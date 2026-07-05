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

struct RemoteHostsSettingsPairingPreview: Equatable {
    var displayName: String
    var gatewayURLString: String
    var hostFingerprint: String
    var hostFingerprintShort: String
    var hostPublicKeyBase64: String
}

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

enum RemoteHostsSettingsPairingState: Equatable {
    case idle
    case ready
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
    @Published var pairingPayloadText: String = ""
    @Published var gatewayURLString: String = ""
    @Published private(set) var pairingPreview: RemoteHostsSettingsPairingPreview?
    @Published private(set) var pairingState: RemoteHostsSettingsPairingState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var testingConnectionHostIDs: Set<String> = []

    private let registry: RemoteHostsRegistryManaging
    private let keyStore: RemoteHostsClientKeyDeleting
    private let pairingClient: any RemoteHostsPairingClientProtocol
    private let connectionTester: (any RemoteHostsConnectionTesting)?
    private let connectionManagerProvider: @MainActor () -> any RemoteHostsConnectionManaging
    private let clientDisplayName: @MainActor () -> String
    private var parsedPayload: RemotePairingPayload?

    init(
        registry: RemoteHostsRegistryManaging = RemoteHostRegistry.shared,
        keyStore: RemoteHostsClientKeyDeleting = RemoteClientKeyStore.shared,
        pairingClient: any RemoteHostsPairingClientProtocol = RemoteHostPairingClient(),
        connectionTester: (any RemoteHostsConnectionTesting)? = nil,
        connectionManager: (any RemoteHostsConnectionManaging)? = nil,
        clientDisplayName: @escaping @MainActor () -> String = RemoteHostsSettingsViewModel.defaultClientDisplayName
    ) {
        self.registry = registry
        self.keyStore = keyStore
        self.pairingClient = pairingClient
        self.connectionTester = connectionTester
        if let connectionManager {
            connectionManagerProvider = { connectionManager }
        } else {
            connectionManagerProvider = { RemoteHostConnectionManager.shared }
        }
        self.clientDisplayName = clientDisplayName
        refreshHosts()
    }

    var hasHosts: Bool {
        !hostRows.isEmpty
    }

    var canPair: Bool {
        guard parsedPayload != nil,
              !pairingState.isPairing,
              let url = URL(string: gatewayURLString),
              RemoteHostRegistry.isValidGatewayURL(url)
        else {
            return false
        }
        return true
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

    func isTestingConnection(hostID: String) -> Bool {
        testingConnectionHostIDs.contains(hostID)
    }

    func resetPairing() {
        pairingPayloadText = ""
        gatewayURLString = ""
        pairingPreview = nil
        parsedPayload = nil
        pairingState = .idle
        statusMessage = nil
        errorMessage = nil
    }

    func parsePairingPayloadText() {
        let trimmed = pairingPayloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsedPayload = nil
            pairingPreview = nil
            gatewayURLString = ""
            pairingState = .idle
            errorMessage = nil
            return
        }

        do {
            let payload = try RemotePairingPayload.parse(trimmed)
            parsedPayload = payload
            gatewayURLString = payload.gatewayURL.absoluteString
            pairingPreview = RemoteHostsSettingsPairingPreview(
                displayName: payload.hostDisplayName,
                gatewayURLString: payload.gatewayURL.absoluteString,
                hostFingerprint: payload.hostFingerprint,
                hostFingerprintShort: payload.fingerprintShort,
                hostPublicKeyBase64: payload.hostPublicKey.base64EncodedString()
            )
            pairingState = .ready
            errorMessage = nil
        } catch {
            parsedPayload = nil
            pairingPreview = nil
            gatewayURLString = ""
            pairingState = .failed(message: Self.message(for: error))
            errorMessage = Self.message(for: error)
        }
    }

