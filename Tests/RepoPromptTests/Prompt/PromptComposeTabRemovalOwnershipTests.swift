import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class PromptComposeTabRemovalOwnershipTests: XCTestCase {
    func testCascadeAdmissionUsesCurrentIndexAfterPrecedingWorkspaceRemoval() async throws {
        let fixture = try makeFixture(windowID: 5620, precedingWorkspace: true)
        let gate = SuspensionGate()
        fixture.prompt.composeTabCascadeResolver = { _, _ in
            await gate.hold()
            return .init()
        }

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [gate.entered], timeout: 5)
        fixture.manager.workspaces.removeFirst()
        gate.resume()
        await removal.value

        XCTAssertEqual(fixture.manager.workspaces.count, 1)
        XCTAssertEqual(fixture.manager.workspaces[0].id, fixture.activeWorkspace.id)
        XCTAssertEqual(fixture.manager.workspaces[0].composeTabs.map(\.id), [fixture.survivingTabID])
        XCTAssertEqual(fixture.manager.workspaces[0].activeComposeTabID, fixture.survivingTabID)
    }

    func testCascadeAdmissionUsesCurrentIndexAfterWorkspaceReorder() async throws {
        let fixture = try makeFixture(windowID: 5621, precedingWorkspace: true)
        let gate = SuspensionGate()
        fixture.prompt.composeTabCascadeResolver = { _, _ in
            await gate.hold()
            return .init()
        }
        let preceding = try XCTUnwrap(fixture.manager.workspaces.first)
        let precedingTabIDs = preceding.composeTabs.map(\.id)

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [gate.entered], timeout: 5)
        fixture.manager.workspaces.swapAt(0, 1)
        gate.resume()
        await removal.value

        XCTAssertEqual(fixture.manager.workspaces[0].id, fixture.activeWorkspace.id)
        XCTAssertEqual(fixture.manager.workspaces[0].composeTabs.map(\.id), [fixture.survivingTabID])
        XCTAssertEqual(fixture.manager.workspaces[1].id, preceding.id)
        XCTAssertEqual(fixture.manager.workspaces[1].composeTabs.map(\.id), precedingTabIDs)
    }

    func testBackgroundCloseDoesNotReplayForegroundSnapshotAfterCleanup() async throws {
        let fixture = try makeFixture(windowID: 5622, activeTabIsSurvivor: true)
        let cleanup = DeferredCleanup()
        cleanup.install(on: fixture.prompt)

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [cleanup.gate.entered], timeout: 5)
        XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, fixture.survivingTabID)
        fixture.prompt.promptText = "foreground edit during cleanup"
        cleanup.gate.resume()
        await removal.value

        XCTAssertEqual(fixture.prompt.promptText, "foreground edit during cleanup")
        XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, fixture.survivingTabID)
    }

    func testFallbackApplyUsesCurrentStateAfterCleanup() async throws {
        let fixture = try makeFixture(windowID: 5623)
        let cleanup = DeferredCleanup()
        cleanup.install(on: fixture.prompt)

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [cleanup.gate.entered], timeout: 5)
        let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex(where: { $0.id == fixture.activeWorkspace.id }))
        let fallbackIndex = try XCTUnwrap(
            fixture.manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == fixture.survivingTabID })
        )
        XCTAssertEqual(
            fixture.manager.workspaces[workspaceIndex].composeTabs[fallbackIndex].promptText,
            "original fallback",
            "The logical commit must not snapshot the removed tab's UI into the fallback"
        )
        fixture.manager.workspaces[workspaceIndex].composeTabs[fallbackIndex].promptText = "fallback edit during cleanup"
        cleanup.gate.resume()
        await removal.value

        XCTAssertEqual(fixture.prompt.promptText, "fallback edit during cleanup")
        XCTAssertEqual(
            fixture.manager.workspaces[workspaceIndex].composeTabs[fallbackIndex].promptText,
            "fallback edit during cleanup"
        )
    }

    func testFallbackUserEditDuringCleanupIsNotReappliedOver() async throws {
        let fixture = try makeFixture(windowID: 5625)
        let files = try await loadFileState(for: fixture)
        try setSurvivorState(
            fixture,
            selection: files.oldFile.path,
            expansion: files.oldFolder.path,
            context: "fallback context"
        )
        let cleanup = DeferredCleanup()
        cleanup.install(on: fixture.prompt)
        #if DEBUG
            var didReachApplication = false
            fixture.manager.composeTabApplyAfterContextHookForTesting = { _ in didReachApplication = true }
        #endif

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [cleanup.gate.entered], timeout: 5)
        fixture.prompt.promptText = "unsaved fallback edit"
        fixture.prompt.setFilesTabSelection(.explicit(.context), source: .user)
        cleanup.gate.resume()
        await removal.value

        XCTAssertEqual(fixture.prompt.promptText, "unsaved fallback edit")
        XCTAssertEqual(fixture.prompt.activeFilesTab, .context)
        XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, fixture.survivingTabID)
        let survivingTab = try XCTUnwrap(
            fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.id == fixture.survivingTabID })
        )
        XCTAssertEqual(survivingTab.promptText, "unsaved fallback edit")
        XCTAssertEqual(survivingTab.activeSubView, .context)
        XCTAssertEqual(
            fixture.prompt.currentContextBuilderOverridesSnapshot().overridePromptText,
            "fallback context"
        )
        XCTAssertEqual(Set(fixture.fileManager.snapshotSelection().selectedPaths), Set([files.oldFile.path]))
        XCTAssertTrue(fixture.fileManager.snapshotExpandedFolderFullPaths().contains(files.oldFolder.path))
        #if DEBUG
            XCTAssertTrue(didReachApplication, "A live edit must not skip fallback file/context activation")
        #endif
    }

    func testCleanupRejectsAwayAndBackWithSameWorkspaceAndTabIDs() async throws {
        let fixture = try makeFixture(windowID: 5624, precedingWorkspace: true)
        let cleanup = DeferredCleanup()
        cleanup.install(on: fixture.prompt)
        #if DEBUG
            var applicationCount = 0
            fixture.manager.composeTabApplyAfterContextHookForTesting = { _ in applicationCount += 1 }
        #endif

        let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
        await fulfillment(of: [cleanup.gate.entered], timeout: 5)
        let foreignWorkspace = try XCTUnwrap(fixture.manager.workspaces.first)
        fixture.manager.activeWorkspace = foreignWorkspace
        fixture.manager.activeWorkspace = fixture.activeWorkspace
        XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, fixture.survivingTabID)
        cleanup.ownerEpoch += 1
        cleanup.gate.resume()
        await removal.value

        XCTAssertEqual(fixture.prompt.promptText, "closing text", "Only the changed epoch rejects activation")
        XCTAssertEqual(fixture.manager.activeWorkspace?.id, fixture.activeWorkspace.id)
        XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, fixture.survivingTabID)
        #if DEBUG
            XCTAssertEqual(applicationCount, 0)
        #endif
    }

    #if DEBUG
        func testOldApplicationStageCannotOverwriteNewerSameTabActivation() async throws {
            let fixture = try makeFixture(windowID: 5626, precedingWorkspace: true)
            let files = try await loadFileState(for: fixture)
            try setSurvivorState(
                fixture,
                selection: files.oldFile.path,
                expansion: files.oldFolder.path,
                context: "old context"
            )
            let cleanup = DeferredCleanup()
            cleanup.install(on: fixture.prompt)
            let stageGate = SuspensionGate()
            var holdFirstApplication = true
            fixture.manager.composeTabApplyAfterContextHookForTesting = { tabID in
                guard tabID == fixture.survivingTabID, holdFirstApplication else { return }
                holdFirstApplication = false
                await stageGate.hold()
            }

            let removal = Task { await fixture.prompt.closeComposeTab(fixture.closingTabID) }
            await fulfillment(of: [cleanup.gate.entered], timeout: 5)
            cleanup.gate.resume()
            await fulfillment(of: [stageGate.entered], timeout: 5)

            let foreignWorkspace = try XCTUnwrap(fixture.manager.workspaces.first)
            fixture.manager.activeWorkspace = foreignWorkspace
            fixture.manager.activeWorkspace = fixture.activeWorkspace
            try setSurvivorState(
                fixture,
                selection: files.newFile.path,
                expansion: files.newFolder.path,
                context: "new context"
            )
            let workspaceIndex = try XCTUnwrap(
                fixture.manager.workspaces.firstIndex(where: { $0.id == fixture.activeWorkspace.id })
            )
            let tabIndex = try XCTUnwrap(
                fixture.manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == fixture.survivingTabID })
            )
            fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex].promptText = "new prompt"
            fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex].activeSubView = .selected
            let newerTab = fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex]
            await fixture.manager.applyComposeTabState(newerTab)
            stageGate.resume()
            await removal.value

            XCTAssertEqual(fixture.prompt.promptText, "new prompt")
            XCTAssertEqual(fixture.prompt.activeFilesTab, .selected)
            XCTAssertEqual(
                fixture.prompt.currentContextBuilderOverridesSnapshot().overridePromptText,
                "new context"
            )
            XCTAssertEqual(Set(fixture.fileManager.snapshotSelection().selectedPaths), Set([files.newFile.path]))
            let survivingTab = try XCTUnwrap(
                fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.id == fixture.survivingTabID })
            )
            XCTAssertEqual(survivingTab.selection.selectedPaths, [files.newFile.path])
            XCTAssertEqual(survivingTab.expandedFolders, [files.newFolder.path])
            XCTAssertEqual(survivingTab.contextOverrides.overridePromptText, "new context")
            let expandedPaths = Set(fixture.fileManager.snapshotExpandedFolderFullPaths())
            XCTAssertTrue(expandedPaths.contains(files.newFolder.path))
            XCTAssertFalse(expandedPaths.contains(files.oldFolder.path))
        }
    #endif

    private func makeFixture(
        windowID: Int,
        precedingWorkspace: Bool = false,
        activeTabIsSurvivor: Bool = false
    ) throws -> Fixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptComposeTabRemovalOwnershipTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
        }

        let closingTabID = UUID()
        let survivingTabID = UUID()
        let activeWorkspace = WorkspaceModel(
            name: "Active",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL,
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: closingTabID, name: "Closing", promptText: "closing text"),
                ComposeTabState(id: survivingTabID, name: "Surviving", promptText: "original fallback")
            ],
            activeComposeTabID: activeTabIsSurvivor ? survivingTabID : closingTabID
        )
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        prompt.attachWorkspaceManager(manager)
        if precedingWorkspace {
            let preceding = WorkspaceModel(
                name: "Preceding",
                repoPaths: [storageURL.path],
                customStoragePath: storageURL,
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(name: "Foreign")],
                activeComposeTabID: nil
            )
            manager.workspaces = [preceding, activeWorkspace]
        } else {
            manager.workspaces = [activeWorkspace]
        }
        manager.activeWorkspace = activeWorkspace
        prompt.loadComposeTabsFromWorkspace(activeWorkspace)
        prompt.promptText = activeTabIsSurvivor ? "original fallback" : "closing text"
        return Fixture(
            prompt: prompt,
            manager: manager,
            fileManager: fileManager,
            activeWorkspace: activeWorkspace,
            storageURL: storageURL,
            closingTabID: closingTabID,
            survivingTabID: survivingTabID
        )
    }

    private struct Fixture {
        let prompt: PromptViewModel
        let manager: WorkspaceManagerViewModel
        let fileManager: WorkspaceFilesViewModel
        let activeWorkspace: WorkspaceModel
        let storageURL: URL
        let closingTabID: UUID
        let survivingTabID: UUID
    }

    private struct FileState {
        let oldFolder: URL
        let newFolder: URL
        let oldFile: URL
        let newFile: URL
    }

    private func loadFileState(for fixture: Fixture) async throws -> FileState {
        let oldFolder = fixture.storageURL.appendingPathComponent("Old", isDirectory: true)
        let newFolder = fixture.storageURL.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let oldFile = oldFolder.appendingPathComponent("Old.swift")
        let newFile = newFolder.appendingPathComponent("New.swift")
        try Data("struct Old {}\n".utf8).write(to: oldFile)
        try Data("struct New {}\n".utf8).write(to: newFile)
        try await fixture.fileManager.loadFolder(at: fixture.storageURL, for: fixture.activeWorkspace)
        addTeardownBlock {
            await fixture.fileManager.unloadAllRootFolders()
        }
        _ = await fixture.fileManager.findFiles(atPaths: [oldFile.path, newFile.path])
        let oldFolderPath = try XCTUnwrap(
            fixture.fileManager.findFolderByFullPath(oldFolder.path)?.standardizedFullPath
        )
        let newFolderPath = try XCTUnwrap(
            fixture.fileManager.findFolderByFullPath(newFolder.path)?.standardizedFullPath
        )
        let oldFilePath = try XCTUnwrap(
            fixture.fileManager.findFileByFullPath(oldFile.path)?.standardizedFullPath
        )
        let newFilePath = try XCTUnwrap(
            fixture.fileManager.findFileByFullPath(newFile.path)?.standardizedFullPath
        )
        return FileState(
            oldFolder: URL(fileURLWithPath: oldFolderPath),
            newFolder: URL(fileURLWithPath: newFolderPath),
            oldFile: URL(fileURLWithPath: oldFilePath),
            newFile: URL(fileURLWithPath: newFilePath)
        )
    }

    private func setSurvivorState(
        _ fixture: Fixture,
        selection: String,
        expansion: String,
        context: String
    ) throws {
        let workspaceIndex = try XCTUnwrap(
            fixture.manager.workspaces.firstIndex(where: { $0.id == fixture.activeWorkspace.id })
        )
        let tabIndex = try XCTUnwrap(
            fixture.manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == fixture.survivingTabID })
        )
        fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex].selection = StoredSelection(
            selectedPaths: [selection],
            codemapAutoEnabled: false
        )
        fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex].expandedFolders = [expansion]
        fixture.manager.workspaces[workspaceIndex].composeTabs[tabIndex].contextOverrides = ContextBuilderOverrides(
            useOverridePrompt: true,
            overridePromptText: context
        )
    }

    @MainActor
    private final class SuspensionGate {
        let entered = XCTestExpectation(description: "asynchronous boundary reached")
        private var continuation: CheckedContinuation<Void, Never>?

        func hold() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func resume() {
            guard let continuation else {
                XCTFail("Expected a held continuation")
                return
            }
            self.continuation = nil
            continuation.resume()
        }
    }

    @MainActor
    private final class DeferredCleanup {
        let gate = SuspensionGate()
        var ownerEpoch = 0
        private var task: Task<Void, Never>?

        func install(on prompt: PromptViewModel) {
            let operationID = UUID()
            prompt.composeTabRemovalPreflight = { _ in operationID }
            prompt.composeTabRemovalPrepare = { _ in true }
            prompt.composeTabRemovalFinalCommit = { [self] _, promptMutation, promptCleanup in
                guard promptMutation() else { return false }
                let committedEpoch = ownerEpoch
                task = Task { @MainActor [self] in
                    await gate.hold()
                    await promptCleanup { ownerEpoch == committedEpoch }
                }
                return true
            }
            prompt.composeTabRemovalAwaitCleanup = { [self] _ in await task?.value }
        }
    }
}
