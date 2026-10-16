import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class TelegramAttentionMessageRendererTests: XCTestCase {
    private typealias Renderer = TelegramAttentionMessageRenderer
    private let limit = TelegramSendMessageClient.maximumTextUTF16Count

    // MARK: - Completion

    func testShortCompletionIsOnePlainPartWithWorkspaceSessionAndText() {
        let parts = Renderer.render(completion("Done. *Not bold* <b>raw</b> [x](y)", workspace: "WS", session: "Fix bug"))
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(
            parts[0].text,
            "RepoPrompt: turn finished\nWorkspace: WS\nSession: Fix bug\n\nDone. *Not bold* <b>raw</b> [x](y)"
        )
        XCTAssertEqual(parts[0].number, 1)
        XCTAssertEqual(parts[0].count, 1)
    }

    func testMissingAndEmptyFinalTextAreStatedTruthfully() {
        XCTAssertEqual(Renderer.render(completion(nil)).map(\.body), [context + Renderer.noFinalTextBody])
        XCTAssertEqual(Renderer.render(completion("")).map(\.body), [context + Renderer.emptyFinalTextBody])
        XCTAssertEqual(Renderer.render(completion(" \n\t")).map(\.body), [context + Renderer.emptyFinalTextBody])
    }

    func testMissingWorkspaceAndMultilineNamesStayVisible() {
        let parts = Renderer.render(completion("x", workspace: nil, session: "line1\nline2"))
        XCTAssertEqual(parts.map(\.text), ["RepoPrompt: turn finished\nWorkspace: (unknown)\nSession: line1 line2\n\nx"])
        XCTAssertEqual(
            Renderer.render(completion("x", workspace: " ", session: "")).map(\.body),
            ["Workspace: (unknown)\nSession: (unnamed)\n\nx"]
        )
    }

    func testLongNamesAreKeptInFullAndSplitLikeContent() {
        let workspace = String(repeating: "w", count: 5000)
        let session = String(repeating: "s", count: 5000)
        let expected = "Workspace: \(workspace)\nSession: \(session)\n\nx"

        let completionParts = Renderer.render(completion("x", workspace: workspace, session: session))
        XCTAssertEqual(completionParts.count, 3)
        assertWithinLimit(completionParts)
        assertNoMarker(completionParts)
        XCTAssertEqual(completionParts.map(\.body).joined(), expected)

        let questionParts = Renderer.render(questionEvent(["Q?"], workspace: workspace, session: session))
        assertWithinLimit(questionParts)
        XCTAssertEqual(
            questionParts.map(\.body).joined(),
            "Workspace: \(workspace)\nSession: \(session)\n\nQ?"
        )
    }

    func testCompletionAtSingleLimitStaysOnePartAndOneMoreSplitsWithoutMarker() {
        let overhead = "RepoPrompt: turn finished\n".utf16.count + context.utf16.count
        let fits = String(repeating: "a", count: limit - overhead)
        let fitsParts = Renderer.render(completion(fits))
        XCTAssertEqual(fitsParts.count, 1)
        XCTAssertEqual(fitsParts[0].text.utf16.count, limit)

        let over = fits + "b"
        let overParts = Renderer.render(completion(over))
        XCTAssertEqual(overParts.count, 2)
        XCTAssertEqual(overParts.map(\.body).joined(), context + over)
        XCTAssertEqual(overParts.map(\.header), [header(completionPart: 1, of: 2), header(completionPart: 2, of: 2)])
        assertNoMarker(overParts)
        assertWithinLimit(overParts)
    }

    func testCompletionFillingExactlyThreePartsHasNoMarker() {
        let capacity = labeledCapacity()
        let body = String(repeating: "a", count: 3 * capacity - context.utf16.count)
        let parts = Renderer.render(completion(body))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.map(\.body).joined(), context + body)
        XCTAssertEqual(parts.map(\.text.utf16.count), [limit, limit, limit])
        assertNoMarker(parts)
    }

    func testCompletionOneUnitOverThreePartsIsTruncatedWithVisibleMarker() {
        let capacity = labeledCapacity()
        let body = String(repeating: "a", count: 3 * capacity - context.utf16.count + 1)
        let parts = Renderer.render(completion(body))
        XCTAssertEqual(parts.count, 3)
        assertWithinLimit(parts)
        XCTAssertTrue(parts[2].body.hasSuffix(Renderer.truncationMarker))
        XCTAssertFalse(parts[0].body.contains(Renderer.truncationMarker))
        XCTAssertFalse(parts[1].body.contains(Renderer.truncationMarker))
        let kept = parts[0].body + parts[1].body + String(parts[2].body.dropLast(Renderer.truncationMarker.count))
        XCTAssertTrue((context + body).hasPrefix(kept))
        XCTAssertEqual(kept.utf16.count, 3 * capacity - Renderer.truncationMarker.utf16.count)
        XCTAssertEqual(parts[2].header, header(completionPart: 3, of: 3))
    }

    /// Four 2,200-character paragraphs (~8.8k units) fit in three parts: preferring paragraph
    /// breaks must never force truncation of the final paragraph (OracleA S3-01).
    func testParagraphedCompletionThatFitsThreePartsRoundTripsExactlyWithoutMarker() {
        let paragraphs = ["a", "b", "c", "d"].map { String(repeating: $0, count: 2200) }
        let body = paragraphs.joined(separator: "\n\n")
        XCTAssertLessThanOrEqual((context + body).utf16.count, 3 * labeledCapacity())

        let parts = Renderer.render(completion(body))
        XCTAssertEqual(parts.count, 3)
        assertWithinLimit(parts)
        assertNoMarker(parts)
        XCTAssertEqual(parts.map(\.body).joined(), context + body)
        XCTAssertEqual(parts.map(\.header), (1 ... 3).map { header(completionPart: $0, of: 3) })
    }

    /// A paragraphed completion longer than three parts keeps the longest prefix that fits, not a
    /// prefix shortened back to a paragraph break (OracleA S3-01).
    func testParagraphedCompletionOverThreePartsKeepsTheFullCapacityPrefix() {
        let paragraphs = ["a", "b", "c", "d", "e", "f"].map { String(repeating: $0, count: 2200) }
        let body = paragraphs.joined(separator: "\n\n")
        let capacity = labeledCapacity()
        XCTAssertGreaterThan((context + body).utf16.count, 3 * capacity)

        let parts = Renderer.render(completion(body))
        XCTAssertEqual(parts.count, 3)
        assertWithinLimit(parts)
        XCTAssertTrue(parts[2].body.hasSuffix(Renderer.truncationMarker))
        XCTAssertFalse(parts[0].body.contains(Renderer.truncationMarker))
        XCTAssertFalse(parts[1].body.contains(Renderer.truncationMarker))
        let kept = parts[0].body + parts[1].body + String(parts[2].body.dropLast(Renderer.truncationMarker.count))
        XCTAssertTrue((context + body).hasPrefix(kept))
        XCTAssertEqual(kept.utf16.count, 3 * capacity - Renderer.truncationMarker.utf16.count)
    }

    func testHugeCompletionIsCappedAtThreeParts() {
        let parts = Renderer.render(completion(String(repeating: "word ", count: 200_000)))
        XCTAssertEqual(parts.count, 3)
        assertWithinLimit(parts)
        XCTAssertTrue(parts[2].text.hasSuffix(Renderer.truncationMarker))
    }

    func testCompletionSplitsKeepEveryEmojiGraphemeIntact() {
        let family = "👨‍👩‍👧‍👦" // 7 scalars, 11 UTF-16 units, one grapheme
        XCTAssertEqual(family.utf16.count, 11)
        let body = String(repeating: family + "🇻🇳" + "é", count: 400) // > 1 part, < 3 parts
        let parts = Renderer.render(completion(body))
        XCTAssertEqual(parts.count, 2)
        assertWithinLimit(parts)
        assertNoMarker(parts)
        XCTAssertEqual(Array(parts.map(\.body).joined().unicodeScalars), Array((context + body).unicodeScalars))
        // Splits fall between graphemes: the parts' graphemes are exactly the content's graphemes.
        XCTAssertEqual(parts.flatMap { Array($0.body) }, Array(context + body))
    }

    func testOversizedSingleGraphemeIsSplitBetweenScalarsWithoutLoss() {
        let cluster = "e" + String(repeating: "\u{0301}", count: 9000)
        XCTAssertEqual(cluster.count, 1)
        let parts = Renderer.render(completion(cluster))
        XCTAssertEqual(parts.count, 3)
        assertWithinLimit(parts)
        assertNoMarker(parts)
        XCTAssertEqual(Array(parts.map(\.body).joined().unicodeScalars), Array((context + cluster).unicodeScalars))
        // The oversized cluster fills each part rather than ending the first part early.
        XCTAssertEqual(parts[0].text.utf16.count, limit)

        let question = Renderer.render(questionEvent(["Pick one", cluster, "Done"]))
        assertWithinLimit(question)
        XCTAssertEqual(
            Array(question.map(\.body).joined().unicodeScalars),
            Array((context + ["Pick one", cluster, "Done"].joined(separator: "\n")).unicodeScalars)
        )
    }

    // MARK: - Question

    func testShortQuestionIsOnePartWithAllLines() {
        let lines = ["Question 1: Ship it?", "  Options:", "  - Yes — deploy now", "  - No", "Allows multiple: no"]
        XCTAssertEqual(Renderer.render(questionEvent(lines))[0].header, "RepoPrompt: question waiting\n")
        let parts = Renderer.render(questionEvent(lines, workspace: "WS", session: "Root"))
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(
            parts[0].text,
            "RepoPrompt: question waiting\nWorkspace: WS\nSession: Root\n\n" + lines.joined(separator: "\n")
        )
    }

    func testLongQuestionRoundTripsExactlyAcrossNumberedParts() {
        var lines: [String] = []
        for index in 1 ... 600 {
            lines.append("Question \(index): Which option — ünïcödé 🧑‍💻 \(String(repeating: "q", count: index % 37))?")
            lines.append("  - Option A: description with combining e\u{0301} and flag 🇯🇵")
            lines.append("  - Option B: *literal* <i>markup</i>")
        }
        lines.append("Allows multiple: yes; custom answer: allowed")
        let body = context + lines.joined(separator: "\n")
        let parts = Renderer.render(questionEvent(lines))

        XCTAssertGreaterThan(parts.count, 9, "exercise two-digit labels")
        assertWithinLimit(parts)
        assertNoMarker(parts)
        XCTAssertEqual(Array(parts.map(\.body).joined().unicodeScalars), Array(body.unicodeScalars))
        for (offset, part) in parts.enumerated() {
            XCTAssertEqual(part.number, offset + 1)
            XCTAssertEqual(part.count, parts.count)
            XCTAssertEqual(part.text, part.header + part.body)
            XCTAssertEqual(part.header, "RepoPrompt: question waiting (\(offset + 1)/\(parts.count))\n")
        }
        XCTAssertTrue(parts[0].body.hasPrefix(context))
        // Line-oriented content prefers to break after a newline.
        XCTAssertTrue(parts[0].body.hasSuffix("\n"))
    }

    func testQuestionNeedingHundredsOfPartsWidensLabelsAndLosesNothing() {
        let body = String(repeating: "x", count: 420_000)
        let parts = Renderer.render(questionEvent([body]))
        XCTAssertGreaterThanOrEqual(parts.count, 100)
        assertWithinLimit(parts)
        XCTAssertEqual(parts.map(\.body).joined(), context + body)
        XCTAssertEqual(parts[99].header, "RepoPrompt: question waiting (100/\(parts.count))\n")
    }

    func testQuestionAtSingleLimitStaysOnePart() {
        let overhead = "RepoPrompt: question waiting\n".utf16.count + context.utf16.count
        let line = String(repeating: "z", count: limit - overhead)
        XCTAssertEqual(Renderer.render(questionEvent([line])).count, 1)
        XCTAssertEqual(Renderer.render(questionEvent([line + "z"])).count, 2)
    }

    // MARK: - splitPrefix

    func testSplitPrefixPartitionsMixedUnicodeExactlyForEveryCapacity() {
        let text = "ab 👨‍👩‍👧‍👦 c\u{0301}\u{0302}\n🇻🇳 " + "e" + String(repeating: "\u{0301}", count: 40) + " end"
        for preferBreaks in [true, false] {
            for capacity in 2 ... 60 {
                var rest = Substring(text)
                var heads: [Substring] = []
                while !rest.isEmpty {
                    let split = Renderer.splitPrefix(rest, capacity: capacity, preferBreaks: preferBreaks)
                    XCTAssertFalse(split.head.isEmpty, "capacity \(capacity) preferBreaks \(preferBreaks)")
                    XCTAssertLessThanOrEqual(split.head.utf16.count, capacity, "capacity \(capacity) preferBreaks \(preferBreaks)")
                    heads.append(split.head)
                    rest = split.rest
                }
                XCTAssertEqual(
                    Array(heads.map(String.init).joined().unicodeScalars),
                    Array(text.unicodeScalars),
                    "capacity \(capacity) preferBreaks \(preferBreaks)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func completion(_ text: String?, workspace: String? = "WS", session: String = "S") -> AttentionNotificationEvent {
        AttentionNotificationEvent(
            key: .turnCompleted(sessionID: UUID(), attemptID: UUID()),
            workspaceName: workspace,
            sessionName: session,
            content: .turnCompleted(finalAssistantText: text)
        )
    }

    private func questionEvent(_ lines: [String], workspace: String? = "WS", session: String = "S") -> AttentionNotificationEvent {
        AttentionNotificationEvent(
            key: .question(sessionID: UUID(), interactionID: UUID()),
            workspaceName: workspace,
            sessionName: session,
            content: .question(contentLines: lines)
        )
    }

    /// Content prefix for the default "WS"/"S" names.
    private let context = "Workspace: WS\nSession: S\n\n"

    private func header(completionPart number: Int, of count: Int) -> String {
        "RepoPrompt: turn finished (\(number)/\(count))\n"
    }

    private func labeledCapacity() -> Int {
        limit - header(completionPart: 3, of: 3).utf16.count
    }

    private func assertWithinLimit(
        _ parts: [TelegramAttentionMessagePart],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for part in parts {
            XCTAssertFalse(part.text.isEmpty, file: file, line: line)
            XCTAssertLessThanOrEqual(part.text.utf16.count, limit, "part \(part.number)", file: file, line: line)
        }
    }

    private func assertNoMarker(_ parts: [TelegramAttentionMessagePart], file: StaticString = #filePath, line: UInt = #line) {
        for part in parts {
            XCTAssertFalse(part.text.contains("[truncated"), "part \(part.number)", file: file, line: line)
        }
    }
}
