import CryptoKit
import Foundation
import RepoPromptRemoteWire

struct RemoteHostPairingHTTPResponse: Equatable {
    var statusCode: Int
    var data: Data
}

protocol RemoteHostPairingTransport: Sendable {
    func postJSON(
        to url: URL,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> RemoteHostPairingHTTPResponse
}

struct URLSessionRemoteHostPairingTransport: RemoteHostPairingTransport, @unchecked Sendable {
    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postJSON(
        to url: URL,
        body: [String: JSONValue],
        timeout: TimeInterval
    ) async throws -> RemoteHostPairingHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteHostPairingError.invalidResponse("Pairing endpoint returned a non-HTTP response.")
        }
        return RemoteHostPairingHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

enum RemoteHostPairingError: Error, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)
    case hostIdentityMismatch(String)
    case consentDenied(String)
    case timeout
    case httpError(statusCode: Int, code: String?, message: String?)
    case transport(String)
}

struct RemoteHostPairingClient {
    static let beginTimeout: TimeInterval = 20
    /// Must exceed the gateway relay's 180s consent timeout so denial can surface first.
    static let completeTimeout: TimeInterval = 185
    static let defaultRequestedScopes: Set<String> = [
        RemoteScope.sessionsObserve.rawValue,
        RemoteScope.sessionsOperate.rawValue,
        RemoteScope.interactionsRespond.rawValue
    ]

    private let transport: any RemoteHostPairingTransport
    private let keyStore: RemoteClientKeyStore
    private let now: @Sendable () -> Date

    init(
        transport: any RemoteHostPairingTransport = URLSessionRemoteHostPairingTransport(),
        keyStore: RemoteClientKeyStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.now = now
    }

    func pair(
        payload: RemotePairingPayload,
        displayName: String,
        scopes: Set<String> = RemoteHostPairingClient.defaultRequestedScopes
    ) async throws -> PairedHostRecord {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            throw RemoteHostPairingError.invalidRequest("displayName must not be empty.")
        }
        let requestedScopes = try validatedScopes(scopes)

        let begin = try await beginPairing(payload: payload)
        try verifyBeginResponse(begin, against: payload)

        let deviceKey = P256.Signing.PrivateKey()
        let publicKeyRaw = deviceKey.publicKey.rawRepresentation
        let deviceID = try RemotePairingCrypto.deviceID(forRawPublicKey: publicKeyRaw)
        let proofPayload = RemotePairingDeviceChallengeV1(
            pairingID: begin.pairingID,
            challenge: begin.challenge,
            deviceID: deviceID,
            displayName: trimmedDisplayName,
            publicKeyRawRepresentation: publicKeyRaw,
            scopes: requestedScopes
        )
        let proof = try RemotePairingProof.signDeviceChallenge(proofPayload, deviceSigner: deviceKey)

