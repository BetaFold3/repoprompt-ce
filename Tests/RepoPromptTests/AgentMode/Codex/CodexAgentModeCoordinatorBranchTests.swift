import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexAgentModeCoordinatorBranchTests: XCTestCase {
    func testTabSessionBranchOriginRoundTripsThroughCodexPersistenceSync() {
        let viewModel = makeViewModel()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        let origin = AgentSessionBranchOrigin(
            rootSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceTurnID: UUID(),
            sourceCodexTurnID: "turn",
            sourceTurnOrdinal: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        session.branchOrigin = origin
        session.codexConversationID = "child"
        session.codexTurnCheckpoints = CodexTurnCheckpointLedger(threadID: "child")

        var persisted = AgentSession()
        persisted.branchOrigin = session.branchOrigin
        viewModel.test_codexCoordinator.applyCodexPersistence(from: session, to: &persisted)

        let restored = AgentModeViewModel.TabSession(tabID: UUID())
        restored.selectedAgent = .codexExec
        restored.branchOrigin = persisted.branchOrigin
        viewModel.test_codexCoordinator.restoreCodexMetadata(from: persisted, session: restored)

        XCTAssertEqual(restored.branchOrigin, origin)
        XCTAssertEqual(restored.codexConversationID, "child")
        XCTAssertEqual(restored.codexTurnCheckpoints?.threadID, "child")
    }

    func testBranchOperationGuardBlocksOptimisticSend() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.isBranchOperationInProgress = true
        session.draftText = "preserved"

        let result = viewModel.submitUserTurn(text: "message", tabID: tabID)

        guard case let .blocked(message) = result else {
            return XCTFail("Expected submission to be blocked")
        }
        XCTAssertEqual(message, "Finish branching before sending another message.")
        XCTAssertEqual(session.draftText, "preserved")
        XCTAssertTrue(session.items.isEmpty)
    }

    func testBranchGuardBlocksSteerHandoffLoadCloseAndMCPSessionAccessAtCentralOwners() async throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let sessionID = UUID()
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        let assistant = AgentChatItem.assistant("answer", sequenceIndex: 1)
        session.items = [.user("question", sequenceIndex: 0), assistant]
        let handoffConfig = try XCTUnwrap(
            viewModel.makeHandoffConfig(for: assistant.id, sourceTabID: tabID, windowID: -1)
        )

        session.runState = .running
        session.isBranchOperationInProgress = true
        session.draftText = "steer draft"
        XCTAssertEqual(
            viewModel.submitUserTurn(text: "steer", tabID: tabID),
            .blocked(message: "Finish branching before sending another message.")
        )
        XCTAssertEqual(session.draftText, "steer draft")
        XCTAssertEqual(session.items.count, 2)

        session.hasLoadedPersistedState = false
        _ = await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertFalse(session.hasLoadedPersistedState)

        await viewModel.deleteSession(tabID: tabID)
        XCTAssertTrue(viewModel.session(for: tabID) === session)

        XCTAssertThrowsError(try viewModel.requireLiveAgentSession(sessionID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("branch_operation_in_progress"))
        }

        do {
            _ = try await handoffConfig.buildPayloadForClipboard()
            XCTFail("Expected guarded handoff rejection")
        } catch AgentHandoffConfigurationError.sourceUnavailable {}
    }

    func testSwitchRejectsTargetBoundToAnotherTabWithoutStealingBinding() async {
        let viewModel = makeViewModel()
        let sourceTabID = UUID()
        let targetTabID = UUID()
        let sourceID = UUID()
        let targetID = UUID()
        let source = viewModel.session(for: sourceTabID)
        let target = viewModel.session(for: targetTabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sourceID, on: source)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: targetID, on: target)
        source.selectedAgent = .codexExec
        source.codexConversationID = "source"
        source.runState = .idle

        do {
            try await viewModel.switchToBranch(sessionID: targetID, tabID: sourceTabID)
            XCTFail("Expected target-open rejection")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .targetOpenElsewhere)
        }

        XCTAssertEqual(source.activeAgentSessionID, sourceID)
        XCTAssertEqual(target.activeAgentSessionID, targetID)
        XCTAssertFalse(source.isBranchOperationInProgress)
    }

    func testBranchFromTurnOrdersVerificationBeforePersistedRestoreAndPreservesDraftWithoutSending() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }

        fixture.controller.forkConversationID = "  child  "
        let childID = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)

        XCTAssertEqual(
            fixture.controller.operations,
            [
                "list:source",
                "fork:source-1",
                "list:child",
                "list:source",
                "shutdown"
            ]
        )
        XCTAssertEqual(fixture.controller.startedTurnCount, 0)
        XCTAssertEqual(fixture.session.activeAgentSessionID, childID)
        XCTAssertEqual(fixture.session.codexConversationID, "child")
        XCTAssertEqual(fixture.session.codexTurnCheckpoints?.threadID, "child")
        XCTAssertEqual(fixture.session.codexTurnCheckpoints?.threadID, fixture.session.codexConversationID)
        XCTAssertEqual(fixture.session.branchOrigin?.sourceSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.branchOrigin?.sourceTurnID, fixture.sourceTurnID)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertEqual(fixture.session.items.count(where: { $0.kind == .user }), 1)
        XCTAssertTrue(fixture.session.items.contains { $0.kind == .system && $0.text.contains("Branched from") })
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testMissingOracleAuthorityFailsClosedBeforeBranching() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.viewModel.test_oracleBranchOccupancyOverride = nil

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected missing Oracle authority to block branching")
        } catch {
            XCTAssertEqual(
                error as? CodexBranchOperationError,
                .unavailable(.notIdle)
            )
        }

        XCTAssertTrue(fixture.controller.operations.isEmpty)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testBranchOperationRevalidatesPinAfterAwaitAndRejectsSourceMutationRace() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.controller.onFirstList = {
            fixture.session.appendItem(.system("concurrent mutation"))
        }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected stale-operation rejection")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .staleOperation)
        }

        XCTAssertEqual(fixture.controller.operations, ["list:source"])
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.codexConversationID, "source")
        XCTAssertTrue(fixture.controller.hasActiveThread)
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testConfirmationRejectsSameTurnRebindBeforeForkSubmission() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let pin = try XCTUnwrap(AgentModeViewModel.ReplyBranchConfirmationPin(
            workspaceID: fixture.workspaceID,
            session: fixture.session,
            turnID: fixture.sourceTurnID
        ))
        fixture.viewModel.test_setLastKnownWorkspaceSnapshot(WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory,
            composeTabs: [ComposeTabState(id: fixture.tabID, name: "Agent")],
            activeComposeTabID: fixture.tabID
        ))
        XCTAssertTrue(pin.matches(
            workspaceID: fixture.workspaceID,
            tabID: fixture.tabID,
            session: fixture.session,
            turnID: fixture.sourceTurnID
        ))

        _ = fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(),
            on: fixture.session
        )
        _ = fixture.viewModel.test_installPersistentSessionBinding(
            sessionID: fixture.sourceSessionID,
            on: fixture.session
        )
        XCTAssertFalse(pin.matches(
            workspaceID: fixture.workspaceID,
            tabID: fixture.tabID,
            session: fixture.session,
            turnID: fixture.sourceTurnID
        ))

        do {
            _ = try await fixture.viewModel.branchFromTurn(
                fixture.sourceTurnID,
                tabID: fixture.tabID,
                confirmationPin: pin
            )
            XCTFail("Expected stale-confirmation rejection")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .staleConfirmation)
            XCTAssertEqual(
                error.localizedDescription,
                "This branch confirmation is stale. Cancel and reopen it."
            )
        }

        XCTAssertTrue(fixture.controller.operations.isEmpty)
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testPostForkVerificationFailureArchivesKnownChildAndKeepsSourceBound() async throws {
        let fixture = try await makeBranchFixture(childTurns: [])
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected structural verification failure")
        } catch {
            XCTAssertEqual(
                error as? CodexForkStructuralVerificationError,
                .childTurnCountMismatch(expected: 1, actual: 0)
            )
        }

        XCTAssertEqual(
            fixture.controller.operations,
            ["list:source", "fork:source-1", "list:child", "archive:child"]
        )
        XCTAssertEqual(fixture.controller.startedTurnCount, 0)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.codexConversationID, "source")
        XCTAssertTrue(fixture.controller.hasActiveThread)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testSuccessfulSameTabSwitchPreservesSessionObjectDraftAndRestoresTargetWithoutSending() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let targetID = UUID()
        let origin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        let target = AgentSession(
            id: targetID,
            workspaceID: fixture.workspaceID,
            name: "Target branch",
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            autoEditEnabled: true,
            codexConversationID: "target-thread",
            codexTurnCheckpoints: CodexTurnCheckpointLedger(threadID: "target-thread"),
            branchOrigin: origin
        )
        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        _ = try await fixture.viewModel.test_dataService.saveAgentSession(
            target,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let originalObject = fixture.session

        try await fixture.viewModel.switchToBranch(sessionID: targetID, tabID: fixture.tabID)

        XCTAssertTrue(fixture.session === originalObject)
        XCTAssertEqual(fixture.session.activeAgentSessionID, targetID)
        XCTAssertEqual(fixture.session.branchOrigin, origin)
        XCTAssertEqual(fixture.session.codexConversationID, "target-thread")
        XCTAssertEqual(fixture.session.codexTurnCheckpoints?.threadID, "target-thread")
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertEqual(fixture.controller.startedTurnCount, 0)
        XCTAssertEqual(fixture.controller.operations, ["shutdown"])
    }

    func testSwitchRechecksOwnershipAtCommitAndDoesNotStealLateBinding() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let targetID = UUID()
        let otherTabID = UUID()
        let origin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        let target = AgentSession(
            id: targetID,
            workspaceID: fixture.workspaceID,
            name: "Target branch",
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            autoEditEnabled: true,
            codexConversationID: "target-thread",
            codexTurnCheckpoints: CodexTurnCheckpointLedger(threadID: "target-thread"),
            branchOrigin: origin
        )
        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        _ = try await fixture.viewModel.test_dataService.saveAgentSession(
            target,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let otherSession = fixture.viewModel.session(for: otherTabID)
        fixture.viewModel.test_branchFailureInjector = { step in
            guard step == "switchBeforeRebind" else { return nil }
            _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: targetID, on: otherSession)
            return nil
        }

        do {
            try await fixture.viewModel.switchToBranch(sessionID: targetID, tabID: fixture.tabID)
            XCTFail("Expected target-open rejection at binding commit")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .targetOpenElsewhere)
        }

        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(otherSession.activeAgentSessionID, targetID)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testSourceSaveFailureLeavesRootBoundAndControllerUntouched() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.viewModel.test_branchFailureInjector = {
            $0 == "sourceSave" ? BranchInjectedFailure.sourceSave : nil
        }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected source-save failure")
        } catch {
            XCTAssertEqual(error as? BranchInjectedFailure, .sourceSave)
        }

        XCTAssertTrue(fixture.controller.operations.isEmpty)
        XCTAssertTrue(fixture.controller.hasActiveThread)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testForkCodedAndAmbiguousFailuresLeaveRootBoundWithoutArchiving() async throws {
        let errors: [CodexNativeSessionController.ThreadPrimitiveError] = [
            .invalidResponse,
            .ambiguousForkOutcome("timeout")
        ]
        for expected in errors {
            let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
            defer { fixture.cleanup() }
            fixture.controller.forkError = expected

            do {
                _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
                XCTFail("Expected fork failure")
            } catch {
                XCTAssertEqual(error as? CodexNativeSessionController.ThreadPrimitiveError, expected)
            }

            XCTAssertEqual(fixture.controller.operations, ["list:source", "fork:source-1"])
            XCTAssertTrue(fixture.controller.hasActiveThread)
            XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
            XCTAssertFalse(fixture.session.isBranchOperationInProgress)
        }
    }

    func testInvalidPersistedBranchPrefixAbortsBeforeProviderFork() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        guard var persistedSource = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        ) else {
            return XCTFail("Expected persisted source")
        }
        persistedSource.items = []
        persistedSource.transcript = .empty
        persistedSource.itemCount = 0
        _ = try await fixture.viewModel.test_dataService.saveAgentSession(
            persistedSource,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        fixture.session.isDirty = false

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected invalid persisted prefix")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .sourceSessionMissing)
        }

        XCTAssertEqual(fixture.controller.operations, ["list:source"])
        XCTAssertFalse(fixture.controller.operations.contains { $0.hasPrefix("fork:") })
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
    }

    func testBlankOrSourceForkIdentityIsNeverArchived() async throws {
        for (forkID, expectedError) in [
            ("   ", CodexForkStructuralVerificationError.invalidChildThreadID),
            ("source", CodexForkStructuralVerificationError.childMatchesSource)
        ] {
            let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
            defer { fixture.cleanup() }
            fixture.controller.forkConversationID = forkID

            do {
                _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
                XCTFail("Expected invalid fork identity")
            } catch {
                XCTAssertEqual(error as? CodexForkStructuralVerificationError, expectedError)
            }

            XCTAssertEqual(fixture.controller.operations, ["list:source", "fork:source-1"])
            XCTAssertFalse(fixture.controller.operations.contains { $0.hasPrefix("archive:") })
            XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
            XCTAssertEqual(fixture.session.codexConversationID, "source")
        }
    }

    func testDirtySourceIsCommittedBeforeFork() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let marker = "dirty source write-first marker"
        fixture.session.appendItem(.system(marker))
        fixture.session.isDirty = true

        _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)

        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        let loadedSource = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        )
        let persistedSource = try XCTUnwrap(loadedSource)
        XCTAssertTrue(persistedSource.items.contains { $0.text == marker })
        XCTAssertTrue(fixture.controller.operations.contains("fork:source-1"))
    }

    func testBranchRestoreFailureAfterRebindRollsBackToSourceAndKeepsPersistedChild() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.viewModel.test_branchFailureInjector = {
            $0 == "restoreAfterRebind" ? BranchInjectedFailure.restore : nil
        }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected post-rebind restore failure")
        } catch {
            XCTAssertEqual(error as? BranchInjectedFailure, .restore)
        }

        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        let tree = await fixture.viewModel.test_dataService.agentSessionBranchTree(
            containing: fixture.sourceSessionID,
            for: workspace
        )
        XCTAssertTrue(tree.requiresExactResume)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.codexConversationID, "source")
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
        XCTAssertFalse(fixture.controller.operations.contains("archive:child"))
    }

    func testBranchFileSaveFailureArchivesChildAndLeavesRootLive() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.viewModel.test_branchFailureInjector = {
            $0 == "branchSave" ? BranchInjectedFailure.branchSave : nil
        }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected branch-save failure")
        } catch {
            XCTAssertEqual(error as? BranchInjectedFailure, .branchSave)
        }

        XCTAssertEqual(
            fixture.controller.operations,
            ["list:source", "fork:source-1", "list:child", "list:source", "archive:child"]
        )
        XCTAssertTrue(fixture.controller.hasActiveThread)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
    }

    func testRestoreFailureLeavesPersistedChildAndRootBindingRecoverable() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.viewModel.test_branchFailureInjector = {
            $0 == "restore" ? BranchInjectedFailure.restore : nil
        }

        do {
            _ = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
            XCTFail("Expected restore failure")
        } catch {
            XCTAssertEqual(error as? BranchInjectedFailure, .restore)
        }

        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        let branchTree = await fixture.viewModel.test_dataService.agentSessionBranchTree(
            containing: fixture.sourceSessionID,
            for: workspace
        )
        XCTAssertTrue(branchTree.requiresExactResume)
        XCTAssertEqual(
            fixture.controller.operations,
            ["list:source", "fork:source-1", "list:child", "list:source", "shutdown"]
        )
        XCTAssertFalse(fixture.controller.hasActiveThread)
        XCTAssertEqual(fixture.session.activeAgentSessionID, fixture.sourceSessionID)
        XCTAssertEqual(fixture.session.draftText, "preserved draft")
        XCTAssertFalse(fixture.session.isBranchOperationInProgress)
    }

    func testOrdinaryPersistedCodexSendInsertsOptimisticRowWithoutTreeReconciliation() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAgentModeCoordinatorBranchTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(
            name: "Ordinary persisted Codex",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
        let controller = BranchNoopCodexController()
        let viewModel = AgentModeViewModel(
            testWorkspaceDirectory: directory,
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_setLastKnownWorkspaceSnapshot(workspace)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.codexConversationID = "ordinary-thread"
        session.codexRolloutPath = "/tmp/ordinary-rollout.jsonl"

        XCTAssertEqual(viewModel.submitUserTurn(text: "send immediately", tabID: tabID), .submitted)

        XCTAssertTrue(session.items.contains { $0.kind == .user && $0.text == "send immediately" })
        XCTAssertFalse(session.isExactResumePreflightInProgress)
    }

    func testExactResumeHonorsReconnectFlagEvenWhenControllerReportsActiveThread() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        fixture.session.codexNeedsReconnect = true
        fixture.controller.startOrResumeError = CancellationError()
        let completion = expectation(description: "reconnect preflight completed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "must not send", tabID: fixture.tabID), .submitted)
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "must not send" })
        XCTAssertTrue(fixture.session.items.contains { $0.kind == .error })
        XCTAssertEqual(fixture.session.draftText, "must not send\n\npreserved draft")
    }

    func testExactResumeDropsStaleBindingWithoutOverwritingNewerComposerEdits() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        fixture.session.codexNeedsReconnect = true
        let gate = BranchAsyncGate()
        fixture.controller.startOrResumeGate = gate
        let completion = expectation(description: "stale exact-resume preflight completed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "original unsent", tabID: fixture.tabID), .submitted)
        await gate.waitUntilEntered()
        fixture.session.draftText = "newer edit"
        XCTAssertEqual(
            fixture.viewModel.submitUserTurn(text: "second send", tabID: fixture.tabID),
            .blocked(message: "Codex is reopening this conversation. Please wait before sending again.")
        )
        XCTAssertEqual(fixture.session.draftText, "newer edit")
        let replacementID = UUID()
        _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: replacementID, on: fixture.session)
        await gate.release()
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertEqual(fixture.session.activeAgentSessionID, replacementID)
        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "original unsent" })
        XCTAssertEqual(fixture.session.draftText, "original unsent\n\nnewer edit")
    }

    func testExactResumeFailureMessagePromisesNoSend() {
        XCTAssertEqual(
            CodexBranchOperationError.exactResumeFailed.localizedDescription,
            "Codex couldn't reopen this conversation (rollout missing). Your message wasn't sent. The other paths may still be available in the branch menu; you can hand this transcript off to a new session."
        )
    }

    func testRootWithBranchesExactResumeFailureOccursBeforeOptimisticUserRowAndRestoresDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAgentModeCoordinatorBranchTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(
            name: "Exact resume root",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
        let controller = BranchNoopCodexController()
        let viewModel = AgentModeViewModel(
            testWorkspaceDirectory: directory,
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_setLastKnownWorkspaceSnapshot(workspace)
        let tabID = UUID()
        let rootID = UUID()
        let branchID = UUID()
        let sourceTurnID = UUID()
        let origin = AgentSessionBranchOrigin(
            rootSessionID: rootID,
            sourceSessionID: rootID,
            sourceTurnID: sourceTurnID,
            sourceCodexTurnID: "source-turn",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        let root = AgentSession(
            id: rootID,
            workspaceID: workspace.id,
            name: "Root",
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            autoEditEnabled: true,
            codexConversationID: "root",
            codexRolloutPath: "/missing/root-rollout.jsonl"
        )
        let branch = AgentSession(
            id: branchID,
            workspaceID: workspace.id,
            name: "Branch",
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: origin
        )
        _ = try await viewModel.test_dataService.saveAgentSession(
            root,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        _ = try await viewModel.test_dataService.saveAgentSession(
            branch,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: rootID, on: session)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.codexConversationID = "root"
        session.codexRolloutPath = "/missing/root-rollout.jsonl"
        session.branchOrigin = nil
        await viewModel.test_reconcileCodexBranchTreeMembership(for: workspace)
        let completion = expectation(description: "exact-resume preflight completed")
        viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(viewModel.submitUserTurn(text: "must remain unsent", tabID: tabID), .submitted)
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertFalse(session.items.contains { $0.kind == .user })
        XCTAssertTrue(session.items.contains { $0.kind == .error })
        XCTAssertEqual(session.draftText, "must remain unsent")
    }

    func testIncompleteBranchMembershipPreservesKnownPositiveWhileCompleteEvidenceCanRemoveIt() {
        let knownID = UUID()
        let discoveredID = UUID()

        let incomplete = AgentSessionDataService.IndexedBranchMembership(
            memberIDs: [discoveredID],
            isComplete: false
        )
        XCTAssertEqual(
            AgentModeViewModel.test_reconciledBranchMembership(existing: [knownID], evidence: incomplete),
            [knownID, discoveredID]
        )

        let complete = AgentSessionDataService.IndexedBranchMembership(
            memberIDs: [],
            isComplete: true
        )
        XCTAssertEqual(
            AgentModeViewModel.test_reconciledBranchMembership(
                existing: [knownID, discoveredID],
                evidence: complete
            ),
            []
        )
    }

    func testOrdinaryCrossTabRebindTransfersPersistentBinding() async throws {
        let viewModel = makeViewModel()
        let requestedID = UUID()
        let oldID = UUID()
        let source = viewModel.session(for: UUID())
        let target = viewModel.session(for: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: requestedID, on: source)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldID, on: target)

        let binding = try await viewModel.test_rebindPersistentSession(requestedID, to: target)

        XCTAssertEqual(binding.sessionID, requestedID)
        XCTAssertNil(source.activeAgentSessionID)
        XCTAssertEqual(target.activeAgentSessionID, requestedID)
    }

    func testLateRebindFailurePreservesDonorPersistentBinding() async {
        let viewModel = makeViewModel()
        let requestedID = UUID()
        let oldID = UUID()
        let source = viewModel.session(for: UUID())
        let target = viewModel.session(for: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: requestedID, on: source)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldID, on: target)
        let gate = BranchAsyncGate()
        viewModel.test_rebindBeforeFinalAwait = { await gate.enter() }

        let rebind = Task { @MainActor in
            try await viewModel.test_rebindPersistentSession(requestedID, to: target)
        }
        await gate.waitUntilEntered()
        viewModel.test_reserveBranchSwitchTarget(requestedID, for: UUID())
        await gate.release()

        do {
            _ = try await rebind.value
            XCTFail("Expected the in-flight rebind to observe the later reservation")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .targetOpenElsewhere)
        }
        XCTAssertEqual(source.activeAgentSessionID, requestedID)
        XCTAssertEqual(target.activeAgentSessionID, oldID)
    }

    func testInFlightRebindRechecksReservationImmediatelyBeforeBindingInstall() async {
        let viewModel = makeViewModel()
        let requestedID = UUID()
        let oldID = UUID()
        let target = viewModel.session(for: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: oldID, on: target)
        let gate = BranchAsyncGate()
        viewModel.test_rebindBeforeFinalAwait = { await gate.enter() }

        let rebind = Task { @MainActor in
            try await viewModel.test_rebindPersistentSession(
                requestedID,
                to: target,
                allowTransferFromAnotherTab: false
            )
        }
        await gate.waitUntilEntered()
        viewModel.test_reserveBranchSwitchTarget(requestedID, for: UUID())
        await gate.release()

        do {
            _ = try await rebind.value
            XCTFail("Expected the in-flight rebind to observe the later reservation")
        } catch {
            XCTAssertEqual(error as? CodexBranchOperationError, .targetOpenElsewhere)
        }
        XCTAssertEqual(target.activeAgentSessionID, oldID)
    }

    func testExactResumeRejectsImmediateRebindBeforeFastPathCanSend() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        fixture.session.codexNeedsReconnect = true
        let completion = expectation(description: "stale fast-path submission completed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "must not send", tabID: fixture.tabID), .submitted)
        _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
        fixture.session.codexNeedsReconnect = false
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "must not send" })
        XCTAssertEqual(fixture.session.draftText, "must not send\n\npreserved draft")
    }

    func testUnloadedPersistedCodexSessionHydratesAndSendsExactlyOnce() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        let loadedPersisted = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        )
        var persisted = try XCTUnwrap(loadedPersisted)
        persisted.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        _ = try await fixture.viewModel.test_dataService.saveAgentSession(
            persisted,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: persisted.items.count
        )
        fixture.controller.prepareAsUnstarted()
        fixture.session.codexController = nil
        fixture.session.hasLoadedPersistedState = false
        fixture.session.codexConversationID = nil
        fixture.session.codexRolloutPath = nil
        fixture.session.codexTurnCheckpoints = nil
        fixture.session.items.removeAll()

        XCTAssertEqual(
            fixture.viewModel.submitUserTurn(text: "send after cold hydration", tabID: fixture.tabID),
            .submitted
        )
        for _ in 0 ..< 500 where fixture.controller.startedTurnCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            fixture.controller.startedTurnCount,
            1,
            "items=\(fixture.session.items.map { "\($0.kind):\($0.text)" }) draft=\(fixture.session.draftText) conversation=\(fixture.session.codexConversationID ?? "nil") loaded=\(fixture.session.hasLoadedPersistedState) runState=\(fixture.session.runState)"
        )
        XCTAssertEqual(
            fixture.session.items.count(where: {
                $0.kind == .user && $0.text == "send after cold hydration"
            }),
            1
        )
        XCTAssertEqual(fixture.session.codexConversationID, "source")
    }

    func testHydratedSubmissionRejectsImmediateRebindBeforeAnySendPath() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.hasLoadedPersistedState = false
        let completion = expectation(description: "stale hydrated submission completed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "hydrated old text", tabID: fixture.tabID), .submitted)
        _ = fixture.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: fixture.session)
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "hydrated old text" })
        XCTAssertTrue(fixture.session.draftText.contains("hydrated old text"))
    }

    func testRolloutPathOnlyTreeMemberExactResumesAndComposerClearDoesNotCancelSend() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        fixture.session.codexConversationID = nil
        fixture.session.codexRolloutPath = "/tmp/path-only-rollout.jsonl"
        fixture.session.codexController = nil
        fixture.controller.prepareAsUnstarted()
        fixture.session.codexNeedsReconnect = true
        let completion = expectation(description: "path-only exact resume completed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "continue from path", tabID: fixture.tabID), .submitted)
        fixture.session.draftText = ""
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertEqual(fixture.controller.startOrResumeExistingRefs.last?.conversationID, "")
        XCTAssertEqual(fixture.controller.startOrResumeExistingRefs.last?.rolloutPath, "/tmp/path-only-rollout.jsonl")
        for _ in 0 ..< 100 where !fixture.session.items.contains(where: {
            $0.kind == .user && $0.text == "continue from path"
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            fixture.session.items.contains {
                $0.kind == .user && $0.text == "continue from path"
            },
            "items=\(fixture.session.items.map { "\($0.kind):\($0.text)" }) draft=\(fixture.session.draftText) conversation=\(fixture.session.codexConversationID ?? "nil") rollout=\(fixture.session.codexRolloutPath ?? "nil") runState=\(fixture.session.runState) controllerActive=\(fixture.controller.hasActiveThread)"
        )
    }

    func testRolloutPathOnlyExactResumeFailureRestoresDraftWithExplicitNoSendError() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        fixture.session.branchOrigin = AgentSessionBranchOrigin(
            rootSessionID: fixture.sourceSessionID,
            sourceSessionID: fixture.sourceSessionID,
            sourceTurnID: fixture.sourceTurnID,
            sourceCodexTurnID: "source-1",
            sourceTurnOrdinal: 1,
            createdAt: Date()
        )
        fixture.session.codexConversationID = nil
        fixture.session.codexRolloutPath = "/tmp/path-only-rollout.jsonl"
        fixture.session.codexController = nil
        fixture.controller.prepareAsUnstarted()
        fixture.session.codexNeedsReconnect = true
        fixture.controller.startOrResumeError = CancellationError()
        let completion = expectation(description: "path-only exact resume failed")
        fixture.viewModel.test_exactResumePreflightDidFinish = { completion.fulfill() }

        XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "remain unsent", tabID: fixture.tabID), .submitted)
        await fulfillment(of: [completion], timeout: 2)

        XCTAssertFalse(fixture.session.items.contains { $0.kind == .user && $0.text == "remain unsent" })
        XCTAssertTrue(fixture.session.items.contains {
            $0.kind == .error && $0.text.contains("Your message wasn't sent")
        })
        XCTAssertTrue(fixture.session.draftText.contains("remain unsent"))
    }

    func testClosingBranchedTabDeletesOnlyBoundChildAndPreservesRoot() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let childID = try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )

        let loadedRoot = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        )
        let loadedChild = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: childID,
            for: workspace
        )
        let persistedRoot = try XCTUnwrap(loadedRoot)
        let persistedChild = try XCTUnwrap(loadedChild)
        XCTAssertEqual(persistedRoot.composeTabID, fixture.tabID)
        XCTAssertNil(persistedChild.composeTabID)

        await fixture.viewModel.handleComposeTabsWillClose([fixture.tabID], reason: .close)

        let remainingRoot = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        )
        let deletedChild = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: childID,
            for: workspace
        )
        XCTAssertNotNil(remainingRoot)
        XCTAssertNil(deletedChild)
    }

    func testTabCloseWaitsForInFlightBranchBeforeDeletingOnlyResultingChild() async throws {
        let fixture = try await makeBranchFixture(childTurns: [threadTurn("source-1")])
        defer { fixture.cleanup() }
        let forkGate = BranchAsyncGate()
        fixture.controller.forkGate = forkGate

        let branchTask = Task { @MainActor in
            try await fixture.viewModel.branchFromTurn(fixture.sourceTurnID, tabID: fixture.tabID)
        }
        await forkGate.waitUntilEntered()
        let closeTask = Task { @MainActor in
            await fixture.viewModel.handleComposeTabsWillClose([fixture.tabID], reason: .close)
        }
        await Task.yield()
        XCTAssertTrue(fixture.session.isBranchOperationInProgress)
        await forkGate.release()
        let childID = try await branchTask.value
        await closeTask.value

        let workspace = WorkspaceModel(
            id: fixture.workspaceID,
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: fixture.workspaceDirectory
        )
        let remainingRoot = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: fixture.sourceSessionID,
            for: workspace
        )
        let deletedChild = try await fixture.viewModel.test_dataService.loadAgentSession(
            id: childID,
            for: workspace
        )
        XCTAssertNotNil(remainingRoot)
        XCTAssertNil(deletedChild)
    }

    private func makeBranchFixture(
        childTurns: [CodexNativeSessionController.ThreadTurn]
    ) async throws -> BranchFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAgentModeCoordinatorBranchTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = WorkspaceModel(
            name: "Codex branch",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
        let controller = BranchRecordingCodexController(childTurns: childTurns)
        let viewModel = AgentModeViewModel(
            testWorkspaceDirectory: directory,
            codexControllerFactory: { _, _, _, _, _, _ in controller }
        )
        viewModel.test_setLastKnownWorkspaceSnapshot(workspace)
        viewModel.test_oracleBranchOccupancyOverride = false

        let tabID = UUID()
        let sourceSessionID = UUID()
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sourceSessionID, on: session)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.codexConversationID = "source"
        session.codexRolloutPath = "/tmp/source-rollout.jsonl"
        session.codexController = controller
        session.runState = .idle
        session.draftText = "preserved draft"

        let items: [AgentChatItem] = [
            .user("first question", sequenceIndex: 0),
            .assistant("first answer", sequenceIndex: 1),
            .user("second question", sequenceIndex: 2),
            .assistant("second answer", sequenceIndex: 3)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: 4,
            compact: false
        )
        let sourceTurnID = try XCTUnwrap(transcript.turns.first?.id)
        session.items = items
        session.transcript = transcript
        session.nextSequenceIndex = 4
        session.codexTurnCheckpoints = CodexTurnCheckpointLedger(
            threadID: "source",
            entries: [
                CodexTurnCheckpoint(
                    turnID: sourceTurnID,
                    codexTurnID: "source-1",
                    status: .completed,
                    sideEffect: .readOnly,
                    recordedAt: Date()
                )
            ]
        )
        var persistedSource = AgentSession(
            id: sourceSessionID,
            workspaceID: workspace.id,
            name: "Source",
            itemCount: items.count,
            autoEditEnabled: true
        )
        persistedSource.composeTabID = tabID
        persistedSource.items = items.map { AgentChatItemPersist(from: $0) }
        persistedSource.transcript = transcript
        persistedSource.agentKind = AgentProviderKind.codexExec.rawValue
        persistedSource.lastRunState = AgentSessionRunState.idle.rawValue
        persistedSource.codexConversationID = "source"
        persistedSource.codexRolloutPath = "/tmp/source-rollout.jsonl"
        persistedSource.codexTurnCheckpoints = session.codexTurnCheckpoints
        _ = try await viewModel.test_dataService.saveAgentSession(
            persistedSource,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: items.count
        )

        return BranchFixture(
            viewModel: viewModel,
            controller: controller,
            session: session,
            workspaceDirectory: directory,
            workspaceID: workspace.id,
            tabID: tabID,
            sourceSessionID: sourceSessionID,
            sourceTurnID: sourceTurnID
        )
    }

    private func threadTurn(_ id: String) -> CodexNativeSessionController.ThreadTurn {
        .init(
            id: id,
            status: .completed,
            items: [],
            itemsView: .summary,
            startedAt: nil,
            completedAt: nil
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        let controller = BranchNoopCodexController()
        let viewModel = AgentModeViewModel(codexControllerFactory: { _, _, _, _, _, _ in controller })
        viewModel.test_oracleBranchOccupancyOverride = false
        return viewModel
    }
}

