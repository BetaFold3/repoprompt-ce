import Foundation

/// Oracle failure inspection plan C5: the failed-execution count behind the ` • N failed`
/// suffix on activity-cluster and grouped-history headers. Computed at the projection's summary
/// boundary from already-merged executions, never in view bodies.
enum AgentTranscriptToolFailureCount {
    /// Counts each logical tool execution once, using its latest normalized status. Pending,
    /// running and cancelled work never counts. An Oracle send whose card resolves as failed
    /// (for example a completed wait envelope with one failed lane, or `errors[]` retained beside
    /// a non-terminal status word) counts once; lane counts stay inside the card.
    static func failedExecutionCount(_ executions: [AgentTranscriptToolExecution]) -> Int {
        executions.count(where: isFailed)
    }

    /// Stored form for `AgentTranscriptClusterSummary.failedToolCount`: `nil` at zero.
    static func storedFailedCount(_ executions: [AgentTranscriptToolExecution]) -> Int? {
        let count = failedExecutionCount(executions)
        return count > 0 ? count : nil
    }

    static func isFailed(_ execution: AgentTranscriptToolExecution) -> Bool {
        switch execution.status {
        case .failed:
            return true
        case .cancelled, .pending, .running:
            return false
        case .success, .warning, .unknown:
            guard isOracleSendTool(execution.toolName) else { return false }
            return OracleToolResultInspection.inspect(
                resultJSON: execution.resultJSON,
                text: nil,
                toolIsError: execution.toolIsError,
                statusWord: AgentTranscriptToolStatusSemantics.persistedStatusWord(from: execution.status)
            ) != nil
        }
    }

    /// Header suffix text, or `nil` when nothing failed. A hidden suffix does not claim that every
    /// call succeeded: older groups only know the evidence their summaries retained.
    static func headerSuffix(failedCount: Int?) -> String? {
        guard let failedCount, failedCount > 0 else { return nil }
        return " • \(failedCount) failed"
    }

    private static func isOracleSendTool(_ toolName: String?) -> Bool {
        let normalized = (AgentTranscriptToolNormalizer.normalizedToolName(toolName) ?? toolName ?? "").lowercased()
        return normalized == "ask_oracle" || normalized == "oracle_send"
    }
}
