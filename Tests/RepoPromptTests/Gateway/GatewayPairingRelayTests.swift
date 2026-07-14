import Foundation
import Logging
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class GatewayPairingRelayTests: XCTestCase {
    func testBeginPairingRateLimitRejectsBurstBeforeCallingAppAgain() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let clock = MutableDateBox(Date(timeIntervalSince1970: 1000))
        let relay = GatewayPairingRelay(appLink: appLink, now: { clock.date })

        for _ in 0 ..< GatewayPairingRelay.rateLimitMaximumRequests {
            let response = await relay.handle(path: GatewayPairingRelay.beginPairingPath, body: Data())
            XCTAssertEqual(response.status, 200)
        }
        let limited = await relay.handle(path: GatewayPairingRelay.beginPairingPath, body: Data())

        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.body.objectValue?["code"]?.stringValue, "rate_limited")
        let calls = await connection.calls
        XCTAssertEqual(calls.count, GatewayPairingRelay.rateLimitMaximumRequests)
    }

    func testAppLinkFailureResponseIncludesUnavailableCode() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection(responses: [.appLinkLost("restart")])
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let relay = GatewayPairingRelay(appLink: appLink)

        let response = await relay.handle(path: GatewayPairingRelay.completePairingPath, body: Data())

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(response.body.objectValue?["code"]?.stringValue, "app_link_unavailable")
        XCTAssertTrue(response.body.objectValue?["error"]?.stringValue?.contains("The app link is unavailable") == true)
    }

    func testPairingDenialPreservesCanonical403Response() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let payload: JSONValue = .object([
            "ok": .bool(false),
            "code": .string("pairing_denied"),
            "error": .string("Remote device pairing was denied by the user."),
            "status": .int(403)
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: payload))
        ])
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let relay = GatewayPairingRelay(appLink: appLink)

        let response = await relay.handle(path: GatewayPairingRelay.completePairingPath, body: Data())

        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.body, payload)
    }

    func testRelayedCallsRemoveWindowIDAndForwardApprovalContext() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let relay = GatewayPairingRelay(appLink: appLink)
        let requests: [(path: String, op: String, body: [String: Any])] = [
            (
                GatewayPairingRelay.beginPairingPath,
                "begin_pairing",
                ["window_id": 7, "approval_context": "fresh-context"]
            ),
            (
                GatewayPairingRelay.completePairingPath,
                "complete_pairing",
                [
                    "window_id": 7,
                    "pairing_id": UUID().uuidString,
                    "display_name": "Client MacBook",
                    "device_id": "remote:feedface",
                    "public_key": "public-key",
                    "proof": "proof",
                    "scopes": ["sessions.observe"]
                ]
            ),
            (
                GatewayPairingRelay.mintTicketPath,
                "mint_ticket",
                [
                    "window_id": 7,
                    "device_id": "remote:feedface"
                ]
            )
        ]

        for request in requests {
            let body = try JSONSerialization.data(withJSONObject: request.body)
            let response = await relay.handle(path: request.path, body: body)
            XCTAssertEqual(response.status, 200, request.op)
        }

        let calls = await connection.calls
        XCTAssertEqual(calls.count, requests.count)
        for (call, request) in zip(calls, requests) {
            XCTAssertEqual(call.name, "remote_pairing", request.op)
            XCTAssertEqual(call.arguments["op"]?.stringValue, request.op)
            XCTAssertNil(call.arguments["window_id"], request.op)
            XCTAssertNil(call.arguments["_windowID"], request.op)
        }
        XCTAssertEqual(calls.first?.arguments["approval_context"], .string("fresh-context"))
    }

    func testDiscoveryRouteValidatesBoundsAndForwardsOnlyNonceAndChannel() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let relay = GatewayPairingRelay(appLink: appLink)
        let body = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "kind": "repoprompt_remote_discovery",
            "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "channel": "release",
            "forwarded_for": "untrusted"
        ])

        let response = await relay.handle(
            path: GatewayPairingRelay.discoveryPath,
            body: body,
            peerAddress: "100.64.0.9"
        )
        XCTAssertEqual(response.status, 200)
        let calls = await connection.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.arguments["op"], .string("discover_host"))
        XCTAssertEqual(call.arguments["channel"], .string("release"))
        XCTAssertNil(call.arguments["forwarded_for"])

        let oversized = await relay.handle(
            path: GatewayPairingRelay.discoveryPath,
            body: Data(repeating: 0, count: GatewayPairingRelay.maximumDiscoveryRequestBytes + 1),
            peerAddress: "100.64.0.9"
        )
        XCTAssertEqual(oversized.status, 413)
    }

    func testRelayedPairingCallsRequestRawJSONToolOutput() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection()
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let relay = GatewayPairingRelay(appLink: appLink)

        let response = await relay.handle(path: GatewayPairingRelay.beginPairingPath, body: Data())

        XCTAssertEqual(response.status, 200)
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "remote_pairing")
        XCTAssertEqual(calls.first?.arguments["op"]?.stringValue, "begin_pairing")
        // Regression: without _rawJSON the app formats results as a ```json fenced
        // markdown block, the relay's codec falls back to {"text": ...}, and the
        // PWA never sees pairing_id (complete_pairing then fails with -32602).
        XCTAssertEqual(calls.first?.arguments["_rawJSON"]?.boolValue, true)
    }
}
