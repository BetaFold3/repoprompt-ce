import AppKit
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import SwiftUI
import XCTest

/// Hosts the actual `MarkdownTextView` as the final row of a transcript-shaped scroll view with the
/// production initial bottom anchor and scroll-geometry observer. The default scheduled path first
/// measures an unstyled placeholder and re-measures after its queued compile; an opted-in completed
/// reply must instead lay out its styled geometry on the first pass and keep it.
@MainActor
final class MarkdownFirstLayoutCompileTests: XCTestCase {
    private static let heightTolerance: CGFloat = 0.5
    private static let positionTolerance: CGFloat = 1

    // MARK: Hosted outcome

    func testOptedInCompletedReplyFirstLayoutUsesStyledGeometry() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        for (label, markdown) in [("growingReply", Fixture.agentReply), ("table", Fixture.table), ("shrinkingMixed", Fixture.mixed)] {
            let scheduled = FirstLayoutHost(text: markdown, prefersSynchronousFirstLayout: false)
            defer { scheduled.close() }
            let scheduledFirst = try scheduled.firstLayout()
            let republished = scheduled.waitForRowHeight(timeout: 3) { abs($0 - scheduledFirst.rowHeight) > Self.heightTolerance }
            let styled = try scheduled.drain()
            XCTAssertTrue(republished, "\(label): default scheduled path must still re-measure after its late compile")

            let optedIn = FirstLayoutHost(text: markdown, prefersSynchronousFirstLayout: true)
            defer { optedIn.close() }
            let first = try optedIn.firstLayout()
            XCTAssertEqual(first.rowHeight, styled.rowHeight, accuracy: Self.heightTolerance, "\(label): first layout must use styled geometry")
            XCTAssertEqual(first.offset, first.maxOffset, accuracy: Self.positionTolerance, "\(label): first layout starts at the latest content")

            let settled = try optedIn.drain()
            XCTAssertEqual(settled.rowHeight, first.rowHeight, accuracy: Self.heightTolerance, "\(label): no late Markdown-driven height change")
            XCTAssertEqual(settled.offset, settled.maxOffset, accuracy: Self.positionTolerance, "\(label): latest content stays in view")
        }
    }

    func testOptedInSameIdentityTextChangeRendersNewStyledText() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let expected = try Self.settledStyledHeight(for: Fixture.table)

        let host = FirstLayoutHost(text: Fixture.agentReply, prefersSynchronousFirstLayout: true)
        defer { host.close() }
        let initial = try host.drain()
        XCTAssertGreaterThan(abs(initial.rowHeight - expected), 1, "fixtures must differ in height")

        host.model.text = Fixture.table
        XCTAssertTrue(
            host.waitForRowHeight(timeout: 3) { abs($0 - expected) <= Self.heightTolerance },
            "a later text update on the same identity must render the new styled text"
        )
        XCTAssertEqual(try host.drain().rowHeight, expected, accuracy: Self.heightTolerance)
    }

    func testOptedInStreamingCompletionRendersFinalStyledText() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let segmentedPartial = Fixture.segmentedReply(paragraphs: 199)
        XCTAssertNotNil(
            MarkdownStreamingFreezeBoundaryResolver.resolveBoundary(in: segmentedPartial),
            "segmented fixture must use the segmented streaming renderer"
        )
        let variants: [(String, String, String)] = [
            ("coalesced", String(Fixture.agentReply.prefix(400)), Fixture.agentReply),
            ("segmented", segmentedPartial, Fixture.segmentedReply(paragraphs: 200))
        ]
        for (label, partial, final) in variants {
            let expected = try Self.settledStyledHeight(for: final)

            let host = FirstLayoutHost(text: partial, isStreaming: true, prefersSynchronousFirstLayout: true)
            defer { host.close() }
            _ = try host.drain()

            host.model.text = final
            host.model.isStreaming = false
            XCTAssertTrue(
                host.waitForRowHeight(timeout: 3) { abs($0 - expected) <= Self.heightTolerance },
                "\(label): completion must render the final styled text"
            )
            XCTAssertEqual(try host.drain().rowHeight, expected, accuracy: Self.heightTolerance, "\(label)")
        }
    }

    // MARK: Memo and policy

    func testMemoReusesOnlyTheExactFullSignature() {
        let memo = MarkdownFirstLayoutCompileMemo()
        var compileCount = 0
        let compile: (MarkdownRenderSignature) -> NSAttributedString = { signature in
            compileCount += 1
            return NSAttributedString(string: signature.text)
        }
        let base = Self.signature()

        let first = memo.resolve(base, compile: compile)
        XCTAssertTrue(memo.resolve(base, compile: compile) === first, "same signature returns the retained instance")
        XCTAssertEqual(compileCount, 1)

        let variants = [
            Self.signature(text: "Hellp"),
            Self.signature(fontSize: 15),
            Self.signature(forceTextColor: .red),
            Self.signature(useMonospaced: true),
            Self.signature(detectsMarkdownFilePaths: false),
            Self.signature(codeFontFaceIdentity: "Menlo-Regular")
        ]
        for variant in variants {
            // Retain the base first so each variant differs from the retained key in one field only.
            _ = memo.resolve(base, compile: compile)
            let before = compileCount
            _ = memo.resolve(variant, compile: compile)
            XCTAssertEqual(compileCount, before + 1, "a single-field signature change must recompile: \(variant)")
        }
    }

    func testConsumeAdoptsRetainedResultWithoutCompilingAndReleasesIt() {
        let memo = MarkdownFirstLayoutCompileMemo()
        var compileCount = 0
        let compile: (MarkdownRenderSignature) -> NSAttributedString = { signature in
            compileCount += 1
            return NSAttributedString(string: signature.text)
        }
        let laidOut = memo.resolve(Self.signature(), compile: compile)

        XCTAssertTrue(memo.consume(Self.signature(), compile: compile) === laidOut, "lifecycle adopts the laid-out instance")
        XCTAssertEqual(compileCount, 1, "adoption must not compile again")
        XCTAssertTrue(memo.isEmpty, "adoption releases the entry")

        _ = memo.consume(Self.signature(text: "Other"), compile: compile)
        XCTAssertEqual(compileCount, 2, "a superseded signature compiles the current one")
        XCTAssertTrue(memo.isEmpty)
    }

    func testFirstLayoutPolicyAppliesOnlyToOptedInImmediateFirstCompile() {
        XCTAssertTrue(MarkdownFirstLayoutCompilePolicy.compilesSynchronously(prefersSynchronousFirstLayout: true, cadence: .immediate, hasCompiledText: false))
        XCTAssertFalse(MarkdownFirstLayoutCompilePolicy.compilesSynchronously(prefersSynchronousFirstLayout: false, cadence: .immediate, hasCompiledText: false))
        XCTAssertFalse(MarkdownFirstLayoutCompilePolicy.compilesSynchronously(prefersSynchronousFirstLayout: true, cadence: .streamingCoalesced, hasCompiledText: false))
        XCTAssertFalse(MarkdownFirstLayoutCompilePolicy.compilesSynchronously(prefersSynchronousFirstLayout: true, cadence: .immediate, hasCompiledText: true))
    }

    func testMarkdownTextViewEqualityIncludesFirstLayoutPreference() {
        let scheduled = MarkdownTextView(text: "# Title")
        let optedIn = MarkdownTextView(text: "# Title", prefersSynchronousFirstLayout: true)
        XCTAssertNotEqual(scheduled, optedIn)
        XCTAssertEqual(optedIn, MarkdownTextView(text: "# Title", prefersSynchronousFirstLayout: true))
    }

    // MARK: Helpers

    /// Styled height of a fresh mount after its compile has published, independent of the opt-in.
    @available(macOS 15.0, *)
    private static func settledStyledHeight(for markdown: String) throws -> CGFloat {
        let host = FirstLayoutHost(text: markdown, prefersSynchronousFirstLayout: false)
        defer { host.close() }
        return try host.drain().rowHeight
    }

    private static func signature(
        text: String = "Hello",
        fontSize: CGFloat = 14,
        forceTextColor: Color? = nil,
        useMonospaced: Bool = false,
        detectsMarkdownFilePaths: Bool = true,
        codeFontFaceIdentity: String = "system"
    ) -> MarkdownRenderSignature {
        MarkdownRenderSignature(
            text: text,
            fontSize: fontSize,
            forceTextColor: forceTextColor,
            useMonospaced: useMonospaced,
            detectsMarkdownFilePaths: detectsMarkdownFilePaths,
            codeFontFaceIdentity: codeFontFaceIdentity
        )
    }
}

