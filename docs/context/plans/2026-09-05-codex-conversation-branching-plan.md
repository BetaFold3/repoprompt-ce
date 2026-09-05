# Plan: Codex Conversation Branching (Pi-style "tree" rollback) in Agent Mode

Scope: read when the task touches Agent Mode conversation branching, the Codex turn-checkpoint ledger, `thread/fork` wiring in `CodexNativeSessionController`, branch switching inside a compose tab, or the `branchOrigin` session lineage field.
Authority: Authoritative
Last-verified: 2026-09-05

Status: **Plan only — not implemented.**
Date: 2026-09-05
Provenance: two independent Oracle plan consultations (presets OracleC and OracleD, identical initial prompt, `model_preset_id` verified on every send), followed by two rounds of anonymous cross-challenge on every material disagreement, then synthesis. Every load-bearing repository claim below was verified by direct reads at the cited lines in this session; every upstream claim was verified against the installed `codex-cli 0.153.3` app-server JSON schema (`codex app-server generate-json-schema`), the official app-server docs, and the Pi upstream sources.

## 1. Goal and non-goals

**Goal.** Let a user, mid-session, roll the *conversation* back to an earlier completed turn and continue differently, while the original path stays intact and switchable in the same compose tab — the experience of Pi's `/tree`. The provider's **native** conversation context must be restored at the checkpoint; this is what distinguishes branching from the existing handoff, which creates a new tab and re-injects a budgeted, lossy transcript export into a fresh provider session (`prepareHandoffHeadless`, AgentModeViewModel.swift:18316–18447; `buildForkTranscriptXML` defaults 200 items / 2000 chars, AgentTranscriptServices.swift:3558).

**Non-goals (v1).** No filesystem, Git, worktree, or workspace-selection rollback ("rollback the conversation, not the world"). No Claude, ACP (OpenCode/Cursor), OMP, remote/gateway, or Pi support. No edit-earlier-prompt, no tree browser, no MCP `agent_manage` branch command, no checkpoint backfill for pre-existing sessions, no Pi-style "summarize the abandoned branch" (that injects abandoned content into model context by design — `session-manager.ts:401`).

## 2. Verified facts the plan rests on

Repository:

- The transcript is linear: `AgentTranscript.turns: [AgentTranscriptTurn]` + `nextSequenceIndex` (AgentTranscriptModels.swift:536–540). `AgentTranscriptProviderResponseSpan.providerTurnID` exists (:325) but is **never written** anywhere; Codex turn IDs reach the coordinator via `.turnStarted(turnID:)` (CodexNativeSessionController.swift:2385–2409, CodexAgentModeCoordinator.swift:6387) and are used only for settle/idle bookkeeping. Persisted sessions therefore carry no provider checkpoint today.
- When the transcript is rebuilt from items, `AgentTranscriptTurn.id` **is** the user item's `id` (AgentTranscriptServices.swift:2907–2909) and `AgentTranscriptRequestAnchor.id = item.id` (AgentTranscriptModels.swift:245). Turn IDs are stable across rebuilds; span IDs are re-minted.
- `AgentSession` persists `providerSessionID` (:262), `codexConversationID`/`codexRolloutPath` (:281–282), `parentSessionID` (:292, child-agent nesting). Three permission decisions key on `parentSessionID == nil` (AgentModeRunService.swift:317, CodexAgentModeCoordinator.swift:4119, ClaudeAgentModeCoordinator.swift:1719). `currentSerializationVersion = 7`; `AgentSessionDataService.swift:524` rewrites only when `serializationVersion < current` — there is no `>` rejection, and decoders ignore unknown keys.
- TabSession↔AgentSession Codex sync happens only in `restoreCodexMetadata`/`applyCodexPersistence` (CodexAgentModeCoordinator.swift:1400–1432).
- `startOrResume(existing:)` issues `thread/resume` or `thread/start` only (CodexNativeSessionController.swift:1050–1166) and, on the way, runs `ensureCodexServerForDiscovery` plus expected-PID registration (:1063–1069). The coordinator wraps it in `startCodexNativeSession(… allowMissingRolloutFallback:)` (:2917–2960); the flag defaults to `true` at :3858 and is already passed `false` at several sites.
- The controller drops turn/item-scoped notifications whose `threadId` differs from the bound thread (CodexNativeSessionController.swift:3047–3051). Each `CodexAppServerClient` spawns its own `codex app-server` process (CodexAppServerClient.swift:1009).
- Oracle chats are owned per Agent Mode session: `ChatSession.agentModeSessionID` (ChatSession.swift:27); `sessionMatchesOracleOwner` requires the exact owning session ID for session-owned chats (OracleViewModel+MCP.swift:1050–1057).
- CE has zero wiring for `thread/fork`, `thread/rollback`, or `thread/revert`. `NativeAgentRuntimeControlling` has no branch/fork method and its DTO aliases still point at Claude types (NativeAgentRuntimeContracts.swift:10–57). Pi native provider is Planned, not implemented.
- Handoff pin pattern to reuse: `pinnedHandoffSource(...)` (AgentModeViewModel+Handoff.swift:264). Save scheduling: `scheduleSave(for:)` (AgentModeViewModel.swift:11929). Cold-session load: `loadSessionFromDisk(for:)` (AgentModeViewModel.swift:4379). Idle shutdown: `scheduleCodexIdleShutdownIfNeeded`/`cancelCodexIdleShutdown` (CodexAgentModeCoordinator.swift:7747/7791). Tool execution records: `AgentTranscriptToolExecution` (AgentTranscriptModels.swift:38). Metadata index entry fields live in AgentSessionMetadataIndex.swift:50–65.

