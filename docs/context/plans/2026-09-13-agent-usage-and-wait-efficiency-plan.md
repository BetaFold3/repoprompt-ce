# Agent usage accounting and worker wait efficiency plan

Scope: read when the task touches Agent Mode provider-reported usage and estimated cost, worker wait policy, or recoverable agent_run response presentation.
Authority: Reference
Last-verified: 2026-09-14

Status: Active. Phase 0 source inventory recorded in §2.1 (offline installed-version evidence only; live gates G1, G1-Codex and G3 remain open). Phase 1 observation transport is implemented; post-review remediation is implemented and focused coordinated validation passed (§2.3); fresh OracleA and OracleB re-reviews closed every P1 finding (§2.3). Phase 2 accounting/persistence and scoped remediations are implemented; final focused validation passed and fresh OracleA/OracleE reviews closed all P0/P1 findings (§2.4). Phase 3 UI and remediations are implemented, focused validation passed, and both OracleA/OracleB P1 findings are closed (§2.5). Phase 4 MCP response presentation and scoped remediations are implemented and validated; fresh OracleA and OracleB R2 reviews approved the remediation and explicitly closed every prior P1, clearing G2 for the deterministic/in-process scope (§2.6). Installed-app qualification remains unverified. Production G1 numeric accounting remains closed and `.unqualified`. Phase 2b and Phases 5–6 remain deferred.
Decision process: OracleE and OracleD, identical initial brief, two anonymous reciprocal challenge rounds.
User decisions: primary-only terminal excerpts accepted (§9.5); Codex CH and fetched-price API-equivalent cost included (§4.1). A separate OracleE/OracleD pricing consultation converged after two challenge rounds (§9.8).

## 1. Outcome and scope

Make three bounded improvements without replacing the runtime:

1. Prefer event-driven waits over repeated polling in workflow guidance.
2. Add trustworthy cache-read-share and cost readouts for both native Claude and Codex: provider-reported estimates for Claude, locally calculated API-equivalent token estimates for Codex.
3. Offer opt-in assistant-result trimming with exact, authorized recovery.

Keep the app's numeric wait default at **120 seconds**. Do not ship a universal 240-second cache-warming rule or a blanket 600-second recommendation. A longer wait already wakes early when a worker completes or needs input; its economic value depends on workload, provider, billing mode, and host limits.

The recommended first release uses a **separate session-owned usage record with turn summaries, Claude cumulative-cost checkpoints and Codex locally priced usage intervals**. It does not repurpose context estimates as billing data. Request-level diagnostics use bounded opt-in existing event capture and offline analysis, not a new live diagnostic UI or persisted request-history ring.

Non-goals: child-to-parent push; changing provider cache TTLs, credentials, subscriptions or permissions; automatic parent-plus-workers UI totals; numeric accounting for unqualified providers; general persistence/runtime refactoring; changes to release metadata. No source behavior is changed by this document.

## 2. Verified starting points

Line references identify the checkout inspected for this plan, not a guarantee against subsequent source movement.

