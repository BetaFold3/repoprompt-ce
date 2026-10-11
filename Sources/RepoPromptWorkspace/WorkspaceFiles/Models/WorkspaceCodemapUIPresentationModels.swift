import Foundation

package struct WorkspaceCodemapUIPresentationEntry: Equatable {
    let presentationID: UUID
    package let fileID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    package let logicalPath: WorkspaceCodemapLogicalPresentationPath
    package let text: String
    let tokenCount: Int

    init(
        presentationID: UUID,
        fileID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        logicalPath: WorkspaceCodemapLogicalPresentationPath,
        text: String,
        tokenCount: Int
    ) {
        self.presentationID = presentationID
        self.fileID = fileID
        self.rootEpoch = rootEpoch
        self.logicalPath = logicalPath
        self.text = text
        self.tokenCount = tokenCount
    }

    init(
        presentationID: UUID,
        renderedEntry: WorkspaceCodemapOperationRenderedEntry
    ) {
        self.presentationID = presentationID
        fileID = renderedEntry.fileID
        rootEpoch = renderedEntry.rootEpoch
        logicalPath = renderedEntry.logicalPath
        text = renderedEntry.text
        tokenCount = renderedEntry.tokenCount
    }
}

package struct WorkspaceCodemapUIPresentationSnapshot: Equatable {
    let presentationID: UUID
    package let orderedEntries: [WorkspaceCodemapUIPresentationEntry]
    package let entriesByFileID: [UUID: WorkspaceCodemapUIPresentationEntry]
    package let coverage: WorkspaceCodemapOperationPresentationCoverage
    package let issues: [WorkspaceCodemapOperationIssue]

    package init(_ presentation: WorkspaceCodemapOperationPresentation) {
        presentationID = presentation.id
        orderedEntries = presentation.orderedEntries.map {
            WorkspaceCodemapUIPresentationEntry(
                presentationID: presentation.id,
                renderedEntry: $0
            )
        }
        entriesByFileID = Dictionary(
            uniqueKeysWithValues: orderedEntries.map { ($0.fileID, $0) }
        )
        coverage = presentation.coverage
        issues = presentation.issues
    }

    package static var empty: WorkspaceCodemapUIPresentationSnapshot {
        WorkspaceCodemapUIPresentationSnapshot(.empty)
    }
}

package enum WorkspaceCodemapUIPreviewDisposition: Equatable {
    case ready(WorkspaceCodemapUIPresentationEntry)
    case unavailable(
        coverage: WorkspaceCodemapOperationPresentationCoverage,
        issues: [WorkspaceCodemapOperationIssue]
    )
    case revoked
}
