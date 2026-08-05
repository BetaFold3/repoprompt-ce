import Foundation

// MARK: - Search entry

/// One block-model row eligible for transcript search matching.
///
/// Deliberately decoupled from `AgentChatItem` so a later tool-output search provider can vend
/// the same shape without depending on assistant-specific fields (Workstream 5 item 1 ships the
/// assistant-text provider only; see `AgentTranscriptSearchProviding`).
struct AgentTranscriptSearchEntry: Identifiable, Equatable {
    let id: UUID
    let sequenceIndex: Int
    let text: String
}

/// Vends searchable entries from the transcript's block model (not rendered rows), so search
/// results stay correct regardless of scroll position or which rows happen to be mounted.
protocol AgentTranscriptSearchProviding {
    func searchEntries(in blocks: [AgentTranscriptRenderBlock]) -> [AgentTranscriptSearchEntry]
}

/// The Workstream 5 item 1 provider: completed assistant replies only.
///
/// Only block kinds that always render their rows directly are scanned (`request`,
/// `standaloneAssistant`, `standaloneTool`, `standaloneNote`, `middleSummary`, `conclusion` —
/// see `AgentModeChatDetailView.transcriptBlockSupportsExpansion`). `activityCluster` and
/// `groupedHistory` blocks have their own block-level collapse/expand behavior
/// (`transcriptBlockExpansion`), which this workstream item leaves completely untouched, so
/// assistant text nested inside a collapsed cluster or grouped-history section is not reachable
/// from transcript search in this iteration — surfacing it would require auto-expanding that
/// container, which is explicitly out of scope. `collapsedHistoryRange` blocks carry no row
/// content to search.
struct AgentAssistantTranscriptSearchProvider: AgentTranscriptSearchProviding {
    func searchEntries(in blocks: [AgentTranscriptRenderBlock]) -> [AgentTranscriptSearchEntry] {
        var entries: [AgentTranscriptSearchEntry] = []
        for block in blocks {
            guard block.kind != .activityCluster,
                  block.kind != .groupedHistory,
                  block.kind != .collapsedHistoryRange
            else {
                continue
            }
            for item in block.rows where isSearchableAssistantMessage(item) {
                entries.append(AgentTranscriptSearchEntry(id: item.id, sequenceIndex: item.sequenceIndex, text: item.text))
            }
        }
        return entries.sorted { $0.sequenceIndex < $1.sequenceIndex }
    }

    private func isSearchableAssistantMessage(_ item: AgentChatItem) -> Bool {
        (item.kind == .assistant || item.kind == .assistantInline)
            && !item.isStreaming
            && AgentDisplayableText.hasDisplayableBody(item.text)
    }
}

// MARK: - Matches

/// One transcript search hit: one matching assistant message, not an intra-text occurrence — v1
/// flashes the row instead of highlighting text, so per-message granularity is sufficient for
/// "N of M" navigation.
struct AgentAssistantTranscriptSearchMatch: Identifiable, Equatable {
    let id: UUID
    let sequenceIndex: Int
}

/// One expand/scroll request. The monotonically increasing token makes repeated navigation to
/// the same message observable as a new event.
struct AgentAssistantTranscriptNavigationEvent: Equatable {
    let token: UInt64
    let match: AgentAssistantTranscriptSearchMatch
}

enum AgentAssistantTranscriptSearchPhase: Equatable {
    case idle
    case debouncing
    case ready
}

struct AgentAssistantTranscriptSearchState: Equatable {
    let query: String
    let phase: AgentAssistantTranscriptSearchPhase
    let matches: [AgentAssistantTranscriptSearchMatch]
    let selectedMatchIndex: Int?

    static let idle = AgentAssistantTranscriptSearchState(query: "", phase: .idle, matches: [], selectedMatchIndex: nil)

    var selectedMatch: AgentAssistantTranscriptSearchMatch? {
        guard let selectedMatchIndex, matches.indices.contains(selectedMatchIndex) else { return nil }
        return matches[selectedMatchIndex]
    }

    /// "2 of 5" style counter text for the search bar; nil while there is nothing to report yet.
    var counterText: String? {
        guard phase == .ready else { return nil }
        guard !matches.isEmpty else { return "No results" }
        guard let selectedMatchIndex else { return "\(matches.count) result\(matches.count == 1 ? "" : "s")" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }
}

/// Pure, literal case-insensitive matching over already-extracted search entries. No intra-text
/// ranges in v1 (see `AgentAssistantTranscriptSearchMatch`), so this only needs containment.
enum AgentAssistantTranscriptSearchEngine {
    static func matches(in entries: [AgentTranscriptSearchEntry], query: String) -> [AgentAssistantTranscriptSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return entries
            .filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
            .map { AgentAssistantTranscriptSearchMatch(id: $0.id, sequenceIndex: $0.sequenceIndex) }
    }
}
