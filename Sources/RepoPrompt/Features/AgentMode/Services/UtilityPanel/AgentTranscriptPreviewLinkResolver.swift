import Foundation

/// Resolves transcript document paths through the same checkout-aware mapping used by Changes
/// artifacts. The result remains a logical-root reference so Preview follows active worktree
/// bindings without persisting a checkout path.
@MainActor
struct AgentTranscriptPreviewLinkResolver {
    private let environment: any AgentChangesPanelEnvironment
    private let probe: any AgentPanelCheckoutProbing

    init(
        environment: any AgentChangesPanelEnvironment,
        probe: any AgentPanelCheckoutProbing = AgentPanelLiveCheckoutProbe()
    ) {
        self.environment = environment
        self.probe = probe
    }

    func reference(for path: String, tabID: UUID?) async -> PreviewDocumentReference? {
        let rootInputs = await environment.rootInputs(tabID: tabID)
        guard !Task.isCancelled else { return nil }

        let resolution = await AgentPanelCheckoutResolver.resolve(
            AgentPanelCheckoutRequest(
                logicalRoots: rootInputs.logicalRoots,
                worktreeBindings: rootInputs.worktreeBindings,
                isPreparingWorktree: rootInputs.isPreparingWorktree
            ),
            probe: probe
        )
        guard !Task.isCancelled else { return nil }

        let checkouts: [AgentPanelResolvedCheckout] = resolution.items.compactMap { item in
            guard case let .resolved(checkout) = item else { return nil }
            return checkout
        }
        guard let artifactPath = Self.artifactPath(
            forTranscriptPath: path,
            logicalRoots: rootInputs.logicalRoots,
            rootIDsByPath: rootInputs.rootIDsByPath
        ) else {
            return nil
        }
        return AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: artifactPath,
            checkouts: checkouts,
            logicalRoots: rootInputs.logicalRoots,
            rootIDsByPath: rootInputs.rootIDsByPath
        )
    }

    /// Composer mentions render as `@path`, while their canonical attachment metadata omits `@`.
    /// In a multi-root workspace that path begins with the owning root's display alias. Translate
    /// either representation to a logical absolute path before checkout projection so the alias is
    /// not mistaken for a directory inside every checkout.
    private static func artifactPath(
        forTranscriptPath path: String,
        logicalRoots: [AgentPanelLogicalRoot],
        rootIDsByPath: [String: UUID]
    ) -> String? {
        let markerStripped = path.hasPrefix("@") ? String(path.dropFirst()) : path
        guard !markerStripped.isEmpty else { return nil }
        guard !markerStripped.hasPrefix("/"), logicalRoots.count > 1 else {
            return markerStripped
        }

        let visibleRoots = logicalRoots.compactMap { root -> WorkspaceRootRef? in
            guard let rootID = rootIDsByPath[root.path] else { return nil }
            return WorkspaceRootRef(id: rootID, name: root.displayName, fullPath: root.path)
        }
        guard visibleRoots.count == logicalRoots.count else { return nil }

        switch WorkspaceAliasResolver.resolve(
            userPath: markerStripped,
            roots: visibleRoots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            return URL(fileURLWithPath: root.standardizedFullPath)
                .appendingPathComponent(remainder)
                .standardizedFileURL
                .path
        case .ambiguous:
            return nil
        case .notAliasPrefixed, .bareRoot:
            return markerStripped
        }
    }
}

/// Testable policy for authored transcript links. Production owns task lifetime; this seam owns
/// ordering and the rule that only a resolver miss may reach the existing external-file fallback.
@MainActor
enum AgentTranscriptPreviewLinkRoutingPolicy {
    enum Outcome: Equatable {
        case previewed
        case fellBack(Bool)
        case unresolved
        case cancelled

        var opened: Bool {
            switch self {
            case .previewed:
                true
            case let .fellBack(opened):
                opened
            case .cancelled:
                true
            case .unresolved:
                false
            }
        }
    }

    static func isPreviewable(_ target: MarkdownFileLinkTarget) -> Bool {
        let fileExtension = (target.normalizedPath as NSString).pathExtension
        return AgentSessionArtifactKind(fileExtension: fileExtension) != nil
    }

    static func mayUseExternalFallback(_ target: MarkdownFileLinkTarget) -> Bool {
        !target.isAutoDetected
    }

    static func route(
        resolve: @MainActor () async -> PreviewDocumentReference?,
        showPreview: @MainActor (PreviewDocumentReference) -> Void,
        reveal: @MainActor () -> Void,
        fallback: (@MainActor () async -> Bool)?
    ) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }

        guard let reference = await resolve() else {
            guard !Task.isCancelled else { return .cancelled }
            guard let fallback else { return .unresolved }
            let opened = await fallback()
            return .fellBack(opened)
        }
        guard !Task.isCancelled else { return .cancelled }

        showPreview(reference)
        reveal()
        return .previewed
    }
}
