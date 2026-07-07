# Technical Implementation Report - 2026-07-08 - Remote-Control Session UX Gaps (S1–S4)

## Session Overview

End-to-end investigation → implementation → review cycle for four remote-control (client ↔ gateway ↔ host) session UX gaps on `feat/remote-client-native`. A deep investigation produced root causes with file:line evidence (`docs/investigations/remote-session-ux-gaps-2026-07-07.md`, local artifact); implementation was fanned out across five delegated worker sessions in two file-disjoint waves; results landed in commits `fbf062e` (Phase 1) and `a5e8322` (Phase 2 + hardening). A final oracle review of the committed range returned **no blockers, no majors**; its two confirmed minor defects were fixed in this session as fast-follows with regression tests and ledger rows (committed here).

The four symptoms:

- **S1 (bug)**: remote-started sessions kept default incremental names ("T10") on the host.
- **S2 (bug/feature)**: child worker/subagent sessions spawned by a remote-controlled parent were invisible on the client.
- **S3 (feature)**: host session rows gave no indication a session is remote-controlled.
- **S4 (feature)**: the client "Run on:" pill showed the full host name instead of a compact abbreviation.

## Implementation Details

### S1 — Remote session naming (client-side)

**Problem Statement:** The client forwarded its own default compose-tab title (`T#` from `PromptViewModel.autoNameForNewTab`) as `session_name`; the host adopted it verbatim (`executeStart` → `mcpResolveOrCreateSessionTarget` → `createBackgroundComposeTab`, where `explicitName ?? autoName` means a non-empty client name always wins). The host-echoed authoritative name was discarded client-side (`_ = sessionName`, formerly `RemoteAgentModeCoordinator.swift:251`), and the wire has no rename op.

**Solution Approach:** Two-part client-only fix. (A) Derive a name from the first user message at remote start when the current title is a default (`AgentSessionTitleNaming.swift`: `^T\d+$`/placeholder predicate + ~40-char word-boundary head), renaming the local tab via `renameSession(tabID:to:)` before the name is captured into the start payload. (C) Adopt the host-echoed name in the coordinator's `.metadata` handler, guarded so user-typed names are never overwritten (default/placeholder titles, last-adopted name, or the name sent at start are the only overwritable classes; tracked in `lastAdoptedHostNameByTabID` / `startSessionNameByTabID`). A host-side `T#` heuristic was explicitly rejected (cannot distinguish a deliberate "T10"; would change behavior for all MCP clients).

### S2 Phase 1 — Spawn tool cards in the remote transcript (host-side)

**Problem Statement:** Remote `get_log` → `buildSpartanLogXML` → `handoffExportEntries` collapsed a completed turn's tool cluster (`groupedHistory`) into a single `<system>` summary row, so the parent's `agent_run` spawn card vanished; the client parser accepts only `user|assistant|system|error|tool_call` tags. Verified not to be tool-visibility suppression (`agent_run` is neither placeholder-suppressed nor in `hiddenTranscriptToolNames`).

**Solution Approach:** Tag-reuse lift-out requiring **zero client parser change**: in the `groupedHistory` branch of `handoffExportEntries` (gated on `preserveIntermediateAssistantNarration == true`, which only the spartan/get_log path passes), spawn-family child blocks (`agent_run`/`agent_manage`) are re-emitted as `<tool_call name="agent_run">…</tool_call>` previews plus a synthesized `<system>Sub-agent <name-or-id>: <status></system>` row when the child result is parseable. Spawn tools are exempted from the failed/cancelled preview prune (a failed child is exactly what the user needs to see). Handoff/fork exports are provably unchanged (negative tests for completed and failed variants).

### S2 Phase 2 — Child session visibility on the client (wire + both ends)

**Problem Statement:** Children are separate host sessions with persisted `parent_session_id`, but the wire `list_sessions` allowlist (`{agent, state, limit}`) had no parent filter and the client never called `list_sessions`.

**Solution Approach:**
- Gateway: `parent_session_id` allowlisted for `list_sessions` only; parent-filtered queries treated as session-addressed for window discovery/routing.
- Host: `executeListSessions` gained an explicit `parent_session_id` filter with never-widening intersection semantics (explicit ∧ metadata-scoped ∧ mismatch → empty; behavior byte-identical for callers omitting the arg); filter applies before `prefix(limit)`.
- Client: `RemoteAgentSessionController.listChildSessions()` (frame reuse — `list_sessions` was already a v1 frame type) + debounced discovery in the coordinator (keyed `hostID|parentRemoteSessionID`; triggers on first running snapshot, terminal, and spawn tool rows) materializing children as remote-bound background tabs threaded under the parent (host child UUID = local session ID, dedup by host + remote session ID, no focus stealing). Defense in depth: client re-filters descriptors by parent even if an old host ignores the arg.

