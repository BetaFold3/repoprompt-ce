import Foundation
@testable import RepoPromptApp
import XCTest

/// Phase 2 cold-resume contract: `thread/resume {excludeTurns:true}` with capability memos keyed
/// to the client transport generation, bounded turn-list reconciliation inside the binding
/// window, bounded `readThreadSnapshot`, and the live-refresh supersession guard.
final class CodexNativeResumeLifecycleTests: XCTestCase {
    private typealias RuntimeStatus = CodexNativeSessionController.ThreadSnapshot.RuntimeStatus

    // MARK: - excludeTurns policy

    func testResumeSendsExcludeTurnsAndHonoredIdleResponseNeedsNoTurnList() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                threadResponse(status: ["type": "idle"], turns: [])
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script)

        let ref = try await resume(controller)

        XCTAssertEqual(ref.conversationID, "saved-thread")
        XCTAssertEqual(script.methods, ["thread/resume", "thread/memoryMode/set"])
        let params = try XCTUnwrap(script.requests("thread/resume").first?.params)
        XCTAssertEqual(params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(params["threadId"] as? String, "saved-thread")
        XCTAssertEqual(params["path"] as? String, "/tmp/saved-thread.jsonl")
        XCTAssertEqual(params["cwd"] as? String, "/tmp/workspace")
        XCTAssertNotNil(params["approvalPolicy"])
        XCTAssertNotNil(params["sandbox"])
        XCTAssertNil(params["baseInstructions"])
        XCTAssertEqual(controller.test_excludeTurnsSupport, .honored)
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .idle)
        XCTAssertNil(controller.test_routingCurrentTurnID)
        XCTAssertTrue(controller.test_activeTurnIDs.isEmpty)
    }

    func testExcludeTurnsRejectionRetriesOnceWithoutFlagAndMemoResetsWithTransportGeneration() async throws {
        let script = ResumeRequestScript { method, _, callIndex in
            guard method == "thread/resume" else { return [:] }
            switch callIndex {
            case 0:
                throw requestFailure(
                    "thread/resume",
                    code: -32602,
                    message: "Invalid request: unknown field `excludeTurns`, expected one of `threadId`, `path`"
                )
            case 1, 2:
                throw ResumeLifecycleTestError.resumeUnavailable
            default:
                return threadResponse(status: ["type": "idle"], turns: [])
            }
        }
        let (controller, client) = await makeController(script: script)

        await assertResumeUnavailable(controller)
        var resumes = script.requests("thread/resume")
        XCTAssertEqual(resumes.count, 2, "A named excludeTurns rejection retries exactly once.")
        XCTAssertEqual(resumes.first?.params["excludeTurns"] as? Bool, true)
        XCTAssertNil(resumes.last?.params["excludeTurns"])
        XCTAssertEqual(controller.test_excludeTurnsSupport, .rejected)

        // Same app-server process: the memo applies and the flag is not resent.
        await assertResumeUnavailable(controller)
        resumes = script.requests("thread/resume")
        XCTAssertEqual(resumes.count, 3)
        XCTAssertNil(resumes.last?.params["excludeTurns"])

        // A restarted app-server (new transport generation) is probed again.
        await client.debugInstallTestTransport()
        _ = try await resume(controller)
        resumes = script.requests("thread/resume")
        XCTAssertEqual(resumes.count, 4)
        XCTAssertEqual(resumes.last?.params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(controller.test_excludeTurnsSupport, .honored)
    }

    func testSuccessfulRetryWithoutExcludeTurnsKeepsRejectedMemoForTheTransportGeneration() async throws {
        let script = ResumeRequestScript { method, _, callIndex in
            guard method == "thread/resume" else { return [:] }
            let turns: [[String: Any]] = [["id": "turn-old", "status": "completed", "items": []]]
            switch callIndex {
            case 0:
                throw requestFailure(
                    "thread/resume",
                    code: -32602,
                    message: "unknown field `excludeTurns`, expected one of `threadId`, `path`"
                )
            case 1:
                // The no-flag retry succeeds with full history; the system-error status then fails
                // the resume, so this controller resumes again on the same transport generation.
                return threadResponse(status: ["type": "systemError"], turns: turns)
            default:
                return threadResponse(status: ["type": "idle"], turns: turns)
            }
        }
        let (controller, _) = await makeController(script: script)

        do {
            _ = try await resume(controller)
            XCTFail("Expected the system-error resume to throw")
        } catch CodexSessionControllerError.threadInSystemErrorState {
            // Expected: the resume RPC itself succeeded on the no-flag retry.
        }
        var resumes = script.requests("thread/resume")
        XCTAssertEqual(resumes.count, 2)
        XCTAssertEqual(resumes.first?.params["excludeTurns"] as? Bool, true)
        XCTAssertNil(resumes.last?.params["excludeTurns"])
        XCTAssertEqual(
            controller.test_excludeTurnsSupport,
            .rejected,
            "A successful retry that never carried the flag must not relabel the memo."
        )

        let ref = try await resume(controller)

        XCTAssertEqual(ref.conversationID, "saved-thread")
        resumes = script.requests("thread/resume")
        XCTAssertEqual(resumes.count, 3, "A later same-generation resume makes exactly one thread/resume request.")
        XCTAssertNil(resumes.last?.params["excludeTurns"], "The known-rejected flag is not resent.")
        XCTAssertEqual(controller.test_excludeTurnsSupport, .rejected)
    }

    func testBareInvalidParamsResumeFailureIsNotRetried() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/resume" else { return [:] }
            throw requestFailure("thread/resume", code: -32602, message: "Invalid params")
        }
        let (controller, _) = await makeController(script: script)

        do {
            _ = try await resume(controller)
            XCTFail("Expected the bare -32602 resume failure to propagate")
        } catch {
            XCTAssertFalse(CodexNativeSessionController.isExcludeTurnsRejection(error))
        }
        XCTAssertEqual(script.methods, ["thread/resume"])
        XCTAssertEqual(script.requests("thread/resume").first?.params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(controller.test_excludeTurnsSupport, .unknown)
    }

    func testExcludeTurnsRejectionClassificationRequiresTheNamedField() {
        struct Row {
            let name: String
            let error: Error
            let isRejection: Bool
        }
        let rows = [
            Row(
                name: "serde unknown field",
                error: requestFailure("thread/resume", code: -32602, message: "unknown field `excludeTurns`"),
                isRejection: true
            ),
            Row(
                name: "snake-case unsupported parameter",
                error: requestFailure("thread/resume", code: nil, message: "Unsupported parameter: exclude_turns"),
                isRejection: true
            ),
            Row(
                name: "unexpected field",
                error: requestFailure("thread/resume", code: -32600, message: "unexpected field excludeTurns in params"),
                isRejection: true
            ),
            Row(
                name: "field named before a not-supported clause",
                error: requestFailure("thread/resume", code: nil, message: "excludeTurns is not supported by this app-server"),
                isRejection: true
            ),
            Row(
                name: "another field rejected with excludeTurns only in the expected list",
                error: requestFailure(
                    "thread/resume",
                    code: -32602,
                    message: "unknown field `otherField`, expected one of `threadId`, `excludeTurns`"
                ),
                isRejection: false
            ),
            Row(
                name: "bare invalid params",
                error: requestFailure("thread/resume", code: -32602, message: "Invalid params"),
                isRejection: false
            ),
            Row(
                name: "generic unknown field",
                error: requestFailure("thread/resume", code: -32602, message: "unknown field `sandboxPolicy`"),
                isRejection: false
            ),
            Row(
                name: "timeout",
                error: requestFailure("thread/resume", code: nil, message: "Request timed out after 120s"),
                isRejection: false
            ),
            Row(
                name: "auth",
                error: requestFailure("thread/resume", code: 401, message: "Unauthorized: token expired"),
                isRejection: false
            ),
            Row(
                name: "frame limit",
                error: CodexAppServerClient.ClientError.inboundFrameTooLarge(
                    observedBytes: 33_554_433,
                    limitBytes: 33_554_432
                ),
                isRejection: false
            )
        ]
        for row in rows {
            XCTAssertEqual(
                CodexNativeSessionController.isExcludeTurnsRejection(row.error),
                row.isRejection,
                row.name
            )
        }
    }

    func testIgnoredExcludeTurnsUsesResponseTurnsWithoutListing() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/resume" else { return [:] }
            return threadResponse(
                status: ["type": "active", "activeFlags": []],
                turns: [
                    ["id": "turn-old", "status": "completed", "items": []],
                    ["id": "turn-live", "status": "inProgress", "items": []]
                ]
            )
        }
        let (controller, _) = await makeController(script: script)

        _ = try await resume(controller)

        XCTAssertEqual(script.methods, ["thread/resume", "thread/memoryMode/set"])
        XCTAssertEqual(controller.test_excludeTurnsSupport, .ignored)
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-live")
        XCTAssertEqual(controller.test_activeTurnIDs, ["turn-live"])
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .active(activeFlags: []))
    }

    // MARK: - Reconciliation inside the binding window

    func testActiveResumeListsNewestTurnAndRoutesItsInProgressID() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                threadResponse(
                    status: ["type": "active", "activeFlags": ["waitingOnApproval"]],
                    turns: []
                )
            case "thread/turns/list":
                ["data": [["id": "turn-live", "status": "inProgress", "items": []]]]
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script, requestTimeout: 30)

        _ = try await resume(controller)

        XCTAssertEqual(
            script.methods,
            ["thread/resume", "thread/turns/list", "thread/memoryMode/set"],
            "Reconciliation runs after the resume response and before memory mode/apply."
        )
        let list = try XCTUnwrap(script.requests("thread/turns/list").first)
        XCTAssertEqual(list.params["threadId"] as? String, "saved-thread")
        XCTAssertEqual(list.params["limit"] as? Int, 1)
        XCTAssertEqual(list.params["sortDirection"] as? String, "desc")
        XCTAssertEqual(list.params["itemsView"] as? String, "notLoaded")
        XCTAssertEqual(list.params.count, 4)
        XCTAssertEqual(list.timeout, 15, "Startup listing is bounded by min(requestTimeout, 15).")
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-live")
        XCTAssertEqual(controller.test_activeTurnIDs, ["turn-live"])
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID, "A listing never fabricates lifecycle authority.")
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .active(activeFlags: ["waitingOnApproval"]))

        // A later turn-less thread notification is attributed to the listed turn through routing.
        await controller.test_handleNotification(
            method: "thread/compacted",
            params: ["threadId": .string("saved-thread")]
        )
        let events = await finishAndReadEvents(from: controller)
        let compactedTurnIDs = events.compactMap { event -> String?? in
            if case let .contextCompacted(turnID) = event { return turnID }
            return nil
        }
        XCTAssertEqual(compactedTurnIDs, [.some("turn-live")])
    }

    func testActiveResumeWithTerminalNewestTurnLeavesIdentityUnresolved() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
            case "thread/turns/list":
                ["data": [["id": "turn-done", "status": "completed", "items": []]]]
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script)

        _ = try await resume(controller)

        XCTAssertNil(controller.test_routingCurrentTurnID)
        XCTAssertTrue(controller.test_activeTurnIDs.isEmpty)
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
        XCTAssertEqual(
            controller.lastKnownRuntimeStatus,
            .active(activeFlags: []),
            "The thread stays active with an unresolved identity so the coordinator marks it busy."
        )
    }

    func testStartupTurnListFailureLeavesIdentityUnresolvedWithoutFullRead() async throws {
        struct Row {
            let name: String
            let listError: Error
            let expectedSupport: CodexNativeSessionController.TurnsListSupport
        }
        let rows = [
            Row(
                name: "method not found",
                listError: requestFailure("thread/turns/list", code: -32601, message: "Method not found"),
                expectedSupport: .unsupported
            ),
            Row(
                name: "named unknown method",
                listError: requestFailure(
                    "thread/turns/list",
                    code: -32600,
                    message: "unknown variant `thread/turns/list`, expected one of `thread/read`"
                ),
                expectedSupport: .unsupported
            ),
            Row(
                name: "timeout",
                listError: requestFailure("thread/turns/list", code: nil, message: "Request timed out after 15s"),
                expectedSupport: .unknown
            )
        ]
        for row in rows {
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
                case "thread/turns/list":
                    throw row.listError
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)

            let ref = try await resume(controller)

            XCTAssertEqual(ref.conversationID, "saved-thread", row.name)
            XCTAssertEqual(
                script.methods,
                ["thread/resume", "thread/turns/list", "thread/memoryMode/set"],
                "\(row.name): startup must never fall back to a full thread/read"
            )
            XCTAssertEqual(controller.test_turnsListSupport, row.expectedSupport, row.name)
            XCTAssertNil(controller.test_routingCurrentTurnID, row.name)
            XCTAssertEqual(controller.lastKnownRuntimeStatus, .active(activeFlags: []), row.name)
            XCTAssertTrue(controller.hasActiveThread, row.name)
        }
    }

    func testStartupTurnListTransportFailurePropagatesInsteadOfReportingReady() async throws {
        struct Row {
            let name: String
            let listError: Error
        }
        let rows = [
            Row(name: "process not running", listError: CodexAppServerClient.ClientError.processNotRunning),
            Row(
                name: "stdin write failed",
                listError: CodexAppServerClient.ClientError.transportWriteFailed(message: "Broken pipe", errno: 32)
            ),
            Row(
                name: "inbound frame too large",
                listError: CodexAppServerClient.ClientError.inboundFrameTooLarge(
                    observedBytes: 33_554_433,
                    limitBytes: 33_554_432
                )
            )
        ]
        for row in rows {
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
                case "thread/turns/list":
                    throw row.listError
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)

            do {
                _ = try await resume(controller)
                XCTFail("\(row.name): a dead transport must fail the resume")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: row.listError), row.name)
            }
            XCTAssertEqual(
                script.methods,
                ["thread/resume", "thread/turns/list"],
                "\(row.name): no memory-mode request or apply after the transport died"
            )
            XCTAssertFalse(controller.hasActiveThread, row.name)
            XCTAssertEqual(controller.test_turnsListSupport, .unknown, row.name)
        }
    }

    func testTurnsListCompatibilityClassificationMatchesTheRejectedToken() {
        struct Row {
            let name: String
            let error: Error
            let isUnsupportedMethod: Bool
            let isItemsViewRejection: Bool
        }
        let rows = [
            Row(
                name: "method not found code",
                error: requestFailure("thread/turns/list", code: -32601, message: "Method not found"),
                isUnsupportedMethod: true,
                isItemsViewRejection: false
            ),
            Row(
                name: "named unknown method variant",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32600,
                    message: "unknown variant `thread/turns/list`, expected one of `thread/read`, `thread/resume`"
                ),
                isUnsupportedMethod: true,
                isItemsViewRejection: false
            ),
            Row(
                name: "method listed only among the expected methods",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32600,
                    message: "unknown variant `thread/foo`, expected one of `thread/read`, `thread/turns/list`"
                ),
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            ),
            Row(
                name: "method-prefixed unknown field",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32602,
                    message: "thread/turns/list: unknown field `sortDirection`"
                ),
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            ),
            Row(
                name: "method-prefixed itemsView field rejection",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32602,
                    message: "thread/turns/list: unknown field `itemsView`, expected one of `threadId`, `limit`"
                ),
                isUnsupportedMethod: false,
                isItemsViewRejection: true
            ),
            Row(
                name: "method-prefixed notLoaded variant rejection",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32602,
                    message: "thread/turns/list: unknown variant `notLoaded`, expected `summary` or `full`"
                ),
                isUnsupportedMethod: false,
                isItemsViewRejection: true
            ),
            Row(
                name: "notLoaded only in the expected list",
                error: requestFailure(
                    "thread/turns/list",
                    code: -32602,
                    message: "unknown variant `bogus`, expected one of `notLoaded`, `summary`"
                ),
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            ),
            Row(
                name: "thread status prose",
                error: requestFailure("thread/turns/list", code: nil, message: "thread is notLoaded"),
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            ),
            Row(
                name: "timeout",
                error: requestFailure("thread/turns/list", code: nil, message: "Request timed out after 15s"),
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            ),
            Row(
                name: "transport",
                error: CodexAppServerClient.ClientError.processNotRunning,
                isUnsupportedMethod: false,
                isItemsViewRejection: false
            )
        ]
        for row in rows {
            XCTAssertEqual(
                CodexNativeSessionController.isTurnsListUnsupportedError(row.error),
                row.isUnsupportedMethod,
                "\(row.name): unsupported method"
            )
            XCTAssertEqual(
                CodexNativeSessionController.isTurnsListItemsViewRejection(row.error),
                row.isItemsViewRejection,
                "\(row.name): itemsView rejection"
            )
        }
    }

    func testNotLoadedResumeIsReadyAndPreservesStatus() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/resume" else { return [:] }
            return threadResponse(status: ["type": "notLoaded"], turns: [])
        }
        let (controller, _) = await makeController(script: script)

        let ref = try await resume(controller)

        XCTAssertEqual(ref.conversationID, "saved-thread")
        XCTAssertEqual(script.methods, ["thread/resume", "thread/memoryMode/set"])
        XCTAssertTrue(controller.hasActiveThread)
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .notLoaded, "notLoaded must never be relabeled idle.")
        XCTAssertNil(controller.test_routingCurrentTurnID)
    }

    func testSystemErrorResumeThrowsTypedErrorWithSavedThreadIdentity() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/resume" else { return [:] }
            return threadResponse(status: ["type": "systemError"], turns: [])
        }
        let (controller, _) = await makeController(script: script)

        do {
            _ = try await resume(controller)
            XCTFail("Expected a system-error resume to throw")
        } catch let CodexSessionControllerError.threadInSystemErrorState(threadID) {
            XCTAssertEqual(threadID, "saved-thread")
        } catch {
            XCTFail("Expected threadInSystemErrorState, got \(error)")
        }
        XCTAssertEqual(script.methods, ["thread/resume"], "No turn listing or memory-mode call for a system-error thread.")
        XCTAssertFalse(controller.hasActiveThread, "The failed resume must not bind the thread.")
    }

    // MARK: - Cancellation before apply (Phase 3)

    func testCancellationBeforeApplyThrowsCancellationAndCancelsBinding() async throws {
        struct Row {
            let name: String
            let gatedMethod: String
            let resumes: Bool
            let expectedMethods: [String]
        }
        let rows = [
            Row(name: "after resume response", gatedMethod: "thread/resume", resumes: true, expectedMethods: ["thread/resume"]),
            Row(name: "after start response", gatedMethod: "thread/start", resumes: false, expectedMethods: ["thread/start"]),
            Row(
                name: "before apply",
                gatedMethod: "thread/memoryMode/set",
                resumes: true,
                expectedMethods: ["thread/resume", "thread/memoryMode/set"]
            )
        ]
        for row in rows {
            let gate = ResumeTestGate()
            let script = ResumeRequestScript { method, _, callIndex in
                // The first gated request answers successfully although the starting task was
                // cancelled while it was in flight: its response raced Stop.
                if method == row.gatedMethod, callIndex == 0 {
                    await gate.enterAndWait()
                }
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "idle"], turns: [])
                case "thread/start":
                    return threadResponse(id: "fresh-thread", status: ["type": "idle"], turns: nil)
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            var backgroundRetryThreadIDs: [String] = []
            controller.test_backgroundMemoryModeRetryObserver = { backgroundRetryThreadIDs.append($0) }

            let startup = Task { () -> CodexNativeSessionController.SessionRef in
                if row.resumes {
                    return try await self.resume(controller)
                }
                return try await controller.startOrResume(existing: nil, baseInstructions: "Agent")
            }
            await gate.waitUntilEntered()
            await controller.test_bufferNotificationDuringBinding(lifecycleNotification("turn/started", turnID: "turn-x"))
            XCTAssertTrue(controller.test_isBindingSession, row.name)
            XCTAssertEqual(controller.test_bufferedInboundCount, 1, row.name)
            startup.cancel()
            await gate.release()

            do {
                _ = try await startup.value
                XCTFail("\(row.name): expected the cancelled startup to throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("\(row.name): expected CancellationError, got \(error)")
            }
            XCTAssertEqual(script.methods, row.expectedMethods, "\(row.name): no RPC may follow the cancelled response")
            XCTAssertFalse(controller.hasActiveThread, row.name)
            XCTAssertNil(controller.lastKnownRuntimeStatus, "\(row.name): the snapshot must not be applied")
            XCTAssertFalse(controller.test_isBindingSession, "\(row.name): the binding window must be cancelled")
            XCTAssertEqual(controller.test_bufferedInboundCount, 0, "\(row.name): buffered inbound must be discarded")
            XCTAssertTrue(backgroundRetryThreadIDs.isEmpty, row.name)

            // The lifecycle returned to fresh, so the same controller can still resume.
            let ref = try await resume(controller)
            XCTAssertEqual(ref.conversationID, "saved-thread", row.name)
            XCTAssertTrue(controller.hasActiveThread, row.name)
            await controller.shutdown()
        }
    }

    func testMemoryModeCancellationIsRethrownWithoutRetryWhileFailureStillDegrades() async throws {
        struct Row {
            let name: String
            let cancelsStartup: Bool
        }
        for row in [Row(name: "cancelled", cancelsStartup: true), Row(name: "failed", cancelsStartup: false)] {
            let gate = ResumeTestGate()
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "idle"], turns: [])
                case "thread/memoryMode/set":
                    guard row.cancelsStartup else {
                        throw ResumeLifecycleTestError.memoryModeUnavailable
                    }
                    // The in-flight request observes the cancelled task, as a real request does.
                    await gate.enterAndWait()
                    try Task.checkCancellation()
                    return [:]
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            var backgroundRetryThreadIDs: [String] = []
            controller.test_backgroundMemoryModeRetryObserver = { backgroundRetryThreadIDs.append($0) }

            let startup = Task { try await self.resume(controller) }
            if row.cancelsStartup {
                await gate.waitUntilEntered()
                startup.cancel()
                await gate.release()
                do {
                    _ = try await startup.value
                    XCTFail("Expected the cancelled memory-mode request to fail startup")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    XCTFail("Expected CancellationError, got \(error)")
                }
                XCTAssertEqual(
                    script.requests("thread/memoryMode/set").count,
                    1,
                    "Cancellation is not a failed attempt and is not retried in the foreground."
                )
                XCTAssertTrue(backgroundRetryThreadIDs.isEmpty, "Cancellation must not schedule the background retry.")
                XCTAssertFalse(controller.hasActiveThread)
                XCTAssertFalse(controller.test_isBindingSession)
            } else {
                // Contrast: an ordinary failure keeps the optional-capability degradation.
                let ref = try await startup.value
                XCTAssertEqual(ref.conversationID, "saved-thread")
                XCTAssertTrue(controller.hasActiveThread)
                XCTAssertEqual(script.requests("thread/memoryMode/set").count, 2)
                XCTAssertEqual(backgroundRetryThreadIDs, ["saved-thread"])
            }
            await controller.shutdown()
        }
    }

    func testCancelledStartupCancelsBindingAfterWaitingForContendedEventMutex() async throws {
        struct Row {
            let name: String
            let gatedMethod: String
            let cancelsWhileApplyWaitsForLock: Bool
            let expectedMethods: [String]
        }
        let rows = [
            Row(
                name: "cancelled after resume response",
                gatedMethod: "thread/resume",
                cancelsWhileApplyWaitsForLock: false,
                expectedMethods: ["thread/resume"]
            ),
            Row(
                name: "cancelled while apply waits for the lock",
                gatedMethod: "thread/memoryMode/set",
                cancelsWhileApplyWaitsForLock: true,
                expectedMethods: ["thread/resume", "thread/memoryMode/set"]
            )
        ]
        for row in rows {
            let requestGate = ResumeTestGate()
            let script = ResumeRequestScript { method, _, callIndex in
                if method == row.gatedMethod, callIndex == 0 {
                    await requestGate.enterAndWait()
                }
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "idle"], turns: [])
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            var backgroundRetryThreadIDs: [String] = []
            controller.test_backgroundMemoryModeRetryObserver = { backgroundRetryThreadIDs.append($0) }
            let cleanupStarted = ResumeTestFlag()
            controller.test_bindingCleanupObserver = { cleanupStarted.set() }

            let startup = Task { try await self.resume(controller) }
            let startupFinished = ResumeTestFlag()
            let startupWatcher = Task {
                _ = await startup.result
                startupFinished.set()
            }
            await requestGate.waitUntilEntered()
            await controller.test_bufferNotificationDuringBinding(lifecycleNotification("turn/started", turnID: "turn-x"))
            XCTAssertTrue(controller.test_isBindingSession, row.name)
            XCTAssertEqual(controller.test_bufferedInboundCount, 1, row.name)

            // Another task holds the event mutex for the rest of the startup.
            let holderGate = ResumeTestGate()
            let holder = Task {
                await controller.test_holdEventHandlingMutex { await holderGate.enterAndWait() }
            }
            await holderGate.waitUntilEntered()

            if row.cancelsWhileApplyWaitsForLock {
                await requestGate.release()
                let applyQueued = await waitForCondition {
                    await controller.test_eventHandlingMutexWaiterCount == 1
                }
                XCTAssertTrue(applyQueued, "\(row.name): the apply step must queue behind the holder")
                startup.cancel()
            } else {
                startup.cancel()
                await requestGate.release()
            }

            // Release the holder only once the binding cleanup is queued behind it (or startup has
            // already finished, which happens only if the cleanup gave up on the contended lock).
            let cleanupQueuedOrStartupFinished = await waitForCondition {
                if startupFinished.isSet { return true }
                guard cleanupStarted.isSet else { return false }
                return await controller.test_eventHandlingMutexWaiterCount >= 1
            }
            XCTAssertTrue(cleanupQueuedOrStartupFinished, row.name)
            XCTAssertFalse(startupFinished.isSet, "\(row.name): startup must wait for its binding cleanup")
            XCTAssertTrue(cleanupStarted.isSet, row.name)
            let queuedWaiterCount = await controller.test_eventHandlingMutexWaiterCount
            XCTAssertEqual(queuedWaiterCount, 1, "\(row.name): only the binding cleanup waits for the lock")
            XCTAssertTrue(controller.test_isBindingSession, "\(row.name): cleanup cannot run while the lock is held")
            await holderGate.release()
            await holder.value

            do {
                _ = try await startup.value
                XCTFail("\(row.name): expected the cancelled startup to throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("\(row.name): expected CancellationError, got \(error)")
            }
            await startupWatcher.value
            XCTAssertEqual(script.methods, row.expectedMethods, row.name)
            XCTAssertFalse(controller.hasActiveThread, row.name)
            XCTAssertNil(controller.lastKnownRuntimeStatus, "\(row.name): the snapshot must not be applied")
            XCTAssertFalse(controller.test_isBindingSession, "\(row.name): the binding window must close after the lock frees")
            XCTAssertEqual(controller.test_bufferedInboundCount, 0, "\(row.name): buffered inbound must be discarded")
            XCTAssertTrue(backgroundRetryThreadIDs.isEmpty, row.name)

            let ref = try await resume(controller)
            XCTAssertEqual(ref.conversationID, "saved-thread", row.name)
            XCTAssertTrue(controller.hasActiveThread, row.name)
            await controller.shutdown()
        }
    }

    func testStopDuringRealResumeRequestSettlesAsCancellationBeforeShutdownCanFailIt() async throws {
        struct Row {
            let name: String
            let cancelsBeforeShutdown: Bool
        }
        let rows = [
            Row(name: "Stop: cancel the task, then shut the controller down", cancelsBeforeShutdown: true),
            Row(name: "contrast: controller shutdown without cancellation", cancelsBeforeShutdown: false)
        ]
        for row in rows {
            // Several fresh pairs cover executor interleavings between the request's cancellation
            // handler and the shutdown that fails every still-pending request.
            for iteration in 0 ..< 10 {
                let label = "\(row.name) #\(iteration)"
                let (controller, client) = await makeRealTransportController()
                let startup = Task { try await self.resume(controller) }
                let requestPending = await waitForCondition { await client.debugPendingRequestCount() == 1 }
                XCTAssertTrue(requestPending, "\(label): thread/resume must be pending on the real client")
                if row.cancelsBeforeShutdown {
                    // Stop's order: cancel the run task, then shut the detached controller down.
                    startup.cancel()
                }
                await controller.shutdown()
                do {
                    _ = try await startup.value
                    XCTFail("\(label): expected the pending resume to fail")
                } catch is CancellationError {
                    XCTAssertTrue(row.cancelsBeforeShutdown, "\(label): only Stop's cancellation may settle quietly")
                } catch {
                    XCTAssertFalse(
                        row.cancelsBeforeShutdown,
                        "\(label): Stop must settle as CancellationError before shutdown fails the request, got \(error)"
                    )
                }
                let pendingAfter = await client.debugPendingRequestCount()
                XCTAssertEqual(pendingAfter, 0, label)
                XCTAssertFalse(controller.hasActiveThread, label)
                XCTAssertFalse(controller.test_isBindingSession, label)
            }
        }
    }

    func testCancelledStartOrResumeEntryMakesNoRequestOrBinding() async throws {
        struct Row {
            let name: String
            let existing: CodexNativeSessionController.SessionRef?
            let shutsDownFirst: Bool
        }
        let savedThread = CodexNativeSessionController.SessionRef(
            conversationID: "saved-thread",
            rolloutPath: "/tmp/saved-thread.jsonl",
            model: nil,
            reasoningEffort: nil
        )
        let rows = [
            // The missing-rollout fallback's fresh start, reached after Stop.
            Row(name: "fresh start on a cancelled task", existing: nil, shutsDownFirst: false),
            Row(name: "resume on a cancelled task", existing: savedThread, shutsDownFirst: false),
            // Stop's teardown already shut the controller down; this must not fail as a lifecycle error.
            Row(name: "fresh start after Stop shut the controller down", existing: nil, shutsDownFirst: true)
        ]
        for row in rows {
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/resume", "thread/start":
                    threadResponse(status: ["type": "idle"], turns: [])
                default:
                    [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            if row.shutsDownFirst {
                await controller.shutdown()
            }
            let existing = row.existing
            let attempt = Task { () async throws -> CodexNativeSessionController.SessionRef in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await controller.startOrResume(existing: existing, baseInstructions: "Agent")
            }
            do {
                _ = try await attempt.value
                XCTFail("\(row.name): expected the cancelled call to throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("\(row.name): expected CancellationError, got \(error)")
            }
            XCTAssertEqual(script.methods, [], "\(row.name): no RPC after cancellation")
            XCTAssertFalse(controller.test_isBindingSession, row.name)
            XCTAssertFalse(controller.hasActiveThread, row.name)
            await controller.shutdown()
        }
    }

    func testStopDuringStartupTurnListingSendsNoMemoryModeRequest() async throws {
        struct Row {
            let name: String
            let listingFails: Bool
        }
        let rows = [
            Row(name: "turn listing succeeds after Stop", listingFails: false),
            // A non-transport failure normally degrades to an unresolved identity and continues.
            Row(name: "turn listing degrades after Stop", listingFails: true)
        ]
        for row in rows {
            let listGate = ResumeTestGate()
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/resume":
                    return threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
                case "thread/turns/list":
                    await listGate.enterAndWait()
                    if row.listingFails {
                        throw ResumeLifecycleTestError.resumeUnavailable
                    }
                    return ["data": []]
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            var backgroundRetryThreadIDs: [String] = []
            controller.test_backgroundMemoryModeRetryObserver = { backgroundRetryThreadIDs.append($0) }
            let startup = Task { try await self.resume(controller) }
            await listGate.waitUntilEntered()
            startup.cancel()
            await listGate.release()
            do {
                _ = try await startup.value
                XCTFail("\(row.name): expected the cancelled startup to throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("\(row.name): expected CancellationError, got \(error)")
            }
            XCTAssertEqual(script.methods, ["thread/resume", "thread/turns/list"], row.name)
            XCTAssertFalse(controller.hasActiveThread, row.name)
            XCTAssertNil(controller.lastKnownRuntimeStatus, row.name)
            XCTAssertFalse(controller.test_isBindingSession, row.name)
            XCTAssertTrue(backgroundRetryThreadIDs.isEmpty, row.name)
            await controller.shutdown()
        }
    }

    func testThreadStatusNotificationUpdatesLastKnownRuntimeStatus() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/resume" else { return [:] }
            return threadResponse(status: ["type": "idle"], turns: [])
        }
        let (controller, _) = await makeController(script: script)
        _ = try await resume(controller)
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .idle)

        await controller.test_handleNotification(
            method: "thread/status/changed",
            params: [
                "threadId": .string("saved-thread"),
                "status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([.string("waitingOnApproval")])
                ])
            ]
        )
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .active(activeFlags: ["waitingOnApproval"]))

        await controller.test_handleNotification(
            method: "thread/status/changed",
            params: [
                "threadId": .string("other-thread"),
                "status": .object(["type": .string("idle")])
            ]
        )
        XCTAssertEqual(
            controller.lastKnownRuntimeStatus,
            .active(activeFlags: ["waitingOnApproval"]),
            "Another thread's status must not overwrite this thread's status."
        )
    }

    func testBufferedStartAndCompletionReplayedOverCompletedListingLeaveTurnInactive() async throws {
        let box = ControllerBox()
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                return threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
            case "thread/turns/list":
                // Both lifecycle notifications arrive while the listing RPC is in flight.
                await box.controller?.test_bufferNotificationDuringBinding(lifecycleNotification("turn/started", turnID: "turn-x"))
                await box.controller?.test_bufferNotificationDuringBinding(
                    lifecycleNotification("turn/completed", turnID: "turn-x", status: "completed")
                )
                return ["data": [["id": "turn-x", "status": "completed", "items": []]]]
            default:
                return [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        box.controller = controller

        _ = try await resume(controller)

        XCTAssertTrue(controller.test_activeTurnIDs.isEmpty)
        XCTAssertNil(controller.test_routingCurrentTurnID)
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
        let lifecycle = await finishAndReadEvents(from: controller).compactMap(lifecycleSummary)
        XCTAssertEqual(lifecycle, ["started:turn-x", "completed:turn-x"])
    }

    func testCompletionDeliveredAfterApplyConvergesToInactiveWithoutDispatchingATurn() async throws {
        let box = ControllerBox()
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                return threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
            case "thread/turns/list":
                // Only the start is buffered; the completion lands after apply/drain (§8.6).
                await box.controller?.test_bufferNotificationDuringBinding(lifecycleNotification("turn/started", turnID: "turn-x"))
                return ["data": [["id": "turn-x", "status": "completed", "items": []]]]
            default:
                return [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        box.controller = controller

        _ = try await resume(controller)

        // Brief, accepted reactivation from the replayed start.
        XCTAssertEqual(controller.test_activeTurnIDs, ["turn-x"])
        XCTAssertEqual(controller.test_authoritativeLifecycleTurnID, "turn-x")

        await controller.test_handleNotification(
            method: "turn/completed",
            params: [
                "threadId": .string("saved-thread"),
                "turn": .object(["id": .string("turn-x"), "status": .string("completed")])
            ]
        )

        XCTAssertTrue(controller.test_activeTurnIDs.isEmpty)
        XCTAssertNil(controller.test_routingCurrentTurnID)
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
        XCTAssertFalse(script.methods.contains("turn/start"), "No turn may be dispatched in the window.")
        let lifecycle = await finishAndReadEvents(from: controller).compactMap(lifecycleSummary)
        XCTAssertEqual(lifecycle, ["started:turn-x", "completed:turn-x"])
    }

    // MARK: - Bounded readThreadSnapshot

    func testReadThreadSnapshotIdleShortCircuitsWithoutListing() async throws {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/read" else { return [:] }
            return threadResponse(id: "thread-1", status: ["type": "idle"], turns: nil)
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1")

        let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)

        XCTAssertEqual(snapshot.runtimeStatus, .idle)
        XCTAssertTrue(snapshot.activeTurnIDs.isEmpty)
        XCTAssertEqual(script.methods, ["thread/read"])
        let read = try XCTUnwrap(script.requests("thread/read").first)
        XCTAssertEqual(read.params["includeTurns"] as? Bool, false)
        XCTAssertEqual(read.timeout, 2)
    }

    func testReadThreadSnapshotListsNewestTurnWhenActive() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/read":
                threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                ["data": [["id": "turn-live", "status": "inProgress", "items": []]]]
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1")

        let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)

        XCTAssertEqual(snapshot.currentTurnID, "turn-live")
        XCTAssertEqual(snapshot.activeTurnIDs, ["turn-live"])
        XCTAssertEqual(script.methods, ["thread/read", "thread/turns/list"])
        let list = try XCTUnwrap(script.requests("thread/turns/list").first)
        XCTAssertEqual(list.params["limit"] as? Int, 1)
        XCTAssertEqual(list.params["sortDirection"] as? String, "desc")
        XCTAssertEqual(list.params["itemsView"] as? String, "notLoaded")
        XCTAssertEqual(list.timeout, 2, "The caller's timeout bounds the listing.")
        XCTAssertEqual(controller.test_turnsListSupport, .supported)

        let metadataOnly = try await controller.readThreadSnapshot(includeTurns: false, timeout: 2)
        XCTAssertTrue(metadataOnly.activeTurnIDs.isEmpty)
        XCTAssertEqual(script.methods, ["thread/read", "thread/turns/list", "thread/read"])
    }

    func testReadThreadSnapshotFallsBackToFullReadOnceWhenTurnListUnsupportedThenUsesMemo() async throws {
        let script = ResumeRequestScript { method, params, _ in
            switch method {
            case "thread/read":
                if params["includeTurns"] as? Bool == true {
                    return threadResponse(
                        id: "thread-1",
                        status: ["type": "active", "activeFlags": []],
                        turns: [["id": "turn-legacy", "status": "inProgress", "items": []]]
                    )
                }
                return threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                throw requestFailure("thread/turns/list", code: -32601, message: "Method not found")
            default:
                return [:]
            }
        }
        let (controller, client) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1")

        let first = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
        XCTAssertEqual(first.activeTurnIDs, ["turn-legacy"])
        XCTAssertEqual(script.methods, ["thread/read", "thread/turns/list", "thread/read"])
        XCTAssertEqual(script.requests("thread/read").map { $0.params["includeTurns"] as? Bool }, [false, true])
        XCTAssertEqual(controller.test_turnsListSupport, .unsupported)

        let second = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
        XCTAssertEqual(second.activeTurnIDs, ["turn-legacy"])
        XCTAssertEqual(
            script.methods,
            ["thread/read", "thread/turns/list", "thread/read", "thread/read", "thread/read"],
            "The unsupported memo skips the listing on later calls."
        )

        await client.debugInstallTestTransport()
        _ = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
        XCTAssertEqual(
            script.requests("thread/turns/list").count,
            2,
            "A new transport generation probes thread/turns/list again."
        )
    }

    func testReadThreadSnapshotRetriesListingWithoutItemsViewWhenRejected() async throws {
        let script = ResumeRequestScript { method, params, _ in
            switch method {
            case "thread/read":
                return threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                if params["itemsView"] != nil {
                    throw requestFailure(
                        "thread/turns/list",
                        code: -32602,
                        message: "unknown variant `notLoaded`, expected `summary` or `full` for itemsView"
                    )
                }
                return ["data": [["id": "turn-live", "status": "inProgress", "items": []]]]
            default:
                return [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1")

        let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)

        XCTAssertEqual(snapshot.activeTurnIDs, ["turn-live"])
        var lists = script.requests("thread/turns/list")
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists.first?.params["itemsView"] as? String, "notLoaded")
        XCTAssertNil(lists.last?.params["itemsView"])
        XCTAssertEqual(lists.last?.params["limit"] as? Int, 1)
        XCTAssertEqual(controller.test_turnsListSupport, .supported)

        _ = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
        lists = script.requests("thread/turns/list")
        XCTAssertEqual(lists.count, 3, "The itemsView memo skips the rejected shape on later calls.")
        XCTAssertNil(lists.last?.params["itemsView"])
    }

    func testReadThreadSnapshotPropagatesOtherListingErrors() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/read":
                return threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                throw requestFailure("thread/turns/list", code: nil, message: "Request timed out after 2s")
            default:
                return [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1")

        do {
            _ = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
            XCTFail("Expected the listing timeout to propagate")
        } catch {
            XCTAssertTrue(CodexAppServerClient.isTimeoutError(error))
        }
        XCTAssertEqual(script.methods, ["thread/read", "thread/turns/list"], "No legacy full read for other errors.")
        XCTAssertEqual(controller.test_turnsListSupport, .unknown)
    }

    // MARK: - Interrupt and live refresh

    func testInterruptAfterActiveResumeTargetsListedTurn() async throws {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/resume":
                threadResponse(status: ["type": "active", "activeFlags": []], turns: [])
            case "thread/read":
                threadResponse(status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                ["data": [["id": "turn-live", "status": "inProgress", "items": []]]]
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        _ = try await resume(controller)

        let receipt = try await controller.reconcileAndInterruptCurrentTurn()

        XCTAssertEqual(receipt.interruptedTurnID, "turn-live")
        let interrupt = try XCTUnwrap(script.requests("turn/interrupt").first)
        XCTAssertEqual(interrupt.params["turnId"] as? String, "turn-live")
        XCTAssertEqual(interrupt.params["threadId"] as? String, "saved-thread")
        XCTAssertNil(controller.test_authoritativeLifecycleTurnID)
    }

    func testLiveRefreshAppliesSnapshotWhenNotSuperseded() async {
        let script = ResumeRequestScript { method, _, _ in
            switch method {
            case "thread/read":
                threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
            case "thread/turns/list":
                ["data": [["id": "turn-live", "status": "inProgress", "items": []]]]
            default:
                [:]
            }
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1", routingTurnID: "turn-old")

        let result = await controller.test_refreshActiveTurnForInterruptIfPossible()

        XCTAssertEqual(result, .refreshed("turn-live"))
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-live")
        XCTAssertEqual(controller.lastKnownRuntimeStatus, .active(activeFlags: []))
    }

    func testLiveRefreshFailureWithoutSupersessionReportsFailed() async {
        let script = ResumeRequestScript { method, _, _ in
            guard method == "thread/read" else { return [:] }
            throw requestFailure("thread/read", code: nil, message: "Request timed out after 5s")
        }
        let (controller, _) = await makeController(script: script)
        controller.test_installThreadState(threadID: "thread-1", routingTurnID: "turn-old")

        let result = await controller.test_refreshActiveTurnForInterruptIfPossible()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(controller.test_routingCurrentTurnID, "turn-old")
    }

    func testLiveRefreshSupersededByLifecycleNotificationKeepsLiveRoutingAndNeverFails() async {
        struct Row {
            let name: String
            let readFails: Bool
        }
        for row in [Row(name: "stale snapshot", readFails: false), Row(name: "read error", readFails: true)] {
            let gate = ResumeTestGate()
            let script = ResumeRequestScript { method, _, _ in
                switch method {
                case "thread/read":
                    await gate.enterAndWait()
                    if row.readFails {
                        throw requestFailure("thread/read", code: nil, message: "Request timed out after 5s")
                    }
                    return threadResponse(id: "thread-1", status: ["type": "active", "activeFlags": []], turns: nil)
                case "thread/turns/list":
                    // Stale view: still reports the turn that completed during the read.
                    return ["data": [["id": "turn-old", "status": "inProgress", "items": []]]]
                default:
                    return [:]
                }
            }
            let (controller, _) = await makeController(script: script)
            controller.test_installThreadState(threadID: "thread-1", routingTurnID: "turn-old")

            let refresh = Task { await controller.test_refreshActiveTurnForInterruptIfPossible() }
            await gate.waitUntilEntered()
            await controller.test_handleNotification(
                method: "turn/completed",
                params: [
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-old"), "status": .string("completed")])
                ]
            )
            await gate.release()
            let result = await refresh.value

            XCTAssertEqual(result, .refreshed(nil), row.name)
            XCTAssertNil(controller.test_routingCurrentTurnID, "\(row.name): routing must not be clobbered")
            XCTAssertFalse(controller.test_activeTurnIDs.contains("turn-old"), row.name)
            XCTAssertNil(
                CodexNativeSessionController.resolvedInterruptTurnID(cachedTurnID: "turn-old", refreshResult: result),
                "\(row.name): the cached turn ID must not be revived"
            )
        }
    }

    // MARK: - Helpers

    private func makeController(
        script: ResumeRequestScript,
        requestTimeout: TimeInterval? = 30
    ) async -> (CodexNativeSessionController, CodexAppServerClient) {
        let client = CodexAppServerClient(livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let options = CodexNativeSessionController.Options(
            requestTimeout: requestTimeout,
            configOverridesProvider: { [:] },
            launchEnvironmentProvider: { [:] },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            authTokensRefreshHandler: nil
        )
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            options: options,
            requestExecutor: { method, params, timeout in
                try await script.handle(method: method, params: params, timeout: timeout)
            }
        )
        return (controller, client)
    }

    /// A controller whose requests go through the real `CodexAppServerClient` request path over
    /// the debug test transport, and which stops that client on shutdown as Agent Mode does. Frames
    /// are accepted without a reader (the debug transport has none), so requests stay pending.
    private func makeRealTransportController() async -> (CodexNativeSessionController, CodexAppServerClient) {
        let client = CodexAppServerClient(writeFrameHandler: { _, _ in }, livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let options = CodexNativeSessionController.Options(
            requestTimeout: 30,
            configOverridesProvider: { [:] },
            launchEnvironmentProvider: { [:] },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            authTokensRefreshHandler: nil
        )
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            options: options,
            clientShutdownBehavior: .stopOnShutdown
        )
        return (controller, client)
    }

    private func resume(_ controller: CodexNativeSessionController) async throws -> CodexNativeSessionController.SessionRef {
        try await controller.startOrResume(
            existing: .init(
                conversationID: "saved-thread",
                rolloutPath: "/tmp/saved-thread.jsonl",
                model: nil,
                reasoningEffort: nil
            ),
            baseInstructions: "Agent"
        )
    }

    /// Polls `condition` until it holds or about five seconds pass.
    private func waitForCondition(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 5000 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func assertResumeUnavailable(
        _ controller: CodexNativeSessionController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await resume(controller)
            XCTFail("Expected resume to fail", file: file, line: line)
        } catch ResumeLifecycleTestError.resumeUnavailable {
            return
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func finishAndReadEvents(
        from controller: CodexNativeSessionController
    ) async -> [CodexNativeSessionController.Event] {
        await controller.shutdown()
        var events: [CodexNativeSessionController.Event] = []
        for await event in controller.events {
            events.append(event)
        }
        return events
    }
}

private func lifecycleSummary(_ event: CodexNativeSessionController.Event) -> String? {
    switch event {
    case let .turnStarted(turnID):
        "started:\(turnID ?? "nil")"
    case let .turnCompleted(turnID, _, _):
        "completed:\(turnID ?? "nil")"
    default:
        nil
    }
}

private func threadResponse(
    id: String = "saved-thread",
    status: [String: Any],
    turns: [[String: Any]]?
) -> [String: Any] {
    var thread: [String: Any] = [
        "id": id,
        "path": "/tmp/\(id).jsonl",
        "status": status
    ]
    if let turns {
        thread["turns"] = turns
    }
    return ["thread": thread]
}

private func requestFailure(_ method: String, code: Int?, message: String) -> Error {
    CodexAppServerClient.ClientError.requestFailed(
        .init(method: method, code: code, message: message, data: nil)
    )
}

private func lifecycleNotification(
    _ method: String,
    turnID: String,
    status: String? = nil
) -> CodexAppServerClient.Notification {
    var turn: [String: CodexJSONValue] = ["id": .string(turnID)]
    if let status {
        turn["status"] = .string(status)
    }
    return .init(
        method: method,
        params: [
            "threadId": .string("saved-thread"),
            "turn": .object(turn)
        ]
    )
}

private enum ResumeLifecycleTestError: Error {
    case resumeUnavailable
    case memoryModeUnavailable
}

private final class ControllerBox: @unchecked Sendable {
    weak var controller: CodexNativeSessionController?
}

/// Records every request routed through the controller's injectable request boundary and
/// answers it from a scripted responder (`callIndex` counts prior calls of the same method).
private final class ResumeRequestScript: @unchecked Sendable {
    struct Request {
        let method: String
        let params: [String: Any]
        let timeout: TimeInterval?
    }

    typealias Responder = @Sendable (
        _ method: String,
        _ params: [String: Any],
        _ callIndex: Int
    ) async throws -> [String: Any]

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var callCounts: [String: Int] = [:]
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func handle(method: String, params: [String: Any]?, timeout: TimeInterval?) async throws -> [String: Any] {
        let params = params ?? [:]
        lock.lock()
        recorded.append(Request(method: method, params: params, timeout: timeout))
        let callIndex = callCounts[method, default: 0]
        callCounts[method] = callIndex + 1
        lock.unlock()
        return try await responder(method, params, callIndex)
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.method)
    }

    func requests(_ method: String) -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.method == method }
    }
}

private final class ResumeTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor ResumeTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
