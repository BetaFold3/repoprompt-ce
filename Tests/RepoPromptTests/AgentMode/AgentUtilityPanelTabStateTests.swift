import Foundation
@testable import RepoPromptApp
import XCTest

/// Transitions of the right utility panel's per-tab state.
///
/// This is a pure value type with no I/O and no persistence, so every test here drives it directly
/// rather than through a session or a store.
final class AgentUtilityPanelTabStateTests: XCTestCase {
    // MARK: - Defaults

    func testAFreshTabOpensOnChangesAgainstTheWorkingTree() {
        let state = AgentUtilityPanelTabState()

        XCTAssertEqual(state.segment, .changes)
        XCTAssertEqual(state.compareSelection, .workingTree)
        XCTAssertEqual(state.resolvedCompareMode, .workingTree)
        XCTAssertEqual(state.diffViewMode, .unified)
        XCTAssertEqual(state.changesFilter, .all)
        XCTAssertNil(state.rootOverride)
        XCTAssertNil(state.baseBranchOverride, "a base must be chosen explicitly, never inferred")
        XCTAssertNil(state.previewDocument)
        XCTAssertEqual(state.htmlDisplayMode, .rendered)
        XCTAssertNil(state.scriptedHTMLDocument, "scripts must be off for every fresh tab")
        XCTAssertTrue(state.expandedFilePaths.isEmpty)
        XCTAssertTrue(state.dismissedBannerArtifactIDs.isEmpty)
    }

    func testStagingIsOfferedOnlyWhileComparingAgainstTheWorkingTree() {
        XCTAssertTrue(AgentChangesCompareSelection.workingTree.allowsStaging)
        XCTAssertFalse(
            AgentChangesCompareSelection.vsBase.allowsStaging,
            "a vs-base list spans commits, so a file-level index mutation would not mean what the row shows"
        )
    }

    // MARK: - Compare projection

    func testSelectingVsBaseWithoutABaseResolvesToNoCompareRatherThanAGuess() {
        var state = AgentUtilityPanelTabState()

        state.setCompareSelection(.vsBase)

        XCTAssertEqual(state.compareSelection, .vsBase)
        XCTAssertNil(
            state.resolvedCompareMode,
            "inferring a default branch here is exactly what the design forbids; the panel must ask"
        )
    }

    func testNamingABaseCompletesTheVsBaseCompare() {
        var state = AgentUtilityPanelTabState()
        state.setCompareSelection(.vsBase)

        state.selectBaseBranch("main", forRepoRoot: "/repos/alpha")

        XCTAssertEqual(state.resolvedCompareMode, .vsBase(base: "main"))
    }

    func testAnEmptyBaseDoesNotCompleteTheVsBaseCompare() {
        var state = AgentUtilityPanelTabState()
        state.setCompareSelection(.vsBase)

        state.selectBaseBranch("", forRepoRoot: "/repos/alpha")

        XCTAssertNil(state.resolvedCompareMode)
    }

    func testAnUnusedBaseDoesNotLeakIntoTheWorkingTreeCompare() {
        var state = AgentUtilityPanelTabState()
        state.selectBaseBranch("main", forRepoRoot: "/repos/alpha")

        XCTAssertEqual(
            state.resolvedCompareMode,
            .workingTree,
            "a remembered base must not silently change what Working Tree compares against"
        )
    }

    // MARK: - Segment

    func testSelectingASegmentReplacesTheShownSegment() {
        var state = AgentUtilityPanelTabState()

        state.select(segment: .preview)
        XCTAssertEqual(state.segment, .preview)

        state.select(segment: .changes)
        XCTAssertEqual(state.segment, .changes)
    }

    // MARK: - Diff layout

    func testDiffLayoutPreferenceIsMutablePerTabStateWithoutPersistence() {
        var first = AgentUtilityPanelTabState()
        var second = AgentUtilityPanelTabState()

        first.setDiffViewMode(.split)

        XCTAssertEqual(first.diffViewMode, .split)
        XCTAssertEqual(second.diffViewMode, .unified)
        second.setDiffViewMode(.split)
        XCTAssertEqual(second.diffViewMode, .split)
    }

    // MARK: - Filters and Viewed

    func testFilterSelectionIsLocalToEachTabState() {
        var first = AgentUtilityPanelTabState()
        let second = AgentUtilityPanelTabState()

        first.setChangesFilter(.unstaged)

        XCTAssertEqual(first.changesFilter, .unstaged)
        XCTAssertEqual(second.changesFilter, .all)
    }

