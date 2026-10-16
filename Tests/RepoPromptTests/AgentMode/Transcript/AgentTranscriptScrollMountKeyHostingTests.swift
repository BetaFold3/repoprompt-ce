import AppKit
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import SwiftUI
import XCTest

/// Real `NSHostingView` regression for the single-pass transcript `ScrollView` identity.
///
/// The host mirrors the production transcript shape (`GeometryReader` > `ScrollViewReader` >
/// `ScrollView { rows }` keyed by `AgentTranscriptScrollMountKey`, the production initial bottom
/// anchor, `onScrollGeometryChange`, and `onChange(of: tabID)` / `onChange(of: restoreSignal)`
/// handlers). The handlers call the production `AgentTranscriptActivationRepaintRemountPolicy`
/// and latch helpers and bump the reset revision only for `requiresIdentityBump`, as
/// `AgentModeChatDetailView` does. The full `AgentModeView` needs the whole view model, so this is
/// a structural host. Each row hosts an AppKit leaf whose make/dismantle calls are counted.
@MainActor
final class AgentTranscriptScrollMountKeyHostingTests: XCTestCase {
    private static let positionTolerance: CGFloat = 1

    func testWarmSwitchBuildsDestinationRowsOnceInFreshScrollViewAtBottom() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = MountKeyHost(initial: .hydrated(MountKeyTab.a, revision: 3))
        defer { host.close() }
        host.settle()
        let sourceScrollView = try host.beginScrollViewObservation()

