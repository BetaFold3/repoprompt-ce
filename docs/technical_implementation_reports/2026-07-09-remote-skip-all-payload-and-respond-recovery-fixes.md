# Technical Implementation Report - 2026-07-09 - Remote Skip All: Wire-Illegal Payload Fix, Respond-Failure Recovery, Gateway Rearm-on-Failure

## Session Overview

Deep investigation → oracle-planned implementation → oracle review → hardening cycle for a remote-control interview regression (native client on MacBook Pro ↔ gateway ↔ host on Mac Studio) observed 2026-07-09 in remote session `FBF779E1-D887-4950-A410-0B14EDAD18B5`:

- Pressing **Skip All** on a remote `ask_user` questionnaire failed with `Remote response failed: Error: [-32602] Invalid params: skip cannot be combined with answers.` (09:24:18) — the skip never took effect on the host.
- The client then **hung**: spinner stuck on "Sending response to Tuan's Mac…", interview card destroyed, no retry path.

Investigation (report: `docs/investigations/remote-skip-all-32602-client-hang-2026-07-09.md`, local/git-excluded; oracle implementation plan: `docs/investigations/remote-skip-all-fix-implementation-plan-2026-07-09.md`, local/git-excluded) established **two independent defects** plus a gateway-side severity amplifier, all remote-path-specific and unrelated to the f7de921 wave. Implementation ran as one engineer worker validated through the lane-serialized conductor daemon; the live CE debug app was never stopped or relaunched.

## Root Causes (established before implementation)

- **Defect 1 — client assembles a wire-illegal respond payload.** `AgentAskUserInteraction.buildSkippedResponse` (`UserInteractionModels.swift:459–469`) legitimately produces the in-process dual shape (response-level `skipped: true` **plus** one content-free skipped entry per question). `RemoteInteractionResponsePayload.askUser(_:)` (`RemotePendingInteraction.swift`, introduced in `ace9d39`) serialized it verbatim — top-level `skip: true` **and** a non-empty `answers` object. The gateway translator is a faithful pass-through; the host's pre-existing validation (`AgentRunMCPToolService.swift:2623`, present since the initial CE snapshot `351e980`, sole occurrence repo-wide) checks dictionary **keys**, not content → -32602. Host-local Skip All never hits this validation (in-process continuation resume), and "Skip Question" is unaffected (submits with response-level `skipped: false`). A pure `skip: true` is losslessly reconstructed host-side via `mcpResolvePendingInteraction` `.question` → `skipAskUser` (`AgentModeViewModel.swift:~7327`).
- **Defect 2 (client half) — optimistic clear with no failure recovery.** `RemoteAgentModeCoordinator` cleared the pending card and set the "Sending response to …" transport status **before** sending; `submitResponse`'s generic catch only appended a system message — no pending restore, no runState/status reset, no re-sync. `RemoteAgentSessionController.respond` propagates command errors before `applySnapshot`/`catchUpFromHost`; only `.inDoubt` and `.interactionAlreadyResolved` had recovery paths. Applies to **all four** respond kinds.
- **Defect 2 (gateway half) — watch disarmed, re-armed only on success.** When an actionable (waiting_for_input) snapshot is emitted, `SessionWatchManager` removes the session from `activeWaitSessionIDs` (`handleWaitSnapshot` :383–387) — by design, ball in the client's court. The only re-arm was `GatewayRuntime.swift:362–364`, called **exclusively on respond/steer success**. After the failed Skip All, no passive frame could ever arrive: host-side state changes, other-device resolutions, and host `ask_user` timeouts were all invisible. Only client steer/cancel, re-attach, or an incidental app-link reconnect could heal.

## Implementation Details

### Fix (a) — Client payload: pure skip on the wire

**Problem Statement:** Skip All emits `skip: true` + non-empty `answers`; the host rejects the combination.

**Solution Approach (oracle-designed):** two layers in `RemotePendingInteraction.swift`:

