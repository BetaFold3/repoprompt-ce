> **Implementation outcome — 2026-10-03:** Implementation complete; OracleA and OracleB approved the implementation/remediation after one fresh delta-scoped re-review, with no P0/P1 findings. **Live acceptance remains pending.** Archival here means completed implementation, not verified live acceptance.
>
> Decisions implemented: identity-only directory evidence with full file evidence/no-follow preserved; typed failure leaves; early baseline-mismatch return; resolve-only authority adoption; store-owned foreground repair. Projection authority failure is latched per session, with no autonomous background reset. Foreground projection tickets use the same once-per-root operation budget, ticket/session fences, and original deadline as seed recovery.
>
> Gate 15 originally failed with 47 restarts, zero repairs, and a 10-second timeout. The resolved design uses foreground projection-ticket repair, preserving one store-owned lifecycle instead of autonomous background reset. Post-remediation validation passed all 391 tests matching `Codemap|MCPCodeStructure`, including service 25, MCP 48, and engine 68; the debug package build also passed. These results do not establish live behavior.
>
> Current durable guidance: [Codemap source-authority recovery](../../codemap-source-authority-recovery.md). Live build/revision, churn, add/commit, multi-file and expansion acceptance remain outstanding. **Do not mark full acceptance complete.** The original plan below is preserved intact; its proposed status and open alternatives are historical.

---

# Codemap source-authority recovery plan (`get_code_structure` `source_authority_unavailable`)

Scope: read when the task touches codemap Git source authority, `WorkspaceCodemapGitCapabilityService` authority evidence, `makeSourceAuthority`/`revalidateSourceAuthorities`, codemap demand rejection recovery, or `get_code_structure` `binding_rejected.*` issues.
Authority: Reference
Last-verified: 2026-10-03

Status: Proposed. Not implemented. No production or test code has changed.
Decision process: two independent Oracle lanes (OracleE and OracleD) received the same brief with verified file:line evidence. Material disagreements were then relayed anonymously for two challenge rounds (§7). Two disagreements converged in round 1. Two survived both rounds, with the lanes swapping positions each round. For each, both positions and a recommendation are recorded below; neither was silently picked.

## 1. Outcome and scope

Make `get_code_structure` return structure for Git-tracked source files while the repository carries on with ordinary Git activity. Today, nearly every call fails with `artifact_unavailable (reason=binding_rejected.source_authority_unavailable) — retryable`. The failure reproduced on several Swift files in this repository on 2026-10-03.

In scope:

1. Stop incidental directory-timestamp churn from counting as a repository-authority change.
2. Give real authority changes a recovery path that can succeed, by reusing the existing store-driven root-session reset.
3. Make the guard that failed observable: typed failure reasons, telemetry, and an MCP issue detail.
4. Add real-Git regression tests that fail on today's code.

Not in scope:

- YAML or Jinja codemap support. `unsupported_file` is correct, because no grammar is registered (`WorkspaceCodemapBindingEngine.swift:5123-5125`, `SyntaxManager.swift:584-586`).
- Invalid `scope` payloads. The schema and validation are correct (`MCPFileToolProvider.swift:162-203`), and the caller is unknown.
- Re-enabling `.git` FSEvents.
- Dropping `indexGeneration` or `metadataGeneration` from the authority.
- Any engine-side root-retirement lifecycle (§7.1).

## 2. Verified starting points

Line references identify the checkout inspected on 2026-10-03.

