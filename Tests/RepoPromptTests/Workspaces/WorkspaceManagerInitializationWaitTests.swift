@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceManagerInitializationWaitTests: XCTestCase {
        func testBoundedWaitReturnsImmediatelyWhenAlreadyInitialized() async throws {
            let manager = makeManager()
            XCTAssertTrue(manager.isInitialized)

            try await manager.awaitInitialized(timeout: .seconds(30))

            XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
            XCTAssertEqual(manager.test_activeInitializationTimeoutTaskCount(), 0)
        }

        func testBoundedWaitResumesOnInitializationAndCancelsTimeout() async throws {
            let manager = makeManager()
            manager.test_resetInitializationForWaiting()
            let waitTask = Task { @MainActor in
                try await manager.awaitInitialized(timeout: .seconds(30))
            }
            await waitUntilRegistered(manager: manager)

            manager.test_completeInitializationForWaiting()
            try await waitTask.value

            await pollUntilOrFail(
                { manager.test_activeInitializationTimeoutTaskCount() == 0 },
                "Initialization success did not cancel and drain its timeout task"
            )
            XCTAssertTrue(manager.isInitialized)
            XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
        }

        func testBoundedWaitTimeoutReportsElapsedAndOwnerState() async {
            let manager = makeManager()
            manager.test_resetInitializationForWaiting()

            do {
                try await manager.awaitInitialized(timeout: .milliseconds(1))
                XCTFail("Expected bounded initialization wait to time out")
            } catch let error as WorkspaceInitializationWaitError {
                guard case let .timedOut(elapsed, isInitialized, isSwitchingWorkspace) = error else {
                    return XCTFail("Expected the dedicated timedOut error")
                }
                XCTAssertGreaterThanOrEqual(elapsed, .zero)
                XCTAssertFalse(isInitialized)
                XCTAssertFalse(isSwitchingWorkspace)
                XCTAssertTrue(error.localizedDescription.contains("isInitialized=false"))
                XCTAssertTrue(error.localizedDescription.contains("isSwitchingWorkspace=false"))
            } catch {
                XCTFail("Expected WorkspaceInitializationWaitError, got \(error)")
            }

            XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
            XCTAssertEqual(manager.test_activeInitializationTimeoutTaskCount(), 0)
        }

        func testBoundedWaitCancellationThrowsAndDeregisters() async {
            let manager = makeManager()
            manager.test_resetInitializationForWaiting()
            let waitTask = Task { @MainActor in
                try await manager.awaitInitialized(timeout: .seconds(30))
            }
            await waitUntilRegistered(manager: manager)

            waitTask.cancel()
            do {
                try await waitTask.value
                XCTFail("Expected cancelled initialization wait to throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }

            await pollUntilOrFail(
                { manager.test_activeInitializationTimeoutTaskCount() == 0 },
                "Cancellation did not cancel and drain the timeout task"
            )
            XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
        }

        func testSuccessTimeoutRaceResolvesEachWaiterExactlyOnce() async {
            let manager = makeManager()
            var successes = 0
            var timeouts = 0

            for _ in 0 ..< 100 {
                manager.test_resetInitializationForWaiting()
                let waitTask = Task { @MainActor in
                    try await manager.awaitInitialized(timeout: .milliseconds(1))
                }
                let completionTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1))
                    manager.test_completeInitializationForWaiting()
                }

                let result = await waitTask.result
                await completionTask.value

                switch result {
                case .success:
                    successes += 1
                case let .failure(error as WorkspaceInitializationWaitError):
                    guard case .timedOut = error else {
                        XCTFail("Expected timedOut race failure")
                        continue
                    }
                    timeouts += 1
                case let .failure(error):
                    XCTFail("Unexpected race result: \(error)")
                }

                await pollUntilOrFail(
                    { manager.test_activeInitializationTimeoutTaskCount() == 0 },
                    deadline: .seconds(1),
                    interval: .milliseconds(1),
                    "Race iteration left its timeout task active"
                )
                XCTAssertTrue(manager.isInitialized)
                XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
            }

            XCTAssertEqual(successes + timeouts, 100)
        }

        func testWaitRegisteredDuringSwitchResumesOnlyAfterSwitchCompletes() async throws {
            let manager = makeManager()
            manager.test_resetInitializationForWaiting()
            manager.test_beginWorkspaceSwitchForInitializationWaiting()
            let waitTask = Task { @MainActor in
                try await manager.awaitInitialized(timeout: .seconds(30))
            }
            await waitUntilRegistered(manager: manager)

            manager.test_completeInitializationForWaiting()
            await Task.yield()
            XCTAssertEqual(
                manager.test_initializationReadinessWaiterCount(),
                1,
                "Initialization alone must not resume a waiter while switching"
            )

            manager.test_endWorkspaceSwitchForInitializationWaiting()
            try await waitTask.value

            await pollUntilOrFail(
                { manager.test_activeInitializationTimeoutTaskCount() == 0 },
                "Switch completion did not cancel and drain the timeout task"
            )
            XCTAssertEqual(manager.test_initializationReadinessWaiterCount(), 0)
        }

        private func waitUntilRegistered(
            manager: WorkspaceManagerViewModel
        ) async {
            await pollUntilOrFail(
                { manager.test_initializationReadinessWaiterCount() == 1 },
                "Initialization waiter was not registered"
            )
        }

        private func makeManager() -> WorkspaceManagerViewModel {
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
                windowID: -1301,
                settingsManager: WindowSettingsManager(windowID: -1301)
            )
            return WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
        }
    }
#endif
