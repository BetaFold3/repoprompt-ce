import Foundation
import Observation

// Outbound attention notifications (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md).
//
// This file owns only the settled-event admission seam: an event captured by the Agent Mode
// adapter (`AgentModeViewModel+AttentionNotifications.swift`) is admitted at most once, in one
// synchronous main-actor step, after its event-specific fences still hold; admitted events are
// handed to an injectable delivery off the main actor and never awaited by the run or question
// paths. Submitted events form one FIFO: only its head prepares (paces) and is admitted, and an
// admitted head stays active through its whole delivery attempt, so a hanging delivery holds later
// notifications only. Production stays disabled with no delivery until the executing-Mac
// `TelegramAttentionNotificationService` starts from guarded app launch and configures it.

/// Identity of one attention event. Each key is admitted at most once per app lifetime.
enum AttentionNotificationEventKey: Hashable {
    /// A root turn completed and settled idle: durable session ID plus the exact run attempt.
    case turnCompleted(sessionID: UUID, attemptID: UUID)
    /// A root `ask_user` interaction is waiting: durable session ID plus the interaction ID.
    case question(sessionID: UUID, interactionID: UUID)
    /// A manual Send test from Settings: a dedicated identity, never a session or question.
    case test(UUID)

    var isManualTest: Bool {
        if case .test = self { true } else { false }
    }
}

/// Content captured at event time. Rendering and splitting into messages belong to the transport.
struct AttentionNotificationEvent: Equatable {
    enum Content: Equatable {
        /// That attempt's final assistant text (nil when the turn ended without one).
        case turnCompleted(finalAssistantText: String?)
        /// Complete question content: every question, option (with description), and the
        /// selection constraints, in the shared `AgentDelegatedQuestionNoticePayload` wording.
        case question(contentLines: [String])
        /// The fixed Send test message; carries no content.
        case test
    }

    let key: AttentionNotificationEventKey
    let workspaceName: String?
    let sessionName: String
    let content: Content
}

enum AttentionNotificationDeliveryOutcome: Equatable {
    case sent
    case failed
    case unknown
}

/// One delivery attempt per admitted event. Called off the main actor; never retried.
protocol AttentionNotificationDelivering: Sendable {
    /// Awaited by the queue head before admission (for example, first-message pacing). The event
    /// is still revalidated after it returns, so it must not send anything.
    func prepareForAdmission() async
    func deliver(_ event: AttentionNotificationEvent) async -> AttentionNotificationDeliveryOutcome
}

extension AttentionNotificationDelivering {
    func prepareForAdmission() async {}
}

enum AttentionNotificationSuppression: String, Equatable {
    /// Disabled at the event, or no delivery is configured.
    case disabled
    /// Disabled, or disabled and re-enabled, between capture and admission.
    case enableChanged
    /// The delivery configuration was replaced or removed, or its saved notification settings
    /// changed, between capture and admission.
    case configurationChanged
    /// Child at any depth, unknown/conflicting lineage, MCP-controlled, or no identity.
    case ineligibleSession
    /// A provider successor was selected, or a generic follow-up was selected but not scheduled.
    /// Actually scheduled generic starts are observed later and use the current-event fence.
    case successorTookOver
    /// The session, its binding, or the event itself is no longer current at admission.
    case eventNoLongerCurrent
    /// Mac input idle time was readable and below the threshold at the event.
    case userActive
}

/// Main-actor admission for attention events (contract Direction 1).
@MainActor
@Observable
final class AttentionNotificationAdmission {
    struct Environment {
        /// Initial delivery for admitted events; nil keeps the seam a no-op. Later changes go
        /// through `setDeliveryConfiguration(_:)`.
        var delivery: (any AttentionNotificationDelivering)?
        /// Seconds since the last Mac input event, or nil when unreadable without a permission
        /// prompt (then idle never suppresses).
        var idleSeconds: @MainActor () -> TimeInterval?
        /// Deterministic fence between the head's preparation (pacing) and admission (tests pause
        /// here). Production is a no-op; admission still re-validates every fence after it returns.
        var beforeAdmission: @MainActor (AttentionNotificationEventKey) async -> Void

        init(
            delivery: (any AttentionNotificationDelivering)? = nil,
            idleSeconds: @escaping @MainActor () -> TimeInterval? = { nil },
            beforeAdmission: @escaping @MainActor (AttentionNotificationEventKey) async -> Void = { _ in }
        ) {
            self.delivery = delivery
            self.idleSeconds = idleSeconds
            self.beforeAdmission = beforeAdmission
        }
    }