| # | Fact | Anchor |
|---|---|---|
| E1 | `makeSourceAuthority` returns `nil` when a fresh capture differs from the cached `record.stableAuthority`. It also returns `nil` on pre/post window instability and on any thrown error, so every cause collapses into one result. | `WorkspaceCodemapGitCapabilityService.swift:644-727` (`:679`, `:703-709`, `:725-726`) |
| E2 | `record.stableAuthority` is written only in `complete(...)` after a resolve flight. In `Sources/`, `resolve`/`reload` are called only from `registerRoot`. An eligible root with an equal registration returns `.exactDuplicate` without re-resolving. | service `:563-567`; engine `:497-498`, `:511`, `:522` |
| E3 | `layoutGeneration` digests the stat of the worktree root, `.git`, gitDir, `commondir` and commonDir. Stat evidence includes size, mtime and ctime. | service `:986-994`, `:1420-1431` |
| E4 | A read-only `git status --porcelain` advanced the `.git` directory's mtime and ctime (1791024707 → 1791024713) while `.git/index` stayed unchanged. | live probe, 2026-10-03 |
| E5 | FSEvents drops every `.git/` event, so the store's `.git` delta predicate never fires from the watcher. Root-level invalidation happens only on a watcher gap, a checkout fence, a late-setup fence or a catalog advance. | `FileSystemService+FSEvents.swift:1076-1082`; store `:20302-20330`, `:18892-18925` |
| E6 | `.sourceAuthorityUnavailable` maps to `.retryFreshDemand`, which re-requests the file against the same stale session. `.resetRootSession` already exists for `.rootNotRegistered` and `.capabilityUnavailable`. | `WorkspaceCodemapArtifactDemandModels.swift:50-59`; store `:14578-14604`, `:14607-14640` |
| E7 | There are four consumers of the cached authority: demand `:5651`, manifest preparation `:4386`, projection preload `:3136` (maps `nil` to per-candidate `.transient`, `:3136-3154`), and batch revalidation `:4527` (service `:782`). | engine |
| F1 | The coordinator already bounds `.resetRootSession` to once per root epoch per operation. | `WorkspaceCodemapPresentationCoordinator.swift:50-69`, `:1310-1375` |
| F2 | Store cleanup is one coalesced flight per root ID. `detachCodemapSession` removes the session synchronously, then the flight runs `invalidateRootAuthority` (default command `.catalogAdvanced`). `prepareCodemapRootSessionRetry` waits for the flight under the caller's deadline. | store `:18710-18863` |
| F3 | Eligible-root invalidation sets the root to `.unavailable(.unresolved)` with the same registration and keeps the capability record. Re-registering with an equal registration resolves again. A different registration must advance **both** catalog and ingress generations, or it returns `.failed`. | engine `:7254-7289`, `:478-494` |
| F4 | `descriptorEvidence` already treats *intermediate* directories as identity-only (see the code comment). Leaf entries use `sameStableStat` across lookup→open and pre→post, and layout leaves are directories. | service `:1287-1395` (`:1351`, `:1380`) |
| F5 | Today's tests either call `resolve` explicitly after each mutation or inject a synthetic rejection. No test covers "succeed → incidental metadata change → demand again". | `WorkspaceCodemapGitCapabilityServiceTests.swift:304-360`; `MCPCodeStructureWorktreeTests.swift:561-605` |

## 3. Root cause

Both lanes agreed on this.

1. Registration captures `StableAuthority` once.
2. That authority includes directory size and timestamps, which ordinary Git activity (lock files in `.git`) and top-level file creation change constantly.
3. Every demand compares a fresh capture against the cached baseline and fails at `:679`.
4. Nothing re-resolves an eligible root, and the watcher cannot see `.git` changes.
5. The recovery mapping retries the same comparison against the same session, so the failure is permanent until a watcher gap, checkout refresh or restart.

Inferred but not directly observed: which leaf guard fires in the running binary. Leaf diagnostics (§4.5) answer this.

## 4. Agreed design

### 4.1 Directory evidence is identity-only (necessary, lands first)

Without this change, recovery alone would pay a root reset on almost every call, because the app's own Git polling keeps changing `.git`.

- In `digestEvidence` (service `:1236-1257`), branch on the descriptor type:
  - **Directories:** append only `st_dev:st_ino:st_mode`, with no size, timestamps or contents.
  - **Regular files:** keep the full `appendStatEvidence` and the bounded-contents policy.
