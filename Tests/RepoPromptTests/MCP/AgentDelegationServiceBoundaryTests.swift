import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Service-level bounded-delegation boundaries: routed callers are re-admitted at commit/dispatch,
/// routed creates never orphan, adoption never invalidates a delegated subtree, and delegated
/// workers cannot control or read sessions that are not deeper than themselves.
@MainActor
final class AgentDelegationServiceBoundaryTests: XCTestCase {
    func testWorkerControlOperationsCannotAddressItselfOrShallowerSessions() async throws {
        try await withFixture { fixture in
            let run = makeRunService(fixture, sourceTabID: fixture.worker.tabID)
            for op in ["cancel", "respond"] {
                await assertInvalidParams(contains: "may only target sessions deeper", label: "\(op) main") {
                    _ = try await run.execute(args: controlArgs(op, fixture.main.sessionID))
                }
                await assertInvalidParams(contains: "may only target sessions deeper", label: "\(op) sibling") {
                    _ = try await run.execute(args: controlArgs(op, fixture.sibling.sessionID))
                }
                await assertInvalidParams(contains: "cannot target the calling agent session itself", label: "\(op) self") {
                    _ = try await run.execute(args: controlArgs(op, fixture.worker.sessionID))
                }
            }
            // The worker's own sub-worker passes the delegation gate (and fails later for having no run).
            do {
                _ = try await run.execute(args: controlArgs("cancel", fixture.subWorker.sessionID))
            } catch {
                XCTAssertFalse(String(describing: error).contains("deeper in the delegation tree"), String(describing: error))
                XCTAssertFalse(String(describing: error).contains("calling agent session itself"), String(describing: error))
            }

            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: { fixture.worker.sessionID })
            for op in ["stop_session", "get_log"] {
                await assertInvalidParams(contains: "may only target sessions deeper", label: op) {
                    _ = try await manage.execute(args: [
                        "op": .string(op),
                        "session_id": .string(fixture.main.sessionID.uuidString)
                    ])
                }
            }
            let cleanup = try await manage.execute(args: [
                "op": .string("cleanup_sessions"),
                "session_ids": .array([
                    .string(fixture.main.sessionID.uuidString),
                    .string(fixture.subWorker.sessionID.uuidString)
                ])
            ])
            let skipped = try XCTUnwrap(cleanup.objectValue?["skipped_sessions"]?.arrayValue)
            let reasons = Dictionary(uniqueKeysWithValues: skipped.compactMap(\.objectValue).compactMap { entry -> (String, String)? in
                guard let id = entry["session_id"]?.stringValue, let reason = entry["reason"]?.stringValue else { return nil }
                return (id, reason)
            })
            XCTAssertEqual(reasons[fixture.main.sessionID.uuidString], "outside_delegation_scope")
            XCTAssertNotEqual(reasons[fixture.subWorker.sessionID.uuidString], "outside_delegation_scope")
            XCTAssertNotNil(fixture.viewModel.sessions[fixture.main.tabID], "Cleanup must not delete an ancestor")

            // Main (depth 0) keeps its existing session-addressed control.
            let mainManage = makeManageService(fixture, sourceTabID: fixture.main.tabID, parentSessionID: { fixture.main.sessionID })
            let stopped = try await mainManage.execute(args: [
                "op": .string("stop_session"),
                "session_id": .string(fixture.worker.sessionID.uuidString)
            ])
            XCTAssertEqual(stopped.objectValue?["session_id"]?.stringValue, fixture.worker.sessionID.uuidString)
        }
    }

    func testCreateSessionRefusesRoutedCallerWithoutResolvedParent() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: { nil })
            await assertInvalidParams(contains: "Refusing to create an unparented session", label: "create_session") {
                _ = try await manage.execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
        }
    }

    func testCreateSessionRevalidatesCallerLineageAtCommitAndRollsBackCreatedTab() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            let sessionCountBefore = fixture.viewModel.sessions.count
            // The caller's lineage changes while parent resolution is suspended: the worker's root
            // is placed under another session, so the admitted depth-1 worker is now depth 2.
            let manage = makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: {
                fixture.main.session.parentSessionID = fixture.otherRoot.sessionID
                return fixture.worker.sessionID
            })
            await assertInvalidParams(contains: "delegation depth 2", label: "create_session") {
                _ = try await manage.execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore, "The created tab is discarded")
            XCTAssertEqual(fixture.viewModel.sessions.count, sessionCountBefore)
            XCTAssertEqual(
                fixture.viewModel.sessions.values.count(where: { $0.parentSessionID == fixture.worker.sessionID }),
                1,
                "Only the pre-existing sub-worker is parented to the worker"
            )
        }
    }

    func testResumeRejectsAdoptingRootWithDelegatedChildren() async throws {
        try await withFixture { fixture in
            let manage = makeManageService(fixture, sourceTabID: fixture.main.tabID, parentSessionID: { fixture.main.sessionID })
            await assertInvalidParams(contains: "already has delegated child sessions", label: "resume_session") {
                _ = try await manage.execute(args: [
                    "op": .string("resume_session"),
                    "session_id": .string(fixture.otherRoot.sessionID.uuidString)
                ])
            }
            XCTAssertNil(fixture.otherRoot.session.parentSessionID)
            XCTAssertEqual(
                fixture.viewModel.mcpDelegationLineage(for: fixture.otherRootChild.session),
                .resolved(depth: 1)
            )
        }
    }

    func testSteerRevalidatesCallerBeforeDispatch() async throws {
        try await withFixture { fixture in
            var run = makeRunService(fixture, sourceTabID: fixture.worker.tabID)
            var dispatched = false
            run.resolveWaitPolicyContext = { metadata in
                // Lineage changes after admission, while the steer request is suspended.
                fixture.main.session.parentSessionID = fixture.otherRoot.sessionID
                return AgentMCPWaitPolicy.RequestContext.unresolved(metadata: metadata)
            }
            run.testDispatchSteerInstruction = { _, _, _, _ in
                dispatched = true
                throw MCPError.internalError("dispatch must not run")
            }
            await assertInvalidParams(contains: "delegation depth 2", label: "steer") {
                _ = try await run.execute(args: [
                    "op": .string("steer"),
                    "session_id": .string(fixture.subWorker.sessionID.uuidString),
                    "message": .string("continue"),
                    "wait": .bool(true)
                ])
            }
            XCTAssertFalse(dispatched)
        }
    }

    func testCreateAndResumeRejectReplacementCallerBoundDuringParentResolution() async throws {
        try await withFixture { fixture in
            let tabsBefore = composeTabIDs(fixture)
            /// The admitted worker's tab is rebound to a different, still-eligible identity while the
            /// parent is resolved; the resolver then reports that replacement identity.
            @MainActor func rebindingService() -> AgentManageMCPToolService {
                makeManageService(fixture, sourceTabID: fixture.worker.tabID, parentSessionID: {
                    let replacementID = UUID()
                    fixture.worker.session.testInstallPersistentSessionBinding(sessionID: replacementID)
                    return replacementID
                })
            }
            await assertInvalidParams(contains: "changed while its parent was being resolved", label: "create_session") {
                _ = try await rebindingService().execute(args: ["op": .string("create_session")])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)

            fixture.worker.session.testInstallPersistentSessionBinding(sessionID: fixture.worker.sessionID)
            await assertInvalidParams(contains: "changed while its parent was being resolved", label: "resume_session") {
                _ = try await rebindingService().execute(args: [
                    "op": .string("resume_session"),
                    "session_id": .string(fixture.subWorker.sessionID.uuidString)
                ])
            }
            XCTAssertEqual(composeTabIDs(fixture), tabsBefore)
        }
    }

    func testCancelRevalidatesCallerScopeAtMutationBoundaryAfterAllowedAdoption() async throws {
        try await withFixture { fixture in
            let target = fixture.otherRoot
            target.session.mcpControlContext = controlContext(sessionID: target.sessionID, role: nil)
            target.session.runState = .running
            defer { target.session.runState = .idle }
            let adoption = AdoptionProbe()
            // A childless depth-0 caller passes cancel admission for another root, then is adopted
            // under main (allowed: it has no children) while cancellation is suspended.
            var run = makeRunService(fixture, sourceTabID: fixture.loneRoot.tabID, beforeHeartbeatOperation: {
                fixture.viewModel.applySpawnParentSessionID(fixture.main.sessionID, to: fixture.loneRoot.session)
                adoption.didAdopt = true
            })
            run.currentSnapshotProvider = { sessionID, _ in
                Self.runningSnapshot(sessionID: sessionID)
            }
            await assertInvalidParams(contains: "may only target sessions deeper", label: "cancel") {
                _ = try await run.execute(args: controlArgs("cancel", target.sessionID))
            }
            XCTAssertTrue(adoption.didAdopt, "The denial comes from the mutation-boundary recheck, after admission")
            XCTAssertEqual(fixture.loneRoot.session.parentSessionID, fixture.main.sessionID)
            XCTAssertEqual(target.session.runState, .running, "The root's run is not cancelled")
        }
    }

    func testExplicitTabParentMustMatchReconciledParentWhileRestorationSucceeds() async throws {
        try await withFixture { fixture in
            // The sibling's own live record lost its parent, but another live record bound to the
            // same identity still claims main, and the sibling has a delegated child.
            let sibling = fixture.sibling
            sibling.session.parentSessionID = nil
            let duplicate = try await makeExtraSession(fixture)
            duplicate.testInstallPersistentSessionBinding(sessionID: sibling.sessionID)
            duplicate.parentSessionID = fixture.main.sessionID
            duplicate.hasLoadedPersistedState = true
            let siblingChild = try await makeExtraSession(fixture)
            siblingChild.testInstallPersistentSessionBinding(sessionID: UUID())
            siblingChild.parentSessionID = sibling.sessionID
            siblingChild.hasLoadedPersistedState = true
            XCTAssertEqual(fixture.viewModel.mcpDelegationParentLookup(sessionID: sibling.sessionID), .parent(fixture.main.sessionID))

            await assertInvalidParams(contains: "different or conflicting parent", label: "conflicting parent") {
                _ = try await fixture.viewModel.mcpResolveOrCreateSessionTarget(
                    tabID: sibling.tabID,
                    sessionID: nil,
                    createIfNeeded: false,
                    sessionName: nil,
                    parentSessionID: fixture.otherRoot.sessionID
                )
            }
            XCTAssertNil(sibling.session.parentSessionID)

            // Restoring the reconciled parent changes no depth, so it is not subtree adoption.
            _ = try await fixture.viewModel.mcpResolveOrCreateSessionTarget(
                tabID: sibling.tabID,
                sessionID: nil,
                createIfNeeded: false,
                sessionName: nil,
                parentSessionID: fixture.main.sessionID
            )
            XCTAssertEqual(sibling.session.parentSessionID, fixture.main.sessionID)
            XCTAssertEqual(fixture.viewModel.mcpDelegationLineage(for: siblingChild), .resolved(depth: 2))
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class AdoptionProbe {
        var didAdopt = false
    }

    private struct Node {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let main: Node
        let worker: Node
        let sibling: Node
        let subWorker: Node
        let otherRoot: Node
        let otherRootChild: Node
        let loneRoot: Node
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDelegationServiceBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()
        do {
            try await runFixture(window: window, rootURL: rootURL, body)
        } catch {
            await teardown(window: window, rootURL: rootURL)
            throw error
        }
        await teardown(window: window, rootURL: rootURL)
    }

    private func teardown(window: WindowState, rootURL: URL) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func runFixture(
        window: WindowState,
        rootURL: URL,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let workspace = window.workspaceManager.createWorkspace(
            name: "Delegation Boundary \(UUID().uuidString.prefix(8))",
            repoPaths: [rootURL.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "agentDelegationServiceBoundaryTests")

        let names = ["Main", "Worker", "Sibling", "SubWorker", "OtherRoot", "OtherRootChild", "LoneRoot"]
        let ids = names.map { _ in (tabID: UUID(), sessionID: UUID()) }
        let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))
        window.workspaceManager.workspaces[workspaceIndex].composeTabs = zip(names, ids).map { name, id in
            ComposeTabState(id: id.tabID, name: name, activeAgentSessionID: id.sessionID)
        }
        window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = ids[0].tabID
        window.promptManager.loadComposeTabsFromWorkspace(window.workspaceManager.workspaces[workspaceIndex], syncPromptText: true)

        let viewModel = window.agentModeViewModel
        func node(_ index: Int, parent: Node?, role: AgentModelCatalog.TaskLabelKind?) throws -> Node {
            let id = ids[index]
            let session = try XCTUnwrap(viewModel.session(for: id.tabID, createIfNeeded: true))
            XCTAssertEqual(session.activeAgentSessionID, id.sessionID)
            session.hasLoadedPersistedState = true
            session.parentSessionID = parent?.sessionID
            if parent != nil {
                session.mcpControlContext = controlContext(sessionID: id.sessionID, role: role)
            }
            return Node(tabID: id.tabID, sessionID: id.sessionID, session: session)
        }
        let main = try node(0, parent: nil, role: nil)
        let worker = try node(1, parent: main, role: .engineer)
        let sibling = try node(2, parent: main, role: .engineer)
        let subWorker = try node(3, parent: worker, role: .engineer)
        let otherRoot = try node(4, parent: nil, role: nil)
        let otherRootChild = try node(5, parent: otherRoot, role: .engineer)
        let loneRoot = try node(6, parent: nil, role: nil)
        viewModel.setAgentModeActive(true)

        XCTAssertEqual(viewModel.mcpDelegationLineage(for: worker.session), .resolved(depth: 1))
        XCTAssertEqual(viewModel.mcpDelegationLineage(for: subWorker.session), .resolved(depth: 2))

        try await body(Fixture(
            window: window,
            rootURL: rootURL,
            viewModel: viewModel,
            main: main,
            worker: worker,
            sibling: sibling,
            subWorker: subWorker,
            otherRoot: otherRoot,
            otherRootChild: otherRootChild,
            loneRoot: loneRoot
        ))
    }

    private func controlContext(sessionID: UUID, role: AgentModelCatalog.TaskLabelKind?) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(sessionID: sessionID, generation: 0),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: false,
            taskLabelKind: role
        )
    }

    private func metadata(_ window: WindowState) -> MCPServerViewModel.RequestMetadata {
        MCPServerViewModel.RequestMetadata(
            connectionID: nil,
            clientName: "agent-delegation-boundary-tests",
            windowID: window.windowID
        )
    }

    private func makeManageService(
        _ fixture: Fixture,
        sourceTabID: UUID?,
        parentSessionID: @escaping () -> UUID?
    ) -> AgentManageMCPToolService {
        let window = fixture.window
        return AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { self.metadata(window) },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in parentSessionID() },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }

    private func makeRunService(
        _ fixture: Fixture,
        sourceTabID: UUID?,
        beforeHeartbeatOperation: (@MainActor @Sendable () -> Void)? = nil
    ) -> AgentRunMCPToolService {
        let window = fixture.window
        return AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { self.metadata(window) },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in
                if let beforeHeartbeatOperation {
                    await MainActor.run { beforeHeartbeatOperation() }
                }
                return try await operation()
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun is not used by delegation boundary tests")
            }
        )
    }

    private nonisolated static func runningSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: nil,
            tabID: nil,
            sessionName: "Running Root",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .running,
            statusText: "running",
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            lastInteractionResolution: nil
        )
    }

    private func controlArgs(_ op: String, _ sessionID: UUID) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string(op),
            "session_id": .string(sessionID.uuidString)
        ]
        if op == "respond" {
            args["interaction_id"] = .string(UUID().uuidString)
            args["answer"] = .string("yes")
        }
        return args
    }

    private func makeExtraSession(_ fixture: Fixture) async throws -> AgentModeViewModel.TabSession {
        await fixture.window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await fixture.viewModel.ensureSessionReady(tabID: tabID)
    }

    private func composeTabIDs(_ fixture: Fixture) -> Set<UUID> {
        Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
    }

    private func assertInvalidParams(
        contains expected: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(label): expected an error containing \"\(expected)\"", file: file, line: line)
        } catch {
            XCTAssertTrue(String(describing: error).contains(expected), "\(label): \(error)", file: file, line: line)
        }
    }
}
