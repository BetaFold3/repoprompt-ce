# Completion outcome (2026-09-04)

This plan is complete. The status and PR notes below are preserved verbatim as historical planning context.

- **PR 1:** shipped the strict schema-v2 OpenAI baseline and GPT-6 Astra data-only support, local whole-row overrides/disables, trusted official-host projection, registry-backed identity/display, and withdrawal-safe visibility behavior.
- **PR 2:** shipped Codex app-server capability parsing, the bounded known-base history ledger, capability-aware extended-effort parsing, evidence-driven Fast eligibility, no-evidence zero/failure retention, and withdrawn-selection preservation.
- **PR 3:** shipped metadata-gated service-tier variants for configured dynamic OpenAI models, OpenAI/Codex catalog status projections, explicit reload/reveal/refresh actions, Settings observability, privacy-safe endpoint/error presentation, status-only shutdown dates, and the durable documentation updates.
- **Decision summary:** whole-wire-ID ownership remains authoritative for static OpenAI cases; metadata gates tiers only for configured dynamic models, while static and registry-miss unknown-custom Responses tier behavior is deliberately deferred; Codex keeps the additive history-ledger design.
- **Validation state:** the prior data/view-model slice was reported validated before this completion slice. Final integration ran a successful `make dev-build` and successful `Scripts/test-check-agent-context`. `Scripts/check-agent-context` remains blocked by the unrelated active Codex computer-use plan's missing header and route. `make guardrails` reaches repository checks outside the sandbox but remains blocked by the current tracked-document allowlist findings; no unrelated allowlist was expanded.

---

# Dynamic GPT Model Catalog Plan (GPT-6 Astra first)

Scope: read when the task touches OpenAI direct-API model discovery or trusted capability metadata (`Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/APIModelCatalog.swift`, `OpenAIAPIModelMetadata.swift`, `OpenAIResponseRequestPlan.swift`, `APISettingsViewModel.swift` OpenAI projection), Codex dynamic model parsing or Fast-tier synthesis (`CodexModelSpecifier.swift`, `CodexServiceTierVariantCatalog.swift`, `CodexAIModelCatalog.swift`, `AgentCodexModelRegistry.swift`, `CodexModelPollingService.swift`), or adding a newly released GPT model such as `gpt-6-astra`.
Authority: Authoritative
Last-verified: 2026-09-04

Status: **Partial implementation — Phase 0, PR 1, and PR 2 implemented; PR 3 pending.**
Date: 2026-09-04

PR 1 outcome (2026-09-04): adopted §3.1 Position 1 whole-wire-ID static ownership and implemented the embedded schema-v2 baseline with v1 compatibility, local override resolution, registry-backed names, trusted official-host projection, and live-session static filtering.

PR 2 outcome (2026-09-04): adopted §3.3 Position 1 additive persistence, implemented tier-field propagation, the bounded v1 known-base ledger with missing-versus-empty legacy migration and monotonic parse-effort history, cached immutable capability-snapshot parsing, evidence-driven Fast variants and deterministic request shaping, no-evidence zero/failure polling preservation, and base-identity-aware withdrawn explicit Codex selection preservation. PR 3 remains pending; the PR 2 section below is retained as planning history.

Provenance: drafted from two independent Oracle plan consultations (presets OracleE and OracleD, identical initial prompts, preset identity verified via `model_preset_id` on every turn), followed by two rounds of anonymous cross-challenge on the material disagreements. Every load-bearing code claim below was verified against live source in this session at the cited lines; two facts (Codex app-server tier fields, app-target packaging) were discovered during verification and were not available to either lane's first draft.

## 1. Background (verified 2026-09-04)

### 1.1 OpenAI documentation

- API model ID `gpt-6-astra`. The model reference lists reasoning efforts exactly `low, medium, high, xhigh, max`; the latest-model guide states `none` is not supported and mentions `minimal` in passing. Whether `minimal` is accepted is **unresolved** and must be probed, not assumed.
- Pro mode supported ("supports the existing API capabilities available with GPT-5.6, including … pro mode"). Streaming supported. 1,050,000-token context window, 128,000 max output tokens. Responses API recommended; tool calling requires Responses. Rollout is staged (Trusted Access first, general API access "in the coming days").
- `GET /v1/models` returns only `id, object, created, owned_by, shutdown_date`. It is a **visibility** authority only; it cannot supply capabilities.

### 1.2 Direct OpenAI API path (Oracle/chat models)

