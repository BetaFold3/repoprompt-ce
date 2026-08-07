import AppKit
import Foundation

/// Type of entity referenced by a mention: either a file or a folder.
public enum MentionKind: String, Codable {
    case folder
    case file
    case skill
    case snippet
}

/// Single suggestion row.
public struct MentionSuggestion: Identifiable, Equatable {
    public let id = UUID()
    public let displayName: String // Text shown in UI
    public let relativePath: String // Repo-relative path (unique key)
    public let kind: MentionKind
    public var children: [MentionSuggestion]?
    public var subtitle: String? // Optional secondary text (e.g. skill description)
    public var commitDisplayText: String? // Text inserted after resolving a plain-text @ tag
}

/// Payload attached to the attributed token inside the editor.
public struct MentionTokenPayload: Codable, Equatable, Hashable {
    public let relativePath: String
    public let kind: MentionKind
}

/// Convenience key so we can tag an attributed range with a payload.
public extension NSAttributedString.Key {
    static let mentionToken = NSAttributedString.Key("MentionTokenAttribute")
}
