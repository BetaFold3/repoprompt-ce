# Agent-context doc gardening

Scope: read when the task touches a scheduled semantic-freshness review of agent guidance and routed durable knowledge.
Authority: Authoritative
Last-verified: 2026-07-30

Use this document as the complete maintenance prompt:

1. Run `Scripts/check-agent-context` from the repository root; fix every structural failure and review every warning.
2. Inspect routed `Authoritative` documents, starting under `docs/context/`; select a representative sample across different work classes and established document locations.
3. Verify each sampled claim against current code, tests, scripts, and CI. Don't infer freshness from a date; update `Last-verified:` only after confirming the document's decision-relevant claims.
4. Search for durable behavior changes that left routed guidance stale or incomplete. Update the single owning document; delete claims that are now wrong instead of appending contradictory corrections.
5. Inspect compatibility adapters, including [`CLAUDE.md`](../../../CLAUDE.md). Remove an adapter only after confirming its named consumer no longer loads it; otherwise leave it policy-free and pointed at the canonical source.
6. Re-run `Scripts/check-agent-context` and its negative suite, `Scripts/test-check-agent-context`.
7. Prepare a focused fix-up pull request, follow the [contribution workflow](../../../.agents/skills/rpce-contribution-check/SKILL.md), and report sampled documents, evidence checked, warnings resolved, and gaps left open.

Run this review monthly through scheduled CI, a scheduled agent task, or a maintainer checklist. The structural checker validates shape and reachability only; this review owns semantic correctness and freshness.
