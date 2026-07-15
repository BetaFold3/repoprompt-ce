import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class RemoteWireProtocolTests: XCTestCase {
    func testClientFrameRoundTripAndUnknownFieldTolerance() throws {
        let json = """
        {
          "v": 1,
          "type": "start",
          "request_id": "req-1",
          "payload": {"message": "hello", "extra_future_field": true},
          "client_time": "2026-07-02T00:00:00Z",
          "sig": null,
          "future_top_level": "ignored"
        }
        """.data(using: .utf8)!

        let frame = try RemoteWireProtocol.decodeClientFrame(from: json)

        XCTAssertEqual(frame.v, 1)
        XCTAssertEqual(frame.type, "start")
        XCTAssertEqual(frame.requestID, "req-1")
        XCTAssertEqual(frame.payload?.objectValue?["message"]?.stringValue, "hello")
        XCTAssertEqual(frame.payload?.objectValue?["extra_future_field"]?.boolValue, true)
    }

    func testVersionRejection() throws {
        let data = #"{"v":2,"type":"ping","sig":null}"#.data(using: .utf8)!
        XCTAssertThrowsError(try RemoteWireProtocol.decodeClientFrame(from: data)) { error in
            XCTAssertEqual(error as? RemoteWireProtocolError, .unsupportedVersion(2))
        }
    }

    func testMutatingOperationsRequireRequestID() throws {
        for type in ["start", "steer", "respond", "cancel", "open_workspace"] {
            let data = "{\"v\":1,\"type\":\"\(type)\",\"payload\":{},\"sig\":null}".data(using: .utf8)!
            XCTAssertThrowsError(try RemoteWireProtocol.decodeClientFrame(from: data), type) { error in
                XCTAssertEqual(error as? RemoteWireProtocolError, .missingRequestID(type))
            }
        }
    }

    func testOpenWorkspaceIsARecognizedMutatingFrame() throws {
        XCTAssertTrue(RemoteWireProtocol.clientFrameTypes.contains("open_workspace"))
        XCTAssertTrue(RemoteWireProtocol.mutatingClientFrameTypes.contains("open_workspace"))
        let data = #"{"v":1,"type":"open_workspace","request_id":"open-1","payload":{"workspace_name":"Project"},"sig":null}"#.data(using: .utf8)!
        XCTAssertEqual(try RemoteWireProtocol.decodeClientFrame(from: data).type, "open_workspace")
    }

    func testListAgentsFrameIsAcceptedWithoutRequestID() throws {
        let data = #"{"v":1,"type":"list_agents","payload":{},"sig":null}"#.data(using: .utf8)!
        let frame = try RemoteWireProtocol.decodeClientFrame(from: data)
        XCTAssertEqual(frame.type, "list_agents")
        XCTAssertNil(frame.requestID)
    }

    func testUnknownServerFrameTypesDecodeForAdditiveEvolution() throws {
        let data = #"{"v":1,"type":"interaction_resolved","payload":{"ok":true}}"#.data(using: .utf8)!
        let frame = try RemoteWireProtocol.decodeServerFrame(from: data)
        XCTAssertEqual(frame.type, "interaction_resolved")
        XCTAssertEqual(frame.payload?.objectValue?["ok"]?.boolValue, true)
    }

    func testServerSequenceEpochRoundTripsAndLegacyFrameDecodesNil() throws {
        let frame = RemoteServerFrame(
            type: "session_update",
            sessionID: "session-1",
            seq: 7,
            seqEpoch: "epoch-1",
            payload: .object(["status": .string("running")])
        )

        let encoded = try RemoteWireProtocol.encodeServerFrame(frame)
        let decoded = try RemoteWireProtocol.decodeServerFrame(from: encoded)
        let legacy = try RemoteWireProtocol.decodeServerFrame(
            from: Data(#"{"v":1,"type":"session_update","session_id":"session-1","seq":1}"#.utf8)
        )

        XCTAssertEqual(decoded.seqEpoch, "epoch-1")
        XCTAssertNil(legacy.seqEpoch)
    }

    func testCanonicalJSONEncodingSortsObjectKeys() throws {
        let value: JSONValue = .object(["b": .int(2), "a": .int(1)])
        let canonical = try RemoteWireProtocol.canonicalJSONString(for: value)
        XCTAssertEqual(canonical, #"{"a":1,"b":2}"#)
    }
}
