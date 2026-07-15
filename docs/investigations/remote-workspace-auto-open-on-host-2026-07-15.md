# Investigation: Auto-open remote scoped workspace on host instead of blocking with `workspace_not_open`

## Summary
Auto-open is feasible and well-supported by existing host machinery. The `workspace_not_open` error exists only because the gateway discovers windows via `bind_context op=list` (open windows only) and never invokes the host's existing open-a-closed-workspace machinery (`openNewWindowShowingWorkspace`, `manage_workspaces action=switch open_in_new_window=true`). Recommended v1: a new host `manage_workspaces action="open"` (idempotent open-or-locate), a new ledgered `open_workspace` wire frame gated on `sessions:operate`, and client-side automatic open on `workspace_not_open` followed by host-wide cache invalidation + force refresh. Two real defects must be fixed along the way: a zero-open-window guard in disk workspace resolution, and a `.blocked("Already on workspace…")` benign no-op that open paths treat as failure.

## Symptoms
- Client opens a remote scoped workspace (e.g. `undertone`) against host "Tuan's Mac".
- If that workspace exists on the host (was created there) but is not currently open in any host window, the client is blocked with:
  `Workspace 'undertone' is not open on Tuan's Mac. Open it there and try again.` (with a Retry button)
- Desired behavior: the host should (optionally) auto-open the workspace so remote work can proceed without someone physically opening it on the host first.

## Known anchors (from initial grep)
- Host-side error text: `Sources/RepoPromptGateway/GatewayRuntime.swift` (~line 1381) — `.workspaceNotOpen(workspaceName)` → "Workspace 'X' is not open on the host."
- Wire error code: `workspace_not_open`
- Client mapping: `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteWorkspaceSessionCatalog.swift` (~line 175) — maps `workspace_not_open` → `.workspaceNotOpen`
- Client message building: `Sources/RepoPrompt/Features/AgentMode/ViewModels/RemoteAgentModeCoordinator.swift` (~line 1567)
- Sidebar rendering: `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+SidebarSessions.swift` (~line 552)
- Tests: `Tests/RepoPromptTests/AgentMode/RemoteWorkspaceSidebarTests.swift`

## Key questions
1. Where on the host is the "workspace open?" decision made (window lookup), and what data does the host have about *existing but closed* workspaces?
2. Is there existing machinery on the host to programmatically open/switch a workspace (window management, MCP `workspace switch`, app-link handling)?
3. Are there security/approval constraints (remote pairing, workspace approval policies) that intentionally gate which workspaces a remote client may touch?
4. What would an auto-open flow look like end-to-end (client retry semantics, host headless vs. visible window, race conditions)?

## Background / Prior Research
Not needed — the investigation was fully in-workspace (feature-gap analysis, no git archaeology or external docs required).

## Investigator Findings
<!-- pair investigator appends here -->

### 1. Current gateway discovery and `workspace_not_open` call chain

**Verdict: Confirmed.**

The workspace-scoped request is intercepted in `RemoteGatewayRuntime.callTranslatedTool` only when a `list_sessions` payload has a workspace selector:

- `Sources/RepoPromptGateway/GatewayRuntime.swift:466-483` — dispatches to `callWorkspaceScopedListSessions`.
- `Sources/RepoPromptGateway/GatewayRuntime.swift:576-603` — validates the translator allow-list, calls `eligibleStartTargetWindowInfoLookup`, filters with `matchingWindowSummaries`, and throws `.workspaceNotOpen` when that filtered list is empty.
- `Sources/RepoPromptGateway/GatewayRuntime.swift:657-681` — matches exact workspace ID and case-insensitive workspace name; if both are present, both must match.

```swift
let matches = matchingWindowSummaries(payload: payload, summaries: windowInfo.summaries)
guard !matches.isEmpty else {
    throw RemoteGatewayRuntimeError.workspaceNotOpen(
        workspaceName: workspaceSelector(from: payload)?.name
    )
}
```

The eligible-window lookup has one discovery source:

