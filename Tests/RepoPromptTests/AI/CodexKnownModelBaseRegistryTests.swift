@testable import RepoPromptApp
import XCTest

final class CodexKnownModelBaseRegistryTests: XCTestCase {
    func testSeedCapabilitiesAndSnapshotOrderingAreStable() {
        let defaults = makeDefaults()
        defer { clear(defaults) }

        let registry = CodexKnownModelBaseRegistry(defaults: defaults)
        let first = registry.capabilitySnapshot()
        let second = registry.capabilitySnapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.knownBasesLongestFirst, second.knownBasesLongestFirst)
        XCTAssertEqual(first.capability(forBase: "gpt-5.6")?.efforts, Set([.max, .ultra]))
        XCTAssertEqual(first.capability(forBase: "gpt-5.6-sol")?.efforts, Set([.max, .ultra]))
        XCTAssertEqual(first.capability(forBase: "gpt-5.6-terra")?.efforts, Set([.max, .ultra]))
        XCTAssertEqual(first.capability(forBase: "gpt-5.6-luna")?.efforts, Set([.max]))
        XCTAssertEqual(first.capability(forBase: "gpt-5.5")?.efforts, [])
        XCTAssertEqual(first.capability(forBase: "gpt-5.4")?.efforts, [])
        XCTAssertTrue(first.capability(forBase: "gpt-5.1-codex-max") != nil)
        XCTAssertEqual(
            Set(registry.entries().filter { $0.additionalSpeedTiers.contains("fast") }.map(\.base)),
            Set(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"])
        )
    }

    func testLegacyFoldPreservesSeedUntilExplicitEmptyObservationAndPersistsOnlyOnUpdate() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let legacyData = Data("""
        [{"id":"gpt-5.6-sol","model":"gpt-5.6-sol","displayName":"Sol","description":"","isDefault":false}]
        """.utf8)
        defaults.set(legacyData, forKey: dynamicStorageKey)
        let legacyRecord = try XCTUnwrap(
            JSONDecoder().decode([CodexDynamicModelRecord].self, from: legacyData).first
        )
        XCTAssertFalse(legacyRecord.hasSupportedReasoningEffortsEvidence)
        XCTAssertFalse(legacyRecord.hasAdditionalSpeedTiersEvidence)
        XCTAssertFalse(legacyRecord.hasServiceTiersEvidence)

        let registry = CodexKnownModelBaseRegistry(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: CodexKnownModelBaseRegistry.storageKey))
        XCTAssertTrue(
            CodexServiceTierVariantCatalog.isFastEligible(
                baseModelID: "gpt-5.6-sol",
                capabilities: registry.capabilitySnapshot()
            )
        )
        XCTAssertEqual(
            CodexModelSpecifier(
                raw: "gpt-5.6-sol-ultra",
                capabilities: registry.capabilitySnapshot()
            ).reasoningEffort,
            .ultra
        )

        let currentRecords = CodexDynamicModelStore.canonicalRecords(from: [
            remoteModel(id: "gpt-5.6-sol", efforts: ["max"], speedTiers: [])
        ])
        let currentRecord = try XCTUnwrap(currentRecords.first)
        XCTAssertTrue(currentRecord.hasSupportedReasoningEffortsEvidence)
        XCTAssertTrue(currentRecord.hasAdditionalSpeedTiersEvidence)
        XCTAssertTrue(currentRecord.hasServiceTiersEvidence)
        registry.unionObserved(records: currentRecords, seenAt: Date(timeIntervalSince1970: 1))

        let updated = registry.capabilitySnapshot()
        XCTAssertFalse(CodexServiceTierVariantCatalog.isFastEligible(
            baseModelID: "gpt-5.6-sol",
            capabilities: updated
        ))
        XCTAssertEqual(
            CodexModelSpecifier(raw: "gpt-5.6-sol-ultra", capabilities: updated).reasoningEffort,
            .ultra
        )
        XCTAssertNotNil(defaults.data(forKey: CodexKnownModelBaseRegistry.storageKey))

        let reloaded = CodexKnownModelBaseRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.entries(), registry.entries())
        XCTAssertEqual(reloaded.capabilitySnapshot(), updated)
    }

    func testObservedBaseAndParseEffortsSurviveLaterPollWithoutThatBase() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let registry = CodexKnownModelBaseRegistry(defaults: defaults)

        registry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [
            remoteModel(id: "gpt-daybreak-blue-latest", efforts: ["max", "ultra"], speedTiers: ["fast"])
        ]), seenAt: Date(timeIntervalSince1970: 1))
        registry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [
            remoteModel(id: "some-other-model", efforts: ["low"], speedTiers: [])
        ]), seenAt: Date(timeIntervalSince1970: 2))

        let snapshot = registry.capabilitySnapshot()
        XCTAssertNotNil(registry.entries().first { $0.base == "gpt-daybreak-blue-latest" })
        let parsed = CodexModelSpecifier(
            raw: "gpt-daybreak-blue-latest-ultra",
            capabilities: snapshot
        )
        XCTAssertEqual(parsed.baseModel, "gpt-daybreak-blue-latest")
        XCTAssertEqual(parsed.reasoningEffort, .ultra)
    }

    func testBoundsAndUnknownSchemaFallbackDoesNotOverwriteFutureData() throws {
        let boundedDefaults = makeDefaults()
        defer { clear(boundedDefaults) }
        let bounded = CodexKnownModelBaseRegistry(defaults: boundedDefaults)
        let observed = (0 ... CodexKnownModelBaseRegistry.maximumEntryCount).map {
            remoteModel(id: "observed-\($0)", efforts: ["low"], speedTiers: [])
        }
        bounded.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: observed), seenAt: Date())
        XCTAssertEqual(bounded.entries().count, CodexKnownModelBaseRegistry.maximumEntryCount)
        XCTAssertNotNil(bounded.capabilitySnapshot().capability(forBase: "gpt-5.1-codex-max"))

        let unknownDefaults = makeDefaults()
        defer { clear(unknownDefaults) }
        let unknownData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 999,
            "entries": [[
                "base": "future-only",
                "efforts": ["ultra"],
                "additionalSpeedTiers": ["fast"],
                "serviceTiers": [],
                "source": "observed"
            ]]
        ])
        unknownDefaults.set(unknownData, forKey: CodexKnownModelBaseRegistry.storageKey)

        let unknown = CodexKnownModelBaseRegistry(defaults: unknownDefaults)
        unknown.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [
            remoteModel(id: "new-observation", efforts: ["max"], speedTiers: ["fast"])
        ]))
        XCTAssertNil(unknown.capabilitySnapshot().capability(forBase: "future-only"))
        XCTAssertNotNil(unknown.capabilitySnapshot().capability(forBase: "gpt-5.6-sol"))
        XCTAssertEqual(unknownDefaults.data(forKey: CodexKnownModelBaseRegistry.storageKey), unknownData)
    }

    private let dynamicStorageKey = "CodexDynamicModelRecords"

    private func remoteModel(
        id: String,
        efforts: [String],
        speedTiers: [String]
    ) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(
            id: id,
            model: id,
            displayName: id,
            description: "",
            isDefault: false,
            supportedReasoningEfforts: efforts.map {
                .init(reasoningEffort: $0, description: "")
            },
            additionalSpeedTiers: speedTiers
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "CodexKnownModelBaseRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: CodexKnownModelBaseRegistry.storageKey)
        defaults.removeObject(forKey: dynamicStorageKey)
    }
}
