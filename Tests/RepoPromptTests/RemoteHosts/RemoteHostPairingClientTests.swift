import CryptoKit
import Foundation
@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemoteHostPairingClientTests: XCTestCase {
    func testHappyPathPostsProofStoresKeyAndReturnsPairedHostRecord() async throws {
        let hostSigner = P256.Signing.PrivateKey()
        let payload = try RemoteHostTestSupport.pairingPayload(hostSigner: hostSigner, hostName: "Studio")
        let pairingID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let challenge = "fixed-challenge"
        let keychain = InMemoryRemoteClientKeychain()
        let keyStore = RemoteClientKeyStore(keychain: keychain, accessMode: .nonInteractive(reason: .test))
        let pairedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = StubRemoteHostPairingTransport(handlers: [
            { url, body, timeout in
                XCTAssertEqual(url.path, "/api/pair/begin")
                XCTAssertEqual(body, [:])
                XCTAssertEqual(timeout, RemoteHostPairingClient.beginTimeout)
                return try Self.response([
                    "ok": true,
                    "pairing_id": pairingID.uuidString,
                    "challenge": challenge,
                    "host_public_key": payload.hostPublicKey.base64EncodedString(),
                    "host_fingerprint": payload.hostFingerprint,
                    "expires_at": "2026-07-03T00:00:30.000Z"
                ])
            },
            { url, body, timeout in
                XCTAssertEqual(url.path, "/api/pair/complete")
                XCTAssertEqual(timeout, RemoteHostPairingClient.completeTimeout)
                let publicKey = try XCTUnwrap(body["public_key"]?.stringValue)
                let deviceID = try XCTUnwrap(body["device_id"]?.stringValue)
                let scopes = try XCTUnwrap(body["scopes"]?.arrayValue?.compactMap(\.stringValue))
                return try Self.response([
                    "ok": true,
                    "device": [
                        "schema_version": 1,
                        "id": deviceID,
                        "display_name": "Client MacBook",
                        "public_key": publicKey,
                        "public_key_fingerprint": RemotePairingCrypto.fingerprint(
                            forRawPublicKey: Data(base64Encoded: publicKey) ?? Data()
                        ) ?? "",
                        "scopes": scopes,
                        "created_at": "2027-01-15T08:00:00.000Z",
                        "counter_floor": 42,
                        "revoked": false
                    ]
                ])
            }
        ])
        let client = RemoteHostPairingClient(
            transport: stub,
            keyStore: keyStore,
            now: { pairedAt }
        )

        let record = try await client.pair(payload: payload, displayName: "Client MacBook")

        XCTAssertEqual(record.id, payload.hostFingerprint)
        XCTAssertEqual(record.displayName, "Studio")
        XCTAssertEqual(record.gatewayURL, payload.gatewayURL)
        XCTAssertEqual(record.hostPublicKey, payload.hostPublicKey)
        XCTAssertEqual(record.grantedScopes, RemoteHostPairingClient.defaultRequestedScopes)
        XCTAssertEqual(record.lastCounter, 42)
        XCTAssertEqual(record.pairedAt, ISO8601DateFormatter.rp_fractional.date(from: "2027-01-15T08:00:00.000Z"))

        let storedKey = try keyStore.privateKey(forHostID: payload.hostFingerprint)
        XCTAssertEqual(try RemotePairingCrypto.deviceID(forRawPublicKey: storedKey.publicKey.rawRepresentation), record.deviceID)

        let requests = await stub.recordedRequests()
        let completeBody = try XCTUnwrap(requests.last?.body)
        let proof = try XCTUnwrap(try Data(base64Encoded: XCTUnwrap(completeBody["proof"]?.stringValue)))
        let publicKey = try XCTUnwrap(try Data(base64Encoded: XCTUnwrap(completeBody["public_key"]?.stringValue)))
        let scopes = try Set(XCTUnwrap(completeBody["scopes"]?.arrayValue?.compactMap(\.stringValue)))
        let hostProofPayload = try RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge,
            deviceID: XCTUnwrap(completeBody["device_id"]?.stringValue),
            displayName: "Client MacBook",
            publicKeyRawRepresentation: publicKey,
            scopes: Set(scopes.compactMap(RemoteScope.init(rawValue:)))
        )
        XCTAssertNoThrow(try RemotePairingCrypto.verifyDeviceChallenge(payload: hostProofPayload, signature: proof))
    }

    func testRejectsHostKeyMismatchAtBeginWithoutStoringKey() async throws {
        let payload = try RemoteHostTestSupport.pairingPayload(hostSigner: P256.Signing.PrivateKey())
        let mismatchedHostSigner = P256.Signing.PrivateKey()
        let keychain = InMemoryRemoteClientKeychain()
        let keyStore = RemoteClientKeyStore(keychain: keychain, accessMode: .nonInteractive(reason: .test))
        let stub = StubRemoteHostPairingTransport(handlers: [
            { _, _, _ in
                try Self.response([
                    "ok": true,
                    "pairing_id": UUID().uuidString,
                    "challenge": "fixed-challenge",
                    "host_public_key": mismatchedHostSigner.publicKey.rawRepresentation.base64EncodedString(),
                    "host_fingerprint": RemotePairingCrypto.fingerprint(for: mismatchedHostSigner.publicKey)
                ])
            }
        ])
        let client = RemoteHostPairingClient(transport: stub, keyStore: keyStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.pair(payload: payload, displayName: "Client MacBook")
        } errorHandler: { error in
            guard case .hostIdentityMismatch = error as? RemoteHostPairingError else {
                XCTFail("Expected hostIdentityMismatch, got \(error)")
                return
            }
        }
        XCTAssertThrowsError(try keyStore.privateKey(forHostID: payload.hostFingerprint)) { error in
            XCTAssertEqual(error as? RemoteClientKeyStoreError, .missingKey(payload.hostFingerprint))
        }
    }

    func testConsentDenialSurfacesTypedError() async throws {
        let hostSigner = P256.Signing.PrivateKey()
        let payload = try RemoteHostTestSupport.pairingPayload(hostSigner: hostSigner)
        let stub = StubRemoteHostPairingTransport(handlers: [
            { _, _, _ in
                try Self.response([
                    "ok": true,
                    "pairing_id": UUID().uuidString,
                    "challenge": "fixed-challenge",
                    "host_public_key": payload.hostPublicKey.base64EncodedString(),
                    "host_fingerprint": payload.hostFingerprint
                ])
            },
            { _, _, _ in
                try Self.response(
                    ["error": "Remote device pairing was denied by the user."],
                    statusCode: 400
                )
            }
        ])
        let client = RemoteHostPairingClient(
            transport: stub,
            keyStore: RemoteClientKeyStore(keychain: InMemoryRemoteClientKeychain(), accessMode: .nonInteractive(reason: .test))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.pair(payload: payload, displayName: "Client MacBook")
        } errorHandler: { error in
            XCTAssertEqual(error as? RemoteHostPairingError, .consentDenied("Remote device pairing was denied by the user."))
        }
    }

    func testCompleteTimeoutSurfacesTypedError() async throws {
        let hostSigner = P256.Signing.PrivateKey()
        let payload = try RemoteHostTestSupport.pairingPayload(hostSigner: hostSigner)
        let stub = StubRemoteHostPairingTransport(handlers: [
            { _, _, _ in
                try Self.response([
                    "ok": true,
                    "pairing_id": UUID().uuidString,
                    "challenge": "fixed-challenge",
                    "host_public_key": payload.hostPublicKey.base64EncodedString(),
                    "host_fingerprint": payload.hostFingerprint
                ])
            },
            { _, _, _ in
                throw URLError(.timedOut)
            }
        ])
        let client = RemoteHostPairingClient(
            transport: stub,
            keyStore: RemoteClientKeyStore(keychain: InMemoryRemoteClientKeychain(), accessMode: .nonInteractive(reason: .test))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.pair(payload: payload, displayName: "Client MacBook")
        } errorHandler: { error in
            XCTAssertEqual(error as? RemoteHostPairingError, .timeout)
        }
    }

    func testRejectsWorkspaceReadScopeBeforeNetwork() async throws {
        let payload = try RemoteHostTestSupport.pairingPayload()
        let stub = StubRemoteHostPairingTransport(handlers: [])
        let client = RemoteHostPairingClient(
            transport: stub,
            keyStore: RemoteClientKeyStore(keychain: InMemoryRemoteClientKeychain(), accessMode: .nonInteractive(reason: .test))
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.pair(
                payload: payload,
                displayName: "Client MacBook",
                scopes: [RemoteScope.workspaceRead.rawValue]
            )
        } errorHandler: { error in
            XCTAssertEqual(
                error as? RemoteHostPairingError,
                .invalidRequest("Remote client pairing can request only v1 session operation scopes.")
            )
        }
        let requests = await stub.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    private static func response(_ object: [String: Any], statusCode: Int = 200) throws -> RemoteHostPairingHTTPResponse {
        try RemoteHostPairingHTTPResponse(
            statusCode: statusCode,
            data: RemoteHostTestSupport.jsonData(object)
        )
    }
}

private actor StubRemoteHostPairingTransport: RemoteHostPairingTransport {
    typealias Handler = @Sendable (URL, [String: JSONValue], TimeInterval) throws -> RemoteHostPairingHTTPResponse

    struct Request {
        var url: URL
        var body: [String: JSONValue]
        var timeout: TimeInterval
    }

    private var handlers: [Handler]
    private var requests: [Request] = []

    init(handlers: [Handler]) {
        self.handlers = handlers
    }

    func postJSON(
        to url: URL,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> RemoteHostPairingHTTPResponse {
        requests.append(Request(url: url, body: body, timeout: timeout))
        guard !handlers.isEmpty else {
            throw RemoteHostPairingError.invalidResponse("Unexpected request to \(url.absoluteString).")
        }
        let handler = handlers.removeFirst()
        return try handler(url, body, timeout)
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

private extension ISO8601DateFormatter {
    static var rp_fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
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
