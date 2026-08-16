# Oracle remote models and Cursor parameter catalog

Scope: read when the task touches Oracle remote-client models for Cursor or Oh My Pi (OMP), Cursor parameter-catalog persistence/polling/status, OMP Oracle model discovery or execution, or Cursor parameter metadata in `agent_manage list_agents`.
Authority: Authoritative
Last-verified: 2026-08-16

## Ownership

The implementation is split deliberately; do not introduce a parallel model or parameter authority.

- Oracle model identity and provider routing: `Sources/RepoPrompt/Infrastructure/AI/AIModel.swift` and `Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift`.
- Dynamic ACP model authority: `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentACPModelRegistry.swift` and `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/ACPAIModelCatalog.swift`.
- OMP Oracle execution: `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiCLIProvider.swift` and the OMP ACP headless provider.
- Shared one-shot lifecycle: `Sources/RepoPrompt/Infrastructure/AI/Providers/HeadlessCLIStreamBridge.swift`.
- OMP grouping/presentation: `Sources/RepoPrompt/Features/Settings/Views/OhMyPiModelMenuBuilder.swift`.
- Cursor parameter persistence and catalog authority: `Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorModelParameterStore.swift` and `CursorModelParameterCatalog.swift`.
- Cursor discovery/recovery: `Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorACPModelPollingService.swift`.
- Cursor parameter application and bracket grammar: the Cursor parameterized-model controller and `CursorBracketModelID.swift`.
- MCP projection: `Sources/RepoPrompt/Infrastructure/MCP/Agent/CursorAgentParameterMetadataBuilder.swift` and `AgentManageMCPToolService.swift`.
- Tool schema and remote forwarding: `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift` and `Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift`.

## OMP Oracle contract

- OMP Oracle selections use `AIModel.ohMyPiCustom(name:)` with the frozen `ohmypi_custom_` raw prefix. The suffix is the exact nonempty registry wire ID; preserve case, `/`, `:`, and flattened suffixes.
- The dynamic OMP registry is the model authority. There is no synthesized static fallback model.
- Picker availability requires the effective OMP connection gate (plus the established DEBUG smoke override). A persisted registry alone must not make OMP selectable.
- Warm the standard registry before request-time validation. Distinguish disconnected OMP from a model withdrawn upstream and fail closed; never fall through to OMP's default model.
- Oracle uses a fresh headless OMP provider with RepoPrompt MCP disabled, no workspace, the exact validated canonical model, and the explicit no-tools prompt suffix even when the incoming system prompt is empty.
- MCP-disabled OMP execution applies the already validated canonical model without re-reading the mutable registry. MCP-enabled Agent Mode retains its mandatory pre-prompt route check.
- OMP success requires a terminal `message_stop`. ACP error events, every tool event type, and clean EOF without `message_stop` fail the request; partial text is never converted into success.
- `HeadlessCLIStreamBridge` owns terminal delivery, cancellation ordering, active-provider registration, and exactly-once disposal for both OMP and Cursor.
- Do not infer a prompt-only OMP session mode from advertised mode names. No session-mode field is sent until a verified upstream fixture proves a tool-free mode.
- OMP `cursor/...` IDs remain distinct from direct Cursor selections because auth, billing, session, and tool-policy paths differ. Do not deduplicate them or infer Cursor fast-pricing warnings from OMP suffixes.
- OMP menus group by the namespace before the first `/`; persisted selection always retains the full wire ID.

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
