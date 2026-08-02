import Darwin
import Foundation
import WebKit

/// Naming and wire constants for the locked-down HTML preview scheme.
///
/// Agent-authored HTML is loaded through a private scheme instead of `file://` so
/// that the web view never holds a file-URL origin. A `file://` document can be
/// coaxed into reading sibling paths; a custom scheme can only reach what this
/// process chooses to hand back, and every hand-back goes through
/// `RepoPreviewResourceResolver`.
enum RepoPreviewURLScheme {
    /// Registered on the configuration via `setURLSchemeHandler(_:forURLScheme:)`.
    static let scheme = "repoprompt-preview"

    /// A single fixed host, so every previewed document shares one stable origin and
    /// any other host is recognizably out of scope. The host carries no meaning
    /// beyond scope identity — the document root is process state, never URL state,
    /// so a document cannot rewrite its own root by editing a link.
    static let scopeHost = "document"

    /// Content-Security-Policy sent with **every** response from the scheme handler.
    ///
    /// The document is untrusted, so the policy starts from nothing and re-adds only
    /// what a static report legitimately needs:
    ///
    /// - `default-src 'none'` — deny every fetch type that is not named below. New
    ///   CSP fetch directives introduced by future WebKit versions inherit this deny.
    /// - `img-src repoprompt-preview:` — images only from our own handler, which means
    ///   only from inside the resolved document root. No remote beacons.
    /// - `style-src repoprompt-preview: 'unsafe-inline'` — local stylesheets plus inline
    ///   `style` attributes/blocks, which ordinary agent-written reports rely on.
    ///   Inline CSS cannot execute script; with `script-src 'none'` the classic CSS
    ///   exfiltration paths still need a network fetch, which every other directive denies.
    /// - `font-src repoprompt-preview:` — local webfonts only.
    /// - `script-src 'none'` — no script of any origin, inline or otherwise. This is the
    ///   second of three independent JavaScript locks (the others are
    ///   `allowsContentJavaScript = false` on the configuration and on each navigation).
    /// - `connect-src 'none'` — no fetch/XHR/EventSource/WebSocket.
    /// - `frame-src 'none'` — no nested browsing contexts, so a report cannot embed a
    ///   remote page or a second document with different privileges.
    /// - `form-action 'none'` — no form target, so credentials typed into a spoofed
    ///   form have nowhere to go.
    /// - `base-uri 'none'` — the document cannot rewrite relative-URL resolution via
    ///   `<base>`, which would otherwise redirect every relative asset.
    ///
    /// Note that `frame-ancestors` is intentionally absent: nothing may frame this
    /// document because nothing else is ever loaded in the web view.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src repoprompt-preview:",
        "style-src repoprompt-preview: 'unsafe-inline'",
        "font-src repoprompt-preview:",
        "script-src 'none'",
        "connect-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'"
    ].joined(separator: "; ")

    /// CSP for the explicitly opted-in, folder-scoped scripted mode.
    ///
    /// This is a separate literal rather than a mutation of `contentSecurityPolicy` so
    /// the Phase-1 policy stays byte-for-byte stable and independently reviewable.
    ///
    /// - `script-src 'unsafe-inline' repoprompt-preview:` permits inline handlers and
    ///   blocks plus local JavaScript. The private-scheme source is safe only because
    ///   the handler simultaneously narrows its resolved serving boundary.
    /// - `worker-src 'none'` prevents a second execution context; `script-src` would
    ///   otherwise be the fallback source list for workers.
    /// - `connect-src 'none'` stays explicit, so fetch, XHR, EventSource, WebSocket,
    ///   and beacon APIs cannot turn folder reads into network exfiltration.
    /// - Images, styles, and fonts keep using the private handler; frames, forms, base
    ///   rewriting, unnamed fetch types, and every network origin remain denied.
    static let scriptedContentSecurityPolicy = [
        "default-src 'none'",
        "img-src repoprompt-preview:",
        "style-src repoprompt-preview: 'unsafe-inline'",
        "font-src repoprompt-preview:",
        "script-src 'unsafe-inline' repoprompt-preview:",
        "worker-src 'none'",
        "connect-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'"
    ].joined(separator: "; ")

    static func contentSecurityPolicy(for assetBoundary: RepoPreviewAssetBoundary) -> String {
        switch assetBoundary {
        case .checkout:
            contentSecurityPolicy
        case .documentSubtree:
            scriptedContentSecurityPolicy
        }
    }

    /// Builds the in-scope URL for a document-root-relative path.
    ///
    /// Percent-encoding is applied per path component so that a literal `#`, `?`, or
    /// space in a filename cannot be reinterpreted as URL syntax.
    static func documentURL(relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = scopeHost
        let trimmed = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        components.path = "/" + trimmed
        return components.url
    }
}