- `APIModelCatalog.swift:4-19, 105-140, 339-346` — discovers IDs from `/v1/models`, caches per (provider, normalized endpoint, SHA-256 key fingerprint), keeps the last-good snapshot on refresh failure.
- `APISettingsViewModel.swift:4510-4513` — intersects visible IDs with trusted metadata via `OpenAIAPIModelCatalogMerge.merge`; the only metadata source is `~/Library/Application Support/RepoPrompt CE/ModelCatalog/openai-model-metadata-v1.json` (`:4562-4579`). There is **no bundled baseline and no app-managed updater**; a missing or malformed file silently yields `[]` (`:4547-4553`). The file does not exist on a typical install.
- `OpenAIAPIModelMetadata.swift:4-42` — schema v1 already models protocols, reasoning modes (standard/pro), efforts (`none … max`), streaming, and tokens. Unknown keys are rejected; `combinedTokenLimitsFit` (`:333-339`) rejects `max_input + max_output > context`, so Astra's row must omit `max_input_tokens`.
- `APISettingsViewModel.swift:4520-4545` — `configuredOpenAIModels` projects metadata rows into `.openAIConfigured(selection:)`, excluding `gpt-5.6-sol` by literal because static `AIModel.gpt56Sol` exists.
- `OpenAIResponseRequestPlan.swift:157-165` (configured branch) and `:168-190` (static branch, e.g. `.gpt56Sol: (.gpt56Sol, "medium")`) — two request-plan branches; `:196-235` sends `.custom(modelID)` and injects `reasoning.mode = "pro"` for Pro.
- `AIModel.swift:277` — the custom-model text field projects only `[.low, .medium, .high, .xhigh]`; a user typing `gpt-6-astra` today gets Responses routing but no `max`, no Pro, and a raw-ID display name.
- `APISettingsViewModel.swift:2250-2261` — the service-tier toggle projects `default/flex/priority` for **every** Responses model with no capability evidence.
- `APISettingsViewModel.swift:2216-2223` — `shouldUseResponsesRoutingForOpenAICustomModel` already distinguishes official `*.openai.com` hosts from custom base URLs.
- `Package.swift` declares no `resources:` on the app target (only `RepoPromptGateway` and the test target do); the `.app` is assembled by maintainer-owned packaging scripts.

### 1.3 Codex Agent Mode path

