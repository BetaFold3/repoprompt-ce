import Foundation
import Logging
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// V1-11 gateway-level integration lock for workspace-scoped remote control:
/// a two-window host sharing one workspace yields a unioned catalog, a session
/// the gateway never started is watchable with cold affinity (discovery sweep
/// only, as after a gateway restart) and warm affinity (recorded by the catalog
/// fan-out), steer round-trips on the resolved window, and a closed workspace
/// surfaces the structured `workspace_not_open` picker payload.
final class GatewayWorkspaceRemoteControlIntegrationTests: XCTestCase {
    private let windowOneOlderID = "11111111-1111-1111-1111-111111111111"
    private let windowOneNewerID = "22222222-2222-2222-2222-222222222222"
    private let windowTwoNewestID = "33333333-3333-3333-3333-333333333333"
    private let windowTwoOlderID = "44444444-4444-4444-4444-444444444444"
    private let sharedWorkspaceID = "66666666-6666-6666-6666-666666666666"

    private func twoWindowSharedWorkspaceListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string(sharedWorkspaceID),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string(sharedWorkspaceID),
                        "name": .string("Shared Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func workspaceSessionListResponse(
        _ sessions: [(id: String, name: String, lastModified: String)]
    ) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array(sessions.map { session in
                .object([
                    "session_id": .string(session.id),
                    "name": .string(session.name),
                    "last_modified": .string(session.lastModified),
                    "state": .string("running")
                ])
            }),
            "workspace": .object([
                "id": .string(sharedWorkspaceID),
                "name": .string("Shared Workspace")
            ])
        ]))
    }

    private func windowOneSessions() -> [(id: String, name: String, lastModified: String)] {
        [
            (windowOneOlderID, "Window One Older", "2026-07-12T01:00:00.000Z"),
            (windowOneNewerID, "Window One Newer", "2026-07-12T02:00:00.000Z")
        ]
    }

    private func windowTwoSessions() -> [(id: String, name: String, lastModified: String)] {
        [
            (windowTwoNewestID, "Window Two Newest", "2026-07-12T04:00:00.000Z"),
            (windowTwoOlderID, "Window Two Older", "2026-07-12T03:00:00.000Z")
        ]
    }

    private func steerResult(sessionID: String) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "session_id": .string(sessionID),
            "status": .string("running")
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
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil,
            bindingState: bindingState
        )
        await watchManager.setWindowResolver { deviceID, sessionID in
            await runtime.resolveSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID)
        }
        return runtime
    }

    private func listWorkspaceSessions(
        runtime: RemoteGatewayRuntime,
        requestID: String
    ) async -> RemoteServerFrame? {
        await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: requestID,
                payload: .object(["workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
    }

    func testWorkspaceCatalogUnionThenWarmAffinityWatchAndSteerWithoutRediscovery() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions())),
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: windowOneNewerID, status: "running")
            ))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )
        let sink = RecordingFrameSink()

        // Two windows share the workspace with distinct session sets: the
        // catalog is the union, ordered newest-first, echoing the host workspace.
        let listResponse = await listWorkspaceSessions(runtime: runtime, requestID: "integration-union")
        XCTAssertEqual(listResponse?.type, "command_result")
        let listPayload = try XCTUnwrap(listResponse?.payload?.objectValue)
        XCTAssertEqual(listPayload["window_count"], .int(2))
        XCTAssertEqual(listPayload["workspace"]?.objectValue?["id"]?.stringValue, sharedWorkspaceID)
        XCTAssertEqual(listPayload["workspace"]?.objectValue?["name"]?.stringValue, "Shared Workspace")
        let sessions = try XCTUnwrap(listPayload["sessions"]?.arrayValue)
        XCTAssertEqual(
            sessions.map { $0.objectValue?["session_id"]?.stringValue },
            [windowTwoNewestID, windowTwoOlderID, windowOneNewerID, windowOneOlderID]
        )
        let fanOutCalls = await connection.calls.filter { $0.name == "agent_manage" }
        XCTAssertEqual(fanOutCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        XCTAssertTrue(fanOutCalls.allSatisfy { $0.arguments["workspace_id"] == .string(sharedWorkspaceID) })
        XCTAssertTrue(fanOutCalls.allSatisfy { $0.arguments["workspace_name"] == nil })

        // Subscribe to a window-one session the gateway never started: warm
        // affinity recorded by the fan-out routes the watch without rediscovery.
        let subscribeResponse = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "integration-warm-subscribe", sessionID: windowOneNewerID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(subscribeResponse?.type, "command_result")
        XCTAssertEqual(
            subscribeResponse?.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(windowOneNewerID)]
        )
        var calls = await connection.calls
        let warmPoll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(warmPoll.arguments["_windowID"], .int(1))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1, "Warm affinity must not rediscover windows")

        // Steer round-trips to the affinity-resolved window.
        _ = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "integration-warm-unsubscribe", sessionID: windowOneNewerID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        await connection.enqueue(.result(steerResult(sessionID: windowOneNewerID)))
        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "integration-warm-steer",
                sessionID: windowOneNewerID,
                payload: .object(["message": .string("continue picked-up work")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(steerResponse?.type, "command_result")
        calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(1))
        XCTAssertEqual(steerCall.arguments["message"], .string("continue picked-up work"))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
    }

    func testColdAffinityDiscoverySweepResolvesNeverStartedSessionAfterGatewayRestart() async throws {
        // First gateway lifetime: the catalog fan-out warms affinity.
        let firstConnection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions()))
        ])
        let firstRuntime = try await makeRuntime(
            connection: firstConnection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )
        let firstList = await listWorkspaceSessions(runtime: firstRuntime, requestID: "integration-pre-restart")
        XCTAssertEqual(firstList?.type, "command_result")

        // Simulated gateway restart: a fresh runtime and connection carry no
        // affinity, so pickup of a never-started session must succeed through
        // the discovery sweep alone (Decision 5: affinity is only latency).
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions())),
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: windowTwoOlderID, status: "running")
            ))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .bindingRequired("bind first")
        )
        let sink = RecordingFrameSink()

        let subscribeResponse = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "integration-cold-subscribe", sessionID: windowTwoOlderID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(subscribeResponse?.type, "command_result")
        XCTAssertEqual(
            subscribeResponse?.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(windowTwoOlderID)]
        )
        var calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let discoveryCalls = calls.filter { $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions") }
        XCTAssertEqual(discoveryCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        let coldPoll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(coldPoll.arguments["_windowID"], .int(2))

        // Steer round-trips using the affinity learned by the sweep — no
        // further window discovery is required.
        _ = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "integration-cold-unsubscribe", sessionID: windowTwoOlderID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        await connection.enqueue(.result(steerResult(sessionID: windowTwoOlderID)))
        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "integration-cold-steer",
                sessionID: windowTwoOlderID,
                payload: .object(["message": .string("resume after restart")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(steerResponse?.type, "command_result")
        calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(steerCall.arguments["message"], .string("resume after restart"))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
    }

    func testWorkspaceScopedListSessionsWithNoMatchingWindowsReturnsWorkspaceNotOpenPickerDetails() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse())
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "integration-not-open",
                payload: .object(["workspace_name": .string("Closed Workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "workspace_not_open")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map { $0.objectValue?["window_id"]?.intValue }, [1, 2])
        XCTAssertTrue(windows.allSatisfy { $0.objectValue?["workspace_name"]?.stringValue == "Shared Workspace" })
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_manage" }, "Zero matches must not fan out to any window")
    }
}
