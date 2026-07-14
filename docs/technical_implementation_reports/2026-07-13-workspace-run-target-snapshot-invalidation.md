# Technical Implementation Report - 2026-07-13 - Workspace Run-Target Snapshot Invalidation

## Session Overview

This session fixed a workspace-scoped Agent Mode race where a newly created session could display “Run on: This Mac” after the workspace default had successfully bound the live session to a remote host. Routing was already correct because dispatch reads TabSession.remoteHost, but the cached AgentStatusPillsUIStore projection could remain stale.

The implementation adds durable complete-snapshot invalidation, two regression tests, and selection-dependent Run-on pill chrome. The existing material background remains intact. Oracle reviewed the approach before implementation and approved the completed production change with no blocking or important findings.

No visible app launch or push occurred.

## Implementation Details

### Durable status-pill snapshot invalidation

**Problem Statement:**

createAndActivateSessionTab() can publish a newly linked tab while its TabSession.remoteHost is still nil. The status store can cache .thisMac before the workspace default writes the remote binding. updateBindingsFromSession(_:) previously had no complete status-snapshot fallback, so the cached label could remain local even though dispatch would run remotely.

**Solution Approach:**

AgentModeViewModel.updateBindingsFromSession(_:) now derives one complete status snapshot when status pills are not already invalidated, compares it with the cached snapshot, and inserts .statusPills on inequality:

    if !invalidation.contains(.statusPills) {
        let nextStatusPillsSnapshot = makeStatusPillsSnapshot()
        if ui.statusPills.snapshot != nextStatusPillsSnapshot {
            invalidation.insert(.statusPills)
        }
    }

The comparison runs after active bindings and permission guidance are current, outside withActiveUISyncSuppressed, and before the established syncActiveUIState publication boundary. It does not publish the temporary snapshot directly.

### Run-on pill neutral and selected chrome

**Problem Statement:**

The Run-on control already used ultraThinMaterial. The actual inconsistency was its always-strong outline: local This Mac used the same 0.35-opacity, 0.8-point treatment as a selected remote host, while adjacent neutral controls use a 0.15-opacity, 0.5-point outline.

**Solution Approach:**

Outline styling is now derived directly from props.selection:

    private var outlineColor: Color {
        switch props.selection {
        case .thisMac: Color.secondary.opacity(0.15)
        case .host: Color.accentColor.opacity(0.35)
        }
    }

    private var outlineLineWidth: CGFloat {
        switch props.selection {
        case .thisMac: 0.5
        case .host: 0.8
        }
    }

Foreground behavior, menu semantics, disabled opacity, accessibility text, and ultraThinMaterial remain unchanged.

### Regression coverage

Two focused tests were added:

1. testExplicitNewSessionCreationPublishesWorkspaceDefaultRunLocationSnapshot
   - uses one window ID for Prompt, settings, and Agent Mode;
   - retains a synchronous, window-filtered activeComposeTabChanged subscription;
   - bridges the DEBUG fixture into the same onTabChanged materialization ordering through setAgentModeActive(true);
   - asserts the bridge fired, the live host binding is remote, and the cached complete snapshot matches the derived snapshot without a manual status sync.

2. testUpdateBindingsRefreshesStatusSnapshotForRemoteHostOnlyTransitions
   - establishes a local cached baseline;
   - mutates only session.remoteHost from local to host and back to local;
   - calls updateBindingsFromSession(_:) after each change;
   - verifies revision increases, correct cached selections, a nil local binding, and complete snapshot equality.

The explicit-session test was proven sensitive by temporarily removing only the new production fallback. Conductor ticket b79d6a98-119e-4590-b908-ae513a025d6e failed on stale cached .thisMac and cached/derived snapshot inequality. The production file was restored byte-for-byte before final validation.

## Files Modified

- Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift — guarded complete status-pill snapshot invalidation.
- Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRunLocationPill.swift — selection-dependent neutral versus remote outline.
- Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift — explicit-session and bidirectional host-binding regressions.
- docs/technical_implementation_reports/2026-07-13-workspace-run-target-snapshot-invalidation.md — this report.
- Scripts/source_layout_guardrails.sh — explicitly promoted this report into the durable contributor-facing documentation allowlist.

The two untracked files under docs/investigations were not modified and are intentionally excluded from the commit.

## Technical Decisions

1. **Compare the full derived projection.** AgentStatusPillsSnapshot equality avoids another incomplete hand-maintained dependency list.
2. **Retain the established publication boundary.** The fix inserts invalidation rather than directly updating AgentStatusPillsUIStore.
3. **Do not reorder activation.** Reordering would cross Prompt and Agent Mode ownership and risk hydrated, MCP, handoff, and explicit-local behavior.
4. **Do not add a creation-specific forced sync.** That would fix only one seam rather than the stale-projection class.
5. **Keep material and change only emphasis.** Local uses neutral chrome; selected remote remains visibly accented.
6. **Test integration ordering and the isolated boundary.** V1 covers the user-visible lifecycle and V2 isolates host-only invalidation in both directions.
7. **Promote the requested report explicitly.** Repository policy keeps agent-authored notes local unless each durable document is named in the source-layout allowlist; the user’s request to report and commit made this report an intentional contributor-facing artifact.

## Bug Fixes

### Stale “Run on: This Mac” after successful workspace-default binding

- **Symptoms:** A new workspace-scoped session displayed This Mac even though its authoritative live binding selected the remote host.
- **Root Cause:** Tab activation cached a local snapshot before remote default application, and the subsequent binding update did not invalidate the complete projection.
- **Fix Applied:** Compare cached and newly derived AgentStatusPillsSnapshot values in updateBindingsFromSession(_:) and invalidate status pills on inequality.

