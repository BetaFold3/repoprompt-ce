import Foundation

// App-owned: host-side pairing challenges carry `RemotePairingApprovalContext`.
struct RemotePairingChallenge: Identifiable, Equatable {
    let pairingID: UUID
    let challenge: String
    let createdAt: Date
    let expiresAt: Date
    let approvalContext: RemotePairingApprovalContext?
    var consumedAt: Date?

    var id: UUID {
        pairingID
    }
}

actor RemotePairingChallengeStore {
    static let shared = RemotePairingChallengeStore()

    typealias ChallengeGenerator = @Sendable () throws -> String

    private var challenges: [UUID: RemotePairingChallenge] = [:]
    private let challengeGenerator: ChallengeGenerator

    init(challengeGenerator: @escaping ChallengeGenerator = { try RemotePairingCrypto.randomChallenge() }) {
        self.challengeGenerator = challengeGenerator
    }

    func issue(
        now: Date = Date(),
        ttl: TimeInterval = RemotePairingCrypto.maximumPairingChallengeTTL,
        approvalContext: RemotePairingApprovalContext? = nil,
        expiresAtLimit: Date? = nil
    ) throws -> RemotePairingChallenge {
        prune(now: now)
        let resolvedTTL = min(max(ttl, 1), RemotePairingCrypto.maximumPairingChallengeTTL)
        let requestedExpiration = now.addingTimeInterval(resolvedTTL)
        let expiresAt = expiresAtLimit.map { min(requestedExpiration, $0) } ?? requestedExpiration
        guard expiresAt > now else { throw RemotePairingCryptoError.expiredChallenge }
        let challenge = try RemotePairingChallenge(
            pairingID: UUID(),
            challenge: challengeGenerator(),
            createdAt: now,
            expiresAt: expiresAt,
            approvalContext: approvalContext,
            consumedAt: nil
        )
        challenges[challenge.pairingID] = challenge
        return challenge
    }

    func consume(pairingID: UUID, now: Date = Date()) throws -> RemotePairingChallenge {
        guard var challenge = challenges[pairingID] else {
            throw RemotePairingCryptoError.challengeNotFound
        }
        guard challenge.consumedAt == nil else {
            throw RemotePairingCryptoError.challengeAlreadyUsed
        }
        guard challenge.expiresAt > now else {
            challenges[pairingID] = nil
            prune(now: now)
            throw RemotePairingCryptoError.expiredChallenge
        }
        prune(now: now)
        let unconsumed = challenge
        challenge.consumedAt = now
        challenges[pairingID] = challenge
        return unconsumed
    }

    func challenge(pairingID: UUID) -> RemotePairingChallenge? {
        challenges[pairingID]
    }

    func resetForTesting() {
        challenges.removeAll()
    }

    private func prune(now: Date) {
        challenges = challenges.filter { _, challenge in
            challenge.expiresAt > now
        }
    }
}
