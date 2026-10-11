import Foundation
import RepoPromptWorkspace

/// Workspace-specific customization overrides for a copy preset
/// These allow per-workspace deviations from the base preset configuration
struct CopyCustomizations: Equatable {
    /// Meta prompts selection
    var selectedPromptIDs: [UUID]?

    // Content configuration overrides
    var fileTreeMode: FileTreeOption?
    var codeMapUsage: CodeMapUsage?
    var gitInclusion: GitInclusion?

    // Include flags overrides
    var includeFiles: Bool?
    var includeUserPrompt: Bool?
    var includeMetaPrompts: Bool?
    var includeFileTree: Bool?

    // MARK: - Initializer

    init(
        selectedPromptIDs: [UUID]? = nil,
        fileTreeMode: FileTreeOption? = nil,
        codeMapUsage: CodeMapUsage? = nil,
        gitInclusion: GitInclusion? = nil,
        includeFiles: Bool? = nil,
        includeUserPrompt: Bool? = nil,
        includeMetaPrompts: Bool? = nil,
        includeFileTree: Bool? = nil
    ) {
        self.selectedPromptIDs = selectedPromptIDs
        self.fileTreeMode = fileTreeMode
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.includeFiles = includeFiles
        self.includeUserPrompt = includeUserPrompt
        self.includeMetaPrompts = includeMetaPrompts
        self.includeFileTree = includeFileTree
    }

    /// Check if any customizations are present
    var hasCustomizations: Bool {
        selectedPromptIDs != nil ||
            fileTreeMode != nil ||
            codeMapUsage != nil ||
            gitInclusion != nil ||
            includeFiles != nil ||
            includeUserPrompt != nil ||
            includeMetaPrompts != nil ||
            includeFileTree != nil
    }

    /// Clear all customizations
    mutating func clear() {
        selectedPromptIDs = nil
        fileTreeMode = nil
        codeMapUsage = nil
        gitInclusion = nil
        includeFiles = nil
        includeUserPrompt = nil
        includeMetaPrompts = nil
        includeFileTree = nil
    }

    /// Returns a copy with only the codemap usage override cleared.
    /// Used to collapse legacy Manual-mode duplicate state while preserving
    /// all other customization fields.
    func removingCodeMapUsageOverride() -> CopyCustomizations {
        var copy = self
        copy.codeMapUsage = nil
        return copy
    }
}

// MARK: - Codable Conformance

extension CopyCustomizations: Codable {
    enum CodingKeys: String, CodingKey {
        case selectedPromptIDs
        case fileTreeMode
        case codeMapUsage
        case gitInclusion
        case includeFiles
        case includeUserPrompt
        case includeMetaPrompts
        case includeFileTree
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedPromptIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedPromptIDs)

        fileTreeMode = try container.decodeIfPresent(FileTreeOption.self, forKey: .fileTreeMode)
        codeMapUsage = try container.decodeIfPresent(CodeMapUsage.self, forKey: .codeMapUsage)
        gitInclusion = try container.decodeIfPresent(GitInclusion.self, forKey: .gitInclusion)
        includeFiles = try container.decodeIfPresent(Bool.self, forKey: .includeFiles)
        includeUserPrompt = try container.decodeIfPresent(Bool.self, forKey: .includeUserPrompt)
        includeMetaPrompts = try container.decodeIfPresent(Bool.self, forKey: .includeMetaPrompts)
        includeFileTree = try container.decodeIfPresent(Bool.self, forKey: .includeFileTree)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedPromptIDs, forKey: .selectedPromptIDs)
        try container.encodeIfPresent(fileTreeMode, forKey: .fileTreeMode)
        try container.encodeIfPresent(codeMapUsage, forKey: .codeMapUsage)
        try container.encodeIfPresent(gitInclusion, forKey: .gitInclusion)
        try container.encodeIfPresent(includeFiles, forKey: .includeFiles)
        try container.encodeIfPresent(includeUserPrompt, forKey: .includeUserPrompt)
        try container.encodeIfPresent(includeMetaPrompts, forKey: .includeMetaPrompts)
        try container.encodeIfPresent(includeFileTree, forKey: .includeFileTree)
    }
}
