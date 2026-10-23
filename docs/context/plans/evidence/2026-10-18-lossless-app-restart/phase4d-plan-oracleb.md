# Claude identity resolution — OracleB planning

Scope: read when the task touches implementation of the Claude history-identity prerequisite under owner O15.
Authority: Reference
Last-verified: 2026-10-23

Exact preset: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; chat `claude-identity-resoluti-DCE5EB`; operation `CA5AFAFF-8AF9-4D31-919A-13CCE3D28A57`. Full independent response retained below. These are recommendations, not owner Decisions; main dispositions are in [resolution evidence](phase4-prerequisite-resolution.md).

# Oracle Plan



# Plan: native Claude history identity for lossless restart (Phase 4 prerequisite)

## 1. Summary

Today a Claude history import into a live conversation is always refused. Nothing ties a native JSONL entry to a local transcript item. Live output gets random item and invocation IDs, the outbound user message carries no UUID, and the preflight looks for ledger user associations that nothing in this build ever writes.

The smallest complete fix makes identity deterministic on both sides, using functions that already exist:

1. **Outbound user message.** Every gated Claude dispatch sends its existing `dispatchID` as the streamed user message's `uuid`. The dispatch's immutable `DispatchBaseline.userItemIDs` already lists all of its local user items in order, so a single-item send and a multi-item send associate the same way. No new persisted field is needed.
2. **Live output.** Complete `assistant`/`user` envelopes carry a native-row identity carrier (session, entry UUID, block ordinal, row kind, raw tool-use ID) through the existing translator → bridge → `AIStreamResult` path. A small reducer step in `applyStreamResult` assigns each live row the same deterministic ID that `ClaudeSessionHistoryReader` gives the matching JSONL row.
3. **Preflight.** The ledger-`localItemID` user check is replaced by an exact entry-UUID ↔ dispatch-baseline match. The suffix/compaction refusals, the owner-save transaction and the cursor CAS stay as they are.
4. **Reader.** The decoder subset grows only by what the pinned SDK chain model needs: graph-only `system`/`progress`/`attachment` nodes, ignored `file-history-snapshot` lines, and validated but never-projected `thinking` blocks. Compaction, sidechains, `isMeta` and API-error messages stay real refusals.

Every unproven assumption fails closed as a typed refusal: no duplicated rows, no misattribution. Everything that changes production behavior sits behind the existing `capturesDispatchBaselines` gate, which stays OFF. The one exception is the deterministic tool invocation ID for built-in Claude, justified in §3.C.

This is a targeted change, not a refactor. The architecture (owner-operation TaskLocals, provider-owned translator DTOs, one owner save followed by a cursor CAS) already has the right extension points.

---

## 2. Current-state analysis

### Outbound path
`ClaudeAgentModeCoordinator` (lines 2053–2130):
- computes `handoff.dispatchBaselineIdentity`, which yields `dispatchID` = first receipt `attemptID`, plus `runAttemptID` and the ordered `userItemIDs`;
- binds `AgentRuntimeOperationOwner.$session` and `.$writeAdmission`;
- calls `controller.sendUserMessage(providerBoundText)`.

`ClaudeNativeProcessSessionController.sendUserMessage`:
- fences;
- runs `writeAdmission`, which calls `admitClaudeDispatchBaseline` → `captureClaudeDispatchBaseline`. That commits the zero-row receipt and baseline before any bytes;
- encodes with `ClaudeSDKProtocolCodec.encodeUserMessage(text:sessionID:)`, which sends no `uuid`.

### Baseline
`captureClaudeDispatchBaseline` (RecoveryActions 846–959) returns early when the gate `recoveryActionRunner.capturesDispatchBaselines` is off or the agent isn't `.claudeCode`. It records a `DispatchBaseline` (captured or unsupported) keyed by `dispatchID`, and returns `.alreadyRecorded` for a dispatch that already has one.

### History read
`ClaudeSessionHistoryReader.decode`:
- validates the whole complete-line candidate, refusing any entry type other than `user`/`assistant`, any `subtype`, and any content block other than `text`/`tool_use`/`tool_result`;
- derives row IDs as `deterministicUUID("rpce-claude-history-row-v1", [provider, session, entryUUID, kind, ordinal])` and tool invocation IDs as `deterministicUUID("rpce-claude-history-tool-v1", [provider, session, toolUseID])`;
- filters out ledger-known rows before returning, so known rows never reach the planner.

### Preflight
`AgentProviderHistoryAssociationPreflight.check`:
- requires every `baseline.userItemIDs` to be the `localItemID` of a ledger userText row. Nothing writes that, so it always refuses (by design today);
- refuses any observation row with `item == nil`;
- requires canonical output after the dispatch ⊆ ledger `localItemID`s ∪ observation item IDs;
- refuses compacted turns (`.notEnumerable`).

### Planner and commit
`AgentProviderHistoryImportPlanner.plan`:
- dedups by ledger key, then by `existingItemIDs` (suffix only, at the RecoveryActions call site);
- appends new items behind a label.

The commit goes through the owner save (`pendingHistoryImportCommit` → `saveAgentSession(committingHistoryImport:)`), and the cursor CAS runs afterwards.

### Live stream
`handleStreamPayload` → translator `parseAssistantMessage`/`parseUserMessage` flattens each envelope into `ClaudeProviderStreamResult`s. The top-level `uuid`, `session_id`, block index and `tool_use_id` are lost. `resolveInvocationID` assigns a random `UUID()` per `tool_use_id`. Then `ClaudeCompatibleProviderRuntimeBridge.streamResult(from:)` produces an `AIStreamResult`, which reaches `AgentModeViewModel.applyStreamResult`:
- `content` → `enqueueAssistantDelta`, which merges into a streaming row. Consecutive text blocks become one item, so a row-level identity is impossible.
- background content → `applyBackgroundAssistantDelta`.

