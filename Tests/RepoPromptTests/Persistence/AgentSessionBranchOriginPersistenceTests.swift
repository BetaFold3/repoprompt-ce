@testable import RepoPromptApp
import XCTest

final class AgentSessionBranchOriginPersistenceTests: XCTestCase {
    func testBranchOriginRoundTripsAtSerializationVersionSeven() throws {
        let origin = AgentSessionBranchOrigin(
            rootSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceTurnID: UUID(),
            sourceCodexTurnID: "codex-turn-2",
            sourceTurnOrdinal: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: 50)
        )
        let session = AgentSession(
            name: "Branch",
            savedAt: Date(timeIntervalSinceReferenceDate: 60),
            autoEditEnabled: true,
            branchOrigin: origin
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(AgentSession.currentSerializationVersion, 7)
        XCTAssertEqual(decoded.branchOrigin, origin)
    }

    func testLegacySessionAndMetadataDecodeWithoutBranchLineage() throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000301",
          "serializationVersion": 7,
          "name": "Root",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """
        let metadataPayload = """
        {
          "schemaVersion": 6,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000301",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000301.json",
              "name": "Root",
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

        let session = try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8))
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(metadataPayload.utf8))

        XCTAssertNil(session.branchOrigin)
        XCTAssertNil(index.entries.first?.branchRootSessionID)
        XCTAssertEqual(AgentSessionMetadataIndex.currentSchemaVersion, 6)
    }

    func testStubRebuildAndTreeQueryExposeBranchRoot() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let rootID = UUID()
        let branchID = UUID()
        let root = AgentSession(
            id: rootID,
            workspaceID: workspace.id,
            name: "Root",
            itemCount: 0,
            autoEditEnabled: true
        )
        let origin = AgentSessionBranchOrigin(
            rootSessionID: rootID,
            sourceSessionID: rootID,
            sourceTurnID: UUID(),
            sourceCodexTurnID: "codex-turn",
            sourceTurnOrdinal: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 70)
        )
        let branch = AgentSession(
            id: branchID,
            workspaceID: workspace.id,
            name: "Branch",
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: origin
        )

        _ = try await service.saveAgentSession(
            root,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let singletonResult = await service.agentSessionBranchTree(containing: rootID, for: workspace)
        XCTAssertFalse(singletonResult.requiresExactResume)

        let branchURL = try await service.saveAgentSession(
            branch,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let stub = try await service.loadAgentSessionStub(from: branchURL)
        let result = await service.agentSessionBranchTree(containing: branchID, for: workspace)
        let rootResult = await service.agentSessionBranchTree(containing: rootID, for: workspace)

        XCTAssertNil(root.branchOrigin)
        XCTAssertEqual(stub.branchOrigin, origin)
        guard case let .available(tree) = result else {
            return XCTFail("Expected an authoritative branch tree")
        }
        XCTAssertEqual(tree.rootSessionID, rootID)
        XCTAssertEqual(Set(tree.records.map(\.id)), [rootID, branchID])
        XCTAssertEqual(tree.records.first(where: { $0.id == branchID })?.branchRootSessionID, rootID)
        XCTAssertTrue(tree.requiresExactResume)
        XCTAssertTrue(result.requiresExactResume)
        XCTAssertTrue(rootResult.requiresExactResume)
    }

    func testTreeQueryFailsClosedWhenAnySessionCannotBeIndexed() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let root = AgentSession(
            workspaceID: workspace.id,
            name: "Root",
            itemCount: 0,
            autoEditEnabled: true
        )
        let rootURL = try await service.saveAgentSession(
            root,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let corruptID = UUID()
        let corruptURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent("AgentSession-\(corruptID.uuidString).json")
        try Data("{ invalid".utf8).write(to: corruptURL)

        let result = await service.agentSessionBranchTree(containing: root.id, for: workspace)

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(result.requiresExactResume)
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionBranchOriginPersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Branch Origin Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