    func pairCurrentPayload() async {
        guard let parsedPayload else {
            parsePairingPayloadText()
            if parsedPayload == nil, errorMessage == nil {
                let message = "Paste a remote pairing payload first."
                pairingState = .failed(message: message)
                errorMessage = message
            }
            return
        }
        guard let gatewayURL = URL(string: gatewayURLString), RemoteHostRegistry.isValidGatewayURL(gatewayURL) else {
            let message = "Enter a valid http or https gateway URL before pairing."
            pairingState = .failed(message: message)
            errorMessage = message
            return
        }

        do {
            let payload = try parsedPayload.withGatewayURL(gatewayURL)
            pairingState = .waitingForApproval(hostName: payload.hostDisplayName)
            errorMessage = nil
            statusMessage = "Waiting for approval on \(payload.hostDisplayName)…"

            let record = try await pairingClient.pair(
                payload: payload,
                displayName: clientDisplayName(),
                scopes: RemoteHostPairingClient.defaultRequestedScopes
            )
            try registry.upsertHost(record)
            refreshHosts()
            statusMessage = "Paired \(record.displayName)."
            pairingState = .paired(hostName: record.displayName)
        } catch {
            let message = Self.message(for: error)
            pairingState = .failed(message: message)
            statusMessage = nil
            errorMessage = message
        }
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
        defer {
            testingConnectionHostIDs.remove(id)
        }

        do {
            let tester = connectionTester ?? connectionManagerProvider()
            let result = try await tester.testConnection(hostID: id)
            refreshHosts()
            let hostName = result.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = hostName?.isEmpty == false
                ? hostName!
                : (hostRows.first { $0.id == id }?.displayName ?? "remote host")
            statusMessage = "Connected to \(displayName)."
            errorMessage = nil
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
        let candidates = [
            Host.current().localizedName,
            Host.current().name,
            ProcessInfo.processInfo.hostName
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return "RepoPrompt Client"
    }

    static func message(for error: Error) -> String {
        switch error {
        case RemotePairingPayloadError.invalidJSON:
            return "Pairing payload must be valid JSON copied from the host's Remote Control settings."
        case let RemotePairingPayloadError.unsupportedVersion(version):
            return "Pairing payload version \(version) is not supported."
        case RemotePairingPayloadError.invalidKind:
            return "Pairing payload is not a RepoPrompt remote pairing payload."
        case let RemotePairingPayloadError.invalidGatewayURL(value):
            return "Pairing payload gateway URL is invalid: \(value)."
        case let RemotePairingPayloadError.invalidHostFingerprint(value):
            return "Pairing payload host fingerprint is invalid: \(value)."
        case RemotePairingPayloadError.invalidHostPublicKey:
            return "Pairing payload host public key is invalid."
        case RemotePairingPayloadError.fingerprintMismatch:
            return "Pairing payload fingerprint does not match the host public key."
        case let RemoteHostPairingError.invalidRequest(message):
            return message
        case let RemoteHostPairingError.invalidResponse(message):
            return "Pairing response was invalid: \(message)"
        case let RemoteHostPairingError.hostIdentityMismatch(message):
            return message
        case let RemoteHostPairingError.consentDenied(message):
            return message
        case RemoteHostPairingError.timeout:
            return "Timed out contacting the host's gateway."
        case let RemoteHostPairingError.completionUnconfirmed(reason):
            return "Pairing wasn't confirmed: \(reason). The host may have already added this device. It's safe to retry — this Mac kept its device key — or you can revoke the device in the host's Remote Control settings."
        case let RemoteHostPairingError.httpError(statusCode, code, message):
            let suffix = message ?? code ?? "HTTP \(statusCode)"
            return "Pairing failed: \(suffix)."
        case let RemoteHostPairingError.transport(message):
            return "Pairing transport failed: \(message)"
        case let RemoteHostRegistryError.hostNotFound(id):
            return "Remote host not found: \(id)."
        case RemoteHostRegistryError.missing:
            return "Remote hosts registry is missing."
        case RemoteHostRegistryError.notRegularFile,
             RemoteHostRegistryError.wrongOwner,
             RemoteHostRegistryError.insecurePermissions,
             RemoteHostRegistryError.unreadable,
             RemoteHostRegistryError.invalidRegistry:
            return "Remote hosts registry failed validation."
        case let RemoteHostRegistryError.writeFailed(message):
            return "Failed to save remote hosts: \(message)"
        case let RemoteClientKeyStoreError.invalidHostID(id):
            return "Remote host fingerprint is invalid: \(id)."
        case let RemoteClientKeyStoreError.missingKey(id):
            return "No device key was found for remote host \(id)."
        case RemoteClientKeyStoreError.invalidPrivateKey:
            return "Stored remote host device key is invalid."
        case let RemoteClientKeyStoreError.keychainUnavailable(message):
            return "Remote host device keychain is unavailable: \(message)"
        case let remoteError as RemoteClientError:
            return remoteError.errorDescription ?? "Remote host connection failed."
        default:
            return error.localizedDescription
        }
    }
}
