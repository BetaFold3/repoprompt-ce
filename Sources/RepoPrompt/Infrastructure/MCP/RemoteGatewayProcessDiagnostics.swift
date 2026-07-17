import Foundation

final class RemoteGatewayProcessDiagnosticsCapture: @unchecked Sendable {
    struct Limits: Sendable {
        let retainedFileCount: Int
        let maximumFileBytes: Int
        let maximumLineBytes: Int

        init(
            retainedFileCount: Int = 6,
            maximumFileBytes: Int = 512 * 1024,
            maximumLineBytes: Int = 64 * 1024
        ) {
            self.retainedFileCount = max(1, retainedFileCount)
            self.maximumFileBytes = max(64, maximumFileBytes)
            self.maximumLineBytes = max(64, maximumLineBytes)
        }
    }

    typealias ReadData = @Sendable (FileHandle) -> Data
    typealias WriteData = @Sendable (FileHandle, Data) throws -> Void

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    private let stdoutSink: StreamSink
    private let stderrSink: StreamSink
    private let readerQueue: DispatchQueue
    private let readData: ReadData
    private let finishLock = NSLock()
    private var finished = false

    init?(
        runtimeRootURL: URL,
        generation: UUID,
        limits: Limits = Limits(),
        fileManager: FileManager = .default,
        readData: @escaping ReadData = { $0.availableData },
        writeData: @escaping WriteData = { try $0.write(contentsOf: $1) }
    ) {
        let directoryURL = runtimeRootURL.appendingPathComponent("diagnostics", isDirectory: true)
        let coordinator: DiagnosticsFileCoordinator
        do {
            coordinator = try DiagnosticsFileCoordinator.shared(
                directoryURL: directoryURL,
                retainedFileCount: limits.retainedFileCount,
                fileManager: fileManager
            )
        } catch {
            return nil
        }

        let prefix = "gateway-\(generation.uuidString.lowercased())"
        stdoutSink = StreamSink(
            filePrefix: "\(prefix)-stdout",
            limits: limits,
            coordinator: coordinator,
            writeData: writeData
        )
        stderrSink = StreamSink(
            filePrefix: "\(prefix)-stderr",
            limits: limits,
            coordinator: coordinator,
            writeData: writeData
        )
        readerQueue = DispatchQueue(label: "com.repoprompt.gateway-diagnostics.reader.\(generation.uuidString)")
        self.readData = readData

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, stdoutSink] handle in
            self?.consumeAvailableData(from: handle, into: stdoutSink)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, stderrSink] handle in
            self?.consumeAvailableData(from: handle, into: stderrSink)
        }
    }

    func finish() {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        readerQueue.sync {
            drain(stdoutPipe.fileHandleForReading, into: stdoutSink)
            drain(stderrPipe.fileHandleForReading, into: stderrSink)
            stdoutSink.finish()
            stderrSink.finish()
        }
    }

    private func consumeAvailableData(from handle: FileHandle, into sink: StreamSink) {
        readerQueue.sync {
            finishLock.lock()
            let shouldRead = !finished
            finishLock.unlock()
            guard shouldRead else { return }
            let data = readData(handle)
            if !data.isEmpty {
                sink.consume(data)
            }
        }
    }

    private func drain(_ handle: FileHandle, into sink: StreamSink) {
        while true {
            let data = readData(handle)
            guard !data.isEmpty else { return }
            sink.consume(data)
        }
    }
}

private final class WeakDiagnosticsFileCoordinator {
    weak var value: DiagnosticsFileCoordinator?

    init(_ value: DiagnosticsFileCoordinator) {
        self.value = value
    }
}

private final class DiagnosticsFileCoordinator: @unchecked Sendable {
    private struct ActiveSegment {
        let url: URL
        let handle: FileHandle
    }