- `Sources/RepoPromptGateway/GatewayRuntime.swift:1046-1071` — calls the app over AppLink with `bind_context`, `op: "list"`, then decodes only its `windows` array.
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:1912-1951` — `listBindContextWindows` starts with `let windows = windowStates.allWindows` and returns summaries for those registered windows and their active workspaces/tabs.
- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:2017-2036` — the `bind_context op=list` handler calls that function.

```swift
result = try await link.callTool(
    name: "bind_context",
    arguments: ["op": .string("list"), "_rawJSON": .bool(true)],
    timeout: 10
)
```

The wire mapping is at `Sources/RepoPromptGateway/GatewayRuntime.swift:1365-1429`: `.workspaceNotOpen` becomes message `Workspace 'X' is not open on the host.` and code `workspace_not_open`.

**Qualification:** an entirely empty `bind_context` window list is classified earlier as `.emptyWindowList` at `GatewayRuntime.swift:1072-1073`. That is a lookup-unavailable/`app_tool_error` path, not the zero-*matching-workspace* `workspace_not_open` path.

### 2. Existing `bind_context bind working_dirs` auto-open behavior

**Verdict: Confirmed, with an existing-window precondition.**

Saved workspaces that are not active in any window participate in working-directory matching:

- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:1107-1171` — `collapsedWorkspaceMatches` seeds candidates from the disk snapshot, overlays active-window workspaces, and derives `showingWindowIDs` only from active-window snapshots. A disk-only match therefore has `showingWindowIDs: []`.
- `WindowRoutingService.swift:1193-1211` — `workspaceMatchesIncludingActiveWindows` loads the disk snapshot and active-window overlay.
- `WindowRoutingService.swift:1646-1682` — exact/superset matching resolves the selected match.
- `WindowRoutingService.swift:1527-1580` — `resolveMatchToWindow` prefers an already-showing window; otherwise it calls `openNewWindowShowingWorkspace`.
- `WindowRoutingService.swift:1375-1385` — that helper opens a window, waits for initialization, and requests a switch to the saved workspace.
- `WindowRoutingService.swift:1778-1801` and `:2072-2081` — `bind_context op=bind working_dirs=...` enters this resolution path.

```swift
if let preferredWindowID = Self.preferredOpenWindowID(
    showingWindowIDs: match.showingWindowIDs, ...
) {
    // reuse an open window
}
let newWindow = try await openNewWindowShowingWorkspace(match.workspace)
```

Thus the host already has “open a saved-but-closed workspace in a new window” machinery. It is not usable when `windowStates.allWindows` is empty; see finding 5. Also, `working_dirs` are host filesystem paths, so they are not a reliable selector to send directly from a different Mac.

### 3. `manage_workspaces action='switch'` window selection and session confirmation

**Verdict: Confirmed, with an `open_in_new_window` exception.**

For the standard existing-window switch path:

- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:2330-2350` — an explicit `window_id` selects a window; without it, `windows.only` is accepted, and `windows.count != 1` throws the window-selection guidance.
- `WindowRoutingService.swift:2352-2366` — resolves the saved workspace and calls `targetWindow.workspaceManager.requestWorkspaceSwitch`.
- `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:2447-2475` — if the selected window reports active sessions, the switch awaits confirmation, then cancels those sessions before proceeding.
- `Sources/RepoPrompt/Features/Workspaces/WorkspaceSwitchingModels.swift:227-235` — the confirmation's destructive button is titled **“Switch and End Sessions.”**

```swift
let targetWindowOpt: WindowState? = if let wid = targetWindowIDArg {
    windows.first(where: { $0.windowID == wid })
} else {
    windows.only
}
if targetWindowIDArg == nil, windows.count != 1 {
    throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
}
```

The exception is `open_in_new_window=true`: `WindowRoutingService.swift:2278-2324` resolves the workspace, opens a new window, switches that new window, and binds the MCP connection to it. It does not require choosing among multiple existing windows, although its disk resolution still requires at least one existing inventory window.

### 4. Same-workspace restoration failure in `openNewWindowShowingWorkspace`

**Verdict: Confirmed as a real conditional failure path.**

- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:1375-1383` treats every `requestWorkspaceSwitch` result with `didSwitch == false` as an MCP error.
- `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:2394-2406` returns `.blocked("Already on workspace ...")` when the target is already active.
- `Sources/RepoPrompt/Features/Workspaces/WorkspaceSwitchingModels.swift:4-12` defines `.blocked` as `didSwitch == false`.

```swift
if newWorkspace.id == activeWorkspaceID {
    return .blocked("Already on workspace \"\(newWorkspace.name)\".")
}
```

A newly registered window can concurrently receive a pending restore entry:

- `Sources/RepoPrompt/App/WindowStateManager.swift:598-619,628-665` — registration notifies the programmatic-open waiter and also applies the next restore entry.
- `Sources/RepoPrompt/App/WindowState.swift:1017-1055` — that entry can restore a workspace by calling `requestWorkspaceSwitch`.

Therefore, if the new window has already restored the requested target by the time `openNewWindowShowingWorkspace` makes its switch request, the desired state has been reached but the helper throws. This is conditional (not every new window restores the target), but the failure path is real. An open operation should first accept an already-active target as success or otherwise treat the benign same-workspace result as idempotent success.

### 5. Zero-open-window behavior

**Verdict: Confirmed limitation.**

All current saved-workspace resolution paths depend on a `WorkspaceManagerViewModel` owned by an existing window:

- `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/WindowRoutingService.swift:1173-1191` — `workspaceMatchesFromDisk` guards `windows.first`.
- `WindowRoutingService.swift:1193-1211` — `workspaceMatchesIncludingActiveWindows` has the same guard.
- `WindowRoutingService.swift:455-461` — the shared `loadWorkspaceDiskSnapshot` used by `resolveWorkspaceForSwitch` guards `allWindows.first?.workspaceManager`.
- `WindowRoutingService.swift:541-548` — `resolveWorkspaceForSwitch` calls that loader.
- `WindowRoutingService.swift:2285-2289` — even `switch open_in_new_window=true` resolves the workspace **before** opening the new window, so it fails at zero windows.

The thrown message is:

```swift
"No windows available to load workspace list. Open at least one window first."
```

Consequences at zero windows:

1. `bind_context list` returns an empty `windows` array because it enumerates `allWindows`.
2. `bind_context bind working_dirs` fails during disk matching.
3. `manage_workspaces switch`, including `open_in_new_window=true`, cannot resolve the saved workspace.
4. The gateway's eligible-window lookup classifies the empty list as unavailable rather than `workspace_not_open`.

Normal “background mode” is slightly different from a truly windowless app: `Sources/RepoPrompt/App/MCPBackgroundModeCoordinator.swift:14-21` hides the NSWindow without tearing down its SwiftUI scene, so its `WindowState` remains registered. Conversely, `Sources/RepoPrompt/App/AppDelegate.swift:137-140` ordinarily terminates after the last real window closes unless the app is intentionally backgrounded. The zero-window guard is nevertheless a real robustness gap and must be fixed for a genuinely running/windowless host.

### 6. Client degraded cache TTL and invalidation

**Verdict: Confirmed.**

- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteWorkspaceSessionCatalog.swift:51-52` — degraded TTL is **20 seconds**; healthy TTL is 300 seconds.
- `RemoteWorkspaceSessionCatalog.swift:108-121` — `.workspaceNotOpen`, `.unsupported`, and `.error` use the degraded TTL.
- `RemoteWorkspaceSessionCatalog.swift:99-105` — exposes both `invalidate(hostID:clientWorkspaceID:)` and host-wide `invalidate(hostID:)`.
- `RemoteWorkspaceSessionCatalog.swift:75-96` — `forceRefresh=true` bypasses a still-valid cache entry.

```swift
private static let degradedEntryTTL: TimeInterval = 20
...
func invalidate(hostID: String, clientWorkspaceID: UUID) {
    cache.removeValue(forKey: CacheKey(hostID: hostID, clientWorkspaceID: clientWorkspaceID))
}
```

One implementation caveat: only host-wide invalidation increments `invalidationGenerationByHostID` (`:103-105`). Targeted invalidation can be repopulated by an older in-flight load, so an Open-on-Host flow should sequence the open response and forced refresh carefully.

