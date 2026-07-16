import CryptoKit
import Foundation
@testable import RepoPromptApp
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class RemoteWireCanonicalCompatTests: XCTestCase {
    func testCanonicalStringsAndHashesMatchPreMoveGatewayGoldens() throws {
        let canonicalValue: JSONValue = .object([
            "z": .array([.int(3), .string("slashes / stay"), .bool(false)]),
            "a": .object([
                "nested": .string("line\nquote \" ok"),
                "null": .null
            ]),
            "m": .double(1.5)
        ])
        let canonical = try RemoteWireProtocol.canonicalJSONString(for: canonicalValue)
        XCTAssertEqual(
            canonical,
            #"{"a":{"nested":"line\nquote \" ok","null":null},"m":1.5,"z":[3,"slashes / stay",false]}"#
        )
        XCTAssertEqual(
            RemoteWireProtocol.sha256Hex(of: Data(canonical.utf8)),
            "3333737ea15a4b3de00dd6f15773fd05d5f22bec2936fd0fa511c16d691dd6a1"
        )

        let rawFrameObject: JSONValue = .object([
            "sig": .object(["ignored": .bool(true)]),
            "payload": .object(["message": .string("go"), "model_id": .string("pair")]),
            "request_id": .string("req-golden"),
            "type": .string("start"),
            "v": .int(1)
        ])
        let rawFrameData = try RemoteWireProtocol.canonicalData(for: rawFrameObject)
        XCTAssertEqual(
            String(data: rawFrameData, encoding: .utf8),
            #"{"payload":{"message":"go","model_id":"pair"},"request_id":"req-golden","sig":{"ignored":true},"type":"start","v":1}"#
        )
        let rawFrameHash = try RemoteWireProtocol.canonicalFrameHashHex(fromRawFrameData: rawFrameData)
        XCTAssertEqual(rawFrameHash, "25f7ef25d50b2e0e368cd6b1b2cad81664ba98432aecdf8d09f529677397e582")

        let ticketID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let signingPayload = RemoteWireProtocol.frameSigningPayload(
            ticketID: ticketID,
            deviceID: "remote:abcd1234",
            counter: 1_725_000_000_123,
            frameHashHex: rawFrameHash
        )
        XCTAssertEqual(
            String(data: signingPayload, encoding: .utf8),
            "RemoteFrameV1\n11111111-2222-3333-4444-555555555555\nremote:abcd1234\n1725000000123\n25f7ef25d50b2e0e368cd6b1b2cad81664ba98432aecdf8d09f529677397e582\n"
        )
        XCTAssertEqual(
            RemoteWireProtocol.sha256Hex(of: signingPayload),
            "bf3d3fe5452ccdf179f0fb846f6dd1e1f9184b02bd8761aa168b1232a1d4be6a"
        )

        let serverFrame = RemoteServerFrame.commandError(
            requestID: "req-golden",
            sessionID: "session-golden",
            code: "binding_required",
            message: "Bind first",
            details: .object([
                "windows": .array([.object(["window_id": .int(7), "workspace_name": .string("Main")])])
            ])
        )
        let serverCanonical = try String(data: RemoteWireProtocol.encodeServerFrame(serverFrame), encoding: .utf8)
        XCTAssertEqual(
            serverCanonical,
            #"{"payload":{"code":"binding_required","details":{"windows":[{"window_id":7,"workspace_name":"Main"}]},"message":"Bind first"},"request_id":"req-golden","session_id":"session-golden","type":"command_error","v":1}"#
        )
        XCTAssertEqual(
            try RemoteWireProtocol.sha256Hex(of: Data(XCTUnwrap(serverCanonical).utf8)),
            "70ea0aeb00029dd91f4944456b3f96f7fcec62bb66d0cb5bccbbd7c2e3222522"
        )

        let commandFrame = RemoteClientFrame(
            type: "start",
            requestID: "req-golden",
            sessionID: "session-golden",
            payload: .object(["message": .string("go"), "model_id": .string("pair")])
        )
        let fingerprint = try RemoteWireProtocol.commandFingerprint(for: commandFrame)
        XCTAssertEqual(fingerprint.operation, "start")
        XCTAssertEqual(fingerprint.canonicalPayloadSHA256, "a24e4521beea101ecf8b7d7a3e769074b0efcf6e273b1e5084efa8c1d262f1cd")
    }

    func testRemoteFrameSignerEmitsCanonicalBytesWithGatewayVerifiableSignature() throws {
        let deviceKey = P256.Signing.PrivateKey()
        let ticketID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        var signer = RemoteFrameSigner(
            deviceSigner: deviceKey,
            ticketID: ticketID,
            deviceID: "remote:abcd1234",
            lastCounter: 10
        )
        let frame = RemoteClientFrame(
            type: "ping",
            payload: .object(["nonce": .string("n1")]),
            clientTime: "2026-07-03T00:00:00Z"
        )

        let signed = try signer.sign(frame, nowMs: 5)
        XCTAssertEqual(signed.signature.counter, 11)
        XCTAssertEqual(signer.lastCounter, 11)

        let decoded = try RemoteWireProtocol.decodeClientFrame(from: signed.data)
        let signature = try XCTUnwrap(RemoteFrameSignature(jsonValue: decoded.sig))
        XCTAssertEqual(signature.ticketID, ticketID)
        XCTAssertEqual(signature.deviceID, "remote:abcd1234")
        XCTAssertEqual(signature.counter, 11)

        let frameHash = try RemoteWireProtocol.canonicalFrameHashHex(fromRawFrameData: signed.data)
        let signingPayload = RemoteWireProtocol.frameSigningPayload(
            ticketID: ticketID,
            deviceID: "remote:abcd1234",
            counter: 11,
            frameHashHex: frameHash
        )
        let ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature.signature)
        XCTAssertTrue(deviceKey.publicKey.isValidSignature(ecdsaSignature, for: signingPayload))

        let recanonicalized = try RemoteWireProtocol.canonicalData(
            for: JSONDecoder().decode(JSONValue.self, from: signed.data)
        )
        XCTAssertEqual(recanonicalized, signed.data)

        let second = try signer.sign(RemoteClientFrame(type: "ping"), nowMs: 1_725_000_000_123)
        XCTAssertEqual(second.signature.counter, 1_725_000_000_123)
        XCTAssertEqual(signer.lastCounter, 1_725_000_000_123)
    }

    func testRemoteTicketVerifyMatchesGatewayTicketContract() throws {
        let hostKey = P256.Signing.PrivateKey()
        let ticketID = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"))
        let issuedAtMs: Int64 = 1_725_000_000_000
        let unsigned = RemoteTicket(
            ticketID: ticketID,
            deviceID: "remote:abcd1234",
            scopes: [GatewayRemoteScope.sessionsObserve, GatewayRemoteScope.interactionsRespond],
            issuedAtMs: issuedAtMs,
            expiresAtMs: issuedAtMs + 45000,
            hostFingerprint: GatewayAuthTestSupport.fingerprint(hostKey.publicKey),
            hostSignature: Data()
        )
        let signature = try hostKey.signature(for: unsigned.canonicalPayload).rawRepresentation
        let ticket = RemoteTicket(
            ticketID: unsigned.ticketID,
            deviceID: unsigned.deviceID,
            scopes: unsigned.scopes,
            issuedAtMs: unsigned.issuedAtMs,
            expiresAtMs: unsigned.expiresAtMs,
            hostFingerprint: unsigned.hostFingerprint,
            hostSignature: signature
        )

        XCTAssertNoThrow(try ticket.verify(hostPublicKeyRaw: hostKey.publicKey.rawRepresentation, nowMs: issuedAtMs + 1000))

        XCTAssertThrowsError(try ticket.verify(hostPublicKeyRaw: hostKey.publicKey.rawRepresentation, nowMs: issuedAtMs + 46000)) { error in
            XCTAssertEqual(error as? RemoteTicketError, .ticketExpired)
        }

        let wrongHost = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try ticket.verify(hostPublicKeyRaw: wrongHost.publicKey.rawRepresentation, nowMs: issuedAtMs + 1000)) { error in
            XCTAssertEqual(error as? RemoteTicketError, .hostFingerprintMismatch)
        }
    }

    func testRemotePairingProofCanonicalPayloadMirrorsAppCrypto() throws {
        let deviceKey = P256.Signing.PrivateKey()
        let pairingID = try XCTUnwrap(UUID(uuidString: "cccccccc-dddd-eeee-ffff-111111111111"))
        let wirePayload = RemotePairingDeviceChallengeV1(
            pairingID: pairingID,
            challenge: "challenge",
            deviceID: "remote:abcd1234",
            displayName: "MacBook Pro",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: [RemoteScope.sessionsObserve.rawValue, RemoteScope.interactionsRespond.rawValue]
        )
        let appPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: "challenge",
            deviceID: "remote:abcd1234",
            displayName: "MacBook Pro",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: [.sessionsObserve, .interactionsRespond]
        )

        XCTAssertEqual(
            RemotePairingProof.canonicalDeviceChallengePayload(wirePayload),
            RemotePairingCrypto.canonicalDeviceChallengePayload(appPayload)
        )
        let signature = try RemotePairingProof.signDeviceChallenge(wirePayload, deviceSigner: deviceKey)
        XCTAssertNoThrow(try RemotePairingCrypto.verifyDeviceChallenge(payload: appPayload, signature: signature))
    }
}
