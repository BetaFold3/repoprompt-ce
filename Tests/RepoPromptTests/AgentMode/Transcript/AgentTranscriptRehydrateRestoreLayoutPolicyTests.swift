@testable import RepoPromptApp
import XCTest

final class AgentTranscriptRehydrateRestoreLayoutPolicyTests: XCTestCase {
    private let tabID = UUID()

    func testNativeBottomWithCurrentSampleSkipsRedundantRestoreScroll() {
        XCTAssertTrue(canSkip(sampleKey: currentKey, distanceToBottom: 0))
        XCTAssertTrue(canSkip(sampleKey: currentKey, distanceToBottom: AgentTranscriptRehydrateRestoreLayoutPolicy.nativeInitialBottomTolerance))
    }

    func testNearButNotAtNativeBottomKeepsRestoreScroll() {
        let tolerance = AgentTranscriptRehydrateRestoreLayoutPolicy.nativeInitialBottomTolerance
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: tolerance + 0.01), "rows re-measured after first layout")
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 16), "bottomTarget resting distance")
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 24), "near-bottom threshold is not native bottom")
    }

    func testInvalidGeometryKeepsRestoreScroll() {
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: -1))
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: .nan))
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: .infinity))
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 0, viewportHeight: 0))
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 0, viewportHeight: .infinity))
    }

    func testMissingStaleOrForeignSampleKeepsRestoreScroll() {
        XCTAssertFalse(canSkip(sampleKey: nil, distanceToBottom: 0))
        XCTAssertFalse(canSkip(sampleKey: key(revision: 6), distanceToBottom: 0), "previous presentation revision")
        XCTAssertFalse(canSkip(sampleKey: key(token: 41), distanceToBottom: 0), "previous layout pass")
        XCTAssertFalse(canSkip(
            sampleKey: AgentTranscriptRehydrateRetryKey(tabID: UUID(), presentationRevision: 7, layoutPassToken: 42),
            distanceToBottom: 0
        ), "other tab")
    }

    func testInFlightScrollOrLegacyHostKeepsRestoreScroll() {
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 0, isProgrammaticScrollInFlight: true))
        XCTAssertFalse(canSkip(sampleKey: currentKey, distanceToBottom: 0, hasNativeInitialBottomAnchor: false))
    }

    private var currentKey: AgentTranscriptRehydrateRetryKey {
        key()
    }

    private func key(revision: Int = 7, token: UInt64 = 42) -> AgentTranscriptRehydrateRetryKey {
        AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: revision, layoutPassToken: token)
    }

    private func canSkip(
        sampleKey: AgentTranscriptRehydrateRetryKey?,
        distanceToBottom: CGFloat,
        viewportHeight: CGFloat = 300,
        hasNativeInitialBottomAnchor: Bool = true,
        isProgrammaticScrollInFlight: Bool = false
    ) -> Bool {
        AgentTranscriptRehydrateRestoreLayoutPolicy.canSkipLiveBottomRestoreScroll(
            hasNativeInitialBottomAnchor: hasNativeInitialBottomAnchor,
            isProgrammaticScrollInFlight: isProgrammaticScrollInFlight,
            currentLayoutSampleKey: sampleKey,
            tabID: tabID,
            presentationRevision: 7,
            layoutPassToken: 42,
            metrics: AgentTranscriptScrollMetrics(
                distanceToBottom: distanceToBottom,
                visibleMinY: 0,
                contentHeight: 2000,
                viewportHeight: viewportHeight
            )
        )
    }
}
