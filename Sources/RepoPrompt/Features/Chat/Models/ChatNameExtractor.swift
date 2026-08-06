import Foundation

/// Extracts the optional chat-name marker from assistant responses.
enum ChatNameExtractor {
    /// Returns the first usable chat name while removing every recognized marker artifact.
    /// Malformed marker-shaped lines are removed without consuming surrounding response lines.
    /// Must only be called on terminal content; malformed-marker recovery is not idempotent on partial buffers.
    static func extractAndRemove(from content: inout String) -> String? {
        let validPattern = #"<chatName\s*=\s*(?:"([^"\r\n]*)"|([^>"\s]+))\s*(?:/?)>"#
        // Deliberately line-anchored: a line starting with `<chatName` is removed whole,
        // including trailing prose, while malformed markers occurring mid-line are left unchanged.
        let malformedLinePattern = #"(?m)^[\t ]*<chatName\b[^\r\n]*"#
        guard let validRegex = try? NSRegularExpression(pattern: validPattern),
              let malformedRegex = try? NSRegularExpression(pattern: malformedLinePattern)
        else {
            return nil
        }

        var extractedName: String?
        while !content.isEmpty {
            let fullRange = NSRange(location: 0, length: content.utf16.count)
            let validMatch = validRegex.firstMatch(in: content, range: fullRange)
            let malformedMatch = malformedRegex.firstMatch(in: content, range: fullRange)

            let validPrecedesMalformed = validMatch.map { valid in
                malformedMatch.map { valid.range.location <= $0.range.location } ?? true
            } ?? false
            if let validMatch, validPrecedesMalformed {
                guard let markerRange = Range(validMatch.range, in: content) else { break }
                if extractedName == nil {
                    extractedName = capturedName(from: validMatch, in: content)
                }
                content.removeSubrange(markerRange)
                continue
            }

            guard let malformedMatch,
                  let markerRange = Range(malformedMatch.range, in: content)
            else {
                break
            }
            if extractedName == nil {
                extractedName = recoverName(fromMalformedMarker: String(content[markerRange]))
            }
            content.removeSubrange(markerRange)
        }
        return extractedName
    }

    private static func capturedName(
        from match: NSTextCheckingResult,
        in content: String
    ) -> String? {
        for captureIndex in 1 ... 2 {
            guard let range = Range(match.range(at: captureIndex), in: content) else {
                continue
            }
            let name = content[range].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func recoverName(fromMalformedMarker marker: String) -> String? {
        guard let tagRange = marker.range(of: "<chatName") else { return nil }

        var payload = String(marker[tagRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.first == "=" else { return nil }

        payload.removeFirst()
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        if payload.first == "\"" {
            payload.removeFirst()
            let name = if let closingQuote = payload.firstIndex(of: "\"") {
                String(payload[..<closingQuote])
            } else {
                payload.trimmingCharacters(in: CharacterSet(charactersIn: "/> "))
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let name = payload.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/>"))
        )
        return name.isEmpty ? nil : name
    }
}
