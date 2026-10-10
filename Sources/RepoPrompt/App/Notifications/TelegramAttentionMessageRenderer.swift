import Foundation

// Plain-text Telegram rendering for attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 3).
//
// Every part fits Telegram's 4096-character limit, counted conservatively in UTF-16 units.
// Splitting partitions the body exactly: no grapheme, emoji, combining mark, or scalar is dropped
// or reordered. A grapheme cluster wider than a part is split between Unicode scalars rather
// than dropped. Completions use at most three parts: preferred line/word breaks first, then
// capacity-filling grapheme-safe splits, and only when even those exceed three parts the longest
// prefix that fills all three is kept, ending with a visible marker. Questions use as many parts
// as needed and are never cut. Workspace and session
// names lead the splittable content in full (newlines flattened to spaces), so a long name is
// split like any other text rather than cut; each part's header is only the title and part label.

/// One numbered Telegram message. `text` is what is sent; `body` is this part's slice of content.
struct TelegramAttentionMessagePart: Equatable {
    let number: Int
    let count: Int
    let header: String
    let body: String

    var text: String {
        header + body
    }
}

enum TelegramAttentionMessageRenderer {
    static let maximumUTF16Count = TelegramSendMessageClient.maximumTextUTF16Count
    static let maximumCompletionParts = 3
    static let truncationMarker = "\n… [truncated: reply longer than 3 messages]"
    static let noFinalTextBody = "(This turn ended without a final assistant message.)"
    static let emptyFinalTextBody = "(The final assistant message was empty.)"

    static func render(_ event: AttentionNotificationEvent) -> [TelegramAttentionMessagePart] {
        let context = contextPrefix(workspaceName: event.workspaceName, sessionName: event.sessionName)
        switch event.content {
        case let .turnCompleted(finalAssistantText):
            return renderCompletion(
                body: context + completionBody(finalAssistantText),
                header: { label in header("RepoPrompt: turn finished", label) }
            )
        case let .question(contentLines):
            return renderQuestion(
                body: context + contentLines.joined(separator: "\n"),
                header: { label in header("RepoPrompt: question waiting", label) }
            )
        }
    }

    /// Leading content of every rendering: full workspace and session names, one line each.
    static func contextPrefix(workspaceName: String?, sessionName: String) -> String {
        let workspace = displayName(workspaceName, fallback: "(unknown)")
        let session = displayName(sessionName, fallback: "(unnamed)")
        return "Workspace: \(workspace)\nSession: \(session)\n\n"
    }

    /// Splits off the longest prefix of `text` within `capacity` UTF-16 units. With `preferBreaks`,
    /// prefers to end after a newline, then after whitespace, within the window's second half;
    /// otherwise fills the capacity up to the last whole grapheme. A grapheme cluster wider than
    /// `capacity` (which no part could hold whole) fills the remaining space scalar by scalar.
    /// `head + rest` always equals `text` scalar for scalar, and `head` is nonempty whenever `text` is.
    static func splitPrefix(
        _ text: Substring,
        capacity: Int,
        preferBreaks: Bool = true
    ) -> (head: Substring, rest: Substring) {
        precondition(capacity >= 2, "capacity must hold any Unicode scalar")
        var used = 0
        var index = text.startIndex
        var afterNewline: String.Index?
        var afterWhitespace: String.Index?
        var oversizedCluster = false
        while index < text.endIndex {
            let next = text.index(after: index)
            let width = text.utf16.distance(from: index, to: next)
            guard used + width <= capacity else {
                oversizedCluster = width > capacity
                break
            }
            used += width
            if preferBreaks, used * 2 >= capacity {
                let character = text[index]
                if character.isNewline {
                    afterNewline = next
                } else if character.isWhitespace {
                    afterWhitespace = next
                }
            }
            index = next
        }
        if index == text.endIndex {
            return (text, text[text.endIndex...])
        }
        if oversizedCluster {
            // Split the oversized cluster between scalars to fill the rest of this part.
            var scalarEnd = index
            while scalarEnd < text.unicodeScalars.endIndex {
                let width = UTF16.width(text.unicodeScalars[scalarEnd])
                guard used + width <= capacity else { break }
                used += width
                scalarEnd = text.unicodeScalars.index(after: scalarEnd)
            }
            let head = String(text[..<index]) + String(text.unicodeScalars[index ..< scalarEnd])
            let rest = String(text.unicodeScalars[scalarEnd...])
            return (Substring(head), Substring(rest))
        }
        let cut = afterNewline ?? afterWhitespace ?? index
        return (text[..<cut], text[cut...])
    }

