# Validation workflow

Scope: read when the task touches validation selection, tests, builds, style checks, smoke checks, release checks, or contribution evidence.
Authority: Authoritative
Last-verified: 2026-08-01

## Select evidence by changed boundary

Run the smallest coordinated check that can fail for the behavior you changed. Don't replace a focused verifier with a broad command unless the focused boundary is unavailable; add broader evidence only when the changed boundary requires it.

| Change boundary | Validation route |
|---|---|
| Agent guidance or `docs/context/` | Run `Scripts/check-agent-context` and `Scripts/test-check-agent-context`. |
| Repository/source layout or durable docs | Run `make guardrails`. |
| Swift behavior (iteration and focused validation) | Run `make dev-lint` and `make dev-test FILTER=<SuiteName>`; run `make dev-format` first only when formatting mutation is intended. |
| Swift behavior (instant re-run of an unchanged build) | Run `make dev-test-artifact FILTER=<SuiteName>`; its result is artifact-scoped and is never validation evidence for source edited after the recorded build ticket. |
| Root app product | Run `make dev-swift-build PRODUCT=RepoPrompt`. |
| MCP/shared protocol product | Run `make dev-swift-build PRODUCT=repoprompt-mcp`. |
| Provider package | Run `make dev-provider-test`; use `FILTER=<SuiteName>` for focused iteration. |
| Core package (`Packages/RepoPromptCore`: RepoPromptShared, RepoPromptMCPClientKit, RepoPromptMCPCore) | Run `make dev-core-test`; use `FILTER=<SuiteName>` for focused iteration. |
| Generated Xcode workspace boundary | Follow the [Xcode validation workflow](../../architecture/xcode-workspace.md). |
| Packaging, MCP CLI, Agent Mode, or running-app behavior | Run the smallest build/test above, then follow the live checks in [development](development.md). |
| Test executable inventory or optimization campaign | Follow [testing](../../testing.md); update the curated ledger surgically and never regenerate it. |
| Release metadata, packaging, signing, or promotion | Follow [releasing](../../releasing.md) and the [release skill](../../../.agents/skills/rpce-release/SKILL.md). |

`make dev-format` mutates first-party Swift files. Run it for intended Swift formatting; don't run it for documentation-only work or as a speculative repository-wide cleanup.

## Fast test-loop semantics

Coordinated test jobs enforce fail-fast and containment guarantees; treat these exit codes as their distinct meanings, not generic failures:

- **Exit 64** — the `FILTER` matched no curated-ledger entry and no source suite; the job never built. Fix the filter, or set `RPCE_ALLOW_UNKNOWN_FILTER=1` only for a genuinely new suite, then add its surgical ledger rows.
- **Exit 66** — the run succeeded but executed zero tests (stale ledger entry, regex mismatch, or config-gated suite). `RPCE_ALLOW_ZERO_TESTS=1` suppresses this only for intentionally gated runs.
- **Exit 70** — an XCTest phase deadline fired (startup, active-method, or between-method); this is hang containment with diagnostics, not a test failure. The active-method budget is ledger-derived (`max(90s, 4×runtime+30s)`; 180s when the method has no ledger runtime); `--xctest-stall-seconds` overrides only that active-method budget, and the startup and between-method bounds are fixed, so disable all deadlines with `REPOPROMPT_DEV_XCTEST_DEADLINES=0` only when a legitimately long startup or inter-case gap is expected.
- **Exit 65** — `dev-test-artifact` found missing, unreadable, or changed ticket/artifact state (no ticket, no bundle, or a bundle that no longer matches the ticket's fingerprint); run `make dev-test` first.

`make dev-test-artifact` re-runs the already-built test bundle in seconds. Every result carries an `artifact_scope`: `current` means the working tree matches the recorded build ticket; `stale` means it does not, and the summary states that current source was NOT validated. A stale-scoped pass never satisfies pre-commit or contribution evidence. A ticket is recorded only by a successful root `dev-test` whose source snapshot is available and stable across the run; a ticket from a filtered run attests tree↔ticket match only, never full-suite coverage.

`make dev-test-impacted` fails when a changed production path has no domain mapping; pass `--allow-unmapped` (via the optimizer CLI) only when the loud smoke-floor degradation is an accepted, explicit choice.

A live-only `make dev-smoke` is non-disruptive and requires an already-running CE debug app. A launch-required smoke or app run changes visible lifecycle state; follow the pinned approval rule in [`AGENTS.md`](../../../AGENTS.md).

## Preserve test quality

Don't weaken assertions, skip tests, or regenerate the curated XCTest ledger to make a change pass; fix the implementation or update a deliberately changed contract with focused evidence. Use the [test-quality skill](../../../.agents/skills/rpce-test-quality/SKILL.md) when the task centers on adding, consolidating, or removing tests.

## Prepare contribution evidence

Before a commit or push, follow the [contribution-check skill](../../../.agents/skills/rpce-contribution-check/SKILL.md) and its [validation matrix](../../../.agents/skills/rpce-contribution-check/references/validation-matrix.md). Stage only intended files and rerun commit preflight after any staging change.

Report the commands run, their result, and any relevant validation not run. A passing structural check establishes document structure and references only; it does not prove that guidance is semantically current.
