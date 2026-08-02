import Foundation

/// Navigation kinds the HTML preview distinguishes.
///
/// This mirrors only the subset of `WKNavigationType` that changes a decision.
/// The WebKit bridge (`SecureHTMLPreviewView`) maps every unrecognized raw value
/// onto `.other` so that a future WebKit case cannot silently widen the policy.
enum HTMLPreviewNavigationType: Equatable {
    case linkActivated
    case formSubmitted
    case backForward
    case reload
    case formResubmitted
    case other
}

/// Where a navigation would be committed.
enum HTMLPreviewNavigationTarget: Equatable {
    case mainFrame
    case subframe
    /// `WKNavigationAction.targetFrame == nil` — a frame that does not exist yet:
    /// `window.open`, `target="_blank"`, or any other new-window request.
    case newWindow
}

/// A WebKit-free description of one navigation attempt.
///
/// The policy is deliberately given a value type rather than a `WKNavigationAction`
/// so the entire decision matrix is unit-testable without instantiating a web view.
struct HTMLPreviewNavigationRequest: Equatable {
    /// `WKNavigationAction.request.url`, which WebKit may report as `nil` for a
    /// malformed or opaque request.
    var url: URL?
    var navigationType: HTMLPreviewNavigationType
    var target: HTMLPreviewNavigationTarget
    /// The document currently committed in the main frame, used to recognize
    /// same-document fragment navigation. `nil` before the first commit.
    var currentDocumentURL: URL?

    init(
        url: URL?,
        navigationType: HTMLPreviewNavigationType,
        target: HTMLPreviewNavigationTarget,
        currentDocumentURL: URL? = nil
    ) {
        self.url = url
        self.navigationType = navigationType
        self.target = target
        self.currentDocumentURL = currentDocumentURL
    }
}

/// The four outcomes the preview surface supports.
enum HTMLPreviewNavigationDecision: Equatable {
    /// Commit the navigation inside the preview web view.
    case allow
    /// Refuse the navigation. Nothing is loaded and nothing is shown to the user.
    case cancel
    /// Refuse the navigation inside the web view, but offer to hand the URL to the
    /// system browser. The caller is responsible for presenting the confirmation
    /// and for the eventual `NSWorkspace` open; the policy never opens anything.
    ///
    /// Leaving the preview moves untrusted agent-authored content into an
    /// unrestricted context, so this must never happen without user intent.
    case openExternallyWithConfirmation(URL)
    /// Refuse this load in the scripted web view and ask the host to reopen the
    /// in-scope document under the scripts-blocked configuration.
    case openInPreviewWithoutScripts(URL)
}

/// Decides what an agent-authored HTML document is allowed to navigate to.
///
/// The preview renders untrusted content: an agent can write any HTML it likes into
/// a report and can plant symlinks beside it. The policy is therefore a deny-list
/// inversion — it enumerates the few navigations that are safe and cancels
/// everything else, including navigation kinds that do not exist yet.
///
/// Containment of a `repoprompt-preview://` path inside the document root is *not*
/// checked here; that is `RepoPreviewResourceResolver`'s single responsibility.
/// This type only decides scope at the scheme/host level.
struct HTMLPreviewNavigationPolicy {
    let scheme: String
    let scopeHost: String
    /// Explicit execution mode for this policy evaluation. External-link behavior
    /// must not be inferred from whether another optional value happens to be present.
    let mode: SecureHTMLPreviewMode
    /// The one main-frame document that may retain JavaScript permission in scripted
    /// mode. A missing pin while scripts are enabled fails closed.
    let scriptedDocumentURL: URL?

    init(
        scheme: String = RepoPreviewURLScheme.scheme,
        scopeHost: String = RepoPreviewURLScheme.scopeHost,
        mode: SecureHTMLPreviewMode = .scriptsBlocked,
        scriptedDocumentURL: URL? = nil
    ) {
        self.scheme = scheme
        self.scopeHost = scopeHost
        self.mode = mode
        self.scriptedDocumentURL = scriptedDocumentURL
    }

