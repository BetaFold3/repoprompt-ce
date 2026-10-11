import SwiftUI

// MARK: - Shared scaling helpers

///
/// The button styles below scale together so a button reads as a single unit at
/// every font preset: text grows, paddings/heights grow with it, and the corner
/// radius stays in proportion. We use `FontScalePreset.current` (the cached
/// preset) and never recreate it inside the makeBody hot path.
///
/// Helpers are namespaced under `ButtonScale` to avoid colliding with other
/// view-style utilities and to make the intent clear at call sites.
package enum ButtonScale {
    /// Scales a metric proportionally to the current font preset and clamps it
    /// so it never shrinks below the base value, and never exceeds
    /// `base * upper`. Defaults to 1.5x growth, which keeps Extra Large
    /// (~1.286x) within range without ever ballooning.
    package static func metric(_ base: CGFloat, upper: CGFloat = 1.5) -> CGFloat {
        guard base > 0 else { return 0 }
        let preset = FontScalePreset.current
        let scaled = preset.scaledMetric(base)
        let cap = base * upper
        return min(max(scaled, base), cap)
    }

    /// Convenience for the most common pill corner radius. Clamps so the radius
    /// remains visually proportional to the (scaled) pill height.
    package static func pillCornerRadius(_ base: CGFloat = 16) -> CGFloat {
        metric(base, upper: 1.35)
    }
}

/// Pill-style button used for most secondary controls.
///
/// IMPORTANT: `verticalPadding`, `horizontalPadding`, and `height` are
/// expected to be **Normal-preset baseline** values (un-scaled). The style
/// scales them internally via `ButtonScale.metric`, so passing pre-scaled
/// metrics (e.g. `fontPreset.scaledMetric(...)`) will double-scale at Large
/// and Extra Large and produce buttons that feel oversized relative to their
/// text.
package struct CustomButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var verticalPadding: CGFloat = 4
    var horizontalPadding: CGFloat = 8
    var height: CGFloat?
    var isPresetActive: Bool = false // New parameter for preset state

    let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
    let disabledColor = Color(nsColor: .controlBackgroundColor).opacity(0.25)
    let lineColor = Color(NSColor.systemGray)

    package init(
        verticalPadding: CGFloat = 4,
        horizontalPadding: CGFloat = 8,
        height: CGFloat? = nil,
        isPresetActive: Bool = false
    ) {
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.height = height
        self.isPresetActive = isPresetActive
    }

    package func makeBody(configuration: Configuration) -> some View {
        // Proportional scaling — heights, paddings, and corner radius all
        // follow the preset so the button reads as a single unit (text + chrome
        // + radius) at any font scale.
        let resolvedHeight = height.map { ButtonScale.metric($0) }
        let resolvedVerticalPadding = ButtonScale.metric(verticalPadding)
        let resolvedHorizontalPadding = ButtonScale.metric(horizontalPadding)
        let resolvedCornerRadius = ButtonScale.pillCornerRadius()
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.vertical, resolvedVerticalPadding)
                .padding(.horizontal, resolvedHorizontalPadding)
                .frame(height: resolvedHeight)
                .background(
                    Group {
                        if !isEnabled {
                            disabledBackground
                        } else if configuration.isPressed {
                            pressedBackground
                        } else if hovering {
                            hoverBackground
                        } else {
                            normalBackground
                        }
                    }
                )
                .foregroundColor(isEnabled ? foregroundColor : .gray)
                .cornerRadius(resolvedCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: resolvedCornerRadius)
                        .stroke(borderColorForState(isPressed: configuration.isPressed, isHovering: hovering), lineWidth: isPresetActive ? 1 : 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private var normalBackground: some View {
        Group {
            if isPresetActive {
                Color.blue.opacity(0.1)
            } else {
                Color.clear
            }
        }
    }

    private var hoverBackground: some View {
        Group {
            if isPresetActive {
                Color.blue.opacity(0.2)
            } else {
                backgroundColor
                    .overlay(
                        Color.primary.opacity(0.05)
                    )
            }
        }
    }

    private var pressedBackground: some View {
        backgroundColor
            .overlay(
                Color.primary.opacity(0.15)
            )
    }

    private var disabledBackground: some View {
        disabledColor
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private func borderColorForState(isPressed: Bool, isHovering: Bool) -> Color {
        if isPresetActive {
            Color.blue.opacity(0.3)
        } else if !isEnabled {
            lineColor.opacity(0.25)
        } else if isPressed {
            lineColor.opacity(0.5)
        } else if isHovering {
            lineColor
        } else {
            lineColor.opacity(0.75)
        }
    }
}

package struct HoverableButton<Content: View>: View {
    let configuration: ButtonStyle.Configuration
    let content: (Bool) -> Content
    @State private var isHovering = false

    package init(configuration: ButtonStyle.Configuration, content: @escaping (Bool) -> Content) {
        self.configuration = configuration
        self.content = content
    }

    package var body: some View {
        content(isHovering)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
    }
}

package struct SmallRoundButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var size: CGFloat
    var iconSize: CGFloat

    package init(size: CGFloat = 28, iconSize: CGFloat = 16) {
        self.size = size
        self.iconSize = iconSize
    }

    package func makeBody(configuration: Configuration) -> some View {
        // Round button frame and icon scale together so the icon never gets
        // cramped at Large/Extra Large nor swims at Normal.
        let resolvedSize = ButtonScale.metric(size)
        let resolvedIconSize = ButtonScale.metric(iconSize)
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .frame(width: resolvedSize, height: resolvedSize)
                .background(
                    Circle()
                        .fill(backgroundColor(configuration: configuration, hovering: hovering))
                )
                .foregroundColor(isEnabled ? .primary : .gray)
                .font(.system(size: resolvedIconSize, weight: .bold))
                .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private func backgroundColor(configuration: Configuration, hovering: Bool) -> Color {
        if !isEnabled {
            Color(nsColor: .controlBackgroundColor).opacity(0.5)
        } else if configuration.isPressed {
            Color.primary.opacity(0.15)
        } else if hovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear // Color(nsColor: .controlBackgroundColor)
        }
    }
}

