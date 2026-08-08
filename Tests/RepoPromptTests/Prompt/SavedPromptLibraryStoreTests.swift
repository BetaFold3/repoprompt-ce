import Combine
@testable import RepoPromptApp
import XCTest

@MainActor
final class SavedPromptLibraryStoreTests: XCTestCase {
    func testMutationFromOneOpenPromptViewModelUpdatesSecondWindowProjection() throws {
        let fixture = try makeFixture()
        let store = PromptStorage(fileURL: fixture.fileURL)
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let windowA = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let windowB = makePromptViewModel(windowID: 2, settingsStore: settingsStore, promptStore: store)

        let prompt = try windowA.addStoredPrompt(title: "Shared", content: "Original")
        XCTAssertEqual(windowB.storedPrompts.first(where: { $0.id == prompt.id })?.content, "Original")

        windowB.updatePromptSelection([prompt.id], for: .copy)
        try windowA.updateStoredPrompt(
            PromptViewModel.StoredPrompt(id: prompt.id, title: prompt.title, content: "Updated")
        )

        XCTAssertEqual(windowB.storedPrompts.first(where: { $0.id == prompt.id })?.content, "Updated")
        XCTAssertEqual(windowB.metaInstructions.count, 1)
        XCTAssertEqual(windowB.metaInstructions.first?.title, "Shared")
        XCTAssertEqual(windowB.metaInstructions.first?.content, "Updated")
        XCTAssertEqual(windowB.selectedPromptIDs, [prompt.id])
    }

    func testRemoteDeletionFollowedByStaleUpdateThrowsPromptNotFound() throws {
        let fixture = try makeFixture()
        var persistenceSnapshots: [[PromptViewModel.StoredPrompt]] = []
        let store = PromptStorage(
            fileURL: fixture.fileURL,
            persistenceObserver: { persistenceSnapshots.append($0) }
        )
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let windowA = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let windowB = makePromptViewModel(windowID: 2, settingsStore: settingsStore, promptStore: store)

        let stalePrompt = try windowA.addStoredPrompt(title: "Stale", content: "Original")
        try windowB.removeStoredPrompt(stalePrompt)
        store.waitForPendingWrites()
        let libraryAfterDeletion = store.prompts
        persistenceSnapshots.removeAll()

        XCTAssertThrowsError(
            try windowA.updateStoredPrompt(
                PromptViewModel.StoredPrompt(
                    id: stalePrompt.id,
                    title: stalePrompt.title,
                    content: "Must not return"
                )
            )
        ) { error in
            guard case let SavedPromptLibraryError.promptNotFound(id) = error else {
                return XCTFail("Expected SavedPromptLibraryError.promptNotFound, got \(error)")
            }
            XCTAssertEqual(id, stalePrompt.id)
        }

        store.waitForPendingWrites()
        XCTAssertEqual(store.prompts, libraryAfterDeletion)
        XCTAssertEqual(windowA.storedPrompts, libraryAfterDeletion)
        XCTAssertEqual(windowB.storedPrompts, libraryAfterDeletion)
        XCTAssertTrue(persistenceSnapshots.isEmpty)
    }

