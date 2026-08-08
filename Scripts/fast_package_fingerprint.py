#!/usr/bin/env python3
"""Compute the strict fast-debug package verification fingerprint."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
from pathlib import Path
from typing import Iterable

FINGERPRINT_VERSION = b"RepoPrompt-fast-package-v2\0"
VOLATILE_BUNDLE_PATHS = frozenset(
    {"Contents/Resources/RepoPromptDebugProvenance.json"}
)


def _update_text(digest: "hashlib._Hash", value: str) -> None:
    digest.update(value.encode("utf-8"))
    digest.update(b"\0")


def _manifest_paths(root: Path) -> Iterable[tuple[str, Path]]:
    yield ".", root
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if relative in VOLATILE_BUNDLE_PATHS:
            continue
        yield relative, path


def _hash_entry(digest: "hashlib._Hash", label: str, path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError(f"cannot fingerprint {path}: {exc}") from exc

    _update_text(digest, label)
    _update_text(digest, oct(stat.S_IMODE(metadata.st_mode)))
    if stat.S_ISLNK(metadata.st_mode):
        _update_text(digest, "link")
        _update_text(digest, os.readlink(path))
    elif stat.S_ISREG(metadata.st_mode):
        _update_text(digest, "file")
        _update_text(digest, str(metadata.st_size))
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    elif stat.S_ISDIR(metadata.st_mode):
        _update_text(digest, "dir")
    else:
        raise ValueError(f"unsupported fast-package fingerprint input: {path}")


def fast_package_fingerprint(
    bundle: Path,
    *,
    sign_identity: str,
    signing_mode: str,
    scripts: Iterable[Path],
) -> str:
    if not bundle.is_dir():
        raise ValueError(f"app bundle is missing: {bundle}")

    digest = hashlib.sha256()
    digest.update(FINGERPRINT_VERSION)
    _update_text(digest, f"sign-identity:{sign_identity}")
    _update_text(digest, f"signing-mode:{signing_mode}")

    for relative, path in _manifest_paths(bundle):
        _hash_entry(digest, f"bundle:{relative}", path)

    script_paths = list(scripts)
    labels = [path.name for path in script_paths]
    if len(labels) != len(set(labels)):
        raise ValueError("control scripts must have unique basenames")
    for path in sorted(script_paths, key=lambda item: item.name):
        _hash_entry(digest, f"control-script:{path.name}", path)

    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--sign-identity", required=True)
    parser.add_argument("--signing-mode", required=True)
    parser.add_argument("--script", type=Path, action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        fingerprint = fast_package_fingerprint(
            args.bundle,
            sign_identity=args.sign_identity,
            signing_mode=args.signing_mode,
            scripts=args.script,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=__import__("sys").stderr)
        return 1
    print(fingerprint)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
