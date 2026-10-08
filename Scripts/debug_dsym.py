#!/usr/bin/env python3
"""Debug dSYM policy and coordinated dSYM regeneration (build-pipeline plan Step 10).

Two entry points:

* ``wrapper-policy -- <swift arguments...>`` -- used by
  ``Scripts/canonical_swift.sh``. Classifies the exact argument vector, prints
  one ``rpce-debug-dsym:`` stderr banner and answers ``on`` or ``off`` on
  stdout. ``off`` means the wrapper adds exactly
  ``SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true``; the policy variable itself never
  reaches Swift. The wrapper never touches symbol files.
* ``regenerate --product <selector>`` -- the coordinated ``dsym`` operation
  (the conductor holds the build lane and the heavy slot). Runs the selected
  toolchain's ``dsymutil`` for existing debug binaries, writing in place to
  the conventional adjacent ``<executable>.dSYM``, then verifies its UUIDs.
  Never builds.

Policy: ``RPCE_DEBUG_DSYM=on|off``; unset means ``off``. Any other value,
including the empty string, exits 2 before anything else happens. Requested
``on``, a release, unknown, conflicting or malformed configuration, and any
nonempty ``REPOPROMPT_ENABLE_SENTRY`` keep the full environment. ``on``
affects future links only; a null build does not recreate missing symbols.

Regeneration is in place and not transactional: a failed, mismatched or
interrupted run can leave the adjacent dSYM missing, partial or stale. That is
reported, never hidden; the previous symbols are not preserved. Rerun
``make dev-dsym`` (or rebuild) to recover. Protection is against cooperating
writers that respect the build lane only.

Standard library only; compatible with the system ``/usr/bin/python3`` (3.9).
"""

from __future__ import annotations

import dataclasses
import os
import platform
import signal
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Policy

POLICY_ENV_KEY = "RPCE_DEBUG_DSYM"
HOOK_ENV_KEY = "SWIFT_DRIVER_DSYMUTIL_EXEC"
HOOK_VALUE = "/usr/bin/true"
SENTRY_ENV_KEY = "REPOPROMPT_ENABLE_SENTRY"
POLICY_VALUES = ("on", "off")
DEFAULT_REQUESTED = "off"
POLICY_EXIT_INVALID = 2
CLASSIFIER_FAILURE_EXIT = 70
BANNER_PREFIX = "rpce-debug-dsym:"
SKIP_NOTE = "regenerate symbols for existing binaries with make dev-dsym"

REASON_SENTRY = "sentry"
REASON_REQUESTED_ON = "requested_on"
REASON_DEBUG_SKIP = "debug_skip"
CONFIGURATION_REASONS = {
    "release": "configuration_release",
    "unknown": "configuration_unknown",
    "conflicting": "configuration_conflicting",
    "malformed": "configuration_malformed",
}

# SwiftPM options whose operand is the next token. An option outside both
# tables, without an inline ``=`` operand, makes the configuration ``unknown``
# (full symbols) rather than a guess about where its operand ends.
VALUE_OPTIONS = frozenset({
    "--package-path", "--scratch-path", "--build-path", "--cache-path", "--config-path", "--security-path",
    "--swift-sdks-path", "--toolset", "--pkg-config-path", "-Xcc", "-Xswiftc", "-Xlinker", "-Xcxx",
    "-Xbuild-tools-swiftc", "-Xmanifest", "--triple", "--sdk", "--toolchain", "--swift-sdk", "--arch",
    "--build-system", "-j", "--jobs", "--product", "--target", "--test-product", "--filter", "--skip",
    "--xunit-output", "--num-workers", "--default-registry-url", "--netrc-file",
    "--resolver-fingerprint-checking", "--resolver-signing-entity-checking", "--sanitize",
    "--explicit-target-dependency-import-check", "-debug-info-format", "--debug-info-format",
    "--experimental-event-stream-output", "--experimental-event-stream-version", "--attachments-path",
    "--traits", "--manifest-cache", "--attempts", "--configuration-file",
})
FLAG_OPTIONS = frozenset({
    "--build-tests", "--skip-build", "--show-bin-path", "--parallel", "--no-parallel", "-v", "--verbose",
    "--very-verbose", "--vv", "-q", "--quiet", "--enable-code-coverage", "--disable-code-coverage",
    "--static-swift-stdlib", "--no-static-swift-stdlib", "--enable-testable-imports",
    "--disable-testable-imports", "--list-tests", "-l", "--enable-index-store", "--disable-index-store",
    "--disable-sandbox", "--enable-dependency-cache", "--disable-dependency-cache",
    "--disable-build-manifest-caching", "--enable-build-manifest-caching", "--skip-update",
    "--disable-automatic-resolution", "--force-resolved-versions", "--only-use-versions-from-resolved-file",
    "--enable-experimental-swift-testing", "--enable-swift-testing", "--disable-swift-testing",
    "--enable-xctest", "--disable-xctest", "--show-codecov-path", "--show-code-coverage-path", "--help",
    "-h", "--version", "--enable-prefetching", "--disable-prefetching",
    "--enable-parseable-module-interfaces", "--enable-dead-strip", "--disable-dead-strip",
    "--disable-local-rpath", "--enable-local-rpath", "--ignore-lock", "--disable-keychain",
    "--enable-keychain", "--netrc", "--disable-netrc", "--enable-netrc", "--use-integrated-swift-driver",
    "--experimental-explicit-module-build", "--emit-swift-module-separately",
})
CONFIGURATION_OPTIONS = frozenset({"-c", "--configuration"})


