@testable import RepoPromptApp
import XCTest

final class GitIndexPatchMutationIntegrationTests: XCTestCase {
    func testStagesOneOfTwoHunksAndLeavesWorktreeUntouched() async throws {
        let fixture = try GitPatchFixture(
            files: ["file.txt": numberedFile(first: "old-one", second: "old-two")]
        )
        let worktree = numberedFile(first: "new-one", second: "new-two")
        try fixture.write(worktree, to: "file.txt")
        let service = GitService()
        let raw = try await service.getDiffData(
            compare: .unstaged,
            paths: ["file.txt"],
            contextLines: 1,
            detectRenames: false,
            at: fixture.root
        )
        let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: "file.txt")
        XCTAssertEqual(parsed.hunks.count, 2)

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.hunks[0].changedLineKeys,
            selectsWholeHunks: true
        )
        try await service.applyIndexPatch(data: compiled.data, reverse: compiled.reverse, repoURL: fixture.root)

        XCTAssertEqual(try fixture.indexText("file.txt"), numberedFile(first: "new-one", second: "old-two"))
        XCTAssertEqual(try fixture.readText("file.txt"), worktree)
    }

    func testUnstagesOneOfTwoStagedHunksWithoutChangingWorktree() async throws {
        let original = numberedFile(first: "old-one", second: "old-two")
        let changed = numberedFile(first: "new-one", second: "new-two")
        let fixture = try GitPatchFixture(files: ["file.txt": original])
        try fixture.write(changed, to: "file.txt")
        try fixture.git(["add", "--", "file.txt"])
        let service = GitService()
        let raw = try await service.getDiffData(
            compare: .staged(base: "HEAD"),
            paths: ["file.txt"],
            contextLines: 1,
            detectRenames: false,
            at: fixture.root
        )
        let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: "file.txt")

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .unstage,
            selectedLineKeys: parsed.hunks[0].changedLineKeys,
            selectsWholeHunks: true
        )
        try await service.applyIndexPatch(data: compiled.data, reverse: compiled.reverse, repoURL: fixture.root)

        XCTAssertEqual(try fixture.indexText("file.txt"), numberedFile(first: "old-one", second: "new-two"))
        XCTAssertEqual(try fixture.readText("file.txt"), changed)
    }

    func testStagesAndUnstagesOnlySelectedReplacementAddition() async throws {
        let fixture = try GitPatchFixture(files: ["file.txt": "a\nb\nc\n"])
        try fixture.write("a\ninsert\nc\n", to: "file.txt")
        let service = GitService()
        let raw = try await unstagedPatch(service, fixture: fixture)
        let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: "file.txt")

        let stage = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [.addition(newLine: 2)],
            selectsWholeHunks: false
        )
        try await service.applyIndexPatch(data: stage.data, reverse: stage.reverse, repoURL: fixture.root)
        XCTAssertEqual(try fixture.indexText("file.txt"), "a\nb\ninsert\nc\n")

        let stagedRaw = try await stagedPatch(service, fixture: fixture)
        let staged = try AgentChangesPartialPatchCompiler.parse(stagedRaw, expectedPath: "file.txt")
        let inserted = try XCTUnwrap(staged.changedLineKeys.first { key in
            if case .addition = key { return true }
            return false
        })
        let unstage = try AgentChangesPartialPatchCompiler.compile(
            staged,
            action: .unstage,
            selectedLineKeys: [inserted],
            selectsWholeHunks: false
        )
        try await service.applyIndexPatch(data: unstage.data, reverse: unstage.reverse, repoURL: fixture.root)

        XCTAssertEqual(try fixture.indexText("file.txt"), "a\nb\nc\n")
        XCTAssertEqual(try fixture.readText("file.txt"), "a\ninsert\nc\n")
    }

    func testStagesAndUnstagesOnlySelectedReplacementDeletion() async throws {
        let fixture = try GitPatchFixture(files: ["file.txt": "a\nb\nc\n"])
        try fixture.write("a\ninsert\nc\n", to: "file.txt")
        let service = GitService()
        let parsed = try await AgentChangesPartialPatchCompiler.parse(
            unstagedPatch(service, fixture: fixture),
            expectedPath: "file.txt"
        )

        let stage = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [.deletion(oldLine: 2)],
            selectsWholeHunks: false
        )
        try await service.applyIndexPatch(data: stage.data, reverse: stage.reverse, repoURL: fixture.root)
        XCTAssertEqual(try fixture.indexText("file.txt"), "a\nc\n")

        let staged = try await AgentChangesPartialPatchCompiler.parse(
            stagedPatch(service, fixture: fixture),
            expectedPath: "file.txt"
        )
        let deleted = try XCTUnwrap(staged.changedLineKeys.first { key in
            if case .deletion = key { return true }
            return false
        })
        let unstage = try AgentChangesPartialPatchCompiler.compile(
            staged,
            action: .unstage,
            selectedLineKeys: [deleted],
            selectsWholeHunks: false
        )
        try await service.applyIndexPatch(data: unstage.data, reverse: unstage.reverse, repoURL: fixture.root)

        XCTAssertEqual(try fixture.indexText("file.txt"), "a\nb\nc\n")
        XCTAssertEqual(try fixture.readText("file.txt"), "a\ninsert\nc\n")
    }

    func testCRLFAndNoFinalNewlinePatchesPreserveExactIndexBytes() async throws {
        let service = GitService()

        let crlf = try GitPatchFixture(files: ["file.txt": Data("one\r\ntwo\r\n".utf8)])
        try crlf.write(Data("ONE\r\ntwo\r\n".utf8), to: "file.txt")
        try await applyFirstHunk(service, fixture: crlf)
        XCTAssertEqual(try crlf.indexData("file.txt"), Data("ONE\r\ntwo\r\n".utf8))
        XCTAssertEqual(try crlf.readData("file.txt"), Data("ONE\r\ntwo\r\n".utf8))

        let noNewline = try GitPatchFixture(files: ["file.txt": Data("old".utf8)])
        try noNewline.write(Data("new".utf8), to: "file.txt")
        try await applyFirstHunk(service, fixture: noNewline)
        XCTAssertEqual(try noNewline.indexData("file.txt"), Data("new".utf8))
        XCTAssertEqual(try noNewline.readData("file.txt"), Data("new".utf8))
    }

    func testNoNewlineBoundaryLineSelectionsAreRefusedWhileWholeHunkStagingRoundTrips() async throws {
        // Index and worktree both end without a trailing newline. Selecting one side of that final
        // replacement used to emit git's positional no-newline marker mid-hunk; `git apply --cached`
        // accepted it and wrote `old lastnew last` into the index.
        let head = Data("context\nold last".utf8)
        let worktree = Data("context\nnew last".utf8)
        let fixture = try GitPatchFixture(files: ["file.txt": head])
        try fixture.write(worktree, to: "file.txt")
        let service = GitService()
        let parsed = try await AgentChangesPartialPatchCompiler.parse(
            unstagedPatch(service, fixture: fixture),
            expectedPath: "file.txt"
        )

        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: [.addition(newLine: 2)],
            selectsWholeHunks: false
        ))
        XCTAssertEqual(try fixture.indexData("file.txt"), head, "Nothing reached git apply")

        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.changedLineKeys,
            selectsWholeHunks: true
        )
        try await service.applyIndexPatch(
            data: compiled.data,
            reverse: compiled.reverse,
            repoURL: fixture.root
        )
        XCTAssertEqual(try fixture.indexData("file.txt"), worktree)
        XCTAssertEqual(try fixture.readData("file.txt"), worktree)

        let staged = try await AgentChangesPartialPatchCompiler.parse(
            stagedPatch(service, fixture: fixture),
            expectedPath: "file.txt"
        )
        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.compile(
            staged,
            action: .unstage,
            selectedLineKeys: [.deletion(oldLine: 2)],
            selectsWholeHunks: false
        ))
        XCTAssertEqual(try fixture.indexData("file.txt"), worktree, "The mirror unstage is refused too")

        let reversed = try AgentChangesPartialPatchCompiler.compile(
            staged,
            action: .unstage,
            selectedLineKeys: staged.changedLineKeys,
            selectsWholeHunks: true
        )
        try await service.applyIndexPatch(
            data: reversed.data,
            reverse: reversed.reverse,
            repoURL: fixture.root
        )
        XCTAssertEqual(try fixture.indexData("file.txt"), head)
        XCTAssertEqual(try fixture.readData("file.txt"), worktree)
    }

    func testSpaceAndLeadingDashPathsApplyWithoutOptionInterpretation() async throws {
        let fixture = try GitPatchFixture(files: [
            "space name.txt": "old\n",
            "-flag.txt": "before\n"
        ])
        let service = GitService()

        for (path, value) in [("space name.txt", "new\n"), ("-flag.txt", "after\n")] {
            try fixture.write(value, to: path)
            let raw = try await service.getDiffData(
                compare: .unstaged,
                paths: [path],
                contextLines: 3,
                detectRenames: false,
                at: fixture.root
            )
            let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: path)
            let compiled = try AgentChangesPartialPatchCompiler.compile(
                parsed,
                action: .stage,
                selectedLineKeys: parsed.changedLineKeys,
                selectsWholeHunks: true
            )
            try await service.applyIndexPatch(data: compiled.data, reverse: false, repoURL: fixture.root)
            XCTAssertEqual(try fixture.indexText(path), value)
        }
    }

    func testMalformedAndContextMismatchedPatchesLeaveIndexByteIdentical() async throws {
        let fixture = try GitPatchFixture(files: ["file.txt": "old\n"])
        try fixture.write("new\n", to: "file.txt")
        let service = GitService()
        let before = try fixture.gitData(["write-tree"])

        do {
            try await service.applyIndexPatch(
                data: Data("not a patch\n".utf8),
                reverse: false,
                repoURL: fixture.root
            )
            XCTFail("Expected invalid patch")
        } catch let error as GitIndexMutationError {
            guard case .invalidPatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.gitData(["write-tree"]), before)

        var mismatch = try await unstagedPatch(service, fixture: fixture)
        mismatch = Data(String(decoding: mismatch, as: UTF8.self).replacingOccurrences(
            of: "-old",
            with: "-different"
        ).utf8)
        do {
            try await service.applyIndexPatch(data: mismatch, reverse: false, repoURL: fixture.root)
            XCTFail("Expected patch mismatch")
        } catch let error as GitIndexMutationError {
            guard case .patchDoesNotApply = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.gitData(["write-tree"]), before)
    }

    func testMultiHunkApplyIsAtomicWhenOneHunkRejects() async throws {
        let original = numberedFile(first: "old-one", second: "old-two")
        let fixture = try GitPatchFixture(files: ["file.txt": original])
        try fixture.write(numberedFile(first: "new-one", second: "new-two"), to: "file.txt")
        let service = GitService()
        let parsed = try await AgentChangesPartialPatchCompiler.parse(
            service.getDiffData(
                compare: .unstaged,
                paths: ["file.txt"],
                contextLines: 1,
                detectRenames: false,
                at: fixture.root
            ),
            expectedPath: "file.txt"
        )
        var compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.changedLineKeys,
            selectsWholeHunks: true
        )
        compiled = .init(
            data: Data(text(compiled.data).replacingOccurrences(of: "-old-two", with: "-wrong-two").utf8),
            reverse: false
        )

        do {
            try await service.applyIndexPatch(data: compiled.data, reverse: false, repoURL: fixture.root)
            XCTFail("Expected atomic rejection")
        } catch let error as GitIndexMutationError {
            guard case .patchDoesNotApply = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.indexText("file.txt"), original)
    }

    func testDiffReadsTreatMagicAndUnicodePathsLiterallyForArgumentAndStdinPathspecs() async throws {
        let paths = [
            ":(exclude)probe.txt",
            ":!x.txt",
            "*.txt",
            "-leading-dash.txt",
            "café.txt"
        ]
        let fixture = try GitPatchFixture(
            files: Dictionary(uniqueKeysWithValues: paths.enumerated().map {
                ($0.element, "old-\($0.offset)\n")
            })
        )
        for (index, path) in paths.enumerated() {
            try fixture.write("new-\(index)\n", to: path)
        }
        let service = GitService()
        let filler = (0 ..< 1400).map {
            "missing/\($0)-\(String(repeating: "x", count: 100))"
        }

        for (index, path) in paths.enumerated() {
            for requestedPaths in [[path], [path] + filler] {
                let raw = try await service.getDiffData(
                    compare: .unstaged,
                    paths: requestedPaths,
                    contextLines: 3,
                    detectRenames: false,
                    at: fixture.root
                )
                let text = try await service.getDiffUnstaged(
                    paths: requestedPaths,
                    contextLines: 3,
                    detectRenames: false,
                    at: fixture.root
                )

                XCTAssertEqual(GitRawDiffFileSplitter.split(raw).count, 1)
                XCTAssertEqual(GitRawDiffFileSplitter.split(Data(text.utf8)).count, 1)
                XCTAssertTrue(text.contains("+new-\(index)"), "The sole patch belongs to \(path)")
                XCTAssertEqual(Data(text.utf8), raw)
            }
        }
    }

    func testUntrackedPartialCompilerRejectionDoesNotCreateIntentToAdd() async throws {
        let fixture = try GitPatchFixture(files: [String: String]())
        try fixture.write("new\n", to: "new.txt")
        let service = GitService()
        let patch = try await service.getUntrackedDiff(
            for: ["new.txt"],
            contextLines: 3,
            at: fixture.root
        )

        XCTAssertThrowsError(try AgentChangesPartialPatchCompiler.parse(
            Data(patch.utf8),
            expectedPath: "new.txt"
        ))
        XCTAssertTrue(try fixture.gitData(["ls-files", "--stage", "--", "new.txt"]).isEmpty)
    }

    func testEmptyAndOversizedPatchAreTypedNonMutatingFailures() async throws {
        let fixture = try GitPatchFixture(files: ["file.txt": "old\n"])
        let service = GitService()
        let before = try fixture.gitData(["write-tree"])

        do {
            try await service.applyIndexPatch(data: Data(), reverse: false, repoURL: fixture.root)
            XCTFail("Expected invalid patch")
        } catch let error as GitIndexMutationError {
            XCTAssertEqual(error, .invalidPatch("the patch is empty"))
        }

        do {
            try await service.applyIndexPatch(
                data: Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1),
                reverse: false,
                repoURL: fixture.root
            )
            XCTFail("Expected size rejection")
        } catch let error as GitIndexMutationError {
            XCTAssertEqual(error, .patchTooLarge(limit: 2 * 1024 * 1024))
        }
        XCTAssertEqual(try fixture.gitData(["write-tree"]), before)
    }

    func testRevokedAuthorityRefusesTheApplyAndLeavesTheIndexTreeIdentical() async throws {
        let fixture = try GitPatchFixture(
            files: ["file.txt": numberedFile(first: "old-one", second: "old-two")]
        )
        try fixture.write(numberedFile(first: "new-one", second: "new-two"), to: "file.txt")
        let service = GitService()
        let raw = try await service.getDiffData(
            compare: .unstaged,
            paths: ["file.txt"],
            contextLines: 1,
            detectRenames: false,
            at: fixture.root
        )
        let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: "file.txt")
        XCTAssertEqual(parsed.hunks.count, 2)
        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.hunks[0].changedLineKeys,
            selectsWholeHunks: true
        )
        let before = try fixture.gitData(["write-tree"])

        // A patch that would otherwise apply cleanly, refused by the hook the service evaluates
        // inside its index-mutation lock.
        do {
            try await service.applyIndexPatch(
                data: compiled.data,
                reverse: compiled.reverse,
                repoURL: fixture.root,
                authorize: neverAuthorizedIndexMutation
            )
            XCTFail("Expected the revoked apply to refuse")
        } catch let error as GitIndexMutationError {
            XCTAssertEqual(error, .authorizationRevoked)
        }

        XCTAssertEqual(try fixture.gitData(["write-tree"]), before)

        // The same bytes still apply once authority is intact, so the refusal was the hook rather
        // than anything wrong with the patch.
        try await service.applyIndexPatch(
            data: compiled.data,
            reverse: compiled.reverse,
            repoURL: fixture.root
        )
        XCTAssertEqual(
            try fixture.indexText("file.txt"),
            numberedFile(first: "new-one", second: "old-two")
        )
    }

    private func applyFirstHunk(_ service: GitService, fixture: GitPatchFixture) async throws {
        let raw = try await unstagedPatch(service, fixture: fixture)
        let parsed = try AgentChangesPartialPatchCompiler.parse(raw, expectedPath: "file.txt")
        let compiled = try AgentChangesPartialPatchCompiler.compile(
            parsed,
            action: .stage,
            selectedLineKeys: parsed.hunks[0].changedLineKeys,
            selectsWholeHunks: true
        )
        try await service.applyIndexPatch(data: compiled.data, reverse: compiled.reverse, repoURL: fixture.root)
    }

    private func unstagedPatch(_ service: GitService, fixture: GitPatchFixture) async throws -> Data {
        try await service.getDiffData(
            compare: .unstaged,
            paths: ["file.txt"],
            contextLines: 3,
            detectRenames: false,
            at: fixture.root
        )
    }

    private func stagedPatch(_ service: GitService, fixture: GitPatchFixture) async throws -> Data {
        try await service.getDiffData(
            compare: .staged(base: "HEAD"),
            paths: ["file.txt"],
            contextLines: 3,
            detectRenames: false,
            at: fixture.root
        )
    }

    private func numberedFile(first: String, second: String) -> String {
        [
            "zero", first, "two", "three", "four", "five",
            "six", "seven", second, "nine", ""
        ].joined(separator: "\n")
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private final class GitPatchFixture {
    let root: URL

    convenience init(files: [String: String]) throws {
        try self.init(files: files.mapValues { Data($0.utf8) })
    }

    init(files: [String: Data]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt-PartialPatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try git(["config", "user.email", "tests@repoprompt.local"])
        try git(["config", "user.name", "RepoPrompt Tests"])
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "core.autocrlf", "false"])

        for (path, data) in files {
            try write(data, to: path)
        }
        if files.isEmpty {
            try write("seed\n", to: ".seed")
        }
        try git(["add", "-A"])
        try git(["commit", "-qm", "initial"])
        if files.isEmpty {
            try FileManager.default.removeItem(at: root.appendingPathComponent(".seed"))
            try git(["add", "-A"])
            try git(["commit", "-qm", "remove seed"])
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func readText(_ path: String) throws -> String {
        try String(decoding: readData(path), as: UTF8.self)
    }

    func readData(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    func indexText(_ path: String) throws -> String {
        try String(decoding: indexData(path), as: UTF8.self)
    }

    func indexData(_ path: String) throws -> Data {
        try gitData(["show", ":\(path)"])
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try String(decoding: gitData(arguments), as: UTF8.self)
    }

    func gitData(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitPatchFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]
            )
        }
        return output
    }
}
