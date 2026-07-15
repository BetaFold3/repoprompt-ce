import Foundation
import Logging
@testable import RepoPromptApp
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
        if states.isEmpty {
            return .ambiguousStartTarget("multiple windows")
        }
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

    private func sharedWorkspaceWindowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string("66666666-6666-6666-6666-666666666666"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string("66666666-6666-6666-6666-666666666666"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(3),
                    "workspace": .object([
                        "id": .string("77777777-7777-7777-7777-777777777777"),
                        "name": .string("Other Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func workspaceSessionListResponse(
        _ sessions: [(id: String, name: String, lastModified: String)],
        workspaceID: String,
        workspaceName: String
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
                "id": .string(workspaceID),
                "name": .string(workspaceName)
            ])
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

    func testWarmObservationAffinityBypassesAppLinkLookupBindingRefreshAndDiscovery() async throws {
        let deviceID = "remote:1a2b3c4d"
        let canonicalSessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        do {
            let connection = RecordingAppLinkConnection(responses: [
                .result(GatewayTestHelpers.toolResult(json: .object([
                    "session_id": .string(canonicalSessionID),
                    "status": .string("running")
                ])))
            ])
            let root = try GatewayTestHelpers.temporaryRoot()
            let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
            let probe = BindingProbeRecorder([.bound])
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
            let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
            let runtime = try RemoteGatewayRuntime(
                appLink: defaultAppLink,
                ledger: CommandLedger(),
                watchManager: watchManager,
                auditLog: nil,
                appLinkPool: pool
            )

            let start = await runtime.handle(
                RemoteClientFrame(
                    type: "start",
                    requestID: "warm-unavailable-start",
                    payload: .object([
                        "message": .string("go"),
                        "window_id": .int(2)
                    ])
                ),
                deviceID: deviceID,
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
            XCTAssertEqual(start?.type, "command_result")
            let callCountBeforeTeardown = await connection.calls.count
            XCTAssertEqual(callCountBeforeTeardown, 1)
            let didTeardown = await pool.teardown(deviceID: deviceID)
            XCTAssertTrue(didTeardown)

            let resolved = await runtime.resolveSessionWindowForObservation(
                deviceID: deviceID,
                sessionID: "  \(canonicalSessionID)  "
            )
            XCTAssertEqual(resolved, 2)
            let callCountAfterResolution = await connection.calls.count
            XCTAssertEqual(callCountAfterResolution, 1)
            XCTAssertEqual(probe.count, 1)
        }

        do {
            let refreshSessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            let connection = RecordingAppLinkConnection(responses: [
                .result(GatewayTestHelpers.toolResult(json: .object([
                    "session_id": .string(refreshSessionID),
                    "status": .string("running")
                ])))
            ])
            let root = try GatewayTestHelpers.temporaryRoot()
            let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
            let initialProbe = BindingProbeRecorder([.bound])
            let refreshProbe = BindingProbeRecorder([.bound])
            let pool = AppLinkPool(
                configuration: config,
                connector: BindingRuntimeConnector(connection: connection),
                bindingProbe: { _ in initialProbe.next() },
                refreshBindingProbe: { _ in refreshProbe.next() },
                unknownBindingRefreshCooldown: 0
            )
            _ = try await pool.ensureLink(forDevice: deviceID)
            let defaultAppLink = AppLinkSession(
                config: config,
                connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
            )
            try await defaultAppLink.connect()
            let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
            let runtime = try RemoteGatewayRuntime(
                appLink: defaultAppLink,
                ledger: CommandLedger(),
                watchManager: watchManager,
                auditLog: nil,
                appLinkPool: pool
            )

            let start = await runtime.handle(
                RemoteClientFrame(
                    type: "start",
                    requestID: "warm-refresh-start",
                    payload: .object([
                        "message": .string("go"),
                        "window_id": .int(2)
                    ])
                ),
                deviceID: deviceID,
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
            XCTAssertEqual(start?.type, "command_result")
            await pool.setBindingState(.bound, forDevice: deviceID, refreshOnNextResolve: true)
            let callsBeforeResolution = await connection.calls
            let refreshCountBeforeResolution = refreshProbe.count

            let resolved = await runtime.resolveSessionWindowForObservation(
                deviceID: deviceID,
                sessionID: "\n\(refreshSessionID)\t"
            )
            XCTAssertEqual(resolved, 2)
            XCTAssertEqual(refreshProbe.count, refreshCountBeforeResolution)
            let callsAfterResolution = await connection.calls
            XCTAssertEqual(callsAfterResolution, callsBeforeResolution)
            XCTAssertFalse(callsBeforeResolution.contains {
                $0.name == "bind_context"
                    || $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions")
            })
        }
    }

    func testSubscribeAcknowledgesBeforeDeferredValidationCanEmit() async throws {
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
                ),
                gate
            )
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()
        let sinkID = UUID()
        let request = RemoteClientFrame(
            type: "subscribe",
            requestID: "subscribe-order",
            sessionID: sessionID
        )

        let handledResponse = await runtime.handle(
            request,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        let response = try XCTUnwrap(handledResponse)

        let callsBeforeAcknowledgment = await connection.calls
        XCTAssertTrue(callsBeforeAcknowledgment.isEmpty)
        await sink.send(response)
        await runtime.didQueueResponse(
            for: request,
            response: response,
            deviceID: "device",
            sinkID: sinkID
        )
        await gate.waitUntilEntered()

        let framesWhileValidationBlocked = await sink.frames
        XCTAssertEqual(framesWhileValidationBlocked.map(\.type), ["command_result"])

        await gate.release()
        for _ in 0 ..< 50 {
            let currentFrames = await sink.frames
            if currentFrames.contains(where: { $0.type == "session_update" }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let frames = await sink.frames
        XCTAssertEqual(frames.first?.type, "command_result")
        XCTAssertTrue(frames.contains { $0.type == "session_update" })
    }

    func testConcurrentMissingRequestIDSubscriptionsKeepPerSinkValidation() async throws {
        let otherSessionID = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
            )),
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: otherSessionID, status: "running")
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let firstSink = RecordingFrameSink()
        let secondSink = RecordingFrameSink()
        let firstSinkID = UUID()
        let secondSinkID = UUID()
        let firstRequest = RemoteClientFrame(type: "subscribe", sessionID: sessionID)
        let secondRequest = RemoteClientFrame(type: "subscribe", sessionID: otherSessionID)

        let firstHandled = await runtime.handle(
            firstRequest,
            deviceID: "device",
            sinkID: firstSinkID,
            sink: firstSink
        )
        let secondHandled = await runtime.handle(
            secondRequest,
            deviceID: "device",
            sinkID: secondSinkID,
            sink: secondSink
        )
        let firstResponse = try XCTUnwrap(firstHandled)
        let secondResponse = try XCTUnwrap(secondHandled)
        await firstSink.send(firstResponse)
        await secondSink.send(secondResponse)
        await runtime.didQueueResponse(
            for: firstRequest,
            response: firstResponse,
            deviceID: "device",
            sinkID: firstSinkID
        )
        await runtime.didQueueResponse(
            for: secondRequest,
            response: secondResponse,
            deviceID: "device",
            sinkID: secondSinkID
        )

        var calls = await connection.calls
        for _ in 0 ..< 50 where calls.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
            calls = await connection.calls
        }
        let polledSessionIDs = Set(calls.compactMap { call -> String? in
            guard call.name == "agent_run",
                  call.arguments["op"] == .string("poll")
            else { return nil }
            return call.arguments["session_id"]?.stringValue
        })
        XCTAssertEqual(polledSessionIDs, Set([sessionID, otherSessionID]))
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

        let request = RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID)
        let sinkID = UUID()
        let response = await runtime.handle(
            request,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )

        let responseFrame = try XCTUnwrap(response)
        XCTAssertEqual(responseFrame.type, "command_result")
        await sink.send(responseFrame)
        await runtime.didQueueResponse(
            for: request,
            response: responseFrame,
            deviceID: "device",
            sinkID: sinkID
        )
        var calls = await connection.calls
        for _ in 0 ..< 50 where !calls.contains(where: {
            $0.name == "agent_run" && $0.arguments["op"] == .string("poll")
        }) {
            try? await Task.sleep(for: .milliseconds(20))
            calls = await connection.calls
        }
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

    func testWorkspaceScopedListSessionsRoutesSingleMatchAndStripsWorkspaceName() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(workspaceSessionListResponse(
                [(sessionID, "Workspace B Session", "2026-07-12T01:00:00.000Z")],
                workspaceID: "55555555-5555-5555-5555-555555555555",
                workspaceName: "Workspace B"
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-single",
                payload: .object(["workspace_name": .string(" workspace b ")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(1))
        XCTAssertEqual(
            response?.payload?.objectValue?["workspace"]?.objectValue?["id"]?.stringValue,
            "55555555-5555-5555-5555-555555555555"
        )
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage"])
        let listCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(listCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(listCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(listCall.arguments["workspace_name"])
    }

    func testWorkspaceScopedListSessionsFansOutDeduplicatesNewestAndRecordsAffinity() async throws {
        let duplicateID = sessionID
        let firstOnlyID = "22222222-2222-2222-2222-222222222222"
        let secondOnlyID = "33333333-3333-3333-3333-333333333333"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(sharedWorkspaceWindowListResponse()),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Older Duplicate", "2026-07-12T01:00:00.000Z"),
                    (firstOnlyID, "First Only", "2026-07-12T02:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Newer Duplicate", "2026-07-12T04:00:00.000Z"),
                    (secondOnlyID, "Second Only", "2026-07-12T03:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(duplicateID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-union",
                payload: .object(["workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(2))
        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.map { $0.objectValue?["session_id"]?.stringValue }, [duplicateID, secondOnlyID, firstOnlyID])
        XCTAssertEqual(sessions.first?.objectValue?["name"]?.stringValue, "Newer Duplicate")

        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "workspace-list-affinity",
                sessionID: duplicateID,
                payload: .object(["message": .string("continue")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(steerResponse?.type, "command_result")

        let calls = await connection.calls
        let listCalls = calls.filter { $0.name == "agent_manage" }
        XCTAssertEqual(listCalls.count, 2)
        XCTAssertEqual(listCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        XCTAssertTrue(listCalls.allSatisfy { $0.arguments["workspace_name"] == nil })
        XCTAssertTrue(listCalls.allSatisfy {
            $0.arguments["workspace_id"] == .string("66666666-6666-6666-6666-666666666666")
        })
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        let auditRecord = try await waitForAuditRecord(in: auditDirectory, op: "list_sessions")
        XCTAssertEqual(auditRecord["workspace_match_count"] as? Int, 2)
    }

    func testWorkspaceScopedListSessionsAppliesLimitAfterUnion() async throws {
        let duplicateID = sessionID
        let firstOnlyID = "22222222-2222-2222-2222-222222222222"
        let secondOnlyID = "33333333-3333-3333-3333-333333333333"
        let connection = RecordingAppLinkConnection(responses: [
            .result(sharedWorkspaceWindowListResponse()),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Older Duplicate", "2026-07-12T01:00:00.000Z"),
                    (firstOnlyID, "First Only", "2026-07-12T02:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Newer Duplicate", "2026-07-12T04:00:00.000Z"),
                    (secondOnlyID, "Second Only", "2026-07-12T03:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-limit",
                payload: .object([
                    "workspace_name": .string("Shared Workspace"),
                    "limit": .int(2)
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.map { $0.objectValue?["session_id"]?.stringValue }, [duplicateID, secondOnlyID])
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(2))
    }

    func testWorkspaceScopedListSessionsRejectsUnsupportedPayloadBeforeLookup() async throws {
        let connection = RecordingAppLinkConnection()
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-invalid",
                payload: .object([
                    "workspace_name": .string("Missing"),
                    "include_hidden": .bool(true)
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "unsupported_payload_key")
        let calls = await connection.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWorkspaceScopedListSessionsWithoutMatchesReturnsWorkspaceNotOpenWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-missing",
                payload: .object(["workspace_name": .string("Missing")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_not_open")
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context"])
    }

    func testWorkspaceScopedListSessionsNormalizesWorkspaceMismatchWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("workspace_mismatch: the target window's active workspace changed")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-mismatch",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_mismatch")
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
    }

    /// Post-v1 review test gap: the gateway's `workspace_mismatch` mapping is
    /// message sniffing (`RemoteGatewayRuntimeError.code`), and the older test
    /// above fakes the host message. This locks the REAL message the host
    /// generates for workspace-scoped `list_sessions` — derived from the shared
    /// `AgentManageMCPToolService.workspaceMismatchMessage` literal, so a host
    /// copy edit that breaks the sniffed prefix fails here. Residual gap:
    /// `AgentRunMCPToolService`'s start-path variant is an independent literal
    /// with the same prefix and is not covered by this test.
    func testWorkspaceScopedListSessionsNormalizesRealHostWorkspaceMismatchMessage() async throws {
        let hostMessage = try AgentManageMCPToolService.workspaceMismatchMessage(
            activeWorkspaceName: "Workspace A",
            activeWorkspaceID: XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444")),
            requestedWorkspaceID: XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        )
        XCTAssertTrue(hostMessage.hasPrefix("workspace_mismatch: "))
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string(hostMessage)
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-real-mismatch",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_mismatch")
        XCTAssertEqual(response?.payload?.objectValue?["message"]?.stringValue, hostMessage)
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
    }

    func testWorkspaceScopedListSessionsLookupFailureDoesNotFabricateWorkspaceNotOpen() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "error": .string("window inventory unavailable")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-lookup-failure",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "app_tool_error")
        XCTAssertNotEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_not_open")
    }

    func testUnscopedListSessionsReturnsHostPayloadWithoutGatewayReshaping() async throws {
        let expectedPayload = JSONValue.object([
            "sessions": .array([
                .object([
                    "session_id": .string(sessionID),
                    "name": .string("Unscoped Session")
                ])
            ]),
            "workspace": .object([
                "id": .string("44444444-4444-4444-4444-444444444444"),
                "name": .string("Workspace A")
            ])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: expectedPayload))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions", requestID: "unscoped-list"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload, expectedPayload)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["agent_manage"])
        XCTAssertNil(calls[0].arguments["workspace_id"])
        XCTAssertNil(calls[0].arguments["workspace_name"])
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

        let subscribeRequest = RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID)
        let handledSubscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        let subscribeResponse = try XCTUnwrap(handledSubscribeResponse)
        await sink.send(subscribeResponse)
        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: subscribeResponse,
            deviceID: "device",
            sinkID: sinkID
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
            if frames.count >= minimumCount {
                return frames
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let frames = await sink.frames.filter { $0.type == "session_update" }
        XCTAssertGreaterThanOrEqual(frames.count, minimumCount, file: file, line: line)
        return frames
    }
}
