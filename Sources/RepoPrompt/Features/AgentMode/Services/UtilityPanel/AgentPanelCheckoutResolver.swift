import Foundation

// MARK: - Inputs

/// One logical workspace root as the panel sees it.
///
/// "Logical" is the workspace's own vocabulary: the path the user added and the name shown in the
/// root picker, never a worktree path. Worktree redirection happens here, in one place, so no other
/// panel component has to know that the bytes it reads live somewhere else.
struct AgentPanelLogicalRoot: Equatable {
    /// Standardized absolute path of the workspace root.
    let path: String
    /// Display name, when the workspace has one.
    let name: String?

    init(path: String, name: String? = nil) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.name = name
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Everything the resolver needs to decide what the Changes panel is looking at.
struct AgentPanelCheckoutRequest: Equatable {
    /// The workspace's logical roots, in workspace order.
    let logicalRoots: [AgentPanelLogicalRoot]

    /// The active session's worktree bindings. A root with no binding reads its own checkout.
    let worktreeBindings: [AgentSessionWorktreeBinding]

    /// Whether the session is still creating its initial worktree.
    ///
    /// This is the only signal that separates "the worktree does not exist yet" from "the worktree
    /// is gone": both look identical on disk. `TabSession.isPreparingInitialWorktree` owns it.
    let isPreparingWorktree: Bool

    /// Logical root paths where the user explicitly chose the workspace checkout over an
    /// unavailable worktree. Sticky by design — the warning chip that comes with the choice is
    /// what keeps the substitution visible.
    let workspaceCheckoutOverrides: Set<String>

    init(
        logicalRoots: [AgentPanelLogicalRoot],
        worktreeBindings: [AgentSessionWorktreeBinding] = [],
        isPreparingWorktree: Bool = false,
        workspaceCheckoutOverrides: Set<String> = []
    ) {
        self.logicalRoots = logicalRoots
        self.worktreeBindings = worktreeBindings
        self.isPreparingWorktree = isPreparingWorktree
        self.workspaceCheckoutOverrides = Set(
            workspaceCheckoutOverrides.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
    }

    /// Changes to this value are what a blocked root waits for.
    ///
    /// Blocked roots do not poll: `.preparing` clears when the binding set, the preparing flag, or
    /// the override set changes, which is exactly when a re-resolve can produce a different answer.
    var retrySignature: String {
        let bindings = worktreeBindings
            .map { "\($0.id)|\($0.logicalRootPath)|\($0.worktreeRootPath)|\($0.branch ?? "")|\($0.head ?? "")" }
            .sorted()
        return [
            logicalRoots.map(\.path).joined(separator: ","),
            bindings.joined(separator: ","),
            String(isPreparingWorktree),
            workspaceCheckoutOverrides.sorted().joined(separator: ",")
        ].joined(separator: "\u{1F}")
    }
}

// MARK: - Worktree identity

/// The bound worktree behind a resolved checkout, for the panel's worktree chip.
struct AgentPanelWorktreeIdentity: Equatable {
    let bindingID: String
    let worktreeID: String
    let worktreeRootPath: String
    let label: String
    let branch: String?

    init(binding: AgentSessionWorktreeBinding) {
        bindingID = binding.id
        worktreeID = binding.worktreeID
        worktreeRootPath = binding.worktreeRootPath
        let candidates = [binding.visualLabel, binding.worktreeName, binding.branch]
        let resolved = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        label = resolved ?? String(binding.worktreeID.suffix(8))
        branch = binding.branch
    }
}

// MARK: - Outcomes

/// Why a logical root has no checkout to show.
enum AgentPanelCheckoutBlockReason: Equatable {
    /// The session is still creating the bound worktree. Auto-retries on binding change.
    case worktreePreparing(label: String, worktreeRootPath: String)
    /// The bound worktree is not on disk.
    case worktreeMissing(label: String, worktreeRootPath: String)
    /// The bound worktree path exists but is not a directory.
    case worktreeNotADirectory(label: String, worktreeRootPath: String)
    /// The bound worktree exists on disk but no VCS backend claims it.
    case worktreeNotARepository(label: String, worktreeRootPath: String)
    /// The logical root itself is gone.
    case rootMissing(path: String)
    /// The logical root is not under any repository — the panel's non-git empty state.
    case notARepository(path: String)

