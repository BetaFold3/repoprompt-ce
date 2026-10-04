# Codemap source-authority recovery

Scope: read when the task touches codemap Git source-authority evidence, typed issuance/revalidation failures, artifact or projection demand recovery, or `get_code_structure` authority-related issues.
Authority: Authoritative
Last-verified: 2026-10-04

Status: The prior plan is implemented at HEAD `cf704272`. OracleA and OracleB completed initial review and fresh scoped re-review on 2026-10-03; neither reported a P0/P1 defect in that prior remediation. Later live evidence refuted acceptance. **Mandatory live acceptance FAILED on the old build and is pending on remediation.** The current delta passed initial review remediation and two fresh, delta-scoped OracleA/B re-review rounds on 2026-10-04. All P1 findings are explicitly closed; fresh-build live proof remains pending.

## Ownership and boundaries

- `WorkspaceCodemapGitCapabilityService.swift` owns repository evidence and authority resolution.
- `WorkspaceCodemapBindingEngine.swift` owns typed demand rejection, session currentness, projection admission/jobs, and the projection failure latch.
- `WorkspaceFileContextStore.swift` owns retained tickets, root sessions, synchronous detachment, and coalesced cleanup.
- `Presentation/WorkspaceCodemapPresentationCoordinator.swift` owns foreground operation resources, retry/reset budgets, and deadlines.
- `Models/WorkspaceCodemapArtifactDemandModels.swift` and `Models/WorkspaceCodemapProjectionPreloadModels.swift` define recovery mappings; `Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` projects issues without changing the MCP issue schema.

The workspace-context paths above are under `Sources/RepoPrompt/Infrastructure/WorkspaceContext/`. Code and tests establish current behavior. Do not add a second engine retirement owner, re-enable `.git` watcher events, remove index/metadata generations, or change unsupported-language/schema behavior as part of this recovery boundary.

## Evidence and adoption

Directory evidence is identity-only: `st_dev`, `st_ino`, and `st_mode`, with existing path/presence markers. Directory size, mtime, and ctime do not contribute to authority digests. Both directory-leaf descriptor windows (lookup→open and pre→post) compare identity, keyed on the observed `S_IFDIR` type, not the URL.

File leaves retain full stable-stat evidence (identity, size, mtime, ctime) and the existing bounded-contents policy. This includes linked-worktree `.git` pointer files, `commondir`, HEAD/refs, index, config, attributes, and sparse-checkout files; index contents are not newly read. Missing/present markers and independent index/metadata/configuration/attribute/sparse generations remain.

Preserved safeguards: `O_NOFOLLOW`, symlink rejection, descriptor-chain identity re-verification, `bindingIdentityDigest`, layout identity, and repository/worktree binding epochs. Replaced directory identities and changed pointer files are not treated as harmless timestamp churn.

Only normal `resolve → complete` adopts `StableAuthority` and advances its generation when evidence changes. `makeSourceAuthority` and `revalidateSourceAuthorities` observe and reject drift; they never adopt it. Existing authority-dependent manifests/projections revalidate normally after the digest change; do not migrate or rewrite tokens.

## Typed failures and comparison order

Issuance returns `issued(token)` or `unavailable(failure)`; batch revalidation returns `valid` or `invalid(failure)`. Both remain non-throwing.

| Failure leaf | Foreground artifact handling |
|---|---|
| `repositoryAuthorityChanged(changed:)` | `.repositoryAuthorityChanged → .resetRootSession` |
| `repositoryBindingChanged`, `repositoryLayoutChanged` | `.capabilityUnavailable → .resetRootSession` |
| `capabilityInactive`, `candidatePathRejected`, `candidateNotRegularFile`, `tokenInvalid` | `.sourceAuthorityUnavailable → .retryFreshDemand` |
| `unstableWindow(attributes / repository / pathFingerprint / capability)` | `.sourceAuthorityUnavailable → .retryFreshDemand` |
| `captureFailed(permissionDenied / transient)` | `.sourceAuthorityUnavailable → .retryFreshDemand` |
| `cancelled` | Existing cancellation path; no reset |

