@testable import RepoPromptApp
import XCTest

final class RemoteHostCatalogTests: XCTestCase {
    func testCapturedListAgentsFixtureDecodesRemoteCatalog() throws {
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(contentsOf: fixtureURL()))

        XCTAssertFalse(catalog.isDegraded)
        XCTAssertGreaterThan(catalog.agents.count, 1)
        XCTAssertGreaterThan(catalog.taskLabels.count, 0)

        let codexAgent = try XCTUnwrap(catalog.agents.first { $0.name == "Codex CLI" })
        XCTAssertTrue(codexAgent.available)
        XCTAssertEqual(codexAgent.defaultModelID, "codexExec:default")
        XCTAssertTrue(codexAgent.capabilities.contains("agent_conversation_send"))

        let codexLow = try XCTUnwrap(codexAgent.models.first { $0.modelID == "codexExec:gpt-5.5-low" })
        XCTAssertEqual(codexLow.name, "Codex CLI GPT-5.5 Low")
        XCTAssertEqual(codexLow.reasoningEffort, "low")
        XCTAssertEqual(catalog.displayName(forModelID: codexLow.modelID), codexLow.name)
        XCTAssertEqual(catalog.reasoningEffort(forModelID: codexLow.modelID), "low")
        XCTAssertEqual(RemoteHostAgentCatalog.agentKind(forModelID: codexLow.modelID), .codexExec)

