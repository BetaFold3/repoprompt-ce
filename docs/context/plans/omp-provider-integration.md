# Plan: Oh My Pi (OMP) as a Third ACP Provider — Managed Barebones Harness

Scope: read when the task touches Oh My Pi/OMP provider integration, `ACPProviderID`/`ACPAgentProvider` seam extension for OMP, `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/**`, or OMP Agent Mode wiring.
Authority: Authoritative
Last-verified: 2026-08-10

Status: **Implemented dark in the current worktree — release gates outstanding; public availability disabled**
Date: 2026-08-09
Provenance: an independent verification pass confirmed every load-bearing repository claim by direct reads and every upstream OMP claim against OMP source on `main` (can1357/oh-my-pi), then two independent Oracle plans (presets OracleB, OracleC) over a ~75k-token curated ACP-seam selection, one adversarial duel round on every material disagreement with referee-supplied source evidence, then synthesis. Preset identity (`model_preset_id`/`model_preset_name`) was verified on every send.


## Implementation checkpoint (dark, not release-ready)

The dark implementation is now present in this worktree: identity/seam sweeps, the fixed launch resolver/provider/normalizer, fresh-only interactive and headless ACP paths, dynamic model polling/registry/catalog/menu plumbing, OMP-specific binding and RepoPrompt MCP grant, strict recognition-scoped duplicate approval handling, and a labeled Settings diagnostic/model-cache surface. Public availability remains false; OMP is not selectable and is excluded from Context Builder's public agent schema, generic binding/subagent Settings rows, recommendations, and task-label surfaces. A runtime guard additionally rejects restored or MCP-configured `.ohMyPi` sessions before workspace lookup or provider/controller startup while the dark flag is false. Headless OMP waits for registered MCP routing before the first prompt; the bootstrap lease retains cleanup ownership.

Local Phase-0 evidence now includes a live, non-UI bootstrap using `Scripts/omp_acp_live_spike.py --phase bootstrap` against OMP `17.2.12` and the freshly built bundled `repoprompt-mcp` helper. The exact accepted launch is `omp acp --no-tools --no-extensions --no-skills --no-rules --approval-mode yolo`; the global help exposes every managed flag, the helper initializes as RepoPrompt CE `1.0.29` and lists 21 tools without invoking one, and OMP accepts protocol-v1 initialize/authenticate/session-new with the injected stdio server. The returned session has `mode`, `model`, and `thinking` config IDs plus delayed `available_commands_update`/`session_info_update` notifications; the disposable workspace retained only its read-only marker. This proves bounded bootstrap compatibility, not a full MCP tool round-trip or production expected-PID routing. In this build, `omp acp --help` proves only that the ACP subcommand exists, while the managed global flags appear in `omp --help`; preflight probes those separately.

The current direct prompt gate is blocked: a no-tool ACP `session/prompt` received no stream, tool, permission, or terminal event within 60 seconds, and a separately bounded bare OMP print-mode prompt under the same constrained profile timed out after 80 seconds. The later ACP response was `stopReason: cancelled` only when the harness closed the session. This establishes that the current OMP model/authentication path is not responsive enough for streaming or MCP-tool validation; it does **not** prove a RepoPrompt MCP, expected-PID, or OMP protocol defect. The optional round-trip harness is safety-enforced: it launches a fresh scratch workspace and exposes a synthetic proxy with exactly one read-only `get_file_tree` tool, snapshots the whole workspace before/after, and reaps its process group before writing evidence. It validates controlled OMP MCP transport once a model responds, not a production `repoprompt-mcp` tool call; the real helper is independently checked in the helper/bootstrap phases. The `"oh-my-pi"` value remains a provisional dark routing hint pending a real RepoPrompt MCP client-identity/PID capture. Still unproven—and therefore release-blocking—are the production RepoPrompt stdio MCP round-trip, poisoned-workspace isolation, yolo suppression on real tool calls, deny enforcement, OMP tool-event shapes/card recognition, at least a 10-minute MCP call, cross-process load with MCP re-registration, and authenticated prompt lifecycle/cancellation cleanup. Capability advertisement alone is not resume proof: the implementation always creates a fresh session, ignores any candidate resume ID, and uses transcript handoff. No HTTP contingency or shared ACP DTO was added because stdio bootstrap failure has not been demonstrated.

