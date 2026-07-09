import Foundation
import Logging
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

private final class BindingRuntimeConnector: AppLinkConnecting, @unchecked Sendable {
    let connection: RecordingAppLinkConnection

    init(connection: RecordingAppLinkConnection) {
        self.connection = connection
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}

private final class BindingProbeRecorder: @unchecked Sendable {
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
        if states.isEmpty { return .ambiguousStartTarget("multiple windows") }
        return states.removeFirst()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

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

    private func duplicateWorkspaceWindowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string("44444444-4444-4444-4444-444444444444"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string("55555555-5555-5555-5555-555555555555"),
                        "name": .string("Shared Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func sessionListResponse(_ ids: [String]) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array(ids.map { id in
                .object([
                    "session_id": .string(id),
                    "name": .string("Session \(id.prefix(4))"),
                    "last_modified": .string("2026-07-02T00:00:00.000Z"),
                    "item_count": .int(1),
                    "state": .string("running"),
                    "is_live": .bool(true)
                ])
            })
        ]))
    }

    private func auditRecords(in directory: URL, op: String) -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { fileURL -> [[String: Any]] in
                let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { rawLine in
                    guard let data = rawLine.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["op"] as? String == op
                    else { return nil }
                    return object
                }
            }
    }

    private func waitForAuditRecord(
        in directory: URL,
        op: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Any] {
        for _ in 0 ..< 100 {
            if let record = auditRecords(in: directory, op: op).first {
                return record
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for audit record", file: file, line: line)
        return [:]
    }

    private func waitForAuditRecords(
        in directory: URL,
        op: String,
        minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [[String: Any]] {
        for _ in 0 ..< 100 {
            let records = auditRecords(in: directory, op: op)
            if records.count >= minimumCount {
                return records
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(minimumCount) audit records", file: file, line: line)
        return []
    }

    private func makeRuntime(
        connection: RecordingAppLinkConnection,
        bindingState: RemoteGatewayBindingState,
        auditLog: RemoteAuditLog? = nil
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
            auditLog: auditLog,
            bindingState: bindingState
        )
        await watchManager.setWindowResolver { deviceID, sessionID in
            await runtime.resolveSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID)
        }
        return runtime
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

    func testSubscribeOnUnboundConnectionProceedsWhenSessionWindowResolves() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        let poll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(poll.arguments["_windowID"], .int(2))
    }

    func testParentFilteredListSessionsRoutesToParentWindow() async throws {
        let childSessionID = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "sessions": .array([
                    .object([
                        "session_id": .string(childSessionID),
                        "name": .string("Child Worker"),
                        "state": .string("running"),
                        "parent_session_id": .string(sessionID)
                    ])
                ])
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "r-child-list",
                payload: .object(["parent_session_id": .string(sessionID)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.first?.objectValue?["session_id"]?.stringValue, childSessionID)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage", "agent_manage", "agent_manage"])
        let listSessions = try XCTUnwrap(calls.last)
        XCTAssertEqual(listSessions.arguments["op"], .string("list_sessions"))
        XCTAssertEqual(listSessions.arguments["parent_session_id"], .string(sessionID))
        XCTAssertEqual(listSessions.arguments["_windowID"], .int(2))
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

    func testStartWithUniqueWorkspaceNameAutoRoutesAndRecordsAffinity() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let startResponse = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string(" workspace b ")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(startResponse?.type, "command_result")

        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_run", "agent_run"])
        let startCall = try XCTUnwrap(calls.first { $0.arguments["op"] == .string("start") })
        XCTAssertEqual(startCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(startCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(startCall.arguments["workspace_name"])
        XCTAssertNil(startCall.arguments["window_id"])
        let steerCall = try XCTUnwrap(calls.first { $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
    }

    func testStartWithNonMatchingWorkspaceNameStillReturnsAmbiguousStartTargetWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Missing")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testStartWithDuplicateWorkspaceNameStillReturnsAmbiguousStartTargetWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(duplicateWorkspaceWindowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testGetLogAuditIncludesPagingFields() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "turn_offset": .int(7),
                "turn_limit": .int(3),
                "returned_turn_count": .int(2),
                "total_turns": .int(10),
                "completed_turn_count": .int(8),
                "transcript_xml": .string("<transcript/>")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound, auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "get_log",
                requestID: "log-r1",
                sessionID: sessionID,
                payload: .object(["offset": .int(7), "limit": .int(3)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "get_log")
        XCTAssertEqual(record["offset"] as? Int, 7)
        XCTAssertEqual(record["limit"] as? Int, 3)
        XCTAssertEqual(record["returned_turn_count"] as? Int, 2)
        XCTAssertEqual(record["completed_turn_count"] as? Int, 8)
        XCTAssertEqual(record["transcript_xml_chars"] as? Int, "<transcript/>".count)
    }

    func testStartBindingFailureAuditIncludesWorkspaceSelectorDiagnostics() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(duplicateWorkspaceWindowListResponse())
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Shared Workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertEqual(record["has_workspace_id"] as? Bool, false)
        XCTAssertEqual(record["workspace_match_count"] as? Int, 2)
    }

    func testStartBindingFailureAuditRecordsWorkspaceMatchSkippedForExplicitWindowID() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound, auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B"), "window_id": .int(2)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertNil(record["workspace_match_count"])
        XCTAssertEqual(record["workspace_match_skipped"] as? String, "explicit_window_id")
        XCTAssertNil(record["workspace_match_unavailable_reason"])
    }

    func testStartBindingFailureAuditRecordsWorkspaceMatchUnavailableReason() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("app_error"),
                "error": .string("window list unavailable")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertNil(record["workspace_match_count"])
        XCTAssertNil(record["workspace_match_skipped"])
        XCTAssertEqual(record["workspace_match_unavailable_reason"] as? String, "app_tool_error")
    }

    func testInFlightDuplicateStartAuditDoesNotConsumeOriginalRoutingDiagnostics() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .gated(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])), gate)
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "start-r1",
            payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
        )

        let original = Task {
            await runtime.handle(
                frame,
                deviceID: "device",
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
        }
        await gate.waitUntilEntered()

        let duplicate = await runtime.handle(
            frame,
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(duplicate?.type, "command_result")
        XCTAssertEqual(duplicate?.payload?.objectValue?["status"]?.stringValue, "in_flight")

        await gate.release()
        let originalResponse = await original.value
        XCTAssertEqual(originalResponse?.type, "command_result")

        let records = try await waitForAuditRecords(in: auditDirectory, op: "start", minimumCount: 2)
        let inFlightRecord = try XCTUnwrap(records.first { $0["outcome"] as? String == "in_flight" })
        let successRecord = try XCTUnwrap(records.first { $0["outcome"] as? String == "success" })
        XCTAssertNil(inFlightRecord["auto_routed_window_id"])
        XCTAssertEqual(successRecord["auto_routed_window_id"] as? Int, 2)
    }

    func testAutoRoutedStartAuditIncludesMatchedWindowID() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"), auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["auto_routed_window_id"] as? Int, 2)
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

    func testExplicitStartRecordsAffinityForNextSteer() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        _ = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "window_id": .int(2)])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        let steer = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(steer?.type, "command_result")
        let calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(steerCall.arguments["op"], .string("steer"))
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
    }

    func testDiscoveryResolvesUnknownSessionAndBulkLearnsSibling() async throws {
        let sibling = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID, sibling])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sibling, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sibling, payload: .object(["message": .string("again")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let steerCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 2)
        XCTAssertTrue(steerCalls.allSatisfy { $0.arguments["_windowID"] == .int(2) })
    }

    func testDiscoveryMissReturnsBindingRequiredWithoutSessionExpired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([]))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        XCTAssertNotEqual(response?.payload?.objectValue?["code"]?.stringValue, "session_expired")
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
    }

    func testToolErrorInvalidatesRediscoversDifferentWindowAndRetriesOnce() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("session_expired"),
                "error": .string("Session not found")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_result")
        let steerCalls = await connection.calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 2)
        XCTAssertEqual(steerCalls[0].arguments["_windowID"], .int(1))
        XCTAssertEqual(steerCalls[1].arguments["_windowID"], .int(2))
    }

    func testNonRoutingToolErrorDoesNotRetryAcrossRediscoveredWindow() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("provider_failed"),
                "error": .string("Provider failed before accepting the message")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "provider_failed")
        let calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let steerCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 1)
    }

    func testAppLinkLostDoesNotRetryAndReturnsInDoubt() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .appLinkLost("restart")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "in_doubt")
        let steerCalls = await connection.calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 1)
    }

    func testBoundStartWithUniqueWorkspaceNameAutoRoutesAndAuditsMatchCount() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, maxRetainedFiles: 2)
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in .bound }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: auditLog,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_run"])
        let startCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(startCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(startCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))

        let auditRecord = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(auditRecord["outcome"] as? String, "success")
        XCTAssertEqual(auditRecord["workspace_match_count"] as? Int, 1)
        XCTAssertEqual(auditRecord["auto_routed_window_id"] as? Int, 2)
    }

    func testStartRoutingAppErrorWithUniqueWorkspaceNameAutoRoutesAfterBindingRefresh() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["error": .string("window inventory unavailable")]), isError: true)),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let probe = BindingProbeRecorder([
            .bound,
            .bound,
            .bound
        ])
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in probe.next() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let steerResponse = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(steerResponse?.type, "command_result")

        let calls = await connection.calls
        let startCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("start") }
        XCTAssertEqual(startCalls.count, 2)
        XCTAssertNil(startCalls[0].arguments["_windowID"])
        XCTAssertEqual(startCalls[1].arguments["_windowID"], .int(2))
        XCTAssertEqual(startCalls[1].arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(startCalls[1].arguments["workspace_name"])
        let steerCall = try XCTUnwrap(calls.first { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        XCTAssertGreaterThanOrEqual(probe.count, 2, "Start routing app errors should retry even when refreshed binding state is bound")
    }

    func testStartRoutingAppErrorWithNonMatchingWorkspaceNameReturnsAmbiguousStartTargetWithWindowsAndRefreshesBinding() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(windowListResponse())
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let probe = BindingProbeRecorder([
            .bound,
            .ambiguousStartTarget("multiple windows"),
            .ambiguousStartTarget("multiple windows")
        ])
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in probe.next() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "workspace_name": .string("Missing")])),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertGreaterThanOrEqual(probe.count, 2, "Start routing app errors should refresh stale bound state")
    }

    func testListAgentsOnAmbiguousConnectionUsesFallbackWindow() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "agents": .array([.object(["id": .string("pair"), "name": .string("Pair")])])
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "r1"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage"])
        let listAgents = try XCTUnwrap(calls.last)
        XCTAssertEqual(listAgents.arguments["op"], .string("list_agents"))
        XCTAssertEqual(listAgents.arguments["_windowID"], .int(1))
    }

    func testListAgentsFallsBackToBindingRequiredWhenWindowDiscoveryFails() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["error": .string("no windows")]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "r1"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_manage" })
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

    func testRespondFailureRearmsSessionWatch() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input"))),
            .failure("respond failed"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        _ = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        _ = await waitForSessionUpdateCount(1, sink: sink)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "respond",
                requestID: "r2",
                sessionID: sessionID,
                payload: .object([
                    "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
                    "response": .string("accept")
                ])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        let frames = await waitForSessionUpdateCount(2, sink: sink)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let firstSeq = try XCTUnwrap(frames[0].seq)
        let secondSeq = try XCTUnwrap(frames[1].seq)
        XCTAssertGreaterThan(secondSeq, firstSeq)

        try await Task.sleep(for: .milliseconds(150))
        let finalSessionUpdateCount = await sink.frames.count { $0.type == "session_update" }
        XCTAssertEqual(finalSessionUpdateCount, 2)
    }

    func testRespondFailureRearmIgnoresUnwatchedSession() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .failure("respond failed")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "respond",
                requestID: "r1",
                sessionID: sessionID,
                payload: .object([
                    "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
                    "response": .string("accept")
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(response?.type, "command_error")
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["op"], .string("respond"))
    }

    private func waitForSessionUpdateCount(
        _ minimumCount: Int,
        sink: RecordingFrameSink,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< 100 {
            let frames = await sink.frames.filter { $0.type == "session_update" }
            if frames.count >= minimumCount { return frames }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let frames = await sink.frames.filter { $0.type == "session_update" }
        XCTAssertGreaterThanOrEqual(frames.count, minimumCount, file: file, line: line)
        return frames
    }
}
