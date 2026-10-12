# Agent Mode transcript-refresh performance — technical spec

Scope: read when the task touches Agent Mode main-thread responsiveness, derived transcript refresh (`scheduleDerivedTranscriptRefresh`, `refreshDerivedTranscriptState`, `buildTranscriptPresentation`), incremental transcript import or sanitize reuse, the bash-metadata caches, segment-end source mutations, source-item commit derivation, or the sidebar session builder's repeated work.
Authority: Reference
Last-verified: 2026-10-12

## Goal

Creating a session, opening a transcript, and watching a running transcript must feel immediate with many windows open and several sessions running. Today the main thread freezes for about 2 s every few seconds because a running background session's transcript is re-derived from scratch on the main actor.

## Done when

- Hands-off live workload W1 (defined below) shows no main-thread hang of 1 s or more, and transcript derivation takes no more than 12% of main-thread time in the daily DEBUG build.
- Every live-mutation refresh that falls back to a full rebuild records a named reason, and fallbacks other than user send and cold load make up at most 5% of refreshes for the largest session.
- In the daily DEBUG build, p95 latency is at most 250 ms from a click on a hydrated session to its first published transcript, and at most 300 ms from a new-session action to a usable composer. Both are measured, not inferred.
- The W3 differential oracle (defined below) passes: on each step, incremental or memoized derivation equals a cold full rebuild.
- No change is made to persisted schemas, retention policy semantics, or `.persistentStorage` sanitization.

## Baseline evidence (2026-10-12, live CE DEBUG app, pid 1278, no restart)

Workload: 6 windows, 771 tabs, 29 hydrated sessions, 7 running. The largest running session was a background Claude tab with about 1,308–1,481 source items (growing during capture), 5 turns, about 910–927 retained ephemeral payloads (about 3.45 MB), and about 1,100 sanitized activities. Raw captures are local working evidence and are not committed.

| Capture | Result |
|---|---|
| 30 s Time Profiler | Main thread 45% busy. 3 hangs of 1.93 s, all in `refreshDerivedTranscriptState`. Inside them, about 62% is `BashToolResultParser.parseMetadata`, mostly the cache-miss compute closure. About 41% is `rebuiltTranscriptPreservingCompactedPrefix` → `buildTranscript`. The two shares overlap. |
| 3 min Time Profiler + Hangs + Hitches | Main thread 32.6% busy (58.8 s). 18 hangs, most 2.04–2.14 s. 136 hitches. Of busy time: derived refresh 57%, SwiftUI hosting-view layout 16%, CA commit 9%, source-item commit rebuild 7.6%, sidebar builder 4%. 19 of the 21 busy stretches of 250 ms or more were derived refresh. |
| 626 s EditFlowPerf stage capture | 207 refreshes took 101 s of main-thread time (16% of wall time), averaging 488 ms with a 2,142 ms maximum. The largest session alone had 82 refreshes, 90 s in total, averaging 1,097 ms. Its incremental import succeeded 42 times (about 84 ms each) and fell back 26 times (about 880 ms each); 14 refreshes made no attempt. 40 sanitize runs were full rebuilds of about 1,100 activities, about 1,128 ms each. Sessions with 100–299 items averaged about 104 ms per refresh; sessions with fewer than 100 items averaged about 22 ms. |
| Main-thread watchdog | 12 stalls of at least 2 s between 15:01 and 17:31. |
| Sidebar | Three render consumers each run the unmemoized `AgentModeSidebarSessionBuilder.build`, about 5–35 ms per build and about 122 builds per minute across windows. |
| 5 min interactive Time Profiler + Hangs + Hitches, plus a 329 s stage capture (18:30–18:35) | The owner switched sessions, created sessions, typed `ask_user` answers, selected text, and scrolled while recording. Interactions were found from handler frames in the samples, not from manual timestamps. The load was quieter than in the earlier captures: 77 refreshes took 5.4 s, and the largest session refreshed only twice. Main thread 25.8% busy. Hangs: 250 ms, 274 ms, 537 ms, and one 2.18 s severe hang. 699 hitches, p50 17 ms, p90 83 ms. |

### Measured interactions (2026-10-12 interactive capture)

