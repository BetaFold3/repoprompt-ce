import Foundation
@testable import RepoPromptApp
import XCTest

/// Teardown-race contracts for the Claude native process controller.
///
/// The subprocess emits a trailing `result` after an interrupt, and the stdout consumer can
/// still deliver it after `shutdown()` has cleared the pending turn-ID queue (cancellation is
/// cooperative and the consume path performs no cancellation check). That sequence must be
/// recorded and recovered from, never trapped, and it must not leak turn state into the next
/// session on this reusable controller.
final class ClaudeNativeTurnTeardownTests: XCTestCase {
    private func makeController() throws -> ClaudeNativeProcessSessionController {
        try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
    }

    func testTrailingResultAfterShutdownIsRecoveredWithoutTrappingOrRestoringTurnInFlight() async throws {
        let controller = try makeController()
        await controller.test_setTurnWasInterrupted(true)
        await controller.shutdown()

        // Mirrors the observed crash sequence exactly: interrupt ACK, session shutdown, then
        // the CLI's trailing `error_during_execution` result. Before the fix the missing
        // pending turn ID hit assertionFailure() and killed the debug app.
        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "error_during_execution",
            "stop_reason": "tool_use"
        ])

        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight, "A post-shutdown trailing result must not resurrect turn tracking.")
    }

    func testReplayedResultWithoutShutdownIsRecoveredWithoutTrapping() async throws {
        let controller = try makeController()

        // Mirrors the 2026-07-27 19:28 host crash: reattaching an existing CLI
        // session replayed the final `result`/`message_stop` of an
        // already-completed turn while the controller was fully live
        // (isShuttingDown == false) with no pending turn ID. The former
        // assertionFailure killed the debug host; the signal must be recorded
        // and recovered instead.
        await controller.test_handleStreamPayload([
            "type": "result",
            "subtype": "success",
            "stop_reason": "end_turn",
            "result": "replayed final message"
        ])

        let inFlight = await controller.hasTurnInFlight
        XCTAssertFalse(inFlight, "A replayed live-path result must not resurrect turn tracking.")
    }

    func testShutdownClearsInterruptMarkerSoALaterResultIsNotMisreportedAsCancelled() async throws {
        let controller = try makeController()
        await controller.test_setTurnWasInterrupted(true)
        await controller.shutdown()

        let status = await controller.test_determineTurnStatus(payload: ["type": "result"])
        guard case .completed = status else {
            return XCTFail(
                "A successful result must not inherit the previous session's interrupt marker; got \(status)."
            )
        }
    }
}