        let exploreLabel = try XCTUnwrap(catalog.taskLabels.first { $0.label == "explore" })
        XCTAssertEqual(exploreLabel.modelID, "codexExec:gpt-5.5-medium")
        XCTAssertEqual(catalog.displayName(forModelID: exploreLabel.modelID), "Codex CLI GPT-5.5 Medium")
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart("  \(exploreLabel.modelID)  "), exploreLabel.modelID)

        // Role labels are valid host-portable selections: display resolves via
        // task_labels and the raw label passes through to agent_run.start.
        XCTAssertEqual(catalog.displayName(forModelID: "explore"), exploreLabel.name)
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart("explore"), "explore")
    }

    func testRoleLabelOnlyCatalogExposesTaskLabelsWithoutAgents() throws {
        // Hosts with restricted discovery (or roles_only) omit `agents` but
        // always return `task_labels` — the catalog is not degraded.
        let json = """
        {
          "task_labels": [
            {"label": "pair", "model_id": "claudeCode:claude-fable-5", "name": "Claude Fable 5"},
            {"label": "explore", "model_id": "codexExec:gpt-5.5-medium", "name": "Codex CLI GPT-5.5 Medium"}
          ]
        }
        """
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(json.utf8))

        XCTAssertFalse(catalog.isDegraded)
        XCTAssertTrue(catalog.selectableAgents.isEmpty)
        XCTAssertEqual(catalog.taskLabels.count, 2)
        XCTAssertEqual(catalog.displayName(forModelID: "pair"), "Claude Fable 5")
        XCTAssertEqual(catalog.displayName(forModelID: "explore"), "Codex CLI GPT-5.5 Medium")
        // Label matches resolve by label first, then by task-label model_id.
        XCTAssertEqual(catalog.displayName(forModelID: "claudeCode:claude-fable-5"), "Claude Fable 5")
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart("pair"), "pair")
        XCTAssertEqual(RemoteHostAgentCatalog.agentKind(forModelID: "claudeCode:claude-fable-5"), .claudeCode)
    }

    func testDegradedCatalogUsesHostDefaultAndOmitsStartModelID() {
        let degraded = RemoteHostAgentCatalog.degraded

        XCTAssertTrue(degraded.isDegraded)
        XCTAssertEqual(degraded.agents, [.hostDefault])
        XCTAssertTrue(degraded.selectableAgents.isEmpty)
        XCTAssertEqual(degraded.displayName(forModelID: nil), RemoteHostAgentCatalog.hostDefaultDisplayName)
        XCTAssertEqual(
            degraded.displayName(forModelID: RemoteHostAgentCatalog.hostDefaultModelID),
            RemoteHostAgentCatalog.hostDefaultDisplayName
        )
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(nil))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(""))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("  "))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart(RemoteHostAgentCatalog.hostDefaultModelID))
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart(" codexExec:gpt-5.5-low "), "codexExec:gpt-5.5-low")
    }

    func testModelIDForStartRejectsStaleLocalAndUnknownSelections() {
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("gpt-5.5"))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("gpt-5.5-low"))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("sonnet"))
        XCTAssertNil(RemoteHostAgentCatalog.modelIDForStart("nope:model"))

        for labelKind in AgentModelCatalog.TaskLabelKind.allCases {
            XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart(labelKind.rawValue), labelKind.rawValue)
        }
        XCTAssertEqual(RemoteHostAgentCatalog.modelIDForStart(" codexExec:gpt-5.5-low "), "codexExec:gpt-5.5-low")
    }

    func testStructuredCatalogGroupsModelsByCLIBaseModelAndEffort() throws {
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(structuredCatalogJSON.utf8))

        XCTAssertTrue(catalog.supportsStructuredModelGroups)
        let agent = try XCTUnwrap(catalog.structuredAgentGroups.first)
        XCTAssertEqual(agent.name, "Claude Code")
        XCTAssertEqual(agent.agentKind, .claudeCode)

        let fable = try XCTUnwrap(agent.models.first { $0.baseModelID == "claude-fable-5" })
        XCTAssertEqual(fable.displayName, "Fable 5")
        XCTAssertEqual(fable.options.map(\.modelID), [
            "claudeCode:claude-fable-5:low",
            "claudeCode:claude-fable-5:medium",
            "claudeCode:claude-fable-5:high"
        ])
        XCTAssertEqual(fable.effortOptions.map(\.displayName), ["Low", "Medium", "High"])
        XCTAssertEqual(fable.preferredModelID, "claudeCode:claude-fable-5:high")
        XCTAssertEqual(catalog.modelID(forEffort: "low", selectedModelID: fable.preferredModelID), "claudeCode:claude-fable-5:low")
        XCTAssertEqual(catalog.reasoningEffort(forModelID: "claudeCode:claude-fable-5:high"), "high")
        XCTAssertEqual(catalog.effortDisplayName(forModelID: "claudeCode:claude-fable-5:high"), "High")
        XCTAssertEqual(catalog.chipTitle(forModelID: "claudeCode:claude-fable-5:high"), "Claude Code · Fable 5")
        XCTAssertEqual(
            RemoteHostAgentCatalog.modelIDForStart(fable.preferredModelID),
            "claudeCode:claude-fable-5:high"
        )
    }

    func testStructuredCatalogFallsBackToMiddleEffortWhenHostDefaultIsAbsent() throws {
        let json = structuredCatalogJSON.replacingOccurrences(of: #""is_default": true"#, with: #""is_default": false"#)
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(json.utf8))
        let fable = try XCTUnwrap(catalog.structuredAgentGroups.first?.models.first { $0.baseModelID == "claude-fable-5" })

        XCTAssertEqual(fable.preferredModelID, "claudeCode:claude-fable-5:medium")
        XCTAssertEqual(catalog.modelID(forEffort: "high", selectedModelID: fable.preferredModelID), "claudeCode:claude-fable-5:high")
    }

    func testUnenrichedCatalogKeepsLegacyFlatFallbackWithoutEffortPicker() throws {
        let json = """
        {
          "agents": [
            {
              "name": "Codex CLI",
              "available": true,
              "models": [
                {"model_id": "codexExec:gpt-5.5-low", "name": "Codex CLI GPT-5.5 Low", "reasoning_effort": "low"}
              ],
              "capabilities": []
            }
          ],
          "task_labels": [
            {"label": "explore", "model_id": "codexExec:gpt-5.5-low", "name": "Codex CLI GPT-5.5 Low"}
          ]
        }
        """
        let catalog = try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: Data(json.utf8))

        XCTAssertFalse(catalog.supportsStructuredModelGroups)
        XCTAssertTrue(catalog.structuredAgentGroups.isEmpty)
        XCTAssertEqual(catalog.selectableAgents.first?.models.first?.name, "Codex CLI GPT-5.5 Low")
        XCTAssertEqual(catalog.displayName(forModelID: "codexExec:gpt-5.5-low"), "Codex CLI GPT-5.5 Low")
        XCTAssertEqual(catalog.reasoningEffort(forModelID: "codexExec:gpt-5.5-low"), "low")
        XCTAssertTrue(catalog.effortOptions(forModelID: "codexExec:gpt-5.5-low").isEmpty)
    }

    @MainActor
    func testDegradedCatalogIsServedFromCacheWithinTTL() async {
        let clock = RemoteHostCatalogTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let loader = RemoteHostCatalogTestLoader(responses: [
            .degraded,
            healthyCatalog(modelID: "codexExec:healthy-after-degraded")
        ])
        let catalog = RemoteHostCatalog(now: { clock.now }, catalogLoader: loader.load)

        let first = await catalog.catalog(for: "host-a")
        clock.now = clock.now.addingTimeInterval(19)
        let second = await catalog.catalog(for: "host-a")

        XCTAssertTrue(first.isDegraded)
        XCTAssertEqual(second, first)
        XCTAssertEqual(catalog.cachedCatalog(for: "host-a"), first)
        XCTAssertEqual(loader.loadCount, 1)
    }

    @MainActor
    func testDegradedCatalogReloadsAfterTTLAndHealthyCatalogReplacesIt() async {
        let clock = RemoteHostCatalogTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let healthy = healthyCatalog(modelID: "codexExec:healthy-after-expiry")
        let loader = RemoteHostCatalogTestLoader(responses: [.degraded, healthy])
        let catalog = RemoteHostCatalog(now: { clock.now }, catalogLoader: loader.load)

        let degraded = await catalog.catalog(for: "host-b")
        clock.now = clock.now.addingTimeInterval(21)
        let reloaded = await catalog.catalog(for: "host-b")

        XCTAssertTrue(degraded.isDegraded)
        XCTAssertEqual(reloaded, healthy)
        XCTAssertEqual(catalog.cachedCatalog(for: "host-b"), healthy)
        XCTAssertEqual(loader.loadCount, 2)
    }

    @MainActor
    func testHealthyCatalogIsServedBeforeTTLAndReloadedAfterTTL() async {
        let clock = RemoteHostCatalogTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let firstHealthy = healthyCatalog(modelID: "codexExec:first-healthy")
        let secondHealthy = healthyCatalog(modelID: "codexExec:second-healthy")
        let loader = RemoteHostCatalogTestLoader(responses: [firstHealthy, secondHealthy])
        let catalog = RemoteHostCatalog(now: { clock.now }, catalogLoader: loader.load)

        let first = await catalog.catalog(for: "host-c")
        clock.now = clock.now.addingTimeInterval(299)
        let cached = await catalog.catalog(for: "host-c")
        clock.now = clock.now.addingTimeInterval(2)
        let reloaded = await catalog.catalog(for: "host-c")

        XCTAssertEqual(first, firstHealthy)
        XCTAssertEqual(cached, firstHealthy)
        XCTAssertEqual(reloaded, secondHealthy)
        XCTAssertEqual(loader.loadCount, 2)
    }

    @MainActor
    func testCancelledCatalogLoadDoesNotPopulateCache() async {
        let loader = RemoteHostCatalogSuspendingLoader()
        let catalog = RemoteHostCatalog(catalogLoader: loader.load)
        let loadTask = Task { @MainActor in
            await catalog.catalog(for: "host-d")
        }

        while loader.loadCount == 0 {
            await Task.yield()
        }
        loadTask.cancel()
        loader.resume(with: .degraded)

        let result = await loadTask.value

        XCTAssertTrue(result.isDegraded)
        XCTAssertNil(catalog.cachedCatalog(for: "host-d"))
    }

    private func healthyCatalog(modelID: String) -> RemoteHostAgentCatalog {
        RemoteHostAgentCatalog(
            agents: [
                RemoteHostAgent(
                    name: "Codex CLI",
                    defaultModelID: modelID,
                    models: [
                        RemoteHostModel(
                            modelID: modelID,
                            name: "Model \(modelID)",
                            reasoningEffort: nil
                        )
                    ],
                    capabilities: ["agent_conversation_send"]
                )
            ]
        )
    }

    private var structuredCatalogJSON: String {
        """
        {
          "agents": [
            {
              "name": "Claude Code",
              "available": true,
              "default_model_id": "claudeCode:claude-fable-5:high",
              "models": [
                {
                  "model_id": "claudeCode:claude-fable-5:low",
                  "name": "Claude Code Fable 5 Low",
                  "agent_id": "claudeCode",
                  "base_model_id": "claude-fable-5",
                  "model_display_name": "Fable 5",
                  "effort": "low",
                  "effort_display_name": "Low"
                },
                {
                  "model_id": "claudeCode:claude-fable-5:medium",
                  "name": "Claude Code Fable 5 Medium",
                  "agent_id": "claudeCode",
                  "base_model_id": "claude-fable-5",
                  "model_display_name": "Fable 5",
                  "effort": "medium",
                  "effort_display_name": "Medium"
                },
                {
                  "model_id": "claudeCode:claude-fable-5:high",
                  "name": "Claude Code Fable 5 High",
                  "agent_id": "claudeCode",
                  "base_model_id": "claude-fable-5",
                  "model_display_name": "Fable 5",
                  "effort": "high",
                  "effort_display_name": "High",
                  "is_default": true
                }
              ],
              "capabilities": ["agent_conversation_send"]
            }
          ],
          "task_labels": [
            {"label": "pair", "model_id": "claudeCode:claude-fable-5:high", "name": "Claude Code Fable 5 High"}
          ]
        }
        """
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentMode/Fixtures/RemoteHostCatalog/agent_manage_list_agents_response.json")
    }
}

private final class RemoteHostCatalogTestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class RemoteHostCatalogTestLoader {
    private var responses: [RemoteHostAgentCatalog]
    private(set) var loadCount = 0

    init(responses: [RemoteHostAgentCatalog]) {
        self.responses = responses
    }

    func load(hostID _: String) async -> RemoteHostAgentCatalog {
        loadCount += 1
        guard !responses.isEmpty else { return .degraded }
        return responses.removeFirst()
    }
}

@MainActor
private final class RemoteHostCatalogSuspendingLoader {
    private var continuation: CheckedContinuation<RemoteHostAgentCatalog, Never>?
    private(set) var loadCount = 0

    func load(hostID _: String) async -> RemoteHostAgentCatalog {
        loadCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with catalog: RemoteHostAgentCatalog) {
        continuation?.resume(returning: catalog)
        continuation = nil
    }
}
