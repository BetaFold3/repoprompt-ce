import Foundation

// MARK: - Agent Session Data Error

enum AgentSessionDataError: Error {
    case invalidFilename(String)
    case decodingFailed(Error)
    case loadFailed(Error)
    case saveFailed(Error)
    case noActiveWorkspace
}

enum AgentSessionFileCreationPolicy {
    /// Existing behavior for deliberate initial session creation.
    case createIfMissing
    /// A writer targeting an existing incarnation must not recreate an explicitly deleted file.
    case requireExisting
}

/// Immutable, process-local ownership of one durable session incarnation. Callers capture this
/// once when they create or hydrate an editable session and never refresh it after deletion.
struct AgentSessionPersistenceStamp: Hashable {
    let sessionID: UUID
    let workspaceID: UUID
    let deletionGeneration: UInt64
    fileprivate let serviceID: UUID
    fileprivate let fileURL: URL
}

/// Full-save authority for one session incarnation and transcript-reset generation.
struct AgentSessionPersistenceState: Hashable {
    let stamp: AgentSessionPersistenceStamp
    let transcriptResetGeneration: UInt64
}

struct AgentSessionEditableLoad {
    let session: AgentSession
    let persistenceState: AgentSessionPersistenceState
}

struct AgentSessionDeletionCandidate: Hashable {
    let composeTabID: UUID
    let persistenceState: AgentSessionPersistenceState

    var sessionID: UUID {
        persistenceState.stamp.sessionID
    }

    var storagePath: String {
        persistenceState.stamp.fileURL.path
    }
}

enum AgentSessionConditionalDeletionResult: Equatable {
    case deleted
    case alreadyAbsent
    case ownershipChanged
}

struct AgentSessionSaveCommit {
    enum Disposition: Equatable {
        case written
        case resetAlreadyCommitted
    }

    let fileURL: URL
    let persistenceState: AgentSessionPersistenceState
    let disposition: Disposition
}

enum AgentScheduledSendMutationError: Error, Equatable {
    case sessionNotFound(UUID)
    case unreadableScheduledSend(UUID)
    case staleExpectedUpdatedAt(expected: Date?, actual: Date?)
    case staleExpectedAttempt(
        expected: AgentScheduledSendPersist.Attempt,
        actual: AgentScheduledSendPersist.Attempt?
    )
    case scheduledSendNotDispatching(actual: AgentScheduledSendPersist.State)
    case invalidAcceptedUserItem(expectedItemID: UUID, actualItemID: UUID)
    case acceptedItemNotUser(UUID)
    case invalidDispatchReceipt
    case staleExpectedScheduledSendMember(
        expected: AgentScheduledSendMember,
        actual: AgentScheduledSendMember?
    )
    case staleExpectedFinalizedItem(
        itemID: UUID,
        expected: AgentScheduledSendProvenance,
        actual: AgentScheduledSendProvenance?
    )
    case invalidPersistenceStamp
    case staleDeletionGeneration(expected: UInt64, actual: UInt64)
    case staleTranscriptResetGeneration(expected: UInt64, actual: UInt64)
    case sessionAlreadyExists(UUID)
}

struct AgentScheduledSendFinalizedItemRemoval: Equatable {
    let itemID: UUID
    let receipt: AgentScheduledSendProvenance
}

enum AgentScheduledSendMutation {
    case upsert(expectedUpdatedAt: Date?, value: AgentScheduledSendPersist)
    case clear(expectedUpdatedAt: Date, completedDispatch: AgentScheduledSendProvenance?)
    case discardUnreadable(expected: AgentScheduledSendJSONValue)
}

struct AgentScheduledSendMutationResult {
    enum MetadataIndexStatus: Equatable {
        case updated
        case repairNeeded(String)
    }

    let session: AgentSession
    let fileURL: URL
    let metadataIndexStatus: MetadataIndexStatus
}

// MARK: - Agent Session Metadata

/// Lightweight metadata for agent session listing
struct AgentSessionMeta {
    let id: UUID
    let composeTabID: UUID?
    let name: String
    let lastModified: Date
    let itemCount: Int
    let agentKind: String?
    let agentModel: String?
    let lastRunState: String?
    let parentSessionID: UUID?
    let remoteHostID: String?
    let remoteHostName: String?
    let remoteSessionID: String?
    let isMCPOriginated: Bool
    /// Session provenance (plan §6.4); `nil` only when built from legacy data
    /// that predates origin tracking.
    let origin: AgentSessionOrigin?
    let worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    let activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
}

private actor AgentSessionDiskWriter {
    private struct PendingWrite {
        var pendingData: Data?
        var isWriting: Bool
        var waiters: [CheckedContinuation<Void, Error>]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]

    func enqueueAndWait(data: Data, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var pending = pendingByURL[url] ?? PendingWrite(
                pendingData: nil,
                isWriting: false,
                waiters: []
            )
            pending.pendingData = data
            pending.waiters.append(continuation)
            let shouldStartWriter = !pending.isWriting
            pending.isWriting = true
            pendingByURL[url] = pending
            if shouldStartWriter {
                Task { await self.drainWrites(for: url) }
            }
        }
    }

    private func drainWrites(for url: URL) async {
        var lastError: Error?
        while true {
            guard var pending = pendingByURL[url] else { return }
            guard let data = pending.pendingData else {
                pending.isWriting = false
                let waiters = pending.waiters
                pendingByURL.removeValue(forKey: url)
                for waiter in waiters {
                    if let lastError {
                        waiter.resume(throwing: lastError)
                    } else {
                        waiter.resume(returning: ())
                    }
                }
                return
            }
            pending.pendingData = nil
            pendingByURL[url] = pending

            let writeResult: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try data.write(to: url, options: .atomic)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case .success:
                lastError = nil
            case let .failure(error):
                lastError = error
            }
        }
    }
}

// MARK: - Agent Session Data Service

