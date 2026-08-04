import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentChangesPanelMultiRootViewModelTests: XCTestCase {
    private let repoA = "/tmp/phase3-panel-a"
    private let repoB = "/tmp/phase3-panel-b"
    private let repoC = "/tmp/phase3-panel-c"

    func testResolvedCheckoutsOwnOneSlotAndFeedWhileBlockedAndAwaitingBaseDoNotFeed() async {
        let working = Phase3PanelHarness()
        let tab = UUID()
        working.configure(repoA, entries: [modified("a.swift")])
        working.configure(repoB, entries: [modified("b.swift")])
        working.environment.setRoots(
            [(repoA, UUID()), ("/tmp/phase3-blocked", UUID()), (repoB, UUID())],
            for: tab
        )
        working.probe.addDirectory("/tmp/phase3-blocked")

        working.sync(tab)
        await working.viewModel.settle()

        XCTAssertEqual(working.viewModel.repositorySlotCount, 2)
        XCTAssertEqual(working.factory.repositories.count, 2)
        XCTAssertEqual(
            Set(working.feeds.createdTargets.map(\.checkoutURL.path)),
            Set([repoA, repoB])
        )
        XCTAssertEqual(
            working.resolutionKinds,
            ["resolved", "blocked", "resolved"],
            "Resolved and blocked outcomes remain in logical-root order"
        )

        let awaiting = Phase3PanelHarness()
        let awaitingTab = UUID()
        awaiting.configure(repoA, entries: [modified("a.swift")])
        awaiting.configure(repoB, entries: [modified("b.swift")])
        awaiting.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: awaitingTab)
        awaiting.environment.setCompareSelection(.vsBase, tabID: awaitingTab)

        awaiting.sync(awaitingTab)
        await awaiting.viewModel.settle()

        XCTAssertEqual(awaiting.viewModel.repositorySlotCount, 2)
        XCTAssertTrue(awaiting.viewModel.groups.allSatisfy { $0.compareState == .awaitingBase })
        XCTAssertTrue(awaiting.feeds.createdTargets.isEmpty)
        XCTAssertTrue(
            awaiting.viewModel.groups.allSatisfy(\.snapshot.sections.isEmpty),
            "No candidate or branch name is inferred into a missing base"
        )

        let stale = Phase3PanelHarness()
        let staleTab = UUID()
        stale.configure(repoA, entries: [modified("late.swift")])
        stale.environment.setRoots([(repoA, UUID())], for: staleTab)
        stale.diffSource.holdMetadata(at: repoA)
        stale.sync(staleTab)
        await waitUntil("working-tree build is suspended") {
            stale.diffSource.metadataWaiterCount(at: self.repoA) > 0
        }

        stale.environment.setCompareSelection(.vsBase, tabID: staleTab)
        stale.sync(staleTab)
        stale.diffSource.releaseMetadata(at: repoA)
        await stale.viewModel.settle()

        XCTAssertEqual(stale.group(at: repoA)?.compareState, .awaitingBase)
        XCTAssertTrue(
            stale.viewModel.groups.allSatisfy(\.snapshot.sections.isEmpty),
            "A late working-tree snapshot cannot restore rows after the group starts awaiting a base"
        )
    }

    func testTabChangeShutsDownWholePoolAndLateRemovedSnapshotsAreIgnored() async {
        let harness = Phase3PanelHarness()
        let oldTab = UUID()
        let newTab = UUID()
        harness.configure(repoA, entries: [modified("old-a.swift")])
        harness.configure(repoB, entries: [modified("old-b.swift")])
        harness.configure(repoC, entries: [modified("new.swift")])
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: oldTab)
        harness.environment.setRoots([(repoC, UUID())], for: newTab)
        harness.diffSource.holdMetadata(at: repoA)
        harness.diffSource.holdMetadata(at: repoB)

        harness.sync(oldTab)
        await waitUntil("old feeds start") {
            harness.feeds.createdTargets.count == 2
        }

        harness.sync(newTab)
        XCTAssertTrue(harness.viewModel.groups.isEmpty, "Old rows clear synchronously on tab change")
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.groups.map(\.target.checkoutURL.path), [repoC])
        XCTAssertGreaterThanOrEqual(harness.feeds.cancelCount, 2)

        harness.diffSource.releaseMetadata(at: repoA)
        harness.diffSource.releaseMetadata(at: repoB)
        await spin()

        XCTAssertEqual(harness.viewModel.groups.map(\.target.checkoutURL.path), [repoC])
        XCTAssertEqual(harness.paths(in: repoC), ["new.swift"])
    }

    func testOutOfOrderPublicationKeepsResolverOrderAndSettleWaitsForEveryStream() async {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("a.swift")])
        harness.configure(repoB, entries: [modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.diffSource.holdMetadata(at: repoA)

        harness.sync(tab)
        await waitUntil("second repository publishes first") {
            harness.paths(in: self.repoB) == ["b.swift"]
        }

        XCTAssertEqual(
            harness.viewModel.groups.map(\.target.checkoutURL.path),
            [repoA, repoB],
            "Completion order must not reorder resolver publication"
        )
        XCTAssertTrue(harness.paths(in: repoA).isEmpty)

        var didSettle = false
        let settleTask = Task { @MainActor in
            await harness.viewModel.settle()
            didSettle = true
        }
        await spin()
        XCTAssertFalse(didSettle, "settle waits for every targeted repository stream")

        harness.diffSource.releaseMetadata(at: repoA)
        await settleTask.value
        XCTAssertEqual(harness.paths(in: repoA), ["a.swift"])
        XCTAssertTrue(didSettle)
    }

    func testRefreshWaitsForEveryActor() async {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("a.swift")])
        harness.configure(repoB, entries: [modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        harness.diffSource.holdMetadata(at: repoB)
        harness.viewModel.refresh()
        await waitUntil("refresh reaches the held repository") {
            harness.diffSource.metadataWaiterCount(at: self.repoB) > 0
        }
        XCTAssertTrue(harness.viewModel.isRefreshing)

        harness.diffSource.releaseMetadata(at: repoB)
        await harness.viewModel.settle()
        XCTAssertFalse(harness.viewModel.isRefreshing)
    }

    func testMissingBaseIsGroupLocalAndDifferentRepositoriesKeepDifferentExplicitBases() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("a.swift")])
        harness.configure(repoB, entries: [modified("b.swift")])
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.environment.branchesByCheckout[repoA] = ["main"]
        harness.environment.branchesByCheckout[repoB] = ["release"]
        harness.environment.setCompareSelection(.vsBase, tabID: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        let groupA = try XCTUnwrap(harness.group(at: repoA))
        let groupB = try XCTUnwrap(harness.group(at: repoB))
        XCTAssertEqual(groupA.baseCandidates, ["main"])
        XCTAssertEqual(groupB.baseCandidates, ["release"])
        XCTAssertEqual(groupA.compareState, .awaitingBase)
        XCTAssertEqual(groupB.compareState, .awaitingBase)

        harness.viewModel.selectBaseRevision("main", for: groupA.id)
        harness.sync(tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.group(at: repoA)?.compareState, .vsBase(base: "main"))
        XCTAssertEqual(harness.group(at: repoB)?.compareState, .awaitingBase)
        XCTAssertEqual(harness.viewModel.emptyState(for: groupB.id), .baseNotChosen)

        harness.viewModel.selectBaseRevision("release", for: groupB.id)
        harness.sync(tab)
        await harness.viewModel.settle()

        XCTAssertEqual(
            harness.environment.state(for: tab).selectedBaseRevision(forRepoRoot: repoA),
            "main"
        )
        XCTAssertEqual(
            harness.environment.state(for: tab).selectedBaseRevision(forRepoRoot: repoB),
            "release"
        )
    }

    func testQualifiedExpansionPendingFlashAndViewedStateCannotCollide() async throws {
        let scheduler = Phase3ManualScheduler()
        let harness = Phase3PanelHarness(scheduler: scheduler)
        let tab = UUID()
        harness.configure(repoA, entries: [modified("same.swift")])
        harness.configure(repoB, entries: [modified("same.swift")])
        harness.setPatch(Self.patch(path: "same.swift"), path: "same.swift", at: repoA)
        harness.setPatch(Self.patch(path: "same.swift"), path: "same.swift", at: repoB)
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        let groupA = try XCTUnwrap(harness.group(at: repoA))
        let groupB = try XCTUnwrap(harness.group(at: repoB))
        let rowA = try XCTUnwrap(harness.row(path: "same.swift", in: groupA.id))
        let rowB = try XCTUnwrap(harness.row(path: "same.swift", in: groupB.id))

        harness.viewModel.setExpansion(false, for: rowB, in: groupB.id)
        XCTAssertTrue(harness.viewModel.isExpanded(rowA, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isExpanded(rowB, in: groupB.id))

        harness.viewModel.setViewed(true, for: rowA, in: groupA.id)
        XCTAssertEqual(
            harness.viewModel.viewedProgress,
            AgentChangesViewedProgress(viewedFileCount: 1, totalFileCount: 2)
        )

        harness.backend.holdStage(at: repoA)
        harness.viewModel.setStaged(true, row: rowA, in: groupA.id)
        XCTAssertTrue(harness.viewModel.isMutationDisabled(rowA, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isMutationDisabled(rowB, in: groupB.id))
        XCTAssertTrue(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupB.id))
        harness.backend.releaseStage(at: repoA)
        await harness.viewModel.settle()

        let stagedRowA = try XCTUnwrap(
            harness.row(path: "same.swift", section: .staged, in: groupA.id)
        )
        await harness.factory.repositories[0].refresh(
            .contentDelta(paths: [repoA + "/same.swift"])
        )
        await harness.factory.repositories[0].waitUntilIdle()
        harness.viewModel.setStaged(false, row: stagedRowA, in: groupA.id)
        await harness.viewModel.settle()

        XCTAssertTrue(harness.viewModel.isFlashing(stagedRowA, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isFlashing(rowB, in: groupB.id))
        scheduler.releaseAll()
        await spin()
    }

    func testBulkPendingDisablesOnlyItsRepository() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("same.swift")])
        harness.configure(repoB, entries: [modified("same.swift")])
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        let groupA = try XCTUnwrap(harness.group(at: repoA))
        let groupB = try XCTUnwrap(harness.group(at: repoB))
        let rowB = try XCTUnwrap(harness.row(path: "same.swift", in: groupB.id))
        harness.backend.holdStage(at: repoA)
        harness.viewModel.applyBulkStaging(true, section: .unstaged, in: groupA.id)
        await waitUntil("bulk stage reaches its repository") {
            harness.viewModel.isBulkActionPending(for: .unstaged, in: groupA.id)
        }

        XCTAssertTrue(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupB.id))
        XCTAssertFalse(harness.viewModel.isMutationDisabled(rowB, in: groupB.id))

        harness.backend.releaseStage(at: repoA)
        await harness.viewModel.settle()
    }

    func testPartialPendingDisablesOnlyItsRepository() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("same.swift")])
        harness.configure(repoB, entries: [modified("same.swift")])
        harness.setPatch(Self.patch(path: "same.swift"), path: "same.swift", at: repoA)
        harness.setPatch(Self.patch(path: "same.swift"), path: "same.swift", at: repoB)
        harness.environment.setRoots([(repoA, UUID()), (repoB, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        let groupA = try XCTUnwrap(harness.group(at: repoA))
        let groupB = try XCTUnwrap(harness.group(at: repoB))
        let rowA = try XCTUnwrap(harness.row(path: "same.swift", in: groupA.id))
        let rowB = try XCTUnwrap(harness.row(path: "same.swift", in: groupB.id))
        let document = try XCTUnwrap(harness.viewModel.patchState(for: rowA, in: groupA.id).document)
        let hunkID = try XCTUnwrap(document.hunks.first?.id)
        XCTAssertEqual(
            harness.viewModel.partialDescriptor(for: rowA, in: groupA.id)?.availability,
            .available
        )

        harness.backend.holdCachedPatch(at: repoA)
        harness.viewModel.applyPartialHunk(for: rowA, hunkID: hunkID, in: groupA.id)
        await waitUntil("partial apply reaches backend") {
            harness.backend.cachedPatchWaiterCount(at: self.repoA) == 1
        }

        XCTAssertNotNil(harness.viewModel.pendingPartial(for: rowA, in: groupA.id))
        XCTAssertTrue(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupA.id))
        XCTAssertFalse(harness.viewModel.isBulkActionDisabled(for: .unstaged, in: groupB.id))
        XCTAssertFalse(harness.viewModel.isPartialMutationDisabled(for: rowB, in: groupB.id))

        harness.backend.releaseCachedPatch(at: repoA)
        await harness.viewModel.settle()
        XCTAssertNil(harness.viewModel.pendingPartial(for: rowA, in: groupA.id))
    }

    func testFailedPartialMutationRevokesDeadDescriptorAndReloadsUnavailableReason() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("file.swift")])
        harness.setPatch(Self.patch(path: "file.swift"), path: "file.swift", at: repoA)
        harness.environment.setRoots([(repoA, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()

        let group = try XCTUnwrap(harness.group(at: repoA))
        let row = try XCTUnwrap(harness.row(path: "file.swift", in: group.id))
        let document = try XCTUnwrap(harness.viewModel.patchState(for: row, in: group.id).document)
        let hunkID = try XCTUnwrap(document.hunks.first?.id)
        let deadToken = try XCTUnwrap(
            harness.viewModel.partialDescriptor(for: row, in: group.id)?.reviewToken
        )
        harness.backend.enqueueCachedPatchFailure(
            GitIndexMutationError.invalidPatch("rejected compiled patch"),
            at: repoA
        )

        harness.viewModel.applyPartialHunk(for: row, hunkID: hunkID, in: group.id)
        await harness.viewModel.settle()

        let refreshed = try XCTUnwrap(
            harness.viewModel.partialDescriptor(for: row, in: group.id)
        )
        XCTAssertEqual(refreshed.availability, .unavailable(.malformedPatch))
        XCTAssertNil(refreshed.reviewToken)
        XCTAssertNotEqual(refreshed.reviewToken, deadToken)
    }

    func testAggregateCountsViewedProgressAndArtifactResolutionQualifyByGroup() async throws {
        let artifactRoot = "/Users/dev/project"
        let harness = Phase3PanelHarness()
        let tab = UUID()
        let artifactRootID = UUID()
        harness.configure(repoA, entries: [modified("same.swift")])
        harness.configure(artifactRoot, entries: [modified("same.swift")])
        harness.environment.setRoots([(repoA, UUID()), (artifactRoot, artifactRootID)], for: tab)
        harness.environment.setItems(
            [AgentEditToolPayloadFixtures.editCreatedMarkdown.item()],
            for: tab
        )
        harness.sync(tab)
        await harness.viewModel.settle()

        XCTAssertEqual(
            harness.viewModel.filterCounts,
            AgentChangesFilterCounts(all: 2, staged: 0, unstaged: 2, conflicts: 0)
        )
        XCTAssertEqual(harness.viewModel.footerSummary.fileCount, 2)
        XCTAssertEqual(
            harness.viewModel.bannerLink?.document,
            PreviewDocumentReference(rootID: artifactRootID, relativePath: "docs/impl-report.md")
        )

        let first = try XCTUnwrap(harness.group(at: repoA))
        let row = try XCTUnwrap(harness.row(path: "same.swift", in: first.id))
        harness.viewModel.setViewed(true, for: row, in: first.id)
        XCTAssertEqual(harness.viewModel.viewedProgress.totalFileCount, 2)
        XCTAssertEqual(harness.viewModel.viewedProgress.viewedFileCount, 1)
    }

    func testRapidPerSlotRetargetsKeepTheNewestExplicitBase() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("a.swift")])
        harness.environment.setRoots([(repoA, UUID())], for: tab)
        harness.environment.setCompareSelection(.vsBase, tabID: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        let groupID = try XCTUnwrap(harness.group(at: repoA)?.id)

        harness.viewModel.selectBaseRevision("old-base", for: groupID)
        harness.viewModel.selectBaseRevision("new-base", for: groupID)
        harness.sync(tab)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.group(at: repoA)?.resolvedCompareMode, .vsBase(base: "new-base"))
        XCTAssertEqual(harness.group(at: repoA)?.snapshot.mode, .vsBase(base: "new-base"))
    }

    func testABARetargetRejectsEpochOnePatchAndDescriptorCompletedLast() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("file.swift")])
        harness.setPatch(
            Self.patch(path: "file.swift", replacement: "epoch-one"),
            path: "file.swift",
            at: repoA
        )
        harness.diffSource.holdNextPatchLoads(2)
        harness.environment.setRoots([(repoA, UUID())], for: tab)
        harness.sync(tab)
        await waitUntil("epoch-one patch is held") {
            harness.diffSource.heldPatchLoadCount == 1
        }
        let slotID = try XCTUnwrap(harness.viewModel.groups.first?.id)

        harness.viewModel.selectCompare(.vsBase)
        harness.setPatch(
            Self.patch(path: "file.swift", replacement: "epoch-three"),
            path: "file.swift",
            at: repoA
        )
        harness.viewModel.selectCompare(.workingTree)
        await waitUntil("epoch-three patch is held") {
            harness.diffSource.heldPatchLoadCount == 2
        }

        harness.diffSource.releaseHeldPatchLoad(at: 1)
        await waitUntil("epoch-three patch publishes first") {
            guard let row = harness.row(path: "file.swift", in: slotID),
                  let document = harness.viewModel.patchState(for: row, in: slotID).document
            else { return false }
            return document.hunks.flatMap(\.lines).contains { $0.text.contains("epoch-three") }
                && harness.viewModel.partialDescriptor(for: row, in: slotID)?.reviewToken != nil
        }
        let row = try XCTUnwrap(harness.row(path: "file.swift", in: slotID))
        let epochThreeToken = try XCTUnwrap(
            harness.viewModel.partialDescriptor(for: row, in: slotID)?.reviewToken
        )

        harness.diffSource.releaseHeldPatchLoad(at: 0)
        await harness.viewModel.settle()

        let finalDocument = try XCTUnwrap(
            harness.viewModel.patchState(for: row, in: slotID).document
        )
        XCTAssertTrue(finalDocument.hunks.flatMap(\.lines).contains { $0.text.contains("epoch-three") })
        XCTAssertFalse(finalDocument.hunks.flatMap(\.lines).contains { $0.text.contains("epoch-one") })
        XCTAssertEqual(
            harness.viewModel.partialDescriptor(for: row, in: slotID)?.reviewToken,
            epochThreeToken
        )
    }

    func testABARetargetRejectsEpochOneGapExpansionCompletedLast() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        let patch = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -5,3 +5,3 @@
         line-5
        -old
        +new
         line-7

        """
        harness.configure(repoA, entries: [modified("file.swift")])
        harness.setPatch(patch, path: "file.swift", at: repoA)
        try harness.diffSource.setFileContent(
            (1 ... 10).map { "epoch-one-line-\($0)" }.joined(separator: "\n") + "\n",
            at: repoA
        )
        harness.environment.setRoots([(repoA, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        let groupID = try XCTUnwrap(harness.group(at: repoA)?.id)
        let row = try XCTUnwrap(harness.row(path: "file.swift", in: groupID))
        let document = try XCTUnwrap(harness.viewModel.patchState(for: row, in: groupID).document)
        let firstGap = try XCTUnwrap(
            DiffContextSplicer.gaps(in: document, sourceLineCount: 10, sourceSide: .new).first
        )
        harness.diffSource.holdNextFileContentLoads(2)
        harness.viewModel.expandContextGap(firstGap, amount: .all, for: row, in: groupID)
        await waitUntil("epoch-one gap read is held") {
            harness.diffSource.heldFileContentLoadCount == 1
        }

        harness.viewModel.selectCompare(.vsBase)
        harness.viewModel.selectCompare(.workingTree)
        await waitUntil("epoch-three base patch reloads") {
            harness.viewModel.patchState(for: row, in: groupID).document != nil
        }
        try harness.diffSource.setFileContent(
            (1 ... 10).map { "epoch-three-line-\($0)" }.joined(separator: "\n") + "\n",
            at: repoA
        )
        let freshDocument = try XCTUnwrap(
            harness.viewModel.patchState(for: row, in: groupID).document
        )
        let freshGap = try XCTUnwrap(
            DiffContextSplicer.gaps(in: freshDocument, sourceLineCount: 10, sourceSide: .new).first
        )
        harness.viewModel.expandContextGap(freshGap, amount: .all, for: row, in: groupID)
        await waitUntil("epoch-three gap read is held") {
            harness.diffSource.heldFileContentLoadCount == 2
        }

        harness.diffSource.releaseHeldFileContentLoad(at: 1)
        await waitUntil("epoch-three gap publishes first") {
            harness.viewModel.patchState(for: row, in: groupID).document?.hunks
                .flatMap(\.lines).contains { $0.text.contains("epoch-three-line") } == true
        }
        harness.diffSource.releaseHeldFileContentLoad(at: 0)
        await harness.viewModel.settle()

        let finalDocument = try XCTUnwrap(
            harness.viewModel.patchState(for: row, in: groupID).document
        )
        XCTAssertTrue(finalDocument.hunks.flatMap(\.lines).contains { $0.text.contains("epoch-three-line") })
        XCTAssertFalse(finalDocument.hunks.flatMap(\.lines).contains { $0.text.contains("epoch-one-line") })
        XCTAssertNil(harness.viewModel.gapContextState(for: row, in: groupID).unavailableReason)
    }

    func testABARetargetSnapshotCarriesNewestTargetRequestEpoch() async throws {
        let harness = Phase3PanelHarness()
        let tab = UUID()
        harness.configure(repoA, entries: [modified("file.swift")])
        harness.setPatch(Self.patch(path: "file.swift"), path: "file.swift", at: repoA)
        harness.environment.setRoots([(repoA, UUID())], for: tab)
        harness.sync(tab)
        await harness.viewModel.settle()
        let groupID = try XCTUnwrap(harness.group(at: repoA)?.id)
        let slotID = try XCTUnwrap(harness.viewModel.repositorySlotID(for: groupID))
        XCTAssertEqual(harness.group(at: repoA)?.snapshot.targetRequestID, 1)

        harness.viewModel.selectCompare(.vsBase)
        harness.viewModel.selectCompare(.workingTree)
        await harness.viewModel.settle()

        XCTAssertEqual(harness.viewModel.repositorySlotID(for: groupID), slotID)
        XCTAssertEqual(harness.group(at: repoA)?.snapshot.targetRequestID, 3)
        XCTAssertEqual(harness.paths(in: repoA), ["file.swift"])
    }

    private func modified(_ path: String) -> VCSIndexStatusEntry {
        VCSIndexStatusEntry(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private static func patch(path: String, replacement: String = "needle") -> String {
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

        """
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

    private func spin(_ count: Int = 40) async {
        for _ in 0 ..< count {
            await Task.yield()
        }
    }
}

