import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// Presentation contract for the Changes panel: how rows, sections, footers, empty states, and
/// artifact links are derived from repository data.
///
/// Everything here is pure, so the whole suite runs without a repository, a workspace, or a view.
final class AgentChangesPresentationTests: XCTestCase {
    // MARK: - Rows

    /// A file's status letter has to come from the side of the XY pair its section speaks for.
    /// The same porcelain record means "added to the index" in Staged and "modified in the working
    /// tree" in Unstaged, and a row that read the wrong half would label a partially-staged file
    /// with a change it is not showing.
    func testRowStatusReadsTheSideOfThePairItsSectionSpeaksFor() {
        let staged = row(path: "a.swift", section: .staged, index: "A", workTree: "M")
        let unstaged = row(path: "a.swift", section: .unstaged, index: "A", workTree: "M")

        XCTAssertEqual(AgentChangesRowPresentation.statusKind(for: staged), .added)
        XCTAssertEqual(AgentChangesRowPresentation.statusKind(for: unstaged), .modified)
        XCTAssertEqual(AgentChangesRowPresentation(row: staged).status.letter, "A")
        XCTAssertEqual(AgentChangesRowPresentation(row: unstaged).status.letter, "M")
    }

    /// Untracked and conflicted outrank the XY pair: porcelain writes no meaningful pair for an
    /// untracked file, and an unmerged one must never read as an ordinary modification next to a
    /// checkbox that would stage its conflict markers.
    func testUntrackedAndConflictedOverrideTheStatusPair() {
        let untracked = AgentChangesFileRow(
            id: "unstaged:new.swift",
            fileKey: "new.swift",
            path: "new.swift",
            originalPath: nil,
            section: .unstaged,
            indexStatus: nil,
            workTreeStatus: nil,
            isUntracked: true,
            isConflicted: false,
            additions: nil,
            deletions: nil,
            hasCounterpartSection: false,
            contentRevision: 0
        )
        let conflicted = row(path: "merge.swift", section: .conflicts, index: "U", workTree: "U", isConflicted: true)

        XCTAssertEqual(AgentChangesRowPresentation.statusKind(for: untracked), .untracked)
        XCTAssertEqual(AgentChangesRowPresentation(row: untracked).status.letter, "?")
        XCTAssertEqual(AgentChangesRowPresentation.statusKind(for: conflicted), .conflicted)
        XCTAssertFalse(conflicted.isStageable, "A conflicted row is never stageable, whatever its section says")
    }

    /// The row dims the directory and keeps the file name legible, so the split has to survive both
    /// a nested path and a file sitting at the repository root.
    func testPathSplitsIntoADimmableDirectoryAndAFileName() {
        let nested = AgentChangesRowPresentation.split(path: "Sources/Feature/View.swift")
        XCTAssertEqual(nested.directory, "Sources/Feature/")
        XCTAssertEqual(nested.name, "View.swift")

        let root = AgentChangesRowPresentation.split(path: "README.md")
        XCTAssertEqual(root.directory, "")
        XCTAssertEqual(root.name, "README.md")
    }

    /// Stats are optional, and the difference matters: a binary file has no counts, a file with no
    /// net change has zeroes, and rendering the first as "+0 −0" would claim a fact Git never gave.
    func testMissingStatsRenderAsAbsentRatherThanZero() {
        let counted = AgentChangesRowPresentation(row: row(path: "a.swift", section: .unstaged, additions: 12, deletions: 3))
        XCTAssertEqual(counted.additionsText, "+12")
        XCTAssertEqual(counted.deletionsText, "\u{2212}3")

        let uncounted = AgentChangesRowPresentation(row: row(path: "logo.png", section: .unstaged))
        XCTAssertNil(uncounted.additionsText)
        XCTAssertNil(uncounted.deletionsText)
    }

