# Technical Implementation Report - 2026-07-26 - Remote Handoff (Fork) over the Paired-Mac Wire

## Session Overview

Implemented client-triggered, host-executed session forking (handoff) for RepoPrompt CE remote control, v1 paired-Mac topology, per `docs/plans/remote-handoff-fork-2026-07-26.md`. Before this work, handoff was a host-local UI feature with no remote surface: the wire protocol had no fork/extract verb and the client hid the affordance for any `session.remoteHost != nil` session (see `docs/investigations/remote-client-handoff-fork-visibility-2026-07-26.md`).

The session was run as an orchestrated build: five work items dispatched to sub-agents (Items 1+3 in parallel, then 2 → 4 → 5), each verified against the plan's "done when" criteria before the next dispatch. Two sub-agent Oracle review passes contributed fixes (gateway `in_flight` ledger response handling with bounded same-request-ID retries; stale per-host capability cache on final-host removal; degraded-catalog/error-wording findings in the popover).

## Implementation Details

### Item 1 — Wire contract slice

**Problem:** `RemoteWireProtocol.clientFrameTypes` rejected any fork/extract frame; the translator's `rejectPassthroughKeys` blocked smuggling an `op`.

**Changes:**
- `Sources/RepoPromptRemoteWire/RemoteWireProtocol.swift` — `fork_session` added to `clientFrameTypes` **and** `mutatingClientFrameTypes` (request_id required → gateway `CommandLedger` idempotency); `extract_handoff` added as a read-only frame.
- `Sources/RepoPromptRemoteWire/RemoteWireFeatures.swift` — three independently negotiated feature strings: `fork_session` (`.forkSession`), `extract_handoff` (`.extractHandoff`), `get_log_host_row_ids` (`.getLogHostRowIDs`). Auto-advertised via the existing `RemoteWireFeatures.all` hello_ack path.
- `Sources/RepoPromptGateway/Auth/ScopeEnforcer.swift` — `fork_session` → `sessions:operate`; `extract_handoff` → `sessions:observe` (least-privilege split per plan decision D2).
- `Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift` — two `agent_manage` mappings with strict payload allow-lists (`fork_session`: `up_to_item_id`, `destination_agent`, `destination_model_id`, `destination_effort`; `extract_handoff`: `up_to_item_id`, `max_transcript_items`, `max_tool_args_characters`); `include_host_row_ids` added to `getLogPayloadKeys`; both frames added to the `sessionAddressed*` sets. Per D1, `request_id` is **not** forwarded into the MCP payload.
- `Sources/RepoPromptGateway/GatewayRuntime.swift` — `singleSessionIDIfSessionAddressed` extended with both frame types for session-affinity routing.

### Item 2 — Host row IDs (cutoff substrate)

**Problem:** client transcript rows carry synthetic deterministic UUIDs (`RemoteTranscriptProjector.deterministicUUID`), not host `AgentChatItem.id`s, so a client could not name a fork cutoff the host understands.

