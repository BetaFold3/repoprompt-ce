#!/usr/bin/env python3
"""Debug packaging helper for Scripts/package_app.sh (stdlib only).

Invoked as ``python3 -I -S Scripts/debug_package_cache.py <subcommand>``. Debug packaging
assembles each bundle in a fresh hidden sibling of its destination and publishes it here
only after every check passed. Release packaging never calls this helper.

Subcommands:
  publish --new P --dest D --temp-parent T
      Move the finished bundle P (inside T) to D. An existing D is swapped atomically with
      renamex_np(RENAME_SWAP); filesystems without swap fall back to two renames with
      rollback. A failed restore never deletes the previous bundle: it stays in T next to
      ``.retain`` and the exact ``mv`` recovery is printed (exit 3).
  cleanup-stale --parent DIR --max-age SECONDS
      Remove ``.rpce-package-*`` siblings older than SECONDS, except any holding ``.retain``.
  resolve-identity --sign-identity S   (stdin: ``security find-identity -v -p codesigning`` output)
      Print ``cert=<SHA-1>|adhoc|unresolved``, mirroring how ``codesign -s`` picks one identity.
  plan --cache on|off --cert C --root R --scripts-dir S --build-dir B --field NAME=VALUE...
      Print the package keys, ``outcome`` and ``receipts_allowed``. Reads stat metadata, small
      repository inputs and Git state only; it never reads or writes a cache. When receipts are
      not allowed (cache ``off`` or an unresolved identity) the keys are ``none``.
  component-lookup --cache-root C --component ID=KEY...
      For each signed component (``sparkle``, ``helper_mcp``, ``helper_gateway``) print
      ``<ID>_status=hit`` with the entry, or ``miss`` with a fresh private temp entry to sign into.
      An entry whose receipt inventory no longer matches, or that lacks ``.complete``, is evicted.
  component-commit --cache-root C --component ID=TEMP...
      Record the signed payload's inventory in ``receipt.json``, write ``.complete`` last and
      rename the temp entry into place. If the entry already exists the temp copy is discarded.
  forget --cache-root C --entry PATH...
      Evict the named component entries (a failed run's used entries).
  prune --cache-root C [--keep 2] [--used PATH...]
      Keep the newest entries per component plus every used one; drop stale temp entries.

The package_app.sh caller invokes the component subcommands only when ``plan`` allowed receipts
(cache ``on`` and a resolved identity), so cache ``off`` never reads, writes or evicts entries.
Component cache layout (immutable entries)::

    <cache-root>/components/sparkle/<key>/Sparkle.framework, receipt.json, .complete
    <cache-root>/components/helpers/<name>/<key>/<name>,       receipt.json, .complete

stdout carries ``key=value`` lines, the first being ``schema=1``. Diagnostics go to stderr.
Exit codes: 0 success, 1 failure with the destination intact (or still absent), 2 usage,
3 publish failure that left the destination missing with the previous bundle preserved.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence, TextIO, Tuple

SCHEMA = 1
TEMP_PARENT_PREFIX = ".rpce-package-"
RETAIN_NAME = ".retain"
BACKUP_PREFIX = "previous-"
# Same flag and signature as conductor.py swap_staged_debug_bundle_into_place (not imported).
RENAME_SWAP = 0x00000002
SWAP_UNSUPPORTED_ERRNOS = frozenset({errno.ENOTSUP, errno.EINVAL, errno.ENOSYS})

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_DESTINATION_MISSING = 3

RenameFn = Callable[[Path, Path], None]
RemoveTreeFn = Callable[[Path], None]

# --- Package keys (plan Step 4) -------------------------------------------------------------
# Each key is the SHA-256 of a labelled, NUL-separated stream. Built outputs are keyed by
# stat metadata (no per-byte hashing of executables); small repository inputs by content.
KEY_SCHEMA = 1
PRODUCTS = ("RepoPrompt", "repoprompt-mcp", "repoprompt-gateway")
HELPERS = {"repoprompt-mcp": "helper_mcp_key", "repoprompt-gateway": "helper_gateway_key"}
# Control scripts (basenames under the control-plane scripts dir) whose bytes shape the debug
# package, including the data/helper files they read. Verification scripts are listed too.
INPUT_SCRIPTS = (
    "package_app.sh",
    "debug_package_cache.py",
    "load_release_metadata.sh",
    "parse_release_metadata.py",
    "normalize_swiftpm_resource_bundles.sh",
    "validate_required_swiftpm_resource_bundles.sh",
    "verify_sparkle_vendor.sh",
    "validate_app_architectures.sh",
    "validate_embedded_mcp_helper_layout.sh",
    "smoke_embedded_mcp_helper.sh",
    "run_without_github_tokens.sh",
    "validate_json.py",
)
# Scripts referenced through a variable file name (none since the fast fingerprint retired).
DECLARED_DYNAMIC: Dict[str, str] = {}
# Repository inputs (relative to ROOT_DIR) copied into or rendered for the bundle.
REPO_INPUTS = (
    "AppBundle/Info.plist.template",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "ThirdPartyLicenses",
    "AppResources",
    "version.env",
)
# Raw environment values hashed into input_key (their effect is not visible in any field).
ENV_INPUTS = ("REPOPROMPT_ENABLE_SENTRY", "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS")
# Resolved package_app.sh values passed as --field; each must be passed exactly once.
PLAN_FIELDS = (
    "CONF",
    "APP_NAME",
    "DISPLAY_NAME",
    "BUNDLE_ID",
    "URL_SCHEME",
    "MARKETING_VERSION",
    "BUILD_NUMBER",
    "DEBUG_STORAGE_BACKEND_MARKER",
    "SIGNING_MODE_MARKER",
    "USE_ADHOC_SIGNING",
    "ARCHITECTURE_POLICY",
    "LOCAL_SIGNING_CERTIFICATE_SHA256",
    "LOCAL_SIGNING_SERVICE_GENERATION",
)
SIGNING_FIELDS = ("SIGNING_MODE_MARKER", "DEBUG_STORAGE_BACKEND_MARKER", "USE_ADHOC_SIGNING")
# Environment variables the closure scripts read whose effect reaches the keys through a plan
# input instead of the raw value: a field, the resolved cert, --root, or --scripts-dir.
ENV_RESOLVED = {
    "ALLOW_ADHOC_SIGNING": "field USE_ADHOC_SIGNING",
    "APP_NAME": "field APP_NAME",
    "BUILD_NUMBER": "field BUILD_NUMBER",
    "BUNDLE_ID": "field BUNDLE_ID",
    "BUNDLE_ID_OVERRIDE": "field BUNDLE_ID",
    "DEBUG_BUNDLE_ID": "field BUNDLE_ID",
    "DEBUG_SECURE_STORAGE_BACKEND": "field DEBUG_STORAGE_BACKEND_MARKER",
    "DISPLAY_NAME": "field DISPLAY_NAME",
    "LOCAL_SIGNING_CERTIFICATE_SHA256": "field LOCAL_SIGNING_CERTIFICATE_SHA256",
    "LOCAL_SIGNING_SERVICE_GENERATION": "field LOCAL_SIGNING_SERVICE_GENERATION",
    "MARKETING_VERSION": "field MARKETING_VERSION",
    "PREFER_STABLE_DEBUG_SIGNING": "cert",
    "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": "scripts-dir",
    "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE": "field BUILD_NUMBER",
    "REPOPROMPT_RELEASE_SOURCE_ROOT": "root",
    "SIGN_IDENTITY": "cert",
}
# Everything else the closure references, with the reason it is not a key input.
CLOSURE_EXCLUSIONS = {
    # Scripts
    "doctor.sh": "environment check only; no output effect",
    "canonical_swift.sh": "build effect reaches the key through the product stat records",
    "patch_keyboard_shortcuts_resource_lookup.sh": "patch effect reaches the key through the product stat records",
    "build_swiftpm_release_products.sh": "release-only",
    "write_app_artifact_manifest.py": "release-only",
    "upload_sentry_debug_symbols.sh": "Sentry side effect; REPOPROMPT_UPLOAD_SENTRY_SYMBOLS is an ENV_INPUTS value",
    # ROOT_DIR paths
    ".build": "build outputs, destinations and generated state",
    "Scripts": "default control-plane scripts dir; its files are INPUT_SCRIPTS",
    "AppBundle/RepoPrompt.entitlements.template": "release-only",
    "AppBundle/RepoPrompt.local-self-signed.entitlements.template": "release-only",
    # Environment
    "APP_ENTITLEMENTS": "script-internal temporary file",
    "APP_ENTITLEMENTS_TEMPLATE": "release-only",
    "EPOCHREALTIME": "timing records only",
    "GATEWAY_ARCHES": "validate_app_architectures.sh internal",
    "HELPER_ARCHES": "validate_app_architectures.sh internal",
    "MAIN_ARCHES": "validate_app_architectures.sh internal",
    "LIPO": "verification tool only; verification always runs",
    "LOCAL_SELF_SIGNED_RELEASE": "release-only (debug fails when set)",
    "LOCAL_SIGNING_CERTIFICATE_SHA1": "release-only (local self-signed requirement)",
    "PROFILE_APP_IDENTIFIER": "release-only internal",
    "RELEASE_ALLOW_ADHOC_SIGNING": "release-only",
    "REPOPROMPT_DEBUG_APP_BUNDLE": "destination path; excluded from every key by design",
    "REPOPROMPT_DEBUG_PACKAGE_CACHE": "escape: off disables keys and receipts",
    "REPOPROMPT_PROVISIONING_PROFILE": "release-only",
    "REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS": "release-only (universal builder)",
    "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE": "Sentry upload credentials; no bundle effect",
    "SENTRY_AUTH_TOKEN": "Sentry upload credentials; no bundle effect",
    "SENTRY_AUTH_TOKEN_FILE": "Sentry upload credentials; no bundle effect",
    "SIGNING_TEAM_ID": "release-only checks; debug value comes from version.env",
    "TEMP_PARENT": "script-internal publish state",
    "VERBOSE": "shell tracing only",
}
CERT_RE = re.compile(r"[0-9A-F]{40}")
IDENTITY_LINE_RE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
UNRESOLVED_WARNING = "WARNING: signing identity not uniquely resolved; package caches disabled"
SYSTEM_VERSION_PLIST = Path("/System/Library/CoreServices/SystemVersion.plist")


def renamex_swap(source: Path, destination: Path) -> None:
    """Atomically exchange two same-volume paths; raises OSError (ENOSYS when unavailable)."""
    if sys.platform != "darwin":
        raise OSError(errno.ENOSYS, "renamex_np is only available on macOS")
    try:
        renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
    except AttributeError as exc:
        raise OSError(errno.ENOSYS, "renamex_np symbol is unavailable") from exc
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    if renamex_np(os.fsencode(source), os.fsencode(destination), RENAME_SWAP) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(source), None, str(destination))


def _default_rename(source: Path, destination: Path) -> None:
    os.rename(source, destination)


def _default_remove_tree(path: Path) -> None:
    shutil.rmtree(path)


def restore_failed_message(destination: Path, backup: Path, new: Path) -> str:
    return (
        f"PUBLISH FAILED: {destination} is missing. Previous bundle preserved at {backup}. "
        f'New bundle at {new}. Recover: mv "{backup}" "{destination}"'
    )


def retained_publish_message(temp_parent: Path, destination: Path, backup: Path, new: Path) -> str:
    return (
        f"PUBLISH INTERRUPTED: {temp_parent} is retained. If {destination} is missing, recover with "
        f'mv "{backup}" "{destination}" (or mv "{new}" "{destination}" when no previous bundle was moved aside). '
        f'Once {destination} is intact, remove the retained directory: rm -rf "{temp_parent}"'
    )


def _same_directory(left: Path, right: Path) -> bool:
    try:
        return os.path.samefile(left, right)
    except OSError:
        return False


class _Publisher:
    def __init__(
        self,
        new: Path,
        destination: Path,
        temp_parent: Path,
        *,
        rename: RenameFn,
        swap: RenameFn,
        remove_tree: RemoveTreeFn,
        out: TextIO,
        err: TextIO,
    ) -> None:
        self.new = new
        self.destination = destination
        self.temp_parent = temp_parent
        self.retain = temp_parent / RETAIN_NAME
        self.backup = temp_parent / f"{BACKUP_PREFIX}{destination.name}"
        self.rename = rename
        self.swap = swap
        self.remove_tree = remove_tree
        self.out = out
        self.err = err

    def emit(self, outcome: str) -> None:
        self.out.write(f"schema={SCHEMA}\noutcome={outcome}\n")
        self.out.flush()

    def fail(self, message: str, outcome: str = "failed", code: int = EXIT_FAILED) -> int:
        self.err.write(f"ERROR: {message}\n")
        self.emit(outcome)
        return code

    def validate(self) -> Optional[str]:
        if not self.temp_parent.name.startswith(TEMP_PARENT_PREFIX):
            return f"temp parent must be named {TEMP_PARENT_PREFIX}*: {self.temp_parent}"
        if self.temp_parent.is_symlink() or not self.temp_parent.is_dir():
            return f"temp parent is not a directory: {self.temp_parent}"
        if self.new.is_symlink() or not self.new.is_dir():
            return f"new bundle is not a directory: {self.new}"
        if self.new.name != self.destination.name:
            return f"new bundle name {self.new.name!r} does not match destination name {self.destination.name!r}"
        if not _same_directory(self.new.parent, self.temp_parent):
            return f"new bundle {self.new} is not directly inside temp parent {self.temp_parent}"
        if not _same_directory(self.temp_parent.parent, self.destination.parent):
            return f"temp parent {self.temp_parent} is not a sibling of destination {self.destination}"
        if self.destination.is_symlink():
            return f"destination is a symlink; refusing to publish through it: {self.destination}"
        if os.path.lexists(self.destination) and not self.destination.is_dir():
            return f"destination exists but is not a directory: {self.destination}"
        if os.path.lexists(self.backup) or os.path.lexists(self.retain):
            return f"temp parent already holds {self.backup.name} or {RETAIN_NAME}: {self.temp_parent}"
        return None

    def write_retain(self, text: str) -> None:
        self.retain.write_text(text + "\n", encoding="utf-8")

    def drop_retain(self) -> None:
        try:
            self.retain.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            self.err.write(f"WARNING: could not remove {self.retain}: {exc}; remove it manually.\n")

    def succeed(self, outcome: str) -> int:
        self.drop_retain()
        try:
            self.remove_tree(self.temp_parent)
        except OSError as exc:
            self.err.write(
                f"WARNING: published {self.destination} but could not remove {self.temp_parent}: {exc}; "
                "stale cleanup will remove it later.\n"
            )
        print(f"Published debug app bundle: {self.destination} ({outcome})", file=self.err)
        self.emit(outcome)
        return EXIT_OK

    def run(self) -> int:
        problem = self.validate()
        if problem is not None:
            return self.fail(f"publish rejected: {problem}", outcome="rejected")
        try:
            self.write_retain(retained_publish_message(self.temp_parent, self.destination, self.backup, self.new))
        except OSError as exc:
            # A partial .retain would block finish() and stale cleanup forever; the destination is intact.
            self.drop_retain()
            return self.fail(f"could not write {self.retain}: {exc}; destination untouched")

        if not os.path.lexists(self.destination):
            try:
                self.rename(self.new, self.destination)
            except OSError as exc:
                self.drop_retain()
                return self.fail(f"publish failed: rename {self.new} -> {self.destination}: {exc}")
            return self.succeed("renamed")

        try:
            self.swap(self.new, self.destination)
        except OSError as exc:
            if exc.errno not in SWAP_UNSUPPORTED_ERRNOS:
                self.drop_retain()
                return self.fail(f"publish failed: swap {self.new} <-> {self.destination}: {exc}; destination untouched")
            self.err.write(f"Atomic swap unavailable ({exc}); publishing with two renames.\n")
            return self.fallback()
        return self.succeed("swapped")

    def fallback(self) -> int:
        try:
            self.rename(self.destination, self.backup)
        except OSError as exc:
            self.drop_retain()
            return self.fail(f"publish failed: rename {self.destination} -> {self.backup}: {exc}; destination untouched")
        try:
            self.rename(self.new, self.destination)
        except OSError as replace_exc:
            try:
                self.rename(self.backup, self.destination)
            except OSError as restore_exc:
                message = restore_failed_message(self.destination, self.backup, self.new)
                try:
                    self.write_retain(message)
                except OSError as exc:
                    self.err.write(f"WARNING: could not rewrite {self.retain}: {exc}\n")
                self.err.write(f"replace error: {replace_exc}\nrestore error: {restore_exc}\n")
                return self.fail(message, outcome="retained", code=EXIT_DESTINATION_MISSING)
            self.drop_retain()
            return self.fail(f"publish failed; previous bundle restored ({replace_exc})", outcome="restored")
        return self.succeed("fallback")


def publish(
    new: Path,
    destination: Path,
    temp_parent: Path,
    *,
    rename: RenameFn = _default_rename,
    swap: RenameFn = renamex_swap,
    remove_tree: RemoveTreeFn = _default_remove_tree,
    out: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
) -> int:
    return _Publisher(
        Path(new),
        Path(destination),
        Path(temp_parent),
        rename=rename,
        swap=swap,
        remove_tree=remove_tree,
        out=out or sys.stdout,
        err=err or sys.stderr,
    ).run()


def cleanup_stale(
    parent: Path,
    max_age_seconds: float,
    *,
    now: Callable[[], float] = time.time,
    remove_tree: RemoveTreeFn = _default_remove_tree,
    out: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parent = Path(parent)
    removed = retained = 0
    if not os.path.lexists(parent):
        out.write(f"schema={SCHEMA}\nremoved=0\nretained=0\n")
        return EXIT_OK
    if parent.is_symlink() or not parent.is_dir():
        err.write(f"ERROR: cleanup parent is not a directory: {parent}\n")
        return EXIT_FAILED
    current = now()
    for entry in sorted(os.scandir(parent), key=lambda item: item.name):
        if not entry.name.startswith(TEMP_PARENT_PREFIX) or not entry.is_dir(follow_symlinks=False):
            continue
        path = Path(entry.path)
        try:
            age = current - entry.stat(follow_symlinks=False).st_mtime
        except OSError:
            continue
        if age < max_age_seconds:
            continue
        retain = path / RETAIN_NAME
        if os.path.lexists(retain):
            retained += 1
            try:
                detail = retain.read_text(encoding="utf-8").strip()
            except OSError:
                detail = ""
            err.write(f"WARNING: keeping {path} because it holds {RETAIN_NAME}. {detail}\n")
            continue
        try:
            remove_tree(path)
            removed += 1
            err.write(f"Removed stale package directory: {path}\n")
        except OSError as exc:
            err.write(f"WARNING: could not remove stale package directory {path}: {exc}\n")
    out.write(f"schema={SCHEMA}\nremoved={removed}\nretained={retained}\n")
    return EXIT_OK


# --- resolve-identity ------------------------------------------------------------------------


def parse_identities(listing: str) -> List[Tuple[str, str]]:
    """(SHA-1 uppercase, name) pairs from ``security find-identity -v -p codesigning`` text."""
    identities: List[Tuple[str, str]] = []
    for line in listing.splitlines():
        match = IDENTITY_LINE_RE.match(line)
        if match and (match.group(1).upper(), match.group(2)) not in identities:
            identities.append((match.group(1).upper(), match.group(2)))
    return identities


def resolve_identity(sign_identity: str, listing: str) -> str:
    """``adhoc``, the single matching SHA-1, or ``unresolved`` (ambiguous, unmatched or empty)."""
    if sign_identity == "-":
        return "adhoc"
    identities = parse_identities(listing)
    if re.fullmatch(r"[0-9A-Fa-f]{40}", sign_identity):
        wanted = sign_identity.upper()
        return wanted if any(sha1 == wanted for sha1, _ in identities) else "unresolved"
    matches = {sha1 for sha1, name in identities if sign_identity and sign_identity in name}
    return matches.pop() if len(matches) == 1 else "unresolved"


# --- plan ------------------------------------------------------------------------------------


class Key:
    """Labelled NUL-separated SHA-256 stream."""

    def __init__(self, label: str) -> None:
        self.digest = hashlib.sha256(f"rpce-debug-package-key\0{KEY_SCHEMA}\0{label}\0".encode())

    def add(self, label: str, *values: object) -> "Key":
        self.digest.update(f"\x1e{label}".encode())
        for value in values:
            self.digest.update(b"\0" + os.fsencode("<missing>" if value is None else str(value)))
        return self

    def hexdigest(self) -> str:
        return self.digest.hexdigest()


StatFn = Callable[[Path], os.stat_result]


def _stat_tuple(path: Path, stat_fn: StatFn) -> Tuple[object, ...]:
    try:
        st = stat_fn(path)
    except FileNotFoundError:
        return ("missing",)
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, oct(st.st_mode))


def product_record(path: Path, stat_fn: StatFn = os.stat) -> Tuple[object, ...]:
    """Stat record of a built executable; cp follows symlinks, so this does too."""
    return _stat_tuple(path, stat_fn)


def _walk(root: Path, lstat_fn: StatFn) -> Iterable[Tuple[str, Path, os.stat_result]]:
    """Every entry below and including ``root`` (rel ``.``), sorted, never following symlinks."""
    stack = [(".", root)]
    while stack:
        rel, path = stack.pop()
        st = lstat_fn(path)
        yield rel, path, st
        if stat.S_ISDIR(st.st_mode):
            children = sorted(os.listdir(path), reverse=True)
            stack.extend(((name if rel == "." else f"{rel}/{name}"), path / name) for name in children)


def _entry_type(mode: int) -> str:
    if stat.S_ISLNK(mode):
        return "link"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def add_tree_manifest(key: Key, label: str, root: Path, lstat_fn: StatFn = os.lstat) -> None:
    """Stat manifest: (rel, type, mode, size, mtime_ns, ctime_ns, ino, symlink target)."""
    if not os.path.lexists(root):
        key.add(label, "missing")
        return
    for rel, path, st in _walk(root, lstat_fn):
        target = os.readlink(path) if stat.S_ISLNK(st.st_mode) else ""
        key.add(label, rel, _entry_type(st.st_mode), oct(st.st_mode), st.st_size, st.st_mtime_ns, st.st_ctime_ns,
                st.st_ino, target)


def add_content_inputs(key: Key, label: str, root: Path, names: Iterable[str]) -> None:
    """Content records (rel, type, mode, symlink target, sha256) for small inputs."""
    for name in names:
        top = root / name
        if not os.path.lexists(top):
            key.add(label, name, "missing")
            continue
        for rel, path, st in _walk(top, os.lstat):
            relative = name if rel == "." else f"{name}/{rel}"
            kind = _entry_type(st.st_mode)
            target = os.readlink(path) if kind == "link" else ""
            content = hashlib.sha256(path.read_bytes()).hexdigest() if kind == "file" else ""
            key.add(label, relative, kind, oct(stat.S_IMODE(st.st_mode)), target, content)


def scripts_digest(scripts_dir: Path) -> str:
    names = (*INPUT_SCRIPTS, *DECLARED_DYNAMIC)
    if len(set(names)) != len(names):
        raise ValueError("closure script basenames must be unique")
    key = Key("scripts")
    add_content_inputs(key, "script", scripts_dir, sorted(names))
    return key.hexdigest()


def git_state(root: Path) -> Tuple[Optional[str], Optional[str], Optional[bool]]:
    """(branch, commit, dirty) exactly as the debug provenance records them; None when unavailable."""

    def git(args: List[str]) -> Optional[str]:
        try:
            completed = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True, timeout=5)
        except Exception:
            return None
        if completed.returncode != 0:
            return None
        return completed.stdout.strip() or None

    status = git(["status", "--porcelain"])
    # dirty is bool(status) on purpose: the provenance writer records exactly this, so an
    # unavailable `git status` reads as clean in both. compute_keys still accepts None (injected).
    return git(["rev-parse", "--abbrev-ref", "HEAD"]), git(["rev-parse", "HEAD"]), bool(status)


def macos_build() -> Optional[str]:
    try:
        return plistlib.loads(SYSTEM_VERSION_PLIST.read_bytes()).get("ProductBuildVersion")
    except (OSError, ValueError):
        return None


def _tool_record(name_or_path: str, environ: Mapping[str, str], stat_fn: StatFn) -> Tuple[object, ...]:
    resolved = name_or_path if "/" in name_or_path else shutil.which(name_or_path, path=environ.get("PATH"))
    if not resolved:
        return (name_or_path, "unresolved")
    return (name_or_path, resolved, *_stat_tuple(Path(resolved), stat_fn))


def signing_policy_key(
    cert: str,
    fields: Mapping[str, str],
    scripts: str,
    *,
    environ: Mapping[str, str],
    os_build: Optional[str],
    stat_fn: StatFn = os.stat,
) -> str:
    key = Key("signing-policy").add("cert", cert)
    for name in SIGNING_FIELDS:
        key.add("field", name, fields[name])
    key.add("macos-build", os_build)
    key.add("codesign", *_tool_record("codesign", environ, stat_fn))
    allocate = environ.get("CODESIGN_ALLOCATE")
    key.add("codesign-allocate", *(_tool_record(allocate, environ, stat_fn) if allocate else ("unset",)))
    return key.add("scripts", scripts).hexdigest()


def bundle_names(build_dir: Path) -> List[str]:
    """Names the package_app.sh glob ``$BUILD_DIR/*.bundle`` copies (no dot-files)."""
    try:
        return sorted(name for name in os.listdir(build_dir) if name.endswith(".bundle") and not name.startswith("."))
    except FileNotFoundError:
        return []


def compute_keys(
    *,
    cert: str,
    root: Path,
    scripts_dir: Path,
    build_dir: Path,
    fields: Mapping[str, str],
    environ: Mapping[str, str],
    git: Tuple[Optional[str], Optional[str], Optional[bool]],
    os_build: Optional[str],
    stat_fn: StatFn = os.stat,
    lstat_fn: StatFn = os.lstat,
) -> Dict[str, str]:
    """All plan keys. The destination and generated provenance bytes are never inputs."""
    scripts = scripts_digest(scripts_dir)
    policy = signing_policy_key(cert, fields, scripts, environ=environ, os_build=os_build, stat_fn=stat_fn)
    products = {name: product_record(build_dir / name, stat_fn) for name in PRODUCTS}

    sparkle = Key("sparkle").add("signing-policy", policy)
    add_tree_manifest(sparkle, "sparkle", build_dir / "Sparkle.framework", lstat_fn)
    keys = {"signing_policy_key": policy, "sparkle_key": sparkle.hexdigest()}
    for name, output in HELPERS.items():
        keys[output] = Key("helper").add("name", name).add("product", *products[name]).add("signing-policy", policy).hexdigest()

    resolved_root = root.resolve()
    key = Key("input").add("root", resolved_root, resolved_root.name)
    for name in PLAN_FIELDS:
        key.add("field", name, fields[name])
    for name in ENV_INPUTS:
        key.add("env", name, environ.get(name))
    key.add("signing-policy", policy)
    for name in PRODUCTS:
        key.add("product", name, *products[name])
    for name in bundle_names(build_dir):
        add_tree_manifest(key, f"bundle:{name}", build_dir / name, lstat_fn)
    key.add("sparkle", keys["sparkle_key"])
    add_content_inputs(key, "repo", root, REPO_INPUTS)
    key.add("scripts", scripts)
    branch, commit, dirty = git
    key.add("git", branch, commit, "null" if dirty is None else int(dirty))
    keys["input_key"] = key.hexdigest()
    return keys


PLAN_KEYS = ("signing_policy_key", "input_key", "sparkle_key", *HELPERS.values())


def plan(
    *,
    cache: str,
    cert: str,
    root: Path,
    scripts_dir: Path,
    build_dir: Path,
    fields: Mapping[str, str],
    environ: Optional[Mapping[str, str]] = None,
    out: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
    compute: Callable[..., Dict[str, str]] = compute_keys,
) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    receipts_allowed = cache == "on" and cert != "unresolved"
    if receipts_allowed:
        keys = compute(cert=cert, root=root, scripts_dir=scripts_dir, build_dir=build_dir, fields=fields,
                       environ=os.environ if environ is None else environ, git=git_state(root), os_build=macos_build())
    else:
        keys = {name: "none" for name in PLAN_KEYS}
        if cache == "off":
            err.write("Debug package caches disabled (REPOPROMPT_DEBUG_PACKAGE_CACHE=off): "
                      "no cache reads or writes; full signing and verification.\n")
    lines = [f"schema={SCHEMA}", "outcome=fresh", f"cache={cache}", f"cert={cert}",
             f"receipts_allowed={int(receipts_allowed)}", *(f"{name}={keys[name]}" for name in PLAN_KEYS)]
    out.write("\n".join(lines) + "\n")
    return EXIT_OK


# --- Signed component cache (plan Step 5) ----------------------------------------------------
# Each entry is signed and verified once by package_app.sh, committed here, and then cloned
# (never hard-linked) into every bundle. Entries are immutable; there is no lock: writers use
# unique temp entries and an atomic rename, and a colliding commit discards its temp copy.

# Component id -> (directory below <cache-root>/components, payload name). Helper payloads keep
# their product basename: a loose Mach-O signed without --identifier takes it as Identifier.
COMPONENTS: Dict[str, Tuple[Tuple[str, ...], str]] = {
    "sparkle": (("sparkle",), "Sparkle.framework"),
    "helper_mcp": (("helpers", "repoprompt-mcp"), "repoprompt-mcp"),
    "helper_gateway": (("helpers", "repoprompt-gateway"), "repoprompt-gateway"),
}
COMPONENT_KEY_RE = re.compile(r"[0-9a-f]{64}")
RECEIPT_NAME = "receipt.json"
COMPLETE_NAME = ".complete"
TEMP_MARKER = ".tmp."
EVICT_MARKER = ".evict."
RECEIPT_VERSION = 1
DEFAULT_KEEP = 2
STALE_TEMP_SECONDS = 3600
CACHE_RECOVERY = ("retry with REPOPROMPT_DEBUG_PACKAGE_CACHE=off, or clear the cache while no package job runs: "
                  "rm -rf .build/debug/package-cache")


class ComponentCacheError(Exception):
    """An operational component-cache failure (not a normal miss)."""


def component_dir(cache_root: Path, component: str) -> Path:
    return Path(cache_root, "components", *COMPONENTS[component][0])


def component_inventory(payload: Path) -> List[List[object]]:
    """(rel, type, mode, size, mtime_ns, ino, symlink target) per payload entry, never following links."""
    inventory: List[List[object]] = []
    for rel, path, st in _walk(payload, os.lstat):
        target = os.readlink(path) if stat.S_ISLNK(st.st_mode) else ""
        inventory.append([rel, _entry_type(st.st_mode), st.st_mode, st.st_size, st.st_mtime_ns, st.st_ino, target])
    return inventory


def _receipt(component: str, key: str, inventory: List[List[object]]) -> Dict[str, object]:
    return {"version": RECEIPT_VERSION, "component": component, "key": key, "payload": COMPONENTS[component][1],
            "inventory": inventory}


def entry_problem(entry: Path, component: str, key: str) -> Optional[str]:
    """Why ``entry`` cannot be reused, or None when its receipt inventory still matches."""
    payload = COMPONENTS[component][1]
    if entry.is_symlink() or not entry.is_dir():
        return "not a directory"
    if not (entry / COMPLETE_NAME).is_file():
        return f"incomplete (no {COMPLETE_NAME})"
    members = sorted(os.listdir(entry))
    if members != sorted((payload, RECEIPT_NAME, COMPLETE_NAME)):
        return f"unexpected members {members}"
    try:
        receipt = json.loads((entry / RECEIPT_NAME).read_text(encoding="utf-8"))
        inventory = component_inventory(entry / payload)
    except (OSError, ValueError) as exc:
        return f"unreadable entry ({exc})"
    if receipt != _receipt(component, key, inventory):
        return "receipt inventory mismatch"
    return None


def _evict(path: Path, err: TextIO) -> None:
    """Move an entry aside atomically, then delete it; a failed delete is left for prune."""
    aside = path.with_name(f"{path.name}{EVICT_MARKER}{os.getpid()}.{os.urandom(4).hex()}")
    os.rename(path, aside)
    try:
        shutil.rmtree(aside)
    except OSError as exc:
        err.write(f"WARNING: could not delete evicted cache entry {aside}: {exc}; prune removes it later.\n")


def component_lookup(cache_root: Path, requests: Sequence[Tuple[str, str]], *, out: TextIO, err: TextIO) -> int:
    lines = [f"schema={SCHEMA}"]
    for component, key in requests:
        directory = component_dir(cache_root, component)
        entry = directory / key
        if os.path.lexists(entry):
            problem = entry_problem(entry, component, key)
            if problem is None:
                os.utime(entry)  # recency for prune; receipts cover only the payload
                lines += [f"{component}_status=hit", f"{component}_path={entry}"]
                continue
            err.write(f"Evicting {component} cache entry {entry}: {problem}\n")
            _evict(entry, err)
        directory.mkdir(parents=True, exist_ok=True)
        temp = tempfile.mkdtemp(prefix=f"{key}{TEMP_MARKER}{os.getppid()}.", dir=directory)
        lines += [f"{component}_status=miss", f"{component}_path={temp}"]
    out.write("\n".join(lines) + "\n")
    return EXIT_OK


def component_commit(cache_root: Path, requests: Sequence[Tuple[str, str]], *, out: TextIO, err: TextIO) -> int:
    lines = [f"schema={SCHEMA}"]
    for component, temp_text in requests:
        directory = component_dir(cache_root, component)
        payload = COMPONENTS[component][1]
        temp = Path(temp_text)
        key, marker, _ = temp.name.partition(TEMP_MARKER)
        if (not marker or not COMPONENT_KEY_RE.fullmatch(key) or temp.is_symlink() or not temp.is_dir()
                or not _same_directory(temp.parent, directory)):
            raise ComponentCacheError(f"{temp} is not a {component} temp entry under {directory}")
        if sorted(os.listdir(temp)) != [payload]:
            raise ComponentCacheError(f"{temp} must hold exactly the signed {payload}")
        receipt = _receipt(component, key, component_inventory(temp / payload))
        (temp / RECEIPT_NAME).write_text(json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8")
        (temp / COMPLETE_NAME).write_text("1\n", encoding="utf-8")  # written last
        final = directory / key
        status = "committed"
        if os.path.lexists(final):
            status = "collision"
        else:
            try:
                os.rename(temp, final)
            except OSError as exc:
                if exc.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                    raise
                status = "collision"
        if status == "collision":
            shutil.rmtree(temp)  # never merge trees; reuse the entry another writer committed
            problem = entry_problem(final, component, key)
            if problem is not None:
                raise ComponentCacheError(f"{final} was committed concurrently but is unusable ({problem})")
            err.write(f"{component} cache entry {final} already exists; discarded this run's signed copy.\n")
        lines += [f"{component}_status={status}", f"{component}_path={final}"]
    out.write("\n".join(lines) + "\n")
    return EXIT_OK


def _component_of_entry(cache_root: Path, entry: Path) -> Optional[str]:
    if not COMPONENT_KEY_RE.fullmatch(entry.name):
        return None
    for component in COMPONENTS:
        if _same_directory(entry.parent, component_dir(cache_root, component)):
            return component
    return None


def forget(cache_root: Path, entries: Sequence[Path], *, out: TextIO, err: TextIO) -> int:
    forgotten = 0
    for entry in map(Path, entries):
        if not os.path.lexists(entry):
            continue
        if _component_of_entry(cache_root, entry) is None:
            raise ComponentCacheError(f"refusing to forget {entry}: not a component entry under {cache_root}")
        _evict(entry, err)
        err.write(f"Forgot cache entry {entry}\n")
        forgotten += 1
    out.write(f"schema={SCHEMA}\nforgotten={forgotten}\n")
    return EXIT_OK


def prune(
    cache_root: Path,
    *,
    keep: int,
    used: Sequence[Path],
    max_temp_age: float = STALE_TEMP_SECONDS,
    now: Callable[[], float] = time.time,
    out: TextIO,
    err: TextIO,
) -> int:
    """Keep the ``keep`` newest entries (by mtime) per component plus every used entry."""
    used_paths = {os.path.realpath(path) for path in used}
    current = now()
    pruned = 0
    for component in COMPONENTS:
        directory = component_dir(cache_root, component)
        if directory.is_symlink() or not directory.is_dir():
            continue
        entries: List[Tuple[int, str, Path]] = []
        for item in os.scandir(directory):
            path = Path(item.path)
            st = item.stat(follow_symlinks=False)
            if COMPONENT_KEY_RE.fullmatch(item.name):
                entries.append((st.st_mtime_ns, item.name, path))
            elif (TEMP_MARKER in item.name or EVICT_MARKER in item.name) and current - st.st_mtime >= max_temp_age:
                if item.is_dir(follow_symlinks=False):
                    shutil.rmtree(path)
                else:
                    path.unlink()
                pruned += 1
        for index, (_, _, path) in enumerate(sorted(entries, reverse=True)):
            if index < keep or os.path.realpath(path) in used_paths:
                continue
            _evict(path, err)
            pruned += 1
    out.write(f"schema={SCHEMA}\npruned={pruned}\n")
    return EXIT_OK


def _component_pairs(parser: argparse.ArgumentParser, pairs: Sequence[str], *, keys: bool) -> List[Tuple[str, str]]:
    parsed: List[Tuple[str, str]] = []
    for pair in pairs:
        component, sep, value = pair.partition("=")
        if not sep or component not in COMPONENTS or any(component == seen for seen, _ in parsed) or not value:
            parser.error(f"--component {pair!r}: unknown, malformed or duplicate component")
        if keys and not COMPONENT_KEY_RE.fullmatch(value):
            parser.error(f"--component {pair!r}: expected a lowercase 64-hex key")
        parsed.append((component, value))
    if not parsed:
        parser.error("at least one --component is required")
    return parsed


def _cert(value: str) -> str:
    if value in ("adhoc", "unresolved") or CERT_RE.fullmatch(value):
        return value
    raise argparse.ArgumentTypeError(f"expected adhoc, unresolved or an uppercase SHA-1, got {value!r}")


def _parse_fields(parser: argparse.ArgumentParser, pairs: Sequence[str]) -> Dict[str, str]:
    fields: Dict[str, str] = {}
    for pair in pairs:
        name, sep, value = pair.partition("=")
        if not sep or name not in PLAN_FIELDS or name in fields:
            parser.error(f"--field {pair!r}: unknown, malformed or duplicate field")
        fields[name] = value
    missing = [name for name in PLAN_FIELDS if name not in fields]
    if missing:
        parser.error(f"missing --field values: {', '.join(missing)}")
    return fields


def _non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected a non-negative integer, got {value!r}") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"expected a non-negative integer, got {value!r}")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="debug_package_cache.py", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    publish_parser = commands.add_parser("publish", help="publish a finished hidden-sibling bundle")
    publish_parser.add_argument("--new", type=Path, required=True)
    publish_parser.add_argument("--dest", type=Path, required=True)
    publish_parser.add_argument("--temp-parent", type=Path, required=True)
    cleanup_parser = commands.add_parser("cleanup-stale", help="remove stale hidden package siblings")
    cleanup_parser.add_argument("--parent", type=Path, required=True)
    cleanup_parser.add_argument("--max-age", type=_non_negative_int, required=True)
    identity_parser = commands.add_parser("resolve-identity", help="resolve SIGN_IDENTITY to one certificate")
    identity_parser.add_argument("--sign-identity", required=True)
    plan_parser = commands.add_parser("plan", help="print package keys and the outcome")
    plan_parser.add_argument("--cache", choices=("on", "off"), required=True)
    plan_parser.add_argument("--cert", type=_cert, required=True)
    plan_parser.add_argument("--root", type=Path, required=True)
    plan_parser.add_argument("--scripts-dir", type=Path, required=True)
    plan_parser.add_argument("--build-dir", type=Path, required=True)
    plan_parser.add_argument("--field", action="append", default=[], metavar="NAME=VALUE")
    for name, metavar, help_text in (("component-lookup", "ID=KEY", "find or start signed component entries"),
                                     ("component-commit", "ID=TEMP", "commit signed component temp entries")):
        component_parser = commands.add_parser(name, help=help_text)
        component_parser.add_argument("--cache-root", type=Path, required=True)
        component_parser.add_argument("--component", action="append", default=[], metavar=metavar)
    forget_parser = commands.add_parser("forget", help="evict component entries a failed run used")
    forget_parser.add_argument("--cache-root", type=Path, required=True)
    forget_parser.add_argument("--entry", type=Path, action="append", required=True)
    prune_parser = commands.add_parser("prune", help="keep the newest and the used component entries")
    prune_parser.add_argument("--cache-root", type=Path, required=True)
    prune_parser.add_argument("--keep", type=_non_negative_int, default=DEFAULT_KEEP)
    prune_parser.add_argument("--used", type=Path, action="append", default=[])
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "publish":
        return publish(args.new, args.dest, args.temp_parent)
    if args.command == "resolve-identity":
        cert = resolve_identity(args.sign_identity, "" if args.sign_identity == "-" else sys.stdin.read())
        if cert == "unresolved":
            print(UNRESOLVED_WARNING, file=sys.stderr)
        sys.stdout.write(f"schema={SCHEMA}\ncert={cert}\n")
        return EXIT_OK
    if args.command == "plan":
        fields = _parse_fields(parser, args.field)
        return plan(cache=args.cache, cert=args.cert, root=args.root, scripts_dir=args.scripts_dir,
                    build_dir=args.build_dir, fields=fields)
    if args.command in ("component-lookup", "component-commit", "forget", "prune"):
        try:
            if args.command == "component-lookup":
                requests = _component_pairs(parser, args.component, keys=True)
                return component_lookup(args.cache_root, requests, out=sys.stdout, err=sys.stderr)
            if args.command == "component-commit":
                requests = _component_pairs(parser, args.component, keys=False)
                return component_commit(args.cache_root, requests, out=sys.stdout, err=sys.stderr)
            if args.command == "forget":
                return forget(args.cache_root, args.entry, out=sys.stdout, err=sys.stderr)
            return prune(args.cache_root, keep=args.keep, used=args.used, out=sys.stdout, err=sys.stderr)
        except (OSError, ComponentCacheError) as exc:
            print(f"ERROR: debug package {args.command} failed: {exc}. To recover, {CACHE_RECOVERY}.", file=sys.stderr)
            return EXIT_FAILED
    return cleanup_stale(args.parent, args.max_age)


if __name__ == "__main__":
    sys.exit(main())