// MARK: - Shared Phase-3 view-model harness

@MainActor
final class Phase3PanelHarness {
    let viewModel: AgentChangesPanelViewModel
    let environment = Phase3PanelEnvironment()
    let probe = Phase3PanelProbe()
    let backend = Phase3IndexBackend()
    let diffSource = Phase3DiffSource()
    let feeds = Phase3FeedRecorder()
    let factory: Phase3RepositoryFactory

    init(
        scheduler: any AgentChangesScheduler = Phase3ImmediateScheduler(),
        searchBudget: AgentChangesSearchBudget = .standard
    ) {
        factory = Phase3RepositoryFactory(
            backend: backend,
            diffSource: diffSource,
            feeds: feeds
        )
        viewModel = AgentChangesPanelViewModel(
            environment: environment,
            repositoryFactory: { [factory] in factory.makeRepository() },
            probe: probe,
            scheduler: scheduler,
            stagingGrace: .zero,
            flashDuration: .seconds(60),
            searchDebounce: .milliseconds(150),
            searchBudget: searchBudget
        )
    }

    func configure(
        _ checkout: String,
        entries: [VCSIndexStatusEntry],
        backendKind: VCSBackendKind = .git
    ) {
        probe.addRepository(checkout, kind: backendKind)
        backend.setEntries(entries, at: checkout)
        backend.setCapabilities(backendKind == .git ? .git : .jujutsu, at: checkout)
    }

