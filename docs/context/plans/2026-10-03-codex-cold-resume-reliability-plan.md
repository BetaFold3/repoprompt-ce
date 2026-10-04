# Codex cold-resume reliability plan (oversized `thread/resume`, metadata-only resume, same-thread identity)

Scope: read when the task touches Codex app-server stdout framing or overflow handling, `thread/resume` parameters or `excludeTurns`, `thread/turns/list`, Codex thread lifecycle reconciliation after resume, `readThreadSnapshot` readers, the repeated-resume-timeout fresh-thread fallback, or presentation of cancelled Codex native starts.
Authority: Reference
Last-verified: 2026-10-03

Status: Phases 1 and 2 implemented; OracleA and OracleB completed independent review and one fresh scoped re-review, with no remaining P0/P1 findings. Nonblocking follow-ups and a baseline-red documentation gate remain. Phase 3 remains unimplemented. The automatic repeated-timeout fresh-thread fallback and cancellation presentation therefore remain unchanged, and end-to-end cold-resume reliability is not yet accepted.

## Phase 1–2 implementation record

- Codex inbound frames have a 32 MiB decode ceiling and generation-scoped fail-fast errors; shared `ProcessStreamFraming.swift` is unchanged. `CodexCLIProvider` also handles the new typed error in its exhaustive error-message switch.
- Resume requests use `excludeTurns`; generation-scoped compatibility memos and bounded newest-turn listing preserve runtime status and reconcile routing. Live readers retain a bounded-transport legacy fallback. The coordinator queues cold sends behind resumed activity without synthesizing `turn/started`.
- Owner decision for §8.6 (2026-10-03): use the recommended notification-replay approach and add a terminal-ID set only if the regression demonstrates a user-visible failure. No set was added.
- Phase 1: six transport tests and 117 lifecycle tests passed; packaging and lint passed. The synthetic 23,243,972-byte response resolved. One instrumented run measured 139.4 MB peak RSS (40.1 MB before payload construction); this is not a worst-case JSON object-graph measurement.
- Initial Phase 2 validation: the nine-suite run executed 280 tests, with 279 passing and one unchanged ACP prompt-write acknowledgement test failing. All 22 initial resume tests passed. Packaging and lint passed.
- Round 1 remediation: 73/73 focused Codex tests passed; the broader focused run passed 246/247, with the same ACP timeout. The unfiltered `make dev-test-parallel` passed 6,318 tests across 589 suites (ticket `a88f7c03-70ce-449c-93c8-424a61db88ad`), with five suites requiring retries: lifecycle, MCP agent wait, worktree code structure, OMP smoke-script, and remote-session suites. This is a pass with retries, not a clean first attempt. Build (`d466022a-78d3-4b42-9e37-e33d49b25e04`), lint (`51aa28cf-f414-49ab-95c3-f3202371d099`), and whitespace checks passed.
- The ACP timeout also reproduced outside this patch on main `cf704272622e555e291c106bd0723f74377c92f4` (ticket `dc3ff103-fa28-4368-b45d-fc201646983a`), whose relevant AgentMode/ACP/provider sources match base `a11b77e`. Other source areas differ, so this is not an exact clean-base reproduction and does not establish the failure's cause.
- Both re-review lanes explicitly closed original P1 CR-01 (idle read bypassing an identified turn's terminal barrier), CR-02 (multiple resumed inputs losing FIFO recovery), and CR-03 (prewarm bypassing the busy gate). The remediation also preserves the rejected `excludeTurns` memo after a successful no-flag retry, propagates startup transport-fatal failures, narrows compatibility classification, and accepts exact-limit split CRLF.
- Gate status: context/guardrail checks fail on six dead export links in the untouched oracle-shim/knowledge-worker plan, already committed at base `a11b77e`; the targets were only untracked in main. The negative context-checker suite passed 23/23. No gate waiver is implied. The existing unrelated Pair-guidance ledger omission remains.
- Validation uses synthetic transports/executors; no real user turn or visible app lifecycle was exercised. The planned `ProcessCoreTests` suite was not found in this checkout; the new transport suite exercises the existing framer through the Codex client. The full-root run is recorded above; §7.3 live checks remain outstanding.

### Nonblocking follow-ups from scoped re-review

- OracleA retains CR-04: an unrelated rejection accompanied by an `itemsView` diagnostic mention can still cause a compatibility retry. OracleB closed the original classifier examples but recorded related method/field-message edge cases. These remain nonblocking; neither lane's disposition overrides the other.
- The split-CRLF fix permits one extra unfinished carry byte. An exactly `L+1` non-CR carry can wait for another chunk/terminator; EOF can report `processNotRunning` rather than the frame-limit error. Completed payloads above L still fail. OracleA records this as R1-01 (P2); OracleB records the boundary caveat as R1-06 (P3).
- OracleB R1-01 (P2, plausible): stale active runtime status after an ordinary completed turn can conservatively queue a later cold send until an idle read. The specific non-resumed second-send case lacks dedicated coverage.
- The unbound idle-read-before-replayed-start ordering remains a distinct, unproven-risk limitation, not the closed identified-blocker CR-01 scenario. No terminal-ID set was added.
- The interrupt-refresh revision guard has no current production caller; its coverage is through a DEBUG hook. The controller-only no-dispatch assertion is not coordinator dispatch evidence. The existing 128-entry binding buffer and legacy nil-ID completion handling remain follow-ups.
- OracleB R1-02 (P2, plausible) asked whether an identified resumed blocker ending failed/interrupted strands queued input. A subsequent read-only trace found `turnCompleted` calls `abandonCodexFallbackQueueBlockedByTerminalTurn` before finalization: matching non-completed blockers clear the queue, mark MCP entries stale, restore manual drafts/attachments, and publish the cancellation notice. Managed-auth recovery has a separate early-return path and controller replacement abandons the queue. `testNilCompletionDoesNotDrainAndFailedCompletionAbandonsBlockedHead` covers the shared failed-blocker cleanup, but not the exact cold-resume failed/interrupted scenario. This is a factual answer, not a new Oracle closure or dedicated runtime proof.
- Additional nonblocking review follow-ups: post-read pump lineage revalidation before identity mutation, the now-stateful dispatch-planning helper, and duplicated resumed-wait predicates. No further minor-finding review loop was run.

The sections below retain the phased contract with implementation clarifications; Phase 3 and full reliability acceptance are still pending.
Decision process: two independent Oracle lanes (OracleE and OracleD) received the same brief with verified file:line evidence and four binding user decisions. Material disagreements were relayed anonymously for two challenge rounds (§8). Every point converged except one narrow item (§8.6), which is recorded with both positions and a recommendation.

## 1. Outcome and scope

After quitting and reopening RepoPrompt, continuing an existing Codex Agent session must resume the **same** native thread reliably. Today it can hang at "Initializing…". Stop then reports `Codex native resume failed: … (Swift.CancellationError error 1.)`.

Most likely cause: an ordinary `thread/resume` returns the whole thread history as one JSON-RPC line. The Codex stdout framer drops oversized lines silently, so the matching request never resolves. The mechanism is reproduced; attribution of the original GUI incident is strongly supported but not trace-confirmed.

In scope:

1. Make oversized inbound frames fail the Codex transport immediately and explicitly, with a larger Codex-only frame ceiling.
2. Resume with `excludeTurns:true` and reconcile lifecycle state with bounded turn metadata.
3. Migrate the full-turn `thread/read` readers to bounded turn listing.
4. Remove the automatic fresh-thread replacement after repeated resume timeouts.
5. Present a user Stop as a cancellation, not as a native-resume failure.

Not in scope:

- Behavior of other `LineFramer` consumers (Claude native, ACP, Codex exec, ClaudeCode provider). `ProcessStreamFraming.swift` stays unchanged.
- The missing-rollout fresh-thread fallback (`allowMissingRolloutFallback`). It is a different, explicitly messaged recovery.
- Stall-watchdog idle classification (§8.4). File it separately if wanted.
- History pagination UI, or hydrating turn items for display.
- Any persisted-session migration. None is needed.

### Binding user decisions (2026-10-03)

| ID | Decision |
|---|---|
| U1 | Remove automatic fresh-thread replacement. Keep the saved thread and show an actionable error. Handoff or new thread happens only as an explicit user action. Update the existing test contract deliberately. |
| U2 | Runtimes that ignore or reject `excludeTurns` get a larger Codex-specific frame limit as a compatibility concession, and fail fast above it. |
| U3 | Migrate the post-resume `thread/read includeTurns:true` readers to bounded `thread/turns/list`, with a fallback when it is unsupported. |
| U4 | Deliver as phased commits in one plan, each validated independently. |

## 2. Verified starting points

Line references identify the checkout inspected on 2026-10-03.

| # | Fact | Anchor |
|---|---|---|
| F1 | `LineFramer` defaults: 8 MiB line, 16 MiB carry, 128 KiB retained tail. The overflow check runs only on the unfinished carry after each chunk. Completed lines are never size-checked. | `ProcessStreamFraming.swift:54-58`, `:162-175` |
| F2 | The Codex client builds the framer with default limits at three sites. Overflow only prints when debug logging is on. | `CodexAppServerClient.swift:352`, `:653`, `:1015`, `:1131-1143` |
| F3 | On a decode failure, `handleJSONLine` tries recovery and then returns silently, leaving the matching request pending. The 128-attempt recovery budget resets after any successful decode, so one garbage line never trips it. | `:1156-1186`, `:366`, `:1188-1200` |
| F4 | `invalidateTransport` is scoped to one transport generation and idempotent. It fails every pending request exactly once and cancels their timers. Timeouts of `thread/start` and `thread/resume` use it. | `:586-629`, `:330-336`, `:1578-1600` |
| F5 | `handleStdoutChunk` has no generation check. The stdout consumer captures `generation` only for EOF. | `:1065-1070`, `:1110-1117` |
| F6 | Cancelling a request resumes its continuation with `CancellationError()`. | `:815-817`, `:1609-1614` |
| F7 | `startOrResume` sends `thread/resume` without `excludeTurns`. The only compatibility retry covers "unknown variant" enum values. | `CodexNativeSessionController.swift:1069-1192`, `:698-745` |
| F8 | Binding buffering covers the whole start/resume window. Notifications are consumed by a separate task under `eventHandlingMutex`; responses resume continuations directly. | `:1077-1079`, `:2062-2068`, `:2102-2132` |
| F9 | `restoreThreadSnapshot` drops `runtimeStatus`. `SessionRef` carries only identity, model and effort. `latestTurnStatus` has no production reader. | `:437-483`, `:1824-1845`, `:1863-1900` |
| F10 | Three readers use `thread/read includeTurns:true`: interrupt reconciliation, which requires exactly one active ID; interrupt refresh; and the fallback pump. | `:1539-1566`, `:1608-1630`; `CodexAgentModeCoordinator.swift:2311-2353` |
| F11 | The server rejects a stale turn ID with "expected active turn id `X` but found `Y`", which the controller already parses. This implies one active turn per thread. | `CodexNativeSessionController.swift:1625-1638` |
| F12 | After two timeouts for the same target, the coordinator starts a fresh thread. The catch block has no `CancellationError` branch, and Stop resets the timeout counter. | `CodexAgentModeCoordinator.swift:381`, `:3091-3135`, `:4250-4421` |
| F13 | A test asserts the replacement: `testCodexRepeatedResumeTimeoutFallsBackToFreshStartForSavedThreadID`. | `AgentModeRunServiceLifecycleTests.swift:2664-2710` |
| F14 | The installed `codex-cli 0.159.0` schema has `ThreadResumeParams.excludeTurns`. `ThreadStatus` is `notLoaded`, `idle`, `systemError` or `active{activeFlags}`, with no turn ID. `ThreadTurnsListParams` takes `limit`, `sortDirection` (default `desc`) and `itemsView` (`notLoaded`, `summary` or `full`). Each `Turn` has an `id` and a `status`. | generated schema, 2026-10-03 |
| F15 | Offline, private-history evidence: ordinary resume returned one 23,243,972-byte line; with `excludeTurns:true` it returned 8,177 bytes. A synthetic chunked 9.4 MB response caused one overflow, left the request pending, and Stop produced `CancellationError`. | prior diagnostic sessions (temporary tests removed) |

## 3. Phase 1 — Codex transport fail-fast and frame ceiling

Goal: no inbound frame can be silently lost. Oversized frames end the transport generation with a typed error.

**`CodexAppServerClient.swift`**

- `Config.maxInboundFrameBytes = 32 * 1024 * 1024`.
- Add `makeStdoutFramer()` with Codex-local `maxLineBytes: L+1`, `maxCarryBytes: L+1`, and `tailRetainBytes: 0`; completed payloads retain the exact L ceiling. The extra byte admits an exact-limit payload whose CR and LF arrive separately; the unfinished-carry/EOF caveat is recorded above. Use it at all three construction sites (`:352`, `:653`, `:1015`) and in the DEBUG transport install. A zero tail is safe because Codex terminates on overflow and never recovers from a tail.
- Add `TransportTerminationReason.inboundFrameLimitExceeded(observedBytes:limitBytes:generation:)`.
- Add `ClientError.inboundFrameTooLarge(observedBytes:limitBytes:)`, with byte sizes only in its description. `isTimeoutError` must stay false for it. Add `static func isInboundFrameLimitError(_:)`.
- Detection, without mutating `stdoutFramer` inside `feed` (an overlapping-access trap):
  - **Carry overflow:** `handleStdoutFramerDiagnostic(.overflow)` records `pendingInboundFrameViolation`, regardless of debug logging.
  - **Oversized completed line:** the first statement of `handleJSONLine` checks `lineData.count <= L` before trimming, decoding or recovery. A failing line records the violation and returns. While a violation is pending, later lines are ignored.
- Drain: after `feed` returns in `handleStdoutChunk`, and after the DEBUG raw-line hook, a pending violation for the current generation calls `invalidateTransport(flushStdout:false, expectedGeneration:, requestFailure: .inboundFrameTooLarge…, reason: .inboundFrameLimitExceeded…)` and then `scheduleTransportCleanup`. Clear the violation on transport reset.
- Pass the consumer task's captured generation into `handleStdoutChunk(_:generation:)`. Drop the chunk unless `generation == transportGeneration && !didTerminateTransport`. This closes F5.
- Completed lines before the overflow in the same batch are self-contained frames and still route. There is no batch discard.
- Diagnostics: always log one line with sizes, generation, and the pending method names from `pendingRequestMetadata`. Never log payload content. Remove the tail-sample preview from the overflow diagnostic.
- DEBUG hooks: `debugSetMaxInboundFrameBytes(_:)` and `debugIngestRawStdoutChunk(_:)`. The second calls `handleStdoutChunk`, so tests exercise real chunked framing with kilobyte-scale fixtures.

**`CodexAgentModeCoordinator.swift` (minimal):** in the start/resume catch (`:4406-4414`), treat `isInboundFrameLimitError` like a control-plane timeout for controller invalidation (`invalidateCodexControllerForReconnect(source: "inbound-frame-limit")`), because the process is already gone. The timeout counter is not touched. Message wording lands in Phase 3.

**Ceiling and memory.** 32 MiB admits the observed 22.2 MiB response with about 40% headroom. 16 MiB would fail it, and 64 MiB would roughly double transient memory without bounding legacy histories. 32 MiB is the **ceiling for accepting and decoding a message, not a hard allocation ceiling**:

- An oversized completed line is allocated before rejection, overshooting by up to one pipe read.
- Queued chunks, `Data` capacity slack, the `emitLine` copy, and the `JSONSerialization` object graph (roughly 3–5 times the text size) add memory.
- Peak transient memory for the worst accepted frame is on the order of 250–300 MB, released after apply and at transport reset.

Metadata-only resume (Phase 2) is the normal memory fix; 32 MiB is compatibility protection only.

## 4. Phase 2 — Metadata-only resume, lifecycle reconciliation, reader migration

### 4.1 `excludeTurns` compatibility policy

- Send `excludeTurns:true` on `thread/resume` unless it is memoized as `.rejected`. Keep every existing parameter, and keep omitting `baseInstructions`.
- Memoize `ExcludeTurnsSupport` (`.unknown`, `.honored`, `.ignored`, `.rejected`) and `TurnsListSupport` (`.unknown`, `.supported`, `.unsupported`). Key them to the client transport generation, exposed through a read-only accessor, so a restarted app-server is probed again.
- **Rejected:** a structured `thread/resume` failure whose message names `excludeTurns` or `exclude_turns` as an unknown, unsupported, unrecognized or unexpected field or parameter. In that case, memoize and retry **once** without the flag. Wrap this retry outside the existing value-style retry, which still applies inside it. A bare `-32602` code, a generic "unknown field" message, a timeout, an auth error or a frame-limit error never qualifies.
- **Ignored:** the response succeeds with a non-empty `thread.turns` array. Memoize, log once, and use those turns as today; no second round trip. This is the realistic legacy case, because a Rust app-server ignores unknown fields by default.
- **Honored:** turns are absent or empty. This is indistinguishable from an empty legacy thread, and the difference is harmless.
- Parse the response into a compact `ThreadSnapshot` immediately, and don't keep the raw dictionary across later awaits. Replace `applyThreadResponse(_:fallbackEffort:)` with `applyThreadSnapshot(_:)`.

### 4.2 Reconciliation inside the binding window

Run reconciliation after the resume response and before `disableThreadMemoryMode` and the `eventHandlingMutex` apply block. This is still inside the binding window (F8), so the mutex is never held across an RPC and every notification is buffered and replayed after apply.

| `runtimeStatus` (turns empty) | Action | Installed state |
|---|---|---|
| `idle` | No call. | Empty routing. |
| `active(flags)` | `thread/turns/list {threadId, limit:1, sortDirection:"desc", itemsView:"notLoaded"}`, timeout `min(requestTimeout, 15)`. | If the newest turn is `inProgress`, it becomes the active and current turn. Otherwise the thread is active with an **unresolved identity**. |
| `active` with turns present (option ignored) | No call. | From the response, as today. |
| `notLoaded` | No call. Log once. | Empty routing. The status stays `.notLoaded` and is never relabeled `.idle`. The next user `turn/start` on the saved thread decides the outcome (§8.4). |
| `systemError` | No call. | Throw `CodexSessionControllerError.threadInSystemErrorState(threadID:)`. The coordinator keeps the thread and shows an actionable error. |

- If `thread/turns/list` is unsupported or fails **during startup**, proceed as active with an unresolved identity. Never fall back to a full `thread/read` at startup; it could exceed the frame ceiling on the just-resumed transport.
- Retain `lastKnownRuntimeStatus` in the controller. Set it in `restoreThreadSnapshot`, in `reconcileActiveTurnRoutingState`, and in the existing thread-status notification handling. Expose it through a `CodexSessionControlling` extension that defaults to nil, so test doubles don't need changes. Include the status and flags in the DEBUG `session.threadReady` record.
- **Unresolved active identity:** in `applyCodexNativeSessionStartResult`, if the status is `.active` and `codexAuthoritativeActiveTurn` is nil, set `session.codexAnonymousActiveTurn`. `codexTurnDispatchPlan` already treats that marker as busy, so new text queues behind it. `pumpCodexFallbackIfAuthoritativelyIdle` clears it once a read reports `.idle`. Never fabricate a `turn/started`.
  - Validate during implementation: the marker's initializer, and whether a listed `inProgress` ID reaches `codexAuthoritativeActiveTurn` without a `turn/started`.
- Turn ordering: `activeTurnOrder` already de-duplicates (`:2275-2276`). Notifications are replayed in arrival order after apply. See §8.6 for the remaining narrow race.

### 4.3 Reader migration (U3)

Keep the `readThreadSnapshot(includeTurns:timeout:)` signature, so there is no protocol or test-double churn. Change only its internals:

1. Always call `thread/read {includeTurns:false}` first.
2. If the caller passed `includeTurns == false`, or the status is `.idle`, return.
3. Otherwise call `thread/turns/list {limit:1, desc, itemsView:"notLoaded"}` within the caller's timeout. Map an `inProgress` newest turn to `activeTurnIDs`/`currentTurnID`, and its status to `latestTurnStatus`.
4. **Unsupported detection:** a `-32601` code on the `thread/turns/list` request, or a message naming that method as unknown or not found. Memoize `.unsupported` and fall back to the legacy `thread/read {includeTurns:true}`, which Phase 1 bounds. Later calls go straight to the fallback. If the error names `itemsView`/`notLoaded`, retry once without `itemsView` (a one-turn summary is still bounded) and memoize. Other errors propagate.

Effect on the callers:

- `reconcileAndInterruptCurrentTurn` keeps its authoritative-ID shortcut. Its "exactly one" check now runs over the bounded result. Single-active-turn semantics plus the server's stale-ID rejection (F11) make that sufficient.
- The fallback pump needs one RPC when idle; its `timeout: 2` bounds each request.
- **Live-read race guard:** add `routingRevision: UInt64` to the controller. Increment it in `restoreThreadSnapshot`, in `reconcileActiveTurnRoutingState`, and in the `turn/started`/`turn/completed` handlers that mutate routing. `refreshActiveTurnForInterruptIfPossible` captures the revision before awaiting. If it changed, the snapshot is discarded and the function returns `.refreshed(routingCurrentTurnID)`. It never returns `.failed` for a superseded snapshot, which would revive the cached ID through `resolvedInterruptTurnID`.

## 5. Phase 3 — Same-thread identity and cancellation presentation

**Remove the replacement machinery (U1).** Delete all of the following, and the `allowResumeTimeoutFallback` parameter at every call site (grep, because some are outside the inspected slices). `.missingRollout` stays.

- `repeatedResumeTimeoutFallbackThreshold` (`:381`)
- `CodexNativeSessionFallbackReason.repeatedResumeTimeout` (`:310`)
- `repeatedResumeTimeoutRecoveryMessage` and its `recoveryMessage` case
- `shouldSkipResumeAfterRepeatedTimeouts`
- `shouldRetryFreshStartAfterResumeTimeout`
- The skip and rewrite branches (`:4250-4275`, `:4318-4323`)
- The fresh-start retry block (`:4345-4389`)

**`CodexResumeTimeoutState`** stays but only drives messages. It increments on a target-specific timeout. It resets on success, on a target change, or on a genuine failure that is neither a timeout nor a cancellation. It is **not** reset on Stop. It never affects which request is sent.

**Catch restructure** (`CodexAgentModeCoordinator.swift:4280-4421`):

1. The first branch, **before** auth recovery, is `if effectiveError is CancellationError`. Repeat it in the nested auth-recovery catch.
   - It invalidates only the captured controller (`source: "resume-cancelled"` or `"start-cancelled"`), because the app-server may still be processing the resume.
   - It logs one line, appends **no** error item, and doesn't touch the counter.
   - The first settlement of the continuation decides: a genuine timeout or frame error that settled before Stop stays visible on its attempt. **`Task.isCancelled` is never used to classify errors.**
2. Otherwise, classify the failure:
   - **Timeout:** record the count (resume only) and invalidate.
   - **Frame limit:** reset the count and invalidate.
   - **System error or other:** reset the count and `markCodexReconnectNeeded`.
3. Append one error item that keeps the `codexNativeSessionFailurePrefix`, so `isCodexNativeSessionFailureText` still matches, followed by guidance:
   - Timeout, first time: "Your saved thread was kept. Send again to retry the same thread."
   - Timeout, count ≥ 2: "Codex has timed out resuming this thread N times in a row. Your saved thread was kept. Send again to retry, or use Handoff to continue in a new thread."
   - Frame limit: "Codex sent more than 32 MB of thread history, which this Codex version can't skip. Update Codex and retry, or use Handoff to continue in a new thread."
   - System error: "Codex reports this thread is in an error state. Your saved thread was kept. Retry, or use Handoff."

**Late-success guards:**

- In `startOrResume`, call `try Task.checkCancellation()` after the resume or start response and again before the `eventHandlingMutex` apply block. The existing catch cancels binding.
- `disableThreadMemoryModeForeground` rethrows `CancellationError` instead of counting it as an attempt and scheduling the background retry.
- In the coordinator, after `startCodexNativeSession` returns on both the normal and the auth-recovered paths, `guard !Task.isCancelled` before `applyCodexNativeSessionStartResult`. If cancelled, invalidate the captured controller and return.
- Cleanup must target only the captured controller and must not alter a successor attempt.

## 6. File-by-file impact

| File | Phase | Change |
|---|---|---|
| `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift` | 1, 2 | Frame ceiling and factory; new error and termination cases; violation record and drain; generation-gated chunk ingestion; size-only diagnostics; DEBUG hooks; read-only generation accessor |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` | 2, 3 | `excludeTurns` policy and memo; turns-list helper; `applyThreadSnapshot`; reconciliation; `lastKnownRuntimeStatus`; `routingRevision`; `readThreadSnapshot` internals; system-error error; cancellation checks; memory-mode rethrow |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | 1, 2, 3 | Frame-limit invalidation; unresolved-activity marker; fallback removal; catch restructure; guidance messages; late-success guard |
| `Sources/RepoPrompt/Infrastructure/Process/ProcessStreamFraming.swift` | — | **Unchanged** |
| `Tests/RepoPromptTests/AI/CodexAppServerInboundFrameLimitTests.swift` (new) | 1 | Transport suite |
| `Tests/RepoPromptTests/AgentMode/Codex/CodexNativeResumeLifecycleTests.swift` (new) | 2, 3 | Controller suite using `requestExecutor` injection |
| `Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift` | 1, 3 | Test-double extensions; deliberate contract replacement; cancellation tests |
| `Scripts/Fixtures/test-suite-contract-ledger.tsv` | 1, 2, 3 | Register new methods in the commit that introduces them, following `docs/testing.md` |

## 7. Validation

### 7.1 Per-phase tests

**Phase 1 — `CodexAppServerInboundFrameLimitTests`.** Use a small debug limit, `debugInstallTestTransport`, and `debugIngestRawStdoutChunk`.

- A line exactly at the limit resolves; limit + 1 fails. Test both chunked delivery and single-chunk delivery of a completed line, plus CRLF.
- Valid frames before an overflow in the same batch still resolve.
- An overflow fails all pending requests exactly once with `.inboundFrameTooLarge`; the pending count and timer count are zero; `lastTransportTerminationReason == .inboundFrameLimitExceeded`.
- A stale-generation chunk after `debugInstallTestTransport` is a no-op.
- `isTimeoutError` is false for the new error.
- EOF flush behavior is unchanged.
- One synthetic case of about 23.3 MB at the real 32 MiB limit succeeds.
- Checkout correction: `ProcessCoreTests` and standalone existing `LineFramer` tests are absent here. This item is N/A; the new Codex transport suite supplies replacement framing coverage, and shared `ProcessStreamFraming.swift` remains unchanged.

Also in Phase 1, `AgentModeRunServiceLifecycleTests`: a frame error during resume gives `.failed`, leaves `codexConversationID` unchanged, and invalidates the controller.

**Phase 2 — `CodexNativeResumeLifecycleTests`.**

- Resume params include `excludeTurns:true`.
- Rejected, ignored and honored responses; a bare `-32602` is not retried; the memo resets with the client generation.
- Idle: no turns-list call.
- Active: exact list params, and the in-progress ID is routed (prove it by routing a later item notification).
- Active with the newest turn terminal: unresolved identity, and the busy marker is set.
- Startup list unsupported: unresolved identity, and no full read.
- `notLoaded`: ready, status preserved.
- `systemError`: typed error, identity preserved.
- `readThreadSnapshot(includeTurns:true)`: idle short-circuit; list path; `-32601` falls back to the full read once, then the memo applies; an `itemsView` rejection retries without it.
- The interrupt path picks the listed ID.
- Live refresh superseded by a notification during its await: routing is not clobbered, and the result is not `.failed`.
- Buffered start and completion replay over a listing that shows the turn completed: the turn is not active.
- **Completion delivered after apply** (§8.6): the state converges to not active, and no new turn is dispatched in between.

**Phase 3 — `AgentModeRunServiceLifecycleTests` and the controller suite.**

- Replace `testCodexRepeatedResumeTimeoutFallsBackToFreshStartForSavedThreadID` with `testCodexRepeatedResumeTimeoutKeepsSavedThreadAndResumesSameThreadOnRetry`:
  - Two failed runs, each `startReferences[i]?.conversationID == "saved-thread"`; saved ID and path unchanged; counts 1 and then 2.
  - No system item containing "Started a fresh thread".
  - Error items carry the prefix, "saved thread was kept", and (on the second) "Handoff".
  - A third run is `.sent` with `startReferences[2]?.conversationID == "saved-thread"`, and the count resets to 0.
  - This is strictly stronger than the old test: it proves the same thread resumes.
- `testCodexResumeCancelledByStopShowsNoFailureItem`: no failure-prefixed item; identity and counter unchanged; the controller is invalidated.
- `testCodexResumeFailureBeforeStopStaysVisible`: a timeout or frame error settles, then Stop arrives; the error item is present.
- `testCodexResumeLateSuccessAfterCancelIsDiscarded`: no text is dispatched, there is no tool tracking, and the controller is invalidated.
- Controller suite: cancellation between the response and apply throws `CancellationError` and cancels binding; memory-mode cancellation is rethrown with no background retry.
- Existing missing-rollout and auth-recovery tests keep passing.

### 7.2 Commands

For each commit, run `make dev-test FILTER=<Suite>` for every affected suite, then `make dev-build` and `make dev-lint`. Run `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` before committing. Use synthetic transports and executors only; never submit a real user turn.

### 7.3 Acceptance before calling resume reliable

- All three phases are green under their suites.
- A manual check with a fingerprinted packaged app: quit, reopen, and continue the affected large-history session. This needs explicit user approval at the app-lifecycle boundary. Record request IDs, byte counts, and the termination reason, never payloads.
- Confirm the saved native thread ID is unchanged across Stop-before-ready, repeated timeouts, and a successful resume.

## 8. Material disagreements and resolutions

### 8.1 Where to enforce the frame limit — resolved (round 1)

- **Position A:** add an opt-in `failClosed` overflow policy inside the shared `LineFramer`, enforced before appending, with whole-batch discard and latching.
- **Position B:** leave the shared framer untouched; detect through the existing diagnostic plus a size guard in `handleJSONLine`; act on the violation after `feed`; gate chunks by generation.
- **Resolution:** B, with A's additions — the generation gate, violation recording independent of debug logging, and wording the limit as a decode ceiling rather than an allocation ceiling. A conceded: batch discard is unnecessary, since earlier completed lines are valid frames, and B keeps Claude, ACP and exec behavior unchanged.

### 8.2 Classifying Stop versus a genuine failure — resolved (round 1)

- **Position B (initial):** `error is CancellationError || Task.isCancelled` means a quiet cancel.
- **Position A:** a genuine error can settle the continuation before Stop, with `Task.isCancelled` becoming true before the catch runs; the disjunction would hide it.
- **Resolution:** only `error is CancellationError`, checked before auth recovery and in nested catches. `Task.isCancelled` is used only for the late-success guard. B conceded.

### 8.3 What counts as rejecting `excludeTurns` — resolved (round 1)

- **Position B (initial):** a bare `-32602` code, or a message mentioning the field or "unknown field", counts as rejection.
- **Position A:** a generic invalid-params error could concern `cwd` or `config`; retrying would mask it and fetch full history.
- **Resolution:** retry only when the error names `excludeTurns`/`exclude_turns` as an unknown or unsupported field. B conceded.

### 8.4 Lifecycle reconciliation shape — resolved (rounds 1–2)

- **Initial A:** reconcile after the drain, with epoch and revision guards, up to 8 pages of `limit:1`, a `turnIDsComplete` flag, a new `threadLifecycleReconciled` event, `notLoaded` treated as unready, an explicit-`.idle` watchdog, and a legacy full-read fallback.
- **Initial B:** reconcile inside the binding window with `limit:2`, no new event or counters, `notLoaded` ready with idle routing, watchdog unchanged, and no startup full read.
- **Converged:**
  - Inside the binding window, with no new event and no paging; a bounded newest-turn lookup is sufficient given single-active-turn semantics (F11).
  - No startup full read, but unresolved activity is preserved and busy.
  - Readers keep the legacy fallback.
  - `systemError` raises a typed error.
  - `notLoaded` completes readiness **without** being relabeled idle; `turn/start` decides.
  - The watchdog stays unchanged (out of scope).
  - A narrow `routingRevision` guard protects the live interrupt refresh.
  - `lastKnownRuntimeStatus` feeds the existing anonymous-activity marker.

### 8.5 Minor points settled by coordinator judgment

- **`limit:1` versus `limit:2`:** chose `limit:1`. The extra terminal row has no production consumer, and `limit:1` avoids reversing descending order before the parser's `.last` selection.
- **`itemsView` rejection:** retry once without `itemsView` (a bounded one-turn summary) rather than declaring the method unsupported.
- **Capability memo scope:** keyed to the client transport generation, so an app-server restart probes again.
- **Frame-limit invalidation:** lands in Phase 1, so the transport fix is independently useful. Message wording waits for Phase 3.
- **Watchdog log:** optionally add the status name to the log at `CodexAgentModeCoordinator.swift:3462`. This is cosmetic.

### 8.6 Turn resurrection after a reconciled listing — owner decision recorded

The question: a buffered `turn/started(X)` is replayed after a listing that already shows X completed, while X's `turn/completed` has not yet been buffered.

- **Position "no merge":** stdout is one ordered stream. If the listing shows X completed, X's completion was written before the response and will be applied, either from the buffer or right after the drain. The only drop path was framer overflow, which Phase 1 turns into termination. The state is therefore eventually correct, and no merge logic is needed.
- **Position "small terminal set":** byte order does not fix processing order. Responses resume continuations directly, while notifications go through a separate task (F8), so the listing can be applied and the buffered start replayed before the completion is consumed, briefly reactivating X. Keep a small controller-owned set of terminal IDs learned from the listing until the next binding, and ignore stale starts for those IDs.
- **Coordinator verification:** notifications are consumed by a separate task under `eventHandlingMutex` (`CodexNativeSessionController.swift:2062-2068`), and responses resume continuations directly. So the brief reactivation is possible. The completion is still processed right after the apply/drain releases the mutex, so the final state converges. The same window already exists with today's full-history resume.
- **Recommendation:** adopt "no merge", and add the delayed-completion regression test (§7.1, Phase 2). It asserts convergence and that no new user turn is dispatched during the window. Add the terminal-ID set only if that test, or the manual acceptance check, shows a user-visible effect, such as a spurious running indicator or a queued message being held. **Owner selected this recommendation on 2026-10-03.** The scoped re-review closes the identified-blocker pump race after deterministic regression coverage; it does not certify the separate unbound idle-read-before-start ordering.

## 9. Risks and open questions

- **Older runtimes:** behavior of `excludeTurns` and `thread/turns/list` before `0.159.0` is unverified. Synthetic tests encode the assumed error shapes. Check one older release if a minimum supported version is defined. There is no numeric version gate today.
- **Legacy cases that still fail:** a runtime that ignores `excludeTurns` and has more than about 1,150 history items (above 32 MiB) still fails. It now fails fast, keeps the thread, and shows an actionable message. This is the accepted concession (U2).
- **Active turn after a cold resume:** probably unreachable if the app-server process dies with the app. Unverified, because the installed rotator shim may broker app-server lifetime. The unresolved-activity marker covers it either way.
- **`waitingOnApproval` after resume:** whether the app-server re-emits a pending approval request when such a thread is resumed is unknown. Log the flags; out of scope.
- **Call sites outside the inspected slices:** other `allowResumeTimeoutFallback` call sites and other `CodexSessionControlling` conformers. Grep before editing.
- **Incident attribution:** strongly supported, not trace-confirmed. The manual acceptance check (§7.3) should record the termination reason so the next occurrence is attributable.
- **Memory:** 32 MiB bounds accepted frames, not process memory. Measure synthetic peak RSS once in Phase 1.