## 1. Goal

Add Oh My Pi as a third interactive ACP provider alongside OpenCode and Cursor, as a **managed barebones harness**: launch `omp acp --no-tools --no-extensions --no-skills --no-rules` plus a spike-confirmed approval-suppressing flag (`--approval-mode yolo` expected), inject the RepoPrompt MCP server through ACP `session/new` `mcpServers` as the **sole tool surface**, so users get OMP's broad model/auth ecosystem (Cursor Pro, OpenRouter, etc.) while RepoPrompt owns tools, context, and permissions. This is deliberately the opposite shape from the Pi native-RPC plan (`docs/context/plans/pi-provider-integration.md`): OMP rides the existing ACP seam; the two plans share only enum-sweep surfaces and must use distinct identifiers (`.ohMyPi` vs planned `.pi`).

## 2. Verified facts the plan rests on

Upstream OMP (source on `main`, verified 2026-08-09):

- `omp acp` is a first-party ACP server over stdio JSON-RPC (@agentclientprotocol/sdk). `initialize` advertises `loadSession:true`, `mcpCapabilities {http, sse}`, `promptCapabilities {embeddedContext, image}`, `sessionCapabilities {list, fork, resume, close}`.
- `#toMcpConfig` accepts **stdio** entries (`"command" in server`) plus http and sse — the advertised `mcpCapabilities` are the optional extended transports, not an exclusion of baseline stdio.
- ACP mode forces `enableMCP:false`: user global/project MCP config never loads; the ACP client is the exclusive MCP source.
- `--no-tools` sets `toolNames=[]` — an allowlist over **built-in tools only**. MCP tools bypass the allowlist entirely (name-dedup only) via `session.refreshMCPTools(manager.getTools())`. Under `--no-tools`, every tool call flows through injected MCP.
- `--no-extensions` sets `disableExtensionDiscovery=true`; `--no-skills` sets `skills=[]`; `--no-rules` sets `rules=[]`.
- configOptions advertises three selects: `mode`, `model` (`provider/model` IDs), and `thinking`. The local capture had thinking=`high` and options off/auto/minimal/low/medium/high; omission is intentionally not interpreted as auto.
- The acp-client-bridge always relays permission requests (`session/request_permission`); fs/terminal delegation happens only when the client advertises those capabilities.

Repository (verified by direct reads):

- `ACPProviderID` = {`openCode`, `cursor`}; the `ACPAgentProvider` protocol is the per-provider surface (support probe, launch config with `expectedExecutableIdentity`, session config with `mcpServers`, prompt blocks, normalization, error mapping).
- The shared `ACPAgentSessionController` owns lifecycle, JSON-RPC, `initialize` (advertises `fs.readTextFile:false`, `terminal:false`, no elicitation), `session/new|load` (serializes `mcpServers.map(\.acpJSONObject)` with `validateACPLaunchCommand` preflight), `session/request_permission`, cancellation, and modern configOptions (`session/set_config_option`, mode/model selectors, Cursor parameter selectors).
- **Cursor already injects RepoPrompt via `session/new` `mcpServers` in production** (`CursorACPAgentProvider.makeSessionConfiguration` returns `[repoPromptMCPConfiguration]`, `includeRepoPromptMCPServer` default true), stdio command-shaped. OpenCode instead uses the `OPENCODE_CONFIG_CONTENT` env overlay with `mcpServers: []`.
- `ACPDefaultSessionUpdateNormalizer` handles standard events; both existing providers delegate to it. `AgentACPModelRegistry` is keyed by `ACPProviderID` with `ACPDynamicModelStore` persistence; a new case flows through without registry changes. OpenCode has a headless ACP provider on the shared bridge.

## 3. Settled architecture (consensus of both plans)

