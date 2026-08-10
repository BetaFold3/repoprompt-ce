import Foundation
@testable import RepoPromptApp
import XCTest

final class OhMyPiACPProviderTests: XCTestCase {
    override func tearDown() {
        AgentACPModelRegistry.shared.reset(providerID: .ohMyPi)
        super.tearDown()
    }

    func testIdentityAndManagedArgumentsAreExact() throws {
        XCTAssertEqual(ACPProviderID.ohMyPi.rawValue, "ohMyPi")
        XCTAssertEqual(AgentProviderKind.ohMyPi.rawValue, "ohMyPi")
        XCTAssertEqual(AgentProviderBindingID.ohMyPi.rawValue, "ohMyPi")
        XCTAssertEqual(AgentProviderKind.ohMyPi.commandName, "omp")
        XCTAssertEqual(AgentProviderKind.ohMyPi.runtimeKind, "omp_acp")
        XCTAssertEqual(AgentProviderKind.ohMyPi.displayName, "Oh My Pi")
        XCTAssertEqual(AgentProviderKind.ohMyPi.mcpClientNameHint, "oh-my-pi")
        XCTAssertEqual(
            OhMyPiAgentConfig.managedArguments,
            ["acp", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--approval-mode", "yolo"]
        )

        let directory = try makeTestDirectory(name: "OhMyPiACPProviderTests-launch")
        let executable = try makeOMPExecutable(in: directory)
        let provider = OhMyPiACPAgentProvider(
            config: OhMyPiAgentConfig(commandName: executable.path, additionalPathHints: [])
        )
        let launch = try provider.makeLaunchConfiguration(for: request(workspacePath: directory.path))

        XCTAssertEqual(launch.arguments, OhMyPiAgentConfig.managedArguments)
        XCTAssertEqual(launch.providerID, .ohMyPi)
        XCTAssertNotNil(launch.expectedExecutableIdentity)
    }

    func testResolverRequiresEveryManagedFlagAndMinimumCapturedVersion() async throws {
        let supportedDirectory = try makeTestDirectory(name: "OhMyPiACPProviderTests-supported")
        let supportedExecutable = try makeOMPExecutable(in: supportedDirectory)
        let supported = try await OhMyPiACPLaunchResolver().probeSupport(
            for: OhMyPiAgentConfig(commandName: supportedExecutable.path, additionalPathHints: [])
        )
        XCTAssertEqual(supported, .supported)

        let oldDirectory = try makeTestDirectory(name: "OhMyPiACPProviderTests-old")
        let oldExecutable = try makeOMPExecutable(in: oldDirectory, version: "17.2.11")
        guard case let .unsupported(oldReason) = try await OhMyPiACPLaunchResolver().probeSupport(
            for: OhMyPiAgentConfig(commandName: oldExecutable.path, additionalPathHints: [])
        ) else {
            return XCTFail("Expected old OMP version to fail closed")
        }
        XCTAssertTrue(oldReason.contains("17.2.12"), oldReason)

        let incompleteDirectory = try makeTestDirectory(name: "OhMyPiACPProviderTests-incomplete")
        let incompleteExecutable = try makeOMPExecutable(
            in: incompleteDirectory,
            rootHelpFlags: ["--no-tools", "--no-extensions", "--no-skills", "--approval-mode"]
        )
        guard case let .unsupported(flagReason) = try await OhMyPiACPLaunchResolver().probeSupport(
            for: OhMyPiAgentConfig(commandName: incompleteExecutable.path, additionalPathHints: [])
        ) else {
            return XCTFail("Expected missing managed flag to fail closed")
        }
        XCTAssertTrue(flagReason.contains("--no-rules"), flagReason)

        let missingACPDirectory = try makeTestDirectory(name: "OhMyPiACPProviderTests-missing-acp")
        let missingACPExecutable = try makeOMPExecutable(
            in: missingACPDirectory,
            acpHelpExitStatus: 2
        )
        guard case let .unsupported(acpReason) = try await OhMyPiACPLaunchResolver().probeSupport(
            for: OhMyPiAgentConfig(commandName: missingACPExecutable.path, additionalPathHints: [])
        ) else {
            return XCTFail("Expected missing ACP subcommand to fail closed")
        }
        XCTAssertTrue(acpReason.localizedCaseInsensitiveContains("acp"), acpReason)
    }

    func testVersionParserAcceptsObservedOutput() {
        XCTAssertEqual(OhMyPiACPLaunchResolver.parseVersion("omp/17.2.12"), [17, 2, 12])
        XCTAssertNil(OhMyPiACPLaunchResolver.parseVersion("omp unknown"))
    }

    func testSessionConfigurationAlwaysStartsFreshWithExactlyOneRepoPromptServer() throws {
        let provider = OhMyPiACPAgentProvider(config: OhMyPiAgentConfig())
        let fresh = try provider.makeSessionConfiguration(
            for: request(resumeSessionID: nil),
            mcpServer: .repoPrompt
        )
        let attemptedResume = try provider.makeSessionConfiguration(
            for: request(resumeSessionID: "candidate-session"),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(fresh.mode, .new)
        XCTAssertEqual(attemptedResume.mode, .new)
        XCTAssertEqual(fresh.mcpServers.count, 1)
        XCTAssertEqual(attemptedResume.mcpServers.count, 1)

        let discoveryProvider = OhMyPiACPAgentProvider(
            config: OhMyPiAgentConfig(includeRepoPromptMCPServer: false)
        )
        let discovery = try discoveryProvider.makeSessionConfiguration(
            for: request(),
            mcpServer: .repoPrompt
        )
        XCTAssertEqual(discovery.mode, .new)
        XCTAssertTrue(discovery.mcpServers.isEmpty)
    }

    func testPromptCombinesSystemUserAndImageWithoutThinkingMutation() throws {
        let provider = OhMyPiACPAgentProvider(config: OhMyPiAgentConfig())
        let attachment = AgentImageAttachment(
            source: .url("https://example.com/reference.png"),
            title: "reference.png"
        )
        let blocks = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "System context", userMessage: "User task"),
            request: request(attachments: [attachment], resumeSessionID: "ignored")
        )

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "System context\n\nUser task")
        XCTAssertEqual(blocks[1]["type"] as? String, "image")
        XCTAssertEqual(blocks[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(blocks[1]["uri"] as? String, "https://example.com/reference.png")
    }

    func testThinNormalizerHandlesRepresentativeStandardACPShape() throws {
        let payload = try fixtureJSONObject(named: "agent_message_chunk")
        let events = OhMyPiACPEventNormalizer.normalize(payload)
        guard case let .stream(result) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected normalized stream event")
        }
        XCTAssertEqual(result.type, "content")
        XCTAssertEqual(result.text, "OMP reply")
        XCTAssertEqual(result.contentMessageID, "omp-standard-message-1")
    }

