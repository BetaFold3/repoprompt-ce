import CryptoKit
import Foundation
@testable import RepoPromptGateway
import XCTest

final class VAPIDKeyStoreTests: XCTestCase {
    private func makeStoreURL() throws -> URL {
        try GatewayTestHelpers.temporaryRoot()
            .appendingPathComponent("push", isDirectory: true)
            .appendingPathComponent("vapid-key-v1.json")
    }

    func testLoadOrCreateGeneratesPersistsAndReloadsTheSameKey() throws {
        let url = try makeStoreURL()
        let store = VAPIDKeyStore(fileURL: url)
        let created = try store.loadOrCreate()

        var statBuffer = stat()
        XCTAssertEqual(lstat(url.path, &statBuffer), 0)
        XCTAssertEqual(Int(statBuffer.st_mode & 0o777), 0o600, "VAPID key file must be 0600")

        let reloaded = try VAPIDKeyStore(fileURL: url).load()
        XCTAssertEqual(created.rawRepresentation, reloaded.rawRepresentation)
        XCTAssertEqual(
            VAPIDKeyStore.publicKeyBase64URL(for: created),
            VAPIDKeyStore.publicKeyBase64URL(for: reloaded)
        )
    }

    func testPublicKeyIsUncompressedPointInBase64URL() throws {
        let store = try VAPIDKeyStore(fileURL: makeStoreURL())
        let key = try store.loadOrCreate()
        let encoded = VAPIDKeyStore.publicKeyBase64URL(for: key)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = try XCTUnwrap(WebPushBase64URL.decode(encoded))
        XCTAssertEqual(decoded.count, 65, "applicationServerKey must be the uncompressed 65-byte point")
        XCTAssertEqual(decoded.first, 0x04)
        XCTAssertEqual(decoded, key.publicKey.x963Representation)
    }

    func testInsecurePermissionsFailClosed() throws {
        let url = try makeStoreURL()
        _ = try VAPIDKeyStore(fileURL: url).loadOrCreate()
        XCTAssertEqual(chmod(url.path, 0o644), 0)

        XCTAssertThrowsError(try VAPIDKeyStore(fileURL: url).load()) { error in
            guard case let GatewayPersistenceError.insecurePermissions(_, mode, expected) = error else {
                return XCTFail("Expected insecurePermissions, got \(error)")
            }
            XCTAssertEqual(mode, 0o644)
            XCTAssertEqual(expected, 0o600)
        }
    }

    func testCorruptKeyFileFailsClosed() throws {
        let url = try makeStoreURL()
        _ = try VAPIDKeyStore(fileURL: url).loadOrCreate()
        try Data("not json".utf8).write(to: url)
        try GatewayFileSecurity.setMode(0o600, path: url.path)

        XCTAssertThrowsError(try VAPIDKeyStore(fileURL: url).load()) { error in
            guard case GatewayPersistenceError.loadFailed = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
        }
    }

    func testValidJSONWithInvalidKeyMaterialFailsClosed() throws {
        let url = try makeStoreURL()
        _ = try VAPIDKeyStore(fileURL: url).loadOrCreate()
        let bogus = Data(#"{"schema_version":1,"private_key":"AAAA"}"#.utf8)
        try bogus.write(to: url)
        try GatewayFileSecurity.setMode(0o600, path: url.path)

        XCTAssertThrowsError(try VAPIDKeyStore(fileURL: url).load()) { error in
            guard case GatewayPersistenceError.loadFailed = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
        }
    }

    func testMissingFileFailsLoadButNotLoadOrCreate() throws {
        let url = try makeStoreURL()
        XCTAssertThrowsError(try VAPIDKeyStore(fileURL: url).load())
        XCTAssertNoThrow(try VAPIDKeyStore(fileURL: url).loadOrCreate())
    }
}
