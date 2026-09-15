@testable import RepoPromptApp
import XCTest

/// Deterministic accounting contracts (plan §4, §8). Every qualified input here is a synthetic
/// test fixture supplied through the accumulator's explicit qualification boundary; production
/// wiring installs `.productionClaude` (`.executionVerified`); `.unqualified` remains a
/// lifecycle-only policy exercised explicitly here.
final class AgentUsageAccountingTests: XCTestCase {
    private let owner = UUID()
    private let execution = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let qualified = AgentUsageQualification.qualified(contractID: "test.claude.cumulative.v1")

    func testRequestSnapshotsUpsertAndAuthoritativeResultReplacesSubtotal() {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn1 = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn1, executionID: execution), .accepted)

        // Snapshot upserts for one request: later fields fill in, duplicates do not add.
        XCTAssertEqual(accumulator.observe(request(turn1, .messageStart, requestID: "r1", input: 100, read: 50)), .accepted)
        XCTAssertEqual(accumulator.observe(request(turn1, .messageDelta, requestID: "r1", output: 10)), .accepted)
        XCTAssertEqual(accumulator.observe(request(turn1, .messageStart, requestID: "r1", input: 100, read: 50)), .accepted)
        // Sidechain observation stays out of the main-loop subtotal.
        XCTAssertEqual(
            accumulator.observe(request(turn1, .assistant, requestID: "r2", input: 999, parentToolUseID: "tool-1")),
            .accepted
        )
        XCTAssertEqual(accumulator.closeTurn(turn1, outcome: .interrupted), .accepted)
        let closedTurn = accumulator.persistedRepresentation?.record?.turns.first
        XCTAssertEqual(closedTurn?.inputTokens, 100)
        XCTAssertEqual(closedTurn?.cacheReadInputTokens, 50)
        XCTAssertNil(closedTurn?.cacheCreationInputTokens)
        XCTAssertEqual(closedTurn?.outputTokens, 10)
        XCTAssertEqual(closedTurn?.observedRequestCount, 2)
        XCTAssertEqual(closedTurn?.outcome, .interrupted)
        XCTAssertEqual(closedTurn?.coverage, .partial)

        // Authoritative result replaces (never adds to) the request subtotal.
        let turn2 = UUID()
        accumulator.registerTurn(turn2, executionID: execution)
        XCTAssertEqual(accumulator.observe(request(turn2, .messageStart, requestID: "r3", input: 5, read: 5, creation: 5)), .accepted)
        XCTAssertEqual(
            accumulator.observe(result(turn2, id: "res-1", input: 1000, output: 20, read: 900, creation: 0, cost: "1.00")),
            .accepted
        )
        let completedTurn = accumulator.persistedRepresentation?.record?.turns.last
        XCTAssertEqual(completedTurn?.acceptedResultID, "res-1")
        XCTAssertEqual(completedTurn?.inputTokens, 1000)
        XCTAssertEqual(completedTurn?.outputTokens, 20)
        XCTAssertEqual(completedTurn?.cacheReadInputTokens, 900)
        XCTAssertEqual(completedTurn?.cacheCreationInputTokens, 0)
        XCTAssertEqual(completedTurn?.observedRequestCount, 1)
        XCTAssertEqual(completedTurn?.coverage, .complete)
        XCTAssertEqual(completedTurn?.outcome, .completed)
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .complete))

        // A cost-only result is accepted even though it carries no token counts.
        let turn3 = UUID()
        accumulator.registerTurn(turn3, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn3, id: "res-2", cost: "1.25")), .accepted)
        let costOnlyTurn = accumulator.persistedRepresentation?.record?.turns.last
        XCTAssertEqual(costOnlyTurn?.acceptedResultID, "res-2")
        XCTAssertNil(costOnlyTurn?.inputTokens)
        XCTAssertEqual(costOnlyTurn?.coverage, .partial)
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, Decimal(string: "1.25"))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.count, 3)
    }

    func testRejectedInputsNeverMutatePersistedAccounting() {
        // Lifecycle-only policy: an unqualified contract registers identity but never materializes state.
        XCTAssertEqual(AgentUsageQualification.productionClaude, .executionVerified, "normal builds verify each execution")
        var production = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: .opaque(.null),
            hasPriorHistory: true,
            qualification: .unqualified
        )
        production.beginExecution(executionID: execution, providerSessionID: "ps", baseline: .verifiedZero, at: start)
        let turn = UUID()
        XCTAssertEqual(production.registerTurn(turn, executionID: execution), .rejected(.unqualifiedContract))
        XCTAssertEqual(
            production.observe(result(turn, id: "res-1", input: 1, output: 1, read: 1, creation: 1, cost: "9.99")),
            .rejected(.unqualifiedContract)
        )
        XCTAssertEqual(production.persistedRepresentation, .opaque(.null))
        XCTAssertNil(production.sessionCostEstimate)
        XCTAssertNil(production.cacheHitShare)
        var absent = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .unqualified)
        absent.beginExecution(executionID: execution, providerSessionID: nil, baseline: .verifiedZero, at: start)
        XCTAssertNil(absent.persistedRepresentation, "an unqualified policy must not create an apparent measured record")

        // Qualified: each ineligible input is rejected without changing the record.
        var accumulator = makeQualified(baseline: .verifiedZero)
        let pendingA = UUID()
        let pendingB = UUID()
        accumulator.registerTurn(pendingA, executionID: execution)
        accumulator.registerTurn(pendingB, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(pendingA, id: "res-1", cost: "1.00")), .accepted)
        let baselineRecord = accumulator.persistedRepresentation

        var replayed = result(pendingB, id: "res-2", cost: "5.00")
        replayed.attribution = .replay
        XCTAssertEqual(accumulator.observe(replayed), .rejected(.replayedOrSynthetic))
        var synthetic = replayed
        synthetic.attribution = .synthetic
        XCTAssertEqual(accumulator.observe(synthetic), .rejected(.replayedOrSynthetic))
        var unverified = replayed
        unverified.attribution = .unverified
        XCTAssertEqual(accumulator.observe(unverified), .rejected(.unverifiedAttribution))
        var unowned = result(pendingB, id: "res-2", cost: "5.00")
        unowned.hasOriginalResultAuthority = false
        XCTAssertEqual(accumulator.observe(unowned), .rejected(.missingResultAuthority))
        XCTAssertEqual(accumulator.observe(result(UUID(), id: "res-2", cost: "5.00")), .rejected(.unregisteredTurn))
        var unattributed = result(pendingB, id: "res-2", cost: "5.00")
        unattributed.turnID = nil
        XCTAssertEqual(
            accumulator.observe(unattributed),
            .rejected(.unregisteredTurn),
            "a result while other turns are pending is not blindly attributed"
        )
        XCTAssertEqual(accumulator.observe(result(pendingB, id: nil, cost: "5.00")), .rejected(.unidentifiedObservation))
        XCTAssertEqual(accumulator.observe(result(pendingB, id: "res-1", cost: "1.00")), .rejected(.duplicateResult))
        XCTAssertEqual(accumulator.observe(request(pendingB, .messageStart, requestID: nil, input: 1)), .rejected(.unidentifiedObservation))
        var disposed = result(pendingB, id: "res-3", cost: "2.00")
        disposed.executionID = UUID()
        XCTAssertEqual(accumulator.observe(disposed), .rejected(.disposedExecution))
        XCTAssertEqual(accumulator.persistedRepresentation, baselineRecord)
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, Decimal(string: "1.00"))

        // Late events after disposal are rejected; the open turn closes as interrupted.
        accumulator.endExecution(execution)
        XCTAssertEqual(accumulator.observe(result(pendingB, id: "res-3", cost: "2.00")), .rejected(.disposedExecution))
        XCTAssertEqual(accumulator.registerTurn(UUID(), executionID: execution), .rejected(.disposedExecution))
        let interrupted = accumulator.persistedRepresentation?.record?.turns.last
        XCTAssertEqual(interrupted?.turnID, pendingB)
        XCTAssertEqual(interrupted?.outcome, .interrupted)
        XCTAssertEqual(interrupted?.coverage, .partial)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.last?.state, .closed)
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, Decimal(string: "1.00"))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: .nan))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: -0.5))
        XCTAssertEqual(AgentUsageObservationInput.exactCost(fromReported: 2.171), Decimal(string: "2.171"))
    }

    func testWeightedCacheHitShareUsesTokenWeightsAndQualifiesMissingZeroAndOverflow() {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn1 = UUID()
        accumulator.registerTurn(turn1, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn1, id: "res-1", input: 10, output: 1, read: 90, creation: 0)), .accepted)
        let turn2 = UUID()
        accumulator.registerTurn(turn2, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn2, id: "res-2", input: 900, output: 1, read: 0, creation: 0)), .accepted)
        XCTAssertEqual(accumulator.cacheHitShare, .init(ratio: decimal("0.09"), coverage: .complete), "9%, not the 45% average of per-turn percentages")

        // Missing components exclude the turn and make coverage partial without changing the ratio.
        let turn3 = UUID()
        accumulator.registerTurn(turn3, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn3, id: "res-3", input: 500, output: 1)), .accepted)
        XCTAssertEqual(accumulator.cacheHitShare, .init(ratio: decimal("0.09"), coverage: .partial))

        // Zero denominator is unavailable, not zero.
        var zero = makeQualified(baseline: .verifiedZero)
        let zeroTurn = UUID()
        zero.registerTurn(zeroTurn, executionID: execution)
        XCTAssertEqual(zero.observe(result(zeroTurn, id: "res-z", input: 0, output: 5, read: 0, creation: 0)), .accepted)
        XCTAssertNil(zero.cacheHitShare)

        // Overflow cannot manufacture a total.
        var overflow = makeQualified(baseline: .verifiedZero)
        for index in 0 ..< 2 {
            let turn = UUID()
            overflow.registerTurn(turn, executionID: execution)
            XCTAssertEqual(
                overflow.observe(result(turn, id: "res-o\(index)", input: 0, output: 0, read: Int.max, creation: 0)),
                .accepted
            )
        }
        XCTAssertNil(overflow.cacheHitShare)
        XCTAssertNil(makeQualified(baseline: .verifiedZero).cacheHitShare)
    }

    func testCumulativeCostCheckpointsResetsDecreasesUnknownBaselineAndDisposal() {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn1 = UUID()
        accumulator.registerTurn(turn1, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn1, id: "res-1", cost: "1.00")), .accepted)
        let turn2 = UUID()
        accumulator.registerTurn(turn2, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn2, id: "res-2", cost: "1.50")), .accepted)
        XCTAssertEqual(accumulator.observe(result(turn2, id: "res-2", cost: "1.50")), .rejected(.duplicateResult))
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.50"), currency: "USD", coverage: .complete))

        // Verified reset opens a new zero-baseline segment: 1.50 + 0.20 = 1.70.
        XCTAssertEqual(accumulator.noteVerifiedReset(executionID: execution), .accepted)
        let turn3 = UUID()
        accumulator.registerTurn(turn3, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn3, id: "res-3", cost: "0.20")), .accepted)
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.70"), currency: "USD", coverage: .complete))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.count, 2)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.last?.resetGeneration, 1)

        // Unexplained decrease suspends the segment; no reset is inferred and no refund happens.
        let turn4 = UUID()
        accumulator.registerTurn(turn4, executionID: execution)
        XCTAssertEqual(
            accumulator.observe(result(turn4, id: "res-4", cost: "0.10")),
            .acceptedWithMonetaryRejection(.unexplainedDecrease)
        )
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.70"), currency: "USD", coverage: .partial))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.last?.state, .suspended)
        let turn5 = UUID()
        accumulator.registerTurn(turn5, executionID: execution)
        XCTAssertEqual(
            accumulator.observe(result(turn5, id: "res-5", cost: "0.30")),
            .acceptedWithMonetaryRejection(.segmentSuspended)
        )
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, decimal("1.70"), "suspended segment never advances")
        XCTAssertEqual(accumulator.noteVerifiedReset(executionID: UUID()), .rejected(.disposedExecution))

        // Unknown resumed baseline: the first observed cumulative amount is not new spend.
        var resumed = makeQualified(baseline: .unknown, hasPriorHistory: true)
        let resumedTurn = UUID()
        resumed.registerTurn(resumedTurn, executionID: execution)
        XCTAssertEqual(resumed.observe(result(resumedTurn, id: "res-r1", cost: "3.00")), .accepted)
        XCTAssertEqual(resumed.sessionCostEstimate, .init(amount: 0, currency: "USD", coverage: .partial))
        let resumedTurn2 = UUID()
        resumed.registerTurn(resumedTurn2, executionID: execution)
        XCTAssertEqual(resumed.observe(result(resumedTurn2, id: "res-r2", cost: "3.50")), .accepted)
        XCTAssertEqual(resumed.sessionCostEstimate, .init(amount: decimal("0.50"), currency: "USD", coverage: .partial))
        XCTAssertEqual(resumed.persistedRepresentation?.record?.hasUnmeasuredHistory, true)

        // Disposed execution: late events are rejected and accepted checkpoints survive.
        resumed.endExecution(execution)
        XCTAssertEqual(resumed.observe(result(resumedTurn2, id: "res-r3", cost: "4.00")), .rejected(.disposedExecution))
        XCTAssertEqual(resumed.sessionCostEstimate?.amount, Decimal(string: "0.50"))
    }

    func testVerifiedResetWithOutstandingTurnRejectsCrossedMoneyButKeepsTokens() throws {
        // Earlier-dispatched A remains outstanding while later-dispatched B establishes the last
        // checkpoint. Reset closure must classify A as uncovered before its result arrives.
        var accumulator = makeQualified(baseline: .verifiedZero)
        let outstandingTurnID = UUID()
        accumulator.registerTurn(outstandingTurnID, executionID: execution)
        let paidTurnID = UUID()
        accumulator.registerTurn(paidTurnID, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(paidTurnID, id: "res-paid", cost: "1.00")), .accepted)
        XCTAssertEqual(accumulator.noteVerifiedReset(executionID: execution), .accepted)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments[0].coverage, .partial)

        XCTAssertEqual(
            accumulator.observe(result(
                outstandingTurnID,
                id: "res-crossed",
                input: 10,
                output: 2,
                read: 90,
                creation: 0,
                cost: "9.00"
            )),
            .acceptedWithMonetaryRejection(.crossedResetBoundary)
        )

        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        let crossedTurn = try XCTUnwrap(record.turns.first(where: { $0.turnID == outstandingTurnID }))
        XCTAssertEqual(crossedTurn.segmentIndex, 0, "the original turn is never reassigned across the reset")
        XCTAssertEqual(crossedTurn.acceptedResultID, "res-crossed")
        XCTAssertEqual(crossedTurn.inputTokens, 10)
        XCTAssertEqual(crossedTurn.outputTokens, 2)
        XCTAssertEqual(crossedTurn.cacheReadInputTokens, 90)
        XCTAssertEqual(crossedTurn.cacheCreationInputTokens, 0)
        XCTAssertEqual(crossedTurn.outcome, .completed)
        XCTAssertEqual(crossedTurn.coverage, .complete)
        XCTAssertEqual(crossedTurn.diagnostic, "monetary checkpoint rejected: crossedResetBoundary")

        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertEqual(record.claudeSegments[0].state, .closed)
        XCTAssertEqual(record.claudeSegments[0].coverage, .partial)
        XCTAssertEqual(record.claudeSegments[0].latestCumulative, decimal("1.00"))
        XCTAssertEqual(record.claudeSegments[0].acceptedResultID, "res-paid")
        XCTAssertEqual(record.claudeSegments[1].state, .open)
        XCTAssertEqual(record.claudeSegments[1].baseline, 0)
        XCTAssertNil(record.claudeSegments[1].latestCumulative)
        XCTAssertNil(record.claudeSegments[1].acceptedResultID)
        XCTAssertEqual(record.claudeSegments[1].acceptedResultOrder, 0)
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertNil(record.semanticViolation)

        accumulator.endExecution(execution, outcome: .completed)
        let closedRecord = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        XCTAssertEqual(closedRecord.claudeSegments[1].state, .closed)
        XCTAssertEqual(closedRecord.claudeSegments[1].coverage, .complete, "a reset segment with no dispatched work stays complete")
        XCTAssertNil(closedRecord.semanticViolation)
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))

        // The reset-time open-turn check also covers a later token-only result.
        var tokenOnly = makeQualified(baseline: .verifiedZero)
        let tokenOnlyOutstandingID = UUID()
        tokenOnly.registerTurn(tokenOnlyOutstandingID, executionID: execution)
        let tokenOnlyPaidID = UUID()
        tokenOnly.registerTurn(tokenOnlyPaidID, executionID: execution)
        XCTAssertEqual(tokenOnly.observe(result(tokenOnlyPaidID, id: "res-token-paid", cost: "1.00")), .accepted)
        XCTAssertEqual(tokenOnly.noteVerifiedReset(executionID: execution), .accepted)
        XCTAssertEqual(
            tokenOnly.observe(result(
                tokenOnlyOutstandingID,
                id: "res-token-only",
                input: 1,
                output: 1,
                read: 0,
                creation: 0
            )),
            .accepted
        )
        tokenOnly.endExecution(execution, outcome: .completed)
        XCTAssertEqual(tokenOnly.persistedRepresentation?.record?.claudeSegments[0].coverage, .partial)
        XCTAssertEqual(tokenOnly.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))

        // An outstanding turn interrupted after reset keeps the same partial classification.
        var interrupted = makeQualified(baseline: .verifiedZero)
        let interruptedOutstandingID = UUID()
        interrupted.registerTurn(interruptedOutstandingID, executionID: execution)
        let interruptedPaidID = UUID()
        interrupted.registerTurn(interruptedPaidID, executionID: execution)
        XCTAssertEqual(interrupted.observe(result(interruptedPaidID, id: "res-interrupted-paid", cost: "1.00")), .accepted)
        XCTAssertEqual(interrupted.noteVerifiedReset(executionID: execution), .accepted)
        XCTAssertEqual(interrupted.closeTurn(interruptedOutstandingID, outcome: .interrupted), .accepted)
        interrupted.endExecution(execution)
        XCTAssertEqual(interrupted.persistedRepresentation?.record?.claudeSegments[0].coverage, .partial)
        XCTAssertEqual(interrupted.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
    }

    func testInterruptedOrCostlessEndingsLeaveMonetaryCoveragePartialUntilCovered() {
        // Interrupted ending: accepted spend preserved, uncovered dispatched work makes coverage partial.
        var interrupted = makeQualified(baseline: .verifiedZero)
        let paidTurn = UUID()
        interrupted.registerTurn(paidTurn, executionID: execution)
        XCTAssertEqual(interrupted.observe(result(paidTurn, id: "res-1", cost: "1.00")), .accepted)
        XCTAssertEqual(interrupted.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .complete))
        interrupted.registerTurn(UUID(), executionID: execution)
        interrupted.endExecution(execution)
        let interruptedSegment = interrupted.persistedRepresentation?.record?.claudeSegments.first
        XCTAssertEqual(interruptedSegment?.state, .closed)
        XCTAssertEqual(interruptedSegment?.coverage, .partial)
        XCTAssertEqual(interruptedSegment?.latestCumulative, decimal("1.00"))
        XCTAssertEqual(interrupted.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))

        // Token-only final result after the last checkpoint: the money for that turn is unmeasured.
        var costless = makeQualified(baseline: .verifiedZero)
        let firstTurn = UUID()
        costless.registerTurn(firstTurn, executionID: execution)
        XCTAssertEqual(costless.observe(result(firstTurn, id: "res-1", cost: "1.00")), .accepted)
        let tokenOnlyTurn = UUID()
        costless.registerTurn(tokenOnlyTurn, executionID: execution)
        XCTAssertEqual(costless.observe(result(tokenOnlyTurn, id: "res-2", input: 10, output: 1, read: 90, creation: 0)), .accepted)
        costless.endExecution(execution, outcome: .completed)
        XCTAssertEqual(costless.persistedRepresentation?.record?.claudeSegments.first?.coverage, .partial)
        XCTAssertEqual(costless.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertEqual(costless.cacheHitShare?.ratio, decimal("0.9"), "token contract is independent of money coverage")

        // A later cumulative checkpoint covers the earlier gap before the segment closes.
        var covered = makeQualified(baseline: .verifiedZero)
        let turnA = UUID()
        covered.registerTurn(turnA, executionID: execution)
        XCTAssertEqual(covered.observe(result(turnA, id: "res-1", cost: "1.00")), .accepted)
        let turnB = UUID()
        covered.registerTurn(turnB, executionID: execution)
        XCTAssertEqual(covered.observe(result(turnB, id: "res-2", input: 1, output: 1)), .accepted)
        let turnC = UUID()
        covered.registerTurn(turnC, executionID: execution)
        XCTAssertEqual(covered.observe(result(turnC, id: "res-3", cost: "1.40")), .accepted)
        covered.endExecution(execution, outcome: .completed)
        XCTAssertEqual(covered.persistedRepresentation?.record?.claudeSegments.first?.coverage, .complete)
        XCTAssertEqual(covered.sessionCostEstimate, .init(amount: decimal("1.40"), currency: "USD", coverage: .complete))

        // No dispatched work at all leaves a verified-zero segment trivially complete.
        var idle = makeQualified(baseline: .verifiedZero)
        idle.endExecution(execution)
        XCTAssertEqual(idle.persistedRepresentation?.record?.claudeSegments.first?.coverage, .complete)
        XCTAssertNil(idle.sessionCostEstimate)
    }

    func testMonetaryRejectionStillFinalizesTokensAndRecordsResultIdentity() {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn1 = UUID()
        accumulator.registerTurn(turn1, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn1, id: "res-1", input: 10, output: 1, read: 90, creation: 0, cost: "1.00")), .accepted)

        // Unexplained decrease: money rejected, tokens and identity accepted.
        let turn2 = UUID()
        accumulator.registerTurn(turn2, executionID: execution)
        XCTAssertEqual(
            accumulator.observe(result(turn2, id: "res-2", input: 900, output: 1, read: 0, creation: 0, cost: "0.50")),
            .acceptedWithMonetaryRejection(.unexplainedDecrease)
        )
        let decreasedTurn = accumulator.persistedRepresentation?.record?.turns.last
        XCTAssertEqual(decreasedTurn?.outcome, .completed)
        XCTAssertEqual(decreasedTurn?.acceptedResultID, "res-2")
        XCTAssertEqual(decreasedTurn?.inputTokens, 900)
        XCTAssertEqual(decreasedTurn?.coverage, .complete)
        XCTAssertEqual(decreasedTurn?.diagnostic, "monetary checkpoint rejected: unexplainedDecrease")
        XCTAssertEqual(accumulator.observe(result(turn2, id: "res-2", cost: "0.50")), .rejected(.duplicateResult), "re-delivery stays detectable")
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertEqual(accumulator.cacheHitShare, .init(ratio: decimal("0.09"), coverage: .complete), "CH keeps counting after suspension")

        // Suspended segment: subsequent priced and unpriced results are treated alike for tokens.
        let turn3 = UUID()
        accumulator.registerTurn(turn3, executionID: execution)
        XCTAssertEqual(
            accumulator.observe(result(turn3, id: "res-3", input: 100, output: 1, read: 0, creation: 0, cost: "2.00")),
            .acceptedWithMonetaryRejection(.segmentSuspended)
        )
        let turn4 = UUID()
        accumulator.registerTurn(turn4, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(turn4, id: "res-4", input: 100, output: 1, read: 0, creation: 0)), .accepted)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.count(where: { $0.outcome == .completed }), 4)
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, decimal("1.00"))

        // Invalid (negative) cost: same decoupling.
        let turn5 = UUID()
        accumulator.registerTurn(turn5, executionID: execution)
        var negative = result(turn5, id: "res-5", input: 1, output: 1, read: 0, creation: 0, cost: "1.00")
        negative.reportedCost = -1
        XCTAssertEqual(accumulator.observe(negative), .acceptedWithMonetaryRejection(.invalidCost))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.last?.acceptedResultID, "res-5")
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, decimal("1.00"))
    }

    func testCrashRestoredOpenStateIsRetiredOnlyUnderQualificationWithScopedSegmentLookup() throws {
        // Persist mid-execution: one accepted checkpoint, one turn still open, segment still open.
        var live = makeQualified(baseline: .verifiedZero)
        let paidTurn = UUID()
        live.registerTurn(paidTurn, executionID: execution)
        XCTAssertEqual(live.observe(result(paidTurn, id: "res-1", cost: "1.00")), .accepted)
        let openTurn = UUID()
        live.registerTurn(openTurn, executionID: execution)
        XCTAssertEqual(live.observe(request(openTurn, .messageStart, requestID: "r-open", input: 40, read: 60, creation: 0)), .accepted)
        let persisted = try XCTUnwrap(live.persistedRepresentation)
        XCTAssertEqual(persisted.record?.turns.last?.outcome, .open)
        XCTAssertEqual(persisted.record?.claudeSegments.first?.state, .open)

        // Unqualified (production) hydration returns the persisted value exactly as loaded.
        let production = AgentUsageAccumulator(ownerSessionID: owner, persisted: persisted, hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(production.persistedRepresentation, persisted)

        // Qualified hydration retires the abandoned state as explicitly incomplete, keeping amounts.
        var restored = AgentUsageAccumulator(ownerSessionID: owner, persisted: persisted, hasPriorHistory: true, qualification: qualified)
        let restoredTurn = restored.persistedRepresentation?.record?.turns.last
        XCTAssertEqual(restoredTurn?.outcome, .interrupted)
        XCTAssertEqual(restoredTurn?.coverage, .partial)
        XCTAssertEqual(restoredTurn?.diagnostic, AgentUsageAccumulator.restoredWithoutTerminalResultDiagnostic)
        XCTAssertNil(restoredTurn?.inputTokens, "in-memory snapshots are not persisted and cannot be reconstructed")
        let restoredSegment = restored.persistedRepresentation?.record?.claudeSegments.first
        XCTAssertEqual(restoredSegment?.state, .closed)
        XCTAssertEqual(restoredSegment?.coverage, .partial)
        XCTAssertEqual(restoredSegment?.latestCumulative, decimal("1.00"))
        XCTAssertEqual(restoredSegment?.acceptedResultID, "res-1")
        XCTAssertEqual(restored.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertEqual(restored.ownedRevision, 0, "hydration normalization is not an owned mutation")
        var lateHydration = restored
        XCTAssertTrue(lateHydration.applyHydration(nil, hasPriorHistory: false))

        // A new execution never reaches the restored segment, even after its own segment suspends.
        let reopened = UUID()
        restored.beginExecution(executionID: reopened, providerSessionID: "ps-2", baseline: .verifiedZero, at: start)
        let turnA = UUID()
        restored.registerTurn(turnA, executionID: reopened)
        var first = result(turnA, id: "res-2", cost: "0.30")
        first.executionID = reopened
        XCTAssertEqual(restored.observe(first), .accepted)
        XCTAssertEqual(restored.sessionCostEstimate, .init(amount: decimal("1.30"), currency: "USD", coverage: .partial))
        let turnB = UUID()
        restored.registerTurn(turnB, executionID: reopened)
        var decrease = result(turnB, id: "res-3", cost: "0.10")
        decrease.executionID = reopened
        XCTAssertEqual(restored.observe(decrease), .acceptedWithMonetaryRejection(.unexplainedDecrease))
        let turnC = UUID()
        restored.registerTurn(turnC, executionID: reopened)
        var afterSuspension = result(turnC, id: "res-4", cost: "0.40")
        afterSuspension.executionID = reopened
        XCTAssertEqual(restored.observe(afterSuspension), .acceptedWithMonetaryRejection(.segmentSuspended))
        let segments = try XCTUnwrap(restored.persistedRepresentation?.record?.claudeSegments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].latestCumulative, decimal("1.00"), "restored segment untouched")
        XCTAssertEqual(segments[0].acceptedResultID, "res-1")
        XCTAssertEqual(segments[0].state, .closed)
        XCTAssertEqual(segments[1].state, .suspended)
        XCTAssertEqual(segments[1].latestCumulative, decimal("0.30"))
        XCTAssertEqual(restored.sessionCostEstimate, .init(amount: decimal("1.30"), currency: "USD", coverage: .partial))
        XCTAssertEqual(restored.persistedRepresentation?.record?.turns.count(where: { $0.outcome == .open }), 0)
    }

    func testFallbackSubtotalsCannotManufactureCacheTriplesFromMissingComponents() {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn = UUID()
        accumulator.registerTurn(turn, executionID: execution)
        XCTAssertEqual(accumulator.observe(request(turn, .messageStart, requestID: "r1", input: 10, read: 90, creation: 0)), .accepted)
        XCTAssertEqual(accumulator.observe(request(turn, .messageStart, requestID: "r2", input: 900)), .accepted)
        XCTAssertEqual(accumulator.closeTurn(turn, outcome: .interrupted), .accepted)
        let closed = accumulator.persistedRepresentation?.record?.turns.first
        XCTAssertEqual(closed?.inputTokens, 910)
        XCTAssertNil(closed?.cacheReadInputTokens, "a contributor without cache counts makes the component unavailable")
        XCTAssertNil(closed?.cacheCreationInputTokens)
        XCTAssertEqual(closed?.observedRequestCount, 2)
        XCTAssertNil(accumulator.cacheHitShare, "no 9% from an incomplete population")

        // Complementary missing fields cannot combine into a triple either.
        var complementary = makeQualified(baseline: .verifiedZero)
        let turn2 = UUID()
        complementary.registerTurn(turn2, executionID: execution)
        XCTAssertEqual(complementary.observe(request(turn2, .messageStart, requestID: "a", input: 10, read: 90)), .accepted)
        XCTAssertEqual(complementary.observe(request(turn2, .messageStart, requestID: "b", input: 10, creation: 0)), .accepted)
        XCTAssertEqual(complementary.observe(result(turn2, id: "res-1", cost: "0.10")), .accepted)
        let costOnly = complementary.persistedRepresentation?.record?.turns.first
        XCTAssertEqual(costOnly?.inputTokens, 20)
        XCTAssertNil(costOnly?.cacheReadInputTokens)
        XCTAssertNil(costOnly?.cacheCreationInputTokens)
        XCTAssertNil(complementary.cacheHitShare)

        // Fully reported requests still yield a fallback subtotal and a partial ratio.
        var complete = makeQualified(baseline: .verifiedZero)
        let turn3 = UUID()
        complete.registerTurn(turn3, executionID: execution)
        XCTAssertEqual(complete.observe(request(turn3, .messageStart, requestID: "a", input: 10, read: 90, creation: 0)), .accepted)
        XCTAssertEqual(complete.observe(request(turn3, .messageStart, requestID: "b", input: 900, read: 0, creation: 0)), .accepted)
        XCTAssertEqual(complete.closeTurn(turn3, outcome: .interrupted), .accepted)
        XCTAssertEqual(complete.cacheHitShare, .init(ratio: decimal("0.09"), coverage: .partial))
    }

    func testIdempotentRegistrationHydrationIdentityResetAndTinyExactCost() throws {
        // Re-registering a turn keeps its summary and in-flight snapshots.
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)
        XCTAssertEqual(accumulator.observe(request(turn, .messageStart, requestID: "r1", input: 5, read: 5, creation: 5)), .accepted)
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.count, 1)
        XCTAssertEqual(accumulator.observe(result(turn, id: "res-1", cost: "0.10")), .accepted)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.first?.observedRequestCount, 1)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.first?.inputTokens, 5)
        accumulator.endExecution(execution, outcome: .completed)
        let persisted = try XCTUnwrap(accumulator.persistedRepresentation)

        // Re-hydrating with a different history forgets the previous accepted identities and resets.
        var rehydrated = AgentUsageAccumulator(ownerSessionID: owner, persisted: persisted, hasPriorHistory: true, qualification: qualified)
        XCTAssertTrue(rehydrated.applyHydration(nil, hasPriorHistory: false))
        XCTAssertNil(rehydrated.persistedRepresentation)
        rehydrated.beginExecution(executionID: execution, providerSessionID: nil, baseline: .verifiedZero, at: start)
        let freshTurn = UUID()
        rehydrated.registerTurn(freshTurn, executionID: execution)
        XCTAssertEqual(rehydrated.observe(result(freshTurn, id: "res-1", cost: "0.20")), .accepted, "old result ids no longer count as duplicates")
        XCTAssertEqual(rehydrated.persistedRepresentation?.record?.claudeSegments.first?.resetGeneration, 0)

        // Ordinary exponent spellings and genuine zero remain exact and available.
        XCTAssertEqual(AgentUsageObservationInput.exactCost(fromReported: 0.00001), decimal("0.00001"))
        XCTAssertEqual(AgentUsageObservationInput.exactCost(fromReported: 1e20), decimal("100000000000000000000"))
        XCTAssertEqual(AgentUsageObservationInput.exactCost(fromReported: 0), 0)
    }

    func testExactCostRejectsUnrepresentableShortestRoundTripValues() {
        // Decimal construction must not turn underflow, overflow, or boundary rounding into a value.
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: 1e-129))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: 1e-200))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: 1e200))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: 1.1e-128))

        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: .nan))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: .infinity))
        XCTAssertNil(AgentUsageObservationInput.exactCost(fromReported: -.infinity))
    }

    func testUnrepresentableReportedCostDoesNotDiscardTokensOrBecomeMeasuredZero() throws {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)

        var underflowed = result(
            turn,
            id: "res-underflow",
            input: 10,
            output: 1,
            read: 90,
            creation: 0
        )
        underflowed.reportedCost = AgentUsageObservationInput.exactCost(fromReported: 1e-129)
        XCTAssertNil(underflowed.reportedCost)
        XCTAssertEqual(accumulator.observe(underflowed), .accepted)

        let completed = try XCTUnwrap(accumulator.persistedRepresentation?.record?.turns.first)
        XCTAssertEqual(completed.acceptedResultID, "res-underflow")
        XCTAssertEqual(completed.inputTokens, 10)
        XCTAssertEqual(completed.outputTokens, 1)
        XCTAssertEqual(completed.cacheReadInputTokens, 90)
        XCTAssertEqual(completed.cacheCreationInputTokens, 0)
        XCTAssertEqual(completed.coverage, .complete)
        XCTAssertEqual(accumulator.cacheHitShare, .init(ratio: decimal("0.9"), coverage: .complete))
        XCTAssertNil(accumulator.sessionCostEstimate, "unavailable cost must not become measured zero")
        XCTAssertNil(accumulator.persistedRepresentation?.record?.claudeSegments.first?.latestCumulative)

        accumulator.endExecution(execution, outcome: .completed)
        let segment = try XCTUnwrap(accumulator.persistedRepresentation?.record?.claudeSegments.first)
        XCTAssertEqual(segment.state, .closed)
        XCTAssertEqual(segment.coverage, .partial)
        XCTAssertNil(segment.latestCumulative)
        XCTAssertNil(accumulator.sessionCostEstimate)
    }

    // MARK: - Execution verdicts (deny by default, authorize each execution)

    func testExecutionVerifiedPolicyMaterializesOnlyAfterQualifiedVerdictAndBackfillsDispatchOrder() throws {
        var accumulator = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .executionVerified)
        accumulator.beginAwaitingExecution(executionID: execution, providerSessionID: "ps", at: start)
        XCTAssertEqual(accumulator.executionVerdict, .awaiting)
        XCTAssertEqual(accumulator.executionQualificationDiagnostic, "the runtime has not reported its version yet")
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(accumulator.registerTurn(first, executionID: execution), .accepted)
        XCTAssertEqual(accumulator.registerTurn(second, executionID: execution), .accepted)
        XCTAssertEqual(accumulator.registerTurn(first, executionID: execution), .accepted, "re-registration is idempotent")
        XCTAssertNil(accumulator.persistedRepresentation, "awaiting executions never materialize a record")
        XCTAssertTrue(accumulator.hasUnchargedDispatchedWork)
        // Snapshot observations are rejected but do not block; only a result before qualification blocks.
        XCTAssertEqual(accumulator.observe(request(first, .messageStart, requestID: "r1", input: 1)), .rejected(.executionNotQualified))
        XCTAssertEqual(accumulator.executionVerdict, .awaiting)

        XCTAssertEqual(
            accumulator.resolveExecutionQualification(
                executionID: execution,
                verdict: .qualified(contractID: "c@2.1.268", baseline: .verifiedZero),
                at: start
            ),
            .accepted
        )
        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.map(\.turnID), [first, second], "backfill preserves dispatch order")
        XCTAssertTrue(record.turns.allSatisfy { $0.outcome == .open && $0.segmentIndex == 0 })
        XCTAssertEqual(record.claudeSegments.first?.contractID, "c@2.1.268")
        XCTAssertEqual(record.claudeSegments.first?.baseline, 0)
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertFalse(accumulator.hasUnchargedDispatchedWork)
        XCTAssertNil(accumulator.executionQualificationDiagnostic)
        XCTAssertEqual(accumulator.resolveExecutionQualification(executionID: execution, verdict: .awaiting, at: start), .accepted)
        XCTAssertEqual(accumulator.resolveExecutionQualification(executionID: UUID(), verdict: .awaiting, at: start), .rejected(.disposedExecution))

        XCTAssertEqual(accumulator.observe(result(first, id: "res-1", input: 10, output: 1, read: 90, creation: 0, cost: "0.50")), .accepted)
        XCTAssertEqual(accumulator.observe(result(second, id: "res-2", input: 10, output: 1, read: 90, creation: 0, cost: "0.75")), .accepted)
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("0.75"), currency: "USD", coverage: .complete))
        XCTAssertEqual(accumulator.cacheHitShare, .init(ratio: decimal("0.9"), coverage: .complete))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.first?.contractID, "c@2.1.268")
    }

    func testResultBeforeQualificationBlocksTheLaunchWithoutBufferingOrCharging() {
        var accumulator = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .executionVerified)
        accumulator.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        let turn = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)
        XCTAssertEqual(accumulator.observe(result(turn, id: "early", cost: "1.00")), .rejected(.executionNotQualified))
        XCTAssertEqual(accumulator.executionVerdict, .blocked(.resultBeforeQualification))
        XCTAssertEqual(
            accumulator.resolveExecutionQualification(
                executionID: execution,
                verdict: .qualified(contractID: "c", baseline: .verifiedZero),
                at: start
            ),
            .rejected(.executionBlocked),
            "a blocked verdict is never lifted"
        )
        XCTAssertEqual(accumulator.observe(result(turn, id: "early", cost: "1.00")), .rejected(.executionBlocked))
        XCTAssertNil(accumulator.persistedRepresentation, "blocked executions never create an apparent record")
        XCTAssertNil(accumulator.sessionCostEstimate)
        accumulator.endExecution(execution)
        XCTAssertNil(accumulator.executionVerdict)
        XCTAssertNil(accumulator.persistedRepresentation)
    }

    func testBlockingAQualifiedExecutionSuspendsItsSegmentPreservesAmountsAndRejectsLaterInput() throws {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let charged = UUID()
        let pending = UUID()
        accumulator.registerTurn(charged, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(charged, id: "res-1", input: 10, output: 1, read: 90, creation: 0, cost: "1.00")), .accepted)
        accumulator.registerTurn(pending, executionID: execution)

        XCTAssertEqual(
            accumulator.resolveExecutionQualification(
                executionID: execution,
                verdict: .blocked(.unsupportedCounterBoundary("compact_boundary")),
                at: start
            ),
            .rejected(.executionBlocked)
        )
        let segment = try XCTUnwrap(accumulator.persistedRepresentation?.record?.claudeSegments.first)
        XCTAssertEqual(segment.state, .suspended)
        XCTAssertEqual(segment.coverage, .partial)
        XCTAssertEqual(segment.latestCumulative, decimal("1.00"))
        XCTAssertEqual(segment.acceptedResultID, "res-1")
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertEqual(accumulator.executionQualificationDiagnostic, "an unqualified counter boundary occurred (compact_boundary)")
        XCTAssertTrue(accumulator.hasUnchargedDispatchedWork)

        XCTAssertEqual(accumulator.observe(result(pending, id: "res-2", cost: "1.50")), .rejected(.executionBlocked))
        XCTAssertEqual(accumulator.registerTurn(UUID(), executionID: execution), .rejected(.executionBlocked))
        XCTAssertEqual(accumulator.noteVerifiedReset(executionID: execution), .rejected(.executionBlocked))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.hasUnmeasuredHistory, true)
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.claudeSegments.first?.latestCumulative, decimal("1.00"))

        accumulator.endExecution(execution)
        let closed = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        XCTAssertEqual(closed.turns.last?.outcome, .interrupted)
        XCTAssertEqual(closed.turns.last?.coverage, .partial)
        XCTAssertEqual(closed.claudeSegments.first?.state, .suspended, "a suspended segment stays suspended, its amount intact")
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, decimal("1.00"))
    }

    func testOriginalCancellationResultFinalizesTurnAsInterruptedWhileKeepingTotalsAndCheckpoint() throws {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn = UUID()
        accumulator.registerTurn(turn, executionID: execution)
        var cancelled = result(turn, id: "abort-1", input: 10, output: 0, read: 90, creation: 0, cost: "0.30")
        cancelled.observation = .init(
            source: .result, inputTokens: 10, outputTokens: 0, cacheReadInputTokens: 90, cacheCreationInputTokens: 0,
            envelopeID: "abort-1", resultSubtype: "error_during_execution", resultIsError: true, resultIndex: 0, queuedTurnCount: 0
        )
        cancelled.terminalOutcome = .interrupted
        XCTAssertEqual(accumulator.observe(cancelled), .accepted)
        let summary = try XCTUnwrap(accumulator.persistedRepresentation?.record?.turns.first)
        XCTAssertEqual(summary.outcome, .interrupted)
        XCTAssertEqual(summary.acceptedResultID, "abort-1")
        XCTAssertEqual(summary.cacheReadInputTokens, 90)
        XCTAssertEqual(summary.coverage, .complete)
        XCTAssertEqual(summary.diagnostic, "original result reported error_during_execution")
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("0.30"), currency: "USD", coverage: .complete))
        // A later closeTurn from the completion lifecycle finds the turn already finalized.
        XCTAssertEqual(accumulator.closeTurn(turn, outcome: .interrupted), .rejected(.unregisteredTurn))
        XCTAssertEqual(accumulator.persistedRepresentation?.record?.turns.first?.outcome, .interrupted)
        // Duplicate delivery of the same original result never charges again.
        XCTAssertEqual(accumulator.observe(cancelled), .rejected(.duplicateResult))
    }

    func testUnqualifiedPolicyKeepsVerdictMachineryInert() throws {
        var production = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .unqualified)
        production.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        XCTAssertEqual(production.executionVerdict, .blocked(.unqualifiedContract))
        XCTAssertEqual(
            production.resolveExecutionQualification(
                executionID: execution,
                verdict: .qualified(contractID: "never", baseline: .verifiedZero),
                at: start
            ),
            .rejected(.unqualifiedContract)
        )
        XCTAssertEqual(production.registerTurn(UUID(), executionID: execution), .rejected(.unqualifiedContract))
        XCTAssertNil(production.persistedRepresentation)
        XCTAssertEqual(production.executionQualificationDiagnostic, "live accounting is not qualified for this build")
        XCTAssertFalse(production.hasUnchargedDispatchedWork)

        // An owned, valid restored record with complete coverage: dispatch, result, closure and
        // launch end under the unqualified policy leave its representation and revision untouched,
        // so the restored figures stay visible (as partial) instead of disappearing.
        var restored = AgentProviderUsageRecord(originSessionID: owner, trackingStartedAt: start, hasUnmeasuredHistory: false)
        let completedTurn = UUID()
        let oldExecution = UUID()
        restored.turns = [
            .init(
                executionID: oldExecution,
                segmentIndex: 0,
                turnID: completedTurn,
                acceptedResultID: "old-1",
                inputTokens: 10,
                outputTokens: 1,
                cacheReadInputTokens: 90,
                cacheCreationInputTokens: 0,
                outcome: .completed,
                coverage: .complete
            )
        ]
        restored.claudeSegments = [
            .init(
                contractID: "old",
                provider: "claude",
                providerSessionID: nil,
                executionID: oldExecution,
                resetGeneration: 0,
                baseline: 0,
                latestCumulative: decimal("0.40"),
                currency: "USD",
                acceptedResultID: "old-1",
                acceptedResultOrder: 1,
                state: .closed,
                coverage: .complete
            )
        ]
        var gated = AgentUsageAccumulator(ownerSessionID: owner, persisted: .record(restored), hasPriorHistory: false, qualification: .unqualified)
        XCTAssertEqual(gated.eligibility, .eligible)
        gated.beginAwaitingExecution(executionID: execution, providerSessionID: "ps", at: start)
        let turn = UUID()
        XCTAssertEqual(gated.registerTurn(turn, executionID: execution), .rejected(.unqualifiedContract))
        XCTAssertEqual(gated.observe(result(turn, id: "live", input: 1, output: 1, read: 1, creation: 0, cost: "9")), .rejected(.unqualifiedContract))
        XCTAssertEqual(gated.closeTurn(turn, outcome: .completed), .rejected(.unregisteredTurn))
        gated.endExecution(execution)
        XCTAssertEqual(gated.ownedRevision, 0)
        XCTAssertEqual(gated.persistedRepresentation, .record(restored))
        XCTAssertEqual(gated.persistedRepresentation?.record?.hasUnmeasuredHistory, false)
        XCTAssertEqual(gated.sessionCostEstimate?.amount, decimal("0.40"))
        XCTAssertEqual(try XCTUnwrap(gated.cacheHitShare).ratio, decimal("0.9"))
    }

    /// OracleB P1#5: a turn dispatched while the execution is still awaiting its verdict and then
    /// closed (interrupt/crash), or an execution that ends while awaiting with dispatches
    /// outstanding, can never be measured. An owned record must say so (`hasUnmeasuredHistory`)
    /// instead of keeping complete coverage; a session without a record materializes nothing.
    func testAwaitingExecutionClosureOrEndWithDispatchesMarksUnmeasuredHistory() {
        let oldExecution = UUID()
        let completedTurn = UUID()
        var restored = AgentProviderUsageRecord(originSessionID: owner, trackingStartedAt: start, hasUnmeasuredHistory: false)
        restored.turns = [
            .init(
                executionID: oldExecution, segmentIndex: 0, turnID: completedTurn, acceptedResultID: "old-1",
                inputTokens: 10, outputTokens: 1, cacheReadInputTokens: 90, cacheCreationInputTokens: 0,
                outcome: .completed, coverage: .complete
            )
        ]
        restored.claudeSegments = [
            .init(
                contractID: "old", provider: "claude", providerSessionID: nil, executionID: oldExecution, resetGeneration: 0,
                baseline: 0, latestCumulative: decimal("0.40"), currency: "USD", acceptedResultID: "old-1",
                acceptedResultOrder: 1, state: .closed, coverage: .complete
            )
        ]

        // Closed while awaiting.
        var closedWhileAwaiting = AgentUsageAccumulator(ownerSessionID: owner, persisted: .record(restored), hasPriorHistory: true, qualification: .executionVerified)
        closedWhileAwaiting.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        let interrupted = UUID()
        XCTAssertEqual(closedWhileAwaiting.registerTurn(interrupted, executionID: execution), .accepted)
        XCTAssertEqual(closedWhileAwaiting.cacheHitShare?.coverage, .complete)
        XCTAssertEqual(closedWhileAwaiting.closeTurn(interrupted, outcome: .interrupted), .rejected(.executionNotQualified))
        XCTAssertEqual(closedWhileAwaiting.persistedRepresentation?.record?.hasUnmeasuredHistory, true)
        XCTAssertEqual(closedWhileAwaiting.ownedRevision, 1)
        XCTAssertEqual(closedWhileAwaiting.cacheHitShare?.coverage, .partial)
        XCTAssertEqual(closedWhileAwaiting.sessionCostEstimate?.coverage, .partial)
        XCTAssertEqual(closedWhileAwaiting.sessionCostEstimate?.amount, decimal("0.40"), "accepted amounts are never touched")
        // A later verdict cannot resurrect the closed dispatch.
        XCTAssertEqual(
            closedWhileAwaiting.resolveExecutionQualification(executionID: execution, verdict: .qualified(contractID: "c", baseline: .verifiedZero), at: start),
            .accepted
        )
        XCTAssertFalse(closedWhileAwaiting.persistedRepresentation?.record?.turns.contains { $0.turnID == interrupted } ?? true)

        // Ended while awaiting with an outstanding dispatch.
        var endedWhileAwaiting = AgentUsageAccumulator(ownerSessionID: owner, persisted: .record(restored), hasPriorHistory: true, qualification: .executionVerified)
        endedWhileAwaiting.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        XCTAssertEqual(endedWhileAwaiting.registerTurn(UUID(), executionID: execution), .accepted)
        endedWhileAwaiting.endExecution(execution)
        XCTAssertNil(endedWhileAwaiting.activeExecutionID)
        XCTAssertEqual(endedWhileAwaiting.persistedRepresentation?.record?.hasUnmeasuredHistory, true)
        XCTAssertEqual(endedWhileAwaiting.cacheHitShare?.coverage, .partial)

        // Ended while awaiting without any dispatch: nothing was uncovered.
        var idle = AgentUsageAccumulator(ownerSessionID: owner, persisted: .record(restored), hasPriorHistory: true, qualification: .executionVerified)
        idle.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        idle.endExecution(execution)
        XCTAssertEqual(idle.persistedRepresentation?.record?.hasUnmeasuredHistory, false)
        XCTAssertEqual(idle.ownedRevision, 0)

        // No record: nothing to mark, nothing materialized.
        var empty = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .executionVerified)
        empty.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        let pending = UUID()
        XCTAssertEqual(empty.registerTurn(pending, executionID: execution), .accepted)
        XCTAssertEqual(empty.closeTurn(pending, outcome: .interrupted), .rejected(.executionNotQualified))
        empty.endExecution(execution)
        XCTAssertNil(empty.persistedRepresentation)
        XCTAssertEqual(empty.ownedRevision, 0)
    }

    func testClosingATurnOnABlockedExecutionRetiresItsSummaryWithoutAcceptingUsage() throws {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let charged = UUID()
        let pending = UUID()
        accumulator.registerTurn(charged, executionID: execution)
        XCTAssertEqual(accumulator.observe(result(charged, id: "res-1", input: 10, output: 1, read: 90, creation: 0, cost: "1.00")), .accepted)
        accumulator.registerTurn(pending, executionID: execution)
        XCTAssertEqual(
            accumulator.resolveExecutionQualification(
                executionID: execution,
                verdict: .blocked(.unsupportedQueueSemantics("queued_turn_count 1 exceeds qualified bound 0")),
                at: start
            ),
            .rejected(.executionBlocked)
        )
        // Ordinary completion after the block: lifecycle retirement only, no usage accepted.
        XCTAssertEqual(accumulator.observe(result(pending, id: "res-2", cost: "1.50")), .rejected(.executionBlocked))
        XCTAssertEqual(accumulator.closeTurn(pending, outcome: .completed), .accepted)
        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertFalse(record.turns.contains { $0.outcome == .open }, "no summary may be stranded open")
        let retired = try XCTUnwrap(record.turns.last)
        XCTAssertEqual(retired.turnID, pending)
        XCTAssertEqual(retired.outcome, .completed)
        XCTAssertEqual(retired.coverage, .partial)
        XCTAssertNil(retired.acceptedResultID)
        XCTAssertEqual(record.claudeSegments.first?.state, .suspended)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, decimal("1.00"))
        XCTAssertEqual(accumulator.sessionCostEstimate, .init(amount: decimal("1.00"), currency: "USD", coverage: .partial))
        XCTAssertEqual(accumulator.cacheHitShare?.coverage, .partial, "omitted work keeps coverage partial")
        accumulator.endExecution(execution)
        XCTAssertFalse(try XCTUnwrap(accumulator.persistedRepresentation?.record).turns.contains { $0.outcome == .open })
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, decimal("1.00"))
    }

    func testExecutionVerifiedRejectsRequestScopeObservationsAsUnsupported() {
        var accumulator = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: .executionVerified)
        accumulator.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        XCTAssertEqual(
            accumulator.resolveExecutionQualification(executionID: execution, verdict: .qualified(contractID: "c", baseline: .verifiedZero), at: start),
            .accepted
        )
        let turn = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)
        // Production-shaped accounting is result-only: request snapshots are quarantined to the
        // test-only `.qualified` fixture and never attributed to a dispatch.
        XCTAssertEqual(accumulator.observe(request(turn, .messageStart, requestID: "r1", input: 100, read: 50)), .rejected(.requestScopeUnsupported))
        XCTAssertEqual(accumulator.observe(request(turn, .assistant, requestID: "r2", input: 5)), .rejected(.requestScopeUnsupported))
        XCTAssertEqual(accumulator.closeTurn(turn, outcome: .interrupted), .accepted)
        let closed = accumulator.persistedRepresentation?.record?.turns.first
        XCTAssertNil(closed?.inputTokens, "no request-derived subtotal exists in production-shaped accounting")
        XCTAssertNil(closed?.observedRequestCount)
        XCTAssertEqual(closed?.coverage, .partial)
    }

    func testExecutionVerifiedHydrationRetiresAbandonedStateOnlyAtFirstOwnedMaterialization() throws {
        let oldExecution = UUID()
        let openTurn = UUID()
        var hydrated = AgentProviderUsageRecord(originSessionID: owner, trackingStartedAt: start, hasUnmeasuredHistory: false)
        hydrated.claudeSegments = [
            .init(
                contractID: "old", provider: "claude", providerSessionID: nil, executionID: oldExecution, resetGeneration: 0,
                baseline: 0, latestCumulative: decimal("0.40"), currency: "USD", acceptedResultID: "old-res",
                acceptedResultOrder: 1, state: .open, coverage: .complete
            )
        ]
        hydrated.turns = [
            .init(executionID: oldExecution, segmentIndex: 0, turnID: openTurn, outcome: .open, coverage: .unavailable)
        ]
        var accumulator = AgentUsageAccumulator(ownerSessionID: owner, persisted: .record(hydrated), hasPriorHistory: false, qualification: .executionVerified)
        XCTAssertEqual(accumulator.persistedRepresentation, .record(hydrated), "hydrated bytes stay authoritative without owned mutation")
        accumulator.beginAwaitingExecution(executionID: execution, providerSessionID: nil, at: start)
        XCTAssertEqual(accumulator.persistedRepresentation, .record(hydrated), "an awaiting execution does not rewrite hydrated state")

        XCTAssertEqual(
            accumulator.resolveExecutionQualification(
                executionID: execution,
                verdict: .qualified(contractID: "new", baseline: .verifiedZero),
                at: start
            ),
            .accepted
        )
        let record = try XCTUnwrap(accumulator.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.first?.outcome, .interrupted)
        XCTAssertEqual(record.turns.first?.coverage, .partial)
        XCTAssertEqual(record.turns.first?.diagnostic, AgentUsageAccumulator.restoredWithoutTerminalResultDiagnostic)
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .partial)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, decimal("0.40"), "accepted amounts are never changed")
        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertEqual(record.claudeSegments.last?.contractID, "new")
        XCTAssertEqual(record.claudeSegments.last?.state, .open)
    }

    func testLatestClaudeRequestUsesAssistantUsageWithoutChangingSessionLedgerAndClearsAtBoundaries() throws {
        var accumulator = makeQualified(baseline: .verifiedZero)
        let turn = UUID()
        XCTAssertEqual(accumulator.registerTurn(turn, executionID: execution), .accepted)

        let firstRequest = AgentProviderUsageObservation(
            source: .assistant,
            inputTokens: 10,
            outputTokens: 1,
            cacheReadInputTokens: 90,
            cacheCreationInputTokens: 0,
            requestID: "msg-1"
        )
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: firstRequest,
                requestID: "msg-1",
                executionID: execution,
                turnID: turn
            ),
            .accepted
        )
        XCTAssertEqual(
            accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio,
            decimal("0.9")
        )

        // A second main-loop API request in the same tool-loop turn replaces, rather than adds to,
        // the latest-request readout. The result remains the separate turn/session authority.
        let secondRequest = AgentProviderUsageObservation(
            source: .assistant,
            inputTokens: 100,
            outputTokens: 1,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            requestID: "msg-2"
        )
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: secondRequest,
                requestID: "msg-2",
                executionID: execution,
                turnID: turn
            ),
            .accepted
        )
        XCTAssertEqual(accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, 0)
        XCTAssertEqual(
            accumulator.observe(result(
                turn,
                id: "result-1",
                input: 50,
                output: 5,
                read: 50,
                creation: 0,
                cost: "2.00"
            )),
            .accepted
        )
        XCTAssertEqual(accumulator.cacheHitShare?.ratio, decimal("0.5"), "result aggregate stays session authority")
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, 2, "request CH must not alter cumulative cost")
        XCTAssertEqual(accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, 0)

        let nextTurn = UUID()
        XCTAssertEqual(accumulator.registerTurn(nextTurn, executionID: execution), .accepted)
        XCTAssertNil(accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share, "a new request boundary clears the prior value")
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: nil,
                requestID: "msg-3",
                executionID: execution,
                turnID: nextTurn
            ),
            .accepted
        )
        let missing = try XCTUnwrap(accumulator.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertNil(missing.share)
        XCTAssertTrue(missing.detail.contains("did not include a usage object"))

        let newerRequest = AgentProviderUsageObservation(
            source: .assistant,
            inputTokens: 75,
            outputTokens: 1,
            cacheReadInputTokens: 25,
            cacheCreationInputTokens: 0,
            requestID: "msg-4"
        )
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: newerRequest,
                requestID: "msg-4",
                executionID: execution,
                turnID: nextTurn
            ),
            .accepted
        )
        XCTAssertEqual(accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, decimal("0.25"))
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: nil,
                requestID: "msg-3",
                executionID: execution,
                turnID: nextTurn
            ),
            .rejected(.replayedOrSynthetic),
            "an initially usage-less superseded identity cannot clear the current request"
        )
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: .init(
                    source: .assistant,
                    inputTokens: 1,
                    outputTokens: 1,
                    cacheReadInputTokens: 99,
                    cacheCreationInputTokens: 0,
                    requestID: "msg-3"
                ),
                requestID: "msg-3",
                executionID: execution,
                turnID: nextTurn
            ),
            .rejected(.replayedOrSynthetic),
            "a usage-bearing replay of an initially usage-less identity cannot publish stale CH"
        )
        XCTAssertEqual(
            accumulator.observeLatestClaudeRequest(
                observation: secondRequest,
                requestID: "msg-2",
                executionID: execution,
                turnID: nextTurn
            ),
            .rejected(.replayedOrSynthetic),
            "an older cross-turn request identity cannot replace the current value"
        )
        XCTAssertEqual(accumulator.latestRequestCacheHit(for: .claudeAssistant)?.share?.ratio, decimal("0.25"))
        XCTAssertEqual(accumulator.sessionCostEstimate?.amount, 2)

        accumulator.endExecution(execution)
        XCTAssertNil(accumulator.latestRequestCacheHit(for: .claudeAssistant))
        let persisted = try XCTUnwrap(accumulator.persistedRepresentation)
        let encoded = try JSONEncoder().encode(persisted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("msg-"))
        let restored = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: persisted,
            hasPriorHistory: true,
            qualification: qualified
        )
        XCTAssertNil(restored.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(restored.sessionCostEstimate?.amount, 2, "restore preserves the accumulated ledger")

        var blocked = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: nil,
            hasPriorHistory: false,
            qualification: .executionVerified
        )
        let blockedExecution = UUID()
        let blockedTurn = UUID()
        blocked.beginAwaitingExecution(executionID: blockedExecution, providerSessionID: nil, at: start)
        XCTAssertEqual(blocked.registerTurn(blockedTurn, executionID: blockedExecution), .accepted)
        XCTAssertTrue(try XCTUnwrap(blocked.latestRequestCacheHit(for: .claudeAssistant)).detail.contains("not reported"))
        XCTAssertEqual(
            blocked.resolveExecutionQualification(
                executionID: blockedExecution,
                verdict: .blocked(.unsupportedQueueSemantics("test queue bound")),
                at: start
            ),
            .rejected(.executionBlocked)
        )
        let blockedLatest = try XCTUnwrap(blocked.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertNil(blockedLatest.share)
        XCTAssertTrue(blockedLatest.detail.contains("not shown because queue semantics are not qualified"))
        XCTAssertFalse(blockedLatest.detail.contains("yet"), "a terminal block must not claim usage is still pending")
    }

    // MARK: - Helpers

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text) ?? .nan
    }

    private func makeQualified(
        baseline: AgentUsageSegmentBaseline,
        hasPriorHistory: Bool = false
    ) -> AgentUsageAccumulator {
        var accumulator = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: nil,
            hasPriorHistory: hasPriorHistory,
            qualification: qualified
        )
        accumulator.beginExecution(executionID: execution, providerSessionID: "provider-session", baseline: baseline, at: start)
        return accumulator
    }

    private func request(
        _ turnID: UUID,
        _ source: AgentProviderUsageObservation.Source,
        requestID: String?,
        input: Int? = nil,
        output: Int? = nil,
        read: Int? = nil,
        creation: Int? = nil,
        parentToolUseID: String? = nil
    ) -> AgentUsageObservationInput {
        .init(
            observation: .init(
                source: source,
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: creation,
                requestID: requestID,
                parentToolUseID: parentToolUseID
            ),
            executionID: execution,
            turnID: turnID,
            attribution: .live
        )
    }

    private func result(
        _ turnID: UUID,
        id: String?,
        input: Int? = nil,
        output: Int? = nil,
        read: Int? = nil,
        creation: Int? = nil,
        cost: String? = nil
    ) -> AgentUsageObservationInput {
        .init(
            observation: .init(
                source: .result,
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: creation,
                envelopeID: id,
                resultSubtype: "success",
                resultIsError: false
            ),
            reportedCost: cost.flatMap { Decimal(string: $0) },
            executionID: execution,
            turnID: turnID,
            attribution: .live,
            hasOriginalResultAuthority: true
        )
    }
}
