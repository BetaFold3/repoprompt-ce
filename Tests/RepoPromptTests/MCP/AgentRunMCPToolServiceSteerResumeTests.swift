import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testSteerCompletedUserOwnedSessionWithoutControlContextReactivatesAndStartsFollowUp() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var observedText: String?
        var observedEpoch: AgentRunTurnEpoch?
        service.testDispatchSteerInstruction = { dispatchedSessionID, text, _, agentModeVM in
            observedText = text
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertFalse(controlledSession.isMCPOriginated)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            let context = try XCTUnwrap(controlledSession.mcpControlContext)
            observedEpoch = try XCTUnwrap(context.currentEpoch)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("continue this user-owned session")
        ])

        XCTAssertEqual(observedText, "continue this user-owned session")
        XCTAssertEqual(value.objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(value.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertFalse(session.isMCPOriginated)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertEqual(epoch, observedEpoch)
        XCTAssertEqual(epoch.transitionKind, .steering)
        XCTAssertEqual(epoch.ordinal, 1)
        XCTAssertNil(context.pendingEpochTransition)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, context.registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            throw MCPError.internalError("synthetic steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("synthetic steer dispatch failure"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerReactivationDispatchFailurePreservesReplacementControlContextButClearsPendingMask() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var replacementActivationID: UUID?
        var replacementRegistration: AgentRunSessionStore.Registration?
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, agentModeVM in
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: sessionID))
            XCTAssertIdentical(controlledSession, session)
            let originalContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)

            try await agentModeVM.mcpActivateControlContext(
                forTabID: controlledSession.tabID,
                sessionID: sessionID,
                originatingConnectionID: UUID(),
                startPending: true,
                markSessionAsMCPOriginated: false,
                requireInactiveRunState: true
            )
            let replacementContext = try XCTUnwrap(controlledSession.mcpControlContext)
            XCTAssertNotEqual(replacementContext.activationID, originalContext.activationID)
            replacementActivationID = replacementContext.activationID
            replacementRegistration = replacementContext.registration
            throw MCPError.internalError("synthetic steer dispatch failure after replacement")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("this dispatch fails after replacement")
            ])
            XCTFail("Expected steer dispatch failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("synthetic steer dispatch failure after replacement"),
                String(describing: error)
            )
        }

        let activationID = try XCTUnwrap(replacementActivationID)
        let registration = try XCTUnwrap(replacementRegistration)
        let context = try XCTUnwrap(session.mcpControlContext)
        XCTAssertEqual(context.activationID, activationID)
        XCTAssertEqual(context.registration, registration)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, registration)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let unknownSessionID = UUID()
        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Unknown sessions must not reach dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("unknown session")
            ])
            XCTFail("Expected unknown session failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("was not found"), String(describing: error))
        }

        XCTAssertNil(viewModel.mcpControlledSession(sessionID: unknownSessionID))
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: unknownSessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerActiveUncontrolledSessionIsRejected() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .running

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Active uncontrolled sessions must be rejected before dispatch")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("active uncontrolled session")
            ])
            XCTFail("Expected active uncontrolled session rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("active but is not controlled"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    // MARK: - Plan §6.4 steer wait selection ordering

    func testSteerRejectsExplicitTimeoutAboveMaximumBeforeAnyMutationOrReactivation() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("An invalid explicit timeout must fail before the steering mutation")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("never dispatched"),
                "timeout_seconds": .int(14401)
            ])
            XCTFail("Expected timeout validation failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("14400"), String(describing: error))
        }

        XCTAssertNil(session.mcpControlContext, "Validation must run before control-context reactivation")
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasActiveRegistration)
    }

    func testSteerWithWaitFalseIgnoresSuppliedTimeoutWithoutParsingAndReportsNoPolicy() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var resolutionCount = 0
        service.resolveWaitPolicyContext = { metadata in
            resolutionCount += 1
            return AgentMCPWaitPolicy.RequestContext(metadata: metadata, parentFamily: .codex)
        }
        var dispatchCount = 0
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            dispatchCount += 1
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        // 99,999 would fail validation if parsed; wait=false must keep ignoring it with the warning.
        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("fire and forget"),
            "wait": .bool(false),
            "timeout_seconds": .int(99999)
        ])

        XCTAssertEqual(dispatchCount, 1)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertTrue(
            object["warning"]?.stringValue?.contains("Ignoring timeout_seconds because wait=false") == true,
            "warning: \(String(describing: object["warning"]))"
        )
        XCTAssertNil(object["wait_policy"], "A deliberately non-waiting steer has no wait policy to report")
        XCTAssertEqual(resolutionCount, 0, "No wait selection means no parent-family resolution")

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testSteerWithExplicitZeroFreezesFamilyBeforeDispatchAndReportsPollPolicy() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = .user
        session.runState = .completed

        var service = makeService(window: window)
        var resolvedBeforeDispatch = false
        var resolutionCount = 0
        service.resolveWaitPolicyContext = { metadata in
            resolutionCount += 1
            resolvedBeforeDispatch = true
            return AgentMCPWaitPolicy.RequestContext(metadata: metadata, parentFamily: .codex)
        }
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            XCTAssertTrue(resolvedBeforeDispatch, "The parent family must be frozen before the steering mutation")
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("steer then poll"),
            "wait": .bool(true),
            "timeout_seconds": .int(0)
        ])

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertNil(object["warning"])
        XCTAssertEqual(object["wait_policy"], .object(["mode": .string("poll"), "timeout_seconds": .int(0)]))
        XCTAssertEqual(resolutionCount, 1)

        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    private func makeRegisteredSession(
        in window: WindowState
    ) async throws -> AgentModeViewModel.TabSession {
        await window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(window: WindowState) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-steer-resume-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}
