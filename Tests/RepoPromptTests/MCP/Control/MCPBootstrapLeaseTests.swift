import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPBootstrapLeaseTests: XCTestCase {
    func testPIDOwnedSameClientLeasesReleaseBootstrapGateBeforeEitherRoutes() async throws {
        #if DEBUG
            let firstRunID = UUID()
            let secondRunID = UUID()
            let firstGateID = UUID()
            let secondGateID = UUID()
            let clientName = "bootstrap-lease-parallel-same-client"
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: firstRunID)
            await MCPRoutingWaiter.cleanup(runID: secondRunID)
            await ServerNetworkManager.shared.debugClearRunRoutingHistoryForTesting()

            func makeLease(runID: UUID, gateID: UUID, tabID: UUID) -> MCPBootstrapLease {
                MCPBootstrapLease(
                    spec: MCPBootstrapLeaseSpec(
                        runID: runID,
                        gateID: gateID,
                        windowID: 1,
                        tabID: tabID,
                        clientName: clientName,
                        restrictedTools: [],
                        additionalTools: nil,
                        oneShot: true,
                        reason: "parallel PID-owned bootstrap regression",
                        ttl: 10,
                        purpose: .agentModeRun,
                        taskLabelKind: nil,
                        allowsAgentExternalControlTools: false,
                        requiresExpectedAgentPID: true
                    ),
                    policyInstaller: { _ in await recorder.recordInstall() },
                    expectedPIDPolicyArmer: { _ in await recorder.recordArm() },
                    policyClearer: { _ in await recorder.recordClear() }
                )
            }

            let firstLease = makeLease(runID: firstRunID, gateID: firstGateID, tabID: UUID())
            let secondLease = makeLease(runID: secondRunID, gateID: secondGateID, tabID: UUID())
            let firstAcquired = await firstLease.acquire()
            let activeGateAfterFirstAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(firstAcquired)
            XCTAssertNil(activeGateAfterFirstAcquire)

            let secondCompleted = expectation(description: "second same-client PID-owned lease acquires before first routes")
            let secondAcquisition = Task {
                let acquired = await secondLease.acquire()
                secondCompleted.fulfill()
                return acquired
            }
            await fulfillment(of: [secondCompleted], timeout: 1)
            let secondAcquired = await secondAcquisition.value

            let installCount = await recorder.installCount
            let armCount = await recorder.armCount
            let activeGateAfterSecondAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(secondAcquired)
            XCTAssertEqual(installCount, 2)
            XCTAssertEqual(armCount, 2)
            XCTAssertNil(activeGateAfterSecondAcquire)

            await firstLease.providerInitializationStarted(provider: "test-provider")
            await firstLease.providerInitializationCompleted(provider: "test-provider", outcome: "ready")
            let firstHistory = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(
                runID: firstRunID,
                limit: 50
            )
            let firstEvents = try XCTUnwrap(firstHistory["events"] as? [[String: Any]])
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "lease_gate_wait_started" })
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "lease_gate_acquired" })
            XCTAssertTrue(firstEvents.contains { $0["event"] as? String == "provider_initialization_started" })
            let providerCompleted = try XCTUnwrap(firstEvents.first { $0["event"] as? String == "provider_initialization_completed" })
            let providerFields = try XCTUnwrap(providerCompleted["fields"] as? [String: String])
            XCTAssertEqual(providerFields["provider"], "test-provider")
            XCTAssertEqual(providerFields["outcome"], "ready")
            let earlyRelease = try XCTUnwrap(firstEvents.first { $0["event"] as? String == "lease_gate_release" })
            let releaseFields = try XCTUnwrap(earlyRelease["fields"] as? [String: String])
            XCTAssertEqual(releaseFields["reason"], "expected_pid_policy_armed")
            XCTAssertEqual(releaseFields["released"], "true")
            XCTAssertNotNil(releaseFields["queue_depth_before_release"])

            await firstLease.cancelAndCleanup()
            await secondLease.cancelAndCleanup()
            let clearCount = await recorder.clearCount
            let firstWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: firstRunID)
            let secondWaiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: secondRunID)
            let activeGateAfterCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(clearCount, 2)
            XCTAssertEqual(firstWaiterCount, 0)
            XCTAssertEqual(secondWaiterCount, 0)
            XCTAssertNil(activeGateAfterCleanup)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testPIDOwnedEarlyReleaseCleanupRemovesRetainedPolicyForEveryExit() async throws {
        #if DEBUG
            enum ExitMode: String, CaseIterable {
                case timeout
                case cancellation
                case failure
            }

            let manager = ServerNetworkManager.shared
            await HeadlessAgentConnectionGate.cancelAll()

            for mode in ExitMode.allCases {
                let runID = UUID()
                let gateID = UUID()
                let clientName = "bootstrap-lease-early-release-\(mode.rawValue)-\(runID.uuidString)"
                let lease = MCPBootstrapLease(
                    spec: MCPBootstrapLeaseSpec(
                        runID: runID,
                        gateID: gateID,
                        windowID: 1,
                        tabID: UUID(),
                        clientName: clientName,
                        restrictedTools: [],
                        additionalTools: nil,
                        oneShot: true,
                        reason: "early release \(mode.rawValue) cleanup regression",
                        ttl: 10,
                        purpose: .agentModeRun,
                        taskLabelKind: nil,
                        allowsAgentExternalControlTools: false,
                        requiresExpectedAgentPID: true
                    )
                )

                await MCPRoutingWaiter.cleanup(runID: runID)
                let acquired = await lease.acquire()
                let activeGateAfterAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                let pendingBeforeExit = await manager.debugPendingPolicySnapshot(for: clientName)
                XCTAssertTrue(acquired, mode.rawValue)
                XCTAssertNil(activeGateAfterAcquire, mode.rawValue)
                XCTAssertTrue(pendingBeforeExit.contains { $0.runID == runID }, mode.rawValue)

                switch mode {
                case .timeout:
                    let routed = await lease.releaseWhenRouted(timeoutMs: 10)
                    XCTAssertFalse(routed)
                case .cancellation:
                    await lease.cancelAndCleanup()
                case .failure:
                    await lease.failAndRelease()
                }

                let pendingAfterExit = await manager.debugPendingPolicySnapshot(for: clientName)
                let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
                let activeGateAfterExit = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                XCTAssertFalse(pendingAfterExit.contains { $0.runID == runID }, mode.rawValue)
                XCTAssertEqual(waiterCount, 0, mode.rawValue)
                XCTAssertNil(activeGateAfterExit, mode.rawValue)
                await manager.cleanupRunRoutingState(for: runID, windowID: 1)
                await MCPRoutingWaiter.cleanup(runID: runID)
            }
        #else
            throw XCTSkip("PID-owned policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testTerminalRevocationRemainsIdempotentAfterSuccessfulRoutePolicyClear() async throws {
        #if DEBUG
            let runID = UUID()
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-post-successful-clear-failure-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "post-route terminal failure cleanup regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                successfulRoutingPolicyClearer: { _ in await recorder.recordSuccessfulRoutingClear() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)

            let release = Task { await lease.releaseWhenRouted(timeoutMs: 1000) }
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let routed = await release.value
            let successfulClearCountAfterRoute = await recorder.successfulRoutingClearCount
            let revokingClearCountAfterRoute = await recorder.clearCount
            let routedSnapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(routed)
            XCTAssertEqual(successfulClearCountAfterRoute, 0)
            XCTAssertEqual(revokingClearCountAfterRoute, 0)
            XCTAssertTrue(routedSnapshot.didCleanupRouting)
            XCTAssertFalse(routedSnapshot.didClearPolicy)
            XCTAssertFalse(routedSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertFalse(routedSnapshot.didRevokePolicy)
            XCTAssertEqual(routedSnapshot.routingCleanupCount, 1)

            await lease.clearPolicyAfterSuccessfulRouting()
            let successfulClearCount = await recorder.successfulRoutingClearCount
            let revokingClearCountBeforeFailure = await recorder.clearCount
            let successfulClearSnapshot = await lease.debugCleanupSnapshot()
            XCTAssertEqual(successfulClearCount, 1)
            XCTAssertEqual(revokingClearCountBeforeFailure, 0)
            XCTAssertTrue(successfulClearSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertFalse(successfulClearSnapshot.didRevokePolicy)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            XCTAssertTrue(didAcquireProbe)

            await lease.failAndRelease()
            let clearCountAfterFailure = await recorder.clearCount
            let failedSnapshot = await lease.debugCleanupSnapshot()
            let activeGateAfterFailure = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(clearCountAfterFailure, 1)
            XCTAssertTrue(failedSnapshot.didCleanupRouting)
            XCTAssertTrue(failedSnapshot.didClearPolicy)
            XCTAssertTrue(failedSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertTrue(failedSnapshot.didRevokePolicy)
            XCTAssertEqual(failedSnapshot.routingCleanupCount, 1)
            XCTAssertEqual(failedSnapshot.terminalCleanupRequestCount, 1)
            XCTAssertEqual(failedSnapshot.terminalCleanupRawRequestCount, 1)
            XCTAssertEqual(activeGateAfterFailure, probeGateID)

            await lease.failAndRelease()
            let clearCountAfterRepeat = await recorder.clearCount
            let repeatedSnapshot = await lease.debugCleanupSnapshot()
            let activeGateAfterRepeat = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            let successfulClearCountAfterRepeat = await recorder.successfulRoutingClearCount
            XCTAssertEqual(successfulClearCountAfterRepeat, 1)
            XCTAssertEqual(clearCountAfterRepeat, 1)
            XCTAssertTrue(repeatedSnapshot.didCleanupRouting)
            XCTAssertTrue(repeatedSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertTrue(repeatedSnapshot.didRevokePolicy)
            XCTAssertEqual(repeatedSnapshot.routingCleanupCount, 1)
            XCTAssertEqual(repeatedSnapshot.terminalCleanupRequestCount, 1)
            XCTAssertEqual(repeatedSnapshot.terminalCleanupRawRequestCount, 2)
            XCTAssertEqual(activeGateAfterRepeat, probeGateID)

            await HeadlessAgentConnectionGate.completeConnection(probeGateID)
            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            let waitingGateCount = await HeadlessAgentConnectionGate.shared.debugWaitingCount()
            let activeGateAfterCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(waiterCount, 0)
            XCTAssertEqual(waitingGateCount, 0)
            XCTAssertNil(activeGateAfterCleanup)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuccessfulRoutePolicyClearIsIdempotentAndPreservesRoutingAndUnrelatedGate() async throws {
        #if DEBUG
            let runID = UUID()
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-successful-route-policy-clear",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "successful routed completion policy clear regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                successfulRoutingPolicyClearer: { _ in await recorder.recordSuccessfulRoutingClear() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            let release = Task { await lease.releaseWhenRouted(timeoutMs: 1000) }
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let routed = await release.value
            XCTAssertTrue(routed)

            await MCPRoutingWaiter.register(runID: runID)
            let retainedRoutingWait = Task {
                await MCPRoutingWaiter.waitUntilRouted(runID: runID, timeoutSeconds: 0)
            }
            for _ in 0 ..< 100 {
                if await MCPRoutingWaiter.debugContinuationCount(runID: runID) == 1 {
                    break
                }
                await Task.yield()
            }
            let retainedWaiterCountBeforeClear = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(retainedWaiterCountBeforeClear, 1)

            let acquiredProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            XCTAssertTrue(acquiredProbe)
            await lease.clearPolicyAfterSuccessfulRouting()
            await lease.clearPolicyAfterSuccessfulRouting()

            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertTrue(snapshot.didRouteSuccessfully)
            XCTAssertTrue(snapshot.didCleanupRouting)
            XCTAssertTrue(snapshot.didClearPolicy)
            XCTAssertTrue(snapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertFalse(snapshot.didRevokePolicy)
            let successfulRoutingClearCount = await recorder.successfulRoutingClearCount
            let revokingClearCount = await recorder.clearCount
            let retainedWaiterCountAfterClear = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            let activeGateAfterClear = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(successfulRoutingClearCount, 1)
            XCTAssertEqual(revokingClearCount, 0)
            XCTAssertEqual(retainedWaiterCountAfterClear, 1)
            XCTAssertEqual(activeGateAfterClear, probeGateID)

            await MCPRoutingWaiter.cleanup(runID: runID)
            let retainedRoutingResult = await retainedRoutingWait.value
            XCTAssertFalse(retainedRoutingResult)
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuccessfulRouteDefaultPolicyClearerClearsPendingPolicyWithoutRevocation() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let runID = UUID()
            let clientName = "bootstrap-lease-default-successful-route-clear-\(runID.uuidString)"

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)
            await manager.debugClearRunRoutingHistoryForTesting()

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    clientName: clientName,
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "default successful routed policy clear regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                )
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            let release = Task { await lease.releaseWhenRouted(timeoutMs: 1000) }
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let routed = await release.value
            XCTAssertTrue(routed)

            let pendingBeforeClear = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(pendingBeforeClear.contains { $0.runID == runID })

            await lease.clearPolicyAfterSuccessfulRouting()
            await lease.clearPolicyAfterSuccessfulRouting()

            let pendingAfterClear = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertFalse(pendingAfterClear.contains { $0.runID == runID })
            let history = await manager.debugRunRoutingHistoryPayload(runID: runID, limit: 100)
            let events = try XCTUnwrap(history["events"] as? [[String: Any]])
            let eventNames = events.compactMap { $0["event"] as? String }
            XCTAssertEqual(eventNames.count(where: { $0 == "policy_cleared" }), 1)
            XCTAssertFalse(eventNames.contains("policy_revoked"))
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Default policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuccessfulRoutePolicyClearAfterTerminalRevocationIsNoOp() async throws {
        #if DEBUG
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-terminal-revoke-before-successful-clear",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "terminal revoke before successful clear regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                successfulRoutingPolicyClearer: { _ in await recorder.recordSuccessfulRoutingClear() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            let release = Task { await lease.releaseWhenRouted(timeoutMs: 1000) }
            await MCPRoutingWaiter.notifyRouted(runID: runID)
            let routed = await release.value
            XCTAssertTrue(routed)

            await lease.failAndRelease()
            await lease.clearPolicyAfterSuccessfulRouting()
            await lease.clearPolicyAfterSuccessfulRouting()

            let successfulClearCount = await recorder.successfulRoutingClearCount
            let revokingClearCount = await recorder.clearCount
            let snapshot = await lease.debugCleanupSnapshot()
            XCTAssertEqual(successfulClearCount, 0)
            XCTAssertEqual(revokingClearCount, 1)
            XCTAssertFalse(snapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertTrue(snapshot.didRevokePolicy)
            XCTAssertEqual(snapshot.terminalCleanupRequestCount, 1)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testSuccessfulRoutePolicyClearIsNoOpBeforeAcquireAndAfterNoRoute() async throws {
        #if DEBUG
            let preRouteRecorder = PolicyRecorder()
            let preRouteLease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: UUID(),
                    gateID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-pre-route-policy-clear",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "pre-route policy clear no-op regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: true
                ),
                policyInstaller: { _ in await preRouteRecorder.recordInstall() },
                expectedPIDPolicyArmer: { _ in true },
                successfulRoutingPolicyClearer: { _ in await preRouteRecorder.recordSuccessfulRoutingClear() },
                policyClearer: { _ in await preRouteRecorder.recordClear() }
            )

            let preRouteAcquired = await preRouteLease.acquire()
            XCTAssertTrue(preRouteAcquired)
            await preRouteLease.clearPolicyAfterSuccessfulRouting()
            let preRouteSnapshot = await preRouteLease.debugCleanupSnapshot()
            XCTAssertFalse(preRouteSnapshot.didRouteSuccessfully)
            XCTAssertFalse(preRouteSnapshot.didCleanupRouting)
            XCTAssertFalse(preRouteSnapshot.didClearPolicy)
            XCTAssertFalse(preRouteSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertFalse(preRouteSnapshot.didRevokePolicy)
            let preRouteSuccessfulClearCount = await preRouteRecorder.successfulRoutingClearCount
            let preRouteRevokingClearCount = await preRouteRecorder.clearCount
            XCTAssertEqual(preRouteSuccessfulClearCount, 0)
            XCTAssertEqual(preRouteRevokingClearCount, 0)
            await preRouteLease.cancelAndCleanup()

            let noRouteRunID = UUID()
            let noRouteRecorder = PolicyRecorder()
            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: noRouteRunID)
            let noRouteLease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: noRouteRunID,
                    gateID: UUID(),
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-no-route-policy-clear",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "no-route policy clear no-op regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await noRouteRecorder.recordInstall() },
                successfulRoutingPolicyClearer: { _ in await noRouteRecorder.recordSuccessfulRoutingClear() },
                policyClearer: { _ in await noRouteRecorder.recordClear() }
            )

            let noRouteAcquired = await noRouteLease.acquire()
            XCTAssertTrue(noRouteAcquired)
            let routed = await noRouteLease.releaseWhenRouted(timeoutMs: 10)
            XCTAssertFalse(routed)
            await noRouteLease.clearPolicyAfterSuccessfulRouting()

            let noRouteSnapshot = await noRouteLease.debugCleanupSnapshot()
            XCTAssertFalse(noRouteSnapshot.didRouteSuccessfully)
            XCTAssertTrue(noRouteSnapshot.didCleanupRouting)
            XCTAssertTrue(noRouteSnapshot.didClearPolicy)
            XCTAssertFalse(noRouteSnapshot.didClearSuccessfulRoutingPolicy)
            XCTAssertTrue(noRouteSnapshot.didRevokePolicy)
            let noRouteSuccessfulClearCount = await noRouteRecorder.successfulRoutingClearCount
            let noRouteRevokingClearCount = await noRouteRecorder.clearCount
            XCTAssertEqual(noRouteSuccessfulClearCount, 0)
            XCTAssertEqual(noRouteRevokingClearCount, 1)
            await MCPRoutingWaiter.cleanup(runID: noRouteRunID)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testPIDOwnedAcquireFailsClosedWhenPolicyCannotBeArmed() async throws {
        #if DEBUG
            let runID = UUID()
            let gateID = UUID()
            let recorder = PolicyRecorder()
            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: gateID,
                    windowID: 1,
                    tabID: UUID(),
                    clientName: "bootstrap-lease-unarmed-policy",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "unarmed PID policy regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: true
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                expectedPIDPolicyArmer: { _ in false },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            let clearCount = await recorder.clearCount
            let waiterCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            let activeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertFalse(acquired)
            XCTAssertEqual(clearCount, 1)
            XCTAssertEqual(waiterCount, 0)
            XCTAssertNil(activeGate)
        #else
            throw XCTSkip("Bootstrap gate diagnostics require DEBUG helpers.")
        #endif
    }

    func testCleanupWhileQueuedReleasesGateOwnershipThatArrivesLater() async throws {
        #if DEBUG
            let blockerGateID = UUID()
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await HeadlessAgentConnectionGate.beginConnection(blockerGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-race-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "queued cleanup regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquisition = Task { await lease.acquire() }
            var queued = false
            let queueDeadline = Date().addingTimeInterval(2)
            repeat {
                queued = await HeadlessAgentConnectionGate.shared.debugWaitingCount() == 1
                if queued { break }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < queueDeadline
            let activeBeforeCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(queued, "Expected lease acquisition to queue behind blocker; active=\(String(describing: activeBeforeCleanup))")

            await lease.cancelAndCleanup()
            let activeBlockerID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(activeBlockerID, blockerGateID)

            await HeadlessAgentConnectionGate.completeConnection(blockerGateID)
            let didAcquireLease = await acquisition.value
            let installCount = await recorder.installCount
            XCTAssertFalse(didAcquireLease)
            XCTAssertEqual(installCount, 0)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            let activeProbeID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(didAcquireProbe)
            XCTAssertEqual(activeProbeID, probeGateID)

            await lease.failAndCleanup()
            let activeProbeAfterFailedAcquireCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(
                activeProbeAfterFailedAcquireCleanup,
                probeGateID,
                "Cleanup after a failed acquire must not release another holder"
            )
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Gate ownership inspection is DEBUG-only.")
        #endif
    }

    func testDeferredRoutingReleaseFreesGateAndTerminalCleanupClearsPolicy() async throws {
        #if DEBUG
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-deferred-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "deferred routing regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquired = await lease.acquire()
            XCTAssertTrue(acquired)
            let installCount = await recorder.installCount
            let activeGateAfterAcquire = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(installCount, 1)
            XCTAssertEqual(activeGateAfterAcquire, leaseGateID)

            await lease.releaseGateForDeferredRouting()
            let activeGateAfterDeferredRelease = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            let clearCountAfterDeferredRelease = await recorder.clearCount
            XCTAssertNil(activeGateAfterDeferredRelease)
            XCTAssertEqual(clearCountAfterDeferredRelease, 0)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            XCTAssertTrue(didAcquireProbe)
            let activeProbeGate = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(activeProbeGate, probeGateID)
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)

            await lease.cleanupDeferredRouting()
            let clearCountAfterCleanup = await recorder.clearCount
            let continuationCount = await MCPRoutingWaiter.debugContinuationCount(runID: runID)
            XCTAssertEqual(clearCountAfterCleanup, 1)
            XCTAssertEqual(continuationCount, 0)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Gate ownership inspection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testDeferredCursorRoutingAdvertisesOracleLogAfterPolicyAdmission() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let leaseGateID = UUID()
            let runID = UUID()
            let connectionID = UUID()
            let tabID = UUID()
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPBootstrapLeaseTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let sourceURL = rootURL.appendingPathComponent("CursorDeferredRouting.swift")
            try "let cursorDeferredRoutingToolGrant = true\n".write(to: sourceURL, atomically: true, encoding: .utf8)

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            try await window.workspaceManager.awaitInitialized(timeout: .seconds(60))

            let catalogService = window.mcpServer.windowMCPToolCatalogService
            var ownedRoutingService: WindowRoutingService?
            var lease: MCPBootstrapLease?
            var loadedRootID: UUID?

            func cleanup() async {
                if let lease {
                    await lease.cleanupDeferredRouting()
                }
                await manager.clearExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.cursorMCPClientID,
                    runID: runID
                )
                await manager.clearClientConnectionPolicy(
                    for: AgentProviderKind.cursorMCPClientID,
                    windowID: window.windowID,
                    runID: runID
                )
                await manager.removeConnection(connectionID)
                await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                await MCPRoutingWaiter.cleanup(runID: runID)
                await HeadlessAgentConnectionGate.cancelAll()
                ServiceRegistry.unregister(catalogService)
                if let ownedRoutingService {
                    ServiceRegistry.unregister(ownedRoutingService)
                }
                if let loadedRootID {
                    await window.workspaceFileContextStore.unloadRoot(id: loadedRootID)
                }
                WindowStatesManager.shared.unregisterWindowState(window)
                try? FileManager.default.removeItem(at: rootURL)
            }

            do {
                let workspace = window.workspaceManager.createWorkspace(
                    name: "Cursor Deferred Routing Tools \(UUID().uuidString.prefix(8))",
                    repoPaths: [rootURL.path],
                    ephemeral: true
                )
                await window.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "cursorDeferredRoutingToolGrantTest"
                )
                let workspaceIndex = try XCTUnwrap(
                    window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
                )
                window.workspaceManager.workspaces[workspaceIndex].composeTabs = [
                    ComposeTabState(id: tabID, name: "Cursor Deferred Routing")
                ]
                window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabID
                await window.workspaceManager.switchWorkspace(
                    to: window.workspaceManager.workspaces[workspaceIndex],
                    saveState: false,
                    reason: "cursorDeferredRoutingToolGrantTestTabs"
                )
                let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
                let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: rootURL.path)
                loadedRootID = loadedRoot.id

                ServiceRegistry.register(catalogService)
                let routing = try await Self.ensureRoutingService()
                ownedRoutingService = routing.owned ? routing.service : nil

                let cursorAdditionalTools = AgentModeMCPPolicyInstaller.additionalTools(for: .cursor)
                XCTAssertTrue(cursorAdditionalTools.contains(MCPWindowToolName.oracleChatLog))
                XCTAssertTrue(cursorAdditionalTools.contains(MCPWindowToolName.askOracle))

                let resolvedLease = MCPBootstrapLease(
                    spec: .agentMode(
                        tabID: tabID,
                        runID: runID,
                        gateID: leaseGateID,
                        windowID: window.windowID,
                        agent: .cursor
                    )
                )
                lease = resolvedLease

                await HeadlessAgentConnectionGate.cancelAll()
                await MCPRoutingWaiter.cleanup(runID: runID)
                let acquiredLease = await resolvedLease.acquire()
                XCTAssertTrue(acquiredLease)
                await manager.registerExpectedAgentPID(
                    getpid(),
                    for: AgentProviderKind.cursorMCPClientID,
                    runID: runID
                )

                let pendingPolicyBeforeDeferredRelease = await manager.debugRunPolicyState(for: runID)
                let runPolicyBeforeDeferredRelease = try XCTUnwrap(pendingPolicyBeforeDeferredRelease)
                XCTAssertEqual(runPolicyBeforeDeferredRelease.additionalTools, cursorAdditionalTools)

                await resolvedLease.releaseGateForDeferredRouting()
                let activeGateAfterDeferredRelease = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
                XCTAssertNil(activeGateAfterDeferredRelease)
                let pendingPolicyAfterDeferredRelease = await manager.debugRunPolicyState(for: runID)
                let runPolicyAfterDeferredRelease = try XCTUnwrap(pendingPolicyAfterDeferredRelease)
                XCTAssertEqual(runPolicyAfterDeferredRelease.additionalTools, cursorAdditionalTools)

                let appliedPolicy = await manager.debugApplyPendingPolicy(
                    clientName: AgentProviderKind.cursorMCPClientID,
                    connectionID: connectionID,
                    clientPid: Int(getpid()),
                    bootstrapClientName: AgentProviderKind.cursorMCPClientID,
                    sessionKey: "cursor-deferred-routing-tools",
                    pidGateTimeout: 0.25
                )
                XCTAssertEqual(appliedPolicy.outcome, "applied")
                XCTAssertEqual(appliedPolicy.runID, runID)
                XCTAssertEqual(appliedPolicy.additionalTools, cursorAdditionalTools)

                let advertisedTools = try await manager.debugListToolNames(for: connectionID)
                XCTAssertTrue(
                    advertisedTools.contains(MCPWindowToolName.oracleChatLog),
                    "Deferred Cursor routing must still advertise oracle_chat_log after policy admission. Tools: \(advertisedTools)"
                )
                XCTAssertTrue(
                    advertisedTools.contains(MCPWindowToolName.askOracle),
                    "Deferred Cursor routing must still advertise ask_oracle after policy admission. Tools: \(advertisedTools)"
                )

                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        #else
            throw XCTSkip("Connection policy and catalog diagnostics are DEBUG-only.")
        #endif
    }
}

private enum MCPBootstrapLeaseTestError: Error {
    case routingServiceUnavailable
}

private extension MCPBootstrapLeaseTests {
    @MainActor
    static func ensureRoutingService() async throws -> (service: WindowRoutingService, owned: Bool) {
        if let existing = ServiceRegistry.services.first(where: { $0 is WindowRoutingService }) as? WindowRoutingService {
            return (existing, false)
        }
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
        for _ in 0 ..< 100 {
            let registered = ServiceRegistry.services.contains { $0 as AnyObject === service as AnyObject }
            let names = await service.tools.map(\.name)
            if registered, names.contains("bind_context") {
                return (service, true)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        ServiceRegistry.unregister(service)
        throw MCPBootstrapLeaseTestError.routingServiceUnavailable
    }
}

private actor PolicyRecorder {
    private(set) var installCount = 0
    private(set) var armCount = 0
    private(set) var successfulRoutingClearCount = 0
    private(set) var clearCount = 0

    func recordInstall() {
        installCount += 1
    }

    func recordArm() -> Bool {
        armCount += 1
        return true
    }

    func recordSuccessfulRoutingClear() {
        successfulRoutingClearCount += 1
    }

    func recordClear() {
        clearCount += 1
    }
}
