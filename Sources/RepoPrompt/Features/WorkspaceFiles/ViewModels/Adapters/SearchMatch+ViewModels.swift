import Foundation

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
