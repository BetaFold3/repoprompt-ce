import AppKit
import SwiftUI

@MainActor
final class AgentChatTitleClusterModel: ObservableObject {
    struct State: Equatable {
        var title: String
        var showsConversationBranches: Bool
        var showsChatOptions: Bool
    }

    @Published private(set) var state: State

    init(title: String) {
        state = State(title: title, showsConversationBranches: false, showsChatOptions: false)
    }

    func update(title: String, showsConversationBranches: Bool, showsChatOptions: Bool) {
        let nextState = State(
            title: title,
            showsConversationBranches: showsConversationBranches,
            showsChatOptions: showsChatOptions
        )
        guard state != nextState else { return }
        state = nextState
    }
}

enum AgentConversationBranchMenuRequestGate {
    static func shouldAccept(
        requestWindowID: Int?,
        currentWindowID: Int,
        showsConversationBranches: Bool
    ) -> Bool {
        requestWindowID == currentWindowID && showsConversationBranches
    }

    static func shouldPresent(
        requestID: UUID?,
        lastPresentationRequestID: UUID?
    ) -> Bool {
        requestID != nil && requestID != lastPresentationRequestID
    }
}

struct AgentChatTitleClusterView: View {
    @ObservedObject var model: AgentChatTitleClusterModel
    let windowID: Int
    let branchMenuSnapshot: () -> AgentConversationBranchPickerSnapshot?
    let branchMenuActions: AgentConversationBranchMenuActions
    let menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
    let menuActions: AgentChatOptionsMenuActions
    @State private var conversationBranchMenuRequestID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            Text(model.state.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 520)
                .accessibilityIdentifier("AgentChatTitle")

            if model.state.showsConversationBranches {
                AgentConversationBranchMenuButton(
                    presentationRequestID: conversationBranchMenuRequestID,
                    menuSnapshot: branchMenuSnapshot,
                    menuActions: branchMenuActions
                )
            }

            if model.state.showsChatOptions {
                AgentChatOptionsMenuButton(
                    menuSnapshot: menuSnapshot,
                    menuActions: menuActions
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .onReceive(NotificationCenter.default.publisher(for: .showAgentConversationBranches)) { notification in
            guard AgentConversationBranchMenuRequestGate.shouldAccept(
                requestWindowID: notification.userInfo?["windowID"] as? Int,
                currentWindowID: windowID,
                showsConversationBranches: model.state.showsConversationBranches
            ) else { return }
            conversationBranchMenuRequestID = UUID()
        }
    }
}

final class AgentConversationBranchButton: NSButton {
    init() {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Conversation Branches"
        )
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Conversation Branches"
        setAccessibilityLabel("Conversation Branches")
        setAccessibilityRole(.menuButton)
        setAccessibilityIdentifier("AgentConversationBranchButton")
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled, let action else { return }
        NSApplication.shared.sendAction(action, to: target, from: self)
    }
}

private struct AgentConversationBranchMenuButton: NSViewRepresentable {
    let presentationRequestID: UUID?
    let menuSnapshot: () -> AgentConversationBranchPickerSnapshot?
    let menuActions: AgentConversationBranchMenuActions

    func makeCoordinator() -> Coordinator {
        Coordinator(
            presentationRequestID: presentationRequestID,
            menuSnapshot: menuSnapshot,
            menuActions: menuActions
        )
    }

    func makeNSView(context: Context) -> AgentConversationBranchButton {
        let button = AgentConversationBranchButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ nsView: AgentConversationBranchButton, context: Context) {
        context.coordinator.menuSnapshot = menuSnapshot
        context.coordinator.menuActions = menuActions
        context.coordinator.presentMenuIfRequested(presentationRequestID, sender: nsView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var menuSnapshot: () -> AgentConversationBranchPickerSnapshot?
        var menuActions: AgentConversationBranchMenuActions
        private var lastPresentationRequestID: UUID?

        init(
            presentationRequestID: UUID?,
            menuSnapshot: @escaping () -> AgentConversationBranchPickerSnapshot?,
            menuActions: AgentConversationBranchMenuActions
        ) {
            lastPresentationRequestID = presentationRequestID
            self.menuSnapshot = menuSnapshot
            self.menuActions = menuActions
        }

        func presentMenuIfRequested(_ requestID: UUID?, sender: NSButton) {
            guard AgentConversationBranchMenuRequestGate.shouldPresent(
                requestID: requestID,
                lastPresentationRequestID: lastPresentationRequestID
            ), let requestID
            else { return }
            lastPresentationRequestID = requestID
            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender else { return }
                showMenu(sender)
            }
        }

        @objc func showMenu(_ sender: NSButton) {
            guard let snapshot = menuSnapshot() else { return }
            AgentConversationBranchMenuPresenter.popUp(
                below: sender,
                snapshot: snapshot,
                actions: menuActions
            )
        }
    }
}

final class AgentChatOptionsButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Chat Options")
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Chat Options"
        setAccessibilityLabel("Chat Options")
        setAccessibilityRole(.menuButton)
        setAccessibilityIdentifier("AgentChatOptionsButton")

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled, let action else { return }
        NSApplication.shared.sendAction(action, to: target, from: self)
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: layer?.cornerRadius ?? 6,
            yRadius: layer?.cornerRadius ?? 6
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        contentTintColor = NSColor.labelColor.withAlphaComponent(isHovering ? 1 : 0.8)
    }
}

private struct AgentChatOptionsMenuButton: NSViewRepresentable {
    let menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
    let menuActions: AgentChatOptionsMenuActions

    func makeCoordinator() -> Coordinator {
        Coordinator(menuSnapshot: menuSnapshot, menuActions: menuActions)
    }

    func makeNSView(context: Context) -> AgentChatOptionsButton {
        let button = AgentChatOptionsButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ nsView: AgentChatOptionsButton, context: Context) {
        _ = nsView
        context.coordinator.menuSnapshot = menuSnapshot
        context.coordinator.menuActions = menuActions
    }

    @MainActor
    final class Coordinator: NSObject {
        var menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
        var menuActions: AgentChatOptionsMenuActions

        init(
            menuSnapshot: @escaping () -> AgentChatOptionsMenuSnapshot?,
            menuActions: AgentChatOptionsMenuActions
        ) {
            self.menuSnapshot = menuSnapshot
            self.menuActions = menuActions
        }

        @objc func showMenu(_ sender: NSButton) {
            guard let snapshot = menuSnapshot() else { return }
            AgentChatOptionsMenuPresenter.popUp(
                below: sender,
                snapshot: snapshot,
                actions: menuActions
            )
        }
    }
}
