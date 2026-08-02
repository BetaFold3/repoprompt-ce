import Foundation
@testable import RepoPromptApp
import XCTest

/// Ordering, filtering, and path mapping for the Preview segment's document browser.
///
/// Every rule here is pure: the picker is handed inventories and returns rows, so "what the user
/// sees first" is settled without a workspace, an index, or a transcript.
final class AgentPreviewDocumentPickerTests: XCTestCase {
    private let rootID = UUID()
    private let secondRootID = UUID()

    // MARK: - Assembly

    func testDocumentsTheAgentWroteComeBeforeTheRepositorysOwn() {
        let entries = AgentPreviewDocumentPicker.entries(
            artifacts: [makeArtifact(path: "/repos/alpha/impl-report.md")],
            files: [
                makeFile(relativePath: "README.md", modifiedAt: date(9000)),
                makeFile(relativePath: "docs/design.md", modifiedAt: date(8000))
            ],
            context: makeContext()
        )

        XCTAssertEqual(entries.map(\.fileName), ["impl-report.md", "README.md", "design.md"])
        XCTAssertTrue(entries[0].isSessionArtifact)
        XCTAssertFalse(entries[1].isSessionArtifact)
    }

    func testRepositoryDocumentsAreOrderedByRecency() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [
                makeFile(relativePath: "old.md", modifiedAt: date(1000)),
                makeFile(relativePath: "newest.md", modifiedAt: date(9000)),
                makeFile(relativePath: "middle.md", modifiedAt: date(5000))
            ],
            context: makeContext()
        )

        XCTAssertEqual(entries.map(\.fileName), ["newest.md", "middle.md", "old.md"])
    }

    func testUndatedDocumentsSortLastAndTieBreakByPath() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [
                makeFile(relativePath: "zeta.md", modifiedAt: nil),
                makeFile(relativePath: "alpha.md", modifiedAt: nil),
                makeFile(relativePath: "dated.md", modifiedAt: date(1000))
            ],
            context: makeContext()
        )

        XCTAssertEqual(entries.map(\.fileName), ["dated.md", "alpha.md", "zeta.md"])
    }

    func testOnlyPreviewableFilesAreOffered() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [
                makeFile(relativePath: "notes.md"),
                makeFile(relativePath: "report.html"),
                makeFile(relativePath: "page.htm"),
                makeFile(relativePath: "Sources/main.swift"),
                makeFile(relativePath: "LICENSE")
            ],
            context: makeContext()
        )

        XCTAssertEqual(Set(entries.map(\.fileName)), ["notes.md", "report.html", "page.htm"])
    }

    func testADocumentListedBothAsAnArtifactAndInTheIndexAppearsOnce() {
        let entries = AgentPreviewDocumentPicker.entries(
            artifacts: [makeArtifact(path: "/repos/alpha/docs/design.md")],
            files: [makeFile(relativePath: "docs/design.md", modifiedAt: date(9000))],
            context: makeContext()
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isSessionArtifact, "the artifact reading wins, so the row keeps its section")
    }

    func testFilesInARootTheWorkspaceNoLongerHasAreDropped() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [makeFile(rootID: UUID(), relativePath: "orphan.md")],
            context: makeContext()
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testARowNamesItsRootWhenTheDocumentSitsAtTheTop() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [makeFile(relativePath: "README.md"), makeFile(relativePath: "docs/deep/design.md")],
            context: makeContext()
        )

        XCTAssertEqual(entries.first(where: { $0.fileName == "README.md" })?.directoryPath, "alpha")
        XCTAssertEqual(
            entries.first(where: { $0.fileName == "design.md" })?.directoryPath,
            "alpha/docs/deep"
        )
    }

    // MARK: - Filtering

    func testAnEmptyQueryKeepsEveryRowAndItsOrder() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [
                makeFile(relativePath: "newest.md", modifiedAt: date(9000)),
                makeFile(relativePath: "older.md", modifiedAt: date(1000))
            ],
            context: makeContext()
        )

        XCTAssertEqual(
            AgentPreviewDocumentPicker.filter(entries, query: "   ").map(\.fileName),
            entries.map(\.fileName)
        )
    }

    func testFileNamePrefixesOutrankContainsWhichOutranksPathMatches() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [
                makeFile(relativePath: "design/notes.md", modifiedAt: date(9000)),
                makeFile(relativePath: "docs/my-design.md", modifiedAt: date(8000)),
                makeFile(relativePath: "docs/design.md", modifiedAt: date(1000))
            ],
            context: makeContext()
        )

        let matches = AgentPreviewDocumentPicker.filter(entries, query: "design")

        XCTAssertEqual(
            matches.map(\.relativePath),
            ["docs/design.md", "docs/my-design.md", "design/notes.md"],
            "a file actually named design beats one that merely mentions it, even though it is older"
        )
    }

    func testFilteringIgnoresCaseAndDiacritics() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [makeFile(relativePath: "Café Notes.md")],
            context: makeContext()
        )

        XCTAssertEqual(AgentPreviewDocumentPicker.filter(entries, query: "cafe").count, 1)
        XCTAssertEqual(AgentPreviewDocumentPicker.filter(entries, query: "NOTES").count, 1)
    }

    func testANonMatchingQueryReturnsNothing() {
        let entries = AgentPreviewDocumentPicker.entries(
            files: [makeFile(relativePath: "docs/design.md")],
            context: makeContext()
        )

        XCTAssertTrue(AgentPreviewDocumentPicker.filter(entries, query: "kubernetes").isEmpty)
    }

    func testASessionArtifactStaysAboveAnEquallyGoodRepositoryMatch() {
        let entries = AgentPreviewDocumentPicker.entries(
            artifacts: [makeArtifact(path: "/repos/alpha/report.md")],
            files: [makeFile(relativePath: "docs/report.md", modifiedAt: date(9000))],
            context: makeContext()
        )

        let matches = AgentPreviewDocumentPicker.filter(entries, query: "report")

        XCTAssertEqual(matches.map(\.relativePath), ["report.md", "docs/report.md"])
    }

    // MARK: - Path mapping

    func testAnAbsolutePathMapsBackToItsRootRelativeReference() {
        let reference = AgentPreviewDocumentPicker.reference(
            forPath: "/repos/alpha/docs/design.md",
            in: makeContext()
        )

        XCTAssertEqual(reference?.rootID, rootID)
        XCTAssertEqual(reference?.relativePath, "docs/design.md")
    }

    func testAPathInsideABoundWorktreeMapsToTheLogicalRootThatOwnsIt() {
        var context = makeContext()
        context.worktreeBindings = [makeBinding(
            logicalRootPath: "/repos/alpha",
            worktreeRootPath: "/worktrees/alpha-feature"
        )]

        let reference = AgentPreviewDocumentPicker.reference(
            forPath: "/worktrees/alpha-feature/impl-report.md",
            in: context
        )

        XCTAssertEqual(
            reference?.rootID,
            rootID,
            "an agent writes into its worktree, but the reference has to survive rebinding"
        )
        XCTAssertEqual(reference?.relativePath, "impl-report.md")
    }

    func testTheDeepestMatchingRootClaimsTheDocument() {
        let context = AgentPreviewResolutionContext(roots: [
            AgentPreviewDocumentRoot(id: rootID, name: "alpha", path: "/repos/alpha"),
            AgentPreviewDocumentRoot(id: secondRootID, name: "nested", path: "/repos/alpha/packages/nested")
        ])

        let reference = AgentPreviewDocumentPicker.reference(
            forPath: "/repos/alpha/packages/nested/docs/api.md",
            in: context
        )

        XCTAssertEqual(reference?.rootID, secondRootID)
        XCTAssertEqual(reference?.relativePath, "docs/api.md")
    }

    func testAPathOutsideEveryCheckoutMapsToNothing() {
        XCTAssertNil(
            AgentPreviewDocumentPicker.reference(forPath: "/elsewhere/report.md", in: makeContext())
        )
        XCTAssertNil(AgentPreviewDocumentPicker.reference(forPath: "   ", in: makeContext()))
    }

    func testTheCheckoutRootItselfIsNotAReference() {
        XCTAssertNil(AgentPreviewDocumentPicker.reference(forPath: "/repos/alpha", in: makeContext()))
    }

    // MARK: - Helpers

    private func makeContext() -> AgentPreviewResolutionContext {
        AgentPreviewResolutionContext(roots: [
            AgentPreviewDocumentRoot(id: rootID, name: "alpha", path: "/repos/alpha")
        ])
    }

    private func makeFile(
        rootID: UUID? = nil,
        relativePath: String,
        modifiedAt: Date? = nil
    ) -> AgentPreviewCandidateFile {
        AgentPreviewCandidateFile(
            rootID: rootID ?? self.rootID,
            relativePath: relativePath,
            modifiedAt: modifiedAt
        )
    }

    private func makeArtifact(path: String, createdAt: Date = Date(timeIntervalSince1970: 7000)) -> AgentSessionArtifact {
        let itemID = UUID()
        return AgentSessionArtifact(
            id: AgentSessionArtifact.identifier(toolItemID: itemID, changeIndex: 0, path: path),
            path: path,
            kind: AgentSessionArtifactKind(fileExtension: (path as NSString).pathExtension) ?? .markdown,
            disposition: .created,
            toolItemID: itemID,
            toolKind: .applyEdits,
            createdAt: createdAt
        )
    }

    private func makeBinding(
        logicalRootPath: String,
        worktreeRootPath: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: "repo",
            repoKey: "repo-key",
            logicalRootPath: logicalRootPath,
            worktreeID: "worktree",
            worktreeRootPath: worktreeRootPath,
            source: "test"
        )
    }

    private func date(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval)
    }
}
