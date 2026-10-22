import CryptoKit
import Darwin
import Foundation

// Claude exact-session history reader: the single built-in decoder subset `nativeEntriesSubsetV1`
// (lossless restart Phase 4, phase4-plan §D and its native-history amendment).
//
// "V1" versions OUR decoder subset, not Claude's format or CLI. Shapes follow the pinned official
// Python SDK fixtures (`claude-agent-sdk-python@3cb0c27eca8caccdc153471a1b19f97fce4ada03`,
// `tests/test_sessions.py` `_make_transcript_entry` / `_parallel_tool_turn`, and
// `_internal/sessions.py` `_build_conversation_chain` / `_recover_orphaned_parallel_tool_results`).
// That pin is reproducibility evidence, not an accepted CLI version or live qualification.
//
// Contract:
// - Exact session only: `<known projects dir>/<project>/<sessionID>.jsonl`. No match = unavailable;
//   more than one distinct file = ambiguous (never chosen by timestamp).
// - Absence is verified, never inferred from a failure: every authorized root must be enumerated
//   (a missing root is genuinely empty) and every listed candidate must report its identity.
//   Anything else is `inspectionFailed`, so a baseline is never `file: nil` because a directory
//   or candidate was unreadable.
// - One descriptor: identity (device, inode, birth time) and bytes come from the same open file.
// - Only complete lines are decoded; an incomplete trailing line waits (an import). A baseline
//   refuses non-whitespace bytes after the last newline (`partialTrailingRecord`): that pre-existing
//   record would otherwise look like a post-baseline entry later. The ENTIRE captured complete
//   candidate is validated before any row or cursor is produced: an unsupported entry type
//   (including `file-history-snapshot`, `progress`, `system`, `attachment`), unsupported content
//   block, meaningful metadata (sidechain, meta, compaction, team/agent), malformed line, session
//   mismatch, conflicting duplicate, missing parent, cycle, ambiguous branch, or ambiguous tool
//   association rejects the whole candidate.
// - Parent links come from `parentUuid` only (never `logicalParentUuid`). Branching is accepted only
//   for the demonstrated parallel-tool shape: an assistant tool-use entry may have one continuation
//   child plus tool-result entries associated to it by `tool_use_id` and `sourceToolAssistantUUID`.
//   Shared API `message.id` only groups parallel calls; it is never an identity or dedup key.
// - Rows are inert data with deterministic identities derived from (provider, native session,
//   native entry UUID, row kind, block ordinal). Native user rows are validated but never
//   projected: `localItemID == nil` means unassociated/not projected, NOT proven RepoPrompt input.
//   This build has no evidence relating a native user entry (or live stream output) to a local
//   transcript item; canonical import refuses rather than assume one
//   (`AgentProviderHistoryAssociationPreflight`).
// - Completion is always unconfirmed: no final answer, stop reason, or EOF proves a turn finished.
// - Import needs a cursor (a baseline or an earlier import): rows are produced only after it.
//   Replacement or truncation rescans the whole file and resumes after the last ledger-known entry.

