import Foundation

// Value types of the outbound attention-notification seam that the agent run service carries
// between its capture and settle hooks. Admission and delivery live in App
// (`App/Notifications/AttentionNotificationAdmission.swift`).

/// Identity of one attention event. Each key is admitted at most once per app lifetime.
package enum AttentionNotificationEventKey: Hashable {
    /// A root turn completed and settled idle: durable session ID plus the exact run attempt.
    case turnCompleted(sessionID: UUID, attemptID: UUID)
    /// A root `ask_user` interaction is waiting: durable session ID plus the interaction ID.
    case question(sessionID: UUID, interactionID: UUID)
    /// A manual Send test from Settings: a dedicated identity, never a session or question.
    case test(UUID)

    package var isManualTest: Bool {
        if case .test = self { true } else { false }
    }
}

/// Content captured at event time. Rendering and splitting into messages belong to the transport.
package struct AttentionNotificationEvent: Equatable {
    package enum Content: Equatable {
        /// That attempt's final assistant text (nil when the turn ended without one).
        case turnCompleted(finalAssistantText: String?)
        /// Complete question content: every question, option (with description), and the
        /// selection constraints, in the shared `AgentDelegatedQuestionNoticePayload` wording.
        case question(contentLines: [String])
        /// The fixed Send test message; carries no content.
        case test
    }

    package let key: AttentionNotificationEventKey
    package let workspaceName: String?
    package let sessionName: String
    package let content: Content

    package init(
        key: AttentionNotificationEventKey,
        workspaceName: String?,
        sessionName: String,
        content: Content
    ) {
        self.key = key
        self.workspaceName = workspaceName
        self.sessionName = sessionName
        self.content = content
    }
}

package enum AttentionNotificationDeliveryOutcome: Equatable {
    case sent
    case failed
    case unknown
}

/// One delivery attempt per admitted event. Called off the main actor; never retried.
package protocol AttentionNotificationDelivering: Sendable {
    /// Awaited by the queue head before admission (for example, first-message pacing). The event
    /// is still revalidated after it returns, so it must not send anything.
    func prepareForAdmission() async
    func deliver(_ event: AttentionNotificationEvent) async -> AttentionNotificationDeliveryOutcome
}

package extension AttentionNotificationDelivering {
    func prepareForAdmission() async {}
}

/// Which admission checks a capture uses.
package enum AttentionNotificationCapturePolicy: Equatable {
    /// Agent Mode events: every enable, configuration, currency, and idle check.
    case automatic
    /// Settings Send test: skips the automatic enable and idle checks only.
    case manualTest
}

/// Captured event plus the fences admission re-validates.
package struct AttentionNotificationCapture {
    package let event: AttentionNotificationEvent
    package let policy: AttentionNotificationCapturePolicy
    package let enableGeneration: UInt64
    /// The delivery configured at the event and its generation. A capture is only ever sent
    /// through this snapshot, and only while it is still the configured one.
    package let delivery: (any AttentionNotificationDelivering)?
    package let deliveryGeneration: UInt64
    /// Idle seconds read at event time (nil when unreadable).
    package let idleSecondsAtEvent: TimeInterval?
    /// Event-specific fences (session object, binding generation, exact pending interaction or
    /// terminal commit, root eligibility). Must be synchronous and side-effect free.
    package let isStillCurrent: @MainActor () -> Bool

    package init(
        event: AttentionNotificationEvent,
        policy: AttentionNotificationCapturePolicy,
        enableGeneration: UInt64,
        delivery: (any AttentionNotificationDelivering)?,
        deliveryGeneration: UInt64,
        idleSecondsAtEvent: TimeInterval?,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        self.event = event
        self.policy = policy
        self.enableGeneration = enableGeneration
        self.delivery = delivery
        self.deliveryGeneration = deliveryGeneration
        self.idleSecondsAtEvent = idleSecondsAtEvent
        self.isStillCurrent = isStillCurrent
    }
}
