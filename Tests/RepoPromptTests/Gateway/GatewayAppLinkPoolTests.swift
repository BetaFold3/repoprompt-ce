import CryptoKit
import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Connector double that records the clientName presented at bootstrap and can
/// simulate app-side capacity rejections per device.
private final class PoolRecordingConnector: AppLinkConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var connectedClientNames: [String] = []
    private(set) var connections: [String: PoolRecordingConnection] = [:]
    var rejectionsByClientName: [String: AppLinkError] = [:]
    var connectGate: PoolConnectGate?

    func connect(
        configuration _: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        lock.lock()
        connectedClientNames.append(clientName)
        let rejection = rejectionsByClientName[clientName]
        lock.unlock()
        if let rejection {
            throw rejection
        }
        if let connectGate {
            await connectGate.waitIfNeeded()
        }
        let connection = PoolRecordingConnection()
        lock.lock()
        connections[clientName] = connection
        lock.unlock()
        return connection
    }

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectedClientNames.count
    }
}

private actor PoolRecordingConnection: AppLinkConnection {
    private(set) var disconnected = false
    private(set) var callTimeouts: [TimeInterval?] = []
    var nextResult: MCPToolResult?

    func setNextResult(_ result: MCPToolResult) {
        nextResult = result
    }

    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout: TimeInterval?
    ) async throws -> MCPToolResult {
        callTimeouts.append(timeout)
        return nextResult ?? GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "is_current_window": .bool(true),
                    "workspace": .object([
                        "id": .string("44444444-4444-4444-4444-444444444444"),
                        "name": .string("Workspace A")
                    ])
                ])
            ]),
            "binding": .object([
                "binding_kind": .string("window"),
                "window_id": .int(1)
            ])
        ]))
    }

    func disconnect() async {
        disconnected = true
    }
}

private final class ManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(_ time: TimeInterval = 0) {
        self.time = time
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        time += interval
        lock.unlock()
    }
}

