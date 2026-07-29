# Technical Implementation Report - 2026-07-29 - Parallel Dual-Oracle Sessions

## Executive Summary

This implementation enables one Agent Mode orchestrator tab to start up to two independent Oracle conversations concurrently, select a different exact model preset for each lane, observe both lanes in the Oracle UI, and verify the resolved model identity before synthesis.

The work hardened the existing per-session concurrency machinery rather than introducing a second Oracle subsystem. It added atomic same-session rejection, exact query correlation, a two-stream per-tab MCP cap, durable model attribution, explicit model identity in tool results, multi-session Oracle UI controls, and prompt/tool guidance for natural named-preset requests. A follow-up diagnostic change makes configured-but-disabled presets visible as **not selectable** and explains how to enable them without bypassing the user-controlled MCP preset toggle.

The user manually confirmed the primary end-to-end behavior with two simultaneously streaming lanes using `KnowledgeDuelA` and `KnowledgeDuelB`; both returned the requested preset identities and were synthesized only after verification.

## Evidence and Limitations

- **Session context available:** Yes. The report uses the implementation discussion, user decisions, review findings, command output, and the user's live smoke result.
- **Git baseline available:** Yes. The working tree is based on commit `fe68009b` (`v1.0.29`) on branch `feat/duo-duel-oracles`.
- **Validation evidence available:** Yes, including focused XCTest runs, lint, builds, packaging, independent review, and a user-run live dual-Oracle consultation.
- **Report scope:** The uncommitted working-tree changes relative to `fe68009b`, plus this report.
- **Known limitations:** The complete root XCTest suite did not finish green because unrelated persistence/Git tests failed. The two reproducible Git failures are outside the changed files. The final configured-but-disabled diagnostic was covered by focused tests and a Swift build but was added after the user's successful live dual-lane consultation.
- **Local planning artifact:** `docs/plans/parallel-oracle-sessions-2026-07-29.md` informed the work but is ignored by repository policy and is not part of the commit.

## User Intent and Scope

**Observed in session:**

- Run two independent Oracle opinions at the same time from one orchestrator session, not sequentially.
- Select two different Oracle models at runtime through user-defined model presets.
- Support independent review, one or more debate rounds, and final synthesis.
- Cap MCP-origin Oracle concurrency at two per Agent Mode tab.
- Reject reuse of a streaming Oracle chat instead of cancelling its existing response.
- Keep one Oracle pill rather than adding two brain icons.
- Show both sessions through a count and an inline chip switcher.
- Persist and display the actual model used by each Oracle.
- Allow a natural request such as “ask KnowledgeDuelA and KnowledgeDuelB independently and synthesize.”
- Match named presets deterministically by exact UUID or exact name; never silently fuzzy-match to another Oracle.
- Preserve the user-controlled **Use Oracle Model Presets for MCP** setting rather than bypassing it.
- Keep the work on the personal feature branch `feat/duo-duel-oracles` for later integration into a personal stable build based on upstream releases.

**Explicitly rejected or deferred:**

- Raw provider catalog model IDs were dropped from v1 after the user confirmed that maintaining two presets was acceptable.
- Two separate Oracle pills/icons were rejected in favor of one pill plus model-labelled session chips.
- Automatic same-session forking was rejected; busy sessions fail deterministically.
- A batch `consultations:[...]` API was deferred. The current feature relies on the orchestrator provider emitting parallel tool calls; the user confirmed simultaneous execution in the tested lane.
- Explicit model selection does not bypass the MCP preset-use toggle.

## Change Inventory

All pre-report implementation files were modified and unstaged when this report was generated.

