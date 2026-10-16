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

    #if DEBUG
        /// Test-only reference mode: derive the initial visible tool-result IDs from a full
        /// projection build, as before the structural query, for differential comparison.
        @TaskLocal static var derivesInitialVisibilityFromProjection = false
    #endif

    /// The tool-result rows visible in `build(from: transcript)`; the structural query avoids
    /// constructing that projection, which only this ID set would read.
    private static func initialVisibleToolResultRowIDs(for transcript: AgentTranscript) -> Set<UUID> {
        #if DEBUG
            if derivesInitialVisibilityFromProjection {
                return AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
                    in: AgentTranscriptProjectionBuilder.build(from: transcript)
                )
            }
        #endif
        return AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(for: transcript)
    }

    private static func materializeRuntimeTranscript(_ transcript: AgentTranscript) -> Result {
        var visibleToolResultRowIDs = initialVisibleToolResultRowIDs(for: transcript)
        var finalMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            preservedVisibleToolResultRowIDs: visibleToolResultRowIDs,
            purpose: .runtimePresentation
        )
        finalMetrics = .init(
            transcript: AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: finalMetrics.transcript),
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            reusedTurnCount: finalMetrics.reusedTurnCount,
            incrementalPathReason: finalMetrics.incrementalPathReason
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
                reusedTurnCount: finalMetrics.reusedTurnCount,
                incrementalPathReason: finalMetrics.incrementalPathReason
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
        let refreshedStorage = AgentTranscriptProjectionBuilder.refreshGroupedHistoryAndBuildStorageProjection(
            in: finalMetrics.transcript
        )
        finalMetrics = .init(
            transcript: refreshedStorage.transcript,
            sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
            reusedTurnCount: finalMetrics.reusedTurnCount,
            incrementalPathReason: finalMetrics.incrementalPathReason
        )
        let finalProjection = refreshedStorage.projection
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
