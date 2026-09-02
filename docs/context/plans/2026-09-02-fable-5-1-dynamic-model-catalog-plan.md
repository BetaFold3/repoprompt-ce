# Fable 5.1 Support + Dynamic Claude Model Family Catalog — Implementation Plan

Scope: read when the task touches Claude Fable 5.1 static catalog support, Anthropic adaptive-effort family shaping, or the planned dynamic Claude model-family registry and grammar.
Authority: Authoritative
Last-verified: 2026-09-02

- **Date:** 2026-09-02
- **Status:** Phases 1a/1b and 2 implemented; Phases 3–4 planned
- **Provenance:** Two independent Oracle consultations (OracleE, OracleD) received an identical prompt with verified repo/upstream facts; material disagreements were cross-examined anonymously over two rounds; minor points were resolved by the orchestrating agent with its own verification. Lane identity checks (`model_preset_id`/`model_preset_name`) passed on every send.

## 1. Goals

1. Make Claude Fable 5.1 (exact ID `claude-fable-5-1`) selectable and correctly executed on both Claude paths: the Claude Code CLI path (Agent Mode + Oracle-through-CLI) and the native Anthropic API path.
2. Add a dynamic model catalog so same-family numeric point releases (fable-5 → 5-1 → future 5-2; analogous opus-5/sonnet-5 releases) become usable automatically once they appear in Anthropic's official `GET /v1/models`, with no per-release code change. Guiding requirement: *if we support fable-5 and fable-5-1 is listed by the official API, the app supports it too.* The Claude Code static catalog stays manually maintained (sole-user decision), but the recurring per-point-release cost is removed.

**Non-goals:** structured thinking-block persistence/replay (deferred, see §6); Cursor/OMP/GLM/Kimi/compatible-backend catalogs; provider defaults (`opus`, effort `.high`); pricing presentation; `GlobalSettingsDocument` schema; the provider package's seam (no network/persistence enters the package).

## 2. Verified pre-implementation state (evidence)

- `claude-fable-5-1` appears nowhere in the repo. Local CLI is 2.1.258 (supports Fable 5.1).
- **Four Claude Code static authorities** must agree for a model to be usable: package catalog (`ClaudeCompatibleProviderPlugin.swift:237,249–254`), `AgentModel` enum (`AgentModel.swift:83` — persisted raw values; "no dynamic probing" comment at :82), adapter XHigh set (`ClaudeCompatibleModelCatalogAdapter.swift:386–393`), Oracle picker table + validation gate (`ClaudeCodeAIModelCatalog.swift:26`, `validatedModel` :66–80 rejects unknown base IDs).
- **Anthropic API path:** `AnthropicAPIModelsClient` decodes only `id` (:41–43); unknown IDs → `.anthropicCustom` (:155–161). `AnthropicModelConfiguration.resolve` (:39–46) grants adaptive thinking + effort **only** to literal `claude-opus-5`; everything else gets legacy `thinking: .none`, and `AnthropicProvider.createRequestPlan` passes `defaultTemperature: 0` (:47–61) — so any fable-family ID selected via API today sends `temperature` and hard-400s. The encoder already supports adaptive thinking, `output_config.effort`, temperature suppression, and the `output-128k` beta header (`AnthropicRequestPlan.swift:39–41,97–123`; `AnthropicProvider.swift:8`).
- **Fable 5.1 API contract (verified via Claude Code 2.1.258 reference):** 1M context, 128K max output; thinking always on (explicit disabled/enabled+budget → 400); sampling params → 400; effort low/medium/high/xhigh/max (API default high); forced `tool_choice` any/tool → 400; refusal `stop_reason` possible on HTTP 200; preserved-thinking history-editing check. Models API returns `display_name`, `max_input_tokens`, `max_tokens`, `capabilities`.
- **Precedent:** durable dynamic catalog semantics in `docs/context/oracle-remote-models-cursor-catalog.md` (versioned envelope, atomic replacement, last-good retention, injectable for tests).

## 3. Design summary (converged)

Two cooperating mechanisms with a strict split of responsibilities:

- **Family grammar + trait table (keyless, deterministic)** governs *validation and request shaping*. Anchored allowlist `{claude-fable-5, claude-opus-5, claude-sonnet-5}`; strict same-major numeric point-release parsing (`claude-<family>-<major>[-<minor>][-<YYYYMMDD>]`, numeric components only; minor required for point-release status; segment-boundary matching so `claude-fable-5` covers `claude-fable-5-1` but never `claude-fable-50`; rejects `claude-fable-6`, `-preview`/`-beta` suffixes, `-thinking` synthetics, substring lookalikes). New majors deliberately require one curated row. Exact-ID override rows always beat family rules.
- **Persisted `/v1/models` registry (keyed, metadata-rich)** governs *picker listing and enrichment* (display names, exact token limits). Listing is registry-gated — the app never fabricates picker entries for models the official API hasn't listed. Validation is grammar-based — persisted/remote/MCP-supplied IDs never break keylessly.

Request shaping moves from the literal `claude-opus-5` branch to a classifier (`AnthropicModelFamilyTraits`): `.adaptiveEffort` (adaptive thinking, sampling suppressed, `output_config.effort`, default `.high`) vs `.legacy` (current suffix-driven behavior, byte-identical). Fable-5 and fable-5-1 families and opus-5 classify `.adaptiveEffort` now; **sonnet-5 stays `.legacy` on the API path until a live probe verifies its contract** (it remains fully supported via CLI). On behavior drift in a future family member (e.g. rejected `output_config`): surface the provider error naming the exact model — never silently downgrade, retry another model, or lower effort; a one-line exact-ID override pins the fix. `capabilities` payloads are decoded and persisted from day one but not trusted for shaping until their vocabulary is verified against a real fixture.

## 4. Phases

### Phase 1a — Static Fable 5.1, Claude Code path (atomic)

All four authorities in one step (a package option without an `AgentModel` case lists but fails validation — inconsistent UI state):

1. `ClaudeCompatibleProviderPlugin.swift`: `fable51Raw = "claude-fable-5-1"`; `StaticModel(displayName: "Fable 5.1", supportsXHigh: true)` inserted before Fable 5.
2. `AgentModel.swift`: `case claudeFable51 = "claude-fable-5-1"`; displayName "Fable 5.1"; description in the fable-5 style; ordering `…defaultModel, .claudeFable51, .claudeFable5, .claudeOpus1m,…`; `contextWindowTokens` → 1_000_000; **discovery tags `[.complex, .engineering, .pair, .extendedContext]` move from `.claudeFable5` to `.claudeFable51`** (5.1 supersedes 5 at the same price/context); fable-5 stays selectable and decodable, untagged.
3. `ClaudeCodeAIModelCatalog.swift`: `ModelDefinition("claude-fable-5-1", "Fable 5.1", [.low,.medium,.high,.max,.xhigh])` at index 0.
4. `ClaudeCompatibleModelCatalogAdapter.swift`: add `claudeFable51` to `claudeXHighEligibleBaseRaws`.

