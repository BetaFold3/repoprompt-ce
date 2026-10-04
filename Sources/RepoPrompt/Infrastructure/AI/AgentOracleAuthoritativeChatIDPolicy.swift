import Foundation

enum AgentOracleAuthoritativeChatIDPolicy {
    /// An explicitly scoped lane route (a persisted Oracle failure diagnostic's lane chat). It
    /// never invalidates or replaces an authoritative root `chat_id`, but it identifies specific
    /// chats, so a result carrying one never allows identity-free latest-chat fallback.
    static let scopedLaneChatIDKey = "lane_chat_id"

    static func extract(fromSerializedJSON json: String?) -> String? {
        guard let json else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        return extract(fromRootObject: object)
    }

    static func extract(fromRootObject object: [String: Any]) -> String? {
        guard !object.keys.contains("chatID"),
              !containsChatID(in: object, excludingAuthoritativeRoot: true),
              let chatID = object["chat_id"] as? String
        else { return nil }
        let trimmed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func allowsLatestFallback(fromSerializedJSON json: String?) -> Bool {
        guard let json else { return false }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return false }
        return !containsChatID(in: object, includingScopedLaneChatIDs: true)
    }

    /// Root extraction ignores scoped lane routes; latest-fallback eligibility counts them.
    private static func containsChatID(
        in value: Any,
        excludingAuthoritativeRoot: Bool = false,
        includingScopedLaneChatIDs: Bool = false
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if key == "chat_id" || key == "chatID" {
                    if excludingAuthoritativeRoot, key == "chat_id" {
                        continue
                    }
                    return true
                }
                if includingScopedLaneChatIDs, key == scopedLaneChatIDKey {
                    return true
                }
                if containsChatID(in: nested, includingScopedLaneChatIDs: includingScopedLaneChatIDs) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsChatID(in: $0, includingScopedLaneChatIDs: includingScopedLaneChatIDs) }
        }
        return false
    }
}
