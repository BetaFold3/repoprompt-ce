import SwiftUI

struct AgentReplyBranchPresentation: Equatable {
    enum OmittedTurnImpact: Equatable {
        case readOnly
        case modified(paths: [String])
        case unknown
    }

    let turnID: UUID
    let availability: AgentSessionBranchAvailability
    let retainedTurnCount: Int
    let omittedTurnCount: Int
    let omittedTurnImpact: OmittedTurnImpact
    let sourceOwnedOracleChatCount: Int
    let isOperationInProgress: Bool
    let hasResolvedTranscriptTurn: Bool

    static func isEligibleBlock(_ kind: AgentTranscriptRenderBlockKind) -> Bool {
        kind == .conclusion
    }

    init(
        turnID: UUID,
        availability: AgentSessionBranchAvailability,
        isOperationInProgress: Bool
    ) {
        self.turnID = turnID
        self.availability = availability
        retainedTurnCount = 0
        omittedTurnCount = 0
        omittedTurnImpact = .unknown
        sourceOwnedOracleChatCount = 0
        self.isOperationInProgress = isOperationInProgress
        hasResolvedTranscriptTurn = false
    }

    init(
        turnID: UUID,
        availability: AgentSessionBranchAvailability,
        transcriptTurnIDs: [UUID],
        ledger: CodexTurnCheckpointLedger?,
        sourceOwnedOracleChatCount: Int = 0,
        isOperationInProgress: Bool
    ) {
        self.turnID = turnID
        self.availability = availability
        self.sourceOwnedOracleChatCount = max(0, sourceOwnedOracleChatCount)
        self.isOperationInProgress = isOperationInProgress

        var selectedIndex: Int?
        for (index, transcriptTurnID) in transcriptTurnIDs.enumerated() where transcriptTurnID == turnID {
            guard selectedIndex == nil else {
                retainedTurnCount = 0
                omittedTurnCount = 0
                omittedTurnImpact = .unknown
                hasResolvedTranscriptTurn = false
                return
            }
            selectedIndex = index
        }
        guard let selectedIndex else {
            retainedTurnCount = 0
            omittedTurnCount = 0
            omittedTurnImpact = .unknown
            hasResolvedTranscriptTurn = false
            return
        }

        hasResolvedTranscriptTurn = true
        retainedTurnCount = selectedIndex + 1
        let omittedTurnIDs = transcriptTurnIDs.dropFirst(selectedIndex + 1)
        omittedTurnCount = omittedTurnIDs.count
        omittedTurnImpact = Self.impact(of: omittedTurnIDs, ledger: ledger)
    }

    var isAvailable: Bool {
        guard case .available = availability else { return false }
        return !isOperationInProgress
    }

    var canPresentConfirmation: Bool {
        isAvailable && hasResolvedTranscriptTurn
    }

    var disabledHelpText: String? {
        if isOperationInProgress {
            return "Finish the pending operation before branching."
        }
        guard case let .unavailable(reason) = availability else { return nil }
        switch reason {
        case .noCheckpoint, .turnNotCompleted, .threadMismatch:
            return "No native checkpoint was recorded for this turn."
        case .beforeCompaction:
            return "Codex compacted this conversation after this checkpoint."
        case .notIdle, .operationInProgress, .pendingHandoff:
            return "Finish the pending operation before branching."
        case .providerUnsupported, .remoteSession, .mcpOriginated, .childSession, .worktreeBound:
            return "Native branching is currently available only for local Codex sessions."
        }
    }

    var confirmationTitle: String {
        "Branch from this reply?"
    }

    var confirmationBody: String {
        guard hasResolvedTranscriptTurn else {
            return "This branch confirmation is stale. Cancel and reopen it."
        }
        let base = "Keeps turns 1–\(retainedTurnCount). Sets aside \(omittedTurnCount) later turn(s) on this branch: \(impactDescription). Anything they changed on disk stays changed. Files, Git state, and workspace selections are not rolled back. The current path stays available in the branch menu."
        guard sourceOwnedOracleChatCount > 0 else { return base }
        let disclosure = if sourceOwnedOracleChatCount == 1 {
            "1 Oracle chat stays with the original path — this branch can read its results but must start a new chat to continue."
        } else {
            "\(sourceOwnedOracleChatCount) Oracle chats stay with the original path — this branch can read their results but must start new chats to continue."
        }
        return "\(base) \(disclosure)"
    }

