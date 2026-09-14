import Foundation
import SwiftUI

@MainActor
final class AgentRuntimeSidebarViewModel: ObservableObject {
    enum UsageSource: String, Equatable {
        case codexLive
        case toolDerived
        case unavailable

        var label: String {
            switch self {
            case .codexLive:
                "Live"
            case .toolDerived:
                "Estimated (tools)"
            case .unavailable:
                "Unavailable"
            }
        }
    }

    struct ProviderUsageSnapshot: Equatable {
        enum Scope: Equatable {
            case claude
            case codex
            case unsupported(String)
        }

        struct Presentation: Equatable {
            var title: String
            var readoutText: String
            var detailText: String
        }

        var scope: Scope
        var trackingStartedAt: Date?
        var cacheHitShare: AgentUsageCacheHitShare?
        var costEstimate: AgentUsageCostEstimate?
        /// Explains why restored read-only values cannot claim current full-session coverage.
        var coverageDetail: String?
        /// Accepted accounting mutations only. This lets lifecycle changes publish through the
        /// existing equality guard without making transcript text a usage update signal.
        var accountingRevision: UInt64?

        init(
            scope: Scope,
            trackingStartedAt: Date? = nil,
            cacheHitShare: AgentUsageCacheHitShare? = nil,
            costEstimate: AgentUsageCostEstimate? = nil,
            coverageDetail: String? = nil,
            accountingRevision: UInt64? = nil
        ) {
            self.scope = scope
            self.trackingStartedAt = trackingStartedAt
            self.cacheHitShare = cacheHitShare
            self.costEstimate = costEstimate
            self.coverageDetail = coverageDetail
            self.accountingRevision = accountingRevision
        }

        static func unavailable(for selectedAgent: AgentProviderKind?) -> Self {
            .init(scope: scope(for: selectedAgent))
        }

        /// Projects only an owned, semantically valid accounting record. A strict lossless view of
        /// an opaque v1 value is eligible; unsupported opaque data and foreign origins remain
        /// unavailable. Production's unqualified gate may expose hydrated data but never live
        /// mutations, because an unqualified accumulator is accepted only at revision zero.
        static func projected(
            selectedAgent: AgentProviderKind?,
            accounting: AgentUsageAccumulator?,
            expectedOwnerSessionID: UUID?
        ) -> Self {
            let resolvedScope = scope(for: selectedAgent)
            guard resolvedScope == .claude,
                  let expectedOwnerSessionID,
                  let accounting,
                  accounting.ownerSessionID == expectedOwnerSessionID,
                  accounting.eligibility == .eligible,
                  let record = accounting.record,
                  record.originSessionID == expectedOwnerSessionID,
                  record.semanticViolation == nil,
                  accounting.qualification != .unqualified || accounting.ownedRevision == 0
            else {
                return .init(scope: resolvedScope)
            }
            var cacheHitShare = accounting.cacheHitShare
            var costEstimate = accounting.sessionCostEstimate
            var coverageDetail: String?
            if accounting.qualification == .unqualified {
                if cacheHitShare != nil {
                    cacheHitShare?.coverage = .partial
                }
                if costEstimate != nil {
                    costEstimate?.coverage = .partial
                }
                var details = [
                    "These figures are restored historical accounting; current runtime tracking is unqualified, so coverage is partial."
                ]
                if record.turns.contains(where: { $0.outcome == .open })
                    || record.claudeSegments.contains(where: { $0.state == .open })
                {
                    details.append("The restored state includes unfinished work.")
                }
                if accounting.activeExecutionID != nil {
                    details.append("The current continuation is unmeasured.")
                }
                coverageDetail = details.joined(separator: " ")
            }
            return .init(
                scope: resolvedScope,
                trackingStartedAt: record.trackingStartedAt,
                cacheHitShare: cacheHitShare,
                costEstimate: costEstimate,
                coverageDetail: coverageDetail,
                accountingRevision: accounting.ownedRevision
            )
        }

