import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CursorModelSelectionSurfaceSpikeTests: XCTestCase {
    private var cursorCatalogSnapshot: [String: [CursorModelParameterCatalog.ParameterSpec]] = [:]

    override func setUp() {
        super.setUp()
        cursorCatalogSnapshot = CursorModelParameterCatalog.shared.currentSnapshot()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        CursorModelParameterCatalog.shared.test_restoreSnapshot(cursorCatalogSnapshot)
        super.tearDown()
    }

    func testAIModelCursorCustomRoundTripsOpaqueRawCharacters() {
        let name = "gpt[alpha beta]=x,y"
        let model = AIModel.cursorCustom(name: name)

        XCTAssertEqual(model.rawValue, "cursor_custom_\(name)")
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
    }

    func testBracketedCursorSelectionIDRoundTripsAndResolvesThroughMCP() throws {
        installCursorModel()
        let modelRaw = "gpt-5.6-sol[context=1m,reasoning=high,fast=false]"
        let selectionID = AgentModelSelectionID(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: modelRaw
        )

        XCTAssertEqual(AgentModelSelectionID.parse(selectionID.rawValue), selectionID)
        XCTAssertEqual(
            AgentModelCatalog.resolveSelectionID(
                selectionID.rawValue,
                availability: cursorAvailability
            ),
            .init(agent: .cursor, modelRaw: modelRaw)
        )

        let mcpSelection = try AgentMCPSelectionResolver.resolve(
            modelID: selectionID.rawValue,
            availability: cursorAvailability
        )
        XCTAssertEqual(mcpSelection.agentRaw, AgentProviderKind.cursor.rawValue)
        XCTAssertEqual(mcpSelection.modelRaw, modelRaw)
        XCTAssertNil(mcpSelection.taskLabelKind)
    }

    func testBracketedCursorDisplayNameResolvesDiscoveredBase() {
        installCursorModel()

        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: "gpt-5.6-sol[context=1m,reasoning=high,fast=false]",
                agentKind: .cursor,
                availability: cursorAvailability,
                includeCursorParameterSuffix: false
            ),
            "GPT 5.6 Sol"
        )
    }

    func testCursorSelectionMatchingAndWarningVisualsPreserveOtherProviders() throws {
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "cursor:gpt-5.6-sol[Reasoning=high,fast=true]",
            selectedRaw: "gpt-5.6-sol[fast=true,reasoning=high]",
            agentKind: .cursor
        ))
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "cursor:gpt-5.6-sol",
            selectedRaw: "gpt-5.6-sol",
            agentKind: .cursor
        ))
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "gpt-5.6-sol",
            selectedRaw: "gpt-5.6-sol[reasoning=high]",
            agentKind: .cursor
        ))
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "gpt-5.6-sol[reasoning=high]",
            selectedRaw: "gpt-5.6-sol[reasoning=High]",
            agentKind: .cursor
        ))
        XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "gpt-5.6-sol[reasoning=high]",
            selectedRaw: "gpt-5.6-sol[reasoning=high,fast=false]",
            agentKind: .cursor
        ))
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "cursor:malformed]",
            selectedRaw: "CURSOR:MALFORMED]",
            agentKind: .cursor
        ))

        XCTAssertTrue(AgentModelSelectionWarningVisuals.showsWarning(
            agent: .cursor,
            rawModel: "gpt-5.6-sol[fast=true]"
        ))
        XCTAssertFalse(AgentModelSelectionWarningVisuals.showsWarning(
            agent: .cursor,
            rawModel: "gpt-5.6-sol"
        ))
        XCTAssertFalse(AgentModelSelectionWarningVisuals.showsWarning(
            agent: .cursor,
            rawModel: "gpt-5.6-sol[fast=false]"
        ))
        XCTAssertEqual(
            AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor),
            "Fast enabled: 2× more expensive, but faster speeds."
        )

        XCTAssertTrue(AgentModelSelectionWarningVisuals.showsWarning(
            agent: .codexExec,
            rawModel: "gpt-5.6-sol-fast-high"
        ))
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: "gpt-5.6-sol-high",
            selectedRaw: "gpt-5.6-sol-high",
            agentKind: .codexExec
        ))
        XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
            optionRaw: AgentModel.claudeSonnet.rawValue,
            selectedRaw: AgentModel.claudeSonnet.rawValue,
            agentKind: .claudeCode
        ))

        let catalog = makeMenuCatalog()
        let selectedPresetRaw = AIModel.cursorCustom(
            name: "gpt-5.6-sol[thinking_mode=high,context=1m]"
        ).rawValue
        let parent = try XCTUnwrap(AIModelDropdown.cursorPresetMenuItem(
            modelRaw: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol",
            selectedRawValue: selectedPresetRaw,
            catalog: catalog,
            isEnabled: true
        ))
        XCTAssertEqual(parent.style, .normal)
        XCTAssertNil(parent.imageSystemName)
        XCTAssertNil(parent.toolTip)

        let parentItems = try XCTUnwrap(parent.submenuItems)
        let fastParent = try XCTUnwrap(parentItems.first(where: { $0.title == "Fast (2×)" }))
        XCTAssertEqual(fastParent.style, .warning)
        XCTAssertEqual(
            fastParent.toolTip,
            AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
        )
        XCTAssertTrue(try XCTUnwrap(fastParent.submenuItems).allSatisfy {
            $0.style == .warning && $0.toolTip != nil
        })

        XCTAssertTrue(CursorModelParameterCatalog.shared.apply(response: menuParameterResponse()))
        let roleItems = AgentModelStableMenuItems.modelItems(
            agentKind: .cursor,
            options: [
                AgentModelOption(
                    rawValue: "gpt-5.6-sol",
                    displayName: "GPT 5.6 Sol",
                    description: nil,
                    isDefault: true
                )
            ],
            selectedAgent: .cursor,
            selectedModelRaw: "gpt-5.6-sol[context=1m,thinking_mode=high,fast=false]"
        ) { _, _ in }
        let roleParent = try XCTUnwrap(roleItems.first)
        XCTAssertEqual(roleParent.style, .normal)
        let roleFastParent = try XCTUnwrap(
            try XCTUnwrap(roleParent.submenuItems).first {
                $0.title == "Fast (2×)"
            }
        )
        XCTAssertEqual(roleFastParent.style, .warning)
        XCTAssertEqual(
            roleFastParent.toolTip,
            AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
        )
        XCTAssertEqual(
            try XCTUnwrap(roleFastParent.submenuItems).map(\.title),
            ["None", "Low", "High"]
        )

        XCTAssertTrue(CursorModelParameterCatalog.shared.apply(response: [
            "models": [[
                "value": "gpt-5.6-sol",
                "configOptions": [[
                    "id": "fast",
                    "category": "speed",
                    "type": "select",
                    "currentValue": "true",
                    "options": [
                        ["value": "false", "name": "Off"],
                        ["value": "true", "name": "On"]
                    ]
                ]]
            ]]
        ]))
        let fastDefaultItems = AgentModelStableMenuItems.modelItems(
            agentKind: .cursor,
            options: [
                AgentModelOption(
                    rawValue: "gpt-5.6-sol",
                    displayName: "GPT 5.6 Sol",
                    description: nil,
                    isDefault: true
                )
            ],
            selectedAgent: .cursor,
            selectedModelRaw: "gpt-5.6-sol[fast=true]"
        ) { _, _ in }
        XCTAssertEqual(fastDefaultItems.first?.style, .warning)
        XCTAssertEqual(
            fastDefaultItems.first?.toolTip,
            AgentModelSelectionWarningVisuals.warningTooltip(for: .cursor)
        )

        let contextParent = try XCTUnwrap(parentItems.first(where: { $0.title == "1M Context" }))
        let highContextLeaf = try XCTUnwrap(
            try XCTUnwrap(contextParent.submenuItems).first(where: { $0.title == "High" })
        )
        XCTAssertTrue(highContextLeaf.isSelected)
    }

    func testCursorDisplaySuffixFlagAndPresetLabelFallback() {
        installCursorModel()
        let modelRaw = "gpt-5.6-sol[reasoning=high,fast=true,context=1m]"
        let aiModel = AIModel.cursorCustom(name: modelRaw)

        XCTAssertEqual(aiModel.rawValue, "cursor_custom_\(modelRaw)")
        XCTAssertEqual(aiModel.displayName, "GPT 5.6 Sol · High · Fast · 1M")
        XCTAssertEqual(
            AIModel.cursorCustom(
                name: "gpt-5.6-sol[reasoning=max,fast=true]"
            ).displayName,
            "GPT 5.6 Sol · Max · Fast"
        )

        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: modelRaw,
                agentKind: .cursor,
                availability: cursorAvailability,
                includeCursorParameterSuffix: true
            ),
            "GPT 5.6 Sol · High · Fast · 1M"
        )
        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: modelRaw,
                agentKind: .cursor,
                availability: cursorAvailability,
                includeCursorParameterSuffix: false
            ),
            "GPT 5.6 Sol"
        )
        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: "cursor:malformed]",
                agentKind: .cursor,
                availability: cursorAvailability
            ),
            "malformed]"
        )
        CursorModelParameterCatalog.shared.clearForMethodNotFound()
        XCTAssertEqual(aiModel.displayName, "GPT 5.6 Sol · High · Fast · 1M")
        let preDiscoveryRaw = "gpt-5.6-sol[context=1m,reasoning=high]"
        let preDiscoveryDisplay = AgentModelCatalog.displayName(
            for: preDiscoveryRaw,
            agentKind: .cursor,
            availability: cursorAvailability,
            includeCursorParameterSuffix: true
        )
        XCTAssertEqual(preDiscoveryDisplay, "GPT 5.6 Sol · High · 1M")
        XCTAssertEqual(
            CursorModelProviderChipDisplay.name(
                rawModel: preDiscoveryRaw,
                fallbackDisplayName: preDiscoveryDisplay,
                parameterLauncherAvailable: false
            ),
            "GPT 5.6 Sol · High · 1M"
        )
        XCTAssertEqual(
            CursorModelProviderChipDisplay.name(
                rawModel: preDiscoveryRaw,
                fallbackDisplayName: preDiscoveryDisplay,
                parameterLauncherAvailable: true
            ),
            "GPT 5.6 Sol"
        )

        XCTAssertEqual(
            AIModelDropdown.displayName(
                forRawValue: AIModel.cursorCustom(name: modelRaw).rawValue,
                destinationID: "planningModel",
                availableModels: [.cursorCustom(name: "gpt-5.6-sol")],
                customOpenRouterModels: []
            ),
            "GPT 5.6 Sol · High · Fast · 1M"
        )
    }

    func testEmptyCatalogKeepsFlatMenusAndOtherProviderGroupingStable() {
        CursorModelParameterCatalog.shared.clearForMethodNotFound()
        let cursorOption = AgentModelOption(
            rawValue: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol",
            description: nil,
            isDefault: true
        )
        let cursorItems = AgentModelStableMenuItems.modelItems(
            agentKind: .cursor,
            options: [cursorOption],
            selectedAgent: .cursor,
            selectedModelRaw: cursorOption.rawValue
        ) { _, _ in }
        XCTAssertEqual(cursorItems.map(\.title), ["GPT 5.6 Sol"])
        XCTAssertEqual(cursorItems.map(\.isSelected), [true])
        XCTAssertEqual(cursorItems.map(\.style), [.normal])

        let nonCursorItems = AgentModelStableMenuItems.modelItems(
            agentKind: .openCode,
            options: [
                AgentModelOption(
                    rawValue: "provider/model",
                    displayName: "Provider Model",
                    description: nil,
                    isDefault: false
                )
            ],
            selectedAgent: .openCode,
            selectedModelRaw: "provider/model",
            groupOpenCode: false
        ) { _, _ in }
        XCTAssertEqual(nonCursorItems.map(\.title), ["Provider Model"])
        XCTAssertEqual(nonCursorItems.map(\.isSelected), [true])
        XCTAssertEqual(nonCursorItems.map(\.style), [.normal])

        let codexMenu = AgentModelCatalog.codexMenu(for: [
            AgentModelOption(
                rawValue: "gpt-5.6-sol-low",
                displayName: "GPT 5.6 Sol Low",
                description: nil,
                isDefault: false
            ),
            AgentModelOption(
                rawValue: "gpt-5.6-sol-high",
                displayName: "GPT 5.6 Sol High",
                description: nil,
                isDefault: false
            )
        ])
        XCTAssertEqual(codexMenu.groups.count, 1)
        XCTAssertEqual(codexMenu.groups.first?.options.map(\.rawValue), [
            "gpt-5.6-sol-low",
            "gpt-5.6-sol-high"
        ])
        let codexStableItems = AgentModelStableMenuItems.modelItems(
            agentKind: .codexExec,
            options: [
                AgentModelOption(
                    rawValue: "gpt-5.6-sol-fast-high",
                    displayName: "GPT 5.6 Sol Fast High",
                    description: nil,
                    isDefault: false
                )
            ],
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.6-sol-fast-high",
            flattenSingleCodexGroups: true
        ) { _, _ in }
        XCTAssertEqual(codexStableItems.first?.style, .warning)
        XCTAssertNil(codexStableItems.first?.toolTip)

        let claudeMenu = AgentModelCatalog.claudeMenu(
            for: [
                AgentModelOption(
                    rawValue: AgentModel.claudeSonnet.rawValue,
                    displayName: AgentModel.claudeSonnet.displayName,
                    description: nil,
                    isDefault: false
                )
            ],
            agentKind: .claudeCode
        )
        XCTAssertEqual(claudeMenu.groups.count, 1)
        XCTAssertEqual(claudeMenu.groups.first?.options.map(\.rawValue), [
            "sonnet:low",
            "sonnet:medium",
            "sonnet:high",
            "sonnet:max"
        ])

        let openCodeMenu = AgentModelCatalog.openCodeMenu(for: [
            AgentModelOption(
                rawValue: "provider/model",
                displayName: "Provider Model",
                description: nil,
                isDefault: false
            )
        ])
        XCTAssertEqual(openCodeMenu.providerGroups.count, 1)
        XCTAssertEqual(openCodeMenu.providerGroups.first?.groups.count, 1)
        XCTAssertEqual(
            openCodeMenu.providerGroups.first?.groups.first?.options.first?.option.rawValue,
            "provider/model"
        )
    }

    private func makeMenuCatalog() -> CursorModelParameterCatalog {
        let catalog = CursorModelParameterCatalog()
        XCTAssertTrue(catalog.apply(response: menuParameterResponse()))
        return catalog
    }

    private func menuParameterResponse() -> [String: Any] {
        [
            "models": [[
                "value": "gpt-5.6-sol",
                "configOptions": [
                    [
                        "id": "context",
                        "category": "context_window",
                        "type": "select",
                        "currentValue": "272k",
                        "options": [
                            ["value": "272k", "name": "272k"],
                            ["value": "1m", "name": "1m"]
                        ]
                    ],
                    [
                        "id": "thinking_mode",
                        "category": "thought_level",
                        "type": "select",
                        "currentValue": "low",
                        "options": [
                            ["value": "none", "name": "None"],
                            ["value": "low", "name": "Low"],
                            ["value": "high", "name": "High"]
                        ]
                    ],
                    [
                        "id": "fast",
                        "category": "speed",
                        "type": "select",
                        "currentValue": "false",
                        "options": [
                            ["value": "false", "name": "Off"],
                            ["value": "true", "name": "On"]
                        ]
                    ]
                ]
            ]]
        ]
    }

    private var cursorAvailability: AgentModelCatalog.AvailabilityContext {
        .init(cursorAvailable: true)
    }

    private func installCursorModel() {
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "gpt-5.6-sol",
                        displayName: "GPT 5.6 Sol",
                        description: "Cursor parameterized model",
                        isDefault: true
                    )
                ],
                currentModelRaw: "gpt-5.6-sol"
            ),
            for: .cursor
        )
    }
}
