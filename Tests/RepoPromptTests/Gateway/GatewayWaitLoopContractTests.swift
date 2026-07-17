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

    func testObservationExhaustionEmitsOneDeduplicatedSessionFailureWithRedactedBoundedMetadata() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("provider_failure"), "message": .string("secret payload /tmp/private")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("provider_failure")]),
                isError: true
            ))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(toolFailure: 1),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForFrames(sink, containing: "observation_failure")
        await manager.pollCatchUp(deviceID: "device")
        await manager.shutdown()

        let failures = await sink.frames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1)
        let payload = try XCTUnwrap(failures.first?.payload?.objectValue)
        XCTAssertEqual(payload["reason"]?.stringValue, "tool_failure")
        XCTAssertEqual(payload["attempt_limit"]?.intValue, 1)
        let encoded = try RemoteWireProtocol.canonicalJSONString(for: .object(payload))
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("/tmp/private"))
    }

    func testObservationFailureTaxonomyUsesNonOverlappingClassOwnedBudgets() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        for reason in RemoteObservationFailureReason.allCases {
            let connection: RecordingAppLinkConnection
            let deviceID: String
            let windowResolver: SessionWatchManager.WindowResolver?
            let windowRecovery: SessionWatchManager.WindowRecovery?
            switch reason {
            case .routingUnavailable:
                connection = RecordingAppLinkConnection()
                deviceID = "device"
                windowResolver = { _, _ in nil }
                windowRecovery = { _, _, _ in nil }
            case .linkUnavailable:
                connection = RecordingAppLinkConnection()
                deviceID = "remote:deadbeef"
                windowResolver = nil
                windowRecovery = nil
            case .toolFailure:
                connection = RecordingAppLinkConnection(responses: [
                    .result(GatewayTestHelpers.toolResult(
                        json: .object(["code": .string("tool_failed")]),
                        isError: true
                    ))
                ])
                deviceID = "device"
                windowResolver = nil
                windowRecovery = nil
            case .invalidSnapshot:
                connection = RecordingAppLinkConnection(responses: [
                    .result(GatewayTestHelpers.toolResult(json: .object(["unexpected": .bool(true)])))
                ])
                deviceID = "device"
                windowResolver = nil
                windowRecovery = nil
            }
            let (manager, _) = try await makeManager(
                connection: connection,
                windowResolver: windowResolver,
                windowRecovery: windowRecovery,
                observationFailureBudgets: .init(
                    routingUnavailable: 1,
                    linkUnavailable: 1,
                    toolFailure: 1,
                    invalidSnapshot: 1
                ),
                pollRefreshSeconds: 0.02
            )
            let sink = RecordingFrameSink()

            await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [s1])
            let frames = await waitForFrames(sink, containing: "observation_failure")
            await manager.shutdown()

            let failures = frames.filter { $0.type == "observation_failure" }
            XCTAssertEqual(failures.count, 1, reason.rawValue)
            XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, reason.rawValue)
        }
    }

    func testObservationFailureLatchResetsOnExplicitRearmAndSuccessfulSnapshot() async throws {
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["code": .string("failed")]), isError: true)),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: .object(["code": .string("failed")]), isError: true))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(toolFailure: 1),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForFrames(sink, containing: "observation_failure")
        await manager.rearm(deviceID: "device", sessionID: s1)
        _ = await waitForSessionStatus(sink, status: "running")
        await manager.pollCatchUp(deviceID: "device")
        let frames = await waitForFrameCount(sink, type: "observation_failure", minimum: 2)
        await manager.shutdown()

        XCTAssertEqual(frames.count(where: { $0.type == "observation_failure" }), 2)
    }

    func testHungAffinityDiscoveryDoesNotBlockHealthySessionWaitRearmAndDelivery() async throws {
        let stuck = "11111111-1111-1111-1111-111111111111"
        let healthy = "22222222-2222-2222-2222-222222222222"
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: healthy, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: healthy, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, sessionID in sessionID == healthy ? 2 : nil },
            windowRecovery: { _, sessionID, _ in
                guard sessionID == stuck else { return 2 }
                await gate.enterAndWaitForRelease()
                return 1
            },
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [stuck])
        await gate.waitUntilEntered()
        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [healthy])
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input")

        let discoveryStillEntered = await gate.hasEntered()
        XCTAssertTrue(discoveryStillEntered)
        XCTAssertTrue(frames.contains { $0.sessionID == healthy && $0.type == "session_update" })
        XCTAssertFalse(frames.contains { $0.sessionID == stuck })
        let calls = await connection.calls
        XCTAssertTrue(calls.filter { $0.arguments["op"] == .string("wait") }.allSatisfy {
            $0.arguments["session_id"] == .string(healthy) && $0.arguments["_windowID"] == .int(2)
        })

        await manager.unsubscribe(deviceID: "device", sessionIDs: [stuck])
        await gate.release()
        await manager.shutdown()
        let finalFrames = await sink.frames
        XCTAssertFalse(finalFrames.contains { $0.sessionID == stuck })
    }

    func testMidWatchAffinityInvalidationExhaustsRoutingBudgetOnceWhileHealthyPeerRemainsLive() async throws {
        let failing = "11111111-1111-1111-1111-111111111111"
        let healthy = "22222222-2222-2222-2222-222222222222"
        let windows = MutableObservationWindows([failing: 1, healthy: 2])
        let recovery = ObservationRecoveryRecorder(result: nil)
        let connection = RecordingAppLinkConnection()
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, sessionID in await windows.windowID(for: sessionID) },
            windowRecovery: { _, sessionID, _ in await recovery.recover(sessionID: sessionID) },
            observationFailureBudgets: .init(routingUnavailable: 2),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(
            deviceID: "device",
            sinkID: UUID(),
            sink: sink,
            sessionIDs: [failing, healthy]
        )
        _ = await waitForSessionStatus(sink, status: "running")
        let healthyFramesBefore = await sink.frames.count { $0.sessionID == healthy && $0.type == "session_update" }

        await windows.setWindowID(nil, for: failing)
        await manager.pollCatchUp(deviceID: "device")
        let failureFrames = await waitForFrameCount(sink, type: "observation_failure", minimum: 1)
        await manager.rearm(deviceID: "device", sessionID: healthy)
        await manager.pollCatchUp(deviceID: "device")
        await manager.pollCatchUp(deviceID: "device")
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(
            failureFrames.count { $0.type == "observation_failure" && $0.sessionID == failing },
            1
        )
        XCTAssertEqual(
            frames.count { $0.type == "observation_failure" && $0.sessionID == failing },
            1
        )
        XCTAssertEqual(
            frames.first { $0.type == "observation_failure" && $0.sessionID == failing }?
                .payload?.objectValue?["reason"]?.stringValue,
            "routing_unavailable"
        )
        XCTAssertGreaterThan(
            frames.count { $0.sessionID == healthy && $0.type == "session_update" },
            healthyFramesBefore
        )
        XCTAssertFalse(frames.contains { $0.sessionID == healthy && ["session_expired", "channel_closing"].contains($0.type) })
        let failingRecoveryCount = await recovery.count(for: failing)
        XCTAssertEqual(failingRecoveryCount, 1)
    }

    func testSessionExpiredToolErrorDoesNotInvalidateAffinityOrEnterRoutingRecovery() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let recovery = ObservationRecoveryRecorder(result: nil)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("session_expired")]),
                isError: true
            ))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, _ in 1 },
            windowRecovery: { _, observedSessionID, _ in
                await recovery.recover(sessionID: observedSessionID)
            },
            observationFailureBudgets: .init(routingUnavailable: 1, toolFailure: 1),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        let frames = await waitForFrames(sink, containing: "observation_failure")
        await manager.shutdown()

        let failures = frames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, "tool_failure")
        XCTAssertFalse(failures.contains { $0.payload?.objectValue?["reason"]?.stringValue == "routing_unavailable" })
        let recoveryCount = await recovery.count(for: sessionID)
        XCTAssertEqual(recoveryCount, 0)
    }

    func testPairedLinkOutageRecoversCatchUpAndWaitWithoutDefaultLinkFallback() async throws {
        let deviceID = "remote:deadbeef"
        let s1 = "11111111-1111-1111-1111-111111111111"
        let pairedConnection = RecordingAppLinkConnection(responses: [
            .appLinkLost("transient"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let fixture = try await makePairedManager(
            deviceID: deviceID,
            pairedConnection: pairedConnection,
            budgets: .init(linkUnavailable: 1)
        )
        let sink = RecordingFrameSink()

        await fixture.manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)
        await fixture.manager.shutdown()

        let frames = await sink.frames
        XCTAssertTrue(frames.contains { $0.type == "observation_failure" })
        XCTAssertTrue(frames.contains { $0.type == "session_update" && $0.sessionID == s1 })
        let defaultCalls = await fixture.defaultConnection.calls
        XCTAssertTrue(defaultCalls.isEmpty)
        XCTAssertGreaterThanOrEqual(fixture.connector.connectCount, 2)
    }

    func testPairedLinkReconnectSuccessClearsLinkUnavailableLatchWithoutObservationReconnectOwnership() async throws {
        let deviceID = "remote:deadbeef"
        let s1 = "11111111-1111-1111-1111-111111111111"
        let pairedConnection = RecordingAppLinkConnection(responses: [
            .appLinkLost("first outage"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "waiting_for_input")))
        ])
        let fixture = try await makePairedManager(
            deviceID: deviceID,
            pairedConnection: pairedConnection,
            budgets: .init(linkUnavailable: 1)
        )
        let sink = RecordingFrameSink()

        await fixture.manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [s1])
        _ = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)
        await pairedConnection.enqueue(.appLinkLost("second outage"))
        await fixture.manager.pollCatchUp(deviceID: deviceID)
        let frames = await waitForFrameCount(sink, type: "observation_failure", minimum: 2, timeoutMilliseconds: 2000)
        await fixture.manager.shutdown()

        XCTAssertEqual(frames.count(where: { $0.type == "observation_failure" }), 2)
        let defaultCalls = await fixture.defaultConnection.calls
        XCTAssertTrue(defaultCalls.isEmpty)
        XCTAssertTrue(fixture.connector.clientNames.allSatisfy { $0 == deviceID })
    }

    func testObsoleteSubscriptionTokenSuppressesLateRecoveryRetryAndFailureFrame() async throws {
        enum Invalidation: CaseIterable {
            case unsubscribe
            case teardown
            case cancellation
        }
        let s1 = "11111111-1111-1111-1111-111111111111"
        for invalidation in Invalidation.allCases {
            let gate = RecordingAppLinkResponseGate()
            let connection = RecordingAppLinkConnection()
            let (manager, _) = try await makeManager(
                connection: connection,
                windowResolver: { _, _ in nil },
                windowRecovery: { _, _, _ in
                    await gate.enterAndWaitForRelease()
                    return 1
                },
                observationFailureBudgets: .init(routingUnavailable: 2),
                pollRefreshSeconds: 0.02
            )
            let sink = RecordingFrameSink()
            await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
            await gate.waitUntilEntered()

            switch invalidation {
            case .unsubscribe:
                await manager.unsubscribe(deviceID: "device", sessionIDs: [s1])
            case .teardown:
                await manager.teardownDevice(deviceID: "device", reason: "revoked", message: "revoked")
            case .cancellation:
                await manager.shutdown()
            }
            await gate.release()
            await Task.yield()
            await manager.shutdown()

            let calls = await connection.calls
            let frames = await sink.frames
            XCTAssertFalse(calls.contains { $0.name == "agent_run" })
            XCTAssertFalse(frames.contains { $0.type == "observation_failure" })
        }
    }

    func testExpiredSnapshotInvalidatesSubscriptionAndSuppressesLateRecoveryFailure() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let expiryGate = RecordingAppLinkResponseGate()
        let recoveryGate = RecordingAppLinkResponseGate()
        let windows = MutableObservationWindows([sessionID: 1])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .gated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "expired")),
                expiryGate
            )
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, observedSessionID in await windows.windowID(for: observedSessionID) },
            windowRecovery: { _, _, _ in
                await recoveryGate.enterAndWaitForRelease()
                return nil
            },
            observationFailureBudgets: .init(routingUnavailable: 2),
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await expiryGate.waitUntilEntered()
        await windows.setWindowID(nil, for: sessionID)
        let catchUp = Task { await manager.pollCatchUp(deviceID: "device") }
        await recoveryGate.waitUntilEntered()
        await expiryGate.release()
        _ = await waitForFrames(sink, containing: "session_expired")
        await recoveryGate.release()
        await catchUp.value
        await manager.shutdown()

        let frames = await sink.frames
        XCTAssertEqual(frames.count { $0.type == "session_expired" && $0.sessionID == sessionID }, 1)
        XCTAssertFalse(frames.contains { $0.type == "observation_failure" && $0.sessionID == sessionID })
        let calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["session_id"] == .string(sessionID) }, 2)
    }

    func testObservationOperationalEventsEmitNoticeOnlyOnHealthTransitions() async throws {
        let recorder = WaitLoopLogRecorder()
        let logger = Logger(label: "test.gateway.wait.transitions") { _ in recorder.handler() }
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("tool_failed")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            logger: logger,
            observationFailureBudgets: .init(toolFailure: 2),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForSessionStatus(sink, status: "running")
        await manager.pollCatchUp(deviceID: "device")
        await manager.shutdown()

        let notices = recorder.noticeMessages
        XCTAssertEqual(notices.count { $0.contains("event=issue") && $0.contains("outcome=tool_failure") }, 1)
        XCTAssertEqual(notices.count { $0.contains("event=return") && $0.contains("outcome=healthy") }, 1)
        XCTAssertEqual(notices.count { $0.contains("outcome=success") }, 0)
        XCTAssertFalse(notices.joined(separator: " ").contains("payload"))
    }

    func testObservationOperationalEventsUseBoundedRedactedCategories() async throws {
        let recorder = WaitLoopLogRecorder()
        let logger = Logger(label: "test.gateway.wait") { _ in recorder.handler() }
        let s1 = "11111111-1111-1111-1111-111111111111"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: s1, status: "running")))
        ])
        let (manager, _) = try await makeManager(connection: connection, logger: logger)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [s1])
        await manager.shutdown()

        let messages = recorder.messages.joined(separator: " ")
        XCTAssertTrue(messages.contains("event=issue"))
        XCTAssertTrue(messages.contains("event=return"))
        XCTAssertFalse(messages.contains("payload"))
        XCTAssertFalse(messages.contains("credential"))
        XCTAssertFalse(messages.contains("/tmp"))
    }

    func testSubscribeWrongOnlySnapshotChargesRequestedInvalidSnapshotWithoutUnsolicitedState() async throws {
        let requested = "11111111-1111-1111-1111-111111111111"
        let wrong = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: wrong, status: "running")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(invalidSnapshot: 1),
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [requested])
        let frames = await waitForFrames(sink, containing: "observation_failure")
        let wrongState = await manager.debugTerminalState(deviceID: "device", sessionID: wrong)
        await manager.shutdown()

        let failures = frames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.sessionID, requested)
        XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, "invalid_snapshot")
        XCTAssertFalse(frames.contains { $0.sessionID == wrong })
        XCTAssertFalse(wrongState.watched)
    }

    func testSubscribeMixedSnapshotsAcceptsOnlyNormalizedRequestedSession() async throws {
        let requested = "11111111-1111-1111-1111-111111111111"
        let wrong = "99999999-9999-9999-9999-999999999999"
        let paddedRequested = "  \(requested)\n"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.multiSnapshots([
                GatewayTestHelpers.snapshot(sessionID: wrong, status: "expired"),
                GatewayTestHelpers.snapshot(sessionID: paddedRequested, status: "waiting_for_input")
            ], sessionIDs: [wrong, paddedRequested])))
        ])
        let (manager, _) = try await makeManager(connection: connection)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [" \(requested)\n"])
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input")
        let wrongState = await manager.debugTerminalState(deviceID: "device", sessionID: wrong)
        await manager.shutdown()

        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == requested
                && $0.payload?.objectValue?["session_id"]?.stringValue == requested
        })
        XCTAssertFalse(frames.contains { $0.sessionID == wrong })
        XCTAssertFalse(wrongState.watched)
    }

    func testSubscribeMismatchedExpiredSnapshotDoesNotExpireOrEmitUnsolicitedSession() async throws {
        let requested = "11111111-1111-1111-1111-111111111111"
        let wrong = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: wrong, status: "expired")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(invalidSnapshot: 1),
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [requested])
        let frames = await waitForFrames(sink, containing: "observation_failure")
        let wrongState = await manager.debugTerminalState(deviceID: "device", sessionID: wrong)
        await manager.shutdown()

        XCTAssertEqual(frames.count { $0.type == "observation_failure" && $0.sessionID == requested }, 1)
        XCTAssertFalse(frames.contains { $0.type == "session_expired" })
        XCTAssertFalse(frames.contains { $0.sessionID == wrong })
        XCTAssertFalse(wrongState.watched)
    }

    func testMidWatchRecoveredWindowBindingRequiredExhaustsRoutingEpochOnceWithoutReplay() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let windows = MutableObservationWindows([sessionID: 1])
        let recovery = ObservationRecoveryRecorder(result: 2)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "waiting_for_input"
            ))),
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("binding_required")]),
                isError: true
            ))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, observedSessionID in await windows.windowID(for: observedSessionID) },
            windowRecovery: { _, observedSessionID, _ in
                let recovered = await recovery.recover(sessionID: observedSessionID)
                await windows.setWindowID(recovered, for: observedSessionID)
                return recovered
            },
            observationFailureBudgets: .init(routingUnavailable: 3),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await windows.setWindowID(nil, for: sessionID)
        await manager.pollCatchUp(deviceID: "device")
        let frames = await waitForFrames(sink, containing: "observation_failure")
        await manager.pollCatchUp(deviceID: "device")
        let calls = await connection.calls
        let recoveryCount = await recovery.count(for: sessionID)
        await manager.shutdown()

        let failures = frames.filter { $0.type == "observation_failure" && $0.sessionID == sessionID }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, "routing_unavailable")
        XCTAssertEqual(failures.first?.payload?.objectValue?["attempt"]?.intValue, 3)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(calls.count(where: { $0.arguments["op"] == .string("poll") }), 2)
        XCTAssertEqual(calls.last?.arguments["_windowID"]?.intValue, 2)
    }

    func testFailedPartitionRecoveryWhileHealthyWaitHeldAutomaticallyRearmsAndDelivers() async throws {
        let failing = "11111111-1111-1111-1111-111111111111"
        let healthy = "22222222-2222-2222-2222-222222222222"
        let connection = PartitionInterleavingAppLinkConnection(failing: failing, healthy: healthy)
        let (manager, _) = try await makeManager(
            connection: connection,
            windowResolver: { _, sessionID in sessionID == failing ? 1 : 2 },
            observationFailureBudgets: .init(routingUnavailable: 1),
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(
            deviceID: "device",
            sinkID: UUID(),
            sink: sink,
            sessionIDs: [failing, healthy]
        )
        await connection.waitUntilHealthyWaitIsHeld()
        _ = await waitForFrames(sink, containing: "observation_failure")
        await connection.releaseHealthyWait()
        let frames = await waitForSessionStatus(sink, status: "waiting_for_input", timeoutMilliseconds: 2000)
        let healthyWaitCount = await connection.healthyWaitCount
        await manager.shutdown()

        XCTAssertTrue(frames.contains {
            $0.type == "session_update"
                && $0.sessionID == healthy
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
        XCTAssertEqual(frames.count { $0.type == "observation_failure" && $0.sessionID == failing }, 1)
        XCTAssertGreaterThanOrEqual(healthyWaitCount, 2)
    }

    func testObservationNoticeIdentifiersUseSafeEncodingAndRejectFieldInjection() async throws {
        let recorder = WaitLoopLogRecorder()
        let logger = Logger(label: "test.gateway.wait.safe-identifiers") { _ in recorder.handler() }
        let deviceID = "remote:secret-device\r\n outcome=forged\tapi_key=alpha"
        let sessionID = "secret-session\r\n session_id=forged authorization=bearer"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["unexpected": .bool(true)])))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            logger: logger,
            observationFailureBudgets: .init(invalidSnapshot: 1),
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForFrames(sink, containing: "observation_failure")
        await manager.shutdown()

        let notices = recorder.noticeMessages
        let joined = notices.joined(separator: " ")
        XCTAssertFalse(joined.contains("secret-device"))
        XCTAssertFalse(joined.contains("secret-session"))
        XCTAssertFalse(joined.contains("outcome=forged"))
        XCTAssertFalse(joined.contains("api_key=alpha"))
        XCTAssertFalse(joined.contains("authorization=bearer"))
        XCTAssertFalse(joined.contains("\r"))
        XCTAssertFalse(joined.contains("\n"))
        XCTAssertFalse(joined.contains("\t"))
        assertSafeIdentifierFields(in: notices)
    }

    func testRepeatedEmptyWaitsChargeRequestedSessionAndEmitOneBoundedFailure() async throws {
        let sessionID = "11111111-AAAA-BBBB-CCCC-111111111111"
        let firstEmptyGate = RecordingAppLinkResponseGate()
        let deadlineScheduler = ManualWatchDeadlineScheduler()
        let retryScheduler = ManualWatchDeadlineScheduler()
        let empty = GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .gated(empty, firstEmptyGate),
            .result(empty),
            .result(empty)
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(invalidSnapshot: 2),
            waitTimeoutSeconds: 2,
            waitWatchdogMarginSeconds: 6,
            waitDeadlineSleep: { try await deadlineScheduler.sleep(seconds: $0) },
            waitRetrySleep: { try await retryScheduler.sleep(seconds: $0) },
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await firstEmptyGate.waitUntilEntered()
        await deadlineScheduler.waitUntilScheduled(count: 1)
        let configuredDurations = await deadlineScheduler.recordedDurations
        XCTAssertEqual(configuredDurations.first, 8)
        await firstEmptyGate.release()

        await retryScheduler.waitUntilScheduled(count: 1)
        var calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["op"] == .string("wait") }, 1, "first empty result must wait for its scheduled retry")
        let framesBeforeRetry = await sink.frames
        XCTAssertFalse(framesBeforeRetry.contains { $0.type == "observation_failure" })
        var retryDurations = await retryScheduler.recordedDurations
        XCTAssertEqual(retryDurations, [0.05])

        let firstRetryFired = await retryScheduler.fireNext()
        XCTAssertTrue(firstRetryFired)
        await retryScheduler.waitUntilScheduled(count: 2)
        calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["op"] == .string("wait") }, 2, "second empty result must not immediately rearm")
        let framesAtLimit = await waitForFrames(sink, containing: "observation_failure")
        retryDurations = await retryScheduler.recordedDurations
        XCTAssertEqual(retryDurations, [0.05, 0.05])

        let secondRetryFired = await retryScheduler.fireNext()
        XCTAssertTrue(secondRetryFired)
        await retryScheduler.waitUntilScheduled(count: 3)
        calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["op"] == .string("wait") }, 3, "every instant-empty cycle must be paced by its retry")
        let finalFrames = await sink.frames
        await manager.shutdown()
        _ = await retryScheduler.fireAll()

        let failures = finalFrames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1, "three paced empty waits must emit exactly one latched failure")
        XCTAssertEqual(framesAtLimit.count { $0.type == "observation_failure" }, 1)
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failure.sessionID, sessionID)
        XCTAssertEqual(failure.payload?.objectValue?["reason"]?.stringValue, "invalid_snapshot")
        XCTAssertEqual(failure.payload?.objectValue?["attempt"]?.intValue, 2)
        XCTAssertEqual(failure.payload?.objectValue?["attempt_limit"]?.intValue, 2)
        XCTAssertNotNil(failure.seq)
        XCTAssertNotNil(failure.seqEpoch)
    }

    func testRejectedWaitSnapshotsChargeEveryCurrentRequestWithoutUnsolicitedFrames() async throws {
        let first = "11111111-1111-1111-1111-111111111111"
        let second = "22222222-2222-2222-2222-222222222222"
        let unsolicited = "99999999-9999-9999-9999-999999999999"
        let cases: [(name: String, payload: JSONValue)] = [
            ("wrong_id", GatewayTestHelpers.snapshot(sessionID: unsolicited, status: "running")),
            ("missing_id", .object(["status": .string("running")])),
            ("missing_status", .object(["session_id": .string(unsolicited)])),
            ("unusable_row", .object(["snapshots": .array([.string("not-a-snapshot")])]))
        ]

        for testCase in cases {
            let connection = RecordingAppLinkConnection(responses: [
                .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: first, status: "running"))),
                .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: second, status: "running"))),
                .result(GatewayTestHelpers.toolResult(json: testCase.payload))
            ])
            let (manager, _) = try await makeManager(
                connection: connection,
                observationFailureBudgets: .init(invalidSnapshot: 1),
                pollRefreshSeconds: 1
            )
            let sink = RecordingFrameSink()

            await manager.subscribe(
                deviceID: "device",
                sinkID: UUID(),
                sink: sink,
                sessionIDs: [first, second]
            )
            let frames = await waitForFrameCount(
                sink,
                type: "observation_failure",
                minimum: 2
            )
            let unsolicitedState = await manager.debugTerminalState(
                deviceID: "device",
                sessionID: unsolicited
            )
            await manager.shutdown()

            let failures = frames.filter { $0.type == "observation_failure" }
            XCTAssertEqual(failures.count, 2, testCase.name)
            XCTAssertEqual(Set(failures.compactMap(\.sessionID)), Set([first, second]), testCase.name)
            XCTAssertTrue(failures.allSatisfy {
                $0.payload?.objectValue?["reason"]?.stringValue == "invalid_snapshot"
                    && $0.payload?.objectValue?["attempt"]?.intValue == 1
                    && $0.payload?.objectValue?["attempt_limit"]?.intValue == 1
            }, testCase.name)
            XCTAssertFalse(frames.contains { $0.sessionID == unsolicited }, testCase.name)
            XCTAssertFalse(unsolicitedState.watched, testCase.name)
            XCTAssertFalse(unsolicitedState.parkedTerminal, testCase.name)
            XCTAssertFalse(unsolicitedState.pendingQuarantine, testCase.name)
        }
    }

    func testLateWaitFromObsoleteSubscriptionTokenCannotSatisfyReplacement() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let obsoleteWaitGate = CancellationObservableAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .cancellationObservedGated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "completed")),
                obsoleteWaitGate
            ),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])])))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(invalidSnapshot: 1),
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: "device", sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        await obsoleteWaitGate.waitUntilEntered()
        await manager.unsubscribe(deviceID: "device", sessionIDs: [sessionID])
        await obsoleteWaitGate.waitUntilCancelled()
        await manager.subscribe(deviceID: "device", sinkID: sinkID, sink: sink, sessionIDs: [sessionID])
        let replacementFrames = await waitForFrames(sink, containing: "observation_failure")
        await obsoleteWaitGate.release()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await manager.shutdown()

        let failures = replacementFrames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.sessionID, sessionID)
        XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, "invalid_snapshot")
        let finalFrames = await sink.frames
        XCTAssertFalse(finalFrames.contains { $0.type == "session_terminal" })
        XCTAssertEqual(finalFrames.count { $0.type == "observation_failure" }, 1)
    }

    func testCaseOnlyUUIDSnapshotUsesSubscribedCanonicalIDWhileNonUUIDCaseRemainsDistinct() async throws {
        let subscribedUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let subscribedUUIDVariant = subscribedUUID.lowercased()
        let uuidConnection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: subscribedUUIDVariant, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: subscribedUUID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: subscribedUUIDVariant, status: "waiting_for_input")))
        ])
        let (uuidManager, _) = try await makeManager(connection: uuidConnection)
        let uuidSink = RecordingFrameSink()

        await uuidManager.subscribe(
            deviceID: "uuid-device",
            sinkID: UUID(),
            sink: uuidSink,
            sessionIDs: ["  \(subscribedUUID)\n", subscribedUUIDVariant]
        )
        let uuidFrames = await waitForFrameCount(uuidSink, type: "session_update", minimum: 4)
        await uuidManager.shutdown()

        let accepted = uuidFrames.filter {
            $0.type == "session_update"
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        }
        XCTAssertEqual(accepted.count, 2, "one canonical UUID snapshot must satisfy every current subscribed spelling")
        XCTAssertEqual(Set(accepted.compactMap(\.sessionID)), Set([subscribedUUID, subscribedUUIDVariant]))
        XCTAssertTrue(accepted.allSatisfy {
            $0.payload?.objectValue?["session_id"]?.stringValue == $0.sessionID
        }, "each emitted frame and payload must preserve its exact subscribed ID")

        let subscribedArbitrary = "Session-A"
        let returnedArbitrary = "session-a"
        let arbitraryConnection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: subscribedArbitrary, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: returnedArbitrary, status: "waiting_for_input")))
        ])
        let (arbitraryManager, _) = try await makeManager(
            connection: arbitraryConnection,
            observationFailureBudgets: .init(invalidSnapshot: 1),
            pollRefreshSeconds: 1
        )
        let arbitrarySink = RecordingFrameSink()

        await arbitraryManager.subscribe(
            deviceID: "arbitrary-device",
            sinkID: UUID(),
            sink: arbitrarySink,
            sessionIDs: [subscribedArbitrary]
        )
        let arbitraryFrames = await waitForFrames(arbitrarySink, containing: "observation_failure")
        let returnedState = await arbitraryManager.debugTerminalState(
            deviceID: "arbitrary-device",
            sessionID: returnedArbitrary
        )
        await arbitraryManager.shutdown()

        XCTAssertEqual(arbitraryFrames.count { $0.type == "observation_failure" && $0.sessionID == subscribedArbitrary }, 1)
        XCTAssertFalse(arbitraryFrames.contains { $0.sessionID == returnedArbitrary })
        XCTAssertFalse(returnedState.watched)
    }

    func testNeverReturningWaitDeadlineCancelsStaleOwnerAndStartsFreshWait() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let staleWaitGate = CancellationObservableAppLinkResponseGate()
        let deadlineScheduler = ManualWatchDeadlineScheduler()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .cancellationObservedGated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "completed")),
                staleWaitGate
            ),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(toolFailure: 1),
            waitTimeoutSeconds: 2,
            waitWatchdogMarginSeconds: 6,
            waitDeadlineSleep: { try await deadlineScheduler.sleep(seconds: $0) },
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await staleWaitGate.waitUntilEntered()
        await deadlineScheduler.waitUntilScheduled(count: 1)
        let durations = await deadlineScheduler.recordedDurations
        XCTAssertEqual(durations.first, 8)
        let firedCount = await deadlineScheduler.fireAll()
        XCTAssertGreaterThanOrEqual(firedCount, 1)
        await staleWaitGate.waitUntilCancelled()
        let callsBeforeStaleRelease = await waitForCalls(connection, minimum: 3)
        let framesBeforeStaleRelease = await waitForSessionStatus(sink, status: "waiting_for_input")

        XCTAssertGreaterThanOrEqual(callsBeforeStaleRelease.count, 3)
        XCTAssertTrue(framesBeforeStaleRelease.contains {
            $0.type == "session_update"
                && $0.sessionID == sessionID
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })
        XCTAssertEqual(framesBeforeStaleRelease.count {
            $0.type == "observation_failure"
                && $0.payload?.objectValue?["reason"]?.stringValue == "tool_failure"
        }, 1)

        await staleWaitGate.release()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await manager.shutdown()
        let finalFrames = await sink.frames
        XCTAssertFalse(finalFrames.contains { $0.type == "session_terminal" })
        XCTAssertEqual(finalFrames.count { $0.type == "observation_failure" }, 1)
    }

    func testRepeatedRearmCannotPostponeCurrentSubscriptionAccountability() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let firstWaitGate = CancellationObservableAppLinkResponseGate()
        let secondWaitGate = CancellationObservableAppLinkResponseGate()
        let deadlineScheduler = ManualWatchDeadlineScheduler()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .cancellationObservedGated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "completed")),
                firstWaitGate
            ),
            .cancellationObservedGated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "completed")),
                secondWaitGate
            ),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            observationFailureBudgets: .init(toolFailure: 2),
            waitTimeoutSeconds: 2,
            waitWatchdogMarginSeconds: 6,
            waitDeadlineSleep: { try await deadlineScheduler.sleep(seconds: $0) },
            pollRefreshSeconds: 1
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        await firstWaitGate.waitUntilEntered()
        await deadlineScheduler.waitUntilScheduled(count: 1)
        for _ in 0 ..< 3 {
            await manager.rearm(deviceID: "device", sessionID: sessionID)
        }
        var calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["op"] == .string("wait") }, 1, "rearm must not install a duplicate current owner")

        let firstDeadlineFireCount = await deadlineScheduler.fireAll()
        XCTAssertGreaterThanOrEqual(firstDeadlineFireCount, 1)
        await firstWaitGate.waitUntilCancelled()
        await secondWaitGate.waitUntilEntered()
        await deadlineScheduler.waitUntilScheduled(count: 2)
        for _ in 0 ..< 3 {
            await manager.rearm(deviceID: "device", sessionID: sessionID)
        }
        calls = await connection.calls
        XCTAssertEqual(calls.count { $0.arguments["op"] == .string("wait") }, 2, "six rearms must not move the active deadline or add an owner")

        let secondDeadlineFireCount = await deadlineScheduler.fireAll()
        XCTAssertGreaterThanOrEqual(secondDeadlineFireCount, 1)
        await secondWaitGate.waitUntilCancelled()
        let accountableFrames = await waitForSessionStatus(sink, status: "waiting_for_input")
        let failures = accountableFrames.filter { $0.type == "observation_failure" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.payload?.objectValue?["reason"]?.stringValue, "tool_failure")
        XCTAssertEqual(failures.first?.payload?.objectValue?["attempt"]?.intValue, 2)
        XCTAssertEqual(failures.first?.payload?.objectValue?["attempt_limit"]?.intValue, 2)
        XCTAssertTrue(accountableFrames.contains {
            $0.type == "session_update"
                && $0.sessionID == sessionID
                && $0.payload?.objectValue?["status"]?.stringValue == "waiting_for_input"
        })

        let durations = await deadlineScheduler.recordedDurations
        XCTAssertTrue(durations.prefix(2).allSatisfy { $0 == 8 })
        await firstWaitGate.release()
        await secondWaitGate.release()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await manager.shutdown()
        let finalFrames = await sink.frames
        XCTAssertFalse(finalFrames.contains { $0.type == "session_terminal" })
        XCTAssertEqual(finalFrames.count { $0.type == "observation_failure" }, 1)
    }

    func testWatchOperationalMarkersAreDistinctAllowlistedAndContentFree() async throws {
        let recorder = WaitLoopLogRecorder()
        let logger = Logger(label: "test.gateway.watch-accountability") { _ in recorder.handler() }
        let deviceID = "raw-device-canary"
        let sessionID = "raw-session-canary"
        let unsolicitedID = "raw-unsolicited-canary"
        let deadlineGate = CancellationObservableAppLinkResponseGate()
        let deadlineScheduler = ManualWatchDeadlineScheduler()
        let rejectedPayload: JSONValue = .object([
            "session_id": .string(unsolicitedID),
            "status": .string("status-canary"),
            "prompt": .string("prompt-canary"),
            "assistant_text": .string("assistant-canary"),
            "transcript": .string("transcript-canary"),
            "workspace_name": .string("workspace-canary"),
            "path": .string("/private/path-canary"),
            "credential": .string("credential-canary"),
            "subscription_token": .string("subscription-token-canary"),
            "raw_payload": .string("raw-payload-canary")
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))),
            .result(GatewayTestHelpers.toolResult(json: rejectedPayload)),
            .cancellationObservedGated(
                GatewayTestHelpers.toolResult(json: rejectedPayload),
                deadlineGate
            ),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let (manager, _) = try await makeManager(
            connection: connection,
            logger: logger,
            observationFailureBudgets: .init(toolFailure: 1, invalidSnapshot: 2),
            waitTimeoutSeconds: 2,
            waitWatchdogMarginSeconds: 6,
            waitDeadlineSleep: { try await deadlineScheduler.sleep(seconds: $0) },
            pollRefreshSeconds: 0.02
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: deviceID, sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForFrames(sink, containing: "observation_failure")
        await deadlineGate.waitUntilEntered()
        await manager.rearm(deviceID: deviceID, sessionID: sessionID)
        await deadlineScheduler.waitUntilScheduled(count: 3)
        let deadlineFireCount = await deadlineScheduler.fireAll()
        XCTAssertGreaterThanOrEqual(deadlineFireCount, 1)
        await deadlineGate.waitUntilCancelled()
        _ = await waitForSessionStatus(sink, status: "waiting_for_input")
        await deadlineGate.release()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await manager.shutdown()

        func parsedFields(_ message: String) -> [String: String] {
            message.split(separator: " ").dropFirst().reduce(into: [:]) { fields, component in
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    fields[parts[0]] = parts[1]
                }
            }
        }

        let records = recorder.records
        let markerRecords = records.filter { $0.message.hasPrefix("watch_accountability ") }
        let markerFields = markerRecords.map { parsedFields($0.message).merging($0.metadata) { _, metadata in metadata } }
        let outcomes = Set(markerFields.compactMap { $0["outcome"] })
        let requiredOutcomes: Set = [
            "accepted", "empty", "rejected", "deadline_exceeded", "rearm",
            "transition", "exhausted", "emitted"
        ]
        XCTAssertTrue(requiredOutcomes.isSubset(of: outcomes), "missing outcomes: \(requiredOutcomes.subtracting(outcomes).sorted())")

        let allowedKeys: Set = [
            "event", "outcome", "reason", "attempt", "attempt_limit", "duration_ms",
            "window_id", "frame_type", "seq", "seq_epoch", "trigger", "device_id",
            "session_id", "correlation_id"
        ]
        for fields in markerFields {
            let extraKeys = Set(fields.keys).subtracting(allowedKeys)
            XCTAssertTrue(extraKeys.isEmpty, "unexpected marker keys: \(extraKeys.sorted())")
            for key in ["attempt", "attempt_limit", "duration_ms", "seq"] {
                guard let value = fields[key], value != "-" else { continue }
                let number = Int64(value)
                XCTAssertNotNil(number, "non-numeric marker key: \(key)")
                XCTAssertTrue((number ?? -1) >= 0 && (number ?? 1_000_001) <= 1_000_000, "out-of-range marker key: \(key)")
            }
            for key in ["device_id", "session_id", "correlation_id"] {
                guard let value = fields[key] else { continue }
                XCTAssertEqual(value.count, 27, "unsafe identifier key: \(key)")
                XCTAssertTrue(value.hasPrefix("id_"), "unsafe identifier key: \(key)")
            }
        }

        let serialized = records.map { record in
            let metadata = record.metadata.keys.sorted().map { "\($0)=\(record.metadata[$0] ?? "")" }.joined(separator: " ")
            return record.message + " " + metadata
        }.joined(separator: "\n")
        for forbiddenValue in [
            deviceID, sessionID, unsolicitedID, "status-canary", "prompt-canary",
            "assistant-canary", "transcript-canary", "workspace-canary", "/private/path-canary",
            "credential-canary", "subscription-token-canary", "raw-payload-canary"
        ] {
            XCTAssertFalse(serialized.contains(forbiddenValue))
        }
        for forbiddenKey in [
            "prompt", "assistant_text", "transcript", "status", "message_content", "workspace",
            "workspace_name", "path", "credential", "token", "subscription_token", "payload",
            "raw_payload"
        ] {
            XCTAssertFalse(serialized.contains("\(forbiddenKey)="), "forbidden diagnostic key: \(forbiddenKey)")
        }
    }

    func testAppGlobalClosingReachesDefaultAndPairedDevicesWhileReconnectStateRemainsScoped() async throws {
        let sessionID = "11111111-1111-1111-1111-111111111111"
        let remoteDeviceID = "remote:deadbeef"
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let defaultConnection = RecordingAppLinkConnection(responses: [.appLinkLost("default outage")])
        let defaultConnector = WatchChannelClosingConnector(connection: defaultConnection)
        let defaultLink = AppLinkSession(config: config, connector: defaultConnector, sleep: { _ in })
        try await defaultLink.connect()
        let pairedConnection = RecordingAppLinkConnection()
        let pairedConnector = WaitLoopPairedConnector(connection: pairedConnection)
        let pool = AppLinkPool(
            configuration: config,
            connector: pairedConnector,
            bindingProbe: { _ in .bound }
        )
        _ = try await pool.ensureLink(forDevice: remoteDeviceID)
        let manager = SessionWatchManager(
            appLink: defaultLink,
            appLinkPool: pool,
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.02,
            terminalQuarantineSeconds: 0
        )
        await manager.start()
        let defaultSink = RecordingFrameSink()
        let pairedSink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: defaultSink, sessionIDs: [sessionID])
        await manager.subscribe(deviceID: remoteDeviceID, sinkID: UUID(), sink: pairedSink, sessionIDs: [sessionID])
        _ = await waitForSessionStatus(pairedSink, status: "running")
        let pairedBeforeClosing = await pairedSink.frames
        XCTAssertFalse(pairedBeforeClosing.contains { ["observation_failure", "channel_closing"].contains($0.type) })

        let capturedHandler = await defaultConnector.capturedHandler
        let handler = try XCTUnwrap(capturedHandler)
        await handler(RepoPromptChannelClosingParams(reason: .serverShutdown, message: nil))
        _ = await waitForFrames(defaultSink, containing: "channel_closing")
        _ = await waitForFrames(pairedSink, containing: "channel_closing")
        await manager.shutdown()

        let defaultFrames = await defaultSink.frames
        let pairedFrames = await pairedSink.frames
        XCTAssertEqual(defaultFrames.count { $0.type == "channel_closing" }, 1)
        XCTAssertEqual(pairedFrames.count { $0.type == "channel_closing" }, 1)
        XCTAssertFalse(pairedFrames.contains { $0.type == "observation_failure" })
        let defaultCalls = await defaultConnection.calls
        let pairedCalls = await pairedConnection.calls
        XCTAssertFalse(defaultCalls.isEmpty)
        XCTAssertFalse(pairedCalls.isEmpty)
    }

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

    private func makePairedManager(
        deviceID: String,
        pairedConnection: RecordingAppLinkConnection,
        budgets: SessionWatchManager.ObservationFailureBudgets
    ) async throws -> (
        manager: SessionWatchManager,
        defaultConnection: RecordingAppLinkConnection,
        connector: WaitLoopPairedConnector
    ) {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let defaultConnection = RecordingAppLinkConnection()
        let defaultLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: defaultConnection),
            sleep: { _ in }
        )
        try await defaultLink.connect()
        let connector = WaitLoopPairedConnector(connection: pairedConnection)
        let pool = AppLinkPool(
            configuration: config,
            connector: connector,
            bindingProbe: { _ in .bound }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)
        let manager = SessionWatchManager(
            appLink: defaultLink,
            appLinkPool: pool,
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.02,
            terminalQuarantineSeconds: 0,
            observationFailureBudgets: budgets
        )
        return (manager, defaultConnection, connector)
    }

    private func makeManager(
        connection: any AppLinkConnection,
        windowResolver: SessionWatchManager.WindowResolver? = nil,
        windowRecovery: SessionWatchManager.WindowRecovery? = nil,
        pushNotifier: (any RemotePushNotifying)? = nil,
        logger: Logger = Logger(label: "test.gateway.wait"),
        observationFailureBudgets: SessionWatchManager.ObservationFailureBudgets = .init(),
        waitTimeoutSeconds: TimeInterval = 0.2,
        waitWatchdogMarginSeconds: TimeInterval = 10,
        waitDeadlineSleep: @escaping SessionWatchManager.WaitDeadlineSleep = { seconds in
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
        },
        waitRetrySleep: @escaping SessionWatchManager.WaitRetrySleep = { seconds in
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
        },
        pollRefreshSeconds: TimeInterval = 0.2
    ) async throws -> (SessionWatchManager, AppLinkSession) {
        let root = try GatewayTestHelpers.temporaryRoot("wait-manager")
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: WaitLoopAnyConnectionConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let manager = SessionWatchManager(
            appLink: appLink,
            pushNotifier: pushNotifier,
            windowResolver: windowResolver,
            logger: logger,
            waitTimeoutSeconds: waitTimeoutSeconds,
            waitWatchdogMarginSeconds: waitWatchdogMarginSeconds,
            waitDeadlineSleep: waitDeadlineSleep,
            waitRetrySleep: waitRetrySleep,
            pollRefreshSeconds: pollRefreshSeconds,
            terminalQuarantineSeconds: 0,
            observationFailureBudgets: observationFailureBudgets
        )
        if windowRecovery != nil {
            await manager.setObservationRouting(
                windowResolver: windowResolver,
                windowRecovery: windowRecovery
            )
        }
        return (manager, appLink)
    }

    private func assertSafeIdentifierFields(in messages: [String], file: StaticString = #filePath, line: UInt = #line) {
        for message in messages {
            for key in ["device_id=", "session_id="] {
                guard let range = message.range(of: key) else { continue }
                let value = message[range.upperBound...].prefix { !$0.isWhitespace }
                XCTAssertEqual(value.count, 27, file: file, line: line)
                XCTAssertTrue(value.hasPrefix("id_"), file: file, line: line)
                XCTAssertTrue(
                    value.dropFirst(3).allSatisfy { $0.isNumber || ("a" ... "f").contains(String($0)) },
                    file: file,
                    line: line
                )
            }
        }
    }

    private func waitForCalls(
        _ connection: RecordingAppLinkConnection,
        minimum: Int,
        timeoutMilliseconds: Int = 1000
    ) async -> [RecordedGatewayToolCall] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let calls = await connection.calls
            if calls.count >= minimum {
                return calls
            }
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
            if frames.contains(where: { $0.type == type }) {
                return frames
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }

    private func waitForFrameCount(
        _ sink: RecordingFrameSink,
        type: String,
        minimum: Int,
        timeoutMilliseconds: Int = 1000
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.count(where: { $0.type == type }) >= minimum {
                return frames
            }
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

private actor ManualWatchDeadlineScheduler {
    private struct Entry {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var entries: [Entry] = []
    private var durationHistory: [TimeInterval] = []
    private var scheduleWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                durationHistory.append(seconds)
                entries.append(Entry(id: id, continuation: continuation))
                resumeSatisfiedScheduleWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilScheduled(count: Int) async {
        if durationHistory.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            scheduleWaiters.append((count, continuation))
        }
    }

    @discardableResult
    func fireNext() -> Bool {
        guard !entries.isEmpty else { return false }
        let entry = entries.removeFirst()
        entry.continuation.resume()
        return true
    }

    @discardableResult
    func fireAll() -> Int {
        let scheduled = entries
        entries.removeAll()
        scheduled.forEach { $0.continuation.resume() }
        return scheduled.count
    }

    var recordedDurations: [TimeInterval] {
        durationHistory
    }

    private func cancel(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedScheduleWaiters() {
        let satisfied = scheduleWaiters.filter { durationHistory.count >= $0.count }
        scheduleWaiters.removeAll { durationHistory.count >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private struct WaitLoopAnyConnectionConnector: AppLinkConnecting {
    let connection: any AppLinkConnection

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}

private actor PartitionInterleavingAppLinkConnection: AppLinkConnection {
    private let failing: String
    private let healthy: String
    private let healthyGate = RecordingAppLinkResponseGate()
    private(set) var healthyWaitCount = 0

    init(failing: String, healthy: String) {
        self.failing = failing
        self.healthy = healthy
    }

    func waitUntilHealthyWaitIsHeld() async {
        await healthyGate.waitUntilEntered()
    }

    func releaseHealthyWait() async {
        await healthyGate.release()
    }

    func callTool(
        name _: String,
        arguments: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        let operation = arguments["op"]?.stringValue
        let sessionID = arguments["session_id"]?.stringValue
        if operation == "poll", let sessionID {
            return GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
            )
        }
        if operation == "wait", sessionID == failing {
            return GatewayTestHelpers.toolResult(
                json: .object(["code": .string("binding_required")]),
                isError: true
            )
        }
        if operation == "wait", sessionID == healthy {
            healthyWaitCount += 1
            if healthyWaitCount == 1 {
                await healthyGate.enterAndWaitForRelease()
                return GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))
            }
            return GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: healthy, status: "waiting_for_input")
            )
        }
        return GatewayTestHelpers.toolResult(json: .object(["snapshots": .array([])]))
    }

    func disconnect() async {}
}

