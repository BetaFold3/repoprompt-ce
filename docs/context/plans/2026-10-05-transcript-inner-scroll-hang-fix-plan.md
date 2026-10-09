# Agent transcript inner-scroll hang fix plan

Scope: read when the task touches the 2026-10-04 Dev CE main-thread hang, capped expanded transcript groups (`AgentTranscriptInnerFollowScrollView`, lazy vs eager grouped/cluster content), inner-follow state ownership, the DEBUG tool-card render-state preference observer, or DEBUG transcript update-burst / main-thread stall diagnostics.
Authority: Reference
Last-verified: 2026-10-05

Status: Steps 1–4 implemented, focused-validated and independently reviewed, then committed locally as 24ca4b4d, 406b9126, 6d27c3f9 and a25bb1c7. Final serial suite comparison completed (6464 tests, 10 skipped, 7 failures; causes unproven; isolated merge/Cursor reruns passed). Step 0 verification and this plan/evidence remain local. Containment, not root-cause proof. The 2026-10-09 corrected-build live health retry passed smoke, bounded main-thread samples and fault monitoring; manual interaction acceptance and soak remain pending, so the plan stays active.
Step 0 — done | rounds 0/2 | open: none | downgraded: none | assumed: Q3 uses existing conductor deadlines; reuse scale-test gate; keep verification-only Step 0 local without a commit after allowlist preflight failure | deferred: OracleB S0R-6/S0R-10 to Step 1; runtime validation to later steps | evidence: docs/plans/evidence/2026-10-05-transcript-inner-scroll-hang-fix/step-0-verification.md; step-0-review-disposition.md
Step 1 — done | rounds 0/2 | open: none | downgraded: none | assumed: preserve unrelated dirty changes; keep plan/evidence local; Diagnostics placement and narrow macOS 15 Mutex guard; full-suite instability nonblocking after isolated reruns; unsigned local commit after signing question timed out | deferred: OracleA/OracleB S1-01 strict log ordering (documented); OracleB S1-04 timezone presentation; existing ledger gap; approval-gated live baseline | evidence: docs/plans/evidence/2026-10-05-transcript-inner-scroll-hang-fix/step-1-execution.md; step-1-review-disposition.md; commit 24ca4b4d
Step 2 — done | rounds 0/2 | open: none | downgraded: none | assumed: keep plan/evidence local; existing external deadlines/scale gate; nondiscriminating experiment discarded; final full suite after Step 4; unsigned local commit default | deferred: OracleB S2-04 renderer consolidation; approval-gated live acceptance | evidence: docs/plans/evidence/2026-10-05-transcript-inner-scroll-hang-fix/step-2-execution.md; step-2-review-disposition.md; commit 406b9126
Step 3 — done | rounds 0/2 | open: none | downgraded: none | assumed: one-to-one transitions per OD6; unsigned local commit; final full suite after Step 4 | deferred: OracleB S3-03 small discarded per-init allocation; preexisting lifecycle/order hazards; live acceptance | evidence: docs/plans/evidence/2026-10-05-transcript-inner-scroll-hang-fix/step-3-execution.md; step-3-review-disposition.md; commit 6d27c3f9
Step 4 — done | rounds 0/2 | open: none | downgraded: none | assumed: observer-only gating per OD5; red full suite nonblocking after scoped triage/isolated passes, causes unknown; unsigned local commit; local plan/evidence | deferred: manual live follow/picker/hover acceptance and soak; stress-harness telemetry; full-suite failure causes; existing ledger gap | evidence: docs/plans/evidence/2026-10-05-transcript-inner-scroll-hang-fix/step-4-execution.md; step-4-review-disposition.md; final-suite-comparison.md; live-fixed-2026-10-09-verification.md; commit a25bb1c7
Decision process: OracleA and OracleB received the same brief, consisting of the verified sample evidence, source facts, and repository constraints. After round 1 the maintainer answered four questions (§1). New unified-log evidence (§2.2) and each lane's arguments were then relayed anonymously for two challenge rounds. Most points converged. Two did not converge: in both rounds the lanes swapped sides on them, so they remain **open** (§9). This plan gives a recommended default for each, but the maintainer decides.

## 1. Outcome and owner decisions

Goal: remove the main-thread livelock behind the 2026-10-04 hang, with high confidence and the smallest change. Keep the Patch C follow contract described in [oracle-failure-inspection.md](../oracle-failure-inspection.md). Add DEBUG diagnostics so that any recurrence is caught and attributed without anyone needing to be watching.