private final class BindingProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AppLinkPool.BindingProbeResult]
    private(set) var callCount = 0

    init(_ states: [AppLinkPool.BindingProbeResult]) {
        self.states = states
    }

    func next() -> AppLinkPool.BindingProbeResult {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if states.isEmpty { return .bound }
        return states.removeFirst()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private actor PoolConnectGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitIfNeeded() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

final class GatewayAppLinkPoolTests: XCTestCase {
    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var connector: PoolRecordingConnector!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try GatewayTestHelpers.temporaryRoot("app-link-pool")
        configuration = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        connector = PoolRecordingConnector()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makePool(
        bindingProbe: AppLinkPool.BindingProbe? = nil,
        unknownBindingRefreshCooldown: TimeInterval = 0,
        now: @escaping AppLinkPool.MonotonicNow = { ProcessInfo.processInfo.systemUptime }
    ) -> AppLinkPool {
        AppLinkPool(
            configuration: configuration,
            connector: connector,
            bindingProbe: bindingProbe ?? { _ in .bound },
            unknownBindingRefreshCooldown: unknownBindingRefreshCooldown,
            now: now
        )
    }

    private func makeRuntime(pool: AppLinkPool) async throws -> RemoteGatewayRuntime {
        let defaultConnection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: defaultConnection)
        )
        try await appLink.connect()
        return try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: appLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )
    }

    func testPerDeviceLinkUsesDeviceIDAsClientName() async throws {
        let pool = makePool()
        let session = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")

        XCTAssertEqual(session.clientName, "remote:1a2b3c4d")
        XCTAssertEqual(connector.connectedClientNames, ["remote:1a2b3c4d"])
    }

    func testEnsureLinkReusesExistingSession() async throws {
        let pool = makePool()
        let first = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")
        let second = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")

        XCTAssertTrue(first === second)
        XCTAssertEqual(connector.connectCount, 1)

        // A different device opens its own link.
        _ = try await pool.ensureLink(forDevice: "remote:eeff0011")
        XCTAssertEqual(connector.connectedClientNames, ["remote:1a2b3c4d", "remote:eeff0011"])
        let ids = await pool.activeDeviceIDs
        XCTAssertEqual(ids, ["remote:1a2b3c4d", "remote:eeff0011"])
    }

    func testConcurrentEnsureLinkForSameDeviceSharesInFlightConnect() async throws {
        let gate = PoolConnectGate()
        connector.connectGate = gate
        let pool = makePool()
        let deviceID = "remote:1a2b3c4d"

        async let first = pool.ensureLink(forDevice: deviceID)
        await gate.waitUntilStarted()
        async let second = pool.ensureLink(forDevice: deviceID)
        await Task.yield()
        await gate.release()

        let (firstSession, secondSession) = try await (first, second)
        XCTAssertTrue(firstSession === secondSession)
        XCTAssertEqual(connector.connectedClientNames, [deviceID])
        XCTAssertEqual(connector.connectCount, 1)
        let ids = await pool.activeDeviceIDs
        XCTAssertEqual(ids, [deviceID])
    }

    func testBindAtConnectSingleWindowAutoBinds() async throws {
        // App-side auto-bind succeeds: the benign probe returns a normal result.
        let pool = AppLinkPool(configuration: configuration, connector: connector)
        _ = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")

        let state = await pool.bindingState(forDevice: "remote:1a2b3c4d")
        XCTAssertEqual(state, .bound)
    }

    func testBindAtConnectMultiWindowRecordsBindingRequired() async throws {
        let pool = makePool(bindingProbe: { _ in
            .bindingRequired("Multiple windows are open; select a window before remote operations.")
        })
        _ = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")

        let state = await pool.bindingState(forDevice: "remote:1a2b3c4d")
        guard case .bindingRequired = state else {
            return XCTFail("Expected bindingRequired, got \(state)")
        }
    }

    func testDefaultBindingProbeDetectsWindowBindError() async throws {
        let session = AppLinkSession(
            config: configuration,
            clientName: "remote:1a2b3c4d",
            connector: connector
        )
        try await session.connect()
        let connection = try XCTUnwrap(connector.connections["remote:1a2b3c4d"])
        await connection.setNextResult(GatewayTestHelpers.toolResult(
            json: .object(["error": .string("No window is bound to this connection; select a window first.")]),
            isError: true
        ))

        let result = await AppLinkPool.defaultBindingProbe(session: session)
        guard case .bindingRequired = result.state else {
            return XCTFail("Expected bindingRequired, got \(result)")
        }
    }

    func testBindingRequiredLinkRejectsOperationsThroughRuntime() async throws {
        let pool = makePool(bindingProbe: { _ in
            .bindingRequired("Multiple windows are open; select a window before remote operations.")
        })
        _ = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")

        let defaultConnection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: defaultConnection)
        )
        try await appLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: appLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let frame = RemoteClientFrame(type: "list_sessions")
        let sink = RecordingFrameSink()
        let response = await runtime.handle(frame, deviceID: "remote:1a2b3c4d", sinkID: UUID(), sink: sink)

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        // The bound-device translator failure must occur before any app tool call.
        let deviceConnection = connector.connections["remote:1a2b3c4d"]
        XCTAssertNotNil(deviceConnection)
    }

    func testRemoteDeviceWithoutPoolLinkDoesNotFallBackToDefaultAppLink() async throws {
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:1a2b3c4d")
        let pool = makePool()
        _ = try await pool.ensureLink(forDevice: device.deviceID)
        _ = await pool.teardown(deviceID: device.deviceID)

        let defaultConnection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["sessions": .array([])])))
        ])
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: defaultConnection)
        )
        try await appLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: appLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: device.deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "app_link_unavailable")
        let calls = await defaultConnection.calls
        XCTAssertTrue(calls.isEmpty, "A remote device without its own app link must not borrow the gateway-principal link")
    }

    func testBindingStateRefreshAllowsPreviouslyBindingRequiredLinkToRecover() async throws {
        let probeResults = BindingProbeSequence([
            .bindingRequired("Multiple windows are open; select a window before remote operations."),
            .bound
        ])
        let pool = makePool(bindingProbe: { _ in
            probeResults.next()
        })
        _ = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")
        guard case .bindingRequired = await pool.bindingState(forDevice: "remote:1a2b3c4d") else {
            return XCTFail("Expected initial bindingRequired state")
        }

        let refreshed = await pool.refreshBindingState(forDevice: "remote:1a2b3c4d")
        XCTAssertEqual(refreshed, .bound)
        let finalState = await pool.bindingState(forDevice: "remote:1a2b3c4d")
        XCTAssertEqual(finalState, .bound)
    }

    func testDefaultBindingProbeDetectsMultiWindowBindContextList() async throws {
        let session = AppLinkSession(
            config: configuration,
            clientName: "remote:1a2b3c4d",
            connector: connector
        )
        try await session.connect()
        let connection = try XCTUnwrap(connector.connections["remote:1a2b3c4d"])
        await connection.setNextResult(GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object(["window_id": .int(1)]),
                .object(["window_id": .int(2)])
            ]),
            "binding": .object(["binding_kind": .string("unbound")])
        ])))

        let result = await AppLinkPool.defaultBindingProbe(session: session)
        guard case .bindingRequired = result.state else {
            return XCTFail("Expected bindingRequired, got \(result)")
        }
        XCTAssertFalse(result.refreshOnNextResolve)
    }

    func testDefaultBindingProbeTransportErrorReturnsUnknown() async throws {
        let connection = RecordingAppLinkConnection(responses: [.timeout(10)])
        let session = AppLinkSession(
            config: configuration,
            clientName: "remote:1a2b3c4d",
            connector: StaticAppLinkConnector(connection: connection)
        )
        try await session.connect()

        let result = await AppLinkPool.defaultBindingProbe(session: session)
        XCTAssertEqual(result.state, .bound)
        XCTAssertTrue(result.refreshOnNextResolve)
    }

    func testUnknownBindingProbeStateRefreshesOnNextResolve() async throws {
        let probeResults = BindingProbeSequence([.unknown, .bound])
        let pool = makePool(bindingProbe: { _ in probeResults.next() })
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        let initialState = await pool.bindingState(forDevice: deviceID)
        let initialRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertEqual(initialState, .bound)
        XCTAssertTrue(initialRequiresRefresh)

        let runtime = try await makeRuntime(pool: pool)
        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(probeResults.count, 2)
        let finalRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertFalse(finalRequiresRefresh)
    }

    func testUnknownBindingProbeCooldownSuppressesImmediateResolveRefresh() async throws {
        let clock = ManualMonotonicClock()
        let probeResults = BindingProbeSequence([.unknown, .bound])
        let pool = makePool(
            bindingProbe: { _ in probeResults.next() },
            unknownBindingRefreshCooldown: 4,
            now: { clock.now() }
        )
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        XCTAssertEqual(probeResults.count, 1)
        let immediateRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertFalse(immediateRequiresRefresh)

        let runtime = try await makeRuntime(pool: pool)
        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(probeResults.count, 1)
    }

    func testUnknownBindingProbeCooldownRefreshesAfterExpiry() async throws {
        let clock = ManualMonotonicClock()
        let probeResults = BindingProbeSequence([.unknown, .unknown])
        let pool = makePool(
            bindingProbe: { _ in probeResults.next() },
            unknownBindingRefreshCooldown: 4,
            now: { clock.now() }
        )
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        clock.advance(by: 4.1)
        let expiredRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertTrue(expiredRequiresRefresh)

        let runtime = try await makeRuntime(pool: pool)
        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(probeResults.count, 2)
        let resetRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertFalse(resetRequiresRefresh)
    }

    func testSuccessfulBindingProbeRefreshClearsUnknownCooldown() async throws {
        let clock = ManualMonotonicClock()
        let probeResults = BindingProbeSequence([.unknown, .bound, .unknown])
        let pool = makePool(
            bindingProbe: { _ in probeResults.next() },
            unknownBindingRefreshCooldown: 4,
            now: { clock.now() }
        )
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        clock.advance(by: 4.1)

        let runtime = try await makeRuntime(pool: pool)
        let firstResponse = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(firstResponse?.type, "command_result")
        XCTAssertEqual(probeResults.count, 2)
        let clearedRequiresRefresh = await pool.bindingStateRequiresRefresh(forDevice: deviceID)
        XCTAssertFalse(clearedRequiresRefresh)

        clock.advance(by: 4.1)
        let secondResponse = await runtime.handle(
            RemoteClientFrame(type: "list_sessions"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(secondResponse?.type, "command_result")
        XCTAssertEqual(probeResults.count, 2)
    }

    func testDefaultRefreshBindingProbeUsesShorterTimeoutThanInitialConnect() async throws {
        let pool = AppLinkPool(
            configuration: configuration,
            connector: connector,
            unknownBindingRefreshCooldown: 0
        )
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        await pool.setBindingState(.bound, forDevice: deviceID, refreshOnNextResolve: true)

        _ = await pool.refreshBindingState(forDevice: deviceID)

        let connection = try XCTUnwrap(connector.connections[deviceID])
        let timeouts = await connection.callTimeouts
        XCTAssertEqual(timeouts, [
            AppLinkPool.defaultInitialBindingProbeTimeout,
            AppLinkPool.defaultRefreshBindingProbeTimeout
        ])
    }

    func testTeardownOnRevokeClosesLink() async throws {
        let hostKey = P256.Signing.PrivateKey()
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:1a2b3c4d")
        let pool = makePool()
        _ = try await pool.ensureLink(forDevice: device.deviceID)

        let revokedSnapshot = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostKey,
            devices: [(device, true)]
        )
        let tornDown = await pool.applyTrustSnapshot(revokedSnapshot)

        XCTAssertEqual(tornDown, [device.deviceID])
        let session = await pool.session(forDevice: device.deviceID)
        XCTAssertNil(session)
        let connection = try XCTUnwrap(connector.connections[device.deviceID])
        let disconnected = await connection.disconnected
        XCTAssertTrue(disconnected, "Revocation must tear down the device app link")
    }

    func testTeardownForUnpairedDeviceAndRetentionForPairedDevice() async throws {
        let hostKey = P256.Signing.PrivateKey()
        let paired = GatewayAuthTestSupport.makeDevice(deviceID: "remote:1a2b3c4d")
        let unpaired = GatewayAuthTestSupport.makeDevice(deviceID: "remote:eeff0011")
        let pool = makePool()
        _ = try await pool.ensureLink(forDevice: paired.deviceID)
        _ = try await pool.ensureLink(forDevice: unpaired.deviceID)

        let snapshot = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostKey,
            devices: [(paired, false)]
        )
        let tornDown = await pool.applyTrustSnapshot(snapshot)

        XCTAssertEqual(tornDown, [unpaired.deviceID])
        let pairedSession = await pool.session(forDevice: paired.deviceID)
        XCTAssertNotNil(pairedSession)
    }

    func testCapacityRejectionSurfacesAsTypedCapacityError() async throws {
        for code in ["capacity_exceeded", "connection_limit_reached"] {
            let deviceID = "remote:\(code.prefix(4))1234"
            connector.rejectionsByClientName[deviceID] = .handshakeRejected(
                errorCode: code,
                reason: "Server at capacity"
            )
            let pool = makePool()
            do {
                _ = try await pool.ensureLink(forDevice: deviceID)
                XCTFail("Expected capacity rejection for \(code)")
            } catch let error as AppLinkPoolError {
                XCTAssertEqual(error, .connectionCapacity(code: code, reason: "Server at capacity"))
                XCTAssertEqual(error.code, code)
            }
        }
    }

    func testNonCapacityConnectFailureIsNotSilent() async throws {
        connector.rejectionsByClientName["remote:1a2b3c4d"] = .handshakeRejected(
            errorCode: "approval_denied",
            reason: "Denied"
        )
        let pool = makePool()
        do {
            _ = try await pool.ensureLink(forDevice: "remote:1a2b3c4d")
            XCTFail("Expected connect failure")
        } catch let error as AppLinkPoolError {
            guard case .connectFailed = error else {
                return XCTFail("Expected connectFailed, got \(error)")
            }
            XCTAssertEqual(error.code, "app_link_unavailable")
        }
    }
}
