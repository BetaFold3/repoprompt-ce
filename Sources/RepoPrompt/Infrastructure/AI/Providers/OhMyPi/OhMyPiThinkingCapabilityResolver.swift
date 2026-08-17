import Foundation

extension Notification.Name {
    static let ohMyPiThinkingCapabilityProbeStateDidChange = Notification.Name(
        "RepoPrompt.ohMyPiThinkingCapabilityProbeStateDidChange"
    )
}

enum OhMyPiThinkingCapabilityProbeState: Equatable {
    case idle
    case loading
    case failed
}

final class OhMyPiThinkingCapabilityProbeStatusStore: @unchecked Sendable {
    static let shared = OhMyPiThinkingCapabilityProbeStatusStore()

    private let lock = NSLock()
    private var statesByModelID: [String: OhMyPiThinkingCapabilityProbeState] = [:]

    func state(for exactModelID: String) -> OhMyPiThinkingCapabilityProbeState {
        lock.lock()
        defer { lock.unlock() }
        return statesByModelID[exactModelID] ?? .idle
    }

    func set(_ state: OhMyPiThinkingCapabilityProbeState, for exactModelID: String) {
        lock.lock()
        let previous = statesByModelID[exactModelID] ?? .idle
        if state == .idle {
            statesByModelID.removeValue(forKey: exactModelID)
        } else {
            statesByModelID[exactModelID] = state
        }
        lock.unlock()
        guard previous != state else { return }
        NotificationCenter.default.post(
            name: .ohMyPiThinkingCapabilityProbeStateDidChange,
            object: self,
            userInfo: ["modelID": exactModelID]
        )
    }
}

protocol OhMyPiThinkingCapabilityProbeClient: Sendable {
    func probe(exactModelID: String, workspacePath: String?) async throws
}

struct OhMyPiThinkingCapabilityControllerProbeClient: OhMyPiThinkingCapabilityProbeClient {
    typealias ProviderFactory = @Sendable (OhMyPiAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = @Sendable (
        any ACPAgentProvider,
        ACPRunRequest,
        @escaping OhMyPiThinkingCapabilityPublisher
    ) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    private let registry: OhMyPiThinkingCapabilityRegistry

    init(
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        providerFactory: @escaping ProviderFactory = { OhMyPiACPAgentProvider(config: $0) },
        controllerFactory: @escaping ControllerFactory = { provider, request, publisher in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                dynamicModelPublicationPolicy: .capabilityOnly,
                ohMyPiThinkingCapabilityPublisher: publisher
            )
        }
    ) {
        self.registry = registry
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func probe(exactModelID: String, workspacePath: String?) async throws {
        let config = OhMyPiAgentConfig(
            modelString: nil,
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false
        )
        let request = ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let provider = providerFactory(config)
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Oh My Pi ACP is not available."
            )
        }

        if let version = OhMyPiRuntimeVersionRegistry.shared.currentVersion,
           registry.snapshot(for: exactModelID)?.ompVersion == version
        {
            return
        }

        let registry = registry
        let controller = try controllerFactory(provider, request) { record in
            _ = registry.record(record)
        }
        do {
            _ = try await controller.bootstrap()
            try Task.checkCancellation()
            try await controller.setSessionModel(exactModelID)
            guard let version = OhMyPiRuntimeVersionRegistry.shared.currentVersion,
                  registry.snapshot(for: exactModelID)?.ompVersion == version
            else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Oh My Pi did not advertise thinking levels for model '\(exactModelID)'."
                )
            }
            await Self.shutdownOutsideCancellationSensitiveScope(controller)
        } catch {
            await Self.shutdownOutsideCancellationSensitiveScope(controller)
            throw provider.normalizeError(error)
        }
    }

    private static func shutdownOutsideCancellationSensitiveScope(
        _ controller: ACPAgentSessionController
    ) async {
        await runCancellationShielded {
            await controller.shutdown()
        }
    }

    private static func runCancellationShielded(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        await Task.detached(priority: .utility, operation: operation).value
    }

    #if DEBUG
        static func testRunCancellationShieldedShutdown(
            _ operation: @escaping @Sendable () async -> Void
        ) async {
            await runCancellationShielded(operation)
        }
    #endif
}

