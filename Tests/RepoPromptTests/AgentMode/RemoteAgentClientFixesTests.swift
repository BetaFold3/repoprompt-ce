@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentClientFixesTests: XCTestCase {
    @MainActor
    func testT8TerminalSettlementContractMappings() {
        XCTAssertEqual(
            RemoteAgentModeCoordinator.test_terminalSettlement(for: "completed").statusWord,
            "completed"
        )
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "completed").isError, false)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "cancelled").statusWord, "cancelled")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "cancelled").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "failed").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "failed").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "expired").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "expired").isError, true)
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "other").statusWord, "failed")
        XCTAssertEqual(RemoteAgentModeCoordinator.test_terminalSettlement(for: "other").isError, true)
    }

    @MainActor
    func testT9TerminalSettledOrphanIsRemovedAndFailedReprojectionOverwrites() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t9-remove")
        let runningTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t9-remove").first)

        coordinator.test_applyTranscriptRows([runningTool], to: session)
        coordinator.test_applyTerminal(status: "completed", to: session)
        XCTAssertEqual(session.items.first?.id, runningTool.id)
        XCTAssertEqual(session.items.first?.toolIsError, false)
        XCTAssertNotNil(session.items.first?.toolResultJSON)

        coordinator.test_applyTranscriptRows([], removedIDs: [runningTool.id], to: session)
        XCTAssertFalse(session.items.contains { $0.id == runningTool.id })

        let overwriteSession = makeSession(remoteSessionID: "remote-t9-overwrite")
        let initialTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t9-overwrite").first)
        let failedTool = try XCTUnwrap(project(
            xml: #"<tool_call name="context_builder"/><tool_result name="context_builder" status="failed"/>"#,
            sessionID: "remote-t9-overwrite"
        ).first)
        XCTAssertEqual(initialTool.id, failedTool.id)

        coordinator.test_applyTranscriptRows([initialTool], to: overwriteSession)
        coordinator.test_applyTerminal(status: "completed", to: overwriteSession)
        coordinator.test_applyTranscriptRows([failedTool], to: overwriteSession)

        let finalTools = overwriteSession.items.filter { $0.kind == .toolCall }
        XCTAssertEqual(finalTools.count, 1)
        let finalTool = try XCTUnwrap(finalTools.first)
        XCTAssertEqual(finalTool.id, initialTool.id)
        XCTAssertEqual(finalTool.toolIsError, true)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: finalTool), .failure)
    }

    @MainActor
    func testT10ParkedToolAbsentOnCompleteRemovesOrphanAndPreservesOptimisticUser() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t10")
        let optimistic = AgentChatItem(kind: .user, text: "local optimistic", sequenceIndex: 999)
        session.appendItem(optimistic)
        session.pendingRemoteOptimisticUserItemIDs.insert(optimistic.id)
        let parked = project(
            xml: #"<user>Prompt</user><assistant>Working</assistant><assistant>Still working</assistant><tool_call name="context_builder"/>"#,
            sessionID: "remote-t10"
        )
        let parkedTool = try XCTUnwrap(parked.first { $0.toolName == "context_builder" })
        let complete = project(
            xml: #"<user>Prompt</user><assistant>Working</assistant><assistant>Still working</assistant><assistant>Final assistant</assistant>"#,
            sessionID: "remote-t10"
        )

        coordinator.test_applyTranscriptRows(parked, to: session)
        coordinator.test_applyTranscriptRows(complete, removedIDs: [parkedTool.id], to: session)

        XCTAssertFalse(session.items.contains { $0.id == parkedTool.id })
        XCTAssertEqual(session.items.count(where: { $0.text == "Final assistant" }), 1)
        XCTAssertTrue(session.items.contains { $0.id == optimistic.id })
    }

    @MainActor
    func testT11CompleteFailedToolUpdatesInPlaceWithoutDuplicate() throws {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t11")
        let parkedTool = try XCTUnwrap(project(xml: #"<tool_call name="context_builder"/>"#, sessionID: "remote-t11").first)
        let failedTool = try XCTUnwrap(project(
            xml: #"<tool_call name="context_builder"/><tool_result name="context_builder" status="failed"/>"#,
            sessionID: "remote-t11"
        ).first)
        XCTAssertEqual(parkedTool.id, failedTool.id)

        coordinator.test_applyTranscriptRows([parkedTool], to: session)
        coordinator.test_applyTranscriptRows([failedTool], to: session)

        let tools = session.items.filter { $0.kind == .toolCall }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.id, parkedTool.id)
        XCTAssertEqual(tools.first?.toolIsError, true)
        XCTAssertEqual(try ToolCallCardStateResolver.status(for: XCTUnwrap(tools.first)), .failure)
    }

    func testT12ParkedUnionKeepsVanishedRowUntilCompleteRemoves() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Still running</assistant>", completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_update", seq: 2, status: "running", to: controller)
        try await waitForBatchCount(2, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 3, status: "completed", to: controller)
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        let vanishedID = try XCTUnwrap(batches[0].items.first?.id)
        XCTAssertTrue(batches[1].removedIDs.isEmpty)
        XCTAssertEqual(batches[2].removedIDs, [vanishedID])
    }

    func testT13LegacyPageNeverRemovesRememberedRows() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Legacy projection</assistant>", completed: nil)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_update", seq: 2, status: "running", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertTrue(batches[1].removedIDs.isEmpty)
    }

    func testT14TerminalSettleBranchRemovesStaleRowNotReemitted() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 1),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final without tool</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 2, status: "completed", to: controller)
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        let staleID = try XCTUnwrap(batches[0].items.first?.id)
        XCTAssertEqual(batches[2].removedIDs, [staleID])
    }

    func testT15RegistryResetOnStartPreventsCrossSessionRemovals() async throws {
        let connection = ScriptedConnection(responses: [
            "start": [Self.snapshotPayload(status: "completed", sessionID: "remote-new")],
            "poll": [Self.snapshotPayload(status: "completed", sessionID: "remote-new")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>New session reply</assistant>", completed: 1),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>New session reply</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(remoteSessionID: "remote-old", nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", sessionID: "remote-old", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        _ = try await controller.start(
            message: "new",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        try await waitForBatchCount(3, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertTrue(batches.dropFirst().allSatisfy(\.removedIDs.isEmpty))
    }

    func testT23TerminalSettleRereadsLastCompletePageRangeAndFreshControllerSkips() async throws {
        let twoTurnXML = "<user>One</user><assistant>First</assistant><user>Two</user><assistant>Second</assistant>"
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 2, total: 2, xml: twoTurnXML, completed: 2),
                Self.logPayload(offset: 0, returned: 2, total: 2, xml: twoTurnXML, completed: 2)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_terminal", seq: 1, status: "completed", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 2])
        let batches = await recorder.batches()
        XCTAssertEqual(batches[0].items.map(\.id), batches[1].items.map(\.id))
        XCTAssertEqual(Set(batches.flatMap { $0.items.map(\.id) }).count, 4)

        let freshConnection = ScriptedConnection(responses: [
            "poll": [Self.snapshotPayload(status: "completed")],
            "get_log": [Self.logPayload(offset: 2, returned: 0, total: 2, xml: "<transcript/>", completed: 2)]
        ])
        let freshController = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 2), connection: freshConnection)
        try await freshController.attachAndCatchUp()
        let freshRequests = await freshConnection.getLogRequests()
        XCTAssertEqual(freshRequests.map(\.offset), [2])
    }

    func testT20ProjectSnapshotStatusTextTrimming() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-t20")

        XCTAssertEqual(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("  Thinking…  ")
        ])).statusText, "Thinking…")
        XCTAssertNil(projector.projectSnapshot(.object(["status": .string("running")])).statusText)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("")
        ])).statusText)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "status_text": .string("  \n\t ")
        ])).statusText)
    }

    @MainActor
    func testT21CoordinatorUsesStatusTextOnlyForRunningState() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = makeSession(remoteSessionID: "remote-t21")

        coordinator.test_applyRunState(.running, statusText: "Thinking…", to: session)
        XCTAssertEqual(session.runningStatusText, "Thinking…")

        coordinator.test_applyRunState(.running, statusText: nil, to: session)
        XCTAssertEqual(session.runningStatusText, "Running on Studio Mac…")

        session.setRunningStatus("Existing waiting label", source: .transport)
        coordinator.test_applyRunState(.waitingForQuestion, statusText: "Queued to start", to: session)
        XCTAssertEqual(session.runningStatusText, "Existing waiting label")

        coordinator.test_applyTerminal(status: "completed", to: session)
        XCTAssertNil(session.runningStatusText)
    }

    func testT22ControllerRunStateEventIncludesStatusTextAndEquates() async {
        XCTAssertEqual(
            RemoteSessionEvent.runState(.running, pendingInteraction: nil, statusText: "Thinking…"),
            RemoteSessionEvent.runState(.running, pendingInteraction: nil, statusText: "Thinking…")
        )
        let connection = ScriptedConnection()
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running", statusText: "Thinking…")
        ))
        await waitForCondition { await recorder.runStateEvents().contains(.runState(.running, pendingInteraction: nil, statusText: "Thinking…")) }
    }

    func testCompletePageReconcilesBudgetDroppedRows() async throws {
        let connection = ScriptedConnection(responses: [
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: #"<tool_call name="context_builder"/>"#, completed: 0),
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Budget-visible assistant</assistant>", completed: 1)
            ]
        ])
        let controller = RemoteAgentSessionController(binding: Self.makeBinding(nextLogOffset: 0), connection: connection)
        let recorder = EventRecorder()
        let eventTask = Task { for await event in controller.events {
            await recorder.record(event)
        } }
        defer { eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await sendFrame(type: "session_update", seq: 1, status: "running", to: controller)
        try await waitForBatchCount(1, recorder: recorder)
        await sendFrame(type: "session_terminal", seq: 2, status: "completed", to: controller)
        try await waitForBatchCount(2, recorder: recorder)

        let batches = await recorder.batches()
        XCTAssertEqual(batches[1].removedIDs, try [XCTUnwrap(batches[0].items.first?.id)])
    }

    @MainActor
    private func makeSession(remoteSessionID: String) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.remoteHost = Self.makeBinding(remoteSessionID: remoteSessionID)
        return session
    }

    private func project(xml: String, sessionID: String, offset: Int = 0) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: sessionID)
            .projectGetLogResponse(Self.logPayload(offset: offset, returned: 1, total: 1, xml: xml, completed: 1))
            .items
    }

    private static func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String = "remote-session-abc",
        lastAppliedSeq: UInt64 = 0,
        nextLogOffset: Int = 0
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            nextLogOffset: nextLogOffset
        )
    }

    fileprivate static func snapshotPayload(status: String = "running", sessionID: String? = nil, statusText: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let sessionID { payload["session_id"] = .string(sessionID) }
        if let statusText { payload["status_text"] = .string(statusText) }
        return .object(payload)
    }

    fileprivate static func logPayload(offset: Int, returned: Int, total: Int, xml: String, completed: Int? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turn_offset": .int(offset),
            "turn_limit": .int(20),
            "returned_turn_count": .int(returned),
            "total_turns": .int(total),
            "transcript_xml": .string(xml)
        ]
        if let completed { payload["completed_turn_count"] = .int(completed) }
        return .object(payload)
    }

    private func sendFrame(
        type: String,
        seq: UInt64,
        status: String,
        sessionID: String = "remote-session-abc",
        to controller: RemoteAgentSessionController
    ) async {
        await controller.handleInboundFrame(RemoteServerFrame(
            type: type,
            sessionID: sessionID,
            seq: seq,
            payload: Self.snapshotPayload(status: status)
        ))
    }

    private func waitForCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for condition", file: file, line: line)
    }

    private func waitForBatchCount(
        _ count: Int,
        recorder: EventRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 100 {
            if await recorder.batches().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalCount = await recorder.batches().count
        XCTAssertGreaterThanOrEqual(finalCount, count, file: file, line: line)
    }
}

