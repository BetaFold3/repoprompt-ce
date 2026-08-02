import Foundation
import WebKit

/// Why a secure preview could not be prepared.
///
/// Preparation failure is always terminal for that document: the surface reports the
/// error instead of degrading to a less restricted web view.
enum SecureHTMLPreviewConfigurationError: Error, Equatable {
    /// `WKContentRuleListStore.default()` was unavailable, so the remote-load block
    /// could not be compiled or installed.
    case contentRuleListStoreUnavailable
    /// Compilation failed, or completed without producing a rule list.
    case contentRuleListCompilationFailed(String)
}

/// Closed modes for the secure preview. Adding a future case forces every security
/// switch to make an explicit choice rather than inheriting script permission.
enum SecureHTMLPreviewMode: Equatable {
    case scriptsBlocked
    case scriptsEnabled

    var assetBoundary: RepoPreviewAssetBoundary {
        switch self {
        case .scriptsBlocked:
            .checkout
        case .scriptsEnabled:
            .documentSubtree
        }
    }

    var allowsContentJavaScript: Bool {
        assetBoundary.allowsContentJavaScript
    }
}

/// Builds the `WKWebViewConfiguration` used for untrusted, agent-authored HTML.
///
/// The factory is `async` and `throws` on purpose. Compiling the remote-load block is
/// asynchronous, and the fail-closed requirement is that no document may load until
/// that block is installed. Expressing it as "you cannot obtain a configuration
/// without a compiled rule list" makes the ordering a property of the type rather
/// than a rule a future caller has to remember.
///
/// Threat-model delta for the explicit script opt-in:
///
/// - Opting in adds inline and local-folder JavaScript execution. That makes same-origin
///   images, styles, and scripts readable/observable to the document.
/// - The scheme handler therefore narrows from the checkout to the one selected,
///   symlink-resolved document plus assets below its own *nested* directory. Resolved
///   dotfiles and dot-directories are always denied; they commonly contain repository
///   metadata, environment values, credentials, and tool state.
/// - Network/connect APIs, frames, forms, base rewriting, workers, popups, persistent
///   storage, and unconfirmed external navigation stay blocked. The remote rule list
///   is still compiled before a web view can exist, and any ambiguity fails closed.
/// - A scripted load always gets a newly built non-persistent store. A different
///   document is never allowed to inherit its handler, storage, or JavaScript state.
@MainActor
enum SecureHTMLPreviewConfiguration {
    static let remoteLoadBlockingRuleListIdentifier = "RepoPromptSecureHTMLPreviewBlockRemoteLoads"

    /// Blocks every http/https/ws/wss load at the network layer.
    ///
    /// This duplicates what the CSP already denies, and that duplication is the point:
    /// the CSP is a response header, so it depends on the response reaching the web
    /// view correctly, whereas a content rule list is enforced by WebKit regardless of
    /// what any document or header says.
    ///
    /// `url-filter` is a regular expression matched against the full URL.
    static let remoteLoadBlockingRuleListJSON = """
    [
      {
        "trigger": { "url-filter": "^https?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://" },
        "action": { "type": "block" }
      }
    ]
    """

    /// Creates a configuration bound to one document root.
    ///
    /// - Throws: `SecureHTMLPreviewConfigurationError` when the remote-load block
    ///   cannot be compiled. Callers must surface an error state; there is no
    ///   fallback configuration.
    static func make(documentRootURL: URL) async throws -> WKWebViewConfiguration {
        // Compiled first: nothing below this line can be reached without the block.
        let ruleList = try await compileRemoteLoadBlockingRuleList()

        let configuration = WKWebViewConfiguration()

        // No cache, cookie, or local-storage residue survives this web view's
        // non-persistent lifecycle. JavaScript is disabled throughout this static path.
        configuration.websiteDataStore = .nonPersistent()

        // Static-mode JavaScript lock 1 of 3 (see also the per-navigation
        // preference in SecureHTMLPreviewView and `script-src 'none'` in the CSP).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        configuration.setURLSchemeHandler(
            RepoPreviewURLSchemeHandler(documentRootURL: documentRootURL),
            forURLScheme: RepoPreviewURLScheme.scheme
        )
        configuration.userContentController.add(ruleList)

        return configuration
    }

    /// Mode-aware entry point used by the preview controller.
    ///
    /// The existing one-argument factory remains the Phase-1 scripts-blocked path.
    /// Scripted mode is separate and cannot be built without an exact document path,
    /// which is what makes the narrowed boundary a construction-time precondition.
    static func make(
        documentRootURL: URL,
        documentRelativePath: String,
        mode: SecureHTMLPreviewMode
    ) async throws -> WKWebViewConfiguration {
        switch mode {
        case .scriptsBlocked:
            try await make(documentRootURL: documentRootURL)
        case .scriptsEnabled:
            try await makeScripted(
                documentRootURL: documentRootURL,
                documentRelativePath: documentRelativePath
            )
        }
    }

    private static func makeScripted(
        documentRootURL: URL,
        documentRelativePath: String
    ) async throws -> WKWebViewConfiguration {
        // Same fail-closed ordering as static mode: no configuration is returned until
        // the unchanged network rule list has compiled successfully.
        let ruleList = try await compileRemoteLoadBlockingRuleList()
        let schemeHandler = try RepoPreviewURLSchemeHandler(
            documentRootURL: documentRootURL,
            documentRelativePath: documentRelativePath,
            assetBoundary: .documentSubtree
        )

        let configuration = WKWebViewConfiguration()
        // A new object is created on every call. The controller never reuses a scripted
        // configuration for another document.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: RepoPreviewURLScheme.scheme
        )
        configuration.userContentController.add(ruleList)
        return configuration
    }

    /// Compiles the rule list on every preparation instead of reusing a stored list.
    ///
    /// `WKContentRuleListStore` caches compilation on disk, so this is cheap, and
    /// recompiling guarantees the installed rules are the ones in this source file —
    /// a previously stored list under the same identifier can never win.
    static func compileRemoteLoadBlockingRuleList() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw SecureHTMLPreviewConfigurationError.contentRuleListStoreUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: remoteLoadBlockingRuleListIdentifier,
                encodedContentRuleList: remoteLoadBlockingRuleListJSON
            ) { ruleList, error in
                if let error {
                    continuation.resume(
                        throwing: SecureHTMLPreviewConfigurationError
                            .contentRuleListCompilationFailed(error.localizedDescription)
                    )
                    return
                }
                guard let ruleList else {
                    // WebKit reported neither a list nor an error. Treat the ambiguity
                    // as failure rather than loading without the block.
                    continuation.resume(
                        throwing: SecureHTMLPreviewConfigurationError
                            .contentRuleListCompilationFailed("compiler returned no rule list")
                    )
                    return
                }
                continuation.resume(returning: ruleList)
            }
        }
    }
}
