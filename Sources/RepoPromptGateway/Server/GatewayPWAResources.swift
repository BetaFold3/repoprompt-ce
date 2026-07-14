import Foundation

private final class GatewayPWABundleFinder {}

/// Locates the PWA static assets packaged into the gateway target's SwiftPM
/// resource bundle (`RepoPromptCE_RepoPromptGateway.bundle`).
///
/// The assets are plain static HTML/CSS/ES modules with no build toolchain and are
/// served only by the gateway (`GatewayHTTPHandler`).
enum GatewayPWAResources {
    static let bundleName = "RepoPromptCE_RepoPromptGateway"
    static let subdirectory = "pwa"

    /// Every asset the PWA needs; packaging validation and `PWAResourceTests`
    /// require all of these to resolve.
    static let requiredAssets = ["index.html", "app.js", "sw.js", "manifest.webmanifest"]

    static func contentType(forAsset name: String) -> String {
        if name.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if name.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if name.hasSuffix(".webmanifest") { return "application/manifest+json; charset=utf-8" }
        if name.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if name.hasSuffix(".svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }

    static func url(forAsset name: String) -> URL? {
        guard requiredAssets.contains(name), let bundle = resourceBundle() else { return nil }
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return bundle.url(
            forResource: String(parts[0]),
            withExtension: String(parts[1]),
            subdirectory: subdirectory
        )
    }

    static func data(forAsset name: String) -> Data? {
        guard let url = url(forAsset: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Resolves the SwiftPM resource bundle across the supported layouts:
    /// - packaged app: `RepoPrompt.app/Contents/Resources/<bundle>` (the gateway
    ///   executable's `Bundle.main` is the app bundle),
    /// - raw build directory: `<bin-dir>/<bundle>` next to the executable,
    /// - `swift test`: `<bin-dir>/<bundle>` next to the `.xctest` bundle.
    static func resourceBundle() -> Bundle? {
        let hostBundle = Bundle(for: GatewayPWABundleFinder.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            hostBundle.resourceURL,
            Bundle.main.bundleURL,
            hostBundle.bundleURL.deletingLastPathComponent()
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let bundleURL = candidate.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
            if let bundle = Bundle(url: bundleURL), bundle.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: subdirectory
            ) != nil {
                return bundle
            }
        }
        return nil
    }
}
