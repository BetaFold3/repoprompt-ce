import Foundation

struct AgentBranchSafetySummary: Equatable {
    enum Impact: Equatable {
        case readOnly
        case modified(paths: [String])
        case unknown
    }

    static let rollbackDisclosure =
        "Conversation only — files, Git state, and workspace selections are not rolled back."
    static let staleText =
        "The conversation changed. Review the updated branch details."
    static let providerUnavailableText =
        "Native branching is currently available only for local Codex and Claude Code sessions."
    static let runtimeCheckingText = "Checking Claude Code branching support…"
    static let runtimeVersionText = "Branching needs Claude Code 2.1.258 or newer."
    static let runtimeUnverifiedText =
        "Claude Code branching could not be verified for this executable."

    let retainedTurnCount: Int
    let omittedTurnCount: Int
    let impact: Impact
    let sourceOwnedOracleChatCount: Int

    init(
        turnID: UUID,
        transcriptTurnIDs: [UUID],
        checkpointIndex: AgentBranchCheckpointIndex?,
        sourceOwnedOracleChatCount: Int = 0
    ) {
        self.sourceOwnedOracleChatCount = max(0, sourceOwnedOracleChatCount)
        let matches = transcriptTurnIDs.indices.filter { transcriptTurnIDs[$0] == turnID }
        guard matches.count == 1, let selectedIndex = matches.first else {
            retainedTurnCount = 0
            omittedTurnCount = 0
            impact = .unknown
            return
        }

        retainedTurnCount = selectedIndex + 1
        let omittedIDs = transcriptTurnIDs.dropFirst(selectedIndex + 1)
        omittedTurnCount = omittedIDs.count
        impact = Self.impact(of: omittedIDs, checkpointIndex: checkpointIndex)
    }

    init(
        retainedTurnCount: Int,
        omittedTurnCount: Int,
        impact: Impact,
        sourceOwnedOracleChatCount: Int = 0
    ) {
        self.retainedTurnCount = max(0, retainedTurnCount)
        self.omittedTurnCount = max(0, omittedTurnCount)
        self.impact = impact
        self.sourceOwnedOracleChatCount = max(0, sourceOwnedOracleChatCount)
    }

    var hasResolvedTurn: Bool {
        retainedTurnCount > 0
    }

    var turnSummaryText: String {
        if omittedTurnCount == 0 {
            return "Keeps turns 1–\(retainedTurnCount) · nothing set aside"
        }
        return "Keeps turns 1–\(retainedTurnCount) · sets aside \(omittedTurnCount) later turn(s)"
    }

    var impactText: String {
        impactText(expanded: false)
    }

    var hasCollapsedChangedPaths: Bool {
        if case let .modified(paths) = impact {
            return paths.count > 8
        }
        return false
    }

    func impactText(expanded: Bool) -> String {
        switch impact {
        case .readOnly:
            return "Read-only exploration"
        case let .modified(paths):
            let visible = expanded ? paths : Array(paths.prefix(8))
            let overflow = paths.count - visible.count
            let suffix = overflow > 0 ? ", and \(overflow) more" : ""
            return "Changed files: \(visible.joined(separator: ", "))\(suffix)"
        case .unknown:
            return "May have changed files"
        }
    }

    var oracleDisclosureText: String? {
        guard sourceOwnedOracleChatCount > 0 else { return nil }
        if sourceOwnedOracleChatCount == 1 {
            return "1 Oracle chat stays with the source path — this branch can read its results but must start a new chat to continue."
        }
        return "\(sourceOwnedOracleChatCount) Oracle chats stay with the source path — this branch can read their results but must start new chats to continue."
    }

    var branchButtonTitle: String {
        switch impact {
        case .readOnly: "Branch"
        case .modified, .unknown: "Branch anyway"
        }
    }

    private static func impact(
        of turnIDs: ArraySlice<UUID>,
        checkpointIndex: AgentBranchCheckpointIndex?
    ) -> Impact {
        guard let checkpointIndex else {
            return turnIDs.isEmpty ? .readOnly : .unknown
        }
        var modifiedPaths: [String] = []
        var seenPaths = Set<String>()
        for turnID in turnIDs {
            guard !checkpointIndex.duplicateTurnIDs.contains(turnID),
                  let checkpoint = checkpointIndex.byTurnID[turnID],
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
