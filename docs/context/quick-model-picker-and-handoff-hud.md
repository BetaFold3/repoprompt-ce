# Agent Mode quick model picker and handoff HUD

Scope: read when the task touches the Agent Mode quick model picker or quick handoff shortcuts, model-leaf index/ranking, HUD lifecycle or hosting, current-session model commit seam, or last-completed-reply handoff routing.
Authority: Authoritative
Last-verified: 2026-08-16

## Durable contract

The feature provides two configurable, window-scoped Agent Mode HUDs:

| Action | Stable shortcut name | Default |
|---|---|---|
| Quick model picker | `showAgentQuickModelSelectionHUD` | ⌥⌘K |
| Quick handoff | `showAgentQuickHandoffHUD` | ⇧⌥⌘K |

Both shortcuts post `.showAgentModelSelectionHUD` with a target `windowID` and stable `AgentModelSelectionHUDMode` raw value. The global coordinator must route through `guardedHUDWindowState()`; Settings owns the user-configurable catalog rows.

Quick model picker changes the active session's model. Quick handoff creates a new session from the newest eligible completed assistant reply and may cross provider families.

## Owning source seams

- Pure catalog flattening and ranking: `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelSelectionIndex.swift`.
- HUD state and rendering: `ViewModels/UI/AgentModelSelectionHUDViewModel.swift` and `Views/Components/AgentModelSelectionHUDView.swift`.
- Presentation, live revalidation, and commits: `ViewModels/AgentModeViewModel+ModelSelectionHUD.swift`.
- Shared MCP-only model-control interactivity, current-session commit ordering, cache-only remote catalog access, last-reply lookup, and source-pinned handoff config: `ViewModels/AgentModeViewModel+Handoff.swift`; composer props consume the same predicate in `AgentModeViewModel+ComposerUI.swift`.
- Transcript cutoff policy: `Runtime/Transcript/AgentTranscriptServices.swift`, with shared conclusion repair in `AgentTranscriptQualityRepair.swift`.
- Handoff execution, success-only effort persistence, and error formatting: `Services/AgentHandoffActionSupport.swift`.
- Atomic hosting and blocking-overlay/nav-HUD exclusion: `Sources/RepoPrompt/App/Views/ContentRootShellView.swift`.
- Shortcut and notification ownership: `Infrastructure/Utilities/Shortcuts.swift`, `App/GlobalKeyboardShortcutsCoordinator.swift`, `App/Notifications/AppNotifications.swift`, and `Features/Settings/Views/KeyboardShortcutsSettingsView.swift`.

## Safety and performance invariants

- Presentation snapshots provider/catalog/transcript inputs once. Keystrokes perform only in-memory ranking: no process launch, network request, provider discovery, or remote catalog load.
- Remote HUD presentation uses `cachedRemoteHostCatalog(sourceTabID:)`, backed by `remoteHostCatalog.cachedCatalog(for:)`. Do not use an accessor that loads on cache miss.
- The index preserves provider-native raw identifiers and encoded effort behavior. A valid parameterized current Cursor raw remains exact; Fast warnings cover Codex Fast and Cursor `fast=true`.
- Empty-query selection is the exact current leaf only. If none exists, Enter is inert; Down starts at the first row and Up at the last. Digits are query input, never row shortcuts.
- Current-session model controls use the existing MCP-only interactivity rule. Available families still come from `selectableAgents(forTabID:)` plus `canSelectAgentInCurrentChat`; do not add run-state, remote, or pending-operation gating.
- `commitCurrentSessionModelSelection` revalidates the source tab, interactivity, family/knowledge policy, and live option existence, then preserves established encoded-effort persistence and model/effort side-effect ordering.
- Handoff presentation and commit are pinned to `sourceTabID`. Local routing uses `prepareHandoffHeadless(sourceTabID:...)`; live source/session/host drift fails closed.
- Handoff may cross provider families but still obeys provider availability and knowledge-session policy. Remote destinations come only from the cached catalog, exclude host default, and require `remoteCoordinator.hostRowID(for:session, clientItemID:)`.
- A local Codex handoff destination starts a new native thread whenever both saved native thread ID and rollout path are absent, regardless of migrated transcript rows or reconnect flags. A saved thread ID resumes that thread; a rollout path without its required thread ID is an explicit persisted-state integrity error. Failed first starts retain the pending handoff and retry `thread/start`.
- The last-reply resolver refuses active sessions, skips explicit failed/cancelled turns even when they contain displayable assistant text, accepts legacy nil terminal state, never synthesizes compacted summaries, and uses legacy items only when structured turns are absent.
- Ordinary Escape, click-outside, and dismissal cannot cancel a committing handoff. A blocking overlay—including remote device approval—immediately unmounts the HUD through the non-cancelling suspension path; task completion must not remount stale state.
- The navigation HUD and model-selection HUD are mutually exclusive.

## Smallest validation routes

Use the narrowest suite matching the changed seam:

- Index, raw-ID, ranking, and warning policy: `make dev-test FILTER=AgentModelSelectionIndexTests`.
- HUD selection and async lifecycle: `make dev-test FILTER=AgentModelSelectionHUDViewModelTests`.
- Last-reply eligibility and remote row mapping: `make dev-test FILTER=AgentLastCompletedAssistantReplyHandoffCutoffResolverTests`.
- Shared VM commit, source/host drift, and handoff presentation: `make dev-test FILTER=AgentModeChatSwitchActivationTests`.
- Handoff action persistence/error formatting: `make dev-test FILTER=AgentHandoffUITests`.
- Codex handoff first-send and native start/resume state: `make dev-test FILTER=AgentModeRunServiceLifecycleTests`.
- Shortcut names, defaults, notification, and Settings rows: `make dev-test FILTER=KeyboardShortcutCatalogTests`.
- Remote cached-catalog integration: `make dev-test FILTER=RemoteWorkspaceSidebarTests`.

Always run `make dev-lint` for Swift changes. Run `make dev-build` when changing SwiftUI hosting, shortcut registration, notifications, or target composition. Run `make guardrails` when moving source or routed context files.
