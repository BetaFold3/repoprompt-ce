import Foundation

enum RemoteScope: String, Codable, CaseIterable, Hashable, Identifiable, Comparable {
    case sessionsObserve = "sessions:observe"
    case sessionsOperate = "sessions:operate"
    case interactionsRespond = "interactions:respond"
    case workspaceRead = "workspace:read"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .sessionsObserve:
            "Observe sessions"
        case .sessionsOperate:
            "Operate sessions"
        case .interactionsRespond:
            "Respond to interactions"
        case .workspaceRead:
            "Read workspace context"
        }
    }

    var detail: String {
        switch self {
        case .sessionsObserve:
            "View session lists, status, transcript catch-up, and live updates."
        case .sessionsOperate:
            "Start, steer, and cancel remote Agent Mode sessions."
        case .interactionsRespond:
            "Submit responses to prompts, approvals, and other pending interactions."
        case .workspaceRead:
            "Read workspace context needed by future remote browsing surfaces."
        }
    }

    static func < (lhs: RemoteScope, rhs: RemoteScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
