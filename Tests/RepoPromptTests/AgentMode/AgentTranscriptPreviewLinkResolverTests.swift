import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentTranscriptPreviewLinkResolverTests: XCTestCase {
    func testResolverProjectsWorktreePathsAndRejectsAmbiguousRelativePaths() async {
        let rootID = UUID()
        let worktreeEnvironment = TranscriptPreviewEnvironment(inputs: AgentChangesPanelRootInputs(
            logicalRoots: [AgentPanelLogicalRoot(path: "/ws/repo")],
            rootIDsByPath: ["/ws/repo": rootID],
            worktreeBindings: [AgentSessionWorktreeBinding(
                id: "binding",
                repositoryID: "repo",
                repoKey: "repo-key",
                logicalRootPath: "/ws/repo",
                worktreeID: "wt_abcdef12",
                worktreeRootPath: "/wt/repo",
                worktreeName: "agent-work",
                branch: "agent-work",
                head: nil,
                source: "test"
            )],
            isPreparingWorktree: false,
            watchedRootPaths: ["/ws/repo", "/wt/repo"]
        ))
        let worktreeResolver = AgentTranscriptPreviewLinkResolver(
            environment: worktreeEnvironment,
            probe: TranscriptPreviewProbe(repositoryPaths: ["/wt/repo"])
        )

        let worktreeReference = await worktreeResolver.reference(
            for: "docs/report.md",
            tabID: UUID()
        )
        XCTAssertEqual(
            worktreeReference,
            PreviewDocumentReference(rootID: rootID, relativePath: "docs/report.md")
        )

        let firstRootID = UUID()
        let secondRootID = UUID()
        let ambiguousEnvironment = TranscriptPreviewEnvironment(inputs: AgentChangesPanelRootInputs(
            logicalRoots: [
                AgentPanelLogicalRoot(path: "/ws/one"),
                AgentPanelLogicalRoot(path: "/ws/two")
            ],
            rootIDsByPath: ["/ws/one": firstRootID, "/ws/two": secondRootID],
            worktreeBindings: [],
            isPreparingWorktree: false,
            watchedRootPaths: ["/ws/one", "/ws/two"]
        ))
        let ambiguousResolver = AgentTranscriptPreviewLinkResolver(
            environment: ambiguousEnvironment,
            probe: TranscriptPreviewProbe(repositoryPaths: ["/ws/one", "/ws/two"])
        )

        let ambiguousReference = await ambiguousResolver.reference(for: "README.md", tabID: UUID())
        XCTAssertNil(ambiguousReference)
    }

    func testRoutingKindGateOrderingAndFallbackPolicy() async throws {
        let previewableDestinations = [
            "docs/report.md:42",
            "docs/report.MARKDOWN#L8",
            "docs/report.Html:9:2",
            "docs/report.HTM#line=4"
        ]
        for destination in previewableDestinations {
            let target = try XCTUnwrap(MarkdownFileLinkTarget.parse(rawDestination: destination))
            XCTAssertTrue(
                AgentTranscriptPreviewLinkRoutingPolicy.isPreviewable(target),
                destination
            )
        }

        for destination in ["Sources/App.swift:9", "docs/report.mdx", "docs/report.pdf"] {
            let target = try XCTUnwrap(MarkdownFileLinkTarget.parse(rawDestination: destination))
            XCTAssertFalse(
                AgentTranscriptPreviewLinkRoutingPolicy.isPreviewable(target),
                destination
            )
        }

        let reference = PreviewDocumentReference(rootID: UUID(), relativePath: "docs/report.md")
        var events: [String] = []
        let previewOutcome = await AgentTranscriptPreviewLinkRoutingPolicy.route(
            resolve: { reference },
            showPreview: { _ in events.append("show") },
            reveal: { events.append("reveal") },
            fallback: {
                events.append("fallback")
                return true
            }
        )

        XCTAssertEqual(previewOutcome, .previewed)
        XCTAssertEqual(events, ["show", "reveal"])

        events.removeAll()
        let missOutcome = await AgentTranscriptPreviewLinkRoutingPolicy.route(
            resolve: { nil },
            showPreview: { _ in events.append("show") },
            reveal: { events.append("reveal") },
            fallback: {
                events.append("fallback")
                return true
            }
        )

        XCTAssertEqual(missOutcome, .fellBack(true))
        XCTAssertEqual(events, ["fallback"])
    }

    func testCancelledRoutingCannotShowRevealOrFallBack() async {
        let reference = PreviewDocumentReference(rootID: UUID(), relativePath: "docs/report.md")
        let resolveGate = TranscriptPreviewRoutingGate<PreviewDocumentReference?>()
        var events: [String] = []
        let task = Task { @MainActor in
            await AgentTranscriptPreviewLinkRoutingPolicy.route(
                resolve: {
                    await resolveGate.wait()
                },
                showPreview: { _ in events.append("show") },
                reveal: { events.append("reveal") },
                fallback: {
                    events.append("fallback")
                    return true
                }
            )
        }

        await resolveGate.waitUntilSuspended()
        task.cancel()
        resolveGate.resume(returning: reference)

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(outcome.opened, "a superseded click is still semantically handled")
        XCTAssertFalse(AgentTranscriptPreviewLinkRoutingPolicy.Outcome.unresolved.opened)
        XCTAssertEqual(events, [])

        let fallbackGate = TranscriptPreviewRoutingGate<Bool>()
        let fallbackTask = Task { @MainActor in
            await AgentTranscriptPreviewLinkRoutingPolicy.route(
                resolve: { nil },
                showPreview: { _ in events.append("show") },
                reveal: { events.append("reveal") },
                fallback: {
                    events.append("fallback")
                    return await fallbackGate.wait()
                }
            )
        }

        await fallbackGate.waitUntilSuspended()
        fallbackTask.cancel()
        fallbackGate.resume(returning: true)

        let fallbackOutcome = await fallbackTask.value
        XCTAssertEqual(fallbackOutcome, .fellBack(true))
        XCTAssertEqual(events, ["fallback"])
    }
}

