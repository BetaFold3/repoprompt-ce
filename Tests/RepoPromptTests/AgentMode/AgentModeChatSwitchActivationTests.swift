import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentModeChatSwitchActivationTests: XCTestCase {
    func testHandoffRebindsComposerAndRejectsStaleSourceSubmitTarget() async throws {
        try await withFixture { fixture in
            let sourceTarget = try XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget)
            XCTAssertEqual(sourceTarget.tabID, fixture.tabAID)
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
            XCTAssertEqual(fixture.window.workspaceManager.activeAgentSessionID(forTabID: destinationTabID), destinationSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertTrue(destinationSession.pendingHandoff.hasPayload)
            XCTAssertEqual(destinationSession.pendingHandoff.sourceItemID, cutoffItemID)

            let composerProps = fixture.viewModel.ui.composer.props
            XCTAssertEqual(composerProps.currentTabID, destinationTabID)
            let destinationTarget = try XCTUnwrap(composerProps.submitTarget)
            XCTAssertEqual(destinationTarget.tabID, destinationTabID)
            XCTAssertEqual(destinationTarget.expectedSourceAgentSessionID, destinationSessionID)
            XCTAssertEqual(
                destinationTarget.expectedSourceTabSessionIdentity,
                ObjectIdentifier(destinationSession)
            )

            let staleAttempt = AgentComposerSubmitAttempt(
                id: UUID(),
                target: sourceTarget,
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "must not reach the source"
            )
            switch fixture.viewModel.claimComposerSubmitAttempt(staleAttempt) {
            case .claimed:
                XCTFail("The source composer target must not survive destination activation")
            case let .rejected(rejection):
                XCTAssertEqual(
                    rejection,
                    .targetRejected(reason: "inactive_composer_tab")
                )
            }
            XCTAssertNil(fixture.sessionA.activeComposerSubmitAttempt)
            XCTAssertEqual(fixture.viewModel.ui.composer.props.currentTabID, destinationTabID)

            let destinationAttempt = try AgentComposerSubmitAttempt(
                id: UUID(),
                target: XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget),
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "destination draft"
            )
            let destinationClaim: AgentModeViewModel.AgentComposerSubmitClaim
            switch fixture.viewModel.claimComposerSubmitAttempt(destinationAttempt) {
            case let .claimed(claim):
                destinationClaim = claim
            case let .rejected(rejection):
                return XCTFail("Expected destination composer recovery, got \(rejection)")
            }
            XCTAssertTrue(fixture.viewModel.releaseComposerSubmitClaim(destinationClaim))
            XCTAssertNotNil(fixture.viewModel.ui.composer.props.submitTarget)
        }
    }

    func testPrepareHandoffHeadlessKeepsForegroundTabAndStagesFullTranscriptPayload() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)

            let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)
            XCTAssertNotEqual(destinationTabID, fixture.tabBID)

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertNil(destinationSession.pendingHandoff.sourceItemID)
            let pendingPayload = try XCTUnwrap(destinationSession.pendingHandoff.payload)
            XCTAssertTrue(pendingPayload.hasPrefix("<forked_session"))

            let composed = fixture.viewModel.prependPendingHandoffIfNeeded(
                "continue from the fork",
                session: destinationSession
            )
            XCTAssertEqual(composed, pendingPayload + "\n\ncontinue from the fork")
        }
    }

    func testHandoffClonesOracleChatsIntoDestinationOwnershipAndPreservesFailClosedBoundaries() async throws {
        try await withFixture { fixture in
            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.id)
            let oracle = fixture.window.oracleViewModel
            let sourceRunID = UUID()
            let thirdPartySessionID = UUID()
            let primarySourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: fixture.sessionAID,
                agentModeRunID: sourceRunID,
                name: "Primary Handoff Oracle",
                messages: [
                    StoredMessage(isUser: true, rawText: "source question", sequenceIndex: 0),
                    StoredMessage(isUser: false, rawText: "source answer", sequenceIndex: 1)
                ]
            )
            let otherSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: fixture.sessionAID,
                agentModeRunID: sourceRunID,
                name: "Other Source Oracle",
                messages: [StoredMessage(isUser: false, rawText: "other source answer", sequenceIndex: 0)]
            )
            let unownedSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                name: "Unowned Source Oracle",
                messages: [
                    StoredMessage(
                        isUser: false,
                        rawText: "unowned source answer",
                        sequenceIndex: 0
                    )
                ]
            )
            let foreignSourceChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabAID,
                agentModeSessionID: thirdPartySessionID,
                agentModeRunID: UUID(),
                name: "Foreign Source Oracle",
                messages: [
                    StoredMessage(
                        isUser: false,
                        rawText: "foreign source answer",
                        sequenceIndex: 0
                    )
                ]
            )
            let thirdPartyChat = ChatSession(
                workspaceID: workspaceID,
                composeTabID: fixture.tabBID,
                agentModeSessionID: thirdPartySessionID,
                agentModeRunID: UUID(),
                name: "Third Party Oracle",
                messages: [StoredMessage(isUser: false, rawText: "third party answer", sequenceIndex: 0)]
            )
            oracle.sessions = [
                primarySourceChat,
                otherSourceChat,
                unownedSourceChat,
                foreignSourceChat,
                thirdPartyChat
            ]
            fixture.window.workspaceManager.setActiveChatSessionID(
                primarySourceChat.id,
                forTabID: fixture.tabAID
            )

            let invocationID = UUID()
            let handoffModel = AIModel.claudeCodeSonnet
            let oracleArgs = #"{"chat_id":"\#(primarySourceChat.shortID)"}"#
            fixture.sessionA.setItemsSilently(
                [
                    .user("A user", sequenceIndex: 0),
                    .toolCall(
                        name: "ask_oracle",
                        invocationID: invocationID,
                        argsJSON: oracleArgs,
                        sequenceIndex: 1
                    ),
                    .toolResult(
                        name: "ask_oracle",
                        invocationID: invocationID,
                        argsJSON: oracleArgs,
                        resultJSON: #"{"chat_id":"\#(primarySourceChat.shortID)","model_source":"preset","ui_model_id":"\#(handoffModel.rawValue)","ui_model_name":"\#(handoffModel.displayName)","response":"source answer"}"#,
                        isError: false,
                        sequenceIndex: 2
                    ),
                    .assistant(
                        "Continue Oracle chat \(primarySourceChat.id.uuidString) from the surrounding prose.",
                        sequenceIndex: 3
                    )
                ],
                reason: .testOverride
            )
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)

            let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
                sourceTabID: fixture.tabAID,
                upToItemID: nil,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )
            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)

            let primaryClone = try XCTUnwrap(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID && $0.name == primarySourceChat.name
                }
            )
            let otherClone = try XCTUnwrap(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID && $0.name == otherSourceChat.name
                }
            )
            for clone in [primaryClone, otherClone] {
                XCTAssertEqual(clone.agentModeSessionID, destinationSessionID)
                XCTAssertNil(clone.agentModeRunID)
            }

            let payload = try XCTUnwrap(destinationSession.pendingHandoff.payload)
            XCTAssertTrue(
                payload.contains(
                    #"<tool_call name="ask_oracle">{"chat_id":"\#(primaryClone.shortID)"}"#
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "Continue Oracle chat \(primarySourceChat.id.uuidString) from the surrounding prose."
                )
            )
            XCTAssertTrue(payload.contains("<oracle_chat_id_mapping>"))
            XCTAssertFalse(payload.contains(handoffModel.rawValue), payload)
            XCTAssertFalse(payload.contains(handoffModel.displayName), payload)
            XCTAssertNil(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID
                        && $0.name == unownedSourceChat.name
                }
            )
            XCTAssertNil(
                oracle.sessions.first {
                    $0.composeTabID == destinationTabID
                        && $0.name == foreignSourceChat.name
                }
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(primarySourceChat.id.uuidString) | \(primaryClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(primarySourceChat.shortID) | \(primaryClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(otherSourceChat.id.uuidString) | \(otherClone.shortID) |"
                )
            )
            XCTAssertTrue(
                payload.contains(
                    "| \(otherSourceChat.shortID) | \(otherClone.shortID) |"
                )
            )

            let destinationRunID = UUID()
            let continuedID = try await oracle.locateOrCreateChat(
                primaryClone.shortID,
                tabID: destinationTabID,
                activateInUI: false,
                agentModeSessionID: destinationSessionID,
                agentModeRunID: destinationRunID
            )
            XCTAssertEqual(continuedID, primaryClone.id)
            let continuedClone = try XCTUnwrap(
                oracle.sessions.first(where: { $0.id == primaryClone.id })
            )
            XCTAssertEqual(continuedClone.agentModeSessionID, destinationSessionID)
            XCTAssertEqual(continuedClone.agentModeRunID, destinationRunID)

            let log = try await oracle.tool_oracleChatLog(
                args: [
                    "chat_id": .string(primaryClone.shortID),
                    "include_user": .bool(true)
                ],
                tabID: destinationTabID,
                agentModeSessionID: destinationSessionID,
                agentModeRunID: destinationRunID
            )
            XCTAssertEqual(log["chat_id"]?.stringValue, primaryClone.shortID)
            let loggedTexts = log["messages"]?.arrayValue?.compactMap {
                $0.objectValue?["text"]?.stringValue
            }
            XCTAssertEqual(loggedTexts, ["source question", "source answer"])

            do {
                _ = try await oracle.locateOrCreateChat(
                    primarySourceChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected the old chat ID to remain invalid")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .invalidParams)
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(primaryClone.shortID))
            }

            do {
                _ = try await oracle.tool_oracleChatLog(
                    args: ["chat_id": .string(primarySourceChat.shortID)],
                    tabID: destinationTabID,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected oracle_chat_log to reject the old chat ID")
            } catch let error as ChatToolError {
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(primaryClone.shortID))
            }

            do {
                _ = try await oracle.locateOrCreateChat(
                    otherSourceChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected the source session's other old chat ID to remain invalid")
            } catch let error as ChatToolError {
                XCTAssertTrue(error.message.contains("was cloned during handoff"))
                XCTAssertTrue(error.message.contains(otherClone.shortID))
            }

            for foreignSessionID in [fixture.sessionAID, thirdPartySessionID] {
                do {
                    _ = try await oracle.locateOrCreateChat(
                        otherClone.shortID,
                        tabID: destinationTabID,
                        activateInUI: false,
                        agentModeSessionID: foreignSessionID,
                        agentModeRunID: UUID()
                    )
                    XCTFail("Expected a foreign Agent Mode session to remain fail closed")
                } catch let error as ChatToolError {
                    XCTAssertTrue(error.message.contains("different Agent Mode owner"))
                    XCTAssertFalse(error.message.contains("was cloned during handoff"))
                }
            }

            for skippedSourceChat in [
                unownedSourceChat,
                foreignSourceChat
            ] {
                do {
                    _ = try await oracle.tool_oracleChatLog(
                        args: [
                            "chat_id": .string(skippedSourceChat.shortID),
                            "include_user": .bool(true)
                        ],
                        tabID: destinationTabID,
                        agentModeSessionID: destinationSessionID,
                        agentModeRunID: destinationRunID
                    )
                    XCTFail("Expected skipped source chat to remain unreadable")
                } catch let error as ChatToolError {
                    XCTAssertEqual(error.code, .invalidParams)
                    XCTAssertFalse(
                        error.message.contains("was cloned during handoff")
                    )
                }
            }

            do {
                _ = try await oracle.locateOrCreateChat(
                    thirdPartyChat.shortID,
                    tabID: destinationTabID,
                    activateInUI: false,
                    agentModeSessionID: destinationSessionID,
                    agentModeRunID: destinationRunID
                )
                XCTFail("Expected a third-party tab chat to remain fail closed")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, .invalidParams)
                XCTAssertFalse(error.message.contains("was cloned during handoff"))
            }
        }
    }

    func testHandoffFailsAndRollsBackWhenAnyOwnedOracleCloneCannotPersist() async throws {
        try await withFixture { fixture in
            let workspaceID = try XCTUnwrap(
                fixture.window.workspaceManager.activeWorkspace?.id
            )
            let oracle = fixture.window.oracleViewModel
            let chats = ["First owned", "Second owned"].map { name in
                ChatSession(
                    workspaceID: workspaceID,
                    composeTabID: fixture.tabAID,
                    agentModeSessionID: fixture.sessionAID,
                    agentModeRunID: UUID(),
                    name: name,
                    messages: [
                        StoredMessage(
                            isUser: false,
                            rawText: "\(name) response",
                            sequenceIndex: 0
                        )
                    ]
                )
            }
            var persistedChats: [ChatSession] = []
            for var chat in chats {
                let url = try await oracle.autosaveSession(chat)
                chat.fileURL = url
                persistedChats.append(chat)
            }
            oracle.sessions = persistedChats
            var persistAttempts = 0
            oracle.setOracleCloneWillPersistObserverForTesting { _, _ in
                persistAttempts += 1
                if persistAttempts == 2 {
                    throw NSError(
                        domain: "OracleCloneFailure",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "injected clone failure"
                        ]
                    )
                }
            }
            defer {
                oracle.setOracleCloneWillPersistObserverForTesting(nil)
            }

            do {
                _ = try await fixture.viewModel.prepareHandoffHeadless(
                    sourceTabID: fixture.tabAID,
                    upToItemID: nil,
                    destinationAgent: fixture.sessionA.selectedAgent,
                    destinationModelRaw: fixture.sessionA.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sessionA
                        .selectedReasoningEffortRaw
                )
                XCTFail("Expected handoff preparation to fail")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "no chats were cloned"
                    ),
                    error.localizedDescription
                )
            }

            XCTAssertEqual(persistAttempts, 2)
            XCTAssertEqual(Set(oracle.sessions.map(\.id)), Set(chats.map(\.id)))
            XCTAssertFalse(
                oracle.sessions.contains {
                    $0.agentModeSessionID != fixture.sessionAID
                }
            )
        }
    }

    func testColdLoadUIToolResultMergePrefersLivePayload() {
        let sharedID = UUID()
        let persistedOnlyID = UUID()
        let merged = AgentModeViewModel.mergeUIToolResultPayloads(
            live: [sharedID: "live identity"],
            persisted: [
                sharedID: "stale persisted identity",
                persistedOnlyID: "persisted identity"
            ]
        )

        XCTAssertEqual(merged[sharedID], "live identity")
        XCTAssertEqual(merged[persistedOnlyID], "persisted identity")
    }

    func testWarmSwitchPublishesDestinationTranscriptBeforeSwitchReturns() async throws {
        try await withFixture { fixture in
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testBackToBackWarmSwitchesPublishLatestDestination() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabAID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testWarmSwitchNotificationIsWindowScoped() async throws {
        try await withFixture { fixtureA in
            let initialPresentation = fixtureA.viewModel.activeTranscriptPresentation

            try await withFixture { fixtureB in
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)

                await fixtureB.window.promptManager.switchComposeTab(fixtureB.tabBID)

                XCTAssertEqual(fixtureB.window.promptManager.activeComposeTabID, fixtureB.tabBID)
                assertPresentation(
                    fixtureB.viewModel.activeTranscriptPresentation,
                    tabID: fixtureB.tabBID,
                    sessionID: fixtureB.sessionBID,
                    session: fixtureB.sessionB,
                    expectedTexts: fixtureB.tabBTexts
                )
                XCTAssertEqual(fixtureA.window.promptManager.activeComposeTabID, fixtureA.tabAID)
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)
                XCTAssertNil(fixtureA.viewModel.activeSessionLoadInProgressTabID)
            }
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentModeChatSwitchActivationTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "A", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "B", activeAgentSessionID: sessionBID)

            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = viewModel.session(for: tabAID)
            let sessionB = viewModel.session(for: tabBID)
            XCTAssertEqual(sessionA.activeAgentSessionID, sessionAID)
            XCTAssertEqual(sessionB.activeAgentSessionID, sessionBID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabAID), sessionAID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabBID), sessionBID)

            let tabATexts = ["A user", "A assistant"]
            let tabBTexts = ["B user", "B assistant"]
            sessionA.hasLoadedPersistedState = true
            sessionA.setItemsSilently(
                [
                    .user(tabATexts[0], sequenceIndex: 0),
                    .assistant(tabATexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionA)

            sessionB.hasLoadedPersistedState = true
            sessionB.setItemsSilently(
                [
                    .user(tabBTexts[0], sequenceIndex: 0),
                    .assistant(tabBTexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionB)

            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionBID: sessionBID,
                sessionA: sessionA,
                sessionB: sessionB,
                tabATexts: tabATexts,
                tabBTexts: tabBTexts
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func assertPresentation(
        _ presentation: AgentTranscriptPresentationSnapshot,
        tabID: UUID,
        sessionID: UUID,
        session: AgentModeViewModel.TabSession,
        expectedTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.tabID, tabID, file: file, line: line)
        XCTAssertTrue(presentation.bindingsHydrated, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.tabID, tabID, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(
            presentation.hydratedBindingTransitionGeneration,
            session.bindingTransitionGeneration,
            file: file,
            line: line
        )
        XCTAssertEqual(presentation.visibleRows.map(\.text), expectedTexts, file: file, line: line)
        XCTAssertEqual(presentation.workingRows.map(\.text), expectedTexts, file: file, line: line)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionBID: UUID
        let sessionA: AgentModeViewModel.TabSession
        let sessionB: AgentModeViewModel.TabSession
        let tabATexts: [String]
        let tabBTexts: [String]
    }
}
