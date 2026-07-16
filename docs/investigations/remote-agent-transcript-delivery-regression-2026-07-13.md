# Investigation: Remote Agent transcript delivery regression after current HEAD

## Summary
The investigation found two pre-existing architectural defects that strongly match the failures: ticket-authenticated WebSocket frames serialize the entire subscribe operation ahead of event-triggered `get_log`, and the client persists a sequence cursor that is compared with an in-memory gateway sequence lacking an epoch. HEAD `dcdcaed` did not introduce either defect; its terminal-fingerprint re-emission can amplify terminal/sequence/catch-up work, but incident-specific amplification and exact request ordering remain unproven without correlated gateway telemetry.

## Symptoms
- A newly started remote session reaches the host and receives the host reply, yet the client reports `Remote subscribe timed out after 30 seconds` followed by a `get_log` catch-up timeout.
- Opening an existing session immediately shows transport degradation/reconnect failures; a new message reaches the host and is answered, but the reply never appears on the client.
- The app log shows duplicate callbacks for the same frame: multiple `session_mismatch` drops followed by one handled callback.
- Some `session_terminal` frames for the active session are dropped as `seq_gated`.
- `get_log` requests sometimes complete slowly (roughly 6–26 seconds) and sometimes exceed the 30-second client timeout.
- Repeated terminal frames trigger repeated empty catch-up fetches at the already-complete offset.

## Background / Prior Research
### Git archaeology: current HEAD regression boundary
- Current HEAD is `dcdcaed9463452d6b0844204ff3f495e4f8a4501` (`Fix live-smoke deferred follow-ups`), parent `be5d267a80476918fdf0edd1866c421c8f066a86`. The commit changes 19 files (+3322/-55), predominantly tests.
- The only direct gateway/watch runtime change is terminal fingerprint re-emission in `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift:43-51,81,831-855,887-933,1017`. A terminal snapshot whose transcript count or raw `updated_at` changes now emits another `session_terminal`, allocates a new sequence, and resets push dedupe. Previously terminal-to-terminal polls were suppressed except for targeted catch-up.
- HEAD also adds persistent undelivered/resend behavior in `AgentModeViewModel.swift:12514-12728`, including a path at 12585-12605 that treats a nil or matching local start attribution as proof an adopted session already received the start, then attaches/catches up instead of sending a new command.
- Transcript optimistic-row matching changed in `RemoteAgentModeCoordinator.swift:403-437,954-979` to prefer provider-facing wrapped text over visible bubble text.
- HEAD does **not** directly modify `RemoteAgentSessionController.swift`, `RepoPromptGateway/Relay/*`, or remote wire/transport code. Start adoption/subscribe/initial catch-up, attach/catch-up, strict sequence gating, and update/terminal-triggered log fetches predate HEAD (primarily commits `5f32849`, `88eb811`, and `e1b6a46`).
- Ranked history leads: (1) terminal fingerprint re-emission creates repeated terminal/sequence/catch-up churn; (2) new resend attribution can silently reconcile to an unrelated binding; (3) provider-text-only correlation can retain optimistic/undelivered state. The observed subscribe/get_log timeouts would be an indirect interaction unless a pre-existing transport defect is merely exposed by the new churn.


## Initial Assessment / Hypotheses
1. **Transport admission/head-of-line blocking:** a long-lived remote subscribe/poll operation may occupy the same serialized request path as `send` or `get_log`, causing otherwise-successful host work to time out at the client.
2. **Duplicate/stale subscription lifecycle:** multiple live observer tasks or controllers appear to process each frame. Stale instances reject the active frame as `session_mismatch`, while only one instance handles it; lifecycle churn could also cancel or starve the authoritative catch-up path.
3. **Incorrect cursor/sequence initialization:** attach/start/resubscribe may adopt or retain the wrong sequence cursor, causing legitimate first or terminal frames to be rejected as `seq_gated`.
4. **Transcript pagination/settling mismatch:** the client may advance `next_log_offset` or declare a terminal page settled before the host's completed turn is visible, leaving subsequent fetches empty and preventing later recovery.
5. **Relay/watch-side connection churn:** transport closure and reconnect failures may originate in the gateway relay/watch path rather than the client projection logic; this must be separated from client-side secondary symptoms.

## Investigator Findings
### Paired investigation — authenticated FIFO, cursor epochs, and HEAD amplification

**Scope and method.** Read-only analysis of current HEAD `dcdcaed9463452d6b0844204ff3f495e4f8a4501`, the supplied Oracle export, the incident timestamps, three independent explore probes, direct source/test reads, and a final Oracle review. No source code was changed.

**Diagnosis basis:** Oracle synthesis plus directly verified current-HEAD code. Recommendations below are investigator-added and are not implemented.

#### Executive verdict

The main hypothesis is **proven as a reachable and sufficient code path**, but **not proven as the unique path taken by this incident**:

