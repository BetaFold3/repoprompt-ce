# Optimized-diagnostics Dev lane — technical spec

Scope: read when the task touches an optimized (`-c release`) build of the CE Dev app that keeps first-party `DEBUG` diagnostics, the `RPCE_OPTIMIZED_DIAGNOSTICS` manifest gate, `canonical_swift.sh --rpce-optimized-diagnostics`, `package_app.sh debug-optimized`, `./conductor build|run|app relaunch --optimized`, `Scripts/verify_build_lane_flags.py`, or `RepoPromptBuildLane`.
Authority: Reference
Last-verified: 2026-10-16

Status: proposed. Merged from independent OracleA and OracleB recommendations, then reviewed once by both (round-1 findings applied 2026-10-16). Refreshed 2026-10-16 against the merged incremental debug packaging (merge `0d4ed733`; owner documentation in `docs/context/workflows/development.md` → "Debug packaging"), then re-reviewed by both (round 2: both approved; P3 clarifications applied). Implementation waits for the owner. Building it reverses the 2026-10-14 owner decision "Leave build tooling unchanged" for this lane only.

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
| Provenance readers check only the fields they need, so additive keys are safe. The debug package input key never hashes the generated provenance bytes, and a reused bundle keeps them. | `Scripts/conductor.py:7743-7760`; `Scripts/live_codemap_authority_e2e.py:547-561`; `Scripts/debug_package_cache.py:633-646` (`compute_keys` docstring); `development.md` → "Debug packaging", Provenance |
| `PROTOCOL_VERSION = 18`: the packaging work bumped it to forward `REPOPROMPT_DEBUG_PACKAGE_CACHE`. `package_debug_app_under_heavy` has one caller, names the live bundle as `REPOPROMPT_DEBUG_APP_REUSE_SOURCE`, and runs `package_app.sh debug` as a literal. | `Scripts/conductor.py:181`, `:7901`, `:7906`, caller `:8102` |
| `run` today treats every token after `run` as an app argument, with or without `--`. | `Scripts/conductor.py:8882-8884` |
| Debug packaging (merged 2026-10-16): the debug branch runs **one** product-less build; host-native release keeps its three `--product` builds in its own `IS_RELEASE` branch; both share the bin-path query. Every reuse path (hidden-sibling publish, signed-component cache, bundle stamps, `noop-dest`/`noop-clone`) is gated on `IS_RELEASE=0`; every outcome runs the full checks; `fast` is an inert alias. | `Scripts/package_app.sh:360-375`, `:377-379`; `development.md` → "Debug packaging" |
| The package input key hashes the `CONF` field, the stat records of the three products, the Sparkle and resource-bundle manifests from `BUILD_DIR`, the signing policy, the control scripts and the Git state. Helper and Sparkle component keys also come from `BUILD_DIR`. The cache root `.build/debug/package-cache/v1/` is fixed. | `Scripts/debug_package_cache.py:129-143` (`PLAN_FIELDS`), `:633-674`; `package_app.sh:529` (`--field CONF`) |
| The cache's completeness test fails unless every script reference, `$ROOT_DIR` path, `REPOPROMPT_*` token and defaulted environment read in `package_app.sh` (and, transitively, in its input scripts) is classified as a key input or an exclusion with a reason. | `Scripts/test_debug_package_cache.py:803-880` (`ClosureTests`); lists at `Scripts/debug_package_cache.py:101-202` |
| Packaging text is pinned: the exact debug build line, the three release build lines, six `"$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build` references, and a fake-command matrix per configuration. | `Scripts/test_release_tooling.py:1775-1805`, `:1807` onward, `:2569-2573` |
| `package_app.sh` uses `CONF` in the failure hint, the cache-escape gate, the Sentry symbols folder, `IS_RELEASE`, `SWIFT_BUILD_ARGS`, the phase labels, the bin-path query, the compatibility link and the plan's `--field CONF`. | `Scripts/package_app.sh:157`, `:173`, `:195`, `:198`, `:335`, `:361-373`, `:378-379`, `:388`, `:529` |
| The KeyboardShortcuts patch helper already takes a scratch path through `REPOPROMPT_SWIFTPM_SCRATCH_PATH`, and the public release builder already uses that pattern. | `Scripts/patch_keyboard_shortcuts_resource_lookup.sh:11-12, 34-38`; `Scripts/build_swiftpm_release_products.sh:89-97` |
| `canonical_swift.sh` runs Swift under `env -i` with an allow-listed environment, because SwiftPM keys its caches on the exact environment. | `Scripts/canonical_swift.sh:1-37`, `:122` |
| Secure-storage trust depends on the signing-mode marker, the storage marker, the bundle ID and the team allowlist. It does not depend on `#if DEBUG` or on optimization. | `Sources/RepoPromptPlatform/Infrastructure/Security/RuntimeCodeSigningPolicy.swift:110-130`, `:241-276` |
| The debug-diagnostics `ping` op is the natural place for a lane label. The handler file is `#if DEBUG`. | Dispatch: `Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift:6, 28-29`. Payload: `MCPConnectionManager+DebugTransportDiagnostics.swift:55` (`debugPingPayload`) |
| The build plan also contains test modules (`RepoPromptTests`, the generated `RepoPromptCEPackageTests`) and third-party test kits. | `.build/debug.yaml` module names |
| First-party C targets have no plain `DEBUG` checks, only specific debug switches (`DEBUG_SEARCH`, `DEBUG_FRAMES_DISPLAY`, `DEBUG_SHOW_*`). | `Sources/RepoPromptC/src/Utils/path_search.c:13`; `Sources/CSwiftPCRE2/src/pcre2_match.c:52-56` |
| Packaging's debug team check only requires a non-empty team. Runtime keychain trust also requires an allow-listed team. | `Scripts/package_app.sh:814-816`; `RuntimeCodeSigningPolicy.swift:111-114` |
| Conductor job records carry the request `args`. | `Scripts/conductor.py:2917`, `:4383` |
| The protocol number is pinned in two tests. The docs name the minimum protocol per feature (`:23` index store needs 17; `:118` package-cache forwarding from 18). The Xcode workspace generator runs `swift package dump-package` on `Package.swift`. | `Scripts/test_conductor_lifecycle.py:97`; `Scripts/test_conductor_output.py:971`; `docs/context/workflows/development.md:23`, `:118`; `Scripts/generate_xcode_workspace.py:62` |
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

