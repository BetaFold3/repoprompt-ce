import Foundation
@testable import RepoPromptApp
import XCTest

final class RemoteGatewayProcessDiagnosticsTests: XCTestCase {
    func testStdoutAndStderrPersistAcrossExitAndRestartUnderRuntimeRoot() throws {
        let root = try temporaryDirectory()
        let first = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID()
        ))
        try write("first stdout\n", to: first.stdoutPipe)
        try write("first stderr\n", to: first.stderrPipe)
        first.finish()

        let second = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID()
        ))
        try write("second stdout\n", to: second.stdoutPipe)
        try write("second stderr\n", to: second.stderrPipe)
        second.finish()

        let files = try diagnosticFiles(in: root)
        XCTAssertEqual(files.count, 4)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(persisted.contains("first stdout"))
        XCTAssertTrue(persisted.contains("first stderr"))
        XCTAssertTrue(persisted.contains("second stdout"))
        XCTAssertTrue(persisted.contains("second stderr"))
    }

    func testDiagnosticsRedactSensitiveFixturesBeforePersistenceAndEnforceFiniteRetention() throws {
        let root = try temporaryDirectory()
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 4,
            maximumFileBytes: 4096,
            maximumLineBytes: 1024
        )
        let secrets = [
            "token=secret-token-value",
            "credential=secret-credential",
            "prompt=private user content",
            "payload=private payload",
            "message=private message",
            "path=/Users/example/private.txt"
        ]
        for _ in 0 ..< 3 {
            let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
                runtimeRootURL: root,
                generation: UUID(),
                limits: limits
            ))
            try write(secrets.joined(separator: "\n") + "\n", to: capture.stdoutPipe)
            try write("safe operational category\n", to: capture.stderrPipe)
            capture.finish()
        }

        let files = try diagnosticFiles(in: root)
        XCTAssertLessThanOrEqual(files.count, limits.retainedFileCount)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, limits.maximumFileBytes)
            let persisted = String(decoding: data, as: UTF8.self)
            for secret in secrets {
                XCTAssertFalse(persisted.contains(secret))
            }
            XCTAssertFalse(persisted.contains("secret-token-value"))
            XCTAssertFalse(persisted.contains("/Users/example/private.txt"))
        }
    }

    func testLargeConcurrentOutputDrainsWithoutBlockingTermination() async throws {
        let root = try temporaryDirectory()
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 2,
            maximumFileBytes: 64 * 1024,
            maximumLineBytes: 2048
        )
        let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits
        ))
        let stdout = capture.stdoutPipe.fileHandleForWriting
        let stderr = capture.stderrPipe.fileHandleForWriting
        let line = Data((String(repeating: "x", count: 512) + "\n").utf8)

        async let stdoutWrite: Void = writeRepeated(line, count: 2000, to: stdout)
        async let stderrWrite: Void = writeRepeated(line, count: 2000, to: stderr)
        _ = try await (stdoutWrite, stderrWrite)
        try stdout.close()
        try stderr.close()
        capture.finish()

        let files = try diagnosticFiles(in: root)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(try files.allSatisfy { try Data(contentsOf: $0).count <= limits.maximumFileBytes })
    }

    func testDiagnosticWriteAndRotationFailureRemainNonfatal() throws {
        let root = try temporaryDirectory()
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)

        let capture = RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: blockingFile,
            generation: UUID()
        )

        XCTAssertNil(capture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockingFile.path))
    }

    func testInGenerationRotationPreservesTailAndEnforcesExactSmallRetentionLimits() throws {
        for retainedFileCount in [1, 2, 4] {
            let root = try temporaryDirectory()
            let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
                retainedFileCount: retainedFileCount,
                maximumFileBytes: 64,
                maximumLineBytes: 64
            )
            let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
                runtimeRootURL: root,
                generation: UUID(),
                limits: limits
            ))
            let lines = (0 ..< 12).map {
                "rotation-marker-\(String(format: "%02d", $0))-xxxxxxxxxxxxxxxx\n"
            }
            try write(lines.joined(), to: capture.stdoutPipe)
            try capture.stderrPipe.fileHandleForWriting.close()
            capture.finish()

            let files = try diagnosticFiles(in: root)
            XCTAssertEqual(files.count, retainedFileCount)
            let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            XCTAssertTrue(persisted.contains("rotation-marker-11"))
            XCTAssertFalse(persisted.contains("rotation-marker-00"))
            XCTAssertTrue(try files.allSatisfy { try Data(contentsOf: $0).count <= limits.maximumFileBytes })
        }
    }

    func testDiagnosticsRedactCommonCredentialSpellingsBeforeRollingPersistence() throws {
        let root = try temporaryDirectory()
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 4,
            maximumFileBytes: 64,
            maximumLineBytes: 128
        )
        let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits
        ))
        let sensitiveLines = [
            "api_key=alpha-secret",
            "APIKEY=beta-secret",
            "Bearer gamma-secret",
            "authorization: delta-secret",
            "auth=epsilon-secret"
        ]
        try write((sensitiveLines + sensitiveLines).joined(separator: "\n") + "\n", to: capture.stdoutPipe)
        try capture.stderrPipe.fileHandleForWriting.close()
        capture.finish()

        let files = try diagnosticFiles(in: root)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for line in sensitiveLines {
            XCTAssertFalse(persisted.localizedCaseInsensitiveContains(line))
        }
        for secret in ["alpha-secret", "beta-secret", "gamma-secret", "delta-secret", "epsilon-secret"] {
            XCTAssertFalse(persisted.contains(secret))
        }
        XCTAssertTrue(persisted.contains("[redacted diagnostic line]"))
    }

    func testFinishQuiescesSerializedReaderBeforeDrainWithoutConcurrentFDReads() async throws {
        let root = try temporaryDirectory()
        let probe = SerializedReadProbe()
        let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            readData: { probe.read(from: $0) }
        ))
        try capture.stdoutPipe.fileHandleForWriting.write(contentsOf: Data("api_key=serialized-secret\n".utf8))
        try capture.stdoutPipe.fileHandleForWriting.close()
        try capture.stderrPipe.fileHandleForWriting.close()
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 2), .success)

        let finish = Task.detached {
            capture.finish()
        }
        probe.release.signal()
        await finish.value

        XCTAssertEqual(probe.maximumConcurrentReads, 1)
        let files = try diagnosticFiles(in: root)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(persisted.contains("[redacted diagnostic line]"))
        XCTAssertFalse(persisted.contains("api_key"))
        XCTAssertFalse(persisted.contains("serialized-secret"))
    }

    func testMidStreamWriteAndRotationFailureRemainNonfatal() throws {
        let root = try temporaryDirectory()
        let writer = FailingDiagnosticsWriter(failingWriteNumber: 2)
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 2,
            maximumFileBytes: 64,
            maximumLineBytes: 64
        )
        let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits,
            writeData: { try writer.write($1, to: $0) }
        ))
        try write(
            "first-safe-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" +
                "second-safe-marker-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n",
            to: capture.stdoutPipe
        )
        try capture.stderrPipe.fileHandleForWriting.close()

        capture.finish()

        XCTAssertEqual(writer.writeCount, 2)
        let files = try diagnosticFiles(in: root)
        XCTAssertLessThanOrEqual(files.count, limits.retainedFileCount)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(persisted.contains("first-safe-marker"))
        XCTAssertFalse(persisted.contains("second-safe-marker"))
    }

    func testAlternatingStdoutStderrRotationPreservesLateMarkersFromBothStreams() throws {
        let root = try temporaryDirectory()
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 2,
            maximumFileBytes: 64,
            maximumLineBytes: 64
        )
        let observer = DiagnosticsWriteObserver()
        let capture = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits,
            writeData: { handle, data in
                try handle.write(contentsOf: data)
                observer.record(data)
            }
        ))
        let stdout = capture.stdoutPipe.fileHandleForWriting
        let stderr = capture.stderrPipe.fileHandleForWriting

        try writeChunk("stdout-early-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", to: stdout)
        try observer.waitForMarker("stdout-early")
        try writeChunk("stderr-early-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n", to: stderr)
        try observer.waitForMarker("stderr-early")
        try writeChunk("stdout-late-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", to: stdout)
        try observer.waitForMarker("stdout-late")
        try writeChunk("stderr-late-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n", to: stderr)
        try observer.waitForMarker("stderr-late")

        try stdout.close()
        try stderr.close()
        capture.finish()

        let files = try diagnosticFiles(in: root)
        XCTAssertEqual(files.count, limits.retainedFileCount)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(persisted.contains("stdout-late"))
        XCTAssertTrue(persisted.contains("stderr-late"))
        XCTAssertFalse(persisted.contains("stdout-early"))
        XCTAssertFalse(persisted.contains("stderr-early"))
    }

    func testOverlappingGenerationsRetentionCannotUnlinkActiveSegmentsOrLoseTails() throws {
        let root = try temporaryDirectory()
        let limits = RemoteGatewayProcessDiagnosticsCapture.Limits(
            retainedFileCount: 2,
            maximumFileBytes: 64,
            maximumLineBytes: 64
        )
        let observer = DiagnosticsWriteObserver()
        let first = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits,
            writeData: { handle, data in
                try handle.write(contentsOf: data)
                observer.record(data)
            }
        ))
        let second = try XCTUnwrap(RemoteGatewayProcessDiagnosticsCapture(
            runtimeRootURL: root,
            generation: UUID(),
            limits: limits,
            writeData: { handle, data in
                try handle.write(contentsOf: data)
                observer.record(data)
            }
        ))
        let firstStdout = first.stdoutPipe.fileHandleForWriting
        let firstStderr = first.stderrPipe.fileHandleForWriting
        let secondStdout = second.stdoutPipe.fileHandleForWriting

        try writeChunk("first-stdout-early-xxxxxxxxxxxxxxxx\n", to: firstStdout)
        try observer.waitForMarker("first-stdout-early")
        try writeChunk("first-stderr-early-yyyyyyyyyyyyyyyy\n", to: firstStderr)
        try observer.waitForMarker("first-stderr-early")
        try writeChunk("second-stdout-early-zzzzzzzzzzzzzz\n", to: secondStdout)
        try observer.waitForMarker("second-stdout-early")
        try writeChunk("first-generation-tail\n", to: firstStdout)
        try observer.waitForMarker("first-generation-tail")
        try writeChunk("second-generation-tail\n", to: secondStdout)
        try observer.waitForMarker("second-generation-tail")

        try firstStdout.close()
        try firstStderr.close()
        try secondStdout.close()
        try second.stderrPipe.fileHandleForWriting.close()
        first.finish()
        second.finish()

        let files = try diagnosticFiles(in: root)
        XCTAssertEqual(files.count, limits.retainedFileCount)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(persisted.contains("first-generation-tail"))
        XCTAssertTrue(persisted.contains("second-generation-tail"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteGatewayProcessDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func diagnosticFiles(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "log" }
    }

    private func writeChunk(_ string: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(string.utf8))
    }

    private func write(_ string: String, to pipe: Pipe) throws {
        try pipe.fileHandleForWriting.write(contentsOf: Data(string.utf8))
        try pipe.fileHandleForWriting.close()
    }

    private func writeRepeated(_ data: Data, count: Int, to handle: FileHandle) async throws {
        try await Task.detached {
            for _ in 0 ..< count {
                try handle.write(contentsOf: data)
            }
        }.value
    }
}

