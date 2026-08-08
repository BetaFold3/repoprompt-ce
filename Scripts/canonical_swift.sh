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

exec /usr/bin/env -i "${swift_env[@]}" /usr/bin/swift "$@"
