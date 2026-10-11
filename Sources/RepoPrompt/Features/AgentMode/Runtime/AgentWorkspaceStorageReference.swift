import Foundation

/// The workspace identity and storage location that agent session persistence
/// reads: the workspace ID, its name, and an optional custom storage root.
protocol AgentWorkspaceStorageReference {
    var id: UUID { get }
    var name: String { get }
    var customStoragePath: URL? { get }
}