### Reusable pieces
- `dispatchID` and `DispatchBaseline.userItemIDs`
- the TaskLocal owner pattern
- `AgentChatItem.replacingID`
- `deterministicUUID`
- the owner-save transaction and `outputItemIDs`/`.notEnumerable`
- `recordBackgroundRows` (records whatever is appended after the delivery starts)

### What blocks import today
- no outbound UUID;
- no identity on live rows;
- content merging in the reducer;
- the preflight's unwritable user-association requirement;
- the reader refusing chain metadata and `thinking`, which ordinary histories plausibly contain.

---

## 3. Design

### A. Outbound user-message identity (answers Q1 and Q2)

**Decision: reuse `dispatchID` as the outbound `uuid`, and associate through the baseline. No new ledger or baseline field.**
- `DispatchBaseline.dispatchID` already *is* the outbound UUID, and `userItemIDs` already holds the ordered constituents. A native userText entry whose `uuid` parses to a recorded baseline's `dispatchID` therefore associates **all** of that baseline's `userItemIDs`, all-or-nothing. Multi-item sends are covered exactly like single-item sends.
- `NativeItem` keeps its single `localItemID` (still `nil` for user rows, still meaning "not projected"). The association can be recomputed from `nativeEntryID` (observation or ledger) plus `dispatchBaselines` every time, so nothing extra is persisted and there is no new authority.

**At most one write carries a given UUID.** A new view-model helper (in `AgentModeViewModel+RecoveryActions.swift`):

```swift
func claudeOutboundUserMessageUUID(_ identity: AgentDispatchBaselineIdentity?, session: AgentTabSession) -> UUID?
// returns identity.dispatchID only if:
//   recoveryActionRunner.capturesDispatchBaselines && session.selectedAgent == .claudeCode
//   && identity != nil
//   && session.providerHistoryRecovery?.dispatchBaseline(dispatchID:) == nil   // first admission only
```

The "no baseline recorded yet" rule handles retries:
- If an earlier admission recorded a baseline, its bytes may have been written, so a retry sends **no** UUID. Its native entry then has no association, and the import refuses (fails closed). This matters because a duplicate UUID with different raw content would make the reader refuse the whole file (`conflictingDuplicate`) for good.
- If the earlier attempt never reached admission, no bytes were written, so binding again is safe.

**Plumbing: a TaskLocal next to `writeAdmission`.** Add to `AgentRuntimeOperationOwner` (`AgentRuntimeLaunch.swift`):

```swift
/// Caller-supplied native identity for the ONE user message this owner operation writes.
@TaskLocal package static var outboundUserMessageUUID: UUID?
```

Why a TaskLocal:
- It is the existing owner-operation mechanism.
- It is immutable for the binding's scope and has the same lifetime as `writeAdmission`.
- It leaves the controller protocol, Codex/ACP controllers and test fakes untouched.

A `sendUserMessage(_:messageUUID:)` parameter would widen every provider and fake.

Rules:
- The coordinator binds it in the same `withValue` nest only when the helper returns non-nil.
- `ClaudeNativeProcessSessionController.sendUserMessage` reads it **once at entry**, before the fence, into a `let`, and passes it to the codec. Other controllers never read it.
- Per the existing doc comment, `Task.detached` re-binding applies if the send path ever detaches. It does not today.

**Codec:** `encodeUserMessage(text:sessionID:uuid: String? = nil)`. When non-nil, add a top-level `"uuid"` (lowercased UUID string). When nil, the payload is byte-identical to today's.

**Unknown to settle before landing (blocks Slice 1):** the exact streamed-input key name. Quote it from the pinned SDK v0.2.173 `types.py`/transport source into evidence. If the pinned source doesn't name the key, Slice 1 is blocked rather than guessed.

Acknowledgement is never treated as proof that the native entry exists. If the entry is missing, the import refuses.

### B. Native reader profile (answers Q5)

The rule: support only what the pinned chain model needs to accept *ordinary* histories, and keep a real refusal for anything that changes meaning. `profileName` becomes `"nativeEntriesSubsetV2"`. It is recorded in new baselines and is not a gate; V1 baselines stay importable because the cursor is a complete-line boundary.

**Entry roles.** Replace `Entry.isAssistant` with `role: .user | .assistant | .graphOnly`.

| Input | Handling |
|---|---|
| `user`, `assistant` | Unchanged validation. `subtype` still refused on these. |
| `system`, `progress`, `attachment` | **Graph-only node**: requires `uuid`, parentUuid rules and `sessionId` match. Content ignored, no rows. `rejectedWhenTrue` still applies (sidechain/meta). `logicalParentUuid`, `compactMetadata`, `teamName` and `agentId` still refused. `system` with a `subtype` containing `compact` → `.metadata("compact", line)`. |
| `file-history-snapshot` | **Ignored line**: valid JSON object, no graph role. The `.fileHistorySnapshot` refusal case is no longer produced; keep the case for source compatibility or remove it if unused. |
| Any other type (`summary`, `queue-operation`, …) | Still `.entryType`. Extend only with pinned evidence. |
| `thinking` block (assistant only, string `thinking`, optional string `signature`) | New `RowKind.thinking`, deterministic `localItemID`, never projected. |
| `redacted_thinking` block (assistant only, string `data`) | `RowKind.thinking`, `text = nil`, never projected. |
| Empty or whitespace-only assistant text | Row kept with `localItemID`. `item(for:)` returns `nil`, matching the live path, which skips empty text. |
| Unknown top-level keys | Still accepted, consistent with the pinned SDK ignoring unknown keys. A uniform refusal would reject every history as the CLI adds fields. |