### S3 — Host-side "remote-controlled" badge

`AgentSessionOrigin.remote(deviceID:)` was already stamped for paired-device app links (MCP clientName `remote:<8-hex>`) and persisted in the session index, but never reached the row layer. Added `remoteControlDeviceID` to `SidebarSession` (populated from live `TabSession.origin` else index-entry origin, included in the row content fingerprint and the thread-collapse transform), a `remoteControlledBadge` capsule in `AgentSessionRow` (`antenna.radiowaves.left.and.right`, 8-hex short label, full device in tooltip/a11y), and tooltip disambiguation vs. the generic "MCP Controlled" wording. Phase0/static-token gateway starts (`.mcp("repoprompt-gateway")`) intentionally stay unbadged.

### S4 — Compact "Run on:" pill abbreviation (display-only)

Added `abbreviation` to `AgentRunLocationHostOption`, computed set-wide in `runLocationProps` with a deterministic, permutation-invariant rule: strip apostrophes, tokenize on non-alphanumerics; ≥2 tokens → lowercase initials of the first two ("Tuan's Mac" → "tm"); 1 token → first two chars; collisions extend with successive own-last-token characters; byte-identical display names disambiguate via host-id prefix. Closed pill shows the abbreviation; hover tooltip, menu items, and accessibility label keep the full name. No stored-name or pairing-identity changes.

## Files Modified

Committed in `fbf062e` + `a5e8322` (26 files, +2486/−29), highlights:
- `Sources/RepoPrompt/Features/AgentMode/AgentSessionTitleNaming.swift` (new) — default-title predicate + name derivation
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — remote-start rename-before-capture; child-tab plumbing
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — guarded host-name adoption; debounced child discovery + materialization
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` — `listChildSessions()`
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift` — spawn preview lift-out + status rows (spartan-gated)
- `Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift`, `GatewayRuntime.swift` — allowlist + parent-window routing
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift` — explicit never-widening parent filter
- S3/S4 view/model files (`AgentSessionRows.swift`, `AgentRunLocation.swift`, `AgentRunLocationPill.swift`, sidebar builder/types)
- 7 test files (new/extended), 30 ledger rows

This session's fast-follow (committed with this report):
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — `stop(tabID:)` clears `startSessionNameByTabID`; `completeChildDiscovery` guards `!Task.isCancelled && controllersByTabID[parentTabID] != nil` (top and per-descriptor) with `finishChildDiscovery` cleanup; new `test_startSessionNameRecord` DEBUG hook
- `Tests/RepoPromptTests/AgentMode/RemoteAgentSessionTests.swift` — `testStopClearsStartSessionNameRecord`, `testStoppedParentDoesNotMaterializeChildrenFromLateDiscovery`; `RecordingRemoteAgentSessionConnection` gained `commandDelayNanosecondsByType` for deterministic late-completion races
- `Scripts/Fixtures/test-suite-contract-ledger.tsv` — 2 surgical rows for the new methods

## Key Code Changes

Late-discovery teardown guard (fast-follow):

```swift
private func completeChildDiscovery(
    context: RemoteChildDiscoveryContext,
    descriptors: [RemoteAgentSessionDescriptor]
) async {
    childDiscoveryTasksByKey.removeValue(forKey: context.key)
    // Discovery may resume after the parent tab was stopped (for example a run-location
    // switch): never materialize children or restart discovery for a torn-down parent.
    guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
        finishChildDiscovery(context: context)
        return
    }
    for descriptor in descriptors {
        guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
            finishChildDiscovery(context: context)
            return
        }
        await materializeRemoteChildSession(descriptor, context: context)
    }
    childDiscoveryInFlightKeys.remove(context.key)
    restartPendingChildDiscoveryIfNeeded(after: context)
}
```

## Technical Decisions

- **Client-side naming over host heuristics**: the host cannot distinguish a deliberate "T10" from a default, and origin cannot gate it reliably (phase0 legs stamp `.mcp`). Suppressing `session_name` alone would not fix S1 — the host would generate its own `T#`.
- **Tag reuse for the transcript fix**: deployed clients silently drop unknown XML tags once any known tag matches, so `<tool_call>`/`<system>` reuse ships the fix with zero client change; a `<tool_result>` vocabulary extension would degrade invisibly on old clients.
- **Poll-on-parent-updates over snapshot enrichment**: `child_session_ids` in `AgentRunMCPSnapshot` was explicitly rejected to keep the snapshot contract stable; debounced `list_sessions` on parent activity is sufficient.
- **Never-widening filter semantics** so a remote parent filter can never expand what MCP-connection metadata scoping already permits.
- **Multi-agent orchestration**: wave 1 = four file-disjoint workers (S1, S2-P1, S3, S4) barred from building (single shared checkout); orchestrator validated centrally via the conductor daemon; wave 2 (S2-P2) ran after S1 because both touch the coordinator.

