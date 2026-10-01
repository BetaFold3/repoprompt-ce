# Completion outcome — 2026-10-01

Status: Complete. Implementation and deterministic validation passed. OracleA initially approved with minor follow-ups; OracleB requested a controller-delivery regression (P1). After test-only remediation, fresh independent OracleA and OracleB re-reviews both approved and explicitly closed the P1 and the setup-synchronization and in-flight-turn coverage findings. Remaining minor test-hardening and consolidation suggestions are follow-ups, not blockers.

Implemented the status-field-only translator release, exact-label native Claude transport-status clear, and resolved tokens-only compaction continuity. Money remains qualified only for the existing 2.1.268 contract; 2.1.281 stays tokens-only. No controller, accumulator, persistence or live-app lifecycle change was made.

Validation: 34 provider tests (27 translator), 66 core tests, 95 focused root tests, lint, format check, the packageable debug build, 6,220-method exact-ID ledger verification, and 23 context-checker tests passed. Status-suite setup is isolated through an injected store's existing DEBUG setup hook with explicit cancel/release/await teardown, without weakening assertions. Review remediation adds real-controller release/FIFO coverage and in-flight-turn token continuity. Nineteen new ledger rows and one contract-row amendment preserve the recorded behavior change. Full-root tests, paid probes and successful auto-compaction capture were not run.