| ID | Owner decision (2026-10-05) |
|---|---|
| OD1 | Capped expanded groups (more than 5 rows, 220/260 pt cap) render **eagerly**. This changes the Patch C "lazy rendering" contract, and the change is approved. |
| OD2 | This was the first full CE hang ever seen. None was observed before the build that contains commit 829cfc0e. |
| OD3 | At the time of onset the maintainer was scheduling a message (date picker), typing or sending while a run was active, and expanding or scrolling a grouped tool-call history block. |
| OD4 | Expanded grouped-history blocks typically hold 50–200 rows. |
| OD5 | 2026-10-08: E1 uses observer-only gating; leave preference emission unchanged. |
| OD6 | 2026-10-08: E2 uses a one-to-one tracker wrapper; do not add lifecycle changes in this fix. |
| OD7 | 2026-10-08: Keep the DEBUG stall watchdog permanently; release-build hang history remains unknown. |
| OD8 | 2026-10-09: Finish Steps 2–4 now; live launch/relaunch and acceptance may wait until afterward, with approval at each action boundary. |

Repository invariants still apply:
- use coordinated `make dev-*` operations;
- ask for approval at the moment of any visible app launch, relaunch, or stop;
- do not weaken tests;
- update the owning routed doc, then run `Scripts/check-agent-context`.

## 2. Evidence

### 2.1 Sample (`sample.txt`, pid 11603, Debug CE 1.0.29 (30), macOS 26.7)

- **Main thread never idle.** All 2,037 main-thread samples are inside a single run-loop observer callout (`__CFRunLoopDoObservers → NSRunLoop.flushObservers`). The main thread never returns to wait on the run loop.
  - 1,715 samples are in `NSHostingView.beginTransaction → GraphHost.flushTransactions`. Of those, 1,479 are generic `runTransaction` graph updates and 232 are separate `runTransaction`s applying `LazyLayoutCacheItem.AllItemsPhaseMutation → LazyLayoutViewCache.updateItemPhases → propagate_dirty`.
  - 322 samples are in `Update.end → dispatchActions`; 317 of them are hover updates and hit-testing through nested `HostingScrollView`/`NSClipView`.
- **Hot layout chain.** The chain runs: outer transcript `ScrollView` → non-lazy `VStack`s (`sizeChildrenIdeally`) → inner capped `ScrollView` → `LazyVStack` → `LazyStack.measureEstimates` over a `ForEach` of `AgentTranscriptGroupInspectionEntry` (about 184 samples).
- **Little app code on main.**
  - About 40 samples copy or destroy `AgentTranscriptGroupInspectionEntry`.
  - 12 samples are in `AgentToolCardRenderStatePreferenceKey.reduce` (`ToolCardContainer.swift:54`), reached through `LazyPreference.value.getter`.
  - 1 sample is in the inner `onScrollGeometryChange` `of:` closure (`AgentTranscriptGroupInspection.swift:383`).
  - The sampled line numbers match the current source.
- **Blocked background threads.** The Cursor and Codex model-poll tasks, and CoreFoundation's day-change notification, are each blocked posting a notification that waits on the main queue. They are victims of the stalled main thread, not causes.
- **Provenance.** The sampled inner-follow and lazy-content code first landed in commit 829cfc0e (2026-10-04 19:33). The app was built from that worktree before the commit, at 18:49, and no later commit touches these files. Before 829cfc0e, capped groups were a plain `ScrollView { VStack }.frame(maxHeight:)` with no geometry tracking.

### 2.2 Unified log (`log show`, pid 11603)

- **Onset about 22:07:08 on 2026-10-04.** The main thread last logged at 22:07:07.949. Process log volume then falls from about 10k lines per hour to about 48 lines per hour of background chatter, and stays there until termination at 2026-10-05 08:23:56, roughly 10 h 15 min later. The earlier "since about midnight" inference is withdrawn.
- **The user was active just before onset:**
  - 22:05: date-picker changes (the scheduled-send control);
  - 22:06: a context/share menu, then key equivalents;
  - 22:07:03–07: typing.