| Boundary | Evidence and consequence |
|---|---|
| Event-driven wait | [AgentRunSessionStore.swift:361–445](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunSessionStore.swift#L361) parks continuations; terminal publication at 271–278 resumes them; 615–620 cancels their timeout tasks. Preserve this machinery. |
| Early and exceptional returns | [AgentRunMCPToolService.swift:2043–2128](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift#L2043) handles readiness, steering, interaction resolution, epochs and optional status updates. These are control contracts, not expendable metadata. |
| Full payloads | Service timeout/status responses at 2189–2209 call [AgentRunMCPSnapshot.asObject:400–459](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPSnapshot.swift#L400); multi-wait repeats the projection at 2902–2925 and 2969. Do not mutate stored snapshots to slim output. |
| Timeout authorities | [MCPTimeoutPolicy.swift:45–59](../../../Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift#L45): CLI 300, lifecycle wait 120. [AgentMCPToolHelpers.swift:11,85](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPToolHelpers.swift#L11): maximum 86,400 seconds. |
| Client deadline distinction | [InteractiveMCPClientSession.swift:965–977](../../../Packages/RepoPromptCore/Sources/RepoPromptMCPCore/Interactive/InteractiveMCPClientSession.swift#L965) extends deadlines for explicit semantic waits; omitted waits retain ordinary client policy. The code already references the shared policy, so shared-constant access is not an unresolved import question. |
| Gateway | [RemoteCommandTranslator.swift:17–55](../../../Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift#L17) mirrors 120, with 30-second grace and 900-second cap. [Package.swift:153–156](../../../Package.swift#L153) already links RepoPromptShared. Public poll maps to poll at 158–162; [SessionWatchManager.swift:1376–1391](../../../Sources/RepoPromptGateway/Watch/SessionWatchManager.swift#L1376) separately calls wait. Do not invent a public gateway wait mapping. |
| Lost usage fields (pre-Phase-1 baseline) | Before Phase 1 the package translator read `cache_read_input_tokens`/`cache_creation_input_tokens` but the split did not survive onto the stream DTO. Phase 1 now preserves it on the optional observation companion (§2.2); `total_cost_usd` stays on the existing `cost` field. Terminal context usage is still deliberately absent: billed-turn totals are not context occupancy. |
| Cost propagation/drop | [Bridge:260,283](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift#L260) preserves `cost` in both mapping directions; the [AgentModeViewModel.swift:2790–2796](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L2790) `finalizeNonCodexTurnUsage` closure forwards only `promptTokens`/`completionTokens`/`contextUsedTokens`, so cost is dropped at finalization. |
| Existing persistence is not billing | [AgentSession.swift:38–124](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift#L38) defines context/estimated-token rows with custom coding. The session envelope also has explicit initializer/coding paths, including 491–619. Inventory every save/hydration projection before adding a field. |
| Positive live attribution needed | [ClaudeNativeProcessSessionController.swift:1483–1548](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift#L1483) detects a raw `type == "result"` payload and `emit(.stream(result))` runs before the `hasPendingTurnIDs` guard. There is no original-result marker on the DTO and no monetary live/replay gate. Neither raw-result detection nor queue presence alone proves a chargeable live turn. |
| Branch ownership | No `AgentSessionBranchSnapshotBuilder` exists (zero matches). Existing handoff/fork paths copy transcript content, not `providerTokenUsageByTurn`; see §2.1. Never count inherited rows as newly incurred destination spend. |
| ACP wiring gap | [AgentModeViewModel+ContextUsage.swift:5–11](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ContextUsage.swift#L5) returns no non-Codex estimator for ACP providers. Preserving fields alone does not implement their persistence. |
| Recovery limitation | [AgentManageMCPToolService.swift:385–443](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentManageMCPToolService.swift#L385) pages whole turns as transcript XML. One turn can be large; it is not exact bounded terminal-result retrieval. |
| Presentation and replay | [AgentRunMCPToolService.swift:414–451](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift#L414) `executeIdempotentMutation` hashes arguments with the registry default exclusion (`request_id` only) and records the canonical value. [MCPRequestIdempotencyRegistry.swift:117–131](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/MCPRequestIdempotencyRegistry.swift#L117) `payloadHashHex(args:excluding:)` supports caller-specified excluded keys. `response_mode` does not exist anywhere under `Infrastructure/MCP/Agent`. |
| UI insertion | [AgentRuntimeSidebarView.swift:79–83](../../../Sources/RepoPrompt/Features/AgentMode/Views/RuntimeSidebar/AgentRuntimeSidebarView.swift#L79) contains existing context presentation; keep new usage projection separate from its context-window math. |

### 2.1 Phase 0 inventory (verified 2026-09-13)

Evidence class: **source-only** unless a row says otherwise. Source reading establishes owners and shapes; it does not qualify installed-runtime cadence, replay, reset or cost semantics (see G1/G1-Codex/G2).

| Owner | Verified fact | Evidence class |
|---|---|---|
| Native controller [ClaudeNativeProcessSessionController.swift:1483–1548](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift#L1483) | Raw `type == "result"` detection; every stream result is emitted before the pending-turn guard; turn completion is deferred to `idle` when session-state events were observed, else immediate. No monetary live/replay gate, no original-result marker. | source-only |
| Package stream DTO (pre-Phase-1 baseline) | Single public initializer; carried `cost: Double?` and legacy token fields only. No `addingEnvelopeMetadata` or `markingOriginalResultPayload` helpers exist (zero matches repo-wide); the reconstructing-copy inventory is the initializer plus the two bridge mappings. Current shape: §2.2. | source-only |
| Core DTO `AIStreamResult` (pre-Phase-1 baseline) | Fields `promptTokens`, `completionTokens`, `cost`, `contextUsedTokens`, `contentMessageID`; single memberwise initializer; no cache-read/cache-creation split. Current shape: §2.2. | source-only |
| Bridge (pre-Phase-1 baseline) | Both mapping directions forwarded `cost`; no observation field existed. Current shape: §2.2. | source-only |
| Session envelope [AgentSession.swift](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift) | `currentSerializationVersion = 7` (line 214); memberwise initializer 322–410; custom decoder 456–528 with `decodeIfPresent` defaults (`providerTokenUsageByTurn` defaults to `[]`); `listStub()` (586) and `withItems(_:)` (606) copy `self`, so usage rows are retained on those copies. | source-only |
| Full save [AgentModeViewModel.swift:12230](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L12230) | Constructs `AgentSession(...)` with `providerTokenUsageByTurn: session.providerTokenUsageByTurn` (12251). | source-only |
| Hydration [AgentModeViewModel.swift:4666](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L4666) | `applyPersistedHydration` restores `providerTokenUsageByTurn` at 4787. Conversation reset paths clear the rows (`removeAll()` at 5041 and 17554). | source-only |
| Stub load [AgentSessionDataService.swift:1132,1188–1226](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L1132) | `loadAgentSessionStub` reconstructs an `AgentSession` from the header **without** `providerTokenUsageByTurn` (defaults to `[]`) while copying the Codex context scalars. Claude usage rows exist only after a full load. | source-only |
| Storage projection [AgentSessionDataService.swift:358](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L358) `sessionPreparedForStorage` (358–432); save 1045–1068; rename 1070–1081; load rewrite 1092–1124 | Every write passes through `sessionPreparedForStorage`; rename and load-time rewrite re-encode the full envelope. Any new `providerUsage` field must be verified through all four paths, not only save. | source-only (358/1070 read; 1045/1092 scout-verified) |
| Metadata index [AgentSessionDataService.swift:575–583](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L575) `metadataRecord`; `AgentSessionMetadataIndex` 44–122 | Index records are a separate header projection with no usage rows. | source-only (575 read; 44–122 scout-verified) |
| Restore [AgentSessionDataService.swift:555](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionDataService.swift#L555) | Cold restore loads the full `AgentSession`, so usage rows arrive only via the full decoder path. | source-only (scout-verified) |
| Tab seeding/hydration [AgentModeViewModel.swift:3832](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L3832) `seedUnhydratedSession`; [10844](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L10844) `hydrateSession` | Seeding copies index fields only; `hydrateSession` loads transcript only; usage rows are applied solely by `applyPersistedHydration` (4787). | source-only |
| Handoff/fork | Existing handoff/fork copies transcript content (`AgentTranscriptServices.handoffTranscript`, fork XML helpers) and sets `parentSessionID`; usage rows are not copied. There is no branch builder. | source-only |
| Export writer [OracleExportFileWriter.swift](../../../Sources/RepoPrompt/Infrastructure/MCP/OracleExportFileWriter.swift) | `GeneratedOracleExportFileWriter.write` requires the destination root to be loaded in the bound `read_file` scope, rejects an existing path, creates with a postcondition, verifies `read_file` resolves the exact path and loads identical contents, and cleans up on any failure. Phase 4 adds a writer-issued cleanup receipt for the already-authorized physical root/path so response-owned late cleanup remains valid after root unload; the narrow response adapter, not the writer, owns the shared one-second deadline and caller-cancellation lifecycle (§2.6). | deterministic in-process integration (§2.6) |
| Idempotency caller [AgentRunMCPToolService.swift:414–451](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift#L414) | Phase 4 excludes exactly `request_id` and `response_mode` at this caller and records the canonical value; response presentation is applied outside the service after fresh or replayed canonical completion (§2.6). | focused regression (§2.6) |
| Installed native Claude version | Local Claude Code **2.1.268**, established by an offline, bounded `claude --version` (exit 0, `2.1.268 (Claude Code)`) on the `PATH`-resolved executable; no provider prompt or paid probe. The version alone does not qualify live reset/replay/error/cost semantics (G1 still open). | offline probe; runtime semantics unqualified |
| G1 live reset/replay/error/native-child/cost attribution | Not qualified. Only synthetic code tests exist; no sanitized captured runtime fixtures. | unqualified |

Numeric accounting remains disabled. Phase 4 trimmed response modes are enabled behind explicit `response_mode=tail|none`, with default `full` unchanged (§2.6).

### 2.2 Phase 1 observation transport (implemented 2026-09-13)

Evidence class: direct source reads of the four production files and the three tests, plus the focused coordinated runs in §2.3. Nothing here is accounting, persistence, UI or runtime qualification.

| Owner | Implemented fact |
|---|---|
| [ClaudeProviderStreamResult.swift](../../../Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeProviderStreamResult.swift) — `ClaudeProviderUsageObservation`, `ClaudeProviderStreamResult.usageObservation` | `public struct ClaudeProviderUsageObservation: Sendable, Equatable` with `Source` (`messageStart`, `messageDelta`, `assistant`, `result`), optional `inputTokens`/`outputTokens`/`cacheReadInputTokens`/`cacheCreationInputTokens`, `model`, `envelopeID` (SDK `uuid`), `requestID` (literal `request_id`/`requestId`), `parentToolUseID`, `resultSubtype`, `resultIsError`. `usageObservation` is a trailing initializer parameter defaulting to `nil`. Raw cumulative cost stays on the existing `cost` field; `message.id` is not duplicated — it rides on the carrier's `contentMessageID` for `usage` carriers only (lane-resolved for `message_delta`, `nil` when unidentified); result `message_stop` carriers leave it `nil`, as the field's doc comment now states. |
| [AIProviderFactory.swift](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift) — `AgentProviderUsageObservation`, `AIStreamResult.usageObservation` | Core `AgentProviderUsageObservation` mirrors the package shape field-for-field; `AIStreamResult.usageObservation` is a trailing parameter defaulting to `nil`. Legacy `promptTokens`/`completionTokens`/`contextUsedTokens` semantics unchanged; content chunks do not gain a message id. |
| [ClaudeSDKNDJSONTranslator.swift](../../../Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift) — `parseUsage`, `makeUsageObservation`, `observedCount`, `parentToolUseID(in:)`, `laneKey`; emit sites in the `message_start`, `message_delta`, assistant-usage and `parseResultMessage` paths | `parseUsage` returns the legacy `TokenUsage` projection plus raw optional counts in one parse; the raw side reads the snake-case key when present and the camel-case key only when absent (conservative precedence, documented in source), while the legacy fallback is unchanged. `observedCount` does not use the legacy `numberToInt`: decimal-digit strings must fit `Int` exactly; floats must be finite, non-negative, exact integers at or below 2^53 with minus-zero rejected; booleans, negatives, fractions, non-finite and overflowing values are `nil` and never zero. Legacy normalization (including boolean-to-1) and result-context `nil` are untouched. `laneKey`: absent/null `parent_tool_use_id` selects the main lane; a non-blank string or an integral non-boolean, non-float number selects its own lane; any other non-null value (blank/whitespace string, bool, float, object, array) is unassigned and can neither read, open nor close the main lane. `parseResultMessage` parses `is_error` once (`rawIsError`); a whitespace-only `subtype` yields a `nil` observation subtype. `resetMainModelTracking` is documented as also clearing the message-id lanes for each process stream. |
| [ClaudeCompatibleProviderRuntimeBridge.swift](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift) — `ClaudeCompatiblePluginUsageObservation`, `usageObservation(from:)`, `providerUsageObservation(from:)` | The alias plus the two conversion functions map every field and both `Source` enums inside the forward (`streamResult(from:)`) and reverse (`providerStreamResult(from:)`) mappings. Feature-bridge wrappers only forward. |
| Tests | Package `ClaudeSDKNDJSONTranslatorTests`: `testUsageObservationTablePreservesRawCountsIdentityAndSourcesWithoutZeroSubstitution` and `testMessageDeltaObservationInheritsLaneMessageIDAndUnidentifiedSidechainStaysUnassigned`. Root `ClaudeCompatiblePluginBridgeTests`: `testStreamResultBridgeRoundTripPreservesEveryFieldIncludingUsageObservation`. All synthetic; no captured runtime fixtures. |
| Ledger `Scripts/Fixtures/test-suite-contract-ledger.tsv` | Three surgical rows added, one per new test, under reason "Agent usage plan phase 1 observation transport 2026-09-13". |

Copy and consumer inventory (source-only, 2026-09-13): `AIStreamResult`, `contentMessageID`, `usageObservation` and `promptTokens` have zero matches under `Features/AgentMode/Runtime/Remote`, `Sources/RepoPromptRemoteWire`, `Sources/RepoPromptGateway` and `Infrastructure/RemoteHosts` — remote/wire paths re-encode JSON/transcript projections, not the stream DTO, so they are not reconstructing copies. The only production grouping reader of `contentMessageID` (`ContextBuilderAgentViewModel`) guards on `type == "content"` before use; the ACP controller's access is diagnostic only. `ClaudeNativeProcessSessionController.streamResultLogPayload` is a diagnostic log subset that omits `contentMessageID` and the observation; the live `.stream(result)` emission forwards the value unchanged, so that omission is not a transport drop. Consumer-level regression: the existing `ContextBuilderRunLifecycleTests.testMCPRoutingFailureAfterImmediateStreamReturnCleansBootstrapAndAllowsImmediateRetry` was extended (no new test method) with a fake stream of `content("retry-", msg_main)`, `usage("USAGE-SENTINEL", msg_sidechain)`, `content("success", msg_main)`; its existing exact `retrySnapshot.agentOutput == "retry-success"` assertion exercises the real `contentMessageID` consumer. Three added test methods in total remain unchanged; the existing ContextBuilder ledger row's scenario count was raised from 1 to 2 for the extended case. Post-remediation results: §2.3.

Phase 1 exit contract status: companion survives the initializer and both bridge directions (source + roundtrip test); legacy behavior identical (asserted by the table test and executed under coordinated validation, §2.3). ACP raw preservation has not landed.

### 2.3 Current-phase validation (2026-09-13, post-remediation)

Ran and passed after the post-review remediation, via coordinated `make dev-*` lanes:

- `make dev-provider-test FILTER=ClaudeSDKNDJSONTranslatorTests` — 22/22 (table scenarios 14, lane scenarios 12). One intermediate fixture had expected the legacy boolean projection to be 1; it was corrected to the pre-existing legacy value 0, with the observation staying `nil` — no production change.
- `make dev-test FILTER=ClaudeCompatiblePluginBridgeTests` — 14/14 (a combined-filter invocation failed on shell quoting; the bridge job itself passed and the consumer case was rerun separately).
- `ContextBuilderRunLifecycleTests/testMCPRoutingFailureAfterImmediateStreamReturnCleansBootstrapAndAllowsImmediateRetry` — 1/1; this single focused method is the consumer evidence, not the whole lifecycle suite.
- `make dev-lint` and `make dev-swift-build PRODUCT=RepoPrompt`.
- `Scripts/test-check-agent-context` — 23/23; `git diff --check` clean.

Ran with pre-existing failures unrelated to this work: `Scripts/check-agent-context` (three Sep 3 / Sep 5 plan errors; none for this plan or its links); `make guardrails` (the same twelve unrelated tracked-document allowlist paths; this plan's path is now allowlisted).

Ledger verification still fails with 297 missing and 3 stale entries. Against the same current executable census, the unchanged HEAD ledger reports 300 missing and the same 3 stale entries: the three new rows cover this change's three new tests, while unrelated ledger drift remains.

Not claimed: a globally clean ledger; unfiltered `make dev-test-parallel` full-root evidence; any G1/G1-Codex/G2/G3 installed-runtime or economic qualification; any paid provider probe.

Review status: two Oracle reviews of the pre-remediation slice requested Phase 1 changes (observation numeric exactness, blank-parent lane classification, consumer coverage of `contentMessageID`); those changes are implemented (§2.2) and the results above follow them. Fresh independent OracleA and OracleB re-reviews explicitly closed every prior P1 finding and found no new P0/P1. OracleA approved the scoped remediation; OracleB retained only nonblocking notes. Both noted that the Phase 0/1 table rows had lost their owner and exit-contract cells; those original cells were restored after review without changing source. Claude-specific wording in the core observation remains a deferred P2 for future provider expansion; the consumer regression remains in its existing integration-test harness. These outcomes cover this transport-only slice, not deferred runtime qualification.

### 2.4 Phase 2 implementation and review status (2026-09-14)

Phase 2 accounting/persistence is **implemented and review-cleared for the gated scope**. The production qualification gate remains `.unqualified`; Phase 3 UI was not part of this slice, and no Codex pricing/accounting, MCP presentation, wait-policy change or live numeric qualification is included. Durable implementation boundaries are owned by [provider plugins](../../architecture/provider-plugins.md#claude-session-accounting-and-preservation). The user approved the field-local preservation amendment in §3.3; arbitrary raw usage values are preserved through the existing writer rather than a general opaque-data framework.

Scoped workers implemented the accumulator, raw-field codec, lifecycle forwarding and regression coverage. Remediation validates accepted-result uniqueness, segment-local checkpoint references, usable amounts for closed complete segments with work, and exact reported-cost representability. Crossed-reset results retain their original turn, tokens and result identity while their money is rejected. Reset closure treats every still-open turn in its segment as uncovered, regardless of dispatch order, and crossed monetary rejection explicitly preserves partial coverage on the original segment. Accepted amounts and checkpoint identities remain unchanged.

**Final validation:** `make dev-test FILTER=AgentUsage` passed 24/24 (12 accounting, 9 persistence, 3 runtime), ticket `16cfe93e-b1ec-4b46-830f-080518ddb09f`; no worktree writes occurred during that run and its full log has no source-change marker. The two reset tests now cover earlier-dispatched A remaining open after B's checkpoint, then reset and priced/token-only/interrupted completion; the real-writer case verifies typed-eligible reload with partial spend. `make dev-lint` passed (0/1,890 files require formatting), ticket `abd44d7d-2e69-40ac-b629-21a8e0603410`; `make dev-swift-build PRODUCT=RepoPrompt` passed, ticket `baaa75c9-71d7-42e2-a493-dad0b7010f6c`; `git diff --check` passed. Earlier adjacent session-profile persistence coverage passed 8/8. Module-cache debug-symbol warnings appeared during test linking but did not fail execution.

Ledger verification retains the pre-existing 297 missing / 3 stale mismatch; the 24 new tests have surgical entries. Repository-wide validation is not claimed: the pre-existing three context-document errors and twelve tracked-document allowlist violations remain outside scope. Full-root tests and installed-runtime/economic gates G1–G3 were not run; no paid probe or visible app lifecycle action was performed.

**Review outcome:** initial OracleA/OracleB findings were remediated. A fresh attempt failed on request size and provider quota; the user authorized OracleE to replace OracleB. Every substantive re-review used fresh OracleA/OracleE lanes with verbatim prior findings and exact deltas. The session stopped at the requested review boundaries, and the user explicitly authorized continued remediation after the surviving findings. In the final overlapping-turn review, OracleA (`oraclea-phase2-overlappi-3E3732`) and OracleE (`oraclee-phase2-overlappi-3571AE`) both approved the scoped remediation, explicitly closed the last crossed-reset coverage P1 and found no new P0/P1. Earlier P0/P1 closures remain closed. These are source-review outcomes, not live-runtime qualification.

Nonblocking review follow-ups are not another implementation loop: clarify/harden direct generic-Codable trust and its optional-null/precision guarantee (persisted codec paths preserve raw bytes); add same-owner supported raw formatting to the full runtime fixture; handle signed reported zero consistently; correct the escaped-key fixture; and maintain lexical ledger placement. The broader plan stays active because Phase 2b/Phases 4–6 and runtime qualification remain deferred.

### 2.5 Phase 3 UI implementation status (2026-09-14)

Phase 3 UI source and the two initial-review remediations are **implemented, focused-validated and review-approved for the gated scope**. `AgentRuntimeSidebarViewModel.ProviderUsageSnapshot` projects provider usage separately from context occupancy, and `AgentRuntimeSidebarView` renders a dedicated session-usage card between context usage and export context. `AgentModeViewModel+RuntimeMetricsUI`, `AgentRuntimeMetricsUIStore` and the scoped flush/invalidation comparisons in `AgentModeViewModel` publish usage changes through the existing runtime-metrics equality/revision path; they do not change context-window denominator math or issue provider requests.

The Claude card follows §4's CH/cost presentation contract: complete, per-metric partial, valid zero, tiny-positive and unavailable values remain distinct, with scope and coverage detail in help/accessibility text. The projection accepts only an active-session-owned, semantically valid record with matching origin; unsupported opaque values and foreign-origin records remain unavailable. Production live ingestion remains closed under `AgentUsageQualification.productionClaude == .unqualified`, so the default no-record state displays `CH — · Est. —`. An owned semantically valid hydrated Claude record can display at accounting revision zero, but under the unqualified production contract both numeric metrics are forced to partial and the detail text identifies restored historical accounting; unfinished restored work and an active unmeasured continuation receive additional explicit detail. This does not qualify live accounting. Codex remains explicitly unavailable because Phase 2b is deferred, and other providers show unavailable rather than inferred numeric values.

To avoid repeatedly deriving validated projections on the main actor, each `TabSession` caches its sidebar projection. Its key covers the selected provider, expected and accounting owners, qualification, eligibility, owned accounting revision, active execution and an explicit accounting-replacement generation. `replaceUsageAccounting` invalidates the cache and advances that generation, so same-owner hydration or replacement at revision zero cannot reuse an older projection. Runtime synchronization may pass the already-derived snapshot, and unchanged keys reuse the cached value.

**Review and validation status:** Verified initial OracleA and OracleB reviews both identified hydrated completeness as P1; OracleB also identified repeated main-actor projection work as P1/nonblocking. The source remediations above and focused regression cases are present. Before those remediations, root verified 83 tests—39 `AgentRuntimeSidebarViewModelTests`, 32 inactive-refresh tests and 12 `AgentUsageAccountingTests`—passed under ticket `63f2eec5-a2c0-4908-80b7-039a69ff9355`; lint passed under `5e0ef033-9e20-4fec-85f4-2a8793ddf828`; and the app build passed under `82130054-bc0e-4f6d-aeb8-bbdbb4687729`. Those runs are pre-remediation evidence only. After remediation, 86 focused tests passed (the same suites plus three `AgentUsageRuntimeIntegrationTests`) under ticket `b63d1cb4-b3c6-49b5-842a-e1ecca4c10ed`; lint passed under `95cc229a-1679-4b64-ad0f-750713068226`; and the app build passed under `6d098a28-0962-40b6-8a57-5474b371508b`. The first fresh re-review attempt was rejected before reviewer execution because a continuation-only parameter was supplied; work stopped until the user explicitly authorized resuming. Fresh OracleA (`oraclea-phase3-fresh-rem-A0D10A`) and OracleB (`oracleb-phase3-fresh-rem-7DEC22`) lanes then reviewed the verbatim prior findings, exact remediation delta and focused evidence. Both returned the requested preset identities, explicitly closed hydrated-coverage and repeated-projection P1 findings, approved the remediation and found no new P0/P1. Nonblocking follow-ups remain: cached unqualified start/end coverage, enforcing replacement/cache invalidation conventions, accessibility and formatting polish, unsupported-provider presentation, additional projection edge cases, and lexical ledger placement. These do not require another remediation round. Full-root tests, live UI validation and runtime qualification were not run.

### 2.6 Phase 4 MCP response presentation and G2 remediation status (2026-09-14)

Phase 4 is **implemented with the second scoped remediation pass applied**. `AgentRunResponsePresentation` parses the public `full|tail|none` mode before request-owner capture or canonical execution, returns default/explicit `full` Value-equal, and applies presentation only after canonical Agent Run/Explore completion. The single `MCPAgentControlToolProvider` boundary wraps every public Agent Run and Agent Explore operation once, so explore single/batch start, detach, poll, wait and cancel results share the same post-canonical presenter without changing `AgentExploreMCPToolService` control behavior. Actionable context remains full; successful terminal trims preserve all control metadata, use one top-level 2,000-Swift-Character excerpt at most, and give nested/collection-only terminal entries exact artifact references. Export de-duplication compares captured UTF-8 bytes, not canonically equivalent Swift `String` values.

Request authorization is frozen before the canonical await from captured MCP request metadata, resolved window/tab/workspace ownership and the captured `read_file` lookup scope. Authorization capture remains inside the absolute deadline but is registered with an inherited unstructured task so the actual caller connection and routing TaskLocals survive; detached preparation, export and cleanup do not regain ambient authority. The desired export path never establishes authority. `GeneratedOracleExportFileWriter.writeArtifact` returns a cleanup receipt containing the already-authorized physical root/path; late cleanup uses that receipt even after the root catalog unloads and reports failure through the response task owner rather than re-authorizing from mutable state. Capture, detached response preparation, export queueing and publication share one injected monotonic additional-wait budget with absolute-deadline checks at publication. Canonical Agent Run/Explore execution time is excluded. Caller cancellation cleans both already-collected successes and later noncooperative successes, while every operation remains in the detached-task owner until drain; no structured task-group join can defeat the deadline.

The parent initial OracleA/OracleB review snapshot `2026-09-14/1219-3` found P1 gaps in collected-success cancellation cleanup, absolute budget coverage, root-unload cleanup ownership and wire formatting of recovery metadata. R1 remediated those paths. Fresh R1 OracleA and OracleB reviews then left P1 contracts for untimed quadratic main-actor collection fallback, incomplete collection/wait-any text-wire recovery, and fix-induced loss of request TaskLocals during detached capture. R2 makes deadline fallback a root-only full-mode warning overlay that leaves the canonical snapshot array untouched, emits retained actionable/export-failure text and nested wait-any retrieval references on the text wire, and preserves caller TaskLocals only for deadline-owned authorization capture. The deterministic sleep helper records registering, wake-pending and cancellation-pending states under one lock. OracleA retained a nonblocking concern about a wake before sleeper entry; this is not claimed fully resolved. The production-shaped in-process MCP regression still invokes the public `agent_run` Tool, replays one successful mutation across `tail → full → none`, observes replay metadata on the canonical full value, observes recovery metadata on the real formatted wire result, and retrieves the exact terminal body through the same caller's real `read_file` endpoint and bound root.

R2 targeted validation passes: `AgentRunResponsePresentationTests` 18/18 under ticket `fe1333fa-155a-416b-8cbd-03b23636e6d4`; the real public replay/wire/readback method 1/1 under `1328a110-b5e9-4039-a6c4-d92d094e82a6`; and strict coordinated lint under `17d8dbee-65c7-4b61-a89a-258749c2c39b`. The first focused build failed only because the new test continuation needed an explicit `Void` type (`6c7a7671-778d-43b8-bc7e-7b1201318227`) and passed after that correction. The R1 writer receipt suite remains 7/7 under `17c154ac-8112-433b-bb01-28d793a104ab`; the parent pre-remediation coordinated baseline remains 80/80 under `e55ea841-c141-4141-b9ae-965e669776ad`. Per the R2 scope, four executable additions received surgical ledger rows; no full-package census/ledger-list pipeline was run. No installed-app or visible-app lifecycle path, paid/provider probe, or live external provider was run.

**Final review outcome:** independent fresh OracleA (`oraclea-phase4-fresh-rem-A62411`) and OracleB (`oracleb-phase4-fresh-rem-7EA5F1`) R2 reviews approved the remediation and explicitly closed every prior P1. No P0 was reported, and no P1 was downgraded by the implementer or orchestrator. G2 is cleared for the supplied deterministic and in-process MCP evidence, not installed-app or external-provider qualification. The parent combined seven-boundary run executed 91 tests successfully (`b58ffc10-acbf-408e-b471-e4699a63d417`), but its reusable artifact ticket was withheld when local review evidence changed during the run; that run alone is not reusable artifact-provenance evidence; the final rerun result is recorded separately in the session handoff. Nonblocking follow-ups remain: a discriminating public caller-versus-ambient worktree test, the test-clock pre-entry wake concern, Swift-String-equal rather than byte-equal readback, and export retention/dependency/Sendable documentation. No further review loop was run for minor findings. The full plan remains active because Phase 2b, Phases 5–6 and the unrelated live/economic gates remain deferred.

### External contracts versus installed-runtime evidence

Current [Claude SDK documentation](https://code.claude.com/docs/en/agent-sdk/cost-tracking) describes streaming-input result usage as per-turn/main-loop, but cost as cumulative within a query/reset interval and inclusive of native subagents. Cost is a provider-side client estimate, not an invoice. Installed reset, resume, replay and result-identity behavior still require qualification.

[Claude cache documentation](https://code.claude.com/docs/en/prompt-caching) distinguishes one-hour subscription-covered main-conversation defaults from five-minute billed defaults and permits overrides. A fixed wait does not establish cache warmth.

[Anthropic token categories](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) separate uncached input, cache writes and cache reads. [ACP's schema](https://agentclientprotocol.com/protocol/v1/schema#usageupdate) defines optional cumulative cost with currency; inspect actual provider support before proposing local pricing.

No measured savings, installed-provider accounting qualification, or source-test passes are implied by these references.

## 3. Usage transport and ownership

### 3.1 Preserve raw observations

Add one optional observation companion to the provider-package stream DTO and a core-owned equivalent on AIStreamResult. Suggested names: ClaudeProviderUsageObservation and AgentProviderUsageObservation.

Preserve optional input/output/cache-read/cache-creation counts, observation source (message-start, delta, assistant, result), reported model when available, and result subtype/error evidence. Retain raw cumulative cost on the existing cost field. Reuse existing envelope/message/parent-tool identities rather than duplicating competing identity fields.

Thread the observation through the DTO initializers, both bridge directions and every other reconstructing copy (the Phase 0 inventory in §2.1 found no `addingEnvelopeMetadata`/`markingOriginalResultPayload` helpers). Implemented shape and anchors: §2.2. Parse once into both the existing legacy projection and the optional-preserving observation.

Leave both legacy TokenUsage structs, AgentTokenUsagePersist, AgentContextUsage and context estimator semantics unchanged. Missing is not zero. Invalid negative, fractional, nonfinite or overflowing accounting inputs cannot become reported zeros; unavailable/partial diagnostics are preferable. Existing legacy normalization remains untouched.

Request IDs must survive start/delta/assistant observations. Do not attribute an unidentified sidechain delta to a global latest-main-message slot. ACP can preserve its existing raw cache fields with provider provenance, but that is transport-only, not qualified numeric support.

### 3.2 Independent core accumulator

Place a narrow AgentUsageAccumulator in Features/AgentMode/Runtime/Usage, owned by the existing session runtime/view model. Key ownership by persistent RPCE session ID, not the current tab.

Core native lifecycle supplies:

- executionID: fresh native process/query identity;
- monetary segment: executionID plus verified reset generation, normally zero;
- provider-turn identity: registered when a provider-bound input is actually dispatched;
- observation/result identity and ordering sufficient to reject duplicates and stale deliveries;
- live versus replay attribution.

For Claude cumulative monetary accounting, a chargeable observation must be positively attributable to a registered live execution/turn, have original-result authority, and satisfy a qualified monetary baseline contract. Codex uses the separately qualified counter-interval contract in §4.1, not Claude result authority. Merely taking the first result after a write, seeing a pending queue, or observing an original-result marker is not sufficient unless installed-runtime evidence proves replay cannot be misattributed.

Keep ordinary transcript delivery intact where required; give accounting its own eligibility gate. Ambiguous observations are diagnostics with partial/unavailable coverage, never guessed charges. Disposed executions cannot mutate a newer execution.

### 3.3 Small session persistence model

Add one optional providerUsage field to the session envelope, with:

- schemaVersion, originSessionID, trackingStartedAt, hasUnmeasuredHistory;
- identity-bearing turn summaries;
- provider-specific accounting checkpoints: cumulative money for Claude, disjoint measured/priced token intervals for Codex.

Turn summaries retain execution/segment/turn identity, accepted result identity, optional finalized input/output/cache counts, optional distinct observed request count, outcome, coverage and diagnostic reason. They may retain a clearly partial observed subtotal when a turn closes without an authoritative result.

Segment checkpoints retain the qualified contract identifier, provider/runtime provenance, known baseline, latest accepted cumulative estimate, currency, accepted result identity/order, closed/suspended state and coverage.

Do not persist request-history arrays, peak-cache-write metrics or raw tool/prompt bodies in v1. Keep active-turn request deduplication in memory; persist only summaries/checkpoints through the existing save revision and writer. No competing persistence task.

Restore accounting before live ingestion. Absent legacy accounting starts an unmeasured tracked interval, not a reconstructed zero-cost history. Same-session resume retains owned completed segments. Branch/copy initialization starts destination-owned accounting; hydration also rejects mismatched originSessionID as destination spend. Rewind and compaction do not refund historical cost.

Inventory custom coding, partial session updates, save projections and all copy/hydration paths atomically. Verify how unsupported/malformed nested usage can remain recoverable without making the transcript unreadable or silently overwriting usage with empty data. If the current store lacks the needed preservation contract, stop that persistence rollout and report the narrow design gap; do not add a speculative repository-wide opaque-data framework.

Phase 2 preservation amendment (approved by the user on 2026-09-13 after the §3.3 stop gate): the existing session store lacks isolated nested-value preservation. Implement a wrapper limited to `providerUsage`, not a repository-wide opaque-data framework. Absent stays absent; supported, fully validated v1 may expose typed accounting; explicit null, unsupported or malformed nested values, and values whose typed projection would lose unknown members remain opaque and ineligible for mutation. Preserve JSON-value semantics, including numeric precision, across save, rename, rewrite, stub reconstruction and hydration. Foreign-origin records remain preserved but excluded from destination spend. Reuse the existing session writer; preservation failure must fail the write, never replace usage with empty data. This amendment does not qualify G1 or enable production numeric accounting.

Old builds may ignore or discard the new field on resave. Promise continued transcript usability, not round-trip preservation of new accounting through older versions. Missing continuity after re-upgrade remains explicit.

## 4. Accounting and display contracts

### Claude tokens

Request observations are snapshots/upserts, not additive events. Missing fields do not erase earlier fields; duplicates do not increase totals. Main-loop and native-sidechain scopes stay distinguishable.

For an accepted authoritative turn result, use its qualified main-loop totals instead of adding them to request subtotals. Before such a result, deduplicated observations can provide a partial subtotal. Output placeholders must not be promoted to finalized billed output.

CH is the token-weighted share:

```text
sum(cache read) / sum(uncached input + cache read + cache creation)
```

Only complete, validated input triples contribute an unqualified ratio. Excluded or unmeasured intervals make displayed coverage partial. A zero denominator is unavailable. Never average request percentages, use context occupancy as the denominator, or present high CH alone as proof of savings.

### Claude provider-reported cost

Within a qualified segment, replace the latest checkpoint:

```text
segment contribution = latest accepted cumulative estimate - known segment baseline
session estimate = sum(disjoint owned segment contributions)
```

Results 1.00 then 1.50 mean 1.50, not 2.50. Keep raw precision until display.

- Zero baseline requires a verified query-start contract.
- A same-provider-session resume may create a new query execution. Never subtract the RPCE lifetime total from a provider query counter.
- With unknown historical baseline, mark prior coverage unmeasured; do not charge the first observed cumulative amount as newly incurred work.
- A reset generation changes only on a positively verified reset boundary, not on a counter drop, compaction or MCP epoch transition.
- Ignore identified stale/duplicate events. An unexplained later decrease suspends the segment as partial; do not infer a reset.
- Valid original error results may report usage. Cancellation/crash without a final result preserves accepted checkpoints and explicitly incomplete coverage; a zeroed crash report cannot erase earlier accepted spend.
- A cost-only report can be meaningful even when the context estimator would append nothing.

First-party native Claude uses this monetary contract. Its cost includes native subagents; CH describes its main loop. Separate RPCE worker sessions are excluded from the parent's figure. Do not add native-child cost again. Codex ships alongside it using §4.1. ACP and compatible-backend numeric accounting remain follow-ups.

### UI

Add a separate usage projection/readout beside context usage; no context-window denominator changes.

Examples: `CH 99.1% · Est. $2.171`; partial data adds explicit `partial`; missing data shows a dash or hides the unavailable metric; valid reported zero remains distinguishable. Tooltip/accessibility text expands CH and gives coverage/tracking interval plus provider-specific cost scope. Claude uses provider-estimated, native-subagent-inclusive, separate-RPCE-worker-exclusive wording; Codex uses the locally calculated Standard/global token-equivalent wording in §4.1. Neither is an invoice.

Do not infer `(sub)` or display an uncertain estimate with a mathematical lower-bound `≥` label. No automatic workload grand total. Publish on accepted results, hydration and lifecycle closure through existing coalescing; duplicates and ordinary text chunks do not republish or trigger provider calls. Latest-request UI/history is deferred; use diagnostics for post-wait investigation.

### 4.1 Codex cache share and locally calculated API-equivalent cost

Codex and Claude are both first-release targets. The user authorized a practical fetched/cached pricing mechanism rather than deferring Codex dollars. This supersedes the earlier Claude-only sequencing and no-local-price-catalog exclusion. It is a plan, not implemented support.

#### Verified source and integration facts

- [CodexNativeSessionController.swift:4956–4987](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift#L4956) accepts last/total usage but returns context totals. Lines 5033–5043 read cached input only in a fallback sum; never reuse that sum for billing because cached input and reasoning output may be subsets.
- The controller emits legacy usage at 3260–3263. [CodexAgentModeCoordinator.swift:6277–6282](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift#L6277) currently discards it outside active run state, then refreshes context/save. A separate accounting path must handle provably owned late usage.
- The controller sends requested model and serviceTier at 1726–1743, not proof of actual charged routing. Official [app-server documentation](https://learn.chatgpt.com/docs/app-server) describes usage/reroute notifications and version-specific schema generation; shapes alone do not qualify event cadence.
- Official [model-list API](https://developers.openai.com/api/reference/resources/models/methods/list) has no price fields. Use the public [pricing document](https://developers.openai.com/api/docs/pricing), fetched as `https://developers.openai.com/api/docs/pricing.md`. A keyless fetch on 2026-09-13 returned 23,005 bytes of Markdown, ETag and Last-Modified. This is a parseable public document, not a stable pricing API.
- [AnthropicDiscoveredModelStore.swift:1–145](../../../Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/AnthropicDiscoveredModelStore.swift#L1) supplies a versioned/validated local-cache pattern, not a pricing authority. Leave model discovery/visibility unchanged.

#### Price acquisition and cache

Add a small app-owned OpenAI pricing component under `Infrastructure/AI/Pricing/`: normalized catalog, pure document parser, reviewed bundled seed, and single-flight store/refresher. No hosted service, admin key, community price authority, per-token network access or LLM parsing. A literal seed is sufficient; a generator and new Settings screen are not prerequisites.

The catalog holds schema version, content-derived pricing version, source/capture/validation timestamps, exact model IDs, explicitly reviewed alias mappings, USD-per-million Decimal rates, eligible context bands and supported pricing semantics. Missing/blank/dash is unknown or explicitly non-applicable according to the qualified schema, not numeric zero. Literal zero is valid. Exact IDs precede explicit aliases; never infer prices from a model family or let price data modify model choices.

Parse only qualified Standard/global text tables, including the separately headed Codex table. Select by headings and header names, not table position. Preserve write and context-band distinctions. Reject conflicting rows, malformed amounts, ambiguous structure and unsupported schema atomically; keep the prior valid catalog. Do not execute or interpret fetched prose as instructions. Aliases/threshold rules require bounded, reviewed mappings rather than arbitrary prose inference. A model lacking a supported mapping stays unpriced.

On first Codex use, use the validated in-memory/persisted snapshot or bundled seed immediately. If last validation is older than 24 hours, schedule one background fetch, capped at 10 seconds and 1 MiB including a bounded decoded response. Pin the official HTTPS endpoint and validate redirects; send no auth, prompts, usage, session IDs or selected-model query. Honor applicable existing offline/network restrictions. No new global network-policy abstraction is required. Document this metadata-only request when implementing the provider seam.

Use conditional validators when supplied. A valid 304 refreshes validation time without changing pricing version; without the corresponding validated body, retry unconditionally. Failure retains last-good/seed with stale provenance; retry no sooner than one hour on subsequent use. Inference/UI never waits for refresh. Persist normalized validated data atomically using the existing local-store pattern; no credentials in this store. A new catalog affects future dispatches, not historical estimates.

#### Raw usage and ownership

Keep `.tokenUsage(AgentContextUsage)` and context behavior unchanged. Add a companion Codex observation containing optional-preserving last/total input, cached input, output, reasoning output and cache-write counts when actually provided; thread/turn identity, execution generation, ordering and attribution provenance. Emit it even if the legacy context projection is nil. Locate every event switch before implementation.

Qualify the installed version's cached-inclusive input and reasoning-inclusive output semantics, cumulative scope, duplicate/refinement cadence, turn identity, resume/fork/compaction and reroute behavior. Schema generation and sanitized matching fixtures are keyless qualification tools; no new paid probe is authorized by this plan.

The core registers a live dispatch and captures an immutable pricing snapshot at dispatch. Resolve positively attributable model rates from that frozen snapshot; record requested/observed model and requested tier separately. A known reroute without a corresponding usage boundary makes affected cost partial/unpriced, not a whole-turn repricing. An unobserved actual model may use the known requested model only as an explicit assumption.

Price disjoint, owned cumulative counter intervals; do not add successive total snapshots or sum last plus total. Preserve baseline/latest checkpoints, accepted identity/order and origin in the existing session-owned accounting. Duplicate events are no-ops; attributable refinements upsert the same interval using its original pricing basis. Unknown initial baseline starts a prospective tracked interval, not a charge for imported history. Deriving total-minus-last is allowed only if installed-runtime evidence proves last exactly spans the new attributable interval; no largest-last fallback as a complete turn.

Accounting eligibility is independent of the active-run context guard. Accept identifiable late updates while disjoint ownership remains proven; reject replay, stale/disposed execution and wrong-origin events. Never assign an event to the currently open turn merely because a prior turn closed. Missing attribution or an unexplained decrease creates partial coverage and prospective rebaselining, not inferred reset, refund or a reconciliation chain. Forked inherited usage is baseline, not new destination spend.

#### Arithmetic and display

For qualified observed intervals, let I be total input, C cached input, W cache-write input and O output inclusive of reasoning. Validate nonnegative integer counts, C+W <= I when all are known, and overflow-safe arithmetic. The official [prompt-caching arithmetic](https://developers.openai.com/api/docs/guides/prompt-caching) treats read/write counts as input subsets. The installed app-server must still preserve those meanings.

```text
CH = sum(C) / sum(I)
ordinary input = I - C - W
API-equivalent token estimate =
    (ordinary input * inputRate
     + C * cachedInputRate
     + W * cacheWriteRate
     + O * outputRate) / 1,000,000
```

Rates are Decimal; round only presentation. Do not add reasoning output a second time. CH can be available while cost is partial; missing is distinct from zero and a zero input denominator is unavailable.

Use **Standard/global list-price equivalence** for all requested tiers, including Fast, as a stable comparison basis—not a reconstruction of subscription charges, actual service tier, regional uplift, tool fees or invoice adjustments. Preserve those exclusions/assumptions in tooltip and persisted provenance. This also means the figure alone cannot establish actual billed savings across providers with different monetary scopes.

Presentation ladder:
1. A point estimate when supported pricing dimensions and counters are known.
2. An explicitly conditional finite range when missing write counts or context bands have proven bounds. If W is unknown and I/C are qualified, its possible interval is 0 through I-C. Use conservative category-rate envelopes across eligible context bands that cover mixtures of requests; simple corner calculations are allowed only when tests prove they bound those mixtures. Round displayed lower/upper ends outward. No midpoint or unjustified greater-than-or-equal label.
3. An explicitly partial subtotal of independently priceable components when bounds/rates are unknown, otherwise unavailable. Never pretend all I-C tokens are ordinary input if unknown W could occupy part of them.

An explicitly qualified non-applicable separate write charge differs from a missing rate, and does not by itself prove W=0. Model-specific normalization must establish whether those input tokens use the ordinary input rate; never equate no separate surcharge with free input. Proven W=0 needs no write rate; potentially positive W with missing rate cannot be zero-priced. The same rule applies to missing cached-input prices. Unknown model means no invented family price. Missing context-band attribution does not justify silently using the cheaper band. Ranges bound the stated token-price assumptions, not the user's invoice.

Suggested UI: `CH 99.1% · API-equiv. $2.171`, with Standard/global basis in details; show a range or visible partial indicator where required. Keep price date/staleness, assumptions, exclusions and coverage accessible. Do not label subscription status unless independently known. Zero requires measured zero; a tiny positive amount must not masquerade as zero. Coalesce publications at finalization, qualified late updates and hydration, using the existing writer/UI cadence.

#### Persistence and implementation map

Extend the proposed session-owned usage record with a monetary-kind discriminator: Claude provider-cumulative versus Codex locally-priced. Retain Codex baseline/end counters, coverage, ownership/order, frozen pricing version plus actually applied rates/model/band assumptions, and Decimal amount or bounds. Persist small interval/turn summaries, not event history or a request ring. Reload before ingest; refresh never silently reprices history. Unpriced history remains unpriced rather than being backfilled with today's prices.

| Owner | Planned change |
|---|---|
| Proposed `Infrastructure/AI/Pricing/OpenAIPricingCatalog.swift`, `OpenAIPricingDocumentParser.swift`, `OpenAIPricingStore.swift`, `OpenAIPricingSeed.swift` | Pure typed prices/parser, seed and bounded independent cache. Names are proposed, not existing files. |
| `Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` plus a feature-appropriate Codex usage DTO | Companion observation, raw optional counts, source identities and lifecycle provenance; legacy context event unchanged. |
| `Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | Dispatch snapshot capture, registered ownership, separate accounting eligibility, final/late lifecycle handling. |
| Proposed `Features/AgentMode/Runtime/Usage/Codex/CodexUsageAccounting.swift`, `CodexTurnPricer.swift`; shared accumulator/persistence from §3 | Pure interval arithmetic and local-money kind; no Claude repricing. |
| Existing session save/hydration/branch and sidebar owners from §7 | Atomic propagation, owned restore, partial/range/stale UI; no parallel writer. |

Land parser/cache tests first, then raw observation transport, then accounting/persistence atomically, then readout. Include both providers in the first release; individual unsupported intervals stay explicitly partial/unavailable rather than blocking all Codex estimates.

Maintainer-guidance check: user benefit is practical cost/cache visibility for both primary providers. Public price fetch and raw-counter loss are confirmed; installed event semantics remain a release qualification item. Authority is official prices plus native measured usage, not context estimates. Risks are double-counting, late/replayed events, inherited spend, stale/misparsed prices and unexplained assumptions. Bound refresh and UI work; reuse session persistence; validate parser, counter ownership, arithmetic and presentation separately.

## 5. Recoverable MCP assistant-result presentation

### Public contract

Add only `response_mode: full | tail | none`, default `full`, to supported snapshot-producing agent_run and corresponding agent_explore operations. Validate before any mutation. Match the established Oracle mode parsing behavior, including malformed-type rejection.

Defer snapshot_detail and public tail_chars. Retain all current descriptive metadata in v1. Default/full output remains semantically Value-equal to existing output, with no new presentation fields.

Apply presentation after canonical outcome construction and idempotency recording, to the top-level snapshot and known snapshots array entries only:

| Snapshot state | full | tail / none |
|---|---|---|
| Non-actionable running | Existing output | Omit assistant preview; do not export transient text |
| Waiting for input/actionable interaction | Existing output | Preserve full assistant/interaction context as a documented safety override |
| Terminal, no text | Existing absence | No empty export |
| Terminal, nonempty text | Existing full text | Export exact captured text before removing it; tail can return excerpt, none returns retrieval metadata |

Never prune status, failure reasons, interaction IDs/content, worktree information, acknowledgements, _meta, wait winner/pending IDs, resolutions, instructions, ordering or unknown control fields. Do not modify canonical snapshots, transcripts, stored terminal text, epoch logic, heartbeats or waiter ownership.

### Export and latency

Use a narrow presenter/adapter with an injected existing authorized export writer, not a new export subsystem or state in AgentRunSessionStore. Capture terminal text and authorized workspace/session ownership before awaiting. Do not reread a later current tab or transcript.

Return the exact file path, retrieval instruction, effective response mode and character/line counts. Reuse content-bound deterministic naming only if the writer can verify ownership and exact contents; an existing filename alone is not proof of a correct artifact. Avoid duplicate writes through existing writer facilities when available, without making a new cache/coalescer a first-release requirement.

The whole response has a maximum **one-second additional presentation wait**, including queueing, not one second per worker. Exports that fail or are not ready fall back to full inline text with an export warning. Successful other entries may still use references. The write/cleanup remains owned after a caller stops waiting; do not wait on non-cooperative cancelled I/O or leave unowned tasks. Qualify this writer integration before enabling trimmed modes.

Export failure is not worker failure and must not invite restarting a completed mutation. If an authorized retrievable artifact cannot be produced, preserve full output. Existing get_log remains transcript catch-up, not the sole exact-result recovery mechanism.

### Excerpt allocation — user-approved primary-only

Use the user-approved response-wide **2,000 Swift Character** excerpt budget: top-level primary terminal snapshot gets the excerpt, nested terminal entries get artifact references without duplicate excerpts. A collection-only multi-poll is reference-only. This is a character limit, not a token limit.

Actionable-context preservation and full-inline export-failure fallback intentionally override size limits; never claim an unconditional hard response cap.

OracleD preferred sharing the same total budget across terminal workers. The user subsequently accepted primary-only; both original arguments and the user resolution remain in §9.5. This is a user-settled decision, not unanimous Oracle agreement.

### Mutation idempotency

Parse presentation arguments before dispatch. Exclude exactly request_id and response_mode from the Agent Run semantic fingerprint at its caller; do not broaden exclusion globally. Record full canonical results. Apply requested presentation to fresh and replayed results alike. Changing presentation on the same request_id must not conflict or reexecute; changing substantive mutation arguments must retain conflict behavior.

## 6. Wait guidance and timeout policy

Update the five workflow prompt owners: WorkflowPrompt+Investigate, +DeepPlan, +Optimize, +Orchestrate and +Refactor under Infrastructure/AI/Prompts/Workflows.

Guidance: detach independent parallel starts, use wait/session_ids for supervision, handle all interactions, remove completed workers and wait again while work remains. Poll is for deliberate instantaneous inspection. Do not enable status updates merely to show activity or abandon active workers.

Keep existing general numeric guidance/defaults; do not introduce a blanket longer value. Describe early wake and timeout-as-upper-bound accurately. Transport heartbeats do not warm a provider prompt cache.

Replace the gateway's duplicated 120 literal with MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds using its existing dependency. Retain mapping, grace, cap and external behavior. Leave implicit CLI deadline policy unchanged now. A future default change must land atomically with app policy, tool-description expectations, gateway behavior, CLI omitted-timeout derivation and relevant host tests. Explicit overrides remain authoritative.

## 7. Implementation phases and owning files

Phase status is recorded per row. Phase 2 is implemented, validated and review-cleared for its gated scope (§2.4); Phase 3 UI and remediations are implemented, focused validation passed, and both OracleA/OracleB P1 findings are closed (§2.5); Phase 4 and scoped remediations are implemented with validation passing and every prior P1 explicitly closed by fresh OracleA/OracleB R2 reviews; G2 is cleared for deterministic/in-process evidence only (§2.6); Phase 2b and Phases 5–6 are future work. Phase 0's source inventory and offline installed-version evidence are complete while its G1, G1-Codex and G3 runtime/economic gates remain open; Phase 1 is implemented with post-review remediation applied, focused validation passed, and every P1 explicitly closed by fresh OracleA and OracleB re-reviews.

| Phase | Owning files / change | Exit contract |
|---|---|---|
| 0. Inventory and qualification fixtures — **source inventory and offline installed-version evidence done (§2.1); G1, G1-Codex and G3 still open; G2 cleared for deterministic/in-process Phase 4 evidence (§2.6)** | Native controller/coordinator; session-envelope save/hydration owners; existing export writer; idempotency caller; relevant tests | Locate exact unselected owners and every reconstructing DTO/session path. Establish installed native version, result/reset/replay contracts and authorized writer behavior; no guessed compatibility. |
| 1. Observation transport — **implemented (§2.2); focused validation passed and Oracle P1 findings closed (§2.3); not accounting or qualification** | Provider package ClaudeSDKNDJSONTranslator.swift, ClaudeProviderStreamResult.swift; core AIProviderFactory.swift, ClaudeCompatibleProviderRuntimeBridge.swift | Optional companion observations survive all copies; legacy token/context behavior identical. ACP raw preservation is transport-only and can land separately. |
| 2. Accounting and persistence — **implemented; focused validation passed and OracleA/OracleE P0/P1 findings closed (§2.4); production G1 remains closed/unqualified** | Proposed Runtime/Usage/AgentUsageAccumulator.swift and AgentProviderUsagePersist.swift; AgentSession.swift; native controller/coordinator; AgentModeViewModel save/hydration/dispatch paths | Core-owned eligibility, independent turn/segment state, old decode compatibility, duplicate/replay/branch safety. Session envelope and every forwarding site land atomically. |
| 2b. Codex pricing and accounting | Pricing component, Codex observation/controller/coordinator and shared accounting owners in §4.1 | Official-price cache, disjoint owned usage, frozen historical rates, point/range/partial contracts. Parser/cache can land independently; observation/accounting persistence lands atomically. |
| 3. UI — **implemented; focused validation passed and OracleA/OracleB P1 findings closed (§2.5)** | AgentRuntimeSidebarViewModel.swift; AgentRuntimeSidebarView.swift; AgentModeViewModel+RuntimeMetricsUI.swift; AgentRuntimeMetricsUIStore.swift; scoped flush/invalidation comparisons in AgentModeViewModel.swift | Clearly scoped CH/cost, explicit unknown/partial, no extra provider requests or context regressions. |
| 4. MCP presentation — **implemented and validated through R2; both fresh Oracle lanes approved and closed every prior P1; G2 deterministic/in-process scope cleared (§2.6)** | Infrastructure/MCP/Agent/AgentRunResponsePresentation.swift and narrow export adapter; AgentRunMCPToolService.swift; OracleExportFileWriter.swift cleanup entry point; MCPAgentControlToolProvider.swift; unchanged AgentExploreMCPToolService behind the single provider boundary | full default unchanged; export-before-trim; bounded fallback; presentation-independent idempotency; all wait/explore outcomes preserved. |
| 5. Guidance and duplicate timeout authority | Five workflow prompt files; RemoteCommandTranslator.swift | Wait-first guidance without unverified numeric rollout; gateway uses shared constant without behavior change. Plain wait-first wording can ship independently before phase 4; response_mode examples require phase 4. |
| 6. Evidence and follow-ups | Existing opt-in Claude raw logging; proposed offline analysis script; provider-seam/context owner docs | Bounded diagnostic evidence establishes whether longer waits or metadata compaction merit another change. No first-release live diagnostic dashboard. |

Update the existing [provider seam document](../../architecture/provider-plugins.md) with implemented observation/accounting facts only when implementation lands. Follow [source layout](../../architecture/source-layout.md), [testing](../../testing.md), [development](../workflows/development.md) and [validation](../workflows/validation.md). New executable tests require surgical ledger rows; leave unrelated staged ledger/branching work intact.

## 8. Validation, release gates and rollback

### Deterministic tests

Prefer existing suites and helpers where they cover the boundary; new suite names below are proposed, not claims of existing tests.

| Boundary | Required observable regression |
|---|---|
| Provider translator / existing ClaudeSDKNDJSONTranslatorTests | Missing versus zero; invalid numeric observations; start/delta/assistant/result scope; request and sidechain identity; no terminal context-total substitution. |
| Existing ClaudeCompatiblePluginBridgeTests / copy helpers | Forward/reverse bridge and original-result/envelope copies retain every observation field. |
| Proposed AgentUsageAccountingTests | Duplicate snapshots/result count once; result replaces request subtotal; cost-only result accepted; synthetic/unowned/replayed result never charges; result arriving while another turn is pending is not blindly attributed. |
| Same accounting suite | Input triples (10 uncached,90 read,0 write) and (900,0,0) yield 9%, not average percentages; missing components/zero denominator qualified; overflow cannot manufacture a total. |
| Same accounting suite | Cumulative 1.00→1.50→duplicate stays1.50; verified reset plus0.20 yields1.70; unexplained decrease suspends; unknown resumed baseline remains partial; late disposed-execution events rejected. |
| Proposed AgentUsagePersistenceTests | Absent old field; round-trip; restore before ingest; accepted IDs survive reload; origin mismatch excluded; same-session resume retained; interrupted execution partial; unknown/malformed version preservation contract. |
| Existing AgentRuntimeSidebarViewModelTests (Phase 3 cases added) | Correct complete/partial/unknown/zero labels, weighted session scope, no subscription inference, no duplicate refresh or context occupancy change. |
| Proposed AgentRunResponsePresentationTests | full equality; actionable safety override; exact retrievable export; Unicode character budget; no hidden full-text duplicates on successful trim; multi-entry references; bounded/failing/deleted/wrong-owner artifact cases; cancellation cleanup owned. |
| Proposed Codex pricing parser/cache tests | Named Standard versus other tiers; specialized Codex table; exact IDs/aliases; reordered headers; invalid/unknown layouts; zero versus dash/unknown; write/band distinctions; offline seed, stale last-good, conditional304 with/without body, response/timeout bounds, concurrent single-flight, restricted-network skip. |
| Proposed Codex observation/accounting/pricer tests | Context unchanged; nil/zero, subsets/overflow; duplicate cumulative snapshots; qualified/unknown baselines; replay/fork/late/disposed events; ambiguous reroute unpriced; no neighbouring-model inference; frozen snapshot; Decimal formula, no reasoning double-count; missing rates partial; mixed-band/write envelopes, outward rounding. |
| Proposed Codex persistence/UI tests | Applied rates/version/model/assumptions survive reload; no refresh repricing; local monetary kind never mixed with Claude dollars; CH independent of cost coverage; Standard/global, requested Fast, zero/tiny-positive, range/partial/stale labels. |
| Existing AgentRunMCPToolServiceWaitTests and WaitAnyTests | Completion/question/approval/steering/interaction-resolution/status updates/epochs/expiry/cancellation preserve outcomes and cleanup; stored terminal text still supports parked wait, poll and later wait. |
| Idempotency boundary | Same mutation request_id with changed response_mode executes once and re-presents canonical data; changed substantive arguments conflict; presentation failure does not record failed worker mutation. |
| Core/gateway boundary | Omitted and explicit waits, overrides, zero/poll, steer without wait and gateway cap/mapping remain unchanged; shared gateway policy does not change current deadlines. |

Use controlled clocks/continuations and injected export outcomes, not sleep-based timing assertions. Use synthetic or sanitized fixtures, not committed raw logs.

### Installed-runtime and economic gates

G1 — Before enabling numeric native-Claude accounting, qualify successive streaming turns, request/result relationship, native-child scope, explicit reset, resume, replay, error/cancellation and live-result ownership on the installed runtime. If scope or identity cannot be proven, keep the affected metric unavailable/partial; do not ship heuristic exactness.

G1-Codex — Before enabling numeric Codex accounting, qualify installed counter inclusion, cumulative cadence, dispatch/late/replay attribution, observed resume baselines, fork inheritance, resets/compaction and model reroutes. A matching schema is necessary but not sufficient for cadence. Validate the live pricing document parser and reviewed seed at release without a paid provider request. Confirm fetch restrictions and conditional-cache failure paths. Unknown intervals stay partial; they do not block independently qualified intervals.

G2 — Before enabling trimming, prove existing writer authorization, exact-content retrieval, off-main-actor work, bounded caller waiting and owned cleanup. Failure keeps full output; no new authorization is inferred from a desired export path. **The deterministic in-process production-writer/adapter, TaskLocal ownership, collection/wait-any text-wire and public MCP readback evidence is recorded in §2.6. Both fresh OracleA and OracleB R2 reviews approved and closed every prior P1, clearing this scope; no installed-app or external-provider execution was performed.**

G3 — For economics, obtain explicit approval for any paid/provider probe and a bounded task/input/time/spend budget. Visible app lifecycle still requires fresh action-boundary approval. Compare full/current versus wait-first/trimmed at120 first, then explicit120 versus600 only after host transport qualification. Use at least five matched pairs as a minimum decision aid, not statistical proof.

Record disjoint parent/worker costs with coverage, unique parent model requests, wait return reasons, actual wait duration, post-wait cache split, response bytes, export fallback/latency, completion time and task-quality criteria. Native-inclusive query cost must not be counted again through native children. Mark ambiguous tool-to-next-request correlation as ambiguous. Bytes/characters are not measured tokens. Incomplete cost coverage cannot establish savings. Codex's Standard/global equivalent and Claude's provider-reported estimate have different cost bases: compare like-for-like within a stated basis, not their sum or a range midpoint as actual workload spend.

A higher-default follow-up requires lower total provider-estimated workload spend/fewer wasteful requests without missed interactions or material latency/quality regression, plus app/CLI/gateway/host deadline compatibility. High CH alone is not an acceptance criterion.

### Commands for future implementation

Run the smallest relevant coordinated make dev-provider-test FILTER=..., make dev-core-test FILTER=..., make dev-test FILTER=..., make dev-lint and affected make dev-swift-build PRODUCT=... checks. Use unfiltered make dev-test-parallel for full-root contribution evidence, not every iteration. Follow daemon tickets; no duplicate direct Swift work.

For documentation, run Scripts/check-agent-context, Scripts/test-check-agent-context and make guardrails. These establish structure, not implemented behavior.

Rollback can independently revert prompt recommendations or leave response_mode at full. Preserve recorded accounting where supported; never reconstruct missing historical spend after downgrade. Stop rollout on duplicate charges, false zero/complete labels, branch-origin leakage, context regression, dropped interaction metadata, inaccessible advertised artifacts or mutation retries caused by presentation failure.

## 9. Oracle disagreement record

Both lanes received the same 9,178-character initial prompt and curated live evidence. OracleE's initial transport/authentication failures produced no usable opinion. Its successful endpoint result was recovered after an accidentally cancelled client wait, then explicitly confirmed in the same verified preset lane. OracleD's original answer was retained. Each challenge message relayed arguments and shared new source evidence, not the other lane's identity.

Exactly two reciprocal challenge rounds ran. Returned preset identities matched OracleE and OracleD throughout successful consultations. OracleE's final response repeated its round-one revised position rather than providing itemized settlement verdicts; the outcomes below therefore rely on its explicit retained positions, not invented final assent.

### 9.1 Accounting container, cost ownership and replay — resolved at contract level

OracleD initially favored adding scalars to context rows and computing cost deltas/reset detection in the translator. OracleE argued that lifecycle ownership, cumulative segment scope and copied branch rows require independent accounting.

After verifying branch copies and pre-guard original-result emission, OracleD accepted the separate ledger and core-owned baseline/identity logic. Both reject inferred resets and lifetime-total subtraction. Use independent turn/segment summaries and raw observation transport. The exact installed-runtime attribution proof remains G1, not an already solved implementation. The proposal to equate first-result-after-write with live ownership is not accepted without replay qualification.

### 9.2 Persisted requests and diagnostic scope — resolved, with a minor metric choice

OracleE initially proposed persisted normalized request records. OracleD initially preferred per-turn summaries and DEBUG analysis; in round one it advocated a bounded200-request ring for reload-visible diagnosis. OracleE reduced its design to active-turn memory plus persisted summaries. In round two OracleD accepted removing the ring.

Plan: summaries/checkpoints only, bounded opt-in offline request diagnostics, no latest-request UI promise. OracleD requested a persisted peak-cache-write scalar alongside requestCount; OracleE explicitly deferred it. Resolved as a minor scope choice by the orchestrator: keep optional observed requestCount, defer the peak scalar because it cannot itself identify the post-wait request or demonstrate savings.

### 9.3 Metadata compaction and text recovery — resolved

OracleD initially proposed one text mode and get_log-only recovery; OracleE proposed orthogonal metadata/text controls with export. Verified get_log returns whole-turn XML, not bounded exact terminal output. Both accepted export-before-terminal-trim.

The positions crossed on metadata during challenge: OracleE reduced scope to text-only; OracleD accepted deferring snapshot_detail in round two. Plan: one response_mode, full compatibility default, all metadata retained. Metadata compaction remains a measurable additive follow-up, not secretly included.

### 9.4 Export mechanism and latency — resolved in favor of the smaller integration

A dedicated export coordinator or cached path in the wait store was proposed to avoid repeated writes. The smaller counterproposal uses the existing authorized writer via a narrow adapter, retaining bounded waiting and full fallback.

Both accepted a one-second response-wide presentation budget and no new wait-store state. Deterministic reuse is an implementation detail only when scoped identity and exact artifact content are verified; no blanket trust in an existing filename. The writer's actual ownership/deadline behavior remains G2.

### 9.5 Multi-worker excerpt allocation — resolved by the user after two rounds

**Primary-only position (OracleE):** give the top-level primary snapshot the response-wide2000-character excerpt; nested terminal snapshots return artifact references. This avoids duplicate summaries, has one clear budget, and minimizes presentation logic.

**Shared-budget position (OracleD):** divide the same2000-character budget among unique terminal worker snapshots, remainder to primary, no per-worker floor; shares below100 characters become reference-only. Several closing summaries may let the parent act without additional artifact reads. OracleD explicitly preserved this as a material rejection in its final verdict.

**Resolution:** after the two Oracle rounds, the user accepted the orchestrator's recommendation: primary-only initially. It has the simpler successful-output contract and no measured evidence yet favors allocation complexity. This was not Oracle consensus. It may increase selective follow-up reads when several workers finish together; compare both strategies on multi-worker tasks before promoting shared allocation.

### 9.6 Wait rollout and deadline hardening — resolved

OracleD initially recommended explicit600-second workflow waits and immediate implicit CLI hardening; OracleE opposed broad numeric rollout before measurement. Both ultimately accepted default120, wait-first guidance without new blanket numbers, and an opt-in600-second experiment.

Both accepted replacing the already-shareable gateway literal now. Implicit CLI policy changes wait for the numeric-default follow-up. OracleD's final uncertainty about core access to the shared policy is refuted by existing references in InteractiveMCPClientSession; deferral is a scope/current-behavior choice, not an import blocker.

### 9.7 Provider coverage and UI claims — resolved

The original consultation chose native first-party Claude first. The user's subsequent request and the separate pricing consultation in §9.8 supersede that sequencing: both Claude and Codex are now first-release targets. ACP remains transport-only until qualified. Explicit scope/partial estimates, no inferred subscription label and no automatic parent-worker UI total remain.

### 9.8 Codex fetched-price extension — resolved after a separate two-round consultation

OracleE and OracleD received the same initial extension brief and curated Codex/cache evidence, in independent new chats with verified exact preset identities. Both supported official Markdown plus seed/local cache and first-release Codex CH/cost. Two anonymous reciprocal challenge rounds resolved the material alternatives; both explicitly accepted final F1–F4. This did not reopen wait120 or the user-approved primary-only decision.

- **Source and refresh:** both chose the public official pricing Markdown over a third-party aggregate or a nonexistent model-prices API. A reviewed seed and last-good cache cover offline/parser failure. Resolve minor scope choices with one bounded cache, no generator/new Settings screen prerequisite, and no coupling to model visibility.
- **Requested tier versus stable baseline:** OracleD initially left Fast/nonstandard requests unpriced; OracleE favored Standard/global equivalence regardless of requested tier. Both accepted the latter with explicit baseline/provenance labels, not actual-charge claims.
- **Missing writes/context versus a point estimate:** OracleD initially omitted writes/assumed short context with flags; OracleE favored conditional ranges. Both accepted point, proven range, then independently priceable partial subtotal. OracleD explicitly withdrew zero-pricing an absent write rate. Preserve unknown, explicit non-applicability and proven zero as distinct facts; absence of a separate surcharge does not prove no writes.
- **Range arithmetic:** a four-corner proposal was narrowed to cases proven to cover mixed request bands. Both accepted conservative per-category rate envelopes and outward rounding. The orchestrator does not adopt turn-total-based threshold shortcuts without the installed pricing/usage contract proving them.
- **Counter ownership and late updates:** unconditional total-minus-last, largest-last as turn usage, current-open-turn tagging and matching-neighbour-model attribution were rejected. OracleE withdrew its reconciliation mechanism; OracleD withdrew a new unattributed-spend checkpoint class. Existing summaries may count independently proven disjoint ownership/model attribution, but ambiguous spans remain partial and rebaseline prospectively.
- **Frozen prices:** both accepted capturing the pricing snapshot at dispatch, resolving attributable model rates from that snapshot, and never repricing history on refresh. A known unresolved reroute does not license whole-turn reassignment.
- **Remote requests:** both accepted the fixed keyless source, 24-hour refresh, 10-second/1-MiB/single-flight bounds, conditional validation and stale fallback. Inspect and honor applicable network restrictions; a missing policy lookup is not authorization to bypass one. No new global policy framework is required.

No material disagreement remains in this pricing extension. Runtime semantic qualification, public-document parser robustness and truthful coverage labels are implementation gates, not claims of completed support.

## 10. Original planning-session validation and handoff (historical)

This section records the original planning session as written on 2026-09-13, before any implementation. It is retained as history and is superseded for current status by the Status line and §§2.1–2.3.

No Swift implementation, provider experiment, credential change, app lifecycle operation, commit or staging was performed for this plan. The user repaired Oracle setup outside this work; consultations consumed the requested Oracle services.

Before document creation, Scripts/check-agent-context failed on two existing issues in docs/context/plans/2026-09-03-codex-computer-use-enablement-plan.md: invalid/missing scope header and orphan reachability. Scripts/test-check-agent-context passed23 tests. These unrelated failures must not be silently repaired or represented as new-plan failures.

Final documentation checks:

- `Scripts/check-agent-context`: failed with the same two pre-existing errors above and no warnings; no additional error was reported for this plan or its validation-workflow link.
- `Scripts/test-check-agent-context`: passed, 23 tests, zero skipped or failed.
- `make guardrails`: failed its tracked-document allowlist check, reporting 12 unrelated existing tracked paths (including the September 3 and September 7 plans). The new plan remains untracked; this check does not establish that it is allowlisted for a future commit. Review its durable-document allowlisting when preparing an explicitly requested contribution.
- Only this new plan and its discovery link in `docs/context/workflows/validation.md` were edited for the deliverable. Unrelated staged work and existing context failures were left untouched.

The later Codex extension used read-only public documentation fetches and two additional Oracle challenge rounds. It did not launch Codex, generate installed schemas or run a paid runtime probe. After the extension edit, Scripts/test-check-agent-context again passed all 23 tests; Scripts/check-agent-context reported the same two pre-existing errors and no new errors or warnings. The earlier guardrails failure was not rerun for this documentation-only extension.

Implementation gates G1–G3 (including G1-Codex), paid runtime probes, and all Swift tests/builds remain not run. No implementation or commit is authorized by this planning result.