Upstream (installed codex-cli 0.153.3 schema):

- `thread/fork {threadId, lastTurnId?, ephemeral?, excludeTurns?, cwd?, model?, config?, approvalPolicy?, sandbox?, approvalsReviewer?, baseInstructions?, developerInstructions?, …}`. `lastTurnId`: "Optional last turn id to fork through, inclusive. When specified, turns after `last_turn_id` are omitted from the fork. The referenced turn cannot be in progress." `excludeTurns`: metadata-only response; "Full-history hydration is deprecated for paginated threads; use `thread/turns/list` and `thread/items/list`." The params description says forking by `thread_id` *loads the thread from disk* — no prior load in the calling process is required. The source thread is untouched.
- `thread/revert {threadId, beforeTurnId}` is **in-place and destructive** ("Replace a paginated thread's durable history with the prefix before one turn… does not revert local file changes"). `thread/rollback` is **deprecated** ("will be removed soon").
- `thread/turns/list {threadId, cursor?, limit?, sortDirection (default desc), itemsView (default summary)} → {data:[Turn], nextCursor?, backwardsCursor?}`; `thread/items/list {threadId, turnId?, cursor?, limit?, sortDirection?}`; `thread/archive {threadId}`. `Turn {id (UUIDv7), status ∈ completed|interrupted|failed|inProgress, items, itemsView ∈ notLoaded|summary|full, startedAt, completedAt, error}`. `ThreadItem` kinds include `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, and `contextCompaction`.
- Pi RPC exposes `fork {entryId}` (new session file), `get_tree`, `get_entries`, `switch_session`, `clone` — no navigate command (`rpc-types.ts:61–66`). `navigateTree` is SDK-only (`agent-session.ts:3113`); a future Pi integration maps onto the same one-session-per-branch shape as Codex.
- Claude: Agent SDK `fork_session(up_to_message_id)` copies the JSONL transcript; the CLI offers only `--fork-session` (whole session). CE's stream-JSON path captures neither message `uuid`s nor any fork flag → Claude needs its own spike.

## 3. Settled design (both lanes converged; adopt)

### 3.1 Provider primitive

`thread/fork` with `threadId` = source, `lastTurnId` = checkpoint turn ID (always supplied), `excludeTurns: true`, `ephemeral: false`, `cwd` = pinned source runtime cwd (no worktree substitution), the same approval/sandbox/config values `startOrResume` sends, **no** `baseInstructions`, **no** prompt, **no** model change merely to branch. One attempt; a transport timeout or disconnect after submission is reported as *ambiguous*, never auto-retried.

Rejected: `thread/revert` (destroys the original path), `thread/rollback` (deprecated), `ephemeral: true` (not resumable), `excludeTurns: false` (deprecated hydration; CE is the presentation authority), Pi-style branch summary (contaminates context).

### 3.2 Checkpoint capture — session-level ledger (D1, converged)

New `Runtime/Codex/CodexTurnCheckpointLedger.swift`:

```swift
struct CodexTurnCheckpointLedger: Codable, Equatable, Sendable {
    var threadID: String                      // thread the turn IDs belong to
    var entries: [CodexTurnCheckpoint]        // Codex turn order
    var compactionBoundaryTurnID: String?     // newest completed entry when thread/compacted last fired (see §3.6)
}
struct CodexTurnCheckpoint: Codable, Equatable, Sendable {
    let turnID: UUID          // CE turn id == user row id (stable across rebuilds)
    let codexTurnID: String   // turn.id from turn/started
    var status: Status        // inProgress | completed | failed | cancelled
    var sideEffect: SideEffect? // readOnly | modified(paths:) | unknown — sealed at .turnCompleted (§3.8)
    let recordedAt: Date
}
```

- Persisted as `AgentSession.codexTurnCheckpoints: CodexTurnCheckpointLedger?` (additive `decodeIfPresent`/`encodeIfPresent`), mirrored on `TabSession`, synced in `restoreCodexMetadata`/`applyCodexPersistence`.
- Recorded in `CodexAgentModeCoordinator` **after** the existing authoritative-start acceptance (`installAuthoritativeCodexTurnForStart`), not on raw `.turnStarted` receipt. One current candidate per CE turn; an accepted replacement native turn for the same request replaces the candidate; a checkpoint is marked `completed` only after the CE request's final terminal settlement (intermediate steered completions are not checkpoints); stale completions whose native ID no longer matches are ignored.
- Invalidated in O(1) when `ledger.threadID != codexConversationID` (fresh-thread fallback, thread replacement); pruned on save to CE turn IDs still present in `transcript.turns`.
- **Not** written to span `providerTurnID`, not added as `AgentTranscriptTurn` fields. Rationale: checkpoints are thread-binding metadata like `codexConversationID`; in-transcript fields would need every items→transcript rebuild path audited, would ride migrated rows into handoff tabs, and would leak into remote projection/export payloads.
- Pre-existing sessions: no backfill (CE turns do not map 1:1 onto Codex turns — cancelled runs, steering, handoff-injected turns). Older turns show "No native checkpoint was recorded for this turn." Capture ships **before** any UI so real sessions accumulate branch points.

### 3.3 Branch model and persistence (D7 + version, converged)

- **One `AgentSession` per branch**, new UUID and file. Lineage lives **only on branches**:

```swift
struct AgentSessionBranchOrigin: Codable, Equatable, Sendable {
    let rootSessionID: UUID      // source.branchOrigin?.rootSessionID ?? source.id
    let sourceSessionID: UUID
    let sourceTurnID: UUID       // CE turn kept inclusive
    let sourceCodexTurnID: String
    let sourceTurnOrdinal: Int   // 1-based, for labels without loading
    let createdAt: Date
}
```
  `AgentSession.branchOrigin: AgentSessionBranchOrigin?` — root has `nil`. Tree = `{ id == root } ∪ { branchOrigin.rootSessionID == root }`, answered by a MetadataIndex query (index entry gains `branchRootSessionID: UUID?`).
- **The root is never written by branching** (the ordinary pre-fork flush of unsaved source state is not a branching mutation). Rejected: annotating the root with a `conversationID` — a droppable second authority and an extra write to the one artifact the feature promises not to touch.
- **No `serializationVersion` bump.** Additive optional keys; a bump would force a rewrite of every existing session on load (DataService:524) and buys nothing. Downgrade re-save by an older build drops the new keys (branch becomes a standalone session, checkpoints lost, no conversation loss) — release-note it.
- `parentSessionID`, `origin`, `isMCPOriginated`, `profile` keep their meanings. Branch session: `origin = .user`, `parentSessionID = nil` (only top-level sources qualify), `name = "\(source.name) (branch)"`, `lastRunState` idle, `providerSessionID`/`remoteHost`/pending-handoff/`codexMcpSessionKey` nil, worktree/merge/resend collections empty, `codexConversationID`/`codexRolloutPath` from the fork `SessionRef`, ledger = source entries through the checkpoint re-homed to the fork thread (positionally re-keyed if the spike shows ID remapping), Codex token totals nil.
- Deleting the root does not cascade (picker shows "Original (deleted)"); deleting a branch is an ordinary delete.

### 3.4 Transcript prefix (converged)

`AgentTranscriptIO.branchPrefix(of:throughTurnID:)` — pure, tested — copies `turns[0...k]` (never splits a span), preserves row/turn/span IDs and sequence indices, keeps `nextSequenceIndex` as the source's high-water mark, clamps `compactionFrontier` to `k+1` (or nils it and lets the policy pipeline recompute), filters `uiToolResultPayloadsByItemID` to retained rows, recomputes `itemCount`/`transcriptProjectionCounts`/`lastUserMessageAt`, leaves `items` empty on disk, truncates `providerTokenUsageByTurn`. Never reuse `buildForkTranscriptXML`, `handoffTranscript`, render-row cutoffs, or `createBackgroundForkComposeTab`. The target must be a full-retention completed turn with a final assistant reply. After restore, one `.system` note is appended through the normal system-note path: "Branched from “{source}” after turn {n}. Conversation context was restored to that point. Files on disk, Oracle chats, worktrees and child sessions were not changed."

### 3.5 Runtime seam (converged)

`NativeAgentRuntimeControlling` untouched. Add to `CodexSessionControlling` (CodexNativeSessionController.swift:54) and every test double: `forkThread(_:) -> SessionRef` (pure request: no `applyThreadResponse`, no `beginBindingSession`, no change to `threadID`/`threadPath`/`routingCurrentTurnID`/`activeTurnIDs`; precondition bound + idle), `listThreadTurns(threadID:cursor:limit:sortDirection:)`, `archiveThread(threadID:)`. Branchability is an Agent-Mode capability, not a runtime feature:

```swift
enum AgentSessionBranchAvailability { case available(CodexTurnCheckpoint), unavailable(Reason) }
enum Reason { providerUnsupported(AgentProviderKind), remoteSession, mcpOriginated, childSession, worktreeBound,
              notIdle, operationInProgress, pendingHandoff, noCheckpoint, turnNotCompleted, beforeCompaction, threadMismatch }
