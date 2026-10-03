# Oracle error copy, tool labels, and delegated `ask_user` escalation plan

Scope: read when the task touches Oracle provider error presentation (`asFriendlyString`, `OracleViewModel.userFriendlyErrorMessage`), request-size failure copy, RepoPrompt MCP tool display names, the completed `ask_user` card, or how a delegated child session's `ask_user` question reaches its parent agent.
Authority: Reference
Last-verified: 2026-10-02

Status: Implementation is present for §3–§6. Source validation and the owner-requested OracleA/OracleB remediation review are complete: both fresh round-2 reviews accepted staged code tree `86a532cb1e1caf62e80cc90445dc5005c733c2d1` and explicitly closed all remaining P1 findings on 2026-10-02. The final remediation run passed 323 focused tests, lint, format check, the RepoPrompt product build, guardrails, and staged preflight. Live-provider, default-font visual, and cold relaunch/replay results are recorded below. The targeted repair acceptance gates passed; source approval and these checks are not blanket release qualification. The plan remains active for the unrun large-font/text-selection and human-answer escalation checks in §7. Deferred minor findings remain separate follow-up work, and `verify-ledger` still reports the unrelated preexisting HEAD omission for `AgentDelegationPolicyTests/testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders`. The owner requested one staged change (no PR split); no commit is authorized in this implementation session.

Implementation evidence (2026-10-02): the owner's screenshot identified `AgentModeView.runningIndicator` as the raw-label renderer. It showed the canonical `mcp__RepoPromptCE__agent_run` spelling; `AgentRunningElapsedText.elapsedText` renders the adjacent dot and elapsed time, not a count. The fix formats known tool names at that boundary and leaves prefix authorization and elapsed-time rendering unchanged. The durable delegated-question contract is maintained in [bounded MCP delegation](../agent-mcp-delegation-depth.md#delegated-questions).

Decision process:
- Two independent Oracle lanes (OracleE and OracleD) received an identical brief with file:line evidence that had been verified against the live checkout.
- They then went through two anonymous reciprocal challenge rounds on four material disagreements (§8). One converged. Three survived both rounds, with the lanes swapping positions in each round.
- The repository owner then decided all open points (below). Minor differences were settled by the plan author after checking the code (§9).

Owner decisions (2026-10-02):
1. **Questions escalate up the delegation chain.** A child's `ask_user` goes to its parent agent, not to the user. The parent answers using its own judgment (`agent_run respond`). If it cannot, it calls `ask_user` itself, which escalates one level further. Only the top-level main agent's `ask_user` reaches the user and takes their attention.
2. **Idle parent: no automatic turn.** If the parent's turn has already ended, the question is delivered at the start of the parent's next turn. No unsolicited paid turn is started.
3. **The child's timeout pauses** while the question is with the parent chain.
4. **Context-window line:** show it, clearly labeled, only when the model's window is known exactly (§3.3).
5. **No delegation system-prompt change.** The escalation guidance travels in the delivered notice itself (§6.3).
6. **Prompt cache matters.** Claude and Codex parents usually sit in up to 25-minute waits, and their cache TTL is 30–60 minutes. Delivery must not depend on a parent's wait timing out (§6.6).

Live qualification update (2026-10-03): real Claude and Codex parents passed unrelated-child wait wakeups and paused child timeouts; Claude passed idle next-turn delivery with a root-generated unknown token, and Codex passed busy-tool delivery and a three-second delegated-question wake during an accepted Oracle consultation that later completed without resend. A long covered-question notice persisted intact in the parent transcript; the child completed-card persistence defect was discovered later. The unknown-token direct covered-wait case exposed a formatter omission: the live parent received the interaction identity and generic prompt but not `interaction.fields`. The scoped formatter repair now renders complete single and nested structured questions. Its regression tests fail against the original source; the production `askUser` → snapshot → wire → formatter integration also passes, and its negative control leaves wire assertions passing while rendered-content assertions fail. Focused runs passed 60 and 43 tests (overlapping suites); lint, format check, guardrails, context checks, and debug packaging passed. Fresh OracleA and OracleB re-reviews explicitly closed the production-mapper P1 and found no material fix-induced regression. At that checkpoint the running app was still the pre-repair binary, so fixed-binary covered-wait live validation, visual acceptance, and relaunch/replay remained open. Later fixed-binary evidence is recorded below; source remediation approval alone is not full live qualification.

Fixed-binary E2E follow-up (2026-10-03, HEAD `4bcc2f8a`): two further scoped defects. (1) A single `agent_run` wait re-parses its raw value through `AgentRunMCPToolService.snapshot(from:)` before decorating it, and that converter dropped each field's `context`, `allows_multiple`, and `allows_custom` and re-emitted `allows_other: false`, so the formatted wait lost per-question context and selection semantics; the converter now round-trips the field shape exactly. (2) Canonical save reduced every completed `ask_user` result to a `summary_only` status stub and dropped its args, so a reloaded card showed a generic "Question" / "No response" with no expansion; see §4 Persistence. Both repairs have regressions that fail against the original source (six converter assertions and 28 persistence assertions). The isolated six-suite run passed 66 tests; fresh OracleA and OracleB reviews explicitly closed both source defects with no material fix-induced regression and report-only P2 follow-ups.

