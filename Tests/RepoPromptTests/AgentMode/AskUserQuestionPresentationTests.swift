@testable import RepoPromptApp
import XCTest

final class AskUserQuestionPresentationTests: XCTestCase {
    func testStructuredExchangePreservesContextOptionsAndCustomResponse() throws {
        let args = #"""
        {
          "title": "Decision",
          "context": "Shared context\nSecond shared line",
          "questions": [
            {
              "id": "mode",
              "header": "Mode",
              "question": "Which mode?\nConsider the tradeoffs.",
              "context": "Question context\nSecond context line",
              "options": [
                "Quick",
                {"label": "Careful", "description": "More analysis\nSecond description line"},
                {"label": "Audit", "description": null}
              ]
            },
            {
              "id": "scope",
              "question": "Which areas?",
              "options": [{"label": "UI", "description": "Presentation"}, "Runtime"]
            }
          ]
        }
        """#
        let result = #"""
        {
          "answers": {
            "mode": {
              "answers": ["Careful", "Additional constraints\nPreserve the details"],
              "selected_options": ["Careful"],
              "custom_response": "Additional constraints\nPreserve the details",
              "skipped": false
            },
            "scope": {
              "selected_options": ["UI", "Runtime"],
              "custom_response": "Keep pending UI unchanged"
            }
          }
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertFalse(summary.skipped)
        XCTAssertFalse(summary.timedOut)
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.title, "Decision")
        XCTAssertEqual(summary.displayTitle, "Decision (2 questions)")
        XCTAssertEqual(summary.contextLine, "Shared context\nSecond shared line")
        XCTAssertEqual(summary.questions.count, 2)

        let mode = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(mode.id, "mode")
        XCTAssertEqual(mode.header, "Mode")
        XCTAssertEqual(mode.question, "Which mode?\nConsider the tradeoffs.")
        XCTAssertEqual(mode.context, "Question context\nSecond context line")
        XCTAssertEqual(mode.options.map(\.label), ["Quick", "Careful", "Audit"])
        XCTAssertEqual(mode.options.map(\.description), [nil, "More analysis\nSecond description line", nil])
        XCTAssertEqual(mode.options.map(\.isSelected), [false, true, false])
        XCTAssertEqual(mode.answer, "Careful, Additional constraints\nPreserve the details")
        XCTAssertEqual(mode.customResponse, "Additional constraints\nPreserve the details")
        XCTAssertFalse(mode.skipped)

        let scope = try XCTUnwrap(summary.questions.last)
        XCTAssertEqual(scope.id, "scope")
        XCTAssertNil(scope.header)
        XCTAssertNil(scope.context)
        XCTAssertEqual(scope.options.map(\.label), ["UI", "Runtime"])
        XCTAssertEqual(scope.options.map(\.description), ["Presentation", nil])
        XCTAssertEqual(scope.options.map(\.isSelected), [true, true])
        XCTAssertEqual(scope.answer, "UI, Runtime, Keep pending UI unchanged")
        XCTAssertEqual(scope.customResponse, "Keep pending UI unchanged")
        XCTAssertFalse(scope.skipped)
    }

