@testable import RepoPromptApp
import Security
import XCTest

final class RuntimeCodeSigningPolicyTests: XCTestCase {
    func testVerifiedPersistentDomainsRouteToIsolatedServices() {
        let official = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let localFingerprint = String(repeating: "A", count: 64)
        let localExpectation = RuntimeLocalSigningExpectation(
            bundleLeafCertificateSHA256: localFingerprint,
            registeredLeafCertificateSHA256: localFingerprint,
            bundleServiceGeneration: 3,
            registeredServiceGeneration: 3
        )
        let local = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            leafCertificateSHA256: localFingerprint,
            validatedDomains: [.localSelfSigned]
        )
        let debug = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.appleDevelopmentDebug]
        )

        assertDecision(
            marker: "developer-id",
            debugMarker: "keychain",
            signingInfo: official,
            expectedDomain: .officialDeveloperID
        )
        assertDecision(
            marker: "local-self-signed",
            debugMarker: "keychain",
            signingInfo: local,
            localSigningContext: .valid(localExpectation),
            expectedDomain: .localSelfSigned,
            expectedLocalCertificateFingerprint: localFingerprint,
            expectedLocalServiceGeneration: 3
        )
        assertDecision(
            marker: "debug-apple-development",
            debugMarker: "keychain",
            signingInfo: debug,
            expectedDomain: .appleDevelopmentDebug,
            expectedDebugTeamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier
        )

        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(
                for: RuntimeSecureStorageDecision(domain: .officialDeveloperID, rejectionReason: nil)
            ).backend === KeychainService.officialV2Shared
        )
        let localSelection = SecureKeyValueStorageFactory.selection(
            for: RuntimeSecureStorageDecision(
                domain: .localSelfSigned,
                rejectionReason: nil,
                localCertificateFingerprint: localFingerprint,
                localServiceGeneration: 3
            )
        )
        XCTAssertEqual(
            (localSelection.backend as? KeychainService)?.serviceName,
            KeychainService.localSelfSignedServiceName(fingerprint: localFingerprint, generation: 3)
        )
        XCTAssertTrue(
            SecureKeyValueStorageFactory.selection(
                for: RuntimeSecureStorageDecision(
                    domain: .appleDevelopmentDebug,
                    rejectionReason: nil,
                    debugTeamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier
                )
            ).backend === KeychainService.debugShared
        )
    }

    func testRejectedModesExhaustivelyFailClosedToEphemeralStorage() {
        let official = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let debug = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier,
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.appleDevelopmentDebug]
        )
        let invalid = RuntimeCodeSigningInfo.synthetic(failure: .signatureInvalid)

        let cases: [(String?, String?, RuntimeCodeSigningInfo, RuntimeSecureStorageRejectionReason)] = [
            (nil, nil, official, .missingSigningModeMarker),
            ("", nil, official, .missingSigningModeMarker),
            ("unknown", nil, official, .unknownSigningModeMarker),
            ("release-candidate-adhoc", nil, official, .releaseCandidate),
            ("debug-adhoc", "alternate-in-memory", debug, .adHocDebug),
            ("debug-apple-development", "alternate-in-memory", debug, .debugEphemeralRequested),
            ("debug-apple-development", nil, debug, .missingDebugStorageMarker),
            ("debug-apple-development", "unknown", debug, .unknownDebugStorageMarker),
            ("developer-id", nil, invalid, .signingValidationFailed),
            ("developer-id", nil, debug, .markerSignatureMismatch),
            ("local-self-signed", nil, official, .localIdentityRegistryUnavailable),
            ("debug-apple-development", "keychain", official, .markerSignatureMismatch),
            ("developer-id", nil, RuntimeCodeSigningInfo.synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
                teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
                isAdHoc: true,
                validatedDomains: [.developerID]
            ), .markerSignatureMismatch)
        ]

        for (marker, debugMarker, signingInfo, expectedReason) in cases {
            let decision = RuntimeCodeSigningPolicy.decision(
                signingModeMarker: marker,
                debugStorageMarker: debugMarker,
                signingInfo: signingInfo
            )
            XCTAssertEqual(decision, RuntimeSecureStorageDecision(domain: .ephemeral, rejectionReason: expectedReason))
            XCTAssertTrue(SecureKeyValueStorageFactory.selection(for: decision).backend === EphemeralSecureKeyValueStore.shared)
        }
    }

    func testPersistentDomainsRequireExactIdentifierAndTeam() {
        let wrongIdentifier = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: "com.example.other",
            teamIdentifier: RuntimeCodeSigningPolicy.signingTeamIdentifier,
            validatedDomains: [.developerID]
        )
        let wrongTeam = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            teamIdentifier: "OTHERTEAM",
            validatedDomains: [.developerID]
        )

        for signingInfo in [wrongIdentifier, wrongTeam] {
            assertDecision(
                marker: "developer-id",
                debugMarker: nil,
                signingInfo: signingInfo,
                expectedDomain: .ephemeral,
                expectedReason: .markerSignatureMismatch
            )
        }
    }

    func testLocalSigningExpectationRequiresMatchingFingerprintAndGeneration() {
        let fingerprint = String(repeating: "AB", count: 32)
        XCTAssertEqual(
            RuntimeLocalSigningExpectation(
                bundleLeafCertificateSHA256: fingerprint.lowercased(),
                registeredLeafCertificateSHA256: fingerprint,
                bundleServiceGeneration: 4,
                registeredServiceGeneration: 4
            ).validatedIdentity,
            RuntimeValidatedLocalSigningIdentity(fingerprint: fingerprint, serviceGeneration: 4)
        )
        XCTAssertNil(
            RuntimeLocalSigningExpectation(
                bundleLeafCertificateSHA256: fingerprint,
                registeredLeafCertificateSHA256: String(repeating: "CD", count: 32),
                bundleServiceGeneration: 4,
                registeredServiceGeneration: 4
            ).validatedIdentity
        )
        XCTAssertNil(
            RuntimeLocalSigningExpectation(
                bundleLeafCertificateSHA256: fingerprint,
                registeredLeafCertificateSHA256: fingerprint,
                bundleServiceGeneration: 4,
                registeredServiceGeneration: 5
            ).validatedIdentity
        )
    }

    func testLocalPersistenceFailsClosedWithoutMatchingRegistryContext() {
        let fingerprint = String(repeating: "A", count: 64)
        let signingInfo = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
            leafCertificateSHA256: fingerprint,
            validatedDomains: [.localSelfSigned]
        )

        let rejectedContexts: [(RuntimeLocalSigningContext, RuntimeSecureStorageRejectionReason)] = [
            (.invalid(.localIdentityMetadataUnavailable), .localIdentityMetadataUnavailable),
            (.invalid(.localIdentityRegistryUnavailable), .localIdentityRegistryUnavailable),
            (.invalid(.localIdentityContinuityMismatch), .localIdentityContinuityMismatch)
        ]
        for (context, reason) in rejectedContexts {
            assertDecision(
                marker: "local-self-signed",
                debugMarker: "keychain",
                signingInfo: signingInfo,
                localSigningContext: context,
                expectedDomain: .ephemeral,
                expectedReason: reason
            )
        }
    }

    func testCompileTimeTrustAnchorsIncludeExpectedCertificateClasses() {
        XCTAssertEqual(RuntimeCodeSigningPolicy.developerIDBundleIdentifier, "com.pvncher.repoprompt.ce")
        XCTAssertEqual(RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier, "com.pvncher.repoprompt.ce.debug")
        XCTAssertEqual(RuntimeCodeSigningPolicy.signingTeamIdentifier, "648A27MST5")
        XCTAssertTrue(RuntimeCodeSigningPolicy.developerIDRequirement.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertTrue(RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement.contains("1.2.840.113635.100.6.1.12"))
    }

    func testAdditionalDebugTeamRequiresVerifiedIdentityAndUsesIsolatedKeychain() throws {
        let team = "AM9B9Y6HBV"
        let debug = RuntimeCodeSigningInfo.synthetic(
            codeIdentifier: RuntimeCodeSigningPolicy.appleDevelopmentDebugBundleIdentifier,
            teamIdentifier: team,
            validatedDomains: [.appleDevelopmentDebug]
        )
        let decision = RuntimeCodeSigningPolicy.decision(
            signingModeMarker: "debug-apple-development",
            debugStorageMarker: "keychain",
            signingInfo: debug
        )
        XCTAssertEqual(decision.domain, .appleDevelopmentDebug)
        XCTAssertEqual(decision.debugTeamIdentifier, team)
        let selection = SecureKeyValueStorageFactory.selection(for: decision)
        let backend = try XCTUnwrap(selection.backend as? KeychainService)
        XCTAssertTrue(backend.persistsValuesAcrossLaunches)
        XCTAssertEqual(backend.serviceName, "\(KeychainService.debugServiceName).team.\(team)")
        XCTAssertNotEqual(backend.serviceName, KeychainService.debugShared.serviceName)
        XCTAssertNotEqual(backend.serviceName, KeychainService.officialV2Shared.serviceName)
        XCTAssertEqual(
            KeychainService.appleDevelopmentDebug(teamIdentifier: team).serviceName,
            backend.serviceName
        )

        let invalidIdentities: [RuntimeCodeSigningInfo] = [
            .synthetic(codeIdentifier: debug.codeIdentifier, teamIdentifier: nil, validatedDomains: [.appleDevelopmentDebug]),
            .synthetic(codeIdentifier: debug.codeIdentifier, teamIdentifier: "OTHERTEAM", validatedDomains: [.appleDevelopmentDebug]),
            .synthetic(codeIdentifier: "com.example.other", teamIdentifier: team, validatedDomains: [.appleDevelopmentDebug]),
            .synthetic(codeIdentifier: debug.codeIdentifier, teamIdentifier: team, isAdHoc: true, validatedDomains: [.appleDevelopmentDebug]),
            .synthetic(codeIdentifier: debug.codeIdentifier, teamIdentifier: team)
        ]
        for identity in invalidIdentities {
            assertDecision(
                marker: "debug-apple-development",
                debugMarker: "keychain",
                signingInfo: identity,
                expectedDomain: .ephemeral,
                expectedReason: .markerSignatureMismatch
            )
        }
        // Authorization for this debug signer must never authorize official-release storage.
        assertDecision(
            marker: "developer-id",
            debugMarker: "keychain",
            signingInfo: .synthetic(
                codeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
                teamIdentifier: team,
                validatedDomains: [.developerID]
            ),
            expectedDomain: .ephemeral,
            expectedReason: .markerSignatureMismatch
        )
        assertDecision(
            marker: "debug-apple-development",
            debugMarker: "alternate-in-memory",
            signingInfo: debug,
            expectedDomain: .ephemeral,
            expectedReason: .debugEphemeralRequested
        )
        for malformedTeam: String? in [nil, "OTHERTEAM"] {
            let rejected = SecureKeyValueStorageFactory.selection(for: RuntimeSecureStorageDecision(
                domain: .appleDevelopmentDebug,
                rejectionReason: nil,
                debugTeamIdentifier: malformedTeam
            ))
            XCTAssertEqual(rejected.decision.domain, .ephemeral)
            XCTAssertEqual(rejected.decision.rejectionReason, .markerSignatureMismatch)
            XCTAssertFalse(rejected.backend.persistsValuesAcrossLaunches)
        }

        // Exercise the Security framework parser, not merely requirement string contents.
        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement as CFString,
                [], &requirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
    }

    private func assertDecision(
        marker: String?,
        debugMarker: String?,
        signingInfo: RuntimeCodeSigningInfo,
        localSigningContext: RuntimeLocalSigningContext? = nil,
        expectedDomain: RuntimeSecureStorageDomain,
        expectedReason: RuntimeSecureStorageRejectionReason? = nil,
        expectedLocalCertificateFingerprint: String? = nil,
        expectedLocalServiceGeneration: Int? = nil,
        expectedDebugTeamIdentifier: String? = nil
    ) {
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.decision(
                signingModeMarker: marker,
                debugStorageMarker: debugMarker,
                signingInfo: signingInfo,
                localSigningContext: localSigningContext
            ),
            RuntimeSecureStorageDecision(
                domain: expectedDomain,
                rejectionReason: expectedReason,
                localCertificateFingerprint: expectedLocalCertificateFingerprint,
                localServiceGeneration: expectedLocalServiceGeneration,
                debugTeamIdentifier: expectedDebugTeamIdentifier
            )
        )
    }
}
