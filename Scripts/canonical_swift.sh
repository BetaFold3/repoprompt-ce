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

# Index store policy (RPCE_INDEX_STORE=on|off; unset means off). No known
# consumer reads SwiftPM's index store, so qualified debug build/test
# invocations get --disable-index-store; on adds nothing. Any other value,
# including the empty string, exits 2 before Swift. The policy variable never
# reaches Swift (env -i); only argv changes, so toggling costs one rebuild.
if [[ -z "${RPCE_INDEX_STORE+set}" ]]; then
    index_policy=off
else
    index_policy="$RPCE_INDEX_STORE"
fi
if [[ "$index_policy" != on && "$index_policy" != off ]]; then
    echo "canonical_swift.sh: RPCE_INDEX_STORE must be 'on' or 'off' (unset means off); got '$index_policy'" >&2
    exit 2
fi

# Xcode 27 / Swift 6.4 defaults to swiftbuild, whose .build/out layout and
# cached XCFramework diagnostics differ from the native SwiftPM engine used by
# our packaging and XCTest artifact tooling. Keep build, test (including list
# and --skip-build), and --show-bin-path on the same explicit engine.
index_candidate=""
case "${1:-}" in
    build|test)
        swift_command="$1"
        shift
        # Pin color off: SwiftPM's TTY-dependent default changes compiler argv between pipe (build) and PTY (test) jobs, forcing module re-emission.
        set -- "$swift_command" --build-system native --no-color-diagnostics "$@"
        index_candidate=1
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

# Index eligibility is the dSYM debug-skip qualification (debug configuration,
# no Sentry), independent of the requested dSYM policy. Effective on is
# ambiguous, so re-ask the same classifier with only RPCE_DEBUG_DSYM=off for
# that one quiet subprocess; the single banner above stays authoritative.
if [[ "$index_policy" == off && -n "$index_candidate" ]]; then
    index_effective="$dsym_effective"
    if [[ "$dsym_effective" == on ]]; then
        index_effective="$(RPCE_DEBUG_DSYM=off "$dsym_python" -I -S "$(dirname "${BASH_SOURCE[0]}")/debug_dsym.py" wrapper-policy -- "$@" 2>/dev/null)" || {
            index_status=$?
            echo "canonical_swift.sh: index store eligibility classification failed (exit $index_status)" >&2
            exit "$index_status"
        }
    fi
    case "$index_effective" in
        off)
            set -- "$1" "$2" "$3" --disable-index-store "${@:4}"
            ;;
        on) ;;
        *)
            echo "canonical_swift.sh: unexpected index store eligibility result '$index_effective'" >&2
            exit 70
            ;;
    esac
fi

exec /usr/bin/env -i "${swift_env[@]}" /usr/bin/swift "$@"