struct SelectorButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let hasSelection: Bool

    init(hasSelection: Bool = false) {
        self.hasSelection = hasSelection
    }

    func makeBody(configuration: Configuration) -> some View {
        let cornerRadius = ButtonScale.pillCornerRadius()
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.vertical, ButtonScale.metric(4))
                .padding(.horizontal, ButtonScale.metric(8))
                .frame(minHeight: ButtonScale.metric(28))
                .background(backgroundColor(isPressed: configuration.isPressed, isHovering: hovering))
                .cornerRadius(cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor(isPressed: configuration.isPressed, isHovering: hovering), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private func backgroundColor(isPressed: Bool, isHovering: Bool) -> Color {
        let active = Color.blue
        let inactive = Color.secondary

        switch (hasSelection, isPressed, isHovering) {
        case (true, true, _):
            return active.opacity(0.25)
        case (true, false, true):
            return active.opacity(0.2)
        case (true, false, false):
            return active.opacity(0.1)
        case (false, true, _):
            return inactive.opacity(0.15)
        case (false, false, true):
            return inactive.opacity(0.1)
        default:
            return .clear
        }
    }

    private func borderColor(isPressed: Bool, isHovering: Bool) -> Color {
        if hasSelection {
            return Color.blue.opacity(0.3)
        }
        return Color.gray.opacity(0.3)
    }
}

