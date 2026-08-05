import AppKit
import SwiftUI

struct UnifiedDiffDocument: Equatable, Hashable {
    struct Line: Equatable, Hashable {
        enum Kind: Equatable, Hashable {
            case addition
            case deletion
            case context
            case gap
            case fileHeader

            func nsTextColor(colorScheme: ColorScheme) -> NSColor {
                switch self {
                case .addition:
                    colorScheme == .dark
                        ? NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.4, alpha: 1)
                        : NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.1, alpha: 1)
                case .deletion:
                    colorScheme == .dark
                        ? NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.4, alpha: 1)
                        : NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1)
                case .gap, .fileHeader:
                    .secondaryLabelColor
                case .context:
                    colorScheme == .dark ? .textColor : .labelColor
                }
            }

            func nsBackgroundColor(colorScheme: ColorScheme) -> NSColor? {
                switch self {
                case .addition:
                    NSColor.systemGreen.withAlphaComponent(colorScheme == .dark ? 0.15 : 0.1)
                case .deletion:
                    NSColor.systemRed.withAlphaComponent(colorScheme == .dark ? 0.15 : 0.1)
                case .fileHeader:
                    NSColor.secondaryLabelColor.withAlphaComponent(0.05)
                case .gap:
                    NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                case .context:
                    nil
                }
            }
        }

        let kind: Kind
        let text: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    let lines: [Line]
    let maxLineNumberDigits: Int
    let renderID: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(renderID)
    }
}

private final class UnifiedDiffDocumentBox: NSObject {
    let document: UnifiedDiffDocument

    init(_ document: UnifiedDiffDocument) {
        self.document = document
    }
}

enum UnifiedDiffCardRendering {
    private static let appKitHorizontalTextPaddingBase: CGFloat = 6
    private static let appKitVerticalTextInsetBase: CGFloat = 0
    private static let appKitLineSpacingBase: CGFloat = 2
    private static let appKitMinimumBodyHeightBase: CGFloat = 44

    static func appKitHorizontalTextPadding(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledMetric(appKitHorizontalTextPaddingBase)
    }

    static func appKitVerticalTextInset(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledMetric(appKitVerticalTextInsetBase)
    }

    static func appKitLineSpacing(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledMetric(appKitLineSpacingBase)
    }

    static func appKitMinimumBodyHeight(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledMetric(appKitMinimumBodyHeightBase)
    }

    private static let parseCache: NSCache<NSString, UnifiedDiffDocumentBox> = {
        let cache = NSCache<NSString, UnifiedDiffDocumentBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    static func estimatedHeight(
        for document: UnifiedDiffDocument,
        fontSize: CGFloat,
        fontPreset: FontScalePreset,
        maxHeight: CGFloat,
        availableWidth: CGFloat = .greatestFiniteMagnitude,
        wrapLines: Bool = false,
        preferredPostScriptName: String? = nil
    ) -> CGFloat {
        let normalizedPreference = preferredPostScriptName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !wrapLines, normalizedPreference?.isEmpty != false {
            // Preserve the pre-wrap/default-font arithmetic exactly. TextKit measurement can
            // differ by fractional rounding even when every source line remains unwrapped.
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let baseLineHeight = ceil(font.ascender - font.descender + font.leading)
            let spacingCount = max(document.lines.count - 1, 0)
            let contentHeight =
                (CGFloat(max(document.lines.count, 1)) * baseLineHeight) +
                (CGFloat(spacingCount) * appKitLineSpacing(for: fontPreset)) +
                (appKitVerticalTextInset(for: fontPreset) * 2)
            return min(max(contentHeight, appKitMinimumBodyHeight(for: fontPreset)), maxHeight)
        }

        let metrics = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: availableWidth,
            wrapLines: wrapLines,
            fontPreset: fontPreset,
            fontSize: fontSize,
            preferredPostScriptName: preferredPostScriptName
        )
        return min(max(metrics.height, appKitMinimumBodyHeight(for: fontPreset)), maxHeight)
    }

    static func parse(_ diff: String) -> UnifiedDiffDocument {
        let key = diff as NSString
        let cost = diff.utf8.count
        if let cached = parseCache.object(forKey: key) {
            EditFlowPerf.event(
                EditFlowPerf.Stage.UnifiedDiff.parseForRender,
                EditFlowPerf.Dimensions(status: "cache-hit", fileBytes: cost)
            )
            return cached.document
        }

        let document = EditFlowPerf.measure(
            EditFlowPerf.Stage.UnifiedDiff.parseForRender,
            EditFlowPerf.Dimensions(status: "cache-miss", fileBytes: cost)
        ) {
            parseUncached(diff)
        }
        parseCache.setObject(UnifiedDiffDocumentBox(document), forKey: key, cost: cost)
        return document
    }

