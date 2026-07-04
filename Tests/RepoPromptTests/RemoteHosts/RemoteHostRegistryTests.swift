import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class RemoteHostRegistryTests: XCTestCase {
    func testLoadReportsMissingFileAsEmptyRegistry() throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let url = RemoteHostTestSupport.registryURL(in: directory)
        let registry = RemoteHostRegistry(url: url)

        XCTAssertEqual(RemoteHostRegistry.load(from: url), .failure(.missing))
        XCTAssertFalse(registry.hasHosts)
        XCTAssertEqual(try registry.listHosts(), [])
    }

    func testRoundTripUpsertCounterRevocationAndRemoval() throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let url = RemoteHostTestSupport.registryURL(in: directory)
        let registry = RemoteHostRegistry(url: url)
        let record = try RemoteHostTestSupport.hostRecord()

        try registry.upsertHost(record)

        XCTAssertTrue(registry.hasHosts)
        XCTAssertEqual(try registry.host(id: record.id), record)
        XCTAssertEqual(try registry.listHosts().map(\.id), [record.id])

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        _ = try registry.updateLastCounter(hostID: record.id, counter: 10)
        _ = try registry.updateLastCounter(hostID: record.id, counter: 2)
        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 10)

        let revokedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let revoked = try registry.markRevokedByHost(hostID: record.id, at: revokedAt)
        XCTAssertEqual(revoked.revokedByHostAt, revokedAt)

        let removed = try registry.removeHost(id: record.id)
        XCTAssertEqual(removed?.id, record.id)
        XCTAssertFalse(registry.hasHosts)
    }

    func testRejectsWrongOwnerInsecureModeInvalidSchemaAndDuplicateHosts() throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let url = RemoteHostTestSupport.registryURL(in: directory)
        let record = try RemoteHostTestSupport.hostRecord()
        let valid = PairedHostRegistryFile(hosts: [record])
        try RemoteHostTestSupport.writeRegistry(valid, to: url)

        XCTAssertEqual(
            RemoteHostRegistry.load(from: url, expectedOwnerID: getuid() + 1),
            .failure(.wrongOwner)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(RemoteHostRegistry.load(from: url), .failure(.insecurePermissions))

        var invalidSchema = valid
        invalidSchema.schemaVersion = 999
        try RemoteHostTestSupport.writeRegistry(invalidSchema, to: url)
        XCTAssertEqual(RemoteHostRegistry.load(from: url), .failure(.invalidRegistry))

        try RemoteHostTestSupport.writeRegistry(PairedHostRegistryFile(hosts: [record, record]), to: url)
        XCTAssertEqual(RemoteHostRegistry.load(from: url), .failure(.invalidRegistry))
    }

    func testRejectsRecordWhoseFingerprintDoesNotMatchPinnedHostKey() throws {
        let hostSigner = P256.Signing.PrivateKey()
        let otherHostSigner = P256.Signing.PrivateKey()
        var record = try RemoteHostTestSupport.hostRecord(hostSigner: hostSigner)
        record.hostPublicKey = otherHostSigner.publicKey.rawRepresentation

        XCTAssertFalse(RemoteHostRegistry.validateHostRecord(record))
    }
}
