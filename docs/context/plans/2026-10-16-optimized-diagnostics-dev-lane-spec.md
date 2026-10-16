# Optimized-diagnostics Dev lane — technical spec

Scope: read when the task touches an optimized (`-c release`) build of the CE Dev app that keeps first-party `DEBUG` diagnostics, the `RPCE_OPTIMIZED_DIAGNOSTICS` manifest gate, `canonical_swift.sh --rpce-optimized-diagnostics`, `package_app.sh debug-optimized`, `./conductor build|run|app relaunch --optimized`, `Scripts/verify_build_lane_flags.py`, or `RepoPromptBuildLane`.
Authority: Reference
Last-verified: 2026-10-16

Status: proposed. Merged from independent OracleA and OracleB recommendations, then reviewed once by both (round-1 findings applied 2026-10-16). Implementation waits for the owner. Building it reverses the 2026-10-14 owner decision "Leave build tooling unchanged" for this lane only.

## Goal

The owner's daily app, `/Applications/RepoPrompt CE Dev.app`, is a SwiftPM debug build: `-Onone`, `DEBUG` defined, assertions on. App-owned Swift (collections, strings, generics, `Equatable` sweeps) runs several times slower than in the shipped app.

Add an opt-in **lane** (an alternative way to build and package the same app) that:
1. compiles optimized, so the Dev app runs close to release speed;
2. keeps the diagnostics behind `#if DEBUG`: `AgentModePerfDiagnostics`, the main-thread stall watchdog, `__repoprompt_debug_diagnostics` (used by `rpce-cli-debug`), and the EditFlowPerf capture recorder;
3. keeps the Dev app's identity, location and data: bundle ID `com.pvncher.repoprompt.ce.debug`, URL scheme `repoprompt-ce-debug`, Apple Development signing through `SIGN_IDENTITY`, the debug secure-storage marker, staged relaunch, and the same user data;
4. leaves the plain debug build as the default. Its compiler arguments and environment stay unchanged, and its only output changes are additive: new provenance keys, one diagnostics `ping` field, and help text;
5. labels every build and running process with its lane, so timing evidence names its configuration.

## Non-goals

- Optimized XCTest runs, optimized `swift-build`, or exposing the lane on `./conductor package`.
- Any behavior change to the release lane: `package_app.sh release`, `release.sh`, `install_local_production.sh`, `build_swiftpm_release_products.sh`, Sparkle, signing identities, bundle IDs, entitlements or channels.
- Splitting diagnostics out of `DEBUG` into a narrower compile condition. That is a possible later product project, not this tooling lane.
- A shipping-performance claim. The lane is "release code generation plus first-party debug extras".

## Done when

- `SIGN_IDENTITY=… REPOPROMPT_DEBUG_APP_BUNDLE="/Applications/RepoPrompt CE Dev.app" ./conductor app relaunch --optimized` installs and launches an optimized Dev app, after owner approval at that moment.
- The same command without `--optimized` restores today's debug build.
- The lane's flags are proven by the verifier, its identity by the packaged-bundle checks, and its diagnostics by the launch smoke (Validation, steps 4–8).
- The default debug lane's manifests, compiler arguments and environment are unchanged, compared against a baseline captured before step 1 (Validation, steps 0, 2 and 6).

## Verified facts (2026-10-16)

