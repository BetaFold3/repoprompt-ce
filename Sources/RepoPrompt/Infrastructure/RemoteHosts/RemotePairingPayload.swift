import Foundation

enum RemotePairingPayloadError: Error, Equatable {
    case invalidJSON
    case unsupportedVersion(Int)
    case invalidKind(String)
    case invalidGatewayURL(String)
    case invalidHostFingerprint(String)
    case invalidHostPublicKey
    case fingerprintMismatch(expected: String, actual: String)
}

struct RemotePairingPayload: Codable, Equatable {
    static let currentVersion = 1
    static let expectedKind = "repoprompt_remote_pairing"

    var version: Int
    var kind: String
    var windowID: Int?
    var gatewayURL: URL
    var hostPublicKey: Data
    var hostFingerprint: String
    var hostName: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case windowID = "window_id"
        case gatewayURL = "gateway_url"
        case hostPublicKey = "host_public_key"
        case hostFingerprint = "host_fingerprint"
        case hostName = "host_name"
    }

    init(
        version: Int = RemotePairingPayload.currentVersion,
        kind: String = RemotePairingPayload.expectedKind,
        windowID: Int? = nil,
        gatewayURL: URL,
        hostPublicKey: Data,
        hostFingerprint: String,
        hostName: String? = nil
    ) throws {
        self.version = version
        self.kind = kind
        self.windowID = windowID
        self.gatewayURL = gatewayURL
        self.hostPublicKey = hostPublicKey
        self.hostFingerprint = hostFingerprint
        self.hostName = hostName
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(String.self, forKey: .kind)
        windowID = try container.decodeIfPresent(Int.self, forKey: .windowID)
        gatewayURL = try container.decode(URL.self, forKey: .gatewayURL)
        hostPublicKey = try container.decode(Data.self, forKey: .hostPublicKey)
        hostFingerprint = try container.decode(String.self, forKey: .hostFingerprint)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        try validate()
    }

    static func parse(_ text: String) throws -> RemotePairingPayload {
        guard let data = text.data(using: .utf8) else {
            throw RemotePairingPayloadError.invalidJSON
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> RemotePairingPayload {
        do {
            return try JSONDecoder().decode(RemotePairingPayload.self, from: data)
        } catch let error as RemotePairingPayloadError {
            throw error
        } catch {
            throw RemotePairingPayloadError.invalidJSON
        }
    }

    func withGatewayURL(_ url: URL) throws -> RemotePairingPayload {
        try RemotePairingPayload(
            version: version,
            kind: kind,
            windowID: windowID,
            gatewayURL: url,
            hostPublicKey: hostPublicKey,
            hostFingerprint: hostFingerprint,
            hostName: hostName
        )
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
        guard RemoteHostRegistry.isValidGatewayURL(gatewayURL) else {
            throw RemotePairingPayloadError.invalidGatewayURL(gatewayURL.absoluteString)
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
    }
}