    func testViewedRevisionAutomaticallyBecomesEditedSinceAfterContentChanges() {
        var state = AgentUtilityPanelTabState()
        let target = "checkout-a\u{1F}workingTree"
        let reviewed = AgentChangesViewedRevision(rowID: "unstaged:a.swift", contentRevision: 4)
        let edited = AgentChangesViewedRevision(rowID: "unstaged:a.swift", contentRevision: 5)

        state.setViewed(true, revision: reviewed, compareTargetKey: target)

        XCTAssertEqual(state.viewedStatus(for: reviewed, compareTargetKey: target), .viewed)
        XCTAssertEqual(
            state.viewedStatus(for: edited, compareTargetKey: target),
            .editedSinceViewed,
            "A later content revision must not inherit Viewed"
        )

        state.setViewed(true, revision: edited, compareTargetKey: target)
        XCTAssertEqual(state.viewedStatus(for: edited, compareTargetKey: target), .viewed)
    }

    func testViewedStateIsPartitionedByCompareTargetAndCanBeCleared() {
        var state = AgentUtilityPanelTabState()
        let revision = AgentChangesViewedRevision(rowID: "vsBase:a.swift", contentRevision: 2)

        state.setViewed(true, revision: revision, compareTargetKey: "checkout-a\u{1F}vsBase:main")

        XCTAssertEqual(
            state.viewedStatus(for: revision, compareTargetKey: "checkout-a\u{1F}vsBase:release"),
            .notViewed
        )
        state.setViewed(false, revision: revision, compareTargetKey: "checkout-a\u{1F}vsBase:main")
        XCTAssertEqual(
            state.viewedStatus(for: revision, compareTargetKey: "checkout-a\u{1F}vsBase:main"),
            .notViewed
        )
    }

    // MARK: - File expansion

    func testTogglingAFileExpandsThenCollapsesItAndReportsTheResultingState() {
        var state = AgentUtilityPanelTabState()

        XCTAssertTrue(state.toggleExpansion(ofFilePath: "Sources/App.swift"))
        XCTAssertTrue(state.isExpanded(filePath: "Sources/App.swift"))

        XCTAssertFalse(state.toggleExpansion(ofFilePath: "Sources/App.swift"))
        XCTAssertFalse(state.isExpanded(filePath: "Sources/App.swift"))
    }

    func testExpansionIsTrackedPerFile() {
        var state = AgentUtilityPanelTabState()

        state.setExpansion(true, ofFilePath: "a.swift")
        state.setExpansion(true, ofFilePath: "b.swift")
        state.setExpansion(false, ofFilePath: "a.swift")

        XCTAssertFalse(state.isExpanded(filePath: "a.swift"))
        XCTAssertTrue(state.isExpanded(filePath: "b.swift"))
    }

    func testCollapsingAllFilesClearsEveryExpandedPath() {
        var state = AgentUtilityPanelTabState()
        state.setExpansion(true, ofFilePath: "a.swift")
        state.setExpansion(true, ofFilePath: "b.swift")

        state.collapseAllFiles()

        XCTAssertTrue(state.expandedFilePaths.isEmpty)
    }

    // MARK: - Context escalation

    func testContextEscalationStepsFromThreeLinesToTwelveToTheWholeFile() {
        var state = AgentUtilityPanelTabState()
        let path = "Sources/App.swift"

        XCTAssertEqual(state.contextLevel(forFilePath: path), .standard)
        XCTAssertEqual(state.contextLevel(forFilePath: path).contextLines, 3)

        XCTAssertEqual(state.escalateContext(forFilePath: path), .expanded)
        XCTAssertEqual(state.contextLevel(forFilePath: path).contextLines, 12)

        XCTAssertEqual(state.escalateContext(forFilePath: path), .fullFile)
        XCTAssertEqual(state.contextLevel(forFilePath: path).projectionLevel, .fullFile)
    }

    func testEscalatingPastTheWholeFileSaturatesInsteadOfWrapping() {
        var state = AgentUtilityPanelTabState()
        state.contextLevelsByFilePath["a.swift"] = .fullFile

        XCTAssertEqual(state.escalateContext(forFilePath: "a.swift"), .fullFile)
        XCTAssertNil(AgentChangesContextLevel.fullFile.escalated)
    }

    func testContextEscalationAppliesToOneFileOnly() {
        var state = AgentUtilityPanelTabState()

        state.escalateContext(forFilePath: "a.swift")

        XCTAssertEqual(state.contextLevel(forFilePath: "a.swift"), .expanded)
        XCTAssertEqual(state.contextLevel(forFilePath: "b.swift"), .standard)
    }

    // MARK: - Retargeting

