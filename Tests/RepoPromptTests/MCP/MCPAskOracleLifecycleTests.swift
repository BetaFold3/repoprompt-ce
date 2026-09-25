import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Oracle resumable wait plan §5 `MCPAskOracleLifecycleTests`: bounded single send, pending
/// stub shape and byte ceiling, `wait_policy` per mode, `op:"wait"` envelopes, `op:"cancel"`
/// phases and the query-match rule, `request_id` dedup, Step C bounded batch scheduling,
/// late-reservation safety, and steering wake through the real `MCPServerViewModel` registry.
///
/// The Oracle stream engine is real; only the provider transport is stubbed after packaging.
@MainActor
final class MCPAskOracleLifecycleTests: XCTestCase {
    // MARK: - Transport harness

    @MainActor
    private final class TransportHarness {
        private var continuations: [AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = []
        private(set) var openedStreamCount = 0

        func makeStream(
            message _: AIMessage,
            for _: AIModel
        ) -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>) {
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuations.append(continuation)
                openedStreamCount += 1
            }
            return (UUID(), stream)
        }

        func waitUntilOpen(count: Int) async throws {
            try await AsyncTestWait.waitUntil("Oracle streams opened (\(count))", timeout: 5) {
                await MainActor.run { self.openedStreamCount >= count }
            }
        }