> Synchronous subscribe validation can emit an update/terminal before the correlated subscribe response. The client can then send `get_log` on the same socket. The ticket-authenticated gateway serializes verification and the entire prior runtime operation, so `get_log` waits behind subscribe while both independent 30-second client timers continue. Client timeout removes only local correlation and does not cancel queued/executing gateway work.

The supplied times match that path to approximately one second. Definitive incident attribution still needs request-ID and gateway enqueue/start/finish correlation.

A second defect is also code-proven: the client persists `lastAppliedSeq`, while the gateway sequence epoch is only in memory and may restart at 1. This fully explains the observed `seq_gated` terminal frames and can suppress later event-driven catch-up. It does not by itself defeat every explicit poll/`get_log`; combined with the observed subscribe/catch-up failure (or with an explicit catch-up that runs before the host reply is complete), it is sufficient to explain existing-session reply loss.

HEAD did **not** introduce the FIFO, client timer, or cursor-epoch defects. HEAD's terminal-fingerprint re-emission is a plausible amplifier because it can create additional terminal frames, sequences, and completed-offset `get_log` calls. The accumulated `desiredSubscriptions` behavior is another proven amplifier, but it predates HEAD. Actual incident fingerprint churn and actual subscription-set width remain unproven.

#### Evidence classification

| Finding | Classification |
|---|---|
| Authenticated frames are full-operation FIFO on one WebSocket | **Direct code proof** |
| Subscribe validation may emit before its correlated response | **Direct code proof**, with the completed-terminal quarantine nuance below |
| The early frame can schedule an overlapping `get_log` with its own timer | **Direct code proof** |
| Client timeout does not cancel gateway work | **Direct code proof** |
| The 16:49:10 `get_log` was behind the specific timed-out subscribe | **Strong incident inference**, not request-correlated proof |
| Persisted cursor can exceed a restarted in-memory gateway sequence | **Direct code proof of the failure mode** |
| A gateway/device epoch reset occurred in this incident | **Unproven incident inference** |
| HEAD terminal re-emission amplified this incident | **Plausible incident inference** |
| Multiple mismatch callbacks prove duplicate listeners | **Disproved by the log shape/code topology** |

#### Timestamp correlation

| Supplied time | Code correlation | Assessment |
|---|---|---|
| **16:48:29** start sent | `RemoteAgentSessionController.start` sends `start` and awaits its independent command continuation (`RemoteAgentSessionController.swift:125-156`; `RemoteHostConnection.swift:610-667`). | The ~19-second start latency is real but its cause is not established. |
| **16:48:48** start adopted | The controller adopts the returned ID, resets cursors only if the ID changed, persists the binding, then immediately awaits subscribe before applying the start snapshot or doing explicit catch-up (`RemoteAgentSessionController.swift:156-183`). | This is the start of the observed subscribe interval. |
| **~16:49:10** update and `get_log` | An accepted update/terminal calls `scheduleLogCatchUp`, which sends `get_log` at the current offset (`RemoteAgentSessionController.swift:303-334,419-428,503-524,636-650`). | Code proves this can happen during subscribe validation; the log does not prove which producer emitted this frame. |
| **16:49:19** subscribe timeout | Default command timeout is 30 seconds (`RemoteHostConnection.swift:62-65`). | ~31 seconds after adoption is an exact/near-exact timer match. |
| **16:49:40** catch-up timeout | The overlapping `get_log` has its own 30-second timeout installed when locally registered (`RemoteHostConnection.swift:630-667`). | Exactly ~30 seconds after the logged fetch start. Queue wait versus later app-tool execution cannot be separated without gateway telemetry. |

#### New-session flow, end to end

1. **UI/coordinator dispatch.** `RemoteAgentModeCoordinator.startRemoteSession` creates/reuses the tab controller, marks the tab running, and awaits controller start (`RemoteAgentModeCoordinator.swift:107-143,257-270`).
2. **Client start ordering.** After `start` returns, the controller adopts the session ID. Only a changed ID resets `lastAppliedSeq` and `nextLogOffset`. It emits the binding, awaits subscribe, then—and only after subscribe succeeds—applies the start snapshot and performs poll/log catch-up (`RemoteAgentSessionController.swift:149-183`).
3. **Transport concurrency.** `RemoteHostConnection` stores pending continuations by request ID. Each command installs an independent timeout task and sends in a child `Task`; actor suspension permits other commands to enter (`RemoteHostConnection.swift:610-667`). There is no client-side command FIFO.
4. **Gateway/app translation.** `start` maps to app `agent_run op=start`; `get_log` maps to `agent_manage op=get_log` (`RemoteCommandTranslator.swift:115-130,192-200`). Runtime executes the translated tool through the app link (`GatewayRuntime.swift:286-375,654-675`).
5. **Authenticated FIFO boundary.** Ticket-authenticated/enforced frames use `handleEnforcedFrame`; the developer static-token path is separate (`GatewayHTTPServer.swift:620-649`). Verification, scope enforcement, all of `await runtime.handle(...)`, and response send are inside one queued operation (`GatewayHTTPServer.swift:810-893`):

   ```swift
   let previous = frameProcessingTask
   frameProcessingTask = Task {
       await previous?.value
       await operation()
   }
   ```

   (`GatewayHTTPServer.swift:896-903`). Therefore later authenticated frames cannot begin runtime handling until the prior operation completes.
