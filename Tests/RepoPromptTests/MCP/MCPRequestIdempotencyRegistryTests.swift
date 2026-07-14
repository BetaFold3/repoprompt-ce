import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Plan §6.1: bounded TTL idempotency registry for `agent_run` `request_id`.
final class MCPRequestIdempotencyRegistryTests: XCTestCase {
    private final class ClockBox: @unchecked Sendable {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }

    private func makeKey(
        clientID: String = "claude-code",
        requestID: String = "req-1"
    ) -> MCPRequestIdempotencyRegistry.Key {
        MCPRequestIdempotencyRegistry.Key(clientID: clientID, requestID: requestID)
    }

    private func makeFingerprint(
        operation: String = "start",
        payloadHash: String = "hash-a"
    ) -> MCPRequestIdempotencyRegistry.Fingerprint {
        MCPRequestIdempotencyRegistry.Fingerprint(operation: operation, payloadHashSHA256: payloadHash)
    }

    func testDuplicateRequestReplaysRecordedSuccessWithoutReExecution() async {
        let registry = MCPRequestIdempotencyRegistry()
        let key = makeKey()
        let fingerprint = makeFingerprint()

        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("First begin must be .new")
        }
        let recorded = Value.object(["session_id": .string("11111111-1111-1111-1111-111111111111")])
        await registry.complete(key: key, outcome: .success(recorded))

