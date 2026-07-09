# Technical Implementation Report - 2026-07-09 - Remote Premature-Terminal Latch & Context Builder Model Label Fixes

## Session Overview

Deep investigation and same-day fix of two recurring remote-client display defects observed while running a `context_builder` workflow session remotely (native client ↔ RepoPromptGateway ↔ live host app):

1. **Premature "completed" latch** — the client showed the session as completed while the host workflow was still running multi-turn. The gateway emitted `session_terminal` frames at workflow turn boundaries (seq 3, 4, 5, 6 in the incident log before the genuine terminal at seq 23), and the client irreversibly stamped in-flight tool calls with synthetic "completed" results.
2. **Wrong model label** — the Context Builder tool card displayed the client's *local* default model ("GPT 5.5 medium") instead of the host's actual model (OpenCode Go / GLM 5.2).

The session ran the full deep-investigation protocol (git archaeology → context builder → pair investigator → adversarial oracle review), produced a root-cause report with file:line evidence (local `docs/investigations/remote-client-premature-terminal-and-model-label-2026-07-09.md`, intentionally uncommitted), then implemented fixes 1–4 of the recommendation set as three oracle-planned work packages executed by three parallel engineer agents on disjoint file sets, with two oracle review rounds (final verdict: ship). Because this defect class has recurred several times, incident-shaped contract tests were added at every layer (gateway, host, client).

## Root Cause (three scope confusions on one axis)

1. **Turn-scoped treated as session-scoped (wire/protocol):** host `agent_run` snapshot `status=completed` is turn-scoped; the terminal commit barrier publishes the terminal revision *before* starting any follow-up, and `AgentRunMCPToolService.currentSnapshot` returned the store's retained terminal snapshot *before* consulting the live snapshot — bypassing the `mcpFollowUpRunPending` running mask on all poll paths. The gateway blindly mapped every terminal-status snapshot to `session_terminal` with no dedupe and never retired terminal sessions from the watched set, so every re-poll re-emitted a terminal.
2. **Session-scoped treated as sub-run-scoped (wire/protocol):** the only model on the wire (`agent.model`) is the parent agent session's model; the CB sub-run's model is never serialized.
3. **Workspace-local-VM state treated as session state (client rendering):** the CB tool card read the local `ContextBuilderAgentViewModel` for both phase and model label, so remote sessions rendered local defaults and local phase state.

Pre-existing semantics — not introduced by that day's earlier commits (`22fe0ed`, `ee8fb72`); verified by git archaeology back to the gateway watch file's introduction and by clean-HEAD baseline runs.

## Implementation Details

### Work Package A — Gateway terminal qualification

**Problem Statement:** `SessionWatchManager.emitSnapshot` mapped any snapshot with status ∈ {completed, failed, cancelled} to a `session_terminal` frame — no transition awareness, no dedupe (dedupe existed only for push wakes), and terminal sessions stayed inertly watched so subscribe/pollCatchUp/rearm re-polls re-emitted terminals indefinitely.

