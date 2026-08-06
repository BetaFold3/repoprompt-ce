@testable import RepoPromptApp
import XCTest

final class CursorModelParameterPickerViewModelTests: XCTestCase {
    func testParameterSelectionComposesFullBracketWithFastLast() throws {
        let viewModel = try makeViewModel(selectedModelRaw: "gpt-5.6-sol")

        let selection = try XCTUnwrap(
            viewModel.selectionRaw(setting: "reasoning", to: "high")
        )

        XCTAssertEqual(
            selection,
            "gpt-5.6-sol[context=272k,reasoning=high,fast=false]"
        )
        let parsed = try XCTUnwrap(CursorBracketModelID.parse(selection))
        XCTAssertTrue(parsed.hasBracket)
        XCTAssertEqual(parsed.params.map(\.key), ["context", "reasoning", "fast"])
    }

    func testBracketSelectionReflectsParameterValuesAndCursorLabels() throws {
        let viewModel = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=1m,reasoning=max,fast=true]"
        )

        XCTAssertTrue(viewModel.isSelectedModel)
        XCTAssertEqual(viewModel.parameters.map(\.id), ["context", "reasoning", "fast"])
        XCTAssertEqual(viewModel.parameters.map(\.label), ["Context", "Reasoning", "Fast"])
        XCTAssertEqual(viewModel.parameters.map(\.selectedValue), ["1m", "max", "true"])
        XCTAssertEqual(
            viewModel.parameters.last?.options.map(\.displayName),
            ["Off", "On"]
        )
    }

    func testInactiveProviderSelectionSuppressesParentAndParameterCheckmarks() throws {
        let viewModel = try makeViewModel(selectedModelRaw: "")

        XCTAssertFalse(viewModel.isSelectedModel)
        XCTAssertTrue(viewModel.parameters.allSatisfy { $0.selectedValue == nil })
    }

    func testDefaultSelectionResetsFullyNonDefaultBracketToCatalogDefaults() throws {
        let viewModel = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
        )

        XCTAssertEqual(
            viewModel.defaultSelectionRaw(),
            "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        )
    }

    func testDisabledEmptyAndAutoSelectionsHideParameterPicker() {
        let hiddenViewModels = [
            CursorModelParameterPickerViewModel(
                modelRaw: "gpt-5.6-sol",
                selectedModelRaw: "gpt-5.6-sol",
                specs: parameterSpecs(),
                isEnabled: false
            ),
            CursorModelParameterPickerViewModel(
                modelRaw: "gpt-5.6-sol",
                selectedModelRaw: "gpt-5.6-sol",
                specs: [],
                isEnabled: true
            ),
            CursorModelParameterPickerViewModel(
                modelRaw: "auto",
                selectedModelRaw: "auto",
                specs: parameterSpecs(),
                isEnabled: true
            ),
            CursorModelParameterPickerViewModel(
                modelRaw: "gpt-5.6-sol[",
                selectedModelRaw: "gpt-5.6-sol[",
                specs: parameterSpecs(),
                isEnabled: true
            )
        ]

        XCTAssertTrue(hiddenViewModels.allSatisfy { $0 == nil })
        XCTAssertTrue(hiddenViewModels.allSatisfy { $0?.plainMenuRowDescriptor() == nil })
    }

    func testSelectionStateClassifiesAllSupportedStatesAndUnknownKeys() throws {
        let notSelected = try makeViewModel(selectedModelRaw: "auto")
        XCTAssertEqual(notSelected.selectionState, .notSelected)

        let inherited = try makeViewModel(selectedModelRaw: "gpt-5.6-sol")
        XCTAssertEqual(inherited.selectionState, .inheritedBareBase)

        let partial = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=272k,reasoning=high,fast=false,future=on]"
        )
        XCTAssertEqual(partial.selectionState, .partialOrUnsupportedBracket)

        let fullyEnforced = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=272k,reasoning=high,fast=false]"
        )
        XCTAssertEqual(fullyEnforced.selectionState, .fullyEnforced)
    }

    func testCurrentSelectionUsesDefaultsCanonicalizesBareAndPreservesFullBracketExactly() throws {
        let fresh = try makeViewModel(selectedModelRaw: "auto")
        XCTAssertEqual(
            fresh.currentSelectionRaw(),
            "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        )

        let exact = "gpt-5.6-sol[fast=true,reasoning=high,context=1m]"
        let fullyEnforced = try makeViewModel(selectedModelRaw: exact)
        XCTAssertEqual(fullyEnforced.currentSelectionRaw(), exact)

        let inherited = try makeViewModel(selectedModelRaw: "gpt-5.6-sol")
        XCTAssertEqual(
            inherited.currentSelectionRaw(),
            "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        )
    }

    func testPlainMenuRowDescriptorReportsSelectionAndFastWarning() throws {
        let fast = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
        )
        XCTAssertEqual(
            fast.plainMenuRowDescriptor(),
            .init(
                isSelected: true,
                selectionRaw: "gpt-5.6-sol[context=1m,reasoning=high,fast=true]",
                showsFastWarning: true
            )
        )

        let fresh = try makeViewModel(selectedModelRaw: "auto")
        let freshDescriptor = try XCTUnwrap(fresh.plainMenuRowDescriptor())
        XCTAssertFalse(freshDescriptor.isSelected)
        XCTAssertFalse(freshDescriptor.showsFastWarning)

        let invalid = CursorModelParameterPickerViewModel(
            modelRaw: "gpt-5.6-sol",
            selectedModelRaw: "auto",
            specs: invalidParameterSpecs(),
            isEnabled: true
        )
        XCTAssertNil(invalid?.plainMenuRowDescriptor())
    }

    func testSummaryLabelUsesSpecOrderAndSurfacesSelectionState() throws {
        let ordinary = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        )
        XCTAssertEqual(ordinary.summaryLabel, "272k · Medium")
        XCTAssertFalse(ordinary.summaryShowsFastWarning)

        let fast = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[context=1m,reasoning=high,fast=true]"
        )
        XCTAssertEqual(fast.summaryLabel, "1m · High · Fast")
        XCTAssertTrue(fast.summaryShowsFastWarning)

        let inherited = try makeViewModel(selectedModelRaw: "gpt-5.6-sol")
        XCTAssertEqual(inherited.summaryLabel, "Inherited")
        XCTAssertFalse(inherited.summaryShowsFastWarning)

        let partial = try makeViewModel(
            selectedModelRaw: "gpt-5.6-sol[reasoning=high,fast=true]"
        )
        XCTAssertEqual(partial.summaryLabel, "Partial")
        XCTAssertTrue(partial.summaryShowsFastWarning)
    }

    func testSequentialImmediateCompositionAccumulatesAcrossCommittedSelections() throws {
        let fresh = try makeViewModel(selectedModelRaw: "auto")
        let defaults = try XCTUnwrap(fresh.currentSelectionRaw())
        XCTAssertEqual(
            defaults,
            "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"
        )

        let selected = try makeViewModel(selectedModelRaw: defaults)
        let high = try XCTUnwrap(selected.selectionRaw(setting: "reasoning", to: "high"))

        let highSelection = try makeViewModel(selectedModelRaw: high)
        let fast = try XCTUnwrap(
            highSelection.selectionRaw(setting: "fast", to: "true")
        )

        XCTAssertEqual(
            fast,
            "gpt-5.6-sol[context=272k,reasoning=high,fast=true]"
        )
    }

    private func makeViewModel(
        selectedModelRaw: String
    ) throws -> CursorModelParameterPickerViewModel {
        try XCTUnwrap(CursorModelParameterPickerViewModel(
            modelRaw: "gpt-5.6-sol",
            selectedModelRaw: selectedModelRaw,
            specs: parameterSpecs(),
            isEnabled: true
        ))
    }

    private func parameterSpecs() -> [CursorModelParameterCatalog.ParameterSpec] {
        [
            .init(
                id: "context",
                category: "model_config",
                defaultValue: "272k",
                options: [
                    .init(value: "272k", name: "272K"),
                    .init(value: "1m", name: "1M")
                ],
                description: "Context window"
            ),
            .init(
                id: "reasoning",
                category: "thought_level",
                defaultValue: "medium",
                options: [
                    .init(value: "medium", name: "Medium"),
                    .init(value: "high", name: "High"),
                    .init(value: "max", name: "Max")
                ],
                description: "Reasoning level"
            ),
            .init(
                id: "fast",
                category: "model_config",
                defaultValue: "false",
                options: [
                    .init(value: "false", name: "Disabled"),
                    .init(value: "true", name: "Enabled")
                ],
                description: "2x more expensive, but faster speeds"
            )
        ]
    }

    private func invalidParameterSpecs() -> [CursorModelParameterCatalog.ParameterSpec] {
        [
            .init(
                id: "reasoning",
                category: "thought_level",
                defaultValue: "not,representable",
                options: [.init(value: "not,representable", name: "Invalid")],
                description: nil
            )
        ]
    }
}