- A linked-worktree `.git` pointer **file** keeps full evidence because it is a file. `commondir`, `HEAD`, refs, `index`, config, attributes and sparse files are unchanged.
- In `descriptorEvidence`, use `sameDescriptorIdentity` for **directory leaves** in both window checks: lookup→open (`:1351`) and pre→post (`:1380`). Without this, a directory timestamp change during the open window still throws `.layoutChanged` (F4). File leaves keep `sameStableStat`.
- Keep unchanged: `O_NOFOLLOW`, symlink rejection, descriptor-chain identity re-verification, `bindingIdentityDigest`, `layoutIdentity`, and the binding epochs.

What directory timestamps protected, and what covers it now:

| Threat | Covered by |
|---|---|
| A directory replaced by a file, symlink or new inode | kept `st_dev`/`st_ino`/`st_mode`, `layoutIdentity`, `worktreeBindingEpoch` |
| Repository relocation | `.git` pointer file and `commondir` contents, which keep full evidence |
| Attributes, sparse or config files appearing or vanishing | the files themselves are digested with a present/missing marker |
| HEAD, ref, packed-refs or index changes | `metadataGeneration` and `indexGeneration` |

In practice only layout URLs resolve to directories. `metadataURLs`, `attributeURLs` and `candidateAttributeURLs` name files (service `:1142-1210`). So a type-based branch behaves the same as a layout-scoped helper and is simpler (§7.5).

### 4.2 Typed authority results

- `makeSourceAuthority` returns an issued token or a `WorkspaceCodemapSourceAuthorityFailure`.
- `revalidateSourceAuthorities` returns valid or invalid with a failure.
- Both stay non-throwing.
- The capability service never adopts a newly observed authority. `resolve → complete` remains the only place authority is updated.

Failure leaves (names only; never contents, paths, digests or ref values):

| Leaf | Meaning | Engine rejection |
|---|---|---|
| `capabilityInactive` | The record is missing or not eligible, or the capability is superseded. | existing behavior |
| `candidatePathRejected`, `candidateNotRegularFile` | The source path itself is unusable. | `.sourceAuthorityUnavailable` |
| `repositoryAuthorityChanged(changed: [component])` | The capture disagrees with the cached baseline on non-binding components. | **new** `.repositoryAuthorityChanged` |
| `repositoryBindingChanged` | The capture disagrees on namespace, object format or a binding epoch. | existing `.capabilityUnavailable` |
| `repositoryLayoutChanged` | The `captureAuthority` layout or prefix guard failed (service `:957-971` origin only). | existing `.capabilityUnavailable` |
| `unstableWindow(attributes \| repository \| pathFingerprint \| capability)` | Pre/post mismatch, including descriptor-window `.layoutChanged` throws. | `.sourceAuthorityUnavailable` |
| `captureFailed(permissionDenied \| transient)` | An I/O or permission failure. | `.sourceAuthorityUnavailable` |
| `tokenInvalid` | The token factory rejected the token, or batch input was invalid or duplicated. | `.sourceAuthorityUnavailable` |
| `cancelled` | Cancellation. | existing cancellation path |

`CapabilityCaptureError.layoutChanged` must record where it was thrown. Descriptor races and symlink or traversal rejection are window instability, not authority change; mapping them to a reset would thrash (§7.2).

Comparison order (capture ordering is still open, §7.3): check cancellation and currentness, then apply the recommended early return in §7.3.

The engine also tags the downstream factory failures at engine `:5745-5754` separately: `sourceExpectationRejected` and `artifactRequestTokenRejected`.

### 4.3 New rejection and recovery mapping