package enum ClaudeSessionHistoryReader {
    package static let profileName = "nativeEntriesSubsetV1"
    package static let providerRaw = AgentRecoveryHistoryProvider.claude.rawValue
    package static let defaultMaximumBytes = 64 << 20

    // MARK: Values

    package enum RowKind: String, CaseIterable {
        case userText
        case assistantText
        case toolCall
        case toolResult
    }

    /// One validated native row. `localItemID` is `nil` for rows that are never projected.
    package struct Row: Equatable {
        package let nativeEntryID: String
        package let kind: RowKind
        package let ordinal: Int
        package let localItemID: UUID?
        package let text: String?
        package let toolName: String?
        /// Native tool-use ID (shared by a call and its result).
        package let toolUseID: String?
        /// Deterministic local invocation ID pairing a call and its result.
        package let toolInvocationID: UUID?
        package let toolInputJSON: String?
        package let toolIsError: Bool?
    }

    package enum Completion: Equatable {
        /// This profile never proves completion.
        case unconfirmed
    }

    package struct Candidate: Equatable {
        package let nativeSessionID: String
        /// `nil` when the session file does not exist yet (a baseline before the first turn).
        package let file: AgentRecoveryHistoryFileIdentity?
        package let completeLineOffset: UInt64
        /// New rows in file order (already deduplicated against the ledger).
        package let rows: [Row]
        package let completion: Completion
        /// The cursor's file was replaced or truncated and the whole file was rescanned.
        package let isRescan: Bool
    }

    package enum Unavailable: Equatable {
        case invalidSessionID
        case notFound
        case ambiguous(count: Int)
        case unreadable(String)
        case tooLarge
        /// The file changed identity between resolution and capture.
        case unstableFile
        /// A root, project directory, or listed candidate could not be inspected: absence is not
        /// established (never treated as "not written yet").
        case inspectionFailed(String)
        /// A baseline whose captured bytes end in an incomplete record.
        case partialTrailingRecord
        /// No cursor exists yet: a baseline must be recorded before rows can be imported.
        case baselineRequired
        /// The file was replaced or truncated and no ledger-known entry locates the previous import.
        case baselineLost
    }

    package enum Unsupported: Error, Equatable {
        case malformedLine(line: Int)
        case entryType(String, line: Int)
        case fileHistorySnapshot(line: Int)
        case metadata(String, line: Int)
        case contentBlock(String, line: Int)
        case sessionMismatch(line: Int)
        case conflictingDuplicate(String)
        case missingParent(String)
        case multipleRoots
        case cycle
        case ambiguousBranch(String)
        case toolAssociation(String)
    }

    package enum Result: Equatable {
        case candidate(Candidate)
        case unavailable(Unavailable)
        case unsupported(Unsupported)
    }

    package enum Mode: Equatable {
        /// Records the current complete-line boundary (validated) as the import baseline; no rows.
        case baseline
        /// Produces rows after the cursor.
        case importAfter(AgentRecoveryHistoryCursor)
    }

    // MARK: File access (the only injected boundary)

    package struct Capture: Equatable {
        package let identity: AgentRecoveryHistoryFileIdentity
        package let bytes: Data

        package init(identity: AgentRecoveryHistoryFileIdentity, bytes: Data) {
            self.identity = identity
            self.bytes = bytes
        }
    }

    package enum CaptureError: Error, Equatable {
        case unreadable(String)
        case tooLarge
    }

    /// Result of listing the exact candidates under every authorized root.
    package enum CandidateListing: Equatable {
        /// Every root was enumerated; these candidates exist (empty = verified absence).
        case listed([URL])
        /// A root or project directory could not be inspected.
        case inspectionFailed(String)
    }

    package struct FileAccess {
        /// Exact candidate files `<dir>/<project>/<fileName>` under each projects directory.
        package var candidates: @Sendable (_ projectsDirectories: [URL], _ fileName: String) -> CandidateListing
        /// Identity of one candidate (for distinct-file counting), without reading it.
        package var identity: @Sendable (URL) -> AgentRecoveryHistoryFileIdentity?
        /// Opens one file once and captures identity and bytes from that descriptor.
        package var capture: @Sendable (URL, _ maximumBytes: Int) throws -> Capture

        package init(
            candidates: @escaping @Sendable ([URL], String) -> CandidateListing,
            identity: @escaping @Sendable (URL) -> AgentRecoveryHistoryFileIdentity?,
            capture: @escaping @Sendable (URL, Int) throws -> Capture
        ) {
            self.candidates = candidates
            self.identity = identity
            self.capture = capture
        }
    }

    // MARK: Entry point

    /// Reads one exact Claude session's history. Synchronous file I/O: call off the main actor.
    /// Never mutates any session or recovery state.
    package static func read(
        nativeSessionID: String,
        projectsDirectories: [URL],
        mode: Mode,
        ledger: AgentSessionProviderHistoryRecovery?,
        fileAccess: FileAccess = .live,
        maximumBytes: Int = defaultMaximumBytes
    ) -> Result {
        guard let canonical = UUID(uuidString: nativeSessionID), canonical.uuidString.lowercased() == nativeSessionID else {
            return .unavailable(.invalidSessionID)
        }
        guard !projectsDirectories.isEmpty else {
            return .unavailable(.inspectionFailed("no history location"))
        }
        let fileName = "\(nativeSessionID).jsonl"
        let urls: [URL]
        switch fileAccess.candidates(projectsDirectories, fileName) {
        case let .listed(listed):
            urls = listed
        case let .inspectionFailed(reason):
            return .unavailable(.inspectionFailed(reason))
        }
        var distinct: [(URL, AgentRecoveryHistoryFileIdentity)] = []
        for url in urls {
            guard let identity = fileAccess.identity(url) else {
                return .unavailable(.inspectionFailed("a candidate's identity couldn't be read"))
            }
            if !distinct.contains(where: { $0.1.device == identity.device && $0.1.inode == identity.inode }) {
                distinct.append((url, identity))
            }
        }
        if distinct.count > 1 {
            return .unavailable(.ambiguous(count: distinct.count))
        }
        guard let (url, resolvedIdentity) = distinct.first else {
            if case .baseline = mode {
                // Verified absence (every root enumerated, nothing listed): the conversation has
                // not been written yet, so everything later is new.
                return .candidate(Candidate(
                    nativeSessionID: nativeSessionID,
                    file: nil,
                    completeLineOffset: 0,
                    rows: [],
                    completion: .unconfirmed,
                    isRescan: false
                ))
            }
            return .unavailable(.notFound)
        }
        let capture: Capture
        do {
            capture = try fileAccess.capture(url, maximumBytes)
        } catch CaptureError.tooLarge {
            return .unavailable(.tooLarge)
        } catch let CaptureError.unreadable(reason) {
            return .unavailable(.unreadable(reason))
        } catch {
            return .unavailable(.unreadable(String(describing: error)))
        }
        guard capture.identity.device == resolvedIdentity.device, capture.identity.inode == resolvedIdentity.inode else {
            return .unavailable(.unstableFile)
        }
        return decode(capture: capture, nativeSessionID: nativeSessionID, mode: mode, ledger: ledger)
    }

    // MARK: Decoder (pure; exercised directly by fixture tests through `read`)

    private struct Entry {
        let line: Int
        let lineStart: Int
        let uuid: String
        let parentUUID: String?
        let isAssistant: Bool
        let messageID: String?
        let sourceToolAssistantUUID: String?
        let blocks: [Block]
        let raw: NSDictionary
    }

    private enum Block {
        case text(String)
        case toolUse(id: String, name: String, inputJSON: String)
        case toolResult(toolUseID: String, text: String, isError: Bool?)
    }

    private static let rejectedWhenTrue = ["isSidechain", "isMeta", "isCompactSummary", "isApiErrorMessage", "isVisibleInTranscriptOnly"]
    private static let rejectedWhenPresent = ["logicalParentUuid", "teamName", "agentId", "compactMetadata", "subtype"]

    static func decode(
        capture: Capture,
        nativeSessionID: String,
        mode: Mode,
        ledger: AgentSessionProviderHistoryRecovery?
    ) -> Result {
        let bytes = [UInt8](capture.bytes)
        // Complete lines only: everything after the last newline waits.
        let completeEnd = (bytes.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? 0
        if case .baseline = mode,
           bytes[completeEnd...].contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D })
        {
            return .unavailable(.partialTrailingRecord)
        }
        var entries: [Entry] = []
        var byUUID: [String: Int] = [:]
        var lineNumber = 0
        var lineStart = 0
        while lineStart < completeEnd {
            guard let newline = bytes[lineStart ..< completeEnd].firstIndex(of: UInt8(ascii: "\n")) else { break }
            lineNumber += 1
            let lineBytes = bytes[lineStart ..< newline]
            defer { lineStart = newline + 1 }
            if lineBytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                continue
            }
            switch parseEntry(Data(lineBytes), line: lineNumber, lineStart: lineStart, nativeSessionID: nativeSessionID) {
            case let .failure(unsupported):
                return .unsupported(unsupported)
            case let .success(entry):
                if let existing = byUUID[entry.uuid] {
                    guard entries[existing].raw.isEqual(entry.raw) else {
                        return .unsupported(.conflictingDuplicate(entry.uuid))
                    }
                    continue
                }
                byUUID[entry.uuid] = entries.count
                entries.append(entry)
            }
        }
        if let failure = validateGraph(entries, byUUID: byUUID) {
            return .unsupported(failure)
        }
        let rows = project(entries, byUUID: byUUID, nativeSessionID: nativeSessionID)
        let completeOffset = UInt64(completeEnd)

        switch mode {
        case .baseline:
            return .candidate(Candidate(
                nativeSessionID: nativeSessionID,
                file: capture.identity,
                completeLineOffset: completeOffset,
                rows: [],
                completion: .unconfirmed,
                isRescan: false
            ))
        case let .importAfter(cursor):
            let known = Set(ledger?.nativeItems.filter { $0.nativeSessionID == nativeSessionID }.map(\.key) ?? [])
            func isKnown(_ row: Row) -> Bool {
                known.contains(ledgerKey(row, nativeSessionID: nativeSessionID))
            }
            let sameFile = cursor.file.map { $0 == capture.identity } ?? true
            let rescan = !sameFile || UInt64(completeEnd) < cursor.completeLineOffset
            let frontier: Int
            if !rescan {
                frontier = cursor.file == nil ? 0 : Int(cursor.completeLineOffset)
            } else {
                // Resume after the last entry the ledger already knows.
                let knownEntryIDs = Set(rows.filter(isKnown).map(\.nativeEntryID))
                guard let lastKnown = entries.last(where: { knownEntryIDs.contains($0.uuid) }) else {
                    return .unavailable(.baselineLost)
                }
                frontier = lastKnown.lineStart + 1
            }
            let entryStart = Dictionary(uniqueKeysWithValues: entries.map { ($0.uuid, $0.lineStart) })
            let newRows = rows.filter { row in
                (entryStart[row.nativeEntryID] ?? 0) >= frontier && !isKnown(row)
            }
            return .candidate(Candidate(
                nativeSessionID: nativeSessionID,
                file: capture.identity,
                completeLineOffset: completeOffset,
                rows: newRows,
                completion: .unconfirmed,
                isRescan: rescan
            ))
        }
    }

    /// The ledger key of a row (normalized native row key).
    package static func ledgerKey(_ row: Row, nativeSessionID: String) -> String {
        AgentSessionProviderHistoryRecovery.rowKey(
            providerRaw: providerRaw,
            nativeSessionID: nativeSessionID,
            nativeEntryID: row.nativeEntryID,
            rowKindRaw: row.kind.rawValue,
            ordinal: row.ordinal
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parseEntry(
        _ data: Data,
        line: Int,
        lineStart: Int,
        nativeSessionID: String
    ) -> Swift.Result<Entry, Unsupported> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            return .failure(.malformedLine(line: line))
        }
        guard let type = object["type"] as? String else {
            return .failure(.malformedLine(line: line))
        }
        switch type {
        case "user", "assistant":
            break
        case "file-history-snapshot":
            return .failure(.fileHistorySnapshot(line: line))
        default:
            return .failure(.entryType(type, line: line))
        }
        for key in rejectedWhenTrue where (object[key] as? Bool) == true {
            return .failure(.metadata(key, line: line))
        }
        for key in rejectedWhenPresent where object[key] != nil && !(object[key] is NSNull) {
            return .failure(.metadata(key, line: line))
        }
        guard let uuid = object["uuid"] as? String, !uuid.isEmpty else {
            return .failure(.malformedLine(line: line))
        }
        let parentUUID: String?
        switch object["parentUuid"] {
        case nil, is NSNull:
            parentUUID = nil
        case let value as String where !value.isEmpty:
            parentUUID = value
        default:
            return .failure(.malformedLine(line: line))
        }
        guard (object["sessionId"] as? String) == nativeSessionID else {
            return .failure(.sessionMismatch(line: line))
        }
        guard let message = object["message"] as? NSDictionary, (message["role"] as? String) == type else {
            return .failure(.malformedLine(line: line))
        }
        let source: String?
        switch object["sourceToolAssistantUUID"] {
        case nil, is NSNull: source = nil
        case let value as String: source = value
        default: return .failure(.malformedLine(line: line))
        }
        let isAssistant = type == "assistant"
        var blocks: [Block] = []
        switch message["content"] {
        case let text as String:
            blocks = [.text(text)]
        case let array as [Any]:
            for element in array {
                guard let block = element as? NSDictionary, let blockType = block["type"] as? String else {
                    return .failure(.malformedLine(line: line))
                }
                switch (blockType, isAssistant) {
                case ("text", _):
                    guard let text = block["text"] as? String else { return .failure(.malformedLine(line: line)) }
                    blocks.append(.text(text))
                case ("tool_use", true):
                    guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String,
                          let input = block["input"] as? NSDictionary,
                          let inputData = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                          let inputJSON = String(data: inputData, encoding: .utf8)
                    else { return .failure(.malformedLine(line: line)) }
                    blocks.append(.toolUse(id: id, name: name, inputJSON: inputJSON))
                case ("tool_result", false):
                    guard let toolUseID = block["tool_use_id"] as? String, !toolUseID.isEmpty else {
                        return .failure(.malformedLine(line: line))
                    }
                    let text: String
                    switch block["content"] {
                    case let value as String:
                        text = value
                    case let parts as [Any]:
                        var collected: [String] = []
                        for part in parts {
                            guard let part = part as? NSDictionary, (part["type"] as? String) == "text",
                                  let partText = part["text"] as? String
                            else {
                                return .failure(.contentBlock("tool_result.content", line: line))
                            }
                            collected.append(partText)
                        }
                        text = collected.joined(separator: "\n")
                    case nil:
                        text = ""
                    default:
                        return .failure(.malformedLine(line: line))
                    }
                    let isError: Bool?
                    switch block["is_error"] {
                    case nil, is NSNull: isError = nil
                    case let value as Bool: isError = value
                    default: return .failure(.malformedLine(line: line))
                    }
                    blocks.append(.toolResult(toolUseID: toolUseID, text: text, isError: isError))
                default:
                    return .failure(.contentBlock(blockType, line: line))
                }
            }
        default:
            return .failure(.malformedLine(line: line))
        }
        if !isAssistant, source != nil, !blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) {
            return .failure(.toolAssociation("source without tool result at line \(line)"))
        }
        return .success(Entry(
            line: line,
            lineStart: lineStart,
            uuid: uuid,
            parentUUID: parentUUID,
            isAssistant: isAssistant,
            messageID: isAssistant ? (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
            sourceToolAssistantUUID: source,
            blocks: blocks,
            raw: object
        ))
    }

    private static func toolUseIDs(_ entry: Entry) -> [String] {
        entry.blocks.compactMap { if case let .toolUse(id, _, _) = $0 { id } else { nil } }
    }

    private static func toolResultIDs(_ entry: Entry) -> [String] {
        entry.blocks.compactMap { if case let .toolResult(id, _, _) = $0 { id } else { nil } }
    }

    /// Whether `child` is a tool-result entry associated to `parent` (demonstrated relationship:
    /// the result's parent is its call entry, its `tool_use_id` names a call in that entry, and its
    /// `sourceToolAssistantUUID`, when present, is that entry).
    private static func isAssociatedResult(_ child: Entry, of parent: Entry) -> Bool {
        guard !child.isAssistant, parent.isAssistant else { return false }
        let results = toolResultIDs(child)
        guard !results.isEmpty, results.count == child.blocks.count else { return false }
        let calls = Set(toolUseIDs(parent))
        return results.allSatisfy(calls.contains) && (child.sourceToolAssistantUUID ?? parent.uuid) == parent.uuid
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func validateGraph(_ entries: [Entry], byUUID: [String: Int]) -> Unsupported? {
        var children: [String: [Int]] = [:]
        var roots: [Int] = []
        for (index, entry) in entries.enumerated() {
            if let parent = entry.parentUUID {
                guard byUUID[parent] != nil else { return .missingParent(entry.uuid) }
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        guard entries.isEmpty || roots.count == 1 else { return .multipleRoots }
        // Reachability from the single root (a cycle leaves entries unreachable).
        var reached = 0
        var stack = roots
        var visited = Set<Int>()
        while let next = stack.popLast() {
            guard visited.insert(next).inserted else { return .cycle }
            reached += 1
            stack.append(contentsOf: children[entries[next].uuid] ?? [])
        }
        guard reached == entries.count else { return .cycle }

        // Tool results: every result names a call of its parent entry exactly once overall.
        var resolvedToolUseIDs: Set<String> = []
        for entry in entries where !entry.isAssistant {
            let results = toolResultIDs(entry)
            guard !results.isEmpty else { continue }
            guard results.count == entry.blocks.count else {
                return .toolAssociation("mixed tool result entry \(entry.uuid)")
            }
            guard let parentID = entry.parentUUID, let parentIndex = byUUID[parentID],
                  isAssociatedResult(entry, of: entries[parentIndex])
            else {
                return .toolAssociation("unassociated tool result \(entry.uuid)")
            }
            for id in results {
                guard resolvedToolUseIDs.insert(id).inserted else {
                    return .toolAssociation("tool use \(id) resolved more than once")
                }
            }
        }
        // Tool-use IDs are unique across calls.
        var callIDs: Set<String> = []
        for entry in entries where entry.isAssistant {
            for id in toolUseIDs(entry) {
                guard callIDs.insert(id).inserted else { return .toolAssociation("duplicate tool use \(id)") }
            }
        }

        // Branching: at most one non-associated (continuation) child per entry.
        var forkLeaves: Set<Int> = []
        for (parentID, childIndexes) in children {
            guard let parentIndex = byUUID[parentID] else { continue }
            let parent = entries[parentIndex]
            let associated = childIndexes.filter { isAssociatedResult(entries[$0], of: parent) }
            let others = childIndexes.count - associated.count
            guard others <= 1 else { return .ambiguousBranch(parentID) }
            // A forked associated result must name its source explicitly (demonstrated shape).
            if childIndexes.count > 1 {
                for index in associated where entries[index].sourceToolAssistantUUID == nil {
                    return .toolAssociation("forked tool result without source \(entries[index].uuid)")
                }
            }
            forkLeaves.formUnion(associated)
        }
        // Leaves: exactly one conversation tip, plus tool-result leaves of a parallel call group
        // (assistant tool-use entries sharing a non-empty API message ID and chained by parent).
        var tips = 0
        var groupLeaves = 0
        for (index, entry) in entries.enumerated() where children[entry.uuid] == nil {
            if forkLeaves.contains(index), let parentID = entry.parentUUID, let parentIndex = byUUID[parentID],
               isInParallelGroup(entries[parentIndex], entries: entries, byUUID: byUUID, children: children)
            {
                groupLeaves += 1
                continue
            }
            tips += 1
        }
        // A conversation whose last turn is a parallel tool group (no continuation yet, e.g. an
        // interrupted run) ends on those group results only.
        guard entries.isEmpty || tips == 1 || (tips == 0 && groupLeaves > 0) else {
            return .ambiguousBranch("conversation has \(tips) tips")
        }
        return nil
    }

    private static func isInParallelGroup(
        _ call: Entry,
        entries: [Entry],
        byUUID: [String: Int],
        children: [String: [Int]]
    ) -> Bool {
        guard let messageID = call.messageID, !toolUseIDs(call).isEmpty else { return false }
        if let parentID = call.parentUUID, let parentIndex = byUUID[parentID],
           entries[parentIndex].messageID == messageID, !toolUseIDs(entries[parentIndex]).isEmpty
        {
            return true
        }
        return (children[call.uuid] ?? []).contains { index in
            entries[index].messageID == messageID && !toolUseIDs(entries[index]).isEmpty
        }
    }

    private static func project(_ entries: [Entry], byUUID: [String: Int], nativeSessionID: String) -> [Row] {
        var toolNames: [String: String] = [:]
        for entry in entries {
            for block in entry.blocks {
                if case let .toolUse(id, name, _) = block { toolNames[id] = name }
            }
        }
        var rows: [Row] = []
        for entry in entries {
            for (ordinal, block) in entry.blocks.enumerated() {
                func localID(_ kind: RowKind) -> UUID {
                    deterministicUUID(
                        namespace: "rpce-claude-history-row-v1",
                        components: [providerRaw, nativeSessionID, entry.uuid, kind.rawValue, String(ordinal)]
                    )
                }
                func invocationID(_ toolUseID: String) -> UUID {
                    deterministicUUID(namespace: "rpce-claude-history-tool-v1", components: [providerRaw, nativeSessionID, toolUseID])
                }
                switch block {
                case let .text(text):
                    let kind: RowKind = entry.isAssistant ? .assistantText : .userText
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: kind,
                        ordinal: ordinal,
                        localItemID: entry.isAssistant ? localID(kind) : nil,
                        text: text,
                        toolName: nil,
                        toolUseID: nil,
                        toolInvocationID: nil,
                        toolInputJSON: nil,
                        toolIsError: nil
                    ))
                case let .toolUse(id, name, inputJSON):
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: .toolCall,
                        ordinal: ordinal,
                        localItemID: localID(.toolCall),
                        text: nil,
                        toolName: name,
                        toolUseID: id,
                        toolInvocationID: invocationID(id),
                        toolInputJSON: inputJSON,
                        toolIsError: nil
                    ))
                case let .toolResult(toolUseID, text, isError):
                    rows.append(Row(
                        nativeEntryID: entry.uuid,
                        kind: .toolResult,
                        ordinal: ordinal,
                        localItemID: localID(.toolResult),
                        text: text,
                        toolName: toolNames[toolUseID],
                        toolUseID: toolUseID,
                        toolInvocationID: invocationID(toolUseID),
                        toolInputJSON: nil,
                        toolIsError: isError
                    ))
                }
            }
        }
        return rows
    }

    /// Fixed, documented derivation (not Swift's randomized `Hasher`): SHA-256 over the namespace and
    /// the length-prefixed components, first 16 bytes, with RFC 9562 version 8 and variant bits.
    package static func deterministicUUID(namespace: String, components: [String]) -> UUID {
        let encoded = ([namespace] + components).map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        var digest = Array(SHA256.hash(data: Data(encoded.utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x80
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

// MARK: - Live file access

package extension ClaudeSessionHistoryReader.FileAccess {
    static let live = ClaudeSessionHistoryReader.FileAccess(
        candidates: { directories, fileName in
            var urls: [URL] = []
            let manager = FileManager.default
            for directory in directories {
                let projects: [URL]
                do {
                    projects = try manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // A missing projects root holds no conversation (genuine absence).
                    continue
                } catch {
                    return .inspectionFailed("a history directory couldn't be listed")
                }
                for project in projects {
                    let candidate = project.appendingPathComponent(fileName, isDirectory: false)
                    var info = stat()
                    if lstat(candidate.path, &info) == 0 {
                        // Any entry is listed; its identity decides (a non-regular file fails).
                        urls.append(candidate)
                    } else if errno == ENOENT || errno == ENOTDIR {
                        continue
                    } else {
                        return .inspectionFailed("a history candidate couldn't be inspected (\(errno))")
                    }
                }
            }
            return .listed(urls)
        },
        identity: { url in
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return ClaudeSessionHistoryReader.fileIdentity(info)
        },
        capture: { url, maximumBytes in
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ClaudeSessionHistoryReader.CaptureError.unreadable("open failed (\(errno))")
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw ClaudeSessionHistoryReader.CaptureError.unreadable("not a regular file")
            }
            // A finite boundary: the size at capture time. Bytes appended later are a later import.
            let size = Int(info.st_size)
            guard size <= maximumBytes else { throw ClaudeSessionHistoryReader.CaptureError.tooLarge }
            var bytes = [UInt8](repeating: 0, count: size)
            var filled = 0
            while filled < size {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress!.advanced(by: filled), size - filled)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ClaudeSessionHistoryReader.CaptureError.unreadable("read failed (\(errno))")
                }
                if count == 0 { break }
                filled += count
            }
            return ClaudeSessionHistoryReader.Capture(
                identity: ClaudeSessionHistoryReader.fileIdentity(info),
                bytes: Data(bytes.prefix(filled))
            )
        }
    )
}

extension ClaudeSessionHistoryReader {
    static func fileIdentity(_ info: stat) -> AgentRecoveryHistoryFileIdentity {
        AgentRecoveryHistoryFileIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }
}
