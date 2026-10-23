# Claude identity resolution — OracleA planning

Scope: read when the task touches implementation of the Claude history-identity prerequisite under owner O15.
Authority: Reference
Last-verified: 2026-10-23

Exact preset: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`; chat `claude-identity-resoluti-980C68`; operation `F7CCDDCF-CBD7-48AB-B6C3-5D8E9D3A21D7`. Full independent response retained below. These are recommendations, not owner Decisions; main dispositions are in [resolution evidence](phase4-prerequisite-resolution.md).

# Oracle Plan

# Native Claude history identity: implementation plan

## 1. Summary

Use the existing durable `dispatchID` as the outbound user-message UUID, with its existing ordered `userItemIDs` supplying the one-to-many association for aggregated sends. Carry complete native message envelopes through the provider seam before flattening, and materialize qualified live envelopes and historical envelopes through one identity projection. Keep association hints separate from completed-materialization records, validate payload conflicts before deduplication, and commit canonical rows, ledger changes, and receipts through the existing owner-save path before advancing any recovery cursor. This is a targeted cross-layer change, not a runtime or persistence refactor. Production recovery gates and live acceptance remain OFF; installed providers, wrappers, helper shutdown, and private runtime data are outside scope.

**Evidence boundary:** The supplied official SDK evidence establishes the user-supplied UUID and complete-assistant-envelope identity contracts. It does not establish every native JSONL record shape, partial-event identity, replay identity, or installed-producer compatibility. The metadata/graph slice below therefore has a bounded public-source/fixture evidence gate—not permission for live inspection.

## 2. Current-state analysis

### Dispatch and baseline ownership

The current outbound chain is:

`AgentProviderHandoff.dispatchBaselineIdentity`<br>
→ `ClaudeAgentModeCoordinator` captures dispatch reservation and runtime owner<br>
→ `AgentRuntimeOperationOwner.session` / `writeAdmission`<br>
→ `ClaudeNativeProcessSessionController.sendUserMessage(_:)`<br>
→ runtime fence and pre-byte admission<br>
→ `ClaudeSDKProtocolCodec.encodeUserMessage(text:sessionID:)`<br>
→ `sendLine`.

The durable dispatch identity already contains:

- `dispatchID`: the first delivery attempt ID;
- `runAttemptID`;
- ordered constituent `userItemIDs`.

`captureClaudeDispatchBaseline` captures an immutable pre-send history boundary. A captured baseline and zero-row receipt are saved before bytes; unsupported captures currently do not provide usable recovery boundaries. Production capture is explicitly OFF.

**Missing:** the encoded user message has no caller UUID, and the baseline does not record that such a UUID was supplied. Existing baselines therefore cannot retrospectively establish this association.

### Live output loses native identity

`ClaudeSDKNDJSONTranslator` converts complete assistant/user envelopes into flattened content, reasoning, and tool results. During that transformation:

- native envelope UUID and block position are lost;
- `message.id` is retained for usage, not native transcript identity;
- tool invocation UUIDs are generated randomly;
- generic `applyStreamResult` buffers/merges assistant text and may replace a trailing assistant row for `final_content`.

The bridge correctly isolates the package from app types. The long-lived event router preserves stream order and active/background ownership. Both must remain intact.

### Historical output has a separate identity projection

`ClaudeSessionHistoryReader`:

1. resolves one exact session file;
2. captures file identity and bytes from one descriptor;
3. validates complete lines and the conversation graph;
4. projects deterministic row and tool invocation UUIDs;
5. filters rows using cursor and ledger.

Its native user rows deliberately have no local item. The import planner then suppresses ledger-known keys without examining their payloads.

Consequently, live and historical items cannot currently be proven equivalent, and a conflicting same-key record could disappear behind deduplication.

### Persistence and canonical transcript ownership

`AgentTabSession.items` is only the mutable working suffix. Older or compacted backing resides in `transcript`; updating `items` cannot repair it.

The existing transaction boundary is appropriate:

`canonical transcript + native ledger + ImportCommit`<br>
→ fenced owner save<br>
→ recovery cursor CAS.

`AgentSessionDataService` rejects ordinary stale snapshots carrying an older import receipt. `saveSession` acknowledges commits only for the current save owner.

The association preflight intentionally refuses ordinary Claude imports today. It also has two relevant limitations:

- it treats any observation row with `item == nil` as an unassociated user;
- `outputItemIDs` does not consistently enumerate output in subsequent full-detail persisted turns: its per-turn `afterUser` flag resets.

Neither limitation should be worked around with text matching.

## 3. Design

### A. Scope and qualification

Use the existing recovery gate to keep the new operational path disabled in production. Do not add a user-facing setting, activate a runtime flag, request partial output, or enable replay messages.

Eligibility requires all of:

1. built-in Claude Code;
2. the existing source-test recovery seam permitting identity capture;
3. a durable dispatch with complete constituent identities;
4. the supported complete-envelope contract.

GLM, Kimi, custom-compatible providers, and wrappers remain on the existing path. A Claude-looking envelope or reported CLI version is not sufficient qualification.

Tests may exercise the complete path through existing injected seams. Production construction continues to disable it.

**Assumption:** source work may extend the existing OFF-gated path and its fixtures, but must not change ordinary production send/render behavior.

---

### B. Outbound UUID and aggregated-user association

#### Decision

Use `dispatchID.uuidString.lowercased()` as the outbound top-level `uuid`.

Do not introduce another generated identifier. A retry of admission for the same durable dispatch uses the same UUID; a genuinely new durable dispatch uses its new dispatch ID. This is correlation, not a claim of provider-side exactly-once delivery.

#### Additive baseline field

Extend `DispatchBaseline` with:

| Serialized field | Type | Default | Meaning |
|---|---|---|---|
| `nativeUserEntryID` | optional string | absent / `nil` | Caller UUID supplied by this implementation for this dispatch |

Keep `userItemIDs` as the ordered, complete association target. Do not add a second single-user field or duplicate the list in each `NativeItem`.

Rules:

- Newly qualified baselines record `nativeUserEntryID == canonical dispatchID`.
- Legacy baselines lacking the field remain unqualified.
- Never infer the field from an old baseline’s `dispatchID` during decoding.
- Require nonempty, distinct constituent IDs, all present as canonical user items.
- Do not use `compactMap` to silently discard missing constituent user IDs when forming a qualified association.
- Unsupported baselines may retain the outbound identity hint, but remain unusable for recovery.
- Baselines remain immutable and are never backfilled from later observations.

When native history contains a user entry with the exact recorded UUID and session, it associates with **all** ordered constituent users. Provider-bound prefixes and instruction injection do not change that association.

A history user record alone, text equality, arrival order, or a replay message does not create the association.

#### Narrow immutable plumbing

Add a Claude-specific task-local context beside—not inside every provider interface—the existing operation-owner plumbing:

- value type: `ClaudeNativeDispatchIdentity`;
- fields: `dispatchID`, `nativeUserEntryID`;
- immutable and `Sendable`;
- lifetime: one coordinator-owned send operation;
- default: absent.

The coordinator constructs it once from the validated handoff identity and binds it around `sendUserMessage`. The controller captures it at method entry, before suspension. It does not reconstruct it from mutable session state after admission.

Keep `sendUserMessage(_:) async throws -> UUID` unchanged.

Modify the codec additively:

- Before: `encodeUserMessage(text:sessionID:)`
- After: `encodeUserMessage(text:sessionID:messageUUID:)`, with the new optional argument defaulting to `nil`.

The controller passes the captured UUID only for the eligible built-in path. With no context, encoding remains unchanged.

Cancellation or stale ownership before `sendLine` still means zero bytes. A persisted baseline for a write that never happened remains harmless. No acknowledgement is treated as an fsync guarantee.

---

### C. Complete-envelope seam before flattening

#### Package DTOs

Add a provider-owned, immutable `Sendable`, `Equatable` complete-envelope DTO. It contains:

- exact native session ID;
- exact top-level envelope UUID;
- role: user or assistant;
- ordered content blocks, retaining original positions;
- raw tool-use IDs;
- sidechain attribution where reported;
- validated semantic metadata needed by the supported profile.

Supported block variants for the first projection:

- text;
- tool use: raw ID, name, structured input;
- tool result: raw tool-use ID, supported content, optional error flag;
- thinking: text and its validated signature field, when supported by the pinned fixture.

Do not assign transcript identity to partial events. Do not use the API `message.id` as an entry key. Preserve that field’s existing usage-accounting meaning.

Unknown block kinds, malformed identity, sidechain output, or semantic mutation fields produce an explicit unsupported extraction result, not a partially qualified envelope.

#### One delivery unit, not adjacent loosely coupled events

Add a translation-result wrapper containing:

- complete-envelope extraction outcome;
- existing flattened `ClaudeProviderStreamResult` companions.

Extraction outcomes are:

- not a complete native message;
- supported complete envelope;
- unsupported complete message, with available identity and a reason.

The existing translation entry point continues returning flattened results for existing consumers. Its implementation and the new wrapper entry point share parsing; do not build a second translator.

The native controller uses the wrapper only in the OFF-gated qualified path. The bridge maps it to one core stream delivery containing:

- provider-neutral/core envelope data;
- the ordered existing `AIStreamResult` companions.

This preserves one router ownership decision for the entire envelope. Do not emit an identity event followed by unrelated companions that might cross a run marker.

**Insufficient slice:** the translator’s public entry point, controller emission code after line 2414, and adapter/router copying code were not supplied. Before editing, trace that continuation and identify every construction or copy of the stream value. Retain the existing public translator signature; add the wrapper entry point beside it.

#### Dedicated app reducer

In `applyStreamResult`, handle the complete-envelope delivery before generic companions, under the already-selected active/background delivery context.

For a supported, qualified envelope:

1. recheck delivery ownership;
2. validate identity and conflicts;
3. project/materialize the entire envelope synchronously on the main actor;
4. stage its ledger changes and receipt with the rows;
5. process only non-content companions.

Consumed companions include text, reasoning rows, tool-call rows, and tool-result rows already represented by the envelope.

Preserved companions include usage, lifecycle, stop/finalization, context accounting, and other nonmaterialization effects. Each must run exactly once, in its original order.

For the unqualified path, retain current flattened behavior exactly.

#### Rendering rules

- A complete native text block owns its deterministic row. Do not merge distinct native entries because they share an API message ID or adjacent text.
- Preserve content-block order. Do not concatenate blocks and renumber them.
- Use the existing background ownership bookkeeping, including the router’s source ID.
- Raw native tool-use identity determines the shared deterministic invocation UUID. Tool name is not an association key.
- Thinking visibility follows the existing reasoning feature policy. Hidden supported thinking still receives an intentional nonprojection record; it must not be mistaken for a user row.
- Generic terminal `final_content` must not rewrite identity-owned rows without native identity. For a delivery already materialized from complete native assistant envelopes, treat terminal text as a companion summary rather than another authoritative transcript row.
- Preserve run completion, usage finalization, tool terminal-state handling, and notifications. Presentation-state changes must not alter the immutable native payload fingerprint.

Unexpected partial output remains unqualified. It may follow existing rendering behavior, but cannot populate completed identity records.

---

### D. Shared identity projection and conflict detection

#### Shared projector

Move the native row/tool ID derivation and supported-envelope projection into a narrow core utility, proposed as:

`ClaudeNativeHistoryIdentity.swift`

It is a stateless namespace, not a service or persistence owner.

Both live envelopes and the history reader feed the same normalized representation:

`provider + native session + envelope UUID + row kind + original block ordinal`

Retain the existing UUID namespaces and derivation algorithm for already supported historical rows. Preserve the existing `deterministicUUID` entry point as a forwarding compatibility helper if callers outside the supplied slices use it.

Add thinking to `RowKind`. Preserve raw tool-use IDs in the normalized row until projection completes.

#### Completed-envelope receipts

`NativeItem` continues mapping an individual native row to at most one local output item. It does **not** become the many-user mapping.

Add an envelope-level completed-materialization collection to `AgentSessionProviderHistoryRecovery`:

`materializedEnvelopes: [MaterializedEnvelope]`

Each entry owns:

| Field | Type |
|---|---|
| `provider` | string |
| `nativeSessionID` | string |
| `nativeEntryID` | string |
| `profile` | string |
| `payloadDigest` | string |
| `rowKeys` | ordered array of strings |
| unknown members | existing extras representation |

This envelope record is necessary to detect removed blocks, changed block counts, and empty-envelope conflicts—not just changed payloads at surviving row keys.

An outbound baseline hint is never an entry in this collection.

The digest covers the normalized supported semantic payload:

- role and ordered blocks;
- exact text;
- raw tool-use IDs;
- tool names and structured inputs;
- tool-result content and error state;
- supported thinking content/signature;
- any supported semantic relationship fields.

Exclude usage, timestamps, display state, and known nonsemantic metadata.

Use a documented canonical encoding before SHA-256: stable object-key ordering, ordered arrays, preserved JSON scalar distinctions, and no floating-point reserialization shortcut. Test this with fixed fixtures. The digest is a conflict check, not the identity.

#### Conflict-before-dedup algorithm

For every complete observed envelope, including envelopes whose rows are ledger-known:

1. validate its supported shape and graph semantics;
2. compute its native key, ordered row keys, and payload digest;
3. compare against any completed-envelope receipt;
4. reject a digest or row-key-set mismatch;
5. only then suppress an identical completed envelope.

If an existing `NativeItem` lacks the envelope-level evidence needed for this comparison, do not silently upgrade it. Refuse qualified reconciliation for that overlap.

Historical candidates must expose all validated envelope evidence needed for conflict checking, even when they project only rows after the selected boundary. Remove ledger suppression from the reader’s validation stage.

Replacement/truncation handling remains conservative: use validated completed evidence to locate a frontier; fail with `baselineLost` if no safe frontier exists.

Complexity remains linear in captured bytes plus rows, using per-operation dictionaries for envelope keys and row keys. Do not repeatedly scan the ledger for each row.

#### Retractions and corrections

Do not implement speculative supersession or refusal-fallback retraction semantics.

The reported TypeScript fields remain investigation leads. Verify their exact definitions in public pinned source before naming or parsing them.

For this slice:

- a same-key payload change is a conflict;
- a validated explicit retraction/supersession is unsupported;
- no completed canonical row is silently deleted or rewritten;
- no cursor advances over the rejected candidate.

For live events, preserve the old materialized rows, display the newly received content through an explicitly unassociated fallback with a warning, and persist an identity blocker. This avoids silently losing the correction while honestly disabling reconciliation.

Add a small `identityIssues` collection to the existing recovery envelope:

- provider and native session;
- optional native entry ID;
- reason string;
- unknown members.

Reasons emitted by this build are `unsupportedEnvelope`, `conflictingEnvelope`, `retraction`, `missingIdentity`, and `canonicalBackingUnavailable`. Unknown reasons remain blocking.

Deduplicate identical issues. They survive ordinary saves and clear only with the corresponding existing transcript reset—not by receiving a later plausible envelope.

---

### E. Canonical materialization and the existing save transaction

#### No suffix-only repair

The reducer and import preflight must inspect canonical turns and the suffix.

For each projected output:

- absent from canonical storage: append through existing source-item mutation mechanisms;
- present with a matching completed receipt and unchanged supported payload: no-op;
- present without sufficient evidence: refuse;
- present only in unenumerable compacted backing: refuse any operation requiring inspection or replacement.

Do not rehydrate compacted turns into `items`, replace suffix rows while leaving canonical backing stale, or use `transcriptByReplacingWorkingTurns` as an identity repair mechanism.

This design does not require changing compaction ownership.

#### Atomic staging

Within one non-suspending main-actor operation:

1. validate the complete batch against current canonical state;
2. install its rows;
3. install corresponding native row mappings and completed-envelope receipts;
4. set one `pendingHistoryImportCommit`;
5. mark the session dirty.

Only then await the existing owner save.

There must be no suspension between row and ledger mutation. Downstream source-item notifications must observe a coherent batch; use a paired mutation helper if existing mutation APIs notify before both sides are installed.

History imports continue using recovered labels. Live materialization does not add a recovered label.

#### Save ordering and failure

Serialize qualified envelope materializations through the existing ordered delivery path. Do not overwrite an in-flight pending import receipt with a second independent transaction.

If a save fails:

- retain the rows, ledger, and exact pending receipt in memory for the existing owner-save retry;
- advance no cursor;
- preserve ordinary provider completion handling;
- degrade subsequent output from that source to explicitly unassociated rendering, with a persisted identity issue;
- do not block the event router indefinitely waiting for storage recovery.

The fallback issue is part of the same session snapshot, not a second journal.

Before another qualified transaction or history import, require the previous pending receipt to be committed.

Audit all receipt-producing call sites so they cannot submit an older qualified snapshot after a newer one. The existing import fence permits explicitly declared import commits; it is not a substitute for current-owner and transaction ordering checks.

No new persistence authority is needed.

#### Recovery preflight changes

Replace the current blanket `item == nil` refusal with explicit row-kind handling:

- user text: require an exact captured baseline association for that native entry and all constituent local users;
- supported intentionally hidden content: validate its nonprojection record;
- output: require completed materialization evidence or a new validated projection.

Check every constituent user exists, not merely the first boundary user.

Fix `outputItemIDs` so that once the boundary is found, output in **all subsequent persisted turns** is included, followed by suffix output. A compacted or structurally compacted relevant turn stays nonenumerable.

Scope associations by provider and native session. Check persisted identity issues before import.

Before applying an off-main history read, revalidate:

- action and lane ownership;
- reset generation;
- provider/session;
- ledger;
- canonical transcript and suffix snapshot;
- pending receipts and inactive run state.

Ledger equality alone is insufficient when background output can modify the transcript.

Claude completion remains unconfirmed.

---

### F. Native history profile: necessary support versus unsupported format

Do not solve ordinary metadata by skipping every unfamiliar record, and do not claim ordinary support while retaining blanket refusal of routine auxiliary records.

#### Fixed decoder architecture

Refactor record classification into three outcomes:

1. **Message node:** supported user/assistant content; participates in graph and projection.
2. **Nonrendering graph node:** verified auxiliary record with native graph identity; retains parent links, contributes no transcript rows.
3. **Nonconversation record:** verified auxiliary record that does not participate in the conversation graph; contributes no rows.

Everything else rejects the candidate.

Graph validation operates over retained nodes before visible-message projection. It must not reconnect children around skipped records by guessing, substitute `logicalParentUuid`, or treat API message IDs as node identities.

#### Required bounded evidence work

Using only public pinned source and repository fixtures, establish exact schemas and graph treatment for:

| Record family | Required resolution |
|---|---|
| `file-history-snapshot` | Prove whether it is outside the conversation graph and which identity-like fields are not parent-chain identity. |
| `progress` | Prove whether it is nonconversation data or a nonrendering graph node. |
| `system` | Allow only individually established nonsemantic subtypes; compaction/reset semantics remain unsupported unless separately modeled. |
| `attachment` | Remain unsupported unless a specific routine shape is proven nonsemantic. Never skip the family wholesale. |
| thinking | Establish exact supported block/signature shape and preserve original ordinal. |
| unknown extras | Separate proven nonsemantic extensions from unrecognized semantic/graph fields; the latter refuse. |

The supplied excerpts do not contain these schemas. Therefore an exact field allowlist cannot honestly be specified here.

**This is a required evidence substep, not optional polish.** Its output is a checked-in fixture/profile matrix naming the exact accepted keys and classifications. If the evidence cannot establish a family, leave it explicitly unsupported and mark ordinary-history acceptance blocked. Identity source tests may still pass; they do not qualify ordinary native files.

Retain existing safeguards for:

- exact session and verified absence;
- descriptor-bound capture;
- complete lines and partial baseline refusal;
- conflicting duplicate entries;
- graph cycles, missing parents, and ambiguous branches;
- ambiguous tool association;
- bounded file size.

Do not broaden parallel-tool graph support beyond demonstrated shapes.

---

### G. Compatibility and schema behavior

Keep session version 7.

All new fields default to absent/empty:

- `DispatchBaseline.nativeUserEntryID`;
- `materializedEnvelopes`;
- `identityIssues`.

Follow the existing dynamic-key/extras pattern. Decode new collections element-wise, preserving unreadable elements verbatim. An unreadable identity record prevents qualified reconciliation; it must not fail loading the entire session.

Legacy sessions load and render unchanged. Legacy baselines and ledger entries are not upgraded by inference.

Add new collections to `nilIfEmpty` and known-key sets. Preserve existing unknown fields during every save.

Old builds can ignore or preserve additions, but may still mutate transcript content without maintaining new invariants. Revalidation must detect mismatches; rollback remains subject to the existing clean-quit/resolve-recovery warning.

## 4. File-by-file impact

Paths are repository-relative.

| File | Change and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | Add outbound association field, completed-envelope receipts, identity issues, element-wise unknown preservation. Foundation for reducer and preflight. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/AgentProviderHandoff.swift` | Validate complete ordered constituent identities for qualified dispatches; do not silently drop missing user IDs. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRuntimeLaunch.swift` | Add immutable Claude-specific task-local outbound identity context; leave provider interfaces unchanged. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift` | Construct and bind the context under existing OFF-gated eligibility; retain reservation and admission rechecks. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKProtocolCodec.swift` | Add optional outbound message UUID with backward-compatible default. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeProviderStreamResult.swift` | Define complete-envelope and translation-wrapper DTOs, separate from usage identity. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift` | Extract complete envelopes before flattening; share parsing with existing translation; retain legacy output API. |
| `Sources/RepoPromptAgentCore/AI/Providers/AIProviderFactory.swift` | Add the core atomic envelope-delivery shape to stream results without changing existing initializers’ behavior. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` | Map envelope DTOs and ordered companions; remain the single package import point. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | Capture outbound context before awaits, encode UUID, and emit atomic complete-envelope deliveries on the qualified path. No launch-argument changes. |
| **New:** `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeHistoryIdentity.swift` | Shared normalization, deterministic IDs, canonical payload fingerprinting, and inert projection. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | Use shared projection; retain envelope evidence before dedup; add proven metadata/graph classifications and thinking support. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | Validate conflicts before planning; produce envelope receipts; handle multi-user associations; fix canonical output enumeration and nil-item classification. |
| **New:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ClaudeNativeIdentity.swift` | Dedicated app reducer, canonical validation, transaction staging, and degraded rendering behavior. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Route envelope deliveries before generic companions; protect identity-owned rows from generic terminal text replacement; reuse owner save acknowledgements. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | Add coherent batch staging support only if existing paired mutation APIs cannot install rows and ledger before notifications. Keep state ownership here. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Record outbound identity on new baselines; use strengthened preflight and canonical-snapshot revalidation; preserve cursor-second ordering. |
| `docs/architecture/provider-plugins.md` | Document atomic envelope seam, native versus API identity, qualified-path routing, and exclusions. |
| **New evidence note under** `docs/context/plans/evidence/` | Record verified contracts, profile matrix, fixtures, validation method, and remaining qualification blockers. Do not edit the lossless-restart plan body. |

**Expected unchanged:** `AgentSessionDataService.swift` and `AgentTranscriptServices.swift`. Reuse their persistence and canonical-transcript ownership. Change them only if the call-site audit proves the existing owner transaction cannot meet the stated ordering; do not preemptively introduce another save path or compaction rewrite.

**Additional source validation required:** adapter/router definitions and complete stream/save implementations were not supplied. Identify their exact files during the initial read-only trace. Any value-copying adapter must preserve the atomic envelope carrier; routing policy itself should not change.

### Acceptance tests

Add focused tests in the existing provider-package and app test directories:

| Test group | Required contracts |
|---|---|
| Codec / dispatch | UUID absent by default; exact canonical dispatch UUID when bound; aggregated constituent order; missing constituent refusal; cancellation and stale admission produce no write; concurrent operations cannot exchange UUIDs. |
| Translation / bridge | Distinct envelope UUIDs sharing one API message ID stay distinct; block ordinals survive; raw tool IDs survive; partial/replay UUIDs are not promoted; usage observations remain identical. |
| Shared projection | Live/history fixtures yield identical row and invocation IDs and digests; structured input key ordering does not change digest; semantic changes do. |
| Reducer | One envelope materializes once; all content companions suppressed once; usage/finalization preserved once; active/background and old/new source interleaving remain isolated. |
| Conflict handling | Same-key text/tool changes, removed blocks, changed block count, empty-envelope changes, and verified retractions are detected before dedup; existing canonical rows are not silently rewritten. |
| Multi-user recovery | One native user UUID associates every dispatch constituent; missing, duplicate, foreign-session, legacy, and partial associations refuse. |
| Canonical backing | Subsequent persisted turns are included; compacted relevant backing refuses; suffix-only repair is impossible; hidden thinking is not classified as a user. |
| Persistence cuts | Before bytes, after row/ledger save but before cursor CAS, failed save, delayed ordinary save, pending-receipt retry, reset, and stale source ownership. |
| Reader profile | Routine metadata fixtures interleaved with messages; proven invisible graph nodes; thinking; unsupported compaction/attachment/semantic extras; existing graph and file-safety cases. |
| Production exclusion | Default construction remains OFF; custom/GLM/Kimi/wrappers retain existing encoding and rendering; no partial/replay launch flags appear. |

Fixtures and injected save failures are source-contract evidence only, never live acceptance.

## 5. Risks and migration

- **Historical and live envelope shapes may differ.** Only fixtures proving the same session/envelope/block projection qualify that shape. Do not compensate with text matching or API-message grouping.
- **New identity metadata can become stale through ordinary rendering.** Protect identity-owned rows from generic text replacement and validate stored payloads before reconciliation.
- **Old snapshots can erase new evidence.** Keep all receipt-producing operations ordered through the current owner-save path; test delayed saves explicitly.
- **Legacy sessions lack sufficient evidence.** Preserve them and refuse qualified overlap rather than synthesizing associations.
- **Metadata support may remain the ordinary-history blocker.** Report that separately from successful UUID plumbing and projection tests.
- **Downgrade remains decoding-compatible, not recovery-safe.** Follow the existing clean-quit and recovery-resolution requirement.

## 6. Implementation order

1. **Trace missing source seams and establish fixtures.**<br>
   Locate translator entry points, atomic event emission, adapter copies, and owner-save serialization. Record public pinned identity evidence and the metadata/profile matrix outside the plan body. No installed-runtime access.

2. **Add persistence shapes and shared identity primitives.**<br>
   Land additive decoding/encoding, deterministic projection, fingerprints, and legacy/refusal tests. No operational behavior changes.

3. **Add outbound association plumbing.**<br>
   Land codec, task-local, coordinator, handoff validation, and baseline changes together. Exercise multi-item dispatches and pre-byte failure cuts. Existing production gate stays OFF.

4. **Add complete-envelope transport.**<br>
   Land package wrapper, core carrier, bridge, controller emission, and any required adapter-copy updates atomically. Legacy consumers remain unchanged.

5. **Add live materialization and transaction integration.**<br>
   Land the reducer and generic-companion interception together. Verify usage/finalization, active/background routing, save failures, and immutable canonical payloads.

6. **Unify reader/import validation and association preflight.**<br>
   Land conflict-before-dedup, envelope receipts, multi-user preflight, canonical enumeration fix, and canonical snapshot checks together. Add only metadata/graph support established in step 1.

7. **Run bounded source acceptance and document status.**<br>
   Report identity source contracts separately from ordinary-format support and installed/live qualification. Keep all activation and final live acceptance OFF.

For implementation reviews, attach the supplied repository review policy verbatim to each Oracle request and follow its independent-lane and round limits. Store findings and validation evidence outside the plan body. Only owner answers belong in Decisions; interpretations belong in evidence or status `assumed:` fields.

## Recommendations

- **Use the existing dispatch UUID and ordered constituent list.** It is the smallest robust multi-item association.
- **Use a narrow immutable task-local.** Do not widen all provider interfaces.
- **Transport complete envelopes atomically, then reduce before flattened companions.**
- **Keep hints separate from completed materialization; compare payloads before dedup.**
- **Refuse retractions, uneditable compacted overlap, and unproven native shapes honestly.**
- **Finish source-contract work now; keep production activation, installed-provider qualification, final live acceptance, and helper shutdown out of scope.**

## Targeted continuation after pinned TS verification

Operation `775F3C0C-D84A-4D3C-A862-001381DE8A41`; same inherited preset verified. Full response follows; this narrows/supersedes initial recommendations where stated.

# Oracle Plan

## Summary

Proceed with the outbound-only first commit. **Supply the dispatch UUID only for a newly recorded, explicitly qualified baseline; omit it on `alreadyRecorded`.** Preserve existing retry/send behavior without claiming exactly-once delivery. Subsequently, extend the existing completed ledger with envelope evidence and add one sticky, profile-local refusal field—not two new collections. Production activation and installed/live qualification remain blocked.

## Current-state analysis

The supplied source account identifies the relevant chain: coordinator → operation-owner TaskLocal/admission → controller → codec. `dispatchID`, `runAttemptID`, and ordered `userItemIDs` already exist; encoding currently omits UUID. Admission can return `alreadyRecorded`, which proves neither that previous bytes were written nor that they were not.

`NativeItem` represents completed materialization. Baseline associations are therefore **hints, not completed ledger entries**. Existing owner-save ordering—canonical rows, ledger, receipt, then cursor CAS—remains the transaction boundary.

The new TS evidence strengthens caller-UUID and retraction contracts, but does not establish universal wire/native UUID or block-grouping equality. This continuation uses supplied evidence only; no additional source inspection or execution occurred.

## Design

### 1. First commit: outbound UUID and honest baseline association

#### Retry contract

| Admission outcome | Outbound caller UUID | Association treatment |
|---|---|---|
| Newly recorded, qualified baseline | Canonical `dispatchID` UUID string | Persist explicit association proof before bytes |
| `alreadyRecorded`, including a legacy baseline | **Omit** | Do not create, upgrade, or reuse association proof |
| Existing allowed-but-unqualified outcome | Omit | Preserve existing send behavior |
| Existing admission rejection/save failure | No write | Preserve existing failure behavior |

Choose omission rather than reuse or refusal:

- **Reuse** could give two physical sends the same identity without a provider deduplication guarantee.
- **Refusal** would introduce a retry-policy change outside this slice.
- **Omission** preserves sending while making the retry ineligible for caller-UUID association.

Do not replace the UUID with a freshly generated one: that would require recording another attempt association.

An existing baseline’s proof remains evidence for its original admission only. If that attempt never wrote bytes, there may be no matching native row. If an omitted-UUID retry appears in history, it remains unassociated and must block reconciliation of the affected range. Future reconciliation must examine all relevant user entries, not discard the retry before association checks.

#### Persisted proof and multi-user completeness

Add optional `DispatchBaseline.nativeUserEntryID`, absent by default. Its documented meaning is:

> This baseline was durably recorded for a newly admitted send whose encoder was instructed to supply this UUID.

It is **not** proof of delivery, native persistence, or fsync.

For qualified admission:

- Require a nonempty, duplicate-free ordered `userItemIDs` list.
- Resolve every constituent to its canonical user item; never use filtering that silently drops missing constituents.
- Preserve the complete order unchanged.
- Scope the association to the baseline’s provider/session and dispatch/run identities.
- Persist the proof with the existing baseline transaction before sending.
- Missing or inconsistent constituent evidence makes this send unqualified; retain the existing admission policy rather than inventing another rejection policy.

One matching native user envelope associates with the entire ordered constituent list. Do not select only the first user or manufacture per-user native UUIDs.

Legacy baselines remain unchanged, including when encountered through `alreadyRecorded`. Retain schema version and unknown-field preservation.

#### Plumbing

Use a Claude-specific immutable TaskLocal context alongside existing `writeAdmission`; do not widen every provider’s `sendUserMessage` interface.

The controller captures the context before suspension. **The final outbound UUID must be selected after admission**, using a local immutable value:

- newly recorded qualified admission → captured UUID;
- every other successful admission → absent.

A TaskLocal containing only the candidate UUID is insufficient if the controller cannot observe `alreadyRecorded`.

The exact current admission return signature was not supplied. Validate whether its disposition already reaches the controller. If erased, expose it through a narrow Claude-specific admission callable/result in that context, backed by the same admission implementation. Execute admission **once**; do not add a second reservation or mutable TaskLocal “result box.”

Codec change:

- Before: `encodeUserMessage(text:sessionID:)`
- After: add optional `messageUUID`, defaulting to absent.

Only the existing OFF-gated built-in Claude path supplies it. Cancellation/stale-owner checks remain before bytes. No parser, reducer, launch-option, partial-output, or replay changes belong in this commit.

### 2. Subsequent reconciliation: one completed-ledger extension is sufficient

**Yes, for a strictly supported, nonempty direct-envelope profile.** Separate `materializedEnvelopes` and `identityIssues` collections are unnecessary.

Add optional envelope proof to each completed `NativeItem` belonging to the envelope:

- profile identifier;
- full normalized semantic-payload fingerprint;
- expected completed-ledger row count;
- native envelope ID, **only if the existing ledger cannot already expose it unambiguously**.

Reuse existing provider/session/row identity fields. Repeat the same proof on the envelope’s rows; this avoids a separate authority or an arbitrary “leader” row.

The fingerprint must cover all supported semantic content, original block order, and raw tool IDs—not flattened text alone. Use an explicitly specified canonical representation that preserves scalar distinctions. Exclude only profile-established nonsemantic fields.

For each incoming envelope, before any suppression:

1. Validate the entire envelope against the pinned direct profile.
2. Compute its full fingerprint and deterministic expected row-key set.
3. Locate existing rows for its provider/session/envelope.
4. Require matching profile, fingerprint, expected count, and exact distinct row-key set.
5. Validate their canonical materialization/association.
6. Only then treat the envelope as completed.

An overlapping legacy ledger without proof, partial group, conflicting payload, or inaccessible compacted backing refuses reconciliation. A count alone is insufficient.

Stage every envelope’s canonical changes, ledger rows, and existing receipt atomically through the owner-save path; advance the cursor only after acknowledgement. Do not suspend between canonical and ledger staging.

**No zero-block framework:** an envelope with no representable ledger rows is outside this profile and refuses. Hidden content is supported only if the profile explicitly represents its completed nonprojection; otherwise refuse.

#### Narrow persisted refusal

Add one optional `claudeDirectEnvelopeRefusal` field to the existing recovery envelope, not a synthetic completed `NativeItem`.

Store originating session ID, optional envelope ID, and a typed reason:

- `unsupportedProfile`
- `normalizedIdentity`
- `retracted`
- `conflictingPayload`
- `incompleteEvidence`
- `compactedBacking`

This is a sticky latch blocking Claude direct-profile reconciliation for that recovery record until its existing reset. Preserve the first refusal; unknown serialized reasons also block and round-trip unchanged.

Persist it through ordinary owner saves. A failed save leaves an in-memory blocker and no cursor advancement—not a claim of durable refusal. This latch is necessary where a live semantic signal might not be reconstructible from later history.

### 3. Exact qualification boundary

The eventual safe source-complete claim is:

> For the explicitly pinned direct-envelope profile, synthetic/public fixtures establish caller association, complete-envelope projection, full-payload conflict checks before deduplication, atomic completed-ledger persistence, and refusal outside that profile.

It does **not** establish universal wire/native equivalence, ordinary-history completeness, installed CLI/wrapper qualification, or recovery activation.

Verified `supersedes`, aborted assistant output, and fallback retractions are refusal inputs—not permission to invent replacement mappings. Normalized per-block UUIDs and tombstoned tool results remain unsupported. Graph-bearing progress/system/attachment records cannot be blanket-skipped; semantic compact summaries and sole-output structured attachments cannot be discarded.

Build nothing beyond profile-local typed refusal for these cases now. Installed producer/native-format matching and final live acceptance remain pending; they do not block the outbound source slice.

## File-by-file impact

Using the previously supplied paths:

- `AgentSessionProviderHistoryRecovery.swift`: optional baseline proof; compatibility tests. Later, ledger proof and refusal latch.
- `AgentProviderHandoff.swift`: complete ordered constituent validation.
- `AgentRuntimeLaunch.swift`: narrow immutable Claude TaskLocal context/disposition plumbing.
- `ClaudeAgentModeCoordinator.swift`: construct and bind context under existing eligibility.
- `ClaudeNativeProcessSessionController.swift`: select UUID from actual admission outcome; retain fencing.
- `ClaudeSDKProtocolCodec.swift`: optional UUID encoding.

Exact test filenames and admission signature require source validation; do not invent parallel APIs to compensate.

## Implementation order

1. Trace admission-result propagation and add tests for new admission, `alreadyRecorded`, legacy baseline, multi-user completeness, cancellation, and concurrent-context isolation.
2. Land baseline proof, completeness validation, context/controller selection, and codec change **atomically**. Verify default production bytes remain unchanged.
3. Separately implement ledger proof/refusal and the supported reconciliation profile with conflict-before-dedup tests. Do not label outbound completion as reconciliation completion.

Keep evidence outside the plan body; only owner answers enter Decisions. Apply the supplied review policy before implementation commits.

## Recommendations

Proceed now with the outbound-only slice and **omit UUID on `alreadyRecorded`**. Reuse the existing ledger for later envelope proof, with one sticky refusal field. Defer normalization/retraction handling, broader metadata support, helper shutdown, production activation, and final live qualification.
