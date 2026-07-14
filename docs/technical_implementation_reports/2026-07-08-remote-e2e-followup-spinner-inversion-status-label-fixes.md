# Technical Implementation Report - 2026-07-08 - Remote E2E Follow-up Fixes: Tool-Card Status Inversion, Orphaned Rows, Thinking Label

## Session Overview

Deep-investigation → oracle-planned implementation → oracle-review → hardening cycle for three NEW remote-control (native client ↔ gateway ↔ host) symptoms observed in the first e2e run after the c2eefef fixes (remote session `25E5D2C5-BAA1-4221-BD06-66AE340A2586`, 2026-07-08 ~16:56–17:10, provider codexExec):

- **N-A (not a bug)**: the first user message produced 2 assistant responses on both host and client.
- **N-B (bug)**: a ~12-minute `context_builder` tool call ended up as a lingering green **Completed** card on the client while the host tool was actually **cancelled**.
- **N-C (gap)**: the client showed a generic "Running on Tuan's Mac" while the host showed "Thinking…".

The investigation (report: `docs/investigations/remote-e2e-followup-duplicate-response-spinner-inversion-status-label-2026-07-08.md`, local/git-excluded) was orchestrated with one pair investigator, an oracle chat spanning plan/review modes, and decisive out-of-band evidence from the Codex rollout file. Implementation ran as three file-disjoint engineer workers plus a ledger worker, all validated through the lane-serialized conductor daemon; the live CE debug app was never stopped or relaunched.

## Root Causes (established before implementation)

- **N-A — expected behavior.** The first turn legitimately contains assistant → hidden `set_status` → assistant (Codex rollout shows `set_status` at 09:56:40.6Z between the two texts). `set_status` is in `hiddenTranscriptToolNames` and dropped at append time, so no tool card separates the two texts anywhere. On Codex, `sealAssistantBoundary` ran before the hidden-tool guard, guaranteeing two distinct rows; a characterization test later proved the split happens at provider-item level regardless (a `function_call` terminates the assistant message item), so two-message first turns are documented-expected.
- **N-B — terminal-time status inversion, four links.** Rollout evidence: the `context_builder` MCP call stayed in-flight 701.7 s and returned `Error: MCPToolExecutionCancelledError()`; no mid-run result ever existed (the prior mid-run-fabrication hypothesis was refuted — the card correctly spun mid-run). Chain: (1) host marks the tool failed; (2) `groupedHistoryToolPreviewItem` prunes failed/cancelled **non-spawn** previews from the spartan export; (3) the client's positional row ID (`turnOffset:index|kind|toolName`) is re-occupied by the final assistant, orphaning the card (upsert never deletes); (4) the client terminal settle stamps the **session's** "completed" onto the unreported **tool** row → green Completed, lingering forever.
- **N-C — client-side drop of an available signal.** The host serializes `runningStatusText` as `status_text` (`AgentModeViewModel.mcpSnapshot` → `AgentRunMCPSnapshot.asObject`); the gateway forwards the payload opaquely; the native client's `projectSnapshot` never read it and `applyRunState` hardcoded "Running on \<host\>…".

## Implementation Details

### F1 — Host: spartan export preserves failed/cancelled non-spawn tool previews

**Problem Statement:** `groupedHistoryToolPreviewItem` returned nil for `.failed`/`.cancelled` executions unless spawn-family (`agent_run`/`agent_manage`), so a cancelled `context_builder` vanished from the final get_log page — both untruthful and the trigger for client-side index churn/orphaning.

**Solution Approach:** In spartan/get_log mode the prune is skipped entirely (spawn or non-spawn); the existing status mapping emits `<tool_result … status="failed"/>`. Handoff/fork exports keep pruning unchanged. The parameter was renamed `allowFailedSpawnFamilyPreview` → `preserveFailedToolPreviews` since it no longer expresses spawn-family-only. Grouped-history (compacted) blocks were deliberately left spawn-only (oracle-scoped: old turns are never re-fetched; budget interactions).

This also fixes index stability: the failed row keeps its positional index, so the final assistant lands at the next index instead of re-occupying the tool's slot.

### F4 — Host: preview defaults can never fabricate success

`toolExecution?.status ?? .success` → `?? .pending` in both `groupedHistorySpawnToolPreviewItem` and `groupedHistoryToolPreviewItem`, with invariant comments (the default is near-dead code — `toolExecution(for:)` never returns nil for toolCall/toolResult rows — kept as a guard so a missing execution yields no `<tool_result/>` rather than success). The `.unknown→success` mapping in `forkTranscriptToolResultStatusWord` was **deliberately kept and documented**: plain-text completed tool payloads (e.g. apply_edits markdown) normalize to `.unknown`, and a `.toolResult` row's existence is itself the completion signal — the oracle's earlier `.unknown→nil` idea was explicitly superseded (it would regress most completed remote cards into spinners).

### F3/F3b — Client: orphan reconciliation + terminal-settle re-read range

**Problem Statement:** `RemoteTranscriptProjector.upserting` never deletes; rows that disappear from a later export are orphaned, and the terminal settle then stamps them with the session outcome.

