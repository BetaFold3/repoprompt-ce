# Completion record

Status: **Completed and closed on 2026-08-16.**
Last-verified: 2026-08-16

Outcome: **T1–T5 implemented and fully validated.** Tracker-owned OMP transcript authority, hierarchical exact-wire model projection, typed thinking transport, destination-owned persistence, separate capability authority, bounded explicit-selection probing, and shared thinking UI are shipped.

Independent OracleA and OracleB final reviews initially required changes. The bounded remediation made credits one-directional and terminal IDs/run teardown state truly run-scoped; paired denial delivery atomic; non-OMP assignment handling fail-closed; model identity canonical at the destination boundary; capability persistence and probe shutdown cancellation-safe; Context Builder and quick-selection semantics exact; empty planning sync non-destructive; and cross-provider behavior explicitly gated by regression coverage.

Final root verification passed **521/521 suites** and **5311/5311 tests**, with no remaining P0, P1, or P2 findings.

The original plan body below is preserved intact as the historical design record; its embedded Status and Authority metadata is superseded by this completion record. Durable implemented guidance remains in the [Oracle remote-models and Cursor catalog contract](../../oracle-remote-models-cursor-catalog.md) and the active [OMP provider integration plan](../omp-provider-integration.md).

---

# OMP Transcript Authority & Model UX — Implementation Plan

Scope: read when the task touches OMP Agent Mode transcript/tool-row rendering, OMP model menus or pickers, the OMP thinking selector, MCP tool-tracking observers for denied calls, or OMP thinking persistence in presets/tabs/prompt destinations.
Authority: Authoritative
Last-verified: 2026-08-16

Status: duel-settled 2026-08-16; T1–T5 implementation and bounded remediation from the completed independent OracleA + OracleB reviews are complete, with focused validation passing. Keep this plan active pending the root verifier and final documentation closure. Follow-up to [omp-provider-integration](omp-provider-integration.md) Phase 6; supersedes its §4.3 "decide at implementation time" and §4.5 "reuse before forking" for the points settled below.

Provenance: independently verified findings (current repo + installed OMP 17.3.4 source + persisted ACP model catalog), then a dual-Oracle duel — identical prompts to presets **OracleB** and **OracleC** in independent lanes, two challenge rounds, referee rulings on the two residual splits. Verified preset identity on every lane result.

## 1. Verified findings (ground truth for this plan)