```
`AgentSessionBranchGate.evaluate(session:turnID:)` is pure (`Runtime/Branching/AgentSessionBranchGate.swift`). Claude/ACP/OMP/remote → disabled item with the reason; **no handoff fallback**.

### 3.6 Fork verification and compaction (D2, converged after modification)

Per-operation, all pages exhausted, `sortDirection: desc`, `itemsView: summary`, reject repeated cursors/duplicate IDs/incomplete pagination:

1. Pre-fork `thread/turns/list(source)`: the ledger's Codex turn IDs through the checkpoint must be an ordered subsequence of the manifest (this is the external-rewrite detector; no separate "epoch"); `lastTurnId.status == completed`; no `inProgress` turn.
2. Fork.
3. Post-fork `thread/turns/list(child)`: child ID nonblank and ≠ source; **count == index(lastTurnId)+1 (gate)**; ordered turn IDs and statuses equal the source's from `lastTurnId`'s position onward (or positional equality if the spike shows remapping — then re-key the branch ledger from the child manifest); if `summary` exposes item kinds at no extra cost, also require no `contextCompaction`/interruption item the source position lacks (do **not** fan out `thread/items/list` per turn — content digests, fingerprints, and epoch UUIDs are rejected as a competing history authority).
4. Re-read the source manifest; must equal the pre-fork read.
5. Mismatch → `thread/archive` the known, unsaved child; no branch; explicit error. Cost for a 200-turn thread at limit 100: ~6 requests.

Compaction policy is decided by Phase 0, before code:
- **Outcome A** — fork replays the rollout through `lastTurnId` (a fork below a compaction boundary answers from raw pre-compaction history): no compaction gate; `compactionBoundaryTurnID` is dropped.
- **Outcome B** — fork uses compacted state: the boundary must come from durable history. The pre-fork `turns/list` read discovers `contextCompaction` items and sets the boundary *at branch time*, superseding any event-derived value (so detachment while the Codex CLI resumed the rollout is irrelevant). Checkpoints at/before the boundary are `.beforeCompaction`.
- **Fallback only if B holds and compaction items are not discoverable via `turns/list`**: clear saved checkpoint eligibility on (re)attachment and capture subsequent turns only — documented as degraded, not the design, because reattach is every idle reconnect and clearing would confine the feature to a single continuous attachment.

### 3.7 Resume policy (D6, converged)

Exact resume for every tree member: `allowMissingRolloutFallback: false` when `session.branchOrigin != nil` **or** the MetadataIndex tree query finds any branch with `rootSessionID == session.id` (an incomplete or stale index must not authorize fallback; invalidate the membership cache after a child save/index partial failure until reconciled). On failure the send fails loudly — "Codex couldn't reopen this conversation (rollout missing). Your message wasn't sent. The other paths may still be available in the branch menu; you can hand this transcript off to a new session." — with the draft preserved and handoff an explicit user action. Ordinary non-branch sessions keep today's fallback. Rationale: a silent fresh thread on the root consumes the user's message and destroys the very path the picker promises to preserve.

### 3.8 Read-only classification and gating (D4, converged)

Classification is **informational, never a creation gate**. Sealed per checkpoint at `.turnCompleted` from the turn's `AgentTranscriptToolExecution`s (before retention demotion can drop activities): `readOnly` (only recognized RepoPrompt MCP read tools — read_file, file_search, get_file_tree, get_code_structure, workspace_context; matched by trusted server identity + canonical tool name), `modified(paths:)` (affirmative successful write/edit/move/delete evidence), `unknown` (shell/command execution, arbitrary or dynamic MCP tools, `manage_selection`/prompt/chat-mutating tools, incomplete tool lifecycle, compacted evidence). Never parse shell command strings. Aggregate worst-of over all omitted turns. Rationale: Codex explores through native `shell`/`command_execution`, so "unknown = blocked" would kill the primary use case; the promise is conversation rollback, not side-effect undo.

Hard gate (`.available` only when all hold): local `.codexExec`, `remoteHost == nil`, `origin == .user`, `parentSessionID == nil`, no worktree bindings/merge operations, `runState == .idle` with no pending Codex interactions, terminal settle, steering queue, attachment work, or in-flight Oracle request bound to the source, no `pendingHandoff`, no branch operation in progress, ledger thread == `codexConversationID`, checkpoint `completed` and not `.beforeCompaction`. Knowledge profile is allowed (profile copied; no provider change). Composer draft text is preserved, never sent.

### 3.9 Operation ordering, guard, failure handling (D3 partially converged)

Write-first, no durable journal: **await source save → fork → verify → save branch file → restore into tab → note/reconnect on next send**. Each failure leaves the root bound with an explicit message; no automatic retry; post-fork failures inside a live process archive the child so "Try again" accumulates nothing. Crash residue is at most an orphan rollout in `~/.codex/sessions` (invisible; not user data). A fork whose outcome is unknown (timeout without a returned ID) is reported as ambiguous; a journal could not resolve it either without a child-lookup primitive, so the journal is a follow-up gated on a demonstrated failure mode.

In-memory per-tab operation guard (existing `pinnedHandoffSource` pattern plus generations): pin `ObjectIdentifier(session)`, `activeAgentSessionID`, `bindingTransitionGeneration`, persistence/transcript mutation generation, `codexConversationID`, `runState == .idle`; re-validate after **every** await; `isBranchOperationInProgress` disables send/steer/handoff/session-load/tab-close on that tab and all MCP entry points; `cancelCodexIdleShutdown` for the operation's duration. Concrete race this closes: idle check → await fork → MCP starts a source turn → activation replaces the tab binding while source callbacks remain active.

| Step | Failure | State after | User sees |
|---|---|---|---|
| Source save | error | nothing changed | "Couldn't save the current session; no branch was created." |
| `thread/fork` | RPC error | root bound | provider error text |
| `thread/fork` | timeout / unknown outcome | root bound; possible orphan | "Codex didn't confirm the branch. Nothing was changed here; check for a stray Codex thread." |
| Verify | mismatch | child archived (best-effort) | "Codex didn't return the expected history; no branch was created." |
| Save branch file | write error | orphan thread; root untouched | "Branch was created in Codex but couldn't be saved. Try again." |
| Restore into tab | binding error | branch file exists, switchable from picker/history | "Branch saved but couldn't be opened; open it from the branch menu." |
| Cancel | only in the sheet; not cancellable once submitted (bounded by `options.requestTimeout`) | | |

Switching (`switchToBranch(sessionID:)`): same idle gate → await save of the current tab → shut down `codexController` → load target via DataService → existing restore-into-tab binding transition (candidate entry point `loadSessionFromDisk(for:)`, AgentModeViewModel.swift:4379 — inventory in Phase 0) → `restoreCodexMetadata` sets `codexNeedsReconnect` → no send. A target already bound in another tab/window is disabled ("This branch is open in another tab."). Switching after a branch has edited files is allowed once idle, with the filesystem warning: it switches between native leaves, it does not undo effects.

### 3.10 Isolation

| Hazard | v1 rule |
|---|---|
| Late tool results / command updates | idle gate + controller shut down before switch; keep original run/controller ownership; never retarget by current tab ID; foreign-thread notifications dropped (:3047–3051 — verify `thread/*`-level methods too) |
| Queued steering / drafts | non-empty queue → `.notIdle`; draft preserved |
| Oracle chats | see §4 open item D5; v1 recommendation: source-owned, results displayable, continuation from a branch errors |
| Pending handoff / remote resend | `.pendingHandoff`; never cleared or consumed |
| Compaction summaries carrying abandoned turns | CE per-turn summaries are exact under prefix copy; Codex side per §3.6 |
| MCP expected-PID routing | unchanged: reconnect goes through `startOrResume`; branch gets a fresh `codexMcpSessionKey` |
| Worktree bindings / merge ops | `.worktreeBound` (cwd projection for a branch undefined; follow-up) |
| MCP-originated source | `.mcpOriginated` |
| Sub-agent children | source with `parentSessionID != nil` → `.childSession`; children of the source stay attached to the source; note says so |

### 3.11 UI

"Branch from here…" on completed assistant conclusion rows (beside handoff; row → `turn.request?.id` → ledger). Disabled reasons as help text: "Native branching is currently available only for local Codex sessions.", "No native checkpoint was recorded for this turn.", "Codex compacted this conversation after this checkpoint.", "Finish the pending operation before branching." Do not overload `canForkSession(_:)` (handoff availability).

Confirmation sheet: title "Branch from this reply?"; body "Keeps turns 1–{n}. Sets aside {m} later turn(s) on this branch: {Read-only exploration | May have changed files | Changed files: <paths>}. Anything they changed on disk stays changed. Files, Git state, and workspace selections are not rolled back. The current path stays available in the branch menu." Button "Branch" (or "Branch anyway" for modified/unknown) / "Cancel". Progress: "Branching…" status in the tab. Picker: titlebar menu when the tree has >1 member — "Original" first, branches with "from turn {ordinal}" and saved date, active checked; same idle gate. History list: "Branch" badge on sessions with `branchOrigin`.

## 4. Material disagreements and how they were resolved

| # | Dispute | Lane 1 opened | Lane 2 opened | Outcome |
|---|---|---|---|---|
| D1 | Checkpoint storage | in-transcript span `providerTurnID` + turn `codexCheckpoint`/`codexBranchSafety`, every rebuild path audited | session-level ledger keyed by user row ID | **Ledger** (lane 1 conceded in round 1 after F1: turn.id == user row id; span IDs re-minted). Lane 1's sealed per-turn safety classification adopted *inside* the ledger entry. |
| D2 | Verification depth / compaction | full pre/post manifests with item-content digests, per-thread history epoch UUID, compaction fingerprint from durable records | newest-turn-ID + count, `.beforeCompaction` flag | **Structural turn-level comparison** (IDs, statuses, count gate, markers if free) — lane 1 dropped digests/epoch/fingerprint, lane 2 upgraded from newest-ID-only after conceding it cannot see remapped IDs or interruption/compaction markers. Compaction resolved as spike Outcome A/B with clear-on-reattach only as documented fallback (lane 1 conceded the default-clear). |
| D3 | Which controller forks; recovery | operation-owned controller + durable 6-phase journal + mutation lease | pure request on existing controller, write-first, no journal | **Journal dropped by both; in-memory guard adopted by both.** Controller choice **swapped in round 2 and remains open** — see below. |
| D4 | Read-only gate | hard block unless provably read-only | informational | **Informational** (lane 1 conceded: a gate that fails closed on Codex's native shell exploration is a dead feature; copy hardened, "Branch anyway"). |
| D5 | Oracle chats | block creation if source owns any chat | tree-scoped shared access | **Open after two rounds (positions swapped)** — see below. |
| D6 | Resume policy | exact-resume for every tree member | existing fallback | **Exact resume for children and for any root that has branches**; ordinary sessions unchanged (lane 2 conceded: a silent fresh thread on the root consumes the message and destroys the promised path). |
| D7 | Root write | annotate root on first branch | never write root | **Never write the root** (lane 1 conceded: lineage on branches + index query suffices). |
| — | `serializationVersion` bump | 7→8 | none | **Resolved by verification, no bump** (DataService:524 would rewrite every session; decoders ignore unknown keys). |
| — | Knowledge profile | unsupported | allowed | Resolved by judgment: **allowed** (profile copied; no provider change). |

### D3 (open): fork on the live tab controller vs. an operation-owned controller

*Position A — live, bound, idle tab controller, fork before shutdown* (lane 2's final): the source thread is already loaded in that process, so `thread/fork {threadId}` is the documented case; no second `codex app-server` is spawned (each client spawns one, CodexAppServerClient.swift:1009); MCP initialization, if the fork triggers any, arrives on the already-registered PID; foreign-thread notifications are already dropped (:3047–3051). Invariants to test: state snapshot equal before/after `forkThread`; precondition bound + no turn in flight; synthetic child-ID `thread/started`/`item/*` notifications never enter the source transcript; idle shutdown cancelled for the duration. Cold session (`codexNeedsReconnect`, no controller): run the normal reconnect with `allowMissingRolloutFallback: false` first (a fork of a fallback-created fresh thread would be a branch of nothing; this also proves the root is resumable).

*Position B — short-lived `CodexBranchOperation` owning its own `CodexNativeSessionController`* (lane 1's final): no expected MCP client name, no PID registration, transport setup separated from `startOrResume`'s binding/integration behaviour, only fork/list/archive, shut down on every outcome; avoids auditing the tab controller's post-shutdown residue and keeps an irreversible provider mutation off the UI-bound object. Costs a second app-server process and, if the fork initializes the child's MCP servers, an `initialize` from an unregistered PID.

**Recommendation: Position A as the primary design, B as the spike-selected fallback.** A violates no named invariant when the fork runs *before* shutdown, reuses the registered PID and loaded thread, and is the smaller change. Switch to B only if Phase 0 shows that `thread/fork` on a bound controller emits `thread/*`-level notifications for the child that the mismatch filter does not cover, or that it initializes the child's MCP servers in a way that disturbs source routing.

### D5 (open): Oracle chats owned by the source

*Position A — source-owned, no shared mutable ownership* (lane 1 round 1, lane 2 final): keep `ChatSession.agentModeSessionID` and `sessionMatchesOracleOwner` unchanged (zero new authority — the existing check already rejects the branch's session ID); copied Oracle tool results stay displayable in the branch transcript; the branch's model calling `ask_oracle(chat_id: X)` gets "This Oracle chat belongs to another branch of this conversation. Start a new Oracle chat here to continue."; new chats belong to the creating branch; sheet line "N Oracle chats stay with the original path — this branch can read their results but must start new chats to continue."; abandoned turns with chat-mutating calls classify as not read-only; quiescence gate includes no in-flight Oracle request bound to the source. Argument: continuing X from the branch would consume X's tail, which may hold abandoned-path messages (the same contamination rejected for compaction summaries), and post-fork appends from either path would silently corrupt the other; tree scope also over-grants (a branch from turn 2 reaching chats created at turn 8).

*Position B — shared live access with disclosure* (lane 2 round 1, lane 1 final): chat IDs are baked into the fork's native history, so denial breaks a capability the transcript references; treat chats like files ("not rolled back"), give tree members read/continue access resolved from stored session metadata, keep ownership unchanged, enforce one active continuation per chat ID (busy error), keep cleanup/deletion/cloning ownership-scoped.

**Recommendation: Position A for v1.** It is the existing behaviour by construction, introduces no new authority, and prevents cross-branch contamination; the loss is *continuation*, not fidelity, and it is disclosed to both the user (sheet) and the model (actionable error). Follow-up: lazy clone-at-checkpoint with transparent chat-ID resolution at the MCP boundary (messages with timestamp ≤ `turns[k].completedAt`, reusing the handoff clone-with-mapping machinery) — the only design that preserves both the native reference and the cut.

## 5. Phase 0 spike gates (blocker-capable; evidence to `docs/investigations/codex-branching-spike.md`, kept local)

Scripted against installed codex-cli 0.153.3 with disposable threads and a scratch workspace:

1. Three distinguishable turns → `thread/fork {lastTurnId: turn2, excludeTurns: true}` → resume the fork → prompt "what was my last message?" must reference turn 2, not 3; `thread/turns/list` shows fork `[t1,t2,new]`, source `[t1,t2,t3]` unchanged; repeat after app-server restart (resume by path).
2. **U1** Are retained turn IDs preserved or remapped across the fork? (Determines positional re-keying.)
3. **U2** Does `thread/fork {threadId}` succeed from a process that never loaded the thread? (Cold-session path; the schema says it loads from disk.)
4. **U3** Does `itemsView: summary` expose item kinds/counts, or only display text? (Determines whether marker checks are free.)
5. **U4** Does a `contextCompaction` item appear in `thread/turns/list` output? Fork below a `thread/compacted` boundary → Outcome A or B (§3.6).
6. **U5** Does `thread/fork` on a bound controller emit child-thread notifications (`thread/started`, MCP `initialize`) and are they dropped by the mismatch filter? (Selects D3 A vs. B.)
7. `turn/started` IDs equal `thread/turns/list` IDs across resume; `thread/archive` behaviour on an unsaved child; lost-response behaviour (why fork retries are unsafe); repository file hashes unchanged by branching itself.

If gate 1 fails (fork does not restore native context through `lastTurnId`), stop — do not substitute handoff.

## 6. Phases and sizing (one engineer)

| Phase | Ships | Size |
|---|---|---|
| 0 Spike | evidence doc; U1–U5 answered; go/no-go | 2–4 d |
| 1 Capture | ledger types, coordinator recording + sealing + side-effect classification, `AgentSession`/`TabSession` fields, sync/prune, tests. **Ships alone** so sessions accumulate branch points | 3–5 d |
| 2 Primitive | `forkThread`/`listThreadTurns`/`archiveThread`, DTOs, errors, fakes, structural verification helper, controller tests | 3–5 d |
| 3 Model | `branchOrigin`, prefix builder, orchestration (`branchFromTurn`, `switchToBranch`), guard, MetadataIndex field + tree query, exact-resume policy, persistence tests | 1 wk |
| 4 UI + hazards | menu item, sheet, picker, badge, disabled reasons, Oracle error copy, UI tests, docs; live smoke | 1 wk |
| Later | edit-earlier-prompt (fork through the previous turn + prefill composer); tree browser; checkpoint backfill; worktree-bound sessions; Oracle clone-at-checkpoint; durable operation journal if a real failure mode appears; `agent_manage.branch_session`; Claude spike; Pi after its native runtime lands | — |

Total ≈ **3.5–5 weeks**, excluding a failed Phase 0.

## 7. Tests and validation

New suites: `Tests/RepoPromptTests/AgentMode/Codex/CodexTurnCheckpointLedgerTests.swift`, `Tests/RepoPromptTests/AI/CodexNativeSessionControllerForkTests.swift` (request shape, no binding side effects, foreign-thread drop, pagination, archive), `Tests/RepoPromptTests/AgentMode/Transcript/AgentTranscriptBranchPrefixTests.swift`, `Tests/RepoPromptTests/AgentMode/Codex/AgentSessionBranchGateTests.swift` (every reason; classification matrix), `Tests/RepoPromptTests/AgentMode/Codex/CodexAgentModeCoordinatorBranchTests.swift` (step ordering, failure at each step leaves root bound, verification mismatch, no auto-send, guard races, exact-resume for root-with-branches and children), `Tests/RepoPromptTests/Persistence/AgentSessionBranchOriginPersistenceTests.swift` (round trip, version unchanged, legacy decode), `Tests/RepoPromptTests/AgentMode/AgentBranchUITests.swift` (modelled on `AgentHandoffUITests.swift`; also proves handoff and MCP `fork_session` are unchanged). Add ledger rows surgically; never regenerate.

```bash
make dev-lint
make dev-swift-build PRODUCT=RepoPrompt
RPCE_ALLOW_UNKNOWN_FILTER=1 make dev-test FILTER='CodexTurnCheckpointLedgerTests|CodexNativeSessionControllerForkTests|AgentTranscriptBranchPrefixTests|AgentSessionBranchGateTests|CodexAgentModeCoordinatorBranchTests|AgentSessionBranchOriginPersistenceTests|AgentBranchUITests'
make dev-test FILTER='CodexNativeSessionController.*Tests|AgentHandoffUITests'   # regression
make dev-test-parallel                                                          # contribution evidence
Scripts/check-agent-context && make guardrails
```

Live smoke on the CE debug app (launch approval per AGENTS.md): branch after read-only exploration → continue differently → switch back → continue original; branch at current leaf; "Branch anyway" over an edit turn; close/reopen both branches; force process death mid-fork; remove a rollout and confirm exact-resume error with draft preserved; confirm no file changes from branching and no leaked MCP routing.

## 8. Phase 0 owner inventory (resolve before Phase 1; do not invent parallel mechanisms)

`CodexSessionControlling` conformers and test doubles; the restore-into-tab binding transition entry point; MetadataIndex entry type and DataService query for `branchRootSessionID`; the Oracle per-tab chat list filter on `agentModeSessionID`; derivation of `codexMcpSessionKey`; the transcript row action-menu and titlebar hosts; coverage of `thread/*`-level notifications by the thread-mismatch drop. Record the `rg` inventory in the PR description.
