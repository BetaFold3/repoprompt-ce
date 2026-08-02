@testable import RepoPromptApp
import XCTest

final class IntralineDiffComputerTests: XCTestCase {
    func testCommonPrefixAndSuffixTrimAChangedWordToItsMiddle() {
        let deletion = "alphaColorValue"
        let addition = "alphaBorderValue"

        let ranges = IntralineDiffComputer.ranges(
            deletion: deletion,
            addition: addition
        )

        XCTAssertEqual(fragments(in: deletion, ranges: ranges?.deletion ?? []), ["Colo"])
        XCTAssertEqual(fragments(in: addition, ranges: ranges?.addition ?? []), ["Borde"])
    }

    func testTokenLCSKeepsUnchangedWordsBetweenTwoEditsUnemphasized() {
        let deletion = "one alpha two beta three"
        let addition = "one amber two gamma three"

        let ranges = IntralineDiffComputer.ranges(
            deletion: deletion,
            addition: addition
        )

        XCTAssertEqual(fragments(in: deletion, ranges: ranges?.deletion ?? []), ["lpha", "bet"])
        XCTAssertEqual(fragments(in: addition, ranges: ranges?.addition ?? []), ["mber", "gamm"])
    }

    func testDissimilarLinesFallBelowTheNoiseThreshold() {
        XCTAssertNil(IntralineDiffComputer.ranges(
            deletion: "abcdefghij",
            addition: "qrstuvwxyz"
        ))
    }

    func testUnicodeRangesUseUTF16WithoutSplittingEmojiOrAccentedGraphemes() {
        let deletion = "let value = 👩🏽‍💻 café"
        let addition = "let value = 👩🏽‍💻 cafe"

        let ranges = IntralineDiffComputer.ranges(
            deletion: deletion,
            addition: addition
        )

        XCTAssertEqual(fragments(in: deletion, ranges: ranges?.deletion ?? []), ["é"])
        XCTAssertEqual(fragments(in: addition, ranges: ranges?.addition ?? []), ["e"])
        XCTAssertGreaterThan(ranges?.deletion.first?.lowerBound ?? 0, ("👩🏽‍💻" as NSString).length)
    }

    func testOnlyEqualLengthAdjacentRunsAreAnnotated() {
        let equal = IntralineDiffComputer.annotating([
            line("d1", .deletion, "let value = one"),
            line("d2", .deletion, "let color = red"),
            line("a1", .addition, "let value = two"),
            line("a2", .addition, "let color = blue")
        ])
        XCTAssertFalse(equal[0].intralineRanges.isEmpty)
        XCTAssertFalse(equal[1].intralineRanges.isEmpty)
        XCTAssertFalse(equal[2].intralineRanges.isEmpty)
        XCTAssertFalse(equal[3].intralineRanges.isEmpty)

        let unequal = IntralineDiffComputer.annotating([
            line("d1", .deletion, "let value = one"),
            line("d2", .deletion, "let color = red"),
            line("a1", .addition, "let value = two")
        ])
        XCTAssertTrue(unequal.allSatisfy(\.intralineRanges.isEmpty))
    }

    private func line(
        _ id: String,
        _ kind: FileDiffProjection.LineKind,
        _ text: String
    ) -> FileDiffProjection.Line {
        FileDiffProjection.Line(
            id: id,
            kind: kind,
            oldLine: kind == .deletion ? 1 : nil,
            newLine: kind == .addition ? 1 : nil,
            text: text
        )
    }

    private func fragments(in text: String, ranges: [Range<Int>]) -> [String] {
        let string = text as NSString
        return ranges.map {
            string.substring(with: NSRange(location: $0.lowerBound, length: $0.count))
        }
    }
}
