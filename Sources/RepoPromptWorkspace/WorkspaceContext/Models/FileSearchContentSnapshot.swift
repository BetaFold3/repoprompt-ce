import Foundation

/// Snapshot of file content plus a stable in-memory revision for search cache identity.
package struct FileSearchContentSnapshot {
    package let content: String?
    let contentRevision: UInt64?
    let modificationDate: Date
    let isFresh: Bool

    package init(
        content: String?,
        contentRevision: UInt64?,
        modificationDate: Date,
        isFresh: Bool
    ) {
        self.content = content
        self.contentRevision = contentRevision
        self.modificationDate = modificationDate
        self.isFresh = isFresh
    }
}
