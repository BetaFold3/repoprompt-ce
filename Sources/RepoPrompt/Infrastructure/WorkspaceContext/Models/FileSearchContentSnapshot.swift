import Foundation

/// Snapshot of file content plus a stable in-memory revision for search cache identity.
struct FileSearchContentSnapshot {
    let content: String?
    let contentRevision: UInt64?
    let modificationDate: Date
    let isFresh: Bool
}
