import Foundation
import RepoPromptPlatform

/// Selected-files/projection diagnostics emitted as `selectedFiles.<name>` events through
/// `PerfDiagnosticsRecorder`. These helpers depend on no agent or MCP types so workspace code
/// can use them; agent-typed field helpers live in an App extension.
enum AgentSelectedFilesDiagnostics {
    static func timestampMSIfEnabled() -> Double? {
        #if DEBUG
            PerfDiagnosticsRecorder.timestampMSIfEnabled()
        #else
            nil
        #endif
    }

    static func elapsedFields(since startMS: Double?) -> [String: String] {
        #if DEBUG
            guard let startMS else { return [:] }
            return ["duration": PerfDiagnosticsRecorder.formatElapsedMS(since: startMS)]
        #else
            [:]
        #endif
    }

    static func event(
        _ name: String,
        fields: [String: String] = [:],
        includeStack: Bool = false
    ) {
        #if DEBUG
            guard PerfDiagnosticsRecorder.isEnabled else { return }
            var fields = fields
            if includeStack {
                fields["stack"] = compactCallStack()
            }
            PerfDiagnosticsRecorder.event("selectedFiles.\(name)", fields: fields)
        #endif
    }

    static func durationEvent(
        _ name: String,
        startMS: Double?,
        fields: [String: String] = [:]
    ) {
        #if DEBUG
            PerfDiagnosticsRecorder.durationEvent("selectedFiles.\(name)", startMS: startMS, fields: fields)
        #endif
    }

    static func shortID(_ id: UUID?) -> String {
        #if DEBUG
            PerfDiagnosticsRecorder.shortID(id)
        #else
            "nil"
        #endif
    }

    private static func compactCallStack() -> String {
        Thread.callStackSymbols
            .dropFirst(3)
            .prefix(10)
            .map { symbol in
                symbol
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: " <- ")
    }
}
