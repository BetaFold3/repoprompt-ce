# Build pipeline and conductor performance plan (Swift build/test + Python conductor)

Scope: read when the task touches Swift build/test wall-time measurement, conductor per-job phase timing, the Swift or conductor benchmark harnesses, debug dSYM generation (`SWIFT_DRIVER_DSYMUTIL_EXEC`, `RPCE_DEBUG_DSYM`), the test-artifact fingerprint or its validation sites, conductor output handling, log summaries, the XCTest runtime-ledger cache, retention, the conductor launcher/bytecode, debug packaging Swift invocations, or diagnosis of slow test-module recompiles and the pre-test residual.
Authority: Reference
Last-verified: 2026-10-05

Status: Steps 1 and 2 are owner-accepted for commit and progression under OD12, which replaces the 5 ms parser budget with 90 ms per 5 MiB and accepts this checkpoint without further qualification runs. Phase 0 is complete (§11). Both OracleA and OracleB approve the scoped r4 implementation; all blocking code findings are closed by their owning lanes. Five shared re-review rounds were used, and no production or test code changed after r4. The Oracles' earlier withholding of empirical phase acceptance remains part of the record; OD12 is an owner decision, not a new Oracle verdict or a claim that missing measurements passed. Step 1's clean no-regression qualification, Step 2's full integrated/null-job qualification and repeatable Swift timing remain follow-up evidence, not blockers for this checkpoint. Steps 3–10 may proceed next in §4 order, with their own requirements unchanged. Steps 3–12 are not implemented and the debug dSYM policy is unchanged.
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
- **Tail.** 30 records and 64 KiB total; each displayed record is ANSI-stripped and capped at 4 KiB (OD7).
- **Summaries.**
  - `summarize_file` streams the raw log through the same splitter.
  - Each classification regex runs once per record, behind a casefolded keyword precheck that covers every regex alternative, with a fixture per alternative.
  - `SummarySectionBuilder.seen` is bounded to 4,096 entries per section. Behavior is exact before saturation; afterwards the summary exposes `deduplicationLimited` and `omittedLineCountQuality: exact | upper_bound`, and `SUMMARY_VERSION` goes from 1 to 2.
  - **Single-flight:** `summary_state: none | running | complete | failed` plus an event. The first caller claims the work under the lock and computes outside it. Racing callers join and honor their own deadlines. Every exception publishes a minimal error summary and releases the pin.

Gates (`dev-conductor-bench-compare` plus self-tests):

| Workload | Gate |
|---|---|
| Output, 0 waiters | CPU at least 50% lower; reference target ≤50 ms (now 142) |
| Output, 4 waiters | CPU and wall at least 75% lower; reference targets ≤100 ms CPU, ≤250 ms wall (now 2,001 / 961) |
| Lock behavior | p99 batch hold ≤5 ms, measured in separate profiled runs; no progress loss or reordering |
| Summary | CPU at least 35% lower on the fixed corpus; exactly one scan per completed log |
| Summary memory | Caps hold at 1M unique records; retained growth from 100k to 1M records under 1 MiB |
| Classification equivalence | Identical ordered `(kind, testName)` sequences against today's classifier over the fixture and retained logs. Allowed differences: events previously hidden behind bare `\r`, each listed explicitly |

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

1. **Idle exit and job-history review (OD6):** with 7 resident daemons, the Step 4 trigger is expected to fire. Should idle exit be planned then, or should daemons be stopped manually (`./conductor daemon stop` in idle worktrees)? Recommended: decide after the Step 4 footprint measurement.
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
