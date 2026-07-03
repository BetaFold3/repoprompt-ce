import CryptoKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class RemotePairingCryptoTests: XCTestCase {
    func testHostTicketVerificationTamperAndExpiry() throws {
        let hostKey = P256.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 2000)
        let ticket = try RemotePairingCrypto.signTicket(
            ticketID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            deviceID: "remote:abcdef12",
            scopes: [.sessionsObserve, .interactionsRespond],
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(60),
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostKey.publicKey),
            hostSigner: hostKey
        )

        XCTAssertNoThrow(try RemotePairingCrypto.verifyTicket(ticket, hostPublicKey: hostKey.publicKey, now: issuedAt.addingTimeInterval(1)))

        var tampered = ticket
        tampered.hostSignature = Data(repeating: 0, count: ticket.hostSignature.count)
        XCTAssertThrowsError(try RemotePairingCrypto.verifyTicket(tampered, hostPublicKey: hostKey.publicKey, now: issuedAt.addingTimeInterval(1))) { error in
            XCTAssertEqual(error as? RemotePairingCryptoError, .signatureVerificationFailed)
        }

        XCTAssertThrowsError(try RemotePairingCrypto.verifyTicket(ticket, hostPublicKey: hostKey.publicKey, now: issuedAt.addingTimeInterval(61))) { error in
            XCTAssertEqual(error as? RemotePairingCryptoError, .expiredTicket)
        }
    }

    func testDeviceChallengeSignatureRoundTripAndTamper() throws {
        let deviceKey = P256.Signing.PrivateKey()
        let payload = try RemotePairingDeviceProofPayload(
            pairingID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            challenge: "challenge",
            deviceID: "remote:abcdef12",
            displayName: "Phone",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: [.sessionsObserve]
        )
        let signature = try RemotePairingCrypto.signDeviceChallenge(payload: payload, deviceSigner: deviceKey)
        XCTAssertNoThrow(try RemotePairingCrypto.verifyDeviceChallenge(payload: payload, signature: signature))

        let tampered = RemotePairingDeviceProofPayload(
            pairingID: payload.pairingID,
            challenge: "other-challenge",
            deviceID: payload.deviceID,
            displayName: payload.displayName,
            publicKeyRawRepresentation: payload.publicKeyRawRepresentation,
            scopes: payload.scopes
        )
        XCTAssertThrowsError(try RemotePairingCrypto.verifyDeviceChallenge(payload: tampered, signature: signature)) { error in
            XCTAssertEqual(error as? RemotePairingCryptoError, .signatureVerificationFailed)
        }
    }

    func testExpiredChallengeFails() async throws {
        let store = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" })
        let now = Date(timeIntervalSince1970: 100)
        let challenge = try await store.issue(now: now, ttl: 1)

        await XCTAssertThrowsErrorAsync {
            try await store.consume(pairingID: challenge.pairingID, now: now.addingTimeInterval(2))
        } errorHandler: { error in
            XCTAssertEqual(error as? RemotePairingCryptoError, .expiredChallenge)
        }
    }

    func testChallengeIsSingleUseWithinTTL() async throws {
        let store = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" })
        let now = Date(timeIntervalSince1970: 100)
        let challenge = try await store.issue(now: now, ttl: 60)

        _ = try await store.consume(pairingID: challenge.pairingID, now: now.addingTimeInterval(1))
        await XCTAssertThrowsErrorAsync {
            try await store.consume(pairingID: challenge.pairingID, now: now.addingTimeInterval(2))
        } errorHandler: { error in
            XCTAssertEqual(error as? RemotePairingCryptoError, .challengeAlreadyUsed)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