| Git Status | Index / Worktree State | Files | File Role | Purpose | Evidence / Notes |
|---|---|---|---|---|---|
| Modified | Unstaged | `Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift`, `OracleViewModel+MCP.swift` | Source | Atomic send reservation, overlap policy, exact query start result, two-lane cap, forced distinct sessions, model selection and result identity | Observed in code and focused tests |
| Modified | Unstaged | `Sources/RepoPrompt/Infrastructure/MCP/MCPOracleToolService.swift`, `ChatToolError.swift`, `MCPOracleToolProvider.swift` | Source/API | `model` and `chat_name` arguments, validation, stable errors, Oracle utilities, preset diagnostics, tool descriptions | Observed in code and tool-catalog tests |
| Modified | Unstaged | `Sources/RepoPrompt/Infrastructure/AI/Models/ModelPreset.swift`, `AppSettingsMCPService.swift` | Source/configuration | Shared MCP preset-usage state and accurate setting description | Added after live configuration diagnosis |
| Modified | Unstaged | `ChatSession.swift`, `ChatHistoryManager.swift` | Source/persistence | Durable latest-send model ID/display name in full sessions and lightweight stubs | Observed in JSON persistence tests |
| Modified | Unstaged | `AgentOraclePill.swift`, `AgentRuntimeSidebarView.swift` | Source/UI | `Oracle · N`, inline session chips, sticky/pinned transcript choice, per-session model and short ID, streaming-first rows | Observed in code and routing tests |
| Modified | Unstaged | `ToolArgsDTOs.swift`, `ToolCardRouter.swift`, `ToolResultCommunicationCards.swift`, `ToolResultDTOs.swift`, `ToolOutputFormatter.swift` | Source/UI/API | Requested/resolved model identity in cards and formatted results; exact chat routing | Observed in code and routing/catalog tests |
| Modified | Unstaged | `AgentToolResultPersistencePolicy.swift` | Source/persistence | Preserve model selector/source/preset/model identity through compact transcript persistence | Observed in focused persistence tests |
| Modified | Unstaged | `AgentModeMCPToolPolicy.swift` | Source/policy | Expose `oracle_utils op=models` to normal orchestrator roles while keeping explore restricted; Agent Mode rejects workspace-wide `op=sessions` | Observed in policy tests |
| Modified | Unstaged | `AgentModePrompts.swift`, `SystemPromptService.swift`, `RepoPromptWorkflowPrompts.swift`, `WorkflowPrompt+Reminder.swift` | Source/prompts | Natural named-Oracle discovery, exact selector use, parallel batching, identity verification, fail-closed synthesis | Observed in prompt catalog tests |
| Modified | Unstaged | `ContextBuilderAgentViewModel.swift` | Source/caller adaptation | Accommodate the typed Oracle send-start contract | Observed in diff/build |
| Modified | Unstaged | Six focused XCTest files under `Tests/RepoPromptTests/AgentMode`, `ChatHistoryJSONOnlyTests.swift`, and three MCP/prompt test files | Tests | Concurrency, UI selection, persistence, policy, API validation, identity, disabled-preset diagnostics, catalog contracts | Observed in focused test runs |
| Modified | Unstaged | `Scripts/Fixtures/test-suite-contract-ledger.tsv` | Test metadata | Register new/updated executable test contracts | Ledger verification still reports unrelated existing mismatch |
| Modified | Unstaged | `Scripts/source_layout_guardrails.sh` | Repository policy | Explicitly allow this user-requested durable implementation report | Required by commit preflight |
| Added | Untracked before staging | `docs/technical_implementation_reports/2026-07-29-parallel-dual-oracle-sessions.md` | Documentation | Preserve implementation, validation, risks, and operating guidance | This report |

## Implementation Details

### 1. Concurrency Safety and Exact Query Correlation

**Problem / Goal:**
The existing system could stream separate Oracle sessions concurrently, but a second send to the same session cancelled the first, and MCP response lookup could fall back to another session's `currentQueryId`.

**What Changed:**

- Added `OracleViewModel.SendOverlapPolicy` with `.cancelExisting` for UI sends and `.rejectIfBusy` for MCP sends.
- Added typed `SendStart` outcomes carrying the exact started query ID or a deterministic rejection.
- Moved busy/cap checks and stream registration into an atomic MainActor reservation path.
- Rechecked reservation after UI cancellation awaits.
- Removed the MCP `activeQueryId ?? currentQueryId` correlation fallback.
- Added a two-stream MCP-origin cap per Agent Mode tab.
- Added stable `oracle_session_busy` and `oracle_concurrency_limit` behavior.
- Prevented rejected third-lane cleanup from restoring a stale active Oracle pointer over a newer UI selection.

**Why This Approach:**
Observed in review and code: the MainActor owns session/run transitions, so it is the authoritative boundary for an atomic check-and-commit. Returning the query ID from send startup prevents both fast-finalization and cross-session correlation races.

**Key Files and Symbols:**

- `OracleViewModel.swift`
  - `SendOverlapPolicy`
  - `SendStart`
  - send reservation and streaming state
- `OracleViewModel+MCP.swift`
  - `tool_chatSend`
  - exact query wait/result lookup

**Behavior Before:**
Two distinct sessions could overlap, but same-session sends cancelled each other and response correlation used a global fallback.

**Behavior After:**
Two distinct MCP lanes can stream concurrently; a third lane or a same-session overlap fails without cancelling or impersonating another lane.

