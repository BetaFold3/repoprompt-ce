import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class TranscriptCodeFontResolverTests: XCTestCase {
    func testNilPreferenceResolvesToSystemMonospaced() {
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: nil,
            pointSize: 12
        )
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(resolved.font.fontName, system.fontName)
        XCTAssertEqual(resolved.fingerprint.faceIdentity, system.fontName)
        XCTAssertEqual(resolved.fingerprint.pointSize, 12, accuracy: 0.001)
        XCTAssertFalse(resolved.didFallBack)
        XCTAssertTrue(resolved.font.isFixedPitch)
        XCTAssertGreaterThan(resolved.minimumLineHeight, 0)
        XCTAssertGreaterThan(resolved.tabInterval, 0)
    }

    func testEmptyPreferenceResolvesToSystemMonospacedWithoutFallbackFlag() {
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: "   ",
            pointSize: 13
        )
        XCTAssertEqual(
            resolved.font.fontName,
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        )
        XCTAssertFalse(resolved.didFallBack)
    }

    func testMissingFaceSilentlyFallsBackToSystemMonospaced() {
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: "RepoPrompt-Definitely-Missing-FixedPitch-Face-XYZ",
            pointSize: 12
        )
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(resolved.font.fontName, system.fontName)
        XCTAssertTrue(resolved.didFallBack)
        XCTAssertTrue(resolved.font.isFixedPitch)
    }

    func testNonFixedPitchFaceIsRejectedAndFallsBack() {
        // Helvetica is a proportional face present on every macOS install.
        XCTAssertFalse(TranscriptCodeFontResolver.isValidFixedPitchFace("Helvetica"))
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: "Helvetica",
            pointSize: 12
        )
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(resolved.font.fontName, system.fontName)
        XCTAssertTrue(resolved.didFallBack)
    }

    func testInstalledFixedPitchFaceIsAcceptedWhenAvailable() throws {
        let faces = TranscriptCodeFontResolver.availableFixedPitchFaces()
        guard let menlo = faces.first(where: { $0.postScriptName.localizedCaseInsensitiveContains("Menlo") })
            ?? faces.first
        else {
            throw XCTSkip("No fixed-pitch faces installed on this host")
        }
        XCTAssertTrue(TranscriptCodeFontResolver.isValidFixedPitchFace(menlo.postScriptName))
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: menlo.postScriptName,
            pointSize: 14
        )
        XCTAssertEqual(resolved.font.fontName, menlo.postScriptName)
        XCTAssertFalse(resolved.didFallBack)
        XCTAssertEqual(resolved.fingerprint.faceIdentity, menlo.postScriptName)
        XCTAssertEqual(resolved.fingerprint.pointSize, 14, accuracy: 0.001)
    }

    func testAvailableFixedPitchFacesAreAllFixedPitch() {
        let faces = TranscriptCodeFontResolver.availableFixedPitchFaces()
        XCTAssertFalse(faces.isEmpty, "macOS ships with at least one fixed-pitch face")
        for face in faces {
            XCTAssertFalse(face.postScriptName.hasPrefix("."), "private dot-prefixed faces must not appear in the picker")
            guard let font = NSFont(name: face.postScriptName, size: 12) else {
                return XCTFail("listed face \(face.postScriptName) could not be instantiated")
            }
            XCTAssertTrue(font.isFixedPitch, "\(face.postScriptName) must be fixed-pitch")
        }
        let expectedOrder = faces.sorted { lhs, rhs in
            let displayOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return lhs.postScriptName.localizedStandardCompare(rhs.postScriptName) == .orderedAscending
        }
        XCTAssertEqual(faces, expectedOrder, "picker faces must be ordered by display name")
    }

    @MainActor
    func testCodeParagraphStylePinsLineHeightAndTabStops() {
        let resolved = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: nil,
            pointSize: 12
        )
        let clippedSignature = TextKitView.paragraphStyleSignature(
            font: resolved.font,
            wrapLines: false
        )
        let wrappedSignature = TextKitView.paragraphStyleSignature(
            font: resolved.font,
            wrapLines: true
        )
        XCTAssertEqual(
            clippedSignature.fontFingerprint,
            wrappedSignature.fontFingerprint
        )
        XCTAssertNotEqual(
            clippedSignature,
            wrappedSignature,
            "Wrap-only changes must invalidate TextKitView paragraph style"
        )

        let style = resolved.makeCodeParagraphStyle(lineSpacing: 2)
        XCTAssertEqual(style.minimumLineHeight, resolved.minimumLineHeight)
        XCTAssertEqual(style.maximumLineHeight, resolved.minimumLineHeight)
        XCTAssertEqual(style.defaultTabInterval, resolved.tabInterval)
        XCTAssertFalse(style.tabStops.isEmpty)
        XCTAssertEqual(style.lineSpacing, 2)

        CodeHighlightCache.shared.clear()
        let legacy = CodeHighlightCache.shared.highlighted("let value = 1", fontPointSize: 12)
        XCTAssertNil(legacy.attribute(.paragraphStyle, at: 0, effectiveRange: nil))

        let clipped = CodeHighlightCache.shared.highlighted(
            "let value = 1",
            fontPointSize: 12,
            fontFingerprint: resolved.fingerprint,
            wrapLines: false
        )
        let wrapped = CodeHighlightCache.shared.highlighted(
            "let value = 1",
            fontPointSize: 12,
            fontFingerprint: resolved.fingerprint,
            wrapLines: true
        )
        let clippedStyle = clipped.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let wrappedStyle = wrapped.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(clippedStyle?.lineBreakMode, .byClipping)
        XCTAssertEqual(wrappedStyle?.lineBreakMode, .byWordWrapping)
        CodeHighlightCache.shared.clear()
    }

    func testDistinctFacesProduceDistinctFingerprintsForCacheKeys() throws {
        let system = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: nil,
            pointSize: 12
        ).fingerprint
        let faces = TranscriptCodeFontResolver.availableFixedPitchFaces()
        guard let alternate = faces.first(where: { $0.postScriptName != system.faceIdentity }) else {
            throw XCTSkip("Need a second fixed-pitch face to prove fingerprint distinctness")
        }
        let custom = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: alternate.postScriptName,
            pointSize: 12
        ).fingerprint
        XCTAssertNotEqual(system, custom)

        let document = UnifiedDiffCardRendering.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        """)
        let systemKey = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontFingerprint: system,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        let customKey = UnifiedDiffHeightMeasurement.CacheKey.make(
            document: document,
            availableWidth: 320,
            wrapLines: false,
            fontFingerprint: custom,
            lineSpacing: 2,
            horizontalPadding: 6,
            verticalInset: 0
        )
        XCTAssertNotEqual(systemKey, customKey)
    }
}
