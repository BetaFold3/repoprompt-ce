import CryptoKit
import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class RemoteFrameSignerTests: XCTestCase {
    func testSignerOutputVerifiesUnderGatewayDeviceAuthenticator() async throws {
        let root = try GatewayTestHelpers.temporaryRoot("remote-frame-signer")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let hostSigner = P256.Signing.PrivateKey()
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:aabbccdd")
        let trust = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, false)]
        )
        let authenticator = try DeviceAuthenticator(
            usedTicketStore: GatewayAuthTestSupport.makeUsedTicketStore(root: root),
            trust: trust
        )
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let connectionID = UUID()
        var signer = RemoteFrameSigner(
            deviceSigner: device.signer,
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            lastCounter: 0
        )

        let signedHello = try signer.sign(
            RemoteClientFrame(type: "hello", payload: .object(["ticket": ticket.jsonValue])),
            nowMs: currentEpochMilliseconds()
        )
        let helloFrame = try RemoteWireProtocol.decodeClientFrame(from: signedHello.data)
        let admitted = try await authenticator.admitHello(
            rawFrame: signedHello.data,
            frame: helloFrame,
            connectionID: connectionID
        )

        XCTAssertEqual(admitted.deviceID, device.deviceID)
        XCTAssertEqual(admitted.ticketID, ticket.ticketID)

        let signedPing = try signer.sign(
            RemoteClientFrame(
                type: "ping",
                requestID: "req-ping",
                payload: .object(["echo": .string("ok")])
            ),
            nowMs: currentEpochMilliseconds()
        )
        let pingFrame = try RemoteWireProtocol.decodeClientFrame(from: signedPing.data)
        let verified = try await authenticator.verifyFrame(
            rawFrame: signedPing.data,
            frame: pingFrame,
            connectionID: connectionID
        )

        XCTAssertEqual(verified.deviceID, device.deviceID)
        XCTAssertGreaterThan(signedPing.signature.counter, signedHello.signature.counter)
    }
}
