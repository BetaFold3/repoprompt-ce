import AppKit
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import SwiftUI
import XCTest

/// Hosts a transcript-shaped SwiftUI `ScrollView` in an unshown offscreen window and reads the
/// backing `NSScrollView` clip position, so the native initial placement is observed on real
/// AppKit geometry rather than asserted from configuration.
@MainActor
final class AgentTranscriptInitialBottomAnchorHostingTests: XCTestCase {
    private static let viewportSize = CGSize(width: 420, height: 300)
    private static let rowHeight: CGFloat = 40
    private static let positionTolerance: CGFloat = 1

    func testTallTranscriptFirstLayoutStartsAtBottom() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 60)
        defer { host.close() }

        // One synchronous layout pass with no run-loop turn: the position SwiftUI produces for the
        // instance's first layout, before any asynchronous scroll correction could run.
        let firstLayout = try host.firstLayoutPosition()
        XCTAssertGreaterThan(firstLayout.maxOffset, Self.viewportSize.height, "fixture must overflow the viewport")
        XCTAssertEqual(firstLayout.offset, firstLayout.maxOffset, accuracy: Self.positionTolerance, "first layout must show the latest rows, not the top")

        let settled = try host.settledPosition()
        XCTAssertEqual(settled.offset, settled.maxOffset, accuracy: Self.positionTolerance, "settled layout must stay at the latest rows")
    }

    func testShortTranscriptFittingViewportStaysAtTopWithoutOffset() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 2)
        defer { host.close() }

        let position = try host.settledPosition()
        XCTAssertEqual(position.maxOffset, 0, accuracy: Self.positionTolerance, "short fixture must fit the viewport")
        XCTAssertEqual(position.offset, 0, accuracy: Self.positionTolerance)
        XCTAssertLessThan(position.firstRowMinY, Self.rowHeight, "short content must stay top-aligned, not bottom-aligned")
    }

    func testRemountedInstanceStartsAtBottomAfterManualScrollTowardHistory() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 60)
        defer { host.close() }

        _ = try host.settledPosition()
        try host.scrollManually(toOffset: 120)
        XCTAssertEqual(try host.settledPosition().offset, 120, accuracy: Self.positionTolerance)

        host.model.rowCount = 80
        host.model.remountRevision += 1
        let remounted = try host.settledPosition()
        XCTAssertEqual(remounted.offset, remounted.maxOffset, accuracy: Self.positionTolerance, "a remounted instance must start at its latest rows")
    }

    func testContentGrowthAfterManualScrollKeepsDetachedReadingPosition() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 60)
        defer { host.close() }

        let initial = try host.settledPosition()
        let readingOffset: CGFloat = 200
        XCTAssertLessThan(readingOffset, initial.maxOffset - Self.viewportSize.height)
        try host.scrollManually(toOffset: readingOffset)

        host.model.rowCount = 90
        let grown = try host.settledPosition()
        XCTAssertGreaterThan(grown.maxOffset, initial.maxOffset + 20 * Self.rowHeight, "growth must be laid out")
        XCTAssertEqual(grown.offset, readingOffset, accuracy: Self.positionTolerance, "content growth must not re-pin a detached reader")
    }

    /// Row content such as Markdown code blocks and tool output hosts its own `ScrollView`s.
    /// The transcript's initial bottom anchor must not open those at their bottom or middle.
    func testNestedRowScrollViewsKeepTheirOwnLeadingTopInitialOffset() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 60, includesNestedScrollViews: true)
        defer { host.close() }

        let outer = try host.settledPosition()
        XCTAssertEqual(outer.offset, outer.maxOffset, accuracy: Self.positionTolerance)

        let nested = try host.nestedScrollViewClips()
        XCTAssertGreaterThan(nested.horizontal.maxOffset, 100, "horizontal fixture must overflow")
        XCTAssertEqual(nested.horizontal.offset, 0, accuracy: Self.positionTolerance, "nested horizontal scroll view must open at its leading edge")
        XCTAssertGreaterThan(nested.vertical.maxOffset, 100, "vertical fixture must overflow")
        XCTAssertEqual(nested.vertical.offset, 0, accuracy: Self.positionTolerance, "nested vertical scroll view must open at its top")
    }

    /// Following growth while pinned belongs to the transcript's pinned maintenance, not to a
    /// native `.sizeChanges` anchor, so a mounted instance keeps its offset when content grows.
    func testGrowthAtNativeBottomDoesNotFollowNatively() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 60)
        defer { host.close() }

        let initial = try host.settledPosition()
        XCTAssertEqual(initial.offset, initial.maxOffset, accuracy: Self.positionTolerance)

        host.model.rowCount = 90
        let grown = try host.settledPosition()
        XCTAssertGreaterThan(grown.maxOffset, initial.maxOffset + 20 * Self.rowHeight, "growth must be laid out")
        XCTAssertEqual(grown.offset, initial.offset, accuracy: Self.positionTolerance, "only the initial offset is anchored")
    }

    func testShortContentWithoutViewportMinimumIsNotBottomAligned() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = TranscriptHost(rowCount: 2, fillsViewport: false)
        defer { host.close() }

        let position = try host.settledPosition()
        XCTAssertEqual(position.offset, 0, accuracy: Self.positionTolerance)
        XCTAssertLessThan(position.firstRowMinY, Self.rowHeight, "short content must not be aligned to the viewport bottom")
    }
}

