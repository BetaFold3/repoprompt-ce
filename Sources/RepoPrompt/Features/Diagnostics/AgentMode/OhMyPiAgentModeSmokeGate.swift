#if DEBUG
    import Foundation

    extension Notification.Name {
        static let ohMyPiQualificationLeaseDidChange = Notification.Name(
            "RepoPrompt.OhMyPiQualificationLeaseDidChange"
        )
    }

    final class OhMyPiAgentModeSmokeGate: @unchecked Sendable {
        struct Snapshot: Equatable {
            let leaseID: UUID
            let ownerConnectionID: UUID
            let ownerProcessID: Int32
            let ownerProcessStartSeconds: Int64
            let ownerProcessStartMicroseconds: Int32
            let expiresAt: Date
            let sessionID: UUID?
            let runID: UUID?
        }

        struct StartTransaction: Equatable {
            fileprivate let transactionID: UUID
            let leaseID: UUID
            let ownerConnectionID: UUID
            let sessionID: UUID
        }

        struct AuthorizedRunReceipt: Equatable {
            let runID: UUID
            let activeAgentSessionID: UUID?
            let runAttemptID: UUID?
        }

        final class StartAuthorizationReceipt: @unchecked Sendable {
            enum Outcome: Equatable {
                case authorized(AuthorizedRunReceipt)
                case denied
            }

            private let lock = NSLock()
            private let authorizationDeadlineUptimeNanoseconds: UInt64?
            private let monotonicNowNanoseconds: @Sendable () -> UInt64
            private var outcome: Outcome?
            private var startupFailureReason: String?
            private var continuations: [UUID: CheckedContinuation<Outcome, Never>] = [:]

            init(
                authorizationDeadlineUptimeNanoseconds: UInt64? = nil,
                monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = {
                    DispatchTime.now().uptimeNanoseconds
                }
            ) {
                self.authorizationDeadlineUptimeNanoseconds = authorizationDeadlineUptimeNanoseconds
                self.monotonicNowNanoseconds = monotonicNowNanoseconds
            }

            var authorizationStillPermitted: Bool {
                lock.withLock {
                    if let outcome {
                        if case .authorized = outcome { return true }
                        return false
                    }
                    guard let authorizationDeadlineUptimeNanoseconds else { return true }
                    return monotonicNowNanoseconds() < authorizationDeadlineUptimeNanoseconds
                }
            }

            @discardableResult
            func resolve(
                _ proposedOutcome: Outcome,
                startupFailureReason proposedStartupFailureReason: String? = nil
            ) -> Outcome {
                let resolution = lock.withLock { () -> (
                    effective: Outcome,
                    continuations: [CheckedContinuation<Outcome, Never>]
                ) in
                    if let outcome {
                        return (outcome, [])
                    }
                    let authorizationDeadlineExceeded: Bool = if case .authorized = proposedOutcome,
                                                                 let authorizationDeadlineUptimeNanoseconds
                    {
                        monotonicNowNanoseconds() >= authorizationDeadlineUptimeNanoseconds
                    } else {
                        false
                    }
                    let effectiveProposal: Outcome = authorizationDeadlineExceeded ? .denied : proposedOutcome
                    outcome = effectiveProposal
                    if case .denied = effectiveProposal {
                        startupFailureReason = authorizationDeadlineExceeded
                            ? "authorization_deadline_exceeded"
                            : proposedStartupFailureReason
                    }
                    let continuations = Array(self.continuations.values)
                    self.continuations.removeAll()
                    return (effectiveProposal, continuations)
                }
                for continuation in resolution.continuations {
                    continuation.resume(returning: resolution.effective)
                }
                return resolution.effective
            }

            func wait() async -> Outcome {
                if let outcome = lock.withLock({ outcome }) {
                    return outcome
                }
                let waiterID = UUID()
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let resolved = lock.withLock { () -> Outcome? in
                            if let outcome { return outcome }
                            if Task.isCancelled { return .denied }
                            continuations[waiterID] = continuation
                            return nil
                        }
                        if let resolved {
                            continuation.resume(returning: resolved)
                        }
                    }
                } onCancel: {
                    let continuation = self.lock.withLock {
                        self.continuations.removeValue(forKey: waiterID)
                    }
                    continuation?.resume(returning: .denied)
                }
            }

            var resolvedOutcome: Outcome? {
                lock.withLock { outcome }
            }

            var resolvedStartupFailureReason: String? {
                lock.withLock { startupFailureReason }
            }

            func wait(timeoutNanoseconds: UInt64) async -> Outcome? {
                await withTaskGroup(of: Outcome?.self) { group in
                    group.addTask { await self.wait() }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        return nil
                    }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    return result
                }
            }
        }

        final class StartContext: @unchecked Sendable {
            let transaction: StartTransaction
            let generationID: UUID
            let expectedWorkspaceID: UUID
            let authorizationReceipt: StartAuthorizationReceipt

            init(
                transaction: StartTransaction,
                expectedWorkspaceID: UUID,
                authorizationDeadlineUptimeNanoseconds: UInt64? = nil
            ) {
                self.transaction = transaction
                generationID = transaction.transactionID
                self.expectedWorkspaceID = expectedWorkspaceID
                authorizationReceipt = StartAuthorizationReceipt(
                    authorizationDeadlineUptimeNanoseconds: authorizationDeadlineUptimeNanoseconds
                )
            }
        }

        struct Consumption {
            let snapshot: Snapshot
            let transaction: StartTransaction
        }

        enum ProviderStartAuthorizationDecision: Equatable {
            case authorized
            case refused(reason: String)

            var isAuthorized: Bool {
                self == .authorized
            }

            var refusalReason: String? {
                guard case let .refused(reason) = self else { return nil }
                return reason
            }
        }

        enum LeaseError: Error, Equatable {
            case alreadyLeased
            case invalidDuration
            case notOwner
            case expired
            case alreadyConsumed
        }

        static let shared = OhMyPiAgentModeSmokeGate()
        static let maximumDuration: TimeInterval = 600
        @TaskLocal static var invocationStartContext: StartContext?

        private struct StoredLease {
            var snapshot: Snapshot
            let monotonicDeadlineNanoseconds: UInt64
            var startTransactionID: UUID?
        }

        private let lock = NSLock()
        private let notificationCenter: NotificationCenter
        private let cancellationHandler: (@Sendable (Snapshot, String) -> Void)?
        private let wallClock: @Sendable () -> Date
        private let monotonicNowNanoseconds: @Sendable () -> UInt64
        private var lease: StoredLease?
        private var expiryGeneration: UInt64 = 0

        init(
            notificationCenter: NotificationCenter = .default,
            cancellationHandler: (@Sendable (Snapshot, String) -> Void)? = nil,
            wallClock: @escaping @Sendable () -> Date = Date.init,
            monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        ) {
            self.notificationCenter = notificationCenter
            self.cancellationHandler = cancellationHandler
            self.wallClock = wallClock
            self.monotonicNowNanoseconds = monotonicNowNanoseconds
        }

        var isEnabled: Bool {
            activeSnapshot() != nil
        }

        func activeSnapshot() -> Snapshot? {
            let now = monotonicNowNanoseconds()
            let result = lock.withLock { () -> (active: Snapshot?, expired: Snapshot?) in
                guard let lease else { return (nil, nil) }
                guard now < lease.monotonicDeadlineNanoseconds else {
                    self.lease = nil
                    expiryGeneration &+= 1
                    return (nil, lease.snapshot)
                }
                return (lease.snapshot, nil)
            }
            if let expired = result.expired {
                completeExpiredRemoval(expired)
            }
            return result.active
        }

        func acquire(
            ownerConnectionID: UUID,
            ownerProcessID: Int32,
            ownerProcessStartSeconds: Int64 = 0,
            ownerProcessStartMicroseconds: Int32 = 0,
            duration: TimeInterval
        ) throws -> Snapshot {
            guard duration > 0, duration <= Self.maximumDuration else {
                throw LeaseError.invalidDuration
            }
            let now = wallClock()
            let monotonicNow = monotonicNowNanoseconds()
            let durationNanoseconds = UInt64((duration * 1_000_000_000).rounded(.up))
            let deadline = monotonicNow.addingReportingOverflow(durationNanoseconds)
            guard !deadline.overflow else { throw LeaseError.invalidDuration }
            let result = try lock.withLock { () throws -> (acquired: Snapshot, expired: Snapshot?, generation: UInt64) in
                if let current = lease, monotonicNow < current.monotonicDeadlineNanoseconds {
                    throw LeaseError.alreadyLeased
                }
                let expired = lease?.snapshot
                let snapshot = Snapshot(
                    leaseID: UUID(),
                    ownerConnectionID: ownerConnectionID,
                    ownerProcessID: ownerProcessID,
                    ownerProcessStartSeconds: ownerProcessStartSeconds,
                    ownerProcessStartMicroseconds: ownerProcessStartMicroseconds,
                    expiresAt: now.addingTimeInterval(duration),
                    sessionID: nil,
                    runID: nil
                )
                lease = StoredLease(
                    snapshot: snapshot,
                    monotonicDeadlineNanoseconds: deadline.partialValue,
                    startTransactionID: nil
                )
                expiryGeneration &+= 1
                return (snapshot, expired, expiryGeneration)
            }
            scheduleExpiry(
                for: result.acquired,
                monotonicDeadlineNanoseconds: deadline.partialValue,
                generation: result.generation
            )
            if let expired = result.expired {
                completeExpiredRemoval(expired)
            } else {
                publishChange()
            }
            return result.acquired
        }

        func providerStartAuthorizationDecision(
            transaction: StartTransaction,
            runID: UUID
        ) -> ProviderStartAuthorizationDecision {
            let now = monotonicNowNanoseconds()
            let outcome = lock.withLock { () -> (
                decision: ProviderStartAuthorizationDecision,
                expired: Snapshot?
            ) in
                guard var stored = lease else {
                    return (.refused(reason: "gate_refusal_no_lease"), nil)
                }
                guard now < stored.monotonicDeadlineNanoseconds else {
                    lease = nil
                    expiryGeneration &+= 1
                    return (.refused(reason: "gate_refusal_expired"), stored.snapshot)
                }
                let current = stored.snapshot
                guard stored.startTransactionID == transaction.transactionID else {
                    return (.refused(reason: "gate_refusal_transaction_id_mismatch"), nil)
                }
                guard current.leaseID == transaction.leaseID else {
                    return (.refused(reason: "gate_refusal_lease_id_mismatch"), nil)
                }
                guard current.ownerConnectionID == transaction.ownerConnectionID else {
                    return (.refused(reason: "gate_refusal_owner_connection_mismatch"), nil)
                }
                guard current.sessionID == transaction.sessionID else {
                    return (.refused(reason: "gate_refusal_session_mismatch"), nil)
                }
                guard current.runID == nil else {
                    return (.refused(reason: "gate_refusal_run_already_assigned"), nil)
                }
                stored.snapshot = Snapshot(
                    leaseID: current.leaseID,
                    ownerConnectionID: current.ownerConnectionID,
                    ownerProcessID: current.ownerProcessID,
                    ownerProcessStartSeconds: current.ownerProcessStartSeconds,
                    ownerProcessStartMicroseconds: current.ownerProcessStartMicroseconds,
                    expiresAt: current.expiresAt,
                    sessionID: transaction.sessionID,
                    runID: runID
                )
                lease = stored
                return (.authorized, nil)
            }
            if let expired = outcome.expired {
                completeExpiredRemoval(expired)
            } else if outcome.decision.isAuthorized {
                publishChange()
            }
            return outcome.decision
        }

        func authorizeProviderStart(transaction: StartTransaction, runID: UUID) -> Bool {
            providerStartAuthorizationDecision(transaction: transaction, runID: runID).isAuthorized
        }

        func requireOwner(processID: Int32) throws -> Snapshot {
            guard let snapshot = activeSnapshot() else { throw LeaseError.expired }
            guard snapshot.ownerProcessID == processID else { throw LeaseError.notOwner }
            return snapshot
        }

        func consume(
            leaseID: UUID,
            ownerConnectionID: UUID,
            ownerProcessID: Int32,
            sessionID: UUID
        ) throws -> Snapshot {
            try consumeStartTransaction(
                leaseID: leaseID,
                ownerConnectionID: ownerConnectionID,
                ownerProcessID: ownerProcessID,
                sessionID: sessionID
            ).snapshot
        }

        func consumeStartTransaction(
            leaseID: UUID,
            ownerConnectionID: UUID,
            ownerProcessID: Int32,
            sessionID: UUID
        ) throws -> Consumption {
            let now = monotonicNowNanoseconds()
            let outcome = lock.withLock { () -> (result: Result<Consumption, LeaseError>, expired: Snapshot?) in
                guard var stored = lease else { return (.failure(.expired), nil) }
                guard now < stored.monotonicDeadlineNanoseconds else {
                    lease = nil
                    expiryGeneration &+= 1
                    return (.failure(.expired), stored.snapshot)
                }
                let current = stored.snapshot
                guard current.leaseID == leaseID, current.ownerProcessID == ownerProcessID else {
                    return (.failure(.notOwner), nil)
                }
                guard current.sessionID == nil, current.runID == nil else {
                    return (.failure(.alreadyConsumed), nil)
                }
                let updated = Snapshot(
                    leaseID: current.leaseID,
                    ownerConnectionID: ownerConnectionID,
                    ownerProcessID: current.ownerProcessID,
                    ownerProcessStartSeconds: current.ownerProcessStartSeconds,
                    ownerProcessStartMicroseconds: current.ownerProcessStartMicroseconds,
                    expiresAt: current.expiresAt,
                    sessionID: sessionID,
                    runID: nil
                )
                let transaction = StartTransaction(
                    transactionID: UUID(),
                    leaseID: current.leaseID,
                    ownerConnectionID: ownerConnectionID,
                    sessionID: sessionID
                )
                stored.snapshot = updated
                stored.startTransactionID = transaction.transactionID
                lease = stored
                return (.success(Consumption(snapshot: updated, transaction: transaction)), nil)
            }
            if let expired = outcome.expired {
                completeExpiredRemoval(expired)
            }
            return try outcome.result.get()
        }

        func bindRun(
            leaseID: UUID,
            ownerConnectionID: UUID,
            sessionID: UUID,
            runID: UUID
        ) throws -> Snapshot {
            let now = monotonicNowNanoseconds()
            let outcome = lock.withLock { () -> (result: Result<Snapshot, LeaseError>, expired: Snapshot?) in
                guard var stored = lease else { return (.failure(.expired), nil) }
                guard now < stored.monotonicDeadlineNanoseconds else {
                    lease = nil
                    expiryGeneration &+= 1
                    return (.failure(.expired), stored.snapshot)
                }
                let current = stored.snapshot
                guard current.leaseID == leaseID,
                      current.ownerConnectionID == ownerConnectionID,
                      current.sessionID == sessionID
                else {
                    return (.failure(.notOwner), nil)
                }
                if current.runID == runID {
                    return (.success(current), nil)
                }
                guard current.runID == nil else {
                    return (.failure(.alreadyConsumed), nil)
                }
                let updated = Snapshot(
                    leaseID: current.leaseID,
                    ownerConnectionID: current.ownerConnectionID,
                    ownerProcessID: current.ownerProcessID,
                    ownerProcessStartSeconds: current.ownerProcessStartSeconds,
                    ownerProcessStartMicroseconds: current.ownerProcessStartMicroseconds,
                    expiresAt: current.expiresAt,
                    sessionID: sessionID,
                    runID: runID
                )
                stored.snapshot = updated
                lease = stored
                return (.success(updated), nil)
            }
            if let expired = outcome.expired {
                completeExpiredRemoval(expired)
            }
            return try outcome.result.get()
        }

        @discardableResult
        func release(leaseID: UUID, ownerProcessID: Int32) throws -> Snapshot {
            let released = try lock.withLock { () throws -> Snapshot in
                guard let stored = lease else { throw LeaseError.expired }
                let current = stored.snapshot
                guard current.leaseID == leaseID, current.ownerProcessID == ownerProcessID else {
                    throw LeaseError.notOwner
                }
                lease = nil
                expiryGeneration &+= 1
                return current
            }
            publishChange()
            cancelBoundRunIfNeeded(released, reason: "qualification_lease_released")
            return released
        }

        /// Rolls back only the exact qualification start phase observed by this transaction.
        /// A concurrent consume/bind or a later lease generation makes the comparison fail.
        @discardableResult
        func rollbackStartTransaction(ifCurrent expected: Snapshot) -> Snapshot? {
            let released = lock.withLock { () -> Snapshot? in
                guard let stored = lease, stored.snapshot == expected else { return nil }
                lease = nil
                expiryGeneration &+= 1
                return stored.snapshot
            }
            if let released {
                publishChange()
                cancelBoundRunIfNeeded(released, reason: "qualification_start_rollback")
            }
            return released
        }

        /// Removes the current snapshot owned by the exact consumed start transaction.
        /// Provider authorization may add a run ID, but another lease generation or session
        /// cannot match this private transaction identity.
        @discardableResult
        func rollbackConsumedStartTransaction(
            _ transaction: StartTransaction,
            cancelBoundRun: Bool = true
        ) -> Snapshot? {
            let released = lock.withLock { () -> Snapshot? in
                guard let stored = lease,
                      stored.startTransactionID == transaction.transactionID,
                      stored.snapshot.leaseID == transaction.leaseID,
                      stored.snapshot.ownerConnectionID == transaction.ownerConnectionID,
                      stored.snapshot.sessionID == transaction.sessionID
                else { return nil }
                lease = nil
                expiryGeneration &+= 1
                return stored.snapshot
            }
            if let released {
                publishChange()
                if cancelBoundRun {
                    cancelBoundRunIfNeeded(released, reason: "qualification_consumed_start_rollback")
                }
            }
            return released
        }

        @discardableResult
        func releaseOwned(by ownerConnectionID: UUID) -> Snapshot? {
            let released = lock.withLock { () -> Snapshot? in
                guard let stored = lease, stored.snapshot.ownerConnectionID == ownerConnectionID else {
                    return nil
                }
                lease = nil
                expiryGeneration &+= 1
                return stored.snapshot
            }
            if let released {
                publishChange()
                cancelBoundRunIfNeeded(released, reason: "qualification_owner_disconnected")
            }
            return released
        }

        @discardableResult
        func acquireForTesting(duration: TimeInterval = 60) throws -> Snapshot {
            try acquire(
                ownerConnectionID: UUID(),
                ownerProcessID: getpid(),
                duration: duration
            )
        }

        func forceExpiryForTesting() {
            lock.withLock {
                guard var current = lease else { return }
                let snapshot = current.snapshot
                current.snapshot = Snapshot(
                    leaseID: snapshot.leaseID,
                    ownerConnectionID: snapshot.ownerConnectionID,
                    ownerProcessID: snapshot.ownerProcessID,
                    ownerProcessStartSeconds: snapshot.ownerProcessStartSeconds,
                    ownerProcessStartMicroseconds: snapshot.ownerProcessStartMicroseconds,
                    expiresAt: .distantPast,
                    sessionID: snapshot.sessionID,
                    runID: snapshot.runID
                )
                lease = StoredLease(
                    snapshot: current.snapshot,
                    monotonicDeadlineNanoseconds: 0,
                    startTransactionID: current.startTransactionID
                )
                expiryGeneration &+= 1
            }
        }

        func resetForTesting() {
            let removed = lock.withLock { () -> Snapshot? in
                let removed = lease?.snapshot
                lease = nil
                expiryGeneration &+= 1
                return removed
            }
            if let removed {
                publishChange()
                cancelBoundRunIfNeeded(removed, reason: "qualification_lease_reset")
            }
        }

        private func scheduleExpiry(
            for snapshot: Snapshot,
            monotonicDeadlineNanoseconds: UInt64,
            generation: UInt64
        ) {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: monotonicDeadlineNanoseconds)
            ) { [weak self] in
                guard let self else { return }
                if let removed = expire(leaseID: snapshot.leaseID, generation: generation) {
                    completeExpiredRemoval(removed)
                }
            }
        }

        private func expire(leaseID: UUID, generation: UInt64) -> Snapshot? {
            lock.withLock {
                guard expiryGeneration == generation,
                      let current = lease,
                      current.snapshot.leaseID == leaseID
                else { return nil }
                lease = nil
                expiryGeneration &+= 1
                return current.snapshot
            }
        }

        private func completeExpiredRemoval(_ snapshot: Snapshot) {
            publishChange()
            cancelBoundRunIfNeeded(snapshot, reason: "qualification_lease_expired")
        }

        private func cancelBoundRunIfNeeded(_ snapshot: Snapshot, reason: String) {
            guard let sessionID = snapshot.sessionID else { return }
            if let cancellationHandler {
                cancellationHandler(snapshot, reason)
                return
            }
            Task { @MainActor in
                for window in WindowStatesManager.shared.allWindows {
                    guard let runID = snapshot.runID,
                          let session = window.agentModeViewModel.mcpControlledSession(sessionID: sessionID),
                          session.runID == runID,
                          session.runState.isActive
                    else { continue }
                    window.mcpServer.cancelActiveToolsForRun(runID: runID, reason: reason)
                    let target = window.agentModeViewModel.makeRunCancelTarget(
                        tabID: session.tabID,
                        session: session
                    )
                    _ = await window.agentModeViewModel.cancelAgentRun(
                        target: target,
                        completion: .terminalPublished
                    )
                    break
                }
            }
        }

        private func publishChange() {
            notificationCenter.post(name: .ohMyPiQualificationLeaseDidChange, object: self)
        }
    }

    private extension NSLock {
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock()
            defer { unlock() }
            return try body()
        }
    }
#endif
