# Investigation: Workspace-scoped remote run-target label

## Summary
Explicit New Session activation can cache a local `.thisMac` status projection before the workspace default binds the live session remotely; the later binding update does not invalidate the run-location/status snapshot. When binding succeeds, the label is stale but dispatch is remote; if the host default is absent, invalid, revoked, unavailable, or explicitly cleared, both label and dispatch are genuinely local.

## Symptoms
- A new session opened from a workspace-scoped remote-control screen shows `Run on: This Mac`.
- The expected label is `Run on: <remote host name>`.
- The actual selection may already default to remote execution, suggesting a presentation/source-of-truth defect rather than an execution-routing defect.
- The `Run on` control appears to lack the background layer used by nearby controls such as `Work locally` and `Workflow`.

## Background / Prior Research
### Git archaeology
- Commit `73de0268b7eae912b8d2af82f36736b19fcfe48f` (`N6 add remote coexistence UI`, 2026-07-04) introduced `AgentRunLocation`, `AgentRunLocationPill`, and the status-row placement before the existing execution/workflow controls. The history probe found the run-location pill's stronger outline/background treatment was present at introduction rather than added by a later regression.
- Commit `cac1560e71f6cc89c9a2e4d7bec772f7d2a6e627` (`WIP workspace scoped remote control v1`, 2026-07-12) introduced `WorkspaceModel.defaultRemoteHostID`, the workspace run-location picker, and one-time application of that default to new/lazy sessions. History indicates `nil` intentionally represents local execution and an explicit later `This Mac` choice must not be overwritten.
- Later commits `311d87f0`, `96c51f59`, and `4c633ba8` intentionally evolved remote-host text from a full name to collision-aware/uppercase abbreviations while retaining full names for tooltip/accessibility; no label regression was identified in history.
- Current-history assessment: the likely defect is in the interaction between workspace scoping and new-session initialization/presentation, not a later change to the literal `This Mac` string. The style concern appears to be an original visual inconsistency or emphasis decision, not a regression.

## Initial Assessment / Hypotheses
1. **Presentation fallback mismatch:** the selected remote-host identifier is correct, but the label resolves before the remote-host catalog/metadata is available and falls back to the local label `This Mac`.
2. **Split source of truth:** workspace scope determines remote routing at start/dispatch time while the composer/menu owns a separate target state that still initializes as local.
3. **Asynchronous initialization race:** a new-session default is set before workspace-scoped remote context arrives, and the label does not recompute or the state is not synchronized afterward.
4. **True default-selection bug:** the UI and underlying selected value are both local, while a later layer silently routes remotely because the screen itself is host-scoped.
5. **Styling inconsistency:** the run-target control uses a plain/menu-specific style or omits the shared background modifier applied to the adjacent mode/workflow controls.

## Investigator Findings

### Verdict

The primary hypothesis is **confirmed at the code-path level, conditional on workspace-default binding succeeding**. Explicit New Session activation can publish and materialize the new tab while its live `TabSession.remoteHost` is still `nil`; the status store can therefore cache `.thisMac`. The explicit creation method then installs the remote binding, but `updateBindingsFromSession` has no remote-host/run-location/full-status-snapshot invalidation check, so the cached pill can remain `Run on: This Mac`. The live session is nevertheless remote-bound, and first-send dispatch takes the remote branch from that live binding.

There is no runtime trace for the reported instance, so source evidence cannot prove that its stored host was present and non-revoked at that moment. If default application failed, the label and dispatch are genuinely local instead. Confidence is **high** in the lifecycle defect and **conditional** for the specific reproduction.

### Current-HEAD causal ordering

1. **Both explicit New Session entry points converge.** The titlebar handler calls `createAndActivateSessionTab()` at `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeNavigationController.swift:46-55`; the global shortcut calls the same method at `Sources/RepoPrompt/App/WindowState.swift:693-703`.

2. **Prompt creation makes the new compose tab look linked before Agent Mode applies the workspace default.** `createBlankComposeTab(createAgentSession: true)` allocates a fresh UUID at `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:2659-2662`, and the blank-tab constructor stores it in `ComposeTabState.activeAgentSessionID` at `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:3699-3712`.

3. **Activation is published synchronously before blank-tab creation returns.** `createComposeTab` appends the tab and assigns `activeComposeTabID` before awaiting tab-state application and before returning at `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:2638-2650`. The property's `didSet` synchronously posts `.activeComposeTabChanged` at `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:136-146`.

