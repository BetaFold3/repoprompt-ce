import Foundation
import MCP
@testable import RepoPromptGateway
import XCTest

/// Plan §6.6: unbound multi-window connections get structured `binding_required`
/// on observation ops, binding errors carry eligible start-target windows, and
/// an explicit `window_id` selector lets `start` proceed without binding.
final class GatewayRuntimeBindingTests: XCTestCase {
    private let sessionID = "11111111-1111-1111-1111-111111111111"

    private func windowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "is_current_window": .bool(true),
                    "workspace": .object([
                        "id": .string("44444444-4444-4444-4444-444444444444"),
                        "name": .string("Workspace A")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "is_current_window": .bool(false),
                    "workspace": .object([
                        "id": .string("55555555-5555-5555-5555-555555555555"),
                        "name": .string("Workspace B")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func makeRuntime(
        connection: RecordingAppLinkConnection,
        bindingState: RemoteGatewayBindingState
    ) async throws -> RemoteGatewayRuntime {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let watchManager = SessionWatchManager(
            appLink: appLink,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2
        )
        return try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil,
            bindingState: bindingState
        )
    }

    func testSubscribeOnUnboundConnectionReturnsBindingRequiredWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "binding_required")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].objectValue?["window_id"]?.intValue, 1)
        XCTAssertEqual(windows[0].objectValue?["workspace_name"]?.stringValue, "Workspace A")
        XCTAssertEqual(windows[1].objectValue?["workspace_id"]?.stringValue, "55555555-5555-5555-5555-555555555555")

        // The catch-up wait/poll loop must never have been armed.
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testUnsubscribeOnUnboundConnectionReturnsBindingRequired() async throws {
        let connection = RecordingAppLinkConnection()
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        XCTAssertEqual(frame.payload?.objectValue?["code"]?.stringValue, "binding_required")
    }

    func testSubscribeOnAmbiguousStartTargetConnectionReturnsBindingRequired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        XCTAssertEqual(frame.payload?.objectValue?["code"]?.stringValue, "binding_required")
    }

    func testStartWithoutSelectorOnAmbiguousConnectionReturnsStructuredErrorWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        // No fallback guessing: the only app call is the gateway-internal window list.
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context"])
    }

    func testStartWithExplicitWindowSelectorProceedsOnAmbiguousConnection() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_result", "Explicit selector must bypass ambiguity refusal: \(frame)")
        let calls = await connection.calls
        let start = try XCTUnwrap(calls.first { $0.name == "agent_run" })
        XCTAssertEqual(start.arguments["op"], .string("start"))
        XCTAssertEqual(start.arguments["_windowID"], .int(2))
        XCTAssertEqual(start.arguments["request_id"], .string("r1"))
        XCTAssertNil(start.arguments["window_id"])
    }

    func testSubscribeOnBoundConnectionSucceeds() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_result", "\(frame)")
        XCTAssertEqual(
            frame.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(sessionID)]
        )
    }
}
