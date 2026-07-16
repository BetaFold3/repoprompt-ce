# Technical Implementation Report - 2026-07-16 - Remote Command-Tail Stale Recovery

## Executive Summary

This session investigated and fixed a remote Agent Mode client stall where the host completed and displayed an AI response while the client remained on an `Initializing…` transcript row indefinitely.

**Observed in session and code:** the client stale-observation watchdog stopped when the first turn became terminal. A later `steer`, `respond`, or `cancel` could return the session to an active state and perform one immediate catch-up, but a still-incomplete log page parked without re-arming the watchdog. If push frames were also absent, no wake-up source remained.

The implementation registers command-tail observation progress for all three state-mutating commands. It reuses the existing `recordStaleObservationProgress` authority rather than adding another timer or polling loop. Deterministic tests cover the original steer failure, uncertain mutation outcomes, already-resolved interactions, cancellation, terminal shutdown, and no command resend.

**Observed in user validation:** the original stuck-session scenario now works. The user also reported that the client can no longer see or select models for execution on the remote host. That regression was not investigated in this session, and its causal relationship to this patch is unknown.

## Evidence and Limitations

- Session context available: **Yes**, including host/client logs, investigation findings, implementation discussion, Oracle plan/review, test results, and user validation.
- Git baseline available: **Partial**. The current implementation is an uncommitted diff on top of `14d32316`; the broader branch contains earlier remote-control work not attributed to this session.
- Validation evidence available: **Yes**, including deterministic XCTest results, formatter runs, Oracle review, and user manual validation.
- Report scope: the two implementation files, this report, and directly relevant session evidence.
- Known limitation: the reported remote model visibility/selection regression has not been reproduced or traced. It is recorded as a follow-up, not assigned a root cause here.
- Sensitive host/device/session identifiers from incident logs are intentionally omitted.

## User Intent and Scope

The user requested:

1. Investigate why the client stayed on `Initializing…` although the remote host completed the response.
2. Implement a robust client-side fix with regression tests.
3. Use a delegated worker and consult Oracle before and after implementation.
4. After manual validation, document the work and commit it even though a smaller remote model-selection regression remains.

Scope was deliberately limited to the client session controller and its deterministic tests. Gateway push diagnostics, protocol changes, and the newly reported model-selection regression were not folded into the fix.

## Change Inventory

| Git Status | Index / Worktree State | File | File Role | Purpose | Evidence / Notes |
|---|---|---|---|---|---|
| Modified | Unstaged before commit preparation | `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift` | Source | Re-arm stale observation recovery at state-mutating command tails | Three defer registrations reuse the existing progress authority |
| Modified | Unstaged before commit preparation | `Tests/RepoPromptTests/AgentMode/RemoteAgentSessionTests.swift` | Test | Add deterministic command-tail recovery coverage and queued command errors | Focused suite passed 64 tests |
| Added | Untracked before commit preparation | `docs/technical_implementation_reports/2026-07-16-remote-command-tail-stale-recovery.md` | Documentation | Preserve implementation rationale, validation, risks, and follow-up work | This report |
| Modified | Unstaged during commit preparation | `Scripts/source_layout_guardrails.sh` | Guardrail | Promote this requested durable report into the explicit tracked-doc allowlist | Required by commit preflight; no other documentation paths promoted |

Other pre-existing untracked investigation, prompt-export, and agent-artifact files were explicitly outside the intended commit.

## Implementation Details

### Command-Tail Observation Recovery

**Problem / Goal:**
Restore the invariant that an attached active remote session retains a bounded wake-up source after a state-mutating command, even when immediate catch-up parks and no push frame arrives.

**What Changed:**
`steer`, `respond`, and `cancel` now register a deferred call to `recordStaleObservationProgress(reason:)` after shutdown/session guards and before sending the command.

Representative mechanism from `RemoteAgentSessionController.swift`:

```swift
// Register before sending so throw paths also re-arm; .inDoubt catch-up can adopt
// a parked active run before rethrowing.
defer { recordStaleObservationProgress(reason: "steer") }
```

The defer executes on successful completion and thrown exits. The existing authority then:

- increments the stale-progress generation;
- stops any prior stale timer;
- schedules one timer only when the current session remains active, attached, connected, and observation-enabled;
- leaves terminal sessions without a timer;
- defers to transient observation recovery when that subsystem owns liveness.