**Solution Approach (oracle-designed):** a controller-side registry — sequenceIndex-derived turn membership was rejected in design review (sequenceIndex encodes the *first page offset* a row was projected from; optimistic rows can collide numerically).

- `RemoteAgentSessionController` gains `projectedRowIDsByPageOffset: [Int: Set<UUID>]`, `lastCompletePageOffset: Int?`, `lastLegacyAdvanceOffset: Int?`, reset on cursor reset. Parked pages **union**-register their projected IDs (a row vanishing between parked pages stays remembered); complete/mixed/terminal-settle pages compute `removals = registry[offset] − incomingIDs`, replace the entry, and record `lastCompletePageOffset`; legacy pages (no `completed_turn_count`) register as parked and never remove.
- The transcript-rows event now carries `{ items, removedIDs }`; the coordinator pipeline is **remove → upsert → settle** inside one `mutateItemsBatch`. `removedIDs` can only contain projector-created IDs, so optimistic/local rows are structurally safe.
- **F3b:** the one-shot terminal-settle re-read (c2eefef) re-fetched `nextLogOffset − 1, limit 1`; if the last complete page covered multiple turns this re-seeded rows under different IDs (latent duplicate bug) — it now re-fetches `lastCompletePageOffset` with the exact covered range, and skips on fresh terminal attach with no advancement.
- **Legacy heal (oracle review P1):** legacy hosts advance the cursor through parked pages, so `lastCompletePageOffset` stays nil and the skip would have silently disabled the S-A truncation heal for them. Fixed: when legacy advancement happened this controller lifetime, the old `max(0, nextLogOffset − 1), limit 1` re-read runs with parked (upsert-only, no removals) semantics.

### F2 — Client: settle semantics locked, not changed

Design review chose to keep `terminalSettlement(for: "completed") = ("completed", false)`: `"interrupted"` normalizes to cancelled → error rendering, and on pre-c2eefef hosts every completed tool card is result-less at terminal — an error-ward settle would turn all of them red. With F1+F3, the inversion window is bounded and self-healing (failed folds overwrite; orphans are removed). Contract tests lock the mappings.

### F6 — Client: consume `status_text` for the running label

`RemoteProjectedSnapshot` gains `statusText` (parsed from `status_text`, trimmed, empty→nil); threaded through the controller's runState event; `applyRunState` uses it **only in the `.running` branch** with the existing "Running on \<host\>…" as fallback (host puts failure prose/"Queued to start" in `status_text` for non-running states, which must not surface as running labels). No gateway or wire-schema change — the field was already shipped end-to-end.

### F5 (reduced) — Host: hidden Codex tracker tools flush-only

A naive guard hoist (hide before seal, matching Claude/ACP) was rejected in design review: skipping the seal skips the pending-delta flush (visible truncation when `wait_for_next_user_instruction` parks the session) and the pending-scope clear (745d856-class late-`assistantCompleted` hazard). The characterization test proved the two-message first turn happens at provider-item level regardless, so the reorder had risk without benefit. Landed instead: hidden tools call `flushPendingAssistantDelta` only (which itself bumps the flush generation and requests presentation refresh — verified at `CodexAgentModeCoordinator.swift:4948-4954`), skipping segment seal and scope clear; visible tools unchanged.

