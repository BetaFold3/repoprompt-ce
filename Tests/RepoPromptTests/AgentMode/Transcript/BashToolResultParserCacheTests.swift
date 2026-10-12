@testable import RepoPromptApp
import XCTest

/// D3: process-wide two-generation bash parser cache and per-build metadata memo.
/// Caching must never change parser output.
final class BashToolResultParserCacheTests: XCTestCase {
    private typealias Cache = BashToolResultParser.Cache

    // MARK: - Trimming fast path

    func testConditionalTrimMatchesFoundationTrimmingIncludingUnicodeWhitespace() {
        let samples = [
            "",
            "plain",
            " leading",
            "trailing\n",
            "\t both \r\n",
            "\u{00A0}nbsp\u{00A0}",
            "\u{3000}ideographic",
            "line separator\u{2028}",
            "\u{2029}paragraph",
            "\u{0085}next line",
            "\u{200B}zero-width-not-whitespace\u{200B}",
            " \u{0301}combining after space",
            "x \u{0301}",
            "\u{0301}leading combining",
            "emoji 👩‍👩‍👧 ",
            " \n\t\u{00A0}\u{3000} ",
            #"{"status":"completed","output":"x"}"#
        ]
        for sample in samples {
            XCTAssertEqual(
                BashToolResultParser.trimmingWhitespaceAndNewlinesIfNeeded(sample),
                sample.trimmingCharacters(in: .whitespacesAndNewlines),
                "sample: \(sample.debugDescription)"
            )
        }
    }

    func testMetadataWithAndWithoutContextMatchesUncachedParserForPaddedInputs() {
        let token = UUID().uuidString
        let bodies = [
            #"{"type":"commandExecution","status":"inProgress","processId":"\#(token)-1"}"#,
            #"{"type":"commandExecution","status":"completed","exitCode":0,"aggregatedOutput":"\#(token)"}"#,
            #"{"status":"failed","exit_code":2,"summary_only":true,"output":"\#(token)"}"#,
            "Process running with session ID 42 \(token)",
            "Process completed with exit code 0 \(token)"
        ]
        let paddings: [(String, String)] = [("", ""), (" ", "\n"), ("\u{3000}", "\u{2028}"), ("\u{00A0}\t", "")]
        for body in bodies {
            for (prefix, suffix) in paddings {
                let raw = prefix + body + suffix
                let expected = BashToolResultParser.parseLivenessMetadata(raw: raw)
                let context = AgentToolResultProcessingContext()
                XCTAssertEqual(BashToolResultParser.parseMetadata(raw: raw), expected)
                XCTAssertEqual(BashToolResultParser.parseMetadata(raw: raw), expected)
                XCTAssertEqual(BashToolResultParser.parseMetadata(raw: raw, context: context), expected)
                XCTAssertEqual(BashToolResultParser.parseMetadata(raw: raw, context: context), expected)
            }
        }
    }

    #if DEBUG || EDIT_FLOW_PERF

        // MARK: - Warm hit rate

        func testBuildLocalMetadataMemoRetainsMoreThanOldCapAcrossPasses() {
            let context = AgentToolResultProcessingContext()
            let raws = (0 ..< 300).map { payload(index: $0, token: "build-local") }
            var computeCount = 0
            func lookup(_ raw: String) -> BashToolResultParser.Metadata {
                context.bashMetadata(raw: raw) {
                    computeCount += 1
                    return BashToolResultParser.parseLivenessMetadata(raw: raw)
                }
            }
            let first = raws.map(lookup)
            let second = raws.map(lookup)
            XCTAssertEqual(first, second)
            XCTAssertEqual(computeCount, raws.count)
            XCTAssertEqual(context.snapshotMetrics().bashMetadataCacheHitCount, raws.count)
        }

        func testThreePassesOverMoreThanThousandKeysHitOnWarmPasses() {
            let token = UUID().uuidString
            let keyCount = 1200
            let raws = (0 ..< keyCount).map { payload(index: $0, token: token) }
            let cache = Cache()
            var computeCount = 0
            var outputsByPass: [[BashToolResultParser.Metadata]] = []
            var hitsByPass: [Int] = []

            for _ in 0 ..< 3 {
                let before = cache.countersSnapshot().metadata
                outputsByPass.append(raws.map { raw in
                    cache.metadata(raw: raw) {
                        computeCount += 1
                        return BashToolResultParser.parseLivenessMetadata(raw: raw)
                    }
                })
                hitsByPass.append(cache.countersSnapshot().metadata.hitCount - before.hitCount)
            }

            XCTAssertEqual(hitsByPass[0], 0)
            XCTAssertGreaterThanOrEqual(Double(hitsByPass[1]) / Double(keyCount), 0.95)
            XCTAssertGreaterThanOrEqual(Double(hitsByPass[2]) / Double(keyCount), 0.95)
            XCTAssertEqual(computeCount, keyCount)
            XCTAssertEqual(outputsByPass[1], outputsByPass[0])
            XCTAssertEqual(outputsByPass[2], outputsByPass[0])
            XCTAssertEqual(outputsByPass[0], raws.map { BashToolResultParser.parseLivenessMetadata(raw: $0) })
            let counters = cache.countersSnapshot().metadata
            XCTAssertEqual(counters.currentEntryCount, keyCount)
            XCTAssertLessThanOrEqual(counters.currentByteCount, Cache.Limits.processDefault.maxBytesPerTable)
        }