| Interaction | Measured on the main thread |
|---|---|
| Click a sidebar session: the largest session, 1,499 source items (`PromptViewModel.switchComposeTab`) | The handler takes 153 ms. Then follow about 1.0 s of SwiftUI graph updates and sidebar builds, a 2.14 s `refreshDerivedTranscriptState` (incremental import fell back at 908 ms; full sanitize of 1,138 activities took 1,167 ms), and another 0.4 s of graph and sidebar work. The main thread stays saturated for **about 3.6 s from click to idle**. Hangs: 537 ms, then a 2.18 s severe hang. Worst single frame: 2,217 ms. That session's next refresh was incremental (80 ms import, 176 ms total). The full rebuild was one of only two refreshes of that session in 5 minutes, so it was almost certainly triggered by the activation (inference). |
| New session (`startNewAgentSessionFromGlobalShortcut` → `createAndActivateSessionTab`), first | **About 1.0–1.1 s** of saturation. About half of the busy samples are `AgentModeSidebarSessionBuilder`; the rest is mostly SwiftUI graph and CA commit. Hitches up to 317 ms. Transcript refresh is negligible. |
| New session, second | **About 0.6 s** of saturation, mostly SwiftUI graph updates. Hitches up to 233 ms. |
| Typing `ask_user` answers (about 30 s) | Main thread 26% busy, 123 hitches, p50 17 ms, max 67 ms. `updateAskUserDraft` is small. Not a priority. |
| Text selection and pop-up menus | Long `mouseDown` spans are AppKit tracking loops (`NSTextView` selection tracking, `NSPopUpButtonCell` menus) during which display cycles keep running. They are not input latency. |
| Scrolling | `scrollWheel` handling appears in only 10 main-thread samples, so scroll windows could not be located exactly. The two hitch-dense windows (100–110 s: 117 hitches, 3.0 s in total; 210–230 s: 173 hitches, 3.4 s in total) had a main thread only 21–30% busy, and many hitches were flagged "Potentially expensive render". Inference: scroll jank there is render- and per-frame-layout-bound, not caused by transcript refresh. |
| Idle (245–275 s, nothing interacted, nothing large refreshing) | Main thread about **16% busy at rest**. 87% of it is `CA::Transaction::commit` → `NSHostingView.layout` → SwiftUI render of the display list, with `RepeatAnimation` frames present. Sidebar view types are the most frequent app frames. Counters showed 39 cancel-spinner appearances against 35 disappearances. |

The earlier queueing estimate (443 ms average extra wait, 12% chance above 1 s) remains a hands-off figure. The measured click on a large session is far worse, because activation itself triggers the full rebuild.

### Attribution model (confirmed arithmetic)

A full rebuild of the largest session costs about 2.1 s: about 880 ms import, about 1,128 ms full sanitize, and about 50 ms projection. That matches the 2.04–2.14 s hang cluster. The 40 full rebuilds (26 fallbacks plus 14 not attempted) equal the 40 `Sanitize outcome=rebuilt` events. (40 × 2.1 s + 42 × 0.15 s) / 82 ≈ 1.10 s, which matches the measured 1,097 ms average. About 93% of that session's 90 s comes from full rebuilds.

### Corrections to first-pass readings

- `EditFlow.Transcript.ProjectionBuild` brackets the PayloadMap and Sanitize stages (`AgentModeViewModel.swift`, `buildTranscriptPresentation`). Projection itself costs about 50 ms per refresh and is not the bottleneck.
- `Sanitize` end dimensions carry no tab or item count. Bucketing by activity count assigned the big session's successful incremental sanitizes to "small sessions". So the earlier claim that the big session got zero prefix reuse is not supported. The 40 rebuilt runs correspond to full imports.
- Turn-granular incrementality does help: a successful final-turn import costs about 84 ms versus about 880 ms for a fallback. The cost driver is the fallback rate (49%), not missing incrementality. The real size of the final turn is unmeasured.

## Root-cause model

Confirmed by code and numbers:

1. **Derivation is synchronous on the main actor.** The scheduled refresh task is `@MainActor` and runs import, sanitize, projection, and retention inline. The coalescing task has no delay, so refreshes run as fast as the main thread allows.
2. **Segment end sends a false structural signal.** `endAssistantSegment` and `endActiveAssistantSegment` only flip `isStreaming` but call `mutateItemsBatch` with its default `.structural` mutation. The merge in `PendingSourceItemsMutationSummary` is sticky, so one structural mutation poisons the whole coalesced batch and blocks incremental import. The same call also triggers a full `commitSourceItems` → `rebuildSourceItemDerivedState`, which re-inspects every item for retention.
3. **Unranged mutations reset the change index to 0.** `PendingSourceItemsMutationSummary.init` and `merge` set `earliestChangedIndex = 0` for any mutation with no `changedIndexRange`. With more than one turn, that always fails the guard `earliestChangedIndex >= finalTurnStartIndex` in `incrementallyUpdatedTranscriptForFinalTurn`.
4. **The bash-metadata caches have a cliff.** Both `BashToolResultParser.Cache`, which is process-wide and static, and `AgentToolResultProcessingContext.bashMetadata` clear everything once they exceed 255 entries. The context is created fresh in every `buildTranscriptPresentation` call, so it never hits across refreshes. One refresh sweeps about 900 results several times, so the caches thrash even within a single refresh. `bashMetadata(raw:)` also trims the full raw string on every lookup, including hits.
5. **A full import gets no sanitize reuse.** Sanitize reuse compares the newly imported turns with the previous *sanitized* turns by `==` (`commonEqualTurnPrefixCount`, `validatedReusablePrefixTurnCount`). `trustedIncrementalFinalTurnStartSequenceIndex` is set only after a successful incremental import, so each full import re-sanitizes about 1,100 activities. Whether imported turns that contain tool results can ever equal sanitized ones is plausible-unequal but not proven.
6. **Refresh also maintains retention.** It runs `setItemsSilently(.retentionCompaction)`, summary-only compaction, payload-map pruning, and `markDerivedTranscriptSynchronized`. Background derivation therefore cannot simply be skipped.
7. **Background tabs pay the full cost.** Publish ran 27 times against about 207 refreshes, so most derivation served tabs nobody was viewing.
8. **Activating a large session pays a full rebuild.** In the measured switch, the activation refresh fell back from incremental import and re-sanitized every activity: 2.14 s of the 3.6 s click-to-idle. The rejection reason is unknown until D0. This is the user-visible form of causes 2–5, and it also bounds D7: deferred work lands on exactly this path.
9. **Running-state animations re-render SwiftUI every frame.** At idle, about 16% of the main thread goes to per-frame `NSHostingView.layout` and display-list render, with `RepeatAnimation` in the stacks. Inference: repeat-forever running indicators (sidebar rows, cancel spinners) force a graph update and render of their whole hosting view on every display frame, in every window that shows one. This is a fixed tax under every interaction.

Plausible, but they need D0 data:
- The 26 rejections could come from unranged mutations, background-row updates in earlier turns, frontier invalidation after compaction, a suffix import that does not yield exactly one turn, or a request-id mismatch.
- The 14 non-attempts could come from structural mutations, user mutations, or a pending `ask_user`.

Unknown:
- Final-turn item count.
- Real cache hit rates.
- Why the activation refresh fell back (needs D0).
- Which hosting views and animations drive the idle render cost, and the busy-time SwiftUI layout (16%) and CA commit (9%) costs. Needs the SwiftUI instrument.
- How much `-Onone` inflates these costs.

## Build configuration and measurement validity

The daily driver is a SwiftPM debug build (`./conductor build` → `package_app.sh debug`). It is compiled `-Onone` with `DEBUG` defined and assertions on. That compiles in every diagnostic used here: `AgentModePerfDiagnostics`, the main-thread stall watchdog, `__repoprompt_debug_diagnostics`, and the EditFlowPerf capture.

`-Onone` inflates constants. Collection- and string-heavy Swift is likely 3–10× slower; Foundation work speeds up less. `-Onone` does not change the structural causes above, and it is the build the user experiences, so DEBUG targets come first.

### Optimized build with diagnostics — trade-off and recommendation

Facts:
- `DEBUG` is defined only through `.when(configuration: .debug)` in `Package.swift`, `Packages/RepoPromptCore/Package.swift`, and `Packages/RepoPromptAgentProviders/Package.swift`.
- There are 2,546 `#if DEBUG` sites in 296 source files, including `__repoprompt_debug_diagnostics`, `AgentModePerfDiagnostics`, and the EditFlowPerf capture recorder.
- `Package.swift` already reads environment gates (`REPOPROMPT_ENABLE_SENTRY`, `RPCE_ENABLE_BENCHMARK_TESTS`).
- `Scripts/package_app.sh release` switches to the production bundle ID `com.pvncher.repoprompt.ce` and the URL scheme `repoprompt-ce`. Debug packaging uses `<base>.debug` and `repoprompt-ce-debug`.
- This configuration has never been compiled.

