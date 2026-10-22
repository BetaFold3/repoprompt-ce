import Foundation

// Optional version-7 session member for provider-history reconciliation (lossless restart Phase 4,
// phase4-plan "History ledger"). It is the session-side half of one import transaction:
//
//   session rows + this native-ID ledger + the import receipt commit in ONE session save
//   (`AgentSessionDataService.commitProviderHistoryImport`) → the recovery cursor CAS follows.
//
// The ledger maps normalized native row keys (provider, native session, native entry, row kind,
// ordinal) to the local transcript items they were projected as, so replays, replacement rescans,
// and crash cuts between the two commits never duplicate rows. Absent when empty (no version bump):
// older builds ignore it; unknown members inside it round-trip.
//
// `dispatchBaselines` are the immutable pre-send history boundaries of individual durable
// dispatches (one per dispatch, never overwritten by a later run). Each captured one was committed
// as a zero-row import receipt BEFORE that dispatch's user bytes; the recovery cursor is only an
// optimization and never selects an interrupted attempt's starting boundary.

package struct AgentSessionProviderHistoryRecovery: Codable, Equatable {
    /// One imported native row (or a validated native entry that is intentionally not projected).
    package struct NativeItem: Codable, Equatable {
        package let providerRaw: String
        package let nativeSessionID: String
        package let nativeEntryID: String
        package let rowKindRaw: String
        package let ordinal: Int
        /// Local transcript item this row was projected as. `nil` = unassociated/not projected (a
        /// native user entry): never evidence that the entry is a known local user item.
        package let localItemID: UUID?
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            providerRaw: String,
            nativeSessionID: String,
            nativeEntryID: String,
            rowKindRaw: String,
            ordinal: Int,
            localItemID: UUID?,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.providerRaw = providerRaw
            self.nativeSessionID = nativeSessionID
            self.nativeEntryID = nativeEntryID
            self.rowKindRaw = rowKindRaw
            self.ordinal = ordinal
            self.localItemID = localItemID
            self.extras = extras
        }

        /// The normalized native row key (never API message ID, text, or tool name).
        package var key: String {
            AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: providerRaw,
                nativeSessionID: nativeSessionID,
                nativeEntryID: nativeEntryID,
                rowKindRaw: rowKindRaw,
                ordinal: ordinal
            )
        }

        private static let knownKeys: Set<String> = [
            "provider", "nativeSessionID", "nativeEntryID", "rowKind", "ordinal", "localItemID"
        ]

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            providerRaw = try container.decode(String.self, forKey: HistoryDynamicKey("provider"))
            nativeSessionID = try container.decode(String.self, forKey: HistoryDynamicKey("nativeSessionID"))
            nativeEntryID = try container.decode(String.self, forKey: HistoryDynamicKey("nativeEntryID"))
            rowKindRaw = try container.decode(String.self, forKey: HistoryDynamicKey("rowKind"))
            ordinal = try container.decode(Int.self, forKey: HistoryDynamicKey("ordinal"))
            localItemID = try container.decodeIfPresent(UUID.self, forKey: HistoryDynamicKey("localItemID"))
            extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            try HistoryDynamicKey.encode(extras, into: &container)
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encode(nativeSessionID, forKey: HistoryDynamicKey("nativeSessionID"))
            try container.encode(nativeEntryID, forKey: HistoryDynamicKey("nativeEntryID"))
            try container.encode(rowKindRaw, forKey: HistoryDynamicKey("rowKind"))
            try container.encode(ordinal, forKey: HistoryDynamicKey("ordinal"))
            try container.encodeIfPresent(localItemID, forKey: HistoryDynamicKey("localItemID"))
        }
    }

    /// Receipt of the latest committed import. The recovery cursor follows this import ID.
    package struct ImportCommit: Codable, Equatable {
        package let importID: UUID
        package let providerRaw: String
        package let conversationID: String
        package let committedAt: Date
        /// Rows projected by this import (0 for a baseline or a no-op import).
        package let rowCount: Int
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            importID: UUID,
            providerRaw: String,
            conversationID: String,
            committedAt: Date,
            rowCount: Int,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.importID = importID
            self.providerRaw = providerRaw
            self.conversationID = conversationID
            self.committedAt = committedAt
            self.rowCount = rowCount
            self.extras = extras
        }

        private static let knownKeys: Set<String> = ["importID", "provider", "conversationID", "committedAt", "rowCount"]

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            importID = try container.decode(UUID.self, forKey: HistoryDynamicKey("importID"))
            providerRaw = try container.decode(String.self, forKey: HistoryDynamicKey("provider"))
            conversationID = try container.decode(String.self, forKey: HistoryDynamicKey("conversationID"))
            committedAt = try container.decode(Date.self, forKey: HistoryDynamicKey("committedAt"))
            rowCount = try container.decode(Int.self, forKey: HistoryDynamicKey("rowCount"))
            extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            try HistoryDynamicKey.encode(extras, into: &container)
            try container.encode(importID, forKey: HistoryDynamicKey("importID"))
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encode(conversationID, forKey: HistoryDynamicKey("conversationID"))
            try container.encode(committedAt, forKey: HistoryDynamicKey("committedAt"))
            try container.encode(rowCount, forKey: HistoryDynamicKey("rowCount"))
        }
    }

    /// Immutable pre-send history boundary of ONE durable dispatch (Phase 4 baseline producer).
    package struct DispatchBaseline: Codable, Equatable {
        package enum Status: Equatable {
            /// A validated complete-line boundary committed before the dispatch's user bytes.
            case captured
            /// No boundary could be captured before the bytes (missing identity or history
            /// location). Never backfilled: this dispatch has no history recovery.
            case unsupported(String)
        }

        /// Existing durable dispatch identity (the first delivery attempt ID); idempotency key.
        package let dispatchID: UUID
        package let runAttemptID: UUID?
        package let transcriptResetGeneration: UInt64
        package let providerRaw: String
        /// Exact native conversation (`nil` only for an unsupported capture without one).
        package let conversationID: String?
        /// Ordered local user items of the dispatch's constituents.
        package let userItemIDs: [UUID]
        /// `nil` for verified absence (or an unsupported capture).
        package let file: AgentRecoveryHistoryFileIdentity?
        package let completeLineOffset: UInt64
        /// The zero-row import receipt that committed this boundary (`nil` when unsupported).
        package let baselineCommitID: UUID?
        package let profileName: String
        package let status: Status
        package let recordedAt: Date
        package var extras: [String: AgentScheduledSendJSONValue]

        package init(
            dispatchID: UUID,
            runAttemptID: UUID?,
            transcriptResetGeneration: UInt64,
            providerRaw: String,
            conversationID: String?,
            userItemIDs: [UUID],
            file: AgentRecoveryHistoryFileIdentity?,
            completeLineOffset: UInt64,
            baselineCommitID: UUID?,
            profileName: String,
            status: Status,
            recordedAt: Date,
            extras: [String: AgentScheduledSendJSONValue] = [:]
        ) {
            self.dispatchID = dispatchID
            self.runAttemptID = runAttemptID
            self.transcriptResetGeneration = transcriptResetGeneration
            self.providerRaw = providerRaw
            self.conversationID = conversationID
            self.userItemIDs = userItemIDs
            self.file = file
            self.completeLineOffset = completeLineOffset
            self.baselineCommitID = baselineCommitID
            self.profileName = profileName
            self.status = status
            self.recordedAt = Self.millisecondDate(Self.milliseconds(recordedAt))
            self.extras = extras
        }

        /// Millisecond precision, so the value survives its own encoding exactly.
        private static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1000).rounded())
        }

        private static func millisecondDate(_ milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }

        /// The import boundary a captured baseline represents (`nil` when unsupported).
        package var cursor: AgentRecoveryHistoryCursor? {
            guard status == .captured, let conversationID, let baselineCommitID else { return nil }
            return AgentRecoveryHistoryCursor(
                providerRaw: providerRaw,
                conversationID: conversationID,
                importID: baselineCommitID,
                file: file,
                completeLineOffset: completeLineOffset,
                committedAt: AgentRecoveryTimestamp(recordedAt)
            )
        }

        private static let knownKeys: Set<String> = [
            "dispatchID", "runAttemptID", "transcriptResetGeneration", "provider", "conversationID",
            "userItemIDs", "fileDevice", "fileInode", "fileBirthSeconds", "fileBirthNanoseconds",
            "completeLineOffset", "baselineCommitID", "profile", "status", "unsupportedReason", "recordedAtMs"
        ]

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
            func key(_ name: String) -> HistoryDynamicKey {
                HistoryDynamicKey(name)
            }
            dispatchID = try container.decode(UUID.self, forKey: key("dispatchID"))
            runAttemptID = try container.decodeIfPresent(UUID.self, forKey: key("runAttemptID"))
            transcriptResetGeneration = try container.decode(UInt64.self, forKey: key("transcriptResetGeneration"))
            providerRaw = try container.decode(String.self, forKey: key("provider"))
            conversationID = try container.decodeIfPresent(String.self, forKey: key("conversationID"))
            userItemIDs = try container.decodeIfPresent([UUID].self, forKey: key("userItemIDs")) ?? []
            if let device = try container.decodeIfPresent(UInt64.self, forKey: key("fileDevice")) {
                file = try AgentRecoveryHistoryFileIdentity(
                    device: device,
                    inode: container.decode(UInt64.self, forKey: key("fileInode")),
                    birthSeconds: container.decodeIfPresent(Int64.self, forKey: key("fileBirthSeconds")),
                    birthNanoseconds: container.decodeIfPresent(Int64.self, forKey: key("fileBirthNanoseconds"))
                )
            } else {
                file = nil
            }
            completeLineOffset = try container.decode(UInt64.self, forKey: key("completeLineOffset"))
            baselineCommitID = try container.decodeIfPresent(UUID.self, forKey: key("baselineCommitID"))
            profileName = try container.decode(String.self, forKey: key("profile"))
            switch try container.decode(String.self, forKey: key("status")) {
            case "captured" where baselineCommitID != nil && conversationID != nil:
                status = .captured
            case "unsupported":
                status = try .unsupported(container.decodeIfPresent(String.self, forKey: key("unsupportedReason")) ?? "")
            default:
                // Not understood (or an incomplete capture): preserved verbatim as unreadable.
                throw DecodingError.dataCorruptedError(
                    forKey: key("status"),
                    in: container,
                    debugDescription: "Unrecognized or incomplete dispatch baseline."
                )
            }
            // Epoch milliseconds: independent of the enclosing encoder's date strategy.
            recordedAt = try Self.millisecondDate(container.decode(Int64.self, forKey: key("recordedAtMs")))
            extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: HistoryDynamicKey.self)
            try HistoryDynamicKey.encode(extras, into: &container)
            try container.encode(dispatchID, forKey: HistoryDynamicKey("dispatchID"))
            try container.encodeIfPresent(runAttemptID, forKey: HistoryDynamicKey("runAttemptID"))
            try container.encode(transcriptResetGeneration, forKey: HistoryDynamicKey("transcriptResetGeneration"))
            try container.encode(providerRaw, forKey: HistoryDynamicKey("provider"))
            try container.encodeIfPresent(conversationID, forKey: HistoryDynamicKey("conversationID"))
            try container.encode(userItemIDs, forKey: HistoryDynamicKey("userItemIDs"))
            if let file {
                try container.encode(file.device, forKey: HistoryDynamicKey("fileDevice"))
                try container.encode(file.inode, forKey: HistoryDynamicKey("fileInode"))
                try container.encodeIfPresent(file.birthSeconds, forKey: HistoryDynamicKey("fileBirthSeconds"))
                try container.encodeIfPresent(file.birthNanoseconds, forKey: HistoryDynamicKey("fileBirthNanoseconds"))
            }
            try container.encode(completeLineOffset, forKey: HistoryDynamicKey("completeLineOffset"))
            try container.encodeIfPresent(baselineCommitID, forKey: HistoryDynamicKey("baselineCommitID"))
            try container.encode(profileName, forKey: HistoryDynamicKey("profile"))
            switch status {
            case .captured:
                try container.encode("captured", forKey: HistoryDynamicKey("status"))
            case let .unsupported(reason):
                try container.encode("unsupported", forKey: HistoryDynamicKey("status"))
                try container.encode(reason, forKey: HistoryDynamicKey("unsupportedReason"))
            }
            try container.encode(Self.milliseconds(recordedAt), forKey: HistoryDynamicKey("recordedAtMs"))
        }
    }

    package var nativeItems: [NativeItem]
    package var lastImportCommit: ImportCommit?
    /// Per-dispatch pre-send boundaries, in recording order (never replaced).
    package var dispatchBaselines: [DispatchBaseline]
    /// Baseline entries this build cannot read, kept verbatim (never usable as a boundary).
    package private(set) var unreadableDispatchBaselines: [AgentScheduledSendJSONValue] = []
    package var extras: [String: AgentScheduledSendJSONValue]

    package init(
        nativeItems: [NativeItem] = [],
        lastImportCommit: ImportCommit? = nil,
        dispatchBaselines: [DispatchBaseline] = [],
        extras: [String: AgentScheduledSendJSONValue] = [:]
    ) {
        self.nativeItems = nativeItems
        self.lastImportCommit = lastImportCommit
        self.dispatchBaselines = dispatchBaselines
        self.extras = extras
    }

    /// `nil` when nothing would be persisted.
    package var nilIfEmpty: AgentSessionProviderHistoryRecovery? {
        nativeItems.isEmpty && lastImportCommit == nil && dispatchBaselines.isEmpty
            && unreadableDispatchBaselines.isEmpty && extras.isEmpty ? nil : self
    }

    package func dispatchBaseline(dispatchID: UUID) -> DispatchBaseline? {
        dispatchBaselines.first { $0.dispatchID == dispatchID }
    }

    /// The starting boundary of one run attempt: its EARLIEST recorded dispatch (captured or not;
    /// a later dispatch never backfills an unsupported first one).
    package func firstDispatchBaseline(runAttemptID: UUID) -> DispatchBaseline? {
        dispatchBaselines.first { $0.runAttemptID == runAttemptID }
    }

    package func nativeItem(forKey key: String) -> NativeItem? {
        nativeItems.first { $0.key == key }
    }

    /// Unambiguous length-prefixed encoding of a native row key.
    package static func rowKey(
        providerRaw: String,
        nativeSessionID: String,
        nativeEntryID: String,
        rowKindRaw: String,
        ordinal: Int
    ) -> String {
        [providerRaw, nativeSessionID, nativeEntryID, rowKindRaw, String(ordinal)]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static let knownKeys: Set<String> = ["nativeItems", "lastImportCommit", "dispatchBaselines"]

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HistoryDynamicKey.self)
        nativeItems = try container.decodeIfPresent([NativeItem].self, forKey: HistoryDynamicKey("nativeItems")) ?? []
        lastImportCommit = try container.decodeIfPresent(ImportCommit.self, forKey: HistoryDynamicKey("lastImportCommit"))
        // Element-wise: one unreadable baseline never fails the session; it round-trips verbatim.
        var typed: [DispatchBaseline] = []
        var unreadable: [AgentScheduledSendJSONValue] = []
        let rawBaselines = try container.decodeIfPresent(
            [AgentScheduledSendJSONValue].self,
            forKey: HistoryDynamicKey("dispatchBaselines")
        ) ?? []
        for raw in rawBaselines {
            if let data = try? JSONEncoder().encode(raw),
               let value = try? JSONDecoder().decode(DispatchBaseline.self, from: data)
            {
                typed.append(value)
            } else {
                unreadable.append(raw)
            }
        }
        dispatchBaselines = typed
        unreadableDispatchBaselines = unreadable
        extras = try HistoryDynamicKey.extras(in: container, excluding: Self.knownKeys)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: HistoryDynamicKey.self)
        try HistoryDynamicKey.encode(extras, into: &container)
        if !nativeItems.isEmpty {
            try container.encode(nativeItems, forKey: HistoryDynamicKey("nativeItems"))
        }
        try container.encodeIfPresent(lastImportCommit, forKey: HistoryDynamicKey("lastImportCommit"))
        if !dispatchBaselines.isEmpty || !unreadableDispatchBaselines.isEmpty {
            var array = container.nestedUnkeyedContainer(forKey: HistoryDynamicKey("dispatchBaselines"))
            for baseline in dispatchBaselines {
                try array.encode(baseline)
            }
            for raw in unreadableDispatchBaselines {
                try array.encode(raw)
            }
        }
    }
}

package enum AgentSessionHistoryImportError: Error, Equatable {
    /// An ordinary save carried an older history receipt than the committed import (an older
    /// snapshot). Nothing was written.
    case staleHistorySnapshot
    /// An import commit whose payload does not carry exactly its own receipt. Nothing was written.
    case receiptMismatch
}

/// Dynamic member key that keeps unknown members of the history envelope.
private struct HistoryDynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }

    static func extras(
        in container: KeyedDecodingContainer<HistoryDynamicKey>,
        excluding known: Set<String>
    ) throws -> [String: AgentScheduledSendJSONValue] {
        var extras: [String: AgentScheduledSendJSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(AgentScheduledSendJSONValue.self, forKey: key)
        }
        return extras
    }

    static func encode(
        _ extras: [String: AgentScheduledSendJSONValue],
        into container: inout KeyedEncodingContainer<HistoryDynamicKey>
    ) throws {
        for (key, value) in extras {
            try container.encode(value, forKey: HistoryDynamicKey(key))
        }
    }
}
