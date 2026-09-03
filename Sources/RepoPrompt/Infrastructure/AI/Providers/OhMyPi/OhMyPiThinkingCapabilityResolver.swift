import Foundation

extension Notification.Name {
    static let ohMyPiThinkingCapabilityProbeStateDidChange = Notification.Name(
        "RepoPrompt.ohMyPiThinkingCapabilityProbeStateDidChange"
    )
}

enum OhMyPiThinkingCapabilityProbeState: Equatable {
    case idle
    case queued
    case loading
    case unsupported
    case failed
}

enum OhMyPiThinkingSweepStatus: Equatable {
    case idle
    case preflight
    case running(done: Int, total: Int, current: String?)
    case partial(loaded: Int, deferred: Int)
    case failed(reason: String, at: Date)
    case completed(loaded: Int, failed: Int, unsupported: Int, at: Date)
    case cancelled(reason: OhMyPiThinkingSweepCancellationReason)
}

final class OhMyPiThinkingCapabilityProbeStatusStore: @unchecked Sendable {
    static let shared = OhMyPiThinkingCapabilityProbeStatusStore()

    private let lock = NSLock()
    private var statesByModelID: [String: OhMyPiThinkingCapabilityProbeState] = [:]
    private var storedSweepStatus: OhMyPiThinkingSweepStatus = .idle

    func state(for exactModelID: String) -> OhMyPiThinkingCapabilityProbeState {
        lock.withLock { statesByModelID[exactModelID] ?? .idle }
    }

    var sweep: OhMyPiThinkingSweepStatus {
        lock.withLock { storedSweepStatus }
    }

    func set(_ state: OhMyPiThinkingCapabilityProbeState, for exactModelID: String) {
        let changed = lock.withLock { () -> Bool in
            let previous = statesByModelID[exactModelID] ?? .idle
            if state == .idle {
                statesByModelID.removeValue(forKey: exactModelID)
            } else {
                statesByModelID[exactModelID] = state
            }
            return previous != state
        }
        guard changed else { return }
        postChange(modelID: exactModelID)
    }

    func setSweep(_ status: OhMyPiThinkingSweepStatus) {
        let changed = lock.withLock { () -> Bool in
            guard storedSweepStatus != status else { return false }
            storedSweepStatus = status
            return true
        }
        guard changed else { return }
        postChange(modelID: nil)
    }

    private func postChange(modelID: String?) {
        let userInfo: [String: Any]? = modelID.map { ["modelID": $0] }
        NotificationCenter.default.post(
            name: .ohMyPiThinkingCapabilityProbeStateDidChange,
            object: self,
            userInfo: userInfo
        )
    }
}

struct OhMyPiThinkingSweepRequest {
    let wireIDs: [String]
    let selectedRawModel: String?
    let workspacePath: String?
    let isLocal: Bool

    init(
        wireIDs: [String],
        selectedRawModel: String?,
        workspacePath: String?,
        isLocal: Bool = true
    ) {
        self.wireIDs = wireIDs
        self.selectedRawModel = selectedRawModel
        self.workspacePath = workspacePath
        self.isLocal = isLocal
    }
}