- **Long-standing SwiftUI faults.** These messages are noise, not attribution evidence. `tried to update multiple times per frame` faults for `<OnScrollGeometryChange Modifier>`, `onChange(of: CGFloat)`, and `Bound preference AgentToolCardRenderStatePreferenceKey` appear in every RepoPrompt process since 2026-09-28. That includes Oct 2–3 builds that predate 829cfc0e, none of which hung. In pid 11603 none appear after onset.

### 2.3 Source facts (verified)

- **Outer transcript is non-lazy.** It is a `VStack` + `ForEach(blocks)` (`AgentModeView.messagesStack`/`transcriptBlockRows`), so every outer layout pass measures every expanded inner scroll view.
- **Grouped-history capped branch.** Expanded `.groupedHistory` with more than 5 rows uses `AgentTranscriptInnerFollowScrollView(maxHeight: 260)` around `lazyGroupedContent` (a `LazyVStack` over `AgentTranscriptGroupInspection.entries(for:)`).
- **Activity-cluster capped branch.** `.activityCluster` with more than 5 rows uses `maxHeight: 220` and `expandedClusterContent(lazy: true)`. Production never emits `.activityCluster`, but the path exists.
- **Inner tracking writes `@State` on every change.** `AgentTranscriptInnerBottomTracking` reports a continuous `Position { offsetY; distanceToBottom }`. Each geometry action calls `followState.record`, which writes the view's `@State` struct, including `lastPosition`.
- **DEBUG observer.** `messageListContent` has `#if DEBUG .onPreferenceChange(AgentToolCardRenderStatePreferenceKey)`, which writes the `@State` `visibleToolCardRenderStatesByID`. Only the telemetry computation is gated (`guard let stressHarness`).
  - `ToolCardContainer` emits the preference unconditionally.
  - `AgentModeView.swift:2591` is the key's only reader (verified with grep).
  - `stressHarness` is a constructor `let` taken from `windowState.agentChatStressHarness`.
- **Offscreen hosting is feasible.** It is used in `AgentExecutionLocationPickerLayoutTests`.
- **No XCTest timeouts are configured.** No execution-time allowance is configured in `Makefile`, `Scripts`, or `conductor`.

## 3. Diagnosis (both lanes converged)

| Rank | Hypothesis | Status |
|---|---|---|
| H1 | **Nested lazy-layout nonconvergence.** A `LazyVStack` inside a content-sized capped inner `ScrollView` that the non-lazy outer stack sizes at its ideal height. The cycle runs: realized set → height estimate → inner viewport height and bottom-clamped offset → realized set. Lazy phase mutations keep queuing transactions inside one `flushTransactions`. | Leading. It is supported by the sample frames and by "first hang after 829cfc0e". With 50–200 rows in a 260 pt viewport, most rows exist only as estimates. The disturbances at onset (appends, expanding or scrolling the group, typing) fit the trigger. The exact cycle is an inference about SwiftUI internals. |
| H2 | **Inner-follow geometry → `@State` feedback.** | Secondary. It is a new edge from 829cfc0e. It may not invalidate anything, because `body` reads `followState` only inside closures (inference). |
| H3 | **Outer scroll-engine geometry actions.** | Amplifier only: they have faulted since Sep 28 without hanging. |
| H4 | **Hover hit-testing.** | Most likely a cost paid on each loop pass, not a cause. |
| H5 | **DEBUG preference observer.** | Lowest: it has faulted since Oct 2 without hanging. |

The fix contains H1 directly and removes the H2 and H5 edges as defense in depth. The plan must report results as **containment**, not as proof of a single root cause, unless the offscreen experiment (§6.1) separates the lazy and eager variants.

## 4. Changes, in commit order

All commits land in one PR. They are ordered for bisection: probe → eager → tracker → gating (both lanes converged on this order).

### Step 0 — Verification before editing (no code)

- Confirm `stressHarness` can change during an `AgentModeView`'s lifetime: it comes from `windowState.agentChatStressHarness`. If it can, the conditional observer swaps the subtree's identity once; that is acceptable in DEBUG and should be noted in a comment.
- Choose where the app-wide DEBUG watchdog lives and starts (after launch finishes), and which `Logger` subsystem it uses. Agent Mode code uses `com.repoprompt.agents`.
- Check whether `make dev-test` can run one suite in isolation with an execution-time limit (§6.1).
- Grep for other `LazyVStack`s inside tool-card or row views that sit inside the capped inner scroll view.

### Step 1 — DEBUG diagnostics