1. **CONF validation.** Accept only `debug | release | debug-optimized`, right after the package-mode check (`:163-169`) and before the cache-escape check (`:172-178`), and update the usage text to `[debug|debug-optimized|release] [fast]`. Today an unknown `CONF` fails later inside Swift.
2. **Top-level `unset RPCE_OPTIMIZED_DIAGNOSTICS`.** Defence in depth for paths that bypass the wrapper, such as the patch helper's direct `swift package resolve`. Add the same one-line `unset` at the top of `Scripts/build_swiftpm_release_products.sh`, which can also be run on its own and calls Swift directly (`:89-121`). This is behavior-neutral for the release lane.
3. **Derived variables**, placed next to `IS_RELEASE`:

   | Variable | `debug` | `debug-optimized` | `release` |
   |---|---|---|---|
   | `BUILD_LANE` | `debug` | `debug-optimized` | `release` |
   | `SWIFT_CONF` | `debug` | `release` | `release` |
   | `CANONICAL_PREFIX` (array) | empty | `(--rpce-optimized-diagnostics)` | empty |
   | `IS_RELEASE` | 0 | **0** | 1 |

   `IS_RELEASE` stays `CONF == "release"`. That single fact routes the lane through every existing debug branch: bundle ID and URL scheme, signing, storage marker, provenance, the single product-less build, hidden-sibling assembly and publish, the package cache and bundle stamps, the full checks, `sign_path` debug arguments, and the debug team check. The cache escape (`:173`) also applies, because it tests `CONF != release`.