    func testRetargetingTheRootClearsPathKeyedExpansionAndContext() {
        var state = AgentUtilityPanelTabState()
        state.setExpansion(true, ofFilePath: "README.md")
        state.escalateContext(forFilePath: "README.md")

        state.selectRootOverride(UUID())

        XCTAssertTrue(
            state.expandedFilePaths.isEmpty,
            "the same relative path in another repository is a different file"
        )
        XCTAssertEqual(state.contextLevel(forFilePath: "README.md"), .standard)
    }

    func testRetargetingTheRootKeepsHowTheUserWantsToReadARepository() {
        var state = AgentUtilityPanelTabState()
        state.setCompareSelection(.vsBase)
        state.selectBaseBranch("main", forRepoRoot: "/repo")

        state.selectRootOverride(UUID())

        XCTAssertEqual(state.compareSelection, .vsBase)
        XCTAssertEqual(state.baseBranchOverride, "main")
    }

    func testSelectingTheSameRootAgainLeavesExpansionUntouched() {
        let rootID = UUID()
        var state = AgentUtilityPanelTabState()
        state.selectRootOverride(rootID)
        state.setExpansion(true, ofFilePath: "README.md")

        state.selectRootOverride(rootID)

        XCTAssertTrue(state.isExpanded(filePath: "README.md"))
    }

    func testChangingCompareSelectionKeepsExpansionBecauseTheCheckoutIsUnchanged() {
        var state = AgentUtilityPanelTabState()
        state.setExpansion(true, ofFilePath: "README.md")
        state.escalateContext(forFilePath: "README.md")

        state.setCompareSelection(.vsBase)

        XCTAssertTrue(state.isExpanded(filePath: "README.md"))
        XCTAssertEqual(state.contextLevel(forFilePath: "README.md"), .expanded)
    }

    // MARK: - Base branch memory

    func testSelectingABaseBranchRecordsItAsThatRepositorysLastUsedBase() {
        var state = AgentUtilityPanelTabState()

        state.selectBaseBranch("develop", forRepoRoot: "/repos/alpha")

        XCTAssertEqual(state.baseBranchOverride, "develop")
        XCTAssertEqual(state.lastUsedBaseBranch(forRepoRoot: "/repos/alpha"), "develop")
    }

    func testLastUsedBasesAreRememberedPerRepository() {
        var state = AgentUtilityPanelTabState()

        state.selectBaseBranch("develop", forRepoRoot: "/repos/alpha")
        state.selectBaseBranch("main", forRepoRoot: "/repos/beta")

        XCTAssertEqual(state.lastUsedBaseBranch(forRepoRoot: "/repos/alpha"), "develop")
        XCTAssertEqual(state.lastUsedBaseBranch(forRepoRoot: "/repos/beta"), "main")
        XCTAssertNil(state.lastUsedBaseBranch(forRepoRoot: "/repos/gamma"))
    }

    func testClearingTheBaseBranchKeepsTheRememberedBaseForThatRepository() {
        var state = AgentUtilityPanelTabState()
        state.selectBaseBranch("develop", forRepoRoot: "/repos/alpha")

        state.selectBaseBranch(nil, forRepoRoot: "/repos/alpha")

        XCTAssertNil(state.baseBranchOverride, "the panel must ask again rather than reuse a cleared choice")
        XCTAssertEqual(
            state.lastUsedBaseBranch(forRepoRoot: "/repos/alpha"),
            "develop",
            "the memory is what lets the picker offer the base the user already chose"
        )
    }

    func testAnEmptyBaseBranchIsNeverRememberedAsAChoice() {
        var state = AgentUtilityPanelTabState()

        state.selectBaseBranch("", forRepoRoot: "/repos/alpha")

        XCTAssertNil(state.lastUsedBaseBranch(forRepoRoot: "/repos/alpha"))
    }

    // MARK: - Preview

    func testShowingAPreviewDocumentAlsoRevealsThePreviewSegment() {
        var state = AgentUtilityPanelTabState()
        let document = PreviewDocumentReference(rootID: UUID(), relativePath: "docs/impl-report.md")

        state.showPreview(of: document)

        XCTAssertEqual(state.previewDocument, document)
        XCTAssertEqual(state.segment, .preview, "a deep link that left Changes showing would drop the caller's intent")
    }

    func testSelectingAPreviewDocumentLeavesTheShownSegmentAlone() {
        var state = AgentUtilityPanelTabState()

        state.selectPreviewDocument(PreviewDocumentReference(rootID: UUID(), relativePath: "notes.md"))

        XCTAssertEqual(state.segment, .changes)
    }

