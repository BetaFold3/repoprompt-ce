# Plan: Pi Coding Agent as a Second Interactive Native Provider

Scope: read when the task touches Pi provider integration, the native runtime seam neutralization (`NativeAgentRuntimeContracts.swift`), the `RepoPromptPiProvider` package, the bundled Pi MCP extension, or Pi Agent Mode wiring.
Authority: Authoritative
Last-verified: 2026-08-09

Status: **Planned — not yet implemented**
Date: 2026-08-09
Provenance: two independent Oracle plans (presets OracleB, OracleC) over an ~108k-token curated selection of the native runtime seam, followed by two adversarial duel rounds on every material disagreement, then synthesis. Preset identity (`model_preset_id`/`model_preset_name`) was verified on every send. Prior to planning, an independent verification pass confirmed every load-bearing repository claim by direct reads and every upstream Pi claim against Pi's official RPC docs, CLI reference, and package listing.

## 1. Goal

Add `pi` (earendil-works/pi) as a first-class interactive native Agent Mode provider using Pi's RPC mode (`pi --mode rpc`, strict LF-delimited JSONL over stdin/stdout), at parity in spirit with the Claude Code native integration: streamed thinking/text/tool events, native steering, RepoPrompt-controlled tool surface, dynamic model/thinking-level selection, session resume, and fail-closed MCP bridging — without regressing Claude.

## 2. Verified facts the plan rests on

Upstream (Pi official docs, verified 2026-08-09):

- RPC mode is the documented subprocess embedding path for non-Node hosts. Strict LF-delimited JSONL; generic Unicode line splitting is non-compliant.
- Commands: `prompt` (with images), `steer`, `follow_up`, `abort`, `abort_bash`, `abort_retry`, `new_session`, `switch_session`, `fork`, `clone`, `get_session_stats`, `set_model`, `cycle_model`, `get_available_models`, `set_thinking_level`, `get_available_thinking_levels`, `compact`, `set_auto_compaction`, `get_messages`, `get_state`, `bash`; optional `id` correlation on commands.
- Events: `message_start/update/end` (thinking + text deltas), `tool_execution_start/update/end`, `bash_execution_update`, `agent_start/agent_end/agent_settled`, `compaction_start/end`, `auto_retry_start/end`.
- Pi has **no built-in MCP client**; MCP requires an extension. The third-party `pi-mcp-extension` is not first-party and is not used.
- Managed flags: `--no-extensions -e <path>` loads only the named extension; `--no-builtin-tools` keeps extension tools; `--no-skills`, `--no-prompt-templates`, `--no-context-files` disable ambient discovery. `--no-approve` is project-local trust gating, **not** tool-permission control.
- Unverified, spike-gated: extension UI request/response over RPC; tool-approval semantics when only extension tools exist; `agent_settled` ordering around `steer`/`follow_up`; session-identity shape; whether thinking levels are model-dependent.

Repository (verified by direct reads):

- `NativeAgentRuntimeContracts.swift` declares the neutral `NativeAgentRuntimeControlling` protocol, but every associated type is a typealias onto `ClaudeNativeProcessSessionController` DTOs (`NativeAgentRuntimeEffortLevel = ClaudeCodeEffortLevel`); the doc and code both say the aliases become neutral DTOs when a second native provider lands.
- `AgentModeRunService.startRun` routes `usesClaudeNativeRuntime` through `ClaudeIntegratedAgentModeRunner` (line ~242); ACP and headless are the only other paths.
- `AgentRuntimeProviderService.swift` holds ~26 exhaustive `AgentProviderKind` switches; `AgentProviderBindingID` has four binding groups (codex, claude, openCode, cursor).
- `docs/architecture/provider-plugins.md` prescribes the 8-step new-provider pattern (package product, single-import bridge, adapter trio, kind/catalog/binding wiring, package + root tests).
- MCP bootstrap uses `MCPBootstrapLease` with expected-PID policy arming; Agent Mode permissioning is RepoPrompt-side.