## Bug Fixes (oracle-review fast-follows, this session)

1. **Stale start-name record could overwrite a user-typed title**
   - **Symptoms**: theoretical path — remote start → switch to "This Mac" (`stop`) → user types a title equal to the stale derived string → rebind remote → host metadata passes the `startSessionNameByTabID[tabID] == currentName` guard and renames. Also an unbounded per-tab map leak.
   - **Root Cause**: `stop(tabID:)` pruned `lastAdoptedHostNameByTabID` but not `startSessionNameByTabID`.
   - **Fix Applied**: `startSessionNameByTabID.removeValue(forKey: tabID)` in `stop`.
2. **Late child-discovery completion resurrected torn-down state**
   - **Symptoms**: `list_sessions` response resuming after `stop(tabID:)` still materialized child tabs and re-inserted controllers/host fanout that `stopConnectionFanoutIfUnused` had just torn down.
   - **Root Cause**: the discovery task only handled a *thrown* `CancellationError`; `completeChildDiscovery` never re-checked cancellation or controller presence.
   - **Fix Applied**: guard shown above.

## Testing

- Focused suites all green at commit time (101/101 across `RemoteAgentSessionTests`, `RemoteSidebarBadgingTests`, `AgentRunLocationHostOptionAbbreviationTests`, `AgentTranscriptGroupedHistorySpawnExportTests`, `AgentManageMCPToolServiceListSessionsTests`, `RemoteCommandTranslatorTests`, `GatewayRuntimeBindingTests`), including a spartan-XML → `RemoteTranscriptProjector` round-trip proving deployed-parser compatibility and negative tests for handoff-export invariance.
- This session: `./conductor test --filter RemoteAgentSessionTests` → 32/32 green including the two new regression tests; `make dev-format-check` and `make dev-lint` clean (0/1500 files, 0 violations).
- Ledger: 2 surgical rows appended; `verify-ledger` residual (missing=195/stale=3) confirmed as pre-existing branch drift (HEAD ledger scores missing=198) — untouched per curated-ledger policy.

## Challenges Encountered

- **Wave coordination in a single checkout**: workers were barred from building; one trivial cross-file break (argument labels added to the `.metadata` enum case vs. a DEBUG hook call site) surfaced in the central build and was fixed by the orchestrator.
- **Completed-vs-failed child asymmetry** in S2-P1 tests: completed `agent_run` grouped-history results can retain only `session_id`/`status` while the human name lives in the spawn call args — status-row synthesis now reads args as fallback (result name → args name → result id → args id).
- **Deterministic late-completion race** for the teardown regression test: the recording connection stub only delayed `get_log`; generalized with `commandDelayNanosecondsByType` so `stop()` reliably lands while `list_sessions` is in flight.

## Next Steps

### Immediate TODOs
- Live two-machine smoke (per oracle residuals): spawn-at-end-of-cluster `<system>` adjacency rendering; duplicate spawn preview when call/result rows split grouped/standalone (PLAUSIBLE, cosmetic); old-gateway pairing stays quiet under repeated debounced discovery failures; bounded fanout + full teardown on 2–3-level worker trees.
- Optional cheap hardening: escape host-provided session names embedded in `<system>` spawn-status rows (same class as pre-existing tagged rows).

### Technical Debt Introduced
- `lastAdoptedHostNameByTabID` is in-memory: after relaunch, a host-side rename of a previously adopted non-default title is not re-adopted (accepted guard-design limitation).
- Pre-existing branch ledger drift (195 missing / 3 stale) remains for a dedicated reconciliation pass.

## Session Metrics
- **Files Changed**: 26 (committed range `HEAD~2..HEAD`, +2486/−29) + 3 fast-follow files in this commit
- **Components Affected**: AgentMode remote runtime, transcript export, gateway wire/routing, MCP agent tools, sidebar/status-pill UI
- **Delegated workers**: 1 investigation pair, 4 implementation workers (wave 1), 1 implementation pair (wave 2), oracle (investigation chat + final review)

## Lessons Learned
- Encoder/parser tag vocabularies on a wire boundary need a round-trip contract test; the S2 gap existed because nothing asserted `buildSpartanLogXML` output stays within `parseTranscriptXML`'s accepted set.
- "Meaningful or absent" is the right contract for names crossing a wire; defaults (`T#`) should never leave the client.
- File-disjoint wave planning plus centralized conductor validation lets multiple workers share one checkout safely; the one break came exactly from the single cross-file seam (enum case labels vs. DEBUG hook).

> Generated from Claude Code session on 2026-07-08
