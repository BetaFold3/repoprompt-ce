import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class InMemoryRemotePairingKeychain: RemotePairingKeychainStoring, @unchecked Sendable {
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
}

enum RemotePairingTestSupport {
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
        directory.appendingPathComponent("paired-devices-v1.json")
    }

    static func writeRegistry(_ registry: PairedDeviceRegistry, to url: URL, permissions: Int = 0o600) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func hostKeychain(signingIdentity: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> (P256.Signing.PrivateKey, InMemoryRemotePairingKeychain) {
        let keychain = InMemoryRemotePairingKeychain(values: [
            RemotePairingIdentityStore.hostSigningKeyAccount: signingIdentity.rawRepresentation.base64EncodedString()
        ])
        return (signingIdentity, keychain)
    }

    static func deviceRecord(
        id: String = "remote:1234abcd",
        displayName: String = "Test iPhone",
        scopes: Set<RemoteScope> = [.sessionsObserve, .interactionsRespond],
        pushSubscription: WebPushSubscriptionRecord? = nil
    ) -> PairedDeviceRecord {
        PairedDeviceRecord(
            id: id,
            displayName: displayName,
            publicKeyRawRepresentation: P256.Signing.PrivateKey().publicKey.rawRepresentation,
            scopes: scopes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            pushSubscription: pushSubscription
        )
    }

    static func validRegistry(hostSigner: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), devices: [PairedDeviceRecord]? = nil) -> PairedDeviceRegistry {
        PairedDeviceRegistry(
            hostPublicKeyFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            devices: devices ?? [deviceRecord()]
        )
    }
}
