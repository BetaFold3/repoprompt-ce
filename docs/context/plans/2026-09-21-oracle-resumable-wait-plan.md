# Oracle resumable wait plan (bounded `ask_oracle` with steering wake)

Scope: read when the task touches `ask_oracle` wait behavior, Oracle operation handles or `op:"wait"`/`op:"cancel"`, the calling agent's prompt-cache warmth during long Oracle runs, or steering delivery while an Oracle consultation is in flight.
Authority: Reference
Last-verified: 2026-09-21

Status: Active. Step A is complete with no intended behavior change; Steps B and C remain planned.
Decision process: two independent Oracle lanes (OracleD and OracleE) received an identical brief with verified file:line evidence, then two anonymous reciprocal challenge rounds on six material disagreements (§7). Five converged. One (batch scope, §7.2) survived both rounds with the lanes swapping positions each round; both positions and the recommendation are recorded, none was silently picked. The OracleE final-round reply was delivered to the user's client rather than the lane and was relayed verbatim.
User decisions (interview, 2026-09-21): `op:"cancel"` ships in the first cut; the default `ask_oracle` contract changes (no opt-in flag); the steering release gate is live validation on Claude Code and Codex parents; batch scope was delegated to the plan author's judgment.

## 1. Outcome and scope

Make `ask_oracle` (Agent Mode only) a **bounded, resumable** consultation without changing the Oracle stream engine:

1. A send returns the complete answer when it arrives within the parent-family automatic wait (Claude 180 s, Codex 600 s, other/unresolved 180 s — the existing [`MCPTimeoutPolicy`](../../../Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift#L66) table, reused unchanged). Otherwise it returns a small **pending** result carrying an operation handle, and the Oracle keeps running.
2. `ask_oracle op:"wait"` observes the same query. It never resends, repackages, selects a model, reserves a query, or spends again.
3. A **steering wake** ends the in-flight wait early with a pending result so the queued steer can be delivered. `ask_oracle` stays in run-owned active-tool tracking; the tool result reaches the parent before any interrupt.
4. `ask_oracle op:"cancel"` stops a specific accepted consultation (user decision).
5. Presentation (`response_mode`, `export_response`) is frozen at send and finalized exactly once per operation.
6. Ownership follows the existing durable-session versus exact-run rules and survives same-session run rotation.

Why this matters: transport heartbeats never issue a parent-model request, so during a 20–60 minute Oracle run the parent's prompt cache goes cold (Claude Fable 5.1: $10/M input versus $0.25/M cache read; 5-minute cache write $12.50/M, 1-hour write $20/M). Returning control every 3/10 minutes lets the parent re-read its prefix at the cached rate. The same blocking call also causes a steering blackout (§2). These constants are product policy, not provider TTL claims; the wait-efficiency plan's §6.2 wording rules apply.

Non-goals: provider-native zero-output keep-alives (Pi-style 1-token warming remains deferred by the [wait-efficiency plan §6.5](2026-09-13-agent-usage-and-wait-efficiency-plan.md)); persisting operation handles across relaunch; changing `oracle_send` (stays synchronous); changing `AgentRunSessionStore`, tool capability/advertisement policy, or the two-stream cap; cache-retention inference or TTL registries.

## 2. Verified starting points

Line references identify the checkout inspected on 2026-09-21; they are not a guarantee against later movement.

| Boundary | Evidence and consequence |
|---|---|
| Blocking call chain | [`executeAskOracle`](../../../Sources/RepoPrompt/Infrastructure/MCP/MCPOracleToolService.swift#L160) still dispatches to synchronous single or batch service paths. Step A split [`tool_chatSend`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift) into `tool_chatSendStart`, `defer`-owned unpin, `waitUntilMessageFinalised`, and synchronous `tool_chatSendReply`; the wrapper still returns only after completion and preserves the prior wire behavior. |
| Heartbeats are transport-only | [`withHeartbeat`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L3762) (L3762–3798) only calls `sendProgress` every 30 s. No parent-model request occurs, so no prompt cache is refreshed. |
| Parent-family wait policy | [`AgentLifecycleParentFamily`](../../../Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift#L59), constants L66–75, resolver L87–98, explicit maximum 14 400 s at L83. [`AgentMCPWaitPolicy`](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPWaitPolicy.swift) owns `RequestContext`, `Selection`, `resolveParentFamily(runID:sessions:)` (L150–192), `selection(rawTimeout:parentFamily:)` (L197–203) and `attaching(_:to:)` (L207–211). All reused unchanged. |
| Current CLI deadline for `ask_oracle` | [`cliDefaultUnboundedToolNames`](../../../Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift#L46) lists `ask_oracle` and `context_builder` as unbounded on the owned CLI. Bounded single/wait calls therefore *gain* a deadline (§3.10). |
| Steering blackout cause | Claude-native flush waits on [`awaitNoActiveMCPTools(runID)`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift#L993) (L993–996); ACP flush at L590–593. The waiter parks on [`activeToolExecutionIDsByRunID`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L2085) (L2085–2110). Only `agent_run`/`agent_manage`/`agent_explore` are excluded from run-owned tracking ([`shouldRegisterRunToolExecution`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L3012) L3012–3021; [`MCPToolCapabilities`](../../../Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolCapabilities.swift#L83) L83–89). `ask_oracle` is `.control` for admission ([`MCPToolAdmissionPolicy`](../../../Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolAdmissionPolicy.swift#L58)) but *is* tracked, so steering waits for it. |
| Existing steering wake for `agent_run` | [`wakeAgentRunWaitersOwnedByActiveRun`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L2268) (L2268–2291) is reached for ordinary main sessions without any child control-context guard: [`wakeMCPWaitersForActiveDispatch`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L7857) (L7857–7866), manual active submit (L13853–13868, predicate [`shouldWakeParentAgentRunWaitersForActiveSubmit`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L13713) excludes Codex unless compaction is in flight), and the Codex drain wiring (L2148–2158 → [`wakeAndDrainAgentRunWaitersOwnedByActiveRun`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L2300)). The `agent_run` wait returns `interrupted_by_steering` plus a resume note ([`AgentRunMCPToolService`](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift#L2200) L2200–2208, L3016–3021). The `wakeCurrentMCPWaitersForSteeringRequest*` helpers (L5333–5386) *are* guarded on `mcpControlContext` and cover child sessions only. |
| Claude interrupt safe point | [`interruptClaudeTurnIfNeeded`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift#L1334) (L1334–1360) calls [`awaitSteeringInterruptSafePoint`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift#L1067) (default 2 s, L105), waiting for provider tool-result ack parity, and proceeds when local MCP tools are idle even if parity times out. The run-service queue itself deliberately does not block on parity (comment near L1009–1012). |
| Codex steering | [`sendCodexNativeMessage`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift#L4461) drains child `agent_run` waits (L4461–4464) before `steerUserTurn`; it does not gate on ordinary MCP idle. Whether a Codex steer is *effective* while an `ask_oracle` result is pending is unverified; the Oracle wake is still needed so the parent's next sampling sees the steer promptly. |
| Finalisation hub | [`MessageFinalisationHub`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift#L262) (L262–326): per-waiter registration; `cancel(id, waiterID:)` is waiter-local. [`waitUntilMessageFinalised`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift#L1612) (L1612–1648) returns for finalized, hub-completed, *or missing* messages; `fulfil` carries no outcome reason. Tests: [`OracleMessageFinalisationHubTests`](../../../Tests/RepoPromptTests/Chat/OracleMessageFinalisationHubTests.swift). |
| Terminal outcome evidence | Step A added an all-origin abnormal terminal notification hook beside the existing stream error and [`cancelAIResponse(in:)`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift) paths. It has one observer slot (latest setter wins), is duplicate-capable, and is not a reason store. Established provider-stop/finalization-claim/finalized-message evidence suppresses a later abnormal notification when success already won. Direct cancel remains **chat-scoped**, awaits the existing `cancelStream`, emits before its own hub fulfil paths only when completion has not won, then follows the prior clear/finalize behavior. |
| Reservation atomicity | Implicit/new sends still reserve inside one synchronous `performAtomicChooseAndReserve` closure (choose → pin → `beginSendMessageReservation`, no await). Explicit continuations still use `sendMessage(... overlapPolicy: .rejectIfBusy)`, which does not suspend between its busy check and reservation. Step A now creates the immutable ticket at the first synchronous point after `.started`; post-start activation/ownership awaits remain after that point. |
| Pins | [`pinSession`/`unpinSession`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift) remain reference-counted. A successful Step A ticket owns exactly one pin; start rejections release their temporary pin internally, and the synchronous wrapper releases the accepted ticket pin via `defer`, including observer cancellation. The post-start segment is intentionally nonthrowing until the caller receives the ticket. |
| Two-stream cap | [`maxConcurrentMCPOracleStreamsPerTab = 2`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift#L372), enforced at L3428–3431 via `activeMCPOracleStreamCount(forTabID:)`. The batch executor's `batchMaxConcurrentStreams` ([L149–150](../../../Sources/RepoPrompt/Infrastructure/MCP/MCPOracleToolService.swift#L149)) is a request-local window, not the authority. |
| Ownership rule | Step A extracted pure `oracleOwnerMatches`: session-owned chats match on durable `agentModeSessionID` regardless of run rotation; run-only chats require the exact run and cannot be adopted by a session-having caller; unowned legacy behavior remains caller-selected through `allowUnownedLegacy`. Existing continuation paths delegate to that helper. |
| Tool execution registration | [`registerToolExecution`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L1982) (L1982–2008); `runTool` registers with the already-resolved `indexedRunID` at L3212–3219 before the start gate opens (L3239) and unregisters in cleanup (L3266). |

## 3. Design

### 3.1 Contract: bounded by default

- Omitting `timeout_seconds` selects the frozen parent-family automatic wait. Explicit `0…14 400` is accepted; `0` polls (start, return pending immediately); larger values are rejected, not clamped.
- Not opt-in (user decision). A steering wake must be able to return a pending result from any in-flight call, so every caller must understand the pending shape anyway. `oracle_send` is unchanged and stays synchronous.
- The observation deadline starts when the operation receipt and observer are installed (after argument validation and authentication) and includes preparation and streaming; it is one monotonic deadline per invocation. A validated send is never aborted because the deadline passes during preparation — it returns pending.
- Timeouts and `op` are validated before any model selection, packaging, chat creation or send.

### 3.2 Tool surface

| Form | Accepted args |
|---|---|
| send, single (`op` absent or `"send"`) | existing single args + `op`, `timeout_seconds`, `request_id` |
| send, batch (`consultations`) | `consultations`, `require_distinct` + `op`; in Step B `timeout_seconds` and `request_id` are **rejected** (§3.7) |
| `op:"wait"` | `operation_ids` (optional array, 1…16; omitted = every undelivered operation the caller owns in the resolved tab, creation order — the post-compaction recovery path), `timeout_seconds` |
| `op:"cancel"` | `operation_ids` (required, 1…16, distinct); nothing else |

`response_mode` and `export_response` are frozen at send; wait and cancel reject all send args. Private `_`-prefixed routing args keep their current handling.

**Completed single send**: today's flat result plus `status:"completed"`, `operation_id`, and a root `wait_policy`.

**Pending single send** (target ≤ ~700 bytes, asserted by a test):

```json
{ "status": "pending", "operation_id": "…", "chat_id": "…", "query_id": "…", "mode": "plan",
  "model_preset_name": "…",
  "pending": { "reason": "timed_out|interrupted_by_steering|polled",
               "stream_state": "streaming|cancelling", "elapsed_seconds": 181 },
  "resume": { "op": "wait", "operation_ids": ["…"] },
  "note": "Oracle is still running; nothing was resent. Call ask_oracle with the resume args. Do not re-send the question.",
  "_meta": { "wake_reason": "steering_requested" },
  "wait_policy": { "mode": "automatic", "timeout_seconds": 180, "parent_family": "claude" } }
```

`_meta.wake_reason` is present only for a steering wake. A pending result never carries a `response` key. Model identity fields come from the same helper as the final reply so `agentFacingOracleResult`'s preset-redaction rule stays intact.

**`op:"wait"` result**: always an envelope, even for one ID — `{ "results": [lane…], "wait": { "result": "completed|timed_out|interrupted_by_steering|polled", "pending_operation_ids": […] }, "resume": {…}, "note", "_meta", "wait_policy" }`. Precedence: all terminal → steering requested → zero-timeout poll → deadline. A lane is a completed final result, a pending stub (without its own `wait_policy`/`resume`), a `{ok:false, status:"failed"|"cancelled", …}` lane, or `status:"unknown"` with code `oracle_operation_not_found` for unknown/evicted/not-owned IDs (the call does not fail as a whole and never reveals whether someone else's ID exists).

**`op:"cancel"` result**: per-lane current snapshots with `cancel: "requested"|"already_terminal"|"not_cancellable_yet"|"query_not_active"`; no `wait_policy` (nothing waited); root `resume` for `op:"wait"`.

Cached delivered lanes never contain `wait_policy`; each invocation attaches its own via `AgentMCPWaitPolicy.attaching(_:to:)` once at the root before `agentFacingOracleResult`. This deliberately differs from `agent_run` idempotent replay: a later Oracle wait is a new observation of the same query, possibly by a different parent family after a run rotation.

### 3.3 Operation store (Oracle-owned) and wake scope (MCP-owned)

**`OracleMCPOperationStore`** — new `@MainActor final class` in `Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleMCPOperationStore.swift`, owned once per `OracleViewModel`, injected into `MCPOracleToolService`. It owns execution receipts and delivery state, not a second copy of stream state:

- Immutable: registry-minted `operation_id` (UUID), `createdAt`, owner scope (tab ID; durable `agentModeSessionID` or exact run ID; originating run ID for attribution only), frozen `FinalizationRequest` (mode, message, `response_mode`, `export_response`, export destination derived from the original packaging scope), optional `request_id`, batch index (Step C).
- Mutable: `phase` (`starting | running | cancelling | ready | failed | cancelled`), bound `chat_id`/`query_id`, `delivery` (`undelivered | delivering(Task) | delivered(result, at)`), pin ownership, terminal-reason stamp.
- Authority: message finalisation (`isFinalized` + hub) remains the completion authority; `phase` is a projection written by exactly one completion observer per operation. The hub is not modified.
- Lifetime: kept until delivered or 24 h; delivered results cached 1 800 s for verbatim replay; at most 128 terminal records per store (evict oldest delivered first, never active work); lazy purge at register/wait entry, no timers. Compact tombstones (key, fingerprint, `operation_id`, `chat_id`) survive eviction and answer `oracle_operation_expired`.
- Not persisted. App relaunch loses the store; a later wait returns `oracle_operation_not_found`/`expired` and recovery is `oracle_chat_log` with the `chat_id` the caller already holds. Never reconstruct by resending.
- Owner match extracts the pure rule in `sessionMatchesOracleOwner` into `OracleViewModel.oracleOwnerMatches(ownerSessionID:ownerRunID:callerSessionID:callerRunID:allowUnownedLegacy:)`, called with `allowUnownedLegacy:false` plus a tab check; both the chat check and the store use it (one authority).
- Why Oracle-owned: an operation lives exactly as long as its stream, which `OracleViewModel` owns; query-matched stop, terminal-reason stamping, capacity release and pin ownership are all Oracle-side; whether `MCPServerViewModel` can be torn down while streams continue is unverified and the design must not depend on it.

**`OracleMCPWaitScope`** — invocation-local, in `MCPServerViewModel` beside the existing agent-run wait scopes. Created in `runTool` in the same synchronous MainActor sequence that registers the execution, using the already-resolved `indexedRunID`, **before the start gate opens**. Holds execution/run/connection identity and a sticky steering flag plus an `onWake` for an already-parked observer. Removed in the same cleanup that unregisters the execution. It owns how *this call* stops waiting; it never owns or cancels the query. When `indexedRunID` is nil the scope is never woken and the 180 s bound still applies. (A per-run generation counter was considered and dropped: with registration-time capture it is equivalent, and the scope's lifetime is already tied to execution cleanup.)

### 3.4 Split send acceptance from completion

In `OracleViewModel+MCP.swift`, without duplicating model-selection, packaging, ownership or reservation logic:

- `tool_chatSendStart(args:promptVM:tabContext:) async throws -> OracleMCPSendTicket` — steps through `setMCPSessionUIState`. Returns `chatID`, `queryID`, `createdFreshChat` and an immutable reply context (mode, tab/session/run IDs, model raw/display names, `modelSelection` fields, `outputReserveTokens`).
- **Bind the operation at the first synchronous point after `.started`, in both branches, before the post-start `activateResolvedChatSession`/`applyOracleOwnerIfNeeded` awaits (L2076–2098).** Verified sufficient: the implicit path is one synchronous closure and the explicit `.rejectIfBusy` path does not suspend after its busy check. No generic reservation callback is threaded into `sendMessage`/`beginSendMessageReservation`.
- Step A's successful ticket owns exactly one ref-counted pin; rejected starts unpin internally and the wrapper releases its ticket pin exactly once with `defer`. The segment from ticket creation through return is deliberately nonthrowing because the caller cannot release a ticket it has not received. In Step B, bind transfers that same pin to the operation at the synchronous bind point; any future pre-return throw must release it internally, while post-bind work must remain non-fatal.
- `tool_chatSendReply(for ticket:) throws -> [String: Value]` — synchronous MainActor read of the finalized message (today's step 6); extract `modelIdentityFields(_:)` for reuse by pending stubs.
- `tool_chatSend` becomes the wrapper (start → `defer` unpin → `waitUntilMessageFinalised` → reply). `oracle_send` behaves exactly as before; a wrapper-parity test proves it.
- Service seams: keep `sendChat` for `oracle_send`; add `startOracleSend` returning the ticket; `performAskOracleSend` stops at start and returns the ticket plus the computed `FinalizationRequest`.

### 3.5 Completion observer and once-only finalization

- At bind, the store spawns one unstructured `@MainActor` completion task per operation: `await waitUntilMessageFinalised(queryID)` → re-enter MainActor → classify from the terminal-reason stamp (§3.8) → capture the raw reply → release the pin → set `ready|failed|cancelled` → resume registered observers → publish one card tick.
- A missing message, hub cleanup, observer cancellation or supervisory timeout is never success.
- `finalizeAskOracleResult` takes `(result: inout, request: FinalizationRequest, routingArgs:)`; the export destination comes from the frozen request; a resolved-tab mismatch takes the existing `export_failed_warning` inline fallback so a response is never lost.
- Delivery is single-flight: `deliver(opID, finalize:)` returns the cached result, awaits an in-progress delivery task, or runs `finalizeAskOracleResult` once; a throw reverts to `undelivered` for retry. Export therefore happens at most once per operation regardless of concurrent waits.
- Completion beats wake: whenever a waiter resumes, it first re-checks whether all requested operations settled and delivers if so, even when the wake reason was steering.

### 3.6 Bounded wait, wait policy, steering wake

- `MCPOracleToolService` gets `resolveWaitInvocation: () async -> (AgentMCPWaitPolicy.RequestContext, callerRunID: UUID?)`, implemented by `MCPServerViewModel` with the same `resolveRunIDForExecution` + single MainActor `resolveParentFamily(runID:sessions:)` read that `agent_run` uses. `callerRunID` is the ID used for `activeToolExecutionIDsByRunID`. Unresolved → 180 s, no wake.
- Park primitive mirrors `awaitNoActiveToolExecutions`: `withTaskCancellationHandler` + `withCheckedContinuation`; a same-turn double-check resumes immediately if all operations settled, the scope's sticky flag is set, the waiter was pre-cancelled, or the deadline passed; a per-waiter sleep fires `.deadline`; removing the waiter record is the exactly-once resume token; timeout 0 skips parking. `withHeartbeat` keeps wrapping the bounded wait.
- **Steering trigger**: as the first statement of `wakeAgentRunWaitersOwnedByActiveRun`, before its `guard !sessionIDs.isEmpty`, mark and wake every Oracle wait scope owned by that run. Verified call sites (§2) already reach this for Claude-native, ACP and Codex without child control-context guards; no additional `AgentModeViewModel` wake routes are added. The `hasActiveChildAgentRunWaits`-conditional Codex drain must be exercised with an Oracle-only wait in the gate; if the steer does not land, extend the drain precondition to include an existing Oracle wait scope.
- Sequence after the wake: the Oracle call returns the pending stub (or the final result if completion raced) → `runTool` cleanup unregisters → `toolIdleWaitersByRunID` resumes the flush → the existing provider safe point (Claude: bounded 2 s ack parity) → interrupt. Unchanged: `shouldRegisterRunToolExecution`, `MCPToolCapabilities`, `MCPToolAdmissionPolicy`, `hasActiveChildAgentRunWaits`. No transport send receipt is added (§7.5).
- Pending operations still count in `activeMCPOracleStreamCount(forTabID:)`. The `.rejectedTabConcurrencyLimit` and `.rejectedSessionBusy` messages name `op:"wait"`/`op:"cancel"` and, via the start context, the caller's running `operation_id`s.

### 3.7 Batch (staged — see §7.2)

**Step B (first cut)**: `executeAskOracleBatch` keeps its synchronous request-owned path and today's result shape (no `status`/`operation_id`/`wait_policy`); lanes are not registered, so `op:"cancel"` cannot address them. Admission requires `activeMCPOracleStreamCount(forTabID:) == 0` at validation (the only condition under which the request-local window of 2 is correct); otherwise a typed `oracle_batch_requires_idle_tab` rejection lists the caller-owned running `operation_id`s and names wait/cancel as the remedy — no spend. `timeout_seconds` and `request_id` are rejected on batch, not ignored. Schema and guidance state that batch blocks until all lanes finish, is not steerable, and recommend the equivalent bounded pattern for long duels: two single sends with `timeout_seconds: 0` (each returns pending immediately), then one `op:"wait"` with both handles. Residual race: a competing single could start between admission and the first lane start; that reproduces today's lane-failure behavior and is documented.

**Step C (committed follow-up)**: one app-owned per-tab FIFO scheduler as the single slot authority (the request-local window is removed), atomic receipt admission after validation, queued lanes with null chat/query IDs that survive the observation and connection loss, a 32-nonterminal-operations-per-tab bound checked all-or-nothing before any lane record exists, an owner-liveness gate at lane start (session-owned: session has an active run; run-owned: exact run active; otherwise `not_started_owner_inactive`), revalidation immediately before reservation after preparation awaits, `queued → cancelled` with no spend, mixed completed/pending/failed envelopes ordered by `index`, and "a single is never queued". The multi-handle wait envelope from Step B is reused unchanged.

### 3.8 Cancel (first cut, user decision)

- `operation_ids` required and distinct; omission never means cancel-all; the whole list is resolved and authorized (same owner rule + tab) before any mutation; unknown/unauthorized → per-lane `oracle_operation_not_found`, no stop issued.
- **Query-match rule**: `cancelAIResponse(in:expectedQueryID:)` gains a defaulted parameter; the guard sits where `runStateBySession[sessionID].activeQueryId` is read, in the same synchronous MainActor segment that initiates the stop. On mismatch it does nothing (no stop, no `fulfil` for any ID) and returns `queryNotActive`. The cancel op never compares IDs outside this function. Verify there is no await between the read and the stream-task cancel; if there is, act on the captured task.
- Phases: `starting` → `not_cancellable_yet`; `running` + match → stop issued, `phase = cancelling`, `cancel:"requested"`; `running` + mismatch → liveness reconcile, actual state, `cancel:"query_not_active"`; `cancelling` → no second stop; terminal → unchanged, `already_terminal`. Legal exits `cancelling → cancelled | completed | failed` (completion can beat the stop); only the completion observer writes the terminal phase. Cancel never parks and never delivers.
- Terminal-reason stamp: `store.noteStreamTerminal(queryID:reason:)`, first-writer-wins, no-op when no operation is bound (UI queries accumulate nothing). Called in the synchronous segment before `fulfil` at the L3756 emission site (`.streamCancelled` → cancelled, `.streamFailed` → failed) and on `cancelAIResponse`'s matched path (needed for ordering, since that function fulfils the hub itself). The observer classifies from the stamp only: absent → completed. Never from hub completion, response text, or a "cancel requested" flag. A user pressing Stop in the Oracle UI yields `status:"cancelled"` through the same path.
- A cancelled lane never exports (`export_skipped:"cancelled"` if an export was requested); partial text is delivered under `partial_response`, never `response`; shape `ok:false, status:"cancelled"`. Capacity and pin are released by the authoritative stream-retirement/observer path, exactly once — not by the cancel request or hub fulfilment.
- The steering note never mentions cancel; schema text says cancel only when the user asks or the question is known to be wrong.
- Tool-task cancellation and MCP connection close affect only the observer (and heartbeat); they never reach the stream.

### 3.9 Duplicate-spend protection

Only an explicit caller-supplied `request_id` (UUID), scoped to the authenticated durable owner (or exact run) plus tab. It reserves a `starting` record synchronously before the first await of the start step so concurrent same-key calls cannot both pass. A normalized intent fingerprint (message, model/preset selector resolved to preset identity, `chat_id`/`new_chat`, selection options, `response_mode`, `export_response`; excluding `timeout_seconds`) is compared only under that key: identical intent observes the existing handle; different intent fails before mutation; an evicted key returns `oracle_operation_expired`. No content-based rejection (§7.3): an unkeyed repeated send is a new consultation, and guidance states that limitation. Not promised across relaunch.

### 3.10 Client and gateway deadlines

`ask_oracle` is currently unbounded on the owned CLI (§2). Classify by args, not tool name: bounded single send and `op:"wait"` with omitted timeout → 630 s (`agentLifecycleAutomaticWaitResponseEnvelopeSeconds`); explicit positive → `max(300, timeout_seconds + 30)` (14 400 → 14 430); explicit 0 → ordinary deadline; cancel → ordinary; Step B batch (`consultations`) → keeps the existing unbounded classification. A caller-supplied timeout policy remains authoritative. Gateway (if it routes `ask_oracle` at all — verify): 630 s automatic, existing `clamp(t+30, 60, 900)` explicit, 900 s cap retained with the documented >870 s caveat. Host coverage must land with or before the 600 s Codex branch.

### 3.11 Tool cards, observability, guidance

- Card states: `waiting` (wait segment reuses the lifecycle helper: `wait ≤3m`/`≤10m`/`wait auto`; after completion the canonical `wait_policy` owns the segment), `pending`, `cancelling`, `completed`, `cancelled`, `failed`. A pending result never renders as done and the earlier pending wire result is never mutated into a final one the parent did not receive.
- Live sidecar for pending cards reads `store.summary(for:)` (phase, elapsed, chat ID/name): "Oracle running · 12m", "Oracle finished — not yet collected", "Collected", plus an open-chat affordance. The store publishes on phase transitions only (no per-token publication). Historical/post-relaunch rows say "last reported pending", never "running".
- Diagnostics: `AgentModePerfDiagnostics.event("mcp.oracle.wait", …)` with mode, timeout, family, outcome, parked ms, operation count, stub bytes; plus phase/wake-reason/finalization counts. No prompts, bodies, credentials or account identity.
- Guidance (schema, CLI help, `WorkflowPromptSharedFragments.swift`, the five workflow owners, `WorkflowPrompt+Reminder.swift`, compaction-recovery text): pending is normal; omit `timeout_seconds` routinely; never resend after pending; `op:"wait"` without IDs after compaction; the Oracle keeps running after a timeout; a wait or heartbeat warms no cache; after steering, respond to the user first, then resume waiting; batch still blocks in Step B (and the two-singles pattern). Never claim a wait is "cache-safe" or TTL-derived.

## 4. File-by-file impact

| File | Change |
|---|---|
| `Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleMCPOperationStore.swift` (new) | Store, operation/owner types, dependencies struct (fakes in tests), park primitive, single-flight delivery, terminal-reason stamp, tombstones, summaries, DEBUG accessors. Step C adds the scheduler. |
| `Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift` | Split `tool_chatSend` into `tool_chatSendStart` / `tool_chatSendReply` / wrapper; `OracleMCPSendTicket`, `modelIdentityFields`; extract `oracleOwnerMatches`; bind at the first synchronous point after `.started`; updated busy/cap texts. Lands first with no behavior change. |
| `Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift` | Own the store; `cancelAIResponse(in:expectedQueryID:)`; `noteStreamTerminal` stamp at the lifecycle emission site; internal liveness accessor over `SessionRunState`. Hub unchanged. |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPOracleToolService.swift` | `op` dispatch (`send`/`wait`/`cancel`), allowlists, `startOracleSend`, `resolveWaitInvocation`, bounded single path, batch idle-tab admission + arg rejection (Step B), pending/envelope builders, `finalizeAskOracleResult` signature, `request_id`. |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` | `OracleMCPWaitScope` created at execution registration before the start gate and removed in cleanup; wake as the first statement of `wakeAgentRunWaitersOwnedByActiveRun`; implement `resolveWaitInvocation`; inject the Oracle-owned store; DEBUG hooks beside `test_beginAgentRunWaitScope`. |
| `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPWaitPolicy.swift` | Doc comments only; `RequestContext`, `selection`, `attaching` reused unchanged. |
| `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift` + owned CLI deadline classifier | Arg-based `ask_oracle` classification (§3.10); widened doc comments. |
| `ChatToolError` definition (locate) | `oracleOperationNotFound`, `oracleOperationExpired`, `oracleBatchRequiresIdleTab`. |
| Tool schema, CLI help, workflow prompt files, tool-card renderer/sidecar (locate by `askOracle`, `"ask_oracle"`, `ui_model_id`, `finalizeAskOracleResult`) | Guidance and card states (§3.11); must land atomically with the flip. |
| `docs/context/workflows/validation.md` | Extend the wait-policy row to cover the `ask_oracle` lifecycle suites. |
| `AGENTS.md` | Route row for this plan. |

Unchanged: `AgentRunSessionStore`, `MessageFinalisationHub`, `MCPToolCapabilities`, `MCPToolAdmissionPolicy`, advertisement policy, bootstrap leases, `MCPContextBuilderToolProvider`, `AgentModeRunService` (no new wake routes), Codex/Claude coordinators (verification only).

## 5. Validation

Focused suites (`make dev-test FILTER=<SuiteName>`; new suites need surgical ledger rows, `RPCE_ALLOW_UNKNOWN_FILTER=1` once):

- `OracleMCPOperationStoreTests` (new): timeout leaves the operation intact; wake scoped to run; sticky flag set before park; completion beats wake; single-flight export runs once under two concurrent waits; cached replay; failed finalize reverts to undelivered; owner match across run rotation; cancel-before-park; eviction and tombstones; terminal-reason classification (cancelled/failed/completed, first-writer-wins); pin released exactly once; teardown.
- `MCPAskOracleLifecycleTests` (new): invalid timeout never invokes `startOracleSend`; `op:"wait"`/`op:"cancel"` reject send args; pending stub byte ceiling; `wait_policy` correct for automatic (per family), explicit, poll; multi-handle envelope order; `request_id` identical/different intent; batch idle-tab rejection and `timeout_seconds` rejection on batch; cancel phases and `query_not_active`.
- Step A `AgentOraclePillRoutingTests`: independent preset and nonpreset golden wire fields (including routed tab/session/run context); wrapper versus start-wait-reply outcome parity; successful ticket/wrapper pin balance; busy/cap rejection pin balance; wrapper-observer cancellation releases its pin without stopping the query; failure/cancel notification ordering; deterministic finalization gates prove late error/cancel cannot stamp completed work.
- Step B bind-point coverage: explicit-continuation bind happens before post-start awaits so observer cancellation between reservation and return leaves a discoverable record.
- Steering integration: `test_beginResolvedToolExecution` tracks `ask_oracle` for a run; park an Oracle waiter; call `wakeAgentRunWaitersOwnedByActiveRun`; assert the steering-pending result and that `awaitNoActiveToolExecutions` drains.
- `OracleMessageFinalisationHubTests`: unchanged (hub untouched).
- Tool-card suite: pending/cancelling/cancelled states, historical non-live presentation, canonical wait labels.
- Core: `make dev-core-test` for the deadline classifier. Products: `make dev-swift-build PRODUCT=repoprompt-mcp`, `make dev-lint`; unfiltered `make dev-test-parallel` for contribution evidence.

Live checks (CE debug app; follow the AGENTS.md approval rule before any launch): Claude parent with a slow preset → pending → wait → final with one export; steering mid-wait delivered within ~2 s and the result collected afterwards; Codex parent gets 600 s waits and a steer lands with an Oracle-only wait (no child `agent_run`); explicit cancel of a running consultation → `cancelling` → `cancelled` with partial text and no export; relaunch mid-Oracle → recovery message; batch in Step B rejected on a busy tab with the running IDs named. Gate (user decision): Claude Code and Codex parents.

Measurement: with the existing usage accounting, record `cache_read / (cache_read + cache_creation + input)` on the first parent turn after the Oracle result, the number of `op:"wait"` calls, stub bytes and output tokens per supervisory turn; compare before/after on a ~20-minute consultation. Report measured numbers, not an assumed TTL.

## 6. Implementation order

1. **Step A — complete (no intended behavior change)**: split `tool_chatSend`, extract `oracleOwnerMatches`, add the liveness accessor and terminal-reason emission hook, wrapper-parity test, surgical ledger rows, and verified owner inventory (§9).
2. **Step B (atomic cutover)**: store + wait scope, bounded single send, `op:"wait"` (multi-handle), `op:"cancel"`, steering wake, `wait_policy`, `request_id`, batch idle-tab admission and arg rejection, deadline classification, cards, guidance, tests, docs. Host coverage lands with the 600 s branch.
3. **Step C (committed follow-up issue)**: per-tab FIFO scheduler, 32-operation bound, owner-liveness gate, queued cancel, mixed batch envelopes; remove the "batch blocks" guidance.
4. **Deferred**: Oracle progress hints in stubs; `oracle_send` in Agent Mode; applying the pattern to `context_builder` (do not generalize the store ahead of time); provider keep-alives (wait-efficiency plan §6.5).

## 7. Material disagreements and resolution

| # | Topic | Round-1 split | Outcome |
|---|---|---|---|
| 7.1 | Explicit `op:"cancel"` in first cut | one lane deferred it (UI stop exists; reflexive-cancel risk; cancelled outcome unverifiable), the other required it (queued lanes could spend later) | **Converged + user decision: ship it.** Verification that `cancelAIResponse` is chat-scoped and that `.streamCancelled` is emitted before `fulfil` supplied the missing outcome evidence; the narrowed contract in §3.8 (required IDs, same-segment query match, non-parking `cancelling`, stamp-derived outcome, no export) was accepted by both. |
| 7.2 | Batch in first cut | staged vs full | **Open after two rounds — lanes swapped each round.** *Position S (staged)*: keep the synchronous batch path in Step B with an idle-tab admission rule and rejected wait controls; the scheduler adds spend-after-return, which needs the owner-liveness gate, queued cancel, a bound and cleanup validation — a separately validated lifecycle; two singles + multi-handle wait already give Oracle's full concurrency (cap 2). *Position F (first cut)*: the idle-tab check is racy (a single can start during the batch's async preparation; registry records are not stream occupancy; legacy `oracle_send` can occupy a slot) and the interim exclusion is a temporary contract the complete design replaces; the synchronous batch keeps the longest-call blackout. **Recommendation: Position S**, because the user's long-duel workflow is fully served by two `timeout_seconds: 0` singles plus one multi-handle wait, the residual race is no worse than today's lane-failure behavior and is documented, and staging follows the repository's stage-scope-deliberately principle with Step C committed as a follow-up. Both critiques are recorded in §3.7. The user delegated this call. |
| 7.3 | Duplicate-spend guard | automatic content digest vs explicit `request_id` | **Converged: explicit `request_id` only.** A digest of message/mode/model omits inputs that define the consultation (`chat_id`, slices, review-git diff, resolved preset identity) and would reject legitimately different sends; the digest lane conceded. Residual risk (unkeyed resend) is mitigated by the no-`response` pending shape, the note, and cap errors naming running IDs. |
| 7.4 | Registry ownership and wake state | `MCPServerViewModel` registry + per-run generation vs `OracleViewModel` store + separate invocation scope | **Converged: Oracle-owned store; MCP-owned invocation-local wait scope created at execution registration; trigger as the first statement of `wakeAgentRunWaitersOwnedByActiveRun`.** The generation lane found its own capture-after-await race (the run ID came from an async resolver); registration-time capture fixes it and makes a counter redundant. Verified call sites show no extra `AgentModeViewModel` wake routes are needed. Minor residual (generation + scope vs scope only) resolved by the plan author: scope only. |
| 7.5 | Response-delivery fence | new `MCPConnectionManager` send receipt vs existing safe point | **Converged: no wire receipt.** A socket write is weaker than provider ack parity; a receipt adds a new way for steering to hang. Verified: the Claude interrupt path waits (bounded 2 s) for ack parity via `awaitSteeringInterruptSafePoint`; the run-service queue does not, by design. Release gate = live steer tests on the actual Claude and Codex paths. |
| 7.6 | Registration boundary | generic reservation callback through `sendMessage` vs same-turn bind | **Converged (verified): bind at the first synchronous point after `.started`, before post-start awaits; no generic callback.** The explicit-continuation `sendMessage(.rejectIfBusy)` path has no await after its busy check. |

## 8. Risks

- Pending read as an answer, or a resend after pending → duplicate spend. Mitigations: no `response` key on pending, the note, `request_id`, cap errors naming running IDs.
- A steering path misses the wake → delay bounded at 180/600 s (today: the whole Oracle run). The registration-time sticky flag covers a steer that arrives during preparation.
- Handle loss on relaunch/eviction → recoverable via wait-without-IDs, then `oracle_chat_log`; never by resending.
- Pin lifetime moves from the call to the stream; the liveness reconcile and single release path cover an observer that never fires.
- Step B batch keeps the blackout and has a documented admission race; Step C is the committed fix.
- Codex steer effectiveness with an Oracle-only wait is unverified; it is in the release gate.
- Rollback is a code revert: no persisted schema, no migration.

## 9. Step A verified inventory for Step B

Verified in the shared checkout on 2026-09-21:

- `ChatToolError` is owned by `Sources/RepoPrompt/Infrastructure/MCP/ChatToolError.swift`.
- The primary schema is `MCPOracleToolProvider.askOracleTool()` in `WindowTools/MCPOracleToolProvider.swift`; Agent Mode's Knowledge overlay is `AgentModeMCPToolPolicy.knowledgeAskOracleDescription`.
- Owned CLI timeout resolution is `InteractiveMCPClientSession.resolvedTimeout`; its default path checks `MCPTimeoutPolicy.cliDefaultUnboundedToolNames`, which currently contains `ask_oracle`.
- CLI help for `ask_oracle` is in `Packages/RepoPromptCore/Sources/RepoPromptMCPCore/RepoPromptMCPCore.swift` near the conversation-tool help.
- `RemoteCommandTranslator` translates `agent_run`, `agent_manage`, and `manage_workspaces`; it has no `ask_oracle` route.
- Tool-card routing is `ToolCardRouter` → `ChatSendResultCard` in `ToolResultCommunicationCards.swift`, decoded through `ToolResultDTOs.ChatSendDTO` in `Infrastructure/MCP/ToolResultDTOs.swift`.
- `MCPServerViewModel.oracleToolService` constructs the service and supplies `sendChat`; `executeAskOracle` receives only the args. `runTool` registers the execution before opening its start gate.
- Codex's `sendCodexNativeMessage` invokes the active wait drain. `wakeAndDrainAgentRunWaitersOwnedByActiveRun` currently fast-exits behind `hasActiveChildAgentRunWaits`.
- The DEBUG execution helper is `test_beginResolvedToolExecution`; there is no `test_beginToolExecution` helper.
- Evidence correction: `cancelAIResponse` captures the active query and stream IDs, awaits the existing `cancelStream`, then conditionally emits the captured query's abnormal cancellation before its own finalisation-hub fulfil paths. Stop behavior and query matching are unchanged. Provider error handling still emits lifecycle activity before fulfil; non-cancellation terminal notification is published only after the existing finalization claim succeeds.
- The Step A terminal hook observes every send origin and has one replaceable observer slot. It may emit duplicates or disagreeing reasons when a provider reports cancellation as another error; it does not implement first-writer-wins. Step B's operation store alone must mint the durable first-writer-wins terminal stamp.
- Existing completion authority wins races: provider-stop evidence, an in-progress finalization claim, or an already-finalized message suppresses later abnormal notification. Deterministic gates cover late provider error and direct cancel while a successful finalizer owns the claim, and assert that the completed response survives unchanged.
- Watchdog obligation for Step B: the existing finalization watchdog reaches the same finalization claim without an abnormal reason, while inactivity cancellation/error paths can produce abnormal notifications. Store classification must preserve the winning claim, tolerate hook multiplicity, and test watchdog completion versus late error/cancel without adding a second stream-state authority.
- A successful `OracleMCPSendTicket` owns exactly one session pin. `tool_chatSendStart` releases rejected temporary pins; `tool_chatSend` releases the accepted pin with `defer`, including waiter cancellation. The post-start ticket-to-return segment is nonthrowing; a future throw there must unpin internally. Busy/cap rejection and observer-cancellation pin balances are covered.
- `waitUntilMessageFinalised` returns immediately for a missing message, an already-finalized message, or a hub-completed query.
- `MessageFinalisationHub`, the service/schema/deadline/gateway/card surfaces, `cancelAIResponse` query matching, operation storage, wait scopes, and steering behavior remain unchanged in Step A.
