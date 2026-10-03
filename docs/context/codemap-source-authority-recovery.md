# Codemap source-authority recovery

Scope: read when the task touches codemap Git source-authority evidence, typed issuance/revalidation failures, artifact or projection demand recovery, or `get_code_structure` authority-related issues.
Authority: Authoritative
Last-verified: 2026-10-03

Status: Implementation complete. OracleA and OracleB approved the scoped remediation in fresh re-review lanes on 2026-10-03; neither reported a P0/P1 defect. **Mandatory live acceptance remains pending.** The validation below is deterministic evidence, not proof of running-app behavior.

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

## Validation mapping and acceptance status

For future changes, use the [validation workflow](workflows/validation.md) and coordinated tests:

| Boundary | Focused validation | Reported implementation evidence |
|---|---|---|
| Directory churn (including timestamp churn inside both lookup→open and pre→post descriptor windows, with replacement controls), full file evidence, no-follow windows, resolve-only adoption, typed mismatch | `make dev-test FILTER=WorkspaceCodemapGitCapabilityServiceTests` | 25 tests green |
| Real-Git demand repair, retained-seed expansion, polling latch, store preload cancelled/no-backoff evidence, both budget orders, final-attempt typed unavailable, concurrency, old worker/ticket, cancellation/deadline, outcome-neutral rejection message | `make dev-test FILTER=MCPCodeStructureWorktreeTests` | 48 tests green |
| Engine lifecycle, projection, manifest compatibility, and warm-adoption authority drift (issuance short-circuit, batch revalidation, reservation/lease release, lazy re-adoption) | `make dev-test FILTER=CodemapBindingEngine` | 68 tests green |
| Adjacent store/presentation/preload/overlay/graph/automatic-selection boundaries | `make dev-test FILTER="'Codemap\|MCPCodeStructure'"` | 391 tests green in one run, including the rows above |

These results are handoff evidence from the initial-review remediation, not a full-root test result or live-app proof. The existing synthetic fresh-demand test is compatibility coverage, not proof of real-Git recovery.

**Gate 15 history:** retained-ready-seed `expand: referrers` after index advance originally failed with **47 restarts, zero repairs, and a 10-second timeout**. The approved extension plan chose foreground projection-ticket repair with a session latch, shared reset budget, and store ownership. That choice keeps one store-owned reset owner, keeps reset bounded per operation, and avoids an autonomous background invalidator; it was a planning decision, **not an implementation review**. The implemented regression `testReferrersExpansionFromRetainedSeedRecoversAfterIndexAdvance` asserts ready referrers output before 10 seconds, exactly one repair, a stale old seed ticket, and no additional repair on repeat; it is covered by the reported green MCP run.

**Outstanding — do not mark full acceptance complete:**

- OracleA and OracleB completed initial review and one fresh delta-scoped re-review. All targeted implementation findings were closed; nonblocking documentation precision issues were clarified without another review round. Optional minor test/helper and diagnostic refinements remain deferred.
- Post-remediation `make dev-build` passed (ticket `66c77a29-dbcd-4262-a6c0-a3d8d5c8dc6a`), including app/helper packaging checks. No visible app launch was authorized; packaging is not live acceptance.
- Record a live CE build revision matching the tested source, then exercise 20 consecutive Swift `get_code_structure` calls interleaved with `git status --porcelain`: structure returned, zero authority rejection issues, zero directory-churn repairs.
- Verify live `git add` and `git commit` each lead to one observed authority change and one repair, with later calls needing none.
- Run a live 60-second `git status` loop every two seconds with periodic structure calls; expect zero churn repairs.
- Verify a live multi-file request spanning `git add` succeeds after one reset or returns one bounded retryable authority issue without looping; confirm retained-seed expansion and idle-background behavior.
- Use live leaf diagnostics to confirm or refute the original running-binary failure mechanism.

Implementation completion and deterministic greens do not discharge these live gates. Raw working evidence remains local/untracked; the archived original plan preserves historical proposals, not current acceptance status.
