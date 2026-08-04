import Foundation

// MARK: - Diff metadata

/// A metadata-only read of a compare: which files changed and by how much, never the diff text.
///
/// Refresh stops here. Generating patch text for a whole working tree on every agent keystroke is
/// the expensive part of a diff read, and the panel only ever renders the patches of files the user
/// has expanded, so patch text is fetched per file, on demand, instead.
struct AgentChangesDiffMetadata: Equatable {
    let fingerprint: GitDiffFingerprint
    let files: [VCSUncommittedFile]
}

/// The patches produced by one scoped diff read, keyed the way `perFile` keys them.
///
/// Keyed rather than flattened because rename detection can decide either way: with both sides of
/// a rename in the pathspec Git emits one patch, and without it two. Keeping the map lets the
/// caller ask for the file it wanted by the same key its row already carries.
struct AgentChangesPatchPayload: Equatable {
    let perFile: [String: String]
    /// Original per-file patch bytes. Missing entries remain renderable but cannot mint review tokens.
    let rawPerFile: [String: Data]
    let fingerprint: GitDiffFingerprint
    let oldSourceReference: String?

    init(
        perFile: [String: String],
        rawPerFile: [String: Data] = [:],
        fingerprint: GitDiffFingerprint,
        oldSourceReference: String? = nil
    ) {
        self.perFile = perFile
        self.rawPerFile = rawPerFile
        self.fingerprint = fingerprint
        self.oldSourceReference = oldSourceReference
    }
}

// MARK: - File content

/// The three source categories a hidden diff gap can read.
enum AgentChangesFileContentSource: Equatable, Hashable {
    enum Reference: Equatable, Hashable {
        case named(String)
        case mergeBase(base: String)
    }

    case worktree(path: String)
    case index(path: String)
    case reference(Reference, path: String)
}

/// Bounded UTF-8 source text, split into one-based file lines while preserving CR in CRLF files.
struct AgentChangesFileContent: Equatable {
    let text: String
    let byteCount: Int
    let lines: [String]

    init(data: Data) throws {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw AgentChangesFileContentReadError.notUTF8
        }
        text = decoded
        byteCount = data.count
        if decoded.isEmpty {
            lines = []
        } else {
            var split = decoded.components(separatedBy: "\n")
            if decoded.hasSuffix("\n") {
                split.removeLast()
            }
            lines = split
        }
    }
}

enum AgentChangesFileContentReadError: LocalizedError, Equatable {
    case tooLarge(limit: Int)
    case notUTF8
    case outsideCheckout
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(limit):
            "File content exceeds the \(limit)-byte inline diff limit."
        case .notUTF8:
            "This file is not UTF-8 text."
        case .outsideCheckout:
            "The file resolves outside the selected checkout."
        case let .unavailable(message):
            message
        }
    }
}

// MARK: - Index backend seam

/// The index questions the Changes panel asks, narrowed to what it actually uses.
///
/// Deliberately not `VCSIndexMutationBackend` itself: that protocol refines `VCSBackend`, so a test
/// double would have to implement branch listing, blame, log, and worktree management to exercise a
/// staging preflight. This is the same narrow index surface with none of those unrelated calls.
protocol AgentChangesIndexBackend: Sendable {
    func capabilities(at checkout: URL) async -> VCSCapabilities
    func hasHeadCommit(at checkout: URL) async throws -> Bool
    func loadIndexStatus(at checkout: URL) async throws -> [VCSIndexStatusEntry]
    func loadIndexStatus(
        at checkout: URL,
        paths: [String]
    ) async throws -> [VCSIndexStatusEntry]
    func stage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws
    func unstage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws
    func applyCachedPatch(
        _ data: Data,
        reverse: Bool,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws
    func markResolved(
        _ identity: VCSIndexPathIdentity,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws
}

extension AgentChangesIndexBackend {
    func loadIndexStatus(
        at checkout: URL,
        paths: [String]
    ) async throws -> [VCSIndexStatusEntry] {
        let reviewedPaths = Set(paths)
        return try await loadIndexStatus(at: checkout).filter { entry in
            !reviewedPaths.isDisjoint(with: entry.identity.allPaths)
        }
    }

    func applyCachedPatch(
        _: Data,
        reverse _: Bool,
        at _: URL,
        authorize _: VCSIndexMutationAuthorization
    ) async throws {
        throw GitIndexMutationError.unavailable("This test index backend does not apply cached patches.")
    }
}

/// Live index backend, resolved per checkout through `VCSService`.
///
/// Backends without an index never reach a mutation call: the panel gates on
/// ``VCSCapabilities/supportsStaging`` and the repository returns `.unsupported` before asking.
/// The `unavailable` throw below therefore covers a genuine resolution failure — a checkout that
/// stopped being a Git repository between two reads — rather than the Jujutsu case.
struct AgentChangesLiveIndexBackend: AgentChangesIndexBackend {
    private let vcsService: VCSService

    init(vcsService: VCSService = .shared) {
        self.vcsService = vcsService
    }

    func capabilities(at checkout: URL) async -> VCSCapabilities {
        await vcsService.capabilities(forRepoRoot: checkout)
    }

    func hasHeadCommit(at checkout: URL) async throws -> Bool {
        try await requireBackend(at: checkout).hasHeadCommit(at: checkout)
    }

    func loadIndexStatus(at checkout: URL) async throws -> [VCSIndexStatusEntry] {
        try await requireBackend(at: checkout).loadIndexStatus(at: checkout)
    }

    func loadIndexStatus(
        at checkout: URL,
        paths: [String]
    ) async throws -> [VCSIndexStatusEntry] {
        try await requireBackend(at: checkout).loadIndexStatus(at: checkout, paths: paths)
    }

    func stage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireBackend(at: checkout).stage(identities, at: checkout, authorize: authorize)
    }

    func unstage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireBackend(at: checkout).unstage(identities, at: checkout, authorize: authorize)
    }

