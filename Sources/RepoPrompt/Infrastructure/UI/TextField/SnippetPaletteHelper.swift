import AppKit
import Foundation

/// One insertable snippet sourced from the user's saved prompt library.
struct SnippetPaletteItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let content: String
}

/// Shortcut-opened palette that fuzzy-searches the saved prompt library and
/// inserts the selected snippet at the caret of the Agent composer.
///
/// Unlike `FileTagMentionHelper`/`SlashSkillMentionHelper` there is no typed
/// trigger character: a session is opened explicitly (keyboard shortcut) and
/// anchored at the current caret. Characters typed after the anchor form the
/// filter query; committing replaces the query range with the snippet content.
@MainActor
final class SnippetPaletteHelper {
    private let overlay: MentionOverlayController = {
        let overlay = MentionOverlayController()
        overlay.placement = .above
        overlay.suggestedWidth = 420
        overlay.visibleRowLimit = 8
        return overlay
    }()

    private var itemsProvider: (() -> [SnippetPaletteItem])?
    private var matchedItems: [SnippetPaletteItem] = []
    private var suggestions: [MentionSuggestion] = []
    private var highlightedIndex = 0
    private var anchorLocation: Int?
    private var overlayIsVisible = false
    private static let maximumQueryLength = 64

    var isSessionActive: Bool {
        anchorLocation != nil
    }

    init() {
        overlay.onRowClicked = { [weak self] _, index in
            self?.selectSuggestion(at: index)
        }
    }

    func configure(enabled: Bool, itemsProvider: (() -> [SnippetPaletteItem])?) {
        guard enabled, itemsProvider != nil else {
            self.itemsProvider = nil
            dismiss()
            return
        }
        self.itemsProvider = itemsProvider
    }

    /// Open the palette anchored at the caret. Repeated opens are idempotent.
    func openSession(in textView: NSTextView) {
        guard !isSessionActive else { return }
        guard itemsProvider != nil else { return }
        guard !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound else { return }
        let caret = NSMaxRange(selection)
        guard caret <= (textView.string as NSString).length else { return }
        if selection.length > 0 {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        anchorLocation = caret
        scheduleRefresh(for: textView, immediate: true, enabled: true, isActive: true)
    }

    /// Open the palette anchored at the caret, or close it when already open.
    func toggleSession(in textView: NSTextView) {
        if isSessionActive {
            dismiss()
        } else {
            openSession(in: textView)
        }
    }

    /// Refreshes synchronously: filtering is in-memory and microsecond-cheap,
    /// and keeping the visible list in lockstep with the text closes the window
    /// in which Return could commit against results the user is no longer
    /// seeing. `immediate` is accepted for call-shape symmetry with the
    /// debounced sibling helpers and intentionally ignored.
    func scheduleRefresh(
        for textView: NSTextView,
        immediate _: Bool,
        enabled: Bool,
        isActive: Bool
    ) {
        guard isSessionActive, isActive, enabled else { return }
        refresh(in: textView)
    }

    func handleCommandIfNeeded(
        textView: NSTextView,
        commandSelector: Selector,
        enabled: Bool
    ) -> Bool {
        guard enabled, isSessionActive else { return false }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex - 1 + suggestions.count) % suggestions.count
            overlay.moveHighlight(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !suggestions.isEmpty else { return false }
            highlightedIndex = (highlightedIndex + 1) % suggestions.count
            overlay.moveHighlight(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertLineBreak(_:))
        {
            guard !suggestions.isEmpty else {
                // The palette was opened intentionally; never let a bare
                // Return fall through to "send message" while it is up.
                dismiss()
                return true
            }
            commitHighlighted(in: textView)
            return true
        }
        return false
    }

    func dismiss() {
        overlay.hide()
        overlayIsVisible = false
        suggestions.removeAll()
        matchedItems.removeAll()
        highlightedIndex = 0
        anchorLocation = nil
    }

    // MARK: - Private

    private func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        highlightedIndex = index
    }

