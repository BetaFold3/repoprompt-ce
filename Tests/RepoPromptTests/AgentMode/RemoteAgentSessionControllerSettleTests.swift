import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteAgentSessionControllerSettleTests: XCTestCase {
    func testTerminalSettleReReadReplacesPartialFinalAssistantTextOnce() async throws {
        let fullText = "final assistant text with the full tail"
        let connection = ScriptedRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>partial assistant</assistant>",
                    completed: 0
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>partial assistant</assistant>",
                    completed: 1
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>\(fullText)</assistant>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(lastAppliedSeq: 0, nextLogOffset: 0),
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

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 1
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 3
        }
        try await waitForTranscriptBatchCount(3, recorder: recorder)

        let upsertedRows = await recorder.upsertedTranscriptRows()
        XCTAssertEqual(upsertedRows.map(\.text), ["Prompt", fullText])
        let currentBinding = await controller.currentBinding()
        let binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.nextLogOffset, 1)
        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 20, 1])

        let getLogCountAfterSettle = await connection.commandCount(type: "get_log")
        XCTAssertEqual(getLogCountAfterSettle, 3)
    }

    func testAttachAndCatchUpTerminalSessionSkipsTerminalSettleReReadWithoutAppliedCompletePage() async throws {
        let connection = ScriptedRemoteAgentSessionConnection(responses: [
            "poll": [Self.snapshotPayload(status: "completed")],
            "get_log": [
                Self.logPayload(
                    offset: 1,
                    returned: 0,
                    total: 1,
                    xml: "<transcript/>",
                    completed: 1
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 1),
            connection: connection
        )
        defer {
            Task { await controller.shutdown() }
        }

        try await controller.attachAndCatchUp()

        let currentBinding = await controller.currentBinding()
        let binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.nextLogOffset, 1)
        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [1])
        XCTAssertEqual(requests.map(\.limit), [20])
    }

    func testLegacyTerminalSettleReReadHealsTruncatedFinalAssistantWithoutRemovals() async throws {
        let connection = ScriptedRemoteAgentSessionConnection(responses: [
            "get_log": [
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>partial final</assistant>",
                    completed: nil
                ),
                Self.logPayload(
                    offset: 1,
                    returned: 0,
                    total: 1,
                    xml: "<transcript/>",
                    completed: nil
                ),
                Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>full final assistant</assistant>",
                    completed: nil
                )
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(lastAppliedSeq: 0, nextLogOffset: 0),
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

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 1
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 2
        }
        try await waitForTranscriptBatchCount(2, recorder: recorder)

        let upsertedRows = await recorder.upsertedTranscriptRows()
        XCTAssertEqual(upsertedRows.map(\.text), ["Prompt", "full final assistant"])
        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 1, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 20, 1])
        let removals = await recorder.allRemovedIDs()
        XCTAssertTrue(removals.allSatisfy(\.isEmpty))
    }

    func testTerminalSettleReReadRetriesAfterTransientFetchFailure() async throws {
        let fullText = "full terminal reply after retry"
        let connection = ScriptedRemoteAgentSessionConnection(scriptedResponses: [
            "get_log": [
                .payload(Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>partial</assistant>",
                    completed: 0
                )),
                .payload(Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>partial</assistant>",
                    completed: 1
                )),
                .transportFailure("temporary terminal settle failure"),
                .payload(Self.logPayload(
                    offset: 1,
                    returned: 0,
                    total: 1,
                    xml: "<transcript/>",
                    completed: 1
                )),
                .payload(Self.logPayload(
                    offset: 0,
                    returned: 1,
                    total: 1,
                    xml: "<user>Prompt</user>\n<assistant>\(fullText)</assistant>",
                    completed: 1
                ))
            ]
        ])
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(lastAppliedSeq: 0, nextLogOffset: 0),
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

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 1
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 2,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 3
        }

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_terminal",
            sessionID: "remote-session-abc",
            seq: 3,
            payload: Self.snapshotPayload(status: "completed")
        ))
        await waitForCondition {
            await connection.commandCount(type: "get_log") >= 5
        }
        try await waitForTranscriptBatchCount(3, recorder: recorder)

        let upsertedRows = await recorder.upsertedTranscriptRows()
        XCTAssertEqual(upsertedRows.map(\.text), ["Prompt", fullText])
        let requests = await connection.getLogRequests()
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0, 1, 0])
        XCTAssertEqual(requests.map(\.limit), [20, 20, 1, 20, 1])
    }

    func testShutdownAfterFetchReturnsBeforeEmitDoesNotEmitRowsOrAdvanceCursor() async throws {
        let connection = BlockingGetLogRemoteAgentSessionConnection(response: Self.logPayload(
            offset: 0,
            returned: 1,
            total: 1,
            xml: "<assistant>Should not emit</assistant>",
            completed: 1
        ))
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(lastAppliedSeq: 0, nextLogOffset: 0),
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

        await controller.handleInboundFrame(RemoteServerFrame(
            type: "session_update",
            sessionID: "remote-session-abc",
            seq: 1,
            payload: Self.snapshotPayload(status: "running")
        ))
        await waitForCondition {
            await connection.didStartGetLog()
        }

        await controller.shutdown()
        await connection.releaseGetLog()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let transcriptRows = await recorder.allTranscriptRows()
        XCTAssertTrue(transcriptRows.isEmpty)
        let currentBinding = await controller.currentBinding()
        let binding = try XCTUnwrap(currentBinding)
        XCTAssertEqual(binding.nextLogOffset, 0)
    }

    @MainActor
    func testEnsureDerivedTranscriptCurrentForExportRefreshesTerminalStaleTranscript() async {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in SettleNoopCodexController() }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.runState = .running
        session.setItemsSilently([
            .user("Prompt", sequenceIndex: 0),
            .assistant("partial final", sequenceIndex: 1)
        ], reason: .testOverride)
        viewModel.refreshDerivedTranscriptState(for: session)
        XCTAssertTrue(AgentTranscriptIO.buildSpartanLogXML(from: session.transcript).contains("partial final"))
        XCTAssertTrue(viewModel.transcriptItems.map(\.text).contains("partial final"))

        session.runState = .completed
        session.setItemsSilently([
            .user("Prompt", sequenceIndex: 0),
            .assistant("full final assistant text", sequenceIndex: 1)
        ], reason: .testOverride)
        XCTAssertFalse(AgentTranscriptIO.buildSpartanLogXML(from: session.transcript).contains("full final assistant text"))

        let didRefresh = viewModel.ensureDerivedTranscriptCurrentForExport(tabID: tabID)

        XCTAssertTrue(didRefresh)
        let refreshedXML = AgentTranscriptIO.buildSpartanLogXML(from: session.transcript)
        XCTAssertTrue(refreshedXML.contains("full final assistant text"), refreshedXML)
        let visiblePresentationTexts = viewModel.transcriptItems.map(\.text)
        XCTAssertTrue(visiblePresentationTexts.contains("full final assistant text"), String(describing: visiblePresentationTexts))
        XCTAssertFalse(visiblePresentationTexts.contains("partial final"), String(describing: visiblePresentationTexts))
        XCTAssertEqual(session.transcript.turns.count, 1)
        XCTAssertEqual(session.transcript.turns.last?.isCompleted, true)
    }

    func testFetchLogPageSendsIncludeRowTimestampsOnlyWhenHostAdvertisesFeature() async throws {
        // Legacy host: no advertised features, so the payload key must be omitted —
        // old gateways hard-reject unknown get_log payload keys.
        let legacyConnection = ScriptedRemoteAgentSessionConnection(responses: [
            "poll": [Self.snapshotPayload(status: "completed")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)
            ]
        ])
        let legacyController = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: legacyConnection
        )
        defer { Task { await legacyController.shutdown() } }
        try await legacyController.attachAndCatchUp()
        let legacyFlags = await legacyConnection.getLogIncludeRowTimestampsFlags()
        XCTAssertFalse(legacyFlags.isEmpty)
        XCTAssertTrue(legacyFlags.allSatisfy { $0 == nil }, String(describing: legacyFlags))

        // Upgraded host: the hello_ack feature enables the opt-in flag on every fetch.
        let upgradedConnection = ScriptedRemoteAgentSessionConnection(
            responses: [
                "poll": [Self.snapshotPayload(status: "completed")],
                "get_log": [
                    Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.getLogRowTimestamps]
        )
        let upgradedController = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: upgradedConnection
        )
        defer { Task { await upgradedController.shutdown() } }
        try await upgradedController.attachAndCatchUp()
        let upgradedFlags = await upgradedConnection.getLogIncludeRowTimestampsFlags()
        XCTAssertFalse(upgradedFlags.isEmpty)
        XCTAssertTrue(upgradedFlags.allSatisfy { $0 == true }, String(describing: upgradedFlags))
    }

    func testFetchLogPageRetriesWithoutRowTimestampsAfterUnsupportedPayloadKeyAndLatches() async throws {
        // Version-skew: the host advertises the feature but rejects the payload key
        // (for example a stale gateway). The fetch must retry once without the key and
        // latch legacy behavior for every later fetch instead of failing catch-up.
        let connection = ScriptedRemoteAgentSessionConnection(
            scriptedResponses: [
                "poll": [.payload(Self.snapshotPayload(status: "completed"))],
                "get_log": [
                    .commandFailure(
                        code: "unsupported_payload_key",
                        message: "Remote operation 'get_log' does not support payload key 'include_row_timestamps'."
                    ),
                    .payload(Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)),
                    .payload(Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1))
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.getLogRowTimestamps]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        try await controller.attachAndCatchUp()

        let requests = await connection.getLogRequests()
        let flags = await connection.getLogIncludeRowTimestampsFlags()
        XCTAssertGreaterThanOrEqual(requests.count, 2, String(describing: requests))
        // First attempt opts in; the immediate retry and every later fetch omit the key.
        XCTAssertEqual(flags.first, true, String(describing: flags))
        XCTAssertEqual(requests[0].offset, requests[1].offset)
        XCTAssertTrue(flags.dropFirst().allSatisfy { $0 == nil }, String(describing: flags))
    }

    func testFetchLogPageSendsIncludeHostRowIDsOnlyWhenHostAdvertisesFeature() async throws {
        let legacyConnection = ScriptedRemoteAgentSessionConnection(responses: [
            "poll": [Self.snapshotPayload(status: "completed")],
            "get_log": [
                Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)
            ]
        ])
        let legacyController = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: legacyConnection
        )
        defer { Task { await legacyController.shutdown() } }
        try await legacyController.attachAndCatchUp()
        let legacyFlags = await legacyConnection.getLogIncludeHostRowIDsFlags()
        XCTAssertFalse(legacyFlags.isEmpty)
        XCTAssertTrue(legacyFlags.allSatisfy { $0 == nil }, String(describing: legacyFlags))

        let upgradedConnection = ScriptedRemoteAgentSessionConnection(
            responses: [
                "poll": [Self.snapshotPayload(status: "completed")],
                "get_log": [
                    Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.getLogHostRowIDs]
        )
        let upgradedController = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: upgradedConnection
        )
        defer { Task { await upgradedController.shutdown() } }
        try await upgradedController.attachAndCatchUp()
        let upgradedFlags = await upgradedConnection.getLogIncludeHostRowIDsFlags()
        XCTAssertFalse(upgradedFlags.isEmpty)
        XCTAssertTrue(upgradedFlags.allSatisfy { $0 == true }, String(describing: upgradedFlags))
    }

    func testFetchLogPageRetriesWithoutHostRowIDsAfterUnsupportedPayloadKeyAndLatches() async throws {
        let connection = ScriptedRemoteAgentSessionConnection(
            scriptedResponses: [
                "poll": [.payload(Self.snapshotPayload(status: "completed"))],
                "get_log": [
                    .commandFailure(
                        code: "unsupported_payload_key",
                        message: "Remote operation 'get_log' does not support payload key 'include_host_row_ids'."
                    ),
                    .payload(Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1)),
                    .payload(Self.logPayload(offset: 0, returned: 1, total: 1, xml: "<user>Prompt</user>", completed: 1))
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.getLogHostRowIDs]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(nextLogOffset: 0),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        try await controller.attachAndCatchUp()

        let requests = await connection.getLogRequests()
        let flags = await connection.getLogIncludeHostRowIDsFlags()
        XCTAssertGreaterThanOrEqual(requests.count, 2, String(describing: requests))
        XCTAssertEqual(flags.first, true, String(describing: flags))
        XCTAssertEqual(requests[0].offset, requests[1].offset)
        XCTAssertTrue(flags.dropFirst().allSatisfy { $0 == nil }, String(describing: flags))
    }

    func testHostRowIDLookupPopulatesFromLogAndResetsForNewSession() async throws {
        let originalSessionID = "remote-session-abc"
        let newSessionID = "remote-session-new"
        let hostRowID = UUID()
        let xml = "<user id=\"\(hostRowID.uuidString)\">Prompt</user>"
        let connection = ScriptedRemoteAgentSessionConnection(
            responses: [
                "start": [Self.snapshotPayload(status: "completed", sessionID: newSessionID)],
                "poll": [
                    Self.snapshotPayload(status: "completed", sessionID: originalSessionID),
                    Self.snapshotPayload(status: "completed", sessionID: newSessionID)
                ],
                "get_log": [
                    Self.logPayload(offset: 0, returned: 1, total: 1, xml: xml, completed: 1),
                    Self.logPayload(offset: 0, returned: 1, total: 1, xml: xml, completed: 1),
                    Self.logPayload(offset: 0, returned: 0, total: 0, xml: "<transcript/>", completed: 0)
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.getLogHostRowIDs]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(remoteSessionID: originalSessionID, nextLogOffset: 0),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }
        let clientItemID = try XCTUnwrap(
            RemoteTranscriptProjector(remoteSessionID: originalSessionID)
                .projectGetLogResponse(Self.logPayload(offset: 0, returned: 1, total: 1, xml: xml, completed: 1))
                .items.first?.id
        )

        try await controller.attachAndCatchUp()
        let mappedHostRowID = await controller.hostRowID(forClientItemID: clientItemID)
        XCTAssertEqual(mappedHostRowID, hostRowID)

        let startedSessionID = try await controller.start(
            message: "New prompt",
            modelSelectionRaw: nil,
            sessionName: nil,
            windowID: nil,
            workspaceID: nil,
            workspaceName: nil
        )
        XCTAssertEqual(startedSessionID, newSessionID)
        let resetHostRowID = await controller.hostRowID(forClientItemID: clientItemID)
        XCTAssertNil(resetHostRowID)
    }

    func testForkSendsMappedHostRowIDAndParsesSharedSessionDescriptor() async throws {
        let clientItemID = UUID()
        let hostRowID = UUID()
        let destinationSessionID = UUID().uuidString
        let connection = ScriptedRemoteAgentSessionConnection(
            responses: [
                "fork_session": [
                    .object(["status": .string("in_flight")]),
                    .object([
                        "status": .string("forked"),
                        "session": .object([
                            "session_id": .string(destinationSessionID),
                            "name": .string("Forked on host"),
                            "raw_state": .string("completed"),
                            "agent": .object([
                                "id": .string(AgentProviderKind.codexExec.rawValue),
                                "model": .string("gpt-5.4")
                            ]),
                            "parent_session_id": .string("parent-session"),
                            "last_modified": .string("2026-07-26T12:34:56.000Z"),
                            "item_count": .int(7),
                            "origin": .string("user"),
                            "is_live": .bool(true)
                        ])
                    ])
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.forkSession]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(),
            connection: connection,
            recoveryScheduler: ImmediateRemoteAgentSessionRecoveryScheduler()
        )
        defer { Task { await controller.shutdown() } }
        await controller.test_setHostRowID(hostRowID, forClientItemID: clientItemID)

        let descriptor = try await controller.fork(
            upToClientItemID: clientItemID,
            destinationAgent: AgentProviderKind.codexExec.rawValue,
            destinationModelID: "gpt-5.4",
            destinationEffort: "high"
        )

        XCTAssertEqual(descriptor.sessionID, destinationSessionID)
        XCTAssertEqual(descriptor.name, "Forked on host")
        XCTAssertEqual(descriptor.stateRaw, "completed")
        XCTAssertEqual(descriptor.agentKindRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(descriptor.agentModelRaw, "gpt-5.4")
        XCTAssertEqual(descriptor.parentSessionID, "parent-session")
        XCTAssertEqual(descriptor.itemCount, 7)
        XCTAssertEqual(descriptor.originSummary, "user")
        XCTAssertEqual(descriptor.isLive, true)
        XCTAssertNotNil(descriptor.lastModified)

        let forkFrames = await connection.frames(type: "fork_session")
        XCTAssertEqual(forkFrames.count, 2)
        XCTAssertEqual(forkFrames[0].requestID, forkFrames[1].requestID)
        let frame = try XCTUnwrap(forkFrames.first)
        XCTAssertEqual(frame.sessionID, "remote-session-abc")
        XCTAssertTrue(frame.requestID?.hasPrefix("rpce-n5-fork-") == true)
        XCTAssertEqual(frame.payload?.objectValue, [
            "up_to_item_id": .string(hostRowID.uuidString),
            "destination_agent": .string(AgentProviderKind.codexExec.rawValue),
            "destination_model_id": .string("gpt-5.4"),
            "destination_effort": .string("high")
        ])
        XCTAssertNotEqual(frame.payload?.objectValue?["up_to_item_id"], .string(clientItemID.uuidString))
    }

    func testExtractHandoffSendsMappedHostRowIDAndReturnsInlineXML() async throws {
        let clientItemID = UUID()
        let hostRowID = UUID()
        let expectedXML = "<forked_session><transcript/></forked_session>"
        let connection = ScriptedRemoteAgentSessionConnection(
            responses: [
                "extract_handoff": [
                    .object([
                        "status": .string("ok"),
                        "handoff_xml": .string(expectedXML)
                    ])
                ]
            ],
            advertisedFeatures: [RemoteWireFeatures.extractHandoff]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }
        await controller.test_setHostRowID(hostRowID, forClientItemID: clientItemID)

        let payload = try await controller.extractHandoff(
            upToClientItemID: clientItemID,
            maxTranscriptItems: 123,
            maxToolArgsCharacters: 456
        )

        XCTAssertEqual(payload, expectedXML)
        let extractFrames = await connection.frames(type: "extract_handoff")
        XCTAssertEqual(extractFrames.count, 1)
        let frame = try XCTUnwrap(extractFrames.first)
        XCTAssertEqual(frame.sessionID, "remote-session-abc")
        XCTAssertTrue(frame.requestID?.hasPrefix("rpce-n5-extract-") == true)
        XCTAssertEqual(frame.payload?.objectValue, [
            "up_to_item_id": .string(hostRowID.uuidString),
            "max_transcript_items": .int(123),
            "max_tool_args_characters": .int(456)
        ])
        XCTAssertNotEqual(frame.payload?.objectValue?["up_to_item_id"], .string(clientItemID.uuidString))
    }

    func testForkAndExtractRejectHostsWithoutTheirAdvertisedFeatures() async throws {
        let connection = ScriptedRemoteAgentSessionConnection(responses: [:])
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        do {
            _ = try await controller.fork(
                upToClientItemID: UUID(),
                destinationAgent: AgentProviderKind.codexExec.rawValue,
                destinationModelID: "gpt-5.4",
                destinationEffort: nil
            )
            XCTFail("Expected unsupported fork feature error")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "unsupported_host_feature")
            XCTAssertTrue(error.localizedDescription.contains("does not support remote session forking"))
        }

        do {
            _ = try await controller.extractHandoff(upToClientItemID: UUID())
            XCTFail("Expected unsupported extract feature error")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "unsupported_host_feature")
            XCTAssertTrue(error.localizedDescription.contains("does not support remote handoff payload extraction"))
        }
        let forkFrames = await connection.frames(type: "fork_session")
        let extractFrames = await connection.frames(type: "extract_handoff")
        XCTAssertTrue(forkFrames.isEmpty)
        XCTAssertTrue(extractFrames.isEmpty)
    }

    func testForkAndExtractRejectUnmappedClientCutoffsBeforeSending() async throws {
        let connection = ScriptedRemoteAgentSessionConnection(
            responses: [:],
            advertisedFeatures: [RemoteWireFeatures.forkSession, RemoteWireFeatures.extractHandoff]
        )
        let controller = RemoteAgentSessionController(
            binding: Self.makeBinding(),
            connection: connection
        )
        defer { Task { await controller.shutdown() } }

        do {
            _ = try await controller.fork(
                upToClientItemID: UUID(),
                destinationAgent: AgentProviderKind.codexExec.rawValue,
                destinationModelID: "gpt-5.4",
                destinationEffort: nil
            )
            XCTFail("Expected unmapped fork cutoff error")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "host_row_id_unavailable")
            XCTAssertTrue(error.localizedDescription.contains("not yet mapped"))
        }

        do {
            _ = try await controller.extractHandoff(upToClientItemID: UUID())
            XCTFail("Expected unmapped extract cutoff error")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "host_row_id_unavailable")
            XCTAssertTrue(error.localizedDescription.contains("not yet mapped"))
        }
        let forkFrames = await connection.frames(type: "fork_session")
        let extractFrames = await connection.frames(type: "extract_handoff")
        XCTAssertTrue(forkFrames.isEmpty)
        XCTAssertTrue(extractFrames.isEmpty)
    }

    private static func makeBinding(
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

    fileprivate static func snapshotPayload(status: String = "running", sessionID: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(status)]
        if let sessionID {
            payload["session_id"] = .string(sessionID)
        }
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
        if let completed {
            payload["completed_turn_count"] = .int(completed)
        }
        return .object(payload)
    }

    private enum WaitError: Error {
        case timedOut
    }

    private func waitForCondition(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalResult = await predicate()
        XCTAssertTrue(finalResult, "Timed out waiting for remote settle condition", file: file, line: line)
    }

    private func waitForTranscriptBatchCount(
        _ count: Int,
        recorder: RemoteSessionEventRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await recorder.waitForTranscriptBatchCount(count)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw WaitError.timedOut
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                XCTFail("Timed out waiting for \(count) transcript row batch(es)", file: file, line: line)
                throw error
            }
        }
    }
}