| Fact | Evidence |
|---|---|
| SwiftPM's debug configuration passes `-DDEBUG`, `-Onone`, `-enable-testing` and batch mode, with no whole-module optimization, to **every** Swift module: all 118, including third-party modules (`Logging`, `NIOCore`, `KeyboardShortcuts`, `MarkdownUI`) and the executable module `RepoPrompt`. | `.build/debug.yaml` compile commands |
| First-party `DEBUG` is also declared through `.define("DEBUG", .when(configuration: .debug))`. | `Package.swift:88` (layer settings, which flow to App, AgentCore, Platform, UI and Workspace), `:108` (tests), `:210`, `:218`, `:238`; `Packages/RepoPromptCore/Package.swift:25, 36, 49, 60`; `Packages/RepoPromptAgentProviders/Package.swift:17` |
| The executable target `RepoPrompt` has no `swiftSettings`. | `Package.swift:133-137` |
| No production source uses `@testable import` or `_is*AssertConfiguration()`. | Searched `Sources/` and `Packages/*/Sources` |
| Provenance readers check only the fields they need, so additive keys are safe. The fast-package fingerprint excludes the provenance file. | `Scripts/conductor.py:7741-7757`; `Scripts/live_codemap_authority_e2e.py:547-561`; `Scripts/fast_package_fingerprint.py:15` |
| `PROTOCOL_VERSION = 17`. `package_debug_app_under_heavy` has one caller. | `Scripts/conductor.py:181`, `:8099` |
| `run` today treats every token after `run` as an app argument, with or without `--`. | `Scripts/conductor.py:8879-8881` |
| The KeyboardShortcuts patch helper already takes a scratch path through `REPOPROMPT_SWIFTPM_SCRATCH_PATH`, and the public release builder already uses that pattern. | `Scripts/patch_keyboard_shortcuts_resource_lookup.sh:11-12, 34-38`; `Scripts/build_swiftpm_release_products.sh:89-97` |
| `canonical_swift.sh` runs Swift under `env -i` with an allow-listed environment, because SwiftPM keys its caches on the exact environment. | `Scripts/canonical_swift.sh:1-37`, `:122` |
| Secure-storage trust depends on the signing-mode marker, the storage marker, the bundle ID and the team allowlist. It does not depend on `#if DEBUG` or on optimization. | `Sources/RepoPromptPlatform/Infrastructure/Security/RuntimeCodeSigningPolicy.swift:110-130`, `:241-276` |
| The debug-diagnostics `ping` op is the natural place for a lane label. The handler file is `#if DEBUG`. | Dispatch: `Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift:6, 28-29`. Payload: `MCPConnectionManager+DebugTransportDiagnostics.swift:55` (`debugPingPayload`) |
| The build plan also contains test modules (`RepoPromptTests`, the generated `RepoPromptCEPackageTests`) and third-party test kits. | `.build/debug.yaml` module names |
| First-party C targets have no plain `DEBUG` checks, only specific debug switches (`DEBUG_SEARCH`, `DEBUG_FRAMES_DISPLAY`, `DEBUG_SHOW_*`). | `Sources/RepoPromptC/src/Utils/path_search.c:13`; `Sources/CSwiftPCRE2/src/pcre2_match.c:52-56` |
| Packaging's debug team check only requires a non-empty team. Runtime keychain trust also requires an allow-listed team. | `Scripts/package_app.sh:510-512`; `RuntimeCodeSigningPolicy.swift:111-114` |
| Conductor job records carry the request `args`. | `Scripts/conductor.py:2917`, `:4381` |
| The protocol number is pinned in a test and in the docs. The Xcode workspace generator runs `swift package dump-package` on `Package.swift`. | `Scripts/test_conductor_lifecycle.py:96`; `docs/context/workflows/development.md:23`; `Scripts/generate_xcode_workspace.py:62` |
| This checkout has no release build tree, and the installed production CE app's binary is dated 2026-07-10. | `.build/arm64-apple-macosx/` contains only `debug`; `/Applications/RepoPrompt CE.app` |

## Design

### 1. Decision

**Compile with SwiftPM `-c release` in a separate build folder.** Define `DEBUG` only on first-party Swift targets, through a manifest environment gate. Package through the existing debug identity and staged-relaunch path.

| Property | Debug lane (today, unchanged) | Optimized-diagnostics lane |
|---|---|---|
| SwiftPM configuration | `debug` | `release` |
| Optimization | `-Onone`, batch mode | `-O`, whole-module optimization |
| `DEBUG` in first-party modules | yes (SwiftPM default plus manifests) | yes (manifest gate) |
| `DEBUG` in third-party and C modules | yes (SwiftPM default) | **no** (plain release) |
| `-enable-testing` | yes | no |
| `assert`, `assertionFailure` | evaluated | not evaluated (release default) |
| `precondition`, `fatalError`, overflow and exclusivity traps | trap | trap |
| Debug info / dSYM | `-g`; dSYM skipped unless `RPCE_DEBUG_DSYM=on` | `-g`; full dSYM on every link |
| Index store | disabled | not produced (release) |
| Build folder | `.build/` | `.build/optimized-diagnostics/` |
| Packaging identity, path, signing, storage marker, staging | debug | debug (same code path) |

**Rejected alternatives:**

| Option | Reason |
|---|---|
| Stay on `-c debug` and add per-target `unsafeFlags(["-O"])` or `-Xswiftc -O` | Keeps `-enable-testing` and batch mode (no whole-module optimization), so the speed-up is partial. It thrashes `.build/<arch>/debug`, so the next `make dev-test` rebuilds all first-party modules. Debug-classified argv also triggers the debug dSYM and index-store policies for a build that is no longer debug. |
| `-c release` plus `-Xswiftc -DDEBUG` | Defines `DEBUG` in every third-party module. |
| Reuse the shared `.build/<arch>/release` tree | `install_local_production.sh` builds host-native release in that tree. Alternating with it would recompile all first-party modules both ways, because the defines differ. The owner estimates one or two local-production installs a day. The installed production app's binary is dated 2026-07-10, so the real frequency is unclear, but a separate folder is safe either way. It costs one extra dependency checkout and some disk, and the patch helper already supports it. |
| A new narrow diagnostics condition built as plain release | The transitive `#if DEBUG` fan-out of the four diagnostics is unknown, and it edits sources behind the default build. Out of scope. |
| xcodebuild with a custom configuration | The repository standardizes on native SwiftPM; the Xcode workspace is disposable. |

### 2. Manifests (all three)

**Gate.** `RPCE_OPTIMIZED_DIAGNOSTICS == "1"`, read with `ProcessInfo.processInfo.environment` next to the existing gates (`Package.swift:9-11`). The two sub-manifests gain `import Foundation` and their own copy of the gate and helper, because manifests can't share code.

