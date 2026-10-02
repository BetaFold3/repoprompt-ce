import Foundation
import MCP

/// Identity of one delegated child question: the asking child's durable session ID plus the
/// `ask_user` interaction ID its MCP snapshot exposes (`AgentAskUserInteraction.id`).
///
/// Related:
/// - AgentDelegatedQuestionAudience.swift (who a child's `ask_user` is addressed to)
/// - AgentModeViewModel+DelegatedQuestions.swift (runtime notice registry and delivery)
/// - docs/context/agent-mcp-delegation-depth.md ("Delegated questions" contract)
struct AgentDelegatedQuestionNoticeKey: Hashable {
    let childSessionID: UUID
    let interactionID: UUID
}

/// Model-visible notice for one pending child question, resolved fresh from the child's
/// `pendingAskUser` at delivery time. It carries the question content and selection
/// constraints only — never the user's unsubmitted drafts — and is not an answer or approval.
struct AgentDelegatedQuestionNoticePayload: Equatable {
    struct Option: Equatable {
        let label: String
        let description: String?
    }

    struct Question: Equatable {
        let id: String
        let header: String?
        let question: String
        let context: String?
        let options: [Option]
        let allowsMultiple: Bool
        let allowsCustom: Bool
    }

    let key: AgentDelegatedQuestionNoticeKey
    let childSessionName: String
    let title: String?
    let context: String?
    let questions: [Question]

    init(
        key: AgentDelegatedQuestionNoticeKey,
        childSessionName: String,
        title: String?,
        context: String?,
        questions: [Question]
    ) {
        self.key = key
        self.childSessionName = childSessionName
        self.title = title
        self.context = context
        self.questions = questions
    }

