import Foundation

struct RemoteAuditRecord: Codable, Equatable {
    let ts: String
    let deviceID: String
    let requestID: String?
    let op: String
    let sessionID: String?
    let outcome: String
    let code: String?
    let offset: Int?
    let limit: Int?
    let returnedTurnCount: Int?
    let completedTurnCount: Int?
    let transcriptXMLChars: Int?
    let autoRoutedWindowID: Int?
    let windowID: Int?
    let hasWorkspaceName: Bool?
    let hasWorkspaceID: Bool?
    let workspaceMatchCount: Int?
    let workspaceMatchSkipped: String?
    let workspaceMatchUnavailableReason: String?
    let bindingStateInitial: String?
    let bindingStateRetry: String?
    let fallbackInitial: String?
    let fallbackRetry: String?
    let windowIDInjectedInitial: Bool?
    let windowIDInjectedRetry: Bool?
    let errorOriginInitial: String?
    let errorOriginRetry: String?
    let recoveryRetried: Bool?

    init(
        date: Date = Date(),
        deviceID: String,
        requestID: String?,
        op: String,
        sessionID: String?,
        outcome: String,
        code: String? = nil,
        offset: Int? = nil,
        limit: Int? = nil,
        returnedTurnCount: Int? = nil,
        completedTurnCount: Int? = nil,
        transcriptXMLChars: Int? = nil,
        autoRoutedWindowID: Int? = nil,
        windowID: Int? = nil,
        hasWorkspaceName: Bool? = nil,
        hasWorkspaceID: Bool? = nil,
        workspaceMatchCount: Int? = nil,
        workspaceMatchSkipped: String? = nil,
        workspaceMatchUnavailableReason: String? = nil,
        bindingStateInitial: String? = nil,
        bindingStateRetry: String? = nil,
        fallbackInitial: String? = nil,
        fallbackRetry: String? = nil,
        windowIDInjectedInitial: Bool? = nil,
        windowIDInjectedRetry: Bool? = nil,
        errorOriginInitial: String? = nil,
        errorOriginRetry: String? = nil,
        recoveryRetried: Bool? = nil
    ) {
        ts = RemoteAuditLog.timestampFormatter.string(from: date)
        self.deviceID = deviceID
        self.requestID = requestID
        self.op = op
        self.sessionID = sessionID
        self.outcome = outcome
        self.code = code
        self.offset = offset
        self.limit = limit
        self.returnedTurnCount = returnedTurnCount
        self.completedTurnCount = completedTurnCount
        self.transcriptXMLChars = transcriptXMLChars
        self.autoRoutedWindowID = autoRoutedWindowID
        self.windowID = windowID
        self.hasWorkspaceName = hasWorkspaceName
        self.hasWorkspaceID = hasWorkspaceID
        self.workspaceMatchCount = workspaceMatchCount
        self.workspaceMatchSkipped = workspaceMatchSkipped
        self.workspaceMatchUnavailableReason = workspaceMatchUnavailableReason
        self.bindingStateInitial = bindingStateInitial
        self.bindingStateRetry = bindingStateRetry
        self.fallbackInitial = fallbackInitial
        self.fallbackRetry = fallbackRetry
        self.windowIDInjectedInitial = windowIDInjectedInitial
        self.windowIDInjectedRetry = windowIDInjectedRetry
        self.errorOriginInitial = errorOriginInitial
        self.errorOriginRetry = errorOriginRetry
        self.recoveryRetried = recoveryRetried
    }

    private enum CodingKeys: String, CodingKey {
        case ts
        case deviceID = "device_id"
        case requestID = "request_id"
        case op
        case sessionID = "session_id"
        case outcome
        case code
        case offset
        case limit
        case returnedTurnCount = "returned_turn_count"
        case completedTurnCount = "completed_turn_count"
        case transcriptXMLChars = "transcript_xml_chars"
        case autoRoutedWindowID = "auto_routed_window_id"
        case windowID = "window_id"
        case hasWorkspaceName = "has_workspace_name"
        case hasWorkspaceID = "has_workspace_id"
        case workspaceMatchCount = "workspace_match_count"
        case workspaceMatchSkipped = "workspace_match_skipped"
        case workspaceMatchUnavailableReason = "workspace_match_unavailable_reason"
        case bindingStateInitial = "binding_state_initial"
        case bindingStateRetry = "binding_state_retry"
        case fallbackInitial = "fallback_initial"
        case fallbackRetry = "fallback_retry"
        case windowIDInjectedInitial = "window_id_injected_initial"
        case windowIDInjectedRetry = "window_id_injected_retry"
        case errorOriginInitial = "error_origin_initial"
        case errorOriginRetry = "error_origin_retry"
        case recoveryRetried = "recovery_retried"
    }
}

actor RemoteAuditLog {
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let directoryURL: URL
    private let fileURL: URL
    private let maxRetainedFiles: Int
    private let encoder: JSONEncoder
    private let fileHandle: FileHandle

    init(
        directoryURL: URL,
        processID: Int32 = getpid(),
        launchDate: Date = Date(),
        maxRetainedFiles: Int = 20,
        fileManager: FileManager = .default
    ) throws {
        self.directoryURL = directoryURL
        self.maxRetainedFiles = max(1, maxRetainedFiles)
        try GatewayFileSecurity.ensureSecureDirectory(at: directoryURL, fileManager: fileManager)
        let launch = Self.timestampFormatter.string(from: launchDate)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        fileURL = directoryURL.appendingPathComponent("audit-\(launch)-\(processID).jsonl")
        try GatewayFileSecurity.ensureSecureFile(at: fileURL, fileManager: fileManager)
        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.pruneAuditFiles(in: directoryURL, keeping: self.maxRetainedFiles, fileManager: fileManager)
    }

    deinit {
        try? fileHandle.close()
    }

    nonisolated func recordBestEffort(_ record: RemoteAuditRecord) {
        Task { [weak self] in
            await self?.write(record)
        }
    }

    func write(_ record: RemoteAuditRecord) {
        do {
            let line = try encoder.encode(record) + Data([UInt8(ascii: "\n")])
            try fileHandle.write(contentsOf: line)
        } catch {
            // Audit writes are intentionally best-effort after startup. Command
            // execution must not block or fail because an individual append failed.
        }
    }

    private static func pruneAuditFiles(
        in directoryURL: URL,
        keeping maxFiles: Int,
        fileManager: FileManager
    ) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let auditFiles = contents.filter { $0.lastPathComponent.hasPrefix("audit-") && $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        for stale in auditFiles.dropFirst(maxFiles) {
            try? fileManager.removeItem(at: stale)
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