- `CodexModelPollingService.swift:221-236` polls app-server `model/list`; `CodexAppServerClient.swift:836-884` parses pages including `supportedReasoningEfforts` and `defaultReasoningEffort`. `CodexDynamicModelStore.save/load` (`CodexAIModelCatalog.swift:313-335`) persists canonical records under UserDefaults key `CodexDynamicModelRecords`.
- `AgentCodexModelRegistry.updateLiveModels` (`:12-28`) replaces the live list and overwrites the persisted records on any non-empty changed poll — partial withdrawal is already representable; only "never received" vs "authoritative empty" is not.
- `AgentCodexModelRegistry.shouldBackfillRecommendedDefaults` (`:186-197`) is actively re-inserting `gpt-5.3-codex` today because the live list contains only `gpt-5.3-codex-spark`; the backfill is deliberate product behaviour, not a cold-start guard.
- `AgentModelCatalog.swift:435-437` — Codex raw model IDs are accepted permissively; no enum case is needed for a dynamic model.
- `CodexModelSpecifier.swift:40-45, 83-95` — `-max`, `-maximum`, `-ultra` are stripped only for hard-coded bases `gpt-5.6`, `gpt-5.6-sol`, `gpt-5.6-terra` (max, ultra) and `gpt-5.6-luna` (max); any other base keeps the suffix with `effort = nil`. This protects the legitimate base ID `gpt-5.1-codex-max`.
- `CodexServiceTierVariantCatalog.swift:7-10` — `isFastEligible` is `major > 5 || (major == 5 && minor >= 3)`; Fast variants are synthesized from that rule at `AgentCodexModelRegistry.swift:92-113` and `CodexAIModelCatalog.swift:478-495`.
- **Live probe (codex-cli 0.153.0, `model/list`)**: 8 models — `gpt-5.6-sol`, `gpt-5.6-terra` (low…max, ultra), `gpt-5.6-luna` (low…max), `gpt-daybreak-blue-latest` (low…max, ultra), `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` (low…xhigh). No `gpt-6-astra`.
  - `gpt-daybreak-blue-latest` advertises `max`/`ultra` but is not in the specifier's hard-coded list, so `gpt-daybreak-blue-latest-max` is misparsed **today**.
  - Each entry also carries `serviceTiers`, `defaultServiceTier`, and `additionalSpeedTiers`. `gpt-5.6-sol/terra/luna`, `gpt-5.5`, `gpt-5.4` → `additionalSpeedTiers: ["fast"]`, `serviceTiers: [{id: "priority", name: "Fast", description: "1.5x speed, increased usage"}]`; `gpt-daybreak-blue-latest`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` → both empty. The current heuristic therefore **over-grants** Fast to `gpt-5.4-mini` and `gpt-5.3-codex-spark` and would invent `gpt-6-astra-fast`.
- Existing suites: `Tests/RepoPromptTests/AI/{OpenAIAPIModelMetadataTests, OpenAIConfiguredModelSelectionTests, ModelPickerStringOrderingTests, CodexModelPollingServiceTests, CodexCLIProviderReconciliationTests}.swift`.

## 2. Agreed decisions (both lanes converged; adopt)

### 2.1 Astra is data-only

No `AIModel.gpt6Astra` case, no recommendation badge, no default or `findBestAvailableModel` priority change. Display name comes from the metadata row via a process-wide registry consulted by `AIModel.displayName` for `.openAIConfigured`; the `gpt-5.6-sol` display special case (`AIModel.swift:576-577`) is removed in favour of the registry. Display names never enter `OpenAIConfiguredModelSelection.rawValue`.

Baseline row:

| Field | Value |
|---|---|
| `id` | `gpt-6-astra` |
| `display_name` | `GPT-6 Astra` |
| `protocols` | `["responses"]` |
| `reasoning.modes` | `["standard", "pro"]` |
| `reasoning.efforts` | `["low", "medium", "high", "xhigh", "max"]` — no `none`, no `minimal` until probed |
| `streaming` | `true` |
| `tokens.context_window_tokens` | `1050000` |
| `tokens.max_output_tokens` | `128000` |
| `tokens.max_input_tokens` | omitted |
| `service_tiers` | omitted (no tier evidence) |

Token metadata is capability information only; do not synthesize `max_output_tokens` into requests.

### 2.2 Trusted-metadata delivery: embedded baseline + local override; no remote channel

- Baseline is a **Swift JSON string literal** in a dedicated source file, decoded by the existing strict decoder and pinned by an exact-decode test. Not a `Package.swift` resource / `Bundle.module`: the app target has no resource contract and packaging is maintainer-owned (§1.2). Revisit only if the baseline outgrows a literal.
- Merge order `baseline < local override`. Each source decodes independently and strictly; a malformed override is discarded **whole** (baseline still applies, error surfaced). Override rows **replace the entire row** by exact `id` — no field splicing, because row invariants are validated per row.
- Explicit removal only: root `disabled_model_ids: [String]` suppresses baseline rows. Omitting a row never removes it.
- Schema bumps to **v2** (`service_tiers` per row, `disabled_model_ids` at root). v1 documents remain decodable and normalize to empty tiers / no disables. A v2 local file on an older binary fails loudly via `unsupportedSchemaVersion` — acceptable and honest.
- Missing local file = "no override" (and clears any previously loaded local layer). Malformed local file retains the last-good local layer and surfaces the error. No metadata failure may ever erase a last-good visibility snapshot.
- Signed remote manifest: **out of scope**. Preconditions for a later workstream: fixed HTTPS origin, signed envelope over canonical bytes, bundled public-key set with rotation, monotonic version, issue/expiry, bounded cached last-good, kill switch, and no ability to alter defaults or recommendations. Future precedence would be `baseline < valid signed remote < local override`.

### 2.3 Custom-model text field: trusted match wins

If the typed ID exactly matches a resolved trusted row **and** the effective base URL is an official OpenAI host, project the row's full capability (declared modes × efforts, streaming flag, display name, declared tiers) as `.openAIConfigured`, bypassing `/v1/models` visibility (the field is the explicit "I have access" escape hatch during staged rollout; Settings still shows "not reported for this key"). Otherwise keep today's conservative projection (`AIModel.swift:277`). For Astra this yields ten choices (five efforts × Standard/Pro).

### 2.4 Service tiers for configured (data-driven) models are metadata-gated

`.openAIConfigured` flex/priority wrappers are projected only when the row lists them in `service_tiers`; absent → `default` only. Astra ships with none. Runtime probing is not a catalog mechanism. (Static-model tier behaviour is a surviving disagreement — §3.2.)

### 2.5 Codex extended-effort parsing: exact-base longest-match over capability evidence

- Replace the hard-coded family list in `CodexModelSpecifier` with a lookup over an immutable capability snapshot `(base, efforts, speedTiers)` built from static seed ∪ observed `model/list` evidence.
- Grammar: (1) `raw` equals a known base → base = raw, effort = nil; (2) else `raw == base + "-" + suffix` for the **longest** known base whose effort set contains `suffix` (`max`, `maximum` → `.max`, `ultra`) → (base, effort); (3) else base = raw, effort = nil. Extended suffixes are never stripped for unknown bases.
- Seed = today's behaviour: `gpt-5.6`, `gpt-5.6-sol`, `gpt-5.6-terra` → {max, ultra}; `gpt-5.6-luna` → {max}; every other static Codex ID → {} (seeded as a base so rule 1 wins — this is what keeps `gpt-5.1-codex-max` intact even if `gpt-5.1-codex` later advertises `max`).
- `CodexModelSpecifier(raw:capabilities:)` gains an injectable snapshot defaulting to the shared value; tests inject `.seedOnly`/transient so `UserDefaults.standard` is never read implicitly. The parser depends on the snapshot value only — never on `RemoteModel` or persistence types — because it is invoked from sort comparators.
- Consequence: `gpt-daybreak-blue-latest-max`/`-ultra` parse after one poll; `gpt-6-astra-max` stays one uninterpreted ID until Codex advertises Astra, then parses with no code change.

### 2.6 Codex Fast tier: upstream evidence is the authority; five-base offline seed

- Parse `additionalSpeedTiers`, `serviceTiers[].{id,name,description}`, and `defaultServiceTier` into `CodexAppServerClient.RemoteModel` and persist them in the record.
- Delete `gptVersion(from:)` / `isFastEligible` and the version formula at **both** synthesis sites. Fast is offered iff the base's latest record has `"fast"` in `additionalSpeedTiers`. A record with empty tiers overrides the seed (so `gpt-5.4-mini` and `gpt-5.3-codex-spark` lose Fast — intended and documented; `gpt-6-astra` never gains it without evidence).
- Offline seed (no record ever: first launch, app-server unreachable, static-only IDs) = exactly the five bases upstream confirms today: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`. Tests: a fixture of the verbatim dump pins the eligible set; a guard asserts seed ⊆ fixture-confirmed set.
- Wire value: the app currently sends `service_tier=fast` (`CodexModelSpecifier.cliServiceTierConfigArgs`) while upstream's `serviceTiers[].id` is `priority` and `additionalSpeedTiers` is `["fast"]`. Keep `fast` as the variant token; **Phase 0 must confirm** which value app-server accepts and record the mapping. Persisted `-fast` raw selections for a base that loses eligibility degrade to base (existing behaviour, now documented as degrade-not-substitute).

