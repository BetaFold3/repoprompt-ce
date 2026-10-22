import Foundation
@testable import RepoPromptAgentCore
import XCTest

/// Lossless restart Phase 4 built-in Claude native-history subset (`nativeEntriesSubsetV1`) and the
/// history-only import planner. Fixtures are in-memory JSONL mirroring the pinned primary-source
/// constructors (`_make_transcript_entry` / `_parallel_tool_turn`, commit
/// 3cb0c27eca8caccdc153471a1b19f97fce4ada03): `type`, `uuid`, `parentUuid`, `sessionId`, `message`,
/// and `sourceToolAssistantUUID` on parallel tool results. Fixture-backed only: this is not
/// qualification of Claude's live format. File access is injected (no home); only the live-listing
/// boundary test uses a temporary directory.
final class ClaudeSessionHistoryReaderTests: XCTestCase {
    private typealias Reader = ClaudeSessionHistoryReader

    private let sessionID = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let identityA = AgentRecoveryHistoryFileIdentity(device: 1, inode: 10, birthSeconds: 100, birthNanoseconds: 0)
    private let identityB = AgentRecoveryHistoryFileIdentity(device: 1, inode: 11, birthSeconds: 200, birthNanoseconds: 0)
    private let projects = URL(fileURLWithPath: "/fixture/home/projects", isDirectory: true)

    // MARK: Fixture builders

    private func entry(
        _ type: String,
        uuid: String,
        parent: String?,
        content: Any,
        messageID: String? = nil,
        source: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var message: [String: Any] = ["role": type, "content": content]
        if let messageID { message["id"] = messageID }
        var object: [String: Any] = [
            "type": type,
            "uuid": uuid,
            "parentUuid": parent ?? NSNull(),
            "sessionId": sessionID,
            "message": message,
            "timestamp": "2026-10-22T00:00:00.000Z",
            "cwd": "/fixture/project",
            "version": "2.0.0",
            "isSidechain": false
        ]
        if let source { object["sourceToolAssistantUUID"] = source }
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    private func user(_ uuid: String, parent: String?, _ text: String) -> [String: Any] {
        entry("user", uuid: uuid, parent: parent, content: text)
    }

    private func assistantText(_ uuid: String, parent: String?, _ text: String, messageID: String? = nil) -> [String: Any] {
        entry("assistant", uuid: uuid, parent: parent, content: [["type": "text", "text": text]], messageID: messageID ?? "msg-\(uuid)")
    }

    private func toolUse(_ uuid: String, parent: String?, id: String, name: String, messageID: String) -> [String: Any] {
        entry(
            "assistant",
            uuid: uuid,
            parent: parent,
            content: [["type": "tool_use", "id": id, "name": name, "input": ["path": "/fixture/\(id)"]]],
            messageID: messageID
        )
    }

    private func toolResult(_ uuid: String, parent: String, toolUseID: String, text: String, source: String?) -> [String: Any] {
        entry(
            "user",
            uuid: uuid,
            parent: parent,
            content: [["type": "tool_result", "tool_use_id": toolUseID, "content": text]],
            source: source
        )
    }

    private func jsonl(_ entries: [[String: Any]], trailing: String = "") -> Data {
        var data = Data()
        for object in entries {
            data.append(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            data.append(0x0A)
        }
        data.append(Data(trailing.utf8))
        return data
    }

    private func access(_ files: [(URL, AgentRecoveryHistoryFileIdentity, Data)]) -> Reader.FileAccess {
        Reader.FileAccess(
            candidates: { _, name in .listed(files.map(\.0).filter { $0.lastPathComponent == name }) },
            identity: { url in files.first { $0.0 == url }?.1 },
            capture: { url, maximumBytes in
                guard let file = files.first(where: { $0.0 == url }) else { throw Reader.CaptureError.unreadable("missing") }
                guard file.2.count <= maximumBytes else { throw Reader.CaptureError.tooLarge }
                return Reader.Capture(identity: file.1, bytes: file.2)
            }
        )
    }

    private func fileURL(project: String = "p") -> URL {
        projects.appendingPathComponent(project, isDirectory: true).appendingPathComponent("\(sessionID).jsonl")
    }

    private func read(
        _ data: Data?,
        identity: AgentRecoveryHistoryFileIdentity? = nil,
        mode: Reader.Mode,
        ledger: AgentSessionProviderHistoryRecovery? = nil
    ) -> Reader.Result {
        let files = data.map { [(fileURL(), identity ?? identityA, $0)] } ?? []
        return Reader.read(
            nativeSessionID: sessionID,
            projectsDirectories: [projects],
            mode: mode,
            ledger: ledger,
            fileAccess: access(files)
        )
    }

    private func cursor(file: AgentRecoveryHistoryFileIdentity?, offset: UInt64, importID: UUID = UUID()) -> AgentRecoveryHistoryCursor {
        AgentRecoveryHistoryCursor(
            providerRaw: Reader.providerRaw,
            conversationID: sessionID,
            importID: importID,
            file: file,
            completeLineOffset: offset,
            committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 1000))
        )
    }

