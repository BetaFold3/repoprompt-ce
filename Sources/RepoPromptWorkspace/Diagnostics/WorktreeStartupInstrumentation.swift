import Foundation
#if DEBUG
    import CryptoKit
#endif

package enum WorkspaceRootStartupRoute: String, Equatable {
    case fullCrawl
    case diffSeedObservation
    case diffSeedServing
}

package enum WorktreeStartupPhase: String, Equatable {
    case agentRunStarted
    case worktreePreparationStarted
    case bindingTransitionStarted
    case rootLoadStarted
    case shadowVerified
    case seedWatcherAttached
    case seedReplayFenced
    case seedReadyForCommit
    case seedPublished
    case seedFallback
    case rootReady
    case providerStart
    #if DEBUG
        case firstBenchmarkSearchStarted
        case firstBenchmarkSearchCompleted
        case firstBenchmarkReadStarted
        case firstBenchmarkReadCompleted
        case firstBenchmarkCodemapStarted
        case firstBenchmarkCodemapCompleted
        case warmBenchmarkCodemapStarted
        case warmBenchmarkCodemapCompleted
        case passiveBenchmarkTreeStarted
        case passiveBenchmarkTreeCompleted
        case benchmarkSelectionStarted
        case benchmarkSelectionCompleted
    #endif
    case failed
}

