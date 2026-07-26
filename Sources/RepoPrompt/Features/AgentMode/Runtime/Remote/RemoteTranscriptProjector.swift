import CryptoKit
import Foundation
import RepoPromptRemoteWire

struct RemoteProjectedLogPage: Equatable {
    var sessionID: String
    var turnOffset: Int
    var turnLimit: Int
    var returnedTurnCount: Int
    var totalTurns: Int
    var completedTurnCount: Int?
    var transcriptXML: String
    var items: [AgentChatItem]
    var hostRowIDByClientItemID: [UUID: UUID]

    var nextLogOffset: Int {
        turnOffset + returnedTurnCount
    }

    var consumableOffset: Int {
        guard let completedTurnCount else { return nextLogOffset }
        return min(completedTurnCount, nextLogOffset)
    }
}

struct RemoteProjectedSnapshot: Equatable {
    var statusRaw: String
    var statusText: String?
    var runState: AgentSessionRunState
    var pendingInteraction: RemotePendingInteraction?
    var terminalStatus: String?
    var isExpired: Bool
    var agentKindRaw: String?
    var agentModelRaw: String?
    var agentReasoningEffortRaw: String?
    var sessionName: String?
}

struct RemoteTranscriptProjector: Equatable {
    let remoteSessionID: String

    func projectGetLogResponse(_ payload: JSONValue) -> RemoteProjectedLogPage {
        let object = payload.objectValue ?? [:]
        let sessionID = object["session_id"]?.stringValue ?? remoteSessionID
        let turnOffset = object["turn_offset"]?.intValue ?? 0
        let turnLimit = object["turn_limit"]?.intValue ?? 0
        let returnedTurnCount = object["returned_turn_count"]?.intValue ?? 0
        let totalTurns = object["total_turns"]?.intValue ?? 0
        let completedTurnCount = object["completed_turn_count"]?.intValue
        let transcriptXML = object["transcript_xml"]?.stringValue ?? ""
        let rows = Self.parseTranscriptXML(transcriptXML)
        let items = rows.enumerated().map { index, row in
            item(from: row, logIndex: "\(turnOffset):\(index)", sequenceIndex: turnOffset * 1_000_000 + index)
        }
        var hostRowIDByClientItemID: [UUID: UUID] = [:]
        for (item, row) in zip(items, rows) {
            if let hostRowID = row.hostRowID {
                hostRowIDByClientItemID[item.id] = hostRowID
            }
        }
        return RemoteProjectedLogPage(
            sessionID: sessionID,
            turnOffset: turnOffset,
            turnLimit: turnLimit,
            returnedTurnCount: returnedTurnCount,
            totalTurns: totalTurns,
            completedTurnCount: completedTurnCount,
            transcriptXML: transcriptXML,
            items: items,
            hostRowIDByClientItemID: hostRowIDByClientItemID
        )
    }