- Add `WorkspaceCodemapBindingDemandRejection.repositoryAuthorityChanged`. It carries no payload, so existing `Equatable` matches stay valid.
- `WorkspaceCodemapArtifactDemandRecovery`: add `.repositoryAuthorityChanged` to the `.resetRootSession` group. Keep `.sourceAuthorityUnavailable → .retryFreshDemand`.
- MCP (`MCPServerViewModel.swift` around `:5990-6070`): use `detail: binding_rejected.repository_authority_changed` with `retryable: true` and a message such as "Repository authority changed; the codemap session was reset. Retry." Keep the existing `code` and `phase` schema.

### 4.4 Recovery is store-driven, with no new engine lifecycle

The engine's `processRequest` maps the typed failure to the rejection and **returns**. It does not invoke any invalidator itself. Recovery reuses the existing path:

coordinator `claim` (F1) → `store.prepareCodemapRootSessionRetry` → `detachCodemapSession` → coalesced cleanup flight (F2) → engine `invalidateRootAuthority` → re-registration → `resolve` → `complete`, which adopts the new `StableAuthority` → the demand succeeds. Sibling seeds are reissued by the coordinator (`:1352-1373`).

Old-session safety already exists and must stay intact:

- `invalidateRootAuthority` flips root state and cancels requests synchronously before its first `await` (engine `:7261-7270`).
- `processRequest` re-checks `currentRequest` and the session ID after each `await` (`:5661-5666`).
- `prepareCodemapRootSessionRetry` requires the ticket to be the current record with this exact rejection.
- Overlay invalidation is fenced by `expectedAuthority`.

### 4.5 Projection preload short-circuit

Both lanes agreed on this. A root-wide authority mismatch is not a per-candidate failure. At engine `:3136-3154`, the first `repositoryAuthorityChanged` (or binding change) ends the current projection job through the existing `cancelProjectionJob` seam (`:4204`). It emits one event and does not spend a full capture per remaining candidate. Unrelated per-candidate failures keep returning `.transient`. Whether the background path also starts root recovery is open (§7.4).

### 4.6 Diagnostics

- A service log line on each failure: `codemap source authority unavailable root=<epoch> reason=<leaf> changed=[layout,index]`.
- Engine events `repositoryAuthorityChanged` and `sourceAuthorityTransientUnavailable`, plus a counter `repositoryAuthorityChanges` next to `capabilityRetries`. The existing `.invalidation(reason:)` event records the reset.
- A DEBUG accessor `lastSourceAuthorityFailureForTesting(rootEpoch:)` holding one bounded entry per root, cleared on release.
- Never log source or metadata contents, absolute paths, ref or config values, fingerprints or raw error text.

## 5. Implementation steps

1. **Failing-first tests** (§6) against the current interfaces. Record the failures.
2. **Evidence normalization** (§4.1). This is independently compilable and testable, and lands on its own.
3. **Optional diagnostics-only build.** Typed results with every failure still mapped to `.sourceAuthorityUnavailable`. Run it live to record the actual leaf before behavior changes.
4. **Atomic behavior set:** typed results consumed at all four call sites (E7), the new rejection, the recovery mapping, the MCP detail, the projection-job short-circuit, and updates to exhaustive switches and test fakes.
5. **Validation** (§6, §9).

Files:

- `Infrastructure/WorkspaceContext/WorkspaceCodemapGitCapabilityService.swift`
- `Infrastructure/WorkspaceContext/Models/WorkspaceCodemapBindingEngineModels.swift`
- `Infrastructure/WorkspaceContext/Models/WorkspaceCodemapArtifactDemandModels.swift`
- `Infrastructure/WorkspaceContext/WorkspaceCodemapBindingEngine.swift`
- `Infrastructure/MCP/ViewModels/MCPServerViewModel.swift`

No logic change is planned in `WorkspaceFileContextStore.swift` or the presentation coordinator, unless the §10 validation items require it.

## 6. Tests

All tests use `ReviewGitRepositoryFixture` and real filesystem or Git mutations. Hooks may control timing, but must never manufacture rejections.

