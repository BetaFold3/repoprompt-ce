import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentChangesPanelSearchViewModelTests: XCTestCase {
    private let repo = "/tmp/phase3-search"

    func testDebounceCancellationAndStaleGenerationPublishOnlyNewestQuery() async {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(scheduler: scheduler)
        let tab = UUID()
        harness.configure(repo, entries: [modified("alpha.swift")])
        harness.setPatch(
            Self.patch(path: "alpha.swift", replacement: "oldvalue newvalue"),
            path: "alpha.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        harness.viewModel.updateSearchQuery("oldvalue")
        await waitUntil("first debounce is pending") { scheduler.pendingCount == 1 }
        XCTAssertEqual(harness.viewModel.searchState.phase, .debouncing)

        harness.viewModel.updateSearchQuery("newvalue")
        await waitUntil("both old and new debounce tasks are controllable") {
            scheduler.pendingCount == 2
        }
        scheduler.releaseAll()

        await waitUntil("new search becomes ready") {
            harness.viewModel.searchState.phase == .ready
        }

        XCTAssertEqual(harness.viewModel.searchState.query, "newvalue")
        XCTAssertFalse(harness.viewModel.searchState.matches.isEmpty)
        for match in harness.viewModel.searchState.matches {
            XCTAssertEqual(substring(for: match), "newvalue")
        }
    }

    func testLeadingAndTrailingSpacesRemainLiteralSearchText() async {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repo, entries: [modified("spaced.swift"), modified("plain.swift")])
        harness.setPatch(
            Self.patch(path: "spaced.swift", replacement: "before needle after"),
            path: "spaced.swift",
            at: repo
        )
        harness.setPatch(
            Self.patch(path: "plain.swift", replacement: "needle"),
            path: "plain.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        harness.viewModel.updateSearchQuery(" needle ")
        await harness.viewModel.settle()

        XCTAssertFalse(harness.viewModel.searchState.matches.isEmpty)
        XCTAssertTrue(
            harness.viewModel.searchState.matches.allSatisfy {
                substring(for: $0) == " needle " && $0.rowKey.rowID.contains("spaced.swift")
            }
        )
    }

    func testIncrementalBatchPublicationPreservesTheSelectedMatchIdentity() async throws {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(scheduler: scheduler)
        let tab = UUID()
        let paths = (0 ..< 8).map { "needle-\($0).swift" }
        harness.configure(repo, entries: paths.map(modified))
        for path in paths {
            harness.setPatch(
                Self.patch(path: path, replacement: "needle body"),
                path: path,
                at: repo
            )
        }
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)
        harness.diffSource.resetPatchMetrics()
        // Held per request rather than in bulk, so the first batch can publish while the second is
        // still in flight. Paths and patches are admitted together now, so there is nothing to
        // select until a batch has actually landed.
        harness.diffSource.holdNextPatchLoads(8)

        harness.viewModel.updateSearchQuery("needle")
        await waitUntil("search debounce is pending") {
            scheduler.pendingCount == 1
        }
        scheduler.releaseNext()
        await waitUntil("first patch batch is held") {
            harness.diffSource.heldPatchLoadCount == 4
        }
        for _ in 0 ..< 4 {
            harness.diffSource.releaseHeldPatchLoad(at: 0)
        }
        await waitUntil("second patch batch is held after the first publication") {
            harness.diffSource.heldPatchLoadCount == 4
        }
        XCTAssertEqual(harness.viewModel.searchState.phase, .loading)
        let firstBatchMatches = harness.viewModel.searchState.matches
        XCTAssertGreaterThan(firstBatchMatches.count, 3)
        harness.viewModel.selectSearchMatch(at: 3)
        let selectedID = try XCTUnwrap(harness.viewModel.searchState.selectedMatch?.id)

        for _ in 0 ..< 4 {
            harness.diffSource.releaseHeldPatchLoad(at: 0)
        }
        await waitUntil("incremental search completes") {
            harness.viewModel.searchState.phase == .ready
        }

        XCTAssertEqual(harness.viewModel.searchState.selectedMatch?.id, selectedID)
        XCTAssertNotEqual(harness.viewModel.searchState.selectedMatchIndex, 0)
        XCTAssertGreaterThan(
            harness.viewModel.searchState.matches.count,
            firstBatchMatches.count,
            "Later corpus rows extend the published results without disturbing the selection"
        )
    }

    func testPatchReadsAreLimitedToFourAndBudgetStopsLaterBatches() async throws {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(
            scheduler: scheduler,
            searchBudget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 1,
                maximumMatchCount: 5000
            )
        )
        let tab = UUID()
        let entries = (0 ..< 8).map { modified("f\($0).swift") }
        harness.configure(repo, entries: entries)
        for entry in entries {
            harness.setPatch(
                Self.patch(path: entry.path, replacement: "needle"),
                path: entry.path,
                at: repo
            )
        }
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)
        harness.diffSource.resetPatchMetrics()
        harness.diffSource.holdPatchLoads()

        harness.viewModel.updateSearchQuery("needle")
        await waitUntil("debounce is pending") { scheduler.pendingCount == 1 }
        scheduler.releaseNext()
        await waitUntil("first search batch reaches the repository") {
            harness.diffSource.activeHeldPatchLoadCount() == 4
        }

        XCTAssertEqual(harness.diffSource.maximumConcurrentPatchLoads, 4)
        XCTAssertTrue(harness.viewModel.searchExpandedFiles.isEmpty)

        harness.diffSource.releasePatchLoads()
        await waitUntil("bounded search completes") {
            harness.viewModel.searchState.phase == .ready
        }

        XCTAssertEqual(harness.diffSource.patchCallCount, 4)
        XCTAssertEqual(harness.viewModel.searchState.skippedFileCount, 4)
        XCTAssertTrue(harness.viewModel.searchState.isTruncated)
        let group = try XCTUnwrap(harness.group(at: repo))
        let row = try XCTUnwrap(harness.row(path: "f0.swift", in: group.id))
        XCTAssertNil(
            harness.viewModel.partialDescriptor(for: row, in: group.id),
            "Search-only patch reads never mint visible-review tokens"
        )
    }

    func testLatePatchResultsFromCancelledSearchCannotOverwriteNewGeneration() async {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(scheduler: scheduler)
        let tab = UUID()
        let paths = (0 ..< 8).map { "f\($0).swift" }
        harness.configure(repo, entries: paths.map(modified))
        for path in paths {
            harness.setPatch(
                Self.patch(path: path, replacement: "oldterm newterm"),
                path: path,
                at: repo
            )
        }
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)
        harness.diffSource.resetPatchMetrics()
        harness.diffSource.holdPatchLoads()

        harness.viewModel.updateSearchQuery("oldterm")
        await waitUntil("old debounce") { scheduler.pendingCount == 1 }
        scheduler.releaseNext()
        await waitUntil("old patch reads suspend") {
            harness.diffSource.activeHeldPatchLoadCount() == 4
        }

        harness.viewModel.updateSearchQuery("newterm")
        await waitUntil("new debounce") { scheduler.pendingCount == 1 }
        scheduler.releaseAll()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(harness.diffSource.activeHeldPatchLoadCount(), 4)
        XCTAssertEqual(harness.diffSource.patchCallCount, 4)
        XCTAssertEqual(
            harness.diffSource.maximumConcurrentPatchLoads,
            4,
            "The read ceiling is global while cancelled generations finish actor work"
        )

        harness.diffSource.releasePatchLoads()

        await waitUntil("new generation is ready") {
            harness.viewModel.searchState.phase == .ready
                && harness.viewModel.searchState.query == "newterm"
        }
        XCTAssertTrue(
            harness.viewModel.searchState.matches.allSatisfy {
                substring(for: $0) == "newterm"
            }
        )
    }

    func testSnapshotFingerprintChangeRestartsActiveSearch() async {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(scheduler: scheduler)
        let tab = UUID()
        harness.configure(repo, entries: [modified("a.swift")])
        harness.setPatch(
            Self.patch(path: "a.swift", replacement: "needle"),
            path: "a.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)
        harness.diffSource.resetPatchMetrics()

        harness.viewModel.updateSearchQuery("needle")
        await waitUntil("initial debounce") { scheduler.pendingCount == 1 }
        scheduler.releaseNext()
        await waitUntil("initial search ready") {
            harness.viewModel.searchState.phase == .ready
        }
        let initialCalls = harness.diffSource.patchCallCount

        harness.diffSource.setHash("moved", at: repo)
        await harness.factory.repositories[0].refresh(
            .contentDelta(paths: [repo + "/a.swift"])
        )
        await harness.factory.repositories[0].waitUntilIdle()
        await waitUntil("snapshot change schedules a new debounce") {
            scheduler.pendingCount == 1
        }
        XCTAssertEqual(harness.viewModel.searchState.phase, .debouncing)

        scheduler.releaseNext()
        await waitUntil("restarted search ready") {
            harness.viewModel.searchState.phase == .ready
        }
        XCTAssertGreaterThan(harness.diffSource.patchCallCount, initialCalls)
    }

    func testPathMatchNavigationDoesNotExpandTheFile() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repo, entries: [modified("unique-path.swift"), modified("other.swift")])
        for path in ["unique-path.swift", "other.swift"] {
            harness.setPatch(
                Self.patch(path: path, replacement: "body"),
                path: path,
                at: repo
            )
        }
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)

        harness.viewModel.updateSearchQuery("unique-path")
        await harness.viewModel.settle()
        let pathMatch = try XCTUnwrap(
            harness.viewModel.searchState.matches.first {
                if case .filePath = $0.locator { return true }
                return false
            }
        )
        let index = try XCTUnwrap(harness.viewModel.searchState.matches.firstIndex(of: pathMatch))
        harness.viewModel.selectSearchMatch(at: index)

        XCTAssertTrue(harness.viewModel.searchExpandedFiles.isEmpty)
        XCTAssertEqual(harness.viewModel.searchNavigationAnchor?.locator, .filePath)
        let group = try XCTUnwrap(harness.group(at: repo))
        let row = try XCTUnwrap(harness.row(path: "unique-path.swift", in: group.id))
        XCTAssertFalse(harness.viewModel.isExpanded(row, in: group.id))
    }

    func testLineNavigationTemporarilyExpandsWrapsPromotesAndNeverMarksViewed() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repo, entries: [modified("a.swift"), modified("b.swift")])
        harness.setPatch(
            Self.patch(path: "a.swift", replacement: "needle-a"),
            path: "a.swift",
            at: repo
        )
        harness.setPatch(
            Self.patch(path: "b.swift", replacement: "needle-b"),
            path: "b.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)

        harness.viewModel.updateSearchQuery("needle-")
        await harness.viewModel.settle()
        XCTAssertEqual(harness.viewModel.searchState.matches.count, 2)
        let group = try XCTUnwrap(harness.group(at: repo))
        let rowA = try XCTUnwrap(harness.row(path: "a.swift", in: group.id))
        let rowB = try XCTUnwrap(harness.row(path: "b.swift", in: group.id))

        harness.viewModel.selectSearchMatch(at: 0)
        await harness.viewModel.settle()
        XCTAssertTrue(harness.viewModel.isExpanded(rowA, in: group.id))
        XCTAssertEqual(harness.viewModel.viewedProgress.viewedFileCount, 0)

        harness.viewModel.toggleExpansion(rowA, in: group.id)
        XCTAssertFalse(harness.viewModel.isExpanded(rowA, in: group.id))
        XCTAssertTrue(harness.viewModel.searchExpandedFiles.isEmpty)

        harness.viewModel.selectSearchMatch(at: 0)
        await harness.viewModel.settle()
        harness.viewModel.setExpansion(true, for: rowA, in: group.id)
        XCTAssertTrue(
            harness.environment.state(for: tab).expandedFiles.contains(
                AgentChangesFileStateKey(
                    groupID: group.id,
                    repositoryRelativePath: "a.swift"
                )
            )
        )
        XCTAssertTrue(harness.viewModel.searchExpandedFiles.isEmpty)

        harness.viewModel.selectNextSearchMatch()
        await harness.viewModel.settle()
        XCTAssertEqual(harness.viewModel.searchState.selectedMatchIndex, 1)
        XCTAssertTrue(harness.viewModel.isExpanded(rowB, in: group.id))

        harness.viewModel.selectNextSearchMatch()
        XCTAssertEqual(harness.viewModel.searchState.selectedMatchIndex, 0, "Next wraps")
        harness.viewModel.selectPreviousSearchMatch()
        XCTAssertEqual(harness.viewModel.searchState.selectedMatchIndex, 1, "Previous wraps")

        harness.viewModel.clearSearch()
        XCTAssertEqual(harness.viewModel.searchState, .idle)
        XCTAssertFalse(harness.viewModel.isExpanded(rowB, in: group.id))
        XCTAssertTrue(
            harness.viewModel.isExpanded(rowA, in: group.id),
            "Clearing search preserves manually promoted expansion"
        )
        XCTAssertEqual(harness.viewModel.viewedProgress.viewedFileCount, 0)
    }

    func testActiveFilterDefinesCorpusAndUnavailableDocumentsAreSkipped() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(
            repo,
            entries: [
                VCSIndexStatusEntry(path: "staged.swift", indexStatus: "M", workTreeStatus: "."),
                modified("unstaged.swift"),
                modified("missing.swift")
            ]
        )
        harness.setPatch(
            Self.patch(path: "staged.swift", replacement: "needle"),
            path: "staged.swift",
            at: repo
        )
        harness.setPatch(
            Self.patch(path: "unstaged.swift", replacement: "needle"),
            path: "unstaged.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        harness.viewModel.selectFilter(.staged)
        harness.viewModel.updateSearchQuery("needle")
        await harness.viewModel.settle()

        let group = try XCTUnwrap(harness.group(at: repo))
        XCTAssertFalse(harness.viewModel.searchState.matches.isEmpty)
        XCTAssertTrue(
            harness.viewModel.searchState.matches.allSatisfy { match in
                harness.viewModel.groupState(for: match.groupID)?
                    .snapshot.section(.staged)?.rows.contains(where: {
                        $0.id == match.rowKey.rowID
                    }) ?? false
            }
        )

        harness.viewModel.selectFilter(.all)
        harness.viewModel.updateSearchQuery("missing.swift")
        await harness.viewModel.settle()
        XCTAssertEqual(harness.viewModel.searchState.skippedFileCount, 1)
        XCTAssertTrue(
            harness.viewModel.searchState.matches.contains {
                $0.groupID == group.id && $0.locator == .filePath
            }
        )
    }

    func testSettledSearchReadPermitsLeaveNoLimiterBookkeeping() async {
        let limiter = AgentChangesSearchReadLimiter(limit: 1)

        guard let acquired = await limiter.acquire() else {
            return XCTFail("The first permit is always granted")
        }
        await limiter.release(acquired)
        // A cancellation that lands after its read completed must not be remembered: search
        // generations recur for every keystroke, so a retained ID grows without bound.
        await limiter.cancel(id: acquired)

        let retained = await limiter.retainedPermitCount
        XCTAssertEqual(retained, 0)

        let next = await limiter.acquire()
        XCTAssertNotNil(next, "The permit released before the late cancellation is still available")
        if let next {
            await limiter.release(next)
        }
        let afterReuse = await limiter.retainedPermitCount
        XCTAssertEqual(afterReuse, 0)
    }

    func testRowScopedMatchLookupReturnsPublishedMatchesForEveryRenderedElement() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repo, entries: [modified("needle-a.swift"), modified("b.swift")])
        harness.setPatch(
            Self.patch(path: "needle-a.swift", replacement: "needle body"),
            path: "needle-a.swift",
            at: repo
        )
        harness.setPatch(
            Self.patch(path: "b.swift", replacement: "needle other"),
            path: "b.swift",
            at: repo
        )
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        harness.viewModel.updateSearchQuery("needle")
        await harness.viewModel.settle()

        let group = try XCTUnwrap(harness.group(at: repo))
        let rowA = try XCTUnwrap(harness.row(path: "needle-a.swift", in: group.id))
        let rowB = try XCTUnwrap(harness.row(path: "b.swift", in: group.id))
        let published = harness.viewModel.searchState.matches
        XCTAssertFalse(published.isEmpty)

        for row in [rowA, rowB] {
            let key = AgentChangesRowKey(groupID: group.id, rowID: row.id)
            let expectedForRow = published.filter { $0.rowKey == key }
            XCTAssertEqual(
                harness.viewModel.searchMatches(for: row, in: group.id),
                expectedForRow
            )
            for locator in Set(expectedForRow.map(\.locator.stableKey)) {
                let expected = expectedForRow.filter { $0.locator.stableKey == locator }
                let locatorValue = try XCTUnwrap(expected.first?.locator)
                XCTAssertEqual(
                    harness.viewModel.searchMatches(for: row, in: group.id, locator: locatorValue),
                    expected
                )
            }
        }

        XCTAssertTrue(
            harness.viewModel.searchMatches(
                for: rowA,
                in: group.id,
                locator: .line(kind: .context, oldLine: 999, newLine: 999)
            ).isEmpty
        )

        harness.viewModel.clearSearch()
        XCTAssertTrue(harness.viewModel.searchMatches(for: rowA, in: group.id).isEmpty)
        XCTAssertTrue(harness.viewModel.searchMatches(for: rowB, in: group.id).isEmpty)
    }

    func testCapFillingPathCorpusStillPublishesTheCompleteGlobalTopN() async throws {
        // Six rows whose paths all match, so the path corpus alone overruns a cap of four, and the
        // two earliest rows also match inside their patches. Ranking puts row 0's patch line ahead of
        // row 3's path, so a path-first pass would publish four results the comparator disagrees with
        // and would never read a patch at all.
        let cap = 4
        let capped = try await searchResults(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 24 * 1024 * 1024,
                maximumMatchCount: cap
            )
        )
        let complete = try await searchResults(
            budget: AgentChangesSearchBudget(
                maximumExaminedByteCount: 24 * 1024 * 1024,
                maximumMatchCount: 10000
            )
        )

        XCTAssertEqual(complete.state.matches.count, 8)
        XCTAssertFalse(complete.state.isTruncated)
        XCTAssertEqual(
            complete.state.matches,
            AgentChangesSearchEngine.ordered(complete.state.matches),
            "The unbounded run is the globally sorted corpus this cap is measured against"
        )

        XCTAssertEqual(capped.state.matches.count, cap)
        XCTAssertEqual(
            capped.state.matches,
            Array(complete.state.matches.prefix(cap)),
            "A capped run must publish exactly the globally sorted top-N"
        )
        XCTAssertTrue(
            capped.state.matches.contains { $0.locator != .filePath },
            "An early row's patch matches outrank a later row's path match"
        )
        XCTAssertTrue(capped.state.isTruncated)
        XCTAssertEqual(
            capped.state.skippedFileCount,
            2,
            "Rows the cap stopped short of are reported rather than silently dropped"
        )
    }

    /// Runs one search over a fixed corpus and returns the settled state.
    ///
    /// Six rows match by path; only the first two also match inside their patches.
    private func searchResults(
        budget: AgentChangesSearchBudget
    ) async throws -> (harness: Phase3PanelHarness, state: AgentChangesSearchState) {
        let harness = Phase3PanelHarness(searchBudget: budget)
        let tab = UUID()
        let paths = (0 ..< 6).map { "needle-\($0).swift" }
        harness.configure(repo, entries: paths.map(modified))
        for (index, path) in paths.enumerated() {
            harness.setPatch(
                Self.patch(path: path, replacement: index < 2 ? "needle body" : "plain body"),
                path: path,
                at: repo
            )
        }
        harness.environment.setRoots([(repo, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        collapseAll(in: harness)

        harness.viewModel.updateSearchQuery("needle")
        await harness.viewModel.settle()
        await waitUntil("search settles") {
            harness.viewModel.searchState.phase == .ready
        }
        return (harness, harness.viewModel.searchState)
    }

    private func collapseAll(in harness: Phase3PanelHarness) {
        for group in harness.viewModel.groups {
            for row in group.snapshot.sections.flatMap(\.rows)
                where harness.viewModel.isExpanded(row, in: group.id)
            {
                harness.viewModel.setExpansion(false, for: row, in: group.id)
            }
        }
    }

    private func modified(_ path: String) -> VCSIndexStatusEntry {
        VCSIndexStatusEntry(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private static func patch(path: String, replacement: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = \(replacement)
         let c = 3
        """ + "\n"
    }

    private func substring(for match: AgentChangesSearchMatch) -> String {
        let range = NSRange(
            location: match.utf16Range.lowerBound,
            length: match.utf16Range.count
        )
        return (match.displayedText as NSString).substring(with: range)
    }

    private func waitUntil(
        _ description: String,
        attempts: Int = 1000,
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
}
