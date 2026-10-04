@testable import RepoPromptApp
import XCTest

/// Codex app-server stdout frame ceiling: oversized inbound frames end the transport
/// generation with a typed error instead of being dropped while their request stays pending.
///
/// Every case feeds raw bytes through the production chunk path (`handleStdoutChunk` via
/// `debugIngestRawStdoutChunk`) on a DEBUG test transport, using a small frame limit except
/// for the real-ceiling case.
final class CodexAppServerInboundFrameLimitTests: XCTestCase {
    private static let testLimit = 4096
    private static let privatePayloadSentinel = "PRIVATE-HISTORY-SENTINEL"

    private struct Outcome: Equatable {
        let marker: String
        let padBytes: Int
    }

    private enum Delivery: String, CaseIterable {
        /// Completed line and LF in one chunk.
        case singleChunk
        /// Line split mid-way; the second chunk completes it.
        case splitMidLine
        /// Whole line without its terminator, then the LF alone in a later chunk.
        case unfinishedCarryThenNewline
        /// Completed line terminated by CRLF in one chunk.
        case crlfSingleChunk
        /// Whole line plus its CR in one chunk, then the LF alone in a later chunk.
        case crlfSplitBetweenCRAndLF
    }

    // MARK: - Boundary

    func testFrameAtLimitResolvesAndOneByteOverFailsAcrossDeliveryShapes() async throws {
        let limit = Self.testLimit
        for delivery in Delivery.allCases {
            for (lineBytes, shouldResolve) in [(limit, true), (limit + 1, false)] {
                let row = "\(delivery.rawValue) lineBytes=\(lineBytes)"
                let client = await makeClient()
                let generation = await client.currentTransportGeneration()
                let request = try await startRequest(client, method: "thread/resume")
                let line = Self.responseLine(id: request.id, marker: "boundary", totalBytes: lineBytes)
                XCTAssertEqual(line.count, lineBytes, row)

                for chunk in Self.chunks(for: line, delivery: delivery) {
                    await client.debugIngestRawStdoutChunk(chunk)
                }

                let result = await request.task.result
                if shouldResolve {
                    XCTAssertEqual(try? result.get().marker, "boundary", row)
                    let isRunning = await client.debugIsProcessRunning()
                    XCTAssertTrue(isRunning, row)
                    let reason = await client.debugLastTransportTerminationReason()
                    XCTAssertNil(reason, row)
                } else {
                    // An unfinished carry that already holds the frame's CR counts that raw byte, so
                    // it is observed one byte larger than the terminator-stripped payload.
                    let observedBytes = delivery == .crlfSplitBetweenCRAndLF ? lineBytes + 1 : lineBytes
                    assertInboundFrameTooLarge(result, observedBytes: observedBytes, limitBytes: limit, row: row)
                    let reason = await client.debugLastTransportTerminationReason()
                    XCTAssertEqual(
                        reason,
                        .inboundFrameLimitExceeded(observedBytes: observedBytes, limitBytes: limit, generation: generation),
                        row
                    )
                    let isRunning = await client.debugIsProcessRunning()
                    XCTAssertFalse(isRunning, row)
                }
                let pendingCount = await client.debugPendingRequestCount()
                XCTAssertEqual(pendingCount, 0, row)
            }
        }
    }

    // MARK: - Batch routing around a violation

