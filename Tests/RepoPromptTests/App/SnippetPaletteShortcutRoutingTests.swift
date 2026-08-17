@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class SnippetPaletteShortcutRoutingTests: XCTestCase {
    func testScopeMatchRequiresExactWindowAndTab() {
        let tabID = UUID()
        let otherTabID = UUID()
        let scope = SnippetPaletteScope(windowID: 41, tabID: tabID)

        let scopes: [(name: String, value: SnippetPaletteScope?)] = [
            ("scoped", scope),
            ("nil scope", nil)
        ]
        let windows: [(name: String, value: Int?)] = [
            ("matching window", 41),
            ("mismatched window", 42),
            ("absent window", nil)
        ]
        let tabs: [(name: String, value: UUID?)] = [
            ("matching tab", tabID),
            ("mismatched tab", otherTabID),
            ("absent tab", nil)
        ]

        for scopeCase in scopes {
            for windowCase in windows {
                for tabCase in tabs {
                    let expected = scopeCase.value != nil
                        && windowCase.value == 41
                        && tabCase.value == tabID
                    XCTAssertEqual(
                        SnippetPaletteScope.matches(
                            scopeCase.value,
                            requestWindowID: windowCase.value,
                            requestTabID: tabCase.value
                        ),
                        expected,
                        "\(scopeCase.name), \(windowCase.name), \(tabCase.name)"
                    )
                }
            }
        }
    }

    func testReconfiguringScopeDismissesActiveSessionWithoutTextChange() {
        let scopeA = SnippetPaletteScope(windowID: 41, tabID: UUID())
        let scopeB = SnippetPaletteScope(windowID: 41, tabID: UUID())
        let item = SnippetPaletteItem(id: UUID(), title: "Snippet", content: "Content")
        let itemsProvider = { [item] }
        let featuresA = ResizableTextFieldFeatures(
            enableSnippetPalette: true,
            snippetPaletteItemsProvider: itemsProvider,
            snippetPaletteScope: scopeA
        )
        let featuresB = ResizableTextFieldFeatures(
            enableSnippetPalette: true,
            snippetPaletteItemsProvider: itemsProvider,
            snippetPaletteScope: scopeB
        )
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { owner.orderOut(nil) }
        let textView = ImageAwareTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 80))
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        owner.contentView = textView

        let coordinator = CustomTextField.Coordinator(
            CustomTextField(
                text: .constant(""),
                placeholder: "",
                onReturn: {},
                onImagePaste: nil,
                features: featuresA,
                currentHeightPresetIndex: .constant(0)
            )
        )
        defer { coordinator.tearDownSnippetPaletteSupport() }
        coordinator.configureSnippetPaletteSupport(
            textView: textView,
            enabled: true,
            itemsProvider: itemsProvider,
            scope: scopeA
        )
        coordinator.openSnippetPaletteSessionForTesting(in: textView)
        XCTAssertTrue(coordinator.snippetPaletteSessionIsActiveForTesting)

        coordinator.parent = CustomTextField(
            text: .constant(""),
            placeholder: "",
            onReturn: {},
            onImagePaste: nil,
            features: featuresB,
            currentHeightPresetIndex: .constant(0)
        )
        coordinator.configureSnippetPaletteSupport(
            textView: textView,
            enabled: true,
            itemsProvider: itemsProvider,
            scope: scopeB
        )

        XCTAssertFalse(coordinator.snippetPaletteSessionIsActiveForTesting)
        XCTAssertEqual(textView.string, "")
    }
}
