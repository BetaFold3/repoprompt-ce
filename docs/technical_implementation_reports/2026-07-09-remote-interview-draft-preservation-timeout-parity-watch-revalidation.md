# Technical Implementation Report - 2026-07-09 - Remote Interview Follow-ups: Draft Preservation, Timeout Resolution Parity, Gateway Watch Revalidation

## Session Overview

Follow-up wave to the remote Skip All fix stack (commit 22fe0ed, see `docs/technical_implementation_reports/2026-07-09-remote-skip-all-payload-and-respond-recovery-fixes.md`). Same operating mode: explore-probe reconnaissance → oracle-designed plan → engineer implementation → orchestrator verification → oracle review → hardening. The live CE debug app was never stopped or relaunched; validation was coordinated builds + unit tests.

Wave scope (from the prior wave's deferred follow-ups):
1. **Draft preservation on re-sync** — a respond rejected by the host (the -32602 class) triggered the shipped recovery's host re-sync, which re-projected the interview card with **empty drafts**: the user's partial answers were captured but discarded.
2. **End-to-end `submitResponse` wiring tests** — the catch→recovery wiring was previously proven only by inspection + unit-level tests.
3. **PWA payload audit** — explore-probe verdict: **unaffected**; the PWA has no interview UI at all and sends only `{response, interaction_id?}` (`app.js:591–598`). No code change.
4. **Host-timeout/disarmed-watch gap** — probe-confirmed and **broader than hypothesized**: the gateway parks a session (stops watching) on any actionable snapshot and re-arms only per-device on respond/steer, so a remote device went permanently dark after ANY out-of-band exit from the actionable state — host-side `ask_user` timeout (always armed, default 300s), host-local user resolution, or another device responding. Compounding host bug: the timeout path skipped `recordMCPInteractionResolution` (the user path records), so no `_meta.interaction_resolved` and no waiter wake even existed for timeouts.

## Implementation Details

### 1. Draft stash + merge (client, `RemoteAgentModeCoordinator.swift`)

New tab-keyed `StashedAskUserState` (interactionID, drafts, currentQuestionIndex). `recoverFromRespondFailure` stashes at entry (before the `attachAndCatchUp` await — the MainActor suspension means the event task can deliver the re-applied `.runState` mid-await). `applyRunState`'s `.question` branch merges via `mergedPendingAskUser` behind a triple gate: stash present, **exact interactionID match**, and the incoming pending's drafts all `!hasContent` (protects against a future host echoing drafts). Merge copies stash drafts only for question IDs present in the incoming interaction, clamps the question index, and consumes the stash (one-shot). Clearing sites: merge consumption, different-interaction arrival, other interaction kinds, nil pending, `applyTerminal`, `sessionExpired`, channel-revoked, `clearResolvedInteraction` (ID-matched), local-restore consumption, `stop(tabID:)`. Timeout timestamps are deliberately not stashed — the host owns the authoritative countdown.

### 2. End-to-end respond wiring tests (client)

DEBUG-gated `test_installController(_:for:hostID:)` installs a real `RemoteAgentSessionController` backed by a test-file `StubRemoteConnection` (scripted per-frame-type results) and reuses the production `startEventTask` pump. Four tests drive `submitAskUserResponse` live: command-error → local restore with drafts (stub subscribe also fails); command-error → successful re-sync merges stashed drafts (end-to-end proof of item 1); success → no restore, no failure message; `interactionAlreadyResolved(RemoteCommandError)` → no restore, placeholder status cleared.

### 3. Host parity: timeout records interaction resolution (`AgentModeViewModel.swift` timeout branch)

The timeout-firing path now stages `pendingInteractionResolutionAttribution = "timeout"` (defer-cleared) and calls `recordMCPInteractionResolution(for:interactionID:)` after clearing pending/reconcile and **before** `continuation.resume` — ordering parity-exact with `resolveAskUserResponse`. Effects: `_meta.interaction_resolved` (`resolved_by: "timeout"`) in subsequent snapshots and `wakeCurrentWaiters(.interactionResolved)` — benefits all MCP consumers. `resolved_by` consumers were grepped: free-form string everywhere ("user"/"system"/"mcp"/client identities), so the new value is safe. The prior wave's placeholder-gated `clearResolvedInteraction` (plus its regression test) already covers the repeated-event client side.

### 4. Gateway watch revalidation for parked-actionable sessions (`SessionWatchManager.swift`)

New `parkedActionableSessionIDs` per device (invariants: ⊆ watched, disjoint from activeWait; maintained via helpers, never raw mutation). Sessions park when a snapshot is actionable-and-not-terminal; a new `ensureRevalidationLoop`/`runRevalidationLoop` (task-ID guarded, sinks-or-push gated, `revalidationIntervalSeconds` init param, default 30s, injectable for tests) periodically re-runs the existing `validateAndAddSession` for each parked session — its existing outcome handling does the right thing per case (still actionable → re-park + idempotent re-emit; exited actionable → re-arm + emit the transition; terminal/expired → existing paths; tool error → existing pause path). This covers **all** out-of-band exits for **all** devices — timeout, host-local resolution, and other-device resolution (gateway `rearm` is per-device, so device A previously stayed dark when device B responded).

**Oracle P1 (caught in review, fixed):** the parked→active transition didn't clear `lastPushKindByDeviceSession`, so a disconnected push-eligible device would get **no Web Push for the next interview** (same wake kind → deduped). Fixed with a centralized `unparkOnExitFromActionable` helper at both transition sites (mirroring `rearm`'s dedupe clear; deliberately NOT cleared in `markSessionPendingObservation`, where re-observing the same actionable state must stay deduped) + a `RecordingPushNotifier` regression test.