        host.recorder.reset()
        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .hydrated(MountKeyTab.b, revision: 9))
        let firstLayout = try host.layoutOnce()
        let firstLayoutScrollView = try host.scrollViewIdentity()
        XCTAssertNotEqual(firstLayoutScrollView, sourceScrollView, "the first layout must already belong to the fresh destination instance")
        XCTAssertEqual(host.installedProbeRowIDs(), MountKeyTab.b.sortedRowIDs, "the first layout must already host the destination rows")
        host.settle()

        XCTAssertEqual(try host.scrollViewIdentity(), firstLayoutScrollView, "no later instance may replace the first-layout one")
        XCTAssertEqual(host.recorder.count("rowBody", MountKeyTab.b), MountKeyTab.b.rowCount, "destination row bodies must be evaluated once")
        XCTAssertEqual(host.recorder.count("make", MountKeyTab.b), MountKeyTab.b.rowCount, "destination AppKit leaves must be created once")
        XCTAssertEqual(host.recorder.count("dismantle", MountKeyTab.b), 0, "no destination leaf may be discarded unused")
        XCTAssertEqual(host.recorder.count("dismantle", MountKeyTab.a), MountKeyTab.a.rowCount)
        XCTAssertEqual(host.recorder.count("tabChange"), 1)
        XCTAssertEqual(host.recorder.count("bump"), 0, "tab entry must not bump the reset revision")
        XCTAssertEqual(host.engine.remountCount, 1, "tab entry keeps its activation repaint bookkeeping")

        XCTAssertNotEqual(try host.scrollViewIdentity(), sourceScrollView, "tab entry must mount a fresh native scroll view")
        XCTAssertEqual(host.distinctScrollViewsSinceReset, 2, "exactly one fresh native scroll view replaces the source one")
        try assertAtNativeBottom(firstLayout, "first layout")
        try assertAtNativeBottom(host.clipPosition(), "settled layout")
        XCTAssertTrue(host.canSkipLiveBottomRestoreScroll(tabID: MountKeyTab.b.id, revision: 9), "the fresh instance must record a current-pass native-bottom sample")
        XCTAssertGreaterThan(host.engine.scrollMetrics.viewportHeight, 0, "scroll metrics must describe the fresh instance after the handlers' reset")
        XCTAssertLessThanOrEqual(host.engine.scrollMetrics.distanceToBottom, 1)
    }

    func testColdLoadingToHydratedBuildsRowsOnceInFreshScrollViewAtBottom() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = MountKeyHost(initial: .hydrated(MountKeyTab.a, revision: 3))
        defer { host.close() }
        host.settle()
        let sourceScrollView = try host.scrollViewIdentity()

        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .loading(MountKeyTab.b, revision: 1))
        host.settle()
        let loadingScrollView = try host.beginScrollViewObservation()
        XCTAssertNotEqual(loadingScrollView, sourceScrollView, "tab entry into a loading presentation must mount a fresh instance")

        host.recorder.reset()
        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .hydrated(MountKeyTab.b, revision: 2))
        let firstLayout = try host.layoutOnce()
        let firstLayoutScrollView = try host.scrollViewIdentity()
        XCTAssertNotEqual(firstLayoutScrollView, loadingScrollView, "the first hydrated layout must already belong to the fresh instance")
        XCTAssertNotEqual(firstLayoutScrollView, sourceScrollView)
        XCTAssertEqual(host.installedProbeRowIDs(), MountKeyTab.b.sortedRowIDs, "the first hydrated layout must already host the rows")
        host.settle()

        XCTAssertEqual(try host.scrollViewIdentity(), firstLayoutScrollView, "no later instance may replace the first-layout one")
        XCTAssertEqual(host.recorder.count("rowBody", MountKeyTab.b), MountKeyTab.b.rowCount, "hydrated row bodies must be evaluated once")
        XCTAssertEqual(host.recorder.count("make", MountKeyTab.b), MountKeyTab.b.rowCount, "hydrated AppKit leaves must be created once")
        XCTAssertEqual(host.recorder.count("dismantle", MountKeyTab.b), 0, "no hydrated leaf may be discarded unused")
        XCTAssertEqual(host.recorder.count("bump"), 0, "the first hydration must not bump the reset revision")
        XCTAssertEqual(host.engine.remountCount, 1, "the first hydration keeps its activation repaint bookkeeping")

        XCTAssertNotEqual(try host.scrollViewIdentity(), loadingScrollView, "the first hydration must mount a fresh native scroll view")
        XCTAssertEqual(host.distinctScrollViewsSinceReset, 2)
        try assertAtNativeBottom(firstLayout, "first hydrated layout")
        try assertAtNativeBottom(host.clipPosition(), "settled hydrated layout")
        XCTAssertTrue(host.canSkipLiveBottomRestoreScroll(tabID: MountKeyTab.b.id, revision: 2), "the fresh instance must record a current-pass native-bottom sample")
        XCTAssertGreaterThan(host.engine.scrollMetrics.viewportHeight, 0, "scroll metrics must describe the fresh instance after the handlers' reset")
        XCTAssertLessThanOrEqual(host.engine.scrollMetrics.distanceToBottom, 1)
    }

    /// An animated activation publication must not run a removal transition that keeps the
    /// source instance alongside the destination one: the remount transaction disables it.
    func testAnimatedSwitchNeverHostsTwoScrollViews() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = MountKeyHost(initial: .hydrated(MountKeyTab.a, revision: 3))
        defer { host.close() }
        host.settle()
        let sourceScrollView = try host.scrollViewIdentity()

        withAnimation(.default) {
            host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .hydrated(MountKeyTab.b, revision: 9))
        }
        _ = try host.layoutOnce()

        XCTAssertEqual(host.scrollViewCount(), 1, "the animated switch must host exactly one native scroll view")
        XCTAssertNotEqual(try host.scrollViewIdentity(), sourceScrollView)
        XCTAssertEqual(host.installedProbeRowIDs(), MountKeyTab.b.sortedRowIDs)
    }

    /// Outside an activation, a binding transition on the shown tab (unhydrated, then hydrated
    /// again with the same rows) kept the mounted instance before the mount key existed, and must
    /// still keep it: the hydration component is latched per activation.
    func testSameTabBindingTransitionAfterRestoreKeepsMountedInstanceAndRows() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Initial bottom anchor requires macOS 15") }
        let host = MountKeyHost(initial: .hydrated(MountKeyTab.a, revision: 3))
        defer { host.close() }
        host.settle()
        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .hydrated(MountKeyTab.b, revision: 9))
        host.settle()
        host.engine.completeRestore()
        let mounted = try host.beginScrollViewObservation()

        host.recorder.reset()
        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .loading(MountKeyTab.b, revision: 10, keepingRows: true))
        host.settle()
        host.model.publish(currentTabID: MountKeyTab.b.id, presentation: .hydrated(MountKeyTab.b, revision: 11))
        host.settle()

        XCTAssertEqual(try host.scrollViewIdentity(), mounted, "a same-tab binding transition must keep the mounted scroll view")
        XCTAssertEqual(host.distinctScrollViewsSinceReset, 1)
        XCTAssertEqual(host.recorder.count("make", MountKeyTab.b), 0)
        XCTAssertEqual(host.recorder.count("dismantle", MountKeyTab.b), 0)
        XCTAssertEqual(host.recorder.count("bump"), 0)
    }

    private func assertAtNativeBottom(
        _ position: MountKeyClipPosition,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertGreaterThan(position.maxOffset, 300, "\(label): fixture must overflow the viewport", file: file, line: line)
        XCTAssertEqual(position.offset, position.maxOffset, accuracy: Self.positionTolerance, "\(label): must show the latest rows", file: file, line: line)
    }
}

