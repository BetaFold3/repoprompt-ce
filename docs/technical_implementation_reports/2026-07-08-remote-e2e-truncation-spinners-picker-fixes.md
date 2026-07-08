# Technical Implementation Report - 2026-07-08 - Remote E2E Fixes: Final-Message Truncation, Tool-Card Spinners, Workspace Picker

## Session Overview

Implementation → oracle-review → hardening cycle for three remote-control (client ↔ gateway ↔ host) defects observed in a single native-client e2e run on `feat/remote-client-native` (remote session `47A452DA-7BD4-4881-B8CE-4D12DFF3EBBD`, 2026-07-08 ~12:52–13:03). Root causes were established in a prior deep-investigation session (`docs/investigations/remote-e2e-truncation-spinners-picker-2026-07-08.md`, local artifact); this session implemented all of that report's recommendations via five file-disjoint delegated engineer workers, ran a full oracle review of the diff (no P0, 2 P1, 8 P2), applied every finding via four more workers, and empirically verified both P1 remedies (including a red-then-green check of the presentation regression test).

The three symptoms:

- **S-A (bug)**: final assistant message truncated on the client (~125 chars, mid-word) while the host transcript was complete.
- **S-B (bug)**: tool-call cards spun forever on the client after run completion.
- **S-C (bug)**: workspace picker prompted on the first remote message despite the 2026-07-06 auto-derivation hardening.

A bonus outcome: validation surfaced a **real production race** in the new Codex terminal-settle path (late `assistantCompleted` scope-rejected after the authoritative turn cleared), fixed and regression-tested in-session.

## Implementation Details

### S-C — Gateway binding-probe truthfulness + ungated workspace auto-match

**Problem Statement:** `AppLinkPool.defaultBindingProbe` falsely returned `.bound` both on unrouted `list_sessions` success and on transport errors; the result was cached and fast-pathed by `resolveAppLink`, and workspace auto-match was gated on `bindingState != .bound` — so a multi-window host with a stale false-`.bound` link sent starts unrouted, surfacing `ambiguous_start_target` → the client's workspace picker.

**Solution Approach:**
- Probe rewritten to use `bind_context op=list`: multi-window unbound ⇒ `.bindingRequired`; transport/tool-unavailable ⇒ a permissive *unknown* state that is never cached as durable `.bound` and refreshes on the next resolve.
- `GatewayRuntime`: workspace auto-match for starts carrying workspace selectors is no longer skipped when the binding looks bound; the `refreshedBindingState != .bound` retry gate was relaxed; auto-routed starts audit a workspace match count. New `transcript_xml_chars` field on get_log audit records for future forensics.
- Review hardening (P2): unknown-probe **cooldown** (4s, monotonic `systemUptime`, injectable clock) plus a shorter refresh-path probe timeout (2s vs 10s initial-connect) so a degraded link doesn't pay a 10s probe before every remote command.

### S-B — Paired `<tool_result/>` emission + client fold + terminal settle

**Problem Statement:** The spartan get_log XML emitted `<tool_call>` previews but discarded result status entirely (`case .toolResult, .thinking: break`), and the client resolver (`ToolCallCardStateResolver.status(for:)`) returns `.running` whenever `toolResultJSON == nil && toolIsError == nil` — a deterministic design gap: remote tool cards could never settle.

**Solution Approach:** Three cooperating layers, deliberately backward-compatible in both directions:
- **Host** (`AgentTranscriptServices`): emits `<tool_result name="…" status="success|failed|warning"/>` as a separate self-closing element immediately after the matching `<tool_call>` (an attribute on `tool_call` would have broken the old-client regex), for both synthesized previews and raw `.toolResult` rows; the pair is budget-dropped atomically.
- **Client** (`RemoteTranscriptProjector`): parses `<tool_result/>` and folds status into the immediately preceding matching `.toolCall` (via `minimalResultJSON` + `toolIsError`) **without consuming a positional row index**, preserving deterministic row-ID parity against old hosts.
- **Client fallback** (`RemoteAgentModeCoordinator`): result-less toolCall items settle at terminal (both in `applyTerminal` and in post-terminal `applyTranscriptRows`, since the terminal event arrives before the final rows), never overwriting explicit results — so new clients against old hosts also stop spinning.
- Review hardening (P2): running/pending tool status emits **no** `<tool_result/>` (spinner correctly preserved mid-run); tool names XML-escaped (`& < > "`) in both elements, round-tripping through the projector's existing entity decode; cancelled/failed runs settle result-less cards as *failure*, not green success.

