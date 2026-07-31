# Validation workflow

Scope: read when the task touches validation selection, tests, builds, style checks, smoke checks, release checks, or contribution evidence.
Authority: Authoritative
Last-verified: 2026-07-30

## Select evidence by changed boundary

Run the smallest coordinated check that can fail for the behavior you changed. Don't replace a focused verifier with a broad command unless the focused boundary is unavailable; add broader evidence only when the changed boundary requires it.

| Change boundary | Validation route |
|---|---|
| Agent guidance or `docs/context/` | Run `Scripts/check-agent-context` and `Scripts/test-check-agent-context`. |
| Repository/source layout or durable docs | Run `make guardrails`. |
| Swift behavior | Run `make dev-lint` and `make dev-test FILTER=<SuiteName>`; run `make dev-format` first only when formatting mutation is intended. |
| Root app product | Run `make dev-swift-build PRODUCT=RepoPrompt`. |
| MCP/shared protocol product | Run `make dev-swift-build PRODUCT=repoprompt-mcp`. |
| Provider package | Run `make dev-provider-test`; use `FILTER=<SuiteName>` for focused iteration. |
| Generated Xcode workspace boundary | Follow the [Xcode validation workflow](../../architecture/xcode-workspace.md). |
| Packaging, MCP CLI, Agent Mode, or running-app behavior | Run the smallest build/test above, then follow the live checks in [development](development.md). |
| Test executable inventory or optimization campaign | Follow [testing](../../testing.md); update the curated ledger surgically and never regenerate it. |
| Release metadata, packaging, signing, or promotion | Follow [releasing](../../releasing.md) and the [release skill](../../../.agents/skills/rpce-release/SKILL.md). |

`make dev-format` mutates first-party Swift files. Run it for intended Swift formatting; don't run it for documentation-only work or as a speculative repository-wide cleanup.

A live-only `make dev-smoke` is non-disruptive and requires an already-running CE debug app. A launch-required smoke or app run changes visible lifecycle state; follow the pinned approval rule in [`AGENTS.md`](../../../AGENTS.md).

## Preserve test quality

Don't weaken assertions, skip tests, or regenerate the curated XCTest ledger to make a change pass; fix the implementation or update a deliberately changed contract with focused evidence. Use the [test-quality skill](../../../.agents/skills/rpce-test-quality/SKILL.md) when the task centers on adding, consolidating, or removing tests.

## Prepare contribution evidence

Before a commit or push, follow the [contribution-check skill](../../../.agents/skills/rpce-contribution-check/SKILL.md) and its [validation matrix](../../../.agents/skills/rpce-contribution-check/references/validation-matrix.md). Stage only intended files and rerun commit preflight after any staging change.

Report the commands run, their result, and any relevant validation not run. A passing structural check establishes document structure and references only; it does not prove that guidance is semantically current.
