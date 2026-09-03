> **Outcome (2026-09-03):** Implemented the bounded single-controller OMP thinking-capability sweep, lazy local OMP provider submenus, observable queue/progress states, deadline-first visible cleanup, runtime-version race protection, and regression coverage across resolver, controller, registry, menu, catalog, and AppKit boundaries.
>
> **Decision:** Position H is final: pure singleton effort-nil base/fast families render as adjacent `<family>` and `<family> Fast` leaves. Automatic background discovery starts only when a local OMP provider submenu opens, with the SwiftUI OMP-branch appearance fallback; explicit selection and manual Load remain single-model interactive requests.
>
> The original authoritative planning snapshot is retained intact below; this completion header supersedes its historical “Planned” status and open §4.5 action.

# Plan: Background OMP thinking-capability sweep and singleton `Default` collapse

Scope: read when the task touches OMP thinking-capability discovery (`OhMyPiThinkingCapabilityResolver`, `OhMyPiThinkingCapabilityRegistry`), the OMP provider submenu in Agent/Oracle/preset pickers, `StableMenuButton` submenu behavior, or OMP family-leaf presentation (`OhMyPiModelMenuProjector`, `OhMyPiThinkingMenuBuilder`, `OhMyPiModelMenuBuilder`, `AgentModelSelectionIndex`).
Authority: Authoritative
Last-verified: 2026-09-03

- **Status**: Planned — not implemented.
- **Date**: 2026-09-03
- **Origin**: Independent verification of a prior investigation session against live code, plus two independent Oracle planning lanes given an identical brief with a two-round anonymized adversarial exchange. Four of five material disagreements converged; one (§4.5) survived both rounds and is recorded with both positions and a recommendation.
- **Supersedes**: the "never hover" and "no cross-model queue" clauses of the lazy-discovery contract in [`oracle-remote-models-cursor-catalog.md`](../oracle-remote-models-cursor-catalog.md) (decision D3 / T5 of the completed `omp-transcript-authority-and-model-ux` plan). The catalog document must be rewritten atomically with the code (§5.5).

## 1. Problem

OMP CLI (Oh My Pi ACP) models reached through the Cursor provider — `cursor/cursor-grok-4.6`, `cursor/cursor-grok-4.6-fast`, `cursor/cursor-grok-4.5`, `cursor/gemini-3.7-flash` — show "Thinking levels have not been loaded." until the user presses "Load thinking levels…" for each model, waits more than ten seconds, then closes and reopens the menu. The user wants thinking levels loaded automatically in the background when the model menu is opened and the OMP CLI provider submenu is hovered/opened, so the levels are present when a model leaf is reached. Secondary defect: collapsed base/fast pairs render as `cursor-grok-4.6 → Default → (levels)` and `→ Fast → Default → (levels)`; the singleton `Default` layer is redundant.

## 2. Verified facts (live code, 2026-09-03)

