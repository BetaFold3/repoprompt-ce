import RepoPromptUI
import SwiftUI

enum AppSidebarSizing {
    static let minWidth: CGFloat = 325
    static let idealWidth: CGFloat = 364
    static let maxWidth: CGFloat = 425
}

enum AgentSidebarSizing {
    static let minWidth: CGFloat = 300
    static let idealWidth: CGFloat = 340
    static let maxWidth: CGFloat = 425
    static let minimumDetailWidth: CGFloat = 560

    static func minWidth(for preset: FontScalePreset) -> CGFloat {
        preset.scaledClamped(minWidth, max: 390)
    }

    static func idealWidth(for preset: FontScalePreset) -> CGFloat {
        max(minWidth(for: preset), preset.scaledClamped(idealWidth, max: 460))
    }

    static func maxWidth(for preset: FontScalePreset) -> CGFloat {
        max(idealWidth(for: preset), preset.scaledClamped(maxWidth, max: 560))
    }

    static func resolvedMaxWidth(for containerWidth: CGFloat, preset: FontScalePreset) -> CGFloat {
        let scaledMinWidth = minWidth(for: preset)
        let clampedWidth = max(scaledMinWidth, containerWidth - minimumDetailWidth)
        return min(maxWidth(for: preset), clampedWidth)
    }

    static func resolvedIdealWidth(for containerWidth: CGFloat, preset: FontScalePreset) -> CGFloat {
        min(idealWidth(for: preset), resolvedMaxWidth(for: containerWidth, preset: preset))
    }

    static func resolvedMaxWidth(for containerWidth: CGFloat) -> CGFloat {
        resolvedMaxWidth(for: containerWidth, preset: FontScalePreset.current)
    }

    static func resolvedIdealWidth(for containerWidth: CGFloat) -> CGFloat {
        resolvedIdealWidth(for: containerWidth, preset: FontScalePreset.current)
    }
}
