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
}