/// The immutable set of files a scheme handler may serve.
///
/// `.checkout` is the exact Phase-1 behavior and always pairs with scripts disabled.
/// `.documentSubtree` is the Phase-2 scripted boundary: the selected document is
/// pinned and every asset must resolve below its own nested directory.
enum RepoPreviewAssetBoundary: Equatable {
    case checkout
    case documentSubtree

    var allowsContentJavaScript: Bool {
        switch self {
        case .checkout:
            false
        case .documentSubtree:
            true
        }
    }
}

/// Why a preview resource request was refused.
///
/// Every case is a refusal: the resolver has no partial-success mode, so a caller
/// that receives a value has already passed containment.
enum RepoPreviewResourceError: Error, Equatable {
    case unsupportedScheme
    case unsupportedHost
    case emptyPath
    /// A `.` or `..` component survived percent-decoding.
    case traversalRejected
    case notFound
    /// Directory, symlink loop, FIFO, device node — anything a bounded read of a
    /// regular file would not terminate on.
    case notARegularFile
    /// The fully symlink-resolved path is outside the resolved document root.
    case escapesDocumentRoot
    /// Scripted mode could not derive a nested, regular selected document.
    case invalidDocumentSubtree
    /// A root-level document would leave the scripted asset set checkout-wide.
    case documentSubtreeIsCheckoutRoot
    /// The resolved resource is outside the selected document's directory.
    case outsideDocumentSubtree
    /// A resolved checkout-relative component begins with `.`. This is evaluated
    /// after symlink resolution so a clean-looking alias cannot launder a hidden path.
    case hiddenPathComponent
    /// Scripted mode serves one HTML document; other HTML files are not assets.
    case nonDocumentHTML
    case tooLarge(byteCount: Int, limit: Int)
    case unreadable
}

/// A request that passed every containment check, ready to be served.
struct RepoPreviewResolvedResource: Equatable {
    let fileURL: URL
    let mimeType: String
    let byteCount: Int
    let data: Data
}

/// Resolved once when a scripted configuration is built, never from attacker-controlled
/// request URL state.
private struct RepoPreviewDocumentSubtreeScope: Equatable {
    let documentFileURL: URL
    let directoryURL: URL
}

/// Maps `repoprompt-preview://document/<path>` onto a file inside one document root.
///
/// This type holds all of the path security for the preview and deliberately touches
/// no WebKit API, so the traversal, symlink, and containment matrix is testable
/// directly against a temp directory.
struct RepoPreviewResourceResolver {
    /// Upper bound on a single served resource. Bounds memory for a `Data`-backed
    /// response and stops a preview from being used to read a huge file into the app.
    static let defaultMaximumResourceByteCount = 16 * 1024 * 1024

    /// The document root with symlinks already resolved.
    ///
    /// Resolving at construction is what makes the containment comparison meaningful:
    /// on macOS a caller-supplied `/tmp/...` root resolves to `/private/tmp/...`, and
    /// comparing a resolved candidate against an unresolved root would reject every
    /// legitimate file.
    let documentRootURL: URL
    let maximumResourceByteCount: Int
    let assetBoundary: RepoPreviewAssetBoundary
    private let documentSubtreeScope: RepoPreviewDocumentSubtreeScope?

