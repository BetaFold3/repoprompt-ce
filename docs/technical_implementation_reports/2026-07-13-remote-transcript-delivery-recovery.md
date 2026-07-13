# Technical Implementation Report - 2026-07-13 - Remote Transcript Delivery Recovery

## Session Overview

This session investigated and fixed remote Agent Mode transcript delivery failures where the host accepted a start or steer and produced a reply, but the client timed out while subscribing or catching up and never projected the transcript.

The implementation addresses four related defects:

1. **Authenticated subscribe head-of-line blocking:** the gateway now queues the correlated subscribe acknowledgment before starting host validation and catch-up.
2. **Repeated full-set subscription work:** the client now reconciles only unacknowledged subscription deltas, while reconnect still replays the full desired set.
3. **Adopted-session observation failure:** a transient subscribe or catch-up failure no longer turns a successfully accepted start into an apparent send failure or causes a duplicate resend.
4. **Persisted sequence cursor without a generation:** remote server frames now carry an optional `seq_epoch`, allowing the client to distinguish a restarted gateway sequence domain from duplicate frames.

Oracle review identified additional lifecycle races in the first implementation. The final patch therefore also uses stable per-session validation tokens, sink-aware validation correlation, observation lifecycle generations, compensating unsubscribe, and retired-epoch rejection.

The visible app was not launched or stopped. No push was performed.

## Implementation Details

### 1. Subscribe Acknowledgment Before Deferred Validation

**Problem Statement:**

For ticket-authenticated WebSockets, frame handling is FIFO. The old subscribe path awaited host polling and possible catch-up emission before returning its `command_result`. An early session update could cause the client to enqueue `get_log` behind the still-running subscribe operation. Both client-side 30-second timers could then expire even though the host had accepted the work and produced the reply.

**Solution Approach:**

`RemoteGatewayRuntime.handleSubscribe` now registers observation intent synchronously and stores a `SubscriptionValidation` keyed by device, sink, request ID, and normalized session IDs. It immediately returns the subscribe `command_result`. Both authenticated and static-token WebSocket paths send that response first and then call `didQueueResponse`, which starts validation in a child task.

`RemoteFrameSink.send` is explicitly documented as returning after the frame has entered the sink's ordered outbound queue, making the ordering contract clear.

Representative production flow:

```swift
if let response = await runtime.handle(frame, deviceID: deviceID, sinkID: sinkID, sink: sink) {
    await sink.send(response)
    await runtime.didQueueResponse(
        for: frame,
        response: response,
        deviceID: deviceID,
        sinkID: sinkID
    )
}
```

Deferred validation is deliberately keyed by `sinkID` as well as request identity so concurrent subscriptions without request IDs cannot consume one another's validation work.

**Race hardening:**

- `SessionWatchManager.registerSubscription` records intent without polling or emitting.
- `validateSubscription` rechecks a stable per-session token after every suspension.
- Unsubscribe or expiry removes that token, so delayed validation cannot resurrect observation or emit a stale frame.
- Removing the initiating sink disables only targeted catch-up; device-level observation still starts for other sinks or push delivery.
- Concurrent registrations for the same device/session reuse the same token, preventing one sink from invalidating another.

### 2. Delta Subscription Reconciliation

**Problem Statement:**

`RemoteHostConnection` previously sent the entire accumulated `desiredSubscriptions` set for each incremental subscribe. This repeatedly revalidated older sessions and amplified gateway polling, terminal emissions, and catch-up traffic.

**Solution Approach:**

The connection now maintains separate desired and acknowledged sets:

```swift
private var desiredSubscriptions: Set<String> = []
private var acknowledgedSubscriptions: Set<String> = []
private var subscriptionReconciliationInFlight = false
```

`reconcileDesiredSubscriptions` serializes reconciliation and sends only:

```swift
let pending = desiredSubscriptions.subtracting(acknowledgedSubscriptions)
```

Successfully acknowledged sessions are retained; command-level binding failures are parked and pruned as before. Disconnect, transport close, revocation, and a newly created socket clear only the acknowledged set. The desired set survives, so reconnect correctly replays the full desired observation state.

### 3. Adopted-Session Observation Recovery Without Resend

**Problem Statement:**