### 2. Distinct Parallel Sessions

**Problem / Goal:**
Two simultaneous `new_chat:true` calls could both reuse a blank “New Chat” session before either appended its first message.

**What Changed:**

- Added `reuseBlankSession` with the existing behavior as the default.
- MCP force-new Oracle lanes pass `reuseBlankSession:false`.
- New-chat rejection cleanup preserves a subsequently selected active session.

**Evidence:**
Observed in code, regression tests, and independent review.

### 3. Deterministic Preset Selection and Identity

**Problem / Goal:**
`ask_oracle` did not accept `model`, and `chat_name` could be mistaken for a selector.

**What Changed:**

- Added `model` and display-only `chat_name` to `ask_oracle`.
- `ask_oracle` accepts an exact preset UUID or exact case-insensitive name; its strict path does not fuzzy-match.
- New chats fail closed when multiple compatible presets exist and no explicit model is supplied.
- Results expose:
  - `model_selection`
  - `model_source`
  - `model_preset_id`
  - `model_preset_name`
  - `model_id`
  - `model_name`
- Tool cards, formatted output, and compact transcript persistence retain the resolved identity.

**Tradeoff:**
The first version uses configured presets only. This requires one-time user setup but protects provider configuration, effort settings, and model identity behind stable user-defined names.

### 4. Preset Availability and Disabled-State Diagnostics

**Problem / Goal:**
The user's presets existed, but `oracle_utils op=models` showed only `current_chat_model`.

**Root Cause — Observed in session and live configuration:**
The Tools-page `oracle_utils` checkbox enabled the tool, while the separate global `mcp.show_model_presets` setting remained `false`. Both `KnowledgeDuelA` and `KnowledgeDuelB` were present in `modelPresets.json`.

**What Changed:**

- Added `MCPModelPresetUsageState` with enabled, none-defined, disabled-by-toggle, and temporarily-hidden states.
- Kept the `Available models` list limited to actually selectable models.
- When configured presets are blocked, `oracle_utils` appends a separate **NOT selectable** section with UUIDs, names, modes, and exact remediation.
- Explicit requests for blocked presets fail before send and state that the preset existed but was not used.
- Updated the `app_settings` description to explain that the toggle controls MCP selectability.

**Decision:**
The toggle remains authoritative. Explicit model selection cannot bypass it.

### 5. Durable Model Attribution

**What Changed:**

- Added optional `lastSendModelID` and `lastSendModelDisplayName` to `ChatSession`.
- Preserved both fields through JSON decoding, lightweight list stubs, autosave stub merging, cloning/forking, and session metadata reads.
- UI display prefers the latest loaded assistant message's model name when available, otherwise the denormalized session metadata.

**Compatibility:**
The fields are optional and decode with `decodeIfPresent`, so legacy chat files remain valid.

### 6. Multi-Session Oracle UI

**What Changed:**

- The existing single pill remains.
- While multiple eligible sessions stream, the label becomes `Oracle · N`.
- The popover includes an inline session-chip row with per-lane streaming state, model attribution, and short chat identity.
- Manual chip selection is pinned so a newer stream does not steal the transcript.
- Exact tool-result routing continues to open the corresponding Oracle chat.
- The runtime sidebar shows all running sessions first, followed by recent completed sessions, with model and short-ID attribution.

**Why One Pill:**
Observed user decision: model-labelled chips express the meaningful identity, avoid titlebar churn, and fit the two-lane cap better than arbitrary duplicate brain icons.

### 7. Natural Named-Oracle Orchestration

**What Changed:**

- Normal Agent Mode orchestrator roles can discover `oracle_utils`; explore remains restricted.
- Prompts and tool descriptions direct the agent to:
  1. Call `oracle_utils op=models`.
  2. Resolve every requested Oracle name.
  3. Prefer exact preset UUIDs.
  4. Issue independent calls together with `new_chat:true`.
  5. Treat `chat_name` as display-only.
  6. Verify returned identities.
  7. Refuse synthesis on missing/mismatched identity or a failed lane.
- `oracle_utils op=sessions` remains blocked in Agent Mode because its workspace-wide metadata is not safely scoped to one run.

## Technical Decisions

