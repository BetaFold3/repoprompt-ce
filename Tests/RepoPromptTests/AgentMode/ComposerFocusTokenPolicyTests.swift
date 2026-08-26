import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ComposerFocusTokenPolicyTests: XCTestCase {
    func testActionTable() {
        let token = UUID()

        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: nil,
                lastAppliedToken: nil,
                hasWindow: false,
                hasAttachedSheet: false
            ),
            .clearPending
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: token,
                hasWindow: true,
                hasAttachedSheet: false
            ),
            .none
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: nil,
                hasWindow: false,
                hasAttachedSheet: false
            ),
            .waitForWindow
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: nil,
                hasWindow: true,
                hasAttachedSheet: true
            ),
            .drop
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: nil,
                hasWindow: true,
                hasAttachedSheet: false
            ),
            .attempt
        )
    }

    func testSeededTokenNeverAttempts() {
        let token = UUID()
        let seededState = ComposerFocusTokenPolicy.seededState(for: token)

        XCTAssertEqual(seededState.lastAppliedToken, token)
        XCTAssertNil(seededState.pendingToken)
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: seededState.lastAppliedToken,
                hasWindow: true,
                hasAttachedSheet: false
            ),
            .none
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: token,
                lastAppliedToken: seededState.lastAppliedToken,
                pendingToken: seededState.pendingToken
            )
        )
    }

    func testStaleScheduledWorkIsRejectedWhenCurrentTokenChanges() {
        let scheduledToken = UUID()

        XCTAssertTrue(
            ComposerFocusTokenPolicy.scheduledTokenIsCurrent(
                scheduledToken,
                currentToken: scheduledToken
            )
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.scheduledTokenIsCurrent(
                scheduledToken,
                currentToken: UUID()
            )
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.scheduledTokenIsCurrent(
                scheduledToken,
                currentToken: nil
            )
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: nil,
                lastAppliedToken: nil,
                pendingToken: nil
            )
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: nil,
                lastAppliedToken: scheduledToken,
                pendingToken: nil
            )
        )
        XCTAssertFalse(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: scheduledToken,
                lastAppliedToken: scheduledToken,
                pendingToken: nil
            )
        )
        XCTAssertTrue(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: scheduledToken,
                lastAppliedToken: nil,
                pendingToken: nil
            )
        )
        XCTAssertTrue(
            ComposerFocusTokenPolicy.shouldSchedule(
                token: scheduledToken,
                lastAppliedToken: scheduledToken,
                pendingToken: scheduledToken
            )
        )
    }

    func testDropMarksTokenAppliedAndClearsPending() {
        let token = UUID()
        let lastAppliedToken = UUID()
        let priorPendingToken = UUID()
        let currentState = ComposerFocusTokenPolicy.State(
            lastAppliedToken: lastAppliedToken,
            pendingToken: priorPendingToken
        )

        XCTAssertEqual(
            ComposerFocusTokenPolicy.state(
                after: .clearPending,
                token: nil,
                currentState: currentState
            ),
            ComposerFocusTokenPolicy.State(
                lastAppliedToken: lastAppliedToken,
                pendingToken: nil
            )
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.state(
                after: .none,
                token: token,
                currentState: currentState
            ),
            currentState
        )
        XCTAssertEqual(
            ComposerFocusTokenPolicy.state(
                after: .waitForWindow,
                token: token,
                currentState: currentState
            ),
            ComposerFocusTokenPolicy.State(
                lastAppliedToken: lastAppliedToken,
                pendingToken: token
            )
        )

        let droppedState = ComposerFocusTokenPolicy.state(
            after: .drop,
            token: token,
            currentState: currentState
        )
        let attemptedState = ComposerFocusTokenPolicy.state(
            after: .attempt,
            token: token,
            currentState: currentState
        )

        XCTAssertEqual(droppedState.lastAppliedToken, token)
        XCTAssertNil(droppedState.pendingToken)
        XCTAssertEqual(attemptedState, droppedState)
        XCTAssertEqual(
            ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: droppedState.lastAppliedToken,
                hasWindow: true,
                hasAttachedSheet: false
            ),
            .none
        )
    }
}