    // MARK: - Private

    private static func renderCompletion(
        body: String,
        header: (_ label: (Int, Int)?) -> String
    ) -> [TelegramAttentionMessagePart] {
        let single = header(nil)
        if single.utf16.count + body.utf16.count <= maximumUTF16Count {
            return [TelegramAttentionMessagePart(number: 1, count: 1, header: single, body: body)]
        }
        // Labels "(n/2)" and "(n/3)" have the same width.
        let capacity = maximumUTF16Count - header((maximumCompletionParts, maximumCompletionParts)).utf16.count
        // The whole body, at preferred breaks if they fit in three parts, else capacity-filling.
        if let bodies = partition(body, capacity: capacity, preferBreaks: true)
            ?? partition(body, capacity: capacity, preferBreaks: false)
        {
            return numberedParts(bodies, header: header)
        }
        // Truncate: keep the longest grapheme-safe prefix that fills all three parts.
        var bodies: [String] = []
        var rest = Substring(body)
        for _ in 1 ..< maximumCompletionParts {
            let split = splitPrefix(rest, capacity: capacity, preferBreaks: false)
            bodies.append(String(split.head))
            rest = split.rest
        }
        let kept = splitPrefix(rest, capacity: capacity - truncationMarker.utf16.count, preferBreaks: false).head
        bodies.append(String(kept) + truncationMarker)
        return numberedParts(bodies, header: header)
    }

    /// The exact partition of `body` into at most `maximumCompletionParts` parts, or nil if it needs more.
    private static func partition(_ body: String, capacity: Int, preferBreaks: Bool) -> [String]? {
        var bodies: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            guard bodies.count < maximumCompletionParts else { return nil }
            let split = splitPrefix(rest, capacity: capacity, preferBreaks: preferBreaks)
            bodies.append(String(split.head))
            rest = split.rest
        }
        return bodies
    }

    private static func renderQuestion(
        body: String,
        header: (_ label: (Int, Int)?) -> String
    ) -> [TelegramAttentionMessagePart] {
        let single = header(nil)
        if single.utf16.count + body.utf16.count <= maximumUTF16Count {
            return [TelegramAttentionMessagePart(number: 1, count: 1, header: single, body: body)]
        }
        // Reserve the widest label for the digit count, widening until the part count fits.
        var digits = 1
        while true {
            let widest = Int(pow(10, Double(digits))) - 1
            let capacity = maximumUTF16Count - header((widest, widest)).utf16.count
            var bodies: [String] = []
            var rest = Substring(body)
            while !rest.isEmpty {
                let split = splitPrefix(rest, capacity: capacity)
                bodies.append(String(split.head))
                rest = split.rest
            }
            if String(bodies.count).count <= digits {
                return numberedParts(bodies, header: header)
            }
            digits += 1
        }
    }

    private static func numberedParts(
        _ bodies: [String],
        header: (_ label: (Int, Int)?) -> String
    ) -> [TelegramAttentionMessagePart] {
        let count = bodies.count
        return bodies.enumerated().map { offset, body in
            TelegramAttentionMessagePart(
                number: offset + 1,
                count: count,
                header: header(count > 1 ? (offset + 1, count) : nil),
                body: body
            )
        }
    }

    private static func header(_ title: String, _ label: (Int, Int)?) -> String {
        let numbered = label.map { " (\($0.0)/\($0.1))" } ?? ""
        return "\(title)\(numbered)\n"
    }

    private static func completionBody(_ text: String?) -> String {
        guard let text else { return noFinalTextBody }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return emptyFinalTextBody
        }
        return text
    }

    /// Full name on one line: each newline grapheme becomes a space; nothing else changes.
    private static func displayName(_ name: String?, fallback: String) -> String {
        let flattened = (name ?? "").map { $0.isNewline ? " " : String($0) }.joined()
        guard !flattened.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        return flattened
    }
}