`WorkspaceCodemapGitCapabilityServiceTests`:

1. `testSourceAuthoritySurvivesDirectoryTimestampChurn`: resolve and issue a token. Create and delete a file in `.git` and in the worktree root, then run `git status --porcelain`. Issue again with the **same** capability and no `resolve`; expect success. Deterministic churn is primary; `git status` is supplementary.
2. `testResolveDoesNotAdvanceAuthorityForDirectoryTimestampChurn`: after the same churn, `authorityGeneration` and `layoutGeneration` are unchanged.
3. `testBatchRevalidationSurvivesDirectoryChurnWithoutResolve`.
4. `testSourceAuthorityReportsChangeAfterIndexAdvance`: stage another file and expect `repositoryAuthorityChanged([index])` with no adoption. An explicit `resolve` then advances, and issuance succeeds. Add variants for commit (`[metadata]`) and for revalidation.
5. `testDescriptorWindowRaceIsUnstableNotChanged`: use `hooks.afterAuthorityEvidenceOpen` or `afterSourcePathFingerprintCapture` to mutate the source or index mid-window. Expect `unstableWindow`, not `repositoryAuthorityChanged`.
6. `testLayoutIdentityAndPointerChangesRemainRejected`: replace a directory inode, and change a linked worktree's `.git` pointer or `commondir`. Old capabilities must stay unusable. Keep the existing symlink and no-follow tests.
7. Existing `testAuthorityAdvancesForIndexConfigAttributesSparseAndRefs` stays green unchanged.

`MCPCodeStructureWorktreeTests` (full store + engine + coordinator, no injected rejection):

8. `testCodeStructureSucceedsAfterGitDirectoryChurn`: ready, then churn, then ready again. `codemapRootSessionRepairCountStorageForTesting == 0` and `repositoryAuthorityChanges == 0`.
9. `testCodeStructureRecoversOnceAfterIndexAdvance`: ready, then `git add` another file, then a request is ready after exactly one repair. A third request needs no further repair. Assert a bounded deadline so a hidden adoption loop fails loudly.
10. `testConcurrentAuthorityRepairReissuesAllSiblingSeeds`: two overlapping multi-file requests. Expect one store detach, current results for all siblings, and stale old tickets.
11. `testOldTicketCannotResetReplacementSession`: after a reset, `prepareCodemapRootSessionRetry` with the old ticket returns `nil` and the repair count is unchanged.
12. `testContinuedAuthorityChangesExhaustOneRootRepair`: mutate again after the replacement registration. Expect one reset, bounded termination and a retryable `repository_authority_changed` issue.
13. Tool-level: drive the actual `get_code_structure` handler after `git add`, then five interleaved `git status` calls. Expect no `artifact_unavailable` and no extra repairs.
14. Preload: about 20 Swift files with the retained-projection policy enabled. After `git add` and no foreground demand, `repositoryAuthorityChanges ≤ 1` per job run. An idle period of about 2 s shows no growth in `capabilityResolutions` or the change counter. A later foreground demand succeeds with one repair.
15. **Expansion gate (§7.4):** after `git add`, an `expand: referrers` query whose seed artifacts are already ready returns structure within the 10 s deadline, without a separate seed re-demand.

Keep the synthetic fresh-demand test (`:561-605`) as compatibility coverage. Do not count it as evidence for this fix.

Run:

```text
make dev-test FILTER=WorkspaceCodemapGitCapabilityServiceTests
make dev-test FILTER=MCPCodeStructureWorktreeTests
make dev-test FILTER=<engine and presentation-coordinator suites touched by exhaustive-switch updates>
```

## 7. Material disagreements and resolution

### 7.1 Lifecycle scope: engine retirement machinery vs store-driven reset. **Resolved in round 1.**

