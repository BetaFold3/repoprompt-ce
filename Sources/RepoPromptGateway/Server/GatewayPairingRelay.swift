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

    static let discoveryPath = "/.well-known/repoprompt/remote-pairing/v1"
    static let beginPairingPath = "/api/pair/begin"
    static let completePairingPath = "/api/pair/complete"
    static let mintTicketPath = "/api/ticket"

    static let relayPaths: Set<String> = [
        discoveryPath,
        beginPairingPath,
        completePairingPath,
        mintTicketPath
    ]

    /// `complete_pairing` blocks on user consent in the app UI, so its tool-call
    /// timeout must accommodate a human approval.
    static let completePairingTimeout: TimeInterval = 180
    static let defaultTimeout: TimeInterval = 20
    static let discoveryTimeout: TimeInterval = 3
    static let maximumDiscoveryRequestBytes = 2 * 1024
    static let maximumDiscoveryInFlight = 4
    static let discoveryPeerRateLimit = 30
    static let discoveryGlobalRateLimit = 240
    static let allowedExpectedFailureCodes: Set<String> = [
        "discovery_unavailable",
        "build_channel_mismatch",
        "approval_context_required",
        "approval_context_expired",
        "approval_context_replayed",
        "approval_window_unavailable",
        "approval_window_ambiguous",
        "approval_target_stale",
        "approval_cancelled",
        "pairing_denied",
        "pairing_challenge_expired",
        "pairing_challenge_replayed",
        "pairing_challenge_not_found",
        "unknown_device",
        "device_revoked"
    ]

    static func status(forExpectedFailure code: String) -> Int {
        switch code {
        case "pairing_denied": 403
        case "discovery_unavailable": 503
        default: 409
        }
    }

    static let rateLimitWindowSeconds: TimeInterval = 60
    static let rateLimitMaximumRequests = 12

    private let appLink: AppLinkSession
    private let auditLog: RemoteAuditLog?
    private let logger: Logger
    private let now: @Sendable () -> Date
    private let discoveryPeerObserver: (@Sendable (String) -> Void)?
    private var postCompletePairingAction: (@Sendable () async -> Void)?
    private var recentRequestTimesByPath: [String: [Date]] = [:]
    private var recentDiscoveryRequestsByPeer: [String: [Date]] = [:]
    private var recentDiscoveryRequests: [Date] = []
    private var discoveryInFlight = 0

    init(
        appLink: AppLinkSession,
        auditLog: RemoteAuditLog? = nil,
        logger: Logger = Logger(label: "com.repoprompt.gateway.pairing-relay"),
        now: @escaping @Sendable () -> Date = { Date() },
        discoveryPeerObserver: (@Sendable (String) -> Void)? = nil
    ) {
        self.appLink = appLink
        self.auditLog = auditLog
        self.logger = logger
        self.now = now
        self.discoveryPeerObserver = discoveryPeerObserver
    }

    /// Installed during gateway startup before the HTTP server accepts work.
    /// Successful pairing waits for this action, making refreshed gateway trust
    /// visible before the controller can mint a ticket and open its WebSocket.
    func setPostCompletePairingAction(_ action: @escaping @Sendable () async -> Void) {
        postCompletePairingAction = action
    }

    func isAppLinkReady() async -> Bool {
        switch await appLink.currentState() {
        case .connected, .reconnected:
            true
        default:
            false
        }
    }

    func handle(path: String, body: Data, peerAddress: String? = nil) async -> RelayResponse {
        if path == Self.discoveryPath, body.count > Self.maximumDiscoveryRequestBytes {
            return RelayResponse(status: 413, body: .object([
                "ok": .bool(false),
                "code": .string("invalid_discovery_request"),
                "error": .string("Discovery request is too large.")
            ]))
        }
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
        case Self.discoveryPath:
            return await handleDiscovery(payload: payload, peerAddress: peerAddress)
        case Self.beginPairingPath:
            var arguments: [String: Value] = [:]
            copyString(payload, key: "approval_context", into: &arguments)
            copyInt(payload, key: "ttl_seconds", into: &arguments)
            return await callPairing(
                op: "begin_pairing",
                auditOp: "pair_begin",
                arguments: arguments,
                timeout: Self.defaultTimeout
            )
        case Self.completePairingPath:
            var arguments: [String: Value] = [:]
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

    private func handleDiscovery(
        payload: [String: JSONValue],
        peerAddress: String?
    ) async -> RelayResponse {
        guard payload["v"]?.intValue == RemoteDiscoveryRequest.version,
              payload["kind"]?.stringValue == RemoteDiscoveryRequest.kind,
              let nonce = payload["nonce"]?.stringValue,
              let channelRaw = payload["channel"]?.stringValue,
              let channel = RemoteControlBuildChannel(rawValue: channelRaw),
              (try? RemoteDiscoveryRequest(nonce: nonce, channel: channel)) != nil
        else {
            return RelayResponse(status: 400, body: .object([
                "ok": .bool(false),
                "code": .string("invalid_discovery_request"),
                "error": .string("Discovery request is invalid.")
            ]))
        }

        let timestamp = now()
        let cutoff = timestamp.addingTimeInterval(-Self.rateLimitWindowSeconds)
        let peer = peerAddress ?? "unknown-peer"
        discoveryPeerObserver?(peer)
        recentDiscoveryRequests = recentDiscoveryRequests.filter { $0 >= cutoff }
        var peerRequests = (recentDiscoveryRequestsByPeer[peer] ?? []).filter { $0 >= cutoff }
        guard recentDiscoveryRequests.count < Self.discoveryGlobalRateLimit,
              peerRequests.count < Self.discoveryPeerRateLimit
        else {
            recentDiscoveryRequestsByPeer[peer] = peerRequests
            return RelayResponse(status: 429, body: .object([
                "ok": .bool(false),
                "code": .string("rate_limited"),
                "error": .string("Too many discovery requests; retry shortly.")
            ]))
        }
        guard discoveryInFlight < Self.maximumDiscoveryInFlight else {
            return RelayResponse(status: 503, body: .object([
                "ok": .bool(false),
                "code": .string("signing_capacity_exceeded"),
                "error": .string("Discovery signing is busy; retry shortly.")
            ]))
        }
        recentDiscoveryRequests.append(timestamp)
        peerRequests.append(timestamp)
        recentDiscoveryRequestsByPeer[peer] = peerRequests
        discoveryInFlight += 1
        defer { discoveryInFlight -= 1 }
        return await callPairing(
            op: "discover_host",
            auditOp: "discover_host",
            arguments: [
                "nonce": .string(nonce),
                "channel": .string(channel.rawValue)
            ],
            timeout: Self.discoveryTimeout
        )
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
            if payload.objectValue?["ok"]?.boolValue == false,
               let code = payload.objectValue?["code"]?.stringValue,
               Self.allowedExpectedFailureCodes.contains(code)
            {
                let status = payload.objectValue?["status"]?.intValue ?? Self.status(forExpectedFailure: code)
                audit(op: auditOp, outcome: "denied", code: code)
                return RelayResponse(status: status, body: payload)
            }
            if op == "complete_pairing", payload.objectValue?["ok"]?.boolValue != false {
                await postCompletePairingAction?()
            }
            audit(op: auditOp, outcome: "success", code: nil)
            return RelayResponse(status: 200, body: payload)
        } catch {
            audit(op: auditOp, outcome: "failure", code: "app_link_error")
            logger.debug("Pairing relay \(op) failed: \(String(describing: error))")
            return RelayResponse(status: 503, body: .object([
                "error": .string("The app link is unavailable."),
                "code": .string("app_link_unavailable")
            ]))
        }
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
