import CryptoKit
import Foundation
@testable import RepoPromptApp
@testable import RepoPromptGateway
import XCTest

final class GatewayAuthDeviceAuthenticatorTests: XCTestCase {
    private var root: URL!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try GatewayTestHelpers.temporaryRoot("device-auth")
        hostSigner = P256.Signing.PrivateKey()
        device = GatewayAuthTestSupport.makeDevice()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeAuthenticator(
        trust: GatewayTrustSnapshot?,
        store: UsedTicketStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> DeviceAuthenticator {
        let store = try store ?? GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        return DeviceAuthenticator(usedTicketStore: store, trust: trust, now: now)
    }

    private func defaultTrust(revoked: Bool = false) -> GatewayTrustSnapshot {
        GatewayAuthTestSupport.trustSnapshot(hostSigner: hostSigner, devices: [(device, revoked)])
    }

    private func signedHello(
        ticket: GatewayRemoteTicket,
        counter: UInt64 = 1,
        deviceKey: P256.Signing.PrivateKey? = nil,
        ticketJSON: JSONValue? = nil
    ) throws -> (data: Data, frame: RemoteClientFrame) {
        let object = GatewayAuthTestSupport.helloObject(ticketJSON: ticketJSON ?? ticket.jsonValue)
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: object,
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            counter: counter,
            deviceKey: deviceKey ?? device.signer
        )
        return try (data, GatewayAuthTestSupport.decodeFrame(data))
    }

