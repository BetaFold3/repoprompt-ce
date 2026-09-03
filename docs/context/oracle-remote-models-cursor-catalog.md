# Oracle remote models and Cursor parameter catalog

Scope: read when the task touches Oracle remote-client models for Cursor or Oh My Pi (OMP), Cursor parameter-catalog persistence/polling/status, OMP Oracle model discovery or execution, or Cursor parameter metadata in `agent_manage list_agents`.
Authority: Authoritative
Last-verified: 2026-09-03

## Ownership

The implementation is split deliberately; do not introduce a parallel model or parameter authority.

- Oracle model identity and provider routing: `Sources/RepoPrompt/Infrastructure/AI/AIModel.swift` and `Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift`.
- Dynamic ACP model authority: `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentACPModelRegistry.swift` and `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/ACPAIModelCatalog.swift`.
- OMP Oracle execution: `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiCLIProvider.swift` and the OMP ACP headless provider.
- Shared one-shot lifecycle: `Sources/RepoPrompt/Infrastructure/AI/Providers/HeadlessCLIStreamBridge.swift`.
- OMP model grouping/presentation: `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/OhMyPiModelMenuProjector.swift` is the shared raw-wire projector; `Sources/RepoPrompt/Features/Settings/Views/OhMyPiModelMenuBuilder.swift` is its settings/Oracle adapter.
- OMP destination intent and typed execution metadata: `Sources/RepoPrompt/Infrastructure/AI/Models/OhMyPiThinkingSelections.swift`, destination/tab/preset owners, and `Sources/RepoPrompt/Infrastructure/AI/AIMessage.swift`.
- OMP thinking capability authority: the separate `OhMyPiThinkingCapabilityRegistry.swift`, `OhMyPiThinkingCapabilityResolver.swift`, and shared row-only `OhMyPiThinkingMenuBuilder.swift`; never fold capability state into the dynamic model registry.
- Cursor parameter persistence and catalog authority: `Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorModelParameterStore.swift` and `CursorModelParameterCatalog.swift`.
- Cursor discovery/recovery: `Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorACPModelPollingService.swift`.
- Cursor parameter application and bracket grammar: the Cursor parameterized-model controller and `CursorBracketModelID.swift`.
- MCP projection: `Sources/RepoPrompt/Infrastructure/MCP/Agent/CursorAgentParameterMetadataBuilder.swift` and `AgentManageMCPToolService.swift`.
- Tool schema and remote forwarding: `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift` and `Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift`.

## OMP Oracle contract