        // A duplicate start with the same request returns the original session_id
        // instead of creating a second session.
        guard case let .duplicate(outcome) = await registry.begin(key: key, fingerprint: fingerprint),
              case let .success(replayed) = outcome
        else {
            return XCTFail("Duplicate begin must replay the recorded success outcome")
        }
        XCTAssertEqual(replayed, recorded)
    }

    func testDuplicateRequestReplaysRecordedFailure() async {
        let registry = MCPRequestIdempotencyRegistry()
        let key = makeKey(requestID: "req-fail")
        let fingerprint = makeFingerprint(operation: "respond")

        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("First begin must be .new")
        }
        await registry.complete(key: key, outcome: .failure(code: "invalid_params", message: "stale interaction"))

        guard case let .duplicate(outcome) = await registry.begin(key: key, fingerprint: fingerprint),
              case let .failure(code, message) = outcome
        else {
            return XCTFail("Duplicate begin must replay the recorded failure outcome")
        }
        XCTAssertEqual(code, "invalid_params")
        XCTAssertEqual(message, "stale interaction")
    }

    func testSameRequestIDWithDifferentPayloadConflicts() async {
        let registry = MCPRequestIdempotencyRegistry()
        let key = makeKey()

        guard case .new = await registry.begin(key: key, fingerprint: makeFingerprint(payloadHash: "hash-a")) else {
            return XCTFail("First begin must be .new")
        }
        await registry.complete(key: key, outcome: .success(.string("ok")))

        guard case let .conflict(existing) = await registry.begin(
            key: key,
            fingerprint: makeFingerprint(payloadHash: "hash-b")
        ) else {
            return XCTFail("Different payload hash for the same request_id must conflict")
        }
        XCTAssertEqual(existing.payloadHashSHA256, "hash-a")
    }

    func testSameRequestIDWithDifferentOperationConflicts() async {
        let registry = MCPRequestIdempotencyRegistry()
        let key = makeKey()

        guard case .new = await registry.begin(key: key, fingerprint: makeFingerprint(operation: "start")) else {
            return XCTFail("First begin must be .new")
        }
        guard case let .conflict(existing) = await registry.begin(
            key: key,
            fingerprint: makeFingerprint(operation: "respond")
        ) else {
            return XCTFail("Different operation for the same request_id must conflict")
        }
        XCTAssertEqual(existing.operation, "start")
    }

    func testDuplicateWhileInFlightIsRefusedNotReExecuted() async {
        let registry = MCPRequestIdempotencyRegistry()
        let key = makeKey()
        let fingerprint = makeFingerprint()

        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("First begin must be .new")
        }
        guard case .inFlight = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("Duplicate begin before completion must be .inFlight")
        }
    }

    func testDifferentClientsWithSameRequestIDAreIndependent() async {
        let registry = MCPRequestIdempotencyRegistry()
        let fingerprint = makeFingerprint()

        guard case .new = await registry.begin(key: makeKey(clientID: "remote:aaaa1111"), fingerprint: fingerprint) else {
            return XCTFail("First client's begin must be .new")
        }
        guard case .new = await registry.begin(key: makeKey(clientID: "remote:bbbb2222"), fingerprint: fingerprint) else {
            return XCTFail("A different client reusing the request_id must be independent (.new)")
        }
    }

    func testCompletedEntriesExpireAfterTTL() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let registry = MCPRequestIdempotencyRegistry(ttl: 600, now: { clock.now })
        let key = makeKey()
        let fingerprint = makeFingerprint()

        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("First begin must be .new")
        }
        await registry.complete(key: key, outcome: .success(.string("ok")))

        clock.now = clock.now.addingTimeInterval(601)
        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("Completed entry past TTL must expire and allow a fresh execution")
        }
    }

    func testInFlightEntriesNeverExpire() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let registry = MCPRequestIdempotencyRegistry(ttl: 600, now: { clock.now })
        let key = makeKey()
        let fingerprint = makeFingerprint()

        guard case .new = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("First begin must be .new")
        }
        clock.now = clock.now.addingTimeInterval(3600)
        guard case .inFlight = await registry.begin(key: key, fingerprint: fingerprint) else {
            return XCTFail("In-flight entries must survive TTL pruning")
        }
    }

    func testBoundsEvictOldestCompletedEntriesButNeverInFlight() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let registry = MCPRequestIdempotencyRegistry(ttl: 3600, maximumEntries: 2, now: { clock.now })
        let fingerprint = makeFingerprint()

        let oldestCompleted = makeKey(requestID: "req-oldest")
        _ = await registry.begin(key: oldestCompleted, fingerprint: fingerprint)
        await registry.complete(key: oldestCompleted, outcome: .success(.string("oldest")))

        clock.now = clock.now.addingTimeInterval(1)
        let inFlight = makeKey(requestID: "req-inflight")
        _ = await registry.begin(key: inFlight, fingerprint: fingerprint)

        clock.now = clock.now.addingTimeInterval(1)
        let newestCompleted = makeKey(requestID: "req-newest")
        _ = await registry.begin(key: newestCompleted, fingerprint: fingerprint)
        await registry.complete(key: newestCompleted, outcome: .success(.string("newest")))

        let hasOldest = await registry.test_hasEntry(key: oldestCompleted)
        let hasInFlight = await registry.test_hasEntry(key: inFlight)
        let hasNewest = await registry.test_hasEntry(key: newestCompleted)
        XCTAssertFalse(hasOldest, "Oldest completed entry must be evicted first")
        XCTAssertTrue(hasInFlight, "In-flight entries must never be evicted by bounds")
        XCTAssertTrue(hasNewest, "Newest completed entry must survive bounds eviction")
        let count = await registry.test_entryCount()
        XCTAssertEqual(count, 2)
    }

    func testPayloadHashIsDeterministicAndExcludesRequestID() {
        let base: [String: Value] = [
            "op": .string("start"),
            "message": .string("go"),
            "model_id": .string("pair")
        ]
        var withRequestID = base
        withRequestID["request_id"] = .string("req-1")
        var withOtherRequestID = base
        withOtherRequestID["request_id"] = .string("req-2")

        let hashBase = MCPRequestIdempotencyRegistry.payloadHashHex(args: base)
        XCTAssertEqual(
            hashBase,
            MCPRequestIdempotencyRegistry.payloadHashHex(args: withRequestID),
            "request_id must be excluded from the payload fingerprint"
        )
        XCTAssertEqual(
            hashBase,
            MCPRequestIdempotencyRegistry.payloadHashHex(args: withOtherRequestID)
        )
        XCTAssertEqual(hashBase.count, 64, "SHA-256 hex digest")

        var different = base
        different["message"] = .string("stop")
        XCTAssertNotEqual(hashBase, MCPRequestIdempotencyRegistry.payloadHashHex(args: different))
    }
}