**1a. Transcript update-burst probe.** This is a new DEBUG-only file, `Sources/RepoPrompt/Features/AgentMode/Views/AgentTranscriptUpdateBurstProbe.swift`.

- `AgentTranscriptUpdateBurstCounter` is a pure value type:
  - `note(_:) -> Report?` returns a report when the per-turn total reaches 2,000 and again at each further 10× multiple;
  - `endTurn()` zeroes the counts.
- `@MainActor enum AgentTranscriptUpdateBurstProbe`:
  - installs one process-wide `CFRunLoopObserver` on the main run loop (common modes, `beforeSources | afterWaiting`) that calls `endTurn()`;
  - logs each report at `.fault` with per-event counts and emits one `OSSignposter` event.
- Counting is per run-loop **turn**, not per second, because the symptom is that the main thread never returns to the run loop.
- Events, one line at each site:
  - inner geometry deliveries;
  - inner duplicate positions, expected to be 0 because the API skips equal values;
  - pin transitions;
  - newest-entry notifications;
  - follows scheduled, executed, and rejected;
  - tool-card render-state deliveries and assignments;
  - outer `onScrollGeometryChange` actions;
  - `transcriptBlockRows` body evaluations.
- Counters are plain fields. They are never published or observed, and the probe has no circuit breaker.
- It is always on in DEBUG, with no launch flag: the incident build was launched normally.

**1b. App-wide main-thread stall watchdog.** This is DEBUG-only, `MainThreadStallWatchdog`, placed as chosen in Step 0.

- **Thread.** A dedicated `Thread` at `.userInitiated` QoS sleeps 0.5 s per loop. It does not use GCD, so it still works if GCD's thread pool is exhausted.
- **Ping.** `DispatchQueue.main.async`, with at most one ping outstanding.
- **State.** Shared through a `Synchronization.Mutex`. It never touches main-actor or SwiftUI state.
- **Pure core.** `tick(now:) -> none | sendPing(id) | fault(id, stalledFor)` and `pong(id, now:) -> recoveredAfter?`, measured with `ContinuousClock`.
- **Validity rule.** A tick gap over 1.0 s (debugger stop, sleep/wake, App Nap) invalidates the window. The outstanding ping's start time resets to now, and no new ping is sent.
- **Output.**
  - One `.fault` per outstanding ping once it reaches 2 s. The fault reports the unanswered ping's **enqueue time**, not a claimed exact onset.
  - If the pong later arrives, one `.error` line: "recovered after N s".
  - A true hang therefore yields exactly one fault and no recovery line.
- **No causal classification.** A heartbeat fault without a probe fault does not prove a loop inside the framework. Both faults together do not prove that app callbacks sustain the stall. The faults only trigger the next capture.

### Step 2 — Eager capped content (primary containment, OD1)

In `AgentModeView.swift`:

- **Grouped history.** Rename `lazyGroupedContent(entries:renderContext:)` to `flattenedGroupedContent(entries:renderContext:)` and change its `LazyVStack(alignment: .leading, spacing: 0)` to `VStack(alignment: .leading, spacing: 0)`.
  - Keep `ForEach(entries)`, `.padding(.top, entry.topSpacing)`, the bottom padding, and `newestEntryID: entries.last?.id`.
- **Activity cluster.** Remove the `lazy:` parameter and the `LazyVStack` branch from `expandedClusterContent`, and drop `lazy: true` at the capped call site.
- **Unchanged:** the 220/260 caps, the more-than-5-row threshold, `bottomAnchorID`, `followsNewest: isDynamicSummaryLockTarget(block)`, `entries(for:)`, the outer `messagesStack`, and the outer scroll engine.
- **Comments.** Update the file-header and C4 doc comments in `AgentTranscriptGroupInspection.swift`: the flattened entries are now rendered eagerly, and still supply stable IDs and the follow token.
- **Rejected alternatives:**
  - keeping `LazyVStack` with a fixed `.frame(height:)`, which leaves blank space under short groups and keeps the coupling between the bottom clamp and the estimate;
  - making the outer stack lazy, which has a large blast radius on restore and pinning;
  - caching the flattened entries, which cannot fix a loop that does not converge.

### Step 3 — Follow state SwiftUI does not observe (H2)

Add `@MainActor final class AgentTranscriptInnerFollowTracker` in the C3 section of `AgentTranscriptGroupInspection.swift`.

