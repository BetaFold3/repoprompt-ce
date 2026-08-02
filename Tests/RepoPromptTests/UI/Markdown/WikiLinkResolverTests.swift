import Foundation
@testable import RepoPromptApp
import XCTest

/// Contract tests for `[[wiki link]]` parsing and root-scoped resolution.
///
/// Containment is the security-relevant contract here: a preview document can
/// be authored by an agent, so a wiki link must never be able to name a file
/// outside the root the reader chose.
final class WikiLinkResolverTests: XCTestCase {
    private static let vault = [
        "README.md",
        "notes/Design Notes.md",
        "notes/Sub Folder/Deep Note.md",
        "notes/image.png",
        "media/Hero.JPG",
        "media/vector.svg",
        "media/photo.heic",
        "media/card.webp",
        "Archive/OLD NOTE.md",
        "duplicate.md",
        "nested/duplicate.md"
    ]

    private var resolver: WikiLinkResolver {
        WikiLinkResolver(rootRelativePaths: Self.vault)
    }

    // MARK: - Parsing

    func testReferenceParsingSplitsAliasAndFragmentAndRejectsEmptyTargets() {
        let cases: [(raw: String, target: String?, fragment: String?, alias: String?)] = [
            ("Design Notes", "Design Notes", nil, nil),
            ("Design Notes|the design", "Design Notes", nil, "the design"),
            ("  spaced  |  padded alias  ", "spaced", nil, "padded alias"),
            ("notes/Design Notes#Section Two", "notes/Design Notes", "Section Two", nil),
            ("notes/Deep#Anchor|Shown", "notes/Deep", "Anchor", "Shown"),
            ("target|", "target", nil, nil),
            ("target#", "target", nil, nil),
            ("", nil, nil, nil),
            ("   ", nil, nil, nil),
            ("|alias only", nil, nil, nil),
            ("#fragment only", nil, nil, nil)
        ]

        for testCase in cases {
            let reference = WikiLinkReference(rawInner: testCase.raw)
            guard let expectedTarget = testCase.target else {
                XCTAssertNil(reference, "\(testCase.raw.debugDescription) is not a usable link")
                continue
            }
            XCTAssertEqual(reference?.target, expectedTarget, testCase.raw)
            XCTAssertEqual(reference?.fragment, testCase.fragment, testCase.raw)
            XCTAssertEqual(reference?.alias, testCase.alias, testCase.raw)
        }

        // The alias is what a reader should see; the target is what resolves.
        XCTAssertEqual(WikiLinkReference(rawInner: "Target|Shown")?.displayText, "Shown")
        XCTAssertEqual(WikiLinkReference(rawInner: "Target")?.displayText, "Target")
    }

    // MARK: - Escape rejection

    func testTargetsThatLeaveTheRootAreRejectedRatherThanResolved() {
        let cases: [(target: String, rejection: WikiLinkRejection)] = [
            ("../secrets", .escapesRoot),
            ("notes/../../secrets", .escapesRoot),
            ("../../../../etc/passwd", .escapesRoot),
            ("/etc/passwd", .absolutePath),
            ("/README.md", .absolutePath),
            ("~/private/notes", .absolutePath),
            ("https://example.com/page", .externalScheme),
            ("file:///etc/passwd", .externalScheme),
            ("mailto:someone@example.com", .externalScheme),
            // A drive-letter path is not a scheme this app honours, but it is
            // still contained: it can only ever fail to name a candidate.
            ("C:/Windows/system32", .notFound),
            (".", .emptyTarget),
            ("./", .emptyTarget)
        ]

        for testCase in cases {
            let reference = WikiLinkReference(rawInner: testCase.target)
            guard let reference else {
                XCTFail("\(testCase.target) should parse before being rejected on resolution")
                continue
            }
            XCTAssertEqual(
                resolver.resolve(reference),
                .rejected(testCase.rejection),
                "\(testCase.target) must not resolve"
            )
        }
    }

    func testTraversalThatReturnsInsideTheRootStillResolves() throws {
        // `notes/../README` never leaves the root, so it is a legitimate path.
        let reference = try XCTUnwrap(WikiLinkReference(rawInner: "notes/../README"))
        XCTAssertEqual(
            resolver.resolve(reference),
            .resolved(relativePath: "README.md", fragment: nil)
        )
    }

    func testAColonInAFileNameIsNotMistakenForAURLScheme() throws {
        let root = WikiLinkResolver(rootRelativePaths: ["Meeting: Notes.md"])
        let reference = try XCTUnwrap(WikiLinkReference(rawInner: "Meeting: Notes"))
        XCTAssertEqual(
            root.resolve(reference),
            .resolved(relativePath: "Meeting: Notes.md", fragment: nil)
        )
    }

    // MARK: - Matching

