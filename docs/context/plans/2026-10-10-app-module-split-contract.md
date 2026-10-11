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

Step 3 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

### Slice 4 — `RepoPromptWorkspace`
Move workspace context, indexing and search, VCS and worktrees, domain diff and edit operations, workspace persistence, and non-UI CodeMap and workspace-file code. Prompt packaging (`ChatPreset`, `CopyPreset`, `PromptSection`) and anything that needs `AIModel` stay above, with only their workspace-only parts extracted down.

Step 4 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

### Slice 5 — AgentCore seams, in place
Still inside `RepoPromptApp`:
- hoist `TabSession` to `AgentTabSession`, together with the nested types the runtime uses, keeping the same object, owner, callbacks and ordering;
- classify the remaining view-model and `WindowStatesManager` uses, and put genuine orchestration behind `AgentSessionHost`;
- split `MCPIntegrationHelper` and `ToolResultDTOs` by responsibility, and inject `AgentMCPHosting` so that headless runs keep MCP hosting;
- enumerate every interface member and constructor call site before Slice 6.

Step 5 — todo | rounds 0/2 | open: | downgraded: | assumed: | deferred:

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