- It deliberately is not `ObservableObject` or `@Observable`.
- It wraps `AgentTranscriptInnerFollowState` and exposes `state`.
- `AgentTranscriptInnerFollowScrollView` replaces `@State private var followState` with `@State private var followTracker`, which only keeps the instance stable. Geometry callbacks mutate the tracker's fields and never write SwiftUI state.
- The deferred `DispatchQueue.main.async` follow keeps its current form and revalidates its ticket through the tracker.
- The legacy macOS 14 branch stays as it is: it is outside the supported range.
- **Recommended default (open item E2, §9):** a one-to-one wrapper with exactly the struct's methods and transitions, and no lifecycle additions.

### Step 4 — Gate the DEBUG render-state observer (H5)

In `AgentModeView.swift`, replace the unconditional `#if DEBUG .onPreferenceChange(...)` with a private DEBUG `AgentToolCardRenderStateObservation(isEnabled: stressHarness != nil, onChange:)` view modifier.

- Its body is `if isEnabled { content.onPreferenceChange(...) } else { content }`.
- The action guards `states != visibleToolCardRenderStatesByID`, assigns, calls `publishStressTelemetrySnapshot()`, and notes the probe events.
- `publishStressTelemetrySnapshot`'s existing guard stays as defense in depth.
- **Recommended default (open item E1, §9):** leave `ToolCardContainer.swift` unchanged.

## 5. Deterministic tests

- **`AgentTranscriptGroupInspectionTests`:** keep every existing C3/C4/C5 test unchanged. Add `@MainActor` sequence-parity tests that drive `AgentTranscriptInnerFollowTracker` and a plain `AgentTranscriptInnerFollowState` through the same sequences and assert equal state and ticket results at every step. The sequences cover:
  - growth while pinned;
  - unpinning by scrolling up;
  - re-pinning;
  - run completion (`setLive(false)`);
  - a superseded ticket;
  - a ticket taken before unpinning;
  - the 6 pt and 0.5 pt boundaries, where not already covered.
- **`AgentTranscriptUpdateBurstCounterTests`** (new, DEBUG):
  - below the threshold, no report;
  - exactly one report at 2,000, with correct per-event counts;
  - further reports only at 10× multiples;
  - `endTurn()` resets.
- **`MainThreadStallWatchdogCoreTests`** (new, DEBUG):
  - no fault before 2 s;
  - exactly one fault per ping;
  - never a second outstanding ping;
  - a late tick resets the window;
  - a recovery line only after a fault;
  - a stale pong id is ignored.
- If E1 resolves to gating emission: add `ToolCardRenderStatePreferenceTests` (offscreen `NSHostingView`): disabled emits no payload, enabled emits a payload, and disabling removes it.
- If E2 resolves to adding lifecycle: add tests that disappearing invalidates an outstanding ticket and reappearing doesn't revive it; that ended→live in one update schedules a follow; and that live→ended cancels it.

## 6. Reproduction and validation

### 6.1 Offscreen layout experiment (time-boxed to about half a day; commit only if it discriminates)

- **Host.** `NSHostingView` in an `NSWindow` that is never ordered front. The structure mirrors production: outer `ScrollView { VStack { filler; AgentTranscriptInnerFollowScrollView(maxHeight: 260, followsNewest: true) { rows } } }`, with stable row IDs.
- **Variants.** `LazyVStack` (pre-fix) vs `VStack` (fix).
- **Parameters.** Row heights cycle 18/44/120 pt. N ∈ {6, 8, 12, 50, 100, 200}, plus window-height sweeps.
- **Finite scripts only.** The same scripted sequence runs on both variants:
  1. rows appended in steps;
  2. a sibling height change, standing in for composer growth;
  3. a parent re-render with identical data, standing in for typing;
  4. a window-height step;
  5. then a quiet window with no mutation.

  Continuous feeding is excluded because it would make the view look busy without showing a loop that sustains itself.
- **Measure.**
  - Layout passes, counted with a test-only counting `Layout` wrapper around the inner content.
  - "Settled" means three consecutive 50 ms slices with zero passes.
  - Report the number of turns to settle and the peak count.
  - Also report (not gate on) the time to lay out a 200-row expanded group, eager vs lazy.
