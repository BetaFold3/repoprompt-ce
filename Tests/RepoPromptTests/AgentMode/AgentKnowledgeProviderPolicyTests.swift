@testable import RepoPromptApp
import XCTest

final class AgentKnowledgeProviderPolicyTests: XCTestCase {
    func testClaudeKnowledgeProfileKeepsOnlyNativeMediaAndWebExceptions() {
        let denied = Set(ClaudeCodeIntegrationConfiguration.disallowedTools(
            for: .agentRun,
            allowNativeBashTool: true,
            sessionProfile: .knowledge
        ))

        for tool in ["Bash", "Write", "Edit", "Glob", "Grep", "Task", "Skill", "NotebookEdit"] {
            XCTAssertTrue(denied.contains(tool), tool)
        }
        for retained in ["Read", "WebSearch", "WebFetch"] {
            XCTAssertFalse(denied.contains(retained), retained)
        }
    }

    func testClaudeStandardProfilePreservesNativeBashPreference() {
        let denied = Set(ClaudeCodeIntegrationConfiguration.disallowedTools(
            for: .agentRun,
            allowNativeBashTool: true,
            sessionProfile: .standard
        ))

        XCTAssertFalse(denied.contains("Bash"))
    }

    func testCodexFocusedPolicyCanDisableShellWhileKeepingWebAndImages() {
        let policy = CodexNativeSessionController.defaultAppServerToolPolicy(
            shellToolEnabled: false,
            webSearchRequestEnabled: true,
            forceExperimentalSteering: false
        )

        XCTAssertEqual(policy.shellToolEnabled, false)
        XCTAssertEqual(policy.webSearchRequestEnabled, true)
        XCTAssertEqual(policy.viewImageToolEnabled, true)
        XCTAssertEqual(policy.includeApplyPatchTool, false)
        XCTAssertEqual(policy.multiAgentEnabled, false)
    }

    @MainActor
    func testSessionProfileCanOnlyChangeBeforeProviderWorkStarts() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertTrue(session.adoptSessionProfile(.knowledge))
        XCTAssertEqual(session.profile, .knowledge)

        session.providerSessionID = "provider-session"
        XCTAssertFalse(session.adoptSessionProfile(.standard))
        XCTAssertEqual(session.profile, .knowledge)
    }

    @MainActor
    func testFreshPlaceholderSwallowMatchesRequestedProfile() {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )

        let standardSession = AgentModeViewModel.TabSession(tabID: UUID())
        viewModel.test_installLiveSession(standardSession)
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(),
            on: standardSession
        )
        standardSession.hasLoadedPersistedState = true

        XCTAssertTrue(viewModel.shouldSwallowNewSessionClick(
            for: standardSession.tabID,
            requestedProfile: .standard
        ))
        XCTAssertFalse(viewModel.shouldSwallowNewSessionClick(
            for: standardSession.tabID,
            requestedProfile: .knowledge
        ))

        let knowledgeSession = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertTrue(knowledgeSession.adoptSessionProfile(.knowledge))
        viewModel.test_installLiveSession(knowledgeSession)
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: UUID(),
            on: knowledgeSession
        )
        knowledgeSession.hasLoadedPersistedState = true

        XCTAssertTrue(viewModel.shouldSwallowNewSessionClick(
            for: knowledgeSession.tabID,
            requestedProfile: .knowledge
        ))
        XCTAssertFalse(viewModel.shouldSwallowNewSessionClick(
            for: knowledgeSession.tabID,
            requestedProfile: .standard
        ))
    }

    func testKnowledgeProviderRepairIgnoresSupportedProviderDisconnects() {
        XCTAssertFalse(AgentModeViewModel.shouldRepairKnowledgeProviderSelection(
            profile: .knowledge,
            selectedAgent: .claudeCode
        ))
        XCTAssertFalse(AgentModeViewModel.shouldRepairKnowledgeProviderSelection(
            profile: .knowledge,
            selectedAgent: .codexExec
        ))
        XCTAssertTrue(AgentModeViewModel.shouldRepairKnowledgeProviderSelection(
            profile: .knowledge,
            selectedAgent: .openCode
        ))
        XCTAssertFalse(AgentModeViewModel.shouldRepairKnowledgeProviderSelection(
            profile: .standard,
            selectedAgent: .openCode
        ))
    }

    func testKnowledgeProviderSupportIsExact() {
        XCTAssertEqual(KnowledgeSessionPolicy.supportedProvidersOrdered, [.claudeCode, .codexExec])
        XCTAssertEqual(KnowledgeSessionPolicy.supportedProviders, Set([.claudeCode, .codexExec]))
        XCTAssertFalse(KnowledgeSessionPolicy.supportedProviders.contains(.claudeCodeGLM))
        XCTAssertFalse(KnowledgeSessionPolicy.supportedProviders.contains(.openCode))
        XCTAssertFalse(KnowledgeSessionPolicy.supportedProviders.contains(.cursor))
    }
}
