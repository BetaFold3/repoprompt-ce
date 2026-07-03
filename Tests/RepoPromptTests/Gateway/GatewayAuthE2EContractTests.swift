import CryptoKit
import Foundation
import Logging
import NIOCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// End-to-end M4 contract over a real loopback WebSocket:
/// a paired device authenticates with an app-minted ticket plus frame signatures,
/// observe-only operations succeed, `steer` is denied until the scope is granted,
/// signed-frame replay is rejected (with an audit entry), a one-time ticket cannot be
/// reused, and bootstrap capacity rejections surface as `channel_closing {reason}`.
final class GatewayAuthE2EContractTests: XCTestCase {
    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!
    private var capacityDevice: GatewayAuthTestSupport.TestDeviceIdentity!
    private var connector: E2EPoolConnector!
    private var watchManager: SessionWatchManager!
    private var server: GatewayHTTPServer!
    private var port: Int!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("gateway-auth-e2e")
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
        device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:1a2b3c4d")
        capacityDevice = GatewayAuthTestSupport.makeDevice(deviceID: "remote:eeff0011")

        let trust = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, false), (capacityDevice, false)]
        )
        let usedTicketStore = try GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        let authenticator = DeviceAuthenticator(usedTicketStore: usedTicketStore, trust: trust)

        connector = E2EPoolConnector(capacityRejectedClientName: capacityDevice.deviceID)
        let pool = AppLinkPool(
            configuration: configuration,
            connector: connector,
            bindingProbe: { _ in .bound }
        )

        let defaultAppLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()

        let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
        self.watchManager = watchManager
        let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog,
            appLinkPool: pool
        )
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            appLinkPool: pool,
            auditLog: auditLog
        )
        try await server.start()
        guard let boundPort = server.localAddress?.port else {
            throw XCTSkip("Could not determine the ephemeral gateway port")
        }
        port = boundPort
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

    // MARK: - WS plumbing

    private func openSocket() -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port!)/ws")!)
        task.resume()
        return task
    }

    private func send(_ data: Data, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveFrame(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval = 10
    ) async throws -> RemoteServerFrame {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayTestError(message: "Timed out waiting for a server frame")
            }
            guard let first = try await group.next() else {
                throw GatewayTestError(message: "No server frame")
            }
            group.cancelAll()
            return first
        }
        let data: Data = switch message {
        case let .string(text): Data(text.utf8)
        case let .data(payload): payload
        @unknown default: Data()
        }
        return try RemoteWireProtocol.decodeServerFrame(from: data)
    }

    private func performTicketHello(
        _ task: URLSessionWebSocketTask,
        ticket: RemoteTicket,
        deviceKey: P256.Signing.PrivateKey,
        counter: UInt64 = 1
    ) async throws -> RemoteServerFrame {
        let hello = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue),
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            counter: counter,
            deviceKey: deviceKey
        )
        try await send(hello, over: task)
        return try await receiveFrame(task)
    }

    // MARK: - Contract

    func testPairedDeviceObserveOnlyContract() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        // 1. Ticket hello admits the paired device.
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")
        XCTAssertEqual(helloAck.payload?.objectValue?["auth"]?.stringValue, "ticket")
        XCTAssertEqual(helloAck.payload?.objectValue?["device_id"]?.stringValue, device.deviceID)

        // 2. Observe-only operation succeeds through the per-device app link.
        let listFrame = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "list_sessions"),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer
        )
        try await send(listFrame, over: socket)
        let listResult = try await receiveFrame(socket)
        XCTAssertEqual(listResult.type, "command_result")
        XCTAssertEqual(connector.connectedClientNames.first, device.deviceID)

        // 3. steer is denied until sessions:operate is granted.
        let steerFrame = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "steer",
                requestID: "req-steer-1",
                sessionID: "session-a",
                payload: .object(["message": .string("do more")])
            ),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 3,
            deviceKey: device.signer
        )
        try await send(steerFrame, over: socket)
        let steerResult = try await receiveFrame(socket)
        XCTAssertEqual(steerResult.type, "command_error")
        XCTAssertEqual(steerResult.payload?.objectValue?["code"]?.stringValue, "insufficient_scope")

        // 4. Byte-identical replay of the signed list frame is rejected and audited.
        try await send(listFrame, over: socket)
        let replayResult = try await receiveFrame(socket)
        XCTAssertEqual(replayResult.type, "command_error")
        XCTAssertEqual(replayResult.payload?.objectValue?["code"]?.stringValue, "counter_replayed")

        try await assertAuditContains(code: "counter_replayed", deviceID: device.deviceID)
        try await assertAuditContains(code: "insufficient_scope", deviceID: device.deviceID)
    }

    func testOneTimeTicketCannotBeReusedForASecondConnection() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let first = openSocket()
        defer { first.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(first, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        let second = openSocket()
        defer { second.cancel(with: .normalClosure, reason: nil) }
        let replayAck = try await performTicketHello(
            second,
            ticket: ticket,
            deviceKey: device.signer,
            counter: 5
        )
        XCTAssertEqual(replayAck.type, "command_error")
        XCTAssertEqual(replayAck.payload?.objectValue?["code"]?.stringValue, "ticket_already_used")
        try await assertAuditContains(code: "ticket_already_used", deviceID: device.deviceID)
    }

    func testHelloWithoutTicketIsRejectedWhenStaticTokenModeIsOff() async throws {
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let hello = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "hello",
                payload: .object(["static_token": .string("anything")])
            )
        )
        try await send(hello, over: socket)
        let response = try await receiveFrame(socket)
        XCTAssertEqual(response.type, "command_error")
        XCTAssertEqual(response.payload?.objectValue?["code"]?.stringValue, "ticket_required")
    }

    func testRevokedWhilePassivelyConnectedClosesWebSocket() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        // Simulate trust sync revoking a passively-connected PWA. The client sends
        // no post-hello frames, so this must not depend on verifyFrame running.
        await watchManager.teardownDevice(
            deviceID: device.deviceID,
            reason: "device_revoked",
            message: "revoked"
        )
        server.closeConnections(forDevice: device.deviceID)

        let closing = try await receiveFrame(socket)
        XCTAssertEqual(closing.type, "channel_closing")
        XCTAssertEqual(closing.payload?.objectValue?["reason"]?.stringValue, "device_revoked")
        do {
            _ = try await receiveFrame(socket, timeout: 0.5)
            XCTFail("Expected revoked WebSocket to close without delivering further events")
        } catch {
            // Expected: the socket is closed (or no more frames can arrive) after revocation.
        }
    }

    func testBootstrapCapacityRejectionSurfacesAsChannelClosing() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: capacityDevice.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let response = try await performTicketHello(
            socket,
            ticket: ticket,
            deviceKey: capacityDevice.signer
        )
        XCTAssertEqual(response.type, "channel_closing")
        XCTAssertEqual(
            response.payload?.objectValue?["reason"]?.stringValue,
            "capacity_exceeded"
        )
        try await assertAuditContains(code: "capacity_exceeded", deviceID: capacityDevice.deviceID)
    }

    // MARK: - Audit assertions

    private func assertAuditContains(
        code: String,
        deviceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try auditRecords().contains(where: { $0.code == code && $0.deviceID == deviceID }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Audit log never recorded code=\(code) for \(deviceID)", file: file, line: line)
    }

    private func auditRecords() throws -> [RemoteAuditRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: configuration.auditDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        var records: [RemoteAuditRecord] = []
        for file in files where file.pathExtension == "jsonl" {
            let data = (try? Data(contentsOf: file)) ?? Data()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let record = try? decoder.decode(RemoteAuditRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
        }
        return records
    }
}

/// Pool connector for E2E tests: per-device links succeed with a recording
/// connection; one device is rejected with a capacity error at bootstrap.
private final class E2EPoolConnector: AppLinkConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let capacityRejectedClientName: String
    private(set) var connectedClientNames: [String] = []

    init(capacityRejectedClientName: String) {
        self.capacityRejectedClientName = capacityRejectedClientName
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        if clientName == capacityRejectedClientName {
            throw AppLinkError.handshakeRejected(errorCode: "capacity_exceeded", reason: "Server at capacity")
        }
        lock.lock()
        connectedClientNames.append(clientName)
        lock.unlock()
        return RecordingAppLinkConnection()
    }
}
