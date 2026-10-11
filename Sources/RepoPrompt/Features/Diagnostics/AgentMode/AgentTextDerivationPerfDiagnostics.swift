import Foundation
import RepoPromptAgentCore

#if DEBUG
    /// Debug-only wrappers for Agent Mode transcript/code text derivation metrics.
    ///
    /// This helper centralizes source names and low-cardinality fields for the
    /// instrumentation-only high-CPU loop. It is compiled out of release builds.
    enum AgentTextDerivationPerfDiagnostics {
        enum Source: String {
            case assistantCollapseCheck
            case assistantPreview
            case toolResultPreview
            case diffPreview
            case collapsibleCodeBlock
            case scrollableCodeHeight
            case toolResultJSONPrettyPrint
        }

        static func start() -> Double? {
            AgentModePerfDiagnostics.timestampMSIfEnabled()
        }

        static func record(
            source: Source,
            startMS: Double?,
            text: String? = nil,
            utf8Bytes: Int? = nil,
            lineCount: Int? = nil,
            previewLineCount: Int? = nil,
            displayedLineCount: Int? = nil,
            remainingLineCount: Int? = nil,
            needsCollapse: Bool? = nil,
            expanded: Bool? = nil,
            toolName: String? = nil,
            isDiff: Bool? = nil,
            isJSON: Bool? = nil,
            didSplitFullArray: Bool? = nil,
            fields: [String: String] = [:]
        ) {
            guard let startMS else { return }
            var payload = fields
            if let text {
                payload["utf8Bytes"] = String(text.utf8.count)
            } else if let utf8Bytes {
                payload["utf8Bytes"] = String(utf8Bytes)
            }
            set(lineCount, for: "lineCount", in: &payload)
            set(previewLineCount, for: "previewLineCount", in: &payload)
            set(displayedLineCount, for: "displayedLineCount", in: &payload)
            set(remainingLineCount, for: "remainingLineCount", in: &payload)
            set(needsCollapse, for: "needsCollapse", in: &payload)
            set(expanded, for: "expanded", in: &payload)
            set(isDiff, for: "isDiff", in: &payload)
            set(isJSON, for: "isJSON", in: &payload)
            set(didSplitFullArray, for: "didSplitFullArray", in: &payload)
            if let toolName {
                payload["toolName"] = normalizedToolName(toolName)
            }
            AgentModePerfDiagnostics.durationEvent(
                eventName(for: source),
                startMS: startMS,
                fields: payload
            )
        }

        private static func eventName(for source: Source) -> String {
            switch source {
            case .assistantCollapseCheck:
                "transcript.lineDerivation.assistantCollapseCheck"
            case .assistantPreview:
                "transcript.lineDerivation.assistantPreview"
            case .toolResultPreview:
                "transcript.lineDerivation.toolResultPreview"
            case .diffPreview:
                "transcript.lineDerivation.diffPreview"
            case .collapsibleCodeBlock:
                "transcript.lineDerivation.collapsibleCodeBlock"
            case .scrollableCodeHeight:
                "transcript.lineDerivation.scrollableCodeHeight"
            case .toolResultJSONPrettyPrint:
                "transcript.prettyPrintJSON.toolResult"
            }
        }

        private static func set(_ value: Int?, for key: String, in payload: inout [String: String]) {
            guard let value else { return }
            payload[key] = String(value)
        }

        private static func set(_ value: Bool?, for key: String, in payload: inout [String: String]) {
            guard let value else { return }
            payload[key] = String(value)
        }

        private static func normalizedToolName(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "nil" }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? Character(scalar) : "_"
            }
            let normalized = String(scalars).prefix(48)
            return normalized.isEmpty ? "unknown" : String(normalized)
        }
    }
#endif