**Why This Approach:**
**Observed in code and Oracle review:** `recordStaleObservationProgress` already owns deadline reset, generation handoff, terminal suppression, eligibility checks, and single-timer scheduling. Calling it at uncovered command tails is the smallest cause-level fix and avoids a parallel recovery authority.

**Key Files and Symbols:**

- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift`
  - `steer(_:)`
  - `respond(interactionID:payload:)`
  - `cancel()`
  - `recordStaleObservationProgress(reason:)`
  - `scheduleStaleRecoveryIfEligible(reason:)`
- `Tests/RepoPromptTests/AgentMode/RemoteAgentSessionTests.swift`
  - command-tail stale recovery tests
  - `ManualRemoteAgentSessionRecoveryScheduler`
  - `RecordingRemoteAgentSessionConnection`

**Behavior Before:**
After an active-to-terminal transition, stale recovery stopped. A later command could adopt `running`, fetch an incomplete next turn, park at the same log offset, and return with neither a push frame nor a timer to wake the client.

**Behavior After:**
Every state-mutating command tail re-evaluates live controller state. An active attached session receives a fresh bounded stale-recovery deadline; a terminal, detached, paused, replaced, unsubscribed, or shut-down session does not.

### Regression Coverage

The test connection double now accepts queued per-command `RemoteClientError` values. Errors are consumed after recording the frame and before scripted responses, allowing tests to verify error-path behavior and exact send counts.

New deterministic coverage proves:

- terminal → steer → active parked page → timer-driven completion without push;
- `.inDoubt` steer catch-up can adopt an active parked state, re-arm, and still send steer exactly once;
- `interactionAlreadyResolved` response catch-up re-arms and completes without resending;
- terminal cancellation leaves no timer or later polling;
- cancellation that remains active re-arms recovery;
- terminal completion removes the timer and prevents future recovery polls.

A repeated suite run exposed an assertion-order race in the new steer test: host command completion could precede asynchronous event-recorder consumption. The wait condition was tightened to include the projected reply and terminal run state before asserting them.

## Technical Decisions

| Decision | Rationale | Alternatives Considered | Consequences / Risks | Evidence |
|---|---|---|---|---|
| Reuse `recordStaleObservationProgress` | It is the existing recovery authority and contains all eligibility/single-flight guards | Directly call the scheduler; add a parked-page polling loop | Resets the bounded recovery deadline at command completion | Code inspection and Oracle review |
| Register defer before command send | Covers command failure and `.inDoubt` internal catch-up paths | Register only after snapshot adoption | A failed user command against an active session may intentionally restart the bounded stale deadline | Oracle plan/review and dedicated test |
| Include `cancel` | Cancellation may still report active while host cancellation propagates | Treat cancel as always terminal | Normal terminal cancel is a guarded no-op; active cancel retains observation | Tests cover both states |
| Keep gateway push absence out of scope | Client fallback gap was independently confirmed and fixable | Combine with gateway diagnostics/logging changes | Missing push remains a separate reliability/observability concern | Investigation evidence |
| Keep model-selection regression out of this patch | Report arrived after successful validation and has not been traced | Speculatively change model discovery while committing | Requires focused investigation before attribution or remediation | User report |

## Challenges, Debugging, and Resolutions

| Challenge | Evidence | Resolution | Remaining Risk |
|---|---|---|---|
| Host completed but client never fetched again | Host audit ended with a parked incomplete turn; client logs showed watchdog stopped at prior terminal | Re-arm the existing watchdog at mutating command tails | Gateway push absence remains unresolved |
| Throw paths could still adopt active state | `commandWithTransportRetry` may catch up before rethrowing `.inDoubt` | Place defer before send and add an `.inDoubt` regression test | Failed commands restart the bounded deadline by design |
| Async event recorder raced test assertions | A repeated focused suite run observed host commands complete before recorder projection | Wait for both command completion and terminal recorder evidence | None observed after rerun |
| Repository-wide formatting checks fail | `dev-format-check` reported 6,016 existing baseline findings; scoped source findings were pre-existing lines | Ran formatter, reverted unrelated formatter spillover, and retained only scoped changes | Repository baseline prevents a clean style-gate result |
| Client model options no longer visible/selectable | User manual validation after the fix | Recorded as immediate follow-up; no speculative change | Remote model discovery/selection remains regressed |

## Validation and Testing

| Check | Command / Method | Result | Notes |
|---|---|---|---|
| Swift formatting mutation | `make dev-format` | Passed | Unrelated formatter spillover was reverted; only scoped files remained modified |
| Focused controller tests | `make dev-test FILTER=RemoteAgentSessionTests` | Passed: **64 tests, 0 failures** | Final run after Oracle hardening and test synchronization fix |
| Formatter check | `make dev-format-check` | Failed on existing repository-wide baseline | 6,016 findings; no new test-file diagnostics reported |
| Combined lint | `make dev-lint` | Failed on the same existing formatting baseline | Earlier implementation run; not represented as passing |
| Oracle pre-implementation plan | RepoPrompt Oracle plan mode | Completed | Validated command-tail placement, defer semantics, and test contract |
| Oracle implementation review | RepoPrompt Oracle review mode | Approved, no blocking findings | Two worthwhile P2 hardening suggestions were applied |
| Manual remote-session validation | User-operated client/host flow | Original stall fixed | User stated “it works” |
| Manual model-selection validation | User observation | Regression present | Client no longer sees/selects remote-host models; not investigated |
| Product build | Not run in this session | Not available | Focused tests compiled the affected test target |
| Live automated smoke | Not run | Not available | Manual user validation supplied behavioral evidence; no visible app lifecycle action was taken by the agent |

## Operational and Integration Impact

- Dependencies changed: **None.**
- Configuration/environment variables changed: **None.**
- Database/schema/migration changes: **None.**
- Wire/API protocol changes: **None.**
- Feature flags changed: **None.**
- Runtime impact: active mutating command tails may schedule the existing bounded stale-recovery poll when push delivery is absent.
- Backward compatibility: no persisted data or protocol format changed.
- Deployment consideration: client and host do not require coordinated protocol upgrades for this patch.

## Risks, Limitations, and Technical Debt

1. **User-reported model discovery/selection regression — observed, root cause unknown.** The client can no longer see or select models for the remote host. The timing suggests it should be investigated against the current branch, but this report does not establish that the three-line command-tail change caused it.
2. **Gateway push delivery remains unpinned.** The client fallback now recovers the observed stall, but incident-time gateway logs were discarded and the reason no push arrived was not proven.
3. **Recovery remains bounded.** A remote turn that outlasts the complete retry window while all pushes are absent can still exhaust recovery. Extending or renewing that policy requires a separate contract.
4. **Style baseline is not clean.** Repository-wide format/lint gates fail independently of this patch, limiting style validation evidence.
5. **No automated live MCP smoke was run.** The user manually validated the target behavior, but the full remote model-discovery surface was not covered by the focused controller suite.

## Follow-up Work

### Immediate

- Investigate the user-reported remote model discovery/selection regression separately:
  - verify whether `list_agents` succeeds on the active remote binding;
  - compare client model catalog state before and after session attachment;
  - inspect binding/workspace routing errors without assuming this watchdog patch is causal;
  - add focused coverage at the model catalog/picker ownership boundary once reproduced.
- Preserve the regression as a separate issue/commit track rather than mixing speculative model changes into the stale-recovery commit.

### Future

- Capture gateway stderr in a durable rotating log so missed watch/push events are diagnosable.
- Investigate why the host emitted no session push frames in the incident.
- Consider a separately specified parked-page re-poll policy if bounded stale recovery still strands very long turns.

## Maintainer Notes

- The defer position is load-bearing. Moving it after the command call would stop covering `.inDoubt` and other throw paths that may already have adopted active host state.
- Do not replace `recordStaleObservationProgress` with a direct scheduler call; that would bypass generation reset, terminal handling, and ownership guards.
- The model picker regression is user-observed but untriaged. Start from its actual catalog/binding authority rather than adding a UI fallback.
- Local investigation reports, prompt exports, and agent artifacts were intentionally excluded from the implementation commit.

## Metrics

- Implementation files changed: **2** before this report.
- Documentation files added: **1**.
- Documentation guardrail files modified: **1**.
- Total intended commit files: **4**.
- Implementation diff before report: **302 insertions, 0 deletions**.
- Components affected: remote Agent Mode client session controller and deterministic controller tests.
- Session duration: **Unknown**; no authoritative duration was recorded.
