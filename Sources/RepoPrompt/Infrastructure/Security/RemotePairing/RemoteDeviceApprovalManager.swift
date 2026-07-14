import AppKit
import Combine
import Foundation

struct RemoteDeviceApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let deviceID: String
    let displayName: String
    let devicePublicKeyFingerprint: String
    let requestedScopes: Set<RemoteScope>
    let hostFingerprint: String
    let windowID: Int?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        deviceID: String,
        displayName: String,
        devicePublicKeyFingerprint: String,
        requestedScopes: Set<RemoteScope>,
        hostFingerprint: String,
        windowID: Int?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.deviceID = deviceID
        self.displayName = displayName
        self.devicePublicKeyFingerprint = devicePublicKeyFingerprint
        self.requestedScopes = requestedScopes
        self.hostFingerprint = hostFingerprint
        self.windowID = windowID
        self.createdAt = createdAt
    }
}

enum RemoteDeviceApprovalResult: Equatable {
    case approved(grantedScopes: Set<RemoteScope>)
    case denied
    case cancelled
    case targetStale

    var grantedScopes: Set<RemoteScope>? {
        guard case let .approved(scopes) = self else { return nil }
        return scopes
    }

    var isApproved: Bool {
        grantedScopes != nil
    }
}

@MainActor
final class RemoteDeviceApprovalManager: ObservableObject {
    static let shared = RemoteDeviceApprovalManager()

    typealias BringWindowToFront = @MainActor @Sendable (_ windowID: Int?) -> Void

    @Published private(set) var pendingRequest: RemoteDeviceApprovalRequest?
    @Published var isApprovalOverlayVisible = false

    private var pendingQueue: [(RemoteDeviceApprovalRequest, CheckedContinuation<RemoteDeviceApprovalResult, Never>)] = []
    private var currentContinuation: CheckedContinuation<RemoteDeviceApprovalResult, Never>?
    private let bringWindowToFront: BringWindowToFront

    init(bringWindowToFront: @escaping BringWindowToFront = { windowID in
        RemoteDeviceApprovalManager.defaultBringWindowToFront(windowID: windowID)
    }) {
        self.bringWindowToFront = bringWindowToFront
    }

    func requestApproval(for request: RemoteDeviceApprovalRequest) async -> RemoteDeviceApprovalResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }

                if pendingRequest != nil {
                    pendingQueue.append((request, continuation))
                    return
                }

                pendingRequest = request
                currentContinuation = continuation
                isApprovalOverlayVisible = true

                bringWindowToFront(request.windowID)
                if let app = NSApp, !app.isActive {
                    app.requestUserAttention(.criticalRequest)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(requestID: request.id)
            }
        }
    }

    func resolveApproval(allow: Bool, grantedScopes: Set<RemoteScope>? = nil) {
        guard let request = pendingRequest,
              let continuation = currentContinuation
        else {
            return
        }

        let resolvedScopes = (grantedScopes ?? request.requestedScopes).intersection(request.requestedScopes)
        let result: RemoteDeviceApprovalResult = allow && !resolvedScopes.isEmpty
            ? .approved(grantedScopes: resolvedScopes)
            : .denied

        continuation.resume(returning: result)
        currentContinuation = nil
        pendingRequest = nil
        isApprovalOverlayVisible = false
        processNextQueuedRequest()
    }

    func cancelPending(requestID: UUID) {
        if pendingRequest?.id == requestID {
            currentContinuation?.resume(returning: .cancelled)
            currentContinuation = nil
            pendingRequest = nil
            isApprovalOverlayVisible = false
            processNextQueuedRequest()
            return
        }

        guard let index = pendingQueue.firstIndex(where: { $0.0.id == requestID }) else { return }
        let (_, continuation) = pendingQueue.remove(at: index)
        continuation.resume(returning: .cancelled)
    }

    func cancelPending(forWindowID windowID: Int) {
        if pendingRequest?.windowID == windowID {
            currentContinuation?.resume(returning: .targetStale)
            currentContinuation = nil
            pendingRequest = nil
            isApprovalOverlayVisible = false
        }

        var remainingQueue: [(RemoteDeviceApprovalRequest, CheckedContinuation<RemoteDeviceApprovalResult, Never>)] = []
        for (request, continuation) in pendingQueue {
            if request.windowID == windowID {
                continuation.resume(returning: .targetStale)
            } else {
                remainingQueue.append((request, continuation))
            }
        }
        pendingQueue = remainingQueue

        if pendingRequest == nil {
            processNextQueuedRequest()
        }
    }

    func cancelAllPending() {
        currentContinuation?.resume(returning: .cancelled)
        for (_, continuation) in pendingQueue {
            continuation.resume(returning: .cancelled)
        }
        currentContinuation = nil
        pendingRequest = nil
        pendingQueue = []
        isApprovalOverlayVisible = false
    }

    #if DEBUG
        var pendingQueueCountForTesting: Int {
            pendingQueue.count
        }
    #endif

    private func processNextQueuedRequest() {
        guard pendingRequest == nil, !pendingQueue.isEmpty else { return }
        let (request, continuation) = pendingQueue.removeFirst()
        pendingRequest = request
        currentContinuation = continuation
        isApprovalOverlayVisible = true
        bringWindowToFront(request.windowID)
    }

    private static func defaultBringWindowToFront(windowID: Int?) {
        guard let windowID,
              let windowState = WindowStatesManager.shared.window(withID: windowID),
              let window = windowState.nsWindow
        else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }
}