A successful remote `start` returns a durable host session ID before the client subscribes and catches up. Previously, a transient observation timeout was thrown through the send path after adoption, making a delivered message appear failed and inviting a duplicate resend.

**Solution Approach:**

`RemoteAgentSessionController.start` now persists and emits the adopted binding before observation. It applies the returned snapshot, then calls `observeAndCatchUp`. Transient observation failures—timeout, transport closure, connection closure, or rate limiting—surface a degraded-observation message and trigger up to three recovery attempts without sending `start` again.

The user-facing distinction is explicit:

```swift
"Remote session was accepted, but observation is degraded. Retrying without resending your message."
```

Definitive failures such as `binding_required` still throw, while the already-adopted binding remains persisted for recovery.

Lifecycle safety is enforced with `observationLifecycleGeneration`:

- start establishes a new observation generation;
- unsubscribe and shutdown invalidate the generation and cancel recovery;
- every suspended subscribe/catch-up rechecks that the generation and session are still current;
- if a stale subscribe completed after cancellation, `compensateStaleObservationSubscription` sends an unsubscribe;
- successful recovery emits one `Remote observation restored.` system message.

### 4. Explicit Sequence Epoch

**Problem Statement:**

The client persisted `lastAppliedSeq`, but the gateway's per-device/session sequence counters lived only in memory. After a gateway restart, legitimate frames starting again at sequence 1 could be dropped by the persisted client as `seq_gated`.

**Solution Approach:**

`RemoteServerFrame` now carries an optional, Codable `seq_epoch`. `SessionWatchManager` generates one epoch for its lifetime and attaches it to every sequenced update, terminal, interaction-resolved, and expired frame. `AgentSessionRemoteHostBinding` persists the current epoch without a serialization-version bump because the new field is optional and legacy payloads decode as `nil`.

When the controller observes a new epoch, it:

1. retires the old epoch;
2. resets only `lastAppliedSeq`;
3. preserves `nextLogOffset`;
4. persists the new binding;
5. forces host catch-up before applying normal sequence gating.

A transition from a known epoch to an epoch-less legacy sender is treated as a domain change and also forces catch-up. Delayed frames from a retired epoch are rejected as `retired_seq_epoch`, preventing rollback to an old sequence domain.

This separates two authorities correctly: event sequencing may restart with the gateway, while transcript pagination remains owned by the host log and must not reset.

## Files Modified

### Production