/// Popover trigger style. Same scaling contract as `CustomButtonStyle`:
/// pass Normal-preset baseline values and let the style scale them.
struct PopoverButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var verticalPadding: CGFloat = 4
    var horizontalPadding: CGFloat = 8
    var height: CGFloat?

    let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
    let disabledColor = Color(nsColor: .controlBackgroundColor).opacity(0.25)

    func makeBody(configuration: Configuration) -> some View {
        // Mirrors CustomButtonStyle scaling so popover triggers feel the same
        // across the app at every font scale.
        let resolvedHeight = height.map { ButtonScale.metric($0) }
        let resolvedVerticalPadding = ButtonScale.metric(verticalPadding)
        let resolvedHorizontalPadding = ButtonScale.metric(horizontalPadding)
        let resolvedCornerRadius = ButtonScale.pillCornerRadius()
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .lineLimit(1)
                .padding(.vertical, resolvedVerticalPadding)
                .padding(.horizontal, resolvedHorizontalPadding)
                .frame(height: resolvedHeight)
                .background(backgroundForState(configuration: configuration, hovering: hovering))
                .foregroundColor(isEnabled ? foregroundColor : .gray)
                .cornerRadius(resolvedCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: resolvedCornerRadius)
                        .stroke(borderColorForState(isPressed: configuration.isPressed, isHovering: hovering), lineWidth: 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private func backgroundForState(configuration: Configuration, hovering: Bool) -> some View {
        Group {
            if !isEnabled {
                disabledBackground
            } else if configuration.isPressed {
                pressedBackground
            } else if hovering {
                hoverBackground
            } else {
                normalBackground
            }
        }
    }

    private var normalBackground: some View {
        Color.clear
    }

    private var hoverBackground: some View {
        backgroundColor
            .overlay(Color.primary.opacity(0.05))
    }

    private var pressedBackground: some View {
        backgroundColor
            .overlay(Color.primary.opacity(0.15))
    }

    private var disabledBackground: some View {
        disabledColor
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private func borderColorForState(isPressed: Bool, isHovering: Bool) -> Color {
        if !isEnabled {
            Color(NSColor.systemGray).opacity(0.25)
        } else if isPressed {
            Color(NSColor.systemGray).opacity(0.5)
        } else if isHovering {
            Color(NSColor.systemGray)
        } else {
            Color(NSColor.systemGray).opacity(0.75)
        }
    }
}

struct RoundedBorderButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var size: CGFloat
    var iconSize: CGFloat

    let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
    let lineColor = Color(NSColor.systemGray)

    init(size: CGFloat = 28, iconSize: CGFloat = 16) {
        self.size = size
        self.iconSize = iconSize
    }

    func makeBody(configuration: Configuration) -> some View {
        let resolvedSize = ButtonScale.metric(size)
        let resolvedIconSize = ButtonScale.metric(iconSize)
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .frame(width: resolvedSize, height: resolvedSize)
                .background(
                    backgroundForState(configuration: configuration, hovering: hovering)
                )
                .foregroundColor(isEnabled ? .primary : .gray)
                .font(.system(size: resolvedIconSize, weight: .bold))
                .overlay(
                    Circle()
                        .stroke(borderColorForState(isPressed: configuration.isPressed, isHovering: hovering), lineWidth: 0.5)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private func backgroundForState(configuration: Configuration, hovering: Bool) -> some View {
        Group {
            if !isEnabled {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.25))
            } else if configuration.isPressed {
                Circle()
                    .fill(backgroundColor)
                    .overlay(Circle().fill(Color.primary.opacity(0.15)))
            } else if hovering {
                Circle()
                    .fill(backgroundColor)
                    .overlay(Circle().fill(Color.primary.opacity(0.05)))
            } else {
                Circle()
                    .fill(Color.clear)
            }
        }
    }

    private func borderColorForState(isPressed: Bool, isHovering: Bool) -> Color {
        if !isEnabled {
            lineColor.opacity(0.25)
        } else if isPressed {
            lineColor.opacity(0.5)
        } else if isHovering {
            lineColor
        } else {
            Color.clear
        }
    }
}

// MARK: - Hover Effects

struct SimpleHoverEffect: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovering ? 1.0 : 0.8)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

package extension View {
    /// Adds a simple hover effect that changes opacity
    func hoverEffect() -> some View {
        modifier(SimpleHoverEffect())
    }
}
