# GPT model catalog

Scope: read when the task touches direct OpenAI API model visibility, trusted model metadata, configured-model projection, static OpenAI wire-ID ownership, or adding a newly released GPT model.
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

## Deferred work

Configured-model service-tier gating and the OpenAI catalog status UI remain PR 3 work. Although schema v2 can decode `service_tiers`, PR 1 does not make metadata the configured-model tier projection authority. Existing static and unknown-custom tier behavior also remains unchanged pending the separately audited follow-up described by the [active plan](plans/2026-09-04-dynamic-gpt-model-catalog-plan.md).

Codex model grammar, capability history, and Fast-tier evidence belong to PR 2 and are not owned by this document yet.

## Add a model

1. Verify the exact official wire ID and document the evidence for protocols, reasoning modes and efforts, streaming, token limits, and service tiers. Treat `/v1/models` as visibility evidence only.
2. Prefer a data-only baseline row. If the wire ID is statically owned, either keep the row non-projecting or perform an explicit static-to-data migration with persistence and request-equivalence coverage.
3. Update the embedded schema-v2 baseline. Omit unsupported or unverified fields; do not infer `max_input_tokens`, service tiers, or reasoning efforts.
4. Confirm strict decoding, v1 compatibility, whole-row override precedence, disables, and malformed-versus-missing override behavior.
5. Verify official-host typed exact matching, live-visibility projection, cached/failed refresh behavior, stable display naming, and withdrawal preservation.
6. Pin the model's exact capabilities and projected choice count in tests, plus request encoding for every supported mode and effort. Verify unsupported efforts and tiers are absent.
7. Update this document when the authority, trust boundary, compatibility contract, or model capability row changes.