Pros:
- **Representative numbers.** The daily `-Onone` build inflates the app's own Swift (collections, strings, generics, `Equatable` sweeps) far more than system frameworks (SwiftUI, AttributeGraph, Core Animation are already optimized). DEBUG measurements therefore over-weight transcript derivation relative to SwiftUI and render costs, which can mis-rank work items. The spec's `-O` column has no measurement source today.
- **Diagnostics are kept.** The stage capture, perf metrics, the stall watchdog, and `rpce-cli-debug` diagnostics all still work, so W1, W2, and W3 can run unchanged.
- **A daily driver closer to what users get.** It feels like the shipped app, so the owner's perception matches the measurements.
- **Low ongoing risk.** It is additive, opt-in, and local; it changes no release lane.

Cons:
- **`DEBUG` is broader than "diagnostics".** It also enables debug-only behaviors, test hooks, and debug-only consistency work across 2,546 sites. `assert` bodies compile out under `-O`, but code in `#if DEBUG` blocks still runs, so numbers stay slightly pessimistic, and behavior is "release plus debug extras", not exactly release.
- **Identity hazard.** The release packaging path switches to the production bundle ID and URL scheme. Running it as is would share preferences, keychain items, and URL handling with an installed production app, and the invariants forbid changing bundle IDs or release metadata casually. The lane must compile `-O` but package with the debug identity, and leave Sparkle and channel metadata untouched.
- **Build cost.** Optimized builds are slower to compile and use a separate `.build` tree (more disk, no shared incremental state with the debug tree). Daily edit-build-run gets slower if this becomes the default.
- **Debuggability.** `lldb` stepping and variable inspection are worse in optimized code. Symbolicated profiles are fine.
- **Unproven build.** Code may assume `DEBUG` implies `-Onone` or `-enable-testing`; the first build may need fixes.
- **Do not use `-Xswiftc -DDEBUG`.** It would define `DEBUG` for every third-party dependency too.

Recommendation: add it. The cons are one-time tooling work plus slower builds, not ongoing product risk, provided the lane has this shape:
1. An environment gate (for example `RPCE_OPTIMIZED_DIAGNOSTICS=1`) adds `.define("DEBUG")` under the release configuration to first-party targets only, in all three manifests.
2. A conductor build variant compiles `-c release` and packages with the debug bundle ID, URL scheme, and app path.
3. The debug build stays the default for edit-build-run. The optimized lane is for measurement and, optionally, the daily driver.

Owner reaction (2026-10-12): "If no cons much, why not?" Confirm the shape above before implementing; implementing it is tooling work separate from D0–D8.

## Work items (ordered)

Each item compiles and tests on its own. Items D2 and D4 change correctness-bearing reuse guards, so each must land together with its W3 differential-oracle cases.

### D0 — Fallback reasons, attribution, and interaction signposts (prerequisite)

Step D0 — done | rounds 2/2 | open: none (D0-OracleA-round2.md, D0-OracleB-round2.md) | downgraded: none | assumed: evidence directory docs/reviews/2026-10-12-agent-mode-transcript-refresh-performance; track existing plan and its performance route; optimized lane remains separate | deferred: optional P3/counter granularity/repeated-click samples/release-branch cleanup per D0-final-dispositions.md; EDIT_FLOW_PERF-only build and live validation not run

- Add an incremental-import rejection reason: empty input, invalid frontier, no final-turn start, change before the final turn (earliest index and final-turn start), suffix turn count, or request-id mismatch. Expose it through a diagnostics variant and keep the existing optional-returning API.
- Add a reason for refreshes that make no incremental attempt: reason not live, pending `ask_user`, missing summary, or a summary rejected as removal, replace-all, user, structural, or unranged. In DEBUG, also record a static caller label on the mutation summary.
- Add sanitize rejection reasons: trusted suffix unavailable, turn count or final-turn identity mismatch, request mismatch, span-count mismatch, span identity mismatch, prefix-boundary mismatch, changed suffix not found, or activity-suffix success.
- Add tab tag, `sourceItemCount`, and `finalTurnItemCount` dimensions to Sanitize and ProjectionBuild, and add a `ProjectionOnly` stage that starts after sanitize.
- Add hit, miss, eviction, and entry-count counters to `BashToolResultParser.Cache`.
- Add signposts for activation click → first `publishTranscriptPresentation` for that tab, split into queue wait, refresh, publish, and render. Add another for new-session action → composer ready.
- Tests: one unit test per rejection guard.

