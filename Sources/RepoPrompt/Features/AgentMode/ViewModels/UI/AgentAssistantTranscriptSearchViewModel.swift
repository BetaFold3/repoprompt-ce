import Foundation

/// The only time transcript search spends: injected so debounce/flash timing is deterministic in
/// tests instead of relying on real sleeps, which would make the suite slow and flaky.
protocol AgentTranscriptSearchScheduler: Sendable {
    func sleep(for duration: Duration) async throws
}

struct AgentTranscriptSearchLiveScheduler: AgentTranscriptSearchScheduler {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Ephemeral assistant transcript search. Owned per displayed Agent Mode session; the hosting
/// view (`AgentModeChatDetailView`) resets it explicitly when the session/tab changes, mirroring
/// `AssistantTranscriptExpansionStore`'s reset and the existing `transcriptBlockExpansion` reset.
///
/// Matching runs over the transcript's block model via `AgentTranscriptSearchProviding`, not
/// rendered rows, so results are correct regardless of scroll position. Debounced so retyping
/// during a long session does not re-walk the block tree on every keystroke.
@MainActor
final class AgentAssistantTranscriptSearchViewModel: ObservableObject {
    @Published private(set) var state: AgentAssistantTranscriptSearchState = .idle
    /// An expand/scroll event. Its token changes even when two searches select the same message.
    @Published private(set) var navigationEvent: AgentAssistantTranscriptNavigationEvent?
    var navigationTarget: AgentAssistantTranscriptSearchMatch? {
        navigationEvent?.match
    }

    /// The row the owning view should briefly highlight, cleared automatically after
    /// `flashDuration`.
    @Published private(set) var flashedItemID: UUID?

    private let provider: AgentTranscriptSearchProviding
    private let scheduler: AgentTranscriptSearchScheduler
    private let debounceDuration: Duration
    private let flashDuration: Duration
    private var debounceTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var navigationToken: UInt64 = 0

    init(
        provider: AgentTranscriptSearchProviding = AgentAssistantTranscriptSearchProvider(),
        scheduler: AgentTranscriptSearchScheduler = AgentTranscriptSearchLiveScheduler(),
        debounceDuration: Duration = .milliseconds(200),
        flashDuration: Duration = .milliseconds(900)
    ) {
        self.provider = provider
        self.scheduler = scheduler
        self.debounceDuration = debounceDuration
        self.flashDuration = flashDuration
    }

    /// `blocks` is the caller's current transcript block snapshot at call time. Each keystroke
    /// cancels the prior debounce and re-captures a fresh snapshot, so the eventual search still
    /// reflects transcript growth that happened while the user was typing.
    func updateQuery(_ query: String, blocks: [AgentTranscriptRenderBlock]) {
        debounceTask?.cancel()
        generation &+= 1
        let currentGeneration = generation

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            navigationEvent = nil
            return
        }

        state = AgentAssistantTranscriptSearchState(
            query: query,
            phase: .debouncing,
            matches: state.matches,
            selectedMatchIndex: nil
        )
        debounceTask = Task { [weak self, scheduler, debounceDuration] in
            do {
                try await scheduler.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.executeSearch(query: query, blocks: blocks, generation: currentGeneration)
        }
    }

    /// Re-runs the active query against a changed transcript snapshot, using the same debounce and
    /// generation fence as keystroke updates.
    func updateSearchableBlocks(_ blocks: [AgentTranscriptRenderBlock]) {
        guard !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateQuery(state.query, blocks: blocks)
    }

    private func executeSearch(query: String, blocks: [AgentTranscriptRenderBlock], generation: UInt64) {
        guard generation == self.generation else { return }
        let entries = provider.searchEntries(in: blocks)
        let matches = AgentAssistantTranscriptSearchEngine.matches(in: entries, query: query)
        state = AgentAssistantTranscriptSearchState(
            query: query,
            phase: .ready,
            matches: matches,
            selectedMatchIndex: matches.isEmpty ? nil : 0
        )
        if let first = state.selectedMatch {
            publishNavigation(to: first)
        } else {
            navigationEvent = nil
        }
    }

    func selectNext() {
        guard !state.matches.isEmpty else { return }
        let next = ((state.selectedMatchIndex ?? -1) + 1) % state.matches.count
        select(at: next)
    }

    func selectPrevious() {
        guard !state.matches.isEmpty else { return }
        let count = state.matches.count
        let previous = ((state.selectedMatchIndex ?? 0) - 1 + count) % count
        select(at: previous)
    }

    private func select(at index: Int) {
        guard state.matches.indices.contains(index) else { return }
        state = AgentAssistantTranscriptSearchState(
            query: state.query,
            phase: state.phase,
            matches: state.matches,
            selectedMatchIndex: index
        )
        publishNavigation(to: state.matches[index])
    }

    private func publishNavigation(to match: AgentAssistantTranscriptSearchMatch) {
        navigationToken &+= 1
        navigationEvent = AgentAssistantTranscriptNavigationEvent(token: navigationToken, match: match)
    }

    /// Cancels in-flight work and returns to the idle, closed-search state.
    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        flashTask?.cancel()
        flashTask = nil
        generation &+= 1
        state = .idle
        navigationEvent = nil
        flashedItemID = nil
    }

    /// Called by the owning view once it has expanded and scrolled to `navigationTarget`.
    func flash(_ itemID: UUID) {
        flashTask?.cancel()
        flashedItemID = itemID
        flashTask = Task { [weak self, scheduler, flashDuration] in
            do {
                try await scheduler.sleep(for: flashDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.flashedItemID == itemID else { return }
                self?.flashedItemID = nil
            }
        }
    }
}