6. **Subscribe response is validation-gated.** `handleSubscribe` awaits `watchManager.subscribe` before constructing `command_result` (`GatewayRuntime.swift:135-165`). The manager registers the sink, then validates requested session IDs sequentially (`SessionWatchManager.swift:174-193`). Each validation polls and may emit its snapshot before returning (`SessionWatchManager.swift:285-322`).
7. **Pre-response emission is real, with one nuance.** Nonterminal snapshots synchronously broadcast `session_update`; expired, failed/cancelled terminal, changed terminal, and targeted/repeated terminal paths can also send before subscribe returns (`SessionWatchManager.swift:760-889`). A first `completed` terminal normally starts the five-second asynchronous quarantine and returns from that validation without immediately emitting (`SessionWatchManager.swift:85-104,819-829,958-1007`). It can still be emitted before the overall subscribe response if later validation remains in progress.
8. **Why subscribe can exceed 30 seconds.** Each watch validation's `agent_run poll` has a 15-second app-link timeout (`SessionWatchManager.swift:633-661`). Session-window discovery may additionally make serial 10-second `agent_manage list_sessions` calls (`GatewayRuntime.swift:824-892`). On the client, `subscribe([newID])` unions the ID into `desiredSubscriptions`, but reconciliation sends the entire accumulated sorted set (`RemoteHostConnection.swift:198-215,520-594`). The actual incident subscription IDs and discovery calls were not captured.
9. **Failure closure.** An early frame is yielded by the connection read loop before the subscribe `command_result` (`RemoteHostConnection.swift:720-770`). The matching controller starts `get_log`; its authenticated frame queues behind subscribe. Timeout removes the local pending continuation only:

   ```swift
   guard let pending = pendingCommands.removeValue(forKey: requestID) else { return }
   ```

   (`RemoteHostConnection.swift:671-688`). No cancellation frame is sent, so gateway work continues and a late result is ignored locally.

This is a complete, code-sufficient explanation for “host starts and replies, subscribe times out, catch-up times out, client never projects the reply.” Request-correlated gateway logs are still required to label it the incident's proven execution trace rather than the strongest supported reconstruction.

#### Existing persisted-session flow and sequence epoch

1. **Persistence/hydration.** `AgentSessionRemoteHostBinding` is Codable and contains `remoteSessionID`, `lastAppliedSeq`, and `nextLogOffset` (`AgentSession.swift:129-153,390-455`). Hydration restores the binding and calls `attachPersistedSessionIfNeeded` (`AgentModeViewModel.swift:4450-4478`).
2. **No epoch adoption.** Controller initialization copies both persisted cursors verbatim (`RemoteAgentSessionController.swift:94-107`). Attach awaits subscribe before its explicit poll/`get_log` catch-up (`RemoteAgentSessionController.swift:234-249,398-416`).
3. **Gateway epoch is volatile.** `SessionWatchManager` owns `seqByDeviceSession` only in memory and an absent key starts at 1 (`SessionWatchManager.swift:60-82,269-283`). Device teardown deletes sequence entries (`SessionWatchManager.swift:209-223`); a new manager/process also starts empty.
4. **Wire has no epoch.** `RemoteServerFrame` carries `v`, type, request/session IDs, optional `seq`, and payload—no gateway instance/epoch (`RemoteWireFrames.swift:88-112`).
5. **Backward sequences are unrecoverable.** The inbound gate drops `seq <= lastAppliedSeq` and returns. Only a forward gap (`seq > lastAppliedSeq + 1`) triggers catch-up (`RemoteAgentSessionController.swift:303-323`):

   ```swift
   if seq <= lastAppliedSeq {
       logInboundFrameDrop(frame, reason: "seq_gated")
       return
   }
   ```

   A persisted cursor 42 against a restarted gateway sequence 1 therefore drops frames 1…42, including the frame that would otherwise schedule `get_log`.
6. **Causal boundary.** This mismatch directly explains the incident's `seq_gated` terminals. By itself it does not always lose a reply because a successful attach/steer performs explicit catch-up. It becomes sufficient for whole-loss when:
   - attach/steer catch-up also times out (as reported), or
   - an immediate post-steer catch-up runs before the host's final reply, and the later terminal that should trigger another catch-up is sequence-gated.