### D1 — Ranged, non-structural segment end

Step D1 — done | rounds 0/2 | open: none | downgraded: none | assumed: include reasoning segment end to avoid same-batch structural poisoning; classification-only | deferred: D5 commit optimization and optional direct Codex seal test; live/large-fixture validation per D1-final.md

Use a non-structural mutation with an exact range for segment end. Either add a case such as `assistantStreamingStateChanged(changedIndexRange:)` or reuse an existing in-place-update case that has a range, `isStructural == false`, and `touchesUserItem == false`.

- Compute the flipped indices first, in the same main-actor turn.
- Keep the background/source-ID predicate and the `retireBackgroundCurrentAssistantRow` ordering.
- Keep `mutateItemsBatch`'s default as `.structural`.
- Audit every caller that relies on the default, and every non-structural mutation whose range is nil.
- Before skipping index rebuilds, verify that no index in `makeToolCorrelationIndexes` depends on `isStreaming`.
- Expected impact: removes up to 14 full rebuilds (about 29 s of the 90 s), plus batches poisoned by the merge.

### D2 — Remove the causes of the 26 rejections (scope set by D0 data)

Step D2 — blocked | rounds 0/2 | open: historical rejection causes unproven; D2-scout.md | downgraded: none | assumed: preserve all importer guards; independent D3–D6 may proceed | deferred: installed D0/live capture or deterministic reproduction to set fix scope

- Give unranged mutations real ranges.
- If background rows in earlier turns cause the rejections, check whether they affect the final turn's projection before excluding them.
- Re-establish the frontier after retention compaction if that is the cause.
- Fix suffix-boundary or request-id mismatches in the importer.
- Reorder the guards so cheap checks run before the suffix `buildTranscript`.
- Never weaken a guard without an oracle case.
- Expected: together with D1, the big session drops from about 90 s to about 12 s per 626 s.

### D3 — Remove the bash-metadata cache cliff

Step D3 — done | rounds 0/2 | open: none | downgraded: none | assumed: build-local contexts verified; 2048 entries/generation and 16 MiB accounted/table initial limits | deferred: parsed byte tuning, memory-pressure purge and live validation per D3-final.md

- **Per-build `AgentToolResultProcessingContext`:** remove the cap, since it lives for one build. Trim only when the first or last character is whitespace.
- **Process-wide `BashToolResultParser.Cache`:** replace clear-on-overflow with bounded eviction, sized above the cross-session working set. Keep separate budgets for metadata and parsed results, use byte accounting, and compute outside the lock with a recheck before insert.
  - Plain LRU still gets 0% hits on a repeating scan larger than its capacity, so capacity matters more than the eviction policy.
  - Recommended policy: two-generation eviction. A hit in the old generation promotes the entry to young; when young fills, the old generation is dropped.
  - Starting sizes: about 2,048–4,096 entries per generation for metadata, and a 16–32 MiB key/value byte budget. Tune these from D0 counters.
- Keep correctness keyed on the full string. Never key only on a hash.
- Test: three passes over 1,000 or more distinct keys give at least 95% hits on passes 2 and 3; memory stays bounded; parser output is unchanged.

### D4 — Sanitize reuse after a full import

Step D4 — done | rounds 1/2 | open: none | downgraded: none | assumed: raw-input/output/processing-flag evidence replaces unsafe trusted-prefix proposal; D4-design.md | deferred: matched live latency/RSS and helper duplication per D4-final.md

- Store the pre-sanitize import from the last refresh (`lastImportedTranscript`) next to `session.transcript`, and drop it on dehydrate.
- Diff the new import against it, not against the sanitized transcript. Derive the reusable turn prefix and the first changed activity sequence index from that diff, and pass them through the existing `trustedReusablePrefixTurnCount` and `trustedIncrementalFinalTurnStartSequenceIndex` parameters.
- Precondition to verify: sanitizing an activity depends only on that activity, given the empty `preservedVisibleToolResultRowIDs` the view-model path uses.
- Also allow appended response spans; today, unequal span counts reject the fast path.
- Expected: unavoidable full rebuilds (user send, cold load, stale-tab activation) drop from about 2.1 s to about the import cost.

