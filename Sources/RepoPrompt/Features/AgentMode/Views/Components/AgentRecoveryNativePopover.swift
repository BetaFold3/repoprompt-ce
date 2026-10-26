import AppKit
import SwiftUI

/// What an open native recovery popover does with one app event.
///
/// SwiftUI's `.popover` swallows the outside click that dismisses it, so the user has to click
/// twice. The native popover instead closes from a local event monitor and hands the click on.
enum AgentRecoveryNativePopoverEventDecision: Equatable {
    /// Keep the popover open and deliver the event normally.
    case ignore
    /// Close the popover, then deliver the event to whatever was clicked.
    case closeAndDeliver
    /// Close the popover and swallow the event (a click on the anchor toggles it closed; Escape).
    case closeAndConsume

    static func decide(
        isMouseDown: Bool,
        isEscapeKey: Bool,
        isInPopoverWindow: Bool,
        isOnAnchor: Bool
    ) -> Self {
        if isMouseDown {
            if isInPopoverWindow { return .ignore }
            // The anchor's own button would reopen the popover; a click there just closes it,
            // matching the toggle of the previous SwiftUI popover.
            return isOnAnchor ? .closeAndConsume : .closeAndDeliver
        }
        if isEscapeKey, isInPopoverWindow { return .closeAndConsume }
        return .ignore
    }
}

extension View {
    /// An AppKit `NSPopover` anchored to this view, hosting `content` in SwiftUI. Unlike `.popover`,
    /// the outside click that dismisses it still reaches what was clicked.
    func agentRecoveryNativePopover(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        background(
            AgentRecoveryNativePopoverAnchor(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
        )
    }
}

private struct AgentRecoveryNativePopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            anchor: nsView,
            isPresented: $isPresented,
            preferredEdge: Self.rectEdge(for: arrowEdge),
            content: content
        )
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        // Never write the binding mid-update; reset it afterwards so a View button that comes back
        // doesn't start with a stale `true` (which would make it look dead).
        coordinator.close(reportingClosed: .deferred)
    }

    /// The anchor `NSView` is unflipped, so the top edge is `maxY`.
    private static func rectEdge(for edge: Edge) -> NSRectEdge {
        switch edge {
        case .top: .maxY
        case .bottom: .minY
        case .leading: .minX
        case .trailing: .maxX
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        /// When `close` writes `false` to the binding.
        enum BindingReport {
            /// Synchronously (event monitor, app deactivation, SwiftUI-requested close).
            case now
            /// On the next main-queue turn, if still `true` (SwiftUI dismantle, AppKit close).
            case deferred
        }

        private var popover: NSPopover?
        private var host: NSHostingController<PopoverContent>?
        private var eventMonitor: Any?
        private var resignActiveObserver: NSObjectProtocol?
        private weak var anchor: NSView?
        private var isPresented: Binding<Bool>?

        func update(
            anchor: NSView,
            isPresented: Binding<Bool>,
            preferredEdge: NSRectEdge,
            content: () -> PopoverContent
        ) {
            self.anchor = anchor
            self.isPresented = isPresented
            if isPresented.wrappedValue {
                if let host {
                    host.rootView = content()
                } else {
                    show(anchor: anchor, preferredEdge: preferredEdge, content: content())
                }
            } else if popover != nil {
                close()
            }
        }

        private func show(anchor: NSView, preferredEdge: NSRectEdge, content: PopoverContent) {
            guard anchor.window != nil else { return }
            // A fresh hosting controller per presentation, so the content's `.task` runs on each
            // open and is cancelled on close, as with SwiftUI's popover.
            let host = NSHostingController(rootView: content)
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            // AppKit's transient handling is replaced by the event monitor below, which closes the
            // popover without consuming the click.
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.contentViewController = host
            popover.delegate = self
            self.host = host
            self.popover = popover
            installMonitors()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        }

        /// Closes the popover (if shown) and reports it closed through the binding. Idempotent.
        func close(reportingClosed report: BindingReport = .now) {
            removeMonitors()
            let popover = popover
            self.popover = nil
            host = nil
            popover?.delegate = nil
            popover?.close()
            guard let isPresented else { return }
            switch report {
            case .now:
                if isPresented.wrappedValue { isPresented.wrappedValue = false }
            case .deferred:
                DispatchQueue.main.async {
                    if isPresented.wrappedValue { isPresented.wrappedValue = false }
                }
            }
        }

        func popoverDidClose(_: Notification) {
            // AppKit closed it (e.g. its window went away); keep the binding in sync without
            // writing it from inside whatever AppKit or SwiftUI work triggered the close.
            close(reportingClosed: .deferred)
        }

        private func installMonitors() {
            removeMonitors()
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                let consume = MainActor.assumeIsolated { self?.shouldConsume(event) ?? false }
                return consume ? nil : event
            }
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }

        private func removeMonitors() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
            resignActiveObserver = nil
        }

        /// Applies the decision for `event`; `true` means the event must not be dispatched.
        private func shouldConsume(_ event: NSEvent) -> Bool {
            guard let popover else { return false }
            let popoverWindow = popover.contentViewController?.view.window
            let isMouseDown = event.type != .keyDown
            let decision = AgentRecoveryNativePopoverEventDecision.decide(
                isMouseDown: isMouseDown,
                isEscapeKey: event.type == .keyDown && event.keyCode == 53,
                isInPopoverWindow: event.window != nil && event.window === popoverWindow,
                isOnAnchor: isMouseDown && isOnAnchor(event)
            )
            switch decision {
            case .ignore:
                return false
            case .closeAndConsume:
                close()
                return true
            case .closeAndDeliver:
                close()
                // The popover window was key; make the clicked anchor window key before AppKit
                // dispatches the event, so it is delivered as a normal click rather than spent
                // activating the window. Other windows keep normal macOS first-click activation,
                // so sheets, panels and window order are left to AppKit.
                if let window = event.window, window === anchor?.window, !window.isKeyWindow {
                    window.makeKey()
                }
                return false
            }
        }

        private func isOnAnchor(_ event: NSEvent) -> Bool {
            guard let anchor, let window = anchor.window, event.window === window else { return false }
            let point = anchor.convert(event.locationInWindow, from: nil)
            return anchor.bounds.contains(point)
        }
    }
}