4. **Agent Mode can materialize and publish the new session while it is local.** The notification observer immediately calls `onTabChanged` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:2630-2640`. Because the compose tab already carries an explicit session ID, `session(for:createIfNeeded:false)` is allowed to create and persistently link a `TabSession` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:3496-3518`; its remote binding initially defaults to `nil` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift:195-196`. `onTabChanged` applies the materialized session to the active bindings at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:3197-3277`, and a successful active-binding application performs a full UI sync at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:8139-8228`. SwiftUI's tab-change path provides another publication opportunity: it synchronizes composer state and then status-pill state at `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift:180-186` and `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift:225-231`.

5. **That pre-default projection is literally `.thisMac`.** `makeStatusPillsSnapshot` obtains run-location props at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:4-21`; `runLocationSelection` returns `.thisMac` exactly when the supplied/live session has no `remoteHost` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:91-94`. The snapshot is owned and cached by `AgentStatusPillsUIStore` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentStatusPillsUIStore.swift:55-81`, and the row renders that cached snapshot at `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentStatusPillsRow.swift:12-31`.

6. **The remote workspace default is installed only after Prompt creation returns.** `createAndActivateSessionTab()` awaits `createBlankComposeTab`, reacquires/materializes the session, marks it fresh, applies the workspace default, and only then calls `updateBindingsFromSession` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:17020-17032`. `applyWorkspaceDefaultRunLocationIfNeeded` reads `WorkspaceModel.defaultRemoteHostID` and delegates to host binding at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:290-299`. On success, `applyHostRunLocation` writes `AgentSessionRemoteHostBinding`, pins the host-default model, and starts catalog loading at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:261-287`.

7. **The successful binding need not invalidate the cached status snapshot.** `updateBindingsFromSession` invalidates status pills for tab identity, run state, agent/provider, permissions, workflow, and guidance changes, but nowhere compares `session.remoteHost`, `runLocationProps`, or a complete next `AgentStatusPillsSnapshot` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:8650-8840`. The host-default model comparison invalidates composer/runtime/run-interaction state rather than status pills at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:8797-8801`, and the final derived-props equality fallback checks only composer props at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:8833-8837`. Once the cached snapshot already has the new tab ID, a remote-host-only change can therefore leave `.thisMac` intact. A later explicit/full status sync will recompute the correct host and heal the display.

### Lazy first-tab counter-evidence and one-shot gates

The initial `T1` tab of a fresh workspace follows a materially different order. `makeComposerSubmitTarget` materializes the absent session and applies the workspace default only when there was no existing session, no linked/persisted active session, and the session is eligible for an initial location at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift:65-84`. The view then synchronizes the status store after composer synchronization at `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift:162-185`, so the status projection normally sees the already-bound session. `makeComposerProps` itself captured the old optional session before `makeComposerSubmitTarget` could materialize it at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift:4-23`, but that smaller one-call composer staleness does not explain the separately synchronized Run on pill.

The automatic default is intentionally one-shot:

- The lazy seam requires `existingSession == nil`; after materialization, later composer syncs do not reapply a missed or explicitly cleared default (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift:65-84`).
- The explicit New Session seam invokes default application once after linked-tab creation (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:17020-17032`).
- Host application requires an unbound, unsubmitted session plus a registry record that exists and is not host-revoked (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:255-287`).
- Initial-location eligibility excludes system workspaces and, when a session exists, MCP/parent/handoff, sent, active/provider-bound, worktree-bound, or nonempty sessions (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:195-215`).
- Persisted/hydrated and MCP materialization paths deliberately do not inherit the workspace default; current tests document that contract at `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:239-262`.
- An explicit `This Mac` selection clears `session.remoteHost` at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:301-354`. During a sessionless first send, the source's pending state is copied to the new destination unconditionally, so a source-side `nil` binding overwrites the destination's automatic workspace binding at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:11941-11949`.

The lazy-path behavior and one-shot local override are covered directly by `testFreshWorkspaceDefaultTabAutoBindsLazyComposerSessionExactlyOnce` at `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:211-237`.

### Authoritative target and actual dispatch

