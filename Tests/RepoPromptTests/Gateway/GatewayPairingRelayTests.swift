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