class PolicyError(ValueError):
    """``RPCE_DEBUG_DSYM`` has a value other than ``on``/``off``."""


def normalize_requested(raw: Optional[str]) -> str:
    """Unset -> ``off``; exactly ``on``/``off`` -> itself; anything else raises."""
    if raw is None:
        return DEFAULT_REQUESTED
    if raw in POLICY_VALUES:
        return raw
    shown = repr(raw) if len(raw) <= 32 else repr(raw[:32]) + "..."
    raise PolicyError(f"{POLICY_ENV_KEY} must be 'on' or 'off' (unset means off); got {shown}")


def scan_configuration(argv: Sequence[str]) -> Tuple[str, Optional[str]]:
    """Token-aware SwiftPM build-configuration scan: ``(configuration, detail)``.

    ``configuration`` is debug | release | unknown | conflicting | malformed.
    Only recognized options are skipped with their operands; tokens after a
    bare ``--`` belong to the invoked program and are not inspected.
    """
    values: List[str] = []
    malformed: Optional[str] = None
    unknown: Optional[str] = None
    tokens = [str(token) for token in argv]
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if token == "--":
            break
        if not token.startswith("-") or token == "-":
            continue
        if token.startswith("--") and "=" in token:
            name, inline = token.split("=", 1)
        else:
            name, inline = token, None
        if name in CONFIGURATION_OPTIONS or name in VALUE_OPTIONS:
            if inline is None:
                if index >= len(tokens):
                    malformed = malformed or f"{name} has no value"
                    continue
                operand = tokens[index]
                index += 1
            else:
                operand = inline
            if name in CONFIGURATION_OPTIONS:
                if not operand or operand.startswith("-"):
                    malformed = malformed or f"{name} has an empty or option-like value"
                    continue
                values.append(operand)
            continue
        if name in FLAG_OPTIONS:
            if inline is not None:
                unknown = unknown or f"{name} does not take a value"
            continue
        if inline is not None:
            continue  # unrecognized ``--opt=value``: its operand boundary is established
        unknown = unknown or f"unrecognized option {name} (operand boundary unknown)"
    if malformed is not None:
        return "malformed", malformed
    if unknown is not None:
        return "unknown", unknown
    if not values:
        return "debug", None
    if len(set(values)) > 1:
        return "conflicting", "distinct configuration values"
    if values[0] in {"debug", "release"}:
        return values[0], None
    return "unknown", "unsupported configuration value"


@dataclasses.dataclass(frozen=True)
class PolicyDecision:
    requested: str  # on | off
    effective: str  # on (full environment) | off (skip hook added)
    reason: str
    configuration: str
    detail: Optional[str] = None

    @property
    def skip(self) -> bool:
        return self.effective == "off"

    def banner(self) -> str:
        parts = [BANNER_PREFIX, f"requested={self.requested}", f"effective={self.effective}",
                 f"reason={self.reason}", f"configuration={self.configuration}"]
        if self.requested == "off" and self.effective == "on":
            parts.append("warning=skip-not-applied")
        line = " ".join(parts)
        return f"{line} ({SKIP_NOTE})" if self.skip else line


