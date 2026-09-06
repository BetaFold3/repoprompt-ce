# Codex conversation branching

Scope: read when the task touches Codex Agent Mode conversation branching, native turn checkpoints, branch creation or switching, branch lineage and tree projection, branch UI, exact resume, or branch-aware Oracle ownership.
Authority: Authoritative
Last-verified: 2026-09-06

## Shipped v1 contract

Conversation branching is complete for local, top-level, user-owned Codex Agent Mode sessions. It restores Codex native context through a completed turn while preserving the original conversation path. Branching is not handoff: it creates a durable native Codex fork and a separate persisted `AgentSession`, then opens that branch in the same compose tab without sending a message.

A turn is branchable only when the session is idle and locally controlled, the persisted checkpoint ledger matches the active Codex thread, and the selected fully retained turn has a completed checkpoint, a sealed side-effect classification, and a stored final assistant conclusion. Remote, MCP-originated, child-agent, worktree-bound, non-Codex, pending-handoff, active-Oracle, terminal-settle, and other non-idle states are unavailable. Existing sessions receive no checkpoint backfill.

## Checkpoints, fork, and persistence

- `CodexTurnCheckpointLedger` is session metadata keyed by stable CE user-turn IDs and bound to one Codex thread ID. Accepted native starts record the Codex turn ID; final settlement seals status and side effect as read-only, modified paths, or unknown. Thread replacement invalidates mismatched ledger authority, and persistence prunes entries not represented by retained transcript turns.
- Branch creation uses the live bound idle Codex controller and `thread/fork` with the source thread, the selected `lastTurnId`, `excludeTurns: true`, and a durable child. It does not mutate the controller's source binding.
- Before the fork, CE exhaustively reads the source turn manifest and validates the checkpoint sequence. Afterward it exhaustively validates the child prefix and rereads the source to prove it is unchanged. Invalid or incomplete pagination, duplicate turns, an invalid child identity, or a structural mismatch fails the operation. A known unsaved child is archived best-effort after failure.
- Fork submission is attempted once. Cancellation or transport/decode failure after enqueue is an ambiguous outcome and is never automatically retried because retrying could create another child.
- The child transcript is an exact prefix through the selected completed turn. It preserves retained turn/span/row identity and the sequence high-water mark, filters omitted tool-result payloads and token usage, recomputes persistence projections, and never splits a turn.
- Each branch is a new session file with a new session ID and `AgentSessionBranchOrigin`. Only branches carry lineage: root ID, source session and CE/Codex turn IDs, one-based source-turn ordinal, and creation date. The original session is not annotated or rewritten by branching beyond the ordinary pre-operation save.
- Session serialization remains version 7 because the checkpoint and lineage keys are additive and optional. Metadata index schema remains compatible and projects branch root, ordinal, and creation date without loading full sessions.

## Tree, switching, and exact resume

The authoritative tree is the root session plus every session whose `branchOrigin.rootSessionID` names that root. The metadata index provides the tree projection; unreadable, quarantined, missing, or otherwise incomplete index evidence fails closed. Deleting the root does not cascade to branches, and a surviving branch presents the missing root as `Original (deleted)`.

Switching is allowed only between persisted local Codex sessions in the same tree. It saves the current path, shuts down its controller, reserves a non-stealing target binding, restores the target into the same compose tab, preserves the draft, and sends nothing. A branch already open or reserved in another tab cannot be switched into.

Every branch child and every root known to have branches requires exact native resume before its next send. CE must resume the stored Codex conversation/rollout with missing-rollout and resume-timeout fallback disabled. If exact resume cannot be proven, CE preserves the unsent composer content, sends nothing, and reports that the conversation could not be reopened. Unavailable tree evidence also requires exact resume; it never authorizes a fresh-thread fallback.

Branch creation and switching pin session identity, binding generation, persistence/transcript generations, source thread, idle state, and operation ownership across every suspension point. While an operation is active, send, steer, handoff, session load, conflicting lifecycle work, and MCP entry points cannot take ownership.

## Oracle ownership

