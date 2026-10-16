import AppKit
@testable import RepoPromptApp
import XCTest

/// Hosts the sidebar running-row arc's layer view in an unshown offscreen window and inspects
/// its Core Animation state directly: one render-server rotation installed only when missing,
/// phase-preserving across updates, removed off-window, and SwiftUI-equivalent geometry.
@MainActor
final class AgentRowActivityArcLayerTests: XCTestCase {
    private static let side: CGFloat = 15 + AgentRowActivityArcLayerView.lineWidth

    func testAttachingToWindowInstallsExactlyOneRotationAnimation() throws {
        let host = ArcHost()
        defer { host.close() }
        XCTAssertNil(host.view.arcLayer.animationKeys(), "no animation may run before the view has a window")

        host.attach()

        XCTAssertEqual(host.view.arcLayer.animationKeys(), [AgentRowActivityArcLayerView.rotationAnimationKey])
        let rotation = try XCTUnwrap(
            host.view.arcLayer.animation(forKey: AgentRowActivityArcLayerView.rotationAnimationKey) as? CABasicAnimation
        )
        XCTAssertEqual(rotation.keyPath, "transform.rotation.z")
        XCTAssertEqual(try XCTUnwrap(rotation.fromValue as? Double), 0)
        XCTAssertEqual(try XCTUnwrap(rotation.toValue as? Double), 2 * .pi, accuracy: 1e-9, "positive rotation reads clockwise in the flipped layer space")
        XCTAssertEqual(rotation.duration, 1.0)
        XCTAssertEqual(rotation.repeatCount, .infinity)
        XCTAssertFalse(rotation.isRemovedOnCompletion)
        let timing = try XCTUnwrap(rotation.timingFunction)
        var first = [Float](repeating: -1, count: 2)
        var second = [Float](repeating: -1, count: 2)
        timing.getControlPoint(at: 1, values: &first)
        timing.getControlPoint(at: 2, values: &second)
        XCTAssertEqual(first, [0, 0], "linear timing")
        XCTAssertEqual(second, [1, 1], "linear timing")
        XCTAssertLessThanOrEqual(rotation.beginTime, CACurrentMediaTime(), "phase starts on a past whole second, never in the future")
    }

    func testUpdatesTintChangesAndLayoutPassesKeepTheSameRotation() throws {
        let host = ArcHost()
        defer { host.close() }
        host.attach()
        let installed = try XCTUnwrap(host.currentRotation())
        XCTAssertTrue(installed === host.currentRotation(), "precondition: lookup returns the installed animation")

        for tint in [NSColor.systemRed, .systemBlue, .controlAccentColor, .systemBlue] {
            host.view.update(tint: tint)
        }
        host.view.needsLayout = true
        host.container.layoutSubtreeIfNeeded()
        host.view.setFrameSize(NSSize(width: Self.side + 2, height: Self.side + 2))
        host.container.layoutSubtreeIfNeeded()
        host.view.viewDidChangeEffectiveAppearance()

        XCTAssertEqual(host.view.arcLayer.animationKeys(), [AgentRowActivityArcLayerView.rotationAnimationKey])
        XCTAssertTrue(installed === host.currentRotation(), "updates must not replace the running rotation or reset its phase")
    }

    func testLeavingWindowRemovesRotationAndReattachingInstallsExactlyOne() throws {
        let host = ArcHost()
        defer { host.close() }
        host.attach()
        let first = try XCTUnwrap(host.currentRotation())

        host.view.removeFromSuperview()
        XCTAssertNil(host.view.arcLayer.animationKeys(), "the rotation must stop once the view leaves the window")
        host.view.update(tint: .systemRed)
        XCTAssertNil(host.view.arcLayer.animationKeys(), "updates off-window must not install a rotation")

        host.attach()
        XCTAssertEqual(host.view.arcLayer.animationKeys(), [AgentRowActivityArcLayerView.rotationAnimationKey])
        XCTAssertFalse(first === host.currentRotation(), "reattaching installs a fresh rotation")
    }

