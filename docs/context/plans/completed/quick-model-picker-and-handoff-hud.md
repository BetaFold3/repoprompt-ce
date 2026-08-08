# Completed: Keyboard-First Quick Model Picker & Quick Handoff HUD

Outcome: Implemented batches 0–7 and the accepted independent-review corrections on 2026-08-08. The feature now provides configurable quick model selection and last-completed-reply handoff HUDs with source-pinned commits, cache-only remote presentation, and focused regression coverage.

Decision summary:
- Shipped stable defaults ⌥⌘K for Quick model picker and ⇧⌥⌘K for Quick handoff.
- Kept model indexing and keystroke ranking pure and snapshot-backed; remote HUD presentation never starts a catalog load.
- Centralized current-session revalidation and source-pinned handoff construction in Agent Mode VM seams while preserving existing provider, knowledge, raw-model, effort, and MCP-control rules.
- Added fail-closed last-reply resolution, including explicit failed/cancelled-turn exclusion, remote host-row mapping, and non-cancelling HUD suspension behind blocking overlays.
- Durable implemented guidance now lives in [Agent Mode quick model picker and handoff HUD](../../quick-model-picker-and-handoff-hud.md).

The original authoritative implementation plan follows intact for historical context.

---

# Plan: Keyboard-First Quick Model Picker & Quick Handoff HUD for Agent Mode

Scope: read when the task touches the Agent Mode quick model picker or quick handoff keyboard shortcuts, their typeahead HUD, the model-leaf search index, or the last-completed-reply handoff cutoff resolver.
Authority: Authoritative
Last-verified: 2026-08-08

Status: **Planned — not yet implemented**
Date: 2026-08-08
Provenance: two independent Oracle plans (presets OracleB, OracleC) over an ~110k-token curated selection, followed by two adversarial duel rounds on every material disagreement, then synthesis. Both lanes' preset identity was verified on every send. Prior to planning, two independent code investigations verified every load-bearing claim below against the source.

## 1. Feature

Two user-configurable keyboard shortcuts, each opening a snappy typeahead HUD:

1. **Quick model picker** (default ⌥⌘K): type e.g. `Fable high` → Enter selects Claude Fable 5 · High for the current Agent Mode session; `Sol xhigh` lists GPT-5.6 Sol XHigh and GPT-5.6 Sol Fast XHigh (plain before Fast), arrows + Enter select. Respects the mid-session provider-family lock.
2. **Quick handoff picker** (default ⇧⌥⌘K): same typeahead, but Enter hands off the **last completed assistant reply** to a new session on the chosen model. Cross-family selection allowed (forking is the supported family switch).

Snappiness contract: all catalog/transcript work happens once at presentation from in-memory state; each keystroke is pure in-memory ranking. No network, process, or provider discovery on the HUD path.

## 2. Consensus architecture (both Oracles agreed independently)

### 2.1 Pure model-leaf search index (new)
`Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelSelectionIndex.swift`

- `AgentModelSelectionLeaf`: Identifiable/Hashable row with a structured stable ID (source + agent + raw model + effort), a commit payload (`local(agent:modelRaw:reasoningEffortRaw:)` / `remote(agentID:modelID:effort:)` / host-default), title, provider subtitle, detail, `showsWarning` (Fast cost), `isCurrentSelection`, `catalogOrder`, and precomputed `AgentSessionSearchFields`.
- Builder flattens **existing catalog surfaces only** — zero hard-coded model names:
  - Codex: the pure option×effort expansion currently inside `AgentHandoffCodexEffortMenu` (see duel resolution D3 — it moves to this file; the popover keeps calling it via a thin forward). Fast variants arrive automatically from `AgentCodexModelRegistry.resolvedOptions`; bare options expand per `supportedReasoningEfforts`; optionless models use the popover's existing default/last-used effort resolution.
  - Claude family (`usesClaudeTooling`): `AgentModelCatalog.claudeMenu(for:agentKind:)` — encoded raws unchanged, effort support already filtered.
  - OpenCode: `openCodeMenu(for:)` flattened; Cursor: options as-is with the input bar's placeholder-default fallback rule (drop `isPlaceholderDefault` unless that empties the list); equality stays with `modelOptionIsSelected` (bracket IDs never rewritten).
  - Remote: `RemoteHostAgentCatalog.structuredAgentGroups` → one leaf per `RemoteHostEffortOption`; host-default leaf only in current-session mode (never a fork destination).
