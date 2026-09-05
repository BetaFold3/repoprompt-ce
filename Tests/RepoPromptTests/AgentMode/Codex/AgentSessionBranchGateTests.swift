import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionBranchGateTests: XCTestCase {
    func testAvailableReturnsCompletedCheckpoint() throws {
        let turnID = UUID()
        let session = makeSession(turnID: turnID)

        let ledger = try XCTUnwrap(session.codexTurnCheckpoints)
        let checkpoint = try XCTUnwrap(ledger.entries.first)
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: session, turnID: turnID),
            .available(checkpoint)
        )
    }

    func testProviderAndOwnershipReasons() {
        let turnID = UUID()

        let provider = makeSession(turnID: turnID)
        provider.selectedAgent = .claudeCode
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: provider, turnID: turnID),
            .unavailable(.providerUnsupported(.claudeCode))
        )

        let remote = makeSession(turnID: turnID)
        remote.remoteHost = AgentSessionRemoteHostBinding(
            hostID: "host",
            hostDisplayName: "Host",
            remoteSessionID: "remote"
        )
        XCTAssertEqual(AgentSessionBranchGate.evaluate(session: remote, turnID: turnID), .unavailable(.remoteSession))

        let mcp = makeSession(turnID: turnID)
        mcp.origin = .mcp(clientID: nil)
        XCTAssertEqual(AgentSessionBranchGate.evaluate(session: mcp, turnID: turnID), .unavailable(.mcpOriginated))

        let malformedRemoteOrigin = makeSession(turnID: turnID)
        malformedRemoteOrigin.origin = .remote(deviceID: "device")
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: malformedRemoteOrigin, turnID: turnID),
            .unavailable(.mcpOriginated)
        )

        let child = makeSession(turnID: turnID)
        child.parentSessionID = UUID()
        XCTAssertEqual(AgentSessionBranchGate.evaluate(session: child, turnID: turnID), .unavailable(.childSession))
    }

    func testWorktreePendingAndOperationReasons() {
        let turnID = UUID()
        let worktree = makeSession(turnID: turnID)
        worktree.worktreeBindings = [makeWorktreeBinding()]
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: worktree, turnID: turnID),
            .unavailable(.worktreeBound)
        )

        let operation = makeSession(turnID: turnID)
        operation.isBranchOperationInProgress = true
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: operation, turnID: turnID),
            .unavailable(.operationInProgress)
        )

        let handoff = makeSession(turnID: turnID)
        handoff.pendingHandoff = .init(
            payload: "handoff",
            createdAt: Date(),
            sourceItemID: nil,
            defersProviderLockUntilSend: false,
            isStagedForSend: false
        )
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: handoff, turnID: turnID),
            .unavailable(.pendingHandoff)
        )
    }

    func testRuntimeActivityAndExternalOccupancyAreNotIdle() {
        let turnID = UUID()
        let running = makeSession(turnID: turnID)
        running.runState = .running
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: running, turnID: turnID),
            .unavailable(.notIdle)
        )

        let oracle = makeSession(turnID: turnID)
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(
                session: oracle,
                turnID: turnID,
                occupancy: .init(oracleRequestActive: true)
            ),
            .unavailable(.notIdle)
        )

        let terminalSettle = makeSession(turnID: turnID)
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(
                session: terminalSettle,
                turnID: turnID,
                occupancy: .init(codexTerminalSettlePending: true)
            ),
            .unavailable(.notIdle)
        )
    }

    func testCheckpointReasons() throws {
        let turnID = UUID()

        let missing = makeSession(turnID: turnID)
        missing.codexTurnCheckpoints = nil
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: missing, turnID: turnID),
            .unavailable(.noCheckpoint)
        )

        let mismatched = makeSession(turnID: turnID)
        let entries = try XCTUnwrap(mismatched.codexTurnCheckpoints).entries
        mismatched.codexTurnCheckpoints = CodexTurnCheckpointLedger(
            threadID: "other",
            entries: entries
        )
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: mismatched, turnID: turnID),
            .unavailable(.threadMismatch)
        )

        let incomplete = makeSession(turnID: turnID, status: .inProgress, sideEffect: nil)
        XCTAssertEqual(
            AgentSessionBranchGate.evaluate(session: incomplete, turnID: turnID),
            .unavailable(.turnNotCompleted)
        )
    }

    private func makeSession(
        turnID: UUID,
        status: CodexTurnCheckpoint.Status = .completed,
        sideEffect: CodexTurnCheckpoint.SideEffect? = .readOnly
    ) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.codexConversationID = "thread"
        session.codexTurnCheckpoints = CodexTurnCheckpointLedger(
            threadID: "thread",
            entries: [
                CodexTurnCheckpoint(
                    turnID: turnID,
                    codexTurnID: "turn",
                    status: status,
                    sideEffect: sideEffect,
                    recordedAt: Date(timeIntervalSinceReferenceDate: 1)
                )
            ]
        )
        return session
    }

    private func makeWorktreeBinding() -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding",
            repositoryID: "repository",
            repoKey: "repo",
            logicalRootPath: "/repo",
            logicalRootName: "repo",
            worktreeID: "worktree",
            worktreeRootPath: "/worktree",
            worktreeName: "branch",
            branch: "branch",
            head: "abc",
            visualLabel: "branch",
            visualColorHex: "#000000",
            boundAt: Date(timeIntervalSinceReferenceDate: 1),
            source: "test"
        )
    }
}
