# Bounded RepoPrompt MCP delegation

Scope: read when the task touches RepoPrompt MCP delegation depth, `agent_run` / `agent_manage` / `agent_explore` admission or advertisement for Agent Mode runs, delegation lineage, fork_session parent placement, or role prompt delegation guidance.
Authority: Authoritative
Last-verified: 2026-10-01

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

A nil audience keeps the legacy role-derived copy for direct callers. Tool descriptions (`ask_oracle`, `oracle_send`, `context_builder`) and tool-result export blocks are capability-neutral: they never name a delegation tool and defer to the prompt.

## Integration coverage

- `PersistentAgentModeMCPReadFileConnectionTests.testSubWorkerLeaseDeniesRawDelegationToolCallsOnRetainedSocketWhileReadFileSucceeds` covers socket-level enforcement:
  - It builds a live main → worker → pair sub-worker chain in the fixture window. It derives the sub-worker's policy with `AgentModeViewModel.mcpDelegationRunToolPolicy` and passes that policy to `MCPBootstrapLeaseSpec.agentMode`, mirroring `AgentModeRunService`.
  - It uses a real socketpair `BootstrapSocketConnectionManager` with expected-PID admission and run routing. `tools/list` omits all three delegation tools.
  - Raw `tools/call` for `agent_run` start, `agent_manage` create_session, and `agent_explore` start each return `isError` with `Tool '<name>' is disabled for this connection.`. None of these calls creates a session or tab, and `read_file` on the same connection still succeeds.
- Scope: this is an in-process SwiftPM fixture.
  - It does not invoke the `AgentModeRunService` or Codex coordinator call sites, and it launches no provider process.
  - It is not packaged-app or live-provider denial evidence.
  - Handler re-checks are covered separately by `AgentDelegationServiceBoundaryTests`.

## Known limitations

- `agent_run` poll, wait, wait_any, and poll_many, and `agent_manage` list_sessions, are status observation and are not depth-gated.
- The worker ceiling is depth-based: a worker may address a deeper session in another worker's subtree.
