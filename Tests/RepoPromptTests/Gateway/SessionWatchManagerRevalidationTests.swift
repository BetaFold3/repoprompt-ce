import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class SessionWatchManagerRevalidationTests: XCTestCase {
    private actor RecordingPushNotifier: RemotePushNotifying {
        struct Wake: Equatable {
            let deviceID: String
            let kind: WebPushWakePayload.Kind
            let sessionID: String
            let interactionID: String?
        }

        private let eligibleDevices: Set<String>
        private(set) var wakes: [Wake] = []

        init(eligibleDevices: Set<String>) {
            self.eligibleDevices = eligibleDevices
        }

        func isPushEligible(deviceID: String) -> Bool {
            eligibleDevices.contains(deviceID)
        }

        func sendWake(deviceID: String, payload: WebPushWakePayload) {
            wakes.append(Wake(
                deviceID: deviceID,
                kind: payload.kind,
                sessionID: payload.sessionID,
                interactionID: payload.interactionID
            ))
        }
    }

    private let sessionID = "11111111-1111-1111-1111-111111111111"

    func testParkedActionableSessionRevalidationEmitsExitFromActionableAndRearms() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        let frames = await waitForStatus(sink, status: "running", minimum: 2, timeoutMilliseconds: 1000)
        let calls = await waitForCalls(connection, minimum: 3, timeoutMilliseconds: 1000)
        await manager.shutdown()

        let updates = frames.filter { $0.type == "session_update" && $0.sessionID == sessionID }
        XCTAssertEqual(updates.prefix(2).map { $0.payload?.objectValue?["status"]?.stringValue }, ["waiting_for_input", "running"])
        XCTAssertEqual(updates.prefix(2).map(\.seq), [1, 2])
        XCTAssertTrue(calls.contains { $0.arguments["op"] == .string("wait") })
    }

    func testParkedActionableStillActionableStaysParkedNoRearmLoop() async throws {
        let connection = RecordingAppLinkConnection(responses: Array(repeating: .result(
            GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input"))
        ), count: 50))
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForCalls(connection, minimum: 3, timeoutMilliseconds: 1000)
        try await Task.sleep(for: .milliseconds(80))
        let calls = await connection.calls
        await manager.shutdown()

        XCTAssertFalse(calls.contains { $0.arguments["op"] == .string("wait") })
        XCTAssertGreaterThanOrEqual(calls.count(where: { $0.arguments["op"] == .string("poll") }), 2)
    }

    func testParkedTerminalSessionIsRevalidatedWithoutDuplicateTerminalFrames() async throws {
        let connection = RecordingAppLinkConnection(responses: Array(repeating: .result(
            GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "completed"))
        ), count: 10))
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForFrames(sink, containing: "session_terminal")
        try await Task.sleep(for: .milliseconds(120))
        let calls = await connection.calls
        await manager.shutdown()

        // Regression for remote-client-premature-terminal-and-model-label-2026-07-09:
        // terminal sessions remain watched for recovery revalidation, but repeated
        // terminal re-polls must be edge-suppressed.
        XCTAssertGreaterThanOrEqual(calls.count(where: { $0.arguments["op"] == .string("poll") }), 2)
        let frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 1)
        XCTAssertFalse(calls.contains { $0.arguments["op"] == .string("wait") })
    }

    func testRevalidationStopsAfterRespondSuccessRearm() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForStatus(sink, status: "waiting_for_input")
        await manager.rearm(deviceID: "device", sessionID: sessionID)
        let calls = await waitForCalls(connection, minimum: 2, timeoutMilliseconds: 1000)
        await manager.shutdown()

        XCTAssertTrue(calls.contains { $0.arguments["op"] == .string("wait") })
    }

    func testExitFromActionableClearsWakeDedupeBeforeNextActionablePush() async throws {
        let deviceID = "device"
        let sinkID = UUID()
        let notifier = RecordingPushNotifier(eligibleDevices: [deviceID])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: snapshot(status: "waiting_for_input", interactionID: "question-1"))),
            .result(GatewayTestHelpers.toolResult(json: snapshot(status: "waiting_for_input", interactionID: "question-1"))),
            .result(GatewayTestHelpers.toolResult(json: snapshot(status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: snapshot(status: "waiting_for_input", interactionID: "question-2")))
        ])
        let (manager, _) = try await makeManager(connection: connection, pushNotifier: notifier)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        await manager.removeSink(deviceID: deviceID, sinkID: sinkID)
        let wakes = await waitForWakes(notifier, minimum: 2, timeoutMilliseconds: 1500)
        await manager.shutdown()

        XCTAssertEqual(wakes.map(\.deviceID), [deviceID, deviceID])
        XCTAssertEqual(wakes.map(\.kind), [.waitingForInput, .waitingForInput])
        XCTAssertEqual(wakes.map(\.sessionID), [sessionID, sessionID])
        XCTAssertEqual(wakes.map(\.interactionID), ["question-1", "question-2"])
    }

    func testRevalidationIdleWithoutSinksOrPush() async throws {
        let sinkID = UUID()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        _ = await waitForStatus(sink, status: "waiting_for_input")
        await manager.removeSink(deviceID: "device", sinkID: sinkID)
        try await Task.sleep(for: .milliseconds(120))
        let calls = await connection.calls
        await manager.shutdown()

        XCTAssertEqual(calls.count(where: { $0.arguments["op"] == .string("poll") }), 1)
        XCTAssertFalse(calls.contains { $0.arguments["op"] == .string("wait") })
    }

    private func snapshot(status: String, interactionID: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "status": .string(status),
            "updated_at": .string("2026-07-02T00:00:00.000Z")
        ]
        if let interactionID {
            payload["interaction_id"] = .string(interactionID)
        }
        return .object(payload)
    }

    private func makeManager(
        connection: RecordingAppLinkConnection,
        pushNotifier: (any RemotePushNotifying)? = nil
    ) async throws -> (SessionWatchManager, AppLinkSession) {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let manager = SessionWatchManager(
            appLink: appLink,
            pushNotifier: pushNotifier,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2,
            revalidationIntervalSeconds: 0.05,
            terminalQuarantineSeconds: 0
        )
        return (manager, appLink)
    }

    private func waitForCalls(
        _ connection: RecordingAppLinkConnection,
        minimum: Int,
        timeoutMilliseconds: Int = 1000
    ) async -> [RecordedGatewayToolCall] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let calls = await connection.calls
            if calls.count >= minimum { return calls }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await connection.calls
    }

    private func waitForWakes(
        _ notifier: RecordingPushNotifier,
        minimum: Int,
        timeoutMilliseconds: Int = 1000
    ) async -> [RecordingPushNotifier.Wake] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let wakes = await notifier.wakes
            if wakes.count >= minimum { return wakes }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await notifier.wakes
    }

    private func waitForFrames(
        _ sink: RecordingFrameSink,
        containing type: String,
        timeoutMilliseconds: Int = 1000
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.contains(where: { $0.type == type }) { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }

    private func waitForStatus(
        _ sink: RecordingFrameSink,
        status: String,
        minimum: Int = 1,
        timeoutMilliseconds: Int = 1000
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let frames = await sink.frames
            let matches = frames.filter { $0.payload?.objectValue?["status"]?.stringValue == status }
            if matches.count >= minimum { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }
}