Durable contracts and detailed validation are in [the owning usage-accounting document](../2026-09-13-agent-usage-and-wait-efficiency-plan.md#2121-claude-compaction-status-and-tokens-only-continuity-amendment-2026-10-01). Provider tests use `make dev-provider-test`; the original plan's core-test command alone does not cover that package. The original plan below is preserved intact, including its historical status and relative links.

---

# Claude compaction status release and tokens-only accounting continuity plan

Scope: read when the task touches the native Claude "Compacting context" running status, Claude `system/status` or `compact_boundary` translation, or whether a tokens-only Claude execution survives a compaction counter boundary.
Authority: Reference
Last-verified: 2026-10-01

Status: Planned, not implemented. No source, test, or ledger change has been made for this plan.
Decision process: OracleE and OracleD received an identical initial brief with verified evidence, then up to two anonymous reciprocal challenge rounds. Every material disagreement converged by round 2 (§9). The OracleE lane failed three times on chat continuation (`oracle_failed`, with one earlier 401 before credentials were fixed). Its round-1 and round-2 challenges were therefore sent as fresh OracleE chats, each restating in substance that lane's own prior position alongside the other lane's arguments. Lane identity was never relayed.
Owning contract document: [agent usage accounting plan](2026-09-13-agent-usage-and-wait-efficiency-plan.md) §2.12 and the §2.10 "Execution verdicts" row. This plan amends that contract (§5); it does not replace it.

## 1. Outcome and scope

Two user-visible defects affect the native Claude Code Agent Mode runtime and the Claude-compatible runtimes that share its translator (`usesClaudeNativeRuntime`: `.claudeCode`, `.claudeCodeGLM`, `.kimiCode`, `.customClaudeCompatible`, see `AgentRuntimeProviderService.swift:124-131`).

1. **Stale status.** After an auto-compaction mid-turn, the running status stays "Compacting context" through later text, edits, and tool calls. It is only replaced when a progress event arrives (for example Ask_Oracle or Bash `tool_progress`) or the turn ends.
2. **Accounting goes dark.** On any Claude Code version other than 2.1.268 (the user runs 2.1.281), the first compaction terminally blocks the execution. The segment is suspended, the latest-request cache-hit (CH) share is nulled, and every later result for that process is rejected. No cost is lost, because tokens-only versions never record cost. What disappears is CH and token tracking.

In scope: a narrow status release, and letting resolved tokens-only executions continue observing tokens across compaction.
Out of scope: qualifying 2.1.281 (or any version) for money, enabling partial messages or reasoning extraction, and changing controller detection, accumulator mechanics, or persistence.

## 2. Verified starting points (2026-10-01, HEAD `2dea737f`)

Status path:
- The package translator `parseSystemMessage` maps `status: "compacting"` to `status` "Compacting context". It returns `[]` for an empty or `"null"` status (`Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift:133-145`). `compact_boundary` emits only a `system` row (`:165-177`). The app translator under `Sources/.../ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift:43-66` is a thin facade over this package translator.
- In the view model's `status` case, a non-empty status becomes a `.transport` status. An empty status clears only if the raw text contains "Permission mode:" (`AgentModeViewModel.swift:17909-17921`). No production code produces that text any more: the only occurrences are `claudeDisplayableStatusText` (`:17566-17579`, whose only caller is `:17912`) and that branch. The branch is dead code.
- `content` clears only reasoning-sourced status (`:17722-17726`, `AgentModeViewModel+TabSession.swift:1678-1685`). `tool_call` and `tool_result` leave status alone (`:17785-17902`). `tool_progress` overwrites it (`:17904-17907`). `message_stop` clears it (`:17999-18001`), but it comes only from the `result` payload, because `buildArguments` has no `--include-partial-messages` (`ClaudeNativeProcessSessionController.swift:3189-3198`, `:2037`). Reasoning extraction is disabled (`Sources/.../ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift:3-4`).
- `ClaudeContextUsageEstimator.ingestStatusSignal` is nil-safe and already matches the literal "compacting context" (`ClaudeContextUsageEstimator.swift:160-166`). The canonical label is therefore already a cross-component contract.
- Other `status` consumers tolerate nil text. Context Builder drops empty statuses (`ContextBuilderAgentViewModel.swift:3937-3942`, `:3991-3995`), and `HeadlessCLIStreamBridge` has no `status` case.
- The only captured compaction wire evidence is `Tests/RepoPromptTests/AgentMode/Fixtures/ClaudeNativeUsage/2.1.268-compact.jsonl`, a failed manual `/compact`. It contains `{subtype:status, status:"compacting"}`, then `{subtype:status, status:null, compact_result:"<redacted>", compact_error:"Not enough messages to compact."}`. Neither payload has a `permissionMode` key, and there is no `compact_boundary`. **No successful auto-compaction sequence has been captured.**

Accounting path:
- The only active contract is `supported2_1_268` (monetary, `compactionQualified: true`). Any other version gets `claude-native.tokens-only.v1@<version>` with an `.unsupported` baseline. `Policy.tokensOnly` has `compactionQualified: false` and is also the fallback for nil or unknown IDs (`ClaudeNativeUsageContract.swift:63-91`, `:113-120`, `:147-150`, `:181-191`).
- The controller reports compaction as `.counterBoundaryObserved` (`ClaudeNativeProcessSessionController.swift:1948-1956`, `:2987-2994`, `:3031-3038`). `TabSession` then calls `counterBoundaryBlock` and resolves `.blocked` (`AgentModeViewModel+TabSession.swift:908-918`). The accumulator suspends the segment, preserves accepted amounts, nulls the latest CH, and rejects later input (`AgentUsageAccumulator.swift:484-489`, `:529-538`, `:553-557`).
- The saved session "P2 follow-up: close-handshake P1 fixes + re-review until approved" confirms this: contract `claude-native.tokens-only.v1@2.1.281`, segment `suspended`, coverage `unavailable`, `acceptedResultOrder 0`, `hasUnmeasuredHistory true`, and two auto-compactions (~327,303 and ~323,375 tokens).

## 3. Design

### 3.1 Package translator: status-field-only release

File: `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift`, `parseSystemMessage`.

For `subtype == "status"`, emit **exactly one** `ClaudeProviderStreamResult(type: "status", ...)`:

| Raw `status` value | Emitted text |
|---|---|
| String trimming to `compacting` (case-insensitive) | `"Compacting context"` (unchanged) |
| Any other non-empty trimmed string except the existing literal `"null"` sentinel | The trimmed string (unchanged) |
| Missing key, JSON null, empty or whitespace-only string, or literal `"null"` after trimming | `nil` (a release) |
| Non-string value (number, Boolean, array, object) | `nil` (a release); never stringify it |

The compaction marker fields `compact_result`, `compact_error`, and `compact_metadata` do **not** affect this output. They remain accounting evidence read only by the controller's `usageCompactionStatusBoundary(in:)`, which stays unchanged and must not be reused as a UI predicate. There are no coexistence or precedence rules.

For `subtype == "compact_boundary"`, emit `[status(nil), system("Context compacted — …")]`: a release, then the existing row, unchanged.

A release is only a status update. It is never a `message_stop`, a turn boundary, a usage observation, or accounting evidence. No new result type, field, translator state, timer, or package dependency is added.

### 3.2 View model: clear only the compaction-owned label

File: `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`, `handleStreamResult` case `"status"`.

- Add a private canonical constant, `"Compacting context"`. Producer/consumer tests pin it to the translator output (§4).
- Keep the `ingestStatusSignal(result.text, ...)` call first and unchanged. It is nil-safe, so the order is behavior-neutral.
- Reduce `claudeDisplayableStatusText` to trimming plus empty-to-nil normalization, removing the dead "Permission mode:" stripping.
- If the displayable text is non-empty, keep the existing `setTransportRunningStatus` behavior, so reasoning precedence is unchanged.
- Otherwise, replace the dead "Permission mode:" else-if with a single narrow release. Clear via `session.setRunningStatus(nil, source: nil)` only when **all** of these hold:
  - `session.selectedAgent.usesClaudeNativeRuntime`
  - `session.runningStatusSource == .transport`
  - `session.runningStatusText == <canonical constant>` (exact `==`, with no substring matching)

  OR its return value into `shouldUpdateBindings`. Do not store "Thinking…", override reasoning, or cancel reasoning buffers.
- Do not add clearing to `content`, `final_content`, `tool_call`, or `tool_result`. Add no `TabSession` state or timers, and no new `RunningStatusSource` case. Existing run and run-attempt guards are unchanged.

Resulting precedence (assuming "Compacting context" is currently shown, unless stated otherwise):

| Situation | Result |
|---|---|
| Release while "Compacting context" (`.transport`) is shown | Cleared (text and source become nil) |
| Release while another transport label is shown (`tool_progress`, `task_progress`, "Thinking…", auth) | Unchanged |
| Release while a reasoning label is shown | Unchanged, and reasoning state is untouched |
| Release with nothing shown, or a duplicate release | No-op, with no binding update |
| A real status or progress event arrived after compaction began | The newer label is kept when the release arrives |
| Non-native agents | Unchanged |

Accepted presentation tradeoff: on uncaptured shapes (a `system/status` with no readable status), the label may be withdrawn before compaction actually finishes. A release means "withdraw this label", not "compaction finished". The run stays active and nothing else is affected.

### 3.3 Accounting: tokens-only executions survive a compaction boundary

File: `Sources/RepoPrompt/Features/AgentMode/Runtime/Usage/Claude/ClaudeNativeUsageContract.swift`, `counterBoundaryBlock(contractID:kind:)`.

Decision order:

| Contract ID | Decision |
|---|---|
| nil | Block (unchanged) |
| Registered contract (`contract(withID:)` resolves) | Use its `compactionQualified` (2.1.268: allow; registered but not compaction-qualified: block) |
| Exact `tokensOnlyContractPrefix` plus a non-whitespace version suffix | **Allow** (new) |
| Bare prefix, empty suffix, or any other unknown ID | Block |

Resolve registered contracts first, so a contract's own policy cannot be bypassed by its name. **Do not** set `Policy.tokensOnly.compactionQualified = true`: that policy is also the nil/unknown fallback, and flipping it would silently relax those cases. Keep `activeContracts == [supported2_1_268]`, the `v1` ID format, the `.unsupported` baseline, queue policy, and backend checks. Update the doc comments on the type header, `Qualified.compactionQualified`, `Policy.tokensOnly`, and `counterBoundaryBlock` so they separate token permission from monetary qualification.

An allowed boundary is purely observational, so the accumulator does not change:

| State | Across an allowed tokens-only boundary |
|---|---|
| Execution, launch token, verdict | Preserved: `.qualified(tokens-only, .unsupported)` |
| Segment | Stays open; coverage stays `.unavailable`; never suspended or reopened |
| Latest-request CH | Not nulled; it updates on the next eligible attributed main request |
| Session token totals and CH inputs | Preserved; later accepted results add exactly once |
| Dispatch ordinals, expected `result_index`, `acceptedResultOrder`, dedup identities | Preserved; a boundary is not a result |
| Cumulative-cost baseline and checkpoints | Still unsupported; `reportedCost` is still rejected as `monetaryScopeUnsupported` |
| `hasUnmeasuredHistory` | Not set by this path; existing flags are preserved |
| Owned revision and save | No revision or save is caused by an allowed boundary alone |

Every existing fail-closed rule still applies to later results: ownership, session and version equality, contiguity (a runtime that resets `result_index` at compaction still blocks), exact-duplicate handling, queue bound, and child-activity CH exclusion. Already-blocked executions are never revived. Persisted suspended history is not migrated or repaired; recovery happens only through a new launch.

Edge cases: a `compact_error` boundary is a no-op for tokens-only executions and for 2.1.268. Manual `/compact` keeps its normal result path (zero-token results are tolerated, and 2.1.268 cumulative cost may still rise). A resumed unknown-version launch stays tokens-only with an `.unsupported` baseline and survives the boundary. 2.1.268 fresh and resumed behavior is unchanged.

## 4. Tests and ledger

Provider package, `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests/SDK/ClaudeSDKNDJSONTranslatorTests.swift` (currently has no `status` or `compact_boundary` coverage, so nothing needs adjusting):
- A table test for every row in §3.1: compacting, ordinary, null, `""`, whitespace, `"null"`, missing key, and non-string values.
- Marker independence: the fixture's terminal payload yields exactly one `status(nil)`, `status:"compacting"` with `compact_metadata` yields the label, and markers never add results.
- `compact_boundary` yields `[status(nil), system row]` in that order, with the row text unchanged.
- The captured `2.1.268-compact.jsonl` status lines replayed in order yield `status "Compacting context"`, then `status(nil)`.
- No release payload produces `message_stop`, `usage`, or a usage observation.

App, view-model status handling (a new focused suite such as `ClaudeCompactionRunningStatusTests` under `Tests/RepoPromptTests/AgentMode/`, driving the existing DEBUG `test_handleStreamResult(_:session:runID:runAttemptID:)` seam the way `AgentModeMCPWaitEpochTests.swift:592` does; no new seam):
- Compacting, then release, clears both text and source.
- Boundary-style release clears; a duplicate release is a no-op.
- A `tool_progress` label followed by a release is unchanged; a reasoning label followed by a release is unchanged, including pending reasoning state.
- A release with nothing shown causes no binding update; a stale run ID or attempt is rejected.
- The canonical constant equals the translator's output (pin test).
- A GLM, Kimi, or custom compatible agent behaves the same; a non-native agent is unaffected.

`ClaudeNativeUsageContractTests.swift`: **deliberately flip `:163-166`**, where a tokens-only ID (`2.1.999`) now returns nil for `compact_boundary`. This is a recorded contract change, not a weakening. Add the `status:compacting` and `status:compact_error` kinds, keep nil → block (`:167-170`), keep the registered `strict` → block and `relaxed` → allow (`:172-185`), and add the bare prefix and empty suffix → block. Verify that fresh and resumed 2.1.281 verdicts stay tokens-only with `.unsupported`.

`AgentUsageRuntimeIntegrationTests.swift`: existing compaction-block cases (`:267-297`, `:843-866`) use a **registered** synthetic contract that is not compaction-qualified, so they stay unchanged and keep proving that blocked semantics hold. Add a saved-session-shaped regression: launch with `2.1.281`, dispatch, result, two boundaries (`status:compacting`, `compact_boundary`), dispatch, result, and turn close. Assert the verdict stays qualified tokens-only, the segment stays open and `.unavailable`, both results are accepted in order, CH reflects both triples, no cost is checkpointed (use nonzero reported costs), `hasUnmeasuredHistory == false`, latest CH is not "Unavailable", no revision is caused by the boundary alone, and save/reload round-trips. Add a hydrated suspended-history → new launch → tokens observed case that preserves old flags.

`AgentUsageAccountingTests.swift` (`:686` passes a blocked verdict directly, so it is unaffected) and `ClaudeNativeUsageAttributionTests.swift`: no semantic change expected. Run them as regressions. Optionally add a controller-path check that the fixture still emits the same boundary events and now two `status` stream results, without consuming the completion FIFO.

`ClaudeCompatiblePluginBridgeTests`: add a regression that nil-text `status` survives the package-to-app conversion.

Ledger: every added or renamed method needs a surgical row in `Scripts/Fixtures/test-suite-contract-ledger.tsv` per [testing](../../testing.md) "Maintain the contract ledger surgically". Never regenerate the ledger.

## 5. Documentation updates (land with the code)

In [agent usage accounting plan](2026-09-13-agent-usage-and-wait-efficiency-plan.md):
- §2.10 "Execution verdicts" row: change "a same-process compaction boundary … blocks terminally" so it applies to awaiting executions, nil or unknown IDs, and registered contracts without `compactionQualified`. Resolved tokens-only executions continue token observation.
- §2.12 Claude paragraph: amend the tokens-only sentence the same way.
- Add a dated subsection recording this amendment, its rationale, the test deltas, actual validation counts, and that 2.1.281 money remains unqualified.
- Leave historical §2.11 and the INCONCLUSIVE capture rows intact.

Then mark this plan's status and, once it is complete, move it to `docs/context/plans/completed/` per AGENTS.md. Run `Scripts/check-agent-context`.

## 6. Implementation order and validation

1. Translator change and translator tests, run with `make dev-core-test`. Confirm it actually runs `RepoPromptClaudeCompatibleProviderTests`; a run that matches zero suites is not validation. This change is safe to land alone, because the view model ignores empty statuses until step 2.
2. View-model change and the status suite, plus the bridge regression: `make dev-test FILTER=ClaudeCompactionRunningStatusTests` and `FILTER=ClaudeCompatiblePluginBridgeTests`.
3. **Atomically:** the `counterBoundaryBlock` change, its doc comments, the contract-test flip and additions, the runtime-integration additions, and the §5 doc amendment. Run `make dev-test FILTER=ClaudeNativeUsageContractTests`, `FILTER=AgentUsageRuntimeIntegrationTests`, `FILTER=AgentUsageAccountingTests`, and `FILTER=ClaudeNativeUsageAttributionTests`.
4. Ledger rows, then `make guardrails` and `Scripts/check-agent-context`.
5. `make dev-lint`, `make dev-format-check`, and an app build via `make dev-build`.

No live app launch or paid provider probe is required or authorized. All validation is deterministic.

## 7. Explicitly unchanged

The app translator facade; `ClaudeNativeProcessSessionController` (detection, raw logging, dispatch ownership, lifecycle, launch arguments); `AgentModeViewModel+TabSession.swift`; `AgentUsageAccumulator.swift`; persistence schema and contract-ID format; `activeContracts`; `Policy.tokensOnly` values; `queuePolicyBlock`; the production reasoning feature flag; and the estimator's own "compacting context" match.

## 8. Risks

- **Canonical-string coupling.** The view model clears only on an exact label. If the translator wording changes without updating the constant, the stale label returns. Pin tests guard this; a typed status identity would be the broader fix if one is ever wanted.
- **Early withdrawal on uncaptured shapes** (§3.2 tradeoff). This is presentation-only and bounded by the exact-match clear.
- **No captured successful auto-compaction.** Success-path behavior relies on `status:null` and/or `compact_boundary`, which the debugging session reported seeing in the live raw events of the user's session. That evidence was not re-verified here: the raw event log was not found on disk. A future capture should confirm that both events arrive, and their order.
- **Token continuity is not new qualification.** It carries the existing unknown-version token policy across compaction. Any post-compaction identity or index anomaly still blocks terminally.
- **Older builds** reading data written by newer builds may still block at their own next live compaction. They never interpret the data as money-qualified.

## 9. Oracle disagreement record

### 9.1 Breadth of the view-model clear — resolved in round 1

One lane initially proposed clearing *any* `.transport` status on an empty `status` result. Its reasoning: an empty status is the inverse of a non-empty one, exact matching couples the view model to translator wording, and clobbering a live `tool_progress` label would self-heal. The other lane proposed an exact match on `.transport` plus "Compacting context", arguing that `.transport` is shared by `tool_progress`, `task_progress`, auth, and the "Thinking…" fallback, so a status-channel release cannot prove ownership of whatever transport text is displayed. Verified evidence showed the string coupling already exists (`ClaudeContextUsageEstimator.swift:160-166`). The broad-clear lane conceded fully. Both agreed to delete the dead "Permission mode:" branch, which was originally proposed for keeping by the narrow-clear lane until the dead-code evidence was shown.

### 9.2 Releasing on `compact_boundary` — resolved in round 1

One lane rejected it: it couples UI to a transcript row, fires only on success, and is redundant once a null status arrives. The other lane argued that it reacts to the protocol event rather than the rendered row, and supplies a completion signal for versions that might not send a null status on success, which nobody has captured. The rejecting lane conceded: it is an explicit wire event, and duplicate releases are no-ops under §9.1.

### 9.3 Absent or malformed status, marker-only release, and coexistence rules — resolved in round 2

One lane wanted to distinguish an explicit null from an absent key (absent and malformed values would not release), plus non-null `compact_result`/`compact_error` releasing without a status field, plus precedence rules (terminal + "compacting" → release only; terminal + ordinary → release then status). The other lane argued for the status field as the single authority:
- Under the exact-match clear, over-release can only withdraw "Compacting context", while under-release reproduces the defect.
- Marker-only release exists solely to patch the gap the null-vs-absent distinction opens. It also adds a second predicate over the accounting evidence keys with different semantics, which is a maintenance hazard.
- The precedence rules cover contradictory payloads that have never been captured.

The first lane conceded all three points, adding one qualification that was adopted: a release means "withdraw this label", and early withdrawal may last for the rest of the compaction rather than being "slightly early". Both lanes stated explicitly that the residual difference was not material: their outputs are identical on every captured payload.

### 9.4 Minor points resolved by the plan author

- **Where the canonical label lives:** a private view-model constant plus pin tests, rather than a public package constant. `AgentModeViewModel.swift` does not import `RepoPromptClaudeCompatibleProvider` today (only `ClaudeCompatibleProviderRuntimeBridge.swift` does), and adding that import for one label isn't warranted.
- **Ordering of the estimator call:** keep it first, with a single branch rather than an early exit. `ingestStatusSignal` is nil-safe, so this is behavior-neutral and the smaller diff.
- **Tokens-only ID check:** require the exact prefix *and* a non-whitespace version suffix. This is harmless and more fail-closed.
- **`claudeDisplayableStatusText`:** reduce it to trimming, since its only caller is the status case and its permission stripping is dead.
- **Existing tests:** verified that only `ClaudeNativeUsageContractTests.swift:163-166` must flip. Runtime-integration compaction-block cases use a registered, non-compaction-qualified synthetic contract and stay valid.

No material disagreement remains open.
