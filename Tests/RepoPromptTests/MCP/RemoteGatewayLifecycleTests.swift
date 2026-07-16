import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteGatewayLifecycleTests: XCTestCase {
    func testSerializedLifecycleCompletesRetirementBeforeReplacementAndIgnoresLateTermination() async throws {
        let fixture = try makeFixture()
        let recorder = LifecycleMutationRecorder()
        let terminationPause = LifecycleTerminationPause()
        let terminationObserver = LifecycleTerminationObserver()
        let lifecycle = RemoteGatewayProcessLifecycle(dependencies: .init(
            generateCredential: { recorder.nextCredential() },
            setCredential: { recorder.setCredential($0) },
            findOrphan: { _ in nil },
            launch: { configuration, credential, token, didTerminate in
                recorder.launch(
                    configuration: configuration,
                    credential: credential,
                    token: token,
                    didTerminate: didTerminate
                )
            },
            terminateOrphan: { recorder.recordOrphanTermination($0) },
            forceKill: { recorder.recordForceKill($0) },
            isProcessRunning: { recorder.isRunning(pid: $0) },
            removeLease: { recorder.recordLeaseRemoval(configuration: $0, pid: $1) },
            waitForTermination: { await terminationPause.pauseOnce() },
            now: { Date(timeIntervalSince1970: 1000) }
        ))
        let terminationHandler: @Sendable (RemoteGatewayProcessIdentity) -> Void = { identity in
            Task {
                let termination = await lifecycle.didTerminate(identity)
                await terminationObserver.record(termination)
            }
        }
        let firstConfiguration = launchConfiguration(ip: "100.64.0.8")
        let staleConfiguration = launchConfiguration(ip: "100.64.0.9")
        let selectedConfiguration = launchConfiguration(ip: "100.64.0.10")

        let firstGeneration = await fixture.gate.begin()
        await lifecycle.selectGeneration(firstGeneration)
        let firstIdentity = try await lifecycle.startIfNeeded(
            firstConfiguration,
            generation: firstGeneration,
            didTerminate: terminationHandler
        )

        let staleGeneration = await fixture.gate.begin()
        await lifecycle.selectGeneration(staleGeneration)
        let staleStart = Task {
            try await lifecycle.startIfNeeded(
                staleConfiguration,
                generation: staleGeneration,
                didTerminate: terminationHandler
            )
        }
        await terminationPause.waitUntilPaused()

        let selectedGeneration = await fixture.gate.begin()
        await lifecycle.selectGeneration(selectedGeneration)
        let selectedStart = Task {
            try await lifecycle.startIfNeeded(
                selectedConfiguration,
                generation: selectedGeneration,
                didTerminate: terminationHandler
            )
        }
        await terminationPause.resume()

        do {
            _ = try await staleStart.value
            XCTFail("Expected stale lifecycle start to be rejected")
        } catch {
            XCTAssertEqual(error as? RemoteGatewayProcessLifecycle.LifecycleError, .staleGeneration)
        }
        let selectedIdentity = try await selectedStart.value
        let selectedAuthority = try configuration(launchID: UUID(), ip: "100.64.0.10")
        try await fixture.gate.activate(
            selectedAuthority,
            generation: selectedGeneration,
            processIsCurrent: {
                await lifecycle.isCurrent(
                    selectedIdentity,
                    configuration: selectedConfiguration,
                    generation: selectedGeneration
                )
            }
        )

        recorder.finishAndNotifyTermination(firstIdentity)
        await terminationObserver.waitUntilRecorded()
        let lateTermination = await terminationObserver.recordedTermination()
        XCTAssertNil(lateTermination)

        let snapshot = await lifecycle.snapshotForTesting()
        XCTAssertEqual(snapshot.processIdentity, selectedIdentity)
        XCTAssertEqual(snapshot.processConfiguration, selectedConfiguration)
        XCTAssertEqual(snapshot.processGeneration, selectedGeneration)
        XCTAssertEqual(snapshot.credentialGeneration, selectedGeneration)
        XCTAssertEqual(recorder.launchedConfigurations, [firstConfiguration, selectedConfiguration])
        XCTAssertEqual(recorder.credentials.count, 3)
        XCTAssertNotNil(recorder.credentials[0])
        XCTAssertNil(recorder.credentials[1])
        XCTAssertNotNil(recorder.credentials[2])
        XCTAssertEqual(recorder.forceKilledPIDs, [firstIdentity.pid])
        XCTAssertEqual(
            recorder.removedLeases,
            [.init(configuration: firstConfiguration, pid: firstIdentity.pid)]
        )
        XCTAssertEqual(
            recorder.lifecycleEvents,
            [
                .launched(configuration: firstConfiguration, pid: firstIdentity.pid),
                .forceKilled(pid: firstIdentity.pid),
                .leaseRemoved(configuration: firstConfiguration, pid: firstIdentity.pid),
                .launched(configuration: selectedConfiguration, pid: selectedIdentity.pid)
            ]
        )
        let active = await fixture.authority.activeConfiguration()
        XCTAssertEqual(active, selectedAuthority)
    }

    func testFailedReadinessLeavesAuthorityUnpublished() async throws {
        let fixture = try makeFixture()
        _ = await fixture.gate.begin()

        let active = await fixture.authority.activeConfiguration()
        XCTAssertNil(active)
    }

    func testLateResolutionAfterDisableAndOverlappingRefreshCannotActivateStaleGeneration() async throws {
        let fixture = try makeFixture()
        let staleGeneration = await fixture.gate.begin()
        await fixture.gate.invalidate()

        await assertGateError(.staleGeneration) {
            try await fixture.gate.activate(
                self.configuration(launchID: UUID(), ip: "100.64.0.8"),
                generation: staleGeneration,
                processIsCurrent: { true }
            )
        }
        let activeAfterDisable = await fixture.authority.activeConfiguration()
        XCTAssertNil(activeAfterDisable)

        let firstRefresh = await fixture.gate.begin()
        let selectedRefresh = await fixture.gate.begin()
        await assertGateError(.staleGeneration) {
            try await fixture.gate.activate(
                self.configuration(launchID: UUID(), ip: "100.64.0.8"),
                generation: firstRefresh,
                processIsCurrent: { true }
            )
        }

        let selected = try configuration(launchID: UUID(), ip: "100.64.0.9")
        try await fixture.gate.activate(
            selected,
            generation: selectedRefresh,
            processIsCurrent: { true }
        )
        let active = await fixture.authority.activeConfiguration()
        XCTAssertEqual(active, selected)
    }

    func testFailedProcessIdentityDoesNotPublishAuthority() async throws {
        let fixture = try makeFixture()
        let generation = await fixture.gate.begin()

        await assertGateError(.processNotCurrent) {
            try await fixture.gate.activate(
                self.configuration(launchID: UUID(), ip: "100.64.0.8"),
                generation: generation,
                processIsCurrent: { false }
            )
        }

        let active = await fixture.authority.activeConfiguration()
        XCTAssertNil(active)
    }

    func testStaleTerminationCannotClearNewerActivationButCurrentTerminationDoes() async throws {
        let fixture = try makeFixture()
        let staleGeneration = await fixture.gate.begin()
        let currentGeneration = await fixture.gate.begin()
        let current = try configuration(launchID: UUID(), ip: "100.64.0.9")
        try await fixture.gate.activate(
            current,
            generation: currentGeneration,
            processIsCurrent: { true }
        )

        await fixture.gate.invalidate(ifGeneration: staleGeneration)
        let activeAfterStaleTermination = await fixture.authority.activeConfiguration()
        XCTAssertEqual(activeAfterStaleTermination, current)

        await fixture.gate.invalidate(ifGeneration: currentGeneration)
        let active = await fixture.authority.activeConfiguration()
        XCTAssertNil(active)
    }

    private func makeFixture() throws -> Fixture {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let identityStore = RemotePairingIdentityStore(
            url: RemotePairingTestSupport.registryURL(in: directory),
            keychain: keychain
        )
        let authority = RemotePairingDiscoveryAuthority(identityStore: identityStore)
        return Fixture(
            authority: authority,
            gate: RemoteGatewayActivationGate(authority: authority)
        )
    }

    private func configuration(
        launchID: UUID,
        ip: String
    ) throws -> RemotePairingDiscoveryAuthority.Configuration {
        try .init(
            launchID: launchID,
            origin: RemoteGatewayOrigin(tailscaleIPv4: ip, channel: .release),
            buildIdentity: .forTesting(channel: .release),
            hostName: "Lifecycle Test Host"
        )
    }

    private func launchConfiguration(ip: String) -> RemoteGatewayLaunchConfiguration {
        .init(bindHost: ip, port: 44100, appSupportRoot: "/tmp/remote-gateway-lifecycle-tests")
    }

    private func assertGateError(
        _ expected: RemoteGatewayActivationGate.GateError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RemoteGatewayActivationGate.GateError, expected)
        }
    }

    private struct Fixture {
        let authority: RemotePairingDiscoveryAuthority
        let gate: RemoteGatewayActivationGate
    }
}

