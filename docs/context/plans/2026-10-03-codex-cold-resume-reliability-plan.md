# Codex cold-resume reliability plan (oversized `thread/resume`, metadata-only resume, same-thread identity)

Scope: read when the task touches Codex app-server stdout framing or overflow handling, `thread/resume` parameters or `excludeTurns`, `thread/turns/list`, Codex thread lifecycle reconciliation after resume, `readThreadSnapshot` readers, repeated-resume-timeout handling (the fresh-thread fallback is removed in Phase 3), or presentation of cancelled Codex native starts.
Authority: Reference
Last-verified: 2026-10-05

Status: All three phases are implemented. OracleA and OracleB completed independent Phase 3 review and three fresh scoped re-review rounds, with no remaining P0/P1 findings. The final-source full-root run passed 6,331 tests across 589 suites with six suite retries; build and lint passed. Nonblocking review follow-ups and the pre-existing unrelated Pair-guidance ledger omission remain. The live §7.3 acceptance check remains outstanding, so end-to-end cold-resume reliability is not yet accepted and this plan is not archived. The records below distinguish historical failures, reviewer closure, and final validation.

## Phase 1–2 implementation record

- Codex inbound frames have a 32 MiB decode ceiling and generation-scoped fail-fast errors; shared `ProcessStreamFraming.swift` is unchanged. `CodexCLIProvider` also handles the new typed error in its exhaustive error-message switch.
- Resume requests use `excludeTurns`; generation-scoped compatibility memos and bounded newest-turn listing preserve runtime status and reconcile routing. Live readers retain a bounded-transport legacy fallback. The coordinator queues cold sends behind resumed activity without synthesizing `turn/started`.
- Owner decision for §8.6 (2026-10-03): use the recommended notification-replay approach and add a terminal-ID set only if the regression demonstrates a user-visible failure. No set was added.
- Phase 1: six transport tests and 117 lifecycle tests passed; packaging and lint passed. The synthetic 23,243,972-byte response resolved. One instrumented run measured 139.4 MB peak RSS (40.1 MB before payload construction); this is not a worst-case JSON object-graph measurement.
- Initial Phase 2 validation: the nine-suite run executed 280 tests, with 279 passing and one unchanged ACP prompt-write acknowledgement test failing. All 22 initial resume tests passed. Packaging and lint passed.
- Round 1 remediation: 73/73 focused Codex tests passed; the broader focused run passed 246/247, with the same ACP timeout. The unfiltered `make dev-test-parallel` passed 6,318 tests across 589 suites (ticket `a88f7c03-70ce-449c-93c8-424a61db88ad`), with five suites requiring retries: lifecycle, MCP agent wait, worktree code structure, OMP smoke-script, and remote-session suites. This is a pass with retries, not a clean first attempt. Build (`d466022a-78d3-4b42-9e37-e33d49b25e04`), lint (`51aa28cf-f414-49ab-95c3-f3202371d099`), and whitespace checks passed.
- The ACP timeout also reproduced outside this patch on main `cf704272622e555e291c106bd0723f74377c92f4` (ticket `dc3ff103-fa28-4368-b45d-fc201646983a`), whose relevant AgentMode/ACP/provider sources match base `a11b77e`. Other source areas differ, so this is not an exact clean-base reproduction and does not establish the failure's cause.
- Both re-review lanes explicitly closed original P1 CR-01 (idle read bypassing an identified turn's terminal barrier), CR-02 (multiple resumed inputs losing FIFO recovery), and CR-03 (prewarm bypassing the busy gate). The remediation also preserves the rejected `excludeTurns` memo after a successful no-flag retry, propagates startup transport-fatal failures, narrows compatibility classification, and accepts exact-limit split CRLF.
- Gate status (updated 2026-10-04): with owner approval, documentation-only commit `5ac8aa87` replaced six dead links to untracked Oracle exports in the oracle-shim/knowledge-worker plan with plain-text evidence identifiers. Context/guardrail checks and commit/push safety preflight now pass; the existing route-count warning remains. The negative context-checker suite passed 23/23. The existing unrelated Pair-guidance ledger omission remains.
- Validation uses synthetic transports/executors; no real user turn or visible app lifecycle was exercised. The planned `ProcessCoreTests` suite was not found in this checkout; the new transport suite exercises the existing framer through the Codex client. The full-root run is recorded above; §7.3 live checks remain outstanding.

### Nonblocking follow-ups from scoped re-review

- OracleA retains CR-04: an unrelated rejection accompanied by an `itemsView` diagnostic mention can still cause a compatibility retry. OracleB closed the original classifier examples but recorded related method/field-message edge cases. These remain nonblocking; neither lane's disposition overrides the other.
- The split-CRLF fix permits one extra unfinished carry byte. An exactly `L+1` non-CR carry can wait for another chunk/terminator; EOF can report `processNotRunning` rather than the frame-limit error. Completed payloads above L still fail. OracleA records this as R1-01 (P2); OracleB records the boundary caveat as R1-06 (P3).
- OracleB R1-01 (P2, plausible): stale active runtime status after an ordinary completed turn can conservatively queue a later cold send until an idle read. The specific non-resumed second-send case lacks dedicated coverage.
- The unbound idle-read-before-replayed-start ordering remains a distinct, unproven-risk limitation, not the closed identified-blocker CR-01 scenario. No terminal-ID set was added.
- The interrupt-refresh revision guard has no current production caller; its coverage is through a DEBUG hook. The controller-only no-dispatch assertion is not coordinator dispatch evidence. The existing 128-entry binding buffer and legacy nil-ID completion handling remain follow-ups.
- OracleB R1-02 (P2, plausible) asked whether an identified resumed blocker ending failed/interrupted strands queued input. A subsequent read-only trace found `turnCompleted` calls `abandonCodexFallbackQueueBlockedByTerminalTurn` before finalization: matching non-completed blockers clear the queue, mark MCP entries stale, restore manual drafts/attachments, and publish the cancellation notice. Managed-auth recovery has a separate early-return path and controller replacement abandons the queue. `testNilCompletionDoesNotDrainAndFailedCompletionAbandonsBlockedHead` covers the shared failed-blocker cleanup, but not the exact cold-resume failed/interrupted scenario. This is a factual answer, not a new Oracle closure or dedicated runtime proof.
- Additional nonblocking review follow-ups: post-read pump lineage revalidation before identity mutation, the now-stateful dispatch-planning helper, and duplicated resumed-wait predicates. No further minor-finding review loop was run.

## Phase 3 implementation record (2026-10-04; subsequent review and remediation below)

- **Replacement removed (U1).** `CodexAgentModeCoordinator.swift` no longer has `.repeatedResumeTimeout`, its threshold, the skip/rewrite branches, the fresh-start retry, or their helpers and message. `allowResumeTimeoutFallback` is gone from every source call site (`ensureCodexNativeSession`, its recursive calls, `/compact`, `/goal`, recovery, managed-auth recovery). `CodexNativeSessionFallbackReason` keeps only `.missingRollout`; that fallback is unchanged.
- **Catch restructure.** The start block captures `startController` and whether the attempt is a resume. `error is CancellationError` is the first branch, before auth recovery, and is repeated in the nested auth-recovery catch. `discardCancelledCodexNativeSessionStart` logs one line, invalidates only the captured controller (`resume-cancelled`/`start-cancelled`), appends nothing, and leaves the counter alone. Everything else goes to `handleCodexNativeSessionStartFailure`, which classifies by error type only (`codexNativeSessionFailureKind`):
  - Timeout: record the count (resume only) and invalidate.
  - Frame limit: reset the count and invalidate.
  - System error or other: reset the count, and call `markCodexReconnectNeeded` only if the attempt still owns the controller slot.
  - The item keeps `codexNativeSessionFailurePrefix` and appends the §5 guidance (`codexNativeSessionFailureGuidance`); the frame-limit size comes from `Config.maxInboundFrameBytes`.
  - Guidance applies to resume attempts only. Fresh-start failures keep the prefix and description, and a fresh-start timeout leaves the count unchanged.
- **Late-success guards.** After `startCodexNativeSession` returns, on both the normal and auth-recovered paths, `guard !Task.isCancelled` discards the result through the same captured-controller cleanup: no apply, no tool tracking, no dispatch. Auth recovery replaces the controller only while the slot still holds the attempt's controller; otherwise it reports the original error. `sendCodexNativeMessage` returns `.cancelled` when its task is cancelled with no reported start failure. It finalizes an owned run as interrupted, or restores attachments, instead of reporting a missing thread.
- **Timeout state.** `CodexResumeTimeoutState` only drives messages and is not reset on Stop (documented in `AgentModeViewModel+Types.swift`).
- **Controller.** `startOrResume` calls `Task.checkCancellation()` after the resume response, after the start response, and as the first statement of the `eventHandlingMutex` apply block. The catch cancels binding through `cancelBindingSessionIgnoringTaskCancellation`. That helper runs on an unstructured task because `AsyncMutex` throws for a cancelled contended waiter. `disableThreadMemoryMode` and `disableThreadMemoryModeForeground` rethrow `CancellationError` without a foreground or background retry.
- **DEBUG hooks.** `test_readySessionToolTrackingRequestCount(tabID:)` on the coordinator. On the controller: `test_backgroundMemoryModeRetryObserver` (when set, it short-circuits the detached retry and records the thread ID), `test_isBindingSession`, and `test_bufferedInboundCount`.
- **Tests.** In `AgentModeRunServiceLifecycleTests`:
  - Deliberate contract replacement (rename): `testCodexRepeatedResumeTimeoutFallsBackToFreshStartForSavedThreadID` -> `testCodexRepeatedResumeTimeoutKeepsSavedThreadAndResumesSameThreadOnRetry`.
  - New: `testCodexResumeCancelledByStopShowsNoFailureItem`, `testCodexResumeFailureBeforeStopStaysVisible` (timeout and frame-limit rows), and `testCodexResumeLateSuccessAfterCancelIsDiscarded`.
  - Strengthened guidance assertions in the frame-limit and system-error tests.
  - New `LifecycleResumeGate`: first settlement wins, with optional cancellation honoring.
  - `testCodexRolloutWithoutThreadIDCannotUseRepeatedTimeoutFreshStartFallback` keeps its ID, but its ledger oracle now describes stale timeout state.
  - In `CodexNativeResumeLifecycleTests`, new: `testCancellationBeforeApplyThrowsCancellationAndCancelsBinding` (after resume response, after start response, before apply) and `testMemoryModeCancellationIsRethrownWithoutRetryWhileFailureStillDegrades`.
  - Ledger rows were updated surgically, and the root scenario total rose from 37,587 to 37,600 (lifecycle 173 -> 181 across 124 -> 127 rows; controller suite 58 -> 63 across 25 -> 27 rows).
- **Validation (synthetic only, no real user turn or visible app lifecycle).**
  - Controller suite: 27/27 (`63273427-5b9b-49b5-b48c-9476797e78a1`).
  - Lifecycle suite: the first run passed 126/127. The unchanged ACP prompt-write acknowledgement test hit its 0.5 s readiness timeout (`5bfdf408-85f1-4d08-bb4c-9a362d83adae`); this is the same test as the Phase 2 record. The rerun passed 127/127 (`c18cf58b-b042-45f1-94a8-b73e75133f7e`), and so did the run after the final test edit (`96232ad7-9a76-4ec0-b81e-7e321923f6d7`).
  - Adjacent Codex suites (goal config/memory-mode retry, event recovery, liveness, hidden-tool boundary, fallback FIFO): 125/125 (`75e8bcf6-2367-46db-8b40-ac0a860072b8`).
  - No dedicated coordinator auth-recovery or missing-rollout suite exists. Their contracts run inside the lifecycle suite.
  - Build passed (`6106ca15-a6eb-44f3-93b9-44f1cba6b470`). Lint passed (`279aa51e-a616-4ddd-985d-b094db083acf`) after removing one redundant `throws`.
  - `verify-ledger` reconciles every Phase 3 ID. It still reports the pre-existing missing Pair-guidance row from `9d48a9e8`.
- **Notes for review.**
  - The pre-existing auth `.recovered` invalidation used `preserveRunID: false`; the R2 remediation record below fixes it.
  - Start-path timeouts show no guidance.
  - The retained rollout-integrity test name mentions the removed fallback.

## Phase 3 initial-review remediation record (2026-10-04; subsequent R1–R3 outcomes below)

Inputs: the OracleA initial review (CR3-01 P1, CR3-02 P2, and the auth-recovery acceptance gap) and the OracleB initial review against snapshot 2026-10-04/2137 (B3-01 to B3-09). Severities are left to re-review. C3-xx and PH3-xx labels came from reconstructed review deliveries that are not review authority, so the items that cited them are recorded below as independent code observations.

- **Captured run ownership (CR3-01, B3-03).**
  - `ensureCodexNativeSession` captures `CodexStartAttemptIdentity` (run attempt and run ID) before its first suspension.
  - `codexStartAttemptOwnsSessionState` gates every timeout-count change, controller invalidation, reconnect mark and managed-auth recovery. That covers the failure handler, the cancellation discard and both auth branches. It holds while no other attempt or run ID is active and the slot is empty or still holds the attempt's controller.
  - A superseded attempt still appends its own genuine error item.
  - A late success is applied only while `codexControllerSlotHolds` the attempt's exact controller, on both the normal and the recovered path.
  - `sendCodexNativeMessage` captures `sendRunOwnership` at entry. After ensure, `codexSendIsSupersededBySuccessor` returns `.stale` without touching reconnect, auth-retry, terminal or dispatch state. It fires when another attempt owns the tab, or when the send's task was cancelled with no attempt active and a later run has already installed a controller.
  - `CodexIntegratedAgentModeRunner` leaves `agentTask` and the pending-handoff outcome alone once superseded.
- **Real-client cancellation ordering (B3-01).** The cancellation handler in `CodexAppServerClient.request` marks a per-request `RequestCancellationMarker` synchronously. A failure that settles the request after that point settles as `CancellationError`: transport invalidation, an error response, a timeout, or an explicit fail. Earlier failures and success responses are unchanged.
- **Stop before the fallback or the start (independent code observation, not an Oracle finding).** `startCodexNativeSession` checks cancellation before the missing-rollout fallback. `startOrResume` checks it before any process, binding or RPC work.
- **Turn listing after Stop (B3-05).** `startOrResume` checks cancellation after `reconcileResumedSnapshot`.
- **Contended binding cleanup (CR3-02).** No behavior change. New DEBUG hooks: `test_bindingCleanupObserver`, `test_holdEventHandlingMutex`, `test_eventHandlingMutexWaiterCount` (backed by `AsyncMutex.test_waiterCount`), and the `testCodexAuthRecovery` injection on `AgentModeViewModel`.
- **New tests.** In `AgentModeRunServiceLifecycleTests`:
  - `testCodexStoppedResumeSettlingDuringSuccessorStartupLeavesSuccessorUntouched`: 6 rows. Cancellation, late success, timeout and auth error against a starting successor; late success against a ready successor and against a finished one.
  - `testCodexManagedAuthRecoveryDuringResumeHonorsStopAndDiscardsLateSuccess`: 5 rows. Stop during a refresh that recovers, and during one that needs login; Stop cancelling the recovered resume, and the recovered resume succeeding after Stop; an uncancelled contrast.
  - `testCodexResumeTaskCancelledWithoutStopInvalidatesItsOwnController`: 2 rows. Send-created attempt, and joined attempt; the joined row restores attachments and does not terminalize.
  - `testCodexMissingRolloutSettledBeforeStopDoesNotStartFreshThread`: 2 rows.

  In `CodexNativeResumeLifecycleTests`:
  - `testCancelledStartupCancelsBindingAfterWaitingForContendedEventMutex`: 2 rows.
  - `testStopDuringRealResumeRequestSettlesAsCancellationBeforeShutdownCanFailIt`: 2 rows × 10 iterations, over the real client.
  - `testCancelledStartOrResumeEntryMakesNoRequestOrBinding`: 3 rows.
  - `testStopDuringStartupTurnListingSendsNoMemoryModeRequest`: 2 rows.

  Changed: `testCodexResumeFailureBeforeStopStaysVisible` now seeds the count, so the timeout row goes from 0 to 1 and the frame row from 1 to 0.
- **Ledger.** The root scenario total went from 37,600 to 37,624. Lifecycle: 181 -> 196 across 127 -> 131 rows. Controller suite: 63 -> 72 across 27 -> 31 rows. `verify-ledger` reports only the pre-existing missing Pair-guidance row.
- **Validation (synthetic only).** In run order:
  - `aff8d3f0-…`: the lifecycle suite passed 130/131. The unchanged ACP prompt-write acknowledgement test hit its 0.5 s readiness timeout, the same flake as in the earlier records. The xctest process then died of SIGPIPE in the new real-client test, because the debug transport had no stdin reader. The test now injects a no-op frame writer.
  - `b4e306f1-…`: the real-client Stop row failed in 1 of 10 iterations with `processNotRunning`, reproducing B3-01 before the client fix.
  - `cbf36fc5-…`: 302/302 across the focused Codex suites after the fix.
  - Mutation run `8110ab8a-…`: 162 tests with 20 failures, confined to the six targeted tests. The six mutants were: plain `try? withLock` cleanup; a discard that never invalidates; a send fence that is always false; and each of the three new cancellation checks removed. Mutation run `c475537a-…`: always terminalizing a cancelled joined send failed the joined row (4 assertions).
  - `7dc66ab2-…`: 302/302 on the restored sources. `f80d2cf3-…`: the joined-attempt row passed.
  - Build: `89ae4c43-…`.
  - Lint `0f93b3e5-…` first failed with two `redundantThrows` and one `preferCountWhere` in the new tests, plus cascaded `indent`/`trailingSpace` reports in an unchanged raw-string literal. After the fix, lint passed (`c7d56b8e-…`). It passed again (`0255d442-…`) after one optional-interpolation warning in the new successor test was fixed.
  - `make dev-test-parallel` (589 suites and 6,331 tests per run):
    - `4c5cbc4e-…`: every test passed after five first-attempt retries, but the integrity check failed (`source dirty digest`) because this record was edited during the run. Result discarded.
    - `c2de3433-…`: failed. `AgentRunMCPToolServiceWaitTests/testOMPQualificationAuthorizationUsesSingleAbsoluteDeadline` failed on both attempts. It passed in isolation (`ef1e0240-…`, 52/52), and it also failed a first attempt in a parallel run on 2026-10-03, before Phase 3. Four other suites passed on retry.
    - `7a831fa7-…`: passed with 0 failures after three first-attempt retries, all passing on retry:
      - the lifecycle suite: the ACP prompt-write flake and `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization`;
      - the OMP smoke-script suite timed out;
      - `WorkspaceFileContextStoreTests`.

      The Codex suites passed on their first attempt.
- **Open for review (not changed here).**
  - Auth `.recovered`: fixed in the R2 remediation record below. The recovered replacement now keeps the run ID, and the contrast row asserts the dispatch.
  - Independent code observation (transport-closed recovery): the transport-closed fallback task's recovery calls `invalidateCodexControllerForReconnect`, which cancels that same task. This is present at HEAD. With Phase 3 the cancelled recovery resume is quiet, and the run fails with the generic recovery message. This is from code trace only and needs a design decision.
  - Independent code observation (fallback-start classification): a failed fresh start after a missing-rollout fallback is still classified as a resume failure, for both guidance and count.
  - B3-07: the frame-limit guidance omits that the saved thread was kept, and takes its size from `Config.maxInboundFrameBytes` rather than the error's limit.
  - B3-08: the retained `…CannotUseRepeatedTimeoutFreshStartFallback` name and its `repeated_timeout_fallback` ledger tag are unchanged.
  - B3-09: Stop waits behind a contended event mutex during binding cleanup, and a background memory-mode retry scheduled before a late cancellation can still send.
  - B3-02: unchanged. Ensure creates the controller before capturing it, and `startCodexNativeSession` never creates one.

## Phase 3 R1 remediation record (2026-10-05; OracleA R2 closed CR3-01)

Input: OracleA R1 kept CR3-01 open. A successor that ran and was then stopped before the stopped attempt's outcome arrived leaves no run attempt, run ID or controller behind. So `codexStartAttemptOwnsSessionState` and `codexSendIsSupersededBySuccessor` both treated the stale attempt as current, and it could change the timeout count, mark reconnect, re-enter auth and send cleanup, and return a non-stale outcome. OracleB's R1 nonblocking findings are not part of this remediation.

- **Run-attempt generation.** No existing session field survives terminal teardown at attempt granularity: `lastObservedRunID` tracks runs and is unset at send entry for a fresh run. So `TabSession.runAttemptGeneration` (`UInt64`) increments in `beginRunAttempt` and is never cleared. Three boundaries compare it:
  - `CodexStartAttemptIdentity` captures it, and `codexStartAttemptOwnsSessionState` rejects a changed generation before its ownership, run-ID and slot checks.
  - `sendCodexNativeMessage` captures it at entry next to `sendRunOwnership`, and `codexSendIsSupersededBySuccessor` treats a changed generation as superseded, so the send returns `.stale`.
  - `CodexIntegratedAgentModeRunner` captures it after taking ownership, and `isSupersededBySuccessor` treats a changed generation as superseded. The stale run wrapper therefore leaves `agentTask` and the pending-handoff outcome alone.
- **"A stopped, no successor" is unchanged.** The generation stays the same, so a genuine first-settled failure still advances or resets the count and fails the run (`testCodexResumeFailureBeforeStopStaysVisible`, not modified). `cancelRun` begins a synthetic attempt only when the run is not already terminal-committed, so a repeated Stop does not bump the generation.
- **Tests.** `testCodexStoppedResumeSettlingDuringSuccessorStartupLeavesSuccessorUntouched` grows from 6 to 12 rows. The new rows stop the successor before the stopped attempt's outcome is delivered:
  - while the successor is starting: cancellation, late success, timeout, and auth error;
  - after it has dispatched: timeout, and late success.

  The stopped rows assert that no controller, run attempt or run ID remains. They then set reconnect to false and the auth-retry turn to a probe value, because the successor's own Stop already marked reconnect. Every row now asserts that the task handle is unchanged (a stand-in handle when none remains) and that no handoff outcome is recorded. The error rows also assert exactly one error item. Ledger: 6 -> 12 scenarios; the root total goes from 37,624 to 37,630.
- **Validation (synthetic only).**
  - Red before the source change, `d966b9bc-…`: 8 failures. The six stopped rows returned `.cancelled` or `.failed` instead of `.stale`, and the finished row lost its task handle and recorded a handoff outcome.
  - Focused Codex suites, `fbbf3f62-…`: 300/302. The extended successor test and the no-successor test passed. The two failures were the ACP prompt-write flake and `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization` (OMP on the ACP path; it also failed first attempts in earlier parallel runs). Lifecycle reruns: `4698003f-…` 130/131 (ACP flake only) and `1a12f95c-…` 131/131.
  - Boundary mutants, each restored afterwards:
    - M9, ownership helper (`9139978b-…`): 7 failures (timeout state ×3, reconnect ×3, visible error ×1);
    - M10, send fence (`a44c666b-…`): 6 outcome failures;
    - M11, run wrapper (`558e84a7-…`): 14 failures (task handle and handoff outcome in the finished row and the six stopped rows).
  - Lint `a7647723-…` and build `f68a0163-…` passed.
  - `make dev-test-parallel`, 589 suites and 6,331 tests per run:
    - `15a2532b-…`: failed. `AgentRunMCPToolServiceWaitTests/testOMPQualificationAuthorizationUsesSingleAbsoluteDeadline` failed both attempts, as in `c2de3433-…` before this change. It passed in isolation (`59877ed4-…`, 52/52).
    - `9ddbed7c-…`: passed with 0 failures after five first-attempt retries, all passing on retry: the lifecycle suite (ACP flake), the same OMP deadline test, `MCPCodeStructureWorktreeTests`, `OMPAgentModeSmokeScriptTests`, and `RemoteAgentSessionTests`. Every Codex suite passed on its first attempt.

## Phase 3 R2 remediation record (2026-10-05; both R3 lanes closed R1-01)

Input: OracleB R2 escalated its Phase 3 R1-01 to P1. That numbering is OracleB's Phase 3 series, separate from the Phase 1–2 R1-01 above. When managed auth had expired during a cold resume and the refresh succeeded, the `"managed-auth-recovery-during-start"` invalidation cleared `session.runID`. The recovered resume was applied, but `sendCodexNativeMessage` then failed the run with "Codex native send failed: run not ready" and dispatched nothing.

- **Fix.** That invalidation now passes `preserveRunID: true`, as `attemptCodexRecovery` already does for its in-run replacement.
  - The replacement serves the same run: `prepareCodexController()` builds it and its event listener under the captured run ID.
  - The ownership check just before the invalidation has confirmed that the session's run ID is the attempt's.
  - Preserving keeps only what is already there, so a Stop that has cleared the run ID leaves it cleared.
  - `preserveExistingRunID` is unchanged and stays `false` for ordinary sends.
- **Unchanged paths.**
  - Stop during the refresh still discards before the invalidation.
  - A cancelled or late-succeeding recovered resume still goes through `discardCancelledCodexNativeSessionStart`, and Stop's own teardown clears the run ID.
  - The successor rows still assert that the refresh never runs.
- **Tests.** The contrast row of `testCodexManagedAuthRecoveryDuringResumeHonorsStopAndDiscardsLateSuccess` now asserts a `.sent` outcome, `recoveredController.sentTexts == ["resume"]`, and no error item. The ledger row's tags, oracle, failure risk and notes are updated. Its scenario count (5) and the root total are unchanged.
- **Validation (synthetic only).**
  - Red with the fix reverted, `307e3ff2-…`: 3 failures, all in the contrast row:
    - the outcome was `.failed("Codex native send failed: run not ready")`;
    - `sentTexts` was empty;
    - the "run not ready" error item appeared.

    The fix was restored and hash-checked, and no mutant markers remain.
  - Focused Codex suites, `fd60c29a-…`: 301/302. The auth-recovery, successor and no-successor tests passed. The one failure was `testACPDelegatedQuestionStageIsAcknowledgedAtThePromptWriteNotAtTurnCompletion` (the ACP prompt-write test). An earlier lifecycle-only run, `0c2fe622-…` (its filter was not quoted), had the same single failure.
  - Lint `32872fc0-…` and build `baf26962-…` passed.
  - `make dev-test-parallel`, `752f0ce5-…` (589 suites, 6,331 tests): **failed**.
    - The lifecycle suite's only test failure, on both attempts, was the ACP prompt-write test hitting its 0.5 s timeout. The harness classified both attempts as `CRASH`: each process exited 1 after printing a complete 131-test summary, with `timed_out: false`. `parallel_xctest_runner.py` labels any nonzero exit `CRASH`, even with a summary; these records do not establish a signal crash.
    - Four other suites passed on retry: `MCPAskOracleWorktreeTests`, `MCPCodeStructureWorktreeTests` and `OMPAgentModeSmokeScriptTests` after timeouts, and `WorkspaceCodemapLocalGitClassificationTests` after a crash.
  - Follow-up checks on the ACP test, with the fix in place:
    - a lifecycle-suite rerun, `ea9d2a2f-…`, had the same single failure;
    - run alone, the test failed once (`0a06e7d7-…`) and passed once (`a36824f6-…`), with a machine load average of about 8 to 11.

    Its body is unchanged from HEAD, and it doesn't use the Codex start path.
  - Main's lifecycle rerun `b66d2d86-4291-45ae-baa0-90f49d49d04e` failed two methods (four assertions): ACP prompt-write readiness and `testPreDeniedOhMyPiReceiptPreventsBootstrapAfterGateAuthorization`. All Codex cases passed. The OMP test also failed before the auth fix in `fbbf3f62-9a27-4f9e-854c-9feb2044f1ef`, and passed alone on final source in `b0cf2430-b521-4116-bd48-57754c7744c4` (1/1). This bounds attribution but does not establish the cause of the ACP/OMP instability.
  - Final unchanged-source `make dev-test-parallel`, `370f0ed5-102b-4878-a58e-2bd6cf481eb9`: **passed 6,331/6,331 tests across 589/589 suites, zero final failures, with six suite retries**. The lifecycle, MCP agent wait, git worktree creation receipt, MCP code-structure worktree, OMP smoke-script, and remote-session suites all passed on their second attempt. This is a pass under the runner's retry policy, not a clean first attempt. No source or documentation edits were made during this run.
- **Open, not changed here.**
  - OracleB R2 retained:
    - R1-02 (P2): during a Stop of event-task recovery, an unmarked settlement still adds a failure item;
    - R1-03's `items.last` heuristic (P3);
    - R1-04 (P3).
  - OracleB R2 raised:
    - N2-01 (P3): the generation also counts attempts that are not real successors;
    - N2-02 (P3): three copies of the superseded check.
  - B3-07, B3-08 and B3-09 remain as listed above.

## Phase 3 final review and acceptance record (2026-10-05)

- Only OracleA and OracleB performed code review. Every re-review used a fresh lane scoped to prior findings and their evidence. R1's patch-file slice did not package the raw delta; R2 and R3 embedded the actual delta directly, resolving that review-material omission. Preset identities were verified on delivery.
- OracleA explicitly closed CR3-01 in R2 (local evidence identifier: `oracle-review-2026-10-05-091333-phase-3-r2-oraclea-2-9baa.md`). In R3, chat `phase-3-r3-oraclea-55AA59`, it closed R1-01 and retained closure of CR3-01/CR3-02, with no fix-induced P0/P1 regression.
- OracleB R3, chat `phase-3-r3-oracleb-3F4CC2`, explicitly closed R1-01 and accepted the code, retaining the earlier closures and nonblocking findings above. Neither lane has an open P0/P1. Review acceptance is not live reliability acceptance.
- Both R3 reviews saw the failed final-source full-root attempt. The subsequent passing run `370f0ed5-102b-4878-a58e-2bd6cf481eb9` supplies that missing evidence without further code changes. The OMP attribution and harness classification requested by OracleB are recorded above.
- Nonblocking R3 notes remain follow-ups, not another review loop: ownership permits an already-nil run ID; the `run_id_preserved` test tag is inferred through dispatch; real-error failure after recovered resume and the in-run auth-recovery variant lack dedicated new coverage.
- The existing unrelated ledger omission remains: `root/RepoPromptTests.AgentDelegationPolicyTests/testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders`. No ledger regeneration or unrelated test change was made.
- No real user turn or visible app lifecycle was exercised. §7.3 requires owner-approved, fingerprinted packaged-app verification before claiming end-to-end cold-resume reliability.

The sections below retain the phased contract with implementation clarifications; code review is complete, while full live reliability acceptance remains pending.
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
