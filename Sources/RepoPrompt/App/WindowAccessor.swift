//
//  WindowAccessor.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-21.
//

import AppKit
import RepoPromptUI
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(callback: callback)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.schedule(window: view.window)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.schedule(window: nsView.window)
    }

    final class Coordinator {
        private let callback: (NSWindow?) -> Void
        private weak var lastWindow: NSWindow?
        private var tokens: [NSObjectProtocol] = []
        private var pendingCallback: DispatchWorkItem?
        private let callbackWorkGate = WorkItemGate()

        init(callback: @escaping (NSWindow?) -> Void) {
            self.callback = callback
        }

        func schedule(window: NSWindow?) {
            guard lastWindow !== window else { return }
            lastWindow = window
            installObservers(for: window)
            fireCallbackDebounced(for: window)
        }

        private func fireCallbackDebounced(for window: NSWindow?, delay: TimeInterval = 0.05) {
            pendingCallback?.cancel()
            callbackWorkGate.cancel()
            pendingCallback = callbackWorkGate.schedule(after: delay) { [weak self, weak window] in
                guard let self else { return }
                callback(window)
            }
        }

        private func installObservers(for window: NSWindow?) {
            removeObservers()
            guard window != nil else { return }
            // Intentionally no extra observers; WindowState handles focus/title updates.
        }

        private func removeObservers() {
            for t in tokens {
                NotificationCenter.default.removeObserver(t)
            }
            tokens.removeAll()
            pendingCallback?.cancel()
            pendingCallback = nil
            callbackWorkGate.cancel()
        }

        deinit {
            removeObservers()
        }
    }
}
