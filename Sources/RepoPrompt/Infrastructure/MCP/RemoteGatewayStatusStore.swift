import Combine
import Foundation
import RepoPromptRemoteWire

@MainActor
final class RemoteGatewayStatusStore: ObservableObject {
    static let shared = RemoteGatewayStatusStore()

    enum Status: Equatable {
        case disabled
        case resolvingTailscale
        case starting(RemoteGatewayOrigin)
        case discoverable(RemoteGatewayOrigin)
        case unavailable(String)
        case failed(String)

        var origin: RemoteGatewayOrigin? {
            switch self {
            case let .starting(origin), let .discoverable(origin):
                origin
            case .disabled, .resolvingTailscale, .unavailable, .failed:
                nil
            }
        }

        var summary: String {
            switch self {
            case .disabled:
                "Disabled"
            case .resolvingTailscale:
                "Resolving Tailscale binding…"
            case let .starting(origin):
                "Starting on \(origin.string)…"
            case let .discoverable(origin):
                "Discoverable on \(origin.string)"
            case let .unavailable(reason):
                "Unavailable: \(reason)"
            case let .failed(message):
                "Failed: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .disabled

    func publish(_ status: Status) {
        self.status = status
    }
}
