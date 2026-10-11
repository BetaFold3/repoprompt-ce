#if DEBUG
    @testable import RepoPromptAgentCore
    @testable import RepoPromptApp
    @testable import RepoPromptPlatform
    import XCTest

    final class AgentTranscriptUpdateBurstCounterTests: XCTestCase {
        private typealias Counter = AgentTranscriptUpdateBurstCounter

        func testBelowThresholdReturnsNoReport() {
            var counter = Counter()
            for _ in 1 ..< Counter.initialReportThreshold {
                XCTAssertNil(counter.note(.innerGeometryDelivery))
            }
            XCTAssertEqual(counter.total, Counter.initialReportThreshold - 1)
        }

        func testReportsExactlyOnceAtThresholdWithPerEventCounts() throws {
            var counter = Counter()
            for _ in 0 ..< 1500 {
                XCTAssertNil(counter.note(.innerGeometryDelivery))
            }
            for _ in 0 ..< 499 {
                XCTAssertNil(counter.note(.outerScrollGeometryAction))
            }

            let report = try XCTUnwrap(counter.note(.innerPinTransition))
            XCTAssertEqual(report.total, 2000)
            XCTAssertEqual(report.count(of: .innerGeometryDelivery), 1500)
            XCTAssertEqual(report.count(of: .outerScrollGeometryAction), 499)
            XCTAssertEqual(report.count(of: .innerPinTransition), 1)
            XCTAssertEqual(report.count(of: .innerDuplicatePosition), 0)
            XCTAssertEqual(
                report.summary,
                "inner_geometry_delivery=1500 inner_pin_transition=1 outer_scroll_geometry_action=499"
            )

            XCTAssertNil(counter.note(.innerGeometryDelivery))
        }

        func testFurtherReportsOnlyAtTenfoldMultiples() {
            var counter = Counter()
            var reportTotals: [Int] = []
            for _ in 0 ..< 200_001 {
                if let report = counter.note(.transcriptBlockRowsBody) {
                    reportTotals.append(report.total)
                }
            }
            XCTAssertEqual(reportTotals, [2000, 20000, 200_000])
        }

        func testEndTurnResetsCountsAndThreshold() throws {
            var counter = Counter()
            for _ in 1 ..< Counter.initialReportThreshold {
                _ = counter.note(.toolCardRenderStateDelivery)
            }
            XCTAssertNotNil(counter.note(.toolCardRenderStateAssignment))

            counter.endTurn()
            XCTAssertEqual(counter, Counter())
            XCTAssertEqual(counter.total, 0)
            XCTAssertTrue(counter.counts.allSatisfy { $0 == 0 })

            for _ in 1 ..< Counter.initialReportThreshold {
                XCTAssertNil(counter.note(.innerFollowRejected))
            }
            let report = try XCTUnwrap(counter.note(.innerFollowRejected))
            XCTAssertEqual(report.total, 2000)
            XCTAssertEqual(report.count(of: .innerFollowRejected), 2000)
            XCTAssertEqual(report.count(of: .toolCardRenderStateDelivery), 0)
        }
    }
#endif