private struct ImmediateRemoteAgentSessionRecoveryScheduler: RemoteAgentSessionRecoveryScheduling {
    func sleep(seconds _: TimeInterval) async throws {}
}

private enum ScriptedRemoteResponse {
    case payload(JSONValue)
    case transportFailure(String)
    case commandFailure(code: String, message: String)
}

private actor RemoteSessionEventRecorder {
    private var transcriptRows: [[AgentChatItem]] = []
    private var removedIDs: [[UUID]] = []
    private var transcriptBatchWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: RemoteSessionEvent) {
        if case let .transcriptRows(rows, removed, _) = event {
            transcriptRows.append(rows)
            removedIDs.append(removed)
            resumeSatisfiedWaiters()
        }
    }

    func allTranscriptRows() -> [[AgentChatItem]] {
        transcriptRows
    }

    func allRemovedIDs() -> [[UUID]] {
        removedIDs
    }

    func waitForTranscriptBatchCount(_ count: Int) async {
        guard transcriptRows.count < count else { return }
        await withCheckedContinuation { continuation in
            transcriptBatchWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in transcriptBatchWaiters {
            if transcriptRows.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        transcriptBatchWaiters = remaining
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
}

private actor ScriptedRemoteAgentSessionConnection: RemoteAgentSessionConnection {
    private var responses: [String: [ScriptedRemoteResponse]]
    private var frames: [RemoteClientFrame] = []
    private let advertisedFeatures: Set<String>

    init(responses: [String: [JSONValue]], advertisedFeatures: Set<String> = []) {
        self.responses = responses.mapValues { values in
            values.map { .payload($0) }
        }
        self.advertisedFeatures = advertisedFeatures
    }

    init(scriptedResponses: [String: [ScriptedRemoteResponse]], advertisedFeatures: Set<String> = []) {
        responses = scriptedResponses
        self.advertisedFeatures = advertisedFeatures
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        if var queued = responses[frame.type], !queued.isEmpty {
            let response = queued.removeFirst()
            responses[frame.type] = queued
            switch response {
            case let .payload(payload):
                return payload
            case let .transportFailure(message):
                throw RemoteClientError.transport(message)
            case let .commandFailure(code, message):
                throw RemoteClientError.fromCommandError(code: code, message: message)
            }
        }
        return defaultResponse(for: frame)
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func supportsHostFeature(_ feature: String) -> Bool {
        advertisedFeatures.contains(feature)
    }

    func commandCount(type: String) -> Int {
        frames.count { $0.type == type }
    }

    func frames(type: String) -> [RemoteClientFrame] {
        frames.filter { $0.type == type }
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

    /// One entry per get_log request: the raw `include_row_timestamps` payload value
    /// (nil when the key was omitted).
    func getLogIncludeRowTimestampsFlags() -> [Bool?] {
        frames.filter { $0.type == "get_log" }.map { frame in
            frame.payload?.objectValue?["include_row_timestamps"]?.boolValue
        }
    }

    /// One entry per get_log request: the raw `include_host_row_ids` payload value
    /// (nil when the key was omitted).
    func getLogIncludeHostRowIDsFlags() -> [Bool?] {
        frames.filter { $0.type == "get_log" }.map { frame in
            frame.payload?.objectValue?["include_host_row_ids"]?.boolValue
        }
    }

    private func defaultResponse(for frame: RemoteClientFrame) -> JSONValue {
        switch frame.type {
        case "poll":
            RemoteAgentSessionControllerSettleTests.snapshotPayload(status: "completed")
        case "get_log":
            RemoteAgentSessionControllerSettleTests.logPayload(
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

private actor BlockingGetLogRemoteAgentSessionConnection: RemoteAgentSessionConnection {
    private let response: JSONValue
    private var frames: [RemoteClientFrame] = []
    private var getLogContinuation: CheckedContinuation<Void, Never>?
    private var startedGetLog = false

    init(response: JSONValue) {
        self.response = response
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        guard frame.type == "get_log" else {
            return RemoteAgentSessionControllerSettleTests.snapshotPayload(status: "running")
        }
        startedGetLog = true
        await withCheckedContinuation { continuation in
            getLogContinuation = continuation
        }
        return response
    }

    func ensureConnected() async throws {}
    func subscribe(sessionIDs _: [String]) async throws {}
    func unsubscribe(sessionIDs _: [String]) async throws {}

    func didStartGetLog() -> Bool {
        startedGetLog
    }

    func releaseGetLog() {
        getLogContinuation?.resume()
        getLogContinuation = nil
    }
}

private final class SettleNoopCodexController: CodexSessionControlling {
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
