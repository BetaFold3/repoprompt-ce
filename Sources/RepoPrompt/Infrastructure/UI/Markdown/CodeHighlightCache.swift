import AppKit
import Foundation

/// Caches pre-highlighted code blocks as attributed strings.
/// - Uses NSCache for automatic eviction.
/// - Cache key includes language, content, font identity, legacy/custom mode, and wrap mode.
@MainActor
class CodeHighlightCache {
    static let shared = CodeHighlightCache()

    private let cache = NSCache<NSString, NSAttributedString>()

    /// Returns a pre-highlighted attributed string for the given code snippet.
    /// - Parameters:
    ///   - code: Raw code text.
    ///   - language: Optional language hint.
    ///   - fontPointSize: Monospaced font size to render with.
    ///   - fontFingerprint: Optional transcript code-font identity. When nil, uses
    ///     system monospaced (composer / non-transcript callers). Transcript paths
    ///     pass the resolver fingerprint so face changes invalidate cache entries.
    func highlighted(
        _ code: String,
        language: String? = nil,
        fontPointSize: CGFloat,
        fontFingerprint: TranscriptCodeFontFingerprint? = nil,
        wrapLines: Bool = false
    ) -> NSAttributedString {
        let fingerprint = fontFingerprint
            ?? TranscriptCodeFontFingerprint.systemMonospaced(pointSize: fontPointSize)
        let attributeMode = fontFingerprint == nil ? "legacy" : "resolved"
        let key = "\(language ?? "plain")|\(code.hashValue)|\(fingerprint.pointSize)|\(fingerprint.faceIdentity)|\(attributeMode)|\(wrapLines)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: fingerprint.faceIdentity,
            pointSize: fingerprint.pointSize
        )
        let font = resolved.font
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        if fontFingerprint != nil {
            attrs[.paragraphStyle] = resolved.makeCodeParagraphStyle(
                lineBreakMode: wrapLines ? .byWordWrapping : .byClipping
            )
        }
        let mutable = NSMutableAttributedString(string: code, attributes: attrs)

        // Reuse the app's highlighter
        CodeHighlighter.applyHighlighting(to: mutable, code: code)

        cache.setObject(mutable, forKey: key)
        return mutable
    }

    /// Clears the cache (optional; NSCache will also auto-evict entries).
    func clear() {
        cache.removeAllObjects()
    }
}
