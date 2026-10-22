import Foundation

// History-only reconciliation planning (lossless restart Phase 4, phase4-plan "History ledger" and
// "Exact transaction boundary"). Pure value transforms: a validated provider candidate plus the
// session's current transcript and ledger produce exactly one import plan:
//
//   1. inert transcript rows to append (never live stream results, never dispatched input),
//   2. the updated native-ID ledger and its import receipt (`ImportCommit`), committed with the rows
//      in ONE session save (`AgentSessionDataService.commitProviderHistoryImport`),
//   3. the recovery cursor, advanced afterwards by compare-and-swap on the previous import ID.
//
// A crash between (2) and (3) leaves the rows and ledger committed; the next import's ledger dedup
// makes the replay a no-op. Rows already known to the ledger, or whose deterministic local ID is
// already in the transcript, are never appended again.
//
// Before planning a provider import into a live conversation, `AgentProviderHistoryAssociationPreflight`
// requires the interrupted dispatch's own pre-send baseline AND explicit associations between the
// native rows and the canonical transcript. The planner deduplicates only its own ledger and
// deterministic IDs; it cannot recognise live rows persisted under unrelated IDs, so importing
// without association evidence could duplicate or misattribute them.

/// One validated native row in provider-neutral form.
package struct AgentProviderHistoryRow: Equatable {
    package let nativeSessionID: String
    package let nativeEntryID: String
    package let rowKindRaw: String
    package let ordinal: Int
    /// The inert transcript item this row projects to (`nil` = recorded in the ledger only).
    package let item: AgentChatItem?

    package init(nativeSessionID: String, nativeEntryID: String, rowKindRaw: String, ordinal: Int, item: AgentChatItem?) {
        self.nativeSessionID = nativeSessionID
        self.nativeEntryID = nativeEntryID
        self.rowKindRaw = rowKindRaw
        self.ordinal = ordinal
        self.item = item
    }
}

/// A complete, validated provider observation ready to plan (built only from a whole validated
/// candidate; partial or unsupported candidates never reach this type).
package struct AgentProviderHistoryObservation: Equatable {
    package let provider: AgentRecoveryHistoryProvider
    package let conversationID: String
    package let rows: [AgentProviderHistoryRow]
    package let file: AgentRecoveryHistoryFileIdentity?
    package let completeLineOffset: UInt64
    /// Whether the provider proved the expected turn finished (Claude: never).
    package let completionConfirmed: Bool

    package init(
        provider: AgentRecoveryHistoryProvider,
        conversationID: String,
        rows: [AgentProviderHistoryRow],
        file: AgentRecoveryHistoryFileIdentity?,
        completeLineOffset: UInt64,
        completionConfirmed: Bool
    ) {
        self.provider = provider
        self.conversationID = conversationID
        self.rows = rows
        self.file = file
        self.completeLineOffset = completeLineOffset
        self.completionConfirmed = completionConfirmed
    }
}

package struct AgentProviderHistoryImportPlan: Equatable {
    package let importID: UUID
    package let previousImportID: UUID?
    /// New inert transcript items, in provider order (labelled by a leading system row when non-empty).
    package let appendedItems: [AgentChatItem]
    package let ledger: AgentSessionProviderHistoryRecovery
    package let importCommit: AgentSessionProviderHistoryRecovery.ImportCommit
    package let cursor: AgentRecoveryHistoryCursor
    package let completionConfirmed: Bool

    package var outcome: AgentRecoveryActionOutcomeKind {
        completionConfirmed ? .importedCompleted : .importedUnconfirmed
    }
}

