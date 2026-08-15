import CryptoKit
import Darwin
import Foundation
import MCP
import Ontology
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class ToolCatalogSnapshotTests: XCTestCase {
    func testWindowToolCatalogSignatureMatchesGolden() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let signatures = try Self.signatures(for: tools)

        XCTAssertEqual(
            tools.map(\.name),
            MCPWindowToolGroup.orderedToolNames,
            "Window catalog order should follow MCPWindowToolGroup."
        )
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count, "Window catalog should not contain duplicate tool names.")
        XCTAssertTrue(
            tools.allSatisfy { MCPToolExecutionContractCatalog.contract(for: $0.name) != nil },
            "Every live window tool must have an explicit execution contract."
        )
        XCTAssertEqual(
            MCPWindowToolGroup.git.orderedToolNames,
            [MCPWindowToolName.git, MCPWindowToolName.manageWorktree],
            ".git group should reserve deterministic provider order for git-related tools."
        )
        XCTAssertEqual(
            tools.map(\.name).filter { MCPWindowToolGroup.git.orderedToolNames.contains($0) },
            MCPWindowToolGroup.git.orderedToolNames,
            "Window catalog should keep .git providers ordered as git, manage_worktree."
        )

        if ProcessInfo.processInfo.environment["RECORD_MCP_WINDOW_TOOL_CATALOG"] == "1" {
            print(Self.renderGolden(signatures))
        }

        XCTAssertEqual(signatures, Self.expectedSignatures)
    }

    func testCodingAgentPromptManifestMatchesRegisteredSchemas() async throws {
        let prompt = SystemPromptService.agentModePrompt()
        XCTAssertTrue(prompt.hasPrefix("# RepoPrompt Coding Agent — System Prompt (vNext-rc2.1)"))
        XCTAssertFalse(prompt.contains("SHIP GATE"))
        XCTAssertTrue(prompt.contains("review independence outweighs the continuity default"))
        XCTAssertTrue(prompt.contains("never end your turn with an unattended session"))
        XCTAssertTrue(prompt.contains("oracle_export_instruction"))
        XCTAssertTrue(prompt.contains("via `ask_user`"))
        XCTAssertTrue(prompt.contains("`RepoPrompt__read_file`"))
        XCTAssertTrue(prompt.contains("Read the applicable instruction chain before acting"))
        XCTAssertFalse(prompt.contains("Codex loads the applicable"))

        let codeMapsDisabledPrompt = SystemPromptService.agentModePrompt(codeMapsDisabled: true)
        XCTAssertTrue(codeMapsDisabledPrompt.contains("Code Maps are globally disabled"))
        XCTAssertFalse(codeMapsDisabledPrompt.contains("when signatures and relationships suffice"))

        let claudeBinaryGuidance = "Use the native Read tool for images, screenshots, PDFs, and other binary assets — always, including @path references in the user's message."
        let codexBinaryGuidance = "Use the provider's native image or document reading tools for binary assets — always, including @path references in the user's message."
        let openCodeBinaryGuidance = "Binary and media files (images, screenshots, PDFs) cannot be read in this session; when the task depends on one — including an @path reference in the user's message — tell the user that limitation and ask for the content in a text form."
        let providerNeutralBinaryGuidance = "If the provider exposes a native image or document reading capability, use it for binary assets — including @path references in the user's message; if it does not, tell the user the file cannot be read and ask for the content in another form."
        let claudeProviderKinds: Set<AgentProviderKind> = [
            .claudeCode,
            .claudeCodeGLM,
            .kimiCode,
            .customClaudeCompatible
        ]
        XCTAssertEqual(
            Set(AgentProviderKind.allCases.filter(\.usesClaudeNativeRuntime)),
            claudeProviderKinds
        )

        let expectedBinaryGuidance: [AgentProviderKind: String] = [
            .claudeCode: claudeBinaryGuidance,
            .claudeCodeGLM: claudeBinaryGuidance,
            .kimiCode: claudeBinaryGuidance,
            .customClaudeCompatible: claudeBinaryGuidance,
            .codexExec: codexBinaryGuidance,
            .openCode: openCodeBinaryGuidance,
            .cursor: providerNeutralBinaryGuidance,
            .ohMyPi: providerNeutralBinaryGuidance
        ]
        let allBinaryGuidance = [
            claudeBinaryGuidance,
            codexBinaryGuidance,
            openCodeBinaryGuidance,
            providerNeutralBinaryGuidance
        ]
        XCTAssertEqual(Set(expectedBinaryGuidance.keys), Set(AgentProviderKind.allCases))
        for (agentKind, expectedGuidance) in expectedBinaryGuidance {
            let providerPrompt = SystemPromptService.agentModePrompt(agentKind: agentKind)
            XCTAssertTrue(providerPrompt.contains(expectedGuidance), "Unexpected binary guidance for \(agentKind)")
            XCTAssertEqual(
                allBinaryGuidance.count(where: { providerPrompt.contains($0) }),
                1,
                "\(agentKind) prompt must contain exactly one binary guidance sentence"
            )
            if !claudeProviderKinds.contains(agentKind) {
                XCTAssertFalse(providerPrompt.contains(claudeBinaryGuidance), "\(agentKind) must not claim native Read")
            }
        }

        let providerNeutralPrompt = SystemPromptService.agentModePrompt(agentKind: nil)
        XCTAssertTrue(providerNeutralPrompt.contains(providerNeutralBinaryGuidance))
        XCTAssertEqual(
            allBinaryGuidance.count(where: { providerNeutralPrompt.contains($0) }),
            1,
            "nil provider prompt must contain exactly one binary guidance sentence"
        )
        XCTAssertFalse(providerNeutralPrompt.contains(claudeBinaryGuidance))

        let codexPrompt = SystemPromptService.agentModePrompt(agentKind: .codexExec)
        let codexQualifiedToolNames = [
            MCPWindowToolName.readFile,
            MCPWindowToolName.getFileTree,
            MCPWindowToolName.search,
            MCPWindowToolName.getCodeStructure,
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.fileActions,
            MCPWindowToolName.askOracle,
            MCPWindowToolName.agentRun,
            MCPWindowToolName.agentManage,
            MCPWindowToolName.askUser,
            MCPWindowToolName.workspaceContext,
            MCPWindowToolName.oracleChatLog,
            MCPWindowToolName.setStatus
        ]
        for toolName in codexQualifiedToolNames {
            let qualified = "`mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__\(toolName)`"
            XCTAssertTrue(codexPrompt.contains(qualified), "Codex prompt should qualify tool \(toolName)")
            XCTAssertFalse(codexPrompt.contains("`\(toolName)`"), "Codex prompt should not retain canonical tool \(toolName)")
        }
        XCTAssertFalse(codexPrompt.contains("`RepoPrompt__read_file`"))
        XCTAssertTrue(codexPrompt.contains("provider's native image or document reading tools"))
        XCTAssertFalse(codexPrompt.contains("native Read tool"))
        XCTAssertTrue(codexPrompt.contains("Codex loads the applicable"))
        XCTAssertFalse(codexPrompt.contains("Read the applicable instruction chain before acting"))
        XCTAssertTrue(codexPrompt.contains("Codex native `spawn_agent` children"))

        for role in [AgentModelCatalog.TaskLabelKind.pair, .design] {
            let rolePrompt = SystemPromptService.agentModePrompt(taskLabelKind: role)
            XCTAssertTrue(rolePrompt.contains("`agent_explore`"), "\(role) prompt should advertise agent_explore")
            XCTAssertFalse(rolePrompt.contains("`agent_run`"), "\(role) prompt should not advertise agent_run")
            XCTAssertFalse(rolePrompt.contains("vNext-rc2.1"), "\(role) should retain its role-specific prompt")
        }

        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let registeredToolNames = Set(tools.map(\.name))
        // Curated ship-gate inventory: update this list whenever the coding-agent prompt
        // adds or removes a RepoPrompt tool contract.
        let shipGateToolNames = [
            MCPWindowToolName.askOracle,
            MCPWindowToolName.oracleChatLog,
            MCPWindowToolName.askUser,
            MCPWindowToolName.setStatus,
            MCPWindowToolName.readFile,
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.fileActions,
            MCPWindowToolName.getFileTree,
            MCPWindowToolName.search,
            MCPWindowToolName.getCodeStructure,
            MCPWindowToolName.manageSelection,
            MCPWindowToolName.prompt,
            MCPWindowToolName.workspaceContext,
            MCPWindowToolName.agentRun,
            MCPWindowToolName.agentManage
        ]
        for toolName in shipGateToolNames {
            XCTAssertTrue(registeredToolNames.contains(toolName), "Coding-agent ship-gate tool is not registered: \(toolName)")
        }

        let askOracle = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.askOracle })
        let oracleSend = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.oracleSend })
        let oracleChatLog = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.oracleChatLog })
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })
        let applyEdits = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.applyEdits })
        let setStatus = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.setStatus })

        let askOracleProperties = try Self.schemaProperties(for: askOracle)
        for field in [
            "mode", "new_chat", "chat_id", "model", "chat_name", "export_response",
            "selection_mode", "slices", "max_output_tokens", "response_mode",
            "consultations", "require_distinct"
        ] {
            XCTAssertNotNil(askOracleProperties[field], "ask_oracle schema should advertise property \(field)")
        }
        let oracleModes = askOracleProperties["mode"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(oracleModes.contains("plan"))
        XCTAssertTrue(oracleModes.contains("review"))

        for tool in [askOracle, oracleSend] {
            let properties = try Self.schemaProperties(for: tool)
            let newChatDescription = try XCTUnwrap(
                properties["new_chat"]?.objectValue?["description"]?.stringValue
            )
            XCTAssertFalse(newChatDescription.contains("discouraged"))
            XCTAssertTrue(newChatDescription.contains("continuity"))
            XCTAssertTrue(newChatDescription.contains("independent review"))
        }

        let oracleChatLogProperties = try Self.schemaProperties(for: oracleChatLog)
        XCTAssertNotNil(oracleChatLogProperties["limit"])
        XCTAssertNotNil(oracleChatLogProperties["max_chars"])
        XCTAssertNotNil(oracleChatLogProperties["part"])
        XCTAssertNotNil(oracleChatLogProperties["max_total_chars"])

        let agentRunProperties = try Self.schemaProperties(for: agentRun)
        for field in [
            "model_id",
            "detach",
            "session_id",
            "session_ids",
            "wait",
            "interaction_id",
            "response"
        ] {
            XCTAssertNotNil(agentRunProperties[field], "agent_run schema should advertise property \(field)")
        }
        let agentRunOperations = agentRunProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for operation in ["wait", "steer", "respond"] {
            XCTAssertTrue(agentRunOperations.contains(operation), "agent_run schema should advertise operation \(operation)")
        }

        let applyEditsProperties = try Self.schemaProperties(for: applyEdits)
        XCTAssertNotNil(applyEditsProperties["rewrite"])
        XCTAssertNotNil(applyEditsProperties["on_missing"])

        let setStatusProperties = try Self.schemaProperties(for: setStatus)
        XCTAssertNotNil(setStatusProperties["session_name"])
    }

    func testAskOracleCatalogDocumentsNamedPresetIdentityContract() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let askOracle = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.askOracle })
        let properties = try Self.schemaProperties(for: askOracle)
        let modelDescription = try XCTUnwrap(properties["model"]?.objectValue?["description"]?.stringValue)
        let chatNameDescription = try XCTUnwrap(properties["chat_name"]?.objectValue?["description"]?.stringValue)
        let selectionModeDescription = try XCTUnwrap(
            properties["selection_mode"]?.objectValue?["description"]?.stringValue
        )
        let maxOutputDescription = try XCTUnwrap(
            properties["max_output_tokens"]?.objectValue?["description"]?.stringValue
        )

        XCTAssertTrue(askOracle.description.contains("model-preset selectors"))
        XCTAssertTrue(askOracle.description.contains("oracle_utils op=models"))
        XCTAssertTrue(askOracle.description.contains("one tool-call batch") || askOracle.description.contains("consultations"))
        XCTAssertTrue(askOracle.description.contains("do not synthesize"))
        XCTAssertTrue(askOracle.description.contains("re-packages the current workspace selection"))
        XCTAssertTrue(askOracle.description.contains("fresh chat with a concise summary"))
        XCTAssertTrue(askOracle.description.contains("Unknown context windows skip"))
        XCTAssertTrue(askOracle.description.contains("response_mode"))
        XCTAssertTrue(askOracle.description.contains("## Recommendations"))
        XCTAssertTrue(askOracle.description.contains("require_distinct"))
        XCTAssertTrue(selectionModeDescription.contains("without mutating shared selection"))
        XCTAssertTrue(selectionModeDescription.contains("no review diff"))
        XCTAssertTrue(maxOutputDescription.contains("pre-send context-budget check"))
        XCTAssertTrue(modelDescription.contains("Exact model preset UUID (preferred)"))
        XCTAssertTrue(modelDescription.contains("Required when the user requests a named Oracle"))
        XCTAssertTrue(chatNameDescription.contains("display-only"))
        XCTAssertTrue(chatNameDescription.contains("never selects the model"))
        let responseModeDescription = try XCTUnwrap(
            properties["response_mode"]?.objectValue?["description"]?.stringValue
        )
        XCTAssertTrue(responseModeDescription.contains("2000"))
        XCTAssertTrue(responseModeDescription.contains("auto-export"))
    }

    func testLifecycleSchemasAdvertiseConfigurableDefaultsWithoutMaximumClamp() async throws {
        do {
            let caseLabel = "testAgentLifecycleSchemasAdvertiseTwoMinuteDefaultsWithoutMaximumClamp"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore }, caseLabel)
            let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun }, caseLabel)

            let exploreTimeout = try XCTUnwrap(
                Self.schemaProperties(for: agentExplore, label: caseLabel)["timeout"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )
            let runProperties = try Self.schemaProperties(for: agentRun, label: caseLabel)
            let runTimeout = try XCTUnwrap(runProperties["timeout"]?.objectValue?["description"]?.stringValue, caseLabel)
            let steerTimeout = try XCTUnwrap(runProperties["timeout_seconds"]?.objectValue?["description"]?.stringValue, caseLabel)

            let defaultText = "Default \(Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds))."
            for description in [exploreTimeout, runTimeout, steerTimeout] {
                XCTAssertTrue(description.contains(defaultText), caseLabel + ": " + description)
                XCTAssertFalse(description.lowercased().contains("maximum"), caseLabel + ": " + description)
            }
        }

        do {
            let caseLabel = "testInteractiveLifecycleSchemasPreserveConfigurableWaitsWithoutMaximumClamp"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let askUser = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.askUser }, caseLabel)
            let waitForNextInstruction = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.waitForNextInstruction },
                caseLabel
            )

            let askUserTimeout = try XCTUnwrap(
                Self.schemaProperties(for: askUser, label: caseLabel)["timeout_seconds"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )
            let instructionTimeout = try XCTUnwrap(
                Self.schemaProperties(for: waitForNextInstruction, label: caseLabel)["timeout_seconds"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )

            XCTAssertTrue(askUserTimeout.contains("workspace question-timeout setting"), caseLabel + ": " + askUserTimeout)
            XCTAssertTrue(
                instructionTimeout.contains(
                    "Default \(Int(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds))."
                ),
                caseLabel + ": " + instructionTimeout
            )
            XCTAssertFalse(askUserTimeout.lowercased().contains("maximum"), caseLabel + ": " + askUserTimeout)
            XCTAssertFalse(instructionTimeout.lowercased().contains("maximum"), caseLabel + ": " + instructionTimeout)
        }
    }

    func testCodexAnnotationProjectionPreservesCanonicalMetadataAcrossIdentityMatrix() async {
        do {
            let caseLabel = "testCanonicalReadOnlyAnnotationsRemainTruthfulOutsideCodexProjection"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let canonicalReadOnlyTools = tools.filter { $0.annotations.readOnlyHint == true }

            XCTAssertFalse(canonicalReadOnlyTools.isEmpty, caseLabel)
            XCTAssertTrue(canonicalReadOnlyTools.allSatisfy { $0.annotations.readOnlyHint == true }, caseLabel)
            XCTAssertTrue(
                canonicalReadOnlyTools.allSatisfy {
                    CodexMCPToolAnnotationProjection.project(
                        $0.annotations,
                        clientIdentifier: "generic-mcp-client"
                    ) == $0.annotations
                },
                caseLabel
            )
        }

        do {
            let caseLabel = "testCodexProjectionClearsOnlyReadOnlyHintForPositiveCodexIdentity"
            let canonical = MCP.Tool.Annotations(
                title: "Read workspace",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
            let codexIdentities: [String?] = [
                "codex-mcp-client",
                "Codex MCP Client",
                "codex-mcp-client/1.2.3",
                "codex-mcp-client-v2"
            ]

            for identity in codexIdentities {
                let projected = CodexMCPToolAnnotationProjection.project(
                    canonical,
                    clientIdentifier: identity
                )
                let identityLabel = caseLabel + ": " + (identity ?? "nil")
                XCTAssertNil(projected.readOnlyHint, identityLabel)
                XCTAssertEqual(projected.title, canonical.title, identityLabel)
                XCTAssertEqual(projected.destructiveHint, canonical.destructiveHint, identityLabel)
                XCTAssertEqual(projected.idempotentHint, canonical.idempotentHint, identityLabel)
                XCTAssertEqual(projected.openWorldHint, canonical.openWorldHint, identityLabel)
            }

            for readOnlyHint in [false, nil] as [Bool?] {
                XCTAssertNil(
                    CodexMCPToolAnnotationProjection.project(
                        MCP.Tool.Annotations(
                            title: canonical.title,
                            readOnlyHint: readOnlyHint,
                            destructiveHint: canonical.destructiveHint,
                            idempotentHint: canonical.idempotentHint,
                            openWorldHint: canonical.openWorldHint
                        ),
                        clientIdentifier: "codex-mcp-client"
                    ).readOnlyHint,
                    caseLabel + ": \(String(describing: readOnlyHint))"
                )
            }

            XCTAssertEqual(canonical.readOnlyHint, true, caseLabel + ": Projection must not mutate canonical catalog metadata.")
        }

        do {
            let caseLabel = "testCodexProjectionPreservesMetadataForMissingAmbiguousAndNonCodexIdentities"
            let canonical = MCP.Tool.Annotations(
                title: "Read workspace",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
            let identities: [String?] = [
                nil,
                "",
                "codex",
                "codex-client",
                "codex-wrapper-beta",
                "claude-code",
                "repoprompt-cli"
            ]

            for identity in identities {
                XCTAssertEqual(
                    CodexMCPToolAnnotationProjection.project(
                        canonical,
                        clientIdentifier: identity
                    ),
                    canonical,
                    caseLabel + ": " + (identity ?? "nil")
                )
            }
        }
    }

    func testAskOracleReadOnlyHintProjectionUsesServerEstablishedAgentModePurpose() {
        let canonical = MCP.Tool.Annotations(
            readOnlyHint: false,
            destructiveHint: false,
            openWorldHint: false
        )

        let agentModeProjected = MCPToolListAnnotationProjection.project(
            canonical,
            toolName: MCPWindowToolName.askOracle,
            clientIdentifier: "claude-code",
            runPurpose: .agentModeRun
        )
        XCTAssertEqual(agentModeProjected.readOnlyHint, true)
        XCTAssertEqual(agentModeProjected.destructiveHint, false)
        XCTAssertEqual(agentModeProjected.openWorldHint, false)

        let externalProjected = MCPToolListAnnotationProjection.project(
            canonical,
            toolName: MCPWindowToolName.askOracle,
            clientIdentifier: "claude-code",
            runPurpose: .unknown
        )
        XCTAssertEqual(externalProjected.readOnlyHint, false)

        let discoverProjected = MCPToolListAnnotationProjection.project(
            canonical,
            toolName: MCPWindowToolName.askOracle,
            clientIdentifier: "claude-code",
            runPurpose: .discoverRun
        )
        XCTAssertEqual(discoverProjected.readOnlyHint, false)

        let otherToolProjected = MCPToolListAnnotationProjection.project(
            canonical,
            toolName: MCPWindowToolName.oracleSend,
            clientIdentifier: "claude-code",
            runPurpose: .agentModeRun
        )
        XCTAssertEqual(otherToolProjected.readOnlyHint, false)

        // Spoofable client names must not flip ask_oracle; only server purpose does.
        let spoofedExternal = MCPToolListAnnotationProjection.project(
            canonical,
            toolName: MCPWindowToolName.askOracle,
            clientIdentifier: "repoprompt-agent-mode",
            runPurpose: .unknown
        )
        XCTAssertEqual(spoofedExternal.readOnlyHint, false)

        // Canonical catalog metadata remains non-read-only (external honesty).
        XCTAssertEqual(canonical.readOnlyHint, false)
    }

    func testProductionRegistrationUsesCatalogServiceNotViewModel() async throws {
        #if DEBUG
            XCTAssertTrue(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true)
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPromptTests.xctest", isDirectory: true)
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true),
                arguments: ["-RP_UITEST"]
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true),
                environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
            ))

            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                let catalogService = window.mcpServer.windowMCPToolCatalogService

                try await Self.withIsolatedBootstrapSocketNamespace(window: window, catalogService: catalogService) { socketURL in
                    let storedAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
                    await window.mcpServer.ensureServerReadyForAgentBootstrap()
                    XCTAssertEqual(GlobalSettingsStore.shared.mcpAutoStart(), storedAutoStart)
                    XCTAssertTrue(ServiceRegistry.services.contains { service in
                        (service as AnyObject) === (catalogService as AnyObject)
                    })
                    XCTAssertFalse(ServiceRegistry.services.contains { service in
                        (service as AnyObject) === (window.mcpServer as AnyObject)
                    })

                    let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
                    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)

                    await Self.assertBootstrapSocketOverrideError(.managerNotFullyStopped) {
                        try await ServerNetworkManager.shared.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
                    }
                }
            }
        #else
            throw XCTSkip("Bootstrap socket URL override seam is DEBUG-only")
        #endif
    }

    func testWorktreePublicAPISchemaFieldsRemainAdvertised() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let manageWorktree = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageWorktree })
        let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore })
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })

        let manageProperties = try Self.schemaProperties(for: manageWorktree)
        for field in [
            "include_graph",
            "graph_limit",
            "worktree",
            "worktree_id",
            "session_id",
            "persist_visuals",
            "marker_style",
            "bind"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise property \(field)")
        }
        let manageOpEnum = manageProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(manageOpEnum.contains("list"))
        XCTAssertTrue(manageOpEnum.contains("create"))
        XCTAssertTrue(manageOpEnum.contains("bind"))

        for field in [
            "operation_id",
            "target",
            "target_worktree_id",
            "confirm_preview",
            "confirm",
            "publish_artifacts",
            "context_lines",
            "detect_renames"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise merge property \(field)")
        }
        XCTAssertTrue(manageOpEnum.contains("preview"))
        XCTAssertTrue(manageOpEnum.contains("apply"))
        XCTAssertTrue(manageOpEnum.contains("status"))
        XCTAssertTrue(manageOpEnum.contains("continue"))
        XCTAssertTrue(manageOpEnum.contains("abort"))

        let agentExploreProperties = try Self.schemaProperties(for: agentExplore)
        let agentRunProperties = try Self.schemaProperties(for: agentRun)
        XCTAssertEqual(
            agentRunProperties["run_id"]?.objectValue?["description"]?.stringValue,
            "[cancel] Optional exact current run UUID fence. When present, cancellation is rejected unless it matches the session's current run."
        )
        XCTAssertNil(agentExploreProperties["run_id"])
        let worktreeFields = [
            "worktree",
            "worktree_id",
            "worktree_create",
            "worktree_repo_root",
            "worktree_branch",
            "worktree_base_ref",
            "worktree_path",
            "worktree_label",
            "worktree_color",
            "allow_external_worktree_path",
            "inherit_worktree"
        ]
        for field in worktreeFields {
            XCTAssertNotNil(agentRunProperties[field], "agent_run schema should advertise property \(field)")
            XCTAssertNotNil(agentExploreProperties[field], "agent_explore schema should advertise property \(field)")
        }
        #if DEBUG
            XCTAssertNotNil(agentRunProperties["_worktree_startup_benchmark_token"])
            XCTAssertNil(agentExploreProperties["_worktree_startup_benchmark_token"])
            let qualificationLease = try XCTUnwrap(agentRunProperties["_omp_qualification_lease_id"]?.objectValue)
            XCTAssertEqual(qualificationLease["type"]?.stringValue, "string")
            XCTAssertEqual(
                qualificationLease["description"]?.stringValue,
                "[DEBUG start] Private single-use OMP qualification lease UUID. Accepted only for the fail-closed qualification smoke path."
            )
            XCTAssertNil(agentExploreProperties["_omp_qualification_lease_id"])
            let applyEditsReview = try XCTUnwrap(agentRunProperties["_omp_qualification_apply_edits_review"]?.objectValue)
            XCTAssertEqual(applyEditsReview["type"]?.stringValue, "boolean")
            XCTAssertEqual(
                applyEditsReview["description"]?.stringValue,
                "[DEBUG start] Permit Auto Edit=false only for the exact lease/workspace/run-bound OMP qualification start."
            )
            XCTAssertNil(agentExploreProperties["_omp_qualification_apply_edits_review"])
        #endif

        let exploreOpEnum = agentExploreProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(exploreOpEnum, ["start", "poll", "wait", "cancel"])
        for field in [
            "model_id",
            "workflow_id",
            "workflow_name",
            "session_name",
            "wait",
            "timeout_seconds",
            "interaction_id",
            "response",
            "answers",
            "content",
            "meta",
            "amendment"
        ] {
            XCTAssertNil(agentExploreProperties[field], "agent_explore schema must not advertise run-only property \(field)")
        }
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    #if DEBUG
        private struct BootstrapSocketNamespaceFixture {
            let directoryURL: URL
            let socketURL: URL

            static func make() throws -> Self {
                let directoryURL = URL(
                    fileURLWithPath: "/tmp/rpce-xctest-bs-\(getpid())-\(UUID().uuidString)",
                    isDirectory: true
                )
                let socketURL = directoryURL.appendingPathComponent("bootstrap.sock")
                XCTAssertLessThan(socketURL.path.utf8CString.count, MemoryLayout<sockaddr_un>.size)
                XCTAssertNotEqual(socketURL.standardizedFileURL, MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL)
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return .init(directoryURL: directoryURL, socketURL: socketURL)
            }

            func removeOwnedDirectory() {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        private static func withIsolatedBootstrapSocketNamespace(
            window: WindowState,
            catalogService: MCPWindowToolCatalogService,
            operation: (URL) async throws -> Void
        ) async throws {
            let fixture = try BootstrapSocketNamespaceFixture.make()
            let manager = ServerNetworkManager.shared
            await manager.debugResumeAllLifecycleFenceCheckpoints()
            await manager.stop()
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let defaultSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(defaultSocketURL, productionSocketURL)
            let previousEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()

            await assertBootstrapSocketOverrideError(.productionSocketURLRejected) {
                try await manager.debugInstallBootstrapSocketURLOverride(productionSocketURL)
            }

            do {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            } catch {
                fixture.removeOwnedDirectory()
                throw error
            }

            await assertBootstrapSocketOverrideError(.overrideAlreadyInstalled) {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            }

            do {
                try await operation(fixture.socketURL)
            } catch {
                do {
                    try await cleanupIsolatedBootstrapSocketNamespace(
                        window: window,
                        catalogService: catalogService,
                        fixture: fixture,
                        previousEnabledState: previousEnabledState
                    )
                } catch {
                    XCTFail("Failed to clean isolated bootstrap socket namespace: \(error)")
                }
                throw error
            }

            try await cleanupIsolatedBootstrapSocketNamespace(
                window: window,
                catalogService: catalogService,
                fixture: fixture,
                previousEnabledState: previousEnabledState
            )
        }

        private static func cleanupIsolatedBootstrapSocketNamespace(
            window: WindowState,
            catalogService: MCPWindowToolCatalogService,
            fixture: BootstrapSocketNamespaceFixture,
            previousEnabledState: Bool
        ) async throws {
            await window.mcpServer.stopServer()
            ServiceRegistry.unregister(catalogService)
            await window.mcpServer.shutdownListener()

            let manager = ServerNetworkManager.shared
            let runningAfterShutdown = await manager.isRunning()
            XCTAssertFalse(runningAfterShutdown)
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let resolvedSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURL, fixture.socketURL.standardizedFileURL)
            try await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
            let restoredSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(restoredSocketURL, productionSocketURL)
            await manager.setEnabled(previousEnabledState)
            let restoredEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()
            XCTAssertEqual(restoredEnabledState, previousEnabledState)
            let runningAfterEnabledRestore = await manager.isRunning()
            XCTAssertFalse(runningAfterEnabledRestore)
            let resolvedSocketURLAfterEnabledRestore = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURLAfterEnabledRestore, productionSocketURL)
            fixture.removeOwnedDirectory()
        }

        private static func assertBootstrapSocketOverrideError(
            _ expectedError: ServerNetworkManager.DebugBootstrapSocketURLOverrideError,
            operation: () async throws -> Void
        ) async {
            do {
                try await operation()
                XCTFail("Expected bootstrap socket URL override error: \(expectedError)")
            } catch let error as ServerNetworkManager.DebugBootstrapSocketURLOverrideError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("Unexpected bootstrap socket URL override error: \(error)")
            }
        }
    #endif

    private static func schemaProperties(
        for tool: RepoPromptApp.Tool,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, label, file: file, line: line)
        return try XCTUnwrap(schema["properties"]?.objectValue, label, file: file, line: line)
    }

    private static let expectedSignatures: [String] = [
        "0|manage_selection|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b2facb46e2b8f9d4cfb00551bdfa19454b7f3eecd81bac510f4fed12f99452c3|schema=4b7a043e8e48130ee84cc6bbf7b9fd597b495aef238d44f17df6600088a2bb6f",
        "1|file_actions|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=81230c22d826458cae079855b133d59da34c4a66ae4a68252727e564931335b8|schema=4fd6a59a00940e13efc05b74c81372928d3ad3de0e028c8b34586e2168d16103",
        "2|get_code_structure|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=e4706db431bffac60068b536d76486337e57d141bb3bc76b8a0deefc18d42245|schema=63876c20e878abd0465cf824d6fa1876c7fe3388c54d3f0cb087622f644f0cd4",
        "3|get_file_tree|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=9bf648121646b463554d58373f61c2dcede04640482994e0cf1533d21ae77093|schema=91972027e030989cf242fed03377bdc5056c6317cc77d351d3fa5348dd1767a0",
        "4|read_file|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=f5ccd98a8fc0956c4ebcff540ffc8c0eaf0aaeb654b2f8edc0495c059fcf2807|schema=d023edb446167481751886bebeac7dc8896e2b3f57c12b18591761f846618bb1",
        "5|file_search|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=f2c9e16ca780c4e94f795b6c9489658856052e6d159aa467a64c906ee48a3fe4|schema=08904f5e241c06414ff476b80b81338a5798961a69d93227d7ed098694546b99",
        "6|workspace_context|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=fb968e72d430d354b03a0dfdb5251d95bbdea2a38cddcd58fe402f6bcb4f1035|schema=d41b9e8db1ccb1ce385d2d20619485a211bda4a8474270ef0c08fc77647e8376",
        "7|prompt|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=e1377f12a6495829c0ade3e37b9325f7a07dc2065288b16bb810d01a4df9e55d|schema=8c8ea22a39bbb9e10c364ad483527faf109a52e1eb9c45c0c939f569ecf144d1",
        "8|apply_edits|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=d33efa75e3e29e1e4e1cfe90d0e9d621337c397e5329aee02f4a261726d790fa|schema=e1ad464843910182006a484b0545305f8d53821a795cd8e116c07a01eededed8",
        "9|oracle_utils|enabled=true|ann=title=nil,readOnly=nil,destructive=nil,idempotent=nil,openWorld=nil|desc=27f95db5e0be6c58c0ce9ee266dd398fd3c40218b1cd575cb6770c81a8fc63e7|schema=7d3c55c22f02f8825008521e4c20cd304a7c12f3679743b34f5a2bf315d19d7b",
        "10|ask_oracle|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=ed12757a69549419923708376be5bf37c8ea0f38527d92e41991738aaab4e5b8|schema=841c868cfe3c93af4f8bc7a53a504b96867ea50a655d366fde48c91ee9e2e6f0",
        "11|oracle_send|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=788f198c056f825fccbbb4b47d7ac73fd966720a5b25bd2ad4a4a59a88d25646|schema=fe707d3b115d3a22103ad81b217af7025030616179849ad4d326db4597c14b78",
        "12|oracle_chat_log|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=48e4697cb8489f95351b4cbb2b6b38ef2d842527b23e6a4ce5fd4cd67cdd5320|schema=94345e29237a1bf1d5fbba4e28cd618ecbbd9505ff3cacad657fa6bff202dfc8",
        "13|git|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=1a9ff83872cf8842146dd84563dd880f7d9b8f6190cc6e9204a0ea82fc8feca6|schema=51bd804997d6acfaa17d529867f6188b969282a4db95956e859a74ab07de626a",
        "14|manage_worktree|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=857ab8975667e3d2e5b35a09c7415e07ca0ab2f0ff16de6895170d4d1b47a820|schema=9263f9f047982b3709d92040f749804d69928d222ce46038a4171ded34d12bc6",
        "15|context_builder|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=d83348b6b803b303965401075041ddc5d7dcea3512020afa3f352c04413750fb|schema=2da87e6e171809a1e0eb0614fa8f7db2f91311f655f8427745060be80755da1f",
        "16|ask_user|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=6b3870ae4848eb01c73de9fbbdf2ed1782487db150260469853757f799257ee0|schema=080446bb7697cf5f4cd31f07b42ecff8ab29edc8501ee0e84e61426748569156",
        "17|remote_pairing|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b66a65cddc2ce05b1aa4bd372bf87806149f0059c77318f2c0c88d998953733b|schema=78d2d5faef64665bd00b69fe88ebd9776445c1b21e028dbaf03f7bbeaa6dfed2",
        "18|agent_explore|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=698ab006db47713a51f394bfe3f832ada8637440d8acb4715be5430ec380cef8|schema=7b3c869b0c959c1c162dfadfd4ea578b05ed0834b2e930d177a8c38f96c31a4b",
        "19|agent_run|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=d7e34e45febbe2f158be407285081ebc1aa06de44f7c08247e6716cdce930069|schema=bccc0d73bcfdeb996b558c052580e7db42abe60959e1807ad23e54291740ee23",
        "20|agent_manage|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=9642d68a071c59dedd7e2e50da6e39288cb4b6065333cf84237dc1b7b13aed05|schema=e596c8c7039c910fe8c0ee8502bf845ee440b1b0c3153cdf33068dedf921ab45",
        "21|share_thoughts|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b1ac755b39a4ac2d8a621e78801a258c5d95ec2ff4e063f600081fa27891a852|schema=a5dea0c92fd4da06a15f991e1e8a287235ca681ae381cef1b594bc7c07e538d7",
        "22|set_status|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=19bbfd6fc47639e02295de4e9289ea77f25c6a91ad150998726768b84c266783|schema=0854d727c81f1eb8fa0a14edb9d6ab8bb58974d919cc53150bd72473f1ae0196",
        "23|wait_for_next_user_instruction|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=3a59a13a0026414ae04dd21d730a7144b91c67146dce77340fe730c865bea3d7|schema=15335c3bbadf042948d0a1ba52f0fcb01125428dda4952dbda418051904d82ef",
        "24|history|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=e082791f37b91a339f66223799d917cb511ac5d18dbff5bc1f93790743ffe4a8|schema=62e0b861675086e0619134fac7d8823a71531b2afccb6b4451d9c7f519389e5d"
    ]

    private static func signatures(for tools: [RepoPromptApp.Tool]) throws -> [String] {
        try tools.enumerated().map { index, tool in
            let schemaValue = try Value(tool.inputSchema)
            let schemaDigest = try digest(canonicalJSONString(schemaValue))
            let annotations = annotationSignature(tool.annotations)
            let descriptionDigest = digest(tool.description)
            return "\(index)|\(tool.name)|enabled=\(tool.isEnabledByDefault)|ann=\(annotations)|desc=\(descriptionDigest)|schema=\(schemaDigest)"
        }
    }

    private static func annotationSignature(_ annotations: MCP.Tool.Annotations) -> String {
        [
            "title=\(annotations.title ?? "nil")",
            "readOnly=\(optionalBool(annotations.readOnlyHint))",
            "destructive=\(optionalBool(annotations.destructiveHint))",
            "idempotent=\(optionalBool(annotations.idempotentHint))",
            "openWorld=\(optionalBool(annotations.openWorldHint))"
        ].joined(separator: ",")
    }

    private static func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func canonicalJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func digest(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func renderGolden(_ signatures: [String]) -> String {
        let body = signatures
            .map { "        \"\($0)\"" }
            .joined(separator: ",\n")
        return "\n        private static let expectedSignatures: [String] = [\n"
            + body
            + "\n        ]\n"
    }
}