- **F1 — duplicate tool rows.** OMP ACP `tool_call`/`tool_call_update` payloads carry no machine-readable tool name — only `toolCallId`, `title`, `kind`, `status`, `rawInput`. Upstream `buildToolTitle` prefers the model-supplied intent (e.g. "Other") and `mapToolKind` maps every MCP tool to `other`. `ACPRuntimeEventParsing.normalizedToolName` promotes the title to an identifier, producing an opaque provider row; the MCP tracker independently renders the authoritative row. Correlation is structurally impossible (different invocation IDs, different name+args signatures, placeholder path requires `{}` args). One real call ⇒ two rows.
- **F2 — flat menus.** 203 discovered OMP models (cursor 179, google-antigravity 19, lm-studio 5). Agent Mode routes OMP through `openCodeMenu` with suffix grouping gated to `.openCode`; the Oracle picker groups only by first path segment. `cursor/gpt-5.6-sol-{none,low,medium,high,xhigh,max}[-fast]` renders as 12 flat leaves.
- **F3 — thinking selector unimplemented.** OMP advertises a `thinking` select (category `thought_level`; options = Off + Auto + the *current model's* `getAvailableThinkingLevels()`). RepoPrompt publishes only the category-`model` selector; auxiliary selectors land in the Cursor-only map; the `.openCode, .ohMyPi` branch sets the model and returns. `google-antigravity/gemini-3.7-flash[-tiered]` has no effort-suffixed siblings — the selector is the only effort route there.
- **F4 — state model.** `ModelPreset` persists only `modelString`; `ModelDestination` applies one raw string; tabs persist `selectedModelRaw`. Presets/tabs sharing a wire model must stay independently configurable; a global per-model store is rejected.
- **F5 — tracker blind spot.** Policy-restricted MCP calls return an error *before* `fireToolCalledObservers` (`MCPConnectionManager.swift` ~11653 vs ~12084), so the tracker never sees denials. Blanket suppression of OMP provider events without fixing this would erase the only transcript evidence of denied attempts.

## 2. Duel record (settled decisions)

| # | Question | Outcome |
|---|---|---|
| D1 | Provider tool events under tracker authority | Both lanes converged on **suppression** (anchors/FIFO rejected by both after round 1). Residual split (per-row detail vs aggregate notice) refereed: **suppression + credited deferred materialization** of unmatched provider terminal failures, with **correlation-neutral wording** (OracleC's honesty constraint). See T1. |
| D2 | Denial-observer emission scope | **Unanimous after round 1**: provider-neutral `denyToolCall` funnel in `MCPConnectionManager`; opt-in `AgentToolTrackingObservationPolicy` at observer registration (default = execution-only); only OMP registrations opt into pre-execution failure reporting initially. |
| D3 | Capability acquisition trigger | **Unanimous after round 2**: automatic, bounded, fire-and-forget probe on **explicit user model selection** (never render/hover/restore/refresh). Referee: **no new settings toggle**; the manual "Load thinking levels…" action remains as the shared fallback surface. |
| D4 | Thinking persistence shape | Split after two swaps; refereed for the **per-destination map** `[exactWireID: ThinkingChoice]` (cap 32, LRU): §4.3's pinned "per-model persistence with a Default (don't-send) state" is an authoritative constraint a clear-on-switch record cannot satisfy. |
| — | T2 projector, T3 typed config (brackets rejected), T4 destination ownership, bijection gate, no eager probing | **Unanimous from round 0.** |

## 3. Track designs

### T1 — Transcript authority for managed OMP runs

While tool tracking is active for the exact `(tabID, runID)` and `selectedAgent == .ohMyPi`:

1. **Suppress every OMP provider tool stream event** — no transcript mutation, no identity claim. Decision is provider+run-scoped only; never inspects titles, args, or normalized names. Tracking absent or stale-run ⇒ current behavior (anonymous rows survive; managed pre-prompt MCP routing means production prompts never start untracked).
2. **Credited deferred failure materialization** (run-scoped, reset by `resetACPToolCorrelation(for:)`):
   - `trackerErrorCredits: Int` — increment per tracker completion with `isError`, counted before the transcript hide filter.
   - `pendingProviderFailures: [(toolCallId, title, rawInput)]` — append on provider terminal `failed`/`cancelled`, deduped by `toolCallId`, cap 64.
   - On append: if `trackerErrorCredits > 0` → decrement and discard (that failure is the denial/error the tracker already rendered — post-F5, a tracker error is causally upstream of its provider `failed` update).
   - At turn end / run teardown / cancellation: materialize each survivor as one `.toolResult` row — name = provider title, args = `rawInput`, `toolIsError = true`, note: *"Reported failed by Oh My Pi; not correlated with any RepoPrompt MCP-tracked call."*
   - **Honesty constraints (normative):** never claim a call "never reached the MCP server"; never render `N−M` arithmetic; mixed-arrival mislabeling is accepted as a rare, honestly-worded extra row rather than hidden evidence.
3. **F5 fix**: one provider-neutral `denyToolCall` funnel for every attributable pre-observer error return (at minimum the `policy.restricted` and `agentExploreControl` branches). It fires `onCalled` then `onCompleted` (`isError: true`, deterministic error JSON with a machine code, e.g. `policy_restricted`) and returns today's `toolErrorResult` **byte-identical**. Delivery is filtered by the registration's `AgentToolTrackingObservationPolicy`; only OMP registrations receive pre-execution events initially. Observer delivery stays observational: it cannot change the denial, execute a tool, or weaken policy. Pre-identity parse failures legitimately stay un-fired; the PR must inventory every `toolErrorResult(` site and document each exclusion.
4. Token accounting moves wholly to the tracker path for OMP; verify tracker-side input-token accounting before removing the provider-side `addToolInputTokens`.

Pre-code validation items: position of `invocationID`/observer-run-ID resolution relative to the policy gate (hoist if needed); exact completed-observer method name; denial must not take a `toolCardOwnershipLedger` lease.

Cursor/OpenCode/Claude: zero behavior change (asserted per provider by test).

### T2 — Dedicated OMP menu projector

New `OhMyPiModelMenuProjector` (presentation-only; identity-agnostic inputs `{sourceID, wireID, displayName}`), consumed by all four surfaces: `AgentModelOptionsMenuContent`, `AgentModelStableMenuItems`, `AgentInputBar`, `AIModelDropDown`. `.ohMyPi` is removed from `openCodeMenu` call sites (grammar untouched); `OhMyPiModelMenuBuilder` becomes projector-backed (or is deleted once call-site-free — atomic either way).

Parser rules (normative; raw wire IDs only, display names never drive grouping):

1. Namespace = first `/` component; no slash ⇒ root leaf, no synthetic provider. Grouping keys compare exactly (sort may be case-insensitive; case-distinct prefixes never merge).
2. Model segment = remainder, verbatim (may contain `/`).
3. Hyphen-suffix stripping only: at most one trailing `fast` token and at most one effort token — `none|minimal|low|medium|high|xhigh|max` — in either order, whole-token, case-insensitive for parsing. `auto` is NOT a wire token (it belongs to the thinking selector). No parenthesized/slash/colon (`:free`)/display-name variants. Never strip to empty.
4. **Corroboration gate:** a family forms only when the same namespace corroborates it (≥2 distinct efforts in a lane, or bare base + suffixed sibling, or a normal/fast pair). Singletons (`foo-high`, `foo-fast`, `grok-code-fast-1`) stay whole. Duplicate semantic slots `(base, effort, fast)` disqualify the family → all standalone leaves.
5. Hierarchy: Namespace → ModelFamily → normal lane (`Default` + efforts in fixed order None…Max) → `Fast` submenu (fast default + fast efforts). Single-leaf groups render as direct actions. No Fast cost-warning decoration (unsubstantiated for OMP).
6. Every leaf carries the exact original `wireID`/`sourceID`; the projector never fabricates a runtime value. O(n) + per-group sort; memoized per catalog snapshot.

**Bijection gate (merge-blocking):** checked-in fixture of all 203 IDs (`Tests/RepoPromptTests/AgentMode/Fixtures/OhMyPiACP/models-17.3.4.json`); flatten every leaf ⇒ multiset equality of `wireID` and `sourceID` with input, byte-identical, no loss/duplication — asserted at the projector layer AND through `AgentModelStableMenuItems.modelItems(agentKind: .ohMyPi, …)`. Adversarial fixtures: singletons, `:free`, no-slash, nested paths, bases ending in effort words, mixed case, duplicate slots, missing bare base, 12-member `gpt-5.6-sol` family, large-catalog stress budget.

### T3 — Thinking backend (typed config; brackets rejected)

Bracket encoding is rejected on three concrete falsifiers: `OhMyPiCLIProvider.requestedModelName` (exact match vs `snapshot.options` ⇒ Oracle throws), `syncACPSelectedModelFromRegistryIfNeeded` (silently resets an unknown raw to Default), and the T2 bijection invariant. Typed config makes "thinking never enters the wire model value" structural — and an executable test (scan every emitted `set_config_option`: the model selector's value never contains a thinking token).

- New `ACPConfigOptionAssignment { configID, value }` (typed key ohMyPiThinking; wire id `thinking`, category `thought_level`, allowed provider `.ohMyPi`); `ACPRunRequest.additionalConfigOptionValues` defaulting empty (all call sites source-compatible). A non-empty OMP value on another provider is an internal configuration error — fail, don't ignore.
- **Controller** (`ACPAgentSessionController`): rename `cursorParameterSelectors`/`rebuildCursorParameterSelectors`/`CursorParameterRollback` to provider-neutral auxiliary-selector names (pure rename; parsing already runs for all providers; Cursor behavior byte-identical). Add serialized `setSessionSelection(model:additionalOptions:)` under `configurationMutationMutex`; `setSessionModel` remains as a wrapper.
- **`.ohMyPi` transaction** (splits from `.openCode`): resolve/canonicalize model → mutate model iff changed, verify `requiredModelValue` → resolve thinking selector by unique category `thought_level` then id `thinking` (ambiguity ⇒ actionable failure) → re-read post-model selector snapshot (skip the no-op model mutation when unchanged; the session-authoritative snapshot suffices) → Default (no entry) ⇒ send nothing, done → explicit value: exact match against advertised values (no case-folding, no substitution; miss ⇒ actionable error listing model, value, advertised choices) → idempotent skip if current → mutate thinking, verify with dual requirement (`requiredModelValue` + `requiredSelectValue`), which also catches a runtime resetting the model on thinking change. Stale/lower-sequence snapshots ignored per `lastAppliedConfigurationSequence`.
- **Rollback** (reverse-order, best-effort, every step verified like a forward mutation): restore target-model thinking if advertised → restore previous model → restore its captured thinking. Clean rollback rethrows the original; failed rollback throws the compound "may retain partial configuration" error (Cursor's shape). Cancellation: propagate before first mutation; after, attempt rollback under the held mutex; never start a prompt after cancellation; surface partial state on cleanup failure. No prompt starts until the transaction succeeds.
- **Oracle path:** additive `AIMessage` execution metadata carrying the typed values (locate declaration with `rg`; no `AIProvider` signature change); `OhMyPiCLIProvider` → `OhMyPiAgentConfig` (defaulted) → headless provider → `ACPRunRequest`. Other providers ignore it.
- **Capability recording hook:** on every sequence-authoritative OMP snapshot with a current model and a valid thinking selector, publish `{configID, category, ordered options}` under that exact model (feeds T5; zero extra round-trips; mid-session model switches teach the cache).

### T4 — Destination-owned thinking persistence (per-model map)

New `OhMyPiThinkingSelections`: `[exactWireModelID: ThinkingChoice{value, updatedAt}]` — Codable, additive, empty-by-default.

- Default = key absence = send nothing. Explicit set updates `updatedAt`; reads don't. Cap **32 entries per destination**, LRU-evict by `updatedAt` (exact wire ID tie-break). Model switching never mutates the map. Never normalize, fuzzy-match, or transfer values between model IDs.
- Owners: `ModelPreset` (decodeIfPresent/encode-when-non-empty, preserved through editor copy flows), `TabSession` + persisted tab DTO, and per-destination Prompt maps (`chat`/`planning`/`contextBuilder`) with the same lifecycle as the existing model-name persistence. `ModelDestination` gains an optional thinking accessory (getter/applier + per-model conveniences + a `binding` overload for the preset editor); destinations without it don't render the section.
- Sync coupling: when the global Oracle/Built-in-Chat sync toggle is on, sync copies model + **whole map** atomically.
- Runtime assembly at the central model-resolution boundary only (never low-level provider global lookups): each source attaches its own destination's entry for the resolved exact model; preset invocation uses only that preset's map.
- Checkmarks from destination intent, never session state: no entry ⇒ Default; entry matching an advertised option ⇒ checked; entry excluded by an authoritative capability snapshot ⇒ selected warning row (`Unavailable: <raw>`, one-click clear), Default unchecked, runtime still fails without substitution. Capability-unknown values stay stored without warning.
- Downgrade: additive-optional everywhere; older builds ignore the keys (a preset rewrite by an old build may drop the field — acceptable, must not crash or reinterpret the model).

### T5 — Capability discovery & thinking UI

- **Registry + store:** `OhMyPiThinkingCapabilityRegistry` (lock/warm/reset per `AgentACPModelRegistry` pattern) persisting a versioned document (`omp-thinking-capabilities-v1.json`, atomic writes, corrupt ⇒ empty, invalid records skipped) of `{configID: thinking, category: thought_level, ordered options}` per exact wire model, plus `ompVersion`/`observedAt` for invalidation on binary change. Session `currentValue` is never persisted. Change-notification drives the next menu snapshot (open menus never mutate).
- **Sources:** (a) opportunistic — every real session and the existing settings refresh probe, via the T3 recording hook; (b) **lazy probe** — automatic, fire-and-forget on explicit user model selection in any picker (input bar, Oracle dropdown, preset editor). Bounds (normative): cache-first; trigger only on explicit selection (never render/hover/restore/checkmark/catalog-refresh); actor-coalesced single-flight per exact wire ID, global concurrency 1, no cross-model queueing (busy ⇒ skip; manual retry available); reuse the existing OMP no-prompt launch/bootstrap; ~8s deadline; guaranteed disposal on success/failure/cancellation; failures silent, non-durable, cooldown-limited; the selection write never waits on the probe.
- **Capability-only publication policy:** a probe controller must not update `AgentACPModelRegistry.currentModelRaw`/discovered-model preference — specifically must never create a state where `syncACPSelectedModelFromRegistryIfNeeded` resets the user's model.
- **UI:** shared `OhMyPiThinkingMenuBuilder` (rows, not controls) rendered as a sibling "Thinking" section/submenu after the model hierarchy (never multiplied into 203 model leaves): `Default` always; advertised options in upstream order (duplicate display names disambiguated by raw value); loading ⇒ disabled row; unknown/failed ⇒ informational row + enabled "Load thinking levels…" action; stale stored value ⇒ the T4 warning row. Never synthesize levels from wire suffixes. Suffix-effort families (T2) and the thinking selector remain independent axes.

## 4. File impact

New: `OhMyPiModelMenuProjector.swift`, `OhMyPiThinkingMenuBuilder.swift`, `ACPConfigOptionAssignment`/typed-values file, `OhMyPiThinkingSelections.swift`, `OhMyPiThinkingCapabilityRegistry.swift` (+ store), `OhMyPiThinkingCapabilityResolver.swift`, test suites + `models-17.3.4.json` fixture.

Modified: `AgentToolTrackingContracts.swift` (observation policy), `AgentToolTracker.swift`/controller (`startTracking` policy arg), `MCPConnectionManager.swift` (`denyToolCall` funnel + policy-filtered delivery), `ACPIntegratedAgentModeRunner.swift` (suppression + credited materialization + run-request thinking + tab helpers), `AgentModelCatalog.swift` (drop `.ohMyPi` from `openCodeMenu` call sites only), `AgentModelOptionsMenuContent.swift`, `AgentInputBar.swift`, `AIModelDropDown.swift`, `OhMyPiModelMenuBuilder.swift`, `ACPAgentProvider.swift` (`ACPRunRequest`), `ACPAgentSessionController.swift` (rename + transaction + publication policy + recording), `AgentACPModelRegistry.swift`, `OhMyPiCLIProvider.swift` + `OhMyPiAgentConfig` + headless provider, `ModelPreset.swift`, `ModelDestination.swift`, `PromptViewModel` + tab/history DTOs, `AIMessage`.

## 5. Test plan (merge gates in bold)

- T1: suppression with matching run; arbitrary titles (no "Other" special-casing); denial ⇒ exactly one failed tracker row with real name/ID and **byte-identical MCP error payload**; pre-dispatch provider failure ⇒ one deferred row with neutral wording; denial + pre-dispatch in one turn ⇒ exactly two rows; provider-failure-before-credit defensive case; stale-run no-suppression; duplicate provider updates idempotent; **Cursor/OpenCode/Claude registrations receive zero pre-execution events** and keep row cardinality; token accounting single-count; denied tool never executes.
- T2: **203-ID bijection at projector and menu-item layers**; family shape for `gpt-5.6-sol`; all adversarial fixtures; ordering stability; display-label round-trip.
- T3: transport-scripted order (model before thinking); **wire-model purity scan** (no thinking token in any model value); Default sends nothing; idempotent skip; unavailable value ⇒ actionable error + model rollback; verification-failure rollback; compound rollback-failure error; cancellation cleanup; stale-snapshot rejection; Cursor/OpenCode transactions byte-identical; non-OMP provider with OMP values ⇒ error.
- T4: two presets / two tabs same model different values independent (F4 as an explicit test); LRU cap eviction determinism; legacy documents decode empty; encode-when-non-empty; sync on/off isolation; checkmark resolution incl. duplicate display names and stale values.
- T5: **zero session starts from menu construction** (anti-probing guard); probe coalescing/single-flight/no-cross-model-queue; disposal on cancellation; capability-only publication leaves `currentModelRaw` untouched; cache round-trip, corrupt-file degradation, `ompVersion` invalidation.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Deferred-materialization mislabels a row in mixed-arrival turns | correlation-neutral wording (never a negative-existence claim); dedup by `toolCallId`; bounded list |
| Projector regression hides a model | dual-layer bijection gate on the real 203-ID fixture |
| Upstream renames the thinking selector id/category | category-then-id resolution; absence ⇒ actionable error, never silent omission |
| Partial model/thinking state after failed apply | verified reverse-order rollback + compound error; no prompt on failure |
| Probe process churn from rapid switching | explicit-selection trigger, cache-first, single-flight, concurrency 1, no queueing, deadline + guaranteed disposal |
| Old build rewrites a preset and drops the thinking field | additive-optional; loss degrades to Default (today's behavior) |
| Denial-observer emission regresses other providers | opt-in policy default execution-only; per-provider zero-event tests; funnel stays neutral so widening is a policy edit |

## 7. Implementation order

1. **T1 policy + F5 funnel** (no caller opts in; behavior unchanged; tests land).
2. **T1 OMP opt-in + suppression + credited materialization** (atomic; kills duplicate rows).
3. **T2 projector + fixture + bijection tests**, then the four UI branch splits (atomic with the Oracle builder rewrite).
4. **T3 types + controller rename** (Cursor suite green before OMP logic), then the OMP transaction.
5. **T4 persistence + destination plumbing** (values reach the transaction).
6. **T5 registry/store + recording hook + resolver + thinking UI.**
7. **Docs:** update this plan's status; amend `omp-provider-integration.md` §4.3 (settled: typed config; record the three bracket falsifiers), §4.5 (superseded by the projector + bijection invariant), §4.6 (transcript authority moves to the tracker), Phase 6 (split per track); amend `oracle-remote-models-cursor-catalog.md` Phase A (projector-backed grouping; preset thinking independence; `AIMessage` metadata transport). Run `Scripts/check-agent-context`.
