import Foundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Run-start provider evidence (lossless restart P1-1): the provider a run was started with is
/// captured once on its ownership (`beginRunAttempt`) and recorded on its run attempt by whichever
/// writer creates the attempt, against a real temporary recovery store behind the real DataService
/// gate. A provider change after the run started never reaches the record.
@MainActor
final class AgentRunStartProviderRecordingTests: XCTestCase {
    /// The Claude / ACP / headless run start (`prepareRunStart` → bind the run attempt →
    /// `commitDispatch`) records the session's provider at run start. Two providers (the fixture's
    /// default, Claude Code, and a Claude-compatible one) show it is read, not assumed.
    func testClaudeRunStartCommitDispatchRecordsTheSessionsProvider() async throws {
        let defaultFixture = try await RecoveryLaneFixture.make("run-start-provider-default")
        XCTAssertEqual(defaultFixture.boundTabSession().selectedAgent, .claudeCode, "the fixture's default provider")
        defaultFixture.tearDown()

        for provider in [AgentProviderKind.claudeCode, .customClaudeCompatible] {
            let fixture = try await RecoveryLaneFixture.make("run-start-provider-\(provider.rawValue)")
            defer { fixture.tearDown() }
            let session = fixture.boundTabSession()
            session.selectedAgent = provider
            let identity = try await fixture.queuedIdentity("first input")
            let handoff = try AgentProviderHandoff.prepareRunStart(session: session, constituents: [identity]).get()
            let ownership = session.beginRunAttempt(source: "test.run-start.claude")
            XCTAssertEqual(ownership.providerKindRaw, provider.rawValue, "captured once at run start")
            guard case .success = await handoff.attachRunAttempt(ownership: ownership, processRunID: UUID(), session: session) else {
                return XCTFail("Binding the deferred run-start handoff succeeds (\(provider))")
            }
            let beforeCommit = await fixture.hasRunAttempt(ownership.attemptID)
            XCTAssertFalse(beforeCommit, "The commit creates the run attempt (\(provider))")

            guard case .success = await handoff.commitDispatch(session: session) else {
                return XCTFail("The run-start dispatch commit succeeds (\(provider))")
            }

            let attempt = try await runAttempt(ownership, in: fixture)
            XCTAssertEqual(attempt.recordedProviderKindRaw, provider.rawValue)
            XCTAssertTrue(handoff.enterProviderBoundary(in: session))
            handoff.noteAccepted()
            _ = await handoff.evidence.settled()
        }
    }

    /// Terminal evidence whose write creates the run attempt (no run-start write happened) records
    /// the run-start provider of the commit's ownership, even after the session's provider changed
    /// mid-run.
    func testTerminalEvidenceCreatingTheAttemptRecordsTheRunStartProvider() async throws {
        let fixture = try await RecoveryLaneFixture.make("terminal-run-provider")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        session.selectedAgent = .codexExec
        let ownership = session.beginRunAttempt(source: "test.terminal.provider")
        session.selectedAgent = .claudeCode
        let before = await fixture.hasRunAttempt(ownership.attemptID)
        XCTAssertFalse(before, "the terminal write creates the attempt")

        await fixture.lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: nil
        ).value

        XCTAssertNil(fixture.lane.terminalEvidenceFailures[ownership.attemptID])
        let attempt = try await runAttempt(ownership, in: fixture)
        XCTAssertEqual(attempt.recordedProviderKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertNotNil(attempt.terminal)
    }

    /// Shutdown evidence whose write creates the run attempt records the run-start provider of its
    /// ownership, even after the session's provider changed mid-run.
    func testShutdownEvidenceCreatingTheAttemptRecordsTheRunStartProvider() async throws {
        let fixture = try await RecoveryLaneFixture.make("shutdown-run-provider")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        session.selectedAgent = .codexExec
        let ownership = session.beginRunAttempt(source: "test.shutdown.provider")
        session.selectedAgent = .claudeCode
        _ = await fixture.lane.restoreComposer()
        let before = await fixture.hasRunAttempt(ownership.attemptID)
        XCTAssertFalse(before, "the shutdown write creates the attempt")

        let run = AgentRecoverySessionLane.ShutdownRunEvidence(
            ownership: ownership,
            processRunID: nil,
            reason: .appQuit,
            lastConfirmedActivityAt: nil
        )
        guard case .success = await fixture.lane.prepareForShutdown(questions: nil, run: run) else {
            return XCTFail("Stage A succeeds")
        }

        let attempt = try await runAttempt(ownership, in: fixture)
        XCTAssertEqual(attempt.recordedProviderKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(attempt.shutdown?.reason, .appQuit)
    }

    private func runAttempt(_ ownership: AgentRunOwnership, in fixture: RecoveryLaneFixture) async throws -> AgentRecoveryRunAttempt {
        let record = await fixture.store.read(sessionID: fixture.sessionID).record
        return try XCTUnwrap(record?.runAttempts.first { $0.runAttemptID == ownership.attemptID })
    }
}
