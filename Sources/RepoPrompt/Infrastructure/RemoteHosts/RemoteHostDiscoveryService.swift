import Foundation
import RepoPromptRemoteWire

struct VerifiedRemoteHostCandidate: Identifiable, Equatable {
    let tailscalePeerID: String?
    let tailscalePeerName: String
    let tailscaleDNSName: String?
    let tailscaleIPv4: String
    let channel: RemoteControlBuildChannel
    let origin: RemoteGatewayOrigin
    let signedHostName: String
    let hostFingerprint: String
    let hostPublicKey: Data
    let bundleID: String
    let marketingVersion: String
    let buildVersion: String
    let capabilities: [String]

    var id: String {
        "\(hostFingerprint)|\(channel.rawValue)|\(origin.string)"
    }

    var fingerprintShort: String {
        String(hostFingerprint.suffix(64).prefix(8))
    }
}

struct RemoteHostDiscoveryDiagnostics: Equatable {
    let candidateCount: Int
    let verifiedCount: Int
    let failedProbeCount: Int
}

struct RemoteHostDiscoveryResult: Equatable {
    let hosts: [VerifiedRemoteHostCandidate]
    let diagnostics: RemoteHostDiscoveryDiagnostics
}

enum RemoteHostDiscoveryError: Error, Equatable, LocalizedError {
    case overallTimeout
    case invalidResponse
    case httpStatus(Int)
    case selectedHostChanged
    case buildIdentityCollision(String)

    var errorDescription: String? {
        switch self {
        case .overallTimeout:
            "Host discovery timed out after 15 seconds."
        case .invalidResponse:
            "A RepoPrompt discovery response was invalid."
        case let .httpStatus(status):
            "RepoPrompt discovery returned HTTP \(status)."
        case .selectedHostChanged:
            "The selected host identity changed; search again."
        case let .buildIdentityCollision(fingerprint):
            "Release and debug reported the same host identity (\(fingerprint)); reset the build-isolated host keys."
        }
    }
}

