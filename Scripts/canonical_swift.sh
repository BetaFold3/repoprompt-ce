#!/usr/bin/env bash
# SwiftPM keys manifest-evaluation and build-plan caches on the exact child
# environment. Measured environment deltas force 14–27s replans versus a ~1.1s
# null floor, so every coordinated/packaging Swift call must present a
# byte-identical environment. The additive env -i construction also subsumes
# run_without_github_tokens.sh stripping of GH_TOKEN, GITHUB_TOKEN, and
# SOURCE_GH_TOKEN.
set -eo pipefail

# Pinned constant PATH: env -i clears PATH, but SwiftPM build steps spawn
# tools (codesign for debug entitlements, git) via PATH lookup. A constant
# system PATH keeps the environment deterministic across all lanes.
swift_env=("PATH=/usr/bin:/bin:/usr/sbin:/sbin")

if [[ -n "${REPOPROMPT_ENABLE_SENTRY:-}" ]]; then
    swift_env+=("REPOPROMPT_ENABLE_SENTRY=$REPOPROMPT_ENABLE_SENTRY")
fi
if [[ -n "${RPCE_ENABLE_BENCHMARK_TESTS:-}" ]]; then
    swift_env+=("RPCE_ENABLE_BENCHMARK_TESTS=$RPCE_ENABLE_BENCHMARK_TESTS")
fi
# XCTest runtime gates must reach swift-test children; they are opt-in and
# rare, so the steady-state (unset) environment stays canonical.
if [[ -n "${RPCE_RUN_CODEMAP_E2E:-}" ]]; then
    swift_env+=("RPCE_RUN_CODEMAP_E2E=$RPCE_RUN_CODEMAP_E2E")
fi
if [[ -n "${RPCE_RUN_SCALE_TESTS:-}" ]]; then
    swift_env+=("RPCE_RUN_SCALE_TESTS=$RPCE_RUN_SCALE_TESTS")
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift_env+=("DEVELOPER_DIR=$DEVELOPER_DIR")
fi
if [[ -n "${SDKROOT:-}" ]]; then
    swift_env+=("SDKROOT=$SDKROOT")
fi
if [[ -n "${TOOLCHAINS:-}" ]]; then
    swift_env+=("TOOLCHAINS=$TOOLCHAINS")
fi

# Xcode 27 / Swift 6.4 defaults to swiftbuild, whose .build/out layout and
# cached XCFramework diagnostics differ from the native SwiftPM engine used by
# our packaging and XCTest artifact tooling. Keep build, test (including list
# and --skip-build), and --show-bin-path on the same explicit engine.
case "${1:-}" in
    build|test)
        swift_command="$1"
        shift
        set -- "$swift_command" --build-system native "$@"
        ;;
esac

# Debug dSYM policy (RPCE_DEBUG_DSYM=on|off; unset means off). The classifier
# inspects only the build configuration of this exact argument vector, prints
# one stderr banner, and answers the effective value on stdout. Every eligible
# debug invocation (build, test, list, --show-bin-path) gets the same added
# hook so SwiftPM's environment-keyed caches stay byte-identical; the policy
# variable itself never reaches Swift (env -i). The wrapper never touches
# symbol files: `make dev-dsym` regenerates them for existing binaries. An
# invalid policy value exits 2 and any classifier failure exits before Swift.
dsym_python=/usr/bin/python3
if [[ ! -x "$dsym_python" ]]; then
    dsym_python="$(command -v python3 || true)"
fi
if [[ -z "$dsym_python" ]]; then
    echo "canonical_swift.sh: python3 is required to classify RPCE_DEBUG_DSYM" >&2
    exit 70
fi
dsym_effective="$("$dsym_python" -I -S "$(dirname "${BASH_SOURCE[0]}")/debug_dsym.py" wrapper-policy -- "$@")" || exit $?
case "$dsym_effective" in
    off)
        swift_env+=("SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true")
        ;;
    on) ;;
    *)
        echo "canonical_swift.sh: unexpected debug dSYM policy result '$dsym_effective'" >&2
        exit 70
        ;;
esac

exec /usr/bin/env -i "${swift_env[@]}" /usr/bin/swift "$@"
