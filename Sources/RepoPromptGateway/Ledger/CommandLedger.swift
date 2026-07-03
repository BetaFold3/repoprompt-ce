import Foundation
import RepoPromptRemoteWire

actor CommandLedger {
    struct Key: Codable, Hashable {
        let deviceID: String
        let requestID: String
    }

    struct CommandFingerprint: Codable, Hashable {
        let operation: String
        let canonicalPayloadSHA256: String
    }

    enum BeginDecision: Equatable {
        case new
        case duplicate(RecordedOutcome)
        case inFlight
        case conflict(existing: CommandFingerprint)
        case persistenceFailed(RecordedOutcome)
    }

    enum RecordedOutcome: Codable, Equatable {
        case success(JSONValue)
        case failure(code: String, message: String)
        case interactionAlreadyResolved(interactionID: String?)
        case inDoubt

        private enum CodingKeys: String, CodingKey {
            case type
            case payload
            case code
            case message
            case interactionID = "interaction_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "success":
                self = try .success(container.decode(JSONValue.self, forKey: .payload))
            case "failure":
                self = try .failure(
                    code: container.decode(String.self, forKey: .code),
                    message: container.decode(String.self, forKey: .message)
                )
            case "interaction_already_resolved":
                self = try .interactionAlreadyResolved(
                    interactionID: container.decodeIfPresent(String.self, forKey: .interactionID)
                )
            case "in_doubt":
                self = .inDoubt
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown ledger outcome type \(type)"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .success(payload):
                try container.encode("success", forKey: .type)
                try container.encode(payload, forKey: .payload)
            case let .failure(code, message):
                try container.encode("failure", forKey: .type)
                try container.encode(code, forKey: .code)
                try container.encode(message, forKey: .message)
            case let .interactionAlreadyResolved(interactionID):
                try container.encode("interaction_already_resolved", forKey: .type)
                try container.encodeIfPresent(interactionID, forKey: .interactionID)
            case .inDoubt:
                try container.encode("in_doubt", forKey: .type)
            }
        }

        var responsePayload: JSONValue {
            switch self {
            case let .success(payload):
                return payload
            case let .failure(code, message):
                return .object([
                    "code": .string(code),
                    "message": .string(message)
                ])
            case let .interactionAlreadyResolved(interactionID):
                var payload: [String: JSONValue] = [
                    "code": .string("interaction_already_resolved"),
                    "message": .string("The interaction was already resolved; poll/get_log for authoritative state.")
                ]
                if let interactionID {
                    payload["interaction_id"] = .string(interactionID)
                }
                return .object(payload)
            case .inDoubt:
                return .object([
                    "code": .string("in_doubt"),
                    "message": .string("The original command may have reached the app before the gateway restarted. Do not replay it; poll or get_log for authoritative state.")
                ])
            }
        }

        var auditCode: String? {
            switch self {
            case .success:
                nil
            case let .failure(code, _):
                code
            case .interactionAlreadyResolved:
                "interaction_already_resolved"
            case .inDoubt:
                "in_doubt"
            }
        }
    }

    private enum Entry: Equatable {
        case inFlight(fingerprint: CommandFingerprint, beganAt: Date)
        case completed(fingerprint: CommandFingerprint, outcome: RecordedOutcome, beganAt: Date, completedAt: Date)

        var fingerprint: CommandFingerprint {
            switch self {
            case let .inFlight(fingerprint, _), let .completed(fingerprint, _, _, _):
                fingerprint
            }
        }

        var beganAt: Date {
            switch self {
            case let .inFlight(_, beganAt), let .completed(_, _, beganAt, _):
                beganAt
            }
        }

        var completedAt: Date? {
            switch self {
            case .inFlight:
                nil
            case let .completed(_, _, _, completedAt):
                completedAt
            }
        }

        var outcome: RecordedOutcome? {
            switch self {
            case .inFlight:
                nil
            case let .completed(_, outcome, _, _):
                outcome
            }
        }
    }

    static let minimumTTL: TimeInterval = 600

    private let ttl: TimeInterval
    private let store: CommandLedgerStore?
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]

    init(
        ttl: TimeInterval = CommandLedger.minimumTTL,
        store: CommandLedgerStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.ttl = max(Self.minimumTTL, ttl)
        self.store = store
        self.now = now
        if let store {
            let restored = try store.load()
            for snapshot in restored {
                if let outcome = snapshot.outcome, let completedAt = snapshot.completedAt {
                    entries[snapshot.key] = .completed(
                        fingerprint: snapshot.fingerprint,
                        outcome: outcome,
                        beganAt: snapshot.beganAt,
                        completedAt: completedAt
                    )
                } else {
                    entries[snapshot.key] = .completed(
                        fingerprint: snapshot.fingerprint,
                        outcome: .inDoubt,
                        beganAt: snapshot.beganAt,
                        completedAt: now()
                    )
                }
            }
        }
        let cutoff = now().addingTimeInterval(-ttl)
        entries = entries.filter { _, entry in
            let referenceDate = entry.completedAt ?? entry.beganAt
            return referenceDate >= cutoff
        }
        try? store?.replace(with: snapshotsForStore())
    }

    func begin(key: Key, fingerprint: CommandFingerprint) async -> BeginDecision {
        let timestamp = now()
        pruneExpired(now: timestamp)
        if let entry = entries[key] {
            guard entry.fingerprint == fingerprint else {
                return .conflict(existing: entry.fingerprint)
            }
            switch entry {
            case .inFlight:
                return .inFlight
            case let .completed(_, outcome, _, _):
                return .duplicate(outcome)
            }
        }
        do {
            try store?.appendBegin(key: key, fingerprint: fingerprint, at: timestamp)
            entries[key] = .inFlight(fingerprint: fingerprint, beganAt: timestamp)
            return .new
        } catch {
            return .persistenceFailed(.failure(
                code: "ledger_persistence_failed",
                message: String(describing: error)
            ))
        }
    }

    func complete(key: Key, outcome: RecordedOutcome) async {
        let timestamp = now()
        guard let entry = entries[key] else { return }
        let completed = Entry.completed(
            fingerprint: entry.fingerprint,
            outcome: outcome,
            beganAt: entry.beganAt,
            completedAt: timestamp
        )
        do {
            try store?.appendComplete(
                key: key,
                fingerprint: entry.fingerprint,
                outcome: outcome,
                at: timestamp
            )
            entries[key] = completed
        } catch {
            // The command has already been executed. Keep the in-memory outcome so
            // same-process duplicates are still absorbed; a restart will conservatively
            // recover the durable begin as in_doubt.
            entries[key] = completed
        }
    }

    func prune(now date: Date) {
        pruneExpired(now: date)
    }

    private func pruneExpired(now date: Date) {
        let cutoff = date.addingTimeInterval(-ttl)
        entries = entries.filter { _, entry in
            let referenceDate = entry.completedAt ?? entry.beganAt
            return referenceDate >= cutoff
        }
        try? store?.replace(with: snapshotsForStore())
    }

    private func snapshotsForStore() -> [CommandLedgerStore.Snapshot] {
        entries.map { key, entry in
            CommandLedgerStore.Snapshot(
                key: key,
                fingerprint: entry.fingerprint,
                outcome: entry.outcome,
                beganAt: entry.beganAt,
                completedAt: entry.completedAt
            )
        }
    }
}