- **One lane, initially:** add an engine `RootAuthorityInvalidationFlight`, expected-session fencing before `revokeProjectionDemands`, a terminal-result parameter for `synchronouslyCancelRequests`, registration/unload joins, and engine-initiated retirement from revalidation.
- **Other lane:** reuse the store-driven reset unchanged.
- **Resolution:** after F1–F3 were verified (reset budget, coalesced store cleanup flight, capability record retained with re-resolution on re-registration), the first lane withdrew every item. Its reasoning: the engine *returns* the rejection and never invalidates from the request path, so there is nothing new to fence or join, and an engine flight would create a second owner of the same lifecycle. Outcome: §4.4.

### 7.2 Mapping `CapabilityCaptureError.layoutChanged` to a reset. **Resolved in round 1.**

- **One lane:** map every `.layoutChanged` to the reset rejection.
- **Resolution:** both lanes agreed it must not. The error is also thrown by descriptor-window races, for example `index.lock` being renamed over `index` between lookup and open, and by symlink or traversal rejection. Only the `captureAuthority` layout/prefix guard maps to the existing `.capabilityUnavailable` repair. Outcome: §4.2.

### 7.3 Capture ordering: return on the first mismatch, or complete both captures? **Open after two rounds.**

The lanes swapped positions in each round. Both agree that neither ordering ever accepts a token, and that F1 bounds both.

- **Complete both captures.** Window instability takes precedence over baseline mismatch: pre ≠ post means unstable, so a fresh demand. pre == post with changed binding components means `.capabilityUnavailable`. pre == post with other changes means `.repositoryAuthorityChanged`. Argument: during a multi-step Git operation (index write, then ref update), early return spends the single root reset on a half-finished state. A second drift then exhausts the budget and the user sees a retryable failure. Classifying that attempt as unstable spends the cheaper per-file retry instead. Successful attempts already do both captures, so the extra cost lands only on the rejection path.
- **Return on the first mismatch** at `:679` and `:782`, with `changed` computed from the capture in hand. If pre matches the baseline, keep the post checks and classify any mismatch as `unstableWindow`. Arguments:
  - The second capture costs three async Git calls plus digests (`:957-979`) on a path whose outcome is already a rejection.
  - The mid-operation race costs at most one retryable reply within a millisecond window, with no loop and no stale artifact.
  - It is testable with the existing `afterSourcePathFingerprintCapture` hook (`:672`); the alternative needs a new hook between the captures.

**Recommendation: return on the first mismatch.** It is the smaller change, safe because no token is accepted, and testable with existing hooks. After §4.1, the remaining rejection sources are rare, settled index or ref rewrites, so the race being optimized for is uncommon.

Revisit trigger: if telemetry shows `repositoryAuthorityChanged` followed by an exhausted reset budget in the same operation at a meaningful rate, switch to completing both captures. That change is confined to the two comparison sites.

### 7.4 Background preload and batch drift: autonomous root recovery or not? **Open after two rounds.**

Both lanes agree on the §4.5 short-circuit, and that a stale background path is degraded (no preloaded projection) rather than incorrect (no stale artifact is served).

- **Propagate background drift.** Revoke the job's projection demands with the existing `.unavailable(.capabilityUnavailable)` status, so the store's projection-recovery observer detaches the session and runs fresh setup without waiting for a foreground request. Give manifest authority loss its own adoption outcome so the `.retryable` re-arm (engine `:4758-4761`) does not retry against the same capability. Constraints:
  - The observer must not wait on the cleanup flight that itself awaits the observer (`startCodemapCleanup` awaits `projectionRecoveryObserverTask`).
  - The preload retry budget must survive replacement.
- **No autonomous repair.** Foreground demands always reach `makeSourceAuthority` after `prepareManifestForRequest` (`:5614-5651`) and trigger the store reset. A `.retryable` adoption only re-arms lazily. Background propagation would add store-observer behavior that has not been verified, plus a self-wait hazard, for a degraded-but-correct state. Test 9's bounded deadline and test 14's idle counter detect any hidden loop.

