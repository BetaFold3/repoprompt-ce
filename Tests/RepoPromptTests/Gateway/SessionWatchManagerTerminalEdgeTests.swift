import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class SessionWatchManagerTerminalEdgeTests: XCTestCase {
    private actor AlwaysEligiblePushNotifier: RemotePushNotifying {
        func isPushEligible(deviceID _: String) -> Bool {
            true
        }

        func sendWake(deviceID _: String, payload _: WebPushWakePayload) {}
    }

    private let deviceID = "device"
    private let sessionID = "11111111-1111-1111-1111-111111111111"

    func testDuplicateTerminalSuppressionWithQuarantineDisabled() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await manager.pollCatchUp(deviceID: deviceID)
        await manager.pollCatchUp(deviceID: deviceID)
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 1)
        XCTAssertEqual(frames.count(where: { $0.type == "session_update" }), 0)
        XCTAssertTrue(frames.filter { $0.seq != nil }.allSatisfy { $0.seqEpoch != nil })
    }

    func testTerminalEdgeRearmsAfterRunningUpdate() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "running")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await manager.pollCatchUp(deviceID: deviceID)
        await manager.pollCatchUp(deviceID: deviceID)
        await manager.shutdown()

        let frames = await sink.frames.filter { $0.type == "session_terminal" || $0.type == "session_update" }
        XCTAssertEqual(frames.map(\.type), ["session_terminal", "session_update", "session_terminal"])
        XCTAssertEqual(frames.map { $0.payload?.objectValue?["status"]?.stringValue }, ["completed", "running", "completed"])
    }

    func testIncidentReplayEdgeOnlySuppressesDuplicateTerminalsAndEmitsAllRunnings() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "running")),
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "running")),
            .result(snapshot(status: "running")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        for _ in 0 ..< 6 {
            await manager.pollCatchUp(deviceID: deviceID)
        }
        await manager.shutdown()

        let frames = await sink.frames.filter { $0.type == "session_terminal" || $0.type == "session_update" }
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 2)
        XCTAssertEqual(frames.count(where: { $0.payload?.objectValue?["status"]?.stringValue == "running" }), 3)
        XCTAssertEqual(frames.map { $0.payload?.objectValue?["status"]?.stringValue }, [
            "running", "completed", "running", "running", "completed"
        ])
    }

    func testIncidentReplayQuarantinedRunningConfirmationPreventsPrematureTerminal() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "running")),
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0.1)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        try await Task.sleep(for: .milliseconds(50))
        var frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 0)

        _ = await waitForStatus(sink, status: "running", minimum: 1, timeoutMilliseconds: 1000)
        frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 0)

        await manager.pollCatchUp(deviceID: deviceID)
        _ = await waitForFrames(sink, type: "session_terminal", minimum: 1, timeoutMilliseconds: 1000)
        await manager.shutdown()

        frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 1)
        XCTAssertTrue(frames.contains { $0.type == "session_update" && $0.payload?.objectValue?["status"]?.stringValue == "running" })
    }

    func testQuarantineFailOpenEmitsHeldTerminalWhenConfirmPollFails() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .failure("confirm failed")
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0.1)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForFrames(sink, type: "session_terminal", minimum: 1, timeoutMilliseconds: 1000)
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 1)
    }

    func testFailedTerminalBypassesCompletedQuarantine() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "running")),
            .result(snapshot(status: "failed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 5)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await manager.pollCatchUp(deviceID: deviceID)
        _ = await waitForFrames(sink, type: "session_terminal", minimum: 1, timeoutMilliseconds: 100)
        await manager.shutdown()

        let frames = await sink.frames
        let terminal = try XCTUnwrap(frames.first { $0.type == "session_terminal" })
        XCTAssertEqual(terminal.payload?.objectValue?["status"]?.stringValue, "failed")
    }

    func testSubscribeCatchUpTargetsOnlyNewSinkAfterSuppressedTerminalEdge() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink1 = RecordingFrameSink()
        let sink2 = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink1, sessionIDs: [sessionID])
        let sink1Baseline = await sink1.frames.count
        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink2, sessionIDs: [sessionID])
        await manager.shutdown()

        let sink1Frames = await sink1.frames
        let sink2Frames = await sink2.frames
        XCTAssertEqual(sink1Frames.count, sink1Baseline)
        XCTAssertEqual(sink2Frames.count(where: { $0.type == "session_terminal" }), 1)
    }

    func testTerminalDemotionRevalidationResumeAndSecondTerminalEdge() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "running")),
            .result(snapshot(status: "completed"))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            revalidationIntervalSeconds: 0.05,
            terminalQuarantineSeconds: 0
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        var state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertFalse(state.activeWait)
        XCTAssertTrue(state.parkedTerminal)

        _ = await waitForStatus(sink, status: "running", minimum: 1, timeoutMilliseconds: 1000)
        state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertTrue(state.activeWait)
        XCTAssertFalse(state.parkedTerminal)

        await manager.pollCatchUp(deviceID: deviceID)
        _ = await waitForFrames(sink, type: "session_terminal", minimum: 2, timeoutMilliseconds: 1000)
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 2)
    }

    func testTerminalFingerprintClearsAcrossUnsubscribeAndResubscribe() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed", transcriptItemCount: 1)),
            .result(snapshot(status: "completed", transcriptItemCount: 2))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sinkID = UUID()
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        var state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertEqual(state.lastEmittedTerminalTranscriptItemCount, 1)
        XCTAssertNotNil(state.lastEmittedTerminalUpdatedAt)

        await manager.unsubscribe(deviceID: deviceID, sessionIDs: [sessionID])
        state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertNil(state.lastEmittedIsTerminal)
        XCTAssertNil(state.lastEmittedTerminalTranscriptItemCount)
        XCTAssertNil(state.lastEmittedTerminalUpdatedAt)

        await manager.subscribe(deviceID: deviceID, sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        let frames = await sink.frames
        state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        await manager.shutdown()

        let terminalFrames = frames.filter { $0.type == "session_terminal" && $0.sessionID == sessionID }
        XCTAssertEqual(terminalFrames.count, 2)
        XCTAssertEqual(terminalFrames.map { $0.payload?.objectValue?["transcript_item_count"]?.intValue }, [1, 2])
        XCTAssertEqual(state.lastEmittedTerminalTranscriptItemCount, 2)
    }

    func testConcurrentSameSessionRegistrationsKeepBothSinksEligible() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "running"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let firstSink = RecordingFrameSink()
        let secondSink = RecordingFrameSink()
        let firstValidation = await manager.registerSubscription(
            deviceID: deviceID,
            sinkID: UUID(),
            sink: firstSink,
            sessionIDs: [sessionID]
        )
        _ = await manager.registerSubscription(
            deviceID: deviceID,
            sinkID: UUID(),
            sink: secondSink,
            sessionIDs: [sessionID]
        )

        await manager.validateSubscription(firstValidation)

        let firstFrames = await firstSink.frames
        let secondFrames = await secondSink.frames
        await manager.shutdown()
        XCTAssertTrue(firstFrames.contains { $0.type == "session_update" })
        XCTAssertTrue(secondFrames.contains { $0.type == "session_update" })
    }

    func testSinkRemovalDuringDeferredValidationStillStartsDeviceObservation() async throws {
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
                ),
                gate
            )
        ])
        let notifier = AlwaysEligiblePushNotifier()
        let (manager, _) = try await makeManager(
            connection: connection,
            pushNotifier: notifier,
            terminalQuarantineSeconds: 0
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()
        let validation = await manager.registerSubscription(
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink,
            sessionIDs: [sessionID]
        )
        let validationTask = Task {
            await manager.validateSubscription(validation)
        }

        await gate.waitUntilEntered()
        await manager.removeSink(deviceID: deviceID, sinkID: sinkID)
        await gate.release()
        await validationTask.value

        let state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        let frames = await sink.frames
        await manager.shutdown()
        XCTAssertTrue(state.watched)
        XCTAssertTrue(state.activeWait)
        XCTAssertTrue(frames.isEmpty)
    }

    func testUnsubscribeBeforeDeferredSubscribeValidationDoesNotEmitOrResurrect() async throws {
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
                ),
                gate
            )
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink = RecordingFrameSink()
        let sinkID = UUID()
        let validation = await manager.registerSubscription(
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink,
            sessionIDs: [sessionID]
        )
        let validationTask = Task {
            await manager.validateSubscription(validation)
        }

        await gate.waitUntilEntered()
        await manager.unsubscribe(deviceID: deviceID, sessionIDs: [sessionID])
        await gate.release()
        await validationTask.value

        let state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        let frames = await sink.frames
        await manager.shutdown()

        XCTAssertFalse(state.watched)
        XCTAssertTrue(frames.isEmpty)
    }

    func testUnsubscribeDuringInFlightWaitDoesNotResurrectSession() async throws {
        let secondSessionID = "22222222-2222-2222-2222-222222222222"
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: secondSessionID, status: "running"))),
            .gated(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")), gate)
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID, secondSessionID])
        _ = await waitForStatus(sink, status: "running", minimum: 2, timeoutMilliseconds: 1000)
        await gate.waitUntilEntered()
        let baselineUnsubscribedFrames = await sink.frames.count(where: { $0.sessionID == sessionID })

        await manager.unsubscribe(deviceID: deviceID, sessionIDs: [sessionID])
        await gate.release()
        try await Task.sleep(for: .milliseconds(120))
        let state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        let frames = await sink.frames
        await manager.shutdown()

        XCTAssertFalse(state.watched)
        XCTAssertFalse(state.activeWait)
        XCTAssertEqual(frames.count(where: { $0.sessionID == sessionID }), baselineUnsubscribedFrames)
    }

    func testExpiredSnapshotRetiresTerminalStateAndCancelsQuarantine() async throws {
        let connection = ScriptedAppLinkConnection(poll: [
            .result(snapshot(status: "completed")),
            .result(snapshot(status: "expired"))
        ])
        let (manager, _) = try await makeManager(connection: connection, terminalQuarantineSeconds: 0.5)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        var state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertTrue(state.pendingQuarantine)

        await manager.pollCatchUp(deviceID: deviceID)
        _ = await waitForFrames(sink, type: "session_expired", minimum: 1, timeoutMilliseconds: 1000)
        try await Task.sleep(for: .milliseconds(600))
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(frames.count(where: { $0.type == "session_expired" }), 1)
        XCTAssertEqual(frames.count(where: { $0.type == "session_terminal" }), 0)
        state = await manager.debugTerminalState(deviceID: deviceID, sessionID: sessionID)
        XCTAssertFalse(state.pendingQuarantine)
        XCTAssertFalse(state.parkedTerminal)
        XCTAssertNil(state.lastEmittedIsTerminal)
    }

    private func makeManager(
        connection: RecordingAppLinkConnection,
        pushNotifier: (any RemotePushNotifying)? = nil,
        terminalQuarantineSeconds: TimeInterval
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
            pollRefreshSeconds: 5,
            revalidationIntervalSeconds: 10,
            terminalQuarantineSeconds: terminalQuarantineSeconds
        )
        return (manager, appLink)
    }

    private func makeManager(
        connection: ScriptedAppLinkConnection,
        revalidationIntervalSeconds: TimeInterval = 10,
        terminalQuarantineSeconds: TimeInterval
    ) async throws -> (SessionWatchManager, AppLinkSession) {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: ScriptedAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let manager = SessionWatchManager(
            appLink: appLink,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 5,
            revalidationIntervalSeconds: revalidationIntervalSeconds,
            terminalQuarantineSeconds: terminalQuarantineSeconds
        )
        return (manager, appLink)
    }

    private func snapshot(
        status: String,
        transcriptItemCount: Int = 0,
        updatedAt: String = "2026-07-02T00:00:00.000Z"
    ) -> JSONValue {
        .object([
            "session_id": .string(sessionID),
            "status": .string(status),
            "transcript_item_count": .int(transcriptItemCount),
            "updated_at": .string(updatedAt)
        ])
    }

    private func waitForFrames(
        _ sink: RecordingFrameSink,
        type: String,
        minimum: Int,
        timeoutMilliseconds: Int
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< max(1, timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.count(where: { $0.type == type }) >= minimum { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }

    private func waitForStatus(
        _ sink: RecordingFrameSink,
        status: String,
        minimum: Int,
        timeoutMilliseconds: Int
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< max(1, timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.count(where: { $0.payload?.objectValue?["status"]?.stringValue == status }) >= minimum { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }
}

private actor ScriptedAppLinkConnection: AppLinkConnection {
    enum Response {
        case result(JSONValue)
        case failure(String)
    }

    private var responsesByOp: [String: [Response]]
    private(set) var calls: [RecordedGatewayToolCall] = []

    init(poll: [Response] = [], wait: [Response] = []) {
        responsesByOp = [
            "poll": poll,
            "wait": wait
        ]
    }

    func callTool(
        name: String,
        arguments: [String: Value],
        timeout: TimeInterval?
    ) async throws -> MCPToolResult {
        calls.append(RecordedGatewayToolCall(name: name, arguments: arguments, timeout: timeout))
        let op = arguments["op"]?.stringValue ?? ""
        var responses = responsesByOp[op] ?? []
        let response = responses.isEmpty ? nil : responses.removeFirst()
        responsesByOp[op] = responses
        switch response {
        case let .result(json):
            return GatewayTestHelpers.toolResult(json: json)
        case let .failure(message):
            throw GatewayTestError(message: message)
        case nil:
            return GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))
        }
    }

    func disconnect() async {}
}

private struct ScriptedAppLinkConnector: AppLinkConnecting {
    let connection: ScriptedAppLinkConnection

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}
