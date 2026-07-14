#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
LAYOUT_LABEL="${2:-Embedded helper layout}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle> [label]"

python3 - "$APP_BUNDLE" "$LAYOUT_LABEL" <<'PYTHON'
import os
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1])
label = sys.argv[2]
helpers = ["repoprompt-mcp", "repoprompt-gateway"]


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


for helper_name in helpers:
    helper = app / "Contents" / "MacOS" / helper_name
    links = {
        app / "Contents" / "Resources" / helper_name: f"../MacOS/{helper_name}",
        app / "Contents" / "Resources" / "bin" / helper_name: f"../../MacOS/{helper_name}",
    }

    try:
        helper_mode = helper.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing embedded helper: {helper}")
    if not stat.S_ISREG(helper_mode):
        fail(f"embedded helper must be a non-symlink regular file: {helper}")
    if not helper_mode & 0o111:
        fail(f"embedded helper must be executable: {helper}")

    for link, expected_target in links.items():
        try:
            link_mode = link.lstat().st_mode
        except FileNotFoundError:
            fail(f"missing embedded helper compatibility symlink: {link}")
        if not stat.S_ISLNK(link_mode):
            fail(f"embedded helper compatibility path must be a symlink: {link}")
        actual_target = os.readlink(link)
        if actual_target != expected_target:
            fail(
                f"embedded helper compatibility symlink target mismatch: "
                f"{link} -> {actual_target}; expected {expected_target}"
            )

print(f"OK: {label} matches the embedded helper layout policy.")
PYTHON