### 2.7 Withdrawal: hide, preserve, never substitute

- Direct API: a data row absent from the current snapshot is not projected; an already-selected `.openAIConfigured` value stays selected, keeps its display name (registry is not visibility-filtered), and is labelled unavailable. The exact stored model is sent if the user runs it; the provider error surfaces unchanged.
- Codex: withdrawn dynamic records leave the picker; `.codexCustom` raw stays permissive and selected; parse knowledge for withdrawn bases is retained (§2.5) so `-max` decoding of an old selection keeps working. No retry with a neighbour, no effort downgrade, no alias substitution. `CodexAgentModeCoordinator` refresh must not rewrite a non-default explicit raw value or its effort.
- Phase 0 checks: the Oracle picker must render a selected-but-invisible configured model; `normalizeCodexSelectionForSession` must not swap a missing model for a default. Either substituting is fixed under this decision.

### 2.8 Static OpenAI models and `/v1/models` visibility: official-host-only

- On an official OpenAI host with a per-key snapshot **successfully refreshed in this session**, static models absent by exact `modelName` are hidden from new choices (the current/persisted selection stays visible as unavailable) and are never `findBestAvailableModel` fallback candidates.
- On a custom base URL (proxy/gateway alias lists routinely omit passthrough-callable IDs), static models are annotated "not listed by endpoint", excluded from fallback, and still offered.
- A cached-only (disk) snapshot never hides: a newly shipped static model must not disappear behind a stale list until discovery refreshes. Failed/malformed refreshes retain last-good and never filter.

### 2.9 Recommended-defaults backfill is out of scope

`shouldBackfillRecommendedDefaults` is doing deliberate product work today (§1.3). This plan does not retire it; a separate product issue decides whether it should survive an explicit upstream withdrawal.

### 2.10 Observability

Settings gets one `OpenAIModelCatalogStatus` value in the OpenAI section: metadata source ("Built-in baseline <version> + override" / "baseline only"), override state (absent / loaded / failed with decoder message + path), counts (baseline, override, overridden, disabled, rejected — with reason, projected), discovery source (live / last-good cached / none), last refresh time, visible-ID count, last error, and whether the typed custom ID is visible for the key; actions Reveal override file (creating the directory) and Refresh discovery. The Codex section gets one caption line ("8 models from Codex app-server · 14:32 · N known bases") plus last poll error; poll cancellation from view teardown is not a failure. Never display the API-key fingerprint; endpoints only in normalized, credential-free form. No filesystem watching; reload on Settings appearance, credential/base-URL change, and explicit reload.

### 2.11 Documentation ownership

`docs/context/gpt-model-catalog.md` (new, Authoritative) owns the durable decisions: authority model, precedence and disables, collision rule, custom-field rule, tier gating, Codex grammar and seed, Fast evidence rule, withdrawal semantics, observability contract, and an "add a model" checklist. `docs/context/claude-model-family-catalog.md` gets a cross-reference. `docs/architecture/source-layout.md` needs no change — it defines directory ownership, not individual files, and every new file lands under an existing owner. This plan moves to `docs/context/plans/completed/` when the last PR lands.

## 3. Material disagreements that survived two rounds (open — decide before implementing)

Both lanes crossed to each other's original position in round 1 and back in round 2; the final positions below are each lane's own. Neither is silently chosen.