4. **Lane preconditions**, checked before any build:
   - `SIGN_IDENTITY` is explicit, not ad hoc, and begins with `Apple Development:`;
   - the resolved bundle ID equals `com.pvncher.repoprompt.ce.debug` (reject `BUNDLE_ID` / `DEBUG_BUNDLE_ID` overrides);
   - `REPOPROMPT_ENABLE_SENTRY` and `REPOPROMPT_UPLOAD_SENTRY_SYMBOLS` are unset.
5. **Dependency patch:** run the KeyboardShortcuts helper with `REPOPROMPT_SWIFTPM_SCRATCH_PATH="$ROOT_DIR/.build/optimized-diagnostics"` for the lane. Other lanes are unchanged.
6. **Build calls:**
   - `SWIFT_BUILD_ARGS=(-c "$SWIFT_CONF")` (`:335`). The value is unchanged for `debug` and `release`;
   - only the debug branch's single product-less build (`:374`) gains the prefix: `run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" ${CANONICAL_PREFIX[@]+"${CANONICAL_PREFIX[@]}"} build "${SWIFT_BUILD_ARGS[@]}"`. That expansion is safe for an empty array under `set -u` in bash 3.2. The release branch's three `--product` builds (`:360-368`) are not edited;
   - the shared bin-path query (`:378-379`) hardcodes `-c "$CONF"` in both its `echo_cmd` and the real call. Both lines switch to the prefix plus `-c "$SWIFT_CONF"`; for `release` the expanded command is unchanged;
   - phase labels are unchanged: `($CONF, host-native)` already prints `debug-optimized` for the lane.
   - **Pinned tests, updated deliberately with equal strength** (`Scripts/test_release_tooling.py`):
     - the exact debug build line (`:1791`) becomes the prefixed line; the debug branch still has exactly one `canonical_swift.sh` call and no `--product`, and the release branch contains no `CANONICAL_PREFIX`;
     - the count of six build references (`:2569-2573`) keeps counting six `canonical_swift.sh` build invocations with a pattern that admits the prefix, and additionally asserts that the exact string `${CANONICAL_PREFIX[@]+"${CANONICAL_PREFIX[@]}"} build` appears exactly three times: the debug build, the bin-path `echo_cmd` line and the executed bin-path query;
     - the fake-command matrix (`test_host_native_build_commands_differ_only_between_debug_and_release`, `:1807`) gains a `debug-optimized` case with `SIGN_IDENTITY="Apple Development: Stub"` and no `ALLOW_ADHOC_SIGNING`, which the lane preconditions require. The stub records the lane flag and `-c release` on the build and on the one executed bin-path query. The echoed bin-path command never invokes the stub (`echo_cmd`, `package_app.sh:71-75`), so it is asserted in captured stdout. The patch stub logs `$REPOPROMPT_SWIFTPM_SCRATCH_PATH` only when it is set, so the `debug` and `release` cases stay unchanged. The phase label is `Building debug products (debug-optimized, host-native)`; the phase summarizer already counts it as a build phase, because it matches the `Building ` prefix (`summarize_package_phases.py:30`, `:99`).
7. **Verifier:** for `debug-optimized` only, after the `BUILD_DIR=` printout (`:391`) and before `Computing debug package keys` (`:512-517`), so it runs on every lane package, including `noop-dest` and `noop-clone`. A static test in `test_release_tooling.py` pins that order and keeps the call outside any `DEBUG_PACKAGE_REUSED` block, because the verifier's closure exclusion (item 10) relies on it:
   - fail unless `BUILD_DIR` lies under `$ROOT_DIR/.build/optimized-diagnostics/`;
   - run `python3 "$CONTROL_PLANE_SCRIPTS_DIR/verify_build_lane_flags.py" --build-yaml "<scratch>/release.yaml"`, deriving `<scratch>` from `BUILD_DIR` (`BUILD_DIR/../..`).

   A failure fails packaging.