**Other review hardenings:** `validateAndAddSession` success path now `guard`s device existence (revalidation-loop/teardown race could resurrect a zombie `DeviceState`); `emitExpired` prunes watched/active/parked idempotently (also fixes a pre-existing wart where `pollCatchUp` could re-emit `session_expired` forever); still-actionable revalidation test script padded 10→50 to remove a slow-runner flake.

### Technical Decisions

- **Gateway slow revalidation over host wait-semantics extension**: an event-driven "wake-on-resolution" wait arg was rejected for this wave — it modifies the host wait path every consumer sits on, with builds+unit-tests-only validation and two-directional version-skew exposure; the poll-based loop is gateway-self-contained, reuses proven plumbing, and its cost is bounded (one poll per device per 30s, only while an interview/approval is on screen).
- **Re-emission idempotency accepted**: still-actionable sessions re-emit an identical snapshot each interval — verified benign (client `interactionMatches` preserves state; push kind + resolution key deduped; seqs contiguous). Cost: one client `get_log` round-trip per parked session per interval.

## Testing

65/65 tests across 8 suites (includes all prior-wave suites, unchanged — no destabilization):
- `RemoteAgentModeCoordinatorDraftStashTests` (new, 9), `RemoteAgentModeCoordinatorSubmitResponseWiringTests` (new, 4), `AgentModeViewModelAskUserTimeoutTests` (new, 1), `SessionWatchManagerRevalidationTests` (new, 6 incl. the push-dedupe regression), plus prior-wave `RemoteAgentModeCoordinatorRespondRecoveryTests` (8), `RemoteInteractionResponsePayloadTests` (4), `AgentRunRespondWireContractTests` (3), `GatewayRuntimeBindingTests` (30).
- Both products build (`make dev-swift-build`); `make dev-format` + `make dev-lint` clean.
- Real-device e2e still deferred (host app live throughout).

## Files Modified

- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — draft stash/merge/clear; `applyRunState` internal seam; DEBUG `test_installController`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — timeout resolution recording with "timeout" attribution.
- `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift` — parked-actionable revalidation loop; push-dedupe clear on exit-from-actionable; zombie-device guard; `emitExpired` pruning.
- Tests: `RemoteAgentModeCoordinatorDraftStashTests.swift`, `RemoteAgentModeCoordinatorSubmitResponseWiringTests.swift`, `AgentModeViewModelAskUserTimeoutTests.swift` (new), `SessionWatchManagerRevalidationTests.swift` (new).

## Next Steps

- Real-device e2e of both waves: Skip All on a remote interview (should skip cleanly), a rejected respond (card should restore with drafts), and letting an interview time out (remote client should see the run resume within one revalidation interval; a Web Push should still fire for the next interview).
- Optional hardening deferred: skip re-emission when the parked snapshot payload is unchanged; "prompt restored — please retry" affordance on the restore branch.

## Session Metrics
- **Files Changed**: 7 (3 source, 4 test) + guardrails allowlist + this report
- **Lines Modified**: ~+1330 −5
- **Components Affected**: AgentMode Remote runtime (client), AgentModeViewModel ask_user timeout (host), RepoPromptGateway watch loop

## Lessons Learned
- "Parked" observation states need explicit coverage for out-of-band exits — any design that stops watching on a wake-worthy state must answer "who tells us when it changes without us?" for every exit path, not just the one the happy path exercises.
- Per-device re-arm semantics silently break multi-device topologies; audits should always ask "what do the OTHER subscribers see?".
- Dedupe keys (push wake kinds, resolution keys) are part of the state machine: every new transition needs an explicit decision about each key, or wakes disappear silently.

> Generated from Claude Code session on 2026-07-09
