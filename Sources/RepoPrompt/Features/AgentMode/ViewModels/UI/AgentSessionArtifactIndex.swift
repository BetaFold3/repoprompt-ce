import Combine
import Foundation

/// The newest-first list of documents an agent wrote in one tab's session.
///
/// One index belongs to one `TabSession`. It is fed the session's canonical `items` array and keeps
/// a per-item cache of decoded artifacts, so a transcript that grows by one tool result — or whose
/// last tool result is rewritten in place while it streams — costs one payload decode rather than a
/// full rescan. Everything expensive happens in `AgentEditToolResultDecoder`; this type only decides
/// *when* that work is worth redoing.
///
/// Wiring is left to the caller: the panel's UI store drives `ingest(_:)` whenever the tab's items
/// change. Keeping the session type out of this file is deliberate — the index knows about
/// transcript items and artifacts, and nothing about view models or panels.
@MainActor
final class AgentSessionArtifactIndex: ObservableObject {
    /// Artifacts newest-first. Within a single tool result, payload order is preserved, so a patch
    /// that wrote two reports lists them the way the agent wrote them.
    @Published private(set) var artifacts: [AgentSessionArtifact] = []

    /// How many payloads have been decoded since this index was created.
    ///
    /// Instrumentation for the incremental contract: repeated ingests of an unchanged transcript
    /// must not move this number.
    private(set) var payloadDecodeCount: Int = 0

    private var cache: [UUID: CachedItem] = [:]

    init() {}

    // MARK: - Ingest

    /// Reconciles the index against a tab's current transcript items.
    ///
    /// Safe to call on every change: items whose payload is untouched reuse their decoded artifacts,
    /// items that vanished are dropped, and `artifacts` is only republished when the resulting list
    /// actually differs.
    func ingest(_ items: [AgentChatItem]) {
        var nextCache: [UUID: CachedItem] = [:]
        nextCache.reserveCapacity(cache.count)
        var groups: [[AgentSessionArtifact]] = []

        for item in items {
            guard AgentEditToolResultDecoder.editToolKind(for: item) != nil else { continue }
            let key = PayloadKey(item)
            let entry: CachedItem
            if let cached = cache[item.id], cached.key == key {
                entry = cached
            } else {
                entry = CachedItem(key: key, artifacts: AgentEditedArtifactExtractor.artifacts(for: item))
                payloadDecodeCount += 1
            }
            nextCache[item.id] = entry
            if !entry.artifacts.isEmpty {
                groups.append(entry.artifacts)
            }
        }

        cache = nextCache
        let ordered = Array(groups.reversed().joined())
        if ordered != artifacts {
            artifacts = ordered
        }
    }

    /// Drops everything, for a session that was cleared or a tab that went away.
    func reset() {
        cache.removeAll()
        if !artifacts.isEmpty {
            artifacts = []
        }
    }

    // MARK: - Queries

    /// The artifact the banner should offer, or `nil` when every candidate has been dismissed.
    ///
    /// Dismissal is per tab and lives with the tab's panel state, so it is passed in rather than
    /// stored here — the index describes what the agent wrote, not what the user is done with.
    func newestArtifact(excludingDismissed dismissedIDs: Set<AgentSessionArtifact.ID>) -> AgentSessionArtifact? {
        artifacts.first { !dismissedIDs.contains($0.id) }
    }

    // MARK: - Cache

    private struct CachedItem {
        let key: PayloadKey
        let artifacts: [AgentSessionArtifact]
    }

    /// Everything about an item that can change what its artifacts are.
    ///
    /// Payload strings are compared rather than hashed: an untouched item hands back the very same
    /// string storage, so equality settles on a pointer comparison instead of re-reading a diff that
    /// can run to hundreds of kilobytes.
    private struct PayloadKey: Equatable {
        let toolName: String?
        let toolResultJSON: String?
        let toolArgsJSON: String?
        let toolIsError: Bool?
        let timestamp: Date

        init(_ item: AgentChatItem) {
            toolName = item.toolName
            toolResultJSON = item.toolResultJSON
            toolArgsJSON = item.toolArgsJSON
            toolIsError = item.toolIsError
            timestamp = item.timestamp
        }
    }
}
