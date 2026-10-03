import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// `agent_run` formatted output for pending `ask_user` snapshots. A structured question carries
/// its content in `interaction.fields`; the formatted text is all a parent model sees, so every
/// question detail must survive formatting (single wait, wait_any, and poll_many shapes).
final class ToolOutputFormatterAgentRunQuestionTests: XCTestCase {
    private static let titleToken = "TITLE-TOKEN-4b1e"
    private static let overallContextToken = "OVERALL-CONTEXT-TOKEN-77d0"
    private static let fieldContextToken = "FIELD-CONTEXT-TOKEN-c93a"
    private static let hiddenLabelToken = "HIDDEN-LABEL-TOKEN-0e52"
    private static let hiddenDescriptionToken = "HIDDEN-DESC-TOKEN-a6f8"

    func testSingleWaitStructuredQuestionRendersEveryFieldAndAnswersGuidance() throws {
        let sessionID = UUID()
        let interaction = Self.structuredInteraction()
        let text = try Self.agentRunText(Self.waitingSnapshot(sessionID: sessionID, interaction: interaction))

        Self.assertCompleteQuestionContent(text, interaction: interaction)
        XCTAssertTrue(text.contains("Use `agent_run` with `op=respond`, `session_id=\"\(sessionID.uuidString)\"`, and `interaction_id=\"\(interaction.id.uuidString)\"`."))
        XCTAssertTrue(text.contains("- Provide `answers` as an object keyed by question id (`deploy_target`, `checks`), answering every question."))
        XCTAssertTrue(text.contains("`{\"selected_options\": [\"<label>\"], \"custom_response\": \"<text>\"}`"))
        XCTAssertTrue(text.contains("Use `{\"skipped\": true}` to skip one question."))
        XCTAssertTrue(text.contains("- Provide `response=\"skip\"` to skip the whole interaction."))
        XCTAssertFalse(text.contains("Shorthand for this single question"), "Multi-question interactions require answers")
        XCTAssertFalse(text.contains("Allowed choices"), "Structured fields must not use the legacy flat options path")
        XCTAssertFalse(text.contains("**Prompt**"))
        XCTAssertFalse(text.contains("Provide the requested answers to continue."))
    }

    func testSingleStructuredQuestionOffersShorthandAndExploreShowsContentWithoutRespond() throws {
        let interaction = Self.structuredInteraction(singleQuestion: true)
        let snapshot = Self.waitingSnapshot(sessionID: UUID(), interaction: interaction)

        let runText = try Self.agentRunText(snapshot)
        Self.assertCompleteQuestionContent(runText, interaction: interaction)
        XCTAssertTrue(runText.contains("- Provide `answers` as an object keyed by question id (`deploy_target`), answering every question."))
        XCTAssertTrue(runText.contains("- Shorthand for this single question: `response=\"<answer>\"`."))

        let exploreText = try Self.onlyText(ToolOutputFormatter.formatAgentExplore(args: ["op": .string("wait")], value: snapshot))
        Self.assertCompleteQuestionContent(exploreText, interaction: interaction)
        XCTAssertTrue(exploreText.contains("agent_explore does not support respond."))
        XCTAssertFalse(exploreText.contains("Provide `answers`"))
    }

