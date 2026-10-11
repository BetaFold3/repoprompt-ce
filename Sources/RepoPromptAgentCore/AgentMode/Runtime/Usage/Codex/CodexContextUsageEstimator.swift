import Foundation

@MainActor
package final class CodexContextUsageEstimator: ContextUsageEstimating {
    package let agent: AgentProviderKind = .codexExec

    package init() {}

    @discardableResult
    package func enqueueUserTurnEstimate(
        messageForProvider _: String,
        session _: AgentTabSession
    ) -> Int {
        0
    }

    @discardableResult
    package func replaceNextQueuedUserTurnEstimate(
        messageForProvider _: String,
        session _: AgentTabSession
    ) -> Int? {
        nil
    }

    package func dequeueQueuedUserTurnEstimate(session _: AgentTabSession) -> Int? {
        nil
    }

    package func beginTurn(session _: AgentTabSession, initialMessage _: String) {
        // Codex uses native token usage events.
    }

    package func addUserInputTokens(_ tokens: Int, session _: AgentTabSession) {
        _ = tokens
    }

    package func addToolInputPayload(_ payload: String?, session _: AgentTabSession) {
        _ = payload
    }

    package func addToolOutputPayload(_ payload: String?, session _: AgentTabSession) {
        _ = payload
    }

    @discardableResult
    package func ingestUsageSignal(
        promptTokens _: Int?,
        completionTokens _: Int?,
        contextUsedTokens _: Int?,
        modelContextWindow _: Int?,
        session _: AgentTabSession
    ) -> ContextUsageSnapshot? {
        nil
    }

    @discardableResult
    package func ingestTurnFinalizationSignal(
        contextUsedTokens _: Int?,
        modelContextWindow _: Int?,
        session _: AgentTabSession
    ) -> ContextUsageSnapshot? {
        nil
    }

    package func ingestStatusSignal(_ statusText: String?, session _: AgentTabSession) {
        _ = statusText
    }

    package func ingestSystemSignal(_ systemText: String?, session _: AgentTabSession) {
        _ = systemText
    }

    @discardableResult
    package func finalizeTurn(
        promptTokens _: Int?,
        completionTokens _: Int?,
        contextUsedTokens _: Int?,
        session _: AgentTabSession
    ) -> Bool {
        false
    }

    @discardableResult
    package func ingestNativeContextUsage(
        _ usage: AgentContextUsage?,
        session: AgentTabSession
    ) -> ContextUsageSnapshot? {
        let next = ContextUsageSnapshot.fromAgentContextUsage(
            usage,
            source: .codexNativeUsage,
            confidence: .exact
        )
        if session.contextUsageSnapshot != next {
            session.contextUsageSnapshot = next
            return next
        }
        return nil
    }
}