- **Targeted core ACP provider** — no new package, plugin bridge, custom controller, or parallel runtime. OpenCode's file template for structure; **Cursor's session-config shape for MCP injection**.
- **Fixed, non-overridable managed launch profile** hard-coded in the config type: no settings toggle, no passthrough args, no per-flag opt-outs. The "managed" claim is gated by a behavioral poisoned-workspace test (canary AGENTS.md/rules, project MCP config, extensions incl. bundled defaults, skills must demonstrably have zero effect), not by trusting the flag list. An unclosable ambient input is a ship blocker escalated upstream.
- **RepoPrompt MCP is the sole tool surface and sole permission authority.** OMP-side approvals are neutralized (§4.4); RepoPrompt's server-side, fail-closed, per-profile MCP approval gates are authoritative.
- **Dynamic models only**: configOptions → `AgentACPModelRegistry` → catalog, with a single `Default` sentinel as the only static entry; no OMP static model cases ever.
- New **`AgentProviderBindingID.ohMyPi`** with an independent RepoPrompt MCP grant and fixed managed-barebones permission profile; because that profile has no mutable choices, it does not manufacture a no-op secure permission document. Model-cache/diagnostic reset remains independent; no piggybacking on `.openCode`/`.cursor`.
- **Dark-ship gating**: `ohMyPiAvailable` stays false in `AvailabilityContext.current`. `AgentModeRunService` rejects `.ohMyPi` before workspace/provider startup when that flag is false, including persisted or MCP-configured selections. The headless adapter and factory are implemented, but OMP is also filtered from public discovery/provider lists, recommendations, and task-label chains. The public flip remains atomic with release smoke.
- `requiresExpectedPIDOwnedAgentModeMCPRouting = true` and `requiresPrePromptAgentModeMCPRouting = true` — MCP-never-connected fails closed **before** the first prompt (load-bearing: MCP is the entire tool surface).
- All changes additive (new enum raws, namespaced keys, no migrations); the availability flag is the single kill switch. Known rollback limitation: an older build won't recognize persisted `selectedAgent == "ohMyPi"`.

## 4. Design decisions (final, duel-settled)

### 4.1 MCP transport — stdio primary via the Cursor template (both lanes converged on referee evidence)

`OhMyPiACPAgentProvider.makeSessionConfiguration` returns `ACPSessionConfiguration(mode:, workingDirectory:, mcpServers: [mcpServer])` — the passed-in `RepoPromptMCPServerConfiguration` exactly as Cursor does (default server name preserved: `repoPromptToolName` recognition keys off it). Zero new transport DTOs; zero controller serialization changes; the path is production-exercised today. OracleB's "under-exercised first consumer" caution was retired and OracleC's "must be HTTP/SSE" position was withdrawn on source evidence (`#toMcpConfig` stdio support). **Contingency (designed, built only if the live spike falsifies stdio end-to-end):** a transport-tagged ACP MCP server DTO (`.stdio`/`.http`/`.sse`) pointing at RepoPrompt's existing HTTP endpoint, byte-for-byte preserving Cursor/OpenCode wire output.

### 4.2 Resume — disabled pending live proof

Capability advertisement is insufficient. The implemented provider always returns `.new`, the headless adapter discards `resumeSessionID`, and `.candidate` never authorizes `session/load`. Fresh sessions receive transcript handoff. Resume may be reconsidered only after a captured cross-process load proves MCP re-registration and non-duplicating history semantics.

### 4.3 Thinking selector — deferred post-MVP; mechanism decided at fast-follow

MVP never sets `thinking`; the capture observed current `high`, so omission deliberately makes no claim about an `auto` default. Agreed constraints for the fast-follow, whichever mechanism wins: thinking is never encoded into the ACP wire model value sent to OMP; model is applied before thinking; unavailable values fail actionably without silent substitution; per-model persistence with a Default ("don't send") state. The duel crossed over on mechanism — OracleB ended favoring an additive `ACPRunRequest.additionalConfigOptionValues` map + separate `OhMyPiAgentToolPreferences` store; OracleC ended favoring reuse of Cursor's parameter-selector/bracket machinery (brackets as RepoPrompt-side selection encoding only). Decide with fixtures at implementation time; both are recorded as viable. Never map onto `ClaudeCodeEffortLevel`/`CodexReasoningEffort`. OMP's ACP `mode` select (default/plan) is unused: `acpSessionModeID` stays nil for all profiles.

### 4.4 Approvals — two belts, OMP-specific, with recognition scoping (OracleC conceded; OracleB refinement adopted)

