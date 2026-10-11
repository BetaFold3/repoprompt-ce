import Foundation

package struct AgentComposerSubmitTarget: Equatable {
    package enum Route: String, Equatable {
        case existingAgentSession
        case createAgentSessionFromSourceTab
    }

    package let tabID: UUID
    package let route: Route
    package let expectedSourceTabSessionIdentity: ObjectIdentifier
    package let expectedSourceAgentSessionID: UUID?
    package let expectedPersistentBindingIdentity: AgentPersistentSessionBindingIdentity?
    package let expectedBindingTransitionGeneration: UInt64
    // Exact freshness guards for unlinked first-send targets. For an existing
    // persistent session, these remain render-time diagnostics while live routing
    // selects the current run and attempt at send time.
    package let expectedRunState: AgentSessionRunState
    package let expectedRunID: UUID?
    package let expectedRunAttemptID: UUID?
    /// One-shot render identity claimed before submission performs any async work.
    package let expectedSubmissionToken: UUID
    package let expectedInitialStartLocation: AgentInitialStartLocation?

    package init(
        tabID: UUID,
        route: Route,
        expectedSourceTabSessionIdentity: ObjectIdentifier,
        expectedSourceAgentSessionID: UUID?,
        expectedPersistentBindingIdentity: AgentPersistentSessionBindingIdentity?,
        expectedBindingTransitionGeneration: UInt64,
        expectedRunState: AgentSessionRunState,
        expectedRunID: UUID?,
        expectedRunAttemptID: UUID?,
        expectedSubmissionToken: UUID,
        expectedInitialStartLocation: AgentInitialStartLocation?
    ) {
        self.tabID = tabID
        self.route = route
        self.expectedSourceTabSessionIdentity = expectedSourceTabSessionIdentity
        self.expectedSourceAgentSessionID = expectedSourceAgentSessionID
        self.expectedPersistentBindingIdentity = expectedPersistentBindingIdentity
        self.expectedBindingTransitionGeneration = expectedBindingTransitionGeneration
        self.expectedRunState = expectedRunState
        self.expectedRunID = expectedRunID
        self.expectedRunAttemptID = expectedRunAttemptID
        self.expectedSubmissionToken = expectedSubmissionToken
        self.expectedInitialStartLocation = expectedInitialStartLocation
    }
}

package struct AgentComposerSubmitAttempt: Equatable {
    package let id: UUID
    package let target: AgentComposerSubmitTarget
    package let inputRevision: UInt64
    package let noticeRevision: UInt64
    package let rawDraftSnapshot: String

    package init(
        id: UUID,
        target: AgentComposerSubmitTarget,
        inputRevision: UInt64,
        noticeRevision: UInt64,
        rawDraftSnapshot: String
    ) {
        self.id = id
        self.target = target
        self.inputRevision = inputRevision
        self.noticeRevision = noticeRevision
        self.rawDraftSnapshot = rawDraftSnapshot
    }

    package var sourceTabID: UUID {
        target.tabID
    }

    package var sourceTabSessionIdentity: ObjectIdentifier {
        target.expectedSourceTabSessionIdentity
    }

    package var capturedSubmissionToken: UUID {
        target.expectedSubmissionToken
    }
}
