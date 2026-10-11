import Foundation

struct WorkspaceCodemapStructureTraversalQuery: Hashable {
    let seeds: [WorkspaceCodemapStoreSelectionGraphSourceIdentity]
    let direction: WorkspaceCodemapStructureTraversalDirection
    let limits: WorkspaceCodemapStructureTraversalLimits
}

struct WorkspaceCodemapStructureTraversalNode: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
    let depth: Int
    let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

package enum WorkspaceCodemapStructureTraversalPartialReason: Hashable {
    case definitionUniverseIncomplete(WorkspaceCodemapRootEpoch)
    case referenceFailuresPresent(WorkspaceCodemapRootEpoch)
}

struct WorkspaceCodemapStructureTraversalRootReceipt: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let graphKey: WorkspaceCodemapSelectionGraphRuntimeKey
    let seeds: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let nodes: [WorkspaceCodemapSelectionGraphRuntimeStructureNode]
    let examinedEdgeCount: Int
}

struct WorkspaceCodemapStructureTraversalPublicationReceipt: Hashable {
    let query: WorkspaceCodemapStructureTraversalQuery
    let roots: [WorkspaceCodemapStructureTraversalRootReceipt]
}

struct WorkspaceCodemapStructureTraversalResult: Hashable {
    let nodes: [WorkspaceCodemapStructureTraversalNode]
    let examinedEdgeCount: Int
    let partialReasons: Set<WorkspaceCodemapStructureTraversalPartialReason>
    let referenceFailures: [WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord]
    let publicationReceipt: WorkspaceCodemapStructureTraversalPublicationReceipt
}

package enum WorkspaceCodemapStructureTraversalPendingReason: Hashable {
    case graphRebuilding(WorkspaceCodemapRootEpoch)
    case graphBusy(WorkspaceCodemapRootEpoch)
}

package enum WorkspaceCodemapStructureTraversalUnavailableReason: Hashable {
    case emptySeeds
    case foreignRootEpoch(UUID)
    case duplicateSeedConflict(UUID)
    case seedNotReady(UUID)
    case graphNotBuilt(WorkspaceCodemapRootEpoch)
    case invalidGraphResult(WorkspaceCodemapRootEpoch)
    case definitionUniverse(
        rootEpoch: WorkspaceCodemapRootEpoch,
        coverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    )
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

package enum WorkspaceCodemapStructureTraversalStaleReason: Hashable {
    case rootEpoch(WorkspaceCodemapRootEpoch)
    case graph(WorkspaceCodemapRootEpoch)
    case seed(WorkspaceCodemapArtifactDemandTicket)
}

package enum WorkspaceCodemapStructureTraversalBudgetReason: Hashable {
    case rootLimit(attempted: Int, limit: Int)
    case nodeLimit(attempted: Int, limit: Int)
    case edgeLimit(attempted: Int, limit: Int)
    case byteLimit(attempted: Int, limit: Int)
    case accountingOverflow
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        dimension: WorkspaceCodemapSelectionGraphRuntimeStructureBudgetDimension
    )
}

enum WorkspaceCodemapStructureTraversalDisposition: Hashable {
    case readyPartial(WorkspaceCodemapStructureTraversalResult)
    case pending(WorkspaceCodemapStructureTraversalPendingReason)
    case unavailable(WorkspaceCodemapStructureTraversalUnavailableReason)
    case stale(WorkspaceCodemapStructureTraversalStaleReason)
    case budget(WorkspaceCodemapStructureTraversalResult?, WorkspaceCodemapStructureTraversalBudgetReason)
    case cancelled
}

struct WorkspaceCodemapStructurePublicationReceipt: Equatable {
    let presentation: WorkspaceCodemapOperationPresentationPublicationReceipt
    let traversal: WorkspaceCodemapStructureTraversalPublicationReceipt?
    let outputFileIDs: [UUID]
}

package enum WorkspaceCodemapStructurePublicationStaleReason: Equatable {
    case presentation(WorkspaceCodemapOperationPublicationStaleReason)
    case traversal(WorkspaceCodemapStructureTraversalStaleReason)
    case output
}

enum WorkspaceCodemapStructurePublicationDisposition: Equatable {
    case current
    case stale(WorkspaceCodemapStructurePublicationStaleReason)
}
