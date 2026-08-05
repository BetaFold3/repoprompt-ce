import Foundation
import MCP

/// Response packaging for `ask_oracle` `response_mode` and `oracle_chat_log` paging.
enum OracleResponseMode: String {
    case full
    case tail
    case none

    static let `default`: OracleResponseMode = .full

    /// Character budget for `tail` excerpts (Swift `Character` count).
    static let tailExcerptCharacterBudget = 2000

    static func parse(_ raw: String?) throws -> OracleResponseMode {
        let normalized = (raw ?? Self.default.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mode = OracleResponseMode(rawValue: normalized) else {
            throw MCPError.invalidParams(
                "response_mode must be one of: full, tail, none"
            )
        }
        return mode
    }
}

enum OracleChatLogPart: String {
    case head
    case tail
    case both

    static let `default`: OracleChatLogPart = .tail

    static func parse(_ raw: String?) throws -> OracleChatLogPart {
        let normalized = (raw ?? Self.default.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let part = OracleChatLogPart(rawValue: normalized) else {
            throw MCPError.invalidParams(
                "part must be one of: head, tail, both"
            )
        }
        return part
    }
}

enum OracleResponsePresentation {
    static let defaultChatLogMaxCharsPerMessage = 8000

    static func truncateMarker(
        omittedCount: Int,
        originalCount: Int,
        exportPath: String? = nil,
        keptLineRange: ClosedRange<Int>? = nil
    ) -> String {
        var parts = ["[truncated: \(omittedCount) of \(originalCount) chars omitted"]
        if let exportPath, !exportPath.isEmpty {
            var retrieval = "full text: \(exportPath)"
            if let keptLineRange {
                retrieval += ", lines \(keptLineRange.lowerBound)–\(keptLineRange.upperBound)"
            }
            parts.append(retrieval)
        } else {
            parts.append(
                "retrieve full text via ask_oracle export_response:true, or retry with a larger max_chars"
            )
        }
        return parts.joined(separator: "; ") + "]"
    }

    /// Last `budget` characters of `text`, or the full string when shorter.
    static func characterTail(
        _ text: String,
        budget: Int = OracleResponseMode.tailExcerptCharacterBudget
    ) -> String {
        guard budget > 0, text.count > budget else { return text }
        let start = text.index(text.endIndex, offsetBy: -budget)
        return String(text[start...])
    }

    static func characterHead(_ text: String, budget: Int) -> String {
        guard budget > 0, text.count > budget else { return text }
        let end = text.index(text.startIndex, offsetBy: budget)
        return String(text[..<end])
    }

    static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Compacts one chat-log message according to `part` / `maxChars`.
    static func compactChatLogText(
        _ text: String,
        maxChars: Int,
        part: OracleChatLogPart
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxChars > 0, trimmed.count > maxChars else { return trimmed }

        let originalCount = trimmed.count
        switch part {
        case .tail:
            let kept = characterTail(trimmed, budget: maxChars)
            let omitted = originalCount - kept.count
            let startLine = max(1, lineCount(of: trimmed) - lineCount(of: kept) + 1)
            let endLine = lineCount(of: trimmed)
            return kept + "\n" + truncateMarker(
                omittedCount: omitted,
                originalCount: originalCount,
                keptLineRange: startLine ... endLine
            )
        case .head:
            let kept = characterHead(trimmed, budget: maxChars)
            let omitted = originalCount - kept.count
            let endLine = lineCount(of: kept)
            return kept + "\n" + truncateMarker(
                omittedCount: omitted,
                originalCount: originalCount,
                keptLineRange: 1 ... max(1, endLine)
            )
        case .both:
            let headBudget = max(1, (maxChars + 1) / 2)
            let tailBudget = max(0, maxChars - headBudget)
            let head = characterHead(trimmed, budget: headBudget)
            let tail = tailBudget > 0
                ? characterTail(trimmed, budget: tailBudget)
                : ""
            let omitted = max(0, originalCount - head.count - tail.count)
            let marker = truncateMarker(
                omittedCount: omitted,
                originalCount: originalCount
            )
            return head + "\n" + marker + "\n" + tail
        }
    }

    /// Applies a response ceiling across ordered message texts, truncating later messages first.
    /// Earlier messages are preserved in full whenever possible; later messages shrink (or clear)
    /// so the total including truncation markers stays within `maxTotalChars`.
    static func enforceTotalCharCeiling(
        messages: inout [[String: Value]],
        textKey: String = "text",
        maxTotalChars: Int
    ) {
        guard maxTotalChars > 0 else { return }

        func length(at index: Int) -> Int {
            messages[index][textKey]?.stringValue?.count ?? 0
        }

        func totalChars() -> Int {
            messages.indices.reduce(0) { $0 + length(at: $1) }
        }

        guard totalChars() > maxTotalChars else { return }

        for index in messages.indices.reversed() {
            guard totalChars() > maxTotalChars else { break }
            let earlier = messages.indices.filter { $0 < index }.reduce(0) { $0 + length(at: $1) }
            let budgetForThis = max(0, maxTotalChars - earlier)
            guard let text = messages[index][textKey]?.stringValue, !text.isEmpty else { continue }
            if text.count <= budgetForThis { continue }
            messages[index]["truncated"] = .bool(true)
            if budgetForThis == 0 {
                messages[index][textKey] = .string("")
                continue
            }

            let original = text.count
            let probeMarker = truncateMarker(
                omittedCount: original,
                originalCount: original
            )
            let markerReserve = probeMarker.count + 1
            if budgetForThis <= markerReserve {
                let compact = "[truncated: \(original) chars omitted]"
                messages[index][textKey] = .string(
                    compact.count <= budgetForThis ? compact : ""
                )
                continue
            }

            let keepBudget = budgetForThis - markerReserve
            let kept = characterHead(text, budget: keepBudget)
            let marker = truncateMarker(
                omittedCount: original - kept.count,
                originalCount: original
            )
            let candidate = kept + "\n" + marker
            messages[index][textKey] = .string(
                candidate.count <= budgetForThis ? candidate : ""
            )
        }
    }

    /// Trims a successful ask_oracle result for `response_mode`, always exporting when trimmed.
    static func applyResponseMode(
        to result: inout [String: Value],
        mode: OracleResponseMode,
        export: (_ response: String?) async throws -> OracleExportFile
    ) async throws {
        switch mode {
        case .full:
            return
        case .tail, .none:
            let fullResponse = result["response"]?.stringValue
            let exportFile = try await export(fullResponse)
            let fullText = fullResponse ?? ""
            let charCount = fullText.count
            let lines = lineCount(of: fullText)

            result.removeValue(forKey: "response")
            result["export_path"] = .string(exportFile.path)
            result["oracle_export_path"] = .string(exportFile.path)
            result["oracle_export_instruction"] = .string(exportFile.instruction)
            result["line_count"] = .int(lines)
            result["char_count"] = .int(charCount)
            result["response_mode"] = .string(mode.rawValue)

            if mode == .tail {
                let excerpt = characterTail(fullText)
                result["excerpt"] = .string(excerpt)
                result["excerpt_lines"] = .int(lineCount(of: excerpt))
            } else {
                result["excerpt_lines"] = .int(0)
            }
        }
    }
}
