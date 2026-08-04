import Foundation

/// Pure literal matcher for the rendered Changes diff corpus.
///
/// Regex is intentionally absent: the Phase-3 contract favors predictable visible-text matching,
/// bounded work, and ranges that can be handed directly to AppKit highlighting.
enum AgentChangesSearchEngine {
    private static let matchingLocale = Locale(identifier: "en_US_POSIX")
    private static let matchingOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive
    ]

    /// Finds every literal occurrence while preserving offsets into the original displayed string.
    ///
    /// Advancement starts one Unicode scalar after the prior match start instead of after the whole
    /// match. This admits overlapping occurrences, including repeated components inside one ZWJ
    /// grapheme, without splitting surrogate pairs. Returned integers remain UTF-16 offsets.
    static func literalUTF16Ranges(
        of query: String,
        in text: String,
        maximumMatchCount: Int = AgentChangesSearchBudget.standard.maximumMatchCount
    ) -> [Range<Int>] {
        precondition(maximumMatchCount >= 0, "Search match limits cannot be negative")
        guard maximumMatchCount > 0 else { return [] }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard !text.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex

        while ranges.count < maximumMatchCount,
              searchStart < text.endIndex,
              let match = text.range(
                  of: query,
                  options: matchingOptions,
                  range: searchStart ..< text.endIndex,
                  locale: matchingLocale
              )
        {
            let utf16Range = NSRange(match, in: text)
            ranges.append(utf16Range.location ..< NSMaxRange(utf16Range))

            // Advancing one Unicode scalar is overlap-safe without splitting a surrogate pair.
            // Character advancement would skip a second query occurrence inside one ZWJ grapheme.
            searchStart = text.unicodeScalars.index(after: match.lowerBound)
        }

        return ranges
    }

    /// Matches a row path before its patch has been loaded.
    static func pathMatches(
        query: String,
        rowKey: AgentChangesRowKey,
        groupOrder: Int,
        sectionOrder: Int,
        rowOrder: Int,
        path: String,
        maximumMatchCount: Int = AgentChangesSearchBudget.standard.maximumMatchCount
    ) -> [AgentChangesSearchMatch] {
        makeMatches(
            query: query,
            text: path,
            rowKey: rowKey,
            groupOrder: groupOrder,
            sectionOrder: sectionOrder,
            rowOrder: rowOrder,
            locatorOrder: 0,
            locator: .filePath,
            maximumMatchCount: maximumMatchCount
        )
    }

    /// Matches projected headings and body lines without repeating the separately loaded path.
    static func patchMatches(
        query: String,
        rowKey: AgentChangesRowKey,
        groupOrder: Int,
        sectionOrder: Int,
        rowOrder: Int,
        document: FileDiffProjection.Document,
        maximumMatchCount: Int = AgentChangesSearchBudget.standard.maximumMatchCount
    ) -> [AgentChangesSearchMatch] {
        precondition(maximumMatchCount >= 0, "Search match limits cannot be negative")
        guard maximumMatchCount > 0 else { return [] }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var matches: [AgentChangesSearchMatch] = []
        var headingOrder = 0
        var lineOrder = 0

        hunkLoop: for hunk in document.hunks {
            if let heading = hunk.heading, !heading.isEmpty {
                matches += makeMatches(
                    query: query,
                    text: heading,
                    rowKey: rowKey,
                    groupOrder: groupOrder,
                    sectionOrder: sectionOrder,
                    rowOrder: rowOrder,
                    locatorOrder: headingOrder,
                    locator: .hunkHeading(hunkID: hunk.id),
                    maximumMatchCount: maximumMatchCount - matches.count
                )
                headingOrder += 1
                guard matches.count < maximumMatchCount else { break hunkLoop }
            }

            for line in hunk.lines {
                guard matches.count < maximumMatchCount else { break hunkLoop }
                // Every kind, including no-newline markers, matches the exact projected text the
                // patch view draws. Normalising here would shift the returned UTF-16 offsets off the
                // rendered string and highlight the wrong characters.
                matches += makeMatches(
                    query: query,
                    text: line.text,
                    rowKey: rowKey,
                    groupOrder: groupOrder,
                    sectionOrder: sectionOrder,
                    rowOrder: rowOrder,
                    locatorOrder: lineOrder,
                    locator: .line(
                        kind: line.kind,
                        oldLine: line.oldLine,
                        newLine: line.newLine
                    ),
                    maximumMatchCount: maximumMatchCount - matches.count
                )
                lineOrder += 1
            }
        }

        return ordered(matches)
    }

    /// Convenience for callers that already have a projection and have not emitted path matches.
    static func matches(
        query: String,
        rowKey: AgentChangesRowKey,
        groupOrder: Int,
        sectionOrder: Int,
        rowOrder: Int,
        document: FileDiffProjection.Document,
        includeFilePath: Bool = true,
        maximumMatchCount: Int = AgentChangesSearchBudget.standard.maximumMatchCount
    ) -> [AgentChangesSearchMatch] {
        precondition(maximumMatchCount >= 0, "Search match limits cannot be negative")
        guard maximumMatchCount > 0 else { return [] }
        var matches: [AgentChangesSearchMatch] = []
        if includeFilePath {
            matches += pathMatches(
                query: query,
                rowKey: rowKey,
                groupOrder: groupOrder,
                sectionOrder: sectionOrder,
                rowOrder: rowOrder,
                path: document.path,
                maximumMatchCount: maximumMatchCount
            )
        }
        matches += patchMatches(
            query: query,
            rowKey: rowKey,
            groupOrder: groupOrder,
            sectionOrder: sectionOrder,
            rowOrder: rowOrder,
            document: document,
            maximumMatchCount: maximumMatchCount - matches.count
        )
        return ordered(matches)
    }

    /// Establishes one total order independent of child-task completion order.
    ///
    /// Group, section, and row positions come from the view model's frozen corpus. Within one row,
    /// paths precede headings, headings precede body lines, rendered-element order disambiguates
    /// different strings, and the final occurrence order is the UTF-16 offset inside that string.
    static func ordered(_ matches: [AgentChangesSearchMatch]) -> [AgentChangesSearchMatch] {
        matches.sorted(by: precedes)
    }

    static func precedes(_ lhs: AgentChangesSearchMatch, _ rhs: AgentChangesSearchMatch) -> Bool {
        if lhs.groupOrder != rhs.groupOrder { return lhs.groupOrder < rhs.groupOrder }
        if lhs.sectionOrder != rhs.sectionOrder { return lhs.sectionOrder < rhs.sectionOrder }
        if lhs.rowOrder != rhs.rowOrder { return lhs.rowOrder < rhs.rowOrder }

        let lhsLocatorRank = locatorRank(lhs.locator)
        let rhsLocatorRank = locatorRank(rhs.locator)
        if lhsLocatorRank != rhsLocatorRank { return lhsLocatorRank < rhsLocatorRank }
        if lhs.locatorOrder != rhs.locatorOrder { return lhs.locatorOrder < rhs.locatorOrder }
        if lhs.utf16Range.lowerBound != rhs.utf16Range.lowerBound {
            return lhs.utf16Range.lowerBound < rhs.utf16Range.lowerBound
        }
        if lhs.utf16Range.upperBound != rhs.utf16Range.upperBound {
            return lhs.utf16Range.upperBound < rhs.utf16Range.upperBound
        }

        // The corpus positions should already be unique. These structural fallbacks make the
        // helper deterministic even for malformed fixtures or duplicated orchestration input.
        if lhs.groupID.targetKey != rhs.groupID.targetKey {
            return lhs.groupID.targetKey < rhs.groupID.targetKey
        }
        if lhs.rowKey.rowID != rhs.rowKey.rowID {
            return lhs.rowKey.rowID < rhs.rowKey.rowID
        }

        let lhsLocatorKey = locatorTieBreak(lhs.locator)
        let rhsLocatorKey = locatorTieBreak(rhs.locator)
        if lhsLocatorKey != rhsLocatorKey { return lhsLocatorKey < rhsLocatorKey }
        return lhs.displayedText < rhs.displayedText
    }

    private static func makeMatches(
        query: String,
        text: String,
        rowKey: AgentChangesRowKey,
        groupOrder: Int,
        sectionOrder: Int,
        rowOrder: Int,
        locatorOrder: Int,
        locator: AgentChangesSearchLocator,
        maximumMatchCount: Int
    ) -> [AgentChangesSearchMatch] {
        literalUTF16Ranges(
            of: query,
            in: text,
            maximumMatchCount: maximumMatchCount
        ).map { range in
            AgentChangesSearchMatch(
                rowKey: rowKey,
                groupOrder: groupOrder,
                sectionOrder: sectionOrder,
                rowOrder: rowOrder,
                locatorOrder: locatorOrder,
                locator: locator,
                utf16Range: range,
                displayedText: text
            )
        }
    }

    private static func locatorRank(_ locator: AgentChangesSearchLocator) -> Int {
        switch locator {
        case .filePath:
            0
        case .hunkHeading:
            1
        case .line:
            2
        }
    }

    private static func locatorTieBreak(_ locator: AgentChangesSearchLocator) -> String {
        switch locator {
        case .filePath:
            return ""
        case let .hunkHeading(hunkID):
            return hunkID
        case let .line(kind, oldLine, newLine):
            let kindKey = switch kind {
            case .context: "0"
            case .addition: "1"
            case .deletion: "2"
            case .noNewlineMarker: "3"
            }
            return [kindKey, oldLine.map(String.init) ?? "", newLine.map(String.init) ?? ""]
                .joined(separator: ":")
        }
    }
}