- **Isolation.** Gate the suite on `RP_TRANSCRIPT_LAYOUT_EXPERIMENT=1` and run it alone with `make dev-test FILTER=…`. The time limit must be enforced from outside the stuck process; no XCTest timeout is configured today (open question Q3). Do not abort inside the shared suite process.
- **Commit rule.** Commit only an eager-variant "settles within K turns" assertion into the normal suite, and only if the experiment reliably separates lazy failure from eager settling. A negative result does not rule out H1.

### 6.2 Approval-gated live runs (ask at the moment of each launch)

- **Builds.** A probe-and-watchdog-only baseline and the full fix, plus one overnight soak of the fixed build. A build with the tracker and gating but still `LazyVStack` is needed only if virtualization is ever reconsidered.
- **Scenario (matches OD3/OD4).**
  1. Start an active run with 50–200 rows of mixed card heights in one grouped-history block.
  2. Expand and pin the block.
  3. Scroll it up and back down.
  4. While rows stream in: type in the composer, schedule a message with the date picker, open a transcript context menu, resize the window, and move the cursor over and away from the group.
  5. After the run ends, leave the app idle.
- **Capture.** When a watchdog fault appears, a `log stream` watcher triggers one bounded capture sequence for that episode: `sample <pid> 10` first, then `spindump` where available.
- **Pass (fixed build) requires all of:**
  - no watchdog fault and no burst fault;
  - the main thread is mostly idle when the app is idle;
  - new rows scroll into view while pinned;
  - scrolling up never yanks back;
  - returning to the bottom resumes following;
  - nothing follows after the run ends;
  - hover affordances still respond;
  - a `sample` of the fixed build without a harness shows no `LazyLayout*` frames under the transcript and no `AgentToolCardRenderStatePreferenceKey.reduce` frames (the E1 acceptance check).
- **Fail:** any watchdog or burst fault, a busy main thread while idle, or `sample` showing the `flushObservers` stack.
- If only the combined change prevents reproduction, report it as containment.

### 6.3 Commands

- `make dev-format-check`
- `make dev-lint`
- `make dev-build`
- `make dev-test FILTER=AgentTranscriptGroupInspectionTests`
- `make dev-test FILTER=AgentTranscriptUpdateBurstCounterTests`
- `make dev-test FILTER=MainThreadStallWatchdogCoreTests`
- Any transcript-scroll, tool-card, or stress-harness suites found by grep.
- A full `make dev-test` before and after, comparing the lists of failing tests: the base suite already has known failures, per `oracle-failure-inspection.md`.
- `Scripts/check-agent-context` after the doc edits.

## 7. Doc updates (at implementation time)

`docs/context/oracle-failure-inspection.md`, Patch C:
- **Last-verified.** Bump the date and add an incident/remediation status line: onset 2026-10-04 22:07:08, about 10 h 15 min stall, fixed by containment, live acceptance pending approval.
- **Lazy rendering → "Capped rendering".**
  - Capped groups render every row eagerly, with grouped history drawn from the flattened entries in a non-lazy `VStack`.
  - `LazyVStack` was removed after the hang.
  - No lazy container may go back inside the content-sized inner scroll view without a harness showing it stays stable.
  - Remove the "offscreen inner card state can reset" caveat.
- **State ownership.** Follow state lives in `AgentTranscriptInnerFollowTracker`, a reference held by `@State` that SwiftUI doesn't observe; geometry callbacks never write SwiftUI state.
- **Diagnostics (DEBUG).**
  - the burst probe's semantics;
  - the stall watchdog and its limits;
  - the render-state observer is attached only when a stress harness is present;
  - the "multiple times per frame" faults predate this change and are not attribution evidence.
- **Known pre-existing issues**, if E2 keeps the plain wrapper:
  - the order of an ended→live change and a newest-entry change within one update can miss the first follow;
  - a deferred follow may call `scrollTo` on a stale proxy after the group disappears.

When the plan completes, move it to `docs/context/plans/completed/` per the context-maintenance rules.

## 8. Risks

- **Eager cost.** Opening a 200-row group builds every row. Measure it in §6.1. If it is too slow, any follow-up is a lazy variant proven stable by the harness, not a silent revert.
- **Follow behavior.** It should not change; the parity tests guard it. Eager content makes `scrollTo(bottomAnchorID)` more reliable.
- **Inner card state** now persists across inner scrolling, which is an improvement.
- **Hover** may stay expensive. Re-check hover-revealed controls inside capped groups.
- **Stress harness.** Its telemetry must still receive render states when `stressHarness` is set.
- **DEBUG watchdog false positives.** Genuinely long main-thread work after a wake reports a fault and then a recovery line. That is a true positive, not a hang.