### 3.1 Static/dynamic collision rule (`gpt-5.6-sol` generalization)

**Position 1 — whole-wire-ID ownership.** If a static `AIModel` case owns a wire ID, no `.openAIConfigured` choice is emitted for that ID. `AIModel.staticOpenAIWireModelNames` is derived from the enum and replaces the literal. Trusted metadata **may** carry rows for static IDs as non-projecting capability data (shown in Settings as "owned by built-in"), with tests that every statically owned ID has exactly one projected representation and that any static-ID row is a capability superset of its static case. Families move static → data-only only, never the reverse. Deciding argument: `.gpt56Sol` and `.openAIConfigured(gpt-5.6-sol, high)` would build requests in different branches of `OpenAIResponseRequestPlan.make` (`:157-165` vs `:168-190`); display/sort can be inherited and decode-time canonicalisation covers persistence, but any static-branch behaviour (defaults, tool wiring, token limits) silently fails to apply to the sibling, and an identity function proves identity equality, not request equivalence. Extending a family is a bounded one-time migration to data-only; because new families are data-only, the static set only shrinks.

**Position 2 — request-level identity.** Deduplicate by normalized request identity `(wireID, mode with nil → standard, effort)` via a pure `AIModel.openAIRequestIdentity` on static cases and configured selections (with a test asserting it matches what `make` emits). Only the exact-same-request configured selection is suppressed, so metadata for `gpt-5.6-sol` still projects low/high/xhigh/max and Pro. Safeguards: canonicalise at decode (a persisted `.openAIConfigured` whose identity equals a static case decodes to the static case, so it is never deduped out of the picker when the enum widens); a baseline row for a static ID must be a capability superset; configured siblings inherit the static family's display name and sort group. Deciding argument: request semantics, not the wire ID, are the stable identity; whole-ID ownership requires a code change whenever metadata reveals a valid sibling, which is the churn this work exists to remove.

**Recommendation: Position 1 for this plan**, with Position 2's superset test retained. Astra needs no sibling projection, so Position 2's benefit is not exercised by the immediate goal; Position 1 is the status quo generalized mechanically (smaller PR, no dual identity), and the request-plan fork is a concrete, verified defect path that Position 2's safeguards do not cover. If a static family later needs Pro or new efforts from data, migrate that family to data-only in one explicit change with selection-migration tests. Record the choice in `gpt-model-catalog.md`.

### 3.2 Service-tier variants for static OpenAI models

**Position 1 — gate only `.openAIConfigured` now; static and unknown-custom tier projection unchanged.** Document the split authority in `gpt-model-catalog.md` with a named follow-up audit PR that fills non-projecting `service_tiers` rows for static IDs and then flips static projection and global-tier application to metadata. Deciding argument: the flip is a billing change, not a catalog change — removing flex/priority from a static selection silently moves the user off that contract, on evidence Astra never needs, inside a PR that also carries observability. One authority with an unreviewed price change is worse than two authorities for one release.

**Position 2 — metadata becomes the sole tier authority for all Responses models in the same PR.** Conditions: every static Responses family gets an audited baseline row with `service_tiers` from OpenAI's documented flex/priority availability so nobody loses a documented tier at upgrade; an unlisted global tier is surfaced ("Flex not available for X — sending default") rather than silently dropped; persisted explicit tier wrappers remain decodable and execute exactly as stored. Deciding argument: tier choice changes billable request semantics, so two capability authorities are unacceptable, and preserving blanket static variants retains the known false-positive mechanism.

**Recommendation: Position 1.** Repository policy is to stay in scope and not remove working behaviour without evidence; the audit has a home (non-projecting rows under §3.1 Position 1) so deferral costs no structural work, and the follow-up is named rather than open-ended. Position 2's "surface the unlisted tier" UI should be carried into that follow-up.

### 3.3 Codex persistence shape

**Position 1 — additive ledger.** Keep `CodexDynamicModelRecords` as the active last-snapshot cache and its consumers untouched. Add a separate versioned ledger `CodexKnownModelBases` v1 of `(base, exact efforts, additionalSpeedTiers, serviceTiers, source: seed|observed, lastSeen)`, seeded from statics, folded once from the legacy array on first load, and unioned inside the same `updateLiveModels` write on every valid non-empty poll (single writer answers the drift objection). Bounded (≤2,048 bases) and versioned; unknown `schemaVersion` → seed only. No replacement store, no dual-write. Deciding argument: with zero-model polls treated as no-evidence (§4.1) and non-empty polls already replacing records (§1.3), the only information a new store adds is history, and history's sole consumer is the parser — which is exactly what the ledger is.