Changed-component names are `layout`, `index`, `checkout_configuration`, `attributes`, `sparse`, and `metadata`. Namespace, object-format, or binding-epoch mismatch is a binding failure rather than a non-binding component change.

**Return on the first baseline mismatch** is the implemented decision for issuance and batch revalidation. If the pre-capture matches the baseline, successful issuance/revalidation still requires the post-capture, attributes, path fingerprints, and active capability to remain stable. A later disagreement is window instability, not adopted authority.

Only capture's repository-layout/prefix failure maps to `repositoryLayoutChanged`. Descriptor-window races and traversal rejection must not all become reset triggers merely because their internal error is named `layoutChanged`. Source-expectation and artifact-token factory rejection remain separate downstream diagnostics.

All four engine consumers use typed results: foreground issuance, manifest issuance, projection candidates, and manifest batch revalidation. Root-wide manifest issuance failure stops remaining captures; root-wide drift found by batch revalidation closes the prepared adoption leases. Either way the adoption reservation is released and the manifest stays dirty for lazy re-adoption rather than updating authority. Only `.explicit` and `.background` demands adopt; `.demand` bypasses adoption. A later explicit/background demand on the replacement session retries adoption, and a manifest made stale by an index advance is a miss recovered from stored artifacts, not a rebuild.

## Store-owned foreground repair

The engine maps and returns a rejection; it does not invalidate a root from source-authority failure recording. The foreground coordinator claims recovery, then the store fences the ticket and performs:

`prepareCodemapRootSessionRetry / prepareCodemapProjectionRootSessionRetry → detachCodemapSession → shared cleanup → engine invalidation → re-registration → resolve → complete`.

Detachment removes the current store session and projection-demand records synchronously. Cleanup is coalesced per root ID. Seed recovery reissues sibling demands from the detached root. Existing registration generation and overlay `expectedAuthority` fences remain; do not relax them to make replacement setup succeed.

### Projection latch and ticket fencing

A root-wide failure observed by the current projection job latches `repositoryAuthorityChanged` or `capabilityUnavailable` on its eligible engine session. One synchronous transition fences job/session currentness, sets the latch, revokes demands with typed unavailable status, and cancels the matching job. An old worker cannot latch or cancel a replacement.

The latch lasts until normal session replacement. Scheduling, activation, polling, and completed-projection restart paths do not relaunch work against that session. **No autonomous background root reset or timer repair is introduced.** Background drift leaves projection idle until legitimate foreground recovery. A store preload launch that reaches a latched session finishes `cancelled` and is not retried; preload backoff retries only transient eligibility or retryable setup outcomes.

Foreground structure requests (`get_code_structure`) initiate bounded store reset preparation through the presentation coordinator. The production call sites for both reset-preparation methods are in that coordinator; this is not a guarantee that every presentation or selection caller enables recovery. No autonomous repair path is added to automatic selection or background preload. A non-recovering caller can remain unavailable until a foreground structure request or an existing session-replacement path repairs the root.

An otherwise valid admitted projection acquisition retains a ticket even when its status is the latched unavailable reason. The store caches the observed authority failure with the acquiring session/authority/engine, preserving it across polling while the record remains retained. Existing expiry/release limits still apply.

`prepareCodemapProjectionRootSessionRetry` requires the exact retained ticket, matching cached failure, a reset-capable reason, current session ID, acquisition authority and engine, loaded-root authority, and catalog/ingress generations. Cancellation and deadline are checked before mutation and after shared cleanup. Missing or detached old tickets return stale; root epoch/generations alone cannot authorize resetting a replacement.

### Shared operation budget and deadline

Seed and projection recovery share `WorkspaceCodemapDemandRecoveryState.resetRootEpochs`: **at most one root-session reset per operation per root epoch**, across structure attempts, with no separate projection allowance.

The budget is **claimed before the store validates the ticket**. A projection preparation that returns `stale` (for example, because a concurrent operation already replaced the session) still counts as this operation's reset and restarts the attempt like `prepared`. A seed preparation that returns no repaired result also keeps the claim and surfaces the ticket's refreshed status. Bounded duplicate work is preferred over a second reset by the same operation.

