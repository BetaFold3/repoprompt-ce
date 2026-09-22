import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Oracle resumable wait plan §5 `MCPAskOracleLifecycleTests`: bounded single send, pending
/// stub shape and byte ceiling, `wait_policy` per mode, `op:"wait"` envelopes, `op:"cancel"`
/// phases and the query-match rule, `request_id` dedup, Step B batch admission, and the
/// steering wake through the real `MCPServerViewModel` execution registry.
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
            window.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            window.oracleViewModel.mcpOperationStore.teardown()
            await window.oracleViewModel.cancelAllActiveSessionStreams()
            window.oracleViewModel.sessions = []
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
            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
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
            XCTAssertEqual(polled["wait_policy"]?.objectValue?["mode"]?.stringValue, "poll")
            XCTAssertNotNil(polled["resume"])

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
            XCTAssertEqual(lane["response"]?.stringValue, "Final Oracle answer")
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
            XCTAssertEqual(replayLane["response"]?.stringValue, "Final Oracle answer")
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

            let askTask = Task { @MainActor in
                try await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                    try await fixture.ask()
                }
            }
            try await fixture.harness.waitUntilOpen(count: 1)
            try await fixture.waitUntilParked()
            let server = fixture.window.mcpServer
            try await AsyncTestWait.waitUntil("observer subscribed to wake scope", timeout: 5) {
                await MainActor.run { server.test_oracleWaitScopeHasParkedObserver(executionID: execution.executionID) }
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
            let operationID = try operationID(in: woken)
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
            XCTAssertEqual(try lanes(in: collected).first?["response"]?.stringValue, "Collected after steer")
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

    // MARK: - Batch admission (Step B)

    func testBatchRejectsWaitControlsAndRequiresIdleTabNamingRunningOperations() async throws {
        try await withFixture { fixture in
            let consultations: Value = .array([
                .object(["message": .string("lane"), "model": .string(fixture.preset.name)])
            ])
            for control in ["timeout_seconds", "request_id"] {
                do {
                    _ = try await fixture.call([
                        "consultations": consultations,
                        control: control == "timeout_seconds" ? .int(0) : .string(UUID().uuidString)
                    ])
                    XCTFail("batch must reject \(control)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains(control), error.localizedDescription)
                    XCTAssertTrue(error.localizedDescription.contains("timeout_seconds:0"), error.localizedDescription)
                }
            }
            XCTAssertEqual(fixture.harness.openedStreamCount, 0)

            let pending = try await fixture.ask(["timeout_seconds": .int(0)])
            let operationID = try operationID(in: pending)
            try await fixture.harness.waitUntilOpen(count: 1)
            do {
                _ = try await fixture.call(["consultations": consultations])
                XCTFail("batch requires an idle tab")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(ChatToolErrorCode.oracleBatchRequiresIdleTab.rawValue), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(operationID.uuidString), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("No lanes were started"), error.localizedDescription)
            }
            XCTAssertEqual(fixture.harness.openedStreamCount, 1, "a rejected batch spends nothing")
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
