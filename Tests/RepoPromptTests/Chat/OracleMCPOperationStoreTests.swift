import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

private final class OffMainOracleReleaseBox: @unchecked Sendable {
    var value: OracleViewModel?

    init(_ value: OracleViewModel) {
        self.value = value
    }

    func release() {
        value = nil
    }
}

private final class WeakOracleReference: @unchecked Sendable {
    weak var value: OracleViewModel?

    init(_ value: OracleViewModel) {
        self.value = value
    }
}

private final class BatchStartupCapture {}

private final class WeakBatchStartupCaptureReference {
    weak var value: BatchStartupCapture?

    init(_ value: BatchStartupCapture) {
        self.value = value
    }
}

/// Oracle resumable wait plan §5: store receipts, park primitive, single-flight delivery,
/// terminal-reason classification, owner matching, eviction, and teardown — with fake
/// dependencies so no stream, chat, or view model is involved.
@MainActor
final class OracleMCPOperationStoreTests: XCTestCase {
    // MARK: - Harness

    @MainActor
    private final class Harness {
        private(set) var finalizedQueryIDs: Set<UUID> = []
        private(set) var missingQueryIDs: Set<UUID> = []
        private var waiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
        private(set) var unpinCounts: [UUID: Int] = [:]
        var repliesByQueryID: [UUID: [String: Value]] = [:]
        var captureFailures: Set<UUID> = []
        var chatNames: [UUID: String] = [:]
        var progressByQueryID: [UUID: OracleViewModel.OracleMCPProgressSnapshot] = [:]
        var activeStreamCount = 0
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        /// Queries whose wait returns even though the message is neither finalized nor missing.
        var unobservedQueryIDs: Set<UUID> = []

        lazy var store = OracleMCPOperationStore(dependencies: .init(
            waitUntilMessageFinalised: { @MainActor @Sendable [weak self] queryID in
                guard let self else { return }
                try await awaitFinalised(queryID)
            },
            messageState: { [weak self] queryID in
                guard let self else { return .missing }
                if missingQueryIDs.contains(queryID) { return .missing }
                return finalizedQueryIDs.contains(queryID) ? .finalized : .notFinalized
            },
            captureReply: { [weak self] ticket in
                guard let self else { return [:] }
                if captureFailures.contains(ticket.queryID) {
                    throw ChatToolError.internalError("capture failed")
                }
                return repliesByQueryID[ticket.queryID] ?? [
                    "chat_id": .string("short-\(ticket.chatID.uuidString.prefix(4))"),
                    "mode": .string(ticket.replyContext.mode),
                    "response": .string("reply for \(ticket.queryID.uuidString)")
                ]
            },
            unpinSession: { [weak self] chatID in
                self?.unpinCounts[chatID, default: 0] += 1
            },
            chatName: { [weak self] chatID in self?.chatNames[chatID] },
            activeStreamCount: { [weak self] _ in self?.activeStreamCount ?? 0 },
            progressSnapshot: { [weak self] queryID in self?.progressByQueryID[queryID] },
            now: { [weak self] in self?.now ?? Date() }
        ))

        func awaitFinalised(_ queryID: UUID) async throws {
            if finalizedQueryIDs.contains(queryID) || missingQueryIDs.contains(queryID) || unobservedQueryIDs.contains(queryID) {
                return
            }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters[queryID, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters[queryID]?.removeValue(forKey: waiterID)?.resume()
                }
            }
            try Task.checkCancellation()
        }

        func finalize(_ queryID: UUID) {
            finalizedQueryIDs.insert(queryID)
            resume(queryID)
        }

        func removeMessage(_ queryID: UUID) {
            missingQueryIDs.insert(queryID)
            resume(queryID)
        }

        func resumeWithoutFinalizing(_ queryID: UUID) {
            unobservedQueryIDs.insert(queryID)
            resume(queryID)
        }

        private func resume(_ queryID: UUID) {
            let list = waiters.removeValue(forKey: queryID) ?? [:]
            for continuation in list.values {
                continuation.resume()
            }
        }

