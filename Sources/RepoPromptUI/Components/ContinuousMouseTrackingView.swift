import AppKit
import SwiftUI

struct ContinuousMouseTrackingView: NSViewRepresentable {
    let onMouseMove: (NSPoint) -> Void
    let onMouseEnter: () -> Void
    let onMouseExit: () -> Void

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMouseMove = onMouseMove
        view.onMouseEnter = onMouseEnter
        view.onMouseExit = onMouseExit
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        nsView.onMouseMove = onMouseMove
        nsView.onMouseEnter = onMouseEnter
        nsView.onMouseExit = onMouseExit
    }

    class MouseTrackingNSView: NSView {
        var onMouseMove: ((NSPoint) -> Void)?
        var onMouseEnter: (() -> Void)?
        var onMouseExit: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            print("MouseTrackingNSView initialized with frame: \(frame)")
            setupView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            print("MouseTrackingNSView initialized from coder")
            setupView()
        }

        private func setupView() {
            // Enable mouse move events for this view
            window?.acceptsMouseMovedEvents = true
            // Add this to enable mouse move events
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect
                ],
                owner: self,
                userInfo: nil
            ))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            print("Updating tracking areas")

            // Remove existing tracking areas
            for trackingArea in trackingAreas {
                removeTrackingArea(trackingArea)
            }

            // Setup new tracking area with all the necessary options
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect
            ]

            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            print("Added tracking area with bounds: \(bounds)")
        }

        override func mouseMoved(with event: NSEvent) {
            print("Mouse moved")
            handleMouseEvent(event)
        }

        override func mouseDragged(with event: NSEvent) {
            print("Mouse dragged")
            handleMouseEvent(event)
        }

        private func handleMouseEvent(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            print("Mouse point: \(point)")
            onMouseMove?(point)
        }

        override func mouseEntered(with event: NSEvent) {
            print("Mouse entered")
            onMouseEnter?()
        }

        override func mouseExited(with event: NSEvent) {
            print("Mouse exited")
            onMouseExit?()
        }

        override func setFrameSize(_ newSize: NSSize) {
            print("Setting frame size to: \(newSize)")
            super.setFrameSize(newSize)
            updateTrackingAreas()
        }

        /// Add this to make the view accept mouse events
        override var acceptsFirstResponder: Bool {
            true
        }

        /// Add this to make the view visible for debugging
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.red.withAlphaComponent(0.1).set()
            dirtyRect.fill()
        }
    }
}
