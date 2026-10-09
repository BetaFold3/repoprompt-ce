import Foundation

#if DEBUG
    import CoreFoundation
    import os

    /// Transcript update events counted by the DEBUG burst probe. Rejected follows include both
    /// schedule-time ineligibility and deferred-ticket rejection.
    enum AgentTranscriptUpdateBurstEvent: Int, CaseIterable {
        /// An inner capped scroll view delivered a bottom-tracking position.
        case innerGeometryDelivery
        /// A delivered inner position equal to the previous one (expected 0 on macOS 15+).
        case innerDuplicatePosition
        /// An inner delivery changed the pinned state.
        case innerPinTransition
        /// The inner view's newest entry ID changed.
        case innerNewestEntryChange
        /// A newest-entry change issued a deferred follow ticket.
        case innerFollowScheduled
        /// A deferred follow passed revalidation and scrolled.
        case innerFollowExecuted
        /// A newest-entry change issued no ticket, or a deferred ticket failed revalidation.
        case innerFollowRejected
        /// The DEBUG tool-card render-state preference observer fired.
        case toolCardRenderStateDelivery
        /// The observer assigned the render-state `@State` dictionary.
        case toolCardRenderStateAssignment
        /// The outer transcript `onScrollGeometryChange` action ran.
        case outerScrollGeometryAction
        /// `transcriptBlockRows` was evaluated.
        case transcriptBlockRowsBody

        var name: String {
            switch self {
            case .innerGeometryDelivery: "inner_geometry_delivery"
            case .innerDuplicatePosition: "inner_duplicate_position"
            case .innerPinTransition: "inner_pin_transition"
            case .innerNewestEntryChange: "inner_newest_entry_change"
            case .innerFollowScheduled: "inner_follow_scheduled"
            case .innerFollowExecuted: "inner_follow_executed"
            case .innerFollowRejected: "inner_follow_rejected"
            case .toolCardRenderStateDelivery: "tool_card_render_state_delivery"
            case .toolCardRenderStateAssignment: "tool_card_render_state_assignment"
            case .outerScrollGeometryAction: "outer_scroll_geometry_action"
            case .transcriptBlockRowsBody: "transcript_block_rows_body"
            }
        }
    }

    /// Pure per-run-loop-turn counter. A report is returned when the turn's total reaches the
    /// initial threshold and again at each further 10x multiple; `endTurn()` zeroes everything.
    struct AgentTranscriptUpdateBurstCounter: Equatable {
        static let initialReportThreshold = 2000
        static let reportThresholdMultiplier = 10

        struct Report: Equatable {
            let total: Int
            let counts: [Int]

            func count(of event: AgentTranscriptUpdateBurstEvent) -> Int {
                counts[event.rawValue]
            }

            /// Nonzero per-event counts, in declaration order.
            var summary: String {
                AgentTranscriptUpdateBurstEvent.allCases
                    .filter { counts[$0.rawValue] > 0 }
                    .map { "\($0.name)=\(counts[$0.rawValue])" }
                    .joined(separator: " ")
            }
        }

        private(set) var total = 0
        private(set) var counts = [Int](repeating: 0, count: AgentTranscriptUpdateBurstEvent.allCases.count)
        private var nextReportThreshold = Self.initialReportThreshold

        mutating func note(_ event: AgentTranscriptUpdateBurstEvent) -> Report? {
            total += 1
            counts[event.rawValue] += 1
            guard total == nextReportThreshold else { return nil }
            let (next, overflow) = nextReportThreshold.multipliedReportingOverflow(by: Self.reportThresholdMultiplier)
            nextReportThreshold = overflow ? Int.max : next
            return Report(total: total, counts: counts)
        }

        mutating func endTurn() {
            guard total > 0 else { return }
            total = 0
            for index in counts.indices {
                counts[index] = 0
            }
            nextReportThreshold = Self.initialReportThreshold
        }
    }

    /// Always-on DEBUG probe for transcript update bursts within a single main run-loop turn.
    ///
    /// The first `note(_:)` installs one process-wide main run-loop observer (common modes,
    /// `beforeSources | afterWaiting`) that ends the turn. Counts are plain static fields: they
    /// are never published or observed by SwiftUI, and there is no circuit breaker. Each report
    /// logs one `.fault` and emits one signpost event; a report triggers a capture, it does not
    /// classify the cause of a stall.
    @MainActor
    enum AgentTranscriptUpdateBurstProbe {
        private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "transcript-update-burst")
        private static let signposter = OSSignposter(
            subsystem: "com.repoprompt.agents",
            category: "transcript-update-burst"
        )
        private static var counter = AgentTranscriptUpdateBurstCounter()
        private static var turnObserver: CFRunLoopObserver?

        static func note(_ event: AgentTranscriptUpdateBurstEvent) {
            installTurnObserverIfNeeded()
            guard let report = counter.note(event) else { return }
            let summary = report.summary
            logger.fault(
                "Transcript update burst: \(report.total, privacy: .public) events in one main run-loop turn: \(summary, privacy: .public)"
            )
            signposter.emitEvent("TranscriptUpdateBurst", "total=\(report.total, privacy: .public)")
        }

        private static func installTurnObserverIfNeeded() {
            guard turnObserver == nil else { return }
            let activities = CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { _, _ in
                MainActor.assumeIsolated {
                    counter.endTurn()
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            turnObserver = observer
        }
    }
#endif
