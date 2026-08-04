import Foundation

/// Lifecycle of one in-diff search generation.
///
/// Debouncing and loading stay distinct so the presentation can avoid implying that repository
/// reads have started while the injected scheduler is still coalescing keystrokes.
enum AgentChangesSearchPhase: Equatable {
    case idle
    case debouncing
    case loading
    case ready
}

/// The rendered diff element containing a search occurrence.
///
/// Search is deliberately literal-only. The locator therefore describes visible projection
/// elements rather than regex captures or source-file offsets that the Changes panel cannot render.
enum AgentChangesSearchLocator: Equatable {
    case filePath
    case hunkHeading(hunkID: String)
    case line(kind: FileDiffProjection.LineKind, oldLine: Int?, newLine: Int?)

    /// Hashable identity of one rendered element, used both for match IDs and for bucketing matches
    /// by the row element that draws them.
    var stableKey: String {
        switch self {
        case .filePath:
            return "path"
        case let .hunkHeading(hunkID):
            return "heading:\(hunkID)"
        case let .line(kind, oldLine, newLine):
            let kindKey = switch kind {
            case .context: "context"
            case .addition: "addition"
            case .deletion: "deletion"
            case .noNewlineMarker: "no-newline"
            }
            return [kindKey, oldLine.map(String.init) ?? "", newLine.map(String.init) ?? ""]
                .joined(separator: ":")
        }
    }
}

/// One occurrence in the active Changes search corpus.
///
/// Match ranges use UTF-16 code-unit offsets because both AppKit attributed strings and the
/// projection's existing intraline ranges use that coordinate space. The displayed text is retained
/// so search results do not keep whole patch documents alive.
struct AgentChangesSearchMatch: Equatable, Identifiable {
    /// Opaque structural identity used to discard duplicate or late child results.
    struct ID: Equatable, Hashable {
        fileprivate let rowKey: AgentChangesRowKey
        fileprivate let locatorKey: String
        fileprivate let locatorOrder: Int
        fileprivate let utf16Offset: Int
    }

    let id: ID

    let rowKey: AgentChangesRowKey

    var groupID: AgentChangesGroupID {
        rowKey.groupID
    }

    /// Resolver/group order, then section and row order inside that group.
    let groupOrder: Int
    let sectionOrder: Int
    let rowOrder: Int

    /// Position of the rendered heading or body line within its locator family.
    ///
    /// UTF-16 offsets are local to one displayed string, so this disambiguates equal offsets from
    /// two different lines without making projection hunk positions part of cross-context identity.
    let locatorOrder: Int

    let locator: AgentChangesSearchLocator
    let utf16Range: Range<Int>
    let displayedText: String

    init(
        rowKey: AgentChangesRowKey,
        groupOrder: Int,
        sectionOrder: Int,
        rowOrder: Int,
        locatorOrder: Int,
        locator: AgentChangesSearchLocator,
        utf16Range: Range<Int>,
        displayedText: String
    ) {
        id = ID(
            rowKey: rowKey,
            locatorKey: locator.stableKey,
            locatorOrder: locatorOrder,
            utf16Offset: utf16Range.lowerBound
        )
        self.rowKey = rowKey
        self.groupOrder = groupOrder
        self.sectionOrder = sectionOrder
        self.rowOrder = rowOrder
        self.locatorOrder = locatorOrder
        self.locator = locator
        self.utf16Range = utf16Range
        self.displayedText = displayedText
    }
}

/// Published value for the active in-diff search generation.
struct AgentChangesSearchState: Equatable {
    let query: String
    let phase: AgentChangesSearchPhase
    let matches: [AgentChangesSearchMatch]
    let selectedMatchIndex: Int?
    let skippedFileCount: Int
    let isTruncated: Bool

    static let idle = AgentChangesSearchState(
        query: "",
        phase: .idle,
        matches: [],
        selectedMatchIndex: nil,
        skippedFileCount: 0,
        isTruncated: false
    )

    init(
        query: String,
        phase: AgentChangesSearchPhase,
        matches: [AgentChangesSearchMatch] = [],
        selectedMatchIndex: Int? = nil,
        skippedFileCount: Int = 0,
        isTruncated: Bool = false
    ) {
        self.query = query
        self.phase = phase
        self.matches = matches
        self.selectedMatchIndex = selectedMatchIndex
        self.skippedFileCount = skippedFileCount
        self.isTruncated = isTruncated
    }

    var selectedMatch: AgentChangesSearchMatch? {
        guard let selectedMatchIndex, matches.indices.contains(selectedMatchIndex) else { return nil }
        return matches[selectedMatchIndex]
    }
}

/// Bounded repository result consumed by the pure search engine.
///
/// Unavailability is a typed content state rather than a nullable projection plus a Boolean, which
/// prevents consumers from accidentally searching a stale document after a failed or oversized
/// read. The byte count records examined patch text for the cross-repository search budget.
struct AgentChangesSearchPatchDocument: Equatable {
    enum Content: Equatable {
        case projected(FileDiffProjection.Document)
        case unavailable
    }

    let content: Content
    let byteCount: Int
    let isTruncated: Bool

    init(
        document: FileDiffProjection.Document,
        byteCount: Int,
        isTruncated: Bool = false
    ) {
        precondition(byteCount >= 0, "Search document byte counts cannot be negative")
        content = .projected(document)
        self.byteCount = byteCount
        self.isTruncated = isTruncated || document.truncation != nil
    }

    static func unavailable(byteCount: Int = 0) -> AgentChangesSearchPatchDocument {
        precondition(byteCount >= 0, "Search document byte counts cannot be negative")
        return AgentChangesSearchPatchDocument(
            content: .unavailable,
            byteCount: byteCount,
            isTruncated: false
        )
    }

    var document: FileDiffProjection.Document? {
        guard case let .projected(document) = content else { return nil }
        return document
    }

    var isUnavailable: Bool {
        if case .unavailable = content { return true }
        return false
    }

    private init(content: Content, byteCount: Int, isTruncated: Bool) {
        self.content = content
        self.byteCount = byteCount
        self.isTruncated = isTruncated
    }
}
