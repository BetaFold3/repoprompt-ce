import XCTest

/// Guards the hostile HTML fixtures used by the manual verification pass for the
/// locked-down preview (plan section 6).
///
/// The fixtures are not loaded by any automated test — rendering them needs a real
/// `WKWebView` and a human deciding whether something visibly leaked. That makes them
/// exactly the kind of asset that rots silently: a fixture emptied or renamed would
/// turn the manual pass into a checklist that verifies nothing. These tests assert the
/// inventory is present and still contains the construct each file claims to probe.
final class SecureHTMLPreviewFixtureTests: XCTestCase {
    /// Fixture name -> substrings that must survive for the file to still be hostile.
    private static let inventory: [String: [String]] = [
        "script-execution.html": ["<script", "javascript:", "onerror=", "onload="],
        "payload.js": ["document.title"],
        "external-image.html": ["http://127.0.0.1:9/pixel.png", "https://127.0.0.1:9/pixel.png"],
        "css-import-remote.html": ["@import", "@font-face", "url(\"http://127.0.0.1:9/beacon.png\")"],
        "remote-import.css": ["@import"],
        "nested-iframe.html": ["<iframe", "data:text/html", "<object", "<embed"],
        "form-post.html": ["<form", "method=\"post\"", "http://127.0.0.1:9/collect"],
        "meta-refresh.html": ["http-equiv=\"refresh\""],
        "path-traversal.html": ["../outside/secret.txt", "%2e%2e", "file:///etc/passwd", "/etc/passwd"],
        "popup-links.html": ["window.open", "target=\"_blank\"", "ws://", "mailto:"],
        "index.html": ["<a href="]
    ]

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    func testHostileFixtureInventoryIsIntact() throws {
        for (name, requiredSubstrings) in Self.inventory {
            let url = Self.fixtureDirectory.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing manual-pass fixture \(name)"
            )

            let contents = try String(contentsOf: url, encoding: .utf8)
            for substring in requiredSubstrings {
                XCTAssertTrue(
                    contents.contains(substring),
                    "\(name) no longer contains \(substring), so it no longer probes what it claims to"
                )
            }
        }
    }

    func testScriptedFolderBoundaryFixtureCarriesARealSiblingOracle() throws {
        let scriptedRelativePath = "scripted/script-folder-boundary.html"
        let siblingRelativePath = "sibling/script-oracle.js"
        let scripted = try String(
            contentsOf: Self.fixtureDirectory.appendingPathComponent(scriptedRelativePath),
            encoding: .utf8
        )
        let sibling = try String(
            contentsOf: Self.fixtureDirectory.appendingPathComponent(siblingRelativePath),
            encoding: .utf8
        )
        let index = try String(
            contentsOf: Self.fixtureDirectory.appendingPathComponent("index.html"),
            encoding: .utf8
        )

        for required in ["<script>", "../sibling/script-oracle.js", "new URL", "probe.onerror"] {
            XCTAssertTrue(scripted.contains(required))
        }
        XCTAssertTrue(sibling.contains("LEAKED: sibling script executed"))
        XCTAssertTrue(index.contains("href=\"\(scriptedRelativePath)\""))
    }

    func testFixtureIndexLinksEveryHostileFixture() throws {
        // The index is the manual pass's entry point; a fixture it does not link is a
        // fixture nobody will open.
        let index = try String(
            contentsOf: Self.fixtureDirectory.appendingPathComponent("index.html"),
            encoding: .utf8
        )

        let linkable = Self.inventory.keys.filter {
            $0.hasSuffix(".html") && $0 != "index.html"
        }
        XCTAssertFalse(linkable.isEmpty)

        for name in linkable {
            XCTAssertTrue(
                index.contains("href=\"\(name)\""),
                "index.html does not link \(name)"
            )
        }
    }
}
