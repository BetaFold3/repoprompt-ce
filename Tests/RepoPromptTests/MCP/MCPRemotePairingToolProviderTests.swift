import CryptoKit
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPRemotePairingToolProviderTests: XCTestCase {
    func testNonGatewayCallerIsRejectedEvenWithGatewayClientName() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let deps = makeDependencies(isGateway: false, identityStore: store, approvalManager: manager)

        await XCTAssertThrowsErrorAsync {
            try await MCPRemotePairingToolProvider.execute(
                args: ["op": .string(RemotePairingOperation.listDevices.rawValue)],
                context: MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1),
                dependencies: deps
            )
        }
    }

    func testCompletePairingRequiresApprovalBeforePersistingDevice() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let challengeStore = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" })
        let now = Date(timeIntervalSince1970: 10000)
        let deps = makeDependencies(
            identityStore: store,
            approvalManager: manager,
            challengeStore: challengeStore,
            now: { now }
        )
        let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 7)

        let begin = try await MCPRemotePairingToolProvider.execute(
            args: ["op": .string(RemotePairingOperation.beginPairing.rawValue)],
            context: context,
            dependencies: deps
        )
        let beginObject = try XCTUnwrap(begin.objectValue)
        let pairingID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(beginObject["pairing_id"]?.stringValue)))
        let challenge = try XCTUnwrap(beginObject["challenge"]?.stringValue)

        let deviceKey = P256.Signing.PrivateKey()
        let deviceID = try RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation)
        let requestedScopes: Set<RemoteScope> = [.sessionsObserve, .interactionsRespond]
        let proofPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge,
            deviceID: deviceID,
            displayName: "Test Phone",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: requestedScopes
        )
        let proof = try RemotePairingCrypto.signDeviceChallenge(payload: proofPayload, deviceSigner: deviceKey)

        let completeTask = Task { @MainActor () throws -> Value in
            try await MCPRemotePairingToolProvider.execute(
                args: [
                    "op": .string(RemotePairingOperation.completePairing.rawValue),
                    "pairing_id": .string(pairingID.uuidString),
                    "display_name": .string("Test Phone"),
                    "device_id": .string(deviceID),
                    "public_key": .string(deviceKey.publicKey.rawRepresentation.base64EncodedString()),
                    "proof": .string(proof.base64EncodedString()),
                    "scopes": .array(requestedScopes.sorted().map { .string($0.rawValue) })
                ],
                context: context,
                dependencies: deps
            )
        }

        await waitUntil { manager.pendingRequest?.deviceID == deviceID }
        XCTAssertNil(try store.device(id: deviceID))
        manager.resolveApproval(allow: true, grantedScopes: [.sessionsObserve])

        let result = try await completeTask.value
        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
        let stored = try XCTUnwrap(try store.device(id: deviceID))
        XCTAssertEqual(stored.scopes, [.sessionsObserve])
        XCTAssertNil(stored.revokedAt)
    }

    func testRevokeMarksDeviceRevokedAndClearsPushMetadata() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let now = Date(timeIntervalSince1970: 20000)
        let deps = makeDependencies(identityStore: store, approvalManager: manager, now: { now })
        let push = WebPushSubscriptionRecord(endpoint: "https://push.example", p256dh: "key", auth: "auth")
        let record = RemotePairingTestSupport.deviceRecord(id: "remote:feedface", pushSubscription: push)
        try store.upsertDevice(record)

        let result = try await MCPRemotePairingToolProvider.execute(
            args: [
                "op": .string(RemotePairingOperation.revokeDevice.rawValue),
                "device_id": .string(record.id)
            ],
            context: MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1),
            dependencies: deps
        )

        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["gateway_sync_required"]?.boolValue, true)
        let revoked = try XCTUnwrap(try store.device(id: record.id))
        XCTAssertEqual(revoked.revokedAt, now)
        XCTAssertNil(revoked.pushSubscription)
    }

    private func makeStore(url: URL) -> RemotePairingIdentityStore {
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        return RemotePairingIdentityStore(url: url, keychain: keychain)
    }

    private func makeDependencies(
        isGateway: Bool = true,
        identityStore: RemotePairingIdentityStore,
        approvalManager: RemoteDeviceApprovalManager,
        challengeStore: RemotePairingChallengeStore = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" }),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> MCPRemotePairingToolProvider.ExecutionDependencies {
        let connectionID = UUID()
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "repoprompt-gateway",
            windowID: 1
        )
        return MCPRemotePairingToolProvider.ExecutionDependencies(
            captureRequestMetadata: { metadata },
            isGatewayPrincipalConnection: { candidate in isGateway && candidate == connectionID },
            identityStore: identityStore,
            approvalManager: approvalManager,
            challengeStore: challengeStore,
            now: now
        )
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