```swift
static func askUser(_ response: AgentAskUserResponse) -> RemoteInteractionResponsePayload {
    guard !response.skipped else {
        return RemoteInteractionResponsePayload(skip: true)
    }
    // existing answers-map construction unchanged
```

and a factory-proof serialization gate in `wirePayload`:

```swift
if let answers, !skip { object["answers"] = answers }
```

Lossless by construction: `response.skipped == true` is produced only by `buildSkippedResponse`, whose entries are provably content-free, and the host rebuilds the identical all-skipped resolution from `skip: true` alone. Partial skips (skipped drafts + Submit) are untouched — they ship `skip` omitted with content-free skipped entries, which host validation already accepts. Gateway translator deliberately untouched (semantics-free pass-through).

### Fix (b) — Client: layered respond-failure recovery

**Problem Statement:** any remote respond rejection stranded the client with a destroyed card, `.running` state, and a stuck "Sending response to …" spinner.

**Solution Approach (oracle-designed, orchestrator-resolved unknowns):** in `RemoteAgentModeCoordinator.swift`:

- New nested `RestorableInteractionState` (interactionID, prior runState, all four pending slots — `AgentAskUserPendingState` carries the user's drafts and question index). `optimisticallyClearPendingInteraction` captures it at exactly clear time and returns it; the four `submit*` methods thread it into `submitResponse(…, restorable:)` (compile-enforced — no other call sites).
- New internal `recoverFromRespondFailure(tabID:restorable:controller:)`:
  1. Re-fetch the session (tab may have closed across the await), unconditionally clear the transport status + `hostProvidedRunningStatusTabIDs`— **before** re-sync, so a successful re-sync repopulates status correctly.
  2. Re-sync from host truth via the existing `controller.attachAndCatchUp()` seam (do/catch, falls through on error). Poll-applied snapshots bypass seq gating; the re-subscribe is idempotent gateway-side and itself re-emits an actionable snapshot.
  3. Gated local restore fallback (offline path): global gate `runState == .running` (state still looks like our optimistic clear — never clobbers terminal or snapshot-applied waiting states), per-slot nil gates (never clobbers newer interactions), fresh `refetchedSession` binding after the await, then `reconcileInteractiveRunState` — verified to recompute runState from pending slots **and** clear running status for waiting states (`AgentModeViewModel.swift:3551–3574`).
- Wiring: generic catch → system message + recovery with the live controller; outer catch (controller creation failed) → recovery with `controller: nil` (straight to restore). `interactionAlreadyResolved` keeps its existing `clearResolvedInteraction` path.
- Documented trade-off: offline restore may briefly re-surface a concurrently resolved card; the next sync or `interaction_resolved` frame clears it through the normal remote paths.

### Fix (c) — Gateway: rearm-on-failure (systemic backstop)

**Problem Statement:** after a failed respond on an actionable session, the gateway watch stays disarmed forever — no client implementation (including the PWA) can passively recover.

**Solution Approach:** mirror the success-branch rearm in `GatewayRuntime.swift`'s catch branch, after `ledger.complete` + `audit`, **before** the `binding_required` special case so both failure return paths are covered:

```swift
if frame.type == "steer" || frame.type == "respond" {
    await watchManager.rearm(deviceID: deviceID, sessionID: frame.sessionID)
}
```

All failure classes, no filtering: `rearm` mutates only gateway state and is guarded by `watchedSessionIDs.contains`; the wait loop's own error handling degrades gracefully when the app link is down. Loop-safe by construction: the still-actionable session's next wait snapshot re-emits once and `handleWaitSnapshot` re-disarms — a one-shot re-push, idempotent client-side via `interactionMatches`. Ledger-dedupe early-return paths intentionally get no rearm (consistent with success-side dedupe).

### Tier 2 — Wire-contract test seam

`AgentRunMCPToolService.parseResponsePayload` changed `private` → `internal` (`/// Internal for wire-contract round-trip tests.`) — zero behavior change, enables the true client→translator→host round-trip test that would have caught defect 1 pre-ship.

### Technical Decisions

- **Fix location for defect 1 is the client, not the host or gateway.** The host contract predates the remote client and is the documented form for headless MCP callers; the gateway is deliberately semantics-free. Host-side tolerance (accepting content-free skipped entries alongside `skip`) was consciously **not** implemented — it would loosen validation for all third-party callers (locked by test `testSkipPlusAnswersStillRejectedForThirdPartyCallers`).
- **Recovery is layered client-side AND backstopped gateway-side** because they heal disjoint failure sets: the client fix works against today's deployed gateway and covers client-local failures (controller creation, second-attempt transport loss) that never reach the gateway; the gateway fix heals all client implementations without client updates. Version skew is safe in both directions.
- **Status-clear ownership (oracle P1, post-review).** The first implementation cleared status unconditionally in `clearResolvedInteraction` — a regression: `RemoteAgentSessionController.applySnapshot` yields `.runState` (which applies host status) and then `.interactionResolved` on **every** snapshot carrying `_meta.interaction_resolved` (no client-side dedupe; snapshots carry the most recent resolution on every wait/poll response), so any later snapshot would wipe a just-applied "Thinking…" for the rest of the run. Final form: a shared `sendingResponseStatusPrefix` constant, and `clearResolvedInteraction` clears **only** the coordinator-owned placeholder (gated on `.transport` source + prefix match). `recoverFromRespondFailure` keeps its unconditional clear — that path is genuinely ours.

## Bug Fixes

1. **Remote Skip All rejected with -32602** — Symptoms: error banner, skip ineffective. Root cause: client-assembled `skip`+`answers` combination vs. key-presence host validation. Fix: pure-skip payload + wire gate (fix a).
2. **Client hangs after any respond failure** — Symptoms: stuck "Sending response to…" spinner, destroyed card, no retry. Root cause: optimistic clear with message-only failure handling + gateway watch disarmed with success-only rearm. Fix: layered recovery (fix b) + rearm-on-failure (fix c).
3. **(Introduced-then-fixed during review) redundant `interaction_resolved` events wiping live host status** — caught by oracle post-review as P1 before commit; fixed with the gated placeholder-only clear + two regression tests.

## Challenges Encountered

- **Distinguishing "no deterministic recovery" from "permanent divergence".** An early hypothesis — "any later host push heals the client via `applyRunState`" — was retracted after tracing the gateway watch lifecycle: disarm-on-actionable (`SessionWatchManager` :383–387) + success-only rearm meant no passive frame could arrive at all. This upgraded fix (c) from defense-in-depth to a required backstop.
- **`attachAndCatchUp` reentrancy concerns** (actor serialization, seq gating, `didTerminalSettleReRead`) were analyzed and found benign: poll-applied snapshots carry no seq; worst case is one redundant `get_log` re-read; a raced restore converges because the queued `applyRunState` re-imposes host truth via `clearPendingInteractions(preserving:)`.

## Testing

45/45 focused tests pass via the conductor daemon (`./conductor test --filter 'RemoteInteractionResponsePayloadTests|RemoteAgentModeCoordinatorRespondRecoveryTests|AgentRunRespondWireContractTests|GatewayRuntimeBindingTests'`):

- `Tests/RepoPromptTests/AgentMode/RemoteInteractionResponsePayloadTests.swift` (new, 4): Skip All omits answers; partial skip keeps answers/omits skip; `wirePayload` gate is factory-proof; all-questions-individually-skipped-via-Submit is not a top-level skip.
- `Tests/RepoPromptTests/AgentMode/RemoteAgentModeCoordinatorRespondRecoveryTests.swift` (new, 8): restore preserves drafts + question index; restore skipped when a newer interaction arrived / after terminal state; status cleared on every branch; approval + userInput/MCP-elicitation restore; P1 regressions (redundant `interactionResolved` preserves host "Thinking…"; the sending placeholder is cleared).
- `Tests/RepoPromptTests/Gateway/GatewayRuntimeBindingTests.swift` (+2, suite 30): failing respond re-arms the watch — second `session_update` reaches the sink with strictly increasing seq, and the count settles at exactly 2 (proves one-shot re-push, no rearm loop); unwatched-session rearm is a no-op.
- `Tests/RepoPromptTests/MCP/AgentRunRespondWireContractTests.swift` (new, 3, Tier 2): Skip All and partial-skip round-trips through the real `RemoteCommandTranslator` + host `parseResponsePayload` pass; hand-built `skip`+`answers` still throws for third-party callers.

Also: `make dev-swift-build PRODUCT=RepoPrompt` and `PRODUCT=repoprompt-mcp` PASS; `make dev-format` + `make dev-lint` clean. Real-device e2e (Skip All from the MacBook against the Mac Studio host) deliberately deferred — the host app was live and in use throughout; validation was builds + unit tests only.

## Files Modified

- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemotePendingInteraction.swift` (+4 −1) — pure-skip `askUser`, `wirePayload` answers gate.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` (+~80 −12) — `RestorableInteractionState`, capture/threading, `recoverFromRespondFailure`, gated `clearResolvedInteraction` status clear, `sendingResponseStatusPrefix`.
- `Sources/RepoPromptGateway/GatewayRuntime.swift` (+3) — rearm on respond/steer failure.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift` (+2 −1) — `parseResponsePayload` internal seam.
- `Tests/RepoPromptTests/AgentMode/RemoteInteractionResponsePayloadTests.swift` (new), `Tests/RepoPromptTests/AgentMode/RemoteAgentModeCoordinatorRespondRecoveryTests.swift` (new), `Tests/RepoPromptTests/Gateway/GatewayRuntimeBindingTests.swift` (+~100), `Tests/RepoPromptTests/MCP/AgentRunRespondWireContractTests.swift` (new).

## Next Steps

### Immediate TODOs (agreed follow-up wave)
- **Draft preservation on re-sync**: validation-class failures re-project the pending card with empty drafts (re-sync wins over restore when the network is healthy — exactly the -32602 class); merge captured drafts when the re-applied interaction matches and slot drafts are empty.
- **End-to-end `submitResponse` wiring test** with a stubbed remote connection (catch → recovery currently proven by inspection + unit-level tests of the recovery method).
- **PWA respond-assembly audit** (`Sources/RepoPromptGateway/Resources/pwa`) for the same skip+answers combination — fix (c) heals its hang, but its payload may still be rejected.
- **Host-timeout/disarmed-watch latent gap** (unverified): a host-side `ask_user` timeout exits the actionable state with no gateway traffic, so a disarmed watch never notifies remote devices — same pattern as defect 2's gateway half.

### Technical Debt Introduced
- Optional "prompt restored — please retry" affordance on the restore branch not added (bare "Remote response failed" next to a silently re-surfaced card is slightly confusing; cosmetic).
- `rearm` on translation-level respond failures re-pushes a snapshot the client already has (idempotent, harmless).

## Session Metrics
- **Files Changed**: 8 (4 source, 4 test) + 2 local investigation docs (git-excluded)
- **Lines Modified**: ~+660 −12
- **Components Affected**: AgentMode Remote runtime (client), RemoteAgentModeCoordinator (client), RepoPromptGateway runtime/watch, Agent MCP tool service (host seam)

## Lessons Learned
- In-process response structs are not automatically wire-legal: `buildSkippedResponse`'s dual shape was fine for continuations but illegal for the MCP contract. The new round-trip contract test (`build → serialize → translate → host-parse`) is the cheap guard for every future respond kind.
- Optimistic UI clears need a captured, restorable counterpart the moment a network boundary is involved — and the recovery must be layered (authoritative re-sync first, local restore for offline).
- "Push will eventually heal it" must be verified against the watch/arm lifecycle, not assumed from the frame-application code: the disarm-on-actionable + success-only-rearm pair made the divergence deterministic, not incidental.

> Generated from Claude Code session on 2026-07-09
