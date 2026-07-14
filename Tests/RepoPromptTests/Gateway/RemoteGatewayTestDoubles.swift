import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire

struct RecordedGatewayToolCall: Equatable {
    let name: String
    let arguments: [String: Value]
    let timeout: TimeInterval?
}

actor RecordingAppLinkResponseGate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append(continuation)
        }
    }

    func enterAndWaitForRelease() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

actor RecordingAppLinkConnection: AppLinkConnection {
    enum Response {
        case result(MCPToolResult)
        case gated(MCPToolResult, RecordingAppLinkResponseGate)
        case appLinkLost(String)
        case timeout(TimeInterval)
        case failure(String)
    }

    private var responses: [Response]
    private(set) var calls: [RecordedGatewayToolCall] = []

    init(responses: [Response] = []) {
        self.responses = responses
    }

    func enqueue(_ response: Response) {
        responses.append(response)
    }

    func callTool(
        name: String,
        arguments: [String: Value],
        timeout: TimeInterval?
    ) async throws -> MCPToolResult {
        calls.append(RecordedGatewayToolCall(name: name, arguments: arguments, timeout: timeout))
        guard !responses.isEmpty else {
            return GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(arguments["session_id"]?.stringValue ?? UUID().uuidString),
                "status": .string("running")
            ]))
        }
        switch responses.removeFirst() {
        case let .result(result):
            return result
        case let .gated(result, gate):
            await gate.enterAndWaitForRelease()
            return result
        case let .appLinkLost(reason):
            throw AppLinkError.appLinkLost(reason)
        case let .timeout(seconds):
            throw AppLinkError.toolCallTimedOut(seconds)
        case let .failure(message):
            throw GatewayTestError(message: message)
        }
    }

    func disconnect() async {}
}

struct GatewayTestError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

struct StaticAppLinkConnector: AppLinkConnecting {
    let connection: RecordingAppLinkConnection

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}

actor RecordingFrameSink: RemoteFrameSink {
    private(set) var frames: [RemoteServerFrame] = []
    private(set) var closeCount = 0

    func send(_ frame: RemoteServerFrame) async {
        frames.append(frame)
    }

    func close() async {
        closeCount += 1
    }
}

enum GatewayTestHelpers {
    static func temporaryRoot(_ name: String = #function) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGatewayTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func configuration(root: URL, staticToken: String? = "test-token") throws -> GatewayConfiguration {
        var args = [
            "--app-support-root", root.path,
            "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
            "--bootstrap-token", "bootstrap-token",
            "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
            "--port", "1"
        ]
        if let staticToken {
            args += ["--static-token", staticToken]
        }
        return try GatewayConfiguration.parse(arguments: args, environment: [:])
    }

    static func toolResult(json: JSONValue, isError: Bool = false) -> MCPToolResult {
        let value = json.mcpValue
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: isError
        )
    }

    static func snapshot(sessionID: String, status: String) -> JSONValue {
        .object([
            "session_id": .string(sessionID),
            "status": .string(status),
            "updated_at": .string("2026-07-02T00:00:00.000Z")
        ])
    }

    static func multiSnapshots(_ snapshots: [JSONValue], sessionIDs: [String]) -> JSONValue {
        .object([
            "poll": .object([
                "mode": .string("many"),
                "session_ids": .array(sessionIDs.map(JSONValue.string))
            ]),
            "snapshots": .array(snapshots)
        ])
    }
}

final class MutableDateBox: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}
