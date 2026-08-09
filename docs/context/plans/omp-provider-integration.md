# Plan: Oh My Pi (OMP) as a Third ACP Provider — Managed Barebones Harness

Scope: read when the task touches Oh My Pi/OMP provider integration, `ACPProviderID`/`ACPAgentProvider` seam extension for OMP, `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/**`, or OMP Agent Mode wiring.
Authority: Authoritative
Last-verified: 2026-08-09

Status: **Planned — not yet implemented**
Date: 2026-08-09
Provenance: an independent verification pass confirmed every load-bearing repository claim by direct reads and every upstream OMP claim against OMP source on `main` (can1357/oh-my-pi), then two independent Oracle plans (presets OracleB, OracleC) over a ~75k-token curated ACP-seam selection, one adversarial duel round on every material disagreement with referee-supplied source evidence, then synthesis. Preset identity (`model_preset_id`/`model_preset_name`) was verified on every send.

## 1. Goal

Add Oh My Pi as a third interactive ACP provider alongside OpenCode and Cursor, as a **managed barebones harness**: launch `omp acp --no-tools --no-extensions --no-skills --no-rules` plus a spike-confirmed approval-suppressing flag (`--approval-mode yolo` expected), inject the RepoPrompt MCP server through ACP `session/new` `mcpServers` as the **sole tool surface**, so users get OMP's broad model/auth ecosystem (Cursor Pro, OpenRouter, etc.) while RepoPrompt owns tools, context, and permissions. This is deliberately the opposite shape from the Pi native-RPC plan (`docs/context/plans/pi-provider-integration.md`): OMP rides the existing ACP seam; the two plans share only enum-sweep surfaces and must use distinct identifiers (`.ohMyPi` vs planned `.pi`).

## 2. Verified facts the plan rests on

Upstream OMP (source on `main`, verified 2026-08-09):

- `omp acp` is a first-party ACP server over stdio JSON-RPC (@agentclientprotocol/sdk). `initialize` advertises `loadSession:true`, `mcpCapabilities {http, sse}`, `promptCapabilities {embeddedContext, image}`, `sessionCapabilities {list, fork, resume, close}`.
- `#toMcpConfig` accepts **stdio** entries (`"command" in server`) plus http and sse — the advertised `mcpCapabilities` are the optional extended transports, not an exclusion of baseline stdio.
- ACP mode forces `enableMCP:false`: user global/project MCP config never loads; the ACP client is the exclusive MCP source.
- `--no-tools` sets `toolNames=[]` — an allowlist over **built-in tools only**. MCP tools bypass the allowlist entirely (name-dedup only) via `session.refreshMCPTools(manager.getTools())`. Under `--no-tools`, every tool call flows through injected MCP.
- `--no-extensions` sets `disableExtensionDiscovery=true`; `--no-skills` sets `skills=[]`; `--no-rules` sets `rules=[]`.
- configOptions advertises three selects: `mode` (default/plan), `model` (`provider/model` IDs from `session.getAvailableModels()`), `thinking` (off/auto/high/medium/low).
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
- New **`AgentProviderBindingID.ohMyPi`** with its own permission documents and reset controls; no piggybacking on `.openCode`/`.cursor`.
- **Dark-ship gating**: `ohMyPiAvailable` stays false in `AvailabilityContext.current` (Cursor CE precedent) with `AgentRuntimeProviderService.makeProvider(.ohMyPi)` throwing typed-unsupported until the headless adapter lands; the public flip is atomic with release smoke, so no released build exposes a delegation surface that can reach an unsupported branch. Excluded from recommendations and task-label chains at MVP.
- `requiresExpectedPIDOwnedAgentModeMCPRouting = true` and `requiresPrePromptAgentModeMCPRouting = true` — MCP-never-connected fails closed **before** the first prompt (load-bearing: MCP is the entire tool surface).
- All changes additive (new enum raws, namespaced keys, no migrations); the availability flag is the single kill switch. Known rollback limitation: an older build won't recognize persisted `selectedAgent == "ohMyPi"`.

## 4. Design decisions (final, duel-settled)

### 4.1 MCP transport — stdio primary via the Cursor template (both lanes converged on referee evidence)