        func testProcessWideParserHitsOnWarmPassesForBothTables() {
            let token = UUID().uuidString
            let keyCount = 1200
            let raws = (0 ..< keyCount).map { payload(index: $0, token: token, outputSize: 1000) }
            let argsJSON = #"{"command":"echo \#(token)"}"#
            var metadataHitsByPass: [Int] = []
            var parsedHitsByPass: [Int] = []
            var firstParsed: [BashToolResultParser.ParsedResult] = []

            for pass in 0 ..< 3 {
                let before = BashToolResultParser.cacheCountersSnapshot()
                let metadata = raws.map { BashToolResultParser.parseMetadata(raw: $0) }
                let parsed = raws.map { BashToolResultParser.parse(raw: $0, argsJSON: argsJSON) }
                let after = BashToolResultParser.cacheCountersSnapshot()
                metadataHitsByPass.append(after.metadata.hitCount - before.metadata.hitCount)
                parsedHitsByPass.append(after.parsed.hitCount - before.parsed.hitCount)
                XCTAssertEqual(metadata, raws.map { BashToolResultParser.parseLivenessMetadata(raw: $0) })
                if pass == 0 {
                    firstParsed = parsed
                } else {
                    XCTAssertEqual(parsed, firstParsed)
                }
            }

            for pass in 1 ..< 3 {
                XCTAssertGreaterThanOrEqual(Double(metadataHitsByPass[pass]) / Double(keyCount), 0.95, "metadata pass \(pass + 1)")
                XCTAssertGreaterThanOrEqual(Double(parsedHitsByPass[pass]) / Double(keyCount), 0.95, "parsed pass \(pass + 1)")
            }
            XCTAssertEqual(firstParsed.first?.command, "echo \(token)")
        }

        // MARK: - Bounded memory

        func testEntryAndByteBudgetsStayBoundedAcrossRotationAndOversizeEntries() {
            let limits = Cache.Limits(maxEntriesPerGeneration: 64, maxBytesPerTable: 64 * 1024)
            let cache = Cache(limits: limits)
            let token = UUID().uuidString
            var computeCount = 0

            for index in 0 ..< 1000 {
                let outputSize = index.isMultiple(of: 97) ? 40 * 1024 : 100 + (index % 13) * 450
                let raw = payload(index: index, token: token, outputSize: outputSize)
                let args = #"{"command":"echo \#(index)"}"#
                let metadata = cache.metadata(raw: raw) {
                    computeCount += 1
                    return BashToolResultParser.parseLivenessMetadata(raw: raw)
                }
                XCTAssertEqual(metadata, BashToolResultParser.parseLivenessMetadata(raw: raw))
                let expectedParsed = parsedValue(raw: raw, index: index)
                XCTAssertEqual(cache.parsed(raw: raw, argsJSON: args) { expectedParsed }, expectedParsed)

                let counters = cache.countersSnapshot()
                for table in [counters.metadata, counters.parsed] {
                    XCTAssertLessThanOrEqual(table.currentByteCount, limits.maxBytesPerTable)
                    XCTAssertLessThanOrEqual(table.currentEntryCount, limits.maxEntriesPerGeneration * 2)
                }
            }
            XCTAssertEqual(computeCount, 1000)

            let counters = cache.countersSnapshot()
            XCTAssertGreaterThan(counters.metadata.evictedEntryCount, 0)
            XCTAssertGreaterThan(counters.parsed.evictedEntryCount, 0)

            // An entry larger than one generation's byte share is returned but never resident.
            let oversizeRaw = payload(index: 5000, token: token, outputSize: 40 * 1024)
            let beforeOversize = cache.countersSnapshot().metadata
            var oversizeComputeCount = 0
            for _ in 0 ..< 2 {
                let value = cache.metadata(raw: oversizeRaw) {
                    oversizeComputeCount += 1
                    return BashToolResultParser.parseLivenessMetadata(raw: oversizeRaw)
                }
                XCTAssertEqual(value, BashToolResultParser.parseLivenessMetadata(raw: oversizeRaw))
            }
            let afterOversize = cache.countersSnapshot().metadata
            XCTAssertEqual(oversizeComputeCount, 2)
            XCTAssertEqual(afterOversize.missCount - beforeOversize.missCount, 2)
            XCTAssertEqual(afterOversize.currentByteCount, beforeOversize.currentByteCount)
            XCTAssertEqual(afterOversize.currentEntryCount, beforeOversize.currentEntryCount)
        }