#if DEBUG
    package enum WorktreeStartupPreparationInstrumentation {
        package enum Phase: String, CaseIterable, Equatable {
            case scopeResolution = "scope_resolution"
            case setFlagsTotal = "set_flags_total"
            case loadedRootIngressFence = "loaded_root_ingress_fence"
            case loadedRootPolicySnapshot = "loaded_root_policy_snapshot"
            case discoveryObservation = "discovery_observation"
            case discoveryAuthorityCapture = "discovery_authority_capture"
            case replacementObservation = "replacement_observation"
            case collectionFence = "collection_fence"
            case capturedAuthorityCapture = "captured_authority_capture"
            case capturedObservationValidation = "captured_observation_validation"
            case authorityMetadataGit = "authority_metadata_git"
            case prefixControlCacheLookup = "prefix_control_cache_lookup"
            case prefixControlScan = "prefix_control_scan"
            case prefixControlCacheAdmit = "prefix_control_cache_admit"
            case treeInventorySpool = "tree_inventory_spool"
            case catalogManifestBuild = "catalog_manifest_build"
            case authorityInstall = "authority_install"
            case snapshotMaterialization = "snapshot_materialization"
            case admissionPrepare = "admission_prepare"
            case preparedAdmissionCurrentness = "prepared_admission_currentness"
            case admissionCommit = "admission_commit"
            case committedAdmissionCurrentness = "committed_admission_currentness"
            case finalLoadedRootCurrentness = "final_loaded_root_currentness"
        }

        package enum Counter: String, CaseIterable, Equatable {
            case authorityCaptures = "authority_captures"
            case gitCommandCount = "git_command_count"
            case gitQueueMicroseconds = "git_queue_us"
            case gitDurationMicroseconds = "git_duration_us"
            case prefixCacheHits = "prefix_cache_hits"
            case prefixCacheMisses = "prefix_cache_misses"
            case prefixCacheInvalidations = "prefix_cache_invalidations"
            case prefixCacheAdmissions = "prefix_cache_admissions"
            case prefixCacheEvictions = "prefix_cache_evictions"
            case prefixCacheBypasses = "prefix_cache_bypasses"
            case prefixCacheCoalesces = "prefix_cache_coalesces"
            case prefixScanCount = "prefix_scan_count"
            case enumeratedCandidates = "enumerated_candidates"
            case enumeratedDirectories = "enumerated_directories"
            case explicitlyPrunedDirectories = "explicitly_pruned_directories"
            case controlRecordCount = "control_record_count"
            case treeRecords = "tree_records"
            case treeSpoolBytes = "tree_spool_bytes"
            case inventoryRecords = "inventory_records"
            case catalogBatches = "catalog_batches"
            case catalogRegularPaths = "catalog_regular_paths"
            case snapshotSearchablePaths = "snapshot_searchable_paths"
        }

        package enum Reason: String, CaseIterable, Equatable {
            case absent
            case bypassed
            case rootIdentityChanged = "root_identity_changed"
            case authorityGenerationChanged = "authority_generation_changed"
            case watermarkAdvanced = "watermark_advanced"
            case coverageLost = "coverage_lost"
            case monitorUnavailable = "monitor_unavailable"
            case controlOrTopologyEvent = "control_or_topology_event"
            case monitorGap = "monitor_gap"
            case replacement
            case capacityEviction = "capacity_eviction"
            case staleCurrentness = "stale_currentness"
            case fallback
            case failure
            case cancellation
        }

        package enum TerminalState: String, Equatable {
            case admitted
            case failed
            case cancelled
        }

        package struct PhaseSnapshot: Equatable {
            package let count: UInt64
            package let completedCount: UInt64
            package let completedDurationNanoseconds: UInt64
            package let activeCount: UInt64
            package let activeElapsedNanoseconds: UInt64
        }

        package struct RouteControlOwnership: Equatable {
            package let controlID: UUID
            package let windowID: Int
            package let workspaceID: UUID
            package let contextID: UUID
            package let rootID: UUID
            package let revoked: Bool
        }

        package struct Snapshot: Equatable {
            package let preparationID: UUID
            package let startedAtNanoseconds: UInt64
            package let elapsedNanoseconds: UInt64
            package let terminalState: TerminalState?
            package let currentActivePhase: Phase?
            package let routeControlOwnership: RouteControlOwnership?
            package let phases: [Phase: PhaseSnapshot]
            package let counters: [Counter: UInt64]
            package let saturatedCounters: Set<Counter>
            package let reasons: [Reason: UInt64]
        }

        package final class Span: @unchecked Sendable {
            private let lock = NSLock()
            private weak var recorder: Recorder?
            private var token: UUID?

            fileprivate init(recorder: Recorder?, token: UUID?) {
                self.recorder = recorder
                self.token = token
            }

            package func end() {
                lock.lock()
                let finishingToken = token
                token = nil
                lock.unlock()
                guard let finishingToken else { return }
                recorder?.end(finishingToken)
            }

            deinit {
                end()
            }
        }

        package final class Recorder: @unchecked Sendable {
            private struct MutablePhase {
                var count: UInt64 = 0
                var completedCount: UInt64 = 0
                var completedDurationNanoseconds: UInt64 = 0
            }

            private struct ActiveSpan {
                let phase: Phase
                let startedAtNanoseconds: UInt64
                let ordinal: UInt64
            }

            let preparationID: UUID
            let startedAtNanoseconds: UInt64

            private let lock = NSLock()
            private var phases: [Phase: MutablePhase] = [:]
            private var activeSpans: [UUID: ActiveSpan] = [:]
            private var counters: [Counter: UInt64] = [:]
            private var saturatedCounters: Set<Counter> = []
            private var reasons: [Reason: UInt64] = [:]
            private var nextSpanOrdinal: UInt64 = 0
            private var terminalState: TerminalState?
            private var terminalAtNanoseconds: UInt64?
            private var routeControlOwnership: RouteControlOwnership?

            package init(preparationID: UUID, startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
                self.preparationID = preparationID
                self.startedAtNanoseconds = startedAtNanoseconds
            }

            package func begin(_ phase: Phase) -> Span {
                lock.lock()
                guard terminalState == nil else {
                    lock.unlock()
                    return Span(recorder: nil, token: nil)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                let token = UUID()
                nextSpanOrdinal = Self.saturatingAdd(nextSpanOrdinal, 1).value
                var metric = phases[phase] ?? MutablePhase()
                metric.count = Self.saturatingAdd(metric.count, 1).value
                phases[phase] = metric
                activeSpans[token] = ActiveSpan(
                    phase: phase,
                    startedAtNanoseconds: now,
                    ordinal: nextSpanOrdinal
                )
                lock.unlock()
                return Span(recorder: self, token: token)
            }

            package func recordCompleted(_ phase: Phase, durationNanoseconds: UInt64) {
                lock.lock()
                guard terminalState == nil else {
                    lock.unlock()
                    return
                }
                var metric = phases[phase] ?? MutablePhase()
                let count = Self.saturatingAdd(metric.count, 1)
                metric.count = count.value
                let completed = Self.saturatingAdd(metric.completedCount, 1)
                metric.completedCount = completed.value
                let duration = Self.saturatingAdd(metric.completedDurationNanoseconds, durationNanoseconds)
                metric.completedDurationNanoseconds = duration.value
                phases[phase] = metric
                lock.unlock()
            }

            func increment(_ counter: Counter, by amount: UInt64 = 1) {
                lock.lock()
                let result = Self.saturatingAdd(counters[counter, default: 0], amount)
                counters[counter] = result.value
                if result.saturated {
                    saturatedCounters.insert(counter)
                }
                lock.unlock()
            }

            func setAbsolute(_ counter: Counter, to value: UInt64) {
                lock.lock()
                counters[counter] = max(counters[counter, default: 0], value)
                lock.unlock()
            }

            package func recordReason(_ reason: Reason) {
                lock.lock()
                let result = Self.saturatingAdd(reasons[reason, default: 0], 1)
                reasons[reason] = result.value
                lock.unlock()
            }

            package func recordRouteControlOwnership(
                controlID: UUID,
                windowID: Int,
                workspaceID: UUID,
                contextID: UUID,
                rootID: UUID
            ) {
                lock.lock()
                if routeControlOwnership == nil {
                    routeControlOwnership = RouteControlOwnership(
                        controlID: controlID,
                        windowID: windowID,
                        workspaceID: workspaceID,
                        contextID: contextID,
                        rootID: rootID,
                        revoked: false
                    )
                }
                lock.unlock()
            }

            package func recordRouteControlRevoked(controlID: UUID) {
                lock.lock()
                if let ownership = routeControlOwnership,
                   ownership.controlID == controlID,
                   !ownership.revoked
                {
                    routeControlOwnership = RouteControlOwnership(
                        controlID: ownership.controlID,
                        windowID: ownership.windowID,
                        workspaceID: ownership.workspaceID,
                        contextID: ownership.contextID,
                        rootID: ownership.rootID,
                        revoked: true
                    )
                }
                lock.unlock()
            }

            @discardableResult
            package func terminalize(_ state: TerminalState) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard terminalState == nil else { return false }
                terminalState = state
                terminalAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                return true
            }

            package func snapshot(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Snapshot {
                lock.lock()
                defer { lock.unlock() }
                var phaseSnapshots = Dictionary(uniqueKeysWithValues: Phase.allCases.map {
                    ($0, PhaseSnapshot(
                        count: phases[$0]?.count ?? 0,
                        completedCount: phases[$0]?.completedCount ?? 0,
                        completedDurationNanoseconds: phases[$0]?.completedDurationNanoseconds ?? 0,
                        activeCount: 0,
                        activeElapsedNanoseconds: 0
                    ))
                })
                for active in activeSpans.values {
                    let prior = phaseSnapshots[active.phase]!
                    phaseSnapshots[active.phase] = PhaseSnapshot(
                        count: prior.count,
                        completedCount: prior.completedCount,
                        completedDurationNanoseconds: prior.completedDurationNanoseconds,
                        activeCount: Self.saturatingAdd(prior.activeCount, 1).value,
                        activeElapsedNanoseconds: Self.saturatingAdd(
                            prior.activeElapsedNanoseconds,
                            now >= active.startedAtNanoseconds ? now - active.startedAtNanoseconds : 0
                        ).value
                    )
                }
                let currentActivePhase = activeSpans.values.max(by: { $0.ordinal < $1.ordinal })?.phase
                let finishedAt = terminalAtNanoseconds ?? now
                return Snapshot(
                    preparationID: preparationID,
                    startedAtNanoseconds: startedAtNanoseconds,
                    elapsedNanoseconds: finishedAt >= startedAtNanoseconds ? finishedAt - startedAtNanoseconds : 0,
                    terminalState: terminalState,
                    currentActivePhase: currentActivePhase,
                    routeControlOwnership: routeControlOwnership,
                    phases: phaseSnapshots,
                    counters: Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0, counters[$0] ?? 0) }),
                    saturatedCounters: saturatedCounters,
                    reasons: Dictionary(uniqueKeysWithValues: Reason.allCases.map { ($0, reasons[$0] ?? 0) })
                )
            }

            fileprivate func end(_ token: UUID) {
                lock.lock()
                defer { lock.unlock() }
                guard let active = activeSpans.removeValue(forKey: token) else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                var metric = phases[active.phase] ?? MutablePhase()
                let completed = Self.saturatingAdd(metric.completedCount, 1)
                metric.completedCount = completed.value
                let elapsed = now >= active.startedAtNanoseconds ? now - active.startedAtNanoseconds : 0
                let duration = Self.saturatingAdd(metric.completedDurationNanoseconds, elapsed)
                metric.completedDurationNanoseconds = duration.value
                phases[active.phase] = metric
            }

            private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> (value: UInt64, saturated: Bool) {
                guard lhs <= UInt64.max - rhs else { return (UInt64.max, true) }
                return (lhs + rhs, false)
            }
        }

        @TaskLocal package static var currentRecorder: Recorder?
    }
