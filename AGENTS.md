# Agent Guidance

RepoPrompt CE is a Swift Package macOS app and agent orchestrator. Read only the documents routed below when the task matches; a small localized change usually needs none.

## Commands
- Environment: `make doctor`
- Build: `make dev-build`
- Test (all): `make dev-test` · Test (single): `make dev-test FILTER=<SuiteName>` · Test (instant artifact re-run, not source validation): `make dev-test-artifact FILTER=<SuiteName>` · Test (core package): `make dev-core-test`
- Lint: `make dev-lint` · Format Swift: `make dev-format`
- Run locally: `make dev-run`
- Repository guardrails: `make guardrails` · Agent-context structure: `Scripts/check-agent-context`
- Before commit: `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit`
- Before push: `.agents/skills/rpce-contribution-check/scripts/preflight.sh push`

## Invariants (pinned — apply always)
- Use coordinated `make dev-*` operations for builds, tests, style, packaging, and app lifecycle; use direct `make`, `swift`, or `./Scripts` fallbacks only when the daemon is unavailable or a routed workflow explicitly requires them.
- If conductor reports `global-wait`, wait on its ticket; don't start duplicate direct Swift/Xcode work.
- The Finder launcher requires Python 3 and does not provide an uncoordinated no-Python fallback; use the coordinated launcher with Python 3 instead.
- Obtain explicit user approval immediately before any force-push, history rewrite, branch or fork deletion, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app. Don't treat earlier task authorization as this approval; ask at the action boundary.
- Read the [contribution-check skill](.agents/skills/rpce-contribution-check/SKILL.md) before every commit or push. Stage only intended files and rerun commit preflight after every staging change.
- Don't stage or merge local `docs/investigations/*.md` reports unless intentionally requested; keep raw working evidence local instead.
- Don't use production `rp-cli` or `rp-cli-debug` to validate CE; use `rpce-cli-debug` instead.
- Don't run `make dev-format` unless Swift formatting mutation is intended; use `make dev-format-check` for a non-mutating check.
- Don't change release metadata, signing identities, bundle IDs, Sparkle keys, or release channels unless a maintainer explicitly requests it; follow the release workflow instead.
- Don't weaken assertions, skip tests, or overwrite the curated XCTest ledger to make a change pass; fix the implementation or deliberately update the changed contract.

## Decision rules
| Situation | Use |
|---|---|
| Choose local build, test, style, package, CLI, or lifecycle behavior | [development workflow](docs/context/workflows/development.md) |
| Choose verification for a changed boundary | [validation workflow](docs/context/workflows/validation.md) |
| Place or move source/test files | [source layout](docs/architecture/source-layout.md) and `make guardrails` |

## Context routes
| Task touches | Paths | Read | Purpose |
|---|---|---|---|
| Local development, conductor, debug app, or CE CLI | `Makefile`, `conductor`, `Scripts/**` | [development](docs/context/workflows/development.md) | coordinated operations and debug tooling |
| Validation choice or contribution evidence | any changed boundary | [validation](docs/context/workflows/validation.md) | smallest relevant checks and handoff evidence |
| Test design, XCTest inventory, or optimization | `Tests/**`, `docs/test-suite-optimizer/**` | [testing](docs/testing.md) | test contracts, ledger, and campaign rules |
| Source ownership or generated workspace | `Sources/**`, `Tests/**`, `Package.swift` | [source layout](docs/architecture/source-layout.md) | target and directory ownership |
| Agent provider implementation | `Packages/RepoPromptAgentProviders/**`, `Sources/RepoPrompt/Features/AgentMode/**` | [provider plugins](docs/architecture/provider-plugins.md) | provider seam and validation |
| Xcode workspace generation | `Scripts/generate_xcode_workspace.py`, `.github/workflows/xcode-workspace.yml` | [Xcode workspace](docs/architecture/xcode-workspace.md) | disposable workspace boundaries |
| Worktree creation or local-file copying | worktree APIs, `.worktreeinclude` | [worktrees](docs/worktrees.md) | copy and safety semantics |
| Release, signing, packaging, or update channels | `version.env`, `AppBundle/**`, `Scripts/release*`, release workflows | [releasing](docs/releasing.md) and [readiness](docs/open-source-readiness.md) | maintainer-owned release process |
| Issues, pull requests, commits, or pushes | `.github/**`, Git-visible operations | [contributing](CONTRIBUTING.md) and [contribution check](.agents/skills/rpce-contribution-check/SKILL.md) | contribution and safety gates |
| Agent-context maintenance | `AGENTS.md`, `CLAUDE.md`, `docs/context/**` | [doc gardening](docs/context/workflows/doc-gardening.md) | semantic freshness review |
| Quick model picker or quick handoff shortcut work | `Sources/RepoPrompt/Features/AgentMode/**` | [quick model/handoff HUD](docs/context/quick-model-picker-and-handoff-hud.md) | implemented shortcuts, HUD, model selection, and handoff invariants |
| Oh My Pi (OMP) ACP provider integration or managed ACP harness work | `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/**`, `Sources/RepoPrompt/Features/AgentMode/Providers/ACP/**` | [OMP provider plan](docs/context/plans/omp-provider-integration.md) | duel-settled managed ACP harness plan and invariants |

## Sources of truth
Code and tests establish current behavior; `Authoritative` documents and explicit user requirements establish intended behavior. When they conflict, don't silently choose one; resolve within scope or report the conflict.

## Completion
Before finishing, run the smallest validation covering the change, report what ran and what did not, and check whether the change invalidated a routed document.

## Context maintenance
When a change alters a durable fact used to plan, implement, or validate future work, update the single owning routed document; use `docs/context/` for new agent-specific knowledge, delete stale claims instead of duplicating them, then run `Scripts/check-agent-context`.
When a context plan completes, move its original intact to `docs/context/plans/completed/`, prepend a short outcome and decision summary, and distill durable decisions into the owning context document. Don't route or read completed plans, generated references, or archives unless the user explicitly asks; use active routed documents instead.
