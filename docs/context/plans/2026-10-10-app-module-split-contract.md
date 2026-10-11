# RepoPromptApp module split — work contract

Scope: read when the task touches splitting `RepoPromptApp` into new root-package targets, moving source between targets, the bridging header retirement, or hoisting `AgentModeViewModel` nested types for that split.
Authority: Reference
Last-verified: 2026-10-10

## Goal
Split the single `RepoPromptApp` target (~694k lines) into layered modules so the dependency direction is enforced by the compiler: runtime and engine code cannot reach into views and view models, and each lower layer can be built and tested without the app. This is architecture work. It is not expected to make builds or the running app faster.

## Done when
- Five root-package targets exist; each depends only on its allowed lower modules:
  - `RepoPromptPlatform` (`Sources/RepoPromptPlatform/`): generic primitives, with no dependency on the other four.
  - `RepoPromptWorkspace` (`Sources/RepoPromptWorkspace/`): the workspace engine, depending on Platform.
  - `RepoPromptAgentCore` (`Sources/RepoPromptAgentCore/`): the agent runtime and AI, depending on Workspace and Platform.
  - `RepoPromptUI` (`Sources/RepoPromptUI/`): reusable UI, depending on Platform only.
  - `RepoPromptApp` (stays at `Sources/RepoPrompt/`): the composition root, depending on all four.
- Workspace and AgentCore never import UI. Domain-specific rendering adapters live in App.
- App keeps everything that owns windows, view models, settings, prompt/chat packaging, MCP server composition and window tools, approvals, and integrated diagnostics/benchmarks.
- Behavior, saved data, test discovery and tooling are unchanged:
  - the same suites and test names run;
  - `Scripts/Fixtures/test-suite-contract-ledger.tsv` is byte-identical;
  - Codable keys, UserDefaults and keychain identifiers, file names and wire formats are unchanged;
  - release packaging builds.
- The bridging header is gone. C code is reached through module imports.
- `source-layout.md` and the guardrails describe and check the new source roots.

## Non-goals
- Build-speed or runtime-speed wins: none is expected, and none is a success criterion.
- More than five modules, a separate MCP module, or a "Common" module.
- Swift 6 language mode, new concurrency settings, library evolution, or aggressive cross-module optimization.
- Redesigning transcript, session or lifecycle behavior.
- Moving tests into new test targets.
- Permanent layering-analysis tooling.

## Boundaries (need my approval)
- Any change to saved-data shapes, security behavior, run/session lifecycle or ordering, or actor isolation.
- A sixth module, or giving up on a module.
- Visible app launches, pushes, and release metadata, as stated in `AGENTS.md`.

## Budget
Advisory: several weeks of focused work, with AgentCore about half of it. Each slice is reviewed per the review policy. Stop and report if a slice runs past about 2× its expected size, or if it can only proceed by changing behavior.

## Facts
- `RepoPrompt` is a thin executable over the `RepoPromptApp` library target, and `RepoPromptApp` has no library product. Library targets link statically into one executable (`Package.swift:118–138`).
- The package-wide Swift 5 mode is set at `Package.swift:189`. `DEBUG`, `BareSlashRegexLiterals`, the bridging-header `unsafeFlags` and Sentry gating are set per target (`Package.swift:84–116`).
- One file-level dependency cycle covers about 561 files and 457k lines, about two-thirds of the app. It spans AgentMode, AI, MCP, WorkspaceContext, VCS, Settings and the App shell. Neither AI nor AgentMode can be extracted by folder. Source: the approximate name-matching inventory, `.agent-artifacts/swift-compile-time/split-guidance/boundary/inventory.md`.
- Of 597 runtime references to `AgentModeViewModel`, 526 are to `AgentModeViewModel.TabSession`, a 2,506-line `@MainActor final class … ObservableObject` nested in a view-model extension (`AgentModeViewModel+TabSession.swift:39–41`). It already talks to its owner through closures (`:79–80`). Only 16 bare uses of the view model itself remain, in 8 runtime files.
- `AI/Prompts` (excluding `AgentModePrompts.swift`) plus `AI/Pricing` is 46 files with no outbound app dependencies. It has 8 app importers and 5 test importers (inventory, "Prompts+Pricing").
- `Features/Search` is backed by WorkspaceContext (`source-layout.md:34`), so folders don't map one-to-one onto modules.
- The bridging header is the only place that declares the wildmatch/gitignore functions (`RepoPrompt-Bridging-Header.h:37–54`). It also covers tree-sitter grammar functions, ptrace/`PT_DENY_ATTACH`, and the RepoPromptC and PCRE2 headers. `Scripts/generate_xcode_workspace.py` currently requires `-disable-bridging-pch`.
- The type-name persistence grep (`NSKeyedArchiver`, `NSClassFromString`, `restorationClass`, `@objc(`) over app sources finds only `GlobalSettingsManager.swift:313`, a test-detection check that the split doesn't affect.
- Runtime performance: there is no expected benefit. Debug builds pay no cost. Release builds may lose some cross-module specialization. OracleE reports that SwiftPM 6.3.1 release builds use `-O` with whole-module optimization and default conservative cross-module optimization; that has not been checked locally.

## Directions (ranked)
1. **Repair in place, then cut.** For each module, first untangle the code inside the single `RepoPromptApp` target, so it still compiles and behaves the same: split mixed files, hoist nested types, inject values, and add narrow interfaces. Then move the files whole with `git mv` and add the target in one change. Place each file or declaration in the lowest module whose dependencies already sit at or below it. Anything that resists stays in App.
   - **Why:** every intermediate commit is shippable, and every slice is a useful stopping point.
   - **Kill:** a module can only be completed by moving a whole other subsystem down, by turning typed data into opaque blobs, or by changing behavior. In that case, stop at the last valid module.
