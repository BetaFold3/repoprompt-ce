import Foundation

/// Narrow seam for store-backed search: waits for and validates the issuing
/// workspace's search readiness ticket without depending on the workspace view model.
package protocol WorkspaceSearchReadinessProviding: Sendable {
    @MainActor
    func awaitWorkspaceSearchReadiness(
        timeout: Duration
    ) async throws -> WorkspaceSearchReadinessTicket

    func validateWorkspaceSearchReadinessSnapshot(
        _ ticket: WorkspaceSearchReadinessTicket
    ) throws
}
