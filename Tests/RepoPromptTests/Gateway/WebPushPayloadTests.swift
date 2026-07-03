import Foundation
@testable import RepoPromptGateway
import XCTest

/// Enforces the M5 hard security rule: push payloads carry identifiers only.
/// This suite must fail if prompt/transcript/path/model/approval fields are ever
/// introduced into the wake payload.
final class WebPushPayloadTests: XCTestCase {
    /// The complete, closed set of allowed push payload keys.
    private static let allowedKeys: Set<String> = ["v", "kind", "session_id", "interaction_id"]

    private func encodedObject(_ payload: WebPushWakePayload) throws -> [String: Any] {
        let data = try payload.encoded()
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testWaitingForInputPayloadSchemaIsExactlyPlanShape() throws {
        let payload = WebPushWakePayload(
            kind: .waitingForInput,
            sessionID: "11111111-1111-1111-1111-111111111111",
            interactionID: "22222222-2222-2222-2222-222222222222"
        )
        let object = try encodedObject(payload)
        XCTAssertEqual(Set(object.keys), Self.allowedKeys)
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "waiting_for_input")
        XCTAssertEqual(object["session_id"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(object["interaction_id"] as? String, "22222222-2222-2222-2222-222222222222")
    }

    func testSessionTerminalPayloadOmitsInteractionID() throws {
        let payload = WebPushWakePayload(
            kind: .sessionTerminal,
            sessionID: "11111111-1111-1111-1111-111111111111",
            interactionID: nil
        )
        let object = try encodedObject(payload)
        XCTAssertEqual(Set(object.keys), ["v", "kind", "session_id"])
        XCTAssertEqual(object["kind"] as? String, "session_terminal")
    }

    /// Redaction gate: every encoded key must be in the allowed identifier set and
    /// must never resemble prompt/transcript/path/model/approval context. This
    /// fails when someone extends the payload with state-bearing fields.
    func testRedactionRejectsStateBearingFields() throws {
        let payload = WebPushWakePayload(
            kind: .waitingForInput,
            sessionID: "session",
            interactionID: "interaction"
        )
        let object = try encodedObject(payload)
        let forbiddenFragments = [
            "prompt", "transcript", "text", "message", "content", "file",
            "path", "workspace", "model", "approval", "question", "answer",
            "title", "name", "log", "diff", "command"
        ]
        for key in object.keys {
            XCTAssertTrue(
                Self.allowedKeys.contains(key),
                "Push payload key '\(key)' is not in the allowed identifier-only schema."
            )
            let lowered = key.lowercased()
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    lowered.contains(fragment),
                    "Push payload key '\(key)' looks like leaked state ('\(fragment)')."
                )
            }
        }
        // Values must be identifiers/enums only: never multi-line or oversized.
        for (key, value) in object {
            if let string = value as? String {
                XCTAssertFalse(string.contains("\n"), "Push payload value for '\(key)' must not be multi-line.")
                XCTAssertLessThanOrEqual(string.count, 128, "Push payload value for '\(key)' is suspiciously large.")
            }
        }
    }

    /// Structural guard: adding any stored property to `WebPushWakePayload` fails
    /// this test until the redaction contract above is deliberately revisited.
    func testPayloadShapeHasNoUnreviewedStoredProperties() {
        let payload = WebPushWakePayload(kind: .waitingForInput, sessionID: "s", interactionID: nil)
        let properties = Mirror(reflecting: payload).children.compactMap(\.label).sorted()
        XCTAssertEqual(properties, ["interactionID", "kind", "sessionID"])
    }

    func testWakeKindsAreOnlyTheTwoPlanKinds() {
        XCTAssertEqual(WebPushWakePayload.Kind.waitingForInput.rawValue, "waiting_for_input")
        XCTAssertEqual(WebPushWakePayload.Kind.sessionTerminal.rawValue, "session_terminal")
    }
}