private enum BranchInjectedFailure: Error {
    case sourceSave
    case branchSave
    case restore
}

private struct BranchFixture {
    let viewModel: AgentModeViewModel
    let controller: BranchRecordingCodexController
    let session: AgentModeViewModel.TabSession
    let workspaceDirectory: URL
    let workspaceID: UUID
    let tabID: UUID
    let sourceSessionID: UUID
    let sourceTurnID: UUID

    func cleanup() {
        try? FileManager.default.removeItem(at: workspaceDirectory)
    }
}

private final class BranchRecordingCodexController: CodexSessionControlling {
    private let stream: AsyncStream<CodexNativeSessionController.Event>
    private let childTurns: [CodexNativeSessionController.ThreadTurn]
    private(set) var operations: [String] = []
    private(set) var startedTurnCount = 0
    private(set) var hasActiveThread = true
    private(set) var startOrResumeExistingRefs: [CodexNativeSessionController.SessionRef] = []
    var onFirstList: (() -> Void)?
    var forkError: Error?
    var forkConversationID = "child"
    var startOrResumeError: Error?
    var startOrResumeGate: BranchAsyncGate?
    var forkGate: BranchAsyncGate?

    init(childTurns: [CodexNativeSessionController.ThreadTurn]) {
        self.childTurns = childTurns
        stream = AsyncStream { _ in }
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream
    }