    func testMalformedOptionalEntriesDoNotDiscardQuestionOrAnswerText() throws {
        let args = #"""
        {
          "title": [],
          "context": true,
          "questions": [{
            "id": 27,
            "header": {},
            "question": "Keep this question",
            "context": {"unexpected": "shape"},
            "options": [
              null, false, 15,
              {"description": "Missing label"},
              {"label": 25},
              " ",
              {"label": " \t "},
              "First",
              {"label": "Second", "description": "Second details"},
              {"label": "Third", "description": false}
            ]
          }]
        }
        """#
        let result = #"""
        {
          "answers": {
            "question_1": {
              "answers": ["First", null, 17, "Stored answer", false],
              "selected_options": [false, "Second", 77, null],
              "custom_response": {},
              "skipped": "invalid"
            }
          },
          "timed_out": {},
          "skipped": [],
          "response": 21
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertNil(summary.title)
        XCTAssertNil(summary.contextLine)
        XCTAssertNil(summary.statusText)
        XCTAssertFalse(summary.skipped)
        XCTAssertFalse(summary.timedOut)
        XCTAssertEqual(summary.questions.count, 1)
        let question = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(question.id, "question_1")
        XCTAssertNil(question.header)
        XCTAssertEqual(question.question, "Keep this question")
        XCTAssertNil(question.context)
        XCTAssertEqual(question.options.map(\.label), ["First", "Second", "Third"])
        XCTAssertEqual(question.options.map(\.description), [nil, "Second details", nil])
        XCTAssertEqual(question.options.map(\.isSelected), [false, true, false])
        XCTAssertEqual(question.answer, "First, Stored answer")
        XCTAssertNil(question.customResponse)
        XCTAssertFalse(question.skipped)
    }

    func testMalformedOptionalContainersAndSiblingEntriesPreserveValidExchange() throws {
        let args = #"""
        {
          "question": [],
          "questions": [
            null,
            true,
            {
              "id": "first",
              "question": "First question",
              "context": "First context",
              "options": {"invalid": "container"}
            },
            {"question": 25},
            {
              "id": "second",
              "question": "Second question",
              "options": ["Kept"]
            }
          ]
        }
        """#
        let result = #"""
        {
          "answers": {
            "first": {
              "answers": ["First answer"],
              "selected_options": "invalid",
              "custom_response": [],
              "skipped": {}
            },
            "second": {
              "answers": "invalid",
              "selected_options": ["Kept"],
              "custom_response": "Second detail",
              "skipped": false
            },
            "unreadable": 7
          },
          "response": []
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertEqual(summary.questions.map(\.id), ["first", "second"])
        XCTAssertEqual(summary.questions.map(\.question), ["First question", "Second question"])
        XCTAssertEqual(summary.questions.map(\.answer), ["First answer", "Kept, Second detail"])

        let first = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(first.context, "First context")
        XCTAssertTrue(first.options.isEmpty)
        XCTAssertNil(first.customResponse)

        let second = try XCTUnwrap(summary.questions.last)
        XCTAssertEqual(second.options.map(\.label), ["Kept"])
        XCTAssertEqual(second.options.map(\.isSelected), [true])
        XCTAssertEqual(second.customResponse, "Second detail")
    }

    func testHistoricalScalarPayloadsRemainUnchanged() throws {
        let args = #"{"question":"  Historical question  ","title":"Ignored title","context":"Ignored context"}"#
        let cases: [(name: String, result: String?, answer: String, skipped: Bool, timedOut: Bool, status: String?)] = [
            ("submitted", #"{"response":"  Legacy answer  "}"#, "Legacy answer", false, false, nil),
            ("raw response", "  Raw response \n", "Raw response", false, false, nil),
            ("no response", nil, "No response", false, false, nil),
            ("skip takes precedence", #"{"response":"ignored","skipped":true,"timed_out":true}"#, "Skipped", true, true, "Skipped"),
            ("timeout with response", #"{"response":"Late response","timed_out":true}"#, "Late response", false, true, "Timed out"),
            ("timeout without response", #"{"timed_out":true}"#, "Timed out", false, true, "Timed out")
        ]

        for testCase in cases {
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: testCase.result)

            XCTAssertTrue(summary.isHistoricalScalar, testCase.name)
            XCTAssertNil(summary.title, testCase.name)
            XCTAssertNil(summary.contextLine, testCase.name)
            XCTAssertEqual(summary.displayTitle, "Question", testCase.name)
            XCTAssertEqual(summary.statusText, testCase.status, testCase.name)
            XCTAssertEqual(summary.skipped, testCase.skipped, testCase.name)
            XCTAssertEqual(summary.timedOut, testCase.timedOut, testCase.name)
            XCTAssertEqual(summary.questions.count, 1, testCase.name)

            let question = try XCTUnwrap(summary.questions.first, testCase.name)
            XCTAssertEqual(question.id, "question", testCase.name)
            XCTAssertNil(question.header, testCase.name)
            XCTAssertEqual(question.question, "Historical question", testCase.name)
            XCTAssertNil(question.context, testCase.name)
            XCTAssertTrue(question.options.isEmpty, testCase.name)
            XCTAssertNil(question.customResponse, testCase.name)
            XCTAssertEqual(question.answer, testCase.answer, testCase.name)
            XCTAssertEqual(question.skipped, testCase.skipped, testCase.name)
        }
    }

    func testStructuredSkippedAndTimedOutSemanticsRemainUnchanged() throws {
        let args = #"{"questions":[{"id":"answer","question":"Decision?","context":"Details","options":["Yes","No"]}]}"#
        let cases: [(name: String, result: String, answer: String?, questionSkipped: Bool, skipped: Bool, timedOut: Bool, status: String?)] = [
            ("overall skip", #"{"skipped":true}"#, "Skipped", true, true, false, "Skipped"),
            ("question skip", #"{"answers":{"answer":{"skipped":true,"answers":[],"selected_options":[]}}}"#, "Skipped", true, false, false, nil),
            ("timeout without answer", #"{"timed_out":true}"#, "No response (timed out)", false, false, true, "Timed out"),
            ("empty answer", #"{"answers":{"answer":{"answers":[],"selected_options":[],"custom_response":" \n "}}}"#, "No response", false, false, false, nil),
            ("missing answer", "{}", nil, false, false, false, nil),
            ("timeout with answer", #"{"timed_out":true,"answers":{"answer":{"answers":["Late response"]}}}"#, "Late response", false, false, true, "Timed out")
        ]

        for testCase in cases {
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: testCase.result)

            XCTAssertFalse(summary.isHistoricalScalar, testCase.name)
            XCTAssertEqual(summary.statusText, testCase.status, testCase.name)
            XCTAssertEqual(summary.skipped, testCase.skipped, testCase.name)
            XCTAssertEqual(summary.timedOut, testCase.timedOut, testCase.name)
            XCTAssertEqual(summary.questions.count, 1, testCase.name)
            let question = try XCTUnwrap(summary.questions.first, testCase.name)
            XCTAssertEqual(question.answer, testCase.answer, testCase.name)
            XCTAssertEqual(question.skipped, testCase.questionSkipped, testCase.name)
            XCTAssertNil(question.customResponse, testCase.name)
            XCTAssertEqual(question.options.map(\.isSelected), [false, false], testCase.name)
        }
    }
}