### S-A — Terminal-settle re-read + host get_log catch-up + Codex bounded settle

**Problem Statement:** Audit evidence (gateway `completed_turn_count` series, including a transient steer-instant blip) proved a boundary-window class where the client consumed a final page whose trailing assistant text was partial, with no mechanism to ever re-read it (~80% client-side loss of a full final page, ~10% Codex partial-at-terminal).

**Solution Approach:** Defense in depth across all three actors:
- **Client** (`RemoteAgentSessionController`): one-shot terminal-settle re-read of `max(0, nextLogOffset - 1)` after terminal paging and on terminal `attachAndCatchUp`; `isShutdown` re-checked after `fetchLogPage` returns before emit/advance. Review hardening (P2): the one-shot flag is set only after a *successful* fetch, so a transient transport error no longer permanently skips the heal.
- **Host** (`AgentManageMCPToolService.executeGetLog`): sessions with non-active runState force the derived transcript current (`ensureDerivedTranscriptCurrentForExport`) and re-read transcript/runState before serialization — closing the proven `completed_turn_count` boundary-blip class. Review cleanup: redundant second `ensureSessionReady` removed; safety comment documents that `canReuseDerivedTranscriptForSave` makes the force-current a no-op when already synchronized.
- **Producer** (`CodexAgentModeCoordinator`): bounded terminal settle — a normal `.completed` `turnCompleted` while the assistant row is still streaming (no observed `assistantCompleted`) defers `finalizeCodexRun` until the matching `.assistantCompleted` or ~1.75s timeout; cancel/error/interrupted finalize immediately.

**Key Code Changes:**

```swift
// AgentModeViewModel.swift — export catch-up + active-tab presentation republish (P1-2 remedy)
@discardableResult
func ensureDerivedTranscriptCurrentForExport(tabID: UUID) -> Bool {
    guard let session = sessions[tabID] else { return false }
    let publishActivePresentation = canBuildOrPublishActiveTranscriptBindings(for: session)
    let didRefresh = catchUpDerivedTranscriptIfNeeded(
        for: session,
        reason: .saveSession,
        publishActivePresentation: false
    )
    if publishActivePresentation {
        updateBindingsFromSession(session)
    }
    return didRefresh
}
```

```swift
// CodexAgentModeCoordinator.swift — commit-before-next-turn invariant (P1-1 remedy)
case let .turnStarted(turnID):
    await completePendingCodexTerminalSettleIfPresent(
        session: session,
        trigger: "turn-started"
    )
    cancelCodexIdleShutdown(for: session.tabID)
    clearStaleCodexPendingInteractionsForNewTurn(turnID, session: session)
    guard let turnKind = installAuthoritativeCodexTurnForStart(...)
```

### Technical Decisions

- **Separate `<tool_result/>` element, not a `tool_call` attribute**: the old-client regex requires `name` to be `tool_call`'s only attribute; a new self-closing element matches no old alternation, so old clients skip it with zero row-index/ID impact.
- **Fold without index consumption**: the projector's deterministic positional row IDs (`remote-transcript-row-v1|session|turnOffset:index|kind|tool`) must stay identical whether or not `<tool_result/>` elements are present, or upserts against old hosts would duplicate rows.
- **Complete, don't cancel, the pending settle on `turnStarted`** (oracle P1-1): cancelling silently dropped the terminal commit barrier, waiters, providerSuccessor, and queued follow-up draining. Completing with partial text preserves the pre-change commit-before-next-turn invariant.
- **Whitespace→`_` tool-name sanitizer contract kept**: escaping covers only `& < > "`; the pre-existing upstream sanitizer defines the persisted-name contract, and the hostile-name test asserts the sanitized+escaped form.
- **Ledger maintenance stayed surgical**: 35 appended rows + 1 in-place rename; the known pre-existing drift (missing=195 stale=3) was deliberately left untouched.

## Bug Fixes