    func testObservedInitializeFixtureRecordsIdentityWithoutEnablingResume() throws {
        let payload = try fixtureJSONObject(named: "initialize")
        let agentInfo = try XCTUnwrap(payload["agentInfo"] as? [String: Any])
        XCTAssertEqual(agentInfo["name"] as? String, "oh-my-pi")
        XCTAssertEqual(agentInfo["title"] as? String, "Oh My Pi")
        XCTAssertEqual(agentInfo["version"] as? String, "17.2.12")
        let capabilities = try XCTUnwrap(payload["agentCapabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["loadSession"] as? Bool, true)

        let provider = OhMyPiACPAgentProvider(config: OhMyPiAgentConfig())
        XCTAssertEqual(
            try provider.makeSessionConfiguration(
                for: request(resumeSessionID: "advertised-only"),
                mcpServer: .repoPrompt
            ).mode,
            .new
        )
    }

    func testDynamicCatalogUsesDefaultSentinelAndPreservesRawModels() {
        let discovered = ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: "openrouter/model:free",
                    displayName: "Model Free",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: false
                ),
                AgentModelOption(
                    rawValue: "cursor-pro/model",
                    displayName: "Cursor Pro Model",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: "cursor-pro/model"
        )
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .ohMyPi))

        let options = AgentModelCatalog.options(
            for: .ohMyPi,
            availability: .init(ohMyPiAvailable: true)
        )
        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertEqual(options.dropFirst().map(\.rawValue), ["cursor-pro/model", "openrouter/model:free"])

