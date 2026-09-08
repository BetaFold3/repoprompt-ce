import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionBranchTreeProjectionTests: XCTestCase {
    func testNestedBranchOfBranchTopologyUsesSourceSessionParents() throws {
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let root = makeRecord(id: rootID)
        let child = makeRecord(id: childID, rootID: rootID, sourceSessionID: rootID)
        let grandchild = makeRecord(id: grandchildID, rootID: rootID, sourceSessionID: childID)

        let tree = try XCTUnwrap(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [root, child, grandchild]
        ))

        XCTAssertEqual(tree.rootState, .present)
        XCTAssertEqual(tree.children(of: rootID).map(\.id), [childID])
        XCTAssertEqual(tree.children(of: childID).map(\.id), [grandchildID])
        XCTAssertEqual(tree.sourceState(for: childID), .complete)
        XCTAssertEqual(tree.sourceState(for: grandchildID), .complete)
        XCTAssertTrue(tree.lineageIncompleteIDs.isEmpty)
        XCTAssertTrue(tree.requiresExactResume)
    }

    func testIncompleteLegacyLineageAttachesToRootAndIsMarked() throws {
        let rootID = UUID()
        let branchID = UUID()
        let tree = try XCTUnwrap(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [
                makeRecord(id: rootID),
                makeRecord(id: branchID, rootID: rootID, sourceSessionID: nil)
            ]
        ))

        XCTAssertEqual(tree.rootState, .present)
        XCTAssertEqual(tree.children(of: rootID).map(\.id), [branchID])
        XCTAssertEqual(tree.sourceState(for: branchID), .sourceUnavailable)
        XCTAssertEqual(tree.lineageIncompleteIDs, [branchID])
    }

    func testDeletedIntermediateSourceRequiresFullEvidenceAndIsNotLineageIncomplete() throws {
        let rootID = UUID()
        let deletedParentID = UUID()
        let branchID = UUID()
        let records = [
            makeRecord(id: rootID),
            makeRecord(id: branchID, rootID: rootID, sourceSessionID: deletedParentID)
        ]

        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: records
        ))
        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: records,
            knownSessionIDs: [rootID, deletedParentID, branchID]
        ))

        let tree = try XCTUnwrap(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: records,
            knownSessionIDs: [rootID, branchID]
        ))

        XCTAssertEqual(tree.rootState, .present)
        XCTAssertTrue(tree.children(of: rootID).isEmpty)
        XCTAssertEqual(tree.children(of: deletedParentID).map(\.id), [branchID])
        XCTAssertEqual(tree.sourceState(for: branchID), .deletedSource(deletedParentID))
        XCTAssertTrue(tree.lineageIncompleteIDs.isEmpty)
    }

    func testDeletedRootIsSeparateFromCompleteSurvivingBranchLineage() throws {
        let rootID = UUID()
        let branchID = UUID()
        let branch = makeRecord(id: branchID, rootID: rootID, sourceSessionID: rootID)

        let tree = try XCTUnwrap(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [branch],
            knownSessionIDs: [branchID]
        ))

        XCTAssertEqual(tree.rootState, .deleted)
        XCTAssertEqual(tree.sourceState(for: branchID), .complete)
        XCTAssertEqual(tree.children(of: rootID).map(\.id), [branchID])
        XCTAssertTrue(tree.lineageIncompleteIDs.isEmpty)
        XCTAssertTrue(tree.requiresExactResume)
    }

    func testTopologyRejectsMalformedRootsCyclesAndKnownOutsideParents() {
        let rootID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let foreignRootID = UUID()
        let outsideParentID = UUID()
        let root = makeRecord(id: rootID)
        let child = makeRecord(id: firstID, rootID: rootID, sourceSessionID: rootID)

        var rootWithBranchRoot = root
        rootWithBranchRoot.branchRootSessionID = rootID
        XCTAssertNil(AgentSessionBranchTree(rootSessionID: rootID, records: [rootWithBranchRoot]))

        var selfParentingRoot = root
        selfParentingRoot.branchSourceSessionID = rootID
        XCTAssertNil(AgentSessionBranchTree(rootSessionID: rootID, records: [selfParentingRoot]))

        var rootChildCycle = root
        rootChildCycle.branchSourceSessionID = firstID
        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [rootChildCycle, child]
        ))

        let outsideRecord = makeRecord(id: outsideParentID)
        var rootWithOutsideParent = root
        rootWithOutsideParent.branchSourceSessionID = outsideParentID
        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [rootWithOutsideParent, outsideRecord],
            knownSessionIDs: [rootID, outsideParentID]
        ))

        var rootWithSourceTurn = root
        rootWithSourceTurn.branchSourceTurnID = UUID()
        XCTAssertNil(AgentSessionBranchTree(rootSessionID: rootID, records: [rootWithSourceTurn]))

        var rootWithSourceOrdinal = root
        rootWithSourceOrdinal.branchSourceTurnOrdinal = 1
        XCTAssertNil(AgentSessionBranchTree(rootSessionID: rootID, records: [rootWithSourceOrdinal]))

        var rootWithBranchDate = root
        rootWithBranchDate.branchCreatedAt = Date(timeIntervalSinceReferenceDate: 1)
        XCTAssertNil(AgentSessionBranchTree(rootSessionID: rootID, records: [rootWithBranchDate]))

        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [
                root,
                makeRecord(id: firstID, rootID: rootID, sourceSessionID: firstID)
            ]
        ))

        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [
                root,
                makeRecord(id: firstID, rootID: rootID, sourceSessionID: secondID),
                makeRecord(id: secondID, rootID: rootID, sourceSessionID: firstID)
            ]
        ))

        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [
                root,
                makeRecord(id: firstID, rootID: foreignRootID, sourceSessionID: rootID)
            ]
        ))

        XCTAssertNil(AgentSessionBranchTree(
            rootSessionID: rootID,
            records: [
                root,
                makeRecord(id: firstID, rootID: rootID, sourceSessionID: outsideParentID)
            ],
            knownSessionIDs: [rootID, firstID, outsideParentID]
        ))
    }

    private func makeRecord(
        id: UUID,
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
            workspaceID: UUID(),
            name: rootID == nil ? "Root" : "Branch",
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            itemCount: 0,
            autoEditEnabled: true,
            branchOrigin: branchOrigin
        )
        var record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/AgentSession-\(id.uuidString).json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        if rootID != nil, sourceSessionID == nil {
            record.branchSourceSessionID = nil
        }
        return record
    }
}
