import Foundation
import RepoPromptWorkspace

extension CodeMapExtractor {
    static func generateFileTreeForRoots(
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        maxDepth: Int?,
        includeHidden: Bool, // Note: This parameter is now ignored; visibility is handled by RepoPrompt
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool = true,
        isExplicitSubtree: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        if option == .none { return "" }
        let mode = switch option {
        case .none: "none"
        case .selected: "selected"
        case .files: "full"
        case .auto: "auto"
        }
        return generateFileTreeForRoots(
            rootFolders: rootFolders,
            mode: mode,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            isExplicitSubtree: isExplicitSubtree,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }

    @inline(__always)
    private static func codeMapRootInfos(from rootFolders: [FolderViewModel]) -> [RootInfo] {
        rootFolders.map {
            RootInfo(
                standardizedRootFullPath: $0.standardizedFullPath,
                displayName: ($0.standardizedFullPath as NSString).lastPathComponent
            )
        }
    }

    /// Returns the set of `FolderViewModel.id` that lie on the path to at least one selected file.
    static func folderIDsContainingSelectedFiles(
        rootFolder: FolderViewModel,
        selectedFileIDs: Set<UUID>
    ) -> Set<UUID> {
        var result = Set<UUID>()
        var visited = Set<UUID>()

        @discardableResult
        func dfs(_ folder: FolderViewModel) -> Bool {
            if Task.isCancelled { return false }
            if !visited.insert(folder.id).inserted { return false }
            var contains = false
            for child in folder.children {
                if Task.isCancelled { return false }
                switch child {
                case let .file(file):
                    if selectedFileIDs.contains(file.id) { contains = true }
                case let .folder(subfolder):
                    if dfs(subfolder) { contains = true }
                }
            }
            if contains { result.insert(folder.id) }
            return contains
        }

        _ = dfs(rootFolder)
        return result
    }

    /// Builds a file tree limited to a subset of files identified by absolute full paths.
    static func generateFileTreeForSubsetFiles(
        rootFolders: [FolderViewModel],
        subsetFullPaths: Set<String>,
        filePathDisplay: FilePathDisplay,
        includeLegend: Bool = false,
        codeMapAvailableFullPaths: Set<String> = [],
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard !subsetFullPaths.isEmpty, !rootFolders.isEmpty else { return "" }
        let roots = codeMapRootInfos(from: rootFolders)
        return generateFileTreeForSubsetPaths(
            roots: roots,
            subsetFullPaths: subsetFullPaths,
            filePathDisplay: filePathDisplay,
            selectedMarkAll: true,
            codeMapAvailableFullPaths: codeMapAvailableFullPaths,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }

    // MARK: - Convenience API for FileTreeOption (existing usage)

    /// Converts FileTreeOption enum to string mode for unified implementation.
    static func generateFileTreeForRoots(
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool = true,
        isExplicitSubtree: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        if option == .none { return "" }

        // Preserve legacy behavior: no explicit depth cap and includeHidden = true.
        return generateFileTreeForRoots(
            rootFolders: rootFolders,
            option: option,
            maxDepth: nil,
            includeHidden: true,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }
}
