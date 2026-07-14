import AppKit
import Combine
import Foundation

protocol RemoteHostsRegistryManaging: AnyObject {
    var hasHosts: Bool { get }
    func listHosts() throws -> [PairedHostRecord]
    func upsertHost(_ record: PairedHostRecord) throws
    @discardableResult func removeHost(id: String) throws -> PairedHostRecord?
    @discardableResult func renameHost(id: String, displayName: String) throws -> PairedHostRecord
}

extension RemoteHostRegistry: RemoteHostsRegistryManaging {}

protocol RemoteHostsClientKeyDeleting: AnyObject {
    func deleteKey(forHostID hostID: String) throws
}

extension RemoteClientKeyStore: RemoteHostsClientKeyDeleting {}

protocol RemoteHostsPairingClientProtocol {
    func pair(
        payload: RemotePairingPayload,
        displayName: String,
        scopes: Set<String>
    ) async throws -> PairedHostRecord
}

extension RemoteHostPairingClient: RemoteHostsPairingClientProtocol {}

protocol RemoteHostsDiscovering: Sendable {
    func search() async throws -> RemoteHostDiscoveryResult
    func revalidateForPairing(_ selected: VerifiedRemoteHostCandidate) async throws -> RemotePairingPayload
}

extension RemoteHostDiscoveryService: RemoteHostsDiscovering {}

struct RemoteHostsSettingsScopeRow: Identifiable, Equatable {
    var id: String {
        rawValue
    }

    var rawValue: String
    var displayName: String

    init(rawValue: String) {
        self.rawValue = rawValue
        displayName = RemoteScope(rawValue: rawValue)?.displayName ?? rawValue
    }
}

struct RemoteHostsSettingsHostRow: Identifiable, Equatable {
    var id: String
    var displayName: String
    var gatewayURLString: String
    var hostFingerprint: String
    var hostFingerprintShort: String
    var deviceID: String
    var scopes: [RemoteHostsSettingsScopeRow]
    var pairedAt: Date
    var lastConnectedAt: Date?
    var revokedByHostAt: Date?

    init(record: PairedHostRecord) {
        id = record.id
        displayName = record.displayName
        gatewayURLString = record.gatewayURL.absoluteString
        hostFingerprint = record.id
        hostFingerprintShort = RemoteHostRegistry.hostFingerprintShort(record.id) ?? "unknown"
        deviceID = record.deviceID
        scopes = record.grantedScopes.sorted().map(RemoteHostsSettingsScopeRow.init(rawValue:))
        pairedAt = record.pairedAt
        lastConnectedAt = record.lastConnectedAt
        revokedByHostAt = record.revokedByHostAt
    }

    var isRevokedByHost: Bool {
        revokedByHostAt != nil
    }

    var scopeSummary: String {
        scopes.map(\.displayName).joined(separator: ", ")
    }

    var revocationBannerMessage: String? {
        guard let revokedByHostAt else { return nil }
        let timestamp = revokedByHostAt.formatted(date: .abbreviated, time: .shortened)
        return "This host rejected the device credentials on \(timestamp). Forget and pair again to restore access."
    }
}

enum RemoteHostsSettingsDiscoveryState: Equatable {
    case idle
    case searching
    case noHosts(RemoteHostDiscoveryDiagnostics)
    case results(RemoteHostDiscoveryDiagnostics)
    case failed(message: String)

    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }
}

enum RemoteHostsSettingsPairingState: Equatable {
    case idle
    case waitingForApproval(hostName: String)
    case paired(hostName: String)
    case failed(message: String)

    var isPairing: Bool {
        if case .waitingForApproval = self { return true }
        return false
    }
}

@MainActor
final class RemoteHostsSettingsViewModel: ObservableObject {
    @Published private(set) var hostRows: [RemoteHostsSettingsHostRow] = []
    @Published private(set) var discoveredHosts: [VerifiedRemoteHostCandidate] = []
    @Published private(set) var discoveryState: RemoteHostsSettingsDiscoveryState = .idle
    @Published private(set) var pairingState: RemoteHostsSettingsPairingState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var testingConnectionHostIDs: Set<String> = []

