import AppKit

typealias AgentConversationBranchPickerTarget = AgentModeViewModel.ConversationBranchPickerTarget
typealias AgentConversationBranchPickerItem = AgentModeViewModel.ConversationBranchPickerItem
typealias AgentConversationBranchPickerSnapshot = AgentModeViewModel.ConversationBranchPickerSnapshot

struct AgentConversationBranchMenuActions {
    let switchBranch: (AgentConversationBranchPickerTarget, UUID) -> Void
}

private final class AgentConversationBranchMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        state: NSControl.StateValue,
        isEnabled: Bool,
        toolTip: String?,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler(_:)), keyEquivalent: "")
        target = self
        self.state = state
        self.isEnabled = isEnabled
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performHandler(_ sender: NSMenuItem) {
        _ = sender
        handler()
    }
}

@MainActor
enum AgentConversationBranchMenuPresenter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func title(for item: AgentConversationBranchPickerItem) -> String {
        if item.isOriginal {
            return item.isDeleted ? "Original (deleted)" : "Original"
        }
        let dateText = item.date.map(dateFormatter.string(from:)) ?? "Unknown date"
        if let ordinal = item.sourceTurnOrdinal {
            return "Branch from turn \(ordinal) — \(dateText)"
        }
        return "Branch — \(dateText)"
    }

    static func makeMenu(
        snapshot: AgentConversationBranchPickerSnapshot,
        actions: AgentConversationBranchMenuActions
    ) -> NSMenu {
        let target = snapshot.target
        let menu = NSMenu(title: "Conversation Branches")
        menu.autoenablesItems = false
        for item in snapshot.items {
            menu.addItem(AgentConversationBranchMenuItem(
                title: title(for: item),
                state: item.isActive ? .on : .off,
                isEnabled: item.isEnabled,
                toolTip: item.disabledHelpText,
                handler: { actions.switchBranch(target, item.id) }
            ))
        }
        return menu
    }

    static func popUp(
        below anchorView: NSView,
        snapshot: AgentConversationBranchPickerSnapshot,
        actions: AgentConversationBranchMenuActions
    ) {
        let menu = makeMenu(snapshot: snapshot, actions: actions)
        let menuOriginY = anchorView.isFlipped
            ? anchorView.bounds.maxY + 2
            : anchorView.bounds.minY - 2
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchorView.bounds.minX, y: menuOriginY),
            in: anchorView
        )
    }
}
