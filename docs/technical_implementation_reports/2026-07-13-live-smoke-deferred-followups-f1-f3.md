# Technical Implementation Report - 2026-07-13 - Live-Smoke Deferred Follow-ups F1–F3

## Session Overview

Implemented the three live-smoke deferred follow-ups specified in `docs/plans/workspace-scoped-remote-control-2026-07-12.md`, then hardened the result through seven rounds of third-party static review and repeated oracle review.

The completed scope is:

1. **F1 — terminal snapshot content revalidation:** a parked terminal session is emitted again when its transcript fingerprint changes, including a fresh push wake for disconnected push-only clients.
2. **F2 — actionable failed remote sends:** an optimistic user row that could not be delivered is marked **Undelivered** and offers an item-level **Resend** action through the normal remote start/steer path.
3. **F3 — explicit recovery feedback:** a tab that surfaced channel degradation appends one one-shot `Remote channel restored.` system row when connectivity returns, regardless of run state.

The follow-up reviews expanded F2's recovery contract to cover selected-window routing, restart persistence, picker lifecycle ownership, ambiguous delivery attribution, in-flight catch-up races, and provider-text optimistic-row deduplication. No remote wire contract, workspace-binding rule, pickup-dedupe contract, or P1-2 local-fallback gate was changed. The visible app was not launched or stopped.

## Implementation Details

### F1: Content-Fingerprinted Terminal Re-emission

**Problem Statement:**

The gateway suppressed every terminal-to-terminal observation. A host turn that started and completed between revalidation intervals could change the terminal transcript without changing terminal status, leaving an attached or push-only remote client permanently unaware of the new content.

**Solution Approach:**

`SessionWatchManager` now records a `TerminalFingerprint` per device/session using the actual snapshot payload fields `transcript_item_count` and `updated_at`. On a terminal-to-terminal observation:

- an empty or first usable fingerprint is silently adopted as the baseline;
- newly available components are merged into the stored baseline;
- a changed known component emits a new `session_terminal` frame with a fresh sequence;
- an unchanged fingerprint remains suppressed;
- a changed terminal clears `lastPushKindByDeviceSession` before `maybePushWake`, making it a new wake-worthy transition for disconnected clients;
- unsubscribe, device removal, and manager teardown clear fingerprint state with the existing per-session lifecycle state.

Representative production logic:

```swift
if evaluateTerminalReemitAdoptingBaseline(forKey: key, newFingerprint: fingerprint) {
    await emitInteractionResolvedIfNeeded(deviceID: deviceID, snapshot: snapshot)
    let seq = nextSeq(deviceID: deviceID, sessionID: snapshot.sessionID)
    let frame = RemoteServerFrame(
        type: "session_terminal",
        sessionID: snapshot.sessionID,
        seq: seq,
        payload: snapshot.payload
    )
    await broadcast(frame, deviceID: deviceID)
    lastPushKindByDeviceSession.removeValue(forKey: key)
    await maybePushWake(deviceID: deviceID, snapshot: snapshot)
    return
}
```

**Files Modified:**

- `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift` — fingerprint state, baseline adoption/merge, re-emission, push-dedupe reset, and lifecycle cleanup.
- `Tests/RepoPromptTests/Gateway/SessionWatchManagerRevalidationTests.swift` — changed-count, changed-timestamp, unchanged/missing-field, push-only wake, and live-sink regressions.
- `Tests/RepoPromptTests/Gateway/SessionWatchManagerTerminalEdgeTests.swift` — fingerprint cleanup across unsubscribe/resubscribe.

### F2: Undelivered Remote Send and Resend Recovery

**Problem Statement:**

A remote transport failure left the optimistic user bubble looking delivered even though the host might never have received it. Recovery also had to remain correct across adopted sessions, explicit window selection, app restart, picker displacement, catch-up races, and provider-side text transformations.

**Solution Approach:**

Failed remote sends now retain the optimistic item identity, mark the row with `isUndeliveredRemoteSend`, and store a normalized `RemoteResendPayload`. The UI renders an **Undelivered** badge and exposes **Resend** only while a live remote binding and usable payload exist and the item is not already in flight.

`resendUndeliveredRemoteUserTurn` routes through the existing remote coordinator:

