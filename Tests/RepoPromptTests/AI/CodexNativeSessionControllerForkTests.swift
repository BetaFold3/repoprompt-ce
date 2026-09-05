import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CodexNativeSessionControllerForkTests: XCTestCase {
    func testForkRequestUsesBoundIdleThreadPinnedConfigurationAndLeavesBindingUnchanged() async throws {
        let recorder = ForkRequestRecorder(result: [
            "thread": ["id": "child-thread", "path": "/tmp/child-rollout"],
            "model": "unchanged-model",
            "reasoningEffort": "high"
        ])
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(
            threadID: "source-thread",
            threadPath: "/tmp/source-rollout",
            routingTurnID: nil
        )
        let before = controller.test_forkStateSnapshot

        let child = try await controller.forkThread("checkpoint-turn")

        XCTAssertEqual(
            child,
            .init(
                conversationID: "child-thread",
                rolloutPath: "/tmp/child-rollout",
                model: "unchanged-model",
                reasoningEffort: "high"
            )
        )
        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "thread/fork")
        XCTAssertEqual(request.timeout, 7)
        XCTAssertEqual(request.params["threadId"] as? String, "source-thread")
        XCTAssertEqual(request.params["lastTurnId"] as? String, "checkpoint-turn")
        XCTAssertEqual(request.params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(request.params["ephemeral"] as? Bool, false)
        XCTAssertEqual(request.params["cwd"] as? String, "/pinned/workspace")
        XCTAssertEqual(request.params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(request.params["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(request.params["approvalsReviewer"] as? String, "guardian_subagent")
        XCTAssertEqual(request.params["config"] as? [String: String], ["feature": "pinned"])
        XCTAssertNil(request.params["baseInstructions"])
        XCTAssertNil(request.params["prompt"])
        XCTAssertNil(request.params["model"])
        XCTAssertEqual(controller.test_forkStateSnapshot, before)
    }

    func testForkRejectsInvalidUnboundAndIndependentNonIdleStatesBeforeSubmission() async {
        let invalidRecorder = ForkRequestRecorder(result: [:])
        let invalidController = makeController(recorder: invalidRecorder)
        await invalidController.test_installForkableThreadState(threadID: "source")
        await assertPrimitiveError(.invalidInput) {
            _ = try await invalidController.forkThread("   ")
        }
        XCTAssertTrue(invalidRecorder.requests().isEmpty)

        let unboundRecorder = ForkRequestRecorder(result: [:])
        let unboundController = makeController(recorder: unboundRecorder)
        await assertPrimitiveError(.unboundController) {
            _ = try await unboundController.forkThread("turn")
        }
        XCTAssertTrue(unboundRecorder.requests().isEmpty)

        await assertForkRejectedBeforeSubmission(activeTurnIDs: ["active-turn"])
        await assertForkRejectedBeforeSubmission(activeTurnIDs: [], routingTurnID: "routing-only")
        await assertForkRejectedBeforeSubmission(activeTurnIDs: [], authoritativeTurnID: "authority-only")
        await assertForkRejectedBeforeSubmission(pendingAuthorityReconciliation: true)
        await assertForkRejectedBeforeSubmission(isBindingSession: true)
    }

    func testForkRevalidatesAfterSuspendedConfigAndRejectsAcceptedTurn() async {
        let configGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(result: ["thread": ["id": "child"]])
        let controller = makeController(
            recorder: recorder,
            configOverridesProvider: {
                await configGate.enterAndWait()
                return ["feature": "pinned"]
            }
        )
        await controller.test_installForkableThreadState(threadID: "source")
        let forkTask = Task {
            try await controller.forkThread("checkpoint")
        }

        await configGate.waitUntilEntered()
        await controller.test_handleNotification(
            method: "turn/started",
            params: [
                "threadId": .string("source"),
                "turn": .object(["id": .string("accepted-turn")])
            ]
        )
        await configGate.release()

        do {
            _ = try await forkTask.value
            XCTFail("Expected the accepted turn to invalidate the idle snapshot")
        } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
            XCTAssertEqual(error, .nonIdleController)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(recorder.requests().isEmpty)
    }

    func testForkRejectsSourceTurnAcceptedAfterReservationBeforeEnqueue() async {
        let enqueueGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(result: ["thread": ["id": "child"]])
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(threadID: "source")
        controller.test_setForkBeforeEnqueueHook {
            await enqueueGate.enterAndWait()
        }
        let forkTask = Task {
            try await controller.forkThread("checkpoint")
        }

        await enqueueGate.waitUntilEntered()
        XCTAssertTrue(controller.test_forkStateSnapshot.isForkInFlight)
        await controller.test_handleNotification(
            method: "turn/started",
            params: [
                "threadId": .string("source"),
                "turn": .object(["id": .string("accepted-after-reservation")])
            ]
        )
        await enqueueGate.release()

        do {
            _ = try await forkTask.value
            XCTFail("Expected the accepted turn to prevent fork enqueue")
        } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
            XCTAssertEqual(error, .nonIdleController)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(recorder.requests().isEmpty)
        XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
    }

    func testPreEnqueueCancellationSubmitsNothingReleasesReservationAndAdmitsSuccessor() async throws {
        let enqueueGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(result: ["thread": ["id": "child"]])
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(threadID: "source")
        controller.test_setForkBeforeEnqueueHook {
            await enqueueGate.enterAndWait()
        }
        let cancelledFork = Task {
            try await controller.forkThread("checkpoint")
        }

        await enqueueGate.waitUntilEntered()
        cancelledFork.cancel()
        await enqueueGate.release()

        do {
            _ = try await cancelledFork.value
            XCTFail("Expected pre-enqueue cancellation")
        } catch is CancellationError {
            // Expected: cancellation is observed before any request task is created.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(recorder.requests().isEmpty)
        XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)

        controller.test_setForkBeforeEnqueueHook(nil)
        _ = try await controller.forkThread("checkpoint")
        XCTAssertEqual(recorder.requests().count, 1)
    }

    func testHandshakeCancellationIsForwardedBeforeInjectedEnqueue() async throws {
        let handshakeGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(result: ["thread": ["id": "child"]])
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(threadID: "source")
        controller.test_setForkRequestTaskBeforeEnqueueHook {
            await handshakeGate.enterAndWait()
        }
        let cancelledFork = Task {
            try await controller.forkThread("checkpoint")
        }

        await handshakeGate.waitUntilEntered()
        XCTAssertTrue(controller.test_forkStateSnapshot.isForkInFlight)
        cancelledFork.cancel()
        await handshakeGate.release()

        do {
            _ = try await cancelledFork.value
            XCTFail("Expected cancellation before injected enqueue admission")
        } catch is CancellationError {
            // Expected: the cancellation handler forwards cancellation to the request task.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(recorder.requests().isEmpty)
        XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)

        controller.test_setForkRequestTaskBeforeEnqueueHook(nil)
        _ = try await controller.forkThread("checkpoint")
        XCTAssertEqual(recorder.requests().count, 1)
    }

    func testStaleFailedRevalidationCleanupCannotClearSuccessorReservation() async throws {
        let beforeEnqueueGate = TestAsyncGate()
        let successorRequestGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(
            result: ["thread": ["id": "child"]],
            requestGate: successorRequestGate
        )
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(threadID: "source")
        controller.test_setForkBeforeEnqueueHook {
            await beforeEnqueueGate.enterAndWait()
        }
        let failedFork = Task {
            try await controller.forkThread("checkpoint")
        }

        await beforeEnqueueGate.waitUntilEntered()
        let staleReservationID = try XCTUnwrap(controller.test_forkStateSnapshot.forkReservationID)
        await controller.test_handleNotification(
            method: "turn/started",
            params: [
                "threadId": .string("source"),
                "turn": .object(["id": .string("intervening-turn")])
            ]
        )
        await beforeEnqueueGate.release()
        do {
            _ = try await failedFork.value
            XCTFail("Expected failed final revalidation")
        } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
            XCTAssertEqual(error, .nonIdleController)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await controller.test_handleNotification(
            method: "turn/completed",
            params: [
                "threadId": .string("source"),
                "turn": .object([
                    "id": .string("intervening-turn"),
                    "status": .string("completed")
                ])
            ]
        )
        controller.test_setForkBeforeEnqueueHook(nil)
        let successorFork = Task {
            try await controller.forkThread("checkpoint")
        }
        await successorRequestGate.waitUntilEntered()
        XCTAssertEqual(recorder.requests().count, 1)
        let successorReservationID = try XCTUnwrap(controller.test_forkStateSnapshot.forkReservationID)
        XCTAssertNotEqual(successorReservationID, staleReservationID)

        await controller.test_clearForkReservation(ownedBy: staleReservationID)
        XCTAssertEqual(controller.test_forkStateSnapshot.forkReservationID, successorReservationID)
        await assertPrimitiveError(.nonIdleController) {
            _ = try await controller.forkThread("checkpoint")
        }
        XCTAssertEqual(recorder.requests().count, 1)

        await successorRequestGate.release()
        _ = try await successorFork.value
        XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
    }

    func testConcurrentForkIsRejectedWhileReservationIsInFlightAndReservationClears() async throws {
        let requestGate = TestAsyncGate()
        let recorder = ForkRequestRecorder(
            result: ["thread": ["id": "child"]],
            requestGate: requestGate
        )
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(threadID: "source")
        let firstFork = Task {
            try await controller.forkThread("checkpoint")
        }

        await requestGate.waitUntilEntered()
        await assertPrimitiveError(.nonIdleController) {
            _ = try await controller.forkThread("checkpoint")
        }
        XCTAssertEqual(recorder.requests().count, 1)

        await requestGate.release()
        _ = try await firstFork.value
        _ = try await controller.forkThread("checkpoint")
        XCTAssertEqual(recorder.requests().count, 2)
    }

    func testForkMalformedSuccessfulResponseIsAmbiguous() async {
        for result: [String: Any] in [[:], ["thread": ["id": " "]]] {
            let recorder = ForkRequestRecorder(result: result)
            let controller = makeController(recorder: recorder)
            await controller.test_installForkableThreadState(threadID: "source")

            do {
                _ = try await controller.forkThread("turn")
                XCTFail("Expected ambiguous fork outcome")
            } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
                guard case .ambiguousForkOutcome = error else {
                    XCTFail("Unexpected primitive error: \(error)")
                    continue
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.requests().count, 1)
            XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
        }
    }

    func testForkTimeoutAndDisconnectAreAmbiguousAndAttemptedOnce() async {
        let failures: [Error] = [
            CodexAppServerClient.ClientError.requestFailed(.init(
                method: "thread/fork",
                code: nil,
                message: "Request timed out after 7.0s",
                data: nil
            )),
            CodexAppServerClient.ClientError.processNotRunning,
            CodexAppServerClient.ClientError.transportWriteFailed(message: "write uncertain", errno: nil),
            CodexAppServerClient.ClientError.transportReadSetupFailed(message: "read uncertain", errno: nil)
        ]

        for failure in failures {
            let recorder = ForkRequestRecorder(error: failure)
            let controller = makeController(recorder: recorder)
            await controller.test_installForkableThreadState(threadID: "source")

            do {
                _ = try await controller.forkThread("turn")
                XCTFail("Expected ambiguous fork outcome")
            } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
                guard case .ambiguousForkOutcome = error else {
                    XCTFail("Unexpected primitive error: \(error)")
                    continue
                }
                // Expected: the submitted mutation is never retried.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.requests().count, 1)
            XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
        }
    }

    func testForkPostSubmissionDecodeFailuresAndCancellationAreAmbiguousOnce() async {
        let failures: [Error] = [
            CodexAppServerClient.ClientError.invalidResponse,
            CodexAppServerClient.ClientError.jsonDecodeFailed,
            CancellationError()
        ]

        for failure in failures {
            let recorder = ForkRequestRecorder(error: failure)
            let controller = makeController(recorder: recorder)
            await controller.test_installForkableThreadState(threadID: "source")

            do {
                _ = try await controller.forkThread("turn")
                XCTFail("Expected ambiguous fork outcome")
            } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
                guard case .ambiguousForkOutcome = error else {
                    XCTFail("Unexpected primitive error: \(error)")
                    continue
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.requests().count, 1)
            XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
        }
    }

    func testForkCodedProviderFailuresPropagateUnchangedWithoutRetry() async {
        let failures: [CodexAppServerClient.RequestFailure] = [
            .init(method: "thread/fork", code: -32602, message: "invalid params", data: nil),
            .init(method: "thread/fork", code: -32000, message: "provider timed out after mutation", data: nil),
            .init(method: "thread/fork", code: -32602, message: "unknown variant readonly", data: nil)
        ]

        for failure in failures {
            let recorder = ForkRequestRecorder(
                error: CodexAppServerClient.ClientError.requestFailed(failure)
            )
            let controller = makeController(recorder: recorder)
            await controller.test_installForkableThreadState(threadID: "source")

            do {
                _ = try await controller.forkThread("turn")
                XCTFail("Expected provider failure")
            } catch let CodexAppServerClient.ClientError.requestFailed(actual) {
                XCTAssertEqual(actual, failure)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.requests().count, 1)
            XCTAssertFalse(controller.test_forkStateSnapshot.isForkInFlight)
        }
    }

    func testListThreadTurnsUsesSummaryDescendingDefaultsAndParsesTypedPage() async throws {
        let recorder = ForkRequestRecorder(result: [
            "data": [
                [
                    "id": "turn-2",
                    "status": "completed",
                    "items": [["type": "agentMessage"]],
                    "itemsView": "summary",
                    "startedAt": 10,
                    "completedAt": 12
                ],
                [
                    "id": "turn-1",
                    "status": "interrupted",
                    "items": [],
                    "itemsView": "summary",
                    "startedAt": 1
                ]
            ],
            "nextCursor": "cursor-2",
            "backwardsCursor": NSNull()
        ])
        let controller = makeController(recorder: recorder)

        let page = try await controller.listThreadTurns(threadID: "thread-exact")

        XCTAssertEqual(page.data.map(\.id), ["turn-2", "turn-1"])
        XCTAssertEqual(page.data.map(\.status), [.completed, .interrupted])
        XCTAssertEqual(page.data.first?.items, [.init(type: "agentMessage")])
        XCTAssertEqual(page.data.first?.itemsView, .summary)
        XCTAssertEqual(page.data.first?.startedAt, 10)
        XCTAssertEqual(page.data.first?.completedAt, 12)
        XCTAssertEqual(page.nextCursor, "cursor-2")
        XCTAssertNil(page.backwardsCursor)

        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "thread/turns/list")
        XCTAssertEqual(request.params["threadId"] as? String, "thread-exact")
        XCTAssertEqual(request.params["sortDirection"] as? String, "desc")
        XCTAssertEqual(request.params["itemsView"] as? String, "summary")
        XCTAssertNil(request.params["cursor"])
        XCTAssertNil(request.params["limit"])
        XCTAssertEqual(request.timeout, 7)

        _ = try await controller.listThreadTurns(
            threadID: "thread-exact",
            cursor: "opaque-cursor",
            limit: 25,
            sortDirection: .ascending
        )
        let explicitRequest = try XCTUnwrap(recorder.requests().last)
        XCTAssertEqual(explicitRequest.method, "thread/turns/list")
        XCTAssertEqual(explicitRequest.params["threadId"] as? String, "thread-exact")
        XCTAssertEqual(explicitRequest.params["cursor"] as? String, "opaque-cursor")
        XCTAssertEqual(explicitRequest.params["limit"] as? Int, 25)
        XCTAssertEqual(explicitRequest.params["sortDirection"] as? String, "asc")
        XCTAssertEqual(explicitRequest.params["itemsView"] as? String, "summary")
        XCTAssertEqual(explicitRequest.timeout, 7)
        XCTAssertEqual(recorder.requests().count, 2)
    }

    func testListAndArchiveRejectInvalidInputAndMalformedPagesFailClosed() async {
        let invalidInputCases: [(String, String?, Int?)] = [
            (" ", nil, nil),
            ("thread", " ", nil),
            ("thread", nil, 0),
            ("thread", nil, -1)
        ]
        for (threadID, cursor, limit) in invalidInputCases {
            let recorder = ForkRequestRecorder()
            let controller = makeController(recorder: recorder)
            await assertPrimitiveError(.invalidInput) {
                _ = try await controller.listThreadTurns(
                    threadID: threadID,
                    cursor: cursor,
                    limit: limit,
                    sortDirection: .descending
                )
            }
            XCTAssertTrue(recorder.requests().isEmpty)
        }

        let malformedPages: [[String: Any]] = [
            [:],
            ["data": "not-an-array"],
            ["data": [[
                "id": "turn",
                "status": "new-status",
                "items": [],
                "itemsView": "summary"
            ]]],
            ["data": [[
                "id": "turn",
                "status": "completed",
                "itemsView": "summary"
            ]]],
            ["data": [[
                "id": "turn",
                "status": "completed",
                "items": [],
                "itemsView": "new-view"
            ]]],
            ["data": [[
                "id": "turn",
                "status": "completed",
                "items": [[:]],
                "itemsView": "summary"
            ]]],
            [
                "data": [[
                    "id": "turn",
                    "status": "completed",
                    "items": [],
                    "itemsView": "summary"
                ]],
                "nextCursor": " "
            ]
        ]
        for page in malformedPages {
            let recorder = ForkRequestRecorder(result: page)
            let controller = makeController(recorder: recorder)
            await assertPrimitiveError(.invalidResponse) {
                _ = try await controller.listThreadTurns(threadID: "thread")
            }
            XCTAssertEqual(recorder.requests().count, 1)
        }

        let archiveRecorder = ForkRequestRecorder()
        let archiveController = makeController(recorder: archiveRecorder)
        await assertPrimitiveError(.invalidInput) {
            try await archiveController.archiveThread(threadID: " ")
        }
        XCTAssertTrue(archiveRecorder.requests().isEmpty)
    }

    func testArchiveThreadUsesExactIDAndConfiguredTimeout() async throws {
        let recorder = ForkRequestRecorder(result: [:])
        let controller = makeController(recorder: recorder)

        try await controller.archiveThread(threadID: " thread-exact ")

        let request = try XCTUnwrap(recorder.requests().only)
        XCTAssertEqual(request.method, "thread/archive")
        XCTAssertEqual(request.params as NSDictionary, ["threadId": " thread-exact "] as NSDictionary)
        XCTAssertEqual(request.timeout, 7)
    }

    func testForeignChildThreadNotificationsAreDroppedBySourceRouting() async {
        XCTAssertTrue(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "mcpServer/startupStatus/updated",
            params: ["threadId": "child-thread"],
            activeThreadID: "source-thread",
            currentTurnID: nil
        ))
        XCTAssertTrue(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "thread/started",
            params: ["thread": ["id": "child-thread"]],
            activeThreadID: "source-thread",
            currentTurnID: nil
        ))
        XCTAssertFalse(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "mcpServer/startupStatus/updated",
            params: ["threadId": "source-thread"],
            activeThreadID: "source-thread",
            currentTurnID: nil
        ))

        let controller = makeController(recorder: ForkRequestRecorder())
        await controller.test_installForkableThreadState(threadID: "source-thread")
        let before = controller.test_forkStateSnapshot
        var iterator = controller.events.makeAsyncIterator()

        await controller.test_handleNotification(
            method: "turn/started",
            params: [
                "threadId": .string("child-thread"),
                "turn": .object(["id": .string("child-turn")])
            ]
        )
        await controller.test_handleNotification(
            method: "item/agentMessage/delta",
            params: [
                "threadId": .string("child-thread"),
                "turnId": .string("child-turn"),
                "itemId": .string("child-item"),
                "delta": .string("child text")
            ]
        )
        XCTAssertEqual(controller.test_forkStateSnapshot, before)

        await controller.test_handleNotification(
            method: "turn/started",
            params: [
                "threadId": .string("source-thread"),
                "turn": .object(["id": .string("source-turn")])
            ]
        )
        guard case let .turnStarted(turnID) = await iterator.next() else {
            return XCTFail("Expected the matching source event first")
        }
        XCTAssertEqual(turnID, "source-turn")
        XCTAssertEqual(controller.test_forkStateSnapshot.threadID, "source-thread")
        XCTAssertEqual(controller.test_forkStateSnapshot.activeTurnIDs, Set(["source-turn"]))
        XCTAssertFalse(controller.test_forkStateSnapshot.activeTurnIDs.contains("child-turn"))
    }

    func testManifestCollectionExhaustsDescendingPagesIntoChronologicalOrder() throws {
        let manifest = try CodexForkStructuralVerifier.collectManifestFromDescendingPages([
            .init(
                requestedCursor: nil,
                page: .init(data: [turn("t3"), turn("t2")], nextCursor: "c1", backwardsCursor: nil)
            ),
            .init(
                requestedCursor: "c1",
                page: .init(data: [turn("t1")], nextCursor: nil, backwardsCursor: nil)
            )
        ])

        XCTAssertEqual(manifest.turns.map(\.id), ["t1", "t2", "t3"])
    }

    func testManifestCollectionRejectsRepeatCursorDuplicateBlankAndIncompletePagination() {
        assertVerificationError(.repeatedCursor("c1")) {
            try CodexForkStructuralVerifier.collectManifestFromDescendingPages([
                .init(requestedCursor: nil, page: .init(data: [turn("t2")], nextCursor: "c1", backwardsCursor: nil)),
                .init(requestedCursor: "c1", page: .init(data: [turn("t1")], nextCursor: "c1", backwardsCursor: nil)),
                .init(requestedCursor: "c1", page: .init(data: [], nextCursor: nil, backwardsCursor: nil))
            ])
        }
        assertVerificationError(.duplicateTurnID("t1")) {
            try CodexForkStructuralVerifier.collectManifestFromDescendingPages([
                .init(requestedCursor: nil, page: .init(data: [turn("t1"), turn("t1")], nextCursor: nil, backwardsCursor: nil))
            ])
        }
        assertVerificationError(.blankTurnID) {
            try CodexForkStructuralVerifier.collectManifestFromDescendingPages([
                .init(requestedCursor: nil, page: .init(data: [turn(" ")], nextCursor: nil, backwardsCursor: nil))
            ])
        }
        assertVerificationError(.incompletePagination) {
            try CodexForkStructuralVerifier.collectManifestFromDescendingPages([
                .init(requestedCursor: nil, page: .init(data: [turn("t2")], nextCursor: "missing", backwardsCursor: nil))
            ])
        }
    }

    func testPreForkVerificationAcceptsOrderedLedgerAndRejectsEachCheckpointBoundary() throws {
        let manifest = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("external"), turn("t2"), turn("t3")
        ])
        try CodexForkStructuralVerifier.validatePreFork(
            manifest: manifest,
            ledgerTurnIDsThroughCheckpoint: ["t1", "t2"],
            checkpointTurnID: "t2"
        )

        assertVerificationError(.ledgerDoesNotEndAtCheckpoint) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: manifest,
                ledgerTurnIDsThroughCheckpoint: [],
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.ledgerDoesNotEndAtCheckpoint) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: manifest,
                ledgerTurnIDsThroughCheckpoint: ["t1", "t2", "t3"],
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.ledgerNotOrderedSubsequence) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: manifest,
                ledgerTurnIDsThroughCheckpoint: ["t2", "t1", "t2"],
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.checkpointMissing) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: .init(turns: [turn("t1")]),
                ledgerTurnIDsThroughCheckpoint: ["t1", "missing"],
                checkpointTurnID: "missing"
            )
        }
        assertVerificationError(.checkpointNotCompleted) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: .init(turns: [turn("t1", status: .failed)]),
                ledgerTurnIDsThroughCheckpoint: ["t1"],
                checkpointTurnID: "t1"
            )
        }
        assertVerificationError(.inProgressTurn("busy")) {
            try CodexForkStructuralVerifier.validatePreFork(
                manifest: .init(turns: [turn("t1"), turn("busy", status: .inProgress)]),
                ledgerTurnIDsThroughCheckpoint: ["t1"],
                checkpointTurnID: "t1"
            )
        }
    }

    func testPostForkVerificationAcceptsExactRetainedPrefixAndSourceReread() throws {
        let source = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("t2"), turn("t3")
        ])
        let child = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("t2")
        ])
        let sourceWithMarker = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("t2", itemTypes: ["contextCompaction"])
        ])
        let childWithNormalizedMarker = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("t2", itemTypes: ["context-compaction"])
        ])

        try CodexForkStructuralVerifier.validatePostFork(
            sourceManifest: source,
            childManifest: child,
            sourceThreadID: "source",
            childThreadID: "child",
            checkpointTurnID: "t2"
        )
        try CodexForkStructuralVerifier.validatePostFork(
            sourceManifest: sourceWithMarker,
            childManifest: childWithNormalizedMarker,
            sourceThreadID: "source",
            childThreadID: "child",
            checkpointTurnID: "t2"
        )
        try CodexForkStructuralVerifier.validateSourceReread(preFork: source, reread: source)
    }

    func testPostForkVerificationRejectsChildIdentityCountShapeAndSourceMutation() {
        let source = CodexForkStructuralVerifier.Manifest(turns: [
            turn("t1"), turn("t2"), turn("t3")
        ])
        let child = CodexForkStructuralVerifier.Manifest(turns: [turn("t1"), turn("t2")])

        assertVerificationError(.invalidChildThreadID) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: child,
                sourceThreadID: "source",
                childThreadID: " ",
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.childMatchesSource) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: child,
                sourceThreadID: "source",
                childThreadID: "source",
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.checkpointMissing) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: child,
                sourceThreadID: "source",
                childThreadID: "child",
                checkpointTurnID: "missing"
            )
        }
        assertVerificationError(.childTurnCountMismatch(expected: 2, actual: 1)) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: .init(turns: [turn("t1")]),
                sourceThreadID: "source",
                childThreadID: "child",
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.childRetainedPrefixMismatch) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: .init(turns: [turn("t1"), turn("wrong")]),
                sourceThreadID: "source",
                childThreadID: "child",
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.childRetainedPrefixMismatch) {
            try CodexForkStructuralVerifier.validatePostFork(
                sourceManifest: source,
                childManifest: .init(turns: [
                    turn("t1"),
                    turn("t2", itemTypes: ["context_compaction"])
                ]),
                sourceThreadID: "source",
                childThreadID: "child",
                checkpointTurnID: "t2"
            )
        }
        assertVerificationError(.sourceManifestChanged) {
            try CodexForkStructuralVerifier.validateSourceReread(
                preFork: source,
                reread: .init(turns: [turn("t1"), turn("t2")])
            )
        }
    }

    private func makeController(
        recorder: ForkRequestRecorder,
        configOverridesProvider: @escaping () async -> [String: Any] = { ["feature": "pinned"] }
    ) -> CodexNativeSessionController {
        let options = CodexNativeSessionController.Options(
            requestTimeout: 7,
            configOverridesProvider: configOverridesProvider,
            approvalPolicyProvider: { .onRequest },
            sandboxModeProvider: { .workspaceWrite },
            approvalReviewerProvider: { .autoReview }
        )
        return CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/pinned/workspace",
            options: options,
            requestExecutor: { method, params, timeout in
                try await recorder.handle(method: method, params: params, timeout: timeout)
            }
        )
    }

    private func turn(
        _ id: String,
        status: CodexNativeSessionController.ThreadTurnStatus = .completed,
        itemTypes: [String] = []
    ) -> CodexNativeSessionController.ThreadTurn {
        .init(
            id: id,
            status: status,
            items: itemTypes.map(CodexNativeSessionController.ThreadTurnItem.init(type:)),
            itemsView: .summary,
            startedAt: nil,
            completedAt: nil
        )
    }

    private func assertForkRejectedBeforeSubmission(
        activeTurnIDs: Set<String>? = nil,
        routingTurnID: String? = nil,
        authoritativeTurnID: String? = nil,
        pendingAuthorityReconciliation: Bool = false,
        isBindingSession: Bool = false
    ) async {
        let recorder = ForkRequestRecorder()
        let controller = makeController(recorder: recorder)
        await controller.test_installForkableThreadState(
            threadID: "source",
            activeTurnIDs: activeTurnIDs,
            routingTurnID: routingTurnID,
            authoritativeTurnID: authoritativeTurnID,
            pendingAuthorityReconciliation: pendingAuthorityReconciliation,
            isBindingSession: isBindingSession
        )
        await assertPrimitiveError(.nonIdleController) {
            _ = try await controller.forkThread("turn")
        }
        XCTAssertTrue(recorder.requests().isEmpty)
    }

    private func assertPrimitiveError(
        _ expected: CodexNativeSessionController.ThreadPrimitiveError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CodexNativeSessionController.ThreadPrimitiveError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertVerificationError(
        _ expected: CodexForkStructuralVerificationError,
        operation: () throws -> Any
    ) {
        do {
            _ = try operation()
            XCTFail("Expected \(expected)")
        } catch let error as CodexForkStructuralVerificationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class ForkRequestRecorder: @unchecked Sendable {
    struct Request {
        let method: String
        let params: [String: Any]
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private let result: [String: Any]
    private let error: Error?
    private let requestGate: TestAsyncGate?

    init(
        result: [String: Any] = [:],
        error: Error? = nil,
        requestGate: TestAsyncGate? = nil
    ) {
        self.result = result
        self.error = error
        self.requestGate = requestGate
    }

    func handle(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> [String: Any] {
        lock.lock()
        recordedRequests.append(.init(method: method, params: params ?? [:], timeout: timeout))
        let result = result
        let error = error
        lock.unlock()
        if let requestGate {
            await requestGate.enterAndWait()
        }
        if let error {
            throw error
        }
        return result
    }

    func requests() -> [Request] {
        lock.lock()
        let requests = recordedRequests
        lock.unlock()
        return requests
    }
}

private actor TestAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
