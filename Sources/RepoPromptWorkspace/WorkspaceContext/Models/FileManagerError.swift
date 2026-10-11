import Foundation

package enum FileManagerError: Error, LocalizedError {
    case failedToLoadFolder(Error)
    case failedToLoadFile(Error)
    case fileSystemServiceNotFound
    case failedToLoadContent
    // New: richer, contextual variant used by MCP tools and FS ops
    case fileSystemServiceNotFoundWithContext(String)

    package var errorDescription: String? {
        switch self {
        case let .failedToLoadFolder(err):
            "Failed to load folder: \(err.localizedDescription)"
        case let .failedToLoadFile(err):
            "Failed to load file: \(err.localizedDescription)"
        case .fileSystemServiceNotFound:
            "No matching workspace folder for the requested path."
        case .failedToLoadContent:
            "Failed to load content."
        case let .fileSystemServiceNotFoundWithContext(context):
            context
        }
    }
}
