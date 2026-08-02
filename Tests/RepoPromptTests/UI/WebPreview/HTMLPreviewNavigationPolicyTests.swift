@testable import RepoPromptApp
import XCTest

/// Literal, well-formed URLs for the matrix below, parsed in one place so the test
/// bodies stay readable and a malformed literal fails loudly instead of silently
/// changing what is being asserted.
private func previewTestURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("invalid test URL literal: \(string)")
    }
    return url
}

/// The preview renders untrusted, agent-authored HTML, so this matrix is the
/// load-bearing security test for the surface: it is pure, instantiates no web view,
/// and enumerates both the permitted navigations and the hostile ones.
final class HTMLPreviewNavigationPolicyTests: XCTestCase {
    private let policy = HTMLPreviewNavigationPolicy(mode: .scriptsBlocked)

    private let documentURL = previewTestURL("repoprompt-preview://document/report.html")

    // MARK: - Permitted navigations

    func testInScopeMainFrameLoadsAreAllowed() {
        // The initial programmatic load arrives as `.other`; history and reload
        // navigations must keep working once a document is committed.
        for navigationType: HTMLPreviewNavigationType in [.other, .backForward, .reload, .linkActivated] {
            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: documentURL,
                        navigationType: navigationType,
                        target: .mainFrame,
                        currentDocumentURL: documentURL
                    )
                ),
                .allow,
                "in-scope main-frame \(navigationType) should load"
            )
        }

        // A sibling document under the same root is still in scope.
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("repoprompt-preview://document/nested/other.html"),
                    navigationType: .linkActivated,
                    target: .mainFrame,
                    currentDocumentURL: documentURL
                )
            ),
            .allow
        )
    }

    func testSameDocumentFragmentNavigationIsAllowed() {
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("repoprompt-preview://document/report.html#section-2"),
                    navigationType: .linkActivated,
                    target: .mainFrame,
                    currentDocumentURL: documentURL
                )
            ),
            .allow
        )

        // A fragment is still only allowed because the destination is in scope; an
        // anchor whose host differs is a different origin and must not slip through.
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("repoprompt-preview://evil/report.html#section-2"),
                    navigationType: .linkActivated,
                    target: .mainFrame,
                    currentDocumentURL: documentURL
                )
            ),
            .cancel
        )
    }

    func testUserClickedWebLinksRequestExternalConfirmation() {
        for raw in ["http://example.com/page", "https://example.com/page"] {
            let url = previewTestURL(raw)

            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: url,
                        navigationType: .linkActivated,
                        target: .mainFrame,
                        currentDocumentURL: documentURL
                    )
                ),
                .openExternallyWithConfirmation(url)
            )

            // `target="_blank"` on a clicked link carries the same user intent.
            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: url,
                        navigationType: .linkActivated,
                        target: .newWindow,
                        currentDocumentURL: documentURL
                    )
                ),
                .openExternallyWithConfirmation(url)
            )
        }
    }

    // MARK: - Hostile navigations

    func testUnclickedWebNavigationsAreCancelledRatherThanPrompting() {
        // Redirects and scripted navigations arrive as something other than
        // `.linkActivated`. They must not be able to summon a confirmation dialog,
        // which would turn an automatic navigation into a user-attributed one.
        let url = previewTestURL("https://example.com/exfiltrate")
        for navigationType: HTMLPreviewNavigationType in [.other, .backForward, .reload] {
            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: url,
                        navigationType: navigationType,
                        target: .mainFrame,
                        currentDocumentURL: documentURL
                    )
                ),
                .cancel,
                "unclicked \(navigationType) navigation to the web should be cancelled"
            )
        }
    }

    func testHostileSchemesAreCancelledInEveryFrame() {
        let hostile = [
            "javascript:alert(document.title)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "file:///Users/someone/.ssh/id_rsa",
            "ws://localhost:9229/devtools",
            "wss://example.com/socket",
            "blob:repoprompt-preview://document/1234",
            "about:blank",
            "ftp://example.com/payload",
            "mailto:someone@example.com",
            "x-some-other-app://run"
        ]

        for raw in hostile {
            let url = previewTestURL(raw)
            for target: HTMLPreviewNavigationTarget in [.mainFrame, .subframe, .newWindow] {
                for navigationType: HTMLPreviewNavigationType in [.linkActivated, .other] {
                    XCTAssertEqual(
                        policy.decide(
                            HTMLPreviewNavigationRequest(
                                url: url,
                                navigationType: navigationType,
                                target: target,
                                currentDocumentURL: documentURL
                            )
                        ),
                        .cancel,
                        "\(raw) in \(target) as \(navigationType) should be cancelled"
                    )
                }
            }
        }
    }

    func testFormSubmissionsAreAlwaysCancelled() {
        // Checked before scope so that a form posting to an in-scope URL is refused
        // too: `form-action 'none'` is the contract, not "no external forms".
        let destinations = [
            documentURL,
            previewTestURL("https://example.com/collect"),
            previewTestURL("repoprompt-preview://document/collect")
        ]

        for url in destinations {
            for navigationType: HTMLPreviewNavigationType in [.formSubmitted, .formResubmitted] {
                for target: HTMLPreviewNavigationTarget in [.mainFrame, .subframe, .newWindow] {
                    XCTAssertEqual(
                        policy.decide(
                            HTMLPreviewNavigationRequest(
                                url: url,
                                navigationType: navigationType,
                                target: target,
                                currentDocumentURL: documentURL
                            )
                        ),
                        .cancel,
                        "form \(navigationType) to \(url) in \(target) should be cancelled"
                    )
                }
            }
        }
    }

    func testSubframeNavigationsAreAlwaysCancelled() {
        // `frame-src 'none'` means no frame should exist to navigate. Any subframe
        // navigation therefore indicates the CSP did not apply, so nothing is trusted
        // there — not even our own scheme.
        let destinations = [
            previewTestURL("http://example.com/tracker"),
            previewTestURL("https://example.com/tracker"),
            previewTestURL("repoprompt-preview://document/nested.html"),
            previewTestURL("data:text/html,<h1>nested</h1>")
        ]

        for url in destinations {
            for navigationType: HTMLPreviewNavigationType in [.linkActivated, .other, .backForward, .reload] {
                XCTAssertEqual(
                    policy.decide(
                        HTMLPreviewNavigationRequest(
                            url: url,
                            navigationType: navigationType,
                            target: .subframe,
                            currentDocumentURL: documentURL
                        )
                    ),
                    .cancel,
                    "subframe navigation to \(url) as \(navigationType) should be cancelled"
                )
            }
        }
    }

    func testNewWindowNavigationsAreCancelledUnlessUserClickedWebLink() {
        // `window.open` reaches the delegate as `.other` with no target frame.
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("https://example.com/popup"),
                    navigationType: .other,
                    target: .newWindow,
                    currentDocumentURL: documentURL
                )
            ),
            .cancel
        )

        // A new window must not be able to host preview content either — that would
        // escape the panel chrome and this delegate.
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("repoprompt-preview://document/report.html"),
                    navigationType: .linkActivated,
                    target: .newWindow,
                    currentDocumentURL: documentURL
                )
            ),
            .cancel
        )
    }

    func testOutOfScopePreviewURLsAreCancelled() {
        let outOfScope = [
            // Foreign host under our own scheme.
            "repoprompt-preview://evil/report.html",
            // Empty host.
            "repoprompt-preview:///report.html",
            // Host that merely contains the scope host.
            "repoprompt-preview://document.evil.test/report.html"
        ]

        for raw in outOfScope {
            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: previewTestURL(raw),
                        navigationType: .linkActivated,
                        target: .mainFrame,
                        currentDocumentURL: documentURL
                    )
                ),
                .cancel,
                "\(raw) should be out of scope"
            )
        }
    }

    func testSchemeAndHostMatchingIsCaseInsensitive() {
        // WebKit may normalize case, but the policy must not depend on it.
        XCTAssertEqual(
            policy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL("REPOPROMPT-PREVIEW://DOCUMENT/report.html"),
                    navigationType: .other,
                    target: .mainFrame,
                    currentDocumentURL: documentURL
                )
            ),
            .allow
        )
    }

    func testScriptedPolicyAllowsOnlyThePinnedDocumentToKeepScripts() {
        let pinned = previewTestURL("repoprompt-preview://document/reports/site/index.html")
        let scriptedPolicy = HTMLPreviewNavigationPolicy(
            mode: .scriptsEnabled,
            scriptedDocumentURL: pinned
        )

        for navigationType: HTMLPreviewNavigationType in [.other, .backForward, .reload, .linkActivated] {
            XCTAssertEqual(
                scriptedPolicy.decide(
                    HTMLPreviewNavigationRequest(
                        url: pinned,
                        navigationType: navigationType,
                        target: .mainFrame,
                        currentDocumentURL: pinned
                    )
                ),
                .allow
            )
        }

        XCTAssertEqual(
            scriptedPolicy.decide(
                HTMLPreviewNavigationRequest(
                    url: previewTestURL(
                        "repoprompt-preview://document/reports/site/index.html#section"
                    ),
                    navigationType: .linkActivated,
                    target: .mainFrame,
                    currentDocumentURL: pinned
                )
            ),
            .allow
        )
    }

    func testEveryDifferentInScopeDocumentNavigationExitsScriptedMode() {
        let pinned = previewTestURL("repoprompt-preview://document/reports/site/index.html")
        let different = previewTestURL(
            "repoprompt-preview://document/reports/site/other.html"
        )
        let scriptedPolicy = HTMLPreviewNavigationPolicy(
            mode: .scriptsEnabled,
            scriptedDocumentURL: pinned
        )

        // A script, meta refresh, history traversal, reload target, and user click all
        // take the same safe path: cancel here, then reopen through the scripts-off host.
        for navigationType: HTMLPreviewNavigationType in [.other, .backForward, .reload, .linkActivated] {
            XCTAssertEqual(
                scriptedPolicy.decide(
                    HTMLPreviewNavigationRequest(
                        url: different,
                        navigationType: navigationType,
                        target: .mainFrame,
                        currentDocumentURL: pinned
                    )
                ),
                .openInPreviewWithoutScripts(different)
            )
        }
    }

    func testScriptedPolicyDoesNotWidenExternalFormsFramesPopupsOrHostileSchemes() {
        let pinned = previewTestURL("repoprompt-preview://document/reports/site/index.html")
        let scriptedPolicy = HTMLPreviewNavigationPolicy(
            mode: .scriptsEnabled,
            scriptedDocumentURL: pinned
        )

        // Script can synthesize a linkActivated action with HTMLAnchorElement.click(),
        // so scripted mode must never turn any external navigation into a prompt.
        let externalAttempts: [(HTMLPreviewNavigationType, HTMLPreviewNavigationTarget)] = [
            (.linkActivated, .mainFrame),
            (.linkActivated, .newWindow),
            (.other, .mainFrame)
        ]
        for (navigationType, target) in externalAttempts {
            XCTAssertEqual(
                scriptedPolicy.decide(
                    HTMLPreviewNavigationRequest(
                        url: previewTestURL("https://example.com/exfiltrate"),
                        navigationType: navigationType,
                        target: target
                    )
                ),
                .cancel
            )
        }

        let refused: [(URL, HTMLPreviewNavigationType, HTMLPreviewNavigationTarget)] = [
            (pinned, .formSubmitted, .mainFrame),
            (pinned, .other, .subframe),
            (pinned, .other, .newWindow),
            (previewTestURL("javascript:alert(1)"), .linkActivated, .mainFrame),
            (previewTestURL("file:///etc/passwd"), .linkActivated, .mainFrame),
            (previewTestURL("ws://localhost:9229"), .other, .mainFrame)
        ]
        for (url, type, target) in refused {
            XCTAssertEqual(
                scriptedPolicy.decide(
                    HTMLPreviewNavigationRequest(
                        url: url,
                        navigationType: type,
                        target: target,
                        currentDocumentURL: pinned
                    )
                ),
                .cancel
            )
        }
    }

    func testMissingURLIsCancelled() {
        // WebKit reports `request.url == nil` for malformed or opaque requests.
        for target: HTMLPreviewNavigationTarget in [.mainFrame, .subframe, .newWindow] {
            XCTAssertEqual(
                policy.decide(
                    HTMLPreviewNavigationRequest(
                        url: nil,
                        navigationType: .linkActivated,
                        target: target,
                        currentDocumentURL: documentURL
                    )
                ),
                .cancel
            )
        }
    }
}