        let complete = try await completePairing(
            payload: payload,
            begin: begin,
            displayName: trimmedDisplayName,
            deviceID: deviceID,
            publicKeyRaw: publicKeyRaw,
            proof: proof,
            requestedScopes: requestedScopes
        )
        let record = try record(
            from: complete,
            payload: payload,
            expectedDeviceID: deviceID,
            expectedPublicKeyRaw: publicKeyRaw
        )
        try keyStore.save(deviceKey, forHostID: payload.hostFingerprint)
        return record
    }

    private func beginPairing(payload: RemotePairingPayload) async throws -> BeginPairingResponse {
        let data = try await post(
            endpoint(base: payload.gatewayURL, pathComponents: ["api", "pair", "begin"]),
            body: [:],
            timeout: Self.beginTimeout
        )
        do {
            return try JSONDecoder().decode(BeginPairingResponse.self, from: data)
        } catch {
            throw RemoteHostPairingError.invalidResponse("Pairing begin response is malformed.")
        }
    }

    private func completePairing(
        payload: RemotePairingPayload,
        begin: BeginPairingResponse,
        displayName: String,
        deviceID: String,
        publicKeyRaw: Data,
        proof: Data,
        requestedScopes: Set<String>
    ) async throws -> CompletePairingResponse {
        let data = try await post(
            endpoint(base: payload.gatewayURL, pathComponents: ["api", "pair", "complete"]),
            body: [
                "pairing_id": .string(begin.pairingID.uuidString),
                "display_name": .string(displayName),
                "device_id": .string(deviceID),
                "public_key": .string(publicKeyRaw.base64EncodedString()),
                "proof": .string(proof.base64EncodedString()),
                "scopes": .array(requestedScopes.sorted().map(JSONValue.string))
            ],
            timeout: Self.completeTimeout
        )
        do {
            return try JSONDecoder().decode(CompletePairingResponse.self, from: data)
        } catch {
            throw RemoteHostPairingError.invalidResponse("Pairing complete response is malformed.")
        }
    }

    private func post(_ url: URL, body: [String: JSONValue], timeout: TimeInterval) async throws -> Data {
        let response: RemoteHostPairingHTTPResponse
        do {
            response = try await transport.postJSON(to: url, body: body, timeout: timeout)
        } catch let error as RemoteHostPairingError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw RemoteHostPairingError.timeout
        } catch {
            throw RemoteHostPairingError.transport(error.localizedDescription)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            throw error(for: response)
        }
        return response.data
    }

    private func verifyBeginResponse(_ begin: BeginPairingResponse, against payload: RemotePairingPayload) throws {
        guard !begin.challenge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteHostPairingError.invalidResponse("Pairing begin response did not include a challenge.")
        }
        guard begin.hostPublicKey == payload.hostPublicKey,
              begin.hostFingerprint == payload.hostFingerprint,
              let computedFingerprint = RemotePairingCrypto.fingerprint(forRawPublicKey: begin.hostPublicKey),
              computedFingerprint == payload.hostFingerprint
        else {
            throw RemoteHostPairingError.hostIdentityMismatch(
                "Pairing begin host key did not match the pinned pairing payload."
            )
        }
    }

    private func record(
        from complete: CompletePairingResponse,
        payload: RemotePairingPayload,
        expectedDeviceID: String,
        expectedPublicKeyRaw: Data
    ) throws -> PairedHostRecord {
        guard complete.ok != false else {
            throw RemoteHostPairingError.invalidResponse("Pairing complete response was not ok.")
        }
        let device = complete.device
        guard device.id == expectedDeviceID else {
            throw RemoteHostPairingError.invalidResponse("Pairing complete returned an unexpected device id.")
        }
        guard device.publicKey == expectedPublicKeyRaw else {
            throw RemoteHostPairingError.invalidResponse("Pairing complete returned an unexpected device public key.")
        }
        if let fingerprint = device.publicKeyFingerprint,
           fingerprint != RemotePairingCrypto.fingerprint(forRawPublicKey: expectedPublicKeyRaw)
        {
            throw RemoteHostPairingError.invalidResponse("Pairing complete returned an unexpected device public key fingerprint.")
        }
        let grantedScopes = Set(device.scopes)
        guard !grantedScopes.isEmpty,
              grantedScopes.allSatisfy({ scope in
                  scope.trimmingCharacters(in: .whitespacesAndNewlines) == scope && !scope.isEmpty
              })
        else {
            throw RemoteHostPairingError.invalidResponse("Pairing complete returned no granted scopes.")
        }

        let pairedAt = parseISO8601(device.createdAt) ?? now()
        return PairedHostRecord(
            id: payload.hostFingerprint,
            displayName: payload.hostDisplayName,
            gatewayURL: payload.gatewayURL,
            hostPublicKey: payload.hostPublicKey,
            deviceID: device.id,
            grantedScopes: grantedScopes,
            pairedAt: pairedAt,
            lastCounter: device.counterFloor ?? 0
        )
    }

    private func validatedScopes(_ scopes: Set<String>) throws -> Set<String> {
        guard !scopes.isEmpty else {
            throw RemoteHostPairingError.invalidRequest("scopes must not be empty.")
        }
        let trimmed = Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard trimmed.count == scopes.count,
              trimmed.allSatisfy({ !$0.isEmpty })
        else {
            throw RemoteHostPairingError.invalidRequest("scopes must be non-empty raw strings without surrounding whitespace.")
        }
        guard trimmed.isSubset(of: Self.defaultRequestedScopes) else {
            throw RemoteHostPairingError.invalidRequest("Remote client pairing can request only v1 session operation scopes.")
        }
        return trimmed
    }

    private func endpoint(base: URL, pathComponents: [String]) -> URL {
        pathComponents.reduce(base) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    private func error(for response: RemoteHostPairingHTTPResponse) -> RemoteHostPairingError {
        let object = try? JSONDecoder().decode(JSONValue.self, from: response.data).objectValue
        let message = object?["error"]?.stringValue
            ?? object?["message"]?.stringValue
            ?? object?["text"]?.stringValue
        let code = object?["code"]?.stringValue
        if response.statusCode == 400,
           let message,
           message.localizedCaseInsensitiveContains("denied") || message.localizedCaseInsensitiveContains("rejected")
        {
            return .consentDenied(message)
        }
        return .httpError(statusCode: response.statusCode, code: code, message: message)
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }
}

private struct BeginPairingResponse: Decodable {
    var ok: Bool?
    var pairingID: UUID
    var challenge: String
    var hostPublicKey: Data
    var hostFingerprint: String

    enum CodingKeys: String, CodingKey {
        case ok
        case pairingID = "pairing_id"
        case challenge
        case hostPublicKey = "host_public_key"
        case hostFingerprint = "host_fingerprint"
    }
}

private struct CompletePairingResponse: Decodable {
    var ok: Bool?
    var device: CompletePairingDevice
}

private struct CompletePairingDevice: Decodable {
    var id: String
    var displayName: String?
    var publicKey: Data
    var publicKeyFingerprint: String?
    var scopes: [String]
    var createdAt: String?
    var counterFloor: UInt64?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case publicKey = "public_key"
        case publicKeyFingerprint = "public_key_fingerprint"
        case scopes
        case createdAt = "created_at"
        case counterFloor = "counter_floor"
    }
}
