import Foundation

enum MCPClientIdentity {
    private static let separatorCharacters = CharacterSet(charactersIn: " -_./")

    /// Namespace prefix for remote gateway device client identities (plan §6.5).
    /// Each paired device gets its own identity: `remote:<device8>`.
    static let remoteClientPrefix = "remote:"

    /// Explicit all-remote-devices wildcard identity. A stored policy only ever
    /// matches every remote device when it is exactly this value — per-device
    /// identities never widen to other devices implicitly.
    static let remoteAllDevicesWildcard = "remote:*"

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(separatorCharacters.contains)
    }

    private static func matchesFamily(_ normalized: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        var remainder = normalized[...]
        for (index, token) in tokens.enumerated() {
            guard remainder.hasPrefix(token) else { return false }
            remainder.removeFirst(token.count)
            guard index < tokens.count - 1 else { continue }
            while let next = remainder.first, isSeparator(next) {
                remainder.removeFirst()
            }
        }

        guard !remainder.isEmpty else { return true }
        guard let boundary = remainder.first, isSeparator(boundary) else { return false }
        while let next = remainder.first, isSeparator(next) {
            remainder.removeFirst()
        }
        guard let suffixStart = remainder.first else { return true }
        return suffixStart.isNumber || suffixStart == "v"
    }

    /// Extracts the device identifier from a `remote:<device8>` client identity.
    /// Returns `nil` for non-remote identities and for the `remote:*` wildcard.
    static func remoteDeviceID(from raw: String?) -> String? {
        guard let normalized = normalized(raw),
              normalized.hasPrefix(remoteClientPrefix)
        else { return nil }
        let deviceID = String(normalized.dropFirst(remoteClientPrefix.count))
        guard !deviceID.isEmpty, deviceID != "*" else { return nil }
        return deviceID
    }

    /// Whether the identity belongs to the remote gateway device namespace
    /// (`remote:<device8>` or the explicit `remote:*` wildcard).
    static func isRemoteClient(_ raw: String?) -> Bool {
        guard let normalized = normalized(raw) else { return false }
        return normalized.hasPrefix(remoteClientPrefix)
            && normalized.count > remoteClientPrefix.count
    }

    static func canonicalFamilyID(_ raw: String?) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        // Remote device identities never form a client family: policy for one
        // device must not approve another device (plan §6.5).
        if normalized.hasPrefix(remoteClientPrefix) { return nil }
        if matchesFamily(normalized, tokens: ["claude", "code"]) { return "claude-code" }
        if matchesFamily(normalized, tokens: ["codex", "mcp", "client"]) { return "codex-mcp-client" }
        if matchesFamily(normalized, tokens: ["gemini", "cli", "mcp", "client"])
            || matchesFamily(normalized, tokens: ["gemini", "cli"])
        {
            return "gemini-cli-mcp-client"
        }
        if matchesFamily(normalized, tokens: ["cursor", "mcp", "client"])
            || matchesFamily(normalized, tokens: ["cursor", "agent"])
            || matchesFamily(normalized, tokens: ["cursor"])
        {
            return "cursor"
        }
        if matchesFamily(normalized, tokens: ["claude", "ai"]) { return "claude-ai" }
        if matchesFamily(normalized, tokens: ["repoprompt", "cli"]) { return "repoprompt-cli" }
        return nil
    }

    static func storageKey(_ raw: String?) -> String? {
        canonicalFamilyID(raw) ?? normalized(raw)
    }

    static func sameFamily(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsFamily = canonicalFamilyID(lhs),
              let rhsFamily = canonicalFamilyID(rhs)
        else {
            return false
        }
        return lhsFamily == rhsFamily
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsNormalized = normalized(lhs),
              let rhsNormalized = normalized(rhs)
        else {
            return false
        }
        if lhsNormalized == rhsNormalized {
            return true
        }
        // The explicit `remote:*` wildcard matches any remote-namespace identity.
        // Per-device identities (`remote:<device8>`) only ever match exactly —
        // they have no canonical family, so no implicit widening is possible.
        if lhsNormalized == remoteAllDevicesWildcard, isRemoteClient(rhsNormalized) {
            return true
        }
        if rhsNormalized == remoteAllDevicesWildcard, isRemoteClient(lhsNormalized) {
            return true
        }
        return sameFamily(lhsNormalized, rhsNormalized)
    }

    static func isHeadlessAgentClient(_ raw: String?) -> Bool {
        guard let family = canonicalFamilyID(raw) else { return false }
        switch family {
        case "claude-code", "codex-mcp-client", "gemini-cli-mcp-client", "cursor":
            return true
        default:
            return false
        }
    }
}