/// An actor that reads/writes AgentSessions from each workspace's "AgentSessions" folder.
///
/// Production composition uses `shared` for every Agent Mode window and MCP entry point, so the
/// per-session persistence gate below is process-wide for app writes. Direct instances remain
/// available to isolated tests.
actor AgentSessionDataService {
    static let shared = AgentSessionDataService()

    #if DEBUG
        private var testConditionalDeletionHook: (@Sendable (AgentSessionDeletionCandidate) async throws -> Void)?

        func test_setConditionalDeletionHook(
            _ hook: (@Sendable (AgentSessionDeletionCandidate) async throws -> Void)?
        ) {
            testConditionalDeletionHook = hook
        }
    #endif

    private let persistenceServiceID = UUID()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diskWriter = AgentSessionDiskWriter()
    private static let sidebarStreamMetadataIndexReconciliationDelaySeconds: TimeInterval = 2.0

    private struct MetadataIndexReconciliationTaskState {
        let id: UUID
        let task: Task<Void, Never>
        let delaySeconds: TimeInterval
    }

    private var metadataIndexCacheByFolder: [URL: AgentSessionMetadataIndex] = [:]
    private var metadataIndexReconciliationTasksByFolder: [URL: MetadataIndexReconciliationTaskState] = [:]
    private var metadataIndexReconciledThisProcess: Set<URL> = []

    private struct AgentSessionScheduleAuthority {
        var scheduledSend: AgentScheduledSendMember?
        var lastScheduledDispatch: AgentScheduledSendProvenance?
        var protectedAcceptedUserItemsByID: [UUID: AgentChatItem]
        var intentionallyRemovedAcceptedUserItemReceiptsByID: [UUID: AgentScheduledSendProvenance]
    }

    private struct AgentSessionTranscriptResetAuthority {
        let deletionGeneration: UInt64
        let generation: UInt64
        let receipt: AgentSessionTranscriptResetReceipt
        let canonicalSessionSnapshot: Data
    }

    private enum StaleFinalizedItemRemovalPolicy {
        case fail
        case ignore
    }

    /// Process-local authority used by ordinary saves after a schedule mutation/finalization.
    /// Production uses the shared data service, so this both avoids a full JSON parse on the hot
    /// save path and prevents stale VM snapshots from dropping finalized scheduled user items.
    private var scheduleAuthorityByFileURL: [URL: AgentSessionScheduleAuthority] = [:]
    private var transcriptResetAuthorityByFileURL: [URL: AgentSessionTranscriptResetAuthority] = [:]
    private var activeSessionPersistence: Set<UUID> = []
    private var sessionPersistenceWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Process-local explicit-deletion evidence keyed by canonical session-file identity. A
    /// recovery context captures the generation before provider handoff; an explicit deletion
    /// (even of an already-absent file) advances it so an older context can never reconstruct.
    private var deletionGenerationsByFileKey: [URL: UInt64] = [:]
    #if DEBUG
        /// Test seam: throws the returned error for recovery finalization attempts.
        private var test_scheduledSendRecoveryFailureInjector: ((AgentScheduledSendAcceptedPayload) -> Error?)?

        /// Installs (or clears with `nil`) the recovery failure injector. Callers that use the
        /// shared instance must clear it during teardown.
        func test_setScheduledSendRecoveryFailureInjector(
            _ injector: (@Sendable (AgentScheduledSendAcceptedPayload) -> Error?)?
        ) {
            test_scheduledSendRecoveryFailureInjector = injector
        }

        /// Test seam: throws the returned error instead of unlinking an existing session file.
        private var test_agentSessionDeletionFailureInjector: ((URL) -> Error?)?

        func test_setAgentSessionDeletionFailureInjector(
            _ injector: (@Sendable (URL) -> Error?)?
        ) {
            test_agentSessionDeletionFailureInjector = injector
        }
    #endif

    private enum AgentSessionMetadataIndexLoadMode {
        case fast
        case backfillIfMissing
        case forceReconcile
    }

    enum FastMetadataRecordsSource: String {
        case memoryIndex
        case diskIndex
    }

    struct FastMetadataRecordsResult {
        let records: [AgentSessionMetadataRecord]
        let source: FastMetadataRecordsSource
    }

    // MARK: - Lightweight decode helpers

    private struct AgentSessionLastRunStateHeader: Decodable {
        let lastRunState: String?
    }

    private struct AgentSessionScheduleHeader: Decodable {
        let scheduledSend: AgentScheduledSendMember?
        let lastScheduledDispatch: AgentScheduledSendProvenance?
    }

    private struct AgentSessionHeader: Decodable {
        let id: UUID
        let serializationVersion: Int?
        let workspaceID: UUID?
        let composeTabID: UUID?
        let name: String
        let savedAt: Date
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
        let agentKind: String?
        let agentModel: String?
        let ohMyPiThinkingSelections: OhMyPiThinkingSelections?
        let agentReasoningEffort: String?
        let lastRunState: String?
        let providerSessionID: String?
        let remoteHost: AgentSessionRemoteHostBinding?
        let autoEditEnabled: Bool
        let codexConversationID: String?
        let codexRolloutPath: String?
        let codexModel: String?
        let codexReasoningEffort: String?
        let codexContextWindow: Int?
        let codexLastTotalTokens: Int?
        let codexTotalTotalTokens: Int?
        let codexMcpSessionKey: String?
        let parentSessionID: UUID?
        let worktreeBindings: [AgentSessionWorktreeBinding]?
        let worktreeMergeOperations: [AgentSessionWorktreeMergeOperation]?
        let pendingHandoffPayload: String?
        let pendingHandoffCreatedAt: Date?
        let pendingHandoffSourceItemID: UUID?
        let pendingHandoffDefersProviderLockUntilSend: Bool?
        let isMCPOriginated: Bool?
        let origin: AgentSessionOrigin?
        let profile: AgentSessionProfile?
        let scheduledSend: AgentScheduledSendMember?
        let lastScheduledDispatch: AgentScheduledSendProvenance?

        private enum CodingKeys: String, CodingKey {
            case id
            case serializationVersion
            case workspaceID
            case composeTabID
            case name
            case savedAt
            case itemCount
            case transcriptProjectionCounts
            case lastUserMessageAt
            case agentKind
            case agentModel
            case ohMyPiThinkingSelections
            case agentReasoningEffort
            case lastRunState
            case providerSessionID
            case remoteHost
            case autoEditEnabled
            case codexConversationID
            case codexRolloutPath
            case codexModel
            case codexReasoningEffort
            case codexContextWindow
            case codexLastTotalTokens
            case codexTotalTotalTokens
            case codexMcpSessionKey
            case parentSessionID
            case worktreeBindings
            case worktreeMergeOperations
            case pendingHandoffPayload
            case pendingHandoffCreatedAt
            case pendingHandoffSourceItemID
            case pendingHandoffDefersProviderLockUntilSend
            case isMCPOriginated
            case origin
            case profile
            case scheduledSend
            case lastScheduledDispatch
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
            workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
            composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
            name = try container.decode(String.self, forKey: .name)
            savedAt = try container.decode(Date.self, forKey: .savedAt)
            itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
            transcriptProjectionCounts = try container.decodeIfPresent(
                AgentTranscriptProjectionCounts.self,
                forKey: .transcriptProjectionCounts
            )
            lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
            agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
            agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
            ohMyPiThinkingSelections = try container.decodeIfPresent(
                OhMyPiThinkingSelections.self,
                forKey: .ohMyPiThinkingSelections
            )?.nilIfEmpty
            agentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffort)
            lastRunState = try container.decodeIfPresent(String.self, forKey: .lastRunState)
            providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
            remoteHost = try container.decodeIfPresent(AgentSessionRemoteHostBinding.self, forKey: .remoteHost)
            autoEditEnabled = try container.decode(Bool.self, forKey: .autoEditEnabled)
            // `providerUsage` is captured as raw bytes by `AgentSessionDataCodec`, never decoded here.
            codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
            codexRolloutPath = try container.decodeIfPresent(String.self, forKey: .codexRolloutPath)
            codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
            codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort)
            codexContextWindow = try container.decodeIfPresent(Int.self, forKey: .codexContextWindow)
            codexLastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexLastTotalTokens)
            codexTotalTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexTotalTotalTokens)
            codexMcpSessionKey = try container.decodeIfPresent(String.self, forKey: .codexMcpSessionKey)
            parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
            worktreeBindings = try container.decodeIfPresent(
                [AgentSessionWorktreeBinding].self,
                forKey: .worktreeBindings
            )
            worktreeMergeOperations = try container.decodeIfPresent(
                [AgentSessionWorktreeMergeOperation].self,
                forKey: .worktreeMergeOperations
            )
            pendingHandoffPayload = try container.decodeIfPresent(String.self, forKey: .pendingHandoffPayload)
            pendingHandoffCreatedAt = try container.decodeIfPresent(Date.self, forKey: .pendingHandoffCreatedAt)
            pendingHandoffSourceItemID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffSourceItemID)
            pendingHandoffDefersProviderLockUntilSend = try container.decodeIfPresent(
                Bool.self,
                forKey: .pendingHandoffDefersProviderLockUntilSend
            )
            isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated)
            origin = try container.decodeIfPresent(AgentSessionOrigin.self, forKey: .origin)
            if container.contains(.profile) {
                guard try !container.decodeNil(forKey: .profile) else {
                    throw DecodingError.valueNotFound(
                        AgentSessionProfile.self,
                        .init(
                            codingPath: container.codingPath + [CodingKeys.profile],
                            debugDescription: "Agent session profile cannot be null"
                        )
                    )
                }
                profile = try container.decode(AgentSessionProfile.self, forKey: .profile)
            } else {
                profile = nil
            }
            scheduledSend = try container.decodeIfPresent(AgentScheduledSendMember.self, forKey: .scheduledSend)
            lastScheduledDispatch = try container.decodeIfPresent(
                AgentScheduledSendProvenance.self,
                forKey: .lastScheduledDispatch
            )
        }
    }

    private func computeLastUserMessageAt(in items: [AgentChatItemPersist]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items.map { $0.toItem() })
    }

    private func computeLastUserMessageAt(in transcript: AgentTranscript) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: transcript)
    }

    private func computeProjectionCounts(in transcript: AgentTranscript) -> AgentTranscriptProjectionCounts {
        AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
    }

    private struct NormalizedLoadedSession {
        let runtimeSession: AgentSession
        let persistedSessionToRewrite: AgentSession?
    }

    enum SavePreparation {
        case canonicalize
        case alreadyCanonicalTranscript
    }

    private struct PreparedSessionMetadata {
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
    }

    private func preparedSessionMetadata(
        transcript: AgentTranscript?,
        workingItems: [AgentChatItem],
        existingItemCount: Int?,
        existingProjectionCounts: AgentTranscriptProjectionCounts?,
        existingLastUserMessageAt: Date?,
        trustedCanonicalItemCount: Int? = nil,
        preserveProvidedValues: Bool
    ) -> PreparedSessionMetadata {
        if let transcript {
            let computedProjectionCounts = computeProjectionCounts(in: transcript)
            return PreparedSessionMetadata(
                itemCount: trustedCanonicalItemCount ?? computedProjectionCounts.canonicalVisibleRowCount,
                transcriptProjectionCounts: computedProjectionCounts,
                lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? computeLastUserMessageAt(in: transcript)) : computeLastUserMessageAt(in: transcript)
            )
        }
        guard !workingItems.isEmpty else {
            return PreparedSessionMetadata(
                itemCount: preserveProvidedValues ? existingItemCount : nil,
                transcriptProjectionCounts: preserveProvidedValues ? existingProjectionCounts : nil,
                lastUserMessageAt: preserveProvidedValues ? existingLastUserMessageAt : nil
            )
        }
        let fallbackItemCount = preserveProvidedValues ? (existingItemCount ?? workingItems.count) : workingItems.count
        let fallbackProjectionCounts = preserveProvidedValues
            ? (existingProjectionCounts ?? .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            ))
            : .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            )
        return PreparedSessionMetadata(
            itemCount: fallbackItemCount,
            transcriptProjectionCounts: fallbackProjectionCounts,
            lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItems)) : AgentTranscriptIO.lastUserInteractionDate(in: workingItems)
        )
    }

    private func sessionPreparedForStorage(
        _ session: AgentSession,
        fileURL: URL? = nil,
        savedAt: Date? = nil,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil
    ) -> AgentSession {
        var stored = session
        let lastRunState = stored.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        var workingItemsCache: [AgentChatItem]?
        func workingItems() -> [AgentChatItem] {
            if let workingItemsCache {
                return workingItemsCache
            }
            let items = stored.items.map { $0.toItem() }
            workingItemsCache = items
            return items
        }

        switch preparation {
        case .alreadyCanonicalTranscript:
            if stored.transcript == nil {
                let canonicalWorkingItems = workingItems()
                if !canonicalWorkingItems.isEmpty {
                    let nextSequenceIndex = max((canonicalWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1, 0)
                    stored.transcript = AgentTranscriptIO.buildTranscript(
                        from: canonicalWorkingItems,
                        terminalState: lastRunState,
                        nextSequenceIndex: nextSequenceIndex,
                        policy: .canonical
                    )
                }
            }
            if let transcript = stored.transcript {
                stored.transcript = AgentTranscriptIO.persistedTranscript(transcript)
            }
        case .canonicalize:
            if stored.transcript == nil {
                let canonicalWorkingItems = workingItems()
                if !canonicalWorkingItems.isEmpty {
                    let nextSequenceIndex = max((canonicalWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1, 0)
                    stored.transcript = AgentTranscriptIO.buildTranscript(
                        from: canonicalWorkingItems,
                        terminalState: lastRunState,
                        nextSequenceIndex: nextSequenceIndex,
                        policy: .canonical
                    )
                }
            }
            if let transcript = stored.transcript {
                stored.transcript = AgentTranscriptIO.persistedTranscript(transcript)
            }
        }
        stored.items = []
        stored.serializationVersion = AgentSession.currentSerializationVersion
        if let fileURL {
            stored.fileURL = fileURL
        }
        if let savedAt {
            stored.savedAt = savedAt
        }
        let metadata = preparedSessionMetadata(
            transcript: stored.transcript,
            workingItems: workingItemsCache ?? [],
            existingItemCount: stored.itemCount,
            existingProjectionCounts: stored.transcriptProjectionCounts,
            existingLastUserMessageAt: stored.lastUserMessageAt,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            preserveProvidedValues: preparation == .alreadyCanonicalTranscript
        )
        stored.itemCount = metadata.itemCount
        stored.transcriptProjectionCounts = metadata.transcriptProjectionCounts
        stored.lastUserMessageAt = metadata.lastUserMessageAt
        return stored
    }

    private func normalizeLoadedSession(
        _ session: AgentSession,
        fileURL: URL
    ) -> NormalizedLoadedSession {
        let policy = AgentTranscriptImportPolicy.canonical
        let persistedLastRunState = session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        let restoredLastRunStateRaw = AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(session.lastRunState)
        let repairTerminalState = (persistedLastRunState?.isActive == true) ? nil : persistedLastRunState
        let importTerminalState = persistedLastRunState
        let repairContext = AgentTranscriptQualityRepair.Context.coldRestore(agentKindRaw: session.agentKind)
        let storedTranscript = session.transcript
        var workingItems: [AgentChatItem] = {
            if session.items.isEmpty, let storedTranscript {
                return AgentTranscriptIO.workingSourceItems(from: storedTranscript)
            }
            return session.items.map { $0.toItem() }
        }()
        let repairedWorkingCount: Int = if let repairTerminalState {
            AgentTranscriptQualityRepair.finalizePendingTerminalTools(
                in: &workingItems,
                terminalState: repairTerminalState,
                context: repairContext,
                nonToolBoundary: 200
            )
        } else {
            0
        }
        let nextSequenceIndex = max(
            storedTranscript?.nextSequenceIndex ?? 0,
            (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
        )
        let normalizedTranscript: AgentTranscript?
        if let storedTranscript {
            let shouldRebuildFromWorkingItems = repairedWorkingCount > 0
                || AgentTranscriptIO.containsRowsExcludedByPolicy(in: storedTranscript, policy: policy)
                || (repairTerminalState != nil && AgentTranscriptQualityRepair.terminalMetadataRepairNeeded(in: storedTranscript))
            if shouldRebuildFromWorkingItems {
                normalizedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: storedTranscript,
                    workingItems: workingItems,
                    terminalState: importTerminalState,
                    nextSequenceIndex: nextSequenceIndex,
                    policy: policy
                )
            } else {
                normalizedTranscript = AgentTranscriptIO.runtimeNormalizedTranscript(storedTranscript)
            }
        } else if !workingItems.isEmpty {
            normalizedTranscript = AgentTranscriptIO.buildTranscript(
                from: workingItems,
                terminalState: importTerminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: policy
            )
        } else {
            normalizedTranscript = nil
        }
        let runtimeTranscript = normalizedTranscript.map {
            let runtimeNormalized = AgentTranscriptPolicyPipeline.runtimeTranscript($0).transcript
            return AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(runtimeNormalized)
        }
        let runtimeWorkingItems = runtimeTranscript.map(AgentTranscriptIO.workingSourceItems(from:)) ?? workingItems
        var runtimeSession = session
        runtimeSession.serializationVersion = AgentSession.currentSerializationVersion
        runtimeSession.fileURL = fileURL
        runtimeSession.lastRunState = restoredLastRunStateRaw
        runtimeSession.transcript = runtimeTranscript
        runtimeSession.items = runtimeWorkingItems.map {
            AgentChatItemPersist(from: $0, sanitizeToolResults: false)
        }
        if let runtimeTranscript {
            let projectionCounts = computeProjectionCounts(in: runtimeTranscript)
            runtimeSession.itemCount = projectionCounts.canonicalVisibleRowCount
            runtimeSession.transcriptProjectionCounts = projectionCounts
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeTranscript)
        } else if !runtimeWorkingItems.isEmpty {
            runtimeSession.itemCount = runtimeWorkingItems.count
            runtimeSession.transcriptProjectionCounts = .init(
                canonicalVisibleRowCount: runtimeWorkingItems.count,
                defaultPresentedRowCount: runtimeWorkingItems.count
            )
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeSession.items)
        }
        let persistedSession = sessionPreparedForStorage(
            runtimeSession,
            fileURL: fileURL,
            savedAt: session.savedAt,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: runtimeSession.itemCount
        )
        let needsRewrite = session.serializationVersion < AgentSession.currentSerializationVersion
            || !session.items.isEmpty
            || session.lastRunState != persistedSession.lastRunState
            || session.transcript != persistedSession.transcript
            || session.itemCount != persistedSession.itemCount
            || session.transcriptProjectionCounts != persistedSession.transcriptProjectionCounts
            || session.lastUserMessageAt != persistedSession.lastUserMessageAt
        return NormalizedLoadedSession(
            runtimeSession: runtimeSession,
            persistedSessionToRewrite: needsRewrite ? persistedSession : nil
        )
    }

    private func writeDataAtomically(_ data: Data, to fileURL: URL) async throws {
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
    }

    // MARK: - Metadata Index Helpers

    private func canonicalMetadataFolderKey(_ folder: URL) -> URL {
        folder.standardizedFileURL
    }

    private func metadataIndexFileURL(forAgentSessionsFolder folder: URL) -> URL {
        folder.appendingPathComponent("AgentSessionIndex.json")
    }

    private func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }

    private func agentSessionFileURL(id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(agentSessionFilename(for: id))
    }

    private func agentSessionID(fromFilename filename: String) -> UUID? {
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else { return nil }
        let prefixLength = "AgentSession-".count
        let suffixLength = ".json".count
        guard filename.count > prefixLength + suffixLength else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefixLength)
        let end = filename.index(filename.endIndex, offsetBy: -suffixLength)
        return UUID(uuidString: String(filename[start ..< end]))
    }

    private func metadataResourceValues(for fileURL: URL) -> (size: Int64?, modified: Date?) {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init)
        return (size, values?.contentModificationDate)
    }

    private func metadataRecord(from session: AgentSession, fileURL: URL) -> AgentSessionMetadataRecord {
        let values = metadataResourceValues(for: fileURL)
        return AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: values.size,
            observedFileModificationDate: values.modified
        )
    }

    private func readMetadataIndexIfAvailable(folder: URL, preferCache: Bool = true) async -> AgentSessionMetadataIndex? {
        #if DEBUG
            let readStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        if preferCache, let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.memoryRead status=hit entries=\(cached.entries.count) quarantined=\(cached.quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return cached
        }
        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=missing duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                #if DEBUG
                    if let readStartMS {
                        WorkspaceRestorePerfLog.log(
                            "agentSessionIndex.diskRead status=schemaMismatch entries=\(index.entries.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                        )
                    }
                #endif
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=hit entries=\(index.entries.count) quarantined=\(index.quarantinedFiles.count) bytes=\(data.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return index
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=error duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS)) error=\(String(describing: error))"
                    )
                }
            #endif
            return nil
        }
    }

    private func writeMetadataIndex(_ index: AgentSessionMetadataIndex, folder: URL) async throws {
        #if DEBUG
            let writeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        var normalized = index
        normalized.schemaVersion = AgentSessionMetadataIndex.currentSchemaVersion
        normalized.entries = normalized.entries.sortedForAgentSessionMetadataIndex()
        let data = try encoder.encode(normalized)
        metadataIndexCacheByFolder[key] = normalized
        try data.write(to: metadataIndexFileURL(forAgentSessionsFolder: folder), options: .atomic)
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.metadata.writeIndex",
                startMS: writeStartMS,
                fields: [
                    "entries": String(normalized.entries.count),
                    "quarantined": String(normalized.quarantinedFiles.count)
                ]
            )
        #endif
    }

    private func upsertMetadataRecordReporting(
        _ record: AgentSessionMetadataRecord,
        folder: URL
    ) async -> Result<Void, Error> {
        do {
            let key = canonicalMetadataFolderKey(folder)
            var index: AgentSessionMetadataIndex = if let cached = metadataIndexCacheByFolder[key] {
                cached
            } else if let existing = await readMetadataIndexIfAvailable(folder: folder) {
                existing
            } else {
                AgentSessionMetadataIndex()
            }
            index.entries.removeAll { existing in
                existing.id == record.id || existing.filename == record.filename
            }
            index.entries.append(record)
            index.generatedAt = Date()
            metadataIndexCacheByFolder[key] = index
            try await writeMetadataIndex(index, folder: folder)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func upsertMetadataRecord(_ record: AgentSessionMetadataRecord, folder: URL) async {
        _ = await upsertMetadataRecordReporting(record, folder: folder)
        // Session files remain authoritative; a later backfill/reconcile can repair the index.
    }

    private func upsertMetadataRecordIfIndexPresent(_ session: AgentSession, fileURL: URL) async {
        let folder = fileURL.deletingLastPathComponent()
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let record = metadataRecord(from: session, fileURL: fileURL)
        if let existing = index.entries.first(where: { $0.id == record.id }),
           existing.matchesIndexedSessionMetadata(record)
        {
            return
        }
        index.entries.removeAll { existing in
            existing.id == record.id || existing.filename == record.filename
        }
        index.entries.append(record)
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func removeMetadataRecords(
        matching shouldRemove: (AgentSessionMetadataRecord) -> Bool,
        folder: URL
    ) async {
        #if DEBUG
            let removeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            var debugEntriesBefore = 0
            var debugEntriesAfter = 0
            var debugChanged = false
            defer {
                AgentModePerfDiagnostics.durationEvent(
                    "cleanup.metadata.removeRecords",
                    startMS: removeStartMS,
                    fields: [
                        "entriesBefore": String(debugEntriesBefore),
                        "entriesAfter": String(debugEntriesAfter),
                        "changed": String(debugChanged)
                    ]
                )
            }
        #endif
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let originalCount = index.entries.count
        #if DEBUG
            debugEntriesBefore = originalCount
            debugEntriesAfter = originalCount
        #endif
        index.entries.removeAll(where: shouldRemove)
        #if DEBUG
            debugEntriesAfter = index.entries.count
            debugChanged = index.entries.count != originalCount
        #endif
        guard index.entries.count != originalCount else { return }
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func agentSessionFiles(in folder: URL) throws -> [URL] {
        #if DEBUG
            let scanStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let jsonFiles = contents.filter {
            $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent.starts(with: "AgentSession-")
        }
        let sorted = jsonFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        #if DEBUG
            if let scanStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.fileScan scannedSessionFiles=\(sorted.count) directoryEntries=\(contents.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: scanStartMS))"
                )
            }
        #endif
        return sorted
    }

    private func metadataIndexNeedsFilenameReconciliation(_ index: AgentSessionMetadataIndex, folder: URL) throws -> Bool {
        #if DEBUG
            let reconcileCheckStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let fileNames = try Set(agentSessionFiles(in: folder).map(\.lastPathComponent))
        let indexedNames = Set(index.entries.map(\.filename))
        let needsReconciliation = fileNames != indexedNames
        #if DEBUG
            if let reconcileCheckStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.reconcileCheck needsRebuild=\(needsReconciliation) scannedSessionFiles=\(fileNames.count) indexedEntries=\(indexedNames.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: reconcileCheckStartMS))"
                )
            }
        #endif
        return needsReconciliation
    }

    private func rebuildMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        let key = canonicalMetadataFolderKey(folder)
        #if DEBUG
            let rebuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let now = Date()
        let files = try agentSessionFiles(in: folder)
        var records: [AgentSessionMetadataRecord] = []
        var quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
        records.reserveCapacity(files.count)

        for fileURL in files {
            let values = metadataResourceValues(for: fileURL)
            do {
                // Load a lightweight stub (transcript=nil). Transcript-derived v5 fields
                // (duration primitives, keyPaths, toolCount, activity bounds) are left empty
                // here and computed on demand by the `history` tool — see
                // `AgentSessionMetadataRecord.enrichingTranscriptDerivedFields(from:)`. This
                // keeps the shared index rebuild — which feeds the agent-mode sidebar and
                // workspace restore — from decoding every full session transcript just to
                // precompute fields only history consumes. The save/load path still populates
                // these fields for free for sessions touched through normal app use.
                let stub = try await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                )
                records.append(
                    AgentSessionMetadataRecord.record(
                        from: stub,
                        fileURL: fileURL,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        lastIndexedAt: now
                    )
                )
            } catch {
                quarantinedFiles.append(
                    AgentSessionMetadataQuarantineRecord(
                        filename: fileURL.lastPathComponent,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        errorDescription: String(describing: error),
                        lastAttemptedAt: now
                    )
                )
            }
        }

        let index = AgentSessionMetadataIndex(
            generatedAt: now,
            lastReconciledAt: now,
            entries: records.sortedForAgentSessionMetadataIndex(),
            quarantinedFiles: quarantinedFiles
        )
        try? await writeMetadataIndex(index, folder: folder)
        metadataIndexReconciledThisProcess.insert(key)
        #if DEBUG
            if let rebuildStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.rebuild scannedSessionFiles=\(files.count) records=\(records.count) quarantined=\(quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: rebuildStartMS))"
                )
            }
        #endif
        return index
    }

    private func reconcileMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        try await rebuildMetadataIndex(folder: folder)
    }

    private func scheduleMetadataIndexReconciliationIfNeeded(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        reason: String = "metadataIndexBackfill",
        workspaceID: UUID? = nil
    ) {
        let key = canonicalMetadataFolderKey(folder)
        let alreadyReconciled = metadataIndexReconciledThisProcess.contains(key)
        let existingTaskState = metadataIndexReconciliationTasksByFolder[key]
        let alreadyScheduled = existingTaskState != nil
        let effectiveDelaySeconds = max(delaySeconds, 0)
        let promotesDelayedReconciliation = existingTaskState.map {
            $0.delaySeconds > 0 && effectiveDelaySeconds == 0
        } ?? false
        let willSchedule = !alreadyReconciled && (!alreadyScheduled || promotesDelayedReconciliation)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.reconcileScheduled",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspaceID),
                    "delayMS": "\(Int((effectiveDelaySeconds * 1000).rounded()))",
                    "reason": reason,
                    "alreadyScheduled": "\(alreadyScheduled)",
                    "alreadyReconciled": "\(alreadyReconciled)",
                    "scheduled": "\(willSchedule)"
                ]
            )
        #endif
        guard willSchedule else { return }
        if promotesDelayedReconciliation {
            existingTaskState?.task.cancel()
        }
        let taskID = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await reconcileMetadataIndexInBackground(
                folder: folder,
                delaySeconds: effectiveDelaySeconds,
                taskID: taskID
            )
        }
        metadataIndexReconciliationTasksByFolder[key] = MetadataIndexReconciliationTaskState(
            id: taskID,
            task: task,
            delaySeconds: effectiveDelaySeconds
        )
    }

    private func reconcileMetadataIndexInBackground(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        taskID: UUID
    ) async {
        let key = canonicalMetadataFolderKey(folder)
        defer {
            if metadataIndexReconciliationTasksByFolder[key]?.id == taskID {
                metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            }
        }
        if delaySeconds > 0 {
            let nanoseconds = UInt64(min(delaySeconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
        }
        do {
            _ = try await reconcileMetadataIndex(folder: folder)
        } catch {
            // Best-effort: session files remain authoritative, and explicit force-reconcile can repair later.
        }
    }

    private func metadataIndex(
        for workspace: WorkspaceModel,
        mode: AgentSessionMetadataIndexLoadMode
    ) async throws -> AgentSessionMetadataIndex? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        switch mode {
        case .fast:
            return await readMetadataIndexIfAvailable(folder: folder)
        case .backfillIfMissing:
            if let index = await readMetadataIndexIfAvailable(folder: folder) {
                scheduleMetadataIndexReconciliationIfNeeded(folder: folder)
                return index
            }
            return try await rebuildMetadataIndex(folder: folder)
        case .forceReconcile:
            return try await reconcileMetadataIndex(folder: folder)
        }
    }

    func fastMetadataRecordsIfAvailable(for workspace: WorkspaceModel) async throws -> FastMetadataRecordsResult? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let key = canonicalMetadataFolderKey(folder)
        if let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            return FastMetadataRecordsResult(
                records: cached.entries.sortedForAgentSessionMetadataIndex(),
                source: .memoryIndex
            )
        }

        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            return FastMetadataRecordsResult(
                records: index.entries.sortedForAgentSessionMetadataIndex(),
                source: .diskIndex
            )
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }
    }

    func metadataRecordForSessionID(_ id: UUID, for workspace: WorkspaceModel) async throws -> AgentSessionMetadataRecord? {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: id, in: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let stub = try await loadAgentSessionStub(
            from: fileURL,
            recoverMissingMetadata: false,
            persistRecoveredMetadata: false
        )
        return metadataRecord(from: stub, fileURL: fileURL)
    }

    private func metadataRecords(
        for workspace: WorkspaceModel,
        limit: Int? = nil
    ) async throws -> [AgentSessionMetadataRecord] {
        let index = try await metadataIndex(for: workspace, mode: .backfillIfMissing)
        let records = index?.entries.sortedForAgentSessionMetadataIndex() ?? []
        guard let limit else { return records }
        return Array(records.prefix(max(limit, 0)))
    }

    func indexedAgentSessionMetadataRecords(for workspace: WorkspaceModel) async throws -> [AgentSessionMetadataRecord] {
        try await metadataRecords(for: workspace)
    }

    func sidebarStreamMetadataRecords(for workspace: WorkspaceModel) async throws -> [AgentSessionMetadataRecord] {
        let folder = try ensureAgentSessionsFolder(for: workspace)
        if let index = await readMetadataIndexIfAvailable(folder: folder) {
            scheduleMetadataIndexReconciliationIfNeeded(
                folder: folder,
                delaySeconds: Self.sidebarStreamMetadataIndexReconciliationDelaySeconds,
                reason: "sidebarStreamHotIndex",
                workspaceID: workspace.id
            )
            return index.entries.sortedForAgentSessionMetadataIndex()
        }
        let index = try await rebuildMetadataIndex(folder: folder)
        return index.entries.sortedForAgentSessionMetadataIndex()
    }

    private func canonicalSessionFileKey(_ fileURL: URL) -> URL {
        fileURL.standardizedFileURL
    }

    private func currentTranscriptResetGeneration(for fileKey: URL) -> UInt64 {
        transcriptResetAuthorityByFileURL[fileKey]?.generation ?? 0
    }

    private func persistenceState(
        sessionID: UUID,
        workspaceID: UUID,
        fileURL: URL
    ) -> AgentSessionPersistenceState {
        let fileKey = canonicalSessionFileKey(fileURL)
        return AgentSessionPersistenceState(
            stamp: AgentSessionPersistenceStamp(
                sessionID: sessionID,
                workspaceID: workspaceID,
                deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
                serviceID: persistenceServiceID,
                fileURL: fileKey
            ),
            transcriptResetGeneration: currentTranscriptResetGeneration(for: fileKey)
        )
    }

    private func validatePersistenceStamp(
        _ stamp: AgentSessionPersistenceStamp,
        sessionID: UUID,
        workspaceID: UUID
    ) throws {
        guard stamp.serviceID == persistenceServiceID,
              stamp.sessionID == sessionID,
              stamp.workspaceID == workspaceID
        else {
            throw AgentScheduledSendMutationError.invalidPersistenceStamp
        }
        let currentGeneration = deletionGenerationsByFileKey[stamp.fileURL] ?? 0
        guard stamp.deletionGeneration == currentGeneration else {
            throw AgentScheduledSendMutationError.staleDeletionGeneration(
                expected: stamp.deletionGeneration,
                actual: currentGeneration
            )
        }
    }

    private func sessionContainsItem(_ session: AgentSession, itemID: UUID) -> Bool {
        if session.items.contains(where: { $0.id == itemID }) {
            return true
        }
        guard let transcript = session.transcript else { return false }
        for turn in transcript.turns {
            if turn.request?.id == itemID {
                return true
            }
            if turn.responseSpans.contains(where: {
                $0.activities.contains(where: { $0.id == itemID })
            }) {
                return true
            }
        }
        return false
    }

    private func scheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        applyingTranscriptResetTo postResetSession: AgentSession
    ) -> AgentSessionScheduleAuthority {
        var updated = authority
        for (itemID, protectedItem) in authority.protectedAcceptedUserItemsByID
            where !sessionContainsItem(postResetSession, itemID: itemID)
        {
            guard let receipt = protectedItem.scheduledSend else { continue }
            updated.protectedAcceptedUserItemsByID.removeValue(forKey: itemID)
            updated.intentionallyRemovedAcceptedUserItemReceiptsByID[itemID] = receipt
        }
        return updated
    }

    private func cachedOrLoadedScheduleAuthority(
        for fileURL: URL
    ) throws -> AgentSessionScheduleAuthority {
        let key = canonicalSessionFileKey(fileURL)
        if let cached = scheduleAuthorityByFileURL[key] {
            return cached
        }

        let persistedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let persistedHeader = try AgentSessionDataCodec.decodeEnvelope(
            AgentSessionScheduleHeader.self,
            from: persistedData,
            using: decoder
        ).value
        let authority = AgentSessionScheduleAuthority(
            scheduledSend: persistedHeader.scheduledSend,
            lastScheduledDispatch: persistedHeader.lastScheduledDispatch,
            protectedAcceptedUserItemsByID: [:],
            intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
        )
        scheduleAuthorityByFileURL[key] = authority
        return authority
    }

    private func rememberScheduleAuthority(
        from session: AgentSession,
        fileURL: URL,
        protecting acceptedUserItem: AgentChatItem? = nil,
        preservingItemAuthority itemAuthority: AgentSessionScheduleAuthority? = nil
    ) {
        let key = canonicalSessionFileKey(fileURL)
        let existingAuthority = itemAuthority ?? scheduleAuthorityByFileURL[key]
        var protectedItems = existingAuthority?.protectedAcceptedUserItemsByID ?? [:]
        var intentionallyRemovedItems =
            existingAuthority?.intentionallyRemovedAcceptedUserItemReceiptsByID ?? [:]
        if let acceptedUserItem {
            protectedItems[acceptedUserItem.id] = acceptedUserItem
            intentionallyRemovedItems.removeValue(forKey: acceptedUserItem.id)
        }
        scheduleAuthorityByFileURL[key] = AgentSessionScheduleAuthority(
            scheduledSend: session.scheduledSend,
            lastScheduledDispatch: session.lastScheduledDispatch,
            protectedAcceptedUserItemsByID: protectedItems,
            intentionallyRemovedAcceptedUserItemReceiptsByID: intentionallyRemovedItems
        )
    }

    private func scheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        applying removals: [AgentScheduledSendFinalizedItemRemoval],
        to session: AgentSession,
        staleRemovalPolicy: StaleFinalizedItemRemovalPolicy = .fail
    ) throws -> AgentSessionScheduleAuthority {
        guard !removals.isEmpty else { return authority }

        var updated = authority
        for removal in removals {
            let conflictingReceipt = [
                updated.protectedAcceptedUserItemsByID[removal.itemID]?.scheduledSend,
                scheduledSendProvenance(in: session, itemID: removal.itemID),
                updated.intentionallyRemovedAcceptedUserItemReceiptsByID[removal.itemID]
            ]
            .compactMap(\.self)
            .first { $0 != removal.receipt }

            if let conflictingReceipt {
                switch staleRemovalPolicy {
                case .fail:
                    throw AgentScheduledSendMutationError.staleExpectedFinalizedItem(
                        itemID: removal.itemID,
                        expected: removal.receipt,
                        actual: conflictingReceipt
                    )
                case .ignore:
                    // The explicit reset still commits, but must not erase a newer accepted item.
                    continue
                }
            }
            updated.protectedAcceptedUserItemsByID.removeValue(forKey: removal.itemID)
            updated.intentionallyRemovedAcceptedUserItemReceiptsByID[removal.itemID] = removal.receipt
        }
        return updated
    }

    private func sessionByApplyingScheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        to session: AgentSession
    ) -> AgentSession {
        var merged = session
        merged.scheduledSend = authority.scheduledSend
        merged.lastScheduledDispatch = authority.lastScheduledDispatch
        merged = sessionByMergingProtectedAcceptedUserItems(
            authority.protectedAcceptedUserItemsByID,
            into: merged
        )
        return sessionByRemovingIntentionallyRemovedAcceptedUserItems(
            authority.intentionallyRemovedAcceptedUserItemReceiptsByID,
            from: merged
        )
    }

    private func scheduledSendProvenance(
        in session: AgentSession,
        itemID: UUID
    ) -> AgentScheduledSendProvenance? {
        if let item = session.items.first(where: { $0.id == itemID }),
           let receipt = item.scheduledSend
        {
            return receipt
        }
        guard let transcript = session.transcript else { return nil }
        for turn in transcript.turns {
            if let request = turn.request,
               request.id == itemID,
               let receipt = request.scheduledSend
            {
                return receipt
            }
            for span in turn.responseSpans {
                if let receipt = span.activities.first(where: { $0.id == itemID })?.scheduledSend {
                    return receipt
                }
            }
        }
        return nil
    }

    private func finalizedScheduledUserItem(
        in session: AgentSession,
        itemID: UUID,
        receipt: AgentScheduledSendProvenance
    ) -> AgentChatItem? {
        if let item = session.items.first(where: {
            $0.id == itemID && $0.scheduledSend == receipt
        }) {
            return item.toItem()
        }
        guard let transcript = session.transcript else { return nil }
        for turn in transcript.turns {
            if let request = turn.request,
               request.id == itemID,
               request.scheduledSend == receipt
            {
                return request.toItem()
            }
            for span in turn.responseSpans {
                if let activity = span.activities.first(where: {
                    $0.id == itemID && $0.scheduledSend == receipt
                }) {
                    return activity.toItem()
                }
            }
        }
        return nil
    }

    private func sessionByRemovingIntentionallyRemovedAcceptedUserItems(
        _ removedItemReceiptsByID: [UUID: AgentScheduledSendProvenance],
        from session: AgentSession
    ) -> AgentSession {
        guard !removedItemReceiptsByID.isEmpty else { return session }

        var updated = session
        updated.items.removeAll { removedItemReceiptsByID[$0.id] != nil }
        if var transcript = updated.transcript {
            for turnIndex in transcript.turns.indices {
                if let request = transcript.turns[turnIndex].request,
                   removedItemReceiptsByID[request.id] != nil
                {
                    transcript.turns[turnIndex].request = nil
                }
                for spanIndex in transcript.turns[turnIndex].responseSpans.indices {
                    transcript.turns[turnIndex].responseSpans[spanIndex].activities.removeAll {
                        removedItemReceiptsByID[$0.id] != nil
                    }
                }
            }
            updated.transcript = transcript
        }
        return updated
    }

    private func sessionByMergingProtectedAcceptedUserItems(
        _ protectedItemsByID: [UUID: AgentChatItem],
        into session: AgentSession
    ) -> AgentSession {
        guard !protectedItemsByID.isEmpty else { return session }

        var merged = session
        var workingItems = merged.workingSourceItems()
        var didChange = false
        let protectedItems = protectedItemsByID.values.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }

        for protectedItem in protectedItems {
            if let receipt = protectedItem.scheduledSend,
               finalizedScheduledUserItem(
                   in: merged,
                   itemID: protectedItem.id,
                   receipt: receipt
               ) != nil
            {
                continue
            }
            if let existingIndex = workingItems.firstIndex(where: { $0.id == protectedItem.id }) {
                guard workingItems[existingIndex] != protectedItem else { continue }
                workingItems[existingIndex] = protectedItem
            } else {
                workingItems.append(protectedItem)
            }
            didChange = true
        }
        guard didChange else { return merged }

        workingItems.sort { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let nextSequenceIndex = max(
            merged.transcript?.nextSequenceIndex ?? 0,
            (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
        )
        let terminalState = merged.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        if let transcript = merged.transcript {
            merged.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript,
                workingItems: workingItems,
                terminalState: terminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: .canonical
            )
        } else {
            merged.transcript = AgentTranscriptIO.buildTranscript(
                from: workingItems,
                terminalState: terminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: .canonical
            )
        }
        merged.items = workingItems.map {
            AgentChatItemPersist(from: $0, sanitizeToolResults: false)
        }
        return merged
    }

    // MARK: - Public API

    /// Issues the lifetime/reset state for a genuine initial creation. The caller retains this
    /// value and must not replace it after a missing-file or deletion failure.
    func prepareInitialAgentSessionPersistence(
        sessionID: UUID,
        for workspace: WorkspaceModel
    ) async throws -> AgentSessionPersistenceState {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: folder)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionAlreadyExists(sessionID)
        }
        return persistenceState(
            sessionID: sessionID,
            workspaceID: workspace.id,
            fileURL: fileURL
        )
    }

    /// Loads an editable session and its process-local persistence state under one gate. The
    /// caller must adopt both values together; the state cannot safely authorize an older snapshot.
    func loadAgentSessionForEditing(
        id sessionID: UUID,
        for workspace: WorkspaceModel
    ) async throws -> AgentSessionEditableLoad? {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let session = try await loadAgentSessionLocked(from: fileURL)
        return AgentSessionEditableLoad(
            session: session,
            persistenceState: persistenceState(
                sessionID: sessionID,
                workspaceID: workspace.id,
                fileURL: fileURL
            )
        )
    }

    /// Saves the full session while keeping schedule persistence under its dedicated CAS authority.
    ///
    /// On initial creation, the supplied schedule fields are written as-is. Once the file exists,
    /// its `scheduledSend` and `lastScheduledDispatch` members are authoritative and are merged
    /// into the full-session payload. Callers use `mutateScheduledSend` for schedule changes and
    /// `finalizeScheduledSend` for provider-accepted turns. Finalized user items remain protected
    /// from stale VM snapshots until a caller explicitly supplies their exact item/receipt identities
    /// in `intentionallyRemovingFinalizedScheduledSendItems`. Explicit removals install process-local
    /// tombstones so later stale snapshots cannot resurrect the removed items. A committed transcript
    /// reset also records its canonical post-reset snapshot for accepted-send recovery after accidental
    /// file loss. This URL-returning overload remains for generic compatibility; editable Agent Mode
    /// owners must use the persistence-state overload below.
    func saveAgentSession(
        _ session: AgentSession,
        for workspace: WorkspaceModel,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval] = [],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt? = nil,
        fileCreationPolicy: AgentSessionFileCreationPolicy = .createIfMissing
    ) async throws -> URL {
        await acquireSessionPersistence(for: session.id)
        defer { releaseSessionPersistence(for: session.id) }
        let commit = try await saveAgentSessionLocked(
            session,
            for: workspace,
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            intentionallyRemovingFinalizedScheduledSendItems: removals,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: fileCreationPolicy,
            expectedPersistenceState: nil
        )
        return commit.fileURL
    }

    /// Fenced full-save entry point for an editable owner. The returned state is the only state
    /// that owner may use for later saves; failures never refresh or transfer ownership.
    func saveAgentSession(
        _ session: AgentSession,
        for workspace: WorkspaceModel,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval] = [],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt? = nil,
        fileCreationPolicy: AgentSessionFileCreationPolicy = .createIfMissing,
        persistenceState: AgentSessionPersistenceState
    ) async throws -> AgentSessionSaveCommit {
        await acquireSessionPersistence(for: session.id)
        defer { releaseSessionPersistence(for: session.id) }
        return try await saveAgentSessionLocked(
            session,
            for: workspace,
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            intentionallyRemovingFinalizedScheduledSendItems: removals,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: fileCreationPolicy,
            expectedPersistenceState: persistenceState
        )
    }

    private func saveAgentSessionLocked(
        _ session: AgentSession,
        for workspace: WorkspaceModel,
        preparation: SavePreparation,
        trustedCanonicalItemCount: Int?,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt?,
        fileCreationPolicy: AgentSessionFileCreationPolicy,
        expectedPersistenceState: AgentSessionPersistenceState?
    ) async throws -> AgentSessionSaveCommit {
        let agentSessionsFolder: URL
        let fileURL: URL
        if let expectedPersistenceState {
            try validatePersistenceStamp(
                expectedPersistenceState.stamp,
                sessionID: session.id,
                workspaceID: workspace.id
            )
            fileURL = expectedPersistenceState.stamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: session.id, in: agentSessionsFolder)
        }
        let fileKey = canonicalSessionFileKey(fileURL)

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        if !fileExists, case .requireExisting = fileCreationPolicy {
            throw AgentScheduledSendMutationError.sessionNotFound(session.id)
        }

        let currentResetGeneration = currentTranscriptResetGeneration(for: fileKey)
        if let resetReceipt,
           fileExists,
           let committedReset = transcriptResetAuthorityByFileURL[fileKey],
           committedReset.deletionGeneration == (deletionGenerationsByFileKey[fileKey] ?? 0),
           committedReset.receipt == resetReceipt
        {
            return AgentSessionSaveCommit(
                fileURL: fileURL,
                persistenceState: persistenceState(
                    sessionID: session.id,
                    workspaceID: workspace.id,
                    fileURL: fileURL
                ),
                disposition: .resetAlreadyCommitted
            )
        }
        if let expectedPersistenceState,
           expectedPersistenceState.transcriptResetGeneration != currentResetGeneration
        {
            throw AgentScheduledSendMutationError.staleTranscriptResetGeneration(
                expected: expectedPersistenceState.transcriptResetGeneration,
                actual: currentResetGeneration
            )
        }

        let staleRemovalPolicy: StaleFinalizedItemRemovalPolicy =
            resetReceipt == nil ? .fail : .ignore
        var sessionWithAuthoritativeSchedule = session
        var itemAuthorityForSave: AgentSessionScheduleAuthority?
        if fileExists {
            var authority = try cachedOrLoadedScheduleAuthority(for: fileURL)
            authority = try scheduleAuthority(
                authority,
                applying: removals,
                to: session,
                staleRemovalPolicy: staleRemovalPolicy
            )
            if resetReceipt != nil {
                authority = scheduleAuthority(
                    authority,
                    applyingTranscriptResetTo: session
                )
            }
            itemAuthorityForSave = authority
            sessionWithAuthoritativeSchedule = sessionByApplyingScheduleAuthority(
                authority,
                to: sessionWithAuthoritativeSchedule
            )
        } else if !removals.isEmpty {
            var authority = AgentSessionScheduleAuthority(
                scheduledSend: session.scheduledSend,
                lastScheduledDispatch: session.lastScheduledDispatch,
                protectedAcceptedUserItemsByID: [:],
                intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
            )
            authority = try scheduleAuthority(
                authority,
                applying: removals,
                to: session,
                staleRemovalPolicy: staleRemovalPolicy
            )
            itemAuthorityForSave = authority
            sessionWithAuthoritativeSchedule = sessionByApplyingScheduleAuthority(
                authority,
                to: sessionWithAuthoritativeSchedule
            )
        }
        let hasItemAuthority = itemAuthorityForSave.map {
            !$0.protectedAcceptedUserItemsByID.isEmpty
                || !$0.intentionallyRemovedAcceptedUserItemReceiptsByID.isEmpty
        } ?? false

        let sessionToSave = sessionPreparedForStorage(
            sessionWithAuthoritativeSchedule,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: preparation,
            trustedCanonicalItemCount: resetReceipt != nil || hasItemAuthority
                ? nil
                : trustedCanonicalItemCount
        )
        let freshEncoder = JSONEncoder()
        // Field-local codec: `providerUsage` bytes are re-inserted verbatim; any preservation
        // failure throws here, before the atomic writer replaces the file.
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: freshEncoder)
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
        rememberScheduleAuthority(
            from: sessionToSave,
            fileURL: fileURL,
            preservingItemAuthority: itemAuthorityForSave
        )
        if let resetReceipt {
            transcriptResetAuthorityByFileURL[fileKey] =
                AgentSessionTranscriptResetAuthority(
                    deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
                    generation: currentResetGeneration &+ 1,
                    receipt: resetReceipt,
                    canonicalSessionSnapshot: data
                )
        }
        await upsertMetadataRecord(metadataRecord(from: sessionToSave, fileURL: fileURL), folder: agentSessionsFolder)
        return AgentSessionSaveCommit(
            fileURL: fileURL,
            persistenceState: persistenceState(
                sessionID: session.id,
                workspaceID: workspace.id,
                fileURL: fileURL
            ),
            disposition: .written
        )
    }

    /// Atomically compare-and-mutates the persisted scheduled-send member.
    ///
    /// All schedule mutations for one session are serialized through this API. A successful return
    /// always means the authoritative session file was durably replaced. Metadata-index failure is
    /// reported separately because retrying the already-committed mutation would be unsafe. Editable
    /// scheduling owners must use the persistence-stamp overload below.
    func mutateScheduledSend(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await performScheduledSendMutation(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: nil,
            mutation: mutation
        )
    }

    /// Fenced schedule-only mutation for an editable owner.
    func mutateScheduledSend(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        persistenceStamp: AgentSessionPersistenceStamp,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await performScheduledSendMutation(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceStamp,
            mutation: mutation
        )
    }

    private func performScheduledSendMutation(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        persistenceStamp: AgentSessionPersistenceStamp?,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        let agentSessionsFolder: URL
        let fileURL: URL
        if let persistenceStamp {
            try validatePersistenceStamp(
                persistenceStamp,
                sessionID: sessionID,
                workspaceID: workspace.id
            )
            fileURL = persistenceStamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }

        var session = try await loadAgentSessionLocked(from: fileURL)

        switch mutation {
        case let .upsert(expectedUpdatedAt, value):
            let actualUpdatedAt: Date?
            switch session.scheduledSend {
            case nil:
                actualUpdatedAt = nil
            case let .v1(current):
                actualUpdatedAt = current.updatedAt
            case .unreadable:
                throw AgentScheduledSendMutationError.unreadableScheduledSend(sessionID)
            }
            guard expectedUpdatedAt == actualUpdatedAt else {
                throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(
                    expected: expectedUpdatedAt,
                    actual: actualUpdatedAt
                )
            }
            session.scheduledSend = .v1(value)
        case let .clear(expectedUpdatedAt, completedDispatch):
            let actualUpdatedAt: Date?
            switch session.scheduledSend {
            case nil:
                actualUpdatedAt = nil
            case let .v1(current):
                actualUpdatedAt = current.updatedAt
            case .unreadable:
                throw AgentScheduledSendMutationError.unreadableScheduledSend(sessionID)
            }
            guard actualUpdatedAt == expectedUpdatedAt else {
                throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(
                    expected: expectedUpdatedAt,
                    actual: actualUpdatedAt
                )
            }
            session.scheduledSend = nil
            if let completedDispatch {
                session.lastScheduledDispatch = completedDispatch
            }
        case let .discardUnreadable(expected):
            let expectedMember = AgentScheduledSendMember.unreadable(expected)
            guard session.scheduledSend == expectedMember else {
                throw AgentScheduledSendMutationError.staleExpectedScheduledSendMember(
                    expected: expectedMember,
                    actual: session.scheduledSend
                )
            }
            session.scheduledSend = nil
        }

        let sessionToSave = sessionPreparedForStorage(
            session,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: session.itemCount
        )
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: JSONEncoder())
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
        rememberScheduleAuthority(from: sessionToSave, fileURL: fileURL)

        let indexStatus: AgentScheduledSendMutationResult.MetadataIndexStatus =
            switch await upsertMetadataRecordReporting(
                metadataRecord(from: sessionToSave, fileURL: fileURL),
                folder: agentSessionsFolder
            ) {
            case .success:
                .updated
            case let .failure(error):
                .repairNeeded(String(describing: error))
            }

        return AgentScheduledSendMutationResult(
            session: sessionToSave,
            fileURL: fileURL,
            metadataIndexStatus: indexStatus
        )
    }

    /// Atomically commits an accepted scheduled user turn and retires its durable schedule.
    ///
    /// The immutable schedule revision and exact dispatch attempt are validated under the same
    /// per-session persistence gate used by ordinary saves. A successful return means the user
    /// item (with provenance), dispatch receipt, and schedule removal are in one durable session
    /// replacement. Matching retries are persistence-idempotent and never authorize provider work.
    func finalizeScheduledSend(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        do {
            let result = try await performScheduledSendFinalization(
                sessionID: sessionID,
                for: workspace,
                expectedUpdatedAt: expectedUpdatedAt,
                expectedAttempt: expectedAttempt,
                acceptedUserItem: acceptedUserItem,
                receipt: receipt
            )
            releaseSessionPersistence(for: sessionID)
            return result
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    /// Captures a DataService-issued recovery context for a persisted `.dispatching` attempt
    /// under the session gate: the pinned destination, the current explicit-deletion generation,
    /// and the canonical session snapshot used only for accidental missing-file reconstruction.
    /// Provider-handoff callers must use the persistence-stamp overload below.
    func prepareScheduledSendRecovery(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await prepareScheduledSendRecoveryLocked(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: nil,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt
        )
    }

    /// Fenced recovery preparation for an editable owner.
    func prepareScheduledSendRecovery(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        persistenceStamp: AgentSessionPersistenceStamp,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await prepareScheduledSendRecoveryLocked(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceStamp,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt
        )
    }

    private func prepareScheduledSendRecoveryLocked(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        persistenceStamp: AgentSessionPersistenceStamp?,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        let agentSessionsFolder: URL
        let fileURL: URL
        if let persistenceStamp {
            try validatePersistenceStamp(
                persistenceStamp,
                sessionID: sessionID,
                workspaceID: workspace.id
            )
            fileURL = persistenceStamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        }
        let fileKey = canonicalSessionFileKey(fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        let session = try await loadAgentSessionLocked(from: fileURL)
        guard let record = session.scheduledSend?.persistedValue else {
            throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(expected: expectedUpdatedAt, actual: nil)
        }
        guard record.updatedAt == expectedUpdatedAt else {
            throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(expected: expectedUpdatedAt, actual: record.updatedAt)
        }
        guard record.attempt == expectedAttempt else {
            throw AgentScheduledSendMutationError.staleExpectedAttempt(expected: expectedAttempt, actual: record.attempt)
        }
        guard record.state == .dispatching else {
            throw AgentScheduledSendMutationError.scheduledSendNotDispatching(actual: record.state)
        }
        let snapshot = try AgentSessionDataCodec.encodeSession(session, using: JSONEncoder())
        return AgentScheduledSendRecoveryContext(
            sessionID: sessionID,
            workspaceID: workspace.id,
            workspace: workspace,
            fileURL: fileURL,
            agentSessionsFolderURL: agentSessionsFolder,
            deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
            canonicalSessionSnapshot: snapshot,
            transcriptResetReceiptAtPreparation:
            transcriptResetAuthorityByFileURL[fileKey]?.receipt,
            transcriptResetGenerationAtPreparation:
            currentTranscriptResetGeneration(for: fileKey),
            dataService: self
        )
    }

    /// Recovery finalization at the pinned destination, under the same gate and through the same
    /// accepted-item/receipt/schedule-retirement pipeline as `finalizeScheduledSend`. When the
    /// authoritative file is missing, explicit-deletion evidence is checked first; only an
    /// accidental loss is reconstructed from the captured canonical snapshot. Never overwrites an
    /// existing file wholesale.
    func finalizeScheduledSend(
        recovery payload: AgentScheduledSendAcceptedPayload
    ) async throws -> AgentScheduledSendRecoveryOutcome {
        let context = payload.context
        guard context.dataService === self else {
            throw AgentScheduledSendMutationError.invalidPersistenceStamp
        }
        await acquireSessionPersistence(for: context.sessionID)
        defer { releaseSessionPersistence(for: context.sessionID) }
        let fileKey = canonicalSessionFileKey(context.fileURL)
        let currentDeletionGeneration = deletionGenerationsByFileKey[fileKey] ?? 0
        guard currentDeletionGeneration == context.deletionGeneration else {
            return .explicitlyDeleted
        }
        let laterResetAuthority = transcriptResetAuthorityByFileURL[fileKey].flatMap { authority in
            authority.deletionGeneration == currentDeletionGeneration
                && authority.generation > context.transcriptResetGenerationAtPreparation
                ? authority
                : nil
        }
        #if DEBUG
            if let injected = test_scheduledSendRecoveryFailureInjector?(payload) {
                throw injected
            }
        #endif
        try validateAcceptedScheduledSendEvidence(
            expectedAttempt: payload.attempt,
            acceptedUserItem: payload.acceptedItem,
            receipt: payload.receipt
        )
        if FileManager.default.fileExists(atPath: context.fileURL.path) {
            let session = try await loadAgentSessionLocked(from: context.fileURL)
            let result = try await commitScheduledSendFinalization(
                session: session,
                fileURL: context.fileURL,
                agentSessionsFolder: context.agentSessionsFolderURL,
                expectedUpdatedAt: payload.expectedUpdatedAt,
                expectedAttempt: payload.attempt,
                acceptedUserItem: payload.acceptedItem,
                receipt: payload.receipt,
                suppressAcceptedItem: laterResetAuthority != nil
                    && !sessionContainsItem(session, itemID: payload.attempt.itemID)
            )
            return .committed(result)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context.agentSessionsFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AgentScheduledSendRecoveryError.destinationUnavailable(context.agentSessionsFolderURL)
        }
        let recoverySnapshotData =
            laterResetAuthority?.canonicalSessionSnapshot ?? context.canonicalSessionSnapshot
        var snapshot: AgentSession
        do {
            snapshot = try AgentSessionDataCodec.decodeSession(from: recoverySnapshotData)
        } catch {
            throw AgentScheduledSendRecoveryError.snapshotUndecodable
        }
        if let scheduleAuthority = scheduleAuthorityByFileURL[fileKey] {
            snapshot = sessionByApplyingScheduleAuthority(scheduleAuthority, to: snapshot)
        }
        let result = try await commitScheduledSendFinalization(
            session: snapshot,
            fileURL: context.fileURL,
            agentSessionsFolder: context.agentSessionsFolderURL,
            expectedUpdatedAt: payload.expectedUpdatedAt,
            expectedAttempt: payload.attempt,
            acceptedUserItem: payload.acceptedItem,
            receipt: payload.receipt,
            suppressAcceptedItem: laterResetAuthority != nil
                && !sessionContainsItem(snapshot, itemID: payload.attempt.itemID)
        )
        return .committed(result)
    }

    private func validateAcceptedScheduledSendEvidence(
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) throws {
        guard acceptedUserItem.id == expectedAttempt.itemID else {
            throw AgentScheduledSendMutationError.invalidAcceptedUserItem(
                expectedItemID: expectedAttempt.itemID,
                actualItemID: acceptedUserItem.id
            )
        }
        guard acceptedUserItem.kind == .user else {
            throw AgentScheduledSendMutationError.acceptedItemNotUser(acceptedUserItem.id)
        }
        guard acceptedUserItem.scheduledSend == nil || acceptedUserItem.scheduledSend == receipt,
              receipt.attemptID == expectedAttempt.attemptID
        else {
            throw AgentScheduledSendMutationError.invalidDispatchReceipt
        }
    }

    private func performScheduledSendFinalization(
        sessionID: UUID,
        for workspace: WorkspaceModel,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) async throws -> AgentScheduledSendMutationResult {
        try validateAcceptedScheduledSendEvidence(
            expectedAttempt: expectedAttempt,
            acceptedUserItem: acceptedUserItem,
            receipt: receipt
        )

        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        let session = try await loadAgentSessionLocked(from: fileURL)
        return try await commitScheduledSendFinalization(
            session: session,
            fileURL: fileURL,
            agentSessionsFolder: agentSessionsFolder,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt,
            acceptedUserItem: acceptedUserItem,
            receipt: receipt
        )
    }

    /// Shared, gate-held finalization pipeline for a loaded authoritative session (existing file)
    /// or the canonical reconstruction snapshot (accidentally missing file).
    private func commitScheduledSendFinalization(
        session loadedSession: AgentSession,
        fileURL: URL,
        agentSessionsFolder: URL,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance,
        suppressAcceptedItem: Bool = false
    ) async throws -> AgentScheduledSendMutationResult {
        var stampedItem = acceptedUserItem
        stampedItem.scheduledSend = receipt
        var session = loadedSession
        let fileKey = canonicalSessionFileKey(fileURL)
        var itemAuthorityForCommit = scheduleAuthorityByFileURL[fileKey]
        let exactRemovalWasCommitted =
            itemAuthorityForCommit?
                .intentionallyRemovedAcceptedUserItemReceiptsByID[stampedItem.id] == receipt
        let acceptedItemMustRemainAbsent = exactRemovalWasCommitted || suppressAcceptedItem
        if suppressAcceptedItem, !exactRemovalWasCommitted {
            var authority = itemAuthorityForCommit ?? AgentSessionScheduleAuthority(
                scheduledSend: session.scheduledSend,
                lastScheduledDispatch: session.lastScheduledDispatch,
                protectedAcceptedUserItemsByID: [:],
                intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
            )
            authority.protectedAcceptedUserItemsByID.removeValue(forKey: stampedItem.id)
            authority.intentionallyRemovedAcceptedUserItemReceiptsByID[stampedItem.id] = receipt
            itemAuthorityForCommit = authority
        }
        var shouldRetirePersistedSchedule = false

        switch session.scheduledSend {
        case let .v1(record):
            let matchesAcceptedSchedule = record.id == receipt.scheduleID
            let matchesAcceptedAttempt = record.attempt == expectedAttempt
            if matchesAcceptedSchedule, matchesAcceptedAttempt {
                guard receipt.scheduledFor == record.notBefore else {
                    throw AgentScheduledSendMutationError.invalidDispatchReceipt
                }
                // Internal schedule-state persistence may advance updatedAt after provider
                // acceptance. The immutable attempt, not that mutable revision, identifies
                // the pending work that this persistence-only finalization must retire.
                shouldRetirePersistedSchedule = true
            } else if matchesAcceptedSchedule, record.updatedAt == expectedUpdatedAt {
                throw AgentScheduledSendMutationError.staleExpectedAttempt(
                    expected: expectedAttempt,
                    actual: record.attempt
                )
            }
        // A different schedule or attempt is a genuine successor. Preserve it while
        // completing the accepted predecessor's item and receipt below.
        case nil, .unreadable:
            // A prior partial write, cancellation, or successor from a future schema must
            // not reduce accepted-message recovery to receipt-only success. Complete the
            // durable item and receipt while leaving any unknown member untouched.
            break
        }

        if acceptedItemMustRemainAbsent {
            session = sessionByRemovingIntentionallyRemovedAcceptedUserItems(
                [stampedItem.id: receipt],
                from: session
            )
        } else {
            session = sessionByMergingProtectedAcceptedUserItems(
                [stampedItem.id: stampedItem],
                into: session
            )
        }
        if shouldRetirePersistedSchedule {
            session.scheduledSend = nil
        }
        session.lastScheduledDispatch = receipt
        let sessionToSave = sessionPreparedForStorage(
            session,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: nil
        )
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: JSONEncoder())
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
        rememberScheduleAuthority(
            from: sessionToSave,
            fileURL: fileURL,
            protecting: acceptedItemMustRemainAbsent ? nil : stampedItem,
            preservingItemAuthority: itemAuthorityForCommit
        )

        let indexStatus: AgentScheduledSendMutationResult.MetadataIndexStatus =
            switch await upsertMetadataRecordReporting(
                metadataRecord(from: sessionToSave, fileURL: fileURL),
                folder: agentSessionsFolder
            ) {
            case .success:
                .updated
            case let .failure(error):
                .repairNeeded(String(describing: error))
            }

        return AgentScheduledSendMutationResult(
            session: sessionToSave,
            fileURL: fileURL,
            metadataIndexStatus: indexStatus
        )
    }

    private func acquireSessionPersistence(for sessionID: UUID) async {
        if activeSessionPersistence.insert(sessionID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            sessionPersistenceWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func releaseSessionPersistence(for sessionID: UUID) {
        guard var waiters = sessionPersistenceWaiters[sessionID], !waiters.isEmpty else {
            activeSessionPersistence.remove(sessionID)
            sessionPersistenceWaiters.removeValue(forKey: sessionID)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            sessionPersistenceWaiters.removeValue(forKey: sessionID)
        } else {
            sessionPersistenceWaiters[sessionID] = waiters
        }
        next.resume()
    }

    func renameAgentSession(
        id: UUID,
        to newName: String,
        for workspace: WorkspaceModel
    ) async throws {
        let validatedName = AgentSession.validatedName(newName)
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard var session = try await loadAgentSession(id: id, for: workspace) else { return }
        guard session.name != validatedName else { return }
        session.name = validatedName
        _ = try await saveAgentSession(session, for: workspace)
    }

    func rawLastRunStateForAgentSession(id: UUID, for workspace: WorkspaceModel) async throws -> String? {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: id))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try AgentSessionDataCodec.decodeEnvelope(AgentSessionLastRunStateHeader.self, from: data, using: decoder)
            .value.lastRunState
    }

    /// Loads a session under the same per-session gate used by full saves and schedule CAS.
    func loadAgentSession(from fileURL: URL) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        await acquireSessionPersistence(for: sessionID)
        do {
            let session = try await loadAgentSessionLocked(from: fileURL)
            releaseSessionPersistence(for: sessionID)
            return session
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    private func loadAgentSessionLocked(from fileURL: URL) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let session = try AgentSessionDataCodec.decodeSession(from: data, using: decoder)
            let normalized = normalizeLoadedSession(session, fileURL: fileURL)
            var runtimeSession = normalized.runtimeSession
            var persistedSessionToRewrite = normalized.persistedSessionToRewrite
            let reconciledMergeOperations = await AgentSessionWorktreeMergeReconciler.reconcile(runtimeSession.worktreeMergeOperations)
            if reconciledMergeOperations != runtimeSession.worktreeMergeOperations {
                runtimeSession.worktreeMergeOperations = reconciledMergeOperations
                persistedSessionToRewrite = sessionPreparedForStorage(
                    runtimeSession,
                    fileURL: fileURL,
                    savedAt: session.savedAt,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: runtimeSession.itemCount
                )
            }
            if let persistedSession = persistedSessionToRewrite {
                let encoded = try AgentSessionDataCodec.encodeSession(persistedSession, using: encoder)
                try await writeDataAtomically(encoded, to: fileURL)
                await upsertMetadataRecord(
                    metadataRecord(from: persistedSession, fileURL: fileURL),
                    folder: fileURL.deletingLastPathComponent()
                )
            } else {
                await upsertMetadataRecordIfIndexPresent(runtimeSession, fileURL: fileURL)
            }
            rememberScheduleAuthority(from: runtimeSession, fileURL: fileURL)
            return runtimeSession
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Loads a lightweight stub under the same gate because metadata recovery may rewrite the file.
    func loadAgentSessionStub(
        from fileURL: URL,
        recoverMissingMetadata: Bool = false,
        persistRecoveredMetadata: Bool = false
    ) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        await acquireSessionPersistence(for: sessionID)
        do {
            let session = try await loadAgentSessionStubLocked(
                from: fileURL,
                recoverMissingMetadata: recoverMissingMetadata,
                persistRecoveredMetadata: persistRecoveredMetadata
            )
            releaseSessionPersistence(for: sessionID)
            return session
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    private func loadAgentSessionStubLocked(
        from fileURL: URL,
        recoverMissingMetadata: Bool,
        persistRecoveredMetadata: Bool
    ) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decodedHeader = try AgentSessionDataCodec.decodeEnvelope(AgentSessionHeader.self, from: data, using: decoder)
            let header = decodedHeader.value
            var recoveredLastUserMessageAt = header.lastUserMessageAt
            var recoveredProjectionCounts = header.transcriptProjectionCounts
            var count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? header.itemCount ?? 0

            if recoverMissingMetadata,
               header.lastUserMessageAt == nil || header.itemCount == nil || header.transcriptProjectionCounts == nil,
               let fullSession = try? AgentSessionDataCodec.decodeSession(from: data, using: decoder)
            {
                let normalized = normalizeLoadedSession(fullSession, fileURL: fileURL)
                if let transcript = normalized.runtimeSession.transcript {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? computeLastUserMessageAt(in: transcript)
                    let projectionCounts = computeProjectionCounts(in: transcript)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? projectionCounts
                    if header.itemCount == nil {
                        count = projectionCounts.canonicalVisibleRowCount
                    }
                } else {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? computeLastUserMessageAt(in: normalized.runtimeSession.items)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? .init(
                        canonicalVisibleRowCount: normalized.runtimeSession.items.count,
                        defaultPresentedRowCount: normalized.runtimeSession.items.count
                    )
                    if header.itemCount == nil {
                        count = normalized.runtimeSession.items.count
                    }
                }
                count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? count
                if persistRecoveredMetadata,
                   let persistedSession = normalized.persistedSessionToRewrite
                {
                    do {
                        let encoded = try AgentSessionDataCodec.encodeSession(persistedSession, using: encoder)
                        try await writeDataAtomically(encoded, to: fileURL)
                        await upsertMetadataRecord(
                            metadataRecord(from: persistedSession, fileURL: fileURL),
                            folder: fileURL.deletingLastPathComponent()
                        )
                    } catch {
                        // Best-effort migration only; continue serving recovered values in-memory.
                    }
                }
            }
            let stub = AgentSession(
                id: header.id,
                serializationVersion: header.serializationVersion ?? AgentSession.legacyUnversionedSerializationVersion,
                workspaceID: header.workspaceID,
                composeTabID: header.composeTabID,
                name: header.name,
                savedAt: header.savedAt,
                fileURL: fileURL,
                items: [],
                transcript: nil,
                itemCount: count,
                transcriptProjectionCounts: recoveredProjectionCounts,
                lastUserMessageAt: recoveredLastUserMessageAt,
                agentKind: header.agentKind,
                agentModel: header.agentModel,
                ohMyPiThinkingSelections: header.ohMyPiThinkingSelections,
                agentReasoningEffort: header.agentReasoningEffort,
                lastRunState: AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(header.lastRunState),
                providerSessionID: header.providerSessionID,
                remoteHost: header.remoteHost,
                autoEditEnabled: header.autoEditEnabled,
                providerUsage: decodedHeader.providerUsage,
                codexConversationID: header.codexConversationID,
                codexRolloutPath: header.codexRolloutPath,
                codexModel: header.codexModel,
                codexReasoningEffort: header.codexReasoningEffort,
                codexContextWindow: header.codexContextWindow,
                codexLastTotalTokens: header.codexLastTotalTokens,
                codexTotalTotalTokens: header.codexTotalTotalTokens,
                codexMcpSessionKey: header.codexMcpSessionKey,
                parentSessionID: header.parentSessionID,
                pendingHandoffPayload: header.pendingHandoffPayload,
                pendingHandoffCreatedAt: header.pendingHandoffCreatedAt,
                pendingHandoffSourceItemID: header.pendingHandoffSourceItemID,
                pendingHandoffDefersProviderLockUntilSend: header.pendingHandoffDefersProviderLockUntilSend ?? false,
                scheduledSend: header.scheduledSend,
                lastScheduledDispatch: header.lastScheduledDispatch,
                isMCPOriginated: header.isMCPOriginated ?? false,
                origin: header.origin,
                profile: header.profile ?? .standard,
                worktreeBindings: header.worktreeBindings ?? [],
                worktreeMergeOperations: header.worktreeMergeOperations ?? []
            )
            rememberScheduleAuthority(from: stub, fileURL: fileURL)
            return stub
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Returns a list of AgentSession files in the workspace's AgentSessions folder, sorted by mod date desc.
    func listAgentSessions(for workspace: WorkspaceModel) async throws -> [URL] {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)

        let contents = try FileManager.default.contentsOfDirectory(
            at: agentSessionsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let jsonFiles = contents.filter {
            agentSessionID(fromFilename: $0.lastPathComponent) != nil
        }

        let datedFiles = jsonFiles.map { url in
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url: url, modificationDate: modificationDate)
        }
        return datedFiles.sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }.map(\.url)
    }

    /// Get metadata for recent agent sessions without loading full content.
    func recentSessions(for workspace: WorkspaceModel, limit: Int = 10) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            var metadataList: [AgentSessionMeta] = []

            for fileURL in files.prefix(max(limit, 0)) {
                do {
                    let session = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? session.savedAt

                    let meta = AgentSessionMeta(
                        id: session.id,
                        composeTabID: session.composeTabID,
                        name: session.name,
                        lastModified: lastModified,
                        itemCount: session.effectiveItemCount,
                        agentKind: session.agentKind,
                        agentModel: session.agentModel,
                        lastRunState: session.lastRunState,
                        parentSessionID: session.parentSessionID,
                        remoteHostID: session.remoteHost?.hostID,
                        remoteHostName: session.remoteHost?.hostDisplayName,
                        remoteSessionID: session.remoteHost?.normalizedRemoteSessionID,
                        isMCPOriginated: session.isMCPOriginated,
                        origin: session.origin,
                        worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                        activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                    )
                    metadataList.append(meta)
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Get lightweight metadata for agent sessions without loading full transcript content.
    func listAgentSessionsMeta(
        for workspace: WorkspaceModel,
        limit: Int? = nil
    ) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            let boundedFiles: ArraySlice<URL> = if let limit {
                files.prefix(max(limit, 0))
            } else {
                files[...]
            }

            var metadataList: [AgentSessionMeta] = []
            metadataList.reserveCapacity(boundedFiles.count)

            for fileURL in boundedFiles {
                do {
                    let session = try await loadAgentSessionStub(
                        from: fileURL,
                        recoverMissingMetadata: false,
                        persistRecoveredMetadata: false
                    )
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ?? session.savedAt
                    metadataList.append(
                        AgentSessionMeta(
                            id: session.id,
                            composeTabID: session.composeTabID,
                            name: session.name,
                            lastModified: lastModified,
                            itemCount: session.effectiveItemCount,
                            agentKind: session.agentKind,
                            agentModel: session.agentModel,
                            lastRunState: session.lastRunState,
                            parentSessionID: session.parentSessionID,
                            remoteHostID: session.remoteHost?.hostID,
                            remoteHostName: session.remoteHost?.hostDisplayName,
                            remoteSessionID: session.remoteHost?.normalizedRemoteSessionID,
                            isMCPOriginated: session.isMCPOriginated,
                            origin: session.origin,
                            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                        )
                    )
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Resolves a session reference (UUID string only) to a session ID.
    func resolveAgentSessionID(
        reference: String,
        for workspace: WorkspaceModel
    ) async throws -> UUID? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return try await loadAgentSession(id: uuid, for: workspace) != nil ? uuid : nil
    }

    func loadAgentSession(
        reference: String,
        for workspace: WorkspaceModel
    ) async throws -> AgentSession? {
        guard let sessionID = try await resolveAgentSessionID(reference: reference, for: workspace) else {
            return nil
        }
        return try await loadAgentSession(id: sessionID, for: workspace)
    }

    /// Find an agent session by its ID for a workspace.
    func findAgentSession(id: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            let filename = fileURL.lastPathComponent
            if filename == "AgentSession-\(id.uuidString).json" {
                return try await loadAgentSession(from: fileURL)
            }
        }

        return nil
    }

    /// Load an agent session by ID without scanning the session directory.
    func loadAgentSession(id: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let filename = "AgentSession-\(id.uuidString).json"
        let fileURL = agentSessionsFolder.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try await loadAgentSession(from: fileURL)
    }

    /// Find an agent session by compose tab ID.
    func findAgentSessionForTab(_ tabID: UUID, for workspace: WorkspaceModel) async throws -> AgentSession? {
        if let records = try? await metadataRecords(for: workspace),
           let best = records
           .filter({ $0.composeTabID == tabID })
           .sortedForAgentSessionMetadataIndex()
           .first
        {
            if let session = try await loadAgentSession(id: best.id, for: workspace) {
                return session
            }
            let folder = try ensureAgentSessionsFolder(for: workspace)
            await removeMetadataRecords(matching: { $0.id == best.id }, folder: folder)
        }

        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            do {
                let stub = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                if stub.composeTabID == tabID {
                    return try await loadAgentSession(from: fileURL)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Delete a particular agent session file under the same per-session gate as saves and CAS.
    func deleteAgentSessionFile(_ fileURL: URL) async throws {
        guard let sessionID = agentSessionID(fromFilename: fileURL.lastPathComponent) else {
            try await deleteAgentSessionFileLocked(fileURL)
            return
        }
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        try await deleteAgentSessionFileLocked(fileURL)
    }

    private func deleteAgentSessionFileLocked(_ fileURL: URL) async throws {
        let folder = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        let parsedID = agentSessionID(fromFilename: filename)
        let fileKey = canonicalSessionFileKey(fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            #if DEBUG
                if let injected = test_agentSessionDeletionFailureInjector?(fileURL) {
                    throw injected
                }
            #endif
            try FileManager.default.removeItem(at: fileURL)
        }

        // Publish committed deletion authority only after unlink succeeds (or the file was already
        // absent). This remains synchronous under the per-session gate with no suspension window.
        scheduleAuthorityByFileURL.removeValue(forKey: fileKey)
        transcriptResetAuthorityByFileURL.removeValue(forKey: fileKey)
        let generation = (deletionGenerationsByFileKey[fileKey] ?? 0) &+ 1
        deletionGenerationsByFileKey[fileKey] = generation
        await removeMetadataRecords(
            matching: { record in
                record.filename == filename || parsedID.map { record.id == $0 } == true
            },
            folder: folder
        )
        var userInfo: [String: Any] = ["fileKey": fileKey, "generation": generation]
        if let parsedID {
            userInfo["sessionID"] = parsedID
        }
        NotificationCenter.default.post(name: .agentSessionDeletionDidCommit, object: nil, userInfo: userInfo)
    }

    /// Current explicit-deletion generation for a session file (0 when never deleted).
    func scheduledSendDeletionGeneration(for fileURL: URL) -> UInt64 {
        deletionGenerationsByFileKey[canonicalSessionFileKey(fileURL)] ?? 0
    }

    /// Delete an agent session by ID under the same per-session gate as saves and CAS.
    func deleteAgentSession(id: UUID, for workspace: WorkspaceModel) async throws {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: id))
        try await deleteAgentSessionFile(fileURL)
    }

    func deletionCandidates(
        forComposeTabID tabID: UUID,
        for workspace: WorkspaceModel
    ) async throws -> [AgentSessionDeletionCandidate] {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        var candidateFilesByPath: [String: URL] = [:]
        if let index = await readMetadataIndexIfAvailable(folder: agentSessionsFolder) {
            for record in index.entries where record.composeTabID == tabID {
                let fileURL = agentSessionsFolder.appendingPathComponent(record.filename)
                candidateFilesByPath[fileURL.path] = fileURL
            }
        }

        let files = try await listAgentSessions(for: workspace)
        for fileURL in files {
            guard
                let stub = try? await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                ),
                stub.composeTabID == tabID
            else { continue }
            candidateFilesByPath[fileURL.path] = fileURL
        }

        return candidateFilesByPath.values.compactMap { fileURL in
            guard let sessionID = agentSessionID(fromFilename: fileURL.lastPathComponent) else {
                return nil
            }
            return AgentSessionDeletionCandidate(
                composeTabID: tabID,
                persistenceState: persistenceState(
                    sessionID: sessionID,
                    workspaceID: workspace.id,
                    fileURL: fileURL
                )
            )
        }
    }

    func deleteAgentSession(
        ifCurrent candidate: AgentSessionDeletionCandidate,
        for workspace: WorkspaceModel
    ) async throws -> AgentSessionConditionalDeletionResult {
        let state = candidate.persistenceState
        let sessionID = state.stamp.sessionID
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        #if DEBUG
            if let testConditionalDeletionHook {
                try await testConditionalDeletionHook(candidate)
            }
        #endif
        try validatePersistenceStamp(
            state.stamp,
            sessionID: sessionID,
            workspaceID: workspace.id
        )
        let fileURL = state.stamp.fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try await deleteAgentSessionFileLocked(fileURL)
            return .alreadyAbsent
        }
        guard
            let stub = try? await loadAgentSessionStubLocked(
                from: fileURL,
                recoverMissingMetadata: false,
                persistRecoveredMetadata: false
            ),
            stub.id == sessionID,
            stub.composeTabID == candidate.composeTabID
        else {
            return .ownershipChanged
        }
        try await deleteAgentSessionFileLocked(fileURL)
        return .deleted
    }

    func deleteAgentSessions(forComposeTabID tabID: UUID, for workspace: WorkspaceModel) async throws {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        var candidateFilesByPath: [String: URL] = [:]
        if let index = await readMetadataIndexIfAvailable(folder: agentSessionsFolder) {
            for record in index.entries where record.composeTabID == tabID {
                candidateFilesByPath[agentSessionsFolder.appendingPathComponent(record.filename).path] = agentSessionsFolder.appendingPathComponent(record.filename)
            }
        }

        let files = try await listAgentSessions(for: workspace)
        for fileURL in files {
            guard
                let stub = try? await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                ),
                stub.composeTabID == tabID
            else { continue }
            candidateFilesByPath[fileURL.path] = fileURL
        }

        for fileURL in candidateFilesByPath.values {
            try? await deleteAgentSessionFile(fileURL)
        }
        await removeMetadataRecords(matching: { $0.composeTabID == tabID }, folder: agentSessionsFolder)
    }

    #if DEBUG
        func test_clearMetadataIndexCache(forAgentSessionsFolder folder: URL) {
            let key = canonicalMetadataFolderKey(folder)
            metadataIndexCacheByFolder.removeValue(forKey: key)
            metadataIndexReconciliationTasksByFolder[key]?.task.cancel()
            metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            metadataIndexReconciledThisProcess.remove(key)
        }

        func test_markMetadataIndexReconciledThisProcess(forAgentSessionsFolder folder: URL) {
            metadataIndexReconciledThisProcess.insert(canonicalMetadataFolderKey(folder))
        }

        func test_cachedMetadataIndexEntryCount(forAgentSessionsFolder folder: URL) -> Int? {
            metadataIndexCacheByFolder[canonicalMetadataFolderKey(folder)]?.entries.count
        }

        func test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder folder: URL) -> Bool {
            metadataIndexReconciliationTasksByFolder[canonicalMetadataFolderKey(folder)] != nil
        }
    #endif

    // MARK: - Folder Helpers

    /// Creates (if needed) and returns the "AgentSessions" subfolder for the given workspace.
    private func ensureAgentSessionsFolder(for workspace: WorkspaceModel) throws -> URL {
        let baseFolder = try workspaceFolderURL(for: workspace)
        let agentSessionsFolder = baseFolder.appendingPathComponent("AgentSessions")

        if !FileManager.default.fileExists(atPath: agentSessionsFolder.path) {
            try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        }
        return agentSessionsFolder
    }

    /// Return the main folder for the workspace (with custom or default path).
    private func workspaceFolderURL(for workspace: WorkspaceModel) throws -> URL {
        if let customURL = workspace.customStoragePath {
            return customURL
        } else {
            let root = MCPFilesystemConstants.identity.applicationSupportRootURL()
                .appendingPathComponent("Workspaces", isDirectory: true)
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let folderName = WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id)
            let workspaceDir = root.appendingPathComponent(folderName)
            if !FileManager.default.fileExists(atPath: workspaceDir.path) {
                try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            }
            return workspaceDir
        }
    }
}
