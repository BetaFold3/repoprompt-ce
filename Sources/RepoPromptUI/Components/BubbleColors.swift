import AppKit
import SwiftUI

// MARK: - Adaptive Color Functions for Chat Bubbles

/// Provides adaptive colors for chat bubbles and related UI elements.
/// All colors adapt to light/dark mode automatically.
package enum BubbleColors {
    /// Helper to determine if we're in dark mode using NSApp.appearance
    static func isDarkMode() -> Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Helper for SwiftUI ColorScheme-based dark mode detection
    static func isDarkMode(colorScheme: ColorScheme?) -> Bool {
        if let scheme = colorScheme {
            return scheme == .dark
        }
        return isDarkMode()
    }

    // MARK: - Background Colors

    static func userBubbleBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.15, green: 0.25, blue: 0.35) :
            Color(red: 0.85, green: 0.9, blue: 0.95)
    }

    package static var userBubbleBackground: Color {
        userBubbleBackground(colorScheme: nil)
    }

    static func assistantBubbleBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.25, green: 0.25, blue: 0.27) :
            Color(red: 0.9, green: 0.9, blue: 0.9)
    }

    package static var assistantBubbleBackground: Color {
        assistantBubbleBackground(colorScheme: nil)
    }

    // MARK: - Accent Colors

    package static func lightBlue(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.2, green: 0.3, blue: 0.4) :
            Color(red: 0.9, green: 0.95, blue: 1.0)
    }

    package static var lightBlue: Color {
        lightBlue(colorScheme: nil)
    }

    static func mediumBlue(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.3, green: 0.4, blue: 0.5) :
            Color(red: 0.8, green: 0.9, blue: 1.0)
    }

    package static var mediumBlue: Color {
        mediumBlue(colorScheme: nil)
    }

    static func borderBlue(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.4, green: 0.5, blue: 0.6) :
            Color(red: 0.7, green: 0.8, blue: 0.9)
    }

    package static var borderBlue: Color {
        borderBlue(colorScheme: nil)
    }

    // MARK: - Button & Icon Colors

    static func deleteIconNormal(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ? Color(white: 0.7) : .secondary
    }

    package static var deleteIconNormal: Color {
        deleteIconNormal(colorScheme: nil)
    }

    static func deleteIconHover(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 1.0, green: 0.35, blue: 0.35) :
            Color(red: 0.75, green: 0.15, blue: 0.15)
    }

    package static var deleteIconHover: Color {
        deleteIconHover(colorScheme: nil)
    }

    static func copyIconNormal(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ? Color(white: 0.7) : .secondary
    }

    package static var copyIconNormal: Color {
        copyIconNormal(colorScheme: nil)
    }

    static func copyIconHover(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 1.0, green: 1.0, blue: 1.0) :
            Color(red: 0.2, green: 0.2, blue: 0.2)
    }

    package static var copyIconHover: Color {
        copyIconHover(colorScheme: nil)
    }

    /// High contrast version for better visibility on hover
    static func highContrastCopyIconHover(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.4, green: 0.8, blue: 1.0) :
            Color(red: 0.0, green: 0.4, blue: 0.8)
    }

    package static var highContrastCopyIconHover: Color {
        highContrastCopyIconHover(colorScheme: nil)
    }

    // MARK: - Section Colors

    static func codeBlockBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.15, green: 0.15, blue: 0.16) :
            Color(red: 0.97, green: 0.97, blue: 0.97)
    }

    package static var codeBlockBackground: Color {
        codeBlockBackground(colorScheme: nil)
    }

    static func fileChangeBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.18, green: 0.18, blue: 0.2) :
            Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    static var fileChangeBackground: Color {
        fileChangeBackground(colorScheme: nil)
    }

    package static func errorBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.35, green: 0.15, blue: 0.15) :
            Color(red: 0.95, green: 0.85, blue: 0.85)
    }

    package static var errorBackground: Color {
        errorBackground(colorScheme: nil)
    }

    static func warningYellowBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.35, green: 0.32, blue: 0.18) :
            Color(red: 1.0, green: 0.92, blue: 0.75)
    }

    static var warningYellowBackground: Color {
        warningYellowBackground(colorScheme: nil)
    }

    static func warningYellowBorder(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.55, green: 0.48, blue: 0.28) :
            Color(red: 0.9, green: 0.7, blue: 0.2)
    }

    static var warningYellowBorder: Color {
        warningYellowBorder(colorScheme: nil)
    }

    // MARK: - Status Colors

    package static func errorRed(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 1.0, green: 0.35, blue: 0.35) :
            Color(red: 0.7, green: 0.1, blue: 0.1)
    }

    package static var errorRed: Color {
        errorRed(colorScheme: nil)
    }

    package static func successGreen(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.4, green: 0.8, blue: 0.4) :
            Color(red: 0.2, green: 0.7, blue: 0.2)
    }

    package static var successGreen: Color {
        successGreen(colorScheme: nil)
    }

    package static func warningYellow(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 1.0, green: 0.85, blue: 0.3) :
            Color(red: 0.85, green: 0.6, blue: 0.0)
    }

    static var warningYellow: Color {
        warningYellow(colorScheme: nil)
    }

    static func neutralGray(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.6, green: 0.6, blue: 0.6) :
            Color(red: 0.5, green: 0.5, blue: 0.5)
    }

    package static var neutralGray: Color {
        neutralGray(colorScheme: nil)
    }

    // MARK: - Tool Accent Colors

    static func toolNavigationAccent(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme)
            ? Color(red: 0.42, green: 0.66, blue: 1.0)
            : Color(red: 0.14, green: 0.4, blue: 0.88)
    }

    package static var toolNavigationAccent: Color {
        toolNavigationAccent(colorScheme: nil)
    }

    static func toolEditAccent(colorScheme: ColorScheme? = nil) -> Color {
        successGreen(colorScheme: colorScheme)
    }

    package static var toolEditAccent: Color {
        toolEditAccent(colorScheme: nil)
    }

    static func toolExecutionAccent(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme)
            ? Color(red: 0.63, green: 0.61, blue: 1.0)
            : Color(red: 0.33, green: 0.29, blue: 0.82)
    }

    package static var toolExecutionAccent: Color {
        toolExecutionAccent(colorScheme: nil)
    }

    static func toolCommunicationAccent(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme)
            ? Color(red: 0.82, green: 0.63, blue: 1.0)
            : Color(red: 0.54, green: 0.28, blue: 0.82)
    }

    package static var toolCommunicationAccent: Color {
        toolCommunicationAccent(colorScheme: nil)
    }

    static func toolConfigAccent(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme)
            ? Color(red: 0.4, green: 0.86, blue: 0.82)
            : Color(red: 0.0, green: 0.55, blue: 0.56)
    }

    package static var toolConfigAccent: Color {
        toolConfigAccent(colorScheme: nil)
    }

    static func toolOtherAccent(colorScheme: ColorScheme? = nil) -> Color {
        neutralGray(colorScheme: colorScheme)
    }

    package static var toolOtherAccent: Color {
        toolOtherAccent(colorScheme: nil)
    }

    // MARK: - Tool/Agent Specific Colors

    package static func toolCallBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.2, green: 0.22, blue: 0.25) :
            Color(red: 0.95, green: 0.95, blue: 0.97)
    }

    static var toolCallBackground: Color {
        toolCallBackground(colorScheme: nil)
    }

    package static func toolResultBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.18, green: 0.2, blue: 0.22) :
            Color(red: 0.96, green: 0.97, blue: 0.98)
    }

    package static var toolResultBackground: Color {
        toolResultBackground(colorScheme: nil)
    }

    static func systemMessageBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.22, green: 0.22, blue: 0.24) :
            Color(red: 0.94, green: 0.94, blue: 0.96)
    }

    static var systemMessageBackground: Color {
        systemMessageBackground(colorScheme: nil)
    }

    /// Subtle background for thinking/reasoning trace bubbles.
    /// Intentionally muted to feel secondary while still giving the text a grounding surface.
    package static func thinkingBubbleBackground(colorScheme: ColorScheme? = nil) -> Color {
        isDarkMode(colorScheme: colorScheme) ?
            Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.6) :
            Color(red: 0.94, green: 0.94, blue: 0.95).opacity(0.6)
    }

    static var thinkingBubbleBackground: Color {
        thinkingBubbleBackground(colorScheme: nil)
    }
}