package enum AgentProviderHistoryImportPlanner {
    package static let recoveredLabel = "Recovered from provider history after restart (completion unconfirmed)."
    package static let recoveredCompletedLabel = "Recovered from provider history after restart."

    /// Plans one import. `previousCursor` is the recovery record's current cursor for this
    /// conversation (its import ID is the CAS expectation).
    package static func plan(
        observation: AgentProviderHistoryObservation,
        existingItemIDs: Set<UUID>,
        ledger: AgentSessionProviderHistoryRecovery?,
        previousCursor: AgentRecoveryHistoryCursor?,
        importID: UUID,
        now: Date
    ) -> AgentProviderHistoryImportPlan {
        var ledger = ledger ?? AgentSessionProviderHistoryRecovery()
        var knownKeys = Set(ledger.nativeItems.map(\.key))
        var seenIDs = existingItemIDs
        var appended: [AgentChatItem] = []
        for row in observation.rows {
            let key = AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: observation.provider.rawValue,
                nativeSessionID: row.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.rowKindRaw,
                ordinal: row.ordinal
            )
            guard knownKeys.insert(key).inserted else { continue }
            var localItemID: UUID?
            if let item = row.item, seenIDs.insert(item.id).inserted {
                appended.append(item)
                localItemID = item.id
            } else if let item = row.item {
                // Already in the transcript under its deterministic ID: record, do not duplicate.
                localItemID = item.id
            }
            ledger.nativeItems.append(AgentSessionProviderHistoryRecovery.NativeItem(
                providerRaw: observation.provider.rawValue,
                nativeSessionID: row.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.rowKindRaw,
                ordinal: row.ordinal,
                localItemID: localItemID
            ))
        }
        if !appended.isEmpty {
            let label = AgentChatItem.system(
                observation.completionConfirmed ? recoveredCompletedLabel : recoveredLabel
            ).replacingID(ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "rpce-history-import-label-v1",
                components: [observation.provider.rawValue, observation.conversationID, importID.uuidString.lowercased()]
            ))
            appended.insert(label, at: 0)
        }
        let commit = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: importID,
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            committedAt: now,
            rowCount: appended.count
        )
        ledger.lastImportCommit = commit
        let cursor = AgentRecoveryHistoryCursor(
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            importID: importID,
            file: observation.file,
            completeLineOffset: observation.completeLineOffset,
            committedAt: AgentRecoveryTimestamp(now)
        )
        return AgentProviderHistoryImportPlan(
            importID: importID,
            previousImportID: previousCursor?.importID,
            appendedItems: appended,
            ledger: ledger,
            importCommit: commit,
            cursor: cursor,
            completionConfirmed: observation.completionConfirmed
        )
    }
}

// MARK: - Association preflight

/// Typed refusal of a canonical history import (lossless restart Phase 4). Zero transcript changes
/// and no cursor movement follow any refusal.
package enum AgentProviderHistoryAssociationRefusal: Equatable {
    /// The interrupted attempt has no captured pre-send baseline (none, unsupported, or unreadable).
    case baselineUnavailable
    /// The baseline belongs to another conversation, transcript generation, or attempt, or its
    /// dispatch's user items are not in this transcript.
    case baselineTargetMismatch
    /// A native user entry after the baseline has no explicit association to a local user item.
    case nativeUserAssociationUnavailable
    /// Canonical provider output after the dispatch is not explicitly associated to native rows
    /// (or cannot be enumerated because it was compacted).
    case canonicalOutputAssociationUnavailable
}

/// The canonical transcript an import would merge into: the persisted turns (including compacted
/// ones) plus the session's mutable working suffix.
package struct AgentProviderHistoryCanonicalView {
    package let transcript: AgentTranscript
    package let suffixItems: [AgentChatItem]

    package init(transcript: AgentTranscript, suffixItems: [AgentChatItem]) {
        self.transcript = transcript
        self.suffixItems = suffixItems
    }
}

