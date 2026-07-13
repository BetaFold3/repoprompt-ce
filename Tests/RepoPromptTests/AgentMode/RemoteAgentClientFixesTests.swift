@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentClientFixesTests: XCTestCase {
    @MainActor
    func testT8TerminalSettlementContractMappings() {
        XCTAssertEqual(
            RemoteAgentModeCoordinator.test_terminalSettlement(for: "completed").statusWord,
            "completed"
        )
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "completed").isError, false)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "cancelled").statusWord, "cancelled")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "cancelled").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "failed").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "failed").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "expired").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "expired").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "other").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "other").isError, true)
    }

    @MainActor
    func testT9TerminalSettledOrphanIsRemovedAndFailedReprojectionOverwrites() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t9-remove")
        let runningTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t9-remove").first)

        coordinator.test_applyTranscriptRows([runningTool], to: session)
        coordinator.test_applyTerminal(status: "completed", to: session)
        XCTAssertEqual(session.items.first?.id, runningTool.id)
        XCTAssertEqual(session.items.first?.toolIsError, false)
        XCTAssertNotNil(session.items.first?.toolResultJSON)

        coordinator.test_applyTranscriptRows([], removedIDs: [runningTool.id], to: session)
        XCTAssertFalse(session.items.contains { $0.id == runningTool.id })

        let overwriteSession = makeSession(remoteSessionID: "remote-t9-overwrite")
        let initialTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t9-overwrite").first)
        let failedTool = try XCTUnwrap(project(
            xml: #"<tool_call name="context_builder"/><tool_result name="context_builder" status="failed"/>"#,
            sessionID: "remote-t9-overwrite"
        ).first)
        XCTAssertEqual(initialTool.id, failedTool.id)

        coordinator.test_applyTranscriptRows([initialTool], to: overwriteSession)
        coordinator.test_applyTerminal(status: "completed", to: overwriteSession)
        coordinator.test_applyTranscriptRows([failedTool], to: overwriteSession)

        let finalTools = overwriteSession.items.filter { $0.kind == .toolCall }
        XCTAssertEqual(finalTools.count, 1)
        let finalTool = try XCTUnwrap(finalTools.first)
        XCTAssertEqual(finalTool.id, initialTool.id)
        XCTAssertEqual(finalTool.toolIsError, true)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: finalTool), .failure)
    }

    @MainActor
    func testT10ParkedToolAbsentOnCompleteRemovesOrphanAndPreservesOptimisticUser() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t10")
        let optimistic = AgentChatItem(kind: .user, text: "local optimistic", sequenceIndex: 999)
        session.appendItem(optimistic)
        session.pendingRemoteOptimisticUserItemIDs.insert(optimistic.id)
        let parked = project(
            xml: #"<user>Prompt</user><assistant>Working</assistant><assistant>Still working</assistant><tool_call name="context_builder"/>"#,
            sessionID: "remote-t10"
        )
        let parkedTool = try XCTUnwrap(parked.first { $0.toolName == "context_builder" })
        let complete = project(
            xml: #"<user>Prompt</user><assistant>Working</assistant><assistant>Still working</assistant><assistant>Final assistant</assistant>"#,
            sessionID: "remote-t10"
        )

        coordinator.test_applyTranscriptRows(parked, to: session)
        coordinator.test_applyTranscriptRows(complete, removedIDs: [parkedTool.id], to: session)

        XCTAssertFalse(session.items.contains { $0.id == parkedTool.id })
        XCTAssertEqual(session.items.count(where: { $0.text == "Final assistant" }), 1)
        XCTAssertTrue(session.items.contains { $0.id == optimistic.id })
    }

    @MainActor
    func testResentOptimisticUserDedupesAgainstHostLogCatchUp() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-resent-dedupe")
        var optimistic = AgentChatItem(kind: .user, text: "Plain resent text", sequenceIndex: 999)
        optimistic.isUndeliveredRemoteSend = true
        session.appendItem(optimistic)
        session.pendingRemoteOptimisticUserItemIDs.insert(optimistic.id)
        session.remoteResendPayloadsByItemID[optimistic.id] = .init(
            providerText: "Plain resent text",
            wasStart: false,
            modelSelectionRaw: nil,
            sessionName: nil,
            workspaceName: nil
        )
        session.remoteResendInFlightItemIDs.insert(optimistic.id)
        let projected = project(
            xml: "<user>Plain resent text</user>",
            sessionID: "remote-resent-dedupe"
        )

        coordinator.test_applyTranscriptRows(projected, to: session)

        XCTAssertEqual(session.items.count(where: {
            $0.kind == .user && $0.text == "Plain resent text"
        }), 1)
        XCTAssertFalse(session.items.contains { $0.id == optimistic.id })
        XCTAssertNil(session.remoteResendPayloadsByItemID[optimistic.id])
        XCTAssertFalse(session.remoteResendInFlightItemIDs.contains(optimistic.id))
    }

    func testStructuredTranscriptRoundTripPreservesUndeliveredRemoteSendAndDefaultsAbsentFlagFalse() throws {
        var flagged = AgentChatItem.user("Retry after restart", sequenceIndex: 7)
        flagged.isUndeliveredRemoteSend = true
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decodedAnchor = try decoder.decode(
            AgentTranscriptRequestAnchor.self,
            from: encoder.encode(AgentTranscriptRequestAnchor(from: flagged))
        )
        XCTAssertTrue(decodedAnchor.toItem().isUndeliveredRemoteSend)

        let decodedActivity = try decoder.decode(
            AgentTranscriptActivity.self,
            from: encoder.encode(AgentTranscriptActivity(from: flagged))
        )
        XCTAssertTrue(decodedActivity.toItem().isUndeliveredRemoteSend)

        let unflaggedAnchorData = try encoder.encode(AgentTranscriptRequestAnchor(from: .user("Delivered")))
        let unflaggedAnchorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unflaggedAnchorData) as? [String: Any]
        )
        XCTAssertNil(unflaggedAnchorObject["isUndeliveredRemoteSend"])
        XCTAssertFalse(
            try decoder.decode(AgentTranscriptRequestAnchor.self, from: unflaggedAnchorData)
                .toItem().isUndeliveredRemoteSend
        )

        let unflaggedActivityData = try encoder.encode(AgentTranscriptActivity(from: .user("Delivered activity")))
        let unflaggedActivityObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unflaggedActivityData) as? [String: Any]
        )
        XCTAssertNil(unflaggedActivityObject["isUndeliveredRemoteSend"])
        XCTAssertFalse(
            try decoder.decode(AgentTranscriptActivity.self, from: unflaggedActivityData)
                .toItem().isUndeliveredRemoteSend
        )

        var productionShaped = AgentSession(name: "Structured resend").withItems([flagged])
        productionShaped.items = []
        let restored = try XCTUnwrap(productionShaped.toLiveItems().first)
        XCTAssertEqual(restored.id, flagged.id)
        XCTAssertTrue(restored.isUndeliveredRemoteSend)
    }

    @MainActor
    func testRestoredUndeliveredRemoteUserRehydratesPendingIDAndDedupesCatchUp() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let tabID = UUID()
        let sessionID = UUID()
        var original = AgentChatItem.user("Restored pending turn", sequenceIndex: 999)
        original.isUndeliveredRemoteSend = true
        var flaggedSystem = AgentChatItem.system("Not an optimistic user", sequenceIndex: 1000)
        flaggedSystem.isUndeliveredRemoteSend = true
        let persistedSession = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Restored remote dedupe",
            items: [
                AgentChatItemPersist(from: original),
                AgentChatItemPersist(from: flaggedSystem)
            ],
            itemCount: 2,
            lastRunState: AgentSessionRunState.failed.rawValue,
            remoteHost: Self.makeBinding(remoteSessionID: "remote-restored-dedupe")
        )
        _ = try await service.saveAgentSession(
            persistedSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 2
        )
        let hydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: tabID,
            sessionID: sessionID,
            resolvedDisplayName: "Restored remote dedupe",
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let preparedPayload = try await service.preparePersistedHydration(hydrationRequest)
        let prepared = try XCTUnwrap(preparedPayload)
        let payload = AgentSessionHydrationPayload(
            sessionID: prepared.sessionID,
            persistedSession: persistedSession,
            canonicalLiveItems: persistedSession.items.map { $0.toItem() },
            transcript: prepared.transcript,
            builtPresentation: prepared.builtPresentation,
            normalizedRunState: prepared.normalizedRunState,
            normalizedSelection: prepared.normalizedSelection,
            lastUserMessageAt: prepared.lastUserMessageAt,
            restoredIndexEntry: prepared.restoredIndexEntry,
            needsReloadMigrationSave: prepared.needsReloadMigrationSave
        )
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in ClientFixesNoopCodexController() }
        )
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)

        let didApplyHydration = await viewModel.test_applyPersistedHydration(payload, to: session)
        XCTAssertTrue(didApplyHydration)

        let restored = try XCTUnwrap(session.items.first {
            $0.kind == .user && $0.text == "Restored pending turn"
        })
        let restoredSystem = try XCTUnwrap(session.items.first {
            $0.kind == .system && $0.text == "Not an optimistic user"
        })
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.contains(restored.id))
        XCTAssertFalse(session.pendingRemoteOptimisticUserItemIDs.contains(restoredSystem.id))
        let coordinator = RemoteAgentModeCoordinator()
        let projected = project(
            xml: "<user>Restored pending turn</user>",
            sessionID: "remote-restored-dedupe"
        )
        coordinator.test_applyTranscriptRows(projected, to: session)

        XCTAssertEqual(session.items.count(where: {
            $0.kind == .user && $0.text == "Restored pending turn"
        }), 1)
        XCTAssertFalse(session.items.contains { $0.id == restored.id })
    }

    @MainActor
    func testPersistedWindowOnlyTargetRoundTripsThroughProductionHydrationAndDispatchesOnce() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let tabID = UUID()
        let sessionID = UUID()
        let providerText = "Byte-identical provider text\nwith spacing  "
        var original = AgentChatItem.user("Displayed resend text", sequenceIndex: 999)
        original.isUndeliveredRemoteSend = true
        var persistedSession = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Persisted resend recovery",
            lastRunState: AgentSessionRunState.failed.rawValue,
            remoteHost: Self.makeBinding(remoteSessionID: ""),
            remoteResendPayloadsByItemID: [
                original.id.uuidString: PersistedRemoteResendPayload(
                    providerText: providerText,
                    wasStart: true,
                    modelSelectionRaw: "codexExec:gpt-5.4",
                    sessionName: "Recovered start",
                    workspaceName: "Stale Project Name",
                    windowID: 42,
                    workspaceID: nil
                )
            ]
        ).withItems([original])
        persistedSession.items = []
        let persistedURL = try await service.saveAgentSession(
            persistedSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: persistedURL)) as? [String: Any]
        )
        XCTAssertEqual((persistedObject["items"] as? [Any])?.count, 0)

        let loadedSessionResult = try await service.loadAgentSession(id: sessionID, for: workspace)
        let loadedSession = try XCTUnwrap(loadedSessionResult)
        let loadedItem = try XCTUnwrap(loadedSession.items.first { $0.id == original.id })
        XCTAssertTrue(loadedItem.isUndeliveredRemoteSend)
        XCTAssertNotNil(loadedSession.transcript)
        let loadedPayload = try XCTUnwrap(loadedSession.remoteResendPayloadsByItemID[original.id.uuidString])
        XCTAssertNil(loadedPayload.workspaceName)
        XCTAssertEqual(loadedPayload.windowID, 42)
        XCTAssertNil(loadedPayload.workspaceID)

        let hydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: tabID,
            sessionID: sessionID,
            resolvedDisplayName: loadedSession.name,
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let preparedResult = try await service.preparePersistedHydration(hydrationRequest)
        let prepared = try XCTUnwrap(preparedResult)
        let preparedItem = try XCTUnwrap(prepared.canonicalLiveItems.first { $0.id == original.id })
        XCTAssertTrue(preparedItem.isUndeliveredRemoteSend)
        XCTAssertNotNil(prepared.persistedSession.remoteResendPayloadsByItemID[original.id.uuidString])

        let coordinator = RemoteAgentModeCoordinator()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in ClientFixesNoopCodexController() },
            testRemoteCoordinator: coordinator
        )
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)

        let didApplyHydration = await viewModel.test_applyPersistedHydration(prepared, to: session)
        XCTAssertTrue(didApplyHydration)
        let restored = try XCTUnwrap(session.items.first { $0.id == original.id })
        XCTAssertEqual(
            viewModel.undeliveredPresentation(for: restored, tabID: tabID),
            .init(isUndelivered: true, resendActionLabel: "Resend")
        )
        XCTAssertTrue(session.remoteResendInFlightItemIDs.isEmpty)
        let restoredPayload = try XCTUnwrap(session.remoteResendPayloadsByItemID[original.id])
        XCTAssertEqual(restoredPayload.providerText, providerText)
        XCTAssertEqual(session.pendingRemoteOptimisticProviderTextByItemID[original.id], providerText)
        XCTAssertNil(restoredPayload.workspaceName)
        XCTAssertEqual(restoredPayload.windowID, 42)
        XCTAssertNil(restoredPayload.workspaceID)

        let connection = ScriptedConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(
            binding: remoteHost,
            connection: connection
        )
        let hostID = try XCTUnwrap(session.remoteHost?.hostID)
        coordinator.test_installController(
            controller,
            for: session,
            hostID: hostID
        )
        viewModel.resendUndeliveredRemoteUserTurn(tabID: tabID, itemID: original.id)
        viewModel.resendUndeliveredRemoteUserTurn(tabID: tabID, itemID: original.id)
        for _ in 0 ..< 200 {
            if await connection.commandFrames(type: "start").count == 1 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let startFrames = await connection.commandFrames(type: "start")
        XCTAssertEqual(startFrames.count, 1)
        let startFrame = try XCTUnwrap(startFrames.first)
        XCTAssertEqual(startFrame.payload?.objectValue?["message"]?.stringValue, providerText)
        XCTAssertEqual(startFrame.payload?.objectValue?["window_id"]?.intValue, 42)
        XCTAssertNil(startFrame.payload?.objectValue?["workspace_id"])
        XCTAssertNil(startFrame.payload?.objectValue?["workspace_name"])
        for _ in 0 ..< 200 {
            if session.remoteResendPayloadsByItemID[original.id] == nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(session.remoteResendPayloadsByItemID[original.id])
        XCTAssertEqual(session.pendingRemoteOptimisticProviderTextByItemID[original.id], providerText)

        let projected = project(
            xml: "<user>\(providerText)</user>",
            sessionID: session.remoteHost?.normalizedRemoteSessionID ?? "remote-started-by-resend"
        )
        coordinator.test_applyTranscriptRows(projected, to: session)

        let projectedUser = try XCTUnwrap(session.items.first { $0.kind == .user })
        XCTAssertEqual(session.items.count(where: { $0.kind == .user }), 1)
        XCTAssertFalse(session.items.contains { $0.id == original.id })
        XCTAssertEqual(projectedUser.text, providerText)
        XCTAssertEqual(projectedUser.timestamp, original.timestamp)
        XCTAssertTrue(session.pendingRemoteOptimisticUserItemIDs.isEmpty)
        XCTAssertTrue(session.pendingRemoteOptimisticProviderTextByItemID.isEmpty)
    }

    @MainActor
    func testHydratedStartAttributionMismatchResendsAsSteer() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let tabID = UUID()
        let sessionID = UUID()
        let attributedItemID = UUID()
        var original = AgentChatItem.user("Hydrated mismatch", sequenceIndex: 999)
        original.isUndeliveredRemoteSend = true
        let persistedSession = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Persisted attribution",
            items: [AgentChatItemPersist(from: original)],
            itemCount: 1,
            lastRunState: AgentSessionRunState.failed.rawValue,
            remoteHost: Self.makeBinding(remoteSessionID: "remote-attributed"),
            remoteResendPayloadsByItemID: [
                original.id.uuidString: PersistedRemoteResendPayload(
                    providerText: "Hydrated mismatch",
                    wasStart: true,
                    modelSelectionRaw: nil,
                    sessionName: nil,
                    workspaceName: "Project Alpha"
                )
            ],
            locallyAttributedStartItemID: attributedItemID
        )
        _ = try await service.saveAgentSession(
            persistedSession,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let loadedSessionResult = try await service.loadAgentSession(id: sessionID, for: workspace)
        let loadedSession = try XCTUnwrap(loadedSessionResult)
        let hydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: tabID,
            sessionID: sessionID,
            resolvedDisplayName: loadedSession.name,
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let preparedResult = try await service.preparePersistedHydration(hydrationRequest)
        let prepared = try XCTUnwrap(preparedResult)
        let payload = AgentSessionHydrationPayload(
            sessionID: prepared.sessionID,
            persistedSession: loadedSession,
            canonicalLiveItems: [original],
            transcript: prepared.transcript,
            builtPresentation: prepared.builtPresentation,
            normalizedRunState: prepared.normalizedRunState,
            normalizedSelection: prepared.normalizedSelection,
            lastUserMessageAt: prepared.lastUserMessageAt,
            restoredIndexEntry: prepared.restoredIndexEntry,
            needsReloadMigrationSave: prepared.needsReloadMigrationSave
        )
        let coordinator = RemoteAgentModeCoordinator()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in ClientFixesNoopCodexController() },
            testRemoteCoordinator: coordinator
        )
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let didApplyHydration = await viewModel.test_applyPersistedHydration(payload, to: session)
        XCTAssertTrue(didApplyHydration)
        XCTAssertEqual(session.locallyAttributedStartItemID, attributedItemID)

        let connection = ScriptedConnection()
        let remoteHost = try XCTUnwrap(session.remoteHost)
        let controller = RemoteAgentSessionController(binding: remoteHost, connection: connection)
        coordinator.test_installController(controller, for: session, hostID: remoteHost.hostID)

        viewModel.resendUndeliveredRemoteUserTurn(tabID: tabID, itemID: original.id)
        for _ in 0 ..< 200 {
            if await connection.commandFrames(type: "steer").count == 1 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let steerFrames = await connection.commandFrames(type: "steer")
        XCTAssertEqual(steerFrames.count, 1)
        XCTAssertEqual(steerFrames.first?.sessionID, "remote-attributed")
        XCTAssertEqual(steerFrames.first?.payload?.objectValue?["message"]?.stringValue, "Hydrated mismatch")
        let startFrames = await connection.commandFrames(type: "start")
        XCTAssertTrue(startFrames.isEmpty)
        XCTAssertFalse(session.items.contains {
            $0.kind == .system && $0.text == "Remote send was already delivered."
        })
    }

    @MainActor
    func testV43LegacySessionDecodeDefaultsResendPayloadsToEmptyAndBadgeOnly() async throws {
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let tabID = UUID()
        let sessionID = UUID()
        var original = AgentChatItem.user("Legacy undelivered", sequenceIndex: 999)
        original.isUndeliveredRemoteSend = true
        let source = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Legacy resend recovery",
            items: [AgentChatItemPersist(from: original)],
            itemCount: 1,
            lastRunState: AgentSessionRunState.failed.rawValue,
            remoteHost: Self.makeBinding(remoteSessionID: "remote-legacy")
        )
        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "remoteResendPayloadsByItemID")
        object.removeValue(forKey: "locallyAttributedStartItemID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacyData)
        XCTAssertTrue(decoded.remoteResendPayloadsByItemID.isEmpty)
        XCTAssertNil(decoded.locallyAttributedStartItemID)

        let partialSelectorData = Data(
            #"{"providerText":"Retry","wasStart":true,"workspaceName":"Project Alpha","windowID":7}"#.utf8
        )
        let partialSelector = try JSONDecoder().decode(PersistedRemoteResendPayload.self, from: partialSelectorData)
        XCTAssertNil(partialSelector.workspaceName)
        XCTAssertEqual(partialSelector.windowID, 7)
        XCTAssertNil(partialSelector.workspaceID)

        let service = AgentSessionDataService.shared
        _ = try await service.saveAgentSession(
            decoded,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let hydrationRequest = AgentSessionHydrationRequest(
            workspace: workspace,
            tabID: tabID,
            sessionID: sessionID,
            resolvedDisplayName: decoded.name,
            hasPendingQuestionUI: false,
            transcriptViewportState: .liveBottom,
            isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        )
        let preparedResult = try await service.preparePersistedHydration(hydrationRequest)
        let prepared = try XCTUnwrap(preparedResult)
        let payload = AgentSessionHydrationPayload(
            sessionID: prepared.sessionID,
            persistedSession: decoded,
            canonicalLiveItems: decoded.items.map { $0.toItem() },
            transcript: prepared.transcript,
            builtPresentation: prepared.builtPresentation,
            normalizedRunState: prepared.normalizedRunState,
            normalizedSelection: prepared.normalizedSelection,
            lastUserMessageAt: prepared.lastUserMessageAt,
            restoredIndexEntry: prepared.restoredIndexEntry,
            needsReloadMigrationSave: prepared.needsReloadMigrationSave
        )
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in ClientFixesNoopCodexController() }
        )
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)

        let didApplyHydration = await viewModel.test_applyPersistedHydration(payload, to: session)
        XCTAssertTrue(didApplyHydration)
        let restored = try XCTUnwrap(session.items.first { $0.id == original.id })
        XCTAssertEqual(
            viewModel.undeliveredPresentation(for: restored, tabID: tabID),
            .init(isUndelivered: true, resendActionLabel: nil)
        )
        XCTAssertTrue(session.remoteResendPayloadsByItemID.isEmpty)
    }

    @MainActor
    func testT11CompleteFailedToolUpdatesInPlaceWithoutDuplicate() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t11")
        let parkedTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t11").first)
        let failedTool = try XCTUnwrap(project(
            xml: #"<tool_call name="context_builder"/><tool_result name="context_builder" status="failed"/>"#,
            sessionID: "remote-t11"
        ).first)
        XCTAssertEqual(parkedTool.id, failedTool.id)

        coordinator.test_applyTranscriptRows([parkedTool], to: session)
        coordinator.test_applyTranscriptRows([failedTool], to: session)

        let tools = session.items.filter { $0.kind == .toolCall }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.id, parkedTool.id)
        XCTAssertEqual(tools.first?.toolIsError, true)
        XCTAssertEqual(try ToolCallCardStateResolver.status(for: XCTUnwrap(tools.first)), .failure)
    }

    func testT12ParkedUnionKeepsVanishedRowUntilCompleteRemoves() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Still running</assistant>", completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_update", seq: 2, status: "running", to: controller)
        try await waitForBatchCount(2, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 3, status: "completed", to: controller)
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        let vanishedID = try XCTUnwrap(batches[0].items.first?.id)
        XCTAssertTrue(batches[1].removedIDs.isEmpty)
        XCTAssertEqual(batches[2].removedIDs, [vanishedID])
    }

    func testT13LegacyPageNeverRemovesRememberedRows() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Legacy projection</assistant>", completed: nil)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_update", seq: 2, status: "running", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertTrue(batches[1].removedIDs.isEmpty)
    }

    func testT14TerminalSettleBranchRemovesStaleRowNotReemitted() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 1),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final without tool</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 2, status: "completed", to: controller)
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        let staleID = try XCTUnwrap(batches[0].items.first?.id)
        XCTAssertEqual(batches[2].removedIDs, [staleID])
    }

    func testT15RegistryResetOnStartPreventsCrossSessionRemovals() async throws {
        let connection = ScriptedConnection(responses: [
            "start": [Self.snapshotPayload(status: "completed", sessionID: "remote-new")],
            "poll": [Self.snapshotPayload(status: "completed", sessionID: "remote-new")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>New session reply</assistant>", completed: 1),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>New session reply</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(remoteSessionID: "remote-old", nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", sessionID: "remote-old", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        _ = try await controller.start(
            message: "new",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertTrue(batches.dropFirst().allSatisfy(\.removedIDs.isEmpty))
    }

    func testT23TerminalSettleRereadsLastCompletePageRangeAndFreshControllerSkips() async throws {
        let twoTurnXML = "<user>One</user><assistant>First</assistant><user>Two</user><assistant>Second</assistant>"
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 2, total: 2, xml: twoTurnXML, completed: 2),
                Self.logPayload(offset: 0, returned: 2, total: 2, xml: twoTurnXML, completed: 2)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_terminal", seq: 1, status: "completed", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 2])
        let batches = await recorder.batches()
        XCTAssertEqual(batches[0].items.map(\.id), batches[1].items.map(\.id))
        XCTAssertEqual(Set(batches.flatMap { $0.items.map(\.id) }).count, 4)

        let freshConnection = ScriptedConnection(responses: [
            "poll": [Self.snapshotPayload(status: "completed")],
            "get_log": [Self.logPayload(offset: 2, returned: 0, total: 2, xml: "<transcript/>", completed: 2)]
        ])
        let freshController = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 2), connection: freshConnection)
        try await freshController.attachAndCatchUp()
        let freshRequests = await freshConnection.getLogRequests()
        XCTAssertEqual(freshRequests.map(\.offset), [2])
    }

    func testT20ProjectSnapshotStatusTextTrimming() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-t20")

        XCTAssertEqual(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("  Thinking…  ")
        ])).statusText, "Thinking…")
        XCTAssertNil(projector.projectSnapshot(.object(["status": .string("running")])).statusText)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("")
        ])).statusText)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("  \n\t ")
        ])).statusText)
    }

    @MainActor
    func testT21CoordinatorUsesStatusTextOnlyForRunningState() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t21")

        coordinator.test_applyRunState(.running, statusText: "Thinking…", to: session)
        XCTAssertEqual(session.runningStatusText, "Thinking…")

        coordinator.test_applyRunState(.running, statusText: nil, to: session)
        XCTAssertEqual(session.runningStatusText, "Thinking…")

        session.setRunningStatus("Existing waiting label", source: .transport)
        coordinator.test_applyRunState(.waitingForQuestion, statusText: "Queued to start", to: session)
        XCTAssertEqual(session.runningStatusText, "Existing waiting label")

        coordinator.test_applyTerminal(status: "completed", to: session)
        XCTAssertNil(session.runningStatusText)
    }

    func testT22ControllerRunStateEventIncludesStatusTextAndEquates() async {
        XCTAssertEqual(
            RemoteSessionEvent.runState(.running, pendingInteraction: nil, statusText: "Thinking…"),
            RemoteSessionEvent.runState(.running, pendingInteraction: nil, statusText: "Thinking…")
        )
        let connection = ScriptedConnection()
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running", statusText: "Thinking…")
        ))
        await waitForCondition { await recorder.runStateEvents().contains(.runState(.running, pendingInteraction: nil, statusText: "Thinking…")) }
    }

    @MainActor
    func testMetadataEchoRemapsPlainModelToCompoundSelection() async {
        let catalog = clientStructuredCatalog()
        let fixture = await makeMetadataFixture(catalog: catalog)
        fixture.session.selectedModelRaw = "codexExec:gpt-5.4-mini-low"

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.4-mini",
            reasoningEffortRaw: "high",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(fixture.session.selectedModelRaw, "codexExec:gpt-5.4-mini-high")
        XCTAssertFalse(catalog.effortOptions(forModelID: fixture.session.selectedModelRaw).isEmpty)
    }

    @MainActor
    func testMetadataEchoDoesNotClobberCompoundWhenCatalogUnavailable() async {
        let fixture = await makeMetadataFixture(catalog: nil)
        fixture.session.selectedModelRaw = "codexExec:gpt-5.4-mini-high"
        fixture.session.selectedReasoningEffortRaw = "high"

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.4-mini",
            reasoningEffortRaw: "low",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(fixture.session.selectedModelRaw, "codexExec:gpt-5.4-mini-high")
        XCTAssertEqual(fixture.session.selectedReasoningEffortRaw, "high")
    }

    @MainActor
    func testMetadataEchoAdoptsCompoundForHostDefaultStart() async {
        let fixture = await makeMetadataFixture(catalog: clientStructuredCatalog())
        fixture.session.selectedModelRaw = RemoteHostAgentCatalog.hostDefaultModelID
        fixture.session.selectedReasoningEffortRaw = nil

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.4-mini",
            reasoningEffortRaw: "medium",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(fixture.session.selectedModelRaw, "codexExec:gpt-5.4-mini-medium")
        XCTAssertEqual(fixture.session.selectedReasoningEffortRaw, "medium")
    }

    @MainActor
    func testMetadataEchoLegacyCatalogAdoptsPlainModelWhenSelectionNotCompound() async {
        let fixture = await makeMetadataFixture(catalog: clientLegacyCatalog())
        fixture.session.selectedModelRaw = "local-legacy-model"
        fixture.session.selectedReasoningEffortRaw = nil

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.5",
            reasoningEffortRaw: "high",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(fixture.session.selectedModelRaw, "gpt-5.5")
        XCTAssertEqual(fixture.session.selectedReasoningEffortRaw, "high")
    }

    @MainActor
    func testMetadataEchoSyncsReasoningEffortFromMatchedOption() async {
        let fixture = await makeMetadataFixture(catalog: clientStructuredCatalog())
        fixture.session.selectedModelRaw = "codexExec:gpt-5.4-mini-high"
        fixture.session.selectedReasoningEffortRaw = "stale"

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.4-mini",
            reasoningEffortRaw: "high",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(fixture.session.selectedModelRaw, "codexExec:gpt-5.4-mini-high")
        XCTAssertEqual(fixture.session.selectedReasoningEffortRaw, "high")
    }

    @MainActor
    func testModelIDForStartRemainsResolvableAfterMetadataEcho() async {
        let fixture = await makeMetadataFixture(catalog: clientStructuredCatalog())
        fixture.session.selectedModelRaw = RemoteHostAgentCatalog.hostDefaultModelID

        fixture.coordinator.test_applyMetadata(
            agentKindRaw: "codexExec",
            modelRaw: "gpt-5.4-mini",
            reasoningEffortRaw: "low",
            sessionName: nil,
            tabID: fixture.tabID
        )

        XCTAssertEqual(
            RemoteHostAgentCatalog.modelIDForStart(fixture.session.selectedModelRaw),
            "codexExec:gpt-5.4-mini-low"
        )
    }

    @MainActor
    func testRunningNilStatusTextDoesNotDowngradeHostProvidedLabel() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-running-label")

        coordinator.test_applyRunState(.running, statusText: "Thinking…", to: session)
        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        XCTAssertEqual(session.runningStatusText, "Thinking…")
    }

    @MainActor
    func testRunningNilStatusTextBeforeAnyHostLabelSetsFallback() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-running-fallback")

        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        XCTAssertEqual(session.runningStatusText, "Running on Studio Mac…")
    }

    @MainActor
    func testTerminalClearsHostLabelFlagSoNextRunFallsBackAgain() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-terminal-clears-label")

        coordinator.test_applyRunState(.running, statusText: "Thinking…", to: session)
        coordinator.test_applyTerminal(status: "completed", to: session)
        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        XCTAssertEqual(session.runningStatusText, "Running on Studio Mac…")
    }

    @MainActor
    func testConnectedChannelLabelPersistsThroughNilStatusRunningFrame() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-connected-label")

        coordinator.test_applyRunState(.running, statusText: "Thinking…", to: session)
        coordinator.test_applyChannel(.init(kind: .connected), to: session)
        coordinator.test_applyRunState(.running, statusText: nil, to: session)

        XCTAssertEqual(session.runningStatusText, "Connected to Studio Mac")
    }

    func testCompletePageReconcilesBudgetDroppedRows() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Budget-visible assistant</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 2, status: "completed", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertEqual(batches[1].removedIDs, try [XCTUnwrap(batches[0].items.first?.id)])
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAgentClientFixesTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Client Fixes Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }

    @MainActor
    private func makeSession(remoteSessionID: String) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.remoteHost = Self.makeBinding(remoteSessionID: remoteSessionID)
        return session
    }

    @MainActor
    private func makeMetadataFixture(catalog: RemoteHostAgentCatalog?) async -> RemoteMetadataFixture {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in ClientFixesNoopCodexController() }
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.remoteHost = Self.makeBinding(hostID: "metadata-host", remoteSessionID: "metadata-remote")
        let coordinator = RemoteAgentModeCoordinator(catalogProvider: { _ in catalog })
        coordinator.attach(viewModel: viewModel)
        return RemoteMetadataFixture(
            tabID: tabID,
            viewModel: viewModel,
            session: session,
            coordinator: coordinator
        )
    }

    private func clientStructuredCatalog() -> RemoteHostAgentCatalog {
        RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Codex CLI",
                defaultModelID: "codexExec:gpt-5.4-mini-medium",
                models: [
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4-mini-low",
                        name: "Codex CLI GPT-5.4 Mini Low",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4-mini",
                        effort: "low",
                        modelDisplayName: "GPT-5.4 Mini",
                        effortDisplayName: "Low"
                    ),
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4-mini-medium",
                        name: "Codex CLI GPT-5.4 Mini Medium",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4-mini",
                        effort: "medium",
                        modelDisplayName: "GPT-5.4 Mini",
                        effortDisplayName: "Medium",
                        isDefault: true
                    ),
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4-mini-high",
                        name: "Codex CLI GPT-5.4 Mini High",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4-mini",
                        effort: "high",
                        modelDisplayName: "GPT-5.4 Mini",
                        effortDisplayName: "High"
                    )
                ],
                capabilities: ["agent_conversation_send"]
            )
        ])
    }

    private func clientLegacyCatalog() -> RemoteHostAgentCatalog {
        RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Codex CLI",
                defaultModelID: "codexExec:gpt-5.5-high",
                models: [
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.5-high",
                        name: "Codex CLI GPT-5.5 High",
                        reasoningEffort: "high"
                    )
                ],
                capabilities: ["agent_conversation_send"]
            )
        ])
    }

    private func project(xml: String, sessionID: String, offset: Int = 0) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: sessionID)
            .projectGetLogResponse(Self.logPayload(offset: offset, returned: 1, total: 1, xml: xml, completed: 1))
            .items
    }

    private static func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String = "remote-session-abc",
        lastAppliedSeq: UInt64 = 0,
        nextLogOffset: Int = 0
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            nextLogOffset: nextLogOffset
        )
    }

    private struct RemoteMetadataFixture {
        let tabID: UUID
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let coordinator: RemoteAgentModeCoordinator
    }

    fileprivate static func snapshotPayload(status: String = "running", sessionID: String? = nil, statusText: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let sessionID { payload["session_id"] = .string(sessionID) }
        if let statusText { payload["status_text"] = .string(statusText) }
        return .object(payload)
    }

    fileprivate static func logPayload(offset: Int, returned: Int, total: Int, xml: String, completed: Int? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turn_offset": .int(offset),
            "turn_limit": .int(20),
            "returned_turn_count": .int(returned),
            "total_turns": .int(total),
            "transcript_xml": .string(xml)
        ]
        if let completed { payload["completed_turn_count"] = .int(completed) }
        return .object(payload)
    }

    private func sendFrame(
        type: String,
        seq: UInt64,
        status: String,
        sessionID: String = "remote-session-abc",
        to controller: RemoteAgentSessionController
    ) async {
        await controller.handleInboundFrame(RemoteServerFrame(
            type: type,
            sessionID: sessionID,
            seq: seq,
            payload: Self.snapshotPayload(status: status)
        ))
    }

    private func waitForCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for condition", file: file, line: line)
    }

    private func waitForBatchCount(
        _ count: Int,
        recorder: EventRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 100 {
            if await recorder.batches().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalCount = await recorder.batches().count
        XCTAssertGreaterThanOrEqual(finalCount, count, file: file, line: line)
    }
}