Projection-reset reasons are `repositoryAuthorityChanged` and `capabilityUnavailable`. A retained projection ticket may therefore trigger one bounded store reset for any cached `capabilityUnavailable` status: a latched binding/layout failure, or a ticket revoked or terminalized because the engine root is registered as unavailable. This matches the seed mapping (`.capabilityUnavailable → .resetRootSession`) and is intended; the shared budget and the store's ticket/session/authority/generation fences still apply.

A projection repair restarts the whole structure attempt through the existing bounded publication loop. Attempt ownership is released; all seeds, projection tickets, and graph inputs are rebuilt, not carried across detachment. The operation's original deadline is retained, not extended (the expansion regression gate is 10 seconds).

Preparation outcomes are `prepared`, `stale`, `deadlineReached`, and `cancelled`. Exhausted reset budget returns unavailable immediately with retry guidance, not another polling/restart loop. After preparation returns `prepared` or `stale`, if the outer loop cannot restart because no publication attempt or deadline remains, it returns `unavailable` with the typed `projection_unavailable` issue and retry delay rather than generic stale output. If the deadline expires during preparation itself, `.deadlineReached` produces the existing timeout result. Caller cancellation or timeout does not cancel shared cleanup.

## Diagnostics and privacy

The service logs only root identity, names-only failure leaf, and changed-component names. Engine events include `repositoryAuthorityChanged` and `sourceAuthorityTransientUnavailable`; the `repositoryAuthorityChanges` counter tracks root-wide observations, **not completed repair count**. Each consumer that observes the change records it independently. An explicit/background demand can count twice when both adoption and its own issuance observe drift; adoption can be skipped or shared by concurrent callers, so there is no unconditional per-request count. A `.demand` request bypasses adoption, and a projection worker records its own root-wide observation when latching. Count resets from invalidation diagnostics (or the DEBUG store repair count in tests), never from this counter. Existing invalidation diagnostics record cleanup separately. DEBUG `lastSourceAuthorityFailureForTesting(rootEpoch:)` retains one entry per root record and is cleared with release.

Never log source/metadata contents, absolute paths, ref/config values, fingerprints, evidence digests, or raw error text. MCP artifact rejection detail is `binding_rejected.repository_authority_changed`, retryable within the existing code/phase schema. Its message is outcome-neutral ("Repository authority changed; retry the request.") because the rejection does not establish whether a reset ran. Projection failure uses `projection_unavailable` / `projection`; exhausted-budget foreground output supplies retry guidance. A failure observation alone does not establish that a repair completed.

## 2026-10-04 follow-up: failed live acceptance and session provenance

**Mandatory live acceptance FAILED on the old build; remediation acceptance is pending.** The following reproduction/trace results are supplied follow-up evidence, not new runs by this documentation pass:

- `/tmp/rpce-codemap-e2e-20261004`: 62/62 main-repository directory/status calls returned ready. The small two-file control returned baseline referrers, then timed out after index advance; its unchanged repeat and subsequent commit request were stale. Directory-churn success did not prove authority-repair/expansion acceptance.
- `/private/tmp/rpce-codemap-authority-gk6e4aom`: durable-harness baseline against old-binary PID 38667 recorded 17 requests: 6 passed, 11 failed. The catalog-only baseline failed, so catalog mutation was **untested**. The earlier empty-commit run compared index bytes only; without full index-stat evidence it did **not** prove pure metadata-only drift.
- Conductor reproductions `b748040f-e8a5-435e-a9ea-28f7c0f4e361`, `031c6bb8-fe07-4fa6-9cdd-2dda916e54b6`, and `be91f38b-c718-4f33-a1c0-4c0d319e2e14` confirmed the mechanism: root reset reused the root epoch, a retained contribution watermark of 4 was compared with the replacement overlay's generation 3, the worker restarted completed projection, and same-key graph supersession left subsequent requests persistently stale. Temporary diagnostic probes were removed.

**Implemented delta invariant:** contribution generations are comparable only within their originating eligible engine session, not merely a reusable root epoch. The engine installs a fresh session-tagged observation alongside registration, maintains monotonic observations for that session, and removes them on invalidation/unload/shutdown. Observation/restart and successor preparation require the original `expectedSessionID`; snapshot root/catalog/repository authority is checked before feeding its observation. Store setup captures the engine projection session once and carries it through overlay observers and successor preparation; callbacks must not substitute whichever session is current later. Store observer-currentness fences apply before coverage wait/freeze after suspension. Worker-finish handling uses the job's own session, including advances observed while it was active.

