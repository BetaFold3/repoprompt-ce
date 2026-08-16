import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import SwiftUI
import XCTest

extension ACPAgentSessionControllerModeConfigTests {
    func testOhMyPiThinkingSelectionsUsesExactIDsAndDeterministicLRUEviction() {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        var selections = OhMyPiThinkingSelections()
        for index in 0 ... OhMyPiThinkingSelections.maximumEntryCount {
            selections.setValue(
                "value-\(index)",
                for: String(format: "model-%02d", index),
                updatedAt: timestamp
            )
        }

        XCTAssertEqual(selections.count, OhMyPiThinkingSelections.maximumEntryCount)
        XCTAssertNil(selections["model-00"], "Exact wire ID is the deterministic tie-break")
        XCTAssertEqual(selections["model-01"]?.value, "value-1")

        let beforeRead = selections["model-01"]
        _ = selections.value(for: "model-01")
        XCTAssertEqual(selections["model-01"], beforeRead, "Reads must not update recency")

        let later = Date(timeIntervalSinceReferenceDate: 200)
        selections.setValue("updated", for: "model-01", updatedAt: later)
        XCTAssertEqual(selections["model-01"], .init(value: "updated", updatedAt: later))
        XCTAssertNil(selections["MODEL-01"], "Model IDs must not normalize or fuzzy-match")
    }