    /// Renames carry their origin into the tooltip and the spoken label, because the row itself only
    /// has room for the destination.
    func testRenameOriginReachesTheTooltipAndTheAccessibilityLabel() {
        var renamed = row(path: "New.swift", section: .staged, index: "R", workTree: ".")
        renamed = AgentChangesFileRow(
            id: renamed.id,
            fileKey: renamed.fileKey,
            path: renamed.path,
            originalPath: "Old.swift",
            section: renamed.section,
            indexStatus: renamed.indexStatus,
            workTreeStatus: renamed.workTreeStatus,
            isUntracked: false,
            isConflicted: false,
            additions: 1,
            deletions: 1,
            hasCounterpartSection: false,
            contentRevision: 0
        )

        let presentation = AgentChangesRowPresentation(row: renamed)
        XCTAssertEqual(presentation.status, .renamed)
        XCTAssertTrue(presentation.tooltip.contains("Old.swift"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("from Old.swift"))
    }

    // MARK: - Sections

    /// Section headers count files and roll up stats, and only offer the bulk action that moves
    /// their own rows out of them.
    func testSectionHeadersCountFilesAndOfferTheActionThatEmptiesThem() {
        let unstaged = AgentChangesSection(kind: .unstaged, rows: [
            row(path: "a.swift", section: .unstaged, additions: 10, deletions: 2),
            row(path: "b.swift", section: .unstaged, additions: 1, deletions: 1)
        ])
        let presentation = AgentChangesSectionPresentation(section: unstaged, supportsStaging: true)
        XCTAssertEqual(presentation.title, "Unstaged")
        XCTAssertEqual(presentation.subtitle, "2 files · +11 \u{2212}3")
        XCTAssertEqual(presentation.bulkActionTitle, "Stage All")

        let staged = AgentChangesSection(kind: .staged, rows: [row(path: "a.swift", section: .staged)])
        XCTAssertEqual(
            AgentChangesSectionPresentation(section: staged, supportsStaging: true).bulkActionTitle,
            "Unstage All"
        )
        XCTAssertEqual(
            AgentChangesSectionPresentation(section: staged, supportsStaging: true).subtitle,
            "1 file",
            "A section with no stats reports its file count alone rather than a fabricated +0 −0"
        )
    }

    /// Sections with no index behind them never grow a bulk control: Conflicts because `git add`
    /// on an unmerged path records conflict markers as resolved, vs-Base and a Jujutsu working copy
    /// because there is no index to move anything into.
    func testSectionsWithoutAnIndexOfferNoBulkAction() {
        let conflicts = AgentChangesSection(kind: .conflicts, rows: [
            row(path: "m.swift", section: .conflicts, isConflicted: true)
        ])
        let vsBase = AgentChangesSection(kind: .vsBase, rows: [row(path: "a.swift", section: .vsBase)])
        let workingCopy = AgentChangesSection(kind: .workingCopy, rows: [row(path: "a.swift", section: .workingCopy)])
        let unstaged = AgentChangesSection(kind: .unstaged, rows: [row(path: "a.swift", section: .unstaged)])

        XCTAssertNil(AgentChangesSectionPresentation(section: conflicts, supportsStaging: true).bulkActionTitle)
        XCTAssertNil(AgentChangesSectionPresentation(section: vsBase, supportsStaging: true).bulkActionTitle)
        XCTAssertNil(AgentChangesSectionPresentation(section: workingCopy, supportsStaging: true).bulkActionTitle)
        XCTAssertNil(
            AgentChangesSectionPresentation(section: unstaged, supportsStaging: false).bulkActionTitle,
            "A backend without a staging area shows no staging surface at all"
        )
    }

    // MARK: - Filters and Viewed progress

    func testFilterCountsAndSectionsComeFromSnapshotMembershipOnly() {
        let sections = [
            AgentChangesSection(kind: .staged, rows: [
                row(path: "partial.swift", section: .staged)
            ]),
            AgentChangesSection(kind: .unstaged, rows: [
                row(path: "partial.swift", section: .unstaged),
                row(path: "working.swift", section: .unstaged)
            ]),
            AgentChangesSection(kind: .conflicts, rows: [
                row(path: "conflict.swift", section: .conflicts, isConflicted: true)
            ])
        ]

        let counts = AgentChangesFiltering.counts(in: sections)
        XCTAssertEqual(counts, AgentChangesFilterCounts(all: 3, staged: 1, unstaged: 2, conflicts: 1))
        XCTAssertEqual(
            AgentChangesFiltering.sections(from: sections, filter: .unstaged).map(\.kind),
            [.unstaged]
        )
        XCTAssertEqual(
            AgentChangesFiltering.sections(from: sections, filter: .conflicts).flatMap(\.rows).map(\.path),
            ["conflict.swift"]
        )
        XCTAssertEqual(
            AgentChangesFiltering.sections(from: sections, filter: .all).map(\.kind),
            [.staged, .unstaged, .conflicts]
        )
    }

    func testViewedProgressCountsLogicalFilesAndRequiresBothPartialPatches() {
        let staged = row(path: "partial.swift", section: .staged, revision: 1)
        let unstaged = row(path: "partial.swift", section: .unstaged, revision: 1)
        let other = row(path: "other.swift", section: .unstaged, revision: 3)
        let sections = [
            AgentChangesSection(kind: .staged, rows: [staged]),
            AgentChangesSection(kind: .unstaged, rows: [unstaged, other])
        ]

        let onlyOnePartialRow = AgentChangesViewedProgress.compute(sections: sections) {
            $0.viewedRevision == staged.viewedRevision
        }
        XCTAssertEqual(
            onlyOnePartialRow,
            AgentChangesViewedProgress(viewedFileCount: 0, totalFileCount: 2),
            "A partially-staged file has two distinct patches to review"
        )

        let completePartial = AgentChangesViewedProgress.compute(sections: sections) {
            $0.fileKey == "partial.swift"
        }
        XCTAssertEqual(completePartial.viewedFileCount, 1)
        XCTAssertEqual(completePartial.totalFileCount, 2)
        XCTAssertEqual(completePartial.fraction, 0.5)
    }

    // MARK: - Footer

    /// A partially-staged file is two rows and one file. The footer counts files, so it must not
    /// report the working tree as twice the size it is.
    func testFooterTotalsCountAPartiallyStagedFileOnce() {
        let snapshot = snapshot(sections: [
            AgentChangesSection(kind: .staged, rows: [
                row(path: "a.swift", section: .staged, additions: 4, deletions: 1)
            ]),
            AgentChangesSection(kind: .unstaged, rows: [
                row(path: "a.swift", section: .unstaged, additions: 2, deletions: 0)
            ])
        ])

        XCTAssertEqual(snapshot.totalFileCount, 1)
        XCTAssertEqual(AgentChangesFooterPresentation.totals(for: snapshot), "1 file · +6 \u{2212}1")
    }

    func testLastRefreshedTextIsCoarseEnoughNotToTick() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertEqual(AgentChangesFooterPresentation.lastRefreshed(nil, now: now), "Not refreshed yet")
        XCTAssertEqual(
            AgentChangesFooterPresentation.lastRefreshed(now.addingTimeInterval(-3), now: now),
            "Updated just now"
        )
        XCTAssertEqual(
            AgentChangesFooterPresentation.lastRefreshed(now.addingTimeInterval(-90), now: now),
            "Updated 1m ago"
        )
        XCTAssertEqual(
            AgentChangesFooterPresentation.lastRefreshed(now.addingTimeInterval(-7200), now: now),
            "Updated 2h ago"
        )
    }

