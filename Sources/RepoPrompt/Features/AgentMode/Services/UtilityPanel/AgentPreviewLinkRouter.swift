import Foundation

/// Extracts user-facing workspace paths from links emitted for the secure Preview web view.
enum AgentPreviewLinkRouter {
    static func transcriptFileURL(for path: String) -> URL? {
        ReservedTranscriptFileURLCodec.makeURL(path: path)
    }

    static func isTranscriptFileURL(_ url: URL) -> Bool {
        ReservedTranscriptFileURLCodec.isReservedURL(url)
    }

    static func transcriptFileTarget(from url: URL) -> MarkdownFileLinkTarget? {
        guard let path = ReservedTranscriptFileURLCodec.path(from: url) else { return nil }
        return MarkdownFileLinkTarget.detectedFilePath(path)
    }

    static func candidateFilePath(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(RepoPreviewURLScheme.scheme) == .orderedSame else {
            return nil
        }

        if isTranscriptFileURL(url) {
            return ReservedTranscriptFileURLCodec.path(from: url)
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
