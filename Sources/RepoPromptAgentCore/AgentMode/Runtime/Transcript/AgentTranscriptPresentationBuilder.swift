import Foundation
import RepoPromptWorkspace

/// Record-only transcript presentation algorithm hoisted from `AgentModeViewModel`.
/// Scheduling and publication stay in the view model.
package enum AgentTranscriptPresentationBuilder {
    package nonisolated static func rebuildEphemeralToolResultPayloadMap(
        from items: [AgentChatItem],
        context: AgentToolResultProcessingContext? = nil,
        diagnosticContext: String? = nil
    ) -> [UUID: String] {
        var payloadByItemID: [UUID: String] = [:]
        var firstRetainedItemByID: [UUID: (index: Int, item: AgentChatItem)] = [:]
        for (index, item) in items.enumerated() {
            guard let retainedPayload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item, context: context) else {
                continue
            }
            if let firstPayload = payloadByItemID[item.id] {
                let first = firstRetainedItemByID[item.id] ?? (index: index, item: item)
                AgentSourceItemIDRepair.logDuplicateRetainedToolResultPayload(
                    duplicateID: item.id,
                    firstIndex: first.index,
                    duplicateIndex: index,
                    firstItem: first.item,
                    duplicateItem: item,
                    firstPayload: firstPayload,
                    duplicatePayload: retainedPayload,
                    context: diagnosticContext,
                    toolResultContext: context
                )
                continue
            }
            payloadByItemID[item.id] = retainedPayload
            firstRetainedItemByID[item.id] = (index, item)
        }
        return payloadByItemID
    }

    private nonisolated static func visibleToolResultIDs(in projection: AgentTranscriptProjection) -> Set<UUID> {
        AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: projection)
    }

    private nonisolated static func degradeCollapsedTranscriptBlocksIfNeeded(
        _ projection: AgentTranscriptProjection,
        isColdLoad: Bool
    ) -> AgentTranscriptProjection {
        guard isColdLoad else { return projection }
        return AgentTranscriptProjection(
            workingBlocks: projection.workingBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            archivedBlocks: projection.archivedBlocks.map(degradeCollapsedTranscriptBlockIfNeeded),
            workingRows: projection.workingRows,
            archivedRows: projection.archivedRows,
            rowAnchorIndex: projection.rowAnchorIndex,
            anchorBlockIndex: projection.anchorBlockIndex,
            workingUnitCount: projection.workingUnitCount
        )
    }

    private nonisolated static func degradeCollapsedTranscriptBlockIfNeeded(
        _ block: AgentTranscriptRenderBlock
    ) -> AgentTranscriptRenderBlock {
        guard block.defaultPresentation == .collapsed else { return block }
        if block.kind == .activityCluster, !block.rows.isEmpty {
            return AgentTranscriptRenderBlock(
                id: block.id,
                kind: block.kind,
                turnID: block.turnID,
                spanID: block.spanID,
                retentionTier: block.retentionTier,
                rows: [],
                isArchived: block.isArchived,
                primaryAnchor: block.primaryAnchor,
                anchorActivityID: block.anchorActivityID,
                activityIDs: block.activityIDs,
                clusterSummary: block.clusterSummary,
                groupedHistory: block.groupedHistory,
                defaultPresentation: block.defaultPresentation
            )
        }
        guard block.kind == .groupedHistory,
              let groupedHistory = block.groupedHistory,
              !groupedHistory.sections.isEmpty
        else {
            return block
        }
        return AgentTranscriptRenderBlock(
            id: block.id,
            kind: block.kind,
            turnID: block.turnID,
            spanID: block.spanID,
            retentionTier: block.retentionTier,
            rows: block.rows,
            isArchived: block.isArchived,
            primaryAnchor: block.primaryAnchor,
            anchorActivityID: block.anchorActivityID,
            activityIDs: block.activityIDs,
            clusterSummary: block.clusterSummary,
            groupedHistory: .init(summary: groupedHistory.summary, sections: []),
            defaultPresentation: block.defaultPresentation
        )
    }

    #if DEBUG || EDIT_FLOW_PERF
        /// Records cumulative process-wide `BashToolResultParser` cache counters, one zero-work
        /// span per table, so they reach both signposts and the DEBUG EditFlowPerf capture.
        /// These are counter snapshots, not parser duration measurements; the snapshot is read
        /// only when a span is live (signposts enabled or capture active).
        nonisolated static func recordBashParserCacheCounterSnapshots() {
            for table in ["metadata", "parsed"] {
                let span = EditFlowPerf.begin(EditFlowPerf.Stage.Transcript.bashParserCache)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Transcript.bashParserCache,
                    span,
                    {
                        let snapshot = BashToolResultParser.cacheCountersSnapshot()
                        let counters = table == "metadata" ? snapshot.metadata : snapshot.parsed
                        return EditFlowPerf.Dimensions(
                            scanKind: table,
                            hitCount: counters.hitCount,
                            missCount: counters.missCount,
                            evictedCount: counters.evictedEntryCount,
                            entryCount: counters.currentEntryCount
                        )
                    }()
                )
            }
        }
    #endif

    package nonisolated static func transcriptDiagnosticFinalTurnItemCount(_ sourceItems: [AgentChatItem]) -> Int? {
        AgentTranscriptIO.finalTurnStartIndex(in: sourceItems).map { sourceItems.count - $0 }
    }

    package nonisolated static func buildTranscriptPresentation(
        from transcript: AgentTranscript,
        sourceItems: [AgentChatItem],
        precomputedEphemeralPayloadByItemID: [UUID: String]? = nil,
        precomputedEphemeralPayloadRevisionByItemID: [UUID: Int]? = nil,
        selectedAgent: AgentProviderKind,
        previousPerformanceSnapshot: AgentTranscriptPerformanceSnapshot,
        previousSanitizedTranscript: AgentTranscript? = nil,
        previousRawInputEvidence: AgentSanitizeRawInputEvidence? = nil,
        previousBaseProjection: AgentTranscriptProjection? = nil,
        previousTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:],
        previousProjectionProtection: AgentTranscriptProjectionProtection = .none,
        projectionProtection: AgentTranscriptProjectionProtection = .none,
        isCompressedHistoryRevealed: Bool = false,
        isColdLoad: Bool = false,
        trustedIncrementalFinalTurnStartSequenceIndex: Int? = nil,
        diagnosticTabTag: String? = nil
    ) -> AgentBuiltTranscriptPresentation {
        let processingContext = AgentToolResultProcessingContext()
        #if DEBUG || EDIT_FLOW_PERF
            let buildStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let projectionSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.projectionBuild,
            EditFlowPerf.Dimensions(
                sourceItemCount: sourceItems.count,
                tabTag: diagnosticTabTag,
                finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems)
            )
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let payloadSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.payloadMap,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: sourceItems.count
            )
        )
        let capturedPayloadByItemID: [UUID: String]
        let capturedPayloadRevisionByItemID: [UUID: Int]
        let payloadScannedItemCount: Int
        if let precomputedEphemeralPayloadByItemID {
            capturedPayloadByItemID = precomputedEphemeralPayloadByItemID
            capturedPayloadRevisionByItemID = precomputedEphemeralPayloadRevisionByItemID ?? [:]
            payloadScannedItemCount = 0
        } else {
            capturedPayloadByItemID = rebuildEphemeralToolResultPayloadMap(from: sourceItems, context: processingContext)
            capturedPayloadRevisionByItemID = Dictionary(
                uniqueKeysWithValues: capturedPayloadByItemID.keys.map { ($0, 1) }
            )
            payloadScannedItemCount = sourceItems.count
        }
        #if DEBUG || EDIT_FLOW_PERF
            let capturedPayloadBytes = capturedPayloadByItemID.values.reduce(0) {
                $0 + $1.lengthOfBytes(using: .utf8)
            }
        #else
            let capturedPayloadBytes = 0
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.payloadMap,
            payloadSignpost,
            EditFlowPerf.Dimensions(
                outcome: precomputedEphemeralPayloadByItemID == nil ? "full_rebuild" : "precomputed",
                sourceItemCount: payloadScannedItemCount,
                retainedPayloadCount: capturedPayloadByItemID.count,
                retainedPayloadBytes: capturedPayloadBytes
            )
        )
        #if DEBUG || EDIT_FLOW_PERF
            let payloadCaptureDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - payloadCaptureStartedAt) * 1000)
            var performanceSnapshot = previousPerformanceSnapshot
            let sanitizeStartedAt = CFAbsoluteTimeGetCurrent()
        #else
            var performanceSnapshot = AgentTranscriptPerformanceSnapshot.empty
        #endif
        let sanitizeSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.sanitize,
            EditFlowPerf.Dimensions(
                sourceItemCount: sourceItems.count,
                tabTag: diagnosticTabTag,
                finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems)
            )
        )
        // Raw-input activity comparison needs the previous build's exact raw input, processing
        // flags, and output; with that evidence it replaces the turn-prefix and trusted-suffix
        // hints. Without it, a live mutation keeps the legacy prefix and trusted-suffix hints,
        // while a full import takes one recording pass (no prefix hint) so evidence is re-seeded.
        let usesRawInputActivityReuse = previousRawInputEvidence != nil && previousSanitizedTranscript != nil
        let seedsRawInputEvidence = !usesRawInputActivityReuse && trustedIncrementalFinalTurnStartSequenceIndex == nil
        let sanitizeReusableTurnCount = usesRawInputActivityReuse || seedsRawInputEvidence
            ? 0
            : commonEqualTurnPrefixCount(
                in: transcript,
                previousTranscript: previousSanitizedTranscript
            )
        #if DEBUG || EDIT_FLOW_PERF
            if sanitizeReusableTurnCount > 0 || usesRawInputActivityReuse {
                performanceSnapshot.sanitizeReuseAttemptCount += 1
            }
        #endif
        let sanitizeMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            previousRawInputEvidence: usesRawInputActivityReuse ? previousRawInputEvidence : nil,
            reusablePrefixTurnCount: seedsRawInputEvidence ? 0 : (sanitizeReusableTurnCount > 0 ? sanitizeReusableTurnCount : nil),
            trustedIncrementalFinalTurnStartSequenceIndex: usesRawInputActivityReuse
                ? nil
                : trustedIncrementalFinalTurnStartSequenceIndex,
            context: processingContext,
            purpose: .runtimePresentation
        )
        let sanitizedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
            in: sanitizeMetrics.transcript,
            reusablePrefixTurnCount: sanitizeMetrics.reusedTurnCount
        )
        #if DEBUG || EDIT_FLOW_PERF
            performanceSnapshot.lastSanitizeReusedActivityCount = usesRawInputActivityReuse
                ? sanitizeMetrics.reusedActivityCount
                : nil
            if usesRawInputActivityReuse {
                if sanitizeMetrics.reusedActivityCount > 0 {
                    performanceSnapshot.sanitizeReuseSuccessCount += 1
                } else {
                    performanceSnapshot.sanitizeReuseFallbackCount += 1
                }
                performanceSnapshot.lastSanitizeReusedTurnCount = sanitizeMetrics.reusedTurnCount
            } else if sanitizeReusableTurnCount > 0 {
                if sanitizeMetrics.reusedTurnCount > 0 {
                    performanceSnapshot.sanitizeReuseSuccessCount += 1
                } else {
                    performanceSnapshot.sanitizeReuseFallbackCount += 1
                }
                performanceSnapshot.lastSanitizeReusedTurnCount = sanitizeMetrics.reusedTurnCount
            } else {
                performanceSnapshot.lastSanitizeReusedTurnCount = nil
            }
            let sanitizeDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - sanitizeStartedAt) * 1000)
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.sanitize,
            sanitizeSignpost,
            EditFlowPerf.Dimensions(
                outcome: sanitizeMetrics.reusedActivityCount > 0
                    ? "reused_activities"
                    : (sanitizeMetrics.reusedTurnCount > 0 ? "reused_prefix" : "rebuilt"),
                sourceItemCount: sourceItems.count,
                sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
                tabTag: diagnosticTabTag,
                finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems),
                fallbackReason: sanitizeMetrics.incrementalPathReason.rawValue
            )
        )
        let projectionOnlySignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.projectionOnly,
            EditFlowPerf.Dimensions(
                sourceItemCount: sourceItems.count,
                tabTag: diagnosticTabTag,
                finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems)
            )
        )
        let projectionReusableTurnCount = AgentTranscriptIO.validatedReusableFrozenPrefixTurnCount(in: sanitizedTranscript) ?? 0
        let baseProjection: AgentTranscriptProjection
        let updatedTurnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
        if projectionReusableTurnCount > 0,
           let previousSanitizedTranscript,
           !previousSanitizedTranscript.turns.isEmpty,
           let previousBaseProjection
        {
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.projectionReuseAttemptCount += 1
            #endif
            if let reusedProjection = AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(
                from: sanitizedTranscript,
                previousTranscript: previousSanitizedTranscript,
                previousProjection: previousBaseProjection,
                previousProtection: previousProjectionProtection,
                protection: projectionProtection,
                reusableFrozenPrefixTurnCount: projectionReusableTurnCount,
                context: processingContext
            ) {
                baseProjection = reusedProjection
                updatedTurnProjectionCaches = AgentTranscriptProjectionBuilder.updatedTurnCaches(
                    for: sanitizedTranscript,
                    projection: reusedProjection,
                    protection: projectionProtection,
                    existingTurnCaches: previousTurnProjectionCaches
                )
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseSuccessCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = projectionReusableTurnCount
                #endif
            } else {
                let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                    from: sanitizedTranscript,
                    protection: projectionProtection,
                    turnCaches: previousTurnProjectionCaches,
                    context: processingContext
                )
                baseProjection = buildResult.projection
                updatedTurnProjectionCaches = buildResult.updatedTurnCaches
                #if DEBUG || EDIT_FLOW_PERF
                    performanceSnapshot.projectionReuseFallbackCount += 1
                    performanceSnapshot.lastProjectionReusedTurnCount = 0
                #endif
            }
        } else {
            let buildResult = AgentTranscriptProjectionBuilder.buildWithCaches(
                from: sanitizedTranscript,
                protection: projectionProtection,
                turnCaches: previousTurnProjectionCaches,
                context: processingContext
            )
            baseProjection = buildResult.projection
            updatedTurnProjectionCaches = buildResult.updatedTurnCaches
            #if DEBUG || EDIT_FLOW_PERF
                performanceSnapshot.lastProjectionReusedTurnCount = nil
            #endif
        }
        let visibleRetainedIDs = visibleToolResultIDs(in: baseProjection)
        let rawToolResultPayloadRenderRevisionByItemID = Dictionary(
            uniqueKeysWithValues: visibleRetainedIDs.compactMap { itemID in
                capturedPayloadRevisionByItemID[itemID].map { (itemID, $0) }
            }
        )
        let fullProjection = degradeCollapsedTranscriptBlocksIfNeeded(
            baseProjection,
            isColdLoad: isColdLoad
        )
        let workingProjection = AgentTranscriptProjectionBuilder.workingProjection(from: fullProjection)
        let archivedSnapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: fullProjection)
        let projection = isCompressedHistoryRevealed ? fullProjection : workingProjection
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: baseProjection)
        let canonicalVisibleRowCount = projectionCounts.canonicalVisibleRowCount
        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.projectionOnly,
            projectionOnlySignpost,
            EditFlowPerf.Dimensions(
                lineCount: canonicalVisibleRowCount,
                sourceItemCount: sourceItems.count,
                tabTag: diagnosticTabTag,
                finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems)
            )
        )
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled, let previousBaseProjection {
                let previousRows = previousBaseProjection.archivedRows + previousBaseProjection.workingRows
                let newRows = baseProjection.archivedRows + baseProjection.workingRows
                let previousBlocks = previousBaseProjection.archivedBlocks + previousBaseProjection.workingBlocks
                let newBlocks = baseProjection.archivedBlocks + baseProjection.workingBlocks
                let previousRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(previousRows)
                let newRowSemanticDigest = AgentTranscriptDebugInstrumentation.itemSemanticSignature(newRows)
                let previousRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(previousRows)
                let newRowIdentityDigest = AgentTranscriptDebugInstrumentation.itemIdentitySignature(newRows)
                let previousBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(previousBlocks)
                let newBlockSemanticDigest = AgentTranscriptDebugInstrumentation.blockSemanticSignature(newBlocks)
                let previousBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(previousBlocks)
                let newBlockIdentityDigest = AgentTranscriptDebugInstrumentation.blockIdentitySignature(newBlocks)
                AgentTranscriptDebugInstrumentation.projectionIdentityHandler?(.init(
                    previousRowCount: previousRows.count,
                    newRowCount: newRows.count,
                    previousBlockCount: previousBlocks.count,
                    newBlockCount: newBlocks.count,
                    rowSemanticDigest: newRowSemanticDigest,
                    previousRowSemanticDigest: previousRowSemanticDigest,
                    rowIdentityDigest: newRowIdentityDigest,
                    previousRowIdentityDigest: previousRowIdentityDigest,
                    blockSemanticDigest: newBlockSemanticDigest,
                    previousBlockSemanticDigest: previousBlockSemanticDigest,
                    blockIdentityDigest: newBlockIdentityDigest,
                    previousBlockIdentityDigest: previousBlockIdentityDigest,
                    rowIdentityDrift: newRowSemanticDigest == previousRowSemanticDigest && newRowIdentityDigest != previousRowIdentityDigest,
                    blockIdentityDrift: newBlockSemanticDigest == previousBlockSemanticDigest && newBlockIdentityDigest != previousBlockIdentityDigest
                ))
            }
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let buildDurationMS = max(0, (CFAbsoluteTimeGetCurrent() - buildStartedAt) * 1000)
            performanceSnapshot.projectionBuildCount += 1
            performanceSnapshot.lastProjectionBuildDurationMS = buildDurationMS
            performanceSnapshot.lastPayloadCaptureDurationMS = payloadCaptureDurationMS
            performanceSnapshot.maxPayloadCaptureDurationMS = max(
                performanceSnapshot.maxPayloadCaptureDurationMS ?? 0,
                payloadCaptureDurationMS
            )
            performanceSnapshot.lastSanitizeDurationMS = sanitizeDurationMS
            performanceSnapshot.maxSanitizeDurationMS = max(
                performanceSnapshot.maxSanitizeDurationMS ?? 0,
                sanitizeDurationMS
            )
            performanceSnapshot.maxProjectionBuildDurationMS = max(
                performanceSnapshot.maxProjectionBuildDurationMS ?? 0,
                buildDurationMS
            )
            performanceSnapshot.lastPayloadCaptureScannedItemCount = payloadScannedItemCount
            performanceSnapshot.lastSanitizedActivityCount = sanitizeMetrics.sanitizedActivityCount
            performanceSnapshot.retainedRawPayloadEntryCount = capturedPayloadByItemID.count
            performanceSnapshot.retainedRawPayloadTotalBytes = capturedPayloadBytes
            let toolProcessingMetrics = processingContext.snapshotMetrics()
            performanceSnapshot.lastToolProcessingMetrics = toolProcessingMetrics
            performanceSnapshot.cumulativeToolProcessingMetrics.add(toolProcessingMetrics)
            EditFlowPerf.event(
                EditFlowPerf.Stage.Transcript.toolProcessing,
                EditFlowPerf.Dimensions(
                    sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes,
                    jsonParseAttemptCount: toolProcessingMetrics.jsonParseAttemptCount,
                    jsonParseCacheHitCount: toolProcessingMetrics.jsonParseCacheHitCount,
                    jsonParseCacheMissCount: toolProcessingMetrics.jsonParseCacheMissCount,
                    jsonParseSuccessCount: toolProcessingMetrics.jsonParseSuccessCount,
                    jsonParseFailureCount: toolProcessingMetrics.jsonParseFailureCount,
                    jsonParseByteCount: toolProcessingMetrics.jsonParseByteCount,
                    toolExecutionCacheHitCount: toolProcessingMetrics.toolExecutionCacheHitCount,
                    toolExecutionCacheMissCount: toolProcessingMetrics.toolExecutionCacheMissCount,
                    bashMetadataCacheHitCount: toolProcessingMetrics.bashMetadataCacheHitCount,
                    bashMetadataCacheMissCount: toolProcessingMetrics.bashMetadataCacheMissCount,
                    regexCaptureCallCount: toolProcessingMetrics.regexCaptureCallCount
                )
            )
            recordBashParserCacheCounterSnapshots()
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.projectionBuild,
                projectionSignpost,
                EditFlowPerf.Dimensions(
                    outcome: performanceSnapshot.lastProjectionReusedTurnCount.map { $0 > 0 ? "reused_prefix" : "fallback" } ?? "built",
                    lineCount: canonicalVisibleRowCount,
                    sourceItemCount: sourceItems.count,
                    retainedPayloadCount: capturedPayloadByItemID.count,
                    retainedPayloadBytes: capturedPayloadBytes,
                    tabTag: diagnosticTabTag,
                    finalTurnItemCount: transcriptDiagnosticFinalTurnItemCount(sourceItems)
                )
            )
            if isColdLoad {
                performanceSnapshot.lastColdLoadProjectionBuildDurationMS = buildDurationMS
            }
        #endif
        return AgentBuiltTranscriptPresentation(
            transcript: sanitizedTranscript,
            baseProjection: baseProjection,
            fullProjection: fullProjection,
            workingProjection: workingProjection,
            projection: projection,
            turnProjectionCaches: updatedTurnProjectionCaches,
            archivedSnapshot: archivedSnapshot,
            projectionProtection: projectionProtection,
            canonicalVisibleRowCount: canonicalVisibleRowCount,
            projectionCounts: projectionCounts,
            analyticsSnapshot: AgentTranscriptAnalyticsBuilder.build(
                from: sanitizedTranscript,
                selectedAgent: selectedAgent
            ),
            sanitizedActivityCount: sanitizeMetrics.sanitizedActivityCount,
            performanceSnapshot: performanceSnapshot,
            rawToolResultPayloadRenderRevisionByItemID: rawToolResultPayloadRenderRevisionByItemID,
            // Only builds that processed (or replayed from evidence) every activity record flags;
            // prefix or trusted-suffix reuse installs activities unchecked and never seeds evidence.
            rawInputSanitizeEvidence: sanitizeMetrics.activityProcessingFlags.map {
                AgentSanitizeRawInputEvidence(importedTranscript: transcript, activityProcessingFlags: $0)
            }
        )
    }

    package nonisolated static func commonEqualTurnPrefixCount(
        in transcript: AgentTranscript,
        previousTranscript: AgentTranscript?
    ) -> Int {
        guard let previousTranscript else { return 0 }
        let limit = min(transcript.turns.count, previousTranscript.turns.count)
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit,
              transcript.turns[count] == previousTranscript.turns[count]
        {
            count += 1
        }
        return count
    }
}