@MainActor
private final class TranscriptPreviewRoutingGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume(returning value: Value) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

@MainActor
private final class TranscriptPreviewEnvironment: AgentChangesPanelEnvironment {
    let inputs: AgentChangesPanelRootInputs

    init(inputs: AgentChangesPanelRootInputs) {
        self.inputs = inputs
    }

    func rootInputs(tabID: UUID?) async -> AgentChangesPanelRootInputs {
        inputs
    }

    func transcriptItems(tabID: UUID?) -> [AgentChatItem] {
        []
    }

    func transcriptItemsPublisher(tabID: UUID?) -> AnyPublisher<[AgentChatItem], Never>? {
        nil
    }

    func baseBranchCandidates(at checkout: URL) async -> [String] {
        []
    }

    func setCompareSelection(_ selection: AgentChangesCompareSelection, tabID: UUID?) {}

    func setDiffViewMode(_ mode: AgentChangesDiffViewMode, tabID: UUID?) {}

    func setChangesFilter(_ filter: AgentChangesFilter, tabID: UUID?) {}

    func selectBaseRevision(_ revision: String?, forRepoRoot repoRoot: String, tabID: UUID?) {}

    func setFileExpansion(_ isExpanded: Bool, file: AgentChangesFileStateKey, tabID: UUID?) {}
    func setFileViewed(
        _ viewed: Bool,
        revision: AgentChangesViewedRevision,
        compareTargetKey: String,
        collapseFile: AgentChangesFileStateKey?,
        tabID: UUID?
    ) {}

    func escalateContext(file: AgentChangesFileStateKey, tabID: UUID?) -> AgentChangesContextLevel {
        .standard
    }

    func showPreview(of document: PreviewDocumentReference, tabID: UUID?) {}

    func dismissBanner(artifactID: String, tabID: UUID?) {}
}

private final class TranscriptPreviewProbe: AgentPanelCheckoutProbing, @unchecked Sendable {
    private let repositoryPaths: Set<String>

    init(repositoryPaths: Set<String>) {
        self.repositoryPaths = repositoryPaths
    }

    func itemKind(at path: String) -> AgentPanelCheckoutItemKind {
        repositoryPaths.contains(path) ? .directory : .missing
    }

    func resolveRepository(at url: URL) async -> VCSResolvedRepo? {
        guard repositoryPaths.contains(url.standardizedFileURL.path) else { return nil }
        return VCSResolvedRepo(rootURL: url, backendKind: .git)
    }
}