    func setPatch(_ patch: String, path: String, at checkout: String) {
        diffSource.setPatch(patch, path: path, at: checkout)
    }

    func sync(_ tabID: UUID) {
        viewModel.sync(tabID: tabID, panel: environment.state(for: tabID))
    }

    func group(at checkout: String) -> AgentChangesGroupState? {
        viewModel.groups.first { $0.target.checkoutURL.path == checkout }
    }

    func paths(in checkout: String, section: AgentChangesSectionKind = .unstaged) -> [String] {
        group(at: checkout)?.snapshot.section(section)?.rows.map(\.path) ?? []
    }

    func row(
        path: String,
        section: AgentChangesSectionKind = .unstaged,
        in groupID: AgentChangesGroupID
    ) -> AgentChangesFileRow? {
        viewModel.groupState(for: groupID)?
            .snapshot.section(section)?.rows.first { $0.path == path }
    }

    var resolutionKinds: [String] {
        (viewModel.resolution?.items ?? []).map {
            switch $0 {
            case .resolved: "resolved"
            case .blocked: "blocked"
            }
        }
    }
}

@MainActor
final class Phase3PanelEnvironment: AgentChangesPanelEnvironment {
    private var inputsByTab: [UUID: AgentChangesPanelRootInputs] = [:]
    private var statesByTab: [UUID: AgentUtilityPanelTabState] = [:]
    private var itemSubjects: [UUID: CurrentValueSubject<[AgentChatItem], Never>] = [:]
    var branchesByCheckout: [String: [String]] = [:]

