import Foundation

// MARK: - VCS Index Path Identity

/// Identifies one working-tree change for an index mutation.
///
/// A rename or copy occupies two repository-relative paths at once: the path Git
/// reports today and the path the content came from. Staging only one of them
/// leaves a half-recorded rename in the index, so callers pass both together and
/// the backend applies them as a single pathspec set.
public struct VCSIndexPathIdentity: Hashable, Sendable {
    /// The current repository-relative path.
    public let path: String

    /// The repository-relative path the content was renamed or copied from, if any.
    public let originalPath: String?

    /// Whether an index mutation must include ``originalPath``.
    ///
    /// Renames mutate both paths because the source disappears. Copies only mutate the destination;
    /// including their source would stage unrelated edits to the file that was copied.
    public let includesOriginalPathInMutation: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        includesOriginalPathInMutation: Bool = true
    ) {
        self.path = path
        self.originalPath = originalPath
        self.includesOriginalPathInMutation = includesOriginalPathInMutation
    }

    /// Every repository-relative path this identity covers for diff detection, current path first.
    public var allPaths: [String] {
        guard let originalPath, originalPath != path else { return [path] }
        return [path, originalPath]
    }

    /// The exact paths an index mutation is allowed to send to Git.
    public var mutationPaths: [String] {
        guard includesOriginalPathInMutation else { return [path] }
        return allPaths
    }
}

// MARK: - VCS Index Status Entry

/// One path's index and working-tree state, projected from a detailed status read.
///
/// This is the stable shape the changes panel consumes; it deliberately mirrors
/// the porcelain-v2 record fields rather than inventing values, so a status
/// character is `nil` exactly when the underlying record has none (untracked
/// paths carry no XY pair).
public struct VCSIndexStatusEntry: Equatable, Sendable {
    /// The current repository-relative path.
    public let path: String

    /// The repository-relative path the content was renamed or copied from, if any.
    public let originalPath: String?

    /// The index (staged) status character, or nil when the record carries no XY pair.
    public let indexStatus: Character?

    /// The working-tree (unstaged) status character, or nil when the record carries no XY pair.
    public let workTreeStatus: Character?

    /// Whether Git reports this path as untracked.
    public let isUntracked: Bool

    /// Whether Git reports this path as unmerged (conflicted).
    public let isConflicted: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        indexStatus: Character? = nil,
        workTreeStatus: Character? = nil,
        isUntracked: Bool = false,
        isConflicted: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
    }

    /// The path identity to pass back into a stage or unstage request.
    public var identity: VCSIndexPathIdentity {
        let isCopy = indexStatus == "C" || workTreeStatus == "C"
        return VCSIndexPathIdentity(
            path: path,
            originalPath: originalPath,
            includesOriginalPathInMutation: !isCopy
        )
    }

    /// Whether the index differs from HEAD for this path.
    public var hasStagedChange: Bool {
        guard let indexStatus else { return false }
        return indexStatus != "." && indexStatus != "?"
    }

    /// Whether the working tree differs from the index for this path.
    /// Untracked paths carry no XY pair but always represent a working-tree change.
    public var hasWorkTreeChange: Bool {
        if isUntracked { return true }
        guard let workTreeStatus else { return false }
        return workTreeStatus != "." && workTreeStatus != "?"
    }
}

// MARK: - Index Status Projection

extension VCSIndexStatusEntry {
    /// Project detailed status entries from already-parsed porcelain-v2 records.
    ///
    /// Ignored records are dropped: they describe files Git deliberately excludes,
    /// not changes that can be staged. Record order is preserved so callers keep
    /// Git's own ordering.
    static func project(_ records: [GitPorcelainV2PathRecord]) -> [VCSIndexStatusEntry] {
        records.compactMap(VCSIndexStatusEntry.init(porcelainRecord:))
    }

    /// Project one porcelain-v2 record, or nil when the record carries no stageable change.
    init?(porcelainRecord record: GitPorcelainV2PathRecord) {
        let originalPath: String?
        switch record.kind {
        case .ignored:
            return nil
        case let .renamedOrCopied(recordedOriginalPath, _):
            originalPath = recordedOriginalPath
        case .ordinary, .unmerged, .untracked:
            originalPath = nil
        }
        self.init(
            path: record.path,
            originalPath: originalPath,
            indexStatus: record.indexStatus,
            workTreeStatus: record.workTreeStatus,
            isUntracked: record.kind == .untracked,
            isConflicted: record.kind == .unmerged
        )
    }
}

// MARK: - VCS Index Mutation Backend Protocol

/// Optional protocol for backends that own a mutable index (staging area).
///
/// Deliberately separate from `VCSBackend`: Jujutsu has no index, so it never
/// conforms and never needs a throwing no-op. Resolve conformance through
/// `VCSService.indexMutationBackend(forRepoRoot:)` and gate UI on
/// `VCSCapabilities.supportsStaging` rather than casting at call sites.
///
/// Phase 1 is file-level only. Per-hunk staging is a separate, later capability.
public protocol VCSIndexMutationBackend: VCSBackend {
    /// Read detailed per-path index and working-tree status.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: One entry per changed, untracked, or conflicted path, in Git's order.
    func loadIndexStatus(at repoURL: URL) async throws -> [VCSIndexStatusEntry]

    /// Stage the given path identities, including rename origins but never copy sources.
    /// - Parameters:
    ///   - identities: The path identities to stage. An empty request is a no-op.
    ///   - repoURL: The repository root URL.
    func stage(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws

    /// Unstage the given path identities, leaving working-tree contents untouched.
    /// - Parameters:
    ///   - identities: The path identities to unstage. An empty request is a no-op.
    ///   - repoURL: The repository root URL.
    func unstage(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws

    /// Record one conflicted path's current contents in the index as its resolution.
    /// Distinct from ordinary staging so callers never overload a staging checkbox with this action.
    func markResolved(_ identity: VCSIndexPathIdentity, at repoURL: URL) async throws

    /// Check whether HEAD resolves to a commit.
    /// Unstaging in a repository with an unborn HEAD needs a different command,
    /// so callers that surface unborn-repository states can probe it directly.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: True when HEAD points at an existing commit.
    func hasHeadCommit(at repoURL: URL) async throws -> Bool
}

// MARK: - Git Index Mutation Error

/// Errors that can occur while mutating a Git index.
enum GitIndexMutationError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidPath(String)
    case invalidStatusEncoding
    case indexLocked
    case gitRefused(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        case let .invalidPath(path):
            "Invalid repository-relative path for staging: \(path)"
        case .invalidStatusEncoding:
            "Git status contains a filename that is not valid UTF-8; this path cannot be staged safely."
        case .indexLocked:
            "Another Git process is using this repository's index. Wait for it to finish and try again."
        case let .gitRefused(message):
            GitService.friendlyErrorDescription(for: message)
        }
    }
}
