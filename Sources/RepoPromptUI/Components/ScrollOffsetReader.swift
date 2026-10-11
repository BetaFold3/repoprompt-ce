import AppKit
import SwiftUI

/// A lightweight NSView that observes its enclosing scroll view's NSClipView
/// and reports scroll offset changes through a callback.
///
/// IMPORTANT: Callbacks are deferred to the next run loop iteration to avoid
/// SwiftUI re-entrancy issues during view construction. Multiple rapid scroll
/// events are coalesced, with only the latest offset being reported.
final class ScrollObserverView: NSView {
    var onScroll: ((CGPoint) -> Void)?
    private var observer: Any?
    private var pendingOrigin: CGPoint?
    private var callbackScheduled = false

    /// Make sure this view never intercepts clicks/hover
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupObserver()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            teardownObserver()
        }
    }

    deinit {
        teardownObserver()
    }

    private func setupObserver() {
        teardownObserver()
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true

        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] note in
            guard let clip = note.object as? NSClipView else { return }
            self?.enqueueCallback(with: clip.bounds.origin)
        }

        // Emit the initial offset on the next run loop turn to avoid re-entrancy.
        enqueueCallback(with: clipView.bounds.origin)
    }

    private func enqueueCallback(with origin: CGPoint) {
        pendingOrigin = origin
        guard !callbackScheduled else { return }
        callbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            callbackScheduled = false
            let origin = pendingOrigin
            pendingOrigin = nil
            if let origin {
                onScroll?(origin)
            }
        }
    }

    private func teardownObserver() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        // Reset state to avoid stale async callbacks after view lifecycle changes
        callbackScheduled = false
        pendingOrigin = nil
    }
}

/// SwiftUI wrapper for observing scroll offset changes of the nearest enclosing NSScrollView.
struct ScrollOffsetReader: NSViewRepresentable {
    var onChange: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollObserverView {
        let v = ScrollObserverView()
        v.onScroll = onChange
        return v
    }

    func updateNSView(_ nsView: ScrollObserverView, context: Context) {
        nsView.onScroll = onChange
    }
}

final class EnclosingScrollViewBox {
    /// Intentionally strong: callers clear this on teardown/reset, and keeping the
    /// last resolved scroll view alive avoids losing the handle during transient
    /// SwiftUI relayout churn.
    var scrollView: NSScrollView?
}

final class EnclosingScrollViewAccessorView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?
    private weak var lastResolvedScrollView: NSScrollView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveEnclosingScrollViewSoon()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveEnclosingScrollViewSoon()
    }

    override func layout() {
        super.layout()
        resolveEnclosingScrollViewSoon()
    }

    private func resolveEnclosingScrollViewSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scrollView = enclosingScrollView
            guard lastResolvedScrollView !== scrollView else { return }
            lastResolvedScrollView = scrollView
            onResolve?(scrollView)
        }
    }
}

struct EnclosingScrollViewAccessor: NSViewRepresentable {
    var onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> EnclosingScrollViewAccessorView {
        let view = EnclosingScrollViewAccessorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: EnclosingScrollViewAccessorView, context: Context) {
        nsView.onResolve = onResolve
        nsView.layoutSubtreeIfNeeded()
    }
}
