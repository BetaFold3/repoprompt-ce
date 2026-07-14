import Foundation
@testable import RepoPromptApp
import XCTest

/// Plan §6.4: `AgentSession.origin` provenance with backward-compatible decoding.
final class AgentSessionOriginTests: XCTestCase {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func sessionJSON(extraFields: String) -> Data {
        Data("""
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy Session",
            "savedAt": "2026-07-01T00:00:00Z",
            "autoEditEnabled": false\(extraFields.isEmpty ? "" : ",")
            \(extraFields)
        }
        """.utf8)
    }

    // MARK: - Old-JSON migration decode

    func testLegacyJSONWithIsMCPOriginatedTrueDecodesAsMCPWithoutClientID() throws {
        let session = try decoder.decode(AgentSession.self, from: sessionJSON(extraFields: #""isMCPOriginated": true"#))
        XCTAssertEqual(session.origin, .mcp(clientID: nil))
        XCTAssertTrue(session.isMCPOriginated)
    }

    func testLegacyJSONWithIsMCPOriginatedFalseDecodesAsUser() throws {
        let session = try decoder.decode(AgentSession.self, from: sessionJSON(extraFields: #""isMCPOriginated": false"#))
        XCTAssertEqual(session.origin, .user)
        XCTAssertFalse(session.isMCPOriginated)
    }

    func testLegacyJSONWithoutOriginOrLegacyFlagDecodesAsUser() throws {
        let session = try decoder.decode(AgentSession.self, from: sessionJSON(extraFields: ""))
        XCTAssertEqual(session.origin, .user)
        XCTAssertFalse(session.isMCPOriginated)
    }

    // MARK: - New-JSON round-trip

    func testRemoteOriginRoundTripsAndKeepsLegacyFlagInSync() throws {
        let json = sessionJSON(extraFields: #""origin": {"kind": "remote", "deviceID": "aaaa1111"}, "isMCPOriginated": true"#)
        let session = try decoder.decode(AgentSession.self, from: json)
        XCTAssertEqual(session.origin, .remote(deviceID: "aaaa1111"))
        XCTAssertTrue(session.isMCPOriginated)

        let encoded = try encoder.encode(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let originObject = try XCTUnwrap(object["origin"] as? [String: Any], "New JSON must carry structured origin")
        XCTAssertEqual(originObject["kind"] as? String, "remote")
        XCTAssertEqual(originObject["deviceID"] as? String, "aaaa1111")
        XCTAssertEqual(object["isMCPOriginated"] as? Bool, true, "Legacy flag stays serialized for older builds")

        let reDecoded = try decoder.decode(AgentSession.self, from: encoded)
        XCTAssertEqual(reDecoded.origin, .remote(deviceID: "aaaa1111"))
        XCTAssertTrue(reDecoded.isMCPOriginated)
    }

    func testMCPOriginWithClientIDRoundTrips() throws {
        let json = sessionJSON(extraFields: #""origin": {"kind": "mcp", "clientID": "claude-code"}, "isMCPOriginated": true"#)
        let session = try decoder.decode(AgentSession.self, from: json)
        XCTAssertEqual(session.origin, .mcp(clientID: "claude-code"))

        let reDecoded = try decoder.decode(AgentSession.self, from: encoder.encode(session))
        XCTAssertEqual(reDecoded.origin, .mcp(clientID: "claude-code"))
        XCTAssertTrue(reDecoded.isMCPOriginated)
    }

    func testStructuredOriginWinsOverStaleLegacyFlag() throws {
        // A structured origin is the source of truth; the derived legacy flag is
        // re-normalized from it on decode.
        let json = sessionJSON(extraFields: #""origin": {"kind": "user"}, "isMCPOriginated": true"#)
        let session = try decoder.decode(AgentSession.self, from: json)
        XCTAssertEqual(session.origin, .user)
        XCTAssertFalse(session.isMCPOriginated)
    }

    // MARK: - Forward compatibility

    func testUnknownOriginKindDecodesAsMCPSoCleanupNeverWidensToUserSessions() throws {
        let json = sessionJSON(extraFields: #""origin": {"kind": "quantum-entangled"}, "isMCPOriginated": true"#)
        let session = try decoder.decode(AgentSession.self, from: json)
        XCTAssertEqual(session.origin, .mcp(clientID: nil))
        XCTAssertTrue(session.isMCPOriginated)
    }

    func testRemoteOriginWithoutDeviceIDDegradesToMCP() throws {
        let json = sessionJSON(extraFields: #""origin": {"kind": "remote"}"#)
        let session = try decoder.decode(AgentSession.self, from: json)
        XCTAssertEqual(session.origin, .mcp(clientID: nil))
    }

    // MARK: - Derivation mapping (cleanup invariant)

    func testCleanupDerivationMapping() {
        XCTAssertFalse(AgentSessionOrigin.user.isMCPOriginated)
        XCTAssertTrue(AgentSessionOrigin.mcp(clientID: nil).isMCPOriginated)
        XCTAssertTrue(AgentSessionOrigin.mcp(clientID: "claude-code").isMCPOriginated)
        XCTAssertTrue(AgentSessionOrigin.remote(deviceID: "aaaa1111").isMCPOriginated)

        XCTAssertEqual(AgentSessionOrigin(legacyIsMCPOriginated: true), .mcp(clientID: nil))
        XCTAssertEqual(AgentSessionOrigin(legacyIsMCPOriginated: false), .user)
    }

    func testFromClientIdentityClassifiesRemoteAndMCPClients() {
        XCTAssertEqual(
            AgentSessionOrigin.fromClientIdentity("remote:aaaa1111"),
            .remote(deviceID: "aaaa1111")
        )
        XCTAssertEqual(
            AgentSessionOrigin.fromClientIdentity("Claude Code"),
            .mcp(clientID: "claude-code")
        )
        XCTAssertEqual(
            AgentSessionOrigin.fromClientIdentity(nil),
            .mcp(clientID: nil)
        )
    }

    func testMergedPrefersNonUserOriginLikeLegacyStickyFlag() {
        XCTAssertEqual(
            AgentSessionOrigin.merged(.remote(deviceID: "aaaa1111"), .user),
            .remote(deviceID: "aaaa1111")
        )
        XCTAssertEqual(
            AgentSessionOrigin.merged(.user, .mcp(clientID: "claude-code")),
            .mcp(clientID: "claude-code")
        )
        XCTAssertEqual(AgentSessionOrigin.merged(.user, .user), .user)
        XCTAssertEqual(AgentSessionOrigin.merged(nil, .user), .user)
        XCTAssertNil(AgentSessionOrigin.merged(nil, nil))
    }

    func testSummaryStrings() {
        XCTAssertEqual(AgentSessionOrigin.user.summaryString, "user")
        XCTAssertEqual(AgentSessionOrigin.mcp(clientID: nil).summaryString, "mcp")
        XCTAssertEqual(AgentSessionOrigin.mcp(clientID: "repoprompt-cli").summaryString, "mcp:repoprompt-cli")
        XCTAssertEqual(AgentSessionOrigin.remote(deviceID: "aaaa1111").summaryString, "remote:aaaa1111")
    }

    // MARK: - Metadata index compatibility

    func testLegacyMetadataRecordEffectiveOriginFallsBackToLegacyFlag() throws {
        let legacyRecordJSON = Data("""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "filename": "22222222-2222-2222-2222-222222222222.json",
            "name": "Indexed Session",
            "savedAt": "2026-07-01T00:00:00Z",
            "itemCount": 3,
            "isMCPOriginated": true
        }
        """.utf8)
        let record = try decoder.decode(AgentSessionMetadataRecord.self, from: legacyRecordJSON)
        XCTAssertNil(record.origin, "Legacy records stay nil; no mass reindex")
        XCTAssertEqual(record.effectiveOrigin, .mcp(clientID: nil))

        let entry = try XCTUnwrap(record.sidebarEntry(tabID: UUID()))
        XCTAssertEqual(entry.origin, .mcp(clientID: nil), "Sidebar entries normalize via effectiveOrigin")
    }

    func testMetadataRecordWithStructuredOriginExposesIt() throws {
        let recordJSON = Data("""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "filename": "22222222-2222-2222-2222-222222222222.json",
            "name": "Indexed Session",
            "savedAt": "2026-07-01T00:00:00Z",
            "itemCount": 3,
            "isMCPOriginated": true,
            "origin": {"kind": "remote", "deviceID": "bbbb2222"}
        }
        """.utf8)
        let record = try decoder.decode(AgentSessionMetadataRecord.self, from: recordJSON)
        XCTAssertEqual(record.effectiveOrigin, .remote(deviceID: "bbbb2222"))
    }

    func testMetadataStructuredOriginWinsOverStaleLegacyFlagForDerivedReaders() throws {
        let recordJSON = Data("""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "filename": "22222222-2222-2222-2222-222222222222.json",
            "name": "Indexed Session",
            "savedAt": "2026-07-01T00:00:00Z",
            "itemCount": 3,
            "isMCPOriginated": true,
            "origin": {"kind": "user"}
        }
        """.utf8)
        let record = try decoder.decode(AgentSessionMetadataRecord.self, from: recordJSON)
        let entry = try XCTUnwrap(record.sidebarEntry(tabID: UUID()))
        let meta = record.agentSessionMeta()

        XCTAssertEqual(record.effectiveOrigin, .user)
        XCTAssertFalse(entry.isMCPOriginated)
        XCTAssertFalse(meta.isMCPOriginated)
    }
}
