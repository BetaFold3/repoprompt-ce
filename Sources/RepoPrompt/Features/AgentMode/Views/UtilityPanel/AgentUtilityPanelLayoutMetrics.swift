import SwiftUI

/// Pure width arithmetic for the right-side utility panel.
///
/// The panel docks beside the transcript only while the transcript keeps its protected reading
/// width; below that the panel presents as a trailing overlay instead of squeezing the transcript.
/// All of that is decided here rather than inside the view so the thresholds can be unit-tested
/// without a rendered hierarchy.
///
/// Widths cross two coordinate systems and the distinction matters:
/// - *unscaled* widths are the user's stored preference, expressed at the `.normal` font preset.
/// - *effective* widths are unscaled widths multiplied by the active preset's scale factor, and are
///   what actually gets laid out on screen.
struct AgentUtilityPanelLayoutMetrics: Equatable {
    // MARK: - Named constants

    /// Narrowest useful panel: matches the runtime sidebar's `minWidth` idiom.
    static let minimumPanelWidth: CGFloat = 320
    /// Widest docked panel before the transcript starts losing more than it gains.
    static let maximumPanelWidth: CGFloat = 560
    /// Width a fresh window opens at, and the width a double-click on the drag strip restores.
    static let defaultPanelWidth: CGFloat = 360
    /// Reading width reserved for the transcript, shared with the sessions-sidebar clamp so both
    /// columns protect the same detail area.
    static let protectedTranscriptWidth: CGFloat = AgentSidebarSizing.minimumDetailWidth
    /// Hairline separating transcript from a docked panel.
    static let dividerWidth: CGFloat = 1
    /// Hit width of the drag strip on the panel's leading edge.
    static let resizeStripWidth: CGFloat = 8
    /// Transcript kept visible beside an overlay panel so the underlying context never disappears.
    static let overlayPeekWidth: CGFloat = 48
    /// Minimum actual diff width at which two readable code columns fit.
    static let splitDiffMinimumEffectiveWidth: CGFloat = 560

    /// How the panel should present for a given container width.
    enum Presentation: Equatable {
        /// Panel is not shown; the transcript owns the whole detail column.
        case hidden
        /// Panel sits beside the transcript, which keeps at least its protected width.
        case docked(panelWidth: CGFloat, transcriptWidth: CGFloat)
        /// Panel floats over the trailing edge of the transcript on a material background.
        case overlay(panelWidth: CGFloat)

        var panelWidth: CGFloat? {
            switch self {
            case .hidden:
                nil
            case let .docked(panelWidth, _), let .overlay(panelWidth):
                panelWidth
            }
        }

        var isDocked: Bool {
            if case .docked = self {
                return true
            }
            return false
        }

        var isOverlay: Bool {
            if case .overlay = self {
                return true
            }
            return false
        }

        var reservedGutterWidth: CGFloat {
            guard case let .docked(panelWidth, _) = self else { return 0 }
            return panelWidth + AgentUtilityPanelLayoutMetrics.dividerWidth
        }
    }

    let preset: FontScalePreset

    init(preset: FontScalePreset = .current) {
        self.preset = preset
    }

    // MARK: - Preference clamping

    /// Clamps a stored (unscaled) preference into the resizable range.
    ///
    /// Non-finite values collapse to the default so a corrupted settings document can never
    /// produce a `NaN` frame.
    static func clampPreferredWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultPanelWidth }
        return min(max(width, minimumPanelWidth), maximumPanelWidth)
    }

    // MARK: - Scaled metrics

    /// The transcript's protected width at the active font preset.
    var scaledProtectedTranscriptWidth: CGFloat {
        preset.scaledMetric(Self.protectedTranscriptWidth)
    }

    /// Narrowest panel the layout will dock, at the active font preset.
    var scaledMinimumPanelWidth: CGFloat {
        preset.scaledMetric(Self.minimumPanelWidth)
    }

    /// Widest panel the layout will dock, at the active font preset.
    var scaledMaximumPanelWidth: CGFloat {
        preset.scaledMetric(Self.maximumPanelWidth)
    }

    /// Converts a stored preference into the width that is actually laid out.
    func effectivePanelWidth(forPreferredWidth preferredWidth: CGFloat) -> CGFloat {
        preset.scaledMetric(Self.clampPreferredWidth(preferredWidth))
    }

    /// Smallest container that can dock a panel at all: protected transcript, divider, and the
    /// narrowest panel.
    var minimumDockableWidth: CGFloat {
        scaledProtectedTranscriptWidth + Self.dividerWidth + scaledMinimumPanelWidth
    }

    // MARK: - Diff mode gate

    static func supportsSplitDiff(effectiveDiffWidth: CGFloat) -> Bool {
        effectiveDiffWidth.isFinite
            && effectiveDiffWidth >= splitDiffMinimumEffectiveWidth
    }

    // MARK: - Resolution

    /// Chooses dock, overlay, or hidden for a container width.
    ///
    /// When the container can dock the narrowest panel but not the user's preferred width, the
    /// panel docks at the widest width that still protects the transcript rather than flipping to
    /// an overlay — an overlay that hides content the window had room to show would be a
    /// regression, and the transcript's protected width is what the decision record actually
    /// guarantees.
    func resolve(
        availableWidth: CGFloat,
        preferredWidth: CGFloat,
        isVisible: Bool
    ) -> Presentation {
        guard isVisible else { return .hidden }
        guard availableWidth.isFinite, availableWidth > 0 else { return .hidden }

        let desiredWidth = effectivePanelWidth(forPreferredWidth: preferredWidth)

        if availableWidth >= minimumDockableWidth {
            let widthAvailableToPanel = availableWidth - scaledProtectedTranscriptWidth - Self.dividerWidth
            let dockedWidth = min(desiredWidth, widthAvailableToPanel)
            return .docked(
                panelWidth: dockedWidth,
                transcriptWidth: availableWidth - Self.dividerWidth - dockedWidth
            )
        }

        // Too narrow to dock: overlay, but always leave a sliver of transcript visible.
        let overlayWidth = min(desiredWidth, max(availableWidth - Self.overlayPeekWidth, 0))
        return .overlay(panelWidth: overlayWidth)
    }

    // MARK: - Drag arithmetic

    /// Resolves a drag on the panel's leading edge into a new stored preference.
    ///
    /// The gesture translation arrives in on-screen (effective) points, so it is divided back out
    /// by the preset's scale factor before being clamped and stored. Dragging the leading edge
    /// left (negative `translation`) widens the panel.
    func preferredWidth(
        draggingFrom startingPreferredWidth: CGFloat,
        translation: CGFloat
    ) -> CGFloat {
        guard translation.isFinite else {
            return Self.clampPreferredWidth(startingPreferredWidth)
        }
        let scaleFactor = preset.scaleFactor
        guard scaleFactor > 0 else {
            return Self.clampPreferredWidth(startingPreferredWidth)
        }
        let startingEffectiveWidth = effectivePanelWidth(forPreferredWidth: startingPreferredWidth)
        let proposedEffectiveWidth = startingEffectiveWidth - translation
        return Self.clampPreferredWidth(proposedEffectiveWidth / scaleFactor)
    }
}
