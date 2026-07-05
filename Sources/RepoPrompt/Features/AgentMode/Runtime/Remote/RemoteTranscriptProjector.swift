import CryptoKit
import Foundation
import RepoPromptRemoteWire

struct RemoteProjectedLogPage: Equatable {
    var sessionID: String
    var turnOffset: Int
    var turnLimit: Int
    var returnedTurnCount: Int
    var totalTurns: Int
    var transcriptXML: String
    var items: [AgentChatItem]

    var nextLogOffset: Int {
        turnOffset + returnedTurnCount
    }
}

struct RemoteProjectedSnapshot: Equatable {
    var statusRaw: String
    var runState: AgentSessionRunState
    var pendingInteraction: RemotePendingInteraction?
    var terminalStatus: String?
    var isExpired: Bool
    var agentKindRaw: String?
    var agentModelRaw: String?
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
        let transcriptXML = object["transcript_xml"]?.stringValue ?? ""
        let rows = Self.parseTranscriptXML(transcriptXML)
        let items = rows.enumerated().map { index, row in
            item(from: row, logIndex: "\(turnOffset):\(index)", sequenceIndex: turnOffset * 1_000_000 + index)
        }
        return RemoteProjectedLogPage(
            sessionID: sessionID,
            turnOffset: turnOffset,
            turnLimit: turnLimit,
            returnedTurnCount: returnedTurnCount,
            totalTurns: totalTurns,
            transcriptXML: transcriptXML,
            items: items
        )
    }

    func projectSnapshot(_ payload: JSONValue, frameType: String? = nil) -> RemoteProjectedSnapshot {
        let object = payload.objectValue ?? [:]
        let statusRaw = object["status"]?.stringValue ?? "running"
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
        let sessionObject = object["session"]?.objectValue
        return RemoteProjectedSnapshot(
            statusRaw: statusRaw,
            runState: runState,
            pendingInteraction: pending,
            terminalStatus: terminalStatus,
            isExpired: isExpired,
            agentKindRaw: agentObject?["id"]?.stringValue,
            agentModelRaw: agentObject?["model"]?.stringValue,
            sessionName: sessionObject?["name"]?.stringValue
        )
    }

    func upserting(_ newItems: [AgentChatItem], into existingItems: [AgentChatItem]) -> [AgentChatItem] {
        guard !newItems.isEmpty else { return existingItems }
        var byID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        for item in newItems {
            byID[item.id] = item
        }
        return byID.values.sorted {
            if $0.sequenceIndex != $1.sequenceIndex {
                return $0.sequenceIndex < $1.sequenceIndex
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func item(from row: XMLRow, logIndex: String, sequenceIndex: Int) -> AgentChatItem {
        let id = deterministicUUID(seed: "remote-transcript-row-v1|\(remoteSessionID)|\(logIndex)|\(row.kind.rawValue)|\(row.toolName ?? "")")
        let timestamp = Date(timeIntervalSince1970: TimeInterval(sequenceIndex))
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
    }

    private static func parseTranscriptXML(_ xml: String) -> [XMLRow] {
        guard !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let pattern = #"(?s)<(user|assistant|system|error)>(.*?)</\1>|<tool_call\s+name="([^"]+)"\s*/>|<tool_call\s+name="([^"]+)">(.*?)</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(xml.startIndex ..< xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, options: [], range: range)
        var rows: [XMLRow] = []
        rows.reserveCapacity(matches.count)
        for match in matches {
            if let tag = string(in: xml, match: match, at: 1) {
                let text = decodeXMLEntities(string(in: xml, match: match, at: 2) ?? "")
                let kind: AgentChatItemKind = switch tag {
                case "user": .user
                case "assistant": .assistant
                case "system": .system
                case "error": .error
                default: .system
                }
                rows.append(XMLRow(kind: kind, text: text, toolName: nil))
            } else if let toolName = string(in: xml, match: match, at: 3) {
                rows.append(XMLRow(kind: .toolCall, text: "", toolName: decodeXMLEntities(toolName)))
            } else if let toolName = string(in: xml, match: match, at: 4) {
                rows.append(XMLRow(kind: .toolCall, text: decodeXMLEntities(string(in: xml, match: match, at: 5) ?? ""), toolName: decodeXMLEntities(toolName)))
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