2. **Folder-level moves with compile-error-driven fixing.**
   - **Why:** fastest on paper.
   - **Kill:** this already failed on paper. The crude pass left about 1,950 upward references and dragged benchmark code into Platform (`module-split-architecture/layers-pass2.txt`). Use it only for leaf folders whose dependencies are proven clean.

### Ground rules for every slice
- **Access:** `internal` stays the default. Use `package` only for declarations other targets actually use: start from the dependency scan's list of names that cross the boundary, then fix what the compiler reports. Add explicit `package init` only where the compiler asks for one. No `public` without an external need, no `open`, no `@_exported`, and no production `@testable`.
- **Each new target** copies the existing `DEBUG` and `BareSlashRegexLiterals` settings. Sentry settings go only to targets that reference Sentry. New targets are never products and never dynamic libraries.
- **Tests:** keep the one `RepoPromptTests` target and add each new module to its dependencies. A script adds `@testable import <module>` to every file that has `@testable import RepoPromptApp`. Don't move or rename tests or suites.
- **Hoisted nested types** get domain-prefixed top-level names, such as `AgentTabSession` and `AgentSourceItemsMutation`. A same-type typealias in the old place keeps existing spellings working until the AgentCore extraction finishes; remove it then.
- **Interfaces into App:** inject the existing instances and values. Add a narrow `@MainActor` protocol only for genuine app orchestration, such as an `AgentSessionHost` for the remaining view-model calls or an `AgentMCPHosting` capability implemented by the existing `ServerNetworkManager`. Keep synchronous calls synchronous. Don't add a service locator or a whole-view-model facade.
- **Settings and windows:** `GlobalSettingsStore`, `WindowStatesManager` and `WindowState` stay in App. Pass precise values, or forward live updates where a consumer needs them.
- **Diagnostics:** split recording mechanisms (Platform) from domain instrumentation (Workspace or AgentCore) and from collectors, benchmarks and reporting (App). Keep event names and enablement unchanged.
- **Extensions on system types** live once, in the lowest module that uses them.
- **Gates per slice:**
  - `make dev-build`;
  - `make dev-test FILTER=<affected suites>`;
  - at the end of the slice: `make dev-test`, `make guardrails` (with paths updated for the new roots), `Scripts/check-agent-context`, and a release build to catch `#if DEBUG` leaks;
  - test discovery compared before and after, and the ledger checksum unchanged.
  - Timing is advisory.

## Evidence directory
`.agent-artifacts/swift-compile-time/module-split-architecture/` (git-excluded). It holds the Oracle brief, both advisors' answers in summary, and the layering passes. The boundary inventory is in `.agent-artifacts/swift-compile-time/split-guidance/boundary/`.

## Slices

### Slice 1 — Pilot: seed `RepoPromptAgentCore` with Prompts + Pricing
Move `Infrastructure/AI/Prompts/**` (excluding `AgentModePrompts.swift`) and `Infrastructure/AI/Pricing/**`. Add their imports and the minimal `package` access. This proves the target, access, test-import and guardrail mechanics with almost no risk.

Intent: prove target, access, test-import and tooling mechanics on a dependency-free leaf. Budget used: about 2 hours of the ~0.5 day expected (cumulative: ~2 hours).

Result: moved all 46 files into `Sources/RepoPromptAgentCore/AI/{Prompts,Pricing}` with only `RepoPromptShared` as a dependency and about 30 declarations made `package`; build, focused suites, release packaging, lint and format pass, test discovery is unchanged (6464) and the ledger is byte-identical, so the mechanics work and Slice 2 follows.

Decisions: the new root mirrors the app path (`AI/Prompts`, `AI/Pricing`) to leave room for `AgentMode/` later; pre-existing `public` on `PromptFactory`/`CodeExamples` was left as is; test imports sit at SwiftFormat's sorted position rather than after the app import; guardrails only check the new root's existence, path and `@main`/fixture rules, not imports; Swift settings shared through `repoPromptLayerSwiftSettings`; evidence lives in the main checkout's `.agent-artifacts/.../module-split-architecture/slice1/`.

Step 1 — done | rounds 0/2 | open: | downgraded: | assumed: A1 | deferred: full `make dev-test` ran before the import lines were reordered (targeted suites rerun after)

### Slice 2 — `RepoPromptPlatform` and bridging-header retirement
- Move dependency-verified primitives in small groups: concurrency, process, regex, networking, filesystem primitives, syntax parsing, utilities, secure-storage mechanics, the PCRE2 wrapper and recording-level instrumentation.
- Give the wildmatch/gitignore functions a public `RepoPromptC` header, import the grammar modules, and add a narrow C shim for ptrace only if one is needed.
- Then remove the bridge and its flags, and relax the Xcode generator's flag requirement, in the same change.

Probe result: name-matching closure over the Platform candidate folders kept 77 of 118 files (16.7k lines) with no app dependencies, and every bridging-header group has a module route (wildmatch/gitignore need a new public `RepoPromptC` header, `ptrace` a C shim), so the direction holds; evidence `slice2-probe/`.

#### Step 2a — retire the bridging header in place
Intent: reach all C code through module imports inside `RepoPromptApp` before any C-using file moves. Budget used: about 1.5 hours (cumulative ~3.5 hours).