actor OhMyPiThinkingCapabilityResolver {
    enum Outcome: Equatable {
        case cached
        case loaded
        case coalesced
        case enqueued
        case cooldownSkipped
        case cancelled
        case failed
    }

    static let shared = OhMyPiThinkingCapabilityResolver(
        client: OhMyPiThinkingCapabilityControllerSweepClient()
    )

    private struct VersionedModelID: Hashable {
        let modelID: String
        let version: String
    }

    private struct QueueEntry: Equatable {
        let modelID: String
        let workspacePath: String?
        let isBackground: Bool
    }

    private let client: any OhMyPiThinkingCapabilitySweepClient
    private let registry: OhMyPiThinkingCapabilityRegistry
    nonisolated let statusStore: OhMyPiThinkingCapabilityProbeStatusStore
    private let limits: OhMyPiThinkingSweepLimits
    private let runtimeVersion: @Sendable () -> String?
    private let isAvailable: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    private var activeQueue: [QueueEntry] = []
    private var reservedEntry: QueueEntry?
    private var deferredBackgroundIDs: [String] = []
    private var deferredBackgroundSet: Set<String> = []
    private var cleanupQueue: [QueueEntry] = []
    private var backgroundPassIDs: Set<String> = []
    private var nextPassRequested = false

    private var sweepTask: Task<Void, Never>?
    private var isCleaningUp = false
    private var runGeneration: UInt64 = 0
    private var switchGeneration: UInt64 = 0
    private var startupWatchdog: Task<Void, Never>?
    private var switchWatchdog: Task<Void, Never>?
    private var lifecycleWatchdog: Task<Void, Never>?

    private var failedAtByModelID: [VersionedModelID: Date] = [:]
    private var unsupportedModelIDs: Set<VersionedModelID> = []
    private var sweepFailedAtByVersion: [String: Date] = [:]
    private var transientVersion: String?

    private var activeWorkspacePath: String?
    private var total = 0
    private var done = 0
    private var loaded = 0
    private var failed = 0
    private var unsupported = 0
    private var isTerminating = false

    init(
        client: any OhMyPiThinkingCapabilitySweepClient,
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        statusStore: OhMyPiThinkingCapabilityProbeStatusStore = .shared,
        limits: OhMyPiThinkingSweepLimits = OhMyPiThinkingSweepLimits(),
        runtimeVersion: @escaping @Sendable () -> String? = {
            OhMyPiRuntimeVersionRegistry.shared.currentVersion
        },
        isAvailable: @escaping @Sendable () -> Bool = {
            OhMyPiConnectionAvailability.isEffectivelyConnected()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.registry = registry
        self.statusStore = statusStore
        self.limits = limits
        self.runtimeVersion = runtimeVersion
        self.isAvailable = isAvailable
        self.now = now
        transientVersion = runtimeVersion()
    }

    nonisolated func state(for exactModelID: String) -> OhMyPiThinkingCapabilityProbeState {
        statusStore.state(for: exactModelID)
    }

    nonisolated var sweepStatus: OhMyPiThinkingSweepStatus {
        statusStore.sweep
    }

    nonisolated func requestAfterExplicitSelection(
        exactModelID: String,
        workspacePath: String? = nil
    ) {
        Task {
            _ = await requestPriority(
                exactModelID: exactModelID,
                workspacePath: workspacePath,
                manual: false
            )
        }
    }

    nonisolated func requestManualRetry(
        exactModelID: String,
        workspacePath: String? = nil
    ) {
        Task {
            _ = await requestPriority(
                exactModelID: exactModelID,
                workspacePath: workspacePath,
                manual: true
            )
        }
    }

    @discardableResult
    func requestSweep(_ request: OhMyPiThinkingSweepRequest) async -> Outcome {
        guard request.isLocal, isAvailable(), !isTerminating else { return .cancelled }
        await registry.warmStandardStoreIfNeeded()
        adoptCurrentVersion()

        if isSweepCoolingDown() {
            return .cooldownSkipped
        }

        let targets = OhMyPiThinkingSweepTargets.compute(
            wireIDs: request.wireIDs,
            selectedRawModel: request.selectedRawModel,
            recentlyInvalidated: registry.recentlyInvalidatedIDs()
        )
        if isCleaningUp {
            let requested = targets.filter {
                deferredBackgroundSet.contains($0) || shouldAcceptBackground($0)
            }
            guard !requested.isEmpty else { return .cached }
            for modelID in requested {
                removeDeferred(modelID)
                appendCleanupEntry(.init(
                    modelID: modelID,
                    workspacePath: request.workspacePath,
                    isBackground: true
                ))
            }
            nextPassRequested = true
            return .enqueued
        }

        if sweepTask == nil {
            let requested = targets.filter {
                deferredBackgroundSet.contains($0) || shouldAcceptBackground($0)
            }
            guard !requested.isEmpty else { return .cached }
            let ordered = uniqueIDs(requested + deferredBackgroundIDs)
            deferredBackgroundIDs.removeAll()
            deferredBackgroundSet.removeAll()
            admitBackgroundPass(ordered, workspacePath: request.workspacePath)
            guard !activeQueue.isEmpty else { return .cached }
            startRunIfNeeded(workspacePath: request.workspacePath)
            return .enqueued
        }

        let eligible = targets.filter { shouldAcceptBackground($0) }
        guard !eligible.isEmpty else { return .enqueued }
        for modelID in eligible {
            if backgroundPassIDs.count < limits.maxBackgroundTargets {
                backgroundPassIDs.insert(modelID)
                activeQueue.append(.init(
                    modelID: modelID,
                    workspacePath: request.workspacePath,
                    isBackground: true
                ))
                total += 1
                statusStore.set(.queued, for: modelID)
            } else {
                appendDeferred(modelID)
            }
        }
        publishRunning(current: reservedEntry?.modelID)
        return .enqueued
    }

    @discardableResult
    func requestPriority(
        exactModelID: String,
        workspacePath: String?,
        manual: Bool
    ) async -> Outcome {
        guard let modelID = normalizedModelID(exactModelID), !isTerminating else {
            return .failed
        }
        await registry.warmStandardStoreIfNeeded()
        adoptCurrentVersion()

        if isCached(modelID) {
            clearTransientState(for: modelID)
            return .cached
        }
        if reservedEntry?.modelID == modelID { return .coalesced }

        if let index = activeQueue.firstIndex(where: { $0.modelID == modelID }) {
            let entry = activeQueue.remove(at: index)
            activeQueue.insert(.init(
                modelID: modelID,
                workspacePath: workspacePath ?? entry.workspacePath,
                isBackground: false
            ), at: 0)
            backgroundPassIDs.remove(modelID)
            statusStore.set(.queued, for: modelID)
            return .enqueued
        }

        if !manual, isModelCoolingDown(modelID) {
            return .cooldownSkipped
        }
        guard isAvailable() else { return .cancelled }
        if manual {
            removeCooldownAndUnsupported(for: modelID)
        }

        removeDeferred(modelID)
        if isCleaningUp {
            appendCleanupEntry(.init(
                modelID: modelID,
                workspacePath: workspacePath,
                isBackground: false
            ), atFront: true)
            return .enqueued
        }

        let entry = QueueEntry(
            modelID: modelID,
            workspacePath: workspacePath,
            isBackground: false
        )
        if sweepTask == nil {
            activeQueue.insert(entry, at: 0)
            total = 1
            statusStore.set(.queued, for: modelID)
            startRunIfNeeded(workspacePath: workspacePath)
        } else {
            activeQueue.insert(entry, at: 0)
            total += 1
            statusStore.set(.queued, for: modelID)
            publishRunning(current: reservedEntry?.modelID)
        }
        return .enqueued
    }

    @discardableResult
    func resolve(
        exactModelID: String,
        workspacePath: String?,
        manualRetry: Bool
    ) async -> Outcome {
        await requestPriority(
            exactModelID: exactModelID,
            workspacePath: workspacePath,
            manual: manualRetry
        )
    }

    func cancel(reason: OhMyPiThinkingSweepCancellationReason) async {
        if reason == .appTermination {
            isTerminating = true
        }
        guard sweepTask != nil else {
            clearActivePass(returnBackgroundToDeferred: false)
            statusStore.setSweep(.cancelled(reason: reason))
            return
        }
        transitionToTerminal(
            .cancelled(reason),
            generation: runGeneration,
            cancelTask: true
        )
        await sweepTask?.value
    }

    private func startRunIfNeeded(workspacePath: String?) {
        guard sweepTask == nil, !activeQueue.isEmpty, !isTerminating else { return }
        runGeneration &+= 1
        let generation = runGeneration
        activeWorkspacePath = workspacePath ?? activeQueue.first?.workspacePath
        isCleaningUp = false
        statusStore.setSweep(.preflight)
        cancelStartupWatchdog()
        let seconds = limits.startupSeconds
        startupWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
            } catch {
                return
            }
            await self?.startupDeadlineFired(generation: generation)
        }
        sweepTask = Task { [weak self] in
            guard let self else { return }
            await runClient(generation: generation)
        }
    }

    private func runClient(generation: UInt64) async {
        let client = client
        let limits = limits
        let workspacePath = activeWorkspacePath
        do {
            try await client.run(
                workspacePath: workspacePath,
                limits: limits,
                nextTarget: { [weak self] in
                    await self?.nextTarget(generation: generation)
                },
                report: { [weak self] event in
                    await self?.handle(event, generation: generation)
                }
            )
            await finishRun(generation: generation, error: nil)
        } catch {
            await finishRun(generation: generation, error: error)
        }
    }

    private func nextTarget(generation: UInt64) -> String? {
        guard generation == runGeneration, !isCleaningUp else { return nil }
        while !activeQueue.isEmpty {
            let entry = activeQueue.removeFirst()
            if isCached(entry.modelID) {
                statusStore.set(.idle, for: entry.modelID)
                backgroundPassIDs.remove(entry.modelID)
                done += 1
                loaded += 1
                continue
            }
            if entry.isBackground, !shouldRemainInActivePass(entry.modelID) {
                backgroundPassIDs.remove(entry.modelID)
                statusStore.set(.idle, for: entry.modelID)
                continue
            }
            reservedEntry = entry
            return entry.modelID
        }
        return nil
    }

    private func handle(_ event: OhMyPiThinkingSweepEvent, generation: UInt64) {
        guard generation == runGeneration, sweepTask != nil else { return }
        switch event {
        case let .bootstrapped(version):
            guard !isCleaningUp else { return }
            cancelStartupWatchdog()
            adoptVersion(version)
            replaceLifecycleWatchdog(generation: generation, version: version)
            publishRunning(current: reservedEntry?.modelID)

        case let .willSwitch(modelID):
            guard !isCleaningUp, reservedEntry?.modelID == modelID else { return }
            switchGeneration &+= 1
            let token = switchGeneration
            statusStore.set(.loading, for: modelID)
            publishRunning(current: modelID)
            replaceSwitchWatchdog(
                generation: generation,
                switchGeneration: token,
                modelID: modelID
            )

        case let .switched(modelID, result, _):
            guard !isCleaningUp, reservedEntry?.modelID == modelID else { return }
            cancelSwitchWatchdog()
            reservedEntry = nil
            done += 1
            switch result {
            case .loaded, .cached:
                loaded += 1
                clearTransientState(for: modelID)
            case .unsupported:
                unsupported += 1
                if let key = versionedKey(modelID) {
                    unsupportedModelIDs.insert(key)
                }
                statusStore.set(.unsupported, for: modelID)
            case .failed:
                failed += 1
                if let key = versionedKey(modelID) {
                    failedAtByModelID[key] = now()
                }
                statusStore.set(.failed, for: modelID)
            }
            publishRunning(current: nil)

        case let .terminal(terminal):
            transitionToTerminal(terminal, generation: generation, cancelTask: false)
        }
    }

    private func transitionToTerminal(
        _ terminal: OhMyPiThinkingSweepTerminal,
        generation: UInt64,
        cancelTask: Bool
    ) {
        guard generation == runGeneration, sweepTask != nil, !isCleaningUp else { return }
        isCleaningUp = true
        cancelAllWatchdogs()

        if let reserved = reservedEntry {
            let reachedLoading = statusStore.state(for: reserved.modelID) == .loading
            let shouldFail = switch terminal {
            case .sessionFatal:
                true
            case .workBudgetExpired:
                reachedLoading
            case let .cancelled(reason):
                reason == .startupDeadline || reason == .switchDeadline
            default:
                false
            }
            if shouldFail {
                if statusStore.state(for: reserved.modelID) != .failed {
                    failed += 1
                }
                if let key = versionedKey(reserved.modelID) {
                    failedAtByModelID[key] = now()
                }
                statusStore.set(.failed, for: reserved.modelID)
            } else {
                statusStore.set(.idle, for: reserved.modelID)
            }
            if reserved.isBackground {
                appendDeferred(reserved.modelID)
            }
            backgroundPassIDs.remove(reserved.modelID)
            reservedEntry = nil
        }

        for entry in activeQueue {
            statusStore.set(.idle, for: entry.modelID)
            if entry.isBackground {
                appendDeferred(entry.modelID)
            }
        }
        activeQueue.removeAll()
        backgroundPassIDs.removeAll()

        switch terminal {
        case .completed:
            if deferredBackgroundSet.isEmpty {
                statusStore.setSweep(.completed(
                    loaded: loaded,
                    failed: failed,
                    unsupported: unsupported,
                    at: now()
                ))
            } else {
                statusStore.setSweep(.partial(
                    loaded: loaded,
                    deferred: deferredBackgroundSet.count
                ))
            }
        case let .preflightFailed(reason), let .bootstrapFailed(reason):
            setSweepCooldownForCurrentVersion()
            statusStore.setSweep(.failed(reason: reason, at: now()))
        case let .cancelled(reason):
            if reason == .startupDeadline {
                setSweepCooldownForCurrentVersion()
                statusStore.setSweep(.failed(
                    reason: "Oh My Pi thinking-level startup timed out.",
                    at: now()
                ))
            } else if reason == .switchDeadline {
                statusStore.setSweep(.failed(
                    reason: "Oh My Pi thinking-level model switch timed out.",
                    at: now()
                ))
            } else {
                statusStore.setSweep(.cancelled(reason: reason))
            }
        case let .sessionFatal(_, reason):
            statusStore.setSweep(.failed(reason: reason, at: now()))
        case .workBudgetExpired:
            statusStore.setSweep(.partial(
                loaded: loaded,
                deferred: deferredBackgroundSet.count
            ))
        }

        if cancelTask {
            sweepTask?.cancel()
        }
    }

    private func finishRun(generation: UInt64, error: Error?) async {
        guard generation == runGeneration else { return }
        if !isCleaningUp {
            let fallback: OhMyPiThinkingSweepTerminal = if let abort = error as? OhMyPiThinkingSweepAbort,
                                                           case let .terminal(terminal) = abort
            {
                terminal
            } else if let error {
                .sessionFatal(current: reservedEntry?.modelID, reason: error.localizedDescription)
            } else {
                .completed
            }
            transitionToTerminal(fallback, generation: generation, cancelTask: false)
        }

        sweepTask = nil
        isCleaningUp = false
        activeWorkspacePath = nil
        total = 0
        done = 0
        loaded = 0
        failed = 0
        unsupported = 0

        let cleanupEntries = cleanupQueue
        cleanupQueue.removeAll()
        let requestedNextPass = nextPassRequested
        nextPassRequested = false

        let interactive = cleanupEntries.filter { !$0.isBackground }
        let background = uniqueIDs(
            cleanupEntries.filter(\.isBackground).map(\.modelID) + deferredBackgroundIDs
        )
        deferredBackgroundIDs.removeAll()
        deferredBackgroundSet.removeAll()

        if let firstInteractive = interactive.first, !isTerminating {
            let workspace = firstInteractive.workspacePath ?? cleanupEntries.first?.workspacePath
            admitBackgroundPass(background, workspacePath: workspace)
            for entry in interactive.reversed() {
                activeQueue.insert(entry, at: 0)
                total += 1
                statusStore.set(.queued, for: entry.modelID)
            }
            startRunIfNeeded(workspacePath: workspace)
        } else if requestedNextPass, !isTerminating {
            let workspace = cleanupEntries.first?.workspacePath
            admitBackgroundPass(background, workspacePath: workspace)
            startRunIfNeeded(workspacePath: workspace)
        } else {
            deferredBackgroundIDs = background
            deferredBackgroundSet = Set(background)
        }
    }

    private func admitBackgroundPass(_ ids: [String], workspacePath: String?) {
        let unique = uniqueIDs(ids).filter { shouldAcceptBackground($0) }
        let admitted = Array(unique.prefix(limits.maxBackgroundTargets))
        let overflow = Array(unique.dropFirst(admitted.count))
        deferredBackgroundIDs = overflow
        deferredBackgroundSet = Set(overflow)
        activeQueue = admitted.map {
            QueueEntry(modelID: $0, workspacePath: workspacePath, isBackground: true)
        }
        backgroundPassIDs = Set(admitted)
        total = admitted.count
        done = 0
        loaded = 0
        failed = 0
        unsupported = 0
        for modelID in admitted {
            statusStore.set(.queued, for: modelID)
        }
        for modelID in overflow {
            statusStore.set(.idle, for: modelID)
        }
    }

    private func clearActivePass(returnBackgroundToDeferred: Bool) {
        if let reserved = reservedEntry {
            statusStore.set(.idle, for: reserved.modelID)
            if returnBackgroundToDeferred, reserved.isBackground {
                appendDeferred(reserved.modelID)
            }
        }
        for entry in activeQueue {
            statusStore.set(.idle, for: entry.modelID)
            if returnBackgroundToDeferred, entry.isBackground {
                appendDeferred(entry.modelID)
            }
        }
        reservedEntry = nil
        activeQueue.removeAll()
        backgroundPassIDs.removeAll()
    }

    private func appendDeferred(_ modelID: String) {
        guard deferredBackgroundSet.insert(modelID).inserted else { return }
        deferredBackgroundIDs.append(modelID)
    }

    private func removeDeferred(_ modelID: String) {
        guard deferredBackgroundSet.remove(modelID) != nil else { return }
        deferredBackgroundIDs.removeAll { $0 == modelID }
    }

    private func appendCleanupEntry(_ entry: QueueEntry, atFront: Bool = false) {
        guard !containsAnywhere(entry.modelID) else {
            if !entry.isBackground,
               let index = cleanupQueue.firstIndex(where: { $0.modelID == entry.modelID })
            {
                let existing = cleanupQueue.remove(at: index)
                cleanupQueue.insert(.init(
                    modelID: existing.modelID,
                    workspacePath: entry.workspacePath ?? existing.workspacePath,
                    isBackground: false
                ), at: 0)
            }
            return
        }
        if atFront {
            cleanupQueue.insert(entry, at: 0)
        } else {
            cleanupQueue.append(entry)
        }
        statusStore.set(.queued, for: entry.modelID)
    }

    private func containsAnywhere(_ modelID: String) -> Bool {
        reservedEntry?.modelID == modelID ||
            activeQueue.contains(where: { $0.modelID == modelID }) ||
            deferredBackgroundSet.contains(modelID) ||
            cleanupQueue.contains(where: { $0.modelID == modelID })
    }

    private func shouldAcceptBackground(_ modelID: String) -> Bool {
        guard !containsAnywhere(modelID), !isCached(modelID) else { return false }
        if let key = versionedKey(modelID), unsupportedModelIDs.contains(key) {
            return false
        }
        return !isModelCoolingDown(modelID)
    }

    private func shouldRemainInActivePass(_ modelID: String) -> Bool {
        guard !isCached(modelID) else { return false }
        if let key = versionedKey(modelID), unsupportedModelIDs.contains(key) {
            return false
        }
        return !isModelCoolingDown(modelID)
    }

    private func isCached(_ modelID: String) -> Bool {
        guard let version = runtimeVersion() else { return false }
        return registry.snapshot(for: modelID)?.ompVersion == version
    }

    private func isModelCoolingDown(_ modelID: String) -> Bool {
        guard let key = versionedKey(modelID),
              let failedAt = failedAtByModelID[key]
        else { return false }
        return now().timeIntervalSince(failedAt) < limits.sweepFailureCooldown
    }

    private func isSweepCoolingDown() -> Bool {
        let key = runtimeVersion() ?? "<unknown>"
        guard let failedAt = sweepFailedAtByVersion[key] else { return false }
        return now().timeIntervalSince(failedAt) < limits.sweepFailureCooldown
    }

    private func setSweepCooldownForCurrentVersion() {
        sweepFailedAtByVersion[runtimeVersion() ?? "<unknown>"] = now()
    }

    private func clearTransientState(for modelID: String) {
        if let key = versionedKey(modelID) {
            failedAtByModelID.removeValue(forKey: key)
            unsupportedModelIDs.remove(key)
        }
        statusStore.set(.idle, for: modelID)
    }

    private func removeCooldownAndUnsupported(for modelID: String) {
        failedAtByModelID = failedAtByModelID.filter { $0.key.modelID != modelID }
        unsupportedModelIDs = unsupportedModelIDs.filter { $0.modelID != modelID }
    }

    private func adoptCurrentVersion() {
        adoptVersion(runtimeVersion())
    }

    private func adoptVersion(_ version: String?) {
        guard transientVersion != version else { return }
        let staleIDs = Set(failedAtByModelID.keys.map(\.modelID))
            .union(unsupportedModelIDs.map(\.modelID))
        transientVersion = version
        if let version {
            failedAtByModelID = failedAtByModelID.filter { $0.key.version == version }
            unsupportedModelIDs = unsupportedModelIDs.filter { $0.version == version }
            sweepFailedAtByVersion = sweepFailedAtByVersion.filter { $0.key == version }
        } else {
            failedAtByModelID.removeAll()
            unsupportedModelIDs.removeAll()
            sweepFailedAtByVersion.removeAll()
        }
        for modelID in staleIDs where !containsAnywhere(modelID) {
            statusStore.set(.idle, for: modelID)
        }
    }

    private func versionedKey(_ modelID: String) -> VersionedModelID? {
        guard let version = runtimeVersion(), !version.isEmpty else { return nil }
        return VersionedModelID(modelID: modelID, version: version)
    }

    private func normalizedModelID(_ value: String) -> String? {
        let modelID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              modelID.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }
        return modelID
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func publishRunning(current: String?) {
        statusStore.setSweep(.running(done: done, total: total, current: current))
    }

    private func startupDeadlineFired(generation: UInt64) {
        guard generation == runGeneration,
              sweepTask != nil,
              !isCleaningUp,
              statusStore.sweep == .preflight
        else { return }
        transitionToTerminal(
            .cancelled(.startupDeadline),
            generation: generation,
            cancelTask: true
        )
    }

    private func replaceSwitchWatchdog(
        generation: UInt64,
        switchGeneration: UInt64,
        modelID: String
    ) {
        cancelSwitchWatchdog()
        let seconds = limits.perSwitchSeconds
        switchWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
            } catch {
                return
            }
            await self?.switchDeadlineFired(
                generation: generation,
                switchGeneration: switchGeneration,
                modelID: modelID
            )
        }
    }

    private func switchDeadlineFired(
        generation: UInt64,
        switchGeneration token: UInt64,
        modelID: String
    ) {
        guard generation == runGeneration,
              token == switchGeneration,
              reservedEntry?.modelID == modelID,
              !isCleaningUp
        else { return }
        transitionToTerminal(
            .cancelled(.switchDeadline),
            generation: generation,
            cancelTask: true
        )
    }

    private func replaceLifecycleWatchdog(generation: UInt64, version: String) {
        lifecycleWatchdog?.cancel()
        lifecycleWatchdog = nil
        lifecycleWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard await self?.lifecycleCheck(
                    generation: generation,
                    version: version
                ) == true else { return }
            }
        }
    }

    private func lifecycleCheck(generation: UInt64, version: String) -> Bool {
        guard generation == runGeneration, !isCleaningUp else { return false }
        if !isAvailable() {
            transitionToTerminal(
                .cancelled(.availabilityLost),
                generation: generation,
                cancelTask: true
            )
            return false
        }
        if runtimeVersion() != version {
            adoptCurrentVersion()
            transitionToTerminal(
                .cancelled(.runtimeVersionChanged),
                generation: generation,
                cancelTask: true
            )
            return false
        }
        return true
    }

    private func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func cancelSwitchWatchdog() {
        switchWatchdog?.cancel()
        switchWatchdog = nil
    }

    private func cancelAllWatchdogs() {
        cancelStartupWatchdog()
        cancelSwitchWatchdog()
        lifecycleWatchdog?.cancel()
        lifecycleWatchdog = nil
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}