This is a session-provenance change, not a new recovery owner or budget. Store-owned detachment/shared cleanup, foreground-only root repair, the shared once-per-root operation allowance, retained-ticket fencing, and the original deadline remain unchanged. These are targeted source spot-checks, **not a review verdict**.

## Review remediation outcome

Both current-delta initial reviews completed. OracleA reported three P1 **harness** findings: post-hoc write guarding, stale-process/new-bundle provenance, and engine-global counter isolation. OracleB reported no P0/P1 finding, with P2 counter-isolation, optional-lock probe contamination, and catalog-only coverage issues plus minor P3 items. Neither identified a blocking engine/store defect. OracleA explicitly closed all three in fresh round 1. That round identified P1 CR-04: interruption during final verification could persist a passing harness summary. Both Oracles explicitly closed CR-04 in fresh round 2 after the completion flag and interruption regression were added. Neither reported a remaining P0/P1; this is code-review closure, not live acceptance.

A deterministic catalog-only regression and a two-root counter-attribution regression now pass. OracleB's nil-setup, redundant-guard, and aggregate-fallback P3 items remain deferred, along with minor diagnostic/forensic refinements reported during re-review; they did not trigger additional review loops.

## Live authority harness

`Scripts/live_codemap_authority_e2e.py` is an explicit, isolated-fixture reproduction against an **already-running CE DEBUG app**, not the packaged-app release gate. Read its current `--help` before use; no remediation live pass is established. Dependencies: Python 3, Git, `gitleaks >= 8.19` with the `dir` command, `xcrun swiftc`, and CE debug CLI tooling.

```bash
python3 Scripts/live_codemap_authority_e2e.py --confirm-isolated-fixtures \
  --window-id <positive-window-id> --context-id <context-uuid> --app-pid <running-pid> \
  --churn --cadence --require-authority-counters
```

- Supply both routing IDs and an explicit PID; optional `--cli` must resolve to CE debug tooling. Every targeted call carries both IDs, including each newly created fixture's own context. Global read-only window discovery for new-fixture routing is a separately authorized exception, not permission to switch an existing workspace.
- The script creates only isolated fixture repositories/workspaces and retains raw evidence. Before dispatching an edit, it validates the absolute physical owned-fixture path and performs a read-only binding preflight; write protection is preventive, not merely a post-hoc check. It never launches/stops/relaunches the app, changes settings, switches existing workspaces, or mutates the product repository. Fixture/window creation requires the explicit fixture opt-in; cleanup is not automatic.
- It records/checks before-and-after PID/process, app/CLI hashes, debug-build provenance/hash, and harness/helper hashes. The process-start lower bound must be strictly later than provenance build time and executable mtime/ctime; same-second or newer-bundle evidence is rejected. This conservative minimum guard is not an OS executable-mapping hash. Record source/artifact provenance separately: a commit ID alone cannot identify dirty-at-build source bytes.
- First failures remain failures; later unchanged repeats do not erase them. Each query must return exact ready structure, empty issues/no retry, exact files and seed/related roles, relationship depth/direction, expected types/methods, and elapsed time **under 10 seconds CLI-inclusive** (startup, binding, server, transport). This conservative bound does not change the original server deadline. Structure-only success is explicitly distinct from authority acceptance.
- Five lanes separate index-only, catalog-only, metadata-only, settled combined, and original-overlap changes. A failed baseline blocks that lane's mutation coverage. Pure metadata-only classification requires changed HEAD with unchanged tree, index SHA, and full index stat, not byte equality alone.
- `--churn` adds 20 paired root/`.git` directory changes; observational Git/status probes are lock-free. `--cadence` adds a **lock-free** 60-second `git --no-optional-locks status` cadence every two seconds with periodic structure calls, explicitly **not ordinary/default-status acceptance proof**. The plain-status live gate remains separate. Directory identity/timestamp and unchanged Git evidence must be proven; sleep or elapsed time alone is not idle/background acceptance.
- `--require-authority-counters` implies required diagnostics and **fails closed** on unavailable/unvalidated root attribution. Strict root/epoch parsing is implemented and covered by negative tests. Success also requires completed post-run settings and build-identity verification; interruption records failure and re-raises rather than certifying incomplete evidence. Root-ID/lifetime and counter validity, Git OID/index SHA/full-stat transitions, exact root repair deltas, and idle controls must be established by actual snapshots, not inferred from structure-only success.
- The existing DEBUG gate `agent_mode.worktree_startup_benchmark_diagnostics_enabled` must be enabled **separately with explicit approval**, with its original value recorded and restored after the run, including failure. The script only reads it; `--diagnostics` and `--require-diagnostics` never enable it.

