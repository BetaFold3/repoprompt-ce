import CryptoKit
import Foundation
import RepoPromptRemoteWire

struct RemoteInteractionResponsePayload: Equatable {
    var response: String?
    var skip: Bool
    var answers: JSONValue?
    var content: JSONValue?
    var meta: JSONValue?
    var amendment: String?

    init(
        response: String? = nil,
        skip: Bool = false,
        answers: JSONValue? = nil,
        content: JSONValue? = nil,
        meta: JSONValue? = nil,
        amendment: String? = nil
    ) {
        self.response = response
        self.skip = skip
        self.answers = answers
        self.content = content
        self.meta = meta
        self.amendment = amendment
    }

    func wirePayload(interactionID: String) -> JSONValue {
        var object: [String: JSONValue] = ["interaction_id": .string(interactionID)]
        if let response { object["response"] = .string(response) }
        if skip { object["skip"] = .bool(true) }
        if let answers, !skip { object["answers"] = answers }
        if let content { object["content"] = content }
        if let meta { object["meta"] = meta }
        if let amendment { object["amendment"] = .string(amendment) }
        return .object(object)
    }

    static func approval(decision: AgentApprovalDecision) -> RemoteInteractionResponsePayload {
        switch decision {
        case .accept:
            RemoteInteractionResponsePayload(response: "accept")
        case .acceptForSession:
            RemoteInteractionResponsePayload(response: "accept_for_session")
        case let .acceptWithExecpolicyAmendment(amendment):
            RemoteInteractionResponsePayload(response: "accept_with_amendment", amendment: amendment)
        case .decline:
            RemoteInteractionResponsePayload(response: "decline")
        case .cancel:
            RemoteInteractionResponsePayload(response: "cancel")
        }
    }

    static func askUser(_ response: AgentAskUserResponse) -> RemoteInteractionResponsePayload {
        guard !response.skipped else {
            return RemoteInteractionResponsePayload(skip: true)
        }
        let answers = response.answersByQuestionID.reduce(into: [String: JSONValue]()) { partial, entry in
            partial[entry.key] = .object([
                "answers": .array(entry.value.answers.map(JSONValue.string)),
                "selected_options": .array(entry.value.selectedOptions.map(JSONValue.string)),
                "custom_response": entry.value.customResponse.map(JSONValue.string) ?? .null,
                "skipped": .bool(entry.value.skipped)
            ])
        }
        return RemoteInteractionResponsePayload(
            skip: response.skipped,
            answers: .object(answers)
        )
    }

    static func userInput(_ response: AgentRequestUserInputResponse) -> RemoteInteractionResponsePayload {
        let answers = response.answersByQuestionID.reduce(into: [String: JSONValue]()) { partial, entry in
            partial[entry.key] = .array(entry.value.map(JSONValue.string))
        }
        return RemoteInteractionResponsePayload(answers: .object(answers))
    }

    static func mcpElicitation(_ response: AgentMCPElicitationResponse) -> RemoteInteractionResponsePayload {
        RemoteInteractionResponsePayload(
            response: response.action.rawValue,
            content: .object(response.content.mapValues(jsonValue(from:))),
            meta: .object(response.meta.mapValues(jsonValue(from:)))
        )
    }

    private static func jsonValue(from value: AgentJSONValue) -> JSONValue {
        switch value {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .int(value): .int(value)
        case let .double(value): .double(value)
        case let .string(value): .string(value)
        case let .array(values): .array(values.map(jsonValue(from:)))
        case let .object(values): .object(values.mapValues(jsonValue(from:)))
        }
    }
}

enum RemotePendingInteraction: Equatable {
    case approval(interactionID: String, request: AgentApprovalRequest)
    case question(interactionID: String, pending: AgentAskUserPendingState)
    case userInput(interactionID: String, request: AgentRequestUserInputRequest)
    case mcpElicitation(interactionID: String, request: AgentMCPElicitationRequest)

