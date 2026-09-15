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
            /// Full scope/coverage explanation for tooltips and accessibility.
            var detailText: String
            /// Additional content rendered inside the context-pill popover. It keeps the compact
            /// main line limited to latest-request CH plus accumulated session cost.
            var expandedDetailText: String?
            /// Short explanation hosts may render visibly next to the readout: why no figures are
            /// shown, or why shown figures are only partial. `nil` when nothing needs explaining.
            var noteText: String?

            init(
                title: String,
                readoutText: String,
                detailText: String,
                expandedDetailText: String? = nil,
                noteText: String? = nil
            ) {
                self.title = title
                self.readoutText = readoutText
                self.detailText = detailText
                self.expandedDetailText = expandedDetailText
                self.noteText = noteText
            }
        }

        var scope: Scope
        var trackingStartedAt: Date?
        /// Live-only request-level CH. Persisted turn/result aggregates never populate it.
        var latestRequestCacheHit: AgentUsageLatestRequestCacheHit?
        /// Token-weighted CH over the persisted session ledger.
        var cacheHitShare: AgentUsageCacheHitShare?
        var costEstimate: AgentUsageCostEstimate?
        /// Upper bound of a Codex envelope-priced estimate; `nil` (or equal to the amount) for a point.
        var costUpperBound: Decimal?
        /// Pricing provenance for Codex (frozen pricing version(s) used by the priced intervals).
        var pricingProvenance: String?
        /// Explains why restored read-only values cannot claim current full-session coverage.
        var coverageDetail: String?
        /// Concrete per-metric coverage text used by the expanded popover.
        var sessionCacheCoverageDetail: String?
        var sessionCostCoverageDetail: String?
        /// Accepted accounting mutations only. This lets lifecycle changes publish through the
        /// existing equality guard without making transcript text a usage update signal.
        var accountingRevision: UInt64?
        /// Explains why a Claude readout shows no figures (gated live accounting, missing record,
        /// foreign ownership, or an unsupported persisted value). `nil` when figures are shown.
        var unavailableReason: String?

        /// Explains a Claude readout with no accounting owner or a lifecycle-only (`.unqualified`)
        /// policy: nothing was measured, which is distinct from a measured zero.
        static let claudeLiveAccountingGatedReason =
            "No live figures: usage accounting is not counting this session's turns. Only restored session accounting can display, and it is marked partial."
        static let claudeNoUsageRecordedReason = "No usage has been recorded for this session yet."

        init(
            scope: Scope,
            trackingStartedAt: Date? = nil,
            latestRequestCacheHit: AgentUsageLatestRequestCacheHit? = nil,
            cacheHitShare: AgentUsageCacheHitShare? = nil,
            costEstimate: AgentUsageCostEstimate? = nil,
            costUpperBound: Decimal? = nil,
            pricingProvenance: String? = nil,
            coverageDetail: String? = nil,
            sessionCacheCoverageDetail: String? = nil,
            sessionCostCoverageDetail: String? = nil,
            accountingRevision: UInt64? = nil,
            unavailableReason: String? = nil
        ) {
            self.scope = scope
            self.trackingStartedAt = trackingStartedAt
            self.latestRequestCacheHit = latestRequestCacheHit
            self.cacheHitShare = cacheHitShare
            self.costEstimate = costEstimate
            self.costUpperBound = costUpperBound
            self.pricingProvenance = pricingProvenance
            self.coverageDetail = coverageDetail
            self.sessionCacheCoverageDetail = sessionCacheCoverageDetail
            self.sessionCostCoverageDetail = sessionCostCoverageDetail
            self.accountingRevision = accountingRevision
            self.unavailableReason = unavailableReason
        }

        /// No accounting owner at all (no session, or no accumulator installed yet). Claude scope
        /// still explains itself so an empty readout is never a silent dash.
        static func unavailable(for selectedAgent: AgentProviderKind?) -> Self {
            let resolvedScope = scope(for: selectedAgent)
            return .init(
                scope: resolvedScope,
                unavailableReason: resolvedScope == .claude || resolvedScope == .codex ? claudeNoUsageRecordedReason : nil
            )
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
            if resolvedScope == .codex {
                return projectedCodex(accounting: accounting, expectedOwnerSessionID: expectedOwnerSessionID)
            }
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
                return .init(
                    scope: resolvedScope,
                    unavailableReason: resolvedScope == .claude
                        ? claudeUnavailableReason(
                            accounting: accounting,
                            expectedOwnerSessionID: expectedOwnerSessionID
                        )
                        : nil
                )
            }
            var cacheHitShare = accounting.cacheHitShare
            var costEstimate = accounting.sessionCostEstimate
            var coverageDetail: String?
            var details: [String] = []
            var cacheCurrentDetails: [String] = []
            var costCurrentDetails: [String] = []
            // Restored `.open` turns/segments from a disposed execution are work that never closed;
            // under every policy they make displayed coverage partial and are named explicitly.
            if accounting.hasAbandonedHydratedLifecycleState {
                if cacheHitShare != nil {
                    cacheHitShare?.coverage = .partial
                }
                if costEstimate != nil {
                    costEstimate?.coverage = .partial
                }
                let detail = "The restored state includes unfinished work."
                details.append(detail)
                cacheCurrentDetails.append(detail)
                costCurrentDetails.append(detail)
            }
            if accounting.qualification == .executionVerified,
               let diagnostic = accounting.executionQualificationDiagnostic
            {
                // Figures come only from qualified executions; an active execution that cannot
                // charge makes any dispatched work explicitly uncounted.
                let detail: String
                if accounting.hasUnchargedDispatchedWork {
                    if cacheHitShare != nil {
                        cacheHitShare?.coverage = .partial
                    }
                    if costEstimate != nil {
                        costEstimate?.coverage = .partial
                    }
                    detail = "The current continuation is not counted: \(diagnostic)."
                } else if case .awaiting? = accounting.executionVerdict {
                    detail = "The current continuation is not counting yet: \(diagnostic)."
                } else {
                    detail = "The current continuation cannot be counted: \(diagnostic)."
                }
                details.append(detail)
                cacheCurrentDetails.append(detail)
                costCurrentDetails.append(detail)
            }
            if accounting.qualification == .executionVerified, let diagnostic = accounting.monetaryScopeDiagnostic {
                let detail = "The current continuation counts tokens only: \(diagnostic)."
                details.append(detail)
                costCurrentDetails.append(detail)
            }
            let childTurns = accounting.childActivityTurnCount
            if childTurns > 0 {
                details.append(
                    "Native child (subagent) activity occurred in \(childTurns) turn\(childTurns == 1 ? "" : "s"); the cost estimate includes it, while those turns' result usage is excluded from CH because its main-loop scope cannot be proven."
                )
                cacheCurrentDetails.append(
                    "Native child (subagent) activity occurred in \(childTurns) turn\(childTurns == 1 ? "" : "s"); those turns' result usage is excluded from CH because its main-loop scope cannot be proven."
                )
            }
            if accounting.qualification == .unqualified {
                if cacheHitShare != nil {
                    cacheHitShare?.coverage = .partial
                }
                if costEstimate != nil {
                    costEstimate?.coverage = .partial
                }
                let unqualified = "These figures are restored historical accounting; current runtime tracking is unqualified, so coverage is partial."
                details.insert(unqualified, at: 0)
                cacheCurrentDetails.append(unqualified)
                costCurrentDetails.append(unqualified)
                if accounting.activeExecutionID != nil {
                    let unmeasured = "The current continuation is unmeasured."
                    details.append(unmeasured)
                    cacheCurrentDetails.append(unmeasured)
                    costCurrentDetails.append(unmeasured)
                }
            }
            if !details.isEmpty {
                coverageDetail = details.joined(separator: " ")
            }
            return .init(
                scope: resolvedScope,
                trackingStartedAt: record.trackingStartedAt,
                latestRequestCacheHit: accounting.latestRequestCacheHit(for: .claudeAssistant),
                cacheHitShare: cacheHitShare,
                costEstimate: costEstimate,
                coverageDetail: coverageDetail,
                sessionCacheCoverageDetail: claudeSessionCacheCoverageDetail(
                    record: record,
                    share: cacheHitShare,
                    currentDetail: cacheCurrentDetails.isEmpty
                        ? nil
                        : uniqueDetails(cacheCurrentDetails).joined(separator: " ")
                ),
                sessionCostCoverageDetail: claudeSessionCostCoverageDetail(
                    record: record,
                    estimate: costEstimate,
                    currentDetail: costCurrentDetails.isEmpty
                        ? nil
                        : uniqueDetails(costCurrentDetails).joined(separator: " ")
                ),
                accountingRevision: accounting.ownedRevision
            )
        }

        /// Codex scope (plan §4.1): owned counter intervals priced locally from the frozen
        /// Standard/global list-price snapshot captured at each dispatch.
        private static func projectedCodex(
            accounting: AgentUsageAccumulator?,
            expectedOwnerSessionID: UUID?
        ) -> Self {
            guard let expectedOwnerSessionID,
                  let accounting,
                  accounting.ownerSessionID == expectedOwnerSessionID,
                  accounting.eligibility == .eligible,
                  accounting.qualification != .unqualified
            else {
                return .init(
                    scope: .codex,
                    unavailableReason: claudeUnavailableReason(
                        accounting: accounting,
                        expectedOwnerSessionID: expectedOwnerSessionID
                    )
                )
            }

            let latest = accounting.latestRequestCacheHit(for: .codexLast)
            guard let record = accounting.record else {
                return .init(
                    scope: .codex,
                    latestRequestCacheHit: latest,
                    sessionCacheCoverageDetail: "Unavailable: no persisted Codex session intervals have been recorded.",
                    sessionCostCoverageDetail: "Unavailable: no persisted Codex session intervals have been recorded.",
                    accountingRevision: accounting.ownedRevision,
                    unavailableReason: latest == nil ? claudeNoUsageRecordedReason : nil
                )
            }
            guard record.originSessionID == expectedOwnerSessionID, record.semanticViolation == nil else {
                return .init(
                    scope: .codex,
                    unavailableReason: claudeUnavailableReason(
                        accounting: accounting,
                        expectedOwnerSessionID: expectedOwnerSessionID
                    )
                )
            }

            let intervals = record.codexIntervals ?? []
            let cacheShare = accounting.codexCacheHitShare
            let cost = accounting.codexSessionCostEstimate
            let intervalDiagnostics = uniqueDetails(intervals.compactMap(\.diagnostic))
            var details = intervalDiagnostics
            if record.hasUnmeasuredHistory {
                details.append(
                    "Earlier Codex usage is marked unmeasured; the persisted record does not store a separate historical cause."
                )
            }
            return .init(
                scope: .codex,
                trackingStartedAt: intervals.isEmpty ? nil : record.trackingStartedAt,
                latestRequestCacheHit: latest,
                cacheHitShare: cacheShare,
                costEstimate: cost.map { .init(amount: $0.lower, currency: $0.currency, coverage: $0.coverage) },
                costUpperBound: cost.flatMap { $0.isPoint ? nil : $0.upper },
                pricingProvenance: accounting.codexPricingProvenance.map(codexPricingProvenanceText),
                coverageDetail: details.isEmpty ? nil : details.joined(separator: " "),
                sessionCacheCoverageDetail: codexSessionCacheCoverageDetail(
                    record: record,
                    intervals: intervals,
                    share: cacheShare
                ),
                sessionCostCoverageDetail: codexSessionCostCoverageDetail(
                    record: record,
                    intervals: intervals,
                    estimate: cost
                ),
                accountingRevision: accounting.ownedRevision,
                unavailableReason: intervals.isEmpty && latest == nil ? claudeNoUsageRecordedReason : nil
            )
        }

        var presentation: Presentation {
            switch scope {
            case .claude:
                claudePresentation
            case .codex:
                codexPresentation
            case let .unsupported(providerName):
                .init(
                    title: "\(providerName) usage",
                    readoutText: "CH — · Est. —",
                    detailText: "Cache hit (CH) share and cost are unavailable for \(providerName).",
                    noteText: "Usage accounting is unavailable for \(providerName)."
                )
            }
        }

        /// Names the first failed projection precondition for a Claude scope. Ordering mirrors the
        /// `projected` guard so the explanation matches the branch that actually rejected the record.
        private static func claudeUnavailableReason(
            accounting: AgentUsageAccumulator?,
            expectedOwnerSessionID: UUID?
        ) -> String {
            guard let expectedOwnerSessionID else {
                return "No active session owns usage accounting."
            }
            guard let accounting else {
                return claudeNoUsageRecordedReason
            }
            guard accounting.ownerSessionID == expectedOwnerSessionID else {
                return "Usage accounting belongs to a different session and is not shown here."
            }
            switch accounting.eligibility {
            case .foreignOrigin:
                return "The restored usage record originated in a different session; it is preserved but not counted here."
            case .opaquePersistedValue:
                return "The restored usage value is not supported by this build; it is preserved unchanged and not shown."
            case .eligible:
                break
            }
            guard let record = accounting.record else {
                if accounting.qualification == .unqualified {
                    return claudeLiveAccountingGatedReason
                }
                if let diagnostic = accounting.executionQualificationDiagnostic {
                    return "No live figures: \(diagnostic). This session's turns are not counted."
                }
                return "No usage has been recorded for this session yet."
            }
            guard record.originSessionID == expectedOwnerSessionID else {
                return "The restored usage record originated in a different session; it is preserved but not counted here."
            }
            guard record.semanticViolation == nil else {
                return "The restored usage record is not semantically valid; it is preserved unchanged and not shown."
            }
            return "Usage accounting cannot be shown for the current session state."
        }

        private static func claudeSessionCacheCoverageDetail(
            record: AgentProviderUsageRecord,
            share: AgentUsageCacheHitShare?,
            currentDetail: String?
        ) -> String {
            var reasons = record.turns.compactMap { turn -> String? in
                guard turn.outcome != .open, turn.coverage != .complete else { return nil }
                if let diagnostic = turn.diagnostic {
                    return diagnostic.contains("monetary checkpoint rejected") ? nil : diagnostic
                }
                let missing = [
                    turn.inputTokens == nil ? "input" : nil,
                    turn.cacheReadInputTokens == nil ? "cache-read" : nil,
                    turn.cacheCreationInputTokens == nil ? "cache-creation" : nil
                ].compactMap(\.self)
                return missing.isEmpty
                    ? "A finalized Claude turn is marked incomplete; its historical cause was not recorded."
                    : "A finalized Claude turn omitted \(missing.joined(separator: ", ")) counters."
            }
            if record.hasUnmeasuredHistory {
                reasons.append(
                    "Earlier Claude usage is marked unmeasured; the persisted record does not store a separate historical cause."
                )
            }
            if let currentDetail {
                reasons.append(currentDetail)
            }
            reasons = uniqueDetails(reasons)
            guard let share else {
                let cause = reasons.isEmpty
                    ? "No finalized turn has a complete, nonzero input/cache-read/cache-creation denominator."
                    : reasons.joined(separator: " ")
                return "Unavailable: \(cause)"
            }
            guard share.coverage == .partial else {
                let complete = "Complete: every finalized measured turn supplied the counters used by this metric."
                return reasons.isEmpty ? complete : "\(complete) \(reasons.joined(separator: " "))"
            }
            return reasons.isEmpty
                ? "Partial: the persisted value is marked partial, but its historical cause was not recorded."
                : "Partial: \(reasons.joined(separator: " "))"
        }

        private static func claudeSessionCostCoverageDetail(
            record: AgentProviderUsageRecord,
            estimate: AgentUsageCostEstimate?,
            currentDetail: String?
        ) -> String {
            var reasons: [String] = []
            for (offset, segment) in record.claudeSegments.enumerated() {
                let segmentNumber = offset + 1
                if segment.baseline == nil {
                    reasons.append("Cost segment \(segmentNumber) has no verified cumulative-cost baseline.")
                }
                if segment.latestCumulative == nil {
                    reasons.append("Cost segment \(segmentNumber) has no accepted cumulative-cost checkpoint.")
                }
                if segment.coverage != .complete {
                    reasons.append(
                        "Cost segment \(segmentNumber) is recorded with \(coverageText(segment.coverage)) coverage; no separate historical reason is stored on the segment."
                    )
                }
                if segment.state == .suspended {
                    reasons.append(
                        "Cost segment \(segmentNumber) is suspended; the persisted segment does not store its historical suspension cause."
                    )
                }
            }
            reasons.append(contentsOf: record.turns.compactMap { turn in
                guard let diagnostic = turn.diagnostic, diagnostic.contains("monetary checkpoint rejected") else {
                    return nil
                }
                return diagnostic
            })
            if record.hasUnmeasuredHistory {
                reasons.append(
                    "Earlier Claude cost is marked unmeasured; the persisted record does not store a separate historical cause."
                )
            }
            if let currentDetail {
                reasons.append(currentDetail)
            }
            reasons = uniqueDetails(reasons)
            guard let estimate else {
                return reasons.isEmpty
                    ? "Unavailable: no segment has both a verified baseline and an accepted cumulative-cost checkpoint."
                    : "Unavailable: \(reasons.joined(separator: " "))"
            }
            guard estimate.coverage == .partial else {
                let complete = "Complete: every contributing monetary segment has complete coverage."
                return reasons.isEmpty ? complete : "\(complete) \(reasons.joined(separator: " "))"
            }
            return reasons.isEmpty
                ? "Partial: the persisted estimate is marked partial, but its historical cause was not recorded."
                : "Partial: \(reasons.joined(separator: " "))"
        }

        private static func codexSessionCacheCoverageDetail(
            record: AgentProviderUsageRecord,
            intervals: [AgentProviderUsageRecord.CodexUsageInterval],
            share: AgentUsageCacheHitShare?
        ) -> String {
            var reasons = intervals.compactMap { interval -> String? in
                guard let input = interval.inputTokens,
                      let cached = interval.cachedInputTokens,
                      input >= 0,
                      cached >= 0,
                      CodexUsagePricing.hasConsistentInputSubsets(
                          input: input,
                          cached: cached,
                          cacheWrite: interval.cacheWriteInputTokens
                      )
                else {
                    if let diagnostic = interval.diagnostic {
                        return diagnostic
                    }
                    let missing = [
                        interval.inputTokens == nil ? "input" : nil,
                        interval.cachedInputTokens == nil ? "cached-input" : nil
                    ].compactMap(\.self)
                    return missing.isEmpty
                        ? "A Codex interval has inconsistent input/cache counters; no separate historical cause was recorded."
                        : "A Codex interval omitted \(missing.joined(separator: ", ")) counters."
                }
                return nil
            }
            if record.hasUnmeasuredHistory {
                reasons.append(
                    "Earlier Codex usage is marked unmeasured; the persisted record does not store a separate historical cause."
                )
            }
            reasons = uniqueDetails(reasons)
            guard let share else {
                return reasons.isEmpty
                    ? "Unavailable: no owned interval has a complete, nonzero input denominator."
                    : "Unavailable: \(reasons.joined(separator: " "))"
            }
            guard share.coverage == .partial else {
                return "Complete: every owned measured interval supplied consistent input and cached-input counters."
            }
            return reasons.isEmpty
                ? "Partial: the persisted value is marked partial, but its historical cause was not recorded."
                : "Partial: \(reasons.joined(separator: " "))"
        }

        private static func codexSessionCostCoverageDetail(
            record: AgentProviderUsageRecord,
            intervals: [AgentProviderUsageRecord.CodexUsageInterval],
            estimate: CodexCostEstimate?
        ) -> String {
            var reasons = intervals.compactMap { interval -> String? in
                guard interval.estimatedCostLowerUSD == nil || interval.coverage != .complete else {
                    return nil
                }
                if let diagnostic = interval.diagnostic {
                    return diagnostic
                }
                let missing = [
                    interval.inputTokens == nil ? "input" : nil,
                    interval.cachedInputTokens == nil ? "cached-input" : nil,
                    interval.outputTokens == nil ? "output" : nil
                ].compactMap(\.self)
                return missing.isEmpty
                    ? "A Codex interval is not completely priced; its historical cause was not recorded."
                    : "A Codex interval omitted \(missing.joined(separator: ", ")) counters required for complete pricing."
            }
            if record.hasUnmeasuredHistory {
                reasons.append(
                    "Earlier Codex cost is marked unmeasured; the persisted record does not store a separate historical cause."
                )
            }
            reasons = uniqueDetails(reasons)
            guard let estimate else {
                return reasons.isEmpty
                    ? "Unavailable: no owned interval has a priceable token delta."
                    : "Unavailable: \(reasons.joined(separator: " "))"
            }
            guard estimate.coverage == .partial else {
                return "Complete: every owned interval has a complete frozen-pricing estimate."
            }
            return reasons.isEmpty
                ? "Partial: the persisted estimate is marked partial, but its historical cause was not recorded."
                : "Partial: \(reasons.joined(separator: " "))"
        }

        private static func uniqueDetails(_ details: [String]) -> [String] {
            var seen = Set<String>()
            return details.filter { seen.insert($0).inserted }
        }

        /// Frozen pricing provenance for the details: version(s), capture/validation dates and
        /// whether any priced interval used a snapshot that was already stale at dispatch.
        private static func codexPricingProvenanceText(_ provenance: CodexPricingProvenance) -> String {
            var parts = ["pricing version \(provenance.pricingVersions.map { String($0.prefix(12)) }.joined(separator: ", "))"]
            if let earliest = provenance.earliestCapturedAt, let latest = provenance.latestCapturedAt {
                let earliestText = earliest.formatted(date: .abbreviated, time: .omitted)
                let latestText = latest.formatted(date: .abbreviated, time: .omitted)
                parts.append(earliestText == latestText ? "price list dated \(earliestText)" : "price lists dated \(earliestText) to \(latestText)")
            }
            if let validated = provenance.latestValidatedAt {
                parts.append("last validated \(validated.formatted(date: .abbreviated, time: .shortened))")
            }
            if provenance.staleIntervalCount > 0 {
                parts.append("stale at dispatch for \(provenance.staleIntervalCount) interval\(provenance.staleIntervalCount == 1 ? "" : "s")")
            }
            return parts.joined(separator: ", ")
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
            let latestReadout = latestRequestCacheHit?.share.map { Self.cachePercentage($0.ratio) }
            let costReadout = costEstimate.flatMap {
                $0.coverage == .unavailable || $0.currency != AgentUsageAccumulator.claudeCurrency
                    ? nil
                    : Self.usdAmount($0.amount)
            }
            let latestInline = latestReadout.map { "CH \($0)" } ?? "CH —"
            let costInline = costReadout.map {
                "Est. \($0)\(Self.partialSuffix(costEstimate?.coverage))"
            } ?? "Est. —"

            let latestDetail = latestRequestCacheHit.map {
                "Latest-request CH: \(latestReadout ?? "unavailable"). \($0.detail)"
            } ?? "Latest-request CH: unavailable. It is live-only and is not restored from turn/result aggregates or another process."
            let sessionCacheDetail = cacheHitShare.map {
                "Session-average CH: \(Self.cachePercentage($0.ratio)) (\(Self.coverageText($0.coverage)) coverage). It is token-weighted over finalized result usage and is never used as the latest-request value. \(sessionCacheCoverageDetail ?? "")"
            } ?? "Session-average CH: unavailable. \(sessionCacheCoverageDetail ?? "No finalized result has a complete nonzero input/cache counter triple.")"
            let trackingDetail = trackingStartedAt.map {
                "Tracking period: since \($0.formatted(date: .abbreviated, time: .shortened))."
            } ?? "Tracking period: unavailable."
            let costDetail = costReadout.map {
                "Accumulated session cost: \($0) (\(Self.coverageText(costEstimate?.coverage)) coverage). It is Claude's cumulative process estimate, including helper-model and native Claude child usage, not billed spend; separate RepoPrompt CE worker sessions are excluded. \(sessionCostCoverageDetail ?? "")"
            } ?? "Accumulated session cost: unavailable. \(sessionCostCoverageDetail ?? "No accepted cumulative cost checkpoint is recorded.")"

            let expanded = [latestDetail, sessionCacheDetail, trackingDetail, costDetail, unavailableReason]
                .compactMap(\.self)
                .joined(separator: "\n\n")
            return .init(
                title: "Claude latest request CH · session cost",
                readoutText: "\(latestInline) · \(costInline)",
                detailText: expanded.replacingOccurrences(of: "\n", with: " "),
                expandedDetailText: expanded,
                noteText: nil
            )
        }

        private var codexPresentation: Presentation {
            let latestReadout = latestRequestCacheHit?.share.map { Self.cachePercentage($0.ratio) }
            let costReadout: String? = costEstimate.flatMap { estimate in
                guard estimate.coverage != .unavailable, estimate.currency == CodexUsagePricing.currency else { return nil }
                if let upper = costUpperBound, upper != estimate.amount {
                    // Endpoints round outward so the displayed range never excludes a permitted value.
                    return "\(Self.usdLowerBound(estimate.amount))–\(Self.usdUpperBound(upper))"
                }
                return Self.usdAmount(estimate.amount)
            }
            let latestInline = latestReadout.map { "CH \($0)" } ?? "CH —"
            let costInline = costReadout.map {
                "Est. \($0)\(Self.partialSuffix(costEstimate?.coverage))"
            } ?? "Est. —"

            let latestDetail = latestRequestCacheHit.map {
                "Latest-request CH: \(latestReadout ?? "unavailable"). \($0.detail)"
            } ?? "Latest-request CH: unavailable. It is live-only and is not restored from cumulative totals, another session, or another process."
            let sessionCacheDetail = cacheHitShare.map {
                "Session-average CH: \(Self.cachePercentage($0.ratio)) (\(Self.coverageText($0.coverage)) coverage). It is token-weighted over owned cumulative-total intervals and is never used as the latest-request value. \(sessionCacheCoverageDetail ?? "")"
            } ?? "Session-average CH: unavailable. \(sessionCacheCoverageDetail ?? "No owned interval has complete nonzero input and cached-input counters.")"
            let trackingDetail = trackingStartedAt.map {
                "Tracking period: since \($0.formatted(date: .abbreviated, time: .shortened))."
            } ?? "Tracking period: unavailable."
            let costDetail = costReadout.map {
                "Accumulated session cost: \($0) (\(Self.coverageText(costEstimate?.coverage)) coverage). It is an API-equivalent estimate calculated from frozen OpenAI Standard/global list prices\(pricingProvenance.map { " (\($0))" } ?? "") at each dispatch, not billed spend or a plan charge. A range bounds the stated token-price assumptions where a context band could not be attributed. \(sessionCostCoverageDetail ?? "")"
            } ?? "Accumulated session cost: unavailable. It would be an API-equivalent estimate, not billed spend or a plan charge. \(sessionCostCoverageDetail ?? "No owned interval could be priced.")"

            let expanded = [latestDetail, sessionCacheDetail, trackingDetail, costDetail, unavailableReason]
                .compactMap(\.self)
                .joined(separator: "\n\n")
            return .init(
                title: "Codex latest request CH · session cost",
                readoutText: "\(latestInline) · \(costInline)",
                detailText: expanded.replacingOccurrences(of: "\n", with: " "),
                expandedDetailText: expanded,
                noteText: nil
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

        /// Lower range endpoint rounded down; a tiny positive value keeps its exact digits so it
        /// never masquerades as zero.
        static func usdLowerBound(_ amount: Decimal) -> String {
            let rounded = roundedDecimal(amount, scale: 3, mode: .down)
            if amount > 0, rounded <= 0 {
                return "$\(NSDecimalNumber(decimal: amount).stringValue)"
            }
            return "$\(formatted(rounded, fractionDigits: 3))"
        }

        /// Upper range endpoint rounded up.
        static func usdUpperBound(_ amount: Decimal) -> String {
            "$\(formatted(roundedDecimal(amount, scale: 3, mode: .up), fractionDigits: 3))"
        }

        private static func roundedDecimal(_ value: Decimal, scale: Int16, mode: NSDecimalNumber.RoundingMode) -> Decimal {
            let handler = NSDecimalNumberHandler(
                roundingMode: mode,
                scale: scale,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
            return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).decimalValue
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
