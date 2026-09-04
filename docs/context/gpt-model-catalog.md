# GPT model catalog

Scope: read when the task touches direct OpenAI API model visibility, trusted model metadata, configured-model projection, static OpenAI wire-ID ownership, Codex app-server model capability discovery, Codex model parsing or Fast variants, or adding a newly released GPT model.
Authority: Authoritative
Last-verified: 2026-09-04

## Authority and trust boundaries

Keep visibility and capability authority separate:

- OpenAI `GET /v1/models` is visibility-only. Its IDs decide which trusted rows may be offered for a key; it supplies no reasoning, protocol, streaming, token, display-name, or service-tier capability.
- `OpenAIAPIModelMetadataBaseline.swift` is the embedded strict schema-v2 baseline. The decoder remains compatible with schema v1, which normalizes to no disables and no service tiers.
- The optional local override remains `~/Library/Application Support/RepoPrompt CE/ModelCatalog/openai-model-metadata-v1.json`. The filename is intentionally unchanged for compatibility even though the current schema is v2.
- There is no remote metadata channel. Do not derive capabilities from `/v1/models` or add an unsigned updater.

Resolution precedence is `embedded baseline < local override`. An override row replaces the complete baseline row with the same exact ID; fields are never spliced. Root `disabled_model_ids` suppresses resolved rows explicitly. Omitting a baseline row from an override does not remove it.

Each source is decoded strictly and independently. A malformed or unreadable override reports failure while retaining the last-good override layer. A missing override means no override and clears any previously loaded local layer. Neither condition changes the last-good visibility snapshot.

## Projection and identity

Static OpenAI cases have Position 1 whole-wire-ID ownership derived from `OpenAIResponseRequestPlan`: when `AIModel.staticOpenAIWireModelNames` owns an exact request wire ID, no `.openAIConfigured` choice is emitted for that ID. This suppresses only configured siblings; an explicitly typed ID retains the legacy custom Responses escape hatch. Trusted metadata may retain such a row as non-projecting capability data. A family that needs metadata-only siblings must migrate explicitly from static ownership to data-only; never introduce a second configured representation of the same static wire ID.

Resolved display names are stored in the process-wide `OpenAIAPIModelMetadataRegistry`. `.openAIConfigured` display and semantic sorting use the registry name while persisted selection raw values and request model IDs remain unchanged.

An exact typed custom-model ID may consume the full trusted row only when the effective endpoint is an official OpenAI host (`api.openai.com` or a subdomain of `openai.com`; the default endpoint qualifies). This explicit typed-ID path bypasses visibility for staged access. On any other host, when no exact trusted row matches, or when the trusted row emits no valid `.openAIConfigured` choices, keep the conservative custom-model projection and never apply unusable official OpenAI metadata.

For official hosts, static OpenAI choices may be filtered by exact wire ID only after a successful live `/v1/models` refresh for the active scope in the current session. Cached-only snapshots and failed refreshes never hide static choices. Custom endpoints do not use official-host static filtering.

Withdrawal hides a configured row from new visible choices but does not rewrite a stored exact selection. Its registry-backed name remains stable, and executing it sends the same stored model ID, mode, and effort; provider failure surfaces without fallback, alias substitution, or effort downgrade.

## GPT-6 Astra baseline

`gpt-6-astra` is data-only and has exactly these trusted capabilities:

- display name `GPT-6 Astra`
- Responses API only
- reasoning modes `standard` and `pro`
- efforts `low`, `medium`, `high`, `xhigh`, and `max`
- streaming supported
- 1,050,000-token context window and 128,000 max output tokens
- no `max_input_tokens`
- no `none`, `minimal`, or `ultra`
- no service tiers

Token metadata describes capability only and does not synthesize output limits into requests.

## Codex app-server authority and persistence

Codex app-server `model/list` is the capability authority for observed Codex bases. `CodexDynamicModelRecords` remains the active last-good snapshot used by current picker consumers. A separate `CodexKnownModelBases` schema-v1 ledger retains parser capability history; it is not a second active catalog. `AgentCodexModelRegistry.updateLiveModels` is the only production persistence trigger for the ledger: each non-empty poll replaces the active snapshot, unions historical effort knowledge, and records the latest additional speed tiers, service tiers, source, and last-seen data for each observed base.

