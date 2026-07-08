import Foundation

/// User-facing execution host choice for a new Agent Mode run.
/// `.host` is a pre-start binding to a paired remote host; once a remote
/// session starts, the persisted `AgentSessionRemoteHostBinding` remains the
/// source of truth.
enum AgentRunLocation: Codable, Equatable, Hashable {
    case thisMac
    case host(hostID: String)

    var isHost: Bool {
        if case .host = self { return true }
        return false
    }
}

struct AgentRunLocationHostOption: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let abbreviation: String

    init(id: String, displayName: String, abbreviation: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.abbreviation = abbreviation ?? Self.abbreviations(for: [(id: id, displayName: displayName)])[id] ?? ""
    }

    static func abbreviations(for hosts: [(id: String, displayName: String)]) -> [String: String] {
        let entries = hosts.map(AbbreviationEntry.init)
        let groupedByBase = Dictionary(grouping: entries, by: \.base)
        var abbreviations: [String: String] = [:]

        for group in groupedByBase.values {
            if group.count == 1, let entry = group.first {
                abbreviations[entry.id] = entry.base
                continue
            }
            abbreviations.merge(disambiguatedAbbreviations(for: group)) { current, _ in current }
        }

        return abbreviations
    }

    private struct AbbreviationEntry {
        let id: String
        let displayName: String
        let base: String
        let lastToken: String
        let consumedLastTokenCharacters: Int

        init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName

            let tokens = Self.tokens(in: displayName)
            switch tokens.count {
            case let count where count >= 2:
                // Display policy: primary initials are uppercase for visual
                // labels, while collision extensions and ID suffixes remain
                // lowercase/readable additions (for example, "MSaa").
                base = (Self.prefix(tokens[0], count: 1) + Self.prefix(tokens[1], count: 1)).uppercased()
                lastToken = tokens[count - 1].lowercased()
                consumedLastTokenCharacters = count == 2 ? 1 : 0
            case 1:
                base = Self.prefix(tokens[0], count: 2).uppercased()
                lastToken = tokens[0].lowercased()
                consumedLastTokenCharacters = min(2, tokens[0].count)
            default:
                base = Self.prefix(id, count: 2).uppercased()
                lastToken = id.lowercased()
                consumedLastTokenCharacters = min(2, id.count)
            }
        }

        func lastTokenExtension(length: Int) -> String {
            guard length > 0,
                  consumedLastTokenCharacters < lastToken.count
            else { return "" }
            return String(lastToken.dropFirst(consumedLastTokenCharacters).prefix(length))
        }

        private static func tokens(in displayName: String) -> [String] {
            displayName
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }

        private static func prefix(_ value: String, count: Int) -> String {
            String(value.prefix(count))
        }
    }

    private static func disambiguatedAbbreviations(for group: [AbbreviationEntry]) -> [String: String] {
        let displayNameCounts = Dictionary(grouping: group, by: \.displayName).mapValues { $0.count }
        let duplicateDisplayNames = Set(displayNameCounts.filter { $0.value > 1 }.map(\.key))
        let sortedGroup = group.sorted { lhs, rhs in
            if lhs.displayName == rhs.displayName { return lhs.id < rhs.id }
            return lhs.displayName < rhs.displayName
        }
        var candidates: [String: String] = [:]
        var reservedCandidates = Set<String>()

        for entry in sortedGroup where duplicateDisplayNames.contains(entry.displayName) {
            let candidate = entry.base + idSuffix(for: entry.id, count: 2)
            candidates[entry.id] = candidate
            reservedCandidates.insert(candidate)
        }

        let uniqueDisplayNameEntries = sortedGroup.filter { !duplicateDisplayNames.contains($0.displayName) }
        if !uniqueDisplayNameEntries.isEmpty {
            let maxExtensionLength = uniqueDisplayNameEntries
                .map { max(0, $0.lastToken.count - $0.consumedLastTokenCharacters) }
                .max() ?? 0
            var resolved: [String: String]?

            if maxExtensionLength > 0 {
                for extensionLength in 1 ... maxExtensionLength {
                    let attempted = Dictionary(
                        uniqueKeysWithValues: uniqueDisplayNameEntries.map { entry in
                            (entry.id, entry.base + entry.lastTokenExtension(length: extensionLength))
                        }
                    )
                    let values = Array(attempted.values)
                    if Set(values).count == values.count,
                       reservedCandidates.isDisjoint(with: values)
                    {
                        resolved = attempted
                        break
                    }
                }
            }

            let fallback = fallbackAbbreviations(
                for: uniqueDisplayNameEntries,
                extensionLength: maxExtensionLength,
                reservedCandidates: reservedCandidates
            )
            candidates.merge(resolved ?? fallback) { current, _ in current }
        }

        return candidates
    }

    private static func fallbackAbbreviations(
        for entries: [AbbreviationEntry],
        extensionLength: Int,
        reservedCandidates: Set<String>
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        var usedCandidates = reservedCandidates

        for entry in entries {
            var suffixLength = 2
            var candidate: String
            repeat {
                candidate = entry.base
                    + entry.lastTokenExtension(length: extensionLength)
                    + idSuffix(for: entry.id, count: suffixLength)
                suffixLength += 1
            } while usedCandidates.contains(candidate) && suffixLength <= entry.id.count + 1

            resolved[entry.id] = candidate
            usedCandidates.insert(candidate)
        }

        return resolved
    }

    private static func idSuffix(for id: String, count: Int) -> String {
        String(id.prefix(count)).lowercased()
    }
}
