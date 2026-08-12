import Foundation
import MCP
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentRunMCPToolServiceWaitTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        #if DEBUG
            await OMPQualificationSharedGateTestIsolation.shared.acquire()
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        #endif
    }

    override func tearDown() async throws {
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            AgentRunMCPToolService.ompQualificationAuthorizationDeadlineNanosecondsOverride = nil
            await OMPQualificationSharedGateTestIsolation.shared.release()
        #endif
        try await super.tearDown()
    }

    func testCancelRunIDFenceRejectsMalformedAndMismatchBeforeExactCurrentCancellation() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let currentRunID = UUID()
        fixture.session.runID = currentRunID
        fixture.session.runState = .running
        await liveSnapshots.set(makeSnapshot(
            sessionID: fixture.sessionID,
            runID: currentRunID,
            status: .running
        ))
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        for malformed in ["", "not-a-uuid"] {
            do {
                _ = try await service.execute(args: [
                    "op": .string("cancel"),
                    "session_id": .string(fixture.sessionID.uuidString),
                    "run_id": .string(malformed)
                ])
                XCTFail("Expected malformed run_id to be rejected")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("non-empty UUID"))
            }
            XCTAssertEqual(fixture.session.runID, currentRunID)
            XCTAssertTrue(fixture.session.runState.isActive)
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("cancel"),
                "session_id": .string(fixture.sessionID.uuidString),
                "run_id": .string(UUID().uuidString)
            ])
            XCTFail("Expected stale run_id to be rejected")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("not the current run"))
        }
        XCTAssertEqual(fixture.session.runID, currentRunID)
        XCTAssertTrue(fixture.session.runState.isActive, "A stale fence must not cancel the later/current run")

        let successorRunID = UUID()
        let successorService = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder,
            beforeHeartbeatOperation: {
                fixture.session.runID = successorRunID
                fixture.session.runState = .running
                await liveSnapshots.set(self.makeSnapshot(
                    sessionID: fixture.sessionID,
                    runID: successorRunID,
                    status: .running
                ))
            }
        )
        do {
            _ = try await successorService.execute(args: [
                "op": .string("cancel"),
                "session_id": .string(fixture.sessionID.uuidString),
                "run_id": .string(currentRunID.uuidString)
            ])
            XCTFail("Expected a successor run installed before dispatch to be rejected")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("not the current run"))
        }
        XCTAssertEqual(fixture.session.runID, successorRunID)
        XCTAssertTrue(fixture.session.runState.isActive, "Dispatch must not cancel a successor run")

        fixture.session.runID = currentRunID
        fixture.session.runState = .running
        await liveSnapshots.set(makeSnapshot(
            sessionID: fixture.sessionID,
            runID: currentRunID,
            status: .running
        ))

        _ = try await service.execute(args: [
            "op": .string("cancel"),
            "session_id": .string(fixture.sessionID.uuidString),
            "run_id": .string(currentRunID.uuidString)
        ])
        XCTAssertFalse(fixture.session.runState.isActive)
    }

    func testGenericStartFailureCleanupIsExactAcrossDeactivatedTargetAndSuccessor() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let viewModel = window.agentModeViewModel
            for installsSuccessor in [false, true] {
                let tabID = UUID()
                let sessionID = UUID()
                let session = AgentModeViewModel.TabSession(tabID: tabID)
                session.testInstallPersistentSessionBinding(sessionID: sessionID)
                viewModel.test_installLiveSession(session)
                let target = AgentModeViewModel.MCPSessionTarget(
                    tabID: tabID,
                    sessionID: sessionID,
                    origin: .createdNewTab
                )
                let oldGenerationID = UUID()
                session.mcpStartInvocationGenerationID = oldGenerationID
                var successorGenerationID: UUID?
                var successorControlContext: AgentModeViewModel.AgentMCPControlContext?

                do {
                    _ = try await AgentExternalMCPRunStarter.start(
                        target: target,
                        message: "Fail after control activation.",
                        metadata: .init(
                            connectionID: UUID(),
                            clientName: "generic-start-cleanup-test",
                            windowID: window.windowID
                        ),
                        bindCurrentRequestToTab: { _, _ in },
                        agentModeVM: viewModel,
                        agentRaw: nil,
                        modelRaw: nil,
                        reasoningEffortRaw: nil,
                        dispatchInstruction: { _, _, _, _, agentModeVM in
                            if installsSuccessor {
                                let nextGenerationID = UUID()
                                try await agentModeVM.mcpActivateControlContext(
                                    forTabID: target.tabID,
                                    sessionID: sessionID,
                                    originatingConnectionID: UUID(),
                                    startPending: true
                                )
                                let liveSession = try XCTUnwrap(agentModeVM.session(
                                    for: target.tabID,
                                    createIfNeeded: false
                                ))
                                liveSession.mcpStartInvocationGenerationID = nextGenerationID
                                successorGenerationID = nextGenerationID
                                successorControlContext = liveSession.mcpControlContext
                            }
                            throw MCPError.internalError("Synthetic provider dispatch failure")
                        }
                    )
                    XCTFail("Expected provider dispatch failure")
                } catch {}

                var phases: [DebugRecoverableStartPhase] = [.failed]
                let outcome = await viewModel.mcpDiscardSessionTarget(
                    target,
                    ifOwnedByStartGeneration: oldGenerationID,
                    expectedSessionID: sessionID,
                    requireNoRun: true,
                    beforeDiscard: { phases.append(.discardRequested) }
                )
                if outcome == .discarded {
                    phases.append(.discardCompleted)
                }

                if installsSuccessor {
                    XCTAssertEqual(outcome, .superseded)
                    XCTAssertEqual(phases, [.failed])
                    let preserved = try XCTUnwrap(viewModel.session(
                        for: target.tabID,
                        createIfNeeded: false
                    ))
                    XCTAssertEqual(preserved.mcpStartInvocationGenerationID, successorGenerationID)
                    XCTAssertEqual(
                        preserved.mcpControlContext?.activationID,
                        successorControlContext?.activationID
                    )
                    XCTAssertEqual(
                        preserved.mcpControlContext?.registration,
                        successorControlContext?.registration
                    )
                } else {
                    XCTAssertEqual(outcome, .discarded)
                    XCTAssertEqual(phases, [.failed, .discardRequested, .discardCompleted])
                    XCTAssertNil(viewModel.session(for: target.tabID, createIfNeeded: false))
                }
            }
        #else
            throw XCTSkip("Durable MCP start generations are DEBUG-only")
        #endif
    }

    func testOMPPostActivationContextReplacementDeactivatesOnlyStaleControl() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let viewModel = window.agentModeViewModel
            let tabID = UUID()
            let sessionID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            viewModel.test_installLiveSession(session)
            let target = AgentModeViewModel.MCPSessionTarget(
                tabID: tabID,
                sessionID: sessionID,
                origin: .existingSession
            )
            let connectionID = UUID()
            let oldLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let oldConsumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                leaseID: oldLease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: sessionID
            )
            let oldContext = OhMyPiAgentModeSmokeGate.StartContext(
                transaction: oldConsumption.transaction,
                expectedWorkspaceID: UUID()
            )
            session.mcpStartInvocationGenerationID = oldContext.generationID
            session.ompQualificationStartContext = oldContext

            var activatedControlContext: AgentModeViewModel.AgentMCPControlContext?
            var successorContext: OhMyPiAgentModeSmokeGate.StartContext?
            do {
                _ = try await OhMyPiAgentModeSmokeGate.$invocationStartContext.withValue(oldContext) {
                    try await AgentExternalMCPRunStarter.start(
                        target: target,
                        message: "Replacement B must retain start ownership without activating control.",
                        metadata: .init(
                            connectionID: connectionID,
                            clientName: "omp-post-activation-replacement-test",
                            windowID: window.windowID
                        ),
                        bindCurrentRequestToTab: { _, _ in
                            activatedControlContext = session.mcpControlContext
                            _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                                oldContext.transaction
                            )
                            let successorLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                                ownerConnectionID: connectionID,
                                ownerProcessID: getpid(),
                                duration: 60
                            )
                            let successorConsumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                                leaseID: successorLease.leaseID,
                                ownerConnectionID: connectionID,
                                ownerProcessID: getpid(),
                                sessionID: sessionID
                            )
                            let replacement = OhMyPiAgentModeSmokeGate.StartContext(
                                transaction: successorConsumption.transaction,
                                expectedWorkspaceID: UUID()
                            )
                            session.mcpStartInvocationGenerationID = replacement.generationID
                            session.ompQualificationStartContext = replacement
                            successorContext = replacement
                        },
                        agentModeVM: viewModel,
                        agentRaw: nil,
                        modelRaw: nil,
                        reasoningEffortRaw: nil
                    )
                }
                XCTFail("Expected post-activation context replacement")
            } catch is AgentExternalMCPRunStarter.OMPQualificationInvocationError {}

            XCTAssertNotNil(activatedControlContext)
            XCTAssertNil(session.mcpControlContext)
            XCTAssertNil(viewModel.mcpRegistration(sessionID: sessionID))
            let replacement = try XCTUnwrap(successorContext)
            XCTAssertEqual(session.mcpStartInvocationGenerationID, replacement.generationID)
            XCTAssertTrue(session.ompQualificationStartContext === replacement)
            _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                replacement.transaction
            )
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testAbortedDiscardClearsOnlyItsClaimAndStartInstallProtectsSuccessor() async throws {
        #if DEBUG
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let viewModel = window.agentModeViewModel
            let tabID = UUID()
            let sessionID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.testInstallPersistentSessionBinding(sessionID: sessionID)
            viewModel.test_installLiveSession(session)
            let target = AgentModeViewModel.MCPSessionTarget(
                tabID: tabID,
                sessionID: sessionID,
                origin: .createdNewTab
            )
            let discardGenerationID = UUID()
            let successorGenerationID = UUID()
            XCTAssertTrue(viewModel.mcpInstallStartInvocationGeneration(
                discardGenerationID,
                for: target,
                expectedSessionID: sessionID
            ))

            var installDuringClaimAccepted = false
            let outcome = await viewModel.mcpDiscardSessionTarget(
                target,
                ifOwnedByStartGeneration: discardGenerationID,
                expectedSessionID: sessionID,
                requireNoRun: true,
                beforeDiscard: {
                    installDuringClaimAccepted = viewModel.mcpInstallStartInvocationGeneration(
                        successorGenerationID,
                        for: target,
                        expectedSessionID: sessionID
                    )
                    session.mcpStartInvocationGenerationID = successorGenerationID
                },
                isDiscardAborted: { true }
            )

            XCTAssertEqual(outcome, .aborted)
            XCTAssertFalse(installDuringClaimAccepted)
            XCTAssertNil(session.mcpStartDiscardClaimGenerationID)
            XCTAssertEqual(session.mcpStartInvocationGenerationID, successorGenerationID)
            XCTAssertTrue(viewModel.mcpInstallStartInvocationGeneration(
                successorGenerationID,
                for: target,
                expectedSessionID: sessionID
            ))
            XCTAssertTrue(viewModel.session(for: tabID, createIfNeeded: false) === session)
        #else
            throw XCTSkip("Durable MCP start generations are DEBUG-only")
        #endif
    }

    func testOMPQualificationTransactionCommitsAllLiveActionableResponseStates() {
        #if DEBUG
            XCTAssertTrue(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .running))
            XCTAssertTrue(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .waitingForInput))
            XCTAssertTrue(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .completed))
            XCTAssertFalse(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .failed))
            XCTAssertFalse(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .cancelled))
            XCTAssertFalse(AgentRunMCPToolService.ompQualificationTransactionCommits(status: .expired))
        #endif
    }

    func testOMPQualificationWorkspaceRaceRejectsBeforeLeaseConsumptionAndProviderDispatch() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationWorkspaceRace-\(UUID().uuidString)", isDirectory: true)
            let firstRoot = root.appendingPathComponent("first", isDirectory: true)
            let secondRoot = root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstWorkspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Fingerprinted",
                repoPaths: [firstRoot.path],
                ephemeral: true
            )
            let secondWorkspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Raced",
                repoPaths: [secondRoot.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: firstWorkspace,
                saveState: false,
                reason: "ompQualificationWorkspaceRaceInitial"
            )

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testAfterOMPQualificationInitialSnapshot = {
                await window.workspaceManager.switchWorkspace(
                    to: secondWorkspace,
                    saveState: false,
                    reason: "ompQualificationWorkspaceRaceAdversary"
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Must reject before provider dispatch."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(firstWorkspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected the routed workspace race to be rejected")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("workspace_mismatch"), String(describing: error))
            }
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, secondWorkspace.id)
            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationMissingWorkspaceIDFailsWithExplicitDiagnostic() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationMissingWorkspaceID-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Missing Workspace ID",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationMissingWorkspaceID"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: LiveSnapshots(),
                recorder: WaitScopeRecorder(),
                connectionID: connectionID
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Missing workspace ID fixture")
                    ))
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Reject missing workspace identity."),
                    "model_id": .string("ohMyPi:default"),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected missing workspace_id rejection")
            } catch let error as MCPError {
                XCTAssertTrue(
                    String(describing: error).contains(
                        "OMP qualification starts require an explicit workspace_id matching the fingerprinted workspace."
                    ),
                    String(describing: error)
                )
            }
            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testDeniedExplicitOMPStartHasNoRoutingOrSessionSideEffects() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPEarlyDeniedStart-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Early Denial",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "ompEarlyDenial")
            let viewModel = makeViewModel(windowID: window.windowID)
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = .ohMyPi
            viewModel.test_installLiveSession(session)
            var routingResolutionCount = 0
            var providerAvailabilityPreflightCount = 0
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                resolveRequestedTabID: { _ in session.tabID },
                resolveSpawnParentSourceTabID: { _ in
                    routingResolutionCount += 1
                    return nil
                }
            )
            service.testBeforeProviderAvailabilityPreflight = {
                providerAvailabilityPreflightCount += 1
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("must deny before routing"),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString)
                ])
                XCTFail("Expected an explicit OMP start without a lease to fail")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("_omp_qualification_lease_id"))
            }
            XCTAssertEqual(routingResolutionCount, 0)
            XCTAssertEqual(providerAvailabilityPreflightCount, 0)
            XCTAssertNil(session.mcpControlContext)
            XCTAssertNil(session.runID)
            XCTAssertEqual(session.runState, .idle)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationWorkspaceSwitchImmediatelyBeforeConsumeFailsUnconsumed() async throws {
        #if DEBUG
            try await exerciseOMPQualificationWorkspaceFence(switchBeforeConsume: true)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationWorkspaceSwitchImmediatelyBeforeProviderDispatchFailsConsumed() async throws {
        #if DEBUG
            try await exerciseOMPQualificationWorkspaceFence(switchBeforeConsume: false)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    #if DEBUG
        private func exerciseOMPQualificationWorkspaceFence(
            switchBeforeConsume: Bool
        ) async throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationLateWorkspaceRace-\(UUID().uuidString)", isDirectory: true)
            let firstRoot = root.appendingPathComponent("first", isDirectory: true)
            let secondRoot = root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let firstWorkspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Frozen Workspace",
                repoPaths: [firstRoot.path],
                ephemeral: true
            )
            let secondWorkspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Late Switch",
                repoPaths: [secondRoot.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: firstWorkspace,
                saveState: false,
                reason: "ompQualificationLateWorkspaceRaceInitial"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            var providerDispatchCount = 0
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                    providerDispatchCount += 1
                    throw MCPError.internalError("Provider dispatch must remain fenced")
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Late workspace fence fixture")
                    ))
                )
            }
            let switchWorkspace = {
                _ = await window.workspaceManager.switchWorkspace(
                    to: secondWorkspace,
                    saveState: false,
                    reason: "ompQualificationLateWorkspaceRaceAdversary"
                )
            }
            if switchBeforeConsume {
                service.testBeforeOMPQualificationConsume = {
                    await switchWorkspace()
                    XCTAssertNil(
                        OhMyPiAgentModeSmokeGate.shared.activeSnapshot()?.sessionID,
                        "The pre-consume fence must observe an unconsumed lease"
                    )
                }
            } else {
                service.testBeforeOMPQualificationProviderDispatch = {
                    XCTAssertNotNil(
                        OhMyPiAgentModeSmokeGate.shared.activeSnapshot()?.sessionID,
                        "The provider-boundary fence must observe a consumed transaction"
                    )
                    await switchWorkspace()
                }
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Must reject the late workspace switch."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(firstWorkspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected the late workspace switch to be rejected")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("workspace_mismatch"), String(describing: error))
            }
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, secondWorkspace.id)
            XCTAssertEqual(providerDispatchCount, 0)
            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
            if !switchBeforeConsume {
                XCTAssertEqual(
                    WorktreeStartupInstrumentation.snapshot().events.last?.phase,
                    .failed,
                    "The consumed workspace-fence failure must terminalize startup instrumentation"
                )
            }
        }
    #endif

    func testOMPQualificationAuthorizationUsesSingleAbsoluteDeadline() async throws {
        #if DEBUG
            AgentRunMCPToolService.ompQualificationAuthorizationDeadlineNanosecondsOverride = 50_000_000
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationSingleDeadline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Single Deadline",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationSingleDeadline"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let runID = UUID()
            var delayedAuthorizationTask: Task<Void, Never>?
            var bootstrapEntries = 0
            var capturedContext: OhMyPiAgentModeSmokeGate.StartContext?
            let viewModel = makeViewModel(windowID: window.windowID)
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                startRun: { target, _, _, _, agentModeVM, _, _, _, _, _, _, _ in
                    let session = agentModeVM.session(for: target.tabID)
                    session.runID = runID
                    session.runState = .running
                    let context = try XCTUnwrap(session.ompQualificationStartContext)
                    capturedContext = context
                    delayedAuthorizationTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(75))
                        let gateAuthorized = OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                            transaction: context.transaction,
                            runID: runID
                        )
                        let proposed: OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome = gateAuthorized
                            ? .authorized(.init(runID: runID, activeAgentSessionID: nil, runAttemptID: nil))
                            : .denied
                        if context.authorizationReceipt.resolve(proposed) == proposed, gateAuthorized {
                            bootstrapEntries += 1
                        }
                    }
                    return try .init(
                        snapshot: self.makeSnapshot(
                            sessionID: XCTUnwrap(target.sessionID),
                            runID: runID,
                            status: .running
                        ),
                        delivery: .startedRun
                    )
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Single authorization deadline fixture")
                    ))
                )
            }

            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Delayed authorization must lose at the first deadline."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "timeout": .int(10),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected authorization deadline failure")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("deadline"), String(describing: error))
            }
            await delayedAuthorizationTask?.value
            let elapsed = startedAt.duration(to: clock.now)
            XCTAssertLessThan(elapsed, .seconds(1), "Cleanup must not open a second authorization window")
            XCTAssertEqual(bootstrapEntries, 0)
            let finalAuthorizationOutcome = await capturedContext?.authorizationReceipt.wait()
            XCTAssertEqual(finalAuthorizationOutcome, .denied)
            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationExpiredBeforeProviderDispatchRollsBackWithoutDispatch() async throws {
        #if DEBUG
            AgentRunMCPToolService.ompQualificationAuthorizationDeadlineNanosecondsOverride = 20_000_000
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationPreDispatchDeadline-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Pre-Dispatch Deadline",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationPreDispatchDeadline"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            var providerDispatchCount = 0
            var terminalCategories: [String] = []
            let viewModel = makeViewModel(windowID: window.windowID)
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                    providerDispatchCount += 1
                    throw MCPError.internalError("Expired qualification must not dispatch")
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testBeforeOMPQualificationProviderDispatch = {
                try? await Task.sleep(for: .milliseconds(40))
            }
            service.testOMPQualificationTerminalCategory = { terminalCategories.append($0) }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Pre-dispatch deadline fixture")
                    ))
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Expire before provider dispatch."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "timeout": .int(10),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected pre-dispatch authorization deadline failure")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("deadline"), String(describing: error))
            }
            XCTAssertEqual(providerDispatchCount, 0)
            XCTAssertEqual(terminalCategories, ["qualification_authorization_timeout"])
            XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationSameSessionContextReplacementRejectsStaleDispatch() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationContextReplacement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Context Replacement",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationContextReplacement"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            var providerDispatchCount = 0
            var replacementLease: OhMyPiAgentModeSmokeGate.Snapshot?
            var replacementContext: OhMyPiAgentModeSmokeGate.StartContext?
            var replacementSession: AgentModeViewModel.TabSession?
            let viewModel = makeViewModel(windowID: window.windowID)
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                resolveRequestedTabID: { _ in tabID },
                startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                    providerDispatchCount += 1
                    throw MCPError.internalError("Stale invocation must not dispatch")
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testBeforeOMPQualificationContextIdentityCheck = { oldContext, session in
                replacementSession = session
                OhMyPiAgentModeSmokeGate.shared.forceExpiryForTesting()
                let nextLease = try! OhMyPiAgentModeSmokeGate.shared.acquire(
                    ownerConnectionID: connectionID,
                    ownerProcessID: getpid(),
                    duration: 60
                )
                let nextConsumption = try! OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                    leaseID: nextLease.leaseID,
                    ownerConnectionID: connectionID,
                    ownerProcessID: getpid(),
                    sessionID: oldContext.transaction.sessionID
                )
                let nextContext = OhMyPiAgentModeSmokeGate.StartContext(
                    transaction: nextConsumption.transaction,
                    expectedWorkspaceID: workspace.id
                )
                session.ompQualificationStartContext = nextContext
                replacementLease = nextLease
                replacementContext = nextContext
            }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Context replacement fixture")
                    ))
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Reject stale transaction context."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected replacement-context rejection")
            } catch let error as MCPError {
                XCTAssertTrue(String(describing: error).contains("replaced"), String(describing: error))
            }
            XCTAssertEqual(providerDispatchCount, 0)
            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot()?.leaseID, replacementLease?.leaseID)
            XCTAssertTrue(replacementSession?.ompQualificationStartContext === replacementContext)
            if let replacementContext {
                _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                    replacementContext.transaction
                )
            }
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationContextClearedAfterPreDispatchPreservesActiveSuccessor() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationPreDispatchReplacement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Pre-Dispatch Replacement",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationPreDispatchReplacement"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)

            let connectionID = UUID()
            let oldLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let viewModel = makeViewModel(windowID: window.windowID)
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var pausedSession: AgentModeViewModel.TabSession?
            var paused = false
            var resumeContinuation: CheckedContinuation<Void, Never>?
            var terminalCategories: [String] = []
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                resolveRequestedTabID: { _ in tabID },
                startRun: {
                    target,
                    message,
                    metadata,
                    bindCurrentRequestToTab,
                    agentModeVM,
                    agentRaw,
                    modelRaw,
                    reasoningEffortRaw,
                    taskLabelKind,
                    workflow,
                    expectedParentSessionID,
                    oracleReviewSource in
                    try await AgentExternalMCPRunStarter.start(
                        target: target,
                        message: message,
                        metadata: metadata,
                        bindCurrentRequestToTab: bindCurrentRequestToTab,
                        agentModeVM: agentModeVM,
                        agentRaw: agentRaw,
                        modelRaw: modelRaw,
                        reasoningEffortRaw: reasoningEffortRaw,
                        taskLabelKind: taskLabelKind,
                        workflow: workflow,
                        expectedParentSessionID: expectedParentSessionID,
                        oracleReviewSource: oracleReviewSource
                    )
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testBeforeOMPQualificationContextIdentityCheck = { _, session in
                pausedSession = session
            }
            service.testAfterOMPQualificationPreDispatchIdentityCheck = {
                paused = true
                await withCheckedContinuation { resumeContinuation = $0 }
            }
            service.testOMPQualificationTerminalCategory = { terminalCategories.append($0) }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let snapshot = AgentRunOracleReviewLaunchSnapshot(
                    route: .windowOnlyActiveCompose,
                    windowID: targetWindow.windowID,
                    workspaceID: workspace.id,
                    tabID: tabID,
                    selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                        workspaceID: workspace.id,
                        tabID: tabID
                    ),
                    promptText: "",
                    selection: StoredSelection(),
                    sourceAgentSessionID: nil,
                    routedRunID: nil
                )
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: snapshot,
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Pre-dispatch replacement fixture")
                    ))
                )
            }

            let oldRequest = Task { @MainActor in
                try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("The successor must survive this stale request."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(oldLease.leaseID.uuidString)
                ])
            }
            for _ in 0 ..< 1000 where !paused {
                await Task.yield()
            }
            XCTAssertTrue(paused, "old request must pause after its pre-dispatch identity check")

            let successorSession = try XCTUnwrap(pausedSession)
            let successorSessionID = try XCTUnwrap(successorSession.activeAgentSessionID)
            let oldContext = try XCTUnwrap(successorSession.ompQualificationStartContext)
            _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                oldContext.transaction
            )
            let replacementLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let replacementConsumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                leaseID: replacementLease.leaseID,
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                sessionID: successorSessionID
            )
            let replacementContext = OhMyPiAgentModeSmokeGate.StartContext(
                transaction: replacementConsumption.transaction,
                expectedWorkspaceID: workspace.id
            )
            successorSession.ompQualificationStartContext = replacementContext
            successorSession.selectedAgent = .ohMyPi
            let successorRunID = UUID()
            let successorAttemptID = UUID()
            successorSession.runID = successorRunID
            successorSession.runState = .running
            _ = successorSession.beginRunAttempt(
                source: "test.preDispatchReplacement",
                attemptID: successorAttemptID
            )
            let successorController = try ACPAgentSessionController(
                provider: WaitTestACPProvider(),
                runRequest: ACPRunRequest(
                    agentKind: .openCode,
                    modelString: nil,
                    workspacePath: root.path,
                    resumeSessionID: nil,
                    attachments: [],
                    taskLabelKind: nil
                )
            )
            successorSession.acpController = successorController
            XCTAssertTrue(OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                transaction: replacementContext.transaction,
                runID: successorRunID
            ))
            let replacementGateSnapshot = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                leaseID: replacementLease.leaseID,
                ownerConnectionID: connectionID,
                sessionID: successorSessionID,
                runID: successorRunID
            )
            let replacementGenerationID = replacementContext.generationID
            successorSession.ompQualificationStartContext = nil
            resumeContinuation?.resume()
            resumeContinuation = nil

            do {
                _ = try await oldRequest.value
                XCTFail("Expected the stale invocation to fail after context replacement")
            } catch let error as MCPError {
                XCTAssertTrue(
                    String(describing: error).contains("transaction context was replaced before provider dispatch"),
                    String(describing: error)
                )
            }

            XCTAssertEqual(terminalCategories, ["qualification_context_replaced"])
            XCTAssertEqual(oldContext.authorizationReceipt.resolve(.denied), .denied)
            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), replacementGateSnapshot)
            let preservedSession = try XCTUnwrap(window.agentModeViewModel.session(
                for: successorSession.tabID,
                createIfNeeded: false
            ))
            XCTAssertTrue(preservedSession === successorSession)
            XCTAssertEqual(preservedSession.activeAgentSessionID, successorSessionID)
            XCTAssertNil(preservedSession.ompQualificationStartContext)
            XCTAssertEqual(preservedSession.mcpStartInvocationGenerationID, replacementGenerationID)
            XCTAssertEqual(preservedSession.runID, successorRunID)
            XCTAssertEqual(preservedSession.activeRunAttemptID, successorAttemptID)
            XCTAssertEqual(preservedSession.runState, .running)
            XCTAssertTrue(preservedSession.acpController === successorController)

            _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                replacementContext.transaction
            )
            await successorController.shutdown()
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationWorktreeFailureAfterReplacementPreservesSuccessor() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationWorktreeReplacement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Worktree Failure Replacement",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompWorktreeFailureReplacement"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let oldLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let viewModel = makeViewModel(windowID: window.windowID)
            var terminalCategories: [String] = []
            var replacementSnapshot: OhMyPiAgentModeSmokeGate.Snapshot?
            var successorSession: AgentModeViewModel.TabSession?
            var successorContext: OhMyPiAgentModeSmokeGate.StartContext?
            var successorController: ACPAgentSessionController?
            var successorItems: [AgentChatItem] = []
            var hookError: Error?
            let successorRunID = UUID()
            let successorAttemptID = UUID()
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: viewModel,
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testWorktreePreparationFailure = MCPError.internalError("Synthetic worktree failure")
            service.testBeforeOMPQualificationTargetDiscardCAS = { liveSession in
                do {
                    let session = try XCTUnwrap(liveSession)
                    let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                    let replacementLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        duration: 60
                    )
                    let consumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                        leaseID: replacementLease.leaseID,
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        sessionID: sessionID
                    )
                    let context = OhMyPiAgentModeSmokeGate.StartContext(
                        transaction: consumption.transaction,
                        expectedWorkspaceID: workspace.id
                    )
                    let controller = try ACPAgentSessionController(
                        provider: WaitTestACPProvider(),
                        runRequest: ACPRunRequest(
                            agentKind: .openCode,
                            modelString: nil,
                            workspacePath: root.path,
                            resumeSessionID: nil,
                            attachments: [],
                            taskLabelKind: nil
                        )
                    )
                    session.ompQualificationStartContext = context
                    session.runID = successorRunID
                    session.runState = .running
                    _ = session.beginRunAttempt(
                        source: "test.worktreeFailureReplacement",
                        attemptID: successorAttemptID
                    )
                    session.acpController = controller
                    XCTAssertTrue(OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                        transaction: consumption.transaction,
                        runID: successorRunID
                    ))
                    context.authorizationReceipt.resolve(.authorized(.init(
                        runID: successorRunID,
                        activeAgentSessionID: session.activeAgentSessionID,
                        runAttemptID: successorAttemptID
                    )))
                    replacementSnapshot = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                        leaseID: replacementLease.leaseID,
                        ownerConnectionID: connectionID,
                        sessionID: sessionID,
                        runID: successorRunID
                    )
                    successorSession = session
                    successorContext = context
                    successorController = controller
                    successorItems = session.items
                } catch {
                    hookError = error
                }
            }
            service.testOMPQualificationTerminalCategory = { terminalCategories.append($0) }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Worktree replacement fixture")
                    ))
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Fail worktree preparation after replacement."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(oldLease.leaseID.uuidString)
                ])
                XCTFail("Expected synthetic worktree failure")
            } catch {}

            XCTAssertNil(hookError)
            XCTAssertEqual(terminalCategories, ["qualification_context_replaced"])
            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), replacementSnapshot)
            let preserved = try XCTUnwrap(successorSession)
            XCTAssertTrue(preserved.ompQualificationStartContext === successorContext)
            XCTAssertEqual(preserved.runID, successorRunID)
            XCTAssertEqual(preserved.activeRunAttemptID, successorAttemptID)
            XCTAssertTrue(preserved.acpController === successorController)
            XCTAssertTrue(preserved.runState.isActive)
            XCTAssertEqual(preserved.items, successorItems)
            XCTAssertTrue(window.agentModeViewModel.session(for: preserved.tabID, createIfNeeded: false) === preserved)
            if let successorContext {
                _ = OhMyPiAgentModeSmokeGate.shared.rollbackConsumedStartTransaction(
                    successorContext.transaction
                )
            }
            await successorController?.shutdown()
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationAuthorizeThenProviderFailureRollsBackBoundRun() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.providerThrows)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationAuthorizedMissingRunIdentityRollsBackBoundRun() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.missingRunID)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationAuthorizedMismatchedRunIdentityRollsBackBoundRun() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.mismatchedRunID)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationFailedAuthorizedRunCannotCancelSuccessorRun() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.successorReplacesAuthorizedRun)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationCASFailedOldRunCleanupPreservesReacquiredSuccessor() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.casFailedAfterSuccessorReacquire)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationSuccessorInstalledDuringRollbackAwaitSurvivesDiscardCAS() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(.successorInstallsBeforeDiscardCAS)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationDeniedReceiptCancelsBoundSnapshotButPreservesSuccessor() async throws {
        #if DEBUG
            try await exerciseOMPQualificationPostAuthorizationFailure(
                .deniedReceiptSuccessorReplacesAuthorizedRun
            )
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    #if DEBUG
        private enum OMPPostAuthorizationFailure: Equatable {
            case providerThrows
            case missingRunID
            case mismatchedRunID
            case successorReplacesAuthorizedRun
            case casFailedAfterSuccessorReacquire
            case successorInstallsBeforeDiscardCAS
            case deniedReceiptSuccessorReplacesAuthorizedRun
        }

        private func exerciseOMPQualificationPostAuthorizationFailure(
            _ failure: OMPPostAuthorizationFailure
        ) async throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationAuthorizedFailure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Authorized Failure",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationAuthorizedFailure"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let authorizedRunID = UUID()
            let mismatchedRunID = UUID()
            let successorRunID = UUID()
            var providerDispatchCount = 0
            var terminalCategories: [String] = []
            var authorizedSession: AgentModeViewModel.TabSession?
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID,
                startRun: { target, _, _, _, agentModeVM, _, _, _, _, _, _, _ in
                    providerDispatchCount += 1
                    let sessionID = try XCTUnwrap(target.sessionID)
                    let session = agentModeVM.session(for: target.tabID)
                    authorizedSession = session
                    session.runID = authorizedRunID
                    session.runState = .running
                    let context = try XCTUnwrap(session.ompQualificationStartContext)
                    XCTAssertTrue(
                        OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                            transaction: context.transaction,
                            runID: authorizedRunID
                        )
                    )
                    if failure == .deniedReceiptSuccessorReplacesAuthorizedRun {
                        context.authorizationReceipt.resolve(.denied)
                        session.runID = successorRunID
                    } else {
                        context.authorizationReceipt.resolve(.authorized(.init(
                            runID: authorizedRunID,
                            activeAgentSessionID: session.activeAgentSessionID,
                            runAttemptID: session.activeRunAttemptID
                        )))
                    }
                    if failure == .casFailedAfterSuccessorReacquire {
                        OhMyPiAgentModeSmokeGate.shared.forceExpiryForTesting()
                        XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
                        let successorLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                            ownerConnectionID: connectionID,
                            ownerProcessID: getpid(),
                            duration: 60
                        )
                        let successorConsumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                            leaseID: successorLease.leaseID,
                            ownerConnectionID: connectionID,
                            ownerProcessID: getpid(),
                            sessionID: sessionID
                        )
                        XCTAssertTrue(OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                            transaction: successorConsumption.transaction,
                            runID: successorRunID
                        ))
                        _ = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                            leaseID: successorLease.leaseID,
                            ownerConnectionID: connectionID,
                            sessionID: sessionID,
                            runID: successorRunID
                        )
                        session.runID = successorRunID
                        throw MCPError.internalError("Old bookkeeping failed after successor reacquire")
                    }
                    if failure == .providerThrows
                        || failure == .successorInstallsBeforeDiscardCAS
                    {
                        throw MCPError.internalError("Authorized provider failed")
                    }
                    if failure == .successorReplacesAuthorizedRun {
                        session.runID = successorRunID
                    }
                    let outcomeRunID: UUID? = switch failure {
                    case .missingRunID, .successorReplacesAuthorizedRun,
                         .deniedReceiptSuccessorReplacesAuthorizedRun:
                        nil
                    case .mismatchedRunID:
                        mismatchedRunID
                    case .providerThrows, .casFailedAfterSuccessorReacquire,
                         .successorInstallsBeforeDiscardCAS:
                        authorizedRunID
                    }
                    let snapshot = self.makeSnapshot(
                        sessionID: sessionID,
                        runID: outcomeRunID,
                        status: .running
                    )
                    return AgentExternalMCPRunStarter.StartOutcome(
                        snapshot: snapshot,
                        delivery: .startedRun
                    )
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            var discardCASHookError: Error?
            service.testBeforeOMPQualificationTargetDiscardCAS = { _ in
                guard failure == .successorInstallsBeforeDiscardCAS else { return }
                do {
                    let session = try XCTUnwrap(authorizedSession)
                    let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                    let successorLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        duration: 60
                    )
                    let successorConsumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                        leaseID: successorLease.leaseID,
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        sessionID: sessionID
                    )
                    let successorContext = OhMyPiAgentModeSmokeGate.StartContext(
                        transaction: successorConsumption.transaction,
                        expectedWorkspaceID: workspace.id
                    )
                    session.ompQualificationStartContext = successorContext
                    session.runID = successorRunID
                    session.runState = .running
                    XCTAssertTrue(OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                        transaction: successorConsumption.transaction,
                        runID: successorRunID
                    ))
                    successorContext.authorizationReceipt.resolve(.authorized(.init(
                        runID: successorRunID,
                        activeAgentSessionID: session.activeAgentSessionID,
                        runAttemptID: session.activeRunAttemptID
                    )))
                    _ = try OhMyPiAgentModeSmokeGate.shared.bindRun(
                        leaseID: successorLease.leaseID,
                        ownerConnectionID: connectionID,
                        sessionID: sessionID,
                        runID: successorRunID
                    )
                } catch {
                    discardCASHookError = error
                }
            }
            service.testOMPQualificationTerminalCategory = { terminalCategories.append($0) }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .windowOnlyActiveCompose,
                        windowID: targetWindow.windowID,
                        workspaceID: workspace.id,
                        tabID: tabID,
                        selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspace.id,
                            tabID: tabID
                        ),
                        promptText: "",
                        selection: StoredSelection(),
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Post-authorization rollback fixture")
                    ))
                )
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("Authorize, then fail closed."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected the authorized start transaction to fail")
            } catch {}
            XCTAssertEqual(providerDispatchCount, 1)
            if failure == .missingRunID {
                XCTAssertEqual(terminalCategories, ["run_identity_missing"])
            } else if failure == .mismatchedRunID {
                XCTAssertEqual(terminalCategories, ["run_identity_mismatch"])
            }
            let finalSession = try XCTUnwrap(authorizedSession)
            XCTAssertNil(discardCASHookError)
            if failure == .successorReplacesAuthorizedRun
                || failure == .casFailedAfterSuccessorReacquire
                || failure == .successorInstallsBeforeDiscardCAS
                || failure == .deniedReceiptSuccessorReplacesAuthorizedRun
            {
                XCTAssertEqual(finalSession.runID, successorRunID)
                XCTAssertTrue(
                    finalSession.runState.isActive,
                    "Exact-run cleanup must not cancel the successor run"
                )
            } else {
                XCTAssertFalse(
                    finalSession.runState.isActive,
                    "Awaited exact-run cleanup must make the authorized run inactive before error propagation"
                )
            }
            if failure == .casFailedAfterSuccessorReacquire
                || failure == .successorInstallsBeforeDiscardCAS
            {
                XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot()?.runID, successorRunID)
            } else {
                XCTAssertNil(
                    OhMyPiAgentModeSmokeGate.shared.activeSnapshot(),
                    "Every post-authorization failure must remove the exact consumed transaction"
                )
            }
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(
                instrumentation.events.last?.phase,
                .failed,
                "Every post-provider qualification failure must terminalize startup instrumentation"
            )
            XCTAssertEqual(
                instrumentation.events.count(where: { $0.phase == .failed }),
                1,
                "One provider-start failure must publish exactly one terminal instrumentation event"
            )
        }
    #endif

    func testOMPQualificationConcurrentLoserRollbackPreservesWinnerBoundRun() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationConcurrentRollback-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Concurrent Rollback",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationConcurrentRollback"
            )
            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            let winnerSessionID = UUID()
            let winnerRunID = UUID()
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testAfterOMPQualificationInitialSnapshot = {
                do {
                    let consumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                        leaseID: lease.leaseID,
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        sessionID: winnerSessionID
                    )
                    XCTAssertTrue(
                        OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                            transaction: consumption.transaction,
                            runID: winnerRunID
                        )
                    )
                } catch {
                    XCTFail("Could not install deterministic concurrent winner: \(error)")
                }
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("The concurrent winner must survive."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                ])
                XCTFail("Expected the concurrent loser to fail")
            } catch {}
            let winner = try XCTUnwrap(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
            XCTAssertEqual(winner.sessionID, winnerSessionID)
            XCTAssertEqual(winner.runID, winnerRunID)
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationOldFailurePreservesReacquiredSameConnectionLease() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationReacquiredRollback-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Reacquired Rollback",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationReacquiredRollback"
            )
            let connectionID = UUID()
            let old = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                duration: 60
            )
            var replacement: OhMyPiAgentModeSmokeGate.Snapshot?
            let replacementSessionID = UUID()
            let replacementRunID = UUID()
            let liveSnapshots = LiveSnapshots()
            let recorder = WaitScopeRecorder()
            var service = makeService(
                window: window,
                viewModel: makeViewModel(windowID: window.windowID),
                liveSnapshots: liveSnapshots,
                recorder: recorder,
                connectionID: connectionID
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, _, _ in
                candidateConnectionID == connectionID && pid == getpid()
            }
            service.testAfterOMPQualificationInitialSnapshot = {
                OhMyPiAgentModeSmokeGate.shared.forceExpiryForTesting()
                XCTAssertNil(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
                do {
                    let replacementLease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        duration: 60
                    )
                    let consumption = try OhMyPiAgentModeSmokeGate.shared.consumeStartTransaction(
                        leaseID: replacementLease.leaseID,
                        ownerConnectionID: connectionID,
                        ownerProcessID: getpid(),
                        sessionID: replacementSessionID
                    )
                    XCTAssertTrue(
                        OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                            transaction: consumption.transaction,
                            runID: replacementRunID
                        )
                    )
                    replacement = OhMyPiAgentModeSmokeGate.shared.activeSnapshot()
                } catch {
                    XCTFail("Could not reacquire deterministic replacement lease: \(error)")
                }
            }

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("The reacquired lease must survive."),
                    "model_id": .string("ohMyPi:default"),
                    "workspace_id": .string(workspace.id.uuidString),
                    "_omp_qualification_lease_id": .string(old.leaseID.uuidString)
                ])
                XCTFail("Expected the old generation start to fail")
            } catch {}
            XCTAssertEqual(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), try XCTUnwrap(replacement))
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testOMPQualificationStartWaitKeepsBoundLeaseAndExactRunActiveAfterActionableResponse() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OMPQualificationStartWait-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let window = makeWindow()
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let workspace = window.workspaceManager.createWorkspace(
                name: "OMP Qualification Start Wait",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ompQualificationStartWaitTest"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let connectionID = UUID()
            let lease = try OhMyPiAgentModeSmokeGate.shared.acquire(
                ownerConnectionID: connectionID,
                ownerProcessID: getpid(),
                ownerProcessStartSeconds: 123,
                ownerProcessStartMicroseconds: 456,
                duration: 30
            )
            XCTAssertTrue(window.apiSettingsViewModel.agentModeAvailabilityContext.ohMyPiAvailable)

            let liveSnapshots = LiveSnapshots()
            let runID = UUID()
            var startedSession: AgentModeViewModel.TabSession?
            var waitCursor: AgentRunSessionStore.WaitCursor?
            var waitingSnapshot: AgentRunMCPSnapshot?
            var service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: connectionID,
                        clientName: AgentProviderKind.ohMyPiMCPClientID,
                        windowID: window.windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                bindCurrentRequestToTab: { _, _ in },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { target, _, metadata, _, agentModeVM, agentRaw, modelRaw, _, taskLabelKind, _, _, _ in
                    let sessionID = try XCTUnwrap(target.sessionID)
                    try await agentModeVM.mcpActivateControlContext(
                        forTabID: target.tabID,
                        sessionID: sessionID,
                        originatingConnectionID: metadata.connectionID,
                        taskLabelKind: taskLabelKind,
                        startPending: true
                    )
                    let session = agentModeVM.session(for: target.tabID)
                    await agentModeVM.prepareMCPWaitTrackingForRunStart(session: session)
                    session.runID = runID
                    session.runState = .running
                    let qualificationContext = try XCTUnwrap(session.ompQualificationStartContext)
                    XCTAssertTrue(
                        OhMyPiAgentModeSmokeGate.invocationStartContext === qualificationContext,
                        "The production MCP withValue scope must reach the injected run-service seam."
                    )
                    XCTAssertTrue(OhMyPiAgentModeSmokeGate.shared.authorizeProviderStart(
                        transaction: qualificationContext.transaction,
                        runID: runID
                    ))
                    qualificationContext.authorizationReceipt.resolve(.authorized(.init(
                        runID: runID,
                        activeAgentSessionID: session.activeAgentSessionID,
                        runAttemptID: session.activeRunAttemptID
                    )))
                    let context = try XCTUnwrap(session.mcpControlContext)
                    waitCursor = try AgentRunSessionStore.WaitCursor(
                        registration: context.registration,
                        epoch: XCTUnwrap(context.currentEpoch)
                    )
                    startedSession = session
                    let running = AgentRunMCPSnapshot(
                        sessionID: sessionID,
                        runID: runID,
                        tabID: target.tabID,
                        sessionName: "OMP Qualification Start Wait",
                        agentRaw: agentRaw,
                        agentDisplayName: AgentProviderKind.ohMyPi.displayName,
                        modelRaw: modelRaw,
                        reasoningEffortRaw: nil,
                        status: .running,
                        statusText: "Running",
                        latestAssistantPreview: nil,
                        interaction: nil,
                        transcriptItemCount: 0,
                        updatedAt: Date(),
                        parentSessionID: nil,
                        failureReason: nil,
                        worktreeBindings: [],
                        activeWorktreeMerges: []
                    )
                    waitingSnapshot = AgentRunMCPSnapshot(
                        sessionID: sessionID,
                        runID: runID,
                        tabID: target.tabID,
                        sessionName: "OMP Qualification Start Wait",
                        agentRaw: agentRaw,
                        agentDisplayName: AgentProviderKind.ohMyPi.displayName,
                        modelRaw: modelRaw,
                        reasoningEffortRaw: nil,
                        status: .waitingForInput,
                        statusText: "Waiting for input",
                        latestAssistantPreview: "Please confirm",
                        interaction: nil,
                        transcriptItemCount: 1,
                        updatedAt: Date(),
                        parentSessionID: nil,
                        failureReason: nil,
                        worktreeBindings: [],
                        activeWorktreeMerges: []
                    )
                    await liveSnapshots.set(running)
                    return AgentExternalMCPRunStarter.StartOutcome(snapshot: running, delivery: .startedRun)
                }
            )
            service.testOMPQualificationOwnerVerifier = { candidateConnectionID, pid, seconds, microseconds in
                candidateConnectionID == connectionID
                    && pid == getpid()
                    && seconds == 123
                    && microseconds == 456
            }
            service.currentSnapshotProvider = { sessionID, _ in
                await liveSnapshots.snapshot(for: sessionID)
            }
            service.beginAgentRunWait = { _, _, _ in
                let snapshot = try? XCTUnwrap(waitingSnapshot)
                let cursor = try? XCTUnwrap(waitCursor)
                if let snapshot, let cursor {
                    await liveSnapshots.set(snapshot)
                    await AgentRunSessionStore.signalSnapshot(snapshot, cursor: cursor)
                }
                return UUID()
            }
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                let snapshot = AgentRunOracleReviewLaunchSnapshot(
                    route: .windowOnlyActiveCompose,
                    windowID: targetWindow.windowID,
                    workspaceID: workspace.id,
                    tabID: tabID,
                    selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                        workspaceID: workspace.id,
                        tabID: tabID
                    ),
                    promptText: "",
                    selection: StoredSelection(),
                    sourceAgentSessionID: nil,
                    routedRunID: nil
                )
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: snapshot,
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: tabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Qualification transaction fixture")
                    ))
                )
            }

            let response = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Wait for input without using tools."),
                "model_id": .string("ohMyPi:default"),
                "workspace_id": .string(workspace.id.uuidString),
                "timeout": .double(2),
                "detach": .bool(false),
                "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
            ])

            XCTAssertEqual(response.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
            let bound = try XCTUnwrap(OhMyPiAgentModeSmokeGate.shared.activeSnapshot())
            XCTAssertEqual(bound.leaseID, lease.leaseID)
            XCTAssertEqual(bound.sessionID, waitingSnapshot?.sessionID)
            XCTAssertEqual(bound.runID, runID)
            let session = try XCTUnwrap(startedSession)
            XCTAssertEqual(session.runID, runID)
            XCTAssertTrue(session.runState.isActive, "Successful actionable response delivery must not cancel the exact run")

            for (label, modelID) in [
                ("second OMP start", "ohMyPi:default"),
                ("second non-OMP start", "claudeCode:default")
            ] {
                do {
                    _ = try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("Must not disturb the already-bound qualification run."),
                        "model_id": .string(modelID),
                        "timeout": .double(2),
                        "detach": .bool(false),
                        "_omp_qualification_lease_id": .string(lease.leaseID.uuidString)
                    ])
                    XCTFail("Expected \(label) to reject the already-bound lease")
                } catch let error as MCPError {
                    XCTAssertTrue(
                        String(describing: error).contains("already consumed by an earlier start"),
                        "\(label): \(error)"
                    )
                }

                let preserved = try XCTUnwrap(OhMyPiAgentModeSmokeGate.shared.activeSnapshot(), label)
                XCTAssertEqual(preserved.leaseID, bound.leaseID, label)
                XCTAssertEqual(preserved.sessionID, bound.sessionID, label)
                XCTAssertEqual(preserved.runID, bound.runID, label)
                XCTAssertEqual(session.runID, runID, label)
                XCTAssertTrue(session.runState.isActive, "\(label) must not cancel the healthy bound run")
            }

            if let context = session.mcpControlContext {
                await AgentRunSessionStore.cleanup(registration: context.registration)
            }
        #else
            throw XCTSkip("OMP qualification transaction is DEBUG-only")
        #endif
    }

    func testSingleWaitSteeringInterruptCompletesOnceAndKeepsRegistrationActive() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let firstWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            fixture.runningSnapshot,
            cursor: fixture.cursor,
            reason: .steeringRequested
        )

        let interruptedValue = try await firstWait.value
        let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
        let interruptedMeta = try XCTUnwrap(interruptedObject["_meta"]?.objectValue)
        let interruptedWait = try XCTUnwrap(interruptedObject["wait"]?.objectValue)
        XCTAssertEqual(
            interruptedMeta["wake_reason"]?.stringValue,
            AgentRunSessionStore.WakeReason.steeringRequested.rawValue
        )
        XCTAssertEqual(interruptedWait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertTrue(interruptedWait["instruction"]?.stringValue?.contains("agent_run.wait") == true)
        XCTAssertNil(interruptedObject["assistant_text"])
        let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: fixture.sessionID
        )
        XCTAssertTrue(registrationRemainsActive)

        let firstCompletions = await recorder.completions()
        XCTAssertEqual(firstCompletions.count, 1)
        XCTAssertEqual(firstCompletions[0].reason, .cancelled)
        XCTAssertEqual(firstCompletions[0].result, "interrupted_by_steering")
        XCTAssertNil(firstCompletions[0].winnerSessionID)
        XCTAssertEqual(firstCompletions[0].pendingSessionIDs, [fixture.sessionID])

        let secondWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)
        let terminalRunID = UUID()
        let terminal = makeSnapshot(sessionID: fixture.sessionID, runID: terminalRunID, status: .completed)
        await liveSnapshots.set(terminal)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let resumedValue = try await secondWait.value
        XCTAssertEqual(resumedValue.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        XCTAssertEqual(resumedValue.objectValue?["run_id"]?.stringValue, terminalRunID.uuidString)
        XCTAssertNil(resumedValue.objectValue?["_meta"]?.objectValue?["wake_reason"])
        let allCompletions = await recorder.completions()
        XCTAssertEqual(allCompletions.count, 2)
        XCTAssertEqual(allCompletions[1].reason, .snapshotReady)
        XCTAssertEqual(allCompletions[1].winnerSessionID, fixture.sessionID)
    }

    func testSingleWaitCancellationDoesNotFabricateSteering() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "cancelled")
        XCTAssertNil(completions[0].winnerSessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, [fixture.sessionID])
    }

    func testMultiWaitSteeringInterruptReturnsAllPendingIDsAndCompletesAggregateScopeOnce() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: first.registration)
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            second.runningSnapshot,
            cursor: second.cursor,
            reason: .steeringRequested
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(
            meta["wake_reason"]?.stringValue,
            AgentRunSessionStore.WakeReason.steeringRequested.rawValue
        )
        XCTAssertEqual(object["session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
        XCTAssertNil(wait["winner_session_id"]?.stringValue)
        XCTAssertEqual(wait["interrupted_session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [first.sessionID.uuidString, second.sessionID.uuidString]
        )
        let firstRegistrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: first.sessionID
        )
        let secondRegistrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: second.sessionID
        )
        XCTAssertTrue(firstRegistrationRemainsActive)
        XCTAssertTrue(secondRegistrationRemainsActive)

        let beginRecords = await recorder.beginRecords()
        let completions = await recorder.completions()
        XCTAssertEqual(beginRecords.count, 1)
        XCTAssertEqual(beginRecords[0], Set([first.sessionID, second.sessionID]))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "interrupted_by_steering")
        XCTAssertEqual(completions[0].pendingSessionIDs, Set([first.sessionID, second.sessionID]))
    }

    func testMultiWaitCancellationDoesNotFabricateSteering() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: first.registration)
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .cancelled)
        XCTAssertEqual(completions[0].result, "cancelled")
        XCTAssertNil(completions[0].winnerSessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, Set([first.sessionID, second.sessionID]))
    }

    func testMultiWaitInstructionDeliveredContinuesUntilActionableAndCompletesOnce() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: first.registration)
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)

        await AgentRunSessionStore.wakeCurrentWaiters(
            second.runningSnapshot,
            cursor: second.cursor,
            reason: .instructionDelivered
        )
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)

        let terminal = makeSnapshot(sessionID: first.sessionID, status: .completed)
        await liveSnapshots.set(terminal)
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: first.epoch, snapshot: terminal),
            registration: first.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, first.sessionID.uuidString)
        XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
        XCTAssertEqual(wait["winner_session_id"]?.stringValue, first.sessionID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [second.sessionID.uuidString]
        )
        XCTAssertNil(object["_meta"]?.objectValue?["wake_reason"])

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .snapshotReady)
        XCTAssertEqual(completions[0].winnerSessionID, first.sessionID)
        XCTAssertEqual(completions[0].pendingSessionIDs, [second.sessionID])
    }

    func testParkedWaitPollAndLaterWaitUseStoredTerminalSnapshot() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )
        let sentinel = "complete-terminal-sentinel."
        let liveRunning = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .running,
            latestAssistantPreview: "live-running-sentinel"
        )
        await liveSnapshots.set(liveRunning)

        let preterminalPoll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        XCTAssertEqual(
            preterminalPoll.objectValue?["assistant_text"]?.stringValue,
            "live-running-sentinel"
        )

        let firstWait = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        // Direct store publication bypasses AgentRunTerminalCommitBarrier; keep this fixture aligned
        // with the production invariant from
        // docs/investigations/remote-client-premature-terminal-and-model-label-2026-07-09.md:
        // final terminal publication sets the live session terminal with no follow-up mask first.
        // Live non-terminal/masked snapshots intentionally win in AgentRunSnapshotPrecedenceTests.
        fixture.session.runState = .completed
        fixture.session.mcpFollowUpRunPending = false
        let terminal = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .completed,
            latestAssistantPreview: sentinel
        )
        _ = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )

        let firstValue = try await firstWait.value
        XCTAssertEqual(firstValue.objectValue?["assistant_text"]?.stringValue, sentinel)

        let pollValue = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        XCTAssertEqual(pollValue.objectValue?["assistant_text"]?.stringValue, sentinel)

        let laterWaitValue = try await service.execute(args: [
            "op": .string("wait"),
            "session_id": .string(fixture.sessionID.uuidString),
            "timeout": .double(2)
        ])
        XCTAssertEqual(
            laterWaitValue.objectValue?["assistant_text"]?.stringValue,
            sentinel
        )
        XCTAssertEqual(
            laterWaitValue.objectValue?["status"]?.stringValue,
            AgentRunMCPSnapshot.Status.completed.rawValue
        )
    }

    func testSingleWaitTimeoutSurfacesStartupPendingSnapshot() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )
        let startupPending = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .running,
            statusText: AgentRunMCPSnapshot.startupPendingStatusText
        )
        await liveSnapshots.set(startupPending)
        await AgentRunSessionStore.signalSnapshot(startupPending, cursor: fixture.cursor)

        let value = try await service.execute(args: [
            "op": .string("wait"),
            "session_id": .string(fixture.sessionID.uuidString),
            "timeout": .double(0.05)
        ])

        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        XCTAssertEqual(meta["wait_result"]?.stringValue, "startup_pending")
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(object["status_text"]?.stringValue, AgentRunMCPSnapshot.startupPendingStatusText)
        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .startupPending)
        XCTAssertEqual(completions[0].result, "startup_pending")
        XCTAssertEqual(completions[0].pendingSessionIDs, [fixture.sessionID])
    }

    // MARK: - Plan §6.2: interaction_resolved wake/metadata

    func testSingleWaitWakesWithInteractionResolvedMetadata() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        let resolution = AgentRunMCPSnapshot.InteractionResolution(
            interactionID: UUID(),
            resolvedBy: "remote:aaaa1111",
            resolvedAt: Date()
        )
        let resolvedSnapshot = makeSnapshot(
            sessionID: fixture.sessionID,
            status: .running,
            lastInteractionResolution: resolution
        )
        await liveSnapshots.set(resolvedSnapshot)
        await AgentRunSessionStore.wakeCurrentWaiters(
            resolvedSnapshot,
            cursor: fixture.cursor,
            reason: .interactionResolved
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let meta = try XCTUnwrap(object["_meta"]?.objectValue)
        XCTAssertEqual(
            meta["wake_reason"]?.stringValue,
            AgentRunSessionStore.WakeReason.interactionResolved.rawValue
        )
        let resolvedMeta = try XCTUnwrap(meta["interaction_resolved"]?.objectValue)
        XCTAssertEqual(resolvedMeta["interaction_id"]?.stringValue, resolution.interactionID.uuidString)
        XCTAssertEqual(resolvedMeta["resolved_by"]?.stringValue, "remote:aaaa1111")
        XCTAssertNotNil(resolvedMeta["resolved_at"]?.stringValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(wait["result"]?.stringValue, "interaction_resolved")

        let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: fixture.sessionID
        )
        XCTAssertTrue(registrationRemainsActive)

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .snapshotReady)
        XCTAssertEqual(completions[0].result, "interaction_resolved")
        XCTAssertEqual(completions[0].winnerSessionID, fixture.sessionID)
    }

    func testMultiWaitSnapshotsCarryInteractionResolvedMetadata() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        let second = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(2)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: first.registration)
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)

        let resolution = AgentRunMCPSnapshot.InteractionResolution(
            interactionID: UUID(),
            resolvedBy: "remote:aaaa1111",
            resolvedAt: Date()
        )
        let resolvedSnapshot = makeSnapshot(
            sessionID: second.sessionID,
            status: .running,
            lastInteractionResolution: resolution
        )
        await liveSnapshots.set(resolvedSnapshot)
        await AgentRunSessionStore.wakeCurrentWaiters(
            resolvedSnapshot,
            cursor: second.cursor,
            reason: .interactionResolved
        )

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        let secondSnapshot = try XCTUnwrap(snapshots.first { snapshot in
            snapshot.objectValue?["session_id"]?.stringValue == second.sessionID.uuidString
        })
        let meta = try XCTUnwrap(secondSnapshot.objectValue?["_meta"]?.objectValue)
        let resolvedMeta = try XCTUnwrap(meta["interaction_resolved"]?.objectValue)
        XCTAssertEqual(resolvedMeta["interaction_id"]?.stringValue, resolution.interactionID.uuidString)
        XCTAssertEqual(resolvedMeta["resolved_by"]?.stringValue, "remote:aaaa1111")
        XCTAssertNotNil(resolvedMeta["resolved_at"]?.stringValue)
    }

    func testPollSerializesInteractionResolvedMetadata() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )

        let resolution = AgentRunMCPSnapshot.InteractionResolution(
            interactionID: UUID(),
            resolvedBy: "repoprompt-cli",
            resolvedAt: Date()
        )
        await liveSnapshots.set(makeSnapshot(
            sessionID: fixture.sessionID,
            status: .running,
            lastInteractionResolution: resolution
        ))

        let value = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        let meta = try XCTUnwrap(value.objectValue?["_meta"]?.objectValue)
        let resolvedMeta = try XCTUnwrap(meta["interaction_resolved"]?.objectValue)
        XCTAssertEqual(resolvedMeta["interaction_id"]?.stringValue, resolution.interactionID.uuidString)
        XCTAssertEqual(resolvedMeta["resolved_by"]?.stringValue, "repoprompt-cli")
    }

    func testPollForIndexedSessionWithoutLiveRegistrationDoesNotReturnExpired() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(
            window: window,
            viewModel: viewModel,
            liveSnapshots: liveSnapshots,
            recorder: recorder
        )
        let sessionID = UUID()
        let tabID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let workspace = WorkspaceModel(name: "Indexed Agent Sessions", repoPaths: [])
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        viewModel.test_installSessionIndexSnapshot(
            [
                sessionID: AgentSessionIndexEntry(
                    id: sessionID,
                    tabID: tabID,
                    name: "Indexed Remote Session",
                    lastUserMessageAt: savedAt,
                    savedAt: savedAt,
                    lastRunStateRaw: AgentSessionRunState.running.rawValue,
                    itemCount: 7,
                    agentKindRaw: AgentProviderKind.codexExec.rawValue,
                    agentModelRaw: "codex",
                    agentReasoningEffortRaw: "medium",
                    autoEditEnabled: false,
                    parentSessionID: nil,
                    hasUnknownConversationContent: false,
                    remoteHostID: nil,
                    remoteHostName: nil,
                    isMCPOriginated: false,
                    origin: nil,
                    worktreeBindingSummaries: [],
                    activeWorktreeMergeSummaries: []
                )
            ],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )

        let value = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertNotEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.expired.rawValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
        XCTAssertEqual(object["session"]?.objectValue?["name"]?.stringValue, "Indexed Remote Session")
        XCTAssertEqual(object["transcript_item_count"]?.intValue, 7)
        XCTAssertTrue(object["status_text"]?.stringValue?.contains("no active control handle") == true)
        let waitScopes = await recorder.beginRecords()
        XCTAssertTrue(waitScopes.isEmpty)
    }

    func testRecordMCPInteractionResolutionConsumesStagedAttribution() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        let interactionID = UUID()

        session.pendingInteractionResolutionAttribution = "remote:aaaa1111"
        viewModel.recordMCPInteractionResolution(for: session, interactionID: interactionID)

        let recorded = try XCTUnwrap(session.lastInteractionResolution)
        XCTAssertEqual(recorded.interactionID, interactionID)
        XCTAssertEqual(recorded.resolvedBy, "remote:aaaa1111")
        XCTAssertNil(session.pendingInteractionResolutionAttribution, "Attribution is single-use")
    }

    func testRecordMCPInteractionResolutionFallsBackToUserAttribution() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        let interactionID = UUID()

        viewModel.recordMCPInteractionResolution(for: session, interactionID: interactionID)

        let recorded = try XCTUnwrap(session.lastInteractionResolution)
        XCTAssertEqual(recorded.resolvedBy, "user", "App-local resolutions attribute to user")
    }

    func testStaleRespondStillThrowsAtVMLevelWithoutLeakingAttribution() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(in: viewModel, liveSnapshots: liveSnapshots)
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let session = try XCTUnwrap(viewModel.sessions.values.first { $0.activeAgentSessionID == fixture.sessionID })

        do {
            _ = try await viewModel.mcpResolvePendingInteraction(
                sessionID: fixture.sessionID,
                interactionID: UUID(),
                payload: .init(
                    text: "yes",
                    skip: false,
                    decisionRaw: nil,
                    amendment: nil,
                    answersByQuestionID: [:]
                ),
                resolvedBy: "remote:aaaa1111"
            )
            XCTFail("Stale respond must throw at the VM level")
        } catch {
            XCTAssertTrue(
                String(describing: error).localizedCaseInsensitiveContains("interaction"),
                "VM fencing stays strict: \(error)"
            )
        }
        XCTAssertNil(
            session.pendingInteractionResolutionAttribution,
            "A failed MCP respond must not leave attribution behind for a later user-local resolution"
        )
        XCTAssertNil(session.lastInteractionResolution)
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func makeViewModel(windowID: Int) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in WaitTestCodexController() }
        )
    }

    private func installRunningSession(
        in viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots
    ) async throws -> RunningSessionFixture {
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: epoch
        )
        let runningSnapshot = makeSnapshot(
            sessionID: sessionID,
            status: .running,
            latestAssistantPreview: "stale assistant text"
        )
        await liveSnapshots.set(runningSnapshot)
        await AgentRunSessionStore.signalSnapshot(runningSnapshot, cursor: cursor)
        return RunningSessionFixture(
            sessionID: sessionID,
            session: session,
            registration: context.registration,
            epoch: epoch,
            cursor: cursor,
            runningSnapshot: runningSnapshot
        )
    }

    private func makeService(
        window: WindowState,
        viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots,
        recorder: WaitScopeRecorder,
        beforeHeartbeatOperation: @escaping () async -> Void = {},
        connectionID: UUID? = nil,
        resolveRequestedTabID: @escaping (_ args: [String: Value]) throws -> UUID? = { _ in nil },
        resolveSpawnParentSourceTabID: @escaping (_ metadata: MCPServerViewModel.RequestMetadata) async -> UUID? = { _ in nil },
        startRun: @escaping AgentRunMCPToolService.StartRun = { _, _, _, _, _, _, _, _, _, _, _, _ in
            throw MCPError.internalError("startRun should not be used by wait tests")
        }
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "agent-run-wait-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: resolveRequestedTabID,
            resolveSpawnParentSourceTabID: resolveSpawnParentSourceTabID,
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in
                await beforeHeartbeatOperation()
                return try await operation()
            },
            startRun: startRun
        )
        service.beginAgentRunWait = {
            (_: MCPServerViewModel.RequestMetadata, sessionIDs: Set<UUID>, _: TimeInterval?) async -> UUID? in
            await recorder.begin(sessionIDs: sessionIDs)
        }
        service.endAgentRunWait = {
            (token: UUID, completion: AgentRunWaitScopeCompletion) async in
            await recorder.end(token: token, completion: completion)
        }
        service.currentSnapshotProvider = {
            (sessionID: UUID, _: AgentModeViewModel) async -> AgentRunMCPSnapshot? in
            await liveSnapshots.snapshot(for: sessionID)
        }
        service.testAgentModeViewModel = viewModel
        return service
    }

    private func makeSnapshot(
        sessionID: UUID,
        runID: UUID? = nil,
        status: AgentRunMCPSnapshot.Status,
        statusText: String? = nil,
        latestAssistantPreview: String? = nil,
        lastInteractionResolution: AgentRunMCPSnapshot.InteractionResolution? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: runID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText ?? status.rawValue,
            latestAssistantPreview: latestAssistantPreview,
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            lastInteractionResolution: lastInteractionResolution
        )
    }
}