    private func admitDefaultHello(
        authenticator: DeviceAuthenticator,
        scopes: Set<String> = [GatewayRemoteScope.sessionsObserve],
        connectionID: UUID = UUID()
    ) async throws -> (device: DeviceAuthenticator.AuthenticatedDevice, ticket: GatewayRemoteTicket, connectionID: UUID) {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: scopes
        )
        let hello = try signedHello(ticket: ticket)
        let admitted = try await authenticator.admitHello(
            rawFrame: hello.data,
            frame: hello.frame,
            connectionID: connectionID
        )
        return (admitted, ticket, connectionID)
    }

    // MARK: - Ticket verification

    func testValidTicketHelloAdmitsWithTicketScopes() async throws {
        let store = try GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        let authenticator = try makeAuthenticator(trust: defaultTrust(), store: store)

        let admitted = try await admitDefaultHello(authenticator: authenticator)

        XCTAssertEqual(admitted.device.deviceID, device.deviceID)
        XCTAssertEqual(admitted.device.scopes, [GatewayRemoteScope.sessionsObserve])
        XCTAssertEqual(admitted.device.ticketID, admitted.ticket.ticketID)
        XCTAssertTrue(store.isUsed(admitted.ticket.ticketID), "One-time ticket must be persisted as used at admission")
    }

    func testExpiredTicketRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve],
            issuedAt: Date().addingTimeInterval(-120),
            ttlMs: 30000
        )
        let hello = try signedHello(ticket: ticket)

        await assertAdmitFails(authenticator, hello: hello, expected: .ticketExpired)
    }

    func testTicketLifetimeAboveMaximumRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve],
            ttlMs: 61000
        )
        let hello = try signedHello(ticket: ticket)

        await assertAdmitFails(authenticator, hello: hello, expected: .invalidTicketLifetime)
    }

    func testTamperedTicketScopesRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        // Escalate scopes after host signing.
        var tampered = try XCTUnwrap(ticket.jsonValue.objectValue)
        tampered["scopes"] = .array([
            .string(GatewayRemoteScope.sessionsObserve),
            .string(GatewayRemoteScope.sessionsOperate)
        ])
        let hello = try signedHello(ticket: ticket, ticketJSON: .object(tampered))

        await assertAdmitFails(authenticator, hello: hello, expected: .ticketSignatureInvalid)
    }

    func testTicketSignedByWrongHostKeyRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let rogueHost = P256.Signing.PrivateKey()
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: rogueHost,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket)

        await assertAdmitFails(authenticator, hello: hello, expected: .ticketSignatureInvalid)
    }

    func testUnknownDeviceRejected() async throws {
        let stranger = GatewayAuthTestSupport.makeDevice(deviceID: "remote:ffff9999")
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: stranger.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket, deviceKey: stranger.signer)

        await assertAdmitFails(authenticator, hello: hello, expected: .unknownDevice(stranger.deviceID))
    }

    func testRevokedDeviceFailsClosedAtHello() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust(revoked: true))
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket)

        await assertAdmitFails(authenticator, hello: hello, expected: .deviceRevoked(device.deviceID))
    }

    func testTrustUnavailableFailsClosed() async throws {
        let authenticator = try makeAuthenticator(trust: nil)
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket)

        await assertAdmitFails(authenticator, hello: hello, expected: .trustUnavailable)
    }

    // MARK: - Frame signature verification

    func testHelloSignedByWrongDeviceKeyRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket, deviceKey: P256.Signing.PrivateKey())

        await assertAdmitFails(authenticator, hello: hello, expected: .signatureInvalid)
    }

    func testHelloWithoutSignatureRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let data = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue)
        )
        let frame = try GatewayAuthTestSupport.decodeFrame(data)

        await assertAdmitFails(authenticator, hello: (data, frame), expected: .signatureRequired("hello"))
    }

    func testUnsupportedSignatureAlgorithmRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue),
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            counter: 1,
            deviceKey: device.signer,
            algorithm: "P384-SHA384"
        )
        let frame = try GatewayAuthTestSupport.decodeFrame(data)

        await assertAdmitFails(
            authenticator,
            hello: (data, frame),
            expected: .unsupportedSignatureAlgorithm("P384-SHA384")
        )
    }

    func testSignatureTicketContextMismatchRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue),
            ticketID: UUID(),
            deviceID: ticket.deviceID,
            counter: 1,
            deviceKey: device.signer
        )
        let frame = try GatewayAuthTestSupport.decodeFrame(data)

        await assertAdmitFails(authenticator, hello: (data, frame), expected: .signatureContextMismatch)
    }

    func testTamperedFrameBodyAfterSigningRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: authenticator)
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "poll", sessionID: "session-a"),
            ticketID: admitted.ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer,
            tamperAfterSigning: { object in
                object["session_id"] = .string("session-b")
            }
        )
        let frame = try GatewayAuthTestSupport.decodeFrame(data)

        await assertVerifyFails(
            authenticator,
            rawFrame: data,
            frame: frame,
            connectionID: admitted.connectionID,
            expected: .signatureInvalid
        )
    }

    // MARK: - Counter monotonicity and replay

    func testReplayedFrameCounterRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: authenticator)
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "poll", sessionID: "session-a"),
            ticketID: admitted.ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer
        )
        let frame = try GatewayAuthTestSupport.decodeFrame(data)

        _ = try await authenticator.verifyFrame(rawFrame: data, frame: frame, connectionID: admitted.connectionID)

        // Byte-identical replay of the signed frame must be rejected.
        await assertVerifyFails(
            authenticator,
            rawFrame: data,
            frame: frame,
            connectionID: admitted.connectionID,
            expected: .counterNotIncreasing(counter: 2, floor: 2)
        )
    }

    func testNonIncreasingCounterRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: authenticator)

        let higher = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "poll", sessionID: "session-a"),
            ticketID: admitted.ticket.ticketID,
            deviceID: device.deviceID,
            counter: 5,
            deviceKey: device.signer
        )
        _ = try await authenticator.verifyFrame(
            rawFrame: higher,
            frame: GatewayAuthTestSupport.decodeFrame(higher),
            connectionID: admitted.connectionID
        )

        let lower = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "poll", sessionID: "session-b"),
            ticketID: admitted.ticket.ticketID,
            deviceID: device.deviceID,
            counter: 3,
            deviceKey: device.signer
        )
        let lowerFrame = try GatewayAuthTestSupport.decodeFrame(lower)
        await assertVerifyFails(
            authenticator,
            rawFrame: lower,
            frame: lowerFrame,
            connectionID: admitted.connectionID,
            expected: .counterNotIncreasing(counter: 3, floor: 5)
        )
    }

    func testCounterFloorFromTrustEnforcedAtHello() async throws {
        let trust = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, false)],
            counterFloor: 10
        )
        let authenticator = try makeAuthenticator(trust: trust)
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let low = try signedHello(ticket: ticket, counter: 5)
        await assertAdmitFails(
            authenticator,
            hello: low,
            expected: .counterNotIncreasing(counter: 5, floor: 10)
        )

        let high = try signedHello(ticket: ticket, counter: 11)
        _ = try await authenticator.admitHello(rawFrame: high.data, frame: high.frame, connectionID: UUID())
    }

    // MARK: - Revocation mid-connection

    func testRevocationAfterAdmissionFailsClosedOnNextFrame() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: authenticator)

        await authenticator.updateTrust(defaultTrust(revoked: true))

        let data = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "poll", sessionID: "session-a"),
            ticketID: admitted.ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer
        )
        let revokedFrame = try GatewayAuthTestSupport.decodeFrame(data)
        await assertVerifyFails(
            authenticator,
            rawFrame: data,
            frame: revokedFrame,
            connectionID: admitted.connectionID,
            expected: .deviceRevoked(device.deviceID)
        )
    }

    func testUpdateTrustReturnsRevokedDeviceIDs() async throws {
        let authenticator = try makeAuthenticator(trust: nil)
        let revoked = await authenticator.updateTrust(defaultTrust(revoked: true))
        XCTAssertEqual(revoked, [device.deviceID])
    }

    func testUpdateTrustReturnsAuthenticatedDeviceMissingFromSnapshot() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        _ = try await admitDefaultHello(authenticator: authenticator)
        let emptyTrust = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: []
        )

        let disconnected = await authenticator.updateTrust(emptyTrust)

        XCTAssertEqual(disconnected, [device.deviceID])
    }

    // MARK: - One-time tickets

    func testTicketReuseWithinProcessRejected() async throws {
        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: authenticator)

        let replayHello = try signedHello(ticket: admitted.ticket, counter: 7)
        await assertAdmitFails(authenticator, hello: replayHello, expected: .ticketAlreadyUsed)
    }

    func testTicketReplayAcrossGatewayRestartRejected() async throws {
        let storeURL = root
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("used-tickets-v1.jsonl")

        let firstStore = try UsedTicketStore(fileURL: storeURL)
        let firstAuthenticator = DeviceAuthenticator(usedTicketStore: firstStore, trust: defaultTrust())
        let admitted = try await admitDefaultHello(authenticator: firstAuthenticator)

        // Simulate a gateway restart: fresh store instance over the same file.
        let restartedStore = try UsedTicketStore(fileURL: storeURL)
        XCTAssertTrue(restartedStore.isUsed(admitted.ticket.ticketID))

        let restartedAuthenticator = DeviceAuthenticator(usedTicketStore: restartedStore, trust: defaultTrust())
        let replayHello = try signedHello(ticket: admitted.ticket, counter: 9)
        await assertAdmitFails(restartedAuthenticator, hello: replayHello, expected: .ticketAlreadyUsed)
    }

    func testUsedTicketPersistenceFailureFailsAdmissionClosed() async throws {
        let storeURL = root
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("used-tickets-v1.jsonl")
        let store = try UsedTicketStore(fileURL: storeURL)
        let authenticator = DeviceAuthenticator(usedTicketStore: store, trust: defaultTrust())

        // Break persistence: insecure mode must fail validation at append time.
        try GatewayFileSecurity.setMode(0o644, path: storeURL.path)
        defer { try? GatewayFileSecurity.setMode(0o600, path: storeURL.path) }

        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let hello = try signedHello(ticket: ticket)
        do {
            _ = try await authenticator.admitHello(rawFrame: hello.data, frame: hello.frame, connectionID: UUID())
            XCTFail("Admission must fail closed when used-ticket persistence fails")
        } catch let error as DeviceAuthenticationError {
            guard case .usedTicketPersistenceFailed = error else {
                return XCTFail("Expected usedTicketPersistenceFailed, got \(error)")
            }
        }
        XCTAssertFalse(store.isUsed(ticket.ticketID))
    }

    // MARK: - App-minted ticket compatibility

    func testAppMintedTicketVerifiesThroughGatewayAuthenticator() async throws {
        // Mint with the app-side crypto to prove the canonical payloads match end to end.
        let appTicket = try RemotePairingCrypto.signTicket(
            deviceID: device.deviceID,
            scopes: [.sessionsObserve, .interactionsRespond],
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(45),
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            hostSigner: hostSigner
        )
        // Wire shape mirrors MCPRemotePairingToolProvider.ticketValue (ms fields are canonical).
        let wireTicket: JSONValue = .object([
            "ticket_id": .string(appTicket.ticketID.uuidString),
            "device_id": .string(appTicket.deviceID),
            "scopes": .array(appTicket.scopes.sorted().map { .string($0.rawValue) }),
            "issued_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(appTicket.issuedAt))),
            "expires_at_ms": .int(Int(RemotePairingCrypto.canonicalMilliseconds(appTicket.expiresAt))),
            "host_fingerprint": .string(appTicket.hostFingerprint),
            "host_signature": .string(appTicket.hostSignature.base64EncodedString())
        ])

        let authenticator = try makeAuthenticator(trust: defaultTrust())
        let parsed = try GatewayRemoteTicket.parse(from: wireTicket)
        let hello = try signedHello(ticket: parsed, ticketJSON: wireTicket)
        let admitted = try await authenticator.admitHello(
            rawFrame: hello.data,
            frame: hello.frame,
            connectionID: UUID()
        )
        XCTAssertEqual(
            admitted.scopes,
            Set([RemoteScope.sessionsObserve, RemoteScope.interactionsRespond].map(\.rawValue))
        )
    }

    // MARK: - Helpers

    private func assertAdmitFails(
        _ authenticator: DeviceAuthenticator,
        hello: (data: Data, frame: RemoteClientFrame),
        expected: DeviceAuthenticationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await authenticator.admitHello(rawFrame: hello.data, frame: hello.frame, connectionID: UUID())
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DeviceAuthenticationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected DeviceAuthenticationError, got \(error)", file: file, line: line)
        }
    }

    private func assertVerifyFails(
        _ authenticator: DeviceAuthenticator,
        rawFrame: Data,
        frame: RemoteClientFrame,
        connectionID: UUID,
        expected: DeviceAuthenticationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await authenticator.verifyFrame(rawFrame: rawFrame, frame: frame, connectionID: connectionID)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DeviceAuthenticationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected DeviceAuthenticationError, got \(error)", file: file, line: line)
        }
    }
}

final class GatewayAuthUsedTicketStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try GatewayTestHelpers.temporaryRoot("used-tickets")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private var storeURL: URL {
        root
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("used-tickets-v1.jsonl")
    }

    func testMarkUsedPersistsAndRejectsDuplicates() throws {
        let store = try UsedTicketStore(fileURL: storeURL)
        let ticketID = UUID()
        let expiry = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)

        XCTAssertFalse(store.isUsed(ticketID))
        try store.markUsed(ticketID: ticketID, expiresAtMs: expiry)
        XCTAssertTrue(store.isUsed(ticketID))
        XCTAssertThrowsError(try store.markUsed(ticketID: ticketID, expiresAtMs: expiry))
    }

    func testEntriesPersistUntilExpiryAcrossRestartAndCompact() throws {
        let base = Date()
        let clock = MutableDateBox(base)
        let store = try UsedTicketStore(fileURL: storeURL, now: { clock.date })
        let liveTicket = UUID()
        let expiringTicket = UUID()
        let baseMs = Int64(base.timeIntervalSince1970 * 1000)
        try store.markUsed(ticketID: liveTicket, expiresAtMs: baseMs + 60000)
        try store.markUsed(ticketID: expiringTicket, expiresAtMs: baseMs + 1000)

        // Restart after the short ticket expired: it is compacted away, the live one stays.
        clock.date = base.addingTimeInterval(30)
        let restarted = try UsedTicketStore(fileURL: storeURL, now: { clock.date })
        XCTAssertTrue(restarted.isUsed(liveTicket))
        XCTAssertFalse(restarted.isUsed(expiringTicket))
        XCTAssertEqual(restarted.liveEntryCount, 1)
    }

    func testInsecureFileModeRejectedOnInit() throws {
        _ = try UsedTicketStore(fileURL: storeURL)
        try GatewayFileSecurity.setMode(0o644, path: storeURL.path)
        XCTAssertThrowsError(try UsedTicketStore(fileURL: storeURL)) { error in
            guard case GatewayPersistenceError.insecurePermissions = error else {
                return XCTFail("Expected insecurePermissions, got \(error)")
            }
        }
    }

    func testCorruptLedgerFailsClosed() throws {
        _ = try UsedTicketStore(fileURL: storeURL)
        try Data("not-json\n".utf8).write(to: storeURL)
        try GatewayFileSecurity.setMode(0o600, path: storeURL.path)
        XCTAssertThrowsError(try UsedTicketStore(fileURL: storeURL))
    }
}
