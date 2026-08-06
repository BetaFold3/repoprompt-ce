import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
extension AgentModeRunServiceLifecycleTests {
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

    func testSupersedingEnsureShutsDownTrackedPrivateFallbackBeforeStartupReturns() async {
        let recorder = LifecycleRecorder()
        let privateStartupGate = LifecycleAsyncGate()
        let privateShutdownGate = LifecycleAsyncGate()
        let retiredController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "retired-before-private-supersession",
            failResumeStart: true
        )
        let privateReplacement = LifecycleFakeNativeController(
            recorder: recorder,
            label: "private-superseded-before-startup-return",
            startGate: privateStartupGate,
            shutdownGate: privateShutdownGate,
            sessionID: "private-superseded-provider-session"
        )
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-after-private-supersession",
            sessionID: "successor-after-private-supersession-session"
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
        session.providerSessionID = "provider-session-before-private-supersession"
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

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)
        await privateShutdownGate.waitUntilArrived()

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the successor controller before private startup returned")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(successorController as AnyObject)
        )
        XCTAssertEqual(
            session.providerSessionID,
            "successor-after-private-supersession-session"
        )
        XCTAssertFalse(
            harness.host.claudeCoordinator.test_hasTrackedPrivateFallbackController(for: session)
        )
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))
        XCTAssertTrue(recorder.contains("private-superseded-before-startup-return:shutdown"))

        await privateShutdownGate.release()
        await privateStartupGate.release()
        await firstEnsureTask.value

        XCTAssertEqual(
            recorder.events.count {
                $0 == "private-superseded-before-startup-return:shutdown"
            },
            1
        )
        XCTAssertFalse(recorder.contains("successor-after-private-supersession:shutdown"))
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

    func testConcurrentEnsureSupersedesPrivateFallbackStartupWithoutConcurrentControllerStart() async {
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
        let successorController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "successor-replacement",
            sessionID: "successor-provider-session"
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

        await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session)

        guard let installedBeforePrivateStartupReturns = session.claudeController else {
            return XCTFail("Expected the concurrent ensure to install its successor controller")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedBeforePrivateStartupReturns as AnyObject),
            ObjectIdentifier(successorController as AnyObject)
        )
        XCTAssertEqual(session.providerSessionID, "successor-provider-session")
        XCTAssertNil(session.pendingHandoff.payload)
        XCTAssertFalse(harness.host.claudeCoordinator.test_hasFallbackReplacementClaim(for: session))

        await freshStartupGate.release()
        await firstEnsureTask.value

        guard let installedController = session.claudeController else {
            return XCTFail("Expected the successor controller to remain installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(installedController as AnyObject),
            ObjectIdentifier(successorController as AnyObject)
        )
        XCTAssertEqual(factoryInvocationCount, 2)
        XCTAssertEqual(session.providerSessionID, "successor-provider-session")
        XCTAssertNil(session.pendingHandoff.payload)
        let privateStartSessionIDs = await privateReplacement.recordedStartExistingSessionIDs()
        let successorStartSessionIDs = await successorController.recordedStartExistingSessionIDs()
        let privateMaximumConcurrentStarts = await privateReplacement.maximumConcurrentStartInvocationCount()
        let successorMaximumConcurrentStarts = await successorController.maximumConcurrentStartInvocationCount()
        XCTAssertEqual(privateStartSessionIDs, [nil])
        XCTAssertEqual(successorStartSessionIDs, ["provider-session-to-resume"])
        XCTAssertEqual(privateMaximumConcurrentStarts, 1)
        XCTAssertEqual(successorMaximumConcurrentStarts, 1)
        XCTAssertTrue(recorder.contains("private-replacement:shutdown"))
        XCTAssertFalse(recorder.contains("successor-replacement:shutdown"))
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
    private let turnInFlight: Bool
    private let failSend: Bool
    private let failStart: Bool
    private let failResumeStart: Bool
    private let replacementAfterTerminalStartupFailure: Bool
    private let startGate: LifecycleAsyncGate?
    private let currentSessionRefGate: LifecycleAsyncGate?
    private let eventsStreamReadyGate: LifecycleAsyncGate?
    private let sendUserMessageGate: LifecycleAsyncGate?
    private let shutdownGate: LifecycleAsyncGate?
    private let emittedAssistantTextOnSend: String?
    private let sessionRef: NativeAgentRuntimeSessionRef
    private let stream: AsyncStream<NativeAgentRuntimeEvent>
    private let streamContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation
    private var startExistingSessionIDs: [String?] = []
    private var activeStartInvocationCount = 0
    private var maxConcurrentStartInvocationCount = 0
    private var pendingTurnCompletionID: UUID?
    private var pendingTurnCompletionWaiters: [CheckedContinuation<UUID, Never>] = []

    init(
        recorder: LifecycleRecorder,
        label: String = "claude",
        hasTurnInFlight: Bool = false,
        failSend: Bool = false,
        failStart: Bool = false,
        failResumeStart: Bool = false,
        requiresReplacementAfterTerminalStartupFailure: Bool = false,
        startGate: LifecycleAsyncGate? = nil,
        currentSessionRefGate: LifecycleAsyncGate? = nil,
        eventsStreamReadyGate: LifecycleAsyncGate? = nil,
        sendUserMessageGate: LifecycleAsyncGate? = nil,
        shutdownGate: LifecycleAsyncGate? = nil,
        emittedAssistantTextOnSend: String? = nil,
        sessionID: String = "lifecycle-claude-session"
    ) {
        self.recorder = recorder
        self.label = label
        turnInFlight = hasTurnInFlight
        self.failSend = failSend
        self.failStart = failStart
        self.failResumeStart = failResumeStart
        replacementAfterTerminalStartupFailure = requiresReplacementAfterTerminalStartupFailure
        self.startGate = startGate
        self.currentSessionRefGate = currentSessionRefGate
        self.eventsStreamReadyGate = eventsStreamReadyGate
        self.sendUserMessageGate = sendUserMessageGate
        self.shutdownGate = shutdownGate
        self.emittedAssistantTextOnSend = emittedAssistantTextOnSend
        sessionRef = NativeAgentRuntimeSessionRef(sessionID: sessionID)
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
        true
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
        startExistingSessionIDs.append(existingSessionID)
        activeStartInvocationCount += 1
        maxConcurrentStartInvocationCount = max(
            maxConcurrentStartInvocationCount,
            activeStartInvocationCount
        )
        defer { activeStartInvocationCount -= 1 }
        if let startGate {
            await startGate.arriveAndWait()
        }
        if failResumeStart, existingSessionID != nil {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        if failStart {
            throw AIProviderError.invalidConfiguration(detail: "Expected configured startup failure")
        }
        return sessionRef
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
        return sessionRef
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {}

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
