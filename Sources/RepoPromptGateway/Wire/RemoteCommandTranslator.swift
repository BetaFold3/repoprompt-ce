import Foundation
import MCP
import RepoPromptRemoteWire

struct RemoteToolCall: Equatable {
    let toolName: String
    let arguments: [String: Value]
    let timeout: TimeInterval?

    init(toolName: String, arguments: [String: Value], timeout: TimeInterval? = nil) {
        self.toolName = toolName
        self.arguments = arguments
        self.timeout = timeout
    }
}

enum RemoteGatewayBindingState: Equatable {
    case bound
    case bindingRequired(String)
    case ambiguousStartTarget(String)
}

enum RemoteCommandTranslatorError: Error, Equatable, CustomStringConvertible {
    case unsupportedFrameType(String)
    case missingSessionID(String)
    case missingPayloadField(String)
    case invalidPayload(String)
    case unsupportedPayloadKey(operation: String, key: String)
    case arbitraryToolPassthroughRejected
    case ambiguousStartTarget
    case bindingRequired(String)

    var code: String {
        switch self {
        case .unsupportedFrameType: "unsupported_frame_type"
        case .missingSessionID: "missing_session_id"
        case .missingPayloadField: "missing_payload_field"
        case .invalidPayload: "invalid_payload"
        case .unsupportedPayloadKey: "unsupported_payload_key"
        case .arbitraryToolPassthroughRejected: "arbitrary_tool_passthrough_rejected"
        case .ambiguousStartTarget: "ambiguous_start_target"
        case .bindingRequired: "binding_required"
        }
    }

    var description: String {
        switch self {
        case let .unsupportedFrameType(type):
            "Remote frame type '\(type)' does not map to an app MCP tool."
        case let .missingSessionID(operation):
            "session_id is required for remote operation '\(operation)'."
        case let .missingPayloadField(field):
            "payload.\(field) is required."
        case let .invalidPayload(message):
            message
        case let .unsupportedPayloadKey(operation, key):
            "Remote operation '\(operation)' does not support payload key '\(key)'."
        case .arbitraryToolPassthroughRejected:
            "Remote frames cannot choose arbitrary MCP tools or raw arguments."
        case .ambiguousStartTarget:
            "Remote start is ambiguous because the app link is not bound to exactly one window."
        case let .bindingRequired(message):
            message
        }
    }
}

struct RemoteCommandTranslator {
    private let bindingState: RemoteGatewayBindingState

    init(bindingState: RemoteGatewayBindingState = .bound) {
        self.bindingState = bindingState
    }

    func translate(_ frame: RemoteClientFrame) throws -> RemoteToolCall {
        let payload = try payloadObject(frame.payload)
        try rejectPassthroughKeys(payload)
        try enforceBinding(for: frame.type, payload: payload)

        switch frame.type {
        case "start":
            return try translateAgentRun(
                frame: frame,
                op: "start",
                payload: payload,
                allowedPayloadKeys: Self.startPayloadKeys,
                requiresSessionID: false
            )
        case "steer":
            return try translateAgentRun(
                frame: frame,
                op: "steer",
                payload: payload,
                allowedPayloadKeys: Self.steerPayloadKeys,
                requiresSessionID: true
            )
        case "respond":
            return try translateAgentRun(
                frame: frame,
                op: "respond",
                payload: payload,
                allowedPayloadKeys: Self.respondPayloadKeys,
                requiresSessionID: true
            )
        case "cancel":
            return try translateAgentRun(
                frame: frame,
                op: "cancel",
                payload: payload,
                allowedPayloadKeys: Self.cancelPayloadKeys,
                requiresSessionID: true
            )
        case "poll":
            return try translateAgentRun(
                frame: frame,
                op: "poll",
                payload: payload,
                allowedPayloadKeys: Self.pollPayloadKeys,
                requiresSessionID: frame.sessionID == nil && payload["session_ids"] == nil
            )
        case "subscribe", "unsubscribe":
            // Subscriptions are gateway-owned observation state, but their immediate
            // catch-up/validation is still an agent_run poll of the addressed session(s).
            return try translateAgentRun(
                frame: frame,
                op: "poll",
                payload: payload,
                allowedPayloadKeys: Self.pollPayloadKeys,
                requiresSessionID: frame.sessionID == nil && payload["session_ids"] == nil
            )
        case "list_agents":
            return try translateAgentManage(
                op: "list_agents",
                payload: payload,
                allowedPayloadKeys: Self.listAgentsPayloadKeys
            )
        case "list_sessions":
            return try translateAgentManage(
                op: "list_sessions",
                payload: payload,
                allowedPayloadKeys: Self.listSessionsPayloadKeys
            )
        case "get_log":
            return try translateAgentManage(
                frame: frame,
                op: "get_log",
                payload: payload,
                allowedPayloadKeys: Self.getLogPayloadKeys,
                requiresSessionID: true
            )
        default:
            throw RemoteCommandTranslatorError.unsupportedFrameType(frame.type)
        }
    }

