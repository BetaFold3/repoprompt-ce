import Foundation
@testable import RepoPromptApp
import XCTest

final class AIProviderRequestSizeFailureTests: XCTestCase {
    func testReportedCharacterLimitsPreserveSentenceAndSourceDomain() throws {
        let cases: [(String, String, Int)] = [
            ("Input exceeds the maximum length of 1048576 characters.", "CodexAppServer", 1_048_576),
            ("Input exceeds the MAXIMUM LENGTH OF 1,048,576 CHARACTERS.", "OtherProvider", 1_048_576),
            ("🚫 Input exceeds the maximum length of 42 characters.", "CodexAppServer", 42)
        ]
        for (sentence, domain, limit) in cases {
            let source = NSError(domain: domain, code: 99, userInfo: [NSLocalizedDescriptionKey: " \n\(sentence) \n"])
            let wrapped = AIProviderError.unknown(source: AIProviderError.apiError(source: source))
            let failure = try XCTUnwrap(AIProviderRequestSizeFailure.detect(in: wrapped))
            XCTAssertEqual(failure.limit, .characters(limit))
            XCTAssertEqual(failure.providerSentence, sentence)
            XCTAssertEqual(failure.sourceDomain, domain)
        }
    }

    func testPromptTooLongDoesNotInventAMaximum() throws {
        let error = AIProviderError.invalidConfiguration(detail: " PROMPT IS TOO LONG ")
        let failure = try XCTUnwrap(AIProviderRequestSizeFailure.detect(in: error))
        XCTAssertEqual(failure.limit, .unreported)
        XCTAssertEqual(failure.providerSentence, "PROMPT IS TOO LONG")
        XCTAssertEqual(failure.sourceDomain, (error as NSError).domain)
    }

    func testMalformedOverflowingAndUnrelatedErrorsAreNotSizeFailures() {
        let descriptions = [
            "Input exceeds the maximum length of 0 characters.",
            "Input exceeds the maximum length of -42 characters.",
            "Input exceeds the maximum length of 12.5 characters.",
            "Input exceeds the maximum length of 1,04,8576 characters.",
            "Input exceeds the maximum length of 1,,024 characters.",
            "Input exceeds the maximum length of ,1024 characters.",
            "Input exceeds the maximum length of 1024, characters.",
            "Input exceeds the maximum length of 1234,567 characters.",
            "Input exceeds the maximum length of \(Int.max)0 characters.",
            "Input exceeds the maximum length of 1048576 tokens.",
            "Input exceeds the maximum length of characters.",
            "Request is too long.",
            "Prompt is too longer.",
            ""
        ]
        for description in descriptions {
            let error = NSError(domain: "CodexAppServer", code: 1_048_576, userInfo: [NSLocalizedDescriptionKey: description])
            XCTAssertNil(AIProviderRequestSizeFailure.detect(in: error), description)
        }
        XCTAssertNil(AIProviderRequestSizeFailure.detect(in: NSError(domain: "CodexAppServer", code: 1_048_576)))
    }

    func testProviderUnwrappingHasABoundedDepth() {
        var error: Error = AIProviderError.invalidConfiguration(detail: "Prompt is too long")
        for _ in 0 ..< 16 {
            error = AIProviderError.apiError(source: error)
        }
        XCTAssertEqual(AIProviderRequestSizeFailure.detect(in: error)?.limit, .unreported)
        error = AIProviderError.unknown(source: error)
        XCTAssertNil(AIProviderRequestSizeFailure.detect(in: error))
    }
}
