import Foundation

enum RemotePairingApprovalRouterError: Error, Equatable {
    case approvalWindowUnavailable
    case approvalWindowAmbiguous
    case approvalTargetStale
    case cancelled
}

@MainActor
protocol RemotePairingApprovalRouting: AnyObject {
    func requestApproval(
        deviceID: String,
        displayName: String,
        devicePublicKeyFingerprint: String,
        requestedScopes: Set<RemoteScope>,
        hostFingerprint: String
    ) async throws -> Set<RemoteScope>?
}

@MainActor
final class RemotePairingApprovalRouter: RemotePairingApprovalRouting {
    static let shared = RemotePairingApprovalRouter(
        windowStates: .shared,
        approvalManager: .shared
    )

    private let windowStates: WindowStatesManager
    private let approvalManager: RemoteDeviceApprovalManager

    init(
        windowStates: WindowStatesManager,
        approvalManager: RemoteDeviceApprovalManager
    ) {
        self.windowStates = windowStates
        self.approvalManager = approvalManager
    }

    func requestApproval(
        deviceID: String,
        displayName: String,
        devicePublicKeyFingerprint: String,
        requestedScopes: Set<RemoteScope>,
        hostFingerprint: String
    ) async throws -> Set<RemoteScope>? {
        let windows = windowStates.allWindows.filter { !$0.isClosing }
        guard !windows.isEmpty else {
            throw RemotePairingApprovalRouterError.approvalWindowUnavailable
        }
        guard windows.count == 1, let window = windows.first else {
            throw RemotePairingApprovalRouterError.approvalWindowAmbiguous
        }
        let request = RemoteDeviceApprovalRequest(
            deviceID: deviceID,
            displayName: displayName,
            devicePublicKeyFingerprint: devicePublicKeyFingerprint,
            requestedScopes: requestedScopes,
            hostFingerprint: hostFingerprint,
            windowID: window.windowID
        )
        let result = await approvalManager.requestApproval(for: request)
        switch result {
        case let .approved(grantedScopes):
            return grantedScopes
        case .denied:
            return nil
        case .targetStale:
            throw RemotePairingApprovalRouterError.approvalTargetStale
        case .cancelled:
            throw RemotePairingApprovalRouterError.cancelled
        }
    }
}
