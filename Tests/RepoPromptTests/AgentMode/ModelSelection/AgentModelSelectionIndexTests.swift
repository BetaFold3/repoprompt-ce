@testable import RepoPromptApp
import XCTest

final class AgentModelSelectionIndexTests: XCTestCase {
    func testLocalIndexFlattensProviderCatalogsAndPreservesRawSelectionSemantics() throws {
        let codexPlaceholder = AgentModelOption(
            rawValue: AgentModel.defaultModel.rawValue,
            displayName: "Default",
            description: nil,
            isPlaceholderDefault: true,
            isProviderDefault: false
        )
        let codex = AgentModelOption(
            rawValue: "gpt-9.9-nova",
            displayName: "GPT-9.9 Nova",
            description: "Future catalog model",
            isDefault: true,
            supportedReasoningEfforts: [.high, .xhigh],
            defaultReasoningEffort: .high
        )
        let claudeHigh = AgentModelOption(
            rawValue: "claude-fable-5:high",
            displayName: "Fable 5 High",
            description: nil,
            isDefault: false
        )
        let claudeXHigh = AgentModelOption(
            rawValue: "claude-fable-5:xhigh",
            displayName: "Fable 5 XHigh",
            description: nil,
            isDefault: false
        )
        let unsupportedClaude = AgentModelOption(
            rawValue: "haiku:xhigh",
            displayName: "Haiku XHigh",
            description: nil,
            isDefault: false
        )
        let cursorPlaceholder = AgentModelOption(
            rawValue: AgentModel.defaultModel.rawValue,
            displayName: "Default",
            description: nil,
            isPlaceholderDefault: true,
            isProviderDefault: false
        )
        let selectedCursorRaw = "gpt-5.6-sol[context=1m,thinking_mode=high,fast=false]"
        let cursor = AgentModelOption(
            rawValue: selectedCursorRaw,
            displayName: "GPT-5.6 Sol · High · 1M",
            description: nil,
            isDefault: true
        )
        let openCode = AgentModelOption(
            rawValue: "provider/model",
            displayName: "Provider Model",
            description: nil,
            isDefault: true
        )
        let index = AgentModelSelectionIndex.local(
            agents: [.codexExec, .claudeCode, .openCode, .cursor],
            optionsByAgent: [
                .codexExec: [codexPlaceholder, codex],
                .claudeCode: [claudeHigh, claudeXHigh, unsupportedClaude],
                .openCode: [openCode],
                .cursor: [cursorPlaceholder, cursor, cursor]
            ],
            selected: AgentModelSelectionLocalSelection(
                agent: .cursor,
                modelRaw: selectedCursorRaw,
                reasoningEffortRaw: nil
            ),
            selectionDefaults: .standard
        )

        let codexLeaves = index.leaves.filter { $0.id.agentRaw == AgentProviderKind.codexExec.rawValue }
        XCTAssertNotNil(codexLeaves.first?.id.effortRaw)
        XCTAssertEqual(Array(codexLeaves.dropFirst().map(\.id.effortRaw)), ["high", "xhigh"])
        XCTAssertEqual(codexLeaves.map(\.id.modelRaw), [
            AgentModel.defaultModel.rawValue,
            "gpt-9.9-nova",
            "gpt-9.9-nova"
        ])

        let claudeRaws = index.leaves
            .filter { $0.id.agentRaw == AgentProviderKind.claudeCode.rawValue }
            .map(\.id.modelRaw)
        XCTAssertEqual(claudeRaws, ["claude-fable-5:high", "claude-fable-5:xhigh"])
        XCTAssertFalse(claudeRaws.contains("haiku:xhigh"))

        XCTAssertTrue(index.leaves.contains { $0.id.modelRaw == "provider/model" })
        let cursorLeaves = index.leaves.filter { $0.id.agentRaw == AgentProviderKind.cursor.rawValue }
        XCTAssertEqual(cursorLeaves.map(\.id.modelRaw), [selectedCursorRaw])
        XCTAssertEqual(cursorLeaves.filter(\.isCurrentSelection).count, 1)
        XCTAssertEqual(index.currentSelectionID, cursorLeaves.first?.id)

        guard case let .local(agent, modelRaw, reasoningEffortRaw) = try XCTUnwrap(
            index.leaves.first { $0.id.modelRaw == "claude-fable-5:high" }
        ).commitPayload else {
            return XCTFail("Expected a local Claude commit payload")
        }
        XCTAssertEqual(agent, .claudeCode)
        XCTAssertEqual(modelRaw, "claude-fable-5:high")
        XCTAssertNil(reasoningEffortRaw)
    }