/// Hard limits for one search generation.
///
/// The standard values mirror the adopted plan. Batch overshoot remains an orchestration concern:
/// accounting stops future admission after a completed batch rather than pretending it can cancel
/// byte reads that already finished.
struct AgentChangesSearchBudget: Equatable {
    static let standard = AgentChangesSearchBudget(
        maximumExaminedByteCount: 24 * 1024 * 1024,
        maximumMatchCount: 5000
    )

    let maximumExaminedByteCount: Int
    let maximumMatchCount: Int

    init(maximumExaminedByteCount: Int, maximumMatchCount: Int) {
        precondition(maximumExaminedByteCount >= 0, "Search byte budgets cannot be negative")
        precondition(maximumMatchCount >= 0, "Search match budgets cannot be negative")
        self.maximumExaminedByteCount = maximumExaminedByteCount
        self.maximumMatchCount = maximumMatchCount
    }
}

/// Incremental budget and footer accounting for one search generation.
struct AgentChangesSearchBudgetAccounting: Equatable {
    let budget: AgentChangesSearchBudget
    private(set) var examinedByteCount = 0
    private(set) var matches: [AgentChangesSearchMatch] = []
    private(set) var skippedFileCount = 0
    private(set) var isTruncated = false

    init(budget: AgentChangesSearchBudget = .standard) {
        self.budget = budget
    }