    /// Phase-1 initializer. Its checkout boundary, CSP, MIME behavior, and JavaScript
    /// denial are intentionally the defaults everywhere.
    init(
        documentRootURL: URL,
        maximumResourceByteCount: Int = RepoPreviewResourceResolver.defaultMaximumResourceByteCount
    ) {
        self.documentRootURL = documentRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.maximumResourceByteCount = maximumResourceByteCount
        assetBoundary = .checkout
        documentSubtreeScope = nil
    }

    /// Builds an explicit serving boundary for a configuration.
    ///
    /// Scripted mode requires a real nested document so its file set is strictly
    /// narrower than the checkout. The selected file and directory are resolved once;
    /// every request is later resolved again and compared with these canonical URLs.
    init(
        documentRootURL: URL,
        documentRelativePath: String,
        assetBoundary: RepoPreviewAssetBoundary,
        maximumResourceByteCount: Int = RepoPreviewResourceResolver.defaultMaximumResourceByteCount
    ) throws {
        let resolvedRoot = documentRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.documentRootURL = resolvedRoot
        self.maximumResourceByteCount = maximumResourceByteCount
        self.assetBoundary = assetBoundary

        switch assetBoundary {
        case .checkout:
            documentSubtreeScope = nil

        case .documentSubtree:
            let components = Self.safeRelativePathComponents(documentRelativePath)
            guard !components.isEmpty else {
                throw RepoPreviewResourceError.invalidDocumentSubtree
            }

            var documentCandidate = resolvedRoot
            for component in components {
                documentCandidate.appendPathComponent(component)
            }
            let resolvedDocument = documentCandidate.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolvedDocument.path),
                  Self.isContained(resolvedDocument, in: resolvedRoot)
            else {
                throw RepoPreviewResourceError.invalidDocumentSubtree
            }
            guard !Self.hasHiddenPathComponent(resolvedDocument, below: resolvedRoot) else {
                throw RepoPreviewResourceError.hiddenPathComponent
            }

            let values = try? resolvedDocument.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                throw RepoPreviewResourceError.invalidDocumentSubtree
            }