    enum WriteResult {
        case written
        case evicted
        case failed
    }

    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: WeakDiagnosticsFileCoordinator] = [:]

    private let directoryURL: URL
    private let retainedFileCount: Int
    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeSegments: [UUID: ActiveSegment] = [:]

    static func shared(
        directoryURL: URL,
        retainedFileCount: Int,
        fileManager: FileManager
    ) throws -> DiagnosticsFileCoordinator {
        let key = directoryURL.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let coordinator = registry[key]?.value {
            return coordinator
        }
        let coordinator = try DiagnosticsFileCoordinator(
            directoryURL: directoryURL,
            retainedFileCount: retainedFileCount,
            fileManager: fileManager
        )
        registry[key] = WeakDiagnosticsFileCoordinator(coordinator)
        return coordinator
    }

    private init(
        directoryURL: URL,
        retainedFileCount: Int,
        fileManager: FileManager
    ) throws {
        self.directoryURL = directoryURL
        self.retainedFileCount = max(1, retainedFileCount)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try enforceRetention(preserving: nil)
    }

    func openSegment(fileName: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = directoryURL.appendingPathComponent(fileName)
        guard fileManager.createFile(atPath: fileURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: fileURL)
        else {
            return nil
        }
        let segmentID = UUID()
        activeSegments[segmentID] = ActiveSegment(url: fileURL, handle: handle)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        do {
            try enforceRetention(preserving: fileURL)
            guard activeSegments[segmentID] != nil else { return nil }
            return segmentID
        } catch {
            closeSegmentLocked(segmentID)
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    func write(
        _ data: Data,
        to segmentID: UUID,
        using writeData: RemoteGatewayProcessDiagnosticsCapture.WriteData
    ) -> WriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard let segment = activeSegments[segmentID] else {
            return .evicted
        }
        do {
            try writeData(segment.handle, data)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: segment.url.path)
            return .written
        } catch {
            closeSegmentLocked(segmentID)
            return .failed
        }
    }

    func closeSegment(_ segmentID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        closeSegmentLocked(segmentID)
    }

    private func closeSegmentLocked(_ segmentID: UUID) {
        guard let segment = activeSegments.removeValue(forKey: segmentID) else { return }
        try? segment.handle.close()
    }

    private func enforceRetention(preserving newestFile: URL?) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("gateway-") && $0.pathExtension == "log" }
        .sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            if lhs == rhs {
                return $0.lastPathComponent < $1.lastPathComponent
            }
            return (lhs ?? .distantPast) < (rhs ?? .distantPast)
        }

        while files.count > retainedFileCount {
            let removalIndex = files.firstIndex { $0 != newestFile } ?? 0
            let file = files.remove(at: removalIndex)
            let removalPath = file.standardizedFileURL.path
            let activeIDs = activeSegments.compactMap { id, segment in
                segment.url.standardizedFileURL.path == removalPath ? id : nil
            }
            for activeID in activeIDs {
                closeSegmentLocked(activeID)
            }
            try fileManager.removeItem(at: file)
        }
    }
}

private final class StreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private let filePrefix: String
    private let limits: RemoteGatewayProcessDiagnosticsCapture.Limits
    private let coordinator: DiagnosticsFileCoordinator
    private let writeData: RemoteGatewayProcessDiagnosticsCapture.WriteData
    private var pending = Data()
    private var segmentIndex = 0
    private var segmentID: UUID?
    private var bytesWritten = 0
    private var closed = false

    init(
        filePrefix: String,
        limits: RemoteGatewayProcessDiagnosticsCapture.Limits,
        coordinator: DiagnosticsFileCoordinator,
        writeData: @escaping RemoteGatewayProcessDiagnosticsCapture.WriteData
    ) {
        self.filePrefix = filePrefix
        self.limits = limits
        self.coordinator = coordinator
        self.writeData = writeData
    }

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        pending.append(data)
        flushCompleteLines()
        if pending.count > limits.maximumLineBytes {
            pending.removeAll(keepingCapacity: true)
            persist("[redacted oversized diagnostic line]\n")
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if !pending.isEmpty {
            persist(Self.redactedLine(from: pending))
            pending.removeAll()
        }
        closed = true
        closeCurrentSegment()
    }

    private func flushCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(through: newline)
            pending.removeSubrange(...newline)
            persist(Self.redactedLine(from: Data(line)))
        }
    }

    private func persist(_ string: String) {
        guard var data = string.data(using: .utf8), !data.isEmpty else { return }
        if data.count > limits.maximumFileBytes {
            data = Data(data.suffix(limits.maximumFileBytes))
        }
        if bytesWritten > 0, bytesWritten + data.count > limits.maximumFileBytes {
            closeCurrentSegment()
        }
        guard openSegmentIfNeeded(), let currentSegmentID = segmentID else {
            closed = true
            return
        }
        switch coordinator.write(data, to: currentSegmentID, using: writeData) {
        case .written:
            bytesWritten += data.count
        case .evicted:
            segmentID = nil
            bytesWritten = 0
            guard openSegmentIfNeeded(), let replacementSegmentID = segmentID else {
                closed = true
                return
            }
            switch coordinator.write(data, to: replacementSegmentID, using: writeData) {
            case .written:
                bytesWritten = data.count
            case .evicted, .failed:
                closeCurrentSegment()
                closed = true
            }
        case .failed:
            segmentID = nil
            bytesWritten = 0
            closed = true
        }
    }

    private func openSegmentIfNeeded() -> Bool {
        guard segmentID == nil else { return true }
        segmentIndex += 1
        let fileName = String(format: "%@-%04d.log", filePrefix, segmentIndex)
        guard let newSegmentID = coordinator.openSegment(fileName: fileName) else {
            return false
        }
        segmentID = newSegmentID
        bytesWritten = 0
        return true
    }

    private func closeCurrentSegment() {
        if let segmentID {
            coordinator.closeSegment(segmentID)
        }
        segmentID = nil
        bytesWritten = 0
    }

    private static func redactedLine(from data: Data) -> String {
        let line = String(decoding: data, as: UTF8.self)
        let lowered = line.lowercased()
        let sensitiveMarkers = [
            "api_key",
            "apikey",
            "authorization",
            "bearer",
            "credential",
            "password",
            "secret",
            "token",
            "auth",
            "payload",
            "message",
            "prompt",
            "path"
        ]
        if sensitiveMarkers.contains(where: lowered.contains) || line.contains("/") || line.contains("\\") {
            return "[redacted diagnostic line]\n"
        }
        return String(line.prefix(4096)).trimmingCharacters(in: .newlines) + "\n"
    }
}