actor RemoteHostDiscoveryService {
    static let probeTimeout: TimeInterval = 2.5
    static let overallTimeout: TimeInterval = 15
    static let maximumResponseBytes = 32 * 1024
    static let maximumConcurrency = 16

    typealias CandidateProvider = @Sendable () async throws -> [TailscaleDiscoveryCandidate]
    typealias Probe = @Sendable (
        _ candidate: TailscaleDiscoveryCandidate,
        _ request: RemoteDiscoveryRequest
    ) async throws -> RemoteDiscoveryResponse
    typealias NowMilliseconds = @Sendable () -> Int64

    private let candidateProvider: CandidateProvider
    private let probe: Probe
    private let nowMilliseconds: NowMilliseconds

    init(
        candidateProvider: @escaping CandidateProvider = {
            try await TailscaleStatusClient().candidates()
        },
        probe: Probe? = nil,
        httpClient: RemoteHostHTTPClient = .shared,
        nowMilliseconds: @escaping NowMilliseconds = {
            Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        }
    ) {
        self.candidateProvider = candidateProvider
        self.nowMilliseconds = nowMilliseconds
        self.probe = probe ?? { candidate, request in
            let body = try JSONEncoder().encode(request)
            let response = try await httpClient.postJSON(
                to: candidate.origin.endpoint(path: "/.well-known/repoprompt/remote-pairing/v1"),
                body: body,
                timeout: Self.probeTimeout,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            guard response.finalURL == candidate.origin.endpoint(
                path: "/.well-known/repoprompt/remote-pairing/v1"
            ) else {
                throw RemoteHostHTTPClientError.redirected
            }
            guard response.statusCode == 200 else {
                throw RemoteHostDiscoveryError.httpStatus(response.statusCode)
            }
            do {
                return try JSONDecoder().decode(RemoteDiscoveryResponse.self, from: response.body)
            } catch {
                throw RemoteHostDiscoveryError.invalidResponse
            }
        }
    }

    func search() async throws -> RemoteHostDiscoveryResult {
        let candidates = try await candidateProvider()
        return try await withThrowingTaskGroup(of: RemoteHostDiscoveryResult.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await Self.probeAll(
                    candidates: candidates,
                    probe: self.probe,
                    nowMilliseconds: self.nowMilliseconds
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.overallTimeout))
                throw RemoteHostDiscoveryError.overallTimeout
            }
            guard let result = try await group.next() else {
                throw RemoteHostDiscoveryError.overallTimeout
            }
            group.cancelAll()
            return result
        }
    }

    func revalidateForPairing(_ selected: VerifiedRemoteHostCandidate) async throws -> RemotePairingPayload {
        let route = TailscaleDiscoveryCandidate(
            peerID: selected.tailscalePeerID,
            peerDisplayName: selected.tailscalePeerName,
            peerDNSName: selected.tailscaleDNSName,
            peerIPv4: selected.tailscaleIPv4,
            channel: selected.channel,
            origin: selected.origin
        )
        let request = try RemoteDiscoveryRequest.make(channel: selected.channel)
        let response = try await probe(route, request)
        try RemoteDiscoveryVerifier.verify(
            response,
            request: request,
            expectedOrigin: selected.origin,
            nowMs: nowMilliseconds()
        )
        guard response.origin == selected.origin,
              response.channel == selected.channel,
              response.hostFingerprint == selected.hostFingerprint
        else {
            throw RemoteHostDiscoveryError.selectedHostChanged
        }
        return try RemotePairingPayload(verifiedDiscovery: response)
    }

    private static func probeAll(
        candidates: [TailscaleDiscoveryCandidate],
        probe: @escaping Probe,
        nowMilliseconds: @escaping NowMilliseconds
    ) async throws -> RemoteHostDiscoveryResult {
        if candidates.isEmpty {
            return RemoteHostDiscoveryResult(
                hosts: [],
                diagnostics: .init(candidateCount: 0, verifiedCount: 0, failedProbeCount: 0)
            )
        }
        var nextIndex = 0
        var verified: [VerifiedRemoteHostCandidate] = []
        var failed = 0

        await withTaskGroup(of: Result<VerifiedRemoteHostCandidate, Error>.self) { group in
            func add(_ candidate: TailscaleDiscoveryCandidate) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let request = try RemoteDiscoveryRequest.make(channel: candidate.channel)
                        let response = try await probe(candidate, request)
                        try RemoteDiscoveryVerifier.verify(
                            response,
                            request: request,
                            expectedOrigin: candidate.origin,
                            nowMs: nowMilliseconds()
                        )
                        return .success(VerifiedRemoteHostCandidate(
                            tailscalePeerID: candidate.peerID,
                            tailscalePeerName: candidate.peerDisplayName,
                            tailscaleDNSName: candidate.peerDNSName,
                            tailscaleIPv4: candidate.peerIPv4,
                            channel: response.channel,
                            origin: response.origin,
                            signedHostName: response.hostName,
                            hostFingerprint: response.hostFingerprint,
                            hostPublicKey: response.hostPublicKey,
                            bundleID: response.bundleID,
                            marketingVersion: response.marketingVersion,
                            buildVersion: response.buildVersion,
                            capabilities: response.capabilities
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            while nextIndex < min(candidates.count, maximumConcurrency) {
                add(candidates[nextIndex])
                nextIndex += 1
            }
            while let result = await group.next() {
                switch result {
                case let .success(host):
                    verified.append(host)
                case .failure:
                    failed += 1
                }
                if nextIndex < candidates.count {
                    add(candidates[nextIndex])
                    nextIndex += 1
                }
            }
        }
        try Task.checkCancellation()

        var fingerprintsByChannel: [String: Set<RemoteControlBuildChannel>] = [:]
        for host in verified {
            fingerprintsByChannel[host.hostFingerprint, default: []].insert(host.channel)
        }
        if let collision = fingerprintsByChannel.first(where: { $0.value.count > 1 })?.key {
            throw RemoteHostDiscoveryError.buildIdentityCollision(collision)
        }

        var unique: [String: VerifiedRemoteHostCandidate] = [:]
        for host in verified.sorted(by: { $0.origin.string < $1.origin.string }) {
            let key = "\(host.hostFingerprint)|\(host.channel.rawValue)"
            if unique[key] == nil { unique[key] = host }
        }
        let hosts = unique.values.sorted {
            if $0.signedHostName.localizedCaseInsensitiveCompare($1.signedHostName) == .orderedSame {
                return $0.origin.string < $1.origin.string
            }
            return $0.signedHostName.localizedCaseInsensitiveCompare($1.signedHostName) == .orderedAscending
        }
        return RemoteHostDiscoveryResult(
            hosts: hosts,
            diagnostics: .init(
                candidateCount: candidates.count,
                verifiedCount: hosts.count,
                failedProbeCount: failed
            )
        )
    }
}
