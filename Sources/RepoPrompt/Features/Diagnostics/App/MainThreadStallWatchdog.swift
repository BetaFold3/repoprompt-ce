import Foundation

#if DEBUG
    import os
    import Synchronization

    /// Pure state machine for the DEBUG main-thread stall watchdog.
    ///
    /// At most one ping is outstanding. A tick more than `maximumTickGap` after the previous one
    /// (debugger stop, sleep/wake, App Nap) invalidates the measurement window: the outstanding
    /// ping's window start resets to now and no new ping is sent. Each ping faults at most once,
    /// when its validity window reaches `stallThreshold`. The ping's original enqueue time is kept
    /// separately from the window start so a fault can report when the unanswered ping was
    /// enqueued without claiming an exact stall onset.
    struct MainThreadStallWatchdogCore: Equatable {
        typealias Instant = ContinuousClock.Instant

        static let tickInterval: Duration = .milliseconds(500)
        static let maximumTickGap: Duration = .seconds(1)
        static let stallThreshold: Duration = .seconds(2)

        enum TickAction: Equatable {
            case none
            case sendPing(id: UInt64)
            case fault(id: UInt64, stalledFor: Duration, enqueuedAt: Instant)
        }

        struct Recovery: Equatable {
            let id: UInt64
            /// Time since the (possibly reset) validity-window start.
            let stalledFor: Duration
            /// Time since the ping was enqueued, including any invalidated gaps.
            let sinceEnqueue: Duration
        }

        struct OutstandingPing: Equatable {
            let id: UInt64
            let enqueuedAt: Instant
            var windowStart: Instant
            var hasFaulted: Bool
        }

        private(set) var outstanding: OutstandingPing?
        private(set) var lastTick: Instant?
        private var nextPingID: UInt64 = 1

        mutating func tick(now: Instant) -> TickAction {
            defer { lastTick = now }
            if let lastTick, now - lastTick > Self.maximumTickGap {
                outstanding?.windowStart = now
                return .none
            }
            guard var ping = outstanding else {
                let id = nextPingID
                nextPingID &+= 1
                outstanding = OutstandingPing(id: id, enqueuedAt: now, windowStart: now, hasFaulted: false)
                return .sendPing(id: id)
            }
            guard !ping.hasFaulted else { return .none }
            let stalledFor = now - ping.windowStart
            guard stalledFor >= Self.stallThreshold else { return .none }
            ping.hasFaulted = true
            outstanding = ping
            return .fault(id: ping.id, stalledFor: stalledFor, enqueuedAt: ping.enqueuedAt)
        }

        /// Clears the matching outstanding ping. Returns a recovery only when that ping had
        /// faulted; a stale or unknown ID changes nothing.
        mutating func pong(id: UInt64, now: Instant) -> Recovery? {
            guard let ping = outstanding, ping.id == id else { return nil }
            outstanding = nil
            guard ping.hasFaulted else { return nil }
            return Recovery(id: id, stalledFor: now - ping.windowStart, sinceEnqueue: now - ping.enqueuedAt)
        }
    }

    /// App-wide DEBUG main-thread stall watchdog, started once from `AppDelegate` after the
    /// launch callback returns. A dedicated thread (not GCD) ticks every 0.5 s and pings the main
    /// queue. A true hang yields exactly one `.fault` and no recovery line; a later pong logs one
    /// `.error` recovery line. Cross-thread log emission can race; correlate records by ping ID.
    /// Faults make no causal classification: they only trigger capture.
    enum MainThreadStallWatchdog {
        @MainActor private static var hasStarted = false

        @MainActor
        static func startIfNeeded() {
            guard !hasStarted else { return }
            // `Synchronization.Mutex` requires macOS 15; the supported range is newer.
            guard #available(macOS 15.0, *) else { return }
            hasStarted = true
            MainThreadStallWatchdogRuntime().start()
        }
    }

    @available(macOS 15.0, *)
    private final class MainThreadStallWatchdogRuntime: Sendable {
        private struct State {
            var core = MainThreadStallWatchdogCore()
            var pingEnqueueWallTime: Date?
        }

        private static let logger = Logger(subsystem: "com.repoprompt.app", category: "main-thread-stall")

        private let state = Mutex(State())
        private let clock = ContinuousClock()

        func start() {
            let thread = Thread { [self] in
                run()
            }
            thread.name = "com.repoprompt.main-thread-stall-watchdog"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        private func run() {
            let interval = Self.seconds(MainThreadStallWatchdogCore.tickInterval)
            while true {
                Thread.sleep(forTimeInterval: interval)
                let now = clock.now
                let (action, enqueueWallTime) = state.withLock { locked -> (MainThreadStallWatchdogCore.TickAction, Date?) in
                    let action = locked.core.tick(now: now)
                    if case .sendPing = action {
                        locked.pingEnqueueWallTime = Date()
                    }
                    return (action, locked.pingEnqueueWallTime)
                }
                switch action {
                case .none:
                    break
                case let .sendPing(id):
                    DispatchQueue.main.async { [self] in
                        receivePong(id: id)
                    }
                case let .fault(id, stalledFor, _):
                    let enqueued = enqueueWallTime.map { Self.timestamp($0) } ?? "unknown"
                    Self.logger.fault(
                        "Main thread unresponsive: ping \(id, privacy: .public) enqueued at \(enqueued, privacy: .public) unanswered for \(Self.seconds(stalledFor), format: .fixed(precision: 1), privacy: .public) s of valid ticks"
                    )
                }
            }
        }

        private func receivePong(id: UInt64) {
            let now = clock.now
            let recovery = state.withLock { locked -> MainThreadStallWatchdogCore.Recovery? in
                let recovery = locked.core.pong(id: id, now: now)
                if locked.core.outstanding == nil {
                    locked.pingEnqueueWallTime = nil
                }
                return recovery
            }
            guard let recovery else { return }
            Self.logger.error(
                "Main thread recovered after \(Self.seconds(recovery.stalledFor), format: .fixed(precision: 1), privacy: .public) s (ping \(recovery.id, privacy: .public), \(Self.seconds(recovery.sinceEnqueue), format: .fixed(precision: 1), privacy: .public) s since enqueue)"
            )
        }

        private static func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }

        private static func timestamp(_ date: Date) -> String {
            date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
    }
#endif
