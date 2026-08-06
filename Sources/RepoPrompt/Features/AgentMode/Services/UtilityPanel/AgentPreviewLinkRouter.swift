import Foundation

/// Extracts user-facing workspace paths from links emitted for the secure Preview web view.
enum AgentPreviewLinkRouter {
    static func candidateFilePath(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(RepoPreviewURLScheme.scheme) == .orderedSame else {
            return nil
        }

        let encodedPath = url.path(percentEncoded: true)
        let encodedCandidate = if let host = url.host(percentEncoded: true), !host.isEmpty {
            "/" + host + encodedPath
        } else {
            encodedPath
        }

        guard let candidate = encodedCandidate.removingPercentEncoding, !candidate.isEmpty else {
            return nil
        }
        return candidate
    }
}
