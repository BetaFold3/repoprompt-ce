@testable import RepoPromptApp
import XCTest

/// Width arithmetic for the right utility panel.
///
/// These are the decisions a rendered panel cannot easily be asked about: whether it docks or
/// overlays at a given window width, how much room the transcript keeps, and how a drag on the
/// resize strip translates into a stored preference across font-scale presets.
final class AgentUtilityPanelLayoutMetricsTests: XCTestCase {
    private typealias Metrics = AgentUtilityPanelLayoutMetrics

    private let accuracy: CGFloat = 0.0001

    // MARK: - Dock vs overlay

    func testPanelDocksBesideTheTranscriptWhenTheColumnFitsBoth() {
        let metrics = Metrics(preset: .normal)

        let presentation = metrics.resolve(
            availableWidth: 1200,
            preferredWidth: 360,
            isVisible: true
        )

        guard case let .docked(panelWidth, transcriptWidth) = presentation else {
            return XCTFail("expected a docked presentation, got \(presentation)")
        }
        XCTAssertEqual(panelWidth, 360, accuracy: accuracy)
        XCTAssertEqual(transcriptWidth, 1200 - Metrics.dividerWidth - 360, accuracy: accuracy)
        XCTAssertEqual(presentation.panelWidth, panelWidth)
        XCTAssertTrue(presentation.isDocked)
        XCTAssertFalse(presentation.isOverlay)
        XCTAssertEqual(
            presentation.reservedGutterWidth,
            panelWidth + Metrics.dividerWidth,
            accuracy: accuracy
        )
    }

    func testPanelOverlaysWhenDockingCouldNotProtectTheTranscript() {
        let metrics = Metrics(preset: .normal)
        // 560 protected + 1 divider + 320 narrowest panel = 881; 880 is one point short.
        XCTAssertEqual(metrics.minimumDockableWidth, 881, accuracy: accuracy)

        let presentation = metrics.resolve(
            availableWidth: 880,
            preferredWidth: 360,
            isVisible: true
        )

        guard case let .overlay(panelWidth) = presentation else {
            return XCTFail("expected an overlay presentation, got \(presentation)")
        }
        XCTAssertEqual(panelWidth, 360, accuracy: accuracy)
        XCTAssertEqual(presentation.panelWidth, panelWidth)
        XCTAssertFalse(presentation.isDocked)
        XCTAssertTrue(presentation.isOverlay)
        XCTAssertEqual(presentation.reservedGutterWidth, 0, accuracy: accuracy)
    }

    /// A column that cannot afford the user's preferred width but can still afford a panel should
    /// dock a narrower one. Flipping to an overlay would hide transcript the window had room for.
    func testColumnThatCannotAffordThePreferredWidthDocksNarrowerRatherThanOverlaying() {
        let metrics = Metrics(preset: .normal)

        let presentation = metrics.resolve(
            availableWidth: 900,
            preferredWidth: Metrics.maximumPanelWidth,
            isVisible: true
        )

        guard case let .docked(panelWidth, transcriptWidth) = presentation else {
            return XCTFail("expected a docked presentation, got \(presentation)")
        }
        XCTAssertEqual(panelWidth, 900 - 560 - Metrics.dividerWidth, accuracy: accuracy)
        XCTAssertEqual(transcriptWidth, 560, accuracy: accuracy)
    }

    func testDockedTranscriptNeverDropsBelowItsProtectedWidth() {
        let metrics = Metrics(preset: .normal)
        let protectedWidth = metrics.scaledProtectedTranscriptWidth

        for availableWidth in stride(from: metrics.minimumDockableWidth, through: CGFloat(2000), by: 37) {
            for preferredWidth in [Metrics.minimumPanelWidth, 400, Metrics.maximumPanelWidth] {
                let presentation = metrics.resolve(
                    availableWidth: availableWidth,
                    preferredWidth: preferredWidth,
                    isVisible: true
                )
                guard case let .docked(_, transcriptWidth) = presentation else {
                    return XCTFail("expected docking at \(availableWidth)pt, got \(presentation)")
                }
                XCTAssertGreaterThanOrEqual(
                    transcriptWidth,
                    protectedWidth - accuracy,
                    "transcript compressed to \(transcriptWidth) at container \(availableWidth)"
                )
                XCTAssertEqual(
                    presentation.reservedGutterWidth + transcriptWidth,
                    availableWidth,
                    accuracy: accuracy,
                    "docked gutter and transcript did not partition \(availableWidth)pt"
                )
            }
        }
    }

