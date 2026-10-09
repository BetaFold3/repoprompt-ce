# Review policy

Scope: read when the task touches planning or implementing plan steps, Oracle planning or review, or committing plan work.
Authority: Reference

Attach verbatim to every Oracle planning and review request. Only the owner edits this file; the repository's agent instructions (AGENTS.md or equivalent) override it. "You" means the main agent.

## Stakes (project-specific; the only section to edit per repository)
- Who depends on this work: solo owner, private fork; no other contributors or CI consumers.
- What is reversible: everything local, including local commits; pushes, releases and visible app lifecycle actions are not.
- Measurement conditions: shared, noisy host, so timing and size results are advisory.

## Rigor
Scale rigor to what a failure would cost under the Stakes:
- Internal and developer tooling: realistic breakage only. Failing loudly with clear recovery steps is a full remedy.
- Product behavior: correct in normal use.
- Data loss, security, or anything externally visible: full rigor.

## Findings
- P0: realistic data loss or security failure.
- P1: realistic failure in the project's actual use that loses data or results, gives a wrong answer, or breaks a workflow.
- P2: real defect that is unlikely or easy to work around. P3: improvement.
- Contrived inputs, hypothetical environments, and hardening the plan didn't ask for are P2 at most.
- Each finding: ID, failure scenario, impact, file:line evidence, and the smallest fix (removing the feature counts).
- Measured targets are advisory unless the Stakes or the owner make one a requirement. Unsound method (mismatched conditions, measuring the wrong thing, no comparable baseline) is a finding; missing or noisy numbers are not. The owner accepts results.

## Review loop
- Only you call Oracles. Initial review: OracleA and OracleB in fresh chats on the same diff, with the plan step, code context, and validation results. Neither lane sees the other's findings or your assessment.
- If a lane still fails after one retry, report it. Never substitute another reviewer.
- Fix P0/P1. Fix P2/P3 if cheap, else list them as deferred; never run a round just for them.
- You may downgrade or reject any finding with written reasoning. The issuing lane may contest once; if it still disagrees, the owner decides.
- Re-review: fresh chats for both lanes on the same snapshot, each given the delta, updated validation, and its own open, downgraded, or rejected P0/P1 verbatim with evidence and your disposition and reasoning. Scope: the fixes, regressions they caused, and contests; a lane with nothing open checks the delta for regressions only. New P2/P3 are listed, not looped on.
- At most 2 re-review rounds per step; then any remaining P0/P1 goes to the owner.
- Later edits: rerun affected validation; re-review only if reviewed behavior changed. Docs, plan, and status edits need no review.
- Save each lane's findings in the plan's evidence directory.

## Owner questions
- Ask with choices and your recommendation. If unanswered and the choice is reversible, proceed on your recommendation, record it under `assumed:`, and keep going.
- Only these wait for an answer, and they block only the dependent action: approvals required by the repository's agent instructions, credentials or manual actions, anything externally visible, contested P0s.
- Plan Decisions are owner answers only, one line each. Your interpretations and assumptions are not Decisions.

## Commit and status
- Commit when validation passes, required reviews are done, and no P0/P1 is open; a P1 contested to the owner may be committed and later steps may proceed, but that step stays `blocked` until the owner decides. Run the repository's pre-commit checks, stage only this step's hunks, read the whole staged diff, and don't push unless the task says to.
- Each step has one status line in the plan: `Step N — todo|doing|blocked|done | rounds n/2 | open: | downgraded: | assumed: | deferred:`
- Evidence lives in the plan's evidence directory, never in the plan; keep only what a status line or finding cites. Say how each result was obtained; never present a fixture or stub result as live. No credentials or tokens anywhere.
- When stopping, report what is blocked and why, the options, your recommendation, and what you continue with.