## 3. Settled architecture (consensus of both plans)

- New Foundation-only **`RepoPromptPiProvider`** product in `Packages/RepoPromptAgentProviders/` (codec, DTOs, translator, argument builder, fixtures); `PiJSONValue` instead of `[String: Any]`.
- **Core-owned** `PiNativeProcessSessionController` actor under `Sources/RepoPrompt/Infrastructure/AI/Providers/Pi/` (needs `ProcessLauncher`, `ServerNetworkManager`, `MCPConfigExportService`, expected-PID policy, Bundle resources — none may enter the package). Reuse Claude's proven infrastructure wholesale: `LineFramer`, `FileHandleChunkChannel`, `ProcessLauncher`/`ProcessTermination`, `ProcessEnvironmentBuilder` (new `.piNative` purpose, **strip `NODE_OPTIONS`**), `CommandPathResolver`/`CLIExecutableOverrideStore`/`CLILaunchProfiles` (new `pi` profile + Node path hints), `MCPConfigLease`, `MCPBootstrapLease`, `AgentRunTerminalCommitBarrier`.
- Two-facade bridge per the doc: `PiProviderRuntimeBridge` (Infrastructure; sole package import) and `PiPluginBridge` (Agent Mode facade), plus `PiNativeSessionAdapter` and `PiModelCatalogAdapter`.
- **Dedicated `PiAgentModeCoordinator` + `PiIntegratedAgentModeRunner`** — do not extend or genericize the Claude pair. Pi's native `steer` eliminates Claude's interrupt-then-resubmit machinery (no MCP-drain gate, no ack-parity wait, no superseding-turn protection). Runner keeps stale-completion filtering via `piExpectedTurnIDs` (abort races).
- **First-party TypeScript extension**, esbuild single-file bundle, in-repo source with pinned lockfile, official MCP TS SDK vendored into the bundle, committed artifact + SHA-256, CI rebuild-diff gate, controller-side checksum check before launch. Managed launch profile is hard-coded and non-overridable: `--mode rpc --no-extensions -e <bundled> --no-builtin-tools --no-skills --no-prompt-templates --no-context-files --no-approve`.
- **Approvals are MCP-side, not Pi-side.** RepoPrompt's MCP server approval gates remain authoritative; the Pi controller never emits `.approvalRequest`; `respondToPermissionRequest` is a no-op. The unverified extension-UI round-trip is off the MVP critical path but spike-probed (it would unlock a future Pi-native-tools profile).
- **Thinking levels are provider-owned raw strings** — never mapped onto `ClaudeCodeEffortLevel`/`CodexReasoningEffort`.
- New **`AgentProviderBindingID.pi`** (own permission documents, threat model, reset controls; no inheritance from `.claude`).
- Session IDs are **opaque**, persisted in `TabSession.providerSessionID`; never parse Pi session files; no auto-replay after crash (duplicate MCP side-effect risk); resume failure → fresh session + existing transcript-handoff prepend.
- `bash_execution_update` under the managed profile is a **managed-profile violation**: emit a security error, abort, shut down.
- No RepoPrompt-managed Pi secrets: Pi owns its provider credentials; settings document this.

## 4. Design decisions (final, duel-settled)

### 4.1 Seam neutralization — "promote, don't wrap" (OracleC conceded)

One atomic, logic-free PR. Promote the Claude controller's nested DTOs to top-level `NativeAgentRuntime*` types in a new `Runtime/Native/NativeAgentRuntimeDTOs.swift`; the Claude controller **emits neutral types directly** and keeps its direct protocol conformance. Flipped compatibility aliases (`ClaudeNativeProcessSessionController.Event = NativeAgentRuntimeEvent`, etc.) keep every existing reference and test compiling with zero edits (deleted in Phase 6). **No adapter forwarding task, no stream re-wrapping** — mapping an `AsyncStream` would have to mirror `ensureEventsStreamReady`/`resetEventsStreamForNewRun` stream-identity semantics and was judged the single biggest Claude-regression risk. No `TabSession` renames.

