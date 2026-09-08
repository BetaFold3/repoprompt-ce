import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionMetadataIndexLineageTests: XCTestCase {
    func testMetadataProjectionIncludesBranchSourceIdentifiers() {
        let rootID = UUID()
        let sourceSessionID = UUID()
        let sourceTurnID = UUID()
        let session = AgentSession(
            id: UUID(),
            workspaceID: UUID(),
            name: "Nested branch",
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: AgentSessionBranchOrigin(
                rootSessionID: rootID,
                sourceSessionID: sourceSessionID,
                sourceTurnID: sourceTurnID,
                sourceNativeTurnRef: "native-turn",
                sourceProviderKind: AgentProviderKind.codexExec.rawValue,
                sourceTurnOrdinal: 3,
                createdAt: Date(timeIntervalSinceReferenceDate: 10)
            )
        )

        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-\(session.id.uuidString).json"),
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 11)
        )

        XCTAssertEqual(record.branchRootSessionID, rootID)
        XCTAssertEqual(record.branchSourceSessionID, sourceSessionID)
        XCTAssertEqual(record.branchSourceTurnID, sourceTurnID)
    }

    func testSchemaSixIndexRebuildsLargeStubFolderWithinLaunchCeiling() async throws {
        let stubCount = 2000
        let launchBlockingCeiling: TimeInterval = 15
        let baseFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionMetadataIndexLineageTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsFolder = baseFolder.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseFolder) }

        for ordinal in 0 ..< stubCount {
            let id = UUID()
            let payload = """
            {"id":"\(id.uuidString)","serializationVersion":7,"name":"Stub \(ordinal)","savedAt":0,"itemCount":0,"autoEditEnabled":true}
            """
            try Data(payload.utf8).write(
                to: sessionsFolder.appendingPathComponent("AgentSession-\(id.uuidString).json")
            )
        }
        let staleIndex = AgentSessionMetadataIndex(schemaVersion: 6, entries: [])
        try JSONEncoder().encode(staleIndex).write(
            to: sessionsFolder.appendingPathComponent("AgentSessionIndex.json"),
            options: .atomic
        )

        let workspace = WorkspaceModel(
            name: "Large metadata rebuild",
            repoPaths: ["/tmp/repo"],
            customStoragePath: baseFolder
        )
        let service = AgentSessionDataService.shared
        await service.test_clearMetadataIndexCache(forAgentSessionsFolder: sessionsFolder)

        let startedAt = Date()
        let records = try await service.sidebarStreamMetadataRecords(for: workspace)
        let duration = Date().timeIntervalSince(startedAt)
        let durationMS = Int((duration * 1000).rounded())
        print("AgentSessionMetadataIndexLineageTests rebuild size=\(stubCount) duration_ms=\(durationMS)")

        let rebuiltData = try Data(
            contentsOf: sessionsFolder.appendingPathComponent("AgentSessionIndex.json")
        )
        let rebuiltIndex = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: rebuiltData)
        XCTAssertEqual(records.count, stubCount)
        XCTAssertEqual(rebuiltIndex.schemaVersion, 7)
        XCTAssertEqual(rebuiltIndex.entries.count, stubCount)
        XCTAssertLessThan(duration, launchBlockingCeiling)
    }
}