1. **Exact-ID, per-version cache.** `OhMyPiThinkingCapabilityResolver.resolve` returns `.cached` only when `registry.snapshot(for:)?.ompVersion == currentVersion` (`OhMyPiThinkingCapabilityResolver.swift:242-250`); `OhMyPiThinkingCapabilityRegistry.warmStandardStoreIfNeeded` drops every persisted record whose version differs and rewrites the store (`OhMyPiThinkingCapabilityRegistry.swift:192-202`). Base, fast, and sibling models never share a record.
2. **Menus never start discovery.** Entry points are only `requestAfterExplicitSelection` / `requestManualRetry` (`Resolver.swift:206-230`), called from selection-commit sites (`AgentModelOptionsMenuContent.swift:359`, `AgentInputBar.swift:1157`, settings/Oracle pickers) and the Load row (`OhMyPiThinkingMenuBuilder.swift:135`).
3. **One OMP process per probe.** `OhMyPiThinkingCapabilityControllerProbeClient.probe` (`Resolver.swift:78-118`) creates a fresh MCP-disabled provider, calls `support(for:)`, bootstraps a controller, calls `setSessionModel`, and shuts down. `support(for:)` runs `OhMyPiACPLaunchResolver.probeSupportSerially` (`OhMyPiACPLaunchResolver.swift:110-172`), which invalidates the launch cache and spawns `omp acp --help`, `omp --help`, and `omp --version` (10 s timeout each) and is where `OhMyPiRuntimeVersionRegistry.shared.observe(version)` is called (`:169`). At cold launch the runtime version is therefore unknown until a preflight or a real session runs.
4. **Key mechanism — one round trip per model.** `ACPAgentSessionController.publishOhMyPiThinkingCapabilityIfAvailable()` (`ACPAgentSessionController.swift:3093-3107`) runs after session bootstrap (`:2605`) and after every verified config-option mutation response (`:2991`). One bootstrapped capability-only controller can call `setSessionModel` (`:715`) sequentially for N exact IDs and a record is published per switch. Whether OMP performs an upstream Cursor round trip per switch is **unverified**.
5. **The 8 s deadline does not bound the visible loading state.** `runWithDeadline` (`Resolver.swift:284-308`) races the probe against a sleep and calls `cancelAll()`, but the task group awaits the cancelled child, and the probe's shutdown is cancellation-shielded (`:101-118`). `.loading` (set at `:265`) persists until cancellation is observed and shutdown finishes. The existing test (`OhMyPiThinkingCapabilityTests.swift:313-331`) asserts disposal counts only; its fake throws immediately on cancellation (`:1244-1262`).
6. **Open stable menus never update.** `StableMenuPresenter.present` builds the whole `NSMenu` tree once (`StableMenuButton.swift:240-252`); the only delegate hook is `menuDidClose`. A root-level `onOpen` closure exists (`:23,53`). Submenus are plain `NSMenu`s with no delegate. `AgentInputBar` bumps `ohMyPiThinkingRevision` on capability/probe notifications (`AgentInputBar.swift:647-653`), which affects only the next build (`:1138`). The SwiftUI surface (`AgentModelOptionsMenuContent` view body, hosted by `AgentHandoffPopover.swift:638`) is reactive.
7. **Busy-skipped requests are silent.** `resolve()` returns `.busySkipped` (`:253-255`); both fire-and-forget entry points discard the outcome; rows branch only on idle/loading/failed (`OhMyPiThinkingMenuBuilder.swift:87-114`).
8. **Version invalidation empties the cache.** The user's `omp-thinking-capabilities-v1.json` held four records at `ompVersion 18.1.3` (three from manual Loads within two minutes, `cursor-grok-4.6-fast` from a later session/selection) while `omp --version` on PATH reported 18.1.5. Every OMP upgrade wipes all records; today the only refill is one model at a time.
9. **Catalog size.** The 18.1.3 fixture has 144 wire IDs (~120 under `cursor/`); accessory-eligible effort-nil leaves number roughly 50–70. Effort-encoded leaves are terminal and need no capability record.
10. **Presentation.** `OhMyPiModelMenuProjector.familyLeaf` titles effort-nil family leaves "Default" (`OhMyPiModelMenuProjector.swift:313-323`); the `Fast` container is added in the stable Agent menu (`AgentModelOptionsMenuContent.swift:976-983`), the SwiftUI menu (`:241-256`), and the settings/Oracle builder (`OhMyPiModelMenuBuilder.swift:133-145`). `AgentModelSelectionIndex` already titles these leaves `<family>` and `<family> Fast` (`AgentModelSelectionIndex.swift:228-241`).
11. **Timeouts are injectable.** `ACPAgentSessionController.RequestTimeouts(bootstrapSeconds:setConfigOptionSeconds:)` exists (`ACPAgentSessionController.swift:10-23`; default bootstrap 30 s; `setConfigOptionSeconds` is honored at `:2186`). Confirm at implementation that the controller initializer used by the probe factory accepts it.
12. **Pure base/fast pairs in 18.1.3**: `cursor-grok-4.5`, `cursor-grok-4.6`, `composer-2.5`, `gpt-5.4`, `gpt-5.5`, `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`. Mixed families (`gpt-5.2`, `gpt-5.2-codex`, `gpt-5.3-codex`, `gpt-5.1`) keep effort siblings.

## 3. Decisions (summary)

- Replace one-process-per-model probing with a resolver-owned **sweep**: one MCP-disabled, capability-only controller bootstraps once, walks a bounded priority queue of accessory-eligible exact wire IDs with sequential `setSessionModel`, publishes one record per switch through the existing hook, and disposes once.
- The **sole automatic trigger** is the OMP provider submenu actually opening (`menuWillOpen`), via a new lazy `StableMenuItem` submenu. No root-menu-open, launch-time, connection-time, render, restore, checkmark, or catalog-refresh triggers.
- The OMP provider submenu becomes **lazy**: children rebuild in `menuNeedsUpdate` before display, so hovering away and back shows fresh progress and levels without closing the root menu. Everything else stays static.
- Explicit selection and manual Load enqueue **exactly one ID at interactive priority**; they never start a broad sweep. `.busySkipped` is removed; a busy resolver enqueues/promotes instead.
- Bounds per pass: ≤24 background models, 30 s startup (preflight + bootstrap), 8 s per switch, 45 s post-bootstrap budget, remainder deferred to the next OMP submenu open; 3-consecutive-failure breaker; 60 s automatic-sweep cooldown after preflight/bootstrap failure (bypassed by explicit selection/Load).
- Visible `.loading` ends at the deadline **before** awaiting cancellation and shielded disposal (fixes fact 5), pinned by an elapsed-time test.
- Sweep progress, queued models, and unsupported models are **visible** in the menu.
- Singleton effort-nil `Default` layers collapse through one projector-owned `ModelGroup.Shape` consumed by all four surfaces; the exact rendering is the open item in §4.5.
- Registry remains the sole capability authority; no schema change; no negative records persisted; wire identities, stored selections, and commit-before-thinking ordering unchanged.

