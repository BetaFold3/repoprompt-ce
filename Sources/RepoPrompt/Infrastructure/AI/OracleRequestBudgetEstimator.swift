import Foundation

/// A token-budget projection derived from the exact immutable `AIMessage` that will be sent.
struct OracleRequestBudgetEstimate: Equatable {
    struct Contributor: Equatable {
        let name: String
        let tokens: Int
    }

    let inputTokens: Int
    let outputReserveTokens: Int
    let tokenizerMarginTokens: Int
    let requiredTokens: Int
    let contextWindowTokens: Int?
    let contributors: [Contributor]

    var exceedsKnownContextWindow: Bool {
        guard let contextWindowTokens else { return false }
        return requiredTokens > contextWindowTokens
    }
}

enum OracleRequestBudgetEstimator {
    /// Provider defaults are not uniformly discoverable. Reserve a useful response when metadata
    /// and the request both omit a limit rather than treating output as free.
    static let fallbackOutputReserveTokens = 8192
    static let minimumTokenizerMarginTokens = 256
    static let tokenizerMarginRate = 0.05

    static func estimate(
        message: AIMessage,
        contextWindowTokens: Int?,
        requestedMaxOutputTokens: Int?,
        modelMaxOutputTokens: Int?
    ) -> OracleRequestBudgetEstimate {
        let systemTokens = tokens(message.systemPrompt)
        let tailTokens = tokens(message.buildTail(embedSystemPrompt: false))
        let conversationTokens = message.conversationMessages.map { tokens($0.content) }
        let inputTokens = saturatedSum(
            [systemTokens, tailTokens] + conversationTokens
        )

        let outputReserve = max(
            1,
            requestedMaxOutputTokens
                ?? modelMaxOutputTokens
                ?? fallbackOutputReserveTokens
        )
        let tokenizerMargin = max(
            minimumTokenizerMarginTokens,
            Int(ceil(Double(inputTokens) * tokenizerMarginRate))
        )
        let requiredTokens = saturatedSum([inputTokens, outputReserve, tokenizerMargin])

        let historyEntries = message.conversationMessages.dropLast()
        let historyTokens = historyEntries.reduce(0) {
            saturatedSum([$0, tokens($1.content)])
        }
        let userMessageTokens = message.conversationMessages.last.map { tokens($0.content) } ?? 0
        let presetTokens = tokens(message.metaPrompts.joined(separator: "\n"))
        let selectionTokens = saturatedSum([
            tokens(message.fileTreeXML),
            tokens(message.fileBlocksXML)
        ])
        let diffTokens = tokens(message.gitDiffXML)
        let duplicateUserTokens = message.duplicateUserInstructionsAtTop ? userMessageTokens : 0
        let categorizedTokens = saturatedSum([
            systemTokens,
            historyTokens,
            userMessageTokens,
            presetTokens,
            selectionTokens,
            diffTokens,
            duplicateUserTokens
        ])
        let packagingOverheadTokens = max(0, inputTokens - categorizedTokens)

        var contributors = [
            OracleRequestBudgetEstimate.Contributor(name: "selection", tokens: selectionTokens),
            .init(name: "history", tokens: historyTokens),
            .init(name: "frozen_diffs", tokens: diffTokens),
            .init(name: "system_prompt", tokens: systemTokens),
            .init(name: "preset_instructions", tokens: presetTokens),
            .init(name: "user_message", tokens: userMessageTokens),
            .init(name: "duplicated_user_message", tokens: duplicateUserTokens),
            .init(name: "packaging_overhead", tokens: packagingOverheadTokens)
        ]
        contributors.removeAll { $0.tokens == 0 }
        contributors.sort {
            if $0.tokens == $1.tokens { return $0.name < $1.name }
            return $0.tokens > $1.tokens
        }

        return OracleRequestBudgetEstimate(
            inputTokens: inputTokens,
            outputReserveTokens: outputReserve,
            tokenizerMarginTokens: tokenizerMargin,
            requiredTokens: requiredTokens,
            contextWindowTokens: contextWindowTokens,
            contributors: contributors
        )
    }

    private static func tokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(0, TokenCalculationService.estimateTokens(for: text))
    }

    private static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(max(0, value))
            return overflow ? Int.max : sum
        }
    }
}
