import SwiftUI

struct AgentReplyBranchPresentation: Equatable {
    let turnID: UUID
    let availability: AgentSessionBranchAvailability
    let isOperationInProgress: Bool
    let isVisible: Bool

    static func isEligibleBlock(_ kind: AgentTranscriptRenderBlockKind) -> Bool {
        kind == .conclusion
    }

    init(
        turnID: UUID,
        availability: AgentSessionBranchAvailability,
        isOperationInProgress: Bool,
        isVisible: Bool = true
    ) {
        self.turnID = turnID
        self.availability = availability
        self.isOperationInProgress = isOperationInProgress
        self.isVisible = isVisible
    }

    var isAvailable: Bool {
        guard case .available = availability else { return false }
        return !isOperationInProgress
    }

    var disabledHelpText: String? {
        if isOperationInProgress {
            return "Finish the pending operation before branching."
        }
        guard case let .unavailable(reason) = availability else { return nil }
        return Self.helpText(for: reason)
    }

    static func helpText(for reason: AgentSessionBranchAvailability.Reason) -> String {
        switch reason {
        case .noCheckpoint, .turnNotCompleted, .threadMismatch, .turnNotRetained,
             .treeEvidenceUnavailable:
            "No native checkpoint was recorded for this turn."
        case .beforeCompaction, .unsupportedHistory:
            "Codex compacted this conversation after this checkpoint."
        case .lineageProviderMismatch:
            "Branching is disabled because this branch's recorded source provider does not match its current provider."
        case .runtimeCapabilityUnknown:
            AgentBranchSafetySummary.runtimeCheckingText
        case let .runtimeUnsupported(reason):
            switch reason {
            case .versionBelowFloor: AgentBranchSafetySummary.runtimeVersionText
            case .flagMissing, .probeFailed, .probeTimedOut:
                AgentBranchSafetySummary.runtimeUnverifiedText
            }
        case .notIdle, .operationInProgress, .pendingHandoff:
            "Finish the pending operation before branching."
        case .providerUnsupported, .remoteSession, .mcpOriginated, .childSession, .worktreeBound:
            AgentBranchSafetySummary.providerUnavailableText
        }
    }
}

struct AgentReplyBranchConfig {
    let presentation: AgentReplyBranchPresentation
    let requestPresentation: @MainActor () -> Void
}

@MainActor
struct AgentReplyBranchControl: View {
    let config: AgentReplyBranchConfig
    @State private var isHovering = false

    var body: some View {
        if config.presentation.isVisible {
            Button {
                guard config.presentation.isAvailable else { return }
                config.requestPresentation()
            } label: {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        isHovering ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal
                    )
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .disabled(!config.presentation.isAvailable)
            .hoverTooltip(config.presentation.disabledHelpText ?? "Branch from this reply…")
            .accessibilityLabel("Create conversation branch from this reply")
        }
    }
}
