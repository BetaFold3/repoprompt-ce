import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCLIModelDiscoveryTests: XCTestCase {
    /// Sanitized shape captured from Claude Code 2.1.281 initialization, without a user turn.
    private func response(
        rows: [[String: Any]],
        account: [String: Any] = ["apiProvider": "firstParty", "email": "fixture@example.invalid", "organization": "fixture-org"]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "control_response",
            "response": [
                "subtype": "success", "request_id": ClaudeCLIModelDiscoveryProbe.requestID,
                "response": ["models": rows, "account": account]
            ]
        ])
    }

    func testInitializationUsesResolvedWireIDsWithoutGuessingFromLabels() throws {
        let data = try response(rows: [
            ["value": "default", "resolvedModel": "claude-opus-5-5[1m]", "displayName": "Default (recommended)"],
            ["value": "opus[1m]", "resolvedModel": "claude-opus-5-5[1m]"],
            ["value": "claude-fable-5-1[1m]", "resolvedModel": "claude-fable-5-1"],
            ["value": "sonnet", "resolvedModel": "claude-sonnet-5"],
            ["value": "opus", "displayName": "Opus 5.99"],
            ["value": "claude-opus-5-8", "resolvedModel": "custom-model"],
            ["value": "claude-opus-5-9"]
        ])
        let result = try ClaudeCLIModelDiscoveryProbe.decode(data, executable: "/fixture/claude")
        XCTAssertEqual(result.modelIDs, ["claude-fable-5-1", "claude-opus-5-5[1m]", "claude-opus-5-9"])
        let scope = try XCTUnwrap(result.scope)
        XCTAssertEqual(scope.count, 64)
        XCTAssertFalse(scope.contains("fixture"))
        let changed = try response(rows: [], account: [
            "apiProvider": "firstParty", "email": "another@example.invalid", "organization": "fixture-org"
        ])
        XCTAssertNotEqual(try ClaudeCLIModelDiscoveryProbe.decode(changed, executable: "/fixture/claude").scope, scope)
    }

    func testMalformedUnsupportedAndAnonymousInitializationBoundaries() throws {
        for rows in [
            [["value": "opus", "resolvedModel": 5]],
            [["value": "opus", "resolvedModel": ""]],
            [["value": "claude-opus-5-5\n"]]
        ] as [[[String: Any]]] {
            XCTAssertThrowsError(try ClaudeCLIModelDiscoveryProbe.decode(response(rows: rows), executable: "/claude"))
        }
        XCTAssertThrowsError(try ClaudeCLIModelDiscoveryProbe.decode(Data("{}".utf8), executable: "/claude"))
        XCTAssertThrowsError(try ClaudeCLIModelDiscoveryProbe.decode(
            response(rows: [], account: ["apiProvider": "bedrock"]), executable: "/claude"
        ))
        let empty = try ClaudeCLIModelDiscoveryProbe.decode(response(rows: []), executable: "/claude")
        XCTAssertEqual(empty.modelIDs, [])
        let anonymous = try ClaudeCLIModelDiscoveryProbe.decode(
            response(rows: [["value": "claude-opus-5-8"]], account: ["apiProvider": "firstParty"]),
            executable: "/claude"
        )
        XCTAssertNil(anonymous.scope)
        XCTAssertEqual(anonymous.modelIDs, ["claude-opus-5-8"])
        XCTAssertFalse(ClaudeCLIModelDiscoveryProbe.isFirstPartyEnvironment(["ANTHROPIC_BASE_URL": "https://example.invalid"]))
        XCTAssertFalse(ClaudeCLIModelDiscoveryProbe.isFirstPartyEnvironment(["CLAUDE_CODE_USE_VERTEX": "1"]))
        XCTAssertTrue(ClaudeCLIModelDiscoveryProbe.isFirstPartyEnvironment([:]))
    }

    func testCLIContextSuffixPreservesWireIdentityWithoutWideningAPIGrammar() throws {
        let raw = "claude-opus-5-8[1m]"
        let release = try XCTUnwrap(ClaudeModelFamilyCatalog.cliPointRelease(raw))
        XCTAssertEqual(release.rawModelID, raw)
        XCTAssertEqual(release.generatedDisplayName, "Opus 5.8 (1M)")
        XCTAssertNil(ClaudeModelFamilyCatalog.pointRelease(raw))
        for rejected in ["claude-opus-5-8[1m][1m]", "claude-opus-5-8[1M]", "claude-opus-5-8[2m]", "claude-opus-6-1[1m]", "claude-opus-5-8[1m] "] {
            XCTAssertNil(ClaudeModelFamilyCatalog.cliPointRelease(rejected), rejected)
        }
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true)
        XCTAssertEqual(ClaudeCompatibleModelCatalogAdapter.isValid(rawModel: raw + ":xhigh", for: .claudeCode, availability: availability), true)
        XCTAssertEqual(ClaudeCodeAIModelCatalog.validatedModel(specifier: raw + ":high")?.claudeCodeRuntimeSpecifierRaw, raw + ":high")
        XCTAssertEqual(AIModelCapabilityMetadata.resolve(for: .claudeCodeModel(specifier: raw)).exactContextWindowTokens, 1_000_000)
        XCTAssertTrue(ClaudeCompatibleModelCatalogAdapter.claudeEffort(.xhigh, isSupportedForBaseModelRaw: raw, agentKind: .claudeCode))
        XCTAssertFalse(ClaudeCompatibleModelCatalogAdapter.claudeEffort(.xhigh, isSupportedForBaseModelRaw: raw, agentKind: .kimiCode))
    }

    func testScopedPersistenceIsInactiveUntilVerifiedAndRetainsLastGoodBytes() throws {
        let suite = "ClaudeCLIModelDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaudeCLIDiscoveredModelStore(defaults: defaults)
        XCTAssertTrue(store.replace(modelIDs: ["claude-opus-5-8[1m]"], scope: "account-a"))
        let restored = ClaudeCLIDiscoveredModelStore(defaults: defaults)
        XCTAssertEqual(restored.revisionedModels.modelIDs, [])
        restored.activate(scope: "account-b")
        XCTAssertEqual(restored.revisionedModels.modelIDs, [])
        restored.activate(scope: "account-a")
        XCTAssertEqual(restored.revisionedModels.modelIDs, ["claude-opus-5-8[1m]"])
        let revision = restored.revisionedModels.revision
        XCTAssertTrue(restored.replace(modelIDs: ["claude-opus-5-8[1m]"], scope: "account-a"))
        XCTAssertEqual(restored.revisionedModels.revision, revision)
        let bytes = defaults.data(forKey: ClaudeCLIDiscoveredModelStore.storageKey)
        XCTAssertFalse(restored.replace(modelIDs: ["claude-opus-6-1"], scope: "account-a"))
        XCTAssertEqual(defaults.data(forKey: ClaudeCLIDiscoveredModelStore.storageKey), bytes)
        XCTAssertTrue(restored.replace(modelIDs: ["claude-opus-5-9"], scope: nil))
        XCTAssertEqual(defaults.data(forKey: ClaudeCLIDiscoveredModelStore.storageKey), bytes)
        XCTAssertTrue(restored.replace(modelIDs: [], scope: "account-a"))
        XCTAssertEqual(restored.revisionedModels.modelIDs, [])
        defaults.set(Data("{\"version\":99}".utf8), forKey: ClaudeCLIDiscoveredModelStore.storageKey)
        let future = ClaudeCLIDiscoveredModelStore(defaults: defaults)
        future.activate(scope: "account-a")
        XCTAssertEqual(future.revisionedModels.modelIDs, [])
        XCTAssertEqual(defaults.data(forKey: ClaudeCLIDiscoveredModelStore.storageKey), Data("{\"version\":99}".utf8))
    }

    func testCatalogUnionWithdrawalAndCompatibleBackendExclusion() throws {
        let api = AnthropicDiscoveredModelStore.transient()
        let cli = ClaudeCLIDiscoveredModelStore()
        XCTAssertTrue(api.replace(with: [AnthropicDiscoveredModel(id: "claude-opus-5-8", displayName: "API Opus 5.8")]))
        XCTAssertTrue(cli.replace(modelIDs: ["claude-opus-5-8", "claude-opus-5-8[1m]", "claude-opus-5-9"], scope: "fixture"))
        let definitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(store: api, cliStore: cli)
        XCTAssertEqual(definitions.count(where: { $0.runtimeModelRaw == "claude-opus-5-8" }), 1)
        XCTAssertEqual(definitions.first { $0.runtimeModelRaw == "claude-opus-5-8" }?.displayName, "API Opus 5.8")
        XCTAssertEqual(definitions.first { $0.runtimeModelRaw == "claude-opus-5-8[1m]" }?.displayName, "Opus 5.8 (1M)")
        let picker = ClaudeCodeAIModelCatalog.modelsForPicker(store: api, cliStore: cli)
        let menu = ClaudeCodeAIModelCatalog.menu(for: picker, store: api, cliStore: cli)
        XCTAssertTrue(menu.groups.contains { $0.baseModelRaw == "claude-opus-5-8[1m]" })
        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true)
        let snapshot = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .claudeCode, availability: availability, store: api, cliStore: cli
        ))
        XCTAssertTrue(snapshot.options.contains { $0.rawValue == "claude-opus-5-8[1m]:xhigh" })
        let compatibleAvailability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true, kimiConfigured: true)
        let compatible = try XCTUnwrap(ClaudeCompatibleModelCatalogAdapter.catalogSnapshot(
            for: .kimiCode, availability: compatibleAvailability, store: api, cliStore: cli
        ))
        XCTAssertFalse(compatible.options.isEmpty)
        XCTAssertFalse(compatible.options.contains { $0.rawValue.contains("claude-opus-5-8") })
        cli.deactivate()
        let withdrawn = ClaudeCodeAIModelCatalog.effectiveDefinitions(store: api, cliStore: cli)
        XCTAssertTrue(withdrawn.contains { $0.runtimeModelRaw == "claude-opus-5-8" })
        XCTAssertFalse(withdrawn.contains { $0.runtimeModelRaw == "claude-opus-5-8[1m]" })
        XCTAssertNotNil(ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-opus-5-8[1m]:high", store: api, cliStore: cli))
    }

    func testProbeSendsOnlyInitializationAndRequiresCleanProcessCompletion() async throws {
        let output = try XCTUnwrap(String(data: response(rows: [
            ["value": "opus[1m]", "resolvedModel": "claude-opus-5-8[1m]"]
        ]), encoding: .utf8))
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // Exercise the production runner, stdin EOF, flags and decoder without authentication or inference.
        var script = "test \"$#\" = \(ClaudeCLIModelDiscoveryProbe.arguments.count) || exit 31\n"
        for argument in ClaudeCLIModelDiscoveryProbe.arguments {
            script += "test \"$1\" = \(quoted(argument)) || exit 32; shift\n"
        }
        script += "IFS= read -r request\n"
        script += "test \"$request\" = \(quoted(String(ClaudeCLIModelDiscoveryProbe.input.dropLast()))) || exit 33\n"
        script += "if IFS= read -r extra; then exit 34; fi\n"
        script += "printf '%s\\n' \(quoted(output))\n"
        let config = CLIProcessConfiguration(command: "/bin/sh", commandSuffix: ["-c", script, "--"])
        let result = try await ClaudeCLIModelDiscoveryProbe.run(config: config)
        XCTAssertEqual(result.modelIDs, ["claude-opus-5-8[1m]"])
        let failing = CLIProcessConfiguration(command: "/bin/sh", commandSuffix: ["-c", "exit 35", "--"])
        do {
            _ = try await ClaudeCLIModelDiscoveryProbe.run(config: failing)
            XCTFail("Nonzero probe must not become an authoritative empty catalog")
        } catch ClaudeCLIModelDiscoveryProbe.Failure.unavailable {
            // Expected; other errors fail the test.
        }
    }

    @MainActor
    func testRefreshFailureRetainsCurrentCatalogButInvalidationDoesNot() async {
        let store = ClaudeCLIDiscoveredModelStore()
        var shouldFail = false
        var calls = 0
        let service = ClaudeCLIModelDiscoveryService(store: store) { _ in
            calls += 1
            if shouldFail {
                return try ClaudeCLIModelDiscoveryProbe.decode(Data("{}".utf8), executable: "/fixture/claude")
            }
            return .init(modelIDs: ["claude-opus-5-8[1m]"], scope: "fixture")
        }
        let config = CLIProcessConfiguration(command: "fixture-claude")
        await service.refresh(config: config)
        await service.refresh(config: config)
        XCTAssertEqual(calls, 1)
        shouldFail = true
        await service.refresh(config: config, force: true)
        XCTAssertEqual(store.revisionedModels.modelIDs, ["claude-opus-5-8[1m]"])
        XCTAssertTrue(service.caption.contains("keeping"))
        service.invalidate()
        await service.refresh(config: config, force: true)
        XCTAssertEqual(store.revisionedModels.modelIDs, [])
        XCTAssertFalse(service.isRefreshing)
    }

    @MainActor
    func testInvalidatedInFlightCompletionCannotRepublishModels() async {
        let store = ClaudeCLIDiscoveredModelStore()
        let started = expectation(description: "probe started")
        var continuation: CheckedContinuation<ClaudeCLIModelDiscoveryProbe.Result, Never>?
        var calls = 0
        let service = ClaudeCLIModelDiscoveryService(store: store) { _ in
            calls += 1
            if calls > 1 {
                return .init(modelIDs: ["claude-opus-5-9"], scope: "successor")
            }
            return await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let config = CLIProcessConfiguration(command: "fixture-claude")
        let first = Task { await service.refresh(config: config) }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "second waiter joined")
        let second = Task {
            joined.fulfill()
            await service.refresh(config: config, force: true)
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(calls, 1)
        var changedConfig = config
        changedConfig.environment = ["CLAUDE_CONFIG_DIR": "/fixture/other-account"]
        let replacing = expectation(description: "configuration changed")
        let successor = Task {
            replacing.fulfill()
            await service.refresh(config: changedConfig)
        }
        await fulfillment(of: [replacing], timeout: 2)
        XCTAssertEqual(calls, 1, "Successor must wait for the obsolete process to finish")
        XCTAssertEqual(store.revisionedModels.modelIDs, [])
        continuation?.resume(returning: .init(modelIDs: ["claude-opus-5-8"], scope: "obsolete"))
        await first.value
        await second.value
        await successor.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.revisionedModels.modelIDs, ["claude-opus-5-9"])
        XCTAssertEqual(store.snapshot?.scope, "successor")
        XCTAssertFalse(service.isRefreshing)
    }
}