// MARK: - Fixtures

private enum Fixture {
    /// Inline code and bold prose that styles taller than its placeholder.
    static let agentReply = (1 ... 10).map { index in
        "**Point \(index):** the `AgentModeView.swift:\(index * 100)` path calls `requestScroll` and then `finishRehydrateRestoreIfSettled`, which keeps the state consistent.\n- detail one for \(index)\n- detail two with `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift` reference\n"
    }.joined(separator: "\n")

    static let table = "| Column A | Column B | Column C |\n|---|---|---|\n"
        + (1 ... 25).map { "| row \($0) value | another value \($0) | `code\($0)` |" }.joined(separator: "\n")

    /// Headings, lists, fenced code, and quotes; styles shorter than its placeholder.
    static let mixed = (1 ... 6).map { section in
        """
        ## Section \(section): implementation notes

        This paragraph explains **why** the change matters and references `SomeType.method()` in passing, with a [link](https://example.com/docs/\(section)) and enough prose to wrap across multiple lines.

        - First bullet with `inline code` and a short explanation
        - Second bullet that is a little longer so that it wraps onto a second line in the viewport
          - Nested bullet describing a detail
        1. Ordered step one
        2. Ordered step two

        ```swift
        func example\(section)(value: Int) -> Int {
            let doubled = value * 2
            return doubled + \(section)
        }
        ```

        > A quoted remark about section \(section).

        """
    }.joined(separator: "\n")