    init?(snapshotPayload: JSONValue, remoteSessionID: String) {
        guard let object = snapshotPayload.objectValue,
              let interactionObject = object["interaction"]?.objectValue,
              let wire = WireInteraction(object: interactionObject)
        else { return nil }
        switch wire.kind {
        case "approval":
            self = .approval(
                interactionID: wire.id,
                request: wire.approvalRequest(remoteSessionID: remoteSessionID)
            )
        case "question", "instruction":
            self = .question(
                interactionID: wire.id,
                pending: wire.askUserPendingState(remoteSessionID: remoteSessionID)
            )
        case "user_input":
            self = .userInput(
                interactionID: wire.id,
                request: wire.userInputRequest(remoteSessionID: remoteSessionID)
            )
        case "mcp_elicitation":
            self = .mcpElicitation(
                interactionID: wire.id,
                request: wire.mcpElicitationRequest(remoteSessionID: remoteSessionID)
            )
        default:
            self = .question(
                interactionID: wire.id,
                pending: wire.askUserPendingState(remoteSessionID: remoteSessionID)
            )
        }
    }

    var interactionID: String {
        switch self {
        case let .approval(interactionID, _),
             let .question(interactionID, _),
             let .userInput(interactionID, _),
             let .mcpElicitation(interactionID, _):
            interactionID
        }
    }

    var interactionUUID: UUID {
        UUID(uuidString: interactionID) ?? Self.deterministicUUID(seed: "remote-interaction|\(interactionID)")
    }

    var approvalRequest: AgentApprovalRequest? {
        if case let .approval(_, request) = self { return request }
        return nil
    }

    private struct WireInteraction: Equatable {
        struct Option: Equatable {
            var label: String
            var description: String?
        }

        struct Field: Equatable {
            var id: String
            var header: String?
            var prompt: String
            var context: String?
            var isSecret: Bool
            var allowsOther: Bool
            var allowsMultiple: Bool?
            var allowsCustom: Bool?
            var options: [Option]
        }

        struct Detail: Equatable {
            var label: String
            var value: String
            var isCode: Bool
        }

        var id: String
        var kind: String
        var responseType: String
        var title: String?
        var prompt: String?
        var context: String?
        var allowsMultiple: Bool?
        var options: [Option]
        var fields: [Field]
        var details: [Detail]
        var rawJSON: JSONValue

        init?(object: [String: JSONValue]) {
            guard let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            self.id = id
            kind = object["kind"]?.stringValue ?? "question"
            responseType = object["response_type"]?.stringValue ?? "text"
            title = object["title"]?.stringValue
            prompt = object["prompt"]?.stringValue
            context = object["context"]?.stringValue
            allowsMultiple = object["allows_multiple"]?.boolValue
            options = (object["options"]?.arrayValue ?? []).compactMap { value in
                guard let object = value.objectValue,
                      let label = object["label"]?.stringValue,
                      !label.isEmpty
                else { return nil }
                return Option(label: label, description: object["description"]?.stringValue)
            }
            fields = (object["fields"]?.arrayValue ?? []).compactMap { value in
                guard let object = value.objectValue,
                      let id = object["id"]?.stringValue,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                let fieldOptions = (object["options"]?.arrayValue ?? []).compactMap { value -> Option? in
                    guard let optionObject = value.objectValue,
                          let label = optionObject["label"]?.stringValue,
                          !label.isEmpty
                    else { return nil }
                    return Option(label: label, description: optionObject["description"]?.stringValue)
                }
                return Field(
                    id: id,
                    header: object["header"]?.stringValue,
                    prompt: object["prompt"]?.stringValue ?? "Response",
                    context: object["context"]?.stringValue,
                    isSecret: object["is_secret"]?.boolValue ?? false,
                    allowsOther: object["allows_other"]?.boolValue ?? true,
                    allowsMultiple: object["allows_multiple"]?.boolValue,
                    allowsCustom: object["allows_custom"]?.boolValue,
                    options: fieldOptions
                )
            }
            details = (object["details"]?.arrayValue ?? []).compactMap { value in
                guard let object = value.objectValue,
                      let label = object["label"]?.stringValue,
                      let value = object["value"]?.stringValue
                else { return nil }
                return Detail(label: label, value: value, isCode: object["is_code"]?.boolValue ?? false)
            }
            rawJSON = .object(object)
        }