    private func refresh(in textView: NSTextView) {
        guard let anchorLocation, let itemsProvider else {
            dismiss()
            return
        }
        guard !textView.hasMarkedText() else {
            dismiss()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else {
            dismiss()
            return
        }
        let caret = selection.location
        let fullText = textView.string as NSString
        guard caret != NSNotFound,
              caret >= anchorLocation,
              anchorLocation <= fullText.length,
              caret <= fullText.length
        else {
            dismiss()
            return
        }

        let query = fullText.substring(
            with: NSRange(location: anchorLocation, length: caret - anchorLocation)
        )
        guard query.count <= Self.maximumQueryLength,
              !query.contains(where: \.isNewline)
        else {
            dismiss()
            return
        }

        matchedItems = Self.filteredItems(itemsProvider(), query: query)
        suggestions = matchedItems.map { item in
            MentionSuggestion(
                displayName: item.title,
                relativePath: item.id.uuidString,
                kind: .snippet,
                subtitle: Self.subtitlePreview(for: item.content)
            )
        }
        highlightedIndex = 0

        guard let ownerWindow = textView.window else {
            dismiss()
            return
        }
        let caretRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        if overlayIsVisible {
            overlay.update(items: suggestions, highlighted: highlightedIndex)
            overlay.repositionRoot(to: caretRect)
        } else {
            overlay.show(at: caretRect, owner: ownerWindow, items: suggestions)
            overlay.update(items: suggestions, highlighted: highlightedIndex)
            overlayIsVisible = true
        }
    }

    private func commitHighlighted(in textView: NSTextView) {
        guard let anchorLocation, let itemsProvider,
              matchedItems.indices.contains(highlightedIndex)
        else {
            dismiss()
            return
        }
        let selection = textView.selectedRange()
        let fullText = textView.string as NSString
        let caret = selection.location
        guard selection.length == 0,
              caret != NSNotFound,
              caret >= anchorLocation,
              caret <= fullText.length
        else {
            dismiss()
            return
        }

        let query = fullText.substring(
            with: NSRange(location: anchorLocation, length: caret - anchorLocation)
        )
        guard query.count <= Self.maximumQueryLength,
              !query.contains(where: \.isNewline)
        else {
            dismiss()
            return
        }
        // Never trust cached results at commit time: re-rank against the live
        // document and library, and drop the commit if the highlighted snippet
        // no longer matches what the user actually typed.
        let highlighted = matchedItems[highlightedIndex]
        guard Self.filteredItems(itemsProvider(), query: query).contains(highlighted) else {
            dismiss()
            return
        }

        let content = highlighted.content
        let replacementRange = NSRange(location: anchorLocation, length: caret - anchorLocation)
        dismiss()
        // Route the mutation through the undo-aware text view protocol so the
        // insertion registers as a single undoable step; a bare textStorage
        // write would leave ⌘Z replaying stale typing ranges over the new text.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: replacementRange, replacementString: content) else {
            return
        }
        textView.textStorage?.replaceCharacters(in: replacementRange, with: content)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        let insertionPoint = replacementRange.location + (content as NSString).length
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.scrollRangeToVisible(NSRange(location: insertionPoint, length: 0))
    }

    // MARK: - Filtering (pure, testable)

    /// Rank snippets for a query. Empty/whitespace queries keep library order.
    /// Ranking: title prefix > title word prefix > title substring >
    /// title subsequence > content substring. Ties keep library order.
    static func filteredItems(
        _ items: [SnippetPaletteItem],
        query: String
    ) -> [SnippetPaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }

        var scored: [(score: Int, index: Int, item: SnippetPaletteItem)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let title = item.title.lowercased()
            let score: Int
            if title.hasPrefix(needle) {
                score = 500
            } else if titleHasWordPrefix(title, needle: needle) {
                score = 400
            } else if title.contains(needle) {
                score = 300
            } else if isSubsequence(needle, of: title) {
                score = 200
            } else if item.content.lowercased().contains(needle) {
                score = 100
            } else {
                continue
            }
            scored.append((score, index, item))
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    static func subtitlePreview(for content: String, maximumLength: Int = 90) -> String {
        // Scan only as far as the first non-empty line: this runs per visible
        // row on every refresh and snippet bodies can be arbitrarily large.
        var searchStart = content.startIndex
        while searchStart < content.endIndex {
            let lineEnd = content[searchStart...].firstIndex(where: \.isNewline) ?? content.endIndex
            let line = content[searchStart ..< lineEnd]
            if !line.isEmpty {
                let firstLine = line.trimmingCharacters(in: .whitespaces)
                if let cutoff = firstLine.index(
                    firstLine.startIndex,
                    offsetBy: maximumLength,
                    limitedBy: firstLine.endIndex
                ), cutoff < firstLine.endIndex {
                    return String(firstLine[..<cutoff]) + "…"
                }
                return firstLine
            }
            guard lineEnd < content.endIndex else { break }
            searchStart = content.index(after: lineEnd)
        }
        return ""
    }

    private static func titleHasWordPrefix(_ title: String, needle: String) -> Bool {
        title
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .contains { $0.hasPrefix(needle) }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var needleIterator = needle.makeIterator()
        var current = needleIterator.next()
        for character in haystack {
            guard let target = current else { return true }
            if character == target {
                current = needleIterator.next()
            }
        }
        return current == nil
    }

    #if DEBUG
        var suggestionsForTesting: [MentionSuggestion] {
            suggestions
        }

        var matchedItemsForTesting: [SnippetPaletteItem] {
            matchedItems
        }

        var anchorLocationForTesting: Int? {
            anchorLocation
        }

        func setSessionStateForTesting(
            matchedItems: [SnippetPaletteItem],
            highlightedIndex: Int,
            anchorLocation: Int
        ) {
            itemsProvider = { matchedItems }
            self.matchedItems = matchedItems
            suggestions = matchedItems.map { item in
                MentionSuggestion(
                    displayName: item.title,
                    relativePath: item.id.uuidString,
                    kind: .snippet,
                    subtitle: nil
                )
            }
            self.highlightedIndex = highlightedIndex
            self.anchorLocation = anchorLocation
        }

        func clickSuggestionForTesting(at index: Int) {
            overlay.onRowClicked?(0, index)
        }
    #endif
}
