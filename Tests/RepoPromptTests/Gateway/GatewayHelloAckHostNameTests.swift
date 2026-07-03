import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class GatewayHelloAckHostNameTests: XCTestCase {
    private var root: URL!
    private var appLink: AppLinkSession!
    private var server: GatewayHTTPServer!
    private var port: Int!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("gateway-hello-ack-host-name")
        let configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--static-token", "dev-token",
                "--allow-static-token-auth",
                "--port", "0"
            ],
            environment: [:]
        )
        appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await appLink.connect()
        let watchManager = SessionWatchManager(appLink: appLink)
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil
        )
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            hostName: "Static Token Host"
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
        if let appLink {
            await appLink.shutdown()
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testStaticTokenHelloAckIncludesHostName() async throws {
        let socket = try URLSession.shared.webSocketTask(with: XCTUnwrap(URL(string: "ws://127.0.0.1:\(port!)/ws?token=dev-token")))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let hello = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "hello",
                payload: .object(["static_token": .string("dev-token")])
            )
        )
        try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
        let ack = try await receiveFrame(socket)

        XCTAssertEqual(ack.type, "hello_ack")
        XCTAssertEqual(ack.payload?.objectValue?["auth"]?.stringValue, "static_token")
        XCTAssertEqual(ack.payload?.objectValue?["device_id"]?.stringValue, RemoteGatewayRuntime.phase0DeviceID)
        XCTAssertEqual(ack.payload?.objectValue?["host_name"]?.stringValue, "Static Token Host")
        XCTAssertEqual(ack.payload?.objectValue?["sig"], .null)
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
}
