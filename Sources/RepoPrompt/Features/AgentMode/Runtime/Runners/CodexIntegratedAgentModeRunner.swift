import Foundation

@MainActor
final class CodexIntegratedAgentModeRunner {
    private let mcpServerEnabler: AgentModeViewModel.MCPServerEnabler
    private let codexCoordinator: CodexAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks

    init(
        mcpServerEnabler: @escaping AgentModeViewModel.MCPServerEnabler,
        codexCoordinator: CodexAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks
    ) {
        self.mcpServerEnabler = mcpServerEnabler
        self.codexCoordinator = codexCoordinator
        self.hooks = hooks
    }

    func startRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentModeViewModel.TabSession.CodexFallbackSubmissionContext?,
        delegatedQuestionStageID: UUID? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        let ownership: AgentRunOwnership
        let createdOwnership: Bool
        if let activeOwnership = session.activeRunOwnership {
            ownership = activeOwnership
            createdOwnership = false
        } else {
            ownership = session.beginRunAttempt(source: "codex")
            createdOwnership = true
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        }
        let attemptGeneration = session.runAttemptGeneration
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
            guard let self, let session else {
                return .cancelled
            }
            defer {
                // A send outliving Stop must not clear a successor run's task handle.
                if !Self.isSupersededBySuccessor(ownership, attemptGeneration: attemptGeneration, session: session) {
                    session.agentTask = nil
                }
            }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            await mcpServerEnabler()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif

            let outcome = await codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: initialMessageForRun,
                attachments: attachments,
                fallbackContext: fallbackContext,
                attachmentReservationID: attachmentReservationID,
                terminalizeRejectedSend: createdOwnership
            )
            // The pending handoff is tab-wide; a superseded send leaves the successor's staging alone.
            if !Self.isSupersededBySuccessor(ownership, attemptGeneration: attemptGeneration, session: session) {
                hooks.recordPendingHandoffSendOutcome(session, outcome.didSend)
            }
            // Delegated child-question notices acknowledge only on an actual send. A queued
            // fallback (`didSend == true`) has not reached the model yet, so its stage is released
            // and the notices stay deliverable; the release also removes the stage's runtime
            // block from the queued fallback text, so only a later delivery carries them.
            let delegatedQuestionNoticesSent = if case .sent = outcome { true } else { false }
            hooks.recordDelegatedQuestionNoticeSendOutcome(
                session,
                delegatedQuestionStageID,
                delegatedQuestionNoticesSent
            )
            switch outcome {
            case .sent:
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            case .cancelled, .failed, .stale:
                if createdOwnership {
                    session.endRunAttempt(ifCurrent: ownership, source: "codex.sendRejected")
                }
            case .queuedFallback:
                break
            }
            return outcome
        }
        session.agentTask = Task {
            await withTaskCancellationHandler {
                _ = await sendTask.value
            } onCancel: {
                sendTask.cancel()
            }
        }
        return await sendTask.value
    }

    /// True once a later run attempt took the tab (Stop, then a new send, while this send was still
    /// starting), whether that attempt still owns the tab or has already ended and released it.
    private static func isSupersededBySuccessor(
        _ ownership: AgentRunOwnership,
        attemptGeneration: UInt64,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        if session.runAttemptGeneration != attemptGeneration {
            return true
        }
        guard let currentOwnership = session.activeRunOwnership else { return false }
        return currentOwnership != ownership
    }
}