**Production race found during validation** (beyond the three target symptoms):
- **Symptoms**: `testTurnCompletionWaitsForLateAssistantCompletionBeforeTerminalCommit` failed only in combined-suite runs.
- **Root Cause**: the deferred finalize path cleared `codexAuthoritativeActiveTurn`, so the late `.assistantCompleted` was rejected by `codexEventScopeMatches` — a real race, not test flake.
- **Fix Applied**: scope matching accepts events matching the pending settle's exact assistant `ItemScope`; review hardening added a threadID equality guard and non-empty turn/item-ID requirements to that early-accept (stale cross-conversation replay defense, 745d856 incident class).

**Test-only flake**: `RemoteAgentSessionControllerSettleTests` asserted recorder state before its `AsyncStream` consumer task had drained; fixed with continuation-backed batch waits (same pattern applied to one pre-existing test).

## Challenges Encountered

- **Concurrent workers vs. shared checkout**: wave-3 workers G and I could not get green focused runs because sibling workers' in-flight test edits transiently broke compilation; resolved by re-running after the wave settled and steering Worker I to finish validation (its two new tests initially failed on real contract mismatches: the synthesized-preview path bypassed the nil-status change, and the whitespace sanitizer surprised the hostile-name expectation).
- **Proving the P1-2 regression test is not illusory**: per the oracle's caution, the republish call was temporarily disabled (`if false && publishActivePresentation`), the test confirmed **red**, then restored and confirmed **green** — the coverage is real.

## Testing

- 35 new/updated tests across 7 suites; combined filter (`GatewayRuntimeBindingTests|GatewayAppLinkPoolTests|RemoteTranscriptProjectorTests|AgentTranscriptGroupedHistorySpawnExportTests|RemoteAgentSessionTests|RemoteAgentSessionControllerSettleTests|CodexAgentModeCoordinatorLivenessTests`) green in repeated conductor runs, re-verified after formatting (158 tests in these suites, 0 failures).
- New suite `RemoteAgentSessionControllerSettleTests` (5 tests) covers the terminal-settle re-read, shutdown-after-fetch, export force-current presentation republish, and transient-failure retry.
- Both products (`RepoPrompt`, `repoprompt-mcp`) build via the coordinated daemon; SwiftFormat applied (2 files); SwiftLint strict 0 violations in 1502 files.
- Ledger: `verify-ledger` returns exactly the pre-existing baseline drift (missing=195 stale=3); all 35 new IDs present; rename handled in place (`…SkippedWhenBound` → `…SkippedForExplicitWindowID`).

## Oracle Review

Full-diff review (snapshot `2026-07-08/1539`): **no P0; 2 P1; 8 P2** — all applied. Final oracle verdict after fixes: “both P1s fully addressed; no residual holes,” with its two requested spot-checks (inline `await` ordering in `turnStarted`; pre-fix redness of the presentation test) confirmed empirically in-session.

## Next Steps

### Immediate TODOs
- Live e2e re-validation with the native remote client (MacBook Pro ↔ Mac Studio) once convenient: confirm final-message completeness, settled tool cards, and no workspace picker on first message.
- Consider the still-deferred P1 from 2026-07-06 (gateway-principal PRIORITY 3 single-window auto-bind persistence) — explicitly out of scope per prior user instruction.

### Technical Debt Introduced
- The remote projector still regex-parses spartan XML; the new `<tool_result/>` element extends, rather than replaces, that contract.
- The 1.75s Codex settle timeout is a heuristic; if provider latencies change, revisit.

## Session Metrics
- **Files Changed**: 18 (17 modified + 1 new test file)
- **Lines Modified**: ~+1,720 / −72 (plus 518-line new test file)
- **Components Affected**: RepoPromptGateway (AppLinkPool, GatewayRuntime, RemoteAuditLog), AgentMode runtime (Codex coordinator, remote controller/projector, transcript services), AgentMode view models (AgentModeViewModel, RemoteAgentModeCoordinator), MCP agent service, 7 test suites, contract ledger
- **Delegated workers**: 10 engineer sessions (5 implementation, 4 review-fix, 1 ledger), all validated through the lane-serialized conductor daemon

## Lessons Learned
- Combined-suite runs catch what focused runs cannot: both a real production race and an AsyncStream test-timing bug appeared only under combined load.
- When multiple workers share a checkout, sequence their *validation* even if their *edits* are file-disjoint — in-flight test edits break sibling compiles.
- Oracle P1s deserve empirical closure: the red-then-green revert check took two minutes and converted “should be fixed” into “provably fixed.”

> Generated from Claude Code session on 2026-07-08