    func testOMPDefaultAndFastDefaultHaveDistinctQuickSelectionTitles() {
        let base = "cursor/gpt-5.2-codex"
        let fast = "cursor/gpt-5.2-codex-fast"
        let index = AgentModelSelectionIndex.local(
            agents: [.ohMyPi],
            optionsByAgent: [
                .ohMyPi: [
                    AgentModelOption(rawValue: base, displayName: "Base", description: nil, isDefault: true),
                    AgentModelOption(rawValue: fast, displayName: "Fast", description: nil, isDefault: false)
                ]
            ],
            selected: nil,
            selectionDefaults: .standard
        )

        XCTAssertEqual(index.leaves.map(\.title), ["gpt-5.2-codex", "gpt-5.2-codex Fast"])
        XCTAssertEqual(index.leaves.map(\.id.modelRaw), [base, fast])
    }

    func testLocalIndexPreservesParameterizedCursorCurrentRawForValidBaseOption() throws {
        let baseRaw = "gpt-5.6-sol"
        let selectedRaw = "cursor:gpt-5.6-sol[context=1m,thinking_mode=high,fast=false]"
        let baseOption = AgentModelOption(
            rawValue: baseRaw,
            displayName: "GPT-5.6 Sol",
            description: "Base catalog option",
            isDefault: true
        )

        let index = AgentModelSelectionIndex.local(
            agents: [.cursor],
            optionsByAgent: [.cursor: [baseOption]],
            selected: AgentModelSelectionLocalSelection(
                agent: .cursor,
                modelRaw: selectedRaw,
                reasoningEffortRaw: nil
            ),
            selectionDefaults: .standard
        )

        XCTAssertEqual(index.leaves.count, 1)
        let leaf = try XCTUnwrap(index.leaves.first)
        XCTAssertEqual(leaf.id.modelRaw, selectedRaw)
        XCTAssertTrue(leaf.isCurrentSelection)
        XCTAssertEqual(index.currentSelectionID, leaf.id)
        guard case let .local(agent, modelRaw, reasoningEffortRaw) = leaf.commitPayload else {
            return XCTFail("Expected a local Cursor commit payload")
        }
        XCTAssertEqual(agent, .cursor)
        XCTAssertEqual(modelRaw, selectedRaw)
        XCTAssertNil(reasoningEffortRaw)
    }

    func testRankingUsesEffortWordScoresANDTokensAndCatalogOrder() {
        let plain = AgentModelOption(
            rawValue: "gpt-9.9-sol",
            displayName: "GPT-9.9 Sol",
            description: nil,
            isDefault: true,
            supportedReasoningEfforts: [.high, .xhigh],
            defaultReasoningEffort: .high
        )
        let fast = AgentModelOption(
            rawValue: "gpt-9.9-sol-fast",
            displayName: "GPT-9.9 Sol Fast",
            description: nil,
            isDefault: false,
            supportedReasoningEfforts: [.high, .xhigh],
            defaultReasoningEffort: .high
        )
        let fableHigh = AgentModelOption(
            rawValue: "claude-fable-5:high",
            displayName: "Fable 5 High",
            description: nil,
            isDefault: false
        )
        let fableXHigh = AgentModelOption(
            rawValue: "claude-fable-5:xhigh",
            displayName: "Fable 5 XHigh",
            description: nil,
            isDefault: false
        )
        let index = AgentModelSelectionIndex.local(
            agents: [.codexExec, .claudeCode],
            optionsByAgent: [
                .codexExec: [plain, fast],
                .claudeCode: [fableHigh, fableXHigh]
            ],
            selected: AgentModelSelectionLocalSelection(
                agent: .codexExec,
                modelRaw: plain.rawValue,
                reasoningEffortRaw: CodexReasoningEffort.high.rawValue
            ),
            selectionDefaults: .standard
        )

        let fableMatches = index.ranked(query: "fable high")
        XCTAssertEqual(fableMatches.first?.id.modelRaw, "claude-fable-5:high")
        XCTAssertEqual(fableMatches.map(\.id.modelRaw), [
            "claude-fable-5:high",
            "claude-fable-5:xhigh"
        ])

        let solMatches = index.ranked(query: "sol xhigh")
        XCTAssertEqual(solMatches.count, 2)
        XCTAssertEqual(solMatches.map(\.id.modelRaw), [
            "gpt-9.9-sol",
            "gpt-9.9-sol-fast"
        ])
        XCTAssertTrue(solMatches[1].showsWarning)
        XCTAssertTrue(index.ranked(query: "sol missing").isEmpty)
        XCTAssertFalse(index.ranked(query: "codexexec gpt-9.9-sol").isEmpty)

        let emptyQuery = index.ranked(query: "")
        XCTAssertEqual(emptyQuery.map(\.catalogOrder), emptyQuery.map(\.catalogOrder).sorted())
        XCTAssertEqual(index.currentSelectionID, emptyQuery.first?.id)
    }