    /// Whether re-resolving may still succeed without the user doing anything.
    var isTransient: Bool {
        if case .worktreePreparing = self { return true }
        return false
    }

    /// Whether the user can substitute the workspace checkout for this root.
    ///
    /// Offered only for worktree failures that will not resolve themselves. A preparing worktree
    /// must not offer it: the substitution is sticky, so accepting it during a two-second hydration
    /// would silently pin the panel to the wrong checkout for the rest of the session.
    var allowsWorkspaceCheckoutOverride: Bool {
        switch self {
        case .worktreeMissing, .worktreeNotADirectory, .worktreeNotARepository:
            true
        case .worktreePreparing, .rootMissing, .notARepository:
            false
        }
    }
}

/// A logical root the panel cannot show, and why.
struct AgentPanelBlockedCheckout: Equatable, Identifiable {
    let logicalRoot: AgentPanelLogicalRoot
    let reason: AgentPanelCheckoutBlockReason

    var id: String {
        logicalRoot.path
    }
}

/// One checkout the Changes panel can read, plus the scope inside it that the workspace represents.
struct AgentPanelResolvedCheckout: Equatable, Identifiable {
    /// The working tree to run VCS reads and index mutations in.
    let checkoutURL: URL

    /// The repository root the backend resolved for ``checkoutURL``. Equal to it for a normal
    /// checkout; for a logical root nested inside a repository it is the enclosing repository root,
    /// which is why ``pathspecPrefixes`` exists.
    let repoRootURL: URL

    let backendKind: VCSBackendKind

    /// Repository-relative directory prefixes covering the logical roots this entry represents,
    /// each with a trailing slash. Empty means the whole repository is represented.
    ///
    /// Every read and every mutation is scoped by these, so a stage-all driven from a workspace
    /// holding one package of a monorepo cannot stage the rest of the monorepo.
    let pathspecPrefixes: [String]

    /// The logical roots collapsed into this entry, in request order.
    let logicalRoots: [AgentPanelLogicalRoot]

    /// The worktree this checkout came from, when a binding redirected it.
    let worktree: AgentPanelWorktreeIdentity?

    /// True when the user chose this workspace checkout in place of an unavailable worktree.
    /// The panel keeps a warning chip while it is set.
    let substitutesUnavailableWorktree: Bool

    /// False when the logical-root scope could not be represented as repository-relative
    /// pathspecs. Reads may widen to the repository so changes remain visible; writes must not.
    let isMutationScopeRepresentable: Bool

    init(
        checkoutURL: URL,
        repoRootURL: URL,
        backendKind: VCSBackendKind,
        pathspecPrefixes: [String],
        logicalRoots: [AgentPanelLogicalRoot],
        worktree: AgentPanelWorktreeIdentity?,
        substitutesUnavailableWorktree: Bool,
        isMutationScopeRepresentable: Bool = true
    ) {
        self.checkoutURL = checkoutURL.standardizedFileURL
        self.repoRootURL = repoRootURL.standardizedFileURL
        self.backendKind = backendKind
        self.pathspecPrefixes = pathspecPrefixes
        self.logicalRoots = logicalRoots
        self.worktree = worktree
        self.substitutesUnavailableWorktree = substitutesUnavailableWorktree
        self.isMutationScopeRepresentable = isMutationScopeRepresentable
    }

    var id: String {
        checkoutURL.standardizedFileURL.path
    }

    /// Full targeting identity. Unlike the path-only ID, this changes with scope and substitution.
    var targetKey: String {
        let roots = logicalRoots.map { "\($0.path)|\($0.name ?? "")" }.joined(separator: ",")
        let worktreeKey = worktree.map {
            "\($0.bindingID)|\($0.worktreeID)|\($0.worktreeRootPath)|\($0.label)|\($0.branch ?? "")"
        } ?? ""
        return [
            checkoutURL.standardizedFileURL.path,
            repoRootURL.standardizedFileURL.path,
            String(describing: backendKind),
            pathspecPrefixes.sorted().joined(separator: ","),
            roots,
            worktreeKey,
            String(substitutesUnavailableWorktree),
            String(isMutationScopeRepresentable)
        ].joined(separator: "\u{1F}")
    }

    /// Display name for the root picker.
    var displayName: String {
        logicalRoots.map(\.displayName).joined(separator: " + ")
    }