### 7. Scope enforcement, frame inventory, and mutation ledger

**Verdict: Confirmed.**

Scope mapping is closed and has no workspace-open operation:

- `Sources/RepoPromptGateway/Auth/ScopeEnforcer.swift:38-58` — `list_sessions` is `sessions:observe`; `start`, `steer`, and `cancel` are `sessions:operate`; `respond` is `interactions:respond`; push subscription is also observation-scoped.
- `ScopeEnforcer.swift:4-9,25-31` reserves `workspace:read` only for future read-only workspace browsing. It is not an open/mutation scope.
- `Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:916-940` rejects unknown scope operations before runtime translation.

The current wire inventory at `Sources/RepoPromptRemoteWire/RemoteWireProtocol.swift:7-41` is:

- Client: `hello`, `start`, `steer`, `respond`, `cancel`, `poll`, `subscribe`, `unsubscribe`, `list_agents`, `list_sessions`, `get_log`, `ping`, `push_subscribe`, `push_unsubscribe`.
- Server: `hello_ack`, `command_result`, `command_error`, `session_update`, `session_terminal`, `session_expired`, `interaction_resolved`, `channel_closing`, `pong`.
- Mutating client frames: `start`, `steer`, `respond`, `cancel`.

`RemoteWireProtocol.swift:43-63` rejects unsupported client types and requires a nonblank `request_id` for the mutating set.

Ledger/idempotency flow:

- `Sources/RepoPromptGateway/GatewayRuntime.swift:358-380` routes only `mutatingClientFrameTypes` to `handleMutatingCommand`.
- `GatewayRuntime.swift:379-454` keys the ledger by `(deviceID, requestID)`, fingerprints the command, replays completed duplicates, reports in-flight duplicates, rejects conflicting reuse, and records success/failure.
- `Sources/RepoPromptGateway/Ledger/CommandLedger.swift:156-219` persists/restores entries and implements the duplicate/in-flight/conflict decisions.

A new `open_workspace` must be deliberately classified as mutating to receive request-ID idempotency. Its scope must also be chosen explicitly: either reuse `sessions:operate` by policy or add a write/open-specific workspace scope; the reserved read scope is not sufficient for opening a visible host window.

### 8. Client `list_sessions` sender and Retry behavior

**Verdict: Confirmed; Retry explicitly bypasses the degraded TTL.**

- `Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteWorkspaceSessionCatalog.swift:122-148` sends `RemoteClientFrame(type: "list_sessions")` with `workspace_name`, `limit: 500`, and a learned host `workspace_id` when available.
- `RemoteWorkspaceSessionCatalog.swift:159-176` retries once without a stale learned ID on `workspace_mismatch` and maps `workspace_not_open` to catalog state.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+SidebarSessions.swift:573-595` performs the fetch; `retryRemoteWorkspaceSidebar` invalidates the targeted entry and then calls `refreshRemoteWorkspaceSidebar(forceRefresh: true)`.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionsSidebarView.swift:630-648` renders Retry for `.workspaceNotOpen` and errors.
- `AgentSessionsSidebarView.swift:144-151` also runs a 20-second normal refresh loop; `:591-599` exposes a separate force-refresh toolbar button.

```swift
func retryRemoteWorkspaceSidebar() async {
    remoteCoordinator.invalidateWorkspaceSessionCatalog(...)
    await refreshRemoteWorkspaceSidebar(forceRefresh: true)
}
```

Therefore the Retry button does not wait for the 20-second degraded TTL; it both invalidates and forces a network fetch.

### 9. Gateway `RemoteCommandTranslator` allow-list and extension point

**Verdict: Confirmed.**

The gateway does not permit an arbitrary frame to select an arbitrary app tool:

- `Sources/RepoPromptGateway/Wire/RemoteCommandTranslator.swift:109-203` is an explicit frame-type switch mapping the known agent operations; the default throws `unsupportedFrameType`.
- `RemoteCommandTranslator.swift:235-329` constructs only allowlisted `agent_run` or `agent_manage` calls for those cases.
- `RemoteCommandTranslator.swift:340-360` rejects passthrough keys such as `tool`, `tool_name`, `arguments`, and `op`, and rejects payload keys outside each operation's set.
- `Sources/RepoPromptGateway/GatewayRuntime.swift:726-742` executes only the resulting `RemoteToolCall` over AppLink.