- OMP Oracle selections use `AIModel.ohMyPiCustom(name:)` with the frozen `ohmypi_custom_` raw prefix. The suffix is the exact nonempty registry wire ID; preserve case, `/`, `:`, and flattened suffixes.
- The dynamic OMP registry is the model authority. There is no synthesized static fallback model. Thinking capabilities are a separate authority and must never change `AgentACPModelRegistry.currentModelRaw` or discovered-model preference.
- Picker availability requires the effective OMP connection gate (plus the established DEBUG smoke override). A persisted registry alone must not make OMP selectable.
- Warm the standard registry before request-time validation. Distinguish disconnected OMP from a model withdrawn upstream and fail closed; never fall through to OMP's default model.
- Oracle uses a fresh headless OMP provider with RepoPrompt MCP disabled, no workspace, the exact validated canonical model, and the explicit no-tools prompt suffix even when the incoming system prompt is empty.
- MCP-disabled OMP execution applies the already validated canonical model without re-reading the mutable registry. MCP-enabled Agent Mode retains its mandatory pre-prompt route check.
- OMP success requires a terminal `message_stop`. ACP error events, every tool event type, and clean EOF without `message_stop` fail the request; partial text is never converted into success.
- `HeadlessCLIStreamBridge` owns terminal delivery, cancellation ordering, active-provider registration, and exactly-once disposal for both OMP and Cursor.
- Do not infer a prompt-only OMP session mode from advertised mode names. No session-mode field is sent until a verified upstream fixture proves a tool-free mode.
- OMP `cursor/...` IDs remain distinct from direct Cursor selections because auth, billing, session, and tool-policy paths differ. Do not deduplicate them or infer Cursor fast-pricing warnings from OMP suffixes.
- Every OMP model surface uses `OhMyPiModelMenuProjector`: group from exact raw wire IDs by namespace, then form only corroborated effort/fast suffix families. The Default (`nil`) effort counts as a semantic slot when corroborating variants within one speed branch, so sparse `Fast > Default` plus `Fast > Low` catalogs still form one family. The projector preserves a bijection of source and wire IDs, never fabricates a selection, and keeps suffix families independent from the runtime `thinking` selector. Its shared `ModelGroup.Shape` collapses a singleton effort-nil normal branch and/or singleton effort-nil fast branch. Under Position H, a collapsed normal branch renders as adjacent `<family>` and either `<family> Fast` leaf/submenu siblings; when the family container remains, a collapsed fast branch renders as a `Fast` leaf. Wire IDs and leaf ordering do not change.
- Stable OMP menus always use hierarchical exact-wire projection, independent of the OpenCode-only `groupOpenCode` flag. Family grouping is presentational: accessory eligibility is a per-leaf property derived from the exact wire ID. A family leaf whose ID encodes an explicit effort suffix (`none` through `max`) is terminal; an effort-nil family leaf, including a bare base or bare `-fast` ID, receives the same thinking submenu as a standalone valid exact-wire leaf on destinations with the accessory. Its children begin with Default and then project that exact model's capability rows, rebuilding from live state on every open; the capability registry remains authoritative for which values exist. The literal provider-default placeholder remains an action leaf; role-default rows use their own per-role destination, while genuinely model-only destinations remain action leaves. This per-leaf rule is identical across the SwiftUI Agent menu, stable Agent/Context Builder/role menus, and the settings/Oracle/preset builder.
- Thinking intent is destination-owned, not provider-global: each Agent Mode tab/session, Prompt chat/planning/Context Builder destination, model preset, and MCP role default keeps its own capped exact-model map. The local Agent handoff popover is an ephemeral destination initialized from the source session map; its selected map is installed on a newly created OMP destination session after the model selection and before binding/persistence, while non-OMP handoffs receive no OMP assignments. Presets, destinations, roles, or handoffs sharing one wire model may select different thinking values; key absence is Default and sends nothing. Legacy entries remain keyed to their exact wire IDs: entries for effort-encoded family leaves remain stored but are ignored by Oracle/preset/chat and Agent Mode execution, while effort-nil family entries may flow under the same per-leaf rule as their menu accessory. There is no migration between old effort-suffixed IDs and newer collapsed base/fast IDs; execution fails open only when exact-model/catalog classification is unavailable.
- The Agent Models profile, resolved at global or workspace scope, is the authority for Context Builder thinking and per-role OMP thinking. `mcpAgentRoleOhMyPiThinkingSelections` is keyed by `TaskLabelKind.rawValue`, preserves unknown nonempty role keys, omits empty role/outer maps, and is retained by whole-profile inheritance and copy. Model pins, resets, recommendations, and Oracle/Chat synchronization never clear or mirror this role-owned map. Nonempty global or workspace role-thinking intent requires the permanent `mcpAgentRoleOhMyPiThinkingSchemaVersion` v5 compatibility boundary; this is a schema guard rather than a migration, and missing fields still decode as Default.
- With Oracle/Chat model sync enabled, writes mirror the whole model-and-thinking-map pair using the established blank asymmetry: Oracle-side model writes mirror even a blank raw value; Built-in Chat model writes mirror only for a non-blank raw value.
- The Agent Models fix added six explicit post-commit capability-probe sites—three Context Builder surfaces, two role-default surfaces, and the Quick Model Picker HUD commit—in addition to existing picker commits. Automatic sweep triggers attach only to the owning local OMP provider submenu (or the OMP branch `.onAppear` in the SwiftUI handoff surface), never inside `OhMyPiThinkingMenuBuilder`; they do not attach to remote-host menus. Both role-default surfaces attach a stable per-role thinking destination to every accessory-eligible valid exact-wire OMP leaf, even when the role currently resolves to another provider; a thinking child commits its exact model before persisting the role map, while effort-encoded leaves remain terminal.
- `MCPAgentRoleDefaultsService` and its storage boundary are the single scoped role authority. A role/default-role resolution carries only the entry for its effective exact OMP model. Non-OMP roles, unavailable-pin fallbacks, provider-default placeholders, compound model IDs, and injected role-selection providers carry an empty map; the injected provider path cannot authoritatively resolve scoped thinking and deliberately does not consult a second store.
- Fresh role-launched sessions receive the narrowed map explicitly at the existing MCP configure/activation path before run dispatch, only for a nonnil task label, an OMP selection, a nonempty exact-model map, and an empty session map. Existing tabs/sessions, resume-created sessions, compound selections, and already-nonempty sessions never seed. `AgentModeRunService` remains session-map-only and does not read role settings.
- Oracle and preset execution carry thinking through typed `AIMessage.executionMetadata.additionalACPConfigOptionValues` as `.ohMyPiThinking`; the canonical OMP model string remains pure. Central destination/preset resolution attaches only that source's exact-model entry. The shared projector-derived execution eligibility policy follows the same per-leaf rule in Oracle/preset/chat and Agent Mode execution: persisted assignments flow for effort-nil exact wire IDs and are suppressed for IDs that encode an explicit effort. An OMP assignment presented to another provider is rejected at the provider boundary; no provider parses thinking from model suffixes.
- `OhMyPiThinkingCapabilityRegistry` is the capability authority. It records only valid sequence-authoritative OMP `thinking`/`thought_level` snapshots per exact model, persists ordered options with OMP version and observation time in `omp-thinking-capabilities-v1.json`, never persists session `currentValue`, invalidates on binary-version change, and notifies future menu snapshots. Real sessions and the existing settings refresh bootstrap publish through the same controller hook with no additional ACP round trip.
- Lazy capability discovery is cache-first and starts after an explicit OMP model-selection action, the shared manual Load action, or the local OMP provider submenu actually opening—never during construction, render, restore, checkmark evaluation, catalog refresh, root-menu open, launch, or connection. One global sweep session consumes a bounded priority queue: at most 24 background targets per pass, 30 seconds for startup, 8 seconds per model switch, and a 45-second post-bootstrap work budget; the remainder is deferred until the next submenu open. Busy requests are enqueued or promoted, never skipped. Selection never waits; manual retry may bypass cooldown. Visible loading ends at its deadline independently of cancellation-shielded cleanup, and provider disposal remains exactly once.
- Thinking menus are projections of destination intent plus the capability registry: Default is always present; authoritative options retain upstream order and exact raw values; duplicate labels are disambiguated; loading and queued rows are disabled; queued rows also expose Load now for promotion; unsupported rows are informational and expose no Load; unknown/failure states retain stored intent and expose Load; an authoritative stale choice on an accessory-eligible menu leaf remains stored and renders a one-click clear warning. A sweep-status header reports preflight, progress, deferral, failure, completion, or cancellation. Lazy stable OMP provider submenus rebuild from current catalog/registry/status state only in `menuNeedsUpdate` before display and never mutate while tracked; `menuWillOpen` alone starts the automatic sweep. The shared row builder never triggers a sweep. It returns rows under standalone leaves and effort-nil family leaves on thinking-enabled destinations; effort-encoded family leaves remain terminal actions. Choosing Default, a capability value, or the stale-value clear action commits that leaf's exact model first and applies thinking only when the commit succeeds, completing both operations in one menu traversal. Load requests capability discovery without selecting or committing the model.