### D5 — O(change) source-item commit

Step D5 — done | rounds 1/2 | open: none | downgraded: none | assumed: focused boundary validation is commit gate; preserve existing single-row assertion contract per D5-final.md | deferred: full-root failure/provenance retry, live timing, rare collision double repair and existing sidecar/index drift per D5-final.md

- Remove the second duplicate-ID repair: `commitSourceItems` repairs, then `rebuildSourceItemDerivedState` repairs again.
- For ranged appends and in-place updates, update `liveItemIDs` and the ephemeral payload map only for the changed indices. Keep the full rebuild for structural, remove, replace-all, and silent paths.
- Run the full `assertSourceItemDerivedStateIsConsistent` in tests and when instrumentation is on. On the hot DEBUG path, use a narrow check of the permitted field changes instead.
- Test: a property test over random ranged mutations, comparing incremental results with a full rebuild.
- Expected: about 4.5 s → under 1 s per 3 minutes.

### D6 — Sidebar: one build per render pass

Step D6 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

Measured weight: about half the main-thread time of a 1 s new-session action, and part of the 1.4 s of non-refresh work after a session click.

- Compute the filtered rows once in `AgentSessionsSidebarView.body` and feed them to the top-bar animation value, the collapse button, and `AgentModeSessionsListView`, through an overload that takes precomputed rows.
- Keep the collapse button's action-time state check fresh.
- Replace the `linkedTabs.contains` membership filter in `AgentModeSidebarSessionBuilder.makeBuildContext` with a `Set<UUID>`.
- Add no persistent memo. Its invalidation would have to cover MCP control, remote hosts, delegated attention, and the session index.
- Before landing, verify that the parent observes every state source the children did.

### D7 — Throttle background-tab derivation, with flush points (owner-approved 2026-10-12, gated on D1, D2, and the consumer audit)

Step D7 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

Design:
- Add a trailing delay of about 1.5 s for sessions that cannot publish active bindings. Use the existing generation and cancel logic.
- Flush synchronously on tab activation (before the first publish), when `runState` leaves active, when `hasPendingQuestionUI` changes, and on save, MCP transcript reads, or memory pressure.
- First audit every reader of `derivedTranscriptSyncState`, `session.transcript`, and projections, including the save path and sidebar badges.
- Do not fully defer derivation to activation; that moves the whole cost onto the click.

Pros:
- **Biggest remaining lever on background load.** About 180 of 207 refreshes in the 626 s capture served tabs nobody was viewing. Even after D1–D4 make each refresh cheap, refresh count times running sessions times windows is the remaining main-thread budget (root cause 7, and the "saturation as a total budget" blind spot). A 1.5 s trailing window collapses streaming bursts, which today trigger a refresh per provider event, into about one refresh per window per session.
- **Scales with the user's real workload.** The pain grows with more windows and more running sessions; throttling is the one item whose savings grow the same way.
- **Cheap and reversible.** It reuses the existing generation and cancel machinery, has one tunable constant, and can be disabled with a flag if an audit miss appears.
- **Frees frame budget.** Fewer background refreshes means fewer main-thread stretches competing with per-frame layout, render, and scroll work.

Cons and risks:
- **Moves cost onto activation.** Whatever was deferred must be paid when the tab is opened. Measured today: activating the 1,499-item session already costs a 2.14 s full rebuild inside a 3.6 s click-to-idle. If that activation refresh still falls back, D7 makes the clicked path no better and can make it slightly worse, because more accumulated mutations increase the chance of a structural or unranged one in the batch. D7 is therefore net-positive only after D1 and D2 make the activation flush incremental, and ideally after D4 so unavoidable full rebuilds are cheap.
- **Structural-merge poisoning grows with the window.** `PendingSourceItemsMutationSummary.merge` is sticky: a 1.5 s window collects about 10–50 events instead of 1–3, so one structural or unranged mutation forces a full rebuild more often. Without D1 and D2 first, throttling could raise the full-rebuild rate.
- **Delayed retention and sync state.** Refresh also runs retention compaction, summary-only compaction, payload-map pruning, and `markDerivedTranscriptSynchronized` (root cause 6). Deferring it lets ephemeral payload memory grow for up to the window, and lets `derivedTranscriptSyncState` lag. Every reader that assumes freshness must flush first or tolerate staleness.
- **Hidden consumers.** Missing one reader causes subtle bugs: stale sidebar badges or attention state, a save that persists a stale projection, an MCP transcript read that misses the last turn, or a pending `ask_user` card hidden too late. Hence the mandatory audit and the flush-point list.
- **Latency for cross-window views.** A transcript visible in a second window, or a background tab watched through a preview, updates up to 1.5 s late. Sessions that can publish active bindings must be excluded from the throttle.
- **Testing burden.** Timing-dependent behavior needs deterministic tests: an injectable clock, a flush on every listed trigger, and W3 equality after a throttled batch.
- **Interaction with D8.** If off-main derivation lands later, the throttle and the off-main job queue must share one generation and token model rather than stacking two schedulers.