private actor LifecycleTerminationObserver {
    private var hasRecorded = false
    private var termination: RemoteGatewayProcessLifecycle.Termination?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ termination: RemoteGatewayProcessLifecycle.Termination?) {
        hasRecorded = true
        self.termination = termination
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilRecorded() async {
        guard !hasRecorded else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func recordedTermination() -> RemoteGatewayProcessLifecycle.Termination? {
        termination
    }
}

private actor LifecycleTerminationPause {
    private var shouldPause = true
    private var paused = false
    private var resumed = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseOnce() async {
        guard shouldPause else { return }
        shouldPause = false
        paused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !resumed else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumed = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

private final class LifecycleMutationRecorder: @unchecked Sendable {
    enum LifecycleEvent: Equatable {
        case launched(configuration: RemoteGatewayLaunchConfiguration, pid: Int32)
        case forceKilled(pid: Int32)
        case leaseRemoved(configuration: RemoteGatewayLaunchConfiguration, pid: Int32)
    }

    struct RemovedLease: Equatable {
        let configuration: RemoteGatewayLaunchConfiguration
        let pid: Int32
    }

    private let lock = NSLock()
    private var credentialCounter = 0
    private var nextPID: Int32 = 7000
    private var processes: [RemoteGatewayProcessIdentity: LifecycleFakeProcess] = [:]
    private var callbacks: [RemoteGatewayProcessIdentity: @Sendable (RemoteGatewayProcessIdentity) -> Void] = [:]
    private var storedCredentials: [String?] = []
    private var storedConfigurations: [RemoteGatewayLaunchConfiguration] = []
    private var storedForceKilledPIDs: [Int32] = []
    private var storedRemovedLeases: [RemovedLease] = []
    private var storedLifecycleEvents: [LifecycleEvent] = []

    var credentials: [String?] {
        withLock { storedCredentials }
    }

    var launchedConfigurations: [RemoteGatewayLaunchConfiguration] {
        withLock { storedConfigurations }
    }

    var forceKilledPIDs: [Int32] {
        withLock { storedForceKilledPIDs }
    }

    var removedLeases: [RemovedLease] {
        withLock { storedRemovedLeases }
    }

    var lifecycleEvents: [LifecycleEvent] {
        withLock { storedLifecycleEvents }
    }

    func nextCredential() -> String {
        withLock {
            credentialCounter += 1
            return "credential-\(credentialCounter)"
        }
    }

    func setCredential(_ credential: String?) {
        withLock { storedCredentials.append(credential) }
    }

    func launch(
        configuration: RemoteGatewayLaunchConfiguration,
        credential _: String,
        token: UUID,
        didTerminate: @escaping @Sendable (RemoteGatewayProcessIdentity) -> Void
    ) -> RemoteGatewayProcessHandle {
        withLock {
            nextPID += 1
            let identity = RemoteGatewayProcessIdentity(token: token, pid: nextPID)
            let process = LifecycleFakeProcess()
            processes[identity] = process
            callbacks[identity] = didTerminate
            storedConfigurations.append(configuration)
            storedLifecycleEvents.append(.launched(configuration: configuration, pid: identity.pid))
            return RemoteGatewayProcessHandle(
                identity: identity,
                isRunning: { process.isRunning },
                terminate: { process.recordTerminationRequest() }
            )
        }
    }

    func isRunning(pid: Int32) -> Bool {
        withLock { processes.first(where: { $0.key.pid == pid })?.value.isRunning == true }
    }

    func recordOrphanTermination(_: Int32) {}

    func recordForceKill(_ pid: Int32) {
        withLock {
            storedForceKilledPIDs.append(pid)
            storedLifecycleEvents.append(.forceKilled(pid: pid))
            processes.first(where: { $0.key.pid == pid })?.value.finish()
        }
    }

    func recordLeaseRemoval(configuration: RemoteGatewayLaunchConfiguration, pid: Int32) {
        withLock {
            storedRemovedLeases.append(.init(configuration: configuration, pid: pid))
            storedLifecycleEvents.append(.leaseRemoved(configuration: configuration, pid: pid))
        }
    }

    func finishAndNotifyTermination(_ identity: RemoteGatewayProcessIdentity) {
        let callback: (@Sendable (RemoteGatewayProcessIdentity) -> Void)? = withLock {
            processes[identity]?.finish()
            return callbacks[identity]
        }
        callback?(identity)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class LifecycleFakeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func recordTerminationRequest() {}

    func finish() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