Belt 1: the locally accepted yolo-equivalent flag is fixed in the profile, but suppression on real tool calls remains unproven and release-blocking. Belt 2: OMP's runtime permission binding auto-approves ACP tool-call permissions only with an exact known RepoPrompt server identity and/or an explicit server-prefixed canonical RepoPrompt tool name; substring server matches and anything unrecognized fall through to normal interactive handling and are logged. Rationale: with `--no-tools` + forced `enableMCP:false`, an ACP-layer prompt can only gate a call into RepoPrompt's independently enforced MCP policy — a strict duplicate — and a future OMP version renaming the yolo flag must degrade invisibly, not into per-call double prompts. Release is blocked unless the spike proves: no built-ins under the profile, ambient MCP cannot load, denied RepoPrompt MCP calls stay denied, auto-approval cannot bypass the server-side profile, headless runs don't stall on provider prompts.

### 4.5 Model menu — reuse `openCodeMenu`, parameterize before forking (OracleC conceded)

OMP raws are the same `provider/model` format; the `"opencode"` prefix-strip is inert for OMP inputs. Phase 3 adds adversarial menu tests over OMP-shaped inputs (`:free` suffixes, IDs resembling variant patterns, IDs without `/`, large catalogs, raw round-tripping); any misfiring heuristic gets gated by `providerID` inside the shared builder. Parallel OMP menu DTOs only as a proven-necessary fallback. No rename churn in this change.

### 4.6 Normalizer — thin named seam (OracleC conceded)

`OhMyPiACPEventNormalizer` delegates every payload to `ACPDefaultSessionUpdateNormalizer.normalize(_:providerID: .ohMyPi)`: template symmetry with both existing providers, a stable fixture-test anchor, and the future home for MCP tool-title canonicalization to `explicitRepoPromptToolName` if fixtures demand it. Stays pass-through otherwise.

### 4.7 Naming — referee ruling