    func testPreviewReferencesStayRootRelativeSoTheyNeverCarryAnAbsolutePath() {
        let rootID = UUID()

        let reference = PreviewDocumentReference(rootID: rootID, relativePath: "/docs/report.md")

        XCTAssertEqual(reference.relativePath, "docs/report.md")
        XCTAssertEqual(reference.fileName, "report.md")
        XCTAssertEqual(reference, PreviewDocumentReference(rootID: rootID, relativePath: "docs/report.md"))
    }

    func testPreviewReferencesForTheSamePathInDifferentRootsAreDistinct() {
        let first = PreviewDocumentReference(rootID: UUID(), relativePath: "README.md")
        let second = PreviewDocumentReference(rootID: UUID(), relativePath: "README.md")

        XCTAssertNotEqual(first, second)
    }

    func testHTMLScriptOptInIsExactDocumentOnlyAndCanBeDisabled() {
        let rootID = UUID()
        let current = PreviewDocumentReference(rootID: rootID, relativePath: "reports/index.html")
        let stale = PreviewDocumentReference(rootID: rootID, relativePath: "reports/old.html")
        var state = AgentUtilityPanelTabState()
        state.selectPreviewDocument(current)

        state.enableHTMLScriptsOnce(for: stale)
        XCTAssertNil(
            state.scriptedHTMLDocument,
            "a stale confirmation must fail toward scripts-off"
        )

        state.enableHTMLScriptsOnce(for: current)
        XCTAssertTrue(state.areHTMLScriptsEnabled(for: current))
        XCTAssertFalse(state.areHTMLScriptsEnabled(for: stale))

        state.disableHTMLScripts()
        XCTAssertNil(state.scriptedHTMLDocument)
        XCTAssertFalse(state.areHTMLScriptsEnabled(for: current))
    }

    func testHTMLScriptOptInClearsOnEveryDifferentDocumentTransition() {
        let rootID = UUID()
        let first = PreviewDocumentReference(rootID: rootID, relativePath: "reports/first.html")
        let second = PreviewDocumentReference(rootID: rootID, relativePath: "reports/second.html")
        var state = AgentUtilityPanelTabState()

        state.selectPreviewDocument(first)
        state.enableHTMLScriptsOnce(for: first)
        state.selectPreviewDocument(second)
        XCTAssertNil(state.scriptedHTMLDocument)

        state.enableHTMLScriptsOnce(for: second)
        state.selectPreviewDocument(nil)
        XCTAssertNil(state.scriptedHTMLDocument)

        state.selectPreviewDocument(first)
        state.enableHTMLScriptsOnce(for: first)
        state.showPreview(of: second)
        XCTAssertNil(state.scriptedHTMLDocument)
        XCTAssertEqual(state.previewDocument, second)
    }

    func testHTMLScriptOptInSurvivesOnlySameDocumentReadingPreferences() {
        let document = PreviewDocumentReference(
            rootID: UUID(),
            relativePath: "reports/index.html"
        )
        var state = AgentUtilityPanelTabState()
        state.selectPreviewDocument(document)
        state.enableHTMLScriptsOnce(for: document)

        state.selectPreviewDocument(document)
        state.setHTMLDisplayMode(.source)
        state.select(segment: .changes)

        XCTAssertTrue(state.areHTMLScriptsEnabled(for: document))
        XCTAssertEqual(
            state.scriptedHTMLDocument,
            document,
            "display and segment preferences do not open a different document"
        )
    }

    func testHTMLDisplayModeTogglesBetweenRenderedAndSource() {
        var state = AgentUtilityPanelTabState()

        state.setHTMLDisplayMode(.source)
        XCTAssertEqual(state.htmlDisplayMode, .source)

        state.setHTMLDisplayMode(.rendered)
        XCTAssertEqual(state.htmlDisplayMode, .rendered)
    }

    // MARK: - Artifact banner

    func testDismissingABannerIsRecordedForThatArtifactOnly() {
        var state = AgentUtilityPanelTabState()

        state.dismissBanner(artifactID: "artifact-1")

        XCTAssertTrue(state.isBannerDismissed(artifactID: "artifact-1"))
        XCTAssertFalse(state.isBannerDismissed(artifactID: "artifact-2"))
    }

    func testDismissingTheSameBannerTwiceIsIdempotent() {
        var state = AgentUtilityPanelTabState()

        state.dismissBanner(artifactID: "artifact-1")
        state.dismissBanner(artifactID: "artifact-1")

        XCTAssertEqual(state.dismissedBannerArtifactIDs, ["artifact-1"])
    }
}