```swift
let optimizedDiagnosticsLane = environment["RPCE_OPTIMIZED_DIAGNOSTICS"] == "1"
let firstPartyDebugSettings: [SwiftSetting] = optimizedDiagnosticsLane
    ? [.define("DEBUG"), .define("RPCE_OPTIMIZED_DIAGNOSTICS", .when(configuration: .release))]
    : [.define("DEBUG", .when(configuration: .debug))]   // exactly today's element
```

- **Gate off:** every site carries today's element, so `swift package dump-package` output is byte-identical to today.
- **Gate on:** `DEBUG` is unconditioned; the wrapper guarantees `-c release`. The `RPCE_OPTIMIZED_DIAGNOSTICS` define is a lane marker used only by the runtime label (§7) and the verifier (§5).

**Where the helper applies:**

| Site | Targets |
|---|---|
| `Package.swift:88` | `repoPromptLayerSwiftSettings`: App, AgentCore, Platform, UI, Workspace |
| `Package.swift:210`, `:218`, `:238` | RemoteWire, RepoPromptMCP, RepoPromptGateway |
| `Package.swift:133-137` | Executable `RepoPrompt`: `swiftSettings` added **only when the gate is on**, because debug builds already define `DEBUG` there |
| `Packages/RepoPromptCore/Package.swift:25, 36, 49` | Shared, MCPClientKit, MCPCore |
| `Packages/RepoPromptAgentProviders/Package.swift:17` | ClaudeCompatibleProvider |

**Unchanged:** test targets (`Package.swift:107-109`, `RepoPromptCore/Package.swift:60`, the providers test target), because tests never run in this lane. Also unchanged: C targets, vendored path packages and remote dependencies.

**Manifest-cache risk.** Whether SwiftPM re-evaluates the local path-package manifests when only the environment changes is unknown. The verifier (§5) fails closed if a Core or AgentProviders module lacks the defines. The fallback is for the wrapper to add `--manifest-cache none` in this lane only.

### 3. `Scripts/canonical_swift.sh`

**New leading internal flag `--rpce-optimized-diagnostics`.** It is consumed before the `case "${1:-}"` command switch, so the existing positional handling sees the same argv shape as today.

**Rules.** Each violation exits 2 with a message before Swift starts:
- the next argument must be `build`;
- argv must contain `-c release`;
- argv must not contain `--build-tests`, `--scratch-path`, `-Xswiftc`, or `-c debug`;
- every other command (`test`, `package`, …) is rejected.

**Effect:**
- appends `RPCE_OPTIMIZED_DIAGNOSTICS=1` to `swift_env` at a fixed position;
- inserts `--scratch-path "$PWD/.build/optimized-diagnostics"`. `package_app.sh` has already done `cd "$ROOT_DIR"`, so `$PWD` is the package root that the patch helper and verifier also use (§4).

**The wrapper never forwards an inherited `RPCE_OPTIMIZED_DIAGNOSTICS`.** `env -i` drops it, and the flag is the only way in.

**`--show-bin-path`** is a `build` invocation and must carry the same flag, so its environment and caches match the three product builds.

**dSYM and index policy** are classified from the remaining argv: `-c release` gives full symbols and no index flag. Extend `Scripts/test_debug_dsym.py` to prove that classification with the scratch-path argument present. `debug_dsym.py` itself changes only if that test fails.

### 4. `Scripts/package_app.sh`

1. **CONF validation.** Accept only `debug | release | debug-optimized`, right after argument parsing, and update the usage text. Today an unknown `CONF` fails later inside Swift.
2. **Top-level `unset RPCE_OPTIMIZED_DIAGNOSTICS`.** Defence in depth for paths that bypass the wrapper, such as the patch helper's direct `swift package resolve`. Add the same one-line `unset` at the top of `Scripts/build_swiftpm_release_products.sh`, which can also be run on its own and calls Swift directly (`:89-121`). This is behavior-neutral for the release lane.
3. **Derived variables**, placed next to `IS_RELEASE`:

   | Variable | `debug` | `debug-optimized` | `release` |
   |---|---|---|---|
   | `BUILD_LANE` | `debug` | `debug-optimized` | `release` |
   | `SWIFT_CONF` | `debug` | `release` | `release` |
   | `CANONICAL_PREFIX` (array) | empty | `(--rpce-optimized-diagnostics)` | empty |
   | `IS_RELEASE` | 0 | **0** | 1 |

   `IS_RELEASE` stays `CONF == "release"`. That single fact routes the lane through every existing debug branch: bundle ID and URL scheme, signing, storage marker, provenance, fast packaging, `sign_path` debug arguments, and the debug team check.
4. **Lane preconditions**, checked before any build:
   - `SIGN_IDENTITY` is explicit, not ad hoc, and begins with `Apple Development:`;
   - the resolved bundle ID equals `com.pvncher.repoprompt.ce.debug` (reject `BUNDLE_ID` / `DEBUG_BUNDLE_ID` overrides);
   - `REPOPROMPT_ENABLE_SENTRY` and `REPOPROMPT_UPLOAD_SENTRY_SYMBOLS` are unset.