        func approvalRequest(remoteSessionID: String) -> AgentApprovalRequest {
            let requestID: AgentApprovalRequestID = .remoteGateway(interactionID: id)
            let approvalKind: AgentApprovalKind = details.contains { detail in
                detail.label.localizedCaseInsensitiveContains("type")
                    && detail.value.localizedCaseInsensitiveContains("file")
            } ? .fileChange : .commandExecution
            let mappedDetails = details.map { detail in
                AgentApprovalDetail(label: detail.label, value: detail.value, isCode: detail.isCode)
            }
            let command = details.first { $0.label.localizedCaseInsensitiveContains("command") }?.value
            let cwd = details.first { $0.label.localizedCaseInsensitiveContains("working directory") || $0.label.localizedCaseInsensitiveContains("cwd") }?.value
            return AgentApprovalRequest(
                id: uuid,
                requestID: requestID,
                method: "remote_gateway.approval",
                kind: approvalKind,
                threadID: remoteSessionID,
                turnID: id,
                itemID: id,
                reason: prompt ?? context ?? title,
                command: command,
                cwd: cwd,
                details: mappedDetails
            )
        }

        func askUserPendingState(remoteSessionID _: String) -> AgentAskUserPendingState {
            let questions: [AgentAskUserQuestion] = if fields.isEmpty {
                [
                    AgentAskUserQuestion(
                        id: "response",
                        header: title,
                        question: prompt ?? title ?? "Response requested",
                        context: context,
                        options: options.map { AgentAskUserOption(label: $0.label, description: $0.description) },
                        allowsMultiple: allowsMultiple ?? (responseType == "structured"),
                        allowsCustom: responseType != "choice"
                    )
                ]
            } else {
                fields.map { field in
                    AgentAskUserQuestion(
                        id: field.id,
                        header: field.header,
                        question: field.prompt,
                        context: field.context ?? context,
                        options: field.options.map { AgentAskUserOption(label: $0.label, description: $0.description) },
                        allowsMultiple: field.allowsMultiple ?? false,
                        allowsCustom: field.allowsCustom ?? field.allowsOther
                    )
                }
            }
            let interaction = AgentAskUserInteraction(
                id: uuid,
                remoteInteractionID: id,
                title: title,
                context: context,
                questions: questions
            )
            return AgentAskUserPendingState(interaction: interaction)
        }

        func userInputRequest(remoteSessionID: String) -> AgentRequestUserInputRequest {
            let questionFields = fields.isEmpty
                ? [Field(
                    id: "response",
                    header: title,
                    prompt: prompt ?? title ?? "Response requested",
                    context: context,
                    isSecret: false,
                    allowsOther: true,
                    allowsMultiple: false,
                    allowsCustom: true,
                    options: options
                )]
                : fields
            let questions = questionFields.map { field in
                AgentRequestUserInputQuestion(
                    id: field.id,
                    header: field.header ?? title ?? "Input",
                    question: field.prompt,
                    isOther: field.allowsOther,
                    isSecret: field.isSecret,
                    options: field.options.map { AgentRequestUserInputOption(label: $0.label, description: $0.description ?? "") }
                )
            }
            return AgentRequestUserInputRequest(
                id: uuid,
                remoteInteractionID: id,
                requestID: .string("remote:\(id)"),
                method: "remote_gateway.user_input",
                threadID: remoteSessionID,
                turnID: id,
                itemID: id,
                questions: questions
            )
        }

        func mcpElicitationRequest(remoteSessionID: String) -> AgentMCPElicitationRequest {
            let rawParams = (try? rawJSON.canonicalString()) ?? "{}"
            return AgentMCPElicitationRequest(
                id: uuid,
                remoteInteractionID: id,
                requestID: .string("remote:\(id)"),
                method: "remote_gateway.mcp_elicitation",
                threadID: remoteSessionID,
                turnID: id,
                itemID: id,
                title: title ?? "MCP Elicitation Requested",
                prompt: prompt,
                message: context,
                rawParamsJSON: rawParams,
                details: details.map { AgentApprovalDetail(label: $0.label, value: $0.value, isCode: $0.isCode) }
            )
        }

        private var uuid: UUID {
            UUID(uuidString: id) ?? RemotePendingInteraction.deterministicUUID(seed: "remote-interaction|\(id)")
        }
    }

    private static func deterministicUUID(seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }
}
