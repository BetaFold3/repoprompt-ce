import Foundation
import RepoPromptRemoteWire

struct RemotePairingApprovalContext: Equatable {
    let token: String
    let launchID: UUID
    let origin: RemoteGatewayOrigin
    let channel: RemoteControlBuildChannel
    let hostFingerprint: String
    let nonce: String
    let expiresAt: Date
}

enum RemotePairingDiscoveryAuthorityError: Error, Equatable {
    case unavailable
    case buildChannelMismatch
    case approvalContextRequired
    case approvalContextExpired
    case approvalContextReplayed
}

actor RemotePairingDiscoveryAuthority {
    static let shared = RemotePairingDiscoveryAuthority()

    struct Configuration: Equatable {
        let launchID: UUID
        let origin: RemoteGatewayOrigin
        let buildIdentity: RemoteControlBuildIdentity
        let hostName: String
    }

    private struct StoredContext: Equatable {
        let value: RemotePairingApprovalContext
        let createdAt: Date
    }

    private var configuration: Configuration?
    private var contexts: [String: StoredContext] = [:]
    private var consumedTokens: [String: Date] = [:]
    private let identityStore: RemotePairingIdentityStore
    private let now: @Sendable () -> Date
    private let tokenGenerator: @Sendable () throws -> String

    init(
        identityStore: RemotePairingIdentityStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenGenerator: @escaping @Sendable () throws -> String = {
            try RemotePairingCrypto.randomChallenge(byteCount: 32)
        }
    ) {
        self.identityStore = identityStore
        self.now = now
        self.tokenGenerator = tokenGenerator
    }

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
        contexts.removeAll()
        consumedTokens.removeAll()
    }

    func clear() {
        configuration = nil
        contexts.removeAll()
        consumedTokens.removeAll()
    }

    func clear(ifLaunchID launchID: UUID) {
        guard configuration?.launchID == launchID else { return }
        clear()
    }

    func activeConfiguration() -> Configuration? {
        configuration
    }

    func discover(_ request: RemoteDiscoveryRequest) throws -> RemoteDiscoveryResponse {
        try request.validate()
        guard let configuration else {
            throw RemotePairingDiscoveryAuthorityError.unavailable
        }
        guard request.channel == configuration.buildIdentity.channel else {
            throw RemotePairingDiscoveryAuthorityError.buildChannelMismatch
        }
        let timestamp = now()
        prune(now: timestamp)
        let host = try identityStore.hostPublicKeyInfo()
        let token = try tokenGenerator()
        let expiresAt = timestamp.addingTimeInterval(
            TimeInterval(RemoteDiscoveryResponse.maximumTTLMilliseconds) / 1000
        )
        let context = RemotePairingApprovalContext(
            token: token,
            launchID: configuration.launchID,
            origin: configuration.origin,
            channel: configuration.buildIdentity.channel,
            hostFingerprint: host.fingerprint,
            nonce: request.nonce,
            expiresAt: expiresAt
        )
        contexts[token] = StoredContext(value: context, createdAt: timestamp)
        enforceCapacity()

        let issuedAtMs = Int64((timestamp.timeIntervalSince1970 * 1000).rounded(.down))
        let expiresAtMs = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded(.down))
        return try RemoteDiscoveryResponse(
            request: request,
            origin: configuration.origin,
            hostPublicKey: host.rawRepresentation,
            hostFingerprint: host.fingerprint,
            hostName: configuration.hostName,
            bundleID: configuration.buildIdentity.bundleID,
            marketingVersion: configuration.buildIdentity.marketingVersion,
            buildVersion: configuration.buildIdentity.buildVersion,
            approvalContext: token,
            issuedAtMs: issuedAtMs,
            expiresAtMs: expiresAtMs,
            hostSigner: identityStore.hostSigningPrivateKey()
        )
    }

    func consumeContext(_ token: String) throws -> RemotePairingApprovalContext {
        let timestamp = now()
        prune(now: timestamp)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextRequired
        }
        if consumedTokens[token] != nil {
            throw RemotePairingDiscoveryAuthorityError.approvalContextReplayed
        }
        guard let stored = contexts.removeValue(forKey: token) else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextExpired
        }
        guard stored.value.expiresAt > timestamp else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextExpired
        }
        try validateActiveContext(stored.value, now: timestamp)
        consumedTokens[token] = stored.value.expiresAt
        return stored.value
    }

    func validateActiveContext(_ context: RemotePairingApprovalContext) throws {
        try validateActiveContext(context, now: now())
    }

    private func validateActiveContext(_ context: RemotePairingApprovalContext, now timestamp: Date) throws {
        guard context.expiresAt > timestamp,
              let configuration,
              context.launchID == configuration.launchID,
              context.origin == configuration.origin,
              context.channel == configuration.buildIdentity.channel,
              try context.hostFingerprint == (identityStore.hostPublicKeyInfo()).fingerprint
        else {
            throw RemotePairingDiscoveryAuthorityError.approvalContextExpired
        }
    }

    private func prune(now: Date) {
        contexts = contexts.filter { $0.value.value.expiresAt > now }
        consumedTokens = consumedTokens.filter { $0.value > now }
    }

    private func enforceCapacity() {
        guard contexts.count > 256 else { return }
        let ordered = contexts.sorted {
            if $0.value.value.expiresAt == $1.value.value.expiresAt {
                return $0.value.createdAt < $1.value.createdAt
            }
            return $0.value.value.expiresAt < $1.value.value.expiresAt
        }
        for entry in ordered.prefix(contexts.count - 256) {
            contexts.removeValue(forKey: entry.key)
        }
    }
}