5. **Dependency patch:** run the KeyboardShortcuts helper with `REPOPROMPT_SWIFTPM_SCRATCH_PATH="$ROOT_DIR/.build/optimized-diagnostics"` for the lane. Other lanes are unchanged.
6. **Build calls:**
   - `SWIFT_BUILD_ARGS=(-c "$SWIFT_CONF")`;
   - the three product-build `canonical_swift.sh` calls (`:259`, `:262`, `:265`) become `canonical_swift.sh ${CANONICAL_PREFIX[@]+"${CANONICAL_PREFIX[@]}"} build …`. That expansion is safe for an empty array under `set -u` in bash 3.2;
   - the bin-path query (`:268-269`) hardcodes `-c "$CONF"` in both its `echo_cmd` and the real call. Both lines switch to `-c "$SWIFT_CONF"` plus the prefix;
   - phase labels show `$BUILD_LANE`.
7. **Verifier:** for `debug-optimized` only, after `BUILD_DIR` is resolved:
   - fail unless `BUILD_DIR` lies under `$ROOT_DIR/.build/optimized-diagnostics/`;
   - run `python3 "$CONTROL_PLANE_SCRIPTS_DIR/verify_build_lane_flags.py" --build-yaml "<scratch>/release.yaml"`, deriving `<scratch>` from `BUILD_DIR` (`BUILD_DIR/../..`).

   A failure fails packaging.
8. **Compatibility link:** use `.build/debug/$APP_NAME.app` for both debug lanes, never `.build/release/…`. That matches the conductor's hardcoded repair path, and it never removes the local-production bundle.
9. **Provenance:** add keys and keep `"version": 1`.

   | Key | `debug` | `debug-optimized` |
   |---|---|---|
   | `buildLane` | `"debug"` | `"debug-optimized"` |
   | `swiftConfiguration` | `"debug"` | `"release"` |
   | `optimization` | `"Onone"` | `"O"` |
   | `assertConfiguration` | `"Debug"` | `"Release"` |
   | `laneFlagsVerified` | `null` | `true` |

   These keys, the `ping` field (§7) and the help text are the default lane's only output changes, and all are additive.
10. **Fast-package cache:** the lane uses `.build/optimized-diagnostics/fast-package-verified.sha256`, written only after full verification succeeds. The debug cache is unchanged. A debug baseline can never authorize a lane skip.
11. **Banner:** print `*** OPTIMIZED DIAGNOSTICS LANE: swift -c release, first-party DEBUG, debug identity ***`.

### 5. Lane-flag verifier: `Scripts/verify_build_lane_flags.py` (new)

**Purpose:** prove from SwiftPM's own build plan that the lane compiled what it claims. Python 3 standard library only, read-only.

**Algorithm:**
1. Parse the llbuild manifest's command blocks.
   - Keep only Swift **compile** commands: `-module-name` plus Swift source inputs. Link and other commands that mention a module name are excluded.
   - Check **each command on its own**. Group by module only for the presence check and for reporting, never to union flags.
   - Accept both define spellings, `-DX` and `-D X`. Today's file shows the single token `-DDEBUG`.
   - **Test modules are not production modules.** These are names ending in `Tests`, which covers `RepoPromptTests`, the generated `RepoPromptCEPackageTests`, and third-party test kits. The plan may list them even though the lane never builds them. They are exempt from the first-party requirements and the unknown-module rule, but must not carry `-DRPCE_OPTIMIZED_DIAGNOSTICS`.
2. **First-party set (13 modules):** RepoPrompt, RepoPromptApp, RepoPromptAgentCore, RepoPromptPlatform, RepoPromptUI, RepoPromptWorkspace, RepoPromptRemoteWire, RepoPromptMCP, RepoPromptGateway, RepoPromptShared, RepoPromptMCPClientKit, RepoPromptMCPCore, RepoPromptClaudeCompatibleProvider.
3. **Each first-party module requires:**
   - `-DDEBUG` and `-DRPCE_OPTIMIZED_DIAGNOSTICS`;
   - `-O` and no `-Onone`;
   - `-whole-module-optimization`;
   - no `-enable-testing`.
4. **Every other Swift module requires:** no `-DDEBUG` and no `-DRPCE_OPTIMIZED_DIAGNOSTICS`.
5. **Fail closed** if:
   - an expected module is missing (this catches the manifest-cache risk);
   - a non-test `RepoPrompt*` module is not in the expected set (this catches a new, unclassified target);
   - the file is malformed.
6. Print one summary line per class, then exit 0 or 1.

**Assumptions to confirm at validation step 4** (both fail closed, so the only risk is a false go/no-go failure):
- after the three product builds, `release.yaml` holds the whole product graph, not just the last product's subgraph;
- manifest-declared defines appear in the spelling the parser expects.

**Selftest:** `Scripts/test_verify_build_lane_flags.py`, using inline synthetic fixtures. Cases:
- pass;
- pass with dormant XCTest and package-test compile commands present;
- a module with two compile commands where only one carries `-DDEBUG` (must fail);
- a link command that mentions a first-party module (ignored);
- a missing Core module;
- `DEBUG` in a third-party module;
- `-Onone` present;
- `-enable-testing` present;
- an unknown `RepoPrompt*` module;
- malformed input.

### 6. Conductor and Makefile

