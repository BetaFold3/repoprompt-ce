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
| Blocked in `agent_run wait`/`wait_any` covering the child | Unchanged actionable snapshot. The result handoff acknowledges the notice without duplicating it (`AgentRunMCPToolService.coveredDelegatedQuestionNoticeKeys`). |
| Blocked in another bounded wait | `wakeAgentRunWaitersOwnedByActiveRun(reason: .delegatedQuestionPending)` wakes every `agent_run` and `ask_oracle` wait owned by the parent's active run. `agent_run` reports `interrupted_by_child_question`, not `interrupted_by_steering`. `ask_oracle` returns its usual pending result with pending reason `interrupted_by_child_question` and `_meta.wake_reason: "delegated_question"`. A wait that begins after the wake checks for deliverable notices when it starts. |
| Running but not waiting | `MCPServerViewModel.runTool` attaches pending notices under `delegated_question_notices` to the next successful result returned on the parent's run-scoped execution. Only allowlisted tools qualify (`AgentDelegatedQuestionNoticeWire.eligibleToolNames`). The original payload is preserved, and error or failed results are never annotated. `ToolOutputFormatter` renders the notice after the original output, and `AgentToolResultPersistencePolicy` persists it with the tool result. |
| Idle or finished | No automatic turn. When the parent's next turn starts for any reason, the notices are prepended to that turn's first provider input as a `<repoprompt_runtime_notice kind="delegated_child_questions">` block. The user's message item is not changed. A successful send stamps and acknowledges the notices and persists a labeled `.system` transcript note with the same text (header, child session ID, interaction ID). Every other outcome releases the staging (see Delivery transaction). |

- **Delivery transaction:** cancellation or failure never consumes a notice.
  - Tool results: `runTool` *reserves* the notices it attaches (`mcpReserveDelegatedQuestionNotices`). A reserved notice is not deliverable to any other result. The `tools/call` handler in `MCPConnectionManager` binds a task-local `MCPToolResultDeliveryTransaction` (`ServerNetworkManager.currentToolResultDelivery`). It finishes the transaction as delivered only on its uncancelled success return, its last point before the SDK transport, after completion observers. Every other exit finishes it as undelivered, through a `defer`. Delivered commits: the parent run is stamped and the notice acknowledged. Undelivered releases: the notice is deliverable again to the same run, which may be woken again. Callers with no bound transaction (direct, non-connection calls) commit immediately. Reconcile releases any reservation whose run is no longer active or whose questions all resolved.
  - Next-turn staging: `startAgentRun` captures the stage ID. After `runService.startRun` returns, `settleDelegatedQuestionTurnStageAfterRunStart` rolls the stage back when the start reported no send (stale, cancelled, or failed) or left the run inactive (refused before the provider). Otherwise the stage waits for the provider send outcome (`recordPendingHandoffSendOutcome`). Reconcile rolls back a stage whose run stopped without reporting one, or whose parent tab is gone.
- **Dedupe:** a notice is acknowledged only by a committed tool-result handoff or a confirmed send. Delivery is also stamped per `(childSessionID, interactionID, parentRunID)`, so a provider that reuses its process run ID across turns (Claude) never sees a notice twice. Each parent run is woken at most once per notice until a release re-arms it.
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
- Delegated-question delivery transaction on the same socketpair fixture (`PersistentAgentModeMCPReadFileConnectionTests`):
  - `testDelegatedQuestionReadFileDeliveryCommitsOnlyAfterCompletionObservers` commits only at the final handoff.
  - `testDelegatedQuestionPostAttachCancellationReleasesAndNextReadDelivers` shows a cancellation after attach releases the notice, and the next read delivers it.
  - `testDelegatedQuestionReadFileErrorDoesNotReserveNotice` shows an error result never reserves.
  - Cancellation is driven through the completion-observer hook, not a client cancellation notification.
  - View-model reservation, staging-release, and answer-race contracts are in `AgentModeViewModelDelegatedQuestionTests`.
  - Late-registered `ask_oracle` wake scopes are in `MCPAskOracleLifecycleTests`.

## Known limitations

- `agent_run` poll, wait, wait_any, and poll_many, and `agent_manage` list_sessions, are status observation and are not depth-gated.
- The worker ceiling is depth-based: a worker may address a deeper session in another worker's subtree.
- Delegated-question routing needs the parent to be a live local session in the same window. Remote-host sessions and parents that are not live fall back to the user.
- Delegated-question tool-result commit happens at the app's final SDK handoff, not at confirmed client receipt. A transport write failure after that handoff (for example, connection loss) is not observed, so that notice counts as delivered. Commit and release settle asynchronously on the main actor. A reconcile release racing a late commit can cause at most one duplicate delivery, never a lost notice. `agent_explore` results never carry notices.
- The persisted `.system` note is replayed to providers inside `<system>…</system>` history. Its exact manual on-screen rendering has only been checked in code (`AgentMessageBubble.systemBubble` renders the full text); it has not been checked visually.