    /// Whether a repository-relative path is inside the represented scope.
    func containsRepositoryRelativePath(_ path: String) -> Bool {
        guard !pathspecPrefixes.isEmpty else { return true }
        return pathspecPrefixes.contains { path.hasPrefix($0) }
    }
}

/// What the panel should show for one request.
struct AgentPanelCheckoutResolution: Equatable {
    /// Readable checkouts, in the order their first logical root appeared.
    let targets: [AgentPanelResolvedCheckout]

    /// Roots that resolved to nothing, with the reason and whether an override is offered.
    let blocked: [AgentPanelBlockedCheckout]

    /// The request signature this resolution was computed from; a change means retry.
    let retrySignature: String

    var isEmpty: Bool {
        targets.isEmpty && blocked.isEmpty
    }

    /// True when at least one root is waiting on worktree hydration.
    var isPreparing: Bool {
        blocked.contains { $0.reason.isTransient }
    }
}

// MARK: - Probe

/// The filesystem and VCS questions the resolver cannot answer by itself.
///
/// Split out so the resolution rules — which worktree wins, when preparing beats unavailable, how
/// same-repository roots collapse — are testable without a repository on disk.
enum AgentPanelCheckoutItemKind: Equatable {
    case missing
    case file
    case directory
}

protocol AgentPanelCheckoutProbing: Sendable {
    func itemKind(at path: String) -> AgentPanelCheckoutItemKind
    func resolveRepository(at url: URL) async -> VCSResolvedRepo?
}

/// Live probe: `FileManager` for existence, `VCSService` for repository discovery.
struct AgentPanelLiveCheckoutProbe: AgentPanelCheckoutProbing {
    private let vcsService: VCSService

    init(vcsService: VCSService = .shared) {
        self.vcsService = vcsService
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        var isDirectory: ObjCBool = false
        // `FileManager.default` rather than an injected instance: `FileManager` is not `Sendable`,
        // and the resolution rules are exercised through a fake probe, not a fake file manager.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        await vcsService.resolveRepo(from: url)
    }
}

// MARK: - Resolver

/// Maps logical workspace roots plus the active session's worktree bindings onto the checkouts the
/// Changes panel reads and stages into.
///
/// The rule this type exists to enforce is decision row 5: **a bound worktree never silently falls
/// back to the workspace checkout.** The panel mutates a Git index; pointing that surface at the
/// wrong working tree would stage the user's own edits under the impression they were reviewing the
/// agent's. So a binding that cannot be honored produces a blocked root carrying its reason, and
/// the workspace checkout is substituted only when the user asks for it by name.
enum AgentPanelCheckoutResolver {
    static func resolve(
        _ request: AgentPanelCheckoutRequest,
        probe: some AgentPanelCheckoutProbing
    ) async -> AgentPanelCheckoutResolution {
        var candidates: [Candidate] = []
        var blocked: [AgentPanelBlockedCheckout] = []

        for root in request.logicalRoots {
            switch await candidate(for: root, request: request, probe: probe) {
            case let .resolved(candidate):
                candidates.append(candidate)
            case let .blocked(reason):
                blocked.append(AgentPanelBlockedCheckout(logicalRoot: root, reason: reason))
            }
        }

        return AgentPanelCheckoutResolution(
            targets: collapse(candidates),
            blocked: blocked,
            retrySignature: request.retrySignature
        )
    }

    // MARK: - Per-root resolution

    private struct Candidate {
        let checkoutURL: URL
        let repoRootURL: URL
        let backendKind: VCSBackendKind
        let logicalRoot: AgentPanelLogicalRoot
        /// The directory inside the checkout that this logical root represents.
        let scopeURL: URL
        let worktree: AgentPanelWorktreeIdentity?
        let substitutesUnavailableWorktree: Bool
    }

    private enum CandidateOutcome {
        case resolved(Candidate)
        case blocked(AgentPanelCheckoutBlockReason)
    }