Oracle chats remain owned by the exact `AgentSession` that created them; tree membership does not grant shared continuation authority. Copied transcript results remain visible in a branch. When the caller is a branch, continuing a chat owned by another path is rejected with branch-specific guidance to start a new Oracle chat; other owner mismatches keep the generic owner-rejection copy. New chats belong to the branch that creates them. Branching is blocked while an Oracle request owned by the source session is active.

## v1 UI surfaces

- Completed assistant conclusion rows expose **Branch from here…**. Disabled controls explain unsupported local state, missing native checkpoints, compaction, or pending work.
- The confirmation sheet states the retained and omitted turn counts, classifies omitted work as read-only, changed paths, or unknown, warns that disk/Git/workspace state is not rolled back, and discloses source-owned Oracle chats. Mutating or unknown suffixes require **Branch anyway**. Submission shows **Branching…** and cannot be cancelled after it starts.
- When the projected tree has more than one member, the title bar exposes a **Conversation Branches** menu. Projection always includes the original slot, so a sole surviving branch whose root was deleted still shows the menu with **Original (deleted)** plus the child. It lists **Original** first, then branches by source-turn ordinal and creation date, checks the active path, and disables deleted or elsewhere-open targets with explanatory help; pending operation state disables other paths with **Finish the pending operation before switching branches.**
- Active and archived Agent Mode sidebar rows display a **Branch** badge for lineage-bearing sessions.
- After creation, the branch transcript receives a system note naming the source and turn and stating that files, Oracle chats, worktrees, and child sessions were not changed.

## Known limitations

Branching rolls back conversation context only. It does not roll back filesystem contents, Git state, worktrees, workspace selection, tool side effects, child sessions, or Oracle chats. Switching paths after either path edits files is allowed and sees the same current filesystem.

“Open elsewhere” occupancy and non-stealing reservations are currently enforced within one window. Cross-window reservation and occupancy are a follow-up; this contract does not claim cross-window safety.

V1 supports only local Codex sessions and excludes remote/gateway sessions, MCP-originated sessions, child agents, worktree-bound sessions, Claude/ACP/OMP/Pi providers, pre-existing turns without captured checkpoints, turns outside full retention, and checkpoints rejected by compaction safety. It has no edit-earlier-prompt flow, tree browser beyond the titlebar menu, checkpoint backfill, Oracle chat cloning, MCP branch command, filesystem snapshot, or durable fork-operation journal. A lost fork confirmation can leave an orphan Codex rollout because the provider exposes no reliable child lookup.

An older build can decode the session while ignoring the additive fields. If that build re-saves it, it drops checkpoint and lineage metadata: a branch becomes a standalone session and native checkpoint availability is lost, but transcript conversation content is not lost.

## Validation and smoke requirements

For changes to this boundary, run the smallest focused suites that cover the changed layer; before contribution, the complete branching validation is:

```bash
make dev-lint
make dev-swift-build PRODUCT=RepoPrompt
RPCE_ALLOW_UNKNOWN_FILTER=1 make dev-test FILTER='CodexTurnCheckpointLedgerTests|CodexNativeSessionControllerForkTests|AgentTranscriptBranchPrefixTests|AgentSessionBranchGateTests|CodexAgentModeCoordinatorBranchTests|AgentSessionBranchOriginPersistenceTests|AgentBranchUITests|MCPAskOracleWorktreeTests'
make dev-test FILTER='CodexNativeSessionController.*Tests|AgentHandoffUITests'
make dev-test-parallel
Scripts/check-agent-context
make guardrails
```

A live smoke requires explicit launch approval under `AGENTS.md`. In the CE debug app: branch after read-only exploration and continue differently; switch back and continue the original; branch at the current leaf; use **Branch anyway** after an edit; close and reopen both paths; verify an elsewhere-open target is disabled; verify branch-owned and source-owned Oracle continuation boundaries; remove a rollout and confirm exact-resume failure preserves the draft and sends nothing; interrupt the process during a fork and inspect for an orphan; and confirm branching itself changes no repository files or MCP routing.