    func projectSnapshot(_ payload: JSONValue, frameType: String? = nil) -> RemoteProjectedSnapshot {
        let object = payload.objectValue ?? [:]
        let statusRaw = object["status"]?.stringValue ?? "running"
        let statusText = object["status_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = RemotePendingInteraction(snapshotPayload: payload, remoteSessionID: remoteSessionID)
        let isExpired = frameType == "session_expired" || statusRaw == "expired"
        let terminalStatus: String? = switch statusRaw {
        case "completed", "failed", "cancelled": statusRaw
        default: isExpired ? "expired" : nil
        }
        let runState: AgentSessionRunState = {
            if pending?.approvalRequest != nil {
                return .waitingForApproval
            }
            if pending != nil {
                return .waitingForQuestion
            }
            switch statusRaw {
            case "running":
                return .running
            case "waiting_for_input":
                return .waitingForQuestion
            case "completed":
                return .completed
            case "failed":
                return .failed
            case "cancelled":
                return .cancelled
            case "expired":
                return .failed
            default:
                return .running
            }
        }()
        let agentObject = object["agent"]?.objectValue
        let agentReasoningEffortRaw = agentObject?["reasoning_effort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionObject = object["session"]?.objectValue
        return RemoteProjectedSnapshot(
            statusRaw: statusRaw,
            statusText: statusText?.isEmpty == false ? statusText : nil,
            runState: runState,
            pendingInteraction: pending,
            terminalStatus: terminalStatus,
            isExpired: isExpired,
            agentKindRaw: agentObject?["id"]?.stringValue,
            agentModelRaw: agentObject?["model"]?.stringValue,
            agentReasoningEffortRaw: agentReasoningEffortRaw?.isEmpty == false ? agentReasoningEffortRaw : nil,
            sessionName: sessionObject?["name"]?.stringValue
        )
    }

    func upserting(_ newItems: [AgentChatItem], into existingItems: [AgentChatItem]) -> [AgentChatItem] {
        guard !newItems.isEmpty else { return existingItems }
        var byID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        for item in newItems {
            if let existing = byID[item.id] {
                // Legacy rows carry synthetic 1970-era sequence-index timestamps; max-merge
                // preserves the optimistic-rescue timestamp across re-projections and lets a
                // real wire `ts` (always past the synthetic floor) heal previously projected
                // or persisted synthetic dates.
                byID[item.id] = item.replacingTimestamp(max(existing.timestamp, item.timestamp))
            } else {
                byID[item.id] = item
            }
        }
        return byID.values.sorted {
            if $0.sequenceIndex != $1.sequenceIndex {
                return $0.sequenceIndex < $1.sequenceIndex
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func item(from row: XMLRow, logIndex: String, sequenceIndex: Int) -> AgentChatItem {
        // The wire timestamp is deliberately excluded from the deterministic ID seed so
        // rows projected from legacy (timestampless) and upgraded hosts share identity
        // and merge via `upserting` instead of duplicating.
        let id = deterministicUUID(seed: "remote-transcript-row-v1|\(remoteSessionID)|\(logIndex)|\(row.kind.rawValue)|\(row.toolName ?? "")")
        // Fallback synthetic date keeps deterministic ordering for legacy hosts; display
        // suppresses it (AgentSessionRecencySanity.isDisplayable).
        let timestamp = row.timestamp ?? Date(timeIntervalSince1970: TimeInterval(sequenceIndex))
        switch row.kind {
        case .user:
            return AgentChatItem(id: id, timestamp: timestamp, kind: .user, text: row.text, sequenceIndex: sequenceIndex)
        case .assistant:
            return AgentChatItem(id: id, timestamp: timestamp, kind: .assistant, text: row.text, sequenceIndex: sequenceIndex)
        case .toolCall:
            return AgentChatItem(
                id: id,
                timestamp: timestamp,
                kind: .toolCall,
                text: "Using tool: \(row.toolName ?? "tool")",
                toolName: row.toolName,
                toolArgsJSON: row.text.isEmpty ? nil : row.text,
                toolResultJSON: row.toolResultStatusWord.map {
                    AgentToolResultPersistencePolicy.minimalResultJSON(
                        statusWord: $0,
                        normalizedToolName: row.toolName
                    )
                },
                toolIsError: row.toolResultStatusWord.map { $0 == "failed" },
                sequenceIndex: sequenceIndex
            )
        case .system:
            return AgentChatItem(id: id, timestamp: timestamp, kind: .system, text: row.text, sequenceIndex: sequenceIndex)
        case .error:
            return AgentChatItem(id: id, timestamp: timestamp, kind: .error, text: row.text, sequenceIndex: sequenceIndex)
        case .assistantInline, .toolResult, .thinking:
            return AgentChatItem(id: id, timestamp: timestamp, kind: .system, text: row.text, sequenceIndex: sequenceIndex)
        }
    }

    private struct XMLRow: Equatable {
        var kind: AgentChatItemKind
        var text: String
        var toolName: String?
        var toolResultStatusWord: String?
        /// Authoritative host row date parsed from the wire `ts` attribute; nil for legacy hosts.
        var timestamp: Date?
        /// Host transcript row identity parsed from the opt-in wire `id` attribute.
        var hostRowID: UUID?
    }

    private static func parseTranscriptXML(_ xml: String) -> [XMLRow] {
        guard !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // Groups: 1 tag, 2 tag attributes, 3 text, 4 self-closed tool_call attributes,
        // 5 open tool_call attributes, 6 tool_call body, 7 tool_result attributes.
        let pattern = #"(?s)<(user|assistant|system|error)((?:\s[^>]*)?)>(.*?)</\1>|<tool_call\b([^>]*)\s*/>|<tool_call\b([^>]*)>(.*?)</tool_call>|<tool_result\b([^>]*)\s*/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(xml.startIndex ..< xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, options: [], range: range)
        var rows: [XMLRow] = []
        rows.reserveCapacity(matches.count)
        for match in matches {
            if let tag = string(in: xml, match: match, at: 1) {
                let attributes = string(in: xml, match: match, at: 2) ?? ""
                let text = decodeXMLEntities(string(in: xml, match: match, at: 3) ?? "")
                let kind: AgentChatItemKind = switch tag {
                case "user": .user
                case "assistant": .assistant
                case "system": .system
                case "error": .error
                default: .system
                }
                rows.append(XMLRow(
                    kind: kind,
                    text: text,
                    toolName: nil,
                    timestamp: rowTimestamp(in: attributes),
                    hostRowID: rowHostID(in: attributes)
                ))
            } else if let attributes = string(in: xml, match: match, at: 4),
                      let toolName = attribute("name", in: attributes)
            {
                rows.append(XMLRow(
                    kind: .toolCall,
                    text: "",
                    toolName: decodeXMLEntities(toolName),
                    timestamp: rowTimestamp(in: attributes),
                    hostRowID: rowHostID(in: attributes)
                ))
            } else if let attributes = string(in: xml, match: match, at: 5),
                      let toolName = attribute("name", in: attributes)
            {
                rows.append(XMLRow(
                    kind: .toolCall,
                    text: decodeXMLEntities(string(in: xml, match: match, at: 6) ?? ""),
                    toolName: decodeXMLEntities(toolName),
                    timestamp: rowTimestamp(in: attributes),
                    hostRowID: rowHostID(in: attributes)
                ))
            } else if let attributes = string(in: xml, match: match, at: 7),
                      let toolName = attribute("name", in: attributes),
                      let statusWord = projectedToolResultStatusWord(attribute("status", in: attributes)),
                      rows.last?.kind == .toolCall,
                      rows.last?.toolName == decodeXMLEntities(toolName)
            {
                rows[rows.count - 1].toolResultStatusWord = statusWord
            }
        }
        if rows.isEmpty {
            var fallback = xml.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fallback != "<transcript/>" else { return [] }
            if fallback.hasPrefix("<transcript>"), fallback.hasSuffix("</transcript>") {
                fallback.removeFirst("<transcript>".count)
                fallback.removeLast("</transcript>".count)
            }
            fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return [] }
            return [XMLRow(kind: .system, text: fallback, toolName: nil)]
        }
        return rows
    }

    private static func rowHostID(in attributes: String) -> UUID? {
        guard let raw = attribute("id", in: attributes) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Parses the wire `ts` attribute (Unix epoch seconds, locale-independent) into a Date.
    /// Non-finite values (`nan`/`inf` parse as valid TimeIntervals) fall back to nil so a
    /// buggy host cannot poison max-merge or session persistence with a non-finite Date.
    private static func rowTimestamp(in attributes: String) -> Date? {
        guard let raw = attribute("ts", in: attributes),
              let interval = TimeInterval(raw),
              interval.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:^|\s)"# + escapedName + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(attributes.startIndex ..< attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, options: [], range: range) else { return nil }
        return string(in: attributes, match: match, at: 1)
    }

    private static func projectedToolResultStatusWord(_ raw: String?) -> String? {
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(raw) else { return nil }
        switch AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: normalized) {
        case .success:
            return "success"
        case .warning:
            return "warning"
        case .failed, .cancelled:
            return "failed"
        case .pending, .running, .unknown:
            return nil
        }
    }

    private static func string(in xml: String, match: NSTextCheckingResult, at index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: xml) else { return nil }
        return String(xml[swiftRange])
    }

    private static func decodeXMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func deterministicUUID(seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }
}
