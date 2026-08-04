import Foundation
@testable import RepoPromptApp
import XCTest

/// Ordering contracts needed before the Changes panel renders every resolved checkout.
///
/// The resolver is the sole place where logical workspace order, checkout collapse, and blocked
/// worktree outcomes meet. These tests keep that ordering deterministic without involving the later
/// repository-pool view-model cutover.
final class AgentPanelCheckoutResolverMultiRootTests: XCTestCase {
    func testResolvedItemsPreserveLogicalRootRequestOrder() async {
        let probe = MultiRootCheckoutProbe(
            directories: ["/ws/alpha", "/ws/beta", "/ws/gamma"],
            repositories: [
                "/ws/alpha": repository(at: "/ws/alpha"),
                "/ws/beta": repository(at: "/ws/beta"),
                "/ws/gamma": repository(at: "/ws/gamma")
            ]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/alpha", name: "alpha"),
            AgentPanelLogicalRoot(path: "/ws/beta", name: "beta"),
            AgentPanelLogicalRoot(path: "/ws/gamma", name: "gamma")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            itemLabels(in: resolution),
            ["resolved:alpha", "resolved:beta", "resolved:gamma"]
        )
        XCTAssertEqual(
            resolution.targets.map(\.checkoutURL.path),
            ["/ws/alpha", "/ws/beta", "/ws/gamma"],
            "the legacy convenience must project the same resolved order"
        )
        XCTAssertTrue(resolution.blocked.isEmpty)
    }

    func testCollapsedCheckoutIsEmittedAtItsFirstLogicalRootPosition() async {
        let alpha = repository(at: "/ws/alpha")
        let beta = repository(at: "/ws/beta")
        let probe = MultiRootCheckoutProbe(
            directories: [
                "/ws/alpha/packages/one",
                "/ws/beta",
                "/ws/alpha/packages/two"
            ],
            repositories: [
                "/ws/alpha/packages/one": alpha,
                "/ws/beta": beta,
                "/ws/alpha/packages/two": alpha
            ]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/alpha/packages/one", name: "alpha-one"),
            AgentPanelLogicalRoot(path: "/ws/beta", name: "beta"),
            AgentPanelLogicalRoot(path: "/ws/alpha/packages/two", name: "alpha-two")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            itemLabels(in: resolution),
            ["resolved:alpha-one + alpha-two", "resolved:beta"],
            "the collapsed alpha checkout belongs where its first logical root appeared"
        )
        XCTAssertEqual(resolution.targets.count, 2)
        XCTAssertEqual(
            resolution.targets.first?.pathspecPrefixes,
            ["packages/one/", "packages/two/"]
        )
        XCTAssertEqual(
            resolution.targets.first?.logicalRoots.map(\.displayName),
            ["alpha-one", "alpha-two"]
        )
    }

    func testBlockedRootsRemainInterleavedWithResolvedCheckouts() async {
        let probe = MultiRootCheckoutProbe(
            directories: ["/ws/alpha", "/ws/gamma", "/ws/notes"],
            repositories: [
                "/ws/alpha": repository(at: "/ws/alpha"),
                "/ws/gamma": repository(at: "/ws/gamma")
            ]
        )
        let request = AgentPanelCheckoutRequest(logicalRoots: [
            AgentPanelLogicalRoot(path: "/ws/alpha", name: "alpha"),
            AgentPanelLogicalRoot(path: "/ws/missing", name: "missing"),
            AgentPanelLogicalRoot(path: "/ws/gamma", name: "gamma"),
            AgentPanelLogicalRoot(path: "/ws/notes", name: "notes")
        ])

        let resolution = await AgentPanelCheckoutResolver.resolve(request, probe: probe)

        XCTAssertEqual(
            itemLabels(in: resolution),
            ["resolved:alpha", "blocked:missing", "resolved:gamma", "blocked:notes"]
        )
        XCTAssertEqual(
            resolution.targets.map(\.displayName),
            ["alpha", "gamma"],
            "computed resolved convenience must not reorder around blocked items"
        )
        XCTAssertEqual(
            resolution.blocked.map(\.logicalRoot.displayName),
            ["missing", "notes"],
            "computed blocked convenience must retain request order"
        )
        XCTAssertEqual(
            resolution.blocked.map(\.reason),
            [.rootMissing(path: "/ws/missing"), .notARepository(path: "/ws/notes")]
        )
    }

    // MARK: - Fixtures

    private func itemLabels(in resolution: AgentPanelCheckoutResolution) -> [String] {
        resolution.items.map { item in
            switch item {
            case let .resolved(target):
                "resolved:\(target.displayName)"
            case let .blocked(blockedCheckout):
                "blocked:\(blockedCheckout.logicalRoot.displayName)"
            }
        }
    }

    private func repository(
        at path: String,
        backendKind: VCSBackendKind = .git
    ) -> VCSResolvedRepo {
        VCSResolvedRepo(
            rootURL: URL(fileURLWithPath: path),
            backendKind: backendKind
        )
    }
}

private struct MultiRootCheckoutProbe: AgentPanelCheckoutProbing {
    let directories: Set<String>
    let repositories: [String: VCSResolvedRepo]

    init(
        directories: [String],
        repositories: [String: VCSResolvedRepo]
    ) {
        self.directories = Set(directories)
        self.repositories = repositories
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        directories.contains(path) ? .directory : .missing
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        repositories[url.standardizedFileURL.path]
    }
}