8. **Compatibility link:** use `.build/debug/$APP_NAME.app` (`:388`) for both debug lanes, never `.build/debug-optimized/…` or `.build/release/…`. That matches the conductor's hardcoded repair path, and it never removes the local-production bundle.
9. **Provenance:** add keys to the payload of the debug provenance writer (`:708`, phase `Writing debug bundle provenance`, which now takes Git state from the plan) and keep `"version": 1`. A reused bundle keeps its provenance bytes; that stays correct because the input key includes `CONF`, so reuse never crosses lanes.

   | Key | `debug` | `debug-optimized` |
   |---|---|---|
   | `buildLane` | `"debug"` | `"debug-optimized"` |
   | `swiftConfiguration` | `"debug"` | `"release"` |
   | `optimization` | `"Onone"` | `"O"` |
   | `assertConfiguration` | `"Debug"` | `"Release"` |
   | `laneFlagsVerified` | `null` | `true` |

   These keys, the `ping` field (§7) and the help text are the default lane's only output changes, and all are additive.
10. **Package cache and reuse: no lane-specific cache code.** The lane shares `.build/debug/package-cache/v1/` and the `fresh` / `noop-dest` / `noop-clone` outcomes. The bundle input key hashes `CONF`, so a bundle stamp never crosses lanes: switching lanes at the same destination always packages `fresh`, and `noop-clone` only clones a bundle of the same lane. Signed Sparkle and helper entries are keyed by the signing policy and the stat records (including inode and ctime) of each lane's own build outputs, so in practice each lane signs its own copies; equal component keys would mean equivalent inputs, and sharing those is safe. Alternating lanes can prune the other lane's signed helper entries (the cache keeps the two newest per component), which costs a re-sign but never correctness. `fast` is an inert alias in both lanes.

    **Closure registration.** Two `CLOSURE_EXCLUSIONS` entries in `Scripts/debug_package_cache.py` keep the completeness test passing:
    - `verify_build_lane_flags.py`: "lane-only build-plan check; runs on every lane package before the plan; no output effect". As an exclusion, verifier edits don't invalidate either lane's caches;
    - `REPOPROMPT_SWIFTPM_SCRATCH_PATH`: "lane scratch path for the KeyboardShortcuts patch helper; its effect reaches the key through the product stat records".
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
- after the single product-less build, `release.yaml` holds the whole default graph. That graph also contains a few small dependency-package example executables; they are third-party modules, so rule 4 applies to them;
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
- `build` (`conductor.py:8774-8779`): add `--optimized`. Set `args["optimized"] = True` **only when true**, so the default request's arguments and identity are unchanged.
- `run` (`:8882-8884`): if the first token is `--optimized`, consume it, then apply today's rule to the rest. Any other first token keeps today's meaning.
- `app relaunch` (`:8885-8896`): consume a leading `--optimized` before the `--` check. `app launch-existing --optimized` is rejected with: "launch-existing does not build; its lane is whatever the bundle was packaged with (see RepoPromptDebugProvenance.json)."

**Daemon:**
- `build` (`:3165-3168`) maps to `[package_app.sh, "debug-optimized" if optimized else "debug"]`, plus the inert `fast` as today.
- `package_debug_app_under_heavy(repo_root, operation_label, package_config="debug")` (`:7887-7922`):
  - raises `ConductorError` unless `package_config` is `debug` or `debug-optimized`;
  - replaces the `"debug"` literal in its `package_app.sh` argv (`:7906`) with `package_config`;
  - its only caller, `operation_debug_app_build_then_launch` (`:8102`), passes `debug-optimized` when `args.get("optimized")`.
  - Staging, swap, activation, the reuse-source line (`:7901`) and the compatibility-link repair are unchanged. A staged `run --optimized` therefore clones the live bundle only when it is a lane bundle with the same input key; otherwise it packages `fresh`.
- **Timeout:** an `optimized` request without an explicit `--timeout` uses `max(default, 3600)` seconds. Step 4 replaces 3600 with twice the measured cold-build time.
  - A timeout failure message names `--timeout <seconds>`.
  - A later `app stop` or `app relaunch` that supersedes an in-flight lane build discards that module's compile progress, because whole-module compiles have no partial results. The live bundle stays intact: `package_debug_app_under_heavy` cleans up staging (`:7887-7922`).