Decision: approved by the owner after the audit, with this order: D0 → D1 → D2 → (D4) → audit → D7. Re-measure the W2 activation latency before and after D7, and back it out if click-to-first-transcript p95 regresses.

### D8 — Off-main derivation (conditional)

Step D8 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

Pursue this only if, after D0–D7, the active-tab incremental refresh p95 is above 50 ms in an optimized build or streaming hitches miss their target.

- The main actor captures an immutable snapshot and a token covering source revision, session identity, run state, agent, question hiding, projection protection, reveal state, and generation.
- A bounded worker derives purely from the snapshot.
- The main actor validates the token before applying presentation or retention changes. Allow one in-flight job per session, newest wins, foreground first, with a guard against starvation.
- Keep the last valid presentation while a new one computes.
- This moves contention; it does not reduce CPU.

## Acceptance metrics

| Metric | Baseline | DEBUG target | `-O` target (if measured) |
|---|---|---|---|
| Big-session live refreshes that fully rebuild, excluding user send and cold load | 40/82 | ≤5%, each with a logged reason | same |
| Big-session RefreshTotal p95 / max | ~2.1 s / 2.14 s | ≤200 ms / ≤500 ms | ≤50 ms / ≤150 ms |
| W3 unavoidable full rebuild, warm caches | ~2.1 s | ≤500 ms | ≤120 ms |
| Bash metadata hit rate on refreshes after the first | unmeasured (the miss path dominates the stacks) | ≥95% | ≥95% |
| W1 main-thread busy | 32.6% | ≤12% | ≤6% |
| W1 hangs ≥1 s per 3 min | 18 | 0 | 0 |
| Watchdog stalls ≥2 s per 2.5 h | 12 | 0 | 0 |
| Commit-path derived rebuild per 3 min | 4.5 s | ≤1 s | — |
| Sidebar builds per body pass | 3 | 1 | — |
| W2 hydrated click → first published transcript, p95 | single sample: click-to-idle about 3.6 s on the 1,499-item session (2.18 s severe hang) | ≤250 ms | ≤100 ms |
| W2 new session → composer usable, p95 | two samples: main-thread saturation about 1.0–1.1 s and about 0.6 s | ≤300 ms | ≤150 ms |
| Idle main-thread busy, no interaction and no large refresh | about 16% (per-frame SwiftUI render) | ≤3% | ≤2% |
| W1 hitches per 3 min | 136 | ≥75% fewer | — |
| Memory | — | cache accounting within budgets; steady-state RSS regression ≤10% | — |

## Validation workloads and protocol