    func setRoots(_ roots: [(String, UUID)], for tabID: UUID) {
        inputsByTab[tabID] = AgentChangesPanelRootInputs(
            logicalRoots: roots.map { AgentPanelLogicalRoot(path: $0.0) },
            rootIDsByPath: Dictionary(
                uniqueKeysWithValues: roots.map {
                    (URL(fileURLWithPath: $0.0).standardizedFileURL.path, $0.1)
                }
            ),
            worktreeBindings: [],
            isPreparingWorktree: false,
            watchedRootPaths: roots.map(\.0)
        )
    }

    func state(for tabID: UUID) -> AgentUtilityPanelTabState {
        statesByTab[tabID] ?? AgentUtilityPanelTabState()
    }

    func setCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID) {
        mutate(tabID) { $0.setCompareSelection(selection) }
    }

    func setItems(_ items: [AgentChatItem], for tabID: UUID) {
        if let subject = itemSubjects[tabID] {
            subject.send(items)
        } else {
            itemSubjects[tabID] = CurrentValueSubject(items)
        }
    }

    private func mutate(
        _ tabID: UUID?,
        _ body: (inout AgentUtilityPanelTabState) -> Void
    ) {
        guard let tabID else { return }
        var state = statesByTab[tabID] ?? AgentUtilityPanelTabState()
        body(&state)
        statesByTab[tabID] = state
    }

    func rootInputs(tabID: UUID?) async -> AgentChangesPanelRootInputs {
        guard let tabID else { return .empty }
        return inputsByTab[tabID] ?? .empty
    }

    func transcriptItems(tabID: UUID?) -> [AgentChatItem] {
        guard let tabID else { return [] }
        return itemSubjects[tabID]?.value ?? []
    }

    func transcriptItemsPublisher(tabID: UUID?) -> AnyPublisher<[AgentChatItem], Never>? {
        guard let tabID else { return nil }
        return itemSubjects[tabID]?.eraseToAnyPublisher()
    }

    func baseBranchCandidates(at checkout: URL) async -> [String] {
        branchesByCheckout[checkout.path] ?? []
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

    func selectBaseRevision(_ revision: String?, forRepoRoot root: String, tabID: UUID?) {
        mutate(tabID) {
            $0.selectBaseRevision(revision, forRepoRoot: root)
            $0.selectBaseBranch(revision, forRepoRoot: root)
        }
    }

    func setFileExpansion(
        _ expanded: Bool,
        file: AgentChangesFileStateKey,
        tabID: UUID?
    ) {
        mutate(tabID) { $0.setExpansion(expanded, ofFile: file) }
    }

    func setFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFile: AgentChangesFileStateKey?,
        tabID: UUID?
    ) {
        mutate(tabID) { state in
            state.setViewed(viewed, revision: revision, compareTargetKey: compareTargetKey)
            if let collapseFile { state.setExpansion(false, ofFile: collapseFile) }
        }
    }

    @discardableResult
    func escalateContext(
        file: AgentChangesFileStateKey,
        tabID: UUID?
    ) -> AgentChangesContextLevel {
        var level = AgentChangesContextLevel.standard
        mutate(tabID) { level = $0.escalateContext(forFile: file) }
        return level
    }

    func showPreview(of document: PreviewDocumentReference, tabID: UUID?) {
        mutate(tabID) { $0.showPreview(of: document) }
    }

    func dismissBanner(artifactID: String, tabID: UUID?) {
        mutate(tabID) { $0.dismissBanner(artifactID: artifactID) }
    }
}

