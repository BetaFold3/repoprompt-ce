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

    /// The file mode recorded in HEAD, when porcelain carries one.
    public let headMode: String?

    /// The file mode recorded in the index, when porcelain carries one.
    public let indexMode: String?

    /// The blob object ID recorded in HEAD, when porcelain carries one.
    public let headOID: String?

    /// The blob object ID currently recorded in the index, when porcelain carries one.
    public let indexOID: String?

    /// The repository HEAD observed by the same porcelain snapshot.
    /// Unborn repositories use Git's literal `(initial)` identity.
    let repositoryHeadIdentity: String

    /// Whether this projection contains every field required for mutation identity comparison.
    let isMutationIdentityRepresentable: Bool

    /// Whether Git reports this path as untracked.
    public let isUntracked: Bool

    /// Whether Git reports this path as unmerged (conflicted).
    public let isConflicted: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        indexStatus: Character? = nil,
        workTreeStatus: Character? = nil,
        headMode: String? = nil,
        indexMode: String? = nil,
        headOID: String? = nil,
        indexOID: String? = nil,
        isUntracked: Bool = false,
        isConflicted: Bool = false,
        repositoryHeadIdentity: String = "(initial)",
        isMutationIdentityRepresentable: Bool = true
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.headMode = headMode
        self.indexMode = indexMode
        self.headOID = headOID
        self.indexOID = indexOID
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
        self.repositoryHeadIdentity = repositoryHeadIdentity
        self.isMutationIdentityRepresentable = isMutationIdentityRepresentable
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
    static func project(_ snapshot: GitStatusPorcelainV2Snapshot) -> [VCSIndexStatusEntry] {
        let repositoryHeadIdentity = snapshot.headID ?? "(initial)"
        return snapshot.pathRecords.compactMap {
            VCSIndexStatusEntry(
                porcelainRecord: $0,
                repositoryHeadIdentity: repositoryHeadIdentity
            )
        }
    }

    /// Project one porcelain-v2 record, or nil when the record carries no stageable change.
    init?(
        porcelainRecord record: GitPorcelainV2PathRecord,
        repositoryHeadIdentity: String
    ) {
        let originalPath: String?
        let isMutationIdentityRepresentable: Bool
        switch record.kind {
        case .ignored:
            return nil
        case let .renamedOrCopied(recordedOriginalPath, _):
            originalPath = recordedOriginalPath
            isMutationIdentityRepresentable = record.headMode != nil
                && record.indexMode != nil
                && record.headOID != nil
                && record.indexOID != nil
        case .ordinary:
            originalPath = nil
            isMutationIdentityRepresentable = record.headMode != nil
                && record.indexMode != nil
                && record.headOID != nil
                && record.indexOID != nil
        case .unmerged:
            originalPath = nil
            isMutationIdentityRepresentable = false
        case .untracked:
            originalPath = nil
            isMutationIdentityRepresentable = true
        }
        self.init(
            path: record.path,
            originalPath: originalPath,
            indexStatus: record.indexStatus,
            workTreeStatus: record.workTreeStatus,
            headMode: record.headMode,
            indexMode: record.indexMode,
            headOID: record.headOID,
            indexOID: record.indexOID,
            isUntracked: record.kind == .untracked,
            isConflicted: record.kind == .unmerged,
            repositoryHeadIdentity: repositoryHeadIdentity,
            isMutationIdentityRepresentable: isMutationIdentityRepresentable
        )
    }
}

// MARK: - VCS Index Mutation Authorization

/// The final authority check a backend evaluates immediately before it spawns a mutating process.
///
/// Callers fence a mutation against shutdown, retarget, and content movement before they hand it to
/// a backend, but a backend serializes mutations of one checkout: a request can then wait for an
/// unrelated mutation to finish, and the authority that approved it can be revoked while it waits.
/// Backends evaluate this hook inside that serialization, after the wait and before the command, so
/// a revoked request is refused while refusing still costs nothing.
///
/// Returning `false` must abort the mutation with a typed refusal and leave the index untouched.
public typealias VCSIndexMutationAuthorization = @Sendable () async -> Bool

// MARK: - VCS Index Mutation Backend Protocol

/// Optional protocol for backends that own a mutable index (staging area).
///
/// Deliberately separate from `VCSBackend`: Jujutsu has no index, so it never
/// conforms and never needs a throwing no-op. Resolve conformance through
/// `VCSService.indexMutationBackend(forRepoRoot:)` and gate UI on
/// `VCSCapabilities.supportsStaging` rather than casting at call sites.
///
/// File-level and byte-exact partial staging share this one serialized index-mutation seam.
public protocol VCSIndexMutationBackend: VCSBackend {
    /// Read detailed per-path index and working-tree status.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: One entry per changed, untracked, or conflicted path, in Git's order.
    func loadIndexStatus(at repoURL: URL) async throws -> [VCSIndexStatusEntry]

    /// Read detailed status for exactly the given repository-relative paths.
    /// The result uses the same porcelain-v2 projection as the full status read; clean paths are absent.
    func loadIndexStatus(
        at repoURL: URL,
        paths: [String]
    ) async throws -> [VCSIndexStatusEntry]

    /// Stage the given path identities, including rename origins but never copy sources.
    /// - Parameters:
    ///   - identities: The path identities to stage. An empty request is a no-op.
    ///   - repoURL: The repository root URL.
    ///   - authorize: Evaluated inside the backend's mutation serialization, immediately before Git
    ///     runs. A `false` result aborts without staging anything.
    func stage(
        _ identities: [VCSIndexPathIdentity],
        at repoURL: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws

    /// Unstage the given path identities, leaving working-tree contents untouched.
    /// - Parameters:
    ///   - identities: The path identities to unstage. An empty request is a no-op.
    ///   - repoURL: The repository root URL.
    ///   - authorize: Evaluated inside the backend's mutation serialization, immediately before Git
    ///     runs. A `false` result aborts without unstaging anything.
    func unstage(
        _ identities: [VCSIndexPathIdentity],
        at repoURL: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws

    /// Apply one byte-exact patch to the index, atomically and without touching the worktree.
    ///
    /// Implementations must not synthesize conflicts, reject files, or chunk the request. The
    /// caller owns preflight and the sole index-lock retry. `authorize` is evaluated inside the
    /// backend's mutation serialization, immediately before Git runs.
    func applyCachedPatch(
        _ data: Data,
        reverse: Bool,
        at repoURL: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws

    /// Record one conflicted path's current contents in the index as its resolution.
    /// Distinct from ordinary staging so callers never overload a staging checkbox with this action.
    /// `authorize` is evaluated inside the backend's mutation serialization, immediately before Git
    /// runs.
    func markResolved(
        _ identity: VCSIndexPathIdentity,
        at repoURL: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws

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
    case authorizationRevoked
    case patchDoesNotApply(String)
    case invalidPatch(String)
    case patchTooLarge(limit: Int)
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
        case .authorizationRevoked:
            "This change was no longer authorized by the time the index was free, so nothing was applied."
        case let .patchDoesNotApply(message):
            GitService.friendlyErrorDescription(for: message)
        case let .invalidPatch(message):
            "Git rejected the partial patch as invalid: \(GitService.friendlyErrorDescription(for: message))"
        case let .patchTooLarge(limit):
            "The partial patch exceeds the \(limit)-byte mutation limit."
        case let .gitRefused(message):
            GitService.friendlyErrorDescription(for: message)
        }
    }
}