def classify_policy(argv: Sequence[str], requested_raw: Optional[str], sentry_value: Optional[str]) -> PolicyDecision:
    """Invalid policy -> PolicyError; Sentry -> on; requested on -> on; debug -> off; anything else -> on."""
    requested = normalize_requested(requested_raw)
    configuration, detail = scan_configuration(argv)
    if sentry_value:
        effective, reason = "on", REASON_SENTRY
    elif requested == "on":
        effective, reason = "on", REASON_REQUESTED_ON
    elif configuration == "debug":
        effective, reason = "off", REASON_DEBUG_SKIP
    else:
        effective, reason = "on", CONFIGURATION_REASONS[configuration]
    return PolicyDecision(requested, effective, reason, configuration, detail)


def classify_environment(argv: Sequence[str], environ: Mapping[str, str]) -> PolicyDecision:
    return classify_policy(argv, environ.get(POLICY_ENV_KEY), environ.get(SENTRY_ENV_KEY))


# ---------------------------------------------------------------------------
# Bounded Mach-O UUID reader

MAX_FAT_SLICES = 64
MAX_LOAD_COMMANDS = 4096
MAX_HEADER_BYTES = 16 * 1024 * 1024
LC_UUID = 0x1B
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
_THIN_MAGICS = {
    struct.pack("<I", MH_MAGIC): ("<", False),
    struct.pack("<I", MH_MAGIC_64): ("<", True),
    struct.pack(">I", MH_MAGIC): (">", False),
    struct.pack(">I", MH_MAGIC_64): (">", True),
}
_FAT_MAGICS = {struct.pack(">I", FAT_MAGIC): False, struct.pack(">I", FAT_MAGIC_64): True}
CPU_NAMES = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x0200000C: "arm64_32", 7: "i386", 12: "arm"}


class MachOError(Exception):
    """Unreadable, unsupported or inconsistent Mach-O metadata."""


def file_identity(st: os.stat_result) -> Tuple[int, int, int, int, int]:
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def _read(fd: int, size: int, budget: List[int], offset: int, length: int) -> bytes:
    if offset < 0 or length < 0 or offset + length > size:
        raise MachOError("read outside the file")
    if length > budget[0]:
        raise MachOError("header read budget exceeded")
    budget[0] -= length
    data = os.pread(fd, length, offset)
    if len(data) != length:
        raise MachOError("short read")
    return data


def _slice_uuid(fd: int, size: int, budget: List[int], offset: int, length: int) -> str:
    if length < 28:
        raise MachOError("slice too small for a Mach-O header")
    shape = _THIN_MAGICS.get(_read(fd, size, budget, offset, 4))
    if shape is None:
        raise MachOError("slice is not a Mach-O image")
    order, is64 = shape
    header_size = 32 if is64 else 28
    if length < header_size:
        raise MachOError("slice too small for its header")
    header = _read(fd, size, budget, offset, header_size)
    cputype, _subtype, _filetype, ncmds, sizeofcmds = struct.unpack(order + "iiIII", header[4:24])
    if ncmds > MAX_LOAD_COMMANDS or header_size + sizeofcmds > length:
        raise MachOError("invalid load command table")
    commands = _read(fd, size, budget, offset + header_size, sizeofcmds)
    position = 0
    found: Optional[str] = None
    for _ in range(ncmds):
        if position + 8 > len(commands):
            raise MachOError("truncated load command")
        cmd, cmdsize = struct.unpack(order + "II", commands[position:position + 8])
        if cmdsize < 8 or position + cmdsize > len(commands):
            raise MachOError("invalid load command size")
        if cmd == LC_UUID:
            if cmdsize < 24 or found is not None:
                raise MachOError("short or duplicate LC_UUID")
            raw = commands[position + 8:position + 24].hex().upper()
            found = f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"
        position += cmdsize
    if found is None:
        raise MachOError("missing LC_UUID")
    return f"{CPU_NAMES.get(cputype, f'cpu{cputype}')}:{found}"


