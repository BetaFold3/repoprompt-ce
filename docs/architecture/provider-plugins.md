# Agent Provider Plugin Seam

Current as of 2026-08-16. This document is contributor-facing: use it when you are wiring a new autonomous-agent provider, editing the Claude-compatible runtime, or moving code across the core ↔ plugin boundary.

## Scope and goals

RepoPrompt CE keeps a small, provider-neutral runtime contract in the app and pushes provider-specific protocol/codec/runtime logic into a Swift package product. The first plugin product is `RepoPromptClaudeCompatibleProvider`, which owns the Claude-compatible family (Claude Code, GLM/Zai, Kimi, custom Claude-compatible). The seam preserves:

- public `AgentProviderKind` raw values;
- `AgentProviderBindingID.claude` settings/permission grouping;
- persisted `AgentModel` raw values, option ordering, and provider defaults;
- secure permission documents in `AgentPermissionSecureStore`;
- `.claude` legacy/mirror keys for tool/permission settings.

The seam intentionally stops short of dynamic plugin loading. It is static SwiftPM composition and an internal DTO-based plugin API.

## High-level layering

```
+-------------------------- core (RepoPromptApp target) --------------------------+
|                                                                                |
| AgentMode/UI · transcript · tool tracking · MCP permission · run state         |
|     │                                                                          |
|     │  NativeAgentRuntimeControlling (provider-neutral core contract)          |
|     ▼                                                                          |
| ClaudeCompatibleNativeSessionAdapter ─┐                                        |
| ClaudeCompatibleHeadlessProviderAdapter ├─ Agent Mode adapter trio             |
| ClaudeCompatibleModelCatalogAdapter ──┘                                        |
|     │                                                                          |
|     │  ClaudeCompatiblePluginBridge (feature bridge / Agent-Mode mappings)     |
|     │                                                                          |
|     │  ClaudeCompatibleProviderRuntimeBridge (infrastructure / package import) |
|     ▼                                                                          |
+--------------------- package (RepoPromptClaudeCompatibleProvider) -------------+
|                                                                                |
| Plugin DTOs · prompt delivery · environment builder · catalog · headless args ·|
| launch env resolver · Claude SDK codec/translator (pure logic)                 |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Two thin facades sit between core and the package so lower-level infrastructure files (for example `ClaudeCodeLaunchEnvironmentResolver`) do not depend upward on Agent Mode:

- **`ClaudeCompatibleProviderRuntimeBridge`** (`Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`) is the single core import point for `RepoPromptClaudeCompatibleProvider`. It owns the package's type aliases, DTO conversions, and pure runtime helpers (prompt delivery, environment building, model normalization, headless argument construction, launch-environment resolution, catalog snapshots, stream-result mapping).
- **`ClaudeCompatiblePluginBridge`** (`Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`) is the Agent-Mode-facing facade. It maps `AgentProviderKind` to the package's `ClaudeCompatibleProviderPluginID`, derives availability, builds runtime configs from Agent Mode / discovery contexts, and forwards every other helper to the infrastructure bridge.

Anywhere outside these two files, core code interacts with Claude-compatible plugin DTOs through one of the bridges, not through a raw package import.

## Static dependency setup

The provider package lives in-repo at `Packages/RepoPromptAgentProviders/` and is composed into the root manifest with SwiftPM's path-dependency form:

```swift
// Package.swift (root)
.package(path: "Packages/RepoPromptAgentProviders"),

// RepoPrompt executable target dependencies
.product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders"),
```

The package itself exposes a single library product today:

```swift
// Packages/RepoPromptAgentProviders/Package.swift
products: [
    .library(
        name: "RepoPromptClaudeCompatibleProvider",
        targets: ["RepoPromptClaudeCompatibleProvider"]
    ),
],
```

The package target is Foundation-only and intentionally does **not** import any RepoPrompt app code, persistence layer, or secure storage.

### Test commands

Use coordinated root commands so provider work shares the repository build/test lanes:

```bash
# Root app build and tests (includes the package transitively)
make dev-swift-build PRODUCT=RepoPrompt
make dev-test

