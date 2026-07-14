# Investigation: Device shows "Revoked by host" immediately after successful pairing

## Summary
The gateway authenticates WebSocket hellos against a paired-device trust snapshot that it refreshes only via a fixed 15-second poll (`Sources/RepoPromptGateway/main.swift:211-259`); pairing completion never triggers a refresh. The first hello after pairing therefore hits a stale snapshot, `DeviceAuthenticator.admitHello` rejects with `unknown_device`, and the client maps `unknown_device` (alongside `device_revoked`) to a **persistent** revoked state (`RemoteClientError.swift:40-41` → `RemoteHostConnection.markRevoked()` → `revokedByHostAt` persisted), which every later connect short-circuits on. A ≤15s transient race is thereby converted into a permanent "Revoked by host". Re-pair reproduces it deterministically because the client-side auto-initiators (notably the workspace sidebar refresh task, whose key re-arms instantly since `forgetHost` doesn't clear `defaultRemoteHostID` and the host ID/fingerprint is unchanged) connect within seconds of pairing — always inside the staleness window. The firewall prompt is expected (separately-signed `repoprompt-gateway` binding the Tailscale IP; ad-hoc/debug signing churn re-prompts each rebuild); the empty `log show` is expected (pairing/connection code has zero os_log; the gateway logs via swift-log to inherited stderr, and its trust-sync failures are logged at `.debug` below the `.info` level).

## Symptoms
Observed during first live two-Mac e2e test of the new native Tailscale discovery/pairing flow (implemented in `.agent-artifacts/duo-plan-build/20260714-tailscale-onboarding-v1/`, spec at `docs/spec/native-direct-tailnet-pairing.md`):

1. **Immediate "Revoked by host" after successful pairing.** Client (controller Mac) successfully discovered the host via "Find Hosts on Tailscale", requested access, host approved. The paired host row then shows:
   - "This host rejected the device credentials on 15 Jul 2026 at 01:48. Forget and pair again to restore access."
   - Status: `Tuan's Mac — Revoked by host`
   - Fingerprint: `sha256:bc8da54494908559af3c4c27c6dfe9e7f6a3395acbfaf76aa39d9613623712a8`
   - Device ID: `remote:9ba3ebf2`
   - Endpoint: `http://100.122.229.108:47392` (debug port)
   - Granted: Respond to interactions, Observe sessions, Operate sessions
   - "Paired 15 Jul 2026 at 01:48 • Last connected: Never"
   - **Key detail**: paired-at and rejected-at timestamps are the same minute (01:48) and "Last connected: Never" — so the rejection happened immediately after pairing completion, before any successful authenticated connection.
   - **Forget + re-pair reproduces the same failure.**

2. **Empty client logs.** User ran:
   `log show --last 30m --info --predicate 'subsystem == "com.repoprompt.agents" AND category == "RemoteControlClient"'`
   and got nothing. Note the user's pasted command contains smart quotes (`RemoteControlClient"'` with curly quote) which may have broken the predicate; also the subsystem/category names may not match what the code actually uses. Need: authoritative subsystem/category names for client-side remote pairing logging, or determine that this path has no os_log coverage at all.

3. **Firewall prompt on host after rebuild**: macOS asked "Do you want the application "repoprompt-gateway" to accept incoming network connections?" — need to confirm this is expected (gateway now binds the Tailscale interface IP instead of loopback → application firewall prompts; debug signing identity churn across rebuilds re-triggers the prompt) and whether Deny would break discovery/pairing.

## Initial Hypotheses
- H1: A client-side post-pairing step (auto ticket request / verify / test connection) runs immediately after pair completion, the host rejects it (401/403 or explicit `revoked` error), and the client maps that rejection to a persistent "Revoked by host" state.
- H2: Host-side split-brain between the app process (which approves + registers the device) and the gateway process (which authenticates subsequent requests): registration not propagated/persisted to whatever store the gateway consults (AppLink relay ordering, snapshot staleness, or separate debug/release trust file namespaces reading/writing different paths).
- H3: Single-use approval-context / post-consent revalidation logic (new in this implementation) consumes or invalidates the approval and then treats the just-paired device as revoked.
- H4: Device identity canonicalization mismatch: device ID / public key encoding differs between the pair/complete registration record and the ticket/WS authentication lookup (e.g. `remote:9ba3ebf2` display id vs full key hash), so lookup misses → host returns "unknown/revoked device".
- H5: Signature/counter scheme mismatch: replay-counter floor or nonce validation fails on the very first authenticated request (e.g. counter initialized to N on host, client starts at 0), rejected as credential failure.
- H6: Gateway retirement/replacement race: gateway restarted (or serialized replacement kicked in) between pair completion and first authenticated request, losing in-memory device/approval state that is not re-hydrated from disk.

## Background / Prior Research
- Branch context: greenfield single-user branch; implementation completed in prior session with four-round security review + Oracle review; live two-Mac acceptance was NOT run before handoff — this e2e test is the first real-network exercise of the flow.
- Debug builds: per CLAUDE.md, auto-detected/ad-hoc debug signing uses **ephemeral in-memory secure storage** — API keys and secure permission changes do not persist across launches. Relevant if host keys / device trust records live in "secure storage" on either end.

## Investigator Findings
<!-- Pair investigator appends structured analysis here (file:line refs, evidence, conclusions). -->

### Overall verdict

**CONFIRMED (code path), with one live-evidence gap.** The source contains the complete stale-trust-to-sticky-revocation chain described by the Oracle: app-side pairing can persist a device and mint its ticket while the gateway still has an older trust snapshot; WebSocket admission then emits "unknown_device"; the client maps that code to ".revoked", persists "revokedByHostAt", and refuses all later attempts. The unverified part is which caller initiated the first connection in this specific live run. There is **no unconditional post-pair connection** in the settings flow, but there are conditional automatic Agent Mode callers documented in Finding 2.

### 1. Reported causal chain

#### 1(a). Gateway trust-sync timing and failure behavior — **CONFIRMED**

The HTTP server starts before the trust task is created (Sources/RepoPromptGateway/main.swift:185-211). Inside the task, the first fetch is before the first sleep; each attempt, successful or failed, is followed by 15 seconds of sleep.

Sources/RepoPromptGateway/main.swift:211-256:

~~~swift
let trustSyncTask = Task {
    var revokedTransitionTracker = GatewayRevokedDeviceTransitionTracker()
    while !Task.isCancelled {
        do {
            let snapshot = try await GatewayTrustSynchronizer.fetchSnapshot(appLink: appLink)
            let revokedDeviceIDs = await authenticator.updateTrust(snapshot)
            let tornDown = await appLinkPool.applyTrustSnapshot(snapshot)
~~~

After the intervening snapshot-application/teardown work, the loop ends each attempt with:

~~~swift
        } catch {
            logger.debug("Gateway trust sync failed: \(String(describing: error))")
        }
        try? await Task.sleep(for: .seconds(15))
    }
}
~~~

Therefore:

- first fetch is immediate, not sleep-first;
- an ordinary "list_devices", parse, or snapshot-application failure does **not** kill the loop;
- there is no immediate retry, failure counter, or exponential backoff in this loop—only the fixed 15-second post-attempt delay;
- the prior snapshot is not cleared on failure;
- cancellation is swallowed by "try?" for the sleep, then the next "while !Task.isCancelled" test exits;
- the tool call itself has a 15-second timeout, so a timed-out attempt can make attempt starts roughly 30 seconds apart (15-second call plus 15-second sleep).

Sources/RepoPromptGateway/Auth/DeviceAuthenticator.swift:63-79:

~~~swift
static func fetchSnapshot(appLink: AppLinkSession) async throws -> GatewayTrustSnapshot {
    let result = try await appLink.callTool(
        name: "remote_pairing",
        arguments: [
            "op": .string("list_devices"),
            "include_revoked": .bool(true)
        ],
        timeout: 15
    )
    let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
    if result.isError == true {
        throw DeviceAuthenticationError.invalidTrustSnapshot("remote_pairing list_devices failed.")
    }
    return try GatewayTrustSnapshot.parse(from: payload)
}
~~~

Diagnostic caveat: gateway log level is ".info" while trust failures use ".debug", so this failure message is suppressed under the current configuration (Sources/RepoPromptGateway/main.swift:103-108).

#### 1(b). WebSocket hello admission and exact codes — **CONFIRMED**

The authenticator begins with no snapshot because main constructs it without a "trust" argument (Sources/RepoPromptGateway/main.swift:129-134). A gateway that has never installed any successful snapshot rejects with "trust_unavailable"; a gateway with a valid but empty/stale snapshot rejects a missing device with "unknown_device"; a present revoked record yields "device_revoked".

Sources/RepoPromptGateway/Auth/DeviceAuthenticator.swift:232-251:

~~~swift
guard let trust else { throw DeviceAuthenticationError.trustUnavailable }
guard let ticketValue = frame.payload?.objectValue?["ticket"] else {
    throw DeviceAuthenticationError.ticketRequired
}
~~~

After ticket parsing:

~~~swift
guard let device = trust.devices[ticket.deviceID] else {
    throw DeviceAuthenticationError.unknownDevice(ticket.deviceID)
}
guard !device.isRevoked else {
    throw DeviceAuthenticationError.deviceRevoked(device.deviceID)
}
~~~

Exact wire codes and messages are defined at Sources/RepoPromptGateway/Auth/DeviceAuthenticator.swift:100-132:

~~~swift
case .trustUnavailable: "trust_unavailable"
case .unknownDevice: "unknown_device"
case .deviceRevoked: "device_revoked"
~~~

~~~swift
case .trustUnavailable:
    "The gateway has not yet synchronized paired-device trust from the app."
case let .unknownDevice(deviceID):
    "Device \(deviceID) is not paired."
case let .deviceRevoked(deviceID):
    "Device \(deviceID) is revoked."
~~~

A successful empty snapshot makes "trust" non-nil through "updateTrust" (Sources/RepoPromptGateway/Auth/DeviceAuthenticator.swift:203-221), so “never synced” and “synced but missing” are observably different. GatewayHTTPServer forwards the authenticator code verbatim as a "command_error" and closes the channel (Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:730-745):

~~~swift
device = try await authenticator.admitHello(rawFrame: rawData, frame: frame, connectionID: sinkID)
~~~

On DeviceAuthenticationError:

~~~swift
await sink.send(.commandError(requestID: frame.requestID, code: error.code, message: error.description))
channel.close(promise: nil)
~~~

#### 1(c). "/api/ticket" reads fresh app state, not gateway trust — **CONFIRMED**

All relay paths, including "/api/ticket", are POSTed through GatewayPairingRelay (Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:287-290). The ticket route merely whitelists arguments and calls the app-side "remote_pairing mint_ticket" tool.

Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:153-165:

~~~swift
case Self.mintTicketPath:
    var arguments: [String: Value] = [:]
    copyString(payload, key: "device_id", into: &arguments)
    copyStringArray(payload, key: "scopes", into: &arguments)
    copyInt(payload, key: "ttl_seconds", into: &arguments)
    return await callPairing(
        op: "mint_ticket",
        auditOp: "mint_ticket",
        arguments: arguments,
        timeout: Self.defaultTimeout
    )
~~~

Pair completion first writes the app-owned identity store (Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:361-384):

~~~swift
let savedRecord = try dependencies.identityStore.upsertDevicePreservingCounterFloor(record)
return .object([
    "ok": .bool(true),
    "device": deviceValue(savedRecord)
])
~~~

Ticket mint then reads that same authoritative store and signs from current app state; it never checks "DeviceAuthenticator.hasTrust" or the gateway snapshot (Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:387-419):

~~~swift
guard let device = try dependencies.identityStore.device(id: deviceID) else {
    throw MCPError.invalidRequest("No paired device exists for \(deviceID).")
}
guard !device.isRevoked else {
    throw MCPError.invalidRequest("Device \(deviceID) is revoked.")
}
~~~

The same function later signs the ticket:

~~~swift
let ticket = try RemotePairingCrypto.signTicket(
    deviceID: deviceID,
    scopes: grantedScopes,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    hostFingerprint: host.fingerprint,
    hostSigner: key
)
~~~

**Conclusion:** after successful "complete_pairing", "mint_ticket" succeeds from the fresh app registry (absent a separate intervening store/AppLink failure) even while WebSocket authentication still sees a stale gateway snapshot. This split makes the reported ticket-success/hello-failure sequence structurally possible.

#### 1(d). Client maps "unknown_device" to revoked — **CONFIRMED**

Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteClientError.swift:37-43:

~~~swift
static func fromCommandError(code: String, message: String, details: JSONValue? = nil) -> RemoteClientError {
    let error = RemoteCommandError(code: code, message: message, details: details)
    switch code {
    case "device_revoked", "unknown_device":
        return .revoked(error)
~~~

By contrast, "trust_unavailable" is in the authentication-error group (same file:50-64), so a gateway that has **never** completed trust sync does not take this revocation path.

#### 1(e). Revocation becomes durable and blocks future connects — **CONFIRMED**

The immediate-retry wrapper marks every ".revoked" error before returning it (Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:318-345):

~~~swift
} catch let error as RemoteClientError {
    if case .revoked = error {
        markRevoked()
        throw error
    }
~~~

The command-code switch in that same catch also contains:

~~~swift
case "device_revoked", "unknown_device":
    markRevoked()
    throw RemoteClientError.revoked(commandError)
~~~

"markRevoked" persists through the registry, cancels connection/reconnect work, and enters the revoked state (same file:889-905):

~~~swift
private func markRevoked() {
    _ = try? registry.markRevokedByHost(hostID: hostID, at: now())
    reconnectTask?.cancel()
    reconnectTask = nil
    connectTask?.cancel()
    connectTask = nil
    flushPendingCounter()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    signer = nil
    connectedScopes = []
    connectedHostName = nil
    acknowledgedSubscriptions.removeAll()
    failAllPending(with: RemoteClientError.hostRevoked(hostID))
    transition(to: .revoked)
}
~~~

The registry mutation is an atomic file save (Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:148-177):

~~~swift
registry.hosts[index].revokedByHostAt = date
try save(registry)
~~~

Every later open reads the record and short-circuits before ticket minting (Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:348-357):

~~~swift
let record = try currentHostRecord()
guard record.revokedByHostAt == nil else {
    transition(to: .revoked)
    throw RemoteClientError.hostRevoked(hostID)
}
~~~

This confirms that one transient "unknown_device" is converted into persistent “Revoked by host”; a later successful gateway trust refresh cannot self-heal the client record.

#### 1(f). Ticket HTTP substring heuristics — **CONFIRMED**

The non-2xx ticket handler is message-substring based after only a special 429/code check. It ignores any other structured code for revocation purposes and case-insensitively matches “revoked” or “no paired device”; both paths immediately persist revocation.

Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostConnection.swift:507-528:

~~~swift
if response.statusCode == 429 || code == "rate_limited" {
    return .rateLimited(message: message)
}
if message.localizedCaseInsensitiveContains("revoked") {
    let error = RemoteCommandError(code: "device_revoked", message: message, details: nil)
    markRevoked()
    return .revoked(error)
}
if message.localizedCaseInsensitiveContains("no paired device") {
    let error = RemoteCommandError(code: "unknown_device", message: message, details: nil)
    markRevoked()
    return .revoked(error)
}
return .transport(message)
~~~

This is a second sticky-revocation entrance. It is broader and more fragile than the WebSocket error-code mapping because arbitrary server text containing either substring is sufficient.

### 2. What connects immediately after pairing? — **UNCONDITIONAL CALLER REFUTED; LIVE CALLER UNCERTAIN**

The settings pairing flow has no post-pair connect. It revalidates, pairs, writes the client registry, refreshes settings rows, and updates UI state.

Sources/RepoPrompt/Features/Settings/ViewModels/RemoteHostsSettingsViewModel.swift:218-237:

~~~swift
let payload = try await discoveryService.revalidateForPairing(selected)
let record = try await pairingClient.pair(
    payload: payload,
    displayName: clientDisplayName(),
    scopes: RemoteHostPairingClient.defaultRequestedScopes
)
try registry.upsertHost(record)
refreshHosts()
discoveredHosts.removeAll { $0.hostFingerprint == record.id }
pairingState = .paired(hostName: record.displayName)
statusMessage = "Paired \(record.displayName)."
~~~

"refreshHosts" is storage-only (same file:167-175), and RemoteHostRegistry is not observable; "upsertHost" only removes/appends/saves (Sources/RepoPrompt/Infrastructure/RemoteHosts/RemoteHostRegistry.swift:15-16, 73-80). The discovery sheet dismisses after this method returns (Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:267-280). No "connection(for:)", "ensureConnected", catalog load, notification, or test call occurs on this path.

The **Test Connection** path is explicitly button-driven (Sources/RepoPrompt/Features/Settings/Views/RemoteHostsSettingsView.swift:152-170) and reaches "ensureConnected" through RemoteHostsSettingsViewModel.swift:291-301, RemoteHostConnectionManager.swift:60-63, and RemoteHostConnection.swift:224-227.

There are, however, three conditional automatic Agent Mode initiators that can fire without Test Connection:

1. **Workspace sidebar catalog task (best post-pair match when this host is the active workspace default).** AgentSessionsSidebarView starts by refreshing immediately, then sleeps 20 seconds (Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionsSidebarView.swift:144-152):

   ~~~swift
   .task(id: agentModeVM.remoteWorkspaceSidebarRefreshKey()) {
       guard agentModeVM.remoteWorkspaceSidebarRefreshKey() != nil else { return }
       while !Task.isCancelled {
           await agentModeVM.refreshRemoteWorkspaceSidebar()
           try await Task.sleep(nanoseconds: 20_000_000_000)
       }
   }
   ~~~

   The key exists only when the active non-system workspace has "defaultRemoteHostID" and that ID now resolves to a paired, non-revoked record (Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+SidebarSessions.swift:506-528):

   ~~~swift
   guard let workspace = workspace ?? workspaceManager?.activeWorkspace,
         !workspace.isSystemWorkspace,
         let boundHostID = workspace.defaultRemoteHostID,
         hostID == nil || hostID == boundHostID,
         let hostRecord = try? remoteHostRegistry.host(id: boundHostID),
         !hostRecord.isRevokedByHost
   else { return nil }
   ~~~

   Refresh calls the workspace catalog (same file:573-583), whose "list_sessions" command connects on demand (Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteWorkspaceSessionCatalog.swift:123-143). Pairing alone does not guarantee this task restarts; a sidebar re-render must make its previously nil task ID non-nil. This path is especially plausible on re-pair because Settings "forgetHost" removes the host/key but does not clear any workspace "defaultRemoteHostID" (RemoteHostsSettingsViewModel.swift:262-282).

2. **Persisted remote-session attachment on app/session load.** Loading a saved session automatically calls "attachPersistedSessionIfNeeded" when "session.remoteHost != nil" (Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:4471-4478). The coordinator launches "controller.attachAndCatchUp()" without a click (RemoteAgentModeCoordinator.swift:90-104); that calls "connection.subscribe" (RemoteAgentSessionController.swift:447-451), and subscribe calls "ensureConnected" (RemoteHostConnection.swift:198-204).

3. **Cold catalog load for an already remote-bound composer session.** Normal composer projection asks for "remoteHostCatalogSnapshot" (Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+ComposerUI.swift:21-23). A missing cache starts "remoteHostCatalog.catalog" (AgentModeViewModel.swift:1115-1147); its loader calls connect-on-demand "supportsAgentCatalog" and then "list_agents" (Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/RemoteHostCatalog.swift:607-624; RemoteHostConnection.swift:190-195).

A user selecting a remote run location also automatically preloads the catalog after that explicit selection (AgentModeViewModel+StatusPillsUI.swift:268-287). Remote start/steer/cancel/respond operations connect through "command", but are likewise explicit actions.

**Live-run implication:** source alone cannot identify which conditional path was active. If the paired host was already the active workspace’s default, a persisted session referenced it, or a remote-bound composer was active, Agent Mode can explain a no-Test-Connection first hello. If none of those conditions held and no remote action was taken, the remaining production initiator is the explicit Test Connection button. Pair completion by itself is not the initiator.

### 3. Timing and “permanently stale” sanity checks

#### 3(a). Is 15 seconds enough? — **CONFIRMED, conditional on an immediate initiator**

A successful trust fetch samples the app registry once, then the gateway sleeps 15 seconds (main.swift:211-256). Pair completion can therefore land anywhere in a nearly 15-second stale interval. Any connection started immediately by Test Connection, a newly activated sidebar task, persisted-session attach, or remote catalog load will usually reach "/api/ticket" and WebSocket hello before the next fetch. The only safe interleaving is for a trust fetch to complete after the app upsert and before hello admission, a much narrower interval than the post-fetch sleep. Thus two immediate re-pairs reproducing the race is timing-plausible and “same minute / Last connected: Never” is consistent with it.

The timing is **not** sufficient by itself if the only caller is an already-running sidebar loop whose next iteration occurs late enough for the next trust refresh to finish. The sidebar’s task executes immediately when its ID becomes active, but otherwise its steady polling interval is 20 seconds (AgentSessionsSidebarView.swift:144-152), longer than a normal healthy 15-second trust delay.

#### 3(b). Could trust synchronization fail forever? — **POSSIBLE AFTER AN EMPTY SNAPSHOT, but no expected window/config blocker found**

"remote_pairing" is explicitly app-wide: it bypasses logical-context, generic tab, window-selection, and window-routing requirements (Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:537-572):

~~~swift
nonisolated static func isAppWideTool(_ toolName: String) -> Bool {
    toolName == AppSettingsMCPService.toolName
        || toolName == MCPWindowToolName.remotePairing
}
~~~

Its app-wide service uses a synthetic "windowID: 0" (Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:58-91). "list_devices" requires no approval window and directly reads the identity store (same file:179-210, 435-449):

~~~swift
case .listDevices:
    return try executeListDevices(args: args, dependencies: dependencies)
~~~

Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPRemotePairingToolProvider.swift:435-449:

~~~swift
let includeRevoked = args["include_revoked"]?.boolValue ?? true
let host = try dependencies.identityStore.hostPublicKeyInfo()
let devices = try dependencies.identityStore.listDevices(includeRevoked: includeRevoked)
~~~

Every operation does require a verified gateway principal (same file:272-280). ServerController installs a launch-scoped credential in the app and passes it to the child (Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift:617-624, 652-669); the gateway includes it in the bootstrap handshake (Sources/RepoPromptGateway/AppLink/AppLinkSession.swift:320-334, 472-484); MCPConnectionManager constant-time checks it and rejects an invalid credential (Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:1606-1644, 4287-4295).

Important implications:

- there is no configuration branch disabling the trust task; main creates it unconditionally after server start;
- no window binding or consent UI can permanently block "list_devices";
- successful discovery/pair completion through the same GatewayPairingRelay/AppLink is strong evidence that the gateway principal and app link worked at that time;
- AppLinkSession.callTool centrally injects "_rawJSON: true", preventing formatted-Markdown results from making snapshot parsing fail (Sources/RepoPromptGateway/AppLink/AppLinkSession.swift:195-225):

  ~~~swift
  var arguments = arguments
  if arguments["_rawJSON"] == nil {
      arguments["_rawJSON"] = .bool(true)
  }
  ~~~

A gateway that **never** obtains any snapshot returns "trust_unavailable", which the client does not persist as revoked. The observed "unknown_device"-style sticky result instead requires either (i) a prior successful empty/stale snapshot followed by the ordinary 15-second race, or (ii) a prior empty snapshot plus all later refreshes failing. Case (ii) is code-possible because failures retain the last snapshot and retry forever, but the source reveals no expected live configuration/window cause. Storage/parse errors or recurring AppLink/tool-call failures remain possible and would need gateway stderr/audit evidence. AppLink reconnect exhaustion eventually emits ".failed", causing main to terminate the gateway rather than silently leaving it alive forever (Sources/RepoPromptGateway/main.swift:24-49, 260-266).

### 4. Quick confirmations

#### 4(a). Client unified logging — **CONFIRMED absent on pairing/connection infrastructure**

A scoped search of all 19 files under Sources/RepoPrompt/Infrastructure/RemoteHosts and Sources/RepoPrompt/Infrastructure/Security/RemotePairing found no "import OSLog", "Logger(...)", or "os_log". The relevant logger exists only in the Agent Mode session controller, outside pairing/connection infrastructure.

Sources/RepoPrompt/Features/AgentMode/Runtime/Remote/RemoteAgentSessionController.swift:1-3, 69-70:

~~~swift
import OSLog
~~~

~~~swift
private static let logger = Logger(
    subsystem: "com.repoprompt.agents",
    category: "RemoteControlClient"
)
~~~

Therefore an otherwise-correct "log show" predicate for "com.repoprompt.agents" / "RemoteControlClient" is expected to show nothing for discovery, pairing, ticket mint, and initial connection admission. That logger only covers higher-level remote Agent Mode session activity.

#### 4(b). Gateway logging and stderr destination — **CONFIRMED**

The gateway uses swift-log’s standard-error handler, not unified logging (Sources/RepoPromptGateway/main.swift:103-108):

~~~swift
LoggingSystem.bootstrap { label in
    StreamLogHandler.standardError(label: label)
}
var logger = Logger(label: "com.repoprompt.gateway")
logger.logLevel = .info
~~~

ServerController creates "Process", assigns executable/environment/termination handler, and calls "run()" without assigning "standardOutput" or "standardError" (Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift:652-674):

~~~swift
let process = Process()
process.executableURL = executableURL
var environment = ProcessInfo.processInfo.environment
~~~

~~~swift
process.environment = environment
process.terminationHandler = { process in
    didTerminate(.init(token: token, pid: process.processIdentifier))
}
try process.run()
~~~

RemoteGatewayProcessLifecycle only calls that injected launcher (Sources/RepoPrompt/Infrastructure/MCP/RemoteGatewayProcessLifecycle.swift:209-216). Thus the child descriptors are inherited from the app process; output is not redirected to a RepoPrompt file or bridged into unified logging. For a GUI-launched parent, inherited stderr may have no convenient persistent consumer.

#### 4(c). Separate gateway executable, signing, and firewall scope — **CONFIRMED code facts; OS behavior is an inference**

Scripts/package_app.sh separately builds the gateway (lines 241-245), copies it into "Contents/MacOS" (283-288), and signs it independently before the main executable/outer app (471-474):

~~~bash
phase "Building repoprompt-gateway ($CONF, host-native)"
run "$RUN_WITHOUT_GITHUB_TOKENS" swift build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-gateway
~~~

~~~bash
for exe in "$APP_NAME" repoprompt-mcp repoprompt-gateway; do
    [[ -x "$BUILD_DIR/$exe" ]] || fail "Missing built executable: $BUILD_DIR/$exe"
    run cp "$BUILD_DIR/$exe" "$APP_BUNDLE/Contents/MacOS/$exe"
    run chmod +x "$APP_BUNDLE/Contents/MacOS/$exe"
done
~~~

~~~bash
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-gateway"
~~~

Debug packaging prefers/accepts a stable identity but permits ad-hoc signing only when explicitly enabled; without either it fails (Scripts/package_app.sh:157-181):

~~~bash
if [[ "$ALLOW_ADHOC_SIGNING" != "1" && "$ALLOW_ADHOC_SIGNING" != "true" ]]; then
    fail "Debug ad-hoc signing is disabled by default. Set ALLOW_ADHOC_SIGNING=1 to build an ad-hoc package, or set SIGN_IDENTITY for stable signing."
fi
~~~

Because this separately signed executable owns the listening socket, macOS can prompt specifically for “repoprompt-gateway.” Rebuilding an ad-hoc-signed binary changes its code identity/hash and can invalidate a prior firewall authorization; a stable Apple Development designated requirement is more likely to persist. Prompt persistence is macOS policy, not behavior implemented by the script.

A firewall Deny blocks remote tailnet peers’ inbound access to the Tailscale-bound listener: discovery, "/api/pair/begin", "/api/pair/complete", "/api/ticket", and "/ws" (relay paths: Sources/RepoPromptGateway/Server/GatewayPairingRelay.swift:21-31; socket bind: Sources/RepoPromptGateway/Server/GatewayHTTPServer.swift:128-132). It does not block the gateway’s local bootstrap/AppLink IPC. Since discovery and pairing succeeded in the reported run, a blanket inbound Deny does not explain the later "unknown_device" behavior.


## Investigation Log

### Phase 1 — Triage
**Hypothesis:** see H1–H6 above.
**Findings:** Report created; dispatched context builder (oracle chat `revoked-after-pairing-di-58C71E`) + pair investigator.

### Phase 2/3 — Context builder oracle + pair investigator
**Hypothesis:** H1–H6.
**Findings:** Oracle fingered H2 (gateway trust-snapshot staleness) + client-side sticky mapping; pair investigator verified every link with file:line evidence (see `## Investigator Findings`). Orchestrator independently re-verified the load-bearing claims: `RemoteClientError.swift:40-41` (`device_revoked`/`unknown_device` → `.revoked`; `trust_unavailable` → `.authentication`), `main.swift:103-108` (swift-log stderr, level `.info`) and `:211-259` (first fetch before first sleep, failures at `.debug`, fixed 15s cadence), `RemoteHostConnection.swift:318-350` (`unknown_device` → `markRevoked()`), `:352-356` (sticky `revokedByHostAt` guard).
**Conclusion:** H2 CONFIRMED as root cause; H1 partially confirmed (the client mapping/persistence half); H3, H4, H5, H6 REFUTED (see verdict table in Investigator Findings and Phase 4 below).

### Phase 4 — Oracle synthesis (alternate explanations, fix ranking, live verification)
**Hypothesis:** is any scenario other than the 15s race consistent with the evidence?
**Findings:**
- The observed *revoked* UI proves the gateway returned `unknown_device` (not `trust_unavailable`), which itself proves ≥1 trust sync succeeded → AppLink/gateway-principal plumbing works → staleness is the mechanism.
- Gateway-restart scenario ruled out: a fresh gateway's first trust fetch runs *before* its first sleep, i.e. after the pairing upsert, so its snapshot would include the device; pre-sync it returns `trust_unavailable`, which is non-revoking on the client.
- `GatewayTrustSnapshot.parse` cannot silently drop one device: `deviceValue()` always emits `id`/`public_key`; `counter_floor` has a `?? 0` fallback; a malformed record fails the whole sync (keeping the old snapshot).
- Debug ephemeral-keychain churn refuted for this incident: key stable within a launch; churn would manifest as fingerprint/`ticket_signature_invalid` errors, never `unknown_device` (device lookup precedes ticket verification); and the client verified the minted ticket against the pinned host key.
- Only falsifiable long-shot: trust sync failing persistently after one early empty success (silent because failures log at `.debug` under an `.info` logger). Eliminated by live test: forget → re-pair → wait 45s → Test Connection succeeds ⇒ race confirmed; still fails ⇒ persistent-sync-failure scenario.
**Conclusion:** H2-race committed as root cause; one falsifiable long-shot documented with a discriminating live test.

### Phase 5 — Path verification for live diagnostics
**Findings (orchestrator-verified):**
- Host trust store: `~/Library/Application Support/RepoPrompt CE/RemoteControl/debug/paired-devices-v1.json` (`RemotePairingIdentityStore.fileName`, `RemoteControlStorageNamespace.rootComponents` + channel).
- Client registry: `~/Library/Application Support/RepoPrompt CE/RemoteControl/debug/remote-hosts-v1.json` (`RemoteHostRegistry.fileName`).
- Gateway audit log: `~/Library/Application Support/RepoPrompt CE/RemoteControl/debug/GatewayRuntime/RemoteGateway/audit/*.jsonl` (ServerController passes `appSupportRoot = gatewayRuntimeRootURL()` = `<root>/GatewayRuntime` at `ServerController.swift:497,661`; gateway defaults audit dir to `<appSupportRoot>/RemoteGateway/audit` at `GatewayConfiguration.swift:71-74`). Hello denials are audited with the exact rejection code — this is the durable diagnostic channel that exists today.
- Note: `remote_pairing` MCP ops are gateway-principal-gated (`MCPRemotePairingToolProvider.swift:272-280`), so `rpce-cli-debug -c remote_pairing …` is rejected; use the on-disk JSON artifacts instead.

## Root Cause
**Trust-propagation race between the app (trust authority) and the gateway (authenticator), made permanent by the client's error mapping.**

Chain (all verified, file:line):
1. Pairing completes app-side: `MCPRemotePairingToolProvider.executeCompletePairing` → `identityStore.upsertDevicePreservingCounterFloor` (`MCPRemotePairingToolProvider.swift:361-384`). Nothing notifies the gateway.
2. `/api/ticket` relays to the app's fresh registry (`GatewayPairingRelay.swift:153-165` → `executeMintTicket`, `MCPRemotePairingToolProvider.swift:387-419`) → **mint succeeds**.
3. WS hello is authenticated gateway-side against `GatewayTrustSnapshot`, refreshed only by the 15s poll (`main.swift:211-259`); the just-paired device is absent → `DeviceAuthenticator.admitHello` throws `unknownDevice` → wire code `unknown_device` (`DeviceAuthenticator.swift:100-132, 232-251`), forwarded verbatim as `command_error` and channel close (`GatewayHTTPServer.swift:730-745`).
4. Client maps `unknown_device` → `.revoked` (`RemoteClientError.swift:40-41`), `openConnectionWithImmediateRetries` calls `markRevoked()` (`RemoteHostConnection.swift:318-350, 889-905`) → `registry.markRevokedByHost` persists `revokedByHostAt` (`RemoteHostRegistry.swift:148-177`).
5. Every later connect short-circuits on `record.revokedByHostAt != nil` (`RemoteHostConnection.swift:352-356`); Test Connection is disabled for revoked rows. A later successful gateway trust refresh cannot self-heal the client record. Only Forget → re-pair resets it — and re-entry into the ≤15s window (auto-initiators fire immediately; `forgetHost` leaves workspace `defaultRemoteHostID` bound and the host fingerprint/ID is unchanged, so the sidebar refresh task re-arms instantly — `AgentSessionsSidebarView.swift:144-152`, `AgentModeViewModel+SidebarSessions.swift:506-528`) makes the transient race present as a deterministic failure.

"Last connected: Never" is consistent: `updateLastConnected` fires only in `handleHelloAck`, which was never reached.

**Eliminated hypotheses:** H3 (approval contexts — failures surface during begin/complete, pairing succeeded), H4 (single device-ID derivation `RemotePairingCrypto.deviceID(forRawPublicKey:)` used by client, app, and snapshot alike), H5 (fresh `counterFloor = 0`, counter check sits after the failing device lookup; `counter_replayed` maps to retry, not revoked), H6 (gateway restart would *fix* not cause this — first fetch precedes first sleep; pre-sync state yields non-revoking `trust_unavailable`), debug ephemeral-keychain churn (would yield signature/fingerprint errors, not `unknown_device`).

**Secondary latent defect (not the trigger here):** `ticketHTTPError` substring heuristics (`RemoteHostConnection.swift:507-528`) persist revocation on ANY ticket HTTP error whose free-text message contains "revoked" or "no paired device" — a second, more fragile sticky-revocation entrance.

**Answers to the two side questions:**
- **Empty `log show`:** expected. Zero `os_log`/`os.Logger` usage in `Infrastructure/RemoteHosts/*` and `Infrastructure/Security/RemotePairing/*`; the only `com.repoprompt.agents`/`RemoteControlClient` logger is `RemoteAgentSessionController.swift:70` (live session streaming only). The gateway uses swift-log → stderr (`main.swift:103-108`), inherited/unredirected by the launcher (`ServerController.swift:652-674`), so nothing reaches unified logging; its trust-sync failures are additionally logged at `.debug` below the `.info` level — the one component that could have explained the incident was silenced twice over. (The smart quotes in the pasted command would also have broken the predicate, but a correct query still returns nothing.)
- **Firewall prompt:** expected. `repoprompt-gateway` is a separately built and separately signed executable (`Scripts/package_app.sh:241-245, 283-288, 471-474`) owning a non-loopback listener on the Tailscale IPv4 (debug port 47392). Ad-hoc/debug signing churn changes its code identity per rebuild and re-triggers the prompt; a stable Apple Development identity persists the authorization. Deny blocks ALL inbound tailnet traffic (discovery, `/api/pair/*`, `/api/ticket`, `/ws`) while the app↔gateway Unix socket stays healthy — host looks fine locally but is invisible to clients. Since discovery and pairing succeeded here, the prompt was Allowed and is unrelated to the revocation.

## Recommendations
Ranked (1 is the actual bug-fix; 2–4 close the window and remove the latent second entrance):

1. **Client — stop persisting revocation on `unknown_device` (necessary).** Reserve `markRevoked()` for explicit `device_revoked` in all three entrances: `RemoteClientError.fromCommandError` (`RemoteClientError.swift:40-41`), `openConnectionWithImmediateRetries` (`RemoteHostConnection.swift:326-345`), and the uncorrelated `command_error` handler (~L813-817). Map `unknown_device` to `.authentication` (retryable, like `trust_unavailable`), ideally with one bounded delayed retry. This alone converts the permanent failure into a ≤15s transient; without it, any future gateway skew re-poisons the record.
2. **Gateway — trigger an immediate trust re-sync after a successful `complete_pairing` relay (strongly recommended).** `GatewayPairingRelay` already sees the `ok: true` response in-band — no new IPC needed. Don't fetch inside the relay actor: nudge the trust-sync loop (e.g. `AsyncStream` wake) so all snapshot installs funnel through the single `authenticator.updateTrust` + `appLinkPool.applyTrustSnapshot` path, with a generation guard so an older poll result can't overwrite a newer snapshot.
3. **Gateway — fetch-on-miss in `admitHello` (deterministic backstop).** On `unknown_device`, refresh once before rejecting, guarded by: single-flight, min-interval throttle (~2–5s; misses during cooldown reject immediately), at most one refresh per hello, and a short fetch timeout (~3s) falling through to `unknown_device` on failure (harmless once #1 lands). Guards matter: hellos are unauthenticated at the lookup point → unknown-device spray must not amplify into app tool calls.
4. **Client — remove `ticketHTTPError` substring heuristics (`RemoteHostConnection.swift:507-528`).** Give `mint_ticket` structured expected-failure codes (`device_not_paired`, `device_revoked`) via `executeExpectedFailureBoundary`, whitelist them in `GatewayPairingRelay.allowedExpectedFailureCodes`, and switch on `code` client-side — persist revocation only for `device_revoked`.
5. **One-liner while there:** raise the trust-sync failure log from `.debug` to `.warning` (`main.swift` catch block) so sync failures are no longer silent.

### Live verification (before/after fix; two Macs, debug builds)
- **Smoking gun (evidence already on disk from the incident):** on the host —
  `grep -h '"op":"hello"' "$HOME/Library/Application Support/RepoPrompt CE/RemoteControl/debug/GatewayRuntime/RemoteGateway/audit/"*.jsonl | grep denied`
  Expect a denial at ~01:48 with `code: "unknown_device"` for `remote:9ba3ebf2`, preceded seconds earlier by a successful `mint_ticket` record. (If it says `trust_unavailable` or `device_revoked` instead, the diagnosis changes — report back.)
- **Host state sanity:** `cat "$HOME/Library/Application Support/RepoPrompt CE/RemoteControl/debug/paired-devices-v1.json"` — the device record should exist and not be revoked (host-side trust is fine while the client shows revoked). Client mirror: `remote-hosts-v1.json` on the controller, `revokedByHostAt` matching the audit denial.
- **Decisive timing test:** client: Forget → re-pair → **wait 45s doing nothing** (stay on the Settings pane; the workspace sidebar auto-initiator otherwise re-arms) → Test Connection. Success ⇒ 15s-staleness race confirmed and the persistent-sync-failure long shot eliminated. Negative control: forget → re-pair → Test Connection within ~3s ⇒ expect "Revoked by host" again.
- Note: `rpce-cli-debug -c remote_pairing …` will NOT work — the tool is restricted to the verified gateway principal.
- Gateway stderr, if wanted: launch the debug app from Terminal (`".../DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt" 2>>/tmp/rp-gateway.log`); trust-sync failures still won't appear until the `.debug`→`.warning` change lands — the audit log is the better instrument.

## Preventive Measures
1. **Integration test for pair→immediate-connect:** gateway-level test completing pairing and issuing a hello *before* the next trust poll, asserting admission post-fix. This exact seam had zero coverage — all pairing tests exercise the app tool directly and all auth tests pre-seed the snapshot.
2. **Client invariant test:** a freshly paired record must never become `revokedByHostAt != nil` from a single transient handshake failure; only explicit `device_revoked` may persist revocation.
3. **Error-code taxonomy rule:** "identity unknown" (`unknown_device`, possibly-stale view) and "identity distrusted" (`device_revoked`, authoritative) must never share a client consequence; retire message-substring matching in favor of structured codes end-to-end.
4. **Observability:** add os_log (`com.repoprompt.agents`, categories e.g. `RemoteControlPairing`/`RemoteControlConnection`) to `RemoteHostPairingClient`, `RemoteHostConnection` (state transitions, error codes, `markRevoked` reason), `RemoteHostDiscoveryService`; capture gateway stderr to a file under `GatewayRuntime/`; raise trust-sync failure logging above the configured level floor. Document the audit-log location as the primary field-diagnostic channel.
5. **UX/docs:** document the expected firewall prompt (and that Deny silently makes the host undiscoverable while looking healthy locally); consider a host-side self-probe surfacing a "blocked by firewall" status. Clear or re-validate workspace `defaultRemoteHostID` on `forgetHost` so forget/re-pair doesn't silently re-arm auto-connect.
6. **Process:** run the two-Mac live acceptance before shipping trust-plane changes — this defect was invisible to a four-round security review + Oracle review because every test doubled or pre-seeded the trust snapshot; the 15s poll × client stickiness interaction only manifests on real hardware timing.