    private func enforceBinding(for operation: String, payload: [String: JSONValue]) throws {
        switch bindingState {
        case .bound:
            return
        case let .bindingRequired(message):
            // M6.6: an explicit start selector names its own target, so start may
            // proceed on an unbound multi-window connection. Observation and
            // session-addressed operations still require binding.
            if operation == "start", hasExplicitStartTarget(payload) { return }
            throw RemoteCommandTranslatorError.bindingRequired(message)
        case .ambiguousStartTarget where operation == "start":
            if hasExplicitStartTarget(payload) { return }
            throw RemoteCommandTranslatorError.ambiguousStartTarget
        case let .ambiguousStartTarget(message):
            throw RemoteCommandTranslatorError.bindingRequired(message)
        }
    }

    private func hasExplicitStartTarget(_ payload: [String: JSONValue]) -> Bool {
        payload["window_id"] != nil || payload["workspace_id"] != nil
    }

    private func translateAgentRun(
        frame: RemoteClientFrame,
        op: String,
        payload: [String: JSONValue],
        allowedPayloadKeys: Set<String>,
        requiresSessionID: Bool
    ) throws -> RemoteToolCall {
        try validateAllowedPayloadKeys(payload, operation: frame.type, allowed: allowedPayloadKeys)
        var arguments = commonArguments(op: op)
        if let sessionID = frame.sessionID {
            arguments["session_id"] = .string(sessionID)
        } else if requiresSessionID {
            throw RemoteCommandTranslatorError.missingSessionID(frame.type)
        }
        // Phase 2 (plan §6.1): forward the remote request_id so the app-side
        // idempotency registry can absorb duplicates end-to-end.
        if let requestID = frame.requestID, ["start", "steer", "respond"].contains(op) {
            arguments["request_id"] = .string(requestID)
        }
        for (key, value) in payload {
            if key == "session_ids" {
                arguments[key] = value.mcpValue
            } else if key == "window_id" {
                // M6.6 explicit start selector: reuse the app's hidden one-shot
                // `_windowID` routing override (dispatcher priority 0). Never
                // synthesize routing state — the app binds/redirects per call.
                if let intValue = value.intValue {
                    arguments["_windowID"] = .int(intValue)
                } else if let stringValue = value.stringValue, let intValue = Int(stringValue) {
                    arguments["_windowID"] = .int(intValue)
                } else {
                    throw RemoteCommandTranslatorError.invalidPayload("payload.window_id must be an integer window id.")
                }
            } else if key == "workspace_id" {
                // Validated app-side against the resolved window's active workspace.
                arguments["workspace_id"] = value.mcpValue
            } else if key == "interaction_id" || key == "message" || key == "response" || key == "answers"
                || key == "content" || key == "meta" || key == "_meta" || key == "amendment"
                || key == "workflow_id" || key == "workflow_name" || key == "model_id"
                || key == "session_name" || key == "timeout" || key == "timeout_seconds"
                || key == "wait" || key == "skip" || key.hasPrefix("worktree") || key == "detach"
                || key == "allow_external_worktree_path"
            {
                arguments[key] = value.mcpValue
            }
        }
        return RemoteToolCall(toolName: "agent_run", arguments: arguments, timeout: nil)
    }

