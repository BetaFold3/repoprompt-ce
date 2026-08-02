import Foundation

/// Turns the raw path an edit-tool payload reported into a `PreviewDocumentReference`.
///
/// The banner offers to open a document; the Preview segment addresses documents by logical root ID
/// plus a root-relative path, never by absolute path, so that a worktree that is torn down or
/// rebound cannot leave the reference pointing at a stale — or wrong — checkout. This type is the
/// one place that bridges the two vocabularies.
///
/// Pure and static: every input is passed in, so the mapping rules are testable without a
/// workspace, a session, or a repository on disk.
enum AgentChangesArtifactLinkResolver {
    /// Resolves an artifact path against the workspace.
    ///
    /// - Parameters:
    ///   - path: the path exactly as the tool payload reported it — absolute, relative, or
    ///     tilde-prefixed.
    ///   - checkout: the checkout the Changes panel is currently reading, used both to anchor a
    ///     relative path and to translate a worktree path back onto its logical root.
    ///   - logicalRoots: every logical root in the workspace, not just the active checkout's. An
    ///     agent can write a report into a root the panel is not currently pointed at, and the
    ///     Preview segment can still open it.
    ///   - rootIDsByPath: `WorkspaceRootRef.id` keyed by standardized logical root path.
    /// - Returns: a reference, or `nil` when the path lies outside every known root. The caller
    ///   suppresses the banner in that case rather than offering an action that cannot work.
    static func reference(
        forArtifactPath path: String,
        checkout: AgentPanelResolvedCheckout?,
        logicalRoots: [AgentPanelLogicalRoot],
        rootIDsByPath: [String: UUID]
    ) -> PreviewDocumentReference? {
        let absolute = absolutePath(for: path, checkout: checkout)

        // A path that already lands inside a logical root needs no worktree translation. The
        // longest match wins so a root nested inside another root claims its own documents.
        if let match = longestContainingRoot(absolute, in: logicalRoots),
           let rootID = rootIDsByPath[match.root.path]
        {
            return PreviewDocumentReference(rootID: rootID, relativePath: match.relativePath)
        }

        guard let checkout,
              let checkoutRelative = AgentPanelCheckoutResolver.repositoryRelativePath(
                  of: URL(fileURLWithPath: absolute),
                  underRepositoryRoot: checkout.checkoutURL
              ),
              !checkoutRelative.isEmpty
        else { return nil }

        guard let projection = projectOntoLogicalRoot(
            checkoutRelativePath: checkoutRelative,
            checkout: checkout
        ), let rootID = rootIDsByPath[projection.root.path] else { return nil }

        return PreviewDocumentReference(rootID: rootID, relativePath: projection.relativePath)
    }

    // MARK: - Path normalization

    /// Absolute, standardized form of a payload path.
    ///
    /// A relative path is anchored on the checkout rather than on the process working directory:
    /// agents report paths relative to the tree they were told to work in, and the app's own
    /// working directory has nothing to do with that tree.
    static func absolutePath(for path: String, checkout: AgentPanelResolvedCheckout?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let base = checkout?.checkoutURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    // MARK: - Root matching

    private struct RootMatch {
        let root: AgentPanelLogicalRoot
        let relativePath: String
    }

    private static func longestContainingRoot(
        _ absolutePath: String,
        in roots: [AgentPanelLogicalRoot]
    ) -> RootMatch? {
        var best: RootMatch?
        for root in roots {
            guard let relative = AgentPanelCheckoutResolver.repositoryRelativePath(
                of: URL(fileURLWithPath: absolutePath),
                underRepositoryRoot: URL(fileURLWithPath: root.path)
            ), !relative.isEmpty else { continue }
            if let current = best, current.root.path.count >= root.path.count { continue }
            best = RootMatch(root: root, relativePath: relative)
        }
        return best
    }

    /// Maps a path inside a worktree checkout back onto the logical root it stands in for.
    ///
    /// The resolver reproduces a logical root's position inside the worktree that replaced it, so a
    /// checkout-relative path carries that same position as its leading components. Two shapes are
    /// possible, and both are decidable from the checkout alone:
    ///
    /// - The checkout represents whole roots (`pathspecPrefixes` empty). With one logical root the
    ///   checkout-relative path *is* the root-relative path.
    /// - The checkout represents scoped roots. The matching pathspec prefix names the position, and
    ///   the logical root that ends with those same components is the one it belongs to.
    private static func projectOntoLogicalRoot(
        checkoutRelativePath: String,
        checkout: AgentPanelResolvedCheckout
    ) -> RootMatch? {
        guard !checkout.pathspecPrefixes.isEmpty else {
            guard checkout.logicalRoots.count == 1, let root = checkout.logicalRoots.first else {
                // Several unscoped roots on one checkout cannot be told apart by path alone;
                // guessing one would open the right file under the wrong root identity.
                return nil
            }
            return RootMatch(root: root, relativePath: checkoutRelativePath)
        }

        let matching = checkout.pathspecPrefixes
            .filter { checkoutRelativePath.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        guard let prefix = matching else { return nil }

        let scope = String(prefix.dropLast())
        guard let root = checkout.logicalRoots.first(where: {
            $0.path == "/" + scope || $0.path.hasSuffix("/" + scope)
        }) else { return nil }

        return RootMatch(
            root: root,
            relativePath: String(checkoutRelativePath.dropFirst(prefix.count))
        )
    }
}