- The only Phase-1 signature change: `effortLevel: NativeAgentRuntimeEffortLevel?` → `effortLevel: String?` (Claude shims via `ClaudeCodeEffortLevel.parse`; two coordinator call sites append `.rawValue`).
- `RuntimeInitStatus` split: neutral `NativeAgentRuntimeInitStatus { sessionID, tools, mcpServerStatuses, repoPromptIntegrationState, details }` with `details: .claude(ClaudeRuntimeInitDetails) | .pi(PiRuntimeInitDetails)`; `isRepoPromptServerFailed` stays neutral (the runner's fail-fast branch is reused verbatim for Pi). `repoPromptIntegrationState: unknown/connecting/ready/failed` is adopted from OracleC's design.
- **Phase-1 regression gate (all required):** (a) no logic changes — moves, renames, one signature shim; (b) `make dev-test` fully green; (c) focused suites green: `ClaudeSDKNDJSONTranslatorTests`, `ClaudeNativeApprovalAndResumeTests`, `ClaudeCompatibleModelCatalogTests`, `ClaudeCompatiblePluginBridgeTests`, `ClaudeCompatibleBackendEnvironmentTests`; (d) scripted DEBUG Claude session with raw-event logging before/after, event-kind sequence diff empty; (e) single-revert PR.

### 4.2 Submission API — explicit modes, UUID return, throw-on-mismatch (both lanes converged in round 3)

Both lanes independently identified the decisive **ghost-turn race**: the queued-steering flush can reach the controller after `agent_settled`; a silently auto-resolving `sendUserMessage` would issue `prompt`, starting a turn with no run attempt, no terminal resources, and no event consumer — a successful ack with the wrong disposition that no throw catches. Therefore:

```swift
struct NativeAgentRuntimePrompt { let text: String; let images: [NativeAgentRuntimeImageAttachment] }  // Foundation-only; Claude ignores images (runner-side attachment flow unchanged)
func submit(_ prompt: NativeAgentRuntimePrompt, mode: NativeAgentRuntimeSubmissionMode) async throws -> UUID
enum NativeAgentRuntimeSubmissionMode { case prompt, steer }
```

- Mode resolution is actor-atomic; mismatch **throws** rather than silently converting: `.steer` with no active turn throws `noActiveTurn` → the flush routes the draft through the existing failure path (`recordPendingHandoffSendOutcome`) into the normal fresh-run path (correct: the run truly ended). `.prompt` with a turn in flight throws `turnInFlight` (startRun invariant violation).
- `.steer` on an active turn returns the **existing** turn ID (steering continues the same logical turn; no new turn boundary; no superseding machinery).
- Landed in Phase 2 as the protocol's submission method; Claude conforms via a trivial `.prompt`-only wrapper delegating to its existing send path (Claude steering remains coordinator-level interrupt-resend, unchanged).
- **Spike-driven extension point:** if Phase 0 shows Pi rejects or queues `steer` during the settling window, adopt the disposition-bearing variant (steer vs `follow_up`, receipt-style per OracleC) instead of widening silently. `follow_up` is otherwise unused at MVP.
- Live steering with image attachments is not sent (unverified upstream); such drafts are held for a post-settlement fresh run.

### 4.3 Readiness and health — in-band over MCP; no side channel (OracleC conceded in round 3)

Fail-closed has three layers:

1. **Structural:** managed flags mean extension-load failure yields a tool-less Pi — degraded, never uncontrolled.
2. **Attested readiness (pre-prompt gate):** after registering tools into Pi, the extension calls a dedicated **`pi_bridge_ready` authenticated MCP control method** (not an advertised agent tool) on RepoPrompt's server, carrying run ID, a launch-env nonce, and the registered tool-name list. The server verifies expected-PID (authoritative), nonce, run ownership, and **exact set-equality** against the granted-tool policy. The controller blocks the first prompt until this succeeds (timeout → `runtimeInit` failed → runner terminates the run pre-prompt with an actionable error).
3. **Mid-run liveness:** `ServerNetworkManager` is the server side of the extension's HTTP connection — post-readiness transport closure emits a Pi-client disconnect notification → controller aborts the turn and shuts Pi down. Registration breakage with a live transport is reported via **`pi_bridge_fatal`**. (A separate Unix status socket was rejected: same-process shared fate means it covers no failure mode these three signals miss.)

Ordering: expected-PID policy is armed at lease-acquire **before spawn** (Claude's existing ordering; no gate file needed). The controller sets `REPOPROMPT_MCP_CONFIG=<leased config path>` + nonce env on the spawned process; the extension connects to RepoPrompt's **HTTP** MCP server entry from the leased config (stdio would bypass expected-PID policy — corrected during the duel). Extension registers `clientInfo.name = "pi"` matching the new `mcpClientNameHint`.

### 4.4 Codec strictness — strict protocol, strict codec (OracleB conceded)

- Unknown but well-formed event types: log and ignore (forward compatibility).
- Duplicate response for an already-completed correlation ID: log and ignore.
- **Terminal protocol failures:** malformed JSON line, invalid UTF-8, oversized line (8 MiB cap), duplicate live response ID, structurally impossible correlated response. On failure: fail pending RPCs, drain turn FIFO to `.failed`, kill the process; session remains resumable via persisted identity. Rationale: a malformed line under strict LF-JSONL means framing desync — skip-and-continue can silently drop `agent_end`/`tool_execution_end` and mask a hung turn as completed. Claude's tolerance layers are evidence-driven exceptions, not precedent.
- Raw debug logs (`piRawEventLoggingEnabled`, DEBUG-gated) redact image bytes, MCP config paths, and environment values.

### 4.5 TabSession storage — sibling Pi fields (OracleC conceded)

Keep `claudeController` and all Claude turn bookkeeping untouched; a shared `nativeRuntimeController` slot would force `sessionOwnsClaudeController` and the fallback-claim/resume-transfer machinery to become family-aware — logic edits inside the most delicate Claude code. Add sibling `piController`, `piExpectedTurnIDs`, `pendingPiSteeringInstructions`, `piSteeringFlushTask`, and Pi-specific replacement claims. Enforce the one-native-process-per-tab invariant with a DEBUG `assertAtMostOneNativeController` at provider-transition and `cancelRun` sites. Unify under an `AgentNativeRuntimeFamily` enum in Phase 6, after both providers have stable suites.

### 4.6 Turn lifecycle and cancellation

- `agent_end` enqueues a candidate `TurnStatus` (completed / failed on error payload / cancelled if abort-flagged); **`agent_settled` is the authoritative idle** that dequeues and emits `.turnCompleted` — direct reuse of Claude's deferred-completion pattern, with a 1 s fallback timer for a missing `agent_settled`. Exact settle ordering under steer/follow-up is fixture-driven from Phase 0, never guessed.
- `interruptTurn` → `abort_retry` first if an auto-retry window is open, then `abort`; ack → `.acknowledged`, empty FIFO → `.noTurnInFlight`, ~2 s timeout → `.timedOut`; escalate to `ProcessTermination` on shutdown.
- RPC correlation: continuations + timeout tasks registered **before** the stdin write (Claude's race-avoidance rule). Timeouts: startup/model commands 10 s; prompt/steer ack 5 s; abort 2 s.
- Compaction/auto-retry are runtime-status-only (`task_progress`), not transcript rows; retry exhaustion surfaces as error with terminal state decided by settlement. Usage via `message_end` payloads plus one `get_session_stats` per turn end → existing `finalizeNonCodexTurnUsage`.
- EOF/crash: fail pending RPCs, drain turn IDs → `.error` + `turnCompleted(.failed)`, finish stream, deinit-safe SIGTERM + detached reap, expected-PID clear; next run may resume the persisted session.

### 4.7 Model catalog — dynamic registry (ACP pattern)

- `AgentPiModelRegistry` (mirrors `AgentACPModelRegistry`): snapshot `{ options, thinkingLevels, currentModelRaw }` fed from `runtimeInit` `details: .pi(...)` each session start and from the Phase-5 headless probe on demand; persisted in UserDefaults (`pi.modelCatalog.cache.v1`, schema-versioned) so pickers populate across launches; generation-guarded against out-of-order probes; stale snapshots retained on probe failure.
- Selection encoding `"<modelID>:<thinkingLevel>"`, parsing the suffix only when the token is in the discovered level set (colon-safe). `AgentModel.defaultModel` sentinel = "don't send `set_model`". No static Pi `AgentModel` cases.
- Validation: membership check with a snapshot; permissive non-empty without one (persisted selections survive cold starts). When a live catalog proves a stored model was removed, surface it as unavailable — never silently substitute.
- Per-model last-used thinking level + tri-state auto-compaction preference in `PiAgentToolPreferences` (`pi.thinkingLevelsByModel.v1`). A stored level absent from a live catalog is kept in storage, not sent, with a non-fatal settings notice.
- `AvailabilityContext` gains `piAvailable` (defaults-off/DEBUG-gated until Phase 6). Pi excluded from recommendations, task-label chains (tail position before Cursor when added), and `KnowledgeSessionPolicy` at MVP. Discovery DTOs gain additive `supportedReasoningLevelRaws`/`defaultReasoningLevelRaw`; Codex fields unchanged.

### 4.8 Sessions, settings, permissions

- `AgentProviderKind.pi`: `commandName "pi"`, `displayName "Pi"`, `runtimeKind "pi_native"`, `usesClaudeNativeRuntime false`, new `usesPiNativeRuntime`, expected-PID + pre-prompt MCP routing true, `providerBindingID .pi`. `AgentModeRunService.startRun` gains a Pi branch between Claude and ACP.
- Resume: spawn → `switch_session(providerSessionID)` → verify via `get_state`; on failure throw a designated resume error → coordinator retries once fresh + transcript handoff (generalize `stageResumeRecoveryHandoffIfNeeded` or add a Pi twin). If the spike reveals a launch-time session flag, prefer it.
- Settings (CLI Providers section): executable override (`cliExecutableOverride.pi`, `pi --version` probe, same wrapper rules as Claude), bundled-extension integrity status, "Test Pi integration" action (managed no-prompt session: readiness + models + shutdown), auto-compaction tri-state, model/thinking diagnostics, reset-Pi-permissions. **Not exposed:** arbitrary extension paths, built-in-tools toggle, extra launch args, third-party MCP extension, out-of-profile auto-approval.
- Rollback: `.pi` raw value is additive; all new keys namespaced; no migrations. Old builds may normalize persisted Pi sessions if resaved — release-note it for previews.

### 4.9 Headless — Phase 5, full-shaped (both moved)

`makeProvider(.pi)` throws deterministic-unsupported through Phase 4 — unreachable by the availability invariant: **Pi appears in a surface only in the phase where that surface's provider path works** (`piAvailable` off, discovery/`list_agents` land Phase 5, recommendation chains exclude Pi; tests prove no delegated path can select Pi prematurely). Phase 5 ships a full `PiHeadlessProviderAdapter` — ephemeral managed controller per `streamAgentMessage` call, same extension/readiness gate, torn down per call — which doubles as the registry's discovery probe.

## 5. Phases, acceptance criteria, estimates

Total ≈ **10–13 weeks**, one senior engineer (lanes estimated 10–11 wk and 9–13 wk independently).

| Phase | Work | Est. | Acceptance |
|---|---|---:|---|
| 0. Spike (blocker-capable) | Scripted harness against pinned `pi --mode rpc`: capture all fixtures; `steer`/`follow_up`/`abort` + `agent_end`→`agent_settled` ordering; extension load under `--no-extensions -e`; extension→MCP→RepoPrompt round trip incl. long-blocking approval tolerance; session identity + resume shape; models/levels (model-dependent?); image prompt shape; env passthrough; extension UI probe. | 1–1.5 wk | Every unverified item answered with captured JSONL evidence in `SPIKE.md`; go/no-go on approval blocking. **If extension tools cannot execute over RPC without an unserviceable Pi UI round-trip, do not ship — never auto-approve an uncontrolled surface.** |
| 1. Seam neutralization | §4.1 exactly; no Pi code. | 1 wk | Five-part regression gate in §4.1. |
| 2. Package + controller | `RepoPromptPiProvider`, bridges, `PiNativeProcessSessionController`, config/launch profile, `submit(mode:)` protocol method. | 2 wk | `make dev-provider-test` green; fixtures cover every event type incl. terminal malformed-line policy; root controller tests: turn FIFO, steer-returns-same-ID, mode-mismatch throws, abort→cancelled, settled-deferral + fallback, EOF drain, RPC timeout. |
| 3. Extension + MCP bridge | TS extension, build/CI + checksum, env contract, `pi_bridge_ready`/`pi_bridge_fatal` + disconnect observation, fail-closed gate. | 2 wk | Stub-MCP integration tests (exact tool exposure, cancellation, transport failure, no stdout pollution); installed-app smoke: tools listed + read-file call; approval-gated call blocks then completes; deleted artifact → pre-prompt failure; foreign-PID rejected; mid-run server kill → abort. |
| 4. Interactive wiring | Kind/binding sweep, coordinator/runner, RunService routing, steering flush, cancellation, tool tracking (`PiAgentToolTrackingHandler` — duplicate correlation core; reuse only if cleanly separable), TabSession fields, images. | 2 wk | Runner tests (terminal mapping, stale-turn filtering, runtimeInit fail-fast); coordinator tests (recycle rules, resume fallback + handoff, cancel teardown, ghost-turn race: post-settle steer throws → draft to fresh-run path); Claude focused suites green; smoke: streamed turn with thinking/text/tool cards, mid-turn steer without terminalizing, steer during an MCP call, clean cancel, session reuse. |
| 5. Catalog, settings, lifecycle, headless | Registry + probe, catalog arms, preferences, settings UI, `PiHeadlessProviderAdapter`, resume-across-restart, compaction/retry presentation, discovery. | 1.5–2 wk | Catalog snapshot tests (options/default/validation/display incl. thinking suffixes; permissive cold-start; no silent substitution); selection persistence round-trip; kill-app → relaunch → resume smoke; `list_agents` accurate; delegated Pi run works. |
| 6. Hardening + enable | Delete flipped aliases; stress fixtures; optional shared-consumer/tool-tracking/`AgentNativeRuntimeFamily` unification; docs (`provider-plugins.md` Pi section + alias-status update); flip `piAvailable` default-on atomically with the installed-app security smoke. | 1 wk | Full suite green; security smoke checklist passes (below); docs merged. |

Installed-app security smoke (Phase 6 gate): configured + automatic executable paths; extension integrity; fresh text and image prompts; MCP tool call with allow and deny decisions; steer during generation and during an MCP call; model + thinking change; restart + resume; cancel during generation/retry/MCP execution; compaction presentation; forced Pi process death; MCP server disconnect → abort; missing/corrupt extension → pre-prompt failure; malicious project-local extension/config ignored; no built-in bash/file tool exposure (bash event → security abort); expected-PID registration and cleanup.

## 6. Risks (ranked, merged)

1. **Extension tools require an unserviceable Pi UI approval round-trip over RPC** — Critical. Phase 0 is a release blocker; never bypass or auto-approve; ship-nothing is the fallback.
2. **Claude regression from seam work** — High. Promote-don't-wrap, no-logic-change rule, flipped aliases, five-part gate, single-revert PR.
3. **Pi launches with an uncontrolled surface** — Critical, mitigated by construction: hard-coded managed flags, `NODE_OPTIONS` strip, artifact checksum, tool-set equality attestation, bash-event abort, no user overrides.
4. **`agent_settled` ordering differs from assumptions** — High. Fixture-driven reducer; never inferred from event names.
5. **Mid-run MCP loss** — High. `pi_bridge_fatal` + disconnect observation → abort; structural worst case is tool-less, never uncontrolled.
6. **Crash recovery duplicating MCP side effects** — High. No auto-replay; fail the turn; resume only on explicit user action.
7. **Pi protocol drift (no versioned wire contract)** — Medium-high. `pi --version` supported-range probe at launch; unknown-event tolerance; per-version fixture recapture; pinned minimum version.
8. **Session resume fragility** — Medium. Opaque IDs, `get_state` verification, one-retry fresh + handoff.
9. **Catalog staleness / model removal** — Medium. Generation-guarded registry, versioned cache, no silent substitution.
10. **Node distribution variance** — Low-medium. `.preferShell` + path hints + executable override.
11. **Extension supply chain** — Low by construction. In-repo audited source, vendored pinned SDK, checksum + CI rebuild-diff.
12. **Rollback** — Low. Additive raw value; namespaced keys; preview release note.

## 7. Duel record

| # | Dispute | OracleB opened | OracleC opened | Outcome |
|---|---|---|---|---|
| 1 | Seam scope | Promote, don't wrap; logic-free Phase 1 | Full mapping adapter + protocol redesign + TabSession renames | **B** (C conceded round 2); B conceded the images hole → neutral prompt DTO |
| 2 | Readiness/health | Startup expected-PID handshake only | Unix status socket + descriptor + nonce + gate file | **Synthesis**: C's *requirements* (attestation + mid-run abort; B conceded), B's *mechanism* (in-band `pi_bridge_ready`/`pi_bridge_fatal` + disconnect observation; C conceded round 3). C corrected two factual errors under challenge: gate file unnecessary (expected-PID arms pre-spawn) and stdio transport wrong (bypasses expected-PID; HTTP required) |
| 3 | Codec strictness | Skip malformed lines | Terminal on malformed | **C** (B conceded round 2) |
| 4 | TabSession | Sibling `piController` fields | Shared renamed `nativeRuntimeController` | **B** (C conceded round 2); DEBUG one-controller assertion added; unification deferred to Phase 6 |
| 5 | Submission API | `sendUserMessage → UUID`, silent internal resolution | `submit(mode:) → SubmissionReceipt` | **Converged round 3** after both found the ghost-turn race: explicit modes, throw-on-mismatch, UUID return (B's final shape), active-turn-only flush with idle → error → fresh-run path (C's handling); receipt dispositions reserved as the spike-driven extension |
| 6 | Headless timing | Phase 5, probe-only | Full adapter pre-MVP | **B's timing + C's shape** (both moved round 2): Phase 5, full ephemeral adapter doubling as discovery probe |

## 8. Validation commands

```bash
make dev-provider-test                          # package iteration
make dev-test FILTER='ClaudeSDKNDJSONTranslatorTests|ClaudeCompatibleBackendEnvironmentTests|ClaudeNativeApprovalAndResumeTests|ClaudeCompatibleModelCatalogTests|ClaudeCompatiblePluginBridgeTests'   # Claude regression gate
make dev-test FILTER='Pi'                       # Pi suites as they land
make dev-swift-build PRODUCT=RepoPrompt         # root build incl. package
```

Implementation must check an `rg` inventory into the seam-sweep PR description: `switch .*AgentProviderKind`, `.usesClaudeNativeRuntime`, `.claudeController`, `.claudeExpectedTurnIDs`, `AgentProviderBindingID.allCases`, `AvailabilityContext` — resolving files outside the planning selection without improvising design decisions.
