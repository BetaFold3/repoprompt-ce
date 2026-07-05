import Foundation

actor GatewaySessionWindowAffinity {
    typealias Discovery = @Sendable () async -> Int?

    private struct Entry {
        var windowID: Int
        var touchedAt: UInt64
    }

    private struct InFlightDiscovery {
        let id: UUID
        let task: Task<Int?, Never>
    }

    private let capacity: Int
    private var clock: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var inFlightDiscoveries: [String: InFlightDiscovery] = [:]

    init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
    }

    func windowID(forSession sessionID: String) -> Int? {
        let key = normalized(sessionID)
        guard var entry = entries[key] else { return nil }
        entry.touchedAt = nextTick()
        entries[key] = entry
        return entry.windowID
    }

    func record(sessionID: String, windowID: Int) {
        let key = normalized(sessionID)
        guard !key.isEmpty else { return }
        entries[key] = Entry(windowID: windowID, touchedAt: nextTick())
        evictIfNeeded()
    }

    func invalidate(sessionID: String) {
        entries.removeValue(forKey: normalized(sessionID))
    }

    func resolvingWindowID(forSession sessionID: String, discover: @escaping Discovery) async -> Int? {
        let key = normalized(sessionID)
        guard !key.isEmpty else { return nil }
        if let cached = windowID(forSession: key) {
            return cached
        }
        if let inFlight = inFlightDiscoveries[key] {
            return await inFlight.task.value
        }

        let inFlight = InFlightDiscovery(id: UUID(), task: Task { await discover() })
        inFlightDiscoveries[key] = inFlight
        let discovered = await inFlight.task.value
        if inFlightDiscoveries[key]?.id == inFlight.id {
            inFlightDiscoveries.removeValue(forKey: key)
        }
        if let discovered {
            record(sessionID: key, windowID: discovered)
        }
        return discovered
    }

    private func normalized(_ sessionID: String) -> String {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextTick() -> UInt64 {
        clock &+= 1
        return clock
    }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        let victims = entries
            .sorted { $0.value.touchedAt < $1.value.touchedAt }
            .prefix(overflow)
            .map(\.key)
        for victim in victims {
            entries.removeValue(forKey: victim)
        }
    }
}