## 9. Material disagreements and resolution

| ID | Topic | Resolution |
|---|---|---|
| D1 | Diagnostics design | **Resolved.** The first positions were launch-flag counters logging per-second rates vs an always-on DEBUG probe counting per run-loop turn. Both converged on the per-turn probe with the merged event list. The lane that proposed the per-turn probe added the stall watchdog (E3); the other lane accepted it with one change, that it makes **no causal classification**, which this plan adopts. I dropped the optional verbose per-second log flag as unnecessary. |
| D2 | Primary fix and commit order | **Resolved.** Both treat eager capped content as the primary containment. Round 2 crossed over on order; round 3 converged on probe → eager → tracker → gating, so the cheapest A/B (probe-only vs probe + eager) tests H1 directly. Live validation is cut to two builds plus a soak (my judgment; one lane proposed it and the other no longer needed per-step attribution once eager went first). |
| D5/E4 | Reproduction | **Resolved.** Both adopted the offscreen experiment with **finite** scripts, a quiet settling window, and isolation from the shared suite process, with the time limit enforced from outside. |
| D6 | Diagnosis ranking | **Resolved.** Both rank nested lazy-layout nonconvergence first, inner `@State` feedback second, and the DEBUG preference observer as an amplifier. The midnight onset is withdrawn. |
| E3 | Stall watchdog scope | **Resolved.** One app-wide DEBUG watchdog (not transcript-specific), with the late-tick validity rule and one fault per episode, reporting the ping's enqueue time. |
| **E1** | **Gate preference emission in `ToolCardContainer`?** | **OPEN.** The lanes swapped sides in both challenge rounds. **For gating emission:** an unread preference costing nothing is an unverified inference about SwiftUI internals; gating at the source makes it a guarantee for about 10 lines, using a DEBUG `@Entry` value `agentToolCardRenderStateCollectionEnabled` (default false, never emitted in release) plus `ToolCardRenderStatePreferenceTests`. **Against:** the logged fault says "**Bound** preference", which is the observer, not the producers; the only reader is the observer (verified); builds before 829cfc0e emitted unconditionally with that reader and never hung; and a conditional modifier on every tool card isn't justified for the lowest-ranked amplifier. **Recommendation: gate only the observer** (Step 4), and keep the §6.2 acceptance check (no `reduce` frames without a harness). Gate at the producer only as a follow-up if that check fails. |
| **E2** | **Inner-follow tracker lifecycle** | **OPEN.** The lanes swapped sides in both challenge rounds. **For a lifecycle:** (a) on disappear, call `setLive(false)` so the deferred closure, which keeps the tracker and proxy alive, becomes a guaranteed no-op, and on appear call `setLive(followsNewest)`; (b) `scheduleFollow(isLive:)`, because SwiftUI doesn't document the order of `onChange` actions, and an ended→live change in the same update as a new row would miss that first row. **Against:** with eager content, the inner view disappears only on collapse or when the block is re-identified; the stale-proxy `scrollTo` already shipped in 829cfc0e; neither is on the hang path; and mixing behavior changes into a commit meant to say "same transitions, no observable writes" muddies attribution. **Recommendation: a one-to-one wrapper in this fix** (Step 3), recording both hazards as known issues in Patch C, and handling (a) and (b) in a small follow-up with their own tests. |

Minor points I resolved:
- The grouped helper is named `flattenedGroupedContent`.
- Duplicate positions are counted by the probe rather than filtered.
- The timer-driven reproduction scenario was replaced by finite scripts.

## 10. Open questions

1. **E1:** observer-only gating (recommended), or gate emission at the producer too?
2. **E2:** a one-to-one tracker wrapper (recommended), or add the disappearance and live-sync lifecycle now?
3. **Experiment time limit:** no XCTest execution-time allowance is configured. Add a coordinated timeout option for an isolated `make dev-test` run, or accept an in-process watchdog abort for the env-gated experiment suite only?
4. Approval for each live run (baseline, fixed build, overnight soak), requested at the moment of launch.
5. Keep the DEBUG stall watchdog permanently? Recommended: yes.
6. Has a release build ever hung? Unknown; it would change how much weight the DEBUG-only edges get.