    func testOverlayAlwaysLeavesASliverOfTranscriptVisible() {
        let metrics = Metrics(preset: .normal)

        let presentation = metrics.resolve(
            availableWidth: 300,
            preferredWidth: 360,
            isVisible: true
        )

        guard case let .overlay(panelWidth) = presentation else {
            return XCTFail("expected an overlay presentation, got \(presentation)")
        }
        XCTAssertEqual(panelWidth, 300 - Metrics.overlayPeekWidth, accuracy: accuracy)
    }

    // MARK: - Hidden

    func testHiddenPanelResolvesToHiddenAtEveryWidth() {
        let metrics = Metrics(preset: .normal)

        for availableWidth in [CGFloat(400), 900, 2400] {
            let presentation = metrics.resolve(
                availableWidth: availableWidth,
                preferredWidth: 360,
                isVisible: false
            )

            XCTAssertEqual(presentation, .hidden)
            XCTAssertNil(presentation.panelWidth)
            XCTAssertFalse(presentation.isDocked)
            XCTAssertFalse(presentation.isOverlay)
            XCTAssertEqual(presentation.reservedGutterWidth, 0, accuracy: accuracy)
        }
    }

    func testDegenerateContainerWidthsResolveToHiddenInsteadOfANegativeFrame() {
        let metrics = Metrics(preset: .normal)

        for availableWidth in [CGFloat(0), -120, .nan, .infinity] {
            XCTAssertEqual(
                metrics.resolve(availableWidth: availableWidth, preferredWidth: 360, isVisible: true),
                .hidden,
                "container width \(availableWidth) should not produce a panel"
            )
        }
    }

    // MARK: - Preference clamping

    func testPreferredWidthClampsIntoTheResizableRange() {
        XCTAssertEqual(Metrics.clampPreferredWidth(100), Metrics.minimumPanelWidth)
        XCTAssertEqual(Metrics.clampPreferredWidth(Metrics.minimumPanelWidth), Metrics.minimumPanelWidth)
        XCTAssertEqual(Metrics.clampPreferredWidth(440), 440)
        XCTAssertEqual(Metrics.clampPreferredWidth(Metrics.maximumPanelWidth), Metrics.maximumPanelWidth)
        XCTAssertEqual(Metrics.clampPreferredWidth(4000), Metrics.maximumPanelWidth)
    }

    func testNonFinitePreferredWidthFallsBackToTheDefaultWidth() {
        XCTAssertEqual(Metrics.clampPreferredWidth(.nan), Metrics.defaultPanelWidth)
        XCTAssertEqual(Metrics.clampPreferredWidth(.infinity), Metrics.defaultPanelWidth)
        XCTAssertEqual(Metrics.clampPreferredWidth(-.infinity), Metrics.defaultPanelWidth)
    }

    // MARK: - Font scaling

    func testLargerFontPresetsScaleBothTheProtectedTranscriptAndThePanel() {
        let normal = Metrics(preset: .normal)
        let extraLarge = Metrics(preset: .extraLarge)
        let scaleFactor = FontScalePreset.extraLarge.scaleFactor

        XCTAssertEqual(
            extraLarge.scaledProtectedTranscriptWidth,
            normal.scaledProtectedTranscriptWidth * scaleFactor,
            accuracy: accuracy
        )
        XCTAssertEqual(
            extraLarge.effectivePanelWidth(forPreferredWidth: 360),
            360 * scaleFactor,
            accuracy: accuracy
        )
        XCTAssertGreaterThan(extraLarge.minimumDockableWidth, normal.minimumDockableWidth)
    }

    func testAColumnThatDocksAtNormalCanOverlayAtExtraLarge() {
        let availableWidth: CGFloat = 1000

        XCTAssertEqual(
            Metrics(preset: .normal).resolve(
                availableWidth: availableWidth,
                preferredWidth: 360,
                isVisible: true
            ),
            .docked(panelWidth: 360, transcriptWidth: availableWidth - Metrics.dividerWidth - 360)
        )

        let scaled = Metrics(preset: .extraLarge).resolve(
            availableWidth: availableWidth,
            preferredWidth: 360,
            isVisible: true
        )
        guard case .overlay = scaled else {
            return XCTFail("expected an overlay at the extra-large preset, got \(scaled)")
        }
    }