enum OhMyPiThinkingSelectionProbeTrigger {
    #if DEBUG
        private static let testingStateLock = NSLock()
        private static var disabledForTesting = false

        static var isDisabledForTesting: Bool {
            get { testingStateLock.withLock { disabledForTesting } }
            set { testingStateLock.withLock { disabledForTesting = newValue } }
        }
    #endif

    static func afterExplicitSelection(
        of model: AIModel,
        workspacePath: String? = nil,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        guard let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: model) else { return }
        resolver.requestAfterExplicitSelection(
            exactModelID: exactModelID,
            workspacePath: workspacePath
        )
    }

    static func afterExplicitSelection(
        agent: AgentProviderKind,
        rawModel: String,
        workspacePath: String? = nil,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        guard agent == .ohMyPi,
              let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: rawModel)
        else { return }
        resolver.requestAfterExplicitSelection(
            exactModelID: exactModelID,
            workspacePath: workspacePath
        )
    }
}

enum OhMyPiThinkingSweepTrigger {
    #if DEBUG
        static var isDisabledForTesting: Bool {
            get { OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting }
            set { OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = newValue }
        }
    #endif

    static func onProviderSubmenuOpen(
        wireIDs: [String],
        selectedRawModel: String?,
        workspacePath: String?,
        isLocal: Bool = true,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        let targets = OhMyPiThinkingSweepTargets.compute(
            wireIDs: wireIDs,
            selectedRawModel: selectedRawModel,
            recentlyInvalidated: OhMyPiThinkingCapabilityRegistry.shared.recentlyInvalidatedIDs()
        )
        guard !targets.isEmpty else { return }
        Task {
            _ = await resolver.requestSweep(.init(
                wireIDs: targets,
                selectedRawModel: selectedRawModel,
                workspacePath: workspacePath,
                isLocal: isLocal
            ))
        }
    }
}
