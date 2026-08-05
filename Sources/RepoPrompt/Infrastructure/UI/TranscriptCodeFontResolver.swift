import AppKit
import Foundation

/// Resolves the effective monospaced face used by transcript code/diff rendering.
///
/// Preference is an optional PostScript name from `UISettings` (`nil` = system monospaced).
/// Missing, uninstalled, or non-fixed-pitch faces fall back silently so caches and layout
/// always see a validated fixed-pitch font plus stable line-height / tab metrics.
enum TranscriptCodeFontResolver {
    /// Sentinel stored / shown for "System Monospaced" in pickers.
    static let systemMonospacedPreferenceValue = ""

    struct FaceOption: Hashable, Equatable, Identifiable {
        /// PostScript / AppKit `fontName` used as the persisted preference value.
        let postScriptName: String
        /// Human-readable label (family + face when available).
        let displayName: String

        var id: String {
            postScriptName
        }
    }

    struct Resolved: Equatable {
        /// Validated fixed-pitch font at the requested point size.
        let font: NSFont
        /// Cache / render-signature identity for the resolved face.
        let fingerprint: TranscriptCodeFontFingerprint
        /// True when the preferred face was nil/invalid and system monospaced was used.
        let didFallBack: Bool
        /// Pinned line height (`ceil(ascender - descender + leading)`).
        let minimumLineHeight: CGFloat
        /// Explicit tab interval (4× advance width of a space in the resolved face).
        let tabInterval: CGFloat

        /// Paragraph style with pinned line height and explicit tab stops for code/diff layout.
        func makeCodeParagraphStyle(
            lineSpacing: CGFloat = 0,
            lineBreakMode: NSLineBreakMode = .byWordWrapping
        ) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.minimumLineHeight = minimumLineHeight
            style.maximumLineHeight = minimumLineHeight
            style.lineBreakMode = lineBreakMode
            style.defaultTabInterval = tabInterval
            // Explicit stops keep tab advance stable across faces that disagree on AppKit defaults.
            style.tabStops = (1 ... 12).map { index in
                NSTextTab(textAlignment: .left, location: tabInterval * CGFloat(index), options: [:])
            }
            return style
        }
    }

    /// Resolve `preferredPostScriptName` (nil/empty = system monospaced) at `pointSize`.
    static func resolve(
        preferredPostScriptName: String?,
        pointSize: CGFloat
    ) -> Resolved {
        let size = max(pointSize, 1)
        let trimmed = preferredPostScriptName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty,
           let candidate = validatedFixedPitchFont(named: trimmed, size: size)
        {
            return makeResolved(font: candidate, didFallBack: false)
        }
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return makeResolved(font: system, didFallBack: trimmed?.isEmpty == false)
    }

    /// Convenience: resolve using the live UI preference + point size.
    @MainActor
    static func resolveFromSettings(pointSize: CGFloat) -> Resolved {
        resolve(
            preferredPostScriptName: GlobalSettingsStore.shared.transcriptCodeFontPostScriptName(),
            pointSize: pointSize
        )
    }

    /// Whether `postScriptName` names an installed fixed-pitch face.
    static func isValidFixedPitchFace(_ postScriptName: String) -> Bool {
        let trimmed = postScriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return validatedFixedPitchFont(named: trimmed, size: 12) != nil
    }

    /// Curated fixed-pitch faces for the Appearance picker / MCP options (no NSFontPanel).
    static func availableFixedPitchFaces() -> [FaceOption] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var options: [FaceOption] = []
        options.reserveCapacity(names.count)
        var seen = Set<String>()
        for name in names {
            guard !name.hasPrefix("."), !seen.contains(name) else { continue }
            guard let font = validatedFixedPitchFont(named: name, size: 12) else { continue }
            seen.insert(name)
            let display = font.displayName ?? font.familyName ?? name
            options.append(FaceOption(postScriptName: name, displayName: display))
        }
        return options.sorted { lhs, rhs in
            let displayOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return lhs.postScriptName.localizedStandardCompare(rhs.postScriptName) == .orderedAscending
        }
    }

    // MARK: - Private

    private static func validatedFixedPitchFont(named postScriptName: String, size: CGFloat) -> NSFont? {
        guard let font = NSFont(name: postScriptName, size: size), font.isFixedPitch else {
            return nil
        }
        return font
    }

    private static func makeResolved(font: NSFont, didFallBack: Bool) -> Resolved {
        let fingerprint = TranscriptCodeFontFingerprint.fingerprint(of: font)
        let minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let tabInterval = max(ceil(spaceWidth * 4), 1)
        return Resolved(
            font: font,
            fingerprint: fingerprint,
            didFallBack: didFallBack,
            minimumLineHeight: minimumLineHeight,
            tabInterval: tabInterval
        )
    }
}
