@testable import RepoPromptApp
import XCTest

private struct LegacyCodexBranchOrigin: Codable {
    let rootSessionID: UUID
    let sourceSessionID: UUID
    let sourceTurnID: UUID
    let sourceCodexTurnID: String
    let sourceTurnOrdinal: Int
    let createdAt: Date
}

final class AgentSessionBranchOriginPersistenceTests: XCTestCase {
    func testBranchOriginRoundTripsAtSerializationVersionSeven() throws {
        let origin = AgentSessionBranchOrigin(
            rootSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceTurnID: UUID(),
            sourceNativeTurnRef: "codex-turn-2",
            sourceProviderKind: AgentProviderKind.codexExec.rawValue,
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
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedOrigin = try XCTUnwrap(payload["branchOrigin"] as? [String: Any])

        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(AgentSession.currentSerializationVersion, 7)
        XCTAssertEqual(decoded.branchOrigin, origin)
        XCTAssertEqual(encodedOrigin["sourceCodexTurnID"] as? String, "codex-turn-2")
        XCTAssertNil(encodedOrigin["sourceNativeTurnRef"])
        XCTAssertEqual(
            encodedOrigin["sourceProviderKind"] as? String,
            AgentProviderKind.codexExec.rawValue
        )
    }

    func testLegacyCodexOriginWithoutProviderKindDefaultsDiagnosticallyAndResavesLegacyKey() throws {
        let payload = """
        {
          "rootSessionID": "00000000-0000-0000-0000-000000000401",
          "sourceSessionID": "00000000-0000-0000-0000-000000000402",
          "sourceTurnID": "00000000-0000-0000-0000-000000000403",
          "sourceCodexTurnID": "legacy-turn",
          "sourceTurnOrdinal": 4,
          "createdAt": 50
        }
        """
        let origin = try JSONDecoder().decode(
            AgentSessionBranchOrigin.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(origin.sourceNativeTurnRef, "legacy-turn")
        XCTAssertNil(origin.sourceProviderKind)
        XCTAssertEqual(
            origin.diagnosticSourceProviderKind,
            AgentProviderKind.codexExec.rawValue
        )

        let resaved = try JSONEncoder().encode(origin)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: resaved) as? [String: Any])
        XCTAssertEqual(object["sourceCodexTurnID"] as? String, "legacy-turn")
        XCTAssertNil(object["sourceNativeTurnRef"])
        XCTAssertNil(object["sourceProviderKind"])
    }

    func testOlderCodexOriginDecoderResavePreservesLegacyNativeReference() throws {
        let origin = AgentSessionBranchOrigin(
            rootSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceTurnID: UUID(),
            sourceNativeTurnRef: "native-turn",
            sourceProviderKind: AgentProviderKind.codexExec.rawValue,
            sourceTurnOrdinal: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: 50)
        )
        let currentBytes = try JSONEncoder().encode(origin)
        let legacy = try JSONDecoder().decode(LegacyCodexBranchOrigin.self, from: currentBytes)
        let legacyResavedBytes = try JSONEncoder().encode(legacy)
        let currentAfterLegacyResave = try JSONDecoder().decode(
            AgentSessionBranchOrigin.self,
            from: legacyResavedBytes
        )