    func testStaleBuiltInSaveAfterRemoteResetUsesLastWriterWins() throws {
        let fixture = try makeFixture()
        let store = PromptStorage(fileURL: fixture.fileURL)
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let windowA = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let windowB = makePromptViewModel(windowID: 2, settingsStore: settingsStore, promptStore: store)

        guard let builtInBeforeReset = windowA.storedPrompts.first(where: {
            $0.id == windowA.architectPromptID
        }) else {
            return XCTFail("Expected the built-in architect prompt")
        }
        let staleDraft = PromptViewModel.StoredPrompt(
            id: builtInBeforeReset.id,
            title: builtInBeforeReset.title,
            content: "Stale editor content wins after reset"
        )
        XCTAssertFalse(staleDraft.isUserEdited)

        try windowB.resetUserPrompts()
        guard let builtInAfterReset = windowB.storedPrompts.first(where: {
            $0.id == builtInBeforeReset.id
        }) else {
            return XCTFail("Reset should preserve the built-in prompt UUID")
        }
        XCTAssertEqual(builtInAfterReset.id, builtInBeforeReset.id)
        XCTAssertFalse(builtInAfterReset.isUserEdited)

        try windowA.updateStoredPrompt(staleDraft)
        store.waitForPendingWrites()

        guard let saved = store.prompts.first(where: { $0.id == staleDraft.id }) else {
            return XCTFail("The stale built-in save should retain its UUID")
        }
        XCTAssertEqual(saved.id, builtInBeforeReset.id)
        XCTAssertEqual(saved.title, staleDraft.title)
        XCTAssertEqual(saved.content, staleDraft.content)
        XCTAssertTrue(saved.isUserEdited)

        let persisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        guard let persistedBuiltIn = persisted.first(where: { $0.id == staleDraft.id }) else {
            return XCTFail("The stale built-in save should be persisted")
        }
        XCTAssertEqual(persistedBuiltIn.id, builtInBeforeReset.id)
        XCTAssertEqual(persistedBuiltIn.title, staleDraft.title)
        XCTAssertEqual(persistedBuiltIn.content, staleDraft.content)
        XCTAssertTrue(persistedBuiltIn.isUserEdited)
    }

    func testSequentialMutationsFromTwoPromptViewModelsPreserveBothPrompts() throws {
        let fixture = try makeFixture()
        let store = PromptStorage(fileURL: fixture.fileURL)
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let windowA = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let windowB = makePromptViewModel(windowID: 2, settingsStore: settingsStore, promptStore: store)

        let promptA = try windowA.addStoredPrompt(title: "From A", content: "A")
        let promptB = try windowB.addStoredPrompt(title: "From B", content: "B")

        let expectedIDs: Set<UUID> = [promptA.id, promptB.id]
        XCTAssertTrue(expectedIDs.isSubset(of: Set(windowA.storedPrompts.map(\.id))))
        XCTAssertTrue(expectedIDs.isSubset(of: Set(windowB.storedPrompts.map(\.id))))

        store.waitForPendingWrites()
        let persisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        XCTAssertTrue(expectedIDs.isSubset(of: Set(persisted.map(\.id))))
    }

    func testGenuinelyMissingFileLoadsAsEmptyAndAllowsPersistence() throws {
        let fixture = try makeFixture()
        let store = PromptStorage(fileURL: fixture.fileURL)
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        var resolverCalls = 0
        let loadResult = store.loadIfNeeded { prompts in
            resolverCalls += 1
            return (prompts: prompts, needsSave: false)
        }
        guard case let .success(loadedPrompts) = loadResult else {
            return XCTFail("A genuinely absent saved-prompt file should load as an empty first-run library")
        }
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertTrue(loadedPrompts.isEmpty)

        let prompt = PromptViewModel.StoredPrompt(id: UUID(), title: "First", content: "Persist")
        try store.mutate { prompts in
            prompts.append(prompt)
            return true
        }
        store.waitForPendingWrites()

        let persisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        XCTAssertEqual(persisted, [prompt])
    }