// MARK: - Host

@MainActor
private final class TranscriptHostModel: ObservableObject {
    @Published var rowCount: Int
    @Published var remountRevision = 0

    init(rowCount: Int) {
        self.rowCount = rowCount
    }
}

@available(macOS 15.0, *)
private struct TranscriptShapedScrollView: View {
    @ObservedObject var model: TranscriptHostModel
    let rowHeight: CGFloat
    let includesNestedScrollViews: Bool
    let fillsViewport: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 1)
                    ForEach(0 ..< model.rowCount, id: \.self) { index in
                        Text("Row \(index)")
                            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                            .background(GeometryReader { rowGeometry in
                                Color.clear.preference(
                                    key: FirstRowMinYPreferenceKey.self,
                                    value: index == 0 ? rowGeometry.frame(in: .named(TranscriptHost.coordinateSpaceName)).minY : nil
                                )
                            })
                    }
                    if includesNestedScrollViews {
                        ScrollView(.horizontal) {
                            Text(String(repeating: "let wideCodeLine = value ", count: 60))
                                .fixedSize()
                        }
                        .frame(height: rowHeight)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(0 ..< 30, id: \.self) { line in
                                    Text("Output line \(line)").frame(height: 20)
                                }
                            }
                        }
                        .frame(height: 80)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding()
                .frame(
                    maxWidth: .infinity,
                    minHeight: fillsViewport ? geometry.size.height : nil,
                    alignment: .topLeading
                )
            }
            .id(model.remountRevision)
            .coordinateSpace(name: TranscriptHost.coordinateSpaceName)
            .modifier(AgentTranscriptInitialBottomAnchor())
            .onPreferenceChange(FirstRowMinYPreferenceKey.self) { value in
                TranscriptHost.lastFirstRowMinY = value
            }
        }
    }
}

private struct FirstRowMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct TranscriptScrollPosition {
    let offset: CGFloat
    let maxOffset: CGFloat
    let firstRowMinY: CGFloat
}

private enum TranscriptHostError: Error {
    case missingScrollView
    case missingFirstRowGeometry
}

@MainActor
private final class TranscriptHost {
    static let coordinateSpaceName = "AgentTranscriptInitialBottomAnchorHost"
    static var lastFirstRowMinY: CGFloat?

    let model: TranscriptHostModel
    private let window: NSWindow
    private let hostingView: NSView

    @available(macOS 15.0, *)
    init(rowCount: Int, includesNestedScrollViews: Bool = false, fillsViewport: Bool = true) {
        Self.lastFirstRowMinY = nil
        model = TranscriptHostModel(rowCount: rowCount)
        let hostingView = NSHostingView(rootView: TranscriptShapedScrollView(
            model: model,
            rowHeight: 40,
            includesNestedScrollViews: includesNestedScrollViews,
            fillsViewport: fillsViewport
        ))
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: 420, height: 300))
        window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 420, height: 300),
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

    func firstLayoutPosition() throws -> (offset: CGFloat, maxOffset: CGFloat) {
        hostingView.layoutSubtreeIfNeeded()
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw TranscriptHostError.missingScrollView }
        return Self.clipPosition(of: scrollView)
    }

    func settledPosition() throws -> TranscriptScrollPosition {
        settle()
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw TranscriptHostError.missingScrollView }
        guard let firstRowMinY = Self.lastFirstRowMinY else { throw TranscriptHostError.missingFirstRowGeometry }
        let position = Self.clipPosition(of: scrollView)
        return TranscriptScrollPosition(offset: position.offset, maxOffset: position.maxOffset, firstRowMinY: firstRowMinY)
    }

    /// Nested scroll views are told apart from the outer transcript by their overflow axis.
    func nestedScrollViewClips() throws -> (
        horizontal: (offset: CGFloat, maxOffset: CGFloat),
        vertical: (offset: CGFloat, maxOffset: CGFloat)
    ) {
        settle()
        guard let outer = Self.firstScrollView(in: hostingView) else { throw TranscriptHostError.missingScrollView }
        let nested = Self.allScrollViews(in: hostingView).filter { $0 !== outer }
        guard let horizontal = nested.first(where: { scrollView in
            (scrollView.documentView?.frame.width ?? 0) > scrollView.contentView.bounds.width + 1
        }),
            let vertical = nested.first(where: { scrollView in
                scrollView !== horizontal
                    && (scrollView.documentView?.frame.height ?? 0) > scrollView.contentView.bounds.height + 1
            })
        else {
            throw TranscriptHostError.missingScrollView
        }
        let horizontalClip = horizontal.contentView.bounds
        return (
            (horizontalClip.origin.x, max(0, (horizontal.documentView?.frame.width ?? 0) - horizontalClip.width)),
            Self.clipPosition(of: vertical)
        )
    }

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { result.append(scrollView) }
        for subview in view.subviews {
            result.append(contentsOf: allScrollViews(in: subview))
        }
        return result
    }

    private static func clipPosition(of scrollView: NSScrollView) -> (offset: CGFloat, maxOffset: CGFloat) {
        let clipBounds = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return (clipBounds.origin.y, max(0, documentHeight - clipBounds.height))
    }

    func scrollManually(toOffset offset: CGFloat) throws {
        settle()
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw TranscriptHostError.missingScrollView }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
    }

    private func settle() {
        for _ in 0 ..< 6 {
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        hostingView.layoutSubtreeIfNeeded()
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
