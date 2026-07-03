import Darwin
import Foundation

enum GatewayPersistenceError: Error, Equatable, CustomStringConvertible {
    case pathIsNotRegularFile(String)
    case pathIsSymlink(String)
    case ownerMismatch(String)
    case insecurePermissions(path: String, mode: Int, expected: Int)
    case cannotCreateDirectory(String)
    case cannotCreateFile(String)
    case loadFailed(String)
    case appendFailed(String)

    var description: String {
        switch self {
        case let .pathIsNotRegularFile(path):
            "Gateway persistence path is not a regular file: \(path)"
        case let .pathIsSymlink(path):
            "Gateway persistence path must not be a symlink: \(path)"
        case let .ownerMismatch(path):
            "Gateway persistence path is not owned by the current user: \(path)"
        case let .insecurePermissions(path, mode, expected):
            "Gateway persistence path has insecure mode \(String(mode, radix: 8)); expected \(String(expected, radix: 8)): \(path)"
        case let .cannotCreateDirectory(path):
            "Could not create gateway persistence directory: \(path)"
        case let .cannotCreateFile(path):
            "Could not create gateway persistence file: \(path)"
        case let .loadFailed(message):
            "Could not load gateway persistence file: \(message)"
        case let .appendFailed(message):
            "Could not append to gateway persistence file: \(message)"
        }
    }
}

enum GatewayFileSecurity {
    static func ensureSecureDirectory(at url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                try setMode(0o700, path: url.path)
            } catch {
                throw GatewayPersistenceError.cannotCreateDirectory(url.path)
            }
        }
        guard isDirectory.boolValue || isDirectory.boolValue == false && isDirectoryAtPath(url.path) else {
            throw GatewayPersistenceError.cannotCreateDirectory(url.path)
        }
        try validateOwnerAndPermissions(path: url.path, expectedMode: 0o700, requireRegularFile: false)
    }

    static func ensureSecureFile(at url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        try ensureSecureDirectory(at: directory, fileManager: fileManager)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: Data()) else {
                throw GatewayPersistenceError.cannotCreateFile(url.path)
            }
            try setMode(0o600, path: url.path)
        }
        try validateOwnerAndPermissions(path: url.path, expectedMode: 0o600, requireRegularFile: true)
    }

    static func validateExistingSecureFile(at url: URL) throws {
        try validateOwnerAndPermissions(path: url.path, expectedMode: 0o600, requireRegularFile: true)
    }

    static func setMode(_ mode: mode_t, path: String) throws {
        guard chmod(path, mode) == 0 else {
            throw GatewayPersistenceError.insecurePermissions(path: path, mode: -1, expected: Int(mode))
        }
    }

    private static func validateOwnerAndPermissions(
        path: String,
        expectedMode: Int,
        requireRegularFile: Bool
    ) throws {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else {
            throw GatewayPersistenceError.cannotCreateFile(path)
        }
        if (statBuffer.st_mode & S_IFMT) == S_IFLNK {
            throw GatewayPersistenceError.pathIsSymlink(path)
        }
        if requireRegularFile, (statBuffer.st_mode & S_IFMT) != S_IFREG {
            throw GatewayPersistenceError.pathIsNotRegularFile(path)
        }
        if !requireRegularFile, (statBuffer.st_mode & S_IFMT) != S_IFDIR {
            throw GatewayPersistenceError.cannotCreateDirectory(path)
        }
        guard statBuffer.st_uid == getuid() else {
            throw GatewayPersistenceError.ownerMismatch(path)
        }
        let mode = Int(statBuffer.st_mode & 0o777)
        guard mode == expectedMode else {
            throw GatewayPersistenceError.insecurePermissions(path: path, mode: mode, expected: expectedMode)
        }
    }

    private static func isDirectoryAtPath(_ path: String) -> Bool {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return false }
        return (statBuffer.st_mode & S_IFMT) == S_IFDIR
    }
}

final class CommandLedgerStore: @unchecked Sendable {
    struct Snapshot: Equatable {
        let key: CommandLedger.Key
        let fingerprint: CommandLedger.CommandFingerprint
        let outcome: CommandLedger.RecordedOutcome?
        let beganAt: Date
        let completedAt: Date?
    }

    private struct Event: Codable {
        enum Kind: String, Codable {
            case begin
            case complete
        }

        let kind: Kind
        let deviceID: String
        let requestID: String
        let operation: String
        let canonicalPayloadSHA256: String
        let outcome: CommandLedger.RecordedOutcome?
        let ts: Date
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try GatewayFileSecurity.ensureSecureFile(at: fileURL, fileManager: fileManager)
    }

