@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentSessionTests: XCTestCase {
    func testLegacyAgentSessionJSONDecodesWithoutRemoteHostBinding() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000301",
          "serializationVersion": 6,
          "name": "Legacy Remote Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertNil(decoded.remoteHost)
        XCTAssertEqual(decoded.serializationVersion, 6)
    }

    func testAgentSessionRoundTripsRemoteHostBindingWithoutVersionBump() throws {
        let binding = makeBinding()
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000302")),
            name: "Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            remoteHost: binding,
            autoEditEnabled: false
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("remoteHost"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 6)
        XCTAssertEqual(decoded.remoteHost, binding)
    }

    func testDataServiceStubMetadataAndSidebarExposeRemoteHostBinding() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let binding = makeBinding()
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000303"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000304"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Remote Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 40),
            itemCount: 4,
            lastRunState: AgentSessionRunState.running.rawValue,
            remoteHost: binding,
            autoEditEnabled: true,
            origin: .remote(deviceID: "device-abc")
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 4
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Remote Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.remoteHost, binding)

        let meta = try XCTUnwrap(metadata.first)
        XCTAssertEqual(meta.remoteHostID, binding.hostID)
        XCTAssertEqual(meta.remoteHostName, binding.hostDisplayName)

        let sidebarEntry = try XCTUnwrap(sidebar.entriesBySessionID[sessionID])
        XCTAssertEqual(sidebarEntry.remoteHostID, binding.hostID)
        XCTAssertEqual(sidebarEntry.remoteHostName, binding.hostDisplayName)
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testMetadataIndexRemoteHostFieldsParticipateInStaleComparison() throws {
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000305")),
            name: "Indexed Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 50),
            itemCount: 2,
            remoteHost: makeBinding(),
            autoEditEnabled: true
        )
        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-00000000-0000-0000-0000-000000000305.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 52)
        )
        let sameRecord = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 53)
        )
        XCTAssertTrue(record.matchesIndexedSessionMetadata(sameRecord))

        var changed = session
        changed.remoteHost?.hostDisplayName = "Renamed Host"
        let changedRecord = AgentSessionMetadataRecord.record(
            from: changed,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 54)
        )
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedRecord))
    }

    func testLegacyMetadataIndexRecordsDecodeWithoutRemoteHostFields() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000306",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000306.json",
              "name": "Indexed Legacy Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(payload.utf8))
        let record = try XCTUnwrap(decoded.entries.first)

        XCTAssertNil(record.remoteHostID)
        XCTAssertNil(record.remoteHostName)
        XCTAssertNil(record.agentSessionMeta().remoteHostID)
        XCTAssertNil(record.agentSessionMeta().remoteHostName)
    }

    func testStartWithNewRemoteSessionResetsCountersAndAcceptsSeqOne() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(sessionID: "remote-session-new")],
            "poll": [Self.snapshotPayload()],
            "get_log": [
                Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>")
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "remote-session-old"),
            connection: connection
        )

        let sessionID = try await controller.start(
            message: "hello",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-new")
        let logOffsets = await connection.getLogOffsets()
        XCTAssertEqual(logOffsets.first, 0)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-new",
            seq: 1,
            payload: Self.snapshotPayload()
        ))
        await waitForRemoteAgentSessionCondition {
            await (controller.currentBinding())?.lastAppliedSeq == 1
        }

        let currentBinding = await controller.currentBinding()
        let binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.lastAppliedSeq, 1)
        XCTAssertEqual(binding.nextLogOffset, 0)
    }

    func testContiguousSessionUpdateTriggersLogFetch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Remote reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload()
        ))

        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Remote reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    func testRapidSessionUpdatesCoalesceLogCatchUpWork() async {
        let connection = RecordingRemoteAgentSessionConnection(getLogDelayNanoseconds: 50_000_000)
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        for seq in UInt64(1) ... UInt64(10) {
            await controller.handleInboundFrame(RemoteServerFrame(
                type: "session_update",
                sessionID: "remote-session-abc",
                seq: seq,
                payload: Self.snapshotPayload()
            ))
        }

        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertGreaterThanOrEqual(getLogCount, 1)
        XCTAssertLessThanOrEqual(getLogCount, 2)
    }

    func testSessionTerminalTriggersFinalLogFetch() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Final reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed")
        ))

        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Final reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    func testCompletedDetachedStartStillFetchesInitialReplyLog() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "completed", sessionID: "remote-session-done")],
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Initial reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        let sessionID = try await controller.start(
            message: "Halo",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: 2,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-done")
        await waitForRemoteAgentSessionCondition {
            await recorder.firstTranscriptRows() != nil
        }
        let firstRows = await recorder.firstTranscriptRows()
        let rows = try XCTUnwrap(firstRows)
        XCTAssertEqual(rows.map(\.text), ["Initial reply"])
        let getLogCount = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCount, 1)
    }

    func testStartCatchUpCapsPoisonedCompletedTurnWhileRunActive() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "start": [Self.snapshotPayload(status: "running", sessionID: "remote-session-race")],
            "poll": [Self.snapshotPayload(status: "running", sessionID: "remote-session-race")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: "", lastAppliedSeq: 0, nextLogOffset: 0),
            connection: connection
        )
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        let sessionID = try await controller.start(
            message: "Prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )

        XCTAssertEqual(sessionID, "remote-session-race")
        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 0)
        await waitForRemoteAgentSessionCondition {
            await !(recorder.allTranscriptRows()).isEmpty
        }
        let initialRows = await recorder.allTranscriptRows()
        XCTAssertEqual(initialRows.first?.map(\.text), ["Prompt"])

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-race",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed", sessionID: "remote-session-race")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }

        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows[1].map(\.text), ["Prompt", "Reply"])
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 1)
        let getLogOffsets = await connection.getLogOffsets()
        XCTAssertEqual(getLogOffsets, [0, 0])
    }

    func testCompletedRemoteLogPageConsumesWhenRunInactive() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Old reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }

        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 1)
    }

    func testWaitingRemoteTurnIsRefetchedUntilCompletedTurnCountAdvances() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Need approval</assistant>",
                    completed: 0
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>Need approval</assistant>\n<assistant>Approved reply</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 0)

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }
        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows[0].map(\.text), ["Prompt", "Need approval"])
        XCTAssertEqual(allRows[1].map(\.text), ["Prompt", "Need approval", "Approved reply"])
        XCTAssertEqual(Set(allRows[0].map(\.id)).count, allRows[0].count)
        XCTAssertEqual(Set(allRows[1].map(\.id)).count, allRows[1].count)
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 1)
        let systemMessages = await recorder.recordedSystemMessages()
        XCTAssertFalse(systemMessages.contains("Remote log page did not advance; stopped catch-up paging."))
        let getLogOffsets = await connection.getLogOffsets()
        XCTAssertEqual(getLogOffsets, [0, 0])
    }

    func testMixedCompletedAndIncompletePageIsSplitBeforeEmittingRows() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 2,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>\n<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 1,
                    returned: 1,
                    total: 2,
                    xml: "<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 1,
                    returned: 1,
                    total: 2,
                    xml: "<user>Second prompt</user>\n<assistant>Second reply</assistant>",
                    completed: 2
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 3
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 2
        }

        let parkedBindingValue = await controller.currentBinding()
        let parkedBinding = try XCTUnwrap(parkedBindingValue)
        XCTAssertEqual(parkedBinding.nextLogOffset, 1)
        let requestsAfterPark = await connection.getLogRequests()
        XCTAssertEqual(requestsAfterPark.prefix(3).map(\.offset), [0, 0, 1])
        XCTAssertEqual(requestsAfterPark.prefix(3).map(\.limit), [20, 1, 20])

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 4
        }
        await waitForRemoteAgentSessionCondition {
            await (recorder.allTranscriptRows()).count >= 3
        }

        let allRows = await recorder.allTranscriptRows()
        XCTAssertEqual(allRows.map { $0.map(\.text) }, [
            ["First prompt", "First reply"],
            ["Second prompt"],
            ["Second prompt", "Second reply"]
        ])
        let upsertedRows = await recorder.upsertedTranscriptRows()
        XCTAssertEqual(upsertedRows.count(where: { $0.text == "Second prompt" }), 1)
        let completedBindingValue = await controller.currentBinding()
        let completedBinding = try XCTUnwrap(completedBindingValue)
        XCTAssertEqual(completedBinding.nextLogOffset, 2)
    }

    func testMixedCompletedSubpageRegressionIsDiscardedWithoutAdvancing() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 2,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>\n<user>Second prompt</user>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 2,
                    xml: "<user>First prompt</user>\n<assistant>First reply</assistant>",
                    completed: 0
                )
            ]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "waiting_for_input")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 1])
        let transcriptRows = await recorder.allTranscriptRows()
        XCTAssertTrue(transcriptRows.isEmpty)
        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 0)
    }

    func testSeqGapCatchUpFailureEmitsSystemMessageOncePerFailureStreak() async {
        let connection = FailingGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await (recorder.recordedSystemMessages()).contains { $0.contains("Remote transcript catch-up failed:") }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let messages = await (recorder.recordedSystemMessages()).filter { $0.contains("Remote transcript catch-up failed:") }
        XCTAssertEqual(messages.count, 1)
    }

    func testRepeatedScheduledSessionExpiredCatchUpYieldsOnce() async {
        let connection = SessionExpiredGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await recorder.sessionExpiredCount() == 1
        }
        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let expiredCount = await recorder.sessionExpiredCount()
        XCTAssertEqual(expiredCount, 1)
    }

    func testScheduledCatchUpFailureEmitsSystemMessageOncePerFailureStreak() async {
        let connection = FailingGetLogRemoteAgentSessionConnection()
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        let recorder = RemoteSessionEventRecorder()
        let eventTask = Task {
            for await event in controller.events {
                await recorder.record(event)
            }
        }
        defer {
            eventTask.cancel()
            Task { await controller.shutdown() }
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await (recorder.recordedSystemMessages()).contains { $0.contains("Remote transcript catch-up failed:") }
        }
        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "running")
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let messages = await (recorder.recordedSystemMessages()).filter { $0.contains("Remote transcript catch-up failed:") }
        XCTAssertEqual(messages.count, 1)
    }

    func testLogPageWithoutCompletedTurnCountAdvancesCursorCompatibly() async throws {
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "get_log": [Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<assistant>Legacy reply</assistant>")]
        ])
        let controller = RemoteAgentSessionController(binding: makeBinding(lastAppliedSeq: 0, nextLogOffset: 0), connection: connection)
        defer { Task { await controller.shutdown() } }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            requestID: nil,
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForRemoteAgentSessionCondition {
            await connection.commandCount(type: "get_log") >= 1
        }
        let bindingValue = await controller.currentBinding()
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.nextLogOffset, 1)
    }

    func testRemoteTurnPolicySteersCompletedSessionWhenRemoteSessionIDExists() {
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .idle,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertFalse(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .waitingForQuestion,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: nil
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .completed,
            remoteSessionID: "  \n"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .failed,
            remoteSessionID: "remote-session-abc"
        ))
        XCTAssertTrue(AgentModeViewModel.shouldStartRemoteTurn(
            runState: .cancelled,
            remoteSessionID: "remote-session-abc"
        ))
    }

    func testRemoteStartSessionNameDerivationUsesDefaultTitlesOnly() {
        let derived = AgentSessionTitleNaming.sessionNameForRemoteStart(
            currentTitle: "T10",
            userText: "Fix the flaky auth test by avoiding sleeps in worker startup"
        )
        XCTAssertEqual(derived, "Fix the flaky auth test by avoiding")
        XCTAssertLessThanOrEqual(derived.count, 40)

        XCTAssertEqual(
            AgentSessionTitleNaming.sessionNameForRemoteStart(
                currentTitle: "Customer Chosen Title",
                userText: "Fix the flaky auth test"
            ),
            "Customer Chosen Title"
        )
        XCTAssertEqual(
            AgentSessionTitleNaming.sessionNameForRemoteStart(
                currentTitle: "T11",
                userText: "   \nSecond line should not be used"
            ),
            "T11"
        )
    }

    @MainActor
    func testCoordinatorAdoptsHostSessionNameForDefaultTitleAndUpdatesIndex() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T10")

        fixture.coordinator.test_applyMetadata(sessionName: "  Host Derived Session  ", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "Host Derived Session")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "Host Derived Session")
    }

    @MainActor
    func testCoordinatorDoesNotOverwriteUserTypedSessionName() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "User Typed Session")

        fixture.coordinator.test_applyMetadata(sessionName: "Host Suggested Session", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "User Typed Session")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "User Typed Session")
    }

    @MainActor
    func testCoordinatorReadoptsPreviouslyAdoptedHostSessionName() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T12")

        fixture.coordinator.test_applyMetadata(sessionName: "Host First Name", tabID: fixture.tabID)
        fixture.coordinator.test_applyMetadata(sessionName: "Host Better Name", tabID: fixture.tabID)

        XCTAssertEqual(fixture.viewModel.resolvedSessionDisplayName(for: fixture.tabID), "Host Better Name")
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "Host Better Name")
    }

    @MainActor
    func testChannelClosingReasonSurfacesAsBannerAndDedupedSystemRows() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.remoteHost = makeBinding()
        session.runState = .running

        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(session.runningStatusText, "Remote reconnecting (app_link_unavailable)…")
        XCTAssertEqual(
            systemMessages(in: session),
            ["Remote channel degraded: app_link_unavailable. Reconnecting…"]
        )

        coordinator.test_applyChannel(.init(kind: .connected), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(systemMessages(in: session).count(where: { $0.contains("app_link_unavailable") }), 2)
    }

    @MainActor
    func testBindingRequiredErrorUsesFriendlyRemoteCopy() {
        let error = RemoteClientError.fromCommandError(
            code: "binding_required",
            message: "Call bind_context with {\"op\":\"bind\"} before using agent_run."
        )

        let description = RemoteAgentModeCoordinator.describe(error)

        XCTAssertEqual(
            description,
            "The host couldn't route this message to its window. Try again — if it keeps failing, the session's window may have been closed on the host."
        )
        XCTAssertFalse(description.contains("bind_context"))
    }

    func testListChildSessionsSendsParentFilterAndParsesDescriptors() async throws {
        let parentRemoteID = "11111111-1111-1111-1111-111111111111"
        let childRemoteID = "22222222-2222-2222-2222-222222222222"
        let siblingRemoteID = "33333333-3333-3333-3333-333333333333"
        let connection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [Self.listSessionsPayload(children: [
                Self.sessionDescriptorPayload(
                    sessionID: childRemoteID,
                    name: "Child Worker",
                    state: "running",
                    agentID: AgentProviderKind.codexExec.rawValue,
                    model: "codex",
                    parentSessionID: parentRemoteID
                ),
                Self.sessionDescriptorPayload(
                    sessionID: siblingRemoteID,
                    name: "Sibling Worker",
                    state: "completed",
                    agentID: AgentProviderKind.claudeCode.rawValue,
                    model: "claude",
                    parentSessionID: "44444444-4444-4444-4444-444444444444"
                )
            ])]
        ])
        let controller = RemoteAgentSessionController(
            binding: makeBinding(remoteSessionID: parentRemoteID),
            connection: connection
        )

        let children = try await controller.listChildSessions()

        XCTAssertEqual(children.count, 1)
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(child.sessionID, childRemoteID)
        XCTAssertEqual(child.name, "Child Worker")
        XCTAssertEqual(child.stateRaw, "running")
        XCTAssertEqual(child.agentKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(child.agentModelRaw, "codex")
        XCTAssertEqual(child.parentSessionID, parentRemoteID)
        let frames = await connection.frames(type: "list_sessions")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertNil(frame.sessionID)
        XCTAssertEqual(frame.payload?.objectValue?["parent_session_id"]?.stringValue, parentRemoteID)
        XCTAssertEqual(frame.payload?.objectValue?["limit"]?.intValue, 500)
    }

    @MainActor
    func testCoordinatorMaterializesRemoteChildrenFromListSessionsAndDedupes() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let childRemoteID = UUID()
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: childRemoteID.uuidString,
                name: "Child Worker",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [childListPayload, childListPayload]
        ])
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        try fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        defer { fixture.coordinator.stop(tabID: fixture.tabID) }
        var attachedRemoteSessionIDs: [String] = []
        fixture.coordinator.test_setMaterializedRemoteChildAttachHandler { childSession in
            if let remoteSessionID = childSession.remoteHost?.remoteSessionID {
                attachedRemoteSessionIDs.append(remoteSessionID)
            }
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)

        await waitForRemoteCoordinatorLifecycle {
            fixture.viewModel.sessions.values.contains { $0.remoteHost?.remoteSessionID == childRemoteID.uuidString }
        }
        let listFrames = await recordingConnection.frames(type: "list_sessions")
        let firstListFrame = try XCTUnwrap(listFrames.first)
        XCTAssertEqual(firstListFrame.payload?.objectValue?["parent_session_id"]?.stringValue, parentRemoteID.uuidString)
        XCTAssertEqual(firstListFrame.payload?.objectValue?["limit"]?.intValue, 500)
        let materializedChildren = fixture.viewModel.sessions.values.filter {
            $0.remoteHost?.remoteSessionID == childRemoteID.uuidString
        }
        XCTAssertEqual(materializedChildren.count, 1)
        let childSession = try XCTUnwrap(materializedChildren.first)
        XCTAssertEqual(childSession.activeAgentSessionID, childRemoteID)
        XCTAssertEqual(childSession.parentSessionID, fixture.sessionID)
        XCTAssertEqual(childSession.remoteHost?.hostID, parentSession.remoteHost?.hostID)
        XCTAssertEqual(childSession.remoteHost?.remoteSessionID, childRemoteID.uuidString)
        XCTAssertEqual(fixture.viewModel.test_ownerValidatedSessionIndex[childRemoteID]?.parentSessionID, fixture.sessionID)
        XCTAssertEqual(attachedRemoteSessionIDs, [childRemoteID.uuidString])

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 2
        }
        XCTAssertEqual(
            fixture.viewModel.sessions.values.count(where: { $0.remoteHost?.remoteSessionID == childRemoteID.uuidString }),
            1
        )
        XCTAssertEqual(attachedRemoteSessionIDs, [childRemoteID.uuidString])
    }

    @MainActor
    func testStopClearsStartSessionNameRecord() async throws {
        let fixture = try await makeRemoteNamingFixture(tabTitle: "T10")
        fixture.coordinator.test_recordStartSessionName("Derived Name", tabID: fixture.tabID)
        XCTAssertEqual(fixture.coordinator.test_startSessionNameRecord(tabID: fixture.tabID), "Derived Name")

        fixture.coordinator.stop(tabID: fixture.tabID)

        XCTAssertNil(fixture.coordinator.test_startSessionNameRecord(tabID: fixture.tabID))
    }

    @MainActor
    func testStoppedParentDoesNotMaterializeChildrenFromLateDiscovery() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let childRemoteID = UUID()
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: childRemoteID.uuidString,
                name: "Child Worker",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(
            responses: ["list_sessions": [childListPayload]],
            commandDelayNanosecondsByType: ["list_sessions": 150_000_000]
        )
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        var attachedRemoteSessionIDs: [String] = []
        fixture.coordinator.test_setMaterializedRemoteChildAttachHandler { childSession in
            if let remoteSessionID = childSession.remoteHost?.remoteSessionID {
                attachedRemoteSessionIDs.append(remoteSessionID)
            }
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 1
        }

        fixture.coordinator.stop(tabID: fixture.tabID)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(fixture.viewModel.sessions.values.contains {
            $0.remoteHost?.remoteSessionID == childRemoteID.uuidString
        })
        XCTAssertTrue(attachedRemoteSessionIDs.isEmpty)
        let counts = fixture.coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
    }

    @MainActor
    func testCoordinatorReportsRemoteChildMaterializationFailureOnce() async throws {
        let fixture = try await makeRemoteNamingFixture(
            tabTitle: "Remote Parent",
            childDiscoveryDebounceInterval: 0
        )
        let parentRemoteID = UUID()
        let invalidChildRemoteID = "not-a-child-uuid"
        let parentSession = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        parentSession.remoteHost = makeBinding(remoteSessionID: parentRemoteID.uuidString)
        let childListPayload = Self.listSessionsPayload(children: [
            Self.sessionDescriptorPayload(
                sessionID: invalidChildRemoteID,
                name: "Broken Child",
                state: "running",
                agentID: AgentProviderKind.codexExec.rawValue,
                model: "codex",
                parentSessionID: parentRemoteID.uuidString
            )
        ])
        let recordingConnection = RecordingRemoteAgentSessionConnection(responses: [
            "list_sessions": [childListPayload, childListPayload]
        ])
        let parentController = try RemoteAgentSessionController(
            binding: XCTUnwrap(parentSession.remoteHost),
            connection: recordingConnection
        )
        let fanoutConnection = RemoteHostConnection(hostID: parentSession.remoteHost?.hostID ?? "host-abc")
        fixture.coordinator.test_attachController(
            tabID: fixture.tabID,
            hostID: parentSession.remoteHost?.hostID ?? "host-abc",
            controller: parentController,
            connection: fanoutConnection
        )
        defer { fixture.coordinator.stop(tabID: fixture.tabID) }
        let expectedMessage = "Remote child session materialization failed for '\(invalidChildRemoteID)'."

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteCoordinatorLifecycle {
            self.systemMessages(in: parentSession).contains(expectedMessage)
        }

        fixture.coordinator.test_requestChildSessionDiscovery(tabID: fixture.tabID)
        await waitForRemoteAgentSessionCondition {
            await recordingConnection.commandCount(type: "list_sessions") >= 2
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(systemMessages(in: parentSession).count(where: { $0 == expectedMessage }), 1)
    }

    @MainActor
    func testStoppingLastRemoteTabsReleasesControllersAndFanoutTasks() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(record)
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let coordinator = RemoteAgentModeCoordinator()
        let firstTabID = UUID()
        let secondTabID = UUID()
        var firstController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-1"),
            connection: connection
        )
        var secondController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-2"),
            connection: connection
        )
        let weakFirstController = RemoteAgentSessionWeakBox(firstController)
        let weakSecondController = RemoteAgentSessionWeakBox(secondController)

        try coordinator.test_attachController(
            tabID: firstTabID,
            hostID: record.id,
            controller: XCTUnwrap(firstController),
            connection: connection
        )
        try coordinator.test_attachController(
            tabID: secondTabID,
            hostID: record.id,
            controller: XCTUnwrap(secondController),
            connection: connection
        )

        var counts = coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 2)
        XCTAssertEqual(counts.eventTasks, 2)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 2)

        coordinator.stop(tabID: firstTabID)
        firstController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakFirstController.value == nil && coordinator.test_lifecycleCounts().controllers == 1
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakFirstController.value)
        XCTAssertEqual(counts.controllers, 1)
        XCTAssertEqual(counts.eventTasks, 1)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 1)

        coordinator.stop(tabID: secondTabID)
        secondController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakSecondController.value == nil && coordinator.test_lifecycleCounts().controllers == 0
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakSecondController.value)
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.eventTasks, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
        XCTAssertEqual(counts.tabHostBindings, 0)
    }

    @MainActor
    private func makeRemoteNamingFixture(
        tabTitle: String,
        childDiscoveryDebounceInterval: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> RemoteNamingFixture {
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Remote Naming",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: tabTitle, activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        prompt.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in RemoteAgentSessionNoopCodexController() }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: prompt,
            workspaceManager: workspaceManager
        )
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.remoteHost = makeBinding()
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        let entry = AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: tabTitle,
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            lastRunStateRaw: session.runState.rawValue,
            itemCount: 0,
            agentKindRaw: session.selectedAgent.rawValue,
            agentModelRaw: session.selectedModelRaw,
            agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: session.remoteHost?.hostID,
            remoteHostName: session.remoteHost?.hostDisplayName,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        let owner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        viewModel.test_installSessionIndexSnapshot(
            [sessionID: entry],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        XCTAssertEqual(viewModel.resolvedSessionDisplayName(for: tabID), tabTitle, file: file, line: line)

        let coordinator = RemoteAgentModeCoordinator(childDiscoveryDebounceInterval: childDiscoveryDebounceInterval)
        coordinator.attach(viewModel: viewModel)
        return RemoteNamingFixture(
            tabID: tabID,
            sessionID: sessionID,
            viewModel: viewModel,
            coordinator: coordinator,
            prompt: prompt,
            workspaceManager: workspaceManager
        )
    }

    @MainActor
    private func systemMessages(in session: AgentModeViewModel.TabSession) -> [String] {
        session.items.filter { $0.kind == .system }.map(\.text)
    }

    @MainActor
    private func waitForRemoteCoordinatorLifecycle(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate(), "Timed out waiting for remote coordinator lifecycle cleanup", file: file, line: line)
    }

    private func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String = "remote-session-abc",
        lastAppliedSeq: UInt64 = 42,
        nextLogOffset: Int = 7
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            nextLogOffset: nextLogOffset
        )
    }

    private struct RemoteNamingFixture {
        let tabID: UUID
        let sessionID: UUID
        let viewModel: AgentModeViewModel
        let coordinator: RemoteAgentModeCoordinator
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
    }

    private final class RemoteAgentSessionWeakBox<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value?) {
            self.value = value
        }
    }

    private static func snapshotPayload(status: String = "running", sessionID: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let sessionID {
            payload["session_id"] = .string(sessionID)
        }
        return .object(payload)
    }

    private static func listSessionsPayload(children: [JSONValue]) -> JSONValue {
        .object(["sessions": .array(children)])
    }

    private static func sessionDescriptorPayload(
        sessionID: String,
        name: String,
        state: String,
        agentID: String,
        model: String,
        parentSessionID: String
    ) -> JSONValue {
        .object([
            "session_id": .string(sessionID),
            "name": .string(name),
            "state": .string(state),
            "agent": .object([
                "id": .string(agentID),
                "model": .string(model)
            ]),
            "parent_session_id": .string(parentSessionID)
        ])
    }

    private static func logPayload(offset: Int, returned: Int, total: Int, xml: String, completed: Int? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "turn_offset": .int(offset),
            "returned_turn_count": .int(returned),
            "total_turns": .int(total),
            "transcript_xml": .string(xml)
        ]
        if let completed {
            payload["completed_turn_count"] = .int(completed)
        }
        return .object(payload)
    }

    private func waitForRemoteAgentSessionCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for remote agent session condition", file: file, line: line)
    }

    private actor RemoteSessionEventRecorder {
        private var transcriptRows: [[AgentChatItem]] = []
        private var systemMessages: [String] = []
        private var expiredCount = 0

        func record(_ event: RemoteSessionEvent) {
            switch event {
            case let .transcriptRows(rows):
                transcriptRows.append(rows)
            case let .systemMessage(message):
                systemMessages.append(message)
            case .sessionExpired:
                expiredCount += 1
            default:
                break
            }
        }

        func firstTranscriptRows() -> [AgentChatItem]? {
            transcriptRows.first
        }

        func allTranscriptRows() -> [[AgentChatItem]] {
            transcriptRows
        }

        func upsertedTranscriptRows() -> [AgentChatItem] {
            var rowsByID: [UUID: AgentChatItem] = [:]
            var orderedIDs: [UUID] = []
            for batch in transcriptRows {
                for row in batch {
                    if rowsByID[row.id] == nil {
                        orderedIDs.append(row.id)
                    }
                    rowsByID[row.id] = row
                }
            }
            return orderedIDs.compactMap { rowsByID[$0] }
        }

        func recordedSystemMessages() -> [String] {
            systemMessages
        }

        func sessionExpiredCount() -> Int {
            expiredCount
        }
    }

    private struct RemoteLogFailure: Error, CustomStringConvertible {
        var description: String {
            "synthetic log failure"
        }
    }

    private actor FailingGetLogRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            if frame.type == "get_log" {
                throw RemoteLogFailure()
            }
            return RemoteAgentSessionTests.snapshotPayload()
        }

        func ensureConnected() async throws {}
        func subscribe(sessionIDs _: [String]) async throws {}
    }

    private actor SessionExpiredGetLogRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            if frame.type == "get_log" {
                throw RemoteClientError.sessionExpired(.init(code: "session_expired", message: "expired"))
            }
            return RemoteAgentSessionTests.snapshotPayload()
        }

        func ensureConnected() async throws {}
        func subscribe(sessionIDs _: [String]) async throws {}
    }

    private actor RecordingRemoteAgentSessionConnection: RemoteAgentSessionConnection {
        private var responses: [String: [JSONValue]]
        private let getLogDelayNanoseconds: UInt64
        private let commandDelayNanosecondsByType: [String: UInt64]
        private var frames: [RemoteClientFrame] = []
        private var subscribedSessionIDs: [[String]] = []
        private var ensureConnectedCallCount = 0

        init(
            responses: [String: [JSONValue]] = [:],
            getLogDelayNanoseconds: UInt64 = 0,
            commandDelayNanosecondsByType: [String: UInt64] = [:]
        ) {
            self.responses = responses
            self.getLogDelayNanoseconds = getLogDelayNanoseconds
            self.commandDelayNanosecondsByType = commandDelayNanosecondsByType
        }

        func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
            frames.append(frame)
            if frame.type == "get_log", getLogDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: getLogDelayNanoseconds)
            }
            if let delay = commandDelayNanosecondsByType[frame.type], delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if var queued = responses[frame.type], !queued.isEmpty {
                let response = queued.removeFirst()
                responses[frame.type] = queued
                return response
            }
            return defaultResponse(for: frame)
        }

        func ensureConnected() async throws {
            ensureConnectedCallCount += 1
        }

        func subscribe(sessionIDs: [String]) async throws {
            subscribedSessionIDs.append(sessionIDs)
        }

        func commandCount(type: String) -> Int {
            frames.count { $0.type == type }
        }

        func frames(type: String) -> [RemoteClientFrame] {
            frames.filter { $0.type == type }
        }

        func getLogOffsets() -> [Int] {
            frames.compactMap { frame in
                guard frame.type == "get_log" else { return nil }
                return frame.payload?.objectValue?["offset"]?.intValue
            }
        }

        func getLogRequests() -> [(offset: Int, limit: Int)] {
            frames.compactMap { frame in
                guard frame.type == "get_log" else { return nil }
                let payload = frame.payload?.objectValue ?? [:]
                return (
                    offset: payload["offset"]?.intValue ?? 0,
                    limit: payload["limit"]?.intValue ?? 0
                )
            }
        }

        private func defaultResponse(for frame: RemoteClientFrame) -> JSONValue {
            switch frame.type {
            case "start":
                RemoteAgentSessionTests.snapshotPayload(sessionID: "remote-session-abc")
            case "poll":
                RemoteAgentSessionTests.snapshotPayload()
            case "get_log":
                RemoteAgentSessionTests.logPayload(
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

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAgentSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Agent Session Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}

private final class RemoteAgentSessionNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
