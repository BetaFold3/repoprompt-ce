#!/usr/bin/env bash

load_release_metadata() {
    local root="$1"
    local script_dir
    local assignments
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    assignments="$(python3 "$script_dir/parse_release_metadata.py" "$root/version.env")" || return
    eval "$assignments"
}