- `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift` — added optional persisted `seqEpoch` to `AgentSessionRemoteHostBinding`.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` — added epoch transitions, forced catch-up, retired-epoch rejection, adopted-session observation recovery, lifecycle generations, and stale-subscribe compensation.
- `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift` — separated desired from acknowledged subscriptions, serialized reconciliation, sent deltas, and reset acknowledgments across connection lifecycles.
- `Sources/RepoPromptGateway/GatewayRuntime.swift` — split subscribe registration from validation and correlated deferred validations by device, sink, request, and session set.
- `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift` — started deferred validation only after the correlated response was queued on both WebSocket admission paths.
- `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift` — introduced registration/validation phases, stable subscription tokens, suspension guards, sink-aware catch-up, and sequence-epoch emission.
- `Sources/RepoPromptRemoteWire/JSONValue.swift` — included `seq_epoch` when materializing a server frame as JSON.
- `Sources/RepoPromptRemoteWire/RemoteWireFrames.swift` — added the optional wire-level `seqEpoch` field and `seq_epoch` coding key.

### Tests

- `Tests/RepoPromptTests/AgentMode/RemoteAgentSessionTests.swift` — covered binding compatibility, transient and definitive observation failures, no duplicate start, unsubscribe during recovery, epoch changes, legacy transitions, offset preservation, and retired epochs.
- `Tests/RepoPromptTests/Gateway/GatewayAuthE2EContractTests.swift` — proved an authenticated subscribe acknowledgment releases FIFO admission before blocked validation and allows `get_log` to complete.
- `Tests/RepoPromptTests/Gateway/GatewayRuntimeBindingTests.swift` — covered response-before-validation ordering and concurrent request-ID-less subscriptions on separate sinks.
- `Tests/RepoPromptTests/Gateway/RemoteWireProtocolTests.swift` — covered `seq_epoch` round-trip and legacy decoding.
- `Tests/RepoPromptTests/Gateway/SessionWatchManagerTerminalEdgeTests.swift` — covered epoch emission, concurrent same-session sinks, sink removal during deferred validation, and unsubscribe-before-validation.
- `Tests/RepoPromptTests/RemoteHosts/RemoteHostConnectionTests.swift` — covered delta sends, no-op repeat subscribe, and full desired-set replay after reconnect.

### Documentation

- `docs/investigations/remote-agent-transcript-delivery-regression-2026-07-13.md` — captured the incident evidence, code-path proof, competing hypotheses, root-cause confidence, and recommended remediation.
- `docs/technical_implementation_reports/2026-07-13-remote-transcript-delivery-recovery.md` — this implementation report.

## Bug Fixes

### Remote subscribe and catch-up timeouts after successful host execution

- **Symptoms:** `Remote subscribe timed out after 30 seconds`, followed by `Remote transcript catch-up failed: timeout(operation: "get_log", seconds: 30.0)`, while the host showed the prompt and response.
- **Root Cause:** authenticated WebSocket FIFO serialized the complete validation-heavy subscribe operation ahead of a later `get_log`.
- **Fix Applied:** queue the subscribe result first, then run validation asynchronously under sink- and request-correlated state.

### Existing-session replies dropped as stale sequences

- **Symptoms:** active-session `session_terminal` frames were logged as `seq_gated`; the host response existed but the client did not fetch/project it.
- **Root Cause:** a persisted sequence cursor was compared with a gateway sequence counter that restarted in memory without a generation identifier.
- **Fix Applied:** add `seq_epoch`, reset only the event cursor on domain change, force transcript catch-up, and reject delayed retired epochs.

### Accepted starts presented as failed delivery

- **Symptoms:** a start reached the host and returned a session ID, but a subsequent observation timeout surfaced as a remote send failure.
- **Root Cause:** start adoption and observation establishment shared one throwing success path.
- **Fix Applied:** preserve the adopted binding and recover observation asynchronously without resending the user message.

### Subscription traffic amplification

- **Symptoms:** each new subscription could revalidate every previously desired session.
- **Root Cause:** reconciliation repeatedly sent the full accumulated desired set rather than the unacknowledged delta.
- **Fix Applied:** track acknowledgments per connection and send only pending deltas; clear acknowledgments on reconnect for full replay.

## Technical Decisions

1. **A queued acknowledgment is the ordering boundary.** Validation begins only after `RemoteFrameSink.send` accepts the correlated response into its ordered outbound queue; it does not wait for peer receipt.
2. **Registration is authoritative observation intent.** Validation may outlive its initiating sink, but cannot outlive unsubscribe/expiry because the per-session token is authoritative.
3. **An adopted host session is not an undelivered send.** Observation recovery is a separate state and never reissues `start`.
4. **Sequence epoch is optional for compatibility.** Legacy gateways and persisted bindings continue to decode; mixed-version transitions force safe catch-up.
5. **Transcript offsets do not follow event epochs.** `nextLogOffset` remains stable across epoch changes to avoid replaying or duplicating already projected transcript turns.
6. **Reconnect owns full replay.** Incremental operation uses deltas; clearing acknowledgments at connection boundaries makes the existing desired set the reconnect source of truth.
7. **No wire protocol version bump.** The additive optional field preserves version-1 compatibility.

## Challenges Encountered

### Separating the incident trigger from amplifying behavior

- **Context:** the prior terminal-fingerprint change increased terminal events and catch-up attempts, but did not create the underlying FIFO or cursor-generation defects.
- **Resolution:** the investigation classified direct code proof separately from incident inference and fixed the architectural boundaries rather than reverting terminal re-emission.

### Moving validation after acknowledgment without creating lifecycle races

- **Context:** deferring work creates gaps where the sink can disappear, another sink can subscribe to the same session, or the user can unsubscribe while polling is suspended.
- **Resolution:** Oracle review drove stable per-session tokens, sink-specific catch-up lookup, post-suspension guards, and device-level observation continuity.

### Avoiding duplicate host work during client recovery

- **Context:** retrying the original send after session adoption could duplicate the user's message.
- **Resolution:** recovery retries only subscribe plus catch-up, holds the adopted binding, and verifies with a test that the `start` command count remains exactly one.

### Supporting rolling compatibility across sequence domains

- **Context:** epoch-aware and legacy senders can be encountered across persisted sessions and rolling upgrades.
- **Resolution:** optional decoding, explicit known-to-legacy transition handling, forced catch-up, and a retired-epoch set provide a conservative compatibility path.

## Code Quality Improvements

- Decomposed subscription handling into explicit registration, response ordering, and validation phases.
- Named the connection's desired-versus-acknowledged state instead of overloading one set.
- Added lifecycle-generation checks around every suspension point in observation recovery.
- Centralized epoch normalization and sequence-domain transitions.
- Extended test doubles with deterministic gates for concurrency and ordering tests.

## Testing

The post-Oracle validation matrix completed successfully:

- `make dev-format`
- `make dev-test FILTER=GatewayRuntimeBindingTests`
- `make dev-test FILTER=SessionWatchManagerTerminalEdgeTests`
- `make dev-test FILTER=RemoteAgentSessionTests`
- `make dev-test FILTER=GatewayAuthE2EContractTests`
- `make dev-test FILTER=RemoteHostConnectionTests`
- Remote wire protocol focused tests
- `make dev-lint`
- `make dev-swift-build PRODUCT=RepoPrompt`
- `make dev-swift-build PRODUCT=repoprompt-mcp`

Final focused result reported by the validation worker: **134 affected tests passed, 0 failed**. Remote wire tests reported **7 passed**. Strict lint and both product builds passed. Formatting introduced no manual follow-up fixes.

The most important new regression contracts are:

- authenticated `get_log` is not blocked behind deferred subscribe validation;
- subscribe `command_result` is the first queued frame;
- repeated incremental subscribe sends no duplicate validation;
- reconnect replays all desired subscriptions;
- transient observation recovery never duplicates `start`;
- unsubscribe cannot resurrect observation after a suspended recovery;
- epoch changes preserve transcript offset and reject delayed old-domain frames;
- legacy wire and persisted payloads still decode.

No live-app smoke was run because that would require a visible app launch/relaunch, which was outside this task.

## Performance Impact

No benchmark was recorded, but the change removes known avoidable work:

- incremental subscribe now polls only newly unacknowledged sessions instead of the entire desired set;
- authenticated command admission is released as soon as the subscribe response is queued;
- duplicate same-session incremental subscribe becomes a no-op after acknowledgment.

The added work is bounded:

- sequence-domain changes trigger one defensive catch-up;
- observation recovery makes at most three attempts with 250 ms and 500 ms backoff before surfacing failure.

## Next Steps

### Immediate TODOs

- Run the live remote Agent Mode smoke flow on a debug client/host pair when explicit app lifecycle approval is available.
- Add request-correlated gateway enqueue/start/finish telemetry if maintainers need definitive incident replay rather than code-path proof.
- Observe mixed-version clients during rollout to confirm the expected known-epoch/legacy transition path.

### Technical Debt Introduced

No intentional shortcut was introduced. The main remaining observability gap is request-correlated gateway queue telemetry; it existed before this change and is documented in the investigation.

## Session Metrics

- **Duration:** Multi-hour investigation, implementation, Oracle review, and validation; exact wall-clock duration is not recoverable from the handoff.
- **Files Changed Before This Report:** 15 files (`+1,468/-53`), comprising 8 production files, 6 test files, and 1 investigation report.
- **Report File:** 1 additional documentation file.
- **Components Affected:** Agent Mode remote session controller, persisted session binding, remote host WebSocket client, gateway WebSocket admission, gateway runtime, session watch manager, remote wire protocol, and focused test infrastructure.
- **Validation:** 134 affected tests plus 7 remote wire tests, strict lint, formatter, and both Swift product builds.

## Lessons Learned

- A correlated command acknowledgment must not be coupled to slow validation when the transport serializes frames.
- Persisted cursors require an explicit generation whenever their producer is in-memory.
- Delivery success and observation health are separate state machines after a host session ID has been adopted.
- Deferring work safely requires authority tokens and post-suspension checks, not only task cancellation.
- Desired state and acknowledged transport state should be modeled separately so incremental reconciliation and reconnect replay can both be correct.

> Generated from the implementation session on 2026-07-13 (Asia/Ho_Chi_Minh).
