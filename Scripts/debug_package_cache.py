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

stdout carries ``key=value`` lines, the first being ``schema=1``. Diagnostics go to stderr.
Exit codes: 0 success, 1 failure with the destination intact (or still absent), 2 usage,
3 publish failure that left the destination missing with the previous bundle preserved.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Callable, Optional, Sequence, TextIO

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
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "publish":
        return publish(args.new, args.dest, args.temp_parent)
    return cleanup_stale(args.parent, args.max_age)


if __name__ == "__main__":
    sys.exit(main())
