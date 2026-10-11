import Foundation
import MCP

extension ServerNetworkManager: AgentMCPHosting {
    /// Builds the server-owned observer inside the actor so registration stays a single
    /// synchronous actor-isolated step.
    func registerToolEventObserver(
        for runID: UUID,
        onCalled: @escaping @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void,
        onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?,
        observationPolicy: AgentToolTrackingObservationPolicy
    ) -> UUID {
        registerToolEventObserver(
            for: runID,
            observer: ToolEventObserver(
                onCalled: onCalled,
                onCompleted: onCompleted,
                observationPolicy: observationPolicy
            )
        )
    }
}

extension MCPRoutingWaiter {
    static let shared = MCPRoutingWaiter(mcpHost: ServerNetworkManager.shared)
}

// MARK: - Static Async Methods (for async callers)

extension MCPRoutingWaiter {
    /// Register a runID before any routing signals are expected.
    static func register(runID: UUID) async {
        await shared.register(runID: runID)
    }

    /// Wait until the runID is routed or timeout/failure.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time to wait. If <= 0, waits indefinitely.
    static func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await shared.waitUntilRouted(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    static func waitUntilRoutedOutcome(runID: UUID, timeoutSeconds: TimeInterval) async -> WaitOutcome {
        await shared.waitUntilRoutedOutcome(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    /// Notify that a runID was successfully routed (async version).
    static func notifyRouted(runID: UUID) async {
        await shared.notifyRouted(runID: runID)
    }

    /// Notify that a runID failed to route (async version).
    static func notifyFailed(runID: UUID) async {
        await shared.notifyFailed(runID: runID)
    }

    /// Clean up state for a completed runID.
    static func cleanup(runID: UUID) async {
        await shared.cleanup(runID: runID)
    }

    #if DEBUG
        static func debugContinuationCount(runID: UUID) async -> Int {
            await shared.debugContinuationCount(runID: runID)
        }
    #endif
}

// MARK: - Fire-and-Forget Signal Methods (for sync callers)

extension MCPRoutingWaiter {
    /// Fire-and-forget routed signal to the process-wide waiter.
    nonisolated static func signalRouted(_ runID: UUID) {
        shared.signalRouted(runID)
    }

    /// Fire-and-forget failure signal to the process-wide waiter.
    nonisolated static func signalFailed(_ runID: UUID) {
        shared.signalFailed(runID)
    }
}

extension AgentRunCoordinator {
    static let shared = AgentRunCoordinator(mcpHost: ServerNetworkManager.shared, routingWaiter: .shared)
}

extension AgentRuntimeProviderService {
    static let shared = AgentRuntimeProviderService(mcpHost: ServerNetworkManager.shared, routingWaiter: .shared)
}
