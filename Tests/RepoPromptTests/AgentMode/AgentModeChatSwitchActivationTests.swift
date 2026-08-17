import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentModeChatSwitchActivationTests: XCTestCase {
    #if DEBUG
        override func setUp() {
            super.setUp()
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = true
        }

        override func tearDown() {
            OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = false
            super.tearDown()
        }
    #endif

    func testFocusedStandardSessionCreationPublishesReturnedTabRequest() async throws {
        try await withFixture { fixture in
            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                focusComposer: true
            )
            let tabID = try XCTUnwrap(returnedTabID)
            let request = try XCTUnwrap(fixture.viewModel.ui.composer.focusRequest)

            XCTAssertEqual(request.tabID, tabID)
            XCTAssertEqual(request.reason, .newSession)
        }
    }

    func testDefaultSessionCreationPublishesNoFocusRequest() async throws {
        try await withFixture { fixture in
            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab()

            XCTAssertNotNil(returnedTabID)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
        }
    }

    func testFocusedSwallowedPlaceholderPublishesReusedPriorTabRequest() async throws {
        try await withFixture { fixture in
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            session.transcript = AgentTranscript()
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                focusComposer: true
            )

            XCTAssertEqual(returnedTabID, fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, fixture.tabAID)
            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.reason, .reusedPlaceholder)
        }
    }

    func testFocusedKnowledgeSessionCreationPublishesKnowledgeReason() async throws {
        try await withFixture { fixture in
            fixture.viewModel.test_setAvailableAgents([.codexExec])

            let returnedTabID = await fixture.viewModel.createAndActivateSessionTab(
                profile: .knowledge,
                focusComposer: true
            )
            let tabID = try XCTUnwrap(returnedTabID)

            XCTAssertEqual(fixture.viewModel.ui.composer.focusRequest?.tabID, tabID)
            XCTAssertEqual(
                fixture.viewModel.ui.composer.focusRequest?.reason,
                .newKnowledgeSession
            )
        }
    }

    func testFailedKnowledgeSessionCreationPublishesNoFocusRequest() async throws {
        try await withFixture { fixture in
            fixture.viewModel.test_setAvailableAgents([])

            let tabID = await fixture.viewModel.createAndActivateSessionTab(
                profile: .knowledge,
                focusComposer: true
            )

            XCTAssertNil(tabID)
            XCTAssertNil(fixture.viewModel.ui.composer.focusRequest)
        }
    }

    func testSharedModelSelectionCommitPreservesInputBarOrderingAndRejectsDrift() async throws {
        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            fixture.viewModel.selectedAgent = .codexExec
            let options = fixture.viewModel.modelOptions(for: .codexExec)
            let option = try XCTUnwrap(
                options.first(where: { !$0.isPlaceholderDefault }) ?? options.first
            )
            let explicitEffort = option.supportedReasoningEfforts.first

            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .codexExec,
                rawModel: option.rawValue,
                explicitCodexEffort: explicitEffort,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(fixture.viewModel.selectedAgent, .codexExec)
            XCTAssertEqual(fixture.viewModel.selectedModelRaw, option.rawValue)
            XCTAssertEqual(session.selectedAgent, .codexExec)
            XCTAssertEqual(session.selectedModelRaw, option.rawValue)
            if let explicitEffort {
                XCTAssertEqual(
                    fixture.viewModel.selectedReasoningEffortRaw,
                    explicitEffort.rawValue
                )
                XCTAssertEqual(session.selectedReasoningEffortRaw, explicitEffort.rawValue)
            }

            let committedModel = session.selectedModelRaw
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: "not-in-the-live-catalog",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .modelUnavailable)
            }
            XCTAssertEqual(session.selectedModelRaw, committedModel)

            fixture.viewModel.test_setMCPControlledTabIDs([fixture.tabAID])
            XCTAssertEqual(
                fixture.viewModel.modelSelectionInteractivity(tabID: fixture.tabAID),
                .disabled(
                    reason: "Model and effort controls are locked while this session is controlled by an MCP agent."
                )
            )
            XCTAssertTrue(fixture.viewModel.makeComposerProps().areModelControlsDisabled)
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: option.rawValue,
                    explicitCodexEffort: explicitEffort,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                guard case .controlsDisabled = error as? AgentModelSelectionCommitError else {
                    return XCTFail("Expected MCP-only interactivity rejection, got \(error)")
                }
            }
            fixture.viewModel.test_setMCPControlledTabIDs([])

            session.hasSentFirstMessage = true
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .openCode,
                    rawModel: "irrelevant-before-family-validation",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .agentNotSelectable)
            }

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: option.rawValue,
                    explicitCodexEffort: explicitEffort,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelSelectionCommitError, .sourceUnavailable)
            }
            XCTAssertEqual(session.selectedModelRaw, committedModel)
        }
    }

    func testSharedModelSelectionCommitPreservesProviderRawSemantics() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer {
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }

        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            fixture.window.apiSettingsViewModel.isClaudeCodeConnected = true
            fixture.window.apiSettingsViewModel.isCursorConnected = true
            fixture.window.apiSettingsViewModel.isOpenCodeConnected = true
            let session = fixture.sessionA
            session.hasSentFirstMessage = false
            session.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: session)

            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: [
                        AgentModelOption(
                            rawValue: "future-cursor-model",
                            displayName: "Future Cursor Model",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    currentModelRaw: "future-cursor-model"
                ),
                for: .cursor
            )
            let cursorRaw = "future-cursor-model[context=1m,reasoning=high,fast=false]"
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .cursor,
                rawModel: cursorRaw,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .cursor)
            XCTAssertEqual(session.selectedModelRaw, cursorRaw)

            let claudeBaseOptions = fixture.viewModel.modelOptions(
                for: .claudeCode,
                includeClaudeEffortVariants: false
            )
            let claudeBase = try XCTUnwrap(claudeBaseOptions.first { option in
                !option.isPlaceholderDefault
                    && !AgentModelCatalog.supportedClaudeEfforts(
                        forSelectedModelRaw: option.rawValue,
                        agentKind: .claudeCode
                    ).isEmpty
            })
            let claudeEffort = try XCTUnwrap(
                AgentModelCatalog.supportedClaudeEfforts(
                    forSelectedModelRaw: claudeBase.rawValue,
                    agentKind: .claudeCode
                ).first
            )
            let claudeEncodedRaw = ClaudeModelSpecifier.encodedRaw(
                baseModelRaw: claudeBase.rawValue,
                effort: claudeEffort
            )
            XCTAssertFalse(claudeBaseOptions.contains { $0.rawValue == claudeEncodedRaw })
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .claudeCode,
                rawModel: claudeEncodedRaw,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .claudeCode)
            XCTAssertEqual(session.selectedModelRaw, claudeEncodedRaw)

            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
                ACPDiscoveredSessionModels(
                    options: [
                        AgentModelOption(
                            rawValue: AgentModel.defaultModel.rawValue,
                            displayName: "OpenCode Default",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    currentModelRaw: AgentModel.defaultModel.rawValue
                ),
                for: .openCode
            )
            let placeholderOptions = fixture.viewModel.modelOptions(for: .openCode)
            XCTAssertEqual(placeholderOptions.count, 1)
            XCTAssertTrue(try XCTUnwrap(placeholderOptions.first).isPlaceholderDefault)
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .openCode,
                rawModel: AgentModel.defaultModel.rawValue,
                explicitCodexEffort: nil,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(session.selectedAgent, .openCode)
            XCTAssertEqual(session.selectedModelRaw, AgentModel.defaultModel.rawValue)

            fixture.viewModel.test_setModelOptionsOverride(
                [
                    AgentModelOption(
                        rawValue: "gpt-5.4-high",
                        displayName: "GPT-5.4 High",
                        description: nil,
                        isDefault: true
                    )
                ],
                for: .codexExec
            )
            let codexOptions = fixture.viewModel.modelOptions(for: .codexExec)
            let encodedCodexOption = try XCTUnwrap(
                codexOptions.first {
                    CodexModelSpecifier(raw: $0.rawValue).reasoningEffort != nil
                },
                "Expected an encoded dynamic Codex option; got \(codexOptions.map(\.rawValue))"
            )
            let encodedEffort = try XCTUnwrap(
                CodexModelSpecifier(raw: encodedCodexOption.rawValue).reasoningEffort
            )
            let contradictoryEffort = try XCTUnwrap(
                CodexReasoningEffort.allCases.first { $0 != encodedEffort }
            )
            try fixture.viewModel.commitCurrentSessionModelSelection(
                agent: .codexExec,
                rawModel: encodedCodexOption.rawValue,
                explicitCodexEffort: contradictoryEffort,
                sourceTabID: fixture.tabAID
            )
            XCTAssertEqual(
                session.selectedModelRaw,
                CodexModelSpecifier(raw: encodedCodexOption.rawValue).baseModel
            )
            XCTAssertEqual(
                session.selectedReasoningEffortRaw,
                encodedEffort.rawValue,
                "The encoded effort must win over a contradictory explicit effort."
            )

            XCTAssertThrowsError(
                try fixture.viewModel.commitCurrentSessionModelSelection(
                    agent: .codexExec,
                    rawModel: "removed-after-menu-snapshot",
                    explicitCodexEffort: nil,
                    sourceTabID: fixture.tabAID
                )
            ) { error in
                XCTAssertEqual(error.localizedDescription, "The selected model is no longer available.")
            }
        }
    }

    func testModelSelectionHUDCurrentPresentationCommitsAndRejectsStaleTab() async throws {
        try await withFixture { fixture in
            fixture.sessionA.hasSentFirstMessage = false
            fixture.sessionA.replaceItems([])
            fixture.viewModel.refreshDerivedTranscriptState(for: fixture.sessionA)
            configureHUDCodexProvider(fixture)
            fixture.sessionA.selectedAgent = .codexExec
            fixture.sessionA.selectedModelRaw = AgentModel.defaultModel.rawValue
            fixture.sessionA.selectedReasoningEffortRaw = nil

            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            XCTAssertNil(presentation.unavailableMessage)
            let defaultLeaf = try XCTUnwrap(
                presentation.index.leaves.first {
                    if case let .local(agent: .codexExec, modelRaw, _) = $0.commitPayload {
                        return modelRaw == AgentModel.defaultModel.rawValue
                    }
                    return false
                }
            )
            XCTAssertTrue(defaultLeaf.isCurrentSelection)
            XCTAssertEqual(presentation.index.currentSelectionID, defaultLeaf.id)
            try await presentation.commit(defaultLeaf)
            XCTAssertEqual(
                fixture.sessionA.selectedModelRaw,
                AgentModel.defaultModel.rawValue
            )

            let leaf = try XCTUnwrap(
                presentation.index.leaves.first {
                    if case let .local(agent: .codexExec, modelRaw, _) = $0.commitPayload {
                        return modelRaw != fixture.viewModel.selectedModelRaw
                    }
                    return false
                }
            )

            try await presentation.commit(leaf)
            guard case let .local(agent, modelRaw, effortRaw) = leaf.commitPayload else {
                return XCTFail("Expected a local model selection")
            }
            XCTAssertEqual(agent, .codexExec)
            XCTAssertEqual(fixture.sessionA.selectedModelRaw, modelRaw)
            XCTAssertEqual(
                fixture.sessionA.selectedReasoningEffortRaw,
                CodexReasoningEffort.parse(effortRaw)?.rawValue
            )

            let stalePresentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .switchModel,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            do {
                try await stalePresentation.commit(leaf)
                XCTFail("Expected a source-pinned presentation to reject tab drift")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
                )
            }
        }
    }

    func testModelSelectionHUDHandoffPresentationRoutesLastCompletedReply() async throws {
        try await withFixture { fixture in
            configureHUDCodexProvider(fixture)
            let expectedTargetID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )

            XCTAssertNil(presentation.unavailableMessage)
            XCTAssertTrue(presentation.noticeText?.contains("Target reply:") == true)
            let leaf = try XCTUnwrap(presentation.index.leaves.first)
            try await presentation.commit(leaf)

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            XCTAssertNotEqual(destinationTabID, fixture.tabAID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(destination.pendingHandoff.sourceItemID, expectedTargetID)
            XCTAssertEqual(destination.selectedAgent, .codexExec)
            XCTAssertEqual(destination.selectedModelRaw, AgentModel.defaultModel.rawValue)
        }
    }

    func testModelSelectionHUDHandoffPreservesOptionlessCodexSourceEffort() async throws {
        try await withFixture { fixture in
            fixture.window.apiSettingsViewModel.isCodexConnected = true
            fixture.viewModel.test_setAvailableAgents([.codexExec])
            fixture.viewModel.test_setModelOptionsOverride(
                [
                    AgentModelOption(
                        rawValue: "gpt-5.4",
                        displayName: "GPT-5.4",
                        description: nil,
                        isDefault: false
                    )
                ],
                for: .codexExec
            )
            fixture.sessionA.selectedAgent = .codexExec
            fixture.sessionA.selectedModelRaw = "gpt-5.4"
            fixture.sessionA.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            let leaf = try XCTUnwrap(presentation.index.leaves.first)
            guard case let .local(_, _, effortRaw) = leaf.commitPayload else {
                return XCTFail("Expected a local Codex handoff leaf")
            }
            XCTAssertEqual(effortRaw, CodexReasoningEffort.high.rawValue)

            try await presentation.commit(leaf)

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(
                destination.selectedReasoningEffortRaw,
                CodexReasoningEffort.high.rawValue
            )
        }
    }

    func testModelSelectionHUDHandoffCommitFormatsStaleTargetFailure() async throws {
        try await withFixture { fixture in
            configureHUDCodexProvider(fixture)
            let presentation = fixture.viewModel.makeModelSelectionHUDPresentation(
                mode: .handoffLastReply,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            )
            let leaf = try XCTUnwrap(presentation.index.leaves.first)

            fixture.sessionA.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "stale-hud-host",
                hostDisplayName: "Stale HUD Host",
                remoteSessionID: "stale-hud-session"
            )

            do {
                try await presentation.commit(leaf)
                XCTFail("Expected a stale handoff target to be rejected")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Handoff failed: The source session is no longer available."
                )
            }
        }
    }

    func testSourcePinnedHandoffConfigUsesOriginalTabAfterForegroundDrift() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))
            let resolved = fixture.viewModel.resolveLastReplyHandoffTarget(
                sourceTabID: fixture.tabAID
            )
            guard case let .target(target) = resolved else {
                return XCTFail("Expected the source transcript to resolve a handoff target")
            }
            XCTAssertEqual(target.clientRowID, cutoffItemID)

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabBID)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: fixture.sessionA.selectedAgent,
                modelRaw: fixture.sessionA.selectedModelRaw,
                reasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )))

            let destinationTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            XCTAssertNotEqual(destinationTabID, fixture.tabBID)
            let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertEqual(destination.items.map(\.text), fixture.tabATexts)
            XCTAssertNotEqual(destination.items.map(\.text), fixture.tabBTexts)
            XCTAssertEqual(destination.pendingHandoff.sourceItemID, cutoffItemID)
        }
    }

    func testLocalHandoffPropagatesOMPThinkingOnlyToOMPDestinationSession() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))
            let ompModelRaw = "google-antigravity/gemini-3.7-flash"
            var thinking = OhMyPiThinkingSelections()
            thinking.setValue("high", for: ompModelRaw)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: .ohMyPi,
                modelRaw: ompModelRaw,
                reasoningEffortRaw: nil,
                ohMyPiThinkingSelections: thinking
            )))
            let ompTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let ompDestination = try XCTUnwrap(fixture.viewModel.sessions[ompTabID])
            XCTAssertEqual(ompDestination.selectedAgent, .ohMyPi)
            XCTAssertEqual(ompDestination.selectedModelRaw, ompModelRaw)
            XCTAssertEqual(ompDestination.ohMyPiThinkingSelections, thinking)

            try await config.performHandoff(.local(AgentHandoffSelection(
                agent: .codexExec,
                modelRaw: "gpt-5.6-sol",
                reasoningEffortRaw: "high",
                ohMyPiThinkingSelections: thinking
            )))
            let codexTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let codexDestination = try XCTUnwrap(fixture.viewModel.sessions[codexTabID])
            XCTAssertEqual(codexDestination.selectedAgent, .codexExec)
            XCTAssertTrue(codexDestination.ohMyPiThinkingSelections.isEmpty)
        }
    }

    func testSourcePinnedHandoffConfigRejectsHostBindingDrift() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)
            let config = try XCTUnwrap(fixture.viewModel.makeHandoffConfig(
                for: cutoffItemID,
                sourceTabID: fixture.tabAID,
                windowID: fixture.window.windowID
            ))

            fixture.sessionA.remoteHost = AgentSessionRemoteHostBinding(
                hostID: "changed-host",
                hostDisplayName: "Changed Host",
                remoteSessionID: "changed-session"
            )
            defer { fixture.sessionA.remoteHost = nil }

            do {
                _ = try await config.buildPayloadForClipboard()
                XCTFail("Expected the pinned config to reject host drift")
            } catch AgentHandoffConfigurationError.sourceUnavailable {}
        }
    }

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

    private func configureHUDCodexProvider(_ fixture: Fixture) {
        fixture.window.apiSettingsViewModel.isCodexConnected = true
        fixture.viewModel.test_setAvailableAgents([.codexExec])
        fixture.viewModel.test_setModelOptionsOverride(
            [
                AgentModelOption(
                    rawValue: AgentModel.defaultModel.rawValue,
                    displayName: "Default",
                    description: nil,
                    isPlaceholderDefault: true,
                    isProviderDefault: false
                ),
                AgentModelOption(
                    rawValue: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Deterministic HUD test option",
                    isDefault: false,
                    supportedReasoningEfforts: [.low, .high],
                    defaultReasoningEffort: .high
                ),
                AgentModelOption(
                    rawValue: "gpt-5.3",
                    displayName: "GPT-5.3",
                    description: "Alternate HUD test option",
                    isDefault: false,
                    supportedReasoningEfforts: [.medium, .high],
                    defaultReasoningEffort: .medium
                )
            ],
            for: .codexExec
        )
        fixture.viewModel.selectedAgent = .codexExec
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
