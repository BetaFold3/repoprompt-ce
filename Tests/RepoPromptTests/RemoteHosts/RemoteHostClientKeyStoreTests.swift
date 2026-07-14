import CryptoKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class RemoteHostClientKeyStoreTests: XCTestCase {
    func testStoresPerHostKeysInIsolatedAccountsAndDeletesOneHostOnly() throws {
        let keychain = InMemoryRemoteClientKeychain()
        let store = RemoteClientKeyStore(keychain: keychain, accessMode: .nonInteractive(reason: .test))
        let hostA = RemotePairingCrypto.fingerprint(for: P256.Signing.PrivateKey().publicKey)
        let hostB = RemotePairingCrypto.fingerprint(for: P256.Signing.PrivateKey().publicKey)
        let keyA = P256.Signing.PrivateKey()
        let keyB = P256.Signing.PrivateKey()

        try store.save(keyA, forHostID: hostA)
        try store.save(keyB, forHostID: hostB)

        XCTAssertEqual(try store.privateKey(forHostID: hostA).rawRepresentation, keyA.rawRepresentation)
        XCTAssertEqual(try store.privateKey(forHostID: hostB).rawRepresentation, keyB.rawRepresentation)
        XCTAssertNotEqual(try RemoteClientKeyStore.account(forHostID: hostA), try RemoteClientKeyStore.account(forHostID: hostB))

        try store.deleteKey(forHostID: hostA)

        XCTAssertThrowsError(try store.privateKey(forHostID: hostA)) { error in
            XCTAssertEqual(error as? RemoteClientKeyStoreError, .missingKey(hostA))
        }
        XCTAssertEqual(try store.privateKey(forHostID: hostB).rawRepresentation, keyB.rawRepresentation)
    }

    func testRejectsInvalidHostFingerprintForAccountDerivation() {
        XCTAssertThrowsError(try RemoteClientKeyStore.account(forHostID: "sha256:ABC")) { error in
            XCTAssertEqual(error as? RemoteClientKeyStoreError, .invalidHostID("sha256:ABC"))
        }
    }
}