// MARK: - Fixture

private struct MountKeyTab {
    static let a = MountKeyTab(name: "A", rowCount: 12, id: UUID())
    static let b = MountKeyTab(name: "B", rowCount: 19, id: UUID())

    let name: String
    let rowCount: Int
    let id: UUID

    var sortedRowIDs: [String] {
        rows.map(\.id).sorted()
    }

    var rows: [MountKeyRow] {
        (0 ..< rowCount).map { MountKeyRow(id: "\(name)-\($0)", text: "\(name) row \($0)") }
    }
}

private struct MountKeyRow: Identifiable, Equatable {
    let id: String
    let text: String
}

private struct MountKeyPresentation: Equatable {
    var tabID: UUID?
    var bindingsHydrated: Bool
    var revision: Int
    var rows: [MountKeyRow]

    static func hydrated(_ tab: MountKeyTab, revision: Int) -> Self {
        .init(tabID: tab.id, bindingsHydrated: true, revision: revision, rows: tab.rows)
    }

    static func loading(_ tab: MountKeyTab, revision: Int, keepingRows: Bool = false) -> Self {
        .init(tabID: tab.id, bindingsHydrated: false, revision: revision, rows: keepingRows ? tab.rows : [])
    }

    var restoreSignal: AgentTranscriptRestoreSignal {
        .init(tabID: tabID, bindingsHydrated: bindingsHydrated, presentationRevision: revision)
    }
}

private struct MountKeyHostState: Equatable {
    var currentTabID: UUID?
    var presentation: MountKeyPresentation
}

@MainActor
private final class MountKeyHostModel: ObservableObject {
    @Published private(set) var state: MountKeyHostState

    init(initial: MountKeyPresentation) {
        state = MountKeyHostState(currentTabID: initial.tabID, presentation: initial)
    }

    /// One publication carrying the current tab and its presentation (batched activation).
    func publish(currentTabID: UUID?, presentation: MountKeyPresentation) {
        state = MountKeyHostState(currentTabID: currentTabID, presentation: presentation)
    }
}

@MainActor
private final class MountKeyRecorder {
    private var events: [(kind: String, detail: String)] = []

    func reset() {
        events.removeAll()
    }

    func note(_ kind: String, _ detail: String = "") {
        events.append((kind, detail))
    }

    func count(_ kind: String, _ tab: MountKeyTab? = nil) -> Int {
        let prefix = tab.map { "\($0.name)-" }
        return events.count { event in
            event.kind == kind && (prefix.map { event.detail.hasPrefix($0) } ?? true)
        }
    }
}

