import Foundation
import RepoPromptRemoteWire

struct RemoteCommandError: Error, Equatable {
    var code: String
    var message: String
    var details: JSONValue?

    init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

enum RemoteClientError: Error, Equatable, LocalizedError {
    case hostNotFound(String)
    case hostRevoked(String)
    case missingDeviceKey(String)
    case security(String)
    case invalidTicket(String)
    case protocolViolation(String)
    case timeout(operation: String, seconds: TimeInterval)
    case transport(String)
    case connectionClosed
    case rateLimited(message: String)
    case revoked(RemoteCommandError)
    case bindingRequired(RemoteCommandError)
    case ambiguousStartTarget(RemoteCommandError)
    case inDoubt(RemoteCommandError)
    case insufficientScope(RemoteCommandError)
    case sessionExpired(RemoteCommandError)
    case interactionAlreadyResolved(RemoteCommandError)
    case authentication(RemoteCommandError)
    case command(RemoteCommandError)

    static func fromCommandError(code: String, message: String, details: JSONValue? = nil) -> RemoteClientError {
        let error = RemoteCommandError(code: code, message: message, details: details)
        switch code {
        case "device_revoked", "unknown_device":
            return .revoked(error)
        case "binding_required":
            return .bindingRequired(error)
        case "ambiguous_start_target":
            return .ambiguousStartTarget(error)
        case "in_doubt":
            return .inDoubt(error)
        case "insufficient_scope":
            return .insufficientScope(error)
        case "session_expired":
            return .sessionExpired(error)
        case "interaction_already_resolved":
            return .interactionAlreadyResolved(error)
        case "ticket_required",
             "ticket_auth_unavailable",
             "ticket_expired",
             "invalid_ticket",
             "invalid_ticket_lifetime",
             "ticket_signature_invalid",
             "ticket_already_used",
             "trust_unavailable",
             "counter_replayed",
             "signature_required",
             "unsupported_signature_algorithm",
             "signature_context_mismatch",
             "signature_invalid",
             "unauthenticated_connection":
            return .authentication(error)
        case "rate_limited":
            return .rateLimited(message: message)
        default:
            return .command(error)
        }
    }

    var commandError: RemoteCommandError? {
        switch self {
        case let .revoked(error),
             let .bindingRequired(error),
             let .ambiguousStartTarget(error),
             let .inDoubt(error),
             let .insufficientScope(error),
             let .sessionExpired(error),
             let .interactionAlreadyResolved(error),
             let .authentication(error),
             let .command(error):
            error
        case .hostNotFound,
             .hostRevoked,
             .missingDeviceKey,
             .security,
             .invalidTicket,
             .protocolViolation,
             .timeout,
             .transport,
             .connectionClosed,
             .rateLimited:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case let .hostNotFound(hostID):
            "Remote host not found: \(hostID)."
        case let .hostRevoked(hostID):
            "Remote host credentials were revoked: \(hostID). Forget and pair again to restore access."
        case let .missingDeviceKey(hostID):
            "No device key was found for remote host \(hostID)."
        case let .security(message):
            "Remote host security check failed: \(message)"
        case let .invalidTicket(message):
            "Remote connection ticket was invalid: \(message)"
        case let .protocolViolation(message):
            "Remote gateway protocol error: \(message)"
        case let .timeout(operation, seconds):
            "Remote \(operation) timed out after \(Int(seconds.rounded())) seconds."
        case let .transport(message):
            "Remote transport failed: \(message)"
        case .connectionClosed:
            "Remote connection closed."
        case let .rateLimited(message):
            message.isEmpty ? "Remote gateway rate limited the request; retry shortly." : message
        case let .revoked(error):
            error.message.isEmpty ? "Remote host revoked this device." : error.message
        case let .bindingRequired(error),
             let .ambiguousStartTarget(error),
             let .inDoubt(error),
             let .insufficientScope(error),
             let .sessionExpired(error),
             let .interactionAlreadyResolved(error),
             let .authentication(error),
             let .command(error):
            error.message.isEmpty ? "Remote command failed with code \(error.code)." : error.message
        }
    }
}
