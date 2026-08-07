import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class SnippetPaletteHelperTests: XCTestCase {
    // MARK: - Filtering

    func testFilteringRanksTitleMatchesAboveContentAndKeepsLibraryOrderForEmptyQuery() {
        let titlePrefix = makeItem(title: "duel oracles plan", content: "irrelevant")
        let titleWordPrefix = makeItem(title: "run the duel", content: "irrelevant")
        let titleSubstring = makeItem(title: "scheduel notes", content: "irrelevant")
        let titleSubsequence = makeItem(title: "dry-run universal export", content: "irrelevant")
        let contentSubstring = makeItem(title: "oracle advice", content: "run a dual duel of oracles")
        let unrelated = makeItem(title: "zebra", content: "xyz")
        let library = [unrelated, contentSubstring, titleSubsequence, titleSubstring, titleWordPrefix, titlePrefix]

        let filtered = SnippetPaletteHelper.filteredItems(library, query: "due")

        XCTAssertEqual(
            filtered.map(\.title),
            [
                "duel oracles plan",
                "run the duel",
                "scheduel notes",
                "dry-run universal export",
                "oracle advice"
            ]
        )

        // Empty and whitespace-only queries keep library order and drop nothing.
        XCTAssertEqual(SnippetPaletteHelper.filteredItems(library, query: ""), library)
        XCTAssertEqual(SnippetPaletteHelper.filteredItems(library, query: "   "), library)

        // Ties within the same rank keep library order.
        let tieA = makeItem(title: "duel A", content: "")
        let tieB = makeItem(title: "duel B", content: "")
        XCTAssertEqual(
            SnippetPaletteHelper.filteredItems([tieB, tieA], query: "due").map(\.title),
            ["duel B", "duel A"]
        )

        // Matching is case-insensitive.
        XCTAssertEqual(
            SnippetPaletteHelper.filteredItems([titlePrefix], query: "DUE").map(\.title),
            ["duel oracles plan"]
        )
    }

    func testSubtitlePreviewUsesFirstLineAndTruncates() {
        XCTAssertEqual(
            SnippetPaletteHelper.subtitlePreview(for: "first line\nsecond line"),
            "first line"
        )
        // Leading empty lines are skipped, matching the pre-optimization split behavior.
        XCTAssertEqual(
            SnippetPaletteHelper.subtitlePreview(for: "\n\nlater line\nrest"),
            "later line"
        )
        let long = String(repeating: "a", count: 120)
        let preview = SnippetPaletteHelper.subtitlePreview(for: long, maximumLength: 90)
        XCTAssertEqual(preview.count, 91)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - Commit

    func testCommitReplacesQueryRangeWithSnippetContentAndEndsSession() {
        let snippet = makeItem(title: "duel oracles", content: "Run your discoveries through dual oracles.")
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "Hello due"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(
            matchedItems: [snippet],
            highlightedIndex: 0,
            anchorLocation: 6
        )

        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Hello Run your discoveries through dual oracles.")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: ("Hello " as NSString).length + (snippet.content as NSString).length, length: 0)
        )
        XCTAssertFalse(helper.isSessionActive)
    }

    func testCommitViaClickedRowInsertsClickedSnippet() {
        let first = makeItem(title: "first", content: "FIRST")
        let second = makeItem(title: "second", content: "SECOND")
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "x "
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(
            matchedItems: [first, second],
            highlightedIndex: 0,
            anchorLocation: 2
        )

        helper.clickSuggestionForTesting(at: 1)
        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertTab(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "x SECOND")
    }

    func testEscapeDismissesAndReturnWithoutMatchesIsConsumedWithoutSend() {
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(matchedItems: [], highlightedIndex: 0, anchorLocation: 3)

        // Return with zero matches must be consumed (no fall-through to send) and close the palette.
        let returnHandled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )
        XCTAssertTrue(returnHandled)
        XCTAssertFalse(helper.isSessionActive)
        XCTAssertEqual(textView.string, "abc")

        // Escape closes an active session.
        helper.setSessionStateForTesting(matchedItems: [], highlightedIndex: 0, anchorLocation: 3)
        let escapeHandled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.cancelOperation(_:)),
            enabled: true
        )
        XCTAssertTrue(escapeHandled)
        XCTAssertFalse(helper.isSessionActive)

        // With no session, commands pass through untouched.
        let idleHandled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )
        XCTAssertFalse(idleHandled)
    }

    func testCommitRegistersUndoSoUndoRestoresTypedQuery() {
        let snippet = makeItem(title: "duel oracles", content: "CONTENT")
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.allowsUndo = true
        let delegate = UndoProvidingTextViewDelegate()
        textView.delegate = delegate
        textView.string = "Hello due"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(
            matchedItems: [snippet],
            highlightedIndex: 0,
            anchorLocation: 6
        )

        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Hello CONTENT")
        XCTAssertTrue(delegate.textViewUndoManager.canUndo)
        delegate.textViewUndoManager.undo()
        XCTAssertEqual(textView.string, "Hello due")
    }

    func testCommitRefiltersAgainstLiveQueryAndDropsStaleHighlight() {
        // A highlighted item that no longer matches the live query (stale
        // results raced ahead of the text) must never be inserted.
        let stale = makeItem(title: "zebra", content: "ZEBRA")
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "Hello due"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(
            matchedItems: [stale],
            highlightedIndex: 0,
            anchorLocation: 6
        )

        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertNewline(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Hello due")
        XCTAssertFalse(helper.isSessionActive)
    }

    func testInsertLineBreakCommitsHighlightedSnippetLikeReturn() {
        // Some keyboards deliver Shift-Return as insertLineBreak; while the
        // palette is up it must commit rather than leak a newline into the query.
        let snippet = makeItem(title: "duel oracles", content: "CONTENT")
        let textView = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "Hello due"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        let helper = SnippetPaletteHelper()
        helper.setSessionStateForTesting(
            matchedItems: [snippet],
            highlightedIndex: 0,
            anchorLocation: 6
        )

        let handled = helper.handleCommandIfNeeded(
            textView: textView,
            commandSelector: #selector(NSResponder.insertLineBreak(_:)),
            enabled: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.string, "Hello CONTENT")
        XCTAssertFalse(helper.isSessionActive)
    }

    // MARK: - Session lifecycle

    func testBeginSessionAnchorsAtCaretAndTypedQueryFiltersSuggestions() async throws {
        let duel = makeItem(title: "duel oracles", content: "content A")
        let review = makeItem(title: "review checklist", content: "content B")
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { owner.orderOut(nil) }
        let textView = ImageAwareTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 80))
        textView.string = "outer prompt "
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        owner.contentView = textView
        let helper = SnippetPaletteHelper()
        helper.configure(enabled: true, itemsProvider: { [duel, review] })

        helper.beginSession(in: textView)
        XCTAssertTrue(helper.isSessionActive)
        try await waitUntil { helper.matchedItemsForTesting == [duel, review] }

        // Type a query after the anchor and refresh: matches narrow to the duel snippet.
        textView.string = "outer prompt due"
        textView.setSelectedRange(NSRange(location: 16, length: 0))
        helper.scheduleRefresh(for: textView, immediate: true, enabled: true, isActive: true)
        try await waitUntil { helper.matchedItemsForTesting == [duel] }

        // A newline in the query range invalidates the session.
        textView.string = "outer prompt due\nx"
        textView.setSelectedRange(NSRange(location: 18, length: 0))
        helper.scheduleRefresh(for: textView, immediate: true, enabled: true, isActive: true)
        try await waitUntil { !helper.isSessionActive }
    }

    // MARK: - Helpers

    private func makeItem(title: String, content: String) -> SnippetPaletteItem {
        SnippetPaletteItem(id: UUID(), title: title, content: content)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// Mirrors the composer coordinator, which vends a private UndoManager to the
/// text view via `undoManager(for:)`.
private final class UndoProvidingTextViewDelegate: NSObject, NSTextViewDelegate {
    let textViewUndoManager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? {
        textViewUndoManager
    }
}
