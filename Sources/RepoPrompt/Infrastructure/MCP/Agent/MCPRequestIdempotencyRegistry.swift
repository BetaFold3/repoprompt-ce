import CryptoKit
import Foundation
import MCP

/// Bounded, TTL-pruned idempotency registry for the optional `request_id`
/// argument on mutating `agent_run` operations (`start` / `steer` / `respond`).
///
/// The registry mirrors the gateway `CommandLedger` rules (Phase 2, plan §6.1):
/// - A duplicate request (same client, request ID, operation, and payload hash)
///   returns the recorded outcome instead of re-executing the mutation.
/// - A duplicate that arrives while the original is still executing is refused
///   explicitly (`inFlight`) rather than triggering a second app mutation.
/// - The same request ID with a different operation or payload is a conflict.
///
/// Entries are keyed by `(clientID, requestID)` with the `(operation,
/// payloadHash)` fingerprint stored for conflict detection. Completed entries
/// expire after `ttl` (default 600s, matching the gateway ledger minimum) and
/// the registry is bounded: the oldest completed entries are evicted first and
/// in-flight entries are never evicted.
actor MCPRequestIdempotencyRegistry {
    static let shared = MCPRequestIdempotencyRegistry()

    struct Key: Hashable {
        let clientID: String
        let requestID: String
    }

    struct Fingerprint: Hashable {
        let operation: String
        let payloadHashSHA256: String
    }

    enum RecordedOutcome {
        case success(Value)
        case failure(code: String, message: String)
    }

    enum BeginDecision {
        case new
        case duplicate(RecordedOutcome)
        case inFlight
        case conflict(existing: Fingerprint)
    }

    private struct Entry {
        let fingerprint: Fingerprint
        var outcome: RecordedOutcome?
        var lastTouchedAt: Date
    }

    private let ttl: TimeInterval
    private let maximumEntries: Int
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]

    init(
        ttl: TimeInterval = 600,
        maximumEntries: Int = 512,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = max(1, ttl)
        self.maximumEntries = max(1, maximumEntries)
        self.now = now
    }

    /// Registers the start of a mutating operation. Returns `.new` when the
    /// caller should execute the mutation and later `complete(key:outcome:)`.
    func begin(key: Key, fingerprint: Fingerprint) -> BeginDecision {
        pruneExpired()
        if let existing = entries[key] {
            guard existing.fingerprint == fingerprint else {
                return .conflict(existing: existing.fingerprint)
            }
            if let outcome = existing.outcome {
                entries[key]?.lastTouchedAt = now()
                return .duplicate(outcome)
            }
            return .inFlight
        }
        entries[key] = Entry(fingerprint: fingerprint, outcome: nil, lastTouchedAt: now())
        enforceBounds()
        return .new
    }

    /// Records the structured result (success value or failure) of an operation
    /// begun via `begin(key:fingerprint:)`.
    func complete(key: Key, outcome: RecordedOutcome) {
        guard var entry = entries[key] else { return }
        entry.outcome = outcome
        entry.lastTouchedAt = now()
        entries[key] = entry
        enforceBounds()
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-ttl)
        entries = entries.filter { _, entry in
            entry.outcome == nil || entry.lastTouchedAt >= cutoff
        }
    }

    private func enforceBounds() {
        guard entries.count > maximumEntries else { return }
        let excess = entries.count - maximumEntries
        let removable = entries
            .filter { $0.value.outcome != nil }
            .sorted { $0.value.lastTouchedAt < $1.value.lastTouchedAt }
            .prefix(excess)
            .map(\.key)
        for key in removable {
            entries.removeValue(forKey: key)
        }
    }

    /// Deterministic SHA-256 hex fingerprint of the tool arguments, excluding
    /// the idempotency key itself so retries hash identically.
    nonisolated static func payloadHashHex(
        args: [String: Value],
        excluding excludedKeys: Set<String> = ["request_id"]
    ) -> String {
        var filtered = args
        for key in excludedKeys {
            filtered.removeValue(forKey: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Value.object(filtered)) else {
            return "encoding-failed"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#if DEBUG
    extension MCPRequestIdempotencyRegistry {
        func test_entryCount() -> Int {
            entries.count
        }

        func test_hasEntry(key: Key) -> Bool {
            entries[key] != nil
        }
    }
#endif
