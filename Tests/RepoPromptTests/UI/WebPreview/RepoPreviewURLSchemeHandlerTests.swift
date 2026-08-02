@testable import RepoPromptApp
import XCTest

/// Literal, well-formed URLs, parsed in one place so a malformed literal fails loudly
/// instead of silently changing what is being asserted.
private func schemeTestURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("invalid test URL literal: \(string)")
    }
    return url
}

/// Containment tests for the preview scheme handler.
///
/// These exercise `RepoPreviewResourceResolver` and the response builder directly
/// against a real temp directory — including real symlinks — because that is where
/// the path security lives. No `WKWebView` is instantiated.
final class RepoPreviewURLSchemeHandlerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var documentRoot: URL!
    private var outsideDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Resolved up front: on macOS the temp directory lives behind the `/var` ->
        // `/private/var` symlink, and the assertions below compare real paths.
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("web-preview-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        documentRoot = temporaryDirectory.appendingPathComponent("root", isDirectory: true)
        outsideDirectory = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path

    func testResolvesRegularFilesInsideDocumentRoot() throws {
        try write("<h1>report</h1>", to: "report.html")
        try FileManager.default.createDirectory(
            at: documentRoot.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try write("body { color: red; }", to: "assets/site.css")

        let resolver = makeResolver()

        let document = try resolver.resolve(previewURL("/report.html"))
        XCTAssertEqual(document.fileURL, documentRoot.appendingPathComponent("report.html"))
        XCTAssertEqual(document.mimeType, "text/html; charset=utf-8")
        XCTAssertEqual(document.byteCount, 15)
        XCTAssertEqual(document.data, Data("<h1>report</h1>".utf8))

        let stylesheet = try resolver.resolve(previewURL("/assets/site.css"))
        XCTAssertEqual(stylesheet.mimeType, "text/css; charset=utf-8")
        XCTAssertEqual(stylesheet.data, Data("body { color: red; }".utf8))
    }

    func testResolvesSymlinkThatStaysInsideDocumentRoot() throws {
        try write("<h1>real</h1>", to: "real.html")
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("link.html"),
            withDestinationURL: documentRoot.appendingPathComponent("real.html")
        )

        let resolved = try makeResolver().resolve(previewURL("/link.html"))

        // The link is followed, and what is served is the real file inside the root.
        XCTAssertEqual(resolved.fileURL, documentRoot.appendingPathComponent("real.html"))
        XCTAssertEqual(resolved.mimeType, "text/html; charset=utf-8")
    }

    // MARK: - Traversal and containment

    func testRejectsDotSegmentTraversalIncludingPercentEncodedForms() throws {
        try write("secret", to: "../outside/secret.txt")

        let resolver = makeResolver()
        let traversals = [
            "/../outside/secret.txt",
            "/%2e%2e/outside/secret.txt",
            "/%2E%2E/outside/secret.txt",
            "/assets/../../outside/secret.txt",
            "/./report.html"
        ]

        for path in traversals {
            assertRefusesToEscape(resolver, path)
        }
    }

    func testRejectsAbsolutePathRequests() {
        let resolver = makeResolver()

        // A leading slash cannot re-root the request: empty components are dropped, so
        // the request is resolved under the document root and simply is not there.
        for path in ["//etc/passwd", "///etc/passwd", "//private/etc/hosts"] {
            assertRefusesToEscape(resolver, path)
        }
    }

    func testRejectsSymlinkEscapingDocumentRoot() throws {
        // The realistic hostile shape: an agent writes a report and drops a symlink
        // beside it. The link's own path looks contained, so containment must be
        // evaluated only after the link is resolved.
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        try "secret".write(
            to: outsideDirectory.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("escape.txt"),
            withDestinationURL: outsideDirectory.appendingPathComponent("secret.txt")
        )

        assertResolveThrows(makeResolver(), "/escape.txt", .escapesDocumentRoot)
    }

    func testRejectsSymlinkedDirectoryEscapingDocumentRoot() throws {
        try "secret".write(
            to: outsideDirectory.appendingPathComponent("secret.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("away"),
            withDestinationURL: outsideDirectory
        )

        assertResolveThrows(makeResolver(), "/away/secret.txt", .escapesDocumentRoot)
    }

    func testRejectsFinalComponentSymlinkSwapAfterPathValidation() throws {
        try write("safe", to: "report.html")
        let requestedFile = documentRoot.appendingPathComponent("report.html")
        let outsideFile = outsideDirectory.appendingPathComponent("secret.html")
        try "outside secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try makeResolver().resolve(
                previewURL("/report.html"),
                afterPathValidation: {
                    try FileManager.default.removeItem(at: requestedFile)
                    try FileManager.default.createSymbolicLink(
                        at: requestedFile,
                        withDestinationURL: outsideFile
                    )
                }
            )
        ) { error in
            XCTAssertEqual(error as? RepoPreviewResourceError, .notARegularFile)
        }
    }

    func testContainmentComparesPathComponentsNotStringPrefixes() {
        // `/root-evil` shares a string prefix with `/root` but is not inside it.
        XCTAssertFalse(
            RepoPreviewResourceResolver.isContained(
                URL(fileURLWithPath: "/tmp/root-evil/secret.txt"),
                in: URL(fileURLWithPath: "/tmp/root")
            )
        )
        XCTAssertTrue(
            RepoPreviewResourceResolver.isContained(
                URL(fileURLWithPath: "/tmp/root/nested/file.txt"),
                in: URL(fileURLWithPath: "/tmp/root")
            )
        )
        // The root itself is contained in the root.
        XCTAssertTrue(
            RepoPreviewResourceResolver.isContained(
                URL(fileURLWithPath: "/tmp/root"),
                in: URL(fileURLWithPath: "/tmp/root")
            )
        )
        XCTAssertFalse(
            RepoPreviewResourceResolver.isContained(
                URL(fileURLWithPath: "/tmp"),
                in: URL(fileURLWithPath: "/tmp/root")
            )
        )
    }

    // MARK: - Non-file and oversized targets

    func testRejectsDirectoriesMissingFilesAndEmptyPaths() throws {
        try FileManager.default.createDirectory(
            at: documentRoot.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )

        let resolver = makeResolver()
        // A directory would otherwise be read as a document; a FIFO would block the
        // read entirely, which is why the check is "is a regular file", not "is not a
        // directory".
        assertResolveThrows(resolver, "/assets", .notARegularFile)
        assertResolveThrows(resolver, "/missing.html", .notFound)
        assertResolveThrows(resolver, "/", .emptyPath)
    }

    func testRejectsResourcesAboveTheSizeCap() throws {
        try write(String(repeating: "a", count: 100), to: "large.html")
        try write(String(repeating: "b", count: 10), to: "growing.html")

        let resolver = RepoPreviewResourceResolver(
            documentRootURL: documentRoot,
            maximumResourceByteCount: 10
        )

        assertResolveThrows(resolver, "/large.html", .tooLarge(byteCount: 100, limit: 10))

        let growingFile = documentRoot.appendingPathComponent("growing.html")
        XCTAssertThrowsError(
            try resolver.resolve(
                previewURL("/growing.html"),
                afterPathValidation: {},
                afterDescriptorValidation: {
                    let handle = try FileHandle(forWritingTo: growingFile)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("x".utf8))
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? RepoPreviewResourceError,
                .tooLarge(byteCount: 11, limit: 10)
            )
        }
    }

    func testRejectsForeignSchemeAndHost() throws {
        try write("<h1>report</h1>", to: "report.html")
        let resolver = makeResolver()

        let fileURL = schemeTestURL("file:///report.html")
        XCTAssertThrowsError(try resolver.resolve(fileURL)) { error in
            XCTAssertEqual(error as? RepoPreviewResourceError, .unsupportedScheme)
        }

        let foreignHostURL = schemeTestURL("repoprompt-preview://evil/report.html")
        XCTAssertThrowsError(try resolver.resolve(foreignHostURL)) { error in
            XCTAssertEqual(error as? RepoPreviewResourceError, .unsupportedHost)
        }
    }

    // MARK: - Scripted document-subtree boundary

    func testScriptedBoundaryAllowsOnlyTheSelectedDocumentAndItsFolderAssets() throws {
        try write("<h1>report</h1>", to: "reports/site/index.html")
        try write("window.reportLoaded = true", to: "reports/site/app.js")
        try write("body { color: green; }", to: "reports/site/assets/theme.css")
        try write("parent", to: "reports/parent.txt")
        try write("sibling", to: "reports/sibling/secret.js")
        try write("<h1>other</h1>", to: "reports/site/other.html")

        let resolver = try makeScriptedResolver(documentRelativePath: "reports/site/index.html")

        XCTAssertEqual(resolver.assetBoundary, .documentSubtree)
        XCTAssertEqual(
            try resolver.resolve(previewURL("/reports/site/index.html")).fileURL,
            documentRoot.appendingPathComponent("reports/site/index.html")
        )
        XCTAssertEqual(
            try resolver.resolve(previewURL("/reports/site/app.js")).mimeType,
            "text/javascript; charset=utf-8"
        )
        XCTAssertEqual(
            try resolver.resolve(previewURL("/reports/site/assets/theme.css")).mimeType,
            "text/css; charset=utf-8"
        )
        assertResolveThrows(resolver, "/reports/parent.txt", .outsideDocumentSubtree)
        assertResolveThrows(resolver, "/reports/sibling/secret.js", .outsideDocumentSubtree)
        assertResolveThrows(resolver, "/reports/site/other.html", .nonDocumentHTML)
    }

    func testScriptedBoundaryRejectsDotEntriesAfterSymlinkResolution() throws {
        try write("<h1>report</h1>", to: "reports/site/index.html")
        try write("secret", to: "reports/site/.env")
        try write("token", to: "reports/site/.cache/token.txt")
        try write("root secret", to: ".root-secret")
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("reports/site/visible-token.txt"),
            withDestinationURL: documentRoot.appendingPathComponent("reports/site/.cache/token.txt")
        )

        let resolver = try makeScriptedResolver(documentRelativePath: "reports/site/index.html")

        for path in [
            "/reports/site/.env",
            "/reports/site/.cache/token.txt",
            "/reports/site/visible-token.txt",
            "/.root-secret"
        ] {
            assertResolveThrows(resolver, path, .hiddenPathComponent)
        }
    }

    func testScriptedBoundaryRejectsSymlinksAndEncodedTraversalOutsideTheSubtree() throws {
        try write("<h1>report</h1>", to: "reports/site/index.html")
        try write("allowed", to: "reports/site/assets/real.js")
        try write("sibling", to: "reports/sibling/secret.js")
        try "outside".write(
            to: outsideDirectory.appendingPathComponent("outside.js"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("reports/site/assets/inside.js"),
            withDestinationURL: documentRoot.appendingPathComponent("reports/site/assets/real.js")
        )
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("reports/site/sibling.js"),
            withDestinationURL: documentRoot.appendingPathComponent("reports/sibling/secret.js")
        )
        try FileManager.default.createSymbolicLink(
            at: documentRoot.appendingPathComponent("reports/site/external.js"),
            withDestinationURL: outsideDirectory.appendingPathComponent("outside.js")
        )

        let resolver = try makeScriptedResolver(documentRelativePath: "reports/site/index.html")

        XCTAssertEqual(
            try resolver.resolve(previewURL("/reports/site/assets/inside.js")).fileURL,
            documentRoot.appendingPathComponent("reports/site/assets/real.js")
        )
        assertResolveThrows(resolver, "/reports/site/sibling.js", .outsideDocumentSubtree)
        assertResolveThrows(resolver, "/reports/site/external.js", .escapesDocumentRoot)

        // This is the malicious scripted-fixture shape after URL normalization:
        // ../sibling becomes an in-scheme checkout path, which the subtree lock denies.
        for path in [
            "/reports/site/../sibling/secret.js",
            "/reports/site/%2e%2e/sibling/secret.js",
            "/reports/sibling/secret.js"
        ] {
            XCTAssertThrowsError(try resolver.resolve(previewURL(path)), path)
        }
    }

    func testScriptedMaliciousFixtureCannotReadItsSiblingThroughTheScheme() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let resolver = try RepoPreviewResourceResolver(
            documentRootURL: fixtureRoot,
            documentRelativePath: "scripted/script-folder-boundary.html",
            assetBoundary: .documentSubtree
        )

        assertResolveThrows(
            resolver,
            "/sibling/script-oracle.js",
            .outsideDocumentSubtree
        )
    }

    func testScriptedBoundaryRefusesRootLevelAndHiddenDocuments() throws {
        try write("<h1>root</h1>", to: "index.html")
        try write("<h1>hidden</h1>", to: ".reports/index.html")

        XCTAssertThrowsError(
            try makeScriptedResolver(documentRelativePath: "index.html")
        ) { error in
            XCTAssertEqual(
                error as? RepoPreviewResourceError,
                .documentSubtreeIsCheckoutRoot
            )
        }
        XCTAssertThrowsError(
            try makeScriptedResolver(documentRelativePath: ".reports/index.html")
        ) { error in
            XCTAssertEqual(error as? RepoPreviewResourceError, .hiddenPathComponent)
        }
    }

    // MARK: - MIME mapping

    func testMimeTypeMappingCoversPermittedAssetsAndFailsClosed() {
        let expected: [String: String] = [
            "html": "text/html; charset=utf-8",
            "htm": "text/html; charset=utf-8",
            "HTML": "text/html; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
            "svg": "image/svg+xml",
            "woff": "font/woff",
            "woff2": "font/woff2",
            "ttf": "font/ttf",
            "otf": "font/otf"
        ]

        for (pathExtension, mimeType) in expected {
            XCTAssertEqual(
                RepoPreviewResourceResolver.mimeType(forPathExtension: pathExtension),
                mimeType
            )
        }

        // Script and everything else fall through to a type the web view will not
        // execute or render inline, so the MIME table agrees with `script-src 'none'`.
        for pathExtension in ["js", "mjs", "wasm", "json", "exe", ""] {
            XCTAssertEqual(
                RepoPreviewResourceResolver.mimeType(forPathExtension: pathExtension),
                "application/octet-stream",
                "\(pathExtension) should not receive an executable or inline-renderable type"
            )
        }
    }

    // MARK: - Response headers

    func testEveryResponseCarriesTheContentSecurityPolicyAndNosniff() throws {
        let url = previewURL("/report.html")
        let response = try XCTUnwrap(
            RepoPreviewURLSchemeHandler.makeResponse(
                url: url,
                mimeType: "text/html; charset=utf-8",
                byteCount: 15
            )
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Security-Policy"),
            RepoPreviewURLScheme.contentSecurityPolicy
        )
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "15")
    }

    func testContentSecurityPolicyLocksDownEveryFetchDirective() {
        let policy = RepoPreviewURLScheme.contentSecurityPolicy
        let directives = policy
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Each directive is asserted individually so that loosening one is a
        // deliberate, visible edit to this list.
        XCTAssertTrue(directives.contains("default-src 'none'"))
        XCTAssertTrue(directives.contains("script-src 'none'"))
        XCTAssertTrue(directives.contains("connect-src 'none'"))
        XCTAssertTrue(directives.contains("frame-src 'none'"))
        XCTAssertTrue(directives.contains("form-action 'none'"))
        XCTAssertTrue(directives.contains("base-uri 'none'"))
        XCTAssertTrue(directives.contains("img-src repoprompt-preview:"))
        XCTAssertTrue(directives.contains("font-src repoprompt-preview:"))
        XCTAssertTrue(directives.contains("style-src repoprompt-preview: 'unsafe-inline'"))

        // No directive may name a network origin.
        for scheme in ["http:", "https:", "ws:", "wss:", "data:", "*"] {
            XCTAssertFalse(
                policy.contains(scheme),
                "CSP must not permit \(scheme)"
            )
        }
    }

    func testStaticAndScriptedPoliciesAreExactAndModeSpecific() throws {
        let phaseOnePolicy = """
        default-src 'none'; img-src repoprompt-preview:; style-src repoprompt-preview: 'unsafe-inline'; \
        font-src repoprompt-preview:; script-src 'none'; connect-src 'none'; frame-src 'none'; \
        form-action 'none'; base-uri 'none'
        """
        let scriptedPolicy = """
        default-src 'none'; img-src repoprompt-preview:; style-src repoprompt-preview: 'unsafe-inline'; \
        font-src repoprompt-preview:; script-src 'unsafe-inline' repoprompt-preview:; worker-src 'none'; \
        connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'
        """

        XCTAssertEqual(RepoPreviewURLScheme.contentSecurityPolicy, phaseOnePolicy)
        XCTAssertEqual(
            RepoPreviewURLScheme.contentSecurityPolicy(for: .checkout),
            phaseOnePolicy,
            "the default response policy must remain byte-identical to Phase 1"
        )
        XCTAssertEqual(RepoPreviewURLScheme.scriptedContentSecurityPolicy, scriptedPolicy)
        XCTAssertEqual(
            RepoPreviewURLScheme.contentSecurityPolicy(for: .documentSubtree),
            scriptedPolicy
        )
        XCTAssertEqual(
            RepoPreviewResourceResolver.mimeType(forPathExtension: "js"),
            "application/octet-stream"
        )
        XCTAssertEqual(
            RepoPreviewResourceResolver.mimeType(
                forPathExtension: "js",
                allowingJavaScript: true
            ),
            "text/javascript; charset=utf-8"
        )

        for policy in [phaseOnePolicy, scriptedPolicy] {
            for networkSource in ["http:", "https:", "ws:", "wss:", "data:", "*"] {
                XCTAssertFalse(policy.contains(networkSource))
            }
            XCTAssertTrue(policy.contains("connect-src 'none'"))
            XCTAssertTrue(policy.contains("frame-src 'none'"))
            XCTAssertTrue(policy.contains("form-action 'none'"))
            XCTAssertTrue(policy.contains("base-uri 'none'"))
        }

        let scriptedResponse = try XCTUnwrap(
            RepoPreviewURLSchemeHandler.makeResponse(
                url: previewURL("/reports/site/index.html"),
                mimeType: "text/html; charset=utf-8",
                byteCount: 1,
                contentSecurityPolicy: scriptedPolicy
            )
        )
        XCTAssertEqual(
            scriptedResponse.value(forHTTPHeaderField: "Content-Security-Policy"),
            scriptedPolicy
        )
        XCTAssertEqual(
            scriptedResponse.value(forHTTPHeaderField: "X-Content-Type-Options"),
            "nosniff"
        )
    }

    @MainActor
    func testConfigurationFactoryAlignsJavaScriptBoundaryAndFreshStoresPerMode() async throws {
        try write("<h1>report</h1>", to: "reports/site/index.html")

        let staticConfiguration = try await SecureHTMLPreviewConfiguration.make(
            documentRootURL: documentRoot,
            documentRelativePath: "reports/site/index.html",
            mode: .scriptsBlocked
        )
        let scriptedConfiguration = try await SecureHTMLPreviewConfiguration.make(
            documentRootURL: documentRoot,
            documentRelativePath: "reports/site/index.html",
            mode: .scriptsEnabled
        )
        let secondScriptedConfiguration = try await SecureHTMLPreviewConfiguration.make(
            documentRootURL: documentRoot,
            documentRelativePath: "reports/site/index.html",
            mode: .scriptsEnabled
        )

        XCTAssertFalse(staticConfiguration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(scriptedConfiguration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(staticConfiguration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(scriptedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(staticConfiguration.websiteDataStore.isPersistent)
        XCTAssertFalse(scriptedConfiguration.websiteDataStore.isPersistent)
        XCTAssertFalse(
            scriptedConfiguration.websiteDataStore === secondScriptedConfiguration.websiteDataStore,
            "every scripted load must receive a fresh non-persistent store"
        )

        let staticHandler = try XCTUnwrap(
            staticConfiguration.urlSchemeHandler(forURLScheme: RepoPreviewURLScheme.scheme)
                as? RepoPreviewURLSchemeHandler
        )
        let scriptedHandler = try XCTUnwrap(
            scriptedConfiguration.urlSchemeHandler(forURLScheme: RepoPreviewURLScheme.scheme)
                as? RepoPreviewURLSchemeHandler
        )
        XCTAssertEqual(staticHandler.assetBoundary, .checkout)
        XCTAssertEqual(scriptedHandler.assetBoundary, .documentSubtree)
    }

    func testDocumentURLBuildsInScopeURLsAndEncodesPathComponents() throws {
        let simple = try XCTUnwrap(RepoPreviewURLScheme.documentURL(relativePath: "report.html"))
        XCTAssertEqual(simple.scheme, RepoPreviewURLScheme.scheme)
        XCTAssertEqual(simple.host, RepoPreviewURLScheme.scopeHost)
        XCTAssertEqual(simple.path, "/report.html")

        // A leading slash in the relative path must not produce an empty first
        // component that could read as an authority.
        let leadingSlash = try XCTUnwrap(RepoPreviewURLScheme.documentURL(relativePath: "/report.html"))
        XCTAssertEqual(leadingSlash.path, "/report.html")

        // Characters that are URL syntax must survive as path, not as syntax.
        let awkward = try XCTUnwrap(
            RepoPreviewURLScheme.documentURL(relativePath: "notes/my report #1.html")
        )
        XCTAssertEqual(awkward.path, "/notes/my report #1.html")
        XCTAssertNil(awkward.fragment)
    }

    // MARK: - Helpers

    private func makeResolver() -> RepoPreviewResourceResolver {
        RepoPreviewResourceResolver(documentRootURL: documentRoot)
    }

    private func makeScriptedResolver(
        documentRelativePath: String
    ) throws -> RepoPreviewResourceResolver {
        try RepoPreviewResourceResolver(
            documentRootURL: documentRoot,
            documentRelativePath: documentRelativePath,
            assetBoundary: .documentSubtree
        )
    }

    private func previewURL(_ path: String) -> URL {
        schemeTestURL("repoprompt-preview://document\(path)")
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = documentRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertResolveThrows(
        _ resolver: RepoPreviewResourceResolver,
        _ path: String,
        _ expected: RepoPreviewResourceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try resolver.resolve(previewURL(path)), path, file: file, line: line) { error in
            XCTAssertEqual(
                error as? RepoPreviewResourceError,
                expected,
                path,
                file: file,
                line: line
            )
        }
    }

    /// Asserts the security invariant rather than a specific refusal: however the
    /// request is spelled, it must never yield a file outside the document root.
    private func assertRefusesToEscape(
        _ resolver: RepoPreviewResourceResolver,
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let resolved = try resolver.resolve(previewURL(path))
            XCTAssertTrue(
                RepoPreviewResourceResolver.isContained(resolved.fileURL, in: resolver.documentRootURL),
                "\(path) resolved to \(resolved.fileURL.path), outside the document root",
                file: file,
                line: line
            )
        } catch {
            // Any refusal is an acceptable outcome; serving outside content is not.
        }
    }
}
