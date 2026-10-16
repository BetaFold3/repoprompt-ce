import Foundation
import RepoPromptWorkspace

package struct AgentSessionIndexEntry: Identifiable, Equatable {
    package let id: UUID
    package let tabID: UUID
    package var name: String
    package var lastUserMessageAt: Date?
    package var savedAt: Date
    package var lastRunStateRaw: String?
    package var itemCount: Int
    package var agentKindRaw: String?
    package var agentModelRaw: String?
    package var agentReasoningEffortRaw: String?
    package var autoEditEnabled: Bool
    package var parentSessionID: UUID?
    package var hasUnknownConversationContent: Bool
    package var remoteHostID: String?
    package var remoteHostName: String?
    package var remoteSessionID: String?
    package var isMCPOriginated: Bool
    /// Session provenance (plan §6.4); `nil` for entries built from legacy
    /// records that only carried `isMCPOriginated`.
    package var origin: AgentSessionOrigin?
    package var profile: AgentSessionProfile = .standard
    package var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    package var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
    /// Pending scheduled-send discovery hint. Counts as conversation content for sidebar
    /// visibility and titling; the coordinator revalidates it against the hydrated record.
    package var scheduledSendSummary: AgentSessionScheduledSendSummary?
    package var lastScheduledDispatch: AgentScheduledSendProvenance?

    package init(
        id: UUID,
        tabID: UUID,
        name: String,
        lastUserMessageAt: Date? = nil,
        savedAt: Date,
        lastRunStateRaw: String? = nil,
        itemCount: Int,
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        agentReasoningEffortRaw: String? = nil,
        autoEditEnabled: Bool,
        parentSessionID: UUID? = nil,
        hasUnknownConversationContent: Bool,
        remoteHostID: String? = nil,
        remoteHostName: String? = nil,
        remoteSessionID: String? = nil,
        isMCPOriginated: Bool,
        origin: AgentSessionOrigin? = nil,
        profile: AgentSessionProfile = .standard,
        worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary],
        activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary],
        scheduledSendSummary: AgentSessionScheduledSendSummary? = nil,
        lastScheduledDispatch: AgentScheduledSendProvenance? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.name = name
        self.lastUserMessageAt = lastUserMessageAt
        self.savedAt = savedAt
        self.lastRunStateRaw = lastRunStateRaw
        self.itemCount = itemCount
        self.agentKindRaw = agentKindRaw
        self.agentModelRaw = agentModelRaw
        self.agentReasoningEffortRaw = agentReasoningEffortRaw
        self.autoEditEnabled = autoEditEnabled
        self.parentSessionID = parentSessionID
        self.hasUnknownConversationContent = hasUnknownConversationContent
        self.remoteHostID = remoteHostID
        self.remoteHostName = remoteHostName
        self.remoteSessionID = remoteSessionID
        self.isMCPOriginated = isMCPOriginated
        self.origin = origin
        self.profile = profile
        self.worktreeBindingSummaries = worktreeBindingSummaries
        self.activeWorktreeMergeSummaries = activeWorktreeMergeSummaries
        self.scheduledSendSummary = scheduledSendSummary
        self.lastScheduledDispatch = lastScheduledDispatch
    }

    var hasUnreadableScheduledSend: Bool {
        scheduledSendSummary?.isUnreadable == true
    }
}

package enum AgentSidebarScheduledSendStatus: Equatable {
    case pending(Date?)
    case dispatching(Date?)
    case needsConfirmation(Date?)
    case failed(Date?)
    case unreadable
    case sent(AgentScheduledSendProvenance)

    package init?(summary: AgentSessionScheduledSendSummary?, lastDispatch: AgentScheduledSendProvenance?) {
        if let summary {
            if summary.isUnreadable {
                self = .unreadable
                return
            }
            switch summary.stateRaw.flatMap(AgentScheduledSendPersist.State.init(rawValue:)) ?? .needsConfirmation {
            case .scheduled:
                self = .pending(summary.notBefore)
            case .dispatching:
                self = .dispatching(summary.notBefore)
            case .needsConfirmation:
                self = .needsConfirmation(summary.notBefore)
            case .failed:
                self = .failed(summary.notBefore)
            }
            return
        }
        guard let lastDispatch else { return nil }
        self = .sent(lastDispatch)
    }
}