        var presentation: Presentation {
            switch scope {
            case .claude:
                claudePresentation
            case .codex:
                .init(
                    title: "Codex session usage",
                    readoutText: "CH — · Est. —",
                    detailText: "Cache hit (CH) share and cost are unavailable because Codex usage accounting is not available in this build."
                )
            case let .unsupported(providerName):
                .init(
                    title: "\(providerName) usage",
                    readoutText: "CH — · Est. —",
                    detailText: "Cache hit (CH) share and cost are unavailable for \(providerName)."
                )
            }
        }

        private static func scope(for selectedAgent: AgentProviderKind?) -> Scope {
            switch selectedAgent {
            case .claudeCode:
                .claude
            case .codexExec:
                .codex
            case let selectedAgent?:
                .unsupported(selectedAgent.displayName)
            case nil:
                .unsupported("Provider")
            }
        }

        private var claudePresentation: Presentation {
            let cacheReadout = cacheHitShare.flatMap {
                $0.coverage == .unavailable ? nil : Self.cachePercentage($0.ratio)
            }
            let costReadout = costEstimate.flatMap {
                $0.coverage == .unavailable || $0.currency != AgentUsageAccumulator.claudeCurrency
                    ? nil
                    : Self.usdAmount($0.amount)
            }
            let cacheInline = cacheReadout.map {
                "CH \($0)\(Self.partialSuffix(cacheHitShare?.coverage))"
            } ?? "CH —"
            let costInline = costReadout.map {
                "Est. \($0)\(Self.partialSuffix(costEstimate?.coverage))"
            } ?? "Est. —"

            let cacheDetail = cacheReadout.map {
                "Cache hit (CH) share: \($0) (\(Self.coverageText(cacheHitShare?.coverage)) coverage). It is token-weighted over validated main-loop input triples."
            } ?? "Cache hit (CH) share: unavailable. It is token-weighted over validated main-loop input triples."
            let trackingDetail = trackingStartedAt.map {
                "Tracking interval starts \($0.formatted(date: .abbreviated, time: .shortened)); coverage is reported per metric."
            } ?? "Tracking interval: unavailable; coverage is reported per metric."
            let costDetail = costReadout.map {
                "Provider-estimated USD cost: \($0) (\(Self.coverageText(costEstimate?.coverage)) coverage). It covers tracked Claude session activity, includes native Claude subagents, and excludes separate RepoPrompt CE worker sessions."
            } ?? "Provider-estimated USD cost: unavailable. Its scope would cover tracked Claude session activity, include native Claude subagents, and exclude separate RepoPrompt CE worker sessions."

            return .init(
                title: "Claude session usage",
                readoutText: "\(cacheInline) · \(costInline)",
                detailText: [cacheDetail, trackingDetail, costDetail, coverageDetail]
                    .compactMap(\.self)
                    .joined(separator: " ")
            )
        }

        private static func cachePercentage(_ ratio: Decimal) -> String {
            if ratio > 0, ratio < Decimal(string: "0.001")! {
                return "<0.1%"
            }
            return "\(formatted(ratio * 100, fractionDigits: 1))%"
        }

        private static func usdAmount(_ amount: Decimal) -> String {
            if amount > 0, amount < Decimal(string: "0.001")! {
                return "$\(NSDecimalNumber(decimal: amount).stringValue)"
            }
            return "$\(formatted(amount, fractionDigits: 3))"
        }

        private static func formatted(_ value: Decimal, fractionDigits: Int) -> String {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = fractionDigits
            formatter.maximumFractionDigits = fractionDigits
            formatter.roundingMode = .halfUp
            return formatter.string(from: NSDecimalNumber(decimal: value))
                ?? NSDecimalNumber(decimal: value).stringValue
        }

        private static func partialSuffix(_ coverage: AgentProviderUsageRecord.Coverage?) -> String {
            coverage == .partial ? " partial" : ""
        }

        private static func coverageText(_ coverage: AgentProviderUsageRecord.Coverage?) -> String {
            switch coverage {
            case .complete:
                "complete"
            case .partial:
                "partial"
            case .unavailable, nil:
                "unavailable"
            }
        }
    }