**Files Modified:**
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift` — F1 spartan prune removal + param rename; F4 `?? .pending` defaults; `.unknown→success` doc comment; DEBUG status-mapper test hook
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` — F3 registry + reconciliation; F3b ranged/legacy terminal-settle re-read; restart-gap comment
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteTranscriptProjector.swift` — F6 `statusText` parse
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` — F3 remove→upsert→settle pipeline; F6 running-label consumption; enriched event sweep
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` — F5 hidden-tool flush-only branches (call + result paths); DEBUG tracker test hooks
- `Scripts/Fixtures/test-suite-contract-ledger.tsv` — 25 new `retain` rows + 1 in-place rename + 14 symptom-label corrections
- Tests: new `AgentTranscriptStandaloneToolSpartanExportTests` (7), new `RemoteAgentClientFixesTests` (13), new `CodexAgentModeCoordinatorHiddenToolBoundaryTests` (4), `RemoteAgentSessionControllerSettleTests` (+legacy-heal test, renamed attach-skip test, de-flaked negative assertion), `RemoteAgentSessionTests` (legacy terminal fetch expectation updated to the restored heal: 2 fetches, offsets [0,0], limits [20,1])

### Technical Decisions

- **Investigation before design**: the Codex rollout file (`~/.codex-auth-switcher/.../rollout-2026-07-08T16-56-32-….jsonl`) refuted the leading mid-run-fabrication hypothesis with hard timestamps — the whole N-B fix shape (terminal-time inversion, not mid-run emission) came from that evidence.
- **Registry over arithmetic**: reconciliation identity from what the projector actually emitted per page offset, not reconstructed from sequenceIndex.
- **Session outcome ≠ tool outcome, but compat wins**: settle stays success-shaped because old hosts offer no truthful alternative; honesty is restored upstream (F1) and via deletion (F3).
- **Characterize before reordering**: the N-A guard reorder was gated on a characterization test that ended up proving it pointless; only the risk-free flush fix landed.
- **Accepted, documented limitations**: orphan registry is per-controller-lifetime (client restart mid-run cannot diff persisted parked rows); legacy heal is same-lifetime only; modern attach-time re-read traded away to avoid duplicate-ID re-seeding.

## Bug Fixes

**Oracle review P1 — legacy-host truncation heal regression (caught before merge):**
- **Symptoms**: none yet shipped — found by adversarial review of the F3b skip guard.
- **Root Cause**: `lastCompletePageOffset` is only set by complete pages; legacy hosts never produce one, so the new skip disabled the c2eefef S-A heal for them.
- **Fix Applied**: legacy-advancement tracking + parked-mode single-turn fallback re-read; regression test `testLegacyTerminalSettleReReadHealsTruncatedFinalAssistantWithoutRemovals`; the pre-existing `testSessionTerminalTriggersFinalLogFetch` (legacy-shaped fixture) was updated to expect the restored two-fetch pattern.

## Challenges Encountered

- **Reconciling the user's timing observation with evidence**: "Completed almost immediately" conflicted with code + rollout proof that no mid-run result existed; resolved by attributing it to the adjacent green apply_edits card and/or post-hoc observation of the lingering orphan — while showing the defect (wrongly-green, lingering card) is real either way.
- **Disk filled mid-validation** (W-CLIENT): resolved with an approved `make clean`; focused tests re-ran green after rebuild.
- **Sequenced validation across concurrent workers**: combined suite runs only after the wave settled (per the prior TIR's lesson); one legacy-fixture test surfaced only in the combined re-run.

## Testing

- 26 new tests; combined focused filter (`AgentTranscriptStandaloneToolSpartanExportTests|AgentTranscriptGroupedHistorySpawnExportTests|RemoteAgentClientFixesTests|RemoteAgentSessionControllerSettleTests|RemoteAgentSessionTests|RemoteTranscriptProjectorTests|CodexAgentModeCoordinatorHiddenToolBoundaryTests|CodexAgentModeCoordinatorLivenessTests`) green: **135 tests, 0 failures**.
- SwiftFormat applied; SwiftLint strict 0 violations in 1505 files; `RepoPrompt` product builds via the coordinated daemon.
- Ledger: `verify-ledger` returns exactly the pre-existing baseline drift (missing=195 stale=3); all 26 new IDs present; rename handled in place (`…ReReadsLastConsumedTurnOnce` → `…SkipsTerminalSettleReReadWithoutAppliedCompletePage`).

## Oracle Review

Plan mode pre-review reshaped three of six fixes (F2 → no-op + contract lock; F3 → registry design + required F3b; F5 → flush-only gated on characterization) and rejected one (`.unknown→nil`). Post-implementation review of the full diff: **no P0; 1 P1; 5 P2** — all applied or verified-no-change (flush refresh already present; 14 ledger labels fixed; restart-gap and attach-trade documented; flaky sleep assertion replaced). Final oracle verdict: "solid to hand back"; its last verification ask (attach-skip test scripts a true empty page, `returned: 0`) confirmed empirically.

## Next Steps

### Immediate TODOs
- Live e2e re-validation (MacBook Pro ↔ Mac Studio) after relaunching the host app: cancelled tools show red Failed cards that persist correctly; no lingering Completed orphans; client shows "Thinking…" during reasoning.
- Consider persisting projected-row tags so orphan reconciliation survives client restarts (documented gap).

### Technical Debt Introduced
- Orphan-reconciliation registry and legacy heal are per-controller-lifetime (documented in code + investigation report).
- The remote projector still regex-parses spartan XML; F1/F6 extend rather than replace that contract.

## Session Metrics
- **Files Changed**: 12 (5 source + 4 test files (3 new) + ledger + TIR + local investigation report)
- **Lines Modified**: ~+1,390 / −67 (incl. 1,040 lines of new tests)
- **Components Affected**: AgentMode transcript export (AgentTranscriptServices), remote runtime (controller/projector), remote coordinator, Codex coordinator, contract ledger
- **Delegated workers**: 3 engineer implementation sessions + 1 ledger session + 1 pair investigator + oracle chat (plan → review → confirm); all builds/tests via the lane-serialized conductor daemon; live app untouched

## Lessons Learned
- Provider-side artifacts (Codex rollouts) can settle in minutes what code reading cannot: exact tool-call wall time and error payloads refuted the leading hypothesis and redirected the entire fix design.
- Adversarial review of a "skip" guard pays off: the F3b skip was correct for modern hosts and silently catastrophic for legacy ones — the P1 existed only in the untested matrix cell (legacy × terminal).
- When a fix's honesty depends on the other end of a wire (settle semantics vs old hosts), prefer restoring truth at the source and deleting stale state over guessing a better lie locally.

> Generated from Claude Code session on 2026-07-08
