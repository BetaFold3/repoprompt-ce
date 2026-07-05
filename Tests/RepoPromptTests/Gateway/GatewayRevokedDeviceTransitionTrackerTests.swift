import CryptoKit
@testable import RepoPromptGateway
import XCTest

final class GatewayRevokedDeviceTransitionTrackerTests: XCTestCase {
    private let hostSigner = P256.Signing.PrivateKey()

    func testSameRevokedDeviceAcrossConsecutiveCyclesFiresOnce() {
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:revoked1")
        let snapshot = trustSnapshot(devices: [(device, true)])
        var tracker = GatewayRevokedDeviceTransitionTracker()

        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: snapshot
            ),
            [device.deviceID]
        )
        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: snapshot
            ),
            []
        )
    }

    func testTornDownDeviceAlwaysFiresEvenIfPreviouslyHandled() {
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:torn1")
        let snapshot = trustSnapshot(devices: [(device, true)])
        var tracker = GatewayRevokedDeviceTransitionTracker()

        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: snapshot
            ),
            [device.deviceID]
        )
        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [device.deviceID],
                snapshot: snapshot
            ),
            [device.deviceID]
        )
    }

    func testRepairedThenRevokedAgainFiresAgain() {
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:repair1")
        let revokedSnapshot = trustSnapshot(devices: [(device, true)])
        let activeSnapshot = trustSnapshot(devices: [(device, false)])
        var tracker = GatewayRevokedDeviceTransitionTracker()

        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: revokedSnapshot
            ),
            [device.deviceID]
        )
        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [],
                tornDown: [],
                snapshot: activeSnapshot
            ),
            []
        )
        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: revokedSnapshot
            ),
            [device.deviceID]
        )
    }

    func testAbsentDevicesStayHandledAndDoNotRefire() {
        let device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:absent1")
        let revokedSnapshot = trustSnapshot(devices: [(device, true)])
        let absentSnapshot = trustSnapshot(devices: [])
        var tracker = GatewayRevokedDeviceTransitionTracker()

        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: revokedSnapshot
            ),
            [device.deviceID]
        )
        XCTAssertEqual(
            tracker.devicesRequiringTeardown(
                revoked: [device.deviceID],
                tornDown: [],
                snapshot: absentSnapshot
            ),
            []
        )
    }

    private func trustSnapshot(
        devices: [(GatewayAuthTestSupport.TestDeviceIdentity, Bool)]
    ) -> GatewayTrustSnapshot {
        GatewayAuthTestSupport.trustSnapshot(hostSigner: hostSigner, devices: devices)
    }
}
