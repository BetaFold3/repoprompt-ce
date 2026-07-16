import Foundation

enum AgentSessionTitleNaming {
    private static let defaultPlaceholderTitles: Set<String> = [
        "Agent Session",
        "New Chat",
        "New Session"
    ]

    static func isDefaultSessionTitle(_ title: String?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || defaultPlaceholderTitles.contains(trimmed) {
            return true
        }
        guard trimmed.count >= 2 else { return false }
        let prefix = trimmed.prefix(1)
        guard prefix == "T" || prefix == "t" else { return false }
        return trimmed.dropFirst().allSatisfy(\.isNumber)
    }

    static func sessionNameForRemoteStart(currentTitle: String, userText: String) -> String {
        if isDefaultSessionTitle(currentTitle),
           let derived = derivedSessionName(from: userText)
        {
            return derived
        }
        return AgentSession.validatedName(currentTitle)
    }

    static func derivedSessionName(from userText: String, maxLength: Int = 40) -> String? {
        guard maxLength > 0 else { return nil }
        let firstLine = userText.components(separatedBy: .newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.count <= maxLength {
            candidate = trimmed
        } else {
            let maxIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
            let prefix = String(trimmed[..<maxIndex])
            if let boundary = prefix.lastIndex(where: { $0.isWhitespace }),
               boundary > prefix.startIndex
            {
                candidate = String(prefix[..<boundary])
            } else {
                candidate = prefix
            }
        }

        let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateTrimmed.isEmpty else { return nil }
        let validated = AgentSession.validatedName(candidateTrimmed)
        return validated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : validated
    }
}