    func testResolutionPrefersExactPathsThenInfersTheMarkdownExtension() throws {
        let exact = try XCTUnwrap(WikiLinkReference(rawInner: "notes/Design Notes.md"))
        XCTAssertEqual(
            resolver.resolve(exact),
            .resolved(relativePath: "notes/Design Notes.md", fragment: nil)
        )

        let inferred = try XCTUnwrap(WikiLinkReference(rawInner: "notes/Design Notes"))
        XCTAssertEqual(
            resolver.resolve(inferred),
            .resolved(relativePath: "notes/Design Notes.md", fragment: nil),
            "a bare target infers the .md extension"
        )

        let nested = try XCTUnwrap(WikiLinkReference(rawInner: "notes/Sub Folder/Deep Note"))
        XCTAssertEqual(
            resolver.resolve(nested),
            .resolved(relativePath: "notes/Sub Folder/Deep Note.md", fragment: nil)
        )

        // Non-Markdown assets resolve only on their exact name.
        let asset = try XCTUnwrap(WikiLinkReference(rawInner: "notes/image.png"))
        XCTAssertEqual(
            resolver.resolve(asset),
            .resolved(relativePath: "notes/image.png", fragment: nil)
        )

        let missing = try XCTUnwrap(WikiLinkReference(rawInner: "notes/Nothing Here"))
        XCTAssertEqual(resolver.resolve(missing), .rejected(.notFound))
    }

    func testEmbedResolutionInfersImageExtensionsAndClassifiesNotes() {
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "notes/image"),
            .resolved(relativePath: "notes/image.png", fragment: nil, kind: .image)
        )
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "media/hero"),
            .resolved(relativePath: "media/Hero.JPG", fragment: nil, kind: .image)
        )
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "media/vector"),
            .resolved(relativePath: "media/vector.svg", fragment: nil, kind: .image)
        )
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "media/photo.heic"),
            .resolved(relativePath: "media/photo.heic", fragment: nil, kind: .image)
        )
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "media/card.webp"),
            .resolved(relativePath: "media/card.webp", fragment: nil, kind: .image)
        )
        XCTAssertEqual(
            resolver.resolveEmbed(rawTarget: "notes/Design Notes#Rollout"),
            .resolved(
                relativePath: "notes/Design Notes.md",
                fragment: "Rollout",
                kind: .note
            )
        )

        XCTAssertEqual(
            resolver.resolve(rawTarget: "notes/image"),
            .rejected(.notFound),
            "image extension inference belongs only to embed syntax"
        )
        XCTAssertEqual(resolver.resolveEmbed(rawTarget: "../escape"), .rejected(.escapesRoot))
    }

    func testCaseInsensitiveFallbackMatchesAndIsDeterministicAboutTies() throws {
        let lowercased = try XCTUnwrap(WikiLinkReference(rawInner: "readme"))
        XCTAssertEqual(
            resolver.resolve(lowercased),
            .resolved(relativePath: "README.md", fragment: nil),
            "macOS roots are routinely case-insensitive, so a lowercase link must still land"
        )

        let mixedCase = try XCTUnwrap(WikiLinkReference(rawInner: "archive/old note"))
        XCTAssertEqual(
            resolver.resolve(mixedCase),
            .resolved(relativePath: "Archive/OLD NOTE.md", fragment: nil)
        )

        // An exact match always beats a case-insensitive one.
        let ambiguous = WikiLinkResolver(rootRelativePaths: ["Note.md", "note.md"])
        let exactLower = try XCTUnwrap(WikiLinkReference(rawInner: "note.md"))
        XCTAssertEqual(
            ambiguous.resolve(exactLower),
            .resolved(relativePath: "note.md", fragment: nil)
        )

        // When only case-insensitive matches exist, the smallest path wins so
        // resolution never depends on enumeration order.
        let tied = WikiLinkResolver(rootRelativePaths: ["zeta/Note.md", "alpha/NOTE.md"])
        let tiedReference = try XCTUnwrap(WikiLinkReference(rawInner: "ALPHA/note"))
        XCTAssertEqual(
            tied.resolve(tiedReference),
            .resolved(relativePath: "alpha/NOTE.md", fragment: nil)
        )
        let reordered = WikiLinkResolver(rootRelativePaths: ["alpha/NOTE.md", "zeta/Note.md"])
        XCTAssertEqual(tied.resolve(tiedReference), reordered.resolve(tiedReference))
    }

    func testFragmentsSurviveResolutionAndDoNotAffectMatching() throws {
        let reference = try XCTUnwrap(WikiLinkReference(rawInner: "notes/Design Notes#Rollout|plan"))
        XCTAssertEqual(
            resolver.resolve(reference),
            .resolved(relativePath: "notes/Design Notes.md", fragment: "Rollout"),
            "the fragment travels through resolution for later scroll targeting"
        )
    }

    func testRawTargetConvenienceMatchesTheParsedPath() {
        XCTAssertEqual(
            resolver.resolve(rawTarget: "notes/Design Notes|alias"),
            .resolved(relativePath: "notes/Design Notes.md", fragment: nil)
        )
        XCTAssertEqual(resolver.resolve(rawTarget: "   "), .rejected(.emptyTarget))
    }

    func testAnEmptyRootResolvesNothingButStillRejectsUnsafeTargetsFirst() throws {
        let empty = WikiLinkResolver(rootRelativePaths: [])
        let present = try XCTUnwrap(WikiLinkReference(rawInner: "anything"))
        let escaping = try XCTUnwrap(WikiLinkReference(rawInner: "../escape"))

        XCTAssertEqual(empty.resolve(present), .rejected(.notFound))
        XCTAssertEqual(
            empty.resolve(escaping),
            .rejected(.escapesRoot),
            "containment is decided before the root is consulted"
        )
    }
}