The missing incident facts are gateway/watch-manager epoch or uptime, persisted `lastAppliedSeq`, and the first post-reconnect gateway `seq`.

#### HEAD `dcdcaed`: amplifier, not origin

- `git show dcdcaed9463452d6b0844204ff3f495e4f8a4501` confirms that the commit changes terminal fingerprinting, resend/persistence/UI behavior, and optimistic correlation, but does **not** modify `GatewayHTTPServer.swift`, `GatewayRuntime.swift`, `RemoteHostConnection.swift`, `RemoteAgentSessionController.swift`, remote wire frames, or relay transport. The FIFO, timers, catch-up scheduling, and sequence gate predate HEAD.
- HEAD fingerprints terminal payloads by `transcript_item_count` plus raw `updated_at`; a changed known component allocates a new sequence, broadcasts a fresh terminal, and resets push dedupe (`SessionWatchManager.swift:830-855,887-934`).
- Every accepted fresh terminal marks the controller catch-up dirty. Frames coalesce while work is active, but a continuing stream can keep producing iterations (`RemoteAgentSessionController.swift:636-650`). At a completed cursor, each iteration still sends an ordinary `get_log`, receives zero turns, and returns without advancing (`RemoteAgentSessionController.swift:419-432`). The one-time terminal-settle guard does not suppress those later ordinary empty calls (`RemoteAgentSessionController.swift:481-503`).
- **Production `updated_at` stability is conditional.** Snapshot wire serialization uses the snapshot's stored date (`AgentRunMCPSnapshot.swift:400-405`). The live view-model snapshot constructs `updatedAt: Date()` on every call, including a terminal-shaped live snapshot (`AgentModeViewModel.swift:5314-5456`). However, normal polling prefers an already stored terminal over a live terminal (`AgentRunMCPToolService.swift:2487-2533`), and indexed fallback uses stable `entry.savedAt` (`AgentRunMCPToolService.swift:2536-2560`). Stored terminal replacement is explicit (`AgentRunSessionStore.swift:519-533`). Thus a production fallback can churn raw `updated_at`, but endless churn for this incident is **not proven** without captured payloads.
- The HEAD resend path executes only for an explicitly flagged undelivered item and either reattaches or dispatches start/steer (`AgentModeViewModel.swift:12575-12643`). Provider-text matching affects optimistic-row correlation only (`RemoteAgentModeCoordinator.swift:953-981`). Neither change independently causes subscribe/`get_log` transport timeouts.

#### Ranked conclusions

1. **Confirmed architecture defect; strongest incident explanation — authenticated full-operation FIFO plus synchronous subscribe validation.** It is sufficient to cause the two timeouts and invisible reply. Timestamp fit is strong; exact request ordering remains unproven.
2. **Confirmed independent architecture defect; strong explanation for existing-session `seq_gated` loss — persisted cursor versus volatile gateway sequence epoch.** Whole visible loss additionally needs failed/early authoritative catch-up, which the incident supplies.
3. **Confirmed workload amplifier — accumulated full-set subscriptions.** It can multiply serial validation/discovery work; the incident's actual set width is missing.
4. **Plausible HEAD amplifier — terminal fingerprint re-emission.** It can add sequences and catch-ups. Actual raw payload churn in the incident is missing.
5. **Secondary behavior — pagination/settlement.** It explains repeated empty completed-offset fetches and extra work, not the original subscribe timeout.
6. **Possible latency contributor only — app MCP admission.** `agent_run` and `agent_manage` share the control lane, but its per-connection limit is 8, not 1 (`MCPToolAdmissionPolicy.swift:29-35,63-72`; `MCPConnectionManager.swift:10860-10930`). There is no incident queue-depth evidence.

#### Eliminated or bounded hypotheses

- **Duplicate listener leak as the explanation for repeated callbacks: eliminated by counter-evidence.** The connection manager caches one connection per host (`RemoteHostConnectionManager.swift:37-55`). The coordinator installs one inbound/state fanout pair per host and deliberately delivers every host frame to every controller on that host (`RemoteAgentModeCoordinator.swift:282-323`). Nonmatching controllers log `session_mismatch` (`RemoteAgentSessionController.swift:303-311`). N−1 mismatches plus one handled callback is therefore the expected topology. `stop` removes controller/event state and the last host fanout (`RemoteAgentModeCoordinator.swift:194-230,297-302`), and `testStoppingLastRemoteTabsReleasesControllersAndFanoutTasks` covers the two-tab lifecycle (`RemoteAgentSessionTests.swift:1621-1686`). A missed exceptional stop path cannot be absolutely excluded without object identities, but the supplied log shape is not leak evidence.
- **Pagination/terminal-settle offset bug as the timeout root cause: eliminated.** Explicit start/attach paging occurs only after subscribe success; an inbound-triggered page is later gateway work, not the operation delaying subscribe. Offset logic may still explain repeated empty calls or stale final-page replacement, but not the 30-second subscribe timer.
- **HEAD resend/provider-text changes as primary cause: eliminated absent an explicit resend.** They can affect recovery routing or optimistic-row cleanup, not authenticated WebSocket command admission.
- **Relay involvement in this path: eliminated by repository topology.** The client mints a ticket and opens a WebSocket directly from the paired record's `gatewayURL` (`RemoteHostConnection.swift:370-385,457-473`). `RemoteRelayClient` is explicitly a contract-only future WAN interface with no runtime conformer or networking stack (`RemoteRelayClient.swift:7-12`).
- **App MCP as a single serialized lane: disproved.** The relevant control lane limit is 8. Saturation remains possible only as an unmeasured contributor.
- **Raw `updated_at` terminal churn: bounded, not eliminated.** A volatile live fallback exists, while the normal stored-terminal path is stable. Incident payload evidence is required.

