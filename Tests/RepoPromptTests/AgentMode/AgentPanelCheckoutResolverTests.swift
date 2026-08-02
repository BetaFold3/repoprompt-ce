import Foundation
@testable import RepoPromptApp
import XCTest

/// Behavior contract for the Changes panel's checkout resolution.
///
/// The rule under test throughout is decision row 5: a bound agent worktree never silently falls
/// back to the workspace checkout, because the panel mutates a Git index and pointing that surface
/// at the wrong working tree would stage the wrong edits.
final class AgentPanelCheckoutResolverTests: XCTestCase {
    // MARK: - Plain roots

    func testRootWithoutABindingResolvesToItsOwnRepositoryCheckout() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo"],
            repositories: ["/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo", name: "repo")])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.blocked, [])
        XCTAssertEqual(resolution.targets.count, 1)
        let target = try? XCTUnwrap(resolution.targets.first)
        XCTAssertEqual(target?.checkoutURL.path, "/ws/repo")
        XCTAssertEqual(target?.repoRootURL.path, "/ws/repo")
        XCTAssertEqual(target?.backendKind, .git)
        XCTAssertEqual(target?.pathspecPrefixes, [], "A root that is the repository root represents all of it")
        XCTAssertNil(target?.worktree)
        XCTAssertEqual(target?.substitutesUnavailableWorktree, false)
    }

    func testRootNestedInsideARepositoryScopesTheTargetToItsOwnPathspecPrefix() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo/packages/app"],
            repositories: [
                "/ws/repo/packages/app": VCSResolvedRepo(
                    rootURL: URL(fileURLWithPath: "/ws/repo"),
                    backendKind: .git
                )
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo/packages/app")]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.first?.pathspecPrefixes, ["packages/app/"])
        XCTAssertEqual(resolution.targets.first?.containsRepositoryRelativePath("packages/app/main.swift"), true)
        XCTAssertEqual(
            resolution.targets.first?.containsRepositoryRelativePath("packages/other/main.swift"),
            false,
            "A stage-all must not be able to reach files the workspace does not represent"
        )
    }

    func testRootOutsideAnyRepositoryIsBlockedRatherThanShownAsAnEmptyCheckout() async {
        let probe = FakeCheckoutProbe(directories: ["/ws/notes"], repositories: [:])
        let request = AgentPanelCheckoutRequest(logicalRoots: [AgentPanelLogicalRoot(path: "/ws/notes")])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets, [])
        XCTAssertEqual(resolution.blocked.first?.reason, .notARepository(path: "/ws/notes"))
    }

    func testMissingRootIsBlockedWithItsOwnReason() async {
        let probe = FakeCheckoutProbe(directories: [], repositories: [:])
        let request = AgentPanelCheckoutRequest(logicalRoots: [AgentPanelLogicalRoot(path: "/ws/gone")])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.blocked.first?.reason, .rootMissing(path: "/ws/gone"))
    }

    // MARK: - Worktree redirection

    func testBoundWorktreeBecomesTheCheckoutInsteadOfTheWorkspaceRoot() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo", "/wt/feature"],
            repositories: [
                "/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git),
                "/wt/feature": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/wt/feature"), backendKind: .git)
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            worktreeBindings: [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.first?.checkoutURL.path, "/wt/feature")
        XCTAssertEqual(resolution.targets.first?.worktree?.label, "feature-x")
        XCTAssertEqual(resolution.targets.first?.substitutesUnavailableWorktree, false)
    }

    func testWorktreeScopeMirrorsTheLogicalRootPositionInsideItsRepository() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo/packages/app", "/wt/feature"],
            repositories: [
                "/ws/repo/packages/app": VCSResolvedRepo(
                    rootURL: URL(fileURLWithPath: "/ws/repo"),
                    backendKind: .git
                ),
                "/wt/feature": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/wt/feature"), backendKind: .git)
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo/packages/app")],
            worktreeBindings: [
                makeBinding(logicalRootPath: "/ws/repo/packages/app", worktreeRootPath: "/wt/feature")
            ]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.first?.checkoutURL.path, "/wt/feature")
        XCTAssertEqual(
            resolution.targets.first?.pathspecPrefixes,
            ["packages/app/"],
            "The workspace represents the same subtree inside the worktree that it did in the repository"
        )
    }

    func testMissingWorktreeReportsPreparingWhileTheSessionIsStillCreatingIt() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo"],
            repositories: ["/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            worktreeBindings: [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")],
            isPreparingWorktree: true
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            resolution.targets,
            [],
            "A preparing worktree must not fall back to the workspace checkout"
        )
        XCTAssertEqual(
            resolution.blocked.first?.reason,
            .worktreePreparing(label: "feature-x", worktreeRootPath: "/wt/feature")
        )
        XCTAssertTrue(resolution.isPreparing)
    }

    func testMissingWorktreeReportsUnavailableOnceTheSessionIsNoLongerPreparing() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo"],
            repositories: ["/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            worktreeBindings: [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")],
            isPreparingWorktree: false
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets, [])
        XCTAssertEqual(
            resolution.blocked.first?.reason,
            .worktreeMissing(label: "feature-x", worktreeRootPath: "/wt/feature")
        )
        XCTAssertFalse(resolution.isPreparing)
    }

    func testWorktreePathThatIsAFileReportsNotADirectory() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo"],
            files: ["/wt/feature"],
            repositories: [
                "/ws/repo": VCSResolvedRepo(
                    rootURL: URL(fileURLWithPath: "/ws/repo"),
                    backendKind: .git
                )
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            worktreeBindings: [
                makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")
            ]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            resolution.blocked.first?.reason,
            .worktreeNotADirectory(label: "feature-x", worktreeRootPath: "/wt/feature")
        )
    }

    func testAncestorBindingStillRedirectsADescendantLogicalRoot() async {
        let logicalRepo = VCSResolvedRepo(
            rootURL: URL(fileURLWithPath: "/ws/repo"),
            backendKind: .git
        )
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo/packages/app", "/wt/feature"],
            repositories: [
                "/ws/repo/packages/app": logicalRepo,
                "/wt/feature": VCSResolvedRepo(
                    rootURL: URL(fileURLWithPath: "/wt/feature"),
                    backendKind: .git
                )
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo/packages/app")],
            worktreeBindings: [
                makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")
            ]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.first?.checkoutURL.path, "/wt/feature")
        XCTAssertEqual(resolution.targets.first?.pathspecPrefixes, ["packages/app/"])
        XCTAssertTrue(
            resolution.blocked.isEmpty,
            "An ancestor/descendant root-list change must not silently fall back to the workspace checkout"
        )
    }

    func testWorktreeDirectoryWithoutARepositoryIsBrokenOnlyAfterPreparingEnds() async {
        let probe = FakeCheckoutProbe(directories: ["/ws/repo", "/wt/feature"], repositories: [
            "/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)
        ])
        let roots = [AgentPanelLogicalRoot(path: "/ws/repo")]
        let bindings = [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")]

        let preparing = await AgentPanelCheckoutResolver.resolve(
            AgentPanelCheckoutRequest(logicalRoots: roots, worktreeBindings: bindings, isPreparingWorktree: true),
            probe: probe
        )
        let settled = await AgentPanelCheckoutResolver.resolve(
            AgentPanelCheckoutRequest(logicalRoots: roots, worktreeBindings: bindings, isPreparingWorktree: false),
            probe: probe
        )

        XCTAssertEqual(
            preparing.blocked.first?.reason,
            .worktreePreparing(label: "feature-x", worktreeRootPath: "/wt/feature")
        )
        XCTAssertEqual(
            settled.blocked.first?.reason,
            .worktreeNotARepository(label: "feature-x", worktreeRootPath: "/wt/feature")
        )
    }

    func testOnlySettledWorktreeFailuresOfferTheWorkspaceCheckoutSubstitution() {
        XCTAssertFalse(
            AgentPanelCheckoutBlockReason
                .worktreePreparing(label: "x", worktreeRootPath: "/wt")
                .allowsWorkspaceCheckoutOverride,
            "The substitution is sticky, so it must not be offered during a hydration that will finish on its own"
        )
        XCTAssertTrue(
            AgentPanelCheckoutBlockReason
                .worktreeMissing(label: "x", worktreeRootPath: "/wt")
                .allowsWorkspaceCheckoutOverride
        )
        XCTAssertTrue(
            AgentPanelCheckoutBlockReason
                .worktreeNotARepository(label: "x", worktreeRootPath: "/wt")
                .allowsWorkspaceCheckoutOverride
        )
        XCTAssertFalse(
            AgentPanelCheckoutBlockReason.notARepository(path: "/ws").allowsWorkspaceCheckoutOverride
        )
    }

    func testExplicitOverrideSubstitutesTheWorkspaceCheckoutAndKeepsTheWarningFlagSet() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo"],
            repositories: ["/ws/repo": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            worktreeBindings: [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")],
            workspaceCheckoutOverrides: ["/ws/repo"]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.blocked, [])
        XCTAssertEqual(resolution.targets.first?.checkoutURL.path, "/ws/repo")
        XCTAssertEqual(
            resolution.targets.first?.substitutesUnavailableWorktree,
            true,
            "The panel keeps a warning chip while the substitution is in effect"
        )
        XCTAssertEqual(
            resolution.targets.first?.worktree?.label,
            "feature-x",
            "The chip names the worktree the user opted out of"
        )
    }

    // MARK: - Retry signal

    func testRetrySignatureChangesWhenABindingChangesSoPreparingRootsResolveAgain() {
        let roots = [AgentPanelLogicalRoot(path: "/ws/repo")]
        let preparing = AgentPanelCheckoutRequest(
            logicalRoots: roots,
            worktreeBindings: [makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature")],
            isPreparingWorktree: true
        )
        let hydrated = AgentPanelCheckoutRequest(
            logicalRoots: roots,
            worktreeBindings: [
                makeBinding(logicalRootPath: "/ws/repo", worktreeRootPath: "/wt/feature", head: "abc123")
            ],
            isPreparingWorktree: false
        )

        XCTAssertNotEqual(preparing.retrySignature, hydrated.retrySignature)
        XCTAssertEqual(preparing.retrySignature, preparing.retrySignature)
    }

    // MARK: - Collapsing

    func testTwoRootsOfOneRepositoryCollapseIntoOneTargetCarryingBothPrefixes() async {
        let repo = VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo/packages/a", "/ws/repo/packages/b"],
            repositories: ["/ws/repo/packages/a": repo, "/ws/repo/packages/b": repo]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/repo/packages/a", name: "a"),
            AgentPanelLogicalRoot(path: "/ws/repo/packages/b", name: "b")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            resolution.targets.count,
            1,
            "Two roots of one repository must not issue two status reads of the same index"
        )
        XCTAssertEqual(resolution.targets.first?.pathspecPrefixes, ["packages/a/", "packages/b/"])
        XCTAssertEqual(resolution.targets.first?.logicalRoots.map(\.displayName), ["a", "b"])
    }

    func testARootAtTheRepositoryRootWidensACollapsedGroupToTheWholeRepository() async {
        let repo = VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo", "/ws/repo/packages/a"],
            repositories: ["/ws/repo": repo, "/ws/repo/packages/a": repo]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/repo/packages/a"),
            AgentPanelLogicalRoot(path: "/ws/repo")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.count, 1)
        XCTAssertEqual(resolution.targets.first?.pathspecPrefixes, [])
        XCTAssertEqual(resolution.targets.first?.containsRepositoryRelativePath("anything/else.swift"), true)
    }

    func testUnexpressibleScopeWidensReadsButDisablesMutations() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/external-root"],
            repositories: [
                "/ws/external-root": VCSResolvedRepo(
                    rootURL: URL(fileURLWithPath: "/actual/repo"),
                    backendKind: .git
                )
            ]
        )
        let request = AgentPanelCheckoutRequest(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/external-root")]
        )

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)
        let target = try? XCTUnwrap(resolution.targets.first)

        XCTAssertEqual(target?.pathspecPrefixes, [], "Reads stay widened rather than hiding changes")
        XCTAssertEqual(target?.isMutationScopeRepresentable, false)
    }

    func testNestedPrefixesInOneGroupAbsorbTheirChildren() async {
        let repo = VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/repo"), backendKind: .git)
        let probe = FakeCheckoutProbe(
            directories: ["/ws/repo/packages", "/ws/repo/packages/a"],
            repositories: ["/ws/repo/packages": repo, "/ws/repo/packages/a": repo]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/repo/packages/a"),
            AgentPanelLogicalRoot(path: "/ws/repo/packages")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            resolution.targets.first?.pathspecPrefixes,
            ["packages/"],
            "Overlapping prefixes would double-count every file under the narrower one"
        )
    }

    func testRootsInDifferentRepositoriesStayAsSeparateTargets() async {
        let probe = FakeCheckoutProbe(
            directories: ["/ws/one", "/ws/two"],
            repositories: [
                "/ws/one": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/one"), backendKind: .git),
                "/ws/two": VCSResolvedRepo(rootURL: URL(fileURLWithPath: "/ws/two"), backendKind: .jujutsu)
            ]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/one"),
            AgentPanelLogicalRoot(path: "/ws/two")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(resolution.targets.map(\.checkoutURL.path), ["/ws/one", "/ws/two"])
        XCTAssertEqual(resolution.targets.map(\.backendKind), [.git, .jujutsu])
    }

    // MARK: - Fixtures

    private func makeBinding(
        logicalRootPath: String,
        worktreeRootPath: String,
        head: String? = nil
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(logicalRootPath)",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRootPath,
            worktreeID: "wt_abcdef12",
            worktreeRootPath: worktreeRootPath,
            worktreeName: "feature-x",
            branch: "feature",
            head: head,
            source: "test"
        )
    }
}

// MARK: - Fake probe

private struct FakeCheckoutProbe: AgentPanelCheckoutProbing {
    let directories: Set<String>
    let files: Set<String>
    let repositories: [String: VCSResolvedRepo]

    init(
        directories: [String],
        files: [String] = [],
        repositories: [String: VCSResolvedRepo]
    ) {
        self.directories = Set(directories)
        self.files = Set(files)
        self.repositories = repositories
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        if directories.contains(path) { return .directory }
        if files.contains(path) { return .file }
        return .missing
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        repositories[url.standardizedFileURL.path]
    }
}