private actor EventRecorder {
    private(set) var transcriptBatches: [(items: [AgentChatItem], removedIDs: [UUID])] = []
    private(set) var runStates: [RemoteSessionEvent] = []

    func record(_ event: RemoteSessionEvent) {
        switch event {
        case let .transcriptRows(items, removedIDs):
            transcriptBatches.append((items, removedIDs))
        case .runState:
            runStates.append(event)
        default:
            break
        }
    }

    func batches() -> [(items: [AgentChatItem], removedIDs: [UUID])] {
        transcriptBatches
    }

    func runStateEvents() -> [RemoteSessionEvent] {
        runStates
    }
}

private actor ScriptedConnection: RemoteAgentSessionConnection {
    private var responses: [String: [JSONValue]]
    private var frames: [RemoteClientFrame] = []

    init(responses: [String: [JSONValue]] = [:]) {
        self.responses = responses
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        if var queued = responses[frame.type], !queued.isEmpty {
            let response = queued.removeFirst()
            responses[frame.type] = queued
            return response
        }
        return defaultResponse(for: frame)
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func commandFrames(type: String) -> [RemoteClientFrame] {
        frames.filter { $0.type == type }
    }

    func getLogRequests() -> [(offset: Int, limit: Int)] {
        frames.compactMap { frame in
            guard frame.type == "get_log" else { return nil }
            let payload = frame.payload?.objectValue ?? [:]
            return (offset: payload["offset"]?.intValue ?? 0, limit: payload["limit"]?.intValue ?? 0)
        }
    }

    private func defaultResponse(for frame: RemoteClientFrame) -> JSONValue {
        switch frame.type {
        case "start":
            RemoteAgentClientFixesTests.snapshotPayload(sessionID: "remote-session-abc")
        case "poll":
            RemoteAgentClientFixesTests.snapshotPayload(status: "running")
        case "get_log":
            RemoteAgentClientFixesTests.logPayload(
                offset: frame.payload?.objectValue?["offset"]?.intValue ?? 0,
                returned: 0,
                total: 0,
                xml: "<transcript/>"
            )
        default:
            .object([:])
        }
    }
}

private final class ClientFixesNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
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
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
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
