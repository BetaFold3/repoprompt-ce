import Foundation

// SEARCH-HELPER: AgentPreviewDocumentPicker, preview document picker, previewable file inventory

/// One previewable file offered by the workspace index.
///
/// A narrow input type rather than `WorkspaceFileRecord`: the picker only needs a root, a path, and
/// a date, and taking the workspace record would force every ordering test to build file IDs and
/// parent folders that have nothing to do with the ordering being tested.
struct AgentPreviewCandidateFile: Equatable {
    let rootID: UUID
    /// Root-relative, forward-slashed.
    let relativePath: String
    let modifiedAt: Date?

    init(rootID: UUID, relativePath: String, modifiedAt: Date? = nil) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
    }
}

/// A row in the picker.
struct AgentPreviewPickerEntry: Equatable, Identifiable {
    let reference: PreviewDocumentReference
    let rootName: String
    let kind: AgentSessionArtifactKind
    /// True when this document was written by an agent in this session, which is why it sorts
    /// above the repository's own documents.
    let isSessionArtifact: Bool
    let modifiedAt: Date?

    var id: String {
        "\(reference.rootID.uuidString)#\(reference.relativePath)"
    }

    var fileName: String {
        reference.fileName
    }

    var relativePath: String {
        reference.relativePath
    }

    /// The directory part, for the dimmed second line of a row. Empty at the root.
    var directoryPath: String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? rootName : "\(rootName)/\(directory)"
    }
}

/// Builds and filters the Preview segment's document list.
///
/// Pure by construction: it is handed inventories and returns rows, so the ordering rules — session
/// artifacts before repository documents, most recently modified first — are testable without a
/// workspace, an index, or a transcript.
enum AgentPreviewDocumentPicker {
    /// Assembles the offered documents.
    ///
    /// - Parameters:
    ///   - artifacts: documents an agent wrote this session, newest first, already decoded.
    ///   - files: previewable files from the workspace index.
    ///   - roots: the roots those references resolve against, for display names.
    ///   - context: used to map an artifact's on-disk path back to a root-relative reference.
    static func entries(
        artifacts: [AgentSessionArtifact] = [],
        files: [AgentPreviewCandidateFile] = [],
        context: AgentPreviewResolutionContext
    ) -> [AgentPreviewPickerEntry] {
        var seen = Set<String>()
        var entries: [AgentPreviewPickerEntry] = []

        for artifact in artifacts {
            guard let reference = reference(forPath: artifact.path, in: context) else { continue }
            guard let root = context.root(id: reference.rootID) else { continue }
            let entry = AgentPreviewPickerEntry(
                reference: reference,
                rootName: root.displayName,
                kind: artifact.kind,
                isSessionArtifact: true,
                modifiedAt: artifact.createdAt
            )
            guard seen.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }

        var workspaceEntries: [AgentPreviewPickerEntry] = []
        for file in files {
            guard let root = context.root(id: file.rootID) else { continue }
            let fileExtension = (file.relativePath as NSString).pathExtension
            guard let kind = AgentSessionArtifactKind(fileExtension: fileExtension) else { continue }
            let reference = PreviewDocumentReference(
                rootID: file.rootID,
                relativePath: file.relativePath
            )
            let entry = AgentPreviewPickerEntry(
                reference: reference,
                rootName: root.displayName,
                kind: kind,
                isSessionArtifact: false,
                modifiedAt: file.modifiedAt
            )
            guard seen.insert(entry.id).inserted else { continue }
            workspaceEntries.append(entry)
        }

        // Most recently touched first: in a repository with hundreds of documents, the one worth
        // reading is nearly always the one something just changed. Undated files sort last rather
        // than jumping to the top, and the path tiebreak keeps the order stable between refreshes.
        workspaceEntries.sort { left, right in
            switch (left.modifiedAt, right.modifiedAt) {
            case let (lhs?, rhs?) where lhs != rhs:
                lhs > rhs
            case (nil, .some):
                false
            case (.some, nil):
                true
            default:
                left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
            }
        }

        entries.append(contentsOf: workspaceEntries)
        return entries
    }

    /// Narrows the list to a search query, best match first.
    ///
    /// Ranking is deliberately simple and explainable: a file whose name starts with the query
    /// beats one that merely contains it, which beats one matched only somewhere in its directory
    /// path. Within a rank the input order survives, so the recency ordering above still shows
    /// through and session artifacts stay on top of an equally good repository match.
    static func filter(_ entries: [AgentPreviewPickerEntry], query: String) -> [AgentPreviewPickerEntry] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return entries }

        return entries
            .enumerated()
            .compactMap { index, entry -> (rank: Int, index: Int, entry: AgentPreviewPickerEntry)? in
                guard let rank = rank(entry, matching: needle) else { return nil }
                return (rank, index, entry)
            }
            .sorted { left, right in
                left.rank == right.rank ? left.index < right.index : left.rank < right.rank
            }
            .map(\.entry)
    }

    private static func rank(_ entry: AgentPreviewPickerEntry, matching needle: String) -> Int? {
        let fileName = normalized(entry.fileName)
        if fileName.hasPrefix(needle) { return 0 }
        if fileName.contains(needle) { return 1 }
        if normalized(entry.relativePath).contains(needle) { return 2 }
        if normalized(entry.rootName).contains(needle) { return 3 }
        return nil
    }

    /// Case- and diacritic-insensitive, so `[[cafe]]`-style typing finds `Café.md`.
    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Path mapping

    /// Maps a path an edit tool reported onto a root-relative reference.
    ///
    /// Tool payloads carry the path the agent used — absolute inside its own checkout, or relative
    /// to the checkout it was launched in — while `PreviewDocumentReference` is deliberately a root
    /// ID plus a relative path. Matching against each root's *checkout* rather than its logical
    /// path is what makes a document an agent wrote inside a worktree addressable at all. Longest
    /// matching checkout wins, so a root nested inside another root claims its own files.
    static func reference(
        forPath rawPath: String,
        in context: AgentPreviewResolutionContext
    ) -> PreviewDocumentReference? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath

        guard expanded.hasPrefix("/") else {
            // Relative: the only defensible reading is "inside one of the checkouts we know".
            // Ambiguity is resolved by taking the first root whose checkout actually holds it.
            let relative = (expanded as NSString).standardizingPath
            for root in context.roots {
                let checkout = context.checkoutRootPath(forRootPath: root.path)
                let candidate = URL(fileURLWithPath: checkout).appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                return PreviewDocumentReference(rootID: root.id, relativePath: relative)
            }
            return nil
        }

        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        var best: (rootID: UUID, relativePath: String)?
        for root in context.roots {
            let checkout = context.checkoutRootPath(forRootPath: root.path)
            guard let relative = relativePath(of: standardized, under: checkout) else { continue }
            if let current = best, current.relativePath.count <= relative.count { continue }
            best = (root.id, relative)
        }
        guard let best else { return nil }
        return PreviewDocumentReference(rootID: best.rootID, relativePath: best.relativePath)
    }

    private static func relativePath(of path: String, under directory: String) -> String? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}
