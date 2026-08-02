import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

/// Behavior contract for the Changes panel's controller.
///
/// Everything runs against fakes with an immediate scheduler and no repository on disk, so the
/// suite exercises retargeting, lazy patch loading, staging presentation, and the artifact deep
/// link without a workspace, a session graph, or Git.
@MainActor
final class AgentChangesPanelViewModelTests: XCTestCase {
    private let repoA = "/tmp/agent-changes-panel-a"
    private let repoB = "/tmp/agent-changes-panel-b"

    // MARK: - Retargeting

    /// Switching tabs points the repository at that tab's checkout, and the rows follow.
    ///
    /// The panel is one controller for the whole window, so a tab switch that failed to retarget
    /// would leave one session reviewing another session's working tree — with checkboxes.
    func testSwitchingTabsPointsTheRepositoryAtThatTabsCheckout() async {
        let harness = makeHarness()
        let tabA = UUID()
        let tabB = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.configure(checkout: repoB, entries: [modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tabA)
        harness.environment.setRoots([(repoB, UUID())], forTab: tabB)

        harness.sync(tabID: tabA)
        await harness.viewModel.settle()
        XCTAssertEqual(harness.viewModel.snapshot.target?.checkoutURL.path, repoA)
        XCTAssertEqual(harness.unstagedPaths, ["a.swift"])

        harness.sync(tabID: tabB)
        XCTAssertEqual(
            harness.viewModel.snapshot,
            .empty,
            "The previous tab's file list must disappear synchronously under the new header"
        )
        await harness.viewModel.settle()
        XCTAssertEqual(harness.viewModel.snapshot.target?.checkoutURL.path, repoB)
        XCTAssertEqual(harness.unstagedPaths, ["b.swift"])
        XCTAssertNil(
            harness.viewModel.statusMessage,
            "A tab switch starts clean rather than carrying the previous tab's message"
        )
    }

    /// A root that resolves to no repository leaves the panel with a named empty state rather than
    /// an empty list that looks like a clean tree.
    func testARootWithoutARepositoryProducesANamedEmptyState() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.environment.setRoots([("/tmp/agent-changes-panel-notes", UUID())], forTab: tab)
        harness.probe.addDirectory("/tmp/agent-changes-panel-notes")

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.emptyState, .notARepository(rootName: "agent-changes-panel-notes"))
        XCTAssertNil(harness.viewModel.activeTarget)
    }

    // MARK: - Lazy patch loading

    /// The first file opens itself; every other file costs a patch read only when the user asks for
    /// one. Refresh never fetches patch text, so an unexpanded list stays cheap while an agent
    /// rewrites it.
    func testTheFirstFileOpensItselfAndOthersLoadOnlyWhenExpanded() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift"), modified("b.swift")])
        harness.diffSource.setPatch(for: "a.swift", text: Self.patch(path: "a.swift"))
        harness.diffSource.setPatch(for: "b.swift", text: Self.patch(path: "b.swift"))
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.environment.state(forTab: tab).expandedFilePaths, ["a.swift"])
        XCTAssertEqual(harness.diffSource.patchCallCount, 1, "Only the auto-expanded file is fetched")
        guard let rowA = harness.unstagedRow("a.swift"), let rowB = harness.unstagedRow("b.swift") else {
            return XCTFail("Expected both files in the unstaged section")
        }
        XCTAssertNotNil(harness.viewModel.patchState(for: rowA).document)
        XCTAssertEqual(harness.viewModel.patchState(for: rowB), .idle)

        harness.viewModel.toggleExpansion(rowB)
        await harness.viewModel.settle()
        XCTAssertEqual(harness.diffSource.patchCallCount, 2)
        XCTAssertNotNil(harness.viewModel.patchState(for: rowB).document)

        harness.viewModel.toggleExpansion(rowB)
        await harness.viewModel.settle()
        XCTAssertEqual(
            harness.viewModel.patchState(for: rowB),
            .idle,
            "A collapsed file releases its projection instead of holding a rendered diff nobody can see"
        )
    }

    /// Escalating context re-fetches the same file at the wider width, and asks Git for that width.
    func testEscalatingContextRefetchesTheFileAtTheWiderWidth() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.diffSource.setPatch(for: "a.swift", text: Self.patch(path: "a.swift"))
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)

        harness.sync(tabID: tab)
        await harness.viewModel.settle()
        guard let row = harness.unstagedRow("a.swift") else { return XCTFail("Expected a row") }
        XCTAssertEqual(harness.diffSource.requestedContextLines, [3])

        harness.viewModel.escalateContext(for: row)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.diffSource.requestedContextLines, [3, 12])
        XCTAssertEqual(harness.viewModel.contextLevel(for: row), .expanded)
    }

    func testFingerprintChangeReloadsTheRemainingPartiallyStagedPatch() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(
            checkout: repoA,
            entries: [
                VCSIndexStatusEntry(
                    path: "partial.swift",
                    indexStatus: "M",
                    workTreeStatus: "M"
                )
            ]
        )
        harness.diffSource.setPatch(for: "partial.swift", text: Self.patch(path: "partial.swift"))
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()
        let initialPatchCallCount = harness.diffSource.patchCallCount
        XCTAssertEqual(initialPatchCallCount, 2, "Both halves of a partial file are initially projected")

        harness.backend.setEntries(
            [VCSIndexStatusEntry(path: "partial.swift", indexStatus: "M", workTreeStatus: ".")],
            at: repoA
        )
        harness.diffSource.setStatusHash("index-moved")
        await harness.repository.refresh(.mutationCompleted)
        await harness.viewModel.settle()

        XCTAssertEqual(
            harness.diffSource.patchCallCount,
            initialPatchCallCount + 1,
            "Index-only movement changes the staged patch even when row ID and content revision do not"
        )
    }

    func testSlowPatchFromPreviousCheckoutCannotSatisfyTheNewCheckoutKey() async {
        let harness = makeHarness()
        let tabA = UUID()
        let tabB = UUID()
        harness.configure(checkout: repoA, entries: [modified("same.swift")])
        harness.configure(checkout: repoB, entries: [modified("same.swift")])
        harness.diffSource.setPatch(
            for: "same.swift",
            at: repoA,
            text: Self.patch(path: "same.swift")
        )
        harness.diffSource.setPatch(
            for: "same.swift",
            at: repoB,
            text: Self.patch(path: "same.swift").replacingOccurrences(of: "22", with: "33")
        )
        harness.diffSource.holdPatches(at: repoA)
        harness.environment.setRoots([(repoA, UUID())], forTab: tabA)
        harness.environment.setRoots([(repoB, UUID())], forTab: tabB)

        harness.sync(tabID: tabA)
        await waitUntil("checkout A's patch read to suspend") {
            harness.diffSource.heldPatchWaiterCount == 1
        }
        harness.sync(tabID: tabB)
        await waitUntil("checkout B's patch to load") {
            guard let row = harness.unstagedRow("same.swift"),
                  let document = harness.viewModel.patchState(for: row).document
            else { return false }
            return document.hunks.flatMap(\.lines).contains { $0.text.contains("33") }
        }

        harness.diffSource.releasePatches(at: repoA)
        await harness.viewModel.settle()

        let row = try? XCTUnwrap(harness.unstagedRow("same.swift"))
        let document = row.flatMap { harness.viewModel.patchState(for: $0).document }
        XCTAssertTrue(document?.hunks.flatMap(\.lines).contains { $0.text.contains("33") } == true)
        XCTAssertFalse(document?.hunks.flatMap(\.lines).contains { $0.text.contains("22") } == true)
    }

    // MARK: - Staging

    /// A click shows the state the user asked for, disables exactly that path and the aggregates
    /// that overlap it, and moves nothing until Git agrees.
    func testAStagingClickIsPendingLocallyAndMovesNoRowsUntilGitAgrees() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift"), modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let rowA = harness.unstagedRow("a.swift"), let rowB = harness.unstagedRow("b.swift") else {
            return XCTFail("Expected both files in the unstaged section")
        }
        harness.backend.holdStageCalls()
        harness.viewModel.setStaged(true, row: rowA)

        XCTAssertEqual(harness.viewModel.pendingStaging(for: rowA)?.requestedStage, true)
        XCTAssertTrue(harness.viewModel.isStagedForDisplay(rowA), "The checkbox shows the request immediately")
        XCTAssertTrue(harness.viewModel.isMutationDisabled(rowA))
        XCTAssertFalse(harness.viewModel.isMutationDisabled(rowB), "A mutation elsewhere leaves other rows clickable")
        XCTAssertTrue(harness.viewModel.isBulkActionDisabled(for: .unstaged))
        XCTAssertEqual(
            harness.unstagedPaths,
            ["a.swift", "b.swift"],
            "No optimistic section move: the row stays where porcelain last put it"
        )

        harness.backend.releaseStageCalls()
        await harness.viewModel.settle()

        XCTAssertNil(harness.viewModel.pendingStaging(for: rowA))
        XCTAssertEqual(harness.stagedPaths, ["a.swift"])
        XCTAssertEqual(harness.unstagedPaths, ["b.swift"])
        XCTAssertFalse(harness.viewModel.isBulkActionDisabled(for: .unstaged))
    }

    /// The spinner appears only once the mutation outlives its grace period. A spinner on every
    /// click — most of which finish in a few milliseconds — reads as a stutter, not as progress.
    func testTheSpinnerWaitsOutTheGracePeriodBeforeAppearing() async {
        let scheduler = PanelManualScheduler()
        let harness = makeHarness(viewModelScheduler: scheduler)
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let row = harness.unstagedRow("a.swift") else { return XCTFail("Expected a row") }
        harness.backend.holdStageCalls()
        harness.viewModel.setStaged(true, row: row)

        XCTAssertEqual(harness.viewModel.pendingStaging(for: row)?.showsSpinner, false)

        scheduler.releaseAll()
        await waitUntil("the grace period elapses") {
            harness.viewModel.pendingStaging(for: row)?.showsSpinner == true
        }

        harness.backend.releaseStageCalls()
        await harness.viewModel.settle()
        XCTAssertNil(harness.viewModel.pendingStaging(for: row))
    }

    /// A file edited between the render and the click is refreshed rather than staged, and the row
    /// flashes so the click does not look ignored.
    func testContentChangedRefreshesAndFlashesInsteadOfStagingUnreviewedContent() async {
        // A scheduler that never fires keeps the flash on screen for the assertion, the same way a
        // real one keeps it there for the user.
        let harness = makeHarness(viewModelScheduler: PanelManualScheduler())
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let row = harness.unstagedRow("a.swift") else { return XCTFail("Expected a row") }
        // The agent writes the file again between the render the user reviewed and the click.
        await harness.repository.refresh(.contentDelta(paths: [repoA + "/a.swift"]))
        await harness.repository.waitUntilIdle()

        harness.viewModel.setStaged(true, row: row)
        await harness.viewModel.settle()

        XCTAssertTrue(harness.backend.stagedPathBatches.isEmpty, "Nothing unreviewed reached the index")
        XCTAssertEqual(harness.viewModel.statusMessage?.isFailure, false)
        XCTAssertEqual(
            harness.viewModel.statusMessage?.text.contains("changed on disk"),
            true,
            "The panel explains why the row did not move"
        )
        XCTAssertTrue(harness.viewModel.isFlashing(row))
    }

    /// Conflicts get a checkbox that is present and refused; a read-only vs-Base list gets none at
    /// all, because there is no index behind it to mutate.
    func testConflictsAreRefusedAndReadOnlyListsHaveNoCheckboxes() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [conflicted("merge.swift"), modified("a.swift")])
        harness.diffSource.setPatch(for: "a.swift", text: Self.patch(path: "a.swift"))
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let conflict = harness.row(section: .conflicts, path: "merge.swift") else {
            return XCTFail("Expected a conflicted row")
        }
        XCTAssertTrue(harness.viewModel.showsStagingCheckbox(for: conflict))
        XCTAssertTrue(harness.viewModel.isMutationDisabled(conflict))
        harness.viewModel.setStaged(true, row: conflict)
        await harness.viewModel.settle()
        XCTAssertTrue(harness.backend.stagedPathBatches.isEmpty, "A refused checkbox reaches no backend")

        harness.environment.selectBaseBranch("main", forRepoRoot: repoA, tabID: tab)
        harness.environment.setCompareSelection(.vsBase, tabID: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let vsBaseRow = harness.row(section: .vsBase, path: "a.swift") else {
            return XCTFail("Expected a vs-Base row")
        }
        XCTAssertFalse(harness.viewModel.snapshot.supportsStaging)
        XCTAssertFalse(harness.viewModel.showsStagingCheckbox(for: vsBaseRow))
    }

    // MARK: - Viewed, filters, and conflict resolution

    func testViewedCollapsesTheFileAndAutomaticallyClearsAfterItsRevisionChanges() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift"), modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let reviewed = harness.unstagedRow("a.swift") else { return XCTFail("Expected a row") }
        XCTAssertTrue(harness.viewModel.isExpanded(reviewed), "The first file starts expanded")

        harness.viewModel.setViewed(true, for: reviewed)

        XCTAssertFalse(harness.viewModel.isExpanded(reviewed), "Viewed files collapse")
        XCTAssertEqual(harness.viewModel.viewedStatus(for: reviewed), .viewed)
        XCTAssertEqual(
            harness.viewModel.viewedProgress,
            AgentChangesViewedProgress(viewedFileCount: 1, totalFileCount: 2)
        )

        await harness.repository.refresh(.contentDelta(paths: [repoA + "/a.swift"]))
        await harness.viewModel.settle()
        guard let edited = harness.unstagedRow("a.swift") else { return XCTFail("Expected refreshed row") }

        XCTAssertEqual(harness.viewModel.viewedStatus(for: edited), .editedSinceViewed)
        XCTAssertEqual(harness.viewModel.viewedProgress.viewedFileCount, 0)
    }

    func testFilterPillsProjectSectionsWithoutChangingRepositoryState() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [
            VCSIndexStatusEntry(path: "staged.swift", indexStatus: "M", workTreeStatus: "."),
            modified("working.swift"),
            conflicted("merge.swift")
        ])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertTrue(harness.viewModel.showsFilterPills)
        XCTAssertEqual(
            harness.viewModel.filterCounts,
            AgentChangesFilterCounts(all: 3, staged: 1, unstaged: 1, conflicts: 1)
        )

        harness.viewModel.selectFilter(.staged)
        XCTAssertEqual(harness.viewModel.visibleSections.map(\.kind), [.staged])
        XCTAssertEqual(harness.viewModel.visibleSections.flatMap(\.rows).map(\.path), ["staged.swift"])
        XCTAssertEqual(harness.environment.state(forTab: tab).changesFilter, .staged)
        XCTAssertTrue(harness.backend.stagedPathBatches.isEmpty, "Filtering is presentation-only")
    }

    func testMarkResolvedHasRowLocalPendingStateAndRefreshesTheConflictAway() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [conflicted("merge.swift"), modified("other.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let conflict = harness.row(section: .conflicts, path: "merge.swift"),
              let other = harness.unstagedRow("other.swift")
        else { return XCTFail("Expected conflict and bystander") }
        XCTAssertNil(harness.viewModel.markResolvedDisabledReason(for: conflict))

        harness.backend.holdStageCalls()
        harness.viewModel.markResolved(conflict)

        XCTAssertNotNil(harness.viewModel.pendingResolution(for: conflict))
        XCTAssertNotNil(harness.viewModel.markResolvedDisabledReason(for: conflict))
        XCTAssertFalse(harness.viewModel.isMutationDisabled(other), "An unrelated row stays interactive")
        XCTAssertTrue(harness.viewModel.isBulkActionDisabled(for: .unstaged))

        harness.backend.releaseStageCalls()
        await harness.viewModel.settle()

        XCTAssertNil(harness.viewModel.pendingResolution(for: conflict))
        XCTAssertEqual(harness.backend.resolvedPathBatches, [["merge.swift"]])
        XCTAssertNil(harness.row(section: .conflicts, path: "merge.swift"))
        XCTAssertEqual(harness.stagedPaths, ["merge.swift"])
    }

    func testMarkResolvedPreflightRefreshesInsteadOfResolvingEditedContents() async {
        let harness = makeHarness(viewModelScheduler: PanelManualScheduler())
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [conflicted("merge.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()
        guard let reviewed = harness.row(section: .conflicts, path: "merge.swift") else {
            return XCTFail("Expected conflict")
        }

        await harness.repository.refresh(.contentDelta(paths: [repoA + "/merge.swift"]))
        await harness.repository.waitUntilIdle()
        harness.viewModel.markResolved(reviewed)
        await harness.viewModel.settle()

        XCTAssertTrue(harness.backend.resolvedPathBatches.isEmpty)
        XCTAssertEqual(harness.viewModel.statusMessage?.isFailure, false)
        XCTAssertTrue(harness.viewModel.statusMessage?.text.contains("changed on disk") == true)
    }

    // MARK: - Compare selection

    /// A clean working tree offers the vs-Base bridge, and taking it asks for a base rather than
    /// picking one. Decision row 1 forbids inferring a default branch, and an inferred base looks
    /// exactly like a chosen one once the diff is on screen.
    func testTheCleanTreeBridgeSwitchesToVsBaseAndThenAsksForABase() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.emptyState, .cleanTree(offersBaseComparison: true))

        harness.viewModel.offerBaseComparison()
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.environment.state(forTab: tab).compareSelection, .vsBase)
        XCTAssertNil(harness.environment.state(forTab: tab).baseBranchOverride)
        XCTAssertEqual(harness.viewModel.emptyState, .baseNotChosen)
        XCTAssertNil(harness.viewModel.snapshot.target, "No compare means no target, not a stale one")
    }

    /// A base branch means something only inside one repository, so switching the active repository
    /// re-reads this tab's repo-scoped memory instead of carrying a branch name across.
    func testTheBaseBranchIsScopedToTheRepositoryItWasChosenFor() async {
        let harness = makeHarness()
        let tab = UUID()
        let rootA = UUID()
        let rootB = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.configure(checkout: repoB, entries: [modified("b.swift")])
        harness.environment.setRoots([(repoA, rootA), (repoB, rootB)], forTab: tab)
        harness.environment.setCompareSelection(.vsBase, tabID: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        harness.viewModel.selectBaseBranch("release/1.0")
        harness.sync(tabID: tab)
        await harness.viewModel.settle()
        XCTAssertEqual(harness.environment.state(forTab: tab).baseBranchOverride, "release/1.0")

        guard let second = harness.viewModel.availableTargets.first(where: { $0.checkoutURL.path == repoB }) else {
            return XCTFail("Expected both repositories to resolve")
        }
        harness.viewModel.selectRoot(second)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertNil(
            harness.environment.state(forTab: tab).baseBranchOverride,
            "A branch the user picked for another repository is not a base for this one"
        )
        XCTAssertEqual(harness.viewModel.emptyState, .baseNotChosen)

        harness.viewModel.selectBaseBranch("main")
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        guard let first = harness.viewModel.availableTargets.first(where: { $0.checkoutURL.path == repoA }) else {
            return XCTFail("Expected the first repository to still resolve")
        }
        harness.viewModel.selectRoot(first)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(
            harness.environment.state(forTab: tab).baseBranchOverride,
            "release/1.0",
            "Coming back re-offers the base this tab already chose for that repository"
        )
    }

    /// The base picker has to be populated in the very state whose purpose is to ask for a base.
    /// Loading its branches off the compare target would leave it empty exactly then, because
    /// vs-Base without a base resolves to no compare and so to no target at all.
    func testTheBasePickerIsPopulatedBeforeABaseIsChosen() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.branchesByCheckout[repoA] = ["main", "release/1.0"]
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.environment.setCompareSelection(.vsBase, tabID: tab)

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.emptyState, .baseNotChosen)
        XCTAssertEqual(harness.viewModel.baseBranchCandidates, ["main", "release/1.0"])
    }

    func testCustomRevisionValidationAcceptsOnlyValidInputAndKeepsTheLastGoodBase() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.environment.setCompareSelection(.vsBase, tabID: tab)
        harness.diffSource.setRevisionValidation(
            .valid(objectID: String(repeating: "a", count: 40)),
            for: "HEAD~3"
        )
        harness.diffSource.setRevisionValidation(.invalid("No such revision"), for: "missing")
        harness.diffSource.setRevisionValidation(.ambiguous("Revision is ambiguous"), for: "abc")
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        harness.viewModel.beginCustomRevisionEntry()
        harness.viewModel.updateCustomRevisionText("HEAD~3")
        harness.viewModel.submitCustomRevision()
        await harness.viewModel.settle()

        XCTAssertEqual(harness.environment.state(forTab: tab).baseBranchOverride, "HEAD~3")
        XCTAssertEqual(
            harness.environment.state(forTab: tab).lastUsedBaseBranch(forRepoRoot: repoA),
            "HEAD~3"
        )
        XCTAssertNil(harness.viewModel.customRevisionEditor)

        harness.viewModel.beginCustomRevisionEntry()
        harness.viewModel.updateCustomRevisionText("missing")
        harness.viewModel.submitCustomRevision()
        await harness.viewModel.settle()
        XCTAssertEqual(harness.environment.state(forTab: tab).baseBranchOverride, "HEAD~3")
        XCTAssertEqual(harness.viewModel.customRevisionEditor?.errorMessage, "No such revision")

        harness.viewModel.updateCustomRevisionText("abc")
        harness.viewModel.submitCustomRevision()
        await harness.viewModel.settle()
        XCTAssertEqual(harness.environment.state(forTab: tab).baseBranchOverride, "HEAD~3")
        XCTAssertEqual(harness.viewModel.customRevisionEditor?.errorMessage, "Revision is ambiguous")
    }

    // MARK: - Worktree fallback

    /// A bound worktree that is not on disk blocks the root instead of quietly reading the
    /// workspace checkout. The panel mutates a Git index, and a staging click aimed at the wrong
    /// working tree stages the user's own edits believing they are the agent's. The substitution
    /// exists, but only as something the user asks for by name — and it stays visible afterwards.
    func testAnUnavailableWorktreeIsSubstitutedOnlyWhenTheUserAsks() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots(
            [(repoA, UUID())],
            forTab: tab,
            bindings: [Self.binding(logicalRootPath: repoA, worktreeRootPath: "/tmp/agent-changes-panel-gone")]
        )

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertNil(harness.viewModel.activeTarget, "A missing worktree never falls back on its own")
        guard let blocked = harness.viewModel.blockedCheckouts.first else {
            return XCTFail("Expected the bound root to be reported as blocked")
        }
        XCTAssertTrue(blocked.reason.allowsWorkspaceCheckoutOverride)

        harness.viewModel.showWorkspaceCheckoutInstead(for: blocked)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.activeTarget?.checkoutURL.path, repoA)
        XCTAssertEqual(harness.unstagedPaths, ["a.swift"])
        XCTAssertTrue(
            harness.viewModel.isSubstitutingWorkspaceCheckout,
            "The warning chip persists for the rest of the session, because the substitution does"
        )
    }

    func testRefreshSpinnerWaitsForRootResolutionAndRetarget() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        harness.environment.holdRootInputs(forTab: tab)
        harness.viewModel.refresh()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertTrue(
            harness.viewModel.isRefreshing,
            "Refresh cannot finish against the old target while the new resolve is still pending"
        )

        harness.environment.releaseRootInputs(forTab: tab)
        await harness.viewModel.settle()
        XCTAssertFalse(harness.viewModel.isRefreshing)
        XCTAssertEqual(harness.viewModel.snapshot.target?.checkoutURL.path, repoA)
    }

    // MARK: - Artifact banner

    /// The banner resolves the agent's raw payload path into a reference the Preview segment can
    /// address, and opening it hands over through tab state alone.
    func testTheArtifactBannerResolvesToAPreviewReferenceAndSwitchesSegment() async {
        let harness = makeHarness()
        let tab = UUID()
        let rootID = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, rootID)], forTab: tab)
        harness.environment.setItems(
            [AgentEditToolPayloadFixtures.editOverwrittenHTMLRelativePath.item()],
            forTab: tab
        )

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        let expected = PreviewDocumentReference(rootID: rootID, relativePath: "docs/coverage.html")
        XCTAssertEqual(harness.viewModel.bannerLink?.document, expected)
        XCTAssertEqual(harness.viewModel.bannerLink?.artifact.fileName, "coverage.html")

        harness.viewModel.viewBannerArtifact()
        XCTAssertEqual(harness.environment.state(forTab: tab).previewDocument, expected)
        XCTAssertEqual(
            harness.environment.state(forTab: tab).segment,
            .preview,
            "The deep link reveals the document rather than retargeting Preview invisibly"
        )

        guard let artifactID = harness.viewModel.bannerLink?.artifact.id else {
            return XCTFail("Expected a banner artifact to dismiss")
        }
        harness.viewModel.dismissBannerArtifact()
        XCTAssertNil(harness.viewModel.bannerLink)
        XCTAssertTrue(harness.environment.state(forTab: tab).isBannerDismissed(artifactID: artifactID))
    }

    /// A document written outside every known root produces no banner: the panel does not offer to
    /// open something it cannot address.
    func testAnArtifactOutsideEveryRootProducesNoBanner() async {
        let harness = makeHarness()
        let tab = UUID()
        harness.configure(checkout: repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], forTab: tab)
        harness.environment.setItems(
            [AgentEditToolPayloadFixtures.editCreatedMarkdown.item()],
            forTab: tab
        )

        harness.sync(tabID: tab)
        await harness.viewModel.settle()

        XCTAssertNil(harness.viewModel.bannerLink)
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let viewModel: AgentChangesPanelViewModel
        let repository: AgentChangesRepository
        let environment: PanelFakeEnvironment
        let backend: PanelFakeIndexBackend
        let diffSource: PanelFakeDiffSource
        let probe: PanelFakeProbe

        func sync(tabID: UUID) {
            viewModel.sync(tabID: tabID, panel: environment.state(forTab: tabID))
        }

        func configure(checkout: String, entries: [VCSIndexStatusEntry]) {
            probe.addRepository(checkout)
            backend.setEntries(entries, at: checkout)
        }

        var unstagedPaths: [String] {
            viewModel.snapshot.section(.unstaged)?.rows.map(\.path) ?? []
        }

        var stagedPaths: [String] {
            viewModel.snapshot.section(.staged)?.rows.map(\.path) ?? []
        }

        func unstagedRow(_ path: String) -> AgentChangesFileRow? {
            row(section: .unstaged, path: path)
        }

        func row(section: AgentChangesSectionKind, path: String) -> AgentChangesFileRow? {
            viewModel.snapshot.section(section)?.rows.first { $0.path == path }
        }
    }

    private func makeHarness(
        viewModelScheduler: (any AgentChangesScheduler)? = nil
    ) -> Harness {
        let backend = PanelFakeIndexBackend()
        let diffSource = PanelFakeDiffSource()
        let probe = PanelFakeProbe()
        let environment = PanelFakeEnvironment()
        let repository = AgentChangesRepository(
            indexBackend: backend,
            diffSource: diffSource,
            invalidationPublisher: PanelInertInvalidationPublisher(),
            scheduler: PanelImmediateScheduler(),
            contentDeltaWindow: .zero,
            makeTriggerFeed: { _ in PanelInertTriggerFeed() }
        )
        let viewModel = AgentChangesPanelViewModel(
            environment: environment,
            repository: repository,
            probe: probe,
            scheduler: viewModelScheduler ?? PanelImmediateScheduler(),
            stagingGrace: .zero,
            flashDuration: .seconds(60)
        )
        return Harness(
            viewModel: viewModel,
            repository: repository,
            environment: environment,
            backend: backend,
            diffSource: diffSource,
            probe: probe
        )
    }

    /// Yields until a condition holds, for the two places where work is deliberately concurrent.
    private func waitUntil(
        _ description: String,
        attempts: Int = 500,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private static func binding(logicalRootPath: String, worktreeRootPath: String) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(logicalRootPath)",
            repositoryID: "repo",
            repoKey: "key",
            logicalRootPath: logicalRootPath,
            worktreeID: "worktree",
            worktreeRootPath: worktreeRootPath,
            branch: "agent/panel",
            boundAt: Date(timeIntervalSince1970: 0),
            source: "test"
        )
    }

    private func modified(_ path: String) -> VCSIndexStatusEntry {
        VCSIndexStatusEntry(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private func conflicted(_ path: String) -> VCSIndexStatusEntry {
        VCSIndexStatusEntry(
            path: path,
            indexStatus: "U",
            workTreeStatus: "U",
            isUntracked: false,
            isConflicted: true
        )
    }

    private static func patch(path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 22
         let c = 3
        """
    }
}

// MARK: - Environment fake

/// A tab's world: its roots, its transcript, and the panel state it owns.
///
/// Holds the canonical `AgentUtilityPanelTabState` the way `TabSession` does, so a test can assert
/// on what the controller actually wrote rather than on what it remembers writing.
@MainActor
private final class PanelFakeEnvironment: AgentChangesPanelEnvironment {
    private var inputsByTab: [UUID: AgentChangesPanelRootInputs] = [:]
    private var itemSubjectsByTab: [UUID: CurrentValueSubject<[AgentChatItem], Never>] = [:]
    private var statesByTab: [UUID: AgentUtilityPanelTabState] = [:]
    private var heldRootInputTabs: Set<UUID> = []
    private var rootInputWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var branchesByCheckout: [String: [String]] = [:]

    func setRoots(
        _ roots: [(String, UUID)],
        forTab tabID: UUID,
        bindings: [AgentSessionWorktreeBinding] = [],
        isPreparingWorktree: Bool = false
    ) {
        inputsByTab[tabID] = AgentChangesPanelRootInputs(
            logicalRoots: roots.map { AgentPanelLogicalRoot(path: $0.0) },
            rootIDsByPath: Dictionary(roots.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }),
            worktreeBindings: bindings,
            isPreparingWorktree: isPreparingWorktree,
            watchedRootPaths: roots.map(\.0)
        )
    }

    func holdRootInputs(forTab tabID: UUID) {
        heldRootInputTabs.insert(tabID)
    }

    func releaseRootInputs(forTab tabID: UUID) {
        heldRootInputTabs.remove(tabID)
        let waiters = rootInputWaiters.removeValue(forKey: tabID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func setItems(_ items: [AgentChatItem], forTab tabID: UUID) {
        if let subject = itemSubjectsByTab[tabID] {
            subject.send(items)
        } else {
            itemSubjectsByTab[tabID] = CurrentValueSubject(items)
        }
    }

    func state(forTab tabID: UUID) -> AgentUtilityPanelTabState {
        statesByTab[tabID] ?? AgentUtilityPanelTabState()
    }

    private func mutate(_ tabID: UUID?, _ body: (inout AgentUtilityPanelTabState) -> Void) {
        guard let tabID else { return }
        var state = statesByTab[tabID] ?? AgentUtilityPanelTabState()
        body(&state)
        statesByTab[tabID] = state
    }

    // MARK: Reads

    func rootInputs(tabID: UUID?) async -> AgentChangesPanelRootInputs {
        guard let tabID else { return .empty }
        if heldRootInputTabs.contains(tabID) {
            await withCheckedContinuation { continuation in
                if heldRootInputTabs.contains(tabID) {
                    rootInputWaiters[tabID, default: []].append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        return inputsByTab[tabID] ?? .empty
    }

    func transcriptItems(tabID: UUID?) -> [AgentChatItem] {
        guard let tabID else { return [] }
        return itemSubjectsByTab[tabID]?.value ?? []
    }

    func transcriptItemsPublisher(tabID: UUID?) -> AnyPublisher<[AgentChatItem], Never>? {
        guard let tabID else { return nil }
        return itemSubjectsByTab[tabID]?.eraseToAnyPublisher()
    }

    func baseBranchCandidates(at checkout: URL) async -> [String] {
        branchesByCheckout[checkout.path] ?? []
    }

    // MARK: Writes

    func selectRootOverride(_ rootID: UUID?, tabID: UUID?) {
        mutate(tabID) { $0.selectRootOverride(rootID) }
    }

    func setCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID?) {
        mutate(tabID) { $0.setCompareSelection(selection) }
    }

    func setDiffViewMode(_ mode: AgentChangesDiffViewMode, tabID: UUID?) {
        mutate(tabID) { $0.setDiffViewMode(mode) }
    }

    func setChangesFilter(_ filter: AgentChangesFilter, tabID: UUID?) {
        mutate(tabID) { $0.setChangesFilter(filter) }
    }

    func selectBaseBranch(_ branch: String?, forRepoRoot repoRoot: String, tabID: UUID?) {
        mutate(tabID) { $0.selectBaseBranch(branch, forRepoRoot: repoRoot) }
    }

    func lastUsedBaseBranch(forRepoRoot repoRoot: String, tabID: UUID?) -> String? {
        guard let tabID else { return nil }
        return state(forTab: tabID).lastUsedBaseBranch(forRepoRoot: repoRoot)
    }

    func setFileExpansion(_ isExpanded: Bool, filePath: String, tabID: UUID?) {
        mutate(tabID) { $0.setExpansion(isExpanded, ofFilePath: filePath) }
    }

    func setFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFilePath: String?,
        tabID: UUID?
    ) {
        mutate(tabID) { state in
            state.setViewed(viewed, revision: revision, compareTargetKey: compareTargetKey)
            if let collapseFilePath {
                state.setExpansion(false, ofFilePath: collapseFilePath)
            }
        }
    }

    @discardableResult
    func escalateContext(filePath: String, tabID: UUID?) -> AgentChangesContextLevel {
        var level = AgentChangesContextLevel.standard
        mutate(tabID) { level = $0.escalateContext(forFilePath: filePath) }
        return level
    }

    func showPreview(of document: PreviewDocumentReference, tabID: UUID?) {
        mutate(tabID) { $0.showPreview(of: document) }
    }

    func dismissBanner(artifactID: String, tabID: UUID?) {
        mutate(tabID) { $0.dismissBanner(artifactID: artifactID) }
    }
}

// MARK: - Checkout probe fake

/// Filesystem and VCS answers without either.
private final class PanelFakeProbe: AgentPanelCheckoutProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String> = []
    private var repositories: Set<String> = []

    func addDirectory(_ path: String) {
        lock.withLock { _ = directories.insert(path) }
    }

    func addRepository(_ path: String) {
        lock.withLock {
            _ = directories.insert(path)
            _ = repositories.insert(path)
        }
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        lock.withLock { directories.contains(path) ? .directory : .missing }
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            repositories.contains(path) ? VCSResolvedRepo(rootURL: url, backendKind: .git) : nil
        }
    }
}

// MARK: - Repository fakes

private struct PanelImmediateScheduler: AgentChangesScheduler {
    func sleep(for _: Duration) async throws {
        await Task.yield()
    }
}

/// A scheduler whose sleeps only finish when a test says so, for asserting on the staging grace
/// period without spending it.
private final class PanelManualScheduler: AgentChangesScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isReleased = true
            let waiting = waiters
            waiters = []
            return waiting
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func sleep(for _: Duration) async throws {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                guard !isReleased else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private struct PanelInertTriggerFeed: AgentChangesTriggerFeed {
    func events() -> AsyncStream<AgentChangesRefreshTrigger> {
        AsyncStream { $0.finish() }
    }

    func cancel() {}
}

private struct PanelInertInvalidationPublisher: AgentChangesInvalidationPublishing {
    func publishIndexMutation(at _: URL) async {}
}

/// An in-memory index that behaves enough like Git for the panel's staging rules to be exercised,
/// with a gate so a test can inspect the world while a mutation is genuinely in flight.
private final class PanelFakeIndexBackend: AgentChangesIndexBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var entriesByCheckout: [String: [VCSIndexStatusEntry]] = [:]
    private var stagedBatches: [[String]] = []
    private var resolvedBatches: [[String]] = []
    private var isHoldingStage = false
    private var stageWaiters: [CheckedContinuation<Void, Never>] = []

    var stagedPathBatches: [[String]] {
        lock.withLock { stagedBatches }
    }

    var resolvedPathBatches: [[String]] {
        lock.withLock { resolvedBatches }
    }

    func setEntries(_ entries: [VCSIndexStatusEntry], at checkout: String) {
        lock.withLock { entriesByCheckout[checkout] = entries }
    }

    func holdStageCalls() {
        lock.withLock { isHoldingStage = true }
    }

    func releaseStageCalls() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isHoldingStage = false
            let waiting = stageWaiters
            stageWaiters = []
            return waiting
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func capabilities(at _: URL) async -> VCSCapabilities {
        .git
    }

    func hasHeadCommit(at _: URL) async throws -> Bool {
        true
    }

    func loadIndexStatus(at checkout: URL) async throws -> [VCSIndexStatusEntry] {
        lock.withLock { entriesByCheckout[checkout.standardizedFileURL.path] ?? [] }
    }

    func stage(_ identities: [VCSIndexPathIdentity], at checkout: URL) async throws {
        await waitIfHolding()
        lock.withLock { stagedBatches.append(identities.map(\.path)) }
        mutate(identities, at: checkout) { entry in
            VCSIndexStatusEntry(
                path: entry.path,
                originalPath: entry.originalPath,
                indexStatus: entry.isUntracked ? "A" : (entry.workTreeStatus ?? "M"),
                workTreeStatus: ".",
                isUntracked: false,
                isConflicted: entry.isConflicted
            )
        }
    }

    func unstage(_ identities: [VCSIndexPathIdentity], at checkout: URL) async throws {
        mutate(identities, at: checkout) { entry in
            VCSIndexStatusEntry(
                path: entry.path,
                originalPath: entry.originalPath,
                indexStatus: ".",
                workTreeStatus: entry.workTreeStatus == "." ? entry.indexStatus : entry.workTreeStatus,
                isUntracked: false,
                isConflicted: entry.isConflicted
            )
        }
    }

    func markResolved(_ identity: VCSIndexPathIdentity, at checkout: URL) async throws {
        await waitIfHolding()
        lock.withLock { resolvedBatches.append([identity.path]) }
        mutate([identity], at: checkout) { entry in
            VCSIndexStatusEntry(
                path: entry.path,
                originalPath: entry.originalPath,
                indexStatus: "M",
                workTreeStatus: ".",
                isUntracked: false,
                isConflicted: false
            )
        }
    }

    private func waitIfHolding() async {
        let holding: Bool = lock.withLock { isHoldingStage }
        guard holding else { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                guard isHoldingStage else { return true }
                stageWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func mutate(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        transform: (VCSIndexStatusEntry) -> VCSIndexStatusEntry
    ) {
        lock.withLock {
            let key = checkout.standardizedFileURL.path
            guard var entries = entriesByCheckout[key] else { return }
            for identity in identities {
                guard let index = entries.firstIndex(where: { $0.path == identity.path }) else { continue }
                entries[index] = transform(entries[index])
            }
            entriesByCheckout[key] = entries
        }
    }
}

private final class PanelFakeDiffSource: AgentChangesDiffSource, @unchecked Sendable {
    private let lock = NSLock()
    private var patchesByPath: [String: String] = [:]
    private var patchesByCheckout: [String: [String: String]] = [:]
    private var heldPatchCheckouts: Set<String> = []
    private var patchWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var patchCalls = 0
    private var contextLines: [Int] = []
    private var statusHash = "initial"
    private var revisionValidations: [String: AgentChangesRevisionValidation] = [:]

    var patchCallCount: Int {
        lock.withLock { patchCalls }
    }

    var requestedContextLines: [Int] {
        lock.withLock { contextLines }
    }

    var heldPatchWaiterCount: Int {
        lock.withLock { patchWaiters.values.reduce(0) { $0 + $1.count } }
    }

    func setPatch(for path: String, text: String) {
        lock.withLock { patchesByPath[path] = text }
    }

    func setPatch(for path: String, at checkout: String, text: String) {
        lock.withLock {
            patchesByCheckout[checkout, default: [:]][path] = text
        }
    }

    func setStatusHash(_ value: String) {
        lock.withLock { statusHash = value }
    }

    func holdPatches(at checkout: String) {
        lock.withLock { _ = heldPatchCheckouts.insert(checkout) }
    }

    func releasePatches(at checkout: String) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            heldPatchCheckouts.remove(checkout)
            return patchWaiters.removeValue(forKey: checkout) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func setRevisionValidation(_ validation: AgentChangesRevisionValidation, for revision: String) {
        lock.withLock { revisionValidations[revision] = validation }
    }

    func resolveRevision(_ revision: String, at _: URL) async -> AgentChangesRevisionValidation {
        lock.withLock { revisionValidations[revision] ?? .invalid("Unknown revision") }
    }

    func fingerprint(compare _: GitDiffCompareSpec, at _: URL) async throws -> GitDiffFingerprint {
        lock.withLock { fingerprintLocked() }
    }

    func loadMetadata(
        compare _: GitDiffCompareSpec,
        pathspecs _: [String],
        at _: URL
    ) async throws -> AgentChangesDiffMetadata {
        lock.withLock {
            AgentChangesDiffMetadata(
                fingerprint: fingerprintLocked(),
                files: patchesByPath.keys.sorted().map {
                    VCSUncommittedFile(path: $0, status: "M", additions: 1, deletions: 1)
                }
            )
        }
    }

    func loadPatch(
        compare _: GitDiffCompareSpec,
        paths: [String],
        at checkout: URL,
        contextLines requestedContext: Int
    ) async throws -> AgentChangesPatchPayload? {
        let checkoutPath = checkout.standardizedFileURL.path
        let shouldHold = lock.withLock { heldPatchCheckouts.contains(checkoutPath) }
        if shouldHold {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    guard heldPatchCheckouts.contains(checkoutPath) else { return true }
                    patchWaiters[checkoutPath, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        return lock.withLock {
            patchCalls += 1
            contextLines.append(requestedContext)
            guard let primary = paths.first,
                  let text = patchesByCheckout[checkoutPath]?[primary] ?? patchesByPath[primary]
            else { return nil }
            return AgentChangesPatchPayload(perFile: [primary: text], fingerprint: fingerprintLocked())
        }
    }

    func loadFileContent(
        source _: AgentChangesFileContentSource,
        at _: URL,
        byteLimit _: Int
    ) async throws -> AgentChangesFileContent {
        throw AgentChangesFileContentReadError.unavailable("No fake source content configured.")
    }

    private func fingerprintLocked() -> GitDiffFingerprint {
        GitDiffFingerprint(
            headSHA: "head",
            baseRef: "INDEX",
            statusHash: statusHash,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