**Graph rule.** Effective children are a node's children minus graph-only subtrees that contain no user/assistant entry. Apply the existing branching, tip and parallel-group rules to effective children, and count only user/assistant entries as tips. A graph-only node whose subtree does contain messages must have exactly one effective child (pass-through).

This accepts:
- a trailing `turn_duration`-style system leaf;
- a progress side leaf;
- a system or attachment entry between two messages.

A graph-only node that opens a second message branch is still `.ambiguousBranch`. Tool-result association still requires the result's parent to be the call entry; a progress node in between is still refused. Complexity stays O(n) with one post-order pass.

**Before landing (blocks Slice 2):** quote the pinned `sessions.py` v0.2.173 transcript-entry type set and visibility filter into evidence. If it differs from `{user, assistant, progress, system, attachment}`, use exactly the pinned set. The `thinking`/`redacted_thinking` block shapes come from the public Messages API docs, not the SDK fixtures; cite that separately.

**Extracted shared identity functions** (in `ClaudeSessionHistoryReader`, used by both `project` and the live path):

```swift
package static func rowLocalItemID(nativeSessionID: String, nativeEntryID: String, kind: RowKind, ordinal: Int) -> UUID
package static func toolInvocationID(nativeSessionID: String, toolUseID: String) -> UUID
package static func payloadDigest(_ row: Row) -> String   // SHA-256 hex, length-prefixed [kind, text, toolName, toolUseID, inputJSON, isError]
```

**Ledger conflict check.** A new `Unsupported.ledgerConflict(String)`. In `.importAfter`, **before** the known-row filter, build a key → digest map from the ledger once. Any row whose key is known and whose ledger `payloadDigest` is non-nil and differs from the row's digest refuses the whole candidate. Old ledger items with no digest are not compared. Within one file, the existing `conflictingDuplicate` still applies; this covers replacement/rescan.

**Still refused, and it is the real format limit (stated, not hidden):**
- any session that has ever compacted (`compact_boundary`, `isCompactSummary`, `logicalParentUuid`);
- `isMeta` user entries (harness-injected model input);
- `isApiErrorMessage` assistant entries;
- sidechain markers;
- `queue-operation`/`summary` lines;
- image or other non-text `tool_result.content`;
- assistant-side `tool_result` blocks;
- a progress node between a call and its result.

So the claim is "ordinary short, uncompacted, subagent-free histories", not "complete ordinary support". Whether `-p --output-format stream-json` histories actually contain these classes is a live-qualification question and stays blocked.

### C. Live native-row identity carrier and reducer seam (answers Q3)

**Package DTO** (`ClaudeProviderStreamResult.swift`, additive):

```swift
public struct ClaudeProviderNativeRowIdentity: Sendable, Equatable {
    public enum Kind: String, Sendable { case assistantText, toolCall, toolResult, thinking }
    public let sessionID: String      // envelope top-level session_id
    public let entryUUID: String      // envelope top-level uuid
    public let kind: Kind
    public let ordinal: Int           // RAW index in message.content (skipped blocks still count)
    public let toolUseID: String?     // raw tool_use id / tool_result tool_use_id
}
// ClaudeProviderStreamResult gains: public let nativeRow: ClaudeProviderNativeRowIdentity?  (init default nil)
```

**Translator (`ClaudeSDKNDJSONTranslator`).** Attach `nativeRow` only when all of these hold:
- top-level `type` is `assistant` or `user` (never `message` or `stream_event`);
- non-empty string `uuid` and `session_id`;
- `parent_tool_use_id` absent or null. Sidechain envelopes get no carrier because their entries live in another file.

Carriers:
- assistant `text` → `.assistantText`, block index. A string-content fallback uses ordinal 0, matching the reader's `[.text(text)]`.
- assistant `tool_use` → `.toolCall` + id.
- assistant `thinking` → `.thinking`, only where a `reasoning` result is already emitted.
- user `tool_result` → `.toolResult` + `tool_use_id`, ordinal = raw index in the user content array.
- Assistant-side `tool_result`, `usage`, `message_stop` and `stream_event` results never get a carrier.

`contentMessageID` and `usageObservation` are unchanged.