`OhMyPiACPAgentProvider.makeSessionConfiguration` returns `ACPSessionConfiguration(mode:, workingDirectory:, mcpServers: [mcpServer])` — the passed-in `RepoPromptMCPServerConfiguration` exactly as Cursor does (default server name preserved: `repoPromptToolName` recognition keys off it). Zero new transport DTOs; zero controller serialization changes; the path is production-exercised today. OracleB's "under-exercised first consumer" caution was retired and OracleC's "must be HTTP/SSE" position was withdrawn on source evidence (`#toMcpConfig` stdio support). **Contingency (designed, built only if the live spike falsifies stdio end-to-end):** a transport-tagged ACP MCP server DTO (`.stdio`/`.http`/`.sse`) pointing at RepoPrompt's existing HTTP endpoint, byte-for-byte preserving Cursor/OpenCode wire output.

### 4.2 Resume — MVP, conditional on spike proof, with a verified-only load guard

Resume ships in MVP **iff** Phase-0 spike item 7 proves cross-process `session/load` continuity including MCP re-registration from the newly supplied `mcpServers`. Confidence guard (OracleC's, adopted): only `.verified` identity authorizes `session/load`; `.candidate` may be recorded diagnostically but is never fed to load. On proof, OMP identity is reported `.verified` and `.load(existingSessionID:)` is enabled (OpenCode-shaped, production-exercised controller path); on spike failure, resume stays disabled (fresh + transcript handoff) without blocking MVP. Load failure → single retry with `.new` + transcript-handoff prepend, only when failure precedes prompt dispatch; never auto-replay a prompt after ambiguous execution (duplicate MCP side effects). The pre-prompt MCP gate fails a tool-less loaded session closed.

### 4.3 Thinking selector — deferred post-MVP; mechanism decided at fast-follow

MVP never sets `thinking` (spike confirms unset ⇒ provider default, expected `auto`). Agreed constraints for the fast-follow, whichever mechanism wins: thinking is never encoded into the ACP wire model value sent to OMP; model is applied before thinking; unavailable values fail actionably without silent substitution; per-model persistence with a Default ("don't send") state. The duel crossed over on mechanism — OracleB ended favoring an additive `ACPRunRequest.additionalConfigOptionValues` map + separate `OhMyPiAgentToolPreferences` store; OracleC ended favoring reuse of Cursor's parameter-selector/bracket machinery (brackets as RepoPrompt-side selection encoding only). Decide with fixtures at implementation time; both are recorded as viable. Never map onto `ClaudeCodeEffortLevel`/`CodexReasoningEffort`. OMP's ACP `mode` select (default/plan) is unused: `acpSessionModeID` stays nil for all profiles.

### 4.4 Approvals — two belts, OMP-specific, with recognition scoping (OracleC conceded; OracleB refinement adopted)

Belt 1: the spike-confirmed yolo-equivalent flag in the fixed profile, so `session/request_permission` is structurally absent. Belt 2: OMP's runtime permission binding auto-approves ACP tool-call permissions **scoped to calls recognized as RepoPrompt-server tools** (server-name/`repoPromptToolName` recognition); anything unrecognized falls through to normal interactive handling and is logged. Rationale: with `--no-tools` + forced `enableMCP:false`, an ACP-layer prompt can only gate a call into RepoPrompt's independently enforced MCP policy — a strict duplicate — and a future OMP version renaming the yolo flag must degrade invisibly, not into per-call double prompts. Release is blocked unless the spike proves: no built-ins under the profile, ambient MCP cannot load, denied RepoPrompt MCP calls stay denied, auto-approval cannot bypass the server-side profile, headless runs don't stall on provider prompts.

### 4.5 Model menu — reuse `openCodeMenu`, parameterize before forking (OracleC conceded)

OMP raws are the same `provider/model` format; the `"opencode"` prefix-strip is inert for OMP inputs. Phase 3 adds adversarial menu tests over OMP-shaped inputs (`:free` suffixes, IDs resembling variant patterns, IDs without `/`, large catalogs, raw round-tripping); any misfiring heuristic gets gated by `providerID` inside the shared builder. Parallel OMP menu DTOs only as a proven-necessary fallback. No rename churn in this change.

### 4.6 Normalizer — thin named seam (OracleC conceded)

`OhMyPiACPEventNormalizer` delegates every payload to `ACPDefaultSessionUpdateNormalizer.normalize(_:providerID: .ohMyPi)`: template symmetry with both existing providers, a stable fixture-test anchor, and the future home for MCP tool-title canonicalization to `explicitRepoPromptToolName` if fixtures demand it. Stays pass-through otherwise.

### 4.7 Naming — referee ruling

Case `.ohMyPi`, raw `"ohMyPi"` for `ACPProviderID`/`AgentProviderKind`/`AgentProviderBindingID`, per the established camelCase identity convention (`openCode`'s raw is not its `opencode` binary name); `commandName "omp"`, `runtimeKind "omp_acp"`, display "Oh My Pi". OracleC's dissent (raw `"omp"`) recorded; identity ≠ executable name won.

## 5. Component inventory

New `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/`: `OhMyPiAgentConfig` (fixed managed args, `CLIPathHints.ohMyPi`, `includeRepoPromptMCPServer`), `OhMyPiACPLaunchResolver` (OpenCode-shaped: probe `omp acp --help` + version pin, `ExecutableFileIdentity` capture/revalidation, `AsyncMutex` probe serialization, managed-flag support verification), `OhMyPiACPAgentProvider` (Cursor-shaped session config; OpenCode-shaped prompt blocks incl. images; actionable error mapping), `OhMyPiACPEventNormalizer`, `OhMyPiACPHeadlessAgentProvider` (Phase 4, shared bridge, fresh sessions only, `.declineUnsupported`; doubles as the model-refresh/discovery probe).

Enum/seam sweeps (all compiler-enforced arms plus an `rg` inventory for string-keyed surfaces in the PR description): `ACPProviderID`, `AgentProviderKind` (+every switch; MCP client ID from spike-captured `clientInfo.name`), `AgentProviderBindingID`, `ACPAgentProviderFactory`, `AgentModelCatalog` (`ohMyPiAvailable` arms, ordering after `.cursor`, defaults/options/validation, recommendation-filter false), `AgentModel` arms, `AgentModeMCPToolPolicy.grantedTools` (standard ACP grant; **Phase-1 product decision**: inventory whether RepoPrompt MCP exposes a policy-gated exec tool — otherwise OMP is a read/search/edit harness at MVP, documented), permission resolver arm, CLI override/profile plumbing, settings UI block (probe, install guidance, managed-profile explanation, permission reset).

## 6. Phases

- **Phase 0 — Live spike + fixture capture (3–4d).** No app code. Scripted stdio JSON-RPC harness against a pinned OMP version; committed fixtures under `Tests/RepoPromptTests/AgentMode/Fixtures/OhMyPiACP/`; raw working notes stay local (not staged) per repo policy. Go/no-go: stdio MCP round trip, managed-flag behavioral completeness, MCP long-call tolerance.
- **Phase 1 — Dark enum/seam sweep (2–3d).** All arms land atomically, `ohMyPiAvailable` false everywhere, factory returns nil placeholder, headless throws typed-unsupported. Full `make dev-test` green; zero UI change.
- **Phase 2 — Provider implementation + unit tests (4–5d).** The OhMyPi directory, factory branch, path hints; HTTP contingency only if Phase 0 demanded it.
- **Phase 3 — Interactive Agent Mode, DEBUG-gated (5d).** Permission-resolver arm, picker branches reusing `openCodeMenu`, resume identity per §4.2, DEBUG availability enable, installed-app DEBUG smoke.
- **Phase 4 — Headless adapter + settings (3–4d).** Real `makeProvider` branch, settings block, `list_agents`/delegated `agent_run` verification in DEBUG.
- **Phase 5 — Hardening + atomic flip (2–3d).** `supportedCLIProviderAgents` + `.current` flip atomic with release smoke; `provider-plugins.md` OMP subsection + MCP-timeout entry; resume confidence finalized.
- **Phase 6 — Fast-follow (separately gated).** Thinking selector per §4.3.

Total ≈ 3–4.5 weeks, one engineer, including the spike.

## 7. Spike checklist (all with captured JSONL evidence)

1. Stdio `mcpServers` entry in `session/new` → OMP connects, RepoPrompt tools exposed, a call round-trips; capture OMP's MCP `clientInfo.name`/version and the observed client PID (expected-PID compatibility). HTTP fallback shape only if stdio fails.
2. Poisoned-workspace managed-flag completeness (AGENTS.md/rules, project MCP, extensions incl. bundled defaults, skills; local config cannot override flags); enumerate `omp acp --help` for missing ambient-input flags (`--no-rules` vs AGENTS.md-style context especially).
3. Approvals: default-mode `session/request_permission` frequency for MCP calls; exact yolo flag spelling/scope; suppression confirmed; denied RepoPrompt MCP calls stay denied; any non-tool permission kinds; no fs/terminal delegation.
4. `tool_call`/`tool_call_update` payload shapes for RepoPrompt MCP tools → normalizer fixtures; `repoPromptToolName` recognition renders RepoPrompt tool cards.
5. Long-blocking MCP call (≥10 min approval wait) vs OMP's MCP client timeout; identify the knob or its absence.
6. configOptions capture (mode/model/thinking IDs, defaults); mid-session `set_config_option` model; unset thinking harmless.
7. Cross-process `session/load`: MCP re-registration, history-replay shape vs controller dedup, prompt-after-load; `resume` vs `load` semantics. Gates §4.2.
8. Auth: `initialize` authMethods; logged-out error shape → error-mapping copy.
9. Lifecycle: cancel mid-generation/mid-MCP-call (stopReason, child cleanup), EOF/crash, usage-update shape or absence, cwd honoring, `omp --version`, install footprint for path hints.
10. Qualitative: a golden-path task under `--no-tools` — does the model drive RepoPrompt MCP tools competently?

## 8. Validation

- Unit suites under `Tests/RepoPromptTests/AgentMode/`: `OhMyPiACPLaunchResolverTests`, `OhMyPiACPEventNormalizerTests` (Phase-0 fixtures), `OhMyPiACPAgentProviderTests` (exact managed args; exactly one RepoPrompt `mcpServers` entry for `.new` and `.load`; prompt blocks incl. images; error mapping), catalog/menu/selection-ID round-trip tests (raws contain `/`), registry persistence via test SPI, permission-binding and MCP-policy grant tests, headless bridge tests.
- Lanes: `make dev-test FILTER='OhMyPi'` during iteration; ACP regression lane (OpenCode/Cursor/controller suites) before/after Phases 2–4 to prove zero shared-controller drift; full `make dev-test` at each phase gate.
- Installed-app smoke (Phase 3 DEBUG, re-run at Phase 5 flip): streaming; RepoPrompt tool cards; approval allow **and** deny with no ACP-layer double prompt; long approval wait; steering mid-turn and mid-MCP-call; cancel with clean teardown; model picker after first session and after restart; model switch; resume across restart (if enabled); missing CLI / logged-out errors actionable; poisoned workspace inert; forced process kill → clean failed terminal; delegated `agent_run` (post-Phase 4).

## 9. Risks

1. **Managed flags incomplete** (bundled extensions / AGENTS.md leak) — behavioral poisoned-workspace gate; unclosable ⇒ ship blocker escalated upstream.
2. **OMP MCP client timeout kills long approval-gated calls** — spike item 5; knob → keep-alive progress notifications → upstream issue → documented constraint.
3. **Tool-name shape mismatch** breaks RepoPrompt card pairing — fixtures + thin-normalizer canonicalization; correct `mcpClientNameHint`.
4. **Stdio unexpectedly rejected live** despite source support — designed HTTP contingency, ~2–3 days.
5. **Yolo flag missing/renamed in a future OMP** — belt 2 (scoped auto-approve) absorbs it invisibly.
6. **Young-project protocol drift** — min-version pin in `support(for:)`, default-normalizer tolerance, per-version fixture recapture.
7. **Non-compiler-enforced surfaces missed** — mandatory `rg` inventory in the Phase-1 PR.
8. **No shell without a RepoPrompt exec tool** — capability, not correctness; explicit Phase-1 inventory + product decision, documented limitation otherwise.
9. **Auth friction** (logins live in OMP's TUI) — MVP requires pre-authenticated OMP with actionable error copy.
