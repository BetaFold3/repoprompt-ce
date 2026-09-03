@testable import RepoPromptApp
import XCTest

final class ClaudeStaticCatalogConsistencyTests: XCTestCase {
    private struct StaticModel {
        let rawValue: String
        let displayName: String
        let supportedEfforts: Set<String>?
    }

    func testModernClaudeFullIDsAreConsistentAcrossStaticAuthorities() throws {
        let positiveNormalizationCases: [(raw: String, expected: String)] = [
            ("claude-fable-5", "claude-fable-5"),
            ("claude-sonnet-4-6", "claude-sonnet-4-6"),
            ("claude-opus-4-5-20251101", "claude-opus-4-5")
        ]
        for testCase in positiveNormalizationCases {
            XCTAssertEqual(normalizedModernClaudeIdentity(testCase.raw), testCase.expected)
        }
        for raw in [
            "opus",
            "claude-opus",
            "claude-opus-four-five",
            "claude-opus-4-5-2025110",
            "claude-opus-4-5-latest",
            "claude-opus-4-5-20251101-extra"
        ] {
            XCTAssertNil(normalizedModernClaudeIdentity(raw), "Unexpectedly normalized \(raw)")
        }

        let packageSnapshot = ClaudeCompatibleProviderRuntimeBridge.modelCatalogSnapshot(
            pluginID: .claudeCode,
            includeEffortVariants: false
        )
        let packageModels = modelsByIdentity(packageSnapshot.options.map {
            StaticModel(
                rawValue: $0.rawValue,
                displayName: $0.displayName,
                supportedEfforts: Set($0.supportedEffortLevels)
            )
        })

        let agentModels = modelsByIdentity(AgentModel.modelsForAgent(.claudeCode).map {
            StaticModel(
                rawValue: $0.rawValue,
                displayName: $0.displayName,
                supportedEfforts: nil
            )
        })

        let emptyStore = AnthropicDiscoveredModelStore.transient()
        let oracleModels = modelsByIdentity(
            ClaudeCodeAIModelCatalog.effectiveDefinitions(store: emptyStore).map {
                StaticModel(
                    rawValue: $0.runtimeModelRaw,
                    displayName: $0.displayName,
                    supportedEfforts: Set($0.supportedEfforts.map(\.rawValue))
                )
            }
        )

        let packageIdentities = Set(packageModels.keys)
        let agentIdentities = Set(agentModels.keys)
        let oracleIdentities = Set(oracleModels.keys)

        let requiredModernIdentities = Set([
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-opus-5",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-opus-4-5",
            "claude-sonnet-5",
            "claude-sonnet-4-6",
            "claude-sonnet-4-5",
            "claude-haiku-4-5"
        ])
        XCTAssertGreaterThanOrEqual(
            packageIdentities.count,
            10,
            "The modern Claude identity filter covers too few package models"
        )
        XCTAssertTrue(
            packageIdentities.isSuperset(of: requiredModernIdentities),
            "The modern Claude identity filter lost representative family/version coverage"
        )
        XCTAssertEqual(
            agentIdentities,
            packageIdentities,
            "AgentModel full IDs drifted from the provider package static snapshot"
        )
        XCTAssertEqual(
            oracleIdentities,
            packageIdentities,
            "The empty-store Oracle catalog drifted from the shared static full-ID set"
        )

        for identity in packageIdentities.sorted() {
            let packageModel = try XCTUnwrap(packageModels[identity])
            XCTAssertEqual(
                try XCTUnwrap(agentModels[identity]).displayName,
                packageModel.displayName,
                "AgentModel display name drifted for \(identity)"
            )
            XCTAssertEqual(
                try XCTUnwrap(oracleModels[identity]).displayName,
                packageModel.displayName,
                "Oracle display name drifted for \(identity)"
            )
        }

        let packageXHighIdentities = Set(
            packageModels
                .filter { $0.value.supportedEfforts?.contains("xhigh") == true }
                .map(\.key)
        )
        let adapterXHighIdentities = Set(
            ClaudeCompatibleModelCatalogAdapter.claudeXHighEligibleBaseRaws.compactMap {
                normalizedModernClaudeIdentity($0)
            }
        )
        XCTAssertEqual(
            adapterXHighIdentities,
            packageXHighIdentities,
            "The adapter exact static XHigh authority drifted from package-derived membership"
        )

        let packageRuntimeOptions = packageSnapshot.options.filter { !$0.isPlaceholderDefault }
        XCTAssertGreaterThanOrEqual(
            packageRuntimeOptions.count,
            14,
            "The package runtime XHigh sweep covers too few selectable options"
        )
        let sweptPackageRaws = Set(packageRuntimeOptions.map { $0.rawValue.lowercased() })
        XCTAssertTrue(
            sweptPackageRaws.isSuperset(of: ["haiku", "sonnet", "opus", "opus[1m]"]),
            "The package runtime XHigh sweep must include every latest alias"
        )
        for option in packageRuntimeOptions {
            XCTAssertEqual(
                option.supportedEffortLevels.contains("xhigh"),
                ClaudeCompatibleModelCatalogAdapter.claudeEffort(
                    .xhigh,
                    isSupportedForBaseModelRaw: option.rawValue,
                    agentKind: .claudeCode
                ),
                "Runtime XHigh eligibility drifted for package option \(option.rawValue)"
            )
        }

        var pickerBaseRaws: Set<String> = []
        var pickerXHighBaseRaws: Set<String> = []
        for model in ClaudeCodeAIModelCatalog.modelsForPicker(store: emptyStore) {
            guard let raw = ClaudeCodeAIModelCatalog.runtimeSpecifierRaw(for: model) else { continue }
            let specifier = ClaudeModelSpecifier(raw: raw)
            guard let base = specifier.baseModel?.lowercased() else { continue }
            pickerBaseRaws.insert(base)
            if specifier.explicitEffortLevel == .xhigh {
                pickerXHighBaseRaws.insert(base)
            }
        }

        var comparedPickerRaws = 0
        for option in packageRuntimeOptions {
            let base = option.rawValue.lowercased()
            guard pickerBaseRaws.contains(base) else { continue }
            comparedPickerRaws += 1
            XCTAssertEqual(
                option.supportedEffortLevels.contains("xhigh"),
                pickerXHighBaseRaws.contains(base),
                "Picker XHigh projection drifted for package option \(option.rawValue)"
            )
        }
        XCTAssertGreaterThanOrEqual(
            comparedPickerRaws,
            6,
            "The empty-store picker shares too few base raws with the package catalog"
        )

        let intentionalOracleNoEffortIdentities = Set([
            "claude-opus-4-5",
            "claude-sonnet-4-5",
            "claude-haiku-4-5"
        ])
        let oracleNoEffortIdentities = Set(oracleModels.compactMap { identity, model in
            model.supportedEfforts?.isEmpty == true ? identity : nil
        })
        XCTAssertEqual(
            oracleNoEffortIdentities,
            intentionalOracleNoEffortIdentities,
            "The exact intentional Oracle no-effort exception set changed"
        )

        for identity in packageIdentities.subtracting(intentionalOracleNoEffortIdentities).sorted() {
            let oracleModel = try XCTUnwrap(oracleModels[identity])
            let oracleEfforts = try XCTUnwrap(oracleModel.supportedEfforts)
            XCTAssertEqual(
                oracleEfforts.contains("xhigh"),
                packageXHighIdentities.contains(identity),
                "Oracle XHigh exposure drifted for \(identity)"
            )
        }
    }