Result: deleted the bridging header and its flags; 13 Swift files now import `RepoPromptC`, `CSwiftPCRE2` or tree-sitter grammar modules, wildmatch/gitignore got a public `repo_gitignore.h`, and `ptrace(PT_DENY_ATTACH…)` moved unchanged into a `RepoPromptC` shim; build, focused suites, full tests (flaky suites pass alone), discovery and ledger are unchanged, so Step 2b follows. The Facts lines about the bridge are now historical.

Decisions: PHP/Ruby grammar call sites unwrap the non-const pointer with `guard let` (same nil behavior); `wildmatch.h` includes `repo_gitignore.h` so build trees with an older cached `RepoPromptC` module rebuild it — if a tree still reports `cannot find 'repo_wildmatch' in scope` after pulling, delete `.build/*/debug/ModuleCache/*/RepoPromptC-*.pcm`; the generator's bridge checks were removed, not inverted.

Step 2a — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-2 generator check against a returning bridge

#### Step 2b — create `RepoPromptPlatform`
Intent: move the dependency-closed generic primitives (minus app-specific files such as `Shortcuts.swift`). Budget used: about 1.75 hours (cumulative ~5.25 hours).

Result: moved 72 files (~15.5k lines: concurrency, process/CLI, regex, networking, filesystem primitives, secure storage, syntax queries, string/collection utilities, the PCRE2 wrapper) into `Sources/RepoPromptPlatform`, which depends only on `RepoPromptShared`, `RepoPromptC` and `CSwiftPCRE2`, with 347 compiler-driven `package` declarations; build, focused and full tests (only the known baseline failure persists), discovery, ledger and the universal release package pass, so Slice 2 is complete and Slice 3 follows.

Decisions: placement rule used — dependency-free files go to the lowest module unless they are UI or feature-domain code (`Shortcuts.swift`, `CodeMapSecureFileRemoval.swift`, `IgnoreDebugMetricsRecorder.swift`, `RemotePairing/RemoteScope.swift` stayed); product constants inside storage mechanics (`SecurityObfuscation`, `RuntimeCodeSigningPolicy`) moved with their Platform users; `GitignoreCompiler.swift` stayed because it calls the app-side metrics recorder; `StringExtensions.swift` imports AppKit explicitly; guard tests that scan source roots iterate `RepoRoot.librarySourceRoots`.

Step 2b — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: recording-level instrumentation and ~41 non-closed Platform candidates stay in App; check `String(reflecting:)` keys in `WorkspaceCodemap*` before Slice 4

### Slice 3 — `RepoPromptUI`
Move reusable components, markdown rendering, typography (`FontScaleManager`, `FontScalePreset`) and UI environment keys. Product-specific adapters stay in App. Small codecs and models that Workspace or AgentCore use move down rather than up.

Probe result: the name-closure scan over the 91 UI candidates (`Infrastructure/UI/**`, `FontScaleManager`, `FontPreset`) on the live tree closes 43 files / 6.2k lines as-is; removing the `GlobalSettingsStore` reads from typography, the code-font resolver, the tooltip modifier and the two markdown views lifts that to 67 files / 14.9k lines including all markdown, so the direction holds and starts with an in-place repair; the remaining 26 are agent, MCP, approval, mention and workspace-backed adapters that stay in App (evidence `slice3-probe/`).

#### Step 3a — settings seams in place
Intent: make typography, tooltips and markdown rendering independent of `GlobalSettingsStore` inside `RepoPromptApp`, with unchanged values, persistence and live updates. Budget used: about 1.25 hours including the probe (cumulative ~6.5 hours).

Result: `FontScaleManager` now persists through a three-call `FontScaleSettingsStoring` protocol bound once in `RepoPromptSwiftUIApp.init` (after telemetry start, before scenes), and a new `UIDisplayPreferences` observable receives `showTooltips` and the transcript code font from a `didSet` on the store's scalar preferences; the tooltip modifier and both markdown views read it, two unused store-reading helpers were deleted, and build, the affected suites (115 tests), format and lint pass, so Step 3b can move these files.

Decisions: forwarding through one observable instead of SwiftUI environment values, because environment injection would have to reach every window, popover and hosting-view root and a missed root would silently show defaults; the views now re-render only when the two forwarded values change, not on every settings change; unit tests run with the manager unbound and the preferences at their defaults, which no existing test depends on.

Step 3a — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: owner-approved smoke launch (font scale survives relaunch, app_settings font change, tooltips toggle, code font re-highlight) not run

#### Step 3b — create `RepoPromptUI` and move the closed set
Intent: move the files that close over Platform after 3a, with compiler-driven `package` access, test imports and tooling, as in Step 2b. Planned set: 67 files / ~14.6k lines (`slice3-probe/move3b.txt`); `CheckRecommendationsButton`, `NotificationsButtonView` and `SnippetPaletteHelper` close too but stay in App as product-feature UI.

Budget used: about 2.5 hours (cumulative ~9 hours).

Result: moved 66 files (~14.5k lines) into `Sources/RepoPromptUI`, which depends on no app module and only on the `Markdown`, `Neon` and `SwiftTreeSitter` packages, with 342 compiler-driven `package` declarations; build, the focused suites, the full suite (its failures match the Step 2a and 2b runs, and rerunning them leaves only the known baseline failure), identical discovery (6464 names), the unchanged ledger, format, lint, guardrails (A1 only) and the Xcode checks pass, and the universal release package build passes, so Slice 3 is complete and Slice 4 (Workspace) follows.