    private static func candidate(
        for root: AgentPanelLogicalRoot,
        request: AgentPanelCheckoutRequest,
        probe: some AgentPanelCheckoutProbing
    ) async -> CandidateOutcome {
        let binding = binding(for: root, in: request.worktreeBindings)
        let overridden = request.workspaceCheckoutOverrides.contains(root.path)

        if let binding, !overridden {
            return await worktreeCandidate(
                root: root,
                binding: binding,
                isPreparingWorktree: request.isPreparingWorktree,
                probe: probe
            )
        }

        // No binding, or the user explicitly asked for the workspace checkout instead.
        guard probe.itemKind(at: root.path) == .directory else {
            return .blocked(.rootMissing(path: root.path))
        }
        let rootURL = URL(fileURLWithPath: root.path)
        guard let repo = await probe.resolveRepository(at: rootURL) else {
            return .blocked(.notARepository(path: root.path))
        }
        return .resolved(Candidate(
            checkoutURL: repo.rootURL.standardizedFileURL,
            repoRootURL: repo.rootURL.standardizedFileURL,
            backendKind: repo.backendKind,
            logicalRoot: root,
            scopeURL: rootURL,
            // A binding that survives an override still names the worktree the user opted out of,
            // which is what keeps the warning chip specific.
            worktree: overridden ? binding.map(AgentPanelWorktreeIdentity.init(binding:)) : nil,
            substitutesUnavailableWorktree: overridden && binding != nil
        ))
    }

    private static func worktreeCandidate(
        root: AgentPanelLogicalRoot,
        binding: AgentSessionWorktreeBinding,
        isPreparingWorktree: Bool,
        probe: some AgentPanelCheckoutProbing
    ) async -> CandidateOutcome {
        let identity = AgentPanelWorktreeIdentity(binding: binding)
        let worktreePath = URL(fileURLWithPath: binding.worktreeRootPath).standardizedFileURL.path

        switch probe.itemKind(at: worktreePath) {
        case .directory:
            break
        case .file:
            return .blocked(
                .worktreeNotADirectory(label: identity.label, worktreeRootPath: worktreePath)
            )
        case .missing:
            // "Not there yet" and "gone" are the same observation; only the session's own
            // preparing flag can tell them apart, and guessing wrong in the optimistic direction
            // would show a permanent spinner for a worktree that was deleted.
            return .blocked(
                isPreparingWorktree
                    ? .worktreePreparing(label: identity.label, worktreeRootPath: worktreePath)
                    : .worktreeMissing(label: identity.label, worktreeRootPath: worktreePath)
            )
        }

        let worktreeURL = URL(fileURLWithPath: worktreePath)
        guard let repo = await probe.resolveRepository(at: worktreeURL) else {
            // A directory that exists without a repository behind it is a half-created worktree
            // while the session is preparing, and a broken one afterwards.
            return .blocked(
                isPreparingWorktree
                    ? .worktreePreparing(label: identity.label, worktreeRootPath: worktreePath)
                    : .worktreeNotARepository(label: identity.label, worktreeRootPath: worktreePath)
            )
        }

        // The logical root's position inside its own repository is reproduced inside the worktree:
        // a workspace holding `repo/packages/x` bound to a worktree reads `worktree/packages/x`.
        let scopeURL = await projectedScopeURL(
            logicalRootPath: root.path,
            worktreeRoot: repo.rootURL.standardizedFileURL,
            probe: probe
        )

        return .resolved(Candidate(
            checkoutURL: repo.rootURL.standardizedFileURL,
            repoRootURL: repo.rootURL.standardizedFileURL,
            backendKind: repo.backendKind,
            logicalRoot: root,
            scopeURL: scopeURL,
            worktree: identity,
            substitutesUnavailableWorktree: false
        ))
    }

    /// Where a logical root's contents live inside the worktree that replaced its repository.
    ///
    /// Falls back to the whole worktree when the logical root is not inside a repository of its
    /// own: without a repository-relative position there is no defensible narrower scope, and
    /// guessing one would silently hide changes.
    private static func projectedScopeURL(
        logicalRootPath: String,
        worktreeRoot: URL,
        probe: some AgentPanelCheckoutProbing
    ) async -> URL {
        let logicalRootURL = URL(fileURLWithPath: logicalRootPath)
        guard let logicalRepo = await probe.resolveRepository(at: logicalRootURL) else {
            return worktreeRoot
        }
        let relative = repositoryRelativePath(
            of: logicalRootURL,
            underRepositoryRoot: logicalRepo.rootURL.standardizedFileURL
        )
        guard let relative, !relative.isEmpty else { return worktreeRoot }
        return worktreeRoot.appendingPathComponent(relative)
    }