# Package-only tests (faster iteration on codec / translator / catalog DTOs)
make dev-provider-test
```

If the developer daemon is unavailable, use the direct SwiftPM commands documented in the [development workflow](../context/workflows/development.md).

### Future external repository

When the provider package is later moved to its own repository, the plan is:

1. Replace the path dependency in the root `Package.swift` with a versioned remote dependency:
   ```swift
   .package(url: "https://github.com/.../RepoPromptAgentProviders.git", from: "x.y.z"),
   ```
2. Document a SwiftPM/Xcode local override for sibling-checkout development rather than re-introducing a required `.package(path:)` in the shared manifest. Two equivalent override options:
   - Xcode → File → Add Package Dependencies → Add Local… pointing at the sibling checkout (Xcode-only override).
   - `swift package edit RepoPromptAgentProviders --path ../RepoPromptAgentProviders` (writes the override into `.swiftpm/`).
3. Keep `Packages/RepoPromptAgentProviders/` in the open-source repo as long as it is the canonical staging location; once split out, mirror updates with versioned releases instead of in-tree edits.

The remote-by-default policy avoids breaking checkouts that do not have a sibling clone, while still giving contributors a low-friction local edit workflow.

## Core vs plugin ownership

| Concern | Owner |
| --- | --- |
| `AgentProviderKind`, `AgentProviderBindingID`, runtime kind strings | core |
| Persisted settings (`UserDefaults`, secure store, `.claude` documents) | core |
| `ClaudeAgentToolPreferences`, `ClaudeCodeCompatibleBackendConfig`, `ClaudeCodeCompatibleBackendStore` | core |
| MCP permission policies, RepoPrompt MCP auto-approval, tool tracking | core |
| Agent Mode transcript mutation, tool-card UI, run-state ownership | core |
| Native process control (`ClaudeNativeProcessSessionController`) | core (this wave) |
| Provider-neutral runtime contract (`NativeAgentRuntimeControlling`) | core |
| Provider-neutral RepoPrompt workflow prompt catalog and renderers (`Infrastructure/AI/Prompts/Workflows`) | core |
| Headless wrapper (`ClaudeCodeAgentProvider`) | core (delegates pure rules to package) |
| `AgentModel` raw values, option DTOs, defaults | core (adapter forwards plugin DTOs back to these) |
| Plugin IDs (`ClaudeCompatibleProviderPluginID`), runtime variants, backend IDs | package DTOs |
| Claude SDK protocol codec and NDJSON translator | package |
| Prompt delivery rules (XML wrapping, system-prompt overrides) | package |
| Compatible-backend environment builder, removed env keys, no-model raw values | package |
| Launch-environment resolver (slot mapping, model normalization, GLM legacy aliases) | package |
| Headless CLI argument construction | package |
| Model catalog snapshot (string options, default raws, supported effort levels) | package |
| Stream-result DTO (`ClaudeProviderStreamResult`, `ClaudeProviderJSONValue`) | package |

The package never touches `UserDefaults`, `Keychain`, or `AgentPermissionSecureStore`. Secrets and persisted backend configs are read in core, sanitized into plugin DTOs (`ClaudeCompatibleBackendConfig`, `ClaudeCompatibleLaunchEnvironment`), and handed to the package at launch/catalog time through bridge functions and provider closures.

## Claude CLI executable selection

Core owns the user-configurable Claude CLI executable override. Settings persists the applied path under `cliExecutableOverride.claude`; `CLIProvidersSettingsView` presents it in the Claude CLI section, and `APISettingsViewModel` owns draft validation, apply/reset, and probes.

The override is sampled for new local Claude-family sessions and one-shot operations. It covers interactive Agent Mode, headless discovery, Settings probes, and Claude MCP installation for standard Claude Code, GLM, Kimi, and custom Claude-compatible backends. Remote-host sessions ignore the local preference, and Codex executable selection is unaffected.

A configured path is validated before launch. Failure produces a typed error and never falls back to another `claude`; configured launches bypass `CommandPathResolver` and `ResolvedCommandCache`. With an empty setting, automatic resolution retains `.preferShell` login-shell lookup. The two Settings probes also use `.preferShell`, matching the local runtime instead of their former `.fallbackOnly` behavior.

`CLIProcessConfiguration.init` requires every call site to name `command:` explicitly; the parameter has no default value. Wrapper or shim paths apply only to new sessions, must `exec` the real CLI, and must keep stdout transparent for the stream-JSON protocol.

## Bridge responsibilities

### `ClaudeCompatibleProviderRuntimeBridge` (infrastructure)

Path: `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`.

This is the only file in core that `import RepoPromptClaudeCompatibleProvider`. It is responsible for:

- declaring `ClaudeCompatiblePlugin…` type aliases for every package DTO core code references, so other files can refer to plugin types without importing the package;
- converting core enums/structs to plugin DTOs and back (`pluginRuntimeVariant(for:)`, `pluginBackendID(for:)`, `pluginBackendConfig(from:)`, `runtimeConfig(from:)`, `launchEnvironment(from:)`, `coreLaunchEnvironment(from:)`, etc.);
- forwarding pure runtime helpers from the package: `ClaudeCompatiblePromptDelivery`, `ClaudeCompatibleBackendEnvironmentBuilder`, `ClaudeCompatibleHeadlessRuntime`, `ClaudeCompatibleLaunchEnvironmentResolver`, `ClaudeCompatibleModelCatalog`, `ClaudeCompatibleModelNormalizer`;
- translating package errors (`ClaudeCompatibleProviderError.invalidConfiguration`) into core errors (`AIProviderError.invalidConfiguration`);
- mapping `ClaudeProviderStreamResult` to `AIStreamResult` and back, so plugin DTOs never leak into Agent Mode and core stream results never leak into the package.

Files that depend on this bridge (illustrative):

- `Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift` (stream mapping)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeLaunchEnvironmentResolver.swift` (model normalization, slot mapping, launch resolution)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeCompatibleBackendStore.swift` (env builder)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodePromptDelivery.swift` (decorated user message)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeAgentToolPreferences.swift` (prompt delivery rules)
- `Infrastructure/AI/Providers/ClaudeCodeAgentProvider.swift` (headless arguments, user-message decoration)

### `ClaudeCompatiblePluginBridge` (Agent Mode feature facade)

Path: `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`.

Responsibilities the infrastructure bridge cannot cleanly own because they require Agent-Mode-only concepts:

- `pluginID(for: AgentProviderKind)` / `agentKind(for: ClaudeCompatiblePluginID)` – the only place Agent Mode's provider kind talks to package IDs.
- `agentModeRuntimeConfig(...)` and `discoveryRuntimeConfig(...)` – build a `ClaudeCompatibleRuntimeConfig` from `ClaudeCodeAgentConfig.agentMode(...)` / `.discovery(...)` while staying tied to `AgentProviderKind`.
- `availability(for:)` – combines `AgentModelCatalog.isAgentAvailable(...)` with package availability shapes.
- `streamResult(from:)` / `providerStreamResult(from:)` – Agent-Mode-facing wrappers re-exported for the adapter trio.

Everything else is a thin pass-through to `ClaudeCompatibleProviderRuntimeBridge`.

## Adapter trio

The Agent Mode side of the bridge ships three small adapters under `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/`.

### `ClaudeCompatibleNativeSessionAdapter`

- Carries a `ClaudeCompatiblePluginRuntimeConfig` and delegates `NativeAgentRuntimeControlling` to a controller factory closure.
- Today the factory returns a `ClaudeNativeProcessSessionController` (core-owned process control). A future slice can replace the factory body with a package-driven controller without changing the adapter's public shape.
- `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` is the single call site that constructs and hands the adapter to `ClaudeAgentModeCoordinator`.

### `ClaudeCompatibleHeadlessProviderAdapter`

- Wraps a concrete `HeadlessAgentProvider` (currently `ClaudeCodeAgentProvider`) and carries a `ClaudeCompatiblePluginRuntimeConfig` for parity with the interactive adapter.
- `AgentRuntimeProviderService.makeProvider(...)` branches for `.claudeCode | .claudeCodeGLM | .kimiCode | .customClaudeCompatible` build the underlying provider and wrap it in this adapter. Non-Claude providers (Codex, Gemini, OpenCode, Cursor) bypass the adapter.

### `ClaudeCompatibleModelCatalogAdapter`

- Asks the package for a `ClaudeCompatibleModelCatalogSnapshot`, then canonicalizes raw values back onto `AgentModel.resolvedModel(...)` and existing GLM legacy aliases.
- Owns the public Agent-Mode-facing helpers `AgentModelCatalog` forwards to for Claude-compatible branches: `defaultModelRaw(for:)`, `options(for:)`, `isValid(rawModel:for:availability:)`, `claudeEffort(...)`, plus compatible-backend display/description lookups.
- Keeps `AgentModel` raw values and validation semantics stable so persisted user selections survive the seam.

## Provider-neutral native runtime contract

Path: `Sources/RepoPrompt/Features/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift`.

This is an **app-internal** contract, not the external plugin API. It still uses core models (`AIStreamResult`, `AgentApprovalRequest`, `AgentApprovalDecision`) because adapters translate plugin DTOs first. The current shape:

```swift
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    func sendUserMessage(_ text: String) async throws -> UUID
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}
```

The associated event/session/turn types are currently `typealias`es over the Claude-native runtime DTOs (`NativeAgentRuntimeEvent = ClaudeNativeProcessSessionController.Event`, etc.). When a second native provider arrives, the aliases will become proper neutral DTOs and the Claude controller will conform via its own mapping. Until then the alias layer keeps the seam ergonomic without forcing churn on coordinators, runners, and tab-session storage.

`ClaudeSessionControlling` is retained as a backwards-compatible alias for existing Claude call sites.


## Oh My Pi managed ACP integration

Oh My Pi (OMP) is implemented as an app-internal ACP provider under `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/`, not through the Claude-compatible package seam. Its stable identities are `ACPProviderID.ohMyPi`, `AgentProviderKind.ohMyPi`, and `AgentProviderBindingID.ohMyPi` (raw `"ohMyPi"`); the executable is `omp`, the runtime kind is `"omp_acp"`, and the verified MCP `clientInfo.name` is `"omp-coding-agent"`. OMP preserves expected-PID and pre-prompt Agent Mode MCP routing.

RepoPrompt owns one fixed OMP launch/preflight profile shared by Agent Mode and Oracle one-shots. New processes receive exactly:

```text
omp acp --no-tools --no-extensions --no-skills --no-rules --approval-mode yolo
```

There is no argument passthrough or per-flag opt-out. Preflight resolves a trusted executable (including the OMP/Bun home-bin hint), separately requires `omp acp --help` to exit successfully, validates every managed global flag in `omp --help`, and rejects versions older than the locally captured `17.2.12` baseline. OMP 17.2.12's ACP subcommand help contains only subcommand usage, so it is not used as evidence for global flags.

Interactive Agent Mode and Agent Mode headless runs inject exactly one command-shaped RepoPrompt stdio MCP server; model discovery uses no MCP server and does not dispatch a prompt. Oracle one-shots instead use `OhMyPiCLIProvider` through the same trusted-executable resolver, fixed argv, managed-flag validation, and version floor, but with RepoPrompt MCP disabled, no workspace or resume, a no-tools system suffix, and ACP approval requests rejected by the headless `.declineUnsupported` policy. A nonblank persisted Agent Mode provider session ID selects `session/load`, while a blank or absent ID selects `session/new`. OMP resume is exact-or-error: a failed load never falls back to a fresh session after transcript replay has been withheld. Models are dynamic ACP `configOptions` data stored in `AgentACPModelRegistry`; the Agent Mode catalog retains `Default` as its sole static sentinel, while the Oracle `AIModel` catalog has no static OMP fallback. RepoPrompt sends OMP's `thinking` option only when the resolved source destination has an explicit entry for the exact wire model ID. The complete capped map is independently owned by each model preset, Agent Mode tab/session, and Prompt destination; key absence remains Default and sends nothing. Request assembly attaches the typed option from that source map, with no provider-global preference lookup.

The OMP permission binding has its own RepoPrompt MCP capability grant and a fixed managed-barebones profile. ACP duplicate approval is allowed only for an exact known RepoPrompt server identity and/or an explicit server-prefixed canonical RepoPrompt tool name; substring server matches and unrecognized requests retain the existing interactive behavior. This optimization does not change the server-side MCP permission decision.

OMP is a supported catalog provider in DEBUG and RELEASE. Window availability is gated by `APISettingsViewModel.isOhMyPiConnected`; a DEBUG qualification lease is an OR override. A successful connection test enables Agent Mode, MCP `list_agents`/`agent_run`, Context Builder, and registry-backed Oracle picker entries, including current-process cached-provider validation and dynamic model subscriptions. The Oracle picker is empty when no dynamic OMP snapshot exists; it never manufactures `Default`, and a persisted OMP selection still decodes and displays while disconnected. `AgentProviderBindingID.publicSettingsCases` remains excluded because the fixed managed OMP profile has no mutable generic setting. Recommendations and task-label resolution remain excluded. MCP-enabled Agent Mode headless OMP waits for the already-registered routing signal before sending its first prompt, while `MCPBootstrapLease` remains the routing cleanup owner. For prompt dispatch, the route check is skipped exactly when `includeRepoPromptMCPServer` is false; model discovery does not send a prompt and therefore never traverses this pre-prompt gate.

Focused Oracle coverage lives in `OhMyPiModelCatalogTests`, `OhMyPiCLIProviderTests`, `OhMyPiACPHeadlessAgentProviderTests`, `HeadlessCLIStreamBridgeTests`, and `CursorCLIProviderTests`.

The hidden DEBUG qualification path remains strict and separate from ordinary public starts. If any qualification lease/context is supplied, owner process, connection, workspace, generation, receipt, Apply Edits scope, and provider identity checks all fail closed; a lease never authorizes a non-OMP target. The six live qualification gates and cross-process `session/load` MCP re-registration have passed. OMP has no supported CE timeout override today; do not add a speculative one.

## ACP provider MCP tool-call timeouts

RepoPrompt CE cannot impose one MCP tool-call timeout across external ACP providers; configure the provider where supported.

- **OpenCode:** Timeout values are milliseconds. For a 10,000-second call, set `"timeout": 10000000` on the existing RepoPrompt MCP server entry, preserving its `type`, `command`, and `environment` fields.
- **Cursor Agent:** Current builds expose no supported ACP, CLI, environment, or configuration override that RepoPrompt CE can set to 10,000 seconds. Do not add a speculative CE timeout control; add one only if Cursor documents a supported configuration surface.

## How a new provider plugs in

The recommended pattern when adding (for example) a hypothetical `acmeAgent` family:

1. **Decide the runtime shape.**
   - Interactive native CLI: implement `NativeAgentRuntimeControlling` for the new family, building an adapter analogous to `ClaudeCompatibleNativeSessionAdapter`.
   - Headless-only CLI: build a `HeadlessAgentProvider` and (optionally) wrap it in a per-family adapter for parity. One-shot AI-query adapters can reuse `HeadlessCLIStreamBridge` while retaining provider-specific prompt, config, model, and event semantics.
   - ACP-based: follow `Sources/RepoPrompt/Features/AgentMode/Providers/ACP/ACPAgentProvider.swift` instead — ACP runtimes do not yet flow through the Claude-compatible plugin seam.

2. **Add (or reuse) a provider package.**
   - For an external family with its own SDK/codec, add a new library product under `Packages/RepoPromptAgentProviders/Sources/RepoPromptAcmeProvider/` and register a Swift target in the package manifest.
   - Keep DTOs Foundation-only. Use a `Sendable` JSON value type rather than `[String: Any]`.
   - Add package-level tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptAcmeProviderTests/` covering codec, translator, prompt delivery, and catalog snapshots.

