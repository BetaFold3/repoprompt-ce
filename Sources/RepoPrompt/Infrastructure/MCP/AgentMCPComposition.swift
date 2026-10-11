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
