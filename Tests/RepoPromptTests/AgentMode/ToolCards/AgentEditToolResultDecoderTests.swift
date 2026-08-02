import Foundation
@testable import RepoPromptApp
import XCTest

/// Contract for the shared edit-payload decoder.
///
/// The decoder was lifted out of `ToolResultEditCards.swift`, so most of this suite is a parity
/// argument: every fixture is run through both the decoder and `LegacyEditCardPayloadReference` —
/// the pre-refactor rules kept verbatim — and the two must agree. Where a card's own output is
/// reachable (`CursorNativeEditResultPresentation`), the assertion goes through the card itself
/// rather than through a copy of it.
final class AgentEditToolResultDecoderTests: XCTestCase {
    private typealias Fixtures = AgentEditToolPayloadFixtures
    private typealias Legacy = LegacyEditCardPayloadReference

    // MARK: - Edit summaries

    func testEditSummaryDiffSelectionMatchesTheLegacyCardRule() {
        for payload in Fixtures.editSummaryPayloads {
            let summary = AgentEditToolResultDecoder.applyEditsSummary(resultJSON: payload.resultJSON)
            XCTAssertEqual(
                AgentEditToolResultDecoder.applyEditsDisplayDiff(from: summary),
                Legacy.resolvedDisplayDiff(from: summary),
                "diff selection drifted for fixture: \(payload.name)"
            )
        }

        let bothDiffs = AgentEditToolResultDecoder.applyEditsSummary(
            resultJSON: Fixtures.editModifiedSwiftWithBothDiffs.resultJSON
        )
        XCTAssertEqual(
            AgentEditToolResultDecoder.applyEditsDisplayDiff(from: bothDiffs)?.contains("compact diff"),
            true,
            "the compact card diff must win over the full diff"
        )
    }

