# Swift compile follow-ups plan (type-check scan, split stand-in, index store)

Scope: read when the task touches the 2026-10-08 Swift compile follow-ups: the slow-type-check scan, the RepoPromptCore split stand-in measurement, or the `RPCE_INDEX_STORE` dev-build default.
Authority: Reference
Last-verified: 2026-10-08

Status: Steps 1–4 complete. Results (noisy host): (1) Type-check is a marginal candidate incremental lever inferred from 807 ms of cold emit-module warnings, including a 525 ms private-method check; the visible declaration-only subtotal is 282 ms (below the plan's ~0.5 s bar; sub-200 ms work omitted), and incremental savings are unverified. (2) A Core body edit skipped the `RepoPromptApp` emit-module job 3/3: Core-edit median 11.151 [11.050–11.294] s, app-edit median 19.856 [19.721–19.907] s (full focused conductor test, n=3 each). Features/AgentMode's optimistic commit-weighted estimate of 4.36 s per app edit meets the plan's follow-up screen; the stricter exclusive-edit proxy is 1.38 s. Further split work is cut on the main agent's recommendation (owner question timed out; reversible assumption, not an owner Decision). (3) Index store off by default, adopted assuming no known consumer (Q1 unanswered; opt-in rollback retained): app edit off 20.54 [20.414–20.667] s vs on 20.55 [20.539–20.560] s, no measurable edit-speed gain (n=2 reversed-order pairs); 744 MiB stale index removed. Evidence: `.agent-artifacts/swift-compile-time/step{1,2,3,4}-results.md` and `step{1,2,3,4}-review-disposition.md`. Planned with OracleA and OracleD (one challenge round; converged). Timebox about 1 day.

## Goal
Answer three questions cheaply, keep only what helps, and stop:
1. Do slow type-checks sit on the incremental critical path, or only in cold builds?
2. Would splitting `RepoPromptApp` pay off — does a body edit in a separate module skip the app's ~12 s emit-module job, and how often would edits land there?
3. Drop the unused 743 MB index store from dev builds, keeping an opt-in.

Starting evidence (2026-10-08, symbols off, noisy host): an app body edit builds in ~17.5 s, of which ~11.6 s is the `RepoPromptApp` emit-module job; linking is ~1 s. The emit-module job already skips non-inlinable function bodies.

## Non-goals
- Moving real code into a new module, or committing to any split.
- Fixing type-check hotspots found in Step 1 (report them only).
- Linker flags (`-no_deduplicate` doesn't exist in ld-prime; linking is ~1 s), the bridging PCH (measured 34.9% slower before), explicit modules, compile caching, lazy type-check.
- Adding conductor passthrough for compiler flags or scratch directories.

## Evidence directory
`.agent-artifacts/swift-compile-time/` (git-excluded; not committed). Raw outputs, timelines and git counts go there; this plan holds only summaries.

## Steps

### Step 1 — Slow-type-check scan (one cold diagnostic build, ~1 h)
- Change: none to the repository. With the conductor idle (`./conductor status` shows no running job), run once:
  `Scripts/canonical_swift.sh build --product RepoPrompt --scratch-path /tmp/rpce-typecheck-scan -Xswiftc -Xfrontend -Xswiftc -warn-long-function-bodies=200 -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=200`
  Save the output in the evidence directory, then delete the scratch directory.
- Validation: warnings appear (if the flag spelling is rejected, the build fails at once; fix the spelling and rerun). Dedupe by location. Classify each top item as declaration-level (stored-property or global initializer, default argument, `@inlinable`; these are type-checked by emit-module on every edit) or body-level (cold builds and the edited file only).
- Done when: a top-10 list with its classification is in the evidence directory, plus a one-line verdict: "type-check is / is not an incremental lever" (a lever only if declaration-level items total ≥ ~0.5 s).
- Step 1 — done | rounds 1/2 | open: — | downgraded: — | assumed: direct one-off run allowed (Q2); incremental recurrence inferred from cold-job attribution | deferred: hotspot fixes out of scope (OracleB N3 addressed in Step 4 `development.md` guidance)

### Step 2 — Split stand-in and edit locality (~1.5 h)
- Change: none to the repository. `RepoPromptCore`'s `RepoPromptShared` (imported by 44 app files) stands in for an extracted module.
  Alternate three body-only line-shift edits of `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift` with three of the control file `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentContextIndicator.swift`. Run each through `./conductor test --filter AgentContextRatioDisplayTests --benchmark-driver-diagnostics`, and restore both files afterwards.
  Then count commits per second-level `Sources/RepoPrompt/` directory over the last 6 months (`git log --since=6.months --name-only`).
- Validation: the driver remarks show whether `RepoPromptApp`'s emit-module job ran after a Core edit. Wall times are recorded as median and range, n=3 per side. `git status` is clean for both files.
- Done when:
  - L (Core-edit time) and D (app-edit time) are recorded.
  - Emit-module skipped: yes or no.
  - For the largest areas (Features/AgentMode, Infrastructure/AI, Infrastructure/MCP, Infrastructure/Process), p = the area's share of app-edit commits, and the estimated average saving p × (D − L) is reported.
  - Verdict: stop the split line if emit-module still runs on a Core body edit, or if no area reaches ≥ 3 s. Otherwise, recommend one bounded follow-up investigation for that area (not an extraction).
- Step 2 — done | rounds 1/2 | open: — | downgraded: — | assumed: ≥3 s threshold (Q3); 6-month window (Q4); cut split follow-up (exclusive 1.38 s; inclusive 4.36 s), owner question timed out | deferred: OracleB S2-R4 author-only recount; results in step2-results.md

### Step 3 — Index store off by default, `RPCE_INDEX_STORE=on` to opt in (~1.5 h)
- Change:
  - `Scripts/canonical_swift.sh` adds `--disable-index-store` to every invocation that already gets the dSYM hook (build, test, list, `--show-bin-path`), so build and test argv stay identical.
  - `RPCE_INDEX_STORE` unset or `off` means disabled and `on` adds nothing. Any other value exits 2 and names the two accepted values.
  - `Scripts/conductor.py` forwards `RPCE_INDEX_STORE` the same way as `RPCE_DEBUG_DSYM` (the passthrough env keys).
  - `docs/context/workflows/development.md` gets one line next to the dSYM policy, including "toggling costs one full rebuild".
- Validation:
  - (a) A settled `make dev-build` → `make dev-test FILTER=AgentContextRatioDisplayTests` → `make dev-build` sequence shows no unexpected app recompilation.
  - (b) `RPCE_INDEX_STORE=bogus make dev-build` fails loudly before Swift runs.
  - (c) `RPCE_INDEX_STORE=on` triggers exactly one rebuild and the index directory reappears.
  - (d) Advisory: two app-edit runs per setting with the order reversed, plus the first post-toggle rebuild time, reported with ranges.
- Done when: the change is committed locally, (a)–(c) pass, the stale `.build/arm64-apple-macosx/debug/index` (743 MB) is deleted, and (d) is reported for the owner to accept.
- Rollback: `RPCE_INDEX_STORE=on`, or revert the commit.
- Step 3 — done | rounds 0/2 | open: — | downgraded: — | assumed: Q1 no known index-store consumer (owner question timed out; repo/host probe only) | deferred: OracleB S3-2–S3-5 optional normalization/diagnostics/other-tree cleanup/helper reuse; advisory timing owner acceptance

### Step 4 — Owner summary and closure (~0.5 h)
- Change: add a short results paragraph to this plan's Status (verdicts and medians with ranges only), then move the plan to `docs/context/plans/completed/`. Record any durable fact in `development.md`.
- Validation: `Scripts/check-agent-context`.
- Done when: the owner has the three verdicts and the plan is archived.
- Step 4 — done | rounds 0/2 | open: — | downgraded: — | assumed: prior Q1–Q4 and cut-follow-up assumptions retained; advisory owner acceptance pending | deferred: no new work; prior optional follow-ups remain in evidence

## Decisions (owner, 2026-10-08)
- Scope: re-scope the original ideas to the evidence (cheap flag experiments, slow-type-check scan, split feasibility pilot).
- Split: a measured pilot only.
- Index store: off is acceptable if nothing consumes it; keep an opt-in.
- Timebox: about 1 day total.

## Disagreements (all settled)
- Split pilot: move 1–3 real Process files into a temporary target vs. time an edit in the existing RepoPromptCore. Settled on RepoPromptCore: it answers the same invalidation question with no code moved (both lanes agreed after round 1).
- Type-check scan: a standalone replay of the emit-module job with stats vs. one cold scratch build with warnings. Settled on the cold build: no fragile output rewriting (agreed).
- Index store: adopt only if a measured benefit appears vs. ship on the consumer check. Settled on the consumer check, which is what the owner decided; timing is advisory (agreed).
- Saving estimate: include a per-file slope term? Cut. Two modules don't make a scaling law, and the slope's source (`-driver-time-compilation`) printed no table on this setup (settled by main agent).
- Fix declaration-level hotspots (≥250 ms) in this plan? No, report only; the smallest plan wins (settled by main agent).
- Index timing depth: extra paired cold builds? Cut. The post-toggle rebuild already gives one cold number (settled by main agent).
- Extra signature-edit cascade run: cut; the cascade cost is already known (~54 s historically).

## Open Questions (assumed; the owner question round timed out)
- Q1: no editor on this host reads `.build/…/index/store`. If one does, skip Step 3.
- Q2: Step 1 may run directly through `Scripts/canonical_swift.sh` with a `/tmp` scratch directory, only while the conductor is idle.
- Q3: the advisory go threshold for further split work is ≥ 3 s estimated average saving per app edit.
- Q4: the last 6 months of git history predicts where edits will land.
