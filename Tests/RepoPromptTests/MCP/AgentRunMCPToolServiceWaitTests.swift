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
        beforeHeartbeatOperation: @escaping () async -> Void = {}
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-wait-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in
                await beforeHeartbeatOperation()
                return try await operation()
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by wait tests")
            }
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
