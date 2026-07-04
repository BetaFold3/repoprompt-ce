@testable import RepoPromptApp
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

    private func makeBinding() -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: "host-abc",
            hostDisplayName: "Studio Mac",
            remoteSessionID: "remote-session-abc",
            lastAppliedSeq: 42,
            nextLogOffset: 7
        )
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