Defaults unchanged everywhere: provider default stays `opus`; app effort default stays `.high` (CLI's own xhigh default divergence documented, not adopted). No settings migration; raw strings round-trip.

### Phase 1b — Anthropic API request shaping + refusal guard

1. **New** `AnthropicModelFamilyTraits.swift`: classifier (exact overrides first, then family anchors, boundary-safe); carries known context window (fable family → 1M) and known max-output (128K) so capability metadata does not depend on registry state.
2. `AnthropicModelConfiguration.resolve`: strip legacy `-thinking` suffixes, classify base; `.adaptiveEffort` → adaptive thinking, `effort = requested ?? .high`, sampling suppressed (this alone fixes the existing fable-5 temperature-400); Fable-family traits use a 16K implicit max-token floor so the production nil-`maxTokens` path leaves room for adaptive thinking, while the exact Opus-5 override preserves its existing nil default; `.legacy` path remains byte-identical, including the `unsupportedEffort` throw. Opus-5 migrates onto the classifier — the literal branch is deleted, no third literal is ever added.
3. `AIModelCapabilityMetadata`: `.anthropicCustom(name:)` consults trait table (fable family → `(1M, .exact)`) before returning `(nil, nil)`; registry lookup lands ahead of this in Phase 2. Enforce known max-output ceiling in `AnthropicRequestPlan.resolve` (reject `requestedMaxTokens` above a known limit) — a few lines beside the existing budget validation.
4. **Refusal handling (in scope — converged in round 2):** first verify (U8) whether the pinned SwiftAnthropic types already decode terminal `stop_reason` (likely, since `end_turn` vs `max_tokens` must be distinguishable). Favorable → ~15-line provider-local guard; unfavorable → narrowest local decode of terminal `stop_reason` only (never a transport replacement). On `refusal`: streaming finishes with typed `AnthropicProviderResponseError.refusal` after already-emitted deltas (no successful `message_stop`); non-streaming throws. `stop_details` included only if the pinned types already expose it; otherwise a bounded message. One focused terminal-state test in an existing suite where possible.

### Phase 2 — Models API metadata + persisted registry (implemented)

1. `AnthropicAPIModelsClient`: decode `display_name`, `max_input_tokens`, `max_tokens` (as maxOutputTokens), `capabilities` (lossless, optional, absence tolerated); new `fetchModels() -> [AnthropicDiscoveredModel]`; keep `fetchModelIDs()` as a mapping wrapper so existing call sites/tests stay intact; retain cursor-loop/page-limit protections; atomic validation across the full paginated result.
2. **New** `AnthropicDiscoveredModelStore` (Cursor-store pattern): injectable storage, versioned envelope (`AnthropicModelCatalogV1`: version, fetchedAt, models), synchronous hydration at init, atomic whole-replacement, last-good retention on transient failure, corrupt/future-version envelopes ignored but preserved, cleared **only** on a structurally valid empty response, **not cleared on API-key removal** (models stay runnable via CLI), monotone `revision` for memoization, main-queue change notification.
3. `APISettingsViewModel`: Anthropic loader fetches descriptors and returns `.map(\.id)` so the published `availableAnthropicModels: [String]` contract is unchanged; `APIModelCatalog` carries a narrow accepted-commit payload so descriptors reach the store only after the refresh generation is accepted, preventing stale-scope commits while preserving OpenAI and stored snapshot compatibility. Refresh triggers: existing ones (launch / key change / scope change) plus a forced refresh after successful key validation; **no TTL loop** (single-user app; launch refresh suffices — orchestrator resolution of a minor divergence).

### Phase 3 — Family grammar + dynamic pass-through

1. **New** `ClaudeModelFamilyCatalog.swift` (pure, no I/O): anchor allowlist; `PointRelease` parsing per §3 grammar; generated display names ("Fable 5.2"); family metadata (efforts, xhigh, context window, API request shape). `AnthropicModelFamilyTraits` re-bases on these anchors — exactly one allowlist.
2. `ClaudeCodeAIModelCatalog`: `effectiveDefinitions()` = static table + registry-corroborated point releases (exact discovered ID as `runtimeModelRaw` — wire-ID bijection; family efforts; registry display name ?? generated), sorted descending minor before the family anchor; memoized on store `revision`; `validatedModel` gains a grammar branch (registry-independent) when definition lookup fails; injectable registry parameter for tests.
3. `ClaudeCompatibleModelCatalogAdapter` (`.claudeCode` only): `isValid` accepts grammar-valid point releases with family-effort membership when `AgentModel.resolvedModel` is nil (GLM/Kimi/custom slots untouched); xhigh via static set OR `pointRelease(…)?.family.xhighEligible`; catalog snapshot splices registry-corroborated dynamic options (with effort-variant expansion) before the family anchor — package untouched.
4. Context-window fallbacks: sidebar/discovery and `AIModelCapabilityMetadata.claudeCodeModel` try `AgentModel` → family catalog → 200K provider fallback; `.anthropicCustom` tries registry `max_input_tokens` (`.exact`) → trait fallback. Dynamic entries stay untagged (usability ≠ recommendation promotion; a future 5.2 runs immediately but doesn't replace 5.1 as recommendation target until promoted).
5. Withdrawal: an authoritative refresh that drops a model removes it from *new* picker choices only; stored raw strings are preserved; a run attempt fails loudly naming the exact raw — no silent substitution.
6. Trust boundary: registry content is remote data — only grammar-valid IDs may reach CLI arguments or picker entries; display names length-capped. Grammar-valid-but-nonexistent IDs (typos via MCP) surface as CLI runtime errors — accepted trade-off.

### Phase 4 — Consistency guard, docs, final validation

1. **New** `ClaudeStaticCatalogConsistencyTests`: asserts the four static authorities agree on what they *do* share for modern families (presence, display name, xhigh eligibility; date-suffix-normalized; static xhigh set ≡ package `supportsXHigh`-derived membership *where options carry effort levels*). Read the package's effort-set derivation first (U2) so the test pins intended, not accidental, relationships.
2. Docs: update `docs/architecture/provider-plugins.md` (registry/grammar are core-owned; package untouched; compatible backends excluded from the overlay); new `docs/context/claude-model-family-catalog.md` (grammar, registry semantics, drift playbook, new-family checklist, CLI-vs-app effort-default divergence, rollback caveat). Run `Scripts/check-agent-context`.
3. Live probes (paid, explicit): U3 sonnet-5 API contract before enrolling it; U5 two-turn fable-5-1 API probe (preserved-thinking deferral gate); one Fable 5.1 smoke through the CE debug app.

## 5. Material disagreements and resolutions

### D1 — First-class `AIModel` case for Fable 5.1 on the API path: **RESOLVED — Position B adopted**

Both lanes swapped in round 1 and re-diverged in round 2 (each holding the position the *other* originally proposed).

- **Position A (add `AIModel.claude51Fable`):** Fable 5.1 is a deliberate promotion, and the codebase's promotion pattern is a first-class case (`.claude5Opus`, `AIModel.swift:132/361`); a static case gives exact `(1M, .exact)` capability metadata and a `maxTokens` 128K home independent of registry/classifier reachability, and a proper display name before any fetch. Future releases need no case — one case per *promotion*, not per release. Condition: shaping must route through the classifier on `rawValue`; no new literal branch.
- **Position B (no new `AIModel` case):** every claimed benefit is supplied by layers this change builds unconditionally — classifier keys on the raw string identically for `.anthropicCustom`; trait table carries 1M/128K statically (keyless); registry supplies display name after the first launch fetch of any keyed session, and the API path is unusable without a key anyway. The case adds exhaustive-switch churn across `StaticIdentity`/`ModelInfo`/`maxTokens`/`fromModelName`/discovery mapping, splits the fable family across two representations on the one path meant to be uniform (fable-5 stays `.anthropicCustom`), and the `.claude5Opus` precedent predates the dynamic mechanism. Promotion semantics (tags, recommendations) live on `AgentModel`, which keeps its case; no API-side recommendation surface consumes an `AIModel` case.
- **Resolution (orchestrator): Position B adopted — do not add the case.** Position B is more coherent with the feature's purpose, and its factual premises were independently verified (trait-table capability fallback landed in Phase 1b, so exact metadata does not wait for the registry; the API path genuinely requires a key). Keep B's safeguards: assert discovered `claude-fable-5-1` → `.anthropicCustom`, and enrich `.anthropicCustom` display names from the registry.

### D2 — Claude Code catalog consolidation: **RESOLVED (converged, round 2)**

One lane initially proposed making the package snapshot authoritative for new entries (freezing `ClaudeCodeAIModelCatalog` as a legacy overlay) and deleting the adapter's `claudeXHighEligibleBaseRaws` as redundant. Resolution, accepted by both lanes: **no structural consolidation this change.** The four authorities' divergences are load-bearing (Oracle sonnet efforts `[low,medium,high]`, haiku `[]`, dated `claude-opus-4-5-20251101` vs undated `AgentModel` raw); orchestrator verification showed the xhigh check site (`:217`) has no snapshot access today and one option-construction path (`:71`) builds options with `supportedEffortLevels: []`, so a naive snapshot-derived membership test could silently invalidate efforts. Keep the set (+1 line for 5.1); guard all four with `ClaudeStaticCatalogConsistencyTests`; the dynamic grammar removes the recurring per-release cost that motivated consolidation; file set-deletion as a follow-up gated on unifying effort-level population across construction paths.

### D3 — Refusal `stop_reason` handling: **RESOLVED (converged, round 2): in scope**

One lane initially deferred it. Resolution, accepted by both lanes: this change itself converts fable-on-API from a loud failure (temperature 400) into the first path where refusal becomes reachable; shipping the enablement while deferring the guard trades a visible error for a silent wrong result (partial/empty text + successful `message_stop`) — unacceptable in a single-user app with no telemetry. Scope per Phase 1b: keyed on `stop_reason == "refusal"` alone; U8 selects the implementation route (existing decode vs narrowest local decode), never deferral; `stop_details` only if already exposed; one focused test.

### Minor points (orchestrator-resolved)

- **Refresh policy:** existing triggers + forced refresh on successful key validation; no 6-hour TTL loop (complexity without benefit for a relaunch-friendly single-user app).
- **Max-output ceiling:** enforced in `AnthropicRequestPlan.resolve` from trait/registry data (a few lines beside existing validation) rather than deferred.
- **Grammar details:** numeric components only; optional trailing 8-digit date suffix accepted; minor version required for point-release treatment.
- **Preserved thinking: deferred (both lanes agreed throughout).** The provider replays text-only history, so the history-*editing* check cannot trip; cost is reasoning-continuity quality, not correctness. Add a regression test pinning that history encoding emits no thinking blocks, a boundary comment, and gate any future API-path multi-turn recommendation on the U5 probe.

## 6. Test strategy and validation

| Phase | Deliberate contract updates | New tests | Smallest validation |
|---|---|---|---|
| 1a | `ModelPickerStringOrderingTests` (first group → fable-5-1; CLI resolution + xhigh); `ClaudeCompatibleRuntimeSupportTests`, `ClaudeCompatiblePluginBridgeTests` gain 5.1 assertions (options, efforts, menu, 1M discovery) | `AgentRuntimeSidebarViewModelTests` 5.1→1M; `AgentModelSelectionIndexTests` selection/search | `make dev-provider-test FILTER=ClaudeCompatibleRuntimeSupportTests`; `make dev-test FILTER='ClaudeCompatiblePluginBridgeTests\|ModelPickerStringOrderingTests\|AgentRuntimeSidebarViewModelTests\|AgentModelSelectionIndexTests'` |
| 1b | — | `AnthropicRequestPlanTests`: fable-5/5-1 → adaptive + default-high + effort passthrough; encoded JSON has `thinking:{type:"adaptive"}`, `output_config.effort`, no `temperature`; boundary `claude-fable-50` stays legacy; opus-5 tests stay green; ceiling enforcement; refusal terminal-state test (existing suite if possible) | `make dev-test FILTER=AnthropicRequestPlanTests` (+ provider suite) |
| 2 | `AnthropicAPIModelsClientTests` extended (metadata decode, absence tolerated, discovered 5.1 → `.anthropicCustom` per D1 recommendation) | `AnthropicDiscoveredModelStoreTests` (hydration, atomic apply, last-good, corrupt-envelope, empty-clear, key-removal non-clear) — surgical curated-ledger rows, never regenerate | `make dev-test FILTER='AnthropicAPIModelsClientTests\|AnthropicDiscoveredModelStoreTests'` |
| 3 | Adapter/catalog tests with injected registry | `ClaudeModelFamilyCatalogTests` (grammar accept/reject matrix); registry-gated listing vs grammar-only validation; splice ordering; sidebar 5.2→1M via family | `make dev-test FILTER='ClaudeModelFamilyCatalogTests\|ClaudeCompatiblePluginBridgeTests\|ModelPickerStringOrderingTests'` |
| 4 | — | `ClaudeStaticCatalogConsistencyTests` | `make dev-test FILTER=ClaudeStaticCatalogConsistencyTests`; `Scripts/check-agent-context`; `make dev-lint`; `make dev-swift-build PRODUCT=RepoPrompt`; final unfiltered `make dev-test-parallel` |

Pre-landing audit (U4): grep root tests for exact-equality assertions over `.claudeCode` option lists / menu groups / discovery snapshots before Phases 1a and 3; update each deliberately.

## 7. Risks

- **Rollback:** an older binary cannot decode a persisted `claudeFable51` selection — accepted (single-user, forward-only), documented.
- **Grammar false positives:** well-formed nonexistent IDs validate and fail at CLI runtime; contained by registry-gated listing (users cannot *pick* a nonexistent ID).
- **Trait drift:** future family member changes behavior → surfaced 400 + one-line exact-ID override; capabilities-derived traits are the eventual refinement once the vocabulary is fixture-verified.
- **API discovery ≠ CLI entitlement:** an API-listed model may be unavailable to the Claude Code subscription; the CLI's exact-model error is authoritative; no silent retry.
- **Discovery payload growth:** dynamic options enlarge `list_agents` output; audit snapshot-style tests (U4); dynamic entries stay untagged.
- **Refusal streaming:** partial deltas may precede the terminal refusal; the turn must finish failed without retracting shown text.

## 8. Unknowns to validate during implementation

- **U1** `APIModelCatalog` snapshot payload generality (descriptor carry-through vs side-channel).
- **U2** Package `supportedEfforts(supportsXHigh:)` derivation (pin intended consistency relationships).
- **U3** Sonnet-5 direct-API contract probe before `.adaptiveEffort` enrollment.
- **U4** Exact-list assertion audit across root tests.
- **U5** Two-turn fable-5-1 API probe (preserved-thinking gate).
- **U6** Exact sidebar window-resolution helper site.
- **U7** Confirm `AgentModelCatalog.supportedClaudeEfforts` routes solely through the adapter.
- **U8** Whether pinned SwiftAnthropic types already decode terminal `stop_reason` (selects refusal implementation route).