/// Non-reactive restore bookkeeping, like `AgentTranscriptScrollEngine`.
@MainActor
private final class MountKeyEngine {
    var phase: AgentTranscriptRehydrateRestorePhase = .idle
    var lastRemountKey: AgentTranscriptRehydrateRetryKey?
    var remountCount = 0
    var layoutPassToken: UInt64 = 0
    var sampleKey: AgentTranscriptRehydrateRetryKey?
    var sampleMetrics = AgentTranscriptScrollMetrics()
    var scrollMetrics = AgentTranscriptScrollMetrics()
    var lastMountedScrollGeometry: AgentTranscriptMountedScrollGeometry?
    var replayCount = 0

    func completeRestore() {
        phase = .idle
        layoutPassToken &+= 1
        sampleKey = nil
    }
}

// MARK: - Views

private final class MountKeyProbeNSView: NSView {
    var rowID = ""
    weak var recorder: MountKeyRecorder?
}

private struct MountKeyProbeLeaf: NSViewRepresentable {
    let rowID: String
    let recorder: MountKeyRecorder

    func makeNSView(context _: Context) -> MountKeyProbeNSView {
        recorder.note("make", rowID)
        let view = MountKeyProbeNSView()
        view.rowID = rowID
        view.recorder = recorder
        return view
    }

    func updateNSView(_: MountKeyProbeNSView, context _: Context) {}

    static func dismantleNSView(_ nsView: MountKeyProbeNSView, coordinator _: ()) {
        nsView.recorder?.note("dismantle", nsView.rowID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: MountKeyProbeNSView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 24)
    }
}

private struct MountKeyRowView: View {
    let row: MountKeyRow
    let recorder: MountKeyRecorder

