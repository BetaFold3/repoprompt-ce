import Darwin
import Foundation

/// Durable one-time ticket ledger. Ticket IDs are persisted until their expiry so a
/// gateway restart cannot admit the same one-time ticket twice.
///
/// Persistence rules (M4):
/// - the store file lives under the gateway app-support root with 0600 permissions,
/// - a ticket ID must be persisted BEFORE the WebSocket connection is accepted,
/// - persistence failure means admission fails closed,
/// - replay across a gateway restart is rejected via load-on-init.
final class UsedTicketStore: @unchecked Sendable {
    private struct Entry: Codable {
        let ticketID: String
        let expiresAtMs: Int64

        private enum CodingKeys: String, CodingKey {
            case ticketID = "ticket_id"
            case expiresAtMs = "expires_at_ms"
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var usedTicketExpiries: [String: Int64] = [:]

    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.fileURL = fileURL
        self.now = now
        try GatewayFileSecurity.ensureSecureDirectory(at: fileURL.deletingLastPathComponent())
        try GatewayFileSecurity.ensureSecureFile(at: fileURL)
        try loadAndCompact()
    }

    /// Whether the ticket ID has already been used and has not expired.
    func isUsed(_ ticketID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return usedTicketExpiries[Self.key(ticketID)] != nil
    }

    /// Records a ticket ID as used, persisting it durably before returning.
    /// Throws when the ticket was already used or when persistence fails; callers
    /// must treat any thrown error as a fail-closed admission decision.
    func markUsed(ticketID: UUID, expiresAtMs: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        let key = Self.key(ticketID)
        guard usedTicketExpiries[key] == nil else {
            throw GatewayPersistenceError.appendFailed("Ticket \(key) was already used.")
        }
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
        let entry = Entry(ticketID: key, expiresAtMs: expiresAtMs)
        var line = try JSONEncoder().encode(entry)
        line.append(UInt8(ascii: "\n"))
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw GatewayPersistenceError.appendFailed(String(describing: error))
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            throw GatewayPersistenceError.appendFailed(String(describing: error))
        }
        usedTicketExpiries[key] = expiresAtMs
    }

    /// Number of live (unexpired) used-ticket entries. Primarily for tests/diagnostics.
    var liveEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return usedTicketExpiries.count
    }

    private static func key(_ ticketID: UUID) -> String {
        ticketID.uuidString.lowercased()
    }

    private func nowMs() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
    }

    private func pruneExpiredLocked() {
        let cutoff = nowMs()
        usedTicketExpiries = usedTicketExpiries.filter { $0.value > cutoff }
    }

    private func loadAndCompact() throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw GatewayPersistenceError.loadFailed(String(describing: error))
        }
        let decoder = JSONDecoder()
        var loaded: [String: Int64] = [:]
        for lineData in data.split(separator: UInt8(ascii: "\n")) where !lineData.isEmpty {
            let entry: Entry
            do {
                entry = try decoder.decode(Entry.self, from: Data(lineData))
            } catch {
                // Fail closed: a corrupt used-ticket ledger must not silently forget
                // tickets that may still be replayable.
                throw GatewayPersistenceError.loadFailed("Corrupt used-ticket entry: \(String(describing: error))")
            }
            loaded[entry.ticketID.lowercased()] = entry.expiresAtMs
        }
        let cutoff = nowMs()
        usedTicketExpiries = loaded.filter { $0.value > cutoff }

        // Compact expired entries away with an atomic secure rewrite.
        if usedTicketExpiries.count != loaded.count {
            let encoder = JSONEncoder()
            var compacted = Data()
            for (ticketID, expiresAtMs) in usedTicketExpiries.sorted(by: { $0.key < $1.key }) {
                let entry = Entry(ticketID: ticketID, expiresAtMs: expiresAtMs)
                try compacted.append(encoder.encode(entry))
                compacted.append(UInt8(ascii: "\n"))
            }
            let temporaryURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
            do {
                try compacted.write(to: temporaryURL, options: [.atomic])
                try GatewayFileSecurity.setMode(0o600, path: temporaryURL.path)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
                try GatewayFileSecurity.setMode(0o600, path: fileURL.path)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw GatewayPersistenceError.loadFailed("Could not compact used-ticket store: \(String(describing: error))")
            }
        }
    }
}