**Client parsing.** The new flag is `--optimized`, on three commands only:
- `build` (`conductor.py:8771-8776`): add `--optimized`. Set `args["optimized"] = True` **only when true**, so the default request's arguments and identity are unchanged.
- `run` (`:8879-8881`): if the first token is `--optimized`, consume it, then apply today's rule to the rest. Any other first token keeps today's meaning.
- `app relaunch` (`:8882-8892`): consume a leading `--optimized` before the `--` check. `app launch-existing --optimized` is rejected with: "launch-existing does not build; its lane is whatever the bundle was packaged with (see RepoPromptDebugProvenance.json)."

**Daemon:**
- `build` maps to `[package_app.sh, "debug-optimized" if optimized else "debug"]`, plus `fast` as today.
- `package_debug_app_under_heavy(repo_root, operation_label, package_config="debug")`:
  - raises `ConductorError` unless `package_config` is `debug` or `debug-optimized`;
  - its only caller, `operation_debug_app_build_then_launch` (`:8099`), passes `debug-optimized` when `args.get("optimized")`.
  - Staging, swap, activation and the compatibility-link repair are unchanged.
- **Timeout:** an `optimized` request without an explicit `--timeout` uses `max(default, 3600)` seconds. Step 4 replaces 3600 with twice the measured cold-build time.
  - A timeout failure message names `--timeout <seconds>`.
  - A later `app stop` or `app relaunch` that supersedes an in-flight lane build discards that module's compile progress, because whole-module compiles have no partial results. The live bundle stays intact: `package_debug_app_under_heavy` cleans up staging (`:7885-7920`).
- **Protocol:** `PROTOCOL_VERSION` 17 → 18, so an idle older daemon is replaced, and a busy one is refused instead of silently dropping `optimized`. This is a deliberate contract update: change the pinned assertion in `Scripts/test_conductor_lifecycle.py:96` and the "protocol 17" sentence in `development.md:23`.
- **Environment:** `RPCE_OPTIMIZED_DIAGNOSTICS` is **not** a passthrough key (`:2990-3059`). A selftest asserts its absence.
- **Lane in reports:** `provenance_report_lines` (`:7741`) prints `build lane: <buildLane>`, or `unknown (pre-lane provenance)`. That covers both the launch report (`:7779-7781`) and `app status` (`:8142`), which share this function.
- **Metrics:** job records already carry `args` (`:2917`, `:4381`), so lane jobs are identifiable by `args.optimized`. `development.md` tells readers of `./conductor metrics` to filter by it, so minute-long lane builds are never pooled with debug builds.
- **Help:** `build [--fast] [--optimized]`, `run [--optimized] [-- <app args...>]`, `app relaunch [--optimized] [-- <app args...>]`, plus a one-line note on what `--optimized` means and that it takes minutes per build.

**Selection is per invocation, not sticky.** Select with `./conductor app relaunch --optimized`, `./conductor run --optimized`, or `make dev-run OPTIMIZED=1`. Switch back with the same command without the flag.

A sticky default would let an unflagged relaunch after a quick edit silently start a multi-minute optimized build. It would also blur what the owner approves at relaunch time. A shell alias gives stickiness without hidden state.

**Request keys:** `optimized` is part of the arguments, so optimized and plain requests never merge. Supersession works as today: the newest relaunch intent wins.

**Makefile:**
- `dev-build` (`:186-187`) and `dev-run` (`:195-196`) append `$(if $(filter 1,$(OPTIMIZED)), --optimized)`;
- the help lines mention `OPTIMIZED=1`;
- `conductor-selftest` (`:127`) runs the verifier selftest;
- direct `make build` stays debug-only.

### 7. Runtime label

**New file** `Packages/RepoPromptCore/Sources/RepoPromptShared/RepoPromptBuildLane.swift`. The type exists only under `DEBUG`, so release binaries don't change:

```swift
#if DEBUG
public enum RepoPromptBuildLane: String, Sendable {
    case debug, debugOptimized = "debug-optimized"
    public static let current: RepoPromptBuildLane = {
        #if RPCE_OPTIMIZED_DIAGNOSTICS
        return .debugOptimized
        #else
        return .debug
        #endif
    }()
}
#endif
#if RPCE_OPTIMIZED_DIAGNOSTICS && !DEBUG
#error("RPCE_OPTIMIZED_DIAGNOSTICS requires DEBUG")
#endif
```

**Single consumer:** `debugPingPayload` (`MCPConnectionManager+DebugTransportDiagnostics.swift:55`) adds `"buildLane"`. No other diagnostics record changes; `ping` is enough for §12.

**No new XCTest**, because the ledger is frozen. The live smoke proves the label.

### 8. Assertions

**Off: release semantics.** This matches what users run, and assertions in hot paths would skew the measurement. None of the four diagnostics depends on `assert`.

Turning them on later would mean adding `-assert-config Debug` to first-party targets only, through `unsafeFlags`. Whether local path packages accept `unsafeFlags` is unverified. `-Xswiftc -assert-config Debug` is rejected, because it reaches third-party modules.

### 9. Build folders, disk and time