```swift
switch frame.type {
case "start": ...
case "list_sessions": ...
case "get_log": ...
default:
    throw RemoteCommandTranslatorError.unsupportedFrameType(frame.type)
}
```

Currently `open_workspace` is rejected even earlier because it is absent from `RemoteWireProtocol.clientFrameTypes` (`RemoteWireProtocol.swift:7-25,52-59`). To add it, the translation belongs as a new explicit case in `RemoteCommandTranslator.translate` (`:121-203`) with a narrow payload allow-list and a new constructed call to the app's `manage_workspaces` tool, e.g. fixed arguments `action: "open"` plus an explicitly mapped workspace selector. It must also be added to the wire client/mutating sets and `ScopeEnforcer`; otherwise it is rejected before translation.

### 10. Existing settings/toggles for remote workspace behavior

**Verdict: Confirmed absent; a nearby host-side settings surface exists.**

Repository-wide searches for remote workspace auto-open/open-on-host setting names found no such preference. The current persisted MCP/remote settings enumerate only gateway enablement/address/port and pairing-detail visibility:

- `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:415-439` — `MCPSettings` fields are `remoteGatewayEnabled`, `remoteGatewayBindAddress`, `remoteGatewayPort`, and `remoteControlShowPairingDetails` (plus unrelated MCP fields).
- `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift:1019-1058` — accessors exist for those same settings only.
- `Sources/RepoPrompt/Features/Settings/Views/RemoteControlSettingsView.swift:16-54` — the host-side “Remote Control” gateway toggle is the closest UI location; `:93-124` displays paired devices and their scopes.
- `Sources/RepoPrompt/Infrastructure/Security/RemotePairing/PairedDeviceRecord.swift:16-46` — host device records contain identity, scopes, counters, revocation, and push state, but no workspace-open preference.
- `Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:119-168` — client-side paired-host rows expose test, rename, and forget actions, not host behavior controls.

A host-global opt-in naturally fits beside Remote Control and in persisted `MCPSettings`. A per-device opt-in would instead require extending/migrating `PairedDeviceRecord`; no such schema exists today.

### Feasibility summary

The oracle design—host `manage_workspaces action=open`, gateway `open_workspace`, and a client **Open on Host** button—is **sound in direction but not complete as-is**.

Most host behavior already exists in `manage_workspaces action=switch, open_in_new_window=true` (`WindowRoutingService.swift:2278-2324`), so a new `open` action should share/harden that implementation rather than duplicate it. Required corrections are:

1. Decouple disk workspace loading from an existing `WindowState`, or bootstrap an initialized inventory window before resolution, so zero-window hosts work.
2. Make open idempotent: an already-active/restored target is success, not the current `.blocked`/MCP error.
3. Open a dedicated new window rather than switching an arbitrary active window; define a non-hanging policy if restoration leaves active sessions and `requestWorkspaceSwitch` asks for confirmation.
4. Add `open_workspace` to the wire client **and mutating** sets, give it an explicit non-read scope, and add a narrow translator case to `manage_workspaces`. This preserves request-ID ledger idempotency and prevents arbitrary tool passthrough.
5. Preserve/update the AppLink connection's binding to the opened window. The existing new-window switch does this at `WindowRoutingService.swift:2313-2315`; a new action should too, and the gateway should refresh any cached binding/window inventory after success.
6. After success, invalidate and force-refresh the client workspace catalog; the existing Retry machinery already provides that cache-bypass behavior.
7. Put any auto-open opt-in on the host (preferably default-off) beside Remote Control. The explicit Open-on-Host button can remain the user-driven fallback.

With those corrections, the design avoids disturbing an existing host window, remains scope- and ledger-controlled, and covers the intended unattended-host scenario.


## Investigation Log