- Search fields: `.model` = full title + base display name + **effort display name as its own field** (so `high` word-prefix-scores High (+40) above XHigh's contains (+10) — the requested ranking falls out of `AgentSessionSearchMatcher` for free); `.secondary`/`.primary` = provider/agent display name; `.identifier` = raw model/agent IDs.
- Ranking: `AgentSessionSearchQuery.parse` + matcher score desc → `catalogOrder` asc → deterministic string tiebreak. Empty query = catalog order with current selection preselected. Display cap ~40–50 rows with an `isShowingLimitedResults` hint; the index itself is never capped.
- `isCurrentSelection` via existing equality (`modelOptionIsSelected`, Codex encoded-effort rules, remote modelID compare); exactly one row marked current.

### 2.2 HUD view model + view (new siblings — no nav-HUD refactor)
- `ViewModels/UI/AgentModelSelectionHUDViewModel.swift`: `@MainActor final class`, two modes (`switchModel` / `handoffLastReply`), phases `ready / unavailable(message) / committing`, published `query` (didSet → re-rank), `filteredLeaves`, `selectedLeafID`, `errorMessage`, `noticeText`, `isRouting`. Async-commit-capable from day one. Present = toggle on re-invoke; snapshot built once; wrap-around arrows; two-stage Escape (clear query, then dismiss); Enter guarded by phase; commit closure injected (testable without WindowState).
- `Views/Components/AgentModelSelectionHUDView.swift`: mirrors `AgentNavigationHUDView` chrome/key handling by **copying idioms, not extracting** (duel resolution D2); rows show provider icon, title, subtitle, current checkmark, `AgentModelSelectionWarningVisuals` for Fast; unavailable/error/committing/limit states; reduced-motion parity.
- **No digit-to-select fast path** (both Oracles independently): model names contain digits (`5.6`, `Fable 5`); digits must type into the query.

### 2.3 Shortcuts, notification, hosting
- `Infrastructure/Utilities/Shortcuts.swift`: two new stable `KeyboardShortcuts.Name`s (never renamed after release), defaults ⌥⌘K / ⇧⌥⌘K (fallback ⌥⌘M family if the final macOS collision check fails — defaults-only change).
- One new notification (`.showAgentModelSelectionHUD`) with `windowID` + mode userInfo, defined beside the nav-HUD notification declarations.
- `GlobalKeyboardShortcutsCoordinator.registerAgentShortcuts()`: two registrations posting through **the same guard the nav-HUD registration uses** (duel resolution D7: copy the actual symbol at implementation time; prefer the HUD-specific guard if two exist). No catalog/transcript work in the coordinator.
- `ContentRootShellView`: `@StateObject` HUD VM; overlay at nav-HUD zIndex; mutual exclusion both directions with the nav HUD; dismiss on blocking overlays and on `activeComposeTabID` change **unless `isRouting`** (handoff success switches tabs — the HUD owns its own dismissal); Escape/click-outside disabled while committing.
- `KeyboardShortcutsSettingsView`: two rows in the Agent & layout section.

### 2.4 Current-session mode (`switchModel`)
- **Gating is structural, not copied**: lift the input bar's exact `modelControlsDisabled` derivation into one `AgentModeViewModel` predicate (e.g. `modelSelectionInteractivity(tabID:) -> interactive | disabled(reason)`), and repoint the input bar at it so chip and HUD cannot drift. ⚠ The exact derivation site was not in the reviewed excerpts — locate via grep before lifting (expected: run-state + remote/pending conditions; the provider lock is NOT part of it — locked sessions still change same-family models, so the lock stays a per-agent *filter*, never a whole-HUD disable).
- Family filter: leaves built from `selectableAgents(forTabID:).filter(canSelectAgentInCurrentChat)` — inherits knowledge policy, provider lock, and Claude-native cross-family allowance with zero new rules. When the lock filtered anything, show `lockedAgentSelectionMessage` as notice text. Non-selectable families are *hidden*, not shown disabled.
- Remote sessions: leaves from the cached `RemoteHostAgentCatalog` only (host-default included, matching the input bar); commit via `selectRemoteAgentModel(rawModel:)` — never through local `selectedAgent` mutation.
- Local commit — **one shared VM method** (duel resolution D5): a main-actor `AgentModeViewModel` method taking (provider, rawModel, optional explicit Codex effort, sourceTabID) that revalidates tab/gate/family/option-existence, then runs the exact existing sequence: `AgentModelCatalog.updateLastUsedEffortIfEncoded` → `selectedAgent` → `selectedModelRaw` (didSet chain untouched — it owns lock revert, persistence, coordinator sync, Claude effort scheduling) → Codex `selectedReasoningEffortRaw` last. The input bar's `selectAgentModel` closure is rerouted through this method as a **verbatim lift**, landing only after characterization tests pin existing behavior (see §4). Never wrap in `isRestoringState` (it suppresses required side effects). Re-check gating at commit; on drift show an error, never mutate a stale session.

### 2.5 Handoff mode (`handoffLastReply`)
- **Config builder**: move the body of `AgentModeView.handoffConfig(for:)` (AgentModeView.swift:3420) into an `AgentModeViewModel` extension `makeHandoffConfig(for:windowID:)` (duel resolution D1: extension, not a Services class; no new public source-addressed API surface). **Pin `sourceTabID` at presentation**; closures re-resolve the session by ID at invocation and fail loudly if it's gone or the host changed — an async commit must never act on a newly active tab. Add source-addressed API overloads only if implementation shows `prepareHandoffToNewTab` re-reads `currentTabID` after suspension points. The view delegates to the extension; must land atomically with the view change; behavior-neutral for the per-message button.
- **Last-completed-reply resolver** (pure, in `AgentTranscriptServices.swift` beside the cutoff helpers): refuse order (1) `runState.isActive` → "Wait for the current reply to finish." (all active states, including approval/question waits); (2) `canForkCurrentSession == false` → "Nothing to hand off yet."; (3) structured transcript: walk turns newest→oldest, skip active turns, per turn try `conclusionActivityID` → recomputed conclusion (make `AgentTranscriptQualityRepair`'s private recompute helper internal and shared) → latest non-streaming displayable assistant/assistantInline activity; validate every candidate with `isValidHandoffExportCutoffRowID`; (4) legacy fallback only when `turns.isEmpty`: shared legacy-items→handoff-transcript helper (deduplicate `fallbackHandoffTranscript` into `AgentTranscriptIO`), last valid non-streaming assistant item; (5) remote: candidate must resolve via `remoteCoordinator.hostRowID(for:clientItemID:)` → else "This reply hasn't synced with the host yet." A compacted turn with no concrete assistant activity yields to earlier turns — never synthesize a cutoff from a summary row. User-only transcripts → "No completed assistant reply to hand off" even when `canForkCurrentSession` is true.
- Resolution + validation run once at presentation (same projection cost every mouse-path handoff already pays at commit); commit revalidates, so mutation between present and Enter cannot fork invalidly. Show a notice with a first-line excerpt of the target reply. If profiling shows pathological-transcript cost, the sanctioned fallback is commit-time-only validation.
- Leaves: local from `config.availableAgentsProvider()` × options — **no family filter**, but pre-filter knowledge-session destinations by the supported-provider policy (avoids the commit-time invalidParams error the popover can hit). Remote from `config.remoteCatalogSnapshot` excluding host-default; degraded catalog → unavailable state. Preselect the leaf matching the source session's current agent/model/effort (Enter-Enter = fork onto same model).
- Commit: leaf → `AgentHandoffDestination`, executed through the **extracted `AgentHandoffActionSupport`** (duel resolution D4): Codex canonicalization, `performHandoff` execution, success-only last-used-effort persistence, and local/remote/`.inDoubt` error formatting move function-unchanged out of `AgentHandoffPopover` behind a neutral non-view type; the popover keeps one-line forwards. `phase = .committing` + `isRouting = true` across the commit; on failure keep the HUD open with the formatted error (`.inDoubt` retains its no-blind-retry warning); never cancel an in-flight handoff (the fork may already exist); `prepareHandoffHeadless` already cleans up the destination tab on every throw path.

## 3. Duel resolutions (what the two Oracles disagreed on, and the outcome)

| # | Question | Resolution |
|---|---|---|
| D1 | Handoff config builder: VM extension vs Services class + source-addressed API overloads | **VM extension**, `sourceTabID` pinned at presentation and re-resolved (fail-loud) at invocation; no new public API surface unless implementation proves `prepareHandoffToNewTab` re-reads `currentTabID` across suspension points. (Both lanes cross-conceded; this middle ground satisfies both the race concern and the churn concern.) |
| D2 | Extract shared typeahead selection helper + panel chrome from the nav HUD now | **No.** Sibling copies the idioms; extraction is an explicit follow-up once *both* HUDs ship (rule of two — the second instance shapes the abstraction with evidence, and the shipped nav HUD isn't churned inside a feature PR). |
| D3 | Codex option×effort expansion location | **Relocate the pure expansion** from `AgentHandoffPopover.swift` into the Models-layer index file (layering: Models must not depend on view-file types); popover calls it via a thin forward — **no re-adaptation of the popover menu UI**. |
| D4 | Handoff commit support: call popover statics vs extract | **Extract `AgentHandoffActionSupport` now** (function-unchanged + forwarding shims): the feature adds a second cross-layer caller, triggering the same boundary rule as D3; the move shape is the same near-zero-risk one both lanes endorsed there. Sanctioned fallback if the statics turn out to interleave popover-local state: call them directly and extract as a follow-up cleanup. |
| D5 | Reroute the input bar's commit through the shared VM method | **Yes — final position of both lanes.** Verbatim lift of the closure body, additive-only revalidation (provably no-op for menu-originated selections), landing only after characterization tests (§4) pass unchanged. Flip to "HUD replays the sequence + parity test" only if the closure body proves non-linear or revalidation can't be proven no-op. |
| D6 | Drive-by fix: `isBlockingOverlayVisible` omits the remote device approval overlay | **Verify first; if confirmed, land as its own revertable commit** (not buried in the feature), applied to *presentation gating* as well as dismissal — a keystroke-capturing HUD above a device-approval prompt is security-adjacent. |
| D7 | Coordinator guard symbol (`guardedHUDWindowState` vs `guardedFocusedWindowState`) | **Implementation-time lookup**: use exactly the guard the `showAgentNavigationHUD` registration uses; prefer the HUD-specific variant if both exist. |

## 4. Test plan

Pure logic (highest value, no harness):
- **Index tests** (`Tests/RepoPromptTests/AgentMode/ModelSelection/`): Codex option×effort flattening incl. Fast variants and encoded efforts; Claude encoded raws + effort-support filtering; placeholder fallback parity with the input bar; dedupe by structured identity; remote current-vs-handoff policies incl. degraded catalog and host-default exclusion; `isCurrentSelection` for Claude-encoded and Cursor bracket cases; a fixture with arbitrary future model names proving no hard-coded catalogs.
- **Ranking tests**: `fable high` ranks High above XHigh; `sol xhigh` returns exactly the plain + Fast pair, plain first; multi-token AND; provider-name and raw-ID tokens; digits in query; empty query preserves catalog order with current row preselected; deterministic tiebreaks.
- **HUD VM tests**: present/toggle/mode-replace; selection preservation across re-rank; no option-provider calls after presentation (assert providers called exactly once); two-stage Escape; sync commit dismisses; async failure retains state + error; double-Enter guarded; `isRouting` across successful handoff; stale-tab rejection; `.inDoubt` wording; no digit fast path.
- **Cutoff resolver tests**: stored conclusion; recomputed conclusion; latest-assistant fallback; failed/compacted latest turn falls back to earlier turns; active-run refusal despite older completed reply; streaming excluded; assistantInline supported; grouped-history IDs accepted; legacy-items fallback; structured wins over conflicting items; user-only/empty → none; every returned ID passes `isValidHandoffExportCutoffRowID`.

VM/integration:
- **Characterization tests gating the D5 reroute**: existing input-bar selection outcomes (Claude encoded / Codex bare+effort / Cursor / placeholder), Claude effort persistence, Codex model-before-effort ordering, family/knowledge/active-run/stale-option rejection, side effects fire exactly once; existing input-bar tests pass unchanged after the reroute.
- `makeHandoffConfig` parity with the per-message path (local, remote-with/without host row); source session/host disappearing before commit; success-only Codex effort persistence; no preference mutation on failure.
- Shortcut catalog tests: both names present, stable, distinct.

Highest-risk seams needing **manual macOS QA**: ⌥⌘K/⇧⌥⌘K delivery vs system/app-menu bindings; text-field focus when the composer held focus; arrows/Enter/Escape on the minimum supported macOS; nav-HUD mutual exclusion; blocking overlays appearing while open; end-to-end local + remote handoff (real host-row mapping, `.inDoubt` after deliberate interruption); presentation latency with the largest OpenCode/remote catalogs and a long compacted transcript.

## 5. Implementation order

1. **Index** (incl. relocated Codex expansion + popover forward) + pure tests. Compiles alone.
2. **Cutoff resolver** (+ shared conclusion-recompute + shared legacy-transcript helper) + tests. Pure; de-risks the hardest correctness question early.
3. **VM surface** (atomic): `makeHandoffConfig` moved + view delegation; `modelSelectionInteractivity` predicate lifted + input bar repointed; shared selection-commit method + characterization tests + input-bar reroute; `resolveLastReplyHandoffTarget`.
4. **`AgentHandoffActionSupport` extraction** (function-unchanged + shims).
5. **HUD VM** (two-mode, async-commit-capable) + tests.
6. **HUD view + hosting + notification** in `ContentRootShellView` (atomic with 7 for end-to-end usability).
7. **Shortcuts**: names, coordinator registration (guard symbol lookup), settings rows.
8. **D6 overlay fix** as its own commit (if verified) + hardening + manual QA checklist + perf sanity + final collision check.

## 6. Edge cases (consolidated from both lanes)

Active waiting states count as in-flight; user-only transcripts refuse handoff; failed/compacted latest turns fall back to earlier turns; stale conclusion metadata recomputed; remote mapping absent → never substitute client UUIDs; degraded remote catalog → no handoff destinations (current-session mode mirrors the input bar); placeholder defaults hidden unless sole option; dedupe by destination identity, not display name; digits stay in the query; Fast warnings always visible; empty-query Enter commits the *current* selection, never an arbitrary first row; catalog mutation after presentation → stale-commit rejection, never silent remap; window closure during handoff → let the async finish, no rollback; no configured providers → useful empty state; pending staged-handoff sessions keep `defersProviderLockUntilSend` behavior; locked family with zero available agents → lock notice + empty-state message.

## 7. Open items to resolve during implementation

- Exact `modelControlsDisabled` derivation site (grep `AgentInputBar` props / composer state sync) — lift verbatim.
- The VM method behind the input bar's `actions.selectAgentModel` closure — the D5 lift target.
- `AgentNavigationHUDView`'s key-capture mechanism — mirror it exactly.
- Coordinator guard symbol (D7).
- Verify the `remoteDeviceApprovalManager` blocking-overlay omission (D6) before fixing.
- Final macOS-level ⌥⌘K / ⇧⌥⌘K collision check; fallback defaults if reserved.
