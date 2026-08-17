# Completion record

Date: 2026-08-16

Outcome: Implemented the OMP Agent Models menu projection, thinking-destination, fresh-profile, sync, and explicit capability-probe fixes described below. Stable OMP menus now preserve hierarchical exact-wire projection across the affected surfaces, Agent Models destinations use their established thinking authorities, and all six post-commit picker probes are covered.

Completion addendum: the sibling Thinking and current-selection gate passages in the preserved historical body are superseded by the implemented per-model leaf submenus and per-leaf placeholder guard. Every valid exact-wire OMP model leaf owns its Thinking children regardless of the current selection; only a literal provider-default placeholder remains an action leaf without Thinking children.

Corrected sync-matrix resolution: when Oracle/Chat sync is enabled, directional writes mirror the whole model-and-thinking-map pair using the established blank asymmetry—Oracle-side model writes mirror even a blank raw value, while Built-in Chat model writes mirror only for a non-blank raw value.

Validation: focused affected suites passed 140 tests with 0 failures; `make dev-build`, `make dev-lint`, `make dev-format-check`, `Scripts/check-agent-context`, and `Scripts/test-check-agent-context` passed. The prior `make dev-test-parallel` pass of 521/521 suites and 5328/5328 tests predates this submenu correction. The current full `make dev-test` exercised the suite but hit one unrelated transient `CursorCLIProviderTests` mock-count failure amid socket lock contention; that exact suite passed immediately in isolation. No new all-green full sweep is claimed.

Review: the current OracleA review on exact preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` found only the stale completion-record issue, now fixed. The current OracleB review on exact preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` found no P0; its in-scope SwiftUI commit-success gate, completion record, exact-leaf test, active-document wording, ledger/resource declarations, and test-safety findings were fixed and revalidated. Its structural deduplication and performance suggestions remain unimplemented follow-ups.

Known unrelated baseline caveats: `make guardrails` rejects five pre-existing tracked documents, and ledger verification reports pre-existing `missing=286` / `stale=3`; all new and renamed task IDs reconcile.

The embedded active status and authority metadata in the preserved original plan below is superseded by this completion record.

---

# OMP Agent Models Menu Projection, Thinking Destinations, and Probe Coverage — Fix Plan

Scope: read when the task touches OMP model-menu grouping in `AgentModelStableMenuItems`, Agent Models thinking destinations (`AgentModelsSettingsViewModel`, `ModelDestination`), Context Builder agent-model pickers, or `OhMyPiThinkingSelectionProbeTrigger` coverage.
Authority: Authoritative
Last-verified: 2026-08-16

