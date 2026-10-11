import Foundation

// MARK: - Scheduled Send Persistence

package struct AgentScheduledSendPersist: Codable, Equatable {
    package enum State: String, Codable, Equatable {
        case scheduled
        case needsConfirmation
        case dispatching
        case failed

        package init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = State(rawValue: rawValue) ?? .needsConfirmation
        }
    }

    package enum ConfirmationReason: String, Codable, Equatable {
        case missedWhileClosed
        case missedDuringSleep
        case clockChanged
        case runNotCompleted
        case deliveryUnknown
        case destinationUnavailable

        package var displayText: String {
            switch self {
            case .missedWhileClosed: "app was closed; confirmation required"
            case .missedDuringSleep: "Mac was asleep; confirmation required"
            case .clockChanged: "system clock changed; confirmation required"
            case .runNotCompleted: "the blocking run did not complete; confirmation required"
            case .deliveryUnknown: "delivery unconfirmed"
            case .destinationUnavailable: "destination unavailable"
            }
        }
    }

    package struct Attempt: Codable, Equatable {
        package let attemptID: UUID
        package let itemID: UUID
        let startedAt: Date

        package init(
            attemptID: UUID,
            itemID: UUID,
            startedAt: Date
        ) {
            self.attemptID = attemptID
            self.itemID = itemID
            self.startedAt = startedAt
        }
    }

    package let id: UUID
    var createdAt: Date
    package var updatedAt: Date
    package var notBefore: Date
    package var state: State
    package var confirmationReason: ConfirmationReason?
    package var rawText: String
    package var attachments: [AgentImageAttachment]
    package var taggedFileAttachments: [AgentTaggedFileAttachment]
    package var workflow: AgentWorkflowDefinition?
    package var interviewFirst: Bool
    package var isNewSessionStart: Bool
    package var runAlongsideOtherSessions: Bool
    package var firstEligibleAt: Date?
    package var attempt: Attempt?
    package var lastFailureMessage: String?

    package init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        notBefore: Date,
        state: State,
        confirmationReason: ConfirmationReason? = nil,
        rawText: String,
        attachments: [AgentImageAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition? = nil,
        interviewFirst: Bool,
        isNewSessionStart: Bool,
        runAlongsideOtherSessions: Bool,
        firstEligibleAt: Date? = nil,
        attempt: Attempt? = nil,
        lastFailureMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notBefore = notBefore
        self.state = state
        self.confirmationReason = confirmationReason
        self.rawText = rawText
        self.attachments = attachments
        self.taggedFileAttachments = taggedFileAttachments
        self.workflow = workflow
        self.interviewFirst = interviewFirst
        self.isNewSessionStart = isNewSessionStart
        self.runAlongsideOtherSessions = runAlongsideOtherSessions
        self.firstEligibleAt = firstEligibleAt
        self.attempt = attempt
        self.lastFailureMessage = lastFailureMessage
    }
}

public struct AgentScheduledSendProvenance: Codable, Equatable, Sendable {
    public let scheduleID: UUID
    public let attemptID: UUID
    public let scheduledFor: Date
    public let sentAt: Date

    public init(scheduleID: UUID, attemptID: UUID, scheduledFor: Date, sentAt: Date) {
        self.scheduleID = scheduleID
        self.attemptID = attemptID
        self.scheduledFor = scheduledFor
        self.sentAt = sentAt
    }
}

/// Semantic JSON representation used to retain a scheduled-send member that this build cannot read.
///
/// Object member order and numeric spelling are not preserved, but the decoded JSON value is.
package enum AgentScheduledSendJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([AgentScheduledSendJSONValue])
    case object([String: AgentScheduledSendJSONValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentScheduledSendJSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: AgentScheduledSendJSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    fileprivate var normalizingUnknownScheduledSendState: AgentScheduledSendJSONValue {
        guard case var .object(object) = self,
              case let .string(rawState)? = object["state"],
              AgentScheduledSendPersist.State(rawValue: rawState) == nil
        else {
            return self
        }
        object["state"] = .string(AgentScheduledSendPersist.State.needsConfirmation.rawValue)
        return .object(object)
    }
}

package enum AgentScheduledSendMember: Codable, Equatable {
    case v1(AgentScheduledSendPersist)
    case unreadable(AgentScheduledSendJSONValue)

    package var persistedValue: AgentScheduledSendPersist? {
        guard case let .v1(value) = self else { return nil }
        return value
    }

    package var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    package init(from decoder: Decoder) throws {
        let jsonValue = try AgentScheduledSendJSONValue(from: decoder)
        let jsonData = try JSONEncoder().encode(jsonValue)

        guard let value = try? JSONDecoder().decode(AgentScheduledSendPersist.self, from: jsonData),
              let typedData = try? JSONEncoder().encode(value),
              let typedJSON = try? JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: typedData),
              typedJSON == jsonValue.normalizingUnknownScheduledSendState
        else {
            self = .unreadable(jsonValue)
            return
        }

        self = .v1(value)
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .v1(value):
            try value.encode(to: encoder)
        case let .unreadable(jsonValue):
            try jsonValue.encode(to: encoder)
        }
    }
}
