import Foundation

/// Provenance of an Agent Mode session (plan §6.4).
///
/// Replaces the boolean `isMCPOriginated` as the source of truth while keeping
/// the legacy flag serialized for backward compatibility:
/// - old JSON without `origin` decodes via `init(legacyIsMCPOriginated:)`
///   (`true` → `.mcp(clientID: nil)`, `false`/missing → `.user`)
/// - new JSON keeps writing `isMCPOriginated` so older builds stay compatible.
enum AgentSessionOrigin: Equatable, Hashable {
    /// Created by the user in the app UI.
    case user
    /// Created by an MCP client; `clientID` is the client identity storage key
    /// when known (for example `claude-code`, `repoprompt-cli`).
    case mcp(clientID: String?)
    /// Created by a paired remote gateway device (`remote:<device8>`);
    /// `deviceID` is the device identifier without the `remote:` prefix.
    case remote(deviceID: String)

    /// Derived legacy compatibility flag: `.mcp`/`.remote` → `true`, `.user` → `false`.
    var isMCPOriginated: Bool {
        switch self {
        case .user:
            false
        case .mcp, .remote:
            true
        }
    }

    /// Migration mapping for records that only carry the legacy boolean.
    init(legacyIsMCPOriginated: Bool) {
        self = legacyIsMCPOriginated ? .mcp(clientID: nil) : .user
    }

    /// Classifies an MCP client identity into `.remote(deviceID:)` for gateway
    /// device identities (`remote:<device8>`) or `.mcp(clientID:)` otherwise.
    static func fromClientIdentity(_ clientName: String?) -> AgentSessionOrigin {
        if let deviceID = MCPClientIdentity.remoteDeviceID(from: clientName) {
            return .remote(deviceID: deviceID)
        }
        return .mcp(clientID: MCPClientIdentity.storageKey(clientName))
    }

    /// Merges two provenance values, preferring the first non-user origin so a
    /// session that was ever MCP/remote-claimed keeps that attribution (mirrors
    /// the sticky legacy `isMCPOriginated ||` merge).
    static func merged(_ lhs: AgentSessionOrigin?, _ rhs: AgentSessionOrigin?) -> AgentSessionOrigin? {
        if let lhs, lhs != .user { return lhs }
        if let rhs, rhs != .user { return rhs }
        return lhs ?? rhs
    }

    /// Stable string form for tool summaries and diagnostics:
    /// `user`, `mcp`, `mcp:<client>`, or `remote:<device8>`.
    var summaryString: String {
        switch self {
        case .user:
            "user"
        case let .mcp(clientID):
            clientID.map { "mcp:\($0)" } ?? "mcp"
        case let .remote(deviceID):
            "remote:\(deviceID)"
        }
    }
}

extension AgentSessionOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case clientID
        case deviceID
    }

    private enum Kind: String {
        case user
        case mcp
        case remote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: kindRaw) {
        case .user:
            self = .user
        case .mcp:
            self = try .mcp(clientID: container.decodeIfPresent(String.self, forKey: .clientID))
        case .remote:
            if let deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) {
                self = .remote(deviceID: deviceID)
            } else {
                self = .mcp(clientID: nil)
            }
        case nil:
            // Forward compatibility: treat unknown origin kinds as MCP-originated
            // so cleanup scoping never silently widens to user sessions.
            self = .mcp(clientID: nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode(Kind.user.rawValue, forKey: .kind)
        case let .mcp(clientID):
            try container.encode(Kind.mcp.rawValue, forKey: .kind)
            try container.encodeIfPresent(clientID, forKey: .clientID)
        case let .remote(deviceID):
            try container.encode(Kind.remote.rawValue, forKey: .kind)
            try container.encode(deviceID, forKey: .deviceID)
        }
    }
}
