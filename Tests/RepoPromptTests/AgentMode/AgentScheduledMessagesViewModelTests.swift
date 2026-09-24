import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentScheduledMessagesViewModelTests: XCTestCase {
    func testIndexFilteringKeepsOnlyPendingSummariesAndRowsReadOnly() {
        let workspaceID = UUID()
        let scheduled = makeMetadataRecord(name: "Scheduled", summary: makeSummary(state: .scheduled))
        let historical = makeMetadataRecord(
            name: "Historical",
            summary: nil,
            lastScheduledDispatch: AgentScheduledSendProvenance(
                scheduleID: UUID(), attemptID: UUID(),
                scheduledFor: Date(timeIntervalSince1970: 1000),
                sentAt: Date(timeIntervalSince1970: 1200)
            )
        )
        let rows = AgentScheduledMessagesViewModel.indexRows(
            from: [scheduled, historical],
            workspaceID: workspaceID,
            workspaceName: "Other workspace"
        )

        XCTAssertEqual(rows.map(\.sessionID), [scheduled.id])
        XCTAssertEqual(rows.first?.workspaceID, workspaceID)
        XCTAssertEqual(rows.first?.workspaceName, "Other workspace")
        XCTAssertEqual(rows.first?.previewText, "Draft text")
        XCTAssertFalse(rows[0].isActionable, "All-workspaces index rows must never expose live actions")
    }

    func testIndexOnlyDispatchingNeverClaimsSendingWithoutLiveAdmission() {
        let summary = makeSummary(state: .dispatching)
        let indexOnly = AgentScheduledMessagesViewModel.indexStatus(summary: summary)
        let admitted = AgentScheduledMessagesViewModel.indexStatus(
            summary: summary,
            hasActiveAdmission: true
        )

        XCTAssertTrue(indexOnly.contains("Delivery unconfirmed"))
        XCTAssertFalse(indexOnly.contains("Sending"))
        XCTAssertTrue(admitted.contains("Sending"))
    }

    func testLiveProjectionReplacesStaleIndexRowBySessionIdentity() {
        let sessionID = UUID()
        let workspaceID = UUID()
        let summary = makeSummary(state: .scheduled)
        let indexed = AgentScheduledMessagesViewModel.indexRow(
            sessionID: sessionID,
            tabID: UUID(),
            workspaceID: workspaceID,
            workspaceName: "Workspace",
            sessionName: "Old name",
            summary: summary
        )
        let live = AgentScheduledMessagesViewModel.Row(
            sessionID: sessionID,
            tabID: UUID(),
            workspaceID: workspaceID,
            workspaceName: "Workspace",
            sessionName: "Current name",
            previewText: "Current text",
            statusText: "Live status",
            props: nil,
            actionHost: nil,
            recovery: nil
        )
        let merged = AgentScheduledMessagesViewModel.merging([indexed], replacingWith: [live])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sessionName, "Current name")
        XCTAssertEqual(merged[0].previewText, "Current text")
    }

    func testReloadAndCountHonorInMemoryNilOverStaleDiskSummary() async throws {
        let workspace = makeWorkspace("Current")
        let viewModel = makeViewModel(workspace: workspace)
        let sessionID = UUID()
        let tabID = UUID()
        let stale = makeMetadataRecord(
            id: sessionID, tabID: tabID, name: "Cancelled",
            summary: makeSummary(state: .scheduled)
        )
        let owner = try XCTUnwrap(viewModel.test_sessionIndexOwner)
        viewModel.test_installSessionIndexSnapshot(
            [sessionID: makeIndexEntry(id: sessionID, tabID: tabID, summary: nil)],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { _ in [stale] }
        )

        await dashboard.reload()
        XCTAssertTrue(dashboard.rows.isEmpty)
        XCTAssertEqual(AgentScheduledMessagesViewModel.currentWorkspaceCount(agentModeVM: viewModel), 0)
    }

    func testReloadAndCountHonorHydratedNilOverStaleIndexSummary() async throws {
        let workspace = makeWorkspace("Current")
        let viewModel = makeViewModel(workspace: workspace)
        let sessionID = UUID()
        let tabID = UUID()
        let summary = makeSummary(state: .scheduled)
        let stale = makeMetadataRecord(
            id: sessionID, tabID: tabID, name: "Cancelled",
            summary: summary
        )
        let owner = try XCTUnwrap(viewModel.test_sessionIndexOwner)
        viewModel.test_installSessionIndexSnapshot(
            [sessionID: makeIndexEntry(id: sessionID, tabID: tabID, summary: summary)],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        session.hasLoadedPersistedState = true
        session.scheduledSendWorkspaceID = workspace.id
        session.scheduledSend = nil
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { _ in [stale] }
        )

        await dashboard.reload()
        XCTAssertTrue(dashboard.rows.isEmpty)
        XCTAssertEqual(AgentScheduledMessagesViewModel.currentWorkspaceCount(agentModeVM: viewModel), 0)
    }

    func testHeldWorkspaceReadCannotPublishRowsOrActionsAfterOwnerSwitch() async {
        let workspaceA = makeWorkspace("A")
        let workspaceB = makeWorkspace("B")
        let viewModel = makeViewModel(workspace: workspaceA)
        let stale = makeMetadataRecord(name: "From A", summary: makeSummary(state: .scheduled))
        let gate = DashboardMetadataReadGate()
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { workspace in
                if workspace.id == workspaceA.id {
                    await gate.wait()
                    return [stale]
                }
                return []
            }
        )
        let held = Task { await dashboard.reload() }
        for _ in 0 ..< 200 where !gate.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(gate.isWaiting)
        viewModel.test_establishPersistenceWorkspace(workspaceB)
        gate.release()
        await held.value

        XCTAssertTrue(dashboard.rows.isEmpty, "A's held index read cannot publish under B's owner")
        XCTAssertNil(dashboard.loadError)
        await dashboard.reload()
        XCTAssertTrue(dashboard.rows.isEmpty)
    }

    func testModelOwnedWorkspaceObservationIgnoresSameIDAndRequestsReloadOnChange() async throws {
        let workspace = makeWorkspace("A")
        let viewModel = makeViewModel(workspace: workspace)
        let indexed = makeMetadataRecord(name: "Later", summary: makeSummary(state: .scheduled))
        let workspaceIDs = CurrentValueSubject<UUID?, Never>(workspace.id)
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { _ in [indexed] },
            workspaceIDs: workspaceIDs.eraseToAnyPublisher()
        )
        await dashboard.reload()
        let initialRow = try XCTUnwrap(dashboard.rows.first)
        XCTAssertEqual(dashboard.reloadRequest, 0)

        workspaceIDs.send(workspace.id)
        XCTAssertEqual(dashboard.reloadRequest, 0)
        XCTAssertTrue(dashboard.rows.first === initialRow, "Same-ID emissions preserve the current rows")

        workspaceIDs.send(UUID())
        XCTAssertEqual(dashboard.reloadRequest, 1)
        XCTAssertTrue(dashboard.rows.isEmpty, "A real workspace change clears rows before the next read")
        workspaceIDs.send(workspace.id)
        XCTAssertEqual(dashboard.reloadRequest, 2, "Each distinct workspace change requests one reload")
    }

    func testUnavailableIndexIsExplicitIncompleteReadOnlyWorkspace() async {
        let workspace = makeWorkspace("Unavailable")
        let viewModel = makeViewModel(workspace: workspace)
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { _ in nil }
        )
        dashboard.scope = .allWorkspaces
        await dashboard.reload()

        XCTAssertEqual(dashboard.rows.count, 1)
        XCTAssertEqual(dashboard.rows.first?.workspaceID, workspace.id)
        XCTAssertEqual(dashboard.rows.first?.isIndexUnavailable, true)
        XCTAssertFalse(dashboard.rows[0].isActionable)
        XCTAssertTrue(dashboard.rows[0].statusText.contains("unavailable"))
        XCTAssertNotNil(dashboard.loadError)
    }

    func testAllWorkspaceReloadKeepsIndexRowReadOnly() async {
        let workspace = makeWorkspace("Other")
        let viewModel = makeViewModel(workspace: workspace)
        let indexed = makeMetadataRecord(name: "Later", summary: makeSummary(state: .scheduled))
        let dashboard = AgentScheduledMessagesViewModel(
            agentModeVM: viewModel,
            metadataRecords: { _ in [indexed] }
        )
        dashboard.scope = .allWorkspaces
        await dashboard.reload()

        XCTAssertEqual(dashboard.rows.map(\.sessionID), [indexed.id])
        XCTAssertNil(dashboard.rows.first?.props)
        XCTAssertFalse(dashboard.rows[0].isActionable)
        let actionError = await dashboard.sendNow(dashboard.rows[0], runAlongsideOtherSessions: true)
        XCTAssertNotNil(actionError)
    }

    private func makeSummary(state: AgentScheduledSendPersist.State) -> AgentSessionScheduledSendSummary {
        AgentSessionScheduledSendSummary(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000),
            notBefore: Date(timeIntervalSince1970: 2000),
            stateRaw: state.rawValue,
            confirmationReasonRaw: nil,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            previewText: "Draft text",
            isUnreadable: false
        )
    }

    private func makeMetadataRecord(
        id: UUID = UUID(),
        tabID: UUID = UUID(),
        name: String,
        summary: AgentSessionScheduledSendSummary?,
        lastScheduledDispatch: AgentScheduledSendProvenance? = nil
    ) -> AgentSessionMetadataRecord {
        let now = Date(timeIntervalSince1970: 1000)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "session.json",
            workspaceID: nil,
            composeTabID: tabID,
            name: name,
            savedAt: now,
            lastUserMessageAt: nil,
            itemCount: 0,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: now,
            scheduledSendSummary: summary,
            lastScheduledDispatch: lastScheduledDispatch
        )
    }

    private func makeIndexEntry(
        id: UUID,
        tabID: UUID,
        summary: AgentSessionScheduledSendSummary?
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: "Session",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 1000),
            lastRunStateRaw: nil,
            itemCount: 0,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: nil,
            remoteHostName: nil,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: [],
            scheduledSendSummary: summary
        )
    }

    private func makeWorkspace(_ name: String) -> WorkspaceModel {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentScheduledMessagesTests-\(UUID().uuidString)")
        return WorkspaceModel(name: name, repoPaths: [storage.path], customStoragePath: storage)
    }

    private func makeViewModel(workspace: WorkspaceModel) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                fatalError("No provider is started by dashboard projection tests")
            }
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        return viewModel
    }
}

@MainActor
private final class DashboardMetadataReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    func wait() async {
        if released { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
