import Foundation
import Logging
import MCP
import RepoPromptRemoteWire

/// Relays the PWA's pairing and ticket bootstrap requests to the app-owned
/// `remote_pairing` MCP tool over the gateway-principal app leg.
///
/// The relay is intentionally narrow:
/// - only `begin_pairing`, `complete_pairing`, and `mint_ticket` are reachable,
/// - request fields are whitelisted per operation (no argument passthrough),
/// - the app remains the sole trust authority: `complete_pairing` succeeds only
///   after user consent in the app, and tickets are host-signed, one-time, ≤60s,
///   and useless without the device's private key (frame signatures are enforced
///   at WS admission), so relaying them to the not-yet-authenticated PWA is safe.
actor GatewayPairingRelay {
    struct RelayResponse: Equatable {
        let status: Int
        let body: JSONValue
    }

    static let beginPairingPath = "/api/pair/begin"
    static let completePairingPath = "/api/pair/complete"
    static let mintTicketPath = "/api/ticket"

    static let relayPaths: Set<String> = [
        beginPairingPath,
        completePairingPath,
        mintTicketPath
    ]

    /// `complete_pairing` blocks on user consent in the app UI, so its tool-call
    /// timeout must accommodate a human approval.
    static let completePairingTimeout: TimeInterval = 180
    static let defaultTimeout: TimeInterval = 20
    static let rateLimitWindowSeconds: TimeInterval = 60
    static let rateLimitMaximumRequests = 12

    private let appLink: AppLinkSession
    private let auditLog: RemoteAuditLog?
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var recentRequestTimesByPath: [String: [Date]] = [:]

    init(
        appLink: AppLinkSession,
        auditLog: RemoteAuditLog? = nil,
        logger: Logger = Logger(label: "com.repoprompt.gateway.pairing-relay"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appLink = appLink
        self.auditLog = auditLog
        self.logger = logger
        self.now = now
    }

    func handle(path: String, body: Data) async -> RelayResponse {
        let payload: [String: JSONValue]
        if body.isEmpty {
            payload = [:]
        } else if let decoded = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let object = decoded.objectValue
        {
            payload = object
        } else {
            return RelayResponse(status: 400, body: .object([
                "error": .string("Request body must be a JSON object.")
            ]))
        }

        if let rateLimited = checkRateLimit(path: path) {
            return rateLimited
        }

        switch path {
        case Self.beginPairingPath:
            var arguments: [String: Value] = [:]
            copyWindowRouting(payload, into: &arguments)
            copyInt(payload, key: "ttl_seconds", into: &arguments)
            return await callPairing(
                op: "begin_pairing",
                auditOp: "pair_begin",
                arguments: arguments,
                timeout: Self.defaultTimeout
            )
        case Self.completePairingPath:
            var arguments: [String: Value] = [:]
            copyWindowRouting(payload, into: &arguments)
            copyString(payload, key: "pairing_id", into: &arguments)
            copyString(payload, key: "display_name", into: &arguments)
            copyString(payload, key: "public_key", into: &arguments)
            copyString(payload, key: "proof", into: &arguments)
            copyString(payload, key: "device_id", into: &arguments)
            copyStringArray(payload, key: "scopes", into: &arguments)
            return await callPairing(
                op: "complete_pairing",
                auditOp: "pair_complete",
                arguments: arguments,
                timeout: Self.completePairingTimeout
            )
        case Self.mintTicketPath:
            var arguments: [String: Value] = [:]
            copyWindowRouting(payload, into: &arguments)
            copyString(payload, key: "device_id", into: &arguments)
            copyStringArray(payload, key: "scopes", into: &arguments)
            copyInt(payload, key: "ttl_seconds", into: &arguments)
            return await callPairing(
                op: "mint_ticket",
                auditOp: "mint_ticket",
                arguments: arguments,
                timeout: Self.defaultTimeout
            )
        default:
            return RelayResponse(status: 404, body: .object(["error": .string("not found")]))
        }
    }

    private func checkRateLimit(path: String) -> RelayResponse? {
        guard path == Self.beginPairingPath || path == Self.mintTicketPath else { return nil }
        let timestamp = now()
        let cutoff = timestamp.addingTimeInterval(-Self.rateLimitWindowSeconds)
        var recent = (recentRequestTimesByPath[path] ?? []).filter { $0 >= cutoff }
        guard recent.count < Self.rateLimitMaximumRequests else {
            recentRequestTimesByPath[path] = recent
            audit(op: path == Self.beginPairingPath ? "pair_begin" : "mint_ticket", outcome: "denied", code: "rate_limited")
            return RelayResponse(status: 429, body: .object([
                "error": .string("Too many requests; retry shortly."),
                "code": .string("rate_limited")
            ]))
        }
        recent.append(timestamp)
        recentRequestTimesByPath[path] = recent
        return nil
    }

    private func callPairing(
        op: String,
        auditOp: String,
        arguments: [String: Value],
        timeout: TimeInterval
    ) async -> RelayResponse {
        var toolArguments = arguments
        toolArguments["op"] = .string(op)
        // Ask the app for raw JSON tool output. Without this the app renders the
        // result through its human-readable formatter (a ```json fenced block),
        // which the relay cannot parse back into the JSON body the PWA expects.
        toolArguments["_rawJSON"] = .bool(true)
        do {
            let result = try await appLink.callTool(
                name: "remote_pairing",
                arguments: toolArguments,
                timeout: timeout
            )
            let payload = try RemoteMCPToolResultCodec.jsonValue(from: result)
            if result.isError == true {
                audit(op: auditOp, outcome: "failure", code: "app_tool_error")
                let message = payload.objectValue?["error"]?.stringValue
                    ?? payload.objectValue?["message"]?.stringValue
                    ?? payload.objectValue?["text"]?.stringValue
                    ?? "The pairing request was rejected."
                return RelayResponse(status: 400, body: .object(["error": .string(message)]))
            }
            audit(op: auditOp, outcome: "success", code: nil)
            return RelayResponse(status: 200, body: payload)
        } catch {
            audit(op: auditOp, outcome: "failure", code: "app_link_error")
            logger.debug("Pairing relay \(op) failed: \(String(describing: error))")
            return RelayResponse(status: 503, body: .object([
                "error": .string("The app link is unavailable: \(String(describing: error))"),
                "code": .string("app_link_unavailable")
            ]))
        }
    }

    private func copyWindowRouting(_ payload: [String: JSONValue], into arguments: inout [String: Value]) {
        copyInt(payload, key: "window_id", into: &arguments)
    }

    private func copyString(_ payload: [String: JSONValue], key: String, into arguments: inout [String: Value]) {
        if let value = payload[key]?.stringValue {
            arguments[key] = .string(value)
        }
    }

    private func copyInt(_ payload: [String: JSONValue], key: String, into arguments: inout [String: Value]) {
        if let value = payload[key]?.intValue {
            arguments[key] = .int(value)
        }
    }

    private func copyStringArray(_ payload: [String: JSONValue], key: String, into arguments: inout [String: Value]) {
        guard let values = payload[key]?.arrayValue else { return }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count else { return }
        arguments[key] = .array(strings.map(Value.string))
    }

    private func audit(op: String, outcome: String, code: String?) {
        auditLog?.recordBestEffort(RemoteAuditRecord(
            deviceID: "unpaired",
            requestID: nil,
            op: op,
            sessionID: nil,
            outcome: outcome,
            code: code
        ))
    }
}