- failed starts retry as starts when no host session was adopted;
- a failed start attributed to the already-adopted session reconciles via host catch-up instead of duplicating it;
- an older start whose attribution does not match a later adopted session is sent as a steer;
- picker-worthy target errors, including `binding_required`, reopen target selection;
- selected targets use either `windowID` with optional `workspaceID`, or a name-only selector, never a mixed selector;
- transport failure after host catch-up silently discards stale recovery state rather than recreating a delivered failure;
- local fallback clears undelivered/resend state while leaving `canRunLocallyAfterRemoteFailure` unchanged.

The resend state machine uses these per-session stores:

```swift
var pendingRemoteOptimisticUserItemIDs: Set<UUID> = []
var pendingRemoteOptimisticProviderTextByItemID: [UUID: String] = [:]
var remoteResendPayloadsByItemID: [UUID: RemoteResendPayload] = [:]
var remoteResendInFlightItemIDs: Set<UUID> = []
var locallyAttributedStartItemID: UUID?
```

#### Restart-safe recovery

The implementation persists the recovery data required to make an undelivered row actionable after relaunch:

- `isUndeliveredRemoteSend` round-trips through structured transcript request anchors and activities;
- `PersistedRemoteResendPayload` stores provider text, start/steer mode, model/session metadata, and a normalized target selector;
- `locallyAttributedStartItemID` prevents a post-restart resend from falsely treating an unrelated later adopted session as delivery of the old start;
- hydration filters payloads to real flagged user items, reseeds pending optimistic IDs, and restores provider-text correlation;
- backward-compatible `decodeIfPresent` handling preserves legacy sessions.

#### Picker lifecycle ownership

`pendingRemoteStartWindowPicker` remains a single presentation slot but now has explicit ownership rules:

- a new picker displaces a different tab/item pair by resolving the old operation as `remote_start_superseded`;
- presentation marks the optimistic row undelivered and persists recovery before showing the sheet;
- selection clears the slot before looking up the owning session;
- cancel, tab teardown, session removal, workspace reset, and local fallback clear only a matching picker;
- asynchronous continuations verify the exact live `TabSession` identity before changing state or reopening a picker.

#### Provider-text catch-up deduplication

The displayed bubble text can differ from the provider-facing text because of interview-first wrapping, workflow envelopes, and slash-skill stripping. Pending optimistic items now retain the exact provider text until host catch-up. `RemoteAgentModeCoordinator` uses that correlation key for timestamp rescue and optimistic-row removal, with displayed-text fallback for legacy state, and prunes it in lockstep with pending IDs.

**Files Modified:**

- `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift` — persisted/decode-tolerant undelivered row flag and timestamp-copy preservation.
- `Sources/RepoPrompt/Features/AgentMode/Models/AgentTranscriptModels.swift` — undelivered flag in transcript anchors and activities.
- `Sources/RepoPrompt/Features/AgentMode/Models/RemoteStartWindowSelection.swift` — picker state retains the original name selector and supports target-error recovery.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift` — persisted resend payload and local-start attribution.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift` — transient resend, in-flight, pending-ID, provider-text, and attribution state.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift` — local fallback cleanup without changing P1-2 eligibility.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — failure marking, resend routing, save/hydrate recovery, picker lifecycle, ownership guards, and provider-text retention.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — provider-text-aware catch-up and lockstep recovery-state pruning.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentMessageBubble.swift` — Undelivered badge, Resend button, and muted failed-row styling.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift` — per-item resend action wiring.
- `Tests/RepoPromptTests/AgentMode/RemoteWorkspaceSidebarTests.swift` — resend, persistence/hydration, picker, attribution, selector, race, and transformed-text regressions.
- `Tests/RepoPromptTests/AgentMode/RemoteAgentClientFixesTests.swift` — production save/hydrate/recovery and client-state coverage.
- `Tests/RepoPromptTests/AgentMode/RemoteAgentSessionTests.swift` — optimistic catch-up and provider-text matching coverage.

### F3: One-Time Remote Channel Restored Row

**Problem Statement:**

After a degraded channel recovered, an idle attached tab could return to normal with no visible confirmation because prior behavior emphasized active-run status labels.

**Solution Approach:**

`RemoteAgentModeCoordinator.applyChannel` checks whether the tab surfaced any degraded reasons before clearing `surfacedChannelReasonsByTabID`. If so, a single system row is appended regardless of run state:

```swift
case .connected:
    let hadSurfacedDegradation =
        !(surfacedChannelReasonsByTabID[session.tabID] ?? []).isEmpty
    surfacedChannelReasonsByTabID[session.tabID] = []
    if hadSurfacedDegradation {
        appendSystemMessage("Remote channel restored.", to: session)
    }
