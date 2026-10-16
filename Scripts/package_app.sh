#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
FAST_PACKAGE_MARKER="${2:-}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
cd "$ROOT_DIR"

[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x

START_TIME="$(date +%s)"
PHASE_START="$START_TIME"
# Machine-readable timing records for Scripts/summarize_package_phases.py. They use
# $EPOCHREALTIME (bash >= 5; wall clock, not monotonic) and never spawn a process.
# Values are "?" when $EPOCHREALTIME is unavailable. Totals for comparisons come
# from an outer harness with a monotonic clock.
PACKAGE_TIMING_PHASE="startup"
PACKAGE_TIMING_OUTCOME="fresh"
PACKAGE_TIMING_DEEP="skipped:not-reached"
package_timing_now(){
    PACKAGE_TIMING_NOW_US="${EPOCHREALTIME:-}"
    PACKAGE_TIMING_NOW_US="${PACKAGE_TIMING_NOW_US//[!0-9]/}"
}
package_timing_now
PACKAGE_TIMING_START_US="$PACKAGE_TIMING_NOW_US"
PACKAGE_TIMING_PHASE_START_US="$PACKAGE_TIMING_NOW_US"
PACKAGE_TIMING_TOTAL_MS="?"
# Debug publish state read by finish(); set only once hidden-sibling assembly starts.
PACKAGE_DEST=""
TEMP_PARENT=""
package_timing_record(){
    local elapsed_ms="?" name="$PACKAGE_TIMING_PHASE"
    package_timing_now
    PACKAGE_TIMING_TOTAL_MS="?"
    if [[ -n "$PACKAGE_TIMING_NOW_US" && -n "$PACKAGE_TIMING_START_US" ]]; then
        PACKAGE_TIMING_TOTAL_MS=$(( (PACKAGE_TIMING_NOW_US - PACKAGE_TIMING_START_US) / 1000 ))
    fi
    if [[ -n "$PACKAGE_TIMING_NOW_US" && -n "$PACKAGE_TIMING_PHASE_START_US" ]]; then
        elapsed_ms=$(( (PACKAGE_TIMING_NOW_US - PACKAGE_TIMING_PHASE_START_US) / 1000 ))
    fi
    name="${name//\\/\\\\}"
    name="${name//\"/\\\"}"
    printf '[package-timing] phase="%s" elapsed_ms=%s total_ms=%s\n' "$name" "$elapsed_ms" "$PACKAGE_TIMING_TOTAL_MS"
    PACKAGE_TIMING_PHASE_START_US="$PACKAGE_TIMING_NOW_US"
}
phase(){
    local now elapsed total
    package_timing_record
    PACKAGE_TIMING_PHASE="$*"
    now="$(date +%s)"
    elapsed=$((now - PHASE_START))
    total=$((now - START_TIME))
    printf '\n==> [%s] %s (previous: %ss, total: %ss)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$elapsed" "$total"
    PHASE_START="$now"
}
echo_cmd(){
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}
run(){
    echo_cmd "$@"
    "$@"
}
fail(){ echo "ERROR: $*" >&2; exit 1; }
truthy(){
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}
sentry_linking_enabled(){
    [[ "${REPOPROMPT_ENABLE_SENTRY:-}" == "1" ]]
}
require_sentry_upload_credentials(){
    if [[ -z "${SENTRY_AUTH_TOKEN:-}" && -z "${REPOPROMPT_SENTRY_AUTH_TOKEN_FILE:-}" && -z "${SENTRY_AUTH_TOKEN_FILE:-}" ]]; then
        fail "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires SENTRY_AUTH_TOKEN or REPOPROMPT_SENTRY_AUTH_TOKEN_FILE."
    fi
}
remove_stale_artifact_manifests(){
    local manifests=()
    shopt -s nullglob
    manifests=("$ROOT_DIR"/.build/release/*-artifact-manifest.json)
    shopt -u nullglob
    if (( ${#manifests[@]} )); then
        run rm -f -- "${manifests[@]}"
    fi
}
paths_same(){
    python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

left = Path(sys.argv[1])
right = Path(sys.argv[2])
try:
    print("1" if left.samefile(right) else "0")
except OSError:
    left_resolved = left.resolve(strict=False)
    right_resolved = right.resolve(strict=False)
    print("1" if left_resolved == right_resolved else "0")
PY
}
finish(){
    local status="$1" now total
    [[ -z "${APP_ENTITLEMENTS:-}" ]] || rm -f "$APP_ENTITLEMENTS"
    # Debug hidden-sibling assembly: delete the temp parent only while the destination exists
    # and no publish step asked to retain it (.retain holds the recovery line).
    if [[ -n "${TEMP_PARENT:-}" && -d "$TEMP_PARENT" ]]; then
        if [[ -e "$PACKAGE_DEST" && ! -e "$TEMP_PARENT/.retain" ]]; then
            rm -rf "$TEMP_PARENT" || echo "WARNING: could not remove $TEMP_PARENT; stale cleanup will retry." >&2
        elif [[ -e "$TEMP_PARENT/.retain" ]]; then
            echo "ERROR: kept $TEMP_PARENT: $(cat "$TEMP_PARENT/.retain" 2>/dev/null || true)" >&2
        else
            echo "WARNING: kept $TEMP_PARENT because $PACKAGE_DEST is missing; it holds the unpublished package. Remove it with: rm -rf \"$TEMP_PARENT\"" >&2
        fi
    fi
    package_timing_record
    printf '[package-timing] summary outcome=%s deep=%s total_ms=%s status=%s\n' "$PACKAGE_TIMING_OUTCOME" "$PACKAGE_TIMING_DEEP" "$PACKAGE_TIMING_TOTAL_MS" "$status"
    now="$(date +%s)"
    total=$((now - START_TIME))
    if (( status == 0 )); then
        printf '\n==> [%s] Completed packaging in %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$total"
    else
        echo "ERROR: Packaging failed after ${total}s. Re-run with VERBOSE=1 $0 $CONF for shell tracing." >&2
    fi
    exit "$status"
}
trap 'finish $?' EXIT

case "$FAST_PACKAGE_MARKER" in
    "") FAST_PACKAGE_REQUESTED=0 ;;
    fast) FAST_PACKAGE_REQUESTED=1 ;;
    *) fail "Unknown package mode '$FAST_PACKAGE_MARKER'. Expected 'fast' or no package mode." ;;
esac
if (( $# > 2 )); then
    fail "Too many arguments. Usage: $0 [debug|release] [fast]"
fi
# Debug package cache escape, checked before any build or mutation. Unset means on; release ignores it.
DEBUG_PACKAGE_CACHE_MODE="on"
if [[ "$CONF" != "release" ]]; then
    case "${REPOPROMPT_DEBUG_PACKAGE_CACHE-on}" in
        on|off) DEBUG_PACKAGE_CACHE_MODE="${REPOPROMPT_DEBUG_PACKAGE_CACHE-on}" ;;
        *) fail "REPOPROMPT_DEBUG_PACKAGE_CACHE must be 'on' or 'off', got '${REPOPROMPT_DEBUG_PACKAGE_CACHE}'. Unset it for the default, or use off to disable debug package caches." ;;
    esac
fi

BUNDLE_ID_OVERRIDE="${BUNDLE_ID:-}"
RELEASE_BUILD_NUMBER_OVERRIDE="${REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE:-}"
# Invalidate public-release manifests before metadata parsing, checks, or builds
# so failed non-public packaging cannot leave stale release metadata behind.
remove_stale_artifact_manifests
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
phase "Loading release metadata"
load_release_metadata "$ROOT_DIR"
if [[ -n "$RELEASE_BUILD_NUMBER_OVERRIDE" ]]; then
    [[ "$RELEASE_BUILD_NUMBER_OVERRIDE" =~ ^[0-9]{1,4}(\.[0-9]{1,2}){0,2}$ ]] ||
        fail "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE must be a valid numeric build version"
    BUILD_NUMBER="$RELEASE_BUILD_NUMBER_OVERRIDE"
fi
APP_NAME="${APP_NAME:-RepoPrompt}"; DISPLAY_NAME="${DISPLAY_NAME:-RepoPrompt CE}"; BASE_BUNDLE_ID="${BUNDLE_ID:-com.pvncher.repoprompt.ce}"; MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"; BUILD_NUMBER="${BUILD_NUMBER:-1}"; SIGNING_TEAM_ID="${SIGNING_TEAM_ID:-648A27MST5}"
ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/$CONF"

IS_RELEASE=0
[[ "$CONF" == "release" ]] && IS_RELEASE=1
if (( FAST_PACKAGE_REQUESTED )); then
    if (( IS_RELEASE )); then
        echo "WARNING: Fast packaging is debug-only; ignoring the 'fast' marker for release packaging."
    else
        echo "The 'fast' package mode is an accepted compatibility alias; debug packaging always runs full verification."
    fi
fi
if (( IS_RELEASE )); then
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-$BASE_BUNDLE_ID}"
    URL_SCHEME="repoprompt-ce"
else
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-${DEBUG_BUNDLE_ID:-$BASE_BUNDLE_ID.debug}}"
    URL_SCHEME="repoprompt-ce-debug"
fi

phase "Checking build environment"
run "$CONTROL_PLANE_SCRIPTS_DIR/doctor.sh" --quiet
SIGN_IDENTITY_WAS_EXPLICIT=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY_WAS_EXPLICIT=1
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
RELEASE_ALLOW_ADHOC_SIGNING="${RELEASE_ALLOW_ADHOC_SIGNING:-0}"
LOCAL_SELF_SIGNED_RELEASE="${LOCAL_SELF_SIGNED_RELEASE:-0}"
LOCAL_SELF_SIGNED_CERTIFICATE_NAME="RepoPrompt CE Local Self-Signed Code Signing"
LOCAL_SIGNING_CERTIFICATE_SHA1="${LOCAL_SIGNING_CERTIFICATE_SHA1:-}"
LOCAL_SIGNING_CERTIFICATE_SHA256="${LOCAL_SIGNING_CERTIFICATE_SHA256:-}"
LOCAL_SIGNING_SERVICE_GENERATION="${LOCAL_SIGNING_SERVICE_GENERATION:-}"
LOCAL_SELF_SIGNED_REQUIREMENT=""
PREFER_STABLE_DEBUG_SIGNING="${PREFER_STABLE_DEBUG_SIGNING:-1}"
DEBUG_SECURE_STORAGE_BACKEND="${DEBUG_SECURE_STORAGE_BACKEND:-}"
REPOPROMPT_PROVISIONING_PROFILE="${REPOPROMPT_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS_TEMPLATE="${APP_ENTITLEMENTS_TEMPLATE:-$ROOT_DIR/AppBundle/RepoPrompt.entitlements.template}"
LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE="$ROOT_DIR/AppBundle/RepoPrompt.local-self-signed.entitlements.template"
APP_ENTITLEMENTS=""
USE_ADHOC_SIGNING=0
USE_LOCAL_SELF_SIGNED_RELEASE=0
DEBUG_STORAGE_BACKEND_MARKER="alternate-in-memory"
SIGNING_MODE_MARKER="debug-apple-development"
# Debug: one `security find-identity` listing serves auto-detection, the not-found warning and
# package-cache identity resolution. Release keeps its own query below.
CODESIGNING_IDENTITIES=""
CODESIGNING_IDENTITIES_LOADED=0
load_codesigning_identities(){
    if (( ! CODESIGNING_IDENTITIES_LOADED )); then
        CODESIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        CODESIGNING_IDENTITIES_LOADED=1
    fi
}
warn_adhoc_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a debug package."
    echo "WARNING: RepoPrompt debug runtime will use ephemeral in-memory secure storage instead of macOS Keychain for API keys and secure permission documents."
    echo "WARNING: Keychain consent prompts should be avoided, but secrets and secure permission changes saved in this run will not persist across app launches."
    echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" for real local Keychain persistence."
}
warn_release_candidate_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a release-candidate package."
    echo "WARNING: This artifact exercises release packaging only. It is not notarizable, distributable, or suitable for GitHub Releases."
}
if [[ "$LOCAL_SELF_SIGNED_RELEASE" == "1" || "$LOCAL_SELF_SIGNED_RELEASE" == "true" ]]; then
    (( IS_RELEASE )) || fail "LOCAL_SELF_SIGNED_RELEASE is only supported for release packaging."
    [[ -n "$SIGN_IDENTITY" ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires SIGN_IDENTITY pointing at the user-local self-signed code-signing identity."
    [[ "$LOCAL_SIGNING_CERTIFICATE_SHA1" =~ ^[[:xdigit:]]{40}$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires LOCAL_SIGNING_CERTIFICATE_SHA1 with the selected certificate SHA-1 fingerprint."
    [[ "$LOCAL_SIGNING_CERTIFICATE_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires LOCAL_SIGNING_CERTIFICATE_SHA256 with the selected certificate SHA-256 fingerprint."
    [[ "$LOCAL_SIGNING_SERVICE_GENERATION" =~ ^[1-9][0-9]*$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires a positive LOCAL_SIGNING_SERVICE_GENERATION."
    LOCAL_SIGNING_CERTIFICATE_SHA1="$(tr '[:lower:]' '[:upper:]' <<< "$LOCAL_SIGNING_CERTIFICATE_SHA1")"
    LOCAL_SIGNING_CERTIFICATE_SHA256="$(tr '[:lower:]' '[:upper:]' <<< "$LOCAL_SIGNING_CERTIFICATE_SHA256")"
    LOCAL_SELF_SIGNED_REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$LOCAL_SIGNING_CERTIFICATE_SHA1\""
    USE_LOCAL_SELF_SIGNED_RELEASE=1
    echo "WARNING: Building a local-only self-signed production app."
    echo "WARNING: This app is for installation on this Mac only. It is not notarized and must not be uploaded to GitHub Releases."
fi
if [[ -z "$SIGN_IDENTITY" ]] && (( ! IS_RELEASE )) && [[ "$PREFER_STABLE_DEBUG_SIGNING" == "1" || "$PREFER_STABLE_DEBUG_SIGNING" == "true" ]]; then
    load_codesigning_identities
    AUTO_SIGN_IDENTITY="$(awk -F'"' '/"Apple Development: / { print $2; exit }' <<< "$CODESIGNING_IDENTITIES")"
    if [[ -n "$AUTO_SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$AUTO_SIGN_IDENTITY"
        echo "Using auto-detected debug signing identity: $SIGN_IDENTITY"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if (( IS_RELEASE )); then
        if [[ "$RELEASE_ALLOW_ADHOC_SIGNING" != "1" && "$RELEASE_ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Release packaging requires SIGN_IDENTITY and will not produce an ad-hoc signed app by default. Set SIGN_IDENTITY to a stable Apple signing identity for team $SIGNING_TEAM_ID."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_release_candidate_signing
    else
        if [[ "$ALLOW_ADHOC_SIGNING" != "1" && "$ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Debug ad-hoc signing is disabled by default. Set ALLOW_ADHOC_SIGNING=1 to build an ad-hoc package, or set SIGN_IDENTITY for stable signing."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_adhoc_signing
    fi
else
    if (( ! IS_RELEASE )) && (( ! SIGN_IDENTITY_WAS_EXPLICIT )) && [[ -z "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
        echo "WARNING: Auto-detected debug signing will use ephemeral in-memory secure storage to avoid macOS Keychain prompts."
        echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" to opt in to persistent debug Keychain storage."
    fi
    echo "Using signing identity: $SIGN_IDENTITY"
    if (( IS_RELEASE )); then
    if ! security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" >/dev/null 2>&1; then
        echo "WARNING: SIGN_IDENTITY was not found by exact text in 'security find-identity'; codesign will still attempt to use it."
    fi
    else
        load_codesigning_identities
        if ! grep -F -- "$SIGN_IDENTITY" <<< "$CODESIGNING_IDENTITIES" >/dev/null 2>&1; then
            echo "WARNING: SIGN_IDENTITY was not found by exact text in 'security find-identity'; codesign will still attempt to use it."
        fi
    fi
fi

if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
    SIGNING_MODE_MARKER="local-self-signed"
elif (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
    SIGNING_MODE_MARKER="developer-id"
elif (( IS_RELEASE )); then
    SIGNING_MODE_MARKER="release-candidate-adhoc"
elif [[ -n "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
    case "$DEBUG_SECURE_STORAGE_BACKEND" in
        keychain|alternate-in-memory) DEBUG_STORAGE_BACKEND_MARKER="$DEBUG_SECURE_STORAGE_BACKEND" ;;
        *) fail "DEBUG_SECURE_STORAGE_BACKEND must be 'keychain' or 'alternate-in-memory', got '$DEBUG_SECURE_STORAGE_BACKEND'." ;;
    esac
elif (( SIGN_IDENTITY_WAS_EXPLICIT )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
elif (( USE_ADHOC_SIGNING )); then
    SIGNING_MODE_MARKER="debug-adhoc"
fi
printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"
printf 'Signing mode marker: %s\n' "$SIGNING_MODE_MARKER"

SWIFT_BUILD_ARGS=(-c "$CONF")
if sentry_linking_enabled; then
    SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)
fi
PUBLIC_UNIVERSAL_RELEASE=0
ARCHITECTURE_POLICY="matching"
if (( IS_RELEASE )) && (( ! USE_LOCAL_SELF_SIGNED_RELEASE )); then
    PUBLIC_UNIVERSAL_RELEASE=1
    ARCHITECTURE_POLICY="arm64,x86_64"
fi

# KeyboardShortcuts' default Bundle.module lookup does not match RepoPrompt's
# packaged resource layout. Host-native builds patch the default checkout below;
# the universal builder patches each isolated architecture checkout before compiling.
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    phase "Building universal public release products in isolated SwiftPM directories"
    BUILD_DIR="$ROOT_DIR/.build/public-release-products/release"
    run env \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS" \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_swiftpm_release_products.sh" "$BUILD_DIR"
else
    phase "Patching KeyboardShortcuts resource lookup"
    run "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh" "$ROOT_DIR"

    if (( IS_RELEASE )); then
    phase "Building $APP_NAME ($CONF, host-native)"
    run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_NAME"

    phase "Building repoprompt-mcp ($CONF, host-native)"
    run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-mcp

    phase "Building repoprompt-gateway ($CONF, host-native)"
    run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-gateway
    else
        # Debug: one product-less build of the default graph. Every root non-test target
        # belongs to one of the three products above. SwiftPM also builds a few small
        # dependency-package executables; they no-op unless dependencies change.
        phase "Building debug products ($CONF, host-native)"
        run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}"
    fi

    phase "Resolving build artifact paths"
    echo_cmd "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build -c "$CONF" --show-bin-path
    BUILD_DIR="$("$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build -c "$CONF" --show-bin-path)"
fi
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
elif (( IS_RELEASE )); then
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
else
    APP_BUNDLE="${REPOPROMPT_DEBUG_APP_BUNDLE:-$HOME/Library/Application Support/RepoPrompt CE/DebugApps/$APP_NAME.app}"
fi
COMPAT_APP_BUNDLE="$ROOT_DIR/.build/$CONF/$APP_NAME.app"
CLI_PATH="$BUILD_DIR/repoprompt-mcp"
GATEWAY_PATH="$BUILD_DIR/repoprompt-gateway"
printf 'BUILD_DIR=%s\nAPP_BUNDLE=%s\nCOMPAT_APP_BUNDLE=%s\nCLI_PATH=%s\nGATEWAY_PATH=%s\nAD_HOC_SIGNING=%s\nARCHITECTURE_POLICY=%s\n' "$BUILD_DIR" "$APP_BUNDLE" "$COMPAT_APP_BUNDLE" "$CLI_PATH" "$GATEWAY_PATH" "$USE_ADHOC_SIGNING" "$ARCHITECTURE_POLICY"

# Strict reader for debug_package_cache.py stdout: schema=1 first, then each expected key once.
# Unknown, duplicate, missing or malformed lines fail loudly. No eval.
read_debug_package_output(){
    local label="$1" output="$2" key value seen=" " first=1
    shift 2
    while IFS='=' read -r key value; do
        if (( first )); then
            [[ "$key" == "schema" && "$value" == "1" ]] || fail "debug_package_cache.py $label: expected schema=1 first, got '$key=$value'."
            first=0
            continue
        fi
        [[ " $* " == *" $key "* ]] || fail "debug_package_cache.py $label printed an unknown key '$key'."
        [[ "$seen" != *" $key "* ]] || fail "debug_package_cache.py $label printed '$key' twice."
        [[ -n "$value" ]] || fail "debug_package_cache.py $label printed an empty '$key'."
        seen+="$key "
        case "$key" in
            cert) DEBUG_PACKAGE_CERT="$value" ;;
            outcome) DEBUG_PACKAGE_OUTCOME="$value" ;;
            cache) DEBUG_PACKAGE_CACHE_REPORTED="$value" ;;
            receipts_allowed) DEBUG_PACKAGE_RECEIPTS_ALLOWED="$value" ;;
            signing_policy_key) DEBUG_PACKAGE_SIGNING_POLICY_KEY="$value" ;;
            input_key) DEBUG_PACKAGE_INPUT_KEY="$value" ;;
            sparkle_key) DEBUG_PACKAGE_SPARKLE_KEY="$value" ;;
            helper_mcp_key) DEBUG_PACKAGE_HELPER_MCP_KEY="$value" ;;
            helper_gateway_key) DEBUG_PACKAGE_HELPER_GATEWAY_KEY="$value" ;;
            *) fail "debug_package_cache.py $label printed an unsupported key '$key'." ;;
        esac
    done <<< "$output"
    (( ! first )) || fail "debug_package_cache.py $label printed nothing."
    for key in "$@"; do
        [[ "$seen" == *" $key "* ]] || fail "debug_package_cache.py $label did not print '$key'."
    done
}
if (( ! IS_RELEASE )); then
    # Debug package keys. This step only computes and reports them: nothing reads or writes a
    # package cache yet, and every outcome below runs full signing and verification.
    phase "Computing debug package keys"
    [[ "$SIGN_IDENTITY" == "-" ]] || load_codesigning_identities
    DEBUG_PACKAGE_HELPER_OUTPUT="$(
        python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py" resolve-identity --sign-identity "$SIGN_IDENTITY" <<< "$CODESIGNING_IDENTITIES"
    )" || fail "debug_package_cache.py resolve-identity exited with status $?."
    read_debug_package_output resolve-identity "$DEBUG_PACKAGE_HELPER_OUTPUT" cert
    DEBUG_PACKAGE_HELPER_OUTPUT="$(
        python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py" plan \
            --cache "$DEBUG_PACKAGE_CACHE_MODE" --cert "$DEBUG_PACKAGE_CERT" \
            --root "$ROOT_DIR" --scripts-dir "$CONTROL_PLANE_SCRIPTS_DIR" --build-dir "$BUILD_DIR" \
            --field CONF="$CONF" --field APP_NAME="$APP_NAME" --field DISPLAY_NAME="$DISPLAY_NAME" \
            --field BUNDLE_ID="$BUNDLE_ID" --field URL_SCHEME="$URL_SCHEME" \
            --field MARKETING_VERSION="$MARKETING_VERSION" --field BUILD_NUMBER="$BUILD_NUMBER" \
            --field DEBUG_STORAGE_BACKEND_MARKER="$DEBUG_STORAGE_BACKEND_MARKER" \
            --field SIGNING_MODE_MARKER="$SIGNING_MODE_MARKER" --field USE_ADHOC_SIGNING="$USE_ADHOC_SIGNING" \
            --field ARCHITECTURE_POLICY="$ARCHITECTURE_POLICY" \
            --field LOCAL_SIGNING_CERTIFICATE_SHA256="$LOCAL_SIGNING_CERTIFICATE_SHA256" \
            --field LOCAL_SIGNING_SERVICE_GENERATION="$LOCAL_SIGNING_SERVICE_GENERATION"
    )" || fail "debug_package_cache.py plan exited with status $?."
    read_debug_package_output plan "$DEBUG_PACKAGE_HELPER_OUTPUT" outcome cache cert receipts_allowed signing_policy_key input_key sparkle_key helper_mcp_key helper_gateway_key
    PACKAGE_TIMING_OUTCOME="$DEBUG_PACKAGE_OUTCOME"
    printf 'Debug package plan: outcome=%s cache=%s cert=%s receipts_allowed=%s input_key=%s\n' \
        "$DEBUG_PACKAGE_OUTCOME" "$DEBUG_PACKAGE_CACHE_REPORTED" "$DEBUG_PACKAGE_CERT" "$DEBUG_PACKAGE_RECEIPTS_ALLOWED" "$DEBUG_PACKAGE_INPUT_KEY"
    printf 'Debug package component keys: signing_policy=%s sparkle=%s repoprompt-mcp=%s repoprompt-gateway=%s\n' \
        "$DEBUG_PACKAGE_SIGNING_POLICY_KEY" "$DEBUG_PACKAGE_SPARKLE_KEY" "$DEBUG_PACKAGE_HELPER_MCP_KEY" "$DEBUG_PACKAGE_HELPER_GATEWAY_KEY"
fi

generate_sentry_debug_symbols(){
    sentry_linking_enabled || return 0
    phase "Generating Sentry debug symbols"
    command -v xcrun >/dev/null 2>&1 || fail "xcrun is required to generate dSYMs."
    run rm -rf "$SENTRY_SYMBOLS_DIR"
    run mkdir -p "$SENTRY_SYMBOLS_DIR"
    for exe in "$APP_NAME" repoprompt-mcp; do
        [[ -f "$BUILD_DIR/$exe" ]] || fail "Missing built executable for dSYM generation: $BUILD_DIR/$exe"
        run xcrun dsymutil "$BUILD_DIR/$exe" -o "$SENTRY_SYMBOLS_DIR/$exe.dSYM"
    done
    printf 'Sentry debug symbols: %s\n' "$SENTRY_SYMBOLS_DIR"
}
generate_sentry_debug_symbols

phase "Creating app bundle layout"
if (( IS_RELEASE )); then
run rm -rf "$APP_BUNDLE"
APP_BUNDLE_MATCHES_COMPAT="$(paths_same "$APP_BUNDLE" "$COMPAT_APP_BUNDLE")"
if [[ "$APP_BUNDLE_MATCHES_COMPAT" != "1" ]]; then
    run rm -rf "$COMPAT_APP_BUNDLE"
fi
else
    # Debug: assemble in a fresh hidden sibling of the destination and publish it only after
    # every check passed, so a failed package never touches the installed bundle.
    PACKAGE_DEST="$APP_BUNDLE"
    if [[ -L "$PACKAGE_DEST" ]] || { [[ -e "$PACKAGE_DEST" ]] && [[ ! -d "$PACKAGE_DEST" ]]; }; then
        fail "Debug package destination must be a directory or absent, not a symlink or file: $PACKAGE_DEST. Remove it or set REPOPROMPT_DEBUG_APP_BUNDLE to another path."
    fi
    run mkdir -p "$(dirname "$PACKAGE_DEST")"
    run python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py" cleanup-stale --parent "$(dirname "$PACKAGE_DEST")" --max-age 3600
    APP_BUNDLE_MATCHES_COMPAT="$(paths_same "$PACKAGE_DEST" "$COMPAT_APP_BUNDLE")"
    TEMP_PARENT="$(mktemp -d "$(dirname "$PACKAGE_DEST")/.rpce-package-$$-XXXXXXXX")"
    APP_BUNDLE="$TEMP_PARENT/$(basename "$PACKAGE_DEST")"
    printf 'Assembling debug app bundle in hidden sibling: %s\n' "$APP_BUNDLE"
fi
run mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/bin" "$APP_BUNDLE/Contents/Frameworks"
for exe in "$APP_NAME" repoprompt-mcp repoprompt-gateway; do
    [[ -x "$BUILD_DIR/$exe" ]] || fail "Missing built executable: $BUILD_DIR/$exe"
    run cp "$BUILD_DIR/$exe" "$APP_BUNDLE/Contents/MacOS/$exe"
    run chmod +x "$APP_BUNDLE/Contents/MacOS/$exe"
done
run ln -sf ../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/repoprompt-mcp"
run ln -sf ../../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/bin/repoprompt-mcp"
run ln -sf ../MacOS/repoprompt-gateway "$APP_BUNDLE/Contents/Resources/repoprompt-gateway"
run ln -sf ../../MacOS/repoprompt-gateway "$APP_BUNDLE/Contents/Resources/bin/repoprompt-gateway"
run mkdir -p "$APP_BUNDLE/Contents/Resources/Legal"
run cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/Legal/"
run cp -R "$ROOT_DIR/ThirdPartyLicenses" "$APP_BUNDLE/Contents/Resources/Legal/"
[[ ! -d AppResources ]] || run rsync -a AppResources/ "$APP_BUNDLE/Contents/Resources/"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do run cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"; done
shopt -u nullglob
run "$CONTROL_PLANE_SCRIPTS_DIR/normalize_swiftpm_resource_bundles.sh" "$APP_BUNDLE"
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_required_swiftpm_resource_bundles.sh" "$APP_BUNDLE" "Packaged app SwiftPM resource bundle layout"

phase "Writing Info.plist"
run python3 - <<PY
import plistlib
from pathlib import Path
s=Path('AppBundle/Info.plist.template').read_text()
for k,v in {'__APP_NAME__':'$APP_NAME','__DISPLAY_NAME__':'$DISPLAY_NAME','__BUNDLE_ID__':'$BUNDLE_ID','__MARKETING_VERSION__':'$MARKETING_VERSION','__BUILD_NUMBER__':'$BUILD_NUMBER','__URL_SCHEME__':'$URL_SCHEME','__DEBUG_SECURE_STORAGE_BACKEND__':'$DEBUG_STORAGE_BACKEND_MARKER','__SIGNING_MODE__':'$SIGNING_MODE_MARKER','__LOCAL_SIGNING_CERTIFICATE_SHA256__':'$LOCAL_SIGNING_CERTIFICATE_SHA256','__LOCAL_SECURE_STORAGE_GENERATION__':'$LOCAL_SIGNING_SERVICE_GENERATION'}.items(): s=s.replace(k,v)
info = plistlib.loads(s.encode())
schemes = [scheme for item in info.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])]
if schemes != ['$URL_SCHEME']:
    raise SystemExit('ERROR: packaged Info.plist URL scheme mismatch')
Path('$APP_BUNDLE/Contents/Info.plist').write_text(s)
PY
run plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    phase "Rendering local self-signed entitlements"
    [[ -f "$LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE" ]] || fail "Missing local self-signed entitlements template: $LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE"
    APP_ENTITLEMENTS="$(mktemp)"
    run python3 - <<PY
from pathlib import Path
s=Path('$LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE').read_text()
s=s.replace('__BUNDLE_ID__', '$BUNDLE_ID')
Path('$APP_ENTITLEMENTS').write_text(s)
PY
    run plutil -lint "$APP_ENTITLEMENTS"
elif (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    phase "Embedding release provisioning profile and entitlements"
    [[ -f "$REPOPROMPT_PROVISIONING_PROFILE" ]] || fail "Signed release packaging requires REPOPROMPT_PROVISIONING_PROFILE pointing to the RepoPrompt CE Developer ID provisioning profile."
    [[ -f "$APP_ENTITLEMENTS_TEMPLATE" ]] || fail "Missing release entitlements template: $APP_ENTITLEMENTS_TEMPLATE"
    PROFILE_PLIST="$(mktemp)"
    run security cms -D -i "$REPOPROMPT_PROVISIONING_PROFILE" -o "$PROFILE_PLIST"
    PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    run rm -f "$PROFILE_PLIST"
    [[ "$PROFILE_APP_IDENTIFIER" == "$SIGNING_TEAM_ID.$BUNDLE_ID" ]] || fail "Provisioning profile app identifier mismatch: expected $SIGNING_TEAM_ID.$BUNDLE_ID, got ${PROFILE_APP_IDENTIFIER:-<missing>}."
    run cp "$REPOPROMPT_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    APP_ENTITLEMENTS="$(mktemp)"
    run python3 - <<PY
from pathlib import Path
s=Path('$APP_ENTITLEMENTS_TEMPLATE').read_text()
for k,v in {'__BUNDLE_ID__':'$BUNDLE_ID','__SIGNING_TEAM_ID__':'$SIGNING_TEAM_ID'}.items(): s=s.replace(k,v)
Path('$APP_ENTITLEMENTS').write_text(s)
PY
    run plutil -lint "$APP_ENTITLEMENTS"
fi

phase "Copying dynamic frameworks"
printf 'Framework destination: %s\n' "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
    "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh" "$SPARKLE_FRAMEWORK"
run cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
run install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Pre-sign packaged app"

if (( ! IS_RELEASE )); then
    phase "Writing debug bundle provenance"
    ROOT_DIR_FOR_PROVENANCE="$ROOT_DIR" APP_BUNDLE_FOR_PROVENANCE="$APP_BUNDLE" python3 - <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import json
import os
import subprocess
import time

root = Path(os.environ["ROOT_DIR_FOR_PROVENANCE"]).resolve()
bundle = Path(os.environ["APP_BUNDLE_FOR_PROVENANCE"])

def git(args: list[str]) -> str | None:
    try:
        completed = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True, timeout=5)
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None

status = git(["status", "--porcelain"])
now = time.time()
payload = {
    "version": 1,
    "repoRoot": str(root),
    "worktreePath": str(root),
    "worktreeName": root.name,
    "branch": git(["rev-parse", "--abbrev-ref", "HEAD"]),
    "commit": git(["rev-parse", "HEAD"]),
    "dirty": bool(status),
    "buildTimeEpoch": now,
    "buildTimeISO": datetime.fromtimestamp(now, timezone.utc).astimezone().isoformat(timespec="seconds"),
}
path = bundle / "Contents" / "Resources" / "RepoPromptDebugProvenance.json"
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Debug bundle provenance: {path}")
PY
    run python3 "$CONTROL_PLANE_SCRIPTS_DIR/validate_json.py" \
        "$APP_BUNDLE/Contents/Resources/RepoPromptDebugProvenance.json"
fi

phase "Signing app bundle"
sign_path(){
    local path="$1"
    shift || true
    local args=(--force --sign "$SIGN_IDENTITY")
    if (( USE_ADHOC_SIGNING )); then
        args+=(--timestamp=none)
    elif (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
        args+=(--timestamp=none --options runtime)
    elif (( IS_RELEASE )); then
        args+=(--timestamp --options runtime)
    else
        args+=(--timestamp=none)
    fi
    run codesign "${args[@]}" "$@" "$path"
}
sign_sparkle_framework(){
    local framework="$1"
    sign_path "$framework/Versions/B/XPCServices/Installer.xpc"
    sign_path "$framework/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
    sign_path "$framework/Versions/B/Autoupdate"
    sign_path "$framework/Versions/B/Updater.app"
    sign_path "$framework"
}
verify_signed_app_identity(){
    local details identifier team authorities designated_requirement certificate_dir certificate_prefix actual_fingerprint
    details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
    identifier="$(awk -F= '/^Identifier=/{print $2; exit}' <<< "$details")"
    team="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<< "$details")"
    authorities="$(printf '%s\n' "$details" | awk -F= '/^Authority=/{print $2}' | paste -sd ', ' -)"
    printf 'Signed app path: %s\n' "$APP_BUNDLE"
    printf 'Signed app identifier: %s\n' "${identifier:-<missing>}"
    printf 'Signed app team: %s\n' "${team:-<missing>}"
    printf 'Signing authorities: %s\n' "${authorities:-<none/ad-hoc>}"
    printf 'Ad-hoc signing active: %s\n' "$USE_ADHOC_SIGNING"
    printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"
    [[ "$identifier" == "$BUNDLE_ID" ]] || fail "Signed app identifier mismatch: expected $BUNDLE_ID, got ${identifier:-<missing>}"
    if (( USE_ADHOC_SIGNING )); then
        [[ -z "$team" || "$team" == "not set" ]] || echo "WARNING: Expected ad-hoc signing without a team identifier, but found team '$team'."
        echo "WARNING: Ad-hoc package created explicitly; do not use this artifact for release."
    elif (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
        [[ -z "$team" || "$team" == "not set" ]] || fail "Local self-signed app unexpectedly has team identifier '$team'."
        run codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SELF_SIGNED_REQUIREMENT" "$APP_BUNDLE"
        certificate_dir="$(mktemp -d)"
        certificate_prefix="$certificate_dir/leaf"
        codesign -d --extract-certificates="$certificate_prefix" "$APP_BUNDLE" >/dev/null 2>&1 || {
            rm -rf "$certificate_dir"
            fail "Could not extract the local signing certificate from the packaged app."
        }
        [[ -f "${certificate_prefix}0" ]] || {
            rm -rf "$certificate_dir"
            fail "Packaged app did not expose a leaf signing certificate."
        }
        actual_fingerprint="$(shasum -a 256 "${certificate_prefix}0" | awk '{print toupper($1)}')"
        rm -rf "$certificate_dir"
        [[ "$actual_fingerprint" == "$LOCAL_SIGNING_CERTIFICATE_SHA256" ]] || fail "Packaged app certificate fingerprint mismatch: expected $LOCAL_SIGNING_CERTIFICATE_SHA256, got ${actual_fingerprint:-<missing>}."
        designated_requirement="$(codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n 's/^designated => //p')"
        [[ -n "$designated_requirement" ]] || fail "Could not extract the packaged app designated requirement."
        grep -F -i -- "$LOCAL_SIGNING_CERTIFICATE_SHA1" <<< "$designated_requirement" >/dev/null || fail "Packaged app designated requirement is not pinned to the selected local certificate."
        printf 'Selected local certificate SHA-256: %s\n' "$LOCAL_SIGNING_CERTIFICATE_SHA256"
        printf 'Local secure-storage service generation: v%s\n' "$LOCAL_SIGNING_SERVICE_GENERATION"
        printf 'Extracted designated requirement: %s\n' "$designated_requirement"
    elif (( IS_RELEASE )); then
        [[ "$team" == "$SIGNING_TEAM_ID" ]] || fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team:-<missing>}"
    else
        [[ -n "$team" && "$team" != "not set" ]] || fail "Debug app was expected to be signed with a stable identity, but no team identifier was found."
    fi
}
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then sign_sparkle_framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; fi
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-gateway"
# Debug: the outer bundle sign below signs the main executable, so the separate pass is release-only.
if (( IS_RELEASE )); then
sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
APP_SIGN_ARGS=()
if (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")
fi
if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    APP_SIGN_ARGS+=(--requirements "=designated => $LOCAL_SELF_SIGNED_REQUIREMENT")
fi
if (( ${#APP_SIGN_ARGS[@]} )); then
    sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"
else
    sign_path "$APP_BUNDLE"
fi
PACKAGE_TIMING_DEEP="ran"
run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_signed_app_identity
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Post-sign packaged app"
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    run "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" write \
        --app "$APP_BUNDLE" \
        --output "$ARTIFACT_MANIFEST" \
        --expected-architectures "$ARCHITECTURE_POLICY"
fi
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Packaged app MCP helper layout"
run "$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh" "$APP_BUNDLE" "Packaged app MCP helper"
if truthy "${REPOPROMPT_UPLOAD_SENTRY_SYMBOLS:-}"; then
    sentry_linking_enabled || fail "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires REPOPROMPT_ENABLE_SENTRY=1."
    require_sentry_upload_credentials
    run "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" "$SENTRY_SYMBOLS_DIR"
fi
if (( ! IS_RELEASE )); then
    phase "Publishing debug app bundle"
    run python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/debug_package_cache.py" publish --new "$APP_BUNDLE" --dest "$PACKAGE_DEST" --temp-parent "$TEMP_PARENT"
    APP_BUNDLE="$PACKAGE_DEST"
    if [[ "$APP_BUNDLE_MATCHES_COMPAT" != "1" ]]; then
        run rm -rf "$COMPAT_APP_BUNDLE"
    fi
fi
if [[ "$APP_BUNDLE_MATCHES_COMPAT" != "1" ]]; then
    phase "Updating compatibility app bundle link"
    run mkdir -p "$(dirname "$COMPAT_APP_BUNDLE")"
    if (( USE_ADHOC_SIGNING )); then
        if (( IS_RELEASE )); then
            warn_release_candidate_signing
        else
            warn_adhoc_signing
        fi
    fi
    run ln -sfn "$APP_BUNDLE" "$COMPAT_APP_BUNDLE"
    printf 'Compatibility link: %s -> %s\n' "$COMPAT_APP_BUNDLE" "$APP_BUNDLE"
fi
printf 'Created: %s\n' "$APP_BUNDLE"
