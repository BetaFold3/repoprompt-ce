import Foundation

// SEARCH-HELPER: AgentEditedArtifactExtractor, AgentSessionArtifact, AgentSessionArtifactKind, artifact banner

/// The document families the utility panel can preview.
///
/// The accepted spellings match the surfaces that already exist: `md` / `markdown` follows the
/// tool-output formatter's language mapping, and `html` / `htm` follows the secure preview scheme
/// handler's MIME table.
enum AgentSessionArtifactKind: String, Hashable, CaseIterable {
    case markdown
    case html

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "html", "htm": self = .html
        default: return nil
        }
    }
}

/// A document an agent wrote during this session, worth offering back to the user.
struct AgentSessionArtifact: Identifiable, Hashable {
    /// Stable across re-decodes of the same transcript item: a streaming tool result that gets
    /// rewritten in place keeps its artifact identity, so a dismissed banner stays dismissed.
    let id: String
    /// The path exactly as the tool payload reported it — absolute or relative, unresolved.
    let path: String
    let kind: AgentSessionArtifactKind
    /// Always a whole-file write; `AgentEditedArtifactExtractor` filters modifications out.
    let disposition: AgentEditedFileDisposition
    /// The transcript item this artifact was decoded from.
    let toolItemID: UUID
    let toolKind: AgentEditToolKind
    /// The transcript item's timestamp, carried so consumers can order or label without the item.
    let createdAt: Date

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    static func identifier(toolItemID: UUID, changeIndex: Int, path: String) -> String {
        "\(toolItemID.uuidString)#\(changeIndex)#\(path)"
    }
}

/// Turns normalized edit facts into the session artifacts the utility panel offers to open.
///
/// The filter is deliberately narrow, following decision 12 of the right-utility-panel design:
/// a Markdown or HTML file that an agent *authored* — created or overwritten. A file the agent
/// merely edited is noise; the whole point of the banner is "the agent just wrote you a document".
enum AgentEditedArtifactExtractor {
    /// Artifacts for a transcript item; empty for anything that is not an edit tool result.
    static func artifacts(for item: AgentChatItem) -> [AgentSessionArtifact] {
        guard let facts = AgentEditToolResultDecoder.facts(for: item) else { return [] }
        return artifacts(from: facts, toolItemID: item.id, timestamp: item.timestamp)
    }

    /// Artifacts for already-decoded facts, in payload order.
    static func artifacts(
        from facts: AgentEditToolFacts,
        toolItemID: UUID,
        timestamp: Date
    ) -> [AgentSessionArtifact] {
        // A failed or still-streaming payload lists files that may never reach disk. Offering to
        // open one would send the user to a document that does not exist yet.
        guard facts.outcome.mayHaveReachedDisk else { return [] }
        return facts.files.enumerated().compactMap { changeIndex, file in
            guard file.disposition.isWholeFileWrite,
                  let kind = AgentSessionArtifactKind(fileExtension: file.fileExtension)
            else {
                return nil
            }
            return AgentSessionArtifact(
                id: AgentSessionArtifact.identifier(
                    toolItemID: toolItemID,
                    changeIndex: changeIndex,
                    path: file.path
                ),
                path: file.path,
                kind: kind,
                disposition: file.disposition,
                toolItemID: toolItemID,
                toolKind: facts.toolKind,
                createdAt: timestamp
            )
        }
    }
}
