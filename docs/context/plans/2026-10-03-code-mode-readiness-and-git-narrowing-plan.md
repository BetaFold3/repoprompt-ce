# Code-mode readiness, RepoPrompt-owned code-mode executor, and Git surface narrowing plan

Scope: read when the task touches MCP `outputSchema`/`structuredContent` delivery, structured result projection for `read_file`/`file_search`/`get_code_structure`/`get_file_tree`, a RepoPrompt-owned code-mode script executor (`code_mode`), nested tool dispatch from a script, the `git_review_snapshot` tool, or shell-aware narrowing of the `git` tool in Agent Mode runs.
Authority: Reference
Last-verified: 2026-10-04

Status: Planned, not implemented. No app source has changed for this plan. The Phase 0 offline analyzer exists locally (`Scripts/analyze_tool_usage.py` and its test file, uncommitted); live structured-content probes have not run. One material disagreement (§8.4, the executor's promotion gate) remains open; its recommendation is recorded but not silently adopted. 2026-10-04 additions: a corrected baseline that includes every Claude Code log root (§2.2), prior art from OpenCode v2 Code Mode (§2.3), and OpenCode capability facts (§4.1, §10).

Decision process: two independent Oracle lanes (OracleE `95F2BD07-4A94-417C-AAAF-17CAB847EC35` and OracleD `7F177418-1980-4BF5-9768-B278FBC7C2BB`; `model_selection: explicit` on the first round, `inherited` on continuations) received an identical brief carrying file:line evidence verified against the live checkout and six months of local usage measurements. Six material disagreements went to anonymous reciprocal challenge (each lane received the other's arguments, never its identity). Round 1: both lanes moved, and on P1–P3 they effectively swapped positions. Round 2: OracleD converged on all three; OracleE's round-2 send failed three times on an `oracle_browser_warning` (ChatGPT browser session), so the round-2 convergence is OracleD's acceptance of OracleE's round-1 positions, with compatible refinements adopted by the plan author. Minor points were settled by the plan author after checking the code (§8.6).

User decisions (2026-10-03):
1. Scope is code-mode readiness plus Git narrowing only. Pi provider work is out of scope (see `docs/context/plans/pi-provider-integration.md`).
2. Context Builder is being deprecated: it is not a target, receives no investment, and keeps its current behavior; it does not constrain the Git design.
3. Git: hide plain inspection only in runs that have a native shell; keep a narrow review-snapshot capability everywhere; keep the full Git surface for runs and clients without a shell.
4. The owner expects a RepoPrompt-owned code-mode executor in our own harness, phased and gated by measurement.
5. Knowledge sessions stay unchanged: no `git`, no `git_review_snapshot`, no executor.
6. The executor engine is vendored QuickJS-ng.
7. The executor is Agent Mode–only until its promotion gate passes; no external-client enrollment.

## 1. Goal

Make RepoPrompt's highest-volume tools composable by scripts and cheaper for models, and remove redundant tool surface where the agent already has a shell:

- **D1 Structured results.** Ship spec-standard `outputSchema` + `structuredContent` for the exploration tools, default off, enabled only where evidence shows it helps.
- **D2 Git narrowing.** Add `git_review_snapshot`; restrict the full `git` tool only in runs proven to have a native shell.
- **D3 Owned executor.** Add an experimental `code_mode` MCP tool that runs a bounded QuickJS script calling the read-only exploration tools through the existing dispatch authority.
- **D4 Measurement.** Baseline from local logs, then a controlled A/B/C experiment that decides whether the executor leaves experimental status.

Non-goals: Pi provider integration; Context Builder changes; Knowledge policy changes; external-client executor enrollment; persistent script state; edits, selection management, Git, Oracle, or delegation inside scripts.

## 2. Evidence

### 2.1 Verified repository facts

| Fact | Evidence |
|---|---|
| Successful window-tool calls return Markdown content only: `CallTool.Result(content: contentBlocks, isError: false)`. | `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:13102-13103` |
| No server code produces `structuredContent` or `outputSchema`; they appear only in result readers. | `AgentTranscriptServices.swift:365`, `ToolJSON.swift:9`, `RepoPromptGateway/Wire/RemoteWireMCPBridge.swift:33` |
| The pinned SDK already supports both fields. | `.build/checkouts/swift-sdk/Sources/MCP/Server/Tools.swift:23` (`Tool.outputSchema`), `:407` (`CallTool.Result.structuredContent`) |
| Typed DTOs exist and are encoded to `Value` before formatting. | `Sources/RepoPromptAgentCore/MCP/ToolResultDTOs.swift:107-159` (`SearchResultDTO`), `:246` (`FileTreeDTO`), `:282` (`CodeStructureReplyDTO`), `:731` (`ReadFileReply`), `:2115` (`GitToolReplyDTO`); `Tool.swift:31-46` |
| Hidden `_rawJSON` returns compact JSON text. | `MCPToolArgsNormalizer.swift:161-163,203-205`; `ToolOutputFormatter.swift:977-1021` |
| Custom client capabilities must be strings; non-string experimental entries are stripped at the socket boundary. | `MCPInitializeCompatibility.swift:22-24`; `docs/context/workflows/development.md:87-96` |
| Connection lanes are independent `AsyncLimiter`s; there is no cross-lane drain. | `MCPConnectionManager.swift:1535-1545`, `:1821-1836` |
| `.exclusive` additionally takes a per-window/app-wide mutation lease (limit 1); `.smallRead` takes a per-window small-read lease (limit 2). | `MCPConnectionManager.swift:1852-1857`, `:12270-12320` |
| Admission caps: small reads 2 per connection and 2 per window; searches 4 per connection; Git 2 per connection + 1 per repository; exclusive 1; control 8. | `Policies/MCPToolAdmissionPolicy.swift:32-38,52` |
| Every advertised tool needs an execution contract and an admission class; both tables are closed. | `Policies/MCPToolExecutionContract.swift:59-105`; `MCPToolAdmissionPolicy.swift:40-71` |
| Only `.bounded` contracts get the server-side deadline/watchdog; `.longSynchronousCancellable` and the other cancellable kinds run unbounded. | `MCPConnectionManager.swift:12743-12747` |
| Agent Mode `read_file` and eligible content searches enqueue automatic selection mutations. | `ViewModels/MCPReadFileAutoSelectionCoordinator.swift:3-8` |
| `git` is one tool with `op` + `artifacts`; artifact publication auto-selects review artifacts and Oracle review mode requires them. | `WindowTools/MCPGitToolProvider.swift:331-372,436-447,537,695-747` |
| Shell availability is a per-run fact. Claude Agent Mode keeps Bash unless the preference is off or the profile is `.mcpSafeDefaults`; Knowledge and discovery runs disallow Bash. | `ClaudeControllerLaunchPolicy.swift:5-25`; `ClaudeCodeIntegrationConfiguration.swift:47-67,75-76,108-109,155-176` |
| Knowledge's positive tool ceiling excludes `git`. | `Features/AgentMode/Runtime/AgentSessionProfile.swift:16-27` |
| Run restrictions are unioned into `restrictedTools` and enforced at both `tools/list` and `tools/call`. | `Features/AgentMode/Runtime/AgentModeRunLease.swift:14-24`; `MCPConnectionManager.swift:11395-11420` |
| Default-off per-feature Agent Mode settings have a precedent. | `AppSettingsMCPService.swift:926` (`agent_mode.codex_computer_use_enabled`) |

### 2.2 Measured usage (this machine, 2026-04-03 to 2026-10-04)

Source: `Scripts/analyze_tool_usage.py` (Phase 0 analyzer) over native Codex logs (`~/.codex/sessions`, `~/.codex/archived_sessions`) and **every** Claude Code log root (`~/.claude/projects` plus each `~/.claude-rotator/profiles/*/projects`; the analyzer's default reads only the first, which missed 393 of 978 Claude files, so pass every root explicitly with repeated `--claude-root`). Aggregates only; calls are deduplicated by provider and call ID; tokens ≈ characters ÷ 4 is an estimate, not billed tokens. 978 Claude and 3,488 Codex files; 0 malformed, oversized or unmatched outputs. The first draft of this section came from an unreviewed prototype that missed the profile roots and counted replayed outputs; the analyzer reproduces that prototype exactly on the same inputs, and the differences are fully explained in the local report (deduplicating 1,215 replayed outputs and serializing Unicode without escapes, −1.87% characters).

| Tool | Calls (Codex + Claude) | Share of all tool output | Median / p90 / p99 chars |
|---|---:|---:|---|
| `read_file` | 21,379 (13,598 + 7,781) | 27.3% | 3.9k / 15.1k / 53.7k |
| Native shell (Codex `exec_command` / Claude `Bash`) | 18,661 / 12,407 | 19.5% / 4.6% | 2.4k / 12.7k / 61k; 1.1k / 4.8k / 14.8k |
| `file_search` | 7,970 (5,559 + 2,411) | 10.7% | 2.7k / 22.2k / 47.4k |
| Codex `exec` (client-native code mode) | 1,958 | 3.3% | 2.1k / 40.0k / 40.2k |
| `git` | 1,959 (1,673 + 286) | 0.9% | 0.6k / 6.1k / 27.8k |
| `get_code_structure` | 651 | 0.9% | 2.2k / 21.3k / 23.6k |

Total measured tool output is 548M characters; native image and PDF reads inflate the denominator (Claude `Read` 17.1%, Codex `view_image` 9.8%).

| Per provider | Codex | Claude Code |
|---|---:|---:|
| User turns that used RepoPrompt (of all observed turns) | 1,264 of 5,946 | 988 of 2,235 |
| RepoPrompt calls per such turn, median / p90 | 17 / 49 | 11 / 48 |
| Turns with ≥3 direct exploration calls (composition opportunities) | 1,073 | 612 |
| Exploration chain length, median / p90 | 3 / 19 | 2 / 6 |
| `read_file` calls with a line range | 71.0% | 73.6% |
| `read_file` calls that re-read a path already read in the session | 42.5% (34.0M chars) | 50.1% (23.7M chars) |
| Reads whose path appeared in an earlier same-turn search/structure/tree output (lower bound) | 9.3% | 4.8% |
| `file_search` outputs flagged truncated (heuristic) | 20.5% | 10.3% |
| Multi-call assistant batches (native parallelism) | 9,558 | 5,655 |
| RepoPrompt `git` calls / with `artifacts=true` | 1,673 / 67 | 286 / 65 |
| Shell Git inspection commands (status/diff/show/log/blame) | 2,269 | 2,202 |

- RepoPrompt tools produced 44.1% of all tool output; the four exploration tools produced 88.7% of RepoPrompt's output.
- Codex `exec` scripts: 1,452 of 1,958 lexically call RepoPrompt tools (2,271 nested call sites, a static estimate; nested results are not logged separately); 513 use `Promise.all`; 361 contain more than one tool call site.
- RepoPrompt `git` is overwhelmingly plain inspection, while the shell already carries more Git inspection than the tool does in both clients. Artifact publication is 4% of Codex `git` calls but 23% of Claude's, so `git_review_snapshot` matters most for Claude runs.
- **Correction to the first draft:** Claude Code, which has no native code mode and is the executor's intended cohort, is a heavy RepoPrompt user here (18,367 RepoPrompt calls). The earlier claim that it "barely used RepoPrompt" came from the missing log roots.
- Re-reads are common (42–50% of reads repeat a path), but the measurement cannot tell whether the content changed or the re-read was avoidable. Search→read joins are low, so the composition win is more likely to come from filtering and summarising inside one script than from search-then-read chaining.
- Provider-reported tokens exist for 59% of Codex turns and 91% of Claude turns; they are not billing evidence and are not used as a baseline here.

### 2.3 Prior art: OpenCode v2 Code Mode (verified 2026-10-04)

Sources: `anomalyco/opencode` `packages/codemode/{README.md,codemode.md}`, `packages/opencode/src/tool/code-mode.ts` and `src/mcp/catalog.ts` on `dev` (release v1.18.34, 2026-09-30), and the v2 MCP docs page. The v2-branch core adapter (`packages/core/src/tool/{registry,execute}.ts`) is described in `codemode.md` but was not read directly.

| Aspect | OpenCode v2 | This plan | Consequence |
|---|---|---|---|
| Exposure | Default for every MCP server: tools are deferred behind one `execute` tool and grouped as `tools.<server>.<tool>`; `mcp.servers.<name>.codemode: false` exposes them directly. v1 ships it behind `OPENCODE_EXPERIMENTAL_CODE_MODE`. | Opt-in `code_mode` over four read-only tools, Agent Mode only. | OpenCode v2 is a *client-side* code-mode host for RepoPrompt, like Codex `exec` (§4.1, §10). |
| Engine | Owned tree-walking interpreter: TypeScript stripped, Acorn parse, no `eval`; a restricted subset (no classes, generators, timers, `.then` chaining, modules). | Vendored QuickJS-ng with no libc (owner decision 6). | Both give capability confinement, not process isolation. OpenCode trades full JavaScript for full control of the surface; QuickJS-ng gives full ES with engine-enforced heap, stack and interrupt limits, which this plan relies on. No change. |
| Results inside scripts | Uses `structuredContent` when present; otherwise text blocks joined as a string; never parses text as JSON (an explicit non-goal). `outputSchema` becomes the generated TypeScript signature; without one a tool is `Promise<unknown>`. | D1 adds `outputSchema` + `structuredContent`. | Today OpenCode scripts receive RepoPrompt results as Markdown strings typed `unknown`. D1 directly improves a shipping client, which strengthens D1 independently of D3. |
| Nested authority | `dev`: each child runs plugin `tool.execute.before/after` hooks and a per-tool permission `ask`. v2 core: leaf tools own authorization; nested calls reuse the outer invocation context and skip registry hooks; "catalog visibility is not execution authorization". | Every child runs the full policy, restriction, admission, contract and observer path (§5.1). | This plan is deliberately stricter, because RepoPrompt is the server and enforces run leases itself. No change. |
| Output bounding | Only the outer `execute` result is bounded; child results stay complete inside the program. | 2 MiB per imported child, 16 MiB cumulative, 32 KiB final output. | Same principle (bound the model-facing result, not intermediates), with memory caps added for an in-process engine. No change. |
| Limits | The library sets no defaults (`timeoutMs`, `maxToolCalls`, `maxOutputBytes` are host policy); fixed 8 concurrent calls and 32 nesting levels; OpenCode core sets no timeout or call limit and relies on user cancellation. | Fixed limits (§5.1), 4 concurrent children. | A server-hosted engine cannot rely on a client's cancel button, so fixed limits stay. |
| Discovery | Token-budgeted catalog (default 2,000 estimated tokens), round-robin across namespaces, plus `tools.$codemode.search`. | Four allowlisted tools, always listed. | Not needed at four tools; revisit only if the allowlist grows. |
| Claimed benefit | Release notes: fewer tokens and round trips. The widely cited 177,444 → 13,274-token result measured the *first request* of a session with a 97-tool MCP server, i.e. tool-definition overhead. | RepoPrompt's burden is tool *results* (§2.2), not definitions. | OpenCode's headline saving does not transfer; it is not evidence for D3. §6 still has to measure result-volume and round-trip effects directly. |
| Maturity signals | Open issue #51849: v2.0.18 code mode reports `Unknown tool` for connected stdio servers, while `codemode: false` works. Issue #45349 (`search` missing at runtime) was closed as not planned. | — | If RepoPrompt runs OpenCode v2 in code mode, RepoPrompt tools inherit these failure modes. |

## 3. D1 — Structured results

### 3.1 Settled design

- **Tools first:** `read_file`, `file_search`, `get_code_structure`, `get_file_tree`; `git_review_snapshot` and `code_mode` get schemas when they land. Legacy `git` gets no schema in this plan.
- **Modes:** `MCPResultDeliveryMode` = `legacy` (no `outputSchema`, no `structuredContent`; today's bytes) or `structuredCompact` (`outputSchema` + `structuredContent` + a summary text of ≤512 UTF-8 bytes with counts, ranges, truncation and warnings). Add `structuredFull` (today's text plus `structuredContent`, no token change) only if a probe shows a client forwards `structuredContent` to scripts but not to the model.
- **Enablement authority (precedence, resolved once per connection, never persisted):**
  1. Lease override: `MCPBootstrapLeaseSpec.agentMode(..., resultDelivery:)` set from a default-off per-provider `app_settings` key (e.g. `agent_mode.structured_results.<provider>`), flipped by a person after reading Phase 0 probe evidence. Not version-gated, so experiment arms stay reproducible across CLI releases.
  2. Probe-backed profile table keyed by handshake client identity and tested version (`auto`). It ships empty and gains rows only from Phase 0 probe artifacts; untested versions fall back to legacy. Identity selects presentation, never permissions.
  3. Legacy.
- **No per-call `_structured` argument** (model-controlled, with effects the model cannot observe). No custom initialize capability (no real client sends one, and object values are stripped).
- **`_rawJSON`:** on legacy connections unchanged; on schema-advertised connections it keeps its exact compact-JSON text and also carries `structuredContent`, because an advertised `outputSchema` is a conformance promise.
- **Schema source of truth:** hand-written schemas in a new `Sources/RepoPrompt/Infrastructure/MCP/MCPToolOutputSchemas.swift`, matching existing `CodingKeys` and optional/omitted fields, permitting additive properties, and covering truncation, omission counts, retry metadata and `worktree_scope`. A parity test encodes fixture DTOs and checks key sets and primitive types against the schema. No reflection or generator.
- **Errors:** thrown/contract errors keep `isError: true` and their existing text. DTO-embedded soft errors keep today's `isError` semantics and stay inside `structuredContent`.
- **Notices:** `structuredContent` carries the unannotated result; delegated-question notices still append once as text (`AgentDelegatedQuestionNoticeWire.splitting`).
- **Projection site:** one synchronous `makeToolResult(toolName:args:value:mode:)` used by the success exit (`MCPConnectionManager.swift:13102`) and by the error helpers (`:1257-1285`), after `delivery.settle`. Observers still receive the unannotated value.

### 3.2 Changes

- `Tool.swift`: optional `outputSchema: Value?` on both initializers; `MCPWindowToolRuntime.tool(...)`: pass-through.
- New `MCPToolOutputSchemas.swift`, new `MCPStructuredToolResults.swift` (mode resolution, summary lines, projection).
- `MCPConnectionManager.swift`: per-connection mode resolution at policy install; `tools/list` sets `MCP.Tool.outputSchema` only for structured connections (separate output-schema cache; not passed through input-schema projection); all result exits go through `makeToolResult`.
- `AgentModeRunLease.swift`: defaulted `resultDelivery` parameter; provider coordinators read the per-provider setting; `AppSettingsMCPService` registers the keys.
- Providers for the four tools pass their schema.

## 4. D2 — Git narrowing

### 4.1 Settled design

- **Separate tool, name-based restriction.** Add `git_review_snapshot` (`MCPWindowToolName.gitReviewSnapshot`) in `MCPGitToolProvider`. Op-level gating inside one `git` tool was rejected because it would add a second policy axis (op allowlists, op-dependent schemas and descriptions, execution-time op checks). Name restriction already fails closed in both `tools/list` and `tools/call`.
- **Snapshot behavior:** fixed `op = diff`, `artifacts = true`, `detail = summary`. Inputs: `compare`, `scope`, `mode`, `repo_root`, `repo_roots`, `repo_key`, `path`, `paths`, `context_lines`, `detect_renames`, with today's defaults and validation. `op`, `artifacts`, `detail`, `inline`, `ref`, `count` and `lines` are rejected by schema and at runtime. It returns `GitToolReplyDTO` through the existing publication, auto-selection, advertisement and cleanup path. It never dispatches a nested call to `git`.
- **Shared implementation:** refactor the git entry path to take an invocation kind (`full` / `reviewSnapshot`) that supplies the real canonical tool name to the hard-coded authorization identities (`replaceAdvertisedGitArtifactsForCurrentTab`, `invalidateAdvertisedGitArtifactsForCurrentTab`, tab-context resolution, and readiness helpers).
- **Classification:** admission `.gitRead` (shares connection and per-repository limits with `git`); contract `.workspaceLifecycleCancellable`; annotations local, non-destructive, `readOnlyHint: false` (it writes snapshot files and selection).
- **Shell signal:** new `AgentRunToolCapabilities` (`nativeShell`, `nativeCodeMode`, each `available | unavailable | unknown`), computed from the final launch configuration after profile, permission and native-tool decisions. `MCPBootstrapLeaseSpec.agentMode` takes a defaulted capabilities value and unions `git` into `restrictedTools` only when `nativeShell == .available`. The MCP layer never learns about shells; the `ConnectionPolicyInstaller` signature does not change.

| Launch | `nativeShell` | Result |
|---|---|---|
| Claude with Bash enabled | available | `git` hidden; snapshot available |
| Claude with Bash off or `.mcpSafeDefaults` | unavailable | full `git` |
| Codex Agent Mode | available (unknown if a configuration disables its shell) | `git` hidden |
| OMP (`--no-tools`) | unavailable | full `git` |
| OpenCode managed interactive mode (`bash: allow`, `OpenCodeIntegrationConfiguration.swift:293-295`) | available | `git` hidden; snapshot available |
| OpenCode headless / no-tools modes (`bash` denied, `:321-328`) | unavailable | full `git` |
| Cursor | unknown until proven | full `git` |
| Context Builder discovery | unavailable | unchanged full `git` |
| Knowledge | n/a | unchanged: neither tool (owner decision) |
| External clients without a lease | unknown | full `git` + snapshot |

- **Prompts and docs:** Oracle review guidance names `git_review_snapshot` first; shell-enabled prompts direct inspection to the shell; other prompts keep Git guidance. Legacy `git(artifacts: true)` stays for clients that still have `git`.
- **Rollback:** dropping the capability union restores today's surface; the additive snapshot tool stays.

## 5. D3 — RepoPrompt-owned executor (`code_mode`)

### 5.1 Settled design

- **Tool:** `code_mode` (window tool, `isEnabledByDefault: false`, policy-gated via `MCPPolicyGatedTools`, granted through `AgentModeMCPPolicyInstaller.additionalTools` only under an experiment setting, and only for Agent Mode runs whose `nativeCodeMode` is not `available`). Input: `script` (required string, async function body, ≤32 KiB). Annotation `.repoPromptLocalReadOnly` (allowlist is read-only and selection is suppressed).
- **Engine:** vendored QuickJS-ng as a C target (`Sources/CQuickJS`, license under the repository's third-party license location), excluding `quickjs-libc` (no `std`/`os`, so no filesystem, network or timers). One fresh runtime per invocation, owned by one dedicated thread; no QuickJS pointer crosses threads; Promise jobs are pumped on that thread; an interrupt handler checks an atomic deadline/cancel flag.
- **Guest API:** frozen `tools.<name>(args)` for the allowlist ∩ tools visible to this connection; each call resolves to the full normalized envelope (`content`, `structuredContent`, `isError`); dispatch/protocol failures reject. No console accumulation, module loading or persistent store.
- **Allowlist:** `read_file`, `file_search`, `get_code_structure`, `get_file_tree`. The bridge positively admits only tools classified `.smallRead` or `.fileSearch`; unknown or reclassified tools fail closed, protected by a focused test. Git, snapshot, edits, selection, Oracle, delegation and recursion are excluded.
- **Limits:** heap 64 MiB; stack 512 KiB; guest CPU 2 s (excluding tool waits); wall 60 s; ≤32 child-call attempts; ≤4 children dispatching concurrently; ≤2 MiB per imported child result (oversize returns an explicit bridge failure, never byte truncation); ≤16 MiB cumulative; final output ≤32 KiB serialized JSON; cancellation cleanup grace 2 s. Reject cycles, unsupported types, non-finite numbers and nesting beyond 64.
- **Dispatch authority (P2 converged):** retain the per-connection callable already registered with the SDK `CallTool` handler in a registry entry removed on disconnect, and invoke that same callable for children. No extraction of the handler body, no copied handler, no socket loopback.
  - `@TaskLocal currentToolCallOrigin`: default `.transport` (set at SDK entry); `.codeMode(parentInvocationID, ordinal)` set only by the bridge; not wire-constructible.
  - Trusted context carries the parent's validated run/tab/worktree identity and binding generation. Children reject `context_id`, `_tabID`, `_windowID`/`window_id` and aliases (`code_mode_routing_override_rejected`), revalidate the pinned binding before each child, and fail with `code_mode_binding_changed` rather than falling back to the active tab.
  - A typed result sink receives the unannotated settled `Value` exactly once at the success settle site; denials and errors are read from the real `CallTool.Result` envelope.
  - Every child gets its own invocation ID and delivery transaction and runs the full policy, restriction, ceiling, admission, freshness, contract, observer and cancellation path. Children are child tasks, never detached tasks.
  - Before any nesting, land the task-locals and nil parent metadata and prove unchanged transport behavior.
- **Admission (P3 converged):** `code_mode` is classified `.control`; no new lane (lanes are independent, so a parent in `.control` cannot block children in `.smallRead`/`.fileSearch`). Script capacity (1 per connection, 2 process-wide, non-queuing `retryable` rejection) is declared in `MCPToolAdmissionPolicy` beside the classification and acquired in the manager's admission step, shaped like the exclusive mutation lease, never in the provider or bridge. Parent and children count in `admittedCallCount`. Measure control-slot contention before considering a dedicated lane.
- **Execution contract:** `.bounded(deadline: 62 s, cancellationGrace: 2 s)`, which puts the existing server-side watchdog behind the runner's own 60 s deadline. Children keep their own contracts and inherit the parent's cancellation.
- **Selection:** trusted origin `.codeMode` suppresses automatic selection at the shared enqueue boundary used by reads and eligible searches. Direct calls are unchanged. The tool description tells callers to select shortlisted material explicitly afterwards.
- **Delegated-question notices (P6 converged):** children settle with `handOff: false` (strip and release). The parent runs the existing notice attachment/reservation step after its children finish and commits eligible notices once, outside the script output. No reservation-transfer API. Inspect the attachment timing first; add a hook only if it is too early.
- **Partial failure:** handled child errors are visible to the script; an uncaught error, timeout, memory limit, cancellation, or return while children are outstanding stops new children, cancels queued/running ones through the shared path, and returns `isError: true` with bounded diagnostics and counts (`calls_started`, `calls_completed`, `calls_failed`). Completed reads are not undone. Success returns `CodeModeReplyDTO { output, calls_started, calls_completed, calls_failed }`.
- **Visibility:** completion observers gain optional `parentInvocationID` and `childOrdinal` (persisted tracking fields optional and absent-decodes-to-nil). The first experiment renders children as flat cards badged "via code_mode"; a grouped parent card follows only if the experiment continues.

## 6. D4 — Measurement

- **Offline analyzer (exists locally, uncommitted):** `Scripts/analyze_tool_usage.py` (standard library only, streaming, SQLite-on-disk percentiles and deduplication; precedent `Scripts/analyze_claude_raw_events.py`) and `Scripts/test_analyze_tool_usage.py` (17 synthetic-fixture tests). It reports metrics a–k: per-tool, per-provider and per-month sizes in characters and UTF-8 bytes; RepoPrompt and exploration share; per-turn calls and composition opportunities; search→read joins; read ranges and re-reads; search truncation; parallelism; Codex `exec` script statistics; RepoPrompt Git ops versus shell Git; provider-reported tokens; and coverage. Characters ÷ 4 is labelled an estimate. Only aggregate output is kept, locally, never committed. Run it with every Claude log root (§2.2).
- **Baseline gate (amended 2026-10-04):** the analyzer must reproduce the reference prototype's aggregates exactly on the same inputs and fully decompose every canonical difference. This replaces "reproduce §2.2 within ±2%": the canonical analyzer deliberately corrects replayed-output and Unicode accounting, so some per-metric deltas exceed 2% for explained reasons. Status: met. Invocation counts for `read_file`, `file_search`, `git` and `exec` agree within 0.3%, total characters are −1.87% with an exact decomposition, and two independent runs produced identical JSON.
- **Structured-content probe:** a debug-only server switch puts distinct sentinels in `structuredContent` and in text for `read_file`; live runs per client/version record which sentinel reaches the model and which reaches native scripts. Results fill the profile table and decide whether `structuredFull` is needed. Clients: Codex (`exec`), Claude Code, and OpenCode v2 when available. From source, OpenCode's code mode hands `structuredContent` to scripts in preference to text (§2.3); the probe confirms this live and records what its direct (`codemode: false`) path shows the model.
- **D1 gate per client:** model-visible payload plus schema overhead ≤ legacy +5% on the probe corpus, and no garbled or duplicated results; otherwise that client stays legacy.
- **Executor experiment (agreed design):** 12 fixed, diverse exploration tasks × ≥5 paired, randomized and interleaved repetitions × three arms on Claude Code Agent Mode: A (legacy, no executor), B (structured, no executor), C (structured + `code_mode`). C vs B isolates the executor; B vs A measures D1. Reset source, selection and routing per run; hold Git policy and model settings fixed. Count wrapper output, shell substitutions, retries and natural failures; exclude deliberate fault-injection runs from performance samples. Adoption is measured against predefined multi-tool opportunities, not treatment-observed counts.
- **Agreed gate components:** zero policy, routing, selection, delivery or sandbox violations; success ≥95% and ≤5 points below B, with a calibration precondition that A and B themselves reach ≥95% on the chosen tasks, and no task where C fails every repetition while B passes every repetition; median and p90 wall time ≤ B +15%; adoption ≥30% of predefined opportunities; natural executor failure ≤10% per invocation; ≤600 tokens of added surface; missing token observations block any cost claim.
- **Disputed component:** the token criterion (§8.4).

## 7. Phases

| Phase | Goal | Key changes | Validation | Exit gate |
|---|---|---|---|---|
| 0 Baseline and probes | Reproducible numbers; know what clients forward | Analyzer + fixtures + test target (done locally, uncommitted); probe switch; this plan's evidence notes | Analyzer fixture tests (17 pass); `Scripts/check-agent-context`; `Scripts/test-check-agent-context`; `make guardrails` (passed); live probes (Codex, Claude Code, OpenCode v2) | Amended baseline gate met (§6); probe results recorded per client/version (pending) |
| 1 Structured results (D1) | Opt-in structured delivery | `Tool.outputSchema`, schemas, delivery mode, `makeToolResult`, lease field, settings | `make dev-lint`; focused `MCPStructuredOutputTests` (modes, `_rawJSON`, errors, truncation, `worktree_scope`, notices, every result exit); `make dev-swift-build PRODUCT=RepoPrompt` and `PRODUCT=repoprompt-mcp`; live check with the setting on | Legacy output byte-identical; per-client D1 gate |
| 2 Git narrowing (D2) | Snapshot tool, then shell-aware restriction | Snapshot tool + shared invocation kind first; then capabilities, lease union, prompts | `MCPGitSurfaceTests` (denial direct and aliased, invalid snapshot args, multi-root/worktree, shared admission, publication failure, cancellation); `AgentRunToolCapabilitiesTests`; existing artifact/Oracle suites; live Oracle review from shell and no-shell runs | Capability matrix passes; Oracle review works in both |
| 3 Dispatch seam | Nested re-entry with no transport change | Callable registry, origin task-local, typed sink, nil parent metadata | All MCP suites; unfiltered `make dev-test-parallel` | Unchanged transport payloads, routing, errors, cancellation |
| 4 Executor (experimental) | `code_mode` behind experiment grant | QuickJS-ng target, runtime, bridge, capacity admission, selection suppression, notice timing, flat child cards | `MCPCodeModeRuntimeTests` (globals absent, infinite and microtask loops interrupted, memory and recursion limits, output caps, cancellation); `MCPCodeModeTests` (restricted/ceiling denials, routing overrides rejected, binding change fails, 20 nested reads leave selection unchanged while direct controls enqueue, notice exactly-once, positive class check); both builds; `make guardrails` | Zero bypasses, deadlocks, leaked permits, premature notice commits, unsafe teardown; engine interruption must work or the phase stops |
| 5 Experiment and decision | Numbers | Run §6 protocol; record results here | Analyzer + in-app counters | §6 gate plus the §8.4 resolution |
| 6 Promotion (conditional) | Default-on where proven | Grant default, grouped cards, docs | Focused suites per change; `make dev-test-parallel` | Owner sign-off |

Throughout: never weaken assertions or regenerate the curated XCTest ledger; add surgical ledger rows for new suites; contribution evidence is an unfiltered `make dev-test-parallel`.

## 8. Material disagreements and resolutions

### 8.1 P1 — Structured-output enablement authority (converged)

One lane first proposed an initialize-time capability (`capabilities.experimental[...]`); the other proposed a probe-filled client-identity table plus a per-call `_structured` argument. Round 1: the capability was dropped (no real client sends it, and the pinned SDK path strips non-string values, `MCPInitializeCompatibility.swift:22-24`), and `_structured` was dropped as model-controlled. Round 2 converged on: lease override from a default-off per-provider setting (not version-gated, for reproducible experiment arms) > version-pinned probe table (`auto`) > legacy. `_rawJSON` on schema-advertised connections carries both representations. Resolution: §3.1.

### 8.2 P2 — Nested dispatch authority (converged)

The choice was a mechanical extraction of the ~1,700-line `tools/call` closure into a transport-neutral dispatcher versus re-entering the registered handler. Both lanes switched sides in round 1. In round 2, retaining and re-entering the same registered callable won: transport behavior is unchanged by construction instead of by review of a very large move, and a non-wire-constructible task-local is as tamper-proof as a parameter (the existing `$currentToolResultDelivery` and `currentConnectionID` precedent). The extraction side's safeguards were kept: explicit trusted context with pinned routing and binding generation, rejected routing overrides, per-child invocation IDs, and real error envelopes. Resolution: §5.1.

### 8.3 P3 — Executor admission (converged after source verification)

One lane proposed a new `.codeMode` orchestration lane on the premise that exclusive calls wait for other lanes to drain. The plan author verified that lanes are independent limiters and found no such drain (§2.1). Both lanes then accepted `.control` plus a positive child-class check. The round-2 refinement was adopted: script capacity is declared in `MCPToolAdmissionPolicy` and acquired in the manager's admission step, so the admission table stays the single concurrency authority. A dedicated lane is deferred until control-slot contention is measured. The plan author added the `.bounded` contract, because only bounded contracts get the server watchdog (`MCPConnectionManager.swift:12743-12747`). Resolution: §5.1.

### 8.4 P5 — Executor promotion gate: token criterion (OPEN)

The experiment design and most gate components converged (§6). The token criterion did not:

- **Position A (latest from the lane that kept the larger reductions as gates):** gate on ≥25% less model-visible tool-result volume and ≥20% fewer round trips, with median reported total tokens required **not to increase**. Rationale: the executor's value includes fewer model turns and less context pressure, and a no-increase guard prevents shipping a cost regression without requiring a large billed saving from a 12-task sample.
- **Position B (latest from the other lane, round 2):** median provider-reported total tokens must be **≥15% lower**, C vs B, paired by task, and lower in ≥10 of 12 tasks (a sign-test floor replacing a bootstrap CI at this sample size); volume and round trips are reported, not gated. Rationale: cost/latency is the executor's sole justification, and the owner's "gated by measurement" requires proof of benefit, not just absence of harm; bytes and round trips can fall while billed tokens or quality regress.
- The lane holding Position A could not answer round 2 (three `oracle_browser_warning` failures), so Position A is its round-1 statement.

**Recommendation (plan author):** a two-tier gate. *Promote beyond experimental* only if tokens are ≥15% lower (≥10 of 12 tasks lower), **or** if tokens do not increase and median wall time is ≥20% lower (the round-trip benefit Position A values, measured where the user feels it). *Remain experimental* if tokens do not increase but neither benefit threshold is met. *Withdraw* if tokens increase. Volume and round trips stay reported diagnostics. This keeps Position B's proof-of-benefit requirement while accepting latency as a benefit. Not adopted until the owner decides.

### 8.5 P6 — Notices produced during nested calls (converged)

Transferring child notice reservations into the parent transaction was rejected as unnecessary machinery. Children settle with `handOff: false`, and the parent's existing reservation step runs after its children finish. The contract test: a notice becomes pending during a child, the script returns an unrelated constant, no further tool call occurs, and the parent result carries the notice exactly once (plus cancellation and competing-transport cases). Resolution: §5.1.

### 8.6 Minor points settled by the plan author

- P4 (Knowledge grants) was closed by the owner: unchanged.
- Executor allowlist excludes `git` (it is `.gitRead` and `artifacts` mutates the tab); this also removes a legacy-`git` schema from D1's scope.
- Tool names `code_mode` (matches the owner's and Pi's terminology) and `git_review_snapshot`; both renameable before Phase 2/4 lands.
- Limits use the tighter set from §5.1 (32 child calls, 512 KiB stack, 32 KiB output, 2 s guest CPU).
- `.bounded` execution contract for `code_mode` instead of `.longSynchronousCancellable`.
- Flat child cards first; grouped parent cards only on promotion.
- Measurement evidence stays local and aggregate-only; it is never committed (consistent with the `docs/investigations` rule in `AGENTS.md`).

## 9. Risks

- **Beneficiary population (revised 2026-10-04):** Claude Code, the executor's cohort, is a substantial RepoPrompt user on this machine (988 RepoPrompt turns, median 11 and p90 48 RepoPrompt calls per turn, 612 composition opportunities). It already batches calls natively (5,655 multi-call batches), so the executor's gain must come from filtering and chaining rather than parallelism. Codex and OpenCode v2 have client-side code mode and stay outside the cohort. The experiment may still legitimately end in "remain experimental".
- **OpenCode v2 default code mode:** RepoPrompt's ephemeral OpenCode overlay registers the RepoPrompt server without a `codemode` key (`OpenCodeIntegrationConfiguration.swift:32-41,117-128`). Under OpenCode v2 that silently moves every RepoPrompt tool behind OpenCode's `execute`, inheriting its known defects (§2.3) and changing what the model sees. The locally installed OpenCode is 1.18.34 (v1), so this has not been observed yet.
- **Client handling of structured results:** clients may duplicate or ignore `structuredContent`; contained by default-off delivery and per-client probes.
- **Selection semantics:** suppressed nested selection means Oracle context must be selected explicitly after a script; the description must say so.
- **In-process engine:** QuickJS gives capability and resource isolation, not process isolation; the Phase 4 adversarial suite blocks integration on any interruption or cleanup failure.
- **Surface change for shell runs:** prompts must move to the shell and `git_review_snapshot` before narrowing is enabled; stale tool lists cannot bypass call-time denial.
- **Hydrated pre-change run policies** lack the new restriction until the next launch (harmless).

## 10. Open questions

1. **§8.4 token criterion for promoting `code_mode`** — choose Position A, Position B, or the recommended two-tier gate.
2. Approve the tool names `code_mode` and `git_review_snapshot`.
3. Cursor shell availability: keep `unknown` (full `git`) until verified? (OpenCode resolved from source: the managed interactive mode allows `bash`; headless and no-tools modes deny it.)
4. Accept the spec-SHOULD deviation of a ≤512-byte summary text instead of serialized JSON in `structuredCompact` mode?
5. Should a later phase enroll OMP (fixed `--no-tools` profile, no native code mode) in the executor experiment?
6. Phase 0 must confirm that Codex `exec` scripts and Claude Code actually receive `structuredContent`. From source, Pi and OpenCode code mode both pass it to scripts. Without that confirmation for Codex and Claude, D1 benefits only the owned executor and OpenCode.
7. **OpenCode v2 overlay policy:** when RepoPrompt launches OpenCode v2, should the overlay pin `codemode: false` for the RepoPrompt server (keep today's direct surface and avoid issue #51849), or accept OpenCode's default and set `nativeCodeMode = available`? Recommendation: pin `false` until an OpenCode v2 probe passes, then decide per version. Also confirm whether OpenCode v1 tolerates the `codemode` key before writing it unconditionally. This is a provider-integration change outside D1–D4 and needs the owner's call.
8. **Re-read volume:** 42–50% of `read_file` calls re-read a path already read in the session (58M characters combined). Is a separate investigation into read deduplication (for example unchanged-content markers) worth opening? It is out of scope here and may be a larger lever than D3.
