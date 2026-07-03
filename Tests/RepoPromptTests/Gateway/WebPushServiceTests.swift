import CryptoKit
import Foundation
@testable import RepoPromptGateway
import XCTest

final class WebPushServiceTests: XCTestCase {
    // MARK: - VAPID JWT (RFC 8292)

    func testVAPIDJWTShapeAndSignature() throws {
        let key = P256.Signing.PrivateKey()
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try WebPushCrypto.vapidJWT(
            audience: "https://push.example.net",
            subject: "https://github.com/repoprompt",
            expiration: expiration,
            pushSender: key
        )
        let segments = jwt.split(separator: ".")
        XCTAssertEqual(segments.count, 3, "JWT must be header.claims.signature")

        let headerData = try XCTUnwrap(WebPushBase64URL.decode(String(segments[0])))
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "JWT")

        let claimsData = try XCTUnwrap(WebPushBase64URL.decode(String(segments[1])))
        let claims = try XCTUnwrap(try JSONSerialization.jsonObject(with: claimsData) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://push.example.net")
        XCTAssertEqual(claims["sub"] as? String, "https://github.com/repoprompt")
        XCTAssertEqual(claims["exp"] as? Int, 1_800_000_000)
        XCTAssertEqual(Set(claims.keys), ["aud", "exp", "sub"])

        // ES256 JWS: raw 64-byte r||s signature over "header.claims".
        let signatureData = try XCTUnwrap(WebPushBase64URL.decode(String(segments[2])))
        XCTAssertEqual(signatureData.count, 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    func testVAPIDAuthorizationHeaderShape() throws {
        let key = P256.Signing.PrivateKey()
        let header = try WebPushCrypto.vapidAuthorizationHeader(
            endpoint: XCTUnwrap(URL(string: "https://push.example.net/w/some-token")),
            subject: "https://github.com/repoprompt",
            expiration: Date(timeIntervalSince1970: 1_800_000_000),
            pushSender: key
        )
        XCTAssertTrue(header.hasPrefix("vapid t="))
        XCTAssertTrue(header.contains(", k="))
        let publicKeySegment = try XCTUnwrap(header.components(separatedBy: ", k=").last)
        XCTAssertEqual(WebPushBase64URL.decode(publicKeySegment), key.publicKey.x963Representation)
    }

    func testPushServiceOriginDerivation() throws {
        XCTAssertEqual(
            try WebPushCrypto.pushServiceOrigin(for: XCTUnwrap(URL(string: "https://push.example.net/w/abc?x=1"))),
            "https://push.example.net"
        )
        XCTAssertEqual(
            try WebPushCrypto.pushServiceOrigin(for: XCTUnwrap(URL(string: "https://push.example.net:8443/w/abc"))),
            "https://push.example.net:8443"
        )
        XCTAssertNil(try WebPushCrypto.pushServiceOrigin(for: XCTUnwrap(URL(string: "http://insecure.example.net/w"))))
    }

    // MARK: - RFC 8291 Appendix A encryption vector

    func testEncryptionMatchesRFC8291AppendixAVector() throws {
        let plaintext = try XCTUnwrap(
            WebPushBase64URL.decode("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24")
        )
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), "When I grow up, I want to be a watermelon")
        let uaPublic = try XCTUnwrap(WebPushBase64URL.decode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        ))
        let authSecret = try XCTUnwrap(WebPushBase64URL.decode("BTBZMqHH6r4Tts7J_aSIgg"))
        let asPrivateRaw = try XCTUnwrap(WebPushBase64URL.decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let asPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: asPrivateRaw)
        XCTAssertEqual(
            WebPushBase64URL.encode(asPrivate.publicKey.x963Representation),
            "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        )
        let salt = try XCTUnwrap(WebPushBase64URL.decode("DGv6ra1nlYgDCS1FRnbzlw"))

        let body = try WebPushCrypto.encrypt(
            plaintext: plaintext,
            userAgentPublicKey: uaPublic,
            authSecret: authSecret,
            applicationServerAgreementIdentity: asPrivate,
            salt: salt
        )

        let expected = try XCTUnwrap(WebPushBase64URL.decode(
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlml"
                + "MoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        ))
        XCTAssertEqual(body, expected, "aes128gcm body must match the RFC 8291 Appendix A vector byte-for-byte")
    }

    func testEncryptionHeaderLayout() throws {
        let uaKey = P256.KeyAgreement.PrivateKey()
        let authSecret = Data((0 ..< 16).map { UInt8($0) })
        let body = try WebPushCrypto.encrypt(
            plaintext: Data("hi".utf8),
            userAgentPublicKey: uaKey.publicKey.x963Representation,
            authSecret: authSecret
        )
        // salt(16) || rs(4) || idlen(1) || keyid(65) || ciphertext+tag
        XCTAssertGreaterThan(body.count, 86)
        let recordSize = body.subdata(in: 16 ..< 20).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(recordSize, 4096)
        XCTAssertEqual(body[20], 65)
        XCTAssertEqual(body[21], 0x04, "keyid must be the uncompressed application-server public key")
    }

    func testEncryptRejectsBadSubscriptionKeyMaterial() {
        XCTAssertThrowsError(try WebPushCrypto.encrypt(
            plaintext: Data("x".utf8),
            userAgentPublicKey: Data([0x04, 0x01]),
            authSecret: Data(repeating: 0, count: 16)
        ))
        let uaKey = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try WebPushCrypto.encrypt(
            plaintext: Data("x".utf8),
            userAgentPublicKey: uaKey.publicKey.x963Representation,
            authSecret: Data(repeating: 0, count: 4)
        ))
    }

    // MARK: - Stubbed send

    private final class RecordingPushHTTPClient: WebPushHTTPClient, @unchecked Sendable {
        struct Request {
            let url: URL
            let headers: [(name: String, value: String)]
            let body: Data
        }

        private let lock = NSLock()
        private var statuses: [Int]
        private(set) var requests: [Request] = []

        init(statuses: [Int]) {
            self.statuses = statuses
        }

        func post(to url: URL, headers: [(name: String, value: String)], body: Data) async throws -> Int {
            lock.lock()
            defer { lock.unlock() }
            requests.append(Request(url: url, headers: headers, body: body))
            return statuses.isEmpty ? 201 : statuses.removeFirst()
        }

        func header(_ name: String, ofRequest index: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard requests.indices.contains(index) else { return nil }
            return requests[index].headers.first { $0.name == name }?.value
        }
    }

    private func makeService(
        statuses: [Int]
    ) throws -> (WebPushService, WebPushSubscriptionStore, RecordingPushHTTPClient) {
        let root = try GatewayTestHelpers.temporaryRoot()
        let store = try WebPushSubscriptionStore(
            fileURL: root
                .appendingPathComponent("push", isDirectory: true)
                .appendingPathComponent("push-subscriptions-v1.json")
        )
        let uaKey = P256.KeyAgreement.PrivateKey()
        let subscription = WebPushSubscription(
            endpoint: "https://push.example.net/w/device-token",
            p256dh: WebPushBase64URL.encode(uaKey.publicKey.x963Representation),
            auth: WebPushBase64URL.encode(Data(repeating: 7, count: 16)),
            createdAtMs: 0
        )
        try store.setSubscription(subscription, forDevice: "remote:aaaa1111")
        let client = RecordingPushHTTPClient(statuses: statuses)
        let pushSender = P256.Signing.PrivateKey()
        let service = WebPushService(
            pushSender: pushSender,
            subscriptionStore: store,
            httpClient: client
        )
        return (service, store, client)
    }

    func testSendWakePostsEncryptedIdentifierOnlyPayloadWithVAPIDHeaders() async throws {
        let (service, _, client) = try makeService(statuses: [201])
        await service.sendWake(
            deviceID: "remote:aaaa1111",
            payload: WebPushWakePayload(kind: .waitingForInput, sessionID: "s-1", interactionID: "i-1")
        )
        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://push.example.net/w/device-token")
        XCTAssertEqual(client.header("Content-Encoding", ofRequest: 0), "aes128gcm")
        XCTAssertEqual(client.header("TTL", ofRequest: 0), "3600")
        XCTAssertEqual(client.header("Urgency", ofRequest: 0), "high")
        XCTAssertEqual(client.header("Content-Type", ofRequest: 0), "application/octet-stream")
        let authorization = try XCTUnwrap(client.header("Authorization", ofRequest: 0))
        XCTAssertTrue(authorization.hasPrefix("vapid t="))
        XCTAssertTrue(authorization.contains(", k="))
        // The body is aes128gcm ciphertext: it must never contain the plaintext.
        XCTAssertNil(request.body.range(of: Data("s-1".utf8)))
        XCTAssertNil(request.body.range(of: Data("waiting_for_input".utf8)))
    }

    func testSendWakeForUnknownDeviceDoesNothing() async throws {
        let (service, _, client) = try makeService(statuses: [201])
        await service.sendWake(
            deviceID: "remote:unknown",
            payload: WebPushWakePayload(kind: .sessionTerminal, sessionID: "s-1", interactionID: nil)
        )
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testGoneEndpointRemovesSubscription() async throws {
        let (service, store, client) = try makeService(statuses: [410])
        await service.sendWake(
            deviceID: "remote:aaaa1111",
            payload: WebPushWakePayload(kind: .sessionTerminal, sessionID: "s-1", interactionID: nil)
        )
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertFalse(store.hasSubscription(forDevice: "remote:aaaa1111"))

        // Subsequent wakes have no subscription and must not post.
        await service.sendWake(
            deviceID: "remote:aaaa1111",
            payload: WebPushWakePayload(kind: .sessionTerminal, sessionID: "s-1", interactionID: nil)
        )
        XCTAssertEqual(client.requests.count, 1)
    }

    func testFailureStatusKeepsSubscriptionAndNeverThrows() async throws {
        let (service, store, client) = try makeService(statuses: [500, 201])
        await service.sendWake(
            deviceID: "remote:aaaa1111",
            payload: WebPushWakePayload(kind: .waitingForInput, sessionID: "s-1", interactionID: nil)
        )
        XCTAssertTrue(store.hasSubscription(forDevice: "remote:aaaa1111"))
        await service.sendWake(
            deviceID: "remote:aaaa1111",
            payload: WebPushWakePayload(kind: .waitingForInput, sessionID: "s-1", interactionID: nil)
        )
        XCTAssertEqual(client.requests.count, 2)
    }
}

final class WebPushSubscriptionStoreTests: XCTestCase {
    private func makeStoreURL() throws -> URL {
        try GatewayTestHelpers.temporaryRoot()
            .appendingPathComponent("push", isDirectory: true)
            .appendingPathComponent("push-subscriptions-v1.json")
    }

    func testSubscriptionsPersistAcrossRestartAndRemoveOnRevoke() throws {
        let url = try makeStoreURL()
        let store = try WebPushSubscriptionStore(fileURL: url)
        let subscription = WebPushSubscription(
            endpoint: "https://push.example.net/w/tok",
            p256dh: "BASE64URLKEY",
            auth: "BASE64URLAUTH",
            createdAtMs: 123
        )
        try store.setSubscription(subscription, forDevice: "remote:aaaa1111")

        let reloaded = try WebPushSubscriptionStore(fileURL: url)
        XCTAssertEqual(reloaded.subscription(forDevice: "remote:aaaa1111"), subscription)
        XCTAssertEqual(reloaded.deviceIDs, ["remote:aaaa1111"])

        XCTAssertTrue(try reloaded.removeSubscription(forDevice: "remote:aaaa1111"))
        XCTAssertFalse(reloaded.hasSubscription(forDevice: "remote:aaaa1111"))
        let reloadedAgain = try WebPushSubscriptionStore(fileURL: url)
        XCTAssertFalse(reloadedAgain.hasSubscription(forDevice: "remote:aaaa1111"))
    }

    func testStoreFileUsesSecureMode() throws {
        let url = try makeStoreURL()
        _ = try WebPushSubscriptionStore(fileURL: url)
        var statBuffer = stat()
        XCTAssertEqual(lstat(url.path, &statBuffer), 0)
        XCTAssertEqual(Int(statBuffer.st_mode & 0o777), 0o600)
    }

    func testParseAcceptsStandardPushSubscriptionJSONShapeOnly() {
        let valid = JSONValue.object([
            "endpoint": .string("https://push.example.net/w/tok"),
            "expirationTime": .null,
            "keys": .object([
                "p256dh": .string("KEY"),
                "auth": .string("AUTH")
            ])
        ])
        XCTAssertNotNil(WebPushSubscription.parse(from: valid, nowMs: 1))

        let insecureEndpoint = JSONValue.object([
            "endpoint": .string("http://push.example.net/w/tok"),
            "keys": .object(["p256dh": .string("KEY"), "auth": .string("AUTH")])
        ])
        XCTAssertNil(WebPushSubscription.parse(from: insecureEndpoint, nowMs: 1))

        let missingKeys = JSONValue.object(["endpoint": .string("https://push.example.net/w/tok")])
        XCTAssertNil(WebPushSubscription.parse(from: missingKeys, nowMs: 1))
    }

    func testCorruptStoreFailsClosed() throws {
        let url = try makeStoreURL()
        _ = try WebPushSubscriptionStore(fileURL: url)
        try Data("[not the schema]".utf8).write(to: url)
        try GatewayFileSecurity.setMode(0o600, path: url.path)
        XCTAssertThrowsError(try WebPushSubscriptionStore(fileURL: url)) { error in
            guard case GatewayPersistenceError.loadFailed = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
        }
    }
}