    struct ContextSnapshot: Equatable {
        var updatedAt: Date?
        var usedTokens: Int?
        var estimatedTranscriptTokens: Int?
        var contextWindowTokens: Int?
        var configuredContextWindowTokens: Int?
        var usageSource: UsageSource = .unavailable
        var selectionFileCount: Int?
        var selectionSummary: AgentContextSelectionSummary?
        var selectionTokens: Int?
        var selectionDeltaTokens: Int?
        var observedReadFileCount: Int = 0
        var tokenStatsTotal: Int?
        var selectedAgent: AgentProviderKind?
        var selectedModelRaw: String?
        var providerUsage: ProviderUsageSnapshot = .unavailable(for: nil)

        /// Canonical context window with agent-specific model metadata fallback when the provider
        /// hasn't reported one yet. With a known agent, encoded selections (`base:effort`)
        /// resolve through `resolvedModel(forRaw:agentKind:)`; without one, only an exact raw
        /// match can be trusted because the specifier grammar is agent-specific.
        var canonicalContextWindowTokens: Int? {
            if let contextWindowTokens { return contextWindowTokens }
            let model: AgentModel? = if let selectedAgent {
                AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent)
            } else {
                selectedModelRaw.flatMap(AgentModel.init(rawValue:))
            }
            if let selectedAgent,
               let compatibleContextWindow = ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                   forRequestedModelRaw: selectedModelRaw,
                   agentKind: selectedAgent
               )
            {
                return compatibleContextWindow
            }
            if let modelContextWindow = model?.contextWindowTokens {
                return modelContextWindow
            }
            // Registry-listed dynamic Claude point releases (no static AgentModel
            // case) resolve through the family grammar before the generic
            // 200K provider fallback below.
            if selectedAgent == .claudeCode,
               let baseModel = ClaudeModelSpecifier(raw: selectedModelRaw).baseModel,
               let familyContextWindow = ClaudeModelFamilyCatalog.pointRelease(baseModel)?
               .family.contextWindowTokens
            {
                return familyContextWindow
            }
            return nil
        }

        var effectiveContextWindowTokens: Int {
            AgentContextWindowDenominator.effectiveContextWindowTokens(
                configured: configuredContextWindowTokens,
                canonical: canonicalContextWindowTokens,
                fallback: fallbackContextWindowTokens
            )
        }

        /// The effective window ONLY when it is a known value (configured or canonical
        /// present), else nil. Standalone window-fact surfaces (pill tooltip line, indicator
        /// `.labeled` window text) gate on this so the hardcoded per-agent `200_000` fallback is
        /// never surfaced as a fact pre-usage. Computed (not stored): adds no `Equatable`/change
        /// bookkeeping, and the min-rule/`effectiveContextWindowTokens` math is unchanged — ratios
        /// still compute over the fallback. Family-agnostic: first-party Claude/GLM are always
        /// known; only `kimiCode`/`customClaudeCompatible` unknown-raw no-settings and Codex GPT
        /// pre-usage hit both-nil, and a KNOWN Sonnet `200_000` is non-nil (knownness, not value).
        var displayContextWindowTokens: Int? {
            (configuredContextWindowTokens ?? canonicalContextWindowTokens) != nil
                ? effectiveContextWindowTokens
                : nil
        }

        private var fallbackContextWindowTokens: Int {
            switch selectedAgent {
            case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: 200_000
            case .openCode, .cursor, .ohMyPi: 200_000
            case .codexExec, .none: 200_000
            }
        }
    }

    @Published private(set) var snapshot: ContextSnapshot = .init()
    @Published private(set) var latestContextBuilderResult: ToolResultDTOs.ContextBuilderDTO?

    private struct SelectionToolMetrics: Equatable {
        let fileCount: Int
        let tokens: Int?
        let timestamp: Date
    }

    private static func trustedSelectionTokens(
        from metrics: SelectionToolMetrics?,
        liveSelectionFileCount: Int?,
        liveSelectionSummary: AgentContextSelectionSummary?
    ) -> Int? {
        guard let metrics else { return nil }
        if let liveSelectionSummary,
           liveSelectionSummary.slicedFileCount > 0 || liveSelectionSummary.sliceRangeCount > 0
        {
            return nil
        }
        guard let liveSelectionFileCount else {
            return metrics.tokens
        }
        guard liveSelectionFileCount > 0 else {
            return nil
        }
        guard metrics.fileCount == liveSelectionFileCount else {
            return nil
        }
        return metrics.tokens
    }

    private struct TimestampedToolResult<Value: Equatable>: Equatable {
        let value: Value
        let timestamp: Date
    }

    private var latestWorkspaceContext: TimestampedToolResult<ToolResultDTOs.PromptContextDTO>?
    private var latestManageSelection: TimestampedToolResult<ToolResultDTOs.SelectionReply>?
    private var observedReadFiles: Set<String> = []
    private var processedItemIDs: Set<UUID> = []
    private var activeTranscriptFirstItemID: UUID?
    private var lastSeenCodexUsage: AgentContextUsage?
    private var lastUpdatedAt: Date?

    func update(
        snapshot transcriptSnapshot: AgentTranscriptAnalyticsSnapshot,
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int? = nil,
        liveSelectionSummary: AgentContextSelectionSummary? = nil,
        selectedAgent: AgentProviderKind? = nil,
        selectedModelRaw: String? = nil,
        sessionConfiguredContextWindow: Int? = nil,
        providerUsage: ProviderUsageSnapshot? = nil
    ) {
        activeTranscriptFirstItemID = nil
        processedItemIDs.removeAll()
        // Only bump `lastUpdatedAt` when meaningful runtime inputs actually change.
        // Updating the timestamp unconditionally defeats the downstream snapshot
        // equality guard in `AgentRuntimeMetricsUIStore` and causes revision churn.
        var meaningfulChange = false

        let nextObservedReadFiles = transcriptSnapshot.observedReadFiles
        if nextObservedReadFiles != observedReadFiles {
            observedReadFiles = nextObservedReadFiles
            meaningfulChange = true
        }

        let nextWorkspaceContextItem = transcriptSnapshot.latestWorkspaceContextItem
        let nextWorkspaceContext = nextWorkspaceContextItem.flatMap { item in
            ToolJSON.decodeResult(ToolResultDTOs.PromptContextDTO.self, from: item.toolResultJSON).map {
                TimestampedToolResult(value: $0, timestamp: item.timestamp)
            }
        }
        if nextWorkspaceContext != latestWorkspaceContext {
            latestWorkspaceContext = nextWorkspaceContext
            meaningfulChange = true
        }

        let nextManageSelectionItem = transcriptSnapshot.latestManageSelectionItem
        let nextManageSelection = nextManageSelectionItem.flatMap { item in
            ToolJSON.decodeResult(ToolResultDTOs.SelectionReply.self, from: item.toolResultJSON).map {
                TimestampedToolResult(value: $0, timestamp: item.timestamp)
            }
        }
        if nextManageSelection != latestManageSelection {
            latestManageSelection = nextManageSelection
            meaningfulChange = true
        }

        let nextContextBuilderResult = transcriptSnapshot.latestContextBuilderItem.flatMap {
            ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: $0.toolResultJSON)
        }
        if nextContextBuilderResult != latestContextBuilderResult {
            latestContextBuilderResult = nextContextBuilderResult
            meaningfulChange = true
        }

        if lastSeenCodexUsage != codexUsage {
            lastSeenCodexUsage = codexUsage
            meaningfulChange = true
        }

        if meaningfulChange {
            lastUpdatedAt = Date()
        }

        let previousSnapshot = snapshot
        var next = ContextSnapshot()
        next.updatedAt = lastUpdatedAt
        next.observedReadFileCount = observedReadFiles.count
        next.estimatedTranscriptTokens = transcriptSnapshot.estimatedTranscriptTokens

        let toolTotalTokens = latestWorkspaceContext?.value.tokenStats?.total ?? latestManageSelection?.value.tokenStats?.total
        next.tokenStatsTotal = toolTotalTokens

        next.configuredContextWindowTokens = codexUsage?.configuredContextWindow ?? sessionConfiguredContextWindow

        if let codexUsage {
            let last = codexUsage.lastTotalTokens ?? 0
            let total = codexUsage.totalTotalTokens ?? 0
            let used = last > 0 ? last : total
            next.usedTokens = used > 0 ? used : nil
            next.contextWindowTokens = codexUsage.modelContextWindow
            next.usageSource = .codexLive
        } else if let toolTotalTokens {
            next.usedTokens = toolTotalTokens
            next.contextWindowTokens = nil
            next.usageSource = .toolDerived
        } else {
            next.usageSource = .unavailable
        }

        let selectionToolMetrics = latestToolSelectionMetrics()
        let selectionFiles = liveSelectionSummary?.totalExplicitFileCount ?? liveSelectedFileCount ?? selectionToolMetrics?.fileCount
        let selectionTokens = Self.trustedSelectionTokens(
            from: selectionToolMetrics,
            liveSelectionFileCount: selectionFiles,
            liveSelectionSummary: liveSelectionSummary
        )
        next.selectionSummary = liveSelectionSummary
        next.selectionTokens = selectionTokens

        if let selectionFiles {
            next.selectionFileCount = selectionFiles
        }

        if let previousTokens = previousSnapshot.selectionTokens,
           let selectionTokens,
           previousTokens != selectionTokens
        {
            next.selectionDeltaTokens = selectionTokens - previousTokens
        }

        next.selectedAgent = selectedAgent ?? transcriptSnapshot.selectedAgent
        next.selectedModelRaw = selectedModelRaw
        next.providerUsage = providerUsage ?? .unavailable(for: next.selectedAgent)

        if snapshot != next {
            snapshot = next
        }
    }

    func update(
        items: [AgentChatItem],
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int? = nil,
        liveSelectionSummary: AgentContextSelectionSummary? = nil,
        selectedAgent: AgentProviderKind? = nil,
        selectedModelRaw: String? = nil,
        sessionConfiguredContextWindow: Int? = nil,
        providerUsage: ProviderUsageSnapshot? = nil
    ) {
        resetIfTranscriptChanged(items: items)
        processNewItems(items)

        if lastSeenCodexUsage != codexUsage {
            lastSeenCodexUsage = codexUsage
            lastUpdatedAt = Date()
        }

        let previousSnapshot = snapshot
        var next = ContextSnapshot()
        next.updatedAt = lastUpdatedAt
        next.observedReadFileCount = observedReadFiles.count
        let transcriptChars = items.reduce(0) { $0 + $1.text.count }
        next.estimatedTranscriptTokens = transcriptChars > 0 ? transcriptChars / 4 : nil

        let toolTotalTokens = latestWorkspaceContext?.value.tokenStats?.total ?? latestManageSelection?.value.tokenStats?.total
        next.tokenStatsTotal = toolTotalTokens

        next.configuredContextWindowTokens = codexUsage?.configuredContextWindow ?? sessionConfiguredContextWindow

        if let codexUsage {
            let last = codexUsage.lastTotalTokens ?? 0
            let total = codexUsage.totalTotalTokens ?? 0
            let used = last > 0 ? last : total
            next.usedTokens = used > 0 ? used : nil
            next.contextWindowTokens = codexUsage.modelContextWindow
            next.usageSource = .codexLive
        } else if let toolTotalTokens {
            next.usedTokens = toolTotalTokens
            next.contextWindowTokens = nil
            next.usageSource = .toolDerived
        } else {
            next.usageSource = .unavailable
        }

        let selectionToolMetrics = latestToolSelectionMetrics()
        let selectionFiles = liveSelectionSummary?.totalExplicitFileCount ?? liveSelectedFileCount ?? selectionToolMetrics?.fileCount
        let selectionTokens = Self.trustedSelectionTokens(
            from: selectionToolMetrics,
            liveSelectionFileCount: selectionFiles,
            liveSelectionSummary: liveSelectionSummary
        )
        next.selectionSummary = liveSelectionSummary
        next.selectionTokens = selectionTokens

        if let selectionFiles {
            next.selectionFileCount = selectionFiles
        }

        if let previousTokens = previousSnapshot.selectionTokens,
           let selectionTokens,
           previousTokens != selectionTokens
        {
            next.selectionDeltaTokens = selectionTokens - previousTokens
        }

        next.selectedAgent = selectedAgent
        next.selectedModelRaw = selectedModelRaw
        next.providerUsage = providerUsage ?? .unavailable(for: next.selectedAgent)

        if snapshot != next {
            snapshot = next
        }
    }

    private func latestToolSelectionMetrics() -> SelectionToolMetrics? {
        let workspaceMetrics = latestWorkspaceContext.flatMap { result -> SelectionToolMetrics? in
            guard let selection = result.value.selection else { return nil }
            return SelectionToolMetrics(
                fileCount: selection.files.count,
                tokens: selection.totalTokens,
                timestamp: result.timestamp
            )
        }
        let manageSelectionMetrics = latestManageSelection.flatMap { result -> SelectionToolMetrics? in
            guard let files = result.value.files else { return nil }
            return SelectionToolMetrics(
                fileCount: files.count,
                tokens: result.value.totalTokens,
                timestamp: result.timestamp
            )
        }

        switch (workspaceMetrics, manageSelectionMetrics) {
        case let (workspaceMetrics?, manageSelectionMetrics?):
            return manageSelectionMetrics.timestamp >= workspaceMetrics.timestamp
                ? manageSelectionMetrics
                : workspaceMetrics
        case let (workspaceMetrics?, nil):
            return workspaceMetrics
        case let (nil, manageSelectionMetrics?):
            return manageSelectionMetrics
        case (nil, nil):
            return nil
        }
    }

    private func resetIfTranscriptChanged(items: [AgentChatItem]) {
        let firstID = items.first?.id
        if firstID != activeTranscriptFirstItemID {
            activeTranscriptFirstItemID = firstID
            processedItemIDs.removeAll()
            latestWorkspaceContext = nil
            latestManageSelection = nil
            latestContextBuilderResult = nil
            observedReadFiles.removeAll()
            lastUpdatedAt = nil
        }
    }

    private func processNewItems(_ items: [AgentChatItem]) {
        for item in items where !processedItemIDs.contains(item.id) {
            processedItemIDs.insert(item.id)
            process(item)
        }
    }

    private func process(_ item: AgentChatItem) {
        guard let toolName = normalizedToolCardName(item.toolName) else { return }
        let normalized = toolName.lowercased()

        if item.kind == .toolCall, normalized == "read_file",
           let args = ToolJSON.decodeArgs(ToolArgsDTOs.ReadFileArgs.self, from: item.toolArgsJSON),
           let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            observedReadFiles.insert(path)
            lastUpdatedAt = item.timestamp
        }

        guard item.kind == .toolResult else { return }
        switch normalized {
        case "workspace_context":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.PromptContextDTO.self, from: item.toolResultJSON) {
                latestWorkspaceContext = TimestampedToolResult(value: dto, timestamp: item.timestamp)
                lastUpdatedAt = item.timestamp
            }
        case "manage_selection":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.SelectionReply.self, from: item.toolResultJSON) {
                latestManageSelection = TimestampedToolResult(value: dto, timestamp: item.timestamp)
                lastUpdatedAt = item.timestamp
            }
        case "context_builder":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: item.toolResultJSON) {
                latestContextBuilderResult = dto
                lastUpdatedAt = item.timestamp
            }
        case "read_file":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.ReadFileReply.self, from: item.toolResultJSON),
               let path = dto.displayPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                observedReadFiles.insert(path)
                lastUpdatedAt = item.timestamp
            }
        default:
            break
        }
    }
}