**Recommendation: no autonomous repair in this fix**, with test 15 as a mandatory gate.

My own concern (an inference, not verified): `expand` traversal may depend on projection coverage. If a query's seeds are already ready, no seed demand reaches `makeSourceAuthority`, so nothing triggers the reset. Relationship expansion could then time out against the stale projection. If test 14 or test 15 fails, adopt the propagation position, including its observer self-wait and budget constraints.

### 7.5 Minor points resolved by the orchestrator

- **Type-based vs layout-scoped directory digest:** type-based (§4.1). Verified that only layout URLs resolve to directories, and that a `.git` pointer file keeps full evidence either way.
- **Name:** `repositoryAuthorityChanged`, not `Advanced`. A single observation does not prove a settled replacement. Both lanes accepted this in round 2.
- **Landing order:** tests first, then evidence normalization alone, then an optional diagnostics-only build, then the atomic behavior set (§5). This combines both lanes' orderings.

## 8. Risks and mitigations

- **Narrower directory evidence.** Identity, no-follow traversal, file evidence and binding checks are preserved (§4.1 table). Audit the omitted helpers (`GitRepositoryLayout` equality, `resolveCandidate`) for any comparison that still uses directory timestamps.
- **Real metadata churn still resets.** Index, config, attribute and ref changes remain authority changes by design. They are bounded by F1 and coalesced by F2. If index-only resets dominate the telemetry, dropping `indexGeneration` is a separate, documented semantic change.
- **Re-registration generation contract (F3).** If the post-detach registration differs without strictly greater catalog and ingress generations, `registerRoot` returns `.failed`. Test 9 is the gate. If it fails, correct how generations are built in the existing reset path. Do not relax the guard.
- **One-time token mismatch after upgrade.** `layoutGeneration` values change, so persisted authority-dependent manifests and projections fail revalidation once and are re-adopted normally. Do not migrate or rewrite tokens.
- **Exhaustive switches outside the inspected slices.** These are compiler-enforced. Update the test fakes for the new return types.

## 9. Acceptance criteria

- Tests 1–15 fail on the current tree for the stated reasons and pass after the change. The listed suites are green.
- The live app's build revision is recorded and matches the tested source.
- In this repository, 20 consecutive `get_code_structure` calls on Swift files, interleaved with `git status --porcelain`, all return structure. There are zero `binding_rejected.*` issues and `repositoryAuthorityChanges == 0`.
- After `git add` and after `git commit`, the next call returns structure with exactly one logged `repositoryAuthorityChanged` (`[index]` or `[metadata]`) and one repair. Later calls need none.
- A `git status` loop every 2 s for 60 s, with periodic calls, produces zero repairs.
- A multi-file request spanning a `git add` either succeeds after one reset or reports one retryable `repository_authority_changed` issue. It never loops.
- Leaf diagnostics from the live build confirm or refute the §3 cause.

## 10. Must-validate before implementation

1. `detachCodemapSession` followed by re-setup: does the replacement registration satisfy F3's equal-or-strictly-greater generation contract? (Test 9.)
2. Whether `.dirtyRetryRequired` and per-candidate `.transient` projection results are driven by a timer or retry loop, or only consumed by the next demand. (Tests 9 and 14.)
3. The behavior of `projectionRecoveryObserver` and `codemapProjectionPreloadRetriesByRootEpoch` on `.capabilityUnavailable`. This is only needed if §7.4 escalates.
4. Whether `descriptorEvidence` directory leaves can be opened without `O_DIRECTORY` today (`isLeaf ? 0 : O_DIRECTORY`). Confirm that the identity-only leaf branch keys on the observed `S_IFDIR` type, not on the URL.
5. All call sites, protocols and fakes for `makeSourceAuthority` and `revalidateSourceAuthorities` (four production sites, E7).