When the ledger key is absent, legacy dynamic records are folded in memory. Field presence is preserved from the app-server wire response through the active record: missing historical or current effort/tier fields are absence of evidence and retain prior capability, while explicit current empty tier arrays are authoritative and remove Fast eligibility for that base. The next non-empty observed update persists the fold. The ledger preserves seeded bases and is capped at 2,048 entries. An unknown ledger schema is never interpreted as compatible data: readers use seed-only capability and do not overwrite the future-schema payload for the process lifetime. Tests use isolated `UserDefaults` and injected immutable snapshots rather than mutating `UserDefaults.standard`.

A successful zero-model poll is no evidence. It records an in-memory poll outcome for later status presentation but does not clear or publish over the active last-good snapshot and does not change the ledger. Poll failures likewise record an in-memory failure outcome while preserving both stores. A non-empty poll still replaces the active snapshot even when it represents partial withdrawal; an unchanged canonical snapshot is not republished.

## Codex model grammar and withdrawal

`CodexModelSpecifier` parses against a cached immutable capability snapshot of `(base, efforts, speed tiers)` with precomputed longest-base ordering. Exact known bases win first, then the longest known base may consume an advertised effort suffix. `max` and its `maximum` alias, plus `ultra`, are extended efforts and are stripped only with capability evidence. Ordinary legacy effort suffixes retain their broad compatibility behavior. This keeps exact IDs such as `gpt-5.1-codex-max` intact, while an observed base such as `gpt-daybreak-blue-latest` automatically gains `-max` and `-ultra` parsing when advertised. Unknown `gpt-6-astra-max` remains one uninterpreted model ID until Codex supplies evidence.

The seed preserves static Codex bases and current extended-effort behavior: `gpt-5.6`, `gpt-5.6-sol`, and `gpt-5.6-terra` advertise seed `max` and `ultra`; `gpt-5.6-luna` advertises seed `max`; other static bases advertise no extended effort unless observed.

A withdrawn dynamic model disappears from new picker choices, but normalization resolves availability using durable known-base knowledge plus current live evidence, with exact-base-wins and longest-match semantics. A present base may normalize changed effort capability; an authoritative explicit empty effort list clears stale effort in both stored selection and request shaping; missing effort metadata preserves the existing effort as unknown evidence; a present now-ineligible Fast selection degrades to that same base; and a genuinely withdrawn explicit raw model plus explicit effort remain unchanged across every normalization and request-selection call site. Parsing knowledge remains in the ledger, and execution sends the same base and effort without neighbor substitution, aliasing, or downgrade. `shouldBackfillRecommendedDefaults` remains separate product policy and is intentionally unchanged.

## Codex Fast authority

Fast eligibility is evidence-driven; there is no GPT version heuristic. An observed record, including one with an empty `additionalSpeedTiers`, overrides seed capability for that exact base. Fast is offered only when the latest capability entry contains exact tier token `fast`. The offline seed grants Fast to exactly `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, and `gpt-5.4`.

The UI variant remains `<base>-fast[-<effort>]`, and the request wire value remains `service_tier=fast`; upstream `serviceTiers[].id == priority` is descriptive metadata, not the request token. A persisted `-fast` selection whose base is no longer eligible degrades to the same base without sending a service tier. Do not infer Fast for new versions or for `gpt-5.4-mini`, `gpt-5.3-codex-spark`, Daybreak, or Astra without explicit `additionalSpeedTiers` evidence.

## Deferred work

Configured-model service-tier gating and the OpenAI catalog status UI remain PR 3 work. Although schema v2 can decode `service_tiers`, the current implementation does not make metadata the configured-model tier projection authority. Existing static and unknown-custom tier behavior also remains unchanged pending the separately audited follow-up described by the [active plan](plans/2026-09-04-dynamic-gpt-model-catalog-plan.md).

## Add a model

1. Verify the exact official wire ID and document the evidence for protocols, reasoning modes and efforts, streaming, token limits, and service tiers. Treat `/v1/models` as visibility evidence only.
2. Prefer a data-only baseline row. If the wire ID is statically owned, either keep the row non-projecting or perform an explicit static-to-data migration with persistence and request-equivalence coverage.
3. Update the embedded schema-v2 baseline. Omit unsupported or unverified fields; do not infer `max_input_tokens`, service tiers, or reasoning efforts.
4. Confirm strict decoding, v1 compatibility, whole-row override precedence, disables, and malformed-versus-missing override behavior.
5. Verify official-host typed exact matching, live-visibility projection, cached/failed refresh behavior, stable display naming, and withdrawal preservation.
6. Pin the model's exact capabilities and projected choice count in tests, plus request encoding for every supported mode and effort. Verify unsupported efforts and tiers are absent.
7. Update this document when the authority, trust boundary, compatibility contract, or model capability row changes.