    /// Long enough (lines and characters) for the segmented streaming renderer.
    static func segmentedReply(paragraphs: Int) -> String {
        (1 ... paragraphs).map { "Paragraph \($0) with **bold** words and `code` spans that pad the line length." }
            .joined(separator: "\n\n")
    }
}

// MARK: - Host

private struct FirstLayoutSnapshot {
    let offset: CGFloat
    let maxOffset: CGFloat
    let rowHeight: CGFloat
}

private enum FirstLayoutHostError: Error {
    case missingScrollView
    case missingRowHeight
}

@MainActor
private final class FirstLayoutHostModel: ObservableObject {
    @Published var text: String
    @Published var isStreaming: Bool

    init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }
}

@MainActor
private final class FinalRowHeightProbe {
    var height: CGFloat?
}

private struct FinalRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

@available(macOS 15.0, *)
private struct FirstLayoutTranscript: View {
    @ObservedObject var model: FirstLayoutHostModel
    let prefersSynchronousFirstLayout: Bool
    let probe: FinalRowHeightProbe

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0 ..< 30, id: \.self) { index in
                        Text("Earlier row \(index)").frame(height: 40)
                    }
                    MarkdownTextView(
                        text: model.text,
                        isMarkdown: true,
                        allowInteraction: true,
                        detectsMarkdownFilePaths: true,
                        renderCadence: model.isStreaming ? .streamingCoalesced : .immediate,
                        prefersSynchronousFirstLayout: prefersSynchronousFirstLayout
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { Color.clear.preference(key: FinalRowHeightKey.self, value: $0.size.height) })
                    Color.clear.frame(height: 24)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .modifier(AgentTranscriptInitialBottomAnchor())
            // Production shape: the transcript observes scroll geometry.
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, _ in })
            .onPreferenceChange(FinalRowHeightKey.self) { probe.height = $0 }
        }
    }
}

@MainActor
private final class FirstLayoutHost {
    let model: FirstLayoutHostModel
    private let probe = FinalRowHeightProbe()
    private let window: NSWindow
    private let hostingView: NSView

    @available(macOS 15.0, *)
    init(text: String, isStreaming: Bool = false, prefersSynchronousFirstLayout: Bool) {
        let size = CGSize(width: 640, height: 500)
        model = FirstLayoutHostModel(text: text, isStreaming: isStreaming)
        let hostingView = NSHostingView(rootView: FirstLayoutTranscript(
            model: model,
            prefersSynchronousFirstLayout: prefersSynchronousFirstLayout,
            probe: probe
        ))
        hostingView.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        self.hostingView = hostingView
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// One synchronous layout pass with no run-loop turn, before any queued compile can publish.
    func firstLayout() throws -> FirstLayoutSnapshot {
        hostingView.layoutSubtreeIfNeeded()
        return try snapshot()
    }

    /// Runs several run-loop turns so queued compiles and lifecycle callbacks publish.
    func drain() throws -> FirstLayoutSnapshot {
        for _ in 0 ..< 20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }
        return try snapshot()
    }

    func waitForRowHeight(timeout: TimeInterval, until condition: (CGFloat) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            hostingView.layoutSubtreeIfNeeded()
            if let height = probe.height, condition(height) {
                return true
            }
        }
        return false
    }

    private func snapshot() throws -> FirstLayoutSnapshot {
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw FirstLayoutHostError.missingScrollView }
        guard let rowHeight = probe.height else { throw FirstLayoutHostError.missingRowHeight }
        let clip = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return FirstLayoutSnapshot(offset: clip.origin.y, maxOffset: max(0, documentHeight - clip.height), rowHeight: rowHeight)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