#endif

package enum WorktreeStartupInstrumentation {
    #if DEBUG
        package enum ReceiptSourceLayoutState: String, Equatable {
            case missing
            case mainCheckout
            case linkedWorktree
        }

        package enum ReceiptDestinationEligibility: String, Equatable {
            case eligible
            case notAppManaged
            case includeCopyDisabled
        }

        package enum ReceiptParentLookupRoute: String, Equatable {
            case notAttempted
            case currentAlias
            case recovered
            case failed
        }

        package enum ReceiptParentLookupFailure: String, Equatable {
            case none
            case currentLeaseUnavailable
            case currentSnapshotUnavailable
            case recoveryObservationUnavailable
            case recoveryCollectionUnavailable
            case externalAuthorityChanged
            case recoveryObservationStale
            case recoveryInstallFailed
            case compatibleSnapshotMissing
            case recoveryAdmissionFailed
            case unexpected
        }

        package enum ReceiptGateState: String, Equatable {
            case notAttempted
            case succeeded
            case failed
        }

        package enum ReceiptMatchState: String, Equatable {
            case notEvaluated
            case match
            case mismatch
        }

        package enum ReceiptCreationOutcome: String, Equatable {
            case receiptEmitted
            case receiptAbsent
            case failed
            case cancelled
        }

        package enum ReceiptFinalObservation: Equatable {
            case eligible
            case disabled
            case fallback(WorkspaceRootSeedFallbackReason)
        }

        package enum ReceiptTerminalStage: String, Equatable {
            case creation
            case coordinator
            case projection
            case consumption
        }

        enum ReceiptDecisionDigestDomain: String {
            case authorityKey = "authority-key"
            case commonDirectory = "common-directory"
            case repositoryID = "repository-id"
            case repositoryNamespace = "repository-namespace"
            case requestedPrefix = "requested-prefix"
            case snapshot
        }

        package struct ReceiptCreationDecision: Equatable {
            package var sourceLayoutState: ReceiptSourceLayoutState = .missing
            package var destinationEligibility: ReceiptDestinationEligibility = .notAppManaged
            package var sourceAuthorityKeyDigest: String?
            package var sourceCommonDirectoryDigest: String?
            package var repositoryIDDigest: String?
            package var repositoryNamespaceDigest: String?
            package var requestedPrefixDigest: String?
            package var currentLeasePresent: Bool?
            package var currentLeaseCurrentAtSnapshotLookup: Bool?
            package var currentSnapshotPresent: Bool?
            package var currentSnapshotContentAddressValid: Bool?
            package var currentSnapshotSHA256: String?
            package var parentLookupRoute: ReceiptParentLookupRoute = .notAttempted
            package var parentLookupFailure: ReceiptParentLookupFailure = .none
            package var parentAuthorityKeyMatch: ReceiptMatchState = .notEvaluated
            package var parentPrefixMatch: ReceiptMatchState = .notEvaluated
            package var targetTreeResolution: ReceiptGateState = .notAttempted
            package var witnessRequested: Bool?
            package var witnessStarted: Bool?
            package var witnessFinished: Bool?
            package var witnessStartEventID: UInt64?
            package var witnessEndEventID: UInt64?
            package var witnessStartEventIDValid: Bool?
            package var witnessEndEventIDValid: Bool?
            package var witnessStableRootAvailableBeforeMutation: Bool?
            package var witnessDestinationAbsentBeforeMutation: Bool?
            package var witnessDestinationStrictDescendant: Bool?
            package var witnessStableRootUnchangedAfterInitialization: Bool?
            package var witnessStreamCreationSucceeded: Bool?
            package var witnessActivationFlushCompleted: Bool?
            package var witnessActivationCallbackBarrierCompleted: Bool?
            package var witnessEndingFlushCompleted: Bool?
            package var witnessEndingCallbackBarrierCompleted: Bool?
            package var witnessStartAcceptedCallbackWatermark: UInt64?
            package var witnessEndAcceptedCallbackWatermark: UInt64?
            package var witnessAcceptedCallbackCount: Int?
            package var witnessAcceptedEventCount: Int?
            package var witnessAcceptedDestinationEventCount: Int?
            package var witnessAcceptedNonDestinationEventCount: Int?
            package var witnessMustScanSubDirs: Bool?
            package var witnessRootChanged: Bool?
            package var witnessUserDropped: Bool?
            package var witnessKernelDropped: Bool?
            package var witnessEventIDsWrapped: Bool?
            package var witnessEventIDRegressed: Bool?
            package var witnessLifetimeExceeded: Bool?
            package var witnessGap: Bool?
            package var witnessDrop: Bool?
            package var witnessOverflow: Bool?
            package var witnessProvesInterval: Bool?
            package var includeCopyRequested: Bool?
            package var includeCopyResultPresent: Bool?
            package var includeCopyComplete: Bool?
            package var includeCopyHadFailures: Bool?
            package var targetLayoutPresent: Bool?
            package var targetLayoutLinked: Bool?
            package var targetAuthorityCapture: ReceiptGateState = .notAttempted
            package var commonDirectoryMatch: ReceiptMatchState = .notEvaluated
            package var repositoryIDMatch: ReceiptMatchState = .notEvaluated
            package var repositoryNamespaceMatch: ReceiptMatchState = .notEvaluated
            package var targetPrefixMatch: ReceiptMatchState = .notEvaluated
            package var targetTreeAuthorityMatch: ReceiptMatchState = .notEvaluated
            package var receiptEmitted: Bool = false
            package var receiptFallbackReason: WorkspaceRootSeedFallbackReason?
            package var initializationFallbackReason: WorkspaceRootSeedFallbackReason?
            package var outcome: ReceiptCreationOutcome = .receiptAbsent

            init() {}
        }

        package struct ReceiptCoordinatorDecision: Equatable {
            package var createResultReceiptCount = 0
            package var hintCount = 0
            package var bindingCount = 0
            package var hintKeyedByCreatedBinding: ReceiptMatchState = .notEvaluated
            package var creationFallbackObserved: WorkspaceRootSeedFallbackReason?

            package init() {}
        }

        package struct ReceiptProjectionDecision: Equatable {
            package var suppliedHintCount = 0
            package var matchedHintCount = 0
            package var allHintKeysMatchedBindings: Bool?
            package var validationFallback: WorkspaceRootSeedFallbackReason?

            init() {}
        }

        package struct ReceiptConsumptionDecision: Equatable {
            package var ownerGenerationMatch: ReceiptMatchState = .notEvaluated
            package var hintSessionMatch: ReceiptMatchState = .notEvaluated
            package var hintCorrelationMatch: ReceiptMatchState = .notEvaluated
            package var hintOwnerMatch: ReceiptMatchState = .notEvaluated
            package var ownershipReused: Bool?
            package var initialHintObservation: ReceiptFinalObservation?
            package var pendingSeededPreparationResult: ReceiptFinalObservation?
            package var fullCrawlPerformed: Bool?
            package var finalObservation: ReceiptFinalObservation?
            package var selectedRoute: WorkspaceRootStartupRoute?

            init() {}
        }

        package struct ReceiptDecision: Equatable {
            package let correlationID: UUID
            package fileprivate(set) var creation: ReceiptCreationDecision?
            package fileprivate(set) var coordinator: ReceiptCoordinatorDecision?
            package fileprivate(set) var projection: ReceiptProjectionDecision?
            package fileprivate(set) var consumption: ReceiptConsumptionDecision?
            package fileprivate(set) var terminalStage: ReceiptTerminalStage?
            package fileprivate(set) var ambiguousOrDuplicate = false
            package fileprivate(set) var creationAttemptCount = 0
        }

        package struct DeltaCompatibilityEvaluationRecord: Equatable {
            package let correlationID: UUID
            package let evaluation: WorkspaceRootSeedDeltaCompatibilityEvaluation
            package let policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison?
            package let exactSnapshotLookupReached: Bool
            package let exactSnapshotLookupPassed: Bool
            package let targetAuthorityComparisonReached: Bool
            package let targetAuthorityComparisonPassed: Bool
            package let currentSearchABIReached: Bool
            package let currentSearchABIMatched: Bool?
            package let catalogPolicyComparisonReached: Bool
            package let catalogPolicyMatched: Bool?
            package let terminalFallback: WorkspaceRootSeedFallbackReason?
            package fileprivate(set) var duplicate = false
            package fileprivate(set) var contradictory = false
        }

        package struct BenchmarkMetricTag: Hashable {
            let correlationID: UUID
            let contextID: UUID
            let agentSessionID: UUID
            let logicalRootID: UUID
            let repositoryID: String
            let destinationID: String

            package init(
                correlationID: UUID,
                contextID: UUID,
                agentSessionID: UUID,
                logicalRootID: UUID,
                repositoryID: String,
                destinationID: String
            ) {
                self.correlationID = correlationID
                self.contextID = contextID
                self.agentSessionID = agentSessionID
                self.logicalRootID = logicalRootID
                self.repositoryID = repositoryID
                self.destinationID = destinationID
            }
        }

        package enum BenchmarkMetricAttribution: String, Equatable {
            case unavailable
            case exact
        }

        package enum BenchmarkPlannerPhase: String, CaseIterable {
            case targetNamespace
            case treeEvidence
            case indexEvidence
            case statusEvidence
            case reconcile
        }

        package enum BenchmarkMarkerPublicationSource: String, Equatable {
            case publishedUpdate
            case warmReplay
        }

        package struct BenchmarkPhaseMetric: Equatable {
            package var count = 0
            package var durationMicroseconds: UInt64 = 0
            package var itemCount = 0
        }

        package struct BenchmarkMarkerPublication: Equatable {
            package let rootID: UUID
            package let rootLifetimeID: UUID
            package let revision: UInt64
            package let effectiveChangeCount: Int
            package let source: BenchmarkMarkerPublicationSource
            package let timestampNanoseconds: UInt64
        }

        package struct BenchmarkMetricSnapshot: Equatable {
            package var gitCommands: [GitCommandMetric] = []
            package var filesystemOperationCount = 0
            package var filesystemDurationMicroseconds: UInt64 = 0
            package var filesystemItemCount = 0
            package var contentReadGrantCount = 0
            package var contentReadOverloadCount = 0
            package var contentReadWaitMicroseconds: UInt64 = 0
            package var contentReadExecutionMicroseconds: UInt64 = 0
            package var codemapRequestCount = 0
            package var codemapBuildCount = 0
            package var codemapQueueMicroseconds: UInt64 = 0
            package var codemapPermitWaitMicroseconds: UInt64 = 0
            package var codemapAttribution: BenchmarkMetricAttribution = .unavailable
            package var plannerPhases: [BenchmarkPlannerPhase: BenchmarkPhaseMetric] = [:]
            package var mutationLockCount = 0
            package var mutationLockQueueMicroseconds: UInt64 = 0
            package var mutationLockHeldMicroseconds: UInt64 = 0
            package var mutationDurationMicroseconds: UInt64 = 0
            package var postMutationFinalizationMicroseconds: UInt64 = 0
            package var passiveTreeCount = 0
            package var passiveTreeDurationMicroseconds: UInt64 = 0
            package var markerPublications: [BenchmarkMarkerPublication] = []
        }

        @TaskLocal package static var currentBenchmarkMetricTag: BenchmarkMetricTag?
    #endif

    package struct Event: Equatable {
        package let correlationID: UUID
        package let phase: WorktreeStartupPhase
        package let route: WorkspaceRootStartupRoute?
        package let fallback: WorkspaceRootSeedFallbackReason?
        let observationEnabled: Bool
        let servingEnabled: Bool
        #if DEBUG
            let agentSessionID: UUID
            package let timestampNanoseconds: UInt64
            let forcedFullCrawl: Bool
        #endif

        init(
            phase: WorktreeStartupPhase,
            context: WorktreeStartupContext,
            route: WorkspaceRootStartupRoute?,
            fallback: WorkspaceRootSeedFallbackReason?
        ) {
            correlationID = context.correlationID
            self.phase = phase
            self.route = route
            self.fallback = fallback
            observationEnabled = context.flags.observeDiffSeededWorktreeStartup
            servingEnabled = context.flags.serveDiffSeededWorktreeStartup
            #if DEBUG
                agentSessionID = context.agentSessionID
                timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
                forcedFullCrawl = context.servingControl == .forceFullCrawl
            #endif
        }
    }

    package struct GitCommandMetric: Equatable {
        package let family: GitProcessCommandFamily
        package let priority: GitProcessAdmissionPriority
        package let queueWaitMicroseconds: Int
        package let durationMicroseconds: Int
        package let outputByteCount: Int
        package let cancelled: Bool
        #if DEBUG
            let timestampNanoseconds: UInt64
        #endif

        init(
            family: GitProcessCommandFamily,
            priority: GitProcessAdmissionPriority,
            queueWaitMicroseconds: Int,
            durationMicroseconds: Int,
            outputByteCount: Int,
            cancelled: Bool
        ) {
            self.family = family
            self.priority = priority
            self.queueWaitMicroseconds = queueWaitMicroseconds
            self.durationMicroseconds = durationMicroseconds
            self.outputByteCount = outputByteCount
            self.cancelled = cancelled
            #if DEBUG
                timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            #endif
        }
    }

    package struct Snapshot: Equatable {
        package let events: [Event]
        let gitCommands: [GitCommandMetric]
        let routeCounts: [WorkspaceRootStartupRoute: Int]
        let fallbackCounts: [WorkspaceRootSeedFallbackReason: Int]
        let shadow: ShadowCounters
        let seed: SeedCounters
        #if DEBUG
            package let eventEvictionCount: Int
            let gitCommandEvictionCount: Int
            package let receiptDecisions: [ReceiptDecision]
            package let receiptDecisionEvictionCount: Int
            package let deltaCompatibilityEvaluations: [DeltaCompatibilityEvaluationRecord]
            package let deltaCompatibilityEvaluationEvictionCount: Int
        #endif
    }

    struct ShadowCounters: Equatable {
        var inventoryComparisons = 0
        var inventoryMatches = 0
        var inventoryMismatches = 0
        var projectedSearchComparisons = 0
        var projectedSearchMatches = 0
        var projectedSearchMismatches = 0
        var latestBaseEntryCount = 0
        var latestOverlayEntryCount = 0
        var latestTombstoneCount = 0
    }

    struct SeedCounters: Equatable {
        var receiptJournalCutPresent = 0
        var receiptJournalCutAbsent = 0
        var acceptedReplayPayloadCount = 0
        var acceptedReplayEventCount = 0
        var latestInitializationWatermarkDelta = 0
        var latestServiceSequenceDelta = 0
        var latestReplayChangedPathCount = 0
        var metadataRevalidationChecks = 0
        var metadataRevalidationUses = 0
        var latestProjectedBaseEntryCount = 0
        var latestProjectedOverlayEntryCount = 0
        var latestProjectedTombstoneCount = 0
        var fullCrawlFallbackCount = 0
    }

    private static let lock = NSLock()
    private static let maximumEventCount = 512
    private static let maximumGitCommandMetricCount = 1024
    private static let maximumSeedMetricValue = 1_000_000
    private static var events: [Event] = []
    private static var gitCommands: [GitCommandMetric] = []
    private static var routeCounts: [WorkspaceRootStartupRoute: Int] = [:]
    private static var fallbackCounts: [WorkspaceRootSeedFallbackReason: Int] = [:]
    private static var shadowCounters = ShadowCounters()
    private static var seedCounters = SeedCounters()
    #if DEBUG
        private static let maximumReceiptDecisionCount = 128
        private static let maximumDeltaCompatibilityEvaluationCount = 128
        private static let maximumBenchmarkMarkerPublicationCount = 128
        private static var eventEvictionCount = 0
        private static var gitCommandEvictionCount = 0
        private static var storedReceiptDecisions: [ReceiptDecision] = []
        private static var receiptDecisionEvictionCount = 0
        private static var storedDeltaCompatibilityEvaluations: [DeltaCompatibilityEvaluationRecord] = []
        private static var deltaCompatibilityEvaluationEvictionCount = 0
        private static var benchmarkMetricsByTag: [BenchmarkMetricTag: BenchmarkMetricSnapshot] = [:]
    #endif

    package static func record(
        _ phase: WorktreeStartupPhase,
        context: WorktreeStartupContext,
        route: WorkspaceRootStartupRoute? = nil,
        fallback: WorkspaceRootSeedFallbackReason? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == maximumEventCount {
            events.removeFirst()
            #if DEBUG
                eventEvictionCount = incremented(eventEvictionCount)
            #endif
        }
        events.append(Event(
            phase: phase,
            context: context,
            route: route,
            fallback: fallback
        ))
        if let route {
            routeCounts[route, default: 0] += 1
        }
        if let fallback {
            fallbackCounts[fallback, default: 0] += 1
        }
    }

    static func recordGitCommand(
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority,
        queueWaitMicroseconds: Int,
        durationMicroseconds: Int,
        outputByteCount: Int,
        cancelled: Bool
    ) {
        #if DEBUG
            WorktreeStartupPreparationInstrumentation.currentRecorder?.increment(.gitCommandCount)
            WorktreeStartupPreparationInstrumentation.currentRecorder?.increment(
                .gitQueueMicroseconds,
                by: UInt64(max(0, queueWaitMicroseconds))
            )
            WorktreeStartupPreparationInstrumentation.currentRecorder?.increment(
                .gitDurationMicroseconds,
                by: UInt64(max(0, durationMicroseconds))
            )
        #endif
        lock.lock()
        defer { lock.unlock() }
        if gitCommands.count == maximumGitCommandMetricCount {
            gitCommands.removeFirst()
            #if DEBUG
                gitCommandEvictionCount = incremented(gitCommandEvictionCount)
            #endif
        }
        gitCommands.append(GitCommandMetric(
            family: family,
            priority: priority,
            queueWaitMicroseconds: queueWaitMicroseconds,
            durationMicroseconds: durationMicroseconds,
            outputByteCount: outputByteCount,
            cancelled: cancelled
        ))
    }

    #if DEBUG
        static func receiptDecisionDigest(
            _ value: String,
            domain: ReceiptDecisionDigestDomain
        ) -> String {
            let material = "rpce-receipt-decision-v1\0\(domain.rawValue)\0\(value)"
            return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static func recordReceiptCreationDecision(
            correlationID: UUID,
            decision: ReceiptCreationDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            storedReceiptDecisions[index].creationAttemptCount = incremented(
                storedReceiptDecisions[index].creationAttemptCount
            )
            if let existing = storedReceiptDecisions[index].creation {
                storedReceiptDecisions[index].ambiguousOrDuplicate = true
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].creation = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .creation : nil)
            lock.unlock()
        }

        package static func recordReceiptCoordinatorDecision(
            correlationID: UUID,
            decision: ReceiptCoordinatorDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].coordinator {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].coordinator = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .coordinator : nil)
            lock.unlock()
        }

        static func recordReceiptProjectionDecision(
            correlationID: UUID,
            decision: ReceiptProjectionDecision,
            terminal: Bool = false
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].projection {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].projection = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .projection : nil)
            lock.unlock()
        }

        static func recordReceiptConsumptionDecision(
            correlationID: UUID,
            decision: ReceiptConsumptionDecision,
            terminal: Bool = true
        ) {
            lock.lock()
            let index = receiptDecisionIndexLocked(correlationID: correlationID)
            if let existing = storedReceiptDecisions[index].consumption {
                if existing != decision {
                    storedReceiptDecisions[index].ambiguousOrDuplicate = true
                }
            } else {
                storedReceiptDecisions[index].consumption = decision
            }
            setReceiptTerminalLocked(index: index, stage: terminal ? .consumption : nil)
            lock.unlock()
        }

        static func receiptDecisions(correlationID: UUID? = nil) -> [ReceiptDecision] {
            lock.lock()
            defer { lock.unlock() }
            guard let correlationID else { return storedReceiptDecisions }
            return storedReceiptDecisions.filter { $0.correlationID == correlationID }
        }

        static func currentReceiptDecisionEvictionCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return receiptDecisionEvictionCount
        }

        static func recordDeltaCompatibilityEvaluation(
            correlationID: UUID,
            evaluation: WorkspaceRootSeedDeltaCompatibilityEvaluation,
            policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison? = nil,
            exactSnapshotLookupReached: Bool,
            exactSnapshotLookupPassed: Bool,
            targetAuthorityComparisonReached: Bool,
            targetAuthorityComparisonPassed: Bool,
            currentSearchABIReached: Bool,
            currentSearchABIMatched: Bool?,
            catalogPolicyComparisonReached: Bool,
            catalogPolicyMatched: Bool?,
            terminalFallback: WorkspaceRootSeedFallbackReason?
        ) {
            let candidate = DeltaCompatibilityEvaluationRecord(
                correlationID: correlationID,
                evaluation: evaluation,
                policyCanonicalizationComparison: policyCanonicalizationComparison,
                exactSnapshotLookupReached: exactSnapshotLookupReached,
                exactSnapshotLookupPassed: exactSnapshotLookupPassed,
                targetAuthorityComparisonReached: targetAuthorityComparisonReached,
                targetAuthorityComparisonPassed: targetAuthorityComparisonPassed,
                currentSearchABIReached: currentSearchABIReached,
                currentSearchABIMatched: currentSearchABIMatched,
                catalogPolicyComparisonReached: catalogPolicyComparisonReached,
                catalogPolicyMatched: catalogPolicyMatched,
                terminalFallback: terminalFallback
            )
            lock.lock()
            defer { lock.unlock() }
            if let index = storedDeltaCompatibilityEvaluations.firstIndex(where: {
                $0.correlationID == correlationID && $0.evaluation.source == evaluation.source
            }) {
                var original = storedDeltaCompatibilityEvaluations[index]
                original.duplicate = false
                original.contradictory = false
                storedDeltaCompatibilityEvaluations[index].duplicate = true
                if original != candidate {
                    storedDeltaCompatibilityEvaluations[index].contradictory = true
                }
                return
            }
            if storedDeltaCompatibilityEvaluations.count == maximumDeltaCompatibilityEvaluationCount {
                storedDeltaCompatibilityEvaluations.removeFirst()
                deltaCompatibilityEvaluationEvictionCount = incremented(
                    deltaCompatibilityEvaluationEvictionCount
                )
            }
            storedDeltaCompatibilityEvaluations.append(candidate)
        }

        static func deltaCompatibilityEvaluations(
            correlationID: UUID? = nil
        ) -> [DeltaCompatibilityEvaluationRecord] {
            lock.lock()
            defer { lock.unlock() }
            guard let correlationID else { return storedDeltaCompatibilityEvaluations }
            return storedDeltaCompatibilityEvaluations.filter { $0.correlationID == correlationID }
        }

        static func currentDeltaCompatibilityEvaluationEvictionCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return deltaCompatibilityEvaluationEvictionCount
        }

        private static func receiptDecisionIndexLocked(correlationID: UUID) -> Int {
            if let index = storedReceiptDecisions.firstIndex(where: { $0.correlationID == correlationID }) {
                return index
            }
            if storedReceiptDecisions.count == maximumReceiptDecisionCount {
                let evictionIndex = storedReceiptDecisions.firstIndex(where: { $0.terminalStage != nil }) ?? 0
                storedReceiptDecisions.remove(at: evictionIndex)
                receiptDecisionEvictionCount = incremented(receiptDecisionEvictionCount)
            }
            storedReceiptDecisions.append(ReceiptDecision(correlationID: correlationID))
            return storedReceiptDecisions.count - 1
        }

        private static func setReceiptTerminalLocked(index: Int, stage: ReceiptTerminalStage?) {
            guard let stage, storedReceiptDecisions[index].terminalStage == nil else { return }
            storedReceiptDecisions[index].terminalStage = stage
        }

        static func recordBenchmarkGitCommand(
            tag: BenchmarkMetricTag?,
            family: GitProcessCommandFamily,
            priority: GitProcessAdmissionPriority,
            queueWaitMicroseconds: Int,
            durationMicroseconds: Int,
            outputByteCount: Int,
            cancelled: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            if metrics.gitCommands.count == maximumGitCommandMetricCount {
                metrics.gitCommands.removeFirst()
            }
            metrics.gitCommands.append(GitCommandMetric(
                family: family,
                priority: priority,
                queueWaitMicroseconds: queueWaitMicroseconds,
                durationMicroseconds: durationMicroseconds,
                outputByteCount: outputByteCount,
                cancelled: cancelled
            ))
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkFilesystemWork(
            tag: BenchmarkMetricTag?,
            durationMicroseconds: UInt64,
            itemCount: Int
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.filesystemOperationCount = incremented(metrics.filesystemOperationCount)
            metrics.filesystemDurationMicroseconds = adding(metrics.filesystemDurationMicroseconds, durationMicroseconds)
            metrics.filesystemItemCount = added(metrics.filesystemItemCount, itemCount)
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkContentReadWork(
            tag: BenchmarkMetricTag?,
            waitMicroseconds: UInt64,
            executionMicroseconds: UInt64,
            overloaded: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            if overloaded {
                metrics.contentReadOverloadCount = incremented(metrics.contentReadOverloadCount)
            } else {
                metrics.contentReadGrantCount = incremented(metrics.contentReadGrantCount)
                metrics.contentReadWaitMicroseconds = adding(metrics.contentReadWaitMicroseconds, waitMicroseconds)
                metrics.contentReadExecutionMicroseconds = adding(
                    metrics.contentReadExecutionMicroseconds,
                    executionMicroseconds
                )
            }
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkCodemapWork(
            tag: BenchmarkMetricTag?,
            durations: CodeMapArtifactCoordinatorDurations?,
            buildPerformed: Bool,
            exactlyAttributed: Bool
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.codemapRequestCount = incremented(metrics.codemapRequestCount)
            if !exactlyAttributed {
                metrics.codemapAttribution = .unavailable
            } else if metrics.codemapAttribution != .unavailable || metrics.codemapRequestCount == 1 {
                metrics.codemapAttribution = .exact
                if buildPerformed {
                    metrics.codemapBuildCount = incremented(metrics.codemapBuildCount)
                }
                if let durations {
                    metrics.codemapQueueMicroseconds = adding(
                        metrics.codemapQueueMicroseconds,
                        durations.buildQueueNanoseconds / 1000
                    )
                    metrics.codemapPermitWaitMicroseconds = adding(
                        metrics.codemapPermitWaitMicroseconds,
                        durations.buildPermitNanoseconds / 1000
                    )
                }
            }
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkPlannerPhase(
            tag: BenchmarkMetricTag?,
            phase: BenchmarkPlannerPhase,
            durationMicroseconds: UInt64,
            itemCount: Int
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            var phaseMetric = metrics.plannerPhases[phase] ?? BenchmarkPhaseMetric()
            phaseMetric.count = incremented(phaseMetric.count)
            phaseMetric.durationMicroseconds = adding(phaseMetric.durationMicroseconds, durationMicroseconds)
            phaseMetric.itemCount = added(phaseMetric.itemCount, itemCount)
            metrics.plannerPhases[phase] = phaseMetric
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkMutationLock(
            tag: BenchmarkMetricTag?,
            queueWaitMicroseconds: UInt64,
            heldMicroseconds: UInt64
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.mutationLockCount = incremented(metrics.mutationLockCount)
            metrics.mutationLockQueueMicroseconds = adding(
                metrics.mutationLockQueueMicroseconds,
                queueWaitMicroseconds
            )
            metrics.mutationLockHeldMicroseconds = adding(metrics.mutationLockHeldMicroseconds, heldMicroseconds)
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkMutationWork(
            tag: BenchmarkMetricTag?,
            mutationDurationMicroseconds: UInt64,
            postMutationFinalizationMicroseconds: UInt64
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.mutationDurationMicroseconds = adding(
                metrics.mutationDurationMicroseconds,
                mutationDurationMicroseconds
            )
            metrics.postMutationFinalizationMicroseconds = adding(
                metrics.postMutationFinalizationMicroseconds,
                postMutationFinalizationMicroseconds
            )
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkPassiveTree(
            tag: BenchmarkMetricTag?,
            durationMicroseconds: UInt64
        ) {
            guard let tag else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            metrics.passiveTreeCount = incremented(metrics.passiveTreeCount)
            metrics.passiveTreeDurationMicroseconds = adding(
                metrics.passiveTreeDurationMicroseconds,
                durationMicroseconds
            )
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        static func recordBenchmarkMarkerPublication(
            tag: BenchmarkMetricTag?,
            rootID: UUID,
            rootLifetimeID: UUID,
            revision: UInt64,
            effectiveChangeCount: Int,
            source: BenchmarkMarkerPublicationSource
        ) {
            guard let tag, effectiveChangeCount > 0 else { return }
            lock.lock()
            var metrics = benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
            if metrics.markerPublications.count == maximumBenchmarkMarkerPublicationCount {
                metrics.markerPublications.removeFirst()
            }
            metrics.markerPublications.append(BenchmarkMarkerPublication(
                rootID: rootID,
                rootLifetimeID: rootLifetimeID,
                revision: revision,
                effectiveChangeCount: bounded(effectiveChangeCount),
                source: source,
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
            benchmarkMetricsByTag[tag] = metrics
            lock.unlock()
        }

        package static func benchmarkMetricSnapshot(for tag: BenchmarkMetricTag) -> BenchmarkMetricSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return benchmarkMetricsByTag[tag] ?? BenchmarkMetricSnapshot()
        }

        package static func benchmarkMetricTag(correlationID: UUID) -> BenchmarkMetricTag? {
            lock.lock()
            defer { lock.unlock() }
            return benchmarkMetricsByTag.keys.first { $0.correlationID == correlationID }
        }

        package static func resetBenchmarkMetrics(correlationID: UUID? = nil) {
            lock.lock()
            if let correlationID {
                benchmarkMetricsByTag = benchmarkMetricsByTag.filter { $0.key.correlationID != correlationID }
            } else {
                benchmarkMetricsByTag.removeAll(keepingCapacity: true)
            }
            lock.unlock()
        }

        private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
        }
    #endif

    static func recordInventoryComparison(matched: Bool) {
        lock.lock()
        shadowCounters.inventoryComparisons = incremented(shadowCounters.inventoryComparisons)
        if matched {
            shadowCounters.inventoryMatches = incremented(shadowCounters.inventoryMatches)
        } else {
            shadowCounters.inventoryMismatches = incremented(shadowCounters.inventoryMismatches)
        }
        lock.unlock()
    }

    static func recordShadowFallback(_ reason: WorkspaceRootSeedFallbackReason) {
        lock.lock()
        fallbackCounts[reason, default: 0] = incremented(fallbackCounts[reason, default: 0])
        lock.unlock()
    }

    static func recordProjectedSearchComparison(
        matched: Bool,
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        shadowCounters.projectedSearchComparisons = incremented(shadowCounters.projectedSearchComparisons)
        if matched {
            shadowCounters.projectedSearchMatches = incremented(shadowCounters.projectedSearchMatches)
        } else {
            shadowCounters.projectedSearchMismatches = incremented(shadowCounters.projectedSearchMismatches)
            fallbackCounts[.projectedSearchMismatch, default: 0] = incremented(
                fallbackCounts[.projectedSearchMismatch, default: 0]
            )
        }
        shadowCounters.latestBaseEntryCount = max(0, baseEntryCount)
        shadowCounters.latestOverlayEntryCount = max(0, overlayEntryCount)
        shadowCounters.latestTombstoneCount = max(0, tombstoneCount)
        lock.unlock()
    }

    static func recordSeedReceiptJournalCut(present: Bool) {
        lock.lock()
        if present {
            seedCounters.receiptJournalCutPresent = incremented(seedCounters.receiptJournalCutPresent)
        } else {
            seedCounters.receiptJournalCutAbsent = incremented(seedCounters.receiptJournalCutAbsent)
        }
        lock.unlock()
    }

    static func recordSeedReplay(
        acceptedPayloadCount: Int,
        acceptedEventCount: Int,
        initializationWatermarkDelta: Int,
        serviceSequenceDelta: Int,
        changedPathCount: Int
    ) {
        lock.lock()
        seedCounters.acceptedReplayPayloadCount = added(
            seedCounters.acceptedReplayPayloadCount,
            acceptedPayloadCount
        )
        seedCounters.acceptedReplayEventCount = added(
            seedCounters.acceptedReplayEventCount,
            acceptedEventCount
        )
        seedCounters.latestInitializationWatermarkDelta = bounded(initializationWatermarkDelta)
        seedCounters.latestServiceSequenceDelta = bounded(serviceSequenceDelta)
        seedCounters.latestReplayChangedPathCount = bounded(changedPathCount)
        lock.unlock()
    }

    static func recordSeedMetadataRevalidation(used: Bool) {
        lock.lock()
        seedCounters.metadataRevalidationChecks = incremented(seedCounters.metadataRevalidationChecks)
        if used {
            seedCounters.metadataRevalidationUses = incremented(seedCounters.metadataRevalidationUses)
        }
        lock.unlock()
    }

    static func recordSeedProjectedPreparation(
        baseEntryCount: Int,
        overlayEntryCount: Int,
        tombstoneCount: Int
    ) {
        lock.lock()
        seedCounters.latestProjectedBaseEntryCount = bounded(baseEntryCount)
        seedCounters.latestProjectedOverlayEntryCount = bounded(overlayEntryCount)
        seedCounters.latestProjectedTombstoneCount = bounded(tombstoneCount)
        lock.unlock()
    }

    static func recordSeedFullCrawlFallback() {
        lock.lock()
        seedCounters.fullCrawlFallbackCount = incremented(seedCounters.fullCrawlFallbackCount)
        lock.unlock()
    }

    package static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
            return Snapshot(
                events: events,
                gitCommands: gitCommands,
                routeCounts: routeCounts,
                fallbackCounts: fallbackCounts,
                shadow: shadowCounters,
                seed: seedCounters,
                eventEvictionCount: eventEvictionCount,
                gitCommandEvictionCount: gitCommandEvictionCount,
                receiptDecisions: storedReceiptDecisions,
                receiptDecisionEvictionCount: receiptDecisionEvictionCount,
                deltaCompatibilityEvaluations: storedDeltaCompatibilityEvaluations,
                deltaCompatibilityEvaluationEvictionCount: deltaCompatibilityEvaluationEvictionCount
            )
        #else
            return Snapshot(
                events: events,
                gitCommands: gitCommands,
                routeCounts: routeCounts,
                fallbackCounts: fallbackCounts,
                shadow: shadowCounters,
                seed: seedCounters
            )
        #endif
    }

    private static func incremented(_ value: Int) -> Int {
        value >= maximumSeedMetricValue ? maximumSeedMetricValue : value + 1
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(0, value), maximumSeedMetricValue)
    }

    private static func added(_ current: Int, _ value: Int) -> Int {
        min(maximumSeedMetricValue, current + bounded(value))
    }

    #if DEBUG
        static func resetForTesting() {
            lock.lock()
            events.removeAll(keepingCapacity: true)
            gitCommands.removeAll(keepingCapacity: true)
            routeCounts.removeAll(keepingCapacity: true)
            fallbackCounts.removeAll(keepingCapacity: true)
            shadowCounters = ShadowCounters()
            seedCounters = SeedCounters()
            eventEvictionCount = 0
            gitCommandEvictionCount = 0
            storedReceiptDecisions.removeAll(keepingCapacity: true)
            receiptDecisionEvictionCount = 0
            storedDeltaCompatibilityEvaluations.removeAll(keepingCapacity: true)
            deltaCompatibilityEvaluationEvictionCount = 0
            benchmarkMetricsByTag.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    #endif
}
