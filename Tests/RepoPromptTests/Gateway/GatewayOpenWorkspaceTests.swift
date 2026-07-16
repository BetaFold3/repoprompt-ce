import Foundation
import Logging
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

private final class OpenWorkspaceProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func record() {
        lock.lock()
        callCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

final class GatewayOpenWorkspaceTests: XCTestCase {
    private let deviceID = "device"
    private let workspaceID = "44444444-4444-4444-4444-444444444444"

    private func openResult(status: String = "opened", windowID: Int = 7) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "status": .string(status), "window_id": .int(windowID),
            "workspace": .object(["id": .string(workspaceID), "name": .string("Project Alpha")])
        ]))
    }

    private func workspaceError(code: String, message: String) -> MCPToolResult {
        GatewayTestHelpers.toolResult(
            json: .object(["error": .string(message), "code": .string(code)]),
            isError: true
        )
    }

    private func windowList(workspaceName: String, windowID: Int) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([.object([
                "window_id": .int(windowID),
                "workspace": .object(["id": .string(workspaceID), "name": .string(workspaceName)])
            ])]),
            "binding": .object(["state": .string("window")])
        ]))
    }

    private func sessionList(workspaceName: String) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array([]),
            "workspace": .object(["id": .string(workspaceID), "name": .string(workspaceName)])
        ]))
    }

    private func openFrame(
        requestID: String,
        workspaceID: String? = nil,
        workspaceName: String? = "Project Alpha"
    ) -> RemoteClientFrame {
        var payload: [String: JSONValue] = [:]
        if let workspaceID { payload["workspace_id"] = .string(workspaceID) }
        if let workspaceName { payload["workspace_name"] = .string(workspaceName) }
        return RemoteClientFrame(type: "open_workspace", requestID: requestID, payload: .object(payload))
    }

    private func makeRuntime(
        connection: RecordingAppLinkConnection,
        bindingState: RemoteGatewayBindingState = .ambiguousStartTarget("multiple windows"),
        ledger: CommandLedger? = nil,
        auditLog: RemoteAuditLog? = nil,
        appLinkPool: AppLinkPool? = nil
    ) async throws -> RemoteGatewayRuntime {
        let root = try GatewayTestHelpers.temporaryRoot()
        let configuration = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let watchManager = SessionWatchManager(
            appLink: appLink,
            appLinkPool: appLinkPool,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2
        )
        return try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: ledger ?? CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog,
            bindingState: bindingState,
            appLinkPool: appLinkPool
        )
    }

    private func handle(
        _ frame: RemoteClientFrame,
        runtime: RemoteGatewayRuntime,
        deviceID: String? = nil
    ) async -> RemoteServerFrame? {
        await runtime.handle(
            frame,
            deviceID: deviceID ?? self.deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
    }

    func testOpenWorkspaceRunsUnderAmbiguousBindingAndReturnsAppPayload() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(openResult()),
            .result(windowList(workspaceName: "Project Alpha", windowID: 7)),
            .result(sessionList(workspaceName: "Project Alpha"))
        ])
        let runtime = try await makeRuntime(connection: connection)

        let response = await handle(
            openFrame(requestID: "open-happy", workspaceID: workspaceID),
            runtime: runtime
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload?.objectValue?["status"], .string("opened"))
        XCTAssertEqual(response?.payload?.objectValue?["window_id"], .int(7))
        let calls = await connection.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.name, "manage_workspaces")
        XCTAssertEqual(call.arguments["action"], .string("open"))
        XCTAssertEqual(call.arguments["workspace_id"], .string(workspaceID))
        XCTAssertNil(call.arguments["workspace_name"], "Canonical ID selector wins")
        XCTAssertEqual(call.arguments["_rawJSON"], .bool(true))
        XCTAssertEqual(call.timeout, AppLinkCallTimeoutPolicy.fast)

        let listResponse = await handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "open-happy-list",
                payload: .object(["workspace_name": .string("Project Alpha")])
            ),
            runtime: runtime
        )
        XCTAssertEqual(listResponse?.type, "command_result")
        XCTAssertEqual(
            listResponse?.payload?.objectValue?["workspace"]?.objectValue?["name"],
            .string("Project Alpha")
        )
    }

    func testSuccessfulOpenRefreshesBindingAndDropsCachedWindowDetails() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        let configuration = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowList(workspaceName: "Old Workspace", windowID: 1)),
            .result(openResult()),
            .result(windowList(workspaceName: "Project Alpha", windowID: 7))
        ])
        let refreshRecorder = OpenWorkspaceProbeRecorder()
        let pool = AppLinkPool(
            configuration: configuration,
            connector: StaticAppLinkConnector(connection: connection),
            bindingProbe: { _ in .bound },
            refreshBindingProbe: { _ in
                refreshRecorder.record()
                return .bound
            }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let runtime = try await makeRuntime(
            connection: RecordingAppLinkConnection(),
            bindingState: .bound,
            appLinkPool: pool
        )
        let preOpen = await handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "pre-open-list",
                payload: .object(["workspace_name": .string("Project Alpha")])
            ),
            runtime: runtime
        )
        XCTAssertEqual(preOpen?.payload?.objectValue?["code"], .string("workspace_not_open"))

        let open = await handle(openFrame(requestID: "refresh-open"), runtime: runtime)
        XCTAssertEqual(open?.type, "command_result")
        XCTAssertEqual(refreshRecorder.count, 1)

        let postOpen = await handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "post-open-list",
                payload: .object(["workspace_name": .string("Still Closed")])
            ),
            runtime: runtime
        )
        XCTAssertEqual(postOpen?.type, "command_error")
        XCTAssertEqual(postOpen?.payload?.objectValue?["code"], .string("workspace_not_open"))
        let details = try XCTUnwrap(postOpen?.payload?.objectValue?["details"]?.objectValue)
        let windows = try XCTUnwrap(details["windows"]?.arrayValue)
        XCTAssertEqual(windows.first?.objectValue?["window_id"], .int(7))
        XCTAssertEqual(windows.first?.objectValue?["workspace_name"], .string("Project Alpha"))
        let calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 2)
        XCTAssertEqual(calls.count(where: { $0.name == "manage_workspaces" }), 1)
    }

    func testLedgerReplaysSuccessAndRejectsConflictingSelector() async throws {
        let connection = RecordingAppLinkConnection(responses: [.result(openResult())])
        let runtime = try await makeRuntime(connection: connection)
        let first = await handle(openFrame(requestID: "duplicate-open"), runtime: runtime)
        let duplicate = await handle(openFrame(requestID: "duplicate-open"), runtime: runtime)
        let conflict = await handle(
            openFrame(requestID: "duplicate-open", workspaceName: "Different Workspace"),
            runtime: runtime
        )
        XCTAssertEqual(first?.type, "command_result")
        XCTAssertEqual(duplicate?.payload, first?.payload)
        XCTAssertEqual(conflict?.payload?.objectValue?["code"], .string("request_id_conflict"))
        let callCount = await connection.calls.count
        XCTAssertEqual(callCount, 1)
    }

    func testStableWorkspaceErrorsReplayWithoutSecondAppCall() async throws {
        for code in ["workspace_not_found", "workspace_ambiguous"] {
            let connection = RecordingAppLinkConnection(responses: [
                .result(workspaceError(code: code, message: "Stable \(code)"))
            ])
            let runtime = try await makeRuntime(connection: connection)
            let requestID = "stable-\(code)"
            let first = await handle(openFrame(requestID: requestID), runtime: runtime)
            let duplicate = await handle(openFrame(requestID: requestID), runtime: runtime)
            XCTAssertEqual(first?.payload?.objectValue?["code"], .string(code))
            XCTAssertEqual(duplicate?.payload, first?.payload)
            let callCount = await connection.calls.count
            XCTAssertEqual(callCount, 1)
        }
    }

    func testInDoubtReplayDoesNotReexecuteAndFreshRequestMayObserveAlreadyOpen() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .appLinkLost("lost after send"),
            .result(openResult(status: "already_open"))
        ])
        let runtime = try await makeRuntime(connection: connection)
        let first = await handle(openFrame(requestID: "lost-open"), runtime: runtime)
        let duplicate = await handle(openFrame(requestID: "lost-open"), runtime: runtime)
        let fresh = await handle(openFrame(requestID: "fresh-open"), runtime: runtime)
        XCTAssertEqual(first?.payload?.objectValue?["code"], .string("in_doubt"))
        XCTAssertEqual(duplicate?.payload, first?.payload)
        XCTAssertEqual(fresh?.payload?.objectValue?["status"], .string("already_open"))
        let callCount = await connection.calls.count
        XCTAssertEqual(callCount, 2)
    }

    func testOpenWorkspaceAuditRecordsSelectorsWindowAndFailureCode() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory)
        let connection = RecordingAppLinkConnection(responses: [
            .result(openResult(windowID: 9)),
            .result(workspaceError(code: "workspace_not_found", message: "Missing"))
        ])
        let runtime = try await makeRuntime(connection: connection, auditLog: auditLog)
        _ = await handle(openFrame(requestID: "audit-success", workspaceID: workspaceID), runtime: runtime)
        _ = await handle(openFrame(requestID: "audit-failure", workspaceName: "Missing"), runtime: runtime)

        var records: [[String: Any]] = []
        for _ in 0 ..< 100 {
            records = auditRecords(in: auditDirectory)
            if records.count >= 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(records.count, 2)
        let success = try XCTUnwrap(records.first { $0["request_id"] as? String == "audit-success" })
        XCTAssertEqual(success["outcome"] as? String, "success")
        XCTAssertEqual(success["window_id"] as? Int, 9)
        XCTAssertEqual(success["has_workspace_id"] as? Bool, true)
        XCTAssertEqual(success["has_workspace_name"] as? Bool, true)
        let failure = try XCTUnwrap(records.first { $0["request_id"] as? String == "audit-failure" })
        XCTAssertEqual(failure["code"] as? String, "workspace_not_found")
        XCTAssertEqual(failure["has_workspace_name"] as? Bool, true)
        XCTAssertNil(failure["window_id"])
    }

    private func auditRecords(in directory: URL) -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { fileURL -> [[String: Any]] in
                let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            }
            .filter { $0["op"] as? String == "open_workspace" }
    }
}