Decisions: `AgentSidebarSizing` moved back to App after review because only Agent views use it; the font-scale DEBUG instrumentation moved with typography as UI-domain instrumentation with unchanged event names; the declared-but-unused Platform dependency was dropped, to be added when UI code first needs Platform; no guardrail checks module dependencies yet, as decided in Slice 1.

Step 3b — done | rounds 0/2 | open: | downgraded: | assumed: A2 | deferred: OracleB F1 — `CodexAgentModeCoordinator` uses `MentionSuggestion` from UI; move `MentionModels` down during Slice 4/5

### Slice 4 — `RepoPromptWorkspace`
Move workspace context, indexing and search, VCS and worktrees, domain diff and edit operations, workspace persistence, and non-UI CodeMap and workspace-file code. Prompt packaging (`ChatPreset`, `CopyPreset`, `PromptSection`) and anything that needs `AIModel` stay above, with only their workspace-only parts extracted down.

Probe result: the name scan over the workspace seed (WorkspaceContext, VCS, FileSystem, Persistence, Diffing, Search, and non-view CodeMap/WorkspaceFiles/Workspaces code plus `StandardizedPath`, `SyntaxManager` and `CheckoutPathIdentity`; 235 files / 164k lines) closes only 74 files today, but its references outside the seed are just 39 names in 29 files used by 45 seed files — view-model convenience overloads, typed declarations living in view-model, prompt and diagnostics files, the search readiness call, worktree-startup and MCP diagnostics, MCP storage constants and DTO adapters, and preset persistence — so there is no kill result and the slice proceeds by in-place seams; the two `String(reflecting:)` sort keys compare values of one type, so their order holds if each type moves whole (evidence `slice4-probe/`).

#### Step 4a — model and view-model seams in place
Intent: hoist the typed declarations that workspace code uses out of view-model, prompt, AI-message and agent files into their own files, move view-model convenience overloads out of workspace files into App extensions, and put the search readiness wait and check behind a narrow protocol, with no behavior change. Budget used: about 2 hours including the probe (cumulative ~11 hours).

Result: hoisted 11 typed declarations (with the supporting types their stored members need) into their own workspace-side files with identical text, moved the separable view-model convenience members of `CodeMapExtractor`, `FileSearchActor`, `SortingUtils`, `DiffEncodingUtils` and the frozen path records into App adapter files under `Features/WorkspaceFiles/ViewModels/Adapters/`, spelled `TokenCalculationService`'s slice types directly, moved the `WorkspaceSelectionHost` conformance to an adapter, and put the search readiness calls behind `WorkspaceSearchReadinessProviding`; build, 25 affected suites (616 tests), format and lint pass, and the next step handles the diagnostics coupling.

Decisions: `FileSystemItemType` and `FileTreeItem` stay with the view models because their cases wrap them; view-model uses that are part of a type's core (`DiffParser`'s stored `WorkspaceFilesViewModel`, `CodeMapExtractor`'s renderer, `SearchFileDescriptor.init(file:)`) stay for the rescan to place.