**Position 2 — unified `CodexModelCatalogStore` v2.** One versioned envelope `{version, fetchedAt, snapshotState: neverReceived|authoritative(at:), activeRecords, historicalRecords}` replacing `CodexDynamicModelStore`, single writer `CodexModelPollingService`, dual-write of `CodexDynamicModelRecords` for one release, one-shot fold of the legacy array into history; the parser consumes only an immutable derived `(base, efforts, speedTiers)` value. Deciding argument: atomic state transition — each poll simultaneously replaces active records, unions history, and changes snapshot state; separate keys permit torn state, especially for authoritative empty.

**Recommendation: Position 1**, contingent on §4.1 (zero = no-evidence). If a maintainer instead wants authoritative-empty semantics, Position 2 becomes the right shape and §4.1 should be re-decided together with it. Either way the parser-facing value type is the same, so §2.5 is unaffected.

## 4. Minor points resolved by judgment

### 4.1 Zero-model `model/list` success

Lanes ended split (authoritative-empty vs no-evidence) after both agreed the backfill stays. Resolved as **no-evidence**: retain last-good active records (else built-ins), caption "Codex reported 0 models at HH:MM" from an in-memory last-poll outcome, ledger untouched. Rationale: a working app-server has never returned zero (probe: 8); zero is operationally indistinguishable from startup/auth/pagination pathology; partial withdrawal is already representable on non-empty lists; and the product already offers models the list omits (§1.3), so "absence = withdrawal" is not a premise the codebase holds. Cost of being wrong is one poll interval.

### 4.2 Baseline delivery mechanism — embedded literal (both lanes agreed after packaging evidence).

### 4.3 Removal form — root `disabled_model_ids` rather than a per-row `enabled: false` tombstone, because a tombstone row would have to violate the row invariant (protocols and streaming required) or special-case the decoder.

### 4.4 Schema version — bump to v2 rather than add keys to v1; the decoder rejects unknown keys either way, and an explicit `unsupportedSchemaVersion(2)` is the clearer failure on older binaries.

### 4.5 PR ordering — PR 1 (OpenAI baseline + Astra) and PR 2 (Codex) are independent and may run in parallel; PR 3 (configured tier gating + observability) depends on PR 1. Chosen over "Codex first" because Astra is the user-facing ask, and over "OpenAI foundation → observability → Codex" because the Codex fix corrects live defects today (daybreak `max`/`ultra`, Fast over-grant).

### 4.6 `minimal` for Astra — omitted from the baseline; an authenticated probe (out of plan, paid) decides; add via override or baseline bump once verified.

### 4.7 `shutdown_date` from `/v1/models` — parsed if present and surfaced in status only; never acted on.

## 5. Phased plan

### Phase 0 — scout (no code)

- Confirm which `service_tier` value app-server accepts for Fast (`fast` vs `priority`, §2.6) with one request on `gpt-5.4`.
- Read the Oracle picker's rendering of a selected-but-invisible configured model and `normalizeCodexSelectionForSession` for substitution (§2.7).
- Locate the Settings slots for the OpenAI status block and Codex caption.
- Enumerate static Codex base IDs (seed) and static OpenAI wire names (`staticOpenAIWireModelNames`).
- Record a green baseline of the five existing suites.
- Validation: findings appended to this file; go/no-go recorded for §2.7 fixes.

### PR 1 — OpenAI baseline + Astra (data-only)

Files:
- new `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/OpenAIAPIModelMetadataBaseline.swift` — literal + `baselineVersion` (ISO date) + schema constant.
- `OpenAIAPIModelMetadata.swift` — schema v2 (`disabled_model_ids`, `service_tiers`, `OpenAIAPIServiceTier`), v1 compatibility, `OpenAIAPIModelMetadataDecodeReport` (rejected rows with reasons, duplicate warnings) via an additive `decodeWithReport`.
- new `OpenAIAPIModelMetadataResolver.swift` — baseline/override precedence, whole-row replacement, disables, collision handling per §3.1 decision, status counts.
- new `OpenAIAPIModelMetadataRegistry.swift` — lock-protected, synchronously readable resolved rows + display-name lookup (needed by `AIModel.displayName`, which is synchronous).
- new `OpenAIConfiguredModelProjection.swift` — `models(rows:visibleIDs:)` extracted from `configuredOpenAIModels`; custom-field trusted match (§2.3); official-host-only static filtering (§2.8).
- `AIModel.swift` — `staticOpenAIWireModelNames`; `.openAIConfigured` display name and `semanticSortMetadata` via registry; remove the `gpt-5.6-sol` display special case.
- `APISettingsViewModel.swift` — resolve → registry → projection; delete the `gpt-5.6-sol` literal (atomic with the above); track "snapshot exists for scope" rather than "array non-empty"; official-host classification reusing `shouldUseResponsesRoutingForOpenAICustomModel`.
- `OpenAIResponseRequestPlan.swift` / `OpenAIProvider.swift` — no request-shape change for Astra (configured branch already correct); only the §3.1 identity helper if Position 2 is chosen.

