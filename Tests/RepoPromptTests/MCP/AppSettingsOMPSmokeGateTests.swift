#if DEBUG
    import Combine
    import Foundation
    import MCP
    @testable import RepoPromptApp
    import RepoPromptShared
    import XCTest

    private final class QualificationMonotonicClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64

        init(_ value: UInt64) {
            self.value = value
        }

        func now() -> UInt64 {
            lock.withLock { value }
        }

        func set(_ value: UInt64) {
            lock.withLock { self.value = value }
        }
    }

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

        func testAuthorizationReceiptSupportsMultipleWaiters() async {
            let receipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt()
            async let first = receipt.wait()
            async let second = receipt.wait()
            await Task.yield()
            receipt.resolve(.denied)
            let outcomes = await (first, second)
            XCTAssertEqual(outcomes.0, .denied)
            XCTAssertEqual(outcomes.1, .denied)
        }

        func testAuthorizationReceiptCancellationResolvesDenial() async {
            let receipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt()
            let waiter = Task { await receipt.wait() }
            await Task.yield()
            waiter.cancel()
            let outcome = await waiter.value
            XCTAssertEqual(outcome, .denied)
        }

        func testAuthorizationReceiptReturnsEffectiveOutcomeAfterPriorDenial() {
            let receipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt()
            let authorized = OhMyPiAgentModeSmokeGate.AuthorizedRunReceipt(
                runID: UUID(),
                activeAgentSessionID: UUID(),
                runAttemptID: UUID()
            )

            XCTAssertEqual(receipt.resolve(.denied), .denied)
            XCTAssertEqual(receipt.resolve(.authorized(authorized)), .denied)
        }

        func testAuthorizationReceiptRejectsAuthorizationAtAbsoluteDeadline() {
            let permittedReceipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt(
                authorizationDeadlineUptimeNanoseconds: 100,
                monotonicNowNanoseconds: { 99 }
            )
            XCTAssertTrue(permittedReceipt.authorizationStillPermitted)
            let receipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt(
                authorizationDeadlineUptimeNanoseconds: 100,
                monotonicNowNanoseconds: { 100 }
            )
            XCTAssertFalse(receipt.authorizationStillPermitted)

            let proposed = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome.authorized(.init(
                runID: UUID(),
                activeAgentSessionID: nil,
                runAttemptID: nil
            ))
            XCTAssertEqual(receipt.resolve(proposed), .denied)
            XCTAssertEqual(receipt.resolve(.authorized(.init(
                runID: UUID(),
                activeAgentSessionID: nil,
                runAttemptID: nil
            ))), .denied, "Denial must remain the one-shot winner")
        }

        func testInvocationStartContextTaskLocalVisibilityIsScoped() async throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let ownerConnectionID = UUID()
            let ownerProcessID = getpid()
            let lease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: ownerProcessID,
                duration: 60
            )
            let consumption = try gate.consumeStartTransaction(
                leaseID: lease.leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: ownerProcessID,
                sessionID: UUID()
            )
            let context = OhMyPiAgentModeSmokeGate.StartContext(
                transaction: consumption.transaction,
                expectedWorkspaceID: UUID()
            )

            XCTAssertNil(OhMyPiAgentModeSmokeGate.invocationStartContext)
            await OhMyPiAgentModeSmokeGate.$invocationStartContext.withValue(context) {
                XCTAssertTrue(OhMyPiAgentModeSmokeGate.invocationStartContext === context)
                await Task.yield()
                XCTAssertTrue(OhMyPiAgentModeSmokeGate.invocationStartContext === context)
            }
            XCTAssertNil(OhMyPiAgentModeSmokeGate.invocationStartContext)
        }

        func testAuthorizationReceiptWaiterCancellationIsLocal() async {
            let receipt = OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt()
            let cancelledWaiter = Task { await receipt.wait() }
            await Task.yield()
            cancelledWaiter.cancel()
            let cancelledOutcome = await cancelledWaiter.value
            XCTAssertEqual(cancelledOutcome, .denied)

            let authorized = OhMyPiAgentModeSmokeGate.AuthorizedRunReceipt(
                runID: UUID(),
                activeAgentSessionID: UUID(),
                runAttemptID: UUID()
            )
            XCTAssertEqual(receipt.resolve(.authorized(authorized)), .authorized(authorized))
            let observedOutcome = await receipt.wait()
            XCTAssertEqual(observedOutcome, .authorized(authorized))
        }

        func testOhMyPiConnectionPublishesWindowAvailabilityWithoutQualificationLease() async {
            let apiSettings = makeAPISettingsViewModel()
            XCTAssertFalse(apiSettings.agentModeAvailabilityContext.ohMyPiAvailable)

            let enabled = expectation(description: "connection availability enabled")
            let cancellable = apiSettings.$agentAvailability
                .map(\.ohMyPiAvailable)
                .removeDuplicates()
                .sink { value in
                    if value { enabled.fulfill() }
                }
            defer { cancellable.cancel() }

            apiSettings.isOhMyPiConnected = true
            await fulfillment(of: [enabled], timeout: 1)

            XCTAssertTrue(apiSettings.agentModeAvailabilityContext.ohMyPiAvailable)
            XCTAssertTrue(apiSettings.agentAvailability.ohMyPiAvailable)
            XCTAssertTrue(AgentModelCatalog.selectableAgents(
                availability: apiSettings.agentModeAvailabilityContext
            ).contains(.ohMyPi))
            XCTAssertTrue(AgentModelCatalog.discoveryAgents(
                availability: apiSettings.agentModeAvailabilityContext
            ).contains { $0.agent == .ohMyPi })
        }

        func testExclusiveLeasePublishesAvailabilityAndReleaseRestoresConnectionGatedState() async throws {
            let apiSettings = makeAPISettingsViewModel()
            let secondWindowAPISettings = makeAPISettingsViewModel()
            XCTAssertFalse(apiSettings.agentAvailability.ohMyPiAvailable)
            XCTAssertFalse(secondWindowAPISettings.agentAvailability.ohMyPiAvailable)
            XCTAssertFalse(apiSettings.isContextBuilderProviderRuntimeReady(.ohMyPi))
            XCTAssertFalse(secondWindowAPISettings.isContextBuilderProviderRuntimeReady(.ohMyPi))

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
            XCTAssertTrue(apiSettings.isContextBuilderProviderRuntimeReady(.ohMyPi))
            XCTAssertTrue(secondWindowAPISettings.isContextBuilderProviderRuntimeReady(.ohMyPi))
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
            XCTAssertFalse(apiSettings.isContextBuilderProviderRuntimeReady(.ohMyPi))
            XCTAssertFalse(secondWindowAPISettings.isContextBuilderProviderRuntimeReady(.ohMyPi))
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

        func testProviderStartAuthorizationDecisionNamesRefusalBranches() throws {
            let noLeaseGate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let sourceGate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let ownerProcessID = getpid()
            let connectionID = UUID()
            let sessionID = UUID()
            let sourceLease = try sourceGate.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                duration: 60
            )
            let sourceConsumption = try sourceGate.consumeStartTransaction(
                leaseID: sourceLease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                sessionID: sessionID
            )
            XCTAssertEqual(
                noLeaseGate.providerStartAuthorizationDecision(
                    transaction: sourceConsumption.transaction,
                    runID: UUID()
                ),
                .refused(reason: "gate_refusal_no_lease")
            )

            let replacementLease = try noLeaseGate.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                duration: 60
            )
            _ = try noLeaseGate.consumeStartTransaction(
                leaseID: replacementLease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                sessionID: sessionID
            )
            XCTAssertEqual(
                noLeaseGate.providerStartAuthorizationDecision(
                    transaction: sourceConsumption.transaction,
                    runID: UUID()
                ),
                .refused(reason: "gate_refusal_transaction_id_mismatch")
            )

            let runID = UUID()
            XCTAssertEqual(
                sourceGate.providerStartAuthorizationDecision(
                    transaction: sourceConsumption.transaction,
                    runID: runID
                ),
                .authorized
            )
            XCTAssertEqual(
                sourceGate.providerStartAuthorizationDecision(
                    transaction: sourceConsumption.transaction,
                    runID: UUID()
                ),
                .refused(reason: "gate_refusal_run_already_assigned")
            )

            let monotonicClock = QualificationMonotonicClock(0)
            let expiredGate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                monotonicNowNanoseconds: monotonicClock.now
            )
            let expiredLease = try expiredGate.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                duration: 1
            )
            let expiredConsumption = try expiredGate.consumeStartTransaction(
                leaseID: expiredLease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: ownerProcessID,
                sessionID: sessionID
            )
            monotonicClock.set(1_000_000_000)
            XCTAssertEqual(
                expiredGate.providerStartAuthorizationDecision(
                    transaction: expiredConsumption.transaction,
                    runID: UUID()
                ),
                .refused(reason: "gate_refusal_expired")
            )
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
            let consumption = try gate.consumeStartTransaction(
                leaseID: lease.leaseID,
                ownerConnectionID: startConnection,
                ownerProcessID: ownerPID,
                sessionID: sessionID
            )
            XCTAssertTrue(gate.authorizeProviderStart(transaction: consumption.transaction, runID: runID))
            XCTAssertFalse(gate.authorizeProviderStart(transaction: consumption.transaction, runID: UUID()))
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
            XCTAssertFalse(gate.authorizeProviderStart(transaction: consumption.transaction, runID: UUID()))
            XCTAssertNil(gate.releaseOwned(by: UUID()))
            XCTAssertEqual(gate.releaseOwned(by: startConnection), bound)
            XCTAssertFalse(gate.isEnabled)
        }

        func testApplyEditsReviewPermissionIsOptInWorkspaceAndRunBound() throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let connectionID = UUID()
            let sessionID = UUID()
            let workspaceID = UUID()
            let runID = UUID()
            let lease = try gate.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let consumption = try gate.consumeStartTransaction(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID,
                qualificationWorkspaceID: workspaceID,
                permitsApplyEditsReview: true
            )

            XCTAssertTrue(gate.permitsApplyEditsReviewActivation(
                transaction: consumption.transaction,
                workspaceID: workspaceID
            ))
            XCTAssertFalse(gate.permitsApplyEditsReviewActivation(
                transaction: consumption.transaction,
                workspaceID: UUID()
            ))
            XCTAssertTrue(gate.authorizeProviderStart(transaction: consumption.transaction, runID: runID))
            _ = try gate.bindRun(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                sessionID: sessionID,
                runID: runID
            )
            XCTAssertFalse(gate.permitsApplyEditsReviewActivation(
                transaction: consumption.transaction,
                workspaceID: workspaceID
            ))
            XCTAssertTrue(gate.permitsApplyEditsReviewResponse(
                sessionID: sessionID,
                runID: runID,
                workspaceID: workspaceID
            ))
            XCTAssertFalse(gate.permitsApplyEditsReviewResponse(
                sessionID: sessionID,
                runID: UUID(),
                workspaceID: workspaceID
            ))
            XCTAssertFalse(gate.permitsApplyEditsReviewResponse(
                sessionID: sessionID,
                runID: runID,
                workspaceID: UUID()
            ))
            XCTAssertEqual(gate.releaseOwned(by: connectionID)?.runID, runID)
            XCTAssertFalse(gate.permitsApplyEditsReviewResponse(
                sessionID: sessionID,
                runID: runID,
                workspaceID: workspaceID
            ))
        }

        func testApplyEditsReviewPermissionDefaultsOff() throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let connectionID = UUID()
            let sessionID = UUID()
            let workspaceID = UUID()
            let lease = try gate.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let consumption = try gate.consumeStartTransaction(
                leaseID: lease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            XCTAssertFalse(gate.permitsApplyEditsReviewActivation(
                transaction: consumption.transaction,
                workspaceID: workspaceID
            ))
        }

        func testConcurrentStartLoserRollbackCannotReleaseOrCancelWinner() throws {
            let recorder = QualificationCancellationRecorder()
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                cancellationHandler: recorder.recordCancellation
            )
            let ownerProcessID = getpid()
            let initial = try gate.acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: ownerProcessID,
                duration: 60
            )
            let loserSnapshot = try XCTUnwrap(gate.activeSnapshot())
            let winnerConnectionID = UUID()
            let winnerSessionID = UUID()
            let winnerRunID = UUID()
            let winnerConsumption = try gate.consumeStartTransaction(
                leaseID: initial.leaseID,
                ownerConnectionID: winnerConnectionID,
                ownerProcessID: ownerProcessID,
                sessionID: winnerSessionID
            )
            XCTAssertTrue(gate.authorizeProviderStart(transaction: winnerConsumption.transaction, runID: winnerRunID))
            let winner = try gate.bindRun(
                leaseID: initial.leaseID,
                ownerConnectionID: winnerConnectionID,
                sessionID: winnerSessionID,
                runID: winnerRunID
            )

            XCTAssertNil(gate.rollbackStartTransaction(ifCurrent: loserSnapshot))
            XCTAssertEqual(gate.activeSnapshot(), winner)
            XCTAssertTrue(recorder.cancellationRecords.isEmpty)
        }

        func testConsumedTransactionRollbackCancelsAuthorizedExactRun() throws {
            let recorder = QualificationCancellationRecorder()
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                cancellationHandler: recorder.recordCancellation
            )
            let ownerConnectionID = UUID()
            let lease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let sessionID = UUID()
            let runID = UUID()
            let consumption = try gate.consumeStartTransaction(
                leaseID: lease.leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            XCTAssertTrue(gate.authorizeProviderStart(transaction: consumption.transaction, runID: runID))

            let released = try XCTUnwrap(
                gate.rollbackConsumedStartTransaction(consumption.transaction)
            )
            XCTAssertEqual(released.sessionID, sessionID)
            XCTAssertEqual(released.runID, runID)
            XCTAssertNil(gate.activeSnapshot())
            XCTAssertEqual(recorder.cancellationRecords.count, 1)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.sessionID, sessionID)
            XCTAssertEqual(recorder.cancellationRecords.first?.0.runID, runID)
            XCTAssertEqual(
                recorder.cancellationRecords.first?.1,
                "qualification_consumed_start_rollback"
            )
        }

        func testOldStartRollbackCannotReleaseReacquiredSameConnectionLease() throws {
            let recorder = QualificationCancellationRecorder()
            let gate = OhMyPiAgentModeSmokeGate(
                notificationCenter: NotificationCenter(),
                cancellationHandler: recorder.recordCancellation
            )
            let ownerConnectionID = UUID()
            let old = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            gate.forceExpiryForTesting()
            XCTAssertNil(gate.activeSnapshot())
            let replacementLease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let replacementSessionID = UUID()
            let replacementRunID = UUID()
            let replacementConsumption = try gate.consumeStartTransaction(
                leaseID: replacementLease.leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                sessionID: replacementSessionID
            )
            XCTAssertTrue(
                gate.authorizeProviderStart(
                    transaction: replacementConsumption.transaction,
                    runID: replacementRunID
                )
            )
            let replacement = try XCTUnwrap(gate.activeSnapshot())

            XCTAssertNil(gate.rollbackStartTransaction(ifCurrent: old))
            XCTAssertEqual(gate.activeSnapshot(), replacement)
            XCTAssertEqual(recorder.cancellationRecords.map(\.0.leaseID), [])
        }

        func testStaleTransactionCannotAuthorizeReacquiredSameSessionLease() throws {
            let gate = OhMyPiAgentModeSmokeGate(notificationCenter: NotificationCenter())
            let ownerConnectionID = UUID()
            let sessionID = UUID()
            let oldLease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let oldConsumption = try gate.consumeStartTransaction(
                leaseID: oldLease.leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            gate.forceExpiryForTesting()
            XCTAssertNil(gate.activeSnapshot())

            let replacementLease = try gate.acquire(
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let replacementConsumption = try gate.consumeStartTransaction(
                leaseID: replacementLease.leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            let replacementRunID = UUID()

            XCTAssertFalse(
                gate.authorizeProviderStart(
                    transaction: oldConsumption.transaction,
                    runID: UUID()
                )
            )
            XCTAssertTrue(
                gate.authorizeProviderStart(
                    transaction: replacementConsumption.transaction,
                    runID: replacementRunID
                )
            )
            XCTAssertEqual(gate.activeSnapshot()?.runID, replacementRunID)
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

        func testRegisterExpectedAgentPIDLiveSamplesExecutableIdentityWhenNotSupplied() async throws {
            let manager = ServerNetworkManager.shared
            let runID = UUID()
            let clientName = "omp-registration-live-sample-\(runID.uuidString)"
            let pid = getpid()
            await manager.registerExpectedAgentPID(pid, for: clientName, runID: runID)
            addTeardownBlock {
                await manager.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            }

            let recordedSnapshot = await manager.debugExpectedProcessIdentity(runID: runID, pid: pid)
            let recorded = try XCTUnwrap(recordedSnapshot)
            let executablePath = try XCTUnwrap(recorded.executablePath)

            XCTAssertEqual(
                recorded.executableIdentity,
                try ExecutableFileIdentity.capture(atPath: executablePath)
            )
        }

        func testSuppliedExpectedProcessIdentityMatchesPostExecImageInsteadOfTransientEnv() async throws {
            let manager = ServerNetworkManager.shared
            let pid = getpid()
            let sampleRunID = UUID()
            let sampleClientName = "omp-registration-sample-\(sampleRunID.uuidString)"
            await manager.registerExpectedAgentPID(pid, for: sampleClientName, runID: sampleRunID)
            let liveSampleSnapshot = await manager.debugExpectedProcessIdentity(runID: sampleRunID, pid: pid)
            let liveSample = try XCTUnwrap(liveSampleSnapshot)
            await manager.clearExpectedAgentPID(pid, for: sampleClientName, runID: sampleRunID)

            let livePath = try XCTUnwrap(liveSample.executablePath)
            let liveIdentity = try XCTUnwrap(liveSample.executableIdentity)
            let suppliedIdentity = try ExecutableFileIdentity.capture(atPath: "/usr/bin/env")
            XCTAssertNotEqual(liveIdentity, suppliedIdentity)

            let runID = UUID()
            let clientName = "omp-registration-supplied-\(runID.uuidString)"
            await manager.registerExpectedAgentPID(
                pid,
                for: clientName,
                runID: runID,
                expectedProcessExecutablePath: suppliedIdentity.canonicalPath,
                expectedProcessExecutableIdentity: suppliedIdentity
            )
            addTeardownBlock {
                await manager.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            }
            let recordedSnapshot = await manager.debugExpectedProcessIdentity(runID: runID, pid: pid)
            let recorded = try XCTUnwrap(recordedSnapshot)

            XCTAssertEqual(recorded.executablePath, suppliedIdentity.canonicalPath)
            XCTAssertEqual(recorded.executableIdentity, suppliedIdentity)
            XCTAssertNotEqual(recorded.executableIdentity, liveIdentity)
            XCTAssertFalse(ServerNetworkManager.debugProcessIdentityMatches(
                expectedStartSeconds: recorded.startSeconds,
                expectedStartMicroseconds: recorded.startMicroseconds,
                expectedExecutableIdentity: recorded.executableIdentity,
                currentStartSeconds: recorded.startSeconds,
                currentStartMicroseconds: recorded.startMicroseconds,
                currentExecutablePath: livePath
            ))

            let malformedPairs: [(String, String?, ExecutableFileIdentity?)] = [
                ("path-only", suppliedIdentity.canonicalPath, nil),
                ("identity-only", nil, suppliedIdentity),
                ("mismatched", livePath, suppliedIdentity)
            ]
            for (label, path, identity) in malformedPairs {
                let malformedRunID = UUID()
                let malformedClientName = "omp-registration-malformed-\(label)-\(malformedRunID.uuidString)"
                await manager.registerExpectedAgentPID(
                    pid,
                    for: malformedClientName,
                    runID: malformedRunID,
                    expectedProcessExecutablePath: path,
                    expectedProcessExecutableIdentity: identity
                )
                let malformedSnapshot = await manager.debugExpectedProcessIdentity(
                    runID: malformedRunID,
                    pid: pid
                )
                let malformed = try XCTUnwrap(malformedSnapshot)
                await manager.clearExpectedAgentPID(
                    pid,
                    for: malformedClientName,
                    runID: malformedRunID
                )

                XCTAssertNil(malformed.executablePath, label)
                XCTAssertNil(malformed.executableIdentity, label)
                XCTAssertFalse(ServerNetworkManager.debugProcessIdentityMatches(
                    expectedStartSeconds: malformed.startSeconds,
                    expectedStartMicroseconds: malformed.startMicroseconds,
                    expectedExecutableIdentity: malformed.executableIdentity,
                    currentStartSeconds: malformed.startSeconds,
                    currentStartMicroseconds: malformed.startMicroseconds,
                    currentExecutablePath: livePath
                ), label)
            }
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