actor OhMyPiThinkingCapabilityResolver {
    enum Outcome: Equatable {
        case cached
        case loaded
        case coalesced
        case busySkipped
        case cooldownSkipped
        case failed
    }

    static let shared = OhMyPiThinkingCapabilityResolver(
        client: OhMyPiThinkingCapabilityControllerProbeClient()
    )

    private enum DeadlineResult {
        case probeCompleted
        case timedOut
    }

    private struct DeadlineExceeded: Error {}

    private let client: any OhMyPiThinkingCapabilityProbeClient
    private let registry: OhMyPiThinkingCapabilityRegistry
    nonisolated let statusStore: OhMyPiThinkingCapabilityProbeStatusStore
    private let deadlineNanoseconds: UInt64
    private let cooldown: TimeInterval
    private let runtimeVersion: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var busyModelID: String?
    private var failedAtByModelID: [String: Date] = [:]

    init(
        client: any OhMyPiThinkingCapabilityProbeClient,
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        statusStore: OhMyPiThinkingCapabilityProbeStatusStore = .shared,
        deadlineNanoseconds: UInt64 = 8_000_000_000,
        cooldown: TimeInterval = 60,
        runtimeVersion: @escaping @Sendable () -> String? = {
            OhMyPiRuntimeVersionRegistry.shared.currentVersion
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.registry = registry
        self.statusStore = statusStore
        self.deadlineNanoseconds = deadlineNanoseconds
        self.cooldown = cooldown
        self.runtimeVersion = runtimeVersion
        self.now = now
    }

    nonisolated func state(for exactModelID: String) -> OhMyPiThinkingCapabilityProbeState {
        statusStore.state(for: exactModelID)
    }

    nonisolated func requestAfterExplicitSelection(
        exactModelID: String,
        workspacePath: String? = nil
    ) {
        Task {
            _ = await resolve(
                exactModelID: exactModelID,
                workspacePath: workspacePath,
                manualRetry: false
            )
        }
    }

    nonisolated func requestManualRetry(
        exactModelID: String,
        workspacePath: String? = nil
    ) {
        Task {
            _ = await resolve(
                exactModelID: exactModelID,
                workspacePath: workspacePath,
                manualRetry: true
            )
        }
    }

    @discardableResult
    func resolve(
        exactModelID: String,
        workspacePath: String?,
        manualRetry: Bool
    ) async -> Outcome {
        let modelID = exactModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              modelID.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return .failed
        }

        await registry.warmStandardStoreIfNeeded()
        if let currentVersion = runtimeVersion(),
           registry.snapshot(for: modelID)?.ompVersion == currentVersion
        {
            failedAtByModelID.removeValue(forKey: modelID)
            statusStore.set(.idle, for: modelID)
            return .cached
        }

        if let busyModelID {
            return busyModelID == modelID ? .coalesced : .busySkipped
        }

        if !manualRetry,
           let failedAt = failedAtByModelID[modelID],
           now().timeIntervalSince(failedAt) < cooldown
        {
            return .cooldownSkipped
        }

        busyModelID = modelID
        statusStore.set(.loading, for: modelID)
        defer { busyModelID = nil }

        do {
            try await runWithDeadline(modelID: modelID, workspacePath: workspacePath)
            failedAtByModelID.removeValue(forKey: modelID)
            statusStore.set(.idle, for: modelID)
            return .loaded
        } catch is CancellationError {
            statusStore.set(.failed, for: modelID)
            return .failed
        } catch {
            failedAtByModelID[modelID] = now()
            statusStore.set(.failed, for: modelID)
            return .failed
        }
    }

    private func runWithDeadline(modelID: String, workspacePath: String?) async throws {
        let client = client
        let deadlineNanoseconds = deadlineNanoseconds
        try await withThrowingTaskGroup(of: DeadlineResult.self) { group in
            group.addTask {
                try await client.probe(exactModelID: modelID, workspacePath: workspacePath)
                return .probeCompleted
            }
            group.addTask {
                try await Task.sleep(nanoseconds: deadlineNanoseconds)
                return .timedOut
            }
            guard let first = try await group.next() else {
                throw DeadlineExceeded()
            }
            group.cancelAll()
            switch first {
            case .probeCompleted:
                return
            case .timedOut:
                throw DeadlineExceeded()
            }
        }
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