    func testTearDownRemovesRotation() {
        let host = ArcHost()
        defer { host.close() }
        host.attach()

        host.view.tearDown()

        XCTAssertNil(host.view.arcLayer.animationKeys())
    }

    func testViewPassesHitsThroughAndAddsNoAccessibilityElement() {
        let host = ArcHost()
        defer { host.close() }
        host.attach()

        XCTAssertNil(host.view.hitTest(NSPoint(x: Self.side / 2, y: Self.side / 2)))
        XCTAssertFalse(host.view.isAccessibilityElement())
    }

    func testShapeLayerGeometryMatchesTheSwiftUIArc() throws {
        let host = ArcHost()
        defer { host.close() }
        host.attach()
        let arc = host.view.arcLayer
        let window = try XCTUnwrap(host.view.window)

        XCTAssertTrue(arc.superlayer === host.view.layer, "the arc is a sublayer of AppKit's backing layer")
        XCTAssertEqual(host.view.layer?.sublayers?.count, 1)
        XCTAssertEqual(arc.strokeStart, 0)
        XCTAssertEqual(arc.strokeEnd, 0.7)
        XCTAssertEqual(arc.lineWidth, 1.5)
        XCTAssertEqual(arc.lineCap, .round)
        XCTAssertNil(arc.fillColor)
        XCTAssertEqual(arc.contentsScale, window.backingScaleFactor)
        XCTAssertEqual(arc.bounds, host.view.bounds)
        XCTAssertEqual(arc.position, CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY))
        XCTAssertEqual(arc.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        let pathBounds = try XCTUnwrap(arc.path).boundingBoxOfPath
        XCTAssertEqual(pathBounds.width, 15, accuracy: 0.01, "15pt circle, stroke kept inside bounds")
        XCTAssertEqual(pathBounds.midX, host.view.bounds.midX, accuracy: 0.01)
        XCTAssertEqual(pathBounds.midY, host.view.bounds.midY, accuracy: 0.01)
    }

    func testArcRendersInFlippedSpaceUnderFlippedAndUnflippedParents() {
        for parentIsFlipped in [true, false] {
            let host = ArcHost(parentIsFlipped: parentIsFlipped)
            defer { host.close() }
            host.attach()
            XCTAssertTrue(
                host.view.arcLayer.contentsAreFlipped(),
                "y-down rendering keeps the SwiftUI start angle and clockwise rotation (parent flipped: \(parentIsFlipped))"
            )
        }
    }

    func testTintChangeUpdatesStrokeColorAtThreeQuartersOpacity() throws {
        let host = ArcHost()
        defer { host.close() }
        host.attach()

        host.view.update(tint: .systemRed)
        let red = try XCTUnwrap(host.view.arcLayer.strokeColor)
        XCTAssertEqual(red, host.expectedStroke(.systemRed))
        XCTAssertEqual(red.alpha, 0.75, accuracy: 0.001)

        host.view.update(tint: .systemBlue)
        let blue = try XCTUnwrap(host.view.arcLayer.strokeColor)
        XCTAssertEqual(blue, host.expectedStroke(.systemBlue))
        XCTAssertNotEqual(red, blue)
    }
}

@MainActor
private final class ArcHost {
    let window: NSWindow
    let container: NSView
    let view = AgentRowActivityArcLayerView()

    init(parentIsFlipped: Bool = true) {
        let side = 15 + AgentRowActivityArcLayerView.lineWidth
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // NSHostingView is flipped; cover both parent orientations.
        container = parentIsFlipped ? FlippedContainerView() : NSView()
        container.wantsLayer = true
        window.contentView = container
        view.frame = NSRect(x: 8, y: 8, width: side, height: side)
    }

    func attach() {
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
    }

    func currentRotation() -> CAAnimation? {
        view.arcLayer.animation(forKey: AgentRowActivityArcLayerView.rotationAnimationKey)
    }

    func expectedStroke(_ color: NSColor) -> CGColor? {
        var resolved: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved.flatMap { $0.copy(alpha: $0.alpha * 0.75) }
    }

    func close() {
        view.tearDown()
        view.removeFromSuperview()
        window.close()
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool {
        true
    }
}