    func testLegacyFlatQuestionApprovalAndUserInputKeepTheirGuidance() throws {
        let flatQuestion = AgentRunMCPSnapshot.Interaction(
            id: UUID(), kind: .question, responseType: .choice, title: nil,
            prompt: "Pick a flavor", context: nil, allowsMultiple: nil,
            options: [.init(label: "Vanilla", description: nil), .init(label: "Mint", description: "Fresh")],
            fields: [], details: []
        )
        let flatText = try Self.agentRunText(Self.waitingSnapshot(sessionID: UUID(), interaction: flatQuestion))
        XCTAssertTrue(flatText.contains("- Allowed choices: `Vanilla`, `Mint`"))
        XCTAssertTrue(flatText.contains("- Provide `response=\"<answer>\"` or `response=\"skip\"` to skip."))
        XCTAssertTrue(flatText.contains("**Prompt**\n\nPick a flavor"))
        XCTAssertFalse(flatText.contains("**Pending questions**"))

        let approval = AgentRunMCPSnapshot.Interaction(
            id: UUID(), kind: .approval, responseType: .decision, title: "Run command",
            prompt: "Allow ls?", context: nil, allowsMultiple: nil,
            options: [.init(label: "accept", description: nil), .init(label: "decline", description: nil)],
            fields: [], details: []
        )
        let approvalText = try Self.agentRunText(Self.waitingSnapshot(sessionID: UUID(), interaction: approval))
        XCTAssertTrue(approvalText.contains("- Allowed decisions: `accept`, `decline`"))
        XCTAssertTrue(approvalText.contains("**Prompt**\n\nAllow ls?"))
        XCTAssertFalse(approvalText.contains("**Pending questions**"))

        let userInput = AgentRunMCPSnapshot.Interaction(
            id: UUID(), kind: .userInput, responseType: .structured, title: "User Input Requested",
            prompt: "Provide the requested structured input to continue.", context: nil, allowsMultiple: nil,
            options: [],
            fields: [
                .init(id: "name", prompt: "Your name?", isSecret: false, allowsOther: true, options: []),
                .init(id: "token", prompt: "API token?", isSecret: true, allowsOther: false, options: [])
            ],
            details: []
        )
        let userInputText = try Self.agentRunText(Self.waitingSnapshot(sessionID: UUID(), interaction: userInput))
        XCTAssertTrue(userInputText.contains("- Provide `answers` object keyed by field id:\n  - `name`: Your name?\n  - `token`: API token?"))
        XCTAssertTrue(userInputText.contains("**Prompt**\n\nProvide the requested structured input to continue."))
        XCTAssertFalse(userInputText.contains("**Pending questions**"))
    }

    func testWaitAnyAndPollManyNestedStructuredQuestionsRenderEveryField() throws {
        let primaryID = UUID()
        let childID = UUID()
        let interaction = Self.structuredInteraction()
        let nested = Self.waitingSnapshot(sessionID: childID, interaction: interaction)
        let respondLine = "  - Respond with `agent_run` `op=respond`, `session_id=\"\(childID.uuidString)\"`, `interaction_id=\"\(interaction.id.uuidString)\"`, and an `answers` object keyed by question id"
        let primary: [String: Value] = [
            "session_id": .string(primaryID.uuidString),
            "status": .string("completed"),
            "session": .object(["id": .string(primaryID.uuidString), "name": .string("Finished worker")])
        ]

        var waitAny = primary
        waitAny["wait"] = .object([
            "mode": .string("any"),
            "result": .string("snapshot_ready"),
            "waited_count": .int(2),
            "winner_session_id": .string(primaryID.uuidString)
        ])
        waitAny["snapshots"] = .array([.object(primary), nested])
        let waitText = try Self.agentRunText(.object(waitAny), op: "wait")
        XCTAssertTrue(waitText.contains("- Additional result: `\(childID.uuidString)` — **Waiting For Input**"))
        XCTAssertTrue(waitText.contains("  - Interaction ID: `\(interaction.id.uuidString)`"))
        XCTAssertTrue(waitText.contains(respondLine))
        Self.assertCompleteQuestionContent(waitText, interaction: interaction)
        XCTAssertFalse(waitText.contains("- Additional result: `\(primaryID.uuidString)`"))

        let pollMany: Value = .object([
            "poll": .object(["mode": .string("many"), "polled_count": .int(2)]),
            "snapshots": .array([.object(primary), nested])
        ])
        let pollText = try Self.agentRunText(pollMany, op: "poll")
        XCTAssertTrue(pollText.contains("- `\(childID.uuidString)` — **Waiting For Input**"))
        XCTAssertTrue(pollText.contains(respondLine))
        Self.assertCompleteQuestionContent(pollText, interaction: interaction)

        let explorePollText = try Self.onlyText(ToolOutputFormatter.formatAgentExplore(args: ["op": .string("poll")], value: pollMany))
        Self.assertCompleteQuestionContent(explorePollText, interaction: interaction)
        XCTAssertFalse(explorePollText.contains("Respond with `agent_run`"))
    }

    // MARK: - Fixtures