    /// Which admission checks a capture uses.
    enum CapturePolicy: Equatable {
        /// Agent Mode events: every enable, configuration, currency, and idle check.
        case automatic
        /// Settings Send test: skips the automatic enable and idle checks only.
        case manualTest
    }

    /// Captured event plus the fences admission re-validates.
    struct Capture {
        let event: AttentionNotificationEvent
        let policy: CapturePolicy
        let enableGeneration: UInt64
        /// The delivery configured at the event and its generation. A capture is only ever sent
        /// through this snapshot, and only while it is still the configured one.
        let delivery: (any AttentionNotificationDelivering)?
        let deliveryGeneration: UInt64
        /// Idle seconds read at event time (nil when unreadable).
        let idleSecondsAtEvent: TimeInterval?
        /// Event-specific fences (session object, binding generation, exact pending interaction or
        /// terminal commit, root eligibility). Must be synchronous and side-effect free.
        let isStillCurrent: @MainActor () -> Bool
    }

    enum Record: Equatable {
        case suppressed(AttentionNotificationSuppression)
        /// Handed to delivery; the single attempt's outcome is still pending.
        case admitted
        case delivered(AttentionNotificationDeliveryOutcome)
    }

    /// App-wide instance. Disabled with no delivery until the guarded Telegram service starts.
    /// Idle time is read lazily, only when an automatic event is captured.
    static let shared = AttentionNotificationAdmission(environment: Environment(
        idleSeconds: { TelegramAttentionIdleReader.secondsSinceLastInput() }
    ))

    static let minimumIdleSeconds: TimeInterval = 5 * 60

    private(set) var isEnabled = false
    /// Bumped on every enable change; a capture from another generation is never admitted.
    private(set) var enableGeneration: UInt64 = 0
    /// Tombstones for every decided event, kept for the app lifetime.
    private(set) var records: [AttentionNotificationEventKey: Record] = [:]
    /// The latest automatic-event suppression and delivery outcome. A manual Send test keeps only
    /// its own record and never overwrites these.
    private(set) var lastSuppression: AttentionNotificationSuppression?
    private(set) var lastDeliveryOutcome: AttentionNotificationDeliveryOutcome?
    /// The configured delivery (an immutable credential/client snapshot) and its generation,
    /// bumped on every replacement or removal.
    @ObservationIgnored private(set) var delivery: (any AttentionNotificationDelivering)?
    private(set) var deliveryGeneration: UInt64 = 0
    /// Submitted, undecided events: the active head (if any) plus the FIFO behind it.
    private(set) var pendingEventKeys: Set<AttentionNotificationEventKey> = []
    /// The queue head being prepared, admitted, or delivered; later events wait behind it.
    private(set) var activeEventKey: AttentionNotificationEventKey?
    /// Synchronous check of the configuration's saved source, installed with each delivery and
    /// read at final admission, so a saved change not yet adopted by the owner never sends
    /// through the old snapshot.
    @ObservationIgnored private var configurationIsCurrent: @MainActor (CapturePolicy) -> Bool = { _ in true }
    @ObservationIgnored private var queuedCaptures: [Capture] = []
    @ObservationIgnored private let idleSeconds: @MainActor () -> TimeInterval?
    @ObservationIgnored private let beforeAdmission: @MainActor (AttentionNotificationEventKey) async -> Void

    /// Keeps only the idle reader and the pre-admission fence; `delivery` is the sole retained
    /// delivery snapshot.
    init(environment: Environment = Environment()) {
        delivery = environment.delivery
        idleSeconds = environment.idleSeconds
        beforeAdmission = environment.beforeAdmission
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enableGeneration &+= 1
    }

    /// Replaces or removes the delivery configuration. Captures taken under an earlier
    /// configuration are never admitted, so old events never switch to new credentials.
    /// `isCurrent` is checked at final admission for this configuration only.
    func setDeliveryConfiguration(
        _ delivery: (any AttentionNotificationDelivering)?,
        isCurrent: @escaping @MainActor (CapturePolicy) -> Bool = { _ in true }
    ) {
        self.delivery = delivery
        configurationIsCurrent = isCurrent
        deliveryGeneration &+= 1
    }

    /// Whether an adapter should capture at all. Cheap; avoids lineage and text work when off.
    var acceptsCaptures: Bool {
        isEnabled && delivery != nil
    }