    /// At the app's 948pt minimum window, the sessions sidebar is still present. Even using the
    /// largest possible remaining detail width (subtracting only the sidebar minimum), every font
    /// preset must overlay rather than dock, and the panel must keep its scaled 320pt usable width.
    func testMinimumWindowOverlaysAtEveryFontPresetAndKeepsTheMinimumPanelUsable() {
        let minimumWindowWidth: CGFloat = 948

        for preset in FontScalePreset.allCases {
            let metrics = Metrics(preset: preset)
            let maximumDetailWidth = minimumWindowWidth - AgentSidebarSizing.minWidth(for: preset)
            XCTAssertLessThan(
                maximumDetailWidth,
                metrics.minimumDockableWidth,
                "\(preset.displayName) unexpectedly had room to dock at the minimum window width"
            )

            let presentation = metrics.resolve(
                availableWidth: maximumDetailWidth,
                preferredWidth: Metrics.minimumPanelWidth,
                isVisible: true
            )
            guard case let .overlay(panelWidth) = presentation else {
                return XCTFail("expected a minimum-window overlay for \(preset.displayName), got \(presentation)")
            }
            XCTAssertEqual(panelWidth, metrics.scaledMinimumPanelWidth, accuracy: accuracy)
            XCTAssertGreaterThanOrEqual(panelWidth, Metrics.minimumPanelWidth)
        }
    }

    // MARK: - Split diff gate

    func testSplitDiffRequiresAtLeast560PointsOfEffectiveWidth() {
        XCTAssertFalse(Metrics.supportsSplitDiff(effectiveDiffWidth: 559.999))
        XCTAssertTrue(Metrics.supportsSplitDiff(effectiveDiffWidth: 560))
        XCTAssertTrue(Metrics.supportsSplitDiff(effectiveDiffWidth: 720))
    }

    func testSplitDiffRejectsNonFiniteEffectiveWidths() {
        XCTAssertFalse(Metrics.supportsSplitDiff(effectiveDiffWidth: .nan))
        XCTAssertFalse(Metrics.supportsSplitDiff(effectiveDiffWidth: .infinity))
    }

    // MARK: - Drag arithmetic

    func testDraggingTheStripLeftWidensThePanelAndRightNarrowsIt() {
        let metrics = Metrics(preset: .normal)

        XCTAssertEqual(
            metrics.preferredWidth(draggingFrom: 360, translation: -60),
            420,
            accuracy: accuracy
        )
        XCTAssertEqual(
            metrics.preferredWidth(draggingFrom: 360, translation: 30),
            330,
            accuracy: accuracy
        )
    }

    func testDragsPastTheRangeStopAtTheMinimumAndMaximumWidths() {
        let metrics = Metrics(preset: .normal)

        XCTAssertEqual(
            metrics.preferredWidth(draggingFrom: 360, translation: 500),
            Metrics.minimumPanelWidth,
            accuracy: accuracy
        )
        XCTAssertEqual(
            metrics.preferredWidth(draggingFrom: 360, translation: -500),
            Metrics.maximumPanelWidth,
            accuracy: accuracy
        )
    }

    /// The gesture reports on-screen points but the preference is stored unscaled, so the same
    /// physical drag must record a smaller preference change at a larger preset.
    func testDragTranslationIsRecordedInUnscaledPoints() {
        let metrics = Metrics(preset: .extraLarge)
        let scaleFactor = FontScalePreset.extraLarge.scaleFactor

        let resolved = metrics.preferredWidth(draggingFrom: 360, translation: -90)

        XCTAssertEqual(resolved, 360 + 90 / scaleFactor, accuracy: accuracy)
        XCTAssertLessThan(resolved, 360 + 90)
    }

    func testNonFiniteDragTranslationLeavesTheWidthUnchanged() {
        let metrics = Metrics(preset: .normal)

        XCTAssertEqual(metrics.preferredWidth(draggingFrom: 420, translation: .nan), 420)
        XCTAssertEqual(metrics.preferredWidth(draggingFrom: 420, translation: .infinity), 420)
    }
}