    var body: some View {
        let _ = recorder.note("rowBody", row.id)
        VStack(alignment: .leading, spacing: 4) {
            Text(row.text)
            MountKeyProbeLeaf(rowID: row.id, recorder: recorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 15.0, *)
private struct MountKeyShapedTranscript: View {
    private typealias Policy = AgentTranscriptActivationRepaintRemountPolicy

    @ObservedObject var model: MountKeyHostModel
    let recorder: MountKeyRecorder
    let engine: MountKeyEngine
    @State private var resetRevision = 0
    @State private var hydratedMountTabID: UUID?

    private var restoreSignal: AgentTranscriptRestoreSignal {
        model.state.presentation.restoreSignal
    }

    private var mountKey: AgentTranscriptScrollMountKey {
        AgentTranscriptScrollMountKey(
            restoreSignal: restoreSignal,
            hydratedMountTabID: hydratedMountTabID,
            resetRevision: resetRevision
        )
    }

    var body: some View {
        let state = model.state
        GeometryReader { geometry in
            ScrollViewReader { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.presentation.rows) { row in
                            MountKeyRowView(row: row, recorder: recorder)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .id(mountKey)
                .transaction(value: mountKey) { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .modifier(AgentTranscriptInitialBottomAnchor())
                .onScrollGeometryChange(for: AgentTranscriptScrollMetrics.self, of: { geometry in
                    AgentTranscriptScrollMetrics(
                        distanceToBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                        visibleMinY: geometry.visibleRect.minY,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.visibleRect.height
                    )
                }, action: { _, metrics in
                    engine.lastMountedScrollGeometry = AgentTranscriptMountedScrollGeometry(mountKey: mountKey, metrics: metrics)
                    engine.scrollMetrics = metrics
                    recordLayoutSample(metrics)
                })
            }
        }
        .onChange(of: state.currentTabID) { _, newTabID in
            recorder.note("tabChange")
            engine.scrollMetrics = AgentTranscriptScrollMetrics() // the tab handler's metrics reset
            armRestore(for: newTabID)
            replayMountedScrollGeometry()
        }
        .onChange(of: restoreSignal) { oldSignal, newSignal in
            let isMountKeyRemount = applyRemountDecision(oldSignal: oldSignal, newSignal: newSignal) == false
            hydratedMountTabID = AgentTranscriptScrollMountKey.hydratedMountTabID(
                afterObserving: newSignal,
                currentTabID: model.state.currentTabID,
                previous: hydratedMountTabID
            )
            advanceRestore()
            if isMountKeyRemount {
                replayMountedScrollGeometry()
            }
        }
    }

    /// Mirrors `armRehydrateRestore` (live-bottom target, activation-start decision).
    private func armRestore(for tabID: UUID?) {
        engine.lastRemountKey = nil
        engine.remountCount = 0
        hydratedMountTabID = AgentTranscriptScrollMountKey.hydratedMountTabID(atActivationOf: tabID, restoreSignal: restoreSignal)
        engine.layoutPassToken &+= 1
        engine.sampleKey = nil
        guard let tabID else {
            engine.phase = .idle
            return
        }
        engine.phase = .awaitingHydration(tabID: tabID, target: .liveBottom)
        if let decision = Policy.activationStartDecision(
            signal: restoreSignal,
            currentTabID: model.state.currentTabID,
            rehydratePhase: engine.phase,
            lastRemountKey: engine.lastRemountKey,
            remountCount: engine.remountCount,
            layoutPassToken: engine.layoutPassToken
        ) {
            apply(decision)
        }
        advanceRestore()
    }

    /// Returns the decision's `requiresIdentityBump`, or `nil` without a decision.
    private func applyRemountDecision(oldSignal: AgentTranscriptRestoreSignal, newSignal: AgentTranscriptRestoreSignal) -> Bool? {
        guard let decision = Policy.decision(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: model.state.currentTabID,
            rehydratePhase: engine.phase,
            lastRemountKey: engine.lastRemountKey,
            remountCount: engine.remountCount,
            layoutPassToken: engine.layoutPassToken,
            hydratedMountTabID: hydratedMountTabID
        ) else { return nil }
        return apply(decision)
    }

    /// Mirrors `remountTranscriptForActivationRepaint`.
    @discardableResult
    private func apply(_ decision: Policy.Decision) -> Bool {
        engine.layoutPassToken &+= 1
        engine.lastRemountKey = AgentTranscriptRehydrateRetryKey(
            tabID: decision.key.tabID,
            presentationRevision: decision.key.presentationRevision,
            layoutPassToken: engine.layoutPassToken
        )
        engine.remountCount += 1
        engine.sampleKey = nil
        switch engine.phase {
        case let .awaitingLayout(tabID, _, target), let .driving(tabID, _, target):
            engine.phase = .awaitingHydration(tabID: tabID, target: target)
        case .idle, .awaitingHydration:
            break
        }
        guard decision.requiresIdentityBump else { return false }
        recorder.note("bump")
        resetRevision &+= 1
        return true
    }

    /// Mirrors `replayMountedScrollGeometryForRestore`.
    private func replayMountedScrollGeometry() {
        guard let metrics = AgentTranscriptMountedScrollGeometry.replayableMetrics(
            engine.lastMountedScrollGeometry,
            currentMountKey: mountKey
        ) else { return }
        engine.replayCount += 1
        engine.scrollMetrics = metrics
        recordLayoutSample(metrics)
    }

    /// Mirrors the `awaitingHydration` -> `awaitingLayout` step of `advanceRehydrateRestoreIfNeeded`.
    private func advanceRestore() {
        guard case let .awaitingHydration(tabID, target) = engine.phase,
              tabID == model.state.currentTabID,
              restoreSignal.tabID == tabID,
              restoreSignal.bindingsHydrated
        else { return }
        let currentKey = AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: restoreSignal.presentationRevision,
            layoutPassToken: engine.layoutPassToken
        )
        if engine.sampleKey != currentKey { engine.sampleKey = nil }
        engine.phase = .awaitingLayout(tabID: tabID, presentationRevision: restoreSignal.presentationRevision, target: target)
    }

    /// Mirrors `recordRehydrateLayoutSampleIfNeeded`.
    private func recordLayoutSample(_ metrics: AgentTranscriptScrollMetrics) {
        guard engine.phase.isActive,
              let tabID = model.state.currentTabID,
              engine.phase.tabID == tabID
        else { return }
        guard AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics) else {
            engine.sampleKey = nil
            return
        }
        engine.sampleKey = AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: restoreSignal.presentationRevision,
            layoutPassToken: engine.layoutPassToken
        )
        engine.sampleMetrics = metrics
    }
}

// MARK: - Host

private struct MountKeyClipPosition {
    let offset: CGFloat
    let maxOffset: CGFloat
}

private enum MountKeyHostError: Error {
    case missingScrollView
}

@MainActor
private final class MountKeyHost {
    let model: MountKeyHostModel
    let recorder = MountKeyRecorder()
    let engine = MountKeyEngine()
    private let window: NSWindow
    private let hostingView: NSView
    private var seenScrollViews = Set<ObjectIdentifier>()

