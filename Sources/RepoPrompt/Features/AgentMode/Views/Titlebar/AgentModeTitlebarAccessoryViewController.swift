//
//  AgentModeTitlebarAccessoryViewController.swift
//  RepoPrompt
//
//  Xcode-style titlebar accessory that places a "New Session" button
//  near the traffic lights using NSTitlebarAccessoryViewController.
//

import Cocoa
import SwiftUI

// MARK: - SwiftUI View for Titlebar Button

/// Compact "New Session" button designed for the titlebar area
private struct AgentModeTitlebarNewSessionView: View {
    let onNewSession: () -> Void
    let onNewKnowledgeSession: () -> Void
    let isKnowledgeSessionAvailable: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary.opacity(isHovering ? 1.0 : 0.7))
                    // SEARCH-HELPER: Titlebar, Alignment, Compose icon offset
                    // The `square.and.pencil` glyph's pencil shaft extends up-and-right
                    // beyond the square, so nudge the visible mass up slightly.
                    .offset(y: -1.5)
            }
            .buttonStyle(TitlebarAccessoryButtonStyle(isHovering: isHovering))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .hoverTooltip("New Session", .bottom)
            .accessibilityLabel("New Session")

            Menu {
                Button("New Knowledge Session", systemImage: "brain", action: onNewKnowledgeSession)
                    .disabled(!isKnowledgeSessionAvailable)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverTooltip("More session types", .bottom)
            .accessibilityLabel("More session types")
        }
    }
}

/// Button style optimized for titlebar accessory placement
struct TitlebarAccessoryButtonStyle: ButtonStyle {
    let isHovering: Bool

    init(isHovering: Bool = false) {
        self.isHovering = isHovering
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            Color.primary.opacity(0.15)
        } else if isHovering {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
    }
}

// MARK: - AppKit Titlebar Accessory Controller

@MainActor
final class AgentModeTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private var hostingView: NSHostingView<AgentModeTitlebarNewSessionView>?
    private var onNewSession: () -> Void
    private var onNewKnowledgeSession: () -> Void
    private var isKnowledgeSessionAvailable: Bool

    init(
        onNewSession: @escaping () -> Void,
        onNewKnowledgeSession: @escaping () -> Void = {},
        isKnowledgeSessionAvailable: Bool = true
    ) {
        self.onNewSession = onNewSession
        self.onNewKnowledgeSession = onNewKnowledgeSession
        self.isKnowledgeSessionAvailable = isKnowledgeSessionAvailable
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let swiftUIView = AgentModeTitlebarNewSessionView(
            onNewSession: onNewSession,
            onNewKnowledgeSession: onNewKnowledgeSession,
            isKnowledgeSessionAvailable: isKnowledgeSessionAvailable
        )
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.frame.size = hosting.fittingSize
        hostingView = hosting
        view = hosting
    }

    // Updates the action closure without recreating the controller
    #if DEBUG
        func testInvokeNewSession() {
            onNewSession()
        }

        func testInvokeNewKnowledgeSession() {
            guard isKnowledgeSessionAvailable else { return }
            onNewKnowledgeSession()
        }
    #endif

    func update(
        onNewSession: @escaping () -> Void,
        onNewKnowledgeSession: @escaping () -> Void = {},
        isKnowledgeSessionAvailable: Bool = true
    ) {
        self.onNewSession = onNewSession
        self.onNewKnowledgeSession = onNewKnowledgeSession
        self.isKnowledgeSessionAvailable = isKnowledgeSessionAvailable
        hostingView?.rootView = AgentModeTitlebarNewSessionView(
            onNewSession: onNewSession,
            onNewKnowledgeSession: onNewKnowledgeSession,
            isKnowledgeSessionAvailable: isKnowledgeSessionAvailable
        )
    }
}