### Excess emphasis for the local Run-on state

- **Symptoms:** The local Run-on pill appeared visually stronger than adjacent neutral controls.
- **Root Cause:** Local and remote selections shared one fixed 0.8-point outline derived from the foreground accent.
- **Fix Applied:** Use neutral 0.15/0.5 chrome for .thisMac and accented 0.35/0.8 chrome for .host.

## Challenges Encountered

### The first explicit-session test did not initially prove the race

- **Context:** PromptViewModel and the DEBUG AgentModeViewModel initially used different window IDs.
- **First Attempt:** Sharing the window ID still allowed the exact V1 test to pass with the production fallback removed.
- **Cause:** The DEBUG initializer injects Prompt/workspace dependencies after initialization and does not install the production activeComposeTabChanged observer.
- **Resolution:** A targeted read-only probe identified a bounded test-only bridge: retain a synchronous, window-filtered notification subscription and call setAgentModeActive(true), which invokes the same onTabChanged materialization path. The strengthened V1 then failed pre-fix on the intended stale projection assertions.

### Preserving the production fix during sensitivity testing

- **Context:** The regression needed evidence that it fails without the new fallback.
- **Resolution:** The implementer recorded the production file hash, temporarily removed only the six-line fallback, ran the exact V1 test through conductor, restored the file immediately, and verified SHA-256 6f872bee21119c2c4a3d12156555dd444e403c011efd2fead9201012825eeec1.

### Separating label state from routing authority

- **Context:** Workspace scope, cached UI state, and live session binding could be mistaken for competing routing sources.
- **Resolution:** The implementation preserved TabSession.remoteHost as the routing authority. Dispatch, persistence, eligibility, and one-shot workspace defaults were not changed.

## Code Quality Improvements

- Replaced an implicit, incomplete invalidation dependency list with equality against the complete derived status snapshot.
- Added assertions against the cached UI store rather than only direct props helpers.
- Added bidirectional host/local transition coverage and store-revision assertions.
- Kept the styling change in small named computed properties.
- Preserved existing one-shot, explicit-local, revoked-host, hydrated-session, and MCP-session behavior.

## Testing

### Pre-fix sensitivity evidence

- make dev-test FILTER=AgentRunLocationTests — expected V2 failure, ticket bdfecb66-898f-418c-92fa-0c94bf693dd5.
- Exact strengthened V1 with only the production fallback temporarily removed — expected failure, ticket b79d6a98-119e-4590-b908-ae513a025d6e.

### Final coordinated validation

- make dev-format — **PASS**, ticket 97f7102c-1229-4a8b-9570-be8ce1e57101.
- make dev-test FILTER=AgentRunLocationTests — **PASS**, ticket 16aabae6-f726-46db-87f3-86d0513a7fd6; 13 tests, 0 failures.
- make dev-test FILTER=AgentRunLocationHostOptionAbbreviationTests — **PASS**, ticket 075bf908-904f-418c-aae3-eea7d4d65074; 7 tests, 0 failures.
- make dev-lint — **PASS**, ticket 2be329c3-e872-4d9f-a04e-bf95b2bb5546.
- make dev-swift-build PRODUCT=RepoPrompt — **PASS**, ticket e074bc14-a674-4221-b1ca-8a0d5ae19830.
- make dev-smoke — **PASS**, ticket 0dcd465e-ab9d-44ac-bf68-cfcacccb5060; the CE debug app and CLI were already available, and no lifecycle action was performed.
- Protected investigation-report hash/status check — **PASS**; both reports remain unchanged, untracked, and unstaged.

Oracle’s final review verdict was **APPROVED**. Its P2 test-harness observation led to the strengthened V1.

## Performance Impact

The fallback adds one synchronous complete status-snapshot derivation only when .statusPills has not already been invalidated. This includes existing remote-host registry reads and execution-location derivation. No benchmark was required or run; the guard avoids duplicate derivation when a status refresh is already scheduled.

No persistence, network, dispatch, or protocol behavior changed.

## Next Steps

### Immediate TODOs

- Stage only the three Swift files, this report, and its explicit source-layout allowlist entry.
- Run the mandatory staged-index contribution preflight before committing.

### Technical Debt Introduced

- None known.
- Residual risk is limited to unbenchmarked synchronous snapshot derivation and source-level rather than pixel-rendered verification of existing SwiftUI primitives.

## Session Metrics

- **Duration:** Approximately 1 hour.
- **Files Changed Before Report:** 3 Swift files; final commit scope also includes this report and one guardrail allowlist entry.
- **Code Diff Before Report:** Approximately +102/-4 lines.
- **Tests Added:** 2.
- **Components Affected:** Agent Mode binding synchronization, status-pill UI store, Run-on pill styling, and Agent Run Location tests.
- **Workers Used:** contract writer, verifier designer, implementer, and targeted read-only probe.
- **Oracle Consultations:** pre-implementation plan review and post-implementation code review.

## Lessons Learned

- UI projection stores need tests against cached snapshots; direct helper assertions can miss lifecycle invalidation defects.
- A production-looking test can pass vacuously when DEBUG initialization omits observer installation.
- Full derived-value equality is safer than adding one more field to an incomplete invalidation list when projection dependencies span multiple subsystems.
- A stale local label does not imply local routing when the UI cache and authoritative session binding are separate state layers.
- Styling investigations should distinguish a missing layer from opacity and line-width differences before changing the component hierarchy.

> Generated from the implementation session on 2026-07-13 (Asia/Ho_Chi_Minh).
