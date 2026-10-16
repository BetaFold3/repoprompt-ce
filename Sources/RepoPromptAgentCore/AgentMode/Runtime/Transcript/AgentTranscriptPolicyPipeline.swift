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

    /// `runtimeTranscript(transcript).transcript` without the final projection build: each
    /// post-refresh stabilization ID set comes from the structural visibility query instead of
    /// `visibleToolResultRowIDs(in: build(from:))`, which reads the same rows.
    static func runtimeTranscriptOnly(_ transcript: AgentTranscript) -> AgentTranscript {
        stabilizeRuntimeTranscript(
            transcript,
            stabilizationVisibleToolResultRowIDs: { refreshed in
                #if DEBUG
                    structuralVisibleToolResultRowIDs(
                        for: refreshed,
                        derivesFromProjection: derivesPostRefreshVisibilityFromProjection
                    )
                #else
                    structuralVisibleToolResultRowIDs(for: refreshed)
                #endif
            }
        ).metrics.transcript
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
        /// Test-only reference mode: `runtimeTranscriptOnly` derives each post-refresh
        /// stabilization ID set from a full projection build, as `runtimeTranscript` does.
        @TaskLocal static var derivesPostRefreshVisibilityFromProjection = false
    #endif

    /// The tool-result rows visible in `build(from: transcript)`; the structural query avoids
    /// constructing that projection, which only this ID set would read. DEBUG reference modes
    /// derive the set from a full projection build instead, for differential comparison.
    private static func structuralVisibleToolResultRowIDs(
        for transcript: AgentTranscript,
        derivesFromProjection: Bool = false
    ) -> Set<UUID> {
        #if DEBUG
            if derivesFromProjection {
                return AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
                    in: AgentTranscriptProjectionBuilder.build(from: transcript)
                )
            }
        #endif
        return AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(for: transcript)
    }

    private static func initialVisibleToolResultRowIDs(for transcript: AgentTranscript) -> Set<UUID> {
        #if DEBUG
            structuralVisibleToolResultRowIDs(for: transcript, derivesFromProjection: derivesInitialVisibilityFromProjection)
        #else
            structuralVisibleToolResultRowIDs(for: transcript)
        #endif
    }

    private struct RuntimeStabilization {
        let metrics: AgentSanitizedTranscriptMetrics
        let visibleToolResultRowIDs: Set<UUID>
        /// False only when retries were exhausted: the last re-sanitized transcript was never
        /// passed to the stabilization query.
        let queriedFinalTranscript: Bool
    }

    private static func sanitizedAndRefreshedRuntimeMetrics(
        _ transcript: AgentTranscript,
        preservedVisibleToolResultRowIDs: Set<UUID>
    ) -> AgentSanitizedTranscriptMetrics {
        let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
            purpose: .runtimePresentation
        )
        return .init(
            transcript: AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: metrics.transcript),
            sanitizedActivityCount: metrics.sanitizedActivityCount,
            reusedTurnCount: metrics.reusedTurnCount,
            incrementalPathReason: metrics.incrementalPathReason
        )
    }

    /// Sanitizes from the original `transcript` with the initial visible IDs, then re-sanitizes from
    /// the original with each changed post-refresh ID set, at most 3 times.
    /// `stabilizationVisibleToolResultRowIDs` is called once per loop iteration, on the current
    /// sanitized and cache-refreshed transcript, exactly when its IDs are compared.
    private static func stabilizeRuntimeTranscript(
        _ transcript: AgentTranscript,
        stabilizationVisibleToolResultRowIDs: (AgentTranscript) -> Set<UUID>
    ) -> RuntimeStabilization {
        var visibleToolResultRowIDs = initialVisibleToolResultRowIDs(for: transcript)
        var finalMetrics = sanitizedAndRefreshedRuntimeMetrics(
            transcript,
            preservedVisibleToolResultRowIDs: visibleToolResultRowIDs
        )
        for _ in 0 ..< 3 {
            let stabilizedVisibleToolResultRowIDs = stabilizationVisibleToolResultRowIDs(finalMetrics.transcript)
            guard stabilizedVisibleToolResultRowIDs != visibleToolResultRowIDs else {
                return RuntimeStabilization(
                    metrics: finalMetrics,
                    visibleToolResultRowIDs: stabilizedVisibleToolResultRowIDs,
                    queriedFinalTranscript: true
                )
            }
            visibleToolResultRowIDs = stabilizedVisibleToolResultRowIDs
            finalMetrics = sanitizedAndRefreshedRuntimeMetrics(
                transcript,
                preservedVisibleToolResultRowIDs: visibleToolResultRowIDs
            )
        }
        return RuntimeStabilization(
            metrics: finalMetrics,
            visibleToolResultRowIDs: visibleToolResultRowIDs,
            queriedFinalTranscript: false
        )
    }

    private static func materializeRuntimeTranscript(_ transcript: AgentTranscript) -> Result {
        var latestProjection: AgentTranscriptProjection?
        let stabilization = stabilizeRuntimeTranscript(transcript) { refreshed in
            let projection = AgentTranscriptProjectionBuilder.build(from: refreshed)
            latestProjection = projection
            return AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: projection)
        }
        let finalProjection: AgentTranscriptProjection = if stabilization.queriedFinalTranscript, let latestProjection {
            latestProjection
        } else {
            // Exhausted retries: the last re-sanitized transcript is built once, as before.
            AgentTranscriptProjectionBuilder.build(from: stabilization.metrics.transcript)
        }
        let finalMetrics = stabilization.metrics

        return Result(
            transcript: finalMetrics.transcript,
            projection: finalProjection,
            visibleToolResultRowIDs: stabilization.visibleToolResultRowIDs,
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
