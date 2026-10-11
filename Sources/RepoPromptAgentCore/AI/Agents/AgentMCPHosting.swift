import Foundation
import MCP

/// The MCP server capabilities the agent runtime uses. The App's MCP server
/// actor implements it; runtime objects receive that instance through their initializers.
package protocol AgentMCPHosting: Sendable {
    func isRunning() async -> Bool

    func hasAuthoritativeLiveRunRoute(runID: UUID, expectedClientName: String) async -> Bool

    func waitForNewConnection(clientName: String?, timeout: TimeInterval) async -> UUID?

    func registerExpectedAgentPID(
        _ pid: pid_t,
        for clientName: String,
        runID: UUID?,
        expectedProcessExecutablePath: String?,
        expectedProcessExecutableIdentity: ExecutableFileIdentity?
    ) async

    func clearExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID?) async

    func requireExpectedAgentPIDForPendingPolicy(for clientName: String, runID: UUID, windowID: Int?) async -> Bool

    // swiftlint:disable:next function_parameter_count
    func installClientConnectionPolicy(
        for clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool,
        reason: String?,
        ttl: TimeInterval,
        tabID: UUID?,
        runID: UUID?,
        additionalTools: Set<String>?,
        allowedToolsOverride: Set<String>?,
        sessionProfile: AgentSessionProfile,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool,
        requiresExpectedAgentPID: Bool
    ) async

    func clearClientConnectionPolicy(for clientName: String, windowID: Int?, runID: UUID?) async

    func revokeClientConnectionPolicy(for clientName: String, windowID: Int, runID: UUID) async

    func registerToolEventObserver(
        for runID: UUID,
        onCalled: @escaping @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void,
        onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?,
        observationPolicy: AgentToolTrackingObservationPolicy
    ) async -> UUID

    func unregisterToolEventObserver(for runID: UUID, token: UUID) async

    func unregisterToolObservers(for runID: UUID) async

    #if DEBUG
        func debugRecordRunRoutingEvent(runID: UUID, event: String, connectionID: UUID?, fields: [String: String]) async
    #endif
}
