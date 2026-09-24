import Foundation

protocol SecureKeyValueStorageBackend: AnyObject, Sendable {
    var persistsValuesAcrossLaunches: Bool { get }

    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws

    func get(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws -> String

    func delete(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws
}

struct SecureKeyValueStorageSelection {
    let decision: RuntimeSecureStorageDecision
    let backend: SecureKeyValueStorageBackend
}

enum SecureKeyValueStorageFactory {
    private static let cachedSelection: SecureKeyValueStorageSelection = {
        let localSigningContext = RuntimeCodeSigningPolicy.currentLocalSigningContext()
        let signingInfo = RuntimeCodeSigningDetector.currentProcessSigningInfo(
            localSigningExpectation: localSigningContext.expectation
        )
        return selection(
            for: RuntimeCodeSigningPolicy.currentDecision(
                signingInfo: signingInfo,
                localSigningContext: localSigningContext
            )
        )
    }()

    static func defaultBackend() -> SecureKeyValueStorageBackend {
        cachedSelection.backend
    }

    static func currentDecision() -> RuntimeSecureStorageDecision {
        cachedSelection.decision
    }

    static func selection(for decision: RuntimeSecureStorageDecision) -> SecureKeyValueStorageSelection {
        let backend: SecureKeyValueStorageBackend
        switch decision.domain {
        case .officialDeveloperID:
            backend = KeychainService.officialV2Shared
        case .localSelfSigned:
            if let fingerprint = decision.localCertificateFingerprint,
               let generation = decision.localServiceGeneration,
               generation > 0
            {
                backend = KeychainService.localSelfSigned(fingerprint: fingerprint, generation: generation)
            } else {
                backend = EphemeralSecureKeyValueStore.shared
            }
        case .appleDevelopmentDebug:
            if let team = decision.debugTeamIdentifier,
               RuntimeCodeSigningPolicy.appleDevelopmentDebugTeamIdentifiers.contains(team)
            {
                backend = KeychainService.appleDevelopmentDebug(teamIdentifier: team)
            } else {
                return SecureKeyValueStorageSelection(
                    decision: RuntimeSecureStorageDecision(domain: .ephemeral, rejectionReason: .markerSignatureMismatch),
                    backend: EphemeralSecureKeyValueStore.shared
                )
            }
        case .ephemeral:
            backend = EphemeralSecureKeyValueStore.shared
        }
        return SecureKeyValueStorageSelection(decision: decision, backend: backend)
    }
}
