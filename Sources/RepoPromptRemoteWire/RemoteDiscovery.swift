import CryptoKit
import Foundation

public enum RemoteControlBuildChannel: String, Codable, CaseIterable, Sendable {
    case release
    case debug

    public var fixedPort: Int {
        switch self {
        case .release: 47_391
        case .debug: 47_392
        }
    }

    public var urlScheme: String {
        switch self {
        case .release: "repoprompt-ce"
        case .debug: "repoprompt-ce-debug"
        }
    }

    public var storageNamespace: String { rawValue }

    public static func channel(forFixedPort port: Int) -> RemoteControlBuildChannel? {
        allCases.first { $0.fixedPort == port }
    }
}

public enum RemoteGatewayOriginError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case missingExplicitPort
    case credentialsNotAllowed
    case nonRootPath
    case queryNotAllowed
    case fragmentNotAllowed
    case invalidDirectTailscaleOrigin
}

public struct RemoteGatewayOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let string: String

    public init(_ url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RemoteGatewayOriginError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RemoteGatewayOriginError.unsupportedScheme
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw RemoteGatewayOriginError.missingHost
        }
        guard components.port != nil else {
            throw RemoteGatewayOriginError.missingExplicitPort
        }
        guard components.user == nil, components.password == nil else {
            throw RemoteGatewayOriginError.credentialsNotAllowed
        }
        guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else {
            throw RemoteGatewayOriginError.nonRootPath
        }
        guard components.percentEncodedQuery == nil else {
            throw RemoteGatewayOriginError.queryNotAllowed
        }
        guard components.fragment == nil else {
            throw RemoteGatewayOriginError.fragmentNotAllowed
        }

        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = ""
        components.percentEncodedQuery = nil
        components.fragment = nil
        guard let normalized = components.url else {
            throw RemoteGatewayOriginError.invalidURL
        }
        string = normalized.absoluteString
    }

    public init(string: String) throws {
        guard let url = URL(string: string) else {
            throw RemoteGatewayOriginError.invalidURL
        }
        try self.init(url)
    }

    public init(tailscaleIPv4: String, channel: RemoteControlBuildChannel) throws {
        guard Self.isTailscaleIPv4(tailscaleIPv4),
              let url = URL(string: "http://\(tailscaleIPv4):\(channel.fixedPort)")
        else {
            throw RemoteGatewayOriginError.invalidDirectTailscaleOrigin
        }
        try self.init(url)
    }

    public var url: URL { URL(string: string)! }
    public var description: String { string }

    public var scheme: String { URLComponents(string: string)?.scheme ?? "" }
    public var host: String { URLComponents(string: string)?.host ?? "" }
    public var port: Int { URLComponents(string: string)?.port ?? 0 }

    public func endpoint(path: String) -> URL {
        var components = URLComponents(string: string)!
        components.percentEncodedPath = path.hasPrefix("/") ? path : "/\(path)"
        return components.url!
    }

    public func webSocketEndpoint() -> URL {
        var components = URLComponents(string: string)!
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.percentEncodedPath = "/ws"
        return components.url!
    }

    public func validateDirectTailscale(channel: RemoteControlBuildChannel) throws {
        guard scheme == "http",
              port == channel.fixedPort,
              Self.isTailscaleIPv4(host)
        else {
            throw RemoteGatewayOriginError.invalidDirectTailscaleOrigin
        }
    }

    public static func isTailscaleIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  (part.count == 1 || part.first != "0"),
                  let number = UInt8(part)
            else { return false }
            octets.append(number)
        }
        guard octets.count == 4 else { return false }
        let packed = UInt32(octets[0]) << 24
            | UInt32(octets[1]) << 16
            | UInt32(octets[2]) << 8
            | UInt32(octets[3])
        return (packed & 0xFFC0_0000) == 0x6440_0000
    }

    public static func numericIPv4SortKey(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(string: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

public enum RemoteDiscoveryCapability: String, Codable, CaseIterable, Sendable {
    case approvalContextV1 = "approval_context_v1"
    case nativePairingV1 = "native_pairing_v1"
}

public enum RemoteDiscoveryError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidKind
    case invalidNonce
    case channelMismatch
    case originMismatch
    case invalidDirectOrigin
    case invalidHostPublicKey
    case fingerprintMismatch
    case invalidLifetime
    case outsideClockSkew
    case missingCapability(String)
    case invalidSignatureAlgorithm
    case invalidSignature
}

public struct RemoteDiscoveryRequest: Codable, Equatable, Sendable {
    public static let version = 1
    public static let kind = "repoprompt_remote_discovery"

    public let v: Int
    public let kind: String
    public let nonce: String
    public let channel: RemoteControlBuildChannel

    public init(
        v: Int = Self.version,
        kind: String = Self.kind,
        nonce: String,
        channel: RemoteControlBuildChannel
    ) throws {
        self.v = v
        self.kind = kind
        self.nonce = nonce
        self.channel = channel
        try validate()
    }

    public func validate() throws {
        guard v == Self.version else { throw RemoteDiscoveryError.invalidVersion }
        guard kind == Self.kind else { throw RemoteDiscoveryError.invalidKind }
        guard Self.isValidNonce(nonce) else { throw RemoteDiscoveryError.invalidNonce }
    }

    public static func make(channel: RemoteControlBuildChannel) throws -> RemoteDiscoveryRequest {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let nonce = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try RemoteDiscoveryRequest(nonce: nonce, channel: channel)
    }

    public static func isValidNonce(_ value: String) -> Bool {
        guard value.count == 43 else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}

public struct RemoteDiscoveryResponse: Codable, Equatable, Sendable {
    public static let signatureAlgorithm = "P256-SHA256"
    public static let signingContext = "RepoPromptRemoteDiscoveryV1"
    public static let maximumTTLMilliseconds: Int64 = 60_000
    public static let maximumClockSkewMilliseconds: Int64 = 30_000

    public let v: Int
    public let kind: String
    public let nonce: String
    public let channel: RemoteControlBuildChannel
    public let origin: RemoteGatewayOrigin
    public let hostPublicKey: Data
    public let hostFingerprint: String
    public let hostName: String
    public let bundleID: String
    public let marketingVersion: String
    public let buildVersion: String
    public let capabilities: [String]
    public let approvalContext: String
    public let issuedAtMs: Int64
    public let expiresAtMs: Int64
    public let algorithm: String
    public let signature: Data

    enum CodingKeys: String, CodingKey {
        case v, kind, nonce, channel, origin
        case hostPublicKey = "host_public_key"
        case hostFingerprint = "host_fingerprint"
        case hostName = "host_name"
        case bundleID = "bundle_id"
        case marketingVersion = "marketing_version"
        case buildVersion = "build_version"
        case capabilities
        case approvalContext = "approval_context"
        case issuedAtMs = "issued_at_ms"
        case expiresAtMs = "expires_at_ms"
        case algorithm
        case signature
    }

    public init(
        request: RemoteDiscoveryRequest,
        origin: RemoteGatewayOrigin,
        hostPublicKey: Data,
        hostFingerprint: String,
        hostName: String,
        bundleID: String,
        marketingVersion: String,
        buildVersion: String,
        capabilities: [String] = RemoteDiscoveryCapability.allCases.map(\.rawValue),
        approvalContext: String,
        issuedAtMs: Int64,
        expiresAtMs: Int64,
        hostSigner: P256.Signing.PrivateKey
    ) throws {
        self.v = request.v
        kind = request.kind
        nonce = request.nonce
        channel = request.channel
        self.origin = origin
        self.hostPublicKey = hostPublicKey
        self.hostFingerprint = hostFingerprint
        self.hostName = hostName
        self.bundleID = bundleID
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.capabilities = capabilities.sorted()
        self.approvalContext = approvalContext
        self.issuedAtMs = issuedAtMs
        self.expiresAtMs = expiresAtMs
        algorithm = Self.signatureAlgorithm
        signature = try hostSigner.signature(for: Self.canonicalSigningData(
            v: request.v,
            kind: request.kind,
            nonce: request.nonce,
            channel: request.channel,
            origin: origin,
            hostPublicKey: hostPublicKey,
            hostFingerprint: hostFingerprint,
            hostName: hostName,
            bundleID: bundleID,
            marketingVersion: marketingVersion,
            buildVersion: buildVersion,
            capabilities: capabilities.sorted(),
            approvalContext: approvalContext,
            issuedAtMs: issuedAtMs,
            expiresAtMs: expiresAtMs,
            algorithm: Self.signatureAlgorithm
        )).rawRepresentation
    }

    public var canonicalSigningData: Data {
        get throws {
            try Self.canonicalSigningData(
                v: v,
                kind: kind,
                nonce: nonce,
                channel: channel,
                origin: origin,
                hostPublicKey: hostPublicKey,
                hostFingerprint: hostFingerprint,
                hostName: hostName,
                bundleID: bundleID,
                marketingVersion: marketingVersion,
                buildVersion: buildVersion,
                capabilities: capabilities.sorted(),
                approvalContext: approvalContext,
                issuedAtMs: issuedAtMs,
                expiresAtMs: expiresAtMs,
                algorithm: algorithm
            )
        }
    }

    private static func canonicalSigningData(
        v: Int,
        kind: String,
        nonce: String,
        channel: RemoteControlBuildChannel,
        origin: RemoteGatewayOrigin,
        hostPublicKey: Data,
        hostFingerprint: String,
        hostName: String,
        bundleID: String,
        marketingVersion: String,
        buildVersion: String,
        capabilities: [String],
        approvalContext: String,
        issuedAtMs: Int64,
        expiresAtMs: Int64,
        algorithm: String
    ) throws -> Data {
        try RemoteWireProtocol.canonicalData(for: .object([
            "context": .string(signingContext),
            "v": .int(v),
            "kind": .string(kind),
            "nonce": .string(nonce),
            "channel": .string(channel.rawValue),
            "origin": .string(origin.string),
            "host_public_key": .string(hostPublicKey.base64EncodedString()),
            "host_fingerprint": .string(hostFingerprint),
            "host_name": .string(hostName),
            "bundle_id": .string(bundleID),
            "marketing_version": .string(marketingVersion),
            "build_version": .string(buildVersion),
            "capabilities": .array(capabilities.map(JSONValue.string)),
            "approval_context": .string(approvalContext),
            "issued_at_ms": .int(Int(issuedAtMs)),
            "expires_at_ms": .int(Int(expiresAtMs)),
            "algorithm": .string(algorithm)
        ]))
    }
}

public enum RemoteDiscoveryVerifier {
    public static func verify(
        _ response: RemoteDiscoveryResponse,
        request: RemoteDiscoveryRequest,
        expectedOrigin: RemoteGatewayOrigin,
        nowMs: Int64
    ) throws {
        try request.validate()
        guard response.v == request.v else { throw RemoteDiscoveryError.invalidVersion }
        guard response.kind == request.kind else { throw RemoteDiscoveryError.invalidKind }
        guard response.nonce == request.nonce else { throw RemoteDiscoveryError.invalidNonce }
        guard response.channel == request.channel else { throw RemoteDiscoveryError.channelMismatch }
        guard response.origin == expectedOrigin else { throw RemoteDiscoveryError.originMismatch }
        do {
            try response.origin.validateDirectTailscale(channel: response.channel)
        } catch {
            throw RemoteDiscoveryError.invalidDirectOrigin
        }
        guard response.expiresAtMs > response.issuedAtMs,
              response.expiresAtMs - response.issuedAtMs <= RemoteDiscoveryResponse.maximumTTLMilliseconds
        else {
            throw RemoteDiscoveryError.invalidLifetime
        }
        guard response.issuedAtMs <= nowMs + RemoteDiscoveryResponse.maximumClockSkewMilliseconds,
              response.expiresAtMs >= nowMs - RemoteDiscoveryResponse.maximumClockSkewMilliseconds
        else {
            throw RemoteDiscoveryError.outsideClockSkew
        }
        guard response.algorithm == RemoteDiscoveryResponse.signatureAlgorithm else {
            throw RemoteDiscoveryError.invalidSignatureAlgorithm
        }
        for capability in RemoteDiscoveryCapability.allCases.map(\.rawValue) {
            guard response.capabilities.contains(capability) else {
                throw RemoteDiscoveryError.missingCapability(capability)
            }
        }
        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: response.hostPublicKey) else {
            throw RemoteDiscoveryError.invalidHostPublicKey
        }
        let computed = "sha256:" + RemoteWireProtocol.sha256Hex(of: response.hostPublicKey)
        guard response.hostFingerprint == computed else {
            throw RemoteDiscoveryError.fingerprintMismatch
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: response.signature),
              publicKey.isValidSignature(signature, for: try response.canonicalSigningData)
        else {
            throw RemoteDiscoveryError.invalidSignature
        }
    }
}