    var confirmationButtonTitle: String {
        switch omittedTurnImpact {
        case .readOnly: "Branch"
        case .modified, .unknown: "Branch anyway"
        }
    }

    private var impactDescription: String {
        switch omittedTurnImpact {
        case .readOnly:
            return "Read-only exploration"
        case let .modified(paths):
            let displayedPaths = paths.prefix(8)
            let overflowCount = paths.count - displayedPaths.count
            let suffix = overflowCount > 0 ? ", and \(overflowCount) more" : ""
            return "Changed files: \(displayedPaths.joined(separator: ", "))\(suffix)"
        case .unknown:
            return "May have changed files"
        }
    }

    private static func impact(
        of turnIDs: ArraySlice<UUID>,
        ledger: CodexTurnCheckpointLedger?
    ) -> OmittedTurnImpact {
        guard let ledger else {
            return turnIDs.isEmpty ? .readOnly : .unknown
        }
        var checkpointByTurnID: [UUID: CodexTurnCheckpoint] = [:]
        var duplicateTurnIDs = Set<UUID>()
        checkpointByTurnID.reserveCapacity(ledger.entries.count)
        for checkpoint in ledger.entries {
            if checkpointByTurnID.updateValue(checkpoint, forKey: checkpoint.turnID) != nil {
                duplicateTurnIDs.insert(checkpoint.turnID)
            }
        }

        var modifiedPaths: [String] = []
        var seenPaths = Set<String>()
        for turnID in turnIDs {
            guard !duplicateTurnIDs.contains(turnID),
                  let checkpoint = checkpointByTurnID[turnID],
                  checkpoint.status == .completed,
                  let sideEffect = checkpoint.sideEffect
            else {
                return .unknown
            }
            switch sideEffect {
            case .readOnly:
                continue
            case .unknown:
                return .unknown
            case let .modified(paths):
                for path in paths where seenPaths.insert(path).inserted {
                    modifiedPaths.append(path)
                }
            }
        }
        return modifiedPaths.isEmpty ? .readOnly : .modified(paths: modifiedPaths)
    }
}

struct AgentReplyBranchConfig {
    let presentation: AgentReplyBranchPresentation
    let requestPresentation: @MainActor () -> Void
}

@MainActor
struct AgentReplyBranchControl: View {
    let config: AgentReplyBranchConfig

    var body: some View {
        Button("Branch from here…") {
            guard config.presentation.isAvailable else { return }
            config.requestPresentation()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .disabled(!config.presentation.isAvailable)
        .hoverTooltip(config.presentation.disabledHelpText ?? "Branch from this reply")
    }
}

struct AgentReplyBranchConfirmation {
    let presentation: AgentReplyBranchPresentation
    let performBranch: @MainActor () async throws -> Void
}

@MainActor
final class AgentReplyBranchConfirmationState: ObservableObject {
    @Published private(set) var confirmation: AgentReplyBranchConfirmation?
    @Published private(set) var submissionStarted = false
    @Published private(set) var errorMessage: String?

    func present(_ confirmation: AgentReplyBranchConfirmation) {
        guard self.confirmation == nil else { return }
        self.confirmation = confirmation
        submissionStarted = false
        errorMessage = nil
    }

    func dismiss() {
        guard !submissionStarted else { return }
        confirmation = nil
        errorMessage = nil
    }

    func submit() async {
        guard !submissionStarted, let confirmation else { return }
        submissionStarted = true
        errorMessage = nil
        do {
            try await confirmation.performBranch()
            self.confirmation = nil
            submissionStarted = false
        } catch {
            errorMessage = error.localizedDescription
            submissionStarted = false
        }
    }
}

@MainActor
struct AgentReplyBranchConfirmationSheet: View {
    @ObservedObject var state: AgentReplyBranchConfirmationState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.confirmation?.presentation.confirmationTitle ?? "Branch from this reply?")
                .font(.headline)
            Text(state.confirmation?.presentation.confirmationBody ?? "")
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Branch failed: \(errorMessage)")
            }

            HStack {
                Button("Cancel") {
                    state.dismiss()
                }
                .disabled(state.submissionStarted)

                Spacer()

                Button {
                    Task { await state.submit() }
                } label: {
                    if state.submissionStarted {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Branching…")
                        }
                    } else {
                        Text(state.confirmation?.presentation.confirmationButtonTitle ?? "Branch")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.submissionStarted)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(state.submissionStarted)
    }
}