`AgentRunLocation` is a user-facing projection; its own documentation says the remote session binding remains the source of truth at `Sources/RepoPrompt/Features/AgentMode/Models/AgentRunLocation.swift:3-9`. The live pre-start authority is `TabSession.remoteHost` (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift:195-196`), and persistence carries the same `AgentSessionRemoteHostBinding` at `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift:129-158` and `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSession.swift:257-258`.

Actual send routing does not read the status pill or independently infer a target from workspace scope. `submitPreparedUserTurn` enters its remote start/steer branch when and only when the live `session.remoteHost != nil`; otherwise it falls through to local provider dispatch at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:13026-13113`. The remote coordinator requires that same binding, resolves the connection with `binding.hostID`, and rejects an unbound session at `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift:257-269`. Remote start then records the returned remote session ID back into the binding at `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift:107-142`.

Therefore:

- If workspace-default application succeeded, the stale `This Mac` pill is a **pre-send presentation defect**; first dispatch is logically remote.
- If the live binding is `nil`, dispatch is genuinely local. Workspace scoping does not silently override it to remote.

### Host validity, revocation, and genuinely local outcomes

A new session remains genuinely local when the workspace/default is absent at the one-shot seam, `defaultRemoteHostID` is `nil`, registry loading/validation throws, the ID is missing, or the record is revoked. The workspace field and nil default are defined at `Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift:374-375` and `Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift:409-442`; registry lookup semantics are at `Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:44-69`; application rejection is at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:261-299`. A user can also make the state genuinely local by explicitly selecting `This Mac`, including the first-send reconciliation described above.

Timing matters for host loss:

- Missing/revoked **before binding** causes application to fail and leaves `remoteHost == nil`, hence local dispatch.
- Removal/revocation **after a binding already exists** is not shown here clearing that binding. The run-location projection remains `.host` (or the pill is hidden if there are no usable host options), and dispatch still enters the remote branch, where connection/start may fail. It does not silently fall back to local.
- The first-send success epilogue explicitly handles a host removed/revoked while reapplying the source tab's binding by leaving that source unbound and clearing the pinned-host sentinel at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:11997-12008`.

### Label and catalog fallback analysis

The missing-host/catalog hypothesis is **eliminated as an explanation for the literal `This Mac` label on a still-bound session**:

- Projection is binary: no binding produces `.thisMac`; a binding produces `.host(hostID:)` (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:91-94`).
- For `.host`, the visible label falls back from current host-option abbreviation to the stored binding abbreviation/display name and finally the literal `Remote host`; it never falls back to `This Mac` (`Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRunLocationPill.swift:12-21`).
- If the registry exposes no usable host options, `runLocationProps` returns `nil` and the control is hidden instead of changing a bound selection to `.thisMac` (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift:25-45`).
- A missing model catalog returns a degraded catalog for model-selection UI at `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:1115-1123`; it does not determine the run-location label.
- The workspace settings picker is a separate projection: an invalid/unpaired stored default resolves visually to local and says `This Mac (previous host unpaired)` at `Sources/RepoPrompt/Features/Workspaces/Views/WorkspaceRunLocationPicker.swift:18-45`. That can predict a later failed default bind and truly local new session, but it cannot transform an already selected live remote binding into the exact Run on pill label `This Mac`.

### Styling evidence

The alleged missing background layer is **not present in current source**. All three adjacent controls use `.background(.ultraThinMaterial)` and the shared `AgentPillMetrics` geometry:

- Run on: `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRunLocationPill.swift:82-102`
- Work locally/execution location: `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentExecutionLocationPill.swift:91-125`
- Workflow: `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentWorkflowPill.swift:29-33` and `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentWorkflowPill.swift:78-89`
- Shared height, padding, and corner radius: `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentStatusPillMetrics.swift:9-21`

The factual inconsistency is the **neutral outline policy**:

- `Run on: This Mac` uses `.secondary` as its accent and always strokes `opacity(0.35)` at `0.8` pt (`Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRunLocationPill.swift:51-57` and `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRunLocationPill.swift:97-102`).
- An ordinary enabled local Work locally pill uses `secondary.opacity(0.15)` at `0.5` pt through `usesNeutralChrome` (`Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentExecutionLocationPill.swift:73-85` and `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentExecutionLocationPill.swift:118-125`).
- Workflow with no selection also uses `secondary.opacity(0.15)` at `0.5` pt, while selected workflow states use stronger accented chrome (`Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentWorkflowPill.swift:80-89`).

It is a product/design judgment whether local Run on should adopt the lighter adjacent neutral outline. Git blame and commit `73de0268b7eae912b8d2af82f36736b19fcfe48f` (`N6 add remote coexistence UI`, 2026-07-04) show the material background and stronger `0.35/0.8` outline arrived together at introduction on current lines `AgentRunLocationPill.swift:80-102`; provenance does not establish design intent.

### Test coverage and gap

Existing tests establish important neighboring contracts:

- Direct workspace-default binding, pinned model, and direct `runLocationProps`: `testWorkspaceDefaultAutoBindingPinsModelAndPill`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:71-99`.
- Missing/revoked/already-bound/submitted host-application rejection: `testHostRunLocationApplicationRejectsExistingSubmittedAndRevokedSessions`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:101-122`.
- Explicit local clearing/persistence: `testSelectingThisMacClearsWorkspaceDefaultBinding`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:124-166`.
- Lazy first-tab one-shot binding: `testFreshWorkspaceDefaultTabAutoBindsLazyComposerSessionExactlyOnce`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:211-237`.
- MCP/hydrated exclusion: `testMCPAndHydratedSessionCreationPathsDoNotAutoBindWorkspaceDefault`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:239-262`.
- Remote binding/model propagation through first send: `testFreshWorkspaceFirstSendCarriesBindingAndPinnedModelToDestination`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:264-286`.
- Genuine local first-send dispatch after explicit override: `testExplicitThisMacSelectionOnFreshTabSendsLocallyAndSticks`, `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:288-342`.
- Workspace default persistence and legacy nil decoding: `Tests/RepoPromptTests/Workspaces/WorkspaceRemoteHostBindingTests.swift:7-64`.

The lifecycle regression itself is uncovered. The only assertion in `AgentRunLocationTests` against `ui.statusPills.snapshot.runLocation` is the explicitly synchronized empty-registry case at `Tests/RepoPromptTests/AgentMode/AgentRunLocationTests.swift:6-18`. No test creates an explicit workspace-default session with `createAndActivateSessionTab()` and immediately asserts both the live `session.remoteHost` and cached `ui.statusPills.snapshot.runLocation`; no test isolates a remote-host-only mutation through `updateBindingsFromSession`. Direct `runLocationProps` assertions bypass the stale store and therefore cannot detect this defect.

### Hypothesis disposition

| Hypothesis | Disposition | Evidence-based conclusion |
|---|---|---|
| Host metadata/catalog fallback turns remote into `This Mac` | **Eliminated** | A bound projection is `.host`; missing label metadata ends at `Remote host`, while no usable options hide the pill. |
| Workspace scope routes remotely while a separate session target stays local | **Refined/partly supported** | There is a split source of truth, but it is live `TabSession.remoteHost` versus cached `AgentStatusPillsUIStore`, not workspace-scope dispatch versus session dispatch. |
| New-session async initialization/status race | **Confirmed** | Activation and local projection precede explicit default application; later scoped invalidation omits the binding/run-location snapshot. |
| A truly local target is silently overridden to remote by the scoped screen | **Eliminated as a mechanism** | Nil live binding falls through to local dispatch; workspace scope supplies no later routing override. |
| Run on lacks the adjacent material background | **Eliminated** | All three controls use `ultraThinMaterial` and shared metrics. The confirmed factual difference is stronger always-on neutral outline chrome. |

### Final conclusion

When `applyWorkspaceDefaultRunLocationIfNeeded` succeeds for an explicit New Session, `Run on: This Mac` is stale presentation state: the authoritative live binding is remote and dispatch is remote. When the default is absent, invalid, revoked before binding, unavailable at the one-shot seam, or explicitly cleared, both presentation and dispatch are genuinely local. The strongest current-HEAD defect is the missing remote-host/run-location/status-snapshot invalidation after the late explicit-session binding; the strongest factual styling discrepancy is outline strength, not a missing background layer.

## Investigation Log

### Phase 1 - Initial assessment and history
**Hypothesis:** The defect is likely a label/source-of-truth mismatch, but the actual dispatch target and styling must be independently verified.
**Findings:** Git history shows workspace-default binding was introduced in `cac1560e`; the Run on pill and its stronger outline were introduced in `73de0268`.
**Evidence:** Workspace defaults are intentional one-shot defaults; nil means local. Later label changes intentionally introduced collision-aware host abbreviations.
**Conclusion:** No later label or styling regression was found; investigate current lifecycle/state synchronization.

### Phase 2 - Broad context building
**Hypothesis:** Explicit new-tab activation may expose a local projection before the workspace default is applied.
**Findings:** The active compose tab is published synchronously before blank-tab creation returns. Agent Mode can materialize and publish a nil-`remoteHost` session during that interval; the explicit creation method applies the workspace default afterward.
**Evidence:** `PromptViewModel.swift:136-146,2638-2662,3699-3712`; `AgentModeViewModel.swift:2630-2640,3496-3518,17020-17032`.
**Conclusion:** Initialization ordering creates a reachable pre-default local snapshot.

### Phase 3 - Pair investigation
**Hypothesis:** The late binding succeeds but does not refresh the cached run-location projection, while dispatch reads the live binding.
**Findings:** Confirmed by the pair investigator and three focused probes. `updateBindingsFromSession` omits remote-host/run-location/full-status-snapshot comparison. Remote dispatch branches directly on live `session.remoteHost`.
**Evidence:** `AgentModeViewModel.swift:8650-8840,13026-13113`; `AgentModeViewModel+StatusPillsUI.swift:91-94,255-299`.
**Conclusion:** Confirmed cached-presentation race; reporter's belief is correct when default binding succeeded.

### Phase 4 - Selection refresh, spot checks, and Oracle synthesis
**Hypothesis:** A label fallback or missing material background could independently explain the observation.
**Findings:** A bound host label falls back to a stored name or `Remote host`, never `This Mac`. All three adjacent pills already use `ultraThinMaterial`; only neutral outline weight/opacity differs.
**Evidence:** `AgentRunLocationPill.swift:12-21,82-102`; `AgentExecutionLocationPill.swift:73-85,91-125`; `AgentWorkflowPill.swift:78-89`.
**Conclusion:** Host-metadata fallback and missing-background hypotheses are eliminated. The styling question is a neutral-outline consistency judgment.

## Root Cause
The root cause is a two-part lifecycle/cache defect in the explicit New Session path:

1. `PromptViewModel.createComposeTab` assigns `activeComposeTabID` and synchronously posts `.activeComposeTabChanged` before tab-state application completes and before `createBlankComposeTab(createAgentSession: true)` returns (`PromptViewModel.swift:136-146,2638-2662`). The tab already contains a fresh `activeAgentSessionID`, so Agent Mode can materialize and publish a `TabSession` whose `remoteHost` still defaults to nil. The run-location projection is therefore accurately cached as `.thisMac` at that instant (`AgentModeViewModel+StatusPillsUI.swift:91-94`).
2. After blank-tab creation returns, `createAndActivateSessionTab` successfully applies `WorkspaceModel.defaultRemoteHostID`, writing an `AgentSessionRemoteHostBinding`, then calls `updateBindingsFromSession` (`AgentModeViewModel.swift:17020-17032`; `AgentModeViewModel+StatusPillsUI.swift:255-299`). That update path does not compare `session.remoteHost`, derived run-location props, or the full next status snapshot, so a remote-host-only change can leave the cached status store at `.thisMac` (`AgentModeViewModel.swift:8650-8840`).

Actual routing is not driven by the pill or by workspace scope. `submitPreparedUserTurn` takes the remote path when and only when the live `session.remoteHost != nil` (`AgentModeViewModel.swift:13026-13113`). Thus a successfully bound session runs remotely despite the stale label. Source evidence cannot prove the reporter's specific host was valid during reproduction; if binding failed or was cleared, the local label and local dispatch are both correct.

## Recommendations
1. **Preferred durable fix:** near the derived-props fallback in `AgentModeViewModel.updateBindingsFromSession` (`AgentModeViewModel.swift:8833-8837`), compare the cached status snapshot with a newly derived status snapshot and invalidate `.statusPills` when they differ. A full projection comparison is safer than adding only `remoteHost`, because remote binding also changes execution-location availability and host-managed messaging.
2. **Minimal hotfix alternative:** after the explicit-session default application and binding update in `createAndActivateSessionTab` (`AgentModeViewModel.swift:17020-17032`), force a final `syncStatusPillsUIState()`. This directly fixes the reported seam but does not prevent the same stale-cache class elsewhere.
3. **Avoid activation reordering as the first fix:** delaying tab publication or moving remote binding into `onTabChanged` crosses Prompt/Agent Mode ownership and risks hydrated, MCP, parent, handoff, and explicit-local contracts. Fix the invalidation boundary first.
4. **Add two P0 regression tests:** (a) production-wired `createAndActivateSessionTab` with a valid workspace-default host must immediately show both a live remote binding and cached `.host` status without manual sync; (b) a remote-host-only mutation followed by `updateBindingsFromSession` must update the cached status in both host→local and local→host directions.
5. **UI judgment:** keep the existing shared `ultraThinMaterial` background. Treat `Run on: This Mac` as neutral chrome matching Work locally and unselected Workflow (`secondary.opacity(0.15)`, 0.5 pt), while retaining the stronger accented outline for a selected remote host. History proves the current stronger local outline is longstanding, but does not document a reason to preserve it.

## Preventive Measures
- Test cached UI-store projections, not only direct props helpers or underlying model state.
- For projection stores with many dependencies, prefer equality against the complete derived snapshot over hand-maintained invalidation lists.
- In lifecycle tests, assert the routing authority and rendered selection together immediately after async creation boundaries.
- Preserve the semantic contract that `This Mac` means no live remote binding; missing host metadata for a bound selection should remain a remote/degraded label, never silently appear local.
- Keep explicit coverage for unavailable/revoked workspace defaults so a UI fix does not incorrectly display remote execution when binding never succeeded.