## Cursor parameter-catalog contract

- `CursorModelParameterCatalog` is the sole parameter authority. MCP and UI layers transform its `ParameterSpec` values; they do not parse Cursor extension responses.
- `CursorModelParameterStore` uses its dedicated versioned `CursorModelParameterCatalogV1` UserDefaults envelope. It is independent of `ACPDynamicModelProviders`.
- Catalog parsing is atomic for the whole response. A malformed model, duplicate normalized base, or invalid/duplicate select specification rejects the response and retains the last-good in-memory and persisted catalog.
- Missing `configOptions` is a valid zero-axis model. Unknown non-select option types are skipped.
- Clear memory and persistence only for authoritative method-not-found or a structurally valid zero-model response. Corrupt and future-version persisted envelopes are ignored but preserved for later recovery.
- Hydration is synchronous at launch with lazy hydration as a backstop. An empty catalog is never persisted as a normal last-good snapshot.
- Catalog-data and status notifications remain separate. Status-only churn must not invalidate parameter menus.
- Status distinguishes cached/live/refreshing/stale failure kinds/unsupported/disabled and records usable-catalog and refresh timestamps.
- Cursor polling classifies failures, sanitizes and transition-rate-limits logs, retains last-good models and parameters on transient failure, and retries with bounded backoff from approximately 15 to 300 seconds. Cancellation and shutdown do not record spurious failures.
- A successful bare-model discovery remains publishable when the parameter extension fails.
- `CursorParameterizedModels.isEnabled` is the shared product gate for parameterized Cursor presentation and MCP metadata.

