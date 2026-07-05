import Foundation
import JSONSchema
import MCP
import Ontology

enum RemotePairingOperation: String, Codable, CaseIterable {
    case beginPairing = "begin_pairing"
    case completePairing = "complete_pairing"
    case mintTicket = "mint_ticket"
    case revokeDevice = "revoke_device"
    case listDevices = "list_devices"
}

private enum MCPRemotePairingToolDefinition {
    static let description = """
    Gateway-only remote-control pairing authority.

    This tool is only callable by the app-spawned gateway connection carrying the verified gateway principal. It never authorizes by clientName. Pairing begins with a short-lived challenge, completes only after device-proof verification and user consent, and tickets are host-signed by the app-owned P256 key.

    Operations:
    - `begin_pairing`: create a ≤60s challenge. Does not persist trust.
    - `complete_pairing`: verify device proof, show consent UI, persist after approval.
    - `mint_ticket`: mint a one-time ≤60s host-signed ticket for a paired non-revoked device. Scopes are clamped to the device record.
    - `revoke_device`: mark a device revoked and clear push metadata.
    - `list_devices`: list paired devices and host fingerprint.
    """

    static let inputSchema: JSONSchema = .object(
        properties: [
            "op": .string(
                description: "Remote pairing operation.",
                enum: ["begin_pairing", "complete_pairing", "mint_ticket", "revoke_device", "list_devices"]
            ),
            "window_id": .integer(description: "Host window ID from the pairing payload. Required for complete_pairing approval routing."),
            "pairing_id": .string(description: "Pairing UUID from begin_pairing, required by complete_pairing."),
            "display_name": .string(description: "Human-readable device name for complete_pairing."),
            "device_id": .string(description: "Device ID, usually remote:<fingerprint8>. Required for ticket/revoke; optional for complete_pairing when derivable from public_key."),
            "public_key": .string(description: "Base64 P256.Signing public-key rawRepresentation for complete_pairing."),
            "proof": .string(description: "Base64 P256 signature over the canonical device challenge payload."),
            "scopes": .array(description: "Requested/granted scope raw values.", items: .string()),
            "ttl_seconds": .integer(description: "Requested challenge/ticket TTL in seconds. Clamped to 60."),
            "include_revoked": .boolean(description: "Whether list_devices includes revoked devices. Default true.")
        ],
        required: ["op"]
    )

    static func contextForAppWideExecution(args: [String: Value]) throws -> MCPWindowToolContext {
        let operation = RemotePairingOperation(rawValue: args["op"]?.stringValue ?? "")
        if operation == .completePairing {
            guard let windowID = args["window_id"]?.intValue, windowID > 0 else {
                throw MCPError.invalidParams("window_id is required for complete_pairing approval routing.")
            }
            return MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: windowID)
        }
        return MCPWindowToolContext(
            toolName: MCPWindowToolName.remotePairing,
            windowID: args["window_id"]?.intValue ?? 0
        )
    }
}

@MainActor
final class MCPRemotePairingToolService: Service {
    private let executionDependencies: MCPRemotePairingToolProvider.ExecutionDependencies

    init() {
        executionDependencies = .liveGatewayDependencies()
    }

    init(executionDependencies: MCPRemotePairingToolProvider.ExecutionDependencies) {
        self.executionDependencies = executionDependencies
    }

    var tools: [Tool] {
        get async { [remotePairingTool()] }
    }

    private func remotePairingTool() -> Tool {
        Tool(
            name: MCPWindowToolName.remotePairing,
            description: MCPRemotePairingToolDefinition.description,
            inputSchema: MCPRemotePairingToolDefinition.inputSchema,
            annotations: .repoPromptLocalEphemeralState,
            returnsValue: { [executionDependencies] args in
                let context = try MCPRemotePairingToolDefinition.contextForAppWideExecution(args: args)
                return try await MCPRemotePairingToolProvider.execute(
                    args: args,
                    context: context,
                    dependencies: executionDependencies
                )
            }
        )
    }
}

