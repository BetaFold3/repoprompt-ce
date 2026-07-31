@testable import RepoPromptApp
import XCTest

final class SettingsSearchMetadataTests: XCTestCase {
    func testMCPServerTabMatchesRemoteControlSearchTerms() {
        let queries = [
            "Remote Control",
            "remote-control",
            "gateway",
            "pairing",
            "remote host",
            "Tailscale"
        ]

        for query in queries {
            let normalizedQuery = query.lowercased()
            let matches = SettingsTab.allCases.filter { tab in
                tab.title.lowercased().contains(normalizedQuery)
                    || tab.searchTags.contains { $0.lowercased().contains(normalizedQuery) }
            }

            XCTAssertTrue(matches.contains(.mcp), "Expected MCP Server to match \(query)")
        }

        let normalizedTags = Set(SettingsTab.mcp.searchTags.map { $0.lowercased() })
        XCTAssertTrue(normalizedTags.contains("remote control"))
        XCTAssertTrue(normalizedTags.contains("remote-control"))
    }
}