    private func modelsByIdentity(_ models: [StaticModel]) -> [String: StaticModel] {
        var result: [String: StaticModel] = [:]
        for model in models {
            guard let identity = normalizedModernClaudeIdentity(model.rawValue) else { continue }
            let previous = result.updateValue(model, forKey: identity)
            XCTAssertNil(
                previous,
                "Static authority contains duplicate normalized identity \(identity)"
            )
        }
        return result
    }

    /// Normalizes only `claude-<family>-<major>-<minor>-<YYYYMMDD>`
    /// to its major/minor full ID. All other accepted full IDs remain exact.
    private func normalizedModernClaudeIdentity(_ rawValue: String) -> String? {
        let components = rawValue.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard components.count == 3 || components.count == 4 || components.count == 5,
              components[0] == "claude",
              !components[1].isEmpty,
              isASCIIDigits(components[2])
        else {
            return nil
        }

        if components.count >= 4 {
            guard isASCIIDigits(components[3]) else { return nil }
        }
        if components.count == 5 {
            guard components[4].count == 8,
                  isASCIIDigits(components[4])
            else {
                return nil
            }
            return components.prefix(4).joined(separator: "-")
        }
        return components.joined(separator: "-")
    }

    private func isASCIIDigits(_ component: Substring) -> Bool {
        !component.isEmpty && component.utf8.allSatisfy { (48 ... 57).contains($0) }
    }
}
