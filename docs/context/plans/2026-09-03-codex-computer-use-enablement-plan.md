# Codex Computer-Use Enablement Plan

Date: 2026-09-03
Status: **Plan only — not implemented.**
Scope: OpenAI Codex only. Claude Code computer use is out of scope (its built-in `computer-use` MCP server is interactive-only and incompatible with RepoPrompt's `-p` stream-JSON transport).

Provenance: drafted from two independent Oracle plan consultations (presets OracleE and OracleD, identical initial prompts, identities verified via `model_preset_id` on every turn), followed by two rounds of anonymous cross-challenge on the material disagreements. Load-bearing code claims were verified against live source in this session at the cited lines.

## 1. Background (verified)

- The entire Codex computer-use pipeline already exists in RepoPrompt and is deliberately gated shut:
  - `CodexOverrides.forcedDisabledConfig` (CodexOverrides.swift:4–21) forces `features.computer_use` (plus plugins, tool_search, tool_call_mcp_elicitation, tool_suggest) to `false`; `computerUseEnabledConfig` (23–30) re-enables them via `forcedConfig(featurePolicy:)` (199–211) when `FeaturePolicy.computerUseEnabled` is true.
  - `CodexComputerUseWorkflow.isEnabled` (CodexComputerUseWorkflow.swift:136–138) hard-codes `isEnabled(persistedValue: false)`, so the declared `enableCodexComputerUse` defaults key is dead; only the `RP_CODEX_COMPUTER_USE` env var or a DEBUG testing override can enable the feature today.
  - Activation flow when enabled: `/computer-use` slash turn → `CodexComputerUseActivation` staged per-turn (AgentModeViewModel.swift:~13762) → coordinator computes `wantsComputerUse` (CodexAgentModeCoordinator.swift:3788–3790) → feature-state diff forces controller reconnect (3796–3804) → `defaultAppServerConfigOverrides` emits the feature policy and force-inserts the `computer-use` MCP server (CodexNativeSessionController.swift:8054–8063) → post-turn settlement clears the activation and recycles the controller (~5758).
- Known hole: the `computer-use` server insertion happens **after** the `suppressThirdPartyMCPServers` narrowing, so Safe Managed (`.mcpSafeDefaults`, MCP-originated `agent_run`) sessions would get it re-enabled once the gate opens. `CodexNativeSessionControllerGoalConfigTests` (~309–316) currently asserts this bypass as intended.
- Precedent: Codex Goals is the one established pattern for persisted Codex Agent Mode booleans (`GlobalSettingsDocument` scalar → `GlobalSettingsManager` accessors (1357–1367) → app_settings key `agent_mode.codex_goal_support_enabled` (AppSettingsMCPService.swift:918–923) → `CodexAgentModeBooleanPreference` case → snapshot-store binding → change notification).
- The Codex desktop plugin (`computer-use@openai-bundled`) materializes an `[mcp_servers.computer-use]` entry in `~/.codex/config.toml` (verified on this machine), so `MCPIntegrationHelper.codexMCPServerEntries()` can see it today.
- The app is not sandboxed; macOS TCC prompts (Accessibility, Screen Recording) attribute to the Codex helper process, and debug (`com.pvncher.repoprompt.ce.debug`) vs release identities hold separate grants.

## 2. Agreed plan (both lanes converged; adopt)

### 2.1 Opt-in gate — full Goals mirror, default OFF

| Surface | Name |
|---|---|
| Document scalar | `GlobalScalarPreferences.AgentMode.codexComputerUseEnabled: Bool?` (nil → disabled, fails closed) |
| Manager accessors | `GlobalSettingsManager.codexComputerUseEnabled()` / `setCodexComputerUseEnabled(_:commit:)` |
| app_settings key | `agent_mode.codex_computer_use_enabled` (group `agent_mode`, label "Codex Computer Use") |
| Preference case | `CodexAgentModeBooleanPreference.computerUse` |
| Notification | `Notification.Name.codexComputerUseDidChange` |
| Binding field / mutation | `CodexToolSettingsBinding.computerUseEnabled` / `.computerUse(enabled:)` on the snapshot store |
| Env override (existing, retained) | `RP_CODEX_COMPUTER_USE` |

- `CodexComputerUseWorkflow` grows the same static surface as `CodexGoalSupport` (`@MainActor isEnabled` reading `GlobalSettingsStore`, `isEnabled(defaults:)`, `isEnabled(persistedValue:)`, `setEnabled`, `postDidChangeIfNeeded`); `CodexNativeFeatureGate.computerUse.defaultPersistedValue` stays `false`.
- **No migration** from the dead `enableCodexComputerUse` defaults key into GlobalSettings (a stale value must not silently enable the capability). The key remains only as the injected-`UserDefaults` test shim.
- Promoting `isEnabled` to `@MainActor` matches Goals; grep all call sites first (known callers at CodexAgentModeCoordinator.swift:1356, 2660, 3784 are MainActor-bound).
- Sidebar toggle added adjacent to the Goals row, with honest help text: enabling permits explicit `/computer-use` turns only; it does not activate anything by itself, grant macOS permissions, or bypass Codex approvals.
- Rollback safety: additive optional scalar; older binaries drop it on re-save and the gate reverts to OFF (safe direction).

### 2.2 Activation stays per-turn and slash-only

The global toggle is *capability* consent; the `/computer-use` invocation is *activation* intent. No session-wide mode, no persisted activation state, no prompt-content-based activation. The existing post-turn teardown (`settleCodexComputerUseActivationAfterTurn` invalidating the controller) is built around per-turn scope and stays unchanged.

### 2.3 Safe Managed exclusion (closes the verified bypass)

- Add `AgentProviderPermissionProfile.codexAllowsComputerUse`: `false` for `.mcpSafeDefaults`, `true` for `.userConfigured` / `.providerOverride`.
- Coordinator: require it in `wantsComputerUse` (~3788), in the activation-clear condition (~3786), in `validateNativeSlashCommand`'s `.computerUse` case (~1356, with a dedicated Safe Managed message), and in `shouldShowNativeSlashCommand` (~2660).
- Controller hardening (defense in depth for any future caller): in `defaultAppServerConfigOverrides`, compute `effectiveComputerUse = computerUseEnabled && !suppressThirdPartyMCPServers && entryExists` once and use it for **both** the `FeaturePolicy` and `appServerMCPServerOverrides`; the insertion at 8057–8063 no longer bypasses suppression. This prevents the half-enabled state (features on, server off) and blocks the side-feature bundle in Safe Managed mode.
- Factory clamp (cheap third layer, adopted from lane 1): in `codexControllerFactory` combine the incoming effective value with `!isKnowledge && permissionProfile.codexAllowsComputerUse` before capturing `computerUseEnabledProvider`.
- **Deliberate test-contract flip**: `CodexNativeSessionControllerGoalConfigTests` changes from asserting `mcp_servers.computer-use.enabled == true` under suppression to asserting `false`; add a non-suppressed case asserting `true`. Call this out in the PR — it is the intended behavior change, not a regression.

### 2.4 Side-effect features unchanged

`computerUseEnabledConfig` (plugins, tool_search, tool_call_mcp_elicitation, tool_suggest, tool_search_always_defer_mcp_tools) stays as-is: it is the verified provider contract for the plugin (server + skill discovered via tool search, approvals via elicitation), and its blast radius is bounded by the one-turn controller lifetime, Safe Managed denial, and immediate post-turn recycling. `CodexOverrides.swift` needs no functional change — only an updated comment on the elicitation flag. Validation item (not a fix): confirm a non-computer-use elicitation arriving during a computer-use turn surfaces as a pending interaction rather than hanging; document the limitation if it hard-fails.

### 2.5 Approval invariants

No changes to `approval_policy` / `sandbox_mode` / `approvals_reviewer` emission; RepoPrompt MCP auto-approval never extends to computer-use tools; the `renderProviderPrompt` safety block (clarify targets, confirm destructive/external actions, surface separation) stays. The elicitation auto-accept question is Disagreement A (§5).

### 2.6 TCC and messaging — static honesty, zero machinery

No entitlement changes, no TCC probing, no permission-management UI. Deliverables: toggle/app_settings descriptions stating that macOS prompts appear only when automation first performs protected actions, are attributed to the Codex helper (not RepoPrompt), and that debug/release identities need separate grants; one added `renderProviderPrompt` line telling the model to report OS-permission errors exactly and direct the user to System Settings → Privacy & Security rather than retrying. Append TCC guidance only on explicit Accessibility/Screen Recording errors — never inferred from generic failures.

### 2.7 Messages

- `disabledMessage` rewrite (current text falsely blames permissions setup): "Codex computer use is turned off. Enable Codex Computer Use in settings or set app_settings key 'agent_mode.codex_computer_use_enabled' to true to use /computer-use."
- New `safeManagedDisabledMessage`: "/computer-use isn't available in Safe Managed (MCP-initiated) Codex sessions."
- Present-but-disabled MCP entry: per-turn force-enable stands (the explicit invocation is the stronger signal); the saved preference is never mutated; note in the setting description.

## 3. File-by-file impact

| File | Change |
|---|---|
| `Features/AgentMode/Runtime/Codex/CodexComputerUseWorkflow.swift` | Notification, Goals-mirrored static surface, message rewrites, provider-prompt TCC line |
| `Features/Settings/Models/GlobalSettingsDocument.swift` | Add `codexComputerUseEnabled: Bool?` scalar + init param |
| `Features/Settings/Models/GlobalSettingsManager.swift` | Accessors mirroring 1357–1367 |
| `Features/AgentMode/Runtime/Codex/CodexAgentModeBooleanPreference.swift` | `.computerUse` case in all four switches |
| `Infrastructure/MCP/AppSettingsMCPService.swift` | `agent_mode.codex_computer_use_enabled` registration |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift` | `codexAllowsComputerUse` property |
| `Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | Eligibility in validate/show/run-path; Safe Managed rejection; notification-driven slash refresh |
| `Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift` | `effectiveComputerUse` clamp; suppression-respecting insertion; (Disagreement A outcome) |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift` | Mutation case, setter, reader, binding field (bind `false` in `.mcpSafeDefaults` — see §6) |
| `Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Factory clamp only |
| Sidebar tool-settings view (locate via `goalSupportEnabled` render site) | Computer Use toggle row + subtitle |
| `CodexOverrides.swift`, `AppBundle/*.template`, `AgentModeViewModel+TabSession.swift` | **No functional change** |
| Tests (see §7) | New + flipped cases |
| Routed doc (locate owner via `codex_goal_support_enabled` in `docs/`) | Durable facts: key, two-gate semantics, Safe Managed exclusion, per-turn force-enable, TCC attribution |

Unknowns to resolve at implementation time (source discovery, not new components): the `CodexToolSettingsBinding` UI consumer file, the `.codexGoalSupportDidChange` observer site, the coordinator gating test file, and any app_settings key-registry test.

## 4. Implementation order

1. Gate stack atomically: document scalar + manager accessors + `CodexComputerUseWorkflow` rewrite (surface, notification, messages).
2. Preference plumbing: `CodexAgentModeBooleanPreference.computerUse` + snapshot-store mutation/binding.
3. Extend `CodexGoalSupportDefaultTests` for the new scalar/shim; run it.
4. app_settings key (+ registry test if found).
5. Controller hardening + `CodexNativeSessionControllerGoalConfigTests` flip, atomically; run it.
6. `codexAllowsComputerUse` + coordinator eligibility + gating tests; run them.
7. Sidebar toggle + notification observer wiring.
8. Resolve Disagreement A/B outcomes (§5) once decided; add their tests.
9. Routed doc update; full `make dev-test` sweep.

## 5. Material disagreements (survived two cross-challenge rounds — OPEN)

Both lanes received identical initial prompts and then two rounds of anonymized cross-relay. On both disputes the lanes **swapped positions in round 1 and swapped again in round 2**, ending exactly opposed. Neither dispute is resolved; both positions and a recommendation follow. The recommendation is the session investigator's, not either Oracle's.

### A — Elicitation auto-accept under full-auto (`computerUseMCPElicitationAutoAcceptResult`, CodexNativeSessionController.swift:3754–3771)

Verified facts: the auto-accept fires only when ALL hold — effective computer use for the explicitly requested turn ∧ approval policy `.never` ∧ sandbox `.dangerFullAccess` ∧ request from the `computer-use` server — and marks the response `repoPromptAutoAccepted: explicit_computer_use_full_access`. When any gate fails, the fall-through (3605–3625) parses via `parseMCPElicitationRequest` and emits `.mcpElicitationRequest` for explicit user interaction, so an explicit-response route exists today either way.

- **Position "remove"** (final holder: lane 1): `.never`+`.dangerFullAccess` scope Codex's exec/sandbox surface and predate this feature; a computer-use elicitation carries per-app control grants for external desktop apps — a distinct TCC-mediated trust boundary, so reusing sandbox consent is consent-stretching and contradicts the "per-app approvals must surface" invariant. The gate has never been open in production, so removal strips nothing from a shipped flow and is a net code deletion.
- **Position "keep"** (final holder: lane 2): the full-auto election is not the computer-use consent — the global toggle and the per-turn `/computer-use` invocation are; the approval policy legitimately governs only *cadence*. Removing it makes computer use uniquely more interrupt-y than full-privilege shell under the same user election, breaking unattended operation (Codex elicits per-app grants lazily, so pre-granting is impossible). Every stricter configuration gets explicit elicitation via the verified fall-through; the audit marker preserves traceability.
- **Recommendation (investigator): keep, with hardening.** The two computer-use-specific opt-ins genuinely re-anchor consent, cadence parity with the user's chosen policy is the coherent contract, and the path is auditable and trivially deletable later if policy changes. Required hardening either way: tests proving failure of *any* gate falls through to `.mcpElicitationRequest`, and toggle/app_settings/doc text stating plainly that full-auto configurations auto-accept computer-use elicitations (marked in the record) while all other policies surface every grant. If the maintainer prefers the strictly conservative reading of "don't weaken approval flows," remove instead — the explicit-interaction route already works and nothing else in this plan changes.

### B — Local preflight for a missing `computer-use` MCP entry

Verified facts: the plugin materializes `[mcp_servers.computer-use]` in `~/.codex/config.toml` today, and RepoPrompt's own server insertion (8057–8063) already requires entry existence — so absent an entry, the turn currently runs with elevated feature flags but no RepoPrompt-enabled server, and the provider prompt instructs the model to state tool unavailability plainly.

- **Position "add preflight"** (final holder: lane 1): check `codexMCPServerEntries()` in `validateNativeSlashCommand` (fresh read; reject only on *absent* normalized entries; menu visibility unchanged; runtime fallback retained). Because it mirrors the exact runtime insertion condition, it cannot reject a turn the current implementation would have served, and it converts a guaranteed failure (controller reconnect with elevated flags ending in a model-mediated apology) into a deterministic actionable error stating only the observable fact.
- **Position "no preflight"** (final holder: lane 2): entry existence is necessary for *RepoPrompt's* insertion, not for *turn viability* across versions — a future Codex may self-activate the bundled server once `features.computer_use`/`plugins` are on, without materializing a config entry; a preflight would then hard-block a working setup until RepoPrompt ships an update, making RepoPrompt's reading of one config representation authoritative over Codex. Cost asymmetry favors soft-fail: the true-missing case costs one reconnect and a prompt-guided error; a false rejection deterministically blocks a working feature. Log entry absence as an actionable diagnostic instead.
- **Recommendation (investigator): no hard preflight; add the diagnostic log.** The minimal-change constraint and the cross-version authority argument outweigh the UX polish: the guaranteed-failure path already produces a user-comprehensible outcome via the provider prompt, while a false rejection has no user remedy. Adopt lane 2's delta: at activation time, when no normalized entry exists, log a diagnostic with install guidance (`expected [mcp_servers.computer-use] in ~/.codex/config.toml`); keep the provider-prompt fallback and turn-error surfacing. Revisit and add the (safe-by-construction-today) validation check only if real-world support burden shows users don't understand the model-reported failure.

## 6. Minor divergences resolved by the investigator

- **Safe Managed toggle display**: bind `computerUseEnabled: false` in the `.mcpSafeDefaults` snapshot branch (divergence from Goals, which binds the global value) — showing an ON toggle for a capability the profile blocks would be misleading. (Lane 2's position; lane 1 preferred showing the global value. Cosmetic; either is defensible.)
- **Factory clamp**: adopted (lane 1) as a one-line third defense layer even though coordinator + controller clamps make it redundant in current flows.
- **Message wording**: exact strings above are drafts; settle at implementation without re-consultation.
- **Dispatch-time revalidation** (lane 1): adopted in the narrow form — recompute the effective value at the existing feature-state comparison point (already where the coordinator computes it); no new revalidation pass.

## 7. Tests and validation

- `CodexGoalSupportDefaultTests`: missing scalar → disabled; explicit true/false; defaults shim; notification fires only on effective change; skip under `RP_CODEX_COMPUTER_USE` (mirror the `RP_CODEX_GOALS` skips).
- `CodexNativeSessionControllerGoalConfigTests`: flipped Safe Managed expectation; non-suppressed enable case; ordinary controller keeps the bundle off; missing entry synthesizes no override; start/resume parity.
- Coordinator gating suite (locate existing file): gate-off message, Safe Managed rejection + hide, standard-session allow, activation cleared on staged-then-ineligible, post-turn recycle, next-turn capability off.
- Disagreement outcomes add their own cases (A: any-gate-failure fall-through; B: absent-entry diagnostic).
- Runs: `make dev-test FILTER=<suite>` per stage, then a full `make dev-test` sweep. Manual smoke (visible-app actions need fresh approval at the action boundary): toggle-off rejection, direct-session `/computer-use` turn, next-turn teardown, Safe Managed `agent_run` denial.

## 8. Out of scope

Claude Code computer use (transport-incompatible); TCC management or entitlement changes; narrowing the Codex side-feature bundle; any change to RepoPrompt MCP auto-approval; session-wide computer-use mode.
