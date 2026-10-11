#if DEBUG
    import Foundation

    /// Debug-only, opt-in instrumentation for app-wide font scaling hot paths.
    ///
    /// Enable through the hidden MCP diagnostics op:
    /// `__repoprompt_debug_diagnostics` with `{ "op": "font_scale_metrics", "enable": true }`.
    ///
    /// This file is compiled behind `#if DEBUG`, and call sites are also wrapped in
    /// `#if DEBUG` so release builds have no font-scaling instrumentation footprint.
    package enum FontScalePerfDiagnostics {
        private static let defaultsKey = "enableFontScalePerfDiagnostics"
        private static let environmentKey = "RP_FONT_SCALE_PERF_DIAGNOSTICS"
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let bufferLimit = 1000
        private static let bufferLock = NSLock()
        private static var processOverrideEnabled: Bool?
        private static var hotPathEnabled = defaultsEnabled || environmentEnabled
        private static var baselineTimestampMS = timestampMS()
        private static var recentMetricLines: [String] = []
        private static var counters: [String: Int] = [:]

        static var isEnabled: Bool {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return hotPathEnabled
        }

        static var defaultsEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        static var environmentEnabled: Bool {
            let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
        }

        static var debugProcessOverrideEnabled: Bool? {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return processOverrideEnabled
        }

        package static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            let resolvedEnabled = enabled ?? (defaultsEnabled || environmentEnabled)
            let now = timestampMS()
            bufferLock.lock()
            let wasEnabled = hotPathEnabled
            processOverrideEnabled = enabled
            hotPathEnabled = resolvedEnabled
            if resolvedEnabled, !wasEnabled {
                baselineTimestampMS = now
            }
            bufferLock.unlock()
        }

        package static func clearRecentMetrics() {
            let now = timestampMS()
            bufferLock.lock()
            baselineTimestampMS = now
            recentMetricLines.removeAll(keepingCapacity: true)
            counters.removeAll(keepingCapacity: true)
            bufferLock.unlock()
        }

        static func increment(_ key: String, by amount: Int = 1) {
            bufferLock.lock()
            guard hotPathEnabled else {
                bufferLock.unlock()
                return
            }
            incrementLocked(key, by: amount)
            bufferLock.unlock()
        }

        static func recordHelper(_ name: String, preset: FontScalePreset? = nil) {
            bufferLock.lock()
            guard hotPathEnabled else {
                bufferLock.unlock()
                return
            }
            incrementLocked("helper.\(name)")
            if let preset {
                incrementLocked("helper.\(name).preset.\(preset.debugMetricsName)")
            }
            bufferLock.unlock()
        }

        package static func event(_ name: String, fields: [String: String] = [:]) {
            bufferLock.lock()
            guard hotPathEnabled else {
                bufferLock.unlock()
                return
            }
            let renderedMessage = renderEvent(name, fields: fields)
            incrementLocked("event.\(name)")
            appendRecentMetricLineLocked(renderedMessage)
            bufferLock.unlock()
        }

        package static func debugStateSnapshot(
            lineLimit: Int,
            currentPreset: FontScalePreset,
            managerPreset: FontScalePreset?,
            managerIsFrozen: Bool?
        ) -> [String: Any] {
            let limit = max(1, min(lineLimit, bufferLimit))
            bufferLock.lock()
            let lines = Array(recentMetricLines.suffix(limit))
            let countersSnapshot = counters
            let override = processOverrideEnabled
            let enabled = hotPathEnabled
            bufferLock.unlock()

            var payload: [String: Any] = [
                "enabled": enabled,
                "defaults_enabled": defaultsEnabled,
                "environment_enabled": environmentEnabled,
                "process_override_enabled": override ?? NSNull(),
                "line_count": lines.count,
                "buffer_limit": bufferLimit,
                "lines": lines,
                "counters": countersSnapshot,
                "current_preset": presetPayload(currentPreset)
            ]
            if let managerPreset {
                payload["manager_preset"] = presetPayload(managerPreset)
            }
            if let managerIsFrozen {
                payload["manager_is_frozen"] = managerIsFrozen
            }
            return payload
        }

        private static func incrementLocked(_ key: String, by amount: Int = 1) {
            counters[key, default: 0] += amount
        }

        private static func appendRecentMetricLineLocked(_ message: String) {
            let elapsedMS = timestampMS() - baselineTimestampMS
            let line = "t+\(formatMS(elapsedMS)) \(message)"
            recentMetricLines.append(line)
            if recentMetricLines.count > bufferLimit {
                recentMetricLines.removeFirst(recentMetricLines.count - bufferLimit)
            }
        }

        private static func timestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        private static func formatMS(_ value: Double) -> String {
            String(format: "%.1fms", value)
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

        private static func presetPayload(_ preset: FontScalePreset) -> [String: Any] {
            [
                "name": preset.debugMetricsName,
                "display_name": preset.displayName,
                "raw_value": preset.rawValue
            ]
        }
    }

    private extension FontScalePreset {
        var debugMetricsName: String {
            String(describing: self)
        }
    }
#endif
