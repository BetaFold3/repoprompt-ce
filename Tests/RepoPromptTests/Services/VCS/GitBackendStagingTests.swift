import Foundation
@testable import RepoPromptApp
import XCTest

final class GitBackendStagingTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Staging

    func testStagesModificationDeletionAndUntrackedFileInOneBatch() async throws {
        let repo = try makeGitFixture(committing: ["modified.txt": "one\n", "deleted.txt": "two\n"])
        let backend = GitBackend()

        try write("changed\n", to: "modified.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("deleted.txt"))
        try write("fresh\n", to: "untracked.txt", in: repo)

        let before = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(before["modified.txt"]?.workTreeStatus, "M")
        XCTAssertEqual(before["deleted.txt"]?.workTreeStatus, "D")
        XCTAssertEqual(before["untracked.txt"]?.isUntracked, true)
        XCTAssertEqual(before.values.filter(\.hasStagedChange).count, 0)

        try await backend.stage(before.values.map(\.identity), at: repo)

        let after = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(after["modified.txt"]?.indexStatus, "M")
        XCTAssertEqual(after["deleted.txt"]?.indexStatus, "D")
        XCTAssertEqual(after["untracked.txt"]?.indexStatus, "A")
        XCTAssertEqual(after.values.filter(\.hasWorkTreeChange).count, 0)
    }

    func testScopedStatusCarriesIndexOIDAndExcludesUnreviewedPaths() async throws {
        let repo = try makeGitFixture(committing: [
            "reviewed.txt": "one\n",
            "bystander.txt": "two\n"
        ])
        let backend = GitBackend()

        try write("reviewed change\n", to: "reviewed.txt", in: repo)
        try write("bystander change\n", to: "bystander.txt", in: repo)

        let entries = try await backend.loadIndexStatus(
            at: repo,
            paths: ["reviewed.txt"]
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.map(\.path), ["reviewed.txt"])
        XCTAssertEqual(entry.indexStatus, ".")
        XCTAssertEqual(entry.workTreeStatus, "M")
        XCTAssertEqual(entry.headMode, "100644")
        XCTAssertEqual(entry.indexMode, "100644")
        XCTAssertEqual(entry.headOID, try gitOutput(["rev-parse", "HEAD:reviewed.txt"], cwd: repo))
        XCTAssertEqual(entry.repositoryHeadIdentity, try gitOutput(["rev-parse", "HEAD"], cwd: repo))
        XCTAssertEqual(
            entry.indexOID,
            try indexEntry(for: "reviewed.txt", in: repo)
                .split(whereSeparator: \.isWhitespace)
                .dropFirst()
                .first
                .map(String.init)
        )
    }

    func testStagesRenameUsingBothPathsAndUnstageRestoresBothSides() async throws {
        let repo = try makeGitFixture(committing: ["origin.txt": "content\n"])
        let backend = GitBackend()

        try FileManager.default.moveItem(
            at: repo.appendingPathComponent("origin.txt"),
            to: repo.appendingPathComponent("renamed.txt")
        )

        try await backend.stage(
            [VCSIndexPathIdentity(path: "renamed.txt", originalPath: "origin.txt")],
            at: repo
        )

        let staged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(staged.count, 1)
        let renameEntry = try XCTUnwrap(staged["renamed.txt"])
        XCTAssertEqual(renameEntry.indexStatus, "R")
        XCTAssertEqual(renameEntry.originalPath, "origin.txt")

        try await backend.unstage([renameEntry.identity], at: repo)

        let restored = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(restored["origin.txt"]?.workTreeStatus, "D")
        XCTAssertEqual(restored["origin.txt"]?.hasStagedChange, false)
        XCTAssertEqual(restored["renamed.txt"]?.isUntracked, true)
        XCTAssertEqual(try contents(of: "renamed.txt", in: repo), "content\n")
    }

    // MARK: - Unstaging

    func testUnstageRestoresStagedChangesWithoutTouchingWorkingTree() async throws {
        let repo = try makeGitFixture(committing: ["modified.txt": "one\n", "deleted.txt": "two\n"])
        let backend = GitBackend()

        try write("changed\n", to: "modified.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("deleted.txt"))
        try runGit(["add", "-A"], cwd: repo)

        let staged = try await entriesByPath(backend, at: repo)
        try await backend.unstage(staged.values.map(\.identity), at: repo)

        let unstaged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(unstaged["modified.txt"]?.indexStatus, ".")
        XCTAssertEqual(unstaged["modified.txt"]?.workTreeStatus, "M")
        XCTAssertEqual(unstaged["deleted.txt"]?.indexStatus, ".")
        XCTAssertEqual(unstaged["deleted.txt"]?.workTreeStatus, "D")
        XCTAssertEqual(try contents(of: "modified.txt", in: repo), "changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("deleted.txt").path))
    }

    func testUnstageWithUnbornHeadRemovesIndexEntriesAndKeepsWorkingTreeFiles() async throws {
        let repo = try makeGitFixture(committing: [:])
        let backend = GitBackend()

        try write("x\n", to: "x.txt", in: repo)
        try write("y\n", to: "y.txt", in: repo)
        try runGit(["add", "-A"], cwd: repo)

        let hasHead = try await backend.hasHeadCommit(at: repo)
        XCTAssertFalse(hasHead, "fixture must have an unborn HEAD")

        let staged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(staged["x.txt"]?.indexStatus, "A")
        XCTAssertEqual(staged["y.txt"]?.indexStatus, "A")

        try await backend.unstage(staged.values.map(\.identity), at: repo)

        let unstaged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(unstaged["x.txt"]?.isUntracked, true)
        XCTAssertEqual(unstaged["y.txt"]?.isUntracked, true)
        XCTAssertEqual(try contents(of: "x.txt", in: repo), "x\n")
        XCTAssertEqual(try contents(of: "y.txt", in: repo), "y\n")
    }

    // MARK: - Path Handling

    func testStagesLeadingDashSpacedUnicodeAndGlobCharacterFilenamesLiterally() async throws {
        let repo = try makeGitFixture(committing: ["seed.txt": "seed\n"])
        let backend = GitBackend()

        let requested = ["-leading-dash.txt", "spaced name.txt", "üñí çø∂é.txt", "star*.txt"]
        let bystander = "starX.txt"
        for name in requested + [bystander] {
            try write("body\n", to: name, in: repo)
        }

        try await backend.stage(requested.map { VCSIndexPathIdentity(path: $0) }, at: repo)

        let entries = try await entriesByPath(backend, at: repo)
        for name in requested {
            XCTAssertEqual(entries[name]?.indexStatus, "A", "expected \(name) to be staged")
        }
        XCTAssertEqual(
            entries[bystander]?.isUntracked,
            true,
            "literal pathspecs must stop star*.txt from globbing onto \(bystander)"
        )
    }

    func testCopyMutationStagesOnlyTheDestinationAndLeavesSourceEditsUnstaged() async throws {
        let repo = try makeGitFixture(committing: ["source.txt": "original\n"])
        let backend = GitBackend()

        try write("edited source\n", to: "source.txt", in: repo)
        try write("original\n", to: "copy.txt", in: repo)
        let copy = VCSIndexStatusEntry(
            path: "copy.txt",
            originalPath: "source.txt",
            indexStatus: "C",
            workTreeStatus: "."
        ).identity

        XCTAssertFalse(copy.includesOriginalPathInMutation)
        XCTAssertEqual(copy.allPaths, ["copy.txt", "source.txt"], "Diff detection still sees both paths")
        XCTAssertEqual(copy.mutationPaths, ["copy.txt"])
        try await backend.stage([copy], at: repo)

        let entries = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(entries["copy.txt"]?.indexStatus, "A")
        XCTAssertEqual(entries["source.txt"]?.indexStatus, ".")
        XCTAssertEqual(entries["source.txt"]?.workTreeStatus, "M")
    }

    func testEmptyRequestLeavesTheIndexUntouched() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])
        let backend = GitBackend()

        try write("changed\n", to: "tracked.txt", in: repo)
        try write("fresh\n", to: "untracked.txt", in: repo)

        try await backend.stage([], at: repo)
        let afterEmptyStage = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(afterEmptyStage.values.filter(\.hasStagedChange).count, 0)

        try runGit(["add", "-A"], cwd: repo)
        try await backend.unstage([], at: repo)
        let afterEmptyUnstage = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(afterEmptyUnstage.values.filter(\.hasStagedChange).count, 2)
    }

    func testRejectsPathsThatEscapeOrWidenTheRepository() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])
        let backend = GitBackend()

        try write("changed\n", to: "tracked.txt", in: repo)

        let rejected = [
            "",
            ".",
            "./",
            "..",
            "../outside.txt",
            "nested/../../outside.txt",
            "/etc/hosts",
            "nested//tracked.txt",
            "nested/",
            "tracked\u{0}.txt"
        ]
        for path in rejected {
            do {
                try await backend.stage([VCSIndexPathIdentity(path: path)], at: repo)
                XCTFail("Expected \(path.debugDescription) to be rejected")
            } catch let error as GitIndexMutationError {
                XCTAssertEqual(error, .invalidPath(path))
            }
        }

        let entries = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(entries.values.filter(\.hasStagedChange).count, 0)
    }

    func testLargeBatchStagesAndUnstagesEveryPath() async throws {
        let repo = try makeGitFixture(committing: ["seed.txt": "seed\n"])
        let backend = GitBackend()

        // Long names keep the pathspec byte total well past the argv threshold, so
        // this batch travels as a NUL-delimited stdin pathspec list.
        let names = (0 ..< 700).map { index in
            "batch-\(String(format: "%04d", index))-" + String(repeating: "p", count: 200) + ".txt"
        }
        for name in names {
            try write("body\n", to: name, in: repo)
        }

        let identities = names.map { VCSIndexPathIdentity(path: $0) }
        try await backend.stage(identities, at: repo)

        let staged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(staged.values.count { $0.indexStatus == "A" }, names.count)

        try await backend.unstage(identities, at: repo)

        let unstaged = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(unstaged.values.filter(\.isUntracked).count, names.count)
        XCTAssertEqual(unstaged.values.filter(\.hasStagedChange).count, 0)
    }

    // MARK: - Index Lock Contention

    func testIndexLockContentionIsSurfacedSoARevalidatedCallerCanRetry() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])
        let backend = GitBackend()

        try write("changed\n", to: "tracked.txt", in: repo)
        let lock = indexLockURL(in: repo)
        try Data().write(to: lock)

        do {
            try await backend.stage([VCSIndexPathIdentity(path: "tracked.txt")], at: repo)
            XCTFail("Expected the first attempt to surface index contention")
        } catch let error as GitIndexMutationError {
            XCTAssertEqual(error, .indexLocked)
        }

        try FileManager.default.removeItem(at: lock)
        try await backend.stage([VCSIndexPathIdentity(path: "tracked.txt")], at: repo)

        let entries = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(entries["tracked.txt"]?.indexStatus, "M")
    }

    func testHeldIndexLockFailsWithTypedErrorAfterExactlyOneRetry() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])
        let gitService = GitService()
        let backend = GitBackend(gitService: gitService)

        try write("changed\n", to: "tracked.txt", in: repo)
        try Data().write(to: indexLockURL(in: repo))

        do {
            try await backend.stage([VCSIndexPathIdentity(path: "tracked.txt")], at: repo)
            XCTFail("Expected a held index.lock to fail the mutation")
        } catch let error as GitIndexMutationError {
            XCTAssertEqual(error, .indexLocked)
        }

        let entries = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(entries["tracked.txt"]?.hasStagedChange, false)
    }

    // MARK: - Authorization inside the index-mutation lock

    func testAuthorityRevokedWhileWaitingForTheIndexLockRunsNoGitAndLeavesTheEntryIdentical() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n", "holder.txt": "one\n"])
        let gitService = GitService()
        let backend = GitBackend(gitService: gitService)

        try write("changed\n", to: "tracked.txt", in: repo)
        try write("changed\n", to: "holder.txt", in: repo)
        let indexEntryBefore = try indexEntry(for: "tracked.txt", in: repo)

        // The holder's own hook is the pause point, so the lock is genuinely held by a mutation that
        // has already claimed it rather than by an approximation of one.
        let holderEnteredHook = AsyncSignal()
        let holderMayProceed = AsyncSignal()
        let revocation = MutationRevocationRecorder()

        let holder = Task {
            try await backend.stage(
                [VCSIndexPathIdentity(path: "holder.txt")],
                at: repo,
                authorize: {
                    holderEnteredHook.signal()
                    await holderMayProceed.wait()
                    return true
                }
            )
        }
        await holderEnteredHook.wait()

        let waiter = Task { () -> (any Error)? in
            do {
                try await backend.stage(
                    [VCSIndexPathIdentity(path: "tracked.txt")],
                    at: repo,
                    authorize: { await revocation.evaluate() }
                )
                return nil
            } catch {
                return error
            }
        }
        await gitService.waitForWorktreeMutationWaiterForTesting(at: repo)

        // Revoked only once the second mutation is provably parked on the lock. A hook evaluated
        // before that wait would have authorized here and staged unreviewed content.
        await revocation.revoke()
        holderMayProceed.signal()
        try await holder.value
        let waiterError = await waiter.value

        let evaluatedAfterRevocation = await revocation.wasEvaluatedAfterRevocation
        XCTAssertEqual(waiterError as? GitIndexMutationError, .authorizationRevoked)
        XCTAssertTrue(
            evaluatedAfterRevocation,
            "The hook must be evaluated after the lock wait, not before it"
        )
        XCTAssertEqual(
            try indexEntry(for: "tracked.txt", in: repo),
            indexEntryBefore,
            "A refused mutation leaves its index entry byte-identical"
        )

        let entries = try await entriesByPath(backend, at: repo)
        XCTAssertEqual(entries["tracked.txt"]?.hasStagedChange, false)
        XCTAssertEqual(entries["tracked.txt"]?.workTreeStatus, "M")
        XCTAssertEqual(
            entries["holder.txt"]?.indexStatus,
            "M",
            "The mutation that held the lock still ran to completion"
        )
    }

    func testRefusedUnstageAndResolutionRunNoGitAtAll() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])
        let backend = GitBackend()

        try write("changed\n", to: "tracked.txt", in: repo)
        try await backend.stage([VCSIndexPathIdentity(path: "tracked.txt")], at: repo)
        let indexEntryBefore = try indexEntry(for: "tracked.txt", in: repo)

        let refusals: [(name: String, run: @Sendable () async throws -> Void)] = [
            ("stage", {
                try await backend.stage(
                    [VCSIndexPathIdentity(path: "tracked.txt")],
                    at: repo,
                    authorize: neverAuthorizedIndexMutation
                )
            }),
            ("unstage", {
                try await backend.unstage(
                    [VCSIndexPathIdentity(path: "tracked.txt")],
                    at: repo,
                    authorize: neverAuthorizedIndexMutation
                )
            }),
            ("markResolved", {
                try await backend.markResolved(
                    VCSIndexPathIdentity(path: "tracked.txt"),
                    at: repo,
                    authorize: neverAuthorizedIndexMutation
                )
            })
        ]

        for refusal in refusals {
            do {
                try await refusal.run()
                XCTFail("Expected \(refusal.name) to refuse")
            } catch let error as GitIndexMutationError {
                XCTAssertEqual(error, .authorizationRevoked, refusal.name)
            }
            XCTAssertEqual(
                try indexEntry(for: "tracked.txt", in: repo),
                indexEntryBefore,
                "\(refusal.name) must leave the index entry byte-identical"
            )
        }
    }

    // MARK: - Conflict resolution

    func testMarkResolvedStagesOnlyTheConfirmedConflictCurrentContents() async throws {
        let repo = try makeGitFixture(committing: [
            "conflict.txt": "base\n",
            "bystander.txt": "base\n"
        ])
        let backend = GitBackend()

        try runGit(["switch", "-c", "other"], cwd: repo)
        try write("other\n", to: "conflict.txt", in: repo)
        try runGit(["commit", "-am", "Other edit"], cwd: repo)
        try runGit(["switch", "main"], cwd: repo)
        try write("main\n", to: "conflict.txt", in: repo)
        try runGit(["commit", "-am", "Main edit"], cwd: repo)
        _ = try TestGitCommandRunner.runResult(["merge", "other"], cwd: repo)

        try write("resolved contents\n", to: "conflict.txt", in: repo)
        try write("unstaged bystander\n", to: "bystander.txt", in: repo)
        let before = try await entriesByPath(backend, at: repo)
        let conflicted = try XCTUnwrap(before["conflict.txt"])
        XCTAssertTrue(conflicted.isConflicted)

        try await backend.markResolved(conflicted.identity, at: repo)

        let after = try await entriesByPath(backend, at: repo)
        XCTAssertFalse(after["conflict.txt"]?.isConflicted == true)
        XCTAssertEqual(after["conflict.txt"]?.indexStatus, "M")
        XCTAssertEqual(after["conflict.txt"]?.workTreeStatus, ".")
        XCTAssertEqual(try contents(of: "conflict.txt", in: repo), "resolved contents\n")
        XCTAssertEqual(after["bystander.txt"]?.hasStagedChange, false)
        XCTAssertEqual(after["bystander.txt"]?.workTreeStatus, "M")
    }

    // MARK: - Detailed Status

    func testLoadIndexStatusReportsConflictedAndPartiallyStagedEntries() async throws {
        let repo = try makeGitFixture(committing: ["conflict.txt": "base\n", "partial.txt": "base\n"])
        let backend = GitBackend()

        try runGit(["switch", "-c", "other"], cwd: repo)
        try write("other\n", to: "conflict.txt", in: repo)
        try runGit(["commit", "-am", "Other edit"], cwd: repo)
        try runGit(["switch", "main"], cwd: repo)
        try write("main\n", to: "conflict.txt", in: repo)
        try runGit(["commit", "-am", "Main edit"], cwd: repo)
        _ = try TestGitCommandRunner.runResult(["merge", "other"], cwd: repo)

        try write("staged\n", to: "partial.txt", in: repo)
        try runGit(["add", "--", "partial.txt"], cwd: repo)
        try write("staged then edited again\n", to: "partial.txt", in: repo)

        let entries = try await entriesByPath(backend, at: repo)
        let conflict = try XCTUnwrap(entries["conflict.txt"])
        XCTAssertTrue(conflict.isConflicted)
        XCTAssertEqual(conflict.indexStatus, "U")
        XCTAssertEqual(conflict.workTreeStatus, "U")

        let partial = try XCTUnwrap(entries["partial.txt"])
        XCTAssertFalse(partial.isConflicted)
        XCTAssertEqual(partial.indexStatus, "M")
        XCTAssertEqual(partial.workTreeStatus, "M")
        XCTAssertTrue(partial.hasStagedChange)
        XCTAssertTrue(partial.hasWorkTreeChange)
    }

    func testIndexStatusDecoderRejectsInvalidUTF8InsteadOfReplacingFilenameBytes() {
        XCTAssertThrowsError(
            try GitService.decodeIndexStatusOutput(Data([0x3F, 0x00, 0xFF, 0x00]))
        ) { error in
            XCTAssertEqual(error as? GitIndexMutationError, .invalidStatusEncoding)
            XCTAssertTrue(error.localizedDescription.contains("UTF-8"))
        }
    }

    func testGetFileContentReadsALeadingDashIndexPathWithOptionTermination() async throws {
        let repo = try makeGitFixture(committing: ["seed.txt": "seed\n"])
        let gitService = GitService()
        try write("body\n", to: "-leading.txt", in: repo)
        try runGit(["add", "--", "-leading.txt"], cwd: repo)

        let data = try await gitService.getFileContent(
            ref: nil,
            path: "-leading.txt",
            byteLimit: 1024,
            at: repo
        )

        XCTAssertEqual(String(data: data, encoding: .utf8), "body\n")
    }

    // MARK: - Capabilities

    func testStagingCapabilityIsGitOnlyAndResolvesThroughTheServiceLayer() async throws {
        let repo = try makeGitFixture(committing: ["tracked.txt": "one\n"])

        let git: any VCSBackend = GitBackend()
        XCTAssertTrue(git.capabilities.supportsStaging)
        XCTAssertNotNil(git as? any VCSIndexMutationBackend)

        let jujutsu: any VCSBackend = JujutsuBackend()
        XCTAssertFalse(jujutsu.capabilities.supportsStaging)
        XCTAssertNil(
            jujutsu as? any VCSIndexMutationBackend,
            "Jujutsu has no staging area and must never conform"
        )

        let service = VCSService()
        let capabilities = await service.capabilities(forRepoRoot: repo)
        XCTAssertTrue(capabilities.supportsStaging)
        let resolved = await service.indexMutationBackend(forRepoRoot: repo)
        XCTAssertNotNil(resolved)
    }

    // MARK: - Fixtures

    private func makeGitFixture(committing files: [String: String]) throws -> URL {
        let root = try makeTemporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: repo)
        try runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try runGit(["config", "user.name", "Test User"], cwd: repo)
        try runGit(["config", "commit.gpgsign", "false"], cwd: repo)
        guard !files.isEmpty else { return repo }
        for (name, body) in files {
            try write(body, to: name, in: repo)
        }
        try runGit(["add", "-A"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return repo
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBackendStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoot = root
        return root
    }

    private func entriesByPath(
        _ backend: GitBackend,
        at repo: URL
    ) async throws -> [String: VCSIndexStatusEntry] {
        let entries = try await backend.loadIndexStatus(at: repo)
        return Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The index's own record for one path, so a refusal can be shown to change nothing.
    private func indexEntry(for path: String, in repo: URL) throws -> String {
        try TestGitCommandRunner.runResult(
            ["ls-files", "--stage", "--", path],
            cwd: repo
        ).outputText
    }

    private func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        try TestGitCommandRunner.runResult(arguments, cwd: cwd).outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func indexLockURL(in repo: URL) -> URL {
        repo.appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("index.lock")
    }

    private func write(_ body: String, to name: String, in repo: URL) throws {
        try body.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func contents(of name: String, in repo: URL) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        try TestGitCommandRunner.run(
            arguments,
            cwd: cwd,
            failureDomain: "GitBackendStagingTests.git"
        )
    }
}

/// A one-shot signal usable from either side of an `await`, so an authorization hook can announce
/// that it is running inside the lock and then park until the test lets it continue.
private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isSignalled = true
            let current = waiters
            waiters = []
            return current
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                guard !isSignalled else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Records when a final-authority hook was evaluated relative to the revocation, which is what
/// separates an in-lock check from one made before the mutation ever waited.
private actor MutationRevocationRecorder {
    private var isRevoked = false
    private(set) var wasEvaluatedAfterRevocation = false

    func revoke() {
        isRevoked = true
    }

    func evaluate() -> Bool {
        if isRevoked { wasEvaluatedAfterRevocation = true }
        return !isRevoked
    }
}