package struct AgentSessionSidebarBuildRequest {
    let workspace: any AgentWorkspaceStorageReference
    let tabNameByID: [UUID: String]
    let validTabIDs: Set<UUID>
    let boundSessionIDByTabID: [UUID: UUID]
    let prioritizedTabID: UUID?

    package init(
        workspace: any AgentWorkspaceStorageReference,
        tabNameByID: [UUID: String],
        validTabIDs: Set<UUID>,
        boundSessionIDByTabID: [UUID: UUID] = [:],
        prioritizedTabID: UUID? = nil
    ) {
        self.workspace = workspace
        self.tabNameByID = tabNameByID
        self.validTabIDs = validTabIDs
        self.boundSessionIDByTabID = boundSessionIDByTabID
        self.prioritizedTabID = prioritizedTabID
    }
}

package struct AgentSessionSidebarBuildBatch {
    package let entriesBySessionID: [UUID: AgentSessionIndexEntry]
    package let preferredSessionIDByTabID: [UUID: UUID]

    package init(
        entriesBySessionID: [UUID: AgentSessionIndexEntry],
        preferredSessionIDByTabID: [UUID: UUID]
    ) {
        self.entriesBySessionID = entriesBySessionID
        self.preferredSessionIDByTabID = preferredSessionIDByTabID
    }
}

package struct AgentSessionSidebarBuildResult {
    package let entriesBySessionID: [UUID: AgentSessionIndexEntry]
    package let preferredSessionIDByTabID: [UUID: UUID]
}

package struct AgentSessionHydrationRequest {
    package let workspace: any AgentWorkspaceStorageReference
    package let tabID: UUID
    package let sessionID: UUID
    package let resolvedDisplayName: String
    package let hasPendingQuestionUI: Bool
    package let transcriptViewportState: AgentTranscriptViewportState
    package let isCompressedHistoryRevealed: Bool
    package let initialPerformanceSnapshot: AgentTranscriptPerformanceSnapshot

    package init(
        workspace: any AgentWorkspaceStorageReference,
        tabID: UUID,
        sessionID: UUID,
        resolvedDisplayName: String,
        hasPendingQuestionUI: Bool,
        transcriptViewportState: AgentTranscriptViewportState,
        isCompressedHistoryRevealed: Bool,
        initialPerformanceSnapshot: AgentTranscriptPerformanceSnapshot
    ) {
        self.workspace = workspace
        self.tabID = tabID
        self.sessionID = sessionID
        self.resolvedDisplayName = resolvedDisplayName
        self.hasPendingQuestionUI = hasPendingQuestionUI
        self.transcriptViewportState = transcriptViewportState
        self.isCompressedHistoryRevealed = isCompressedHistoryRevealed
        self.initialPerformanceSnapshot = initialPerformanceSnapshot
    }
}

package struct AgentSessionHydrationPayload {
    package let sessionID: UUID
    package let persistedSession: AgentSession
    /// Service-issued lifetime/reset state issued by the same gate-held load that produced
    /// `persistedSession`; the owner adopts both together.
    package let persistenceState: AgentSessionPersistenceState
    package let canonicalLiveItems: [AgentChatItem]
    package let transcript: AgentTranscript
    package let builtPresentation: AgentBuiltTranscriptPresentation
    package let normalizedRunState: AgentSessionRunState
    package let normalizedSelection: AgentModelCatalog.NormalizedAgentSelection
    package let lastUserMessageAt: Date?
    package let restoredIndexEntry: AgentSessionIndexEntry
    package let needsReloadMigrationSave: Bool
}