### Phase 4 - Oracle synthesis (final reconciled design)
**Hypothesis:** The oracle's initial plan (new `action=open` + `open_workspace` frame + client button) survives the pair's corrections.
**Findings:** Design confirmed in direction with these final decisions:
- (a) New `manage_workspaces action="open"` as a thin *open-or-locate* wrapper sharing refactored internals with `switch open_in_new_window=true` (which must keep its always-new-window contract for existing local MCP clients). Idempotency fix (`!didSwitch` but target already active → success) is a shared bug fix benefiting `bind_context bind`, `open_in_new_window`, and `open`. Host-side single-flight per workspace ID (not gateway-side).
- (b) Zero-window handling: bootstrap `openInitializedWindow()` first, then resolve+switch that fresh window. Decoupling `loadWorkspaceSnapshotFromDisk` from `WorkspaceManagerViewModel` is a deferred cleanup.
- (c) Reuse `sessions:operate` (a device with that scope can already start code-executing sessions in open workspaces; opening a closed workspace is strictly less powerful). No default-off toggle in v1 — it would recreate the "forgot to configure before leaving" failure mode; optional default-ON opt-out toggle as fast-follow. Local precedent: `bind_context bind` already auto-opens closed workspaces ungated.
- (d) Fully automatic client-driven auto-open on `workspace_not_open` (once-per-episode guard), interim "Opening…" sidebar state, then **host-wide** `invalidate(hostID:)` (bumps `invalidationGenerationByHostID`, defeating the stale in-flight-load repopulation caveat) + `fetch(forceRefresh: true)`. `list_sessions` stays observe-scoped and side-effect-free; the open is a distinct operate-scoped ledgered frame. Existing Retry re-enters the same path; no new button needed.
- (e) Deferred from v1: `start`-path inline auto-open, new `workspace:open` scope, settings kill switch, snapshot-loading decoupling, gateway push notifications.
**Conclusion:** Confirmed — see Recommendations.

### Phase 3 - Pair investigator verification
**Hypothesis:** The oracle's factual claims hold at exact file:line.
**Findings:** All 10 claims verified (see `## Investigator Findings`); two defects confirmed (zero-window guard, `.blocked` no-op treated as failure); orchestrator independently spot-checked WindowRoutingService.swift:2278-2324 (`open_in_new_window` resolves from disk *before* opening a window and throws on any `!didSwitch`), WindowRoutingService.swift:455-461 (zero-window guard message), WorkspaceManagerViewModel.swift:2394-2406 (`.blocked("Already on workspace…")` documented as benign no-op).
**Conclusion:** Oracle plan sound in direction; corrections folded into Phase 4 synthesis.

### Phase 1 - Initial grep for error message
**Hypothesis:** Error originates host-side and is surfaced verbatim on client.
**Findings:** Confirmed; see anchors above. Error code `workspace_not_open` travels over the remote wire from GatewayRuntime to the client catalog.
**Conclusion:** Need to trace host-side workspace window lookup and any existing programmatic workspace-open path.

## Root Cause
Not a bug — a designed-in gap. The gateway's workspace-scoped `list_sessions` path (`GatewayRuntime.swift:576-603`) discovers host windows exclusively through AppLink `bind_context op=list` (`GatewayRuntime.swift:1046-1071`), which enumerates only currently-open windows (`WindowRoutingService.listBindContextWindows`, `WindowRoutingService.swift:1912-1951`). When no open window matches the requested workspace, it throws `RemoteGatewayRuntimeError.workspaceNotOpen` → wire code `workspace_not_open` → client blocks with "Open it there and try again" (`RemoteWorkspaceSessionCatalog.swift:175`, `RemoteAgentModeCoordinator.swift:1567`, `AgentModeViewModel+SidebarSessions.swift:552`). The host *already has* machinery to open saved-but-closed workspaces (`resolveMatchToWindow` → `openNewWindowShowingWorkspace`, `WindowRoutingService.swift:1527-1580, 1375-1385`; `manage_workspaces action=switch open_in_new_window=true`, `WindowRoutingService.swift:2278-2324`) — the gateway simply never invokes it, and no wire frame exposes it to remote clients (`RemoteCommandTranslator.swift:109-203` is a closed allow-list; `RemoteWireProtocol.swift:7-41` has no open frame).