    private func translateAgentManage(
        frame: RemoteClientFrame? = nil,
        op: String,
        payload: [String: JSONValue],
        allowedPayloadKeys: Set<String>,
        requiresSessionID: Bool = false
    ) throws -> RemoteToolCall {
        try validateAllowedPayloadKeys(payload, operation: frame?.type ?? op, allowed: allowedPayloadKeys)
        var arguments = commonArguments(op: op)
        if let sessionID = frame?.sessionID {
            arguments["session_id"] = .string(sessionID)
        } else if requiresSessionID {
            throw RemoteCommandTranslatorError.missingSessionID(frame?.type ?? op)
        }
        for (key, value) in payload {
            arguments[key] = value.mcpValue
        }
        return RemoteToolCall(toolName: "agent_manage", arguments: arguments, timeout: nil)
    }

    private func commonArguments(op: String) -> [String: Value] {
        [
            "op": .string(op),
            "_rawJSON": .bool(true)
        ]
    }

    private func payloadObject(_ payload: JSONValue?) throws -> [String: JSONValue] {
        guard let payload else { return [:] }
        guard let object = payload.objectValue else {
            throw RemoteCommandTranslatorError.invalidPayload("payload must be an object when present.")
        }
        return object
    }

    private func rejectPassthroughKeys(_ payload: [String: JSONValue]) throws {
        let forbidden = ["tool", "tool_name", "name", "arguments", "args"]
        if payload.keys.contains(where: { forbidden.contains($0) }) {
            throw RemoteCommandTranslatorError.arbitraryToolPassthroughRejected
        }
        if payload["op"] != nil {
            throw RemoteCommandTranslatorError.arbitraryToolPassthroughRejected
        }
    }

    private func validateAllowedPayloadKeys(
        _ payload: [String: JSONValue],
        operation: String,
        allowed: Set<String>
    ) throws {
        for key in payload.keys.sorted() where !allowed.contains(key) {
            throw RemoteCommandTranslatorError.unsupportedPayloadKey(operation: operation, key: key)
        }
    }

    private static let commonWorktreePayloadKeys: Set<String> = [
        "worktree",
        "worktree_id",
        "worktree_create",
        "worktree_repo_root",
        "worktree_branch",
        "worktree_base_ref",
        "worktree_path",
        "allow_external_worktree_path",
        "worktree_label",
        "worktree_color",
        "inherit_worktree"
    ]

    private static let startPayloadKeys: Set<String> = Set([
        "message",
        "model_id",
        "session_name",
        "timeout",
        "detach",
        "workflow_id",
        "workflow_name",
        // M6.6 explicit multi-window start selectors.
        "window_id",
        "workspace_id"
    ]).union(commonWorktreePayloadKeys)

    private static let steerPayloadKeys: Set<String> = [
        "message",
        "workflow_id",
        "workflow_name",
        "wait",
        "timeout_seconds"
    ]

    private static let respondPayloadKeys: Set<String> = [
        "interaction_id",
        "response",
        "answers",
        "skip",
        "content",
        "meta",
        "_meta",
        "amendment",
        "workflow_id",
        "workflow_name"
    ]

    private static let cancelPayloadKeys: Set<String> = []

    private static let pollPayloadKeys: Set<String> = [
        "session_ids",
        "timeout"
    ]

    private static let listAgentsPayloadKeys: Set<String> = []

    private static let listSessionsPayloadKeys: Set<String> = [
        "agent",
        "state",
        "limit"
    ]

    private static let getLogPayloadKeys: Set<String> = [
        "offset",
        "limit"
    ]
}