**Solution Approach:**
- **Transition-edge dedupe:** `lastEmittedIsTerminalByDeviceSession` — `session_terminal` emits only on a non-terminal→terminal edge; duplicate terminals are suppressed entirely (no frame, no seq consumed). Suppression (not demotion to `session_update`) was chosen because the client derives terminal state from the payload's `status` field, not the frame type — a demoted frame would still latch.
- **Completed-terminal quarantine** (default 5 s, init-injectable, `completed` only): the terminal is held; after the quarantine window a confirm re-poll runs. Resumed → running recovery frame; still terminal → emit; poll failure → fail open and emit the held terminal (a genuine terminal is never lost). `failed`/`cancelled` bypass the quarantine and emit immediately.
- **Terminal demotion:** after terminal emission, sessions move into `parkedTerminalSessionIDs` and are re-polled by the existing 30 s revalidation loop — deterministic resume detection (the incident's recovery frame previously arrived only by accident). Full retirement only on expired/unsubscribe/teardown.
- **Targeted subscribe catch-up:** a freshly subscribing sink still receives one targeted `session_terminal` when the edge state is already terminal (skipped while a quarantine is pending, so the held terminal can't leak to a fresh sink).
- **Trigger-attributed logging** on every emission path (`subscribe | pollCatchUp | waitLoop | revalidation | quarantine`), closing the seq-attribution gap from the incident log.
- **Watched-membership invariant (oracle P1 fix):** classification helpers now require the session to already be in `watchedSessionIDs`; the unconditional re-insert in `handleWaitSnapshot` was removed and `markSessionPendingObservation` no longer recreates torn-down device state — an in-flight 30 s wait can no longer resurrect an unsubscribed session into permanent observation.

**Files Modified:**
- `Sources/RepoPromptGateway/Watch/SessionWatchManager.swift` (+268 −47)
- `Tests/RepoPromptTests/Gateway/SessionWatchManagerTerminalEdgeTests.swift` (new, 10 tests)
- `Tests/RepoPromptTests/Gateway/SessionWatchManagerRevalidationTests.swift` (terminal-revalidation contract inverted intentionally, keeping the never-re-enter-wait-loop assertion)
- `Tests/RepoPromptTests/Gateway/GatewayWaitLoopContractTests.swift` (pin `terminalQuarantineSeconds: 0` for pre-quarantine timing contracts)
- `Tests/RepoPromptTests/Gateway/PushTriggerTests.swift` (original immediate-push contract pinned at quarantine 0; new contract test: quarantine delays but never loses the sessionTerminal push)

### Work Package B — Host snapshot precedence + `followup_pending`

**Problem Statement:** `AgentRunMCPToolService.currentSnapshot` short-circuited on a stored terminal snapshot before consulting the live snapshot, so gateway polls observed stale `completed` even while the host masked the session as running across a follow-up boundary.

**Solution Approach:** surgical precedence change via a pure, table-testable helper:

```swift
// AgentRunMCPToolService.swift — stored-terminal branch
if let storedSnapshot, storedSnapshot.status.isTerminal {
    // Live non-terminal (masked-running / genuinely running) wins;
    // canonical committed terminal (runID, failure detail) wins otherwise.
    if let registration,
       let live = agentModeVM.mcpSnapshot(registration: registration),
       !live.status.isTerminal {
        return live
    }
    return storedSnapshot
}
```

Plus an additive, skew-safe wire field: `AgentRunMCPSnapshot.followUpPending` — serialized as `"followup_pending": true` only when true, parsed with default `false`, populated from `session.mcpFollowUpRunPending || session.pendingSupersedingTurnCompletions > 0` in both the live and canonical-terminal construction paths. Because the barrier sets the mask before building the terminal envelope, a stored terminal snapshot itself carries `followup_pending=true` when a successor was sampled. A `session_final` field was deliberately **not** added — the host cannot assert finality at no-successor boundaries.

**Files Modified:**
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift` (+28 −13)
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPSnapshot.swift` (+6)
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` (+2 — snapshot construction only)
- `Tests/RepoPromptTests/MCP/AgentRunSnapshotPrecedenceTests.swift` (new, 3 tests)
- `Tests/RepoPromptTests/MCP/AgentRunMCPToolServiceWaitTests.swift` (one test aligned with the barrier invariant — it previously published a stored terminal while leaving the fake live session non-terminal, a state production cannot reach)

### Work Package C — Client reversible settlement + remote-aware CB card

**Problem Statement:** `RemoteAgentModeCoordinator.applyTerminal` stamped synthetic "completed" results onto in-flight tool calls with no un-settle path (the durable latch), and the CB card rendered local-VM phase/model for remote sessions.

**Solution Approach:**
- **Marker-tagged reversible settlement:** synthetic results are produced by a new `AgentToolResultPersistencePolicy.syntheticSettlementResultJSON(...)` (= `minimalResultJSON` + `"synthetic_settlement": true`; `minimalResultJSON` itself unchanged so real host projections stay unmarked). Revert fires on the **terminal→active transition** (previous `runState` captured before mutation), which survives coordinator teardown/re-attach; `tabsWithSyntheticSettlements` remains as a fast-path guard. Real results are never overwritten and never reverted; host results overwrite synthetics via the projector's wholesale upsert.
- **Discovery debounce:** repeated `.terminal` events without an intervening running state no longer trigger immediate child-session discovery.
- **Remote-aware CB card:** `ContextBuilderCardContext` gained `isRemoteSession` (set at the single construction site in `AgentModeView`). Remote cards derive phase from tool-result presence (`toolResultJSON == nil && toolIsError == nil` → running), omit the model/detail line entirely (the only wire-available model is the parent agent's — an honest omission beats a differently-wrong label), hide local-only run details and cancel controls. Local behavior is bit-identical, pinned by test.

**Files Modified:**
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` (+45 −4)
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentToolResultPersistencePolicy.swift` (+21)
- `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ContextBuilderToolCards.swift` (+70 −18)
- `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolCardRouter.swift` (+4 −1)
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift` (+3 −1)
- `Tests/RepoPromptTests/AgentMode/RemoteTerminalSettlementReversalTests.swift` (new, 8 tests)
- `Tests/RepoPromptTests/AgentMode/ContextBuilderRemoteCardTests.swift` (new, 2 tests)

### Technical Decisions

- **Suppress duplicate terminals, don't demote:** the client keys terminal handling off payload `status`, not frame type.
- **Edge dedupe AND quarantine:** edge dedupe alone still emits one terminal per turn boundary (the incident had four); the quarantine converts fast-resume boundaries into zero terminal frames. Cost accepted: genuine completion notifications/push wakes delayed ≤5 s.
- **No terminal unwatch:** a naive unwatch-on-terminal would have made the latch *permanent* (the spurious re-polls were the only recovery channel); demotion to the revalidation set keeps resume detection alive.
- **Transition-edge push/emission keying** rather than per-status dedupe — a bare status dedupe would suppress the genuine final terminal after a completed→running→completed cycle.
- **Marker inside result JSON** rather than a new statusWord (zero rendering blast radius) or an in-memory set (leaks wrong state across teardown).
- **All wire changes additive-optional:** new host + old gateway/client and vice versa all degrade to current behavior; the gateway forwards snapshot payloads verbatim.

## Bug Fixes

1. **Premature terminal latch (recurring)** — fixed at all three layers as above.
2. **Wrong CB model label** — remote CB cards no longer render local defaults.
3. **Unsubscribed-session resurrection (found in oracle review)** — in-flight wait results could permanently re-add an unsubscribed session to gateway observation; watched-membership guards added.
4. **Multiplex wait batching regression (caught mid-implementation)** — the first gateway iteration called `ensureWaitLoop` mid-emission, splitting multi-session subscribes into single-session waits; loop scheduling moved back to outer coordination points (caught by pre-existing `testMultiplexWaitUsesSessionIDsArray`).
5. **Quarantine silent-drop edge** — device-state-missing path now falls through to emit instead of losing a terminal.

## Challenges Encountered

- **Parallel agents, one checkout:** three engineers editing simultaneously meant early focused test runs collided with in-flight compiles from sibling packages. Resolved by disjoint file ownership (verified pre-dispatch), daemon-serialized builds, and a consolidated validation pass after all packages landed.
- **Full-suite noise vs. real regressions:** the root suite (3460 tests) surfaced 8 failures. Two were genuine blast-radius follow-ups (PushTrigger timing, the stored-terminal wait test asserting the old buggy contract) and were fixed. Two ambiguous ones (`ToolCatalogSnapshotTests` golden, `AgentModeSidebarSessionBuilderTests` recency) were proven **pre-existing** by running them in an isolated `git worktree` at clean HEAD (`ee8fb72`) — both fail identically without our diff. The rest are documented load-flaky (e.g. `GitLoadedRootAuthorityEvidenceTests` appears in the test-suite-optimizer reliability-gate flake artifacts).
- **Background-run exit masking:** piping `make dev-test` through `tail` masked the failing exit code on the first full-suite run; re-ran with explicit `EXIT=$?` capture.

## Testing

23 new incident-shaped contract tests (the regression guardrail for a defect that has recurred):
- `SessionWatchManagerTerminalEdgeTests` (10): duplicate suppression; edge re-arm; **incident replay edge-only** (running, completed×3, running×2, completed → exactly 2 terminals); **incident replay quarantined** (first completed → zero terminal frames, running recovery emitted; genuine final → exactly 1); quarantine fail-open; failed-bypass; targeted subscribe catch-up; demotion/revalidation resume; expired retirement; unsubscribe-during-in-flight-wait no-resurrection.
- `AgentRunSnapshotPrecedenceTests` (3): precedence table; `followup_pending` round-trip; op=poll returns running (not stale terminal) during a successor window.
- `RemoteTerminalSettlementReversalTests` (8): settle+revert; full incident cycle; real-results-untouched; re-settle path; host-result-overwrites-synthetic; no-coordinator-memory revert (teardown/re-attach); running→running no-scan; discovery debounce.
- `ContextBuilderRemoteCardTests` (2): remote phase helper; local detail-line byte-identical pinning.
- `PushTriggerTests` (+1): quarantine delays but never loses the sessionTerminal push.

Validation: SwiftFormat + `swiftlint --strict` clean; all three products (`RepoPrompt`, `repoprompt-mcp`, `repoprompt-gateway`) build; all blast-radius suites green; full-suite residuals proven pre-existing/flaky via clean-HEAD worktree baseline. Live host app was never launched, stopped, or relaunched (in active use throughout).

## Next Steps

### Immediate TODOs
- Live smoke of the remote flow (client ↔ gateway ↔ host with a multi-turn context_builder workflow) next time the debug app can be relaunched.
- Follow-up: trigger-conditional watched-membership guard in `validateAndAddSession` for the pollCatchUp/revalidation stale-iteration window (pre-existing, ~3 lines + mid-loop-unsubscribe test).
- Fix 5 (deferred): faithful CB sub-run model on the wire — requires DTO + persistence budget + transcript XML export + projector changes together (a DTO field alone is invisible remotely; results are reduced to minimal status JSON).
- Capture a screenshot + raw frame payloads on the next occurrence of the literal "completed ()" string — exhaustively proven absent from native sources/PWA; likeliest data-origin.
- Doc note: `status=completed` is turn-scoped on the wire; quarantine delays genuine completion notifications/push wakes by ≤5 s.

### Technical Debt Introduced
- Synthetic-settlement markers do not survive app restart (persisted `.toolCall` items drop `toolResultJSON`) — accepted, documented next to the marker constant; self-heals via terminal→active cycles and re-projection.
- Quarantine adds a bounded (≤5 s) delay to genuine terminal notifications for all remote observers.

## Session Metrics
- **Files Changed**: 17 (13 modified, 4 new test files); ~+1,530 / −100 lines
- **Components Affected**: RepoPromptGateway (SessionWatchManager), host MCP agent layer (AgentRunMCPToolService/Snapshot), remote client coordinator, Context Builder tool cards
- **Agents used**: 1 explore (git archaeology), 1 pair investigator, 3 parallel engineers, oracle (plan + 2 review rounds)

## Lessons Learned
- Turn-scoped vs. session-scoped status must be explicit on any wire protocol; a relay cannot infer finality from `status=completed` alone.
- Dedupe must key on transitions, not values — per-status dedupe silently swallows legitimate repeat states after a cycle.
- "Recovery by accident" (spurious re-polls delivering the resume frame) is a trap: removing the spam without adding deterministic resume detection would have made the bug worse.
- For destructive client-side inference (synthetic settlement), always tag the inference so it is distinguishable from ground truth and reversible.
- When a full suite fails after a large change, an isolated `git worktree` at clean HEAD is the cheapest honest baseline for separating pre-existing failures from regressions.

> Generated from Claude Code session on 2026-07-09
