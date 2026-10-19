# Codemap automatic convergence plan

Scope: read when the task touches automatic codemap convergence on large roots: demand release and the idle ready cache, projection source-authority batching, or automatic prompt-builder root repair.
Authority: Authoritative
Evidence: `docs/plans/evidence/2026-10-18-codemap-preload-churn/` (local).
Review policy: `docs/context/review-policy.md`.

## Problem (summary)
- Cause 1: external Git index rewrites leave the codemap authority baseline stale; prompt builders never repair it (only `get_code_structure` does).
- Cause 2: on a large root every automatic call restarts the whole projection (demand start/accept/release advance the overlay contribution generation; last-holder release also clears the root-wide published graph), and a full rerun costs ~400 s (16 git spawns per candidate). Release waits on the rerun, so calls can block for minutes.

## Steps
1. Release keeps ready codemaps warm and root graph state intact; bounded release wait (Oracle seams S1 + S2).
2. Projection issues source authority once per batch window (up to 128 candidates) instead of twice per candidate (seam S5b; no config memo).
3. Automatic prompt-builder operations use the existing bounded foreground root-session repair, without in-call restart (seam S6).
4. Contract doc update and owner live acceptance (dev-app rebuild/relaunch is owner-run).

Deferred by plan: semantic coverage advances (S3), incremental rerun (S4), git config memo (S5a), semantic index generation.

## Status
Step 1 — done | rounds 2/2 | open: | downgraded: | assumed: lease-pressure eviction reaches idle records in every window (fix 2c); warm rejoins skip Git authority revalidation (R1-02, Step 4 text); S1-R2-01 fixed per reviewer's smallest fix after round 2, not re-reviewed | deferred: cold large-selection convergence (owner question); process-wide idle bound at release (R2-02/03); fence wait deadline (R1-04); coordinator deadline test (S1-02); fail-closed finalization variant (S1-A-05); publication-enabled lease check (Step 4)
Step 1b — done | rounds 1/2 | open: | downgraded: S1B-A-01 and S1B-A-08 rejected with evidence (step1b-fix1-report.md) | assumed: scope and bound per OracleA/B option-(a) assessments (evidence optA-*.md); R1-A-01 guard added after round 1, not re-reviewed | deferred: structure latency right after an automatic build and projection preload staying scheduled (Step 4 acceptance); resolution-fence wait deadline (S1B-A-11); stale owner fences after detach (R1-A-02); release-site counters need a consumer or removal (R1-A-03)
Step 2 — done | rounds 1/2 | open: | downgraded: | assumed: authority drift during the last projection batch is caught by the next foreground issuance or revalidation, not by projection (S2-R-05); prefetch inputs cannot change while the job is current (DEBUG assertion, S2-R1-03); S2-R1-01 classification fix applied after round 1, not re-reviewed | deferred: S2-R-03 probed, no bug: the foreground snapshot publishes through the engine's restartGeneration path (guard test 3ed6c66a, evidence s2r03-probe-report.md); unprobed: the staleness check's terminal cases as a cause of live publication_stale, and full-projection recovery latency (Step 4 acceptance); reader rejection of a file changed between prefetch and read is untested (S2-02); ingress-mismatch early exit (S2-R-09); unreachable-default assertions (S2-R-10); prefetch failures logged before a successful fallback (S2-R1-04)
Step 3 — done | rounds 2/2 | open: | downgraded: | assumed: event-driven recounts (file-system, Git status, readiness) count as foreground under D2 (S3-R-02/R1-03; Step 4 measures resets per minute and projection completion); automatic repair covers repository-authority drift only, binding and layout changes need a structure request (R1-02); provisional-candidate repair untested, otherwise recovers one recount later (S3-R1-01, S3-R2-01 ticket fix applied after round 2, not re-reviewed) | deferred: exact-intent prompt builds still never repair (S3-R-04, owner follow-up); graphRebuild reported when no reset ran, can mask late candidate rejections (S3-R-07/R1-06/S3-R2-03, Step 4 checks the repair counter); provisional rejections arriving during planning (S3-R2-01 A); refreshCurrentness backoff (S3-R2-02); reset during stale retry reported as publicationStale (S3-R2-04); final-demand reset untested (R1-05); exact-path hasPending overwrite (R1-08, pre-existing)
Step 4 — blocked | rounds 0/2 | open: owner live acceptance (dev-app rebuild/relaunch is owner-run; checklist step4-live-acceptance.md); keep or remove release-site counters (R1-A-03) | downgraded: | assumed: contract doc edits are docs-only, no Oracle review (step4-doc-report.md) | deferred: moving historical sections of the contract doc to an archive (proposed cut)

## Decisions
- D1: implement the three-step fix (release/warm cache + bounded wait, batched authority windows, automatic foreground repair).
- D2: approve changing the contract so foreground automatic prompt builds may run a bounded repair; background work still never repairs.
- D3: add Step 1b (released, already-admitted pending automatic demands finish into the warm cache) if OracleA and OracleB approve; both approved with changes.
