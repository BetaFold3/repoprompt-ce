import AppKit
import Combine
import Foundation

/// App-wide, single-flight metadata discovery. Settings windows only observe it.
@MainActor
final class ClaudeCLIModelDiscoveryService: ObservableObject {
    static let shared = ClaudeCLIModelDiscoveryService(store: .shared)
    @Published private(set) var caption = "Claude CLI models have not been refreshed."
    @Published private(set) var isRefreshing = false

    private let store: ClaudeCLIDiscoveredModelStore
    private let probe: (CLIProcessConfiguration) async throws -> ClaudeCLIModelDiscoveryProbe.Result
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var retiringTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private struct LaunchContext: Equatable {
        let command: String
        let selection: CLICommandSelection?
        let environment: [String: String]
        let additionalPaths: [String]
        let suffix: [String]
        let candidates: [String]?
        let shellLookup: CommandPathResolver.ShellLookupMode

        init(_ config: CLIProcessConfiguration) {
            command = config.command
            selection = config.commandSelection
            environment = config.environment
            additionalPaths = config.additionalPaths
            suffix = config.commandSuffix
            candidates = config.resolveCandidates
            shellLookup = config.shellLookupMode
        }
    }

    // In-memory only; never log or persist launch environment values.
    private var context: LaunchContext?
    private var lastAttempt: Date?
    private var terminationObserver: AnyCancellable?

    init(
        store: ClaudeCLIDiscoveredModelStore,
        now: @escaping () -> Date = Date.init,
        probe: @escaping (CLIProcessConfiguration) async throws -> ClaudeCLIModelDiscoveryProbe.Result = {
            try await ClaudeCLIModelDiscoveryProbe.run(config: $0)
        }
    ) {
        self.store = store
        self.now = now
        self.probe = probe
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
    }

    func invalidate() {
        generation &+= 1
        task?.cancel()
        retiringTask = task ?? retiringTask
        task = nil
        context = nil
        lastAttempt = nil
        store.deactivate()
        isRefreshing = false
        caption = "Claude CLI models need a fresh connection check."
    }

    func refresh(config: CLIProcessConfiguration, force: Bool = false) async {
        let nextContext = LaunchContext(config)
        if context != nextContext {
            invalidate()
            context = nextContext
        }
        if let task {
            await task.value
            return
        }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 60 { return }
        let currentGeneration = generation
        lastAttempt = now()
        isRefreshing = true
        caption = "Discovering models through Claude CLI…"
        let probe = probe
        let predecessor = retiringTask
        retiringTask = nil
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            do {
                let result = try await probe(config)
                guard let self, !Task.isCancelled, generation == currentGeneration else { return }
                if let scope = result.scope { store.activate(scope: scope) }
                store.replace(modelIDs: result.modelIDs, scope: result.scope, fetchedAt: now())
                caption = result.modelIDs.isEmpty
                    ? "Claude CLI reported no supported point releases; using existing catalog entries."
                    : "\(result.modelIDs.count) versioned model(s) discovered through Claude CLI."
            } catch {
                guard let self, !Task.isCancelled, generation == currentGeneration else { return }
                if case let ClaudeCLIModelDiscoveryProbe.Failure.invalidModels(scope) = error,
                   scope == nil || store.snapshot?.scope != scope
                {
                    store.deactivate()
                }
                if case ClaudeCLIModelDiscoveryProbe.Failure.unsupportedBackend = error {
                    store.deactivate()
                    caption = "CLI model discovery requires the standard Anthropic backend."
                } else {
                    // Never expose raw subprocess errors, output, or account data.
                    caption = store.snapshot == nil
                        ? "CLI model discovery failed. Check Claude login/version and refresh."
                        : "CLI model discovery failed; keeping this connection’s last successful catalog."
                }
            }
            guard let self, generation == currentGeneration else { return }
            isRefreshing = false
            self.task = nil
        }
        self.task = task
        await task.value
    }
}
