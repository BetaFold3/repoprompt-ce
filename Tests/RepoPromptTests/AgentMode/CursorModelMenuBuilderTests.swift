import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorModelMenuBuilderTests: XCTestCase {
    func testAgentLeavesUseFullBracketsPreserveCurrentSecondaryValuesAndWireOrder() throws {
        let catalog = makeCatalog()
        let leaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "cursor:gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "cursor:gpt-5.6-sol[context=1m,thinking_mode=low,fast=true]",
            catalog: catalog,
            isEnabled: true
        ))

        XCTAssertEqual(
            CursorModelMenuBuilder.sections(from: leaves).map(\.title),
            [nil, nil, "Fast (2×)"]
        )
        XCTAssertEqual(leaves.map(\.title), [
            "Default", "None", "Low", "High", "None", "Low", "High"
        ])
        XCTAssertEqual(
            leaves[0].rawValue,
            "cursor:gpt-5.6-sol[context=272k,thinking_mode=low,fast=false]"
        )
        XCTAssertTrue(leaves[0].isDefaultLeaf)
        let reasoningHigh = try XCTUnwrap(leaves.first {
            $0.section == .reasoning && $0.title == "High"
        })
        let fastHigh = try XCTUnwrap(leaves.first {
            $0.section == .fast && $0.title == "High"
        })
        XCTAssertEqual(
            reasoningHigh.rawValue,
            "cursor:gpt-5.6-sol[context=1m,thinking_mode=high,fast=true]"
        )
        XCTAssertEqual(fastHigh.rawValue, reasoningHigh.rawValue)
        XCTAssertTrue(reasoningHigh.showsFastWarning)
        XCTAssertTrue(fastHigh.showsFastWarning)
        XCTAssertFalse(CursorModelMenuBuilder.leafIsSelected(
            reasoningHigh,
            among: leaves,
            selectedModelRaw: reasoningHigh.rawValue
        ))
        XCTAssertTrue(CursorModelMenuBuilder.leafIsSelected(
            fastHigh,
            among: leaves,
            selectedModelRaw: fastHigh.rawValue
        ))
        let freshLeaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "other-model",
            catalog: catalog,
            isEnabled: true
        ))
        XCTAssertEqual(
            try XCTUnwrap(freshLeaves.first {
                $0.section == .reasoning && $0.title == "High"
            }).rawValue,
            "gpt-5.6-sol[context=272k,thinking_mode=high,fast=false]"
        )
        XCTAssertEqual(
            try XCTUnwrap(freshLeaves.first {
                $0.section == .fast && $0.title == "High"
            }).rawValue,
            "gpt-5.6-sol[context=272k,thinking_mode=high,fast=true]"
        )
        XCTAssertTrue(CursorModelMenuBuilder.leafIsSelected(
            freshLeaves[0],
            among: freshLeaves,
            selectedModelRaw: freshLeaves[0].rawValue
        ))
        let lowLeaf = try XCTUnwrap(freshLeaves.first {
            $0.section == .reasoning && $0.title == "Low"
        })
        XCTAssertEqual(lowLeaf.rawValue, freshLeaves[0].rawValue)
        XCTAssertFalse(CursorModelMenuBuilder.leafIsSelected(
            lowLeaf,
            among: freshLeaves,
            selectedModelRaw: freshLeaves[0].rawValue
        ))

        let fastOnlyCatalog = CursorModelParameterCatalog()
        XCTAssertTrue(fastOnlyCatalog.apply(response: response(
            includeThought: false,
            includeContext: true,
            includeFast: true
        )))
        let fastOnlyLeaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "other-model",
            catalog: fastOnlyCatalog,
            isEnabled: true
        ))
        XCTAssertEqual(fastOnlyLeaves.map(\.title), ["Default", "Fast"])
        XCTAssertEqual(fastOnlyLeaves.last?.section, .fast)
        XCTAssertEqual(
            fastOnlyLeaves.last?.rawValue,
            "gpt-5.6-sol[context=272k,fast=true]"
        )
        XCTAssertTrue(fastOnlyLeaves.last?.showsFastWarning == true)
    }

    func testPresetLeavesUseOnlyChosenDimensionsAndOmitFastContextProduct() throws {
        let leaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .preset,
            selectedModelRaw: "",
            catalog: makeCatalog(),
            isEnabled: true
        ))

        XCTAssertEqual(leaves.first?.rawValue, "gpt-5.6-sol")
        XCTAssertEqual(leaves.first?.title, "Default (inherit)")
        XCTAssertEqual(
            leaves.filter { $0.section == .reasoning }.map(\.rawValue),
            [
                "gpt-5.6-sol[thinking_mode=none]",
                "gpt-5.6-sol[thinking_mode=low]",
                "gpt-5.6-sol[thinking_mode=high]"
            ]
        )

        let contextSection = CursorModelMenuBuilder.Section.context(value: "1m", title: "1M Context")
        XCTAssertEqual(
            leaves.filter { $0.section == contextSection }.map(\.rawValue),
            [
                "gpt-5.6-sol[context=1m]",
                "gpt-5.6-sol[context=1m,thinking_mode=none]",
                "gpt-5.6-sol[context=1m,thinking_mode=low]",
                "gpt-5.6-sol[context=1m,thinking_mode=high]"
            ]
        )
        XCTAssertEqual(
            leaves.filter { $0.section == .fast }.map(\.rawValue),
            [
                "gpt-5.6-sol[fast=true]",
                "gpt-5.6-sol[thinking_mode=none,fast=true]",
                "gpt-5.6-sol[thinking_mode=low,fast=true]",
                "gpt-5.6-sol[thinking_mode=high,fast=true]"
            ]
        )
        XCTAssertFalse(leaves.contains {
            $0.rawValue.contains("context=1m") && $0.rawValue.contains("fast=true")
        })
        XCTAssertEqual(
            CursorModelMenuBuilder.sections(from: leaves).map(\.title),
            [nil, nil, "1M Context", "Fast (2×)"]
        )

        let contextOnlyCatalog = CursorModelParameterCatalog()
        XCTAssertTrue(contextOnlyCatalog.apply(response: response(
            includeThought: false,
            includeFast: false,
            contextID: "token_window"
        )))
        let contextOnlyLeaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .preset,
            selectedModelRaw: "",
            catalog: contextOnlyCatalog,
            isEnabled: true
        ))
        XCTAssertEqual(contextOnlyLeaves.map(\.rawValue), [
            "gpt-5.6-sol",
            "gpt-5.6-sol[token_window=1m]"
        ])
        XCTAssertTrue(contextOnlyLeaves.filter { $0.section == .reasoning }.isEmpty)

        let fastOnlyCatalog = CursorModelParameterCatalog()
        XCTAssertTrue(fastOnlyCatalog.apply(response: response(
            includeThought: false,
            includeContext: false
        )))
        let fastOnlyLeaves = try XCTUnwrap(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .preset,
            selectedModelRaw: "",
            catalog: fastOnlyCatalog,
            isEnabled: true
        ))
        XCTAssertEqual(fastOnlyLeaves.map(\.rawValue), [
            "gpt-5.6-sol",
            "gpt-5.6-sol[fast=true]"
        ])
        XCTAssertTrue(fastOnlyLeaves.filter { $0.section == .reasoning }.isEmpty)
    }

    func testLeavesDegradeToNilForUnsupportedInputs() {
        let catalog = makeCatalog()
        let emptyCatalog = CursorModelParameterCatalog()
        let noThoughtCatalog = CursorModelParameterCatalog()
        XCTAssertTrue(noThoughtCatalog.apply(response: response(
            includeThought: false,
            includeFast: false
        )))
        let composerCatalog = CursorModelParameterCatalog()
        XCTAssertTrue(composerCatalog.apply(response: response(
            includeThought: true,
            modelRaw: AgentModel.cursorComposer2.rawValue
        )))

        XCTAssertNil(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "",
            catalog: catalog,
            isEnabled: false
        ))
        XCTAssertNil(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "",
            catalog: emptyCatalog,
            isEnabled: true
        ))
        XCTAssertNil(CursorModelMenuBuilder.leaves(
            forModelRaw: "auto",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "",
            catalog: catalog,
            isEnabled: true
        ))
        XCTAssertNil(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "",
            catalog: noThoughtCatalog,
            isEnabled: true
        ))
        XCTAssertNil(CursorModelMenuBuilder.leaves(
            forModelRaw: "gpt-5.6-sol[thinking_mode=high]",
            dimensionSet: .agentReasoning,
            selectedModelRaw: "",
            catalog: catalog,
            isEnabled: true
        ))
        for dimensionSet in [
            CursorModelMenuBuilder.DimensionSet.agentReasoning,
            .preset
        ] {
            XCTAssertNil(CursorModelMenuBuilder.leaves(
                forModelRaw: AgentModel.cursorComposer2.rawValue,
                dimensionSet: dimensionSet,
                selectedModelRaw: "",
                catalog: composerCatalog,
                isEnabled: true
            ))
        }
    }

    func testDisplaySuffixAndFastDetectionWorkWithAndWithoutCatalog() {
        let raw = "gpt-5.6-sol[context=1m,thinking_mode=high,fast=true]"
        XCTAssertEqual(
            CursorModelMenuBuilder.displaySuffix(forRaw: raw, catalog: makeCatalog()),
            "High · Fast · 1M"
        )
        XCTAssertEqual(
            CursorModelMenuBuilder.displaySuffix(
                forRaw: "gpt-5.6-sol[thinking_mode=low,context=272k,fast=false]",
                catalog: makeCatalog()
            ),
            nil
        )
        XCTAssertEqual(
            CursorModelMenuBuilder.displaySuffix(
                forRaw: "gpt-5.6-sol[reasoning=high,fast=true,context=1m]",
                catalog: CursorModelParameterCatalog()
            ),
            "High · Fast · 1M"
        )

        XCTAssertTrue(CursorModelMenuBuilder.hasFastEnabled(raw))
        XCTAssertTrue(CursorModelMenuBuilder.hasFastEnabled("cursor:gpt[FAST=TrUe]"))
        XCTAssertFalse(CursorModelMenuBuilder.hasFastEnabled("gpt"))
        XCTAssertFalse(CursorModelMenuBuilder.hasFastEnabled("gpt[fast=false]"))
        XCTAssertFalse(CursorModelMenuBuilder.hasFastEnabled("gpt[fast=true"))
    }

    private func makeCatalog() -> CursorModelParameterCatalog {
        let catalog = CursorModelParameterCatalog()
        XCTAssertTrue(catalog.apply(response: response(includeThought: true)))
        return catalog
    }

    private func response(
        includeThought: Bool,
        includeContext: Bool = true,
        includeFast: Bool = true,
        contextID: String = "context",
        modelRaw: String = "gpt-5.6-sol"
    ) -> [String: Any] {
        var specs: [[String: Any]] = []
        if includeContext {
            specs.append([
                "id": contextID,
                "category": "context_window",
                "type": "select",
                "currentValue": "272k",
                "options": [
                    ["value": "272k", "name": "272k"],
                    ["value": "1m", "name": "1m"]
                ]
            ])
        }
        if includeThought {
            specs.append([
                "id": "thinking_mode",
                "category": "thought_level",
                "type": "select",
                "currentValue": "low",
                "options": [
                    ["value": "none", "name": "None"],
                    ["value": "low", "name": "Low"],
                    ["value": "high", "name": "High"]
                ]
            ])
        }
        if includeFast {
            specs.append([
                "id": "fast",
                "category": "speed",
                "type": "select",
                "currentValue": "false",
                "options": [
                    ["value": "false", "name": "Off"],
                    ["value": "true", "name": "On"]
                ]
            ])
        }
        return [
            "models": [[
                "value": modelRaw,
                "configOptions": specs
            ]]
        ]
    }
}
