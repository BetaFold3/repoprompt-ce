# Bounded RepoPrompt MCP delegation

Scope: read when the task touches RepoPrompt MCP delegation depth, `agent_run` / `agent_manage` / `agent_explore` admission or advertisement for Agent Mode runs, delegation lineage, fork_session parent placement, role prompt delegation guidance, or delegated child `ask_user` routing to a parent agent.
Authority: Authoritative
Last-verified: 2026-10-02

## Contract

- Delegation depth is main (depth 0) → worker (depth 1) → sub-worker (depth 2), then stop.
- Non-explore sessions at depths 0 and 1 may delegate. Explicit-model (nil-role) sessions use `agent_run` + `agent_manage`; named engineer, pair, and design roles use `agent_run` + `agent_manage` + `agent_explore`.
- Depth ≥ 2 sessions, explore sessions at any depth, and sessions whose lineage is missing, cyclic, or inconsistent are delegation leaves with none of the three tools.
- External MCP clients without an Agent Mode source tab keep their existing surface. An Agent Mode connection whose source tab cannot be resolved is rejected rather than treated as external.
- Native Codex `spawn_agent` delegation is out of scope.

## Lineage

- Depth is derived on demand from the existing `parentSessionID` chain and is never persisted. `AgentDelegationPolicy` (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentDelegationPolicy.swift`) holds the pure rules; `AgentModeViewModel` supplies the live and index lookups.
- A session's parent is reconciled across every claim for its durable identity: each live record bound to it and its owner-validated session-index entry. The caller resolved from its run-scoped tab is one of those records.
  - A live record with a parent claims that parent. A hydrated live record without a parent claims root. An unhydrated live record without a parent makes no claim, because its persisted parent may not have loaded yet.
  - An index entry claims its recorded parent, or root when it records none.
  - Two different non-nil parents are inconsistent. A non-nil parent outranks a root claim (the deeper, more restrictive reading), so compatible parentless duplicates stay roots while a parentless duplicate cannot shorten a nested lineage.
  - With no claim the parent is unknown, so an unhydrated persisted identity without an index entry fails closed instead of reading as a root.
- A hydrated live session without a durable identity or parent is a genuinely new root, so ordinary UI sessions stay at depth 0 even without an MCP control context.

## Enforcement

- Every Agent Mode run lease resolves `AgentDelegationPolicy.RunToolPolicy` when it is prepared. This covers `AgentModeRunService` and the Codex coordinator at transport start. Leaf runs union all three delegation tools into `restrictedTools`. Restrictions are checked before advertisement and execution, so they both hide and deny. Eligible runs set the advertisement-only `allowsAgentExternalControlTools` flag.
- Handlers re-check lineage on each call. These handlers are `agent_run` start and steer; `agent_manage` create_session, resume_session, and fork_session; and `agent_explore` start, via `mcpValidateAgentRunSpawnAllowed`. The explore caller also still requires a named non-explore role.
- Admission (`mcpValidateAgentRunSpawnAllowed`) returns the routed caller's durable identity, frozen synchronously with admission. An admitted caller without one is a genuinely new hydrated root, so admission binds its identity. External callers return nil and stay unbound.
  - After the spawn parent is resolved across an await, `mcpRequireAdmittedSpawnParent` requires that parent to equal the admitted identity, so a replacement session in the same tab is never credited with the request.
- Admission is repeated synchronously at the mutation or dispatch boundary (`mcpRevalidateDelegationCommit`) after the request may have suspended. The routed caller tab must still hold the admitted identity, still be eligible, and still satisfy the target ceiling.
  - `mcpResolveOrCreateSessionTarget` and `prepareHandoffHeadless` take a `delegationCommitCheck` that runs immediately before the spawn parent is recorded. Created tabs are discarded on failure.
  - Steer re-checks immediately before dispatch. Fork also recomputes the destination parent.
- A routed `agent_run` start or `agent_manage` create_session whose parent session cannot be resolved is rejected instead of creating an unparented root.
- Recording a parent on a live record that has none is checked against the parent its identity already reconciles to:
  - Restoring that same reconciled parent (for example an indexed parent not yet on the live record) changes no depth and is allowed.
  - A different or conflicting parent fails closed.
  - A genuine root adoption is rejected when the session already has delegated children (a live record or index entry naming it as parent). Adoption would shift its existing subtree deeper while running descendants keep their leased policy, so resume, explicit-tab start, and similar paths reject it.
- Main and external callers keep their existing session-addressed behavior. A worker may target only sessions strictly deeper than itself (`mcpValidateDelegationTarget`), never itself, an ancestor, a sibling, or another root. This depth ceiling is not an ownership check.
  - It applies to resume, steer, and explicit-tab start, and to session-addressed control: `agent_run` cancel and respond, and `agent_manage` stop_session and get_log.
  - `agent_run` control admission (`mcpAdmitDelegationControl`) also requires the caller to be eligible.
  - Cancel carries the frozen caller identity to its mutation boundary, then re-admits the caller (identity, eligibility, target ceiling) immediately before `cancelAgentRun(target:)`.
  - For cleanup_sessions, IDs outside the ceiling are skipped as `outside_delegation_scope`.
  - These control paths also reject an Agent Mode connection whose source tab cannot be routed. Existing session-access authorization is unchanged.
- `fork_session` places the destination before publication through `prepareHandoffHeadless(delegationParentSessionID:)`. The destination keeps the source's parent unless the requesting agent's child would be deeper. It is never deeper than depth 2, and a worker can never mint a new root. UI handoffs pass no parent and stay parentless.

## Prompt audience

`SystemPromptService.agentModePrompt(delegationAudience:)` receives the run policy's audience from the generic, ACP, and headless path (the view-model message builder), and from the Claude and Codex coordinators:

| Audience | Delegation copy |
|---|---|
| `.agentRunOnly` | nil-role `agent_run` guidance |
| `.both` | `agent_run` / `agent_manage` / `agent_explore` with the depth note |
| `.none` | no delegation tools, export handoff, or dispatch guidance |

- A shared Pair-worker preference for delegating Oracle review/re-review remediation (`AgentModePrompts.Fragments.pairReviewRemediationGuidance`) renders only for `.agentRunOnly` and `.both` audiences, in both the nil-role coding prompt and named-role prompts. `.none` and `.agentExploreOnly` omit it.
- The Pair role description in `AgentModelCatalog.taskLabels` and the `agent_run` tool description carry the same preference.

A nil audience keeps the legacy role-derived copy for direct callers. Tool descriptions (`ask_oracle`, `oracle_send`, `context_builder`) and tool-result export blocks are capability-neutral: they never name a delegation tool and defer to the prompt.

## Delegated questions

A child's `ask_user` is addressed to whoever controls that child. `AgentDelegatedQuestionAudience` (`Sources/RepoPrompt/Features/AgentMode/Runtime/AgentDelegatedQuestionAudience.swift`) resolves the audience. It uses the same reconciled parent lookup (`mcpDelegationParentLookup`) and lineage that depth uses, so there is no second lineage reader. Design rationale and owner decisions: [delegated `ask_user` escalation plan](plans/2026-10-02-oracle-errors-and-delegated-ask-user-plan.md) §6.

| Asking session | Audience | Behavior |
|---|---|---|
| Not MCP-controlled | `.user` | Unchanged reveal and timeout. |
| MCP-controlled, reconciled `.parent` with resolvable lineage, and exactly one live local parent session | `.parentAgent` | No reveal. The timeout pauses and the notice goes to the parent. |
| MCP-controlled root whose controller connection is verified as non-Agent-Mode | `.externalController` | Unchanged. |
| Anything else: unknown or inconsistent lineage, an unverified root controller, or a missing, closed, or ambiguous parent | `.userFallback` | No reveal. The normal timeout runs and the child row shows a "Needs your answer" badge. |

- **External controller:** being an MCP-controlled root is never enough to count as external. `MCPAskUserToolProvider.verifiedControllerProvenance` checks the session's originating controller connection. That connection must be live, keep an unknown run purpose after run-context rehydration, and have no run mapping. Otherwise the provenance is unverified and the question falls back to the user. Provenance is bound to that connection ID, so it stops applying if the controller connection changes.
- **Escalation:** the parent either answers with `agent_run respond` or calls its own `ask_user`, which this same table routes. Escalation is therefore recursive, and there is no new tool or protocol.
- **Authority:** the child's `pendingAskUser` and its continuation stay the only authority for content, answers, and the timeout. `AgentModeViewModel+DelegatedQuestions.swift` keeps a runtime-only notice registry keyed by `(childSessionID, interactionID)`, holding the parent session, delivery run stamps, and an acknowledgement flag.
  - Reconcile runs synchronously on the main actor when a question is installed, answered, skipped, timed out, or cancelled. It also runs on `teardownMCPControl`, on session-list and MCP-control changes, and on relevant session binding updates.
  - Notice content is re-read from `pendingAskUser` at each delivery and never includes drafts. A notice that was not yet delivered is dropped when its question resolves.
- **Notice content:** the notice carries the child session name and ID, the interaction ID, and the questions with their context, options, and selection constraints. It uses the point-of-need guidance from the plan. The rendered text starts with a `[RepoPrompt runtime notice: delegated child question — not user input]` header.

Delivery depends on the parent's state:

| Parent state | Delivery |
|---|---|
| Blocked in `agent_run wait`/`wait_any` covering the child | Unchanged actionable snapshot. The result handoff acknowledges the notice without duplicating it (`AgentRunMCPToolService.coveredDelegatedQuestionNoticeKeys`, single snapshot or `snapshots` array). The stored `agent_run` summary keeps only the interaction identity, so the committing step also appends one persistence-only `.system` record per result (`AgentDelegatedQuestionNoticeWire.coveredRecordHeader`). It holds each covered question's complete content: title, context, questions, per-question context, selection constraints, and options. The returned result is unchanged, and no notice note is added. |
| Blocked in another bounded wait | `wakeAgentRunWaitersOwnedByActiveRun(reason: .delegatedQuestionPending)` wakes every `agent_run` and `ask_oracle` wait owned by the parent's active run. `agent_run` reports `interrupted_by_child_question`, not `interrupted_by_steering`. A multi-session wait arbitrates over its single post-wake snapshot collection: a child that is actionable or terminal in that set wins (`snapshot_ready`/`expired`), so the interrupt never carries an actionable snapshot. `ask_oracle` returns its usual pending result with pending reason `interrupted_by_child_question` and `_meta.wake_reason: "delegated_question"`. A wait that begins after the wake checks for deliverable notices when it starts. |
| Running but not waiting | `MCPServerViewModel.runTool` attaches pending notices under `delegated_question_notices` to the next successful result returned on the parent's run-scoped execution. Only allowlisted tools qualify (`AgentDelegatedQuestionNoticeWire.eligibleToolNames`). The original payload is preserved, and error or failed results are never annotated. `ToolOutputFormatter` renders the notice after the original output. Completion observers record the unannotated result; the final handoff records the committed notices as a labeled `.system` transcript note with exactly the returned notice text (see Delivery transaction). For a result that itself carries `delegated_question_notices` (a direct, non-connection call), `AgentToolResultPersistencePolicy` keeps the key with the tool result: it wraps a non-object summary as `{"summary": …, "delegated_question_notices": …}` and keeps a rendered `text` that differs from the raw payload. |
| Idle or finished | No automatic turn. When the parent's next turn starts from idle, for any reason, `startAgentRun` prepends the notices to that turn's first provider input as a `<repoprompt_runtime_notice kind="delegated_child_questions">` block. It does not stage notices while a run is active. The user's message item is not changed. The provider submission outcome of that exact stage stamps and acknowledges the notices. It also persists a labeled `.system` transcript note with the same text (header, child session ID, interaction ID). Every other outcome releases the staging (see Delivery transaction). |

- **Destination identity:** only a live parent's *active run attempt* receives notices. A tool captures `AgentDelegatedQuestionDeliveryTarget` (parent run ID plus `activeRunAttemptID`) when it starts executing (`mcpDelegatedQuestionDeliveryTarget`). An idle parent that keeps its process run ID (Claude) is never a destination and is never woken. A result for an earlier attempt that completes under a reused run ID never carries notices.
- **Delivery transaction:** cancellation or failure never consumes a notice.
  - Tool results: `runTool` *reserves* the notices it attaches for its captured target (`mcpReserveDelegatedQuestionNotices(target:)`). A reserved notice is not deliverable to any other result and is never staged into a turn input. The `tools/call` handler in `MCPConnectionManager` binds a task-local `MCPToolResultDeliveryTransaction` (`ServerNetworkManager.currentToolResultDelivery`), and `runTool` registers an unannotate/settle/abandon participant on it.
  - Completion observers: the handler passes them `delivery.unannotated(value)`, the result without the attached notices, so nothing reserved reaches the transcript before it is committed.
  - Final handoff: after the last suspending completion processing (the completion observers), the handler calls `delivery.settle(value, handOff: !Task.isCancelled)`, then formats and returns the settled value with no further suspension. Settle reaches `mcpSettleDelegatedQuestionNoticeReservation` on the main actor, which revalidates each notice: it must still be held by this reservation, its question must still be pending, and the captured attempt must still be current. Valid notices are stamped and acknowledged, and in the same main-actor step the attached ones are appended to the parent transcript as a labeled `.system` note with exactly the returned notice text. Committed covered questions get the persistence-only record instead. Every other notice is stripped from the returned value, released, and never recorded. A question resolved, a parent attempt replaced, or a reservation released while the handler is suspended in its observers is therefore never returned.
  - A cancelled handler strips and releases all of its notices, because the SDK still sends a cancelled handler's return value. The handler samples `handOff` before any participant suspends, so the main-actor settle step also rechecks the handler task's `Task.isCancelled` at its commit point. A cancellation that lands during the hop to the main actor therefore strips and releases instead of committing. Any other exit abandons the transaction through a `defer`, which also releases. The response and the transcript therefore carry exactly the committed notices. Settle and abandon close the transaction once, and a participant registered after close is abandoned immediately.
  - Callers with no bound transaction (direct, non-connection calls) commit immediately, recording committed covered questions the same way. Reconcile releases any reservation whose attempt is no longer current or whose questions all resolved.
  - Next-turn staging: `startAgentRun` captures the stage ID and passes it to `runService.startRun`. Runners report `Hooks.recordDelegatedQuestionNoticeSendOutcome(session, stageID, didSend)` at the actual provider submission:
    - Codex reports a send only on `.sent`; `.queuedFallback` releases the stage. Releasing any stage also removes exactly that stage's runtime block from the provider and draft text of every queued, unclaimed Codex fallback entry of the parent tab. The user's text, context, and attachments are unchanged. The notices therefore reach the parent only through a later delivery that acknowledges them. The runner reports the queued outcome right after enqueueing, before a dispatch can claim the entry.
    - Claude reports after its send outcome.
    - Headless reports once streaming starts.
    - ACP reports at the actual `session/prompt` write (`ACPAgentSessionController.prompt(onSubmitted:)`), and reports not-sent when no write happened. Turn completion does not count as the send.
  - An outcome for any other stage ID, such as a superseded start, is a no-op. `settleDelegatedQuestionTurnStageAfterRunStart` rolls the stage back when the start reported no send or left the run inactive. Reconcile rolls back a stage whose run stopped without reporting an outcome, or whose parent tab is gone.
- **Child-controlled text:** `AgentDelegatedQuestionNoticeWire.neutralizingRuntimeNoticeDelimiters` replaces the `<` of any `<repoprompt_runtime_notice` or `</repoprompt_runtime_notice` sequence in rendered notices (case-insensitive) with `‹`. The turn-input wrapper neutralizes its body again. Session names, titles, questions, and options therefore cannot close or open the wrapper.
- **Dedupe:** a notice is acknowledged only by a committed tool-result handoff or a confirmed send of its stage (plan §6.2). An acknowledged notice is never re-delivered to the same or a later run, or to a new attempt under a reused run ID. It is also not re-armed automatically if the parent's turn ends without answering (see Known limitations). Each parent run attempt is woken at most once per notice until a release re-arms it.
- **Answer races:** the existing first-wins paths decide. A user answer in the child tab after the parent's `respond`, or a `respond` after the user answered, is a no-op or is rejected ("No pending interaction found…" / "…no longer matches interaction_id"). `lastInteractionResolution.resolvedBy` records the winner (`user` or the MCP client attribution).
- **Timeout:** with a `.parentAgent` audience, no timeout starts and `timeoutStartedAt` is nil, so the child card shows "Waiting on parent agent" instead of a countdown. If reconcile later falls back to the user (parent closed, lineage invalid, or control torn down), a fresh generation-guarded timeout starts at that moment and honors the child's `timeout_seconds`. Fallback is one-directional: once a question falls back to the user, it never pauses again.
- **Visibility:** neither surface takes focus, and the parent's `runState` is unchanged.
  - The parent composer shows a banner with one row per pending child question. Its **Open** action selects the child tab after re-checking that the question is still pending, and never answers anything.
  - `AgentModeSidebarSessionBuilder` shows a sidebar badge, resolved by durable session ID so index-only rows work too. The parent row shows its pending child-question count. The child row shows "Waiting on parent agent" or "Needs your answer".
- **Unchanged:** the depth ceilings, `agent_run respond` authorization, and the `MCPAskUserToolProvider` reveal guard. `respond` still rejects an interaction ID that no longer matches. Delivery never starts a turn, steers, interrupts a native tool, restarts a provider, or bypasses an approval.

## Integration coverage

- `PersistentAgentModeMCPReadFileConnectionTests.testSubWorkerLeaseDeniesRawDelegationToolCallsOnRetainedSocketWhileReadFileSucceeds` covers socket-level enforcement:
  - It builds a live main → worker → pair sub-worker chain in the fixture window. It derives the sub-worker's policy with `AgentModeViewModel.mcpDelegationRunToolPolicy` and passes that policy to `MCPBootstrapLeaseSpec.agentMode`, mirroring `AgentModeRunService`.
  - It uses a real socketpair `BootstrapSocketConnectionManager` with expected-PID admission and run routing. `tools/list` omits all three delegation tools.
  - Raw `tools/call` for `agent_run` start, `agent_manage` create_session, and `agent_explore` start each return `isError` with `Tool '<name>' is disabled for this connection.`. None of these calls creates a session or tab, and `read_file` on the same connection still succeeds.
- Scope: this is an in-process SwiftPM fixture.
  - It does not invoke the `AgentModeRunService` or Codex coordinator call sites, and it launches no provider process.
  - It is not packaged-app or live-provider denial evidence.
  - Handler re-checks are covered separately by `AgentDelegationServiceBoundaryTests`.
- Delegated-question delivery transaction on the same socketpair fixture (`PersistentAgentModeMCPReadFileConnectionTests`, parent with an active run attempt):
  - Each success scenario suspends a real completion observer registered for the parent run (a cancellation-ignoring gate), so the handler is suspended inside its completion processing after `runTool` attached the notice. While suspended, the observed result carries no notice, and the notice is reserved, unacknowledged, and unrecorded.
  - `testDelegatedQuestionReadFileDeliveryCommitsAndRecordsAtFinalHandoffAfterCompletionObservers`: once released, the response carries the notice, the record is acknowledged when the response arrives, and the parent transcript holds exactly one notice note whose text equals the returned notice block.
  - `testDelegatedQuestionPostAttachCancellationReleasesAndNextReadDelivers` cancels the handler task from inside that observer. The response carries no notice, nothing is recorded, the notice stays unacknowledged, and the next read delivers and records it once.
  - `testDelegatedQuestionResolvedDuringCompletionObserversIsStrippedFromTheResult` resolves the question while the observer is suspended: no notice is returned or recorded.
  - `testDelegatedQuestionParentAttemptReplacedDuringCompletionObserversIsStrippedAndRedelivered` begins a new parent attempt under the same run ID while the observer is suspended: the stale result is stripped and released, and the next read (the new attempt) delivers it.
  - `testDelegatedQuestionReadFileErrorDoesNotReserveNotice` shows an error result never reserves.
  - Cancellation is driven by cancelling the handler task, not by a client cancellation notification.
  - Transaction exclusivity is covered in `MCPToolResultDeliveryTransactionTests`. View-model attempt binding, settlement, reservation, stage-scoped outcomes, staging release, steer-while-asking, and answer-race contracts are in `AgentModeViewModelDelegatedQuestionTests`. The same suite also covers three delivery boundaries:
    - A cancellation that lands after settlement was requested but before the main-actor commit (a gate participant registered ahead of the production participant).
    - Single and multi-snapshot covered-question records through canonical save and reload.
    - The caller-level Codex path: idle stage, then queued fallback, then claimed dispatch, with an intervening delivery or resolution in between.
  - Multi-wait final-set arbitration is in `AgentRunMCPToolServiceWaitTests`. `AgentModeRunServiceLifecycleTests` covers stage outcomes: ACP acknowledges at the prompt write and reports not-sent when the prompt is never written, and Codex acknowledges only after an actual send, never for a queued fallback. Late-registered `ask_oracle` wake scopes are in `MCPAskOracleLifecycleTests`.

## Known limitations

- `agent_run` poll, wait, wait_any, and poll_many, and `agent_manage` list_sessions, are status observation and are not depth-gated.
- The worker ceiling is depth-based: a worker may address a deeper session in another worker's subtree.
- Delegated-question routing needs the parent to be a live local session in the same window. Remote-host sessions and parents that are not live fall back to the user.
- Delegated-question tool-result commit happens at the handler's final handoff, not at confirmed client receipt. The handler does not suspend between settlement and returning the content, but the SDK writes after the handler returns. A transport write failure after that handoff (for example, connection loss) is not observed, so that notice counts as delivered. The same applies to a cancellation, or a question resolution, that lands after settlement but before the SDK writes: the committed result is still sent. Settlement revalidates on the main actor, so a reservation already released by reconcile is stripped, not committed. `agent_explore` results never carry notices.
- Once a notice is acknowledged, it is not re-delivered if the parent's turn ends without answering (plan §6.2: acknowledged at handoff, no automatic re-arm). The child's question stays pending with its timeout paused until the parent answers or escalates, or the parent route fails and the question falls back to the user. This is the current owner contract.
- Native provider subagents (Claude `Task`, Codex multi-agent) are not Agent Mode children and are out of scope (plan §1). MCP request metadata carries no native-subagent attribution. If a native subagent shared the parent's MCP connection and run, its eligible tool results could carry the parent's notices. Production Claude configuration disallows `Task`, and the Codex configuration sets `multiAgentEnabled: false` (`CodexNativeSessionController`), so this shared-connection premise has not been established.
- The persisted `.system` notes (delivered notices and covered-question records) are replayed to providers inside `<system>…</system>` history. Their exact manual on-screen rendering has only been checked in code (`AgentMessageBubble.systemBubble` renders the full text); it has not been checked visually.
