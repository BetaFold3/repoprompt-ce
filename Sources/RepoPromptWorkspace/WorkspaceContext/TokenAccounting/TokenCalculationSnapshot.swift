import Foundation

package struct PromptFileEntrySnapshot {
    package let fileID: UUID
    let relativePath: String
    package let isCodemapRequested: Bool
    let ranges: [LineRange]?
    let cachedFullTokenCount: Int?
    let loadedContent: String?
    package let codeMapContent: String?
    let availableCodeMapTokenCount: Int

    package init(
        fileID: UUID,
        relativePath: String,
        isCodemapRequested: Bool,
        ranges: [LineRange]?,
        cachedFullTokenCount: Int?,
        loadedContent: String?,
        codeMapContent: String?,
        availableCodeMapTokenCount: Int
    ) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.isCodemapRequested = isCodemapRequested
        self.ranges = ranges
        self.cachedFullTokenCount = cachedFullTokenCount
        self.loadedContent = loadedContent
        self.codeMapContent = codeMapContent
        self.availableCodeMapTokenCount = availableCodeMapTokenCount
    }
}

package enum TokenCalculationFileTreeInput {
    case none
    case rendered(String)
    case snapshot(FileTreeSelectionSnapshot)
}

package struct TokenCalculationSnapshot {
    let promptText: String
    let selectedInstructionsText: String
    let duplicateUserInstructionsAtTop: Bool
    let promptEntries: [PromptFileEntrySnapshot]
    let fileTree: TokenCalculationFileTreeInput

    package init(
        promptText: String,
        selectedInstructionsText: String,
        duplicateUserInstructionsAtTop: Bool,
        promptEntries: [PromptFileEntrySnapshot],
        fileTree: TokenCalculationFileTreeInput
    ) {
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.promptEntries = promptEntries
        self.fileTree = fileTree
    }
}
