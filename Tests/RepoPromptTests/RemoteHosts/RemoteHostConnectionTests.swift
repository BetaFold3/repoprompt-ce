import CryptoKit
import Foundation
@testable import RepoPromptApp
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class RemoteHostConnectionTests: XCTestCase {
    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!
    private var authenticator: DeviceAuthenticator!
    private var appConnection: RecordingAppLinkConnection!
    private var appLink: AppLinkSession!
    private var watchManager: SessionWatchManager!
    private var server: GatewayHTTPServer!
    private var port: Int!
    private var registry: RemoteHostRegistry!
    private var keyStore: RemoteClientKeyStore!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("remote-host-connection")
        configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--port", "0"
            ],
            environment: [:]
        )
        hostSigner = P256.Signing.PrivateKey()
        device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:11223344")
        authenticator = try DeviceAuthenticator(
            usedTicketStore: GatewayAuthTestSupport.makeUsedTicketStore(root: root),
            trust: GatewayAuthTestSupport.trustSnapshot(
                hostSigner: hostSigner,
                devices: [(device, false)]
            )
        )

        appConnection = RecordingAppLinkConnection()
        appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: appConnection)
        )
        try await appLink.connect()

        watchManager = SessionWatchManager(appLink: appLink)
        let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog
        )
        let pairingRelay = GatewayPairingRelay(appLink: appLink, auditLog: auditLog)
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            auditLog: auditLog,
            pairingRelay: pairingRelay,
            hostName: "N3 Test Host"
        )
        try await server.start()
        port = try XCTUnwrap(server.localAddress?.port)

        let registryDirectory = root.appendingPathComponent("client-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: registryDirectory))
        keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
    }

    override func tearDown() async throws {
        if let server {
            await server.shutdown()
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testConnectionMintsTicketHelloPingsAndDisconnects() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        let result = try await connection.testConnection(timeout: 5)

        XCTAssertEqual(result.hostID, record.id)
        XCTAssertEqual(result.hostName, "N3 Test Host")
        XCTAssertEqual(result.scopes, record.grantedScopes)
        XCTAssertEqual(result.pongPayload.objectValue?["probe"]?.stringValue, "settings_test_connection")
        let disconnectedState = await connection.currentState()
        XCTAssertEqual(disconnectedState, .idle)
        let persisted = try XCTUnwrap(registry.host(id: record.id))
        XCTAssertNotNil(persisted.lastConnectedAt)
        XCTAssertGreaterThan(persisted.lastCounter, 0)
    }

    func testTicketMintDoesNotSendVolatileHostWindowID() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        let result = try await connection.testConnection(timeout: 5)

        XCTAssertEqual(result.hostID, record.id)
        let calls = await appConnection.calls
        let ticketCall = try XCTUnwrap(calls.first { call in
            call.name == "remote_pairing" && call.arguments["op"]?.stringValue == "mint_ticket"
        })
        XCTAssertNil(ticketCall.arguments["_windowID"])
        XCTAssertNil(ticketCall.arguments["window_id"])
    }

    func testUsedTicketAtHelloRetriesWithFreshTicket() async throws {
        let record = try upsertClientRecord()
        let firstTicket = await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        try await connection.ensureConnected()
        await connection.disconnect()

        await enqueueTicket(firstTicket)
        let freshTicket = await enqueueTicket()
        try await connection.ensureConnected()

        guard case let .connected(scopes) = await connection.currentState() else {
            XCTFail("Expected connection to recover with a fresh ticket")
            return
        }
        XCTAssertEqual(scopes, record.grantedScopes)
        XCTAssertNotEqual(firstTicket.ticketID, freshTicket.ticketID)
        await connection.disconnect()
    }

    func testSubscribeRearmsAfterReconnect() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        try await connection.subscribe(sessionIDs: ["session-a"])
        guard case let .connected(initialScopes) = await connection.currentState() else {
            XCTFail("Expected subscribe to leave the channel connected")
            return
        }
        XCTAssertEqual(initialScopes, record.grantedScopes)

        await connection.disconnect()
        await enqueueTicket()
        try await connection.ensureConnected()
        guard case let .connected(rearmedScopes) = await connection.currentState() else {
            XCTFail("Expected reconnect with subscription re-arm to leave the channel connected")
            return
        }
        XCTAssertEqual(rearmedScopes, record.grantedScopes)

        await connection.disconnect()
    }

    func testRevocationDuringHelloMarksRegistryAndStopsRetrying() async throws {
        let record = try upsertClientRecord()
        _ = await authenticator.updateTrust(GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, true)]
        ))
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        do {
            try await connection.ensureConnected()
            XCTFail("Expected revoked host credentials to fail connection")
        } catch let error as RemoteClientError {
            guard case .revoked = error else {
                XCTFail("Expected revoked error, got \(error)")
                return
            }
        }

        XCTAssertNotNil(try registry.host(id: record.id)?.revokedByHostAt)
        let revokedState = await connection.currentState()
        XCTAssertEqual(revokedState, .revoked)
    }

    func testUnknownServerFramesAreIgnored() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let frameTask = nextFrameTask(from: connection.inboundFrames, timeout: 0.2)

        await connection.handleServerFrameForTesting(RemoteServerFrame(type: "future_frame"))

        do {
            _ = try await frameTask.value
            XCTFail("Unknown server frame should not be yielded to inbound consumers")
        } catch RemoteClientError.timeout {
            // Expected.
        } catch {
            throw error
        }
    }

    func testInboundStreamYieldsKnownServerFrames() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let frameTask = nextFrameTask(from: connection.inboundFrames, ofType: "session_update", timeout: 1)

        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "session-a",
            seq: 1,
            payload: GatewayTestHelpers.snapshot(sessionID: "session-a", status: "running")
        ))

        let frame = try await frameTask.value
        XCTAssertEqual(frame.type, "session_update")
        XCTAssertEqual(frame.sessionID, "session-a")
    }

    @MainActor
    func testManagerReusesSingleConnectionPerHost() throws {
        let record = try upsertClientRecord()
        let manager = RemoteHostConnectionManager(registry: registry, keyStore: keyStore)

        let first = try manager.connection(for: record.id)
        let second = try manager.connection(for: record.id)

        XCTAssertTrue(first === second)
    }

    func testCounterPersistenceCoalescesUntilFlush() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            counterWriteCoalescingDelay: 60
        )

        await connection.persistCounterForTesting(10)
        await connection.persistCounterForTesting(7)
        await connection.persistCounterForTesting(25)

        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 0)
        await connection.flushPendingCounterForTesting()
        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 25)
    }

    func testDisconnectFlushesPendingCounterWrite() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            counterWriteCoalescingDelay: 60
        )

        await connection.persistCounterForTesting(33)
        await connection.disconnect()

        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 33)
    }

    func testChannelClosingSchedulesSingleReconnectLoopForMultipleSubscriptions() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            initialReconnectBackoff: 60
        )

        try await connection.subscribe(sessionIDs: ["session-a", "session-b"])
        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string("app_link_unavailable"),
                "message": .string("App link unavailable")
            ])
        ))
        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string("app_link_unavailable"),
                "message": .string("App link unavailable")
            ])
        ))

        let reconnectScheduleCount = await connection.reconnectScheduleCountForTesting()
        let hasReconnectTask = await connection.hasReconnectTaskForTesting()
        XCTAssertEqual(reconnectScheduleCount, 1)
        XCTAssertTrue(hasReconnectTask)
        await connection.disconnect()
    }

    @discardableResult
    private func upsertClientRecord(
        scopes: Set<String> = [GatewayRemoteScope.sessionsObserve, GatewayRemoteScope.sessionsOperate]
    ) throws -> PairedHostRecord {
        let record = PairedHostRecord(
            id: GatewayAuthTestSupport.fingerprint(hostSigner.publicKey),
            displayName: "N3 Test Host",
            gatewayURL: URL(string: "http://127.0.0.1:\(port!)")!,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            deviceID: device.deviceID,
            grantedScopes: scopes,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try registry.upsertHost(record)
        try keyStore.save(device.signer, forHostID: record.id)
        return record
    }

    @discardableResult
    private func enqueueTicket(
        _ existing: RemoteTicket? = nil,
        scopes: Set<String> = [GatewayRemoteScope.sessionsObserve, GatewayRemoteScope.sessionsOperate]
    ) async -> RemoteTicket {
        let ticket: RemoteTicket = if let existing {
            existing
        } else {
            try! GatewayAuthTestSupport.mintTicket(
                hostSigner: hostSigner,
                deviceID: device.deviceID,
                scopes: scopes
            )
        }
        await appConnection.enqueue(.result(GatewayTestHelpers.toolResult(json: .object([
            "ok": .bool(true),
            "ticket": ticket.jsonValue
        ]))))
        return ticket
    }

    private func nextFrameTask(
        from stream: AsyncStream<RemoteServerFrame>,
        ofType type: String? = nil,
        timeout: TimeInterval
    ) -> Task<RemoteServerFrame, Error> {
        Task {
            try await withThrowingTaskGroup(of: RemoteServerFrame.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    while let frame = await iterator.next() {
                        if let type, frame.type != type {
                            continue
                        }
                        return frame
                    }
                    throw RemoteClientError.connectionClosed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw RemoteClientError.timeout(operation: "inbound frame", seconds: timeout)
                }
                guard let first = try await group.next() else {
                    throw RemoteClientError.connectionClosed
                }
                group.cancelAll()
                return first
            }
        }
    }
}
