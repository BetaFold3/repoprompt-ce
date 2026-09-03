# Claude model-family catalog

Scope: read when the task touches Claude Fable 5.1 static support, Claude Code dynamic point releases, the Anthropic models registry, Claude family grammar, or Anthropic family-based request shaping.
Authority: Authoritative
Last-verified: 2026-09-03

## Authority and ownership

Keep these authorities separate:

- `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/ClaudeModelFamilyCatalog.swift` is the core, keyless authority for supported family/major anchors, point-release grammar, family effort metadata, CLI context windows, and API request-shape traits.
- `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/AnthropicAPIModelsClient.swift` fetches and validates official `GET /v1/models` descriptors.
- `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/AnthropicDiscoveredModelStore.swift` is the persisted descriptor authority.
- `Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/ClaudeCodeAIModelCatalog.swift` combines the static Claude Code catalog with registry-corroborated point releases for Oracle/picker presentation while retaining grammar-based validation.
- `Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatibleModelCatalogAdapter.swift` overlays those dynamic entries only for standard `.claudeCode`.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Anthropic/AnthropicModelFamilyTraits.swift` applies exact-ID overrides before family traits; `AnthropicModelConfiguration.swift` and `AnthropicRequestPlan.swift` turn those traits into native API requests.

The in-repo `RepoPromptClaudeCompatibleProvider` package remains the static Claude-compatible catalog and runtime seam. Dynamic registry, grammar, persistence, and request shaping are app-core concerns. The overlay never extends GLM, Kimi, or custom Claude-compatible backend catalogs.

## Strict family grammar

The curated anchors are `claude-fable-5`, `claude-opus-5`, and `claude-sonnet-5`. An anchor identifies a family; a dynamic point release must match:

```text
claude-<family>-<major>-<minor>[-<YYYYMMDD>]
```

The match is exact and case-sensitive. `minor` contains ASCII digits only and is required; the optional date is exactly eight ASCII digits. The parser therefore accepts same-major IDs such as `claude-fable-5-2` and `claude-opus-5-12-20260902`, but rejects new majors, family-prefix lookalikes, empty segments, nonnumeric components, and suffixes such as `preview`, `beta`, or `thinking`. A single trailing date-like numeric component is a numeric minor, not a date suffix. New majors require a new curated family row.

Grammar controls validation and traits; it does not manufacture picker entries. Numeric minor, then date, then stable raw-string ordering places newer point releases before their family anchor.

## Registry semantics and trust boundary

The models client paginates the official Anthropic endpoint, tolerantly decodes optional `display_name`, `max_input_tokens`, `max_tokens`, and lossless `capabilities`, then validates the complete result atomically. Capabilities are persisted but are not a request-shaping authority.

The store synchronously hydrates a version-1 UserDefaults envelope, atomically replaces the complete canonical model array, and increments a monotone revision only when model data changes. Invalid responses, transient fetch failures, corrupt persisted bytes, and future envelope versions do not replace the last-good catalog; corrupt/future bytes are left intact. A structurally valid empty response is authoritative and clears the catalog. Removing an API key does not clear it.

Only registry IDs that also pass the strict family grammar enter dynamic Claude Code picker/discovery options. Wire IDs remain exact. Registry display names are trimmed and accepted only when nonempty, control-free, at most 80 characters, and at most 320 UTF-8 bytes; otherwise the family-generated name is used. Registry token limits may enrich capability metadata, but registry capabilities do not select request traits.

When an authoritative refresh withdraws a model, it disappears from new picker choices. Stored raw selections remain unchanged and grammar-valid IDs remain validation-compatible; an unavailable runtime ID must fail loudly at the provider rather than being substituted.

## Request-shaping traits and exact overrides

Exact full-model-ID overrides in `AnthropicModelFamilyTraits` win before family grammar. The override table is intentionally empty until a live contract divergence is verified.

The request-shaping table below is API-only. CLI supported efforts and XHigh eligibility are carried separately by each `ClaudeModelFamilyCatalog.Family` row; Sonnet 5 therefore remains CLI XHigh-capable while its native Anthropic API request shape stays legacy.

Current API family traits are:

| Family | Native Anthropic request shape | Static API metadata |
| --- | --- | --- |
| Fable 5 | adaptive thinking; requested effort or `.high`; sampling suppressed; `output_config.effort`; implicit `max_tokens` 16,000 | 1,000,000 input; 128,000 output |
| Opus 5 | adaptive thinking; requested effort or `.high`; sampling suppressed; `output_config.effort` | no family fallback token limits |
| Sonnet 5 | legacy | no family fallback token limits |

Legacy models retain suffix-driven `-thinking` / `-thinking-max` behavior and reject an explicit adaptive effort. Known output ceilings reject an explicitly requested `max_tokens` above the limit. Registry token metadata is preferred over family fallback metadata where available.

## CLI and app effort defaults

RepoPrompt owns its app default independently of the Claude Code CLI's internal default behavior. `ClaudeAgentToolPreferences` defaults to `.high`, prefers high, then medium, then the first available supported choice, and launches Claude Code with `CLAUDE_CODE_EFFORT_LEVEL`. The native Anthropic adaptive path likewise uses `.high` when no effort is requested. Do not change the app default to mirror a CLI-side xhigh default; direct CLI behavior and RepoPrompt-launched behavior are deliberately distinct.

## Drift playbook

If a future grammar-valid release rejects inherited request fields or otherwise changes its API contract:

1. Preserve the exact provider error, including the exact model ID. Do not silently retry, downgrade request shape, substitute a model, or lower effort.
2. Reproduce with a focused live probe and capture the exact request/response contract.
3. Add the narrowest exact-ID trait override; exact overrides already precede family rules.
4. Add focused request-plan/encoding coverage and update this document if the durable contract changed.
5. Generalize the family row only after evidence shows the change applies to the whole family/major.

## New family or new major checklist

1. Live-probe the native Anthropic contract before selecting adaptive shaping or static API token limits.
2. Add one `ClaudeModelFamilyCatalog.Family` row for the exact family/major, including efforts, xhigh eligibility, separate CLI/API token metadata, default max tokens, and request shape.
3. Add grammar acceptance/rejection, ordering, trait, request-plan, capability, withdrawal, and compatible-backend exclusion coverage.
4. If promoting a static Claude Code model, update all static authorities together: provider-package catalog, `AgentModel`, `ClaudeCodeAIModelCatalog`, and adapter xhigh membership; then run `make dev-test FILTER=ClaudeStaticCatalogConsistencyTests`.
5. Keep dynamic models untagged until separately promoted for recommendations.
6. Verify official registry corroboration controls listing while grammar continues to control keyless validation.

## Rollback compatibility

Raw model IDs and effort-qualified selections are persisted without migration, but the two forms have different rollback behavior. An older binary cannot decode a persisted `AgentModel.claudeFable51` selection because that enum case did not exist. Dynamic point-release raw strings are more forward-tolerant where the older binary preserves unknown/custom strings, but they may still be absent from pickers or rejected by older validation. Do not rewrite either form to a nearby alias, silently substitute another model, or clear the registry as a rollback workaround; require explicit reselection or restore a build that understands the ID.

## Validation map

Use the smallest coordinated suites for the changed boundary:

| Boundary | Focused coverage |
| --- | --- |
| Family rows, grammar, ordering, traits | `ClaudeModelFamilyCatalogTests` |
| Models API decoding, pagination, atomic validation | `AnthropicAPIModelsClientTests` |
| Persistence, replacement, revision, last-good retention | `AnthropicDiscoveredModelStoreTests` |
| Native request shape and capability metadata | `AnthropicRequestPlanTests` |
| Registry-backed Oracle/picker ordering and withdrawal validation | `ModelPickerStringOrderingTests` |
| Agent Mode overlay and compatible-backend exclusion | `ClaudeCompatiblePluginBridgeTests` |
| Static catalog consistency across authorities | `ClaudeStaticCatalogConsistencyTests` |
| Static package catalog behavior | `ClaudeCompatibleRuntimeSupportTests` and `ClaudeCompatiblePluginBridgeTests` |

Use `make dev-provider-test FILTER=ClaudeCompatibleRuntimeSupportTests` for package coverage and `make dev-test FILTER=<SuiteName>` for root suites. Live API and CE debug-app probes remain separate paid/manual gates; they are not implied by these tests.