@MainActor
final class MCPRemotePairingToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .remotePairing

    struct ExecutionDependencies: @unchecked Sendable {
        let captureRequestMetadata: MCPWindowToolDependencies.CaptureRequestMetadata
        let isGatewayPrincipalConnection: MCPWindowToolDependencies.IsGatewayPrincipalConnection
        let identityStore: RemotePairingIdentityStore
        let approvalManager: RemoteDeviceApprovalManager
        let challengeStore: RemotePairingChallengeStore
        let now: @Sendable () -> Date

        init(
            captureRequestMetadata: @escaping MCPWindowToolDependencies.CaptureRequestMetadata,
            isGatewayPrincipalConnection: @escaping MCPWindowToolDependencies.IsGatewayPrincipalConnection,
            identityStore: RemotePairingIdentityStore = .shared,
            approvalManager: RemoteDeviceApprovalManager,
            challengeStore: RemotePairingChallengeStore = .shared,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.captureRequestMetadata = captureRequestMetadata
            self.isGatewayPrincipalConnection = isGatewayPrincipalConnection
            self.identityStore = identityStore
            self.approvalManager = approvalManager
            self.challengeStore = challengeStore
            self.now = now
        }

        @MainActor
        static func liveGatewayDependencies() -> ExecutionDependencies {
            ExecutionDependencies(
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: ServerNetworkManager.currentConnectionID,
                        clientName: nil,
                        windowID: nil
                    )
                },
                isGatewayPrincipalConnection: { connectionID in
                    await ServerNetworkManager.shared.isGatewayPrincipalConnection(connectionID)
                },
                approvalManager: .shared
            )
        }
    }

    private let runtime: MCPWindowToolRuntime
    private let executionDependencies: ExecutionDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        executionDependencies = ExecutionDependencies(
            captureRequestMetadata: dependencies.captureRequestMetadata,
            isGatewayPrincipalConnection: dependencies.isGatewayPrincipalConnection,
            approvalManager: .shared
        )
    }

    init(runtime: MCPWindowToolRuntime, executionDependencies: ExecutionDependencies) {
        self.runtime = runtime
        self.executionDependencies = executionDependencies
    }

    func buildTools() -> [Tool] {
        [remotePairingTool()]
    }

    private func remotePairingTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.remotePairing,
            freshnessPolicy: .none,
            description: MCPRemotePairingToolDefinition.description,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: MCPRemotePairingToolDefinition.inputSchema
        ) { [executionDependencies] context, args in
            try await Self.execute(args: args, context: context, dependencies: executionDependencies)
        }
    }

    static func execute(
        args: [String: Value],
        context: MCPWindowToolContext,
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        try await requireGatewayPrincipal(dependencies: dependencies)

        guard let opRaw = args["op"]?.stringValue,
              let operation = RemotePairingOperation(rawValue: opRaw)
        else {
            throw MCPError.invalidParams("op must be one of: \(RemotePairingOperation.allCases.map(\.rawValue).joined(separator: ", ")).")
        }

        switch operation {
        case .beginPairing:
            return try await executeBeginPairing(args: args, dependencies: dependencies)
        case .completePairing:
            return try await executeCompletePairing(args: args, context: context, dependencies: dependencies)
        case .mintTicket:
            return try executeMintTicket(args: args, dependencies: dependencies)
        case .revokeDevice:
            return try executeRevokeDevice(args: args, dependencies: dependencies)
        case .listDevices:
            return try executeListDevices(args: args, dependencies: dependencies)
        }
    }

    private static func requireGatewayPrincipal(dependencies: ExecutionDependencies) async throws {
        let metadata = await dependencies.captureRequestMetadata()
        guard let connectionID = metadata.connectionID else {
            throw MCPError.invalidRequest("remote_pairing requires a verified gateway principal connection.")
        }
        guard await dependencies.isGatewayPrincipalConnection(connectionID) else {
            throw MCPError.invalidRequest("remote_pairing is restricted to the verified gateway principal.")
        }
    }

    private static func executeBeginPairing(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let host = try dependencies.identityStore.hostPublicKeyInfo()
        let ttl = ttlSeconds(from: args["ttl_seconds"])
        let challenge = try await dependencies.challengeStore.issue(now: dependencies.now(), ttl: ttl)
        return .object([
            "ok": .bool(true),
            "pairing_id": .string(challenge.pairingID.uuidString),
            "challenge": .string(challenge.challenge),
            "host_public_key": .string(host.rawRepresentation.base64EncodedString()),
            "host_fingerprint": .string(host.fingerprint),
            "expires_at": .string(formatDate(challenge.expiresAt))
        ])
    }

    private static func executeCompletePairing(
        args: [String: Value],
        context: MCPWindowToolContext,
        dependencies: ExecutionDependencies
    ) async throws -> Value {
        let pairingID = try requiredUUID(args["pairing_id"], name: "pairing_id")
        let displayName = try requiredTrimmedString(args["display_name"], name: "display_name")
        let publicKeyRaw = try requiredBase64Data(args["public_key"], name: "public_key")
        let proof = try requiredBase64Data(args["proof"], name: "proof")
        guard let requestedScopes = try parseScopes(args["scopes"], required: true) else {
            throw MCPError.invalidParams("scopes is required.")
        }
        let deviceID = try resolvedDeviceID(args["device_id"]?.stringValue, publicKeyRawRepresentation: publicKeyRaw)

        let challenge = try await dependencies.challengeStore.consume(pairingID: pairingID, now: dependencies.now())
        let proofPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge.challenge,
            deviceID: deviceID,
            displayName: displayName,
            publicKeyRawRepresentation: publicKeyRaw,
            scopes: requestedScopes
        )
        try RemotePairingCrypto.verifyDeviceChallenge(payload: proofPayload, signature: proof)

        let host = try dependencies.identityStore.hostPublicKeyInfo()
        guard let deviceFingerprint = RemotePairingCrypto.fingerprint(forRawPublicKey: publicKeyRaw) else {
            throw MCPError.invalidParams("public_key is not a valid P256 signing public key.")
        }
        let request = RemoteDeviceApprovalRequest(
            deviceID: deviceID,
            displayName: displayName,
            devicePublicKeyFingerprint: deviceFingerprint,
            requestedScopes: requestedScopes,
            hostFingerprint: host.fingerprint,
            windowID: context.windowID
        )
        let approval = await dependencies.approvalManager.requestApproval(for: request)
        guard case let .approved(grantedScopes) = approval, !grantedScopes.isEmpty else {
            throw MCPError.invalidRequest("Remote device pairing was denied by the user.")
        }

        let existingDevice = try dependencies.identityStore.device(id: deviceID)
        // deviceID is the pubkey fingerprint, so a re-pair reuses the same key;
        // resetting the anti-replay counterFloor would open a replay window for
        // previously captured signed frames.
        let record = PairedDeviceRecord(
            id: deviceID,
            displayName: displayName,
            publicKeyRawRepresentation: publicKeyRaw,
            scopes: grantedScopes,
            createdAt: dependencies.now(),
            counterFloor: existingDevice?.counterFloor ?? 0
        )
        let savedRecord = try dependencies.identityStore.upsertDevicePreservingCounterFloor(record)
        return .object([
            "ok": .bool(true),
            "device": deviceValue(savedRecord)
        ])
    }

    private static func executeMintTicket(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) throws -> Value {
        let deviceID = try requiredTrimmedString(args["device_id"], name: "device_id")
        guard let device = try dependencies.identityStore.device(id: deviceID) else {
            throw MCPError.invalidRequest("No paired device exists for \(deviceID).")
        }
        guard !device.isRevoked else {
            throw MCPError.invalidRequest("Device \(deviceID) is revoked.")
        }
        let requestedScopes = try parseScopes(args["scopes"], required: false) ?? device.scopes
        let grantedScopes = requestedScopes.intersection(device.scopes)
        guard !grantedScopes.isEmpty else {
            throw MCPError.invalidParams("Requested ticket scopes are not granted to \(deviceID).")
        }

        let issuedAt = dependencies.now()
        let expiresAt = issuedAt.addingTimeInterval(ttlSeconds(from: args["ttl_seconds"]))
        let host = try dependencies.identityStore.hostPublicKeyInfo()
        let key = try dependencies.identityStore.hostSigningPrivateKey()
        let ticket = try RemotePairingCrypto.signTicket(
            deviceID: deviceID,
            scopes: grantedScopes,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            hostFingerprint: host.fingerprint,
            hostSigner: key
        )
        return .object([
            "ok": .bool(true),
            "ticket": ticketValue(ticket)
        ])
    }

    private static func executeRevokeDevice(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) throws -> Value {
        let deviceID = try requiredTrimmedString(args["device_id"], name: "device_id")
        let record = try dependencies.identityStore.revokeDevice(id: deviceID, revokedAt: dependencies.now())
        return .object([
            "ok": .bool(true),
            "device": deviceValue(record),
            "gateway_sync_required": .bool(true)
        ])
    }

    private static func executeListDevices(
        args: [String: Value],
        dependencies: ExecutionDependencies
    ) throws -> Value {
        let includeRevoked = args["include_revoked"]?.boolValue ?? true
        let host = try dependencies.identityStore.hostPublicKeyInfo()
        let devices = try dependencies.identityStore.listDevices(includeRevoked: includeRevoked)
        return .object([
            "ok": .bool(true),
            "host_public_key": .string(host.rawRepresentation.base64EncodedString()),
            "host_fingerprint": .string(host.fingerprint),
            "devices": .array(devices.map(deviceValue))
        ])
    }

    private static func ttlSeconds(from value: Value?) -> TimeInterval {
        guard let seconds = value?.intValue, seconds > 0 else {
            return RemotePairingCrypto.maximumTicketTTL
        }
        return min(TimeInterval(seconds), RemotePairingCrypto.maximumTicketTTL)
    }

    private static func parseScopes(_ value: Value?, required: Bool) throws -> Set<RemoteScope>? {
        guard let value else {
            if required { throw MCPError.invalidParams("scopes is required.") }
            return nil
        }
        guard let entries = value.arrayValue else {
            throw MCPError.invalidParams("scopes must be an array of scope strings.")
        }
        let scopes = try Set(entries.map { entry in
            guard let raw = entry.stringValue,
                  let scope = RemoteScope(rawValue: raw)
            else {
                throw MCPError.invalidParams("Unknown remote scope in scopes.")
            }
            return scope
        })
        guard !scopes.isEmpty else {
            throw MCPError.invalidParams("scopes must not be empty.")
        }
        return scopes
    }

    private static func resolvedDeviceID(_ raw: String?, publicKeyRawRepresentation: Data) throws -> String {
        let derived = try RemotePairingCrypto.deviceID(forRawPublicKey: publicKeyRawRepresentation)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return derived }
        guard RemotePairingIdentityStore.isValidDeviceID(trimmed) else {
            throw MCPError.invalidParams("device_id must match remote:<lowercase-hex>.")
        }
        return trimmed
    }

    private static func requiredUUID(_ value: Value?, name: String) throws -> UUID {
        guard let raw = value?.stringValue,
              let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MCPError.invalidParams("\(name) must be a UUID string.")
        }
        return uuid
    }

    private static func requiredTrimmedString(_ value: Value?, name: String) throws -> String {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return string
    }

    private static func requiredBase64Data(_ value: Value?, name: String) throws -> Data {
        guard let raw = value?.stringValue,
              let data = Data(base64Encoded: raw)
        else {
            throw MCPError.invalidParams("\(name) must be base64 data.")
        }
        return data
    }

    private static func ticketValue(_ ticket: RemoteConnectionTicket) -> Value {
        .object([
            "ticket_id": .string(ticket.ticketID.uuidString),
            "device_id": .string(ticket.deviceID),
            "scopes": .array(ticket.scopes.sorted().map { .string($0.rawValue) }),
            "issued_at": .string(formatDate(ticket.issuedAt)),
            "expires_at": .string(formatDate(ticket.expiresAt)),
            // Canonical signed milliseconds: verifiers must use these exact values so
            // signature checks never depend on a lossy ISO-8601 date round-trip.
            "issued_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(ticket.issuedAt))),
            "expires_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(ticket.expiresAt))),
            "host_fingerprint": .string(ticket.hostFingerprint),
            "host_signature": .string(ticket.hostSignature.base64EncodedString())
        ])
    }

    private static func deviceValue(_ device: PairedDeviceRecord) -> Value {
        var object: [String: Value] = [
            "schema_version": .int(device.schemaVersion),
            "id": .string(device.id),
            "display_name": .string(device.displayName),
            "public_key": .string(device.publicKeyRawRepresentation.base64EncodedString()),
            "public_key_fingerprint": .string(device.publicKeyFingerprint ?? ""),
            "scopes": .array(device.scopes.sorted().map { .string($0.rawValue) }),
            "created_at": .string(formatDate(device.createdAt)),
            "counter_floor": .int(Int(device.counterFloor)),
            "revoked": .bool(device.isRevoked)
        ]
        if let lastSeenAt = device.lastSeenAt {
            object["last_seen_at"] = .string(formatDate(lastSeenAt))
        } else {
            object["last_seen_at"] = .null
        }
        if let revokedAt = device.revokedAt {
            object["revoked_at"] = .string(formatDate(revokedAt))
        } else {
            object["revoked_at"] = .null
        }
        object["has_push_subscription"] = .bool(device.pushSubscription != nil)
        return .object(object)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