**Changes:**
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift` + `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift` — `get_log` gains feature-gated `include_host_row_ids`; row `id` attributes are emitted at the same serializer point as the existing `ts` attributes (`ForkItem` now carries `hostRowID`). Output is byte-identical when the flag is absent.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteTranscriptProjector.swift` — parses row `id` attributes into a `hostRowIDByClientItemID: [UUID: UUID]` side-channel on the projected page; malformed/missing IDs are ignored; legacy hosts project identically with an empty map.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` — opts in via `supportsHostFeature(.getLogHostRowIDs)` with the `unsupported_payload_key` latch fallback (mirroring the `get_log_row_timestamps` precedent); accumulates the map, resets it with log-reconciliation state, exposes actor-isolated `hostRowID(forClientItemID:)`.

### Item 3 — Host `fork_session` op + headless fork

**Changes:**
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — extracted session-addressed `prepareHandoffHeadless(...)` (payload build, transcript-prefix migration, background fork-duplicate tab via `createBackgroundForkComposeTab`, oracle-chat clone, destination session config + staged `pendingHandoff`, `scheduleSave`) with **no** foreground steps and no `currentTabID` pinning. `prepareHandoffToNewTab` is now a thin wrapper adding the tab-switch/focus step — one copy of the machinery. Optional cutoff: nil forks the full transcript.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift` — `executeForkSession` (dispatch case `fork_session`): requires a live source session (persisted-only → `invalidParams`; `extract_handoff` covers those); validates the cutoff with `AgentTranscriptIO.isValidHandoffExportCutoffRowID`; validates `destination_agent`/`destination_model_id`/`destination_effort` against host capabilities (plan decision C3); returns `{status: "forked", session: …}` where the descriptor is produced by the same `sessionSummaryObject` encoder as `list_sessions` (plan decision C2 — no hand-rolled descriptor).
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift` — `agent_manage` tool schema documents the new op and destination-value sourcing from `list_agents`.

### Item 4 — Client fork/extract commands + auto-open

**Changes:**
- `RemoteAgentSessionController.swift` — `fork(...)` and `extractHandoff(...)` modeled on `steer` (`commandWithTransportRetry`, stable request IDs so transport retries are absorbed by the gateway ledger). The cutoff sent over the wire is the **host** row UUID via `requireHostRowID(forClientItemID:)` — never the client synthetic ID. Clear errors for feature-unsupported hosts and unmapped cutoffs. Fork result parsed with a single-entry variant of the existing `sessionDescriptors(from:)` (C2).
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — `fork(...)` sends the command, materializes the returned descriptor via `materializeRemoteWorkspaceSession` (auto-open on the client comes free; duplicate descriptor → no-op), then force-refreshes the workspace session catalog. `extractHandoff(...)` returns payload XML for the clipboard. Per-host fork-capability cache behind `canForkRemoteSession(session:)`.
- **MainActor bridge for per-row gating (C1):** `.transcriptRows` controller events carry the complete row-ID snapshot; the coordinator mirrors it per tab (`hostRowIDByClientItemIDByTabID`) and exposes synchronous `hostRowID(for:clientItemID:)`. Capability or mapping flips trigger `syncRunInteractionUIState()`.

### Item 5 — Client UI integration

**Changes:**
- `AgentModeViewModel.swift` — `canForkCurrentSession` branches: `remoteHost != nil` → `remoteCoordinator.canForkRemoteSession(session:)`; local behavior unchanged.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift` — per-row gating (C1): `handoffConfig(for: item.id)` returns non-nil for remote sessions only when the synchronous host-row lookup resolves; rows without a mapping show no handoff button.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentHandoffTypes.swift` — `AgentHandoffConfig` is destination-source aware (`.localProviders` vs remote catalog); `performHandoff` takes an `AgentHandoffDestination`; `buildPayloadForClipboard` is throwing so remote extraction failures surface in the popover instead of silently returning empty.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentHandoffPopover.swift` — remote branch renders destinations from `RemoteHostAgentCatalog.structuredAgentGroups` with the effort chip from `effortOptions`, sending exactly the catalog's raw values (C3); degraded catalog disables Handoff but keeps Copy Payload; legible action-specific `inDoubt` error text (plan tradeoff T4); note that remote forks use the host tab's last stored selection for file contents (T1).

### Technical Decisions

- **D1** — fork op lives in `agent_manage`; idempotency is gateway-ledger-only, `request_id` never enters the MCP payload.
- **D2** — Copy Payload is a separate read-only `extract_handoff` frame under `sessions:observe`; `output_path` and `include_file_contents` are excluded from the remote key set.
- **D3 / C1** — cutoff identity via feature-gated host row IDs in `get_log`; per-row (not per-session) UI gating means the v1 client always sends a resolved host cutoff by construction.
- **C2** — one descriptor encoder (`sessionSummaryObject`) shared by `list_sessions` and `fork_session`; one client parser.
- **C3** — destination raw strings validated exclusively by the host against its own capabilities.
- Old-host/new-client skew degrades to today's behavior (no button); legacy `get_log` output stays byte-identical.

## Testing

Focused daemon suites, all green:

| Area | Suites | Result |
|---|---|---|
| Wire/gateway (Item 1) | `RemoteWireProtocolTests` (12), `GatewayAuthScopeEnforcerTests` (6), `RemoteCommandTranslatorTests` (30) | pass |
| Host row IDs (Item 2) | `RemoteTranscriptProjectorTests` (15), `AgentManageMCPToolServiceResumeTests` (3), `RemoteAgentSessionControllerSettleTests` (11), `AgentTranscriptRowTimestampExportTests` (3) | pass |
| Host fork (Item 3) | `AgentManageMCPToolServiceForkTests` (4, new — incl. the T3 integration test proving a post-fork send begins with the `<forked_session>` payload), `AgentModeChatSwitchActivationTests` (5) | pass |
| Client commands (Item 4) | `RemoteAgentSessionControllerSettleTests` (15), `RemoteWorkspaceSidebarTests` (46) | pass |
| UI (Item 5) | `AgentHandoffUITests` (4, new), `RemoteWorkspaceSidebarTests` (47) | pass |

Also per item: `make dev-lint` (format-check + SwiftLint strict) green; `make dev-test-list` confirmed every new XCTest ID; contract-ledger rows added surgically for all new tests. Item 5 finished with a full `make dev-swift-build PRODUCT=RepoPrompt` (pass).