    private func candidate(_ result: Reader.Result, file: StaticString = #filePath, line: UInt = #line) -> Reader.Candidate? {
        guard case let .candidate(value) = result else {
            XCTFail("expected a candidate, got \(result)", file: file, line: line)
            return nil
        }
        return value
    }

    private var fromStart: Reader.Mode {
        .importAfter(cursor(file: nil, offset: 0))
    }

    /// One parallel tool turn: two assistant tool-use entries sharing an API message ID (chained by
    /// parent), each result parented to its own call entry and naming it as its source.
    private func parallelTurn(order: [Int]) -> [[String: Any]] {
        let parts: [[String: Any]] = [
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "msg-parallel"),
            toolUse("a2", parent: "a1", id: "toolu_2", name: "Grep", messageID: "msg-parallel"),
            toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: "a1"),
            toolResult("r2", parent: "a2", toolUseID: "toolu_2", text: "two", source: "a2")
        ]
        return [user("u1", parent: nil, "read both")] + order.map { parts[$0] }
            + [assistantText("a3", parent: "r2", "done")]
    }

    // MARK: Parallel tool association (pinned orders)

    func testParallelToolTurnValidatesInEveryPinnedOrder() throws {
        let orders = [[0, 1, 2, 3], [0, 2, 1, 3], [0, 1, 3, 2], [1, 0, 3, 2]]
        var projections: [[String]] = []
        for order in orders {
            let result = read(jsonl(parallelTurn(order: order)), mode: fromStart)
            let value = try XCTUnwrap(candidate(result), "order \(order)")
            XCTAssertEqual(value.completion, .unconfirmed, "Claude completion is never confirmed")
            let calls = value.rows.filter { $0.kind == .toolCall }
            let results = value.rows.filter { $0.kind == .toolResult }
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(results.count, 2, "parallel results stay separate entries")
            for result in results {
                let call = try XCTUnwrap(calls.first { $0.toolUseID == result.toolUseID })
                XCTAssertEqual(call.toolInvocationID, result.toolInvocationID, "result joins its own call")
                XCTAssertEqual(result.toolName, call.toolName)
            }
            projections.append(value.rows.map { "\($0.nativeEntryID)|\($0.kind.rawValue)|\($0.localItemID?.uuidString ?? "-")" }.sorted())
        }
        XCTAssertEqual(Set(projections.map { $0.joined(separator: ",") }).count, 1, "identities are order-independent")
    }

    func testLastTurnResultsInReversedOrderStillAssociate() throws {
        // The final turn writes its results in [1, 0] order and ends on the second result.
        let entries = [user("u1", parent: nil, "go")]
            + [
                toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "msg-last"),
                toolUse("a2", parent: "a1", id: "toolu_2", name: "Read", messageID: "msg-last"),
                toolResult("r2", parent: "a2", toolUseID: "toolu_2", text: "two", source: "a2"),
                toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: "a1")
            ]
        let value = try XCTUnwrap(candidate(read(jsonl(entries), mode: fromStart)))
        XCTAssertEqual(value.rows.filter { $0.kind == .toolResult }.map(\.nativeEntryID), ["r2", "r1"])
    }

    func testAssistantEntriesSharingMessageIDStaySeparateRows() throws {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "first", messageID: "msg-shared"),
            toolUse("a2", parent: "a1", id: "toolu_9", name: "Read", messageID: "msg-shared"),
            toolResult("r9", parent: "a2", toolUseID: "toolu_9", text: "ok", source: "a2"),
            assistantText("a3", parent: "r9", "second")
        ]
        let value = try XCTUnwrap(candidate(read(jsonl(entries), mode: fromStart)))
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u1", "a1", "a2", "r9", "a3"])
        XCTAssertNil(value.rows[0].localItemID, "native user text is ledger-only")
        XCTAssertEqual(Set(value.rows.compactMap(\.localItemID)).count, 4)
    }

    // MARK: Whole-candidate rejection

    func testFileHistorySnapshotRejectsTheWholeCandidate() {
        let snapshot: [String: Any] = ["type": "file-history-snapshot", "messageId": "m", "snapshot": [String: String]()]
        let entries = [snapshot, user("u1", parent: nil, "hi")]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.fileHistorySnapshot(line: 1)))
    }

    func testMalformedCompleteLineRejects() {
        var data = jsonl([user("u1", parent: nil, "hi")])
        data.append(Data("{not json\n".utf8))
        XCTAssertEqual(read(data, mode: fromStart), .unsupported(.malformedLine(line: 2)))
    }

    func testUnknownEntryTypeAndMetadataReject() {
        let system = entry("system", uuid: "s1", parent: nil, content: "x")
        XCTAssertEqual(read(jsonl([system]), mode: fromStart), .unsupported(.entryType("system", line: 1)))
        let sidechain = entry("user", uuid: "u1", parent: nil, content: "x", extra: ["isSidechain": true])
        XCTAssertEqual(read(jsonl([sidechain]), mode: fromStart), .unsupported(.metadata("isSidechain", line: 1)))
        let compacted = entry("user", uuid: "u1", parent: nil, content: "x", extra: ["logicalParentUuid": "zz"])
        XCTAssertEqual(read(jsonl([compacted]), mode: fromStart), .unsupported(.metadata("logicalParentUuid", line: 1)))
    }

    func testMissingParentRejects() {
        let entries = [user("u1", parent: nil, "hi"), assistantText("a1", parent: "ghost", "x")]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.missingParent("a1")))
    }

    func testCycleRejects() {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "a2", "x"),
            assistantText("a2", parent: "a1", "y")
        ]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.cycle))
    }

    func testAmbiguousBranchRejects() {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "x"),
            assistantText("a2", parent: "u1", "y")
        ]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.ambiguousBranch("u1")))
    }

    func testAmbiguousToolAssociationRejects() {
        // A result whose source names a different call entry than its parent.
        let entries = [
            user("u1", parent: nil, "go"),
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "m"),
            toolUse("a2", parent: "a1", id: "toolu_2", name: "Read", messageID: "m"),
            toolResult("r1", parent: "a2", toolUseID: "toolu_1", text: "one", source: "a1")
        ]
        guard case .unsupported(.toolAssociation) = read(jsonl(entries), mode: fromStart) else {
            return XCTFail("expected a tool-association rejection")
        }
    }

    func testConflictingDuplicateEntryRejectsButIdenticalRepeatIsIdempotent() throws {
        let first = user("u1", parent: nil, "hi")
        let repeated = try XCTUnwrap(candidate(read(jsonl([first, first, assistantText("a1", parent: "u1", "x")]), mode: fromStart)))
        XCTAssertEqual(repeated.rows.count, 2)
        let conflicting = user("u1", parent: nil, "changed")
        XCTAssertEqual(read(jsonl([first, conflicting]), mode: fromStart), .unsupported(.conflictingDuplicate("u1")))
    }

    // MARK: Complete lines, cursor, rescan, dedup

    func testIncompleteTrailingLinePermitsTheValidatedPrefixOnly() throws {
        let complete = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")])
        var data = complete
        data.append(Data("{\"type\":\"assistant\",\"uuid\":\"a2\"".utf8))
        let value = try XCTUnwrap(candidate(read(data, mode: fromStart)))
        XCTAssertEqual(value.completeLineOffset, UInt64(complete.count))
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u1", "a1"])
    }

    func testBaselineOnMissingFileAndExistingFile() throws {
        let missing = try XCTUnwrap(candidate(read(nil, mode: .baseline)))
        XCTAssertNil(missing.file)
        XCTAssertEqual(missing.completeLineOffset, 0)
        let data = jsonl([user("u1", parent: nil, "hi")])
        let existing = try XCTUnwrap(candidate(read(data, mode: .baseline)))
        XCTAssertEqual(existing.file, identityA)
        XCTAssertEqual(existing.completeLineOffset, UInt64(data.count))
        XCTAssertTrue(existing.rows.isEmpty, "a baseline imports nothing")
        XCTAssertEqual(read(nil, mode: fromStart), .unavailable(.notFound))
    }

    func testBaselineAbsenceMustBeVerifiedNeverInferredFromAnInspectionFailure() {
        func read(_ access: Reader.FileAccess, roots: [URL]? = nil) -> Reader.Result {
            Reader.read(nativeSessionID: sessionID, projectsDirectories: roots ?? [projects], mode: .baseline, ledger: nil, fileAccess: access)
        }
        let failedRoot = Reader.FileAccess(
            candidates: { _, _ in .inspectionFailed("root unreadable") },
            identity: { _ in nil },
            capture: { _, _ in throw Reader.CaptureError.unreadable("unused") }
        )
        XCTAssertEqual(read(failedRoot), .unavailable(.inspectionFailed("root unreadable")), "a failed root is not an absent file")
        let listedURL = fileURL()
        let unidentifiedCandidate = Reader.FileAccess(
            candidates: { _, _ in .listed([listedURL]) },
            identity: { _ in nil },
            capture: { _, _ in throw Reader.CaptureError.unreadable("unused") }
        )
        guard case .unavailable(.inspectionFailed) = read(unidentifiedCandidate) else {
            return XCTFail("a listed candidate without identity is not absence")
        }
        guard case .unavailable(.inspectionFailed) = read(access([]), roots: []) else {
            return XCTFail("no authorized root establishes nothing")
        }
        XCTAssertNil(candidate(read(access([])))?.file, "verified absence (every root listed, nothing found) is a nil-file baseline")
    }

    func testBaselineRefusesAPartialTrailingRecordButAnImportWaitsForIt() throws {
        let complete = jsonl([user("u1", parent: nil, "hi")])
        let partial = jsonl([user("u1", parent: nil, "hi")], trailing: #"{"type":"assistant","uu"#)
        XCTAssertEqual(read(partial, mode: .baseline), .unavailable(.partialTrailingRecord))
        let whitespace = try XCTUnwrap(candidate(read(jsonl([user("u1", parent: nil, "hi")], trailing: " \r"), mode: .baseline)))
        XCTAssertEqual(whitespace.completeLineOffset, UInt64(complete.count), "trailing whitespace is not a record")
        let imported = try XCTUnwrap(candidate(read(partial, mode: fromStart)))
        XCTAssertEqual(imported.completeLineOffset, UInt64(complete.count), "an import decodes complete lines and waits")
    }

    func testLiveListingDistinguishesAMissingRootFromAnUninspectableOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionHistoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingRoot = root.appendingPathComponent("missing/projects", isDirectory: true)
        XCTAssertEqual(Reader.FileAccess.live.candidates([missingRoot], "\(sessionID).jsonl"), .listed([]), "a missing root holds nothing")
        let fileRoot = root.appendingPathComponent("projects-is-a-file")
        try Data("x".utf8).write(to: fileRoot)
        guard case .inspectionFailed = Reader.FileAccess.live.candidates([fileRoot], "\(sessionID).jsonl") else {
            return XCTFail("a root that cannot be listed is an inspection failure")
        }
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: projectsRoot.appendingPathComponent("stray-file"))
        XCTAssertEqual(Reader.FileAccess.live.candidates([projectsRoot], "\(sessionID).jsonl"), .listed([]))
        let file = project.appendingPathComponent("\(sessionID).jsonl")
        try jsonl([user("u1", parent: nil, "hi")]).write(to: file)
        guard case let .listed(urls) = Reader.FileAccess.live.candidates([projectsRoot], "\(sessionID).jsonl") else {
            return XCTFail("listing failed")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["\(sessionID).jsonl"])
    }

    func testSameFileImportReturnsOnlyRowsAfterTheCursor() throws {
        let prefix = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "before")])
        let full = jsonl([
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "before"),
            user("u2", parent: "a1", "more"),
            assistantText("a2", parent: "u2", "after")
        ])
        let value = try XCTUnwrap(candidate(read(full, mode: .importAfter(cursor(file: identityA, offset: UInt64(prefix.count))))))
        XCTAssertFalse(value.isRescan)
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u2", "a2"])
    }

    func testReplacementRescansAndDeduplicatesThroughTheLedger() throws {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "before"),
            user("u2", parent: "a1", "more"),
            assistantText("a2", parent: "u2", "after")
        ]
        let first = try XCTUnwrap(candidate(read(jsonl(Array(entries.prefix(2))), mode: fromStart)))
        let observation = Reader.observation(first)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 2000)
        )
        // The file is replaced (new identity) with the same history plus a new turn.
        let rescanned = try XCTUnwrap(candidate(read(
            jsonl(entries),
            identity: identityB,
            mode: .importAfter(plan.cursor),
            ledger: plan.ledger
        )))
        XCTAssertTrue(rescanned.isRescan)
        XCTAssertEqual(rescanned.rows.map(\.nativeEntryID), ["u2", "a2"], "known rows are never duplicated")
        // Truncation below the cursor also rescans.
        let truncated = jsonl(Array(entries.prefix(1)))
        XCTAssertEqual(
            read(truncated, mode: .importAfter(cursor(file: identityA, offset: 10000)), ledger: nil),
            .unavailable(.baselineLost),
            "a rescan with no ledger-known entry cannot locate the previous import"
        )
    }

    func testFileSelectionIsExactAndUnambiguous() {
        XCTAssertEqual(
            Reader.read(nativeSessionID: "NOT-A-UUID", projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: access([])),
            .unavailable(.invalidSessionID)
        )
        let data = jsonl([user("u1", parent: nil, "hi")])
        let two = access([(fileURL(project: "a"), identityA, data), (fileURL(project: "b"), identityB, data)])
        XCTAssertEqual(
            Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: two),
            .unavailable(.ambiguous(count: 2))
        )
        let sameInode = access([(fileURL(project: "a"), identityA, data), (fileURL(project: "b"), identityA, data)])
        if case .candidate = Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: sameInode) {} else {
            XCTFail("hard links to one file are one candidate")
        }
        XCTAssertEqual(
            Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: access([(fileURL(), identityA, data)]), maximumBytes: 4),
            .unavailable(.tooLarge)
        )
    }

    func testDeterministicUUIDIsStableAndVersion8() {
        let one = Reader.deterministicUUID(namespace: "ns", components: ["a", "bc"])
        XCTAssertEqual(one, Reader.deterministicUUID(namespace: "ns", components: ["a", "bc"]))
        XCTAssertNotEqual(one, Reader.deterministicUUID(namespace: "ns", components: ["ab", "c"]), "length-prefixed components")
        let bytes = one.uuid
        XCTAssertEqual(bytes.6 >> 4, 0x8)
        XCTAssertEqual(bytes.8 >> 6, 0b10)
    }

    // MARK: Planner

    func testPlannerAppendsLabelledInertRowsOnceAndRecordsTheLedger() throws {
        let value = try XCTUnwrap(candidate(read(jsonl(parallelTurn(order: [0, 1, 2, 3])), mode: fromStart)))
        let observation = Reader.observation(value)
        XCTAssertFalse(observation.completionConfirmed)
        let importID = UUID()
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: importID,
            now: Date(timeIntervalSince1970: 3000)
        )
        XCTAssertEqual(plan.outcome, .importedUnconfirmed)
        XCTAssertEqual(plan.appendedItems.first?.kind, .system)
        XCTAssertEqual(plan.appendedItems.first?.text, AgentProviderHistoryImportPlanner.recoveredLabel)
        XCTAssertEqual(plan.appendedItems.dropFirst().map(\.kind), [.toolCall, .toolCall, .toolResult, .toolResult, .assistant])
        XCTAssertEqual(plan.ledger.nativeItems.count, value.rows.count, "user text is recorded ledger-only")
        XCTAssertEqual(plan.ledger.lastImportCommit?.importID, importID)
        XCTAssertEqual(plan.importCommit, plan.ledger.lastImportCommit)
        XCTAssertEqual(plan.cursor.importID, importID)
        XCTAssertNil(plan.previousImportID)

        let replay = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: Set(plan.appendedItems.map(\.id)),
            ledger: plan.ledger,
            previousCursor: plan.cursor,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 4000)
        )
        XCTAssertTrue(replay.appendedItems.isEmpty, "a replay appends nothing")
        XCTAssertEqual(replay.ledger.nativeItems.count, plan.ledger.nativeItems.count)
        XCTAssertEqual(replay.previousImportID, importID)
    }

    func testPlannerRecordsButNeverDuplicatesRowsAlreadyInTheTranscript() throws {
        let value = try XCTUnwrap(candidate(read(jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")]), mode: fromStart)))
        let observation = Reader.observation(value)
        let existing = try XCTUnwrap(observation.rows.compactMap(\.item).first?.id)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [existing],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date()
        )
        XCTAssertTrue(plan.appendedItems.isEmpty)
        XCTAssertEqual(plan.ledger.nativeItems.compactMap(\.localItemID), [existing])
    }
}
