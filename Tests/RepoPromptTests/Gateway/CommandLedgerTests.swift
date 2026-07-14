import Foundation
@testable import RepoPromptGateway
import XCTest

final class CommandLedgerTests: XCTestCase {
    func testNewInFlightDuplicateAndConflict() async throws {
        let box = MutableDateBox(Date())
        let ledger = try CommandLedger(now: { box.date })
        let key = CommandLedger.Key(deviceID: "device-a", requestID: "req-1")
        let fingerprint = CommandLedger.CommandFingerprint(operation: "start", canonicalPayloadSHA256: "aaa")

        let first = await ledger.begin(key: key, fingerprint: fingerprint)
        let second = await ledger.begin(key: key, fingerprint: fingerprint)
        XCTAssertEqual(first, .new)
        XCTAssertEqual(second, .inFlight)

        await ledger.complete(key: key, outcome: .success(.object(["ok": .bool(true)])))
        let duplicate = await ledger.begin(key: key, fingerprint: fingerprint)
        XCTAssertEqual(duplicate, .duplicate(.success(.object(["ok": .bool(true)]))))

        let conflicting = CommandLedger.CommandFingerprint(operation: "start", canonicalPayloadSHA256: "bbb")
        let conflict = await ledger.begin(key: key, fingerprint: conflicting)
        XCTAssertEqual(conflict, .conflict(existing: fingerprint))
    }

    func testPerDeviceIsolation() async throws {
        let ledger = try CommandLedger()
        let fingerprint = CommandLedger.CommandFingerprint(operation: "respond", canonicalPayloadSHA256: "same")
        let a = CommandLedger.Key(deviceID: "device-a", requestID: "req")
        let b = CommandLedger.Key(deviceID: "device-b", requestID: "req")

        let first = await ledger.begin(key: a, fingerprint: fingerprint)
        let second = await ledger.begin(key: b, fingerprint: fingerprint)
        XCTAssertEqual(first, .new)
        XCTAssertEqual(second, .new)
    }

    func testTTLPrunesCompletedEntriesAfterMinimumWindow() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let box = MutableDateBox(start)
        let ledger = try CommandLedger(ttl: 1, now: { box.date })
        let key = CommandLedger.Key(deviceID: "device-a", requestID: "req")
        let fingerprint = CommandLedger.CommandFingerprint(operation: "cancel", canonicalPayloadSHA256: "aaa")

        let first = await ledger.begin(key: key, fingerprint: fingerprint)
        XCTAssertEqual(first, .new)
        await ledger.complete(key: key, outcome: .success(.object(["ok": .bool(true)])))

        box.date = start.addingTimeInterval(CommandLedger.minimumTTL + 1)
        await ledger.prune(now: box.date)

        let afterPrune = await ledger.begin(key: key, fingerprint: fingerprint)
        XCTAssertEqual(afterPrune, .new)
    }
}
