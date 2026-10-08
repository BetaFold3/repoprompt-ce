# Validation workflow

Scope: read when the task touches validation selection, tests, builds, style checks, smoke checks, release checks, or contribution evidence.
Authority: Authoritative
Last-verified: 2026-08-08

## Select evidence by changed boundary

Run the smallest coordinated check that can fail for the behavior you changed. Don't replace a focused verifier with a broad command unless the focused boundary is unavailable; add broader evidence only when the changed boundary requires it.

| Change boundary | Validation route |
|---|---|
| Agent guidance or `docs/context/` | Run `Scripts/check-agent-context` and `Scripts/test-check-agent-context`. |
| Repository/source layout or durable docs | Run `make guardrails`. |
| Canonical Swift environment, debug dSYM helpers or conductor symbol operations | Run `make conductor-selftest` and focused policy/regeneration tests. For policy/toolchain rollout, record an off-mode test-breakpoint/local-value and actual-crash symbolication before/after in-place `dev-dsym`, ten alternating same-tree test-edit runs per mode with off faster, reported null medians (flag off >0.5 s slower), and one default-off `make dev-build` plus `make dev-test`. Disclose any test filter and crash return-address adjustment. See [debug symbols](development.md#debug-symbols) for the qualified behavior and rollback. Automated C1–C5, fine-client A/A, calibration, bootstrap and thermal gates are not required by the owner's lean contract. |
| Swift behavior (iteration and focused validation) | Run `make dev-lint` and `make dev-test FILTER=<SuiteName>`; run `make dev-format` first only when formatting mutation is intended. |
| Swift behavior (instant re-run of an unchanged build) | Run `make dev-test-artifact FILTER=<SuiteName>`; its result is artifact-scoped and is never validation evidence for source edited after the recorded build ticket. |
| Full root contribution evidence | Run unfiltered `make dev-test-parallel`; it builds tests from a stable source snapshot, runs the parallel root bundle, and fails closed on post-run source/toolchain/artifact drift. The acceptance gate passed on 2026-08-07 (10/10 greens, p90 about 194s). Any `FILTER` is filtered evidence only; serial `make dev-test` remains the supported fallback. |
| Root app product | Run `make dev-swift-build PRODUCT=RepoPrompt`. |
| MCP/shared protocol product | Run `make dev-swift-build PRODUCT=repoprompt-mcp`. |
| Provider package | Run `make dev-provider-test`; use `FILTER=<SuiteName>` for focused iteration. |
| Core package (`Packages/RepoPromptCore`: RepoPromptShared, RepoPromptMCPClientKit, RepoPromptMCPCore) | Run `make dev-core-test`; use `FILTER=<SuiteName>` for focused iteration. |
| Generated Xcode workspace boundary | Follow the [Xcode validation workflow](../../architecture/xcode-workspace.md). |
| Packaging, MCP CLI, Agent Mode, or running-app behavior | Run the smallest build/test above, then follow the live checks in [development](development.md). |
| Test executable inventory or optimization campaign | Follow [testing](../../testing.md); update the curated ledger surgically and never regenerate it. |
| Release metadata, packaging, signing, or promotion | Follow [releasing](../../releasing.md) and the [release skill](../../../.agents/skills/rpce-release/SKILL.md). |
| Agent Mode provider usage/cost accounting, worker wait policy, or `agent_run` response presentation | Follow the [usage accounting and wait efficiency plan](../plans/2026-09-13-agent-usage-and-wait-efficiency-plan.md); its §8 lists the deterministic suites and the G1–G3 runtime gates. |
| `ask_oracle` resumable waits, batch admission/FIFO scheduling, operation ownership/cancellation, steering wake, captured source identity, advisory progress hints, or pending/queued cards | Follow the [Oracle resumable wait plan](../plans/2026-09-21-oracle-resumable-wait-plan.md) §5: focused store, lifecycle, deterministic batch-scheduling, production-drain, worktree/source-capture, pill/card/DTO, schema, and unchanged finalisation-hub coverage. Prove the 1…16 lane and 32-nonterminal bounds, actual two-stream occupancy, no-spend pre-bind cancellation, same-session rotation, stable indexes, connection-independent startup, and omitted-ID recovery beyond 16 with deterministic fences rather than sleeps. For progress hints, prove sampled output character count and observed activity age from existing query state, FIFO-derived zero-based queue position, optional old-result decoding, terminal/unsupported-state omission, the byte ceiling, no text/reasoning leakage or per-token operation-store publication, and presentation with no completion/failure/stall/provider/cache/TTL inference. Run `make dev-core-test`, both `make dev-swift-build` products, and `make dev-build` for a packageable debug artifact; packaging does not install, launch, or prove live behavior. Claude Code and Codex live steering/batch checks, relaunch recovery, and cache measurement are separate release gates, not established by deterministic tests. |

`make dev-format` mutates first-party Swift files. Run it for intended Swift formatting; don't run it for documentation-only work or as a speculative repository-wide cleanup.

## Fast test-loop semantics

Coordinated test jobs enforce fail-fast and containment guarantees; treat these exit codes as their distinct meanings, not generic failures:

- **Exit 64** — the `FILTER` matched no curated-ledger entry and no source suite; the job never built. Fix the filter, or set `RPCE_ALLOW_UNKNOWN_FILTER=1` only for a genuinely new suite, then add its surgical ledger rows.
- **Exit 66** — the run succeeded but executed zero tests (stale ledger entry, regex mismatch, or config-gated suite). `RPCE_ALLOW_ZERO_TESTS=1` suppresses this only for intentionally gated runs.
- **Exit 70** — an XCTest phase deadline fired (startup, active-method, or between-method); this is hang containment with diagnostics, not a test failure. The active-method budget is ledger-derived (`max(90s, 4×runtime+30s)`; 180s when the method has no ledger runtime); `--xctest-stall-seconds` overrides only that active-method budget, and the startup and between-method bounds are fixed, so disable all deadlines with `REPOPROMPT_DEV_XCTEST_DEADLINES=0` only when a legitimately long startup or inter-case gap is expected.
- **Exit 65** — `dev-test-artifact` found missing, unreadable, or changed ticket/artifact state (no ticket, no bundle, a bundle that no longer matches the ticket's fingerprint, or an artifact that changed while being validated or before launch); run a successful root serial or parallel test first. A ticket with a malformed, future or inconsistent version, or one that predates fingerprint v2 (`ticket predates fingerprint v2 — re-mint with a source-validating run`), fails 65 before any hashing or launch; nothing is upgraded in place. After a conductor code-version transition in either direction (upgrade or rollback), first stop the idle daemon with `make dev-daemon-stop`, then re-mint with a source-validating run. The daemon mints and evaluates tickets with the code it loaded at start, so a daemon that predates the transition can mint evidence the current client rejects. The failure is not guaranteed: after a rollback, a daemon still running the newer code can keep minting and serially evaluating with the newer semantics without any 65 or 67, so the restart is required even when nothing fails. The stop refuses while jobs are active or queued; do not force it or stop the app. An otherwise successful run whose artifact bytes changed during the run, or whose post-run artifact is unreadable or unstable while being re-fingerprinted (scope difference `post-run artifact integrity unavailable`), also fails 65; an earlier failure, timeout, or cancellation keeps its own outcome.
- **Exit 67** — `dev-test-parallel` could not prove stable source/artifact provenance: a source snapshot, candidate manifest, environment/toolchain check, artifact path, or artifact fingerprint was missing, invalid, or changed, or the candidate's version envelope is malformed, future, inconsistent or predates fingerprint v2. The old root ticket remains invalidated. After a conductor code-version transition in either direction, the same idle-daemon `make dev-daemon-stop` precedes the re-run. The candidate is written by a runner child on the current code but read by the daemon's start-time code.

`make dev-test-artifact` retains artifact-only semantics and re-runs the already-built test bundle in seconds. Every result carries an `artifact_scope`: `current` means the working tree matches the recorded build ticket; `stale` means it does not, and the summary states that current source was NOT validated; `pending` means execution-time evaluation never completed (for example, the job failed or was canceled first) and is never validation evidence. A stale-scoped pass never satisfies contribution evidence. Successful stable root serial and parallel runs record compatible tickets that attest source/environment/toolchain↔artifact provenance only, never full-suite coverage. For contribution evidence, only an unfiltered green `make dev-test-parallel` is the full-root lane; a filtered parallel or serial result remains focused evidence.

`make dev-test-impacted` fails when a changed production path has no domain mapping; pass `--allow-unmapped` (via the optimizer CLI) only when the loud smoke-floor degradation is an accepted, explicit choice.

A live-only `make dev-smoke` is non-disruptive and requires an already-running CE debug app. A launch-required smoke or app run changes visible lifecycle state; follow the pinned approval rule in [`AGENTS.md`](../../../AGENTS.md).

## Preserve test quality

Don't weaken assertions, skip tests, or regenerate the curated XCTest ledger to make a change pass; fix the implementation or update a deliberately changed contract with focused evidence. Use the [test-quality skill](../../../.agents/skills/rpce-test-quality/SKILL.md) when the task centers on adding, consolidating, or removing tests.

## Prepare contribution evidence

Before a commit or push, follow the [contribution-check skill](../../../.agents/skills/rpce-contribution-check/SKILL.md) and its [validation matrix](../../../.agents/skills/rpce-contribution-check/references/validation-matrix.md). Stage only intended files and rerun commit preflight after any staging change.

Report the commands run, their result, and any relevant validation not run. A passing structural check establishes document structure and references only; it does not prove that guidance is semantically current.
