import AppKit
import Foundation

/// Stable identity for the resolved monospaced font used by transcript diff/code-block
/// measurement caches and render signatures.
///
/// Prefer constructing fingerprints via `TranscriptCodeFontResolver` so preference
/// validation (installed + fixed-pitch) stays in one place. `resolvedFont()` remains a
/// defensive rematerialization for cache consumers that only hold the fingerprint.
struct TranscriptCodeFontFingerprint: Hashable, Equatable {
    /// PostScript / AppKit `fontName` of the resolved face.
    let faceIdentity: String
    /// Exact point size of the resolved face.
    let pointSize: CGFloat

    /// Fingerprint for today's system-monospaced code font at `pointSize`.
    static func systemMonospaced(pointSize: CGFloat) -> TranscriptCodeFontFingerprint {
        fingerprint(of: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular))
    }

    /// Build a fingerprint from an already-resolved `NSFont` (custom face or system).
    static func fingerprint(of font: NSFont) -> TranscriptCodeFontFingerprint {
        TranscriptCodeFontFingerprint(
            faceIdentity: font.fontName,
            pointSize: font.pointSize
        )
    }

    /// Rematerialize the NSFont for this fingerprint, falling back to system monospaced
    /// when the face was uninstalled after the fingerprint was captured.
    func resolvedFont() -> NSFont {
        TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: faceIdentity,
            pointSize: pointSize
        ).font
    }
}