## `list_agents` Cursor parameterization contract

Eligible bare Cursor start targets with a nonempty catalog entry receive one additive `parameterization` object. Existing model/start-target count, order, IDs, default selection, and non-Cursor serialization remain unchanged. Never Cartesian-expand parameter options into additional targets, and never attach this metadata to OMP.

The compact object contains:

- `syntax: "cursor-bracket-v1"`
- `target_template`: the exact serialized bare compound `model_id` followed by brackets, with every captured catalog parameter ID mapped in catalog order to the literal `<value>`, for example `cursor:gpt-5.6-sol[context=<value>,reasoning=<value>,fast=<value>]`; the completed template must parse through `CursorBracketModelID`
- `include_model_parameters_flag: "include_model_parameters"`
- optional `reasoning_effort_parameter_id`, only when the same captured parameter snapshot contains exactly one `thought_level` parameter

When the caller passes the strictly parsed boolean `include_model_parameters: true`, the object also contains `parameters`. Each parameter preserves:

- `id`
- `category`
- `default_value`
- `options[]` with exact `value` and `name`
- optional `description`

The tool schema declares `include_model_parameters` as a boolean with default `false`. The gateway forwards it through the strict `list_agents` allowlist.

Omit `parameterization` entirely when any of these is true:

- the target is not direct Cursor;
- the catalog entry is absent or empty;
- the target is already bracketed;
- `CursorParameterizedModels.isEnabled` is false.

The enablement predicate and catalog are injectable in `CursorAgentParameterMetadataBuilder`, so tests must not mutate shared UserDefaults or the shared catalog.

## Payload rationale

The captured `Tests/RepoPromptTests/AgentMode/Fixtures/CursorACP/list_available_models.json` fixture contains 33 models, 26 with parameter axes. Compact sorted JSON measured 10,943 bytes; always including full axes measured 24,497 bytes, an increase of 13,554 bytes. This exceeds the approximately 5 KB falsifier, so compact metadata remains always-on for eligible targets while full axes remain opt-in.

## Focused validation

Use the smallest coordinated suite covering the changed seam:

```bash
make dev-test FILTER=OhMyPiModelCatalogTests
make dev-test FILTER=OhMyPiCLIProviderTests
make dev-test FILTER=OhMyPiACPHeadlessAgentProviderTests
make dev-test FILTER=HeadlessCLIStreamBridgeTests

make dev-test FILTER=MCPAgentRoleDefaultsServiceTests
make dev-test FILTER=OhMyPiThinkingMenuBuilderTests
make dev-test FILTER=AgentModeRunServiceLifecycleTests/testFreshRoleOMPThinkingSeedsOnceAndFeedsRunServiceAssignments
make dev-test FILTER=AgentRunMCPToolServiceStartDefaultTests
make dev-test FILTER=SettingsJSONOnlyPersistenceTests/testAgentRoleThinkingUsesFixedFeatureSchemaV5AndGlobalDefaultsJSONRoundTrip
make dev-test FILTER=SettingsJSONOnlyPersistenceTests/testAgentModelsRoleThinkingRoundTripsAcrossScopesCopiesAndUnrelatedMutations
make dev-test FILTER=ACPAgentSessionControllerModeConfigTests

make dev-test FILTER=CursorModelParameterStoreTests
make dev-test FILTER=CursorModelParameterCatalogTests
make dev-test FILTER=CursorACPModelPollingServiceTests
make dev-test FILTER=CursorModelParameterCatalogStatusPresentationTests
make dev-test FILTER=CursorParameterizedModelControllerTests

make dev-test FILTER=AgentManageListAgentsCursorParameterMetadataTests
make dev-test FILTER=AgentManageMCPToolServiceListAgentsTests
make dev-test FILTER=RemoteCommandTranslatorTests
make dev-test FILTER=ToolCatalogSnapshotTests

make dev-lint
make dev-format-check
```

Run `make dev-build` when app integration or packaging changed. A filtered suite is not full-root contribution evidence; use unfiltered `make dev-test-parallel` when full-root evidence is required.