Live fixed-binary acceptance (2026-10-03, build commit `aaa637f0`, binary UUID `F21573C4-C2E6-3AEF-BECE-687803B6FA4B`): Claude and Codex parents received complete direct-child wait results, including a root-generated opaque answer available only in per-question context, a 14 KB context with a trailing sentinel, option descriptions, and both single/multiple/custom selection constraints. Both answered correctly using `agent_run respond`; child `ask_user` results were `timed_out:false` after 59 seconds (Claude) and 23 seconds (Codex), despite a two-second timeout and a deliberate six-second parent pause. Both parents and children completed. Canonical files retain the full 15.5 KB question arguments and exact submitted answers with `summaryOnly:false`. The completed card expands, its context wraps at a narrower window width, and the running label displays `Agent Run` with elapsed time. The current workspace was not switched; the original tab and geometry were restored. Closing completed child tabs was initially refused because provider connections still held live run bindings. The owner subsequently relaunched the same build, and the cold-reload gate passed: the app process changed from PID 81919 to 66384 with the same binary UUID; both canonical question/answer payloads remained byte-identical; both reloaded cards expanded with their complete context tail, option descriptions, and answers; both child continuations completed with `COLD_REPLAY_OK`; canonical re-save retained the exact original exchange with exactly one `ask_user` result; and Claude and Codex parent continuations completed with `COLD_PARENT_REPLAY_OK`. The transcript XML export abbreviates long tool arguments, so full-card content was verified through targeted accessibility inspection rather than inferred from that export. These checks did not switch workspaces. Large-font/text-selection acceptance and the live human-answer escalation round trip in §7 were not exercised. Already-truncated legacy cards cannot be reconstructed by this repair.

## 1. Outcome and scope

The user reported four issues:

1. Oracle shows raw diagnostic errors, for example `Unknown error [RepoPromptApp.AIProviderError, code 2]: apiError(...)` for a Codex 1,048,576-character rejection, and `... code 1]: invalidConfiguration(detail: "Prompt is too long")`. The user wants actionable copy that states the maximum supported size.
2. A tool label appears as `mcp_RepoPromptCE_agent_run • 1`.
3. The completed `ask_user` card truncates questions and answers, and there is no way to expand it.
4. A child agent's `ask_user` question gets buried: its parent agent is not told, so the question can wait until it times out or until the user happens to find it.

Non-goals for this plan:
- a Codex character-length preflight;
- automatically starting a paid model turn for an idle parent;
- widening RepoPrompt tool-name matching used for authorization;
- native Codex `spawn_agent` children;
- approval, elicitation, and permission escalation;
- OS notifications;
- provider-native cache keep-alives;
- making the child's `ask_user` itself bounded or resumable.

## 2. Verified starting points

Line references identify the checkout inspected on 2026-10-02.