| Decision | Rationale | Alternatives Considered | Consequences / Risks | Evidence |
|---|---|---|---|---|
| Cap MCP Oracle streams at two per tab | Matches the desired duel workflow and visible UI scope | Unbounded streams; per-run cap | A third lane waits/fails; UI-origin sends are not capped | User decision and code/tests |
| Hard-error on busy session | Prevent one lane from cancelling another | Auto-fork; retain cancel semantics | Caller must use a new chat or wait | User/reviewer decision |
| Preset UUID/name selectors only | Deterministic identity with controlled provider/model settings | Raw catalog IDs | Requires preset setup | User accepted this tradeoff |
| Strict `ask_oracle` matching | Wrong-model silence is worse than a retry | Existing fuzzy preset matching | Agents must use discovery output exactly | Third-party and Oracle review |
| One pill plus chips | Model identity is more useful than duplicate icons | Two pills/brain icons; dropdown | One transcript visible at a time | User decision |
| Persist denormalized latest-send model metadata | Avoid loading every transcript just to render lists | Ephemeral UI state; reuse `preferredAIModel` | Metadata describes latest send, not every historical turn | Review finding and persistence tests |
| Preserve preset-use toggle authority | Prevent unexpected spend/provider selection | Explicit selector bypass | User must enable the setting once | Live diagnosis and fresh Oracle review |

## Challenges, Debugging, and Resolutions

| Challenge | Evidence | Resolution | Remaining Risk |
|---|---|---|---|
| Query result could attach to the wrong session | Review identified `activeQueryId ?? currentQueryId`; code inspection confirmed it | `sendMessage` returns exact query ID; MCP uses only that ID | None observed in focused concurrency tests |
| Same-session overlap check could race across awaits | Independent review | Atomic reservation plus UI post-cancel recheck | UI can intentionally cancel an MCP stream; user wins |
| Blank-session reuse collapsed two force-new lanes | Oracle plan review | MCP new-chat disables blank reuse | Covered by regression test |
| Rejected third lane could overwrite a newer active pointer | Sol/Oracle review | Restore only when the rejected session still owns the pointer | Covered by interleaving test |
| Missing `chat_name` bypassed the original explicit-model guard | Sol/Oracle review | Guard now applies to every ambiguous `new_chat:true` call | Covered by service test |
| `oracle_utils` was enabled but presets were absent from discovery | User live test plus `app_settings`/JSON evidence | Distinguished tool ACL from preset-use toggle; added diagnostics | User must enable the global toggle |
| Full suite reported unrelated failures | Full `make dev-test` output | Reran failing suites; persistence suite passed alone, two Git tests remained | Full root suite is not green |
| Ledger verification reported unrelated stale/missing contracts | `verify-ledger` output | Added this feature's ledger rows; left unrelated workspace projection entries untouched | Three missing and two stale unrelated rows remain |

## Validation and Testing