    private static func parseUncached(_ diff: String) -> UnifiedDiffDocument {
        let rawLines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [UnifiedDiffDocument.Line] = []
        lines.reserveCapacity(rawLines.count)
        var maxOldDigits = 0
        var maxNewDigits = 0
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var skippedLeadingPathHeaderPair = false
        var pendingLeadingPlusHeaderSkip = false

        func appendLine(kind: UnifiedDiffDocument.Line.Kind, text: String, old: Int?, new: Int?) {
            if let old {
                maxOldDigits = max(maxOldDigits, String(old).count)
            }
            if let new {
                maxNewDigits = max(maxNewDigits, String(new).count)
            }
            lines.append(.init(kind: kind, text: text, oldLineNumber: old, newLineNumber: new))
        }

        for (index, line) in rawLines.enumerated() {
            if !skippedLeadingPathHeaderPair,
               !inHunk,
               line.hasPrefix("--- "),
               index + 1 < rawLines.count,
               rawLines[index + 1].hasPrefix("+++ ")
            {
                skippedLeadingPathHeaderPair = true
                pendingLeadingPlusHeaderSkip = true
                continue
            }
            if pendingLeadingPlusHeaderSkip,
               !inHunk,
               line.hasPrefix("+++ "),
               index > 0,
               rawLines[index - 1].hasPrefix("--- ")
            {
                pendingLeadingPlusHeaderSkip = false
                continue
            }
            pendingLeadingPlusHeaderSkip = false

            if line.hasPrefix("@@") {
                if let (oldStart, newStart) = parseHunkHeader(line) {
                    if inHunk {
                        let hiddenOld = max(0, oldStart - oldLine)
                        let hiddenNew = max(0, newStart - newLine)
                        let hiddenLines = max(hiddenOld, hiddenNew)
                        if hiddenLines > 0 {
                            appendLine(kind: .gap, text: collapsedGapText(for: hiddenLines), old: nil, new: nil)
                        }
                    }
                    oldLine = oldStart
                    newLine = newStart
                    inHunk = true
                } else {
                    appendLine(kind: .fileHeader, text: String(line), old: nil, new: nil)
                    inHunk = false
                    oldLine = 0
                    newLine = 0
                }
                continue
            }

            if line.hasPrefix("diff --git") {
                inHunk = false
                oldLine = 0
                newLine = 0
                appendLine(kind: .fileHeader, text: String(line), old: nil, new: nil)
                continue
            }
            if line.hasPrefix("index ") {
                inHunk = false
                oldLine = 0
                newLine = 0
                appendLine(kind: .fileHeader, text: String(line), old: nil, new: nil)
                continue
            }
            if !inHunk && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) {
                appendLine(kind: .fileHeader, text: String(line), old: nil, new: nil)
                continue
            }

            let text = String(line)
            if line.hasPrefix("+") {
                let numberedNewLine = newLine > 0 ? newLine : nil
                appendLine(kind: .addition, text: text, old: nil, new: numberedNewLine)
                if newLine > 0 {
                    newLine += 1
                }
                continue
            }

            if line.hasPrefix("-") {
                let numberedOldLine = oldLine > 0 ? oldLine : nil
                appendLine(kind: .deletion, text: text, old: numberedOldLine, new: nil)
                if oldLine > 0 {
                    oldLine += 1
                }
                continue
            }

            if line.hasPrefix(" ") || (oldLine > 0 && newLine > 0) {
                appendLine(kind: .context, text: text, old: oldLine, new: newLine)
                oldLine += 1
                newLine += 1
                continue
            }

            appendLine(kind: .context, text: text, old: nil, new: nil)
        }

        let maxLineNumberDigits = max(maxOldDigits, maxNewDigits, 2)
        return UnifiedDiffDocument(
            lines: lines,
            maxLineNumberDigits: maxLineNumberDigits,
            renderID: renderID(for: lines, maxLineNumberDigits: maxLineNumberDigits)
        )
    }

    private static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, newStart: Int)? {
        var index = line.startIndex
        guard line[index...].hasPrefix("@@ -") else { return nil }
        index = line.index(index, offsetBy: 4)
        guard let oldStart = parseDecimal(in: line, from: &index) else { return nil }
        if index < line.endIndex, line[index] == "," {
            index = line.index(after: index)
            guard parseDecimal(in: line, from: &index) != nil else { return nil }
        }
        guard index < line.endIndex, line[index] == " " else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == "+" else { return nil }
        index = line.index(after: index)
        guard let newStart = parseDecimal(in: line, from: &index) else { return nil }
        if index < line.endIndex, line[index] == "," {
            index = line.index(after: index)
            guard parseDecimal(in: line, from: &index) != nil else { return nil }
        }
        guard line[index...].hasPrefix(" @@") else { return nil }
        return (oldStart, newStart)
    }

    private static func parseDecimal(in line: Substring, from index: inout Substring.Index) -> Int? {
        guard index < line.endIndex, let firstDigit = line[index].wholeNumberValue else {
            return nil
        }
        var value = firstDigit
        index = line.index(after: index)
        while index < line.endIndex, let digit = line[index].wholeNumberValue {
            value = (value * 10) + digit
            index = line.index(after: index)
        }
        return value
    }

    static func collapsedGapText(for hiddenLines: Int) -> String {
        if hiddenLines == 1 {
            return "⋯ 1 unchanged line ⋯"
        }
        return "⋯ \(hiddenLines) unchanged lines ⋯"
    }

    private static func renderID(for lines: [UnifiedDiffDocument.Line], maxLineNumberDigits: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(maxLineNumberDigits)
        for line in lines {
            hasher.combine(line.kind)
            hasher.combine(line.text)
            hasher.combine(line.oldLineNumber)
            hasher.combine(line.newLineNumber)
        }
        return hasher.finalize()
    }
}