- **Protocol:** `PROTOCOL_VERSION` 18 → 19, so an idle older daemon is replaced, and a busy one is refused instead of silently dropping `optimized`. This is a deliberate contract update.
  - Main reached 18 with the packaging work. Two branches that each make the same bump merge without a conflict, so the implementer reads the current value first and bumps from it.
  - Update the pins `Scripts/test_conductor_lifecycle.py:97` (with a `# 19:` history comment) and `Scripts/test_conductor_output.py:971`.
  - `development.md`'s existing protocol sentences stay as they are (`:23`, `:118`); the new lane subsection states that `--optimized` needs protocol 19.
- **Environment:** `RPCE_OPTIMIZED_DIAGNOSTICS` is **not** a passthrough key (`OperationRegistry.PASSTHROUGH_ENV_KEYS`, `:3061`). A selftest asserts its absence.
- **Lane in reports:** `provenance_report_lines` (`:7743`) prints `build lane: <buildLane>`, or `unknown (pre-lane provenance)`. That covers both the launch report (`:7776-7778`) and `app status` (`:8145`), which share this function.
- **Metrics:** job records already carry `args` (`:2917`, `:4383`), so lane jobs are identifiable by `args.optimized`. `development.md` tells readers of `./conductor metrics` to filter by it, so minute-long lane builds are never pooled with debug builds.
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
| First (cold) build, including the default graph's small dependency example executables | ~10–25 min | — |
| One-line edit in RepoPromptApp (re-optimize module, relink, dSYM, package) | ~3–8 min | ~20–35 s |
| Edit in RepoPromptShared or AgentCore (cascades) | ~8–15 min | — |
| Extra disk (checkouts, objects, dSYMs) | ~3–6 GB | — |

**Heavy slot.** Packaging runs inside the machine-wide heavy slot (`conductor.py:7887-7910`; default one slot). A lane build holds it for minutes, so every coordinated build or test on the machine waits in `waiting-heavy-slot` meanwhile, agent `make dev-test` loops included.

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
| `RepoPromptDebugSecureStorageBackend = keychain` | explicit identity path; runtime trust unchanged. Keychain continuity holds when the marker is `keychain` and the signer's team is on the runtime allowlist (`RuntimeCodeSigningPolicy.swift:111-114`). Packaging checks only for a non-empty team (`package_app.sh:814-816`), exactly as the debug lane does today. An intentional in-memory override stays allowed and is not a failure. | `plutil` extract; the launch report's storage and team warnings (`conductor.py:7786-7805`); live smoke: API keys present without re-entry |
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
| `Scripts/conductor.py` | §6: parsing, mapping, helper parameter, timeout, protocol bump 18 → 19, lane line in `provenance_report_lines`, help |
| `Scripts/debug_package_cache.py` | Two `CLOSURE_EXCLUSIONS` entries (§4 item 10); no logic change |
| `Scripts/build_swiftpm_release_products.sh` | One top-level `unset RPCE_OPTIMIZED_DIAGNOSTICS` (§4 item 2) |
| `Scripts/test_conductor_lifecycle.py` | Lane parsing and mapping, rejection, helper pass-through (the staged package argv ends in `debug-optimized` and still sets the reuse source), request-key distinction, no passthrough, pre-activation failure leaves the live bundle untouched; protocol assertion 18 → 19 (`:97`). |
| `Scripts/test_conductor_output.py` | Protocol assertion 18 → 19 (`:971`); any help or output snapshot the new help text changes |
| `Scripts/test_debug_dsym.py` | Lane argv keeps full symbols; debug policy unchanged |
| `Scripts/test_release_tooling.py` | The three pin updates in §4 item 6; the verifier-order check (§4 item 7); release commands never receive the gate or the lane prefix; provenance additions |
| `Makefile` | `OPTIMIZED=1`, help, verifier selftest |
| `Packages/RepoPromptCore/Sources/RepoPromptShared/RepoPromptBuildLane.swift` (new); `Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugTransportDiagnostics.swift` (`debugPingPayload`) | §7 |
| `docs/context/workflows/development.md` | "Optimized diagnostics lane (opt-in)" subsection: commands, per-invocation selection, costs (labeled unmeasured), the heavy-slot note, timeout and supersession behavior, §10 differences, the §12 evidence rule, the metrics filter, a pointer to the running-app caution under "Debug packaging" → Publish (instead of a new warning), the shared package cache and lane separation (one sentence), the probe compatibility-link note, rollback, and that `--optimized` needs protocol 19. The existing protocol sentences (`:23`, `:118`) are not edited. |

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
3. **Selftests:** `make conductor-selftest` (including the verifier selftest), `python3 Scripts/test_debug_dsym.py`, `make release-selftest`, and `cd Scripts && python3 -m unittest test_debug_package_cache` (the closure test; no `make` target runs it).
4. **Compile and package — go/no-go.** `SIGN_IDENTITY=… REPOPROMPT_DEBUG_APP_BUNDLE=/tmp/rpce-opt-probe/RepoPrompt.app ./conductor build --optimized`, to a scratch bundle and not `/Applications`.
   - The verifier passes, and its §5 assumptions are confirmed.
   - Record the cold build time and disk use; set the lane timeout to twice the cold time.
   - Note: probe builds repoint the `.build/debug/RepoPrompt.app` compatibility link at the probe until the next `app relaunch` or `launch-existing` repairs it.
   - Make a one-line RepoPromptApp edit, rebuild, and record the incremental time.
   - Rebuild once more with no change: the plan line reports `noop-dest`.
   - **Stop and report to the owner.**