## 4. Material disagreements and resolutions

Two Oracle lanes received the identical brief. Arguments (never identities) were cross-relayed for two rounds.

### 4.1 Trigger — resolved: OMP submenu open only

- Position A: OMP provider-submenu `menuWillOpen` is the sole automatic trigger; root `StableMenuButton.onOpen` fires with no evidence of OMP intent and would spawn preflight plus an OMP process when the user opens the menu for another provider.
- Position B: both root `onOpen` (when OMP is selectable) and submenu open, for earlier lead time and SwiftUI parity, bounded by "root-open starts at most one pass per version".
- Round 1: the lanes swapped positions. Round 2: both settled on A after two coordinator-verified facts: the lead time root-open gains is the sub-second interval between clicking the chip and hovering the OMP item, not the bootstrap duration; and at cold launch the version is unknown until preflight (fact 3), so a root-open trigger on a fresh cache still pays the three help/version spawns. With the lazy submenu (§4.3) the user's symptom is fixed regardless of when the sweep starts.
- Hardening both lanes accepted: the build-time gate (`canSelectAgentInCurrentChat(.ohMyPi)`) is insufficient; the resolver rechecks OMP availability and a nonempty target set immediately before creating the session and cancels on later availability loss or version change.
- SwiftUI handoff popover (secondary surface, no verified submenu-open hook): `.onAppear` on the OMP branch of `AgentModelOptionsMenuContent`, harmless if it fires early because the request is cache-first and coalesced. Coordinator decision.

### 4.2 Bounds — resolved by coordinator after near-convergence

