import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIConfiguredModelProjectionTests: XCTestCase {
    func testVisibleAstraProjectsExactlyTenBaseChoicesWithoutServiceTierWrappers() throws {
        let models = try OpenAIConfiguredModelProjection.models(
            rows: astraRows(),
            visibleModelIDs: ["gpt-6-astra"],
            typedCustomModelID: nil,
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )

        XCTAssertEqual(models.count, 10)
        XCTAssertTrue(models.allSatisfy { model in
            guard case let .openAIConfigured(selection) = model else { return false }
            return selection.modelID == "gpt-6-astra"
                && selection.supportsStreaming == true
                && !model.isOpenAIServiceTierVariant
        })
    }

    func testUnreportedTrustedModelIsHiddenUnlessTyped() throws {
        let rows = try astraRows()
        XCTAssertTrue(OpenAIConfiguredModelProjection.models(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: nil,
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        ).isEmpty)

        XCTAssertEqual(OpenAIConfiguredModelProjection.models(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: "gpt-6-astra",
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        ).count, 10)
    }

    func testTypedTrustedAstraUsesAllDeclaredModesAndEfforts() throws {
        let models = try OpenAIConfiguredModelProjection.models(
            rows: astraRows(),
            visibleModelIDs: [],
            typedCustomModelID: "gpt-6-astra",
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )
        let selections = models.compactMap { model -> OpenAIConfiguredModelSelection? in
            guard case let .openAIConfigured(selection) = model else { return nil }
            return selection
        }

        XCTAssertEqual(Set(selections.map(\.reasoningMode)), Set(OpenAIReasoningMode.allCases))
        XCTAssertEqual(
            Set(selections.map(\.reasoningEffort)),
            Set([.low, .medium, .high, .xhigh, .max])
        )
    }

    func testUnknownOfficialCustomKeepsLegacyFourEffortResponsesVariants() {
        let models = OpenAIConfiguredModelProjection.models(
            rows: [],
            visibleModelIDs: [],
            typedCustomModelID: "gpt-future",
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )

        XCTAssertEqual(models, Set(AIModel.openAICustomResponsesVariants(for: "gpt-future")))
        XCTAssertEqual(models.count, 5)
    }

    func testTypedTrustedDelimiterIDFallsBackWhenConfiguredRawValueCannotProject() throws {
        let rows = try metadataRows(
            """
            {
              "schema_version":2,
              "models":[{
                "id":"gpt__delimiter",
                "protocols":["responses"],
                "reasoning":{"modes":["standard"],"efforts":["medium"]},
                "streaming":true
              }]
            }
            """
        )

        let models = OpenAIConfiguredModelProjection.models(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: "gpt__delimiter",
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )

        XCTAssertEqual(models, Set(AIModel.openAICustomResponsesVariants(for: "gpt__delimiter")))
    }

    func testTypedTrustedNonProjectingRowsFallBackToCustomResponsesVariants() throws {
        let rows = try metadataRows(
            """
            {
              "schema_version":2,
              "models":[
                {"id":"chat-only","protocols":["chat_completions"],"streaming":true},
                {"id":"responses-no-reasoning","protocols":["responses"],"streaming":true}
              ]
            }
            """
        )

        for modelID in rows.map(\.id) {
            let models = OpenAIConfiguredModelProjection.models(
                rows: rows,
                visibleModelIDs: [],
                typedCustomModelID: modelID,
                isOfficialOpenAIHost: true,
                staticWireModelNames: AIModel.staticOpenAIWireModelNames
            )
            XCTAssertEqual(models, Set(AIModel.openAICustomResponsesVariants(for: modelID)))
        }
    }

    func testNonOfficialEndpointIgnoresTrustedMetadataAndKeepsLegacyCustomRouting() throws {
        let models = try OpenAIConfiguredModelProjection.models(
            rows: astraRows(),
            visibleModelIDs: ["gpt-6-astra"],
            typedCustomModelID: "gpt-6-astra",
            isOfficialOpenAIHost: false,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )

        XCTAssertEqual(models, [.openaiCustom(name: "gpt-6-astra")])
    }

    func testWholeWireStaticCollisionSuppressesConfiguredButPreservesTypedCustomProjection() throws {
        let rows = try metadataRows(
            """
            {
              "schema_version":2,
              "models":[{
                "id":"gpt-5.6-sol",
                "display_name":"Trusted Sol",
                "protocols":["responses"],
                "reasoning":{"modes":["standard","pro"],"efforts":["low","high"]},
                "streaming":true
              }]
            }
            """
        )

        let models = OpenAIConfiguredModelProjection.models(
            rows: rows,
            visibleModelIDs: ["gpt-5.6-sol"],
            typedCustomModelID: "gpt-5.6-sol",
            isOfficialOpenAIHost: true,
            staticWireModelNames: AIModel.staticOpenAIWireModelNames
        )

        XCTAssertEqual(models, Set(AIModel.openAICustomResponsesVariants(for: "gpt-5.6-sol")))
    }

    func testOfficialLiveRefreshUsesRequestWireIDsAndRetainsWholeVisibleEffortFamily() {
        let statics = Set(AIModel.modelsForProvider(.openAI))
        let requestModelIDs = Set(statics.map {
            OpenAIResponseRequestPlan.make(model: $0, defaultServiceTier: nil).modelID
        })

        XCTAssertEqual(AIModel.staticOpenAIWireModelNames, requestModelIDs)
        for model in statics {
            XCTAssertEqual(
                AIModel.staticOpenAIRequestWireModelID(for: model),
                OpenAIResponseRequestPlan.make(model: model, defaultServiceTier: nil).modelID
            )
        }

        let filtered = OpenAIConfiguredModelProjection.staticModels(
            statics,
            visibleModelIDs: ["gpt-5.2"],
            isOfficialOpenAIHost: true,
            hasSuccessfulLiveRefresh: true
        )

        XCTAssertEqual(filtered, [.gpt5, .gpt5Low, .gpt5High, .gpt5XHigh])
    }

    func testCurrentSelectionRemainsDecodableButIsNotReinsertedOrUsedAsFallback() throws {
        let current = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "gpt-5.6-sol",
            reasoningMode: .pro,
            reasoningEffort: .high
        ))
        let currentModel = AIModel.openAIConfigured(selection: current)
        let available = OpenAIConfiguredModelProjection.staticModels(
            [.gpt56Sol, .gpt54],
            visibleModelIDs: ["gpt-5.4"],
            isOfficialOpenAIHost: true,
            hasSuccessfulLiveRefresh: true
        )

        XCTAssertFalse(available.contains(.gpt56Sol))
        XCTAssertFalse(available.contains(currentModel))
        XCTAssertEqual(AIModel.fromModelName(currentModel.rawValue), currentModel)
        XCTAssertNotEqual(
            AIModel.findBestAvailableModel(
                in: Array(available),
                desiredFormat: PromptViewModel.FileEditFormat.none,
                priorities: [.gpt56Sol, .gpt54]
            ),
            currentModel
        )
    }

    func testCachedOnlySnapshotDoesNotHideStaticModels() {
        let statics: Set<AIModel> = [.gpt56Sol, .gpt54]
        let projected = OpenAIConfiguredModelProjection.staticModels(
            statics,
            visibleModelIDs: ["gpt-5.4"],
            isOfficialOpenAIHost: true,
            hasSuccessfulLiveRefresh: false
        )

        XCTAssertEqual(projected, statics)
    }

    func testProjectedMetadataRowCountExcludesResolvedButNonVisibleRows() throws {
        let rows = try metadataRows(
            """
            {"schema_version":2,"models":[
              {"id":"visible","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["medium"]},"streaming":true},
              {"id":"resolved-not-visible","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["medium"]},"streaming":true}
            ]}
            """
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(OpenAIConfiguredModelProjection.projectedMetadataRowCount(
            rows: rows,
            visibleModelIDs: ["visible"],
            typedCustomModelID: nil,
            isOfficialOpenAIHost: true,
            staticWireModelNames: []
        ), 1)
        XCTAssertEqual(OpenAIConfiguredModelProjection.projectedMetadataRowCount(
            rows: rows,
            visibleModelIDs: ["visible"],
            typedCustomModelID: nil,
            isOfficialOpenAIHost: false,
            staticWireModelNames: []
        ), 0)
    }

    func testProjectedMetadataRowCountUsesTypedTrustedProjectionSemantics() throws {
        let rows = try astraRows()

        XCTAssertEqual(OpenAIConfiguredModelProjection.projectedMetadataRowCount(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: "gpt-6-astra",
            isOfficialOpenAIHost: true,
            staticWireModelNames: []
        ), 1)
        XCTAssertEqual(OpenAIConfiguredModelProjection.projectedMetadataRowCount(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: "unknown-model",
            isOfficialOpenAIHost: true,
            staticWireModelNames: []
        ), 0)
        XCTAssertEqual(OpenAIConfiguredModelProjection.projectedMetadataRowCount(
            rows: rows,
            visibleModelIDs: [],
            typedCustomModelID: "gpt-6-astra",
            isOfficialOpenAIHost: false,
            staticWireModelNames: []
        ), 0)
    }

    func testLegacyTierVariantsStructurallyExcludeConfiguredModels() throws {
        let configured = try XCTUnwrap(OpenAIConfiguredModelSelection(
            modelID: "configured-but-not-projected",
            reasoningMode: .standard,
            reasoningEffort: .medium
        ))
        let configuredBase = AIModel.openAIConfigured(selection: configured)
        let unknownCustom = AIModel.openaiCustomResponses(name: "unknown-custom")
        let variants = OpenAIConfiguredModelProjection.legacyServiceTierVariants(
            for: [configuredBase, unknownCustom],
            enabled: true
        )

        XCTAssertEqual(variants.count, 3)
        XCTAssertTrue(variants.allSatisfy { model in
            guard case let .openAIServiceTierVariant(base, tier) = model else { return false }
            return base == unknownCustom && ["default", "flex", "priority"].contains(tier)
        })
        XCTAssertFalse(variants.contains { model in
            guard case let .openAIServiceTierVariant(base, _) = model else { return false }
            return base == configuredBase
        })
    }

    func testServiceTierVariantsUseExactlyRowDeclaredTiers() throws {
        let rows = try metadataRows(
            """
            {"schema_version":2,"models":[
              {"id":"none","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["medium"]},"streaming":true},
              {"id":"flex","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["medium"]},"streaming":true,"service_tiers":["flex"]},
              {"id":"both","protocols":["responses"],"reasoning":{"modes":["standard"],"efforts":["medium"]},"streaming":true,"service_tiers":["flex","priority"]}
            ]}
            """
        )
        let bases = OpenAIConfiguredModelProjection.models(
            rows: rows,
            visibleModelIDs: rows.map(\.id),
            typedCustomModelID: nil,
            isOfficialOpenAIHost: true,
            staticWireModelNames: []
        )

        XCTAssertTrue(OpenAIConfiguredModelProjection.serviceTierVariants(
            for: bases,
            rows: rows,
            enabled: false
        ).isEmpty)

        let variants = OpenAIConfiguredModelProjection.serviceTierVariants(
            for: bases,
            rows: rows,
            enabled: true
        )
        let tiersByID = Dictionary(grouping: variants.compactMap { model -> (String, String)? in
            guard case let .openAIServiceTierVariant(base, tier) = model,
                  case let .openAIConfigured(selection) = base
            else { return nil }
            return (selection.modelID, tier)
        }, by: \.0).mapValues { Set($0.map(\.1)) }

        XCTAssertEqual(variants.count, 6)
        XCTAssertEqual(tiersByID["none"], ["default"])
        XCTAssertEqual(tiersByID["flex"], ["default", "flex"])
        XCTAssertEqual(tiersByID["both"], ["default", "flex", "priority"])
    }

    private func astraRows() throws -> [OpenAIAPIModelMetadata] {
        try OpenAIAPIModelMetadataBaseline.decode().document.models
    }

    private func metadataRows(_ json: String) throws -> [OpenAIAPIModelMetadata] {
        try OpenAIAPIModelMetadataDecoder.decode(Data(json.utf8)).models
    }
}
