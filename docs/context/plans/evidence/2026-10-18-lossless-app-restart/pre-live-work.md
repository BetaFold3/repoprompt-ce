# Remaining lossless-restart work before live acceptance

Scope: read when the task touches the bounded remaining lossless-restart source work, its scope assumptions or pre-live blockers.
Authority: Reference
Last-verified: 2026-10-23

## Baseline and owner boundary

Baseline is signed commit ff475f0b10e1d0ecdd3246a86b05bde1f31dfc41. Step 4a same-ID saved-message relocation is complete in its reviewed inactive source scope. Original unrelated working-tree changes are excluded. The owner now asks to continue until all work is finished before final live verification. Main interprets that as including Phase 5's pending edit-review and delegated-child preservation requirements, not the explicitly later experiments, power-loss hardening, polish or retention. This interpretation is an assumption, not an owner Decision.

Production registry, Stop, fresh Claude identity, Resume/history and automated Restart remain OFF. O3 live acceptance remains pending. No provider/helper/MCP executable, packaging, visible app action, runtime-data/home/credential inspection or process signalling is authorized by this source work.

## Planning evidence and disposition

Main launched three read-only scoped probes, all completed: helper policy (54620065-BAE1-4CFB-8D8B-E52E45F38924), Claude identity (0EB7A5E9-3CA0-441F-912E-78ACC5AB9C65), remaining scope (DA199E7A-C11D-4B2B-BF62-5B6B96BC28D9). Summaries are claims; main directly checked the critical helper late-exit fixture, shutdown failure/Retry code, ledger/importer suppression, real edit preview/write path and routing-only RequestMetadata. The last two probes are being continued on narrower Phase 5 ownership questions.

Fresh OracleA and OracleB planning calls were submitted together with the same controlled source packet and full review policy, no shared selection or cross-lane responses. Both completed and returned the exact requested preset UUID/name: A 61D024A4-CCFB-4C9C-A614-CC65E0A1864C, B 7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C. Full responses: [A](pre-live-plan-oraclea.md), [B](pre-live-plan-oracleb.md). No OracleC was used. This is not another round of the capped original Phase 4 acceptance review.

Adopted common scope:
- Do not build a speculative Claude merge/provenance pipeline before authoritative identity and materialization evidence.
- Repair late exact-helper-stop recovery narrowly, without releasing choices while uncertainty remains.
- Finish the two Phase 5 preservation features using existing recovery/session ownership and normal dispatch.
- Validate and review each new behavioral scope independently; keep live evidence and full-contract blockers explicit.

Rejected planning details:
- B's fail-open persistence for edit reviews/child links would let display, writes or dispatch happen without preservation and contradicts the requested durable contract. Required commits must fail closed before those actions.
- A newly invented service UUID is not a substitute for the real invocation identity. Subsequent source reads establish that the existing MCP ingress UUID is the authoritative local execution ID; provider-native attribution is not required by this discovery contract. See the admission clarification below.
- Allowing duplicate live/native output as a general import policy would bypass the current canonical association preflight; do not weaken it.
- A plan-only source claim that Retry cannot spawn because its old budget is spent is contradicted by AgentLifecycleShutdownCoordinator.swift:827-837 and :873 onward. Existing explicit user Retry starts a fresh manual attempt with its own absolute deadline. Preserve that reviewed behavior; a late-stop notification itself must never renew a deadline or spawn/quit automatically. No blanket removal of existing manual retry semantics is selected.
- Old binaries discarding preservation records is not merely loss of optional hints. Keep the existing downgrade compatibility caveat explicit.

## Bounded work

### Step 4b: late stopped-helper proof

Current source leaves an ambiguous arm-sent failure unfinished even when exact-child exit is later observed. Existing AppRelaunchCoordinatorTests.swift:211-215 demonstrates that a subsequent abandonment can release that proof; the shutdown path does not subscribe. Add a narrow proof observation, preserve matching helper/request/attempt ownership, invalidate stale presentation answers, and restore normal Stage B choices only after proof. No polling, new persisted schema, new helper protocol, or automatic action. [Step 4b implementation and review](phase4b-helper-stop.md) and [worker evidence](phase4b-helper-stop-worker.md) record affected source, validation and dispositions. Main's initial context check found a premature link before that file existed; replacing it with non-link text made the check pass. The worker later found its new note orphaned; this completed link makes it reachable.

This cannot resolve the case where a potentially armed helper's stop remains unknowable. The original R4 failure-policy/activation blocker remains, and changing it requires an explicit owner contract choice. Keep fail-closed behavior meanwhile.

### Claude identity: evidence blocker, not another framework

Main's Sources search found nativeItems writes in the import planner plus model construction/decoding, and cursor commits in baseline/import paths plus their existing store/codec wrappers. The planner's known-key skip treats the ledger as completed import, not provisional identity. The app's canonical preflight refuses missing associations before planning. This is a bounded text search, not a whole-program proof.

Do not add tests that merely restate existing safeguards unless the trace finds missing regression coverage or a concrete defect. No speculative schema or algorithm is selected. [Existing investigation](phase4-source-investigations.md) gives the precise missing joins and acceptable external evidence. Full Claude canonical merge stays blocked; final live verification is not yet possible merely because this source packet is complete.

### Steps 5a and 5b: preservation

Two narrow continuations in the same OracleA planning chat completed on the inherited exact A preset. [Admission-bound linkage clarification](pre-live-admission-plan-oraclea.md) accepts the existing actual MCP invocation UUID plus a coherently captured/fenced admission-time parent attempt; no native provider-call correspondence or cross-request deduplication is claimed. A later request admitted under a new attempt belongs to that admission owner, rather than an inferred historical native origin. The source probe's initial demand for native identity was over-rigorous and is superseded by this local contract.

[Read-only review recovery clarification](pre-live-review-plan-oraclea.md) accepts View/Copy proposal/Discard only after restart. Recovered Apply is cut as an unnecessary additional feature: the written preservation contract does not require it. Persist exact proposed text and the fingerprint of preview's decoded base text (explicit decoded-text domain, not raw bytes); compare through the same host decoding on opening a historical card. Content matching is observation, not evidence the operation applied. No new conditional-write subsystem or raw fingerprint framework is selected. This is a reversible assumption, not an owner Decision; recovered mutation could be added later as a separate feature. Existing live mutation races are not claimed fixed.

Trace then implement pending edit-review proposals and agent_run invocation linkage. A proposal needs exact reconstruction, original-file evidence, commit-before-display, applicationStarted-before-write, lifecycle preserve versus explicit withdrawal, and historical actions that cannot resurrect old RPC/permission scopes. A child link needs authoritative admission-time parent session/incarnation/attempt and existing local MCP invocation identity, a durable child stub plus parent link before dispatch, and recovery discovery rather than automatic replay. Reuse existing stores, mutation paths and fences. Missing authoritative identity blocks only the dependent route.

## Maintainer-guidance check

User impact is avoiding lost proposals, missing delegated work and a permanent shutdown wedge after uncertainty ends. Source ownership is the existing recovery store/coordinator, canonical session owner, MCP dispatcher and relaunch driver; no parallel authority is selected. Persist before externally meaningful actions and fence every asynchronous continuation. Keep work bounded and observations event-driven. Fixtures validate conditional source behavior, never native identity or live acceptance.
