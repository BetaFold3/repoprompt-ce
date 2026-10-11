import Foundation

#if DEBUG
    import RepoPromptPlatform

    /// Debug-only, opt-in instrumentation for steady-state Agent Mode performance hot paths.
    ///
    /// Enable in debug builds with either:
    /// - `defaults write com.repoprompt.RepoPrompt enableAgentModePerfDiagnostics -bool YES`
    /// - `RP_AGENT_MODE_PERF_DIAGNOSTICS=1`
    /// - the hidden MCP diagnostics op: `__repoprompt_debug_diagnostics` with `{ "op": "agent_perf_metrics", "enable": true }`
    ///
    /// This file is compiled behind `#if DEBUG`; release builds do not include the logger.
    /// The generic recording mechanism (enablement, timestamps, event/counter buffers, os_log)
    /// lives in `PerfDiagnosticsRecorder`; this type adds Agent Mode instrumentation and reporting.
    /// App-owned state below is guarded by the recorder lock via `withLockedState`.
    package enum AgentModePerfDiagnostics {
        private typealias Recorder = PerfDiagnosticsRecorder
        private typealias AgentPerfEventRecord = PerfDiagnosticsRecorder.EventRecord
        private static let bufferLimit = Recorder.bufferLimit
        private static let structuredEventLimit = Recorder.structuredEventLimit
        private static let sessionSnapshotLimit = 500
        private static var latestSessionSnapshots: [String: [String: Any]] = [:]
        private static var latestSessionSnapshotOrder: [String] = []
        private static var pendingSidebarDeleteByTabID: [UUID: PendingSidebarDelete] = [:]

        package struct SidebarDeleteBeginContext {
            let tabID: UUID
            let sessionID: UUID?
            let source: String
            let reason: String?
            let wasCurrentTab: Bool
            let wasRunning: Bool
            let isMCPControlled: Bool

            package init(
                tabID: UUID,
                sessionID: UUID?,
                source: String,
                reason: String?,
                wasCurrentTab: Bool,
                wasRunning: Bool,
                isMCPControlled: Bool
            ) {
                self.tabID = tabID
                self.sessionID = sessionID
                self.source = source
                self.reason = reason
                self.wasCurrentTab = wasCurrentTab
                self.wasRunning = wasRunning
                self.isMCPControlled = isMCPControlled
            }
        }

        private struct PendingSidebarDelete {
            let deleteID: UUID
            let tabID: UUID
            let sessionID: UUID?
            let startMS: Double
            let source: String
            let reason: String?
            let wasCurrentTab: Bool
            let wasRunning: Bool
            let isMCPControlled: Bool
            var didEmitVisibleRemoved: Bool
            var didEmitAgentCleanupComplete: Bool
            var didEmitFullCleanupComplete: Bool
        }

        private struct SidebarDeleteEmission {
            let eventName: String
            let fields: [String: String]
        }

        package static var isEnabled: Bool {
            Recorder.isEnabled
        }

        static var defaultsEnabled: Bool {
            Recorder.defaultsEnabled
        }

        static var environmentEnabled: Bool {
            Recorder.environmentEnabled
        }

        static var debugProcessOverrideEnabled: Bool? {
            Recorder.debugProcessOverrideEnabled
        }

        static var osLogEnabled: Bool {
            Recorder.osLogEnabled
        }

        package static func timestampMSIfEnabled() -> Double? {
            Recorder.timestampMSIfEnabled()
        }

        static func timestampMS() -> Double {
            Recorder.timestampMS()
        }

        package static func elapsedMS(since startMS: Double) -> Double {
            Recorder.elapsedMS(since: startMS)
        }

        package static func formatMS(_ value: Double) -> String {
            Recorder.formatMS(value)
        }

        package static func formatElapsedMS(since startMS: Double) -> String {
            Recorder.formatElapsedMS(since: startMS)
        }

        package static func durationEvent(
            _ name: String,
            startMS: Double?,
            tabID: UUID? = nil,
            fields: [String: String] = [:]
        ) {
            var renderedFields = fields
            if let tabID {
                renderedFields["tabID"] = shortID(tabID)
            }
            Recorder.durationEvent(name, startMS: startMS, fields: renderedFields)
        }

        package static func counterKey(_ base: String, source: String?) -> String {
            let normalizedSource = source?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\t", with: "_")
            guard let normalizedSource, !normalizedSource.isEmpty else {
                return "\(base).source.unknown"
            }
            return "\(base).source.\(normalizedSource)"
        }

        package static func shortID(_ id: UUID?) -> String {
            Recorder.shortID(id)
        }

        package static func increment(_ key: String, tabID: UUID? = nil, by amount: Int = 1) {
            guard isEnabled else { return }
            Recorder.withLockedState { state in
                state.counters[key, default: 0] += amount
                if let tabID {
                    state.counters["\(key).tab.\(tabID.uuidString)", default: 0] += amount
                }
            }
        }

        package static func event(_ name: String, tabID: UUID? = nil, fields: [String: String] = [:]) {
            // `Recorder.event` performs the single enablement check.
            var renderedFields = fields
            if let tabID {
                renderedFields["tabID"] = shortID(tabID)
            }
            Recorder.event(name, fields: renderedFields)
        }

        static func recordConversationReplay(
            _ metrics: AgentConversationReplayMetrics,
            startMS: Double?
        ) {
            guard isEnabled else { return }
            var fields: [String: String] = [
                "mode": metrics.mode.rawValue,
                "turnCount": String(metrics.turnCount),
                "examinedRowCount": String(metrics.examinedRowCount),
                "unboundedOutputUTF8Bytes": String(metrics.unboundedOutputUTF8Bytes),
                "outputUTF8Bytes": String(metrics.outputUTF8Bytes),
                "userAuthoredUTF8Bytes": String(metrics.userAuthoredUTF8Bytes),
                "originalToolArgumentCharacters": String(metrics.originalToolArgumentCharacters),
                "emittedToolArgumentCharacters": String(metrics.emittedToolArgumentCharacters),
                "truncatedToolCallCount": String(metrics.truncatedToolCallCount),
                "omittedRowCount": String(metrics.omittedRowCount),
                "essentialOverflowUTF8Bytes": String(metrics.essentialOverflowUTF8Bytes),
                "finalOverBudgetUTF8Bytes": String(metrics.finalOverBudgetUTF8Bytes)
            ]
            for category in AgentConversationReplayCategory.allCases {
                let categoryMetrics = metrics.categories[category] ?? .init()
                fields["\(category.rawValue).examined"] = String(categoryMetrics.examinedCount)
                fields["\(category.rawValue).emitted"] = String(categoryMetrics.emittedCount)
                fields["\(category.rawValue).omitted"] = String(categoryMetrics.omittedCount)
                fields["\(category.rawValue).unboundedUTF8Bytes"] = String(categoryMetrics.unboundedUTF8Bytes)
                fields["\(category.rawValue).emittedUTF8Bytes"] = String(categoryMetrics.emittedUTF8Bytes)
            }
            durationEvent("conversationReplay.serialize", startMS: startMS, fields: fields)
            increment("conversationReplay.serialize.\(metrics.mode.rawValue)")
            increment("conversationReplay.truncatedToolCalls", by: metrics.truncatedToolCallCount)
            increment("conversationReplay.omittedRows", by: metrics.omittedRowCount)
            if metrics.essentialOverflowUTF8Bytes > 0 {
                increment("conversationReplay.essentialOverflow")
            }
        }

        package static func recordStoreUpdate(_ store: String, published: Bool, details: [String: String] = [:]) {
            guard isEnabled else { return }
            increment("store.\(store).called")
            increment("store.\(store).\(published ? "published" : "skipped")")
            var fields = details
            fields["store"] = store
            fields["published"] = String(published)
            event("store.update", fields: fields)
            if store.hasPrefix("sessionSidebar.attention.") {
                event(store, fields: fields)
            }
        }

        @discardableResult
        package static func beginSidebarDelete(_ context: SidebarDeleteBeginContext) -> UUID {
            let deleteID = UUID()
            guard isEnabled else { return deleteID }
            let pending = PendingSidebarDelete(
                deleteID: deleteID,
                tabID: context.tabID,
                sessionID: context.sessionID,
                startMS: timestampMS(),
                source: context.source,
                reason: context.reason,
                wasCurrentTab: context.wasCurrentTab,
                wasRunning: context.wasRunning,
                isMCPControlled: context.isMCPControlled,
                didEmitVisibleRemoved: false,
                didEmitAgentCleanupComplete: false,
                didEmitFullCleanupComplete: false
            )
            Recorder.withLockedState { _ in
                pendingSidebarDeleteByTabID[context.tabID] = pending
            }
            event("sidebar.delete.requested", fields: sidebarDeleteFields(for: pending))
            return deleteID
        }

        package static func markSidebarDeleteVisibleRemoved(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.visibleRemoved",
                durationEventName: "sidebar.delete.requestToVisible",
                duplicateEventName: "sidebar.delete.duplicateVisibleRemoved",
                orphanEventName: "sidebar.delete.orphanVisibleRemoved",
                markEmitted: { $0.didEmitVisibleRemoved = true },
                hasEmitted: { $0.didEmitVisibleRemoved }
            )
        }

        package static func markSidebarDeleteAgentCleanupComplete(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.agentCleanupComplete",
                durationEventName: "sidebar.delete.requestToAgentCleanup",
                duplicateEventName: "sidebar.delete.duplicateAgentCleanupComplete",
                orphanEventName: "sidebar.delete.orphanAgentCleanupComplete",
                markEmitted: { $0.didEmitAgentCleanupComplete = true },
                hasEmitted: { $0.didEmitAgentCleanupComplete }
            )
        }

        package static func markSidebarDeleteFullCleanupComplete(tabID: UUID, source: String, fields: [String: String] = [:]) {
            emitSidebarDeleteMilestone(
                tabID: tabID,
                source: source,
                fields: fields,
                milestoneEventName: "sidebar.delete.fullCleanupComplete",
                durationEventName: "sidebar.delete.requestToFullCleanup",
                duplicateEventName: "sidebar.delete.duplicateFullCleanupComplete",
                orphanEventName: "sidebar.delete.orphanFullCleanupComplete",
                markEmitted: { $0.didEmitFullCleanupComplete = true },
                hasEmitted: { $0.didEmitFullCleanupComplete }
            )
        }

        static func cancelSidebarDeleteTracking(tabID: UUID, source: String, fields: [String: String] = [:]) {
            guard isEnabled else { return }
            let pending: PendingSidebarDelete? = Recorder.withLockedState { _ in
                pendingSidebarDeleteByTabID.removeValue(forKey: tabID)
            }
            var eventFields = fields
            eventFields["source"] = source
            if let pending {
                event("sidebar.delete.cancelled", fields: sidebarDeleteFields(for: pending, extraFields: eventFields))
            } else {
                eventFields["tabID"] = tabID.uuidString
                event("sidebar.delete.orphanCancelled", fields: eventFields)
            }
        }

        package static func recordSessionSnapshot(tabID: UUID, fields: [String: Any]) {
            guard isEnabled else { return }
            let key = tabID.uuidString
            var snapshot = fields
            snapshot["tabID"] = key
            snapshot["shortTabID"] = shortID(tabID)
            snapshot["recordedAtMS"] = timestampMS()
            Recorder.withLockedState { _ in
                if latestSessionSnapshots[key] == nil {
                    latestSessionSnapshotOrder.append(key)
                }
                latestSessionSnapshots[key] = snapshot
                while latestSessionSnapshotOrder.count > sessionSnapshotLimit {
                    let staleKey = latestSessionSnapshotOrder.removeFirst()
                    latestSessionSnapshots.removeValue(forKey: staleKey)
                }
            }

            let stringFields = fields.reduce(into: [String: String]()) { partial, entry in
                partial[entry.key] = String(describing: entry.value)
            }
            event("memory.sessionSnapshot", tabID: tabID, fields: stringFields)
        }

        package static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            Recorder.setDebugProcessOverrideEnabled(enabled)
        }

        package static func clearRecentMetrics() {
            Recorder.withLockedState { state in
                state.recentMetricLines.removeAll(keepingCapacity: true)
                state.eventRecords.removeAll(keepingCapacity: true)
                state.nextEventSequence = 0
                state.droppedEventRecordCount = 0
                state.counters.removeAll(keepingCapacity: true)
                latestSessionSnapshots.removeAll(keepingCapacity: true)
                latestSessionSnapshotOrder.removeAll(keepingCapacity: true)
                pendingSidebarDeleteByTabID.removeAll(keepingCapacity: true)
            }
        }

        static func recentMetricLinesSnapshot(limit requestedLimit: Int) -> [String] {
            let limit = max(1, min(requestedLimit, bufferLimit))
            return Recorder.withLockedState { state in
                Array(state.recentMetricLines.suffix(limit))
            }
        }

        package static func debugStateSnapshot(lineLimit: Int) -> [String: Any] {
            let limit = max(1, min(lineLimit, bufferLimit))
            let (lines, countersSnapshot, sessionSnapshots, structuredCount, structuredDropped, pendingSidebarDeleteCount) =
                Recorder.withLockedState { state in
                    (
                        Array(state.recentMetricLines.suffix(limit)),
                        state.counters,
                        latestSessionSnapshots,
                        state.eventRecords.count,
                        state.droppedEventRecordCount,
                        pendingSidebarDeleteByTabID.count
                    )
                }
            return [
                "enabled": isEnabled,
                "defaults_enabled": defaultsEnabled,
                "environment_enabled": environmentEnabled,
                "process_override_enabled": debugProcessOverrideEnabled ?? NSNull(),
                "os_log_enabled": osLogEnabled,
                "line_count": lines.count,
                "buffer_limit": bufferLimit,
                "structured_event_count": structuredCount,
                "structured_event_limit": structuredEventLimit,
                "structured_event_dropped_count": structuredDropped,
                "session_snapshot_limit": sessionSnapshotLimit,
                "pending_sidebar_delete_count": pendingSidebarDeleteCount,
                "mcp_long_thread_baseline_inventory": MCPAgentLongThreadBaselineInventory.debugSnapshot,
                "lines": lines,
                "counters": countersSnapshot,
                "latest_session_snapshots": sessionSnapshots
            ]
        }

        package static func debugMetricSummarySnapshot(
            lineLimit requestedLineLimit: Int,
            startMark: String? = nil,
            endMark: String? = nil,
            eventNames: Set<String>? = nil
        ) -> [String: Any] {
            let trimmedStartMark = startMark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedEndMark = endMark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let eventNameFilter = eventNames.map { Set($0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
            let lineLimit = max(1, min(requestedLineLimit, bufferLimit))

            let (records, countersSnapshot, droppedCount) = Recorder.withLockedState { state in
                (state.eventRecords, state.counters, state.droppedEventRecordCount)
            }

            let windowResult = recordsInWindow(
                records,
                startMark: trimmedStartMark,
                endMark: trimmedEndMark
            )
            guard windowResult.ok else {
                let missingWindow: [String: Any] = [
                    "start_mark": anyOrNull(trimmedStartMark),
                    "end_mark": anyOrNull(trimmedEndMark),
                    "record_count": 0,
                    "buffer_truncated": droppedCount > 0
                ]
                return [
                    "ok": false,
                    "code": "missing_mark",
                    "missing_mark": anyOrNull(windowResult.missingMark),
                    "window": missingWindow,
                    "events": [String: Any](),
                    "counters": countersSnapshot,
                    "line_limit": lineLimit
                ]
            }

            let filteredRecords = windowResult.records.filter { record in
                guard let eventNameFilter, !eventNameFilter.isEmpty else { return true }
                return eventNameFilter.contains(record.name)
            }
            let groupedRecords = Dictionary(grouping: filteredRecords, by: \.name)
            let eventSummaries = groupedRecords.keys.sorted().reduce(into: [String: Any]()) { partial, name in
                partial[name] = summaryPayload(for: groupedRecords[name] ?? [])
            }

            let windowPayload: [String: Any] = [
                "start_mark": anyOrNull(trimmedStartMark),
                "end_mark": anyOrNull(trimmedEndMark),
                "start_sequence": anyOrNull(windowResult.startSequence),
                "end_sequence": anyOrNull(windowResult.endSequence),
                "record_count": windowResult.records.count,
                "filtered_record_count": filteredRecords.count,
                "oldest_retained_sequence": anyOrNull(records.first?.sequence),
                "newest_retained_sequence": anyOrNull(records.last?.sequence),
                "buffer_truncated": droppedCount > 0,
                "dropped_record_count": droppedCount
            ]
            let eventNamesFilterPayload: Any = eventNameFilter.map { Array($0).sorted() } ?? NSNull()
            return [
                "ok": true,
                "window": windowPayload,
                "events": eventSummaries,
                "counters": countersSnapshot,
                "event_names_filter": eventNamesFilterPayload,
                "line_limit": lineLimit
            ]
        }

        private struct MetricWindowResult {
            let ok: Bool
            let records: [AgentPerfEventRecord]
            let startSequence: Int?
            let endSequence: Int?
            let missingMark: String?
        }

        private static func recordsInWindow(
            _ records: [AgentPerfEventRecord],
            startMark: String?,
            endMark: String?
        ) -> MetricWindowResult {
            var lowerBoundSequence: Int?
            var upperBoundSequence: Int?
            if let startMark {
                guard let start = records.last(where: { isMark($0, named: startMark) }) else {
                    return MetricWindowResult(ok: false, records: [], startSequence: nil, endSequence: nil, missingMark: startMark)
                }
                lowerBoundSequence = start.sequence
                if let endMark {
                    guard let end = records.first(where: { $0.sequence > start.sequence && isMark($0, named: endMark) }) else {
                        return MetricWindowResult(ok: false, records: [], startSequence: start.sequence, endSequence: nil, missingMark: endMark)
                    }
                    upperBoundSequence = end.sequence
                }
            } else if let endMark {
                guard let end = records.first(where: { isMark($0, named: endMark) }) else {
                    return MetricWindowResult(ok: false, records: [], startSequence: nil, endSequence: nil, missingMark: endMark)
                }
                upperBoundSequence = end.sequence
            }

            let windowRecords = records.filter { record in
                if let lowerBoundSequence, record.sequence <= lowerBoundSequence { return false }
                if let upperBoundSequence, record.sequence > upperBoundSequence { return false }
                return true
            }
            return MetricWindowResult(
                ok: true,
                records: windowRecords,
                startSequence: lowerBoundSequence,
                endSequence: upperBoundSequence,
                missingMark: nil
            )
        }

        private static func isMark(_ record: AgentPerfEventRecord, named mark: String) -> Bool {
            record.name == "agent.metrics.mark" && record.fields["mark"] == mark
        }

        private static func summaryPayload(for records: [AgentPerfEventRecord]) -> [String: Any] {
            var durations: [Double] = []
            var malformedDurationCount = 0
            for record in records {
                guard let duration = record.fields["duration"] else { continue }
                if let parsed = parseDurationMS(duration) {
                    durations.append(parsed)
                } else {
                    malformedDurationCount += 1
                }
            }
            let sortedDurations = durations.sorted()
            let total = sortedDurations.reduce(0, +)
            return [
                "count": records.count,
                "duration_count": sortedDurations.count,
                "malformed_duration_count": malformedDurationCount,
                "median_ms": median(sortedDurations).map(roundedMS) ?? NSNull(),
                "p95_ms": nearestRankPercentile(sortedDurations, percentile: 0.95).map(roundedMS) ?? NSNull(),
                "max_ms": sortedDurations.last.map(roundedMS) ?? NSNull(),
                "total_ms": sortedDurations.isEmpty ? NSNull() : roundedMS(total),
                "first_sequence": records.first?.sequence ?? NSNull(),
                "last_sequence": records.last?.sequence ?? NSNull()
            ]
        }

        private static func median(_ sortedValues: [Double]) -> Double? {
            guard !sortedValues.isEmpty else { return nil }
            let midpoint = sortedValues.count / 2
            if sortedValues.count.isMultiple(of: 2) {
                return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2.0
            }
            return sortedValues[midpoint]
        }

        private static func nearestRankPercentile(_ sortedValues: [Double], percentile: Double) -> Double? {
            guard !sortedValues.isEmpty else { return nil }
            let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
            let clamped = min(max(rank, 0), sortedValues.count - 1)
            return sortedValues[clamped]
        }

        private static func roundedMS(_ value: Double) -> Double {
            (value * 10.0).rounded() / 10.0
        }

        private static func parseDurationMS(_ raw: String) -> Double? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let numeric = trimmed.hasSuffix("ms") ? String(trimmed.dropLast(2)) : trimmed
            guard let value = Double(numeric), value.isFinite else { return nil }
            return value
        }

        private static func anyOrNull(_ value: (some Any)?) -> Any {
            value.map { $0 as Any } ?? NSNull()
        }

        private static func emitSidebarDeleteMilestone(
            tabID: UUID,
            source: String,
            fields: [String: String],
            milestoneEventName: String,
            durationEventName: String,
            duplicateEventName: String,
            orphanEventName: String,
            markEmitted: (inout PendingSidebarDelete) -> Void,
            hasEmitted: (PendingSidebarDelete) -> Bool
        ) {
            guard isEnabled else { return }
            let nowMS = timestampMS()
            let emissions: [SidebarDeleteEmission] = Recorder.withLockedState { _ in
                if var pending = pendingSidebarDeleteByTabID[tabID] {
                    if hasEmitted(pending) {
                        return [
                            SidebarDeleteEmission(
                                eventName: duplicateEventName,
                                fields: sidebarDeleteFields(for: pending, extraFields: fields.merging(["source": source]) { _, new in new })
                            )
                        ]
                    }
                    markEmitted(&pending)
                    if pending.didEmitVisibleRemoved, pending.didEmitFullCleanupComplete {
                        pendingSidebarDeleteByTabID.removeValue(forKey: tabID)
                    } else {
                        pendingSidebarDeleteByTabID[tabID] = pending
                    }
                    var milestoneFields = fields
                    milestoneFields["source"] = source
                    var durationFields = milestoneFields
                    durationFields["duration"] = formatMS(nowMS - pending.startMS)
                    return [
                        SidebarDeleteEmission(
                            eventName: milestoneEventName,
                            fields: sidebarDeleteFields(for: pending, extraFields: milestoneFields)
                        ),
                        SidebarDeleteEmission(
                            eventName: durationEventName,
                            fields: sidebarDeleteFields(for: pending, extraFields: durationFields)
                        )
                    ]
                }
                var orphanFields = fields
                orphanFields["tabID"] = tabID.uuidString
                orphanFields["source"] = source
                return [SidebarDeleteEmission(eventName: orphanEventName, fields: orphanFields)]
            }

            for emission in emissions {
                event(emission.eventName, fields: emission.fields)
            }
        }

        private static func sidebarDeleteFields(
            for pending: PendingSidebarDelete,
            extraFields: [String: String] = [:]
        ) -> [String: String] {
            var fields = extraFields
            fields["deleteID"] = pending.deleteID.uuidString
            fields["tabID"] = pending.tabID.uuidString
            fields["shortTabID"] = shortID(pending.tabID)
            fields["sessionID"] = pending.sessionID?.uuidString ?? "nil"
            fields["shortSessionID"] = shortID(pending.sessionID)
            fields["requestSource"] = pending.source
            fields["reason"] = pending.reason ?? "nil"
            fields["wasCurrentTab"] = String(pending.wasCurrentTab)
            fields["wasRunning"] = String(pending.wasRunning)
            fields["isMCPControlled"] = String(pending.isMCPControlled)
            return fields
        }
    }

    private extension String {
        var nilIfEmpty: String? {
            isEmpty ? nil : self
        }
    }
#endif