- The debug lane keeps `.build/<arch>/debug`; the optimized lane uses `.build/optimized-diagnostics/`, with its own checkouts. Alternating lanes forces no rebuild in either folder.
- Local-production and public-release builds are unaffected.

**Estimates.** These are unmeasured, on a noisy host; validation step 4 measures them.

| Work | Optimized lane | Debug today |
|---|---|---|
| First (cold) build | ~10–25 min | — |
| One-line edit in RepoPromptApp (re-optimize module, relink, dSYM, package) | ~3–8 min | ~20–35 s |
| Edit in RepoPromptShared or AgentCore (cascades) | ~8–15 min | — |
| Extra disk (checkouts, objects, dSYMs) | ~3–6 GB | — |

**Heavy slot.** Packaging runs inside the machine-wide heavy slot (`conductor.py:7885-7907`; default one slot). A lane build holds it for minutes, so every coordinated build or test on the machine waits in `waiting-heavy-slot` meanwhile, agent `make dev-test` loops included.

Expected use: debug for edit-build loops. Use the lane for the daily app at natural break points, when no agents are mid-test, and for measurement.

### 10. Diagnostics and behavior relative to today's Dev app

- **Kept** (first-party `DEBUG` is still defined):
  - the four diagnostics;
  - debug-only `app_settings` keys;
  - the debug app-support, socket and CLI paths;
  - the Dev app's updater behavior;
  - all other first-party `#if DEBUG` code.
- **Changed:**
  - timing diagnostics fire less often because the app is faster;
  - numbers from different lanes must never be pooled;
  - first-party `#if DEBUG` consistency work still runs, so numbers stay slightly pessimistic;
  - third-party modules lose the `DEBUG` that SwiftPM's debug configuration gives them today, so their `#if DEBUG` code paths behave as in the shipped app;
  - if first-party `#if DEBUG` code calls a dependency's `#if DEBUG`-only API, the lane fails to compile. That shows up at the go/no-go step, and validation step 1 looks for it in advance;
  - first-party C targets are unaffected: they have no plain `DEBUG` checks (Verified facts).
- **Lost:**
  - `assert` checks;
  - `lldb` stepping and variable inspection quality;
  - crash backtraces still symbolicate through the dSYMs, but inlined frames collapse.

### 11. Identity, signing and storage — guarantees and proof

| Invariant | Guaranteed by | Proof on the packaged bundle |
|---|---|---|
| Bundle ID `com.pvncher.repoprompt.ce.debug` | `IS_RELEASE=0`; lane precondition; signed-identifier check | `codesign -dv` identifier; `plutil -extract CFBundleIdentifier raw` |
| URL scheme `repoprompt-ce-debug` only | debug branch; Info.plist scheme assertion | `plutil -extract CFBundleURLTypes json` |
| Apple Development signing | explicit `SIGN_IDENTITY` precondition; debug team check | `codesign -dv` authority and team; designated requirement equals a debug-lane probe's |
| `RepoPromptSigningMode = debug-apple-development` | unchanged debug default | `plutil -extract RepoPromptSigningMode raw` |
| `RepoPromptDebugSecureStorageBackend = keychain` | explicit identity path; runtime trust unchanged. Keychain continuity holds when the marker is `keychain` and the signer's team is on the runtime allowlist (`RuntimeCodeSigningPolicy.swift:111-114`). Packaging checks only for a non-empty team (`package_app.sh:510-512`), exactly as the debug lane does today. An intentional in-memory override stays allowed and is not a failure. | `plutil` extract; the launch report's storage and team warnings (`conductor.py:7791-7803`); live smoke: API keys present without re-entry |
| Same path and staging | unchanged conductor staging | the launch report prints the live path |
| Same user data | first-party `DEBUG` keeps the debug data paths | smoke: the same workspaces and sessions are listed; `rpce-cli-debug -e 'windows'` connects |
| Lane label | provenance and `RepoPromptBuildLane.current` | both say `debug-optimized` |

A rebuild changes the cdhash in both lanes, as today. Keychain access follows the designated requirement, so no new prompt is expected.

### 12. Measurement labeling

- **Bundle:** the provenance keys from §4.9, plus the existing `commit` and `dirty`.
- **Process:** `buildLane` from the diagnostics `ping`.
- **Evidence rule** (goes into `development.md`):
  - every timing sample records `buildLane` from the running process;
  - `commit` and `dirty` come from the bundle's provenance file, and count only if the bundle's executable has not changed since the process started. Check this at capture start and end, the way `Scripts/live_codemap_authority_e2e.py:600-625` binds a process to its executable and provenance bytes;
  - samples from different lanes or commits are never pooled, and a bundle replaced during a capture invalidates it.

## File-by-file impact