            let directory = resolvedDocument.deletingLastPathComponent().standardizedFileURL
            // A root-level report would still expose almost the whole checkout. Refuse
            // the opt-in rather than presenting that as a narrowed boundary.
            guard directory != resolvedRoot else {
                throw RepoPreviewResourceError.documentSubtreeIsCheckoutRoot
            }
            documentSubtreeScope = RepoPreviewDocumentSubtreeScope(
                documentFileURL: resolvedDocument,
                directoryURL: directory
            )
        }
    }

    func resolve(_ url: URL) throws -> RepoPreviewResolvedResource {
        try resolve(
            url,
            afterPathValidation: {},
            afterDescriptorValidation: {}
        )
    }

    /// Test seams run at the two race boundaries without changing the production path.
    /// The descriptor is never exposed: callers can only mutate the fixture around it.
    func resolve(
        _ url: URL,
        afterPathValidation: () throws -> Void,
        afterDescriptorValidation: () throws -> Void = {}
    ) throws -> RepoPreviewResolvedResource {
        let resolved = try resolvedResourceURL(for: url)
        try afterPathValidation()

        // O_NOFOLLOW closes the final-component swap after canonical resolution.
        // O_NONBLOCK ensures a swapped FIFO cannot stall the I/O queue before fstat
        // rejects it as non-regular.
        let descriptor = resolved.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw RepoPreviewResourceError.notFound
            case ELOOP:
                throw RepoPreviewResourceError.notARegularFile
            default:
                throw RepoPreviewResourceError.unreadable
            }
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw RepoPreviewResourceError.unreadable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw RepoPreviewResourceError.notARegularFile
        }
        guard status.st_size >= 0 else {
            throw RepoPreviewResourceError.unreadable
        }

        let statByteCount = Int(status.st_size)
        guard statByteCount <= maximumResourceByteCount else {
            throw RepoPreviewResourceError.tooLarge(
                byteCount: statByteCount,
                limit: maximumResourceByteCount
            )
        }

        // F_GETPATH describes the object actually opened, not the path checked before
        // open. Re-running containment and scripted-boundary validation closes races
        // through swapped intermediate components.
        let openedURL = try openedFileURL(for: descriptor)
        try validateResolvedResourceURL(openedURL)
        try afterDescriptorValidation()

        // The file may grow after fstat. The read asks for at most limit + 1 bytes;
        // observing that extra byte is a refusal, never an unbounded allocation.
        let data = try readData(from: descriptor, reservingCapacity: statByteCount)

        return RepoPreviewResolvedResource(
            fileURL: openedURL,
            mimeType: Self.mimeType(
                forPathExtension: openedURL.pathExtension,
                allowingJavaScript: assetBoundary.allowsContentJavaScript
            ),
            byteCount: data.count,
            data: data
        )
    }

    private func resolvedResourceURL(for url: URL) throws -> URL {
        guard let urlScheme = url.scheme?.lowercased(),
              urlScheme == RepoPreviewURLScheme.scheme
        else {
            throw RepoPreviewResourceError.unsupportedScheme
        }
        guard let host = url.host?.lowercased(), host == RepoPreviewURLScheme.scopeHost else {
            throw RepoPreviewResourceError.unsupportedHost
        }

        // `URL.path` is already percent-decoded, so `%2e%2e` and `%2f` have collapsed
        // into ordinary `..` and separators by the time they are inspected below.
        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { throw RepoPreviewResourceError.emptyPath }

        // Reject traversal by name before touching the filesystem. A leading `/` (or
        // `//`) never survives because empty components are dropped, so an absolute
        // request such as `//etc/passwd` is re-rooted rather than honored.
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw RepoPreviewResourceError.traversalRejected
        }

        var candidate = documentRootURL
        for component in components {
            candidate.appendPathComponent(component)
        }

        // Symlinks are resolved *before* containment, not after: an agent can write a
        // report and a symlink beside it in the same directory, and a check performed
        // on the pre-resolution path would happily serve `/etc/passwd` through a link
        // whose own path looks contained.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        try validateResolvedResourceURL(resolved)
        return resolved
    }

    private func validateResolvedResourceURL(_ resolved: URL) throws {
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw RepoPreviewResourceError.notFound
        }
        guard Self.isContained(resolved, in: documentRootURL) else {
            throw RepoPreviewResourceError.escapesDocumentRoot
        }

        if assetBoundary == .documentSubtree {
            guard let scope = documentSubtreeScope else {
                throw RepoPreviewResourceError.invalidDocumentSubtree
            }

            // Hidden entries are rejected relative to the checkout, not merely below
            // the selected directory. This also refuses a document placed in a hidden
            // directory and catches symlinks whose visible request path is innocuous.
            guard !Self.hasHiddenPathComponent(resolved, below: documentRootURL) else {
                throw RepoPreviewResourceError.hiddenPathComponent
            }

            let isSelectedDocument = resolved == scope.documentFileURL
            guard isSelectedDocument || Self.isContained(resolved, in: scope.directoryURL) else {
                throw RepoPreviewResourceError.outsideDocumentSubtree
            }

            // Other HTML files can become new active documents rather than passive
            // assets. They must be reopened through the host, which drops script mode.
            if Self.isHTMLPathExtension(resolved.pathExtension), !isSelectedDocument {
                throw RepoPreviewResourceError.nonDocumentHTML
            }
        }
    }

    private func openedFileURL(for descriptor: Int32) throws -> URL {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = pathBuffer.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return CInt(-1) }
            // Darwin's Swift overlay provides a fixed-arity `fcntl` shim for the
            // pointer-valued commands; a `@_silgen_name` binding must not be used here
            // because C `fcntl` is variadic and its va_arg lives on the stack on arm64.
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result != -1 else {
            throw RepoPreviewResourceError.unreadable
        }
        return URL(fileURLWithPath: String(cString: pathBuffer))
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func readData(
        from descriptor: Int32,
        reservingCapacity byteCount: Int
    ) throws -> Data {
        guard maximumResourceByteCount >= 0 else {
            throw RepoPreviewResourceError.tooLarge(
                byteCount: 0,
                limit: maximumResourceByteCount
            )
        }

        let chunkByteCount = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        var data = Data()
        data.reserveCapacity(min(byteCount, maximumResourceByteCount))

        while true {
            let remaining = maximumResourceByteCount - data.count
            let requestedByteCount = remaining >= chunkByteCount
                ? chunkByteCount
                : remaining + 1
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedByteCount)
            }

            if bytesRead == 0 { return data }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw RepoPreviewResourceError.unreadable
            }

            data.append(contentsOf: buffer.prefix(bytesRead))
            guard data.count <= maximumResourceByteCount else {
                throw RepoPreviewResourceError.tooLarge(
                    byteCount: data.count,
                    limit: maximumResourceByteCount
                )
            }
        }
    }

    private static func safeRelativePathComponents(_ path: String) -> [String] {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return []
        }
        return components
    }

    /// Evaluated only on canonical, symlink-resolved URLs.
    static func hasHiddenPathComponent(_ candidate: URL, below root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return false
        }
        return candidateComponents
            .dropFirst(rootComponents.count)
            .contains(where: { $0.hasPrefix(".") })
    }

    static func isHTMLPathExtension(_ pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "html", "htm":
            true
        default:
            false
        }
    }

    /// Path-component prefix comparison rather than string `hasPrefix`, so a sibling
    /// root such as `/root-evil` cannot masquerade as a child of `/root`.
    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Extension-driven MIME mapping restricted to what the CSP actually permits.
    ///
    /// Anything unrecognized becomes `application/octet-stream`, which the web view
    /// will not execute or render inline. JavaScript extensions are intentionally
    /// absent from this table: a `.js` file resolves to octet-stream so that the MIME
    /// layer agrees with `script-src 'none'` instead of contradicting it.
    static func mimeType(
        forPathExtension pathExtension: String,
        allowingJavaScript: Bool = false
    ) -> String {
        let normalizedExtension = pathExtension.lowercased()
        if allowingJavaScript, normalizedExtension == "js" || normalizedExtension == "mjs" {
            // `nosniff` stays enabled, so scripts receive an executable MIME type
            // only inside the already-narrowed scripted handler.
            return "text/javascript; charset=utf-8"
        }

        return switch normalizedExtension {
        case "html", "htm":
            "text/html; charset=utf-8"
        case "css":
            "text/css; charset=utf-8"
        case "png":
            "image/png"
        case "jpg", "jpeg":
            "image/jpeg"
        case "gif":
            "image/gif"
        case "webp":
            "image/webp"
        // SVG can carry inline script, but it is only ever reachable as an image
        // subresource here: `script-src 'none'` plus disabled JavaScript stop the
        // scripted-SVG path, and `default-src 'none'` stops it fetching anything.
        case "svg":
            "image/svg+xml"
        case "woff":
            "font/woff"
        case "woff2":
            "font/woff2"
        case "ttf":
            "font/ttf"
        case "otf":
            "font/otf"
        default:
            "application/octet-stream"
        }
    }
}

