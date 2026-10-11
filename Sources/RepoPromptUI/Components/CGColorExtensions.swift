//
//  CGColorExtensions.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-04.
//

import AppKit

/// CGColor helper matching `NSColor.hoverOutlineColor` but returned
/// directly as a Core Graphics colour so callers can assign it straight
/// to `CALayer.borderColor` without the extra conversion.
///
/// • Light  → dark grey  (15 % white, 65 % α)
/// • Dark   → light grey (100 % white, 20 % α)
extension CGColor {
    static func hoverOutline(for appearance: NSAppearance) -> CGColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            // Light grey with lower opacity for dark mode
            return NSColor(white: 1.0, alpha: 0.20).cgColor
        } else {
            // Much darker grey, closer to primary text colour
            return NSColor(white: 0.15, alpha: 0.65).cgColor
        }
    }

    static var hoverOutline: CGColor {
        hoverOutline(for: NSApp.effectiveAppearance)
    }
}