    @MainActor
    func testCanonicalOMPWireIdentityGovernsMapLookupUIProbeAndExecution() {
        let canonicalID = "Cursor/GPT:Fast"
        let persistedAlias = "cursor/gpt:fast"
        AgentACPModelRegistry.shared.reset(providerID: .ohMyPi)
        defer { AgentACPModelRegistry.shared.reset(providerID: .ohMyPi) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: canonicalID,
                        displayName: "GPT Fast",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: canonicalID
            ),
            for: .ohMyPi
        ))

        var selections = OhMyPiThinkingSelections()
        selections.setValue("high", for: persistedAlias)
        let aliasedModel = AIModel.ohMyPiCustom(name: persistedAlias)

        XCTAssertEqual(OhMyPiCanonicalModelIdentity.exactWireID(for: aliasedModel), canonicalID)
        XCTAssertEqual(
            OhMyPiThinkingMenuBuilder.exactModelID(from: aliasedModel.rawValue),
            canonicalID
        )
        XCTAssertTrue(
            selections.assignments(for: aliasedModel).isEmpty,
            "Canonical resolution must not transfer a choice stored under a case-distinct ID"
        )
        XCTAssertTrue(AgentModeRunService.ohMyPiConfigAssignments(
            agent: .ohMyPi,
            exactWireModelID: persistedAlias,
            selections: selections
        ).isEmpty)

        selections.setValue("max", for: canonicalID)
        XCTAssertEqual(selections.assignments(for: aliasedModel), [.ohMyPiThinking("max")])
        XCTAssertEqual(AgentModeRunService.ohMyPiConfigAssignments(
            agent: .ohMyPi,
            exactWireModelID: persistedAlias,
            selections: selections
        ), [.ohMyPiThinking("max")])
    }

    func testOhMyPiThinkingSelectionsLegacyDecodeAndNonemptyOnlyEncoding() throws {
        let legacyPresetData = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000301",
              "name": "legacy",
              "modelString": "ohMyPiCustom:cursor/model"
            }
            """.utf8
        )
        let legacyPreset = try JSONDecoder().decode(ModelPreset.self, from: legacyPresetData)
        XCTAssertTrue(legacyPreset.ohMyPiThinkingSelections.isEmpty)

        let emptyData = try JSONEncoder().encode(legacyPreset)
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        XCTAssertNil(emptyObject["ohMyPiThinkingSelections"])

        var selections = OhMyPiThinkingSelections()
        selections.setValue(
            "high",
            for: "cursor/model",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let populatedPreset = ModelPreset(
            id: legacyPreset.id,
            name: legacyPreset.name,
            model: .ohMyPiCustom(name: "cursor/model"),
            ohMyPiThinkingSelections: selections
        )
        let populatedData = try JSONEncoder().encode(populatedPreset)
        let populatedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: populatedData) as? [String: Any]
        )
        XCTAssertNotNil(populatedObject["ohMyPiThinkingSelections"])

        let roundTripped = try JSONDecoder().decode(ModelPreset.self, from: populatedData)
        XCTAssertEqual(roundTripped.ohMyPiThinkingSelections, selections)
    }

    func testAgentModelsSettingsProfileThinkingMapsDecodeAdditivelyAndEncodeOnlyWhenNonempty() throws {
        let legacyData = Data(
            """
            {
              "planningModelRaw": "ohMyPiCustom:cursor/planning",
              "preferredComposeModelRaw": "ohMyPiCustom:cursor/chat"
            }
            """.utf8
        )
        let legacy = try JSONDecoder().decode(AgentModelsSettingsProfile.self, from: legacyData)
        XCTAssertTrue(legacy.planningModelOhMyPiThinkingSelections.isEmpty)
        XCTAssertTrue(legacy.preferredComposeOhMyPiThinkingSelections.isEmpty)
        XCTAssertTrue(legacy.contextBuilderOhMyPiThinkingSelections.isEmpty)

        let emptyData = try JSONEncoder().encode(legacy)
        let emptyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
        )
        XCTAssertNil(emptyObject["planningModelOhMyPiThinkingSelections"])
        XCTAssertNil(emptyObject["preferredComposeOhMyPiThinkingSelections"])
        XCTAssertNil(emptyObject["contextBuilderOhMyPiThinkingSelections"])

        var planning = OhMyPiThinkingSelections()
        planning.setValue(
            "plan",
            for: "cursor/planning",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        var chat = OhMyPiThinkingSelections()
        chat.setValue(
            "chat",
            for: "cursor/chat",
            updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        var contextBuilder = OhMyPiThinkingSelections()
        contextBuilder.setValue(
            "context",
            for: "cursor/context",
            updatedAt: Date(timeIntervalSinceReferenceDate: 3)
        )
        var populated = legacy
        populated.planningModelOhMyPiThinkingSelections = planning
        populated.preferredComposeOhMyPiThinkingSelections = chat
        populated.contextBuilderOhMyPiThinkingSelections = contextBuilder

        let populatedData = try JSONEncoder().encode(populated)
        let roundTripped = try JSONDecoder().decode(
            AgentModelsSettingsProfile.self,
            from: populatedData
        )
        XCTAssertEqual(roundTripped, populated)
    }

    func testOhMyPiPresetCopiesAndSharedModelsKeepIndependentSelections() {
        let wireID = "cursor/shared-model"
        let model = AIModel.ohMyPiCustom(name: wireID)
        var firstSelections = OhMyPiThinkingSelections()
        firstSelections.setValue("low", for: wireID, updatedAt: Date(timeIntervalSinceReferenceDate: 1))
        var secondSelections = OhMyPiThinkingSelections()
        secondSelections.setValue("high", for: wireID, updatedAt: Date(timeIntervalSinceReferenceDate: 2))

        let first = ModelPreset(
            name: "first",
            model: model,
            ohMyPiThinkingSelections: firstSelections
        )
        let second = ModelPreset(
            name: "second",
            model: model,
            ohMyPiThinkingSelections: secondSelections
        )
        let editedCopy = ModelPreset(
            id: first.id,
            name: first.name,
            model: first.model,
            description: first.description,
            supportedModes: first.supportedModes,
            proEditingOverride: first.proEditingOverride,
            chatPresetMappings: first.chatPresetMappings,
            ohMyPiThinkingSelections: first.ohMyPiThinkingSelections
        )

        XCTAssertEqual(first.modelString, second.modelString)
        XCTAssertEqual(first.ohMyPiThinkingSelections.value(for: wireID), "low")
        XCTAssertEqual(second.ohMyPiThinkingSelections.value(for: wireID), "high")
        XCTAssertEqual(editedCopy.ohMyPiThinkingSelections, firstSelections)
        XCTAssertEqual(firstSelections.assignments(for: model), [.ohMyPiThinking("low")])
        XCTAssertEqual(secondSelections.assignments(for: model), [.ohMyPiThinking("high")])

        let packagedMessage = AIMessage(systemPrompt: "system", userMessage: "prompt")
        let firstRequest = packagedMessage.replacingExecutionMetadata(
            first.ohMyPiThinkingSelections.executionMetadata(for: first.model)
        )
        let secondRequest = packagedMessage.replacingExecutionMetadata(
            second.ohMyPiThinkingSelections.executionMetadata(for: second.model)
        )
        XCTAssertEqual(
            firstRequest.executionMetadata.additionalACPConfigOptionValues,
            [.ohMyPiThinking("low")]
        )
        XCTAssertEqual(
            secondRequest.executionMetadata.additionalACPConfigOptionValues,
            [.ohMyPiThinking("high")]
        )
    }

    @MainActor
    func testOhMyPiTabsAndModelDestinationsRemainIndependent() {
        let wireID = "google-antigravity/shared-model"
        let firstTab = AgentModeViewModel.TabSession(tabID: UUID())
        let secondTab = AgentModeViewModel.TabSession(tabID: UUID())
        firstTab.selectedAgent = .ohMyPi
        secondTab.selectedAgent = .ohMyPi
        firstTab.selectedModelRaw = wireID
        secondTab.selectedModelRaw = wireID

        let firstDestination = ModelDestination.agentTab(firstTab)
        let secondDestination = ModelDestination.agentTab(secondTab)
        firstDestination.applyThinkingValue(
            "auto",
            for: wireID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        secondDestination.applyThinkingValue(
            "max",
            for: wireID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )

        XCTAssertTrue(firstDestination.hasThinkingAccessory)
        XCTAssertEqual(firstDestination.thinkingChoice(for: wireID)?.value, "auto")
        XCTAssertEqual(secondDestination.thinkingChoice(for: wireID)?.value, "max")
        XCTAssertEqual(
            AgentModeRunService.ohMyPiConfigAssignments(
                agent: .ohMyPi,
                exactWireModelID: wireID,
                selections: firstTab.ohMyPiThinkingSelections
            ),
            [.ohMyPiThinking("auto")]
        )
        XCTAssertEqual(
            AgentModeRunService.ohMyPiConfigAssignments(
                agent: .ohMyPi,
                exactWireModelID: wireID,
                selections: secondTab.ohMyPiThinkingSelections
            ),
            [.ohMyPiThinking("max")]
        )
        XCTAssertEqual(
            AgentModeRunService.ohMyPiConfigAssignments(
                agent: .cursor,
                exactWireModelID: wireID,
                selections: firstTab.ohMyPiThinkingSelections
            ),
            []
        )
        XCTAssertEqual(
            ContextBuilderAgentViewModel.ohMyPiConfigAssignments(
                agent: .ohMyPi,
                exactWireModelID: wireID,
                profile: AgentModelsSettingsProfile(
                    contextBuilderOhMyPiThinkingSelections: firstTab.ohMyPiThinkingSelections
                )
            ),
            [.ohMyPiThinking("auto")]
        )

        var plainModel = "plain"
        let plain = ModelDestination.binding(
            Binding(
                get: { plainModel },
                set: { plainModel = $0 }
            ),
            id: "plain"
        )
        XCTAssertFalse(plain.hasThinkingAccessory)
        XCTAssertNil(plain.currentThinkingSelections)
        plain.applyThinkingValue("ignored", for: wireID)
        XCTAssertNil(plain.thinkingChoice(for: wireID))

        var boundSelections = OhMyPiThinkingSelections()
        let presetEditor = ModelDestination.binding(
            Binding(get: { plainModel }, set: { plainModel = $0 }),
            thinkingSelections: Binding(
                get: { boundSelections },
                set: { boundSelections = $0 }
            ),
            id: "presetEditor"
        )
        presetEditor.applyThinkingValue(
            "high",
            for: wireID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 3)
        )
        XCTAssertTrue(presetEditor.hasThinkingAccessory)
        XCTAssertEqual(boundSelections.value(for: wireID), "high")
    }

    func testOhMyPiThinkingDestinationIntentUsesRawValuesNotDisplayNames() {
        let choice = OhMyPiThinkingSelections.ThinkingChoice(
            value: "raw-b",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let duplicateDisplayNames = OhMyPiThinkingAdvertisedCapabilities(
            options: [
                .init(value: "raw-a", displayName: "High"),
                .init(value: "raw-b", displayName: "High")
            ],
            isAuthoritative: true
        )

        XCTAssertEqual(
            OhMyPiThinkingDestinationIntent.resolve(
                choice: nil,
                capabilities: duplicateDisplayNames
            ),
            .defaultSelection
        )
        XCTAssertEqual(
            OhMyPiThinkingDestinationIntent.resolve(
                choice: choice,
                capabilities: duplicateDisplayNames
            ),
            .advertised(optionIndex: 1, value: "raw-b")
        )
        XCTAssertEqual(
            OhMyPiThinkingDestinationIntent.resolve(
                choice: .init(
                    value: "stale",
                    updatedAt: Date(timeIntervalSinceReferenceDate: 2)
                ),
                capabilities: duplicateDisplayNames
            ),
            .unavailable(rawValue: "stale")
        )
        XCTAssertEqual(
            OhMyPiThinkingDestinationIntent.resolve(choice: choice, capabilities: nil),
            .capabilityUnknown(rawValue: "raw-b")
        )
        XCTAssertEqual(
            OhMyPiThinkingDestinationIntent.resolve(
                choice: choice,
                capabilities: .init(options: [], isAuthoritative: false)
            ),
            .capabilityUnknown(rawValue: "raw-b")
        )
    }

    func testAgentSessionThinkingSelectionsAreAdditiveAndEmptyByDefault() throws {
        let legacyData = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000302",
              "serializationVersion": 7,
              "name": "legacy",
              "savedAt": 0,
              "items": [],
              "autoEditEnabled": true
            }
            """.utf8
        )
        let legacy = try JSONDecoder().decode(AgentSession.self, from: legacyData)
        XCTAssertNil(legacy.ohMyPiThinkingSelections)

        var selections = OhMyPiThinkingSelections()
        selections.setValue(
            "high",
            for: "cursor/model",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let session = AgentSession(
            id: UUID(),
            name: "OMP",
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            agentKind: AgentProviderKind.ohMyPi.rawValue,
            agentModel: "cursor/model",
            ohMyPiThinkingSelections: selections
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.ohMyPiThinkingSelections, selections)

        let emptySessionData = try JSONEncoder().encode(AgentSession())
        let emptyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: emptySessionData) as? [String: Any]
        )
        XCTAssertNil(emptyObject["ohMyPiThinkingSelections"])
    }
}
