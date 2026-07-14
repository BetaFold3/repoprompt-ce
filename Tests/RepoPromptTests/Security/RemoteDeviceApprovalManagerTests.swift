import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class RemoteDeviceApprovalManagerTests: XCTestCase {
    func testQueueOrderingApproveAndDeny() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let first = makeRequest(deviceID: "remote:aaaa1111")
        let second = makeRequest(deviceID: "remote:bbbb2222")

        let firstTask = Task { @MainActor in
            await manager.requestApproval(for: first)
        }
        await waitUntil { manager.pendingRequest?.id == first.id }

        let secondTask = Task { @MainActor in
            await manager.requestApproval(for: second)
        }
        await waitUntil { manager.pendingQueueCountForTesting == 1 }

        manager.resolveApproval(allow: true, grantedScopes: [.sessionsObserve])
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, .approved(grantedScopes: [.sessionsObserve]))

        await waitUntil { manager.pendingRequest?.id == second.id }
        manager.resolveApproval(allow: false)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, .denied)
        XCTAssertFalse(manager.isApprovalOverlayVisible)
        XCTAssertNil(manager.pendingRequest)
    }

    func testCancellingActiveApprovalResolvesCancelledAndClearsOverlay() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let request = makeRequest(deviceID: "remote:cccc3333")

        let task = Task { @MainActor in
            await manager.requestApproval(for: request)
        }
        await waitUntil { manager.pendingRequest?.id == request.id }

        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        await waitUntil { manager.pendingRequest == nil }
        XCTAssertFalse(manager.isApprovalOverlayVisible)
    }

    func testCancellingQueuedApprovalLeavesActivePending() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let active = makeRequest(deviceID: "remote:dddd4444")
        let queued = makeRequest(deviceID: "remote:eeee5555")

        let activeTask = Task { @MainActor in
            await manager.requestApproval(for: active)
        }
        await waitUntil { manager.pendingRequest?.id == active.id }

        let queuedTask = Task { @MainActor in
            await manager.requestApproval(for: queued)
        }
        await waitUntil { manager.pendingQueueCountForTesting == 1 }

        queuedTask.cancel()
        let queuedResult = await queuedTask.value
        XCTAssertEqual(queuedResult, .cancelled)
        XCTAssertEqual(manager.pendingRequest?.id, active.id)
        XCTAssertTrue(manager.isApprovalOverlayVisible)

        manager.resolveApproval(allow: true)
        let activeResult = await activeTask.value
        XCTAssertEqual(activeResult, .approved(grantedScopes: active.requestedScopes))
    }

    func testClosingTargetWindowResolvesTargetStale() async {
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let request = makeRequest(deviceID: "remote:ffff6666", windowID: 42)
        let task = Task { @MainActor in await manager.requestApproval(for: request) }
        await waitUntil { manager.pendingRequest?.id == request.id }

        manager.cancelPending(forWindowID: 42)

        let result = await task.value
        XCTAssertEqual(result, .targetStale)
        XCTAssertNil(manager.pendingRequest)
    }

    private func makeRequest(deviceID: String, windowID: Int? = nil) -> RemoteDeviceApprovalRequest {
        RemoteDeviceApprovalRequest(
            deviceID: deviceID,
            displayName: "Device \(deviceID.suffix(4))",
            devicePublicKeyFingerprint: "sha256:\(String(repeating: "a", count: 64))",
            requestedScopes: [.sessionsObserve, .interactionsRespond],
            hostFingerprint: "sha256:\(String(repeating: "b", count: 64))",
            windowID: windowID
        )
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