    // MARK: - Empty states

    /// The order of these cases is the policy. A session waiting on worktree hydration has no
    /// checkout yet; reporting that as a clean tree would tell the user their agent changed nothing
    /// at the exact moment it is working.
    func testCheckoutProblemsOutrankACleanTree() {
        let preparing = AgentPanelCheckoutResolution(
            targets: [],
            blocked: [AgentPanelBlockedCheckout(
                logicalRoot: AgentPanelLogicalRoot(path: "/tmp/repo"),
                reason: .worktreePreparing(label: "agent/foo", worktreeRootPath: "/tmp/wt")
            )],
            retrySignature: "a"
        )

        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: preparing,
                snapshot: snapshot(sections: []),
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .blockedRootsOnly
        )
    }

    func testNonRepositoryRootsAreNamedRatherThanCalledEmpty() {
        let resolution = AgentPanelCheckoutResolution(
            targets: [],
            blocked: [AgentPanelBlockedCheckout(
                logicalRoot: AgentPanelLogicalRoot(path: "/tmp/notes", name: "Notes"),
                reason: .notARepository(path: "/tmp/notes")
            )],
            retrySignature: "a"
        )

        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: resolution,
                snapshot: snapshot(sections: []),
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .notARepository(rootName: "Notes")
        )
    }

    /// vs-Base without a base asks, and asks before it reads: a compare that cannot be built must
    /// not be reported as a repository with nothing in it.
    func testVsBaseWithoutABaseAsksInsteadOfReporting() {
        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: snapshot(sections: []),
                compareSelection: .vsBase,
                hasResolvedCompare: false
            ),
            .baseNotChosen
        )
    }

    /// A clean working tree offers the vs-Base bridge, and only in Working Tree mode — an empty
    /// vs-Base list means the base really is caught up, and there is nowhere further to send anyone.
    func testACleanWorkingTreeOffersTheBaseComparisonBridge() {
        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: snapshot(sections: [AgentChangesSection(kind: .unstaged, rows: [])], loadState: .ready),
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .cleanTree(offersBaseComparison: true)
        )

        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: snapshot(sections: [AgentChangesSection(kind: .vsBase, rows: [])], loadState: .ready),
                compareSelection: .vsBase,
                hasResolvedCompare: true
            ),
            .cleanTree(offersBaseComparison: false)
        )
    }

    func testUnbornHeadAndFailureAndPopulatedListsAreDistinguished() {
        let unborn = snapshot(sections: [AgentChangesSection(kind: .unstaged, rows: [])], loadState: .ready, hasHeadCommit: false)
        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: unborn,
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .unbornHead
        )

        let failed = snapshot(sections: [], loadState: .failed("git exploded"))
        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: failed,
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .failed("git exploded")
        )

        let populated = snapshot(
            sections: [AgentChangesSection(kind: .unstaged, rows: [row(path: "a.swift", section: .unstaged)])],
            loadState: .ready
        )
        XCTAssertNil(
            AgentChangesEmptyState.resolve(
                resolution: readyResolution,
                snapshot: populated,
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            "A list with rows in it is not an empty state"
        )

        XCTAssertEqual(
            AgentChangesEmptyState.resolve(
                resolution: nil,
                snapshot: .empty,
                compareSelection: .workingTree,
                hasResolvedCompare: true
            ),
            .loading,
            "No resolution yet means still looking, not nothing here"
        )
    }

    // MARK: - Artifact links

    /// A payload path relative to the checkout resolves against the logical root that stands for it.
    func testRelativeArtifactPathsResolveAgainstTheCheckoutsLogicalRoot() {
        let rootID = UUID()
        let reference = AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: "docs/coverage.html",
            checkout: checkout(path: "/tmp/panel-repo"),
            logicalRoots: [AgentPanelLogicalRoot(path: "/tmp/panel-repo")],
            rootIDsByPath: ["/tmp/panel-repo": rootID]
        )

        XCTAssertEqual(reference, PreviewDocumentReference(rootID: rootID, relativePath: "docs/coverage.html"))
    }

    /// An absolute path inside a root is addressed by that root, and the deepest root wins so a
    /// nested root claims its own documents rather than being swallowed by its parent.
    func testAbsoluteArtifactPathsPreferTheDeepestContainingRoot() {
        let outer = UUID()
        let inner = UUID()
        let reference = AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: "/tmp/panel-repo/packages/app/docs/report.md",
            checkout: checkout(path: "/tmp/panel-repo"),
            logicalRoots: [
                AgentPanelLogicalRoot(path: "/tmp/panel-repo"),
                AgentPanelLogicalRoot(path: "/tmp/panel-repo/packages/app")
            ],
            rootIDsByPath: [
                "/tmp/panel-repo": outer,
                "/tmp/panel-repo/packages/app": inner
            ]
        )

        XCTAssertEqual(reference, PreviewDocumentReference(rootID: inner, relativePath: "docs/report.md"))
    }

    /// A worktree checkout writes its documents at worktree paths, which belong to no logical root
    /// at all. The reference still has to name the logical root, or the Preview segment would hold
    /// an address that dies with the worktree.
    func testWorktreePathsAreTranslatedBackOntoTheLogicalRoot() {
        let rootID = UUID()
        let worktreeCheckout = AgentPanelResolvedCheckout(
            checkoutURL: URL(fileURLWithPath: "/tmp/worktrees/agent-1"),
            repoRootURL: URL(fileURLWithPath: "/tmp/worktrees/agent-1"),
            backendKind: .git,
            pathspecPrefixes: [],
            logicalRoots: [AgentPanelLogicalRoot(path: "/tmp/panel-repo")],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )

        let reference = AgentChangesArtifactLinkResolver.reference(
            forArtifactPath: "/tmp/worktrees/agent-1/docs/report.md",
            checkout: worktreeCheckout,
            logicalRoots: [AgentPanelLogicalRoot(path: "/tmp/panel-repo")],
            rootIDsByPath: ["/tmp/panel-repo": rootID]
        )

        XCTAssertEqual(reference, PreviewDocumentReference(rootID: rootID, relativePath: "docs/report.md"))
    }

    /// A document outside every known root produces no reference — and the caller shows no banner
    /// rather than a banner whose only action cannot work.
    func testArtifactsOutsideEveryRootResolveToNothing() {
        XCTAssertNil(
            AgentChangesArtifactLinkResolver.reference(
                forArtifactPath: "/private/var/tmp/scratch.md",
                checkout: checkout(path: "/tmp/panel-repo"),
                logicalRoots: [AgentPanelLogicalRoot(path: "/tmp/panel-repo")],
                rootIDsByPath: ["/tmp/panel-repo": UUID()]
            )
        )
    }

    // MARK: - Diff typography

    /// The panel and the transcript's diff cards render the same patches in the same window, so the
    /// panel reads its colors off the card vocabulary instead of restating them.
    func testDiffLineKindsMapOntoTheTranscriptCardVocabulary() {
        XCTAssertEqual(AgentChangesDiffPalette.cardKind(for: .addition), .addition)
        XCTAssertEqual(AgentChangesDiffPalette.cardKind(for: .deletion), .deletion)
        XCTAssertEqual(AgentChangesDiffPalette.cardKind(for: .context), .context)
        XCTAssertEqual(
            AgentChangesDiffPalette.cardKind(for: .noNewlineMarker),
            .gap,
            "The no-newline annotation describes its neighbor and takes the recessive treatment"
        )

        XCTAssertEqual(AgentChangesDiffPalette.marker(for: .addition), "+")
        XCTAssertEqual(AgentChangesDiffPalette.marker(for: .deletion), "\u{2212}")
        XCTAssertEqual(AgentChangesDiffPalette.marker(for: .context), " ")

        for colorScheme in [ColorScheme.light, .dark] {
            XCTAssertNil(AgentChangesDiffPalette.backgroundColor(for: .context, colorScheme: colorScheme))
            XCTAssertNotNil(AgentChangesDiffPalette.backgroundColor(for: .addition, colorScheme: colorScheme))
            XCTAssertNotNil(AgentChangesDiffPalette.backgroundColor(for: .deletion, colorScheme: colorScheme))
            XCTAssertNotNil(AgentChangesDiffPalette.backgroundColor(for: .noNewlineMarker, colorScheme: colorScheme))
        }
    }

    /// Both gutters are sized from the widest number in the whole file, so the columns stay in one
    /// straight edge instead of stepping in and out as hunks gain digits.
    func testGutterDigitsCoverTheWidestNumberInTheFile() {
        let document = FileDiffProjection.Document(
            id: "a.swift",
            path: "a.swift",
            oldPath: nil,
            change: .modified,
            additions: 1,
            deletions: 1,
            hunks: [
                FileDiffProjection.Hunk(
                    id: "a.swift#0",
                    oldStart: 1,
                    oldCount: 3,
                    newStart: 1,
                    newCount: 3,
                    heading: nil,
                    lines: []
                ),
                FileDiffProjection.Hunk(
                    id: "a.swift#1",
                    oldStart: 995,
                    oldCount: 10,
                    newStart: 995,
                    newCount: 12,
                    heading: "func body()",
                    lines: []
                )
            ],
            contextLevel: .lines(3),
            truncation: nil
        )

        XCTAssertEqual(AgentChangesPatchPresentation.maximumLineNumberDigits(in: document), 4)
        XCTAssertEqual(
            AgentChangesPatchPresentation.rangeText(for: document.hunks[1]),
            "@@ -995,10 +995,12 @@"
        )
        XCTAssertGreaterThan(
            AgentChangesDiffMetrics.gutterWidth(digits: 4, preset: .normal),
            AgentChangesDiffMetrics.gutterWidth(digits: 2, preset: .normal)
        )
        XCTAssertGreaterThan(
            AgentChangesDiffMetrics.gutterWidth(digits: 4, preset: .extraLarge),
            AgentChangesDiffMetrics.gutterWidth(digits: 4, preset: .normal),
            "Gutters scale with the font preset rather than staying pinned to a Normal-preset guess"
        )
    }

    /// Context escalation is one-way and saturates, and the control disappears at the top rung
    /// rather than promising a width that does not exist.
    func testContextEscalationLabelsFollowTheRungTheFileIsOn() {
        XCTAssertEqual(AgentChangesPatchPresentation.expandContextTitle(from: .standard), "Expand context")
        XCTAssertEqual(AgentChangesPatchPresentation.expandContextTitle(from: .expanded), "Expand to whole file")
        XCTAssertNil(AgentChangesPatchPresentation.expandContextTitle(from: .fullFile))
    }

    /// Only a size wall offers the file itself; an absent diff has no file worth opening from here.
    func testOnlyASizeWallOffersTheFileItself() {
        XCTAssertTrue(AgentChangesPatchPresentation.offersOpenFile(for: .tooLarge(bytes: 5_000_000)))
        XCTAssertFalse(AgentChangesPatchPresentation.offersOpenFile(for: .noTextualDiff))
        XCTAssertFalse(AgentChangesPatchPresentation.offersOpenFile(for: .unbornHead))
        XCTAssertEqual(AgentChangesPatchPresentation.summary(for: .binary), "Binary file — no text to show.")
        XCTAssertEqual(AgentChangesPatchPresentation.summary(for: .renamed(from: "Old.swift")), "Renamed from Old.swift.")
        XCTAssertNil(AgentChangesPatchPresentation.summary(for: .modified))
    }

    // MARK: - Builders

    private var readyResolution: AgentPanelCheckoutResolution {
        AgentPanelCheckoutResolution(
            targets: [checkout(path: "/tmp/panel-repo")],
            blocked: [],
            retrySignature: "ready"
        )
    }

    private func checkout(path: String) -> AgentPanelResolvedCheckout {
        AgentPanelResolvedCheckout(
            checkoutURL: URL(fileURLWithPath: path),
            repoRootURL: URL(fileURLWithPath: path),
            backendKind: .git,
            pathspecPrefixes: [],
            logicalRoots: [AgentPanelLogicalRoot(path: path)],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )
    }

    private func row(
        path: String,
        section: AgentChangesSectionKind,
        index: Character? = ".",
        workTree: Character? = "M",
        isConflicted: Bool = false,
        additions: Int? = nil,
        deletions: Int? = nil,
        revision: UInt64 = 0
    ) -> AgentChangesFileRow {
        AgentChangesFileRow(
            id: AgentChangesFileRow.makeID(section: section, fileKey: path),
            fileKey: path,
            path: path,
            originalPath: nil,
            section: section,
            indexStatus: index,
            workTreeStatus: workTree,
            isUntracked: false,
            isConflicted: isConflicted,
            additions: additions,
            deletions: deletions,
            hasCounterpartSection: false,
            contentRevision: revision
        )
    }

    private func snapshot(
        sections: [AgentChangesSection],
        loadState: AgentChangesLoadState = .ready,
        hasHeadCommit: Bool = true
    ) -> AgentChangesSnapshot {
        AgentChangesSnapshot(
            generation: 1,
            target: checkout(path: "/tmp/panel-repo"),
            mode: .workingTree,
            sections: sections,
            loadState: loadState,
            supportsStaging: true,
            hasHeadCommit: hasHeadCommit,
            isPollingDegraded: false,
            contentEpoch: 0
        )
    }
}