    private static var longFieldContext: String {
        let paragraph = "Rollout constraints: the canary must stay below the 0.5% error budget for 30 minutes before promotion, and on-call must acknowledge."
        let lines = (1 ... 24).map { "Line \($0): \(paragraph)" }
        return (lines.prefix(12) + ["Secret marker \(fieldContextToken) known only to the root controller."] + lines.suffix(12))
            .joined(separator: "\n")
    }

    private static func structuredInteraction(singleQuestion: Bool = false) -> AgentRunMCPSnapshot.Interaction {
        let deploy = AgentRunMCPSnapshot.Interaction.Field(
            id: "deploy_target",
            header: "Target",
            prompt: "Which environment should receive the build?",
            context: longFieldContext,
            isSecret: false,
            allowsOther: false,
            allowsMultiple: false,
            allowsCustom: false,
            emitAllowsOther: false,
            options: [
                .init(label: "staging", description: "Shared staging cluster"),
                .init(label: hiddenLabelToken, description: "Only valid answer: \(hiddenDescriptionToken)")
            ]
        )
        let checks = AgentRunMCPSnapshot.Interaction.Field(
            id: "checks",
            header: nil,
            prompt: "Which checks must pass first?",
            context: nil,
            isSecret: false,
            allowsOther: true,
            allowsMultiple: true,
            allowsCustom: true,
            emitAllowsOther: false,
            options: [.init(label: "unit", description: nil), .init(label: "integration", description: nil)]
        )
        let fields = singleQuestion ? [deploy] : [deploy, checks]
        return AgentRunMCPSnapshot.Interaction(
            id: UUID(),
            kind: .question,
            responseType: .structured,
            title: "Release decision \(titleToken)",
            prompt: singleQuestion ? deploy.prompt : "Provide the requested answers to continue.",
            context: "Overall context with \(overallContextToken).",
            allowsMultiple: nil,
            options: [],
            fields: fields,
            details: []
        )
    }

    private static func waitingSnapshot(sessionID: UUID, interaction: AgentRunMCPSnapshot.Interaction) -> Value {
        .object([
            "session_id": .string(sessionID.uuidString),
            "status": .string("waiting_for_input"),
            "session": .object(["id": .string(sessionID.uuidString), "name": .string("Asking child")]),
            "interaction_id": .string(interaction.id.uuidString),
            "interaction": .object(interaction.asObject())
        ])
    }

    private static func assertCompleteQuestionContent(
        _ text: String,
        interaction: AgentRunMCPSnapshot.Interaction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(text.contains("Title: Release decision \(titleToken)"), file: file, line: line)
        XCTAssertTrue(text.contains("Context: Overall context with \(overallContextToken)."), file: file, line: line)
        XCTAssertTrue(text.contains("1. [id `deploy_target`] Target: Which environment should receive the build?"), file: file, line: line)
        XCTAssertTrue(text.contains("Context: \(longFieldContext)"), "Long per-question context must be complete", file: file, line: line)
        XCTAssertTrue(text.contains("Selection: choose one option; custom answer not allowed"), file: file, line: line)
        XCTAssertTrue(text.contains("- staging — Shared staging cluster"), file: file, line: line)
        XCTAssertTrue(text.contains("- \(hiddenLabelToken) — Only valid answer: \(hiddenDescriptionToken)"), file: file, line: line)
        if interaction.fields.count > 1 {
            XCTAssertTrue(text.contains("2. [id `checks`] Which checks must pass first?"), file: file, line: line)
            XCTAssertTrue(text.contains("Selection: choose any number of options; custom answer allowed"), file: file, line: line)
            XCTAssertTrue(text.contains("- unit\n"), file: file, line: line)
            XCTAssertTrue(text.contains("- integration"), file: file, line: line)
        }
    }

    private static func agentRunText(_ value: Value, op: String = "wait") throws -> String {
        try onlyText(ToolOutputFormatter.formatAgentRun(args: ["op": .string(op)], value: value))
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        XCTAssertEqual(blocks.count, 1)
        guard case let .text(text, _, _) = try XCTUnwrap(blocks.first) else {
            XCTFail("Expected a text block")
            return ""
        }
        return text
    }
}