    @available(macOS 15.0, *)
    init(initial: MountKeyPresentation) {
        model = MountKeyHostModel(initial: initial)
        let size = CGSize(width: 420, height: 300)
        let hostingView = NSHostingView(rootView: MountKeyShapedTranscript(model: model, recorder: recorder, engine: engine))
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

    var distinctScrollViewsSinceReset: Int {
        seenScrollViews.count
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// Starts a native scroll view observation window at the current instance and returns it.
    func beginScrollViewObservation() throws -> ObjectIdentifier {
        let identity = try scrollViewIdentity()
        seenScrollViews = [identity]
        return identity
    }

    func settle() {
        for _ in 0 ..< 6 {
            hostingView.layoutSubtreeIfNeeded()
            noteScrollView()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            noteScrollView()
        }
        hostingView.layoutSubtreeIfNeeded()
        noteScrollView()
    }

    /// One synchronous layout pass with no run-loop turn: the instance's first layout.
    func layoutOnce() throws -> MountKeyClipPosition {
        hostingView.layoutSubtreeIfNeeded()
        noteScrollView()
        return try clipPosition()
    }

    func scrollViewIdentity() throws -> ObjectIdentifier {
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw MountKeyHostError.missingScrollView }
        return ObjectIdentifier(scrollView)
    }

    func clipPosition() throws -> MountKeyClipPosition {
        guard let scrollView = Self.firstScrollView(in: hostingView) else { throw MountKeyHostError.missingScrollView }
        let clipBounds = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return MountKeyClipPosition(offset: clipBounds.origin.y, maxOffset: max(0, documentHeight - clipBounds.height))
    }

    func canSkipLiveBottomRestoreScroll(tabID: UUID, revision: Int) -> Bool {
        AgentTranscriptRehydrateRestoreLayoutPolicy.canSkipLiveBottomRestoreScroll(
            hasNativeInitialBottomAnchor: true,
            isProgrammaticScrollInFlight: false,
            currentLayoutSampleKey: engine.sampleKey,
            tabID: tabID,
            presentationRevision: revision,
            layoutPassToken: engine.layoutPassToken,
            metrics: engine.sampleMetrics
        )
    }

    /// Every native scroll view in the hosting hierarchy, including any kept by a transition.
    func scrollViewCount() -> Int {
        Self.allViews(in: hostingView).count { $0 is NSScrollView }
    }

    /// Probe row IDs installed in the current scroll view's document, sorted (duplicates kept).
    func installedProbeRowIDs() -> [String] {
        guard let documentView = Self.firstScrollView(in: hostingView)?.documentView else { return [] }
        return Self.allViews(in: documentView).compactMap { ($0 as? MountKeyProbeNSView)?.rowID }.sorted()
    }

    private static func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func noteScrollView() {
        guard let scrollView = Self.firstScrollView(in: hostingView) else { return }
        seenScrollViews.insert(ObjectIdentifier(scrollView))
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