**Deterministic invocation IDs, single-sourced in the translator.**
- Add an init parameter `invocationIDDeriver: (@Sendable (_ sessionID: String, _ toolUseID: String) -> UUID)? = nil`.
- `resolveInvocationID` uses the deriver when a session ID is known (the envelope's `session_id`, tracked on the translator) and caches the result in `invocationIDByToolUseID` as today. Otherwise it falls back to random, as today.
- Core injects `ClaudeSessionHistoryReader.toolInvocationID` for the built-in variant only.

This is deliberately ungated: it only changes opaque IDs, and calls, results and approval lookups keep reading the same translator map, so pairing can't diverge. Deriving in the reducer instead would split the source of truth from the approval linkage.

**Unknown:** the translator's construction site (controller vs bridge) and the built-in variant enum case (the one alongside `.glm`) must be located; neither is in the provided source.

**Bridge and core.**
- New core value `AgentProviderNativeRowIdentity { nativeSessionID, nativeEntryID, rowKindRaw, ordinal, toolUseID }`, defined next to `AIStreamResult` in `AIProviderFactory.swift`.
- `AIStreamResult.nativeRow` (init default nil).
- `ClaudeCompatibleProviderRuntimeBridge.streamResult(from:)` maps `Kind` → `ClaudeSessionHistoryReader.RowKind.rawValue` with an exhaustive switch, plus a type alias for the package DTO.

**View-model reducer seam (`applyStreamResult`, MainActor).** It runs after the delivery guard and before `switch result.type`:

1. `identityOn = recoveryActionRunner.capturesDispatchBaselines && session.selectedAgent == .claudeCode`, captured once per call.
2. If `identityOn` and `result.nativeRow` is set:
   - `nativeItemID = rowLocalItemID(...)`;
   - **Idempotency:** if `nativeItemID` is already in `session.items` or in any transcript turn's request/activity IDs, return. A replayed complete envelope changes nothing, and nothing is appended, so the background defer is a no-op.
3. Branches:
   - **`content` with `nativeItemID`:** do the existing pre-steps (clear reasoning status on an active run), call `flushPendingAssistantDelta`, end streaming on the delivery's current streaming assistant row through the existing segment-end path, then append a **complete, non-streaming** `.assistant(text).replacingID(nativeItemID)`. Never enqueue into the merge buffer.
     - Background: append through the background row-start path so the row becomes this source's current background row and later `final_content` still finds it. Refactor `applyBackgroundAssistantDelta` into "start row (optional ID)" + "append text".
   - **`tool_call` / `tool_result` / `reasoning`:** the existing branches build the item as today and apply `.replacingID(nativeItemID)` **only when they append a new item**. If a branch updates an existing row (for example an MCP-side result placeholder), it is never re-IDed; the import then refuses honestly.
   - **`final_content`, `usage`, finalization, active/background routing, `recordBackgroundRows`, notification provenance:** unchanged. `final_content` may rewrite the tail row's text; identity is kept, and text is deliberately not compared.
4. With the gate off, or no carrier, the existing path runs byte-for-byte. Results without a carrier (`stream_event` deltas, sidechains, rows created by `final_content`) keep random IDs, and an import that meets them refuses with `canonicalOutputAssociationUnavailable`.

**Unknowns (helper names, to locate in `AgentModeViewModel.swift`):**
- the background current-row registration inside `applyBackgroundAssistantDelta`;
- the streaming-segment-end helper;
- whether the `tool_result` branch appends a distinct `.toolResult` item or upserts.

If it upserts, document it and leave it; do not re-ID.

**Ordering, duplicates, drops.** One stream is strictly ordered. Duplicates are idempotent. A dropped envelope leaves a missing live row, which the import later appends as a recovered row. Live persistence is sequential, so persisted live rows are a prefix of the dispatch's output, and appended history rows are a correct-order suffix.

### D. Association preflight and atomic import (answers Q4)

**`AgentProviderHistoryRow`** gains two additive init parameters with defaults, so the Codex projection is unaffected:
- `localItemID: UUID?` (default `item?.id`): the deterministic identity even when not projected (thinking, empty text);
- `payloadDigest: String?` (default nil).

`ClaudeSessionHistoryReader.observation(_:)` fills both.

**`NativeItem`** gains `payloadDigest: String?` (known key `"payloadDigest"`, `encodeIfPresent`). Old JSON decodes it as nil; old builds carry it through `extras`. The planner stores `row.payloadDigest`.

**`check(...)`.** The signature is unchanged; it reads `ledger?.dispatchBaselines`. The new user/association section:

```
baselineRefusal (unchanged) → canonicalOutputIDs (unchanged; nil → .baselineTargetMismatch)
recorded = ledger.dispatchBaselines filtered to (providerRaw, conversationID, transcriptResetGeneration)
nativeUserEntryIDs = observation userText rows' nativeEntryID ∪ ledger userText NativeItems' nativeEntryID (this conversation)
1. start: some id in nativeUserEntryIDs with UUID(id) == baseline.dispatchID   else .nativeUserAssociationUnavailable
   (the reader dedups an entry UUID, so a match is unique; all baseline.userItemIDs are associated together)
2. every OBSERVATION userText row: UUID(nativeEntryID) == some recorded.dispatchID whose userItemIDs are non-empty
   and all present in canonical (turn requests/activities or suffix)              else .nativeUserAssociationUnavailable
   (steering dispatches qualify only if they recorded a baseline; otherwise refuse)
3. delete the blanket `rows.contains { $0.item == nil }` check (user rows handled by 1–2; other nil-item rows carry localItemID)
4. .notEnumerable → .canonicalOutputAssociationUnavailable (unchanged)
5. associated = ledger localItemIDs ∪ observation rows' localItemID; canonical output ⊆ associated else refusal (unchanged rule)
```

How the specific failure cases resolve:
- **Retraction:** a live row the provider later dropped from history is absent from the observation, so step 5 refuses.
- **Live vs history mismatch:** kind is part of the hash, and invocation IDs are derived from the same function on both sides. So a live-vs-history structural mismatch can only appear as a non-associated ID, which step 5 already refuses. No separate check is added.
- **Compacted dispatch:** refused through `.notEnumerable`.
- **Suffix replacement:** never touches compacted backing.

**Planner call site (RecoveryActions ~1096).** `existingItemIDs` becomes the suffix IDs ∪ every transcript turn's `request?.id` and `allActivities` IDs, so a live row stored outside the suffix is recorded, not duplicated. `plan(...)` keeps its signature. Live rows already in the transcript take the existing "record, do not duplicate" branch, which writes a `NativeItem` with `localItemID` (completed materialization). Ledger rows are written **only** by the import commit; the live item ID is the only identity hint and never suppresses anything.

**Transaction:** unchanged. Rows, ledger and receipt go in one owner save (`pendingHistoryImportCommit`), then `commitHistoryCursor` CAS. A crash between the two replays as a no-op through ledger dedup.

**Refusal text:** the reader's `.unsupported` is already mapped generically in reconcile ("records this version doesn't support"). The new `ledgerConflict` case flows through that mapping. Exhaustive switches over `Unsupported` and `RowKind` will be flagged by the compiler; update each.

### E. Provider scope (answers Q6)

- **Source scope:** the outbound UUID and the identity reducer require `.claudeCode` and the gate. The deriver is injected for the built-in variant only. Import is already `.claudeCode`-only. GLM, Kimi and custom runtimes receive passive carriers but no behavior change.
- **Wrappers:** whether a user-overridden CLI executable is distinguishable at the launch resolver is unknown. If `ClaudeCodeLaunchEnvironmentResolver` exposes an override signal, also exclude it in the helper; otherwise record `assumed: built-in agent selection is the source qualification boundary`.
- **What is source-complete:** codec, TaskLocal, carrier, parity of deterministic projection, preflight, reader subset, and fixture tests.
- **What is not qualified:** whether the installed CLI honors a supplied `uuid`; whether live `AssistantMessage.uuid` and user tool-result envelope `uuid` equal the JSONL `uuid` for every block; which metadata classes `-p stream-json` actually writes; `--resume` session-ID continuity; dangling `tool_use` on resume. Each of these, if false, produces a refusal, never duplication.

---

## 4. File-by-file impact

| File | Change | Why / dependencies |
|---|---|---|
| `Packages/.../ClaudeSDKProtocolCodec.swift` | `encodeUserMessage(text:sessionID:uuid: String? = nil)`; top-level `"uuid"` when non-nil | A. Independent. |
| `Sources/.../Recovery/AgentRuntimeLaunch.swift` | `@TaskLocal package static var outboundUserMessageUUID: UUID?` on `AgentRuntimeOperationOwner` | A. Independent. |
| `Sources/.../SDK/ClaudeNativeProcessSessionController.swift` | `sendUserMessage` reads the TaskLocal once at entry and passes it to the codec. Translator construction injects `invocationIDDeriver` for the built-in variant (locate site). | A, C. After codec, TaskLocal and reader helpers. |
| `Sources/.../Claude/ClaudeAgentModeCoordinator.swift` | Compute `outboundUUID` from the VM helper; bind `$outboundUserMessageUUID` in the existing `withValue` nest when non-nil | A. After the VM helper. |
| `Sources/RepoPrompt/.../AgentModeViewModel+RecoveryActions.swift` | Add `claudeOutboundUserMessageUUID(_:session:)`; widen planner `existingItemIDs` to transcript IDs | A, D. |
| `Sources/.../SDK/ClaudeSessionHistoryReader.swift` | Entry roles; graph-only nodes; ignored `file-history-snapshot`; `RowKind.thinking`; effective-children graph rule; `rowLocalItemID`/`toolInvocationID`/`payloadDigest` statics (and `project` uses them); `Unsupported.ledgerConflict`; ledger digest check before the known filter; profile `V2` | B, D. Pure; first. |
| `Sources/.../Recovery/AgentProviderHistoryImport.swift` | `AgentProviderHistoryRow.localItemID`/`payloadDigest`; preflight steps 1–5; planner stores the digest; `item(for:)` returns nil for empty assistant text and for `.thinking` | D. After reader. |
| `Sources/.../Models/AgentSessionProviderHistoryRecovery.swift` | `NativeItem.payloadDigest` (known key, optional) | D. |
| `Packages/.../ClaudeProviderStreamResult.swift` | `ClaudeProviderNativeRowIdentity`; `nativeRow` field | C. |
| `Packages/.../ClaudeSDKNDJSONTranslator.swift` | Carriers with raw ordinals; session tracking; `invocationIDDeriver` | C. After DTO. |
| `Sources/.../ClaudeCompatibleProviderRuntimeBridge.swift` | Alias and map `nativeRow`; expose the deriver closure | C. |
| `Sources/.../AI/Providers/AIProviderFactory.swift` | `AgentProviderNativeRowIdentity`; `AIStreamResult.nativeRow` | C. |
| `Sources/RepoPrompt/.../AgentModeViewModel.swift` | Pre-switch identity step, idempotency, non-merging identified content, `replacingID` on new tool/reasoning items, background row-start refactor | C. After bridge and reader statics. |
| Tests (`RepoPromptClaudeCompatibleProviderTests`, `Tests/RepoPromptTests/AgentMode/{ClaudeCompatible,Recovery,History}`) | See §6 | Per slice. |
| `docs/architecture/provider-plugins.md` | Optional, deferrable: one paragraph on `nativeRow` | Docs only. |

**Not changed:** `AgentSessionDataService`, `AgentTabSession`, `AgentTranscriptServices`, `AgentProviderHandoff` (its `dispatchBaselineIdentity` is reused), and the plan body.

---

## 5. Risks and migration

- **Schema:** only additive. `NativeItem.payloadDigest` is optional; the ledger stores `rowKindRaw "thinking"` as a plain string. The session stays at version 7, and older builds round-trip unknown members. No migration.
- **Production behavior with the gate OFF:**
  - outbound bytes unchanged (helper returns nil);
  - reducer unchanged;
  - carriers passive;
  - **only** visible change: built-in Claude tool invocation IDs become deterministic UUIDv8.

  Risk: something assumes v4 or cross-session uniqueness. Mitigation: a pairing/approval regression test. Reversible by not injecting the deriver.
- **Duplicate-UUID poisoning:** prevented by the first-admission rule. If it happens anyway, the reader refuses (fails closed).
- **Gated code paths:** while the gate exists there are two content reducers (identified vs merged). When the gate retires, the merged path for built-in Claude should go too. Record that as deferred, not as a new flag.

---

## 6. Implementation order (slices, each independently compilable and testable)

**Slice 1: outbound identity.** Codec, TaskLocal, controller read, VM helper, coordinator bind. Blocked until the pinned key-name quote is in evidence.
- Tests:
  - the codec emits lowercase `uuid` only when given, and nil is byte-identical;
  - the controller payload carries the bound UUID and has none when unbound;
  - admission refusal writes zero bytes;
  - the coordinator doesn't bind when the gate is off, the dispatch is untracked, or a baseline already exists, and binds `dispatchID` otherwise.

**Slice 2: reader subset V2 and shared identity statics** (pure; can run in parallel with Slice 1).
- Accept fixtures:
  - system leaf, progress side leaf, attachment pass-through, `file-history-snapshot`;
  - `thinking`/`redacted_thinking` rows with deterministic IDs;
  - empty text row.
- Refuse fixtures:
  - `compact_boundary`, `isMeta`, `queue-operation`;
  - graph-only node opening a second message branch;
  - progress between a call and its result.
- Other tests:
  - a user entry with `uuid` = X yields a userText row with `nativeEntryID` X;
  - `project` output is unchanged for V1 fixtures, with identical IDs.

**Slice 3: live carrier and reducer seam** (needs the Slice 2 statics).
- Translator tests:
  - raw ordinals across [thinking, empty text, text, tool_use];
  - sidechain, missing `uuid` and `stream_event` produce no carrier;
  - user `tool_result` carrier;
  - string-content ordinal 0;
  - usage unchanged.
- Deriver tests: call and result share an ID equal to `toolInvocationID`; with no deriver, behavior is legacy.
- Bridge mapping test.
- **Parity contract test:** the same native JSON sent as a live envelope (translator → bridge → `rowLocalItemID`) and as a JSONL line (reader) yields identical item and invocation IDs for every kind.
- VM tests (gate on):
  - consecutive identified texts produce two items;
  - a replayed envelope is a no-op;
  - tool items carry deterministic IDs;
  - background rows are recorded and `final_content` replaces the identified row;
  - finalization and usage are unchanged.
- VM golden test (gate off): output identical to today's.

**Slice 4: association, conflict, import** (needs 1–3; land the preflight and planner-call-site edits together, atomically).
- Preflight tests:
  - single-item and **multi-item** dispatch match → passes and associates every `userItemID`;
  - foreign user UUID → `nativeUserAssociationUnavailable`;
  - steering entry matching another recorded baseline → passes; without a baseline → refuses;
  - random-ID canonical output → refuses;
  - retraction → refuses;
  - compacted → refuses;
  - live thinking associated through `localItemID`.
- Reader tests: digest conflict on rescan → `ledgerConflict`; no digest → accepted.
- Planner tests: live rows recorded, not appended; missing suffix appended in order behind the label; digest persisted; transcript-only IDs deduped.
- VM end-to-end (fixture `FileAccess`, gate on): baseline → identified live rows saved → a truncated save simulates a crash → reconcile imports only the missing suffix → a second reconcile is a no-op → a crash between save and CAS replays as a no-op.
- Persistence tests: `payloadDigest` round-trips; legacy JSON decodes; unknown keys survive.

Per the review policy, each slice gets OracleA/OracleB review. Evidence goes in the plan's evidence directory, and fixture results are labeled as fixtures, never as live.

---

## Recommendations

1. **Q1:** Use `dispatchID` as the outbound `uuid`, bound only on a dispatch's first admission. Associate the whole ordered `DispatchBaseline.userItemIDs` by exact entry-UUID match. This needs no new ledger or baseline field, and multi-item sends are covered rather than excluded.
2. **Q2:** Use a TaskLocal (`outboundUserMessageUUID`) next to `writeAdmission`, read once at the top of `sendUserMessage`, with an optional codec parameter. Don't widen the controller protocol.
3. **Q3:**
   - The minimum seam is one optional `nativeRow` carrier attached at envelope parse, before flattening, using raw block ordinals.
   - Tool invocation IDs are derived deterministically inside the translator.
   - One pre-switch reducer step assigns IDs, stays idempotent, and stops merging only identified content. Usage, `final_content`, finalization and routing stay untouched.
   - The parity test is the core contract.
4. **Q4:**
   - Keep the existing single owner save and cursor CAS.
   - Ledger rows are written only by that commit; the live item ID is the only hint.
   - Payload conflicts are checked in the reader before ledger dedup (digest).
   - Retractions and identity mismatches are caught by the canonical ⊆ associated rule.
   - Compacted backing refuses through `.notEnumerable`.
5. **Q5:** Accept graph-only `system`/`progress`/`attachment`, ignored `file-history-snapshot`, and never-projected `thinking`. Keep compaction, `isMeta`, API-error, sidechain, `queue-operation` and image results as real refusals, and state plainly that compacted or subagent-using sessions remain non-importable.
6. **Q6:** Restrict the contract to built-in `.claudeCode` behind the existing gate. GLM, Kimi, custom runtimes and wrappers are excluded. Source completeness ≠ qualification: every live identity assumption stays blocked and fails closed.

**Can safely stay blocked:**
- live CLI qualification (UUID honoring, live/native UUID equality, metadata classes in `-p` histories, `--resume` session continuity, dangling `tool_use`);
- compaction support;
- `isMeta`/`queue-operation` support;
- steering without baselines;
- `final_content`-created rows;
- unverified TS 0.3.309 `user_message_uuid(s)`/supersedes leads (no code until the types are verified);
- production gate activation.

**Record under `assumed:`** (reversible, so proceeding on these; owner may override):
- (a) deterministic invocation IDs ship ungated for built-in Claude;
- (b) profile bump to V2 with no gate;
- (c) the wrapper boundary is "built-in agent selection" unless the resolver exposes an override signal.

**Still to locate before or while implementing, not invented here:**
- the streamed-user `uuid` key quote and the `sessions.py` type set (these block Slices 1 and 2);
- the translator construction site and the built-in variant case;
- the VM background row-start and segment-end helpers;
- whether the `tool_result` branch appends or upserts.

## Targeted continuation after pinned TS verification

Operation `1AE7DF31-89B0-4C2D-9B13-4AA9AF803E67`; same inherited preset verified. Full response follows; this narrows/supersedes initial recommendations where stated.

# Oracle Plan



# Native Claude history identity: first slice, retry contract and minimum ledger evidence

## 1. First commit: outbound caller UUID with an explicit baseline claim

### Retry contract: omit the UUID on any admission that doesn't create the baseline

| Option | Behavior when admission returns `.alreadyRecorded` (earlier bytes unknown) | Verdict |
|---|---|---|
| Reuse the same UUID | If the earlier bytes landed, the CLI gets two user messages with one UUID. Native behavior is CLI-internal: it might deduplicate or drop the second one (which changes send semantics), or persist both (the reader then sees `conflictingDuplicate` and the whole file is refused for good). | Rejected |
| Refuse the send | Retry fails where it works today, which breaks existing send semantics. | Rejected |
| **Omit the UUID** | Bytes are the same as today's send. If the earlier write never landed, the claimed UUID never appears, so preflight refuses. If it did land, the extra user entry without a UUID matches no claim, so preflight refuses. Either way the result is honest. | **Chosen** |

**The decision sits inside admission, not in a coordinator pre-check.** The previous plan's helper read `dispatchBaseline(dispatchID:) == nil` in the coordinator. There is an `await` between that check and the admission that actually commits, so two different points would each decide. Instead, the existing `AgentRuntimeOperationOwner.writeAdmission` TaskLocal closure **returns** the UUID to put on the wire:

```swift
// before: writeAdmission: (@Sendable () async throws -> Void)?        (shape to confirm)
// after:  writeAdmission: (@Sendable () async throws -> UUID?)?       // nil = omit uuid
```

- `captureClaudeDispatchBaseline` returns the UUID only when **this call** records a new *captured* baseline with the gate on and agent `.claudeCode`. It returns nil for: gate off, untracked dispatch, `.alreadyRecorded`, or an unsupported baseline.
- `ClaudeNativeProcessSessionController.sendUserMessage` keeps admission's result as a `let` and passes it to `encodeUserMessage(text:sessionID:uuid:)`. With nil, the bytes are identical to today's.
- No new TaskLocal is needed, so drop the previous plan's `outboundUserMessageUUID`.
- Every other place that reads `writeAdmission` discards the result with `_ =`.
- **To check:** list every reader and binder of `writeAdmission`. If a non-Claude controller reads it, the change is still one line per site. If there are more than about 3 such sites, report back before widening.

### Proof stored in the baseline (additive, fixed when the baseline is first recorded)

Add one optional field to `DispatchBaseline`:

```swift
struct OutboundUserMessageClaim: Codable, Equatable { let uuid: UUID; let textSHA256: String }
var outboundUserMessage: OutboundUserMessageClaim?   // known key, encodeIfPresent
```

- The field is written in the same zero-row receipt and baseline commit that already happens before any bytes go out. That makes the claim durable before the UUID can exist on the wire.
- `uuid` = `dispatchID`. It is stored explicitly so association never infers it from `dispatchID`.
- `textSHA256` is computed over the exact provider-bound text.
- **Legacy baselines:** they have nil, so they never associate.
- **Rollback:** if an old build drops the unknown key, the baseline becomes legacy, and legacy refuses.
- **To check:**
  - Whether `DispatchBaseline` keeps unknown keys. Either answer is fail-closed.
  - Whether the controller changes `providerBoundText` before encoding. If it does, compute the digest from the text the controller actually encodes.

### Association proof in `AgentProviderHistoryAssociationPreflight.check` (replaces the ledger-`localItemID` user check)

1. The start baseline has a non-nil `outboundUserMessage`. Otherwise refuse with `.nativeUserAssociationUnavailable`.
2. Exactly one userText entry (from the observation or a Claude ledger `NativeItem`) has `UUID(nativeEntryID) == claim.uuid`. That entry has exactly one text block, and the SHA-256 of its text equals `claim.textSHA256`.
3. **Ordered multi-user completeness:** every item in `baseline.userItemIDs` appears in canonical exactly once, in baseline order, and none is missing. The match is all-or-nothing.
4. Every other userText row in the observation matches the claim of some other recorded baseline in the same conversation and generation, and passes steps 2–3 for that baseline. Otherwise refuse.
5. Remove the blanket `item == nil` refusal **only** for userText rows associated by steps 2–4.
6. Output association is unchanged. Live output still has random IDs, so any dispatch with persisted live output still refuses. That is correct for commit 1.

Nothing in this commit changes production behavior: with the gate off, no baselines are captured, so nothing is claimed, sent or imported.

**Tests:**
- Codec: nil gives identical bytes; non-nil adds a lowercase `uuid`.
- Admission:
  - `newCaptured` returns the UUID and persists the claim;
  - `.alreadyRecorded`, unsupported baseline, gate off and untracked dispatch all return nil;
  - admission that throws writes zero bytes;
  - a retry after a recorded baseline sends no `uuid`.
- Preflight:
  - single-item and multi-item dispatches pass;
  - each of these refuses: legacy baseline, missing entry, entry duplicated across observation and ledger, text-digest mismatch, multi-block user content, a missing, reordered or duplicated constituent, an unclaimed extra user entry, steering without a claim.
- Persistence: the claim round-trips; legacy JSON decodes with nil.

Withdraw the previous plan's ungated deterministic tool-invocation deriver. It breaks the "no ungated production changes" rule; move it into the reducer slice behind the gate.

---

## 2. Reconciliation evidence: one optional field on `NativeItem`, no new collections

**Yes, a single extension is enough.** Replace the previous plan's per-row `payloadDigest` with one field:

```swift
var envelopeDigest: String?   // NativeItem, known key, encodeIfPresent
```

- **What it covers:** SHA-256 over the envelope's full semantic payload, length-prefixed: entry type, the ordered list of every block (kind, raw ordinal, text, tool name, tool-use ID, canonical input JSON, result text, `isError`), and every block including ones that are never projected.
- **Stored on every `NativeItem` of the envelope.** The copy on each row is redundant, but it avoids a `materializedEnvelopes` collection.
- **No count field.** Because the digest covers the ordered block list, any added, removed or changed block changes it.
- **No zero-block persistence.** The supported profile is defined so every accepted envelope yields at least one row (empty assistant text and thinking keep their rows). An envelope that would yield zero rows is a profile refusal.

**Conflict check before dedup** runs in `ClaudeSessionHistoryReader`, `.importAfter`, before the known-row filter:

- Group observation rows by `nativeEntryID`.
- For any envelope with **any** ledger-known key, all of these must hold, or the reader refuses with `.ledgerConflict`:
  - the ledger key set for that entry equals the observed key set;
  - every one of those ledger rows carries the same non-nil `envelopeDigest`;
  - that digest equals the observed digest.
- Claude ledger rows with no digest refuse. In practice there are none, because Claude import has always refused. Codex is untouched.
- Envelope atomicity on write: the planner materializes all rows of an envelope or none.

**Overlap with live canonical rows** (reducer slice, needs no persistence): when an observation row's `localItemID` matches an existing canonical item, `item(for: row)` must be semantically equal to that item (text, tool name and input, result, `isError`) before the preflight treats it as already present. A mismatch refuses. This covers normalization, refusal-fallback rewrites and `final_content` edits without assuming raw wire output matches history.

**No persisted refusal is needed.** Retraction, supersede and refusal-fallback all leave canonical rows with no matching history counterpart: either the UUIDs are derived or the row is gone. Rule 5 (canonical ⊆ associated) already refuses these at every reconciliation, deterministically, from data that already exists. A persisted marker would only matter if the live reducer deleted or rewrote canonical rows on retraction. Instead, make that a contract for the reducer slice: **it must not apply `supersedes`, `aborted` or `retracted_message_uuids` to canonical rows.** `DispatchBaseline` stays immutable.

---

## 3. What the source can honestly claim, and what still needs live qualification

**Profile-local typed refusals to add now** (cheap, reader denylist only):
- `supersedes`, `aborted`, or any retraction-UUID key, at entry level or inside `message`;
- any refusal-fallback entry. This already refuses through `.entryType`/`subtype`; add a test that pins it.

Correction to the previous plan: drop the blanket graph-only acceptance of `system`/`progress`/`attachment`. A `structured_output` attachment can be the only persisted output, and a compact summary carries meaning. Leave those entries refused as they are today, with no metadata relaxation in these commits.

**Claim that is safe once the source work lands:**
> For built-in `.claudeCode` with the dispatch-baseline gate on (not activated):
> - a native user entry associates to local user items only through a caller UUID claimed in a baseline that was durable before any bytes were sent, with an exact text digest and complete ordered constituents;
> - history rows are imported only when every overlapping envelope is semantically identical to what the ledger and canonical transcript already hold;
> - any compaction, sidechain, metadata entry, retraction, supersede or abort marker, unsupported block, or ambiguous graph refuses with a typed reason, and the refusal leaves transcript, ledger and cursor unchanged.

**Not claimed (final live qualification, still pending):**
- that the installed CLI and wrapper persist the caller's streamed `uuid` as the native entry `uuid`;
- that live envelope UUIDs equal native UUIDs for each block, including tool-result user envelopes;
- that a missing marker means there was no retraction (the native entry union is CLI-internal);
- what share of ordinary `-p stream-json` histories fit the profile. Public fixtures show `progress`/`system`/`attachment` carry graph structure, so coverage **may be close to zero**; do not describe this as ordinary-history support;
- durability after acknowledgement (no fsync is assumed);
- session continuity across `--resume`.

Build nothing beyond the typed refusals: no supersede handling, no derived-UUID mapping from TS 0.3.309, no persisted issue log, no retention or tooling.

---

## Recommendations

1. **Commit 1:**
   - `writeAdmission` returns `UUID?`. It is non-nil only when this call records a new captured baseline.
   - Add `DispatchBaseline.outboundUserMessage {uuid, textSHA256}`.
   - Add the optional `uuid` codec parameter.
   - Rewrite the preflight user association: exact claim match, text digest, ordered all-or-nothing constituents.
   - Retries after `.alreadyRecorded` **omit** the UUID; legacy baselines never associate.
   - Drop the separate TaskLocal and the ungated deriver.
2. **Commit 2:** `NativeItem.envelopeDigest`, the envelope-grouped `.ledgerConflict` check before the known-row filter, all-or-nothing envelope materialization, and the reader refusals for `supersedes`/`aborted`/retraction markers.
3. **Commit 3:** the gated live carrier and reducer, with the semantic-overlap comparison and the rule that retraction events never mutate canonical rows. Move the deterministic deriver here, behind the gate.
4. Keep metadata entries refused. Report ordinary-history coverage as unqualified and possibly near zero, and leave all six live-qualification items above blocked.
5. **Record under `assumed:`** (reversible):
   - (a) omit-on-retry;
   - (b) one claim field on the baseline;
   - (c) digest-only, with no count;
   - (d) no persisted refusal.
6. **Validate during implementation:**
   - every reader and binder of `writeAdmission`;
   - whether `DispatchBaseline` keeps unknown keys;
   - whether the controller encodes `providerBoundText` exactly as passed;
   - the streamed-input `uuid` key, quoted from the verified `sdk.d.ts` `SDKUserMessage` into evidence.