Status: Duel-settled, ready to implement
Date: 2026-08-16
Provenance: independently verified repository evidence (this session's direct reads), then dual independent Oracle plans (OracleA preset `61D024A4`, OracleB preset `7CDD523E`, identical prompt and identical 53k-token selection), then one adversarial duel round. Both lanes converged on every major point; concessions are recorded inline. Follow-up work on this plan routes here; the parent feature's normative invariants stay in `docs/context/plans/completed/omp-transcript-authority-and-model-ux.md` (T2/T4/T5).

## Verified defects (all confirmed by direct reads on `dev/v1.0.29-remote-client-models`)

1. **OMP flattening on role-default menus.** Both `AgentModelStableMenuItems.modelItems` overloads (`Sources/RepoPrompt/Infrastructure/UI/Agent/AgentModelOptionsMenuContent.swift` ~538 and ~585) gate OMP projection on `groupOpenCode`. The role-default surfaces (`AgentModelsSettingsViewModel.roleDefaultMenuItems` ~492, `AgentModelsPopoverView.roleDefaultMenuItems` ~374) pass `groupOpenCode: false` for a valid OpenCode reason, so OMP accidentally renders as a flat 203-leaf list there. The SwiftUI `AgentModelOptionsMenuContent` path has no such coupling.
2. **Missing thinking wiring on Agent Models destinations.** `AgentModelsSettingsViewModel.oracleModelDestination` / `builtinChatModelDestination` are model-only, although `AgentModelsSettingsProfile` already persists `planningModelOhMyPiThinkingSelections` / `preferredComposeOhMyPiThinkingSelections` and the PromptViewModel-backed destinations wire thinking.
3. **Three Context Builder picker surfaces omit the thinking destination**: Settings → Agent Models page (`AgentModelsSettingsViewModel.contextBuilderAgentModelMenuItems`), sidebar Models popover (`AgentModelsPopoverView.contextBuilderAgentModelMenuItems`), and MCP toolbar popover (`MCPServerToggleView.contextBuilderAgentModelMenuItems` ~608–652). None fires the capability probe.
4. **Probe gap in the Quick Model Picker HUD.** `AgentModeViewModel.commitCurrentSessionModelSelection` (`AgentModeViewModel+Handoff.swift` ~56) performs explicit model selection with no `OhMyPiThinkingSelectionProbeTrigger` call, violating T5's "explicit selection in any picker".
5. **Cross-writer lost-update window in `AgentModelsSettingsViewModel`.** `updateSelectedProfile` mutates the cached `profileSnapshot`; external refresh arrives via `.agentModelsSettingsDidChange` subscribed with `.receive(on: DispatchQueue.main)` (async hop). A `PromptViewModel` profile write followed by a settings-VM write in the stale window clobbers the external write. Pre-existing; thinking writes widen it.

## Settled facts that bound the design

- **Store authority (corrects the original draft):** `PromptViewModel.contextBuilderOhMyPiThinkingSelections` reads/writes `AgentModelsSettingsProfile.contextBuilderOhMyPiThinkingSelections` — the Agent Models profile (global/workspace scope), *not* workspace chat settings. The profile is the single thinking authority for all three Context Builder surfaces; there is no second store to reconcile.
- **Field distinction:** `PromptViewModel.contextBuilderModelName` writes `chatSettings.contextBuilderModelRaw` (the AI-chat context-builder model). The CLI agent model is `contextBuilderAgentModelRaw` (profile `contextBuilderModelsByAgent`). `ModelDestination.contextBuilderModel(promptVM:)` targets the former and must not be reused; its mixed model/thinking store split is a pre-existing `// KNOWN:` inconsistency, documented but not fixed here.
- **Fixture truth:** `google-antigravity/gemini-3.7-flash` and `-tiered` are the only antigravity Gemini 3.7 IDs in the 203-ID fixture; `-low/-medium/-high` exist only under `cursor/`. Antigravity effort comes exclusively from the dynamic `thought_level` Thinking submenu; fabricating model IDs violates the T2 bijection invariant.
- **Menus rebuild by construction (duel-settled — OracleB conceded):** `StableMenuButton`'s trigger is `Button { onOpen(); presenter.present(items()) }`; the item-provider closure runs fresh on every open and reads live state (view models, `OhMyPiThinkingCapabilityRegistry.shared`, resolver state). No per-surface `ohMyPiThinkingRevision` state is added for these surfaces; the existing counters in `AgentInputBar`/`AIModelDropDown`/`OptimizedModelPicker` invalidate SwiftUI-rendered content, not StableMenu rebuilds.
- **Thinking destination is an accessory channel:** in `agentSubmenu(…thinkingDestination:)`, model selection flows through `onSelect`; the destination's model half only keys the Thinking submenu (`AgentInputBar` precedent uses an applier of `{ _ in }`). Menu actions must not additionally call `destination.apply` — that would double-persist.

## Design (final, converged)

### 1. Decouple OMP projection from `groupOpenCode`

In both `AgentModelStableMenuItems.modelItems` overloads: dispatch `.ohMyPi` to `ohMyPiModelItems` **unconditionally** (move above the `.openCode` branch); the `@MainActor` overload's guard becomes `guard agentKind == .ohMyPi else`. `groupOpenCode` keeps its name but its contract narrows to `.openCode` only — document that on all six `modelItems`/`agentSubmenu` overloads. Do **not** add a `groupOhMyPi` parameter (flat OMP is never a valid rendering; the configuration must not exist). Defer any `AgentModelMenuGroupingOptions` struct refactor to follow-up. OpenCode behavior stays byte-identical (`CursorModelSelectionSurfaceSpikeTests` flat contract must keep passing).

### 2. Fresh-read fix in `AgentModelsSettingsViewModel` (duel-settled — OracleA conceded; prerequisite for 3)

Add a private `currentProfile()` that reads fresh from `settingsManager`, recomputing `inheritanceMode` so `(scope, profile)` resolve together and persistence targets that same scope. Use it in `updateSelectedProfile`, `applyAllRecommendations`, and every destination getter, replacing `profileSnapshot` reads. Move any values precomputed from `profileSnapshot` (e.g. role overrides in `persistRoleDefaultOverrides` / `setRoleDefaultSelection`) into the fresh-read mutation. All existing mutation closures are field-scoped (audited); no closure reads a field it also writes from displayed state.

### 3. Thinking accessors for Oracle / Built-in Chat destinations

Add `thinkingGetter`/`thinkingApplier` to `oracleModelDestination` (`agentModels.oracle`) and `builtinChatModelDestination` (`agentModels.builtinChat`), backed by the profile maps via new private `setOracleThinkingSelections(_:)` / `setBuiltinChatThinkingSelections(_:)`. Each operation mutates and persists one profile exactly once.

**Sync matrix (must match the `PromptViewModel` setters exactly so both write paths converge):**

| Trigger | Local write | Additional write when `syncChatModelWithOracle` is on |
|---|---|---|
| Set Oracle model | `planningModelRaw = raw` | `preferredComposeModelRaw = raw` **and** whole planning map → compose map (unconditional, including blank raw — matches `setPlanningModelRaw`) |
| Set Built-in Chat model | `preferredComposeModelRaw = raw` | if raw non-blank: `planningModelRaw = raw` **and** whole compose map → planning map; blank mirrors nothing (matches `setPreferredModelRaw`) |
| Oracle thinking write | replace planning map | if `planningModelRaw` non-blank: re-assert `preferredComposeModelRaw = planningModelRaw` **and** copy whole map |
| Built-in Chat thinking write | replace compose map | if `preferredComposeModelRaw` non-blank: re-assert `planningModelRaw` **and** copy whole map |
| `applyOracleRecommendation` / chat branch of `applyAllRecommendations` | both model fields (existing behavior, ungated) | copy Oracle map → Chat map, whole-map, **gated on the toggle** and on non-blank recommended raw |

Resolution note (2026-08-16, integration-audit ambiguity): an earlier revision of the two model-selection rows listed only the model mirror. That contradicted the normative clause above; the clause wins. Verified on disk: `PromptViewModel.setPlanningModelRaw` and `setPreferredModelRaw` both copy the whole thinking map alongside the model under sync (Oracle-side unguarded, chat-side gated on non-blank raw, guard covering both writes). A sync-directional model write re-asserts the whole (model, map) pair — anything less lets the persisted state depend on which surface performed the same user action. This is whole-map replacement between the coupled destinations (already-shipped setter behavior), not entry-level mutation, so T4's "model switching never mutates the map" is not implicated.

Deliberate asymmetry, documented in code: model writes may mirror blank (explicit intent); thinking writes never re-assert a blank model. Recommendation paths keep their pre-existing ungated dual model write, but the map copy is toggle-gated — note the discrepancy in a comment so nobody "fixes" it by ungating the map. Sync OFF: recommendation apply leaves **both maps completely untouched** (maps key on exact wire IDs; absence = Default; cross-destination copies violate T4 ownership; clearing violates "model switching never mutates the map").

### 4. Context Builder agent-model destinations (two implementations, one authority)

- `ModelDestination.contextBuilderAgentModel(promptVM:)` (id `contextBuilderAgentModel`) in `ModelDestination.swift`: getter `contextBuilderAgentModelRaw`; applier routes through `selectContextBuilderAgentModel` + commit; thinking getter/applier `promptVM.contextBuilderOhMyPiThinkingSelections` (already `.userInitiated`). Used by the sidebar popover and MCP toolbar popover.
- `AgentModelsSettingsViewModel.contextBuilderAgentModelDestination` (id `agentModels.contextBuilderAgentModel`): model half via `setContextBuilderSelection`; thinking applier through `updateSelectedProfile` with `contextBuilderWriteIntent: .userInitiated`.
- Wire the `thinkingDestination:` `agentSubmenu` overload into all three Context Builder surfaces. **Placeholder guard:** attach the destination only when `contextBuilderAgent == .ohMyPi` and `OhMyPiCanonicalModelIdentity.exactWireID(for: rawModel) != nil`; otherwise fall back to the model-only overload (mirrors `AgentInputBar.inputBarOhMyPiThinkingDestination`). Prevents a Thinking submenu keyed on the literal `default` placeholder. **SUPERSEDED:** this current-selection gate was replaced by per-model leaf submenus with an exact-wire placeholder guard applied independently to each leaf.
- Document (do not fix) the legacy `contextBuilderModel(promptVM:)` mixed-store inconsistency with a `// KNOWN:` note.
- Add a `// Do not hoist:` comment at each of the three `StableMenuButton(items:)` call sites: correctness of capability refresh rests on `items` staying a closure invoked at open time.

### 5. Probe coverage — six sites, never in shared helpers

Fire `OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(agent:rawModel:)` after successful selection commit at: (1) settings-page Context Builder `onSelect`, (2) sidebar popover Context Builder `onSelect`, (3) MCP toolbar popover Context Builder `onSelect`, (4) settings-page role-default `onSelect`, (5) sidebar popover role-default `onSelect`, (6) HUD commit path `commitCurrentSessionModelSelection` after `selectModel(rawModel:)`, passing the session's selected agent (the trigger self-gates on `.ohMyPi` and wire-ID validity — no call-site branch). Never inside `modelItem`, `ohMyPiModelItems`, or any shared helper (`performAllActions(in:)` bijection tests execute all 203 actions). Role defaults get projection + probe but **no** Thinking submenu (no per-role thinking owner exists; comment the omission as deliberate at both sites).

**Test guard:** `#if DEBUG` `isDisabledForTesting` (synchronized, `@_spi(TestSupport)` or equivalent) on `OhMyPiThinkingSelectionProbeTrigger`, checked in both `afterExplicitSelection` overloads, set in `setUp`/reset in `tearDown` of suites that execute view-model menu actions or session-model commits — two of the six sites live in unit-testable view models.

### 6. Explicit non-goals

- No per-role thinking storage (persistence-shape change; out of scope).
- Quick Model Picker HUD stays a flat searchable leaf index (only its probe gap is fixed).
- No changes to `OhMyPiModelMenuProjector`, capability registry/resolver internals, `GlobalSettingsDocument`, or persistence shapes. **No migration needed or written** — all fields already `decodeIfPresent`/encode-when-non-empty; old↔new documents degrade to Default both ways.
- Legacy `contextBuilderModel(promptVM:)` mixed-store split: documented follow-up only.

## File-by-file impact

| File | Change |
|---|---|
| `Infrastructure/UI/Agent/AgentModelOptionsMenuContent.swift` | Unconditional `.ohMyPi` dispatch in both `modelItems` overloads; narrowed `groupOpenCode` doc comments on all six overloads |
| `Features/AgentMode/ViewModels/UI/AgentModelsSettingsViewModel.swift` | `currentProfile()` fresh reads; thinking accessors + sync helpers; `contextBuilderAgentModelDestination`; recommendation-path map sync; probe firing (Context Builder + role defaults); deliberate-omission comment on role defaults |
| `Infrastructure/UI/Components/ModelDestination.swift` | `contextBuilderAgentModel(promptVM:)`; `// KNOWN:` note on `contextBuilderModel(promptVM:)` |
| `Features/AgentMode/Views/AgentModelsPopoverView.swift` | Guarded thinking destination for Context Builder; probe firing (Context Builder + role defaults); do-not-hoist comment |
| `Infrastructure/UI/Components/MCPServerToggleView.swift` | Same Context Builder wiring + probe + do-not-hoist comment (easy to miss: lives outside the AgentMode folder) |
| `Features/AgentMode/ViewModels/AgentModeViewModel+Handoff.swift` | Probe after `selectModel` in `commitCurrentSessionModelSelection` |
| `Infrastructure/AI/Providers/OhMyPi/OhMyPiThinkingCapabilityResolver.swift` | DEBUG-only synchronized `isDisabledForTesting` on the trigger |

## Test plan (ordered; `make dev-test FILTER=<Suite>`)

1. `OhMyPiModelCatalogTests` — baseline green before edits; after step 1: **new** `testOhMyPiIgnoresGroupOpenCodeFlagAndAlwaysProjects` (203-ID fixture, `groupOpenCode: false`, assert hierarchy + full bijection via `performAllActions`), `testAntigravityGeminiHasNoFabricatedEffortLeaves`.
2. `CursorModelSelectionSurfaceSpikeTests` — unchanged; `.openCode` + `groupOpenCode:false` stays flat.
3. `OhMyPiThinkingCapabilityTests` — existing invariants stay green (`testMenuConstructionStartsNoProbe`, single-sibling Thinking **[SUPERSEDED: Thinking children now live under each valid per-model leaf]**); **new** `testContextBuilderSurfaceAddsExactlyOneThinkingSubmenu`, `testThinkingSubmenuAbsentForPlaceholderModel`, `testReopenedThinkingMenuReflectsNewlyLearnedCapabilities` (same builder invoked twice around an injected-registry `record`, pinning by-construction rebuild without asserting SwiftUI).
4. **New** settings-VM suite (e.g. `AgentModelsSettingsOhMyPiTests`): independent maps sync-off; Oracle thinking write mirrors (model, map) sync-on; Chat thinking write mirrors when compose raw non-blank; blank-chat guard through the thinking path; blank-source thinking write does not mirror; `testRecommendationApplyMirrorsThinkingMapWhenSyncOn`; `testRecommendationApplyLeavesBothThinkingMapsUntouchedWhenSyncOff`; `testUpdateSelectedProfileReadsFreshProfile` (external `settingsManager` write survives a subsequent VM write to a different field); Context Builder `.userInitiated` intent preserved; prompt-backed destination never touches `ChatSettings.contextBuilderModelRaw`.
5. Existing settings/prompt sweeps: `SettingsJSONOnlyPersistenceTests`, the Agent Models settings suite, PromptViewModel sync suites.
6. `make dev-build`, `make dev-lint`, `make dev-format-check`, full `make dev-test` before merge; `Scripts/check-agent-context` after doc updates.

Manual validation with OMP connected: role-default menus hierarchical (namespace → family → efforts/Fast), not 203 flat rows; select `google-antigravity/gemini-3.7-flash` on a Context Builder surface → reopen → Thinking shows advertised levels (or the informational load row if OMP advertises none — that is upstream truth, not a bug); Oracle↔Chat sync mirrors thinking maps directionally with blank guards intact; sidebar and MCP popovers show the same Thinking selection (single authority).

## Duel record (for future context)

- OracleA conceded staleness (fresh-read required; scope+profile must resolve together). OracleB conceded capability refresh (StableMenuButton rebuilds items every open; revision state withdrawn, replaced by do-not-hoist comments + rebuild test).
- Jointly added beyond the original draft: recommendation-path map sync with toggle-gated copy; six probe sites including the HUD commit; DEBUG probe test guard; placeholder wire-ID guard; `MCPServerToggleView` as the third Context Builder surface.
