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

    func testFirstResolvedOptionMatchesResolvedOptionsFirstAcrossSources() throws {
        func makeDefaults(_ label: String) throws -> UserDefaults {
            let suiteName = "CodexServiceTierVariantCatalogTests.FirstResolved.\(label).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
            return defaults
        }
        func remote(
            _ id: String,
            _ displayName: String,
            efforts: [String] = [],
            speedTiers: [String] = [],
            isDefault: Bool = false
        ) -> CodexAppServerClient.RemoteModel {
            CodexAppServerClient.RemoteModel(
                id: id,
                model: id,
                displayName: displayName,
                description: "",
                isDefault: isDefault,
                supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") },
                additionalSpeedTiers: speedTiers
            )
        }
        func slug(_ slug: String) -> (AgentModelOption) -> Bool {
            {
                CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: $0.rawValue)
                    .caseInsensitiveCompare(slug) == .orderedSame
            }
        }
        func raw(_ raw: String) -> (AgentModelOption) -> Bool {
            { $0.rawValue == raw }
        }

        let defaults = try makeDefaults("Sources")
        let knownRegistry = CodexKnownModelBaseRegistry(defaults: defaults)
        knownRegistry.unionObserved(records: CodexDynamicModelStore.canonicalRecords(from: [
            remote("hermetic-static", "Hermetic Static", speedTiers: ["fast"])
        ]))
        let registry = AgentCodexModelRegistry(defaults: defaults, knownModelBaseRegistry: knownRegistry)
        let staticOnlyDefaults = try makeDefaults("StaticOnly")
        let staticOnlyRegistry = AgentCodexModelRegistry(
            defaults: staticOnlyDefaults,
            knownModelBaseRegistry: knownRegistry
        )
        let staticOptions = [
            AgentModelOption(rawValue: "default", displayName: "Default", description: nil, isDefault: true),
            AgentModelOption(rawValue: "hermetic-shared", displayName: "Static Shared", description: nil, isDefault: false),
            AgentModelOption(rawValue: "hermetic-static", displayName: "Hermetic Static", description: nil, isDefault: false)
        ]

        // Live A also writes the cache; overwrite the cache with B so live and cache differ.
        XCTAssertTrue(registry.updateLiveModels([
            remote("hermetic-live", "Hermetic Live", efforts: ["low", "high"], isDefault: true),
            remote("hermetic-shared", "Live Shared"),
            remote("hermetic-fastbase", "Hermetic Fastbase", speedTiers: ["fast"])
        ]))
        CodexDynamicModelStore.save([remote("hermetic-cache", "Cache Only")], defaults: defaults)

        // Fixed oracle for the full nil/live resolution, independent of `firstResolvedOption`:
        // placeholder, then mapper order (provider-default effort first, same-base effort rank,
        // otherwise base order), then dynamic fast synthesis, then the static backfill (the
        // hermetic set lacks the recommended GPT keys) minus equivalent duplicates, plus its fast variant.
        XCTAssertEqual(registry.resolvedOptions(staticOptions: staticOptions).map(\.rawValue), [
            "default",
            "hermetic-live-low",
            "hermetic-fastbase",
            "hermetic-live-high",
            "hermetic-shared",
            "hermetic-fastbase-fast",
            "hermetic-static",
            "hermetic-static-fast"
        ])

        let sources: [(name: String, registry: AgentCodexModelRegistry, preferred: [CodexAppServerClient.RemoteModel]?)] = [
            ("nil preferred uses live", registry, nil),
            ("explicit empty uses cache", registry, []),
            ("non-empty preferred", registry, [remote("hermetic-preferred", "Preferred")]),
            ("static only, nil preferred", staticOnlyRegistry, nil),
            ("static only, explicit empty", staticOnlyRegistry, [])
        ]
        let predicates: [(name: String, matches: (AgentModelOption) -> Bool)] = [
            ("default placeholder", slug("default")),
            ("primary with multiple efforts", slug("hermetic-live")),
            ("case-insensitive duplicate", slug("HERMETIC-SHARED")),
            ("synthesized fast", raw("hermetic-fastbase-fast")),
            ("backfilled static", slug("hermetic-static")),
            ("backfilled static fast", raw("hermetic-static-fast")),
            ("cache only", slug("hermetic-cache")),
            ("preferred only", slug("hermetic-preferred")),
            ("miss", slug("hermetic-missing"))
        ]

        for source in sources {
            let full = source.registry.resolvedOptions(
                staticOptions: staticOptions,
                preferredLiveModels: source.preferred
            )
            for predicate in predicates {
                XCTAssertEqual(
                    source.registry.firstResolvedOption(
                        staticOptions: staticOptions,
                        preferredLiveModels: source.preferred,
                        matching: predicate.matches
                    ),
                    full.first(where: predicate.matches),
                    "\(source.name): \(predicate.name)"
                )
            }
        }

        func first(
            _ registry: AgentCodexModelRegistry,
            _ preferred: [CodexAppServerClient.RemoteModel]?,
            _ predicate: (AgentModelOption) -> Bool
        ) -> AgentModelOption? {
            registry.firstResolvedOption(
                staticOptions: staticOptions,
                preferredLiveModels: preferred,
                matching: predicate
            )
        }
        // Pin that the sources and groups above actually exercise the intended paths.
        XCTAssertEqual(first(registry, nil, slug("hermetic-shared"))?.displayName, "Live Shared")
        XCTAssertNotNil(first(registry, nil, slug("hermetic-live")))
        XCTAssertNil(first(registry, nil, slug("hermetic-cache")))
        XCTAssertNotNil(first(registry, [], slug("hermetic-cache")))
        XCTAssertNil(first(registry, [], slug("hermetic-live")))
        XCTAssertNotNil(first(registry, nil, raw("hermetic-fastbase-fast")))
        XCTAssertNotNil(first(registry, nil, raw("hermetic-static")))
        XCTAssertNotNil(first(registry, nil, raw("hermetic-static-fast")))
        XCTAssertEqual(first(registry, nil, slug("default"))?.isPlaceholderDefault, true)
        XCTAssertEqual(first(staticOnlyRegistry, nil, slug("hermetic-shared"))?.displayName, "Static Shared")
        XCTAssertNotNil(first(staticOnlyRegistry, [], raw("hermetic-static-fast")))
    }

    func testCodexBaseDisplayNameFallsBackWhenCodexIsUnavailable() {
        let rawModel = "hermetic-unavailable-high"
        let modelSlug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: rawModel)
        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: rawModel,
                agentKind: .codexExec,
                availability: .none,
                includeEffortSuffix: false
            ),
            AIModel.codexBaseDisplayName(for: modelSlug, fallbackDisplayName: rawModel)
        )
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
