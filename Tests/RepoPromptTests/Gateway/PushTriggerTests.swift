import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// M5 wake-only semantics: push fires ONLY for a disconnected device and ONLY on
/// wake-worthy transitions (`waiting_for_input` or terminal).
final class PushTriggerTests: XCTestCase {
    private actor RecordingPushNotifier: RemotePushNotifying {
        struct Wake: Equatable {
            let deviceID: String
            let kind: WebPushWakePayload.Kind
            let sessionID: String
            let interactionID: String?
        }

        private var eligibleDevices: Set<String>
        private(set) var wakes: [Wake] = []

        init(eligibleDevices: Set<String>) {
            self.eligibleDevices = eligibleDevices
        }

        func setEligible(_ eligible: Bool, deviceID: String) {
            if eligible {
                eligibleDevices.insert(deviceID)
            } else {
                eligibleDevices.remove(deviceID)
            }
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

    private let device = "remote:aaaa1111"
    private let session = "11111111-1111-1111-1111-111111111111"

    func testDisconnectedDeviceWithWaitingForInputTriggersPush() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running")))
        ])
        let (manager, notifier) = try await makeManager(connection: connection, eligible: true)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        // The wake-worthy transition arrives only AFTER the device disconnected.
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: waitingSnapshot(interactionID: "abcd-1234"))))
        let wakes = await waitForWakes(notifier, minimum: 1)

        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes.first?.deviceID, device)
        XCTAssertEqual(wakes.first?.kind, .waitingForInput)
        XCTAssertEqual(wakes.first?.sessionID, session)
        XCTAssertEqual(wakes.first?.interactionID, "abcd-1234")
    }

    func testConnectedDeviceNeverTriggersPush() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "waiting_for_input")))
        ])
        let (manager, notifier) = try await makeManager(connection: connection, eligible: true)
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: device, sinkID: UUID(), sink: sink, sessionIDs: [session])
        _ = await waitForFrames(sink, containing: "session_update", minimum: 2)
        try await Task.sleep(for: .milliseconds(100))

        let wakes = await notifier.wakes
        XCTAssertTrue(wakes.isEmpty, "A connected device must catch up over WS, never push: \(wakes)")
    }

    func testDisconnectedDeviceTerminalTransitionTriggersSessionTerminalPush() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running")))
        ])
        // This original wake contract predates completed-terminal quarantine; keep
        // it pinned to immediate terminal emission/push by disabling quarantine.
        let (manager, notifier) = try await makeManager(
            connection: connection,
            eligible: true,
            terminalQuarantineSeconds: 0
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "completed"))))
        let wakes = await waitForWakes(notifier, minimum: 1)

        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes.first?.kind, .sessionTerminal)
        XCTAssertNil(wakes.first?.interactionID, "Terminal wakes carry no interaction ID")
    }

    func testDisconnectedDeviceCompletedTerminalQuarantineStillPushesOnceAfterConfirmation() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running")))
        ])
        let (manager, notifier) = try await makeManager(
            connection: connection,
            eligible: true,
            terminalQuarantineSeconds: 0.1
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "completed"))))
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "completed"))))
        let wakes = await waitForWakes(notifier, minimum: 1)

        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes.first?.kind, .sessionTerminal)
        try await Task.sleep(for: .milliseconds(150))
        let finalWakes = await notifier.wakes
        XCTAssertEqual(finalWakes.count, 1, "Quarantine confirmation must not duplicate terminal pushes: \(finalWakes)")
    }

    func testNonWakeWorthyTransitionDoesNotPush() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running")))
        ])
        let (manager, notifier) = try await makeManager(connection: connection, eligible: true)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        try await Task.sleep(for: .milliseconds(200))

        let wakes = await notifier.wakes
        XCTAssertTrue(wakes.isEmpty, "Running-state updates are not wake-worthy: \(wakes)")
    }

    func testIneligibleDisconnectedDeviceStopsWatchingAndNeverPushes() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "waiting_for_input")))
        ])
        let (manager, notifier) = try await makeManager(connection: connection, eligible: false)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        try await Task.sleep(for: .milliseconds(200))

        let wakes = await notifier.wakes
        XCTAssertTrue(wakes.isEmpty, "Devices without a push subscription must never receive wakes: \(wakes)")
    }

    func testSameWakeStateIsNotPushedTwiceUntilRearm() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: session, status: "running")))
        ])
        let (manager, notifier) = try await makeManager(connection: connection, eligible: true)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        await manager.subscribe(deviceID: device, sinkID: sinkID, sink: sink, sessionIDs: [session])
        await manager.removeSink(deviceID: device, sinkID: sinkID)
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: waitingSnapshot(interactionID: nil))))
        _ = await waitForWakes(notifier, minimum: 1)
        // pollCatchUp surfaces the same actionable snapshot again; it must dedupe.
        await connection.enqueue(.result(GatewayTestHelpers.toolResult(json: waitingSnapshot(interactionID: nil))))
        await manager.pollCatchUp(deviceID: device)
        try await Task.sleep(for: .milliseconds(150))

        let wakes = await notifier.wakes
        XCTAssertEqual(wakes.count, 1, "The same wake-worthy state must be pushed at most once: \(wakes)")
    }

    // MARK: - Helpers

    private func waitingSnapshot(interactionID: String?) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string(session),
            "status": .string("waiting_for_input"),
            "updated_at": .string("2026-07-02T00:00:00.000Z")
        ]
        if let interactionID {
            object["interaction_id"] = .string(interactionID)
        }
        return .object(object)
    }

    private func makeManager(
        connection: RecordingAppLinkConnection,
        eligible: Bool,
        terminalQuarantineSeconds: TimeInterval = 5
    ) async throws -> (SessionWatchManager, RecordingPushNotifier) {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let connector = StaticAppLinkConnector(connection: connection)
        let appLink = AppLinkSession(
            config: config,
            connector: connector,
            sleep: { _ in }
        )
        try await appLink.connect()
        let appLinkPool = AppLinkPool(
            configuration: config,
            connector: connector,
            bindingProbe: { _ in .bound }
        )
        _ = try await appLinkPool.ensureLink(forDevice: device)
        let notifier = RecordingPushNotifier(eligibleDevices: eligible ? [device] : [])
        let manager = SessionWatchManager(
            appLink: appLink,
            appLinkPool: appLinkPool,
            pushNotifier: notifier,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2,
            terminalQuarantineSeconds: terminalQuarantineSeconds
        )
        return (manager, notifier)
    }

    private func waitForWakes(
        _ notifier: RecordingPushNotifier,
        minimum: Int,
        timeoutMilliseconds: Int = 2000
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
        minimum: Int = 1,
        timeoutMilliseconds: Int = 1000
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< (timeoutMilliseconds / 20) {
            let frames = await sink.frames
            if frames.count(where: { $0.type == type }) >= minimum { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await sink.frames
    }
}