        func finish(index: Int, text: String) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(ChatStreamOutput(
                text: text,
                reasoning: nil,
                tokens: ChatTokenInfo(promptTokens: 12, completionTokens: 3, cost: 0),
                isFinal: true
            ))
            continuations[index].finish()
        }

        func yield(index: Int, text: String) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(ChatStreamOutput(text: text, reasoning: nil, tokens: ChatTokenInfo(), isFinal: false))
        }

        func yieldReasoning(index: Int, reasoning: String) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(ChatStreamOutput(text: "", reasoning: reasoning, tokens: ChatTokenInfo(), isFinal: false))
        }

        func fail(index: Int, error: Error) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].finish(throwing: error)
        }

        func finishAll() {
            for continuation in continuations {
                continuation.finish()
            }
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let window: WindowState
        let tabID: UUID
        let connectionID: UUID
        let runID: UUID
        let model: AIModel
        let preset: ModelPreset
        let harness: TransportHarness
        private let previousPresets: [ModelPreset]
        private let previousShowPresets: Bool
        private let previousTemporaryDisable: Bool
        private let previousCustomProviderValidity: Bool
        private let storageRoot: URL
        private var didCleanup = false

        private init(
            window: WindowState,
            tabID: UUID,
            connectionID: UUID,
            runID: UUID,
            model: AIModel,
            preset: ModelPreset,
            harness: TransportHarness,
            previousPresets: [ModelPreset],
            previousShowPresets: Bool,
            previousTemporaryDisable: Bool,
            previousCustomProviderValidity: Bool,
            storageRoot: URL
        ) {
            self.window = window
            self.tabID = tabID
            self.connectionID = connectionID
            self.runID = runID
            self.model = model
            self.preset = preset
            self.harness = harness
            self.previousPresets = previousPresets
            self.previousShowPresets = previousShowPresets
            self.previousTemporaryDisable = previousTemporaryDisable
            self.previousCustomProviderValidity = previousCustomProviderValidity
            self.storageRoot = storageRoot
        }

        static func make(name: String) async throws -> Fixture {
            let settings = GlobalSettingsStore.shared
            let presetsManager = ModelPresetsManager.shared
            let previousPresets = presetsManager.presets
            let previousShowPresets = settings.mcpShowModelPresets()
            let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()

            let previousAutoStart = settings.mcpAutoStart()
            settings.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            settings.setMCPAutoStart(previousAutoStart, commit: false)
            do {
                try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))
            } catch {
                WindowStatesManager.shared.unregisterWindowState(window)
                throw error
            }

            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPAskOracleLifecycleTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let tabID = UUID()
            workspace.customStoragePath = storageRoot
            // A primary root lets the frozen export destination resolve (plan §3.5); exports
            // themselves are intercepted by the export override in the tests that need them.
            workspace.repoPaths = [storageRoot.path]
            workspace.composeTabs = [ComposeTabState(id: tabID)]
            workspace.activeComposeTabID = tabID
            if let index = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                window.workspaceManager.workspaces[index] = workspace
            }
            window.workspaceManager.activeWorkspace = workspace
            window.promptManager.loadComposeTabsFromWorkspace(workspace)
            await window.oracleViewModel.loadSessionsFromWorkspace()
            window.oracleViewModel.sessions = []

            let model = AIModel.customProviderUser(name: "lifecycle-\(name)")
            let preset = ModelPreset(
                name: "Lifecycle_\(name)",
                model: model,
                supportedModes: SupportedModes(chat: true, plan: true, review: true)
            )
            presetsManager.presets = [preset]
            settings.setMCPShowModelPresets(true, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            let previousCustomProviderValidity = window.apiSettingsViewModel.isCustomProviderValid
            window.apiSettingsViewModel.isCustomProviderValid = true
            let harness = TransportHarness()
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, selectedModel in
                harness.makeStream(message: message, for: selectedModel)
            }
            let connectionID = UUID()
            let runID = UUID()
            guard window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: window.windowID
            ) else {
                WindowStatesManager.shared.unregisterWindowState(window)
                throw LifecycleTestError.runMappingFailed
            }
            return Fixture(
                window: window,
                tabID: tabID,
                connectionID: connectionID,
                runID: runID,
                model: model,
                preset: preset,
                harness: harness,
                previousPresets: previousPresets,
                previousShowPresets: previousShowPresets,
                previousTemporaryDisable: previousTemporaryDisable,
                previousCustomProviderValidity: previousCustomProviderValidity,
                storageRoot: storageRoot
            )
        }

        var store: OracleMCPOperationStore {
            window.oracleViewModel.mcpOperationStore
        }

        var metadata: MCPServerViewModel.RequestMetadata {
            MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "ask-oracle-lifecycle-tests",
                windowID: window.windowID
            )
        }

        func ask(_ extra: [String: Value] = [:], message: String = "Lifecycle question") async throws -> [String: Value] {
            var args: [String: Value] = [
                "message": .string(message),
                "mode": .string("chat"),
                "model": .string(preset.id.uuidString),
                "new_chat": .bool(true)
            ]
            args.merge(extra) { _, new in new }
            let value = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await window.mcpServer.executeAskOracleForTesting(args: args)
            }
            return try XCTUnwrap(value.objectValue)
        }

        func call(_ args: [String: Value]) async throws -> [String: Value] {
            let value = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await window.mcpServer.executeAskOracleForTesting(args: args)
            }
            return try XCTUnwrap(value.objectValue)
        }

        @discardableResult
        func activateAgentRunForBatch(
            sessionID: UUID? = nil,
            activeRunID: UUID? = nil,
            selectedAgent: AgentProviderKind? = nil,
            promptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention = .standard
        ) throws -> UUID {
            let sessionID = sessionID ?? runID
            let activeRunID = activeRunID ?? runID
            let session = try XCTUnwrap(window.agentModeViewModel.session(for: tabID, createIfNeeded: true))
            guard window.agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: session,
                updateWorkspaceMetadata: true
            ) != nil else {
                throw LifecycleTestError.runMappingFailed
            }
            if let selectedAgent {
                session.selectedAgent = selectedAgent
            }
            session.claudePromptCacheRetention = promptCacheRetention
            session.runID = activeRunID
            session.runState = .running
            window.agentModeViewModel.setAgentRunActive(tabID, isActive: true)
            return sessionID
        }

        func legacySend(message: String) async throws -> [String: Value] {
            let value = try await window.mcpServer.executeOracleSendForTesting(args: [
                "message": .string(message),
                "mode": .string("chat"),
                "model": .string(preset.id.uuidString),
                "new_chat": .bool(true)
            ])
            return try XCTUnwrap(value.objectValue)
        }

        func chatUUID(shortID: String) throws -> UUID {
            try XCTUnwrap(window.oracleViewModel.resolveSession(id: shortID)?.id)
        }

        func waitUntilParked(count: Int = 1) async throws {
            let store = store
            try await AsyncTestWait.waitUntil("ask_oracle waiter parked", timeout: 5) {
                await MainActor.run { store.test_waiterCount() >= count }
            }
        }

        func waitUntilTerminal(_ operationID: UUID) async throws {
            let store = store
            try await AsyncTestWait.waitUntil("operation terminal", timeout: 5) {
                await MainActor.run { store.snapshot(operationID)?.phase.isTerminal == true }
            }
        }

        func cleanup() async {
            guard !didCleanup else { return }
            didCleanup = true
            harness.finishAll()
            window.mcpServer.setOracleExportOverrideForTesting(nil)
            window.mcpServer.setOracleCancelOverrideForTesting(nil)
            window.mcpServer.setOracleChatSendOverrideForTesting(nil)
            window.mcpServer.setBeforeAskOraclePreparationForTesting(nil)
            window.mcpServer.setOraclePostBindObserverForTesting(nil)
            window.oracleViewModel.setOracleRequestPreparedObserverForTesting(nil)
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            window.oracleViewModel.mcpOperationStore.teardown()
            await window.oracleViewModel.cancelAllActiveSessionStreams()
            if let session = window.agentModeViewModel.session(for: tabID, createIfNeeded: false),
               let sessionID = session.activeAgentSessionID,
               session.mcpControlContext != nil
            {
                await window.agentModeViewModel.mcpDeactivateControlContext(
                    sessionID: sessionID,
                    cleanupSessionStore: true
                )
            }
            window.oracleViewModel.sessions = []
            window.agentModeViewModel.setAgentRunActive(tabID, isActive: false)
            window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: connectionID)
            let settings = GlobalSettingsStore.shared
            ModelPresetsManager.shared.presets = previousPresets
            settings.setMCPShowModelPresets(previousShowPresets, commit: false)
            settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
            window.apiSettingsViewModel.isCustomProviderValid = previousCustomProviderValidity
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    private enum LifecycleTestError: Error {
        case runMappingFailed
        case exportFailed
    }

    @MainActor
    private final class ExportCounter {
        var count = 0
    }

    @MainActor
    private final class AskResultBox {
        var result: Result<[String: Value], Error>?
    }

    private func withFixture(
        _ name: String = #function,
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture.make(name: name.replacingOccurrences(of: "()", with: ""))
        do {
            try await body(fixture)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    private func operationID(in result: [String: Value]) throws -> UUID {
        try XCTUnwrap(result["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    private func lanes(in envelope: [String: Value]) throws -> [[String: Value]] {
        try XCTUnwrap(envelope["results"]?.arrayValue).compactMap(\.objectValue)
    }

    private func encodedByteCount(_ object: [String: Value]) throws -> Int {
        try JSONEncoder().encode(Value.object(object)).count
    }

    private func batchConsultations(
        fixture: Fixture,
        count: Int,
        responseModeForLast: String? = nil
    ) -> Value {
        .array((0 ..< count).map { index in
            var lane: [String: Value] = [
                "message": .string("Batch lane \(index)"),
                "model": .string(fixture.preset.id.uuidString),
                "mode": .string("chat"),
                "chat_name": .string("Batch \(index)")
            ]
            if index == count - 1, let responseModeForLast {
                lane["response_mode"] = .string(responseModeForLast)
            }
            return .object(lane)
        })
    }

    // MARK: - Validation before any send

    func testInvalidTimeoutOpAndWaitCancelArgsAreRejectedBeforeAnySend() async throws {
        try await withFixture { fixture in
            let rejectedSends: [[String: Value]] = [
                ["timeout_seconds": .int(14401)],
                ["timeout_seconds": .int(-1)],
                ["timeout_seconds": .bool(true)],
                ["op": .string("bogus")],
                ["op": .int(1)],
                ["request_id": .string("not-a-uuid")]
            ]
            for extra in rejectedSends {
                do {
                    _ = try await fixture.ask(extra)
                    XCTFail("expected rejection for \(extra)")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
            }

            let rejectedControl: [[String: Value]] = [
                ["op": .string("wait"), "message": .string("resend?")],
                ["op": .string("wait"), "response_mode": .string("tail")],
                ["op": .string("wait"), "operation_ids": .array([])],
                ["op": .string("wait"), "operation_ids": .array(Array(repeating: .string(UUID().uuidString), count: 17))],
                ["op": .string("wait"), "operation_ids": .array([.string("nope")])],
                ["op": .string("cancel")],
                ["op": .string("cancel"), "operation_ids": .array([.string(UUID().uuidString)]), "export_response": .bool(true)],
                ["op": .string("cancel"), "operation_ids": .array([.string(UUID().uuidString), .string(UUID().uuidString)]), "timeout_seconds": .int(1)]
            ]
            for args in rejectedControl {
                do {
                    _ = try await fixture.call(args)
                    XCTFail("expected rejection for \(args)")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
            }
            let duplicate = UUID().uuidString
            do {
                _ = try await fixture.call([
                    "op": .string("cancel"),
                    "operation_ids": .array([.string(duplicate), .string(duplicate)])
                ])
                XCTFail("duplicate operation_ids must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("distinct"), error.localizedDescription)
            }

            XCTAssertEqual(fixture.harness.openedStreamCount, 0, "validation failures never reach the Oracle")
            XCTAssertEqual(fixture.store.test_recordCount(), 0)
        }
    }

    // MARK: - Pending stub, wait, cached replay

    func testPollSendReturnsPendingStubUnderCeilingAndWaitDeliversExactlyOnce() async throws {
        try await withFixture { fixture in
            let requestID = UUID().uuidString
            let pendingArgs: [String: Value] = [
                "timeout_seconds": .int(0),
                "request_id": .string(requestID)
            ]
            let pending = try await fixture.ask(pendingArgs)
            XCTAssertEqual(pending["status"]?.stringValue, "pending")
            XCTAssertNil(pending["response"], "a pending result never carries a response")
            XCTAssertNotNil(pending["chat_id"])
            XCTAssertNotNil(pending["query_id"])
            XCTAssertEqual(pending["mode"]?.stringValue, "chat")
            XCTAssertEqual(pending["model_preset_name"]?.stringValue, fixture.preset.name)
            XCTAssertNil(pending["model_id"], "preset identity is redacted at the MCP boundary")
            XCTAssertNil(pending["ui_model_id"])
            let pendingInfo = try XCTUnwrap(pending["pending"]?.objectValue)
            XCTAssertEqual(pendingInfo["reason"]?.stringValue, "polled")
            XCTAssertEqual(pendingInfo["stream_state"]?.stringValue, "streaming")
            XCTAssertNotNil(pendingInfo["elapsed_seconds"]?.intValue)
            let initialProgress = try XCTUnwrap(pendingInfo["progress"]?.objectValue)
            XCTAssertEqual(initialProgress["output_chars"]?.intValue, 0)
            XCTAssertNil(initialProgress["last_activity_seconds_ago"], "activity age is omitted until stream activity is observed")
            XCTAssertNil(initialProgress["queue_position"], "single sends are never queued")
            XCTAssertEqual(Set(initialProgress.keys), ["output_chars"], "progress never leaks text or extra stream state")
            XCTAssertEqual(pending["note"]?.stringValue, MCPOracleToolService.pendingNote)
            XCTAssertNil(pending["_meta"], "wake_reason is present only for a steering wake")
            let operationID = try operationID(in: pending)
            XCTAssertEqual(
                pending["resume"]?.objectValue?["operation_ids"]?.arrayValue?.first?.stringValue,
                operationID.uuidString
            )
            XCTAssertEqual(pending["resume"]?.objectValue?["op"]?.stringValue, "wait")
            let waitPolicy = try XCTUnwrap(pending["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicy["mode"]?.stringValue, "poll")
            XCTAssertEqual(waitPolicy["timeout_seconds"]?.intValue, 0)
            XCTAssertNil(waitPolicy["parent_family"])
            XCTAssertLessThanOrEqual(
                try encodedByteCount(pending),
                MCPOracleToolService.pendingStubByteCeiling,
                "pending stub exceeded the byte ceiling"
            )

            try await fixture.harness.waitUntilOpen(count: 1)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)
            let chatID = try fixture.chatUUID(shortID: XCTUnwrap(pending["chat_id"]?.stringValue))
            XCTAssertEqual(fixture.window.oracleViewModel.oracleSessionPinCountForTesting(chatID), 1, "the operation owns the ticket pin")
            XCTAssertEqual(fixture.window.oracleViewModel.mcpActiveOracleStreamCount(forTabID: fixture.tabID), 1, "pending operations still occupy the two-stream cap")

            let queryID = try XCTUnwrap(pending["query_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let reasoningText = "Private reasoning must stay private"
            fixture.harness.yieldReasoning(index: 0, reasoning: reasoningText)
            try await AsyncTestWait.waitUntil("Oracle progress snapshot observes reasoning-only activity", timeout: 2) {
                await MainActor.run {
                    guard let snapshot = fixture.window.oracleViewModel.oracleMCPProgressSnapshot(for: queryID) else {
                        return false
                    }
                    return snapshot.outputChars == 0 && snapshot.lastActivityAt != nil
                }
            }
            let reasoningOnly = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let reasoningLane = try XCTUnwrap(try lanes(in: reasoningOnly).first)
            let reasoningProgress = try XCTUnwrap(
                reasoningLane["pending"]?.objectValue?["progress"]?.objectValue
            )
            XCTAssertEqual(reasoningProgress["output_chars"]?.intValue, 0)
            XCTAssertNotNil(reasoningProgress["last_activity_seconds_ago"]?.intValue)
            XCTAssertNil(reasoningProgress["queue_position"])
            XCTAssertEqual(Set(reasoningProgress.keys), ["output_chars", "last_activity_seconds_ago"])
            XCTAssertFalse(
                ToolOutputFormatter.rawJSONString(.object(reasoningOnly)).contains(reasoningText),
                "reasoning-only activity must never expose reasoning text"
            )

            let partialText = "Partial 🔒 output"
            let phaseRevisionBeforeProgress = fixture.store.phaseRevision
            fixture.harness.yield(index: 0, text: partialText)
            try await AsyncTestWait.waitUntil("Oracle progress snapshot observes streamed output", timeout: 2) {
                await MainActor.run {
                    fixture.window.oracleViewModel.oracleMCPProgressSnapshot(for: queryID)?.outputChars
                        == partialText.count
                }
            }
            XCTAssertEqual(
                fixture.store.phaseRevision,
                phaseRevisionBeforeProgress,
                "stream deltas do not publish operation-store phase revisions"
            )

            let polled = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            XCTAssertEqual(polled["wait"]?.objectValue?["result"]?.stringValue, "polled")
            let polledLane = try XCTUnwrap(try lanes(in: polled).first)
            XCTAssertEqual(polledLane["status"]?.stringValue, "pending")
            XCTAssertNil(polledLane["wait_policy"], "lanes never carry their own wait_policy")
            XCTAssertNil(polledLane["resume"])
            let sampledProgress = try XCTUnwrap(
                polledLane["pending"]?.objectValue?["progress"]?.objectValue
            )
            XCTAssertEqual(sampledProgress["output_chars"]?.intValue, partialText.count)
            XCTAssertNotNil(sampledProgress["last_activity_seconds_ago"]?.intValue)
            XCTAssertNil(sampledProgress["queue_position"])
            XCTAssertEqual(
                Set(sampledProgress.keys),
                ["output_chars", "last_activity_seconds_ago"],
                "advisory progress exposes counts only, never response text or reasoning"
            )
            XCTAssertFalse(
                ToolOutputFormatter.rawJSONString(.object(sampledProgress)).contains(partialText),
                "progress metadata must not contain streamed text"
            )
            XCTAssertEqual(polled["wait_policy"]?.objectValue?["mode"]?.stringValue, "poll")
            XCTAssertNotNil(polled["resume"])

            let progressedReplay = try await fixture.ask(pendingArgs)
            XCTAssertEqual(try self.operationID(in: progressedReplay), operationID)
            XCTAssertEqual(progressedReplay["status"]?.stringValue, "pending")
            XCTAssertEqual(progressedReplay["wait_policy"]?.objectValue?["mode"]?.stringValue, "poll")
            XCTAssertNotNil(progressedReplay["resume"])
            XCTAssertEqual(progressedReplay["note"]?.stringValue, MCPOracleToolService.pendingNote)
            let replayProgress = try XCTUnwrap(
                progressedReplay["pending"]?.objectValue?["progress"]?.objectValue
            )
            XCTAssertEqual(replayProgress["output_chars"]?.intValue, partialText.count)
            XCTAssertNotNil(replayProgress["last_activity_seconds_ago"]?.intValue)
            XCTAssertEqual(Set(replayProgress.keys), ["output_chars", "last_activity_seconds_ago"])
            let progressedReplayByteCount = try encodedByteCount(progressedReplay)
            XCTAssertLessThanOrEqual(
                progressedReplayByteCount,
                MCPOracleToolService.pendingStubByteCeiling,
                "progressed keyed single-result stub measured \(progressedReplayByteCount) bytes"
            )
            XCTAssertEqual(fixture.harness.openedStreamCount, 1, "keyed progress replay never resends")

            fixture.harness.finish(index: 0, text: "Final Oracle answer")
            let completed = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(completed["wait"]?.objectValue?["result"]?.stringValue, "completed")
            XCTAssertEqual(completed["wait"]?.objectValue?["pending_operation_ids"]?.arrayValue?.count, 0)
            XCTAssertNil(completed["resume"])
            XCTAssertNil(completed["_meta"])
            let waitPolicyAutomatic = try XCTUnwrap(completed["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicyAutomatic["mode"]?.stringValue, "automatic")
            XCTAssertEqual(waitPolicyAutomatic["timeout_seconds"]?.intValue, 180)
            XCTAssertEqual(waitPolicyAutomatic["parent_family"]?.stringValue, "unresolved")
            let lane = try XCTUnwrap(try lanes(in: completed).first)
            XCTAssertEqual(lane["status"]?.stringValue, "completed")
            XCTAssertEqual(lane["operation_id"]?.stringValue, operationID.uuidString)
            XCTAssertEqual(lane["response"]?.stringValue, partialText + "Final Oracle answer")
            XCTAssertEqual(lane["model_preset_name"]?.stringValue, fixture.preset.name)
            XCTAssertNil(lane["wait_policy"])
            XCTAssertEqual(fixture.window.oracleViewModel.oracleSessionPinCountForTesting(chatID), 0, "the observer released the pin exactly once")
            XCTAssertEqual(fixture.store.snapshot(operationID)?.delivery, .delivered)

            let replay = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(7)
            ])
            let replayLane = try XCTUnwrap(try lanes(in: replay).first)
            XCTAssertEqual(replayLane["response"]?.stringValue, partialText + "Final Oracle answer")
            XCTAssertEqual(replay["wait_policy"]?.objectValue?["mode"]?.stringValue, "explicit")
            XCTAssertEqual(replay["wait_policy"]?.objectValue?["timeout_seconds"]?.intValue, 7)
            XCTAssertEqual(fixture.harness.openedStreamCount, 1, "waits never resend")
        }
    }

    func testAutomaticSendCompletesInlineWithStatusOperationIDAndWaitPolicy() async throws {
        try await withFixture { fixture in
            let task = Task { @MainActor in try await fixture.ask() }
            try await fixture.harness.waitUntilOpen(count: 1)
            try await fixture.waitUntilParked()
            fixture.harness.finish(index: 0, text: "Inline answer")
            let result = try await task.value
            XCTAssertEqual(result["status"]?.stringValue, "completed")
            XCTAssertEqual(result["response"]?.stringValue, "Inline answer")
            XCTAssertNotNil(result["operation_id"])
            XCTAssertNil(result["pending"])
            XCTAssertNil(result["resume"])
            let waitPolicy = try XCTUnwrap(result["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicy["mode"]?.stringValue, "automatic")
            XCTAssertEqual(waitPolicy["timeout_seconds"]?.intValue, 180)
            XCTAssertEqual(waitPolicy["parent_family"]?.stringValue, "unresolved")
            XCTAssertNotNil(result["usage"]?.objectValue)
            let operationID = try operationID(in: result)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.delivery, .delivered)
        }
    }

    func testAutomaticSendUsesExtendedClaudeParentWaitPolicy() async throws {
        try await withFixture { fixture in
            _ = try fixture.activateAgentRunForBatch(
                selectedAgent: .claudeCode,
                promptCacheRetention: .extended
            )

            let task = Task { @MainActor in try await fixture.ask() }
            try await fixture.harness.waitUntilOpen(count: 1)
            try await fixture.waitUntilParked()
            fixture.harness.finish(index: 0, text: "Extended inline answer")

            let result = try await task.value
            let waitPolicy = try XCTUnwrap(result["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicy["mode"]?.stringValue, "automatic")
            XCTAssertEqual(waitPolicy["timeout_seconds"]?.intValue, 1500)
            XCTAssertEqual(waitPolicy["parent_family"]?.stringValue, "claude")
        }
    }

    func testAutomaticWaitUsesExtendedClaudeParentWaitPolicy() async throws {
        try await withFixture { fixture in
            _ = try fixture.activateAgentRunForBatch(
                selectedAgent: .claudeCode,
                promptCacheRetention: .extended
            )
            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)

            let waitTask = Task { @MainActor in
                try await fixture.call([
                    "op": .string("wait"),
                    "operation_ids": .array([.string(operationID.uuidString)])
                ])
            }
            try await fixture.waitUntilParked()
            fixture.harness.finish(index: 0, text: "Extended waited answer")

            let result = try await waitTask.value
            let waitPolicy = try XCTUnwrap(result["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicy["mode"]?.stringValue, "automatic")
            XCTAssertEqual(waitPolicy["timeout_seconds"]?.intValue, 1500)
            XCTAssertEqual(waitPolicy["parent_family"]?.stringValue, "claude")
        }
    }

    func testAutomaticBatchUsesExtendedClaudeParentWaitPolicy() async throws {
        try await withFixture { fixture in
            _ = try fixture.activateAgentRunForBatch(
                selectedAgent: .claudeCode,
                promptCacheRetention: .extended
            )
            let batchTask = Task { @MainActor in
                try await fixture.call([
                    "consultations": batchConsultations(fixture: fixture, count: 1)
                ])
            }
            try await fixture.harness.waitUntilOpen(count: 1)
            try await fixture.waitUntilParked()
            fixture.harness.finish(index: 0, text: "Extended batch answer")

            let result = try await batchTask.value
            let waitPolicy = try XCTUnwrap(result["wait_policy"]?.objectValue)
            XCTAssertEqual(waitPolicy["mode"]?.stringValue, "automatic")
            XCTAssertEqual(waitPolicy["timeout_seconds"]?.intValue, 1500)
            XCTAssertEqual(waitPolicy["parent_family"]?.stringValue, "claude")
        }
    }

    func testExplicitTimeoutReturnsTimedOutPendingAndLeavesStreamRunning() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask(["timeout_seconds": .int(1)])
            XCTAssertEqual(pending["status"]?.stringValue, "pending")
            XCTAssertEqual(pending["pending"]?.objectValue?["reason"]?.stringValue, "timed_out")
            XCTAssertEqual(pending["wait_policy"]?.objectValue?["mode"]?.stringValue, "explicit")
            XCTAssertEqual(pending["wait_policy"]?.objectValue?["timeout_seconds"]?.intValue, 1)
            let operationID = try operationID(in: pending)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running, "a timeout never touches the query")
            XCTAssertEqual(fixture.store.test_waiterCount(), 0)

            fixture.harness.finish(index: 0, text: "Late answer")
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(try lanes(in: collected).first?["response"]?.stringValue, "Late answer")
        }
    }

    func testMonotonicDeadlineBoundsPreparationBeforeSendStarts() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle deadline preparation gate")
            defer { gate.release() }
            fixture.window.mcpServer.setBeforeAskOraclePreparationForTesting {
                await gate.enterAndWait()
            }
            let clock = ContinuousClock()
            let startedAt = clock.now
            let askTask = Task { @MainActor in
                try await fixture.ask(["timeout_seconds": .int(1)])
            }
            await gate.waitUntilEntered()

            let pending = try await askTask.value
            let elapsed = startedAt.duration(to: clock.now)
            let operationID = try operationID(in: pending)
            XCTAssertEqual(pending["pending"]?.objectValue?["reason"]?.stringValue, "timed_out")
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .starting)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            XCTAssertLessThan(elapsed, .seconds(3), "startup preparation must not extend the one-second observer deadline")

            gate.release()
            try await fixture.harness.waitUntilOpen(count: 1)
        }
    }

    func testRejectedStartupAfterPendingReturnDeliversOriginalErrorAndReleasesRequestKey() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle rejected startup after pending")
            defer { gate.release() }
            let rejection = ChatToolError.oracleConcurrencyLimit("forced pre-send rejection")
            fixture.window.mcpServer.setBeforeAskOraclePreparationForTesting {
                await gate.enterAndWait()
            }
            fixture.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, _ in
                throw rejection
            }
            let requestID = UUID().uuidString

            let pending = try await fixture.ask([
                "timeout_seconds": .int(0),
                "request_id": .string(requestID)
            ])
            let rejectedOperationID = try operationID(in: pending)
            await gate.waitUntilEntered()
            XCTAssertEqual(pending["status"]?.stringValue, "pending")
            XCTAssertEqual(fixture.store.snapshot(rejectedOperationID)?.phase, .starting)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            gate.release()
            try await fixture.waitUntilTerminal(rejectedOperationID)
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(rejectedOperationID.uuidString)])
            ])
            let lane = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(lane["status"]?.stringValue, "failed")
            XCTAssertEqual(lane["error"]?.objectValue?["code"]?.stringValue, rejection.code.rawValue)
            XCTAssertEqual(lane["error"]?.objectValue?["message"]?.stringValue, rejection.message)
            XCTAssertEqual(lane["consultation_started"]?.boolValue, false)
            XCTAssertEqual(lane["request_id_reusable"]?.boolValue, true)
            XCTAssertNil(lane["chat_id"])
            XCTAssertNil(lane["query_id"])
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            fixture.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
            let retry = try await fixture.ask([
                "timeout_seconds": .int(0),
                "request_id": .string(requestID)
            ])
            XCTAssertNotEqual(try operationID(in: retry), rejectedOperationID)
            try await fixture.harness.waitUntilOpen(count: 1)
        }
    }

    func testConcurrentKeyedObserverReceivesOriginalStartupRejectionWithoutResend() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle concurrent keyed rejection")
            defer { gate.release() }
            let rejection = ChatToolError.oracleSessionBusy("forced pre-send rejection")
            fixture.window.mcpServer.setBeforeAskOraclePreparationForTesting {
                await gate.enterAndWait()
            }
            fixture.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, _ in
                throw rejection
            }
            let requestID = UUID().uuidString
            let args: [String: Value] = [
                "timeout_seconds": .int(30),
                "request_id": .string(requestID)
            ]

            let originatingTask = Task { @MainActor in try await fixture.ask(args) }
            await gate.waitUntilEntered()
            try await fixture.waitUntilParked(count: 1)
            let observerTask = Task { @MainActor in try await fixture.ask(args) }
            try await fixture.waitUntilParked(count: 2)

            gate.release()
            do {
                _ = try await originatingTask.value
                XCTFail("originating observer must receive the original pre-send rejection")
            } catch let error as ChatToolError {
                XCTAssertEqual(error.code, rejection.code)
                XCTAssertEqual(error.message, rejection.message)
            }
            let observed = try await observerTask.value
            XCTAssertEqual(observed["status"]?.stringValue, "failed")
            XCTAssertEqual(observed["error"]?.objectValue?["code"]?.stringValue, rejection.code.rawValue)
            XCTAssertEqual(observed["error"]?.objectValue?["message"]?.stringValue, rejection.message)
            XCTAssertEqual(observed["consultation_started"]?.boolValue, false)
            XCTAssertEqual(observed["request_id_reusable"]?.boolValue, true)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0, "pre-send rejection never spends or resends")
        }
    }

    func testWatchdogFinalizationBeatsTransportCancellationAndStaysFailed() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)
            let queryID = try XCTUnwrap(fixture.store.snapshot(operationID)?.queryID)
            fixture.harness.yield(index: 0, text: "partial before watchdog")

            await fixture.window.oracleViewModel.test_fireFinalizationWatchdogNow(for: queryID)
            try await fixture.waitUntilTerminal(operationID)

            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .failed)
            XCTAssertEqual(
                fixture.store.test_terminalDetail(operationID),
                "watchdog_forced_finalization"
            )
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            let lane = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(lane["status"]?.stringValue, "failed")
            XCTAssertNil(lane["response"])
        }
    }

    func testSteeringWakeBoundsPreparationBeforeSendStarts() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle preparation gate")
            defer { gate.release() }
            fixture.window.mcpServer.setBeforeAskOraclePreparationForTesting {
                await gate.enterAndWait()
            }
            let registered = await fixture.window.mcpServer.test_beginResolvedToolExecution(
                metadata: fixture.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle
            )
            let execution = try XCTUnwrap(registered)
            let askTask = Task { @MainActor in
                try await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                    try await fixture.ask(["timeout_seconds": .int(30)])
                }
            }
            await gate.waitUntilEntered()
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            XCTAssertEqual(fixture.store.test_recordCount(), 1)
            XCTAssertEqual(
                try fixture.store.snapshot(XCTUnwrap(fixture.store.test_creationOrder().first))?.phase,
                .starting
            )

            await fixture.window.mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                runID: fixture.runID,
                source: "lifecycle-test-preparation-steer"
            ) { _ in nil }
            let pending = try await askTask.value
            let operationID = try operationID(in: pending)
            XCTAssertEqual(pending["pending"]?.objectValue?["reason"]?.stringValue, "interrupted_by_steering")
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .starting)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            gate.release()
            try await fixture.harness.waitUntilOpen(count: 1)
            fixture.window.mcpServer.test_endToolExecution(executionID: execution.executionID)
        }
    }

    func testSteeringWakeBoundsPostBindActivation() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle post-bind gate")
            defer { gate.release() }
            fixture.window.mcpServer.setOraclePostBindObserverForTesting { _, _ in
                await gate.enterAndWait()
            }
            let registered = await fixture.window.mcpServer.test_beginResolvedToolExecution(
                metadata: fixture.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle
            )
            let execution = try XCTUnwrap(registered)
            let askTask = Task { @MainActor in
                try await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                    try await fixture.ask(["timeout_seconds": .int(30)])
                }
            }
            await gate.waitUntilEntered()
            let operationID = try XCTUnwrap(fixture.store.test_creationOrder().first)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)

            await fixture.window.mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                runID: fixture.runID,
                source: "lifecycle-test-post-bind-steer"
            ) { _ in nil }
            let pending = try await askTask.value
            XCTAssertEqual(try self.operationID(in: pending), operationID)
            XCTAssertEqual(pending["pending"]?.objectValue?["reason"]?.stringValue, "interrupted_by_steering")
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)

            gate.release()
            try await fixture.harness.waitUntilOpen(count: 1)
            fixture.window.mcpServer.test_endToolExecution(executionID: execution.executionID)
        }
    }

    func testTerminalBoundSendReturnsBeforePostBindActivationAndExecutionDrainCompletes() async throws {
        try await withFixture { fixture in
            let gate = TestReleaseFence(name: "ask_oracle terminal post-bind gate")
            defer { gate.release() }
            fixture.window.mcpServer.setOraclePostBindObserverForTesting { _, _ in
                await gate.enterAndWait()
            }
            let registered = await fixture.window.mcpServer.test_beginResolvedToolExecution(
                metadata: fixture.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle
            )
            let execution = try XCTUnwrap(registered)
            let server = fixture.window.mcpServer
            defer { server.test_endToolExecution(executionID: execution.executionID) }

            let resultBox = AskResultBox()
            let askTask = Task { @MainActor in
                do {
                    let result = try await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                        try await fixture.ask(["timeout_seconds": .int(30)])
                    }
                    resultBox.result = .success(result)
                } catch {
                    resultBox.result = .failure(error)
                }
            }
            await gate.waitUntilEntered()
            let operationID = try XCTUnwrap(fixture.store.test_creationOrder().first)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)
            try await fixture.harness.waitUntilOpen(count: 1)

            fixture.harness.finish(index: 0, text: "Completed before post-bind activation")
            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .ready)

            let drainTask = Task { @MainActor in
                await server.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
                    runID: fixture.runID,
                    source: "lifecycle-test-terminal-post-bind-drain",
                    timeoutSeconds: 5
                ) { _ in nil }
            }
            try await AsyncTestWait.waitUntil("terminal post-bind steering becomes sticky", timeout: 5) {
                await MainActor.run {
                    server.oracleWaitScopeSteeringRequested(executionID: execution.executionID)
                }
            }
            try await AsyncTestWait.waitUntil("originating send returns before post-bind release", timeout: 2) {
                await MainActor.run { resultBox.result != nil }
            }

            let completed = try XCTUnwrap(resultBox.result).get()
            XCTAssertEqual(completed["status"]?.stringValue, "completed")
            XCTAssertEqual(completed["response"]?.stringValue, "Completed before post-bind activation")
            XCTAssertEqual(try self.operationID(in: completed), operationID)
            await askTask.value

            server.test_endToolExecution(executionID: execution.executionID)
            let drained = await drainTask.value
            XCTAssertTrue(drained)
            XCTAssertFalse(server.test_oracleWaitScopeExists(executionID: execution.executionID))
            XCTAssertFalse(server.hasActiveToolExecutions(runID: fixture.runID))

            gate.release()
        }
    }

    // MARK: - Steering wake through the execution registry

    func testSteeringWakeReturnsPendingAndToolExecutionDrains() async throws {
        try await withFixture { fixture in
            let registered = await fixture.window.mcpServer.test_beginResolvedToolExecution(
                metadata: fixture.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle
            )
            let execution = try XCTUnwrap(registered)
            XCTAssertEqual(execution.runID, fixture.runID)
            XCTAssertTrue(fixture.window.mcpServer.test_oracleWaitScopeExists(executionID: execution.executionID))
            XCTAssertTrue(fixture.window.mcpServer.hasActiveToolExecutions(runID: fixture.runID))

            let requestID = UUID().uuidString
            let askTask = Task { @MainActor in
                try await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                    try await fixture.ask(["request_id": .string(requestID)])
                }
            }
            try await fixture.harness.waitUntilOpen(count: 1)
            try await fixture.waitUntilParked()
            let server = fixture.window.mcpServer
            try await AsyncTestWait.waitUntil("observer subscribed to wake scope", timeout: 5) {
                await MainActor.run { server.test_oracleWaitScopeHasParkedObserver(executionID: execution.executionID) }
            }

            let operationID = try XCTUnwrap(fixture.store.test_creationOrder().first)
            let queryID = try XCTUnwrap(fixture.store.snapshot(operationID)?.queryID)
            let steeringText = String(repeating: "s", count: 12480)
            fixture.harness.yield(index: 0, text: steeringText)
            try await AsyncTestWait.waitUntil("steering stub observes streamed output", timeout: 2) {
                await MainActor.run {
                    fixture.window.oracleViewModel.oracleMCPProgressSnapshot(for: queryID)?.outputChars
                        == steeringText.count
                }
            }

            await fixture.window.mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                runID: fixture.runID,
                source: "lifecycle-test-steer"
            ) { _ in nil }

            let woken = try await askTask.value
            XCTAssertEqual(woken["status"]?.stringValue, "pending")
            XCTAssertEqual(woken["pending"]?.objectValue?["reason"]?.stringValue, "interrupted_by_steering")
            XCTAssertEqual(woken["_meta"]?.objectValue?["wake_reason"]?.stringValue, MCPOracleToolService.steeringWakeReason)
            XCTAssertNil(woken["response"])
            XCTAssertFalse((woken["note"]?.stringValue ?? "").lowercased().contains("cancel"), "the steering note never mentions cancel")
            XCTAssertEqual(try self.operationID(in: woken), operationID)
            XCTAssertEqual(woken["wait_policy"]?.objectValue?["mode"]?.stringValue, "automatic")
            XCTAssertEqual(woken["wait_policy"]?.objectValue?["parent_family"]?.stringValue, "unresolved")
            let steeringProgress = try XCTUnwrap(
                woken["pending"]?.objectValue?["progress"]?.objectValue
            )
            XCTAssertEqual(steeringProgress["output_chars"]?.intValue, steeringText.count)
            XCTAssertNotNil(steeringProgress["last_activity_seconds_ago"]?.intValue)
            XCTAssertEqual(Set(steeringProgress.keys), ["output_chars", "last_activity_seconds_ago"])
            XCTAssertFalse(
                ToolOutputFormatter.rawJSONString(.object(woken)).contains(steeringText),
                "steering progress must not include output text"
            )
            let steeringStubByteCount = try encodedByteCount(woken)
            XCTAssertLessThanOrEqual(
                steeringStubByteCount,
                MCPOracleToolService.pendingStubByteCeiling,
                "automatic steering stub measured \(steeringStubByteCount) bytes"
            )
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)

            // The tool result has been produced; cleanup unregisters and the flush waiter drains.
            let drainTask = Task { @MainActor in
                try await fixture.window.mcpServer.awaitNoActiveToolExecutions(runID: fixture.runID)
            }
            fixture.window.mcpServer.test_endToolExecution(executionID: execution.executionID)
            try await drainTask.value
            XCTAssertFalse(fixture.window.mcpServer.test_oracleWaitScopeExists(executionID: execution.executionID))
            XCTAssertFalse(fixture.window.mcpServer.hasActiveToolExecutions(runID: fixture.runID))

            // A steer that lands before the call parks is captured by the sticky flag.
            let secondRegistered = await fixture.window.mcpServer.test_beginResolvedToolExecution(
                metadata: fixture.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle
            )
            let second = try XCTUnwrap(secondRegistered)
            await fixture.window.mcpServer.wakeAgentRunWaitersOwnedByActiveRun(
                runID: fixture.runID,
                source: "lifecycle-test-early-steer"
            ) { _ in nil }
            XCTAssertTrue(fixture.window.mcpServer.oracleWaitScopeSteeringRequested(executionID: second.executionID))
            let stickyWait = try await MCPServerViewModel.$currentToolExecutionID.withValue(second.executionID) {
                try await fixture.call([
                    "op": .string("wait"),
                    "operation_ids": .array([.string(operationID.uuidString)])
                ])
            }
            XCTAssertEqual(stickyWait["wait"]?.objectValue?["result"]?.stringValue, "interrupted_by_steering")
            XCTAssertEqual(stickyWait["_meta"]?.objectValue?["wake_reason"]?.stringValue, MCPOracleToolService.steeringWakeReason)
            fixture.window.mcpServer.test_endToolExecution(executionID: second.executionID)

            fixture.harness.finish(index: 0, text: "Collected after steer")
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(collected["wait"]?.objectValue?["result"]?.stringValue, "completed")
            XCTAssertEqual(try lanes(in: collected).first?["response"]?.stringValue, steeringText + "Collected after steer")
            XCTAssertEqual(fixture.harness.openedStreamCount, 1)
        }
    }

    // MARK: - Cancel

    func testCancelPhasesDeliverCancelledLaneWithoutResponseOrExport() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask([
                "timeout_seconds": .int(0),
                "response_mode": .string("tail")
            ])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)
            fixture.harness.yield(index: 0, text: "partial so far")
            try await AsyncTestWait.waitUntil("partial text observed", timeout: 5) {
                await MainActor.run {
                    let queryID = fixture.store.snapshot(operationID)?.queryID
                    return queryID.flatMap { fixture.window.oracleViewModel.getChatMessage(withId: $0)?.content }?.isEmpty == false
                }
            }
            let exportCounter = ExportCounter()
            fixture.window.mcpServer.setOracleExportOverrideForTesting { _ in
                exportCounter.count += 1
                return OracleExportFile(path: "/tmp/never.md", instruction: "never")
            }

            let cancelled = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString), .string(UUID().uuidString)])
            ])
            XCTAssertNil(cancelled["wait_policy"], "cancel never waits")
            let cancelLanes = try lanes(in: cancelled)
            XCTAssertEqual(cancelLanes.count, 2)
            XCTAssertEqual(cancelLanes[0]["cancel"]?.stringValue, "requested")
            XCTAssertEqual(cancelLanes[0]["operation_id"]?.stringValue, operationID.uuidString)
            XCTAssertEqual(cancelLanes[1]["status"]?.stringValue, "unknown")
            XCTAssertEqual(
                cancelLanes[1]["error"]?.objectValue?["code"]?.stringValue,
                ChatToolErrorCode.oracleOperationNotFound.rawValue
            )
            XCTAssertNotNil(cancelled["note"])

            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .cancelled)

            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(collected["wait"]?.objectValue?["result"]?.stringValue, "completed")
            let lane = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(lane["ok"]?.boolValue, false)
            XCTAssertEqual(lane["status"]?.stringValue, "cancelled")
            XCTAssertNil(lane["response"])
            XCTAssertEqual(lane["partial_response"]?.stringValue, "partial so far")
            XCTAssertEqual(lane["export_skipped"]?.stringValue, "cancelled")
            XCTAssertEqual(exportCounter.count, 0, "a cancelled lane never exports")

            let again = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(try lanes(in: again).first?["cancel"]?.stringValue, "already_terminal")
            let chatID = try fixture.chatUUID(shortID: XCTUnwrap(pending["chat_id"]?.stringValue))
            XCTAssertEqual(fixture.window.oracleViewModel.oracleSessionPinCountForTesting(chatID), 0)
        }
    }

    func testConcurrentCancelCallsIssueOneTransportStop() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)

            let gate = TestReleaseFence(name: "ask_oracle cancel gate")
            defer { gate.release() }
            let counter = ExportCounter()
            fixture.window.mcpServer.setOracleCancelOverrideForTesting { _, queryID in
                counter.count += 1
                await gate.enterAndWait()
                return .stopIssued(queryID: queryID)
            }

            let first = Task { @MainActor in
                try await fixture.call([
                    "op": .string("cancel"),
                    "operation_ids": .array([.string(operationID.uuidString)])
                ])
            }
            await gate.waitUntilEntered()
            let second = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(counter.count, 1)
            XCTAssertEqual(try lanes(in: second).first?["cancel"]?.stringValue, "requested")

            gate.release()
            let firstResult = try await first.value
            XCTAssertEqual(try lanes(in: firstResult).first?["cancel"]?.stringValue, "requested")
            XCTAssertEqual(counter.count, 1)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .cancelling)
        }
    }

    func testCancelQueryMatchGuardLeavesMismatchedQueryRunning() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)
            let snapshot = try XCTUnwrap(fixture.store.snapshot(operationID))
            let chatID = try XCTUnwrap(snapshot.chatID)
            let queryID = try XCTUnwrap(snapshot.queryID)

            let mismatch = await fixture.window.oracleViewModel.cancelAIResponse(in: chatID, expectedQueryID: UUID())
            XCTAssertEqual(mismatch, .queryNotActive(activeQueryID: queryID))
            XCTAssertTrue(fixture.window.oracleViewModel.isOracleQueryActive(queryID, in: chatID), "a mismatched cancel issues no stop")
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .running)
            XCTAssertNil(fixture.store.test_terminalReason(operationID))

            // A user pressing Stop in the Oracle UI flows through the same stamp path.
            let matched = await fixture.window.oracleViewModel.cancelAIResponse(in: chatID, skipPartialParseAndSave: true)
            XCTAssertEqual(matched, .stopIssued(queryID: queryID))
            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .cancelled)
            let afterStop = await fixture.window.oracleViewModel.cancelAIResponse(in: chatID, expectedQueryID: queryID)
            XCTAssertEqual(afterStop, .queryNotActive(activeQueryID: nil))
        }
    }

    // MARK: - request_id

    func testRequestIDIdenticalIntentObservesExistingHandleAndDifferentIntentFails() async throws {
        try await withFixture { fixture in
            let requestID = UUID().uuidString
            let first = try await fixture.ask(["timeout_seconds": .int(0), "request_id": .string(requestID)])
            let operationID = try operationID(in: first)
            try await fixture.harness.waitUntilOpen(count: 1)

            let second = try await fixture.ask(["timeout_seconds": .int(0), "request_id": .string(requestID)])
            XCTAssertEqual(try self.operationID(in: second), operationID, "identical keyed intent observes the existing handle")
            XCTAssertEqual(fixture.harness.openedStreamCount, 1, "nothing was resent")

            do {
                _ = try await fixture.ask(
                    ["timeout_seconds": .int(0), "request_id": .string(requestID)],
                    message: "A different question"
                )
                XCTFail("different intent under the same request_id must fail before mutation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("request_id"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.harness.openedStreamCount, 1)
            XCTAssertEqual(fixture.store.test_recordCount(), 1)

            // An unkeyed repeat is a new consultation (no content-based rejection).
            let unkeyed = try await fixture.ask(["timeout_seconds": .int(0)])
            XCTAssertNotEqual(try self.operationID(in: unkeyed), operationID)
            try await fixture.harness.waitUntilOpen(count: 2)
        }
    }

    func testKeyedRetryUsesCanonicalDefaultsBeforeMutablePresetPreparation() async throws {
        try await withFixture { fixture in
            let requestID = UUID().uuidString
            let base: [String: Value] = [
                "message": .string("canonical keyed question"),
                "model": .string(fixture.preset.id.uuidString),
                "new_chat": .bool(true),
                "timeout_seconds": .int(0),
                "request_id": .string(requestID)
            ]
            let first = try await fixture.call(base)
            let operationID = try operationID(in: first)
            try await fixture.harness.waitUntilOpen(count: 1)

            ModelPresetsManager.shared.presets = []
            var explicitDefaults = base
            explicitDefaults["mode"] = .string("chat")
            explicitDefaults["selection_mode"] = .string("current")
            let retried = try await fixture.call(explicitDefaults)

            XCTAssertEqual(try self.operationID(in: retried), operationID)
            XCTAssertEqual(fixture.harness.openedStreamCount, 1)
            XCTAssertEqual(fixture.store.test_recordCount(), 1)
        }
    }

    // MARK: - Bounded resumable batches (Step C)

    func testBatchValidationRejectsInvalidShapesAtomicallyBeforeAnyReceipt() async throws {
        try await withFixture { fixture in
            let invalidBatches: [[String: Value]] = [
                ["consultations": .array([]), "timeout_seconds": .int(0)],
                ["consultations": batchConsultations(fixture: fixture, count: 17), "timeout_seconds": .int(0)],
                [
                    "consultations": batchConsultations(fixture: fixture, count: 1),
                    "timeout_seconds": .int(0),
                    "request_id": .string(UUID().uuidString)
                ],
                [
                    "consultations": .array([
                        .object([
                            "message": .string("lane"),
                            "model": .string(fixture.preset.id.uuidString),
                            "request_id": .string(UUID().uuidString)
                        ])
                    ]),
                    "timeout_seconds": .int(0)
                ]
            ]

            for args in invalidBatches {
                do {
                    _ = try await fixture.call(args)
                    XCTFail("invalid batch must fail before admission")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
                XCTAssertEqual(fixture.store.test_recordCount(), 0)
                XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            }
        }
    }

    func testBatchSelectorValidationRejectsMixedUnknownAndAmbiguousNamesAtomically() async throws {
        try await withFixture { fixture in
            do {
                _ = try await fixture.call([
                    "consultations": .array([
                        .object([
                            "message": .string("valid lane"),
                            "model": .string(fixture.preset.id.uuidString)
                        ]),
                        .object([
                            "message": .string("invalid lane"),
                            "model": .string("misspelled-preset")
                        ])
                    ]),
                    "timeout_seconds": .int(0)
                ])
                XCTFail("unknown selector must reject the entire batch")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("consultations[1].model"),
                    error.localizedDescription
                )
            }
            XCTAssertEqual(fixture.store.test_recordCount(), 0)
            XCTAssertEqual(fixture.window.oracleViewModel.sessions.count, 0)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            let duplicate = ModelPreset(
                name: fixture.preset.name,
                model: .customProviderUser(name: "ambiguous-selector"),
                supportedModes: SupportedModes(chat: true, plan: true, review: true)
            )
            ModelPresetsManager.shared.presets = [fixture.preset, duplicate]
            do {
                _ = try await fixture.call([
                    "consultations": .array([
                        .object([
                            "message": .string("ambiguous lane"),
                            "model": .string(fixture.preset.name)
                        ])
                    ]),
                    "timeout_seconds": .int(0)
                ])
                XCTFail("ambiguous selector must reject the entire batch")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("unambiguous name"),
                    error.localizedDescription
                )
            }
            XCTAssertEqual(fixture.store.test_recordCount(), 0)
            XCTAssertEqual(fixture.window.oracleViewModel.sessions.count, 0)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
        }
    }

    func testBatchPlanningModelSentinelRemainsValidWithoutUsablePresets() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let settings = GlobalSettingsStore.shared
            let previousPlanningModelName = fixture.window.promptManager.planningModelName
            defer {
                fixture.window.promptManager.planningModelName = previousPlanningModelName
            }
            settings.setMCPShowModelPresets(false, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            fixture.window.promptManager.planningModelName = fixture.model.rawValue

            let batch = try await fixture.call([
                "consultations": .array([
                    .object([
                        "message": .string("planning sentinel lane"),
                        "model": .string("current_chat_model")
                    ])
                ]),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            try await fixture.harness.waitUntilOpen(count: 1)
            let replyContext = try XCTUnwrap(fixture.store.replyContext(operationID))
            XCTAssertEqual(replyContext.modelSource, "planning_model")
            XCTAssertEqual(replyContext.modelRawID, fixture.model.rawValue)

            fixture.harness.finish(index: 0, text: "planning sentinel answer")
            try await fixture.waitUntilTerminal(operationID)
        }
    }

    func testBatchReturnsStableIndexedReceiptsAndQueuesBehindActualStreamCapacity() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let preparationGate = TestReleaseFence(name: "queued position preparing-head gate")
            defer { preparationGate.release() }
            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 5),
                "timeout_seconds": .int(0)
            ])
            let admitted = try lanes(in: batch)
            XCTAssertEqual(admitted.map { $0["index"]?.intValue }, [0, 1, 2, 3, 4])
            let operationIDs = try admitted.map {
                try XCTUnwrap($0["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            }
            XCTAssertEqual(batch["wait"]?.objectValue?["result"]?.stringValue, "polled")
            XCTAssertEqual(batch["wait_policy"]?.objectValue?["mode"]?.stringValue, "poll")

            try await fixture.harness.waitUntilOpen(count: 2)
            let polled = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array(operationIDs.map { .string($0.uuidString) }),
                "timeout_seconds": .int(0)
            ])
            let lanes = try lanes(in: polled)
            XCTAssertEqual(lanes.map { $0["index"]?.intValue }, [0, 1, 2, 3, 4])
            XCTAssertEqual(lanes[0]["pending"]?.objectValue?["stream_state"]?.stringValue, "streaming")
            XCTAssertEqual(lanes[1]["pending"]?.objectValue?["stream_state"]?.stringValue, "streaming")
            XCTAssertEqual(
                lanes[2 ... 4].map { $0["pending"]?.objectValue?["stream_state"]?.stringValue },
                ["queued", "queued", "queued"]
            )
            let initialQueuePositions = try lanes[2 ... 4].map { lane in
                let progress = try XCTUnwrap(lane["pending"]?.objectValue?["progress"]?.objectValue)
                XCTAssertNil(progress["output_chars"])
                XCTAssertNil(progress["last_activity_seconds_ago"])
                XCTAssertEqual(Set(progress.keys), ["queue_position"])
                return try XCTUnwrap(progress["queue_position"]?.intValue)
            }
            XCTAssertEqual(initialQueuePositions, [0, 1, 2])
            XCTAssertNotNil(lanes[2]["chat_id"], "unbound batch receipts explicitly carry null chat_id")
            XCTAssertNotNil(lanes[2]["query_id"], "unbound batch receipts explicitly carry null query_id")

            let cancelled = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationIDs[2].uuidString)])
            ])
            let cancelledLane = try XCTUnwrap(try self.lanes(in: cancelled).first)
            XCTAssertEqual(cancelledLane["index"]?.intValue, 2)
            XCTAssertEqual(cancelledLane["cancel"]?.stringValue, "requested")

            let afterCancel = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array(operationIDs[3 ... 4].map { .string($0.uuidString) }),
                "timeout_seconds": .int(0)
            ])
            let afterCancelLanes = try self.lanes(in: afterCancel)
            XCTAssertEqual(afterCancelLanes.map { $0["index"]?.intValue }, [3, 4])
            let afterCancelPositions = try afterCancelLanes.map { lane in
                try XCTUnwrap(
                    lane["pending"]?.objectValue?["progress"]?.objectValue?["queue_position"]?.intValue
                )
            }
            XCTAssertEqual(afterCancelPositions, [0, 1], "cancelling the queued head shifts later FIFO positions")

            var shouldBlockNextPreparation = true
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                if shouldBlockNextPreparation {
                    shouldBlockNextPreparation = false
                    await preparationGate.enterAndWait()
                }
            }
            fixture.harness.finish(index: 0, text: "lane zero")
            await preparationGate.waitUntilEntered()
            XCTAssertEqual(fixture.store.snapshot(operationIDs[3])?.phase, .starting)

            let whilePreparing = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array(operationIDs[3 ... 4].map { .string($0.uuidString) }),
                "timeout_seconds": .int(0)
            ])
            let preparingLanes = try self.lanes(in: whilePreparing)
            XCTAssertEqual(preparingLanes.map { $0["index"]?.intValue }, [3, 4])
            XCTAssertEqual(preparingLanes[0]["pending"]?.objectValue?["stream_state"]?.stringValue, "starting")
            XCTAssertNil(
                preparingLanes[0]["pending"]?.objectValue?["progress"],
                "a preparing head reports no progress of its own"
            )
            XCTAssertEqual(
                preparingLanes[1]["pending"]?.objectValue?["progress"]?.objectValue?["queue_position"]?.intValue,
                1,
                "a queued lane counts an earlier unbound preparing head"
            )

            preparationGate.release()
            try await fixture.harness.waitUntilOpen(count: 3)
            XCTAssertEqual(fixture.store.snapshot(operationIDs[3])?.phase, .running)
            let afterBind = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array(operationIDs[3 ... 4].map { .string($0.uuidString) }),
                "timeout_seconds": .int(0)
            ])
            let afterBindLanes = try self.lanes(in: afterBind)
            XCTAssertEqual(afterBindLanes.map { $0["index"]?.intValue }, [3, 4])
            XCTAssertEqual(afterBindLanes[0]["pending"]?.objectValue?["stream_state"]?.stringValue, "streaming")
            XCTAssertEqual(
                afterBindLanes[1]["pending"]?.objectValue?["progress"]?.objectValue?["queue_position"]?.intValue,
                0,
                "binding the preparing head removes it from the unbound FIFO position"
            )

            fixture.harness.finish(index: 1, text: "lane one")
            try await fixture.harness.waitUntilOpen(count: 4)
            fixture.harness.finish(index: 2, text: "lane three")
            fixture.harness.finish(index: 3, text: "lane four")
            for operationID in [operationIDs[0], operationIDs[1], operationIDs[3], operationIDs[4]] {
                try await fixture.waitUntilTerminal(operationID)
            }
        }
    }

    func testBatchSameSessionRunRotationUsesCurrentRunAndRetainsOrigin() async throws {
        try await withFixture { fixture in
            let sessionID = UUID()
            try fixture.activateAgentRunForBatch(
                sessionID: sessionID,
                activeRunID: fixture.runID
            )
            let gate = TestReleaseFence(name: "batch same-session rotation final gate")
            defer { gate.release() }
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                await gate.enterAndWait()
            }

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()
            XCTAssertEqual(fixture.store.snapshot(operationID)?.owner.originatingRunID, fixture.runID)

            let rotatedRunID = UUID()
            let session = fixture.window.agentModeViewModel.session(for: fixture.tabID)
            session.runID = rotatedRunID
            session.runState = .running
            gate.release()

            try await fixture.harness.waitUntilOpen(count: 1)
            try await AsyncTestWait.waitUntil("rotated batch lane bound", timeout: 5) {
                await MainActor.run { fixture.store.snapshot(operationID)?.phase == .running }
            }
            let replyContext = try XCTUnwrap(fixture.store.replyContext(operationID))
            XCTAssertEqual(replyContext.agentModeSessionID, sessionID)
            XCTAssertEqual(replyContext.agentModeRunID, rotatedRunID)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.owner.originatingRunID, fixture.runID)

            fixture.harness.finish(index: 0, text: "rotated run answer")
            try await fixture.waitUntilTerminal(operationID)
        }
    }

    func testDelegatedBatchRejectsSameSessionRunRotationAtFinalReservationGate() async throws {
        try await withFixture { fixture in
            let sessionID = UUID()
            try fixture.activateAgentRunForBatch(
                sessionID: sessionID,
                activeRunID: fixture.runID
            )
            let viewModel = fixture.window.agentModeViewModel
            _ = try await viewModel.mcpActivateControlContext(
                forTabID: fixture.tabID,
                sessionID: sessionID,
                originatingConnectionID: fixture.connectionID,
                startPending: true
            )
            let session = viewModel.session(for: fixture.tabID)
            session.runID = fixture.runID
            session.runState = .running
            viewModel.setAgentRunActive(fixture.tabID, isActive: true)

            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let source = AgentRunOracleReviewSource.captured(.init(
                sourceTabID: fixture.tabID,
                workspaceID: workspace.id,
                sourceSelectionRevision: fixture.window.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: fixture.tabID
                ),
                promptText: "frozen delegated review source",
                selection: StoredSelection(),
                lookupContext: .visibleWorkspace,
                reviewGitContext: .automaticOnly(
                    base: "HEAD",
                    workspaceRootPaths: workspace.repoPaths
                ),
                sourceAgentSessionID: sessionID,
                sourceAgentRunID: fixture.runID,
                sourceWorktreeBindings: []
            ))
            try viewModel.mcpStageAgentRunOracleReviewSource(
                source,
                targetTabID: fixture.tabID,
                targetSessionID: sessionID,
                expectedParentSessionID: session.parentSessionID
            )
            XCTAssertNotNil(
                viewModel.mcpBindPendingAgentRunOracleReviewContext(
                    tabID: fixture.tabID,
                    runID: fixture.runID
                )
            )

            let gate = TestReleaseFence(name: "delegated batch originating-run final gate")
            defer { gate.release() }
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                await gate.enterAndWait()
            }
            let batch = try await fixture.call([
                "consultations": .array([
                    .object([
                        "message": .string("Review the delegated source"),
                        "model": .string(fixture.preset.id.uuidString),
                        "mode": .string("review")
                    ])
                ]),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()

            session.runID = UUID()
            session.runState = .running
            gate.release()

            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let terminal = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(terminal["consultation_started"]?.boolValue, false)
            XCTAssertEqual(
                terminal["error"]?.objectValue?["code"]?.stringValue,
                ChatToolErrorCode.notStartedOwnerInactive.rawValue
            )
        }
    }

    func testBatchFIFOAcrossInvocationsAndPostBindActivationDoesNotSerialize() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "first batch post-bind activation")
            defer { gate.release() }
            var postBindCount = 0
            fixture.window.mcpServer.setOraclePostBindObserverForTesting { _, _ in
                postBindCount += 1
                if postBindCount == 1 {
                    await gate.enterAndWait()
                }
            }

            let firstBatch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 2),
                "timeout_seconds": .int(0)
            ])
            let firstIDs = try lanes(in: firstBatch).map {
                try XCTUnwrap($0["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            }
            await gate.waitUntilEntered()
            try await fixture.harness.waitUntilOpen(count: 2)
            XCTAssertEqual(postBindCount, 2, "the next lane binds while prior post-bind activation is parked")
            XCTAssertTrue(firstIDs.allSatisfy { fixture.store.snapshot($0)?.phase == .running })

            let secondBatch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 2),
                "timeout_seconds": .int(0)
            ])
            let secondIDs = try lanes(in: secondBatch).map {
                try XCTUnwrap($0["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            }
            XCTAssertEqual(fixture.store.test_batchQueue(fixture.tabID), secondIDs)
            XCTAssertTrue(secondIDs.allSatisfy { fixture.store.snapshot($0)?.phase == .queued })
            gate.release()

            fixture.harness.finish(index: 0, text: "first batch lane zero")
            try await fixture.harness.waitUntilOpen(count: 3)
            XCTAssertEqual(fixture.store.snapshot(secondIDs[0])?.phase, .running)
            XCTAssertEqual(fixture.store.snapshot(secondIDs[1])?.phase, .queued)

            fixture.harness.finish(index: 1, text: "first batch lane one")
            try await fixture.harness.waitUntilOpen(count: 4)
            XCTAssertEqual(fixture.store.snapshot(secondIDs[1])?.phase, .running)

            fixture.harness.finish(index: 2, text: "second batch lane zero")
            fixture.harness.finish(index: 3, text: "second batch lane one")
            for operationID in firstIDs + secondIDs {
                try await fixture.waitUntilTerminal(operationID)
            }
        }
    }

    func testBatchSchedulerRespectsLegacyOracleSendActualStreamOccupancy() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            async let legacyResult = fixture.legacySend(message: "legacy occupancy")
            try await fixture.harness.waitUntilOpen(count: 1)

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 2),
                "timeout_seconds": .int(0)
            ])
            let admitted = try lanes(in: batch)
            let operationIDs = try admitted.map {
                try XCTUnwrap($0["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            }

            try await fixture.harness.waitUntilOpen(count: 2)
            XCTAssertEqual(fixture.store.snapshot(operationIDs[0])?.phase, .running)
            XCTAssertEqual(fixture.store.snapshot(operationIDs[1])?.phase, .queued)
            XCTAssertEqual(
                fixture.harness.openedStreamCount,
                2,
                "one legacy stream leaves capacity for exactly one batch lane"
            )

            fixture.harness.finish(index: 0, text: "legacy complete")
            _ = try await legacyResult
            try await fixture.harness.waitUntilOpen(count: 3)
            XCTAssertEqual(fixture.store.snapshot(operationIDs[1])?.phase, .running)

            fixture.harness.finish(index: 1, text: "batch zero")
            fixture.harness.finish(index: 2, text: "batch one")
            try await fixture.waitUntilTerminal(operationIDs[0])
            try await fixture.waitUntilTerminal(operationIDs[1])
        }
    }

    func testBatchLateReservationRaceParksPreparedLaneWithoutRepackaging() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "batch post-packaging reservation gate")
            defer { gate.release() }
            var preparedCount = 0
            var shouldBlockFirst = true
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                preparedCount += 1
                if shouldBlockFirst {
                    shouldBlockFirst = false
                    await gate.enterAndWait()
                }
            }

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let batchLane = try XCTUnwrap(try lanes(in: batch).first)
            let batchOperationID = try XCTUnwrap(
                batchLane["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()

            let firstSingle = try await fixture.ask(["timeout_seconds": .int(0)], message: "occupy one")
            let secondSingle = try await fixture.ask(["timeout_seconds": .int(0)], message: "occupy two")
            let firstSingleID = try operationID(in: firstSingle)
            let secondSingleID = try operationID(in: secondSingle)
            try await fixture.harness.waitUntilOpen(count: 2)

            gate.release()
            try await AsyncTestWait.waitUntil("prepared batch lane parks after capacity race", timeout: 5) {
                await MainActor.run {
                    fixture.store.snapshot(batchOperationID)?.phase == .queued
                }
            }
            XCTAssertEqual(fixture.harness.openedStreamCount, 2)
            XCTAssertEqual(preparedCount, 3, "the batch lane and two singles package exactly once each")

            fixture.harness.finish(index: 0, text: "free capacity")
            try await fixture.harness.waitUntilOpen(count: 3)
            XCTAssertEqual(fixture.store.snapshot(batchOperationID)?.phase, .running)
            XCTAssertEqual(preparedCount, 3, "capacity wake must reuse the prepared request")
            fixture.harness.finish(index: 1, text: "second single")
            fixture.harness.finish(index: 2, text: "batch")
            try await fixture.waitUntilTerminal(firstSingleID)
            try await fixture.waitUntilTerminal(secondSingleID)
        }
    }

    func testBatchCancellationAfterPackagingFailsFinalGateWithoutSpend() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "batch cancellation after packaging")
            defer { gate.release() }
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                await gate.enterAndWaitIgnoringCancellationUntilRelease()
            }
            let initialSessionIDs = fixture.window.oracleViewModel.sessions.map(\.id)

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()
            let startupTask = try XCTUnwrap(fixture.store.test_startupTask(operationID))

            let cancelled = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            XCTAssertEqual(try lanes(in: cancelled).first?["cancel"]?.stringValue, "requested")
            gate.release()
            let startupError = await startupTask.value

            XCTAssertEqual(startupError?.code, .internalError)
            XCTAssertEqual(
                startupError?.message,
                "ask_oracle batch lane could not be reserved because its accepted receipt is no longer eligible"
            )
            XCTAssertEqual(fixture.store.snapshot(operationID)?.phase, .cancelled)
            XCTAssertNil(fixture.store.snapshot(operationID)?.chatID)
            XCTAssertNil(fixture.store.snapshot(operationID)?.queryID)
            XCTAssertFalse(fixture.store.test_ownsPin(operationID))
            XCTAssertEqual(fixture.window.oracleViewModel.sessions.map(\.id), initialSessionIDs)
            XCTAssertEqual(
                fixture.window.oracleViewModel.mcpActiveOracleStreamCount(forTabID: fixture.tabID),
                0
            )
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
        }
    }

    func testBatchPurgedCancelledReceiptFailsClosedBeforeSendPreparation() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "batch purged cancelled receipt")
            defer { gate.release() }
            fixture.window.mcpServer.setBeforeAskOraclePreparationForTesting {
                await gate.enterAndWaitIgnoringCancellationUntilRelease()
            }
            let initialSessionIDs = fixture.window.oracleViewModel.sessions.map(\.id)

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()
            let startupTask = try XCTUnwrap(fixture.store.test_startupTask(operationID))

            _ = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ])
            fixture.store.purge(
                now: Date().addingTimeInterval(
                    OracleMCPOperationStore.undeliveredRetentionSeconds + 1
                )
            )
            XCTAssertNil(fixture.store.snapshot(operationID))

            gate.release()
            let startupError = await startupTask.value
            XCTAssertEqual(startupError?.code, .internalError)
            XCTAssertEqual(
                startupError?.message,
                "ask_oracle operation receipt is no longer available before send preparation"
            )
            XCTAssertEqual(fixture.window.oracleViewModel.sessions.map(\.id), initialSessionIDs)
            XCTAssertEqual(
                fixture.window.oracleViewModel.mcpActiveOracleStreamCount(forTabID: fixture.tabID),
                0
            )
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            let expired = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let expiredLane = try XCTUnwrap(try lanes(in: expired).first)
            XCTAssertEqual(expiredLane["status"]?.stringValue, "unknown")
            XCTAssertEqual(
                expiredLane["error"]?.objectValue?["code"]?.stringValue,
                ChatToolErrorCode.oracleOperationExpired.rawValue
            )
        }
    }

    func testBatchTeardownAfterPackagingReturnsTypedNoSpendFailure() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "batch teardown after packaging")
            defer { gate.release() }
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                await gate.enterAndWaitIgnoringCancellationUntilRelease()
            }
            let initialSessionIDs = fixture.window.oracleViewModel.sessions.map(\.id)

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let operationID = try XCTUnwrap(
                try lanes(in: batch).first?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()
            let startupTask = try XCTUnwrap(fixture.store.test_startupTask(operationID))

            fixture.store.teardown()
            gate.release()
            let startupError = await startupTask.value
            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(startupError?.code, .internalError)
            XCTAssertEqual(
                startupError?.message,
                "ask_oracle batch lane could not be reserved because its accepted receipt is no longer eligible"
            )
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            XCTAssertNil(fixture.store.snapshot(operationID)?.chatID)
            XCTAssertNil(fixture.store.snapshot(operationID)?.queryID)
            XCTAssertFalse(fixture.store.test_ownsPin(operationID))
            XCTAssertEqual(fixture.window.oracleViewModel.sessions.map(\.id), initialSessionIDs)
            XCTAssertEqual(
                fixture.window.oracleViewModel.mcpActiveOracleStreamCount(forTabID: fixture.tabID),
                0
            )

            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let terminal = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(terminal["consultation_started"]?.boolValue, false)
            XCTAssertEqual(
                terminal["error"]?.objectValue?["code"]?.stringValue,
                ChatToolErrorCode.internalError.rawValue
            )
            XCTAssertEqual(
                terminal["error"]?.objectValue?["message"]?.stringValue,
                "ask_oracle batch lane could not be reserved because its accepted receipt is no longer eligible"
            )
        }
    }

    func testExplicitSendBatchPlanLaneUsesSharedBatchPackaging() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let batch = try await fixture.call([
                "op": .string("send"),
                "consultations": .array([
                    .object([
                        "message": .string("Plan through the shared batch source"),
                        "model": .string(fixture.preset.id.uuidString),
                        "mode": .string("plan")
                    ])
                ]),
                "timeout_seconds": .int(0)
            ])
            let lane = try XCTUnwrap(try lanes(in: batch).first)
            let operationID = try XCTUnwrap(
                lane["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            XCTAssertEqual(lane["index"]?.intValue, 0)
            try await fixture.harness.waitUntilOpen(count: 1)
            XCTAssertEqual(fixture.store.snapshot(operationID)?.finalization.mode, "plan")
            XCTAssertEqual(fixture.store.replyContext(operationID)?.mode, "plan")

            fixture.harness.finish(index: 0, text: "plan answer")
            try await fixture.waitUntilTerminal(operationID)
        }
    }

    func testQueuedBatchCancellationSpendsNothingAndDeliversIndexedTerminalLane() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let batch = try await fixture.call([
                "consultations": batchConsultations(
                    fixture: fixture,
                    count: 3,
                    responseModeForLast: "tail"
                ),
                "timeout_seconds": .int(0)
            ])
            let admitted = try lanes(in: batch)
            let operationIDs = try admitted.map {
                try XCTUnwrap($0["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            }
            try await fixture.harness.waitUntilOpen(count: 2)
            XCTAssertEqual(fixture.store.snapshot(operationIDs[2])?.phase, .queued)

            let cancelled = try await fixture.call([
                "op": .string("cancel"),
                "operation_ids": .array([.string(operationIDs[2].uuidString)])
            ])
            let cancelLane = try XCTUnwrap(try lanes(in: cancelled).first)
            XCTAssertEqual(cancelLane["index"]?.intValue, 2)
            XCTAssertEqual(cancelLane["cancel"]?.stringValue, "requested")
            XCTAssertEqual(
                cancelled["resume"]?.objectValue?["operation_ids"]?.arrayValue?.compactMap(\.stringValue),
                [operationIDs[2].uuidString]
            )

            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationIDs[2].uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let terminal = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(terminal["index"]?.intValue, 2)
            XCTAssertEqual(terminal["status"]?.stringValue, "cancelled")
            XCTAssertEqual(terminal["consultation_started"]?.boolValue, false)
            XCTAssertEqual(terminal["export_skipped"]?.stringValue, "cancelled")
            XCTAssertNil(terminal["response"])

            fixture.harness.finish(index: 0, text: "first")
            fixture.harness.finish(index: 1, text: "second")
            try await fixture.waitUntilTerminal(operationIDs[0])
            try await fixture.waitUntilTerminal(operationIDs[1])
            XCTAssertEqual(fixture.harness.openedStreamCount, 2, "cancelled queued work never starts a provider")
        }
    }

    func testBatchOwnerBecomingInactiveAfterPreparationFailsBeforeReservation() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            let gate = TestReleaseFence(name: "batch owner liveness final gate")
            defer { gate.release() }
            var shouldBlockFirst = true
            fixture.window.oracleViewModel.setOracleRequestPreparedObserverForTesting {
                if shouldBlockFirst {
                    shouldBlockFirst = false
                    await gate.enterAndWait()
                }
            }

            let batch = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])
            let lane = try XCTUnwrap(try lanes(in: batch).first)
            let operationID = try XCTUnwrap(
                lane["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            await gate.waitUntilEntered()

            let session = fixture.window.agentModeViewModel.session(for: fixture.tabID)
            session.runState = .completed
            fixture.window.agentModeViewModel.setAgentRunActive(fixture.tabID, isActive: false)
            gate.release()

            try await fixture.waitUntilTerminal(operationID)
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)
            let collected = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let terminal = try XCTUnwrap(try lanes(in: collected).first)
            XCTAssertEqual(terminal["index"]?.intValue, 0)
            XCTAssertEqual(terminal["consultation_started"]?.boolValue, false)
            XCTAssertEqual(
                terminal["error"]?.objectValue?["code"]?.stringValue,
                ChatToolErrorCode.notStartedOwnerInactive.rawValue
            )
        }
    }

    func testIDLessWaitRecoversMoreThanSixteenBatchLanesWithSafeResumeArgs() async throws {
        try await withFixture { fixture in
            try fixture.activateAgentRunForBatch()
            _ = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 16),
                "timeout_seconds": .int(0)
            ])
            _ = try await fixture.call([
                "consultations": batchConsultations(fixture: fixture, count: 1),
                "timeout_seconds": .int(0)
            ])

            let recovered = try await fixture.call([
                "op": .string("wait"),
                "timeout_seconds": .int(0)
            ])
            XCTAssertEqual(try lanes(in: recovered).count, 17)
            XCTAssertEqual(
                recovered["wait"]?.objectValue?["pending_operation_ids"]?.arrayValue?.count,
                17
            )
            XCTAssertEqual(recovered["resume"]?.objectValue?["op"]?.stringValue, "wait")
            XCTAssertNil(
                recovered["resume"]?.objectValue?["operation_ids"],
                "resume must omit an invalid >16 explicit handle list"
            )
        }
    }

    // MARK: - Multi-handle wait envelopes

    func testWaitWithoutIDsObservesUndeliveredOperationsInCreationOrderAndUnknownLanesNeverFail() async throws {
        try await withFixture { fixture in
            let first = try await fixture.ask(["timeout_seconds": .int(0)], message: "first")
            let second = try await fixture.ask(["timeout_seconds": .int(0)], message: "second")
            let firstID = try operationID(in: first)
            let secondID = try operationID(in: second)
            try await fixture.harness.waitUntilOpen(count: 2)

            let polled = try await fixture.call(["op": .string("wait"), "timeout_seconds": .int(0)])
            XCTAssertEqual(
                try lanes(in: polled).map { $0["operation_id"]?.stringValue },
                [firstID.uuidString, secondID.uuidString]
            )
            XCTAssertEqual(
                polled["wait"]?.objectValue?["pending_operation_ids"]?.arrayValue?.compactMap(\.stringValue),
                [firstID.uuidString, secondID.uuidString]
            )

            fixture.harness.finish(index: 0, text: "first answer")
            let unknownID = UUID()
            let partial = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([.string(unknownID.uuidString), .string(firstID.uuidString), .string(secondID.uuidString)]),
                "timeout_seconds": .int(0)
            ])
            let partialLanes = try lanes(in: partial)
            XCTAssertEqual(partialLanes.count, 3)
            XCTAssertEqual(partialLanes[0]["status"]?.stringValue, "unknown")
            XCTAssertEqual(partialLanes[0]["error"]?.objectValue?["code"]?.stringValue, ChatToolErrorCode.oracleOperationNotFound.rawValue)
            XCTAssertEqual(partialLanes[1]["status"]?.stringValue, "completed")
            XCTAssertEqual(partialLanes[1]["response"]?.stringValue, "first answer")
            XCTAssertEqual(partialLanes[2]["status"]?.stringValue, "pending")
            XCTAssertEqual(partial["wait"]?.objectValue?["result"]?.stringValue, "polled")
            XCTAssertEqual(
                partial["resume"]?.objectValue?["operation_ids"]?.arrayValue?.compactMap(\.stringValue),
                [secondID.uuidString]
            )

            fixture.harness.finish(index: 1, text: "second answer")
            let rest = try await fixture.call(["op": .string("wait")])
            XCTAssertEqual(rest["wait"]?.objectValue?["result"]?.stringValue, "completed")
            XCTAssertEqual(try lanes(in: rest).map { $0["operation_id"]?.stringValue }, [secondID.uuidString])

            let nothingLeft = try await fixture.call(["op": .string("wait"), "timeout_seconds": .int(0)])
            XCTAssertEqual(try lanes(in: nothingLeft).count, 0, "delivered operations are not re-observed by an ID-less wait")
            XCTAssertEqual(nothingLeft["wait"]?.objectValue?["result"]?.stringValue, "completed")
        }
    }

    func testMultiLaneFullExportFailureFallsBackInlineWithoutLosingSuccessfulLane() async throws {
        try await withFixture { fixture in
            let first = try await fixture.ask(
                ["timeout_seconds": .int(0), "export_response": .bool(true)],
                message: "first export"
            )
            let second = try await fixture.ask(
                ["timeout_seconds": .int(0), "export_response": .bool(true)],
                message: "second export"
            )
            let firstID = try operationID(in: first)
            let secondID = try operationID(in: second)
            try await fixture.harness.waitUntilOpen(count: 2)

            let counter = ExportCounter()
            fixture.window.mcpServer.setOracleExportOverrideForTesting { request in
                counter.count += 1
                if counter.count == 2 {
                    throw LifecycleTestError.exportFailed
                }
                return OracleExportFile(
                    path: "/tmp/oracle-\(request.chatID ?? "chat").md",
                    instruction: "read it"
                )
            }
            fixture.harness.finish(index: 0, text: "first response")
            fixture.harness.finish(index: 1, text: "second response")
            try await fixture.waitUntilTerminal(firstID)
            try await fixture.waitUntilTerminal(secondID)

            let waited = try await fixture.call([
                "op": .string("wait"),
                "operation_ids": .array([
                    .string(firstID.uuidString),
                    .string(secondID.uuidString)
                ])
            ])
            let delivered = try lanes(in: waited)
            XCTAssertEqual(delivered.count, 2)
            XCTAssertEqual(delivered[0]["status"]?.stringValue, "completed")
            XCTAssertNotNil(delivered[0]["oracle_export_path"])
            XCTAssertEqual(delivered[1]["status"]?.stringValue, "completed")
            XCTAssertEqual(delivered[1]["response"]?.stringValue, "second response")
            XCTAssertNotNil(delivered[1]["export_failed_warning"])
            XCTAssertEqual(fixture.store.snapshot(firstID)?.delivery, .delivered)
            XCTAssertEqual(fixture.store.snapshot(secondID)?.delivery, .delivered)
        }
    }

    func testTrimmedResponseExportsOnceAcrossConcurrentWaits() async throws {
        try await withFixture { fixture in
            let pending = try await fixture.ask([
                "timeout_seconds": .int(0),
                "response_mode": .string("none")
            ])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)
            let exportCounter = ExportCounter()
            fixture.window.mcpServer.setOracleExportOverrideForTesting { request in
                exportCounter.count += 1
                return OracleExportFile(path: "/tmp/oracle-\(request.chatID ?? "chat").md", instruction: "read it")
            }
            fixture.harness.finish(index: 0, text: "A long answer that is exported")
            try await fixture.waitUntilTerminal(operationID)

            let waitArgs: [String: Value] = [
                "op": .string("wait"),
                "operation_ids": .array([.string(operationID.uuidString)])
            ]
            async let firstWait = fixture.call(waitArgs)
            async let secondWait = fixture.call(waitArgs)
            let (first, second) = try await (firstWait, secondWait)
            XCTAssertEqual(exportCounter.count, 1, "export happens at most once per operation")
            let firstLane = try XCTUnwrap(try lanes(in: first).first)
            let secondLane = try XCTUnwrap(try lanes(in: second).first)
            XCTAssertEqual(firstLane, secondLane)
            XCTAssertNil(firstLane["response"])
            XCTAssertEqual(firstLane["response_mode"]?.stringValue, "none")
            XCTAssertNotNil(firstLane["oracle_export_path"])
            XCTAssertEqual(firstLane["status"]?.stringValue, "completed")
        }
    }
}