    private let registry: RemoteHostsRegistryManaging
    private let keyStore: RemoteHostsClientKeyDeleting
    private let pairingClient: any RemoteHostsPairingClientProtocol
    private let discoveryService: any RemoteHostsDiscovering
    private let connectionTester: (any RemoteHostsConnectionTesting)?
    private let connectionManagerProvider: @MainActor () -> any RemoteHostsConnectionManaging
    private let clientDisplayName: @MainActor () -> String
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration = 0

    init(
        registry: RemoteHostsRegistryManaging = RemoteHostRegistry.shared,
        keyStore: RemoteHostsClientKeyDeleting = RemoteClientKeyStore.shared,
        pairingClient: any RemoteHostsPairingClientProtocol = RemoteHostPairingClient(),
        discoveryService: any RemoteHostsDiscovering = RemoteHostDiscoveryService(),
        connectionTester: (any RemoteHostsConnectionTesting)? = nil,
        connectionManager: (any RemoteHostsConnectionManaging)? = nil,
        clientDisplayName: @escaping @MainActor () -> String = RemoteHostsSettingsViewModel.defaultClientDisplayName
    ) {
        self.registry = registry
        self.keyStore = keyStore
        self.pairingClient = pairingClient
        self.discoveryService = discoveryService
        self.connectionTester = connectionTester
        if let connectionManager {
            connectionManagerProvider = { connectionManager }
        } else {
            connectionManagerProvider = { RemoteHostConnectionManager.shared }
        }
        self.clientDisplayName = clientDisplayName
        refreshHosts()
    }

    deinit {
        discoveryTask?.cancel()
    }

    var hasHosts: Bool {
        !hostRows.isEmpty
    }

    func refreshHosts() {
        do {
            hostRows = try registry.listHosts().map(RemoteHostsSettingsHostRow.init(record:))
            errorMessage = nil
        } catch {
            hostRows = []
            errorMessage = Self.message(for: error)
        }
    }

    func findHosts() {
        cancelDiscovery(resetState: false)
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discoveredHosts = []
        discoveryState = .searching
        pairingState = .idle
        errorMessage = nil
        statusMessage = "Searching your tailnet for RepoPrompt hosts…"
        discoveryTask = Task { [weak self, discoveryService] in
            do {
                let result = try await discoveryService.search()
                guard !Task.isCancelled, let self, generation == discoveryGeneration else { return }
                discoveredHosts = result.hosts
                discoveryState = result.hosts.isEmpty ? .noHosts(result.diagnostics) : .results(result.diagnostics)
                statusMessage = result.hosts.isEmpty
                    ? "No signed RepoPrompt hosts responded."
                    : "Found \(result.hosts.count) RepoPrompt host\(result.hosts.count == 1 ? "" : "s")."
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == discoveryGeneration else { return }
                let message = Self.message(for: error)
                discoveryState = .failed(message: message)
                statusMessage = nil
                errorMessage = message
            }
        }
    }

    func cancelDiscovery(resetState: Bool = true) {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryGeneration += 1
        if resetState, discoveryState.isSearching {
            discoveryState = .idle
            statusMessage = nil
        }
    }

    func requestAccess(to selected: VerifiedRemoteHostCandidate) async {
        guard !pairingState.isPairing else { return }
        cancelDiscovery(resetState: false)
        pairingState = .waitingForApproval(hostName: selected.signedHostName)
        errorMessage = nil
        statusMessage = "Waiting for approval on \(selected.signedHostName)…"
        do {
            let payload = try await discoveryService.revalidateForPairing(selected)
            let record = try await pairingClient.pair(
                payload: payload,
                displayName: clientDisplayName(),
                scopes: RemoteHostPairingClient.defaultRequestedScopes
            )
            try registry.upsertHost(record)
            refreshHosts()
            discoveredHosts.removeAll { $0.hostFingerprint == record.id }
            pairingState = .paired(hostName: record.displayName)
            statusMessage = "Paired \(record.displayName)."
        } catch {
            let message = Self.message(for: error)
            pairingState = .failed(message: message)
            statusMessage = nil
            errorMessage = message
        }
    }

