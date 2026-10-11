import Foundation

enum ClaudeAbortArtifactFilter {
    static func shouldSuppressUserFacingError(_ message: String) -> Bool {
        let lowered = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowered.isEmpty else { return false }

        if lowered.contains("json parse error") || lowered.contains("syntaxerror") {
            if lowered.contains("unrecognized token '/'")
                || lowered.contains("/$bunfs/root/src/entrypoints/cli.js")
                || lowered.contains("entrypoints/cli.js")
                || lowered.contains("at <parse>")
                || lowered.contains("at parse")
            {
                return true
            }
        }
        if lowered.contains("non-fatal") && lowered.contains("lock acquisition failed") {
            return true
        }
        if lowered.contains("aborterror")
            || lowered.contains("the operation was aborted")
            || lowered.contains("request was aborted")
        {
            return true
        }
        if lowered.hasPrefix("[ede_diagnostic]")
            || lowered.contains("internal diagnostic:")
        {
            return true
        }
        return false
    }
}
