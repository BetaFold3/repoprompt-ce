import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexServiceTierVariantCatalogTests: XCTestCase {
    func testWireFixtureAndEvidenceDrivenFastEligibility() throws {
        let fixture = """
        {
          "data": [
            {"id":"gpt-5.6-sol","model":"gpt-5.6-sol","additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}],"defaultServiceTier":"default"},
            {"id":"gpt-5.6-terra","model":"gpt-5.6-terra","additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]},
            {"id":"gpt-5.6-luna","model":"gpt-5.6-luna","additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]},
            {"id":"gpt-5.5","model":"gpt-5.5","additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]},
            {"id":"gpt-5.4","model":"gpt-5.4","additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]},
            {"id":"gpt-daybreak-blue-latest","model":"gpt-daybreak-blue-latest","additionalSpeedTiers":[],"serviceTiers":[]},
            {"id":"gpt-5.4-mini","model":"gpt-5.4-mini","additionalSpeedTiers":[],"serviceTiers":[]},
            {"id":"gpt-5.3-codex-spark","model":"gpt-5.3-codex-spark","additionalSpeedTiers":[],"serviceTiers":[]}
          ]
        }
        """
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
        )
        let entries = try XCTUnwrap(object["data"] as? [[String: Any]])
        let models = entries.compactMap(CodexAppServerClient.parseRemoteModel)
        XCTAssertEqual(models.first?.serviceTiers.first?.id, "priority")
        XCTAssertEqual(models.first?.additionalSpeedTiers, ["fast"])
        XCTAssertEqual(models.first?.defaultServiceTier, "default")
        XCTAssertEqual(models.first?.hasSupportedReasoningEffortsEvidence, false)
        XCTAssertEqual(models.first?.hasAdditionalSpeedTiersEvidence, true)
        XCTAssertEqual(models.first?.hasServiceTiersEvidence, true)

        let capabilities = CodexModelCapabilitySnapshot(capabilities: models.map {
            .init(
                base: $0.id,
                efforts: Set($0.supportedReasoningEfforts.compactMap {
                    CodexReasoningEffort.parse($0.reasoningEffort)
                }),
                speedTiers: Set($0.additionalSpeedTiers)
            )
        })
        let eligible = Set(models.filter {
            CodexServiceTierVariantCatalog.isFastEligible(
                baseModelID: $0.id,
                capabilities: capabilities
            )
        }.map(\.id))
        let confirmed = Set(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"])
        XCTAssertEqual(eligible, confirmed)

        let seedEligible = Set(
            CodexModelCapabilitySnapshot.seedOnly.capabilitiesByBase.values
                .filter { $0.speedTiers.contains("fast") }
                .map(\.base)
        )
        XCTAssertTrue(seedEligible.isSubset(of: confirmed))
        for ineligible in ["gpt-6-astra", "gpt-daybreak-blue-latest", "gpt-5.4-mini", "gpt-5.3-codex-spark"] {
            XCTAssertNil(CodexServiceTierVariantCatalog.fastVariantID(
                baseModelID: ineligible,
                reasoningEffort: nil,
                capabilities: capabilities
            ))
        }
        XCTAssertEqual(
            CodexServiceTierVariantCatalog.fastVariantID(
                baseModelID: "gpt-5.4",
                reasoningEffort: .high,
                capabilities: capabilities
            ),
            "gpt-5.4-fast-high"
        )
        let degraded = CodexModelSpecifier(raw: "gpt-5.4-mini-fast", capabilities: capabilities)
        XCTAssertEqual(degraded.cliModelArgs, ["--model", "gpt-5.4-mini"])
        XCTAssertEqual(degraded.cliServiceTierConfigArgs, [])
    }

    func testTierlessWireObservationPreservesSeedFastUntilExplicitEmptyTierEvidence() throws {
        let suiteName = "CodexServiceTierVariantCatalogTests.WireEvidence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = CodexKnownModelBaseRegistry(defaults: defaults)

        let omitted = try XCTUnwrap(CodexAppServerClient.parseRemoteModel([
            "id": "gpt-5.6-sol",
            "model": "gpt-5.6-sol"
        ]))
        XCTAssertFalse(omitted.hasSupportedReasoningEffortsEvidence)
        XCTAssertFalse(omitted.hasAdditionalSpeedTiersEvidence)
        XCTAssertFalse(omitted.hasServiceTiersEvidence)
        registry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [omitted]))
        XCTAssertTrue(CodexServiceTierVariantCatalog.isFastEligible(
            baseModelID: "gpt-5.6-sol",
            capabilities: registry.capabilitySnapshot()
        ))

        let explicitEmpty = try XCTUnwrap(CodexAppServerClient.parseRemoteModel([
            "id": "gpt-5.6-sol",
            "model": "gpt-5.6-sol",
            "supportedReasoningEfforts": [],
            "additionalSpeedTiers": [],
            "serviceTiers": []
        ]))
        XCTAssertTrue(explicitEmpty.hasSupportedReasoningEffortsEvidence)
        XCTAssertTrue(explicitEmpty.hasAdditionalSpeedTiersEvidence)
        XCTAssertTrue(explicitEmpty.hasServiceTiersEvidence)
        registry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [explicitEmpty]))
        XCTAssertFalse(CodexServiceTierVariantCatalog.isFastEligible(
            baseModelID: "gpt-5.6-sol",
            capabilities: registry.capabilitySnapshot()
        ))
    }

    func testAgentRegistryFastSynthesisUsesInjectedKnownBaseRegistry() throws {
        let suiteName = "CodexServiceTierVariantCatalogTests.AgentRegistry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let knownRegistry = CodexKnownModelBaseRegistry(defaults: defaults)
        knownRegistry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [
            CodexAppServerClient.RemoteModel(
                id: "hermetic-model",
                model: "hermetic-model",
                displayName: "Hermetic",
                description: "",
                isDefault: false,
                additionalSpeedTiers: ["fast"]
            )
        ]))
        let registry = AgentCodexModelRegistry(
            defaults: defaults,
            knownModelBaseRegistry: knownRegistry
        )
        let options = registry.resolvedOptions(staticOptions: [
            AgentModelOption(
                rawValue: "hermetic-model",
                displayName: "Hermetic",
                description: nil,
                isDefault: false
            )
        ], preferredLiveModels: [])

        XCTAssertTrue(options.contains { $0.rawValue == "hermetic-model-fast" })
    }

    func testCodexCatalogFastSynthesisUsesInjectedSnapshot() throws {
        let suiteName = "CodexServiceTierVariantCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = CodexAppServerClient.RemoteModel(
            id: "hermetic-model",
            model: "hermetic-model",
            displayName: "Hermetic",
            description: "",
            isDefault: false
        )
        CodexDynamicModelStore.save([model], defaults: defaults)
        let eligible = CodexModelCapabilitySnapshot(capabilities: [
            .init(base: "hermetic-model", efforts: [], speedTiers: ["fast"])
        ])
        let ineligible = CodexModelCapabilitySnapshot(capabilities: [
            .init(base: "hermetic-model", efforts: [], speedTiers: [])
        ])

        XCTAssertTrue(CodexAIModelCatalog.modelsForPicker(
            staticModels: [],
            capabilities: eligible,
            defaults: defaults
        ).contains { $0.modelName == "hermetic-model-fast" })
        XCTAssertFalse(CodexAIModelCatalog.modelsForPicker(
            staticModels: [],
            capabilities: ineligible,
            defaults: defaults
        ).contains { $0.modelName == "hermetic-model-fast" })
    }
}