    func testOptionlessCodexLeafUsesModelScopedLastUsedEffort() throws {
        let suiteName = "AgentModelSelectionIndexTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let option = AgentModelOption(
            rawValue: "gpt-9.9-optionless",
            displayName: "GPT-9.9 Optionless",
            description: nil,
            isDefault: false
        )
        CodexAgentToolPreferences.setLastUsedReasoningEffort(
            .xhigh,
            forModelRaw: option.rawValue,
            defaults: defaults
        )

        let index = AgentModelSelectionIndex.local(
            agents: [.codexExec],
            optionsByAgent: [.codexExec: [option]],
            selected: nil,
            selectionDefaults: defaults
        )
        guard case let .local(_, _, effortRaw) = try XCTUnwrap(
            index.leaves.first
        ).commitPayload else {
            return XCTFail("Expected a local Codex leaf")
        }
        XCTAssertEqual(effortRaw, CodexReasoningEffort.xhigh.rawValue)
    }

    func testRemoteCursorFastLeafShowsWarning() throws {
        let fastRaw = "cursor:gpt-5.6-sol[thinking_mode=high,fast=true]"
        let fast = RemoteHostModel(
            modelID: fastRaw,
            name: "Cursor GPT-5.6 Sol High Fast",
            agentID: AgentProviderKind.cursor.rawValue,
            baseModelID: "gpt-5.6-sol",
            modelDisplayName: "GPT-5.6 Sol",
            isDefault: true
        )
        let catalog = RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Cursor",
                defaultModelID: fastRaw,
                models: [fast]
            )
        ])

        let index = AgentModelSelectionIndex.remote(
            hostID: "host-cursor",
            hostDisplayName: "Studio Mac",
            catalog: catalog,
            includeHostDefault: false,
            selectedModelID: nil
        )
        XCTAssertEqual(index.leaves.count, 1)
        let leaf = try XCTUnwrap(index.leaves.first)
        XCTAssertEqual(leaf.id.modelRaw, fastRaw)
        XCTAssertTrue(leaf.showsWarning)
    }

    func testRemoteIndexSeparatesHostDefaultAndHandoffPoliciesAndDeduplicatesIdentity() {
        let high = RemoteHostModel(
            modelID: "codexExec:gpt-9.9-sol-high",
            name: "Codex CLI GPT-9.9 Sol High",
            agentID: "codexExec",
            baseModelID: "gpt-9.9-sol",
            effort: "high",
            modelDisplayName: "GPT-9.9 Sol",
            effortDisplayName: "High",
            isDefault: true
        )
        let catalog = RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Codex CLI",
                defaultModelID: high.modelID,
                models: [high, high]
            )
        ])

        let currentIndex = AgentModelSelectionIndex.remote(
            hostID: "host-a",
            hostDisplayName: "Studio Mac",
            catalog: catalog,
            includeHostDefault: true,
            selectedModelID: RemoteHostAgentCatalog.hostDefaultModelID
        )
        XCTAssertEqual(currentIndex.leaves.map(\.title), ["Host default", "GPT-9.9 Sol High"])
        XCTAssertEqual(currentIndex.leaves.filter(\.isCurrentSelection).count, 1)
        XCTAssertEqual(currentIndex.leaves.first?.commitPayload, .hostDefault(hostID: "host-a"))

        let handoffIndex = AgentModelSelectionIndex.remote(
            hostID: "host-a",
            hostDisplayName: "Studio Mac",
            catalog: catalog,
            includeHostDefault: false,
            selectedModelID: high.modelID
        )
        XCTAssertEqual(handoffIndex.leaves.count, 1)
        XCTAssertEqual(
            handoffIndex.leaves.first?.commitPayload,
            .remote(agentID: "codexExec", modelID: high.modelID, effort: "high")
        )
        XCTAssertEqual(handoffIndex.currentSelectionID, handoffIndex.leaves.first?.id)

        XCTAssertTrue(AgentModelSelectionIndex.remote(
            hostID: "host-a",
            hostDisplayName: nil,
            catalog: .degraded,
            includeHostDefault: false,
            selectedModelID: nil
        ).leaves.isEmpty)
        XCTAssertEqual(AgentModelSelectionIndex.remote(
            hostID: "host-a",
            hostDisplayName: nil,
            catalog: .degraded,
            includeHostDefault: true,
            selectedModelID: nil
        ).leaves.count, 1)
    }
}