The existing DEBUG snapshot now exposes sibling `codemap_root_attribution` with `scope: root_epoch`, `root_id`, `root_lifetime_id`, and `root_capability_resolutions`, `root_repository_authority_changes`, `root_store_session_repairs`. Counts are cumulative for that root epoch across session resets, cleared on root release, and exclude other roots' activity. Engine-held fields are nullable when unavailable: missing/null attribution must fail closed, never become fallback zero evidence. Before/after comparisons must match the original root ID/lifetime, not merely a window or replacement session.

Existing `capability_resolutions` / `repository_authority_changes` remain engine-wide and `store_root_session_repairs` remains store-wide: **diagnostic-only aggregates, not acceptance counters**. Single-window/single-root inventory cannot prove shared-engine isolation. Never equate authority observations with repairs or infer repair counts from notices; use validated root-attributed snapshots.

## Validation mapping and acceptance status

For future changes, use the [validation workflow](workflows/validation.md) and coordinated tests:

| Boundary | Focused validation | Reported implementation evidence |
|---|---|---|
| Directory churn (including timestamp churn inside both lookup→open and pre→post descriptor windows, with replacement controls), full file evidence, no-follow windows, resolve-only adoption, typed mismatch | `make dev-test FILTER=WorkspaceCodemapGitCapabilityServiceTests` | 25 tests green |
| Real-Git demand repair, retained-seed expansion, polling latch, store preload cancelled/no-backoff evidence, both budget orders, final-attempt typed unavailable, concurrency, old worker/ticket, cancellation/deadline, outcome-neutral rejection message | `make dev-test FILTER=MCPCodeStructureWorktreeTests` | 48 tests green |
| Engine lifecycle, projection, manifest compatibility, and warm-adoption authority drift (issuance short-circuit, batch revalidation, reservation/lease release, lazy re-adoption) | `make dev-test FILTER=CodemapBindingEngine` | 68 tests green |
| Adjacent store/presentation/preload/overlay/graph/automatic-selection boundaries | `make dev-test FILTER="'Codemap\|MCPCodeStructure'"` | 391 tests green in one run, including the rows above |

These results are historical handoff evidence for the prior implementation at `cf704272`, not a full-root test result, current-delta review, or live-app proof. The existing synthetic fresh-demand test is compatibility coverage, not proof of real-Git recovery.

The orchestrator's 2026-10-04 log checks establish the following bounded **pre-review-remediation** evidence; this documentation pass did not rerun implementation tests, lint, format checks, ledger verification, or the live harness:

| Scope | Conductor ticket | Evidence |
|---|---|---|
| Red control: current three integration tests against HEAD production | `2840640e-9d38-419c-882b-560968481440` | 3 tests, 12 assertion failures; all stale |
| Focused repaired delta | `b6e53aa3-d4f3-487c-8b70-1f2aaf4f7471` | 11 tests, 0 failures (8 overlay + 3 new integration) |
| Broader scoped validation | `796f55ae-ff97-45ef-98e4-cb841c371f32` | 396 tests, 0 failures, 0 skipped |
| Strict suite with `RPCE_RUN_CODEMAP_E2E=1` | `bccc75d4-aa16-416e-a67f-acf8e6a77d2b` | 9 tests, 0 failures, 0 skipped; deterministic suite, not running-app acceptance |
| Lint | `e260437c-e0a0-4419-8226-1250fc5d4090` | Worker reported exit 0; orchestrator checked logs |
| Non-mutating format check | `f054eb4e-3ab5-45d8-b1bc-7754357fc6ac` | Worker reported exit 0; orchestrator checked logs |