/// Serves `repoprompt-preview://` requests for one document root.
///
/// One handler instance belongs to one `WKWebViewConfiguration`, and therefore to one
/// document root; switching documents rebuilds the stack rather than re-pointing a
/// live handler, so a request issued by the previous document can never be answered
/// against the new root.
final class RepoPreviewURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let resolver: RepoPreviewResourceResolver
    let assetBoundary: RepoPreviewAssetBoundary
    private let contentSecurityPolicy: String
    private let ioQueue = DispatchQueue(
        label: "com.repoprompt.web-preview.scheme-handler",
        qos: .userInitiated
    )

    /// Tasks WebKit has started and not yet stopped.
    ///
    /// Messaging a stopped `WKURLSchemeTask` raises an Objective-C exception, so
    /// completion must be gated on liveness. `start`, `stop`, and every delivery run
    /// on the main queue, which serializes the check against the cancellation.
    private var activeTasks: Set<ObjectIdentifier> = []

    init(resolver: RepoPreviewResourceResolver) {
        self.resolver = resolver
        assetBoundary = resolver.assetBoundary
        contentSecurityPolicy = RepoPreviewURLScheme.contentSecurityPolicy(
            for: resolver.assetBoundary
        )
    }

    convenience init(documentRootURL: URL) {
        self.init(resolver: RepoPreviewResourceResolver(documentRootURL: documentRootURL))
    }

    convenience init(
        documentRootURL: URL,
        documentRelativePath: String,
        assetBoundary: RepoPreviewAssetBoundary
    ) throws {
        try self.init(resolver: RepoPreviewResourceResolver(
            documentRootURL: documentRootURL,
            documentRelativePath: documentRelativePath,
            assetBoundary: assetBoundary
        ))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        // `activeTasks` is unsynchronized, which is only sound because WebKit drives a
        // main-thread web view's scheme handler from the main thread. Checked in debug
        // so the assumption behind `@unchecked Sendable` fails loudly if it changes.
        assert(Thread.isMainThread, "scheme handler start must run on the main thread")
        let key = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(key)

        let url = urlSchemeTask.request.url
        // Captured as a value so the background closure does not need `self`.
        let resourceResolver = resolver
        let responseContentSecurityPolicy = contentSecurityPolicy

        // Resolution stats the path and reads the file, so it stays off the main
        // thread even though the payload is size-capped.
        ioQueue.async { [weak self] in
            let outcome: Result<RepoPreviewResolvedResource, Error>
            do {
                guard let url else { throw RepoPreviewResourceError.unsupportedScheme }
                let resource = try resourceResolver.resolve(url)
                outcome = .success(resource)
            } catch {
                outcome = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self, self.activeTasks.contains(key) else { return }
                self.activeTasks.remove(key)
                switch outcome {
                case let .success(resource):
                    guard let url,
                          let response = Self.makeResponse(
                              url: url,
                              mimeType: resource.mimeType,
                              byteCount: resource.byteCount,
                              contentSecurityPolicy: responseContentSecurityPolicy
                          )
                    else {
                        urlSchemeTask.didFailWithError(RepoPreviewResourceError.unreadable)
                        return
                    }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(resource.data)
                    urlSchemeTask.didFinish()
                case let .failure(error):
                    // Refusals fail the task rather than serving a placeholder document:
                    // an error page rendered in the document's own origin would be one
                    // more piece of attacker-influenced content.
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        assert(Thread.isMainThread, "scheme handler stop must run on the main thread")
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// Every response carries the CSP, so the policy applies to the top-level document
    /// and to each subresource independently of anything the document declares.
    static func makeResponse(
        url: URL,
        mimeType: String,
        byteCount: Int,
        contentSecurityPolicy: String = RepoPreviewURLScheme.contentSecurityPolicy
    ) -> HTTPURLResponse? {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(byteCount),
                "Content-Security-Policy": contentSecurityPolicy,
                // Without this a mislabelled octet-stream could still be sniffed into
                // HTML and inherit the document origin.
                "X-Content-Type-Options": "nosniff"
            ]
        )
    }
}