    /// Starts a capture for the adapter, reading event-time idle and the enable generation.
    func makeCapture(
        event: AttentionNotificationEvent,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) -> Capture {
        Capture(
            event: event,
            policy: .automatic,
            enableGeneration: enableGeneration,
            delivery: delivery,
            deliveryGeneration: deliveryGeneration,
            idleSecondsAtEvent: idleSeconds(),
            isStillCurrent: isStillCurrent
        )
    }

    /// Queues a manual Send test through the same FIFO, pacing, and single attempt as automatic
    /// events. It is sent only through the delivery configured now, and only while that is still
    /// the configuration and `isStillCurrent` holds at admission. Returns the test's key.
    func submitManualTest(isStillCurrent: @escaping @MainActor () -> Bool) -> AttentionNotificationEventKey {
        let key = AttentionNotificationEventKey.test(UUID())
        submit(Capture(
            event: AttentionNotificationEvent(key: key, workspaceName: nil, sessionName: "", content: .test),
            policy: .manualTest,
            enableGeneration: enableGeneration,
            delivery: delivery,
            deliveryGeneration: deliveryGeneration,
            idleSecondsAtEvent: nil,
            isStillCurrent: isStillCurrent
        ))
        return key
    }

    /// Records a decided-not-to-send event (first decision wins).
    func suppress(_ key: AttentionNotificationEventKey, reason: AttentionNotificationSuppression) {
        guard records[key] == nil else { return }
        records[key] = .suppressed(reason)
        if !key.isManualTest {
            lastSuppression = reason
        }
    }

    /// Queues the event behind earlier submissions. Never blocks the caller. A key already
    /// decided or already pending is ignored before any asynchronous work.
    func submit(_ capture: Capture) {
        let key = capture.event.key
        guard records[key] == nil, !pendingEventKeys.contains(key) else { return }
        pendingEventKeys.insert(key)
        queuedCaptures.append(capture)
        startNextIfIdle()
    }

    /// Starts the queue head: preparation (pacing), then the pre-admission fence, then the
    /// synchronous admission. A suppressed head releases at once; an admitted head is released
    /// when its delivery outcome is recorded.
    private func startNextIfIdle() {
        guard activeEventKey == nil, !queuedCaptures.isEmpty else { return }
        let capture = queuedCaptures.removeFirst()
        let key = capture.event.key
        activeEventKey = key
        let fence = beforeAdmission
        Task { @MainActor [weak self] in
            await capture.delivery?.prepareForAdmission()
            await fence(key)
            guard let self, !admit(capture) else { return }
            releaseActiveEvent(key)
        }
    }

    /// Releases the head only if `key` still owns it, then starts the next event.
    private func releaseActiveEvent(_ key: AttentionNotificationEventKey) {
        guard activeEventKey == key else { return }
        activeEventKey = nil
        pendingEventKeys.remove(key)
        startNextIfIdle()
    }

    /// The single synchronous admission boundary. Returns true when the event was handed to
    /// delivery. Nothing here awaits; the delivery runs in a detached task.
    private func admit(_ capture: Capture) -> Bool {
        let key = capture.event.key
        guard records[key] == nil else { return false }
        if capture.policy == .automatic {
            guard isEnabled else {
                suppress(key, reason: capture.enableGeneration == enableGeneration ? .disabled : .enableChanged)
                return false
            }
            guard capture.enableGeneration == enableGeneration else {
                suppress(key, reason: .enableChanged)
                return false
            }
        }
        guard capture.deliveryGeneration == deliveryGeneration else {
            suppress(key, reason: .configurationChanged)
            return false
        }
        guard let delivery = capture.delivery else {
            suppress(key, reason: .disabled)
            return false
        }
        guard configurationIsCurrent(capture.policy) else {
            suppress(key, reason: .configurationChanged)
            return false
        }
        guard capture.isStillCurrent() else {
            suppress(key, reason: .eventNoLongerCurrent)
            return false
        }
        if let idle = capture.idleSecondsAtEvent, idle < Self.minimumIdleSeconds {
            suppress(key, reason: .userActive)
            return false
        }
        records[key] = .admitted
        let event = capture.event
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await delivery.deliver(event)
            await self?.recordDeliveryOutcome(outcome, for: key)
        }
        return true
    }

    private func recordDeliveryOutcome(
        _ outcome: AttentionNotificationDeliveryOutcome,
        for key: AttentionNotificationEventKey
    ) {
        records[key] = .delivered(outcome)
        if !key.isManualTest {
            lastDeliveryOutcome = outcome
        }
        releaseActiveEvent(key)
    }
}
