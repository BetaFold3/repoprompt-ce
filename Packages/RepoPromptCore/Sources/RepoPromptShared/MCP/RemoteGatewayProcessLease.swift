import Foundation

/// Small ownership record written by the app-launched `repoprompt-gateway` helper.
///
/// The app uses this to clean up a previous helper after an app crash before
/// launching a replacement on the same bind address/port. It is intentionally
/// not an authorization primitive; it only narrows process cleanup to a gateway
/// instance with matching launch metadata.
public struct RemoteGatewayProcessLease: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let pid: Int32
    public let parentPID: Int32?
    public let executablePath: String?
    public let bindHost: String
    public let port: Int
    public let appSupportRoot: String
    public let createdAt: Date

    public init(
        pid: Int32,
        parentPID: Int32?,
        executablePath: String?,
        bindHost: String,
        port: Int,
        appSupportRoot: String,
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.bindHost = bindHost
        self.port = port
        self.appSupportRoot = URL(fileURLWithPath: appSupportRoot).standardizedFileURL.path
        self.createdAt = createdAt
    }

    public func matches(
        bindHost: String,
        port: Int,
        appSupportRoot: String,
        executablePath: String?
    ) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              self.bindHost == bindHost,
              self.port == port,
              self.appSupportRoot == URL(fileURLWithPath: appSupportRoot).standardizedFileURL.path
        else { return false }
        guard let expected = executablePath?.nilIfEmpty,
              let actual = self.executablePath?.nilIfEmpty
        else { return true }
        return URL(fileURLWithPath: actual).standardizedFileURL.path == URL(fileURLWithPath: expected).standardizedFileURL.path
    }
}

public enum RemoteGatewayProcessLeaseFile {
    public static func defaultURL(appSupportRoot: URL) -> URL {
        appSupportRoot
            .appendingPathComponent("RemoteGateway", isDirectory: true)
            .appendingPathComponent("gateway-process-v1.json")
    }

    public static func read(from fileURL: URL) throws -> RemoteGatewayProcessLease? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let lease = try JSONDecoder().decode(RemoteGatewayProcessLease.self, from: data)
        guard lease.schemaVersion == RemoteGatewayProcessLease.currentSchemaVersion else { return nil }
        return lease
    }

    public static func write(_ lease: RemoteGatewayProcessLease, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lease)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }

    public static func removeIfOwned(fileURL: URL, pid: Int32) {
        guard let lease = try? read(from: fileURL), lease.pid == pid else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