    func testFramesBeforeAnOversizedFrameInOneChunkRouteAndLaterFramesAreIgnored() async throws {
        let limit = Self.testLimit
        struct Row {
            let name: String
            let oversizedIsCompletedLine: Bool
        }
        let rows = [
            // The oversized frame is the unfinished tail of the chunk: caught by carry overflow.
            Row(name: "unfinished-carry-overflow", oversizedIsCompletedLine: false),
            // The oversized frame is a completed line followed by more frames: caught by the line guard.
            Row(name: "completed-oversized-line", oversizedIsCompletedLine: true)
        ]

        for row in rows {
            let client = await makeClient()
            let notifications = await client.subscribeNotifications()
            let collectedMethods = Task { () -> [String] in
                var methods: [String] = []
                for await notification in notifications {
                    methods.append(notification.method)
                }
                return methods
            }
            let first = try await startRequest(client, method: "thread/read")
            let second = try await startRequest(client, method: "thread/resume")

            var chunk = Self.responseLine(id: first.id, marker: "first", totalBytes: 256) + Data("\n".utf8)
            chunk += Data("{\"method\":\"before/overflow\",\"params\":{}}\n".utf8)
            let oversized = Self.responseLine(id: 999, marker: Self.privatePayloadSentinel, totalBytes: limit + 64)
            if row.oversizedIsCompletedLine {
                chunk += oversized + Data("\n".utf8)
                chunk += Data("{\"method\":\"after/overflow\",\"params\":{}}\n".utf8)
                chunk += Self.responseLine(id: second.id, marker: "second", totalBytes: 256) + Data("\n".utf8)
            } else {
                chunk += oversized
            }
            await client.debugIngestRawStdoutChunk(chunk)

            let firstResult = await first.task.result
            XCTAssertEqual(try? firstResult.get().marker, "first", row.name)
            let secondResult = await second.task.result
            assertInboundFrameTooLarge(secondResult, observedBytes: limit + 64, limitBytes: limit, row: row.name)
            let isRunning = await client.debugIsProcessRunning()
            XCTAssertFalse(isRunning, row.name)
            if isRunning {
                // A transport that missed the violation never finishes the stream; fail instead of hanging.
                collectedMethods.cancel()
            }
            // Termination finishes subscriber streams; only the frame before the violation was delivered.
            let methods = await collectedMethods.value
            XCTAssertEqual(methods, ["before/overflow"], row.name)
            let pendingCount = await client.debugPendingRequestCount()
            XCTAssertEqual(pendingCount, 0, row.name)
        }
    }

    // MARK: - Termination contract

    func testInboundFrameLimitFailsEveryPendingRequestOnceAndEndsTheGeneration() async throws {
        let limit = Self.testLimit
        let client = await makeClient()
        let generation = await client.currentTransportGeneration()
        let resume = try await startRequest(client, method: "thread/resume", timeout: 60)
        let read = try await startRequest(client, method: "thread/read", timeout: 60)
        let modelList = try await startRequest(client, method: "model/list", timeout: 60)
        let requests = [resume, read, modelList]
        let armedTimers = await client.debugTimeoutTaskCount()
        XCTAssertEqual(armedTimers, 3)

        let oversized = Self.responseLine(id: requests[0].id, marker: Self.privatePayloadSentinel, totalBytes: limit + 512)
        await client.debugIngestRawStdoutChunk(oversized)

        for request in requests {
            let result = await request.task.result
            assertInboundFrameTooLarge(result, observedBytes: limit + 512, limitBytes: limit, row: request.method)
            guard case let .failure(error) = result else { continue }
            XCTAssertTrue(CodexAppServerClient.isInboundFrameLimitError(error), request.method)
            XCTAssertFalse(CodexAppServerClient.isTimeoutError(error), request.method)
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("\(limit)"), description)
            XCTAssertFalse(description.contains(Self.privatePayloadSentinel), description)
        }
        let pendingCount = await client.debugPendingRequestCount()
        XCTAssertEqual(pendingCount, 0)
        let timerCount = await client.debugTimeoutTaskCount()
        XCTAssertEqual(timerCount, 0)
        let isRunning = await client.debugIsProcessRunning()
        XCTAssertFalse(isRunning)
        let expectedReason = CodexAppServerClient.TransportTerminationReason.inboundFrameLimitExceeded(
            observedBytes: limit + 512,
            limitBytes: limit,
            generation: generation
        )
        let reason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(reason, expectedReason)

        // The rest of the oversized frame and any later frame of the dead generation are no-ops.
        await client.debugIngestRawStdoutChunk(Data("\"}}\n".utf8))
        await client.debugIngestRawStdoutChunk(
            Self.responseLine(id: requests[1].id, marker: "late", totalBytes: 128) + Data("\n".utf8)
        )
        let reasonAfterLateChunks = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(reasonAfterLateChunks, expectedReason)