private actor EventRecorder {
    private(set) var transcriptBatches: [(items: [AgentChatItem], removedIDs: [UUID])] = []
    private(set) var runStates: [RemoteSessionEvent] = []

    func record(_ event: RemoteSessionEvent) {
        switch event {
        case let .transcriptRows(items, removedIDs):
            transcriptBatches.append((items, removedIDs))
        case .runState:
            runStates.append(event)
        default:
            break
        }
    }

    func batches() -> [(items: [AgentChatItem], removedIDs: [UUID])] {
        transcriptBatches
    }

    func runStateEvents() -> [RemoteSessionEvent] {
        runStates
    }
}

private actor ScriptedConnection: RemoteAgentSessionConnection {
    private var responses: [String: [JSONValue]]
    private var frames: [RemoteClientFrame] = []

    init(responses: [String: [JSONValue]] = [:]) {
        self.responses = responses
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        if var queued = responses[frame.type], !queued.isEmpty {
            let response = queued.removeFirst()
            responses[frame.type] = queued
            return response
        }
        return defaultResponse(for: frame)
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func getLogRequests() -> [(offset: Int, limit: Int)] {
        frames.compactMap { frame in
            guard frame.type == "get_log" else { return nil }
            let payload = frame.payload?.objectValue ?? [:]
            return (offset: payload["offset"]?.intValue ?? 0, limit: payload["limit"]?.intValue ?? 0)
        }
    }

    private func defaultResponse(for frame: RemoteClientFrame) -> JSONValue {
        switch frame.type {
        case "start":
            RemoteAgentClientFixesTests.snapshotPayload(sessionID: "remote-session-abc")
        case "poll":
            RemoteAgentClientFixesTests.snapshotPayload(status: "running")
        case "get_log":
            RemoteAgentClientFixesTests.logPayload(
                offset: frame.payload?.objectValue?["offset"]?.intValue ?? 0,
                returned: 0,
                total: 0,
                xml: "<transcript/>"
            )
        default:
            .object([:])
        }
    }
}