final class Phase3PanelProbe: AgentPanelCheckoutProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String> = []
    private var repositories: [String: VCSBackendKind] = [:]

    func addDirectory(_ path: String) {
        lock.withLock { _ = directories.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
    }

    func addRepository(_ path: String, kind: VCSBackendKind) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.withLock {
            directories.insert(standardized)
            repositories[standardized] = kind
        }
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return lock.withLock { directories.contains(standardized) ? .directory : .missing }
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            repositories[path].map { VCSResolvedRepo(rootURL: url, backendKind: $0) }
        }
    }
}

struct Phase3ImmediateScheduler: AgentChangesScheduler {
    func sleep(for _: Duration) async throws {
        await Task.yield()
    }
}

final class Phase3ManualScheduler: AgentChangesScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        lock.withLock { waiters.count }
    }

    func releaseNext() {
        let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        waiter?.resume()
    }

    func releaseAll() {
        let pending = lock.withLock {
            let value = waiters
            waiters = []
            return value
        }
        pending.forEach { $0.resume() }
    }

    func sleep(for _: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }
}

final class Phase3FeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [AgentPanelResolvedCheckout] = []
    private var cancellations = 0

    var createdTargets: [AgentPanelResolvedCheckout] {
        lock.withLock { targets }
    }

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    func makeFeed(for target: AgentPanelResolvedCheckout) -> Phase3Feed {
        lock.withLock { targets.append(target) }
        return Phase3Feed { [weak self] in
            self?.lock.withLock { self?.cancellations += 1 }
        }
    }
}