Tests:
- `OpenAIAPIModelMetadataTests` — baseline decodes with zero warnings; Astra row invariants (five efforts, two modes, no `none`/`minimal`/`ultra`, omitted `max_input_tokens`); v1 compatibility; v2 disables/tiers; future-version rejection; malformed override discarded whole; missing override clears layer.
- new `OpenAIAPIModelMetadataResolverTests` — whole-row replace; disables; static-ID handling per §3.1; superset test.
- new `OpenAIConfiguredModelProjectionTests` — visible Astra → exactly ten choices, no tier variants; unreported Astra hidden unless typed; typed trusted Astra → ten choices; unknown custom ID → legacy four efforts; non-official endpoint does not consume official metadata; official-host static filtering incl. current-selection exception; cached-only snapshot does not hide.
- `OpenAIConfiguredModelSelectionTests` — Astra raw-value round trips; Standard and Pro body encoding for all five efforts with `.custom("gpt-6-astra")`; no `temperature`/`top_p`; explicit output cap survives; withdrawn raw selection still decodes.
- `ModelPickerStringOrderingTests` — configured ordering; `gpt-5.6-sol` ordering pinned.

Validation: `make dev-build`; `make dev-test FILTER=OpenAIAPIModelMetadataTests`; `FILTER=OpenAIAPIModelMetadataResolverTests`; `FILTER=OpenAIConfiguredModelProjectionTests`; `FILTER=OpenAIConfiguredModelSelectionTests`; `FILTER=ModelPickerStringOrderingTests`; `make dev-format-check`; `make guardrails`; `Scripts/check-agent-context`. Manual: fresh profile with no override → Astra appears once `/v1/models` lists it; a key without Astra does not see it; typed `gpt-6-astra` exposes ten choices before rollout; request bodies carry the exact model ID and effort/mode; no Astra tier choices.

Docs: create `docs/context/gpt-model-catalog.md` (OpenAI sections, add-a-model checklist).

### PR 2 — Codex capability parsing, Fast evidence, ledger

Files:
- `CodexAppServerClient.swift:836-884` — parse `additionalSpeedTiers`, `serviceTiers`, `defaultServiceTier` into `RemoteModel`; `CodexDynamicModelRecord` carries them.
- new `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/CodexKnownModelBaseRegistry.swift` (ledger per §3.3 decision; seed; union; migration; bounded; DEBUG `test_replaceEntries`).
- `CodexReasoningEffort` — `isExtended`.
- `CodexModelSpecifier.swift` — grammar rewrite with injectable capability snapshot (§2.5).
- `CodexServiceTierVariantCatalog.swift` — delete version formula; `fastVariants(for:)` over record evidence + five-base seed (§2.6).
- `AgentCodexModelRegistry.swift`, `CodexAIModelCatalog.swift` — both synthesis sites route through `fastVariants(for:)`; `updateLiveModels` unions the ledger in the same write; `shouldBackfillRecommendedDefaults` untouched (§2.9).
- `CodexModelPollingService.swift` — zero-model handling per §4.1; in-memory last-poll outcome for the caption.
- `CodexAgentModeCoordinator.swift` — preserve explicit raw/effort across refresh (§2.7).

Tests:
- new `CodexKnownModelBaseRegistryTests` — seed; union; poll failure leaves ledger intact; migration from `CodexDynamicModelRecords`; bounds; unknown schema → seed only.
- new `CodexModelSpecifierTests` — table: `gpt-5.6-sol-max`, `gpt-5.1-codex-max` (base), `gpt-5.1-codex-max-low`, `gpt-daybreak-blue-latest-ultra` after injected record, unknown `gpt-6-astra-max` keeps suffix, adversarial `gpt-5.1-codex` + max (rule 1 wins), `maximum` alias.
- new `CodexServiceTierVariantCatalogTests` — verbatim `model/list` fixture pins the eligible set; seed ⊆ confirmed; no `gpt-6-astra-fast`, no daybreak Fast, `gpt-5.4-mini`/`gpt-5.3-codex-spark` lose Fast after a record with empty tiers.
- `CodexModelPollingServiceTests` — zero-model success retains state and records outcome; unchanged snapshots not republished; single-flight intact.
- `CodexCLIProviderReconciliationTests` — daybreak `max`/`ultra` sends base via `--model` plus separate effort config; `gpt-5.1-codex-max` sends the full base with no false effort; withdrawn selection keeps identical CLI args; Fast only for evidenced bases.
- `ModelPickerStringOrderingTests` — explicit registry injection; daybreak grouping; unavailable explicit selection not normalized away.

Validation: `make dev-build`; `make dev-test FILTER=<each suite above>`; `make dev-format-check`; `make guardrails`; `Scripts/check-agent-context`. Manual: daybreak shows `max`/`ultra` after one poll; `gpt-5.4-mini` no longer offers Fast; kill app-server mid-session → picker unchanged.

Docs: extend `gpt-model-catalog.md` (Codex sections).

### PR 3 — configured tier gating + observability

