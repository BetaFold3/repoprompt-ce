import Foundation

struct ApplyEditsApprovalScope: Hashable {
    let windowID: Int
    let tabID: UUID
}

struct PendingApplyEditsReview: Identifiable, Hashable {
    let id: UUID
    let scope: ApplyEditsApprovalScope
    let path: String
    let unifiedDiff: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.createdAt = createdAt
    }
}