    func applyCachedPatch(
        _ data: Data,
        reverse: Bool,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireBackend(at: checkout).applyCachedPatch(
            data,
            reverse: reverse,
            at: checkout,
            authorize: authorize
        )
    }

    func markResolved(
        _ identity: VCSIndexPathIdentity,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireBackend(at: checkout).markResolved(
            identity,
            at: checkout,
            authorize: authorize
        )
    }

    private func requireBackend(at checkout: URL) async throws -> any VCSIndexMutationBackend {
        guard let backend = await vcsService.indexMutationBackend(forRepoRoot: checkout) else {
            throw GitIndexMutationError.unavailable(
                "No index-mutating backend is available for \(checkout.path)."
            )
        }
        return backend
    }
}

// MARK: - Diff source seam

/// The diff reads the Changes panel performs.
protocol AgentChangesDiffSource: Sendable {
    /// Resolve arbitrary commit-ish syntax before it is accepted as a compare target.
    func resolveRevision(_ revision: String, at checkout: URL) async -> AgentChangesRevisionValidation

    /// Changed-file list and stats for a compare. No patch text.
    func loadMetadata(
        compare: GitDiffCompareSpec,
        pathspecs: [String],
        at checkout: URL
    ) async throws -> AgentChangesDiffMetadata

    /// The diff fingerprint for a compare, without reading the diff itself.
    func fingerprint(compare: GitDiffCompareSpec, at checkout: URL) async throws -> GitDiffFingerprint

    /// One file's patch text at a given context width.
    ///
    /// - Parameter paths: every repository-relative path the file occupies. Renames and copies pass
    ///   both sides, because a pathspec naming only the destination makes Git report the rename as
    ///   an unrelated addition.
    func loadPatch(
        compare: GitDiffCompareSpec,
        paths: [String],
        at checkout: URL,
        contextLines: Int
    ) async throws -> AgentChangesPatchPayload?

    /// One bounded source version for hidden-context splicing.
    func loadFileContent(
        source: AgentChangesFileContentSource,
        at checkout: URL,
        byteLimit: Int
    ) async throws -> AgentChangesFileContent
}

/// Live diff source over the existing `GitDiffEngine`.
struct AgentChangesLiveDiffSource: AgentChangesDiffSource {
    private let engine: GitDiffEngine
    private let gitService: GitService

    init(
        engine: GitDiffEngine = .shared,
        gitService: GitService = GitService()
    ) {
        self.engine = engine
        self.gitService = gitService
    }

