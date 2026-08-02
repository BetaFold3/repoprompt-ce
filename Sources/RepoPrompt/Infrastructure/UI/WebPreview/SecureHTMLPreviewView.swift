import AppKit
import Foundation
import SwiftUI
import WebKit

/// Lifecycle of one preview surface, reported to the hosting view.
///
/// `.failed` is terminal for the current document: the surface shows the message and
/// no web view exists, which is how the fail-closed requirement stays observable from
/// the outside.
enum SecureHTMLPreviewState: Equatable {
    /// Building the configuration — notably compiling the remote-load rule list.
    /// No document has been loaded yet.
    case preparing
    case ready
    case failed(String)
}

/// A document identified the way the preview addresses it: a root plus a path
/// relative to that root. Absolute paths never reach the web view.
struct SecureHTMLPreviewDocument: Equatable {
    let documentRootURL: URL
    let relativePath: String
    let mode: SecureHTMLPreviewMode
}

/// The immutable privilege scope of an installed configuration.
private enum SecureHTMLPreviewPreparedScope: Equatable {
    case checkout(URL)
    case documentSubtree(rootURL: URL, relativePath: String)

    init(_ document: SecureHTMLPreviewDocument) {
        switch document.mode {
        case .scriptsBlocked:
            self = .checkout(document.documentRootURL)
        case .scriptsEnabled:
            self = .documentSubtree(
                rootURL: document.documentRootURL,
                relativePath: document.relativePath
            )
        }
    }
}

/// Owns the WKWebView for one preview surface.
///
/// Split out of the `NSViewRepresentable` because the representable is a value
/// recreated on every SwiftUI update, while the web view, its configuration, and the
/// in-flight preparation must survive those updates.
@MainActor
final class SecureHTMLPreviewController: NSObject {
    /// Always present, so SwiftUI has a stable view to mount while preparation runs.
    /// The web view is added only once its configuration exists.
    let containerView = NSView()

    var onExternalLinkRequested: ((URL) -> Void)?
    /// Called only for another in-scope main-frame document. The host must update its
    /// document reference, which clears script consent before the target is reloaded.
    var onInScopeDocumentRequested: ((URL) -> Void)?
    var onStateChange: ((SecureHTMLPreviewState) -> Void)?

    private var webView: WKWebView?
    /// The immutable privilege scope the live handler and data store were built for.
    private var preparedScope: SecureHTMLPreviewPreparedScope?
    private var requestedDocument: SecureHTMLPreviewDocument?
    private var loadedDocument: SecureHTMLPreviewDocument?
    private var preparationTask: Task<Void, Never>?
    private var reportedState: SecureHTMLPreviewState?

    deinit {
        preparationTask?.cancel()
    }

    /// Shows `relativePath` resolved against `documentRootURL`.
    ///
    /// Idempotent: SwiftUI calls this on every update, and repeating the current
    /// document must not reload the page and lose scroll position.
    func load(
        documentRootURL: URL,
        relativePath: String,
        mode: SecureHTMLPreviewMode
    ) {
        let document = SecureHTMLPreviewDocument(
            // Normalized here so that two spellings of the same root do not look like
            // a root change and needlessly rebuild the stack.
            documentRootURL: documentRootURL.resolvingSymlinksInPath().standardizedFileURL,
            relativePath: relativePath,
            mode: mode
        )
        guard document != requestedDocument else { return }
        requestedDocument = document

        // Static mode retains Phase-1's same-checkout reuse. Scripted mode's key also
        // includes the exact document path, so neither a mode change nor a different
        // document can inherit its handler, store, or JavaScript heap.
        if let webView, preparedScope == SecureHTMLPreviewPreparedScope(document) {
            commitLoad(document, in: webView)
            return
        }

        prepareAndLoad(document)
    }

    private func prepareAndLoad(_ document: SecureHTMLPreviewDocument) {
        teardownWebView()
        report(.preparing)

        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            do {
                let configuration = try await SecureHTMLPreviewConfiguration.make(
                    documentRootURL: document.documentRootURL,
                    documentRelativePath: document.relativePath,
                    mode: document.mode
                )
                guard !Task.isCancelled, let self, requestedDocument == document else { return }
                let webView = installWebView(
                    configuration: configuration,
                    preparedScope: SecureHTMLPreviewPreparedScope(document)
                )
                commitLoad(document, in: webView)
            } catch {
                guard !Task.isCancelled, let self, requestedDocument == document else { return }
                // No web view is installed on this path, so the fail-closed contract
                // holds structurally: there is nothing that could load a document.
                report(.failed(Self.describe(error)))
            }
        }
    }

    private func installWebView(
        configuration: WKWebViewConfiguration,
        preparedScope: SecureHTMLPreviewPreparedScope
    ) -> WKWebView {
        let webView = WKWebView(frame: containerView.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Backdrop for the overscroll region and for documents that declare no
        // background of their own, so the preview does not punch a white rectangle
        // into a dark window. Documents that set their own background are unaffected.
        // Public API only — the private `drawsBackground` key is deliberately not used.
        webView.underPageBackgroundColor = .textBackgroundColor

        // Web Inspector is a debugging affordance, not something to expose on
        // untrusted content in a shipped build.
        #if DEBUG
            webView.isInspectable = true
        #else
            webView.isInspectable = false
        #endif

        containerView.addSubview(webView)
        self.webView = webView
        self.preparedScope = preparedScope
        return webView
    }

    private func commitLoad(_ document: SecureHTMLPreviewDocument, in webView: WKWebView) {
        guard loadedDocument != document else { return }
        guard let url = RepoPreviewURLScheme.documentURL(relativePath: document.relativePath) else {
            report(.failed("Could not build a preview URL for \(document.relativePath)."))
            return
        }
        loadedDocument = document
        webView.load(URLRequest(url: url))
    }

    private func teardownWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        preparedScope = nil
        loadedDocument = nil
    }

    private func report(_ state: SecureHTMLPreviewState) {
        guard reportedState != state else { return }
        reportedState = state
        onStateChange?(state)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SecureHTMLPreviewConfigurationError.contentRuleListStoreUnavailable:
            "The preview could not start because its content blocker is unavailable."
        case let SecureHTMLPreviewConfigurationError.contentRuleListCompilationFailed(reason):
            "The preview could not start because its content blocker failed to compile (\(reason))."
        case RepoPreviewResourceError.documentSubtreeIsCheckoutRoot:
            """
            Scripts are unavailable because this document is at the checkout root, where its folder \
            would not be narrower than the checkout.
            """
        case RepoPreviewResourceError.hiddenPathComponent:
            "Scripts are unavailable for documents or assets under hidden paths."
        case RepoPreviewResourceError.invalidDocumentSubtree:
            "The preview could not establish a safe folder boundary for this document."
        case RepoPreviewResourceError.outsideDocumentSubtree,
             RepoPreviewResourceError.nonDocumentHTML:
            "The scripted preview refused a resource outside this document's folder scope."
        default:
            error.localizedDescription
        }
    }
}