```

Tests cover both the idle degraded-to-connected path and a connected transition that had no surfaced degradation.

## Technical Decisions

- **No wire changes:** all recovery is implemented with existing `session_terminal`, start, steer, log catch-up, and channel-state contracts.
- **Actual payload keys are authoritative:** the gateway fingerprints `transcript_item_count` and `updated_at`; the plan's descriptor names are not used against snapshot payloads.
- **Component-wise fingerprint comparison:** partial payloads learn newly available fields without treating absence as a change or forgetting known fields.
- **Push dedupe is reset at the transition site:** the existing `maybePushWake` contract remains narrow.
- **Keep optimistic IDs after ambiguous failure:** this allows host catch-up to absorb a send that succeeded despite a lost acknowledgement.
- **Persist only normalized resend state:** selectors are ID-form or name-form, and window-only routing is supported because `windowID` is the gateway's authoritative explicit selector.
- **Persist local-start attribution:** nil attribution is not sufficient evidence that an old start produced a later adopted session after restart.
- **Provider text is correlation state, not display state:** exact dispatched text owns catch-up matching; the user-facing bubble remains unchanged.
- **Single picker slot with explicit displacement:** a per-tab picker redesign was avoided; ownership checks and recoverable displacement contain the existing UI architecture.

## Bug Fixes from Review Rounds

1. **Fingerprint re-emission did not wake push-only clients**
   - **Root Cause:** terminal push dedupe still contained `sessionTerminal`.
   - **Fix:** clear the per-device/session push kind only for a fingerprint-changed re-emission.

2. **Partial fingerprints could remain permanently blind**
   - **Root Cause:** a newly available component was not merged unless another component changed.
   - **Fix:** merge non-nil components on suppression and emission paths.

3. **Selected-window resend lost or contradicted its target**
   - **Root Cause:** retries dropped IDs, mixed picked IDs with stale workspace names, or rejected window-only selectors during persistence.
   - **Fix:** normalize selector forms and round-trip `windowID` with optional `workspaceID`.

4. **Restart made an Undelivered badge non-actionable**
   - **Root Cause:** the row flag, payload, and attribution lived in different persistence paths or were transient.
   - **Fix:** persist the structured transcript flag, normalized resend payload, and local-start attribution; rehydrate them together.

5. **Restart while the picker was open lost the send**
   - **Root Cause:** picker state was transient and presentation saved an apparently delivered optimistic item.
   - **Fix:** mark/persist recovery before picker presentation and restore Resend after relaunch.

6. **Concurrent picker requests stranded state**
   - **Root Cause:** a global picker slot was overwritten without releasing the displaced session or in-flight item.
   - **Fix:** resolve displacement as a recoverable failure and enforce picker ownership during teardown/async completion.

7. **Successful remote catch-up could duplicate transformed user text**
   - **Root Cause:** dedup compared displayed `bubbleText` with host/provider `wrappedText`.
   - **Fix:** retain provider-facing text until host truth replaces the optimistic item.

8. **Host catch-up during resend could leave orphan recovery state**
   - **Root Cause:** a later transport failure recreated state after the optimistic row had already been removed.
   - **Fix:** validate item/session ownership before failure handling and prune pending/provider/payload/in-flight state together.

## Challenges Encountered

- **Large pre-existing uncommitted stack:** the work had to preserve v1 changes and avoid unrelated cleanup. Edits and ledger changes stayed within the F1–F3 seams and their tests.
- **Ambiguous-delivery semantics:** a failed acknowledgement does not prove failed delivery. The solution retains pending correlation, distinguishes locally attributed starts from unrelated adopted sessions, and defers final truth to host catch-up.
- **MainActor suspension races:** picker fetch, resend transport, and catch-up can interleave with tab teardown. Exact `TabSession` identity checks prevent detached continuations from mutating a replacement session.
- **Daemon lane hang:** a gateway test fixture deadlocked and held the coordinated build lane. The hung ticket was cancelled, the fixture gating was corrected, and all coordinated validation was rerun.
- **Ledger baseline is already red:** `verify-ledger` reports `missing=195 stale=0` at this HEAD. The acceptance gate was zero new drift; the before/after result remained identical.

## Code Quality Improvements

- Centralized picker-worthy remote-start target-error classification, including `binding_required`.
- Documented the resend selector invariant next to `RemoteResendPayload`.
- Kept pending IDs, provider-text keys, resend payloads, and in-flight IDs under explicit subset/lifecycle invariants.
- Added tolerant persistence decoding without a schema version bump.
- Preserved legacy displayed-text catch-up fallback.

## Testing

Thirty-eight exact XCTest IDs were added, with surgical contract-ledger updates (`+39/-1`: 38 new rows plus one corrected existing row).

Final coordinated validation:

- Five-suite same-tree sweep: **131/131 passed**
  - `SessionWatchManagerRevalidationTests`: 12
  - `SessionWatchManagerTerminalEdgeTests`: 11
  - `RemoteWorkspaceSidebarTests`: 30
  - `RemoteAgentSessionTests`: 49
  - `RemoteAgentClientFixesTests`: 29
- Authoritative test-list check: **PASS**
- `make dev-lint`: **PASS**, 0/1,576 format issues
- `make dev-swift-build PRODUCT=RepoPrompt`: **PASS**
- `make dev-swift-build PRODUCT=repoprompt-mcp`: **PASS**
- Contract ledger: baseline-identical `missing=195 stale=0`, zero new drift

No visible app lifecycle action or live two-machine test was performed.

## Performance Impact

- Gateway work remains bounded to parked-session revalidation. Fingerprint comparison is constant-size state per device/session.
- A changed terminal can cause one additional `session_terminal`, client log catch-up, and push wake; unchanged terminal snapshots remain suppressed.
- Client resend state adds small per-pending-item dictionaries and is pruned after host catch-up or teardown.

## Next Steps

### Immediate TODOs

Run the user-owned two-Mac acceptance checklist:

1. A host turn completing in under 30 seconds appears on a picked-up client tab within approximately one revalidation interval.
2. A second fast terminal completion wakes a fully closed, push-only client.
3. An adopted-session transport failure shows **Undelivered + Resend** and resends exactly once.
4. Relaunch preserves an undelivered row and actionable Resend.
5. Relaunch while target selection is open preserves recovery and selected-window targeting.
6. A recovered `binding_required` resend reopens target selection.
7. Closing a tab with an open picker leaves no dead sheet.
8. Interview/workflow/slash-skill remote turns do not duplicate after catch-up.
9. Reconnection appends exactly one `Remote channel restored.` row.
10. Closing only the host workspace reports `workspace_not_open`, not a transport error.

### Technical Debt / Residual Risk

- A restart after a successful ordinary remote send or resend but before host catch-up can lose transient provider-text correlation and pending-ID state. This broader successful-send restart class predates F2 and should be addressed in a separate bounded change.
- Same-text optimistic dedup can still absorb the wrong identical user turn in pathological host ordering.
- If multiple host sessions are created for related starts, the conservative recovery rule steers the older undelivered text into the later adopted session.
- `updated_at`-only changes may cause one benign extra terminal emission and log catch-up.

## Session Metrics

- **Duration:** multi-round implementation and review spanning 2026-07-12 to 2026-07-13
- **Files Changed before this report:** 17 tracked files
- **Lines Modified before this report:** approximately +3,040 / -55
- **Tests Added:** 38 exact XCTest IDs
- **Components Affected:** gateway session watch/push wake; AgentMode persistence, view model, coordinator, picker, and message UI; root XCTest contract ledger
- **Review Process:** oracle plan/review plus seven third-party finding rounds

## Lessons Learned

- Terminal status is not a sufficient suppression key; parked state machines need a content or revision identity.
- Push-dedupe state is part of transition correctness and must be explicitly rearmed for every newly wake-worthy transition.
- Ambiguous transport failure requires correlation state, not immediate rollback or blind retry.
- Persistence tests must exercise the real save → structured transcript → prepare hydration → apply path; manually injecting canonical items can conceal serialization gaps.
- UI presentation state needs a clear owner and teardown contract when async operations can outlive tabs.
- Optimistic dedup must compare the exact provider payload, not a transformed presentation string.

> Generated from Codex/Claude collaborative implementation session on 2026-07-13