Files: `OpenAIConfiguredModelProjection.swift` (`serviceTierVariants` replacing the loop at `APISettingsViewModel.swift:2250-2261` for configured models only, per §3.2 decision); `APISettingsViewModel.swift` (`OpenAIModelCatalogStatus` publisher, reload/refresh actions); `APIModelCatalog.swift` (additive `refreshFailed` reporting without changing acceptance semantics; `shutdown_date` passthrough); `APISettingsView.swift` (status block, Reveal/Refresh, Codex caption; tier explanatory text updated); `AIModel.swift:277` used only on registry miss.

Tests: `OpenAIAPIModelMetadataTests` (`service_tiers` decode/reject); `OpenAIConfiguredModelProjectionTests` (absent → default only; listed → exact wrappers); new `OpenAIModelCatalogStatusTests` (source/count states; malformed-override presentation; no fingerprint/credential in display values; custom-ID visibility); `APIModelCatalogTests` (failure reporting retains snapshot).

Validation: coordinated commands as above; manual matrix {no / valid / malformed / static-ID override} × {discovery live / cached / failed} → status text matches the doc's table.

Docs: finalize `gpt-model-catalog.md`; cross-reference from `claude-model-family-catalog.md`; move this plan to `docs/context/plans/completed/` with an outcome summary.

## 6. Open items and follow-ups

| Item | Owner / trigger |
|---|---|
| §3.1 collision rule, §3.2 static tier authority, §3.3 persistence shape | maintainer decision before PR 1 / PR 2 respectively |
| `minimal` acceptance for Astra | authenticated probe; baseline bump |
| Fast wire value (`fast` vs `priority`) | Phase 0 |
| Static-family `service_tiers` audit and static-projection flip | follow-up PR after PR 3 (if §3.2 Position 1) |
| `shouldBackfillRecommendedDefaults` vs explicit upstream withdrawal | separate product issue |
| Signed remote metadata channel | separate security-reviewed workstream; preconditions in §2.2 |
| Chat Completions support for Astra | omitted on evidence; add via override/baseline once verified |

## 7. Phase 0 findings (2026-09-04)

Phase 0 result: **PR 1 go**. The picker preserves selected-but-invisible configured values, so PR 1 does not require PR 3 unavailable-label UI. The Codex normalization concern belongs to PR 2.

1. **Fast request probe.** With codex-cli 0.153.0, exactly one gpt-5.4 request was made. Both thread/start and turn/start accepted serviceTier="fast" and returned acceptance receipts. The completion watcher later timed out; no second request was sent. Returned objects exposed no tier field, so internal fast-to-priority normalization was not observable. The app-server caller token remains "fast".
2. **Withdrawal behavior.** AIModelDropdown renders a stored configured selection when it is absent from availableModels and does not substitute it; it does not yet show an unavailable label (PR 3). normalizeCodexSelectionForSession preserves the raw model but can rewrite an explicit effort against the default model after withdrawal (PR 2).
3. **Settings insertion slots.** APISettingsView.swift: OpenAI status belongs after the OpenAI key/base-URL stack and before the DeepSeek divider. CLIProvidersSettingsView.swift: the Codex caption belongs after connected "Using path" and before direct controls.
4. **Static source evidence.** CodexModelSpecifier.swift:88-91 seeds gpt-5.6, gpt-5.6-sol, and gpt-5.6-terra with max plus ultra, and gpt-5.6-luna with max. AgentModel.swift:250-286 owns the Codex sources used by modelsForAgent; AgentModel.swift:47-51 keeps gpt-5.5 decode-only. AIModel.swift:351 uses the actual gpt-5.1-mini name. Static OpenAI wire IDs, derived as actualName ?? rawValue, are gpt-5.2, gpt-5.2-low, gpt-5.2-high, gpt-5.2-xhigh, gpt-5.4, gpt-5.4-mini, gpt-5.4-nano, gpt-5.6-sol, gpt-5.1-codex-max, gpt-5.2-pro, and gpt-5.4-pro.
5. **Pre-change source-validating baseline.** All commands exited 0 without global-wait:
   - OpenAIAPIModelMetadataTests: 6 tests, 0 failures; ticket 7b958557-44c9-4277-bd74-1fb1deb8b6cb.
   - OpenAIConfiguredModelSelectionTests: 10 tests, 0 failures; ticket 63ef0dff-d2b6-405a-9da9-2fbfbdf59353.
   - ModelPickerStringOrderingTests: 25 tests, 0 failures; ticket 8b2859a9-e13e-49af-8b7b-8979b59abea2.
   - CodexModelPollingServiceTests: 1 test, 0 failures; ticket 971a8aac-adc5-464f-ad71-fbfbd38df6f8.
   - CodexCLIProviderReconciliationTests: 2 tests, 0 failures; ticket f8ae4edf-52b0-4c2e-be9a-dcb7bed69853.