    func load() throws -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        var snapshots: [CommandLedger.Key: Snapshot] = [:]
        for (index, line) in lines.enumerated() {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            let event: Event
            do {
                event = try decoder.decode(Event.self, from: lineData)
            } catch {
                logCorruptLedgerLine(lineNumber: index + 1, line: String(line), error: error)
                continue
            }
            let key = CommandLedger.Key(deviceID: event.deviceID, requestID: event.requestID)
            let fingerprint = CommandLedger.CommandFingerprint(
                operation: event.operation,
                canonicalPayloadSHA256: event.canonicalPayloadSHA256
            )
            switch event.kind {
            case .begin:
                snapshots[key] = Snapshot(
                    key: key,
                    fingerprint: fingerprint,
                    outcome: nil,
                    beganAt: event.ts,
                    completedAt: nil
                )
            case .complete:
                let beganAt = snapshots[key]?.beganAt ?? event.ts
                snapshots[key] = Snapshot(
                    key: key,
                    fingerprint: fingerprint,
                    outcome: event.outcome,
                    beganAt: beganAt,
                    completedAt: event.ts
                )
            }
        }
        return Array(snapshots.values)
    }

    func appendBegin(
        key: CommandLedger.Key,
        fingerprint: CommandLedger.CommandFingerprint,
        at date: Date
    ) throws {
        try append(Event(
            kind: .begin,
            deviceID: key.deviceID,
            requestID: key.requestID,
            operation: fingerprint.operation,
            canonicalPayloadSHA256: fingerprint.canonicalPayloadSHA256,
            outcome: nil,
            ts: date
        ))
    }

    func appendComplete(
        key: CommandLedger.Key,
        fingerprint: CommandLedger.CommandFingerprint,
        outcome: CommandLedger.RecordedOutcome,
        at date: Date
    ) throws {
        try append(Event(
            kind: .complete,
            deviceID: key.deviceID,
            requestID: key.requestID,
            operation: fingerprint.operation,
            canonicalPayloadSHA256: fingerprint.canonicalPayloadSHA256,
            outcome: outcome,
            ts: date
        ))
    }

    func replace(with snapshots: [Snapshot]) throws {
        lock.lock()
        defer { lock.unlock() }
        var data = Data()
        for snapshot in snapshots.sorted(by: { lhs, rhs in
            if lhs.key.deviceID == rhs.key.deviceID { return lhs.key.requestID < rhs.key.requestID }
            return lhs.key.deviceID < rhs.key.deviceID
        }) {
            let begin = Event(
                kind: .begin,
                deviceID: snapshot.key.deviceID,
                requestID: snapshot.key.requestID,
                operation: snapshot.fingerprint.operation,
                canonicalPayloadSHA256: snapshot.fingerprint.canonicalPayloadSHA256,
                outcome: nil,
                ts: snapshot.beganAt
            )
            try data.append(encoder.encode(begin))
            data.append(UInt8(ascii: "\n"))
            if let outcome = snapshot.outcome {
                let complete = Event(
                    kind: .complete,
                    deviceID: snapshot.key.deviceID,
                    requestID: snapshot.key.requestID,
                    operation: snapshot.fingerprint.operation,
                    canonicalPayloadSHA256: snapshot.fingerprint.canonicalPayloadSHA256,
                    outcome: outcome,
                    ts: snapshot.completedAt ?? snapshot.beganAt
                )
                try data.append(encoder.encode(complete))
                data.append(UInt8(ascii: "\n"))
            }
        }
        try data.write(to: fileURL, options: [.atomic])
        try GatewayFileSecurity.setMode(0o600, path: fileURL.path)
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
    }

    private func logCorruptLedgerLine(lineNumber: Int, line: String, error: Error) {
        let message = "Skipping corrupt command-ledger row \(lineNumber) in \(fileURL.path): \(String(describing: error))\n"
        fputs(message, stderr)
        do {
            let quarantineURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt.jsonl")
            try GatewayFileSecurity.ensureSecureFile(at: quarantineURL)
            let data = Data((line + "\n").utf8)
            let handle = try FileHandle(forWritingTo: quarantineURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("Could not quarantine corrupt command-ledger row: \(String(describing: error))\n", stderr)
        }
    }

    private func append(_ event: Event) throws {
        let data = try encoder.encode(event) + Data([UInt8(ascii: "\n")])
        lock.lock()
        defer { lock.unlock() }
        try GatewayFileSecurity.validateExistingSecureFile(at: fileURL)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