private struct RunningSessionFixture {
    let sessionID: UUID
    let session: AgentModeViewModel.TabSession
    let registration: AgentRunSessionStore.Registration
    let epoch: AgentRunTurnEpoch
    let cursor: AgentRunSessionStore.WaitCursor
    let runningSnapshot: AgentRunMCPSnapshot
}

private actor LiveSnapshots {
    private var snapshots: [UUID: AgentRunMCPSnapshot] = [:]

    func set(_ snapshot: AgentRunMCPSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
        snapshots[sessionID]
    }
}

private struct WaitTestACPProvider: ACPAgentProvider {
    /// The fixture only needs a stable controller identity; using OpenCode avoids
    /// consulting the developer machine's OMP launch resolution.
    let providerID: ACPProviderID = .openCode

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: "/usr/bin/true",
            arguments: [],
            environment: [:],
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

private final class WaitTestCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "wait-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private actor WaitScopeRecorder {
    private var startedSessionIDs: [Set<UUID>] = []
    private var recordedCompletions: [AgentRunWaitScopeCompletion] = []

    func begin(sessionIDs: Set<UUID>) -> UUID {
        startedSessionIDs.append(sessionIDs)
        return UUID()
    }

    func end(token _: UUID, completion: AgentRunWaitScopeCompletion) {
        recordedCompletions.append(completion)
    }

    func beginRecords() -> [Set<UUID>] {
        startedSessionIDs
    }

    func completions() -> [AgentRunWaitScopeCompletion] {
        recordedCompletions
    }
}
