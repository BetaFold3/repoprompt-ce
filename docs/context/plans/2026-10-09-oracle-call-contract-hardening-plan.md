# Oracle call-contract hardening plan

Scope: read when the task touches `ask_oracle` `explicit_slices` slice validation, the advertised `ask_oracle` slice schema, or the wait/resume and slice recipes in the `ask_oracle` description.
Authority: Reference
Last-verified: 2026-10-09

Status: Step 1 done (commit cd71e8e2).
Step 1 — done | rounds 1/2 | open: none | downgraded: none | assumed: plan and evidence stay local and uncommitted; plan link added to the owner's uncommitted status paragraph in oracle-failure-inspection.md | deferred: OracleB R1-4 backstop index/1:1 test, R1-5 extra test proofs, R1-6 other parseSelectionMode rejections after reservation; Knowledge-profile description lacks recipes; pre-existing missing ledger row AgentDelegationPolicyTests/testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders

Evidence: `docs/plans/evidence/2026-10-09-oracle-call-contract-hardening/`.

## Goal

Agents waste turns on first `ask_oracle` calls, and malformed slices can silently drop requested review context (live probe, 2026-10-09: one valid and two malformed slices completed with only the valid file in context). Make malformed slices fail loudly before any consultation starts, and make the correct call shapes easy to copy.

## Step 1 — Reject malformed Oracle slices; publish copyable recipes

- Validate every `slices` entry before admission when `selection_mode:"explicit_slices"`: each needs a non-empty `path` and either a non-empty `ranges` array or a non-empty `lines` string. Reject the whole send, naming each bad entry (`slices[i]`), with a correct example. Line fields placed directly on the slice get a "move into ranges" hint. `manage_selection` parsing is unchanged.
- Advertised schema and description state the ranges-or-lines rule and give two recipes: a wait call with `operation_ids`, and a slice with `ranges`; a returned `resume` object is the complete next call.
- `op:"wait"` stays strict (send arguments still rejected).
- Validation: focused tests for path-only, misplaced line fields, mixed valid/invalid, empty `ranges`, and existing valid `ranges`/`lines` shapes (no provider start on rejection); tool-catalog snapshot; lint and format check; agent-context check.

## Decisions

- D1 (2026-10-09): Step 1 must also address the `op:"cancel"` + `consultations` rejection seen in another session.
