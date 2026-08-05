import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentAssistantTranscriptSearchViewModelTests: XCTestCase {
    func testDebounceCoalescesRapidQueryUpdatesToOnlyTheNewestQuery() async {
        let scheduler = AssistantSearchManualScheduler()
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: scheduler)
        let match = item(kind: .assistant, text: "alpha needle", sequenceIndex: 0)
        let blocks = [block(rows: [match])]

        vm.updateQuery("alp", blocks: blocks)
        await waitUntil("first debounce pending") { scheduler.pendingCount == 1 }
        XCTAssertEqual(vm.state.phase, .debouncing)

        vm.updateQuery("needle", blocks: blocks)
        await waitUntil("both debounce tasks queued") { scheduler.pendingCount == 2 }
        scheduler.releaseAll()

        await waitUntil("search becomes ready") { vm.state.phase == .ready }

        XCTAssertEqual(vm.state.query, "needle")
        XCTAssertEqual(vm.state.matches.map(\.id), [match.id], "only the newest query's results should publish")
    }

    func testEmptyQueryClearsStateImmediatelyAndIgnoresTheStaleCancelledDebounce() async {
        let scheduler = AssistantSearchManualScheduler()
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: scheduler)
        let match = item(kind: .assistant, text: "needle", sequenceIndex: 0)

        vm.updateQuery("needle", blocks: [block(rows: [match])])
        await waitUntil("debounce pending") { scheduler.pendingCount == 1 }

        vm.updateQuery("", blocks: [])
        XCTAssertEqual(vm.state, .idle, "clearing to an empty query resolves synchronously, without waiting on debounce")

        scheduler.releaseAll() // resumes the now-cancelled first debounce task
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(vm.state, .idle, "the cancelled debounce must not resurrect stale matches")
    }

    func testSearchReadySelectsFirstMatchAndPublishesItAsTheNavigationTarget() async {
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: AssistantSearchImmediateScheduler(), debounceDuration: .zero)
        let first = item(kind: .assistant, text: "needle one", sequenceIndex: 0)
        let second = item(kind: .assistant, text: "needle two", sequenceIndex: 1)

        vm.updateQuery("needle", blocks: [block(rows: [first, second])])
        await waitUntil("search becomes ready") { vm.state.phase == .ready }

        XCTAssertEqual(vm.state.matches.count, 2)
        XCTAssertEqual(vm.state.selectedMatch?.id, first.id)
        XCTAssertEqual(vm.navigationTarget?.id, first.id)
        let firstNavigationToken = vm.navigationEvent?.token

        // A second search that selects the same message must still publish a distinct event so
        // SwiftUI repeats expand/scroll rather than suppressing an equal target value.
        vm.updateQuery("needle one", blocks: [block(rows: [first, second])])
        await waitUntil("same-message navigation republishes") {
            vm.navigationEvent?.token != firstNavigationToken && vm.state.phase == .ready
        }
        XCTAssertEqual(vm.navigationTarget?.id, first.id)

        // Transcript growth re-runs the active query even when the user does not type again.
        let newlyMatching = item(kind: .assistant, text: "needle one newly arrived", sequenceIndex: 2)
        vm.updateSearchableBlocks([block(rows: [first, second, newlyMatching])])
        await waitUntil("changed block snapshot refreshes matches") { vm.state.matches.count == 2 }
        XCTAssertEqual(vm.state.matches.map(\.id), [first.id, newlyMatching.id])
    }

    func testSelectNextAndPreviousWrapAndUpdateNavigationTarget() async {
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: AssistantSearchImmediateScheduler(), debounceDuration: .zero)
        let first = item(kind: .assistant, text: "needle one", sequenceIndex: 0)
        let second = item(kind: .assistant, text: "needle two", sequenceIndex: 1)
        vm.updateQuery("needle", blocks: [block(rows: [first, second])])
        await waitUntil("search becomes ready") { vm.state.phase == .ready }

        vm.selectNext()
        XCTAssertEqual(vm.state.selectedMatch?.id, second.id)
        XCTAssertEqual(vm.navigationTarget?.id, second.id)

        vm.selectNext()
        XCTAssertEqual(vm.state.selectedMatch?.id, first.id, "next wraps back to the first match")

        vm.selectPrevious()
        XCTAssertEqual(vm.state.selectedMatch?.id, second.id, "previous wraps back to the last match")
    }

    func testClearCancelsPendingDebounceAndResetsToIdle() async {
        let scheduler = AssistantSearchManualScheduler()
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: scheduler)
        vm.updateQuery("needle", blocks: [])
        await waitUntil("debounce pending") { scheduler.pendingCount == 1 }

        vm.clear()
        scheduler.releaseAll()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(vm.state, .idle)
        XCTAssertNil(vm.navigationTarget)
    }

    func testFlashClearsAutomaticallyAfterTheConfiguredDuration() async {
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: AssistantSearchImmediateScheduler(), flashDuration: .zero)
        let id = UUID()

        vm.flash(id)
        XCTAssertEqual(vm.flashedItemID, id)

        await waitUntil("flash clears") { vm.flashedItemID == nil }
    }

    /// Composes the two model-layer pieces `AgentModeChatDetailView.handleAssistantSearchNavigation`
    /// wires together (no SwiftUI harness exists for that private view function, so this proves the
    /// contract at the model layer): a search hit becomes the navigation target, and forcing that
    /// target open in the expansion store expands exactly that message ID.
    func testExpandOnMatchExpandsTheStoreForTheNavigationTargetID() async throws {
        let vm = AgentAssistantTranscriptSearchViewModel(scheduler: AssistantSearchImmediateScheduler(), debounceDuration: .zero)
        let store = AssistantTranscriptExpansionStore()
        let match = item(kind: .assistant, text: "needle", sequenceIndex: 0)
        let other = item(kind: .assistant, text: "unrelated", sequenceIndex: 1)

        vm.updateQuery("needle", blocks: [block(rows: [match, other])])
        await waitUntil("search becomes ready") { vm.state.phase == .ready }

        let target = try XCTUnwrap(vm.navigationTarget)
        XCTAssertEqual(target.id, match.id)
        XCTAssertFalse(store.isExpanded(match.id))

        store.expand(target.id)

        XCTAssertTrue(store.isExpanded(match.id))
        XCTAssertFalse(store.isExpanded(other.id), "only the matched message expands")
    }

    // MARK: - Helpers

    private func item(kind: AgentChatItemKind, text: String, sequenceIndex: Int) -> AgentChatItem {
        AgentChatItem(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
            kind: kind,
            text: text,
            sequenceIndex: sequenceIndex
        )
    }

    private func block(rows: [AgentChatItem]) -> AgentTranscriptRenderBlock {
        AgentTranscriptRenderBlock(
            id: UUID().uuidString,
            kind: .standaloneAssistant,
            turnID: UUID(),
            retentionTier: .full,
            rows: rows,
            isArchived: false
        )
    }

    private func waitUntil(
        _ description: String,
        attempts: Int = 1000,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}

/// Deterministic, release-controlled debounce gate for coalescing/cancellation tests.
private final class AssistantSearchManualScheduler: AgentTranscriptSearchScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        lock.withLock { waiters.count }
    }

    func releaseAll() {
        let pending = lock.withLock {
            let value = waiters
            waiters = []
            return value
        }
        pending.forEach { $0.resume() }
    }

    func sleep(for _: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }
}

/// Resolves every sleep on the next runloop tick, for tests that only care about the eventual
/// state rather than controlling debounce timing directly.
private struct AssistantSearchImmediateScheduler: AgentTranscriptSearchScheduler {
    func sleep(for _: Duration) async throws {
        await Task.yield()
    }
}