    var matchCount: Int {
        matches.count
    }

    /// Whether orchestration may schedule another patch-read batch.
    ///
    /// A completed batch may overshoot the byte threshold by design. The caller records all four
    /// outcomes, then consults this value before scheduling the next bounded batch.
    var canScheduleMore: Bool {
        examinedByteCount < budget.maximumExaminedByteCount
            && matchCount < budget.maximumMatchCount
    }

    /// Records bytes for every outcome and skipped/truncated state for repository failures.
    mutating func record(_ document: AgentChangesSearchPatchDocument) {
        examinedByteCount = saturatingSum(examinedByteCount, document.byteCount)
        if document.isUnavailable {
            skippedFileCount = saturatingSum(skippedFileCount, 1)
        }
        if document.isTruncated {
            isTruncated = true
        }
    }

    /// Merges one already-sorted batch into the deterministic global top-N.
    ///
    /// This is the only admission path, so path and patch candidates for the same rows compete for
    /// the same cap slots. Results from at most four concurrent reads may arrive out of corpus
    /// order. The caller sorts each completed batch once; this linear merge lets an earlier row
    /// displace a later row while stable IDs suppress duplicate child results.
    @discardableResult
    mutating func accept(
        _ proposedMatches: [AgentChangesSearchMatch]
    ) -> [AgentChangesSearchMatch] {
        guard !proposedMatches.isEmpty else { return matches }

        var seen: Set<AgentChangesSearchMatch.ID> = []
        var accepted: [AgentChangesSearchMatch] = []
        accepted.reserveCapacity(min(
            budget.maximumMatchCount,
            matches.count + proposedMatches.count
        ))
        var currentIndex = 0
        var proposedIndex = 0

        while currentIndex < matches.count || proposedIndex < proposedMatches.count {
            let candidate: AgentChangesSearchMatch
            if proposedIndex >= proposedMatches.count {
                candidate = matches[currentIndex]
                currentIndex += 1
            } else if currentIndex >= matches.count {
                candidate = proposedMatches[proposedIndex]
                proposedIndex += 1
            } else if AgentChangesSearchEngine.precedes(
                proposedMatches[proposedIndex],
                matches[currentIndex]
            ) {
                candidate = proposedMatches[proposedIndex]
                proposedIndex += 1
            } else {
                candidate = matches[currentIndex]
                currentIndex += 1
            }

            guard seen.insert(candidate.id).inserted else { continue }
            guard accepted.count < budget.maximumMatchCount else {
                isTruncated = true
                continue
            }
            accepted.append(candidate)
        }

        matches = accepted
        return accepted
    }

    /// Marks files left unscheduled after a byte or match cap stopped corpus traversal.
    mutating func recordBudgetExcludedFiles(_ count: Int) {
        precondition(count >= 0, "Excluded file counts cannot be negative")
        guard count > 0 else { return }
        skippedFileCount = saturatingSum(skippedFileCount, count)
        isTruncated = true
    }

    private func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
