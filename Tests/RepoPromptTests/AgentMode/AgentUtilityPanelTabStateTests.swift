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
        XCTAssertNil(state.baseBranchOverride, "a base must be chosen explicitly, never inferred")
        XCTAssertNil(state.previewDocument)
        XCTAssertEqual(state.htmlDisplayMode, .rendered)
        XCTAssertNil(state.scriptedHTMLDocument, "scripts must be off for every fresh tab")
        XCTAssertTrue(state.expandedFiles.isEmpty)
        XCTAssertTrue(state.contextLevelsByFile.isEmpty)
        XCTAssertTrue(state.baseRevisionByRepoRoot.isEmpty)
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
        let app = file("Sources/App.swift")

        XCTAssertTrue(state.toggleExpansion(ofFile: app))
        XCTAssertTrue(state.isExpanded(file: app))

        XCTAssertFalse(state.toggleExpansion(ofFile: app))
        XCTAssertFalse(state.isExpanded(file: app))
    }

    func testExpansionIsTrackedPerFile() {
        var state = AgentUtilityPanelTabState()
        let a = file("a.swift")
        let b = file("b.swift")

        state.setExpansion(true, ofFile: a)
        state.setExpansion(true, ofFile: b)
        state.setExpansion(false, ofFile: a)

        XCTAssertFalse(state.isExpanded(file: a))
        XCTAssertTrue(state.isExpanded(file: b))
    }

    func testCollapsingAllFilesClearsEveryExpandedPath() {
        var state = AgentUtilityPanelTabState()
        state.setExpansion(true, ofFile: file("a.swift"))
        state.setExpansion(true, ofFile: file("b.swift"))

        state.collapseAllFiles()

        XCTAssertTrue(state.expandedFiles.isEmpty)
    }

    func testQualifiedExpansionAndContextDoNotCollideAcrossGroups() {
        var state = AgentUtilityPanelTabState()
        let first = AgentChangesFileStateKey(
            groupID: AgentChangesGroupID(targetKey: "checkout-alpha"),
            repositoryRelativePath: "Sources/App.swift"
        )
        let second = AgentChangesFileStateKey(
            groupID: AgentChangesGroupID(targetKey: "checkout-beta"),
            repositoryRelativePath: "Sources/App.swift"
        )

        state.setExpansion(true, ofFile: first)
        state.escalateContext(forFile: first)

        XCTAssertTrue(state.isExpanded(file: first))
        XCTAssertFalse(state.isExpanded(file: second))
        XCTAssertEqual(state.contextLevel(forFile: first), .expanded)
        XCTAssertEqual(state.contextLevel(forFile: second), .standard)

        state.setExpansion(true, ofFile: second)
        state.escalateContext(forFile: second)
        state.escalateContext(forFile: first)

        XCTAssertEqual(state.expandedFiles, [first, second])
        XCTAssertEqual(state.contextLevel(forFile: first), .fullFile)
        XCTAssertEqual(state.contextLevel(forFile: second), .expanded)
    }

    // MARK: - Context escalation

    func testContextEscalationStepsFromThreeLinesToTwelveToTheWholeFile() {
        var state = AgentUtilityPanelTabState()
        let key = file("Sources/App.swift")

        XCTAssertEqual(state.contextLevel(forFile: key), .standard)
        XCTAssertEqual(state.contextLevel(forFile: key).contextLines, 3)

        XCTAssertEqual(state.escalateContext(forFile: key), .expanded)
        XCTAssertEqual(state.contextLevel(forFile: key).contextLines, 12)

        XCTAssertEqual(state.escalateContext(forFile: key), .fullFile)
        XCTAssertEqual(state.contextLevel(forFile: key).projectionLevel, .fullFile)
    }

    func testEscalatingPastTheWholeFileSaturatesInsteadOfWrapping() {
        var state = AgentUtilityPanelTabState()
        state.contextLevelsByFile[file("a.swift")] = .fullFile

        XCTAssertEqual(state.escalateContext(forFile: file("a.swift")), .fullFile)
        XCTAssertNil(AgentChangesContextLevel.fullFile.escalated)
    }

    func testContextEscalationAppliesToOneFileOnly() {
        var state = AgentUtilityPanelTabState()

        state.escalateContext(forFile: file("a.swift"))

        XCTAssertEqual(state.contextLevel(forFile: file("a.swift")), .expanded)
        XCTAssertEqual(state.contextLevel(forFile: file("b.swift")), .standard)
    }

    // MARK: - Retargeting

    func testChangingCompareSelectionKeepsExpansionBecauseTheCheckoutIsUnchanged() {
        var state = AgentUtilityPanelTabState()
        let readme = file("README.md")
        state.setExpansion(true, ofFile: readme)
        state.escalateContext(forFile: readme)

        state.setCompareSelection(.vsBase)

        XCTAssertTrue(state.isExpanded(file: readme))
        XCTAssertEqual(state.contextLevel(forFile: readme), .expanded)
    }

    // MARK: - Base revisions

    func testExplicitBaseRevisionsAreRepositoryQualifiedAndResolveIndependently() {
        var state = AgentUtilityPanelTabState()
        let alpha = checkout(at: "/repos/alpha")
        let beta = checkout(at: "/repos/beta")
        state.setCompareSelection(.vsBase)

        state.selectBaseRevision("develop", forRepoRoot: alpha.repoRootURL.path)
        state.selectBaseRevision("release", forRepoRoot: beta.repoRootURL.path)

        XCTAssertEqual(
            state.resolvedCompareMode(for: alpha),
            .vsBase(base: "develop")
        )
        XCTAssertEqual(
            state.resolvedCompareMode(for: beta),
            .vsBase(base: "release")
        )
        XCTAssertEqual(
            state.baseRevisionByRepoRoot,
            ["/repos/alpha": "develop", "/repos/beta": "release"]
        )

        state.selectBaseRevision(nil, forRepoRoot: alpha.repoRootURL.path)

        XCTAssertNil(state.selectedBaseRevision(forRepoRoot: alpha.repoRootURL.path))
        XCTAssertNil(
            state.resolvedCompareMode(for: alpha),
            "clearing one repository must restore Choose base rather than reuse a hidden value"
        )
        XCTAssertEqual(state.resolvedCompareMode(for: beta), .vsBase(base: "release"))

        state.selectBaseRevision("", forRepoRoot: beta.repoRootURL.path)

        XCTAssertNil(
            state.resolvedCompareMode(for: beta),
            "an empty revision is also no explicit choice"
        )
        XCTAssertTrue(state.baseRevisionByRepoRoot.isEmpty)
    }

    func testBaseCandidatesAndLegacyMemoryNeverPopulateTheExplicitBaseMap() {
        var state = AgentUtilityPanelTabState()
        let target = checkout(at: "/repos/alpha")
        let presentedCandidates = ["main", "origin/main"]
        state.setCompareSelection(.vsBase)

        state.selectBaseBranch(presentedCandidates[0], forRepoRoot: target.repoRootURL.path)

        XCTAssertEqual(state.baseBranchOverride, "main")
        XCTAssertEqual(state.lastUsedBaseBranch(forRepoRoot: target.repoRootURL.path), "main")
        XCTAssertTrue(
            state.baseRevisionByRepoRoot.isEmpty,
            "candidate presentation and the scalar base API must not infer a grouped choice"
        )
        XCTAssertNil(state.selectedBaseRevision(forRepoRoot: target.repoRootURL.path))
        XCTAssertNil(state.resolvedCompareMode(for: target))
        XCTAssertTrue(
            state.baseRevisionByRepoRoot.isEmpty,
            "resolving an absent choice must be a read, never lazy candidate reconciliation"
        )
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

    // MARK: - Fixtures

    /// One checkout-qualified file key, so path-keyed scenarios name the checkout they mean.
    private func file(
        _ path: String,
        in targetKey: String = "checkout-alpha"
    ) -> AgentChangesFileStateKey {
        AgentChangesFileStateKey(
            groupID: AgentChangesGroupID(targetKey: targetKey),
            repositoryRelativePath: path
        )
    }

    private func checkout(at path: String) -> AgentPanelResolvedCheckout {
        let rootURL = URL(fileURLWithPath: path)
        return AgentPanelResolvedCheckout(
            checkoutURL: rootURL,
            repoRootURL: rootURL,
            backendKind: .git,
            pathspecPrefixes: [],
            logicalRoots: [AgentPanelLogicalRoot(path: path)],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )
    }
}
