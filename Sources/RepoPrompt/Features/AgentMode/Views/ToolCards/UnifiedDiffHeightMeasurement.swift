import AppKit
import Foundation
import SwiftUI

/// Width-aware TextKit height measurement for unified-diff cards.
///
/// Cache key shape is fixed for Workstream 5 item 3 (custom font): font identity already
/// participates via `TranscriptCodeFontFingerprint`, so a future custom face only changes
/// the fingerprint value — not this key layout.
enum UnifiedDiffHeightMeasurement {
    /// Pixel bucket size for width keys. Coarse enough to avoid thrashing during live
    /// resize; fine enough that wrap height stays accurate within a few characters.
    static let widthBucketSize: CGFloat = 8
    /// Width is irrelevant when lines do not wrap; wrap mode already distinguishes cache keys.
    static let unwrappedWidthBucket = Int.min

    /// Debounce interval for resize-driven height invalidation.
    static let resizeDebounceNanoseconds: UInt64 = 80_000_000 // 80ms

    struct CacheKey: Hashable, Equatable {
        let contentIdentity: Int
        let widthBucket: Int
        let wrapLines: Bool
        let fontFingerprint: TranscriptCodeFontFingerprint
        let lineSpacing: CGFloat
        let horizontalPadding: CGFloat
        let verticalInset: CGFloat
        let maxLineNumberDigits: Int

        static func widthBucket(for width: CGFloat) -> Int {
            guard width.isFinite, width > 0 else { return 0 }
            let bucket = (width / widthBucketSize).rounded(.down)
            guard bucket.isFinite else { return Int.max }
            guard bucket < CGFloat(Int.max) else { return Int.max }
            return Int(bucket)
        }

        static func make(
            document: UnifiedDiffDocument,
            availableWidth: CGFloat,
            wrapLines: Bool,
            fontFingerprint: TranscriptCodeFontFingerprint,
            lineSpacing: CGFloat,
            horizontalPadding: CGFloat,
            verticalInset: CGFloat
        ) -> CacheKey {
            CacheKey(
                contentIdentity: document.renderID,
                widthBucket: wrapLines ? widthBucket(for: availableWidth) : unwrappedWidthBucket,
                wrapLines: wrapLines,
                fontFingerprint: fontFingerprint,
                lineSpacing: lineSpacing,
                horizontalPadding: horizontalPadding,
                verticalInset: verticalInset,
                maxLineNumberDigits: document.maxLineNumberDigits
            )
        }
    }

    struct Metrics: Equatable {
        let height: CGFloat
        let usedWidth: CGFloat
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: Metrics] = [:]
    private static let cacheLimit = 256

    /// Test seam: clear the process-wide measurement cache.
    static func resetCacheForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll(keepingCapacity: false)
    }

    /// Test seam: current cache occupancy.
    static func cacheCountForTesting() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    static func cachedMetrics(for key: CacheKey) -> Metrics? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    @discardableResult
    static func storeMetrics(_ metrics: Metrics, for key: CacheKey) -> Metrics {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= cacheLimit, cache[key] == nil {
            // Drop an arbitrary entry; keys are cheap and rematerialize on demand.
            if let first = cache.keys.first {
                cache.removeValue(forKey: first)
            }
        }
        cache[key] = metrics
        return metrics
    }

    /// Measure the laid-out height for `document` at `availableWidth`.
    ///
    /// When `wrapLines` is false, uses an effectively infinite container width so height
    /// matches the historical line-count path (one visual line per source line).
    static func measure(
        document: UnifiedDiffDocument,
        availableWidth: CGFloat,
        wrapLines: Bool,
        fontPreset: FontScalePreset,
        fontSize: CGFloat,
        colorScheme: ColorScheme = .light,
        preferredPostScriptName: String? = nil
    ) -> Metrics {
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: preferredPostScriptName,
            pointSize: fontSize
        )
        let fontFingerprint = resolved.fingerprint
        let lineSpacing = UnifiedDiffCardRendering.appKitLineSpacing(for: fontPreset)
        let horizontalPadding = UnifiedDiffCardRendering.appKitHorizontalTextPadding(for: fontPreset)
        let verticalInset = UnifiedDiffCardRendering.appKitVerticalTextInset(for: fontPreset)
        let key = CacheKey.make(
            document: document,
            availableWidth: availableWidth,
            wrapLines: wrapLines,
            fontFingerprint: fontFingerprint,
            lineSpacing: lineSpacing,
            horizontalPadding: horizontalPadding,
            verticalInset: verticalInset
        )
        if let cached = cachedMetrics(for: key) {
            return cached
        }

        let canonicalWidth = wrapLines
            ? max(CGFloat(key.widthBucket) * widthBucketSize, 1)
            : CGFloat.greatestFiniteMagnitude
        let metrics = measureUncached(
            document: document,
            availableWidth: canonicalWidth,
            wrapLines: wrapLines,
            fontFingerprint: fontFingerprint,
            lineSpacing: lineSpacing,
            horizontalPadding: horizontalPadding,
            verticalInset: verticalInset,
            colorScheme: colorScheme,
            resolvedMetrics: resolved,
            preferredPostScriptName: preferredPostScriptName
        )
        return storeMetrics(metrics, for: key)
    }

    static func measureUncached(
        document: UnifiedDiffDocument,
        availableWidth: CGFloat,
        wrapLines: Bool,
        fontFingerprint: TranscriptCodeFontFingerprint,
        lineSpacing: CGFloat,
        horizontalPadding: CGFloat,
        verticalInset: CGFloat,
        colorScheme: ColorScheme = .light,
        resolvedMetrics: TranscriptCodeFontResolver.Resolved? = nil,
        preferredPostScriptName: String? = nil
    ) -> Metrics {
        let resolved = resolvedMetrics ?? TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: fontFingerprint.faceIdentity,
            pointSize: fontFingerprint.pointSize
        )
        let font = resolved.font
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: colorScheme,
            lineSpacing: lineSpacing,
            wrapLines: wrapLines,
            resolvedFontMetrics: resolved,
            preferredPostScriptName: preferredPostScriptName
        ).build()

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        // Match UnifiedDiffTextView: the container tracks the full text-view width and
        // lineFragmentPadding consumes space inside that width exactly once.
        let containerWidth: CGFloat = if wrapLines {
            max(availableWidth, 1)
        } else {
            CGFloat.greatestFiniteMagnitude / 4
        }
        let textContainer = NSTextContainer(size: NSSize(
            width: containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = horizontalPadding
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = ceil(used.height + (verticalInset * 2))
        return Metrics(height: max(height, 1), usedWidth: used.width)
    }

    /// Bucketed width corresponding to `width`, used by view-layer debounce consumers.
    static func bucketedWidth(for width: CGFloat) -> CGFloat {
        let bucket = CacheKey.widthBucket(for: width)
        return CGFloat(bucket) * widthBucketSize
    }
}
