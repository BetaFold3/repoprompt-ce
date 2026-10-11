import Foundation

enum AgentTranscriptPolicyPipeline {
    struct Result {
        let transcript: AgentTranscript
        let projection: AgentTranscriptProjection
        let visibleToolResultRowIDs: Set<UUID>
        let sanitizedActivityCount: Int
        let retainedFullDetailBytes: Int
    }

    private enum MaterializationPurpose {
        case runtimePresentation
        case persistentStorage
    }

    static func runtimeTranscript(_ transcript: AgentTranscript) -> Result {
        materialize(transcript, purpose: .runtimePresentation)
    }

    static func persistedTranscript(
        from transcript: AgentTranscript,
        protection: AgentTranscriptProjectionProtection = .none
    ) -> Result {
        let normalized = AgentTranscriptCompactor.compact(
            transcript,
            protection: protection
        )
        return persistedNormalizedTranscript(normalized)
    }

    static func persistedNormalizedTranscript(_ transcript: AgentTranscript) -> Result {
        materialize(
            AgentTranscriptHistoricalTruncationPolicy.truncatedTranscript(transcript),
            purpose: .persistentStorage
        )
    }

    static func handoffTranscript(
        from transcript: AgentTranscript,
        upToRowID: UUID?
    ) -> Result {
        let exportTurns = AgentTranscriptIO.turnsForExport(from: transcript, upToRowID: upToRowID)
        let truncatedTurns = AgentTranscriptHistoricalTruncationPolicy.truncatedExportSlice(exportTurns)
        let exportTranscript = AgentTranscript(
            version: transcript.version,
            turns: truncatedTurns,
            nextSequenceIndex: transcript.nextSequenceIndex,
            compactionFrontier: nil
        )
        return materialize(exportTranscript, purpose: .runtimePresentation)
    }

    private static func materialize(
        _ transcript: AgentTranscript,
        purpose: MaterializationPurpose
    ) -> Result {
        switch purpose {
        case .runtimePresentation:
            materializeRuntimeTranscript(transcript)
        case .persistentStorage:
            materializePersistentStorageTranscript(transcript)
        }
    }

    private static func materializeRuntimeTranscript(_ transcript: AgentTranscript) -> Result {
        var visibleToolResultRowIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
            in: AgentTranscriptProjectionBuilder.build(from: transcript)
        )
        var finalMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            preservedVisibleToolResultRowIDs: visibleToolResultRowIDs,
            purpose: .runtimePresentation
        )
        finalMetrics = .init(
            transcript: AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: finalMetrics.transcript),
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            reusedTurnCount: finalMetrics.reusedTurnCount
        )
        var finalProjection = AgentTranscriptProjectionBuilder.build(from: finalMetrics.transcript)

        for _ in 0 ..< 3 {
            let stabilizedVisibleToolResultRowIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
                in: finalProjection
            )
            guard stabilizedVisibleToolResultRowIDs != visibleToolResultRowIDs else {
                visibleToolResultRowIDs = stabilizedVisibleToolResultRowIDs
                break
            }
            visibleToolResultRowIDs = stabilizedVisibleToolResultRowIDs
            finalMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
                transcript,
                preservedVisibleToolResultRowIDs: visibleToolResultRowIDs,
                purpose: .runtimePresentation
            )
            finalMetrics = .init(
                transcript: AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: finalMetrics.transcript),
                sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
                reusedTurnCount: finalMetrics.reusedTurnCount
            )
            finalProjection = AgentTranscriptProjectionBuilder.build(from: finalMetrics.transcript)
        }

        return Result(
            transcript: finalMetrics.transcript,
            projection: finalProjection,
            visibleToolResultRowIDs: visibleToolResultRowIDs,
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            retainedFullDetailBytes: AgentTranscriptCompactor.retainedFullDetailBytes(for: finalMetrics.transcript)
        )
    }

    private static func materializePersistentStorageTranscript(_ transcript: AgentTranscript) -> Result {
        var finalMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(transcript)
        finalMetrics = .init(
            transcript: AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: finalMetrics.transcript),
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            reusedTurnCount: finalMetrics.reusedTurnCount
        )
        let finalProjection = AgentTranscriptProjectionBuilder.build(from: finalMetrics.transcript)
        let visibleToolResultRowIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: finalProjection)

        return Result(
            transcript: finalMetrics.transcript,
            projection: finalProjection,
            visibleToolResultRowIDs: visibleToolResultRowIDs,
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            retainedFullDetailBytes: AgentTranscriptCompactor.retainedFullDetailBytes(for: finalMetrics.transcript)
        )
    }
}