#### Test evidence and missing coverage

Existing tests prove components but not the cross-layer failure:

- `testStartWithNewRemoteSessionResetsCountersAndAcceptsSeqOne`, update coalescing, and terminal fetch behavior: `RemoteAgentSessionTests.swift:267-399`.
- Accumulated/fallback subscription behavior: `RemoteHostConnectionTests.swift:170-199,261-299`.
- Targeted terminal delivery during subscribe: `testSubscribeCatchUpTargetsOnlyNewSinkAfterSuppressedTerminalEdge`, `SessionWatchManagerTerminalEdgeTests.swift:139-157`.
- Changed count/timestamp, unchanged/missing fingerprints, and sequence behavior: `SessionWatchManagerRevalidationTests.swift:75-264`. Its helper uses explicitly fixed timestamps (`SessionWatchManagerRevalidationTests.swift:433-452`), not production snapshot generation.
- Transient subscribe-poll/app-link behavior: `GatewayWaitLoopContractTests.swift:170-305`.
- Fanout cleanup: `RemoteAgentSessionTests.swift:1621-1686`.

Missing tests:

1. Real ticket-authenticated same-WebSocket integration: blocked subscribe validation emits an early frame; client sends `get_log`; assert it cannot start before subscribe completes; assert both client timeouts and late-result discard.
2. Hydrated controller with persisted `lastAppliedSeq = 42` against a fresh `SessionWatchManager` emitting `seq = 1`.
3. Repeated production terminal snapshots through `AgentRunMCPToolService` into `SessionWatchManager`, proving whether raw `updated_at` is stable in each live/stored/indexed path.
4. Multi-session accumulated subscription timing across session-window discovery plus watch poll.
5. Restart recovery where persisted `nextLogOffset` equals host total but the locally persisted final transcript is absent/truncated.

#### Remaining evidence gaps

1. A cross-layer trace keyed by WebSocket/sink ID, frame type, request ID, enqueue/start/finish time, app-link invocation ID, tool name, and client timeout. This is the only way to promote the timestamp reconstruction to incident proof.
2. The exact `session_ids` array in the timed-out subscribe and whether window-affinity discovery ran.
3. Gateway/watch-manager process epoch or uptime, the client's persisted `lastAppliedSeq`, and first post-reconnect `seq`.
4. Actual terminal payloads across revalidation: `status`, `transcript_item_count`, raw `updated_at`, emitted sequence, trigger, and fingerprint-change reason.
5. App control-lane active permit/queue depth during the 6–26-second and >30-second calls.
6. Controller/tab/object identities and lifecycle counts during hydration, tab switches, close, workspace switch, and resend reattach.

#### Fix locations and options (recommendations only)

1. **Preferred transport fix: respond to subscribe before validation/catch-up emission.**
   - Locations: `GatewayRuntime.handleSubscribe` (`GatewayRuntime.swift:135-165`), `SessionWatchManager.subscribe` (`SessionWatchManager.swift:174-193`), and the post-response send point in `GatewayHTTPServer.handleEnforcedFrame` (`GatewayHTTPServer.swift:887-892`).
   - Option: split “register sink/subscription IDs” from “validate/catch up.” Return/send `command_result` after registration, then start validation from an explicit post-send hook. A bare `Task.yield` is not a response-order guarantee.
   - Why: it removes the pre-response event cycle and releases the socket FIFO before event-driven `get_log`.
   - Risk: observation must not miss changes between registration and validation; preserve a durable/dirty catch-up marker and test unsubscribe/reconnect races.
2. **Narrow the FIFO without weakening authentication.**
   - Locations: `GatewayHTTPServer.handleEnforcedFrame/enqueueFrameProcessing` (`GatewayHTTPServer.swift:810-903`).
   - Option: keep ticket/counter verification strictly ordered, then dispatch independent runtime operations outside the authentication chain, relying on request IDs and the mutating command ledger.
   - Risk: counter verification, subscribe/unsubscribe ordering, and mutating-command ordering are security/correctness boundaries. A subscribe-specific post-response split is lower risk than making all runtime operations concurrent.