private final class DiagnosticsWriteObserver: @unchecked Sendable {
    private let condition = NSCondition()
    private var persisted = ""

    func record(_ data: Data) {
        condition.lock()
        persisted += String(decoding: data, as: UTF8.self)
        condition.broadcast()
        condition.unlock()
    }

    func waitForMarker(_ marker: String) throws {
        let deadline = Date().addingTimeInterval(2)
        condition.lock()
        defer { condition.unlock() }
        while !persisted.contains(marker) {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "RemoteGatewayProcessDiagnosticsTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for diagnostic marker \(marker)"]
                )
            }
        }
    }
}

private final class SerializedReadProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var shouldPause = true
    private var bufferedRemainder: Data?
    private var concurrentReads = 0
    private var storedMaximumConcurrentReads = 0

    var maximumConcurrentReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMaximumConcurrentReads
    }

    func read(from handle: FileHandle) -> Data {
        lock.lock()
        concurrentReads += 1
        storedMaximumConcurrentReads = max(storedMaximumConcurrentReads, concurrentReads)
        let pause = shouldPause
        shouldPause = false
        lock.unlock()

        let data: Data
        lock.lock()
        if let remainder = bufferedRemainder {
            bufferedRemainder = nil
            data = remainder
            lock.unlock()
        } else {
            lock.unlock()
            let available = handle.availableData
            if pause, available.count > 4 {
                data = Data(available.prefix(4))
                lock.lock()
                bufferedRemainder = Data(available.dropFirst(4))
                lock.unlock()
            } else {
                data = available
            }
        }
        if pause {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }

        lock.lock()
        concurrentReads -= 1
        lock.unlock()
        return data
    }
}

private final class FailingDiagnosticsWriter: @unchecked Sendable {
    private enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private let failingWriteNumber: Int
    private var storedWriteCount = 0

    init(failingWriteNumber: Int) {
        self.failingWriteNumber = failingWriteNumber
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedWriteCount
    }

    func write(_ data: Data, to handle: FileHandle) throws {
        lock.lock()
        storedWriteCount += 1
        let shouldFail = storedWriteCount == failingWriteNumber
        lock.unlock()
        if shouldFail {
            throw Failure.injected
        }
        try handle.write(contentsOf: data)
    }
}
