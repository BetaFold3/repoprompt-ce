import Foundation
@testable import RepoPromptApp
import XCTest

final class OracleErrorPresenterTests: XCTestCase {
    func testCharacterLimitCopyNamesOnlyCodexAndQualifiesPromptTokenEstimate() {
        let cases: [(String, Int, String)] = [
            (
                "CodexAppServer", 1_048_576,
                "Tip: Deselect some files or use slices, or start a new Oracle chat — this Oracle provider resends the full conversation history with every request."
            ),
            ("OtherProvider", 2048, "Tip: Deselect some files or use slices, or start a new Oracle chat.")
        ]
        for (domain, limit, tip) in cases {
            let error = AIProviderError.apiError(source: NSError(
                domain: domain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Input exceeds the maximum length of \(limit) characters."]
            ))
            let provider = domain == "CodexAppServer" ? "The Codex app server" : "The provider"
            XCTAssertEqual(
                OracleErrorPresenter.message(for: error, tokenCount: 1234),
                "Request too large. \(provider) rejected this request; its reported input limit is \(limit.formatted()) characters, which is separate from the model's token context window."
                    + "\n\nCurrent request size: ~\(1234.formatted()) tokens (current Prompt context estimate; not a character count and excludes Oracle conversation messages and provider-added text)."
                    + "\n\n\(tip)"
            )
        }
    }

    func testUnreportedLimitCopyAndNonpositiveTokenCountOmitInventedSizes() {
        let error = AIProviderError.invalidConfiguration(detail: "Prompt is too long")
        let expected = "Request too large. The provider rejected this request as too long and did not report a maximum size."
            + "\n\nTip: Deselect some files or use slices, or start a new Oracle chat to drop earlier conversation history."
        for tokenCount in [0, -1] {
            XCTAssertEqual(OracleErrorPresenter.message(for: error, tokenCount: tokenCount), expected)
        }
    }

    func testContextWindowUsesOnlyExactCapturedModelMetadata() {
        let error = AIProviderError.invalidConfiguration(detail: "Prompt is too long")
        let withoutWindow = OracleErrorPresenter.message(for: error)
        let exact = OracleErrorPresenter.message(for: error, capturedModel: .geminiFlashLatest)
        XCTAssertEqual(
            exact,
            "Request too large. The provider rejected this request as too long and did not report a maximum size."
                + "\n\nModel context window: about \(1_000_000.formatted()) tokens. This is separate from the provider's input-size limit and is not the available input budget."
                + "\n\nTip: Deselect some files or use slices, or start a new Oracle chat to drop earlier conversation history."
        )
        let nonExactModels: [AIModel?] = [nil, .codexCliGpt5Low, .codexCustom(name: "unknown")]
        for model in nonExactModels {
            XCTAssertEqual(OracleErrorPresenter.message(for: error, capturedModel: model), withoutWindow)
        }
    }

    func testNetworkAndCustomOpenAIHandlingKeepPrecedenceAndExistingCopy() {
        let networkCases: [(Int, String)] = [
            (NSURLErrorTimedOut, "The request timed out. Please check your internet connection and try again."),
            (NSURLErrorCannotConnectToHost, "Unable to connect to the server. Please try again later."),
            (NSURLErrorNetworkConnectionLost, "The network connection was lost. Please check your internet connection and try again."),
            (NSURLErrorNotConnectedToInternet, "No internet connection. Please check your network settings and try again."),
            (NSURLErrorSecureConnectionFailed, "Secure connection failed.")
        ]
        for (code, expected) in networkCases {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "Prompt is too long"])
            XCTAssertEqual(OracleErrorPresenter.message(for: error, tokenCount: 1234, capturedModel: .geminiFlashLatest), expected)
        }
        let suffix = "\n\nCurrent request size: ~\(1234.formatted()) tokens\nTip: Try deselecting some files to reduce the context size."
        let customCases: [(Error, String)] = [
            (
                CustomOpenAIProviderError.requestTooLarge(),
                "Request too large. The model has strict token limits and the provided request exceeds them." + suffix
            ),
            (
                CustomOpenAIProviderError.requestFailed(statusCode: 400, message: "no additional details"),
                "OpenAI error: Request failed. This often occurs when the request is too large or there are insufficient credits on your account." + suffix
            ),
            (
                CustomOpenAIProviderError.requestFailed(statusCode: 400, message: "Prompt is too long"),
                "Request failed (code 400): Prompt is too long"
            ),
            (
                NSError(domain: "Provider", code: 400, userInfo: [NSLocalizedDescriptionKey: "no additional details"]),
                "Request failed. This often occurs when the request is too large or there are insufficient credits on your account." + suffix
            ),
            (
                AIProviderError.missingAPIKey,
                "Missing API key."
            )
        ]
        for (error, expected) in customCases {
            XCTAssertEqual(OracleErrorPresenter.message(for: error, tokenCount: 1234, capturedModel: .geminiFlashLatest), expected)
        }
    }
}