Post-remediation validation: focused 13 tests passed (`01e3df4e-29c4-4bf8-bfe4-1f96d10b4ee5`); 398 boundary tests passed with no skips (`54f198aa-138b-4222-8fe6-4b198bef5140`); nine strict worktree-inheritance tests passed (`3133451c-0bda-41be-9f39-71d9aa92de82`). After fixing one `hoistTry` test-helper formatting finding, all 53 MCP worktree tests passed (`2fe9b5e7-1f78-4b70-b202-fd47166d82d7`); lint (`eb7326a2-7314-4d29-a81d-054559bc5ebd`) and format-check (`4cae592a-e7f6-4c8f-89c1-efe6e02efa64`) passed. The final Python-only interruption delta passed all 28 harness self-tests. No full-root run or engine-test failing-first run is claimed; the real-Git integration red control remains the causal regression evidence.

**Ledger verification is not green:** it fails on the pre-existing missing HEAD row `AgentDelegationPolicyTests/testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders`. The orchestrator checked the HEAD ledger's absence and the test's presence at HEAD line 1122. All seven new rows reconcile according to the worker's inventory check; the pre-existing omission remains unfixed and unwaived. Scoped test results do not establish live acceptance.

**Gate 15 history:** retained-ready-seed `expand: referrers` after index advance originally failed with **47 restarts, zero repairs, and a 10-second timeout**. The approved extension plan chose foreground projection-ticket repair with a session latch, shared reset budget, and store ownership. That choice keeps one store-owned reset owner, keeps reset bounded per operation, and avoids an autonomous background invalidator; it was a planning decision, **not an implementation review**. The implemented regression `testReferrersExpansionFromRetainedSeedRecoversAfterIndexAdvance` asserts ready referrers output before 10 seconds, exactly one repair, a stale old seed ticket, and no additional repair on repeat; it is covered by the reported green MCP run.

**Outstanding — do not mark full acceptance complete:**

- Historical OracleA/B initial review and re-review closed the prior targeted findings; documentation precision was clarified without another review round. Optional minor refinements were deferred. **Current-delta review remediation is closed after two fresh OracleA/B re-review rounds.** All P1 findings were explicitly closed; deferred minor observations remain recorded.
- Historical `make dev-build` ticket `66c77a29-dbcd-4262-a6c0-a3d8d5c8dc6a` passed app/helper packaging checks, not live acceptance. Build `dc89b734` predates review remediation. Current package build `afceb477-0d81-456e-a068-6fb60291406a` passed full signing, architecture, and embedded-helper checks. On 2026-10-04 the user chose to relaunch personally and approved temporary benchmark diagnostics with restoration afterward. Matched running-process/source identity is still required; the old-binary failures above cannot be replaced by a packaging result.
- Record a live CE build revision matching the tested source, then exercise 20 consecutive Swift `get_code_structure` calls interleaved with `git status --porcelain`: structure returned, zero authority rejection issues, zero directory-churn repairs.
- Verify settled live `git add` and `git commit` phases each lead to exactly one store-owned repair, with unchanged repeats needing none. Use root-attributed observations and repair deltas separately; there is no universal one-observation-per-repair rule. Prove full index-stat/SHA and tree stability before classifying an empty commit as metadata-only.
- Run a live 60-second `git status` loop every two seconds with periodic structure calls; expect zero churn repairs.
- Verify a live multi-file request spanning `git add` succeeds after one reset or returns one bounded retryable authority issue without looping; confirm retained-seed expansion and idle-background behavior.
- Use live leaf diagnostics to confirm or refute the original running-binary failure mechanism.

Prior implementation/review completion and deterministic greens do not discharge these live gates. **No remediation live pass is established.** Implementation validation, strict harness parsing, and OracleA/B review remediation are complete. Fresh-build live acceptance awaits the user's relaunch; full ledger verification remains blocked by the pre-existing missing row above. Raw working evidence remains local/untracked; the archived original plan preserves historical proposals, not current acceptance status.
