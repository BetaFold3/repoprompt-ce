import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class OracleMessageTimestampTests: XCTestCase {
    func testLiveStorageAndHydrationPreserveMessageEventTimestamps() async {
        let userTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let completionTimestamp = Date(timeIntervalSince1970: 1_700_000_123)

        let user = AIChatMessage(
            content: "Question",
            isUser: true,
            timestamp: userTimestamp,
            sequenceIndex: 0
        )
        var assistant = AIChatMessage(
            content: "Answer",
            isUser: false,
            timestamp: userTimestamp,
            sequenceIndex: 1,
            allowedFilePaths: ["/tmp/example.swift"],
            modelName: "claude"
        )
        let revisionBeforeFinalization = assistant.revisionCount

        assistant.markFinalized(at: completionTimestamp)

        XCTAssertTrue(assistant.isFinalized)
        XCTAssertEqual(assistant.timestamp, completionTimestamp)
        XCTAssertEqual(assistant.revisionCount, revisionBeforeFinalization + 1)

        let revisionAfterFinalization = assistant.revisionCount
        XCTAssertFalse(assistant.markFinalized(at: completionTimestamp.addingTimeInterval(60)))
        XCTAssertEqual(assistant.timestamp, completionTimestamp)
        XCTAssertEqual(assistant.revisionCount, revisionAfterFinalization)

        let storedUser = StoredMessage(from: user)
        let storedAssistant = StoredMessage(from: assistant)
        XCTAssertEqual(storedUser.timestamp, userTimestamp)
        XCTAssertEqual(storedAssistant.timestamp, completionTimestamp)
        XCTAssertEqual(storedAssistant.allowedFilePaths, ["/tmp/example.swift"])

        let hydratedUser = await OracleViewModel.parseSingleRawMessage(storedUser)
        let hydratedAssistant = await OracleViewModel.parseSingleRawMessage(storedAssistant)
        XCTAssertEqual(hydratedUser.timestamp, userTimestamp)
        XCTAssertEqual(hydratedAssistant.timestamp, completionTimestamp)
    }

    func testHeadlessMessagesUseDistinctDispatchAndCompletionTimestamps() {
        let userTimestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let completionTimestamp = Date(timeIntervalSince1970: 1_800_000_456)
        let tokenInfo = ChatTokenInfo(promptTokens: 1203, completionTokens: 64, cost: 0.42)

        let messages = OracleViewModel.headlessStoredMessages(
            prompt: "Question",
            response: "Answer",
            modelName: "claude",
            tokenInfo: tokenInfo,
            allowedPaths: ["/tmp/example.swift"],
            userTimestamp: userTimestamp,
            assistantTimestamp: completionTimestamp
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].isUser)
        XCTAssertEqual(messages[0].timestamp, userTimestamp)
        XCTAssertEqual(messages[0].sequenceIndex, 0)
        XCTAssertNil(messages[0].promptTokens)

        XCTAssertFalse(messages[1].isUser)
        XCTAssertEqual(messages[1].timestamp, completionTimestamp)
        XCTAssertEqual(messages[1].sequenceIndex, 1)
        XCTAssertEqual(messages[1].promptTokens, 1203)
        XCTAssertEqual(messages[1].completionTokens, 64)
        XCTAssertEqual(messages[1].cost, 0.42)
        XCTAssertEqual(messages[1].modelName, "claude")
    }
}