    func isTestingConnection(hostID: String) -> Bool {
        testingConnectionHostIDs.contains(hostID)
    }

    @discardableResult
    func renameHost(id: String, displayName: String) -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Host name cannot be empty."
            return false
        }
        do {
            _ = try registry.renameHost(id: id, displayName: trimmed)
            refreshHosts()
            statusMessage = "Renamed remote host."
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func forgetHost(id: String) async -> Bool {
        do {
            statusMessage = "Forgetting remote host…"
            await connectionManagerProvider().teardown(hostID: id)
            _ = try registry.removeHost(id: id)
            do {
                try keyStore.deleteKey(forHostID: id)
            } catch {
                refreshHosts()
                errorMessage = nil
                statusMessage = "Forgot remote host, but the device key could not be deleted: \(Self.message(for: error))"
                return true
            }
            refreshHosts()
            statusMessage = "Forgot remote host. The host may still list this device until it is revoked there."
            return true
        } catch {
            refreshHosts()
            statusMessage = nil
            errorMessage = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func testConnection(id: String) async -> Bool {
        guard !testingConnectionHostIDs.contains(id) else { return false }
        testingConnectionHostIDs.insert(id)
        statusMessage = "Testing remote host connection…"
        errorMessage = nil
        defer { testingConnectionHostIDs.remove(id) }
        do {
            let tester = connectionTester ?? connectionManagerProvider()
            let result = try await tester.testConnection(hostID: id)
            refreshHosts()
            let hostName = result.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = hostName?.isEmpty == false
                ? hostName!
                : (hostRows.first { $0.id == id }?.displayName ?? "remote host")
            statusMessage = "Connected to \(displayName)."
            return true
        } catch {
            refreshHosts()
            let message = Self.message(for: error)
            statusMessage = nil
            errorMessage = message
            return false
        }
    }

    static func defaultClientDisplayName() -> String {
        let candidates = [Host.current().localizedName, Host.current().name, ProcessInfo.processInfo.hostName]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return "RepoPrompt Client"
    }

    static func message(for error: Error) -> String {
        switch error {
        case let RemotePairingPayloadError.unsupportedVersion(version):
            "Pairing payload version \(version) is not supported."
        case RemotePairingPayloadError.invalidKind:
            "Pairing payload is not a RepoPrompt remote pairing payload."
        case let RemotePairingPayloadError.invalidGatewayURL(value):
            "Pairing gateway origin is invalid: \(value)."
        case let RemotePairingPayloadError.invalidHostFingerprint(value):
            "Pairing host fingerprint is invalid: \(value)."
        case RemotePairingPayloadError.invalidHostPublicKey:
            "Pairing host public key is invalid."
        case RemotePairingPayloadError.fingerprintMismatch:
            "Pairing fingerprint does not match the signed host public key."
        case RemotePairingPayloadError.missingApprovalContext:
            "Pairing approval expired; search again."
        case let RemoteHostPairingError.invalidRequest(message):
            message
        case let RemoteHostPairingError.invalidResponse(message):
            "Pairing response was invalid: \(message)"
        case let RemoteHostPairingError.hostIdentityMismatch(message),
             let RemoteHostPairingError.consentDenied(message):
            message
        case RemoteHostPairingError.timeout:
            "Timed out contacting the host gateway."
        case let RemoteHostPairingError.completionUnconfirmed(reason):
            "Pairing was not confirmed: \(reason). It is safe to search and retry."
        case let RemoteHostPairingError.httpError(statusCode, code, message):
            "Pairing failed: \(message ?? code ?? "HTTP \(statusCode)")."
        case let RemoteHostPairingError.transport(message):
            "Pairing transport failed: \(message)"
        case let localized as LocalizedError:
            localized.errorDescription ?? error.localizedDescription
        default:
            error.localizedDescription
        }
    }
}