- **W1 (hands-off live):** 6 or more windows, 25 or more hydrated sessions, 5 or more running, including one session with 1,400 or more items and 800 or more bash results. Record a 3-minute trace with `xcrun xctrace record --template 'Time Profiler' --instrument Hitches --instrument Hangs --attach <pid> --time-limit 180s`, plus a 10-minute EditFlowPerf capture via `__repoprompt_debug_diagnostics` (`mcp_read_search_capture_begin` / `mcp_read_search_capture_snapshot`). Also record `agent_perf_metrics` start and end marks and the watchdog log (`log show --predicate 'subsystem == "com.repoprompt.app" AND category == "main-thread-stall"'`). Report busy %, hangs, hitches, stage totals by session size, fallback reasons, and cache counters.
- **W2 (scripted interaction):** 20 switches among hydrated tabs including the big one, 10 new sessions, 10 sends into the big session. Use the D0 signposts. A human-driven run must be confirmed in the trace. Without signposts, find interactions from handler frames: `PromptViewModel.switchComposeTab`, `startNewAgentSessionFromGlobalShortcut` / `createAndActivateSessionTab`, `updateAskUserDraft`. Then measure saturation on a 100–200 ms grid until the main thread drops to its idle level. Ignore `mouseDown` spans; they include AppKit tracking loops. Report the source load next to every W2 number, since the interactive capture saw about 5% of the earlier refresh load.
- **W3 (deterministic test fixture):** 1,500 items in a single final turn with 900 distinct bash outputs. Replay append, result update, segment end, and user send through `refreshDerivedTranscriptState` using `test_allowsScheduledDerivedTranscriptRefreshWithoutPromptManager`. This is a blocking gate: at every step, the following must equal a cold forced full rebuild:
  - the sanitized transcript;
  - projection rows and blocks;
  - post-retention `session.items`;
  - the ephemeral payload and revision maps;
  - pending-question hiding.
- Run the focused tests with `make dev-test FILTER=<Suite>`. Re-capture W1 and W2 after each of D1, D3, D2, and D4. Report three matched trials per build configuration and the event counts, so that a quieter provider stream is not mistaken for a fix.

## Open blind spots

- SwiftUI layout (16%) and CA commit (9%) need the Instruments SwiftUI template (body counts, cause and effect). Candidates are `lastActivityAt` and `isDirty` churn, sidebar re-sorts, `.animation(value:)` evaluated in every body, and running indicators across 7 sessions × 6 windows.
- Idle per-frame render (root cause 9, about 16% at rest): identify the animating views with the SwiftUI instrument. Candidate fixes, to verify: isolate repeat-forever indicators in small leaf views or `TimelineView`s so only they re-render; pause indicators in non-key or occluded windows; use a Core Animation layer animation instead of SwiftUI state animation.
- Scroll smoothness: hitch-dense windows had a low main-thread load and "expensive render" flags. Measure scrolling explicitly with the Animation Hitches template on a large transcript to separate render-server cost, per-frame layout, and text layout.
- Save path: the frequency and threading of encoding about 3.45 MB-payload sessions. Storage sanitization deliberately does not reuse runtime prefixes.
- Memory across 29 hydrated sessions, including the new `lastImportedTranscript` and the caches. Consider dehydrating idle background sessions.
- Main-actor saturation as a total budget: even at about 150 ms per refresh, 7 running sessions can saturate the main thread.
- `logCodexDebug(... transcriptRowDebugWindow(...))` on every refresh. Verify whether its argument is an `@autoclosure`.

## Decisions and provenance

- Owner Decision (2026-10-12): Retry D3 commit; unsigned local commits are permitted for subsequent plan steps without changing global Git settings.

- Owner Decision (2026-10-12): D0 records publication and SwiftUI observation; actual on-screen rendered-frame timing remains an Instruments measurement, not an in-app completion claim.

- The 2026-10-12 consultation used OracleA (preset `61D024A4…`) and OracleB (preset `7CDD523E…`), as independent fresh plan-mode chats with identical evidence. Both agreed on the main-actor diagnosis, D1, the cache fix, instrumentation first, sidebar sharing as a minor independent item, staging background throttling after a consumer audit, and off-main work only if still needed.
- Divergence: OracleA proposed an LRU cache, while OracleB showed LRU fails on repeating scans larger than its capacity. Decision: size the cache above the working set and use generational eviction. Both noted that capacity, not policy, decides the hit rate.
- Divergence: OracleA preferred sub-turn reuse before background work, while OracleB preferred input-diff sanitize memoization (D4) over trusting mutation summaries. Decision: D4 uses the input diff; extending sub-turn import waits for the D0 final-turn size data.
- 2026-10-12 owner decisions: D7 is approved after the consumer audit, with the pros and cons recorded under D7. The optimized-with-diagnostics lane is favored ("If no cons much, why not?"); see the trade-off and required shape under Build configuration.
- 2026-10-12 interactive capture: the owner drove session switches, new sessions, `ask_user` typing, and scrolling during a 5-minute trace. That turned W2 from unmeasured into measured single samples. It also exposed root causes 8 (activation full rebuild) and 9 (idle per-frame render), which the Oracle consultation did not have.
- Owner decisions still pending: adopting the acceptance targets above, and the exact shape of the optimized lane.