    /// The binding that governs a logical root.
    ///
    /// Matched on the logical root path rather than on repository identity: two roots of the same
    /// repository can be bound to different worktrees, and the binding that names this root is the
    /// only one that speaks for it.
    private static func binding(
        for root: AgentPanelLogicalRoot,
        in bindings: [AgentSessionWorktreeBinding]
    ) -> AgentSessionWorktreeBinding? {
        let standardized = bindings.map { binding in
            (binding, URL(fileURLWithPath: binding.logicalRootPath).standardizedFileURL.path)
        }
        if let exact = standardized.first(where: { $0.1 == root.path }) {
            return exact.0
        }

        // Bindings are recorded from the visible workspace-root path. If the root list later
        // changes to an ancestor or descendant, exact equality no longer holds even though the
        // binding still governs the same repository. Prefer the closest containment match rather
        // than silently falling back to the workspace checkout.
        return standardized
            .filter { pathsContainEachOther($0.1, root.path) }
            .sorted { lhs, rhs in
                abs(lhs.1.count - root.path.count) < abs(rhs.1.count - root.path.count)
            }
            .first?
            .0
    }

    private static func pathsContainEachOther(_ lhs: String, _ rhs: String) -> Bool {
        func contains(_ ancestor: String, _ descendant: String) -> Bool {
            descendant == ancestor
                || descendant.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
        }
        return contains(lhs, rhs) || contains(rhs, lhs)
    }

    // MARK: - Collapsing

    /// Collapses roots that landed on one checkout into a single entry.
    ///
    /// Two roots of one repository must not become two panel targets: they would issue two status
    /// reads of the same index, show the same file twice, and let a stage-all in one entry silently
    /// change the other. Collapsing them into one entry with two pathspec prefixes keeps a single
    /// authoritative read while preserving the scope restriction.
    private static func collapse(_ candidates: [Candidate]) -> [AgentPanelResolvedCheckout] {
        var order: [String] = []
        var grouped: [String: [Candidate]] = [:]

        for candidate in candidates {
            let key = candidate.checkoutURL.standardizedFileURL.path
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            grouped[key]?.append(candidate)
        }

        return order.compactMap { key -> AgentPanelResolvedCheckout? in
            guard let group = grouped[key], let first = group.first else { return nil }
            let scope = pathspecScope(for: group, repoRootURL: first.repoRootURL)
            return AgentPanelResolvedCheckout(
                checkoutURL: first.checkoutURL,
                repoRootURL: first.repoRootURL,
                backendKind: first.backendKind,
                pathspecPrefixes: scope.prefixes,
                logicalRoots: group.map(\.logicalRoot),
                worktree: group.compactMap(\.worktree).first,
                substitutesUnavailableWorktree: group.contains { $0.substitutesUnavailableWorktree },
                isMutationScopeRepresentable: scope.isMutationScopeRepresentable
            )
        }
    }

    /// The repository-relative prefixes covering a collapsed group.
    ///
    /// Any root that is the repository root itself widens the group to the whole repository, and
    /// prefixes that contain other prefixes absorb them, so the result never double-counts a file.
    private struct PathspecScope {
        let prefixes: [String]
        let isMutationScopeRepresentable: Bool
    }

    private static func pathspecScope(
        for group: [Candidate],
        repoRootURL: URL
    ) -> PathspecScope {
        var prefixes: Set<String> = []
        for candidate in group {
            guard let relative = repositoryRelativePath(
                of: candidate.scopeURL,
                underRepositoryRoot: repoRootURL
            ) else {
                // Widen reads so changes stay visible, but explicitly disable every write: an
                // unexpressible logical-root boundary cannot safely scope Stage All.
                return PathspecScope(prefixes: [], isMutationScopeRepresentable: false)
            }
            if relative.isEmpty {
                return PathspecScope(prefixes: [], isMutationScopeRepresentable: true)
            }
            prefixes.insert(relative + "/")
        }

        let sorted = prefixes.sorted()
        var minimal: [String] = []
        for prefix in sorted where !minimal.contains(where: { prefix.hasPrefix($0) }) {
            minimal.append(prefix)
        }
        return PathspecScope(prefixes: minimal, isMutationScopeRepresentable: true)
    }

    /// The repository-relative path of `url`, or nil when it is not under `repositoryRoot`.
    /// Returns an empty string when they are the same directory.
    static func repositoryRelativePath(of url: URL, underRepositoryRoot repositoryRoot: URL) -> String? {
        let rootPath = repositoryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
