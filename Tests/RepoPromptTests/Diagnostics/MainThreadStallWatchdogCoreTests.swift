#if DEBUG
    @testable import RepoPromptAgentCore
    @testable import RepoPromptApp
    @testable import RepoPromptPlatform
    @testable import RepoPromptUI
    import XCTest

    final class MainThreadStallWatchdogCoreTests: XCTestCase {
        private typealias Core = MainThreadStallWatchdogCore

        private let start = ContinuousClock.now

        private func at(milliseconds: Int) -> ContinuousClock.Instant {
            start + .milliseconds(milliseconds)
        }

        func testNoFaultBeforeStallThreshold() {
            var core = Core()
            XCTAssertEqual(core.tick(now: at(milliseconds: 0)), .sendPing(id: 1))
            for milliseconds in [500, 1000, 1500, 1999] {
                XCTAssertEqual(core.tick(now: at(milliseconds: milliseconds)), Core.TickAction.none, "\(milliseconds) ms")
            }
            XCTAssertEqual(
                core.tick(now: at(milliseconds: 2000)),
                .fault(id: 1, stalledFor: .seconds(2), enqueuedAt: at(milliseconds: 0))
            )
        }

        func testExactlyOneFaultPerPing() {
            var core = Core()
            var faults: [Core.TickAction] = []
            for step in 0 ... 40 {
                let action = core.tick(now: at(milliseconds: step * 500))
                if case .fault = action {
                    faults.append(action)
                }
            }
            XCTAssertEqual(faults, [.fault(id: 1, stalledFor: .seconds(2), enqueuedAt: at(milliseconds: 0))])
        }

        func testNeverSendsSecondPingWhileOneIsOutstanding() {
            var core = Core()
            var pings: [UInt64] = []
            for step in 0 ... 20 {
                if case let .sendPing(id) = core.tick(now: at(milliseconds: step * 500)) {
                    pings.append(id)
                }
            }
            XCTAssertEqual(pings, [1])
            XCTAssertEqual(core.outstanding?.id, 1)

            _ = core.pong(id: 1, now: at(milliseconds: 10100))
            XCTAssertNil(core.outstanding)
            XCTAssertEqual(core.tick(now: at(milliseconds: 10500)), .sendPing(id: 2))
        }

        func testLateTickResetsValidityWindowWithoutNewPing() {
            var core = Core()
            XCTAssertEqual(core.tick(now: at(milliseconds: 0)), .sendPing(id: 1))
            XCTAssertEqual(core.tick(now: at(milliseconds: 500)), Core.TickAction.none)

            // A 4.5 s gap (debugger stop, sleep/wake, App Nap) invalidates the window.
            XCTAssertEqual(core.tick(now: at(milliseconds: 5000)), Core.TickAction.none)
            XCTAssertEqual(core.outstanding?.windowStart, at(milliseconds: 5000))
            XCTAssertEqual(core.outstanding?.enqueuedAt, at(milliseconds: 0))

            for milliseconds in [5500, 6000, 6500] {
                XCTAssertEqual(core.tick(now: at(milliseconds: milliseconds)), Core.TickAction.none, "\(milliseconds) ms")
            }
            XCTAssertEqual(
                core.tick(now: at(milliseconds: 7000)),
                .fault(id: 1, stalledFor: .seconds(2), enqueuedAt: at(milliseconds: 0))
            )

            // A late tick with nothing outstanding sends no ping; the next valid tick does.
            _ = core.pong(id: 1, now: at(milliseconds: 7100))
            XCTAssertEqual(core.tick(now: at(milliseconds: 9000)), Core.TickAction.none)
            XCTAssertNil(core.outstanding)
            XCTAssertEqual(core.tick(now: at(milliseconds: 9500)), .sendPing(id: 2))
        }

        func testRecoveryOnlyAfterFault() {
            var core = Core()
            XCTAssertEqual(core.tick(now: at(milliseconds: 0)), .sendPing(id: 1))
            XCTAssertNil(core.pong(id: 1, now: at(milliseconds: 300)))

            XCTAssertEqual(core.tick(now: at(milliseconds: 500)), .sendPing(id: 2))
            XCTAssertEqual(core.tick(now: at(milliseconds: 1000)), Core.TickAction.none)
            XCTAssertEqual(core.tick(now: at(milliseconds: 3000)), Core.TickAction.none)
            for milliseconds in [3500, 4000, 4500] {
                XCTAssertEqual(core.tick(now: at(milliseconds: milliseconds)), Core.TickAction.none, "\(milliseconds) ms")
            }
            XCTAssertEqual(
                core.tick(now: at(milliseconds: 5000)),
                .fault(id: 2, stalledFor: .seconds(2), enqueuedAt: at(milliseconds: 500))
            )
            XCTAssertEqual(
                core.pong(id: 2, now: at(milliseconds: 6000)),
                Core.Recovery(id: 2, stalledFor: .seconds(3), sinceEnqueue: .milliseconds(5500))
            )
            XCTAssertNil(core.outstanding)
        }

        func testStalePongIsIgnored() {
            var core = Core()
            XCTAssertEqual(core.tick(now: at(milliseconds: 0)), .sendPing(id: 1))
            let before = core

            XCTAssertNil(core.pong(id: 99, now: at(milliseconds: 100)))
            XCTAssertEqual(core, before)

            for step in 1 ... 4 {
                _ = core.tick(now: at(milliseconds: step * 500))
            }
            XCTAssertEqual(core.outstanding?.hasFaulted, true)
            XCTAssertNil(core.pong(id: 0, now: at(milliseconds: 2100)))
            XCTAssertEqual(core.outstanding?.id, 1)
            XCTAssertNotNil(core.pong(id: 1, now: at(milliseconds: 2200)))
            XCTAssertNil(core.pong(id: 1, now: at(milliseconds: 2300)))
        }
    }
#endif
