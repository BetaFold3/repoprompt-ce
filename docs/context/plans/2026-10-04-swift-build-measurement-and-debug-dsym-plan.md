# Build pipeline and conductor performance plan (Swift build/test + Python conductor)

Scope: read when the task touches Swift build/test wall-time measurement, conductor per-job phase timing, the Swift or conductor benchmark harnesses, debug dSYM generation (`SWIFT_DRIVER_DSYMUTIL_EXEC`, `RPCE_DEBUG_DSYM`), the test-artifact fingerprint or its validation sites, conductor output handling, log summaries, the XCTest runtime-ledger cache, retention, the conductor launcher/bytecode, debug packaging Swift invocations, or diagnosis of slow test-module recompiles and the pre-test residual.
Authority: Reference
Last-verified: 2026-10-07

Status: Steps 1 and 2 are owner-accepted for commit and progression under OD12, which replaces the 5 ms parser budget with 90 ms per 5 MiB and accepts this checkpoint without further qualification runs. Phase 0 is complete (§11). Both OracleA and OracleB approve the scoped Steps 1–2 r4 implementation; all blocking code findings are closed by their owning lanes. Five shared re-review rounds were used for Steps 1–2, and no production or test code changed after r4. The Oracles' earlier withholding of empirical phase acceptance remains part of the record; OD12 is an owner decision, not a new Oracle verdict or a claim that missing measurements passed. Step 1's clean no-regression qualification, Step 2's full integrated/null-job qualification and repeatable Swift timing remain follow-up evidence, not blockers for this checkpoint. Steps 3–10 may proceed next in §4 order, with their own requirements unchanged. Under OD13, Step 3 has completed **four of five shared re-review rounds**. Both fresh round-4 lanes approve the remediation code on the frozen r4 snapshot. OracleA explicitly closed S3-R0-03 as fixed, not downgraded, and S3-R3-01 as fixed; all earlier closures remain. There are no open P0/P1 findings. OD16 authorizes explicit, visible job failure at pathological D1/D2 limits; the r4 reader-completion guard prevents an otherwise successful classifying job from publishing success before its reader finishes. OracleA's new S3-R4-01 test-readiness finding is nonblocking P2 and deferred; OracleB's P3 observations are recorded below. **Step 3 is owner-accepted for commit and progression under OD17.** Current-r4 qualification passes pipe, summary, lock and classification-equivalence gates; the clean PTY output misses and narrowly contaminated memory result remain recorded as non-blocking follow-up. This is explicit measured acceptance, not a claim that those gates passed or a new Oracle empirical verdict. Step 3 is committed as `f6bc1a8e`. Step 4 remediation r1 is approved by both main-owned round-1 lanes: OracleA closes S4-R0-LOCK-IO and S4-R0-FALLBACK-COVERAGE; OracleB closes S4-R0-01–05. Both P1s are fixed, not downgraded. Its numerical gates pass on the unchanged measured path; main's independent selftest and guardrails pass. Step 4 is accepted and committed as `86e3e024`; a first signed-commit attempt failed on the 1Password agent, and the signed retry succeeded. OD6's review is discharged with idle exit and job history still deferred; no new gate or campaign is required. One shared re-review round of five was used. **Step 5 r0 drew changes requested from OracleA (S5-R0-OWNERSHIP, P1) and a conditional approval from OracleB (conditional on C1/C2). In re-review round 1 of 5 on frozen r1, OracleA closed S5-R0-OWNERSHIP as fixed but opened P1 S5-R1-STOP-PIN-ROLLBACK, and OracleB approved. Remediation r2 is implemented and independently validated on parent `86e3e024`. In round 2, OracleA explicitly closed S5-R1-STOP-PIN-ROLLBACK as fixed and lifted its acceptance withholding. OracleB's first round-2 attempt failed before completion; the owner requested a plainly worded fresh-lane retry on the same preset. That retry approved r2 and closed S5-R1-01 as fixed. Both lanes approve Step 5 and its acceptance evidence; no P0/P1 remains open. Step 5 is accepted and committed as `6adf66a9`.** **Both initial Oracle lanes approve Step 6 code with no P0/P1 findings on the frozen initial-review snapshot. Under OD18 the owner accepts Step 6 for commit and progression on current-byte CLI medians of 72.317 / 72.474 ms, explicitly carrying the missed 60 ms target as nonblocking follow-up. Improvement and p90 gates pass. No code changed after initial review; both fresh round-1 lanes lift acceptance withholding under OD18. Contribution preflight passed and files are staged; two signed commit attempts failed in 1Password, so Step 6 is not committed and Step 7 implementation has not started.** Steps 7–12 are not yet implemented; their own gates remain unchanged and debug dSYM policy is unchanged.
Decision process: this revision replaces the earlier Swift-only plan. Two independent Oracle lanes (OracleE and OracleD) received the same brief: the owner's answers, the Phase 0 results, the verified Python conductor findings, and the earlier plan. Material disagreements were relayed anonymously for two challenge rounds, and both lanes ended CONVERGED. Two disputes were settled by owner decisions and one by code verification; §9 records each. The filename is kept so existing links stay valid.

## 1. Outcome, scope, and owner decisions

Goal: measure the Swift build/test pipeline and the Python conductor **now** and **after every later change**. Then use those measurements to remove avoidable work in both:

- debug dSYM generation;
- redundant test-artifact hashing;
- per-line output locking;
- repeated summary work;
- per-job ledger copies;
- uncached launcher compilation;
- redundant packaging Swift invocations, if measured worthwhile.

Owner decisions (authoritative; they replace the earlier assumptions A1–A5):

