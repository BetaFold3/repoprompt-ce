# Agent Mode QoL: shortcut reliability, composer focus, toolbar cleanup, panel motion

Scope: read when the task touches first-press global-shortcut delivery, snippet-palette activation, new-session composer focus, the Agent Mode toolbar item set, or utility-panel/sidebar open-close motion.
Authority: Authoritative
Last-verified: 2026-08-16
Status: Duel-settled plan, approved for implementation; no code changed yet.

## How this plan was settled

A read-only trace produced findings F1–F6 (below), each re-verified against source. Two independently prompted Oracle lanes (presets OracleC and OracleB, identical prompts, plan mode) produced positions on decision points D1–D6, followed by one adversarial duel round on the two genuine disagreements (D2 routing, D5 mechanism). D4's dispute was settled by direct verification instead of debate. The residual D2 split was adjudicated on a verified structural fact. Final decisions below are binding for this work; deviations require re-justification.

## Verified findings

- **F1 — first-press shortcut misses.** `WindowStatesManager.updateKeyboardShortcutsState()` enables KeyboardShortcuts (Carbon hotkeys) only when some `WindowState.isCurrentlyFocused` is true. That flag arrives via deferred hops (Combine `.receive(on: RunLoop.main)`, then `Task.yield()` in `scheduleFocusUpdate`→`applyFocus`, then another in `scheduleFocusSideEffects`→`onFocusChanged`). A window can be natively key while `KeyboardShortcuts.isEnabled` is still false; the first press is dropped. Additionally `guardedFocusedWindowState()` reads the same stale flag, so even an enabled handler can no-op, and `first(where: isCurrentlyFocused)` can mis-route in multi-window.
- **F2 — snippet palette gate.** `.openPromptSnippetPalette` is posted unscoped; the receiving coordinator (`ResizableTextField.swift`) requires `window.isKeyWindow && window.firstResponder === textView` and silently no-ops otherwise. Clicking the composer first is effectively mandatory.
- **F3 — new sessions never focus the composer.** `createAndActivateSessionTab()` has no focus concept; both user-initiated callers (`WindowState.startNewAgentSessionFromGlobalShortcut`, titlebar accessory actions) duplicate a profile-blind swallow pre-check outside the VM. A working `@FocusState isInputFocused` seam exists (chat detail → `AgentInputBar` → `AgentComposerView` → `.focused()`); precedent: workflow selection sets it.
- **F4 — toolbar buttons are popover anchors with remote openers.** `.showRecommendationWizard` is posted from AgentModelsPopoverView, AgentOnboardingWizardView, and Settings' CheckRecommendationsButton; `.showMCPServerPopover` from `AgentOnboardingWizardViewModel.openMCPServerPopover`. Removing only the ToolbarItems strands those routes. `RecommendationWizardViewModel` is still needed for the workspace-creation auto-apply path.
- **F5 — utility panel dock/overlay policy is accepted.** Docks when detail ≥ 560pt protected transcript + 1pt divider + 320pt min panel (~881pt), overlays below. The always-dock rewrite is dropped: the user tiles 3–4 narrow windows and will widen when needed. `AgentUtilityPanelLayoutMetrics` and its tests stay as-is.
- **F6 — motion sluggishness is per-frame transcript reflow.** `.animation(_, value: store.isVisible)` above the whole presentation makes the docked HStack's detail-column frame interpolate, re-wrapping transcript text every frame. The transition on the panel is not the cost; the sibling frame interpolation is.
- **MCP Settings parity (verified, settles D4's gate).** `MCPSettingsView` already provides status indicator, per-window `windowToolsEnabled` toggle, Auto-Start, connections counter, Status Dashboard, and Force Stop Listener. `MCPServerPopoverContent` has no consumer outside `MCPServerToggleView.swift`. Full deletion of that file is safe.

## Settled decisions

### D1 — Native AppKit key/active state is the sole shortcut authority (unanimous)

- New `Sources/RepoPrompt/App/GlobalShortcutActivation.swift` with two types:
  - `GlobalShortcutTargetResolver` — pure, unit-testable decision layer over `WindowDescriptor { windowID, isNativeKeyWindow, isFocusFlagged, isClosing }`. Enablement = `appIsActive && settingsEnabled && ∃ tracked native key window (not closing)` — native-only. Target resolution = native key match first, `isFocusFlagged` fallback second (fallback resolves targets only, never enables).
  - `GlobalShortcutActivationController` — synchronous NotificationCenter observers with `queue: nil` (never `OperationQueue.main`, `Task`, or `receive(on:)`) for `NSWindow.didBecomeKey`, `NSWindow.didResignKey`, `NSWindow.willClose`, `NSApp.didBecomeActive`, `NSApp.didResignActive`. Each callback: read `NSApp.isActive`/`NSApp.keyWindow`, scan tracked windows, idempotent `ensureHandlersRegistered()`, write `KeyboardShortcuts.isEnabled` only on change (`lastAppliedEnabled` memo). No `@Published` writes, no persistence, no SwiftUI mutation on this path.
- **Single authority is the critical correctness point:** `WindowStatesManager.updateKeyboardShortcutsState()` keeps its name and call sites but its body becomes a delegate to the controller's `refresh()`. It must no longer compute from `isCurrentlyFocused`, or the deferred path can re-disable what the native path just enabled.
- `WindowStatesManager` gains `activeMainWindowState` (native-key-first, flag-fallback) and `refreshGlobalShortcutActivation()` (guarded by `isTerminating`). `WindowState.attachWindow` calls the refresh on attach and detach branches; register/unregister paths do the same (closes the became-key-before-attach gap, incl. the `isUITestSession` async `makeKeyAndOrderFront` path).
- `GlobalKeyboardShortcutsCoordinator`: `focusedWindowState()` → `activeMainWindowState`; `guardedFocusedWindowState()` = `NSApp.isActive` guard + that resolver (drop the stale `isCurrentlyFocused` re-check — it is the exact assertion that fails in the gap); `guardedHUDWindowState()` keeps its shape and latest-window fallback per the HUD doc contract.
- `WindowState`'s deferred `isCurrentlyFocused` pipeline is untouched (REPOPROMPT-1K4 hazard class: it drives SwiftUI, workspace-files side effects, and session persistence). It remains the UI/side-effect signal; it is no longer the Carbon authority.
- Deliberately preserved: only exact tracked `nsWindow` matches count. Settings windows, attached sheets, popover host windows keep global shortcuts disabled — same as today; comment this in the controller so nobody "fixes" it.

### D2 — Snippet palette: two-hop arbitration through ContentRootShellView (duel-settled; adjudicated)

Duel outcome: both lanes agreed HUD gating is mandatory (a snippet activation while the navigation or model-selection HUD is up would `makeFirstResponder` the composer underneath a visually live HUD — broken state). The residual split (expose HUD flags via `WindowState` vs arbitrate in `ContentRootShellView`) was adjudicated on verified structure: both HUD view models are `@StateObject`s local to `ContentRootShellView`; exposing them elsewhere means a mirrored shadow copy that future overlay authors must remember to maintain — the same silent-omission failure mode that produced F2. `ContentRootShellView` is already the overlay mutual-exclusion authority, so the gate lives there.

Mechanism:

1. **Poster** (`GlobalKeyboardShortcutsCoordinator.openPromptSnippetPaletteFromShortcut`): `guard let win = guardedFocusedWindowState()`; post `.openPromptSnippetPalette` with `windowID` only.
2. **Arbiter** (`ContentRootShellView.onReceive`): accept only when windowID matches, root route is Agent Mode, main window is key with no attached sheet, `!isBlockingOverlayVisible`, `!agentNavigationHUD.isPresented`, `!agentModelSelectionHUD.isPresented`. On acceptance, stamp the authoritative `tabID` from `viewModel.state.promptManager.activeComposeTabID` and synchronously post private `.performPromptSnippetPaletteActivation` with windowID + tabID.
3. **Receiver** (`ResizableTextField` coordinator, observing only the private name): pure static scope-match on windowID+tabID against a `SnippetPaletteScope` carried through `ResizableTextFieldFeatures` (new optional field; `agentInputBar(...)` gains one argument, supplied by `AgentComposerView` from its existing `windowID`/`currentTabID` — the entire surgical footprint in `AgentInputBar.swift` for this track). Then local re-validation (`isActive`, live text view, `isKeyWindow`, `attachedSheet == nil`), then **IME guard** `!textView.hasMarkedText()` (palette anchors an integer caret and commits by range replacement; marked text would corrupt), then:
   - not first responder → `guard textView.acceptsFirstResponder, window.makeFirstResponder(textView), window.firstResponder === textView` → `SnippetPaletteHelper.openSession(in:)` (**open, not toggle**, when focus was taken);
   - already first responder → `toggleSession(in:)` (unchanged toggle semantics).
- New `SnippetPaletteHelper.openSession(in:)`, idempotent when active; `toggleSession` becomes `isSessionActive ? dismiss() : openSession(...)`.
- `makeFirstResponder` strictly before opening: NSTextView focus acquisition can normalize the selection; opening first would anchor a caret about to move.
- Stale/mismatched targets are dropped, never re-targeted. No unscoped legacy acceptance.
- Doc impact: snippet activation joins the HUD mutual-exclusion set → update `docs/context/quick-model-picker-and-handoff-hud.md` (also for D1's resolver change) and bump Last-verified.

### D3 — New-session composer focus: one-shot UUID request, default off (unanimous)

- `AgentComposerFocusRequest { id: UUID, tabID: UUID, reason: .newSession | .newKnowledgeSession | .reusedPlaceholder }` published on the window-scoped `AgentComposerUIStore` (`agentModeVM.ui.composer`): `@Published private(set) focusRequest`, `requestFocus(_:)`, `consumeFocusRequest(id:)` (no-op unless id matches). UUID, not a counter — the payload must carry `tabID` and supersession must be decidable. It must NOT ride `AgentComposerProps`: `AgentComposerView` is `.equatable()` on props and would swallow or defeat it.
- `createAndActivateSessionTab(profile: AgentSessionProfile = .standard, focusComposer: Bool = false)`. Publishes after `syncAllActiveUIState()` on the success exit (`.newSession`/`.newKnowledgeSession`) and on the swallow exit (`.reusedPlaceholder`, targeting `priorTabID`) — the swallowed action focuses the existing placeholder instead of appearing broken. Failure exits publish nothing. Default `false` keeps every programmatic caller (handoff, MCP, first-send routing, restore) focus-neutral by construction; `rg 'createAndActivateSessionTab'` inventory confirms no other caller should opt in.
- Callers: `WindowState.startNewAgentSessionFromGlobalShortcut()` and both `AgentModeNavigationController` titlebar closures pass `focusComposer: true` and **delete their duplicated, profile-blind swallow pre-checks** — the VM's profile-aware check is the single swallow authority and the publisher for that path.
- Consumption in `AgentInputBar` (not the memoized `AgentComposerView`) via the existing `@FocusState`: `.onChange(of: composerUI.focusRequest)`, `.onChange(of: currentTabID)`, `.onAppear`, all funneling into one `apply` helper. Asymmetric mismatch handling: mismatch at publish time → leave pending (currentTabID is about to catch up); mismatch during a tab change → consume/discard (user navigated away; the request must not ambush later). On match: `isFocused = true`, then `consumeFocusRequest(id:)`.
- Pre-specified contingency (no new design decision if `.focused()` fails to move first responder into the hosted NSTextView in live validation): add `composerFocusToken: UUID?` to `ResizableTextFieldFeatures`, compare in `updateNSView` against a coordinator-stored last-applied token, `makeFirstResponder` on change. Do not build both mechanisms speculatively.

### D4 — Toolbar removal (unanimous; deletion gate settled by verification)

- Delete both `ToolbarItem`s from `ContentViewToolbarContent` plus its `recommendationWizardViewModel`, `showRecommendationsPopover`, `showMCPServerPopover` parameters. Remaining toolbar: principal title cluster (macOS 26 branch intact), update pill, utility-panel toggle.
- Recommendation wizard re-hosts as a sheet in `ContentViewSheetPresenter`, rendering the unchanged `RecommendationWizardPopoverView(viewModel:onDismiss:)` at width 480 with dismissal semantics copied verbatim (`markCompleted()` when `currentStep == .summary || !hasActiveRecommendations`). `ContentView`: rename state to `showRecommendationWizardSheet`; the `.showRecommendationWizard` callback ensures the VM exists, refreshes `.resetToIntro`, sets the flag; add the flag to `closeAllSheets()` (strict improvement: approvals and `.appWillRestartForUpdate` now dismiss it). All three remote posters keep posting `.showRecommendationWizard` unchanged. `RecommendationWizardViewModel` survives (auto-apply path).
- Onboarding MCP: `openMCPServerPopover()` → `openMCPSettings()` posting `.showMCPSettingsTab` with the same windowID; update call site and button label in `AgentOnboardingWizardView`.
- Retire: `Notification.Name.showMCPServerPopover`; `ContentView.showMCPServerPopover` state; `ContentViewNotificationHandler.onShowMCPPopover` + subscription; files `RecommendationToolbarButtonView.swift` and `MCPServerToggleView.swift` entirely (incl. `MCPServerPopoverContent` — parity verified) after `rg` reference audits. Untouched: `.showMCPSettingsTab`, `.showMCPStatusWindow`, `MCPStatusView`, MCP approval overlay.
- Accepted UX cost (surfaced and accepted by the user context): the yellow-lightbulb ambient `hasActiveRecommendations` signal disappears; Agent Models banner and Settings remain the discovery surfaces.

### D5 — Utility panel motion: declarative single-pass gutter + scoped overlay animation (duel-converged)

Duel outcome: OracleC conceded its manual mount/reveal/delayed-unmount state machine (functional failure modes — ghost/stuck panel under rapid toggling — bought to insure against a cosmetic one); OracleB conceded exit hit-testing and the animated double-click reset. Converged design:

- Remove the top-level `.animation(_, value: store.isVisible)` and both old transitions. No `withAnimation` may wrap any visibility or width mutation — hard prerequisite: `rg 'toggleAgentUtilityPanel'` and the panel's own close chevron; strip any ambient wrapper found.
- Structure inside the GeometryReader: `HStack(spacing: 0) { detail(); if docked+visible { Divider(); Color.clear.frame(width: panelWidth) } }` — the inert gutter snaps in a single unanimated pass (transcript reflows exactly once). Panel rendered in `.overlay(alignment: .trailing) { ZStack { if present { panelSurface.transition(reduceMotion ? .opacity : .move(edge: .trailing)) } } .allowsHitTesting(present) .animation(motion, value: present) }` with `.clipped()` on the container.
- Load-bearing details: the `.animation` value is a `Bool` (presence), not the geometry-derived struct — dock↔overlay threshold crossings produce no structural change and snap instantly; the modifier sits inside the overlay closure so its transaction cannot reach HStack siblings; `.allowsHitTesting` lives on the persisting container (a removing child freezes its last body) so the exiting panel is inert and clicks fall through to the already-final-width transcript.
- Resize drag stays per-frame unanimated with commit-on-release. **Double-click reset becomes unanimated** (affordance consistency with the drag, and reset has no single-pass option — the widths are complementary). Rule after this change: no width mutation is ever animated; only panel presence animates.
- Shared motion: new `AgentPanelMotion.reveal(reduceMotion:)` = `.snappy(duration: 0.18, extraBounce: 0)` / `.easeOut(duration: 0.10)` (macOS floor established by `ContentRootShellView.hudAnimation`, which stays untouched — pinned file). Sidebar: `AgentModeView.toggleAgentSessionSidebar` adopts the shared curve and gains the missing `@Environment(\.accessibilityReduceMotion)` — calibrated expectation: NavigationSplitView still owns the column slide; this is consistency + an a11y fix, not a reflow fix.
- Acceptance check: closing the panel must visibly slide, not vanish. Pre-specified fallback if the removal transition fails to run: offset-based reveal on a mounted panel (`.offset(x:).animation(motion, value: present)`) — continuous property, no transition semantics. OracleC's next-turn reveal deferral for open is granted on merits but gated behind measurement (DEBUG transcript-body counter): adopt only if an open-hitch is observed on a long transcript.
- `AgentUtilityPanelLayoutMetrics.Presentation` gains additive accessors: `panelWidth: CGFloat?` (nil iff hidden), `isDocked`, `isOverlay`, `reservedGutterWidth` (docked: panelWidth + dividerWidth; else 0). Policy and existing tests unchanged.

### D6 — Tests and validation (merged)

New suites:
- `GlobalShortcutActivationTests` (pure resolver): enabled iff app active + settings on + tracked native key window; foreign key window (Settings) disables; stale-flag multi-window case (A flagged, B natively key → target B); `isClosing` never enables nor targets; flag fallback resolves target but never enables.
- `SnippetPaletteShortcutRoutingTests`: the full scope-match table (window match/mismatch × tab match/mismatch/absent × nil scope).
- `SnippetPaletteActivationGateTests`: arbiter conditions as a pure function (route, key window, sheet, blocking overlay, both HUD flags).
- `AgentComposerFocusRequestTests`: publish, matching consume clears, stale consume no-ops, supersession.
- `AppNotificationContractTests`: `.showRecommendationWizard` / `.showMCPSettingsTab` raw values survive; onboarding VM posts `.showMCPSettingsTab` with the right windowID if constructible.

Extended suites (additive only, no weakening):
- `SnippetPaletteHelperTests`: `openSession` opens when inactive / idempotent when active; `toggleSession` still closes (regression guard on the refactor).
- `AgentModeChatSwitchActivationTests`: `focusComposer: true` publishes request with returned tabID; **default publishes nothing** (locks "programmatic never steals focus"); swallow + `focusComposer: true` → prior-tab request with `.reusedPlaceholder`; failed knowledge creation publishes nothing.
- `AgentUtilityPanelLayoutMetricsTests`: `reservedGutterWidth` values; invariant `reservedGutterWidth + transcriptWidth == availableWidth` across the existing stride; `panelWidth == nil ⇔ .hidden`.
- `KeyboardShortcutCatalogTests`: snippet notification key contract.

Live-only: first press after ⌘Tab/activation and after clicking the transcript; two-window routing; Settings-window-key disablement; palette focus-then-open incl. IME no-op and HUD/blocker no-op; caret in a brand-new session's composer (all four creation paths incl. swallowed placeholder); programmatic creation stays focus-neutral; wizard sheet from all three posters; onboarding → MCP Settings; panel open/close/rapid-toggle/drag/reset at both presets and with Reduce Motion; sidebar toggle feel. DEBUG objective check: transcript-body render counter (`AgentModePerfDiagnostics`) shows one width-attributable re-render per panel toggle, not ~11.

Gates: `make dev-lint` every Swift change; `make dev-build` for T1/T2/T4; `make guardrails` for T4 (file deletions) and this plan-doc routing change; per-track `make dev-test FILTER=` runs.

## Phased implementation order

0. **Spikes (no production code):** `rg` inventories (`createAndActivateSessionTab` callers; `toggleAgentUtilityPanel` ambient animation; deleted-type references), one live `@FocusState`→first-responder check.
1. **T1 shortcut authority (atomic, one commit):** `GlobalShortcutActivation.swift` + manager delegation + coordinator resolution + attach/register refresh hooks + tests + HUD-doc update. Splitting it would leave two authorities computing `KeyboardShortcuts.isEnabled` — worse than the bug.
2. **T3 new-session focus:** store seam + VM param + caller simplification + tests. Independent of Phase 1.
3. **T2 snippet palette:** notification keys + arbiter + scope plumbing + `openSession` + tests. Depends on Phase 1 for first-press posting.
4. **T5 panel/sidebar motion:** metrics accessors + tests first, then the layout restructure, then the sidebar curve. Independent.
5. **T4 toolbar removal:** wizard sheet re-host first (verify all three posters), then deletions + onboarding reroute, last (deletion-shaped diff, cleanest bisection).

## Risks and preconditions

- Two-authority race (T1): the old computation must be fully replaced by delegation, not left in parallel.
- Ambient `withAnimation` anywhere around panel visibility/width defeats T5 silently — the rg strip is a prerequisite, not a note.
- `.focused()` bridge to the hosted NSTextView is the one unverified seam in T3; contingency is pre-specified above.
- `AgentInputBar.swift` carries unrelated uncommitted edits — keep its diffs surgical (one added argument for T2; onChange/onAppear + one helper for T3).
- Removal-transition behavior (T5) has an acceptance check and a pre-specified offset fallback; the manual mount state machine is the third option only if both fail.