// MARK: - Navigation policy

extension SecureHTMLPreviewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Navigation preferences are derived only from the immutable installed
        // document mode. A navigation action can never upgrade its own privilege.
        let mode = loadedDocument?.mode ?? .scriptsBlocked
        preferences.allowsContentJavaScript = mode.allowsContentJavaScript

        let request = HTMLPreviewNavigationRequest(
            url: navigationAction.request.url,
            navigationType: HTMLPreviewNavigationType(navigationAction.navigationType),
            target: HTMLPreviewNavigationTarget(navigationAction),
            currentDocumentURL: webView.url
        )

        let scriptedDocumentURL: URL? = if mode == .scriptsEnabled {
            loadedDocument.flatMap {
                RepoPreviewURLScheme.documentURL(relativePath: $0.relativePath)
            }
        } else {
            nil
        }
        let policy = HTMLPreviewNavigationPolicy(
            mode: mode,
            scriptedDocumentURL: scriptedDocumentURL
        )

        switch policy.decide(request) {
        case .allow:
            decisionHandler(.allow, preferences)
        case .cancel:
            decisionHandler(.cancel, preferences)
        case let .openExternallyWithConfirmation(url):
            // Cancelled here regardless; the host decides whether to confirm and open.
            decisionHandler(.cancel, preferences)
            onExternalLinkRequested?(url)
        case let .openInPreviewWithoutScripts(url):
            // The current scripted stack never commits this load. The host first
            // changes the exact document reference (revoking consent), after which
            // SwiftUI prepares a fresh scripts-blocked configuration for the target.
            decisionHandler(.cancel, preferences)
            onInScopeDocumentRequested?(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        report(.ready)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    private func reportNavigationFailure(_ error: Error) {
        // Every policy refusal surfaces as a cancellation. Those are the mechanism
        // working, not a failure of the preview, so they must not replace the rendered
        // document with an error state.
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        report(.failed(error.localizedDescription))
    }
}

// MARK: - Popups

extension SecureHTMLPreviewController: WKUIDelegate {
    /// Returning `nil` refuses the new web view outright, so no popup window can be
    /// created even if a navigation ever reaches this point.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

// MARK: - WebKit bridge

extension HTMLPreviewNavigationType {
    /// Unknown future WebKit cases collapse to `.other`, which the policy treats as
    /// untrusted rather than as a link the user clicked.
    init(_ navigationType: WKNavigationType) {
        switch navigationType {
        case .linkActivated: self = .linkActivated
        case .formSubmitted: self = .formSubmitted
        case .backForward: self = .backForward
        case .reload: self = .reload
        case .formResubmitted: self = .formResubmitted
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}

extension HTMLPreviewNavigationTarget {
    /// A `nil` target frame means the navigation would create a window.
    init(_ navigationAction: WKNavigationAction) {
        guard let targetFrame = navigationAction.targetFrame else {
            self = .newWindow
            return
        }
        self = targetFrame.isMainFrame ? .mainFrame : .subframe
    }
}

// MARK: - SwiftUI surface

/// Renders untrusted, agent-authored HTML under `SecureHTMLPreviewConfiguration`.
///
/// Hostile fixtures for the manual verification pass live in
/// `Tests/RepoPromptTests/UI/WebPreview/Fixtures/` — see
/// `SecureHTMLPreviewFixtureTests` for the inventory and what each one probes.
struct SecureHTMLPreviewView: NSViewRepresentable {
    let documentRootURL: URL
    let relativePath: String
    /// Must be `.scriptsEnabled` only after an explicit, exact-document consent in
    /// the host. The controller rebuilds rather than mutating an installed stack.
    let mode: SecureHTMLPreviewMode
    /// Invoked when the user activates an http(s) link. The host is expected to
    /// confirm before handing the URL to `NSWorkspace`, because opening it moves
    /// untrusted content into an unrestricted context.
    var onExternalLinkRequested: (URL) -> Void
    var onInScopeDocumentRequested: (URL) -> Void
    var onStateChange: (SecureHTMLPreviewState) -> Void

    func makeCoordinator() -> SecureHTMLPreviewController {
        SecureHTMLPreviewController()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onExternalLinkRequested = onExternalLinkRequested
        context.coordinator.onInScopeDocumentRequested = onInScopeDocumentRequested
        context.coordinator.onStateChange = onStateChange
        context.coordinator.load(
            documentRootURL: documentRootURL,
            relativePath: relativePath,
            mode: mode
        )
    }
}