    func decide(_ request: HTMLPreviewNavigationRequest) -> HTMLPreviewNavigationDecision {
        // A request WebKit cannot even express as a URL is never safe to commit.
        guard let url = request.url else { return .cancel }

        // 1. Form submissions never leave the preview. `form-action 'none'` in the CSP
        //    should already have blocked this; cancelling here keeps the guarantee even
        //    if a response ever reaches the web view without our CSP header.
        switch request.navigationType {
        case .formSubmitted, .formResubmitted:
            return .cancel
        case .linkActivated, .backForward, .reload, .other:
            break
        }

        // 2. Scripted documents cannot raise an external-open confirmation at all.
        //    WebKit classifies a synthetic HTMLAnchorElement.click() as linkActivated,
        //    so navigation type cannot distinguish script from genuine user intent.
        if mode == .scriptsEnabled, isExternalWebURL(url) {
            return .cancel
        }

        // 3. New windows. No document may ever be committed into one, because a popup
        //    would escape both the preview chrome and this delegate. In scripts-blocked
        //    mode only, a clicked web link is routed through confirmation.
        if request.target == .newWindow {
            if request.navigationType == .linkActivated, isExternalWebURL(url) {
                return .openExternallyWithConfirmation(url)
            }
            return .cancel
        }

        // 4. Subframes. `frame-src 'none'` means no frame should exist to navigate,
        //    so any subframe navigation indicates the CSP was not applied. Cancel
        //    unconditionally rather than trying to decide what a nested document may do.
        if request.target == .subframe {
            return .cancel
        }

        // --- Main frame from here on. ---

        // 5. In scripts-blocked mode, a user-clicked http(s) link is the one
        //    legitimate way out of the preview. Only `.linkActivated` qualifies:
        //    redirects and other unclicked navigations cannot summon a dialog.
        if request.navigationType == .linkActivated, isExternalWebURL(url) {
            return .openExternallyWithConfirmation(url)
        }

        // 6. Loads of our own scheme inside the document scope.
        if isInScopePreviewURL(url) {
            switch mode {
            case .scriptsBlocked:
                return .allow
            case .scriptsEnabled:
                guard let scriptedDocumentURL else { return .cancel }
                guard isSamePreviewDocument(url, as: scriptedDocumentURL) else {
                    // Never commit a different document under the scripted handler.
                    // The host clears the exact-reference grant, builds a fresh static
                    // configuration, and only then loads this target.
                    return .openInPreviewWithoutScripts(url)
                }
                return .allow
            }
        }

        // 7. Same-document fragment navigation (in-page anchors). Redundant with rule 6
        //    while the document is always in scope, but stated explicitly so the
        //    anchor-link contract is enforced by name rather than by coincidence.
        if isSameDocumentFragmentNavigation(url, currentDocumentURL: request.currentDocumentURL) {
            return .allow
        }

        // 8. Fail closed: file://, data:, javascript:, ws://, blob:, about:, custom
        //    schemes registered by other apps, and anything WebKit invents later.
        return .cancel
    }

    // MARK: - Classification

    /// `http`/`https` only. Deliberately excludes every other network-capable scheme
    /// (`ws`, `ftp`, `mailto`, app schemes) so they fall through to `.cancel` rather
    /// than being handed to `NSWorkspace`.
    private func isExternalWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// In scope means our scheme *and* our fixed scope host. A different host is a
    /// different origin as far as WebKit is concerned, so it is treated as foreign.
    private func isInScopePreviewURL(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), urlScheme == scheme.lowercased() else {
            return false
        }
        guard let host = url.host?.lowercased(), host == scopeHost.lowercased() else {
            return false
        }
        return true
    }

    /// Resource identity ignores fragment and query because the scheme handler maps
    /// only the decoded path to disk. Both values must already be in scope.
    private func isSamePreviewDocument(_ url: URL, as scriptedDocumentURL: URL) -> Bool {
        guard isInScopePreviewURL(scriptedDocumentURL) else { return false }
        return url.path == scriptedDocumentURL.path
    }

    /// True when `url` differs from the committed document only by fragment, and the
    /// committed document is itself in scope. Both sides must be in scope so a
    /// document that somehow loaded from elsewhere cannot authorize its own anchors.
    private func isSameDocumentFragmentNavigation(_ url: URL, currentDocumentURL: URL?) -> Bool {
        guard let currentDocumentURL else { return false }
        guard isInScopePreviewURL(url), isInScopePreviewURL(currentDocumentURL) else { return false }
        guard url.fragment != nil else { return false }
        return Self.strippingFragment(url) == Self.strippingFragment(currentDocumentURL)
    }

    private static func strippingFragment(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.string
    }
}
