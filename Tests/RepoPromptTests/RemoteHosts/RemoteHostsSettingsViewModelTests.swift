import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

@MainActor
final class RemoteHostsSettingsViewModelTests: XCTestCase {
    func testDiscoveryRequiresExplicitSelectionRevalidatesAndPersistsOnlyAfterPairing() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
        let pairingClient = SuspendedRemoteHostsPairingClient()
        let hostSigner = P256.Signing.PrivateKey()
        let origin = try RemoteGatewayOrigin(string: "http://100.64.0.8:47391")
        let candidate = Self.candidate(hostSigner: hostSigner, origin: origin)
        let payload = try RemotePairingPayload(
            gatewayOrigin: origin,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            hostName: "Studio",
            approvalContext: "fresh-context"
        )
        let discovery = StubRemoteHostsDiscovery(
            result: RemoteHostDiscoveryResult(
                hosts: [candidate],
                diagnostics: .init(candidateCount: 4, verifiedCount: 1, failedProbeCount: 3)
            ),
            payload: payload
        )
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: keyStore,
            pairingClient: pairingClient,
            discoveryService: discovery,
            clientDisplayName: { "Client MacBook" }
        )

        viewModel.findHosts()
        await waitForDiscovery(viewModel)

        XCTAssertEqual(viewModel.discoveredHosts, [candidate])
        XCTAssertEqual(viewModel.discoveryState, .results(.init(candidateCount: 4, verifiedCount: 1, failedProbeCount: 3)))
        XCTAssertFalse(registry.hasHosts)

        let pairTask = Task { await viewModel.requestAccess(to: candidate) }
        await waitForPairingRequest(pairingClient)

        XCTAssertEqual(viewModel.pairingState, .waitingForApproval(hostName: "Studio"))
        let request = try XCTUnwrap(pairingClient.requests.first)
        XCTAssertEqual(request.payload.gatewayOrigin, origin)
        XCTAssertEqual(request.payload.approvalContext, "fresh-context")
        XCTAssertEqual(request.displayName, "Client MacBook")
        XCTAssertEqual(request.scopes, RemoteHostPairingClient.defaultRequestedScopes)
        XCTAssertFalse(registry.hasHosts)

        let record = try Self.record(from: request.payload)
        pairingClient.complete(with: record)
        await pairTask.value

        XCTAssertEqual(viewModel.pairingState, .paired(hostName: "Studio"))
        XCTAssertEqual(viewModel.hostRows.map(\.id), [record.id])
        XCTAssertEqual(try registry.host(id: record.id)?.gatewayURL.absoluteString, origin.string)
        let revalidationCount = await discovery.revalidationCount()
        XCTAssertEqual(revalidationCount, 1)
    }

    func testForgetRemovesRegistryRecordAndClientKey() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keychain = InMemoryRemoteClientKeychain()
        let keyStore = RemoteClientKeyStore(
            keychain: keychain,
            accessMode: .nonInteractive(reason: .test)
        )
        let record = try RemoteHostTestSupport.hostRecord()
        try registry.upsertHost(record)
        try keyStore.save(P256.Signing.PrivateKey(), forHostID: record.id)
        let account = try RemoteClientKeyStore.account(forHostID: record.id)
        let connectionManager = RecordingRemoteHostsConnectionManager()
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: keyStore,
            pairingClient: ImmediateRemoteHostsPairingClient(),
            connectionManager: connectionManager
        )

        XCTAssertNotNil(keychain.value(for: account))
        XCTAssertEqual(viewModel.hostRows.map(\.id), [record.id])

        let forgetSucceeded = await viewModel.forgetHost(id: record.id)

        XCTAssertTrue(forgetSucceeded)
        XCTAssertEqual(connectionManager.teardownHostIDs, [record.id])
        XCTAssertNil(keychain.value(for: account))
        XCTAssertFalse(registry.hasHosts)
        XCTAssertTrue(viewModel.hostRows.isEmpty)
    }

    func testForgetDisconnectsBeforeRegistryRemovalAndKeychainDeletion() async throws {
        let recorder = RemoteHostsForgetOrderRecorder()
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio")
        let registry = RecordingRemoteHostsRegistry(record: record, recorder: recorder)
        let keyStore = RecordingRemoteHostsClientKeyDeleter(recorder: recorder)
        let connectionManager = RecordingRemoteHostsConnectionManager(recorder: recorder)
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: keyStore,
            pairingClient: ImmediateRemoteHostsPairingClient(),
            connectionManager: connectionManager
        )

        let forgetSucceeded = await viewModel.forgetHost(id: record.id)

        XCTAssertTrue(forgetSucceeded)
        XCTAssertEqual(recorder.events, [
            "disconnect:\(record.id)",
            "registry.remove:\(record.id)",
            "keychain.delete:\(record.id)"
        ])
        XCTAssertEqual(viewModel.statusMessage, "Forgot remote host. The host may still list this device until it is revoked there.")
        XCTAssertFalse(viewModel.hasHosts)
    }

    func testForgetReportsKeyDeletionWarningAfterRegistryRemoval() async throws {
        let recorder = RemoteHostsForgetOrderRecorder()
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio")
        let registry = RecordingRemoteHostsRegistry(record: record, recorder: recorder)
        let keyStore = RecordingRemoteHostsClientKeyDeleter(
            recorder: recorder,
            error: RemoteClientKeyStoreError.keychainUnavailable("locked")
        )
        let connectionManager = RecordingRemoteHostsConnectionManager(recorder: recorder)
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: keyStore,
            pairingClient: ImmediateRemoteHostsPairingClient(),
            connectionManager: connectionManager
        )

        let forgetSucceeded = await viewModel.forgetHost(id: record.id)

        XCTAssertTrue(forgetSucceeded)
        XCTAssertFalse(viewModel.hasHosts)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(recorder.events, [
            "disconnect:\(record.id)",
            "registry.remove:\(record.id)",
            "keychain.delete:\(record.id)"
        ])
        XCTAssertTrue(try XCTUnwrap(viewModel.statusMessage).contains("device key could not be deleted"))
    }

    func testConnectionActionUsesTesterRefreshesRowsAndReportsStatus() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio")
        try registry.upsertHost(record)
        let tester = RecordingRemoteHostsConnectionTester(result: RemoteHostConnectionTestResult(
            hostID: record.id,
            hostName: "Studio Live",
            scopes: record.grantedScopes,
            pongPayload: .object(["probe": .string("settings_test_connection")])
        ))
        tester.onTest = { hostID in
            _ = try registry.updateLastConnected(hostID: hostID, at: Date(timeIntervalSince1970: 1_800_000_321))
        }
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: RemoteClientKeyStore(
                keychain: InMemoryRemoteClientKeychain(),
                accessMode: .nonInteractive(reason: .test)
            ),
            pairingClient: ImmediateRemoteHostsPairingClient(),
            connectionTester: tester
        )

        let succeeded = await viewModel.testConnection(id: record.id)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(tester.hostIDs, [record.id])
        XCTAssertEqual(viewModel.statusMessage, "Connected to Studio Live.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isTestingConnection(hostID: record.id))
        XCTAssertEqual(viewModel.hostRows.first?.lastConnectedAt, Date(timeIntervalSince1970: 1_800_000_321))
    }

    func testConnectionActionSurfacesRemoteClientError() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio")
        try registry.upsertHost(record)
        let tester = RecordingRemoteHostsConnectionTester(error: RemoteClientError.timeout(operation: "ping", seconds: 5))
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: RemoteClientKeyStore(
                keychain: InMemoryRemoteClientKeychain(),
                accessMode: .nonInteractive(reason: .test)
            ),
            pairingClient: ImmediateRemoteHostsPairingClient(),
            connectionTester: tester
        )

        let succeeded = await viewModel.testConnection(id: record.id)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(tester.hostIDs, [record.id])
        XCTAssertEqual(viewModel.errorMessage, "Remote ping timed out after 5 seconds.")
        XCTAssertNil(viewModel.statusMessage)
    }

    func testRenameAndRevokedBannerRowLogic() throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        var record = try RemoteHostTestSupport.hostRecord(displayName: "Studio")
        record.revokedByHostAt = Date(timeIntervalSince1970: 1_800_000_200)
        try registry.upsertHost(record)
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: RemoteClientKeyStore(
                keychain: InMemoryRemoteClientKeychain(),
                accessMode: .nonInteractive(reason: .test)
            ),
            pairingClient: ImmediateRemoteHostsPairingClient()
        )

        let revokedRow = try XCTUnwrap(viewModel.hostRows.first)
        XCTAssertTrue(revokedRow.isRevokedByHost)
        XCTAssertTrue(try XCTUnwrap(revokedRow.revocationBannerMessage).contains("rejected the device credentials"))

        XCTAssertTrue(viewModel.renameHost(id: record.id, displayName: "  Studio Pro  "))
        XCTAssertEqual(viewModel.hostRows.first?.displayName, "Studio Pro")
        XCTAssertEqual(try registry.host(id: record.id)?.displayName, "Studio Pro")

        XCTAssertFalse(viewModel.renameHost(id: record.id, displayName: "   "))
        XCTAssertEqual(viewModel.errorMessage, "Host name cannot be empty.")
    }

    func testPairingErrorMessagesIncludeRetryGuidance() {
        let completionMessage = RemoteHostsSettingsViewModel.message(for: RemoteHostPairingError.completionUnconfirmed("x"))
        XCTAssertTrue(completionMessage.contains("Pairing was not confirmed: x"))
        XCTAssertTrue(completionMessage.contains("safe to search and retry"))
        XCTAssertEqual(
            RemoteHostsSettingsViewModel.message(for: RemoteHostPairingError.timeout),
            "Timed out contacting the host gateway."
        )
    }

    func testDiscoveryFailureSurfacesFriendlyErrorWithoutPersisting() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let discovery = StubRemoteHostsDiscovery(error: TailscaleStatusError.backendUnavailable("Stopped"))
        let viewModel = RemoteHostsSettingsViewModel(
            registry: registry,
            keyStore: RemoteClientKeyStore(
                keychain: InMemoryRemoteClientKeychain(),
                accessMode: .nonInteractive(reason: .test)
            ),
            pairingClient: ImmediateRemoteHostsPairingClient(),
            discoveryService: discovery
        )

        viewModel.findHosts()
        await waitForDiscovery(viewModel)

        XCTAssertEqual(viewModel.discoveryState, .failed(message: "Tailscale is not ready (Stopped)."))
        XCTAssertEqual(viewModel.errorMessage, "Tailscale is not ready (Stopped).")
        XCTAssertTrue(viewModel.discoveredHosts.isEmpty)
        XCTAssertFalse(registry.hasHosts)
    }

    private func waitForDiscovery(
        _ viewModel: RemoteHostsSettingsViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 50 {
            if !viewModel.discoveryState.isSearching { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for discovery", file: file, line: line)
    }

    private func waitForPairingRequest(
        _ client: SuspendedRemoteHostsPairingClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 20 {
            if !client.requests.isEmpty { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for pairing request", file: file, line: line)
    }

    private static func candidate(
        hostSigner: P256.Signing.PrivateKey,
        origin: RemoteGatewayOrigin
    ) -> VerifiedRemoteHostCandidate {
        VerifiedRemoteHostCandidate(
            tailscalePeerID: "peer-1",
            tailscalePeerName: "studio.tailnet.ts.net",
            tailscaleDNSName: "studio.tailnet.ts.net",
            tailscaleIPv4: "100.64.0.8",
            channel: .release,
            origin: origin,
            signedHostName: "Studio",
            hostFingerprint: RemotePairingCrypto.fingerprint(for: hostSigner.publicKey),
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            bundleID: "com.pvncher.repoprompt.ce",
            marketingVersion: "1.0",
            buildVersion: "1",
            capabilities: ["approval_context_v1", "native_pairing_v1"]
        )
    }

    fileprivate nonisolated static func record(from payload: RemotePairingPayload) throws -> PairedHostRecord {
        let deviceKey = P256.Signing.PrivateKey()
        return try PairedHostRecord(
            id: payload.hostFingerprint,
            displayName: payload.hostDisplayName,
            gatewayURL: payload.gatewayURL,
            hostPublicKey: payload.hostPublicKey,
            deviceID: RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation),
            grantedScopes: RemoteHostPairingClient.defaultRequestedScopes,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private actor StubRemoteHostsDiscovery: RemoteHostsDiscovering {
    private let result: RemoteHostDiscoveryResult?
    private let payload: RemotePairingPayload?
    private let error: (any Error)?
    private var revalidations = 0

    init(result: RemoteHostDiscoveryResult, payload: RemotePairingPayload) {
        self.result = result
        self.payload = payload
        error = nil
    }

    init(error: any Error) {
        result = nil
        payload = nil
        self.error = error
    }

    func search() async throws -> RemoteHostDiscoveryResult {
        if let error { throw error }
        guard let result else { throw RemoteHostDiscoveryError.invalidResponse }
        return result
    }

    func revalidateForPairing(_: VerifiedRemoteHostCandidate) async throws -> RemotePairingPayload {
        revalidations += 1
        if let error { throw error }
        guard let payload else { throw RemoteHostDiscoveryError.invalidResponse }
        return payload
    }

    func revalidationCount() -> Int {
        revalidations
    }
}

private final class SuspendedRemoteHostsPairingClient: RemoteHostsPairingClientProtocol {
    struct Request: Equatable {
        var payload: RemotePairingPayload
        var displayName: String
        var scopes: Set<String>
    }

    private(set) var requests: [Request] = []
    private var continuation: CheckedContinuation<PairedHostRecord, Error>?

    func pair(
        payload: RemotePairingPayload,
        displayName: String,
        scopes: Set<String>
    ) async throws -> PairedHostRecord {
        requests.append(Request(payload: payload, displayName: displayName, scopes: scopes))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with record: PairedHostRecord) {
        continuation?.resume(returning: record)
        continuation = nil
    }
}

private struct ImmediateRemoteHostsPairingClient: RemoteHostsPairingClientProtocol {
    func pair(
        payload: RemotePairingPayload,
        displayName _: String,
        scopes _: Set<String>
    ) async throws -> PairedHostRecord {
        try RemoteHostsSettingsViewModelTests.record(from: payload)
    }
}

private final class RemoteHostsForgetOrderRecorder {
    var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private final class RecordingRemoteHostsRegistry: RemoteHostsRegistryManaging {
    private var record: PairedHostRecord?
    private let recorder: RemoteHostsForgetOrderRecorder

    init(record: PairedHostRecord, recorder: RemoteHostsForgetOrderRecorder) {
        self.record = record
        self.recorder = recorder
    }

    var hasHosts: Bool {
        record != nil
    }

    func listHosts() throws -> [PairedHostRecord] {
        record.map { [$0] } ?? []
    }

    func upsertHost(_ record: PairedHostRecord) throws {
        self.record = record
    }

    @discardableResult
    func removeHost(id: String) throws -> PairedHostRecord? {
        recorder.record("registry.remove:\(id)")
        guard record?.id == id else { return nil }
        defer { record = nil }
        return record
    }

    @discardableResult
    func renameHost(id _: String, displayName _: String) throws -> PairedHostRecord {
        throw RemoteHostRegistryError.hostNotFound("unused")
    }
}

private final class RecordingRemoteHostsClientKeyDeleter: RemoteHostsClientKeyDeleting {
    private let recorder: RemoteHostsForgetOrderRecorder
    private let error: Error?

    init(recorder: RemoteHostsForgetOrderRecorder, error: Error? = nil) {
        self.recorder = recorder
        self.error = error
    }

    func deleteKey(forHostID hostID: String) throws {
        recorder.record("keychain.delete:\(hostID)")
        if let error { throw error }
    }
}

@MainActor
private final class RecordingRemoteHostsConnectionManager: RemoteHostsConnectionManaging {
    private let recorder: RemoteHostsForgetOrderRecorder?
    var teardownHostIDs: [String] = []

    init(recorder: RemoteHostsForgetOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func teardown(hostID: String) async {
        recorder?.record("disconnect:\(hostID)")
        teardownHostIDs.append(hostID)
    }

    func testConnection(hostID: String) async throws -> RemoteHostConnectionTestResult {
        RemoteHostConnectionTestResult(
            hostID: hostID,
            hostName: nil,
            scopes: [],
            pongPayload: .object([:])
        )
    }
}

@MainActor
private final class RecordingRemoteHostsConnectionTester: RemoteHostsConnectionTesting {
    private let result: Result<RemoteHostConnectionTestResult, Error>
    var hostIDs: [String] = []
    var onTest: ((String) throws -> Void)?

    init(result: RemoteHostConnectionTestResult) {
        self.result = .success(result)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func testConnection(hostID: String) async throws -> RemoteHostConnectionTestResult {
        hostIDs.append(hostID)
        try onTest?(hostID)
        return try result.get()
    }
}
