import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentAssistantTranscriptSearchEngineTests: XCTestCase {
    func testMatchesAreCaseInsensitiveAndOrderedBySequenceIndex() {
        let entries = [
            AgentTranscriptSearchEntry(id: UUID(), sequenceIndex: 3, text: "third NEEDLE"),
            AgentTranscriptSearchEntry(id: UUID(), sequenceIndex: 1, text: "first needle"),
            AgentTranscriptSearchEntry(id: UUID(), sequenceIndex: 2, text: "no match here")
        ]

        let matches = AgentAssistantTranscriptSearchEngine.matches(in: entries, query: "Needle")

        XCTAssertEqual(matches.map(\.sequenceIndex), [1, 3])
        XCTAssertEqual(matches.map(\.id), [entries[1].id, entries[0].id])
    }

    func testBlankQueryProducesNoMatches() {
        let entries = [AgentTranscriptSearchEntry(id: UUID(), sequenceIndex: 0, text: "anything")]

        XCTAssertTrue(AgentAssistantTranscriptSearchEngine.matches(in: entries, query: "   ").isEmpty)
    }

    func testCounterTextReflectsPhaseAndSelection() {
        let matches = [
            AgentAssistantTranscriptSearchMatch(id: UUID(), sequenceIndex: 0),
            AgentAssistantTranscriptSearchMatch(id: UUID(), sequenceIndex: 1)
        ]

        XCTAssertNil(AgentAssistantTranscriptSearchState.idle.counterText, "no counter until a search is ready")

        let noResults = AgentAssistantTranscriptSearchState(query: "x", phase: .ready, matches: [], selectedMatchIndex: nil)
        XCTAssertEqual(noResults.counterText, "No results")

        let selected = AgentAssistantTranscriptSearchState(query: "x", phase: .ready, matches: matches, selectedMatchIndex: 1)
        XCTAssertEqual(selected.counterText, "2 of 2")
    }
}