5. **Identity** on the probe bundle (built with `SIGN_IDENTITY`): the §11 proof column. Diff its Info.plist against a debug-lane probe built the same way; only the build number and timestamps may differ.
6. **Default lane unchanged:**
   - `./conductor build` to a scratch bundle gives provenance `buildLane = debug`, and the per-module compile arguments in `.build/debug.yaml` match the step-0 baseline, apart from source-driven changes;
   - `make dev-test FILTER=<small existing suite>` passes;
   - `.build/optimized-diagnostics/` is not touched by debug jobs;
   - lane separation: a plain `./conductor build` into the same scratch path right after a lane build reports `fresh`, never `noop-dest`, and its provenance says `debug`.
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
| R2 | P1, mitigated | An older daemon ignores `optimized`, builds debug, and the owner believes it is optimized. A second branch's identical protocol bump merges silently and has the same effect. | Protocol bump from the current value (18 → 19), checked at implementation time; the provenance and runtime label show the truth. |
| R3 | P1, mitigated | Sub-package manifests are not re-evaluated, so Core or AgentProviders build without `DEBUG`: diagnostics missing, or a helper/app mismatch. | The verifier fails closed; fallback `--manifest-cache none` for the lane only. |
| R4 | P1, mitigated | The lane's patch helper targets the default checkout, so the packaged app's KeyboardShortcuts resources break. | The scratch path is passed to the helper; the launch smoke exercises the app. |
| R5 | P2 | The first `-O` + `DEBUG` compile fails: first-party `DEBUG` code has never been compiled with `-O`, or it uses a dependency's `DEBUG`-only API. Or whole-module optimization is extremely slow in `DEBUG` code. | Validation step 1 search; go/no-go at validation step 4. |
| R6 | P2 | The optimizer exposes a latent race, or a lifetime assumption (shorter ARC lifetimes), and the daily app crashes. First-party `DEBUG` code has never run under `-O`. | Shipped users already run the non-`DEBUG` code under `-O`. Rollback: relaunch without the flag. |
| R7 | P2 | `assert` side effects are skipped. | Static spot check in validation step 1. |
| R8 | P2, existing | `./conductor build --optimized` into the running app's destination (for example `REPOPROMPT_DEBUG_APP_BUNDLE=/Applications/…`) publishes by swapping the bundle out from under it, so the app keeps running a deleted executable that a later stop cannot detect. | Same as today's `build`; already documented under "Debug packaging" → Publish, which the lane subsection points to; use `run` or `app relaunch` for the live app. |
| R9 | P3 | Extra disk use, full-dSYM time, a second dependency checkout. | Accepted. The lane's folder can be deleted when no conductor job is running. |
| R10 | cost | The edit-relaunch loop in this lane takes minutes. | Debug stays the default. |
| R11 | P2 | A lane build holds the machine-wide heavy slot for minutes, and parallel agent builds and tests wait. | Documented (§9); build the lane at natural break points. |
| R12 | P2 | A cold build overruns the timeout, or a stop or relaunch supersedes it mid-compile, and a retry starts the whole-module compile from zero. | Timeout set from the measured cold time; the message names `--timeout`; documented (§6). The live bundle is never touched. |
| R13 | P3 | In a checkout that has never had a default debug build, lane packaging creates `.build/debug` as a real directory (the package-cache root and the compatibility link), where SwiftPM normally keeps a symlink; a later default debug build may then fail or replace it. The owner's main checkout already has the symlink. | Run one default debug build first in a fresh worktree. Recovery: `rm -rf .build/debug` while no conductor job runs (it costs only cache speed). |

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
4. **Conductor `build --optimized`, protocol bump (18 → 19) and selftests.** Then validation steps 3–7. **Go/no-go: report to the owner.**
5. **Conductor `run` / `app relaunch --optimized`**, the helper parameter, timeout and launch report.
6. **Runtime label** (§7).
7. **Makefile and `development.md`.**
8. **Launch smoke and A-B-A measurement** (validation steps 8–9), as owner-approved actions.

