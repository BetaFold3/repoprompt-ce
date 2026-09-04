import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIAPIModelMetadataTests: XCTestCase {
    func testBaselineDecodesExactlyAndPinsAstraCapabilities() throws {
        let report = try OpenAIAPIModelMetadataBaseline.decode()
        let document = report.document
        let model = try XCTUnwrap(document.models.only)

        XCTAssertEqual(OpenAIAPIModelMetadataBaseline.baselineVersion, "2026-09-04")
        XCTAssertEqual(
            OpenAIAPIModelMetadataBaseline.schemaVersion,
            OpenAIAPIModelMetadataDocument.currentSchemaVersion
        )
        XCTAssertEqual(
            document.schemaVersion,
            OpenAIAPIModelMetadataDocument.currentSchemaVersion
        )
        XCTAssertEqual(document.disabledModelIDs, [])
        XCTAssertEqual(report.rejectedRows, [])
        XCTAssertEqual(report.duplicateWarnings, [])
        XCTAssertEqual(model.id, "gpt-6-astra")
        XCTAssertEqual(model.displayName, "GPT-6 Astra")
        XCTAssertEqual(model.protocols, [.responses])
        XCTAssertEqual(model.reasoning?.modes, [.standard, .pro])
        XCTAssertEqual(model.reasoning?.efforts, [.low, .medium, .high, .xhigh, .max])
        XCTAssertFalse(model.reasoning?.efforts.contains(.none) ?? true)
        XCTAssertFalse(model.reasoning?.efforts.contains(.minimal) ?? true)
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertEqual(model.tokens?.contextWindowTokens, 1_050_000)
        XCTAssertNil(model.tokens?.maxInputTokens)
        XCTAssertEqual(model.tokens?.maxOutputTokens, 128_000)
        XCTAssertEqual(model.serviceTiers, [])
    }

    func testVersionOneCompatibilityNormalizesNewFields() throws {
        let document = try decode(
            """
            {
              "schema_version": 1,
              "models": [{
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
              }]
            }
            """
        )
        let model = try XCTUnwrap(document.models.only)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.disabledModelIDs, [])
        XCTAssertEqual(model.serviceTiers, [])
        XCTAssertEqual(model.tokens?.maxInputTokens, 272_000)
    }

    func testVersionTwoDecodesDisablesAndServiceTiers() throws {
        let document = try decode(
            """
            {
              "schema_version": 2,
              "models": [{
                "id": "gpt-tiered",
                "protocols": ["responses"],
                "streaming": true,
                "service_tiers": ["flex", "priority"]
              }],
              "disabled_model_ids": ["gpt-old"]
            }
            """
        )

        XCTAssertEqual(document.disabledModelIDs, ["gpt-old"])
        XCTAssertEqual(document.models.only?.serviceTiers, [.flex, .priority])
    }

    func testVersionTwoAllowsEmptyAndDisableOnlyDocuments() throws {
        let empty = try decode(#"{"schema_version":2,"models":[]}"#)
        let disableOnly = try decode(
            #"{"schema_version":2,"models":[],"disabled_model_ids":["gpt-old"]}"#
        )

        XCTAssertEqual(empty.models, [])
        XCTAssertEqual(disableOnly.disabledModelIDs, ["gpt-old"])
    }

    func testDecodeReportIncludesRejectedRowsAndDuplicateWarnings() throws {
        let report = try OpenAIAPIModelMetadataDecoder.decodeWithReport(Data(
            """
            {
              "schema_version": 2,
              "models": [
                {"id":"good","protocols":["responses"],"streaming":true},
                {"id":"bad id","protocols":["responses"],"streaming":true},
                {"id":"good","protocols":["responses"],"streaming":false}
              ]
            }
            """.utf8
        ))

        XCTAssertEqual(report.document.models.map(\.id), ["good"])
        XCTAssertEqual(
            report.rejectedRows,
            [.init(index: 1, modelID: nil, reason: .invalidModelID)]
        )
        XCTAssertEqual(
            report.duplicateWarnings,
            [.init(index: 2, modelID: "good")]
        )
    }

    func testStrictDecoderRejectsFutureVersionsAndVersionSpecificUnknownKeys() {
        assertError(
            #"{"schema_version":3,"models":[],"future_key":true}"#,
            equals: .unsupportedSchemaVersion(3)
        )
        assertError(
            #"{"schema_version":1,"models":[{"id":"gpt","protocols":["responses"],"streaming":true,"service_tiers":[]}]}"#,
            equals: .forbiddenField("models[0].service_tiers")
        )
        assertError(
            #"{"schema_version":2,"models":[],"endpoint":"https://example.com"}"#,
            equals: .forbiddenField("$.endpoint")
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"gpt","protocols":["responses"],"streaming":true,"api_key":"secret"}]}"#,
            equals: .forbiddenField("models[0].api_key")
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"gpt","protocols":["responses"],"streaming":true,"headers":{}}]}"#,
            equals: .forbiddenField("models[0].headers")
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"gpt","protocols":["responses"],"streaming":true,"recommendation":true}]}"#,
            equals: .forbiddenField("models[0].recommendation")
        )
    }

    func testStrictDecoderRejectsMalformedUnknownNestedAndInvalidOnlyInputs() {
        assertError("{", equals: .malformedJSON)
        assertError(
            #"{"schema_version":2,"models":[{"id":"gpt","protocols":["responses"],"streaming":true,"tokens":{"context_window_tokens":1000,"payload":true}}]}"#,
            equals: .forbiddenField("models[0].tokens.payload")
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"bad id","protocols":["unknown"],"streaming":1}]}"#,
            equals: .noValidModels
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"gpt","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["ultra"]},"streaming":true}]}"#,
            equals: .noValidModels
        )
        assertError(
            #"{"schema_version":2,"models":[{"id":"bad id","protocols":["responses"],"streaming":true}],"disabled_model_ids":["gpt-old"]}"#,
            equals: .noValidModels
        )
    }

    func testDecoderPreservesTokenAndCollectionBounds() {
        assertError(
            """
            {"schema_version":2,"models":[{
              "id":"gpt",
              "protocols":["responses"],
              "streaming":true,
              "tokens":{
                "context_window_tokens":100,
                "max_input_tokens":80,
                "max_output_tokens":30
              }
            }]}
            """,
            equals: .noValidModels
        )
        assertError(
            """
            {"schema_version":2,"models":[{
              "id":"gpt-int-boundary",
              "protocols":["responses"],
              "streaming":true,
              "tokens":{"context_window_tokens":\(Double(Int.max))}
            }]}
            """,
            equals: .noValidModels
        )
        let oversized = Data(repeating: 0x20, count: OpenAIAPIModelMetadataDecoder.maximumDocumentByteCount + 1)
        XCTAssertThrowsError(try OpenAIAPIModelMetadataDecoder.decode(oversized)) { error in
            XCTAssertEqual(error as? OpenAIAPIModelMetadataError, .documentTooLarge)
        }
    }

    func testVisibilityMergeRequiresExactVisibilityAndTrustedMetadataIntersection() throws {
        let document = try decode(
            """
            {
              "schema_version": 2,
              "models": [
                {"id":"trusted-visible","display_name":"Visible","protocols":["responses"],"streaming":true},
                {"id":"trusted-hidden","display_name":"Hidden","protocols":["responses"],"streaming":true}
              ]
            }
            """
        )

        let merged = OpenAIAPIModelCatalogMerge.merge(
            visibleModelIDs: ["untrusted-visible-only", "trusted-visible"],
            trustedMetadata: document.models
        )

        XCTAssertEqual(merged.map(\.id), ["trusted-visible"])
    }

    private func decode(_ json: String) throws -> OpenAIAPIModelMetadataDocument {
        try OpenAIAPIModelMetadataDecoder.decode(Data(json.utf8))
    }

    private func assertError(
        _ json: String,
        equals expected: OpenAIAPIModelMetadataError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try OpenAIAPIModelMetadataDecoder.decode(Data(json.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? OpenAIAPIModelMetadataError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