| Boundary | Evidence and consequence |
|---|---|
| Shared formatter | [`Error.asFriendlyString()`](../../../Sources/RepoPrompt/Infrastructure/Utilities/ErrorExtensions.swift#L13) (L13–71) recognizes only `CustomOpenAIProviderError`, `OpenAIErrorResponse`, and the SwiftOpenAI/SwiftAnthropic `APIError` types. Everything else falls through to `"Unknown error [domain, code]: \(self)"` (L71). No test pins that string. It has about 30 callers, including settings alerts and Context Builder background-plan errors. |
| Existing readable descriptions | [`AIProviderError: LocalizedError`](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift#L229) (L229–253) already maps `.apiError`/`.unknown` to `source?.localizedDescription` and `.invalidConfiguration` to `detail`. These descriptions are never consulted. |
| Oracle error path | The stream-failure handler appends `"\n\n--\nError:\n\(errorMessage)"` ([`OracleViewModel.swift`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift#L4004) L4004–4010), which matches the reported format. [`userFriendlyErrorMessage(for:tokenCount:)`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel.swift#L4050) (L4050–4103) is its only caller (L4006). `tokenCount` comes from `promptViewModel.totalTokenCount` (L4005). |
| Codex character cap | The cap is the provider's `NSError` domain `CodexAppServer` text "Input exceeds the maximum length of 1048576 characters." [`CodexCLIProvider.buildPrompt`](../../../Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexCLIProvider.swift#L859) (L859–884) joins the reminder, the full conversation history, and the packaged context tail into one string, so long Oracle chats grow into the cap. |
| Token preflight | Only the MCP path has one: [`OracleViewModel+MCP.swift`](../../../Sources/RepoPrompt/Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift#L1654) (L1654–1681). It is token-based and throws [`ChatToolError.oracleContextOverflow`](../../../Sources/RepoPrompt/Infrastructure/MCP/ChatToolError.swift#L13) only when `windowSource == .exact`. It is the only `OracleRequestBudgetEstimator.estimate` call site. The chat failure path above has no preflight. |
| "Prompt is too long" | The phrase is not in `Sources/` or `Packages/`. It is provider text wrapped as `invalidConfiguration` at one of: `CodexCLIProvider.swift` L134/219/299/349, `ClaudeCodeAgentProvider.swift` L615, `ClaudeCompatibleProviderRuntimeBridge.swift` L171, or `ACPHeadlessAgentProviderBridge.swift` L193. Which one emitted it, and what limit applied, is unknown. |
| Tool-name resolver | The server name is `RepoPromptCE` ([`RepoPromptMCPServerConfiguration.swift`](../../../Sources/RepoPrompt/Infrastructure/MCP/RepoPromptMCPServerConfiguration.swift#L16)). [`stripExplicitRepoPromptPrefix`](../../../Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift#L182) (L182–193) accepts `mcp__repopromptce__`, `mcp_repopromptce__`, `repopromptce__`, and `repopromptce_`, but not `mcp_repopromptce_`. The same resolver backs `isRepoPromptToolNameWithServerPrefix` (L249–253), which sits next to authorization-related code (L263). |
| Label surface unknown | [`toolDisplayName`](../../../Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolCardContainer.swift#L552) would title-case an unknown name ("Mcp RepoPromptCE Agent Run") rather than print it raw. Cluster chips use `×N` ([`ClusterToolCategory.swift`](../../../Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ClusterToolCategory.swift#L126) L126–141). The raw-name `•` joiners ([`AgentToolResultPersistencePolicy.swift`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentToolResultPersistencePolicy.swift#L1134) L1134–1136 and [`AgentTranscriptServices.swift`](../../../Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/AgentTranscriptServices.swift#L1582) L1582–1587) append a status word, not a number. The gateway PWA assets contain no `•`. The exact raw name is also unconfirmed: the user's text may have been mangled from double underscores. |
| Completed `ask_user` card | Context is limited to 2 lines ([`AgentMessageBubble.swift`](../../../Sources/RepoPrompt/Features/AgentMode/Views/AgentMessageBubble.swift#L750) L750–755), questions to 3 (L1619–1621), and answers to 3 (L1630–1634). There is no expand control. The display decoder `AskUserQuestionArgs.Question` (L1308–1313) drops per-question `context` and `options`, although [`AgentAskUserQuestion`](../../../Sources/RepoPrompt/Features/AgentMode/Models/UserInteractionModels.swift#L140) carries both. Runtime presentation keeps the raw payload, but canonical save originally kept only a summary stub and no args (see §4 Persistence). |
| Reveal routing today | [`MCPAskUserToolProvider`](../../../Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAskUserToolProvider.swift#L136) (L136–144) reveals only for tabs that are not MCP-controlled ([`isMCPControlled`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L6050) is `mcpControlledTabIDs` membership). [`WindowState.revealPendingInteraction`](../../../Sources/RepoPrompt/App/WindowState.swift#L1636) (L1636–1649) calls `NSApp.activate(ignoringOtherApps: true)`, `makeKeyAndOrderFront`, and switches the compose tab. So a top-level main agent's `ask_user` already takes the user's attention, and an `agent_run`-controlled child's does not. Owner decision 1 matches this split. |
| Child question reaches only a parent waiting on that child | A pending question becomes a `.question` interaction ([`AgentModeViewModel.swift`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L6647) L6647–6664) and the session status becomes `.waitingForInput` (L6305–6306). [`AgentRunSessionStore`](../../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunSessionStore.swift#L351) resumes only waiters whose cursor is that child's (L351–378) and returns the actionable snapshot immediately to later waits (L396–397). A parent waiting on a *different* child, sitting in an `ask_oracle` wait, busy with other tools, or idle is not told. |
| Parent wait scopes (wake targets) | Every `agent_run` wait registers an `AgentRunWaitScope` keyed by the parent `runID`, with its child session IDs ([`MCPServerViewModel.swift`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L2360) L2360–2378). Bounded `ask_oracle` waits register run-owned wake scopes with a sticky wake flag (`wakeOracleWaitScopes`, just after L2436). [`wakeAgentRunWaitersOwnedByActiveRun`](../../../Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift#L2510) (L2510–2537) wakes both kinds for a run, currently only with `WakeReason.steeringRequested`. |
| Wait and timeout constants | [`MCPTimeoutPolicy`](../../../Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPTimeoutPolicy.swift#L89): the automatic lifecycle wait is 1500 s for extended-cache Claude (L89) and for Codex (L92). The default `ask_user` timeout is 300 s (L140), and the workspace setting overrides it ([`MCPAskUserToolProvider`](../../../Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAskUserToolProvider.swift#L114) L114–115). Today a child's question can therefore time out (5 min) long before a parent waiting elsewhere returns (up to 25 min). |
| Timeout mechanics | `askUser` schedules `schedulePendingAskUserTimeout` from `interaction.askedAt` ([`AgentModeViewModel.swift`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L18823) L18823–18835). Generation-guarded reschedule and invalidate helpers already exist (L18897–18950). `AgentAskUserPendingState.timeoutStartedAt` drives the card countdown. |
| Answer authority and races | `agent_run respond` for a `.question` rejects an interaction ID that no longer matches ("The pending question no longer matches interaction_id.") and submits synchronously through `submitAskUserResponse` ([`AgentModeViewModel.swift`](../../../Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift#L9152) L9152–9178). Local resolution clears the pending question and its continuation and resumes once (L18990–19008). |

## 3. Step 1 — Actionable Oracle provider errors (issue 1)

### 3.1 Shared formatter (`ErrorExtensions.swift`)

Keep the existing branches and their order. Insert the following after the SwiftAnthropic branch and before the fallback:

1. **Unwrap `AIProviderError`.** For `.apiError(source)` or `.unknown(source)` with a non-nil source, return `source.asFriendlyString()`. The recursion is bounded by the wrapping depth, so a wrapped `CustomOpenAIProviderError` keeps its existing friendly text.
2. **Use `LocalizedError` descriptions.** Return a nonblank, trimmed `errorDescription` when one exists. This fixes `invalidConfiguration("Prompt is too long")` and also settings alerts such as `missingAPIKey`, which becomes "Missing API key.".
3. **Use explicit `NSError` descriptions.** Return a nonblank `userInfo[NSLocalizedDescriptionKey]` string, for example the `CodexAppServer` sentence. Do not fall back to Foundation's generic `localizedDescription`.
4. Otherwise, keep the existing `Unknown error [...]` text unchanged.

Contract: output changes only for errors that reach the fallback today and carry an explicit description. Structured MCP error codes and details are unchanged. No Oracle-specific advice leaks into settings or Context Builder messages.

### 3.2 Size-failure classifier (new pure type, `Sources/RepoPrompt/Infrastructure/AI/AIProviderRequestSizeFailure.swift`)

The interface is synchronous and nonthrowing: `static func detect(in: Error) -> AIProviderRequestSizeFailure?`. The result carries the limit (`.characters(Int)` or `.unreported`), the matched provider sentence, and `sourceDomain: String?`.

How it works:
- It unwraps `AIProviderError` sources with a bounded depth.
- It matches only two phrases, case-insensitively:
  - "maximum length of <positive integer, commas allowed> characters" gives `.characters`;
  - "prompt is too long" gives `.unreported`.
- It rejects malformed or overflowing numbers.
- It never derives a limit from an `NSError` code or from a bare "too long". There are no speculative token patterns.

### 3.3 Oracle copy (`OracleViewModel.userFriendlyErrorMessage`)

Call the classifier in the non-network branch, after the `CustomOpenAIProviderError` block and before the generic fallback. Network, `requestTooLarge`, and "no additional details" handling stay unchanged.

- **Character limit, domain `CodexAppServer`:**
  > Request too large. The Codex app server rejected this request; its reported input limit is 1,048,576 characters, which is separate from the model's token context window.
  >
  > Tip: Deselect some files or use slices, or start a new Oracle chat — this Oracle provider resends the full conversation history with every request.

  Format the number from the error; never hard-code it.
- **Character limit, any other domain:** the same message, without naming Codex and without the conversation-history clause.
- **No limit reported:**
  > Request too large. The provider rejected this request as too long and did not report a maximum size.
  >
  > Tip: Deselect some files or use slices, or start a new Oracle chat to drop earlier conversation history.
- **Model context window (owner decision 4):** after the limit sentence, add "Model context window: about N tokens. This is separate from the provider's input-size limit and is not the available input budget." Conditions:
  - only when `AIModelCapabilityMetadata.resolve(for:)` reports `windowSource == .exact` for the model **captured with the failed request**;
  - if that model is not available at L4006 without new retained state, omit the line;
  - never use the current UI selection.
- **Existing size line:** keep the `Current request size: ~N tokens` line when `tokenCount > 0`, and state that it is not a character count. Before wording it, confirm what `promptViewModel.totalTokenCount` covers; it may exclude earlier conversation history.

Keep the user's message, selection, and conversation intact on failure. Do not change the preflight or `buildPrompt`.

## 4. Step 2 — Expandable completed `ask_user` card (issue 3)

All changes are in `AgentMessageBubble.swift`.

- **Decoder:** `AskUserQuestionArgs.Question` decodes optional `context` and `options`. Options may be bare strings or `{label, description}` objects. Malformed optional entries are ignored one by one, so valid question and answer text never disappears. This is display tolerance only; the MCP request validator is unchanged.
- **Summary model:** `AskUserQuestionSummary.Question` gains `context`, `options` (label, description, and `isSelected` derived from `selected_options`), and `customResponse`. The historical scalar path leaves these empty. Make the summary and the robust parser `internal` for `@testable` tests.
- **Disclosure:** a single per-card disclosure using the same style as the nearby "Show N more lines" expander, labeled "Show full exchange" / "Show less". It is always shown on completed structured cards, is ephemeral `@State`, and is not persisted.

| Content | Collapsed | Expanded |
|---|---|---|
| Overall context | Existing 2-line limit | Complete |
| Question text | Existing 3-line limit | Complete |
| Answer text | Existing 3-line limit | Complete |
| Per-question context | Hidden | Shown when present |
| Options (selected marked) and descriptions | Hidden | All valid options, read-only |

- **Rendering:** all text remains selectable. There is no nested scroll view; the conversation's own scrolling is used. Skipped and timed-out semantics are unchanged.
- **Unchanged:** the pending interactive question card, validation, and submission.
- **Persistence:** canonical save (`AgentToolResultPersistencePolicy`, `.persistentStorage`) keeps a completed `ask_user` / `ask_user_question` result activity's args (the agent's questions) and result (submitted answers only; drafts are never part of either) verbatim, with `summaryOnly == false`, outside the 2 KiB summary budget, so cold reload renders the full card. A payload that is already a `summary_only` stub stays a summary: sessions saved before this repair cannot be recovered and keep the historical scalar card.
- **Escalated answers:** a question answered by the parent agent through `respond` renders the same way as one answered by the user.

## 5. Step 3 — Tool label, investigate first (issue 2)

**Investigation (do this before any code):**
- Capture one failing example: the exact raw `toolName` (without Markdown processing), the item kind, status, count, any persisted summary, and the view that renders it.
- Ask the user which screen showed `… • 1`, with a screenshot if possible.
- Record the renderer's path and symbol in the commit message.

**Fix, chosen by what the investigation finds:**
- **The renderer bypasses `toolDisplayName`:** route that composition boundary through `toolDisplayName(for:)` and keep the separately rendered status/count. Do not run regex replacement over already-composed or persisted text.
- **The raw name really is `mcp_RepoPromptCE_agent_run`:** add a private, display-only helper used exclusively by `toolDisplayName`. It matches only the exact server name (case-insensitively), then the single-underscore delimiter, then a suffix that is already in `repoPromptToolNames`. Retire the dead `mcp__RepoPrompt__` literal strip at the same time.
- **The count:** align `• 1` with the existing `×N` convention, or drop a count of 1.

**Guarantee that authorization does not broaden:**
- No edits to `stripExplicitRepoPromptPrefix`, `resolveRepoPromptToolName`, `repoPromptToolNames`, `normalizedToolCardName`, or any `isRepoPrompt…` predicate.
- Add regression tests pinning `canonicalRepoPromptToolName("mcp_repopromptce_agent_run") == nil` and `isRepoPromptToolNameWithServerPrefix(...) == false`, including lookalike server names and unknown suffixes.

If the surface cannot be reproduced, ship Steps 1, 2, and 4 and leave this step open with the findings recorded. Do not guess a fix.

## 6. Step 4 — Delegated `ask_user` escalates to the parent agent (issue 4)

### 6.1 Model

Each session's `ask_user` is addressed to whoever controls that session:

| Asking session | Audience | Behavior |
|---|---|---|
| Top-level session (not MCP-controlled) | User | Unchanged: reveal and take attention. |
| In-app child with a reconciled live parent (any depth) | Parent agent | No reveal. Deliver to the parent (§6.2). The child's timeout pauses (§6.4). |
| Session controlled by an external MCP client (no in-app parent) | External controller | Unchanged. |
| In-app child whose lineage is missing or inconsistent, or whose parent session no longer exists | User, as a fallback | No reveal; the child row shows "Needs your answer" and the normal timeout runs. Never guess a parent. |

How escalation works:
- The parent decides: answer through `agent_run respond`, or escalate by calling its own `ask_user`. That call is routed by this same table, so escalation is recursive: sub-worker → worker → main → user.
- No new escalation tool or protocol is introduced.
- Parent resolution reuses the reconciled-parent lookup `AgentModeViewModel` already supplies to `AgentDelegationPolicy`. There is no second lineage reader.
- A pure `AgentDelegatedQuestionAudience` policy next to `AgentDelegationPolicy` encodes the table. `.externalController` applies only when the child is verifiably controlled by a non-Agent-Mode connection.

### 6.2 Delivery to the parent agent, by parent state

A runtime-only notice record is keyed by `(childSessionID, interactionID)`:
- It holds the immediate parent session ID, `askedAt`, delivery stamps (the parent `runID` each delivery went to), and an acknowledgement flag.
- The child's `pendingAskUser` remains the only authority for question content, drafts, the continuation, and the timeout. Content is resolved fresh at each delivery.
- Reconcile synchronously on the main actor after the question is installed (once `pendingAskUser` and the continuation exist), on answer, skip, timeout, cancel, or remote resolution, on child teardown (`teardownMCPControl`) and close, and when the parent's run or identity changes.
- Repeated observations and draft edits are no-ops.

| Parent state when the child asks | Delivery |
|---|---|
| Blocked in `agent_run wait`/`wait_any` covering this child | **Existing path, unchanged.** The actionable snapshot returns immediately. Mark the notice acknowledged at the result handoff for that run. |
| Blocked in `agent_run wait` on *other* children, or in a bounded `ask_oracle` wait | **Wake early.** Wake every bounded wait scope owned by the parent's active run through the existing `wakeAgentRunWaitersOwnedByActiveRun` path, with a new, distinct reason (`delegatedQuestionPending`). The woken result carries the notice (§6.3). The parent learns within seconds instead of after up to 25 minutes (§6.6). |
| Running but not blocked in a wait (model sampling, or other tools) | **Next eligible tool result.** Attach the notice to the next RepoPrompt MCP tool result returned on the parent's run-scoped connection. Use an explicit allowlist of text-compatible results, excluding tools whose results the app parses structurally (`ask_user`, `apply_edits`, `agent_run` structured payloads unless the notice is carried in a dedicated field). Preserve original payloads and error flags. Revalidate the parent run and the pending interaction immediately before handoff. Cancellation must never silently consume a notice. |
| Idle or finished turn (owner decision 2) | **No automatic turn.** Show the parent banner and badge (§6.5). At the parent's next turn, started by the user for any reason, include the pending notices in that turn's first input as a labeled runtime notice block assembled by the message builder. It is not written into the user's message text. |

Rules that apply to every delivery:
- **Dedupe:** deliver once per `(childSessionID, interactionID, parentRunID)`. An acknowledged notice is never re-delivered to the same run. It may be re-delivered to a later run only if it is still pending and unacknowledged.
- **Persistence:** the delivered notice is persisted with the parent's tool result or turn input as a clearly labeled, ID-bearing note, so the transcript shows what the model saw. Live state stays authoritative in `pendingAskUser`, so a persisted note is never read as current state.
- **Never:** start a turn, interrupt a native tool, send a steering message, restart a provider, or bypass an approval to deliver a notice.

### 6.3 Notice content (point-of-need guidance, owner decision 5)

The notice includes the child session ID and name, the interaction ID, and the questions, with their context, options, and selection constraints as exposed by the child's MCP snapshot interaction. It never includes the user's unsubmitted drafts. The guidance text:

> Child session "<name>" (`<session_id>`) is waiting for your answer to an `ask_user` question (interaction `<interaction_id>`). Use your own judgment and the information you have to answer it with `agent_run respond`. If you cannot decide, ask your own controller with `ask_user`, then relay the answer. This notice is not a user answer or approval; confirm the interaction is still pending before responding.

The delegation system prompt and its audience table are unchanged.

### 6.4 Child timeout pauses while the question is with the parent chain (owner decision 3)

- When the audience is "parent agent", do not start the `ask_user` timeout. Clear `timeoutStartedAt` so the child card shows "Waiting on parent agent" instead of a countdown.
- If the audience later becomes "user as a fallback" (the parent session is closed or deleted, or its lineage becomes invalid), start a fresh timeout from that moment, using the existing generation-guarded `schedulePendingAskUserTimeout`.
- The question still resolves through the existing paths: the parent's `respond`, the user answering in the child tab, run cancellation, or teardown.
- An explicit `timeout_seconds` passed by the child is honored only once the fallback starts, because the owner chose to pause while the question is with the parent.
- An idle parent leaves the child waiting until the parent's next turn, the user answers in the child tab, or the run is cancelled. This is visible on both rows (§6.5).

### 6.5 Visibility without taking attention

These surfaces exist for legibility, never for focus. Escalated questions take the user's attention only through the top-level agent's own `ask_user`.

- **Parent conversation:** a banner (not a transcript item) with one row per pending child question, for example "Child agent '<title>' asked a question — delivered" / "— waiting for this agent's next turn". It has an **Open** action that selects the child tab after verifying the question is still pending. The action never answers anything.
- **Sidebar:** a badge on the parent row via `AgentModeSidebarSessionBuilder`, following the existing `mergeAttention` precedent and resolved by durable session ID, so index-only rows work too. The child row shows "Waiting on parent agent", or "Needs your answer" in the fallback case.
- **Unchanged:** the parent's `runState`, and `MCPAskUserToolProvider`'s reveal guard, which already matches owner decision 1.

### 6.6 Prompt-cache considerations (owner decision 6)

- **No reliance on wait timeouts.** A parent waiting on the asking child is woken immediately (existing behavior). A parent waiting elsewhere is woken early by §6.2. Delivery to a parent that is waiting never depends on a 1500-second wait running out, so the parent's next request stays well within a 30–60-minute cache TTL.
- **No extra paid turns.** An early wake only shortens a tool call the parent already made. It adds at most one follow-up model request (the parent re-issues its wait after handling the notice), which is a warm-cache read. Idle parents are never woken (owner decision 2).
- **Unavoidable cold-cache exposure.** While a question escalates to the user, the asking child — and every parent blocked in its own `ask_user` along the chain — sits inside a tool call until the user answers. If the user takes longer than the provider's TTL, those sessions resume cold. Fast routing and the top-level attention take keep this short. Keep-alives remain out of scope, as the [wait-efficiency plan](2026-09-13-agent-usage-and-wait-efficiency-plan.md) defers them.
- **Reason labeling.** The woken `agent_run` wait reports `interrupted_by_child_question`, not `interrupted_by_steering`, so the parent does not look for a steer that does not exist. The bounded `ask_oracle` wait returns its usual pending result with `_meta.wake_reason: "delegated_question"`. This extends the [Oracle resumable wait plan](2026-09-21-oracle-resumable-wait-plan.md) contract that `wake_reason` appears only for steering. Update that document's §3.2 wording, and verify that completion still wins over a wake (§3.6 of that plan).

### 6.7 Answer authority and races

- The child's `pendingAskUser` plus its continuation stay the single authority. The notice never resolves anything.
- The existing protections hold: `respond` rejects an interaction ID that no longer matches, and local resolution is first-wins and resumes once (§2). If the user answers in the child tab while the parent is responding, the parent gets the existing error and can see `lastInteractionResolution` in the next snapshot. Add tests for this; add no new mechanism.
- A notice that has not been delivered yet is cancelled when the question resolves. One that was already delivered cannot be retracted, which is why the identity check in `respond` is required.

### 6.8 Documentation

- [`agent-mcp-delegation-depth.md`](../agent-mcp-delegation-depth.md): replace the "Known limitations" pointer with a "Delegated questions" section. It covers the audience table, delivery by parent state, the paused timeout, unchanged authorization and depth ceilings, and the no-automatic-turn rule.
- [Oracle resumable wait plan](2026-09-21-oracle-resumable-wait-plan.md): the `wake_reason` extension (§6.6).

## 7. Validation

Run `make dev-test FILTER=<Suite>` for each focused suite. Suite names are proposals; extend an existing suite if one already owns the boundary. Then run the commit preflight as `AGENTS.md` requires.

- **Errors:** `ErrorExtensionsTests` covers:
  - both reported wrappers;
  - a nested wrapped `CustomOpenAIProviderError` (unchanged text);
  - `missingAPIKey` gives "Missing API key.";
  - blank descriptions and a non-`LocalizedError` enum both keep the fallback.

  `AIProviderRequestSizeFailureTests` covers positive and negative patterns, overflow, and a non-Codex domain. Add Oracle copy tests through an `internal` presenter, including the window line shown for `.exact`, omitted for non-exact, and omitted when the model is unknown. Live check: an oversized Codex Oracle request shows the reported character limit, and an unreported rejection shows no invented maximum. The input must be preserved in both cases.
- **`ask_user` card:** `AskUserQuestionPresentationTests` covers:
  - string and object options;
  - per-question context;
  - selected-option marking;
  - malformed optional fields;
  - historical scalar payloads rendering unchanged.

  `AgentToolResultPersistencePolicyTests/testCompletedAskUserExchangeSurvivesCanonicalSaveAndColdReload` covers canonical save, fresh-service cold reload, re-save, and a legacy stub staying summary-only.

  Manual check: a long multi-question exchange expands and collapses, stays selectable at narrow widths and large font sizes, and older sessions still render.
- **Label:** the investigation findings, `toolDisplayName` cases, and regression results for the unchanged canonical and prefix predicates. Rerun `AgentDelegationServiceBoundaryTests` and `PersistentAgentModeMCPReadFileConnectionTests`.
- **Delegated questions:**
  - `AgentDelegatedQuestionAudienceTests` truth table, covering the top-level, in-app child, external, and invalid-lineage rows.
  - View-model and MCP tests:
    - no reveal for an in-app child;
    - main → worker → sub-worker reaches only the immediate parent;
    - a parent waiting on the asking child gets the existing immediate result, and the notice is acknowledged with no duplicate;
    - a parent waiting on another child, or in a bounded `ask_oracle` wait, wakes early with `delegatedQuestionPending` and the notice;
    - a busy parent gets the notice on its next eligible result, and only once;
    - an idle parent gets zero provider starts, and the notice arrives in its next turn's first input;
    - the child timeout is not scheduled while the parent is the audience, and starts fresh on fallback;
    - escalation never resets drafts;
    - races between the user answering and the parent's `respond`, and stale interaction IDs;
    - teardown and close cleanup;
    - parent tab replacement.
  - Delegation suites stay green.
  - Live check on Claude Code and Codex parents:
    - main → worker; the worker asks; the main agent receives the notice while waiting on a different worker (early wake) and answers via `respond`;
    - repeat with a question the main agent cannot answer, so its own `ask_user` reveals to the user, and the answer flows back down;
    - an idle main agent gets no automatic turn, and the notice is delivered when the user next sends a message.
- **Docs:** run `Scripts/check-agent-context`.

## 8. Material disagreements and their resolution

### 8.1 How a busy parent agent finds out — converged in round 2; scope changed by the owner

- **The disagreement.** One lane initially proposed the steering queue. The other proposed attaching the notice to the next tool result.
- **Arguments.** Against steering:
  - a steer can appear as user-authored text;
  - on backends that queue steers as the next turn, it can start a paid turn;
  - its in-turn guarantees are unverified for each backend.

  Against attaching to tool results:
  - it mixes foreign content into tool data;
  - persisted results would carry the notice.
- **Resolution.** Both lanes converged on next-eligible-result attachment, which cannot start a turn by construction. The lanes had deferred it pending evidence. Owner decision 1 makes parent delivery the core of the feature, so it is in scope now (§6.2), together with the early wake of the parent's bounded waits, which owner decision 6 requires.
- **Persistence sub-point.** One lane would persist the notice; the other would strip it. The plan author chose to persist it as a labeled note (§6.2).

### 8.2 Automatically revealing a child's question to the user — resolved by the owner

- **Position A:** attention only; never reveal a child's question.
- **Position B:** reveal once when the parent cannot act.
- **Plan author's recommendation:** A. Revealing activates the app over other apps (`WindowState.swift:1636–1649`).
- **Owner decision 1** goes further than either position: a child's question goes to the parent *agent*, and only the top-level agent's `ask_user` takes the user's attention. Children never reveal. The current reveal guard already implements the top-level part.

### 8.3 Context-window line for "Prompt is too long" — resolved by the owner

- **Position A:** omit it. Exact metadata still does not identify the limit the provider enforced.
- **Position B:** include it as a separately labeled line, `.exact` metadata only, using the model captured with the request.
- **Plan author's recommendation:** B. The user asked for the maximum, and the failing chat path has no preflight.
- **Owner decision 4:** adopt B (§3.3).

### 8.4 Delegation system-prompt guidance — resolved by the owner

- **Position A:** no change now; prefer point-of-need text, and only on evidence.
- **Position B:** one scoped sentence for the `.agentRunOnly` and `.both` audiences.
- **Plan author's recommendation:** A.
- **Owner decision 5:** adopt A. Under the escalation model, the guidance travels in the delivered notice (§6.3), which is the point-of-need placement Position A preferred.

## 9. Minor points settled by the plan author

- **Formatter shape.** The lanes proposed (a) honoring any nonblank `LocalizedError` description, or (b) a layered approach: `AIProviderError` recursive unwrap, then `LocalizedError`, then an explicit `NSLocalizedDescriptionKey`. The plan uses (b), which is a superset of (a) and keeps wrapped OpenAI errors' existing friendly text. Both lanes agreed not to use Foundation's generic `localizedDescription`. A search confirmed that no test pins the old fallback text.
- **Classifier location.** The plan uses a pure type in `Infrastructure/AI` so it can be reused (for example by Context Builder), with the copy kept in Oracle. The speculative Anthropic token pattern ("N tokens > M maximum") is excluded because it isn't in the evidence.
- **Codex naming.** Both lanes converged: name Codex only when the `NSError` domain is `CodexAppServer`, and scope the history tip to the verified `CodexCLIProvider.buildPrompt` path.
- **Disclosure visibility.** The plan always shows the control on completed structured cards, instead of using a character-count heuristic. Truncation depends on width, so a heuristic could hide the control while the text is still clipped.
- **Label investigation leads.** The gateway PWA was proposed as a candidate surface, but its assets contain no `•`, so it is deprioritized.
- **Response races.** No new logic is needed; §6.7 covers it.
- **Distinct wake reason.** Both lanes had planned no new `WakeReason` while delivery was deferred. Once early wake became required (owner decision 6), the plan author added `delegatedQuestionPending`. Reusing `steeringRequested` would tell the parent a steer arrived when none did.

## 10. Deferred and out of scope

- A typed `AIProviderError.requestTooLarge(detail:limit:actual:)` populated at the wrap site. This needs that site identified and touches every exhaustive `switch`.
- A Codex character preflight, once the counted field and counting unit (graphemes, UTF-16, or bytes) are verified against the final assembled payload.
- Routing support for a single-underscore server prefix, only if a provider is found emitting it.
- Escalating approvals and elicitations through the same chain.
- Native Codex `spawn_agent` children.
- OS or audible notifications.
- Cache keep-alives while a question waits on the user.