Step 4a — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB F1 — frozen path-record adapter initializers need a verbatim `package` init at the cut (don't route through the re-standardizing public init); pre-existing dropped `isExplicitSubtree` in the short `generateFileTreeForRoots(option:)` overload

#### Step 4b — diagnostics seams in place
Intent: remove the three places where workspace code reaches app diagnostics — the worktree-startup recorder's benchmark-scope parameter, the file-system service's direct call into the MCP apply-edits rebase probe, and the binding projection's selected-files events that run through the agent perf logger — by passing values, a DEBUG observer the MCP diagnostics install, and a generic event-recording core split out of the agent perf logger, with event names and enablement unchanged. The remaining workspace diagnostics (edit-flow timing, worktree-startup instrumentation, MCP work counts, restore and root-load logs) already depend on nothing above the workspace and move with it.

Budget used: about 1.5 hours (cumulative ~12.5 hours).

Result: the worktree-startup recorder now takes plain values, the file-system service and the file-context store report publications through a DEBUG `WorkspacePublicationDebugObserver` that the MCP rebase probe installs on first registration (review found three store calls the intent had missed), and the generic recording core `PerfDiagnosticsRecorder` now lives in `RepoPromptPlatform` with the agent perf logger forwarding to it; a rescan finds no app diagnostics names left in the workspace seed paths, and build, 10 affected suites (305 tests, 0 failures), format and lint pass, so the next step plans the remaining non-diagnostics adapters from a rescan.

Decisions: the recorder moved to Platform now rather than at the cut, so the compiler already proves it independent; the agent perf logger keeps its own state under the recorder's lock through `withLockedState`, which keeps every snapshot and clear atomic as before.

Step 4b — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB F3 — narrow the recorder's exposed `State` if the cut shows users beyond the agent perf logger

#### Step 4c — remaining adapter seams in place
Intent: a rescan of the live code (evidence `step4c-probe/`) leaves 26 outside names, of which the diagnostics files, `MCPFilesystemConstants` and `AgentSessionWorktreeBinding` depend on nothing outside the seed and simply join the move, several are scanner false positives (`compare`, `insertionIndex`, `fileName`), and the workspace-switch providers, preset store and `WorkspaceSelectionCoordinator` have no workspace users and stay in App; the rest are split in place — hoist `StoredSelection`, and move the view-model tree renderers of `CodeMapExtractor`, the `FileViewModel` members of `SearchMatch`, `FileTreeItem` with its sorting helper, the `WorkspaceFilesViewModel`-bound `DiffParser` class, and the git diff DTO adapter into App files.

Budget used: about 1 hour (cumulative ~13.5 hours).

Result: the six splits moved code verbatim (a block-order move check leaves only ten `private` → internal relaxations for helpers now shared across files, plus file scaffolding), and the rescan leaves no workspace reference to App code except the files that join the move, scanner false positives and files that stay in App; build, 15 affected suites (361 tests, 0 failures), format and lint pass, so the seams for Slice 4 are complete and the next step is the move itself.

Decisions: the moved `CodeMapExtractor` renderers got their own adapter file (`CodeMapExtractor+FileTreeRendering.swift`) instead of growing the existing one by 1,570 lines, and the `DiffParser` class lives in `WorkspaceFilesDiffParser.swift` because a module cannot hold two files of the same name.

Step 4c — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-1 — at the cut, give `SearchFileDescriptor` a verbatim `package` memberwise init for `init(file:)` (don't route through `init(record:…)`); OracleB P3-3 — at the cut, keep the `countOnly` reset in a descriptor-based search in Workspace so `searchWithErrors` and `SearchContentResult` can return to `private`

#### Step 4d — create `RepoPromptWorkspace` and move the engine
Intent: move the 250 files that now close over themselves (about 162k lines; list in `step4c-probe/moveset.txt`) into `Sources/RepoPromptWorkspace` with a Platform-only app dependency, applying the deferred verbatim `package` initializers and the descriptor-based search, then run the slice-end gates.

Budget used: about 4 hours (cumulative ~17.5 hours).

Result: `RepoPromptWorkspace` now holds the 250 files (about 162k lines) with `RepoPromptPlatform` as its only app-module dependency and no UI, agent, app, MCP SDK or Sentry import, App and tests reach it through 2,284 compiler-driven `package` declarations (93 of them verbatim initializers, including the deferred path-record and search-descriptor ones and the descriptor-based search that keeps the `countOnly` reset), an ordered per-file check shows the moved files changed only by `package`, added initializers and five explained lines, and build, the full suite (failures match the baseline and pass when rerun alone), identical discovery (6464 names), the unchanged ledger, format, lint, guardrails (A1 only) and the Xcode checks pass, and the universal release package build passes, so Slice 4 is complete and Slice 5 (AgentCore seams) follows.

Decisions: accepted the 2,284 `package` declarations instead of moving instrumentation back into App, because they are the compiler-required surface for a 162k-line module that App uses everywhere and trimming would mean redesign; `WorkspaceModel`, the workspace-switch providers and registry, the preset store and `WorkspaceSelectionCoordinator` stay in App because they own prompt packaging, compose tabs or view-model orchestration; source-scanning tests had their paths updated (and the auto-codemap invariant test now scans both the App and Workspace folders) so their coverage follows the moved files; the Step 4b recorder-`State` deferral is closed because only the agent perf logger uses it.

Step 4d — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB (3b) F1 — move `MentionModels`/`MentionSuggestion` down in Slice 5 if AgentCore needs it

### Slice 5 — AgentCore seams, in place
Still inside `RepoPromptApp`:
- hoist `TabSession` to `AgentTabSession`, together with the nested types the runtime uses, keeping the same object, owner, callbacks and ordering;
- classify the remaining view-model and `WindowStatesManager` uses, and put genuine orchestration behind `AgentSessionHost`;
- split `MCPIntegrationHelper` and `ToolResultDTOs` by responsibility, and inject `AgentMCPHosting` so that headless runs keep MCP hosting;
- enumerate every interface member and constructor call site before Slice 6.

Probe result: the name scan over the agent seed (all of `Infrastructure/AI` except `AgentModePrompts.swift`, non-view `Features/AgentMode`, and `Infrastructure/RemoteHosts`; 284 files / 142k lines) closes only 63 files today, and its outside references are 79 names in 93 files — the `TabSession` namespace (526 uses) and its ~35 sibling records in `AgentModeViewModel+Types.swift`, two coordinators that own the view model, MCP helpers and leases (50 files), settings reads and writes (8), packaging records (7), diagnostics (8), four files importing `RepoPromptUI`, and small pull-ins (key manager, executable identity, pairing validation) — while `TabSession` itself holds no owner pointer and talks to its owner only through three callbacks, so there is no kill result and the slice proceeds by in-place steps (evidence `slice5-probe/`).

Decisions: hoist only the small `PromptSection` order contract that `AIMessage` stores, keeping prompt assembly and packaging in App; keep each hoisted type's behavior and object identity, and use domain-prefixed names with same-type aliases until Slice 6.

#### Step 5a — `TabSession` sibling records hoisted
Intent: move the nested `AgentModeViewModel` types that `TabSession` and the runtime name (sibling records in `AgentModeViewModel+Types.swift`, factory and control aliases, the record-based payload and transcript-presentation helpers) to top-level `Agent…` declarations in their own files, leaving same-type typealiases so every existing spelling still compiles, with no behavior change.

Budget used: about 1.5 hours (cumulative ~19 hours).

Result: 26 sibling records, 9 factory and control aliases and the record-only transcript-presentation algorithm now live in five top-level files under `Features/AgentMode/Runtime` (`Session/AgentSession{Persistence,RunState,Transcript}Records.swift`, `AgentModeRuntimeFactories.swift`, `Transcript/AgentTranscriptPresentationBuilder.swift`), and the view model keeps same-type aliases and thin forwarders. A move check leaves only renames, imports, five re-qualified references and the forwarders. Build, 19 affected suites (519 tests, 0 failures), format and lint pass, and both reviewers found nothing above P3, so the next step hoists `TabSession` with its remaining sibling records.

Decisions: `commonEqualTurnPrefixCount` is internal on the builder because the view model's `persistableSnapshot` still calls it through a forwarder; the two aliases whose hoisted type keeps its old name use a `RepoPromptApp.` qualifier, so Slice 6 removes aliases in the same change that moves the types.

Step 5a — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-1 — hoisted records still name `AgentModeViewModel.AgentRunEpochTransitionIntent`, `.AgentInteractionTransport`, `.AgentExecutionWorktreeSelection`, `TabSession.PersistedLoadDisposition` and `MCPServerViewModel.AgentRunWaitDrainOutcome`; resolve in 5b and the MCP step, and switch runtime callers off the view-model forwarders before Slice 6

#### Step 5b — `TabSession` hoisted to `AgentTabSession`
Intent: move the `TabSession` class and the resend record it stores out of `AgentModeViewModel` into a top-level `AgentTabSession` in its own file, spelling its view-model alias references as the hoisted `Agent…` names, and hoist the three records Step 5a deferred (`AgentInteractionTransport`, `AgentRunEpochTransitionIntent`, `AgentExecutionWorktreeSelection`), leaving same-type aliases, with the same object, owner, callbacks and ordering.

Budget used: about 1 hour (cumulative ~20 hours).

Result: `AgentTabSession` and `AgentRemoteResendPayload` now live in `Features/AgentMode/Runtime/Session/AgentTabSession.swift`, and the three deferred records live in `AgentSessionRunStateRecords.swift`. An ordered line diff against the old nested bodies shows only alias-to-name spellings and one call that now goes straight to the transcript builder. Build, 23 affected suites (592 tests, 0 failures), format and lint pass, and both reviewers found nothing above P3, so the next step classifies the remaining view-model and window-state uses from a rescan.

Decisions: the emptied `AgentModeViewModel+TabSession.swift` was deleted and its two aliases joined the others in `AgentModeViewModel+Types.swift`, so Slice 6 removes aliases from one file; a source-scanning release-absence test and one plan citation now point at the new file.

Step 5b — done | rounds 0/2 | open: | downgraded: | assumed: | deferred:

#### Step 5c — agent code spells the hoisted names
Intent: a rescan (evidence `step5c-probe/`) shows 574 of the remaining view-model references in the agent seed are old spellings through the Step 5a/5b aliases, so rewrite them to the hoisted `Agent…` names (and the two transcript forwarders to the builder) and move the saved `AgentContextUsage` record out of the view-model file unchanged, so the next rescan shows only genuine view-model dependencies.

Budget used: about 1 hour (cumulative ~21 hours).

Result: 574 references in 20 agent files now use the hoisted names and `AgentContextUsage` has its own file. A mechanical check shows every changed file equals its base with only the alias map applied, apart from three realigned lines and the moved record. Build, format, lint and 34 affected suites (765 tests) pass, except that each of two runs had one different timing-dependent failure, and both suites pass alone. Both reviewers found nothing above P3, so the next step rescans and classifies the genuine view-model uses.

Decisions: the two intermittent failures (`AgentModeRunServiceLifecycleTests.testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization`, `RemoteAgentSessionTests.testStaleRecoveryPausesOnDisconnectResumesSameSessionAndDefersToTransientRecovery`) are treated as host-load flakes because the compiled program is unchanged apart from one equivalent direct call; the view-model debug-log statics stay for the diagnostics step.

Step 5c — done | rounds 0/2 | open: | downgraded: | assumed: | deferred:

#### Step 5d — the session's own App ties cut
Intent: a rescan (evidence `step5d-probe/`) leaves 84 outside names; the five that `AgentTabSession` itself stores (the provider usage snapshot nested in the runtime sidebar view model, the composer submit target and attempt, the worktree-merge review records, and the persistent binding identity) are plain records, so move them into runtime session and usage files, hoisting the nested snapshot to `AgentProviderUsageSnapshot` with an alias, with no behavior change.

Budget used: about 1 hour (cumulative ~22 hours).

Result: the five records now live in `Runtime/Session/AgentComposerSubmitRecords.swift`, `AgentWorktreeMergeReviewRecords.swift`, `AgentSessionPersistenceRecords.swift` and `Runtime/Usage/AgentProviderUsageSnapshot.swift`. Ordered diffs show only the hoisted name and one same-type field spelling. Build, format, lint and 10 affected suites (385 tests, 0 failures) pass, and both reviewers found nothing above P3, so `AgentTabSession` no longer names any view-model or UI type. The next step takes the tool-card normalization helpers the transcript services use.

Decisions: the `ProviderUsageSnapshot` alias stays inside `AgentRuntimeSidebarViewModel`, because it aliases that class's nested name; Slice 6 alias removal must cover it as well as `AgentModeViewModel+Types.swift`.

Step 5d — done | rounds 0/2 | open: | downgraded: | assumed: | deferred:

#### Step 5e — tool-name helpers out of tool-card views
Intent: the transcript services and edit decoder call three pure string functions that live in SwiftUI tool-card files (`normalizedToolCardName`, `toolIcon`, `toolDisplayName`), so move them verbatim into a runtime file; the other tool-card helpers the runtime uses (`ToolJSON`, `ToolArgsDTOs`, `ClusterToolCategory`) already depend only on agent code and move whole at the cut.

Budget used: about 0.5 hours (cumulative ~22.5 hours).

Result: the three helpers now live in `Runtime/ToolTracking/AgentToolNaming.swift`, byte-identical to the removed lines under an ordered diff. Build, format, lint and 16 affected suites (362 tests, 0 failures) pass, and both reviewers found nothing above P3. The next step takes on the MCP helpers, the largest remaining group.

Decisions: suite selection now also matches test classes declared inside `#if DEBUG` blocks; a backfill run found one suite that Steps 5b–5d had missed, and it passes.

Step 5e — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-1 — `normalizedToolCardName` still calls `MCPIntegrationHelper.canonicalRepoPromptToolName`; the MCP split must place that name lookup at agent level

#### Step 5f — app actions split out of `MCPIntegrationHelper`
Intent: agent code uses `MCPIntegrationHelper` in 24 files for tool-name canonicalization and provider MCP configuration, and the helper's only App ties are the deep-link installers (`NSWorkspace`), the clipboard copy (`NSPasteboard`) and the `CLIPathInstaller` forwarders, so move those into an App extension file and drop AppKit from the helper, with no behavior change.

Budget used: about 0.5 hours (cumulative ~23 hours).

Result: `MCPIntegrationHelper+AppActions.swift` now holds the two deep-link installers, the clipboard copy and the 12 command-line forwarders, and the helper imports only Foundation and AgentCore. A move check leaves only imports, the extension wrapper and one `private` → internal relaxation. Build, format, lint and 9 affected suites (110 tests, 0 failures) pass, and both reviewers found nothing above P3. The next step handles the MCP leases and the server hosting interface.

Decisions: the new extension file stays in App at the cut, so the helper members it uses (`mcpConfigDict`, `repoPromptMCPConfiguration`, `jsonSnippet`, `setMCPServerInstalled`) will need `package` access then; `setMCPServerInstalled` stays in the helper because the helper's own installers call it.

Step 5f — done | rounds 0/2 | open: | downgraded: | assumed: | deferred:

#### Step 5g — MCP hosting interface
Intent: agent runtime calls 13 `ServerNetworkManager` methods, so first test whether one `Sendable` async protocol that the server actor conforms to can cover all of them without pulling App types along (the kill result would be a signature that needs an App-only type graph), and move the shared `MCPRunPurpose` enum out of the connection manager; if it holds, make `AgentToolTracker` its first user through a required initializer argument, with owners passing the server for now.

Budget used: about 1 hour (cumulative ~24 hours).

Result: `AgentMCPHosting` covers all 13 server methods the runtime calls, and every type in its signatures sits in the agent seed, the MCP SDK or (for `ExecutableFileIdentity`) a file that needs only Workspace, so the kill result did not occur and Debug and Release both build. `MCPRunPurpose` moved verbatim, and `AgentToolTracker` and its controller now take the host as a required initializer argument. Build, format, lint and 8 affected suites (0 failures) pass, and neither reviewer found anything above P2; the one P2 was a miscounted method total in this intent. The next step threads the host into the providers and session controllers that still read the server directly.

Decisions: the protocol is a non-isolated `Sendable` async protocol rather than the `@MainActor` protocol the ground rules mention, because the server is its own actor and a main-actor requirement would add a main-actor hop to every call; calls keep their current async shape. Tool-event registration goes through a callback overload, so the App-nested `ToolEventObserver` stays out of the protocol. Owners pass `ServerNetworkManager.shared` until their own initializers take the host.

Step 5g — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-1 — move `ExecutableFileIdentity` below App before the cut; P3-2 — when callers switch to the protocol, write the actor's default arguments out exactly, and give any convenience overload a different signature; P3-4 — owner-suite coverage comes from the slice-end full test run; P3-6 — redundant `manager` alias in the tracker and tests; carried from 5a — `MCPServerViewModel.AgentRunWaitDrainOutcome` in `AgentModeRuntimeFactories.swift`

#### Step 5h — host into session controllers and providers
Intent: the Claude native session controller, the Codex app-server client, the ACP session controller and the Claude, Codex exec and OMP headless providers still read `ServerNetworkManager.shared`, so give each a required `mcpHost` initializer argument used for those calls and the tool-tracking controllers they own, with construction sites passing the server or their owner's host, and no behavior change.

Budget used: about 1 hour (cumulative ~25 hours).

Result: the six classes now take a required `mcpHost` and no longer mention `ServerNetworkManager`; the two providers build their tool-tracking controllers from it, and the OMP provider passes it to the ACP controllers it creates. Build, format, lint and the 32 suites in test files that construct these classes (0 failures) pass, and neither reviewer found anything above P3. The next step lifts the interim `ServerNetworkManager.shared` arguments out of the runtime owners: the tool-tracking owners, the provider service, the coordinators, the polling services and the bootstrap lease, routing waiter and run coordinator.

Decisions: Swift defaults can't refer to another parameter, so the Codex client's PID registrar and the OMP provider's route check and controller factory became optional parameters whose defaults are built in `init` from the host; explicit arguments behave as before. An engineer worker did the threading, and I removed two unused stored properties after its run.

Step 5h — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: OracleB P3-4 — interim `mcpHost: ServerNetworkManager.shared` sites inside agent code (provider service, Claude coordinator, tool-tracking owners, Cursor/OpenCode/OMP polling and headless defaults, OMP CLI provider and thinking sweep, Codex helpers and the debug test hook) move up in the next steps

#### Step 5i — routing waiter, run coordinator and bootstrap lease take their dependencies
Intent: the bootstrap lease, routing waiter and run coordinator reach the server and each other through `.shared`, so give them required initializer dependencies (host, waiter, coordinator), move the two process-wide instances and the waiter's static convenience calls into the App composition file, and have the OMP provider and agent-mode lease helpers take the waiter or host they use, with no behavior change.

Budget used: about 1.5 hours (cumulative ~26.5 hours).

Result: the routing waiter takes the host, the run coordinator takes the host and waiter, and the bootstrap lease takes the coordinator and reads both from it; the process-wide waiter and coordinator and the waiter's static calls now live in the App composition file, and none of the five touched agent files names the server or those statics. Build, format, lint and the 17 affected suites pass; one run had a single failure in the lifecycle test that also failed intermittently in Step 5c, and it passed alone and in a full rerun. Neither reviewer found anything above P3. The next step lifts the remaining interim server, waiter and coordinator arguments out of agent-mode owners and provider defaults.

Decisions: the lease takes only the coordinator, so it can't register on one waiter and wait on another. First use of the waiter now also creates the server object, which has no side effects at creation. `agentModePolicyClearer` had no callers at HEAD and was deleted rather than given a host. The fire-and-forget signals became waiter instance methods that the App statics forward to.

Step 5i — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: interim `ServerNetworkManager.shared`, `MCPRoutingWaiter.shared` and `AgentRunCoordinator.shared` arguments at agent-mode run service, Codex coordinator, provider service and OMP CLI provider sites

#### Step 5j — agent-mode owners take the host from the view model
Intent: the Codex and Claude coordinators, the agent-mode run service with its ACP runner, the Claude tool-tracking handler and the provider service still pass `ServerNetworkManager.shared` or the shared waiter and coordinator themselves, so give each the dependencies it uses as required initializer arguments, supplied by the view model or the App composition file (which now builds the provider service), and drop the run coordinator's uncalled `makeProvider`, with no behavior change.

Budget used: about 1.5 hours (cumulative ~28 hours).

Result: the Codex and Claude coordinators, the run service with its ACP runner, the Claude tool-tracking handler and the provider service now take their host, waiter or run coordinator as required arguments from the view model or the App composition file, and none of the touched agent owner files names the server or those statics. Build, format, lint and the 17 affected suites pass; the one cross-suite failure (the chat-switch model-base assertion after the list-agents suite) fails the same way on the tree before this step, so it is pre-existing. Neither reviewer found anything above P2. The next step lifts the remaining server references out of `Infrastructure/AI`.

Decisions: the Codex coordinator and the run service take only the run coordinator and read its host, so observers and policies can't land on different servers. Creating the provider service now also creates the server and waiter objects, and the view model reads the server in its initializer; nothing those creations reach uses the shared provider service or coordinator, so this can't recurse. The review fix that merged the two arguments changed wiring, not behavior, so it was not re-reviewed.

Step 5j — done | rounds 0/2 | open: | downgraded: | assumed: | deferred: pre-existing order dependence between `AgentManageMCPToolServiceListAgentsTests` and `AgentModeChatSwitchActivationTests` (shared Codex model-base registry), outside this contract

#### Step 5k — `Infrastructure/AI` providers and services take the host
Intent: the chat-provider factory and its CLI providers, the Cursor, OpenCode and OMP headless providers and model-polling services, the OMP thinking sweep, the Codex non-agent client helper and its users still reach `ServerNetworkManager.shared` (or the shared waiter) through default arguments, so give each the host it uses as a required dependency supplied from App, move their process-wide instances that need it into the App composition file, and delete the uncalled debug Codex hook, with no behavior change.

Budget used: about 0 hours so far (cumulative ~28 hours).

Step 5k — doing | rounds 0/2 | open: | downgraded: | assumed: | deferred:

### Slice 6 — `RepoPromptAgentCore` extraction
Move the now-acyclic AI, agent models, providers, runtime, services, history, recommendations and non-UI remote-host code. Remove the temporary typealiases. Check the release compile flags once for cross-module optimization; don't change them.

Step 6 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

## Decisions
- Purpose: architecture and enforced boundaries, not build or runtime speed.
- Modules: Platform, Workspace, AgentCore, UI and App, with `RepoPrompt`-prefixed names.
- UI is a sibling of Workspace and AgentCore and depends on Platform only.
- Access: `internal` by default; `package` only where another target uses a declaration.
- Pilot: Prompts + Pricing as the seed of AgentCore; Platform comes next.
- MCP server composition stays in App; AgentCore gets a narrow hosting interface.
- No permanent layering-check tooling; `Package.swift` dependencies enforce the layers.
- Test imports are added by script to every `@testable import RepoPromptApp` file.
- Typealiases for hoisted types stay until the AgentCore extraction, then go.
- No upstream sync: this is a private-use fork that has diverged.

## Assumed
- A1 (Slice 1): `make guardrails` fails in this worktree only on `Scripts/check-agent-context` for two plans (`2026-10-05-transcript-inner-scroll-hang-fix-plan.md`, `2026-10-09-oracle-call-contract-hardening-plan.md`) that are orphaned at HEAD; another session's uncommitted edit in the main checkout links them. Treated as pre-existing and not fixed here; undo by linking them from a routed doc if that edit never lands.
- A2 (Step 3b): "UI depends on Platform only" limits which app modules UI may use, so third-party packages (`Markdown`, `Neon`, `SwiftTreeSitter`) are allowed, as they already are for Platform. Undo by keeping the markdown and highlighting files in App, which would return most of Slice 3 to App.