    func ensureEventsStreamReady() {}

    func prepareAsUnstarted() {
        hasActiveThread = false
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        if let existing {
            startOrResumeExistingRefs.append(existing)
        }
        if let startOrResumeGate { await startOrResumeGate.enter() }
        if let startOrResumeError { throw startOrResumeError }
        hasActiveThread = true
        return .init(
            conversationID: existing?.conversationID.isEmpty == false ? existing?.conversationID ?? "source" : "source",
            rolloutPath: existing?.rolloutPath,
            model: nil,
            reasoningEffort: nil
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "source",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func forkThread(_ lastTurnID: String) async throws -> CodexNativeSessionController.SessionRef {
        operations.append("fork:\(lastTurnID)")
        if let forkGate { await forkGate.enter() }
        if let forkError { throw forkError }
        return .init(conversationID: forkConversationID, rolloutPath: "/tmp/child-rollout.jsonl", model: nil, reasoningEffort: nil)
    }

    func listThreadTurns(
        threadID: String,
        cursor _: String?,
        limit _: Int?,
        sortDirection _: CodexNativeSessionController.ThreadTurnsSortDirection
    ) async throws -> CodexNativeSessionController.ThreadTurnsPage {
        operations.append("list:\(threadID)")
        if let onFirstList {
            self.onFirstList = nil
            onFirstList()
        }
        let turns = threadID == "child" ? childTurns : [
            CodexNativeSessionController.ThreadTurn(
                id: "source-2",
                status: .completed,
                items: [],
                itemsView: .summary,
                startedAt: nil,
                completedAt: nil
            ),
            CodexNativeSessionController.ThreadTurn(
                id: "source-1",
                status: .completed,
                items: [],
                itemsView: .summary,
                startedAt: nil,
                completedAt: nil
            )
        ]
        return .init(data: turns, nextCursor: nil, backwardsCursor: nil)
    }

    func archiveThread(threadID: String) async throws {
        operations.append("archive:\(threadID)")
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        startedTurnCount += 1
        return .init(provisionalSubmissionID: "unexpected")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}

    func shutdown() async {
        operations.append("shutdown")
        hasActiveThread = false
    }

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

private actor BranchAsyncGate {
    private var entered = false
    private var released = false
    private var blockers: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let pendingObservers = observers
        observers.removeAll()
        pendingObservers.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { blockers.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        let pendingBlockers = blockers
        blockers.removeAll()
        pendingBlockers.forEach { $0.resume() }
    }
}

private final class BranchNoopCodexController: CodexSessionControlling {
    private let stream: AsyncStream<CodexNativeSessionController.Event>

    init() {
        stream = AsyncStream { $0.finish() }
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        stream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        .init(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        .init(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        .init(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}

    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