private final class WaitLoopPairedConnector: AppLinkConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: RecordingAppLinkConnection
    private var recordedClientNames: [String] = []

    init(connection: RecordingAppLinkConnection) {
        self.connection = connection
    }

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedClientNames.count
    }

    var clientNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedClientNames
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        lock.lock()
        recordedClientNames.append(clientName)
        lock.unlock()
        return connection
    }
}

private struct WaitLoopLogRecord {
    let level: Logger.Level
    let message: String
    let metadata: [String: String]
}

private final class WaitLoopLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRecords: [WaitLoopLogRecord] = []

    var records: [WaitLoopLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    var messages: [String] {
        records.map(\.message)
    }

    var noticeMessages: [String] {
        records.filter { $0.level >= .notice }.map(\.message)
    }

    func handler() -> WaitLoopCaptureLogHandler {
        WaitLoopCaptureLogHandler(recorder: self)
    }

    func record(level: Logger.Level, message: String, metadata: [String: String]) {
        lock.lock()
        storedRecords.append(WaitLoopLogRecord(level: level, message: message, metadata: metadata))
        lock.unlock()
    }
}

private struct WaitLoopCaptureLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    private let recorder: WaitLoopLogRecorder

    init(recorder: WaitLoopLogRecorder) {
        self.recorder = recorder
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata additionalMetadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var mergedMetadata = metadata
        additionalMetadata?.forEach { mergedMetadata[$0.key] = $0.value }
        recorder.record(
            level: level,
            message: message.description,
            metadata: mergedMetadata.mapValues(\.description)
        )
    }
}

private actor MutableObservationWindows {
    private var windowBySessionID: [String: Int]

    init(_ windowBySessionID: [String: Int]) {
        self.windowBySessionID = windowBySessionID
    }

    func windowID(for sessionID: String) -> Int? {
        windowBySessionID[sessionID]
    }

    func setWindowID(_ windowID: Int?, for sessionID: String) {
        windowBySessionID[sessionID] = windowID
    }
}

private actor ObservationRecoveryRecorder {
    private let result: Int?
    private var counts: [String: Int] = [:]

    init(result: Int?) {
        self.result = result
    }

    func recover(sessionID: String) -> Int? {
        counts[sessionID, default: 0] += 1
        return result
    }

    func count(for sessionID: String) -> Int {
        counts[sessionID, default: 0]
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