def read_uuids_fd(fd: int) -> Tuple[frozenset, Tuple[int, ...]]:
    """``(frozenset{"<arch>:<UUID>"}, identity)`` of an open regular Mach-O file.

    Thin or fat, either byte order; exactly one ``LC_UUID`` per slice; at most
    ``MAX_HEADER_BYTES`` read; a file changing during inspection raises.
    """
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        raise MachOError("not a regular file")
    size = before.st_size
    budget = [MAX_HEADER_BYTES]
    magic = _read(fd, size, budget, 0, 4)
    result: List[str] = []
    if magic in _FAT_MAGICS:
        is64 = _FAT_MAGICS[magic]
        (count,) = struct.unpack(">I", _read(fd, size, budget, 4, 4))
        if count == 0 or count > MAX_FAT_SLICES:
            raise MachOError("unsupported fat slice count")
        entry = 32 if is64 else 20
        table = _read(fd, size, budget, 8, entry * count)
        for index in range(count):
            raw = table[index * entry:(index + 1) * entry]
            if is64:
                _cpu, _sub, offset, length, _align, _reserved = struct.unpack(">iiQQII", raw)
            else:
                _cpu, _sub, offset, length, _align = struct.unpack(">iiIII", raw)
            if offset < 8 + entry * count or length <= 0 or offset + length > size:
                raise MachOError("fat slice outside the file")
            result.append(_slice_uuid(fd, size, budget, offset, length))
    elif magic in _THIN_MAGICS:
        result.append(_slice_uuid(fd, size, budget, 0, size))
    else:
        raise MachOError("not a Mach-O file")
    if file_identity(before) != file_identity(os.fstat(fd)):
        raise MachOError("file changed during inspection")
    if len(set(result)) != len(result):
        raise MachOError("duplicate slice UUIDs")
    return frozenset(result), file_identity(before)