    func testPersistRecreatesDeletedParentAndFreshStoreLoadsExactSnapshot() throws {
        let fixture = try makeFixture()
        let store = PromptStorage(fileURL: fixture.fileURL)
        var freshStore: PromptStorage?
        defer {
            freshStore?.waitForPendingWrites()
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let loadResult = store.loadIfNeeded { prompts in
            (prompts: prompts, needsSave: false)
        }
        guard case .success = loadResult else {
            return XCTFail("The initial store should load from the temporary location")
        }

        let promptID = try XCTUnwrap(UUID(uuidString: "66A4991E-8C6B-49ED-B561-488539C021B8"))
        let initialPrompt = PromptViewModel.StoredPrompt(
            id: promptID,
            title: "Before parent deletion",
            content: "Initial content"
        )
        try store.mutate { prompts in
            prompts = [initialPrompt]
            return true
        }
        store.waitForPendingWrites()

        let initiallyPersisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        XCTAssertEqual(initiallyPersisted.count, 1)
        XCTAssertEqual(initiallyPersisted[0].id, initialPrompt.id)
        XCTAssertEqual(initiallyPersisted[0].title, initialPrompt.title)
        XCTAssertEqual(initiallyPersisted[0].content, initialPrompt.content)

        try FileManager.default.removeItem(at: fixture.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))

        let expectedPrompt = PromptViewModel.StoredPrompt(
            id: initialPrompt.id,
            title: "After parent deletion",
            content: "Recovered content"
        )
        try store.mutate { prompts in
            prompts = [expectedPrompt]
            return true
        }
        store.waitForPendingWrites()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.directory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))

        let persisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].id, expectedPrompt.id)
        XCTAssertEqual(persisted[0].title, expectedPrompt.title)
        XCTAssertEqual(persisted[0].content, expectedPrompt.content)

        let reloadedStore = PromptStorage(fileURL: fixture.fileURL)
        freshStore = reloadedStore
        let reloadResult = reloadedStore.loadIfNeeded { prompts in
            (prompts: prompts, needsSave: false)
        }
        guard case let .success(reloadedPrompts) = reloadResult else {
            return XCTFail("The fresh store should load the recreated saved-prompt file")
        }
        XCTAssertEqual(reloadedPrompts.count, 1)
        XCTAssertEqual(reloadedPrompts[0].id, expectedPrompt.id)
        XCTAssertEqual(reloadedPrompts[0].title, expectedPrompt.title)
        XCTAssertEqual(reloadedPrompts[0].content, expectedPrompt.content)
    }

    func testInvalidParentPathLoadFailsClosedWithoutPersistence() throws {
        let fixture = try makeFixture()
        let blockedParent = fixture.directory.appendingPathComponent("NotADirectory")
        let blockerData = Data("regular file".utf8)
        try blockerData.write(to: blockedParent)

        var persistenceSnapshots: [[PromptViewModel.StoredPrompt]] = []
        let store = PromptStorage(
            fileURL: blockedParent.appendingPathComponent("SavedPrompts.json"),
            persistenceObserver: { persistenceSnapshots.append($0) }
        )
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        var resolverCalls = 0
        let firstLoad = store.loadIfNeeded { prompts in
            resolverCalls += 1
            return (prompts: prompts, needsSave: false)
        }
        guard case .failure = firstLoad else {
            return XCTFail("An invalid parent path must fail the saved-prompt load")
        }

        let secondLoad = store.loadIfNeeded { prompts in
            resolverCalls += 1
            return (prompts: prompts, needsSave: false)
        }
        guard case .failure = secondLoad else {
            return XCTFail("The failed load state must be retained")
        }

        XCTAssertThrowsError(
            try store.mutate { prompts in
                prompts.append(PromptViewModel.StoredPrompt(id: UUID(), title: "No", content: "Write"))
                return true
            }
        ) { error in
            guard case SavedPromptLibraryError.loadFailed = error else {
                return XCTFail("Expected SavedPromptLibraryError.loadFailed, got \(error)")
            }
        }

        store.waitForPendingWrites()
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertTrue(store.prompts.isEmpty)
        XCTAssertTrue(persistenceSnapshots.isEmpty)
        XCTAssertEqual(try Data(contentsOf: blockedParent), blockerData)
    }

    func testCorruptLoadMakesPromptViewModelOperationsFailClosed() throws {
        let fixture = try makeFixture()
        let corruptData = Data("{not valid json".utf8)
        try corruptData.write(to: fixture.fileURL)

        var persistenceSnapshots: [[PromptViewModel.StoredPrompt]] = []
        let store = PromptStorage(
            fileURL: fixture.fileURL,
            persistenceObserver: { persistenceSnapshots.append($0) }
        )
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let window = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let selectionBeforeAdd = window.selectedPromptIDs
        let libraryBeforeAdd = window.storedPrompts

        assertLoadFailed { _ = try window.addStoredPrompt(title: "Unavailable", content: "Do not add") }
        XCTAssertEqual(window.selectedPromptIDs, selectionBeforeAdd)
        XCTAssertEqual(window.storedPrompts, libraryBeforeAdd)

        let importURL = fixture.directory.appendingPathComponent("Import.json")
        try JSONEncoder().encode([PromptExport(title: "Imported", content: "Do not import")]).write(to: importURL)
        assertLoadFailed { _ = try window.importPrompts(from: importURL) }
        assertLoadFailed { try window.resetUserPrompts() }
        assertLoadFailed { try window.exportPrompts(to: fixture.fileURL) }
        store.waitForPendingWrites()

        XCTAssertEqual(window.selectedPromptIDs, selectionBeforeAdd)
        XCTAssertEqual(window.storedPrompts, libraryBeforeAdd)
        XCTAssertTrue(persistenceSnapshots.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corruptData)
    }

    func testResetPublishesAndPersistsOnlyFinalDefaultLibrary() throws {
        let fixture = try makeFixture()
        var persistenceSnapshots: [[PromptViewModel.StoredPrompt]] = []
        let store = PromptStorage(
            fileURL: fixture.fileURL,
            persistenceObserver: { persistenceSnapshots.append($0) }
        )
        defer {
            store.waitForPendingWrites()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let settingsStore = try makeSettingsStore(in: fixture.directory)
        let window = makePromptViewModel(windowID: 1, settingsStore: settingsStore, promptStore: store)
        let custom = try window.addStoredPrompt(title: "Custom", content: "Remove me")
        XCTAssertTrue(window.storedPrompts.contains(where: { $0.id == custom.id }))

        var publishedSnapshots: [[PromptViewModel.StoredPrompt]] = []
        let observation = store.$prompts
            .dropFirst()
            .sink { publishedSnapshots.append($0) }
        defer { observation.cancel() }
        persistenceSnapshots.removeAll()

        try window.resetUserPrompts()
        store.waitForPendingWrites()

        XCTAssertEqual(publishedSnapshots.count, 1)
        XCTAssertEqual(persistenceSnapshots.count, 1)
        XCTAssertFalse(publishedSnapshots[0].isEmpty)
        XCTAssertFalse(persistenceSnapshots[0].isEmpty)
        XCTAssertEqual(publishedSnapshots[0].map(\.id), persistenceSnapshots[0].map(\.id))
        XCTAssertFalse(publishedSnapshots[0].contains(where: { $0.id == custom.id }))

        let persisted = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: fixture.fileURL)
        )
        XCTAssertEqual(persisted.map(\.id), publishedSnapshots[0].map(\.id))
    }

    private func assertLoadFailed(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let libraryError = error as? SavedPromptLibraryError,
                  case let .loadFailed(underlying) = libraryError
            else {
                return XCTFail("Expected SavedPromptLibraryError.loadFailed, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(underlying is DecodingError, file: file, line: line)
        }
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedPromptLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("SavedPrompts.json"))
    }

    private func makeSettingsStore(in directory: URL) throws -> GlobalSettingsStore {
        let suiteName = "SavedPromptLibraryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fileURL = directory.appendingPathComponent("Settings/globalSettings.json")
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    private func makePromptViewModel(
        windowID: Int,
        settingsStore: GlobalSettingsStore,
        promptStore: PromptStorage
    ) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [:]))
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID, store: settingsStore),
            promptLibraryStore: promptStore
        )
    }
}
