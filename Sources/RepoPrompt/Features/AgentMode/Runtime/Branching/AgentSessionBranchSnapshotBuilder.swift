import Foundation

enum AgentSessionBranchSnapshotBuilder {
    static func codexChild(
        source: AgentSession,
        prefixedSource: AgentSession,
        workspaceID: UUID,
        childID: UUID,
        childThreadID: String,
        childRolloutPath: String?,
        childLedger: CodexTurnCheckpointLedger,
        childModel: String?,
        childReasoningEffort: String?,
        sourceTurnID: UUID,
        sourceNativeTurnRef: String,
        sourceTurnOrdinal: Int,
        createdAt: Date = Date()
    ) -> AgentSession {
        let rootID = source.branchOrigin?.rootSessionID ?? source.id
        return AgentSession(
            id: childID,
            workspaceID: workspaceID,
            composeTabID: nil,
            name: "\(source.name) (branch)",
            items: prefixedSource.items,
            uiToolResultPayloadsByItemID: prefixedSource.uiToolResultPayloadsByItemID,
            transcript: prefixedSource.transcript,
            itemCount: prefixedSource.itemCount,
            transcriptProjectionCounts: prefixedSource.transcriptProjectionCounts,
            lastUserMessageAt: prefixedSource.lastUserMessageAt,
            agentKind: AgentProviderKind.codexExec.rawValue,
            agentModel: source.agentModel,
            ohMyPiThinkingSelections: source.ohMyPiThinkingSelections,
            agentReasoningEffort: source.agentReasoningEffort,
            lastRunState: AgentSessionRunState.idle.rawValue,
            autoEditEnabled: source.autoEditEnabled,
            providerTokenUsageByTurn: prefixedSource.providerTokenUsageByTurn,
            codexConversationID: childThreadID,
            codexRolloutPath: childRolloutPath,
            codexTurnCheckpoints: childLedger,
            codexModel: childModel ?? source.codexModel,
            codexReasoningEffort: childReasoningEffort ?? source.codexReasoningEffort,
            branchOrigin: AgentSessionBranchOrigin(
                rootSessionID: rootID,
                sourceSessionID: source.id,
                sourceTurnID: sourceTurnID,
                sourceNativeTurnRef: sourceNativeTurnRef,
                sourceProviderKind: AgentProviderKind.codexExec.rawValue,
                sourceTurnOrdinal: sourceTurnOrdinal,
                createdAt: createdAt
            ),
            parentSessionID: nil,
            isMCPOriginated: false,
            origin: .user,
            profile: source.profile
        )
    }
}
