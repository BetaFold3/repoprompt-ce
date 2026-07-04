import Foundation
@testable import RepoPromptApp
import XCTest

final class GatewayRemoteControlPairingPayloadTests: XCTestCase {
    func testPairingPayloadIncludesHostNameAdditively() throws {
        let payload = RemoteControlPairingPayloadBuilder.payload(
            windowID: 42,
            gatewayURL: "https://studio.tailnet.example:47391",
            hostPublicKey: "host-public-key",
            hostFingerprint: "sha256:abcdef",
            hostName: "Mac Studio"
        )
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "repoprompt_remote_pairing")
        XCTAssertEqual(object["window_id"] as? Int, 42)
        XCTAssertEqual(object["gateway_url"] as? String, "https://studio.tailnet.example:47391")
        XCTAssertEqual(object["host_public_key"] as? String, "host-public-key")
        XCTAssertEqual(object["host_fingerprint"] as? String, "sha256:abcdef")
        XCTAssertEqual(object["host_name"] as? String, "Mac Studio")
    }
}