**Full root suite (`make dev-test`):** exit 1 with four failing suites — `GitLoadedRootAuthorityEvidenceTests`, `AgentRunWorktreeStartTests`, `CodeMapRootManifestStoreTests`, `DurableArtifactStoreTests` — none overlapping this feature's files, and every fork/handoff suite passed inside that same run. All four were rerun focused and **passed in isolation** (0 failures each; the Git suite ran 48 tests with 2 skipped). Verdict: parallel-execution contention flakes (the full-run log shows bootstrap-socket lock contention `errno 35`, tool-execution watchdog kills, and 60 s timeouts), not regressions.

**Not yet run (requires the user):** the live MCP smoke (`make dev-run` + `rpce-cli-debug agent_manage op=fork_session` — visible app launch) and the plan's required paired-Mac v1 sign-off: fork at a chosen message from the client → session auto-opens on the client → first steer delivers the `<forked_session>` payload (verified host-side) → Copy Payload returns the XML.

## Challenges Encountered

- **Actor isolation vs synchronous UI gating:** the controller's row-ID map is actor-isolated, but C1 requires a synchronous MainActor per-row check. Resolved by carrying the row-ID snapshot on `.transcriptRows` events and mirroring it per tab in the coordinator.
- **Shared-checkout entanglement:** the working tree also carries an unrelated in-flight flight-recorder/Sentry telemetry workstream (see below) plus pre-existing contract-ledger drift (222 missing / 1 stale, unchanged by this work). Sub-agents were scoped to disjoint files and verified not to touch each other's areas.
- **Full-suite flakes:** four unrelated suites failed under full-parallel load; isolation reruns proved them environmental.

## Working-Tree Boundary (staging guidance)

Feature files to stage (source): `RemoteWireProtocol.swift`, `RemoteWireFeatures.swift`, `ScopeEnforcer.swift`, `RemoteCommandTranslator.swift`, `GatewayRuntime.swift`, `AgentManageMCPToolService.swift`, `MCPAgentControlToolProvider.swift`, `AgentModeViewModel.swift`, `AgentTranscriptServices.swift`, `RemoteAgentSessionController.swift`, `RemoteTranscriptProjector.swift`, `RemoteAgentModeCoordinator.swift`, `AgentHandoffPopover.swift`, `AgentHandoffTypes.swift`, `AgentModeView.swift`. Tests: the suites named above, including new `Tests/RepoPromptTests/MCP/AgentManageMCPToolServiceForkTests.swift` and `Tests/RepoPromptTests/AgentMode/AgentHandoffUITests.swift`, plus feature rows in `Scripts/Fixtures/test-suite-contract-ledger.tsv` (**mixed file** — the telemetry workstream may also have rows; stage hunks selectively and rerun the preflight after partial staging).

Do **not** stage with this feature: the flight-recorder/telemetry workstream (`Package.swift`, `RepoPromptApp.swift`, `Sources/RepoPrompt/Infrastructure/Telemetry/*`, `Sources/RepoPromptShared/Diagnostics/*`, `RemoteHostConnection.swift`, `RemoteHostConnectionManager.swift`, `GatewayHTTPServer.swift`, push/audit/ticket/VAPID stores, `SessionWatchManager.swift`, `RemoteWireFrames.swift`/`JSONValue.swift` `origin_request_id` changes, settings/telemetry files and their tests), and `docs/investigations/*` (intentionally local per repo policy).

## Next Steps

### Immediate TODOs
- User-run paired-Mac end-to-end sign-off (required by the plan before calling v1 done) and the live MCP smoke.
- Stage feature files only, then run `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` (rerun after any partial-staging change) and `preflight.sh push` before pushing.

### Technical Debt / Deferred
- No PWA (gateway browser client) handoff UI in v1 — wire verbs exist, so a PWA affordance is additive later.
- `include_file_contents` unavailable remotely (T1): remote forks use the host tab's last stored selection snapshot.
- A user-level retry after an `inDoubt` fork error can create a second fork (T4) — same semantics as remote `start`, accepted for v1.
- Pre-existing contract-ledger drift (222 missing / 1 stale) predates this work and remains for its owning workstream.

## Session Metrics
- **Work items:** 5 (orchestrated; Items 1+3 parallel, then 2 → 4 → 5)
- **Feature files changed:** ~15 source + 11 test files + ledger fixture (within a 60-file dirty tree shared with an unrelated workstream)
- **New tests:** fork op suite (4), handoff UI suite (4), plus additions across 9 existing suites; every new ID ledger-recorded
- **Components affected:** RepoPromptRemoteWire, RepoPromptGateway (auth/translator/runtime), host MCP agent tools, AgentMode remote runtime, AgentMode UI

> Generated from Claude Code orchestration session on 2026-07-26
