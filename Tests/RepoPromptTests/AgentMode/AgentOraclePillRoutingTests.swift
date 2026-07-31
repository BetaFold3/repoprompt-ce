import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentOraclePillRoutingTests: XCTestCase {
    func testExplicitRequestStateRejectsBlankStaleTabAndMismatchedSession() throws {
        let tabID = UUID()
        let otherTabID = UUID()
        let workspaceID = UUID()
        let session = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Exact Session")
        let otherSession = ChatSession(workspaceID: workspaceID, composeTabID: tabID, name: "Other Session")

        XCTAssertNil(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: "  \n ",
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 1
            )
        )

        let request = try XCTUnwrap(
            AgentOraclePillLogic.explicitOpenRequest(
                chatID: session.id.uuidString.lowercased(),
                workspaceID: workspaceID,
                tabID: tabID,
                generation: 4
            )
        )
        XCTAssertTrue(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 5,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertNil(AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: session.id,
            isExplicit: true,
            currentWorkspaceID: UUID(),
            sameTabSessions: [session],
            eligibleSessions: [session],
            streamingSessionIDs: []
        ))
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: otherTabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: otherSession,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: workspaceID,
                currentTabID: tabID
            )
        )
        XCTAssertFalse(
            AgentOraclePillLogic.shouldPresent(
                session: session,
                for: request,
                currentGeneration: 4,
                currentWorkspaceID: UUID(),
                currentTabID: tabID
            )
        )
    }

    func testExactInMemoryResolutionUsesUUIDOrShortIDInsteadOfLatestSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let exact = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "exact", sequenceIndex: 0)]
        )
        let newer = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Session",
            savedAt: Date(timeIntervalSince1970: 200),
            messages: [StoredMessage(isUser: false, rawText: "newer", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [exact, newer]
        let didLoadExactSessionMessages = await fixture.oracleViewModel.ensureSessionMessagesLoaded(exact.id)
        XCTAssertTrue(didLoadExactSessionMessages)

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: fixture.oracleViewModel.sessions(forTabID: fixture.tabID),
                streamingSessionIDs: [newer.id]
            )?.id,
            newer.id
        )

        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, exact.id)

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: exact.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, exact.id)
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: exact.id).count, 1)
    }

    func testLatestStreamingSessionDoesNotFallbackToStaleCompletedSession() {
        let workspaceID = UUID()
        let tabID = UUID()
        let olderStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Older Streaming",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let staleCompleted = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Stale Completed",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let newerStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "Newer Streaming",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let sessions = [olderStreaming, staleCompleted, newerStreaming]

        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.latestStreamingSession(
                in: sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            )?.id,
            newerStreaming.id
        )
        XCTAssertNil(AgentOraclePillLogic.latestStreamingSession(
            in: sessions,
            streamingSessionIDs: []
        ))
        XCTAssertEqual(
            AgentOraclePillLogic.latestSession(
                in: sessions,
                streamingSessionIDs: []
            )?.id,
            staleCompleted.id
        )
        XCTAssertEqual(
            AgentOraclePillLogic.orderedSessions(
                sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id]
            ).map(\.id),
            [newerStreaming.id, olderStreaming.id, staleCompleted.id]
        )
        XCTAssertEqual(
            AgentOraclePillLogic.orderedSessions(
                sessions,
                streamingSessionIDs: [olderStreaming.id, newerStreaming.id],
                completedLimit: 0
            ).map(\.id),
            [newerStreaming.id, olderStreaming.id]
        )
        XCTAssertEqual(
            AgentOraclePillLogic.reconciledPresentedSessionID(
                currentSessionID: olderStreaming.id,
                source: .pinned,
                currentWorkspaceID: workspaceID,
                sameTabSessions: sessions,
                eligibleSessions: sessions,
                streamingSessionIDs: [newerStreaming.id]
            ),
            olderStreaming.id,
            "A manually pinned transcript must not be replaced by a newer stream"
        )

        let activeAgentID = UUID()
        let activeRunID = UUID()
        let ownedCompleted = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: activeAgentID,
            agentModeRunID: activeRunID,
            name: "Owned Completed",
            messages: [StoredMessage(isUser: false, rawText: "owned", sequenceIndex: 0)]
        )
        let foreignStreaming = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: UUID(),
            agentModeRunID: UUID(),
            name: "Foreign Streaming"
        )
        let foreignCompleted = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            agentModeSessionID: UUID(),
            agentModeRunID: UUID(),
            name: "Foreign Completed",
            messages: [StoredMessage(isUser: false, rawText: "foreign", sequenceIndex: 0)]
        )
        let eligible = AgentOraclePillLogic.eligibleSessions(
            sessions: [ownedCompleted, foreignStreaming, foreignCompleted],
            streamingSessionIDs: [foreignStreaming.id],
            liveMessageCount: { _ in nil },
            activeAgentSessionID: activeAgentID,
            activeRunID: activeRunID
        )
        XCTAssertEqual(Set(eligible.map(\.id)), [ownedCompleted.id, foreignStreaming.id])

        let switchedModelSession = ChatSession(
            workspaceID: workspaceID,
            composeTabID: tabID,
            name: "New Chat",
            messages: [StoredMessage(
                isUser: false,
                rawText: "Previous answer",
                sequenceIndex: 0,
                modelName: "Previous Model"
            )],
            lastSendModelID: "current-model-id",
            lastSendModelDisplayName: "Current Model"
        )
        XCTAssertEqual(switchedModelSession.lastResponseModelDisplayName, "Previous Model")
        XCTAssertEqual(
            AgentOraclePillLogic.modelDisplayName(
                for: switchedModelSession,
                streamingSessionIDs: [switchedModelSession.id]
            ),
            "Current Model"
        )
        XCTAssertEqual(
            AgentOraclePillLogic.modelDisplayName(for: switchedModelSession, streamingSessionIDs: []),
            "Previous Model"
        )
        XCTAssertEqual(switchedModelSession.listStub().lastResponseModelDisplayName, "Current Model")
    }

    func testExactPersistedResolutionHydratesAndRegistersUUIDAndShortID() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let persisted = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Exact Session",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "persisted", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persisted,
            for: fixture.workspace
        )
        let distractor = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Newer Distractor",
            savedAt: Date(timeIntervalSince1970: 300),
            messages: [StoredMessage(isUser: false, rawText: "distractor", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [distractor]

        let byShortID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byShortID?.id, persisted.id)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persisted.id })?.messages.count,
            1
        )
        XCTAssertEqual(fixture.oracleViewModel.messagesSnapshot(for: persisted.id).count, 1)

        fixture.oracleViewModel.sessions = [distractor]
        let byUUID = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persisted.id.uuidString.lowercased(),
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(byUUID?.id, persisted.id)
        XCTAssertTrue(fixture.oracleViewModel.sessions.contains(where: { $0.id == persisted.id }))

        let collidingShortID = "shared-oracle-chat"
        let persistedCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Persisted Collision",
            messages: [StoredMessage(isUser: false, rawText: "same-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedCollision,
            for: fixture.workspace
        )
        let wrongTabCollision = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Collision",
            messages: [StoredMessage(isUser: false, rawText: "wrong-tab collision", sequenceIndex: 0)],
            shortID: collidingShortID
        )
        fixture.oracleViewModel.sessions = [distractor, wrongTabCollision]

        let collisionResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: collidingShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertEqual(collisionResult?.id, persistedCollision.id)
        XCTAssertEqual(collisionResult?.composeTabID, fixture.tabID)
    }

    func testOracleLaneSurvivesRunRotationAndRejectsCrossSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let oracle = fixture.oracleViewModel
        let sessionID = UUID()
        let originalRunID = UUID()
        let rotatedRunID = UUID()

        let lane = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: sessionID,
            agentModeRunID: originalRunID,
            name: "Rotated Lane",
            savedAt: Date(timeIntervalSince1970: 100),
            messages: [StoredMessage(isUser: false, rawText: "lane history", sequenceIndex: 0)]
        )
        oracle.sessions = [lane]

        // Explicit continuation from the same Agent Mode session under a rotated run
        // (app relaunch / controller recreation) resumes the lane and advances the
        // ephemeral run stamp.
        let continuedID = try await oracle.locateOrCreateChat(
            lane.id.uuidString,
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: sessionID,
            agentModeRunID: rotatedRunID
        )
        XCTAssertEqual(continuedID, lane.id)
        XCTAssertEqual(
            oracle.sessions.first(where: { $0.id == lane.id })?.agentModeRunID,
            rotatedRunID
        )

        // A different Agent Mode session still fails closed with a discriminating message.
        do {
            _ = try await oracle.locateOrCreateChat(
                lane.id.uuidString,
                tabID: fixture.tabID,
                activateInUI: false,
                agentModeSessionID: UUID(),
                agentModeRunID: rotatedRunID
            )
            XCTFail("Expected cross-session continuation to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("different Agent Mode owner"))
            XCTAssertTrue(error.localizedDescription.contains("different Agent Mode session"))
        }

        // Read-only log recovery works across rotation and never advances the stamp.
        oracle.sessions = [lane]
        let log = try await oracle.tool_oracleChatLog(
            args: ["chat_id": .string(lane.id.uuidString)],
            tabID: fixture.tabID,
            agentModeSessionID: sessionID,
            agentModeRunID: rotatedRunID
        )
        XCTAssertNotNil(log["messages"])
        XCTAssertEqual(
            oracle.sessions.first(where: { $0.id == lane.id })?.agentModeRunID,
            originalRunID
        )

        // Implicit sends (no chat_id) never silently adopt a stale-run lane: after a
        // rotation the send starts a fresh lane. Lane recovery is deliberate —
        // oracle_chat_log (which echoes the chat_id) then explicit continuation.
        let implicitID = try await oracle.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: sessionID,
            agentModeRunID: rotatedRunID
        )
        XCTAssertNotEqual(implicitID, lane.id)
        XCTAssertEqual(
            oracle.sessions.first(where: { $0.id == implicitID })?.agentModeSessionID,
            sessionID
        )

        // An exact-run lane outranks a stale-run lane even when the stale lane is newer.
        let exactLane = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: sessionID,
            agentModeRunID: rotatedRunID,
            name: "Exact Lane",
            savedAt: Date(timeIntervalSince1970: 50),
            messages: [StoredMessage(isUser: false, rawText: "exact history", sequenceIndex: 0)]
        )
        let staleNewerLane = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: sessionID,
            agentModeRunID: originalRunID,
            name: "Stale Newer Lane",
            savedAt: Date(timeIntervalSince1970: 200),
            messages: [StoredMessage(isUser: false, rawText: "stale history", sequenceIndex: 0)]
        )
        oracle.sessions = [staleNewerLane, exactLane]
        let dominantID = try await oracle.locateOrCreateChat(
            nil,
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: sessionID,
            agentModeRunID: rotatedRunID
        )
        XCTAssertEqual(dominantID, exactLane.id)

        // Post-restart shape: the lane is a persisted list stub. Continuation must load
        // it from disk first, then stamp the canonical loaded entry (activate-then-stamp
        // ordering) — keeping messages intact while advancing the run stamp.
        let stubRunID = UUID()
        var persistedLane = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            agentModeSessionID: sessionID,
            agentModeRunID: originalRunID,
            name: "Persisted Stub Lane",
            savedAt: Date(timeIntervalSince1970: 300),
            messages: [StoredMessage(isUser: false, rawText: "stub history", sequenceIndex: 0)]
        )
        persistedLane.fileURL = try await oracle.chatData.saveChatSession(
            persistedLane,
            for: fixture.workspace
        )
        oracle.sessions = [persistedLane.listStub()]
        let stubContinuedID = try await oracle.locateOrCreateChat(
            persistedLane.id.uuidString,
            tabID: fixture.tabID,
            activateInUI: false,
            agentModeSessionID: sessionID,
            agentModeRunID: stubRunID
        )
        XCTAssertEqual(stubContinuedID, persistedLane.id)
        let canonical = try XCTUnwrap(oracle.sessions.first(where: { $0.id == persistedLane.id }))
        XCTAssertEqual(canonical.agentModeRunID, stubRunID)
        XCTAssertEqual(canonical.messages.count, 1)
    }

    func testExactPersistedResolutionRejectsWrongTabAndUnknownWithoutLatestFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let wrongTab = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.otherTabID,
            name: "Wrong Tab Session",
            messages: [StoredMessage(isUser: false, rawText: "wrong tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            wrongTab,
            for: fixture.workspace
        )
        let latest = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Latest Session",
            savedAt: Date(timeIntervalSince1970: 500),
            messages: [StoredMessage(isUser: false, rawText: "latest", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [latest]

        let wrongTabResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: wrongTab.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongTabResult)

        let unknownResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: UUID().uuidString,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(unknownResult)
        XCTAssertEqual(fixture.oracleViewModel.sessions.map(\.id), [latest.id])

        let persistedBeforeReassignment = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Reassigned Session",
            messages: [StoredMessage(isUser: false, rawText: "persisted tab", sequenceIndex: 0)]
        )
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(
            persistedBeforeReassignment,
            for: fixture.workspace
        )
        var reassignedInMemory = persistedBeforeReassignment
        reassignedInMemory.composeTabID = fixture.otherTabID
        fixture.oracleViewModel.sessions = [latest, reassignedInMemory]

        let staleDiskResult = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: persistedBeforeReassignment.shortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(staleDiskResult)
        XCTAssertEqual(
            fixture.oracleViewModel.sessions.first(where: { $0.id == persistedBeforeReassignment.id })?.composeTabID,
            fixture.otherTabID
        )
    }

    func testExactResolutionRejectsSameTabShortIDCollisionsInMemoryAndOnDisk() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let sharedShortID = "same-tab-collision"
        let first = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "First Collision",
            messages: [StoredMessage(isUser: false, rawText: "first", sequenceIndex: 0)],
            shortID: sharedShortID
        )
        let second = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Second Collision",
            messages: [StoredMessage(isUser: false, rawText: "second", sequenceIndex: 0)],
            shortID: sharedShortID
        )

        fixture.oracleViewModel.sessions = [first, second]
        let inMemoryCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(inMemoryCollision)

        _ = try await fixture.oracleViewModel.chatData.saveChatSession(first, for: fixture.workspace)
        _ = try await fixture.oracleViewModel.chatData.saveChatSession(second, for: fixture.workspace)
        fixture.oracleViewModel.sessions = [first]
        let mixedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(mixedCollision)

        fixture.oracleViewModel.sessions = []
        let persistedCollision = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: sharedShortID,
            workspaceID: fixture.workspace.id,
            tabID: fixture.tabID
        )
        XCTAssertNil(persistedCollision)
    }

    func testExactResolutionRejectsWorkspaceMismatch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let session = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Workspace Bound",
            messages: [StoredMessage(isUser: false, rawText: "workspace", sequenceIndex: 0)]
        )
        fixture.oracleViewModel.sessions = [session]

        let wrongWorkspace = await fixture.oracleViewModel.resolveExactSessionForPopover(
            chatID: session.shortID,
            workspaceID: UUID(),
            tabID: fixture.tabID
        )
        XCTAssertNil(wrongWorkspace)
    }

    @MainActor
    private final class OneShotAsyncGate {
        var targetQueryID: UUID?
        private(set) var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func suspendUntilReleased() async {
            guard !released else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class FirstSessionSaveGate {
        private let gate = OneShotAsyncGate()
        private(set) var entryCount = 0

        var entered: Bool {
            gate.entered
        }

        func intercept() async {
            entryCount += 1
            if entryCount == 1 {
                await gate.suspendUntilReleased()
            }
        }

        func release() {
            gate.release()
        }
    }

    @MainActor
    private final class ParallelOracleTransportHarness {
        private var continuations: [String: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]
        private var gitDiffs: [String: String?] = [:]
        private var openedStreamCount = 0

        func makeStream(
            message: AIMessage,
            for model: AIModel
        ) -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>) {
            gitDiffs[model.rawValue] = message.gitDiff
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuations[model.rawValue] = continuation
                openedStreamCount += 1
            }
            return (UUID(), stream)
        }

        func waitUntilOpen(count: Int) async throws {
            try await AsyncTestWait.waitUntil(
                "Parallel Oracle streams opened",
                timeout: 2,
                initialDelayNanoseconds: 1_000_000,
                maximumDelayNanoseconds: 25_000_000
            ) {
                await MainActor.run { self.openedStreamCount >= count }
            }
        }

        func gitDiff(for model: AIModel) -> String? {
            gitDiffs[model.rawValue] ?? nil
        }

        func yield(model: AIModel, text: String, isFinal: Bool = false) {
            guard let continuation = continuations[model.rawValue] else { return }
            continuation.yield(ChatStreamOutput(
                text: text,
                reasoning: nil,
                tokens: ChatTokenInfo(),
                isFinal: isFinal
            ))
        }

        func finish(model: AIModel, text: String) {
            yield(model: model, text: text, isFinal: true)
            continuations[model.rawValue]?.finish()
        }

        func finishAll() {
            continuations.values.forEach { $0.finish() }
        }
    }

    func testParallelOracleSendsUseExactPresetsStayIndependentAndEnforceOverlapPolicies() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let promptViewModel = fixture.composition.promptManager
        let apiSettings = try XCTUnwrap(promptViewModel.apiSettingsViewModel)
        let settings = GlobalSettingsStore.shared
        let presetsManager = ModelPresetsManager.shared
        let previousPresets = presetsManager.presets
        let previousShowPresets = settings.mcpShowModelPresets()
        let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()

        defer {
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            oracle.setOracleRejectedNewSessionCleanupObserverForTesting(nil)
            promptViewModel.setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
            presetsManager.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        let fableModel = AIModel.customProviderUser(name: "parallel-fable-xhigh")
        let solModel = AIModel.customProviderUser(name: "parallel-sol-xhigh")
        let uiModel = AIModel.customProviderUser(name: "parallel-ui-uncapped")
        let otherTabModel = AIModel.customProviderUser(name: "parallel-other-tab")
        let fablePreset = ModelPreset(
            name: "Claude_Fable_xhigh",
            model: fableModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let solPreset = ModelPreset(
            name: "GPT_5_6_Sol_xhigh",
            model: solModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let otherTabPreset = ModelPreset(
            name: "Other_Tab_Oracle",
            model: otherTabModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [fablePreset, solPreset, otherTabPreset]
        settings.setMCPShowModelPresets(true, commit: false)
        settings.setMCPTemporarilyDisablePresets(false, commit: false)
        apiSettings.isCustomProviderValid = true
        promptViewModel.setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
            AutomaticReviewGitDiffResult(
                text: "PARALLEL_REVIEW_CONTEXT",
                completeness: .complete,
                outcomes: [],
                pathIssues: []
            )
        }

        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "",
            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
            lookupContext: nil,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            ),
            provenance: .direct
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            origin: .askOracle,
            packaging: packaging
        )

        let firstTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Independent Fable review"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 1)

        let firstSession = try XCTUnwrap(
            oracle.sessions.first {
                oracle.streamingSessions.contains($0.id) && $0.lastSendModelID == fableModel.rawValue
            }
        )
        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Must not cancel the first lane"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "chat_id": .string(firstSession.shortID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected a busy-session error")
        } catch {
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleSessionBusy)
            XCTAssertTrue(error.localizedDescription.contains("oracle_session_busy"), error.localizedDescription)
            XCTAssertTrue(oracle.streamingSessions.contains(firstSession.id))
        }

        let secondTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Independent Sol review"),
                    "mode": .string("review"),
                    "model": .string(solPreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 2)
        XCTAssertEqual(harness.gitDiff(for: fableModel), "PARALLEL_REVIEW_CONTEXT")
        XCTAssertEqual(harness.gitDiff(for: solModel), "PARALLEL_REVIEW_CONTEXT")

        let streamingSessions = oracle.sessions.filter { oracle.streamingSessions.contains($0.id) }
        XCTAssertEqual(streamingSessions.count, 2)
        XCTAssertEqual(Set(streamingSessions.map(\.id)).count, 2)
        XCTAssertEqual(Set(streamingSessions.map(\.name)).count, 1)
        XCTAssertFalse(streamingSessions[0].name.isEmpty)
        XCTAssertEqual(
            Set(streamingSessions.compactMap(\.lastSendModelID)),
            [fableModel.rawValue, solModel.rawValue]
        )
        let liveList = try await oracle.tool_chatList(args: [
            "scope": .string("tab"),
            "context_id": .string(fixture.tabID.uuidString),
            "limit": .int(1)
        ])
        let liveRows = try XCTUnwrap(liveList["chats"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(liveRows.count, 2, "A completed-result limit must never hide active streams")
        XCTAssertTrue(liveRows.allSatisfy { $0["is_streaming"]?.boolValue == true })
        XCTAssertEqual(
            Set(liveRows.compactMap { $0["model_id"]?.stringValue }),
            [fableModel.rawValue, solModel.rawValue]
        )
        XCTAssertEqual(
            Set(liveRows.compactMap { $0["model_name"]?.stringValue }),
            [fableModel.displayName, solModel.displayName]
        )

        let createdUISessionID = await oracle.startNewChatSession(
            name: "Uncapped UI lane",
            tabID: fixture.tabID,
            activateInUI: false,
            setActiveForTab: false,
            reuseBlankSession: false
        )
        let uiSessionID = try XCTUnwrap(createdUISessionID)
        let uiStart = await oracle.sendMessage(
            "UI sends are not part of the MCP cap",
            sessionID: uiSessionID,
            overrideModel: uiModel,
            origin: .ui
        )
        guard case let .started(uiQueryID) = uiStart else {
            return XCTFail("Expected UI-origin send to bypass the MCP cap, got \(uiStart)")
        }
        try await harness.waitUntilOpen(count: 3)

        let otherPackaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.otherTabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "",
            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
            lookupContext: nil,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            ),
            provenance: .direct
        )
        let otherTabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.otherTabID,
            workspaceID: fixture.workspace.id,
            origin: .askOracle,
            packaging: otherPackaging
        )
        let otherTabTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("A separate tab has its own cap"),
                    "mode": .string("review"),
                    "model": .string(otherTabPreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: otherTabContext
            )
        }
        try await harness.waitUntilOpen(count: 4)
        XCTAssertEqual(
            oracle.sessions.count(where: {
                $0.composeTabID == fixture.tabID && oracle.streamingSessions.contains($0.id)
            }),
            3,
            "Two MCP lanes and an uncapped UI lane should coexist in one tab"
        )
        XCTAssertEqual(
            oracle.sessions.count(where: {
                $0.composeTabID == fixture.otherTabID && oracle.streamingSessions.contains($0.id)
            }),
            1,
            "The MCP cap must be scoped per tab"
        )

        let activeSessionBeforeRejectedThird = oracle.workspaceManager.activeChatSessionID(forTabID: fixture.tabID)

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("A third lane must be capped"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected the per-tab Oracle concurrency cap")
        } catch {
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleConcurrencyLimit)
            XCTAssertTrue(error.localizedDescription.contains("oracle_concurrency_limit"), error.localizedDescription)
            XCTAssertEqual(oracle.streamingSessions.count, 4)
            XCTAssertEqual(
                oracle.sessions.count(where: { $0.composeTabID == fixture.tabID }),
                3,
                "A rejected third lane must not leave a blank orphan session"
            )
            XCTAssertEqual(
                oracle.workspaceManager.activeChatSessionID(forTabID: fixture.tabID),
                activeSessionBeforeRejectedThird,
                "A rejected third lane must restore the exact previously active Oracle chat"
            )
        }

        oracle.setOracleRejectedNewSessionCleanupObserverForTesting { rejectedSessionID, tabID in
            XCTAssertNotEqual(rejectedSessionID, uiSessionID)
            XCTAssertEqual(tabID, fixture.tabID)
            oracle.workspaceManager.setActiveChatSessionID(uiSessionID, forTabID: fixture.tabID)
        }
        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Rejected cleanup must preserve a newer active lane"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected the per-tab Oracle concurrency cap")
        } catch {
            XCTAssertEqual((error as? ChatToolError)?.code, .oracleConcurrencyLimit)
            XCTAssertEqual(
                oracle.workspaceManager.activeChatSessionID(forTabID: fixture.tabID),
                uiSessionID,
                "Rejected cleanup must not overwrite a newer active-chat selection"
            )
            XCTAssertEqual(
                oracle.sessions.count(where: { $0.composeTabID == fixture.tabID }),
                3,
                "The interleaved rejected lane must still be deleted"
            )
        }
        oracle.setOracleRejectedNewSessionCleanupObserverForTesting(nil)

        harness.finish(model: uiModel, text: "UI response")
        try await oracle.waitUntilMessageFinalised(uiQueryID)
        harness.finish(model: otherTabModel, text: "Other tab response")
        let otherTabResult = try await otherTabTask.value
        XCTAssertEqual(otherTabResult["response"]?.stringValue, "Other tab response")
        XCTAssertEqual(oracle.streamingSessions.count, 2)

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("A fuzzy selector must not choose silently"),
                    "mode": .string("review"),
                    "model": .string("Claude_Fable"),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected exact-only preset selection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(fablePreset.name), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(solPreset.name), error.localizedDescription)
        }

        let duplicateFablePreset = ModelPreset(
            name: fablePreset.name.lowercased(),
            model: AIModel.customProviderUser(name: "parallel-duplicate-fable"),
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [fablePreset, solPreset, otherTabPreset, duplicateFablePreset]
        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("An ambiguous exact name must fail closed"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected duplicate exact preset names to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Multiple model presets"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("UUID"), error.localizedDescription)
        }
        presetsManager.presets = [fablePreset, solPreset, otherTabPreset]

        harness.finish(model: solModel, text: "Sol independent response")
        harness.finish(model: fableModel, text: "Fable independent response")
        let secondResult = try await secondTask.value
        let firstResult = try await firstTask.value

        XCTAssertEqual(firstResult["response"]?.stringValue, "Fable independent response")
        XCTAssertEqual(firstResult["model_id"]?.stringValue, fableModel.rawValue)
        XCTAssertEqual(firstResult["model_name"]?.stringValue, fableModel.displayName)
        XCTAssertEqual(firstResult["model_selection"]?.stringValue, "explicit")
        XCTAssertEqual(firstResult["model_source"]?.stringValue, "preset")
        XCTAssertEqual(firstResult["model_preset_id"]?.stringValue, fablePreset.id.uuidString)
        XCTAssertEqual(firstResult["model_preset_name"]?.stringValue, fablePreset.name)
        XCTAssertEqual(secondResult["response"]?.stringValue, "Sol independent response")
        XCTAssertEqual(secondResult["model_id"]?.stringValue, solModel.rawValue)
        XCTAssertEqual(secondResult["model_name"]?.stringValue, solModel.displayName)
        XCTAssertEqual(secondResult["model_selection"]?.stringValue, "explicit")
        XCTAssertEqual(secondResult["model_source"]?.stringValue, "preset")
        XCTAssertEqual(secondResult["model_preset_id"]?.stringValue, solPreset.id.uuidString)
        XCTAssertEqual(secondResult["model_preset_name"]?.stringValue, solPreset.name)
        XCTAssertTrue(oracle.streamingSessions.isEmpty)

        let namedTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Name this lane"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "chat_name": .string("Named Oracle Lane"),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 5)
        let namedSession = try XCTUnwrap(
            oracle.sessions.first {
                oracle.streamingSessions.contains($0.id) && $0.name == "Named Oracle Lane"
            }
        )
        harness.finish(model: fableModel, text: "Named lane response")
        let namedResult = try await namedTask.value
        XCTAssertEqual(namedResult["chat_id"]?.stringValue, namedSession.shortID)
        XCTAssertEqual(namedResult["response"]?.stringValue, "Named lane response")

        let cancelledMCPTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Return a partial response before UI cancellation"),
                    "mode": .string("review"),
                    "model": .string(fablePreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 6)
        let cancellableSession = try XCTUnwrap(
            oracle.sessions.first {
                oracle.streamingSessions.contains($0.id) && $0.lastSendModelID == fableModel.rawValue
            }
        )
        harness.yield(model: fableModel, text: "Partial MCP answer")
        try await AsyncTestWait.waitUntil("MCP partial response became visible") {
            await MainActor.run {
                oracle.messagesSnapshot(for: cancellableSession.id)
                    .contains(where: { !$0.isUser && $0.content.contains("Partial MCP answer") })
            }
        }

        let uiOverrideStart = await oracle.sendMessage(
            "User takes over this chat",
            sessionID: cancellableSession.id,
            overrideModel: solModel,
            overlapPolicy: .cancelExisting,
            origin: .ui
        )
        guard case let .started(uiOverrideQueryID) = uiOverrideStart else {
            return XCTFail("Expected UI override to start, got \(uiOverrideStart)")
        }
        try await harness.waitUntilOpen(count: 7)
        let cancelledMCPResult = try await cancelledMCPTask.value
        XCTAssertEqual(cancelledMCPResult["response"]?.stringValue, "Partial MCP answer")
        XCTAssertTrue(oracle.streamingSessions.contains(cancellableSession.id))

        harness.finish(model: solModel, text: "UI successor response")
        try await oracle.waitUntilMessageFinalised(uiOverrideQueryID)
        XCTAssertFalse(oracle.streamingSessions.contains(cancellableSession.id))

        let persistedURL = try await oracle.autosaveSession(
            XCTUnwrap(oracle.sessions.first(where: { $0.id == firstSession.id }))
        )
        let persisted = try await oracle.chatData.loadChatSession(from: persistedURL)
        XCTAssertEqual(persisted.lastSendModelID, fableModel.rawValue)
        XCTAssertEqual(persisted.lastSendModelDisplayName, fableModel.displayName)

        let clonedIDs = try await oracle.cloneChatSessions(
            fromTabID: fixture.tabID,
            toTabID: fixture.otherTabID
        )
        let clonedID = try XCTUnwrap(clonedIDs[firstSession.id])
        let clone = try XCTUnwrap(oracle.sessions.first(where: { $0.id == clonedID }))
        XCTAssertEqual(clone.lastSendModelID, fableModel.rawValue)
        XCTAssertEqual(clone.lastSendModelDisplayName, fableModel.displayName)
    }

    func testUICancelExistingDoesNotCancelConcurrentMCPSuccessor() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let apiSettings = try XCTUnwrap(fixture.composition.promptManager.apiSettingsViewModel)
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()
        let cancellationFinalizationGate = OneShotAsyncGate()

        defer {
            cancellationFinalizationGate.release()
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            oracle.setOracleCancellationAfterOwnershipClearObserverForTesting(nil)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        apiSettings.isCustomProviderValid = true
        let originalModel = AIModel.customProviderUser(name: "ui-takeover-original")
        let successorModel = AIModel.customProviderUser(name: "ui-takeover-successor")
        let uiModel = AIModel.customProviderUser(name: "ui-takeover-retry")
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let createdSessionID = await oracle.startNewChatSession(
            name: "UI takeover race",
            tabID: fixture.tabID,
            reuseBlankSession: false
        )
        let sessionID = try XCTUnwrap(createdSessionID)
        let originalStart = await oracle.sendMessage(
            "Original MCP request",
            sessionID: sessionID,
            overrideModel: originalModel,
            overlapPolicy: .rejectIfBusy,
            origin: .mcp
        )
        guard case let .started(originalQueryID) = originalStart else {
            return XCTFail("Expected original MCP send to start, got \(originalStart)")
        }
        try await harness.waitUntilOpen(count: 1)
        harness.yield(model: originalModel, text: "Original partial answer")
        try await AsyncTestWait.waitUntil("Original partial response became visible") {
            await MainActor.run {
                oracle.messagesSnapshot(for: sessionID)
                    .contains(where: { !$0.isUser && $0.content.contains("Original partial answer") })
            }
        }

        cancellationFinalizationGate.targetQueryID = originalQueryID
        oracle.setOracleCancellationAfterOwnershipClearObserverForTesting { queryID, _ in
            guard cancellationFinalizationGate.targetQueryID == queryID else { return }
            await cancellationFinalizationGate.suspendUntilReleased()
        }
        let uiTakeoverTask = Task { @MainActor in
            await oracle.sendMessage(
                "Retain this UI retry message",
                sessionID: sessionID,
                overrideModel: uiModel,
                overlapPolicy: .cancelExisting,
                origin: .ui
            )
        }
        try await AsyncTestWait.waitUntil("Original cancellation reached finalization gate") {
            await MainActor.run { cancellationFinalizationGate.entered }
        }

        let successorStart = await oracle.sendMessage(
            "Concurrent MCP successor",
            sessionID: sessionID,
            overrideModel: successorModel,
            overlapPolicy: .rejectIfBusy,
            origin: .mcp
        )
        guard case let .started(successorQueryID) = successorStart else {
            return XCTFail("Expected concurrent MCP successor to start, got \(successorStart)")
        }
        try await harness.waitUntilOpen(count: 2)

        cancellationFinalizationGate.release()
        let uiTakeoverResult = await uiTakeoverTask.value
        XCTAssertEqual(uiTakeoverResult, .rejectedSessionBusy)
        XCTAssertEqual(oracle.activeQueryId(for: sessionID), successorQueryID)
        XCTAssertTrue(oracle.streamingSessions.contains(sessionID))
        let retainedMessages = oracle.messagesSnapshot(for: sessionID)
        XCTAssertTrue(retainedMessages.contains(where: {
            $0.isUser && $0.content == "Retain this UI retry message"
        }))
        XCTAssertTrue(retainedMessages.contains(where: {
            !$0.isUser && $0.content.contains("Please retry this message")
        }))

        harness.finish(model: successorModel, text: "Successor survived UI takeover")
        try await oracle.waitUntilMessageFinalised(successorQueryID)
        XCTAssertFalse(oracle.streamingSessions.contains(sessionID))
        XCTAssertEqual(
            oracle.messagesSnapshot(for: sessionID)
                .first(where: { $0.id == successorQueryID })?.content,
            "Successor survived UI takeover"
        )
    }

    func testCancelledFinalizerCannotOverwriteSuccessorSessionSave() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let apiSettings = try XCTUnwrap(fixture.composition.promptManager.apiSettingsViewModel)
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()
        let finalizationGate = OneShotAsyncGate()
        let saveGate = FirstSessionSaveGate()
        let deletionSaveGate = OneShotAsyncGate()
        let queuedDeletionSaveGate = OneShotAsyncGate()

        defer {
            finalizationGate.release()
            saveGate.release()
            deletionSaveGate.release()
            queuedDeletionSaveGate.release()
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            oracle.setOracleFinalizationBeforeOwnershipCommitObserverForTesting(nil)
            oracle.setOracleSessionSaveWillPersistObserverForTesting(nil)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        apiSettings.isCustomProviderValid = true
        let firstModel = AIModel.customProviderUser(name: "save-race-first")
        let secondModel = AIModel.customProviderUser(name: "save-race-second")
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let createdSessionID = await oracle.startNewChatSession(
            name: "Save race",
            tabID: fixture.tabID,
            reuseBlankSession: false
        )
        let sessionID = try XCTUnwrap(createdSessionID)
        oracle.setOracleFinalizationBeforeOwnershipCommitObserverForTesting { queryID, _ in
            guard finalizationGate.targetQueryID == queryID else { return }
            await finalizationGate.suspendUntilReleased()
        }

        let firstStart = await oracle.sendMessage(
            "First request",
            sessionID: sessionID,
            overrideModel: firstModel
        )
        guard case let .started(firstQueryID) = firstStart else {
            return XCTFail("Expected first send to start, got \(firstStart)")
        }
        finalizationGate.targetQueryID = firstQueryID
        try await harness.waitUntilOpen(count: 1)
        harness.finish(model: firstModel, text: "<chatName=\"Stale Name\"/>First response")
        try await AsyncTestWait.waitUntil("First finalizer reached ownership gate") {
            await MainActor.run { finalizationGate.entered }
        }

        oracle.setOracleSessionSaveWillPersistObserverForTesting { observedSessionID, _ in
            guard observedSessionID == sessionID else { return }
            await saveGate.intercept()
        }

        let secondStart = await oracle.sendMessage(
            "Second request",
            sessionID: sessionID,
            overrideModel: secondModel
        )
        guard case let .started(secondQueryID) = secondStart else {
            return XCTFail("Expected successor send to start, got \(secondStart)")
        }
        try await harness.waitUntilOpen(count: 2)
        try await AsyncTestWait.waitUntil("Cancellation save reached persistence gate") {
            await MainActor.run { saveGate.entered }
        }

        // Let the older cancellation snapshot finish while the successor is
        // still streaming. Its watcher must merge persistence metadata without
        // reinstalling stale messages or model attribution.
        saveGate.release()
        await oracle.waitForSessionSavesForTesting(sessionID)
        try await AsyncTestWait.waitUntil("Older save watcher published its file URL") {
            await MainActor.run {
                oracle.sessions.first(where: { $0.id == sessionID })?.fileURL != nil
            }
        }
        let liveSuccessor = try XCTUnwrap(oracle.sessions.first(where: { $0.id == sessionID }))
        XCTAssertEqual(saveGate.entryCount, 1)
        XCTAssertEqual(liveSuccessor.lastSendModelID, secondModel.rawValue)
        XCTAssertEqual(liveSuccessor.lastSendModelDisplayName, secondModel.displayName)
        XCTAssertEqual(oracle.messagesSnapshot(for: sessionID).count, 4)

        finalizationGate.release()
        harness.finish(model: secondModel, text: "Second response")
        try await oracle.waitUntilMessageFinalised(secondQueryID)
        await oracle.waitForSessionSavesForTesting(sessionID)
        try await AsyncTestWait.waitUntil("Successor session file URL published") {
            await MainActor.run {
                oracle.sessions.first(where: { $0.id == sessionID })?.fileURL != nil
            }
        }

        let savedSession = try XCTUnwrap(oracle.sessions.first(where: { $0.id == sessionID }))
        let fileURL = try XCTUnwrap(savedSession.fileURL)
        let persisted = try await oracle.chatData.loadChatSession(from: fileURL)
        XCTAssertEqual(saveGate.entryCount, 2, "The stale finalizer must not enqueue a third save")
        XCTAssertEqual(persisted.messages.count, 4)
        XCTAssertEqual(persisted.messages.last?.rawText, "Second response")
        XCTAssertEqual(persisted.messages.last?.modelName, secondModel.displayName)
        XCTAssertEqual(persisted.name, "Save race", "A stale finalizer must not rename the successor session")
        XCTAssertEqual(persisted.lastSendModelID, secondModel.rawValue)
        XCTAssertEqual(persisted.lastSendModelDisplayName, secondModel.displayName)

        oracle.setOracleSessionSaveWillPersistObserverForTesting { observedSessionID, _ in
            guard observedSessionID == sessionID else { return }
            await deletionSaveGate.suspendUntilReleased()
        }
        oracle.autosaveChatHistory(for: sessionID, force: true)
        try await AsyncTestWait.waitUntil("Pre-deletion session save blocked") {
            await MainActor.run { deletionSaveGate.entered }
        }
        let releaseDeletionSave = Task { @MainActor in
            await Task.yield()
            deletionSaveGate.release()
        }
        await oracle.deleteSession(savedSession)
        await releaseDeletionSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(oracle.sessions.contains(where: { $0.id == sessionID }))

        do {
            _ = try await oracle.autosaveSession(savedSession)
            XCTFail("A tombstoned session must not be recreated")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // Regression: if two saves are queued for a never-published session, the
        // first can create its file while deletion tombstones the second. Deletion
        // must discover the predecessor's successful URL even though the tail fails.
        let createdQueuedDeletionSessionID = await oracle.startNewChatSession(
            name: "Queued deletion race",
            tabID: fixture.tabID,
            reuseBlankSession: false
        )
        let queuedDeletionSessionID = try XCTUnwrap(createdQueuedDeletionSessionID)
        let queuedDeletionSession = try XCTUnwrap(
            oracle.sessions.first(where: { $0.id == queuedDeletionSessionID })
        )
        oracle.setOracleSessionSaveWillPersistObserverForTesting { observedSessionID, _ in
            guard observedSessionID == queuedDeletionSessionID else { return }
            await queuedDeletionSaveGate.suspendUntilReleased()
        }
        oracle.autosaveChatHistory(for: queuedDeletionSessionID, force: true)
        oracle.autosaveChatHistory(for: queuedDeletionSessionID, force: true)
        try await AsyncTestWait.waitUntil("First queued deletion save blocked") {
            await MainActor.run { queuedDeletionSaveGate.entered }
        }

        let queuedDeletionTask = Task { @MainActor in
            await oracle.deleteSession(queuedDeletionSession)
        }
        try await AsyncTestWait.waitUntil("Queued deletion session tombstoned") {
            await MainActor.run { oracle.isSessionTombstonedForTesting(queuedDeletionSessionID) }
        }
        queuedDeletionSaveGate.release()
        await queuedDeletionTask.value

        let remainingSessionFiles = try await oracle.chatData.listChatSessions(for: fixture.workspace)
        for remainingSessionFile in remainingSessionFiles {
            let remainingSession = try await oracle.chatData.loadChatSession(from: remainingSessionFile)
            XCTAssertNotEqual(remainingSession.id, queuedDeletionSessionID)
        }
        XCTAssertFalse(oracle.sessions.contains(where: { $0.id == queuedDeletionSessionID }))
    }

    func testForkBeforeLatestAssistantDerivesIncludedModelAttribution() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        defer { fixture.cleanup() }

        let firstUser = StoredMessage(isUser: true, rawText: "First", sequenceIndex: 0)
        let firstAssistant = StoredMessage(
            isUser: false,
            rawText: "Model A response",
            sequenceIndex: 1,
            modelName: "Model A"
        )
        let secondUser = StoredMessage(isUser: true, rawText: "Second", sequenceIndex: 2)
        let secondAssistant = StoredMessage(
            isUser: false,
            rawText: "Model B response",
            sequenceIndex: 3,
            modelName: "Model B"
        )
        let original = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Fork source",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            lastSendModelID: "model-b-id",
            lastSendModelDisplayName: "Stale Model B"
        )
        oracle.sessions = [original]
        await oracle.switchToSession(original.id)

        await oracle.forkChatSession(from: firstAssistant.id)
        let forkID = try XCTUnwrap(oracle.currentSessionID)
        XCTAssertNotEqual(forkID, original.id)
        await oracle.waitForSessionSavesForTesting(forkID)
        try await AsyncTestWait.waitUntil("Fork file URL published") {
            await MainActor.run {
                oracle.sessions.first(where: { $0.id == forkID })?.fileURL != nil
            }
        }

        let fork = try XCTUnwrap(oracle.sessions.first(where: { $0.id == forkID }))
        XCTAssertNil(fork.lastSendModelID)
        XCTAssertEqual(fork.lastSendModelDisplayName, "Model A")
        let persisted = try await oracle.chatData.loadChatSession(from: XCTUnwrap(fork.fileURL))
        XCTAssertNil(persisted.lastSendModelID)
        XCTAssertEqual(persisted.lastSendModelDisplayName, "Model A")
        XCTAssertEqual(persisted.listStub().lastSendModelDisplayName, "Model A")

        await oracle.switchToSession(original.id)
        await oracle.forkChatSession(from: secondAssistant.id)
        let fullForkID = try XCTUnwrap(oracle.currentSessionID)
        let fullFork = try XCTUnwrap(oracle.sessions.first(where: { $0.id == fullForkID }))
        XCTAssertEqual(fullFork.lastSendModelID, "model-b-id")
        XCTAssertEqual(
            fullFork.lastSendModelDisplayName,
            "Model B",
            "A full fork must prefer the included assistant message over stale denormalized metadata"
        )
    }

    func testHeadlessSessionPersistsRawAndDisplayModelAttribution() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        defer { fixture.cleanup() }

        let model = AIModel.customProviderUser(name: "headless-model-raw")
        let result = try await oracle.createSessionFromHeadlessRun(
            prompt: "Plan this",
            response: "Headless response",
            model: model,
            tokenInfo: ChatTokenInfo(),
            selection: StoredSelection(),
            chatName: "Headless attribution",
            chatPresetID: nil,
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id
        )

        XCTAssertEqual(result.session.lastSendModelID, model.rawValue)
        XCTAssertEqual(result.session.lastSendModelDisplayName, model.displayName)
        XCTAssertEqual(result.session.messages.last?.modelName, model.displayName)
        let fileURL = try XCTUnwrap(result.session.fileURL)
        let persisted = try await oracle.chatData.loadChatSession(from: fileURL)
        XCTAssertEqual(persisted.lastSendModelID, model.rawValue)
        XCTAssertEqual(persisted.lastSendModelDisplayName, model.displayName)
        XCTAssertEqual(persisted.messages.last?.modelName, model.displayName)
        let stub = persisted.listStub()
        XCTAssertEqual(stub.lastSendModelID, model.rawValue)
        XCTAssertEqual(stub.lastResponseModelDisplayName, model.displayName)
    }

    func testChatIDContinuationInheritsLanePresetAndSupportsExplicitMigration() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let promptViewModel = fixture.composition.promptManager
        let apiSettings = try XCTUnwrap(promptViewModel.apiSettingsViewModel)
        let settings = GlobalSettingsStore.shared
        let presetsManager = ModelPresetsManager.shared
        let previousPresets = presetsManager.presets
        let previousShowPresets = settings.mcpShowModelPresets()
        let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()

        defer {
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            presetsManager.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        let fableModel = AIModel.customProviderUser(name: "inheritance-fable")
        let solModel = AIModel.customProviderUser(name: "inheritance-sol")
        let fablePreset = ModelPreset(
            name: "Inheritance Fable",
            model: fableModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let solPreset = ModelPreset(
            name: "Inheritance Sol",
            model: solModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [fablePreset, solPreset]
        settings.setMCPShowModelPresets(true, commit: false)
        settings.setMCPTemporarilyDisablePresets(false, commit: false)
        apiSettings.isCustomProviderValid = true
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "",
            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
            lookupContext: nil,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            ),
            provenance: .direct
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            origin: .askOracle,
            packaging: packaging
        )

        let openFableTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Open Fable lane"),
                    "mode": .string("chat"),
                    "model": .string(fablePreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 1)
        harness.finish(model: fableModel, text: "Fable opened")
        let openFableResult = try await openFableTask.value
        let fableChatID = try XCTUnwrap(openFableResult["chat_id"]?.stringValue)

        let openSolTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Open Sol lane"),
                    "mode": .string("chat"),
                    "model": .string(solPreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 2)
        harness.finish(model: solModel, text: "Sol opened")
        let openSolResult = try await openSolTask.value
        let solChatID = try XCTUnwrap(openSolResult["chat_id"]?.stringValue)

        let inheritSolTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Continue Sol lane"),
                    "mode": .string("chat"),
                    "chat_id": .string(solChatID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 3)
        harness.finish(model: solModel, text: "Sol continued")
        let inheritSolResult = try await inheritSolTask.value
        XCTAssertEqual(
            inheritSolResult["model_preset_id"]?.stringValue,
            solPreset.id.uuidString,
            "Resolving Fable here would reproduce the pre-fix wrong-lane available.first defect"
        )
        XCTAssertEqual(inheritSolResult["model_id"]?.stringValue, solModel.rawValue)
        XCTAssertEqual(inheritSolResult["model_selection"]?.stringValue, "inherited")

        presetsManager.presets = [solPreset, fablePreset]
        let inheritFableTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Continue Fable lane"),
                    "mode": .string("chat"),
                    "chat_id": .string(fableChatID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 4)
        harness.finish(model: fableModel, text: "Fable continued")
        let inheritFableResult = try await inheritFableTask.value
        XCTAssertEqual(inheritFableResult["model_preset_id"]?.stringValue, fablePreset.id.uuidString)
        XCTAssertEqual(inheritFableResult["model_id"]?.stringValue, fableModel.rawValue)
        XCTAssertEqual(inheritFableResult["model_selection"]?.stringValue, "inherited")

        let migrateSolTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Migrate Sol lane to Fable"),
                    "mode": .string("chat"),
                    "model": .string(fablePreset.id.uuidString),
                    "chat_id": .string(solChatID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 5)
        harness.finish(model: fableModel, text: "Sol lane migrated")
        let migrateSolResult = try await migrateSolTask.value
        XCTAssertEqual(migrateSolResult["model_selection"]?.stringValue, "explicit")
        XCTAssertEqual(migrateSolResult["model_preset_id"]?.stringValue, fablePreset.id.uuidString)
        let migratedSolSession = try XCTUnwrap(oracle.sessions.first(where: { $0.shortID == solChatID }))
        XCTAssertEqual(migratedSolSession.lastSendModelPresetID, fablePreset.id)
    }

    func testChatIDContinuationFailsClosedInsteadOfSubstitutingAPreset() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let promptViewModel = fixture.composition.promptManager
        let apiSettings = try XCTUnwrap(promptViewModel.apiSettingsViewModel)
        let settings = GlobalSettingsStore.shared
        let presetsManager = ModelPresetsManager.shared
        let previousPresets = presetsManager.presets
        let previousShowPresets = settings.mcpShowModelPresets()
        let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()

        defer {
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            presetsManager.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        settings.setMCPShowModelPresets(true, commit: false)
        settings.setMCPTemporarilyDisablePresets(false, commit: false)
        apiSettings.isCustomProviderValid = true
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "",
            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
            lookupContext: nil,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            ),
            provenance: .direct
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            origin: .askOracle,
            packaging: packaging
        )

        let deletedModel = AIModel.customProviderUser(name: "fail-closed-deleted")
        let survivingModel = AIModel.customProviderUser(name: "fail-closed-surviving")
        let deletedPreset = ModelPreset(
            name: "Deleted Bound Preset",
            model: deletedModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let survivingPreset = ModelPreset(
            name: "Surviving Preset",
            model: survivingModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [deletedPreset, survivingPreset]

        let openDeletedTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Open soon-to-be-deleted lane"),
                    "mode": .string("chat"),
                    "model": .string(deletedPreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 1)
        harness.finish(model: deletedModel, text: "Deleted preset lane opened")
        let openDeletedResult = try await openDeletedTask.value
        let deletedChatID = try XCTUnwrap(openDeletedResult["chat_id"]?.stringValue)
        presetsManager.presets = [survivingPreset]

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Must not substitute surviving preset"),
                    "mode": .string("chat"),
                    "chat_id": .string(deletedChatID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected deleted bound preset continuation to fail closed")
        } catch let error as ChatToolError {
            XCTAssertTrue(error.localizedDescription.contains("no longer exists"), error.localizedDescription)
        } catch {
            XCTFail("Expected ChatToolError, got \(error)")
        }
        XCTAssertTrue(oracle.streamingSessions.isEmpty, "Preset resolution failure must not start a send")
        XCTAssertFalse(
            oracle.sessions.contains(where: { $0.lastSendModelID == survivingModel.rawValue }),
            "The surviving preset must not be substituted for a deleted lane binding"
        )

        let modeModel = AIModel.customProviderUser(name: "fail-closed-mode")
        let modePreset = ModelPreset(
            name: "Mode Bound Preset",
            model: modeModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [modePreset, survivingPreset]
        let openModeTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Open mode-bound lane"),
                    "mode": .string("chat"),
                    "model": .string(modePreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 2)
        harness.finish(model: modeModel, text: "Mode-bound lane opened")
        let openModeResult = try await openModeTask.value
        let modeChatID = try XCTUnwrap(openModeResult["chat_id"]?.stringValue)
        let incompatibleModePreset = ModelPreset(
            id: modePreset.id,
            name: modePreset.name,
            model: modeModel,
            supportedModes: SupportedModes(chat: true, plan: false, review: true)
        )
        presetsManager.presets = [incompatibleModePreset, survivingPreset]

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Plan with incompatible bound preset"),
                    "mode": .string("plan"),
                    "chat_id": .string(modeChatID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected mode-incompatible bound preset continuation to fail closed")
        } catch let error as ChatToolError {
            XCTAssertTrue(error.localizedDescription.contains("'plan' mode"), error.localizedDescription)
        } catch {
            XCTFail("Expected ChatToolError, got \(error)")
        }
        XCTAssertTrue(oracle.streamingSessions.isEmpty, "Mode incompatibility must not start a send")

        let sharedModel = AIModel.customProviderUser(name: "fail-closed-shared-model")
        let sharedPresetOne = ModelPreset(
            name: "Shared Model One",
            model: sharedModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let sharedPresetTwo = ModelPreset(
            name: "Shared Model Two",
            model: sharedModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let legacySession = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Legacy model-attributed lane",
            messages: [StoredMessage(isUser: false, rawText: "Earlier response", sequenceIndex: 0)],
            lastSendModelID: sharedModel.rawValue,
            lastSendModelDisplayName: sharedModel.displayName,
            lastSendModelPresetID: nil
        )
        oracle.sessions.append(legacySession)
        presetsManager.presets = [sharedPresetOne, sharedPresetTwo]

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Ambiguous legacy continuation"),
                    "mode": .string("chat"),
                    "chat_id": .string(legacySession.shortID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected ambiguous legacy model attribution to fail closed")
        } catch let error as ChatToolError {
            XCTAssertTrue(error.localizedDescription.contains("ambiguous"), error.localizedDescription)
        } catch {
            XCTFail("Expected ChatToolError, got \(error)")
        }
        XCTAssertTrue(oracle.streamingSessions.isEmpty, "Ambiguous preset inheritance must not start a send")

        presetsManager.presets = [sharedPresetOne]
        let uniqueLegacyTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Unique legacy continuation"),
                    "mode": .string("chat"),
                    "chat_id": .string(legacySession.shortID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 3)
        harness.finish(model: sharedModel, text: "Unique legacy preset inherited")
        let uniqueLegacyResult = try await uniqueLegacyTask.value
        XCTAssertEqual(uniqueLegacyResult["model_selection"]?.stringValue, "inherited")
        XCTAssertEqual(uniqueLegacyResult["model_preset_id"]?.stringValue, sharedPresetOne.id.uuidString)
    }

    /// Pins the two contested policy edges of continuation inheritance:
    /// a UI send resets the lane binding, and a chat with no recorded attribution at all is
    /// treated by message count rather than blanket-automatic.
    func testUnattributedContinuationPolicyAndUISendResetsLaneBinding() async throws {
        let fixture = try await makeFixture()
        let oracle = fixture.oracleViewModel
        let promptViewModel = fixture.composition.promptManager
        let apiSettings = try XCTUnwrap(promptViewModel.apiSettingsViewModel)
        let settings = GlobalSettingsStore.shared
        let presetsManager = ModelPresetsManager.shared
        let previousPresets = presetsManager.presets
        let previousShowPresets = settings.mcpShowModelPresets()
        let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
        let previousCustomProviderValidity = apiSettings.isCustomProviderValid
        let harness = ParallelOracleTransportHarness()

        defer {
            harness.finishAll()
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            presetsManager.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            apiSettings.isCustomProviderValid = previousCustomProviderValidity
            fixture.cleanup()
        }

        let firstModel = AIModel.customProviderUser(name: "policy-first")
        let boundModel = AIModel.customProviderUser(name: "policy-bound")
        let uiModel = AIModel.customProviderUser(name: "policy-ui")
        let firstPreset = ModelPreset(
            name: "Policy_First",
            model: firstModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        let boundPreset = ModelPreset(
            name: "Policy_Bound",
            model: boundModel,
            supportedModes: SupportedModes(chat: true, plan: true, review: true)
        )
        presetsManager.presets = [firstPreset, boundPreset]
        settings.setMCPShowModelPresets(true, commit: false)
        settings.setMCPTemporarilyDisablePresets(false, commit: false)
        apiSettings.isCustomProviderValid = true

        oracle.setOraclePostPackagingTransportOverrideForTesting { message, model in
            harness.makeStream(message: message, for: model)
        }

        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: fixture.tabID,
            sourceWorkspaceID: fixture.workspace.id,
            sourceSelectionRevision: 0,
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            promptText: "",
            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
            lookupContext: nil,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            ),
            provenance: .direct
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspace.id,
            origin: .askOracle,
            packaging: packaging
        )

        // Bind a lane to the preset that is NOT first in the available list.
        let openTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Open bound lane"),
                    "mode": .string("chat"),
                    "model": .string(boundPreset.id.uuidString),
                    "new_chat": .bool(true)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 1)
        harness.finish(model: boundModel, text: "Bound lane opened")
        let openResult = try await openTask.value
        let boundChatID = try XCTUnwrap(openResult["chat_id"]?.stringValue)
        let boundSession = try XCTUnwrap(oracle.sessions.first(where: { $0.shortID == boundChatID }))
        XCTAssertEqual(boundSession.lastSendModelPresetID, boundPreset.id)

        // A UI send has no ModelPreset identity, so it must clear the binding rather than leave a
        // stale preset paired with a newer model. Attribution is recorded at send reservation.
        let uiSendStart = await oracle.sendMessage(
            "User typed directly into this lane",
            sessionID: boundSession.id,
            overrideModel: uiModel,
            overrideModelPresetID: nil,
            overlapPolicy: .rejectIfBusy,
            origin: .ui
        )
        guard case .started = uiSendStart else {
            XCTFail("Expected the UI send to start, got \(uiSendStart)")
            return
        }
        let afterUISend = try XCTUnwrap(oracle.sessions.first(where: { $0.id == boundSession.id }))
        XCTAssertNil(
            afterUISend.lastSendModelPresetID,
            "A UI send must reset the lane binding instead of leaving a stale preset/model pair"
        )
        XCTAssertEqual(afterUISend.lastSendModelID, uiModel.rawValue)
        try await harness.waitUntilOpen(count: 2)
        harness.finish(model: uiModel, text: "UI reply")

        // Non-empty chat with no recorded attribution at all: its historical model is unrecoverable
        // (per-message model names are display strings), so an ambiguous guess must fail loudly.
        let unattributedSession = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Unattributed history",
            messages: [StoredMessage(isUser: false, rawText: "Earlier response", sequenceIndex: 0)],
            lastSendModelID: nil,
            lastSendModelDisplayName: nil,
            lastSendModelPresetID: nil
        )
        oracle.sessions.append(unattributedSession)
        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("Continue unattributed history"),
                    "mode": .string("chat"),
                    "chat_id": .string(unattributedSession.shortID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
            XCTFail("Expected unattributed non-empty history to fail closed while ambiguous")
        } catch let error as ChatToolError {
            XCTAssertTrue(
                error.localizedDescription.contains("no recorded model attribution"),
                error.localizedDescription
            )
        } catch {
            XCTFail("Expected ChatToolError, got \(error)")
        }
        // Scoped to this chat on purpose: the earlier UI send may still be settling, so global
        // stream emptiness is not the invariant under test.
        XCTAssertFalse(
            oracle.streamingSessions.contains(unattributedSession.id),
            "An ambiguity failure must not start a send for the chat it rejected"
        )
        XCTAssertNil(
            oracle.sessions.first(where: { $0.id == unattributedSession.id })?.lastSendModelID,
            "A rejected continuation must not record attribution"
        )

        // A never-sent chat has no binding to preserve, so automatic selection stays available and
        // is reported honestly as automatic rather than inherited.
        let neverSentSession = ChatSession(
            workspaceID: fixture.workspace.id,
            composeTabID: fixture.tabID,
            name: "Never sent",
            messages: []
        )
        oracle.sessions.append(neverSentSession)
        let neverSentTask = Task { @MainActor in
            try await oracle.tool_chatSend(
                args: [
                    "message": .string("Continue never-sent chat"),
                    "mode": .string("chat"),
                    "chat_id": .string(neverSentSession.shortID)
                ],
                promptVM: promptViewModel,
                tabContext: tabContext
            )
        }
        try await harness.waitUntilOpen(count: 3)
        harness.finish(model: firstModel, text: "Automatic selection for an empty chat")
        let neverSentResult = try await neverSentTask.value
        XCTAssertEqual(neverSentResult["model_selection"]?.stringValue, "automatic")
        XCTAssertEqual(neverSentResult["model_preset_id"]?.stringValue, firstPreset.id.uuidString)
    }

    private static var nextFixtureWindowID = -1200

    private static func allocateFixtureWindowID() -> Int {
        nextFixtureWindowID -= 1
        return nextFixtureWindowID
    }

    private func makeFixture() async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let composition = WindowStateCompositionFactory.make(
            windowID: Self.allocateFixtureWindowID(),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOraclePillRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = UUID()
        let otherTabID = UUID()
        workspace.customStoragePath = storageRoot
        workspace.composeTabs = [ComposeTabState(id: tabID), ComposeTabState(id: otherTabID)]
        workspace.activeComposeTabID = tabID
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        composition.oracleViewModel.sessions = []

        return Fixture(
            composition: composition,
            workspace: workspace,
            tabID: tabID,
            otherTabID: otherTabID,
            storageRoot: storageRoot
        )
    }

    @MainActor
    private struct Fixture {
        let composition: WindowStateComposition
        let workspace: WorkspaceModel
        let tabID: UUID
        let otherTabID: UUID
        let storageRoot: URL

        var oracleViewModel: OracleViewModel {
            composition.oracleViewModel
        }

        func cleanup() {
            oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }
}
