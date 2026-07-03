import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class GatewayBootstrapContractTests: XCTestCase {
    func testStartFrameProducesExactAgentRunToolCall() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection)
        let sink = RecordingFrameSink()
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "req-1",
            payload: .object(["message": .string("run"), "model_id": .string("pair")])
        )

        let response = await runtime.handle(
            frame,
            deviceID: RemoteGatewayRuntime.phase0DeviceID,
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "agent_run")
        XCTAssertEqual(calls[0].arguments["op"], .string("start"))
        XCTAssertEqual(calls[0].arguments["_rawJSON"], .bool(true))
        XCTAssertEqual(calls[0].arguments["message"], .string("run"))
        XCTAssertEqual(calls[0].arguments["model_id"], .string("pair"))
    }

    func testDuplicateMutatingFrameDoesNotReplayAppCall() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection)
        let sink = RecordingFrameSink()
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "req-1",
            payload: .object(["message": .string("run")])
        )

        _ = await runtime.handle(frame, deviceID: RemoteGatewayRuntime.phase0DeviceID, sinkID: UUID(), sink: sink)
        let duplicate = await runtime.handle(frame, deviceID: RemoteGatewayRuntime.phase0DeviceID, sinkID: UUID(), sink: sink)

        XCTAssertEqual(duplicate?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testArbitraryToolPassthroughIsRejectedBeforeAppCall() async throws {
        let connection = RecordingAppLinkConnection()
        let runtime = try await makeRuntime(connection: connection)
        let sink = RecordingFrameSink()
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "req-1",
            payload: .object(["message": .string("run"), "tool_name": .string("read_file")])
        )

        let response = await runtime.handle(frame, deviceID: RemoteGatewayRuntime.phase0DeviceID, sinkID: UUID(), sink: sink)

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "arbitrary_tool_passthrough_rejected")
        let calls = await connection.calls
        XCTAssertTrue(calls.isEmpty)
    }

    private func makeRuntime(connection: RecordingAppLinkConnection) async throws -> RemoteGatewayRuntime {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let ledger = try CommandLedger()
        let watch = SessionWatchManager(appLink: appLink)
        return RemoteGatewayRuntime(
            appLink: appLink,
            ledger: ledger,
            watchManager: watch,
            auditLog: nil
        )
    }
}
