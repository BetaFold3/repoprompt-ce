import Foundation
@testable import RepoPromptApp
import XCTest

final class ErrorExtensionsTests: XCTestCase {
    func testProviderWrappersPreserveExplicitAndCustomDescriptions() {
        let source = NSError(
            domain: "CodexAppServer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Input exceeds the maximum length of 1048576 characters."]
        )
        let cases: [(Error, String)] = [
            (AIProviderError.apiError(source: source), source.localizedDescription),
            (AIProviderError.invalidConfiguration(detail: "Prompt is too long"), "Prompt is too long"),
            (
                AIProviderError.unknown(source: AIProviderError.apiError(
                    source: CustomOpenAIProviderError.invalidModel(statusCode: 400, message: "Choose another model")
                )),
                "Model invalid (code 400): Choose another model"
            ),
            (AIProviderError.missingAPIKey, "Missing API key.")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.asFriendlyString(), expected)
        }
    }

    func testLocalizedAndExplicitNSErrorDescriptionsAreTrimmed() {
        XCTAssertEqual(DescribedError(errorDescription: " \nReadable detail.\t ").asFriendlyString(), "Readable detail.")
        let explicit = NSError(
            domain: "Provider",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: " \nProvider detail. \t"]
        )
        XCTAssertEqual(explicit.asFriendlyString(), "Provider detail.")
    }

    func testBlankAndUndescribedErrorsKeepDiagnosticFallback() {
        let cases: [Error] = [
            DescribedError(errorDescription: " \n\t"),
            DescribedError(errorDescription: nil),
            NSError(domain: "Provider", code: 7, userInfo: [NSLocalizedDescriptionKey: " \n\t"]),
            NSError(domain: "Provider", code: 7),
            PlainError.failure
        ]
        for error in cases {
            let nsError = error as NSError
            XCTAssertEqual(
                error.asFriendlyString(),
                "Unknown error [\(nsError.domain), code \(nsError.code)]: \(error)"
            )
        }
    }

    private struct DescribedError: LocalizedError {
        let errorDescription: String?
    }

    private enum PlainError: Error {
        case failure
    }
}
