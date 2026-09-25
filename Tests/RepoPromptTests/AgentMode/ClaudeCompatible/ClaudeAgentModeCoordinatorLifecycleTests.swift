import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
extension AgentModeRunServiceLifecycleTests {
    func testAutoLaunchSettingsEqualityTracksBaseAndBackendButNotEffort() {
        let opusKey = ClaudeAgentModeCoordinator.AutoPermissionValidationKey(
            agentKind: .claudeCode,
            runtimeVariant: .standard,
            baseModel: "claude-opus-5"
        )
        let sonnetKey = ClaudeAgentModeCoordinator.AutoPermissionValidationKey(
            agentKind: .claudeCode,
            runtimeVariant: .standard,
            baseModel: "claude-sonnet-5"
        )
        let compatibleKey = ClaudeAgentModeCoordinator.AutoPermissionValidationKey(
            agentKind: .claudeCodeGLM,
            runtimeVariant: .glm,
            baseModel: "claude-opus-5"
        )
        let base = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: "/workspace",
            permissionMode: "auto",
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: opusKey
        )
        let sameEffortFreeIdentity = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: "/workspace",
            permissionMode: "auto",
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: opusKey
        )
        let changedModel = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: "/workspace",
            permissionMode: "auto",
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: sonnetKey
        )
        let changedBackend = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .glm,
            workspacePath: "/workspace",
            permissionMode: "auto",
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: compatibleKey
        )

        XCTAssertEqual(base, sameEffortFreeIdentity)
        XCTAssertNotEqual(base, changedModel)
        XCTAssertNotEqual(base, changedBackend)
    }

    func testActiveAutoTurnDefersLiveSettingsApplication() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "auto-active",
            hasTurnInFlight: true
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.selectedModelRaw = "opus"
        session.permissionProfile = .providerOverride(.claude(.auto))
        harness.host.test_installLiveSession(session)
        harness.host.test_setCurrentTabIDOverride(session.tabID)
        defer { harness.host.test_setCurrentTabIDOverride(nil) }
        guard let runID = session.runID else {
            return XCTFail("Expected running Claude session identity")
        }

        let launchSettings = ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).standardizedFileURL.path,
            permissionMode: "auto",
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: .init(
                agentKind: .claudeCode,
                runtimeVariant: .standard,
                baseModel: "opus"
            )
        )
        session.claudePermissionSessionState = .acknowledged(
            ClaudePermissionAcknowledgement(
                ownership: ClaudePermissionControllerOwnership(
                    controllerIdentifier: ObjectIdentifier(controller as AnyObject),
                    runID: runID,
                    runAttemptID: session.activeRunAttemptID
                ),
                launchSettings: launchSettings,
                requestedMode: "auto",
                acknowledgedEffort: .high
            )
        )
        harness.host.updatePermissionBindingState(from: session, syncUI: false)
        let acknowledgedBinding = harness.host.activeProviderControlsBinding
        XCTAssertEqual(acknowledgedBinding?.permission.sessionStatus?.phase, .acknowledged)
        harness.host.claudeCoordinator.test_setControllerLaunchSettings(
            launchSettings,
            for: session
        )

        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_active_auto"
        )

        XCTAssertFalse(recorder.contains("auto-active:apply"))
        guard case .pendingNextTurn = session.claudePermissionSessionState else {
            return XCTFail("Expected pending next-turn evidence")
        }
        let pendingBinding = harness.host.activeProviderControlsBinding
        XCTAssertEqual(pendingBinding?.permission.sessionStatus?.phase, .pendingNextTurn)
        XCTAssertNotEqual(acknowledgedBinding, pendingBinding)
    }

    func testOwnedStartupPropagatesPromptCacheRetentionToSession() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "extended-cache",
            promptCacheRetention: .extended
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        harness.host.test_installLiveSession(session)

        let sent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "propagate retention",
            attachments: []
        )

        XCTAssertTrue(sent)
        XCTAssertEqual(session.claudePromptCacheRetention, .extended)
    }

    func testCancelledDispatchCannotResumeAgainstSuccessorController() async {
        let recorder = LifecycleRecorder()
        let cancelledStartGate = LifecycleAsyncGate()
        let cancelledController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "cancelled-dispatch",
            startGate: cancelledStartGate,
            promptCacheRetention: .extended
        )
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-dispatch",
            promptCacheRetention: .standard
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? cancelledController : successorController
            }
        )
        let session = makeRunningClaudeSession(controller: cancelledController)
        session.claudeController = nil
        harness.host.test_installLiveSession(session)

        let cancelledDispatch = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "cancelled",
                attachments: []
            )
        }
        await cancelledStartGate.waitUntilArrived()

        _ = harness.host.claudeCoordinator.prepareClaudeCancelSync(session)
        if let cancelledAttemptID = session.activeRunAttemptID {
            _ = session.endRunAttempt(
                ifCurrentAttemptID: cancelledAttemptID,
                source: "test_cancelled_dispatch"
            )
        }
        session.runState = .running
        session.beginRunAttempt(source: "test_successor_dispatch")

        let successorDispatch = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "successor",
                attachments: []
            )
        }
        let successorSent = await successorDispatch.value

        XCTAssertTrue(successorSent)
        XCTAssertFalse(recorder.contains("cancelled-dispatch:send"))
        XCTAssertEqual(
            recorder.events.count { $0 == "successor-dispatch:send" },
            1
        )
        XCTAssertEqual(session.claudeExpectedTurnIDs.count, 1)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.claudePromptCacheRetention, .standard)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)

        await cancelledStartGate.release()
        let cancelledSent = await cancelledDispatch.value

        XCTAssertFalse(cancelledSent)
        XCTAssertEqual(
            recorder.events.count { $0 == "successor-dispatch:send" },
            1
        )
        XCTAssertEqual(session.claudeExpectedTurnIDs.count, 1)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.claudePromptCacheRetention, .standard)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testSupersededStartupReturnCannotEvictSuccessorAutoEffortEvidence() async {
        let recorder = LifecycleRecorder()
        let supersededStartGate = LifecycleAsyncGate()
        let supersededController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "superseded-auto-startup",
            startGate: supersededStartGate
        )
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-auto-startup",
            failApplyCount: 1
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? supersededController : successorController
            }
        )
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = makeRunningClaudeSession(controller: supersededController)
        session.claudeController = nil
        session.selectedModelRaw = model
        session.permissionProfile = .providerOverride(.claude(.auto))
        harness.host.test_installLiveSession(session)

        let supersededDispatch = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "superseded",
                attachments: []
            )
        }
        await supersededStartGate.waitUntilArrived()

        _ = harness.host.claudeCoordinator.prepareClaudeCancelSync(session)
        if let supersededAttemptID = session.activeRunAttemptID {
            _ = session.endRunAttempt(
                ifCurrentAttemptID: supersededAttemptID,
                source: "test_superseded_auto_startup"
            )
        }
        session.runState = .running
        session.beginRunAttempt(source: "test_successor_auto_startup")

        let firstSuccessorSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "successor first",
            attachments: []
        )

        XCTAssertTrue(firstSuccessorSent)
        let appliedEffortsAfterFirstSuccessorSend = await successorController.recordedAppliedEffortLevels()
        XCTAssertTrue(appliedEffortsAfterFirstSuccessorSend.isEmpty)

        await supersededStartGate.release()
        let supersededSent = await supersededDispatch.value
        XCTAssertFalse(supersededSent)

        let secondSuccessorSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "successor second",
            attachments: []
        )

        XCTAssertTrue(secondSuccessorSent)
        XCTAssertEqual(
            recorder.events.count { $0 == "successor-auto-startup:send" },
            2
        )
        let successorAppliedEfforts = await successorController.recordedAppliedEffortLevels()
        XCTAssertTrue(successorAppliedEfforts.isEmpty)
        XCTAssertFalse(recorder.contains("superseded-auto-startup:send"))
        let supersededAppliedEfforts = await supersededController.recordedAppliedEffortLevels()
        XCTAssertTrue(supersededAppliedEfforts.isEmpty)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected successor Auto effort acknowledgement")
        }
        XCTAssertEqual(
            acknowledgement.ownership.controllerIdentifier,
            ObjectIdentifier(successorController as AnyObject)
        )
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .high)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testSupersededStartupReturnCannotOverwriteSuccessorPromptCacheRetention() async {
        let recorder = LifecycleRecorder()
        let supersededStartGate = LifecycleAsyncGate()
        let supersededController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "superseded-retention-startup",
            startGate: supersededStartGate,
            promptCacheRetention: .extended
        )
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-retention-startup",
            promptCacheRetention: .standard
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in supersededController }
        )
        let session = makeRunningClaudeSession(controller: supersededController)
        session.claudeController = nil
        harness.host.test_installLiveSession(session)

        var didSupersedeBeforeRetentionSync = false
        harness.host.claudeCoordinator.test_setBeforePromptCacheRetentionSync { observedSession in
            guard !didSupersedeBeforeRetentionSync else { return }
            didSupersedeBeforeRetentionSync = true
            if let supersededAttemptID = observedSession.activeRunAttemptID {
                _ = observedSession.endRunAttempt(
                    ifCurrentAttemptID: supersededAttemptID,
                    source: "test_superseded_retention_startup"
                )
            }
            observedSession.runID = UUID()
            observedSession.runState = .running
            observedSession.beginRunAttempt(source: "test_successor_retention_startup")
            observedSession.claudeController = successorController
            observedSession.claudePromptCacheRetention = .standard
        }
        defer {
            harness.host.claudeCoordinator.test_setBeforePromptCacheRetentionSync(nil)
        }

        let supersededDispatch = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "superseded retention",
                attachments: []
            )
        }
        await supersededStartGate.waitUntilArrived()
        await supersededStartGate.release()
        let supersededSent = await supersededDispatch.value

        XCTAssertFalse(supersededSent)
        XCTAssertTrue(didSupersedeBeforeRetentionSync)
        XCTAssertEqual(session.claudePromptCacheRetention, .standard)
        XCTAssertTrue(
            session.claudeController.map {
                ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(successorController as AnyObject)
            } ?? false
        )
    }

    func testRetainedAutoControllerAppliesDeferredEffortBeforeNextSend() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retained-auto-effort"
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        await controller.setTurnInFlight(true)
        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_active_high_to_low"
        )

        guard case let .pendingNextTurn(active, _, _) = session.claudePermissionSessionState else {
            return XCTFail("Expected deferred Low effort evidence")
        }
        XCTAssertEqual(active?.acknowledgedEffort, .high)

        await controller.setTurnInFlight(false)
        let sent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "apply low",
            attachments: []
        )

        XCTAssertTrue(sent)
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(appliedEfforts, [.low])
        assertOrderedEvents([
            "retained-auto-effort:apply",
            "retained-auto-effort:send"
        ], in: recorder)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected acknowledged Low effort evidence")
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .low)
    }

    func testFailedAutoEffortApplicationRemainsPendingAndRetriesBeforeSend() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retry-auto-effort",
            failApplyCount: 1
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)

        let firstSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "first",
            attachments: []
        )

        XCTAssertFalse(firstSent)
        XCTAssertFalse(recorder.contains("retry-auto-effort:send"))
        guard case let .pendingNextTurn(active, _, _) = session.claudePermissionSessionState else {
            return XCTFail("Expected failed Low effort to remain pending")
        }
        XCTAssertEqual(active?.acknowledgedEffort, .high)

        let secondSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "second",
            attachments: []
        )

        XCTAssertTrue(secondSent)
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(appliedEfforts, [.low, .low])
        XCTAssertEqual(
            recorder.events.count { $0 == "retry-auto-effort:send" },
            1
        )
        assertOrderedEvents([
            "retry-auto-effort:apply",
            "retry-auto-effort:apply",
            "retry-auto-effort:send"
        ], in: recorder)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected retried Low effort acknowledgement")
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .low)
    }

    func testAutoEffortRevalidatesAfterEventsPreparationBeforeSend() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "final-auto-effort"
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        let eventsReadyGate = LifecycleAsyncGate()
        await controller.setEventsStreamReadyGate(eventsReadyGate)

        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "latest effort",
                attachments: []
            )
        }
        await eventsReadyGate.waitUntilArrived()

        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_effort_change_during_events_prepare"
        )
        await eventsReadyGate.release()

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(appliedEfforts, [.low])
        assertOrderedEvents([
            "final-auto-effort:events-ready",
            "final-auto-effort:apply",
            "final-auto-effort:send"
        ], in: recorder)
    }

    func testSameControllerAutoRestartReinitializesCapturedEffortThenAppliesLatestBeforeSend() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "same-controller-auto-restart"
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await controller.setHasActiveSession(false)
        let restartGate = LifecycleAsyncGate()
        await controller.setStartGate(restartGate)

        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "same controller restart",
                attachments: []
            )
        }
        await restartGate.waitUntilArrived()

        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_same_controller_restart_latest_effort"
        )
        await restartGate.release()

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        let startEfforts = await controller.recordedStartEffortLevels()
        XCTAssertEqual(startEfforts, [.high, .low])
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(appliedEfforts, [.high])
        assertOrderedEvents([
            "same-controller-auto-restart:start:low",
            "same-controller-auto-restart:apply:high",
            "same-controller-auto-restart:send"
        ], in: recorder)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected latest High effort acknowledgement after restart")
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .high)
    }

    func testAutoReinitializationEvidenceFollowsStartupReturnNotPreSampledActiveSession() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "startup-return-auto-evidence"
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await controller.forceInitializationOnNextStartCall()
        let restartGate = LifecycleAsyncGate()
        await controller.setStartGate(restartGate)
        let reportsActiveBeforeStart = await controller.hasActiveSession
        XCTAssertTrue(reportsActiveBeforeStart)

        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "startup-return evidence",
                attachments: []
            )
        }
        await restartGate.waitUntilArrived()

        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_startup_return_auto_evidence"
        )
        await restartGate.release()

        let sent = await sendTask.value
        XCTAssertTrue(sent)
        let startEfforts = await controller.recordedStartEffortLevels()
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(startEfforts, [.high, .low])
        XCTAssertEqual(appliedEfforts, [.high])
        assertOrderedEvents([
            "startup-return-auto-evidence:start:low",
            "startup-return-auto-evidence:apply:high",
            "startup-return-auto-evidence:send"
        ], in: recorder)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected latest High effort acknowledgement after reported initialization")
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .high)
    }

    func testAutoReuseAfterUnobservedReinitializationDropsStaleEffortEvidenceBeforeSend() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unobserved-auto-reinitialization"
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = await makeInitializedAutoSession(
            harness: harness,
            controller: controller,
            model: model
        )
        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await controller.advanceInitializationGenerationUnobserved(effortLevel: .low)
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)

        let firstSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "revalidate after unobserved initialization",
            attachments: []
        )
        let secondSent = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "reuse acknowledged generation",
            attachments: []
        )

        XCTAssertTrue(firstSent)
        XCTAssertTrue(secondSent)
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertEqual(appliedEfforts, [.high])
        XCTAssertEqual(
            recorder.events.count { $0 == "unobserved-auto-reinitialization:send" },
            2
        )
        assertOrderedEvents([
            "unobserved-auto-reinitialization:unobserved-initialization:low",
            "unobserved-auto-reinitialization:apply:high",
            "unobserved-auto-reinitialization:send"
        ], in: recorder)
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            return XCTFail("Expected High effort acknowledgement for the advanced generation")
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .high)
    }

    func testAutoInitializationCompletionPreservesPendingEffortIntent() async {
        let recorder = LifecycleRecorder()
        let initializationGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "gated-auto-initialization",
            hasActiveSession: false,
            startGate: initializationGate
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let effortService = harness.host.providerBindingService
        let model = "opus"
        let previousEffort = effortService.claudeEffortLevel(
            forModelRaw: model,
            agentKind: .claudeCode
        )
        effortService.setClaudeEffortLevel(.high, forModelRaw: model, agentKind: .claudeCode)
        defer {
            effortService.setClaudeEffortLevel(
                previousEffort,
                forModelRaw: model,
                agentKind: .claudeCode
            )
        }

        let session = makeRunningClaudeSession(controller: controller)
        session.claudeController = nil
        session.selectedModelRaw = model
        session.permissionProfile = .providerOverride(.claude(.auto))
        harness.host.test_installLiveSession(session)

        let initializationTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await initializationGate.waitUntilArrived()

        effortService.setClaudeEffortLevel(.low, forModelRaw: model, agentKind: .claudeCode)
        await harness.host.claudeCoordinator.applyCurrentClaudeModelAndEffortIfPossible(
            for: session,
            reason: "test_initialization_pending_effort"
        )
        await initializationGate.release()
        await initializationTask.value

        let startEfforts = await controller.recordedStartEffortLevels()
        XCTAssertEqual(startEfforts, [.high])
        let appliedEfforts = await controller.recordedAppliedEffortLevels()
        XCTAssertTrue(appliedEfforts.isEmpty)
        guard case let .pendingNextTurn(active, requestedMode, _) =
            session.claudePermissionSessionState
        else {
            return XCTFail("Expected pending Low intent after High initialization")
        }
        XCTAssertEqual(active?.acknowledgedEffort, .high)
        XCTAssertEqual(requestedMode, "auto")
    }

    func testQueuedClaudeSteeringRecreatesControllerBeforeSendWhenPermissionsTighten() async {
        let recorder = LifecycleRecorder()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: true
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, settings in
                recorder.record("factory:claude:\(settings.permissionMode ?? "nil"):\(String(describing: settings.allowNativeBashTool)):\(String(describing: settings.mcpStrictMode))")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
            allowNativeBashTool: true,
            mcpStrictMode: false
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "tighten before send")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        let launchSettings = harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session)
        XCTAssertEqual(
            launchSettings?.permissionMode,
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        )
        XCTAssertEqual(launchSettings?.allowNativeBashTool, false)
        XCTAssertEqual(launchSettings?.mcpStrictMode, true)
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "idle",
            "old:interrupt:interrupt",
            "old:shutdown",
            "factory:claude:default:Optional(false):Optional(true)",
            "new:start",
            "new:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRevalidatesPermissionsImmediatelyBeforeDispatch() async {
        let recorder = LifecycleRecorder()
        let eventsReadyGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: false,
            eventsStreamReadyGate: eventsReadyGate
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, settings in
                recorder.record("factory:claude:\(settings.permissionMode ?? "nil"):\(String(describing: settings.allowNativeBashTool)):\(String(describing: settings.mcpStrictMode))")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        let initialProfile = AgentProviderPermissionProfile.providerOverride(.claude(.fullAccess))
        let initialRuntime = resolvedClaudeLaunchPolicy(
            profile: initialProfile,
            harness: harness
        )
        session.permissionProfile = initialProfile
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: initialRuntime?.permissionMode,
            allowNativeBashTool: initialRuntime?.allowNativeBashTool,
            mcpStrictMode: initialRuntime?.mcpStrictMode
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "tighten at dispatch")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await eventsReadyGate.waitUntilArrived()
        session.permissionProfile = .mcpSafeDefaults
        await eventsReadyGate.release()
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        let launchSettings = harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session)
        XCTAssertEqual(
            launchSettings?.permissionMode,
            ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        )
        XCTAssertEqual(launchSettings?.allowNativeBashTool, false)
        XCTAssertEqual(launchSettings?.mcpStrictMode, true)
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "old:start",
            "old:events-ready",
            "old:shutdown",
            "factory:claude:default:Optional(false):Optional(true)",
            "new:start",
            "new:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRevalidatesWorkspaceImmediatelyBeforeDispatch() async {
        let recorder = LifecycleRecorder()
        let eventsReadyGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old-workspace-dispatch",
            eventsStreamReadyGate: eventsReadyGate
        )
        let newController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "new-workspace-dispatch"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:workspace-dispatch")
                return newController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: .mcpSafeDefaults,
            harness: harness
        )
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "workspace at dispatch")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await eventsReadyGate.waitUntilArrived()
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: "/stale/workspace",
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await eventsReadyGate.release()
        await session.claudeSteeringFlushTask?.value

        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertFalse(recorder.contains("old-workspace-dispatch:send"))
        assertOrderedEvents([
            "old-workspace-dispatch:events-ready",
            "old-workspace-dispatch:shutdown",
            "factory:workspace-dispatch",
            "new-workspace-dispatch:start",
            "new-workspace-dispatch:send",
            "delivered"
        ], in: recorder)
    }

    func testQueuedClaudeSteeringRecycleDoesNotClearReplacementControllerAfterAwait() async {
        let recorder = LifecycleRecorder()
        let currentSessionRefGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old",
            hasTurnInFlight: true,
            currentSessionRefGate: currentSessionRefGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement",
            hasTurnInFlight: false
        )
        let fallbackController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fallback",
            hasTurnInFlight: false
        )
        let harness = makeHarness(
            recorder: recorder,
            idleWaiter: { _ in recorder.record("idle") },
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:unexpected")
                return fallbackController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
            allowNativeBashTool: true,
            mcpStrictMode: false
        )
        session.pendingClaudeSteeringInstructions = [makeClaudeSteeringInstruction(session: session, text: "replace while recycling")]

        let queueStarted = await harness.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(queueStarted)
        await currentSessionRefGate.waitUntilArrived()
        session.claudeController = replacementController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
            allowNativeBashTool: false,
            mcpStrictMode: true
        )
        await currentSessionRefGate.release()
        await session.claudeSteeringFlushTask?.value

        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertFalse(recorder.contains("factory:unexpected"))
        XCTAssertFalse(recorder.contains("old:send"))
        assertOrderedEvents([
            "idle",
            "old:interrupt:interrupt",
            "old:current-ref",
            "old:shutdown",
            "replacement:start",
            "replacement:send",
            "delivered"
        ], in: recorder)
    }

    func testClaudeWorkspaceRecycleDoesNotClearReplacementAfterCurrentSessionAwait() async {
        let recorder = LifecycleRecorder()
        let currentSessionRefGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "old-workspace",
            currentSessionRefGate: currentSessionRefGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-workspace"
        )
        let fallbackController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fallback-workspace"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:workspace-unexpected")
                return fallbackController
            }
        )
        let session = makeRunningClaudeSession(controller: oldController)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: .mcpSafeDefaults,
            harness: harness
        )
        let currentWorkspacePath = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).standardizedFileURL.path
        session.permissionProfile = .mcpSafeDefaults
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: "/stale/workspace",
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await currentSessionRefGate.waitUntilArrived()
        session.claudeController = replacementController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            workspacePath: currentWorkspacePath,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await currentSessionRefGate.release()
        await ensureTask.value

        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement workspace controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertFalse(recorder.contains("factory:workspace-unexpected"))
        assertOrderedEvents([
            "old-workspace:current-ref",
            "old-workspace:shutdown"
        ], in: recorder)
    }

    func testResumeFallbackDetachesAndClaimsBeforeRetiringOldController() async {
        let recorder = LifecycleRecorder()
        let oldShutdownGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "claimed-before-retirement",
            failResumeStart: true,
            shutdownGate: oldShutdownGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-after-retirement"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in replacementController }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-to-resume"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await oldShutdownGate.waitUntilArrived()

        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertTrue(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))

        await oldShutdownGate.release()
        await ensureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected a replacement controller after retirement")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testCancelInvalidatesTrackedPrivateFallbackBeforeStartupReturns() async {
        let recorder = LifecycleRecorder()
        let privateStartupGate = LifecycleAsyncGate()
        let privateShutdownGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-private-cancel",
            failResumeStart: true
        )
        let privateReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "private-cancelled-before-startup-return",
            startGate: privateStartupGate,
            shutdownGate: privateShutdownGate
        )
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-after-private-cancel",
            sessionID: "successor-after-private-cancel-session"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? privateReplacement : successorController
            }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-before-private-cancel"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let firstEnsureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await privateStartupGate.waitUntilArrived()
        XCTAssertTrue(
            harness.host.claudeCoordinator.test_hasTrackedPrivateFallbackController(for: session)
        )

        _ = harness.host.claudeCoordinator.prepareClaudeCancelSync(session)
        await privateShutdownGate.waitUntilArrived()

        XCTAssertNil(session.claudeController)
        XCTAssertFalse(
            harness.host.claudeCoordinator.test_hasTrackedPrivateFallbackController(for: session)
        )
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))

        await privateShutdownGate.release()
        await privateStartupGate.release()
        await firstEnsureTask.value

        session.runState = .running
        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        guard let installedController = session.claudeController else {
            return XCTFail("Expected a successor after cancelled preparation completed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(successorController as AnyObject)
        )
        XCTAssertEqual(factoryInvocationCount, 2)
        XCTAssertEqual(
            recorder.events.count {
                $0 == "private-cancelled-before-startup-return:shutdown"
            },
            1
        )
        XCTAssertFalse(recorder.contains("successor-after-private-cancel:shutdown"))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testCoordinatorStopShutsDownTrackedPrivateFallbackBeforeStartupReturns() async {
        let recorder = LifecycleRecorder()
        let privateStartupGate = LifecycleAsyncGate()
        let privateShutdownGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-coordinator-stop",
            failResumeStart: true
        )
        let privateReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "private-stopped-before-startup-return",
            startGate: privateStartupGate,
            shutdownGate: privateShutdownGate
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in privateReplacement }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-before-coordinator-stop"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await privateStartupGate.waitUntilArrived()
        XCTAssertTrue(
            harness.host.claudeCoordinator.test_hasTrackedPrivateFallbackController(for: session)
        )
        XCTAssertTrue(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))

        harness.host.claudeCoordinator.stop()
        await privateShutdownGate.waitUntilArrived()

        XCTAssertNil(session.claudeController)
        XCTAssertFalse(
            harness.host.claudeCoordinator.test_hasTrackedPrivateFallbackController(for: session)
        )
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertTrue(recorder.contains("private-stopped-before-startup-return:shutdown"))

        await privateShutdownGate.release()
        await privateStartupGate.release()
        await ensureTask.value

        XCTAssertNil(session.claudeController)
        XCTAssertEqual(
            recorder.events.count {
                $0 == "private-stopped-before-startup-return:shutdown"
            },
            1
        )
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testConcurrentEnsureJoinsPrivateFallbackPreparation() async {
        let recorder = LifecycleRecorder()
        let freshStartupGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-private-startup",
            failResumeStart: true
        )
        let privateReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "private-replacement",
            startGate: freshStartupGate,
            sessionID: "private-provider-session"
        )
        let unexpectedSuccessor = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unexpected-successor"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? privateReplacement : unexpectedSuccessor
            }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-to-resume"
        session.appendItem(.user("prior request", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(.assistant("prior answer", sequenceIndex: session.nextSequenceIndex))
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let firstEnsureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await freshStartupGate.waitUntilArrived()

        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertTrue(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))

        let joiningEnsureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await Task.yield()

        XCTAssertEqual(factoryInvocationCount, 1)
        let maximumConcurrentStarts = await privateReplacement.maximumConcurrentStartInvocationCount()
        XCTAssertEqual(maximumConcurrentStarts, 1)

        await freshStartupGate.release()
        await firstEnsureTask.value
        await joiningEnsureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the joined preparation controller to be installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(privateReplacement as AnyObject)
        )
        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertEqual(session.providerSessionID, "private-provider-session")
        XCTAssertNotNil(session.pendingHandoff.payload)
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        let privateStartSessionIDs = await privateReplacement.recordedStartExistingSessionIDs()
        XCTAssertEqual(privateStartSessionIDs, [nil])
        XCTAssertFalse(recorder.contains("private-replacement:shutdown"))
        XCTAssertFalse(recorder.contains("unexpected-successor:start"))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testResumeFallbackWithoutTransferableItemsCommitsFreshSessionWithoutHandoff() async {
        let recorder = LifecycleRecorder()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-without-handoff",
            failResumeStart: true
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-without-handoff",
            sessionID: "fresh-provider-session-without-handoff"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in replacementController }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-without-transcript"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the fresh controller to be committed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertEqual(session.providerSessionID, "fresh-provider-session-without-handoff")
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertNotNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        let retiredStartSessionIDs = await retiredController.recordedStartExistingSessionIDs()
        let replacementStartSessionIDs = await replacementController.recordedStartExistingSessionIDs()
        XCTAssertEqual(retiredStartSessionIDs, ["provider-session-without-transcript"])
        XCTAssertEqual(replacementStartSessionIDs, [nil])
        XCTAssertFalse(recorder.contains("replacement-without-handoff:shutdown"))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testSameControllerAttemptSupersessionDoesNotShutdownSuccessor() async throws {
        let recorder = LifecycleRecorder()
        let startGate = LifecycleAsyncGate()
        let sharedController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "same-controller-successor",
            failResumeStart: true,
            startGate: startGate
        )
        let harness = makeHarness(recorder: recorder, claudeController: sharedController)
        let session = makeRunningClaudeSession(controller: sharedController)
        session.providerSessionID = "provider-session-to-resume"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await startGate.waitUntilArrived()
        let previousOwnership = try XCTUnwrap(session.activeRunOwnership)
        XCTAssertTrue(session.endRunAttempt(
            ifCurrent: previousOwnership,
            source: "test.sameControllerSuperseded"
        ))
        let successorOwnership = session.beginRunAttempt(source: "test.sameControllerSuccessor")
        await startGate.release()
        await ensureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the successor to retain the shared controller")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(sharedController as AnyObject)
        )
        XCTAssertEqual(session.activeRunAttemptID, successorOwnership.attemptID)
        XCTAssertFalse(recorder.contains("same-controller-successor:shutdown"))
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testStaleFallbackHandoffDoesNotCommitOrShutdownSameControllerSuccessor() async throws {
        let recorder = LifecycleRecorder()
        let handoffBeforeCommitGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-stale-handoff",
            failResumeStart: true
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-with-stale-handoff"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in replacementController }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        session.providerSessionID = "provider-session-before-stale-handoff"
        session.appendItem(.user("prior request", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(.assistant("prior answer", sequenceIndex: session.nextSequenceIndex))
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        harness.host.claudeCoordinator.test_setResumeRecoveryHandoffBeforeCommitGate {
            await handoffBeforeCommitGate.arriveAndWait()
        }

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await handoffBeforeCommitGate.waitUntilArrived()
        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertTrue(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        let previousOwnership = try XCTUnwrap(session.activeRunOwnership)
        XCTAssertTrue(session.endRunAttempt(
            ifCurrent: previousOwnership,
            source: "test.staleHandoffSuperseded"
        ))
        let successorOwnership = session.beginRunAttempt(source: "test.staleHandoffSuccessor")
        session.claudeController = replacementController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await handoffBeforeCommitGate.release()
        await ensureTask.value
        harness.host.claudeCoordinator.test_setResumeRecoveryHandoffBeforeCommitGate(nil)

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the successor to retain the replacement controller")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertEqual(session.activeRunAttemptID, successorOwnership.attemptID)
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertEqual(session.providerSessionID, "provider-session-before-stale-handoff")
        XCTAssertFalse(recorder.contains("replacement-with-stale-handoff:shutdown"))
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
    }

    func testResumeFallbackPreservesRunIdentityAndReplacementEventsReachActiveAttempt() async throws {
        let recorder = LifecycleRecorder()
        let replacementSendGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-resume",
            failResumeStart: true
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "fresh-replacement",
            sendUserMessageGate: replacementSendGate,
            emittedAssistantTextOnSend: "replacement answer"
        )
        var factoryRunIDs: [UUID] = []
        var transcriptSession: AgentModeViewModel.TabSession?
        var observedAttemptIDs: [UUID?] = []
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { runID, _, _, _ in
                factoryRunIDs.append(runID)
                return factoryRunIDs.count == 1 ? retiredController : replacementController
            },
            handleHeadlessStreamResult: { result in
                observedAttemptIDs.append(transcriptSession?.activeRunAttemptID)
                if let transcriptSession, let text = result.text {
                    transcriptSession.appendItem(.assistant(
                        text,
                        sequenceIndex: transcriptSession.nextSequenceIndex
                    ))
                }
            },
            autoSignalACPRouting: true
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "provider-session-to-resume"
        session.appendItem(.user("prior request", sequenceIndex: session.nextSequenceIndex))
        transcriptSession = session

        let outcome = await harness.service.startRun(
            tabID: session.tabID,
            session: session,
            initialUserMessage: "continue",
            initialMessageForRun: "continue",
            attachments: []
        )
        XCTAssertNil(outcome)
        await replacementSendGate.waitUntilArrived()
        XCTAssertEqual(session.providerSessionID, "lifecycle-claude-session")
        XCTAssertNotNil(session.pendingHandoff.payload)
        await retiredController.emitAssistantText("retired event")

        let activeAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        let originalRunID = try XCTUnwrap(factoryRunIDs.first)
        let agentTask = try XCTUnwrap(session.agentTask)
        await replacementSendGate.release()
        let completedTurnID = await replacementController.waitForPendingTurnCompletion()
        while !session.claudeExpectedTurnIDs.contains(completedTurnID) {
            await Task.yield()
        }
        await replacementController.emitPendingTurnCompletion()
        await agentTask.value

        XCTAssertEqual(factoryRunIDs, [originalRunID, originalRunID])
        XCTAssertEqual(session.runID, originalRunID)
        XCTAssertEqual(observedAttemptIDs, [activeAttemptID])
        XCTAssertEqual(
            session.items.filter { $0.kind == .assistant }.map(\.text),
            ["replacement answer"]
        )
        XCTAssertFalse(session.items.contains { $0.text == "retired event" })
        XCTAssertEqual(session.runState, .completed)
        XCTAssertEqual(
            harness.host.claudeCoordinator.test_trackedClaudeRunID(for: session),
            originalRunID
        )
        let retiredStartSessionIDs = await retiredController.recordedStartExistingSessionIDs()
        let replacementStartSessionIDs = await replacementController.recordedStartExistingSessionIDs()
        XCTAssertEqual(retiredStartSessionIDs, ["provider-session-to-resume"])
        XCTAssertEqual(replacementStartSessionIDs, [nil])
        let policyEvents = recorder.events.filter { $0.hasPrefix("policy:") }
        XCTAssertEqual(policyEvents.count, 1)
        XCTAssertTrue(try XCTUnwrap(policyEvents.first).hasSuffix(originalRunID.uuidString))
    }

    func testResumeFallbackStartupFailureDiscardsReplacementStateTransactionally() async throws {
        let recorder = LifecycleRecorder()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-resume-failure",
            failResumeStart: true
        )
        let failedReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "failed-fresh-replacement",
            failStart: true
        )
        let retryController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retry-selected-controller"
        )
        var factoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                factoryInvocationCount += 1
                return factoryInvocationCount == 1 ? failedReplacement : retryController
            }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        let originalRunID = try XCTUnwrap(session.runID)
        session.providerSessionID = "provider-session-to-preserve"
        session.appendItem(.user("prior request", sequenceIndex: session.nextSequenceIndex))
        session.appendItem(.assistant("prior answer", sequenceIndex: session.nextSequenceIndex))
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertEqual(session.runID, originalRunID)
        XCTAssertEqual(session.providerSessionID, "provider-session-to-preserve")
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertTrue(recorder.contains("failed-fresh-replacement:shutdown"))

        session.runState = .running
        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        guard let installedController = session.claudeController else {
            return XCTFail("Expected retry to install a newly selected controller")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(retryController as AnyObject)
        )
        XCTAssertNotNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertEqual(session.runID, originalRunID)
        XCTAssertNil(session.pendingHandoff.payload)
        let retryStartSessionIDs = await retryController.recordedStartExistingSessionIDs()
        XCTAssertEqual(retryStartSessionIDs, ["provider-session-to-preserve"])
    }

    func testResumeFallbackDoesNotOverwriteNewerControllerWhileToolTrackingStops() async throws {
        let recorder = LifecycleRecorder()
        let toolTrackingStopGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-during-tracking-stop",
            failResumeStart: true
        )
        let newerController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "newer-during-tracking-stop"
        )
        let unexpectedFallback = LifecycleFakeNativeController(
            recorder: recorder,
            label: "unexpected-fallback"
        )
        var fallbackFactoryInvocationCount = 0
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                fallbackFactoryInvocationCount += 1
                return unexpectedFallback
            }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        let runID = try XCTUnwrap(session.runID)
        session.providerSessionID = "provider-session-during-tracking-stop"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await harness.host.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
            for: session,
            runID: runID
        )
        harness.host.claudeCoordinator.test_setStopToolTrackingGate {
            await toolTrackingStopGate.arriveAndWait()
        }

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await toolTrackingStopGate.waitUntilArrived()
        session.claudeController = newerController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await toolTrackingStopGate.release()
        await ensureTask.value
        harness.host.claudeCoordinator.test_setStopToolTrackingGate(nil)

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the newer controller to remain installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(newerController as AnyObject)
        )
        XCTAssertEqual(fallbackFactoryInvocationCount, 0)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
    }

    func testFailedFallbackRetirementCannotFailNewerController() async throws {
        let recorder = LifecycleRecorder()
        let failedReplacementShutdownGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-failed-replacement",
            failResumeStart: true
        )
        let failedReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "failed-replacement-retiring",
            failStart: true,
            shutdownGate: failedReplacementShutdownGate
        )
        let newerController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "newer-during-retirement"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in failedReplacement }
        )
        let session = makeRunningClaudeSession(controller: retiredController)
        let runID = try XCTUnwrap(session.runID)
        let runAttemptID = try XCTUnwrap(session.activeRunAttemptID)
        session.providerSessionID = "provider-session-during-retirement"
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ensureTask = Task {
            await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        }
        await failedReplacementShutdownGate.waitUntilArrived()
        session.claudeController = newerController
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )
        await failedReplacementShutdownGate.release()
        await ensureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the newer controller to survive stale retirement")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(newerController as AnyObject)
        )
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.activeRunAttemptID, runAttemptID)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.providerSessionID, "provider-session-during-retirement")
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertTrue(recorder.contains("failed-replacement-retiring:shutdown"))
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
    }

    func testConfiguredTerminalStartupFailureDiscardsControllerAndLaunchSettings() async {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            label: "configured-failure",
            failStart: true,
            requiresReplacementAfterTerminalStartupFailure: true
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        XCTAssertNil(session.claudeController)
        XCTAssertNil(harness.host.claudeCoordinator.test_controllerLaunchSettings(for: session))
        XCTAssertEqual(session.runState, .failed)
        assertOrderedEvents([
            "configured-failure:start",
            "configured-failure:shutdown"
        ], in: recorder)
    }

    func testClaudeSendCompletionDoesNotFailReplacementController() async {
        let recorder = LifecycleRecorder()
        let sendGate = LifecycleAsyncGate()
        let oldController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "stale-send",
            sendUserMessageGate: sendGate
        )
        let replacementController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "replacement-send"
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeController: oldController
        )
        let session = makeRunningClaudeSession(controller: oldController)
        let runtime = resolvedClaudeLaunchPolicy(
            profile: session.permissionProfile,
            harness: harness
        )
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let sendTask = Task {
            await harness.host.claudeCoordinator.sendClaudeNativeMessage(
                session: session,
                text: "do not fail replacement",
                attachments: []
            )
        }
        await sendGate.waitUntilArrived()
        session.claudeController = replacementController
        await sendGate.release()

        let didSend = await sendTask.value
        XCTAssertFalse(didSend)
        guard let finalController = session.claudeController else {
            XCTFail("Expected replacement controller to remain installed")
            return
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(replacementController as AnyObject)
        )
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertTrue(recorder.contains("stale-send:shutdown"))
    }

    func testInvalidatedClaudeResumeTransferCannotRestoreClearedSessionID() async {
        let recorder = LifecycleRecorder()
        let sessionRefGate = LifecycleAsyncGate()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            currentSessionRefGate: sessionRefGate
        )
        let harness = makeHarness(recorder: recorder, claudeController: controller)
        let session = makeRunningClaudeSession(controller: controller)
        session.providerSessionID = "session-to-clear"

        let detached = harness.host.claudeCoordinator.prepareClaudeCancelSync(session)
        harness.host.claudeCoordinator.beginClaudeResumeTransferIfNeeded(
            for: session,
            oldController: detached
        )
        await sessionRefGate.waitUntilArrived()
        harness.host.claudeCoordinator.invalidatePendingClaudeResumeTransfer(for: session)
        session.providerSessionID = nil
        await sessionRefGate.release()
        await harness.host.claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)

        XCTAssertNil(session.providerSessionID)
        XCTAssertFalse(
            harness.host.claudeCoordinator.test_hasPendingOrRetiredResumeTransfers(for: session)
        )
        XCTAssertTrue(recorder.contains("claude:shutdown"))
    }

    private func makeInitializedAutoSession(
        harness: LifecycleHarness,
        controller: LifecycleFakeNativeController,
        model: String
    ) async -> AgentModeViewModel.TabSession {
        let session = makeRunningClaudeSession(controller: controller)
        session.claudeController = nil
        session.selectedModelRaw = model
        session.permissionProfile = .providerOverride(.claude(.auto))
        harness.host.test_installLiveSession(session)

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        guard let installedController = session.claudeController else {
            XCTFail("Expected initialized Auto controller")
            return session
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(controller as AnyObject)
        )
        guard case let .acknowledged(acknowledgement) = session.claudePermissionSessionState else {
            XCTFail("Expected initialized Auto permission acknowledgement")
            return session
        }
        XCTAssertEqual(acknowledgement.acknowledgedEffort, .high)
        return session
    }

    private func resolvedClaudeLaunchPolicy(
        profile: AgentProviderPermissionProfile,
        harness: LifecycleHarness
    ) -> ClaudeControllerLaunchPolicy? {
        let providerBindingService = harness.host.providerBindingService
        let permissionMode = providerBindingService.runtimePermission(
            for: .claudeCode,
            profile: profile
        ).claudePermissionMode
        let preferences = providerBindingService.preferences
        return ClaudeControllerLaunchPolicy.resolve(
            permissionMode: permissionMode,
            profile: profile,
            defaults: preferences.defaults,
            securePermissions: preferences.securePermissions
        )
    }

    private func setClaudeControllerLaunchSettings(
        for session: AgentModeViewModel.TabSession,
        coordinator: ClaudeAgentModeCoordinator,
        workspacePath: String? = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).standardizedFileURL.path,
        permissionMode: String?,
        allowNativeBashTool: Bool?,
        mcpStrictMode: Bool?
    ) {
        coordinator.test_setControllerLaunchSettings(
            .init(
                runtimeVariant: .standard,
                workspacePath: workspacePath,
                permissionMode: permissionMode,
                allowNativeBashTool: allowNativeBashTool,
                mcpStrictMode: mcpStrictMode,
                sessionProfile: .standard,
                toolSearchEnabled: nil
            ),
            for: session
        )
    }
}

