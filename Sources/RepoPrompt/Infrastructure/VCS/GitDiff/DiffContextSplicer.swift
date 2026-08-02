import Foundation

/// Derives hidden unchanged regions around hunks and splices requested source lines into them.
///
/// A gap is identified by its neighboring stable hunk IDs, so revealing twelve lines does not mint
/// a new gap identity for the remainder. Source text comes from the repository layer; this type is
/// pure and only performs numbering and value-model reconstruction.
enum DiffContextSplicer {
    enum SourceSide: Equatable {
        case old
        case new
    }

    enum ExpansionAmount: Equatable {
        case lines(Int)
        case all
    }

    struct Gap: Equatable, Identifiable {
        enum Location: Equatable {
            case beforeFirst
            case between(leftHunkIndex: Int, rightHunkIndex: Int)
            case afterLast
        }

        let id: String
        let location: Location
        let oldRange: Range<Int>?
        let newRange: Range<Int>?
        /// Nil only for a possible trailing gap before source content has supplied the file length.
        let hiddenLineCount: Int?
    }

    static func gaps(
        in document: FileDiffProjection.Document,
        sourceLineCount: Int?,
        sourceSide: SourceSide
    ) -> [Gap] {
        guard document.truncation == nil, !document.hunks.isEmpty else { return [] }

        var result: [Gap] = []
        let first = document.hunks[0]
        if let gap = makeGap(
            id: "\(document.id)#gap#before#\(first.id)",
            location: .beforeFirst,
            oldRange: rangeBefore(hunk: first, side: .old),
            newRange: rangeBefore(hunk: first, side: .new),
            sourceSide: sourceSide
        ) {
            result.append(gap)
        }

        if document.hunks.count > 1 {
            for rightIndex in 1 ..< document.hunks.count {
                let leftIndex = rightIndex - 1
                let left = document.hunks[leftIndex]
                let right = document.hunks[rightIndex]
                if let gap = makeGap(
                    id: "\(document.id)#gap#between#\(left.id)#\(right.id)",
                    location: .between(leftHunkIndex: leftIndex, rightHunkIndex: rightIndex),
                    oldRange: rangeBetween(left: left, right: right, side: .old),
                    newRange: rangeBetween(left: left, right: right, side: .new),
                    sourceSide: sourceSide
                ) {
                    result.append(gap)
                }
            }
        }

        let lastIndex = document.hunks.count - 1
        let last = document.hunks[lastIndex]
        if let sourceLineCount,
           let sourceRange = rangeAfter(hunk: last, side: sourceSide, lineCount: sourceLineCount)
        {
            let otherSide: SourceSide = sourceSide == .old ? .new : .old
            let otherRange = hunkRange(last, side: otherSide).map {
                $0.upperBound ..< ($0.upperBound + sourceRange.count)
            }
            let oldRange = sourceSide == .old ? sourceRange : otherRange
            let newRange = sourceSide == .new ? sourceRange : otherRange
            if let gap = makeGap(
                id: "\(document.id)#gap#after#\(last.id)",
                location: .afterLast,
                oldRange: oldRange,
                newRange: newRange,
                sourceSide: sourceSide
            ) {
                result.append(gap)
            }
        } else if sourceLineCount == nil, hasPotentialTrailingGap(
            in: document,
            sourceSide: sourceSide
        ) {
            result.append(Gap(
                id: "\(document.id)#gap#after#\(last.id)",
                location: .afterLast,
                oldRange: nil,
                newRange: nil,
                hiddenLineCount: nil
            ))
        }

        return result
    }

    static func splice(
        document: FileDiffProjection.Document,
        sourceLines: [String],
        sourceSide: SourceSide,
        gapID: String,
        amount: ExpansionAmount
    ) -> FileDiffProjection.Document {
        let availableGaps = gaps(
            in: document,
            sourceLineCount: sourceLines.count,
            sourceSide: sourceSide
        )
        guard let gap = availableGaps.first(where: { $0.id == gapID }),
              let sourceRange = sourceSide == .old ? gap.oldRange : gap.newRange,
              !sourceRange.isEmpty
        else { return document }

        let selections = selectedOffsets(
            count: sourceRange.count,
            location: gap.location,
            amount: amount
        )
        guard !selections.isEmpty else { return document }

        let oldRange = gap.oldRange
        let newRange = gap.newRange

        func lines(for offsets: Range<Int>) -> [FileDiffProjection.Line] {
            offsets.map { offset in
                let sourceNumber = sourceRange.lowerBound + offset
                let oldNumber: Int?
                let newNumber: Int?
                switch sourceSide {
                case .old:
                    oldNumber = sourceNumber
                    newNumber = newRange.map { $0.lowerBound + offset }
                case .new:
                    oldNumber = oldRange.map { $0.lowerBound + offset }
                    newNumber = sourceNumber
                }
                return FileDiffProjection.Line(
                    id: "\(gap.id)#\(oldNumber ?? 0):\(newNumber ?? 0)",
                    kind: .context,
                    oldLine: oldNumber,
                    newLine: newNumber,
                    text: sourceLines[sourceNumber - 1]
                )
            }
        }

        var hunks = document.hunks
        switch gap.location {
        case .beforeFirst:
            hunks[0] = expanding(hunks[0], prepending: lines(for: selections[0]), appending: [])

        case .afterLast:
            let lastIndex = hunks.count - 1
            hunks[lastIndex] = expanding(
                hunks[lastIndex],
                prepending: [],
                appending: lines(for: selections[0])
            )

        case let .between(leftIndex, rightIndex):
            let leading = selections.first.map(lines(for:)) ?? []
            let trailing = selections.count > 1 ? lines(for: selections[1]) : []
            hunks[leftIndex] = expanding(hunks[leftIndex], prepending: [], appending: leading)
            hunks[rightIndex] = expanding(hunks[rightIndex], prepending: trailing, appending: [])
        }

        return FileDiffProjection.Document(
            id: document.id,
            path: document.path,
            oldPath: document.oldPath,
            change: document.change,
            additions: document.additions,
            deletions: document.deletions,
            hunks: hunks,
            contextLevel: document.contextLevel,
            oldSourceReference: document.oldSourceReference,
            truncation: document.truncation
        )
    }

