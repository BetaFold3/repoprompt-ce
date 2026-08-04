@testable import RepoPromptApp
import XCTest

final class AgentChangesRepositoryPartialStagingTests: XCTestCase {
    func testDescriptorRequiresVisibleRawPatchAndSearchNeverMintsReviewToken() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let row = try await environment.unstagedRow()

        let search = await environment.repository.searchDocument(for: row)
        let searchDocument = try XCTUnwrap(search.document)
        let searchDescriptor = await environment.repository.partialStagingDescriptor(
            for: row,
            renderedDocument: searchDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(searchDescriptor.availability, .unavailable(.rawPatchUnavailable))
        XCTAssertNil(searchDescriptor.reviewToken)

        let (_, descriptor) = try await environment.visibleDescriptor(row: row)
        XCTAssertEqual(descriptor.availability, .available)
        XCTAssertNotNil(descriptor.reviewToken)
        XCTAssertEqual(environment.diffSource.patchCallCount, 2)
    }

    func testDescriptorFailsClosedForTruncatedStructuralUntrackedAndUnsupportedRows() async throws {
        let truncated = makeEnvironment(patchLineLimit: 1)
        await truncated.start()
        let truncatedRow = try await truncated.unstagedRow()
        let truncatedPatch = await truncated.repository.patch(for: truncatedRow)
        let truncatedDocument = try XCTUnwrap(truncatedPatch.document)
        let truncatedDescriptor = await truncated.repository.partialStagingDescriptor(
            for: truncatedRow,
            renderedDocument: truncatedDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(truncatedDescriptor.availability, .unavailable(.truncatedProjection))

        let untracked = makeEnvironment(
            entry: VCSIndexStatusEntry(path: "file.txt", isUntracked: true),
            patch: """
            diff --git a/file.txt b/file.txt
            new file mode 100644
            --- /dev/null
            +++ b/file.txt
            @@ -0,0 +1 @@
            +new
            """ + "\n"
        )
        await untracked.start()
        let untrackedRow = try await untracked.unstagedRow()
        let untrackedPatch = await untracked.repository.patch(for: untrackedRow)
        let untrackedDocument = try XCTUnwrap(untrackedPatch.document)
        let untrackedDescriptor = await untracked.repository.partialStagingDescriptor(
            for: untrackedRow,
            renderedDocument: untrackedDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(untrackedDescriptor.availability, .unavailable(.untrackedRequiresWholeFile))

        let structural = makeEnvironment(
            entry: VCSIndexStatusEntry(
                path: "file.txt",
                originalPath: "old.txt",
                indexStatus: ".",
                workTreeStatus: "R"
            ),
            patch: """
            diff --git a/old.txt b/file.txt
            similarity index 90%
            rename from old.txt
            rename to file.txt
            --- a/old.txt
            +++ b/file.txt
            @@ -1 +1 @@
            -old
            +new
            """ + "\n"
        )
        await structural.start()
        let structuralRow = try await structural.unstagedRow()
        let structuralPatch = await structural.repository.patch(for: structuralRow)
        let structuralDocument = try XCTUnwrap(structuralPatch.document)
        let structuralDescriptor = await structural.repository.partialStagingDescriptor(
            for: structuralRow,
            renderedDocument: structuralDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(structuralDescriptor.availability, .unavailable(.structuralChange))

        let unsupported = makeEnvironment(capabilities: .jujutsu)
        await unsupported.start()
        let unsupportedSnapshot = await unsupported.repository.currentSnapshot()
        let unsupportedRow = try XCTUnwrap(unsupportedSnapshot.sections.first?.rows.first)
        let unsupportedPatch = await unsupported.repository.patch(for: unsupportedRow)
        let unsupportedDocument = try XCTUnwrap(unsupportedPatch.document)
        let unsupportedDescriptor = await unsupported.repository.partialStagingDescriptor(
            for: unsupportedRow,
            renderedDocument: unsupportedDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(unsupportedDescriptor.availability, .unavailable(.backendHasNoIndex))
    }

    func testContentAndModeChangeReportsStructuralUnavailableReasonPersistently() async throws {
        let environment = makeEnvironment(patch: """
        diff --git a/file.txt b/file.txt
        old mode 100644
        new mode 100755
        index 1111111..2222222
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new
        """ + "\n")
        await environment.start()
        let row = try await environment.unstagedRow()
        let patch = await environment.repository.patch(for: row)
        let document = try XCTUnwrap(patch.document)

        let first = await environment.repository.partialStagingDescriptor(
            for: row,
            renderedDocument: document,
            contextLevel: .standard
        )
        let derivedAgain = await environment.repository.partialStagingDescriptor(
            for: row,
            renderedDocument: document,
            contextLevel: .standard
        )

        XCTAssertEqual(first.availability, .unavailable(.structuralChange))
        XCTAssertEqual(derivedAgain.availability, .unavailable(.structuralChange))
        XCTAssertNil(derivedAgain.reviewToken)
    }

    func testNoNewlineHunksStayWholeHunkOnlyAndRefuseLineRequests() async throws {
        let environment = makeEnvironment(patch: Self.noNewlinePatch)
        await environment.start()
        let row = try await environment.unstagedRow()
        let (_, descriptor) = try await environment.visibleDescriptor(row: row)

        XCTAssertEqual(descriptor.availability, .available)
        let hunk = try XCTUnwrap(descriptor.changedLineKeysByHunkID.first)
        XCTAssertEqual(hunk.value, [.deletion(oldLine: 2), .addition(newLine: 2)])
        XCTAssertTrue(
            descriptor.selectableChangedLineKeys.isEmpty,
            "A hunk git annotated with a no-newline marker offers no per-line selection"
        )

        let token = try XCTUnwrap(descriptor.reviewToken)
        let lineOutcome = await environment.repository.applyPartialMutation(
            AgentChangesPartialMutationRequest(
                reviewToken: token,
                row: row,
                selection: .lines(projectedHunkID: hunk.key, lines: [.addition(newLine: 2)])
            )
        )
        XCTAssertFalse(lineOutcome.didMutate)
        XCTAssertEqual(environment.backend.applyCallCount, 0)

        let hunkOutcome = await environment.repository.applyPartialMutation(
            AgentChangesPartialMutationRequest(
                reviewToken: token,
                row: row,
                selection: .hunk(projectedHunkID: hunk.key, lines: hunk.value)
            )
        )
        XCTAssertEqual(hunkOutcome, .applied)
        XCTAssertEqual(environment.backend.applyCallCount, 1)
    }

    func testMatchingContentFingerprintAndRetargetInvalidateReviewTokens() async throws {
        let content = makeEnvironment()
        await content.start()
        let contentRequest = try await content.hunkRequest()
        await content.repository.refresh(.contentDelta(paths: [content.absolutePath("file.txt")]))
        let contentOutcome = await content.repository.applyPartialMutation(contentRequest)
        XCTAssertEqual(contentOutcome, .contentChanged)
        XCTAssertEqual(content.backend.applyCallCount, 0)

        let fingerprint = makeEnvironment()
        await fingerprint.start()
        let fingerprintRequest = try await fingerprint.hunkRequest()
        fingerprint.diffSource.setStatusHash("moved")
        await fingerprint.repository.refresh(.metadata)
        await fingerprint.repository.waitUntilIdle()
        let fingerprintOutcome = await fingerprint.repository.applyPartialMutation(fingerprintRequest)
        XCTAssertEqual(fingerprintOutcome, .contentChanged)
        XCTAssertEqual(fingerprint.backend.applyCallCount, 0)

        let retarget = makeEnvironment()
        await retarget.start()
        let retargetRequest = try await retarget.hunkRequest()
        let otherTarget = makeTarget(path: "/tmp/agent-changes-partial-other")
        await retarget.repository.setTarget(otherTarget, mode: .workingTree)
        await retarget.repository.waitUntilIdle()
        let retargetOutcome = await retarget.repository.applyPartialMutation(retargetRequest)
        XCTAssertEqual(retargetOutcome, .contentChanged)
        XCTAssertEqual(retarget.backend.applyCallCount, 0)
    }

    func testSameTargetEpochInvalidatesReviewTokenAndSuspendedWholeFilePreflight() async throws {
        let partial = makeEnvironment()
        await partial.start(requestID: 1)
        let partialRow = try await partial.unstagedRow()
        let (_, descriptor) = try await partial.visibleDescriptor(row: partialRow)
        let staleToken = try XCTUnwrap(descriptor.reviewToken)
        let hunk = try XCTUnwrap(descriptor.changedLineKeysByHunkID.first)
        let staleRequest = AgentChangesPartialMutationRequest(
            reviewToken: staleToken,
            row: partialRow,
            selection: .hunk(projectedHunkID: hunk.key, lines: hunk.value)
        )

        await partial.repository.setTarget(partial.target, mode: .workingTree, requestID: 3)
        let staleOutcome = await partial.repository.applyPartialMutation(staleRequest)
        XCTAssertEqual(staleOutcome, .contentChanged)
        XCTAssertEqual(partial.backend.applyCallCount, 0)

        let refreshedRow = try await partial.unstagedRow()
        let (_, refreshedDescriptor) = try await partial.visibleDescriptor(row: refreshedRow)
        XCTAssertEqual(refreshedDescriptor.availability, .available)
        XCTAssertNotEqual(refreshedDescriptor.reviewToken, staleToken)

        let wholeFile = makeEnvironment()
        await wholeFile.start(requestID: 1)
        let reviewedRow = try await wholeFile.unstagedRow()
        let wholeFileRequest = AgentChangesMutationRequest(
            row: reviewedRow,
            stage: true,
            targetRequestID: 1
        )
        wholeFile.backend.scopedStatusGate.hold()
        let wholeFileTask = Task {
            await wholeFile.repository.applyMutation(wholeFileRequest)
        }
        await wholeFile.backend.scopedStatusGate.waitUntilEntered()

        await wholeFile.repository.setTarget(wholeFile.target, mode: .workingTree, requestID: 3)
        wholeFile.backend.scopedStatusGate.release()
        let wholeFileOutcome = await wholeFileTask.value

        XCTAssertEqual(wholeFileOutcome, .contentChanged)
        XCTAssertEqual(wholeFile.backend.stageCallCount, 0)
    }

    func testUnrelatedContentRevisionKeepsTokenValid() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("other.txt")]))
        await environment.repository.waitUntilIdle()
        let outcome = await environment.repository.applyPartialMutation(request)

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.applyCallCount, 1)
    }

    func testStatusFreshBytesSelectionAndScopeDriftNeverReachBackend() async throws {
        let status = makeEnvironment()
        await status.start()
        let statusRequest = try await status.hunkRequest()
        status.backend.setEntries([
            VCSIndexStatusEntry(path: "file.txt", indexStatus: ".", workTreeStatus: ".")
        ])
        let statusOutcome = await status.repository.applyPartialMutation(statusRequest)
        XCTAssertEqual(statusOutcome, .contentChanged)
        XCTAssertEqual(status.backend.applyCallCount, 0)

        let bytes = makeEnvironment()
        await bytes.start()
        let bytesRequest = try await bytes.hunkRequest()
        bytes.diffSource.setPatch(Self.changedPatch)
        let bytesOutcome = await bytes.repository.applyPartialMutation(bytesRequest)
        XCTAssertEqual(bytesOutcome, .contentChanged)
        XCTAssertEqual(bytes.backend.applyCallCount, 0)

        let selection = makeEnvironment()
        await selection.start()
        let validRequest = try await selection.hunkRequest()
        let invalidSelection = AgentChangesPartialMutationRequest(
            reviewToken: validRequest.reviewToken,
            rowID: validRequest.rowID,
            fileKey: validRequest.fileKey,
            identity: validRequest.identity,
            section: validRequest.section,
            expectedContentRevision: validRequest.expectedContentRevision,
            selection: .lines(
                projectedHunkID: validRequest.selection.projectedHunkID,
                lines: [.addition(newLine: 999)]
            )
        )
        let invalidOutcome = await selection.repository.applyPartialMutation(invalidSelection)
        XCTAssertFalse(invalidOutcome.didMutate)
        XCTAssertEqual(selection.backend.applyCallCount, 0)

        let scope = makeEnvironment(pathspecPrefixes: ["sub/"], path: "sub/file.txt")
        await scope.start()
        let scopeRequest = try await scope.hunkRequest(path: "sub/file.txt")
        let escaping = AgentChangesPartialMutationRequest(
            reviewToken: scopeRequest.reviewToken,
            rowID: scopeRequest.rowID,
            fileKey: scopeRequest.fileKey,
            identity: VCSIndexPathIdentity(path: "outside.txt"),
            section: scopeRequest.section,
            expectedContentRevision: scopeRequest.expectedContentRevision,
            selection: scopeRequest.selection
        )
        let scopeOutcome = await scope.repository.applyPartialMutation(escaping)
        XCTAssertFalse(scopeOutcome.didMutate)
        XCTAssertEqual(scope.backend.applyCallCount, 0)
    }

    func testContentRevisionIsRecheckedAfterStatusAndFreshPatchSuspensions() async throws {
        let status = makeEnvironment()
        await status.start()
        let statusRequest = try await status.hunkRequest()
        status.backend.scopedStatusGate.hold()
        let statusTask = Task { await status.repository.applyPartialMutation(statusRequest) }
        await status.backend.scopedStatusGate.waitUntilEntered()
        await status.repository.refresh(.contentDelta(paths: [status.absolutePath("file.txt")]))
        status.backend.scopedStatusGate.release()
        let statusOutcome = await statusTask.value
        XCTAssertEqual(statusOutcome, .contentChanged)
        XCTAssertEqual(status.backend.applyCallCount, 0)

        let patch = makeEnvironment()
        await patch.start()
        let patchRequest = try await patch.hunkRequest()
        patch.diffSource.patchGate.hold()
        let patchTask = Task { await patch.repository.applyPartialMutation(patchRequest) }
        await patch.diffSource.patchGate.waitUntilEntered()
        await patch.repository.refresh(.contentDelta(paths: [patch.absolutePath("file.txt")]))
        patch.diffSource.patchGate.release()
        let patchOutcome = await patchTask.value
        XCTAssertEqual(patchOutcome, .contentChanged)
        XCTAssertEqual(patch.backend.applyCallCount, 0)
    }

    func testIndexLockRetriesExactlyOnceAndRerunsFullPreflight() async throws {
        let success = makeEnvironment()
        await success.start()
        let successRequest = try await success.hunkRequest()
        let baselineStatus = success.backend.statusCallCount
        let baselinePatches = success.diffSource.patchCallCount
        success.backend.enqueueApplyFailure(GitIndexMutationError.indexLocked)

        let successOutcome = await success.repository.applyPartialMutation(successRequest)
        XCTAssertEqual(successOutcome, .applied)
        XCTAssertEqual(success.backend.applyCallCount, 2)
        XCTAssertGreaterThanOrEqual(success.backend.statusCallCount - baselineStatus, 3)
        XCTAssertEqual(success.diffSource.patchCallCount - baselinePatches, 2)

        let failure = makeEnvironment()
        await failure.start()
        let failureRequest = try await failure.hunkRequest()
        let failureBaseline = failure.diffSource.patchCallCount
        failure.backend.enqueueApplyFailure(GitIndexMutationError.indexLocked)
        failure.backend.enqueueApplyFailure(GitIndexMutationError.indexLocked)

        let outcome = await failure.repository.applyPartialMutation(failureRequest)
        guard case .failed = outcome else {
            return XCTFail("Expected second lock failure, got \(outcome)")
        }
        XCTAssertEqual(failure.backend.applyCallCount, 2)
        XCTAssertEqual(failure.diffSource.patchCallCount - failureBaseline, 2)
    }

    func testPatchRejectionForcesRebuildWithoutReportingMutation() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        let baselineStatus = environment.backend.statusCallCount
        environment.backend.enqueueApplyFailure(
            GitIndexMutationError.patchDoesNotApply("patch does not apply")
        )

        let outcome = await environment.repository.applyPartialMutation(request)

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertFalse(outcome.didMutate)
        XCTAssertEqual(environment.publisher.publishCount, 0)
        XCTAssertGreaterThanOrEqual(environment.backend.statusCallCount - baselineStatus, 2)

        let invalid = makeEnvironment()
        await invalid.start()
        let invalidRequest = try await invalid.hunkRequest()
        invalid.backend.enqueueApplyFailure(GitIndexMutationError.invalidPatch("invalid compiled patch"))
        let invalidOutcome = await invalid.repository.applyPartialMutation(invalidRequest)
        guard case .failed = invalidOutcome else {
            return XCTFail("Expected invalid patch failure, got \(invalidOutcome)")
        }

        let invalidRow = try await invalid.unstagedRow()
        let invalidPatch = await invalid.repository.patch(for: invalidRow)
        let invalidDocument = try XCTUnwrap(invalidPatch.document)
        let disabledDescriptor = await invalid.repository.partialStagingDescriptor(
            for: invalidRow,
            renderedDocument: invalidDocument,
            contextLevel: .standard
        )
        XCTAssertEqual(disabledDescriptor.availability, .unavailable(.malformedPatch))
        XCTAssertNil(disabledDescriptor.reviewToken)
    }

    func testSuccessfulApplyInvalidatesBeforeForcedRebuildAndNeverPublishesOptimistically() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        environment.backend.applyGate.hold()
        let task = Task { await environment.repository.applyPartialMutation(request) }
        await environment.backend.applyGate.waitUntilEntered()

        let whileApplying = await environment.repository.currentSnapshot()
        XCTAssertNotNil(whileApplying.section(.unstaged)?.rows.first)
        XCTAssertEqual(environment.publisher.publishCount, 0)

        environment.backend.statusGate.hold()
        environment.backend.applyGate.release()
        await environment.backend.statusGate.waitUntilEntered()
        XCTAssertEqual(environment.publisher.publishCount, 1)
        let beforeRebuildCompletes = await environment.repository.currentSnapshot()
        XCTAssertNotNil(beforeRebuildCompletes.section(.unstaged)?.rows.first)

        environment.backend.statusGate.release()
        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .applied)
        let final = await environment.repository.currentSnapshot()
        XCTAssertNil(final.section(.unstaged)?.rows.first)
        XCTAssertNotNil(final.section(.staged)?.rows.first)
    }

    func testContentMoveAfterApplyReturnsTruthfulMutatingOutcome() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        environment.backend.applyGate.hold()
        let task = Task { await environment.repository.applyPartialMutation(request) }
        await environment.backend.applyGate.waitUntilEntered()

        // The bytes reach the index first; the file only moves afterwards, while the forced rebuild
        // is reading status. That is the drift `.applied(contentChanged:)` exists to report.
        environment.backend.statusGate.hold()
        environment.backend.applyGate.release()
        await environment.backend.statusGate.waitUntilEntered()
        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("file.txt")]))
        environment.backend.statusGate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .appliedThenContentChanged)
        XCTAssertTrue(outcome.didMutate)
        XCTAssertEqual(environment.backend.applyCallCount, 1)
        XCTAssertEqual(environment.backend.refusedMutationCount, 0)
    }

    // MARK: - Authority revoked while the mutation waits for the index

    func testContentMoveWhileTheApplyWaitsForTheIndexRefusesBeforeGitRuns() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        // The gate stands in for another app mutation holding the backend's index-mutation lock:
        // every repository-side preflight has already passed at this point.
        environment.backend.applyGate.hold()
        let task = Task { await environment.repository.applyPartialMutation(request) }
        await environment.backend.applyGate.waitUntilEntered()

        await environment.repository.refresh(.contentDelta(paths: [environment.absolutePath("file.txt")]))
        environment.backend.applyGate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertFalse(outcome.didMutate)
        XCTAssertEqual(
            environment.backend.applyCallCount,
            0,
            "Reviewed bytes must not reach the index after the reviewed content moved"
        )
        XCTAssertEqual(environment.backend.refusedMutationCount, 1)
    }

    func testRetargetWhileTheApplyWaitsForTheIndexRefusesBeforeGitRuns() async throws {
        let environment = makeEnvironment()
        await environment.start(requestID: 1)
        let request = try await environment.hunkRequest()
        environment.backend.applyGate.hold()
        let task = Task { await environment.repository.applyPartialMutation(request) }
        await environment.backend.applyGate.waitUntilEntered()

        await environment.repository.setTarget(
            makeTarget(path: "/tmp/agent-changes-partial-retarget-\(UUID().uuidString)"),
            mode: .workingTree,
            requestID: 2
        )
        environment.backend.applyGate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertFalse(outcome.didMutate)
        XCTAssertEqual(
            environment.backend.applyCallCount,
            0,
            "A retarget while the mutation waited must not apply against the old checkout"
        )
        XCTAssertEqual(environment.backend.refusedMutationCount, 1)
    }

    func testShutdownWhileTheApplyWaitsForTheIndexRefusesBeforeGitRuns() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        environment.backend.applyGate.hold()
        let task = Task { await environment.repository.applyPartialMutation(request) }
        await environment.backend.applyGate.waitUntilEntered()

        await environment.repository.shutdown()
        environment.backend.applyGate.release()
        let outcome = await task.value

        XCTAssertEqual(outcome, .contentChanged)
        XCTAssertFalse(outcome.didMutate)
        XCTAssertEqual(
            environment.backend.applyCallCount,
            0,
            "Terminal shutdown stays terminal even for a mutation already queued at the backend"
        )
        XCTAssertEqual(environment.backend.refusedMutationCount, 1)
    }

    func testIndexLockRetryReevaluatesTheAuthorizationHook() async throws {
        let environment = makeEnvironment()
        await environment.start()
        let request = try await environment.hunkRequest()
        environment.backend.enqueueApplyFailure(.indexLocked)

        let outcome = await environment.repository.applyPartialMutation(request)

        // The sole retry re-runs the whole preflight; the hook is part of that discipline, so it is
        // evaluated once per attempt rather than carried over from the refused one.
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(environment.backend.applyCallCount, 2)
        XCTAssertEqual(environment.backend.authorizationCheckCount, 2)
        XCTAssertEqual(environment.backend.refusedMutationCount, 0)
    }

    private struct Environment {
        let repository: AgentChangesRepository
        let backend: PartialFakeIndexBackend
        let diffSource: PartialFakeDiffSource
        let publisher: PartialFakePublisher
        let target: AgentPanelResolvedCheckout
        let path: String

        func start(requestID: UInt64? = nil) async {
            await repository.setTarget(target, mode: .workingTree, requestID: requestID)
            await repository.waitUntilIdle()
        }

        func absolutePath(_ relative: String) -> String {
            target.checkoutURL.appendingPathComponent(relative).path
        }

        func unstagedRow(_ requestedPath: String? = nil) async throws -> AgentChangesFileRow {
            let rowPath = requestedPath ?? path
            let snapshot = await repository.currentSnapshot()
            return try XCTUnwrap(snapshot.section(.unstaged)?.rows.first(where: { $0.path == rowPath }))
        }

        func visibleDescriptor(
            row: AgentChangesFileRow
        ) async throws -> (FileDiffProjection.Document, AgentChangesPartialStagingDescriptor) {
            let patch = await repository.patch(for: row)
            let document = try XCTUnwrap(patch.document)
            let descriptor = await repository.partialStagingDescriptor(
                for: row,
                renderedDocument: document,
                contextLevel: .standard
            )
            return (document, descriptor)
        }

        func hunkRequest(path requestedPath: String? = nil) async throws -> AgentChangesPartialMutationRequest {
            let row = try await unstagedRow(requestedPath)
            let (_, descriptor) = try await visibleDescriptor(row: row)
            let token = try XCTUnwrap(descriptor.reviewToken)
            let hunk = try XCTUnwrap(descriptor.changedLineKeysByHunkID.first)
            return AgentChangesPartialMutationRequest(
                reviewToken: token,
                row: row,
                selection: .hunk(projectedHunkID: hunk.key, lines: hunk.value)
            )
        }
    }

    private func makeEnvironment(
        entry: VCSIndexStatusEntry? = nil,
        patch: String? = nil,
        capabilities: VCSCapabilities = .git,
        pathspecPrefixes: [String] = [],
        path: String = "file.txt",
        patchLineLimit: Int = 4000
    ) -> Environment {
        let target = Self.makeTarget(
            path: "/tmp/agent-changes-partial-\(UUID().uuidString)",
            pathspecPrefixes: pathspecPrefixes
        )
        let backend = PartialFakeIndexBackend(
            checkout: target.checkoutURL,
            entries: [entry ?? VCSIndexStatusEntry(path: path, indexStatus: ".", workTreeStatus: "M")],
            capabilities: capabilities
        )
        let diffSource = PartialFakeDiffSource(path: path, patch: patch ?? Self.patch(path: path))
        let publisher = PartialFakePublisher()
        let repository = AgentChangesRepository(
            indexBackend: backend,
            diffSource: diffSource,
            invalidationPublisher: publisher,
            scheduler: PartialImmediateScheduler(),
            contentDeltaWindow: .zero,
            patchLineLimit: patchLineLimit,
            makeTriggerFeed: { _ in PartialInertTriggerFeed() }
        )
        return Environment(
            repository: repository,
            backend: backend,
            diffSource: diffSource,
            publisher: publisher,
            target: target,
            path: path
        )
    }

    private static func makeTarget(
        path: String,
        pathspecPrefixes: [String] = []
    ) -> AgentPanelResolvedCheckout {
        let url = URL(fileURLWithPath: path)
        return AgentPanelResolvedCheckout(
            checkoutURL: url,
            repoRootURL: url,
            backendKind: .git,
            pathspecPrefixes: pathspecPrefixes,
            logicalRoots: [AgentPanelLogicalRoot(path: path)],
            worktree: nil,
            substitutesUnavailableWorktree: false
        )
    }

    private func makeTarget(path: String) -> AgentPanelResolvedCheckout {
        Self.makeTarget(path: path)
    }

    private static func patch(path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1,3 +1,3 @@
         one
        -old
        +new
         three
        """ + "\n"
    }

    /// Both sides end without a trailing newline, so git annotates the replacement pair.
    private static let noNewlinePatch = """
    diff --git a/file.txt b/file.txt
    index 1111111..2222222 100644
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     one
    -old
    \\ No newline at end of file
    +new
    \\ No newline at end of file
    """ + "\n"

    private static let changedPatch = """
    diff --git a/file.txt b/file.txt
    index 1111111..3333333 100644
    --- a/file.txt
    +++ b/file.txt
    @@ -1,3 +1,3 @@
     one
    -old
    +newer
     three
    """ + "\n"
}

private struct PartialImmediateScheduler: AgentChangesScheduler {
    func sleep(for _: Duration) async throws {
        await Task.yield()
    }
}

private struct PartialInertTriggerFeed: AgentChangesTriggerFeed {
    func events() -> AsyncStream<AgentChangesRefreshTrigger> {
        AsyncStream { _ in }
    }

    func cancel() {}
}

private final class PartialFakePublisher: AgentChangesInvalidationPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var publishCount: Int {
        lock.withLock { count }
    }

    func publishIndexMutation(at _: URL) async {
        lock.withLock { count += 1 }
    }
}

private final class PartialSuspensionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var entries = 0
    private var targetEntry = 0
    private var blockers: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() {
        lock.withLock {
            held = true
            targetEntry = entries + 1
        }
    }

    func waitUntilEntered() async {
        let shouldWait = lock.withLock { entries < targetEntry }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard entries < targetEntry else { return true }
                observers.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func enter() async {
        let state: (shouldBlock: Bool, observers: [CheckedContinuation<Void, Never>]) = lock.withLock {
            entries += 1
            let waiting = observers
            observers = []
            return (held, waiting)
        }
        for observer in state.observers {
            observer.resume()
        }
        guard state.shouldBlock else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard held else { return true }
                blockers.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            held = false
            let waiting = blockers
            blockers = []
            return waiting
        }
        for blocker in waiting {
            blocker.resume()
        }
    }
}

private final class PartialFakeIndexBackend: AgentChangesIndexBackend, @unchecked Sendable {
    let statusGate = PartialSuspensionGate()
    let scopedStatusGate = PartialSuspensionGate()
    let applyGate = PartialSuspensionGate()

    private let lock = NSLock()
    private let checkout: URL
    private var entries: [VCSIndexStatusEntry]
    private let capabilitiesValue: VCSCapabilities
    private var statusCalls = 0
    private var stageCalls = 0
    private var applyCalls = 0
    private var applyFailures: [GitIndexMutationError] = []
    private var refusedMutations = 0
    private var authorizationChecks = 0

    init(checkout: URL, entries: [VCSIndexStatusEntry], capabilities: VCSCapabilities) {
        self.checkout = checkout
        self.entries = entries
        capabilitiesValue = capabilities
    }

    var statusCallCount: Int {
        lock.withLock { statusCalls }
    }

    var stageCallCount: Int {
        lock.withLock { stageCalls }
    }

    var applyCallCount: Int {
        lock.withLock { applyCalls }
    }

    /// How many mutations the caller's final-authority hook refused after they had waited.
    var refusedMutationCount: Int {
        lock.withLock { refusedMutations }
    }

    /// How many times the hook was evaluated, so a retry can be shown to re-authorize.
    var authorizationCheckCount: Int {
        lock.withLock { authorizationChecks }
    }

    func setEntries(_ value: [VCSIndexStatusEntry]) {
        lock.withLock { entries = value }
    }

    func enqueueApplyFailure(_ error: GitIndexMutationError) {
        lock.withLock { applyFailures.append(error) }
    }

    func capabilities(at _: URL) async -> VCSCapabilities {
        capabilitiesValue
    }

    func hasHeadCommit(at _: URL) async throws -> Bool {
        true
    }

    func loadIndexStatus(at _: URL) async throws -> [VCSIndexStatusEntry] {
        await statusGate.enter()
        return lock.withLock {
            statusCalls += 1
            return entries
        }
    }

    func loadIndexStatus(at _: URL, paths: [String]) async throws -> [VCSIndexStatusEntry] {
        await scopedStatusGate.enter()
        let reviewedPaths = Set(paths)
        return lock.withLock {
            statusCalls += 1
            return entries.filter {
                reviewedPaths.contains($0.path)
                    || $0.originalPath.map(reviewedPaths.contains) == true
            }
        }
    }

    func stage(
        _: [VCSIndexPathIdentity],
        at _: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireAuthorization(authorize)
        lock.withLock { stageCalls += 1 }
    }

    func unstage(
        _: [VCSIndexPathIdentity],
        at _: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireAuthorization(authorize)
    }

    func applyCachedPatch(
        _: Data,
        reverse _: Bool,
        at _: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        // Gate first, hook second: the real backend evaluates the hook after it has waited for the
        // serialized index slot, which is the window this suite revokes authority in.
        await applyGate.enter()
        try await requireAuthorization(authorize)
        let failure: GitIndexMutationError? = lock.withLock {
            applyCalls += 1
            return applyFailures.isEmpty ? nil : applyFailures.removeFirst()
        }
        if let failure { throw failure }

        lock.withLock {
            let firstPath = entries.first?.path
            entries = entries.map { entry in
                guard entry.path == firstPath else { return entry }
                return VCSIndexStatusEntry(
                    path: entry.path,
                    indexStatus: "M",
                    workTreeStatus: "."
                )
            }
        }
    }

    func markResolved(
        _: VCSIndexPathIdentity,
        at _: URL,
        authorize: VCSIndexMutationAuthorization
    ) async throws {
        try await requireAuthorization(authorize)
    }

    private func requireAuthorization(_ authorize: VCSIndexMutationAuthorization) async throws {
        let authorized = await authorize()
        lock.withLock {
            authorizationChecks += 1
            if !authorized { refusedMutations += 1 }
        }
        guard authorized else {
            throw GitIndexMutationError.authorizationRevoked
        }
    }
}

private final class PartialFakeDiffSource: AgentChangesDiffSource, @unchecked Sendable {
    let patchGate = PartialSuspensionGate()

    private let lock = NSLock()
    private let path: String
    private var patchText: String
    private var statusHash = "initial"
    private var patchCalls = 0

    init(path: String, patch: String) {
        self.path = path
        patchText = patch
    }

    var patchCallCount: Int {
        lock.withLock { patchCalls }
    }

    func setPatch(_ value: String) {
        lock.withLock { patchText = value }
    }

    func setStatusHash(_ value: String) {
        lock.withLock { statusHash = value }
    }

    func resolveRevision(_: String, at _: URL) async -> AgentChangesRevisionValidation {
        .invalid("unused")
    }

    func fingerprint(compare _: GitDiffCompareSpec, at _: URL) async throws -> GitDiffFingerprint {
        currentFingerprint()
    }

    func loadMetadata(
        compare _: GitDiffCompareSpec,
        pathspecs _: [String],
        at _: URL
    ) async throws -> AgentChangesDiffMetadata {
        AgentChangesDiffMetadata(
            fingerprint: currentFingerprint(),
            files: [VCSUncommittedFile(path: path, status: "M", additions: 1, deletions: 1)]
        )
    }

    func loadPatch(
        compare _: GitDiffCompareSpec,
        paths: [String],
        at _: URL,
        contextLines _: Int
    ) async throws -> AgentChangesPatchPayload? {
        await patchGate.enter()
        return lock.withLock {
            patchCalls += 1
            guard paths.contains(path) else { return nil }
            return AgentChangesPatchPayload(
                perFile: [path: patchText],
                rawPerFile: [path: Data(patchText.utf8)],
                fingerprint: currentFingerprintLocked()
            )
        }
    }

    func loadFileContent(
        source _: AgentChangesFileContentSource,
        at _: URL,
        byteLimit _: Int
    ) async throws -> AgentChangesFileContent {
        throw AgentChangesFileContentReadError.unavailable("unused")
    }

    private func currentFingerprint() -> GitDiffFingerprint {
        lock.withLock { currentFingerprintLocked() }
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
