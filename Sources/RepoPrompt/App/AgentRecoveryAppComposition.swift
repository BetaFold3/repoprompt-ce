import Foundation
import RepoPromptAgentCore

/// Lossless-restart production composition (spec R8, Phase 1b final cutover): exactly one recovery
/// store, the shared `AgentSessionDataService` gated by it, one recovery coordinator, and the
/// shared scheduled-send coordinator, injected into every window's Agent Mode view model with
/// mandatory admission before that view model hydrates anything.
///
/// Startup order: the scheduler is created closed (`.awaitingRecovery`) before any host
/// registers; the coordinator captures the previous launch mark, writes this launch's running
/// mark, inventories every workspace, reconciles each session under its DataService gate,
/// publishes results, crash holds, and scoped restrictions, reports ready, and only then is
/// scheduler admission opened. A global failure (unreadable workspace index, launch mark, or
/// discovery) keeps both closed until Retry succeeds. Startup constructs no provider, controller,
/// or view model, never awaits its own barrier, and never replays or resumes anything.
///
/// XCTest processes do not compose production recovery (`AgentRecoveryStore.production` is nil):
/// windows are constructed by the hundreds there and the real workspace index must never be read
/// or rewritten. Tests inject temporary compositions through `init` instead.
@MainActor
final class AgentRecoveryAppComposition {
    typealias InventoryLoader = @Sendable () throws -> AgentRecoveryWorkspaceInventory

    let scheduler: AgentScheduledSendCoordinator
    /// `nil` when composition is inactive or failed.
    let coordinator: AgentRecoveryCoordinator?
    /// Why composition failed; mandatory admission then stays fail-closed (no permissive fallback).
    let failure: String?
    /// Whether this composition selects mandatory recovery for the windows it installs into.
    let isActive: Bool
    private var startupTask: Task<Void, Never>?

    /// - Parameters:
    ///   - store: the single recovery store; `nil` leaves recovery inactive (legacy behavior).
    ///   - dataService: must be configured with `store` (the coordinator validates it).
    ///   - scheduler: the shared scheduler; closed here before any host can register.
    init(
        store: AgentRecoveryStore?,
        dataService: AgentSessionDataService,
        scheduler: AgentScheduledSendCoordinator,
        loadInventory: @escaping InventoryLoader
    ) {
        self.scheduler = scheduler
        guard let store else {
            coordinator = nil
            failure = nil
            isActive = false
            return
        }
        isActive = true
        scheduler.closeStartupAdmission()
        scheduler.dispatchingRecordsRequireTransferResolution = true
        do {
            coordinator = try AgentRecoveryCoordinator(
                store: store,
                dataService: dataService,
                reconcile: { report in
                    let inventory = try await Task.detached(priority: .userInitiated) {
                        try loadInventory()
                    }.value
                    return await AgentRecoveryStartupSweep.run(
                        inventory: inventory,
                        entries: report.discovered,
                        dataService: dataService
                    )
                }
            )
            failure = nil
        } catch {
            coordinator = nil
            failure = String(describing: error)
            scheduler.failStartupAdmission("Recovery could not be composed: \(error)")
        }
    }

    /// The app's composition: production store and DataService outside XCTest, inactive inside.
    static let shared = AgentRecoveryAppComposition(
        store: AgentRecoveryStore.production,
        dataService: .shared,
        scheduler: AgentScheduledSendCoordinator(
            startupAdmission: AgentRecoveryStore.production == nil ? .open : .awaitingRecovery
        ),
        loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory() }
    )

    /// Installs recovery into a freshly created view model, before it hydrates any session or
    /// observes its first draft, then starts startup once. Inactive compositions install nothing.
    func install(into viewModel: AgentModeViewModel) {
        guard isActive else { return }
        if let coordinator {
            viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
            viewModel.recoveryStartupRetry = { [weak self] in self?.retryStartup() }
        } else {
            viewModel.failRecoveryComposition(failure ?? "unknown composition failure")
        }
        startIfNeeded()
    }

    func startIfNeeded() {
        guard let coordinator, startupTask == nil else { return }
        coordinator.startIfNeeded()
        startupTask = Task { [weak self] in
            await self?.releaseSchedulerAfterStartup()
        }
    }

    /// Re-runs a failed startup; scheduler admission stays closed until it is ready.
    func retryStartup() {
        guard let coordinator, case .failed = coordinator.startupState else { return }
        scheduler.closeStartupAdmission()
        coordinator.retryStartup()
        startupTask = Task { [weak self] in
            await self?.releaseSchedulerAfterStartup()
        }
    }

    /// Step 6 of the startup order: scheduler admission follows recovery readiness.
    private func releaseSchedulerAfterStartup() async {
        guard let coordinator else { return }
        switch await coordinator.awaitStartup() {
        case .ready:
            scheduler.openStartupAdmission()
        case let .failed(message):
            scheduler.failStartupAdmission(message)
        case .notStarted, .loading:
            break
        }
    }

    /// Test observability: the task releasing the scheduler after startup.
    var startupCompletion: Task<Void, Never>? {
        startupTask
    }
}
