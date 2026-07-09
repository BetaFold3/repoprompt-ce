@testable import RepoPrompt
import RepoPromptRemoteWire
import XCTest

final class RemoteInteractionResponsePayloadTests: XCTestCase {
    func testAskUserSkipAllPayloadOmitsAnswers() throws {
        let interaction = makeTwoQuestionInteraction()
        let response = interaction.buildSkippedResponse(elapsedSeconds: 4)

        let payload = RemoteInteractionResponsePayload.askUser(response)

        XCTAssertTrue(payload.skip)
        XCTAssertNil(payload.answers)
        let object = try XCTUnwrap(payload.wirePayload(interactionID: "wire-question-1").objectValue)
        XCTAssertEqual(object["interaction_id"]?.stringValue, "wire-question-1")
        XCTAssertEqual(object["skip"]?.boolValue, true)
        XCTAssertNil(object["answers"])
    }

    func testAskUserPartialSkipKeepsAnswersAndOmitsSkip() throws {
        let interaction = makeTwoQuestionInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["first"] = AgentAskUserDraft(skipped: true)
        drafts["second"] = AgentAskUserDraft(customResponse: "answer")
        let response = try interaction.buildSubmittedResponse(drafts: drafts, elapsedSeconds: 5)

        let payload = RemoteInteractionResponsePayload.askUser(response)

        XCTAssertFalse(payload.skip)
        XCTAssertNotNil(payload.answers)
        let object = try XCTUnwrap(payload.wirePayload(interactionID: "wire-question-2").objectValue)
        XCTAssertNil(object["skip"])
        let answers = try XCTUnwrap(object["answers"]?.objectValue)
        let first = try XCTUnwrap(answers["first"]?.objectValue)
        XCTAssertEqual(first["answers"]?.arrayValue, [])
        XCTAssertEqual(first["skipped"]?.boolValue, true)
        XCTAssertNotNil(answers["second"]?.objectValue)
    }

    func testWirePayloadDropsAnswersWhenSkipTrue() throws {
        let payload = RemoteInteractionResponsePayload(
            skip: true,
            answers: .object(["question": .array([.string("answer")])])
        )

        let object = try XCTUnwrap(payload.wirePayload(interactionID: "wire-question-3").objectValue)

        XCTAssertEqual(object["skip"]?.boolValue, true)
        XCTAssertNil(object["answers"])
    }

    func testAllQuestionsIndividuallySkippedViaSubmitIsNotTopLevelSkip() throws {
        let interaction = makeTwoQuestionInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["first"] = AgentAskUserDraft(skipped: true)
        drafts["second"] = AgentAskUserDraft(skipped: true)
        let response = try interaction.buildSubmittedResponse(drafts: drafts, elapsedSeconds: 6)

        let payload = RemoteInteractionResponsePayload.askUser(response)

        XCTAssertFalse(payload.skip)
        XCTAssertNotNil(payload.answers)
        let object = try XCTUnwrap(payload.wirePayload(interactionID: "wire-question-4").objectValue)
        XCTAssertNil(object["skip"])
        XCTAssertNotNil(object["answers"]?.objectValue)
    }

    private func makeTwoQuestionInteraction() -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            remoteInteractionID: "wire-question",
            questions: [
                AgentAskUserQuestion(id: "first", question: "Skip this?", allowsCustom: true),
                AgentAskUserQuestion(id: "second", question: "Answer this", allowsCustom: true)
            ]
        )
    }
}
