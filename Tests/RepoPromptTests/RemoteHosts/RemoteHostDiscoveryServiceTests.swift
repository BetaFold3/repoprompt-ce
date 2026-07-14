import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class RemoteHostDiscoveryServiceTests: XCTestCase {
    func testSearchKeepsVerifiedPartialResultsAndReportsFailures() async throws {
        let signer = P256.Signing.PrivateKey()
        let good = try candidate(ip: "100.64.0.8", channel: .release)
        let bad = try candidate(ip: "100.64.0.9", channel: .debug)
        let service = RemoteHostDiscoveryService(
            candidateProvider: { [good, bad] },
            probe: { candidate, request in
                if candidate.peerIPv4 == bad.peerIPv4 {
                    throw URLError(.timedOut)
                }
                return try Self.response(
                    signer: signer,
                    candidate: candidate,
                    request: request,
                    approvalContext: "context-one"
                )
            },
            nowMilliseconds: { 1_030_000 }
        )

        let result = try await service.search()

        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts.first?.tailscalePeerName, "peer-100.64.0.8")
        XCTAssertEqual(result.hosts.first?.signedHostName, "Signed Studio")
        XCTAssertEqual(result.diagnostics, .init(candidateCount: 2, verifiedCount: 1, failedProbeCount: 1))
    }

    func testRevalidationRequiresUnchangedPinnedIdentity() async throws {
        let selectedSigner = P256.Signing.PrivateKey()
        let changedSigner = P256.Signing.PrivateKey()
        let route = try candidate(ip: "100.64.0.8", channel: .release)
        let selectedResponse = try Self.response(
            signer: selectedSigner,
            candidate: route,
            request: RemoteDiscoveryRequest(
                nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                channel: .release
            ),
            approvalContext: "old"
        )
        let selected = VerifiedRemoteHostCandidate(
            tailscalePeerID: route.peerID,
            tailscalePeerName: route.peerDisplayName,
            tailscaleDNSName: route.peerDNSName,
            tailscaleIPv4: route.peerIPv4,
            channel: .release,
            origin: route.origin,
            signedHostName: selectedResponse.hostName,
            hostFingerprint: selectedResponse.hostFingerprint,
            hostPublicKey: selectedResponse.hostPublicKey,
            bundleID: selectedResponse.bundleID,
            marketingVersion: selectedResponse.marketingVersion,
            buildVersion: selectedResponse.buildVersion,
            capabilities: selectedResponse.capabilities
        )
        let service = RemoteHostDiscoveryService(
            candidateProvider: { [] },
            probe: { candidate, request in
                try Self.response(
                    signer: changedSigner,
                    candidate: candidate,
                    request: request,
                    approvalContext: "fresh"
                )
            },
            nowMilliseconds: { 1_030_000 }
        )

        do {
            _ = try await service.revalidateForPairing(selected)
            XCTFail("Expected selected host identity change")
        } catch {
            XCTAssertEqual(error as? RemoteHostDiscoveryError, .selectedHostChanged)
        }
    }

    private func candidate(
        ip: String,
        channel: RemoteControlBuildChannel
    ) throws -> TailscaleDiscoveryCandidate {
        try TailscaleDiscoveryCandidate(
            peerID: ip,
            peerDisplayName: "peer-\(ip)",
            peerDNSName: "peer-\(ip).ts.net",
            peerIPv4: ip,
            channel: channel,
            origin: RemoteGatewayOrigin(tailscaleIPv4: ip, channel: channel)
        )
    }

    private static func response(
        signer: P256.Signing.PrivateKey,
        candidate: TailscaleDiscoveryCandidate,
        request: RemoteDiscoveryRequest,
        approvalContext: String
    ) throws -> RemoteDiscoveryResponse {
        try RemoteDiscoveryResponse(
            request: request,
            origin: candidate.origin,
            hostPublicKey: signer.publicKey.rawRepresentation,
            hostFingerprint: "sha256:" + RemoteWireProtocol.sha256Hex(of: signer.publicKey.rawRepresentation),
            hostName: "Signed Studio",
            bundleID: candidate.channel == .release
                ? "com.pvncher.repoprompt.ce"
                : "com.pvncher.repoprompt.ce.debug",
            marketingVersion: "1.0",
            buildVersion: "1",
            approvalContext: approvalContext,
            issuedAtMs: 1_000_000,
            expiresAtMs: 1_060_000,
            hostSigner: signer
        )
    }
}
