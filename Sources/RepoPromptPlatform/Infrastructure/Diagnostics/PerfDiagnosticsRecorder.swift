import Foundation

#if DEBUG
    import os

    /// Debug-only, opt-in recording mechanism behind `AgentModePerfDiagnostics`: enablement,
    /// timestamps, duration formatting, and event/counter emission into bounded in-memory
    /// buffers (optionally mirrored to os_log). Domain instrumentation and reporting live with
    /// their owners; this type has no app-domain dependencies.
    ///
    /// Enable in debug builds with either:
    /// - `defaults write com.repoprompt.RepoPrompt enableAgentModePerfDiagnostics -bool YES`
    /// - `RP_AGENT_MODE_PERF_DIAGNOSTICS=1`
    /// - a process override via `setDebugProcessOverrideEnabled(_:)`
    package enum PerfDiagnosticsRecorder {
        package struct EventRecord {
            package let sequence: Int
            package let timestampMS: Double
            package let name: String
            package let fields: [String: String]
        }

        /// Recorder buffers. Only read or mutate inside `withLockedState(_:)`.
        package struct State {
            package var processOverrideEnabled: Bool?
            package var recentMetricLines: [String] = []
            package var eventRecords: [EventRecord] = []
            package var nextEventSequence = 0
            package var droppedEventRecordCount = 0
            package var counters: [String: Int] = [:]
        }

        package static let bufferLimit = 1000
        package static let structuredEventLimit = 5000

        private static let logger = Logger(subsystem: "com.repoprompt.agent-perf", category: "agent-mode")
        private static let defaultsKey = "enableAgentModePerfDiagnostics"
        private static let environmentKey = "RP_AGENT_MODE_PERF_DIAGNOSTICS"
        private static let osLogDefaultsKey = "emitAgentModePerfDiagnosticsToOSLog"
        private static let osLogEnvironmentKey = "RP_AGENT_MODE_PERF_OSLOG"
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let lock = NSLock()
        private nonisolated(unsafe) static var state = State()

        /// Runs `body` while holding the recorder lock. The lock is not recursive: `body` must not
        /// call other locking `PerfDiagnosticsRecorder` members. Callers may also use it to guard
        /// their own diagnostic state atomically with the recorder buffers.
        package static func withLockedState<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }

        package static var isEnabled: Bool {
            if let override = debugProcessOverrideEnabled {
                return override
            }
            return defaultsEnabled || environmentEnabled
        }

        package static var defaultsEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        package static var environmentEnabled: Bool {
            environmentFlagEnabled(environmentKey)
        }

        package static var debugProcessOverrideEnabled: Bool? {
            withLockedState { $0.processOverrideEnabled }
        }

        package static var osLogEnabled: Bool {
            UserDefaults.standard.bool(forKey: osLogDefaultsKey) || environmentFlagEnabled(osLogEnvironmentKey)
        }

        package static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            withLockedState { $0.processOverrideEnabled = enabled }
        }

        package static func timestampMSIfEnabled() -> Double? {
            guard isEnabled else { return nil }
            return timestampMS()
        }

        package static func timestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        package static func elapsedMS(since startMS: Double) -> Double {
            timestampMS() - startMS
        }

        package static func formatMS(_ value: Double) -> String {
            String(format: "%.1fms", value)
        }

        package static func formatElapsedMS(since startMS: Double) -> String {
            formatMS(elapsedMS(since: startMS))
        }

        package static func shortID(_ id: UUID?) -> String {
            id?.uuidString.prefix(8).description ?? "nil"
        }

        package static func durationEvent(
            _ name: String,
            startMS: Double?,
            fields: [String: String] = [:]
        ) {
            guard let startMS else { return }
            var renderedFields = fields
            renderedFields["duration"] = formatElapsedMS(since: startMS)
            event(name, fields: renderedFields)
        }

        package static func event(_ name: String, fields: [String: String] = [:]) {
            guard isEnabled else { return }
            let timestamp = timestampMS()
            let renderedMessage = renderEvent(name, fields: fields)
            withLockedState { state in
                state.counters["event.\(name)", default: 0] += 1
                appendRecentMetricLine(renderedMessage, timestampMS: timestamp, to: &state)
                appendEventRecord(
                    EventRecord(
                        sequence: state.nextEventSequence,
                        timestampMS: timestamp,
                        name: name,
                        fields: fields
                    ),
                    to: &state
                )
                state.nextEventSequence &+= 1
            }
            if osLogEnabled {
                logger.debug("\(renderedMessage, privacy: .public)")
            }
        }

        private static func environmentFlagEnabled(_ key: String) -> Bool {
            let rawValue = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
        }

        private static func appendRecentMetricLine(_ message: String, timestampMS: Double, to state: inout State) {
            let line = "t+\(formatMS(timestampMS)) \(message)"
            state.recentMetricLines.append(line)
            if state.recentMetricLines.count > bufferLimit {
                state.recentMetricLines.removeFirst(state.recentMetricLines.count - bufferLimit)
            }
        }

        private static func appendEventRecord(_ record: EventRecord, to state: inout State) {
            state.eventRecords.append(record)
            if state.eventRecords.count > structuredEventLimit {
                let dropCount = state.eventRecords.count - structuredEventLimit
                state.eventRecords.removeFirst(dropCount)
                state.droppedEventRecordCount += dropCount
            }
        }

        private static func renderEvent(_ name: String, fields: [String: String]) -> String {
            guard !fields.isEmpty else { return name }
            let suffix = fields.keys.sorted().map { key in
                "\(key)=\(sanitize(fields[key] ?? ""))"
            }.joined(separator: " ")
            return "\(name) \(suffix)"
        }

        private static func sanitize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: " ", with: "_")
        }
    }
#endif
