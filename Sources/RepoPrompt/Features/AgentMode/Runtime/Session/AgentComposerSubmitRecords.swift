import Foundation

struct AgentComposerSubmitTarget: Equatable {
    enum Route: String, Equatable {
        case existingAgentSession
        case createAgentSessionFromSourceTab
    }

    let tabID: UUID
    let route: Route
    let expectedSourceTabSessionIdentity: ObjectIdentifier
    let expectedSourceAgentSessionID: UUID?
    let expectedPersistentBindingIdentity: AgentPersistentSessionBindingIdentity?
    let expectedBindingTransitionGeneration: UInt64
    // Exact freshness guards for unlinked first-send targets. For an existing
    // persistent session, these remain render-time diagnostics while live routing
    // selects the current run and attempt at send time.
    let expectedRunState: AgentSessionRunState
    let expectedRunID: UUID?
    let expectedRunAttemptID: UUID?
    /// One-shot render identity claimed before submission performs any async work.
    let expectedSubmissionToken: UUID
    let expectedInitialStartLocation: AgentInitialStartLocation?
}

struct AgentComposerSubmitAttempt: Equatable {
    let id: UUID
    let target: AgentComposerSubmitTarget
    let inputRevision: UInt64
    let noticeRevision: UInt64
    let rawDraftSnapshot: String

    var sourceTabID: UUID {
        target.tabID
    }

    var sourceTabSessionIdentity: ObjectIdentifier {
        target.expectedSourceTabSessionIdentity
    }

    var capturedSubmissionToken: UUID {
        target.expectedSubmissionToken
    }
}
