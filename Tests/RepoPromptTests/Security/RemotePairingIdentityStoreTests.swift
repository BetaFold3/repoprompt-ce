import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class RemotePairingIdentityStoreTests: XCTestCase {
    func testLoadReportsMissingFile() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let missing = RemotePairingTestSupport.registryURL(in: directory)

        XCTAssertEqual(RemotePairingIdentityStore.load(from: missing), .failure(.missing))
    }

    func testRejectsWrongOwnerInsecureModeAndInvalidSchema() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let hostKey = P256.Signing.PrivateKey()
        let registry = RemotePairingTestSupport.validRegistry(hostSigner: hostKey)
        try RemotePairingTestSupport.writeRegistry(registry, to: url)

        XCTAssertEqual(
            RemotePairingIdentityStore.load(from: url, expectedOwnerID: getuid() + 1),
            .failure(.wrongOwner)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.insecurePermissions))

        var invalid = registry
        invalid.schemaVersion = 999
        try RemotePairingTestSupport.writeRegistry(invalid, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))
    }

    func testValidRoundTripAndRevokeClearsPushMetadata() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        let push = WebPushSubscriptionRecord(endpoint: "https://push.example/device", p256dh: "p256dh", auth: "auth")
        let record = RemotePairingTestSupport.deviceRecord(pushSubscription: push)
        try store.upsertDevice(record)

        let loaded = try RemotePairingIdentityStore.load(from: url).get()
        XCTAssertEqual(loaded.schemaVersion, PairedDeviceRegistry.currentSchemaVersion)
        XCTAssertEqual(loaded.hostPublicKeyFingerprint, RemotePairingCrypto.fingerprint(for: hostKey.publicKey))
        XCTAssertEqual(loaded.devices.map(\.id), [record.id])
        XCTAssertEqual(loaded.devices.first?.pushSubscription, push)

        let revoked = try store.revokeDevice(id: record.id, revokedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertNotNil(revoked.revokedAt)
        XCTAssertNil(revoked.pushSubscription)

        let devices = try store.listDevices(includeRevoked: true)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].isRevoked)
        XCTAssertNil(devices[0].pushSubscription)
    }
}