| File | Change |
|---|---|
| `Package.swift` | Gate, helper, applied at `:88`, `:210`, `:218`, `:238`, and on the executable target when the gate is on |
| `Packages/RepoPromptCore/Package.swift` | `import Foundation`, gate, helper at `:25`, `:36`, `:49` |
| `Packages/RepoPromptAgentProviders/Package.swift` | `import Foundation`, gate, helper at `:17` |
| `Scripts/canonical_swift.sh` | Internal lane flag: rules, gate injection, scratch path |
| `Scripts/package_app.sh` | §4 items 1–11 |
| `Scripts/verify_build_lane_flags.py` (new), `Scripts/test_verify_build_lane_flags.py` (new) | §5 |
| `Scripts/conductor.py` | §6: parsing, mapping, helper parameter, timeout, protocol bump, lane line in `provenance_report_lines`, help |
| `Scripts/build_swiftpm_release_products.sh` | One top-level `unset RPCE_OPTIMIZED_DIAGNOSTICS` (§4 item 2) |
| `Scripts/test_conductor_lifecycle.py` | Lane parsing and mapping, rejection, helper pass-through, request-key distinction, no passthrough, pre-activation failure leaves the live bundle untouched; protocol assertion 17 → 18 (`:96`). Update any help or output snapshot in `Scripts/test_conductor_output.py` that the new help text changes. |
| `Scripts/test_debug_dsym.py` | Lane argv keeps full symbols; debug policy unchanged |
| `Scripts/test_release_tooling.py` | Release commands never receive the gate or the lane prefix; provenance additions |
| `Makefile` | `OPTIMIZED=1`, help, verifier selftest |
| `Packages/RepoPromptCore/Sources/RepoPromptShared/RepoPromptBuildLane.swift` (new); `Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugTransportDiagnostics.swift` (`debugPingPayload`) | §7 |
| `docs/context/workflows/development.md` | "Optimized diagnostics lane (opt-in)" subsection: commands, per-invocation selection, costs (labeled unmeasured), the heavy-slot note, timeout and supersession behavior, §10 differences, the §12 evidence rule, the metrics filter, the `./conductor build` in-place warning, the probe compatibility-link note, rollback. Also update the protocol number at `:23`. |

**Explicitly unchanged:** `release.sh`, `install_local_production.sh`, `build_swiftpm_release_products.sh` (apart from the one `unset` line), the Info.plist and entitlements templates, `RuntimeCodeSigningPolicy.swift`, Sparkle, the XCTest ledger, and application persistence.

## Validation

0. **Baseline, before step 1 lands.** Save to the evidence directory:
   - gate-off `swift package dump-package` output for the root and both sub-packages;
   - the per-module compile-argument sets from `.build/debug.yaml`.
1. **Static, before compiling.** Done 2026-10-16: no `@testable` and no `_is*AssertConfiguration()` in production sources. At implementation time:
   - repeat that check;
   - spot-check side-effecting `assert(` calls;
   - search the dependency checkouts for public declarations inside `#if DEBUG` that first-party code references.
2. **Manifest neutrality.** Gate off: `dump-package` for all three packages must be byte-identical to the step-0 baseline. Gate on (the wrapper accepts only `build`, so call Swift directly): `env RPCE_OPTIMIZED_DIAGNOSTICS=1 swift package --package-path <pkg> dump-package` must show the defines on the §2 targets only.
3. **Selftests:** `make conductor-selftest` (including the verifier selftest), `python3 Scripts/test_debug_dsym.py`, and `make release-selftest`.
4. **Compile and package — go/no-go.** `SIGN_IDENTITY=… REPOPROMPT_DEBUG_APP_BUNDLE=/tmp/rpce-opt-probe/RepoPrompt.app ./conductor build --optimized`, to a scratch bundle and not `/Applications`.
   - The verifier passes, and its §5 assumptions are confirmed.
   - Record the cold build time and disk use; set the lane timeout to twice the cold time.
   - Note: probe builds repoint the `.build/debug/RepoPrompt.app` compatibility link at the probe until the next `app relaunch` or `launch-existing` repairs it.
   - Make a one-line RepoPromptApp edit, rebuild, and record the incremental time.
   - **Stop and report to the owner.**
5. **Identity** on the probe bundle (built with `SIGN_IDENTITY`): the §11 proof column. Diff its Info.plist against a debug-lane probe built the same way; only the build number and timestamps may differ.
6. **Default lane unchanged:**
   - `./conductor build` to a scratch bundle gives provenance `buildLane = debug`, and the per-module compile arguments in `.build/debug.yaml` match the step-0 baseline, apart from source-driven changes;
   - `make dev-test FILTER=<small existing suite>` passes;
   - `.build/optimized-diagnostics/` is not touched by debug jobs.
7. **Guardrails and lint:** `make guardrails`, `make dev-lint`, `make xcode-generator-test` (the generator reads `Package.swift`), `Scripts/check-agent-context`.
8. **Launch smoke, with explicit owner approval at that moment.** Run `SIGN_IDENTITY=… REPOPROMPT_DEBUG_APP_BUNDLE="/Applications/RepoPrompt CE Dev.app" ./conductor app relaunch --optimized`. Then check that:
   - the launch report says `debug-optimized`;
   - `rpce-cli-debug -e 'windows'` connects;
   - the diagnostics `ping` returns `buildLane: debug-optimized`;
   - perf diagnostics turn on through `app_settings`;
   - API keys are present without re-entry;
   - existing workspaces and sessions are listed.
