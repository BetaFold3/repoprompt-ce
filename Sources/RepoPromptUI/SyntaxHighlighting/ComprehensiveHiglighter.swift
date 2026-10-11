//
//  ComprehensiveHiglighter.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//

import AppKit
import Neon

/// A simple struct to hold the text attributes for a token in dark and light modes.
struct TokenStyle {
    let darkModeAttributes: [NSAttributedString.Key: Any]
    let lightModeAttributes: [NSAttributedString.Key: Any]
}

/// A comprehensive syntax highlighter that applies attribute styles
/// based on the token’s primary or sub token types (e.g. "keyword", "keyword.function", etc.).
/// It uses a base mapping for known types and subtypes, and falls back
/// to default text styles for unknown tokens.
final class ComprehensiveHighlighter {
    static let shared = ComprehensiveHighlighter()
    private init() {}

    // MARK: - Master Style Mapping

    /// You can expand or tweak these entries to match your theme.
    /// The keys here represent the base token type (e.g. "keyword", "string", "comment").
    private let styleMapping: [String: TokenStyle] = [
        // --- Basic Code Categories ---

        "attribute": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#4EC9B0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#e50000")!]
        ),
        "boolean": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#B5CEA8")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#098658")!]
        ),
        "comment": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#6A9955")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#008000")!]
        ),
        "comment.documentation": TokenStyle(
            // doc comments might be the same color or slightly lighter
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#6A9955")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#008000")!]
        ),
        "constant": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#AE81FF")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0451A5")!]
        ),
        "constant.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#AE81FF")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0451A5")!]
        ),
        "constructor": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#DCDCAA")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000080")!]
        ),
        "constructor.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#DCDCAA")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000080")!]
        ),
        "error": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#FF3333")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#CC0000")!]
        ),
        "escape": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#D7BA7D")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#859900")!]
        ),
        "function": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#DCDCAA")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000080")!]
        ),
        "function.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#DCDCAA")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000080")!]
        ),
        "keyword": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#569CD6")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0000FF")!]
        ),
        "markup": TokenStyle(
            // For general prose in markup, we often use default text color
            darkModeAttributes: [:],
            lightModeAttributes: [:]
        ),
        // Example markup subtypes
        "markup.heading": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#F92672")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#800000")!]
        ),
        "markup.link": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#4FC1FF")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0000EE")!]
        ),
        "markup.link.url": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#2AA198")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0451A5")!]
        ),
        "number": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#B5CEA8")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#098658")!]
        ),
        "operator": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#C586C0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        "property": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#9CDCFE")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        "property.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#9CDCFE")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        // Basic punctuation might just be a mild gray in dark or near-black in light
        "punctuation": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CCCCCC")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#333333")!]
        ),
        "punctuation.bracket": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CCCCCC")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#333333")!]
        ),
        "punctuation.delimiter": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CCCCCC")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#333333")!]
        ),
        "punctuation.special": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CCCCCC")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#333333")!]
        ),
        "string": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CE9178")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#A31515")!]
        ),
        "string.escape": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#FFD700")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#857B00")!]
        ),
        "string.regexp": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#D33682")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#811F3F")!]
        ),
        "string.special": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#CE9178")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#A31515")!]
        ),
        "string.special.symbol": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#B5CEA8")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#098658")!]
        ),
        "tag": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#F92672")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#800000")!]
        ),
        "type": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#4EC9B0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#2B91AF")!]
        ),
        "type.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#4EC9B0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#2B91AF")!]
        ),
        "variable": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#9CDCFE")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        "variable.builtin": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#569CD6")!], // e.g. treat 'this', 'self' like keywords
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#0000FF")!]
        ),
        "variable.member": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#9CDCFE")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        "variable.parameter": TokenStyle(
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#9CDCFE")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#000000")!]
        ),
        "type.alias": TokenStyle( // NEW – colour like regular types
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#4EC9B0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#2B91AF")!]
        ),
        "import.facade": TokenStyle( // Optional Laravel facades
            darkModeAttributes: [.foregroundColor: NSColor(hex: "#C586C0")!],
            lightModeAttributes: [.foregroundColor: NSColor(hex: "#795E26")!]
        )
    ]

    // MARK: - Token Attribute Lookup

    /// Returns the text attributes for a given Neon `Token` based on its
    /// base type and the current system appearance (dark vs light).
    func attributes(for token: Token) -> [NSAttributedString.Key: Any] {
        // Break down the token name by '.' (e.g., "keyword.function" -> ["keyword","function"])
        let parts = token.name.split(separator: ".").map { String($0) }

        // Try to match from largest sub-path to smallest, for example:
        //   "keyword.function.builtin" -> check "keyword.function.builtin"
        //                                  then "keyword.function"
        //                                  then "keyword"
        // This ensures the most specific style is applied first if it exists.
        for i in (1 ... parts.count).reversed() {
            let partialKey = parts.prefix(i).joined(separator: ".")
            if let style = styleMapping[partialKey] {
                return attributesFromStyle(style)
            }
        }

        // If no matching style is found, fallback
        return defaultAttributes()
    }

    // MARK: - Helpers

    /// Convert a `TokenStyle` to actual NSAttributedString attributes,
    /// picking based on dark or light appearance.
    private func attributesFromStyle(_ style: TokenStyle) -> [NSAttributedString.Key: Any] {
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Provide a default font if not specified
        let baseFont = FontScalePreset.current.monospacedNSFont(sizeAtNormal: 12)

        let dict = isDark ? style.darkModeAttributes : style.lightModeAttributes

        // Insert a default font if none is present in the style.
        // Here, 'dict' is non-optional so we use direct subscripting.
        var result = dict
        if result[.font] == nil {
            result[.font] = baseFont
        }
        return result
    }

    /// Fallback attributes if a token type is unknown or not in the map.
    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return [
            .foregroundColor: isDark ? NSColor.white : NSColor.black,
            .font: FontScalePreset.current.monospacedNSFont(sizeAtNormal: 12)
        ]
    }
}

// MARK: - NSColor+Hex Helper

extension NSColor {
    /// Initializes an NSColor from a hex string, e.g. "#569CD6".
    convenience init?(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        guard hexString.count == 6, let intVal = Int(hexString, radix: 16) else {
            return nil
        }
        let r = CGFloat((intVal >> 16) & 0xFF) / 255.0
        let g = CGFloat((intVal >> 8) & 0xFF) / 255.0
        let b = CGFloat(intVal & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