        func unpinCount(_ chatID: UUID) -> Int {
            unpinCounts[chatID] ?? 0
        }
    }

    private let tabID = UUID()

    private func makeTicket(
        chatID: UUID = UUID(),
        queryID: UUID = UUID(),
        mode: String = "chat",
        presetName: String? = "Store_Preset"
    ) -> OracleViewModel.OracleMCPSendTicket {
        let model = AIModel.customProviderUser(name: "operation-store")
        return OracleViewModel.OracleMCPSendTicket(
            chatID: chatID,
            queryID: queryID,
            createdFreshChat: true,
            replyContext: OracleViewModel.OracleMCPSendReplyContext(
                mode: mode,
                tabID: tabID,
                agentModeSessionID: nil,
                agentModeRunID: nil,
                model: model,
                modelRawID: model.rawValue,
                modelDisplayName: model.displayName,
                modelSelection: "explicit",
                modelSource: presetName == nil ? "planning_model" : "preset",
                modelPresetID: presetName == nil ? nil : UUID(),
                modelPresetName: presetName,
                outputReserveTokens: nil
            )
        )
    }

    private func makeOwner(
        sessionID: UUID? = nil,
        runID: UUID? = nil,
        tabID: UUID? = nil
    ) -> OracleMCPOperationStore.OwnerScope {
        .init(tabID: tabID ?? self.tabID, agentSessionID: sessionID, runID: runID)
    }

    private func makeFinalization(
        mode: String = "chat",
        message: String = "question",
        responseMode: OracleResponseMode = .full,
        exportResponse: Bool = false
    ) -> OracleMCPOperationStore.FinalizationRequest {
        .init(
            mode: mode,
            message: message,
            responseMode: responseMode,
            exportResponse: exportResponse,
            exportDestination: nil
        )
    }

    @discardableResult
    private func reserveAndBind(
        _ harness: Harness,
        owner: OracleMCPOperationStore.OwnerScope? = nil,
        finalization: OracleMCPOperationStore.FinalizationRequest? = nil,
        ticket: OracleViewModel.OracleMCPSendTicket? = nil,
        requestKey: OracleMCPOperationStore.RequestKey? = nil,
        intentDigest: String? = nil
    ) throws -> (operationID: UUID, ticket: OracleViewModel.OracleMCPSendTicket) {
        let ticket = ticket ?? makeTicket()
        let outcome = try harness.store.reserve(
            owner: owner ?? makeOwner(),
            finalization: finalization ?? makeFinalization(),
            requestKey: requestKey,
            intentDigest: intentDigest
        )
        guard case let .reserved(operationID) = outcome else {
            throw ChatToolError.internalError("expected a fresh reservation")
        }
        harness.store.bind(operationID, ticket: ticket, chatShortID: "short-\(ticket.chatID.uuidString.prefix(4))")
        return (operationID, ticket)
    }

    private func settle(_ harness: Harness, operationID: UUID, timeout: TimeInterval = 2) async throws {
        try await AsyncTestWait.waitUntil(
            "operation \(operationID) settled",
            timeout: timeout,
            initialDelayNanoseconds: 1_000_000,
            maximumDelayNanoseconds: 20_000_000
        ) {
            await MainActor.run { harness.store.snapshot(operationID)?.phase.isTerminal == true }
        }
    }

    private func makeWake(
        requested: Bool = false
    ) -> (wake: OracleMCPOperationStore.ExternalWake, fire: () -> Void, subscribeCount: () -> Int, unsubscribeCount: () -> Int) {
        final class Box {
            var requested: Bool
            var onWake: (@MainActor () -> Void)?
            var subscribeCount = 0
            var unsubscribeCount = 0
            init(requested: Bool) {
                self.requested = requested
            }
        }
        let box = Box(requested: requested)
        let wake = OracleMCPOperationStore.ExternalWake(
            isRequested: { box.requested },
            subscribe: { onWake in
                box.subscribeCount += 1
                box.onWake = onWake
            },
            unsubscribe: { box.unsubscribeCount += 1 }
        )
        let fire: () -> Void = {
            box.requested = true
            let handler = box.onWake
            box.onWake = nil
            Task { @MainActor in handler?() }
        }
        return (wake, fire, { box.subscribeCount }, { box.unsubscribeCount })
    }

    func testOracleViewModelFinalReleaseOffMainDoesNotInstantiateStoreOrTrap() async throws {
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState()

        for instantiateStore in [false, true] {
            let candidate: (strong: OffMainOracleReleaseBox, weak: WeakOracleReference) = {
                let viewModel = OracleViewModel(
                    aiQueriesService: window.aiQueriesService,
                    promptViewModel: window.promptManager,
                    workspaceManager: window.workspaceManager,
                    chatData: ChatDataService()
                )
                XCTAssertFalse(viewModel.test_hasMCPOperationStore)
                if instantiateStore {
                    _ = viewModel.mcpOperationStore
                    XCTAssertTrue(viewModel.test_hasMCPOperationStore)
                }
                return (
                    strong: OffMainOracleReleaseBox(viewModel),
                    weak: WeakOracleReference(viewModel)
                )
            }()

            await Task.detached {
                candidate.strong.release()
            }.value
            try await AsyncTestWait.waitUntil("OracleViewModel released off-main") {
                candidate.weak.value == nil
            }
            XCTAssertNil(candidate.weak.value)
        }
    }

    func testAdmissionBoundIsAtomicAcrossOwnersAndKeyedReplayStillWorksAtLimit() throws {
        let harness = Harness()
        harness.activeStreamCount = OracleViewModel.maxConcurrentMCPOracleStreamsPerTab
        let ownerA = makeOwner(sessionID: UUID(), runID: UUID())
        let ownerB = makeOwner(sessionID: UUID(), runID: UUID())
        let requestKey = OracleMCPOperationStore.RequestKey(owner: ownerA, requestID: UUID())
        let keyed = try harness.store.reserve(
            owner: ownerA,
            finalization: makeFinalization(),
            requestKey: requestKey,
            intentDigest: "same"
        )
        guard case let .reserved(keyedOperationID) = keyed else {
            return XCTFail("expected keyed reservation")
        }
        for _ in 1 ..< 31 {
            _ = try harness.store.reserve(owner: ownerA, finalization: makeFinalization())
        }
        XCTAssertEqual(harness.store.test_recordCount(), 31)

        let submission = OracleMCPOperationStore.BatchSubmission(
            finalization: makeFinalization(),
            activeRunProvider: { UUID() },
            startup: { _ in nil }
        )
        do {
            _ = try harness.store.admitBatch(owner: ownerB, submissions: [submission, submission])
            XCTFail("the all-or-nothing batch must not partially cross the tab bound")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .oracleOperationLimit)
            XCTAssertEqual(error.details?["current_count"], "31")
            XCTAssertEqual(error.details?["requested_count"], "2")
            XCTAssertNil(error.details?["running_operation_ids"], "cross-owner IDs must not leak")
        }
        XCTAssertEqual(harness.store.test_recordCount(), 31)

        let admitted = try harness.store.admitBatch(owner: ownerB, submissions: [submission])
        XCTAssertEqual(admitted.count, 1)
        XCTAssertEqual(harness.store.test_recordCount(), 32)

        let replay = try harness.store.reserve(
            owner: ownerA,
            finalization: makeFinalization(),
            requestKey: requestKey,
            intentDigest: "same"
        )
        XCTAssertEqual(replay, .existing(keyedOperationID), "keyed replay resolves before the bound")

        do {
            _ = try harness.store.reserve(owner: ownerA, finalization: makeFinalization())
            XCTFail("a new single must count against the same 32-operation tab bound")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .oracleOperationLimit)
            let visible = error.details?["running_operation_ids"]?
                .split(separator: ",")
                .map(String.init) ?? []
            XCTAssertEqual(visible.count, 31, "only owner A's nonterminal IDs are disclosed")
            XCTAssertFalse(visible.contains(admitted[0].uuidString))
        }
        XCTAssertEqual(harness.store.test_recordCount(), 32)
    }

    func testBatchBindReleasesCapturedStartupState() async throws {
        let harness = Harness()
        let owner = makeOwner(sessionID: UUID(), runID: UUID())
        let ticket = makeTicket()

        func admit(capture: BatchStartupCapture) throws -> UUID {
            let submission = OracleMCPOperationStore.BatchSubmission(
                finalization: makeFinalization(),
                activeRunProvider: {
                    _ = capture
                    return owner.originatingRunID
                },
                startup: { operationID in
                    _ = capture
                    XCTAssertTrue(
                        harness.store.bind(
                            operationID,
                            ticket: ticket,
                            chatShortID: "captured-startup"
                        )
                    )
                    return nil
                }
            )
            return try XCTUnwrap(
                harness.store.admitBatch(owner: owner, submissions: [submission]).first
            )
        }

        var capture: BatchStartupCapture? = BatchStartupCapture()
        let weakCapture = try WeakBatchStartupCaptureReference(XCTUnwrap(capture))
        let operationID = try admit(capture: XCTUnwrap(capture))
        capture = nil

        try await AsyncTestWait.waitUntil("bound batch startup state released", timeout: 2) {
            await MainActor.run {
                harness.store.snapshot(operationID)?.phase == .running
                    && !harness.store.test_hasStartupTask(operationID)
            }
        }
        XCTAssertFalse(harness.store.test_hasBatchStartupState(operationID))
        XCTAssertNil(weakCapture.value)
    }

    func testDelegatedBatchRejectsRunRotationAtFinalReservationGate() async throws {
        let harness = Harness()
        let originatingRunID = UUID()
        let rotatedRunID = UUID()
        let owner = makeOwner(sessionID: UUID(), runID: originatingRunID)
        var observedDecision: OracleMCPOperationStore.BatchReservationDecision?
        let submission = OracleMCPOperationStore.BatchSubmission(
            finalization: makeFinalization(mode: "review"),
            activeRunProvider: { rotatedRunID },
            startup: { operationID in
                observedDecision = harness.store.authorizeBatchReservation(
                    operationID,
                    requiresOriginatingRun: true
                )
                return nil
            }
        )
        let operationID = try XCTUnwrap(
            harness.store.admitBatch(owner: owner, submissions: [submission]).first
        )

        try await AsyncTestWait.waitUntil("delegated rotation rejected", timeout: 2) {
            await MainActor.run { harness.store.snapshot(operationID)?.phase == .failed }
        }
        XCTAssertEqual(observedDecision, .ownerInactive)
        XCTAssertEqual(
            harness.store.baseLane(operationID)?["error"]?.objectValue?["code"]?.stringValue,
            ChatToolErrorCode.notStartedOwnerInactive.rawValue
        )
        XCTAssertEqual(
            harness.store.baseLane(operationID)?["consultation_started"]?.boolValue,
            false
        )
    }

    // MARK: - Park primitive

    func testDeadlineLeavesOperationRunningAndRemovesWaiter() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
        XCTAssertTrue(harness.store.test_ownsPin(operationID))

        let outcome = await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 0.05, externalWake: nil)
        XCTAssertEqual(outcome, .deadline)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
        XCTAssertEqual(harness.store.test_waiterCount(), 0)
        XCTAssertTrue(harness.store.test_ownsPin(operationID))
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 0)

        let polled = await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 0, externalWake: nil)
        XCTAssertEqual(polled, .polled)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
    }

    func testStickySteeringFlagSetBeforeParkReturnsWithoutParking() async throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)
        let wake = makeWake(requested: true)
        let outcome = await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: wake.wake)
        XCTAssertEqual(outcome, .steering)
        XCTAssertEqual(wake.subscribeCount(), 0)
        XCTAssertEqual(harness.store.test_waiterCount(), 0)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
    }

    func testExternalWakeResumesParkedWaiterAsSteeringAndUnsubscribes() async throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)
        let wake = makeWake()
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: wake.wake)
        }
        try await AsyncTestWait.waitUntil("waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }
        XCTAssertEqual(wake.subscribeCount(), 1)
        wake.fire()
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .steering)
        XCTAssertEqual(wake.unsubscribeCount(), 1)
        XCTAssertEqual(harness.store.test_waiterCount(), 0)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running, "a steering wake never touches the query")
    }

    func testCompletionBeatsWakeAndReleasesPinExactlyOnce() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        let wake = makeWake()
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: wake.wake)
        }
        try await AsyncTestWait.waitUntil("waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        // Fire the wake after completion: the waiter must already have resumed as settled.
        wake.fire()
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .settled)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .ready)
        XCTAssertFalse(harness.store.test_ownsPin(operationID))
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 1)
        XCTAssertFalse(harness.store.test_hasCompletionObserver(operationID))

        // A settled set reports settled even when the wake wins the race to the continuation.
        let again = await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: makeWake(requested: true).wake)
        XCTAssertEqual(again, .settled)
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 1)
    }

    func testMultiHandleWaitSettlesOnlyWhenEveryOperationIsTerminal() async throws {
        let harness = Harness()
        let first = try reserveAndBind(harness)
        let second = try reserveAndBind(harness)
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(of: [first.operationID, second.operationID], timeoutSeconds: 5, externalWake: nil)
        }
        try await AsyncTestWait.waitUntil("waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }
        harness.finalize(first.ticket.queryID)
        try await settle(harness, operationID: first.operationID)
        XCTAssertEqual(harness.store.test_waiterCount(), 1, "one settled lane must not resume a multi-handle waiter")
        harness.finalize(second.ticket.queryID)
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .settled)
        XCTAssertTrue(harness.store.allSettled([first.operationID, second.operationID]))
    }

    func testMultiHandleWaitSettlesAfterOneTerminalLaneIsEvictedMidWait() async throws {
        let harness = Harness()
        let owner = makeOwner()
        let first = try reserveAndBind(harness, owner: owner)
        let second = try reserveAndBind(harness, owner: owner)
        harness.finalize(first.ticket.queryID)
        try await settle(harness, operationID: first.operationID)

        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(
                of: [first.operationID, second.operationID],
                timeoutSeconds: 5,
                externalWake: nil
            )
        }
        try await AsyncTestWait.waitUntil("multi-lane waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }

        harness.now = harness.now.addingTimeInterval(
            OracleMCPOperationStore.undeliveredRetentionSeconds + 1
        )
        harness.store.purge()
        XCTAssertEqual(harness.store.test_waiterCount(), 1)
        if case .expired = harness.store.lookup(first.operationID, caller: owner) {} else {
            XCTFail("the evicted lane should remain an owner-visible tombstone")
        }

        harness.finalize(second.ticket.queryID)
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .settled)
        XCTAssertEqual(harness.store.test_waiterCount(), 0)
    }

    func testDiscardedStartingReceiptSettlesParkedWaiter() async throws {
        let harness = Harness()
        let owner = makeOwner()
        let requestKey = OracleMCPOperationStore.RequestKey(owner: owner, requestID: UUID())
        guard case let .reserved(operationID) = try harness.store.reserve(
            owner: owner,
            finalization: makeFinalization(),
            requestKey: requestKey,
            intentDigest: "same-key-intent"
        ) else {
            return XCTFail("expected reservation")
        }
        XCTAssertEqual(
            try harness.store.reserve(
                owner: owner,
                finalization: makeFinalization(),
                requestKey: requestKey,
                intentDigest: "same-key-intent"
            ),
            .existing(operationID),
            "the parked observer models an identical concurrent keyed retry"
        )
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(
                of: [operationID],
                timeoutSeconds: 5,
                externalWake: nil
            )
        }
        try await AsyncTestWait.waitUntil("starting waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }

        harness.store.discardUnstarted(operationID)

        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .settled)
        XCTAssertNil(harness.store.snapshot(operationID))
        XCTAssertEqual(harness.store.test_waiterCount(), 0)
    }

    func testTaskCancellationResumesWaiterAsCancelledWithoutTouchingOperation() async throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: nil)
        }
        try await AsyncTestWait.waitUntil("waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }
        waitTask.cancel()
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
        XCTAssertTrue(harness.store.test_ownsPin(operationID))
    }

    // MARK: - Delivery

    func testSingleFlightDeliveryFinalizesOnceUnderConcurrentWaitsAndReplaysCached() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)

        final class Counter { var finalizeCalls = 0 }
        let counter = Counter()
        let finalize: @MainActor (inout [String: Value], OracleMCPOperationStore.FinalizationRequest) async throws -> Void = { result, _ in
            counter.finalizeCalls += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            result["oracle_export_path"] = .string("/tmp/export-\(counter.finalizeCalls).md")
        }
        async let first = harness.store.deliver(operationID, finalize: finalize)
        async let second = harness.store.deliver(operationID, finalize: finalize)
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(counter.finalizeCalls, 1, "export/finalize must run at most once per operation")
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult["status"]?.stringValue, "completed")
        XCTAssertEqual(firstResult["operation_id"]?.stringValue, operationID.uuidString)
        XCTAssertEqual(firstResult["query_id"]?.stringValue, ticket.queryID.uuidString)
        XCTAssertEqual(firstResult["oracle_export_path"]?.stringValue, "/tmp/export-1.md")
        XCTAssertEqual(harness.store.snapshot(operationID)?.delivery, .delivered)

        let replay = try await harness.store.deliver(operationID) { _, _ in
            XCTFail("cached delivery must not finalize again")
        }
        XCTAssertEqual(replay, firstResult)
        XCTAssertNil(replay["wait_policy"], "cached lanes never carry wait_policy; each invocation attaches its own")
    }

    func testFailedFinalizeRevertsToUndeliveredForRetry() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)

        do {
            _ = try await harness.store.deliver(operationID) { _, _ in
                throw ChatToolError.internalError("export exploded")
            }
            XCTFail("expected the finalize failure to propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("export exploded"))
        }
        XCTAssertEqual(harness.store.snapshot(operationID)?.delivery, .undelivered)

        let retried = try await harness.store.deliver(operationID) { result, _ in
            result["retried"] = .bool(true)
        }
        XCTAssertEqual(retried["retried"]?.boolValue, true)
        XCTAssertEqual(harness.store.snapshot(operationID)?.delivery, .delivered)
    }

    func testDeliverRejectsNonTerminalAndUnknownOperations() async throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)
        do {
            _ = try await harness.store.deliver(operationID) { _, _ in }
            XCTFail("running operations are not deliverable")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .internalError)
        }
        do {
            _ = try await harness.store.deliver(UUID()) { _, _ in }
            XCTFail("unknown operations are not deliverable")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .oracleOperationNotFound)
        }
    }

    // MARK: - Terminal-reason classification

    func testTerminalReasonStampIsFirstWriterWinsAndCancelledLaneNeverExports() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(
            harness,
            finalization: makeFinalization(responseMode: .tail, exportResponse: false)
        )
        harness.repliesByQueryID[ticket.queryID] = [
            "chat_id": .string("short"),
            "mode": .string("chat"),
            "response": .string("partial text so far")
        ]
        harness.store.noteStreamTerminal(queryID: ticket.queryID, reason: .cancelled)
        harness.store.noteStreamTerminal(queryID: ticket.queryID, reason: .failed)
        XCTAssertEqual(harness.store.test_terminalReason(operationID), .cancelled)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelled)

        let lane = try await harness.store.deliver(operationID) { _, _ in
            XCTFail("cancelled lanes are never finalized/exported")
        }
        XCTAssertEqual(lane["ok"]?.boolValue, false)
        XCTAssertEqual(lane["status"]?.stringValue, "cancelled")
        XCTAssertNil(lane["response"])
        XCTAssertEqual(lane["partial_response"]?.stringValue, "partial text so far")
        XCTAssertEqual(lane["export_skipped"]?.stringValue, "cancelled")
        XCTAssertEqual(lane["error"]?.objectValue?["code"]?.stringValue, "oracle_cancelled")
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 1)
    }

    func testFailedStampClassifiesFailedAndAbsentStampClassifiesCompleted() async throws {
        let harness = Harness()
        let failed = try reserveAndBind(harness)
        harness.store.noteStreamTerminal(
            queryID: failed.ticket.queryID,
            reason: .failed,
            detail: "watchdog_forced_finalization"
        )
        harness.finalize(failed.ticket.queryID)
        try await settle(harness, operationID: failed.operationID)
        XCTAssertEqual(harness.store.snapshot(failed.operationID)?.phase, .failed)
        XCTAssertEqual(harness.store.test_terminalDetail(failed.operationID), "watchdog_forced_finalization")
        let failedLane = try await harness.store.deliver(failed.operationID) { _, _ in }
        XCTAssertEqual(failedLane["status"]?.stringValue, "failed")
        XCTAssertEqual(failedLane["error"]?.objectValue?["code"]?.stringValue, "oracle_stream_failed")

        let completed = try reserveAndBind(harness)
        harness.finalize(completed.ticket.queryID)
        try await settle(harness, operationID: completed.operationID)
        XCTAssertEqual(harness.store.snapshot(completed.operationID)?.phase, .ready)
        XCTAssertNil(harness.store.test_terminalReason(completed.operationID))

        // A stamp for a query no operation observes is a no-op.
        harness.store.noteStreamTerminal(queryID: UUID(), reason: .failed)
        XCTAssertEqual(harness.store.test_recordCount(), 2)

        // A stamp arriving after the terminal phase is written never rewrites it.
        harness.store.noteStreamTerminal(queryID: completed.ticket.queryID, reason: .cancelled)
        XCTAssertEqual(harness.store.snapshot(completed.operationID)?.phase, .ready)
        XCTAssertNil(harness.store.test_terminalReason(completed.operationID))
    }

    func testMissingOrUnfinalizedMessageIsNeverSuccess() async throws {
        let harness = Harness()
        let missing = try reserveAndBind(harness)
        harness.removeMessage(missing.ticket.queryID)
        try await settle(harness, operationID: missing.operationID)
        XCTAssertEqual(harness.store.snapshot(missing.operationID)?.phase, .failed)
        XCTAssertEqual(harness.store.test_terminalDetail(missing.operationID), "message_missing")
        XCTAssertEqual(harness.unpinCount(missing.ticket.chatID), 1)

        let unobserved = try reserveAndBind(harness)
        harness.resumeWithoutFinalizing(unobserved.ticket.queryID)
        try await settle(harness, operationID: unobserved.operationID)
        XCTAssertEqual(harness.store.snapshot(unobserved.operationID)?.phase, .failed)
        XCTAssertEqual(harness.store.test_terminalDetail(unobserved.operationID), "finalization_unobserved")
    }

    func testCaptureFailureStillReleasesPinAndDeliversStatusOnlyLane() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.captureFailures.insert(ticket.queryID)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 1)
        let lane = try await harness.store.deliver(operationID) { _, _ in }
        XCTAssertEqual(lane["status"]?.stringValue, "completed")
        XCTAssertEqual(lane["operation_id"]?.stringValue, operationID.uuidString)
        XCTAssertEqual(lane["chat_id"]?.stringValue, "short-\(ticket.chatID.uuidString.prefix(4))")
    }

    // MARK: - Cancel phases

    func testCancelRequestedBeforeParkReportsCancellingThenTerminalCancelled() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.store.noteCancelRequested(operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelling)
        XCTAssertTrue(harness.store.snapshot(operationID)?.cancelRequested ?? false)

        let outcome = await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 0.02, externalWake: nil)
        XCTAssertEqual(outcome, .deadline)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelling, "cancel never parks and never delivers")

        harness.store.noteStreamTerminal(queryID: ticket.queryID, reason: .cancelled)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelled)
        harness.store.noteCancelRequested(operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelled, "terminal phases are never overwritten")
    }

    func testCancelGateAllowsOneStopAndCanRestoreRejectedAttempt() throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)

        XCTAssertTrue(harness.store.beginCancelRequest(operationID))
        XCTAssertFalse(harness.store.beginCancelRequest(operationID))
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .cancelling)

        harness.store.cancelRequestRejected(operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
        XCTAssertFalse(harness.store.snapshot(operationID)?.cancelRequested ?? true)
        XCTAssertTrue(harness.store.beginCancelRequest(operationID))
    }

    func testCompletionCanBeatCancelRequest() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.store.noteCancelRequested(operationID)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .ready, "cancelling → completed is a legal exit")
    }

    // MARK: - Owner match and lookup

    func testOwnerMatchAcrossRunRotationAndExactRunForRunOnlyOperations() throws {
        let harness = Harness()
        let sessionID = UUID()
        let runA = UUID()
        let runB = UUID()
        let sessionOwned = try reserveAndBind(harness, owner: makeOwner(sessionID: sessionID, runID: runA))
        let runOwned = try reserveAndBind(harness, owner: makeOwner(sessionID: nil, runID: runA))
        let unowned = try reserveAndBind(harness, owner: makeOwner())

        if case .found = harness.store.lookup(sessionOwned.operationID, caller: makeOwner(sessionID: sessionID, runID: runB)) {} else {
            XCTFail("session-owned operations survive run rotation")
        }
        XCTAssertEqual(harness.store.lookup(sessionOwned.operationID, caller: makeOwner(sessionID: UUID(), runID: runA)), .notFound)
        XCTAssertEqual(harness.store.lookup(sessionOwned.operationID, caller: makeOwner(sessionID: sessionID, runID: runA, tabID: UUID())), .notFound)

        if case .found = harness.store.lookup(runOwned.operationID, caller: makeOwner(sessionID: nil, runID: runA)) {} else {
            XCTFail("run-only operations match the exact run")
        }
        XCTAssertEqual(harness.store.lookup(runOwned.operationID, caller: makeOwner(sessionID: sessionID, runID: runA)), .notFound, "a session-having caller must not adopt a run-only operation")
        XCTAssertEqual(harness.store.lookup(runOwned.operationID, caller: makeOwner(sessionID: nil, runID: runB)), .notFound)

        if case .found = harness.store.lookup(unowned.operationID, caller: makeOwner()) {} else {
            XCTFail("unowned operations match unowned callers")
        }
        XCTAssertEqual(harness.store.lookup(unowned.operationID, caller: makeOwner(sessionID: sessionID, runID: runA)), .notFound, "allowUnownedLegacy is false for operations")
        XCTAssertEqual(harness.store.lookup(UUID(), caller: makeOwner()), .notFound)

        XCTAssertEqual(
            harness.store.undeliveredOperationIDs(owner: makeOwner(sessionID: sessionID, runID: runB)),
            [sessionOwned.operationID]
        )
        XCTAssertEqual(
            harness.store.runningOperationIDs(inTab: tabID),
            [sessionOwned.operationID, runOwned.operationID, unowned.operationID]
        )
        XCTAssertEqual(harness.store.runningOperationIDs(chatID: unowned.ticket.chatID), [unowned.operationID])
    }

    func testTombstonesAndRunningIDsAreOwnerScoped() async throws {
        let harness = Harness()
        let ownerA = makeOwner(sessionID: UUID(), runID: UUID())
        let ownerB = makeOwner(sessionID: UUID(), runID: UUID())
        let first = try reserveAndBind(harness, owner: ownerA)
        let second = try reserveAndBind(harness, owner: ownerB)

        XCTAssertEqual(harness.store.runningOperationIDs(owner: ownerA), [first.operationID])
        XCTAssertEqual(harness.store.runningOperationIDs(owner: ownerB), [second.operationID])

        harness.finalize(first.ticket.queryID)
        try await settle(harness, operationID: first.operationID)
        _ = try await harness.store.deliver(first.operationID) { _, _ in }
        harness.now = harness.now.addingTimeInterval(
            OracleMCPOperationStore.deliveredRetentionSeconds + 1
        )
        harness.store.purge()

        if case .expired = harness.store.lookup(first.operationID, caller: ownerA) {} else {
            XCTFail("the owner should see its tombstone")
        }
        XCTAssertEqual(
            harness.store.lookup(first.operationID, caller: ownerB),
            .notFound,
            "a tombstone must not reveal another owner's operation"
        )
        XCTAssertEqual(
            harness.store.lookup(
                first.operationID,
                caller: makeOwner(
                    sessionID: ownerA.agentSessionID,
                    runID: ownerA.runID,
                    tabID: UUID()
                )
            ),
            .notFound,
            "a tombstone must not cross tab boundaries"
        )
    }

    // MARK: - request_id

    func testRequestKeyDedupObservesIdenticalIntentAndRejectsDifferentIntent() throws {
        let harness = Harness()
        let owner = makeOwner(sessionID: UUID(), runID: UUID())
        let key = OracleMCPOperationStore.RequestKey(owner: owner, requestID: UUID())
        let first = try harness.store.reserve(owner: owner, finalization: makeFinalization(), requestKey: key, intentDigest: "intent-a")
        guard case let .reserved(operationID) = first else { return XCTFail("expected reservation") }
        XCTAssertEqual(
            try harness.store.reserve(owner: owner, finalization: makeFinalization(), requestKey: key, intentDigest: "intent-a"),
            .existing(operationID)
        )
        XCTAssertThrowsError(
            try harness.store.reserve(owner: owner, finalization: makeFinalization(), requestKey: key, intentDigest: "intent-b")
        ) { error in
            XCTAssertEqual((error as? ChatToolError)?.code, .invalidParams)
        }
        XCTAssertEqual(harness.store.test_recordCount(), 1, "a rejected different intent never mutates")

        // A rejected start releases the key so the same request_id can be retried.
        harness.store.discardUnstarted(operationID)
        XCTAssertEqual(harness.store.test_recordCount(), 0)
        guard case .reserved = try harness.store.reserve(owner: owner, finalization: makeFinalization(), requestKey: key, intentDigest: "intent-a") else {
            return XCTFail("expected a fresh reservation after discard")
        }
    }

    func testUsedRequestKeySurvivesTombstoneCompaction() async throws {
        let harness = Harness()
        let owner = makeOwner(sessionID: UUID(), runID: UUID())
        let key = OracleMCPOperationStore.RequestKey(owner: owner, requestID: UUID())
        guard case let .reserved(firstID) = try harness.store.reserve(
            owner: owner,
            finalization: makeFinalization(),
            requestKey: key,
            intentDigest: "durable-intent"
        ) else {
            return XCTFail("expected keyed reservation")
        }
        let firstTicket = makeTicket()
        harness.store.test_bindCompleted(
            firstID,
            ticket: firstTicket,
            chatShortID: "durable-chat",
            result: ["chat_id": .string("durable-chat"), "response": .string("done")]
        )
        _ = try await harness.store.deliver(firstID) { _, _ in }

        let churnCount = OracleMCPOperationStore.maxTerminalRecords
            + OracleMCPOperationStore.maxTombstones + 2
        for _ in 0 ..< churnCount {
            guard case let .reserved(operationID) = try harness.store.reserve(
                owner: owner,
                finalization: makeFinalization()
            ) else {
                return XCTFail("expected churn reservation")
            }
            let ticket = makeTicket()
            harness.store.test_bindCompleted(
                operationID,
                ticket: ticket,
                chatShortID: nil,
                result: ["response": .string("done")]
            )
            _ = try await harness.store.deliver(operationID) { _, _ in }
            harness.now = harness.now.addingTimeInterval(1)
        }
        harness.store.purge()

        XCTAssertEqual(harness.store.test_tombstoneCount(), OracleMCPOperationStore.maxTombstones)
        XCTAssertEqual(harness.store.test_usedRequestKeyCount(), 1)
        XCTAssertThrowsError(
            try harness.store.reserve(
                owner: owner,
                finalization: makeFinalization(),
                requestKey: key,
                intentDigest: "durable-intent"
            )
        ) { error in
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleOperationExpired)
            XCTAssertEqual((error as? ChatToolError)?.details?["operation_id"], firstID.uuidString)
        }
    }

    func testDiscardUnstartedIgnoresBoundOperations() throws {
        let harness = Harness()
        let (operationID, _) = try reserveAndBind(harness)
        harness.store.discardUnstarted(operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .running)
    }

    func testBindIgnoresUnknownOrAlreadyBoundReceipts() throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        let other = makeTicket()
        XCTAssertFalse(harness.store.bind(operationID, ticket: other, chatShortID: "other"))
        XCTAssertEqual(harness.store.snapshot(operationID)?.queryID, ticket.queryID)
        XCTAssertFalse(harness.store.bind(UUID(), ticket: other, chatShortID: "other"))
        XCTAssertEqual(harness.store.test_recordCount(), 1)
        XCTAssertEqual(harness.unpinCount(other.chatID), 0, "an ignored bind leaves the caller's pin with the caller")
    }

    // MARK: - Eviction and tombstones

    func testEvictionKeepsActiveWorkEvictsOldestDeliveredFirstAndMintsTombstones() async throws {
        let harness = Harness()
        let active = try reserveAndBind(harness)
        var deliveredIDs: [UUID] = []
        for _ in 0 ..< (OracleMCPOperationStore.maxTerminalRecords + 3) {
            let (operationID, ticket) = try reserveAndBind(harness)
            harness.finalize(ticket.queryID)
            try await settle(harness, operationID: operationID)
            _ = try await harness.store.deliver(operationID) { _, _ in }
            deliveredIDs.append(operationID)
            harness.now = harness.now.addingTimeInterval(1)
        }
        harness.store.purge()
        XCTAssertNotNil(harness.store.snapshot(active.operationID), "active work is never evicted")
        let remainingTerminal = deliveredIDs.filter { harness.store.snapshot($0) != nil }
        XCTAssertEqual(remainingTerminal.count, OracleMCPOperationStore.maxTerminalRecords)
        for evicted in deliveredIDs.prefix(3) {
            XCTAssertNil(harness.store.snapshot(evicted))
            guard case let .expired(tombstone) = harness.store.lookup(evicted, caller: makeOwner()) else {
                return XCTFail("evicted operations answer with a tombstone")
            }
            XCTAssertEqual(tombstone.operationID, evicted)
            XCTAssertNotNil(tombstone.chatShortID)
        }
        XCTAssertEqual(harness.store.test_tombstoneCount(), 3)
    }

    func testDeliveredResultsExpireAfterRetentionAndKeyedTombstoneReportsExpired() async throws {
        let harness = Harness()
        let owner = makeOwner()
        let key = OracleMCPOperationStore.RequestKey(owner: owner, requestID: UUID())
        let (operationID, ticket) = try reserveAndBind(harness, owner: owner, requestKey: key, intentDigest: "keyed")
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        _ = try await harness.store.deliver(operationID) { _, _ in }

        harness.now = harness.now.addingTimeInterval(OracleMCPOperationStore.deliveredRetentionSeconds - 1)
        harness.store.purge()
        XCTAssertNotNil(harness.store.snapshot(operationID))

        harness.now = harness.now.addingTimeInterval(2)
        harness.store.purge()
        XCTAssertNil(harness.store.snapshot(operationID))
        XCTAssertThrowsError(
            try harness.store.reserve(owner: owner, finalization: makeFinalization(), requestKey: key, intentDigest: "keyed")
        ) { error in
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleOperationExpired)
        }
    }

    func testLifetimeUsedKeyMarkersRetainOnlyFixedSizeDigestsAcrossLargeIntentCompaction() throws {
        let harness = Harness()
        let owner = makeOwner(sessionID: UUID(), runID: UUID())
        var firstKey: OracleMCPOperationStore.RequestKey?
        var firstDigest: String?

        for index in 0 ..< 700 {
            let requestKey = OracleMCPOperationStore.RequestKey(owner: owner, requestID: UUID())
            let message = String(repeating: "large-intent-sentinel-\(index)-", count: 2048)
            let digest = MCPOracleToolService.intentDigest(
                args: [
                    "message": .string(message),
                    "mode": .string("chat"),
                    "new_chat": .bool(true)
                ],
                responseMode: .full,
                exportResponse: false
            )
            XCTAssertEqual(digest.utf8.count, 64)
            guard case let .reserved(operationID) = try harness.store.reserve(
                owner: owner,
                finalization: makeFinalization(message: message),
                requestKey: requestKey,
                intentDigest: digest
            ) else {
                return XCTFail("expected a fresh keyed reservation")
            }
            let ticket = makeTicket()
            harness.store.test_bindCompleted(
                operationID,
                ticket: ticket,
                chatShortID: "large-\(index)",
                result: [
                    "chat_id": .string("large-\(index)"),
                    "mode": .string("chat"),
                    "response": .string("done")
                ]
            )
            if index == 0 {
                firstKey = requestKey
                firstDigest = digest
            }
        }

        harness.store.purge()
        XCTAssertEqual(harness.store.test_usedRequestKeyCount(), 700)
        XCTAssertLessThanOrEqual(harness.store.test_recordCount(), OracleMCPOperationStore.maxTerminalRecords)
        XCTAssertEqual(harness.store.test_tombstoneCount(), OracleMCPOperationStore.maxTombstones)
        let retainedDigests = harness.store.test_usedRequestIntentDigests()
        XCTAssertEqual(retainedDigests.count, 700)
        XCTAssertTrue(retainedDigests.allSatisfy { $0.utf8.count == 64 })
        XCTAssertFalse(retainedDigests.contains { $0.contains("large-intent-sentinel") })

        let key = try XCTUnwrap(firstKey)
        let digest = try XCTUnwrap(firstDigest)
        XCTAssertThrowsError(
            try harness.store.reserve(
                owner: owner,
                finalization: makeFinalization(),
                requestKey: key,
                intentDigest: digest
            )
        ) { error in
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleOperationExpired)
        }
    }

    func testUndeliveredRetentionStartsAtTerminalTimestamp() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.now = harness.now.addingTimeInterval(
            OracleMCPOperationStore.undeliveredRetentionSeconds - 60
        )
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)

        harness.now = harness.now.addingTimeInterval(120)
        harness.store.purge()
        XCTAssertNotNil(
            harness.store.snapshot(operationID),
            "long-running work gets a full terminal retention window"
        )

        harness.now = harness.now.addingTimeInterval(
            OracleMCPOperationStore.undeliveredRetentionSeconds
        )
        harness.store.purge()
        XCTAssertNil(harness.store.snapshot(operationID))
    }

    func testUndeliveredTerminalRecordsExpireAfterTwentyFourHours() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        harness.now = harness.now.addingTimeInterval(OracleMCPOperationStore.undeliveredRetentionSeconds + 1)
        harness.store.purge()
        XCTAssertNil(harness.store.snapshot(operationID))
        XCTAssertEqual(harness.store.test_tombstoneCount(), 1)
    }

    // MARK: - Summaries, revision, teardown

    func testSummaryReportsPhaseElapsedChatIdentityAndCollectedState() async throws {
        let harness = Harness()
        let ticket = makeTicket(mode: "plan")
        harness.chatNames[ticket.chatID] = "Duel lane A"
        harness.progressByQueryID[ticket.queryID] = OracleViewModel.OracleMCPProgressSnapshot(
            outputChars: 12480,
            lastActivityAt: harness.now.addingTimeInterval(-4)
        )
        let (operationID, _) = try reserveAndBind(harness, finalization: makeFinalization(mode: "plan"), ticket: ticket)
        let running = try XCTUnwrap(harness.store.summary(for: operationID))
        XCTAssertEqual(running.phase, .running)
        XCTAssertFalse(running.isTerminal)
        XCTAssertFalse(running.isCollected)
        XCTAssertEqual(running.chatID, ticket.chatID)
        XCTAssertEqual(running.chatName, "Duel lane A")
        XCTAssertEqual(running.mode, "plan")
        XCTAssertEqual(running.modelPresetName, "Store_Preset")
        XCTAssertEqual(running.progress?.outputChars, 12480)
        XCTAssertEqual(running.progress?.lastActivitySecondsAgo, 4)
        XCTAssertNil(running.progress?.queuePosition)
        XCTAssertEqual(running.elapsed(at: harness.now.addingTimeInterval(720)), 720, accuracy: 0.001)
        harness.now = harness.now.addingTimeInterval(37)
        XCTAssertEqual(harness.store.elapsedSeconds(for: operationID), 37)
        harness.now = harness.now.addingTimeInterval(-37)

        harness.now = harness.now.addingTimeInterval(10)
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        let ready = try XCTUnwrap(harness.store.summary(forOperationIDString: operationID.uuidString))
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertTrue(ready.isTerminal)
        XCTAssertFalse(ready.isCollected)
        XCTAssertNil(ready.progress, "terminal rows never expose advisory pending progress")
        XCTAssertEqual(ready.elapsed(at: harness.now.addingTimeInterval(1000)), 10, accuracy: 0.001, "elapsed freezes at the terminal timestamp")

        _ = try await harness.store.deliver(operationID) { _, _ in }
        XCTAssertTrue(harness.store.summary(for: operationID)?.isCollected ?? false)
        XCTAssertNil(harness.store.summary(forOperationIDString: "not-a-uuid"))
    }

    func testPhaseRevisionPublishesOnTransitionsNotReads() async throws {
        let harness = Harness()
        let before = harness.store.phaseRevision
        let (operationID, ticket) = try reserveAndBind(harness)
        let afterBind = harness.store.phaseRevision
        XCTAssertGreaterThan(afterBind, before)
        _ = harness.store.snapshot(operationID)
        _ = harness.store.summary(for: operationID)
        _ = harness.store.lookup(operationID, caller: makeOwner())
        XCTAssertEqual(harness.store.phaseRevision, afterBind, "reads never publish")
        harness.finalize(ticket.queryID)
        try await settle(harness, operationID: operationID)
        let afterTerminal = harness.store.phaseRevision
        XCTAssertGreaterThan(afterTerminal, afterBind)
        _ = try await harness.store.deliver(operationID) { _, _ in }
        XCTAssertGreaterThan(harness.store.phaseRevision, afterTerminal)
    }

    func testTeardownStopsBatchAdmissionAndResumesPreparedCapacityWaiters() async throws {
        let harness = Harness()
        harness.activeStreamCount = OracleViewModel.maxConcurrentMCPOracleStreamsPerTab
        let owner = makeOwner(sessionID: UUID(), runID: UUID())
        let submission = OracleMCPOperationStore.BatchSubmission(
            finalization: makeFinalization(),
            activeRunProvider: { owner.originatingRunID },
            startup: { _ in nil }
        )
        let operationID = try XCTUnwrap(
            harness.store.admitBatch(owner: owner, submissions: [submission]).first
        )
        let capacityTask = Task { @MainActor in
            await harness.store.awaitBatchCapacity(operationID)
        }
        try await AsyncTestWait.waitUntil("batch capacity waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_batchCapacityWaiterCount() == 1 }
        }

        harness.store.teardown()

        let capacityResult = await capacityTask.value
        XCTAssertFalse(capacityResult)
        XCTAssertEqual(harness.store.test_batchCapacityWaiterCount(), 0)
        XCTAssertTrue(harness.store.test_batchQueue(owner.tabID).isEmpty)
        do {
            _ = try harness.store.admitBatch(owner: owner, submissions: [submission])
            XCTFail("teardown must permanently stop batch admission")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .internalError)
        }
    }

    func testTeardownCancelsObserversResumesWaitersAndReleasesPins() async throws {
        let harness = Harness()
        let (operationID, ticket) = try reserveAndBind(harness)
        let waitTask = Task { @MainActor in
            await harness.store.awaitSettlement(of: [operationID], timeoutSeconds: 5, externalWake: nil)
        }
        try await AsyncTestWait.waitUntil("waiter parked", timeout: 2) {
            await MainActor.run { harness.store.test_waiterCount() == 1 }
        }
        harness.store.teardown()
        let outcome = await waitTask.value
        XCTAssertEqual(outcome, .cancelled)
        try await settle(harness, operationID: operationID)
        XCTAssertEqual(harness.store.snapshot(operationID)?.phase, .failed, "observer cancellation is never success")
        XCTAssertEqual(harness.store.test_terminalDetail(operationID), "observer_cancelled")
        XCTAssertEqual(harness.unpinCount(ticket.chatID), 1)
        let afterTeardown = await harness.store.awaitSettlement(of: [UUID()], timeoutSeconds: 5, externalWake: nil)
        XCTAssertEqual(afterTeardown, .settled, "unknown IDs count as settled; nothing parks after teardown")
    }
}
