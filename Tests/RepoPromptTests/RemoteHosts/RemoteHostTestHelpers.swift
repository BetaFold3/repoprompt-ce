import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class InMemoryRemoteClientKeychain: RemoteClientKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func get(for key: String, accessMode _: KeychainAccessMode) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else {
            throw KeychainService.KeychainError.itemNotFound
        }
        return value
    }

    func save(_ value: String, for key: String, accessMode _: KeychainAccessMode) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func delete(for key: String, accessMode _: KeychainAccessMode) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }

    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}

enum RemoteHostTestSupport {
    static func temporaryDirectory(testCase: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    static func registryURL(in directory: URL) -> URL {
        directory.appendingPathComponent("remote-hosts-v1.json")
    }

    static func writeRegistry(
        _ registry: PairedHostRegistryFile,
        to url: URL,
        permissions: Int = 0o600
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func hostRecord(
        hostSigner: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
        displayName: String = "Studio",
        gatewayURL: URL = URL(string: "https://studio.tailnet.example:8765")!,
        grantedScopes: Set<String> = ["sessions:observe", "sessions:operate"]
    ) throws -> PairedHostRecord {
        let deviceKey = P256.Signing.PrivateKey()
        let hostPublicKey = hostSigner.publicKey.rawRepresentation
        return try PairedHostRecord(
            id: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            displayName: displayName,
            gatewayURL: gatewayURL,
            hostPublicKey: hostPublicKey,
            deviceID: RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation),
            grantedScopes: grantedScopes,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    static func pairingPayload(
        hostSigner: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
        gatewayURL: URL = URL(string: "https://studio.tailnet.example:8765")!,
        hostName: String? = "Studio"
    ) throws -> RemotePairingPayload {
        try RemotePairingPayload(
            gatewayOrigin: RemoteGatewayOrigin(gatewayURL),
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            hostName: hostName,
            approvalContext: "test-approval-context"
        )
    }

    static func pairingPayloadJSON(
        hostSigner: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
        gatewayURL: URL = URL(string: "https://studio.tailnet.example:8765")!,
        hostName: String? = "Studio"
    ) throws -> String {
        var object: [String: Any] = [
            "v": 1,
            "kind": "repoprompt_remote_pairing",
            "window_id": 7,
            "gateway_url": gatewayURL.absoluteString,
            "host_public_key": hostSigner.publicKey.rawRepresentation.base64EncodedString(),
            "host_fingerprint": RemotePairingCrypto.fingerprint(for: hostSigner.publicKey)
        ]
        if let hostName {
            object["host_name"] = hostName
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