Case `.ohMyPi`, raw `"ohMyPi"` for `ACPProviderID`/`AgentProviderKind`/`AgentProviderBindingID`, per the established camelCase identity convention (`openCode`'s raw is not its `opencode` binary name); `commandName "omp"`, `runtimeKind "omp_acp"`, display "Oh My Pi". OracleC's dissent (raw `"omp"`) recorded; identity ≠ executable name won.

## 5. Component inventory

New `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/`: `OhMyPiAgentConfig` (fixed managed args, `CLIPathHints.ohMyPi`, `includeRepoPromptMCPServer`), `OhMyPiACPLaunchResolver` (OpenCode-shaped: probe ACP subcommand exit via `omp acp --help`, managed global flags via `omp --help`, plus a version pin, `ExecutableFileIdentity` capture/revalidation, and `AsyncMutex` probe serialization), `OhMyPiACPAgentProvider` (Cursor-shaped session config; OpenCode-shaped prompt blocks incl. images; actionable error mapping), `OhMyPiACPEventNormalizer`, `OhMyPiACPHeadlessAgentProvider` (Phase 4, shared bridge, fresh sessions only, `.declineUnsupported`; doubles as the model-refresh/discovery probe).

Enum/seam sweeps (all compiler-enforced arms plus an `rg` inventory for string-keyed surfaces in the PR description): `ACPProviderID`, `AgentProviderKind` (+every switch; provisional MCP routing hint from captured ACP `agentInfo.name`, not live MCP `clientInfo.name`), `AgentProviderBindingID`, `ACPAgentProviderFactory`, `AgentModelCatalog` (`ohMyPiAvailable` arms, ordering after `.cursor`, defaults/options/validation, recommendation-filter false), `AgentModel` arms, `AgentModeMCPToolPolicy.grantedTools` (standard ACP grant; **Phase-1 product decision**: inventory whether RepoPrompt MCP exposes a policy-gated exec tool — otherwise OMP is a read/search/edit harness at MVP, documented), permission resolver arm, CLI override/profile plumbing, settings UI block (probe, install guidance, managed-profile explanation, permission reset).

## 6. Phases

- **Phase 0 — Live spike + fixture capture (partially implemented / blocked on responsive OMP model).** `Scripts/omp_acp_live_spike.py` automates preflight, direct helper MCP startup, ACP bootstrap, a no-tool prompt, and an opt-in safety-enforced round-trip. The latter uses a fresh private scratch directory, a one-tool synthetic read-only MCP proxy, full before/after workspace snapshots, and process teardown before evidence writes; it is transport evidence only, not a production-helper call. It established stdio injection/bootstrap, but both prompt-bearing phases remain blocked until the selected OMP authentication/model profile answers reliably. Preserve raw working notes locally, and commit only safe, useful fixtures under `Tests/RepoPromptTests/AgentMode/Fixtures/OhMyPiACP/` after a successful call. Go/no-go remains: a real production-helper stdio MCP round trip, managed-flag behavioral completeness, and MCP long-call tolerance.
- **Phase 1 — Dark enum/seam sweep (implemented).** All identity, catalog, selection, binding, persistence, MCP-policy, and exhaustive/string-keyed arms are wired with `ohMyPiAvailable` false.
- **Phase 2 — Provider implementation + unit tests (implemented dark).** The OhMyPi directory, factory, fixed resolver/path hints, Cursor-shaped stdio session injection, normalizer fixtures, and focused contract tests are present. No HTTP contingency was justified.
- **Phase 3 — Interactive Agent Mode (implemented dark; smoke outstanding).** Permission/controller policy and dynamic picker branches reuse `openCodeMenu`; resume remains disabled. Availability was not enabled, including in DEBUG; a lifecycle regression proves that persisted or MCP-configured OMP cannot bypass the dark gate; and no visible-app smoke has run.
- **Phase 4 — Headless adapter + settings (implemented dark; live delegation outstanding).** The shared fresh-session headless bridge and diagnostic probe/model refresh/reset surface are wired, but public discovery/delegation remains gated.
- **Phase 5 — Hardening + atomic flip (not started).** The architecture caveats are documented, but `supportedCLIProviderAgents` and `.current` remain unchanged until every live release gate passes. Resume is separately gated.
- **Phase 6 — Fast-follow (separately gated).** Thinking selector per §4.3.

Total ≈ 3–4.5 weeks, one engineer, including the spike.

## 7. Spike checklist (all with captured JSONL evidence)

1. Stdio `mcpServers` entry in `session/new` → OMP connects, RepoPrompt tools exposed, a call round-trips; capture OMP's MCP `clientInfo.name`/version and the observed client PID (expected-PID compatibility). HTTP fallback shape only if stdio fails.
2. Poisoned-workspace managed-flag completeness (AGENTS.md/rules, project MCP, extensions incl. bundled defaults, skills; local config cannot override flags); enumerate managed global flags from `omp --help` (the 17.2.12 `omp acp --help` output is subcommand usage only) for missing ambient-input controls (`--no-rules` vs AGENTS.md-style context especially).
3. Approvals: default-mode `session/request_permission` frequency for MCP calls; exact yolo flag spelling/scope; suppression confirmed; denied RepoPrompt MCP calls stay denied; any non-tool permission kinds; no fs/terminal delegation.
4. `tool_call`/`tool_call_update` payload shapes for RepoPrompt MCP tools → normalizer fixtures; `repoPromptToolName` recognition renders RepoPrompt tool cards.
5. Long-blocking MCP call (≥10 min approval wait) vs OMP's MCP client timeout; identify the knob or its absence.
6. configOptions capture (mode/model/thinking IDs, defaults); mid-session `set_config_option` model; unset thinking harmless.
7. Cross-process `session/load`: MCP re-registration, history-replay shape vs controller dedup, prompt-after-load; `resume` vs `load` semantics. Gates §4.2.
8. Auth: `initialize` authMethods; logged-out error shape → error-mapping copy.
9. Lifecycle: cancel mid-generation/mid-MCP-call (stopReason, child cleanup), EOF/crash, usage-update shape or absence, cwd honoring, `omp --version`, install footprint for path hints.
10. Qualitative: a golden-path task under `--no-tools` — does the model drive RepoPrompt MCP tools competently?

## 8. Validation

- Unit suites under `Tests/RepoPromptTests/AgentMode/`: `OhMyPiACPLaunchResolverTests`, `OhMyPiACPEventNormalizerTests` (Phase-0 fixtures), `OhMyPiACPAgentProviderTests` (exact managed args; exactly one RepoPrompt `mcpServers` entry for fresh `.new` sessions and none for discovery; `.load` must never be selected; prompt blocks incl. images; error mapping), catalog/menu/selection-ID round-trip tests (raws contain `/`), registry persistence via test SPI, permission-binding and MCP-policy grant tests, headless bridge tests.
- Lanes: `make dev-test FILTER='OhMyPi'` during iteration; ACP regression lane (OpenCode/Cursor/controller suites) before/after Phases 2–4 to prove zero shared-controller drift; full `make dev-test` at each phase gate.
- Installed-app smoke (Phase 3 DEBUG, re-run at Phase 5 flip): streaming; RepoPrompt tool cards; approval allow **and** deny with no ACP-layer double prompt; long approval wait; steering mid-turn and mid-MCP-call; cancel with clean teardown; model picker after first session and after restart; model switch; resume across restart (if enabled); missing CLI / logged-out errors actionable; poisoned workspace inert; forced process kill → clean failed terminal; delegated `agent_run` (post-Phase 4).


### Current worktree validation (2026-08-10)

- `make dev-test FILTER=OhMyPiACPProviderTests`: 13/13 passed (curated ledger filter, no unknown-filter override), including resolver help-split, approval spoof resistance, pre-prompt ordering, dark public surfaces, cross-provider persistence transactions, OMP menu opacity, and polling reset/coalescing coverage.
- Routing/headless/registry/menu regressions passed: `MCPBootstrapLeaseTests` 6/6, `AgentModeRunServiceLifecycleTests` 48/48 (including the persisted/MCP-configured dark-gate regression), `ContextBuilderModelStartupSelectionTests` 12/12, and `CursorModelSelectionSurfaceSpikeTests` 6/6.
- Shared ACP/settings regressions passed: `ACPAgentSessionControllerModeConfigTests` 27/27, `ACPProviderSessionIdentityTests` 4/4, `ACPSynchronousMCPStartupTests` 3/3, and `AppSettingsMCPServiceAgentModeSettingsTests` 4/4.
- `make dev-build`, `make dev-format-check`, and `make dev-lint` passed. A later `make dev-run` packaged the current app but could not launch a second instance because the app hosting this session already owns the same debug bundle identifier; it did not stop or replace that app.
- Live bootstrap passed via `Scripts/omp_acp_live_spike.py --phase bootstrap`: OMP `17.2.12`, all managed global flags, bundled RepoPrompt CE `1.0.29` MCP helper with 21 tools, ACP v1 initialize/authenticate/session-new, and dynamic `mode`/`model`/`thinking` selectors. The scratch workspace was unchanged except for the harness marker.
- Direct prompt evidence is a release blocker, not a false success: the no-tool ACP prompt timed out after 60 seconds with no model/tool/permission event, and a bare constrained OMP print-mode prompt timed out after 80 seconds. Both probes terminated their child process groups; no root cause is inferred from those timeouts.
- Source-layout, contributor-allowlist, license, and SwiftPM guardrail phases pass. `Scripts/test-check-agent-context` passes 23/23.
- No visible-app smoke was run. All live OMP release gates in the implementation checkpoint remain outstanding.

## 9. Risks

1. **Managed flags incomplete** (bundled extensions / AGENTS.md leak) — behavioral poisoned-workspace gate; unclosable ⇒ ship blocker escalated upstream.
2. **OMP MCP client timeout kills long approval-gated calls** — spike item 5; knob → keep-alive progress notifications → upstream issue → documented constraint.
3. **Tool-name/PID shape mismatch** breaks RepoPrompt card pairing or expected-PID routing — fixtures + thin-normalizer canonicalization; replace the provisional `mcpClientNameHint` only from a live MCP `clientInfo.name`/PID capture.
4. **Stdio unexpectedly rejected live** despite source support — designed HTTP contingency, ~2–3 days.
5. **Yolo flag missing/renamed in a future OMP** — belt 2 (scoped auto-approve) absorbs it invisibly.
6. **Young-project protocol drift** — min-version pin in `support(for:)`, default-normalizer tolerance, per-version fixture recapture.
7. **Non-compiler-enforced surfaces missed** — mandatory `rg` inventory in the Phase-1 PR.
8. **No shell without a RepoPrompt exec tool** — capability, not correctness; explicit Phase-1 inventory + product decision, documented limitation otherwise.
9. **Auth friction** (logins live in OMP's TUI) — MVP requires pre-authenticated OMP with actionable error copy.
