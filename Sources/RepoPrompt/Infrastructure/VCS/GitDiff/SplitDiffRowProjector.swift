import Foundation

/// Render-time projection of unified hunk lines into one synchronized split-row sequence.
///
/// The old/new line-number pairs remain authoritative on `FileDiffProjection.Line`. This type
/// derives alignment only when split rendering is requested; it never reparses patch text and never
/// creates a second scroll view.
enum SplitDiffRowProjector {
    struct Row: Equatable, Identifiable {
        let id: String
        let old: FileDiffProjection.Line?
        let new: FileDiffProjection.Line?
        /// Context occupies the full row rather than being duplicated into two cells.
        let spansBoth: Bool
    }

    static func rows(for hunk: FileDiffProjection.Hunk) -> [Row] {
        var rows: [Row] = []
        var index = 0

        while index < hunk.lines.count {
            let line = hunk.lines[index]
            if line.kind == .context {
                rows.append(Row(id: line.id, old: line, new: line, spansBoth: true))
                index += 1
                continue
            }

            if line.kind == .noNewlineMarker {
                rows.append(markerRow(line, previousLine: hunk.lines[safe: index - 1]))
                index += 1
                continue
            }

            let blockStart = index
            while index < hunk.lines.count, hunk.lines[index].kind != .context {
                index += 1
            }
            let block = Array(hunk.lines[blockStart ..< index])
            let deletions = block.filter { $0.kind == .deletion }
            let additions = block.filter { $0.kind == .addition }
            let pairCount = max(deletions.count, additions.count)

            for pairIndex in 0 ..< pairCount {
                let old = deletions[safe: pairIndex]
                let new = additions[safe: pairIndex]
                rows.append(Row(
                    id: [old?.id, new?.id].compactMap(\.self).joined(separator: "|"),
                    old: old,
                    new: new,
                    spansBoth: false
                ))
            }

            var previousChange: FileDiffProjection.Line?
            for item in block {
                switch item.kind {
                case .addition, .deletion:
                    previousChange = item
                case .noNewlineMarker:
                    rows.append(markerRow(item, previousLine: previousChange))
                case .context:
                    break
                }
            }
        }

        return rows
    }

    private static func markerRow(
        _ marker: FileDiffProjection.Line,
        previousLine: FileDiffProjection.Line?
    ) -> Row {
        if previousLine?.kind == .addition {
            return Row(id: marker.id, old: nil, new: marker, spansBoth: false)
        }
        return Row(id: marker.id, old: marker, new: nil, spansBoth: false)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
