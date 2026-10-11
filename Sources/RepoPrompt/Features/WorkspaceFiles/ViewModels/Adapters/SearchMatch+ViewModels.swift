import Foundation
import RepoPromptWorkspace

extension FileSearchActor {
    /// Enhanced search with full options support (backward compatibility)
    func search(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        var autoCorrected: Bool? = nil
        return try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files
        )
    }

    /// Unified search combining path and content search with full SearchOptions support (backward compatibility)
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        // Entry point for MCP tool integration

        var autoCorrected: Bool? = nil
        return try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            aliasByRootPath: aliasByRootPath
        )
    }
}

extension SearchFileDescriptor {
    init(file: FileViewModel) {
        self.init(
            id: file.id,
            name: file.name,
            relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath,
            fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath,
            standardizedRootFolderPath: file.standardizedRootFolderPath,
            fileExtension: file.fileExtension,
            contentSnapshot: { policy in
                await file.searchContentSnapshot(freshnessPolicy: policy)
            }
        )
    }
}

extension FileSearchActor {
    /// Enhanced search with full options support and auto-correction reporting
    func search(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: options,
            in: files.map(SearchFileDescriptor.init(file:))
        )
    }

    /// Finds file paths that match the supplied `pattern`.
    /// Supports shell wild-cards (`*`, `?`) **or full regular-expressions** when
    /// `isRegex == true`.
    /// Results are returned as *absolute* file paths, up to `limit` items.
    ///
    /// Matching is performed only against repo-relative paths (e.g. `"Assets/Foo.cs"`)
    /// and optional alias-prefixed forms (`"RootAlias/Assets/Foo.cs"`).
    /// Absolute OS paths (`"/Users/..."`) are intentionally *not* matched here;
    /// absolute path resolution is handled via `WorkspaceFilesViewModel`/`PathMatchWorker`.
    ///
    /// **Return values are canonical absolute paths** (`standardizedFullPath`) for
    /// downstream identity, deduplication, and display formatting via `mcpDisplayPath`.
    ///
    /// The work is fanned-out in parallel – similar to the grep implementation.
    func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [FileViewModel],
        caseInsensitive: Bool = true,
        isRegex: Bool = false, // ← NEW
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        try await searchPaths(
            pattern: pattern,
            limit: limit,
            in: files.map(SearchFileDescriptor.init(file:)),
            caseInsensitive: caseInsensitive,
            isRegex: isRegex,
            aliasByRootPath: aliasByRootPath
        )
    }

    /// Unified search combining path and content search with full SearchOptions support and auto-correction reporting
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: options,
            in: files.map(SearchFileDescriptor.init(file:)),
            aliasByRootPath: aliasByRootPath
        )
    }
}
