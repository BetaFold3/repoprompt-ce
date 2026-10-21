import Foundation

/// Builds the durable pending-question snapshots of one session for shutdown preparation (spec R4).
///
/// Only display data and non-secret partial answers are captured: never a continuation, request
/// routing, provider identity, or anything typed or selected for a secret question. A non-empty
/// secret answer cannot be preserved, so it is reported for the caller to veto Stage A while the
/// live question stays usable.
package enum AgentRecoveryQuestionSnapshotBuilder {
    package struct Capture: Equatable {
        package let snapshots: [AgentRecoveryQuestionSnapshot]
        /// A secret question holds a non-empty answer or selection that shutdown would lose.
        package let hasUnsavableSecretAnswer: Bool
    }

    @MainActor
    package static func capture(
        session: AgentTabSession,
        appInstanceID: UUID,
        transcriptResetGeneration: UInt64
    ) -> Capture {
        let runAttemptID = session.activeRunAttemptID
        var snapshots: [AgentRecoveryQuestionSnapshot] = []
        var hasUnsavableSecretAnswer = false

        if let pending = session.pendingAskUser {
            let interaction = pending.interaction
            snapshots.append(AgentRecoveryQuestionSnapshot(
                interactionID: interaction.id,
                kind: .askUser,
                runAttemptID: runAttemptID,
                transcriptResetGeneration: transcriptResetGeneration,
                appInstanceID: appInstanceID,
                askedAt: AgentRecoveryTimestamp(interaction.askedAt),
                title: interaction.title,
                message: interaction.context,
                items: interaction.questions.map { question in
                    AgentRecoveryQuestionItem(
                        questionID: question.id,
                        header: question.header,
                        text: question.question,
                        options: question.optionLabels,
                        isSecret: false,
                        answer: pending.draftsByQuestionID[question.id].flatMap(askUserAnswerText)
                    )
                }
            ))
        }

        let liveDrafts = session.pendingUserInputDrafts
        let userInputRequests = [session.pendingUserInputRequest].compactMap(\.self) + session.queuedUserInputRequests
        for request in userInputRequests {
            let drafts = liveDrafts?.requestID == request.id ? liveDrafts?.draftsByQuestionID ?? [:] : [:]
            var items: [AgentRecoveryQuestionItem] = []
            for question in request.questions {
                let draft = drafts[question.id]
                if question.isSecret {
                    if draft?.hasContent == true { hasUnsavableSecretAnswer = true }
                    items.append(AgentRecoveryQuestionItem(
                        questionID: question.id,
                        header: question.header,
                        text: question.question,
                        options: question.options.map(\.label),
                        isSecret: true,
                        answer: nil
                    ))
                } else {
                    items.append(AgentRecoveryQuestionItem(
                        questionID: question.id,
                        header: question.header,
                        text: question.question,
                        options: question.options.map(\.label),
                        isSecret: false,
                        answer: draft.flatMap { userInputAnswerText($0, question: question) }
                    ))
                }
            }
            snapshots.append(AgentRecoveryQuestionSnapshot(
                interactionID: request.id,
                kind: .userInput,
                runAttemptID: runAttemptID,
                transcriptResetGeneration: transcriptResetGeneration,
                appInstanceID: appInstanceID,
                askedAt: AgentRecoveryTimestamp(request.askedAt),
                title: nil,
                message: nil,
                items: items
            ))
        }

        let elicitations = [session.pendingMCPElicitationRequest].compactMap(\.self) + session.queuedMCPElicitationRequests
        for request in elicitations {
            snapshots.append(AgentRecoveryQuestionSnapshot(
                interactionID: request.id,
                kind: .elicitation,
                runAttemptID: runAttemptID,
                transcriptResetGeneration: transcriptResetGeneration,
                appInstanceID: appInstanceID,
                askedAt: AgentRecoveryTimestamp(Date()),
                title: request.title,
                message: request.message ?? request.prompt,
                items: []
            ))
        }
        return Capture(snapshots: snapshots, hasUnsavableSecretAnswer: hasUnsavableSecretAnswer)
    }

    static func askUserAnswerText(_ draft: AgentAskUserDraft) -> String? {
        guard !draft.skipped else { return nil }
        var parts = draft.selectedOptionLabels
        let custom = draft.customResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func userInputAnswerText(
        _ draft: AgentRequestUserInputQuestionDraft,
        question: AgentRequestUserInputQuestion
    ) -> String? {
        guard !question.isSecret else { return nil }
        var parts: [String] = []
        if let index = draft.selectedOptionIndex {
            if question.options.indices.contains(index) {
                parts.append(question.options[index].label)
            } else if index == question.options.count, question.isOtherOptionEnabled {
                parts.append(AgentRequestUserInputQuestion.otherOptionLabel)
            }
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