package enum AgentProviderHistoryAssociationPreflight {
    static let outputKinds: Set<AgentChatItemKind> = [.assistant, .assistantInline, .toolCall, .toolResult, .thinking]

    /// Checks whether `observation` (read after `baseline`) may be planned into `canonical`.
    /// `nil` = the explicit associations exist; otherwise the import must not run.
    package static func check(
        observation: AgentProviderHistoryObservation,
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        hasUnreadableBaselines: Bool,
        expectedRunAttemptID: UUID?,
        transcriptResetGeneration: UInt64,
        canonical: AgentProviderHistoryCanonicalView,
        ledger: AgentSessionProviderHistoryRecovery?
    ) -> AgentProviderHistoryAssociationRefusal? {
        if let refusal = baselineRefusal(
            baseline: baseline,
            hasUnreadableBaselines: hasUnreadableBaselines,
            expectedRunAttemptID: expectedRunAttemptID,
            providerRaw: observation.provider.rawValue,
            conversationID: observation.conversationID,
            transcriptResetGeneration: transcriptResetGeneration
        ) {
            return refusal
        }
        guard let baseline else { return .baselineUnavailable }
        // Canonical output after the dispatch's first user item, across compacted turns and suffix
        // (`nil` = the dispatch's user items are not in this transcript).
        guard let canonicalOutputIDs = outputItemIDs(after: Set(baseline.userItemIDs), in: canonical) else {
            return .baselineTargetMismatch
        }
        // Positive association of EVERY user constituent of the dispatch (review A P1-05), checked
        // independently of the (possibly ledger-filtered) observation: each local user item must be
        // the explicit `localItemID` of a native user row of this conversation in the ledger. A nil
        // `localItemID` is unassociated. Nothing in this build writes such a user association, so a
        // live conversation always refuses here; no empty-output or user-filter shortcut exists.
        let associatedUserItemIDs = Set((ledger?.nativeItems ?? []).compactMap { native -> UUID? in
            guard native.providerRaw == observation.provider.rawValue,
                  native.nativeSessionID == observation.conversationID,
                  native.rowKindRaw == userRowKindRaw(observation.provider)
            else { return nil }
            return native.localItemID
        })
        guard Set(baseline.userItemIDs).isSubset(of: associatedUserItemIDs) else {
            return .nativeUserAssociationUnavailable
        }
        // Native user rows: `localItemID == nil` in the ledger is NOT an association, and nothing in
        // this build relates a native user entry to the dispatch's local user item.
        if observation.rows.contains(where: { $0.item == nil }) {
            return .nativeUserAssociationUnavailable
        }
        guard case let .enumerated(ids) = canonicalOutputIDs else {
            return .canonicalOutputAssociationUnavailable
        }
        let associated = Set((ledger?.nativeItems ?? []).compactMap(\.localItemID))
            .union(observation.rows.compactMap { $0.item?.id })
        if !ids.isSubset(of: associated) {
            return .canonicalOutputAssociationUnavailable
        }
        return nil
    }

    /// The baseline half of the preflight (checked before any history read).
    package static func baselineRefusal(
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        hasUnreadableBaselines: Bool,
        expectedRunAttemptID: UUID?,
        providerRaw: String,
        conversationID: String,
        transcriptResetGeneration: UInt64
    ) -> AgentProviderHistoryAssociationRefusal? {
        // An unreadable entry might be this attempt's earliest one: never select a later boundary.
        guard let baseline, baseline.status == .captured, baseline.cursor != nil, !hasUnreadableBaselines else {
            return .baselineUnavailable
        }
        guard baseline.providerRaw == providerRaw,
              baseline.conversationID == conversationID,
              baseline.transcriptResetGeneration == transcriptResetGeneration,
              expectedRunAttemptID != nil, baseline.runAttemptID == expectedRunAttemptID,
              !baseline.userItemIDs.isEmpty
        else {
            return .baselineTargetMismatch
        }
        return nil
    }

    /// Codex canonical overlap (review A P1-04 / B F1). Live Codex output is persisted under its own
    /// IDs, and this build has no native → canonical mapping for live Codex items, so projected
    /// observation rows may be planned only when the canonical transcript provably holds no
    /// unassociated provider output at or after the interrupted turn's user item (compacted turns
    /// included, plus the suffix). Output already associated through the ledger (an earlier import)
    /// or carried by this observation's own deterministic rows does not overlap. `nil` = no overlap;
    /// otherwise the rows are withheld (zero rows; a confirmed completion stays honest).
    package static func codexOverlapRefusal(
        observation: AgentProviderHistoryObservation,
        turnUserItemIDs: Set<UUID>,
        canonical: AgentProviderHistoryCanonicalView,
        ledger: AgentSessionProviderHistoryRecovery?
    ) -> AgentProviderHistoryAssociationRefusal? {
        guard observation.rows.contains(where: { $0.item != nil }) else { return nil }
        guard !turnUserItemIDs.isEmpty, let output = outputItemIDs(after: turnUserItemIDs, in: canonical) else {
            return .baselineTargetMismatch
        }
        guard case let .enumerated(ids) = output else { return .canonicalOutputAssociationUnavailable }
        let associated = Set((ledger?.nativeItems ?? []).compactMap(\.localItemID))
            .union(observation.rows.compactMap { $0.item?.id })
        return ids.isSubset(of: associated) ? nil : .canonicalOutputAssociationUnavailable
    }

    /// The native row kind of a provider's user message.
    static func userRowKindRaw(_ provider: AgentRecoveryHistoryProvider) -> String {
        switch provider {
        case .claude: ClaudeSessionHistoryReader.RowKind.userText.rawValue
        case .codex: CodexRecoveryObservation.Item.Kind.userMessage.rawValue
        }
    }

    enum CanonicalOutput: Equatable {
        case enumerated(Set<UUID>)
        /// The dispatch lies in (or before) a compacted turn whose rows are not stored.
        case notEnumerable
    }

    /// Provider-output item IDs at or after the first of `userItemIDs`; `nil` when that user item is
    /// in neither the persisted turns nor the suffix.
    static func outputItemIDs(after userItemIDs: Set<UUID>, in canonical: AgentProviderHistoryCanonicalView) -> CanonicalOutput? {
        var ids = Set<UUID>()
        var found = false
        var enumerable = true
        for turn in canonical.transcript.turns {
            let requestMatches = turn.request.map { userItemIDs.contains($0.id) } ?? false
            let activityMatches = turn.allActivities.contains { userItemIDs.contains($0.id) }
            if !found, requestMatches || activityMatches {
                found = true
            }
            guard found else { continue }
            if turn.retentionTier != .full || turn.isStructurallyCompacted {
                enumerable = false
            }
            var afterUser = requestMatches
            for activity in turn.allActivities {
                if userItemIDs.contains(activity.id) { afterUser = true }
                if afterUser, outputKinds.contains(activity.itemKind) { ids.insert(activity.id) }
            }
        }
        var afterUserInSuffix = found
        for item in canonical.suffixItems {
            if userItemIDs.contains(item.id) {
                found = true
                afterUserInSuffix = true
            }
            if afterUserInSuffix, outputKinds.contains(item.kind) { ids.insert(item.id) }
        }
        guard found else { return nil }
        return enumerable ? .enumerated(ids) : .notEnumerable
    }
}