        do {
            _ = try await client.request(method: "thread/read", params: [:], timeout: nil, useDefaultTimeout: false)
            XCTFail("A request after frame-limit termination must not be admitted")
        } catch {
            guard case .processNotRunning? = error as? CodexAppServerClient.ClientError else {
                return XCTFail("Expected processNotRunning, got \(error)")
            }
        }

        let otherErrors: [Error] = [
            CodexAppServerClient.ClientError.processNotRunning,
            CodexAppServerClient.ClientError.jsonDecodeFailed,
            CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/resume",
                code: nil,
                message: "Request timed out after 30.0s",
                data: nil
            ))
        ]
        for error in otherErrors {
            XCTAssertFalse(CodexAppServerClient.isInboundFrameLimitError(error), "\(error)")
        }
    }

    // MARK: - Generation gate

    func testStaleGenerationChunksAreIgnored() async throws {
        let limit = Self.testLimit
        let client = await makeClient()
        let staleGeneration = await client.currentTransportGeneration()
        await client.debugInstallTestTransport()
        let currentGeneration = await client.currentTransportGeneration()
        XCTAssertNotEqual(currentGeneration, staleGeneration)

        let request = try await startRequest(client, method: "thread/resume")
        let response = Self.responseLine(id: request.id, marker: "current", totalBytes: 256) + Data("\n".utf8)

        await client.debugIngestRawStdoutChunk(response, generation: staleGeneration)
        await client.debugIngestRawStdoutChunk(
            Self.responseLine(id: request.id, marker: "stale", totalBytes: limit + 1),
            generation: staleGeneration
        )
        let pendingAfterStale = await client.debugPendingRequestCount()
        XCTAssertEqual(pendingAfterStale, 1)
        let reasonAfterStale = await client.debugLastTransportTerminationReason()
        XCTAssertNil(reasonAfterStale)
        let isRunning = await client.debugIsProcessRunning()
        XCTAssertTrue(isRunning)

        await client.debugIngestRawStdoutChunk(response, generation: currentGeneration)
        let result = await request.task.result
        XCTAssertEqual(try? result.get().marker, "current")
    }

    // MARK: - EOF flush

    func testStdoutEOFStillFlushesAnUnterminatedFinalFrameAtTheLimit() async throws {
        let limit = Self.testLimit
        let client = await makeClient()
        let answered = try await startRequest(client, method: "thread/read")
        let unanswered = try await startRequest(client, method: "thread/resume")

        // Exactly-at-limit unfinished carry is retained, then routed by the EOF flush.
        await client.debugIngestRawStdoutChunk(
            Self.responseLine(id: answered.id, marker: "flushed", totalBytes: limit)
        )
        let pendingBeforeEOF = await client.debugPendingRequestCount()
        XCTAssertEqual(pendingBeforeEOF, 2)
        await client.debugSimulateStdoutEOF()

        let answeredResult = await answered.task.result
        XCTAssertEqual(try? answeredResult.get().marker, "flushed")
        let unansweredResult = await unanswered.task.result
        guard case let .failure(error) = unansweredResult,
              case .processNotRunning? = error as? CodexAppServerClient.ClientError
        else {
            return XCTFail("Expected the unanswered request to fail with processNotRunning, got \(unansweredResult)")
        }
        let reason = await client.debugLastTransportTerminationReason()
        XCTAssertEqual(reason, .stdoutEOF)
    }

    // MARK: - Real ceiling

    func testRealCeilingAcceptsTheObservedTwentyThreeMegabyteResumeResponse() async throws {
        let client = await makeClient(limit: nil)
        let limitBytes = await client.debugInboundFrameLimitBytes()
        XCTAssertEqual(limitBytes, CodexAppServerClient.Config.maxInboundFrameBytes)

        let request = try await startRequest(client, method: "thread/resume")
        // Byte size of the ordinary `thread/resume` response observed for the incident thread.
        let observedResumeResponseBytes = 23_243_972
        var line = Self.responseLine(id: request.id, marker: "resume", totalBytes: observedResumeResponseBytes)
        line.append(0x0A)
        let pipeReadBytes = 64 * 1024
        var offset = 0
        while offset < line.count {
            let end = min(offset + pipeReadBytes, line.count)
            await client.debugIngestRawStdoutChunk(line.subdata(in: offset ..< end))
            offset = end
        }

        let result = await request.task.result
        let outcome = try result.get()
        XCTAssertEqual(outcome.marker, "resume")
        XCTAssertEqual(outcome.padBytes, observedResumeResponseBytes - Self.responseEnvelopeBytes(id: request.id, marker: "resume"))
        let isRunning = await client.debugIsProcessRunning()
        XCTAssertTrue(isRunning)
        let reason = await client.debugLastTransportTerminationReason()
        XCTAssertNil(reason)
    }

    // MARK: - Helpers

    private struct StartedRequest {
        let id: Int
        let method: String
        let task: Task<Outcome, Error>
    }

    private func makeClient(limit: Int? = CodexAppServerInboundFrameLimitTests.testLimit) async -> CodexAppServerClient {
        let client = CodexAppServerClient(
            writeFrameHandler: { _, _ in },
            livenessProbe: { _ in true },
            expectedAgentPIDRegistrar: .init(register: { _, _, _ in }, clear: { _, _, _ in })
        )
        await client.debugInstallTestTransport()
        if let limit {
            await client.debugSetMaxInboundFrameBytes(limit)
        }
        return client
    }

    /// Starts one request and waits until it is registered, so request IDs stay deterministic.
    private func startRequest(
        _ client: CodexAppServerClient,
        method: String,
        timeout: TimeInterval? = nil
    ) async throws -> StartedRequest {
        let id = await client.debugNextRequestID()
        let pendingBefore = await client.debugPendingRequestCount()
        let task = Task<Outcome, Error> {
            let result = try await client.request(
                method: method,
                params: [:],
                timeout: timeout,
                useDefaultTimeout: false
            )
            return Outcome(
                marker: result["marker"] as? String ?? "",
                padBytes: (result["pad"] as? NSString)?.length ?? -1
            )
        }
        for _ in 0 ..< 2000 {
            if await client.debugPendingRequestCount() == pendingBefore + 1 {
                return StartedRequest(id: id, method: method, task: task)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        throw RequestRegistrationTimeout(method: method)
    }

    private struct RequestRegistrationTimeout: Error {
        let method: String
    }

    private static func responseEnvelopeBytes(id: Int, marker: String) -> Int {
        "{\"id\":\(id),\"result\":{\"marker\":\"\(marker)\",\"pad\":\"\"}}".utf8.count
    }

    /// A JSON-RPC response line of exactly `totalBytes` bytes, without a line terminator.
    private static func responseLine(id: Int, marker: String, totalBytes: Int) -> Data {
        let padCount = totalBytes - responseEnvelopeBytes(id: id, marker: marker)
        precondition(padCount >= 0, "totalBytes too small for the response envelope")
        let text = "{\"id\":\(id),\"result\":{\"marker\":\"\(marker)\",\"pad\":\""
            + String(repeating: "x", count: padCount)
            + "\"}}"
        return Data(text.utf8)
    }

    private static func chunks(for line: Data, delivery: Delivery) -> [Data] {
        switch delivery {
        case .singleChunk:
            return [line + Data("\n".utf8)]
        case .splitMidLine:
            let middle = line.count / 2
            return [line.subdata(in: 0 ..< middle), line.subdata(in: middle ..< line.count) + Data("\n".utf8)]
        case .unfinishedCarryThenNewline:
            return [line, Data("\n".utf8)]
        case .crlfSingleChunk:
            return [line + Data("\r\n".utf8)]
        case .crlfSplitBetweenCRAndLF:
            return [line + Data("\r".utf8), Data("\n".utf8)]
        }
    }

    private func assertInboundFrameTooLarge(
        _ result: Result<Outcome, Error>,
        observedBytes: Int,
        limitBytes: Int,
        row: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("\(row): expected inboundFrameTooLarge, got \(result)", file: file, line: line)
        }
        guard case let .inboundFrameTooLarge(observed, limit)? = error as? CodexAppServerClient.ClientError else {
            return XCTFail("\(row): expected inboundFrameTooLarge, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(observed, observedBytes, row, file: file, line: line)
        XCTAssertEqual(limit, limitBytes, row, file: file, line: line)
    }
}