3. **Reduce subscribe amplification.**
   - Locations: `RemoteHostConnection.subscribe/reconcileDesiredSubscriptions` (`RemoteHostConnection.swift:198-215,520-594`).
   - Option: normal subscribe sends only the newly requested delta; full-set replay remains reconnect-only. Serialize or coalesce overlapping reconciliation so reentrant callers do not send redundant full sets.
   - Risk: binding-required fallback and interleaved unsubscribe tests must remain valid.
4. **Do not abandon an adopted session on observation timeout.**
   - Locations: `RemoteAgentSessionController.start` and `attachAndCatchUp` (`RemoteAgentSessionController.swift:149-183,234-249`).
   - Option: after a start response establishes host truth, treat subscribe timeout as degraded observation, retain the binding, apply safe response state, and schedule bounded resubscribe/poll/`get_log` recovery rather than failing the whole start.
   - Risk: avoid duplicate optimistic rows and duplicate recovery tasks; do not hide genuine binding/revocation errors.
5. **Add a real sequence epoch.**
   - Locations: `RemoteServerFrame`/hello payload (`RemoteWireFrames.swift:88-112`), `SessionWatchManager`, `AgentSessionRemoteHostBinding`, and `RemoteAgentSessionController.handleInboundFrame`.
   - Preferred option: gateway instance/sequence epoch on `hello_ack` or sequenced frames; persist it with the binding; on epoch change reset `lastAppliedSeq` and force authoritative catch-up.
   - Alternative: durably persist gateway sequence state. Containment-only: reset on connection generation and force catch-up, but without a wire epoch delayed old frames cannot be distinguished safely.
   - Risk: wire backward compatibility and persistence migration require explicit tests.
6. **Harden terminal fingerprint semantics after instrumentation.**
   - Locations: snapshot `updated_at` production (`AgentModeViewModel.swift:5314-5456`; `AgentRunMCPToolService.swift:2487-2560`) and `SessionWatchManager.terminalFingerprint` (`SessionWatchManager.swift:887-934`).
   - Options: make terminal `updated_at` a stable content revision; fingerprint a durable terminal revision; or exclude raw time when `transcript_item_count`/revision is authoritative.
   - Risk: do not recreate the original missed-terminal-content bug that HEAD intended to fix.
7. **Add observability and the five missing integration tests before/with the fix.**
   - Locations: client pending-command lifecycle, gateway frame queue, runtime translated call, app-link invocation, watch emission, and controller identity logs.
   - Required fields are the ones listed under **Remaining evidence gaps**; redact payload text.


## Investigation Log

### Phase 1 - User-supplied runtime evidence
**Hypothesis:** The failure is client delivery/catch-up rather than host execution.
**Findings:** In both new and existing sessions, the host receives the user prompt and produces a response. The client either times out subscribing/catching up or never displays the completed turn. The app log contains active-session frame handling as well as duplicate stale-session drops.
**Evidence:** User-supplied session transcripts and unified log excerpt dated 2026-07-13, category `RemoteControlClient`.
**Conclusion:** Confirmed. Host execution is not the primary failing boundary; remote event delivery, catch-up, or client projection is.

### Phase 1 - Timing and callback topology
**Hypothesis:** The visible timeout is accompanied by request serialization and/or duplicate listener lifecycles.
**Findings:** A start request at 16:48:29 is adopted at 16:48:48; the active update at 16:49:10 starts `get_log`; subscribe fails at 16:49:19; catch-up fails at 16:49:40. Frames for one session are logged multiple times as mismatches and once as handled.
**Evidence:** User-supplied log timestamps for session `70E683D1-3B2E-48C0-9D6B-E92EB9DCF282`.
**Conclusion:** Strong lead, not yet proven in code.

### Phase 2 - Broad context and initial Oracle analysis
**Hypothesis:** Synchronous subscribe validation can emit an inbound frame that starts `get_log`, while the authenticated gateway queues `get_log` behind the still-running subscribe.
**Findings:** Context Builder selected the client transport/controller, UI lifecycle, gateway WebSocket/runtime/watch, app-link/admission, wire protocol, snapshot production, and relevant tests. It identified a complete code-reachable head-of-line path and a separate sequence-epoch mismatch.
**Evidence:** `GatewayHTTPServer.swift:810-903`, `GatewayRuntime.swift:135-165`, `SessionWatchManager.swift:174-193,285-322`, `RemoteHostConnection.swift:610-688`, and `RemoteAgentSessionController.swift:149-183,303-323`.
**Conclusion:** Confirmed as architectural failure modes; incident attribution still required pair verification and timestamp correlation.

