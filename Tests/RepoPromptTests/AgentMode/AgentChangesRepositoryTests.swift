import Foundation
@testable import RepoPromptApp
import XCTest

/// Behavior contract for the Changes panel's data controller.
///
/// Everything here runs against fakes with an immediate scheduler, so the suite exercises the
/// gating, coalescing, cancellation, and staging rules without real sleeps or a repository on disk.
/// The last two tests cross-check the porcelain decomposition against real Git in a temp repo.
final class AgentChangesRepositoryTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fingerprint gate matrix

    func testMetadataTriggerWithAnUnchangedFingerprintDoesNotRebuild() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baseline = environment.backend.statusCallCount

        await environment.repository.refresh(.metadata)
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(
            environment.backend.statusCallCount,
            baseline,
            "A .git metadata event that moved no fingerprint must not cost a status read"
        )
    }

    func testMetadataTriggerWithAChangedFingerprintRebuilds() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baseline = environment.backend.statusCallCount

        environment.diffSource.setStatusHash("moved")
        await environment.repository.refresh(.metadata)
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(environment.backend.statusCallCount, baseline + 1)
    }

    func testContentDeltaRebuildsEvenWhenTheFingerprintIsUnchanged() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baselineStatus = environment.backend.statusCallCount
        let baselineFingerprints = environment.diffSource.fingerprintCallCount

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("a.swift")]))
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(
            environment.backend.statusCallCount,
            baselineStatus + 1,
            "Re-editing an already-modified file leaves porcelain membership identical, so the gate would hide it"
        )
        XCTAssertEqual(
            environment.diffSource.fingerprintCallCount,
            baselineFingerprints,
            "A content delta must not spend a fingerprint read asking Git to confirm what FSEvents reported"
        )
    }

    func testEmptyContentDeltaAdvancesEpochAndForcesAWindowedRebuild() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let before = await environment.repository.currentSnapshot()
        let baseline = environment.backend.statusCallCount

        await environment.repository.refresh(.contentDelta(paths: []))
        await environment.repository.waitUntilIdle()

        let after = await environment.repository.currentSnapshot()
        XCTAssertGreaterThan(after.contentEpoch, before.contentEpoch)
        XCTAssertEqual(environment.backend.statusCallCount, baseline + 1)
    }

    func testGitInternalContentDeltaIsIgnored() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baseline = environment.backend.statusCallCount

        await environment.repository.refresh(
            .contentDelta(paths: [environment.absolutePath(".git/index")])
        )
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(environment.backend.statusCallCount, baseline)
    }

    func testPathRevisionsArePrunedWhenTheyBackNeitherRowsNorCaches() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()

        await environment.repository.refresh(
            .contentDelta(paths: [environment.absolutePath(".build/generated.o")])
        )
        await environment.repository.waitUntilIdle()

        environment.backend.setEntries(
            [modified(".build/generated.o")],
            at: environment.target.checkoutURL
        )
        await environment.repository.refresh(.mutationCompleted)
        await environment.repository.waitUntilIdle()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(
            snapshot.section(.unstaged)?.rows.first?.contentRevision,
            snapshot.contentEpoch,
            "A non-row build artifact must not retain a per-path revision forever"
        )
    }

    func testContentDeltaEvictsOnlyTheEditedFilesCachedPatch() async {
        let environment = makeEnvironment(entries: [modified("a.swift"), modified("b.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        environment.diffSource.setPatch(for: "b.swift", text: Self.patchText(path: "b.swift"))
        await environment.start()

        let rowA = await environment.unstagedRow("a.swift")
        let rowB = await environment.unstagedRow("b.swift")
        _ = await environment.repository.patch(for: rowA)
        _ = await environment.repository.patch(for: rowB)
        _ = await environment.repository.patch(for: rowA)
        XCTAssertEqual(environment.diffSource.patchCallCount, 2, "Repeat reads of one file come from the cache")

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("a.swift")]))
        await environment.repository.waitUntilIdle()

        _ = await environment.repository.patch(for: environment.unstagedRow("b.swift"))
        XCTAssertEqual(
            environment.diffSource.patchCallCount,
            2,
            "An edit to a.swift must not throw away the patch already rendered for b.swift"
        )
        _ = await environment.repository.patch(for: environment.unstagedRow("a.swift"))
        XCTAssertEqual(environment.diffSource.patchCallCount, 3)
    }

    func testMutationCompletedTriggerRebuildsWithoutEvictingCachedPatches() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        await environment.start()
        _ = await environment.repository.patch(for: environment.unstagedRow("a.swift"))
        let baselineStatus = environment.backend.statusCallCount

        await environment.repository.refresh(.mutationCompleted)
        await environment.repository.waitUntilIdle()
        _ = await environment.repository.patch(for: environment.unstagedRow("a.swift"))

        XCTAssertEqual(environment.backend.statusCallCount, baselineStatus + 1)
        XCTAssertEqual(
            environment.diffSource.patchCallCount,
            1,
            "Staging moves a file between index and working tree without changing its bytes"
        )
    }

    func testPollBypassesTheGateEvictsEveryPatchAndMarksTheCheckoutDegraded() async {
        let environment = makeEnvironment(entries: [modified("a.swift"), modified("b.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        environment.diffSource.setPatch(for: "b.swift", text: Self.patchText(path: "b.swift"))
        await environment.start()
        _ = await environment.repository.patch(for: environment.unstagedRow("a.swift"))
        _ = await environment.repository.patch(for: environment.unstagedRow("b.swift"))
        let baselineStatus = environment.backend.statusCallCount

        await environment.repository.refresh(.poll)
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(environment.backend.statusCallCount, baselineStatus + 1)
        let degradedSnapshot = await environment.repository.currentSnapshot()
        XCTAssertTrue(
            degradedSnapshot.isPollingDegraded,
            "A poll only arrives when a watcher could not be created, which the panel surfaces"
        )
        _ = await environment.repository.patch(for: environment.unstagedRow("a.swift"))
        _ = await environment.repository.patch(for: environment.unstagedRow("b.swift"))
        XCTAssertEqual(
            environment.diffSource.patchCallCount,
            4,
            "A poll cannot say which files moved, so every cached patch is suspect"
        )
    }

    func testReconcileAfterActivationRebuildsWithoutConsultingTheGate() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baselineStatus = environment.backend.statusCallCount
        let baselineFingerprints = environment.diffSource.fingerprintCallCount

        await environment.repository.refresh(.reconcile)
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(environment.backend.statusCallCount, baselineStatus + 1)
        XCTAssertEqual(environment.diffSource.fingerprintCallCount, baselineFingerprints)
    }

    func testContentDeltaOutsideTheRepresentedScopeIsIgnored() async {
        let environment = makeEnvironment(
            entries: [modified("packages/a/x.swift")],
            pathspecPrefixes: ["packages/a/"]
        )
        await environment.start()
        let baseline = environment.backend.statusCallCount

        await environment.repository.refresh(
            .contentDelta(paths: [environment.absolutePath("packages/b/y.swift")])
        )
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(
            environment.backend.statusCallCount,
            baseline,
            "A workspace representing one package must not rebuild for edits elsewhere in the monorepo"
        )
    }

    func testContentDeltaOutsideTheCheckoutEntirelyIsIgnored() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baseline = environment.backend.statusCallCount

        await environment.repository.refresh(.contentDelta(paths: ["/somewhere/else/a.swift"]))
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(environment.backend.statusCallCount, baseline)
    }

    func testDefaultRepositoryUsesAScopedContentWatch() {
        let checkout = makeCheckout(path: "/tmp/default-content-watch")

        XCTAssertEqual(
            AgentChangesRepository.defaultScopedWatchPaths(for: checkout),
            [checkout.checkoutURL]
        )
    }

    // MARK: - Trigger coalescing

    func testATriggerBurstDuringARebuildCollapsesIntoOneFollowUpRebuild() async throws {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let baseline = environment.backend.statusCallCount

        environment.backend.holdNextStatusReads()
        await environment.repository.refresh(.manual)
        try await AsyncTestWait.waitUntil("the first rebuild to reach its status read") {
            environment.backend.statusCallCount == baseline + 1
        }

        for _ in 0 ..< 5 {
            await environment.repository.refresh(.manual)
        }
        environment.backend.releaseHeldStatusReads()
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(
            environment.backend.statusCallCount,
            baseline + 2,
            "Five triggers arriving during one rebuild are latest-wins: they cost one follow-up, not five"
        )
    }

    // MARK: - Retarget cancellation

    func testRetargetingDropsTheInFlightBuildSoItsSectionsNeverPublish() async throws {
        let first = makeCheckout(path: "/tmp/checkout-one")
        let second = makeCheckout(path: "/tmp/checkout-two")
        let backend = FakeIndexBackend(entriesByCheckout: [
            first.checkoutURL.path: [modified("from-first.swift")],
            second.checkoutURL.path: [modified("from-second.swift")]
        ])
        let diffSource = FakeDiffSource()
        let repository = makeRepository(backend: backend, diffSource: diffSource)

        let recorder = SnapshotRecorder()
        let collector = Task {
            for await snapshot in await repository.snapshots() {
                recorder.append(snapshot)
            }
        }

        await repository.setTarget(first, mode: .workingTree)
        await repository.waitUntilIdle()
        try await AsyncTestWait.waitUntil("the first target's ready snapshot to be observed") {
            recorder.readyCount(forTarget: first.id) == 1
        }

        // Hold the next rebuild inside its status read, so the retarget lands while a build for the
        // first target is genuinely in flight.
        backend.holdNextStatusReads()
        await repository.refresh(.manual)
        try await AsyncTestWait.waitUntil("the first target's rebuild to reach its status read") {
            backend.statusCallCount >= 2
        }

        await repository.setTarget(second, mode: .workingTree)
        backend.releaseHeldStatusReads()
        await repository.waitUntilIdle()
        try await AsyncTestWait.waitUntil("the second target's ready snapshot to be observed") {
            recorder.readyCount(forTarget: second.id) == 1
        }
        collector.cancel()

        XCTAssertEqual(
            recorder.readyCount(forTarget: first.id),
            1,
            "The build already in flight when the target changed must never publish a second time"
        )
        let final = await repository.currentSnapshot()
        XCTAssertEqual(final.target?.id, second.id)
        XCTAssertEqual(final.sections.flatMap(\.rows).map(\.path), ["from-second.swift"])
    }

    func testRetargetingSameCheckoutWithANarrowerScopeRebuilds() async {
        let checkout = makeCheckout(path: "/tmp/scope-retarget")
        let narrowed = makeCheckout(
            path: checkout.checkoutURL.path,
            pathspecPrefixes: ["packages/a/"]
        )
        let backend = FakeIndexBackend(entriesByCheckout: [
            checkout.checkoutURL.path: [
                modified("packages/a/a.swift"),
                modified("packages/b/b.swift")
            ]
        ])
        let repository = makeRepository(backend: backend, diffSource: FakeDiffSource())

        await repository.setTarget(checkout, mode: .workingTree)
        await repository.waitUntilIdle()
        await repository.setTarget(narrowed, mode: .workingTree)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        XCTAssertEqual(snapshot.target, narrowed)
        XCTAssertEqual(snapshot.section(.unstaged)?.rows.map(\.path), ["packages/a/a.swift"])
    }

    func testStaleMonotonicRetargetRequestCannotRestoreAnOlderCheckout() async {
        let first = makeCheckout(path: "/tmp/request-one")
        let second = makeCheckout(path: "/tmp/request-two")
        let backend = FakeIndexBackend(entriesByCheckout: [
            first.checkoutURL.path: [modified("first.swift")],
            second.checkoutURL.path: [modified("second.swift")]
        ])
        let repository = makeRepository(backend: backend, diffSource: FakeDiffSource())

        await repository.setTarget(second, mode: .workingTree, requestID: 2)
        await repository.setTarget(first, mode: .workingTree, requestID: 1)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        XCTAssertEqual(snapshot.target, second)
        XCTAssertEqual(snapshot.section(.unstaged)?.rows.map(\.path), ["second.swift"])
    }

    func testCancellingAContentWindowDuringRetargetResumesIdleWaiters() async throws {
        let target = makeCheckout(path: "/tmp/idle-window")
        let backend = FakeIndexBackend(entriesByCheckout: [
            target.checkoutURL.path: [modified("a.swift")]
        ])
        let scheduler = GateScheduler()
        let repository = makeRepository(
            backend: backend,
            diffSource: FakeDiffSource(),
            scheduler: scheduler,
            contentDeltaWindow: .seconds(1)
        )
        await repository.setTarget(target, mode: .workingTree)
        await repository.waitUntilIdle()

        await repository.refresh(.contentDelta(paths: [target.checkoutURL.appendingPathComponent("a.swift").path]))
        try await AsyncTestWait.waitUntil("the content window to park") {
            scheduler.waiterCount == 1
        }

        let completed = CompletionFlag()
        Task {
            await repository.waitUntilIdle()
            completed.set()
        }
        await repository.setTarget(nil, mode: .workingTree)

        try await AsyncTestWait.waitUntil("the cancelled window's idle waiter to resume") {
            completed.value
        }
        scheduler.releaseAll()
    }

    func testCapabilityResultFromAnOldTargetCannotPoisonTheNewTarget() async throws {
        let gitTarget = makeCheckout(path: "/tmp/capability-git")
        let jjTarget = AgentPanelResolvedCheckout(
            checkoutURL: URL(fileURLWithPath: "/tmp/capability-jj"),
            repoRootURL: URL(fileURLWithPath: "/tmp/capability-jj"),
            backendKind: .jujutsu,
            pathspecPrefixes: [],
            logicalRoots: [AgentPanelLogicalRoot(path: "/tmp/capability-jj")],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )
        let backend = FakeIndexBackend(entriesByCheckout: [
            gitTarget.checkoutURL.path: [modified("git.swift")],
            jjTarget.checkoutURL.path: []
        ])
        backend.setCapabilities(.git, at: gitTarget.checkoutURL)
        backend.setCapabilities(.jujutsu, at: jjTarget.checkoutURL)
        backend.holdCapabilities(at: gitTarget.checkoutURL)
        let diffSource = FakeDiffSource()
        diffSource.setFiles(
            for: .uncommitted(base: "HEAD"),
            files: [VCSUncommittedFile(path: "jj.swift", status: "M")]
        )
        let repository = makeRepository(backend: backend, diffSource: diffSource)

        await repository.setTarget(gitTarget, mode: .workingTree)
        try await AsyncTestWait.waitUntil("the old capability read to suspend") {
            backend.capabilityCallPaths.contains(gitTarget.checkoutURL.path)
        }
        let mutationTask = Task {
            await repository.applyMutation(AgentChangesMutationRequest(
                identity: VCSIndexPathIdentity(path: "git.swift"),
                stage: true,
                expectedContentRevision: 0
            ))
        }
        try await AsyncTestWait.waitUntil("the old-target mutation capability read to suspend") {
            backend.capabilityCallPaths.count { $0 == gitTarget.checkoutURL.path } == 2
        }

        await repository.setTarget(jjTarget, mode: .workingTree)
        backend.releaseCapabilities(at: gitTarget.checkoutURL)
        let mutationOutcome = await mutationTask.value
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        XCTAssertEqual(snapshot.target, jjTarget)
        XCTAssertEqual(snapshot.sections.map(\.kind), [.workingCopy])
        XCTAssertFalse(snapshot.supportsStaging)
        XCTAssertTrue(backend.capabilityCallPaths.contains(jjTarget.checkoutURL.path))
        guard case .failed = mutationOutcome else {
            return XCTFail("The old-target mutation must fail rather than adopt the new checkout")
        }
        XCTAssertTrue(backend.stagedPathBatches.isEmpty)
    }

    // MARK: - Porcelain decomposition

    func testPartiallyStagedFileAppearsInBothSectionsWithDistinctRowIdentities() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "partial.swift", indexStatus: "M", workTreeStatus: "M")
        ])
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        let staged = snapshot.section(.staged)?.rows ?? []
        let unstaged = snapshot.section(.unstaged)?.rows ?? []

        XCTAssertEqual(staged.map(\.path), ["partial.swift"])
        XCTAssertEqual(unstaged.map(\.path), ["partial.swift"])
        XCTAssertNotEqual(staged.first?.id, unstaged.first?.id)
        XCTAssertEqual(staged.first?.fileKey, unstaged.first?.fileKey)
        XCTAssertEqual(staged.first?.hasCounterpartSection, true)
        XCTAssertEqual(unstaged.first?.hasCounterpartSection, true)
        XCTAssertEqual(snapshot.totalFileCount, 1, "One file with two rows is still one file in the footer")
    }

    func testConflictedFileStaysOutOfStagedAndUnstagedAndIsNotStageable() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(
                path: "conflict.swift",
                indexStatus: "U",
                workTreeStatus: "U",
                isConflicted: true
            )
        ])
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.section(.staged)?.rows ?? [], [])
        XCTAssertEqual(snapshot.section(.unstaged)?.rows ?? [], [])
        XCTAssertEqual(snapshot.section(.conflicts)?.rows.map(\.path), ["conflict.swift"])
        XCTAssertEqual(snapshot.section(.conflicts)?.rows.first?.isStageable, false)
    }

    func testUntrackedFileIsUnstagedOnlyAndReportsItsPorcelainStatus() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "new.swift", isUntracked: true)
        ])
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.section(.staged)?.rows ?? [], [])
        XCTAssertEqual(snapshot.section(.unstaged)?.rows.map(\.displayStatus), ["??"])
        XCTAssertEqual(snapshot.section(.unstaged)?.rows.first?.isUntracked, true)
    }

    func testFilesOutsideTheRepresentedScopeAreExcludedFromEverySection() async {
        let environment = makeEnvironment(
            entries: [modified("packages/a/x.swift"), modified("packages/b/y.swift")],
            pathspecPrefixes: ["packages/a/"]
        )
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.section(.unstaged)?.rows.map(\.path), ["packages/a/x.swift"])
    }

    func testMembershipSurvivesAnUnbornHeadEvenThoughStagedPatchesCannotLoad() async {
        let environment = makeEnvironment(entries: [VCSIndexStatusEntry(path: "first.swift", indexStatus: "A")])
        environment.backend.setHasHeadCommit(false)
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertFalse(snapshot.hasHeadCommit)
        XCTAssertEqual(
            snapshot.section(.staged)?.rows.map(\.path),
            ["first.swift"],
            "Porcelain does not need HEAD, so a fresh repository still lists what is staged"
        )
        let state = await environment.repository.patch(for: XCTUnwrapped(snapshot.section(.staged)?.rows.first))
        XCTAssertEqual(state, .unavailable(.unbornHead))
    }

    // MARK: - Patches

    func testExpandingAFileProjectsItsPatchAndCachesTheProjection() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        await environment.start()

        let state = await environment.repository.patch(for: environment.unstagedRow("a.swift"))

        guard case let .loaded(document) = state else {
            return XCTFail("Expected a projected patch, got \(state)")
        }
        XCTAssertEqual(document.id, "a.swift")
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
        XCTAssertEqual(document.hunks.count, 1)
        XCTAssertEqual(document.contextLevel, .lines(3))
        let changed = document.hunks.flatMap(\.lines).filter {
            $0.kind == .addition || $0.kind == .deletion
        }
        XCTAssertTrue(
            changed.contains { !$0.intralineRanges.isEmpty },
            "The Changes repository opts into intraline projection without changing projector defaults"
        )
    }

    func testPerGapExpansionLoadsWorktreeContentOnceAndCachesItByFileFingerprint() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchTextWithLeadingGap(path: "a.swift"))
        environment.diffSource.setFileContent(
            for: .worktree(path: "a.swift"),
            text: Array(1 ... 10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        )
        await environment.start()

        let row = await environment.unstagedRow("a.swift")
        guard case let .loaded(document) = await environment.repository.patch(for: row) else {
            return XCTFail("Expected a projected patch")
        }
        let gap = XCTUnwrapped(DiffContextSplicer.gaps(
            in: document,
            sourceLineCount: nil,
            sourceSide: .new
        ).first)

        let first = await environment.repository.expandContextGap(
            for: row,
            in: document,
            gapID: gap.id,
            amount: .all
        )
        _ = await environment.repository.expandContextGap(
            for: row,
            in: document,
            gapID: gap.id,
            amount: .all
        )

        guard case let .expanded(expanded, lineCount, side) = first else {
            return XCTFail("Expected expanded context, got \(first)")
        }
        XCTAssertEqual(lineCount, 10)
        XCTAssertEqual(side, .new)
        XCTAssertEqual(expanded.hunks.first?.oldStart, 1)
        XCTAssertEqual(expanded.hunks.first?.newStart, 1)
        XCTAssertEqual(environment.diffSource.fileContentCallCount, 1)
    }

    func testContextSourceResolverHandlesUnbornAndRenameWithoutReadingTheOldRenamePath() {
        let renameRow = AgentChangesFileRow(
            id: "staged:new.swift",
            fileKey: "new.swift",
            path: "new.swift",
            originalPath: "old.swift",
            section: .staged,
            indexStatus: "R",
            workTreeStatus: ".",
            isUntracked: false,
            isConflicted: false,
            additions: 0,
            deletions: 0,
            hasCounterpartSection: false,
            contentRevision: 0
        )
        let renameDocument = FileDiffProjection.Document(
            id: "new.swift",
            path: "new.swift",
            oldPath: "old.swift",
            change: .renamed(from: "old.swift"),
            additions: 0,
            deletions: 0,
            hunks: [],
            contextLevel: .lines(3),
            truncation: nil
        )

        XCTAssertNil(AgentChangesContextSourceResolver.selection(
            for: renameRow,
            document: renameDocument,
            mode: .workingTree,
            hasHeadCommit: false
        ))
        XCTAssertEqual(
            AgentChangesContextSourceResolver.selection(
                for: renameRow,
                document: renameDocument,
                mode: .workingTree,
                hasHeadCommit: true
            ),
            AgentChangesContextSourceSelection(
                source: .index(path: "new.swift"),
                side: .new
            )
        )
    }

    func testDeletedVsBaseContextReadsTheMergeBaseReferenceOnTheOldSide() {
        let row = AgentChangesFileRow(
            id: "vsBase:gone.swift",
            fileKey: "gone.swift",
            path: "gone.swift",
            originalPath: nil,
            section: .vsBase,
            indexStatus: nil,
            workTreeStatus: "D",
            isUntracked: false,
            isConflicted: false,
            additions: 0,
            deletions: 3,
            hasCounterpartSection: false,
            contentRevision: 0
        )
        let document = FileDiffProjection.Document(
            id: "gone.swift",
            path: "gone.swift",
            oldPath: nil,
            change: .deleted,
            additions: 0,
            deletions: 3,
            hunks: [],
            contextLevel: .lines(3),
            truncation: nil
        )

        XCTAssertEqual(
            AgentChangesContextSourceResolver.selection(
                for: row,
                document: document,
                mode: .vsBase(base: "main"),
                hasHeadCommit: true
            ),
            AgentChangesContextSourceSelection(
                source: .reference(.mergeBase(base: "main"), path: "gone.swift"),
                side: .old
            )
        )
    }

    func testRefreshNeverLoadsPatchText() async {
        let environment = makeEnvironment(entries: [modified("a.swift"), modified("b.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        await environment.start()

        await environment.repository.refresh(.manual)
        await environment.repository.waitUntilIdle()

        XCTAssertEqual(
            environment.diffSource.patchCallCount,
            0,
            "Metadata-first refresh is what keeps a working-tree-wide diff off the hot path"
        )
        XCTAssertEqual(
            Set(environment.diffSource.metadataCompares),
            ["staged:HEAD", "unstaged"],
            "One porcelain read decides membership; the two metadata reads only add line counts"
        )
    }

    func testContextEscalationRequestsAWiderPatchInsteadOfReusingTheCachedOne() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        await environment.start()
        let row = await environment.unstagedRow("a.swift")

        _ = await environment.repository.patch(for: row, contextLevel: .standard)
        _ = await environment.repository.patch(for: row, contextLevel: .expanded)
        let full = await environment.repository.patch(for: row, contextLevel: .fullFile)

        XCTAssertEqual(environment.diffSource.patchCallCount, 3)
        XCTAssertEqual(environment.diffSource.requestedContextLines, [3, 12, 1_000_000])
        XCTAssertEqual(full.document?.contextLevel, .fullFile)
    }

    func testAPatchBeyondTheByteBudgetIsReportedRatherThanRendered() async {
        let environment = makeEnvironment(entries: [modified("a.swift")], patchByteLimit: 32)
        environment.diffSource.setPatch(for: "a.swift", text: Self.patchText(path: "a.swift"))
        await environment.start()

        let state = await environment.repository.patch(for: environment.unstagedRow("a.swift"))

        guard case let .unavailable(.tooLarge(bytes)) = state else {
            return XCTFail("Expected a too-large report, got \(state)")
        }
        XCTAssertGreaterThan(bytes, 32)
    }

    func testARenameRequestsBothOfItsPathsSoGitCanStillDetectIt() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "new.swift", originalPath: "old.swift", indexStatus: "R", workTreeStatus: ".")
        ])
        environment.diffSource.setPatch(for: "new.swift", text: Self.patchText(path: "new.swift"))
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        _ = await environment.repository.patch(for: XCTUnwrapped(snapshot.section(.staged)?.rows.first))

        XCTAssertEqual(environment.diffSource.requestedPatchPaths, [["new.swift", "old.swift"]])
    }

    // MARK: - Revision validation

    func testRevisionValidationReportsValidInvalidAndAmbiguousWithoutChangingTargetState() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setRevisionValidation(.valid(objectID: String(repeating: "a", count: 40)), for: "v1.2.3")
        environment.diffSource.setRevisionValidation(.invalid("unknown revision"), for: "missing")
        environment.diffSource.setRevisionValidation(.ambiguous("short SHA is ambiguous"), for: "abc123")

        let valid = await environment.repository.validateRevision("v1.2.3", at: environment.target)
        let invalid = await environment.repository.validateRevision("missing", at: environment.target)
        let ambiguous = await environment.repository.validateRevision("abc123", at: environment.target)
        let snapshot = await environment.repository.currentSnapshot()

        XCTAssertEqual(valid, .valid(objectID: String(repeating: "a", count: 40)))
        XCTAssertEqual(invalid, .invalid("unknown revision"))
        XCTAssertEqual(ambiguous, .ambiguous("short SHA is ambiguous"))
        XCTAssertEqual(snapshot, .empty)
    }

    // MARK: - Staging

    func testStagingAnUnstagedFileAppliesAndPublishesInvalidation() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let row = await environment.unstagedRow("a.swift")

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.stagedPathBatches, [["a.swift"]])
        XCTAssertEqual(environment.publisher.publishCount, 1)
        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.section(.staged)?.rows.map(\.path), ["a.swift"])
        XCTAssertEqual(snapshot.section(.unstaged)?.rows ?? [], [])
    }

    func testStagingAFileThatIsAlreadyFullyStagedIsANoOpThatRunsNoGit() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "a.swift", indexStatus: "M", workTreeStatus: ".")
        ])
        await environment.start()
        let snapshot = await environment.repository.currentSnapshot()
        let row = XCTUnwrapped(snapshot.section(.staged)?.rows.first)

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(environment.backend.stagedPathBatches, [])
        XCTAssertEqual(environment.publisher.publishCount, 0)
    }

    func testStagingAPartiallyStagedFileIsNotMistakenForANoOp() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "partial.swift", indexStatus: "M", workTreeStatus: "M")
        ])
        await environment.start()
        let row = await environment.unstagedRow("partial.swift")

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        XCTAssertEqual(
            outcome,
            .applied,
            "The file is in Staged already, but there is still a working-tree change left to capture"
        )
        XCTAssertEqual(environment.backend.stagedPathBatches, [["partial.swift"]])
    }

    func testUnstagingAStagedFileAppliesAndMovesItBackToUnstaged() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(path: "a.swift", indexStatus: "M", workTreeStatus: ".")
        ])
        await environment.start()
        let snapshot = await environment.repository.currentSnapshot()
        let row = XCTUnwrapped(snapshot.section(.staged)?.rows.first)

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: false)
        )

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.unstagedPathBatches, [["a.swift"]])
        XCTAssertEqual(environment.publisher.publishCount, 1)
        let after = await environment.repository.currentSnapshot()
        XCTAssertEqual(after.section(.staged)?.rows ?? [], [])
        XCTAssertEqual(after.section(.unstaged)?.rows.map(\.path), ["a.swift"])
    }

    func testUnstagingAFileWithNothingStagedIsANoOpThatRunsNoGit() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let row = await environment.unstagedRow("a.swift")

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: false)
        )

        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(environment.backend.unstagedPathBatches, [])
        XCTAssertEqual(environment.publisher.publishCount, 0)
    }

    func testStagingPreflightAbortsWhenTheFileChangedSinceTheRowWasRendered() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let reviewedRow = await environment.unstagedRow("a.swift")

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("a.swift")]))
        await environment.repository.waitUntilIdle()
        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: reviewedRow, stage: true)
        )

        XCTAssertEqual(
            outcome,
            .contentChanged,
            "Staging here would record content the reviewer never saw"
        )
        XCTAssertEqual(environment.backend.stagedPathBatches, [])
    }

    func testStagingProceedsWhenADifferentFileChangedSinceTheRowWasRendered() async {
        let environment = makeEnvironment(entries: [modified("a.swift"), modified("b.swift")])
        await environment.start()
        let reviewedRow = await environment.unstagedRow("a.swift")

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("b.swift")]))
        await environment.repository.waitUntilIdle()
        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: reviewedRow, stage: true)
        )

        XCTAssertEqual(
            outcome,
            .applied,
            "Revisions are per file, so an unrelated edit must not block a reviewed staging click"
        )
    }

    func testPostStatusRevisionCheckRejectsAnEditThatLandsDuringPreflightIO() async throws {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let reviewed = await environment.unstagedRow("a.swift")
        let baseline = environment.backend.statusCallCount

        environment.backend.holdNextStatusReads()
        let mutation = Task {
            await environment.repository.applyMutation(
                AgentChangesMutationRequest(row: reviewed, stage: true)
            )
        }
        try await AsyncTestWait.waitUntil("the mutation preflight status read to suspend") {
            environment.backend.statusCallCount >= baseline + 1
        }

        await environment.repository.refresh(
            .contentDelta(paths: [environment.absolutePath("a.swift")])
        )
        environment.backend.releaseHeldStatusReads()
        let outcome = await mutation.value

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertTrue(environment.backend.stagedPathBatches.isEmpty)
    }

    func testRenameOriginOutsideScopeMakesTheRowNonStageable() async {
        let environment = makeEnvironment(
            entries: [
                VCSIndexStatusEntry(
                    path: "packages/a/new.swift",
                    originalPath: "packages/b/old.swift",
                    indexStatus: ".",
                    workTreeStatus: "R"
                )
            ],
            pathspecPrefixes: ["packages/a/"]
        )
        await environment.start()
        let row = await environment.unstagedRow("packages/a/new.swift")

        XCTAssertFalse(row.isStageable)
        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected an explicit scope failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("outside"))
        XCTAssertTrue(environment.backend.stagedPathBatches.isEmpty)
    }

    func testIndexLockRetryRereadsAuthoritativeStatusBeforeRetrying() async throws {
        let scheduler = GateScheduler(heldDuration: .milliseconds(150))
        let environment = makeEnvironment(
            entries: [modified("a.swift")],
            repositoryScheduler: scheduler
        )
        await environment.start()
        let reviewed = await environment.unstagedRow("a.swift")
        let baselineStatus = environment.backend.statusCallCount
        environment.backend.enqueueStageFailure(GitIndexMutationError.indexLocked)

        let mutation = Task {
            await environment.repository.applyMutation(
                AgentChangesMutationRequest(row: reviewed, stage: true)
            )
        }
        try await AsyncTestWait.waitUntil("the contention retry delay to park") {
            scheduler.waiterCount == 1
        }

        // Model the contending Git process completing the requested stage while it held index.lock.
        environment.backend.setEntries(
            [VCSIndexStatusEntry(path: "a.swift", indexStatus: "M", workTreeStatus: ".")],
            at: environment.target.checkoutURL
        )
        scheduler.releaseAll()
        let outcome = await mutation.value

        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(environment.backend.stagedPathBatches.count, 1, "No blind second Git command ran")
        XCTAssertGreaterThanOrEqual(
            environment.backend.statusCallCount,
            baselineStatus + 2,
            "The repository must re-read index generation after contention"
        )
    }

    func testBulkStagingRejectsAFileThatAppearedAfterRender() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let reviewed = await environment.bulkRequest(section: .unstaged, stage: true)

        environment.backend.setEntries(
            [modified("a.swift"), modified("new.swift")],
            at: environment.target.checkoutURL
        )
        let outcome = await environment.repository.applyBulkMutation(reviewed)

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertTrue(
            environment.backend.stagedPathBatches.isEmpty,
            "Stage All must never silently acquire a file the user did not see"
        )
    }

    func testUnexpressibleTargetScopeDisablesAllIndexMutations() async {
        let target = AgentPanelResolvedCheckout(
            checkoutURL: URL(fileURLWithPath: "/tmp/unexpressible-scope"),
            repoRootURL: URL(fileURLWithPath: "/tmp/unexpressible-scope"),
            backendKind: .git,
            pathspecPrefixes: [],
            logicalRoots: [AgentPanelLogicalRoot(path: "/elsewhere/root")],
            worktree: nil,
            substitutesUnavailableWorktree: false,
            isMutationScopeRepresentable: false
        )
        let backend = FakeIndexBackend(entriesByCheckout: [
            target.checkoutURL.path: [modified("a.swift")]
        ])
        let repository = makeRepository(backend: backend, diffSource: FakeDiffSource())
        await repository.setTarget(target, mode: .workingTree)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        XCTAssertFalse(snapshot.supportsStaging)
        let row = XCTUnwrapped(snapshot.section(.unstaged)?.rows.first)
        XCTAssertFalse(row.isStageable)
        let outcome = await repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )
        XCTAssertEqual(outcome, .unsupported)
    }

    func testStagingAConflictedPathIsRefusedBeforeReachingGit() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(
                path: "conflict.swift",
                indexStatus: "U",
                workTreeStatus: "U",
                isConflicted: true
            )
        ])
        await environment.start()
        let row = await XCTUnwrapped(environment.repository.currentSnapshot().section(.conflicts)?.rows.first)

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        XCTAssertEqual(outcome, .conflicted)
        XCTAssertEqual(environment.backend.stagedPathBatches, [])
    }

    func testMarkResolvedUsesItsDistinctMutationAndRefreshesTheConflictOutOfItsSection() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(
                path: "conflict.swift",
                indexStatus: "U",
                workTreeStatus: "U",
                isConflicted: true
            )
        ])
        await environment.start()
        let row = await XCTUnwrapped(
            environment.repository.currentSnapshot().section(.conflicts)?.rows.first
        )

        let outcome = await environment.repository.markResolved(AgentChangesResolveRequest(row: row))

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.resolvedPathBatches, [["conflict.swift"]])
        XCTAssertEqual(environment.backend.stagedPathBatches, [], "Resolution has a distinct backend path")
        XCTAssertEqual(environment.publisher.publishCount, 1)
        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.section(.conflicts)?.rows ?? [], [])
        XCTAssertEqual(snapshot.section(.staged)?.rows.map(\.path), ["conflict.swift"])
    }

    func testMarkResolvedPreflightRejectsContentsEditedAfterReview() async {
        let environment = makeEnvironment(entries: [
            VCSIndexStatusEntry(
                path: "conflict.swift",
                indexStatus: "U",
                workTreeStatus: "U",
                isConflicted: true
            )
        ])
        await environment.start()
        let reviewed = await XCTUnwrapped(
            environment.repository.currentSnapshot().section(.conflicts)?.rows.first
        )
        await environment.repository.refresh(
            .contentDelta(paths: [environment.absolutePath("conflict.swift")])
        )
        await environment.repository.waitUntilIdle()

        let outcome = await environment.repository.markResolved(AgentChangesResolveRequest(row: reviewed))

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertEqual(environment.backend.resolvedPathBatches, [])
        XCTAssertEqual(environment.publisher.publishCount, 0)
    }

    func testConcurrentMutationsSerializeWithAnAuthoritativeRebuildBetweenThem() async {
        let environment = makeEnvironment(entries: [modified("a.swift"), modified("b.swift")])
        await environment.start()
        let rowA = await environment.unstagedRow("a.swift")
        let rowB = await environment.unstagedRow("b.swift")
        environment.backend.resetCallLog()

        async let firstOutcome = environment.repository.applyMutation(
            AgentChangesMutationRequest(row: rowA, stage: true)
        )
        async let secondOutcome = environment.repository.applyMutation(
            AgentChangesMutationRequest(row: rowB, stage: true)
        )
        let outcomes = await [firstOutcome, secondOutcome]

        XCTAssertEqual(outcomes, [.applied, .applied])
        let log = environment.backend.callLog
        let stageIndices = log.indices.filter { if case .stage = log[$0] { true } else { false } }
        XCTAssertEqual(stageIndices.count, 2, "Both mutations ran")
        let between = log[(stageIndices[0] + 1) ..< stageIndices[1]]
        XCTAssertTrue(
            between.contains(.status),
            "The second mutation must decide against the index the first one produced"
        )
    }

    func testBulkStagingOnlyTouchesPathsInsideTheRepresentedScope() async {
        let environment = makeEnvironment(
            entries: [modified("packages/a/x.swift"), modified("packages/b/y.swift")],
            pathspecPrefixes: ["packages/a/"]
        )
        await environment.start()

        let outcome = await environment.repository.applyBulkMutation(
            environment.bulkRequest(section: .unstaged, stage: true)
        )

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(
            environment.backend.stagedPathBatches,
            [["packages/a/x.swift"]],
            "A stage-all cannot reach files the workspace does not represent"
        )
    }

    func testBulkStagingSkipsConflictedPathsRatherThanFailing() async {
        let environment = makeEnvironment(entries: [
            modified("a.swift"),
            VCSIndexStatusEntry(
                path: "conflict.swift",
                indexStatus: "U",
                workTreeStatus: "U",
                isConflicted: true
            )
        ])
        await environment.start()

        let outcome = await environment.repository.applyBulkMutation(
            environment.bulkRequest(section: .unstaged, stage: true)
        )

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.stagedPathBatches, [["a.swift"]])
    }

    func testAFailedMutationForcesARebuildSoTheRowsStopShowingAPendingState() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        await environment.start()
        let row = await environment.unstagedRow("a.swift")
        environment.backend.setStageFailure(GitIndexMutationError.indexLocked)
        let baseline = environment.backend.statusCallCount

        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )

        guard case .failed = outcome else {
            return XCTFail("Expected a failure outcome, got \(outcome)")
        }
        XCTAssertGreaterThan(environment.backend.statusCallCount, baseline + 1)
        XCTAssertEqual(environment.publisher.publishCount, 0, "A refused mutation changed no index")
    }

    // MARK: - Capability degradation

    func testABackendWithoutAnIndexShowsOneWorkingCopyListAndNoStagingSurface() async {
        let environment = makeEnvironment(entries: [], capabilities: .jujutsu)
        environment.diffSource.setFiles(
            for: GitDiffCompareSpec.uncommitted(base: "HEAD"),
            files: [VCSUncommittedFile(path: "a.swift", status: "M", additions: 2, deletions: 1)]
        )
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.sections.map(\.kind), [.workingCopy])
        XCTAssertEqual(snapshot.sections.first?.rows.map(\.path), ["a.swift"])
        XCTAssertFalse(snapshot.supportsStaging)
        XCTAssertEqual(
            environment.backend.statusCallCount,
            0,
            "There is no index to read, so no porcelain decomposition is attempted"
        )
    }

    func testMutationOnABackendWithoutAnIndexIsUnsupportedWithoutReachingTheBackend() async {
        let environment = makeEnvironment(entries: [], capabilities: .jujutsu)
        environment.diffSource.setFiles(
            for: GitDiffCompareSpec.uncommitted(base: "HEAD"),
            files: [VCSUncommittedFile(path: "a.swift", status: "M")]
        )
        await environment.start()
        let row = await XCTUnwrapped(environment.repository.currentSnapshot().sections.first?.rows.first)

        let single = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )
        let bulk = await environment.repository.applyBulkMutation(
            environment.bulkRequest(section: .workingCopy, stage: true)
        )

        XCTAssertEqual(single, .unsupported)
        XCTAssertEqual(bulk, .unsupported)
        XCTAssertEqual(environment.backend.stagedPathBatches, [])
    }

    // MARK: - vs Base

    func testVsBaseModeShowsOneFlatReadOnlyList() async {
        let environment = makeEnvironment(entries: [modified("a.swift")])
        environment.diffSource.setFiles(
            for: GitDiffCompareSpec.uncommittedMergeBase(base: "main"),
            files: [VCSUncommittedFile(path: "a.swift", status: "M", additions: 4, deletions: 2)]
        )
        await environment.repository.setTarget(environment.target, mode: .vsBase(base: "main"))
        await environment.repository.waitUntilIdle()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.sections.map(\.kind), [.vsBase])
        XCTAssertEqual(snapshot.sections.first?.rows.map(\.path), ["a.swift"])
        XCTAssertEqual(snapshot.additions, 4)
        XCTAssertFalse(snapshot.supportsStaging)

        let row = XCTUnwrapped(snapshot.sections.first?.rows.first)
        let outcome = await environment.repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: true)
        )
        XCTAssertEqual(outcome, .unsupported)
    }

    // MARK: - Empty states

    func testACleanTreeReportsItsEmptyReasonRatherThanLookingBroken() async {
        let environment = makeEnvironment(entries: [])
        await environment.start()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.emptyReason, .cleanTree)
    }

    func testNoCheckoutReportsItsOwnEmptyReason() async {
        let environment = makeEnvironment(entries: [])
        await environment.repository.setTarget(nil, mode: .workingTree)
        await environment.repository.waitUntilIdle()

        let snapshot = await environment.repository.currentSnapshot()
        XCTAssertEqual(snapshot.emptyReason, .noCheckout)
    }

    // MARK: - Watch degradation

    func testAFailedScopedWatchDegradesToPollTriggers() async {
        let feed = AgentChangesLiveTriggerFeed(
            sources: AgentChangesTriggerSources(),
            scopedWatchPaths: [URL(fileURLWithPath: "/tmp/does-not-exist")],
            pollInterval: .seconds(5),
            scheduler: ImmediateScheduler(),
            makeScopedWatch: { _ in
                throw ScopedFileEventStreamError.missingPath("/tmp/does-not-exist")
            }
        )

        var triggers: [AgentChangesRefreshTrigger] = []
        for await trigger in feed.events() {
            triggers.append(trigger)
            if triggers.count == 3 { break }
        }
        feed.cancel()

        XCTAssertEqual(
            triggers,
            [.poll, .poll, .poll],
            "A worktree outside every workspace root is invisible without a watch, so it polls instead"
        )
    }

    func testScopedWatchBatchesArriveAsContentDeltaTriggers() async {
        let (batches, continuation) = AsyncStream<ScopedFileChangeBatch>.makeStream()
        let feed = AgentChangesLiveTriggerFeed(
            sources: AgentChangesTriggerSources(),
            scopedWatchPaths: [URL(fileURLWithPath: "/tmp/watched")],
            scheduler: ImmediateScheduler(),
            makeScopedWatch: { _ in
                AgentChangesScopedWatch(batches: batches, cancel: {})
            }
        )

        let events = feed.events()
        continuation.yield(ScopedFileChangeBatch(paths: ["/tmp/watched/a.swift"], mayHaveMissedEvents: false))
        var received: AgentChangesRefreshTrigger?
        for await trigger in events {
            received = trigger
            break
        }
        continuation.finish()
        feed.cancel()

        XCTAssertEqual(received, .contentDelta(paths: ["/tmp/watched/a.swift"]))
    }

    func testScopedWatchHistoryGapsRequestFullResyncWithAndWithoutPaths() async {
        let cases: [(ScopedFileChangeBatch, [AgentChangesRefreshTrigger])] = [
            (
                ScopedFileChangeBatch(paths: [], mayHaveMissedEvents: true),
                [.contentDelta(paths: [])]
            ),
            (
                ScopedFileChangeBatch(paths: ["/tmp/watched/a.swift"], mayHaveMissedEvents: true),
                [
                    .contentDelta(paths: []),
                    .contentDelta(paths: ["/tmp/watched/a.swift"])
                ]
            )
        ]

        for (batch, expected) in cases {
            let (batches, continuation) = AsyncStream<ScopedFileChangeBatch>.makeStream()
            let feed = AgentChangesLiveTriggerFeed(
                sources: AgentChangesTriggerSources(),
                scopedWatchPaths: [URL(fileURLWithPath: "/tmp/watched")],
                scheduler: ImmediateScheduler(),
                makeScopedWatch: { _ in
                    AgentChangesScopedWatch(batches: batches, cancel: {})
                }
            )

            let events = feed.events()
            continuation.yield(batch)
            continuation.finish()
            var received: [AgentChangesRefreshTrigger] = []
            for await trigger in events {
                received.append(trigger)
                if received.count == expected.count { break }
            }
            feed.cancel()

            XCTAssertEqual(received, expected)
        }
    }

    // MARK: - Real repository integration

    func testPorcelainDecompositionAgainstARealRepositorySplitsEverySection() async throws {
        let repo = try makeGitFixture(committing: [
            "staged.txt": "one\n",
            "unstaged.txt": "two\n",
            "partial.txt": "three\n"
        ])
        try write("staged edit\n", to: "staged.txt", in: repo)
        try runGit(["add", "staged.txt"], cwd: repo)
        try write("unstaged edit\n", to: "unstaged.txt", in: repo)
        try write("partial staged\n", to: "partial.txt", in: repo)
        try runGit(["add", "partial.txt"], cwd: repo)
        try write("partial staged then edited again\n", to: "partial.txt", in: repo)
        try write("brand new\n", to: "untracked.txt", in: repo)

        let repository = makeLiveRepository()
        await repository.setTarget(makeCheckout(url: repo), mode: .workingTree)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        XCTAssertEqual(snapshot.loadState, .ready)
        XCTAssertEqual(
            Set(snapshot.section(.staged)?.rows.map(\.path) ?? []),
            ["staged.txt", "partial.txt"]
        )
        XCTAssertEqual(
            Set(snapshot.section(.unstaged)?.rows.map(\.path) ?? []),
            ["unstaged.txt", "partial.txt", "untracked.txt"]
        )
        XCTAssertEqual(snapshot.section(.conflicts)?.rows ?? [], [])
        XCTAssertEqual(
            snapshot.section(.staged)?.rows.first { $0.path == "partial.txt" }?.hasCounterpartSection,
            true
        )
        XCTAssertEqual(
            snapshot.section(.staged)?.rows.first { $0.path == "staged.txt" }?.additions,
            1,
            "Stats come from the diff read that enriches porcelain's answer"
        )
        await repository.shutdown()
    }

    func testScopedRealRenameNeverStagesItsOutOfScopeOrigin() async throws {
        let repo = try makeGitFixture(committing: [
            "outside.txt": "content\n",
            "inside/seed.txt": "seed\n"
        ])
        try runGit(["config", "status.renames", "true"], cwd: repo)
        try runGit(["mv", "outside.txt", "inside/moved.txt"], cwd: repo)

        let repository = makeLiveRepository()
        let target = makeCheckout(url: repo, pathspecPrefixes: ["inside/"])
        await repository.setTarget(target, mode: .workingTree)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        let row = try XCTUnwrap(
            snapshot.section(.staged)?.rows.first(where: { $0.path == "inside/moved.txt" })
        )
        XCTAssertEqual(row.originalPath, "outside.txt")
        XCTAssertFalse(row.isStageable)

        let outcome = await repository.applyMutation(
            AgentChangesMutationRequest(row: row, stage: false)
        )
        guard case .failed = outcome else {
            return XCTFail("Expected the scope-escaping rename to be refused")
        }
        let staged = try TestGitCommandRunner.run(
            ["diff", "--cached", "--name-status"],
            cwd: repo,
            failureDomain: "AgentChangesRepositoryTests.git"
        )
        XCTAssertTrue(staged.contains("outside.txt"))
        XCTAssertTrue(staged.contains("inside/moved.txt"))
        XCTAssertTrue(
            staged.hasPrefix("R"),
            "Refusing the scoped mutation must leave the indexed rename untouched"
        )
        await repository.shutdown()
    }

    func testARealRepositoryPatchLoadProjectsTheExpandedFilesHunk() async throws {
        let repo = try makeGitFixture(committing: ["main.swift": "let a = 1\nlet b = 2\nlet c = 3\n"])
        try write("let a = 1\nlet b = 22\nlet c = 3\n", to: "main.swift", in: repo)

        let repository = makeLiveRepository()
        await repository.setTarget(makeCheckout(url: repo), mode: .workingTree)
        await repository.waitUntilIdle()

        let snapshot = await repository.currentSnapshot()
        let row = XCTUnwrapped(snapshot.section(.unstaged)?.rows.first)
        let state = await repository.patch(for: row)

        guard case let .loaded(document) = state else {
            return XCTFail("Expected a projected patch, got \(state)")
        }
        XCTAssertEqual(document.id, "main.swift")
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
        let changed = document.hunks.flatMap(\.lines).filter { $0.kind != .context }
        XCTAssertEqual(changed.map(\.text), ["let b = 2", "let b = 22"])
        XCTAssertEqual(changed.map(\.oldLine), [2, nil])
        XCTAssertEqual(changed.map(\.newLine), [nil, 2])
        await repository.shutdown()
    }

    func testLiveFileContentSourceReadsWorktreeIndexAndReferenceVersions() async throws {
        let repo = try makeGitFixture(committing: ["state.txt": "head\n"])
        try write("index\n", to: "state.txt", in: repo)
        try runGit(["add", "--", "state.txt"], cwd: repo)
        try write("worktree\n", to: "state.txt", in: repo)

        let gitService = GitService()
        let source = AgentChangesLiveDiffSource(
            engine: GitDiffEngine(vcsService: VCSService(), gitService: gitService),
            gitService: gitService
        )

        let worktree = try await source.loadFileContent(
            source: .worktree(path: "state.txt"),
            at: repo,
            byteLimit: 1024
        )
        let index = try await source.loadFileContent(
            source: .index(path: "state.txt"),
            at: repo,
            byteLimit: 1024
        )
        let reference = try await source.loadFileContent(
            source: .reference(.named("HEAD"), path: "state.txt"),
            at: repo,
            byteLimit: 1024
        )

        XCTAssertEqual(worktree.lines, ["worktree"])
        XCTAssertEqual(index.lines, ["index"])
        XCTAssertEqual(reference.lines, ["head"])
    }

    func testVsBaseContextKeepsThePatchMergeBasePinnedAfterTheBranchMoves() async throws {
        let repo = try makeGitFixture(committing: [
            "state.txt": "base one\nbase two\nbase three\n"
        ])
        try runGit(["branch", "base"], cwd: repo)

        let gitService = GitService()
        let originalBase = try await gitService.getHeadSHA(at: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("state.txt"))
        try runGit(["add", "-A"], cwd: repo)
        try runGit(["commit", "-m", "Delete state"], cwd: repo)

        let source = AgentChangesLiveDiffSource(
            engine: GitDiffEngine(vcsService: VCSService(), gitService: gitService),
            gitService: gitService
        )
        let loadedPayload = try await source.loadPatch(
            compare: .uncommittedMergeBase(base: "base"),
            paths: ["state.txt"],
            at: repo,
            contextLines: 0
        )
        let payload = try XCTUnwrap(loadedPayload)
        let patch = try XCTUnwrap(payload.perFile["state.txt"])
        let document = DiffLineProjector.project(
            patch: patch,
            fileKey: "state.txt",
            contextLevel: .lines(0),
            oldSourceReference: payload.oldSourceReference
        )
        let row = AgentChangesFileRow(
            id: "vsBase:state.txt",
            fileKey: "state.txt",
            path: "state.txt",
            originalPath: nil,
            section: .vsBase,
            indexStatus: nil,
            workTreeStatus: "D",
            isUntracked: false,
            isConflicted: false,
            additions: 0,
            deletions: 3,
            hasCounterpartSection: false,
            contentRevision: 0
        )
        let selection = try XCTUnwrap(AgentChangesContextSourceResolver.selection(
            for: row,
            document: document,
            mode: .vsBase(base: "base"),
            hasHeadCommit: true
        ))

        try runGit(["branch", "-f", "base", "HEAD"], cwd: repo)
        XCTAssertEqual(payload.oldSourceReference, originalBase)
        XCTAssertEqual(
            selection,
            AgentChangesContextSourceSelection(
                source: .reference(.named(originalBase), path: "state.txt"),
                side: .old
            )
        )
        let content = try await source.loadFileContent(
            source: selection.source,
            at: repo,
            byteLimit: 1024
        )
        XCTAssertEqual(content.lines, ["base one", "base two", "base three"])
    }

    // MARK: - Environment

    private struct Environment {
        let repository: AgentChangesRepository
        let backend: FakeIndexBackend
        let diffSource: FakeDiffSource
        let publisher: FakeInvalidationPublisher
        let target: AgentPanelResolvedCheckout

        func start() async {
            await repository.setTarget(target, mode: .workingTree)
            await repository.waitUntilIdle()
        }

        func absolutePath(_ repositoryRelativePath: String) -> String {
            target.checkoutURL.appendingPathComponent(repositoryRelativePath).path
        }

        func unstagedRow(_ path: String) async -> AgentChangesFileRow {
            let snapshot = await repository.currentSnapshot()
            guard let row = snapshot.section(.unstaged)?.rows.first(where: { $0.path == path }) else {
                fatalError("No unstaged row for \(path)")
            }
            return row
        }

        func bulkRequest(
            section: AgentChangesSectionKind,
            stage: Bool
        ) async -> AgentChangesBulkMutationRequest {
            let snapshot = await repository.currentSnapshot()
            return AgentChangesBulkMutationRequest(
                section: section,
                stage: stage,
                rows: snapshot.section(section)?.rows.filter(\.isStageable) ?? []
            )
        }
    }

    private func makeEnvironment(
        entries: [VCSIndexStatusEntry],
        capabilities: VCSCapabilities = .git,
        pathspecPrefixes: [String] = [],
        patchByteLimit: Int = 2 * 1024 * 1024,
        repositoryScheduler: any AgentChangesScheduler = ImmediateScheduler()
    ) -> Environment {
        let target = makeCheckout(path: "/tmp/agent-changes-checkout", pathspecPrefixes: pathspecPrefixes)
        let backend = FakeIndexBackend(
            entriesByCheckout: [target.checkoutURL.path: entries],
            capabilities: capabilities
        )
        let diffSource = FakeDiffSource()
        let publisher = FakeInvalidationPublisher()
        let repository = makeRepository(
            backend: backend,
            diffSource: diffSource,
            publisher: publisher,
            patchByteLimit: patchByteLimit,
            scheduler: repositoryScheduler
        )
        return Environment(
            repository: repository,
            backend: backend,
            diffSource: diffSource,
            publisher: publisher,
            target: target
        )
    }

    private func makeRepository(
        backend: FakeIndexBackend,
        diffSource: FakeDiffSource,
        publisher: FakeInvalidationPublisher = FakeInvalidationPublisher(),
        patchByteLimit: Int = 2 * 1024 * 1024,
        scheduler: any AgentChangesScheduler = ImmediateScheduler(),
        contentDeltaWindow: Duration = .zero
    ) -> AgentChangesRepository {
        AgentChangesRepository(
            indexBackend: backend,
            diffSource: diffSource,
            invalidationPublisher: publisher,
            scheduler: scheduler,
            contentDeltaWindow: contentDeltaWindow,
            patchByteLimit: patchByteLimit,
            makeTriggerFeed: { _ in InertTriggerFeed() }
        )
    }

    private func makeLiveRepository() -> AgentChangesRepository {
        AgentChangesRepository(
            indexBackend: AgentChangesLiveIndexBackend(vcsService: VCSService()),
            diffSource: AgentChangesLiveDiffSource(
                engine: GitDiffEngine(vcsService: VCSService(), gitService: GitService())
            ),
            invalidationPublisher: FakeInvalidationPublisher(),
            scheduler: ImmediateScheduler(),
            contentDeltaWindow: .zero,
            makeTriggerFeed: { _ in InertTriggerFeed() }
        )
    }

    private func makeCheckout(
        path: String,
        pathspecPrefixes: [String] = []
    ) -> AgentPanelResolvedCheckout {
        makeCheckout(url: URL(fileURLWithPath: path), pathspecPrefixes: pathspecPrefixes)
    }

    private func makeCheckout(
        url: URL,
        pathspecPrefixes: [String] = []
    ) -> AgentPanelResolvedCheckout {
        AgentPanelResolvedCheckout(
            checkoutURL: url.standardizedFileURL,
            repoRootURL: url.standardizedFileURL,
            backendKind: .git,
            pathspecPrefixes: pathspecPrefixes,
            logicalRoots: [AgentPanelLogicalRoot(path: url.path)],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )
    }

    private func modified(_ path: String) -> VCSIndexStatusEntry {
        VCSIndexStatusEntry(path: path, indexStatus: ".", workTreeStatus: "M")
    }

    private static func patchText(path: String) -> String {
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

    private static func patchTextWithLeadingGap(path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -5,3 +5,3 @@
         line 5
        -line 6 old
        +line 6 new
         line 7
        """
    }

    // MARK: - Git fixtures

    private func makeGitFixture(committing files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChangesRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoot = root
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test User"], cwd: repo)
        try runGit(["config", "commit.gpgsign", "false"], cwd: repo)
        for (name, body) in files {
            try write(body, to: name, in: repo)
        }
        try runGit(["add", "-A"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return repo
    }

    private func write(_ body: String, to name: String, in repo: URL) throws {
        let destination = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: destination, atomically: true, encoding: .utf8)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        try TestGitCommandRunner.run(
            arguments,
            cwd: cwd,
            failureDomain: "AgentChangesRepositoryTests.git"
        )
    }
}

// MARK: - Unwrap helper

private func XCTUnwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
    guard let value else {
        XCTFail("Unexpected nil", file: file, line: line)
        fatalError("Unexpected nil")
    }
    return value
}

// MARK: - Fakes

/// Collects published snapshots across the actor boundary without a data race.
private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AgentChangesSnapshot] = []

    func append(_ snapshot: AgentChangesSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    func readyCount(forTarget id: String) -> Int {
        lock.withLock {
            snapshots.count(where: { $0.target?.id == id && $0.loadState == .ready })
        }
    }
}

private struct ImmediateScheduler: AgentChangesScheduler {
    func sleep(for _: Duration) async throws {
        await Task.yield()
    }
}

private final class GateScheduler: AgentChangesScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private let heldDuration: Duration?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(heldDuration: Duration? = nil) {
        self.heldDuration = heldDuration
    }

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isReleased = true
            let result = waiters
            waiters = []
            return result
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func sleep(for duration: Duration) async throws {
        if let heldDuration, heldDuration != duration {
            await Task.yield()
            return
        }
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

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var value: Bool {
        lock.withLock { completed }
    }

    func set() {
        lock.withLock { completed = true }
    }
}

private struct InertTriggerFeed: AgentChangesTriggerFeed {
    func events() -> AsyncStream<AgentChangesRefreshTrigger> {
        AsyncStream { $0.finish() }
    }

    func cancel() {}
}

private final class FakeInvalidationPublisher: AgentChangesInvalidationPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var publishCount: Int {
        lock.withLock { count }
    }

    func publishIndexMutation(at _: URL) async {
        lock.withLock { count += 1 }
    }
}

/// An in-memory index that behaves enough like Git for section and staging rules to be exercised.
///
/// Lock-guarded rather than an actor so assertions can read its counters directly: `XCTAssertEqual`
/// takes autoclosures, which cannot await.
private final class FakeIndexBackend: AgentChangesIndexBackend, @unchecked Sendable {
    enum Call: Equatable {
        case status
        case stage([String])
        case unstage([String])
        case markResolved(String)
    }

    private let lock = NSLock()
    private var entriesByCheckout: [String: [VCSIndexStatusEntry]]
    private var capabilitiesValue: VCSCapabilities
    private var capabilitiesByCheckout: [String: VCSCapabilities] = [:]
    private var heldCapabilityCheckouts: Set<String> = []
    private var capabilityWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var capabilityCalls: [String] = []
    private var hasHead = true
    private var stageFailure: (any Error)?
    private var queuedStageFailures: [any Error] = []
    private var log: [Call] = []
    private var stagedBatches: [[String]] = []
    private var unstagedBatches: [[String]] = []
    private var resolvedBatches: [[String]] = []
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(entriesByCheckout: [String: [VCSIndexStatusEntry]], capabilities: VCSCapabilities = .git) {
        self.entriesByCheckout = entriesByCheckout
        capabilitiesValue = capabilities
    }

    var callLog: [Call] {
        lock.withLock { log }
    }

    var statusCallCount: Int {
        lock.withLock { log.count(where: { $0 == .status }) }
    }

    var stagedPathBatches: [[String]] {
        lock.withLock { stagedBatches }
    }

    var unstagedPathBatches: [[String]] {
        lock.withLock { unstagedBatches }
    }

    var resolvedPathBatches: [[String]] {
        lock.withLock { resolvedBatches }
    }

    var capabilityCallPaths: [String] {
        lock.withLock { capabilityCalls }
    }

    func setEntries(_ entries: [VCSIndexStatusEntry], at checkout: URL) {
        lock.withLock { entriesByCheckout[checkout.standardizedFileURL.path] = entries }
    }

    func setCapabilities(_ capabilities: VCSCapabilities, at checkout: URL) {
        lock.withLock { capabilitiesByCheckout[checkout.standardizedFileURL.path] = capabilities }
    }

    func holdCapabilities(at checkout: URL) {
        lock.withLock { _ = heldCapabilityCheckouts.insert(checkout.standardizedFileURL.path) }
    }

    func releaseCapabilities(at checkout: URL) {
        let key = checkout.standardizedFileURL.path
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            heldCapabilityCheckouts.remove(key)
            return capabilityWaiters.removeValue(forKey: key) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func setHasHeadCommit(_ value: Bool) {
        lock.withLock { hasHead = value }
    }

    func setStageFailure(_ error: any Error) {
        lock.withLock { stageFailure = error }
    }

    func enqueueStageFailure(_ error: any Error) {
        lock.withLock { queuedStageFailures.append(error) }
    }

    func resetCallLog() {
        lock.withLock {
            log = []
            stagedBatches = []
            unstagedBatches = []
            resolvedBatches = []
        }
    }

    /// Blocks every status read until ``releaseHeldStatusReads()``, so a test can observe what
    /// happens while a rebuild is genuinely in flight.
    func holdNextStatusReads() {
        lock.withLock { isHolding = true }
    }

    func releaseHeldStatusReads() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            isHolding = false
            let pending = held
            held = []
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func capabilities(at checkout: URL) async -> VCSCapabilities {
        let key = checkout.standardizedFileURL.path
        let shouldHold: Bool = lock.withLock {
            capabilityCalls.append(key)
            return heldCapabilityCheckouts.contains(key)
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    guard heldCapabilityCheckouts.contains(key) else { return true }
                    capabilityWaiters[key, default: []].append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return lock.withLock { capabilitiesByCheckout[key] ?? capabilitiesValue }
    }

    func hasHeadCommit(at _: URL) async throws -> Bool {
        lock.withLock { hasHead }
    }

    func loadIndexStatus(at checkout: URL) async throws -> [VCSIndexStatusEntry] {
        let holding: Bool = lock.withLock {
            log.append(.status)
            return isHolding
        }
        if holding {
            await withCheckedContinuation { continuation in
                let shouldResumeNow: Bool = lock.withLock {
                    guard isHolding else { return true }
                    held.append(continuation)
                    return false
                }
                if shouldResumeNow { continuation.resume() }
            }
        }
        return lock.withLock { entriesByCheckout[checkout.standardizedFileURL.path] ?? [] }
    }

    func stage(_ identities: [VCSIndexPathIdentity], at checkout: URL) async throws {
        let failure: (any Error)? = lock.withLock {
            log.append(.stage(identities.map(\.path)))
            stagedBatches.append(identities.map(\.path))
            if !queuedStageFailures.isEmpty {
                return queuedStageFailures.removeFirst()
            }
            return stageFailure
        }
        if let failure { throw failure }
        mutate(identities, at: checkout) { entry in
            let staged: Character = entry.isUntracked ? "A" : (entry.workTreeStatus ?? "M")
            return VCSIndexStatusEntry(
                path: entry.path,
                originalPath: entry.originalPath,
                indexStatus: staged,
                workTreeStatus: ".",
                isUntracked: false,
                isConflicted: entry.isConflicted
            )
        }
    }

    func unstage(_ identities: [VCSIndexPathIdentity], at checkout: URL) async throws {
        lock.withLock {
            log.append(.unstage(identities.map(\.path)))
            unstagedBatches.append(identities.map(\.path))
        }
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
        lock.withLock {
            log.append(.markResolved(identity.path))
            resolvedBatches.append([identity.path])
        }
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

private final class FakeDiffSource: AgentChangesDiffSource, @unchecked Sendable {
    private let lock = NSLock()
    private var filesByCompare: [String: [VCSUncommittedFile]] = [:]
    private var patchesByPath: [String: String] = [:]
    private var statusHash = "initial"
    private var fingerprintCalls = 0
    private var patchCalls = 0
    private var compares: [String] = []
    private var contextLines: [Int] = []
    private var patchPaths: [[String]] = []
    private var fileContents: [AgentChangesFileContentSource: Data] = [:]
    private var revisionValidations: [String: AgentChangesRevisionValidation] = [:]
    private var fileContentCalls = 0

    var fingerprintCallCount: Int {
        lock.withLock { fingerprintCalls }
    }

    var patchCallCount: Int {
        lock.withLock { patchCalls }
    }

    var metadataCompares: [String] {
        lock.withLock { compares }
    }

    var requestedContextLines: [Int] {
        lock.withLock { contextLines }
    }

    var requestedPatchPaths: [[String]] {
        lock.withLock { patchPaths }
    }

    var fileContentCallCount: Int {
        lock.withLock { fileContentCalls }
    }

    func setStatusHash(_ value: String) {
        lock.withLock { statusHash = value }
    }

    func setRevisionValidation(_ validation: AgentChangesRevisionValidation, for revision: String) {
        lock.withLock { revisionValidations[revision] = validation }
    }

    func setFiles(for compare: GitDiffCompareSpec, files: [VCSUncommittedFile]) {
        lock.withLock { filesByCompare[compare.rawKey] = files }
    }

    func setPatch(for path: String, text: String) {
        lock.withLock { patchesByPath[path] = text }
    }

    func setFileContent(for source: AgentChangesFileContentSource, text: String) {
        lock.withLock { fileContents[source] = Data(text.utf8) }
    }

    func resolveRevision(_ revision: String, at _: URL) async -> AgentChangesRevisionValidation {
        lock.withLock {
            revisionValidations[revision] ?? .invalid("Unknown revision")
        }
    }

    func fingerprint(compare _: GitDiffCompareSpec, at _: URL) async throws -> GitDiffFingerprint {
        lock.withLock {
            fingerprintCalls += 1
            return currentFingerprintLocked()
        }
    }

    func loadMetadata(
        compare: GitDiffCompareSpec,
        pathspecs _: [String],
        at _: URL
    ) async throws -> AgentChangesDiffMetadata {
        lock.withLock {
            compares.append(compare.rawKey)
            return AgentChangesDiffMetadata(
                fingerprint: currentFingerprintLocked(),
                files: filesByCompare[compare.rawKey] ?? defaultFilesLocked()
            )
        }
    }

    func loadPatch(
        compare _: GitDiffCompareSpec,
        paths: [String],
        at _: URL,
        contextLines requestedContext: Int
    ) async throws -> AgentChangesPatchPayload? {
        lock.withLock {
            patchCalls += 1
            contextLines.append(requestedContext)
            patchPaths.append(paths)
            guard let primary = paths.first, let text = patchesByPath[primary] else { return nil }
            return AgentChangesPatchPayload(
                perFile: [primary: text],
                fingerprint: currentFingerprintLocked()
            )
        }
    }

    func loadFileContent(
        source: AgentChangesFileContentSource,
        at _: URL,
        byteLimit: Int
    ) async throws -> AgentChangesFileContent {
        let data: Data? = lock.withLock {
            fileContentCalls += 1
            return fileContents[source]
        }
        guard let data else {
            throw AgentChangesFileContentReadError.unavailable("No fake content for \(source).")
        }
        guard data.count <= byteLimit else {
            throw AgentChangesFileContentReadError.tooLarge(limit: byteLimit)
        }
        return try AgentChangesFileContent(data: data)
    }

    /// Stats for paths the tests did not configure explicitly: one added and one removed line per
    /// file the fake has a patch for, so rows carry plausible counts without every test declaring
    /// them.
    private func defaultFilesLocked() -> [VCSUncommittedFile] {
        patchesByPath.keys.sorted().map {
            VCSUncommittedFile(path: $0, status: "M", additions: 1, deletions: 1)
        }
    }

    private func currentFingerprintLocked() -> GitDiffFingerprint {
        GitDiffFingerprint(
            headSHA: "head",
            baseRef: "INDEX",
            statusHash: statusHash,
            generatedAt: Date()
        )
    }
}