3. **Wire the package into core through a bridge.**
   - Add one infrastructure file that imports the new package and declares `Acme…` type aliases, DTO conversions, and pure-helper forwarders. Mirror `ClaudeCompatibleProviderRuntimeBridge`.
   - Add an Agent-Mode-facing facade if the new family needs `AgentProviderKind` mappings, availability rules, or runtime-config builders.

4. **Add the adapter trio.**
   - `AcmeNativeSessionAdapter` (if interactive), `AcmeHeadlessProviderAdapter`, `AcmeModelCatalogAdapter`.
   - The native adapter conforms to `NativeAgentRuntimeControlling` and delegates to a factory closure so the controller implementation can move between core and the package later.

5. **Extend the runtime/factory wiring.**
   - Add the new cases to `AgentProviderKind` and the supporting maps (`commandName`, `displayName`, `mcpClientNameHint`, `runtimeKind`, `usesClaudeNativeRuntime` / new flags, `claudeRuntimeVariant` if relevant, `agentDescription`).
   - Extend `AgentProviderBindingID` if the new family needs its own permission/settings grouping; otherwise reuse an existing binding ID and keep secure-store documents grouped accordingly.
   - Add a branch in `AgentRuntimeProviderService.makeProvider(...)` that builds the headless provider and wraps it in the new adapter.
   - For interactive runs, add a sibling of `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` that constructs the adapter; pass it through `ClaudeAgentModeCoordinator`'s factory or add a coordinator analogue if the new family needs distinct steering rules.