final class Phase3Feed: AgentChangesTriggerFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AgentChangesRefreshTrigger>.Continuation?
    private let onCancel: @Sendable () -> Void
    private var didCancel = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func events() -> AsyncStream<AgentChangesRefreshTrigger> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func cancel() {
        let continuation: AsyncStream<AgentChangesRefreshTrigger>.Continuation? = lock.withLock {
            guard !didCancel else { return nil }
            didCancel = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.finish()
        if continuation != nil { onCancel() }
    }
}

@MainActor
final class Phase3RepositoryFactory {
    let backend: Phase3IndexBackend
    let diffSource: Phase3DiffSource
    let feeds: Phase3FeedRecorder
    private(set) var repositories: [AgentChangesRepository] = []

    init(
        backend: Phase3IndexBackend,
        diffSource: Phase3DiffSource,
        feeds: Phase3FeedRecorder
    ) {
        self.backend = backend
        self.diffSource = diffSource
        self.feeds = feeds
    }

    func makeRepository() -> AgentChangesRepository {
        let repository = AgentChangesRepository(
            indexBackend: backend,
            diffSource: diffSource,
            invalidationPublisher: Phase3InvalidationPublisher(),
            scheduler: Phase3ImmediateScheduler(),
            contentDeltaWindow: .zero,
            makeTriggerFeed: { [feeds] target in feeds.makeFeed(for: target) }
        )
        repositories.append(repository)
        return repository
    }
}

struct Phase3InvalidationPublisher: AgentChangesInvalidationPublishing {
    func publishIndexMutation(at _: URL) async {}
}