### Phase 3 - Pair investigation and counter-hypothesis testing
**Hypothesis:** The FIFO path explains the new-session timeouts; persisted-versus-volatile sequence state explains existing-session `seq_gated` loss; HEAD is an amplifier rather than the origin.
**Findings:** The pair traced both flows, corrected the completed-terminal quarantine nuance, verified accumulated full-set subscriptions and the missing sequence epoch, and bounded fanout, pagination, resend correlation, relay, and MCP admission alternatives.
**Evidence:** Detailed `## Investigator Findings` above, including current-HEAD source/test references and git boundary `dcdcaed^..dcdcaed`.
**Conclusion:** Two pre-existing architectural defects confirmed. Exact execution of the inferred ordering and actual HEAD fingerprint churn remain unproven incident facts.

### Phase 4 - Refocused Oracle synthesis
**Hypothesis:** The report's claims and fix order remain valid under adversarial cross-file review.
**Findings:** Oracle confirmed the architectural/protocol root causes, identified the conditions required for persistent loss, and ranked a subscribe response/validation split ahead of broad FIFO concurrency or fingerprint changes.
**Evidence:** Refreshed 131k-token selection including production snapshot generation, session store behavior, connection/controller tests, relay contract, and the pair report.
**Conclusion:** Investigation is complete at code-proof level. A request-correlated trace is required only to promote the strongest reconstruction to a definitive incident execution trace.

## Root Cause

### 1. Architectural root cause of the new-session timeout path
Ticket-authenticated frames serialize signature verification **and the entire** `await runtime.handle(...)` operation through `frameProcessingTask` (`Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:810-903`). A subscribe response is not constructed until `SessionWatchManager.subscribe` finishes (`Sources/RepoPromptGateway/GatewayRuntime.swift:135-165`), and that method validates every requested session sequentially (`Sources/RepoPromptGateway/Watch/SessionWatchManager.swift:174-193`).

Validation polls the host and can emit a running update or qualifying/targeted/repeated terminal before returning (`SessionWatchManager.swift:285-322,760-889`). The first completed terminal normally enters asynchronous quarantine, but it may still be emitted before the overall subscribe result if later validation remains active. The client read loop can accept the early frame and schedule `get_log`, but the authenticated gateway queues that request behind subscribe.

Each client command starts its own 30-second timer when locally registered (`Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:610-667`). Timeout removes only the local pending continuation and sends no cancellation to the gateway (`RemoteHostConnection.swift:671-688`). Meanwhile, start/attach waits for subscribe before applying the start snapshot and performing explicit authoritative catch-up (`Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift:149-183,234-249`). This is a code-proven, sufficient mechanism for the observed subscribe and `get_log` timeouts and the lack of transcript projection during that interval.

The timestamps are a strong match: adoption around 16:48:48 to subscribe failure at 16:49:19 is one timeout, and the 16:49:10 `get_log` to failure at 16:49:40 is another. Receiving the update proves the socket/read loop was alive. Without request IDs and gateway enqueue/start/finish timestamps, it remains a strong incident reconstruction rather than a uniquely proven execution trace. Persistent loss additionally requires no later successful catch-up; the code-proven FIFO path alone guarantees the observed delayed/failed recovery interval, not permanent loss in every run.