6. **Plug into the model catalog.**
   - Forward the new family's branches in `AgentModelCatalog` to `AcmeModelCatalogAdapter` so option ordering, defaults, validation, display names, and discovery payloads come from the package while preserving `AgentModel` raw values for persisted user selections.

7. **Keep persistence in core.**
   - Settings/backend stores live under `Infrastructure/AI/Providers/Acme/` and are sanitized into plugin DTOs at launch time.
   - Secrets pass through `@Sendable` provider closures (see `ClaudeCompatibleLaunchEnvironmentResolver`'s `zaiSecretProvider`/`backendSecretProvider`) rather than being read inside the package.

8. **Add tests.**
   - Package-level tests for pure logic in the new product.
   - Root app tests under `Tests/RepoPromptTests/` for: adapter-to-controller wiring, model catalog snapshots (option order, defaults, raw values), launch-environment resolution, and any new permission/binding rules.

## Validation

Standard checks for changes that touch the seam:

```bash
# Root build (includes the path-dependency package)
make dev-swift-build PRODUCT=RepoPrompt

# Focused suites used during Work Items 1–9
make dev-test FILTER='ClaudeSDKNDJSONTranslatorTests|ClaudeCompatibleBackendEnvironmentTests|ClaudeNativeApprovalAndResumeTests|ClaudeCompatibleModelCatalogTests|ClaudeCompatiblePluginBridgeTests'

# Package-only iteration
make dev-provider-test
```

Add the relevant focused suite before any catalog/codec change, and snapshot model catalogs across `claudeCode`, `claudeCodeGLM`, `kimiCode`, and `customClaudeCompatible` before touching `AgentModelCatalog` branches.

## References

- `Package.swift` — root manifest and product wiring.
- `Packages/RepoPromptAgentProviders/Package.swift` — provider package manifest.
- `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/` — plugin DTOs, codec, translator, prompt delivery, environment builder, catalog, headless arg builder, launch-env resolver.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` — single package import point.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/HeadlessCLIStreamBridge.swift` and `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiCLIProvider.swift` — shared one-shot lifecycle plus the tool-free OMP Oracle adapter.
- `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/` — Agent-Mode facade and adapter trio.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift` — provider-neutral runtime contract.
- `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/` — provider-neutral RepoPrompt workflow prompt catalog, metadata, variants, and renderers shared by installs and MCP prompt registration.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift` — `AgentProviderKind` and headless factory.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — `makeClaudeCompatibleNativeController(...)`.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift` — interactive Claude-compatible coordinator.
- SwiftPM package manifest docs: <https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html>
- Xcode local package override workflow: <https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package>