Status:
- Step 1 — done | rounds 0/2 | open: | downgraded: | assumed: assertions off and isolated scratch as approved | deferred: S1-P3-1 allowlist; S1-P3-4 gate-copy static test; optimized compile to Step 4; pre-existing release-selftest lint assertion (optimized-lane-step1-review.md)
- Step 2 — done | rounds 0/2 | open: | downgraded: | assumed: literal no-DEBUG rule includes dormant tests | deferred: real optimized-plan validation to Step 4 (optimized-lane-step2-review.md)
- Step 3 — done | rounds 0/2 | open: | downgraded: | assumed: explicit Apple Development name as specified | deferred: real caller environment to Step 4; SHA1 identity selection only if needed; baseline release-selftest lint assertion (optimized-lane-step3-review.md)
- Step 4 — done | rounds 0/2 | open: | downgraded: | assumed: build/packaging go only; default timeout remains 3600s | deferred: runtime acceptance Step 8; disk 7.0 GiB (8.9 GB free); optional SIGKILL-hint test/display label; baseline lint assertion (optimized-lane-step4-review.md, optimized-lane-step4-warnings.md)
- Step 5 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 6 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 7 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Step 8 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:
- Spec — done (owner approved implementation) | rounds 2/2 | open: | downgraded: | assumed: assertions off; per-invocation selection; separate build folder | deferred:

## Decisions

- Owner Decision (2026-10-16): Implement Steps 1–4 one at a time with validation, OracleA/OracleB review and local commits; continue toward the remaining steps if build-time results show nothing unexpected. This authorizes the optimized-diagnostics lane in place of the earlier leave-tooling-unchanged decision; visible app lifecycle actions still require fresh approval.

- Owner Decision (2026-10-16): Merge the OracleA and OracleB recommendations into one spec, have both Oracles review it once, and show the final spec before implementation.
- Owner Decision (2026-10-16): Include the build-plan flag verifier and the running-app build-lane label.
- Owner Decision (2026-10-16): The incremental debug packaging merged first (merge `0d4ed733`). Refresh this spec against it, and have both Oracles, told of that merge, review the refresh and approve it before implementation.

Evidence: `docs/reviews/2026-10-12-agent-mode-transcript-refresh-performance/optimized-lane-spec-*.md`.