        XCTAssertEqual(currentAfterLegacyResave.sourceNativeTurnRef, "native-turn")
        XCTAssertNil(currentAfterLegacyResave.sourceProviderKind)
        XCTAssertEqual(
            currentAfterLegacyResave.diagnosticSourceProviderKind,
            AgentProviderKind.codexExec.rawValue
        )
    }

    func testLegacySessionAndSchemaSixMetadataDecodeWithoutBranchLineage() throws {
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
        XCTAssertNil(index.entries.first?.branchSourceSessionID)
        XCTAssertNil(index.entries.first?.branchSourceTurnID)
        XCTAssertEqual(index.schemaVersion, 6)
        XCTAssertEqual(AgentSessionMetadataIndex.currentSchemaVersion, 7)
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
            sourceNativeTurnRef: "codex-turn",
            sourceProviderKind: AgentProviderKind.codexExec.rawValue,
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
        let branchRecord = tree.records.first(where: { $0.id == branchID })
        XCTAssertEqual(branchRecord?.branchRootSessionID, rootID)
        XCTAssertEqual(branchRecord?.branchSourceSessionID, rootID)
        XCTAssertEqual(branchRecord?.branchSourceTurnID, origin.sourceTurnID)
        XCTAssertEqual(tree.children(of: rootID).map(\.id), [branchID])
        XCTAssertTrue(tree.lineageIncompleteIDs.isEmpty)
        XCTAssertTrue(tree.requiresExactResume)
        XCTAssertTrue(result.requiresExactResume)
        XCTAssertTrue(rootResult.requiresExactResume)
    }

    func testWarmIndexTreeQueryRejectsParentBearingRootRecords() async throws {
        let service = AgentSessionDataService.shared
        let workspaceID = UUID()
        let rootID = UUID()
        let childID = UUID()
        let outsideParentID = UUID()
        let root = makeMetadataRecord(id: rootID, workspaceID: workspaceID)
        let child = makeMetadataRecord(
            id: childID,
            workspaceID: workspaceID,
            rootID: rootID,
            sourceSessionID: rootID
        )

        var selfParentingRoot = root
        selfParentingRoot.branchSourceSessionID = rootID
        try await assertWarmTreeUnavailable(
            records: [selfParentingRoot],
            containing: rootID,
            service: service
        )

        var rootChildCycle = root
        rootChildCycle.branchSourceSessionID = childID
        try await assertWarmTreeUnavailable(
            records: [rootChildCycle, child],
            containing: rootID,
            service: service
        )

        let outsideParent = makeMetadataRecord(id: outsideParentID, workspaceID: workspaceID)
        var rootWithOutsideParent = root
        rootWithOutsideParent.branchSourceSessionID = outsideParentID
        try await assertWarmTreeUnavailable(
            records: [rootWithOutsideParent, outsideParent],
            containing: rootID,
            service: service
        )
    }

    func testWarmIndexTreeQueryPreservesStandaloneNestedAndDeletedRootTopologies() async throws {
        let service = AgentSessionDataService.shared
        let workspaceID = UUID()

        let standaloneID = UUID()
        let standaloneResult = try await warmTreeResult(
            records: [makeMetadataRecord(id: standaloneID, workspaceID: workspaceID)],
            containing: standaloneID,
            service: service
        )
        guard case let .available(standaloneTree) = standaloneResult else {
            return XCTFail("Expected standalone warm-index topology")
        }
        XCTAssertEqual(standaloneTree.rootState, .present)
        XCTAssertTrue(standaloneTree.lineageIncompleteIDs.isEmpty)
        XCTAssertFalse(standaloneResult.requiresExactResume)

        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let nestedResult = try await warmTreeResult(
            records: [
                makeMetadataRecord(id: rootID, workspaceID: workspaceID),
                makeMetadataRecord(
                    id: childID,
                    workspaceID: workspaceID,
                    rootID: rootID,
                    sourceSessionID: rootID
                ),
                makeMetadataRecord(
                    id: grandchildID,
                    workspaceID: workspaceID,
                    rootID: rootID,
                    sourceSessionID: childID
                )
            ],
            containing: grandchildID,
            service: service
        )
        guard case let .available(nestedTree) = nestedResult else {
            return XCTFail("Expected nested warm-index topology")
        }
        XCTAssertEqual(nestedTree.sourceState(for: childID), .complete)
        XCTAssertEqual(nestedTree.sourceState(for: grandchildID), .complete)
        XCTAssertTrue(nestedTree.lineageIncompleteIDs.isEmpty)
        XCTAssertTrue(nestedResult.requiresExactResume)

        let deletedRootID = UUID()
        let survivingBranchID = UUID()
        let deletedRootResult = try await warmTreeResult(
            records: [
                makeMetadataRecord(
                    id: survivingBranchID,
                    workspaceID: workspaceID,
                    rootID: deletedRootID,
                    sourceSessionID: deletedRootID
                )
            ],
            containing: survivingBranchID,
            service: service
        )
        guard case let .available(deletedRootTree) = deletedRootResult else {
            return XCTFail("Expected deleted-root warm-index topology")
        }
        XCTAssertEqual(deletedRootTree.rootState, .deleted)
        XCTAssertEqual(deletedRootTree.sourceState(for: survivingBranchID), .complete)
        XCTAssertTrue(deletedRootTree.lineageIncompleteIDs.isEmpty)
        XCTAssertTrue(deletedRootResult.requiresExactResume)
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

    private func assertWarmTreeUnavailable(
        records: [AgentSessionMetadataRecord],
        containing sessionID: UUID,
        service: AgentSessionDataService
    ) async throws {
        let result = try await warmTreeResult(
            records: records,
            containing: sessionID,
            service: service
        )
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(result.requiresExactResume)
    }

    private func warmTreeResult(
        records: [AgentSessionMetadataRecord],
        containing sessionID: UUID,
        service: AgentSessionDataService
    ) async throws -> AgentSessionBranchTreeQueryResult {
        let workspace = makeTemporaryWorkspace()
        let baseFolder = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: baseFolder) }
        let sessionsFolder = baseFolder.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        let index = AgentSessionMetadataIndex(entries: records)
        try JSONEncoder().encode(index).write(
            to: sessionsFolder.appendingPathComponent("AgentSessionIndex.json"),
            options: .atomic
        )
        await service.test_clearMetadataIndexCache(forAgentSessionsFolder: sessionsFolder)
        await service.test_markMetadataIndexReconciledThisProcess(forAgentSessionsFolder: sessionsFolder)
        return await service.indexedAgentSessionBranchTree(
            containing: sessionID,
            for: workspace
        )
    }

    private func makeMetadataRecord(
        id: UUID,
        workspaceID: UUID,
        rootID: UUID? = nil,
        sourceSessionID: UUID? = nil
    ) -> AgentSessionMetadataRecord {
        let branchOrigin = rootID.map { rootID in
            AgentSessionBranchOrigin(
                rootSessionID: rootID,
                sourceSessionID: sourceSessionID ?? rootID,
                sourceTurnID: UUID(),
                sourceNativeTurnRef: "native-turn",
                sourceProviderKind: AgentProviderKind.codexExec.rawValue,
                sourceTurnOrdinal: 1,
                createdAt: Date(timeIntervalSinceReferenceDate: 1)
            )
        }
        let session = AgentSession(
            id: id,
            workspaceID: workspaceID,
            name: rootID == nil ? "Root" : "Branch",
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: branchOrigin
        )
        return AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-\(id.uuidString).json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
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
