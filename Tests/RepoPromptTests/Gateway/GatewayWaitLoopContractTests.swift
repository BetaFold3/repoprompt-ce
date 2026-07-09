import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import RepoPromptShared
import XCTest

final class GatewayWaitLoopContractTests: XCTestCase {
    private actor RecordingPushEligibilityNotifier: RemotePushNotifying {
        private let eligibleDevices: Set<String>

        init(eligibleDevices: Set<String>) {
            self.eligibleDevices = eligibleDevices
        }

        func isPushEligible(deviceID: String) -> Bool {
            eligibleDevices.contains(deviceID)
        }

        func sendWake(deviceID _: String, payload _: WebPushWakePayload) {}
    }

    func testWaitPartitionArgsIncludeStatusUpdatesWhenSinksLive() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        let calls = await waitForCalls(connection, minimum: 2)
        await manager.shutdown()

        let waitCall = try XCTUnwrap(calls.first { $0.name == "agent_run" && $0.arguments["op"] == .string("wait") })
        XCTAssertEqual(waitCall.arguments["include_status_updates"], .bool(true))
    }

    func testWaitPartitionOmitsStatusUpdatesForSinklessPushEligibleDevice() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let deviceID = "device"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running")))
        ])
        let notifier = RecordingPushEligibilityNotifier(eligibleDevices: [deviceID])
        let (manager, _) = try await makeManager(
            connection: connection,
            pushNotifier: notifier,
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.05
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: deviceID, sinkID: sinkID, sink: sink, sessionIDs: [s1])
        await manager.removeSink(deviceID: deviceID, sinkID: sinkID)
        let calls = await waitForCalls(connection, minimum: 3)
        await manager.shutdown()

        let waitCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("wait") }
        // The LAST wait call must be sinkless-shaped; a contains-based check would
        // pass even if the flag flip-flopped per iteration.
        let lastWaitCall = try XCTUnwrap(waitCalls.last)
        XCTAssertNil(
            lastWaitCall.arguments["include_status_updates"],
            "A disconnected push-eligible wait loop must omit include_status_updates: \(waitCalls)"
        )
    }

    func testMultiplexWaitUsesSessionIDsArray() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let s2 = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s2, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.multiSnapshots([
                GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input"),
                GatewayTestHelpers.snapshot(sessionID: s2, status: "running")
            ], sessionIDs: [s1, s2])))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1, s2])
        let calls = await waitForCalls(connection, minimum: 3)

        XCTAssertTrue(calls.contains { call in
            call.name == "agent_run"
                && call.arguments["op"] == .string("wait")
                && call.arguments["session_ids"]?.arrayValue == [.string(s1), .string(s2)]
        })
    }

    func testResolvedWindowWaitPartitionsUseHiddenWindowID() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let s2 = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s2, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s2, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, sessionID in
                sessionID == s1 ? 1 : 2
            }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1, s2])
        let calls = await waitForCalls(connection, minimum: 4, timeoutMilliseconds: 1500)
        await manager.shutdown()

        let waitCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("wait") }
        XCTAssertEqual(Set(waitCalls.compactMap { $0.arguments["_windowID"]?.intValue }), Set([1, 2]))
        XCTAssertTrue(waitCalls.contains { $0.arguments["session_id"] == .string(s1) })
        XCTAssertTrue(waitCalls.contains { $0.arguments["session_id"] == .string(s2) })
    }

    func testTerminalSnapshotEmitsSessionTerminal() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "completed")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        let frames = await waitForFrames(sink, containing: "session_terminal")

        XCTAssertTrue(frames.contains { $0.type == "session_terminal" && $0.sessionID == s1 })
    }

    func testExpiredSessionEmitsSessionExpiredAndDoesNotPoisonWait() async throws {
        let stale = "33333333-3333-3333-3333-333333333333"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: stale, status: "expired")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [stale])
        let frames = await waitForFrames(sink, containing: "session_expired")
        let calls = await connection.calls

        XCTAssertTrue(frames.contains { $0.type == "session_expired" && $0.sessionID == stale })
        XCTAssertFalse(calls.contains { $0.arguments["op"] == .string("wait") })
    }

    func testAntiBusySpinDoesNotWaitOnAlreadyActionableSession() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        try await Task.sleep(for: .milliseconds(150))
        let calls = await connection.calls

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["op"], .string("poll"))
    }

    func testPollCatchUpRefreshesSnapshotsAfterReconnect() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        await manager.pollCatchUp(deviceID: "device")
        let frames = await waitForFrames(sink, containing: "session_update")
        let calls = await connection.calls

        XCTAssertGreaterThanOrEqual(calls.count(where: { $0.arguments["op"] == .string("poll") }), 2)
        XCTAssertTrue(frames.contains { $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input" })
    }

    func testRearmAfterCompletedWaitLoopStartsNextWaitWithoutRetryDelay() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 5
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 1000)
        _ = await waitForCalls(connection, minimum: 2, timeoutMilliseconds: 1000)
        await manager.rearm(deviceID: "device", sessionID: s1)
        let calls = await waitForCalls(connection, minimum: 3, timeoutMilliseconds: 400)
        await manager.shutdown()

        XCTAssertGreaterThanOrEqual(calls.count, 3)
        if calls.count >= 3 {
            XCTAssertEqual(calls[2].arguments["op"], .string("wait"))
        }
    }

    func testAppLinkLossMidWaitRetriesWithoutExpiringOrClosingChannel() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .appLinkLost("restart"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForCalls(connection, minimum: 3, timeoutMilliseconds: 2000)
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)

        XCTAssertFalse(frames.contains { $0.type == "channel_closing" })
        XCTAssertFalse(frames.contains { $0.type == "session_expired" })
        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == s1
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
    }

    func testPollTransportFailureRetriesObservationWithoutSessionExpired() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .appLinkLost("restart"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForCalls(connection, minimum: 2, timeoutMilliseconds: 2000)
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)

        XCTAssertFalse(frames.contains { $0.type == "channel_closing" })
        XCTAssertFalse(frames.contains { $0.type == "session_expired" })
        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == s1
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
    }

    func testSubscribePollErrorResultPausesObservationWithoutSessionExpired() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["error": .string("No active workspace available for agent_run")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForCalls(connection, minimum: 2, timeoutMilliseconds: 2000)
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)

        // Tool-level errors (isError results) are transient: pause + retry, never expiry.
        XCTAssertFalse(frames.contains { $0.type == "session_expired" })
        XCTAssertFalse(frames.contains { $0.type == "channel_closing" })
        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == s1
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
    }

    func testSubscribeEmptyPollResultDoesNotEmitSessionExpired() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForCalls(connection, minimum: 2, timeoutMilliseconds: 2000)
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)

        // A response with no parseable snapshot is not authoritative expiry.
        XCTAssertFalse(frames.contains { $0.type == "session_expired" })
        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == s1
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
    }

    func testRevokedDeviceTeardownRemovesSinksCancelsWaitAndClosesConnection() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let deviceConnection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running")))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let pool = AppLinkPool(
            configuration: config,
            connector: StaticAppLinkConnector(connection: deviceConnection),
            bindingProbe: { _ in .bound }
        )
        let deviceID = "remote:1a2b3c4d"
        _ = try await pool.ensureLink(forDevice: deviceID)
        let defaultConnection = RecordingAppLinkConnection()
        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: defaultConnection),
            sleep: { _ in }
        )
        try await defaultAppLink.connect()
        let manager = SessionWatchManager(
            appLink: defaultAppLink,
            appLinkPool: pool,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2,
            terminalQuarantineSeconds: 0
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForFrames(sink, containing: "session_update")
        await manager.teardownDevice(
            deviceID: deviceID,
            reason: "device_revoked",
            message: "revoked"
        )
        // Let any in-flight (now-cancelled) wait call settle before capturing the
        // baseline; the wait loop may legitimately have issued one wait call
        // between subscribe and teardown.
        try await Task.sleep(for: .milliseconds(100))
        let callCountAfterTeardown = await deviceConnection.calls.count
        await manager.rearm(deviceID: deviceID, sessionID: s1)
        try await Task.sleep(for: .milliseconds(150))

        let frames = await sink.frames
        XCTAssertTrue(frames.contains { $0.type == "channel_closing" })
        let closeCount = await sink.closeCount
        XCTAssertEqual(closeCount, 1)
        let calls = await deviceConnection.calls
        XCTAssertEqual(
            calls.count,
            callCountAfterTeardown,
            "Revoked device wait loop must be cancelled and not continue streaming snapshots"
        )
        let defaultCalls = await defaultConnection.calls
        XCTAssertTrue(defaultCalls.isEmpty, "Revoked remote device must never fall back to the default app link")
    }

    // MARK: - Plan §6.2: interaction_resolved forwarding

    func testSnapshotWithInteractionResolvedMetaEmitsFrameOnceWithDedupe() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let resolvedSnapshot: JSONValue = .object([
            "session_id": .string(s1),
            "status": .string("running"),
            "updated_at": .string("2026-07-02T00:00:00.000Z"),
            "_meta": .object([
                "wake_reason": .string("interaction_resolved"),
                "interaction_resolved": .object([
                    "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
                    "resolved_by": .string("remote:aaaa1111"),
                    "resolved_at": .string("2026-07-02T00:00:01.000Z")
                ])
            ])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: resolvedSnapshot)),
            .result(GatewayTestHelpers.toolResult(json: resolvedSnapshot))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        let frames = await waitForFrames(sink, containing: "interaction_resolved")
        _ = await waitForCalls(connection, minimum: 2)
        try await Task.sleep(for: .milliseconds(100))

        let resolvedFrames = await sink.frames.filter { $0.type == "interaction_resolved" }
        XCTAssertEqual(resolvedFrames.count, 1, "Identical resolution metadata must be forwarded exactly once")
        let frame = try XCTUnwrap(resolvedFrames.first)
        XCTAssertEqual(frame.sessionID, s1)
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["interaction_id"]?.stringValue, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(payload["resolved_by"]?.stringValue, "remote:aaaa1111")
        XCTAssertEqual(payload["resolved_at"]?.stringValue, "2026-07-02T00:00:01.000Z")
        XCTAssertNotNil(frame.seq)
        XCTAssertTrue(frames.contains { $0.type == "interaction_resolved" })
    }

    // MARK: - Plan §6.3: graceful app channel_closing forwarding

    func testAppAnnouncedClosingStateForwardsChannelClosingToDevices() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running")))
        ])
        let connector = WatchChannelClosingConnector(connection: connection)
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: connector,
            sleep: { _ in }
        )
        try await appLink.connect()
        let manager = SessionWatchManager(
            appLink: appLink,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2,
            terminalQuarantineSeconds: 0
        )
        await manager.start()
        let sink = RecordingFrameSink()
        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForCalls(connection, minimum: 1)

        let capturedHandler = await connector.capturedHandler
        let handler = try XCTUnwrap(capturedHandler)
        await handler(RepoPromptChannelClosingParams(reason: .serverShutdown, message: nil))

        let frames = await waitForFrames(sink, containing: "channel_closing")
        await manager.shutdown()
        let closing = try XCTUnwrap(frames.first { $0.type == "channel_closing" })
        let payload = try XCTUnwrap(closing.payload?.objectValue)
        XCTAssertEqual(payload["reason"]?.stringValue, TerminationReason.serverShutdown.rawValue)
        XCTAssertNotNil(payload["message"]?.stringValue)
    }

    private func makeManager(
        connection: RecordingAppLinkConnection,
        windowResolver: SessionWatchManager.WindowResolver? = nil,
        pushNotifier: (any RemotePushNotifying)? = nil,
        waitTimeoutSeconds: TimeInterval = 0.2,
        pollRefreshSeconds: TimeInterval = 0.2
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
            windowResolver: windowResolver,
            waitTimeoutSeconds: waitTimeoutSeconds,
            pollRefreshSeconds: pollRefreshSeconds,
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

    private func waitForSessionStatus(
        _ sink: RecordingFrameSink,
        status: String,
        timeoutMilliseconds: Int = 1000
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.contains(where: { $0.payload?.objectValue?["status"]?.stringValue == status }) {
                return frames
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }
}

/// Plan §6.3: connector that both records tool calls and captures the
/// channel-closing handler so tests can simulate the app's announcement.
private actor WatchChannelClosingConnector: AppLinkConnecting {
    private let connection: RecordingAppLinkConnection
    private(set) var capturedHandler: (@Sendable (RepoPromptChannelClosingParams) async -> Void)?

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

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger,
        onChannelClosing: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection {
        capturedHandler = onChannelClosing
        return connection
    }
}
