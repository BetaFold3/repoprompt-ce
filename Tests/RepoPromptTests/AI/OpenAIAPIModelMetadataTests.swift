import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIAPIModelMetadataTests: XCTestCase {
    func testDecoderLoadsStrictVersionOneMetadataAndIgnoresInvalidModels() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "models": [
                {
                  "id": "gpt-5.2",
                  "display_name": "GPT-5.2",
                  "protocols": ["responses", "chat_completions"],
                  "reasoning": {
                    "modes": ["standard", "pro"],
                    "efforts": ["none", "low", "medium", "high", "xhigh", "max"]
                  },
                  "streaming": true,
                  "tokens": {
                    "context_window_tokens": 400000,
                    "max_input_tokens": 272000,
                    "max_output_tokens": 128000
                  }
                },
                {
                  "id": "invalid model id",
                  "protocols": ["responses"],
                  "streaming": true
                },
                {
                  "id": "gpt-5.2",
                  "display_name": "Duplicate",
                  "protocols": ["responses"],
                  "streaming": false
                }
              ]
            }
            """.utf8
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("openai-model-metadata-v1.json")
        try data.write(to: fileURL)

        let document = try OpenAIAPIModelMetadataDecoder.decode(contentsOf: fileURL)
        let model = try XCTUnwrap(document.models.first)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.models.count, 1)
        XCTAssertEqual(model.id, "gpt-5.2")
        XCTAssertEqual(model.displayName, "GPT-5.2")
        XCTAssertEqual(model.protocols, [.responses, .chatCompletions])
        XCTAssertEqual(model.reasoning?.modes, [.standard, .pro])
        XCTAssertEqual(model.reasoning?.efforts, [.none, .low, .medium, .high, .xhigh, .max])
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertEqual(model.tokens?.contextWindowTokens, 400_000)
        XCTAssertEqual(model.tokens?.maxInputTokens, 272_000)
        XCTAssertEqual(model.tokens?.maxOutputTokens, 128_000)
    }

    func testDecoderRejectsUnsupportedUltraReasoningEffort() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "models": [
                {
                  "id": "gpt-5.6-sol",
                  "protocols": ["responses"],
                  "reasoning": {
                    "modes": ["standard", "pro"],
                    "efforts": ["none", "low", "medium", "high", "xhigh", "max", "ultra"]
                  },
                  "streaming": true
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(data)) { error in
            XCTAssertEqual(error as? OpenAIAPIModelMetadataError, .noValidModels)
        }
    }

    func testDecoderRejectsOutOfRangeIntegerWithoutTrapping() throws {
        let data = Data(
            """
            {
              "schema_version": 1,
              "models": [
                {
                  "id": "gpt-huge-context",
                  "protocols": ["responses"],
                  "streaming": true,
                  "tokens": {
                    "context_window_tokens": 9223372036854775807
                  }
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(data)) { error in
            XCTAssertEqual(error as? OpenAIAPIModelMetadataError, .noValidModels)
        }
    }

    func testDecoderRejectsEndpointCredentialHeaderRecommendationAndArbitraryFields() throws {
        let cases: [(expectedPath: String, json: String)] = [
            (
                "$.endpoint",
                """
                {"schema_version":1,"models":[],"endpoint":"https://example.com"}
                """
            ),
            (
                "models[0].headers",
                """
                {"schema_version":1,"models":[{"id":"gpt-5","protocols":["responses"],"streaming":true,"headers":{"X-Test":"value"}}]}
                """
            ),
            (
                "models[0].api_key",
                """
                {"schema_version":1,"models":[{"id":"gpt-5","protocols":["responses"],"streaming":true,"api_key":"secret"}]}
                """
            ),
            (
                "models[0].recommendation",
                """
                {"schema_version":1,"models":[{"id":"gpt-5","protocols":["responses"],"streaming":true,"recommendation":"default"}]}
                """
            ),
            (
                "models[0].tokens.payload",
                """
                {"schema_version":1,"models":[{"id":"gpt-5","protocols":["responses"],"streaming":true,"tokens":{"context_window_tokens":1000,"payload":{"anything":true}}}]}
                """
            )
        ]

        for testCase in cases {
            XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(Data(testCase.json.utf8))) { error in
                XCTAssertEqual(
                    error as? OpenAIAPIModelMetadataError,
                    .forbiddenField(testCase.expectedPath)
                )
            }
        }
    }

    func testDecoderRejectsInvalidVersionAndDocumentsWithoutValidModels() throws {
        let futureVersion = Data(
            """
            {"schema_version":2,"models":[]}
            """.utf8
        )
        XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(futureVersion)) { error in
            XCTAssertEqual(
                error as? OpenAIAPIModelMetadataError,
                .unsupportedSchemaVersion(2)
            )
        }

        let invalidOnly = Data(
            """
            {"schema_version":1,"models":[{"id":"bad id","protocols":["unknown"],"streaming":1}]}
            """.utf8
        )
        XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(invalidOnly)) { error in
            XCTAssertEqual(error as? OpenAIAPIModelMetadataError, .noValidModels)
        }
    }

    func testVisibilityMergeRequiresExactVisibilityAndTrustedMetadataIntersection() throws {
        let document = try OpenAIAPIModelMetadataDecoder.decode(Data(
            """
            {
              "schema_version": 1,
              "models": [
                {"id":"trusted-visible","display_name":"Visible","protocols":["responses"],"streaming":true},
                {"id":"trusted-hidden","display_name":"Hidden","protocols":["responses"],"streaming":true}
              ]
            }
            """.utf8
        ))

        let merged = OpenAIAPIModelCatalogMerge.merge(
            visibleModelIDs: ["untrusted-visible-only", "trusted-visible"],
            trustedMetadata: document.models
        )

        XCTAssertEqual(merged.map(\.id), ["trusted-visible"])
        XCTAssertFalse(merged.contains { $0.id == "untrusted-visible-only" })
        XCTAssertFalse(merged.contains { $0.id == "trusted-hidden" })
    }
}
