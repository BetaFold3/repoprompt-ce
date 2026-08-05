import AppKit
import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

final class UnifiedDiffHeightMeasurementTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UnifiedDiffHeightMeasurement.resetCacheForTesting()
    }

    override func tearDown() {
        UnifiedDiffHeightMeasurement.resetCacheForTesting()
        super.tearDown()
    }

    // MARK: - Cache key distinctness

    func testCacheKeyDistinguishesWrapModeWidthBucketAndFontFingerprint() {
        let document = UnifiedDiffCardRendering.parse(sampleDiff)
        let baseFont = TranscriptCodeFontFingerprint.systemMonospaced(pointSize: 12)
        let largerFont = TranscriptCodeFontFingerprint.systemMonospaced(pointSize: 14)

        let base = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let wrapped = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320,
            wrapLines: true,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let widerBucket = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320 + UnifiedDiffHeightMeasurement.widthBucketSize,
            wrapLines: true,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let unwrappedHuge = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: .greatestFiniteMagnitude,
            wrapLines: false,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let wrappedHuge = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: .greatestFiniteMagnitude,
            wrapLines: true,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let hugeFiniteWidth = CGFloat(Int.max) * UnifiedDiffHeightMeasurement.widthBucketSize * 2
        let wrappedHugeFinite = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: hugeFiniteWidth,
            wrapLines: true,
            fontFingerprint: baseFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let differentFont = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontFingerprint: largerFont,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )

        XCTAssertNotEqual(base, wrapped, "wrap mode must participate in the cache key")
        XCTAssertNotEqual(wrapped, widerBucket, "wrapped width bucket must participate in the cache key")
        XCTAssertNotEqual(base, differentFont, "font fingerprint must participate in the cache key")
        XCTAssertEqual(base.widthBucket, UnifiedDiffHeightMeasurement.unwrappedWidthBucket)
        XCTAssertEqual(unwrappedHuge.widthBucket, base.widthBucket)
        XCTAssertEqual(wrappedHuge.widthBucket, Int.max, "greatestFiniteMagnitude clamps instead of trapping")
        XCTAssertEqual(wrappedHugeFinite.widthBucket, Int.max, "large finite widths clamp instead of trapping")
        XCTAssertEqual(
            widerBucket.widthBucket,
            UnifiedDiffHeightMeasurement.CacheKey.widthBucket(for: 320 + UnifiedDiffHeightMeasurement.widthBucketSize)
        )
    }

    func testWidthBucketIgnoresSubBucketJitter() {
        let bucketStart = UnifiedDiffHeightMeasurement.widthBucketSize * 12
        let a = UnifiedDiffHeightMeasurement.CacheKey.widthBucket(for: bucketStart)
        let b = UnifiedDiffHeightMeasurement.CacheKey.widthBucket(
            for: bucketStart + UnifiedDiffHeightMeasurement.widthBucketSize - 0.01
        )
        XCTAssertEqual(a, b)
        let c = UnifiedDiffHeightMeasurement.CacheKey.widthBucket(
            for: bucketStart + UnifiedDiffHeightMeasurement.widthBucketSize
        )
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(
            UnifiedDiffHeightMeasurement.CacheKey.widthBucket(for: .greatestFiniteMagnitude),
            Int.max
        )
    }

    func testCacheInvalidatesOnWidthBucketChange() {
        let document = UnifiedDiffCardRendering.parse(longLineDiff)
        let firstSameBucket = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 200.1,
            wrapLines: true,
            fontPreset: .normal,
            fontSize: 12
        )
        UnifiedDiffHeightMeasurement.resetCacheForTesting()
        let secondSameBucket = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 207.9,
            wrapLines: true,
            fontPreset: .normal,
            fontSize: 12
        )
        XCTAssertEqual(firstSameBucket, secondSameBucket, "same-bucket callers must measure at the canonical floor width")

        UnifiedDiffHeightMeasurement.resetCacheForTesting()
        let narrow = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 200,
            wrapLines: true,
            fontPreset: .normal,
            fontSize: 12
        )
        XCTAssertEqual(UnifiedDiffHeightMeasurement.cacheCountForTesting(), 1)

        let wide = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 200 + UnifiedDiffHeightMeasurement.widthBucketSize * 4,
            wrapLines: true,
            fontPreset: .normal,
            fontSize: 12
        )
        XCTAssertEqual(UnifiedDiffHeightMeasurement.cacheCountForTesting(), 2)
        XCTAssertNotEqual(narrow.height, wide.height, "wider wrap width should change measured height for long lines")
    }

    // MARK: - Wrapped vs unwrapped height

    func testWrappedLongLinesAreTallerThanUnwrapped() {
        let document = UnifiedDiffCardRendering.parse(longLineDiff)
        let unwrapped = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 240,
            wrapLines: false,
            fontPreset: .normal,
            fontSize: 12
        )
        let wrapped = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 240,
            wrapLines: true,
            fontPreset: .normal,
            fontSize: 12
        )
        XCTAssertGreaterThan(
            wrapped.height,
            unwrapped.height,
            "wrapping a long line into a narrow width must increase measured height"
        )
    }

    func testDefaultOffUnwrappedPathUsesClippingParagraphStyle() {
        let document = UnifiedDiffCardRendering.parse(sampleDiff)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: .light,
            lineSpacing: 2,
            wrapLines: false
        ).build()
        guard attributed.length > 0,
              let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else {
            return XCTFail("expected paragraph style on unwrapped attributed string")
        }
        XCTAssertEqual(style.lineBreakMode, .byClipping)
        XCTAssertEqual(style.headIndent, 0)
        let legacyStyle = NSMutableParagraphStyle()
        XCTAssertEqual(style.defaultTabInterval, legacyStyle.defaultTabInterval)
        XCTAssertEqual(style.tabStops.count, legacyStyle.tabStops.count)

        let expectedLineHeight = ceil(font.ascender - font.descender + font.leading)
        let expectedContentHeight =
            (CGFloat(max(document.lines.count, 1)) * expectedLineHeight) +
            (CGFloat(max(document.lines.count - 1, 0)) * UnifiedDiffCardRendering.appKitLineSpacing(for: .normal))
        let expectedHeight = max(expectedContentHeight, UnifiedDiffCardRendering.appKitMinimumBodyHeight(for: .normal))
        let estimated = UnifiedDiffCardRendering.estimatedHeight(
            for: document,
            fontSize: 12,
            fontPreset: .normal,
            maxHeight: 10000,
            availableWidth: .greatestFiniteMagnitude
        )
        XCTAssertEqual(estimated, expectedHeight, "default-off nil-font height must retain the legacy line-count formula")
    }

    func testWrappedPathUsesWordWrappingAndBlankGutterHeadIndent() {
        let document = UnifiedDiffCardRendering.parse(sampleDiff)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: .light,
            lineSpacing: 2,
            wrapLines: true
        ).build()
        guard attributed.length > 0,
              let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else {
            return XCTFail("expected paragraph style on wrapped attributed string")
        }
        XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
        let expectedGutter = UnifiedDiffAttributedStringBuilder.gutterWidth(
            maxLineNumberDigits: document.maxLineNumberDigits,
            font: font
        )
        XCTAssertEqual(style.headIndent, expectedGutter)
        XCTAssertEqual(style.firstLineHeadIndent, 0)
    }

    // MARK: - Copy preserves unwrapped text

    func testCopyPreservesUnwrappedSourceTextWhenWrapped() {
        let document = UnifiedDiffCardRendering.parse(longLineDiff)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let builder = UnifiedDiffAttributedStringBuilder(
            document: document,
            font: font,
            colorScheme: .light,
            lineSpacing: 2,
            wrapLines: true
        )
        let attributed = builder.build()
        let plain = builder.plainSourceText()

        XCTAssertEqual(attributed.string, plain, "attributed storage must keep hard newlines only")
        XCTAssertFalse(attributed.string.contains("\u{2028}"), "must not inject soft line separators")
        // Long line remains a single hard-newline-delimited record.
        let sourceLines = plain.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(sourceLines.contains(where: { $0.count > 80 }))
    }

    // MARK: - Font fingerprint slot

    func testSystemMonospacedFingerprintUsesResolvedFaceIdentity() {
        let fingerprint = TranscriptCodeFontFingerprint.systemMonospaced(pointSize: 13)
        let font = fingerprint.resolvedFont()
        XCTAssertEqual(fingerprint.faceIdentity, font.fontName)
        XCTAssertEqual(fingerprint.pointSize, 13, accuracy: 0.001)
        XCTAssertTrue(font.isFixedPitch)
    }

    func testMeasurePreferredFaceChangesCacheKeyVersusSystem() throws {
        let faces = TranscriptCodeFontResolver.availableFixedPitchFaces()
        let systemFace = TranscriptCodeFontFingerprint.systemMonospaced(pointSize: 12).faceIdentity
        guard let alternate = faces.first(where: { $0.postScriptName != systemFace }) else {
            throw XCTSkip("Need a non-system fixed-pitch face for preferred-face cache distinctness")
        }

        let document = UnifiedDiffCardRendering.parse(sampleDiff)
        _ = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontPreset: .normal,
            fontSize: 12,
            preferredPostScriptName: nil
        )
        XCTAssertEqual(UnifiedDiffHeightMeasurement.cacheCountForTesting(), 1)

        _ = UnifiedDiffHeightMeasurement.measure(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontPreset: .normal,
            fontSize: 12,
            preferredPostScriptName: alternate.postScriptName
        )
        XCTAssertEqual(
            UnifiedDiffHeightMeasurement.cacheCountForTesting(),
            2,
            "preferred face must produce a distinct height cache entry"
        )
    }

    // MARK: - Fixtures

    private var sampleDiff: String {
        """
        diff --git a/file.swift b/file.swift
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
    }

    private var longLineDiff: String {
        let long = String(repeating: "abcdef0123456789", count: 12)
        return """
        diff --git a/long.swift b/long.swift
        --- a/long.swift
        +++ b/long.swift
        @@ -1,2 +1,2 @@
         keep
        -old \(long)
        +new \(long)
        """
    }
}
