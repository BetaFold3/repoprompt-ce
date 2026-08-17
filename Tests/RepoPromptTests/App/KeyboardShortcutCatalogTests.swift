@testable import RepoPromptApp
import XCTest

final class KeyboardShortcutCatalogTests: XCTestCase {
    func testAgentCatalogIncludesQuickModelAndHandoffBindings() throws {
        let section = try XCTUnwrap(
            KeyboardShortcutCatalog.sections.first { $0.id == "agent-layout" }
        )
        let bindings = Dictionary(uniqueKeysWithValues: section.bindings.map { ($0.id, $0) })

        let modelPicker = try XCTUnwrap(bindings["agent-model-picker"])
        XCTAssertEqual(modelPicker.title, "Quick model picker")
        XCTAssertEqual(
            modelPicker.detail,
            "Switch models in the active Agent session."
        )
        XCTAssertEqual(
            modelPicker.name.rawValue,
            "showAgentQuickModelSelectionHUD"
        )

        let handoff = try XCTUnwrap(bindings["agent-quick-handoff"])
        XCTAssertEqual(handoff.title, "Quick handoff")
        XCTAssertEqual(
            handoff.detail,
            "Start a new session from the last completed assistant reply."
        )
        XCTAssertEqual(handoff.name.rawValue, "showAgentQuickHandoffHUD")
        XCTAssertNotEqual(modelPicker.name, handoff.name)
    }

    func testSnippetPaletteNotificationContractPreservesPublicAndPrivateHops() {
        XCTAssertEqual(
            Notification.Name.openPromptSnippetPalette.rawValue,
            "openPromptSnippetPalette"
        )
        XCTAssertEqual(
            Notification.Name.performPromptSnippetPaletteActivation.rawValue,
            "performPromptSnippetPaletteActivation"
        )
        XCTAssertEqual(SnippetPaletteNotificationUserInfoKey.windowID, "windowID")
        XCTAssertEqual(SnippetPaletteNotificationUserInfoKey.tabID, "tabID")
    }

    func testModelSelectionHUDNotificationContractUsesStableModes() {
        XCTAssertEqual(
            Notification.Name.showAgentModelSelectionHUD.rawValue,
            "showAgentModelSelectionHUD"
        )
        XCTAssertEqual(
            AgentModelSelectionHUDNotificationUserInfoKey.windowID,
            "windowID"
        )
        XCTAssertEqual(
            AgentModelSelectionHUDNotificationUserInfoKey.mode,
            "mode"
        )
        XCTAssertEqual(
            AgentModelSelectionHUDMode.switchModel.rawValue,
            "switchModel"
        )
        XCTAssertEqual(
            AgentModelSelectionHUDMode.handoffLastReply.rawValue,
            "handoffLastReply"
        )
    }
}