- Both lanes accepted 24 models per pass, a 45 s post-bootstrap budget, deferral of the remainder, a 3-consecutive-failure breaker, and a 60 s automatic-sweep cooldown.
- Startup deadline: 30 s (one lane's 15 s was withdrawn because preflight alone can spend up to three 10 s subprocess timeouts before bootstrap; 30 s also matches `RequestTimeouts.default.bootstrapSeconds`).
- Per-switch deadline: 8 s (one lane's 4 s was rejected because a client-side timeout cannot cancel OMP's server-side work; a late response would arrive on the same sequential connection while the next request is pending, poisoning a working model with a cooldown and cascading into the breaker). Tune from measured `elapsed` diagnostics before widening anything.

### 4.3 Static versus lazy OMP submenu — resolved: lazy, scoped

- Position A: keep stable menus static and tell the user to reopen. Position B: rebuild the OMP submenu in `menuNeedsUpdate`.
- Converged on B in round 1: `menuNeedsUpdate` is the sanctioned AppKit mutation point, fired for a submenu before it is displayed and never while it is tracked; the parent menu is untouched; the delegate is retained through `representedObject` like `StableMenuActionBox`. Constraints: only the OMP provider submenu is lazy; the rebuild closure reads only the registry, status store, and catalog (never SwiftUI `@State`); `menuWillOpen` may request the sweep, `menuNeedsUpdate` never starts discovery; no mutation after display. Fallback if tests show `menuNeedsUpdate` does not fire per display: static tree plus "reopen the menu for updates" wording.

### 4.4 Explicit selection when idle — resolved: single ID only

- Position A: an explicit selection with an idle resolver sweeps the selected model first and then the rest, "since the process is up anyway". Position B: selection and Load enqueue exactly one ID.
- Converged on B in round 1: fact 4 proves only one ACP round trip per switch, not that the upstream Cursor cost is nil; a selection in the Oracle dropdown or a preset editor would otherwise silently launch a catalog walk the user is not looking at, violating "keep async work visible" and "defaults balance cost". During a running sweep, selection/Load promote that ID to the next model boundary.

### 4.5 Singleton `Default` collapse — OPEN after two rounds

Both lanes agree on the seam: a structural `OhMyPiModelMenuProjector.ModelGroup.Shape`, derived from leaf structure (never from the word "Default"), consumed by the stable Agent menu, the SwiftUI menu, `OhMyPiModelMenuBuilder`, and `AgentModelSelectionIndex`; every inlined/hoisted row keeps the leaf-scoped commit for its exact wire ID; mixed and effort-encoded families keep their current hierarchy. They disagree on the rendering, and swapped positions in both rounds:

- **Position H — hoist to sibling leaves.** Replace the family container with two adjacent leaves titled `<family>` and `<family> Fast` (e.g. `cursor ▸ … cursor-grok-4.6 ▸ levels, cursor-grok-4.6 Fast ▸ levels …`). Arguments: one list, one choice dimension; each leaf looks like every other standalone leaf; checkmarks derive from the exact ID exactly as leaves already do; the titles are the ones `AgentModelSelectionIndex` already assigns, so menu and index converge; blast radius is bounded to the eight pure pairs in fact 12 and siblings sort adjacently.
- **Position I — inline under the family container.** Keep `cursor-grok-4.6 ▸ [Default, Off, Auto, Low, … ─ Fast ▸ [Default, Off, …]]`. Arguments: removes exactly the redundant layer while preserving family grouping, labels, namespace order, and the existing family-submenu test structure; smaller cross-surface change; the selected state transfers to the container label.
- **Coordinator recommendation: Position H.** Inlining places a *model* branch (`Fast`) inside a list of *thinking values*, next to `Low`/`Auto`, which is precisely the two-dimensions-in-one-list ambiguity the user complained about; it also needs a new "selected state transfers to the container" rule that is ambiguous when the fast leaf is selected. The "smaller diff" argument is outweighed by a UX-correctness defect, and all four consumers already share the projector so the cross-surface cost is one `Shape` read per surface. Grok-pair family-submenu tests are re-pinned to the sibling structure at equal strictness, not weakened.
- **Action**: the owner picks H or I before §5.4 is implemented. Everything else in this plan is independent of that choice.

### 4.6 Minor points settled by the coordinator

- **Version race during a sweep.** `registry.record` tags a record with the runtime version current at record time and prunes records that mismatch the *incoming* record's version (`Registry.swift:214-262`), so a late record from a sweep started under an older binary could mislabel or wipe fresh records. Resolution: the sweep client captures `OhMyPiRuntimeVersionRegistry.shared.currentVersion` after preflight; before every `setSessionModel` and inside the publisher closure it compares with the live value; on mismatch it drops the record, ends the sweep as `.cancelled(reason: .runtimeVersionChanged)`, and resets queued IDs to idle. No new gate type or registry field.
- **Cooldown keys** are `(exactModelID, ompVersion)` in memory; version invalidation clears old-version cooldowns and unsupported marks.
- **Namespace-submenu promotion** (hovering `cursor` reorders its pending IDs first) is an optional priority hint, not a trigger, and is deferred until the base sweep is measured.

## 5. Design

### 5.1 Trigger policy

- **Stable Agent menu (`AgentInputBar.agentProviderModelMenuItems`)**: emit `.lazySubmenu(agent.displayName, onOpen: { OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(…) }, items: { inputBarModelMenuItems(for: .ohMyPi) })` for `.ohMyPi` only.
- **Settings/Oracle/preset pickers** (`AIModelDropDown.swift:456`, `OptimizedModelPicker.swift:250`): wrap their OMP section in the same lazy submenu with the same trigger. Verify at implementation that both surfaces present through `StableMenuButton`; if a surface uses SwiftUI `Menu`, apply the `.onAppear` fallback.
- **Handoff popover** (`AgentHandoffPopover.swift:638` → `AgentModelOptionsMenuContent`): `.onAppear` on the OMP branch.
- **Trigger entry point** (`OhMyPiThinkingCapabilityResolver.swift`): `enum OhMyPiThinkingSweepTrigger { static func onProviderSubmenuOpen(wireIDs: [String], selectedRawModel: String?, workspacePath: String?, resolver: OhMyPiThinkingCapabilityResolver = .shared) }`, honoring the DEBUG `isDisabledForTesting` flag, computing targets synchronously via `OhMyPiThinkingSweepTargets.compute` and calling `resolver.requestSweep(_:)` fire-and-forget.
- **Gating inside the resolver, immediately before session creation**: OMP is selectable through the existing effective OMP connection gate (name the API at implementation; the picker's gate is the reference), a local (not remote-host) menu, and a nonempty target set after cache filtering. When the runtime version is unknown, preflight is permitted (it is how the version is learned) but bootstrap happens only if targets remain after re-filtering against the observed version.
- **Never** from construction, render, restore, checkmark evaluation, catalog refresh, app launch, OMP connection alone, or root `StableMenuButton.onOpen`.
- **Composition**: `requestAfterExplicitSelection` / `requestManualRetry` become wrappers over `requestPriority(exactModelID:workspacePath:manual:)`: idle → single-target run; busy → promote to the queue front (`.enqueued`). Manual Load bypasses the per-model and sweep-level cooldowns; explicit selection bypasses only the sweep-level cooldown.
- **Cancellation**: menu close never cancels. Cancel on OMP availability loss, runtime-version change, and app termination (hook at `AppDelegate.applicationWillTerminate`, `AppDelegate.swift:180`, or the `WindowStateManager` termination signal at `:910`; choose at implementation). Cancellation flips status first (§5.2), then awaits disposal.

### 5.2 Sweep engine

New file `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiThinkingCapabilitySweep.swift`:

```swift
struct OhMyPiThinkingSweepLimits {
    var startupSeconds: TimeInterval = 30      // preflight + bootstrap
    var perSwitchSeconds: TimeInterval = 8
    var workBudgetSeconds: TimeInterval = 45   // after bootstrap
    var maxBackgroundTargets = 24
    var consecutiveFailureLimit = 3
    var sweepFailureCooldown: TimeInterval = 60
}
enum OhMyPiThinkingSwitchResult { case loaded, cached, unsupported, failed(String) }
enum OhMyPiThinkingSweepEvent {
    case preflightFailed(String), bootstrapped(ompVersion: String)
    case willSwitch(String), switched(String, OhMyPiThinkingSwitchResult, elapsed: TimeInterval)
}
protocol OhMyPiThinkingCapabilitySweepClient: Sendable {
    func run(workspacePath: String?, limits: OhMyPiThinkingSweepLimits,
             nextTarget: @Sendable () async -> String?,
             report: @Sendable (OhMyPiThinkingSweepEvent) async -> Void) async throws
}
```

`OhMyPiThinkingCapabilityControllerSweepClient` replaces `OhMyPiThinkingCapabilityControllerProbeClient` (same provider/controller factory injection):

1. Preflight once (`support(for:)`), MCP disabled, `modelString: nil`. Failure → `.preflightFailed`, throw (starts the sweep cooldown).
2. Capture `OhMyPiRuntimeVersionRegistry.shared.currentVersion`; re-filter targets against same-version registry snapshots; if none remain, return without bootstrapping.
3. Bootstrap one controller with `dynamicModelPublicationPolicy: .capabilityOnly`, `RequestTimeouts(bootstrapSeconds: 30, setConfigOptionSeconds: 8)`, and a publisher that records only when the live version still equals the captured version.
4. Loop `while let id = await nextTarget()`: `checkCancellation`; version still equal, else end as version-changed; cached → `.cached`; `setSessionModel(id)` succeeded with a same-version record present → `.loaded`; succeeded without a record → `.unsupported`; thrown → `.failed(normalized)`. Continue on model-local failure; break on `ControllerError.invalidState`, transport loss, or the consecutive-failure limit (validate the exact error mapping at implementation; unknown errors are session-fatal).
5. Exactly one cancellation-shielded shutdown (existing `runCancellationShielded`).

Resolver changes (`OhMyPiThinkingCapabilityResolver.swift`, same actor):

- `activeSweep: SweepRun?` (`task`, ordered `queue`, `inFlight`, `done`, `total`, `startedAt`, `trigger`) replaces `busyModelID`. Keep `failedAtByModelID` keyed by `(id, version)`; add `sweepFailedAt: Date?` and in-memory `unsupportedModelIDs`.
- `requestSweep(_ request: SweepRequest)`: dedupe; drop cached, cooled-down, and unsupported IDs; cap at `maxBackgroundTargets`; mark `.queued`; start the runner if idle and not in sweep cooldown, else append to the live queue.
- `requestPriority(exactModelID:workspacePath:manual:)`: insert at the queue front; `.coalesced` if in flight, `.enqueued` if queued; interactive IDs are exempt from the background cap.
- `nextTarget()` is an actor method the client awaits, so promotions land between switches; an in-flight switch is never preempted.
- Ordering: selected exact OMP model first, then IDs dropped by the most recent version invalidation (in-memory hint set by `removeVersionMismatchesLocked` and the warm filter, cleared per model on `record`), then projection order.
- `Outcome` drops `.busySkipped`; adds `.enqueued`, `.cancelled`.
- **Deadline semantics (fact 5 fix)**: status is driven by client events and a resolver watchdog, never by child-task completion. On per-switch timeout, work-budget expiry, or `cancel(reason:)`: set in-flight → `.failed` (or `.idle` on lifecycle cancellation, with no cooldown), queued → `.idle`, sweep status → `.failed`/`.cancelled`/`.partial`; **then** cancel and await the child in a retained cleanup task. No new session starts until cleanup finishes; requests during cleanup remain visibly queued.
- Persist only successful registry records; queue/progress/cooldown/unsupported state is transient.

### 5.3 Observability

- `OhMyPiThinkingCapabilityProbeState` adds `.queued` and `.unsupported`.
- `OhMyPiThinkingCapabilityProbeStatusStore` adds `sweep: OhMyPiThinkingSweepStatus` (`idle`, `preflight`, `running(done:total:current:)`, `partial(loaded:deferred:)`, `failed(reason:at:)`, `completed(loaded:failed:unsupported:at:)`), posted through the existing `.ohMyPiThinkingCapabilityProbeStateDidChange` so `AgentInputBar`'s revision bump already covers it.
- `OhMyPiThinkingMenuBuilder.rows`: `.queued` → disabled "Queued — loading in background…" plus an enabled "Load now" (promotes); `.unsupported` → informational "This model does not advertise thinking levels." with no Load; `.loading` → disabled "Loading thinking levels…"; `.idle`/`.failed` unchanged.
- New `OhMyPiThinkingSweepStatusPresentation.headerItem(_:) -> StableMenuItem?` / `headerText` prepended to the OMP submenu in all three builders: "Loading thinking levels… 12/24 · cursor/cursor-grok-4.6", "Loaded 18 · 6 deferred — open this menu again to continue", "Thinking levels: 3 failed — hover away and back to refresh"; nil when idle. Lazy rebuild (§4.3) makes "hover away and back" the refresh gesture.

### 5.4 Presentation collapse (blocked on §4.5)

- `OhMyPiModelMenuProjector.ModelGroup.shape: Shape` where `Shape { collapsesNormal: Bool; collapsesFast: Bool }`; `collapsesNormal = isFamily && normalLeaves.count == 1 && normalLeaves[0].effort == nil`; `collapsesFast = fastLeaves.count == 1 && fastLeaves[0].effort == nil`. Never keyed off the "Default" title.
- Position H rendering: `collapsesNormal` → no family container; a leaf titled `group.title`, then the fast branch as a sibling — a leaf titled `"\(group.title) Fast"` if `collapsesFast`, else a submenu with that title. Otherwise the family container remains and a collapsed fast branch is a leaf titled "Fast". `groupItem` becomes `groupItems(_:) -> [StableMenuItem]` in both `ohMyPiModelItems` overloads and `OhMyPiModelMenuBuilder.stableMenuItems`; `ohMyPiModelGroupContent` emits the same views; `AgentModelSelectionIndex` reads `group.shape` for its titles so index and menu cannot drift.
- Position I rendering: family container kept; the singleton normal leaf's thinking rows inline under the container, a separator, then `Fast` (inlined likewise when singleton); container checkmark derives from the exact ID.
- Under either position: `Leaf.title`, sourceID/wireID, stored selections, `onBeforeApply` ordering, projector cache, `qualifiesAsFamily`, and `parseSuffix` are untouched.

### 5.5 Contract rewrite (`docs/context/oracle-remote-models-cursor-catalog.md`)

Rewrite, atomically with the code:

- The "Lazy capability discovery…" bullet: triggers become explicit selection, manual Load, and OMP provider-submenu open (never construction/render/restore/checkmark/catalog refresh/root-menu open/launch/connection); "one global probe with no cross-model queue" becomes "one global sweep session over a bounded priority queue (≤24 background targets per pass, 30 s startup, 8 s per switch, 45 s work budget, remainder deferred to the next submenu open); busy ⇒ enqueued/promoted, never skipped"; "approximately eight-second deadline" becomes the per-switch/startup/budget triple with visible loading bounded independently of shielded cleanup.
- The "explicit post-commit capability-probe sites … probes remain out of shared menu helpers" sentence: sweep triggers attach at the provider submenu in the owning surface, never inside `OhMyPiThinkingMenuBuilder`.
- The "Thinking menus are projections…" bullet: add queued/unsupported rows and the sweep header; open lazy OMP submenus rebuild before display and never mutate while tracked.
- The family-grouping bullet: add the `Shape` rule chosen in §4.5.
- Bump `Last-verified`. Add a one-line supersession note to the completed `omp-transcript-authority-and-model-ux.md` (D3/T5) and to the "Residual costs" bullet of `2026-09-03-omp-collapsed-cursor-thinking-accessory-plan.md`.

## 6. File impact

- `Sources/RepoPrompt/Infrastructure/UI/Components/StableMenuButton.swift`: `.lazySubmenu(title, onOpen:, items:)`; `StableMenuSubmenuDelegate: NSObject, NSMenuDelegate` retained via `representedObject`; `menuWillOpen` → `onOpen`; `menuNeedsUpdate` → rebuild from `items()`; `submenuItems` returns `items()` for tests. Land first.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiThinkingCapabilitySweep.swift` (new): limits, events, client protocol, controller sweep client, `OhMyPiThinkingSweepTargets`.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/OhMyPi/OhMyPiThinkingCapabilityResolver.swift`: sweep scheduler, priority queue, watchdog, cancellation, `OhMyPiThinkingSweepTrigger`; delete the one-shot probe client.
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/OhMyPiThinkingCapabilityRegistry.swift`: recently-invalidated-ID hint only; no schema change.
- `Sources/RepoPrompt/Infrastructure/UI/Agent/OhMyPiThinkingMenuBuilder.swift`: queued/unsupported rows; sweep header presentation.
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/OhMyPiModelMenuProjector.swift`: `ModelGroup.Shape`.
- `Sources/RepoPrompt/Infrastructure/UI/Agent/AgentModelOptionsMenuContent.swift`, `Sources/RepoPrompt/Features/Settings/Views/OhMyPiModelMenuBuilder.swift`, `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelSelectionIndex.swift`: shape-driven rendering and header.
- `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift`, `Sources/RepoPrompt/Features/Settings/Views/AIModelDropDown.swift`, `Sources/RepoPrompt/Features/Settings/Views/OptimizedModelPicker.swift`, `Sources/RepoPrompt/Features/AgentMode/Views/AgentHandoffPopover.swift`: lazy submenu / `.onAppear` triggers.
- Tests: `Tests/RepoPromptTests/AgentMode/OhMyPiThinkingCapabilityTests.swift` (resolver + menu-builder suites), `Tests/RepoPromptTests/AI/OhMyPiModelCatalogTests.swift`, the file owning `ACPAgentSessionControllerModeConfigTests`, new `Tests/RepoPromptTests/UI/StableMenuItemTests.swift`; add surgical rows to `Scripts/Fixtures/test-suite-contract-ledger.tsv` for new suites/methods.
- Docs: §5.5.

## 7. Tests

`OhMyPiThinkingCapabilityResolverTests` (fake `SweepClient` actor with scripted per-model results, a per-switch gate, and bootstrap/switch/disposal counters; replaces `ProbeClient`):

- `testSweepBootstrapsOnceAndSwitchesSequentiallyInPriorityOrder`
- `testSweepSkipsCachedCooldownAndUnsupportedTargets`
- `testSubmenuOpenWithFreshRecordsSpawnsNothing`
- `testColdVersionRefiltersAfterPreflightAndSkipsBootstrap`
- `testExplicitSelectionDuringSweepPromotesToFrontInsteadOfSkipping` (asserts `.enqueued` and observed switch order; `.busySkipped` no longer exists)
- `testIdleExplicitSelectionRunsSingleTargetOnly`
- `testManualLoadBypassesModelAndSweepCooldowns`
- `testSweepHonorsBackgroundCapAndWorkBudgetAndDefersRemainder`
- `testSwitchFailureContinuesSweepAndAppliesPerModelCooldown`
- `testConsecutiveFailuresAndInvalidStateAbortSweepLeavingQueuedIdle`
- `testWallClockTimeoutExitsLoadingBeforeDisposalFinishes` (fact 5 regression: client ignores cancellation for ~300 ms via a detached sleep under a 20 ms deadline; assert the in-flight state leaves `.loading` within deadline + 50 ms and disposals eventually equal 1)
- `testCancelOnAvailabilityLossOrVersionChangeResetsQueuedToIdleAndDisposesOnce`
- `testLateRecordFromChangedRuntimeVersionIsDropped`
- `testSweepStatusReportsMonotonicPartialProgress`
- Keep `testMenuConstructionStartsNoProbe`; extend it to build a `.lazySubmenu` without opening it.

`OhMyPiThinkingMenuBuilderTests`: `testQueuedStateRendersDisabledRowAndLoadNow`; `testUnsupportedStateRendersInformationalRowWithoutLoad`; `testSweepHeaderReflectsRunningPartialFailedCompletedIdle`; `testStableAgentSurfaceCollapsesSingletonDefaultBranches` (Grok pair; first row Default; commit precedes thinking write; only that wire ID's entry changes); `testStableSettingsSurfaceCollapsesSingletonDefaultBranches`; `testMixedFamilyKeepsContainerAndCollapsesSingletonFastLeaf`; `testEffortEncodedSingletonBranchesKeepContainers`.

`OhMyPiModelCatalogTests` (18.1.3 fixture): `testProjectorShapeForCollapsedPairsAndMixedGpt52Family`; `testSelectionIndexTitlesMatchProjectorShape`; `testSweepTargetsExcludeEffortEncodedLeavesAndOrderSelectedFirst`; projection bijection unchanged.

`ACPAgentSessionControllerModeConfigTests`: `testSequentialSetSessionModelPublishesCapabilityPerVerifiedSwitchUnderCapabilityOnlyPolicy` (two scripted switches → two records with distinct `modelID`s; `AgentACPModelRegistry.currentModelRaw` untouched).

New `StableMenuItemTests`: `testLazySubmenuRebuildsOnMenuNeedsUpdateAndFiresOnOpenOnlyWhenOpened`; delegate boxes survive tracking.

## 8. Risks and open questions

- **Per-switch upstream cost is unverified.** If OMP round-trips to Cursor on every `session/set_config_option`, 24 switches may be slow or rate-limited. The `elapsed` field in `.switched` and debug logging provide the measurement; tune limits from the first live run before widening.
- **Cursor auth/billing.** No prompt is sent, but model validation may touch Cursor auth. The breaker and sweep cooldown bound damage; confirm on the first live run in the CE debug app.
- **Coexistence with a real OMP session.** Two OMP processes for up to ~75 s; both publish into the same registry (`observedAt` ordering guard); `.capabilityOnly` keeps `currentModelRaw` untouched. Idle CPU/memory is the accepted cost.
- **Version wipe (fact 8).** The first submenu open after an upgrade is still cold; dropped-ID ordering restores the user's models first. An upgrade mid-sweep ends the sweep and the next open refills. Not changing the correctness rule that old-version records are discarded.
- **AppKit lazy submenu.** Rebuild only in `menuNeedsUpdate`; never mutate a tracking menu; verify delegate retention and per-display firing in `StableMenuItemTests`; fall back to static plus "reopen" wording if AppKit does not cooperate.
- **SwiftUI `.onAppear` timing** in the handoff popover is unknown; acceptable because requests are cache-first and coalesced.
- **Termination hook and availability API** are outside the verified selection; name them at implementation.
- **Behavioral breaks**: `.busySkipped` removed; `ProbeClient` fake replaced; "menu never starts discovery" tests are re-pinned to "menu *construction* never starts discovery; only submenu *open* does" at equal strictness.

## 9. Implementation order

1. `StableMenuItem.lazySubmenu` + `StableMenuItemTests`.
2. Probe states, sweep status, menu-builder rows, header presentation + tests.
3. Sweep client, resolver rewrite, trigger, targets, registry hint, fake sweep client + resolver tests (including the fact 5 elapsed-time test); `ACPAgentSessionControllerModeConfigTests` sequential-publication test.
4. Surface hookups (input bar, settings/Oracle pickers, handoff popover) — land 3 + 4 + the §5.5 doc rewrite atomically.
5. After the §4.5 decision: projector `Shape`, four consumers, index, tests, and the doc's grouping bullet.
6. Live measurement in the CE debug app (fresh approval at the relaunch boundary): time one cold sweep with stage timestamps; record per-switch `elapsed` and error classes; adjust limits only with that evidence.

## 10. Validation

```bash
make dev-test FILTER=OhMyPiThinkingCapabilityResolverTests
make dev-test FILTER=OhMyPiThinkingMenuBuilderTests
make dev-test FILTER=OhMyPiModelCatalogTests
make dev-test FILTER=ACPAgentSessionControllerModeConfigTests
make dev-test FILTER=OhMyPiACPHeadlessAgentProviderTests
make dev-test FILTER=StableMenuItemTests
make dev-lint
make dev-format-check
make dev-build
Scripts/check-agent-context
```

Unfiltered `make dev-test-parallel` before the contribution is pushed.

## 11. Out of scope

- Root-menu-open, launch-time, or connection-time sweeps (rejected on cost, §4.1).
- Namespace-submenu priority promotion (deferred, §4.6).
- Skipping `probeSupport`'s help/version spawns on a recently validated launch (possible latency win; separate change to `OhMyPiACPLaunchResolver`).
- Reading OMP's ACP source for a per-model config-options listing that avoids model switching entirely (would make the sweep near-free; investigate separately).
- Emission-time capability validation in `assignments(for:)` (already filed by the completed accessory plan).
