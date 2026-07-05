import Foundation
import Logging
@testable import RepoPromptGateway
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

    func testRelayedCallsForwardWindowIDAsPublicPairingContext() async throws {
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
                ["window_id": 7]
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
            XCTAssertEqual(call.arguments["window_id"], .int(7), request.op)
            XCTAssertNil(call.arguments["_windowID"], request.op)
        }
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
