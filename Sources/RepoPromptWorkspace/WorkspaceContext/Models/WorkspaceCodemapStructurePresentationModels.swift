import Foundation

package struct WorkspaceCodemapStructureOutputLimits: Equatable {
    let maximumFileCount: Int
    let maximumCodemapTokenCount: Int

    package init(maximumFileCount: Int, maximumCodemapTokenCount: Int) {
        precondition(maximumFileCount > 0)
        precondition(maximumCodemapTokenCount >= 0)
        self.maximumFileCount = maximumFileCount
        self.maximumCodemapTokenCount = maximumCodemapTokenCount
    }
}

package enum WorkspaceCodemapStructureOutcome: String, Equatable {
    case ready
    case partial
    case pending
    case busy
    case timeout
    case unavailable
    case stale
    case budget
}

package enum WorkspaceCodemapStructureIssue: Equatable {
    case candidate(WorkspaceCodemapOperationCandidateIssue)
    case artifactPending(fileID: UUID, ticket: WorkspaceCodemapArtifactDemandTicket)
    case artifactUnavailable(fileID: UUID, reason: WorkspaceCodemapArtifactDemandUnavailableReason)
    case traversalPartial(WorkspaceCodemapStructureTraversalPartialReason)
    case traversalPending(WorkspaceCodemapStructureTraversalPendingReason)
    case traversalUnavailable(WorkspaceCodemapStructureTraversalUnavailableReason)
    case traversalStale(WorkspaceCodemapStructureTraversalStaleReason)
    case traversalBudget(WorkspaceCodemapStructureTraversalBudgetReason)
    case busy(retryAfterMilliseconds: Int)
    case readinessTimeout(
        elapsedMilliseconds: Int,
        limitMilliseconds: Int,
        retryAfterMilliseconds: Int
    )
    case projectionUnavailable(
        reason: WorkspaceCodemapProjectionDemandUnavailableReason,
        retryAfterMilliseconds: Int?
    )
    case projectionBudget(WorkspaceCodemapProjectionBudget)
    case freezeUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationFreezeUnavailableReason
    )
    case renderUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationRenderUnavailableReason
    )
    case fileLimit(attempted: Int, limit: Int)
    case seedDemandLimit(attempted: Int, limit: Int)
    case tokenLimit(path: String, attempted: Int, limit: Int)
    case publicationStale(WorkspaceCodemapStructurePublicationStaleReason)
}

package struct WorkspaceCodemapStructureRenderedEntry: Equatable {
    package let entry: WorkspaceCodemapOperationRenderedEntry
    package let isSeed: Bool
    package let depth: Int
    package let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

package struct WorkspaceCodemapStructurePresentation: Equatable {
    package let outcome: WorkspaceCodemapStructureOutcome
    package let entries: [WorkspaceCodemapStructureRenderedEntry]
    package let issues: [WorkspaceCodemapStructureIssue]
    package let requestedSeedCount: Int
    package let resolvedSeedCount: Int
    package let examinedEdgeCount: Int
    package let codemapTokenCount: Int

    static func stale(
        _ reason: WorkspaceCodemapStructurePublicationStaleReason,
        requestedSeedCount: Int
    ) -> Self {
        Self(
            outcome: .stale,
            entries: [],
            issues: [.publicationStale(reason)],
            requestedSeedCount: requestedSeedCount,
            resolvedSeedCount: 0,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )
    }
}
