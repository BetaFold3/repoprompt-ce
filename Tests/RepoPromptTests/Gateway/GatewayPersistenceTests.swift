import Darwin
import Foundation
@testable import RepoPromptGateway
import XCTest

final class GatewayPersistenceTests: XCTestCase {
    func testLedgerCrashRecoveryMarksInFlightAsInDoubt() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger", isDirectory: true)
            .appendingPathComponent("command-ledger-v1.jsonl")
        let key = CommandLedger.Key(deviceID: "device", requestID: "req")
        let fingerprint = CommandLedger.CommandFingerprint(operation: "start", canonicalPayloadSHA256: "abc")

        do {
            let store = try CommandLedgerStore(fileURL: url)
            let ledger = try CommandLedger(store: store)
            let begin = await ledger.begin(key: key, fingerprint: fingerprint)
            XCTAssertEqual(begin, .new)
        }

        let recoveredStore = try CommandLedgerStore(fileURL: url)
        let recovered = try CommandLedger(store: recoveredStore)
        let recoveredBegin = await recovered.begin(key: key, fingerprint: fingerprint)
        XCTAssertEqual(recoveredBegin, .duplicate(.inDoubt))
    }

    func testLedgerStoreRejectsInsecureFileMode() throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(dir.path, 0o700), 0)
        let file = dir.appendingPathComponent("command-ledger-v1.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertEqual(chmod(file.path, 0o644), 0)

        XCTAssertThrowsError(try CommandLedgerStore(fileURL: file)) { error in
            guard case let GatewayPersistenceError.insecurePermissions(path, mode, expected) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(path, file.path)
            XCTAssertEqual(mode, 0o644)
            XCTAssertEqual(expected, 0o600)
        }
    }

    func testLedgerStoreSkipsAndQuarantinesCorruptRows() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ledger", isDirectory: true)
            .appendingPathComponent("command-ledger-v1.jsonl")
        let key = CommandLedger.Key(deviceID: "device", requestID: "req")
        let fingerprint = CommandLedger.CommandFingerprint(operation: "start", canonicalPayloadSHA256: "abc")

        do {
            let store = try CommandLedgerStore(fileURL: file)
            let ledger = try CommandLedger(store: store)
            let beginOutcome = await ledger.begin(key: key, fingerprint: fingerprint)
            XCTAssertEqual(beginOutcome, .new)
            await ledger.complete(key: key, outcome: .success(.object(["ok": .bool(true)])))
        }
        let original = try Data(contentsOf: file)
        var corrupted = Data("not-json\n".utf8)
        corrupted.append(original)
        try corrupted.write(to: file, options: [.atomic])
        try GatewayFileSecurity.setMode(0o600, path: file.path)

        let recoveredStore = try CommandLedgerStore(fileURL: file)
        let snapshots = try recoveredStore.load()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.key, key)
        XCTAssertEqual(snapshots.first?.outcome, .success(.object(["ok": .bool(true)])))
        let quarantine = file.deletingPathExtension().appendingPathExtension("corrupt.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testLedgerStoreCreatesSecureFile() throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ledger", isDirectory: true)
            .appendingPathComponent("command-ledger-v1.jsonl")
        _ = try CommandLedgerStore(fileURL: file)

        var statBuffer = stat()
        XCTAssertEqual(lstat(file.path, &statBuffer), 0)
        XCTAssertEqual(Int(statBuffer.st_mode & 0o777), 0o600)
    }
}
