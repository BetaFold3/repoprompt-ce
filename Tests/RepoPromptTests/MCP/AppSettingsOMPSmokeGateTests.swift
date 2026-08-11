#if DEBUG
    import Combine
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import RepoPromptShared
    import XCTest

    private final class QualificationWallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock { value }
        }

        func set(_ value: Date) {
            lock.withLock { self.value = value }
        }
    }

    private final class QualificationCancellationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellations: [(OhMyPiAgentModeSmokeGate.Snapshot, String)] = []
        private var publications = 0

        func recordCancellation(_ snapshot: OhMyPiAgentModeSmokeGate.Snapshot, reason: String) {
            lock.withLock { cancellations.append((snapshot, reason)) }
        }

        func recordPublication() {
            lock.withLock { publications += 1 }
        }

        var cancellationRecords: [(OhMyPiAgentModeSmokeGate.Snapshot, String)] {
            lock.withLock { cancellations }
        }

        var publicationCount: Int {
            lock.withLock { publications }
        }
    }

    private actor QualificationTeardownConnection: MCPServerConnection {
        private let deliverySnapshot: MCPResponseDeliverySnapshot?

        init(deliverySnapshot: MCPResponseDeliverySnapshot?) {
            self.deliverySnapshot = deliverySnapshot
        }

        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}

        func stop() async {}

        func abortForExecutionWatchdog() async {}

        func notifyToolListChanged() async {}

        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
            deliverySnapshot
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}

        func sendProgress(tool _: String, kind _: RepoPromptProgressKind, stage _: String, message _: String) async {}
    }

    @MainActor
    final class AppSettingsOMPSmokeGateTests: XCTestCase {
        override func setUp() async throws {
            try await super.setUp()
            await OMPQualificationSharedGateTestIsolation.shared.acquire()
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        }

        override func tearDown() async throws {
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            await OMPQualificationSharedGateTestIsolation.shared.release()
            try await super.tearDown()
        }

        func testExclusiveLeasePublishesAvailabilityAndReleaseRestoresDarkness() async throws {
            let apiSettings = makeAPISettingsViewModel()
            let secondWindowAPISettings = makeAPISettingsViewModel()
            XCTAssertFalse(apiSettings.agentAvailability.ohMyPiAvailable)
            XCTAssertFalse(secondWindowAPISettings.agentAvailability.ohMyPiAvailable)

            let enabled = expectation(description: "availability enabled")
            let disabled = expectation(description: "availability disabled")
            var states: [Bool] = []
            let cancellable = apiSettings.$agentAvailability
                .map(\.ohMyPiAvailable)
                .removeDuplicates()
                .sink { value in
                    states.append(value)
                    if value { enabled.fulfill() }
                    if states.contains(true), !value { disabled.fulfill() }
                }
            let secondCancellable = secondWindowAPISettings.$agentAvailability
                .map(\.ohMyPiAvailable)
                .removeDuplicates()
                .sink { _ in }
            defer {
                cancellable.cancel()
                secondCancellable.cancel()
            }

            let owner = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: owner,
                ownerProcessID: getpid(),
                duration: 60
            )
            await fulfillment(of: [enabled], timeout: 1)
            XCTAssertTrue(apiSettings.agentAvailability.ohMyPiAvailable)
            XCTAssertTrue(secondWindowAPISettings.agentAvailability.ohMyPiAvailable)
            XCTAssertThrowsError(
                try OhMyPiAgentModeSmokeGate.shared.acquire(
                    ownerConnectionID: UUID(),
                    ownerProcessID: getpid(),
                    duration: 60
                )
            ) { error in
                XCTAssertEqual(error as? OhMyPiAgentModeSmokeGate.LeaseError, .alreadyLeased)
            }

            _ = try OhMyPiAgentModeSmokeGate.shared.release(
                leaseID: lease.leaseID,
                ownerProcessID: getpid()
            )
            await fulfillment(of: [disabled], timeout: 1)
            XCTAssertFalse(apiSettings.agentAvailability.ohMyPiAvailable)
            XCTAssertFalse(secondWindowAPISettings.agentAvailability.ohMyPiAvailable)
        }

        func testLeaseExpiresAndFailureCleanupIsFailClosed() async throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let lease = try gate.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: getpid(),
                duration: 0.05
            )
            XCTAssertTrue(gate.isEnabled)
            XCTAssertThrowsError(
                try gate.release(leaseID: lease.leaseID, ownerProcessID: getpid() + 1)
            ) { error in
                XCTAssertEqual(error as? OhMyPiAgentModeSmokeGate.LeaseError, .notOwner)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(gate.isEnabled)
            XCTAssertNil(gate.activeSnapshot())
        }

        func testMonotonicTimerExpiresDespiteWallClockRollback() async throws {
            let clock = QualificationWallClock(Date())
            let recorder = QualificationCancellationRecorder()
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                cancellationHandler: recorder.recordCancellation,
                wallClock: clock.now
            )
            let bound = try bindLease(gate, duration: 0.05)
            clock.set(clock.now().addingTimeInterval(-3600.0))

            try await Task.sleep(for: .milliseconds(150))

            XCTAssertNil(gate.activeSnapshot())
            XCTAssertEqual(recorder.cancellationRecords.map(\.0.leaseID), [bound.leaseID])
            XCTAssertEqual(recorder.cancellationRecords.map(\.1), ["qualification_lease_expired"])
        }

        func testLeaseConsumptionIsOneShotAndConnectionBound() throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let ownerPID = getpid()
            let lease = try gate.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: ownerPID,
                duration: 60
            )
            let startConnection = UUID()
            let sessionID = UUID()
            let runID = UUID()
            XCTAssertFalse(gate.authorizeProviderStart(sessionID: sessionID, runID: runID))
            _ = try gate.consume(
                leaseID: lease.leaseID,
                ownerConnectionID: startConnection,
                ownerProcessID: ownerPID,
                sessionID: sessionID
            )
            XCTAssertTrue(gate.authorizeProviderStart(sessionID: sessionID, runID: runID))
            XCTAssertFalse(gate.authorizeProviderStart(sessionID: sessionID, runID: UUID()))
            XCTAssertFalse(gate.authorizeProviderStart(sessionID: UUID(), runID: UUID()))
            XCTAssertThrowsError(
                try gate.consume(
                    leaseID: lease.leaseID,
                    ownerConnectionID: startConnection,
                    ownerProcessID: ownerPID,
                    sessionID: UUID()
                )
            ) { error in
                XCTAssertEqual(error as? OhMyPiAgentModeSmokeGate.LeaseError, .alreadyConsumed)
            }
            let bound = try gate.bindRun(
                leaseID: lease.leaseID,
                ownerConnectionID: startConnection,
                sessionID: sessionID,
                runID: runID
            )
            XCTAssertEqual(bound.runID, runID)
            XCTAssertFalse(gate.authorizeProviderStart(sessionID: sessionID, runID: UUID()))
            XCTAssertNil(gate.releaseOwned(by: UUID()))
            XCTAssertEqual(gate.releaseOwned(by: startConnection), bound)
            XCTAssertFalse(gate.isEnabled)
        }

        func testNilDeliverySnapshotOnAcquiringConnectionTeardownPreservesLease() async throws {
            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let manager = ServerNetworkManager()
            await manager.test_installQualificationTeardownConnection(
                QualificationTeardownConnection(deliverySnapshot: nil),
                connectionID: connectionID
            )

            await manager.removeConnection(connectionID)

            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), lease)
            XCTAssertNil(lease.sessionID)
            XCTAssertNil(lease.runID)
        }

        func testNilDeliverySnapshotOnBoundStartConnectionTeardownPreservesRunLease() async throws {
            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: getpid(),
                duration: 60
            )
            let sessionID = UUID()
            let runID = UUID()
            _ = try OhMyPiAgentModeSmokeGate.shared.consume(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            let bound = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                sessionID: sessionID,
                runID: runID
            )
            let manager = ServerNetworkManager()
            await manager.test_installQualificationTeardownConnection(
                QualificationTeardownConnection(deliverySnapshot: nil),
                connectionID: connectionID
            )

            await manager.removeConnection(connectionID)

            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), bound)
            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot()?.runID, runID)
        }

        func testIncompleteDeliverySnapshotOnBoundConnectionTeardownReleasesLease() async throws {
            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: getpid(),
                duration: 60
            )
            let sessionID = UUID()
            _ = try OhMyPiAgentModeSmokeGate.shared.consume(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            _ = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                sessionID: sessionID,
                runID: UUID()
            )
            let delivery = MCPResponseDeliverySnapshot(
                pendingRequestCount: 1,
                waiterCount: 0,
                isTerminal: true
            )
            let manager = ServerNetworkManager()
            await manager.test_installQualificationTeardownConnection(
                QualificationTeardownConnection(deliverySnapshot: delivery),
                connectionID: connectionID
            )

            await manager.removeConnection(connectionID)

            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
        }

        func testAcquiringConnectionCanReleaseUnconsumedLeaseOnIncompleteTeardown() throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let ownerConnectionID = UUID()
            let lease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )

            XCTAssertNil(lease.sessionID)
            XCTAssertNil(lease.runID)
            XCTAssertEqual(gate.releaseOwned(by: ownerConnectionID), lease)
            XCTAssertNil(gate.activeSnapshot())
        }

        func testRealTimerExpiryCancelsCurrentBoundRunExactlyOnce() async throws {
            let recorder = QualificationCancellationRecorder()
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                cancellationHandler: recorder.recordCancellation
            )
            let bound = try bindLease(gate, duration: 0.05)

            try await Task.sleep(for: .milliseconds(150))

            XCTAssertNil(gate.activeSnapshot())
            XCTAssertEqual(recorder.cancellationRecords.count, 1)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.leaseID, bound.leaseID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.sessionID, bound.sessionID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.runID, bound.runID)
            XCTAssertEqual(recorder.cancellationRecords.first?.1, "qualification_lease_expired")
        }

        func testSynchronousExpiryObservationPublishesAndCancelsBoundRunExactlyOnce() throws {
            let notificationCenter = NotificationCenter()
            let recorder = QualificationCancellationRecorder()
            let observer = notificationCenter.addObserver(
                forName: .ohMyPiQualificationLeaseDidChange,
                object: nil,
                queue: nil
            ) { _ in
                recorder.recordPublication()
            }
            defer { notificationCenter.removeObserver(observer) }
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: notificationCenter,
                cancellationHandler: recorder.recordCancellation
            )
            let bound = try bindLease(gate)
            let publicationsBeforeExpiry = recorder.publicationCount

            gate.forceExpiryForTesting()
            XCTAssertNil(gate.activeSnapshot())
            XCTAssertNil(gate.activeSnapshot())

            XCTAssertEqual(recorder.publicationCount, publicationsBeforeExpiry + 1)
            XCTAssertEqual(recorder.cancellationRecords.count, 1)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.leaseID, bound.leaseID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.sessionID, bound.sessionID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.runID, bound.runID)
            XCTAssertEqual(recorder.cancellationRecords.first?.1, "qualification_lease_expired")
        }

        func testReacquisitionPublishesAndCancelsExpiredBoundRunExactlyOnce() throws {
            let notificationCenter = NotificationCenter()
            let recorder = QualificationCancellationRecorder()
            let observer = notificationCenter.addObserver(
                forName: .ohMyPiQualificationLeaseDidChange,
                object: nil,
                queue: nil
            ) { _ in
                recorder.recordPublication()
            }
            defer { notificationCenter.removeObserver(observer) }
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: notificationCenter,
                cancellationHandler: recorder.recordCancellation
            )
            let expired = try bindLease(gate)
            let publicationsBeforeReacquisition = recorder.publicationCount
            gate.forceExpiryForTesting()

            let replacement = try gate.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: getpid(),
                duration: 60
            )

            XCTAssertNotEqual(replacement.leaseID, expired.leaseID)
            XCTAssertEqual(gate.activeSnapshot(), replacement)
            XCTAssertEqual(recorder.publicationCount, publicationsBeforeReacquisition + 1)
            XCTAssertEqual(recorder.cancellationRecords.count, 1)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.leaseID, expired.leaseID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.sessionID, expired.sessionID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.runID, expired.runID)
            XCTAssertEqual(recorder.cancellationRecords.first?.1, "qualification_lease_expired")
        }

        func testCurrentExecutableIdentityRejectsExecImageChangeWithSameProcessStartIdentity() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPExecutableIdentityTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let launched = root.appendingPathComponent("launched")
            let replacement = root.appendingPathComponent("replacement")
            try "#!/bin/sh\nexit 0\n".write(to: launched, atomically: true, encoding: .utf8)
            try "#!/bin/sh\nexit 1\n".write(to: replacement, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launched.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
            let launchIdentity = try ExecutableFileIdentity.capture(atPath: launched.path)

            XCTAssertTrue(ServerNetworkManager.debugProcessIdentityMatches(
                expectedStartSeconds: 100,
                expectedStartMicroseconds: 200,
                expectedExecutableIdentity: launchIdentity,
                currentStartSeconds: 100,
                currentStartMicroseconds: 200,
                currentExecutablePath: launched.path
            ))
            XCTAssertFalse(ServerNetworkManager.debugProcessIdentityMatches(
                expectedStartSeconds: 100,
                expectedStartMicroseconds: 200,
                expectedExecutableIdentity: launchIdentity,
                currentStartSeconds: 100,
                currentStartMicroseconds: 200,
                currentExecutablePath: replacement.path
            ))
        }

        private func bindLease(
            _ gate: OhMyPiAgentModeSmokeGate,
            duration: TimeInterval = 60
        ) throws -> OhMyPiAgentModeSmokeGate.Snapshot {
            let ownerPID = getpid()
            let lease = try gate.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: ownerPID,
                duration: duration
            )
            let connectionID = UUID()
            let sessionID = UUID()
            _ = try gate.consume(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: ownerPID,
                sessionID: sessionID
            )
            return try gate.bindRun(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                sessionID: sessionID,
                runID: UUID()
            )
        }

        private func makeAPISettingsViewModel() -> APISettingsViewModel {
            let secureService = SecureKeysService(
                secureStorage: TestSecureStorageBackend(values: [:])
            )
            let keyManager = KeyManager(secureService: secureService)
            return APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
        }
    }
#endif
