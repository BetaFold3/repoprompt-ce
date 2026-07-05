import Foundation

struct GatewayRevokedDeviceTransitionTracker {
    private var handled: Set<String> = []

    mutating func devicesRequiringTeardown(
        revoked: Set<String>,
        tornDown: Set<String>,
        snapshot: GatewayTrustSnapshot
    ) -> [String] {
        // Devices that re-appear as active (re-paired) leave `handled`, so a later
        // re-revocation fires teardown again. Devices absent from the snapshot stay
        // handled because they have not reappeared as trusted.
        handled = handled.filter { deviceID in
            snapshot.devices[deviceID].map(\.isRevoked) ?? true
        }

        let toAct = tornDown.union(revoked.subtracting(handled))
        handled.formUnion(toAct)
        return toAct.sorted()
    }
}