Two genuine defects block a clean implementation and need fixing regardless:
1. **Zero-open-window guard** — `loadWorkspaceDiskSnapshot` (`WindowRoutingService.swift:455-461`) requires an existing `WindowState`, so every disk-resolution path (including `open_in_new_window`, which resolves *before* opening) fails when the app runs with no windows.
2. **Idempotency bug** — `requestWorkspaceSwitch` returns benign `.blocked("Already on workspace…")` (`WorkspaceManagerViewModel.swift:2401-2406`), but `openNewWindowShowingWorkspace` (`WindowRoutingService.swift:1375-1383`) and the `open_in_new_window` branch (`:2309-2312`) throw on any `!didSwitch` — a real failure path when a launch-restore race leaves the new window already on the target workspace (`WindowStateManager.swift:598-665`, `WindowState.swift:1017-1055`).

## Recommendations
V1 slice (smallest coherent change solving unattended recovery):
1. **Host `WindowRoutingService`**: fix `.blocked`-as-success in `openNewWindowShowingWorkspace` (treat `!didSwitch` as success when the window's active workspace already equals the target — shared fix for `bind_context bind`, `open_in_new_window`, and the new action); add `manage_workspaces action="open"` = resolve from disk (`workspace_not_found` if absent) → locate in open windows (`already_open` + `window_id`, never switch an occupied window) → else single-flighted `openNewWindowShowingWorkspace`; bind calling connection to the resulting window (mirror `WindowRoutingService.swift:2313-2315`); zero-window case: bootstrap `openInitializedWindow()` first, then resolve and switch that fresh window.
2. **`RemoteWireProtocol.swift`**: add `open_workspace` to `clientFrameTypes` AND `mutatingClientFrameTypes` (+ command fingerprint coverage) for ledger idempotency.
3. **`ScopeEnforcer.swift`**: `open_workspace` → `sessions:operate`.
4. **`RemoteCommandTranslator.swift`**: explicit case → `manage_workspaces {action: "open", workspace: <id-or-name>}` with payload allow-list `{workspace_id, workspace_name}`.
5. **`GatewayRuntime`**: after successful open, `appLinkPool.refreshBindingState(forDevice:)` + drop cached `lastEligibleWindowDetailsByDevice[deviceID]`; audit record with selector flags, resulting `window_id`, outcome codes.
6. **Client**: on `workspace_not_open` with `sessions:operate` granted, auto-send `open_workspace` (once per `(hostID, clientWorkspaceID)` episode), show "Opening 'X' on <host>…" interim state; on success `invalidate(hostID:)` **host-wide** (bumps generation; targeted invalidate does not) then `fetch(forceRefresh: true)`; on failure/old-host/missing-scope fall back to current copy + Retry.

Deferred: `start`-path inline auto-open; dedicated `workspace:open` scope; default-ON host opt-out toggle in `MCPSettings`/`RemoteControlSettingsView`; decoupling `loadWorkspaceSnapshotFromDisk` from `WindowState`.

Test plan: host open/locate/idempotency/zero-window/single-flight tests; gateway `open_workspace` happy path, ledger replay, `insufficient_scope`, `workspace_not_found` passthrough — while keeping `testWorkspaceScopedListSessionsWithNoMatchingWindowsReturnsWorkspaceNotOpenPickerDetails` and the no-fabrication test green (`list_sessions` semantics unchanged); client sidebar auto-open/failure/degradation tests in `RemoteWorkspaceSidebarTests`.

## Preventive Measures
- Keep observe-scoped frames (`list_sessions`) side-effect-free as an explicit invariant; any recovery action must be a distinct mutating, ledgered, audited frame.
- When adding window-dependent host services, avoid coupling disk catalog reads to a live `WindowState` (the zero-window guard was a silent robustness gap across three code paths).
- Callers of `requestWorkspaceSwitch` must treat `.blocked` same-workspace results as idempotent success; consider a dedicated `.alreadyActive` result case to make this un-missable at compile time.
- Version-skew: new wire frames should degrade gracefully (client hides/falls back when gateway/host rejects unknown frame types), which the closed translator allow-list already enforces server-side.