| Check | Command / Method | Result | Notes |
|---|---|---|---|
| Agent Mode Oracle tool policy | `make dev-test FILTER=AgentModeMCPToolAdvertisementPolicyTests` | Passed, 2 tests | Normal orchestrators see `oracle_utils`; explore does not |
| MCP Oracle service and worktree behavior | `make dev-test FILTER=MCPAskOracleWorktreeTests` | Passed, 25 tests | Includes arguments, fail-closed model selection, disabled diagnostics, sessions restriction |
| Oracle pill/routing/concurrency | `make dev-test FILTER=AgentOraclePillRoutingTests` | Passed, 12 tests | Includes two streams, pinned selection, cap/pointer behavior, persistence |
| Tool-result navigation | `make dev-test FILTER=OracleOperationToolCardRoutingTests` | Passed, 10 tests | Exact Oracle chat routing and identity |
| Compact result persistence | `make dev-test FILTER=AgentToolResultPersistencePolicyTests` | Passed, 14 tests | Model identity survives transcript compaction |
| Workflow prompt contracts | `make dev-test FILTER=WorkflowPromptCatalogTests` | Passed, 5 tests | Named-Oracle fail-closed guidance |
| Tool catalog contract | `make dev-test FILTER=ToolCatalogSnapshotTests` | Passed, 6 tests | Updated Oracle tool descriptions/schema signatures |
| JSON chat compatibility | Focused `ChatHistoryJSONOnlyTests` run during implementation | Passed | New optional model metadata and legacy decoding |
| Formatting and lint | `make dev-format`; `make dev-lint` | Passed | Final lint: zero SwiftFormat findings; strict SwiftLint passed |
| Product build | `make dev-swift-build PRODUCT=RepoPrompt` | Passed | Repeated after disabled-preset diagnostic |
| Debug package | `./conductor build` | Passed on the final tree during report generation | Packaging included signing, architecture validation, embedded MCP layout validation, and the embedded MCP smoke |
| Diff integrity | `git diff --check` | Passed | Repeated after final changes |
| Authoritative test list | `make dev-test-list` | Passed | Test IDs available for ledger checks |
| Test ledger | `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | Failed: unrelated `missing=3`, `stale=2` | All remaining examples are `WorkspaceProjectedPathSearchTests` |
| Full root suite | `make dev-test` | Failed | One persistence failure passed in isolation; two `GitBlobIdentityServiceTests` failures remained and their files were unchanged |
| Live dual-Oracle smoke | User-run Agent Mode request using `KnowledgeDuelA` and `KnowledgeDuelB` | Passed | User confirmed simultaneous execution, correct returned preset identities, and successful synthesis |
| Independent implementation review | GPT-5.6 Sol xhigh plus fresh Oracle | Approved after fixes | Two P1 findings were fixed before approval |
| Disabled-preset UX review | Fresh Oracle, plan chat `untitled-chat-1AA196` | Recommendation incorporated | Kept toggle authoritative and separated unavailable presets |

## Operational and Integration Impact

- **Dependencies changed:** None observed.
- **Configuration:** The global **Use Oracle Model Presets for MCP** toggle must be enabled for named presets to be selectable. Tool availability and preset use are separate controls.
- **Storage:** Two optional fields are added to chat-session JSON. No migration is required.
- **MCP API:** `ask_oracle` now accepts `model` and `chat_name`; results include resolved model/preset identity; new busy and concurrency-limit errors are observable.
- **Feature limits:** Maximum two simultaneous MCP-origin Oracle streams per Agent Mode tab.
- **Runtime:** Claude-compatible orchestrators were observed issuing parallel calls. A client that serializes tool calls will still produce correct independent lanes but not simultaneous streaming.
- **Backward compatibility:** Existing UI sends retain cancel-existing behavior by default. Existing session JSON decodes without the new optional fields.
- **Security/privacy:** Agent Mode can use `oracle_utils op=models`, but workspace-wide `op=sessions` remains unavailable.
- **Deployment:** No database, dependency, environment-variable, or release-schema changes are required.

## Risks, Limitations, and Technical Debt

- The batch `consultations:[...]` form remains deferred; providers that serialize tool calls cannot force simultaneous lanes through the single-call API.
- Only one transcript is visible at a time in the pill popover; side-by-side comparison is not implemented.
- The two-lane cap is fixed rather than configurable.
- A cancelled MCP request can leave its Oracle stream running to completion and holding a cap slot; the session remains recoverable by explicit chat ID.
- The full repository test suite is not currently green because of failures outside this diff.
- The test ledger retains unrelated stale/missing workspace projection contracts.
- The final disabled-preset diagnostic has focused automated coverage but was not included in the user's earlier successful live duel because it was implemented afterward.

## Follow-up Work

### Immediate

- Enable **Use Oracle Model Presets for MCP** before running named duels.
- Rerun the user smoke after the final diagnostic build if the disabled-state wording itself needs visual verification.
- Review the staged diff and run the repository commit preflight before committing.

### Future

- Consider a batch consultation API if simultaneous execution must work with clients that serialize tool calls.
- Consider first-class debate orchestration metadata if cross-lane round exchange becomes a common workflow.
- Resolve the unrelated root-suite Git failures and workspace projection ledger mismatch separately.
- Consider making the two-lane cap configurable only if operational evidence justifies it.

## Maintainer Notes

- `chat_name` is strictly presentation metadata; never use it for model selection.
- Continue a lane with its returned `chat_id`; do not rely on “latest” session selection under concurrency.
- Exact preset UUIDs are the most reliable selectors, especially if names are later edited.
- Do not remove the MainActor atomic reservation boundary or reintroduce a global query-ID fallback.
- When rendering session lists, use lightweight model metadata; do not load every chat transcript.
- Do not reuse `preferredAIModel` for latest MCP override attribution because it controls chat UI model state.
- Keep configured-but-disabled presets outside the selectable `Available models` block.

## Metrics

- **Baseline:** `fe68009b` (`v1.0.29`)
- **Implementation files changed before this report:** 32
- **Implementation diff before this report:** 2,969 additions, 337 deletions
- **Total committed files including report allowlist and report:** 34
- **Components affected:** Oracle chat runtime, MCP tool service/API, model presets, Agent Mode prompts/policy/transcript persistence, Oracle pill/sidebar/tool cards, chat-session persistence, focused tests
- **Dependencies added:** 0
- **Duration:** Unknown; no single authoritative session-duration metric was recorded

> Generated from AI-agent coding session evidence on 2026-07-29.
