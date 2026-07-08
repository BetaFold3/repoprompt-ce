import Foundation
@testable import RepoPromptApp
import XCTest

final class ContextBuilderStreamLogMappingTests: XCTestCase {
    @MainActor
    func testReasoningFragmentCurrentlyMapsToVisibleSystemLogRow() throws {
        #if DEBUG
            let previousMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer {
                GlobalSettingsStore.shared.setMCPAutoStart(previousMCPAutoStart, commit: false)
            }

            let composition = WindowStateCompositionFactory.make(
                windowID: -77,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                loadStoredAPISettingsDataOnInit: false
            )
            let mapping = try XCTUnwrap(
                composition.contextBuilderAgentViewModel.test_mapStreamResultToLogEntry(
                    AIStreamResult(type: "reasoning", text: nil, reasoning: "e8")
                )
            )

            XCTAssertEqual(mapping.entry.type, .system)
            XCTAssertEqual(mapping.entry.message, "e8")
            XCTAssertEqual(mapping.dedupeKey, "status:reasoning:e8")
        #else
            throw XCTSkip("Context Builder stream log mapping test hook is DEBUG-only.")
        #endif
    }
}