### 2. Protocol root cause of existing-session sequence loss
The client persists `lastAppliedSeq` in its remote binding and restores it on hydration (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift:129-153,390-455`; `AgentModeViewModel.swift:4450-4478`). The gateway's `seqByDeviceSession` is in-memory, starts absent domains at sequence 1, and is cleared during device teardown (`Sources/RepoPromptGateway/Watch/SessionWatchManager.swift:60-82,209-223,269-283`). `RemoteServerFrame` carries no gateway or sequence epoch (`Sources/RepoPromptRemoteWire/RemoteWireFrames.swift:88-112`).

The controller copies the persisted cursor verbatim and drops every `seq <= lastAppliedSeq` without catch-up; only a forward gap triggers recovery (`RemoteAgentSessionController.swift:94-107,303-323`). A restarted gateway can therefore emit legitimate sequence 1 against a persisted client cursor such as 42, making new frames indistinguishable from duplicates. This directly explains the observed `seq_gated` class. Whole-reply loss additionally needs failed/early explicit catch-up or another recovery failure, which is consistent with the reported subscribe/`get_log` failures but is not caused by sequence gating alone. Confirming an actual epoch reset in this incident requires the gateway uptime/epoch, persisted cursor, and first post-reconnect sequence.

### 3. Why the current HEAD exposed the defects
HEAD `dcdcaed` did not modify `GatewayHTTPServer.swift`, `GatewayRuntime.swift`, `RemoteHostConnection.swift`, `RemoteAgentSessionController.swift`, the wire sequence contract, or relay transport. The FIFO, client timers, subscribe ordering, and epochless cursor all predate it.

HEAD changed `SessionWatchManager` so a changed terminal `transcript_item_count` or raw `updated_at` emits a new terminal sequence, broadcasts again, and resets push dedupe (`SessionWatchManager.swift:830-855,887-934`). Every accepted terminal dirties client catch-up; repeated dirty events can cause additional empty `get_log` calls at a completed offset (`RemoteAgentSessionController.swift:419-432,481-503,636-650`). A live snapshot fallback constructs `updatedAt: Date()`, while the normal stored-terminal path is stable (`AgentModeViewModel.swift:5290-5470`; `AgentRunMCPToolService.swift:2470-2570`). Therefore HEAD added a real amplification mechanism, but captured production payloads are needed to prove it churned in this incident. Do not call HEAD the transport root cause or remove timestamp fingerprinting without that evidence.

### 4. Eliminated or bounded alternatives
- The repeated `session_mismatch` plus one handled callback matches intentional per-host fanout to every controller, not duplicate WebSocket listeners (`RemoteHostConnectionManager.swift:37-55`; `RemoteAgentModeCoordinator.swift:282-323`).
- Pagination/terminal settlement explains repeated empty fetches and added load, not the subscribe timeout.
- HEAD resend/provider-text matching affects explicit resend or optimistic-row reconciliation after transcript arrival, not gateway admission.
- The active client uses the paired gateway WebSocket; `RemoteRelayClient` is a contract-only future interface with no runtime networking conformer.
- `agent_run` and `agent_manage` use a control lane with limit 8, not a single serialized app lane. Saturation remains an unmeasured latency contributor, not the primary boundary.

## Recommendations
1. **First fix: acknowledge subscribe before host validation/catch-up emission.** Split registration/intent from validation in `GatewayRuntime.handleSubscribe` and `SessionWatchManager.subscribe`, and add an explicit post-response validation hook at the `GatewayHTTPServer` send boundary. Keep binding decisions that can return `binding_required` before acknowledgment, and use a subscription generation/token so late validation cannot undo unsubscribe.
2. **Reduce subscription amplification.** In `RemoteHostConnection.subscribe/reconcileDesiredSubscriptions`, send deltas during normal operation, reserve full-set replay for reconnect, and serialize/coalesce overlapping reconciliation with an in-flight state plus dirty flag.
3. **Treat observation failure after adopted start as degraded recovery.** In `RemoteAgentSessionController.start` and `attachAndCatchUp`, retain the authoritative binding/start result on transient subscribe failure, surface degraded observation, and schedule one bounded/coalesced resubscribe + poll/`get_log` recovery. Do not swallow authentication, revocation, binding, or definitive command errors.
4. **Add an explicit sequence epoch.** Put an optional epoch on sequenced frames, persist it with the remote binding, reset `lastAppliedSeq` and force catch-up on epoch change, and reject delayed frames from older epochs. Do not reset `nextLogOffset`; it is a transcript cursor, not an event-sequence cursor.
5. **Do not broadly parallelize authenticated runtime handling first.** If head-of-line blocking remains after the subscribe-specific change, split strictly ordered authentication/counter admission from carefully classified per-session execution. Broad concurrency risks counter, subscribe/unsubscribe, steer/cancel, and command ordering.
6. **Instrument before changing fingerprint semantics.** Capture snapshot source, `transcript_item_count`, raw `updated_at`, emitted sequence, and fingerprint-change reason. Prefer a stable terminal content revision if volatility is confirmed; do not weaken the HEAD fix on inference alone.
7. **Add deterministic regression coverage.** Reproduce the ticket-authenticated early-frame/`get_log` FIFO cycle and the persisted-sequence/fresh-epoch failure before implementing the behavioral fixes.

## Preventive Measures
- Add cross-layer request lifecycle telemetry: redacted connection/sink generation, frame type/request ID, client register/send/complete/timeout, gateway enqueue/start/finish, subscribe session IDs, per-session validation duration, app-link invocation/tool, and queue/admission latency.
- Add sequence-domain observability: gateway epoch/uptime, client persisted epoch/cursor, and handled/gated frame sequence.
- Add controller/tab/object identity and active controller/subscription counts to mismatch/handled logs so intentional fanout is distinguishable from leaks.
- Add ticket-authenticated integration tests for subscribe acknowledgment ordering, early frames, same-socket `get_log`, timeout/late-result behavior, unsubscribe during late validation, and multi-session subscription timing.
- Add epoch tests for same-epoch duplicates, changed-epoch reset plus forced catch-up, legacy persisted bindings, and delayed old-epoch frames.
- Exercise terminal fingerprinting through real stored/live/indexed snapshot selection rather than fixed-timestamp test helpers.
- Require a correlated trace before labeling a production occurrence's unique cause; code-proven architecture defects may still be fixed with deterministic failing tests even if historical telemetry is incomplete.