    func testEditSummaryFactsTakeThePathFromArgumentsAndTheFlagsFromTheResult() throws {
        let created = try XCTUnwrap(AgentEditToolResultDecoder.facts(for: Fixtures.editCreatedMarkdown.item()))
        XCTAssertEqual(created.toolKind, .applyEdits)
        XCTAssertEqual(created.files.count, 1)
        let createdFile = try XCTUnwrap(created.files.first)
        XCTAssertEqual(createdFile.path, "/Users/dev/project/docs/impl-report.md")
        XCTAssertEqual(createdFile.disposition, .created)
        XCTAssertEqual(createdFile.fileName, "impl-report.md")
        XCTAssertEqual(createdFile.diffText?.contains("+# Implementation report"), true)
        XCTAssertFalse(createdFile.isDiffTruncated)
        XCTAssertNil(createdFile.movedToPath)

        let overwritten = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editOverwrittenHTMLRelativePath.item())
        )
        XCTAssertEqual(overwritten.files.first?.disposition, .overwritten)
        XCTAssertEqual(overwritten.files.first?.path, "docs/coverage.html")

        let modified = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editModifiedSwiftWithBothDiffs.item())
        )
        XCTAssertEqual(modified.files.first?.disposition, .modified)

        let summaryOnly = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editSummaryOnlyCreatedMarkdown.item())
        )
        XCTAssertEqual(summaryOnly.files.first?.disposition, .created)
        XCTAssertNil(summaryOnly.files.first?.diffText, "a compacted payload keeps its flags but not its diff")
    }

    /// Only the arguments carry the path, so a payload without them describes no file at all.
    func testEditSummaryWithoutArgumentsDescribesNoFile() throws {
        let facts = try XCTUnwrap(AgentEditToolResultDecoder.facts(for: Fixtures.editWithoutArguments.item()))
        XCTAssertEqual(facts.outcome, .succeeded)
        XCTAssertTrue(facts.files.isEmpty)
    }

    func testEnvelopeWrappedResultsAreUnwrappedTheSameWayTheCardsUnwrappedThem() throws {
        let facts = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editEnvelopeWrappedCreatedMarkdown.item())
        )
        XCTAssertEqual(facts.toolKind, .applyEdits)
        XCTAssertEqual(facts.files.first?.disposition, .created)
        XCTAssertEqual(facts.files.first?.path, "notes/summary.md")
    }

    // MARK: - Patches

    func testPatchFactsMirrorEveryChangeInPayloadOrder() {
        for payload in Fixtures.patchPayloads {
            let summary = AgentEditToolResultDecoder.applyPatchSummary(resultJSON: payload.resultJSON)
            let facts = AgentEditToolResultDecoder.applyPatchFiles(summary: summary)
            let legacy = Legacy.patchChanges(from: summary)

            XCTAssertEqual(facts.count, legacy.count, "change count drifted for fixture: \(payload.name)")
            for (file, change) in zip(facts, legacy) {
                XCTAssertEqual(file.path, change.path, "path drifted for fixture: \(payload.name)")
                XCTAssertEqual(file.movedToPath, change.movePath, "move path drifted for fixture: \(payload.name)")
                XCTAssertEqual(file.diffText ?? "", change.diff, "diff drifted for fixture: \(payload.name)")
                XCTAssertEqual(
                    rendersAsUnifiedDiff(file),
                    change.rendersAsUnifiedDiff,
                    "diff routing drifted for \(change.path) in fixture: \(payload.name)"
                )
            }
        }
    }

    func testPatchDispositionsFollowThePayloadChangeWords() throws {
        let facts = try XCTUnwrap(AgentEditToolResultDecoder.facts(for: Fixtures.patchMixedChanges.item()))
        XCTAssertEqual(facts.toolKind, .applyPatch)
        XCTAssertEqual(facts.files.map(\.path), [
            "docs/plan.md",
            "Sources/App/Runner.swift",
            "docs/notes.md",
            "docs/obsolete.md"
        ])
        XCTAssertEqual(facts.files.map(\.disposition), [.created, .modified, .modified, .deleted])
        XCTAssertEqual(facts.files.map(\.rawChangeKind), ["add", "update", "update", "delete"])
        XCTAssertEqual(facts.files[2].movedToPath, "docs/archive/notes.md")
    }

    // MARK: - Native edits

    /// The strongest available parity check: the real card presentation against the old rules.
    func testNativeEditCardDiffsMatchTheLegacyBlockFilter() {
        for payload in Fixtures.nativeEditPayloads {
            let presentation = CursorNativeEditResultPresentation.build(for: payload.item())
            let legacy = Legacy.displayDiffs(
                from: AgentEditToolResultDecoder.nativeEditSummary(resultJSON: payload.resultJSON)
            )

            XCTAssertEqual(
                presentation.diffs.map { Legacy.DisplayDiff(path: $0.path, diff: $0.diff, isTruncated: $0.isTruncated) },
                legacy,
                "rendered diffs drifted for fixture: \(payload.name)"
            )
        }
    }

    func testNativeEditCardTitleSummaryAndRenderModeSurviveTheRefactor() {
        let created = CursorNativeEditResultPresentation.build(for: Fixtures.nativeCreatedMarkdown.item())
        XCTAssertEqual(created.title, "Edit File")
        XCTAssertEqual(created.summary, "cursor-report.md • edit")
        XCTAssertEqual(created.renderMode, .diffPreview)
        XCTAssertTrue(created.isExpandable)

        let truncated = CursorNativeEditResultPresentation.build(
            for: Fixtures.nativeModifiedWithPersistedTruncatedDiff.item()
        )
        XCTAssertEqual(truncated.summary, "handbook.md • edit • diff truncated")
        XCTAssertEqual(truncated.diffs.first?.path, "docs/handbook.md", "the padded path is trimmed exactly as before")

        let dropped = CursorNativeEditResultPresentation.build(for: Fixtures.nativeWithUnrenderableBlocks.item())
        XCTAssertEqual(dropped.title, "Rename symbol")
        XCTAssertEqual(dropped.diffs.map(\.path), ["docs/kept.md"])
        XCTAssertEqual(dropped.summary, "kept.md • edit")
    }

    /// ACP payloads carry no created flag, so only an explicitly empty old text may claim one.
    func testNativeEditCreationIsClaimedOnlyFromReportedEmptyOldText() throws {
        let created = try XCTUnwrap(AgentEditToolResultDecoder.facts(for: Fixtures.nativeCreatedMarkdown.item()))
        XCTAssertEqual(created.files.first?.disposition, .created)

        let persistedDiffOnly = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.nativeModifiedWithPersistedTruncatedDiff.item())
        )
        XCTAssertEqual(
            persistedDiffOnly.files.first?.disposition,
            .modified,
            "a payload that never reported old text must not be guessed into a creation"
        )
        XCTAssertEqual(persistedDiffOnly.files.first?.isDiffTruncated, true)
    }

    // MARK: - Tool identity

    func testToolNameAliasesResolveToTheirEditFamily() {
        let expected: [String: AgentEditToolKind?] = [
            "apply_edits": .applyEdits,
            "functions.apply_edits": .applyEdits,
            "apply_patch": .applyPatch,
            "filechange": .applyPatch,
            "file_change": .applyPatch,
            "edit": .nativeEdit,
            "Edit File": .nativeEdit,
            "read_file": nil,
            "bash": nil,
            "": nil
        ]

        for (toolName, kind) in expected {
            XCTAssertEqual(
                AgentEditToolKind(normalizedToolName: normalizedToolCardName(toolName)),
                kind,
                "unexpected edit family for tool name: \(toolName)"
            )
        }
    }

    func testToolCallsAndNonEditResultsDecodeToNothing() {
        XCTAssertNil(AgentEditToolResultDecoder.facts(for: Fixtures.readFileResult.item()))

        let toolCall = AgentChatItem(
            kind: .toolCall,
            text: "Using tool: apply_edits",
            toolName: "apply_edits",
            toolArgsJSON: Fixtures.editCreatedMarkdown.argsJSON
        )
        XCTAssertNil(
            AgentEditToolResultDecoder.facts(for: toolCall),
            "a call has not edited anything yet; only its result has"
        )
    }

    // MARK: - Outcome

    func testOutcomeReflectsPayloadStatusAndTheErrorFlag() throws {
        let cases: [(Fixtures.Payload, AgentEditToolOutcome)] = [
            (Fixtures.editCreatedMarkdown, .succeeded),
            (Fixtures.editFailedMarkdown, .failed),
            (Fixtures.patchRunningMarkdown, .pending),
            (Fixtures.patchDeclinedMarkdown, .failed),
            (Fixtures.patchSummaryOnlyAliasedToolName, .succeeded),
            (Fixtures.nativeFailed, .failed)
        ]

        for (payload, expected) in cases {
            let facts = try XCTUnwrap(
                AgentEditToolResultDecoder.facts(for: payload.item()),
                "expected edit facts for fixture: \(payload.name)"
            )
            XCTAssertEqual(facts.outcome, expected, "unexpected outcome for fixture: \(payload.name)")
        }

        let unknownStatus = AgentEditToolResultDecoder.facts(
            toolName: "apply_edits",
            resultJSON: #"{"status":"weird","edits_requested":1,"edits_applied":1}"#,
            argsJSON: #"{"path":"docs/report.md"}"#,
            isError: nil
        )
        XCTAssertEqual(unknownStatus?.outcome, .unknown)

        let errorFlagWins = AgentEditToolResultDecoder.facts(
            toolName: "apply_edits",
            resultJSON: #"{"status":"success","edits_requested":1,"edits_applied":1,"file_created":true}"#,
            argsJSON: #"{"path":"docs/report.md"}"#,
            isError: true
        )
        XCTAssertEqual(errorFlagWins?.outcome, .failed, "a transport-level error outranks an optimistic status word")
    }

    func testOutcomesThatMayHaveReachedDiskAreExactlyTheNonFailedNonStreamingOnes() {
        XCTAssertTrue(AgentEditToolOutcome.succeeded.mayHaveReachedDisk)
        XCTAssertTrue(AgentEditToolOutcome.partial.mayHaveReachedDisk)
        XCTAssertTrue(AgentEditToolOutcome.unknown.mayHaveReachedDisk)
        XCTAssertFalse(AgentEditToolOutcome.failed.mayHaveReachedDisk)
        XCTAssertFalse(AgentEditToolOutcome.pending.mayHaveReachedDisk)
    }

    // MARK: - Paths

    func testPathsAreClassifiedWithoutInventingAWorkspaceRoot() throws {
        let absolute = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editCreatedMarkdown.item())?.files.first
        )
        XCTAssertTrue(absolute.isAbsolutePath)
        XCTAssertEqual(absolute.absolutePath, "/Users/dev/project/docs/impl-report.md")
        XCTAssertNil(absolute.relativePath)

        let relative = try XCTUnwrap(
            AgentEditToolResultDecoder.facts(for: Fixtures.editOverwrittenHTMLRelativePath.item())?.files.first
        )
        XCTAssertFalse(relative.isAbsolutePath)
        XCTAssertEqual(relative.relativePath, "docs/coverage.html")
        XCTAssertNil(relative.absolutePath)
        XCTAssertEqual(relative.fileExtension, "html")
    }

    func testFileExtensionsAreCaseFolded() throws {
        let facts = try XCTUnwrap(AgentEditToolResultDecoder.facts(
            toolName: "apply_edits",
            resultJSON: #"{"status":"success","edits_requested":1,"edits_applied":1,"file_created":true}"#,
            argsJSON: #"{"path":"docs/REPORT.MD"}"#,
            isError: nil
        ))
        XCTAssertEqual(facts.files.first?.fileExtension, "md")
        XCTAssertEqual(facts.files.first?.fileName, "REPORT.MD")
    }

    // MARK: - Helpers

    /// Mirrors `ApplyPatchResultCard.isUnifiedDiff(_:)`, which is private to the card. If this and
    /// the card ever disagree, the decoder stopped carrying what the card needs.
    private func rendersAsUnifiedDiff(_ file: AgentEditedFileFact) -> Bool {
        guard file.rawChangeKind == "update", let diff = file.diffText else { return false }
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@@") || trimmed.contains("--- ") || trimmed.contains("+++ ")
    }
}