def read_uuids(path: os.PathLike) -> Tuple[frozenset, Tuple[int, ...]]:
    fd = os.open(os.fspath(path), os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    try:
        return read_uuids_fd(fd)
    finally:
        os.close(fd)


def dsym_uuids(dsym: Path, exe_name: str) -> frozenset:
    """UUIDs of a dSYM bundle's single DWARF file, which must be named after the executable."""
    dwarf = dsym / "Contents" / "Resources" / "DWARF"
    for directory in (dsym, dsym / "Contents", dsym / "Contents" / "Resources", dwarf):
        st = os.lstat(directory)
        if not stat.S_ISDIR(st.st_mode):
            raise MachOError(f"{directory} is not a real directory")
    names = sorted(os.listdir(dwarf))
    if names != [exe_name]:
        raise MachOError(f"{dwarf} must hold exactly {exe_name!r}, found {names[:8]}")
    return read_uuids(dwarf / exe_name)[0]


# ---------------------------------------------------------------------------
# Coordinated regeneration

PRODUCT_SELECTORS = ("all", "RepoPrompt", "repoprompt-mcp", "repoprompt-gateway", "root-tests")
ROOT_TEST_BUNDLE = "RepoPromptCEPackageTests.xctest"
DSYMUTIL_TIMEOUT_S = 15 * 60
MAX_PRINTED_OUTPUT_LINES = 40


class RegenerationError(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class Product:
    selector: str
    parent: Tuple[str, ...]  # components below the native debug bin directory
    exe_name: str

    @property
    def relpath(self) -> str:
        return "/".join((*self.parent, self.exe_name))

    @property
    def dsym_name(self) -> str:
        return self.exe_name + ".dSYM"


def product_for(selector: str) -> Product:
    if selector == "root-tests":
        stem = ROOT_TEST_BUNDLE[: -len(".xctest")]
        return Product(selector, (ROOT_TEST_BUNDLE, "Contents", "MacOS"), stem)
    if selector in PRODUCT_SELECTORS and selector != "all":
        return Product(selector, (), selector)
    raise RegenerationError(f"PRODUCT must be one of {', '.join(PRODUCT_SELECTORS)}; got {selector!r}")


def native_triple(machine: Optional[str] = None) -> str:
    name = machine or platform.machine()
    triple = {"arm64": "arm64-apple-macosx", "x86_64": "x86_64-apple-macosx"}.get(name)
    if triple is None:
        raise RegenerationError(f"unsupported host architecture {name!r}")
    return triple


def real_directory_chain(base: Path, components: Sequence[str]) -> Path:
    """``base/components...``, each component a real directory (never a symlink)."""
    current = base
    for component in components:
        current = current / component
        st = os.lstat(current)  # FileNotFoundError propagates
        if stat.S_ISLNK(st.st_mode):
            raise RegenerationError(f"{current} is a symbolic link; refusing to follow it")
        if not stat.S_ISDIR(st.st_mode):
            raise RegenerationError(f"{current} is not a directory")
    return current


def native_debug_bin(package_root: Path, machine: Optional[str] = None) -> Path:
    """``<realpath(package)>/.build/<triple>/debug`` with no symlinked component below the package."""
    try:
        return real_directory_chain(Path(os.path.realpath(package_root)), (".build", native_triple(machine), "debug"))
    except FileNotFoundError:
        raise RegenerationError("no native debug build exists; build first (for example `make dev-swift-build` or "
                                "`make dev-test`)") from None


def selected_dsymutil() -> str:
    """The selected toolchain's ``dsymutil`` (honors ``DEVELOPER_DIR``)."""
    try:
        completed = subprocess.run(["/usr/bin/xcrun", "--find", "dsymutil"], stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RegenerationError(f"cannot locate dsymutil: {exc}") from None
    path = completed.stdout.strip()
    if completed.returncode != 0 or not path or not os.access(path, os.X_OK):
        raise RegenerationError(f"cannot locate dsymutil: {completed.stderr.strip() or 'xcrun --find failed'}")
    return path


def count_pcm_warnings(text: str) -> int:
    return sum(1 for line in text.splitlines() if ".pcm" in line and "warning" in line.lower())


def run_dsymutil(argv: Sequence[str], timeout: float) -> Tuple[int, str, int]:
    """``(exit, combined output, duration ns)``; the child is killed on timeout or interruption."""
    started = time.monotonic_ns()
    process = subprocess.Popen(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        process.kill()
        process.communicate()
        raise
    return process.returncode, output.decode("utf-8", errors="replace"), time.monotonic_ns() - started


def regenerate(package_root: os.PathLike, selector: str, *, machine: Optional[str] = None,
               dsymutil: Optional[str] = None, timeout: float = DSYMUTIL_TIMEOUT_S,
               emit: Callable[[str], None] = print) -> Dict[str, Any]:
    """Regenerate dSYMs for existing selected debug binaries; never builds.

    An explicitly selected missing product fails. ``all`` processes the
    existing products, reports omissions and fails when none exists.
    """
    if selector not in PRODUCT_SELECTORS:
        raise RegenerationError(f"PRODUCT must be one of {', '.join(PRODUCT_SELECTORS)}; got {selector!r}")
    bin_dir = native_debug_bin(Path(package_root), machine)
    selectors = [item for item in PRODUCT_SELECTORS if item != "all"] if selector == "all" else [selector]
    targets: List[Product] = []
    omitted: List[str] = []
    for item in selectors:
        product = product_for(item)
        try:
            parent = real_directory_chain(bin_dir, product.parent)
            st = os.lstat(parent / product.exe_name)
        except FileNotFoundError:
            omitted.append(item)
            continue
        if not stat.S_ISREG(st.st_mode):
            raise RegenerationError(f"{product.relpath} is not a regular file")
        targets.append(product)
    if selector != "all" and omitted:
        raise RegenerationError(f"{selector} has not been built; build it first, then rerun "
                                f"`make dev-dsym PRODUCT={selector}`")
    if not targets:
        raise RegenerationError("none of the selected debug binaries exist; build first")
    tool = dsymutil or selected_dsymutil()
    emit(f"dsym: dsymutil {tool}")
    for item in omitted:
        emit(f"dsym: {item} not built; omitted")
    results = [regenerate_one(bin_dir, product, tool, timeout, emit) for product in targets]
    return {"selector": selector, "dsymutil": tool, "products": results, "omitted": omitted}


def regenerate_one(bin_dir: Path, product: Product, dsymutil: str, timeout: float,
                   emit: Callable[[str], None]) -> Dict[str, Any]:
    parent = real_directory_chain(bin_dir, product.parent)
    exe = parent / product.exe_name
    destination = parent / product.dsym_name
    existing = _lstat(destination)
    if existing is not None and not stat.S_ISDIR(existing.st_mode):
        raise RegenerationError(f"{destination} exists but is not a real directory; nothing changed")
    try:
        exe_uuids, exe_identity = read_uuids(exe)
    except (OSError, MachOError) as exc:
        raise RegenerationError(f"{product.relpath}: cannot read Mach-O UUIDs: {exc}") from None
    rerun = f"rerun `make dev-dsym PRODUCT={product.selector}` or rebuild"
    try:
        # In place: dsymutil writes the conventional adjacent bundle directly.
        code, output, duration_ns = run_dsymutil([dsymutil, str(exe), "-o", str(destination)], timeout)
    except BaseException:
        emit(f"dsym: interrupted; {destination} may be missing, partial or stale; {rerun}")
        raise
    lines = output.splitlines()
    for line in lines[:MAX_PRINTED_OUTPUT_LINES]:
        emit(line)
    if len(lines) > MAX_PRINTED_OUTPUT_LINES:
        emit(f"[{len(lines) - MAX_PRINTED_OUTPUT_LINES} more dsymutil output lines not shown]")
    pcm = count_pcm_warnings(output)
    unusable = f"{destination} may be missing, partial or stale (previous symbols are not preserved); {rerun}"
    if code != 0:
        raise RegenerationError(f"{product.relpath}: dsymutil exited {code}; {unusable}")
    try:
        dsym_ids = dsym_uuids(destination, product.exe_name)
        after_uuids, after_identity = read_uuids(exe)
    except (OSError, MachOError) as exc:
        raise RegenerationError(f"{product.relpath}: output unverifiable ({exc}); {unusable}") from None
    if dsym_ids != exe_uuids:
        raise RegenerationError(f"{product.relpath}: dSYM UUIDs {sorted(dsym_ids)} do not match the executable "
                                f"{sorted(exe_uuids)}; {unusable}")
    if (after_uuids, after_identity) != (exe_uuids, exe_identity):
        raise RegenerationError(f"{product.relpath}: executable changed during generation; {unusable}")
    arch_uuids = sorted(exe_uuids)
    emit(f"dsym: {product.relpath}.dSYM {'regenerated' if existing is not None else 'created'} in place "
         f"uuids={','.join(arch_uuids)} dsymutil={duration_ns / 1e9:.1f}s pcmWarnings={pcm}")
    return {"product": product.selector, "relpath": product.relpath, "dsym": str(destination), "uuids": arch_uuids,
            "replaced": existing is not None, "durationSeconds": round(duration_ns / 1e9, 3), "pcmWarnings": pcm}


def _lstat(path: Path) -> Optional[os.stat_result]:
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


# ---------------------------------------------------------------------------
# Command line


def _wrapper_policy(argv: Sequence[str]) -> int:
    args = list(argv)
    if args and args[0] == "--":
        args = args[1:]
    try:
        decision = classify_environment(args, os.environ)
    except PolicyError as exc:
        print(f"canonical_swift.sh: {exc}", file=sys.stderr)
        return POLICY_EXIT_INVALID
    print(decision.banner(), file=sys.stderr, flush=True)
    print(decision.effective)
    return 0


def _terminate(signum: int, _frame: Any) -> None:
    # Conductor cancellation sends SIGTERM to the job's process group; raising
    # kills dsymutil and discloses the possibly partial in-place dSYM.
    raise SystemExit(128 + signum)


def _regenerate(argv: Sequence[str]) -> int:
    args = list(argv)
    selector = "all"
    package_root = Path.cwd()
    while args:
        option = args.pop(0)
        if option in ("--product", "--package-root") and args:
            value = args.pop(0)
            if option == "--product":
                selector = value
            else:
                package_root = Path(value)
        else:
            print("usage: debug_dsym.py regenerate [--product <selector>] [--package-root <path>]", file=sys.stderr)
            return 64
    signal.signal(signal.SIGTERM, _terminate)
    print(f"==> Regenerate debug dSYMs ({selector}); existing debug binaries only, never builds", flush=True)
    try:
        regenerate(package_root, selector, emit=lambda line: print(line, flush=True))
    except RegenerationError as exc:
        print(f"dsym: {exc}", file=sys.stderr, flush=True)
        return 1
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "wrapper-policy":
        try:
            return _wrapper_policy(args[1:])
        except Exception as exc:  # noqa: BLE001 - fail before Swift, never a silent policy
            print(f"canonical_swift.sh: debug dSYM policy classification failed: {exc}", file=sys.stderr)
            return CLASSIFIER_FAILURE_EXIT
    if args and args[0] == "regenerate":
        return _regenerate(args[1:])
    print("usage: debug_dsym.py wrapper-policy -- <swift arguments...> | regenerate [--product <selector>]",
          file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
