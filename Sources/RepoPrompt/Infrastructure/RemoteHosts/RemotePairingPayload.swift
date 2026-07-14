import Foundation
import RepoPromptRemoteWire

enum RemotePairingPayloadError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidKind(String)
    case invalidGatewayURL(String)
    case invalidHostFingerprint(String)
    case invalidHostPublicKey
    case fingerprintMismatch(expected: String, actual: String)
    case missingApprovalContext
}

struct RemotePairingPayload: Equatable {
    static let currentVersion = 1
    static let expectedKind = "repoprompt_remote_pairing"

    var version: Int
    var kind: String
    var gatewayOrigin: RemoteGatewayOrigin
    var hostPublicKey: Data
    var hostFingerprint: String
    var hostName: String?
    var approvalContext: String

    init(
        version: Int = RemotePairingPayload.currentVersion,
        kind: String = RemotePairingPayload.expectedKind,
        gatewayOrigin: RemoteGatewayOrigin,
        hostPublicKey: Data,
        hostFingerprint: String,
        hostName: String? = nil,
        approvalContext: String
    ) throws {
        self.version = version
        self.kind = kind
        self.gatewayOrigin = gatewayOrigin
        self.hostPublicKey = hostPublicKey
        self.hostFingerprint = hostFingerprint
        self.hostName = hostName
        self.approvalContext = approvalContext
        try validate()
    }

    init(verifiedDiscovery response: RemoteDiscoveryResponse) throws {
        try self.init(
            gatewayOrigin: response.origin,
            hostPublicKey: response.hostPublicKey,
            hostFingerprint: response.hostFingerprint,
            hostName: response.hostName,
            approvalContext: response.approvalContext
        )
    }

    var gatewayURL: URL {
        gatewayOrigin.url
    }

    var hostDisplayName: String {
        if let trimmed = hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return "Remote Host \(fingerprintShort)"
    }

    var fingerprintShort: String {
        RemoteHostRegistry.hostFingerprintShort(hostFingerprint) ?? "unknown"
    }

    private func validate() throws {
        guard version == Self.currentVersion else {
            throw RemotePairingPayloadError.unsupportedVersion(version)
        }
        guard kind == Self.expectedKind else {
            throw RemotePairingPayloadError.invalidKind(kind)
        }
        guard RemoteHostRegistry.isValidHostFingerprint(hostFingerprint) else {
            throw RemotePairingPayloadError.invalidHostFingerprint(hostFingerprint)
        }
        guard let computedFingerprint = RemotePairingCrypto.fingerprint(forRawPublicKey: hostPublicKey) else {
            throw RemotePairingPayloadError.invalidHostPublicKey
        }
        guard computedFingerprint == hostFingerprint else {
            throw RemotePairingPayloadError.fingerprintMismatch(expected: hostFingerprint, actual: computedFingerprint)
        }
        guard !approvalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemotePairingPayloadError.missingApprovalContext
        }
    }
}