    /// Builds the payload from the authoritative interaction only (no drafts are read).
    init(childSessionID: UUID, childSessionName: String, interaction: AgentAskUserInteraction) {
        self.init(
            key: AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interaction.id),
            childSessionName: childSessionName,
            title: interaction.title,
            context: interaction.context,
            questions: interaction.questions.map { question in
                Question(
                    id: question.id,
                    header: question.header,
                    question: question.question,
                    context: question.context,
                    options: question.options.map { Option(label: $0.label, description: $0.description) },
                    allowsMultiple: question.allowsMultiple,
                    allowsCustom: question.allowsCustom
                )
            }
        )
    }

    /// Point-of-need guidance (plan §6.3), verbatim apart from the substituted identifiers.
    var guidanceText: String {
        let sessionID = key.childSessionID.uuidString
        let interactionID = key.interactionID.uuidString
        return "Child session \"\(childSessionName)\" (`\(sessionID)`) is waiting for your answer to an `ask_user` question (interaction `\(interactionID)`). Use your own judgment and the information you have to answer it with `agent_run respond`. If you cannot decide, ask your own controller with `ask_user`, then relay the answer. This notice is not a user answer or approval; confirm the interaction is still pending before responding."
    }

    /// Labeled, ID-bearing text block shown to the parent model and persisted with the tool
    /// result or turn input that delivered it.
    var renderedText: String {
        var lines: [String] = [AgentDelegatedQuestionNoticeWire.noticeHeader, guidanceText]
        if let title = Self.nonEmpty(title) {
            lines.append("Title: \(title)")
        }
        if let context = Self.nonEmpty(context) {
            lines.append("Context: \(context)")
        }
        lines.append("Questions:")
        for (index, question) in questions.enumerated() {
            let header = Self.nonEmpty(question.header).map { "\($0): " } ?? ""
            lines.append("\(index + 1). [id `\(question.id)`] \(header)\(question.question)")
            if let context = Self.nonEmpty(question.context) {
                lines.append("   Context: \(context)")
            }
            lines.append("   Selection: \(Self.selectionConstraint(for: question))")
            for option in question.options {
                if let description = Self.nonEmpty(option.description) {
                    lines.append("   - \(option.label) — \(description)")
                } else {
                    lines.append("   - \(option.label)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Structured entry carried under `AgentDelegatedQuestionNoticeWire.resultKey`. The `text`
    /// field is the rendered block so the formatter never re-derives notice wording.
    func wireValue() -> Value {
        var object: [String: Value] = [
            "kind": .string(AgentDelegatedQuestionNoticeWire.entryKind),
            "child_session_id": .string(key.childSessionID.uuidString),
            "child_session_name": .string(childSessionName),
            "interaction_id": .string(key.interactionID.uuidString),
            "guidance": .string(guidanceText),
            "questions": .array(questions.map { question in
                var questionObject: [String: Value] = [
                    "id": .string(question.id),
                    "question": .string(question.question),
                    "allows_multiple": .bool(question.allowsMultiple),
                    "allows_custom": .bool(question.allowsCustom),
                    "options": .array(question.options.map { option in
                        var optionObject: [String: Value] = ["label": .string(option.label)]
                        if let description = option.description {
                            optionObject["description"] = .string(description)
                        }
                        return .object(optionObject)
                    })
                ]
                if let header = question.header {
                    questionObject["header"] = .string(header)
                }
                if let context = question.context {
                    questionObject["context"] = .string(context)
                }
                return .object(questionObject)
            }),
            "text": .string(renderedText)
        ]
        if let title {
            object["title"] = .string(title)
        }
        if let context {
            object["context"] = .string(context)
        }
        return .object(object)
    }

    private static func selectionConstraint(for question: Question) -> String {
        let choice = if question.options.isEmpty {
            "free-form answer"
        } else if question.allowsMultiple {
            "choose any number of options"
        } else {
            "choose one option"
        }
        let custom = question.allowsCustom ? "custom answer allowed" : "custom answer not allowed"
        return "\(choice); \(custom)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Wire constants and pure helpers shared by the Agent Mode delivery registry and the MCP
/// result path (`MCPServerViewModel.runTool`, `ToolOutputFormatter`, wait services).
enum AgentDelegatedQuestionNoticeWire {
    /// Dedicated root key on an object tool result carrying `[AgentDelegatedQuestionNoticePayload.wireValue()]`.
    static let resultKey = "delegated_question_notices"
    /// Per-entry `kind` discriminator.
    static let entryKind = "delegated_question"
    /// `agent_run` wait result when woken early by a pending child question.
    static let agentRunWaitResult = "interrupted_by_child_question"
    /// `ask_oracle` bounded-wait `_meta.wake_reason` for a child-question wake.
    static let oracleWakeReason = "delegated_question"
    /// `ask_oracle` pending `reason` for a child-question wake (steering keeps its own reason).
    static let oraclePendingReason = "interrupted_by_child_question"
    /// First line of every rendered notice block.
    static let noticeHeader = "[RepoPrompt runtime notice: delegated child question — not user input]"

    /// Explicit allowlist of RepoPrompt MCP tools whose object results may carry notices in
    /// `resultKey`. Excludes tools whose results the app or model parses structurally without
    /// a dedicated field (`ask_user`, `apply_edits`) and long-running or side-effect tools.
    static let eligibleToolNames: Set<String> = [
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.manageSelection,
        MCPWindowToolName.workspaceContext,
        MCPWindowToolName.prompt,
        MCPWindowToolName.git,
        MCPWindowToolName.oracleUtils,
        MCPWindowToolName.oracleChatLog,
        MCPWindowToolName.askOracle,
        MCPWindowToolName.oracleSend,
        MCPWindowToolName.agentRun,
        MCPWindowToolName.agentManage,
        MCPWindowToolName.history
    ]

    static func isEligible(toolName: String) -> Bool {
        eligibleToolNames.contains(toolName)
    }

    /// Returns `value` with `payloads` appended under `resultKey`, preserving every original
    /// key. Returns nil when `value` is not an object or `payloads` is empty, so callers never
    /// consume a notice they could not attach.
    static func attaching(_ payloads: [AgentDelegatedQuestionNoticePayload], to value: Value) -> Value? {
        guard !payloads.isEmpty, case var .object(object) = value else { return nil }
        var entries = object[resultKey]?.arrayValue ?? []
        entries.append(contentsOf: payloads.map { $0.wireValue() })
        object[resultKey] = .array(entries)
        return .object(object)
    }

    /// Splits a tool result into the original payload (without `resultKey`) and the joined
    /// rendered notice text, if any. Non-object values pass through unchanged.
    static func splitting(_ value: Value) -> (original: Value, noticeText: String?) {
        guard case var .object(object) = value,
              let entries = object.removeValue(forKey: resultKey)
        else {
            return (value, nil)
        }
        let texts = (entries.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }
        return (.object(object), texts.isEmpty ? nil : renderedText(texts))
    }

    /// Joined notice block for one delivery (tool result or turn input).
    static func renderedText(for payloads: [AgentDelegatedQuestionNoticePayload]) -> String? {
        let texts = payloads.map(\.renderedText)
        return texts.isEmpty ? nil : renderedText(texts)
    }

    private static func renderedText(_ texts: [String]) -> String {
        texts.joined(separator: "\n\n")
    }
}