9. **Fair speed comparison** (advisory; noisy host):
   - use the same commit with `dirty = false`;
   - run blocks in A-B-A order (debug, optimized, debug), each block one approved relaunch;
   - use the perf spec's W1–W3 workloads on the same data;
   - discard the first iteration after launch, and take at least 5 samples per block;
   - record host load with each sample;
   - report per-block medians and spread. The drift between the two debug blocks bounds how far the comparison can be trusted;
   - use Instruments for visible-frame timing.

## Risks

Severity uses the review-policy scale for developer tooling.

| ID | Sev | Failure scenario | Mitigation / residual |
|---|---|---|---|
| R1 | P1, mitigated | `DEBUG` leaks into a production-identity build. | The gate is reachable only through the wrapper flag behind `env -i`; it is not a passthrough key; `package_app.sh` and `build_swiftpm_release_products.sh` unset it; release selftests assert it is absent. Residual P2: a hand-run `swift build -c release` with the variable exported. |
| R2 | P1, mitigated | An older daemon ignores `optimized`, builds debug, and the owner believes it is optimized. | Protocol bump; the provenance and runtime label show the truth. |
| R3 | P1, mitigated | Sub-package manifests are not re-evaluated, so Core or AgentProviders build without `DEBUG`: diagnostics missing, or a helper/app mismatch. | The verifier fails closed; fallback `--manifest-cache none` for the lane only. |
| R4 | P1, mitigated | The lane's patch helper targets the default checkout, so the packaged app's KeyboardShortcuts resources break. | The scratch path is passed to the helper; the launch smoke exercises the app. |
| R5 | P2 | The first `-O` + `DEBUG` compile fails: first-party `DEBUG` code has never been compiled with `-O`, or it uses a dependency's `DEBUG`-only API. Or whole-module optimization is extremely slow in `DEBUG` code. | Validation step 1 search; go/no-go at validation step 4. |
| R6 | P2 | The optimizer exposes a latent race, or a lifetime assumption (shorter ARC lifetimes), and the daily app crashes. First-party `DEBUG` code has never run under `-O`. | Shipped users already run the non-`DEBUG` code under `-O`. Rollback: relaunch without the flag. |
| R7 | P2 | `assert` side effects are skipped. | Static spot check in validation step 1. |
| R8 | P2, existing | `./conductor build --optimized` with `REPOPROMPT_DEBUG_APP_BUNDLE=/Applications/…` rewrites the live bundle under a running app. | Same as today's `build`; documented; use `app relaunch`. |
| R9 | P3 | Extra disk use, full-dSYM time, a second dependency checkout. | Accepted. The lane's folder can be deleted when no conductor job is running. |
| R10 | cost | The edit-relaunch loop in this lane takes minutes. | Debug stays the default. |
| R11 | P2 | A lane build holds the machine-wide heavy slot for minutes, and parallel agent builds and tests wait. | Documented (§9); build the lane at natural break points. |
| R12 | P2 | A cold build overruns the timeout, or a stop or relaunch supersedes it mid-compile, and a retry starts the whole-module compile from zero. | Timeout set from the measured cold time; the message names `--timeout`; documented (§6). The live bundle is never touched. |

**Rollback:**
1. Relaunch without `--optimized`, with owner approval. This restores the plain Dev app with the same data and Keychain service.
2. `git revert` the lane commits.
3. Optionally delete `.build/optimized-diagnostics/` while no conductor jobs are running.

No data migration is involved.

**Effort** (agent time, estimated): about 2–4 days in total.

| Work | Time |
|---|---|
| Manifests, wrapper, verifier | ~0.5–1 day |
| `package_app.sh` | ~0.5 day |
| Conductor, selftests, Makefile, docs | ~0.5–1 day |
| First compile and fixes | unknown: 1 hour to 1 day |
| Runtime label | ~2 hours |
| Validation and A-B-A measurement | ~0.5 day, plus 3–4 owner-approved relaunches |

## Implementation steps

Each step compiles and passes its tests on its own.

1. **Manifests and wrapper** (§2, §3), landed together. Gate off is a no-op, proven by validation step 2.
2. **Verifier and its selftest** (§5).
3. **`package_app.sh`** (§4).
4. **Conductor `build --optimized`, protocol bump and selftests.** Then validation steps 3–7. **Go/no-go: report to the owner.**
5. **Conductor `run` / `app relaunch --optimized`**, the helper parameter, timeout and launch report.
6. **Runtime label** (§7).
7. **Makefile and `development.md`.**
8. **Launch smoke and A-B-A measurement** (validation steps 8–9), as owner-approved actions.

Status:
- Step 1 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 2 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 3 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 4 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 5 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 6 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 7 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 8 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Spec — done (awaiting owner approval) | rounds 1/2 | open: | downgraded: | assumed: assertions off; per-invocation selection; separate build folder | deferred:

## Decisions

- Owner Decision (2026-10-16): Merge the OracleA and OracleB recommendations into one spec, have both Oracles review it once, and show the final spec before implementation.
- Owner Decision (2026-10-16): Include the build-plan flag verifier and the running-app build-lane label.

Evidence: `docs/reviews/2026-10-12-agent-mode-transcript-refresh-performance/optimized-lane-spec-*.md`.
