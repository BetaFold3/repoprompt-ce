import Foundation
@testable import RepoPromptGateway
import XCTest

final class RemoteAuditLogTests: XCTestCase {
    func testAuditLogWritesJSONLineSchema() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = try RemoteAuditLog(directoryURL: root.appendingPathComponent("audit", isDirectory: true), processID: 123)

        await audit.write(RemoteAuditRecord(
            date: Date(timeIntervalSince1970: 0),
            deviceID: "phase0:static-token",
            requestID: "req",
            op: "respond",
            sessionID: "sid",
            outcome: "success",
            code: nil
        ))

        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("audit", isDirectory: true), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let line = try String(contentsOf: files[0], encoding: .utf8)
        let data = try XCTUnwrap(line.split(separator: "\n").first?.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["device_id"] as? String, "phase0:static-token")
        XCTAssertEqual(object?["request_id"] as? String, "req")
        XCTAssertEqual(object?["op"] as? String, "respond")
        XCTAssertEqual(object?["session_id"] as? String, "sid")
        XCTAssertEqual(object?["outcome"] as? String, "success")
    }

    func testAuditLogRetentionPrunesOldFiles() throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDir = root.appendingPathComponent("audit", isDirectory: true)
        try GatewayFileSecurity.ensureSecureDirectory(at: auditDir)
        for index in 0 ..< 3 {
            let file = auditDir.appendingPathComponent("audit-old-\(index).jsonl")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
            try GatewayFileSecurity.setMode(0o600, path: file.path)
        }

        _ = try RemoteAuditLog(directoryURL: auditDir, processID: 123, maxRetainedFiles: 2)

        let files = try FileManager.default.contentsOfDirectory(at: auditDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("audit-") && $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(files.count, 2)
    }

    func testBestEffortRecordDoesNotThrow() throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = try RemoteAuditLog(directoryURL: root.appendingPathComponent("audit", isDirectory: true), processID: 123)
        audit.recordBestEffort(RemoteAuditRecord(
            deviceID: "device",
            requestID: nil,
            op: "poll",
            sessionID: nil,
            outcome: "success"
        ))
    }
}