final class Phase3IndexBackend: AgentChangesIndexBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [VCSIndexStatusEntry]] = [:]
    private var capabilities: [String: VCSCapabilities] = [:]
    private var heldStages: Set<String> = []
    private var stageWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var heldCachedPatches: Set<String> = []
    private var cachedPatchWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cachedPatchFailures: [String: [GitIndexMutationError]] = [:]

    func setEntries(_ value: [VCSIndexStatusEntry], at checkout: String) {
        lock.withLock { entries[standardized(checkout)] = value }
    }

    func setCapabilities(_ value: VCSCapabilities, at checkout: String) {
        lock.withLock { capabilities[standardized(checkout)] = value }
    }

    func holdStage(at checkout: String) {
        lock.withLock { _ = heldStages.insert(standardized(checkout)) }
    }

    func releaseStage(at checkout: String) {
        let key = standardized(checkout)
        let waiters = lock.withLock {
            heldStages.remove(key)
            return stageWaiters.removeValue(forKey: key) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    func holdCachedPatch(at checkout: String) {
        lock.withLock { _ = heldCachedPatches.insert(standardized(checkout)) }
    }

    func releaseCachedPatch(at checkout: String) {
        let key = standardized(checkout)
        let waiters = lock.withLock {
            heldCachedPatches.remove(key)
            return cachedPatchWaiters.removeValue(forKey: key) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    func cachedPatchWaiterCount(at checkout: String) -> Int {
        lock.withLock { cachedPatchWaiters[standardized(checkout)]?.count ?? 0 }
    }

    func enqueueCachedPatchFailure(_ error: GitIndexMutationError, at checkout: String) {
        lock.withLock { cachedPatchFailures[standardized(checkout), default: []].append(error) }
    }

    func capabilities(at checkout: URL) async -> VCSCapabilities {
        lock.withLock { capabilities[checkout.standardizedFileURL.path] ?? .git }
    }

    func hasHeadCommit(at _: URL) async throws -> Bool {
        true
    }

    func loadIndexStatus(at checkout: URL) async throws -> [VCSIndexStatusEntry] {
        lock.withLock { entries[checkout.standardizedFileURL.path] ?? [] }
    }

    func stage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        await waitForStage(checkout.standardizedFileURL.path)
        try await requireAuthorization(authorize)
        lock.withLock {
            let key = checkout.standardizedFileURL.path
            var current = entries[key] ?? []
            for identity in identities {
                guard let index = current.firstIndex(where: { $0.path == identity.path }) else { continue }
                let old = current[index]
                current[index] = VCSIndexStatusEntry(
                    path: old.path,
                    originalPath: old.originalPath,
                    indexStatus: old.isUntracked ? "A" : (old.workTreeStatus ?? "M"),
                    workTreeStatus: ".",
                    isUntracked: false,
                    isConflicted: old.isConflicted
                )
            }
            entries[key] = current
        }
    }

    func unstage(
        _ identities: [VCSIndexPathIdentity],
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireAuthorization(authorize)
        lock.withLock {
            let key = checkout.standardizedFileURL.path
            var current = entries[key] ?? []
            for identity in identities {
                guard let index = current.firstIndex(where: { $0.path == identity.path }) else { continue }
                let old = current[index]
                current[index] = VCSIndexStatusEntry(
                    path: old.path,
                    originalPath: old.originalPath,
                    indexStatus: ".",
                    workTreeStatus: old.indexStatus,
                    isUntracked: false,
                    isConflicted: old.isConflicted
                )
            }
            entries[key] = current
        }
    }

    func applyCachedPatch(
        _: Data,
        reverse _: Bool,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        let key = checkout.standardizedFileURL.path
        if let failure = lock.withLock({ () -> GitIndexMutationError? in
            guard var failures = cachedPatchFailures[key], !failures.isEmpty else { return nil }
            let failure = failures.removeFirst()
            cachedPatchFailures[key] = failures
            return failure
        }) {
            throw failure
        }
        let held = lock.withLock { heldCachedPatches.contains(key) }
        if held {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard heldCachedPatches.contains(key) else { return true }
                    cachedPatchWaiters[key, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        try await requireAuthorization(authorize)
    }

    func markResolved(
        _ identity: VCSIndexPathIdentity,
        at checkout: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await stage([identity], at: checkout, authorize: authorize)
    }

    /// Evaluated after any hold, exactly where a real backend evaluates it: past the serialized
    /// index slot and immediately before the command.
    private func requireAuthorization(_ authorize: VCSIndexMutationAuthorization) async throws {
        guard await authorize() else {
            throw GitIndexMutationError.authorizationRevoked
        }
    }

    private func waitForStage(_ key: String) async {
        let held = lock.withLock { heldStages.contains(key) }
        guard held else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard heldStages.contains(key) else { return true }
                stageWaiters[key, default: []].append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

final class Phase3DiffSource: AgentChangesDiffSource, @unchecked Sendable {
    private let lock = NSLock()
    private var patches: [String: [String: String]] = [:]
    private var hashes: [String: String] = [:]
    private var heldMetadata: Set<String> = []
    private var metadataWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var heldPatches = false
    private var patchWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextPatchHoldCount = 0
    private var heldPatchRequestIDs: [UUID] = []
    private var patchWaitersByID: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var fileContents: [String: AgentChangesFileContent] = [:]
    private var nextFileContentHoldCount = 0
    private var heldFileContentRequestIDs: [UUID] = []
    private var fileContentWaitersByID: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var activePatchLoads = 0
    private var maximumPatchLoads = 0
    private var patchCalls: [(String, String)] = []
    private var validations: [String: AgentChangesRevisionValidation] = [:]

    var maximumConcurrentPatchLoads: Int {
        lock.withLock { maximumPatchLoads }
    }

    var patchCallCount: Int {
        lock.withLock { patchCalls.count }
    }

    func patchCallCount(at checkout: String) -> Int {
        lock.withLock {
            patchCalls.count { $0.0 == URL(fileURLWithPath: checkout).standardizedFileURL.path }
        }
    }

    func setPatch(_ text: String, path: String, at checkout: String) {
        lock.withLock {
            patches[URL(fileURLWithPath: checkout).standardizedFileURL.path, default: [:]][path] = text
        }
    }

    func setHash(_ hash: String, at checkout: String) {
        lock.withLock { hashes[URL(fileURLWithPath: checkout).standardizedFileURL.path] = hash }
    }

    func holdMetadata(at checkout: String) {
        lock.withLock { _ = heldMetadata.insert(URL(fileURLWithPath: checkout).standardizedFileURL.path) }
    }

    func releaseMetadata(at checkout: String) {
        let key = URL(fileURLWithPath: checkout).standardizedFileURL.path
        let waiters = lock.withLock {
            heldMetadata.remove(key)
            return metadataWaiters.removeValue(forKey: key) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    func metadataWaiterCount(at checkout: String) -> Int {
        let key = URL(fileURLWithPath: checkout).standardizedFileURL.path
        return lock.withLock { metadataWaiters[key]?.count ?? 0 }
    }

    func holdPatchLoads() {
        lock.withLock {
            heldPatches = true
            activePatchLoads = 0
            maximumPatchLoads = 0
        }
    }

    func releasePatchLoads() {
        let waiters = lock.withLock {
            heldPatches = false
            let current = patchWaiters
            patchWaiters = []
            return current
        }
        waiters.forEach { $0.resume() }
    }

    func holdNextPatchLoads(_ count: Int) {
        lock.withLock { nextPatchHoldCount += count }
    }

    var heldPatchLoadCount: Int {
        lock.withLock { heldPatchRequestIDs.count }
    }

    func releaseHeldPatchLoad(at index: Int) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard heldPatchRequestIDs.indices.contains(index) else { return nil }
            let id = heldPatchRequestIDs.remove(at: index)
            return patchWaitersByID.removeValue(forKey: id)
        }
        waiter?.resume()
    }

    func setFileContent(_ text: String, at checkout: String) throws {
        let content = try AgentChangesFileContent(data: Data(text.utf8))
        lock.withLock {
            fileContents[URL(fileURLWithPath: checkout).standardizedFileURL.path] = content
        }
    }

    func holdNextFileContentLoads(_ count: Int) {
        lock.withLock { nextFileContentHoldCount += count }
    }

    var heldFileContentLoadCount: Int {
        lock.withLock { heldFileContentRequestIDs.count }
    }

    func releaseHeldFileContentLoad(at index: Int) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard heldFileContentRequestIDs.indices.contains(index) else { return nil }
            let id = heldFileContentRequestIDs.remove(at: index)
            return fileContentWaitersByID.removeValue(forKey: id)
        }
        waiter?.resume()
    }

    func activeHeldPatchLoadCount() -> Int {
        lock.withLock { activePatchLoads }
    }

    func resetPatchMetrics() {
        lock.withLock {
            patchCalls = []
            activePatchLoads = 0
            maximumPatchLoads = 0
        }
    }

    func setRevisionValidation(
        _ validation: AgentChangesRevisionValidation,
        revision: String
    ) {
        lock.withLock { validations[revision] = validation }
    }

    func resolveRevision(_ revision: String, at _: URL) async -> AgentChangesRevisionValidation {
        lock.withLock { validations[revision] ?? .valid(objectID: revision) }
    }

    func fingerprint(compare _: GitDiffCompareSpec, at checkout: URL) async throws -> GitDiffFingerprint {
        fingerprint(at: checkout.standardizedFileURL.path)
    }

    func loadMetadata(
        compare _: GitDiffCompareSpec,
        pathspecs _: [String],
        at checkout: URL
    ) async throws -> AgentChangesDiffMetadata {
        let key = checkout.standardizedFileURL.path
        let held = lock.withLock { heldMetadata.contains(key) }
        if held {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard heldMetadata.contains(key) else { return true }
                    metadataWaiters[key, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let files = lock.withLock {
            (patches[key] ?? [:]).keys.sorted().map {
                VCSUncommittedFile(path: $0, status: "M", additions: 1, deletions: 1)
            }
        }
        return AgentChangesDiffMetadata(
            fingerprint: fingerprint(at: key),
            files: files
        )
    }

    func loadPatch(
        compare _: GitDiffCompareSpec,
        paths requestedPaths: [String],
        at checkout: URL,
        contextLines _: Int
    ) async throws -> AgentChangesPatchPayload? {
        let key = checkout.standardizedFileURL.path
        let path = requestedPaths.first
        let capture = lock.withLock { () -> (Bool, UUID?, String?, String) in
            patchCalls.append((key, path ?? ""))
            let holdID: UUID?
            if heldPatches {
                holdID = nil
            } else if nextPatchHoldCount > 0 {
                nextPatchHoldCount -= 1
                let id = UUID()
                heldPatchRequestIDs.append(id)
                holdID = id
            } else {
                holdID = nil
            }
            let isHeld = heldPatches || holdID != nil
            if isHeld {
                activePatchLoads += 1
                maximumPatchLoads = max(maximumPatchLoads, activePatchLoads)
            }
            return (heldPatches, holdID, path.flatMap { patches[key]?[$0] }, hashes[key] ?? "initial")
        }

        if capture.0 {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard heldPatches else { return true }
                    patchWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { activePatchLoads -= 1 }
        } else if let holdID = capture.1 {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard heldPatchRequestIDs.contains(holdID) else { return true }
                    patchWaitersByID[holdID] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            lock.withLock { activePatchLoads -= 1 }
        }

        guard let path, let text = capture.2 else { return nil }
        return AgentChangesPatchPayload(
            perFile: [path: text],
            rawPerFile: [path: Data(text.utf8)],
            fingerprint: fingerprint(hash: capture.3)
        )
    }

    func loadFileContent(
        source _: AgentChangesFileContentSource,
        at checkout: URL,
        byteLimit _: Int
    ) async throws -> AgentChangesFileContent {
        let key = checkout.standardizedFileURL.path
        let capture = lock.withLock { () -> (UUID?, AgentChangesFileContent?) in
            let holdID: UUID?
            if nextFileContentHoldCount > 0 {
                nextFileContentHoldCount -= 1
                let id = UUID()
                heldFileContentRequestIDs.append(id)
                holdID = id
            } else {
                holdID = nil
            }
            return (holdID, fileContents[key])
        }
        if let holdID = capture.0 {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard heldFileContentRequestIDs.contains(holdID) else { return true }
                    fileContentWaitersByID[holdID] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        guard let content = capture.1 else {
            throw AgentChangesFileContentReadError.unavailable("No Phase-3 fake file content.")
        }
        return content
    }

    private func fingerprint(at checkout: String) -> GitDiffFingerprint {
        fingerprint(hash: lock.withLock { hashes[checkout] ?? "initial" })
    }

    private func fingerprint(hash: String) -> GitDiffFingerprint {
        GitDiffFingerprint(
            headSHA: "head",
            baseRef: "INDEX",
            statusHash: hash,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
