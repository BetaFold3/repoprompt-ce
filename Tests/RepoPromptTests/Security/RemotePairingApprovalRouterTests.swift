import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class RemotePairingApprovalRouterTests: XCTestCase {
    private let windowStates = WindowStatesManager.shared

    override func setUp() {
        super.setUp()
        windowStates.allWindows = []
    }

    override func tearDown() {
        windowStates.allWindows = []
        super.tearDown()
    }

    func testZeroWindowsIsUnavailableAndManyWindowsIsAmbiguous() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let router = RemotePairingApprovalRouter(windowStates: windowStates, approvalManager: manager)

        await assertRouterError(.approvalWindowUnavailable) {
            try await self.requestApproval(router)
        }

        let first = makeWindow()
        let second = makeWindow()
        windowStates.allWindows = [first, second]
        await assertRouterError(.approvalWindowAmbiguous) {
            try await self.requestApproval(router)
        }
        first.beginClose()
        second.beginClose()
        await first.tearDown()
        await second.tearDown()
    }

    func testOneWindowRoutesApprovalAndPreservesDenial() async throws {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let router = RemotePairingApprovalRouter(windowStates: windowStates, approvalManager: manager)
        let window = makeWindow()
        windowStates.allWindows = [window]

        let approvedTask = Task { @MainActor in try await self.requestApproval(router) }
        await waitUntil { manager.pendingRequest?.windowID == window.windowID }
        manager.resolveApproval(allow: true, grantedScopes: [.sessionsObserve])
        let approved = try await approvedTask.value
        XCTAssertEqual(approved, [.sessionsObserve])

        let deniedTask = Task { @MainActor in try await self.requestApproval(router) }
        await waitUntil { manager.pendingRequest?.windowID == window.windowID }
        manager.resolveApproval(allow: false)
        let denied = try await deniedTask.value
        XCTAssertNil(denied)

        window.beginClose()
        await window.tearDown()
    }

    func testTargetCloseAndCancellationRemainDistinct() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let router = RemotePairingApprovalRouter(windowStates: windowStates, approvalManager: manager)
        let window = makeWindow()
        windowStates.allWindows = [window]

        let staleTask = Task { @MainActor in try await self.requestApproval(router) }
        await waitUntil { manager.pendingRequest?.windowID == window.windowID }
        manager.cancelPending(forWindowID: window.windowID)
        await assertTaskError(staleTask, expected: .approvalTargetStale)

        let cancelledTask = Task { @MainActor in try await self.requestApproval(router) }
        await waitUntil { manager.pendingRequest?.windowID == window.windowID }
        cancelledTask.cancel()
        await assertTaskError(cancelledTask, expected: .cancelled)

        window.beginClose()
        await window.tearDown()
    }

    private func requestApproval(_ router: RemotePairingApprovalRouter) async throws -> Set<RemoteScope>? {
        try await router.requestApproval(
            deviceID: "remote:test",
            displayName: "Test Device",
            devicePublicKeyFingerprint: "sha256:\(String(repeating: "a", count: 64))",
            requestedScopes: [.sessionsObserve, .interactionsRespond],
            hostFingerprint: "sha256:\(String(repeating: "b", count: 64))"
        )
    }

    private func makeWindow() -> WindowState {
        let previous = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previous, commit: false) }
        return WindowState()
    }

    private func assertRouterError(
        _ expected: RemotePairingApprovalRouterError,
        operation: () async throws -> Set<RemoteScope>?
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RemotePairingApprovalRouterError, expected)
        }
    }

    private func assertTaskError(
        _ task: Task<Set<RemoteScope>?, Error>,
        expected: RemotePairingApprovalRouterError
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RemotePairingApprovalRouterError, expected)
        }
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }
}
