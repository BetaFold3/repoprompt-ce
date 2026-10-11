import Foundation

/// A log entry for agent interactions (tool calls, messages, thinking, etc.)
public struct AgentLogEntry: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let type: AgentLogEntryType
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), type: AgentLogEntryType, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.message = message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AgentLogEntry, rhs: AgentLogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// The type/category of an agent log entry
public enum AgentLogEntryType: String, Codable, Sendable {
    case user
    case assistant
    case tool
    case system
    case error
    case thinking
}