    func resolveRevision(_ revision: String, at checkout: URL) async -> AgentChangesRevisionValidation {
        do {
            switch try await gitService.resolveCommitRevision(revision, at: checkout) {
            case let .resolved(objectID):
                return .valid(objectID: objectID)
            case let .invalid(message):
                return .invalid(message)
            case let .ambiguous(message):
                return .ambiguous(message)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func fingerprint(compare: GitDiffCompareSpec, at checkout: URL) async throws -> GitDiffFingerprint {
        try await engine.fingerprint(for: compare, repoURL: checkout)
    }

    func loadMetadata(
        compare: GitDiffCompareSpec,
        pathspecs: [String],
        at checkout: URL
    ) async throws -> AgentChangesDiffMetadata {
        let result = try await engine.buildSnapshotInputs(
            compare: compare,
            pathspecs: pathspecs.isEmpty ? nil : pathspecs,
            repoURL: checkout,
            contextLines: 0,
            detectRenames: true,
            generateDiffText: false
        )
        return AgentChangesDiffMetadata(fingerprint: result.fingerprint, files: result.changedFiles)
    }

    func loadPatch(
        compare: GitDiffCompareSpec,
        paths: [String],
        at checkout: URL,
        contextLines: Int
    ) async throws -> AgentChangesPatchPayload? {
        guard !paths.isEmpty else { return nil }
        let pinned = try await pinnedPatchCompare(compare, at: checkout)
        let result = try await engine.buildSnapshotInputs(
            compare: pinned.compare,
            pathspecs: paths,
            repoURL: checkout,
            contextLines: contextLines,
            detectRenames: true,
            generateDiffText: true
        )
        guard let perFile = result.perFile, !perFile.isEmpty else { return nil }
        return AgentChangesPatchPayload(
            perFile: perFile,
            rawPerFile: result.rawPerFile ?? [:],
            fingerprint: result.fingerprint,
            oldSourceReference: pinned.oldSourceReference
        )
    }

    private func pinnedPatchCompare(
        _ compare: GitDiffCompareSpec,
        at checkout: URL
    ) async throws -> (compare: GitDiffCompareSpec, oldSourceReference: String?) {
        switch compare {
        case let .uncommittedMergeBase(base):
            let mergeBase = try await gitService.getMergeBase(
                sourceHead: "HEAD",
                targetHead: base,
                at: checkout
            )
            return (.uncommitted(base: mergeBase), mergeBase)

        case let .staged(base):
            let resolved = try await gitService.getRefSHA(at: checkout, ref: base)
            return (.staged(base: resolved), resolved)

        case let .stagedMergeBase(base):
            let mergeBase = try await gitService.getMergeBase(
                sourceHead: "HEAD",
                targetHead: base,
                at: checkout
            )
            return (.staged(base: mergeBase), mergeBase)

        case .uncommitted, .unstaged, .revspec:
            return (compare, nil)
        }
    }

    func loadFileContent(
        source: AgentChangesFileContentSource,
        at checkout: URL,
        byteLimit: Int
    ) async throws -> AgentChangesFileContent {
        let data: Data
        switch source {
        case let .worktree(path):
            data = try readWorktreeFile(path: path, at: checkout, byteLimit: byteLimit)

        case let .index(path):
            data = try await readGitFile(
                ref: nil,
                path: path,
                at: checkout,
                byteLimit: byteLimit
            )

        case let .reference(reference, path):
            let resolvedReference: String = switch reference {
            case let .named(name):
                name
            case let .mergeBase(base):
                try await gitService.getMergeBase(
                    sourceHead: "HEAD",
                    targetHead: base,
                    at: checkout
                )
            }
            data = try await readGitFile(
                ref: resolvedReference,
                path: path,
                at: checkout,
                byteLimit: byteLimit
            )
        }
        return try AgentChangesFileContent(data: data)
    }

    private func readGitFile(
        ref: String?,
        path: String,
        at checkout: URL,
        byteLimit: Int
    ) async throws -> Data {
        do {
            return try await gitService.getFileContent(
                ref: ref,
                path: path,
                byteLimit: byteLimit,
                at: checkout
            )
        } catch let error as GitFileContentReadError {
            switch error {
            case let .tooLarge(limit):
                throw AgentChangesFileContentReadError.tooLarge(limit: limit)
            case let .unavailable(message):
                throw AgentChangesFileContentReadError.unavailable(message)
            }
        }
    }

    private func readWorktreeFile(
        path: String,
        at checkout: URL,
        byteLimit: Int
    ) throws -> Data {
        guard byteLimit >= 0 else {
            throw AgentChangesFileContentReadError.tooLarge(limit: byteLimit)
        }
        let checkoutRoot = checkout.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = checkout.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = checkoutRoot.path.hasSuffix("/") ? checkoutRoot.path : checkoutRoot.path + "/"
        guard candidate.path == checkoutRoot.path || candidate.path.hasPrefix(rootPath) else {
            throw AgentChangesFileContentReadError.outsideCheckout
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: candidate)
        } catch {
            throw AgentChangesFileContentReadError.unavailable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let (captureLimit, overflow) = byteLimit.addingReportingOverflow(1)
        guard !overflow else {
            throw AgentChangesFileContentReadError.tooLarge(limit: byteLimit)
        }
        let data = try handle.read(upToCount: captureLimit) ?? Data()
        guard data.count <= byteLimit else {
            throw AgentChangesFileContentReadError.tooLarge(limit: byteLimit)
        }
        return data
    }
}

// MARK: - Invalidation seam

/// Publishes the fact that this panel mutated an index.
///
/// The panel is not the only reader of the repositories it stages into; the workspace context store
/// and the diff snapshot store both reconcile off `GitWorkspaceStateAuthority` invalidations. A
/// staging click that skipped the announcement would leave every other surface believing its cached
/// view of the index was still current.
protocol AgentChangesInvalidationPublishing: Sendable {
    func publishIndexMutation(at checkout: URL) async
}

/// Live publisher: opens and immediately closes an authority mutation window for the checkout.
///
/// Both ends of the window emit, which is exactly the shape this needs — begin invalidates every
/// cached scope for the repository, and completion balances the mutation depth so the authority
/// does not stay parked in "a mutation is in flight".
struct AgentChangesLiveInvalidationPublisher: AgentChangesInvalidationPublishing {
    private let authority: GitWorkspaceStateAuthority

    init(authority: GitWorkspaceStateAuthority = .shared) {
        self.authority = authority
    }

    func publishIndexMutation(at checkout: URL) async {
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: checkout) else { return }
        let key = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        // `.other` rather than a new mutation kind: the authority's kinds name workflows that own
        // dedicated recovery behavior, and a file-level index write needs none of it.
        let token = await authority.beginMutation(repositoryKey: key, kind: .other)
        await authority.finishMutation(token, outcome: .succeeded)
    }
}