| ID | Decision |
|---|---|
| OD1 | Scope covers both the Swift build pipeline and the Python conductor CPU/memory fixes, in one plan. |
| OD2 | This is the owner's own app, and crashes are never shared. Delayed or off-machine symbolication after skipping debug dSYMs is acceptable. |
| OD3 | Private fork with no other contributors or CI consumers, so the debug dSYM default may flip. Repository invariants still apply: coordinated `make dev-*`, just-in-time approval before a visible app launch/relaunch/stop, contribution preflight before commits, and an untouched curated XCTest ledger. |
| OD4 | Packaging consolidation is in scope now, as a measured and gated step. |
| OD5 | Test-artifact integrity: full byte hashing at exactly two points per run, before launch and after the run. No trust-by-file-identity hash memo. |
| OD6 | Idle daemon exit and persisted job history are deferred. Fix the ledger leak first, re-measure, then review (§4 Step 4). |
| OD7 | Visible tail and summary changes are accepted: carriage-return-segmented, ANSI-stripped tail entries capped at 4 KiB, and an approximate omitted-line count once deduplication saturates. Raw logs stay byte-identical. |
| OD8 | Two scratch worktrees per A/B capture (one per dSYM mode, ~9 GB each), removed after each capture. |
| OD9 | On 2026-10-05 the owner restricted the current implementation to Steps 1 and 2, authorized fixing valid review findings, and requested a commit only after implementation, validation, and both Oracle approvals. In a subsequent explicit answer, the owner chose “Keep 5 ms; try the minimal implementation.” The original parser gate remained binding until superseded by OD12. |
| OD10 | On 2026-10-05 the owner explicitly approved narrow pre-existing validation repairs: exact documentation allowlist entries for this plan and the already-committed knowledge-work report; an exact installer-test expectation matching the existing AppleEvents entitlement; and local-only Scope/routing repairs for `docs/context/review-policy.md`. No signing behavior, assertions, or policy rules may be weakened. The local policy and its validation-workflow link remain unstaged. |
| OD11 | On 2026-10-05 the owner explicitly answered “No, meet 5 ms first” when offered a commit with performance qualification deferred. The gate remained binding until superseded by OD12. A bounded worker investigation was authorized to find the smallest contract-preserving optimization. A subsequent request to permit a native-parser feasibility prototype timed out; no native architecture expansion is authorized. |
| OD12 | On 2026-10-05 the owner explicitly instructed: “consider it 90ms as acceptance, record it, commit. Then confirm me we can work from step 3->10 next, right?” The parser budget is now 90 ms of added CPU per 5 MiB, replacing OD9/OD11's 5 ms budget. The owner accepts the current reviewed Steps 1–2 checkpoint for commit and progression on the disclosed evidence, including the 82.047 ms median reader-path diagnostic, without requiring another measurement schedule. Outstanding Step 1 no-regression, full Step 2 integrated/null-job and Swift-repeatability evidence is carried forward as follow-up rather than a blocker for this checkpoint. This is explicit owner acceptance of incomplete empirical qualification, not a claim that a clean end-to-end 90 ms gate passed or a change to either Oracle's historical verdict. Follow-up evidence is to be revisited with the next relevant before/after measurements; Steps 3–10 retain their own gates and dependency order. No native parser, broader rewrite or gate changes for later steps are authorized. |
| OD14 | On 2026-10-06 the owner answered the main agent's timed-out two-part Step 3 decision request with “Approve. Also remember to address OracleA findings if you deem those are valid and not downgraded.” Asked whether approval meant bounded experimentation rather than relaxing performance gates, the main agent confirmed it did, with all gates unchanged; the owner then answered “yes, use your own judgement and I trust your recs.” OD14 authorizes **bounded PTY available-read coalescing** only: each OS read keeps its own receive timestamp, its raw bytes are written and flushed unchanged before the next read, recognized XCTest transitions stay individual and ordered, and the 256-record / 64 KiB batch caps hold. Coalescing never waits for data (no fill-buffer blocking) and keeps cancellation and watchdog responsiveness bounded. Every Step 3 performance gate still applies unchanged. OD14 grants no acceptance waiver, no gate change and no separate terminal-state or watchdog notification architecture. |
| OD15 | Same provenance as OD14, including the owner's confirmation that the approval covers disclosed repeated summary lines after saturation. It narrowly extends OD7: once a summary section's 4,096-entry deduplication memory saturates, a keep-last section (Phases, App lifecycle) may display an older line again. It must disclose this explicitly, through `displayedLinesMayRepeat` on the section and summary and a terminal note. First-lines sections must keep exact displayed lines. OD15 changes nothing else about displayed lines, does not close any review finding and waives no acceptance evidence. |
| OD16 | On 2026-10-06 the owner explicitly authorized the recommended remedy for S3-R0-03. Replying to the recommendation “explicit, visible job failure at pathological input limits”, the owner wrote “do it.” OD16 replaces silent marker loss (D1) and early application (D2) with explicit, visible job failure at the previously documented bounds. **D1:** a normalized XCTest-marker segment of an over-cap record exceeds 65,536 characters. **D2:** more than 16 transitions are pending in one over-cap record. The trigger is exact: D1 fails only when the oversized segment would match the parent's `XCTEST_PROGRESS_RE`, so ordinary large non-XCTest lines never fail. D2 fails on the 17th pending item. The failure goes through the real job lifecycle. The job becomes measurement-invalid and finalizes `failed` with exit 70, even if the child exits 0. Its reason is bounded and echoes no output. The existing XCTest monitor terminates the process tree while the reader keeps draining, and no success artifact is published. Pending transitions are never applied early, and no partial identity is used. Otherwise, transition semantics, completing-read times, bounded memory, OD14 coalescing limits and per-read raw write/flush are unchanged. Summary-only reading never classifies output or fails a job. Main records the r4 incomplete-reader guard as necessary fail-closed implementation of OD16, not a separate owner waiver: if a classifying reader still lives after the existing joins/close, its unread or unsubmitted output cannot establish whether D1/D2 occurred. An otherwise successful job therefore fails even if its input would eventually prove ordinary. This fallback preserves decided failure/cancellation outcomes and adds no unbounded reader wait; it does not promise the pre-existing macOS PTY close itself is bounded. OD16 changes no performance gate, waives no acceptance evidence and closes no finding; only the main-owned review lanes rule on S3-R0-03. |
| OD17 | On 2026-10-06, after main recommended accepting Step 3's measured gains, explicitly carrying the three missed PTY targets and narrowly contaminated memory result as non-blocking follow-up, committing Step 3 and proceeding to Step 4, the owner replied: “I approve (was away from keyboard at the time).” This resolves the prior timed-out acceptance request. The owner accepts the reviewed r4 implementation for commit and progression: PTY CPU improves 22.0% at w0 and 55.7% at w4, and w4 wall improves 24.4%; the original 50%/75% targets did not pass. Memory growth meets the numeric limit but remains inconclusive due to a 4.03-core window against the 4.0 cutoff. No benchmark thresholds, sample minima or contamination labels are rewritten. These shortfalls are non-blocking follow-up, not fabricated passing evidence. Both Oracle code approvals and all existing correctness contracts remain in force; later steps retain their own requirements. |
| OD18 | On 2026-10-07 the owner replied “do it” to main’s recommendation: “accepting the measured improvement and recording the 60 ms miss as nonblocking follow-up,” followed by “May I proceed on that basis?” This explicitly accepts Step 6 for commit and progression on the reviewed implementation: current-byte help/status medians are 72.317 / 72.474 ms versus parent 108.266 / 108.636 ms, about 36 ms faster, with passing improvement and p90 gates. The ≤60 ms reference target did not pass; it remains recorded as nonblocking follow-up, not fabricated passing evidence or a new code-review verdict. Main assigns the accepted nonblocking follow-up to Step 12 residual diagnosis, where startup cost will be revisited and any separately scoped optimization recommendation recorded (main's placement, not quoted owner wording); no deadline to attain 60 ms and no lazy-import, interpreter-flag or shell rewrite is authorized. Correctness contracts, both required Oracle reviews, contribution preflight and later-step gates remain unchanged. This resolves the earlier timed-out question and supersedes only Step 6’s absolute-target exit condition. |
| OD13 | On 2026-10-05 the owner explicitly requested implementation of Steps 3–12. Steps run in §4 order through scoped workers, one step at a time; each worker owns only its step's production/test changes and evidence. Review ownership is the main agent's: it alone calls OracleA and OracleB, with a cap of 5 re-review rounds per step; workers do not review. A step is committed only after its own gates pass and both Oracle reviews approve. No gate is waived or relaxed by this authorization; OD12 applies only to the Steps 1–2 checkpoint. |

Not in scope:

- Rust or Go ports. They were evaluated and deferred: every measured win comes from avoided work, not interpreter speed.
- Release packaging behavior, signing, Sentry symbol upload, release channels.
- Application Swift sources and curated ledger rows. Probe sources exist only in scratch worktrees.

## 2. Baseline evidence (2026-10-04, reference host)

Host: 28 cores, 256 GB RAM; swift-driver 1.148.6, Apple Swift 6.3.1. These are reference-machine numbers, not portable promises. Phase 0 details are in §11.

### 2.1 Swift pipeline

| Measurement | Result | Source |
|---|---|---|
| Cold coordinated probe test in a fresh worktree | 304.6 s client wall; 194.0 s SwiftPM-reported build; 105.6 s residual; 8.7 GB `.build` | Phase 0 |
| Warm null probe test | 0.34–0.36 s build, 0.7 s residual, ~1.1 s execution | Phase 0 |
| One-file test edit, dSYM on | 14.2–14.9 s build, 18.9–19.5 s client | Phase 0 |
| One-file test edit, dSYM skipped | 7.0–7.5 s build, 11.2–11.7 s client: **about 7.3 s build / 7.8 s client saved per test relink** (pilot, small sample) | Phase 0 |
| Residual after any one-file relink | 3.4 s in both modes, so not `dsymutil` | Phase 0 |
| Mode-switch cost | First switch to a never-seen environment: 28.4 s replan. Later switches: about 4.1 s. A plain null build: 0.35 s | Phase 0 |
| Standalone `dsymutil` on the aged main checkout's 492 MB test binary | 11.7 s, with 48 missing-`.pcm` warnings | Phase 0 (U3) |
| Test dSYM | 630 MiB **inside** the bundle at `RepoPromptCEPackageTests.xctest/Contents/MacOS/RepoPromptCEPackageTests.dSYM`; content-hashed by every fingerprint | Earlier session |
| App dSYM | 288 MB, rewritten at every app link | Earlier session |
| Historical full test-module rebuilds | 7 retained jobs rebuilt 579–623 test files, with an extra 38–67 s residual | Retained logs |
| App packaging, no change | 9.5–13 s: three `--product` builds (about 1–2 s each) plus `--show-bin-path` plus signing (about 4 s) | Retained logs |
| Machine-wide contention | One null sample waited 13.8 s for a heavy slot held by another repository's job | Phase 0 |

### 2.2 Python conductor (historical baseline: `Scripts/conductor.py`, 6,654 lines at fa43fe38)

Line references in this subsection describe that baseline, not the later implementation. Prototype numbers came from scratch prototypes in `/tmp/conductor-bench/`; none were applied to the repository.

| Area | Evidence | Current | Prototype |
|---|---|---|---|
| Per-job XCTest runtime-ledger copy | `_load_xctest_method_runtimes_locked` `:3489-3518` copies the ledger per job, never cleared (field `:1985`); loaded under `self.condition` | 1.54 MiB and 43 ms per test job; 85.8 MiB at 56 retained test jobs, about 306 MiB extrapolated at 200 | One shared copy: 1.55 MiB, one 43 ms load |
| Output handling | Per line: lock, `notify_all`, pipe flush (`:3382-3420`). Pipe `readline()` is unbounded (`:1007`); the PTY buffer only shrinks on `\n` | 5 MiB log: 142 ms CPU with 0 waiters; 961 ms wall / 2,001 ms CPU with 4 waiters | Per-chunk batching: 17 ms; 20–21 ms with waiters |
| Carriage-return folding | About 101k CRLF, about 9k bare `\r`, about 9k `\x1b[2K` per compiling log; LF "lines" reach 190–211 KB | 30-line tail not byte-bounded; regexes scan 200 KB strings | — |
| `OutputSummarizer` | `FAILURE_RE`/`SWIFT_ERROR_RE` searched twice per line. Computed before checking for an existing summary (`:3879-3892`). The completion thread and status/wait can each compute one | Largest log: 741 ms | Search once plus casefolded keyword precheck: 255 ms, 0 mismatches over 143 logs × 4 modes |
| `SummarySectionBuilder.seen` | `:1560-1581`, unbounded | 14.75 MiB at 100k unique lines | Bounded: 0.001 MiB |
| Test-artifact validation | Three full evaluations (client `:6489`, enqueue `:2555→:2247`, execution `:3023→:2247`), plus prelaunch `:3055` and post-run `:3271/:3282`. `test_artifact_fingerprint` (`:557-629`) SHA-256s the executable and the **content** of every closure file, including the nested 630 MiB dSYM. `evaluate_test_artifact` (`:665-725`) has no schema-version check | Executable hash 470 ms × 5; `swift --version` 97 ms per evaluation; about 3.2 s integrity overhead per `test-artifact` run | About 1.8 s (estimated from components, not end-to-end) |
| Launcher | `conductor` execs `python3 Scripts/conductor.py`; a `__main__` script is never bytecode-cached. Job runners start the same way | 36.5 ms compile per call; `--help`/`status` 92/93 ms | 54/57 ms |
| Retention | `_retention_pass_locked` `:4183-4234` scans the jobs dir under the lock on each transition. History lives only in memory; no idle exit | — | — |
| Daemon memory | Main daemon physical footprint 137.5 MiB (`vmmap`), RSS 194.7 MiB; 7 daemons about 711 MiB RSS | — | — |

Other facts the plan depends on:

- Every coordinated Swift call goes through `Scripts/canonical_swift.sh`, which builds a byte-identical `env -i` environment, because SwiftPM keys its caches on the child environment. Phase 0's 28 s first-switch replan confirms that cost.
- Environment forwarding is a whitelist: `OperationRegistry.PASSTHROUGH_ENV_KEYS` (`:2137-2147`), with `DEBUG_ENV_KEYS` (`:2086-2090`) covering `REPOPROMPT_DEBUG_APP_ROOT`, `_BUNDLE` and `_CLI_INSTALL_PATH`.
- Conductor state lives in `~/Library/Application Support/RepoPrompt CE/conductor/<repo-hash>/`. Each checkout, including a scratch worktree, has its own daemon. Heavy and XCTest slots are machine-wide locks under `/tmp/repoprompt-ce-dev-locks-<uid>/`.
- `make conductor-selftest` runs `Scripts/test_conductor_output.py` and `Scripts/test_conductor_lifecycle.py`.
- No file under `Tests/` uses `import Testing`; the Swift Testing pass takes 0.001 s.

## 3. Design principles

1. **Measure first, one change at a time.** Every optimization lands as its own step, with an immediate-parent capture and a candidate capture under identical fixture, instrumentation, and environment. Changes that remove overlapping work (fingerprint exclusion, validation dedup, dSYM skip) never share one table.
2. **Never perturb the measured invocation.** Passive capture changes no Swift argv, no Swift child environment, and no raw log bytes. Driver diagnostics and process sampling run only in explicitly marked diagnostic captures, which never count as acceptance samples.
3. **Unknown is never zero.** Every span carries a quality label: `measured_wall`, `measured_cpu`, `observed_wall`, `reported_duration`, `sampled_window`, `unavailable`, or `not_applicable`. Unavailable values are null.
4. **Keep integrity byte-exact.** Executable and closure content hashes stay full SHA-256 (OD5). Only the exact driver-generated test dSYM leaves the fingerprint.
5. **`canonical_swift.sh` stays the only environment-injection point.** The debug dSYM policy is decided there, by build configuration, and is identical for every debug subcommand.
6. **Fail toward symbols and toward existing behavior.** Release builds, unknown or conflicting configurations, and any non-empty `REPOPROMPT_ENABLE_SENTRY` keep today's full environment. Telemetry, cleanup, and history failures never change a job's state, exit code, `measurement_invalid`, or ticket publication.
7. **Targeted changes, no refactor.** `Job`, `OperationRegistry`, `OutputSummarizer`, scheduling, and process ownership stay in `conductor.py`. New modules hold only pure logic, harnesses, or helpers.

## 4. Steps

Order: 1 → 2 → 3 → (4 → 5 → 6) ‖ (7 → 8) → 9 → 10 → 11 → 12. Steps 4–6 do not depend on Steps 7–8. Step 9 and everything after it require Steps 3 and 8.

### Step 1 — Conductor benchmark harness and "before" capture

`Scripts/conductor_benchmark.py`: a committed, versioned harness, reconstructed from the `/tmp` prototypes rather than copied unreviewed. Its subcommands drive the target revision's real implementation, through explicit adapters:

| Subcommand | Workload | Seams |
|---|---|---|
| `output` | A deterministic seeded 5 MiB log through both transports, with 0 and 4 real waiting clients. Bytes written must equal bytes read | Factor the reader loop as `_pump_output(fd, sink)` (the only `conductor.py` change in this step) |
| `summary` | `OutputSummarizer.summarize_file` on the fixture, plus optional retained logs (`--logs-dir`, never committed); compared against a golden file and the previous implementation | — |
| `mem` | Ledger loads × N jobs, and `seen` at 100k and 1M unique lines (`tracemalloc`) | — |
| `artifact` | Fingerprint and evaluation call counts, bytes hashed, wall time, using a generated 468 MiB executable and a fake bundle with a 630 MiB dSYM under `/tmp` | — |
| `cli` | `./conductor --help` and `./conductor status`, 30 runs each | — |
| `rss` | A fixture daemon with 56 synthetic retained test jobs: physical footprint (`vmmap`/`footprint`) is primary, RSS corroborating | Reuse the `test_conductor_lifecycle.py` fixtures |

- Fixtures: `Scripts/Fixtures/conductor-benchmark/v1/` (manifest and seeds; large inputs are generated at runtime).
- Make targets: `dev-conductor-bench` (`output summary mem cli`; a paired capture at manifest counts took 593 s on the reference host) and `dev-conductor-bench-full` (adds `artifact rss`; 1,564 s paired at manifest counts, 2,405 s with 90 fast pairs). `TARGET_A`/`TARGET_B` take `NAME=ROOT` (paths may contain spaces), `CLASS_SAMPLES=fast=90` raises per-class counts, and `WORKLOADS`, `CAPTURE_ID`, `LOGS_DIR` are passed through quoted. `dev-conductor-bench-compare` applies the gates (`PROFILE`, `CONFIRM_BASELINE`/`CONFIRM_CANDIDATE`, `REPORT`); `make` exits 2 for any nonzero harness code, so the printed `conductor-bench-compare exit N` line, or a direct `python3 Scripts/conductor_benchmark.py compare` call, carries the exact code.
- Captures: `<state>/benchmarks/conductor/<capture-id>/`. Distilled rows go to §11.
- Statistics: 30 paired samples for fast workloads; at least 10 fresh-process pairs for retained-memory measurements.
- Comparison exit codes: `0` qualified, `1` established regression, `2` inconclusive, `3` harness failure. Missing or incompatible evidence never passes.
- Exit: the unmodified-code baseline is captured and recorded in §11.

### Step 2 — Passive per-job timing (first production change)

New `Scripts/swift_pipeline_metrics.py`: a pure marker parser, per-job recorder, interval derivation, schema, `RotatingJsonl`, and comparison statistics.

Recorder interface:

- `record_boundary(name, monotonic_ns, metadata)`
- `observe_records(records)`
- `record_operation(name, duration_ns, counters, origin)`
- `finalize()`

The recorder has its own private lock. That lock is never taken while holding `self.condition`, and `self.condition` is never taken while holding it.

Conductor boundaries recorded:

- client artifact-evaluation duration (advisory, bounded, excluded from request identity);
- request acceptance and lane dispatch;
- source snapshot and prepare;
- each slot wait, with a `contended` flag based on whether a foreign holder was actually observed;
- just before and after `Popen`;
- output receipt, timestamped immediately after `read_chunk()` and before flush or lock;
- observed exit;
- post-run provenance;
- lane release;
- summary work and retention work, recorded separately.

Fingerprint/evaluation helpers gain an optional sink that records calls, bytes hashed, and duration per origin.

Durations from different processes are never subtracted. A single wall-clock anchor exists only to correlate with XCTest's printed timestamps. Python CPU is measured as thread CPU where the work belongs to one thread.

Swift observations:

- Segments open at command boundaries (`$ …`, `+ …`); packaging `==>` headings supply context only.
- Events recognized: planning, `Write`, compile, emit-module, link, build-complete, suite, and method.
- Recorded per segment:
  - time to first build work;
  - per-module unique compiled-file counts;
  - the link → build-complete span (observed, never labeled isolated `dsymutil` time);
  - SwiftPM's reported duration;
  - the signed pre-completion residual;
  - build-complete → first suite and → first method;
  - XCTest span;
  - `.pcm` warning count;
  - effective dSYM policy and symbol evidence (Step 10).

Provenance: `conductorDigest`, a content digest of the conductor implementation bytes computed at module load. It is recorded in status, job metadata, telemetry rows, and benchmark metadata, with daemon and runner digests attributed separately. It is informational only: no handshake enforcement and no `PROTOCOL_VERSION` bump.

Bounds per recorder:

- 20,000 events and 4 MiB of serialized events;
- 10,000 file identities with a 2 MiB text budget;
- 256 module aggregates;
- 64 segments.

After a cap, the affected values are marked partial or inexact.

Storage:

| Artifact | Lifetime |
|---|---|
| `<ticket>.timing-events.jsonl`, `<ticket>.timings.json` (atomic replace), optional `<ticket>.runner-timings.json` | Normal 24 h / 200-job retention; added to the job's retained paths and to the orphan sweep |
| `<state>/metrics/build-metrics.jsonl` | `RotatingJsonl`: 32 MiB active file plus 2 rotated generations, appended outside the scheduler and recorder locks. This is performance history, not reconnectable job history |

Surface:

- an additive `phaseMetrics` (schema 1) in the status/wait payload; result delivery does not wait for persistence, so it may initially be `pending`. Read `job status` or `metrics --ticket` after persistence when complete metrics are needed;
- `./conductor metrics [--last N] [--kind K] [--ticket T] [--json]`, which reads the history client-side;
- `make dev-metrics`;
- `RPCE_CONDUCTOR_TIMING=off`, read at daemon start, as the kill switch for overhead proofs.

Gates:

- Median added null-job wall below max(50 ms, 1% of process wall) over 30 paired on/off runs.
- Parser CPU no more than 90 ms per 5 MiB above the output path alone (OD12; originally 5 ms). OD12 owner-accepts the current checkpoint without further qualification; later measurements must retain honest contamination and completeness labels.
- Raw log bytes unchanged.
- `make dev-test FILTER=MCPInitializeCompatibilityTests` twice; `phaseMetrics` reproduces the no-change numbers and agrees with log timestamps within 100 ms.
- Deterministic tests in `Scripts/test_swift_pipeline_metrics.py`, using fixtures under `Scripts/Fixtures/build-metrics/v1/` (`null-test`, `compile-cr`, `package-debug`, `parallel-test`, `artifact`).

### Step 3 — Output path and summaries (land together; they share one splitter)

New `Scripts/conductor_output.py`: a streaming record splitter and normalizer, shared by the live tail, telemetry, and retrospective summaries.

- **Reads.** The PTY keeps its bounded `os.read(64 KiB)`. The pipe's `readline()` becomes an available-data read (`read1(64 KiB)` or `os.read`), never a fill-the-buffer read.
- **Splitter.** It handles split UTF-8, split ANSI sequences, CRLF across reads, and EOF without a newline. Records end at `\n`, `\r\n`, or a bare `\r`. A bare `\r` emits its record immediately and swallows one following `\n`, even across a read boundary. Pending records are capped at 64 KiB, with bounded prefix/suffix diagnostics. Each record carries its sequence number, receive time, delimiter kind, bounded text, and truncation status. Progress parsing happens before display shortening.
- **Reader contract, per read:**
  1. Capture the receive time.
  2. Write and flush the raw chunk unchanged.
  3. Split, classify, and feed telemetry, all outside the lock.
  4. Acquire `self.condition` once, extend the tail, and apply **every recognized XCTest transition individually and in order** through today's per-line transition body, extracted without semantic edits. Each transition increments the existing `xctest_progress_sequence` and uses the read's receive time.
  5. Call `notify_all` once if any records arrived.

  Only notifications are coalesced. A record completed by a later read takes that read's timestamp. Watchdog change detection uses the sequence, not timestamp equality, and deadlines still use receive times. Batches are at most 256 records or 64 KiB.

  **OD14 amendment (PTY only).** After a blocking read, the reader may take further reads while `select(timeout=0)` reports data, never waiting for more, up to 64 KiB, 64 reads or 5 ms per group. Budgets are checked before a read starts. Each further read requests at most the group's remaining bytes, and none starts once 5 ms have passed since the first read's receive time. Only the processing of a read already taken can end after the budget. Steps 1–2 still run per read, so each read keeps its receive time (and wall time), its unchanged write and flush, and its order. Steps 3–5 run once per group. An OD16 over-cap failure ends a group, so the job fails right after the reads that caused it. The pipe is unchanged.
- **Over-cap records (S3-R0-03; D1/D2 bounds under OD16, r3).** Before any bytes are dropped, a record that exceeds the 64 KiB cap streams through bounded whole-record views.
  - With the watchdog enabled, it is classified segment by segment in `str.splitlines` terms, with segment content capped at 64 Ki characters. Its transitions ride on the record and take the receive time of the read that completes it, like any line.
  - **OD16 bounds.** Exceeding either bound fails the job visibly:
    - D1: a segment whose normalized content exceeds 65,536 characters and would match `XCTEST_PROGRESS_RE`. It is decided exactly in bounded memory, from a 12-character head, a 16-character stripped end and the `)`-free run state.
    - D2: a 17th pending item in one record.
  - On failure, nothing pending is applied, early or later, and classification stops for the rest of the job. Records before the failing one keep their transitions; later records still feed the raw log, telemetry and tail. Over-cap `Build complete!` segments and markers at or under 65,536 characters keep normal semantics.
  - **Reader completion (r4).** A classifying job can succeed only after its output reader has finished. If the reader is still alive after `_run_job`'s two bounded joins (`OUTPUT_READER_JOIN_SECONDS` each) and the reader close, a job that would otherwise succeed becomes measurement-invalid: it fails with exit 70, gets a bounded reason, and publishes no ticket. An outcome already decided keeps its own reason. Remaining job processes get the bounded TERM/KILL escalation. The reader is not waited for further.
  - Its tail entry and summary line come from the first visible characters of the whole record, with ANSI removed in one pass exactly as from the full text, not from the kept 64 KiB.
- **Tail.** 30 records and 64 KiB total; each displayed record is ANSI-stripped and capped at 4 KiB (OD7).
- **Summaries.**
  - `summarize_file` streams the raw log through the same splitter.
  - Each classification regex runs once per record, behind a casefolded keyword precheck that covers every regex alternative, with a fixture per alternative.
  - `SummarySectionBuilder.seen` is bounded to 4,096 entries per section. Behavior is exact before saturation; afterwards the summary exposes `deduplicationLimited` and `omittedLineCountQuality: exact | upper_bound`, and `SUMMARY_VERSION` goes from 1 to 2. Under OD15, a keep-last section may show an older line again after saturation; it then sets `displayedLinesMayRepeat`, and the terminal prints a note. The top-level `omittedLineCountQuality` is always `exact`, because the top-level count is exact; upper bounds are rendered as "at most N".
  - **Single-flight:** `summary_state: none | running | complete | failed` plus an event. The first caller claims the work under the lock and computes outside it. Racing callers join and honor their own deadlines. Every exception publishes a minimal error summary and releases the pin. A `job_wait` whose deadline expires while it is joining returns `summaryPending`. The client then shows a minimal pending summary without rescanning the log, and re-polls for at most 60 s. Summary pins, held from claim or join through payload construction and released on every path, defer retention of the job and its log; the last unpin reruns retention.

Gates (`dev-conductor-bench-compare` plus self-tests):

| Workload | Gate |
|---|---|
| Output, 0 waiters | CPU at least 50% lower; reference target ≤50 ms (now 142) |
| Output, 4 waiters | CPU and wall at least 75% lower; reference targets ≤100 ms CPU, ≤250 ms wall (now 2,001 / 961) |
| Lock behavior | p99 batch hold ≤5 ms, measured in separate profiled runs; no progress loss or reordering |
| Summary | CPU at least 35% lower on the fixed corpus; exactly one scan per completed log |
| Summary memory | Caps hold at 1M unique records; retained growth from 100k to 1M records under 1 MiB |
| Classification equivalence | Identical ordered `(kind, testName)` sequences against today's classifier over the fixture and retained logs. Allowed differences: events previously hidden behind bare `\r`, each listed explicitly. Under OD16, input beyond the D1/D2 bounds fails the job visibly instead; the corpus must produce no OD16 failure |

Tests:

- "Test A passed" and "test B started" in one chunk leave B active, with B's budget, `started+1`, and two sequence values.
- A record split across reads gets the second read's time.
- Delayed lock acquisition; dense empty records; unterminated multi-megabyte output; cancellation.
- Byte-identical raw logs.
- Tests that asserted the old tail shape assert the new exact shape; they are not loosened.

### Step 4 — Shared runtime ledger, then a footprint review

- **Cache.** A daemon-owned `RuntimeLedgerCache` holds one current immutable snapshot (`MappingProxyType` of `(suite, method) → runtime_seconds`). Its key is the resolved path plus device, inode, size, `mtime_ns` and `ctime_ns`.
- **Loading.** The ledger is loaded before process start, outside `self.condition`, with private single-flight. Stat before and after the read; on a change, retry once, otherwise fall back to the existing flat budget with a diagnostic. Parsing semantics are unchanged: incomplete, negative and non-finite values are ignored, and the first valid row wins.
- **Lifetime.** Active jobs pin their snapshot. The terminal transition clears `Job.xctest_method_runtimes`. Older snapshots survive only while active jobs pin them, so at most 2 are resident during a ledger update.
- **Under the lock.** `_set_xctest_active_method_budget_locked` performs no file I/O.
- **Gates.** One parse per unchanged identity. Ledger-attributable retained heap ≤4 MiB after 200 jobs and at least 95% below baseline.
- **Review trigger (OD6).** After this step, measure a fresh daemon's **physical footprint** after 56 retained test jobs. Reopen idle exit and job history for review — not automatic implementation — if the footprint exceeds 70 MiB or the owner routinely keeps 5 or more daemons resident. The current count of 7 daemons already meets the second condition, so expect the review.

### Step 5 — Retention off the scheduler lock

- `_retention_pass_locked` keeps only the in-memory eviction decision.
- A single maintenance worker does the scans, stats, unlinks and rotation outside `self.condition`. It is signaled by job transitions and coalesces pending work; orphan sweeps run at most once a minute.
- Deletion is limited to the exact generated families: logs, diagnostics, timing sidecars.
- Files are pinned while summaries or telemetry finalization use them. Pins are released in `finally`, so a late write can never recreate a pruned file.
- Policy stays 24 h / 200 jobs. Cleanup failures are retried by later sweeps and never change job outcomes.
- Status for an evicted ticket stays "unknown", as today.
- Gates: no scan, stat or unlink under the scheduler lock; status/enqueue latency during a blocked cleanup ≤50 ms.

### Step 6 — Cached-import launcher

- **Entry point.** New `Scripts/conductor_entry.py` loads `Scripts/conductor.py` as module `rpce_conductor`, via `spec_from_file_location` and `SourceFileLoader`. The module is registered in `sys.modules` before `exec_module`, because dataclasses look it up. The entry then calls `main()`. Direct execution of `conductor.py` keeps working.
- **Routing.** The root `conductor` script, `OperationRegistry._internal_argv()` (job runners), daemon start, launchd `ProgramArguments`, and the restart paths all use the entry, with `sys.executable`.
- **Checked-hash bytecode.** Same-size edits within the same mtime second would otherwise load stale timestamp-validated bytecode. If the `.pyc` is missing or not checked-hash, the entry bootstraps it once with `py_compile` in `CHECKED_HASH` mode; normal import validation follows (SipHash of about 280 KB, under 1 ms).
- **Unwritable cache.** Fall back to a fresh empty temporary cache prefix with writes disabled, never an old cache. Remove the prefix at exit.
- **Ignore rules.** `Scripts/__pycache__/` is git-ignored and guardrail-clean.
- **Running daemons.** A daemon that outlives a conductor edit is today's behavior and stays unchanged; `conductorDigest` (Step 2) makes it visible.
- **Gates.** `cli` median ≤60 ms and at least 15 ms lower, with no p90 regression beyond 10% and 10 ms. Tests cover: a same-size, same-mtime edit runs the new code; missing, malformed or unwritable caches; concurrent first imports; an interpreter change.

### Step 7 — Test-artifact validation dedup (ticket format unchanged)

| Site | New work |
|---|---|
| Client `:6489` | Ticket parse, version message, executable/bundle existence. No hashing, no `swift --version`, no source snapshot |
| Enqueue `:2555` | The same cheap admission. Scope `pending`. No source snapshot: source-stale artifacts are intentionally runnable, so an early snapshot could not reject anything and would be stale by launch |
| Execution (after lane and XCTest-slot admission, immediately before process creation, outside `self.condition`) | **One** full `evaluate_test_artifact`: toolchain once, authoritative source scope, full fingerprint. Its result feeds command construction |
| Post-run `:3271/:3282` | Exactly today's work: source snapshot plus full fingerprint, with no added `swift --version`. The parallel lane keeps its existing post-run toolchain verification |

- Client-supplied derived artifact fields (`artifactPath`, `artifactFingerprint`, scope fields, ticket snapshot, build-ticket id) are stripped during normalization; only the execution-time result fills them.
- File identities (device, inode, type, size, `mtime_ns`, `ctime_ns`) are captured while hashing and rechecked immediately before launch. They detect races; they never replace hashes.
- Outcomes:
  - A stale or mismatched artifact before launch fails before process creation, with today's stale-artifact exit status (U9).
  - A post-run byte change invalidates an otherwise successful result.
  - An earlier failure, timeout or cancellation keeps its primary outcome, and the integrity failure is attached.
- **Gates.**
  - Per `test-artifact` job: 2 executable hashes, 2 closure walks, 2 source snapshots, 1 `swift --version`, and none at client or enqueue (lifecycle counter test).
  - The `artifact` workload's wall and the telemetry `artifact.*` sum are ≤0.70× the pre-step baseline from the same worktree.
  - Tests cover queued replacement, same-size corruption with restored mtime, resource changes, mutation during hashing and during execution, source-stale passes, and cancellation before slot acquisition.

### Step 8 — Fingerprint v2: exclude exactly the generated test dSYM

- **Exclusion.** Prune only the real directory `executable.parent / (executable.name + ".dSYM")`, with no-follow traversal. Every other `.dSYM` stays content-hashed. If validation finds another driver-generated adjacent dSYM in the closure (U20), extend to the exact `<member>.dSYM` next to each closure Mach-O — never a suffix match.
- **Unchanged.** The full executable SHA-256, and per-file `relpath\0size\0mtime_ns\0sha256(content)` manifest lines for every other file.
- **Domain separation.** The closure digest becomes `SHA-256(b"rpce-runtime-closure-v2\0" + manifest)`. Old code computes v1 digests and therefore always rejects v2 tickets; new code rejects v1 the same way.
- **Version.** Tickets carry `fingerprint_version: 2`, used for the specific "ticket predates fingerprint v2 — re-mint with a source-validating run" message. Root-ticket and parallel-candidate schema versions advance together, and all readers and writers change atomically.
- **Unchanged gates.** `artifact_env_gates()` is untouched. dSYM policy is informational ticket metadata only.
- **Gates.**
  - Creating, deleting or regenerating `<exe>.dSYM` leaves the fingerprint unchanged.
  - An old-commit conductor (scratch checkout) rejects a v2 ticket.
  - With dSYMs on, evaluation time with the 630 MiB dSYM present is within 50 ms of the time without it.
  - Bytes hashed per call drop by exactly the excluded subtree.
- **Validation.** `make dev-test`, `make dev-test-artifact`, and `make dev-test-parallel`, each with `FILTER=MCPInitializeCompatibilityTests`; then one unfiltered `make dev-test-parallel`, which mints a v2 ticket.

### Step 9 — Swift benchmark harness and baseline

`Scripts/swift_build_benchmark.py` is a **slot-free foreground orchestrator**.

- **Worktrees.** It creates two detached same-SHA worktrees under `<state>/benchmarks/worktrees/`: `ab-on` and `ab-skip`, one per dSYM arm (OD8). Each has its own daemon and its own scratch `REPOPROMPT_DEBUG_APP_ROOT`, `REPOPROMPT_DEBUG_APP_BUNDLE` and `REPOPROMPT_DEBUG_CLI_INSTALL_PATH`; packaging caches are redirected if U12 shows they live outside the worktree.
- **Jobs.** It submits ordinary coordinated jobs to each worktree's daemon and never holds a slot itself, which would deadlock its own jobs.
- **Fixtures.** Probe templates live in `Scripts/Fixtures/swift-build-benchmark/v1/` and are copied only into scratch worktrees: a one-method XCTest suite that passes filter preflight through the source-suite fallback (U2), and a body-only app probe in a leaf file. Edits apply only between terminal jobs, after checking the expected prior bytes.
- **Rules.** Never copy `.build` between worktrees. `clean` stops each worktree daemon and then removes the worktree.

| Scenario | Measures |
|---|---|
| `null-test` / `test-body` | No-change floor / one-file test compile plus relink (the primary dSYM signal) |
| `null-app` / `app-body` / `app-body→test` | App build floor / body-only app edit / cross-module fan-out |
| `add` / `remove` input, `touch-tests`, `broad-test` | Input-set invalidation, mtime churn, a true full test-module rebuild |
| `artifact` | Repeated `test-artifact` after a valid ticket |
| `null-package` / `app-body-package` | Fully verified debug packaging with scratch destinations, never launched (Step 12) |
| `cold` | A fresh `.build`; recorded and never gated; also hosts residual experiments R1 and R2 (Step 11) |
| `diag-driver` | `-driver-show-incremental -driver-time-compilation`, run only in a separate later capture |

Sampling:

- **Start precondition.** All machine-wide slots are free (probed by non-blocking acquisition, released immediately), the main-tree conductor is idle, load is below the calibrated threshold, and the thermal state is nominal.
- **Order.** Two primers per command and mode, then **5 balanced ABBA blocks** alternating across the two worktrees, giving 10 samples per arm. Re-prime an arm after any environment change or `conductorDigest` change; record the first switch (about 28 s) and later switches (about 4.1 s) separately.
- **Contention.** Discard samples with observed foreign contention, retry them in place up to 3 times, then replace the whole block. Stop as inconclusive once invalid attempts exceed 10% after 20 attempts. Never stop another repository's daemon, change slot counts, or hold slots.
- **A/A calibration (on/on across both worktrees).** The entire paired block-bootstrap 95% CI of the difference must lie within ±max(150 ms, 3% of the pooled median), and |Δmedian| must also be within that bound. If not, extend to 10 blocks before declaring failure. The calibrated on/on samples double as the full-mode **before** baseline.
- **Comparison.** Captures must match hardware, toolchain, SDK, architecture, fixture version, command, test scope, cache class, instrumentation mode, and `conductorDigest` class, apart from the declared treatment.
- **Regression floors.** A slowdown counts only if it exceeds both 5% and a per-class floor: 2 ms for fast Python timing, 100 ms for artifact wall, 0.5 s for Swift and packaging scenarios. It must be confirmed by a second batch whose paired CI lies above zero.

Make targets: `dev-bench NAME=… REF=… SCENARIOS=… BLOCKS=…`, `dev-bench-compare BASELINE=… CANDIDATE=…`, and `dev-bench-clean`.

### Step 10 — Debug dSYM default: skip (with `on` as the escape hatch)

**Policy in `canonical_swift.sh`.**

- `RPCE_DEBUG_DSYM=on|off`. Unset means `off` (skip). Any other value, including empty, fails with exit 2 before any mutation.
- The policy is classified by **configuration only**:
  - recognized debug (no `-c`, or `-c X`, `--configuration X`, `--configuration=X` with value `debug`) is eligible for skip;
  - release, unknown or conflicting configurations get today's full environment, plus a one-line warning if `off` was requested;
  - any non-empty `REPOPROMPT_ENABLE_SENTRY` forces full.
- Every eligible debug invocation gets the **identical** environment, whether it is `build`, `test`, `test list`, `--skip-build`, `--show-bin-path` or `package`. Queries therefore never trigger replans.
- Only the effective skip environment adds exactly `SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true`; the switch itself never reaches Swift.
- A stderr banner states the effective policy and the reason.

**Conductor.**

- `RPCE_DEBUG_DSYM` joins `PASSTHROUGH_ENV_KEYS` and normalized request identity (U8).
- Telemetry records the effective policy.
- Per-job effectiveness is `exercised | not_exercised | ineffective | unknown`, using pre/post UUID evidence. A stale dSYM left after a skipped relink does not by itself prove hook failure. `ineffective` adds a warning line and never counts as skip evidence.

**Cleanup.** Pre-build only, in `Scripts/debug_dsym.py`, invoked only when skip is effective and a candidate exists.

- Candidates: depth-1 product dSYMs in the debug bin dir, and executable-adjacent test-bundle dSYMs (root, core and provider bundles).
- The bin dir is derived as `<package>/.build/<arch>-apple-macosx/debug` without spawning Swift; a missing directory means no cleanup.
- Traversal is no-follow and descriptor-anchored. Paths must be confined under `realpath(<package>/.build)`, with real-directory ancestry. Bounds: 4,096 directory entries, 64 candidates, 20,000 visited entries, depth 16.
- A candidate is deleted **only if its DWARF UUID set differs from the executable's `LC_UUID` set**. A matching dSYM, such as a fresh `make dev-dsym` result, is kept. An unreadable one is kept with a warning.
- Cleanup errors warn and never change Swift's exit or signal behavior.

**Regeneration and qualification.**

- A coordinated `dsym` operation, `make dev-dsym [PRODUCT=all|RepoPrompt|repoprompt-mcp|repoprompt-gateway|root-tests]`, holds the build lane and the heavy slot.
- It generates into a temporary directory, verifies the UUIDs, then replaces the dSYM, and prints the duration and `.pcm` warning count.
- `make dev-dsym-check` runs the scripted LLDB/XCTest qualification below, which also holds the XCTest slot.
- Phase 0 showed a null build does not regenerate symbols after switching back to `on`, so `on` affects only future links; immediate restoration needs `dev-dsym`.

**Debuggability checks.** Both modes run on the same tree.

- C1 to C4 run on a fresh worktree.
- C1 and C2 also run on the **aged** main checkout, which has the 48 missing-`.pcm` references (U3).

| Check | Pass |
|---|---|
| C1 static | `image lookup -v` file:line entries and file/line breakpoints resolve for app and test code (already passed statically in Phase 0, fresh tree) |
| C2 live | Stop a scratch XCTest at a breakpoint. `frame variable` shows ordinary, generic, async and Foundation/Objective-C values. A clang-module type that fails to display passes only if it fails identically under `on` |
| C3 crash | A throwaway `fatalError` probe symbolicates with `atos` to function (mandatory) and file:line while the `.o` files exist |
| C4 delayed | After C3, `make dev-dsym PRODUCT=root-tests`, then `atos` resolves file:line through the generated dSYM; binary and dSYM UUIDs agree |
| C5 aged comparative | C1 and C2 on the aged tree show no Swift-frame regression versus `on`; `.pcm` warnings are recorded but not gating |
| Optional | A delayed-case **app** crash needs a visible launch, so it runs once only with just-in-time approval and is not gating |

**Acceptance (replaces the earlier "≥70% of `dsymutil`" rule).** That ratio depended on tree age: about 7.3 s in-build in a fresh tree versus 11.7 s standalone on the aged tree.

1. `test-body`: the lower bound of the paired 95% CI of the client saving is ≥5 s, and the median saving is ≥25%.
2. `app-body`: no established regression; the saving is recorded.
3. `null-test` and `null-app`: equivalent within the A/A-calibrated bound.
4. `test-body` residual difference within 300 ms.
5. U1 is re-confirmed through the final wrapper. Skipped app and test relinks, each followed by two null builds, show zero link lines and unchanged executable mtimes. A matching `dev-dsym` output survives two null builds.
6. C1–C5 pass.
7. A v2 ticket minted under `on` validates under `off`, and vice versa.
8. After landing: `make dev-core-test`, `make dev-provider-test`, all three `make dev-swift-build` products, an isolated fully verified `make dev-build`, and one unfiltered `make dev-test-parallel` all pass.

Rollback: `RPCE_DEBUG_DSYM=on` costs one replan; optionally run `make dev-dsym`. Re-qualify after every toolchain upgrade, because the driver hook is undocumented.

### Step 11 — Pre-test residual (diagnostic; only an explained fix lands)

There are two separate effects:

- a constant ~2.7 s per relink (3.4 s total, independent of dSYM mode);
- a component that grows with the number of freshly compiled files: 38–67 s after 579–623-file test rebuilds, 105.6 s cold.

The residual as measured so far does not prove the time falls after `Build complete!`. Step 2 localizes it using the signed pre-completion residual and the separate build-complete → first suite span.

Hypotheses:

- **H1:** SwiftPM work before XCTest spawns.
- **H2:** a second XCTest load to list tests.
- **H3:** first execution of a new binary (code-signature, page-in, dyld).
- **H4:** Spotlight/IO contention after large compiles.

| Experiment | Decides |
|---|---|
| R1: a cold probe in a `cold` capture with the opt-in 250 ms process-tree sampler (also sampling `syspolicyd`, `XProtectService`, `amfid`, `mds`), plus `sample` of the top-CPU process every 2 s | Which process owns the interval, whether XCTest spawns once or twice, CPU-bound or idle |
| R2: in the same worktree, without rebuilding, counterbalanced first runs of direct `xcrun xctest` versus serial `swift test`, then repeated artifact runs | Slow only on first execution → H3; absent outside SwiftPM → H1/H2 |
| R3: `--parallel` versus serial after a one-file relink, 3 samples each | H2's share of the constant term |
| R4 (only if R1 shows idle or IO wait): `.build/.metadata_never_index` plus a cold rebuild | H4 |
| R5: incremental-driver diagnostics for body edits, mtime churn, and input-set changes | Which change classes recompile the whole test module |

- Sampling and driver flags disqualify runs from acceptance.
- Naming an owning interval, process or invalidation cause requires three reproductions; otherwise record "not reproduced" or correct the historical interpretation.
- Possible fixes, each gated with its own table:
  - idempotent `.metadata_never_index` in `canonical_swift.sh` (residual after cold ≤50% of baseline);
  - a build-then-test split for listing (≥2 s off the `test-body` residual);
  - for H3, document it as an OS cost, with no change.
- Raw findings go to a local `docs/investigations/` report (not staged), distilled into §11.

### Step 12 — Debug packaging Swift invocations (gated)

- **Isolation (U4).** The benchmark sets all three destination overrides inside the capture directory and runs fully verified coordinated `build` jobs, with fast packaging disabled and the signing mode matched. Staging stays under the scratch root, and `activate_staged_debug_bundle` never runs, because nothing launches.
- **Candidate (i).** Reuse one bin-path query instead of repeated `--show-bin-path` spawns. `swift_build_all` (`:5882`) computes it once and exports it; `package_app.sh` uses it when set and existing, and falls back otherwise.
- **Candidate (ii).** Replace the three `--product` builds with one unqualified native debug build, **only if** U13 proves the graph builds exactly the three products' closure, with identical compiled-target sets and identical `LC_UUID`s. SwiftPM documents a single `--product` selector, so repeated `--product` flags are not a candidate. If adopted, update both `package_app.sh`'s debug branch and `operation_swift_build_all()`, plus a graph-scope regression check.
- **Gate (per candidate).**
  - Ten warm fully verified packages per condition.
  - Median `null-package` saving ≥1 s and ≥10%, with a positive paired CI.
  - No `app-body-package` regression.
  - Identical bundle file inventory and executable UUIDs in the same tree state.
  - All architecture, identity, resource, signature and helper-smoke checks pass.
  - The cold comparison is reported.
  - No accepted sample contains `FAST PACKAGE SKIP`.
- **Validation.** A fully verified `make dev-build` afterwards. Any launch needs just-in-time approval.
- **If a gate fails:** keep the three builds and record the rejected experiment.

## 5. How to measure now and later

- **Every day (after Step 2):** every coordinated job writes `phaseMetrics` and a history row. Use `./conductor metrics --last N` or `make dev-metrics`.
- **Conductor changes:** run `make dev-conductor-bench` (or `-full`) at the parent revision and at the candidate, then `make dev-conductor-bench-compare`.
- **Build-pipeline changes:** run `make dev-bench` at the parent and the candidate under matching conditions, then `make dev-bench-compare`. Commit the distilled table in the owning document.
- **Rules:** a filtered or benchmark result is never test evidence. Missing, incompatible or insufficient evidence is inconclusive, never a pass.
- **Today:** §2 and §11 are the provisional baseline. Step 1 replaces the Python numbers with harness captures, and Step 9 replaces the Swift numbers with calibrated captures.

## 6. File-by-file impact

| File | Change | Step |
|---|---|---|
| `Scripts/conductor_benchmark.py`, `Scripts/test_conductor_benchmark.py`, `Scripts/Fixtures/conductor-benchmark/v1/` (new) | Python harness, adapters, gates, comparison | 1 |
| `Scripts/swift_pipeline_metrics.py`, `Scripts/test_swift_pipeline_metrics.py`, `Scripts/Fixtures/build-metrics/v1/` (new) | Recorder, parser, derivation, `RotatingJsonl`, statistics, optional sampler | 2, 11 |
| `Scripts/conductor_output.py` (new) | Streaming splitter and normalizer | 3 |
| `Scripts/conductor_entry.py` (new); `conductor` | Checked-hash import entry; the launcher execs it | 6 |
| `Scripts/debug_dsym.py`, `Scripts/test_debug_dsym.py` (new) | Confined UUID-based cleanup, regeneration, qualification support | 10 |
| `Scripts/swift_build_benchmark.py`, `Scripts/test_swift_build_benchmark.py`, `Scripts/Fixtures/swift-build-benchmark/v1/` (new) | Per-arm worktrees, scenarios, ABBA, contention, cleanup, LLDB fixture | 9–12 |
| `Scripts/conductor.py` | Changes per step: 1 `_pump_output` seam · 2 timing hooks, `phaseMetrics`, `conductorDigest`, `metrics` subcommand, kill switch · 3 batched reader, summary single-flight/once-per-record/bounded `seen` · 4 ledger cache · 5 maintenance worker and pins · 6 entry paths · 7 validation sites · 8 fingerprint v2 and version readers/writers · 10 passthrough/identity, effectiveness detector, `dsym` operation · 12 `swift_build_all` bin path / optional single build | 1–12 |
| `Scripts/canonical_swift.sh` | Policy validation, configuration classification, override injection, banner, helper call | 10 |
| `Scripts/package_app.sh` | Bin-path reuse / single build, only if gated | 12 |
| `Scripts/test_conductor_output.py`, `Scripts/test_conductor_lifecycle.py` | Splitter/batch/watchdog, summary, ledger, retention pins, artifact counters and races, fingerprint v2, policy identity | 2–10 |
| `Makefile` | `dev-conductor-bench[-full\|-compare]`, `dev-metrics`, `dev-bench[-compare\|-clean]`, `dev-dsym`, `dev-dsym-check`; help entries | 1, 2, 9, 10 |
| `.gitignore` | `Scripts/__pycache__/` | 6 |
| `docs/context/workflows/development.md` | Measurement commands, debug-symbol policy and restoration, aged-cache caveat, isolated packaging, worktree cleanup | 2, 9, 10, 12 |
| `docs/context/workflows/validation.md` | Performance-evidence requirement, artifact checkpoints and messages, benchmark ≠ test evidence | 7–9 |

## 7. Risks

| Risk | Handling |
|---|---|
| Telemetry overhead or missing events | Overhead gate, bounds, partial labels, external CLI timing |
| Batching shifts when markers become observable | Accept on CLI/process wall, CPU and lock behavior, never on an apparent interval improvement |
| Watchdog regressions | Per-transition ordered application, sequence-based change detection, delayed-lock and multi-transition tests |
| Tail and summary semantics (OD7) | `SUMMARY_VERSION` 2, qualified omission counts, exact-shape tests |
| Ledger changes mid-load | Stat-before/after check, one retry, existing fallback, pinned snapshots |
| Retention vs. finalization races | Pins, exact filename families, no late recreation |
| Stale bytecode | Checked-hash pycs; `PYTHONDONTWRITEBYTECODE` or an unwritable cache falls back to uncached loading, which is still correct |
| An old daemon outliving conductor edits (existing behavior) | `conductorDigest` in status and telemetry; harnesses check the daemon digest against disk before and after each series and restart the idle scratch daemon on mismatch |
| Ticket invalidation at Step 8 | One source-validating re-mint; domain separation guarantees rejection in both directions |
| Post-run artifact mutation | Invalidates an otherwise successful result |
| Undocumented driver hook | Effectiveness detector; re-qualify after toolchain upgrades |
| Lost file:line after `.o` files change (OD2 accepted) | `make dev-dsym` while compatible objects exist |
| Aged `.pcm` references | C5 comparative check; warning disappearance is not a repair |
| Debug ↔ release replans | U17 measures it; release builds are rare on this fork |
| Cleanup deleting the wrong thing | Confinement, bounds, UUID rule, keep-on-doubt |
| Packaging escaping the scratch roots | All three overrides plus ancestry checks; no launch |
| Benchmark noise and disk | A/A equivalence bound, contention discard, about 17.4 GB for two worktrees, `dev-bench-clean` |

## 8. Unknowns to check during implementation

Before Step 1, search the whole repository for every fingerprint/ticket reader and writer, every `conductor.py` launch reference, `ProgramArguments`, `__operation_runner`, and the schema constants.

| ID | Unknown | Check |
|---|---|---|
| U7 | Does the client reject unknown status/handshake keys? | Read the client connect path; if it does, one `PROTOCOL_VERSION` bump lands at Step 2 |
| U8 | Does request identity include the environment snapshot? | A lifecycle test asserting that `RPCE_DEBUG_DSYM` changes it |
| U9 | Today's exit status for a stale or mismatched artifact | Read the stale-artifact paths; keep the status unchanged |
| U11 | Is `Scripts/__pycache__/` ignored and guardrail-clean? | `git check-ignore`; `make guardrails` |
| U12 | `package_app.sh` lines 300–440: `FAST_PACKAGE_CACHE` location, CLI install writes, release-path dSYM consumers, the Sentry flag | Read the script |
| U13 | Does an unqualified debug build cover exactly the three products? | Scratch dry run comparing compiled target sets and `LC_UUID`s |
| U14 | Does the watchdog wait loop rely on notify counts rather than timeouts? | Read `_xctest_watchdog`; notify-only-on-progress test |
| U15 | A daemon construction seam without sockets for the harness | Reuse lifecycle fixtures |
| U16 | Which interpreter runners and the daemon use | Read `_internal_argv` and the spawn code |
| U17 | Does debug ↔ release alternation replan debug? | Debug null → release null → debug null; look for "Planning build" |
| U18 | Does `conductor.py` import any local modules? | grep; include any in the bytecode and digest coverage |
| U19 | Does anything between execution prepare (`:3023`) and prelaunch (`:3055`) use hash-derived output? | Read `_run_job` |
| U20 | Are there other driver-generated adjacent dSYMs in the test closure? | List the `.dSYM` entries in the current closure at the start of Step 8 |

## 9. Material disagreements and resolution

Earlier Swift-only round (still valid unless noted):

- **Fingerprint exclusion with a version bump, landed before the skip.** Converged.
- **No markers, inventories or forced relinks.** Converged.
- **Slot-free orchestrator.** Converged.
- **Per-ticket telemetry plus rotated history.** Converged.
- **The default-flip gate.** Superseded by OD2/OD3.

This combined round:

| # | Topic | Round-1 positions | Resolution |
|---|---|---|---|
| N1 | Artifact validation design | One lane: one byte-exact hash per executable identity per daemon lifetime, memoized by stat identity, with stat-only client/enqueue/prelaunch/post-run checks. Other lane: no memo; full fingerprints at prelaunch and post-run. | **Owner decision OD5:** full hashing twice per run, no memo. The memo lane also claimed closure entries were "already size/mtime only", which the code refutes (`:600-610` content-hashes every closure file); it retracted. Converged on Step 7. |
| N2 | Job history and idle exit | One lane: persisted `jobs-history.jsonl` plus 30-minute idle exit. Other lane: defer until the post-fix footprint is measured. | **Owner decision OD6:** defer. Both lanes accepted the Step 4 review trigger, measured as fresh-daemon physical footprint. |
| N3 | Launcher stale-code safety | Round 1: one lane wanted checked-hash pycs plus an enforced generation digest and a `PROTOCOL_VERSION` bump; the other wanted a plain loader. After the challenge, the lanes swapped positions. | **Converged in round 2:** checked-hash pycs; an informational `conductorDigest` recorded everywhere and checked by the harnesses; no enforcement or protocol bump; telemetry lands before the launcher. |
| N4 | Output batching vs. watchdog | One lane: stamp `last_progress` once per chunk. Other lane: apply every transition in order and coalesce only notifications. | **Converged:** the single-stamp model loses transitions, e.g. "test A passed" followed by "test B started" in the same chunk. Transitions are applied per record through today's handler, using the existing `xctest_progress_sequence`. |
| N5 | dSYM policy classification and cleanup | One lane: skip for every invocation, no configuration or Sentry gating, simple cleanup. Other lane: configuration-based policy with an identical environment for every debug subcommand. | **Converged:** configuration-based; release, unknown and Sentry get full; identical debug environment for all subcommands. Cleanup is pre-build only, confined, and **UUID-mismatch** based. An interim mtime rule was rejected because mtime proves neither staleness nor freshness. |
| N6 | Fingerprint details | Exclusion by any `.dSYM` suffix vs. the exact path; schema field only vs. domain separation. | **Resolved by code verification:** `evaluate_test_artifact` has no version check, so the closure digest is domain-separated; the exclusion is the exact path; fingerprint and dedup are separately measured steps (Steps 7–8). |
| N7 | A/B design | Fixed ABAB with a median-only A/A gate vs. balanced ABBA with a CI-based gate. | **Converged:** one worktree per arm, 5 ABBA blocks, and an A/A equivalence bound in which the entire CI must lie within ±max(150 ms, 3%). |
| N8 | Enqueue source snapshot; post-run `swift --version` | One lane kept both, "to reject early" and "for parity". | **Converged:** neither. Stale-source artifacts are runnable by design, and today's post-run path has no toolchain call. |

Process notes:

- OracleD's first answer arrived truncated; it re-sent its first nine sections in the same chat.
- OracleE's first challenge reply failed with a browser-session warning; the retry succeeded.
- One question round to the owner timed out; the owner then instructed "do as you recommended", which produced OD5–OD8.

No material disagreement remains open.

## 10. Open questions for the owner

1. **Idle exit and job-history review (OD6): discharged by main.** Step 4's 86.8 MiB physical footprint fires the review trigger. Both lanes reviewed it; main keeps the existing idle-exit and job-history deferral unchanged. OracleB explicitly withdrew its initial request for a new owner decision. An optional later footprint/heap re-check may inform separately authorized work, but has no deadline and is not a gate before Step 5.
2. **Delayed-case app crash check:** run once with just-in-time approval for the record? Recommended: yes, once, not gating.
3. **Switch name:** `RPCE_DEBUG_DSYM=on|off`, unset meaning off. Recommended as written. One lane proposed `on|skip`; the difference is cosmetic.

## 11. Evidence

### Phase 0 (2026-10-04)

Method:

- A disposable detached worktree at `f8da89c7` with its own conductor daemon.
- A scratch-only one-method suite `BuildPipelineBenchmarkProbeTests`, run via `./conductor test --filter`.
- Mode changes made only in the scratch copy of `canonical_swift.sh`.
- The worktree and its daemon were removed afterwards.

Column definitions:

- **Client:** client wall-clock time.
- **Build:** SwiftPM's reported "Build complete!" duration.
- **Residual:** (XCTest first-suite timestamp − process start) − build.

| Step | Mode | Client s | Build s | Residual s | Notes |
|---|---|---|---|---|---|
| Cold | on | 304.6 | 194.0 | 105.6 | 2,407 build steps; 0 `.pcm` warnings |
| Null | on | 5.7 | 4.0 | 0.7 | First post-cold build replanned |
| 1-file edit ×3 | on | 18.9–19.5 | 14.2–14.9 | 3.4–3.6 | One compile, one link, dSYM regenerated |
| Null | on | 15.9 | 0.36 | 0.7 | 13.8 s foreign heavy-slot wait |
| First switch to skip | off | 31.2 | 28.4 | 1.8 | Replan; 1,233 `Write` steps, 0 compiles or links |
| 1-file edit ×2 | off | 11.2–11.7 | 7.0–7.5 | 3.4 | No dSYM |
| Null ×2 | off | 1.75 | 0.34–0.35 | 0.7 | Zero links, executable mtime unchanged |
| Switch back to on, null | on | 5.5 | 4.08 | 0.7 | dSYM **not** regenerated by a null build; regenerated at the next link |
| Repeat switches (null) | both | 5.9 | 4.08–4.11 | 0.7 | Only the first switch to a never-seen environment cost 28 s |

Unknowns resolved:

| ID | Result |
|---|---|
| U1 | **Pass.** After a skipped link, two null builds show zero link lines and an unchanged executable mtime. |
| U2 | **Pass.** The probe suite passes filter preflight through the source-suite fallback (stderr reminder about the ledger), runs exactly one test, and leaves the ledger untouched. |
| U3 | **Attributed to `dsymutil`.** Standalone `xcrun dsymutil` on the aged main checkout's test binary takes 11.7 s and emits 48 `ModuleCache/<hash>/*.pcm: No such file` warnings across 6 module-cache directories, some deleted (stale debug-map references in older `.o` files). A fresh tree emits 0 in both modes. In logs the warnings follow `Write Objects.LinkFileList`. |
| U4 | Packaging writes the bundle under `REPOPROMPT_DEBUG_APP_ROOT`/`_BUNDLE`, shared by default. Conductor stages it under `<DebugApps>/.staging/<token>/` (`:5605`); only the launch path swaps it live (`:5662`). It also writes `mktemp` entitlement/profile files and a `.build/<conf>/RepoPrompt.app` compatibility path. It can be isolated by overriding all destination keys. |
| U5 | `swift_build_all` (`:5882`) runs three sequential `canonical_swift.sh build --product` calls. |
| U6 | Retained compiling logs hold about 101k CRLF, about 9k bare `\r`, and about 9k `\x1b[2K`; LF "lines" reach 190–211 KB. |
| Static LLDB (skip, no dSYM, none found by Spotlight) | `image lookup -v` gives file:line `LineEntry`s for test and app functions through the debug map. `breakpoint set -f … -l …` resolves for both. Live locals, crash `atos`, and the delayed case remain for C2–C4. |

### Implementation checkpoint (2026-10-05)

The candidate Step 1 harness measures the real target implementation through explicit adapters, preserving parent bytes at commit `ee811f469d59ef17a35e3bac3b1d7534cbeecab8`. Captures live under the main checkout's conductor state directory in `benchmarks/conductor/`; raw evidence remains local and is not contribution material.

Clean captures `step1-v2-default-20261005` and `step1-v2-full-20261005` ran 30 paired fast samples and 10 paired fresh-process memory samples per arm. The full capture also ran 10 artifact and 10 footprint samples per arm. Both collected without harness errors, but their no-regression comparisons returned **2 (inconclusive)**, not acceptance. An output-only rerun did not resolve all output uncertainty. The earlier v1 captures are excluded because they overlapped other profiling; v1 also had an asymmetric bytecode-loading confound corrected before v2.

Host: Apple M3 Ultra, 28 CPUs, macOS 26.7, Python 3.14.7, Swift 6.3.1. The full v2 parent/seam conductor content digests are `3582ec18a2c11799279c9e37fabb1b394cd6393a0e382119cf3913e8ab379cde` / `26953b6ff0907da673c037d56001128dbc2232116d0ca55aaf0ff63c5b34549b`; the harness digest is `60ce26c1db43eb6fcd7b269cac762e0da95d13d677590331d99634ac3089cd37`. These describe the captured versions, not later revisions.

| Full v2 baseline metric | Parent median | Output-seam candidate median |
|---|---|---|
| Pipe output CPU, 0 / 4 waiters | 185.1 / 2,828.2 ms | 185.7 / 3,028.3 ms |
| PTY output CPU, 0 / 4 waiters | 147.8 / 286.0 ms | 150.3 / 299.3 ms |
| Summary total CPU, four fixture modes | 4,283.4 ms | 4,268.3 ms |
| Ledger retained heap, 56 / 200 jobs | 86.75 / 309.79 MiB | 86.75 / 309.79 MiB |
| Summary `seen`, 100k / 1M records | 14.75 / 142.31 MiB | 14.75 / 142.31 MiB |
| CLI help / status | 99.9 / 100.3 ms | 99.9 / 100.0 ms |
| Artifact run wall / integrity | 2,822.8 / 2,783.8 ms | 2,813.6 / 2,776.4 ms |
| Artifact calls: evaluation / fingerprint / source / toolchain | 3 / 5 / 4 / 3 | 3 / 5 / 4 / 3 |
| Retained physical footprint, 56 synthetic test jobs | 153.21 MiB | 153.26 MiB |

The full comparison remains inconclusive on pipe/4-waiter CPU and wall and PTY/4-waiter CPU. The default comparison remains inconclusive on PTY/4-waiter CPU. Confidence bounds, not just point estimates, must qualify; these results do not establish a regression or a speedup. The paired default capture took 593 seconds and the full capture 1,564 seconds, substantially longer than the provisional ~30-second default estimate in Step 1.

**Review remediation r1 (2026-10-05).** Remediation was attempted inside Step 1 scope as harness v3 / capture schema 2. These are implementation changes, not a claim that all findings are closed:

- Captures record an explicit `state`/`complete` and are written even when a run fails or is interrupted.
- Metrics must be finite numbers, every sample must report exactly its workload's recorded metric and equivalence inventory, and every measured block must be present.
- Every profile gate must match a measured metric.
- Smoke overrides and unpinned fixture sizes or counts are never acceptance evidence.
- A confirming batch must be an independent, clean, complete capture of the same target digests.
- PTY verification is positional, and PTY variants run the production XCTest stall-watchdog thread.
- `requireGolden` enforces the summary golden for the baseline arm.
- Retained-log corpora are copied once and fingerprinted.
- Each sample records machine-slot and load observations, and the CLI interpreter is recorded.
- Arm names and capture IDs must be safe path components, and Make scalars are quoted.

The v2 captures (schema 1) cannot be loaded by v3 and are superseded.

Deviations from the Step 1 text, recorded for the owner:

- The seam is `_pump_output(ticket, read_chunk, sink)`, not `_pump_output(fd, sink)`: the pipe transport reads lines from a stream, so an fd-based seam would change behavior. r1 changed only its docstring.
- "Bytes written must equal bytes read" holds exactly for the pipe. On the PTY every written byte must arrive at its ONLCR-translated position; the only tolerated deviation is one tty-retried CR immediately before the CR LF of a written LF (65–67 per 5 MiB run observed). PTY tail evidence removes exactly those CRs and digests a fixed 512-byte suffix.
- Because PTY variants now include the watchdog waiter, PTY figures are not comparable with v2 (PTY 0-waiter CPU rose from about 148 ms to about 190 ms).
- `rss` measures a fixture worker's in-process `DaemonState`, including harness overhead, after 56 jobs through the real `enqueue`/`_run_job`. It is valid for A/B deltas, not for Step 4's fresh-daemon 70 MiB trigger, which needs a real `__daemon` measurement.
- Targets run from staged, byte-verified copies, with `conductor.py` compiled from source in every process.

Predeclared r1 measurements used harness digest `c63d74a78239d10067dcdffb72cd7658745efff2385536298838b8de99dfd865`, parent `3582ec18a2c11799279c9e37fabb1b394cd6393a0e382119cf3913e8ab379cde`, and seam `78e8fcd11486e311a516ee132d658930738a43907dc1f505f30b25f10301ca0e`:

| Capture | Arms and samples | Comparison |
|---|---|---|
| `step1-r1-aa-output-f90-20261005` | parent / parent, output only, 90 pairs | `calibration-output` exit 0 (calibration evidence only) |
| `step1-r1-full-f90-20261005` | parent / seam, all workloads, 90 fast pairs and 10 memory, artifact and rss pairs | Initially exit 0 before contamination labeling; final `no-regression-full` exit 2 (inconclusive), not acceptance |

r1 full parent medians (contaminated capture; timing/footprint rows are descriptive only, not acceptance evidence):

| Metric | Parent median |
|---|---|
| Pipe output CPU, 0 / 4 waiters | 191.9 / 3,099.5 ms |
| PTY output CPU, 0 / 4 waiters | 189.7 / 352.5 ms |
| Summary total CPU | 4,505.6 ms |
| Ledger retained heap, 56 / 200 jobs | 86.75 / 309.79 MiB |
| Summary `seen`, 100k / 1M records | 14.75 / 142.31 MiB |
| CLI help / status | 91.6 / 91.5 ms |
| Artifact run wall / integrity | 2,655.5 / 2,620.4 ms |
| Artifact calls: evaluation / fingerprint / source / toolchain; bytes hashed | 3 / 5 / 4 / 3; 5,756,684,090 bytes |
| Retained footprint, 56 synthetic jobs (idle) | 155.0 MiB (49.7 MiB) |

The paired full capture took 2,405 s.

A once-per-minute process sampler recorded foreign interactive CPU (Jump Desktop Connect, up to about 3 cores) during the capture. The orchestrator conservatively labeled the window `2026-10-05T07:27:00Z`–`07:59:59Z` as contaminated; it overlaps the end of output and the later workloads. Re-comparison returns **2 (inconclusive)**. ABBA pairing does not establish equal exposure or remove this uncertainty, so the unlabelled exit-0 reports are not acceptance evidence. The independent A/A capture ended before this window and remains calibration evidence only. No additional capture was run after the predeclared two captures; fresh uncontaminated full qualification remains outstanding.

**Step 2 feasibility gate:** a local pure-helper candidate passed 50 deterministic tests. A subsequent chunk-first prototype matched 77/77 payload/event/boundary equivalence checks. Two separately declared, alternating 30-pair batches included construction, splitting, parsing, EOF and finalization CPU, less the bare read loop:

| Batch | Pipe incremental CPU / 5 MiB | PTY incremental CPU / 5 MiB |
|---|---|---|
| A | 157.02 ms | 159.36 ms |
| B | 158.99 ms | 161.58 ms |

Both miss the literal **≤5 ms** screen by a wide margin. This is a failed bounded implementation experiment, not proof that every possible Python design is impossible and not an integrated output-path overhead proof. Moving CPU after exit would not satisfy a total-CPU requirement. The owner clarification timed out; the original gate remains binding, and the helper is not integrated. Local experiment sources and raw rows are preserved under `.agent-artifacts/step2-unintegrated/` and `.agent-artifacts/parser-feasibility/`.

**Fresh review outcomes (2026-10-05).** OracleA explicitly closed OracleA-002/004/005/006 but kept OracleA-001 (the capture's inventory remains self-declared rather than checked against a versioned adapter authority) and OracleA-003 (512-byte PTY suffix evidence does not prove the full visible tail or entry boundaries) open at P1. OracleB explicitly closed both of its P1 findings and reported no open P0/P1, while retaining non-blocking follow-ups for contamination detection and future Step 3 tail evidence. Both lanes reject Step 1 acceptance and full-plan completion. Implementation initially stopped at this unresolved review contract; OD9 subsequently authorized remediation and a minimal Step 2 attempt. Neither OracleA P1 is waived. Raw reviews, the exact reviewed states and deltas remain local working evidence.

**Resumed implementation (OD9, 2026-10-05).** The Step 1 candidate now reconstructs inventories from its versioned adapters and pinned manifest, and supplements noisy PTY suffix evidence with a 915-byte deterministic fixture whose complete 30-entry tail digest preserves content and entry boundaries. Harness v4 / capture schema 3 supersedes r1 captures. A predeclared foreign-CPU contamination check uses a 4-core limit over 10-second windows; captures require a passing 60-second preflight and never adapt the threshold to ambient load. The fixed r2 schedule is one output A/A capture (90 pairs), then one full parent/seam capture (90 fast pairs, 10 memory/artifact pairs), with at most one contamination-only rerun across the schedule. The subsequent fresh reviews closed the blocking findings described below. The predeclared r2 schedule completed: both A/A captures and the full comparison returned exit 2 solely for automatic contamination. The full capture had no harness failures or regression-gate failures, but output, memory and one footprint arm exceeded the foreign-CPU limit; no acceptance is claimed. The single rerun was consumed by A/A and no additional Step 1 capture is authorized by that schedule.

Step 2's candidate reuses existing LF decoding with a separate bounded CR cursor, retains only first-method events, records per-job boundaries/operations and implementation digests, persists timing sidecars/history, and exposes client-side metrics. The original timing-off output functions are preserved. Its overhead will be measured through real pipe/PTY transports with 0/4 waiting clients, including finalization/persistence CPU, using two predeclared 30-pair on/off batches and separate calibration/null-job batches. Parser qualification requires the paired 95% confidence upper bound to remain at or below 5 ms per 5 MiB; median and p90 are reported, without a separate p90 gate. This conservative estimator was selected before captures, not after observing results. The first Step 2 preflight measured 5.872 foreign CPU cores and failed; it created no batch. Integrated overhead qualification is therefore still missing, not failed or passed. Step 1 used frozen harness v4 (`0fb6deff…`); the current v5 harness adds Step 2 helper staging and informational loaded-daemon/runner digests. Its separate frozen Step 2 harness is `17bd3a57…`, and its target digest is `823b88a2…`.

Validation so far: 61 benchmark tests, 64 metrics-helper tests, and the full conductor self-test target passed. The approved supporting repairs let `make guardrails` pass (one pre-existing route-count warning). Three coordinated `MCPInitializeCompatibilityTests` runs each passed 3 XCTest tests; the first was a compiling warmup, followed by two no-change runs. The no-change runs reported 0.35-second SwiftPM builds and approximately 1.145-second process spans, with no compile/link work. Recorded first-suite skew was 0.907 / 1.115 ms; reconstructed outer-suite end skew was 43.476 / 43.928 ms, below 100 ms. Original anchor pairs are not persisted, and method-start lines have no printed timestamp, so these are receipt/log correlation evidence rather than independent method-clock verification. Raw records remain local under `.agent-artifacts/conductor-review-evidence/`.

**Review status after the resumed snapshot.** The exact reviewed bytes are preserved in `.agent-artifacts/conductor-review-r2/files/` with `sha256.json`; the existing-file delta is `delta-existing.patch`. Step 1 has used two fresh re-review rounds of the user's five-round cap; Step 2 received its initial review in the same lanes. OracleA closed OracleA-001/003 and opened Step 2 OracleA-007 (launchd kill switch), -008 (unqueried queued terminal jobs), -009 (blocking telemetry persistence), and -010 (truncated compile counts). OracleB has no Step 1 P1 and opened RV-R2-S2-P1-01 for the launchd switch. Missing performance evidence remains separately blocking. Reviews are preserved locally at `prompt-exports/oracle-review-2026-10-05-174603-oraclea-step1-r2-and-d5e9.md` and `prompt-exports/oracle-review-2026-10-05-180827-oracleb-step1-r2-and-df5b.md`. The Pair worker reproduced all four Step 2 failures against the prior frozen target and implemented fixes: launchd forwards the daemon-start setting and reports mismatches without restarting; queued terminal jobs persist without a query; job result delivery no longer waits for telemetry persistence and history-lock acquisition is bounded; truncated compile observations exclude a possibly incomplete filename and mark counts partial. A small benchmark-fixture drain prevents temporary-directory cleanup from racing the now-asynchronous persistence; it runs outside measured wall time and is not a production client wait. The r3 reviews subsequently closed those findings, as recorded below. Neither phase is accepted and no commit has been made.

Post-remediation validation: the complete 12-suite `make conductor-selftest` passed on unchanged final bytes, including 51 output tests (20 named timing integration tests), 67 metrics tests, 65 benchmark tests and 142 lifecycle tests. The earlier benchmark count of 61 predates four metadata tests; the earlier 45 output tests included the original 14 timing integration tests. An isolated real-launchd check passed all 12 assertions, including disabled startup, same-PID mismatch notice, and enabled mode after explicit stop/start; it launched no app and removed only its own temporary daemon.

The new frozen Step 2 target is `636a4e39…`. Its two 60-second preflights measured 4.072 and 4.015 foreign CPU cores, above the unchanged 4.0 threshold; neither created a qualification batch. A separate explicitly smoke-only, one-pair 5 MiB diagnostic exercised the real on/off path with finalization included. Its added CPU was 86.49 / 63.39 ms for pipe 0/4 waiters and 99.35 / 104.30 ms normalized for PTY 0/4 waiters. The diagnostic deliberately bypassed preflight and is not acceptance evidence, an established regression, or the required 30-pair proof. It does not demonstrate compliance with the retained 5 ms limit. Raw evidence is local in `.agent-artifacts/step2-qualification/runs-smoke/step2-r2-diagnostic-only/`.

A narrow counter-lifecycle check confirms successful capture workers are reaped before the after-probe and Step 2 uses in-process daemon state inside fresh workers, not launchd services. A nested-child check accounted for 2.057 seconds of child CPU at wait completion and only 0.000075 seconds later; this addresses the claimed delayed-reaping scenario, not every possible contamination-estimator limitation. No performance threshold has been changed.

**Step 2 re-review and final-byte checks.** OracleA and OracleB explicitly closed their prior P1s in fresh r3 lanes. OracleA raised R3-S2-P1-01 for failure to start a queued-job timing thread; OracleB reported the same scenario as non-blocking R3-S2-P2-01. The Pair worker contained construction/start errors, restored completion accounting, and exposed a failed telemetry status without affecting cancellation or shutdown; OracleA explicitly closed its P1 and OracleB closed its matching P2 in the final fresh reviews below. A fixture cleanup race introduced by asynchronous persistence was repaired at the test cleanup owner by draining test-owned timing work before removing its temporary directory. Timing remains enabled and assertions are unchanged. The affected heavy-slot test passed 30/30 separate-process runs; the same command on the prior fixture failed 1/30, and removing the drain made the new regression test fail. Final `make conductor-selftest` exited 0 with 12 Python suites plus the context checker, including 54 output, 67 metrics, 65 benchmark and 143 lifecycle tests. Local `BEFORE-SHA256SUMS` and `AFTER-SHA256SUMS` files under `.agent-artifacts/step2-r3-lifecycle-fix/validation/` bind the run to unchanged code. The final review packet embedded the AFTER hashes; the main agent verified them against the working tree and staged index. Only this failure-path fix, its tests, and the fixture cleanup changed since r3; no performance gate was relaxed.

Two further coordinated Swift runs used the current implementation digest `sha256:cfdd9f1efe390b3d8417e204b522287b0fd5c4341e9b2225f8e560f5846e6cb3`. Tickets `2cb12450-bfdf-4d13-a113-9d55b8294ae4` and `86fe8495-71ca-417a-9ab5-47967193f665` each passed 3 XCTest tests, with zero compile observations. Their SwiftPM build durations were 0.63 / 0.34 s and measured process spans 4.667 / 1.133 s; the first included a 3.546 s build-complete-to-first-suite interval. Post-persistence status was complete with no telemetry error. First-suite receipt/log skew was 1.327 / 1.319 ms, and reconstructed end skew was 41.197 / 43.171 ms. The original wall-anchor and method-timestamp limitations above still apply. This pair supports functional correctness and timestamp correlation, but repeatable no-change timing remains partial: the first run's 3.546-second gap is unexplained. The smoke-only result remains diagnostic rather than gate evidence.

**Final review record.** Code approval is distinct from phase acceptance. The r4 packet requested full evidence attachments, but OracleB reported missing prior-review/evidence material. The fifth and final fresh round therefore embedded each lane's own prior reviews verbatim, the exact delta and essential evidence directly in the request. Both lanes confirmed receipt and retained scoped code approval, with no open P0/P1. No production or test code changed after the r4 snapshot. The remaining minor findings are deferred; another remediation loop was not requested.

Response paths below are relative to local `prompt-exports/`:

| Finding | Issuing response | Closure response and ownership |
|---|---|---|
| OracleA-001/003 | Earlier Step 1 review record | OracleA `oracle-review-2026-10-05-174603-oraclea-step1-r2-and-d5e9.md` explicitly closes both; final OracleA retains these closures. |
| OracleA-007/008/009/010 | `oracle-review-2026-10-05-174603-oraclea-step1-r2-and-d5e9.md` | OracleA `oracle-review-2026-10-05-185129-oraclea-step2-p1-rem-24b1.md` explicitly closes all four. |
| RV-R2-S2-P1-01 | OracleB `oracle-review-2026-10-05-180827-oracleb-step1-r2-and-df5b.md` | OracleB `oracle-review-2026-10-05-185645-oracleb-step2-p1-rem-a94d.md` records “Closed (concurring)” and no open P0/P1; final OracleB retains that disposition. Its wording is preserved rather than relabeling concurrence. |
| R3-S2-P1-01 (P1) | OracleA `oracle-review-2026-10-05-185129-oraclea-step2-p1-rem-24b1.md` | OracleA `oracle-review-2026-10-05-191904-oraclea-final-eviden-ca64.md` explicitly closes its own finding. |
| R3-S2-P2-01 (P2) | OracleB `oracle-review-2026-10-05-185645-oracleb-step2-p1-rem-a94d.md` | OracleB `oracle-review-2026-10-05-192406-oracleb-final-eviden-bd39.md` explicitly closes its own P2 and only concurs on OracleA's P1. |

Deferred minor observations include terminal `failed` status documentation/finalize-failure coverage, test gate-release/cleanup ordering and process-wide thread fault injection, plus the earlier non-blocking daemon-mode notices and cleanup-state observations. No new code was added for these after approval.

**New authorized measurement schedule and outcome.** The owner explicitly authorized one additional Steps 1–2 schedule, preserving the 60-second preflight, 4.0-core threshold and 5 ms/5 MiB budget, with no app stopping, waiver or automatic retry. Before execution, `.agent-artifacts/step2-qualification/PROTOCOL-R4.md` and `Q1R4-SHA256SUMS` pinned the r4 target (harness target digest `73709b0d…`, loaded implementation `cfdd9f1e…`), unchanged driver/binding and both harnesses. The main agent's verify command checked hashes, target-local helper loading and binding API readiness. The Step 2 binding includes synchronous finalization/persistence in output measurements and drains persistence for null jobs; it does not use the older harness's artifact/RSS adapters. Step 1's frozen parent/seam targets and full 90-fast/10-slow schedule were explicitly included, conditional on Step 2 qualification.

Execution `run-q1r4.sh execute` ran from 12:23:26 to 12:31:56 UTC on 2026-10-05 and stopped with exit 20. Calibration and batch A each completed 30 pairs per pipe/PTY, 0/4-waiter variant with no harness errors. Batch A was contaminated: 93 samples across 7 windows exceeded 4 foreign cores (worst 7.448). Its raw median CPU increments were +94.942 / −246.652 ms for pipe 0/4 waiters and +99.549 / +118.906 ms for PTY 0/4 waiters. Those numbers are not qualifying evidence, including the apparent negative pipe/4 result. Before batch B, the preflight reported 2.302 foreign cores but a held `global-heavy-0.lock`; the host was not idle, so no B batch was created. The wrapper's generic “above the contamination limit” text must not be mistaken for a CPU-threshold exceedance in that preflight.

The partial report exits 2 and reports parser/null-job gates missing. B, null and the conditional Step 1 capture did not run. The one-shot authorization is consumed; no retry was taken. Raw records and the report are local at `.agent-artifacts/step2-qualification/runs/step2-q1r4/`. Steps 1 and 2 remain blocked, not accepted; no commit has been made.

**Bounded performance investigation after OD11.** The RepoPrompt Pair worker profiled the unchanged r4 code rather than repeating qualification. Real-pump in-process replay over the fixed 5 MiB fixture measured approximately 79–85 ms of added reader CPU. Compile records accounted for roughly 42–46 ms of cursor work and carriage-return progress for 15–16 ms. The main agent independently ran `profile_observer.py` for five pipe replays: median added reader CPU 82.047 ms, range 76.291–84.277 ms; finalization median 0.743 ms. This replay omits real transport/persistence and is diagnostic attribution, not qualification. Local evidence is `.agent-artifacts/step2-perf/`, including `diag/main-pipe-confirmation.json`.

Stripped-down parsing probes also exceeded 5 ms, but these are particular algorithms, not mathematical lower bounds. An OracleA `mode:plan` feasibility consultation (`prompt-exports/oracle-plan-2026-10-05-194657-step2-5ms-feasibilit-749b.md`) found no credible simple Python-only optimization capable of the required reduction while retaining all observations. It recommended obtaining owner approval before a bounded native scanning/aggregation experiment. This consultation was not code review, did not reset the exhausted re-review cap, and granted no acceptance. The approval request timed out. No production/test code was changed, no gate was relaxed, and no commit was made. Native acceleration would require an explicit scope decision and any resulting production delta would also require an explicitly extended review budget.

**Owner acceptance and progression (OD12).** After reviewing the diagnostic result and unresolved evidence, the owner chose 90 ms as acceptance and explicitly requested the commit. The main five-run reader-path median was 82.047 ms (maximum 84.277 ms), below 90 ms, but that diagnostic excluded real transport/persistence; no full integrated 90 ms pass is asserted. Production and test bytes remain exactly the Oracle-approved r4 snapshot. The changed acceptance decision and existing functional validation permit this checkpoint to be committed without another code-review or capture loop. The earlier blocked statements above describe the pre-OD12 state. Work can proceed with Step 3, then Steps 4–6 and 7–8 on their independent dependency branches, then Steps 9–10. Each later step still requires its own scoped implementation, validation and review. Steps 11–12 remain future work.

Follow-up evidence (the first three items are non-blocking for the Steps 1–2 checkpoint under OD12):

- Repeatable final-byte Swift no-change timing (the first final-byte run's 3.546-second gap remains unexplained).
- Step 1 output-seam no-regression qualification and each later Python before/after table.
- Step 2 overhead proof.
- Step 9 A/A calibration and full-mode baseline.
- Step 7/8 artifact tables.
- Step 10 A/B and C1–C5 table.
- Step 11 findings.
- Step 12 packaging gate.
- The Step 4 footprint review.

### Step 3 implementation checkpoint (2026-10-05, OD13)

Status: implemented in the working tree; **not accepted, not staged, not committed**. Steps 4–12 are blocked until Step 3 is accepted. This section records the r0 implementation and its reviews; the r1 remediation and its evidence follow in "Step 3 remediation r1" below. Raw evidence is local under `.agent-artifacts/step3/` (`EVIDENCE.md`, compare reports, capture copies, scripts and checksums) and is not contribution material.

Implementation, from parent `506af898` (snapshot and `PARENT-SHA256SUMS` captured before edits):

- New `Scripts/conductor_output.py`: the shared record splitter, OD7 tail entries and bounded `OutputTail`, and batches of at most 256 records / 64 KiB (the byte bound is enforced conservatively as 16 Ki decoded characters). The conductor loads it by explicit path as a required helper, and it is part of `conductorDigest`, so captures detect changes to output code.
- `Scripts/conductor.py`: the pipe reads with `read1(64 KiB)`, and the PTY keeps `os.read(64 KiB)`. Each read is timestamped, then written and flushed, then split, normalized and classified outside the lock. Each batch locks once, applies every XCTest transition in order through the extracted per-line body with the record's receive time, and notifies once. Summaries stream through the same splitter, with each regex run once per record behind a casefolded keyword precheck (applied only to ASCII lines). `seen` is bounded to 4,096 entries per section, `SUMMARY_VERSION` is 2, and summaries are single-flight.
- `Scripts/swift_pipeline_metrics.py`: telemetry consumes the shared records. `Scripts/conductor_benchmark.py` is harness v6: it stages and verifies the helper and adds an independent Step 3 tail model for PTY evidence.
- Tests: new contract tests, and old tail-shape assertions replaced with the exact new shapes; none are loosened.
- Interpretations to confirm in review:
  - Delimited tail entries end with `\n`; an unterminated final record has none.
  - The keyword precheck is applied only to ASCII lines.
  - "Releases the pin" is read as releasing the summary claim and event.
  - A `job_wait` that reaches its deadline while joining a running summary returns without `outputSummary`, with `waitTimedOut` false.

Final gate capture `step3-gate-2` (`make dev-conductor-bench-full`, workloads output/summary/mem, 30 fast and 10 memory pairs, 914 s). It used the parent target `73709b0d…` and the candidate target `5b534314…` (loaded implementation `sha256:e16f4670…`), with harness `ddeb526b…`, and is byte-identical to the working tree. `dev-conductor-bench-compare PROFILE=step3-output-summary` returned **exit 2**: the gate failures below, plus contamination.

| Gate metric | Parent median | Candidate median | Ratio | Required | Result |
|---|---|---|---|---|---|
| `output.pipe.w0.cpu_ms` | 191.5 | 75.5 | 0.39 | ≤0.5 | numerical threshold met; inconclusive (contaminated) |
| `output.pipe.w4.cpu_ms` | 3,123.3 | 79.4 | 0.025 | ≤0.25 | numerical threshold met; inconclusive (contaminated) |
| `output.pipe.w4.wall_ms` | 1,534.3 | 84.7 | 0.055 | ≤0.25 | numerical threshold met; inconclusive (contaminated) |
| `output.pty.w0.cpu_ms` | 188.6 | 204.7 | 1.085 | ≤0.5 | **fail** |
| `output.pty.w4.cpu_ms` | 349.9 | 673.0 | 1.92 | ≤0.25 | **fail** |
| `output.pty.w4.wall_ms` | 261.3 | 434.2 | 1.66 | ≤0.25 | **fail** |
| `summary.fixture.total_cpu_ms` | 4,296.2 | 996.8 | 0.23 | ≤0.65 | pass |
| `mem.seen_growth_100k_1m_mib` | 127.56 | −0.000 | — | ≤1.0 MiB | numerical threshold met; inconclusive (contaminated) |

Contamination caveats:

- The 60-second preflight passed (2.96 foreign cores).
- During the capture, some output windows reached 4.75 foreign cores and some memory windows 5.08, above the 4.0 limit. The comparison therefore labels output and memory inconclusive for both arms, and `output.pty.w0.wall_ms` is also inconclusive.
- Summary windows stayed within the limit.
- The PTY failures and the `seen` result lie far from their thresholds, but no contaminated window is claimed as clean qualification.
- The earlier capture `step3-gate-1`, taken before optimizing the splitter and tail, showed the same pattern (PTY w0/w4 CPU ratios 1.20/1.94; memory contaminated).

PTY diagnosis. These are measured hypotheses from this host; they are not a mathematical lower bound and not proof that no optimization exists:

- **Read size.** The macOS PTY delivered about 1 KiB per read: about 5,188 reads per 5 MiB, against 80 for the pipe. Both arms read the same counts.
- **Wakeups.** With per-batch notification, each read woke every parked waiter: about 5,191 notifies produced about 20,664 waiter wakeups. Parent sent about 69,518 per-line notifies, but its waiters were rarely parked between lines, which produced about 11,839 wakeups.
- **Thread CPU, 4 waiters, median of 5 runs.**

  | Thread | Candidate | Parent |
  |---|---|---|
  | Reader | 312 ms | 209 ms |
  | Waiters | 299 ms | 127 ms |
  | Watchdog | 77 ms | 33 ms |

- **In-process reader CPU** with 1 KiB reads and no waiters: candidate 121 ms against parent 107 ms. Splitter and tail optimizations within the contract reduced it from 141 ms.
- **Transition density.** About 93% of 1 KiB fixture reads carry an XCTest transition, so notifying only on progress would likely not change this fixture.
- **Open options.** Changing the PTY gates, the per-read batching, or the waiter wake structure requires an owner/review decision; none is authorized.

Evidence outside the benchmark, scoped as stated:

- **Classification equivalence (qualified).** Parent and candidate ran separately through the real `_pump_output` with the watchdog enabled, at 4,093-byte and 64 KiB reads. Inputs were 83 logs, about 36.9 MB: fixture raw/ONLCR, PTY fidelity, a synthetic 60k-test XCTest-dense log, and 79 retained conductor logs. The 170,812 ordered `(kind, testName)` transitions are identical, and no allowed difference was needed. Across 498 summaries in 6 modes, the candidate with `seen` uncapped and projected to v1 is byte-identical to parent. With the cap, only 18 synthetic-fixture summaries differ, and only by an upper-bound `omittedLineCount` with `deduplicationLimited`/`upper_bound` set.
- **Lock (qualified for the stated scope).** Reader-thread hold per acquisition was measured in-process with 64 KiB reads, 4 waiters and 5 repeats over the fixture and the dense log. The p99 was 89–200 µs and the maximum 0.4 ms, against the 5 ms gate. The candidate took 330–646 acquisitions per run, against parent's 69,516–132,003. Final sequence, started count and last test/action matched parent in every run. This was not measured through a real PTY.
- **Single flight and one scan.** A race test of completion, status and wait gives exactly one `summarize_file` call; a joiner honors its deadline; an exception publishes a minimal error summary with state `failed`. The end-to-end lifecycle test asserts one `output_summary` operation.
- **Functional.**
  - `make conductor-selftest` exited 0 on the final bytes: 12 suites plus the context checker, including 77 output, 68 benchmark, 67 metrics and 143 lifecycle tests.
  - `make guardrails` exited 0, with the pre-existing route-count warning.
  - `git diff --check` is clean.
  - Overhead with timing on was not re-measured.

Step 3 review index (main-owned, OD13):

| Item | State |
|---|---|
| Initial OracleA review | Changes requested; snapshot `2026-10-05/2234` |
| Initial OracleB review | Complete replacement initial review: no P0/P1 on supplied material; P2 remediation/verification requested; snapshot `2026-10-05/2234` |
| Reviewed snapshot per lane | Initial: `2026-10-05/2234`. Round 1: frozen r1b `.agent-artifacts/step3-review-r1/files/` and `SHA256SUMS`. Round 2: frozen r2 `.agent-artifacts/step3-review-r2/files/` and `SHA256SUMS`; OracleA received `r1-to-r2.patch`, OracleB received `r0-to-r2.patch` to repair its incomplete round-1 delivery. Both confirmed complete embedded receipt. |
| Reviewed snapshot (round 3) | Frozen r3 `.agent-artifacts/step3-review-r3/files/` and `SHA256SUMS`, with `r2-to-r3.patch` and `plan-frozen-r2-to-r3.patch`; both lanes verified |
| Reviewed snapshot (round 4) | Frozen r4 `.agent-artifacts/step3-review-r4/files/` and `SHA256SUMS`; full `r3-to-r4.patch` and focused evidence embedded in both fresh lanes. Both preset identities and complete receipt verified by main. |
| Re-review rounds used | 4 / 5. Both round-4 code verdicts approve; no open P0/P1. Whole-phase acceptance remains blocked by missing qualification. |
| Closed OracleA findings | Round 1: S3-R0-01 (under OD15), S3-R0-02/04/05/06. Round 2: S3-R1-01/02. Round 4: S3-R0-03 explicitly fixed, not downgraded; S3-R3-01 fixed. All earlier closures retained. |
| Open OracleA P1 findings | None. Round 4 approves remediation code. New S3-R4-01 is nonblocking P2 (descendant signal-handler readiness in the escalation test), explicitly deferrable without another review round. |
| Open OracleB P0/P1 findings | None. Round 4 approves r4 code with no own or fix-induced P0/P1/P2; S3R3-B-N02 closed, other noted P3s deferred. OracleB does not close OracleA findings; OracleA's own explicit closures above establish their disposition. |
| Decisions relied on | OD7; OD12 for predecessor acceptance only; OD13 for this workstream; OD14 and OD15 for r1; OD16 for r3 and r4 |
| Acceptance | Owner-accepted for commit and progression under OD17. Both lanes approve r4 code; pipe, summary, lock and equivalence passed. The three clean PTY misses and narrowly contaminated memory result are explicitly non-blocking follow-up, not passes. |
| Reviewed bytes | Local `.agent-artifacts/step3-review-r0/files/` and `SHA256SUMS`; snapshot `2026-10-05/2234` |
| OracleA record | Initial `prompt-exports/oracle-review-2026-10-05-225040-oraclea-step3-initia-4c07.md`; round 1 `prompt-exports/oracle-review-2026-10-06-101543-oraclea-step3-r1-sco-14c0.md`; round 2 `prompt-exports/oracle-review-2026-10-06-103654-oraclea-step3-r2-emb-80c6.md`; round 3 `prompt-exports/oracle-review-2026-10-06-144642-oraclea-step3-r3-od1-e463.md`; round 4 `prompt-exports/oracle-review-2026-10-06-152604-oraclea-step3-r4-rea-6aea.md`. |
| OracleB record | Complete initial `prompt-exports/oracle-review-2026-10-05-230954-oracleb-step3-initia-a68a.md`; complete round 2 `prompt-exports/oracle-review-2026-10-06-104018-oracleb-step3-r2-emb-70ec.md`; round 3 `prompt-exports/oracle-review-2026-10-06-145536-oracleb-step3-r3-od1-1277.md`. Round 4 `prompt-exports/oracle-review-2026-10-06-154201-oracleb-step3-r4-rea-15a0.md`. The incomplete round-1 export is retained as historical evidence only. |
| Historical r1 remediation bytes | r1a, measured by every r1 capture: `.agent-artifacts/step3-r1/CANDIDATE-SHA256SUMS` (`conductor.py` `36143188…`, `conductor_output.py` `e846c1eb…`, `conductor_benchmark.py` `f7bb6907…`). Reviewed r1b, with the over-cap fix: `.agent-artifacts/step3-r1/CANDIDATE-SHA256SUMS-r1b` (`conductor.py` `0d90033d…`, `conductor_output.py` `0e566ce5…`, `test_conductor_output.py` `ace20f36…`; the other files are unchanged) |
| r1 evidence and re-review packet | `.agent-artifacts/step3-r1/EVIDENCE.md`; `.agent-artifacts/step3-r1/packet/MANIFEST.md` and `PACKET-SHA256SUMS` (r1b); the r1a packet is archived intact in `.agent-artifacts/step3-r1/packet-r1a/` |
| Reviewed r2 remediation bytes and evidence | `.agent-artifacts/step3-r2/CANDIDATE-SHA256SUMS`, `EVIDENCE.md` and `r1b-to-r2.diff`. The frozen r1b review snapshot `.agent-artifacts/step3-review-r1/` is unchanged. Main's independent r1b `make conductor-selftest` exited 0 (`.agent-artifacts/step3-review-r1/selftest-main.log`) |
| Reviewed r3 (OD16) bytes and evidence | `.agent-artifacts/step3-r3/CANDIDATE-SHA256SUMS`, `EVIDENCE.md`, `r2-to-r3.diff` and `context/`. The frozen r2 review snapshot `.agent-artifacts/step3-review-r2/` is unchanged. Main's independent r3 `make conductor-selftest` exited 0 (`.agent-artifacts/step3-r3/validation/selftest-main.log`) |
| Reviewed r4 bytes and evidence | `.agent-artifacts/step3-r4/CANDIDATE-SHA256SUMS`, `EVIDENCE.md`, `r3-to-r4.diff` and `context/`. The frozen r3 review snapshot `.agent-artifacts/step3-review-r3/` verified unchanged before editing and is not modified |
| Evidence storage | `.agent-artifacts/` is retained local working evidence, not durable contribution storage. The packet copies the material the lanes requested, with checksums, for main's re-review. |

The first OracleB delivery (`prompt-exports/oracle-review-2026-10-05-225041-oracleb-step3-initia-71af.md`) started mid-finding and omitted its opening findings in both export and chat log. It is incomplete and not counted as approval. A fresh same-preset initial review of the unchanged snapshot produced the complete replacement above. Both completed review preset identities were verified. No substitute reviewer was used.

The main agent independently reran `make conductor-selftest`: exit 0, recorded in local `.agent-artifacts/steps3-12-orchestration/step3-selftest-main.log`. The seven candidate production/test/harness checksums matched the implementation worker's evidence. The main context checker and its 23 tests also passed; the existing route-count warning remains.

**Historical r0 stop and required decisions (superseded by OD14/OD15).** The main agent asked whether to authorize (1) bounded PTY read coalescing while preserving individual receive times, raw bytes, ordered transitions, batch caps and all performance gates, and (2) an explicit OD7 extension allowing disclosed repeated older displayed lines after dedup saturation. The request timed out after 300 seconds with no answers. Neither change is authorized. No gate is waived, and no claim of optimization impossibility is made. Steps 4–12 remain blocked. No files are staged or committed. (Superseded on 2026-10-06: the owner approved both changes as OD14 and OD15; see Step 3 remediation r1.)

At the historical r0 stop, the review lanes differed on the severity/scope of summary deduplication, client rescan and retention protection. The following r0 state is superseded by the round-2 index above: OracleA's P1s remain open; OracleB's lower severity or informational treatment is not closure. No targeted remediation or re-review has occurred, so this is not yet a post-remediation contract-dispute determination. Safe independent future work includes bounded reproduction/remediation of the remaining correctness findings and evidence curation; changing summary semantics or PTY batching requires the unanswered decisions.

The historical r0 stop-record update and correction of contaminated table labels postdated that reviewed snapshot. They are documentation-only and have not received delta review. Production, test and harness bytes remain at the reviewed snapshot. Raw evidence and review exports remain local, unstaged working material.

### Step 3 remediation r1 (2026-10-06, OD14/OD15)

Status: **reviewed in round 1 of 5 on the frozen r1b bytes; not accepted, not staged, not committed.** The round-1 dispositions are in the review index above. OracleA closed S3-R0-01/02/04/05/06; S3-R0-03 stays open; S3-R1-01/02 are new and remediated in r2 (below); OracleB's round-1 delivery is incomplete. No finding is approved or closed by this document; only the main-owned OracleA and OracleB lanes can do that. r1 starts from the reviewed r0 bytes (`.agent-artifacts/step3-review-r0/`, snapshot `2026-10-05/2234`) and HEAD `506af898`. Its first bytes (r1a) are bound by `.agent-artifacts/step3-r1/CANDIDATE-SHA256SUMS`. The round-1 reviewed bytes (r1b, with the pre-review over-cap fix below) are bound by `CANDIDATE-SHA256SUMS-r1b`. Evidence is in `.agent-artifacts/step3-r1/EVIDENCE.md`, and the re-review packet is `.agent-artifacts/step3-r1/packet/`. The r0 evidence in `.agent-artifacts/step3/` is unchanged.

Every finding was reproduced on r0 before editing; S3-R0-03 was also checked against parent, which keeps the transitions. The r1 tests target each finding, and 37 mutations that revert or break a remediation are all killed.

| Finding | r1 remediation (scope) |
|---|---|
| S3-R0-01 / OracleB SEEN-01 | Under OD15, a keep-last section sets `displayedLinesMayRepeat` when an unverified line evicts after saturation, and the terminal prints a note. A repeat-evicted keep-last regression covers it; first-lines sections stay exact. |
| S3-R0-02 / OracleB WAIT-01 | `summaryPending` payload flag. The client shows a minimal pending summary with no rescan (including render) and keeps the legacy scan fallback. `wait_for_terminal` re-polls a pending terminal payload for at most 60 s (`WAIT_POLL_SECONDS` is 1 s, so the path is common). |
| S3-R0-03 | A bounded streaming `SegmentScanner` classifies over-cap records before truncation: incremental UTF-8, SGR carry, `str.isspace` stripping, every `splitlines` separator, a rolling keyword window and a 64 Ki-character content cap. In r1a, segments were applied with the receive time of the read that completed them; in r1b, they apply when the record completes (see r1b below). |
| S3-R0-04 | Narrow summary pins through payload construction, released on every path. Retention defers pinned jobs, and the last unpin reruns it. The Step 5 worker refactor is not implemented. |
| S3-R0-05 | Harness `@6`: Step 3 targets must match the independent tail model for pipe and PTY. Empty, deleted and boundary-mutated tails are rejected, and comparisons reject Step 3 arms without validated tails. |
| S3-R0-06 / SCHEMA-01 | Upper-bound counts render as "at most N … (deduplication limited …)". The artifact-scope section carries every v2 field, and the top-level quality is `exact`. |
| OracleB EQ-01, TEST-01, BATCH-01, COUPLE-01 | Prefilter-vs-regex test; per-alternative precheck fixtures; mid-record cancellation, joiner-deadline and claimant `BaseException` tests; exact UTF-8 batch bytes; load-time coupling checks. |
| OracleB DEAD-01 | **Deferred**: the legacy cursor methods and duplicate splitter remain in `swift_pipeline_metrics.py`. |
| OracleB DOC-01 | Review-index fields added above. |

Contract changes, made deliberately and reflected in tests:

- the top-level `omittedLineCountQuality` is always `exact`;
- new `displayedLinesMayRepeat` and `summaryPending` fields;
- harness output adapter `@6`, with a `tailModel` per variant.

The r0 interpretation "releases the pin" is replaced by real pins. r0's deadline-joiner interpretation (no `outputSummary`, `waitTimedOut` false) is replaced by `summaryPending` with a bounded client re-wait.

OD14 is implemented as amended in §4 Step 3 and covers the PTY only. A first r1 build flushed once per group; that contradicted the per-read flush contract, so its partial capture was stopped and discarded.

r1a disclosed four bounded over-cap divergences, none exercised by the fixtures:

- D1: a marker whose stripped content exceeds 64 Ki characters is not recognized;
- D2: segments are applied when they complete, earlier than parent's application at the LF;
- D3: tail entries derive from the kept 64 KiB prefix;
- D4: summary lines of over-cap records with heavy leading ANSI may differ from parent.

**r1b (2026-10-06, before the first re-review).** Main asked that these be resolved where feasible without expanding scope. Each was reproduced, parent vs candidate in separate processes, with inputs under 1 MiB (`repro/overcap_divergences.py`, `overcap-before.log` / `overcap-after.log`).

- **D3 and D4 resolved.** A bounded `VisiblePrefix` streams every byte of an over-cap record. It keeps the first N characters of the whole record with ANSI removed in one pass. This matches whole-text substitution exactly; the substitution is not idempotent, so it is never applied twice. The tail uses 4,097 characters with `ANSI_RE`; the summary uses 401 with the summary's CSI-only grammar.
  - Tail entries now equal the independent OD7 full-record model.
  - `summarize_file` output equals parent's (v1 projection) on ANSI-heavy over-cap lines.
- **D2 addressed only within a bound; the remainder is open.** Segment items ride on the record, so they take the receive and wall time of the read that completes it, matching parent. To bound memory, at most 16 pending items wait. Beyond that, the pending items are applied early with the current read's time: same transitions, order and final state, but earlier timestamps. The reproduction `D2c` shows this.
- **D1 not resolved; contract decision needed.**
  - Counterexample: `Test Case '-[M.S t` + 70,000 × `n` + `]' started.` Parent applies `started` with a 70,017-character test name; r1b applies nothing. A 70,000-character parenthetical with a short name also diverges.
  - The greedy name in `XCTEST_PROGRESS_RE` can grow without limit (a parenthetical may itself contain `' passed (`), so the worker's current in-memory scanner cannot retain every exact identity within its cap. This is a limitation of that design, not proof that a lossless disk-backed design is impossible.
  - Alternatives: (1) keep the bound and disclose it; (2) make names up to 64 Ki characters exact for any parenthetical length (about 50 lines of XCTest-specific scanner logic; the long-name case still diverges); (3) truncate names (changes identity); (4) unbounded content (breaks the 64 KiB pending contract).
  - Implementation position: (1).
- **D2 bound: contract decision needed.** Alternatives: early application beyond the bound (r1b), unbounded buffering, or folding pending transitions, which must replay the per-`started` budget and clamp side effects. Implementation position: the r1b bound, disclosed.
- **r1b validation.**
  - 13 new mutations bring the total to 50, all killed.
  - The focused suites pass, and `make conductor-selftest` exits 0.
  - Classification equivalence is re-run and qualified, with the same totals as r1a.
  - Guardrails, the context check and `git diff --check` pass.

Evidence (`.agent-artifacts/step3-r1/`). Every performance, lock, thread and timing result below measured the r1a bytes. The results remain valid records of r1a but are not r1b evidence. r1b touches measured hot paths: a per-record over-cap check in `tail_entries`, 9-field records in the bulk splitter, and per-line type dispatch in the summary loop. No capture was run for r1b. The parent-506af898 baseline and the r1 effects are reported separately:

| Gate metric | Parent 506af898 | r1 | Ratio | Required | r0 ratio | Result |
|---|---|---|---|---|---|---|
| `output.pipe.w0.cpu_ms` | 208.4 | 80.2 | 0.385 | ≤0.5 | 0.39 | threshold met; inconclusive (contaminated) |
| `output.pipe.w4.cpu_ms` | 4,172.5 | 86.7 | 0.021 | ≤0.25 | 0.025 | threshold met; inconclusive |
| `output.pipe.w4.wall_ms` | 2,022.2 | 129.5 | 0.064 | ≤0.25 | 0.055 | threshold met; inconclusive |
| `output.pty.w0.cpu_ms` | 214.0 | 153.5 | 0.718 | ≤0.5 | 1.085 | **fail** |
| `output.pty.w4.cpu_ms` | 511.0 | 166.9 | 0.327 | ≤0.25 | 1.92 | **fail** |
| `output.pty.w4.wall_ms` | 340.6 | 183.9 | 0.540 | ≤0.25 | 1.66 | **fail** |
| `summary.fixture.total_cpu_ms` | 4,314.0 | 1,009.7 | 0.234 | ≤0.65 | 0.23 | threshold met; inconclusive |
| `mem.seen_growth_100k_1m_mib` | 127.56 | −0.000 | — | ≤1.0 MiB | — | threshold met; inconclusive |

- **Gate capture** `step3-r1-gate-a`, via `make dev-conductor-bench-full` (output/summary/mem). `compare --profile step3-output-summary` returned exit 2. Foreign CPU exceeded the 4.0-core limit in every workload: output median 6.55 / max 7.55, summary max 6.07, memory max 6.26. No harness failures; every candidate variant has a `step3-validated` tail. With `--enforce-reference-targets`, pipe w0 CPU (80.2 > 50), PTY w0 CPU and PTY w4 CPU also miss their reference targets.
- **OD14 delta** `step3-r1-od14-delta`: the r1 tree with only the coalescing wiring disabled, compared with r1, output only. It is contaminated (median 4.75 foreign cores).
  - PTY w0 CPU 223.1 → 151.4 ms; w4 CPU 793.5 → 162.0 ms; w4 wall 472.3 → 193.2 ms. Every CI excludes zero.
  - Pipe is unchanged; its CIs include zero.
- **PTY thread attribution**, diagnostic:

  | Thread | r1 w4 | Parent w4 |
  |---|---|---|
  | Reader | 146.4 ms | 231.6 ms |
  | Waiters | 7.6 ms | 170.5 ms |
  | Watchdog | 2.0 ms | 44.1 ms |

  The remaining cost is reader work over about 5,190 one-KiB reads. Meeting w0 ≤0.5× needs about 43 ms less reader CPU. The contract-kept per-read flush accounts for about 13 ms. No further rewrite was attempted, and no gate was changed.
- **Lock, real PTY with the ledger included**: 5 runs, 4 `job_wait` clients and the real watchdog.
  - Reader p99 is 121 µs (fixture) and 129 µs (XCTest-dense), against the 5 ms gate.
  - The only holds above 5 ms are the pre-existing first-`started` ledger load (45–50 ms, Step 4 scope), once per run in both arms.
  - Final progress is identical to parent, with no watchdog trigger.
- **Classification equivalence**: qualified over 83 inputs (36.9 MB).
  - 170,812 ordered transitions are identical to parent at 4,093 B, 64 KiB, 1 KiB, and 1 KiB with OD14 coalescing.
  - 498 summaries: r1 uncapped, projected to v1, is byte-identical to parent. 18 capped summaries differ only by declared saturation, with no displayed-line differences.
- **Timing-on overhead**: diagnostic replay using the Step 2 method.
  - r1 adds 72.1 ms per 5 MiB with 1 KiB reads and 66.6 ms with 64 KiB reads, within OD12's 90 ms; parent adds 81.8–82.7 ms.
  - The replay excludes transport and persistence.
- **Functional** (r1a; the r1b results are listed above):
  - `make conductor-selftest` exited 0 (12 suites; 107 output, 74 benchmark and 143 lifecycle tests).
  - `make guardrails` and `Scripts/check-agent-context` exited 0, with the pre-existing route-count warning.
  - `git diff --check` is clean.

Unsatisfied requirements:

- the three PTY output gates fail;
- no clean, uncontaminated capture exists, so pipe, summary and memory remain inconclusive;
- the historical r1a reference targets are missed when `--enforce-reference-targets` is enabled; these conditional targets are not a new universal prerequisite;
- DEAD-01 is deferred;
- r1b performance is unmeasured;
- the D1 and D2-bound contract decisions are open, so the over-cap path still has known, disclosed divergences from parent.

No acceptance waiver, gate change or separate terminal-state or watchdog notification architecture is claimed or authorized.

### Step 3 remediation r2 (2026-10-06, S3-R1-01/02 only)

Status: **reviewed in round 2 of 5 on the frozen r2 bytes; not accepted, not staged, not committed.** OracleA explicitly closed S3-R1-01/02. S3-R0-03 remains P1/open, without downgrade. OracleB's complete delivery reports no own P0/P1 and closes all its P2s. This document records those lane dispositions; it does not independently close findings. r2 starts from the frozen r1b review snapshot `.agent-artifacts/step3-review-r1/files/`, which is preserved unchanged. Evidence is in `.agent-artifacts/step3-r2/`. No performance capture was run, so r2 performance is unmeasured; the r1a captures remain historical only.

| Finding | r2 change |
|---|---|
| S3-R1-01 | `VisiblePrefix._add` returns on an empty visible fragment, so ANSI-only input (for example, an unterminated over-cap record of `ESC[0m`) keeps no fragments; retained parts stay at most one per visible piece up to the character limit. |
| S3-R1-02 | Coalescing budgets are checked before a read starts. `ProcessOutputTransport.read_available(max_bytes)` reads at most the group's remaining bytes, so a group's total never exceeds 64 KiB when its first read does not. The 5 ms check (from the first read's receive time) runs before each further read instead of after it, so no read starts once the budget is spent; only the processing of a read already taken can end later. The benchmark's counting wrapper forwards the allowance. |

r2 also corrects the `conductor_output.py` coalescing header, which said flushes were shared, to per-read write and flush. The pump docstring is updated the same way. D1/D2 code and semantics are unchanged.

A test fixture changed deliberately. The group-ending segment-items test used to overflow the pending record through the byte overshoot that S3-R1-02 removes. It now overflows in a later group: within one group, the byte budget keeps a record started in that group under the 64 KiB cap. The time-bound expectation now follows the before-read check.

r2 validation, on the final r2 bytes:

- Mutations: 56 in total, none survived. These are the 50 r1b mutations (C05 retargeted to the moved check) plus R01–R06. R01–R06 cover kept empty fragments, no byte allowance, an after-read-only time check (the r1b behavior), a transport ignoring the allowance, an allowance off by one, and a harness dropping the allowance.
- `make conductor-selftest` exited 0: 12 suites, including 118 output, 74 benchmark and 143 lifecycle tests.
- Classification equivalence (r2 runner copy, whose coalesced fake honors the allowance) is qualified with the same totals as r1b: 83 inputs, 170,812 identical transitions, and 18 saturation-only summaries.
- `make guardrails`, `Scripts/check-agent-context` (pre-existing route-count warning) and `git diff --check` pass.

Bytes and evidence:

- r2 bytes are in `.agent-artifacts/step3-r2/CANDIDATE-SHA256SUMS` (`fc6e8824…`): `conductor.py` `2a8d4155…`, `conductor_output.py` `043a5a99…`, `conductor_benchmark.py` `393267c4…`, `test_conductor_output.py` `77ff006e…`. The other five files are unchanged from r1b.
- The delta against the frozen r1b snapshot is in `r1b-to-r2.diff`. Production lines changed (+/−): `conductor.py` +15/−8, `conductor_output.py` +6/−2, `conductor_benchmark.py` +2/−2; tests: `test_conductor_output.py` +86/−10.
- Evidence summary: `.agent-artifacts/step3-r2/EVIDENCE.md`.

### Step 3 round-2 outcome and contract-dispute stop (2026-10-06)

Both main-owned fresh review lanes completed on the frozen r2 snapshot. Their preset identities were verified, and each explicitly acknowledged the embedded delta, current source, prior findings and gate configuration. OracleB's complete r0→r2 review repairs the incomplete round-1 delivery; no substitute reviewer was used. Two shared re-review rounds have been used. No production, test or harness bytes changed after these reviews.

**OracleA's remaining finding, S3-R0-03 (P1/open, no downgrade):**

> Requirement: Preserve recognized transitions and completing-read timestamps. OD14 permits bounded available-read coalescing, not these semantic exceptions; OD15 concerns summary deduplication only.

> Disposition: Ordinary over-cap cases are repaired, but the owning P1 remains open. Tests asserting discarded markers or early application demonstrate implementation behavior, not authorization. Main’s stop on decision-dependent remedies is appropriate. The worker’s bounded-scanner recommendation and the unanswered diagnostic-failure request do not amend the contract.

The scenarios are concrete: D1 loses a valid `started` marker with a long name, or a `passed` marker with a short name and long parenthetical, when normalized content exceeds 65,536 characters. D2 applies more than 16 pending embedded transitions on an earlier read instead of the enclosing record's completing read, changing deadline anchors and potentially watchdog behavior.

**Implementation position:** the current scanner keeps memory bounded by dropping recognition above its content cap and applying excess pending transitions early. The worker recommends retaining and disclosing those bounds. That position conflicts with the preserved contract and is not authorized. A narrow OracleA planning consultation identified raw-log-backed deferred replay and disk-backed exact identity as a possible lossless direction, requiring a consumer audit and potentially broader architecture; it was not implemented or validated. This record does not claim lossless handling is globally impossible.

**OracleB's advisory position, verbatim:**

> Both are unauthorized. Neither is on Step 3's list of allowed differences, and there is no Decision.

> OracleB's position: D1 conflicts with reader-contract step 4 and with "no progress loss". My materiality view is still P2 for D1 and P3 for D2, because neither can be produced by real XCTest output. That view is advice only and does not affect OracleA's P1.

OracleB has no own P0/P1 and closed every own P2. OracleA explicitly closed S3-R1-01/02 and retained all earlier closures. Main does not adopt OracleB's severity as a downgrade of OracleA's finding. The corpus equivalence result does not cover these counterexamples.

**Decision boundary and recommendation:** main asked for explicit authorization to fail the diagnostic job visibly at the D1/D2 limits, rather than silently discard markers or move watchdog timestamps. That request timed out without an answer. Broad approval of bounded experimentation and trust in recommendations is not recorded as this contract change. The recommended decision remains fail-visible handling at the documented bounds; the alternative is retaining exact semantics and separately scoping a lossless design. Neither is implemented or authorized by this record. Performance gates remain unchanged whichever option is chosen.

**Acceptance evidence remains separate:** there is no clean current-r2 output, summary, memory or affected lock qualification. Historical r1a PTY ratios 0.718 / 0.327 / 0.540 missed the 0.5 / 0.25 / 0.25 gates, and all r1 captures were contaminated. Those results neither qualify nor measure failure on r2. OD12's historical diagnostic timing treatment is unchanged; reference-host thresholds remain conditional on `--enforce-reference-targets`.

**Final independent validation:** main reran `make conductor-selftest` on r2: exit 0, 12 Python suites plus all 23 context-checker tests; the output, benchmark, metrics and lifecycle suites include 118, 74, 67 and 143 tests respectively. Log: `.agent-artifacts/step3-review-r2/selftest-main.log`. Main also reran `Scripts/check-agent-context`, `Scripts/test-check-agent-context` (23 passed), `make guardrails` and `git diff --check`; all passed after removing a trailing blank line introduced by this documentation update. The existing route-count warning remains. All nine candidate code/harness checksums match `CANDIDATE-SHA256SUMS`; the pre-existing unrelated documentation diff is unchanged, the index is empty and HEAD remains `506af898d9ed2b059a86b6317dd4949e3c06ca33`. All three delegated sessions completed, and no Oracle operations remain pending. These functional results do not replace performance qualification or resolve D1/D2. No Swift app build, live-app validation or commit preflight was run for this stopped checkpoint.

**Deferred minor findings:** S3R0-DEAD-01 (legacy metrics cursor/splitter and stale wording) is deferred because it is non-blocking cleanup outside the two r2 repairs; reconsider in a future explicitly scoped Step 3 maintenance delta after the contract is settled, not as a prerequisite or a new refactor now. S3R1-B-N01 (the summary claimant's existing inline scan ignores its caller deadline) remains deferred as preexisting behavior. S3R2-B-N01's module-docstring wording remains reported, not looped on; the plan's last-verified date is updated here.

**Stop:** S3-R0-03 survived both re-reviews and is recorded as a contract dispute, not another implementation slip. Step 3 is not accepted; Steps 4–12 remain unimplemented and blocked. Nothing is staged or committed. This final review-index/stop-record update is documentation-only and postdates the reviewed snapshot; it has not received another Oracle review. Raw evidence and review exports remain local working material.

### Step 3 remediation r3 (2026-10-06, OD16 only)

Status: **reviewed in round 3 of 5 on the frozen r3 snapshot; not accepted, not staged, not committed** (outcome in the r4 section). r3 implements only OD16 for S3-R0-03 D1/D2 on the r2 bytes. At the r3 review, S3-R0-03 remained open on the delayed-reader lifecycle gap; OracleA subsequently closed it on r4, as recorded below. The frozen r2 review snapshot `.agent-artifacts/step3-review-r2/files/` verifies unchanged against its `SHA256SUMS`, and its working copy is `.agent-artifacts/step3-r3/base-r2/` (`BASE-r2-SHA256SUMS`). No performance capture was run: r3 performance is unmeasured and no gate changed.

| Area | r3 change |
|---|---|
| D1 (scanner) | `SegmentScanner(marker_shape=True)` checks every segment over `SEGMENT_MAX_CHARS` against `XCTEST_PROGRESS_RE` exactly, in bounded state. The state is a 12-character head (`Test Case '` plus a non-empty name), a 16-character stripped end (`' ACTION.` or `).`) and, for `).`, the `)`-free run that must start at `' ACTION (`. Only such a segment fails the scanner (`failure = "segment"`). Other oversized segments keep r2 handling: only their `Build complete!` substring test applies. A long unterminated `ESC[` literal directly after the head counts as part of the name. `conductor.py` refuses to import a `conductor_output.py` whose `XCTEST_MARKER_PATTERN` differs from `XCTEST_PROGRESS_RE`. |
| D2 (scanner) | A 17th pending item fails the scanner (`failure = "pending"`). Up to 16 items still wait for the completing read. |
| Splitter | The first failure latches `segment_failure = (kind, record seq)` and drops the scanner, so scanning stops for the rest of the stream. The failed record and every later record carry no items. `take_segment_items` and `_submit_segment_items` (early application) are removed. |
| Pump | `_submit_output_group` submits records before the failed one with their transitions, fails the job, then submits the rest without classification (raw log, telemetry and tail continue). A failure ends a coalescing group; a failure in a group's first read skips coalescing. Per-read write and flush, receive times and OD14 limits are unchanged. |
| Lifecycle | `_fail_xctest_output_contract` records a bounded reason that names the boundary, record sequence and limit but echoes no output. It adds a diagnostic `{kind: "xctest-output-contract", boundary, recordSeq, limit}` and a system line (on a new log line if the raw log ends mid-line), and marks a running job measurement-invalid. The XCTest monitor then terminates the process tree through `_terminate_xctest_stalled_job(cleanup="XCTest output contract failure")`, while the reader drains to EOF. Finalization reports `failed` with exit 70 even when the child exits 0, so no build ticket is published. The first failure keeps its reason, a stall claim never replaces it, and an earlier stall keeps its own error. |

Tests:
- Output suite (118 → 123 tests):
  - Exact 16/17-pending and 65,536/65,537-character boundaries for name and parenthetical markers, both decorated and at EOF without a newline, at chunk sizes 977, 4,093 and 65,536.
  - Marker-shape equality with the parent regex on 33 hand cases plus 160 fuzz cases, with both outcomes asserted.
  - Large non-marker records never fail.
  - Records before the failure keep their transitions, and later records feed only the tail.
  - Boundedness of shape and failed scanners.
  - Summaries never classify or fail.
  - Pump group cuts, including a first-read failure that skips coalescing.
  - The property test checks both outcomes against a reference scan.
- Lifecycle suite (143 → 147 tests), each with a real PTY child:
  - D1a, D1b, D1 at EOF without a newline, and D2c each fail visibly although the child exits 0: `failed`, exit 70, bounded reason, single diagnostic, no build ticket, rendered `Error:` line, no raw-output echo, reason on its own log line.
  - D2b at the bound and a large non-marker record complete and publish normally.
  - The first failure keeps its reason.
  - A child that keeps writing, or ignores SIGTERM, is terminated within the grace periods, and its later output is still drained.

Validation on the final r3 bytes (`.agent-artifacts/step3-r3/`):
- **Mutations.** 73 in total, all killed (`mutation/mutation-results-r3-final.log`).
  - M03, V09, V10 and C03 are retired because they mutated the removed early-application path; C07 and M20 are re-anchored; O01–O21 are new.
  - An earlier full run on the same production bytes left O20 (a first-read failure coalesces) surviving. Its test was replaced, and the superseded log is kept.
- **`make conductor-selftest`.** Exit 0: 12 suites, including 123 output, 74 benchmark, 67 metrics and 147 lifecycle tests.
- **Classification equivalence** (r3 runner copy, which also records OD16 failures). Qualified: 83 inputs, 170,812 identical transitions, 18 saturation-only summaries and 0 OD16 failures. These are the same totals as r2.
- **Over-cap repro.**
  - D1a, D1b and D2c are FAIL-VISIBLE (`failed`, 70).
  - D1c, D2, D2b and the D3/D4 tail and summary cases match the parent.
- **Checks.** `make guardrails`, `Scripts/check-agent-context` and `git diff --check` pass.

Disclosures:
- Exit 70 is shared with existing XCTest stall and measurement-invalid failures. The diagnostic kind and reason distinguish OD16.
- The log gains conductor-inserted bytes: the system line, as for stalls, plus one newline when the raw output ends mid-line. Child bytes are unchanged.
- A failed record's transitions are withheld whole, including those before the failing point; earlier records keep theirs.
- Over-cap `Build complete!` items count toward the 16-item pending bound, as in r2.
- Jobs without the XCTest watchdog have no scanner and cannot fail this way.
- If a reader latches a failure after the job has already finalized, it records the diagnostic and system line but does not change the job state.
- The deferred minor findings (S3R0-DEAD-01, S3R1-B-N01 and S3R2-B-N01) are untouched.

Bytes and evidence:
- r3 bytes: `.agent-artifacts/step3-r3/CANDIDATE-SHA256SUMS`.
  - Changed from r2: `conductor.py` `1845714c…`, `conductor_output.py` `13db6f1f…`, `test_conductor_output.py` `9e55cf99…`, `test_conductor_lifecycle.py` `5a0f8650…`.
  - The other five code files are unchanged from r2.
- Complete r2→r3 delta: `r2-to-r3.diff`.
  - Production `diff -u` lines (+/−): `conductor.py` +131/−44, `conductor_output.py` +141/−18.
  - Tests: `test_conductor_output.py` +314/−52, `test_conductor_lifecycle.py` +153/−0.
  - The diff also contains this plan's OD16 updates.
- Focused excerpts: `context/`. Evidence summary: `EVIDENCE.md`.

### Step 3 round-3 outcome and remediation r4 (2026-10-06, reader-completion guard)

**Round 3 (3 of 5, frozen r3 snapshot `.agent-artifacts/step3-review-r3/`).** Both main-owned lanes completed, and their preset identities were verified. Main's independent r3 `make conductor-selftest` exited 0 (`.agent-artifacts/step3-r3/validation/selftest-main.log`); that is r3 evidence.

- **OracleA:**
  - Retains all earlier closures (S3-R0-01/02/04/05/06, S3-R1-01/02).
  - Finds D1/D2 remediated under OD16.
  - Keeps **S3-R0-03 P1/open, without downgrade, on a new lifecycle basis.** `_run_job` continued after its two bounded reader joins without requiring the reader to have finished. A reader delayed before reporting an OD16 failure could therefore let the job finalize `completed` and publish the root build ticket. The late report then changed no state.
  - Raises S3-R3-01 (P2, test): the post-failure `tick` assertion depended on scheduling.
- **OracleB:**
  - Approves the r3 code with no own or fix-induced P0/P1/P2. This is code approval only: it neither closes nor downgrades OracleA's finding, and Step 3 acceptance remains unqualified.
  - Reports P3s S3R3-B-N01–N04 and requests helper context.

Main agrees that the delayed-reader race is a valid in-scope OD16 correctness gap. Records:
- OracleA: `prompt-exports/oracle-review-2026-10-06-144642-oraclea-step3-r3-od1-e463.md`
- OracleB: `prompt-exports/oracle-review-2026-10-06-145536-oracleb-step3-r3-od1-1277.md`

**r4 status: reviewed in round 4 of 5; remediation code approved by both lanes, but Step 3 not accepted, staged or committed.** r4 changes only the reader-completion guard and the S3-R3-01 test. OracleA explicitly closed S3-R0-03 and S3-R3-01; final dispositions are below. The frozen r3 snapshot verified unchanged before editing and is not modified. No performance capture was run: r4 performance is unmeasured and no gate changed.

| Area | r4 change |
|---|---|
| Reader-completion guard (S3-R0-03) | The two reader joins use `OUTPUT_READER_JOIN_SECONDS` (2.0 s, unchanged). If the reader of a classifying (watchdog-enabled) job is still alive after both joins and the reader close, `_fail_incomplete_xctest_output_reader` runs before `xctest_process_finished`, provenance, finalization and ticket publication. It always records a bounded diagnostic `{kind: "xctest-output-reader-incomplete", joinSeconds, outcomeChanged}` and a system line (on a new log line if the log ends mid-line). A job that would otherwise succeed (exit 0, not canceled, timed out or already measurement-invalid) becomes measurement-invalid. It then finalizes `failed` with exit 70 and its bounded reason, and publishes no ticket. Outcomes already decided keep their reasons. Remaining verified job processes get the bounded TERM/KILL escalation. There is no further or unbounded wait. A resumed reader finds its descriptor closed (EOF); its late transitions and OD16 report change no outcome, reason or ticket, because finalization and ticket writes do not run again. Jobs without the watchdog have no scanner and are not guarded. |
| S3-R3-01 (test) | The relay test is synchronized. The child writes `after-failure` only after the failure is recorded (a go file), and the monitor's termination proceeds only after the reader has submitted that line. The test asserts this ordering, the relayed line after the reason, the failed outcome and a dead tree. Coverage is not weakened. |

New lifecycle tests (147 → 151; the r3 relay test is rewritten):
- **Held reader before the OD16 report** (D2c, and D1 at EOF without a newline). The reader is held in `_fail_xctest_output_contract` beyond both joins (patched to 0.2 s), then released.
  - Before release: `failed`/70, the guard reason, and no ticket.
  - After release: the same outcome and reason, still no ticket, and the late OD16 report recorded.
  - Clean-up: no new live threads, and no thread exceptions.
- **Held reader without any OD16 failure** (in `_submit_output_records`). The job still fails, and its transitions are applied late without changing the outcome.
- **Guard tree cleanup.** The root exits 0 after spawning a TERM-ignoring descendant that holds the PTY; the guard's KILL escalation ends it.
- **Precedence unit test.** Nonzero exit, timeout, stall and cancel keep their reasons (`outcomeChanged: false`).

Validation on the final r4 bytes (`.agent-artifacts/step3-r4/`):
- **Mutations.** 80 in total, all killed (`mutation/mutation-results-r4-final.log`).
  - These are the 73 r3 mutations plus G01–G07: no guard, no invalidation, overriding a decided outcome, no tree cleanup, no KILL escalation, a reason joining an open line, and a reader that stops after a failure (S3-R3-01).
  - O11 is re-anchored to its r3 context line because the guard repeats its two lines.
  - G06 first survived; adding the EOF-without-newline held case killed it (`mutation-guard-prelim.log`, `mutation-G06-rerun.log`).
- **Repetition.** The OD16 lifecycle class passed 15 of 15 separate-process runs.
- **`make conductor-selftest`.** Exit 0: 12 suites, including 123 output, 74 benchmark, 67 metrics and 151 lifecycle tests.
- **Not rerun.** Classification equivalence and the over-cap repro, because the pump and scanner bytes are unchanged; their r3 report rows and provenance are in `context/`.
- **Checks.** `make guardrails`, `Scripts/check-agent-context` and `git diff --check` pass.

OracleB's round-3 P3s (reported, not fixed):
- **N01.** `xctest_watchdog_triggered` is not in `to_payload`, rendering or telemetry. Its only other read is the benchmark harness's error text, so an OD16 failure is never presented to users as a stall. Deferred.
- **N02.** r4 removes its success case: a guarded job whose reader outlives the joins can no longer finalize `completed`. A post-finalization OD16 report remains possible for an already unsuccessful job; OracleA's round-3 review explicitly permits late diagnostic-only reporting for an already unsuccessful job, and its round-4 review closes the false-success gap.
- **N03 and N04.** Deferred, along with S3R0-DEAD-01, S3R1-B-N01 and S3R2-B-N01. N03's disclosure precision: the conductor-inserted newline splits the child's open line in the raw log and in later summaries.

Pre-existing behavior, not changed by r4, reported for main:
- On macOS, closing a PTY master while the reader is blocked in `os.read` does not return until every holder of the slave closes it (`preexisting/pty_master_close_blocks.log`).
- In the parent and in r2–r4, `close_reader()` after the first join can therefore wait as long as a live descendant holds the PTY without writing. The job stays `running` instead of succeeding.
- Bounding that wait would mean ending lingering descendants of normally exiting jobs, a broader contract change that needs a decision.
- The guard's cleanup also reaches only descendants the conductor has verified: orphans it never tracked are as unreachable as on other normal-exit paths.

Bytes and evidence:
- r4 bytes: `.agent-artifacts/step3-r4/CANDIDATE-SHA256SUMS`.
  - Changed from r3: `conductor.py` `58e139e4…` (+68/−2) and `test_conductor_lifecycle.py` `acb257ae…` (+199/−6).
  - The other seven code files are unchanged.
- Complete delta from the frozen r3 snapshot, plan included: `r3-to-r4.diff`.
- Focused context, including every OracleB-requested helper, read site, timing, mutation patch, equivalence row and repro provenance: `context/`.
- Summary: `EVIDENCE.md`.

### Step 3 round-4 outcome (2026-10-06)

**Code remediation approved by both required lanes; whole Step 3 acceptance remains blocked.** Both fresh round-4 reviews confirmed receipt of the complete frozen-r3→r4 delta and requested evidence. Main verified both exact preset identities and the candidate hashes. No production, harness or test code changed after the frozen r4 review snapshot.

- **OracleA:** explicitly closes **S3-R0-03 as fixed, not downgraded**, and **S3-R3-01 as fixed**. All earlier closures remain. Its code verdict is approved with a nonblocking test finding.
- **OracleB:** approves r4 code, with no own or fix-induced P0/P1/P2; closes S3R3-B-N02 and retains prior closures. This does not substitute for OracleA's explicit closures.
- **Rounds:** 4/5 used; no new round for minor observations. Records:
  - `prompt-exports/oracle-review-2026-10-06-152604-oraclea-step3-r4-rea-6aea.md`
  - `prompt-exports/oracle-review-2026-10-06-154201-oracleb-step3-r4-rea-15a0.md`
- **Frozen reviewed bytes:** `.agent-artifacts/step3-review-r4/files/`, `SHA256SUMS` and `r3-to-r4.patch`. The worker's original plan hash remains bound to that snapshot; this outcome-record update postdates it and is documentation-only, not an additional reviewed code change.

**Validation:** main's independent r4 `make conductor-selftest` exited **0**, with 12 Python suites including 123 output, 74 benchmark, 67 metrics and 151 lifecycle tests. The separate context checker passed all 23 tests. Main also ran `make guardrails`, `Scripts/check-agent-context`, `Scripts/test-check-agent-context` and `git diff --check`; all passed, with the existing route-count warning. Worker evidence records 80/80 killed mutations and 15/15 focused lifecycle runs. Main's log and explicit exit/hash provenance are in `.agent-artifacts/step3-r4/validation/selftest-main.log` and `selftest-main-evidence.md`. r3 classification equivalence and reproductions were not rerun for r4; their unchanged pump/scanner coverage is carried forward only as disclosed focused evidence.

**Deferred findings, not hidden acceptance blockers:**
- **S3-R4-01 (OracleA P2):** the TERM-resistant descendant test does not acknowledge that its signal handler is installed before escalation. A heavily delayed child could die on TERM and fail the expected KILL assertion. OracleA explicitly permits deferral and says not to open another round solely for it. Synchronize readiness in the next necessary lifecycle-test change; retain the escalation assertions.
- **OracleB S3R4-B-N01/N02/N03 (P3):** thread death after a reader exception is not distinguished from normal completion; a resumed reader can attempt to use a closed sink; raw-log diagnostic insertion can race late writes. These are disclosed fault/late-reader limitations, not fixes included in r4. Avoid claiming all late-reader positions preserve full raw output or end without thread exceptions.
- **OracleB S3R4-B-N04 (P3):** the guard also fails ordinary input whose reader remains incomplete. Main's implementation rationale is recorded under OD16 above; this is necessary to prevent unreported OD16 failures from publishing success, not a performance waiver.
- **OracleB S3R4-B-N05 (P3 documentation):** this update removes contradictory round counts, distinguishes Steps 1–2 r4 from Step 3 r4, records current dispositions, and attributes OracleA's late-failure position to its actual reviews.
- **OracleB S3R4-B-N06 (P3):** repeated termination logic and limited non-watchdog integration coverage are deferred; no unrelated refactor is added. Earlier deferred P3s remain listed in their owning round records.

**Remaining stop (at round 4; superseded by the qualification below):** no clean current-r4 output, summary, memory or affected lock qualification had been captured. Historical r1a PTY ratios missed gates and all captures were contaminated; they neither qualify r4 nor establish current-r4 performance failure. Performance gates, sample/contamination policy and conditional reference targets remain unchanged. Both lanes withhold whole-phase acceptance. The pre-existing macOS PTY-close block is a separate shutdown-policy issue, not reopened as a Step 3 gate; r4 makes no four-second end-to-end shutdown guarantee.

Step 3 is therefore not staged or committed, and Steps 4–12 remain unimplemented and blocked pending empirical acceptance. No Swift application build, live-app operation or commit preflight was run for this checkpoint. All delegated sessions completed; no Oracle operation or validation process is left pending.

### Step 3 current-r4 qualification (2026-10-06)

**Result: PTY output gates fail on a clean capture; pipe, summary, lock and equivalence pass; memory is inconclusive. The owner subsequently accepted this measured checkpoint under OD17.** This is measurement evidence only. It is not an Oracle verdict or empirical-acceptance claim. No code, harness, gate, sample minimum or contamination rule changed. Local evidence: `.agent-artifacts/step3-r4-qualification/` (`MANIFEST.md`, `SHA256SUMS` `f7429866…`).

**Method.**
- Targets: baseline is the immediate parent `506af898` (`.agent-artifacts/step3/parent-506af898`, equal to HEAD). Candidate is the current tree, re-verified byte-equal to frozen r4 (`step3-review-r4/SHA256SUMS` `71693777…`, all 7 code/test files).
- Both arms ran under the same current harness (`conductor_benchmark.py` `393267c4…`, harness digest `f025d31f…`).
- Capture A was contaminated (foreign cores up to 4.78) and exited inconclusive. It was followed by one retry, capture B.
- `--enforce-reference-targets` was not used.
- No app or daemon was stopped. Foreign load (Storage.appex, the CE Dev app, editors and browsers) is recorded in `preflight/`.

| Gate (capture B; n = 30 fast, 10 mem) | Parent | r4 | Ratio / value | Threshold | Validity | Result |
|---|---|---|---|---|---|---|
| Pipe w0 CPU ms | 190.487 | 77.119 | 0.405 | ≤0.50 | clean (max 3.63) | pass |
| Pipe w4 CPU / wall ms | 3,118.264 / 1,533.675 | 81.144 / 87.108 | 0.026 / 0.057 | ≤0.25 | clean | pass |
| PTY w0 CPU ms | 187.199 | 146.005 | 0.780 | ≤0.50 | clean | **fail** |
| PTY w4 CPU ms | 351.088 | 155.657 | 0.443 | ≤0.25 | clean | **fail** |
| PTY w4 wall ms | 263.021 | 198.744 | 0.756 | ≤0.25 | clean | **fail** |
| Summary fixture CPU ms | 4,272.126 | 997.956 | 0.234 | ≤0.65 | clean (max 3.64) | pass |
| Single scan per log | — | — | `test_racing_status_wait_and_completion_scan_once` | self-test | r4 selftest exit 0 | pass |
| Memory growth 100k→1M MiB | 127.564 | −0.000 | −0.000 | <1.0 | 1 sample at 4.03 > 4.0 | **inconclusive** (threshold met) |
| Lock p99 batch hold | 6.8–12.6 µs | 106.8–131.0 µs | max p99 131.0 µs | ≤5 ms | real PTY, ledger, watchdog, 4 waiters | pass |
| Progress loss/reorder | identical | identical | log = transport bytes | none | 5 runs × 2 inputs | pass |
| Classification equivalence | — | — | 83 inputs; 170,812 transitions × 4 read modes identical; 18 saturation-only diffs; 0 OD16 failures | qualified | r3 script | pass |

**Lock profile.** The only hold above 5 ms in either arm is the pre-existing first-`started` ledger load (44–51 ms, Step 4 scope), once per run. The r1 lock profiler had to be copied with one fix: its `read_available` wrapper now forwards the S3-R1-02 byte allowance. Its crashed outputs are kept as invalid.

**Timing-on (OD12 diagnostic, treatment unchanged).** Added reader CPU per 5 MiB is 71.7 ms (r4, 1 KiB), 68.5 (64 KiB) and 84.1 (per line), against the parent's 81.0 and 81.6. Every arm stays ≤90 ms.

**PTY attribution (bounded; nothing coded).**
- r4's PTY cost is the reader thread: 143 of 146 ms process CPU at w0, and 149 of 158 at w4.
- A diagnostic transport-only floor (cat → PTY → the target's own `read_chunk`, discarding output) is 48 ms wall and 18 ms CPU in both arms. Wall is therefore reader-bound, not producer-bound.
- The reader's ≈143 ms splits into:
  - ≈18 ms transport;
  - ≈13 ms contract per-read write+flush;
  - ≈87 ms per-record processing (in-process 1 KiB replay; parent 49.9 ms);
  - ≈25 ms group, select, lock and GIL overhead.
- Processing is led by visible-tail construction (`tail_entries`) and the regex splitter (`feed`).
- Required reductions:
  - w0 CPU: −52.4 ms, to ≤93.6;
  - w4 CPU: −67.9 ms, to ≤87.8;
  - w4 wall: −133.0 ms, to ≤65.8. That is ≤18 ms above the transport floor, including the 13 ms flush.
- Smallest plausible contract-preserving fix: build tail entries only for records that can survive into each group's tail, and use bytes fast paths instead of per-read regex splitting.
- Projected effect (estimate, not measured): about −25 to −45 ms. All three PTY gates would still fail; even parent-cost per-record work would leave w0 at about 105–110 ms.

**Main's decision recommendation:** accept the reviewed Step 3 implementation at its measured gains, carrying the three missed PTY targets and narrowly contaminated memory result as non-blocking follow-up rather than authorizing a deeper rewrite. Clean PTY improvements are 22.0% (w0 CPU), 55.7% (w4 CPU) and 24.4% (w4 wall); this is not a claim that the original 50%/75% targets passed. The proposed optimization's projected savings remain estimates, not proof that the original targets are impossible.

Main asked explicitly whether to approve this measured acceptance, commit Step 3 and proceed to Step 4. The request initially timed out after 300 seconds with no answer; the owner subsequently approved it explicitly, recorded as OD17. The user's request to resolve the gates was not silently treated as a waiver. Main verified the 60-file evidence manifest, the clean output/summary and contaminated-memory labels in capture B, and the lock summary. Reviewed r4 code remains byte-identical, the unrelated tracked documentation diff is unchanged, HEAD is still `506af898d9ed2b059a86b6317dd4949e3c06ca33`, and the index is empty. All worker processes finished. Only this owning plan changed; no additional code review round was used. That historical acceptance block is now resolved by OD17; Step 4 may proceed in plan order.

### Step 4 implementation checkpoint (2026-10-06, OD13)

Status (r0, frozen under `.agent-artifacts/step4-review-r0/`): **implemented; both initial reviews requested changes; remediation r1 follows below. Not accepted, not staged, not committed.** The parent is HEAD `f6bc1a8e` (Step 3 commit). Raw evidence is local under `.agent-artifacts/step4/`: `PARENT-SHA256SUMS`, `CANDIDATE-SHA256SUMS`, `delta-scripts.patch`, the `parent-f6bc1a8e/` target, mutation, footprint and bench outputs. It is not contribution material.

Implementation (`Scripts/conductor.py`):

- `RuntimeLedgerCache` is daemon-owned (`DaemonState.runtime_ledger_cache`). It keeps one current `MappingProxyType` snapshot keyed by `(resolved path, st_dev, st_ino, st_size, st_mtime_ns, st_ctime_ns)`.
- **Loading.** `load()` runs under a private lock plus a single-flight event, never under `self.condition`. Joiners take the leader's result. The cache stats before and after the read, retries once on a change, and otherwise falls back. Unreadable, undecodable and changed-twice ledgers fall back to the flat budget with the existing "XCTest runtime ledger unavailable …" diagnostic and leave no current snapshot. An unexpected loader exception propagates to the leader; joiners get a fallback and the flight is always cleared.
- **Parsing.** `_parse_xctest_method_runtimes` is the parent loop, extracted unchanged. A row lacking a suite, method or runtime is ignored, as is a negative, non-finite or unparsable runtime; the first valid row wins.
- **Pin.** `_pin_xctest_method_runtimes` runs in `_run_job` after the start line and before `Popen`, outside the condition, and only for watchdog-enabled jobs without `--xctest-stall-seconds`. A fallback diagnostic is written to the log outside the condition; only the tail update and pin assignment take the condition.
- **Release.** `_run_job`'s `finally` calls `_release_xctest_method_runtimes_locked` under the condition before lane release and scheduling. This covers completion, failure, cancellation, timeout and runner exceptions.
- **Budget.** `_set_xctest_active_method_budget_locked` reads only the pinned snapshot. Its ledger I/O and the old `_load_xctest_method_runtimes_locked` are removed.
- **Residency.** Every watchdog-enabled operation (`test`, `test-artifact`, `provider-test`, `core-test`) uses the `build` lane, so at most one job per daemon holds a pin. Resident snapshots are therefore the current one plus at most one older pinned one, which matches "at most 2". No counterexample was found.

Behavior changes for review:

- The fallback diagnostic now appears once per consulting job, right after the `$ argv` line, instead of at the first started marker. That includes jobs that fail before any marker. Because the line matches `OutputSummarizer.FAILURE_RE` (`No such file or directory`), it adds one error count, and the "Failure highlights" section of every summary now includes the following four lines as context. That covers success summaries as well, since success clears only "Recent output". Each context line stays within the Step 3 display cap of 400 characters. Normal checkouts are unaffected, because the ledger is tracked (OD3).
- This exposed the OD16 lifecycle fixture `XCTestOutputContractLifecycleTests.run_child`, which had no ledger: its oversized record entered summary context. The fixture now writes a realistic ledger whose row does not match `M.S`. Budgets stay `default`-sourced, and every assertion is unchanged.
- Two tests that asserted the old lazy load, `test_missing_runtime_ledger_logs_once_and_uses_default` and `test_negative_runtime_ledger_entry_is_ignored`, now pin first. Their assertions are unchanged.
- r0 left the pre-existing clamp diagnostic in `_set_xctest_active_method_budget_locked` appending to the job log under the condition. Both reviews raised this as P1; remediation r1 below moves the write out of the condition.

Harness adapter, the minimum needed for both arms (`Scripts/conductor_benchmark.py`, `HARNESS_VERSION` 7):

- `mem@2` pins and releases through the target's production seam when present; older targets keep their lazy path. Control jobs never pin. The ledger arm checks `ledger-derived` budgets instead of the released field, and records `ledgerParsesFor5Jobs`.
- `rss@2` checks ledger use by budget source.
- The `step4-ledger` profile and gates are unchanged.

Gates and evidence (host as in Step 3; Python 3.14.7):

| Gate / check | Parent `f6bc1a8e` | Candidate | Limit | Result |
|---|---|---|---|---|
| `mem.ledger_retained_n200_mib` (median, 10 fresh-process pairs) | 310.231 MiB | 1.600 MiB (0.52%) | ≤4 MiB and ≤5% | `step4-ledger` compare **exit 0 (qualified)** |
| `mem.ledger_retained_n56_mib` | 86.871 MiB | 1.566 MiB | — | no regression |
| `mem.ledger_load_ms` (5 jobs, median) | 40.856 ms | 0.024 ms (cache-hit median: the one cold parse per identity, ~40 ms, runs before `Popen`, outside the condition) | — | no regression; not a faster parse |
| Parses per unchanged identity | per job | 1 for 5 jobs in all 10 samples; 1 across sequential `_run_job` tests | 1 | pass |
| Snapshot equivalence | 5,310 entries | 5,310 entries; equals the parent loader on the curated ledger | identical | pass |
| No ledger I/O under `condition` | — | real `_run_job` boundary: every stat/open/parse saw `RLock._is_owned()` false; pinned before `Popen` | none | pass |
| Contamination | — | 20 windows, median 1.54, max 3.53 foreign cores | ≤4.0 | clean |

The capture `step4-mem-full-20261006` was one capture, with no retry used. It ran only the `mem` workload (`--full`, 417 s). Its 60-second preflight measured 4.59 foreign cores on the first attempt (no capture created), then 2.86. The harness digest is `e24d195c…`; arm conductor digests are parent `6300c81a…` and candidate `a2ef50e0…`. The `no-regression` profile on the same capture exits 2 only because the `output`, `summary` and `cli` workloads were not captured. That profile is not a Step 4 gate, and this is not a pass.

**OD6 review trigger: fires; review only, no implementation.** A fresh real `__daemon` was run per arm: direct spawn, isolated state and socket, real machine slots, 56 retained `test` jobs through `./conductor test` on the `rss` fixture repo, and `/usr/bin/footprint`. All jobs completed, every log had a started marker, and none logged a fallback.

| Arm | Fresh | After 56 jobs | RSS after |
|---|---|---|---|
| Parent | 41.9 MiB | 169.1 MiB | 180.0 MiB |
| Candidate | 42.8 MiB | **86.8 MiB** | 99.4 MiB |

The candidate exceeds 70 MiB. Its dirty memory is MALLOC_SMALL 37 MB, MALLOC_LARGE 26 MB and VM_ALLOCATE 20 MB (`footprint/footprint-*-detail.txt`). Nine conductor daemons were resident on the host (≥5). That count was observed in-session with `pgrep -fl __daemon | grep -c conductor.py`; no count artifact was saved. Both OD6 conditions hold, so idle exit and job history go to main's review.

Validation:

- `make conductor-selftest` exits 0 on the frozen candidate bytes, across 12 suites plus the context checker.
- 16 focused `RuntimeLedgerCacheTests` cover: parent-equivalent parsing, including the curated ledger; one immutable snapshot per identity; inode and symlink keys; single-flight joiners; leader-exception release; retry-once; double-change fallback; unreadable and undecodable fallbacks; at most 2 resident; budget lookup with no I/O; the non-consulting job kinds; the real `_run_job` boundary; and release on completion, cancellation and runner error.
- Mutation check: all 8 mutants are killed — no terminal release, no single-flight, no retry, I/O under the condition, no identity cache, no pre-start pin, no stat-after, last-row-wins.
- `test_conductor_benchmark` passes 74 tests.
- Main's own runs, initial-only evidence on the r0 bytes: `selftest-main.log` (exit 0) and `guardrails-main.log` (exit 0, one route-count warning) under `.agent-artifacts/step4/`.

### Step 4 initial review outcome (2026-10-06)

- **OracleA: changes requested.** S4-R0-LOCK-IO (P1): the budget clamp still writes the log under the condition. S4-R0-FALLBACK-COVERAGE (P2): the fixture change removed `_run_job` coverage of the missing-ledger path. The numerical gates are supported by the evidence.
- **OracleB: changes requested.** S4-R0-01 (P1), the same clamp I/O. S4-R0-02 (P3): missing-ledger `_run_job` coverage is gone, and the plan's "failure summaries" wording was too narrow. S4-R0-03 (P3): the "at most 2 resident" bound rests on an unguarded lane invariant. S4-R0-04 (P3): the `mem.ledger_load_ms` label. S4-R0-05 (P3): missing index fields. No new `mem` capture is needed if the measured path is unchanged.
- **OD6 review discussion.** Both lanes find both triggers fired, and both recommend keeping idle exit and job history deferred. OracleB suggests an owner question and Decision; OracleA, a separately authorized bounded follow-up. The existing OD6 scope is unchanged: the trigger requires review, not implementation, so no new Decision or owner waiver is needed. An optional re-check, after Steps 5–6, of footprint at 56 jobs and at the 200-job cap, with live-heap vs. footprint attribution, may inform a later decision. It is not a mandatory gate or campaign, and it has no deadline. Main states this in the fresh review.

### Step 4 remediation r1 (2026-10-06, S4-R0-LOCK-IO / S4-R0-01, S4-R0-FALLBACK-COVERAGE / S4-R0-02, optional S4-R0-03–05)

Raw evidence: `.agent-artifacts/step4-r1/`. Frozen r0 stays under `.agent-artifacts/step4-review-r0/`.

- **Clamp diagnostic outside the condition.** `_set_xctest_active_method_budget_locked` now calls `_append_deferred_system_line_locked`. That appends the line to the tail under the condition, as before, and queues its log write on `Job.deferred_log_lines`. The queue is bounded: at most one line per transition in a batch, and it is taken every batch.
  - **Flush points.**
    - The output reader takes the queue under the same per-batch lock, then writes it after release: before the next batch and the next read.
    - `_flush_deferred_log_lines` serves direct `_record_xctest_progress_locked` callers. Only tests call it; the benchmark `mem` adapter's jobs have no timeout, so they never clamp.
    - `_run_job`'s `finally` flushes defensively after transports close.
  - **Unchanged.** Diagnostic text, the raw-chunk write and flush, the reader's per-read order (raw bytes, then that read's clamp lines, then the next read), OD14 coalescing and OD16 failure handling. The OD16 failure line still follows the clamps of earlier records.
  - **Ordering note.** A system line written by another thread (watchdog, termination) was never deterministically ordered against reader writes. It may now land between a clamp's tail append and its log write.
- **Evidence.**
  - On real `_run_job`, the parent `f6bc1a8e` and r1 produce byte-identical logs for the normal and the clamped scenarios (`logbytes/compare.txt`).
  - Missing-ledger logs differ only by r0's earlier diagnostic position and its resolved path.
- **Tests (`RuntimeLedgerCacheTests`).**
  - A real-I/O clamped `_run_job` regression checks: tail order; each clamp logged once; log order started A < clamp A < started B < clamp B; and every clamp write made with `RLock._is_owned()` false.
  - A direct-caller flush test checks that the line is queued, then logged once, after the condition.
  - A terminal-flush test.
  - A lane-invariant test for S4-R0-03: exactly `test`, `test-artifact`, `provider-test` and `core-test` are watchdog operations, and `registry.prepare` gives each the `build` lane.
- **Missing-ledger coverage (`XCTestOutputContractLifecycleTests`).**
  - `assert_failed_visibly` is split, with no assertion removed. `assert_failed_visibly_contract` holds the OD16 contract: failed, exit 70, a bounded output-free reason, no ticket artifact, measurement invalid, and its own log line. The 200-nines check remains for existing callers.
  - A new D1 `_run_job` test runs without a ledger. It checks: the full contract; one fallback diagnostic; a `default` budget clamped to the 20 s timeout; log order `$ argv` < diagnostic < first child output; both system writes made outside the condition; and every rendered summary line within the 400-character cap.
  - The prior failing assertion, reproduced on frozen r0 with the fixture ledger removed (`prior-fixture-failure.log`), was line 3959 `assertNotIn("9" * 200, rendered)` in cases `d1a-huge-parenthetical` and `d1-eof-without-newline`. The oversized record appeared only as display-capped "Failure highlights" context after the diagnostic (≤399 nines plus `…`). The reason stayed output-free. That check guards incidental summary context, not the OD16 contract, and it stays in place with the realistic fixture.
- **Measurement binding.** The cache, pin, release and `mem` adapter are unchanged. `Job` gained one field defaulting to `None`, and the clamp branch never runs in `mem`. The r0 `step4-mem-full-20261006` capture therefore stands for the measured path; the conductor digest delta is disclosed in the r1 hashes. No new capture was taken.
- **Validation:**
  - `make conductor-selftest`;
  - mutations R1-M1–M9: all killed (`mutation/results.txt`);
  - guardrails, the context check and `git diff --check`, results in `.agent-artifacts/step4-r1/`.

Step 4 review index (main-owned, OD13):

| Item | State |
|---|---|
| Decisions relied on | OD6 (footprint review trigger; idle exit and history deferred), OD13 (review policy), OD17 (parent `f6bc1a8e` acceptance) |
| Initial OracleA review | Changes requested: S4-R0-LOCK-IO P1 (open), S4-R0-FALLBACK-COVERAGE P2 (open). Record: `prompt-exports/oracle-review-2026-10-06-180247-oraclea-step4-initia-f0f4.md` |
| Initial OracleB review | Changes requested: S4-R0-01 P1 (open), S4-R0-02–05 P3 (open). Record: `prompt-exports/oracle-review-2026-10-06-181036-oracleb-step4-initia-d3c1.md` |
| Re-review rounds used | 1 / 5; both fresh round-1 lanes approve |
| Open findings | No P0/P1. Initial findings closed by their owning lanes. Nonblocking test-timing observation S4-R1-TEST-SYNC (OracleA P2) / S4-R1-01 (OracleB P3) deferred. S4-R1-02 documentation upkeep addressed below |
| r0 bytes | `CANDIDATE-SHA256SUMS` (`conductor.py` `82521297…`, `conductor_benchmark.py` `39be6365…`, `test_conductor_lifecycle.py` `e99efc5f…`); delta `delta-scripts.patch` `f69be751…` |
| r1 bytes | Frozen `.agent-artifacts/step4-review-r1/files/`, `SHA256SUMS`, `r0-r1.patch`; identical code to `.agent-artifacts/step4-r1/R1-SHA256SUMS`. This outcome update is documentation-only after freeze |
| Round-1 OracleA | Approved; S4-R0-LOCK-IO closed as fixed, not downgraded; S4-R0-FALLBACK-COVERAGE closed as fixed. Record: `prompt-exports/oracle-review-2026-10-06-183203-oraclea-step4-r1-cla-f992.md` |
| Round-1 OracleB | Approved; S4-R0-01 closed as fixed, not downgraded; S4-R0-02–05 closed. Record: `prompt-exports/oracle-review-2026-10-06-183756-oracleb-step4-r1-cla-ae14.md` |

### Step 4 round-1 acceptance (2026-10-06)

Main verified both exact preset identities and complete-delta receipts. Both lanes approve the frozen r1 code; neither identifies a remaining blocking code defect. OracleA identifies no mandatory acceptance gap beyond pre-commit work; OracleB confirms the Step 4 gates pass for r1, with staged-index contribution preflight required before commit.

Main independently ran `make conductor-selftest` (exit 0; 12 suites including 123 output, 74 benchmark, 67 metrics and 171 lifecycle tests), `make guardrails` (exit 0), `Scripts/check-agent-context` (exit 0, existing route-count warning), and `git diff --check` (exit 0). Logs are `.agent-artifacts/step4-r1/{selftest-main,guardrails-main,context-main}.log`. The six-entry hash manifest matched before and after validation, and the unrelated tracked documentation diff matches the session-start capture. Worker evidence records all 9 remediation mutations killed. No Swift application build or live-app validation was run for this Python-only step.

The r0 clean ledger capture is carried forward only for the unchanged measured path, as explicitly accepted by both lanes: 200-job ledger-retained heap is 1.600 MiB versus 310.231 MiB, a 99.48% reduction, with one parse per unchanged identity. The added `Job` field defaults to `None` in both control and ledger arms; their adapter jobs have no timeout and cannot enter the changed clamp path. This is not a new r1 capture or an unchanged conductor digest claim.

**Nonblocking finding:** S4-R1-TEST-SYNC (OracleA P2) and S4-R1-01 (OracleB P3) identify the same potential test flake: the clamp-order test uses a 300 ms child delay rather than a handshake. A delayed reader may receive both methods in one group, making its ordering assertion fail although production behavior is correct. Both lanes explicitly permit deferral and say not to open another round solely for it. Keep the finding for the next necessary edit to that test; no assertions are weakened here. S4-R1-02's index/OD6 provenance upkeep is addressed by this update.

**OD6 disposition by main:** review discharged; existing deferral unchanged. OracleB explicitly withdraws its initial required-owner-question framing. No idle exit, persisted history, mandatory 200-job footprint campaign, or new owner waiver is introduced. Step 5 may proceed after Step 4's isolated commit. Main staged only `Scripts/conductor.py`, `Scripts/conductor_benchmark.py`, `Scripts/test_conductor_lifecycle.py` and this plan. Staged code blobs match the frozen reviewed snapshot. Staged-index preflight passed (`.agent-artifacts/step4-r1/preflight-commit.log`). The first `git commit` failed with `error: 1Password: agent returned an error` / `fatal: failed to write commit object`, and HEAD stayed `f6bc1a8e`. Signing configuration was not changed. The later signed retry succeeded: Step 4 is commit `86e3e024ec82e76bd6d4f40092ec2ebdebb40b46`, and that historical block is resolved. Step 5 proceeds from that parent (checkpoint below).

### Step 5 implementation checkpoint (2026-10-06, OD13)

Status: **implemented; awaiting main-owned review. Not approved, accepted, staged or committed.** The parent is HEAD `86e3e024` (Step 4 commit). Raw evidence is local under `.agent-artifacts/step5/`; it is not contribution material.

Implementation (`Scripts/conductor.py`):

- **Decision under the lock.** `_retention_pass_locked` keeps the 24 h / 200-job decision, pin deferral, `self.jobs` eviction and request-key cleanup, all in memory. It hands each evicted ticket's exact paths (log, recorded diagnostics, the three timing sidecars) to the worker and requests an orphan sweep. It does no scan, stat or unlink.
- **One maintenance worker.** `_signal_maintenance_locked` queues work under a private `_maintenance_cv` (lock order: `condition` → `_maintenance_cv`). It starts `conductor-maintenance` on demand when work is due; at most one runs, and it exits when nothing is due. Queued exact removals run at once. Orphan sweeps are coalesced to at most one per `ORPHAN_SWEEP_INTERVAL_SECONDS` (60 s); a request that is not yet due waits for a later transition, so no worker or timer idles for the interval. The sweep snapshots `self.jobs` keys under the condition, then scans with `os.scandir`, `lstat`s and unlinks outside every daemon lock.
- **Exact families.** `generated_job_file_ticket` accepts only a lowercase hyphenated UUID ticket (any version; production mints `uuid4`) plus one of `.log`, `.xctest-stall.json`, `.xctest-stall.sample.txt`, `.timing-events.jsonl`, `.timings.json`, `.runner-timings.json`. Exact removals also require `path.parent == jobs_dir` and a name equal to that ticket plus one of those suffixes. Directories are never removed.
- **Pins across full ownership.** `_run_job` pins its job in its first lock block and unpins in an outer `finally`, after lane release, summary and timing persistence. The output reader, the XCTest watchdog and the timing-off summary thread start through `_start_job_owned_thread`, which pins before `start()` and unpins in the thread's `finally`, or immediately if `start()` raises. The undispatched timing worker pins before its thread starts and unpins in its `finally`, or in the start-failure branch. Status, wait and summary pins are unchanged. A pinned due job is deferred, and its last unpin reruns the pass. *Correction (r1):* r0 did not pin the three cancellation owners, which write after condition waits (S5-R0-OWNERSHIP / S5-R0-01); "full ownership" was overstated until r1.
- **Failures.** A failed exact unlink is kept in a bounded retry map (1,024 paths, oldest dropped; an aged one is still found by name) and retried by the next due sweep. A failed scan requests another sweep. A worker that cannot start leaves its work queued for the next signal. Errors are recorded only in `_maintenance_error`; job state, exit code, `measurement_invalid` and tickets never change.
- **Daemon exit.** After the existing timing drain, `run_daemon` waits at most `TIMING_DRAIN_SECONDS` in `_await_maintenance` for queued removals.
- **Unchanged.** Policy (24 h / 200 jobs). Unknown status for an evicted ticket. The `retention_pass` operation name and origins, which now time only the in-memory decision. `RotatingJsonl` history rotation, which already ran outside the condition. OD14 raw read/flush, OD16 visible failure and the Step 4 ledger cache.

Behavior changes for review:

- **Narrower orphan sweeps.** The parent globbed `*.log`, `*.xctest-stall.*` and `*timing*`, and deleted any aged unretained match. Non-generated aged names such as `notes.log` or `<uuid>.xctest-stall.extra` now survive; the parent deleted both in the gate-1 run below.
- **Asynchronous deletion.** An evicted ticket is unknown immediately; its files disappear shortly afterwards. The parent ran a sweep on every transition; now a sweep may wait up to 60 s, plus until the next transition. Exact removals of evicted jobs are not delayed by the sweep interval, but they can queue behind a busy worker (an in-progress unlink or sweep).
- **Pins on running jobs.** Running jobs now hold pins. They were never evictable, so this changes no decision.
- **Pre-existing, out of scope.** `_invalidate_root_build_ticket_locked` unlinks `build-ticket-root.json` under the lock when a root-ticket-invalidating job starts. It is not retention and is unchanged; it appears separately in the gate-1 counts.
- **Test adjustments.** Assertions are unchanged and deliberately target the async contract. The two existing retention tests drain `_await_maintenance` before their file assertions. The orphan fixture uses UUID tickets. The lifecycle supersede test selects the escalation `Thread` call by target rather than the last call, because the enqueue now also constructs the maintenance worker.

Gates and evidence (host: 28 cores, Python 3.14.7; the one-minute load average was 5.2–5.4 throughout; 9 conductor daemons were resident):

| Gate / check | Parent `86e3e024` | Candidate | Limit | Result |
|---|---|---|---|---|
| Jobs-dir scan/stat/unlink under the scheduler lock, through every production caller (6 real `build` jobs, a queued cancel, status/wait pins with `MAX_TERMINAL_JOBS`=3, 30 expired and 100 orphan families) | 1,502 events (804 `os.remove`, 42 `os.scandir`, 662 `os.stat`) | **0**; 796 removes, 1 scan, all off the lock | 0 | pass |
| `status_payload` during a blocked cleanup (640 files, 2 ms injected per unlink), 5 ABAB fresh-process runs | median 1,952 ms | median 0.057 ms first probe, max 0.193 ms | ≤50 ms | pass |
| `enqueue` during the same blocked cleanup (trigger / concurrent probe) | 1,953 / 1,953 ms | max 0.483 / 0.146 ms | ≤50 ms | pass |
| Scheduler-lock hold per retention pass, with 200 retained jobs plus 1,000 fresh orphan names (50 passes × 5 runs) | median p50 10.7 ms, p95 11.8 ms | median p50 0.017 ms, p95 0.022 ms | — | improvement |
| Cleanup completeness | 640/640 removed | 640/640 removed; drained | all | pass |

- **Gate 1 run** (`ab/lock_io_qualify.py`, `ab/q1-final/`). It uses `sys.addaudithook` for `os.remove`, `os.scandir`, `os.listdir` and `glob.glob`, and wraps `os.stat` and `os.lstat`, recording whether the calling thread owned the scheduler `RLock`. `DirEntry.stat` cannot be intercepted; it runs in the same worker function after the off-lock scan.
- **Root build-ticket unlinks.** The pre-existing `build-ticket-root.json` unlink occurred 6 times under the lock in each arm, once per job, and is excluded from the retention count.
- **Latency runs** (`ab/retention_ab.py`, `ab/summary.md`) use an injected slow disk, not a real stall.
- **Contamination.** It was not measured with the Step 1 harness's foreign-core metric. These are targeted lock-behavior A/B captures, not a benchmark-harness campaign.

Tests (`Scripts/test_conductor_output.py`, `Step5RetentionMaintenanceTests`):

- the name predicate;
- the off-lock exact-family cleanup, with foreign files, a foreign recorded diagnostic path and a generated-name directory;
- status, enqueue and list within 50 ms while an unlink is blocked, plus a bounded drain that reports the stuck work;
- one coalesced sweep per interval, without delaying exact removals or idling a worker;
- failed-unlink retry by a later sweep, while the evicted ticket stays unknown and the surviving job is unchanged;
- a worker start failure, with work kept queued;
- dispatched and undispatched timing finalization staying pinned until persisted, with no sidecar recreated;
- a job-owned reader that outlives `_run_job` keeping its job pinned.

Validation:

- **Mutation.** 10 mutants are each killed by their intended test, and the unmutated control passes (`mutation/results.txt`): synchronous I/O under the lock, no owner pin, no undispatched pin, no sweep interval, no retry, a suffix-only predicate, no exact-item guard, an uncaught start failure, an unpinned reader, and a worker holding the lock. A first harness attempt was invalid (import error) and is kept under `mutation/invalid-attempt1/`.
- **Repeat runs.** 25 repeats of the focused tests had 0 failures.
- **Repository checks.** `make conductor-selftest` exits 0 (12 suites, including 132 output and 171 lifecycle tests). `make guardrails` exits 0. `Scripts/check-agent-context` exits 0 with the existing route-count warning. `git diff --check` exits 0. Logs are under `tests/`.

Step 5 review index (main-owned, OD13):

| Item | State |
|---|---|
| Decisions relied on | OD6 (deferral unchanged; no idle exit or history), OD13 (review policy), OD14/OD16 and Step 4 (preserved) |
| Candidate bytes | `CANDIDATE-SHA256SUMS` and `delta.patch` under `.agent-artifacts/step5/` |
| Initial reviews (frozen r0, `.agent-artifacts/step5-review-r0/`) | OracleA: code **changes requested**, S5-R0-OWNERSHIP P1 open; acceptance withheld on correctness, with both numerical gates supported. OracleB: code **approve**, conditional on C1/C2 confirmation; S5-R0-01 P2 (same gap); S5-R0-02–05 P3 |
| Remediation r1 | Below; candidate bytes `.agent-artifacts/step5-r1/R1-SHA256SUMS`, frozen for review as `.agent-artifacts/step5-review-r1/files/` |
| Round 1 (frozen r1) | **OracleA:** S5-R0-OWNERSHIP **closed, fixed (not downgraded)**. New **P1 S5-R1-STOP-PIN-ROLLBACK** (open): `stop(force=True)` could raise after acquiring pins but before its thread-start rollback. Code changes requested; acceptance withheld pending that fix and the `conductorDigest` clarification. **OracleB:** code **approve**. S5-R0-01, S5-R0-02 and S5-R0-05 closed, fixed. C1/C2 confirmed, so the approval is unconditional. S5-R0-03/04 remain deferred P3s. New P3 S5-R1-01 is the same gap as OracleA's P1; new P3 S5-R1-02 (route the cancellation threads through `_start_job_owned_thread`) is deferred. The optional `_append_system_line_locked` eviction guard is deferred. Both lanes asked for the `conductorDigest` provenance. |
| Remediation r2 | Below; candidate bytes `.agent-artifacts/step5-r2/R2-SHA256SUMS` |
| Re-review rounds | 2 of 5 completed; OracleB round 2 required one failed provider attempt and a successful fresh-lane retry on identical code |
| Round 2 (frozen r2) | Both lanes approve code and acceptance. OracleA closes S5-R1-STOP-PIN-ROLLBACK as fixed, not downgraded or waived; S5-R0-OWNERSHIP remains closed. OracleB's successful fresh-lane retry closes S5-R1-01 as fixed and resolves the digest clarification. Its new S5-R2-01 is a nonblocking P3, deferred. No P0/P1 remains open. Review records and failed-attempt provenance are below |

### Step 5 remediation r1 (2026-10-06, OD13)

Status: **reviewed in round 1 of 5 on the frozen r1 bytes; dispositions are in the Step 5 review index above, and r2 follows below. Not approved, accepted, staged or committed.** The text below is the r1 record as submitted; closures belong to the main-owned lanes. The parent is still HEAD `86e3e024`. The frozen r0 snapshot `.agent-artifacts/step5-review-r0/files/` is unchanged. r1 evidence is under `.agent-artifacts/step5-r1/`, and every result cited here is bound to `final/` and conductor `d5c18b76…`. Earlier r1 runs on `1679dae6…` differ only by one comment (`final/comment-only-delta-from-1679dae6.diff`). Invalid attempts are kept with READMEs.

**S5-R0-OWNERSHIP / S5-R0-01 (fix, not downgrade).** Each cancellation owner now pins its job for the whole operation and releases the pin in a `finally` after its last possible write. This follows the existing Step 5 pin design: the job can't be evicted while pinned, the last unpin reruns retention, writes are not skipped and no diagnostics are dropped.

- **`_cancel_running_job_locked`** pins on entry. Its body (pid wait, terminate, condition waits, kill, completion loop) runs in a `try`, and the `finally` unpins. Every early return and exception passes through that `finally`.
- **Supersession.** `_supersede_live_app_jobs_locked` pins the old running job before starting `_escalate_canceled_job_after_grace`, and passes the job to it. If `Thread.start()` raises, it unpins and re-raises. The escalation thread's whole body under `self.condition` sits in a `try`, with the unpin in its `finally`.
- **`stop(force=True)`** pins each running job before starting `_force_shutdown_when_canceled`. If the start fails, it unpins all of them and re-raises. The thread's loop under `self.condition` unpins in its `finally`, before the existing sleep and `server.shutdown`.
- **Reentrant waits.** `condition.wait` inside `_wait_for_process_tree_exit_locked` releases every recursion level of the `RLock`. While the owner is suspended there, `_run_job` can finish and drop its own pin, but this pin keeps the job retained. Inventory: no other caller of `_wait_for_process_tree_exit_locked` is unpinned. The `_run_job` callers hold the owner pin, the OD16 incomplete-reader path runs in `_run_job` or the pinned reader, `_terminate_xctest_stalled_job` runs in the pinned watchdog, and `_signal_stop` never waits.
- **Outcomes unchanged.** Job outcome (`canceled`/130), signal escalation and process cleanup are unchanged. Thread-start failures still propagate.

**Regression tests** (`Scripts/test_conductor_output.py`, `Step5OwnershipPinTests`). The three owner tests are deterministic, with no timing sleeps:

1. Run a real job with a real sleeping child.
2. Suspend the owner at its first condition wait, inside `_wait_for_process_tree_exit_locked`.
3. Let the real `_run_job` finish.
4. Force retention with `MAX_TERMINAL_JOBS`=0.
5. Require the pass to defer the job while the log still exists.
6. Resume and require the "SIGKILL after grace period" line.
7. Require eviction only after the owner's release, with no file left for the ticket.

They cover job cancel, supersession escalation and force-stop cleanup. Further S5-R0-02 tests:

- the watchdog thread and the timing-off summary thread stay pinned until they return;
- a real enqueue-minted ticket's log name and the real `_capture_xctest_stall_diagnostics` names (`<ticket>.xctest-stall.json`, `<ticket>.xctest-stall.sample.txt`) are accepted by the orphan predicate.

**Repro** (`repro/cancel_recreation_repro.py`; `repro/summary.txt` for r0/`1679dae6`, `final/repro/summary.txt` for `d5c18b76`). The repro suspends each owner and forces retention on a real `DaemonState`.

| Arm | Pins while the owner is suspended | Result |
|---|---|---|
| Frozen r0 | 0 | Evicted before resume, then the log was **recreated** after eviction, in all three owners |
| r1 | 1 | Eviction deferred; nothing left or recreated, in all three owners |

**C1/C2 (confirmation; no production change).** The grep on `d5c18b76` is in `final/c1c2-sites.txt`.

- **C1.** Tickets are minted only by `ticket = str(uuid.uuid4())` in `enqueue`, and the log path is `jobs_dir / f"{ticket}.log"`.
- **C2.** The only `xctest-stall` writers are `snapshot_path = jobs_dir / f"{job.ticket}.xctest-stall.json"` and `sample_path = … .xctest-stall.sample.txt` in `_capture_xctest_stall_diagnostics`. These are the only `diagnostic_paths.append` sites.
- **Timing sidecars.** `.timing-events.jsonl` and `.timings.json` come from the telemetry persister. `.runner-timings.json` reaches the runner through `RPCE_CONDUCTOR_RUNNER_TIMINGS_PATH`.
- **Other names.** Other `jobs_dir` names (`build-ticket-root.json`, `parallel-xctest-<run>*`) are not generated job families and are never touched.

**S5-R0-05.** The "uuid4" and "never delayed" wording above is corrected.

*Main's interpretation (not an owner waiver):* `RotatingJsonl` history rotation stays on its existing persisting thread, which already runs outside `self.condition`. The Step 5 requirement is no retention I/O under the scheduler lock, so no rotation-worker change is needed.

**Deferred:** S5-R0-03 (write-only `_maintenance_error`) and S5-R0-04 (a finished worker's `finally` clearing the busy flag), as minor P3s. No other cleanup was done.

**Validation** (`final/`):

- **Mutation** (`final/mutation/results.txt`): 0 survivors or invalid results out of 17. The unmutated control passes.
  - The frozen r0 `conductor.py` fails all three owner tests.
  - The new mutants are each killed by their intended test: M11 no cancel pin, M12 no supersession pin, M13 no force-stop pin, M14 unpinned watchdog, M15 unpinned summary thread.
  - M1–M10 are still killed.
- **Repeats.** 25 repeats of the Step 5 classes plus the two retention tests had 0 failures.
- **Affected suites.** 138 output tests and 171 lifecycle tests pass. The lifecycle file is unchanged since r0.
- **Gate 1, rerun on `d5c18b76` because the pins touch the cancel path.** Both the frozen probe and an r1 variant with one added running-job cancel recorded **0** retention scan/stat/unlink events under the scheduler lock. Outcomes are unchanged: the variant's running cancel is `canceled`/130. The pre-existing root build-ticket unlinks under the lock are 6 and 7, one per build job.
- **Gate 2, bounded rerun** (3 runs per scenario, not a campaign). Status and enqueue during the blocked cleanup have a worst case of 0.416 ms (limit 50 ms). All 640 files were removed and drained. Per-pass lock hold has a p50 of 0.017 ms.
- **Repository checks.** `make conductor-selftest`, `make guardrails`, `Scripts/check-agent-context` and `git diff --check`: logs and exit codes are in `final/tests/`.

### Step 5 remediation r2 (2026-10-06, OD13)

Status: **round 2 complete; both lanes approve code and acceptance. OracleA explicitly closed S5-R1-STOP-PIN-ROLLBACK as fixed; OracleB's fresh-lane retry closed S5-R1-01 as fixed. Accepted and committed as `6adf66a9`.** The parent is still HEAD `86e3e024`. The frozen r1 snapshot `.agent-artifacts/step5-review-r1/files/` is unchanged. r2 evidence is under `.agent-artifacts/step5-r2/`.

**S5-R1-STOP-PIN-ROLLBACK / S5-R1-01 (narrow fix).**

- **`stop()`.** One `try`/`except BaseException` now spans the whole interval from the first pin to the handoff. That covers the condition block, the per-job loop (queued processing and terminate for the first and later running jobs), the running-processes ledger write, the payload, and thread construction and start.
  - `handed_off` is set only after `Thread.start()` returns. From then on the force-shutdown thread alone releases the pins, in its `finally`, after its last write.
  - Before the handoff, any failure releases exactly the jobs this call pinned (`running_jobs`, appended right after each pin) under the condition, then re-raises. Another holder's pin is never released.
  - Propagation is preserved. No job state, `cancel_requested`, `shutdown_requested` or exit code is rewritten. A non-force stop and a force stop with no running job acquire no pin, so their paths are unchanged.
- **`_start_job_owned_thread`.** Thread construction moved inside the existing rollback `try`. It was the only remaining step between pin and handoff that the rollback did not cover.
- **Supersession.** Construction and start were already inside its rollback. No code changed; it now has tests.
- **Not changed:**
  - OracleB's optional S5-R1-02 refactor and the `_append_system_line_locked` guard are deferred.
  - The undispatched timing worker's start handler still catches `Exception` only, as in r0; it is not part of this finding.

**Tests** (`Step5PinHandoffRollbackTests`). These use synthetic jobs and no child processes, and inject a `BaseException` subclass so the fix can't rely on `except Exception`.

- **`stop(force=True)` setup.** The fixture is running R1, queued Q, running R2 (already holding another holder's pin) and running R3. Faults are injected at:
  - terminate of the first running job;
  - terminate of a later running job (a partial multi-job acquisition);
  - queued-job processing;
  - the ledger write;
  - payload construction;
  - thread construction;
  - thread start.

  Each test records the pins at the fault (proving they were acquired) and then requires the injected exception to propagate. Afterwards R1 and R3 must have 0 pins, R2 must keep exactly its other pin, and no retention deferral may be left behind. Outcomes already reached before the fault stay as they were.
- **Supersession escalation and `_start_job_owned_thread`.** Thread construction and start failures release only the caller's pin, keep the other holder's pin, and never run the target.

**Mutation** (`step5-r2/mutation/results.txt`): **24 executions (21 mutants, 2 frozen revisions, 1 control)**. All results are as expected: every mutant and frozen bad revision is rejected, and the control passes.

- The frozen r1 conductor fails exactly the five pre-handoff `stop()` faults and the owned-thread construction case. It passes the `stop()` and supersession thread construction/start tests, as expected, because r1 already rolled those back.
- The frozen r0 conductor fails all owner and rollback tests.
- New mutants, each killed by its intended tests:
  - M16: no `stop()` setup rollback;
  - M17: `handed_off` set before `start()`;
  - M18: rollback catches `Exception` only;
  - M19: no supersession start rollback;
  - M20: owned thread constructed outside the rollback;
  - M21: no owned-thread start rollback.
- M13's search text was re-indented to the new `stop()` body. M1–M15 are still killed.

**`conductorDigest` provenance (clarification; no new measurement).**

- **What it is.** `CONDUCTOR_DIGEST` is not a file SHA. It is computed once at module load by `compute_conductor_digest()`, which calls `swift_pipeline_metrics.content_digest()` over `conductor.py`, `swift_pipeline_metrics.py`, `debug_app_process.py` and `conductor_output.py`. The hash is `sha256(b"rpce-conductor-digest-v1\0" + for each file sorted by path: len(name)‖name‖len(bytes)‖bytes)`, with lengths as 8-byte big-endian.
- **Recomputed independently** (`step5-r2/digest/recompute_digest.py`, `digest-reconciliation.txt`):

  | Bytes | Composite digest | Matches |
  |---|---|---|
  | Exact r1 tested copies (`step5-r1/final/ab/candidate-tree`, `final/repro/r1final-scripts`) | `sha256:eb7b3db7…` | Every r1-final Gate 1/Gate 2 JSON; the module's own `CONDUCTOR_DIGEST` imported from that copy |
  | Frozen r1 `conductor.py` (`d5c18b76…`) with the HEAD helpers | `eb7b3db7…` | Same |
  | r1 before the comment edit (`1679dae6…`) | `178ea770…` | That run's JSONs |
  | r0 (`23c00ad4…`) | `e883b2ec…` | r0 JSONs |
  | Parent (`16b4e8fc…`) | `6ad9fb4f…` | Parent JSONs |

- **Helpers.** The three helpers are identical to HEAD (`c7bb7e3d…` `swift_pipeline_metrics.py`, `53875b77…` `debug_app_process.py`, `13db6f1f…` `conductor_output.py`).
- **Result.** No mismatch was found.

**Performance.** r2 changes no successful operation sequence. `stop()` and the owned-thread starter run the same calls in the same order inside a broader `try`, and `stop()` is on neither gate's measured path. The r1 gate evidence therefore carries over. As a bounded corroboration on r2 (`step5-r2/ab/`, digest `31e266f6…`), the frozen Gate 1 probe and the running-cancel variant both recorded **0** retention events under the lock. Outcomes were unchanged, and the root build-ticket unlinks were 6 and 7, as before. Gate 2 was not rerun.

**Validation** (`step5-r2/tests/`):

- 147 output tests and 171 lifecycle tests pass.
- 25 repeats of the Step 5 classes plus the two retention tests had 0 failures.
- `make conductor-selftest`, `make guardrails`, `Scripts/check-agent-context` and `git diff --check` exit codes are in `checks-exit.txt`.

### Step 5 round-2 outcome and recovered provider failure (2026-10-06)

Main verified both requested preset identities. OracleA completed initially; OracleB completed on a fresh-lane retry requested by the owner. Both reviewed the same frozen r2 code. This records two completed approvals, not an inference from the failed attempt.

- **OracleA:** approves the scoped r2 remediation, explicitly closes **S5-R1-STOP-PIN-ROLLBACK as fixed, not downgraded or waived**, retains the S5-R0-OWNERSHIP closure, and lifts this lane's Step 5 acceptance withholding. It resolves the composite-digest clarification and requests no further remediation or measurement campaign. Record: `prompt-exports/oracle-review-2026-10-06-210459-oraclea-step5-r2-for-e5a1.md`.
- **OracleB:** fresh round-2 chat `oracleb-step5-r2-force-p-39240B`, operation `82F186EB-178F-46C1-9B49-26EDC74C8D76`, failed with `oracle_stream_failed`. The provider reported that safeguards flagged the message, detail `[reasoning_extraction]`; export was skipped because the operation failed. This produces no code-review verdict. Its earlier r1 approval does not cover the r2 delta. That failed attempt was not counted as approval. The owner then explicitly requested rephrasing and a fresh lane. Main submitted a plainly worded code-review request for public conclusions and evidence, retaining the prior published findings verbatim and the same r1-to-r2 delta, evidence and OracleB preset; no substitute reviewer was used.
- **Frozen reviewed r2:** `.agent-artifacts/step5-review-r2/files/`, `R2-SHA256SUMS`, `r1-r2.patch`, `delta.patch`. Code hashes are conductor `735a0fa6…`, output tests `30e8a25a…`, lifecycle tests `10a69e6f…`. This outcome-only plan update postdates the snapshot; no code changed.
- **Main validation:** `make conductor-selftest` exited 0, including 147 output, 171 lifecycle, 74 benchmark and 67 metrics tests; `make guardrails`, `Scripts/check-agent-context` and `git diff --check` passed, with the existing route-count warning. Logs: `.agent-artifacts/step5-r2/{selftest-main,guardrails-main,context-main}.log`. All four source/plan hashes matched before and after validation. The unrelated tracked documentation diff matches the session-start capture.
- **Provenance:** main independently ran the supplied digest recomputation after inspecting its formula. Both the actual r1 test copy and frozen r1 plus unchanged helpers reproduce `eb7b3db7…`; current r2 reproduces `31e266f6…`. Evidence: `step5-r2/digest/main-recomputed.txt`. Gate 1 has r2 corroboration; Gate 2 remains carried-forward r1 evidence, not a new capture.
- **OracleB recovered outcome:** fresh chat `oracleb-step5-r2-retry-p-CF6035`, operation `24E63C60-BBA1-46E3-8940-8338FB56B669`, completed on the requested preset. It approves code and Step 5 acceptance, closes S5-R1-01 as fixed, preserves prior closures and confirms the digest binding. Record: `prompt-exports/oracle-review-2026-10-06-212511-oracleb-step5-r2-ret-68c7.md`.
- **Minor deferrals:** S5-R0-03 (maintenance error observability), S5-R0-04 (busy-flag finalization), S5-R1-02 (optional cancellation-owner helper refactor), and new S5-R2-01 (undispatched telemetry start rollback catches `Exception`, not `BaseException`) remain nonblocking P3s. The last is unchanged since r0 and was disclosed before r2; main defers it under the instruction not to loop on new minor findings. No code changed after the reviewed snapshot. The optional append guard and docstring refinement remain deferred.
- **Commit boundary:** both required reviews and Step 5 acceptance are complete. Stage only the four Step 5 files, run staged-index contribution preflight and commit before Step 6. These outcome/index and mutation-count wording changes implement the reviewers' recording recommendations; they change no code, contract or gate. Steps 6–12 had not started implementation at that point. All workers and validation processes finished; no Oracle operation remains pending. No Swift build, live-app or launchd validation was run for Step 5. *Outcome:* Step 5 is commit `6adf66a92b3ee02c1bd0c126f6d4023b245744e5`, the Step 6 parent.

### Step 6 implementation checkpoint (2026-10-06, OD13)

Status: **both initial lanes approve code; no P0/P1 findings. Owner-accepted for commit and progression under OD18; both round-1 lanes lift acceptance withholding. Contribution preflight passed and files are staged; two signed commit attempts failed in 1Password, so Step 6 is not committed and Step 7 implementation has not started.** The parent is HEAD `6adf66a9` (Step 5 commit). The median-improvement and p90 gates pass. **The 60 ms reference median misses: current reviewed bytes measure 72.317 / 72.474 ms (help / status).** The initial question timed out; the owner's explicit 2026-10-07 reply now authorizes acceptance under OD18 without pretending the reference target passed. Raw evidence is local under `.agent-artifacts/step6/`; it is not contribution material.

Implementation:

- **Entry** (`Scripts/conductor_entry.py`, new, mode 0755).
  - Loads `conductor.py` as module `rpce_conductor` through `spec_from_file_location` with an explicit `SourceFileLoader`, and registers it in `sys.modules` before `exec_module` (removed again if execution raises).
  - Calls `cli_main`, which is `main` plus the existing command-line exit mapping.
  - Sets `sys.argv[0]` to `conductor.py`, so argparse usage text is unchanged.
  - Direct `python3 Scripts/conductor.py` keeps working through the same `cli_main`.
- **Checked-hash bootstrap.** Before importing, the entry reads the 16-byte `.pyc` header (at `cache_from_source`) of `conductor.py` and of the three local modules it imports (U18: `debug_app_process`, `swift_pipeline_metrics`, `conductor_output`).
  - A header other than this interpreter's magic with flags `0b11` is recompiled once with `py_compile` in `CHECKED_HASH` mode, which writes atomically. That covers a missing, empty, truncated or garbage file, another interpreter's magic, an unchecked-hash pyc and a timestamp pyc. *(r1)* So is a body that does not unmarshal to a code object.
  - Each import then validates the source hash. A stale checked-hash pyc, such as one left after a same-size, same-mtime edit, is rejected by import and rewritten as checked-hash.
  - The check costs about 0.2 ms for headers alone, and about 0.9 ms with r1's body unmarshal.
- **Fallback.** It applies when a compile fails with `OSError` or `PyCompileError`, or when bytecode writes are disabled (`PYTHONDONTWRITEBYTECODE`) while any cache is not checked-hash.
  - The process sets `sys.pycache_prefix` to a fresh `mkdtemp` directory (`rpce-conductor-pycache-*`) and sets `sys.dont_write_bytecode`. An `atexit` handler removes the directory.
  - Valid checked-hash caches are still used when writes are disabled.
- **Routing.** `conductor_entry_script()` is used by `OperationRegistry.script_path` (job runners) and by `ensure_daemon`, with `sys.executable`. `ensure_daemon` is the only `spawn_daemon` caller, so this covers start, idle protocol-mismatch replacement, launchd `ProgramArguments` and direct spawn. The root `conductor` and `Scripts/run.sh` exec the entry with `python3` from `PATH`; interpreter selection and flags are unchanged.
- **Identity.** `verify_daemon_pid_identity` now calls `daemon_command_matches`.
  - An entry daemon's command must end with exactly ` <entry> __daemon --repo-root <root>`.
  - The interpreter path is not compared: live `ps` shows the Homebrew framework's re-executed `Python.app` binary, not `sys.executable`.
  - The legacy substring rule is unchanged for daemons started directly from `conductor.py` before Step 6. The metadata pid, repo and `processStart` checks are unchanged.
- **Digest.** `compute_conductor_digest` adds `conductor_entry.py`, so `conductorDigest` now covers five files and its values change.
- **Harness** (`Scripts/conductor_benchmark.py`, `HARNESS_VERSION` 7→8).
  - The entry is an optional target file; a parent without it keeps its byte digest.
  - Staging never precompiles `conductor.py` or the entry, so the parent never gets cached conductor bytecode.
  - The `runner` digest probe goes through the entry's `load_conductor` when the target has one.
  - The `targetLoading` text is updated, so v7 captures are not comparable with v8.
  - Workers still compile `conductor.py` from source for both arms; worker metrics never time module loading. The `cli` adapter (`launcher_subprocess@1`) is unchanged: it runs each target's own launcher.
- **Unchanged.** `.gitignore`: the existing `__pycache__/` rule already ignores `Scripts/__pycache__/` (U11: `git check-ignore`; `make guardrails` passes). A daemon that outlives an edit keeps its old code, as before; `conductorDigest` makes this visible.

Behavior changes for review:

- **Cache files.** `Scripts/__pycache__/{conductor,debug_app_process,swift_pipeline_metrics,conductor_output}.cpython-314.pyc` are written checked-hash. A test or direct `import conductor` may still write timestamp pycs; the next entry start replaces them.
- **Visible text.** Job logs' start line shows `…/conductor_entry.py __operation_runner …`. `conductorDigest` values change.
- **Fallback cost.** The fallback prefix is process-wide, so that rare path also compiles the standard library from source. It is slower, but correct.
- **Not covered.**
  - A body that unmarshals into a valid but altered code object can't be detected without a checksum, as in CPython. A body that fails to unmarshal is recovered in r1.
  - `--check-hash-based-pycs never` would disable validation; no launcher passes it.
  - The fallback prefix is not removed after `SIGKILL` or `os._exit`. The daemon's `SIGTERM`/`SIGINT` handlers stop normally, so `atexit` runs.

Gates and evidence for **superseded pre-body-check bytes** (not the current reviewed candidate; its `step6-cli-r2-body` results are below). Paired CLI-only captures `step6-cli-r0` and `step6-cli-r1` ran through `make dev-conductor-bench WORKLOADS=cli`, with no live daemon (a private, daemon-free state directory). Each had 30 pairs and 2 primers, completed with 0 errors, and was compared with profile `step6-launcher`.

| Gate | Parent `6adf66a9` (r0 / r1) | Candidate (r0 / r1) | Limit | Result |
|---|---|---|---|---|
| `cli.help_ms` median | 108.140 / 106.498 | 70.770 / 69.453 | ≥15 ms lower | pass: −37.27 (CI −38.23…−36.71) / −37.08 |
| `cli.status_ms` median | 108.694 / 106.927 | 70.717 / 69.619 | ≥15 ms lower | pass: −37.72 / −37.08 |
| p90 help / status | 110.650 / 109.804; 107.768 / 108.129 | 72.120 / 72.369; 71.148 / 71.529 | ≤ +10% and +10 ms | pass (decrease) |
| Reference median | — | about 70 | ≤60 ms | **miss** |

- **Comparisons.** The `make dev-conductor-bench-compare` path (no reference enforcement) is qualified, exit 0, for both captures. A direct `compare --enforce-reference-targets` is inconclusive, exit 2, for both, with `median … > reference target 60.0` for each metric. Gate semantics and thresholds are unchanged.
- **Host.** 28 cores; Python 3.14.7 (Homebrew framework), which is also the launcher's `cliPython`. load1 was 4.73–5.05 (r0) and 4.38–4.51 (r1). Foreign CPU was 3.47 / 3.20 cores in a single ≥10 s window (limit 4.0), with 0 samples while slots were held. 8 conductor daemons were resident. §2.2 recorded 92/93 ms for the smaller `fa43fe38` conductor; today's parent `6adf66a9` measures 106–109 ms.
- **Not gated.** Primers absorb the candidate's one-time bootstrap, so cold first-start cost is not gated.
- **Provenance.** Byte digests are parent `93681d60…` and candidate `a7e1352c…`. Loaded `conductorDigest` is parent `31e266f6…` (it matches Step 5 r2) and candidate `10e02459…`; the runner and daemon roles agree in both arms. Harness digest is `0e420cbc…`, with `conductor_benchmark.py` `e4e0937e…`. Frozen bytes were verified before and after both captures (`PARENT-`, `CANDIDATE-`, `HARNESS-SHA256SUMS`).
- **Reference-target analysis** (a bounded experiment; nothing adopted).
  - Approximate breakdown: 8 ms bash launcher; 18.5 ms interpreter and `site` (including Homebrew's `sitecustomize`, 3.5 ms); 25 ms of the conductor's module-level stdlib imports; 11 ms of conductor module execution (regex compiles about 3 ms, dataclasses about 2.5 ms, helper loads).
  - Launcher variants (40 interleaved runs): current 70.5 ms; pure-parameter bash dirname 67.6 ms; `/bin/sh` 64.8 ms; `python3` entry with no shell 61.8 ms.
  - No launcher shape that Step 6 owns reaches 60 ms. Closing the gap needs out-of-scope work: deferring the conductor's module-level imports, regexes and dataclasses, or interpreter flags such as `-S`. Neither is implemented. Evidence: `launcher-experiment.txt`.

Tests:

- **`Step6ConductorEntryTests`** (`Scripts/test_conductor_output.py`, 9 tests; 10 after r1):
  - `rpce_conductor` registration, loader and dataclass module, plus CLI parity with direct execution: help, `ConductorError` exit 1 and argparse usage naming `conductor.py`.
  - The root launcher bootstraps checked-hash bytecode once, and doesn't rewrite it on the next start.
  - A same-size, same-mtime edit runs new code, from both a timestamp and a checked-hash prior cache. The control shows that an ordinary import runs the stale code.
  - Missing, empty, truncated, garbage, other-interpreter, unchecked-hash and timestamp caches are recompiled.
  - An unwritable cache uses a fresh, empty, write-disabled prefix under `TMPDIR`, removed at exit; the stale cache is never used.
  - With `PYTHONDONTWRITEBYTECODE`, a stale cache is never used and a valid checked-hash cache is.
  - Eight concurrent first imports, released together through a stdin gate, all succeed and leave valid checked-hash files and no temporary files.
  - Runners, the launchd plist, direct spawn and `ensure_daemon` use the entry with `sys.executable`.
  - Exact entry identity and legacy direct identity.
- **Benchmark.** `test_cli_caches_conductor_only_through_a_targets_own_step6_entry` checks that a candidate target caches checked-hash conductor bytecode through its own launcher, a parent-shaped target never does, and the candidate's entry runner digest equals the worker digest.
- **Deliberate contract updates.**
  - The runner argv expectation (`test_parallel_test_cli_and_registry_construct_source_validating_job`) and the `run.sh` exec line now name the entry.
  - The `run.sh` fixtures copy the entry.
  - The digest test also perturbs `conductor_entry.py`.
  - The direct-execution exit-65 test is unchanged.

Validation (`.agent-artifacts/step6/`):

- **Mutation** (`mutation/results.txt`): 20 mutants, all killed by their intended tests; the control passes. They cover:
  - the bootstrap: none, timestamp mode, unchecked flags or magic, no prefix, writes enabled, no cleanup, stale cache with writes disabled;
  - the loader: registration after exec, `argv[0]`;
  - routing: runner and daemon paths, the root launcher;
  - identity: substring match, dropped legacy rule, legacy-only rule;
  - the exit mapping;
  - the harness: precompiling the conductor, unstaged entry;
  - digest coverage. The first run's digest mutant survived; the digest test was then strengthened.
- **Untested selection.** The runner-digest probe's choice between entry and `runpy` is informational and not mutation-discriminated.
- **Repeats.** 25 repeats of the Step 6 tests plus the digest and benchmark tests had 0 failures.
- **Live identity** (`identity/live-identity.json`). A scratch-copy daemon, with its own label and state, was started through the entry by direct spawn and by launchd. `verify_daemon_pid_identity` is true for both; the legacy rule alone would be false. Both were stopped, and the scratch launchd label is gone.
- **Repository checks.** `make conductor-selftest` exits 0 (12 suites, including 156 output, 171 lifecycle, 75 benchmark and 67 metrics tests). `make guardrails`, `Scripts/check-agent-context` (existing route-count warning), `Scripts/test-check-agent-context` (23 passed) and `git diff --check` all exit 0 (`tests/checks-exit.txt`).
- **Not run.** No Swift build, live app or real-checkout daemon restart.

Step 6 review index (main-owned, OD13):

| Item | State |
|---|---|
| Decisions relied on | OD13 (review policy), OD18 (measured acceptance; absolute target is nonblocking follow-up); Step 2 `conductorDigest` (informational, now covering the entry); §9 N3 (checked-hash, no enforcement or protocol bump) |
| Reviewed snapshot, both lanes | `.agent-artifacts/step6-review-r0/files/`, matching `.agent-artifacts/step6/r1/STEP6-CODE-R1-SHA256SUMS`; complete parent→candidate diff `r1/parent-to-candidate-code-r1.diff`. Entry `7a94bbf9…`, conductor `f6383265…`, output tests `9f165867…`, reviewed plan `7c4597bf…`. Later changes are this outcome/index correction only |
| Re-review rounds | 1 of 5; documentation/evidence round only, no code changes. The worker's pre-review implementation label r1 is not a review round |
| Open P0/P1 by lane | OracleA: none. OracleB: none; V1/V2 resolved by OracleB in round 1 |
| Initial review records | OracleA: `prompt-exports/oracle-review-2026-10-06-221223-oraclea-step6-initia-b329.md`. OracleB: `prompt-exports/oracle-review-2026-10-06-222807-oracleb-step6-initia-70aa.md`. Both preset identities verified |
| Owner acceptance | OD18 resolves the earlier timeout and accepts the measured gain for commit/progression. The 60 ms target still misses (72.317 / 72.474 ms); revisit startup cost in Step 12, without blocking this checkpoint or authorizing broader startup changes |
| Deferred | Earlier P3s unchanged: S5-R0-03/04, S5-R1-02, S5-R2-01. OracleA P2 S6-R0-DIGEST-FALLBACK and S6-R0-ENTRY-CLASSIFICATION; OracleB P2 S6-R0-01 and S6-R0-02; OracleB P3 S6-R0-04–07. Main records them below without opening a code-change round solely for nonblocking findings. OracleB closed S6-R0-03 as fixed in round 1. Entry-classification follow-up also covers validation-matrix and AGENTS path references, per OracleB's addition |
| Pre-review r1 | Corrupt-body cache recovery (below); candidate bytes `.agent-artifacts/step6/CANDIDATE-R1-SHA256SUMS`; code and plan hashes in `.agent-artifacts/step6/r1/STEP6-CODE-R1-SHA256SUMS` |

#### Step 6 r1: corrupt-body cache recovery (2026-10-06, before the initial review)

Main asked for coverage of a cache with a valid checked-hash header and a malformed body before the initial review. The r0 handoff had disclosed this gap. The r0 text above is the submitted record, apart from the factual corrections marked r1.

- **Reproduced on r0.** A pyc whose header matches the source hash but whose body is truncated failed `./conductor --help` with `EOFError: marshal data too short`. This happened for `conductor.py` (raised inside `exec_module`) and for helpers (raised while the conductor module was executing).
- **Fix.** `has_checked_hash_bytecode` now reads the whole file. Besides the header, it requires the body to unmarshal to a code object; `EOFError`, `ValueError`, `TypeError` or a non-code object count as malformed.
  - Malformed caches take the existing paths: recompile in checked-hash mode, or use the fresh empty prefix when the cache is unwritable or writes are disabled.
  - The check runs before any conductor code executes. No loader subclass, retry of module execution or broad exception handling was added, and runtime errors from the conductor still propagate unchanged.
  - The cost is one extra unmarshal of the four caches, about 0.9 ms per start (`conductor.py` 0.68 ms of it).
- **Tests.** New `test_valid_checked_hash_header_with_corrupt_body_is_recompiled` covers:
  - truncated, garbage and non-code bodies, for `conductor.py` (entry loader), `debug_app_process.py` (plain import) and `conductor_output.py` (explicit-path loader);
  - a control showing that an ordinary `import conductor` fails on each cache;
  - the recovered cache being checked-hash and loadable;
  - with an unwritable cache, the corrupt cache bypassed through the private prefix, left unchanged, with nothing left in `TMPDIR`.

  The existing other-interpreter, unchecked-hash and timestamp cases now keep the real body and hash, so each case isolates its own header field.
- **Mutation** (`r1/mutation-results.txt`): 22 mutants, all killed, and the control passes.
  - New: M21 (body not validated) and M22 (non-code body accepted).
  - M3/M4 search text follows the renamed variable.
  - The frozen r0 entry is rejected by the new test (10 failures).
  - The r0 `mutation/results.txt` is preserved.
- **Bounded re-measurement** (`step6-cli-r2-body`, parent `6adf66a9` against frozen `candidate-r1/`):
  - Medians: parent 108.266 / 108.636 ms, candidate 72.317 / 72.474 ms (help / status). The differences are −35.88 (CI −36.92…−35.22) and −36.15 ms.
  - p90 fell from 110.5 / 110.6 to 74.1 / 74.4 ms.
  - The make compare path qualifies (exit 0). With `--enforce-reference-targets` the result is inconclusive (exit 2), because 72.3 and 72.5 ms are above the 60 ms reference.
  - Conditions: load1 6.98–7.17, higher than r0/r1. Foreign CPU was 3.45 cores (limit 4.0), with 0 samples while slots were held.
  - Provenance: candidate byte digest `c1902755…`; loaded `conductorDigest` `115135a7…`, with runner and daemon roles equal; harness `0e420cbc…`, unchanged.
  - The r0/r1 captures and `candidate/` are preserved as their original bytes.
  - No import, lazy-loading, `-S` or shell change was attempted. The reference-target miss is for the owner's explicit decision; no waiver is assumed.
- **Validation** (`r1/`). `make conductor-selftest` exits 0, including 157 output tests. `make guardrails`, `Scripts/check-agent-context`, `Scripts/test-check-agent-context` (23 passed) and `git diff --check` all exit 0. 25 repeats had 0 failures.
- **Changed files.** Only `Scripts/conductor_entry.py` (`7a94bbf9…`) and `Scripts/test_conductor_output.py` changed.

#### Step 6 initial-review outcome and acceptance stop (main, 2026-10-06)

Both requested presets completed against identical frozen code. OracleA considers the code acceptable with nonblocking findings; OracleB approves code with no P0/P1. Both withhold acceptance on the unwaived 60 ms target (OracleA S6-R0-ACCEPTANCE-60MS; OracleB AE-S6-01). Main does not reinterpret a default comparison's exit 0 as passing the explicitly enforced target.

**Main validation:** `make conductor-selftest` passed all 12 suites, including 157 output, 171 lifecycle, 75 benchmark and 67 metrics tests. `make guardrails`, `Scripts/check-agent-context` (existing route-count warning), `Scripts/test-check-agent-context` (23 passed) and `git diff --check` passed. All ten candidate hashes matched. Logs are `step6/r1/selftest-main.log` and `guardrails-main.log`; the full context-negative result was observed in-session. No Swift build, visible-app operation, real-checkout daemon restart, staging, commit or Step 6 contribution preflight is claimed.

**Nonblocking dispositions, not downgrades:**
- OracleA S6-R0-DIGEST-FALLBACK (P2): with the optional metrics helper unavailable, the existing fallback hashes only conductor.py and misses entry-only changes. Informational provenance limitation; deferred.
- OracleA S6-R0-ENTRY-CLASSIFICATION / OracleB S6-R0-01 (P2): entry-only changes do not match the explicit preflight control-plane and optimizer broad-impact lists. Main confirmed `preflight.sh:101` and `test_suite_optimizer.py:62–70`. Current Step 6 validation ran explicitly and covers the entry; future entry-only selection remains a follow-up.
- OracleB S6-R0-02 (P2): rollback across the entry introduction can remove the running daemon's fixed runner path, and the old signal fallback cannot recognize its entry command. **Operator guidance:** stop the daemon with the current checkout's `./conductor daemon stop` before checking out a pre-Step-6 revision. No fallback architecture was added.
- OracleB S6-R0-03 (P3): current-byte medians, superseded-capture labels and required review-index fields are corrected in this outcome update. This is record correction, not a reviewer closure claim.
- OracleB S6-R0-04–07 (P3): entry docstring's absolute corruption claim, silent fallback/TMPDIR failure diagnostics, test fidelity/placement and module warning/metadata differences are deferred. The reviewed code is unchanged.

**OracleB V1/V2 evidence:** a scoped explore worker gathered evidence, not review judgments, under `.agent-artifacts/step6/evidence-v1v2/`. Main read the exact parent bodies and process-search output and spot-checked current production references.
- V1 searched hidden/ignored and untracked repository files, excluding Git/build/cache/generated-agent artifacts and dependency directories, with patterns for `conductor.py`, process-command consumers, `pgrep` and internal runner names. Full commands/scope and match lists are in the evidence handoff and `v1-*.txt`. The only production conductor-name matcher found is the updated daemon matcher; XCTest and descendant cleanup use executable/PID/start/ancestry/group ownership rather than conductor.py. Makefile and Finder route through the root wrapper; remaining direct execution references are compatibility tests or benchmark loading. No missed production matcher was found in this search.
- V2 uses parent `6adf66a9:Scripts/conductor.py`, materialized as `parent-conductor.py`; decisive bodies are `parent-exact-bodies.txt`. `cleanup_stale_files:1741–1747` returns while its recorded PID is alive. `ensure_daemon:6194–6240` tries RPC and refuses replacement after contact failure with a live PID, repeating the protection under the startup lock. `daemon stop:6724–6749` tries RPC first. `force_stop_unresponsive_daemon:6274–6308` rejects failed identity before any signal or metadata deletion. Thus identity mismatch alone does not remove the live daemon's files or start a duplicate. Actual socket/protocol state was not probed.
- These are supplied facts for the requested verification, not an additional Oracle verdict or closure. No P1 was raised in the initial review; V1/V2 are not silently treated as reviewer-confirmed.

**Historical stop, resolved 2026-10-07:** the required question initially timed out and Step 6 remained unstaged. The owner subsequently replied “do it” to main's explicit measured-acceptance recommendation. OD18 now accepts the roughly 36 ms gain and carries the missed 60 ms target as nonblocking follow-up. Main verified all nine code/test/launcher files still exactly match the initial reviewed snapshot; only decision/outcome documentation changed. Both fresh round-1 lanes completed on 2026-10-07, preserved their code approvals and lifted acceptance withholding under OD18, without calling the 60 ms target passed. OracleB explicitly resolved V1/V2 and closed S6-R0-03 as fixed. Records: `prompt-exports/oracle-review-2026-10-07-085300-oraclea-step6-r1-own-366d.md` and `prompt-exports/oracle-review-2026-10-07-085705-oracleb-step6-r1-v1-1fe7.md`; preset identities match the requested lanes. Main corrected the literal newline between OD18/OD13 (OracleA S6-R1-DECISION-ROW / OracleB S6-R1-01), labelled Step 12 placement as main's choice (S6-R1-02), and restored earlier P3 IDs (S6-R1-03). These are mechanical outcome-documentation corrections, locally checked; no new minor-finding review loop or code change. Optional search/helper-body completeness observations EG-1/EG-2 remain nonblocking. Contribution preflight passed before each signed commit attempt. Both attempts failed with `error: 1Password: failed to fill whole buffer` and `fatal: failed to write commit object`; HEAD remains `6adf66a92b3ee02c1bd0c126f6d4023b245744e5`. Signing was not disabled or reconfigured. The ten task-owned files remain staged and the nine code/test/launcher files match the reviewed snapshot. This is a signer blocker, not a remaining Step 6 acceptance decision. Step 7 implementation remains blocked by OD13's predecessor-commit rule. Its read-only scout and a main-owned narrow plan consultation are complete (`prompt-exports/oracle-plan-2026-10-07-085926-step7-narrow-integri-8b49.md`), but no implementation worker was started. No worker or Oracle operation is pending.