// MARK: - Claude projection

extension ClaudeSessionHistoryReader {
    /// Converts a validated candidate to the provider-neutral observation. Rows carry inert items
    /// with their deterministic identities; native user rows carry no item (unassociated, never
    /// projected, and never assumed to be a local user item).
    package static func observation(_ candidate: Candidate) -> AgentProviderHistoryObservation {
        let rows = candidate.rows.map { row -> AgentProviderHistoryRow in
            AgentProviderHistoryRow(
                nativeSessionID: candidate.nativeSessionID,
                nativeEntryID: row.nativeEntryID,
                rowKindRaw: row.kind.rawValue,
                ordinal: row.ordinal,
                item: item(for: row)
            )
        }
        return AgentProviderHistoryObservation(
            provider: .claude,
            conversationID: candidate.nativeSessionID,
            rows: rows,
            file: candidate.file,
            completeLineOffset: candidate.completeLineOffset,
            completionConfirmed: false
        )
    }

    static func item(for row: Row) -> AgentChatItem? {
        guard let localID = row.localItemID else { return nil }
        let item: AgentChatItem? = switch row.kind {
        case .userText:
            nil
        case .assistantText:
            row.text.map { AgentChatItem.assistant($0) }
        case .toolCall:
            AgentChatItem.toolCall(
                name: row.toolName ?? "tool",
                invocationID: row.toolInvocationID,
                argsJSON: row.toolInputJSON
            )
        case .toolResult:
            AgentChatItem.toolResult(
                name: row.toolName ?? "tool",
                invocationID: row.toolInvocationID,
                resultJSON: row.text ?? "",
                isError: row.toolIsError
            )
        }
        return item?.replacingID(localID)
    }
}