actor LifecycleAsyncGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let arrivalWaiters = arrivalWaiters
        self.arrivalWaiters.removeAll()
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

actor LifecycleFakeNativeController: NativeAgentRuntimeControlling {
    private let recorder: LifecycleRecorder
    private let label: String
    private var activeSession: Bool
    private var turnInFlight: Bool
    private let failSend: Bool
    private var remainingApplyFailures: Int
    private let failStart: Bool
    private let failResumeStart: Bool
    private let replacementAfterTerminalStartupFailure: Bool
    private var startGate: LifecycleAsyncGate?
    private let currentSessionRefGate: LifecycleAsyncGate?
    private var eventsStreamReadyGate: LifecycleAsyncGate?
    private var forceInitializationOnNextStart = false
    private var initializationGeneration: UInt64 = 0
    private let sendUserMessageGate: LifecycleAsyncGate?
    private let shutdownGate: LifecycleAsyncGate?
    private let emittedAssistantTextOnSend: String?
    private let sessionID: String
    private let promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention
    private let stream: AsyncStream<NativeAgentRuntimeEvent>
    private let streamContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation
    private var startExistingSessionIDs: [String?] = []
    private var startEffortLevels: [NativeAgentRuntimeEffortLevel?] = []
    private var appliedEffortLevels: [NativeAgentRuntimeEffortLevel?] = []
    private var activeStartInvocationCount = 0
    private var maxConcurrentStartInvocationCount = 0
    private var pendingTurnCompletionID: UUID?
    private var pendingTurnCompletionWaiters: [CheckedContinuation<UUID, Never>] = []

    init(
        recorder: LifecycleRecorder,
        label: String = "claude",
        hasActiveSession: Bool = true,
        hasTurnInFlight: Bool = false,
        failSend: Bool = false,
        failApplyCount: Int = 0,
        failStart: Bool = false,
        failResumeStart: Bool = false,
        requiresReplacementAfterTerminalStartupFailure: Bool = false,
        startGate: LifecycleAsyncGate? = nil,
        currentSessionRefGate: LifecycleAsyncGate? = nil,
        eventsStreamReadyGate: LifecycleAsyncGate? = nil,
        sendUserMessageGate: LifecycleAsyncGate? = nil,
        shutdownGate: LifecycleAsyncGate? = nil,
        emittedAssistantTextOnSend: String? = nil,
        sessionID: String = "lifecycle-claude-session",
        promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention = .standard
    ) {
        self.recorder = recorder
        self.label = label
        activeSession = hasActiveSession
        turnInFlight = hasTurnInFlight
        self.failSend = failSend
        remainingApplyFailures = failApplyCount
        self.failStart = failStart
        self.failResumeStart = failResumeStart
        replacementAfterTerminalStartupFailure = requiresReplacementAfterTerminalStartupFailure
        self.startGate = startGate
        self.currentSessionRefGate = currentSessionRefGate
        self.eventsStreamReadyGate = eventsStreamReadyGate
        self.sendUserMessageGate = sendUserMessageGate
        self.shutdownGate = shutdownGate
        self.emittedAssistantTextOnSend = emittedAssistantTextOnSend
        self.sessionID = sessionID
        self.promptCacheRetention = promptCacheRetention
        var capturedContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            fatalError("Expected lifecycle native event continuation")
        }
        streamContinuation = capturedContinuation
    }

    var hasActiveSession: Bool {
        activeSession
    }

    var hasTurnInFlight: Bool {
        turnInFlight
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    var requiresReplacementAfterTerminalStartupFailure: Bool {
        replacementAfterTerminalStartupFailure
    }

    func ensureEventsStreamReady() async {
        if let eventsStreamReadyGate {
            recorder.record("\(label):events-ready")
            await eventsStreamReadyGate.arriveAndWait()
        }
    }

    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        recorder.record("\(label):start")
        recorder.record("\(label):start:\(effortLevel?.rawValue ?? "nil")")
        startExistingSessionIDs.append(existingSessionID)
        startEffortLevels.append(effortLevel)
        activeStartInvocationCount += 1
        maxConcurrentStartInvocationCount = max(
            maxConcurrentStartInvocationCount,
            activeStartInvocationCount
        )
        defer { activeStartInvocationCount -= 1 }
        let generationAtEntry = initializationGeneration
        let shouldInitialize = initializationGeneration == 0
            || !activeSession
            || forceInitializationOnNextStart
        forceInitializationOnNextStart = false
        if let startGate {
            await startGate.arriveAndWait()
        }
        if failResumeStart, existingSessionID != nil {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        if failStart {
            throw AIProviderError.invalidConfiguration(detail: "Expected configured startup failure")
        }
        if shouldInitialize {
            initializationGeneration &+= 1
        }
        activeSession = true
        return NativeAgentRuntimeSessionRef(
            sessionID: sessionID,
            promptCacheRetention: promptCacheRetention,
            initializationGeneration: initializationGeneration,
            initializedDuringCall: initializationGeneration != generationAtEntry
        )
    }

    func recordedStartExistingSessionIDs() -> [String?] {
        startExistingSessionIDs
    }

    func maximumConcurrentStartInvocationCount() -> Int {
        maxConcurrentStartInvocationCount
    }

    func emitAssistantText(_ text: String) {
        streamContinuation.yield(.stream(AIStreamResult(
            type: "assistant",
            text: text
        )))
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        if let currentSessionRefGate {
            recorder.record("\(label):current-ref")
            await currentSessionRefGate.arriveAndWait()
        }
        return NativeAgentRuntimeSessionRef(
            sessionID: sessionID,
            promptCacheRetention: promptCacheRetention,
            initializationGeneration: initializationGeneration,
            initializedDuringCall: false
        )
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        recorder.record("\(label):apply")
        recorder.record("\(label):apply:\(effortLevel?.rawValue ?? "nil")")
        appliedEffortLevels.append(effortLevel)
        if remainingApplyFailures > 0 {
            remainingApplyFailures -= 1
            throw AIProviderError.invalidConfiguration(detail: "Expected effort application failure")
        }
    }

    func setHasActiveSession(_ value: Bool) {
        activeSession = value
    }

    func setTurnInFlight(_ value: Bool) {
        turnInFlight = value
    }

    func setStartGate(_ gate: LifecycleAsyncGate?) {
        startGate = gate
    }

    func forceInitializationOnNextStartCall() {
        forceInitializationOnNextStart = true
    }

    func advanceInitializationGenerationUnobserved(
        effortLevel: NativeAgentRuntimeEffortLevel
    ) {
        recorder.record("\(label):unobserved-initialization:\(effortLevel.rawValue)")
        initializationGeneration &+= 1
        activeSession = true
    }

    func setEventsStreamReadyGate(_ gate: LifecycleAsyncGate?) {
        eventsStreamReadyGate = gate
    }

    func recordedStartEffortLevels() -> [NativeAgentRuntimeEffortLevel?] {
        startEffortLevels
    }

    func recordedAppliedEffortLevels() -> [NativeAgentRuntimeEffortLevel?] {
        appliedEffortLevels
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        recorder.record("\(label):send")
        if let sendUserMessageGate {
            await sendUserMessageGate.arriveAndWait()
        }
        if failSend {
            throw LifecycleTestError.expectedClaudeSendFailure
        }
        let turnID = UUID()
        if let emittedAssistantTextOnSend {
            streamContinuation.yield(.stream(AIStreamResult(
                type: "assistant",
                text: emittedAssistantTextOnSend
            )))
            pendingTurnCompletionID = turnID
            let waiters = pendingTurnCompletionWaiters
            pendingTurnCompletionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: turnID)
            }
        }
        return turnID
    }

    func waitForPendingTurnCompletion() async -> UUID {
        if let pendingTurnCompletionID {
            return pendingTurnCompletionID
        }
        return await withCheckedContinuation { continuation in
            pendingTurnCompletionWaiters.append(continuation)
        }
    }

    func emitPendingTurnCompletion() {
        guard let turnID = pendingTurnCompletionID else { return }
        pendingTurnCompletionID = nil
        streamContinuation.yield(.turnCompleted(turnID: turnID, status: .completed))
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        recorder.record("\(label):interrupt:\(reason)")
        return .noTurnInFlight
    }

    func shutdown() async {
        recorder.record("\(label):shutdown")
        if let shutdownGate {
            await shutdownGate.arriveAndWait()
        }
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {}
}