    // MARK: - Gap derivation

    private static func makeGap(
        id: String,
        location: Gap.Location,
        oldRange: Range<Int>?,
        newRange: Range<Int>?,
        sourceSide: SourceSide
    ) -> Gap? {
        guard let sourceRange = sourceSide == .old ? oldRange : newRange,
              !sourceRange.isEmpty
        else { return nil }

        let alignedOld = oldRange?.count == sourceRange.count ? oldRange : nil
        let alignedNew = newRange?.count == sourceRange.count ? newRange : nil
        return Gap(
            id: id,
            location: location,
            oldRange: alignedOld,
            newRange: alignedNew,
            hiddenLineCount: sourceRange.count
        )
    }

    private static func hunkRange(
        _ hunk: FileDiffProjection.Hunk,
        side: SourceSide
    ) -> Range<Int>? {
        let start = side == .old ? hunk.oldStart : hunk.newStart
        let count = side == .old ? hunk.oldCount : hunk.newCount
        guard count > 0 else { return nil }
        return start ..< (start + count)
    }

    private static func rangeBefore(
        hunk: FileDiffProjection.Hunk,
        side: SourceSide
    ) -> Range<Int>? {
        guard let hunkRange = hunkRange(hunk, side: side), hunkRange.lowerBound > 1 else {
            return nil
        }
        return 1 ..< hunkRange.lowerBound
    }

    private static func rangeBetween(
        left: FileDiffProjection.Hunk,
        right: FileDiffProjection.Hunk,
        side: SourceSide
    ) -> Range<Int>? {
        guard let leftRange = hunkRange(left, side: side),
              let rightRange = hunkRange(right, side: side),
              leftRange.upperBound < rightRange.lowerBound
        else { return nil }
        return leftRange.upperBound ..< rightRange.lowerBound
    }

    private static func rangeAfter(
        hunk: FileDiffProjection.Hunk,
        side: SourceSide,
        lineCount: Int?
    ) -> Range<Int>? {
        guard let lineCount,
              let hunkRange = hunkRange(hunk, side: side),
              hunkRange.upperBound <= lineCount
        else { return nil }
        let range = hunkRange.upperBound ..< (lineCount + 1)
        return range.isEmpty ? nil : range
    }

    private static func hasPotentialTrailingGap(
        in document: FileDiffProjection.Document,
        sourceSide: SourceSide
    ) -> Bool {
        guard case let .lines(contextLines) = document.contextLevel,
              contextLines > 0,
              let last = document.hunks.last
        else { return false }

        var trailingContext = 0
        for line in last.lines.reversed() {
            guard line.kind == .context else { break }
            let number = sourceSide == .old ? line.oldLine : line.newLine
            guard number != nil else { break }
            trailingContext += 1
        }
        return trailingContext >= contextLines
    }

    // MARK: - Selection and reconstruction

    private static func selectedOffsets(
        count: Int,
        location: Gap.Location,
        amount: ExpansionAmount
    ) -> [Range<Int>] {
        guard count > 0 else { return [] }

        switch location {
        case .beforeFirst:
            let reveal = revealCount(count: count, amount: amount)
            return [(count - reveal) ..< count]

        case .afterLast:
            let reveal = revealCount(count: count, amount: amount)
            return [0 ..< reveal]

        case .between:
            let reveal = revealCount(count: count, amount: amount)
            let leadingCount = (reveal + 1) / 2
            let trailingCount = reveal - leadingCount
            var result: [Range<Int>] = []
            if leadingCount > 0 { result.append(0 ..< leadingCount) }
            if trailingCount > 0 { result.append((count - trailingCount) ..< count) }
            return result
        }
    }

    private static func revealCount(count: Int, amount: ExpansionAmount) -> Int {
        switch amount {
        case let .lines(limit): min(count, max(limit, 0))
        case .all: count
        }
    }

    private static func expanding(
        _ hunk: FileDiffProjection.Hunk,
        prepending: [FileDiffProjection.Line],
        appending: [FileDiffProjection.Line]
    ) -> FileDiffProjection.Hunk {
        let oldAdded = prepending.count(where: { $0.oldLine != nil })
            + appending.count(where: { $0.oldLine != nil })
        let newAdded = prepending.count(where: { $0.newLine != nil })
            + appending.count(where: { $0.newLine != nil })
        let oldStart = prepending.compactMap(\.oldLine).first ?? hunk.oldStart
        let newStart = prepending.compactMap(\.newLine).first ?? hunk.newStart

        return FileDiffProjection.Hunk(
            id: hunk.id,
            oldStart: oldStart,
            oldCount: hunk.oldCount + oldAdded,
            newStart: newStart,
            newCount: hunk.newCount + newAdded,
            heading: hunk.heading,
            lines: prepending + hunk.lines + appending
        )
    }
}