        let menu = AgentModelCatalog.openCodeMenu(for: options, providerID: .ohMyPi)
        let menuRaws = menu.providerGroups.flatMap(\.groups).flatMap(\.options).map(\.option.rawValue)
        XCTAssertEqual(Set(menuRaws), Set(options.map(\.rawValue)))

        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: "ohMyPi",
            modelRaw: "openrouter/model:free",
            availability: .init(ohMyPiAvailable: true)
        )
        XCTAssertEqual(normalized.agent, .ohMyPi)
        XCTAssertEqual(normalized.modelRaw, "openrouter/model:free")

        let availability = AgentModelCatalog.AvailabilityContext(ohMyPiAvailable: true)
        XCTAssertEqual(
            AgentModelCatalog.defaultModelRaw(for: .ohMyPi, availability: availability),
            AgentModel.defaultModel.rawValue
        )
        XCTAssertTrue(
            AgentModelCatalog.isValid(
                rawModel: AgentModel.defaultModel.rawValue,
                for: .ohMyPi,
                availability: availability
            )
        )
        let sentinelID = AgentModelSelectionID(
            agentRaw: AgentProviderKind.ohMyPi.rawValue,
            modelRaw: AgentModel.defaultModel.rawValue
        )
        XCTAssertEqual(
            AgentModelCatalog.resolveSelectionID(sentinelID.rawValue, availability: availability)?.modelRaw,
            AgentModel.defaultModel.rawValue
        )

        let adversarialRaws = [
            "provider/high",
            "provider/low",
            "openrouter/model:free",
            "model-without-provider"
        ]
        let adversarialOptions = adversarialRaws.map { raw in
            AgentModelOption(
                rawValue: raw,
                displayName: raw,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false
            )
        }
        let adversarialMenu = AgentModelCatalog.openCodeMenu(
            for: adversarialOptions,
            providerID: .ohMyPi
        )
        let roundTrippedRaws = adversarialMenu.providerGroups
            .flatMap(\.groups)
            .flatMap(\.options)
            .map(\.option.rawValue)
        XCTAssertEqual(Set(roundTrippedRaws), Set(adversarialRaws))

        let opaqueGroups = adversarialMenu.groups
        XCTAssertEqual(opaqueGroups.count, adversarialRaws.count)
        XCTAssertTrue(opaqueGroups.allSatisfy { !$0.rendersAsSubmenu })
        XCTAssertTrue(
            opaqueGroups
                .flatMap(\.options)
                .allSatisfy { $0.variantDisplayName == nil && $0.isBaseOption }
        )
        XCTAssertEqual(
            opaqueGroups.first { $0.options.first?.option.rawValue == "provider/high" }?.modelDisplayName,
            "high"
        )
        XCTAssertEqual(
            opaqueGroups.first { $0.options.first?.option.rawValue == "provider/low" }?.modelDisplayName,
            "low"
        )
        XCTAssertEqual(
            opaqueGroups.first { $0.options.first?.option.rawValue == "openrouter/model:free" }?.modelDisplayName,
            "model:free"
        )
        XCTAssertEqual(
            opaqueGroups.first { $0.options.first?.option.rawValue == "model-without-provider" }?.displayName,
            "model-without-provider"
        )

        AgentACPModelRegistry.shared.reset(providerID: .ohMyPi)
        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi))
    }

    @MainActor
    func testPermissionBindingMCPGrantAndDarkAvailability() throws {
        XCTAssertEqual(AgentProviderKind.ohMyPi.providerBindingID, .ohMyPi)
        XCTAssertEqual(
            AgentProviderPermissionLevelID.subagentDefault(for: .ohMyPi),
            .ohMyPi(.managedBarebones)
        )
        XCTAssertEqual(
            AgentModeMCPToolPolicy.grantedTools(forAgent: .ohMyPi),
            AgentModeMCPToolPolicy.ohMyPiGrantedTools
        )

        let suiteName = "OhMyPiACPProviderTests-permissions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let binding = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            .runtimePermission(for: .ohMyPi, profile: .userConfigured)
        XCTAssertNil(binding.acpSessionModeID)
        XCTAssertFalse(binding.autoApproveAllACPToolPermissions)
        XCTAssertFalse(AgentModelCatalog.AvailabilityContext.current.ohMyPiAvailable)
        XCTAssertFalse(AgentModelCatalog.selectableAgents().contains(.ohMyPi))
        XCTAssertFalse(AgentModelCatalog.supportedCLIProviderAgents.contains(.ohMyPi))
        XCTAssertTrue(AgentProviderKind.allCases.contains(.ohMyPi))
        XCTAssertFalse(AgentProviderKind.publicContextBuilderCases.contains(.ohMyPi))
        XCTAssertTrue(AgentProviderBindingID.allCases.contains(.ohMyPi))
        XCTAssertFalse(AgentProviderBindingID.publicSettingsCases.contains(.ohMyPi))

        XCTAssertFalse(
            AgentModelCatalog.discoveryAgents().contains { $0.agent == .ohMyPi }
        )
        let onlyOhMyPi = AgentModelCatalog.AvailabilityContext(ohMyPiAvailable: true)
        for kind in AgentModelCatalog.TaskLabelKind.allCases {
            XCTAssertNotEqual(
                AgentModelCatalog.resolveTaskLabelKind(kind, availability: onlyOhMyPi)?.agent,
                .ohMyPi
            )
        }
    }

    func testRepoPromptScopedAutoApprovalRecognizesOnlyStrictEvidence() {
        let prefixedKnownTool = ACPAgentSessionController.repoPromptScopedAutoApprovalMatch(
            providerID: .ohMyPi,
            requestToolName: "mcp__RepoPromptCE__read_file",
            requestPayload: ["title": "mcp__RepoPromptCE__read_file"]
        )
        XCTAssertNotNil(prefixedKnownTool)

        let exactServerUnknownTool = ACPAgentSessionController.repoPromptScopedAutoApprovalMatch(
            providerID: .ohMyPi,
            requestToolName: "future_repo_prompt_tool",
            requestPayload: ["server_name": MCPIntegrationHelper.repoPromptMCPServerName]
        )
        XCTAssertNotNil(exactServerUnknownTool)

        let spoofedServer = ACPAgentSessionController.repoPromptScopedAutoApprovalMatch(
            providerID: .ohMyPi,
            requestToolName: "bash",
            requestPayload: ["server_name": "not-RepoPromptCE"]
        )
        XCTAssertNil(spoofedServer)

        let unknown = ACPAgentSessionController.repoPromptScopedAutoApprovalMatch(
            providerID: .ohMyPi,
            requestToolName: "bash",
            requestPayload: ["rawInput": ["command": "echo unsafe"]]
        )
        XCTAssertNil(unknown)
    }

    func testHeadlessRequestDiscardsResumeCandidateAndRequiresRegistryModel() async {
        var ordering: [String] = []
        do {
            try await ACPHeadlessAgentProviderBridge.performPromptAfterBarrier(
                beforePrompt: { ordering.append("routing") },
                sendPrompt: { ordering.append("prompt") }
            )
        } catch {
            XCTFail("Expected routing barrier success: \(error)")
        }
        XCTAssertEqual(ordering, ["routing", "prompt"])

        ordering = []
        do {
            try await ACPHeadlessAgentProviderBridge.performPromptAfterBarrier(
                beforePrompt: {
                    ordering.append("routing")
                    throw CocoaError(.fileNoSuchFile)
                },
                sendPrompt: { ordering.append("prompt") }
            )
            XCTFail("Expected routing barrier failure")
        } catch {}
        XCTAssertEqual(ordering, ["routing"])

        let config = OhMyPiAgentConfig(modelString: "openrouter/model")
        let request = OhMyPiACPHeadlessAgentProvider.makeRunRequest(
            config: config,
            workspacePath: "/tmp/workspace",
            message: AgentMessage(userMessage: "handoff", resumeSessionID: "candidate")
        )
        XCTAssertNil(request.resumeSessionID)

        XCTAssertNil(OhMyPiACPHeadlessAgentProvider.selectedModelToApply(config: config))
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "openrouter/model",
                        displayName: "Model",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "openrouter/model"
            ),
            for: .ohMyPi
        )
        XCTAssertEqual(OhMyPiACPHeadlessAgentProvider.selectedModelToApply(config: config), "openrouter/model")
    }

    func testDynamicStoreSerializesCrossProviderTransactions() throws {
        let suiteName = "OhMyPiACPProviderTests-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let providers: [ACPProviderID] = [.openCode, .cursor, .ohMyPi]
        DispatchQueue.concurrentPerform(iterations: 90) { index in
            let providerID = providers[index % providers.count]
            ACPDynamicModelStore.save(
                Self.dynamicSnapshot(raw: "\(providerID.rawValue)/model-\(index)"),
                for: providerID,
                defaults: defaults
            )
        }

        let concurrentlySaved = ACPDynamicModelStore.loadAll(defaults: defaults)
        XCTAssertEqual(Set(concurrentlySaved.keys), Set(providers))

        DispatchQueue.concurrentPerform(iterations: 61) { index in
            if index == 0 {
                ACPDynamicModelStore.remove(providerID: .ohMyPi, defaults: defaults)
            } else {
                let providerID: ACPProviderID = index.isMultiple(of: 2) ? .openCode : .cursor
                ACPDynamicModelStore.save(
                    Self.dynamicSnapshot(raw: "\(providerID.rawValue)/reset-race-\(index)"),
                    for: providerID,
                    defaults: defaults
                )
            }
        }

        let afterResetRace = ACPDynamicModelStore.loadAll(defaults: defaults)
        XCTAssertNil(afterResetRace[.ohMyPi])
        XCTAssertNotNil(afterResetRace[.openCode])
        XCTAssertNotNil(afterResetRace[.cursor])
    }

    func testModelPollingCoalescesAndResetDropsStaleDiscovery() async throws {
        let client = ControlledOhMyPiModelDiscoveryClient()
        let service = OhMyPiACPModelPollingService(
            client: client,
            intervalNanos: 60_000_000_000
        )
        let initial = Self.dynamicSnapshot(raw: "provider/initial")
        let replacement = Self.dynamicSnapshot(raw: "provider/stale")

        let discoverTask = Task {
            try await service.discoverOnce(workspacePath: "/tmp/workspace")
        }
        let refreshTask = Task {
            await service.refreshNow(workspacePath: "/tmp/workspace")
        }
        await client.waitForCallCount(1)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let coalescedCallCount = await client.observedCallCount()
        XCTAssertEqual(coalescedCallCount, 1)
        await client.complete(call: 0, with: initial)
        let discovered = try await discoverTask.value
        let refreshed = await refreshTask.value
        XCTAssertEqual(discovered?.models, initial)
        XCTAssertTrue(refreshed)

        let recorder = OhMyPiPollingSnapshotRecorder()
        let stream = await service.subscribe(workspacePath: "/tmp/workspace")
        let observationTask = Task {
            for await snapshot in stream {
                await recorder.record(snapshot)
            }
        }
        await client.waitForCallCount(2)

        await service.reset()
        await client.complete(call: 1, with: replacement)
        await observationTask.value

        let observedModels = await recorder.observedModels()
        let latestAfterReset = await service.latestSnapshot()
        XCTAssertEqual(observedModels, [initial])
        XCTAssertNil(latestAfterReset)
        XCTAssertNil(AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi))
        await service.shutdown()
    }

    private static func dynamicSnapshot(raw: String) -> ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: raw,
                    displayName: raw,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: raw
        )
    }

    private func request(
        workspacePath: String? = nil,
        attachments: [AgentImageAttachment] = [],
        resumeSessionID: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: attachments,
            taskLabelKind: nil
        )
    }

    private func fixtureJSONObject(named name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OhMyPiACP/\(name).json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    private func makeOMPExecutable(
        in directory: URL,
        version: String = "17.2.12",
        rootHelpFlags: [String] = OhMyPiAgentConfig.requiredManagedFlags,
        acpHelpExitStatus: Int = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent("omp")
        let rootHelp = rootHelpFlags.joined(separator: " ")
        let script = """
        #!/bin/sh
        if [ "$1" = "acp" ] && [ "$2" = "--help" ]; then
          printf '%s\\n' 'Usage: omp acp [options]'
          exit \(acpHelpExitStatus)
        fi
        if [ "$1" = "--help" ]; then
          printf '%s\\n' '\(rootHelp)'
          exit 0
        fi
        if [ "$1" = "--version" ]; then
          printf '%s\\n' 'omp/\(version)'
          exit 0
        fi
        exit 2
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private actor ControlledOhMyPiModelDiscoveryClient: OhMyPiACPModelDiscoveryClient {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<ACPDiscoveredSessionModels?, any Error>] = [:]
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        let call = callCount
        callCount += 1
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func observedCallCount() -> Int {
        callCount
    }

    func complete(call: Int, with snapshot: ACPDiscoveredSessionModels?) {
        pending.removeValue(forKey: call)?.resume(returning: snapshot)
    }

    private func resumeSatisfiedWaiters() {
        let ready = callWaiters.filter { callCount >= $0.target }
        callWaiters.removeAll { callCount >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor OhMyPiPollingSnapshotRecorder {
    private var models: [ACPDiscoveredSessionModels] = []

    func record(_ snapshot: OhMyPiACPModelPollingService.Snapshot) {
        models.append(snapshot.models)
    }

    func observedModels() -> [ACPDiscoveredSessionModels] {
        models
    }
}