        func testOldGenerationHitPromotesAndSurvivesNextRotation() {
            let cache = Cache(limits: .init(maxEntriesPerGeneration: 4, maxBytesPerTable: 1024 * 1024))
            let keys = (0 ..< 8).map { "key-\($0)" }
            var computed: [String] = []
            func lookup(_ key: String) -> BashToolResultParser.Metadata {
                cache.metadata(raw: key) {
                    computed.append(key)
                    return BashToolResultParser.Metadata(
                        isRunning: false, statusWord: key, exitCode: 0, processID: nil, isSummaryOnly: false
                    )
                }
            }

            keys.prefix(4).forEach { _ = lookup($0) } // young: 0-3
            keys.suffix(4).forEach { _ = lookup($0) } // rotate: old 0-3, young 4-7
            XCTAssertEqual(lookup("key-0").statusWord, "key-0") // old hit -> rotate: old 4-7, young 0
            _ = lookup("key-new-a")
            _ = lookup("key-new-b")
            _ = lookup("key-new-c") // young: 0, a, b, c
            _ = lookup("key-new-d") // rotate: old drops 4-7
            XCTAssertEqual(lookup("key-0").statusWord, "key-0") // still resident in old
            XCTAssertEqual(computed.count { $0 == "key-0" }, 1)
            _ = lookup("key-5")
            XCTAssertEqual(computed.count { $0 == "key-5" }, 2)
            // Rotation on the key-0 promotion drops 1-3; the key-new-d rotation drops 4-7.
            XCTAssertEqual(cache.countersSnapshot().metadata.evictedEntryCount, 7)
        }

        // MARK: - Concurrency

        func testConcurrentSameKeyComputeReturnsEqualValuesAndKeepsOneAccountedEntry() {
            let cache = Cache()
            let raw = payload(index: 1, token: UUID().uuidString)
            let args = #"{"command":"echo concurrent"}"#
            let expectedMetadata = BashToolResultParser.parseLivenessMetadata(raw: raw)
            let expectedParsed = parsedValue(raw: raw, index: 1)
            let resultLock = NSLock()
            var metadataResults: [BashToolResultParser.Metadata] = []
            var parsedResults: [BashToolResultParser.ParsedResult] = []

            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let metadata = cache.metadata(raw: raw) { BashToolResultParser.parseLivenessMetadata(raw: raw) }
                let parsed = cache.parsed(raw: raw, argsJSON: args) { expectedParsed }
                resultLock.lock()
                metadataResults.append(metadata)
                parsedResults.append(parsed)
                resultLock.unlock()
            }

            XCTAssertEqual(metadataResults.count, 64)
            XCTAssertTrue(metadataResults.allSatisfy { $0 == expectedMetadata })
            XCTAssertTrue(parsedResults.allSatisfy { $0 == expectedParsed })
            let counters = cache.countersSnapshot()
            XCTAssertEqual(counters.metadata.currentEntryCount, 1)
            XCTAssertEqual(counters.parsed.currentEntryCount, 1)
            XCTAssertEqual(counters.metadata.hitCount + counters.metadata.missCount, 64)
            XCTAssertEqual(counters.metadata.currentByteCount, Cache.accountedByteCount(raw: raw, metadata: expectedMetadata))
            XCTAssertEqual(
                counters.parsed.currentByteCount,
                Cache.accountedByteCount(key: .init(raw: raw, argsJSON: args), parsed: expectedParsed)
            )
        }
    #endif

    // MARK: - Helpers

    private func payload(index: Int, token: String, outputSize: Int? = nil) -> String {
        let size = outputSize ?? (2000 + (index % 7) * 300)
        let output = String(repeating: "o", count: size)
        return #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"\#(index)","aggregatedOutput":"\#(token)-\#(index)-\#(output)"}"#
    }

    private func parsedValue(raw: String, index: Int) -> BashToolResultParser.ParsedResult {
        BashToolResultParser.ParsedResult(
            isRunning: false,
            command: "echo \(index)",
            statusWord: "completed",
            exitCode: 0,
            output: String(raw.suffix(64)),
            processID: "\(index)",
            isSummaryOnly: false
        )
    }
}
