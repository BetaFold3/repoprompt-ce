import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class RemoteCommandTranslatorTests: XCTestCase {
    func testTableDrivenMappings() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let cases: [(RemoteClientFrame, String, String, [String: Value])] = [
            (
                RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "model_id": .string("pair")])),
                "agent_run",
                "start",
                ["message": .string("go"), "model_id": .string("pair")]
            ),
            (
                RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sid, payload: .object(["message": .string("next"), "wait": .bool(true)])),
                "agent_run",
                "steer",
                ["session_id": .string(sid), "message": .string("next"), "wait": .bool(true)]
            ),
            (
                RemoteClientFrame(type: "respond", requestID: "r3", sessionID: sid, payload: .object(["interaction_id": .string("22222222-2222-2222-2222-222222222222"), "response": .string("yes")])),
                "agent_run",
                "respond",
                ["session_id": .string(sid), "interaction_id": .string("22222222-2222-2222-2222-222222222222"), "response": .string("yes")]
            ),
            (
                RemoteClientFrame(type: "cancel", requestID: "r4", sessionID: sid, payload: .object([:])),
                "agent_run",
                "cancel",
                ["session_id": .string(sid)]
            ),
            (
                RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:])),
                "agent_run",
                "poll",
                ["session_id": .string(sid)]
            ),
            (
                RemoteClientFrame(type: "list_agents", requestID: "req-list-agents", payload: .object([:])),
                "agent_manage",
                "list_agents",
                [:]
            ),
            (
                RemoteClientFrame(type: "list_sessions", payload: .object(["limit": .int(5)])),
                "agent_manage",
                "list_sessions",
                ["limit": .int(5)]
            ),
            (
                RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object(["offset": .int(2), "limit": .int(3)])),
                "agent_manage",
                "get_log",
                ["session_id": .string(sid), "offset": .int(2), "limit": .int(3)]
            )
        ]

        let translator = RemoteCommandTranslator()
        for (frame, expectedTool, expectedOp, expectedArgs) in cases {
            let call = try translator.translate(frame)
            XCTAssertEqual(call.toolName, expectedTool)
            XCTAssertEqual(call.arguments["op"], .string(expectedOp))
            XCTAssertEqual(call.arguments["_rawJSON"], .bool(true))
            for (key, value) in expectedArgs {
                XCTAssertEqual(call.arguments[key], value, "\(frame.type).\(key)")
            }
        }
    }

    func testRejectsArbitraryToolPassthrough() throws {
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object(["tool_name": .string("read_file"), "message": .string("go")])
        )
        XCTAssertThrowsError(try RemoteCommandTranslator().translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .arbitraryToolPassthroughRejected)
        }
    }

    func testListAgentsRejectsRemotePayloadKeys() throws {
        let frame = RemoteClientFrame(
            type: "list_agents",
            requestID: "req-list-agents",
            payload: .object(["roles_only": .bool(true)])
        )
        XCTAssertThrowsError(try RemoteCommandTranslator().translate(frame)) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "list_agents", key: "roles_only")
            )
        }
    }

    func testAmbiguousStartTargetReturnsStructuredError() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go")]))
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testBindingRequiredAppliesToAllOps() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))
        let frame = RemoteClientFrame(type: "list_sessions")
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    // MARK: - Plan §6.1: request_id forwarding to the app idempotency registry

    func testForwardsRequestIDForMutatingOpsOnly() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()

        let start = try translator.translate(
            RemoteClientFrame(type: "start", requestID: "req-start", payload: .object(["message": .string("go")]))
        )
        XCTAssertEqual(start.arguments["request_id"], .string("req-start"))

        let steer = try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "req-steer", sessionID: sid, payload: .object(["message": .string("next")]))
        )
        XCTAssertEqual(steer.arguments["request_id"], .string("req-steer"))

        let respond = try translator.translate(
            RemoteClientFrame(
                type: "respond",
                requestID: "req-respond",
                sessionID: sid,
                payload: .object(["interaction_id": .string(sid), "response": .string("yes")])
            )
        )
        XCTAssertEqual(respond.arguments["request_id"], .string("req-respond"))

        let cancel = try translator.translate(
            RemoteClientFrame(type: "cancel", requestID: "req-cancel", sessionID: sid, payload: .object([:]))
        )
        XCTAssertNil(cancel.arguments["request_id"], "Non-idempotent-registry ops must not forward request_id")

        let poll = try translator.translate(
            RemoteClientFrame(type: "poll", requestID: "req-poll", sessionID: sid, payload: .object([:]))
        )
        XCTAssertNil(poll.arguments["request_id"])
    }

    // MARK: - Plan §6.6: explicit multi-window start selector

    func testStartWindowSelectorMapsToHiddenWindowIDOverride() throws {
        let translator = RemoteCommandTranslator()

        let intSelector = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(3)])
            )
        )
        XCTAssertEqual(intSelector.arguments["_windowID"], .int(3))
        XCTAssertNil(intSelector.arguments["window_id"], "window_id is consumed into the routing override")

        let stringSelector = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r2",
                payload: .object(["message": .string("go"), "window_id": .string("7")])
            )
        )
        XCTAssertEqual(stringSelector.arguments["_windowID"], .int(7))
    }

    func testStartWindowSelectorRejectsNonIntegerValues() throws {
        let translator = RemoteCommandTranslator()
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object(["message": .string("go"), "window_id": .string("main")])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            guard case .invalidPayload = error as? RemoteCommandTranslatorError else {
                return XCTFail("Expected invalidPayload, got \(error)")
            }
        }
    }

    func testStartWorkspaceSelectorPassesThroughForAppSideValidation() throws {
        let translator = RemoteCommandTranslator()
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "workspace_id": .string("33333333-3333-3333-3333-333333333333")
                ])
            )
        )
        XCTAssertEqual(call.arguments["workspace_id"], .string("33333333-3333-3333-3333-333333333333"))
    }

    func testStartWorkspaceNameIsAcceptedButConsumedByGateway() throws {
        let translator = RemoteCommandTranslator()
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "workspace_name": .string("Workspace A")
                ])
            )
        )
        XCTAssertNil(call.arguments["workspace_name"])
        XCTAssertNil(call.arguments["_windowID"])

        let ambiguousTranslator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        XCTAssertThrowsError(try ambiguousTranslator.translate(RemoteClientFrame(
            type: "start",
            requestID: "r2",
            payload: .object([
                "message": .string("go"),
                "workspace_name": .string("Workspace A")
            ])
        ))) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testWorkspaceSelectorAloneDoesNotBypassAmbiguousStartTarget() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object([
                "message": .string("go"),
                "workspace_id": .string("33333333-3333-3333-3333-333333333333")
            ])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testWorkspaceSelectorAloneDoesNotBypassBindingRequired() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object([
                "message": .string("go"),
                "workspace_id": .string("33333333-3333-3333-3333-333333333333")
            ])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    func testWindowAndWorkspaceSelectorsBypassAmbiguousStartTarget() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "window_id": .int(2),
                    "workspace_id": .string("33333333-3333-3333-3333-333333333333")
                ])
            )
        )
        XCTAssertEqual(call.arguments["_windowID"], .int(2))
        XCTAssertEqual(call.arguments["workspace_id"], .string("33333333-3333-3333-3333-333333333333"))
    }

    func testExplicitSelectorBypassesAmbiguousStartTargetForStart() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            )
        )
        XCTAssertEqual(call.arguments["_windowID"], .int(2))
        XCTAssertEqual(call.arguments["op"], .string("start"))
    }

    func testExplicitSelectorBypassesBindingRequiredForStartOnly() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))

        let start = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            )
        )
        XCTAssertEqual(start.arguments["_windowID"], .int(2))

        let sid = "11111111-1111-1111-1111-111111111111"
        let observationOps: [RemoteClientFrame] = [
            RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(
                type: "respond",
                requestID: "r2",
                sessionID: sid,
                payload: .object(["interaction_id": .string(sid), "response": .string("yes")])
            ),
            RemoteClientFrame(type: "list_sessions")
        ]
        for frame in observationOps {
            XCTAssertThrowsError(try translator.translate(frame), frame.type) { error in
                XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"), frame.type)
            }
        }
    }

    func testResolvedWindowBypassesBindingRequiredForSessionAddressedOps() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))

        let steer = try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sid, payload: .object(["message": .string("next")])),
            resolvedWindowID: 9
        )
        XCTAssertEqual(steer.arguments["_windowID"], .int(9))
        XCTAssertEqual(steer.arguments["session_id"], .string(sid))

        let getLog = try translator.translate(
            RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object([:])),
            resolvedWindowID: 9
        )
        XCTAssertEqual(getLog.toolName, "agent_manage")
        XCTAssertEqual(getLog.arguments["_windowID"], .int(9))

        XCTAssertThrowsError(try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sid, payload: .object(["message": .string("next")]))
        )) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    func testAmbiguousStartTargetRefusesNonStartOpsWithBindingRequired() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(type: "list_sessions")
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("multiple windows"))
        }
    }

    func testListAgentsWithResolvedWindowBypassesBindingGateAndInjectsWindowID() throws {
        let frame = RemoteClientFrame(type: "list_agents", requestID: "req-list-agents")

        for bindingState in [
            RemoteGatewayBindingState.bindingRequired("bind first"),
            RemoteGatewayBindingState.ambiguousStartTarget("multiple windows")
        ] {
            let translator = RemoteCommandTranslator(bindingState: bindingState)
            let call = try translator.translate(frame, resolvedWindowID: 7)

            XCTAssertEqual(call.toolName, "agent_manage")
            XCTAssertEqual(call.arguments["op"], .string("list_agents"))
            XCTAssertEqual(call.arguments["_windowID"], .int(7))
        }
    }

    func testListAgentsWithoutResolvedWindowStillRequiresBinding() throws {
        let frame = RemoteClientFrame(type: "list_agents", requestID: "req-list-agents")

        XCTAssertThrowsError(try RemoteCommandTranslator(bindingState: .bindingRequired("bind first")).translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
        XCTAssertThrowsError(try RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows")).translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("multiple windows"))
        }
    }

    func testTranslatedToolCallsCarryAppLinkTimeoutPolicy() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()

        let fastFrames = [
            RemoteClientFrame(type: "cancel", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(type: "list_agents", payload: .object([:])),
            RemoteClientFrame(type: "list_sessions", payload: .object([:]))
        ]
        for frame in fastFrames {
            XCTAssertEqual(try translator.translate(frame).timeout, 60, frame.type)
        }

        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "poll", sessionID: sid, payload: .object(["timeout": .int(120)]))
            ).timeout,
            150
        )
        XCTAssertEqual(
            try translator.translate(RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:]))).timeout,
            60
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(
                    type: "steer",
                    sessionID: sid,
                    payload: .object(["message": .string("next"), "wait": .bool(true), "timeout_seconds": .int(300)])
                )
            ).timeout,
            330
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "steer", sessionID: sid, payload: .object(["message": .string("next")]))
            ).timeout,
            60
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "start", payload: .object(["message": .string("go"), "timeout": .int(60)]))
            ).timeout,
            90
        )
        XCTAssertEqual(
            try translator.translate(RemoteClientFrame(type: "start", payload: .object(["message": .string("go")]))).timeout,
            150
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "start", payload: .object(["message": .string("go"), "timeout": .int(10000)]))
            ).timeout,
            900
        )
    }
}
