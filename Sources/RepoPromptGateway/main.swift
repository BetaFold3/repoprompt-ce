import Darwin
import Dispatch
import Foundation
import Logging
import RepoPromptShared

private enum GatewayTerminationReason: CustomStringConvertible {
    case signal
    case parentExited(Int32)
    case appLinkFailed(String)

    var description: String {
        switch self {
        case .signal:
            "signal"
        case let .parentExited(pid):
            "parent app pid \(pid) exited"
        case let .appLinkFailed(reason):
            "app link failed: \(reason)"
        }
    }
}

private func waitForTermination(parentPID: Int32?, appLink: AppLinkSession) async -> GatewayTerminationReason {
    await withCheckedContinuation { continuation in
        let gate = GatewayTerminationGate(continuation: continuation)
        let signals = [SIGINT, SIGTERM]
        for signalNumber in signals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                gate.resume(.signal)
            }
            gate.retain(source)
            source.resume()
        }
        if let parentPID {
            gate.retain(Task {
                await waitForParentExit(parentPID)
                gate.resume(.parentExited(parentPID))
            })
        }
        gate.retain(Task {
            for await state in appLink.stateEvents {
                if case let .failed(reason) = state {
                    gate.resume(.appLinkFailed(reason))
                    return
                }
            }
        })
    }
}

private func waitForParentExit(_ parentPID: Int32) async {
    while !Task.isCancelled {
        if getppid() != parentPID { return }
        if kill(parentPID, 0) != 0, errno == ESRCH { return }
        try? await Task.sleep(for: .seconds(2))
    }
}

private final class GatewayTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GatewayTerminationReason, Never>?
    private var sources: [DispatchSourceSignal] = []
    private var tasks: [Task<Void, Never>] = []

    init(continuation: CheckedContinuation<GatewayTerminationReason, Never>) {
        self.continuation = continuation
    }

    func retain(_ source: DispatchSourceSignal) {
        lock.lock()
        sources.append(source)
        lock.unlock()
    }

    func retain(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func resume(_ reason: GatewayTerminationReason) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let retainedSources = sources
        sources.removeAll()
        let retainedTasks = tasks
        tasks.removeAll()
        lock.unlock()

        retainedSources.forEach { $0.cancel() }
        retainedTasks.forEach { $0.cancel() }
        continuation.resume(returning: reason)
    }
}

LoggingSystem.bootstrap { label in
    StreamLogHandler.standardError(label: label)
}

var configuredLogger = Logger(label: "com.repoprompt.gateway")
configuredLogger.logLevel = .info
let logger = configuredLogger

do {
    let configuration = try GatewayConfiguration.parse()
    let gatewayPID = getpid()
    var processLeaseWritten = false
    defer {
        if processLeaseWritten {
            RemoteGatewayProcessLeaseFile.removeIfOwned(fileURL: configuration.processLeaseFileURL, pid: gatewayPID)
        }
    }
    logger.notice("Starting RepoPrompt gateway on \(configuration.listenAddressDescription)")

    let ledgerStoreURL = configuration.appSupportRootURL
        .appendingPathComponent("RemoteGateway", isDirectory: true)
        .appendingPathComponent("ledger", isDirectory: true)
        .appendingPathComponent("command-ledger-v1.jsonl")
    let ledgerStore = try CommandLedgerStore(fileURL: ledgerStoreURL)
    let ledger = try CommandLedger(store: ledgerStore)
    let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)

    let usedTicketStoreURL = configuration.appSupportRootURL
        .appendingPathComponent("RemoteGateway", isDirectory: true)
        .appendingPathComponent("auth", isDirectory: true)
        .appendingPathComponent("used-tickets-v1.jsonl")
    let usedTicketStore = try UsedTicketStore(fileURL: usedTicketStoreURL)
    let authenticator = DeviceAuthenticator(usedTicketStore: usedTicketStore)

    // Web Push (M5): gateway-owned VAPID keypair and per-device subscriptions.
    let pushDirectoryURL = configuration.appSupportRootURL
        .appendingPathComponent("RemoteGateway", isDirectory: true)
        .appendingPathComponent("push", isDirectory: true)
    let vapidKeyStore = VAPIDKeyStore(fileURL: pushDirectoryURL.appendingPathComponent("vapid-key-v1.json"))
    let vapidPrivateKey = try vapidKeyStore.loadOrCreate()
    let pushSubscriptionStore = try WebPushSubscriptionStore(
        fileURL: pushDirectoryURL.appendingPathComponent("push-subscriptions-v1.json")
    )

    let appLink = AppLinkSession(
        config: configuration,
        logger: logger,
        maximumReconnectAttempts: configuration.appLinkMaximumReconnectAttempts
    )
    await appLink.start()

    let appLinkPool = AppLinkPool(configuration: configuration, logger: logger)

    let webPushService = WebPushService(
        pushSender: vapidPrivateKey,
        subscriptionStore: pushSubscriptionStore,
        auditLog: auditLog,
        logger: logger
    )

    let watchManager = SessionWatchManager(
        appLink: appLink,
        appLinkPool: appLinkPool,
        pushNotifier: webPushService,
        logger: logger
    )
    await watchManager.start()

    let runtime = RemoteGatewayRuntime(
        appLink: appLink,
        ledger: ledger,
        watchManager: watchManager,
        auditLog: auditLog,
        logger: logger,
        appLinkPool: appLinkPool,
        pushSubscriptionStore: pushSubscriptionStore
    )
    await watchManager.setWindowResolver { deviceID, sessionID in
        await runtime.resolveSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID)
    }

    let pairingRelay = GatewayPairingRelay(appLink: appLink, auditLog: auditLog, logger: logger)

    let httpServer = GatewayHTTPServer(
        configuration: configuration,
        runtime: runtime,
        authenticator: authenticator,
        appLinkPool: appLinkPool,
        auditLog: auditLog,
        pairingRelay: pairingRelay,
        vapidPublicKeyBase64URL: VAPIDKeyStore.publicKeyBase64URL(for: vapidPrivateKey),
        logger: logger
    )

    let revokedTransitionState = GatewayRevokedDeviceTransitionState()
    let trustRefreshCoordinator = GatewayTrustRefreshCoordinator(
        fetchSnapshot: {
            try await GatewayTrustSynchronizer.fetchSnapshot(appLink: appLink)
        },
        applySnapshot: { snapshot in
            let revokedDeviceIDs = await authenticator.updateTrust(snapshot)
            let tornDown = await appLinkPool.applyTrustSnapshot(snapshot)
            let teardownDeviceIDs = await revokedTransitionState.devicesRequiringTeardown(
                revoked: Set(revokedDeviceIDs),
                tornDown: Set(tornDown),
                snapshot: snapshot
            )
            for deviceID in teardownDeviceIDs {
                let code = snapshot.devices[deviceID]?.isRevoked == true ? "device_revoked" : "device_unpaired"
                await runtime.teardownRevokedDevice(deviceID: deviceID, reason: code)
                httpServer.closeConnections(forDevice: deviceID)
                auditLog.recordBestEffort(RemoteAuditRecord(
                    deviceID: deviceID,
                    requestID: nil,
                    op: "trust_sync",
                    sessionID: nil,
                    outcome: tornDown.contains(deviceID) ? "revoked_teardown" : "revoked_connection_teardown",
                    code: code
                ))
            }
            // Push subscriptions are removed on revocation/unpairing (M5).
            for deviceID in pushSubscriptionStore.deviceIDs {
                let device = snapshot.devices[deviceID]
                if device == nil || device?.isRevoked == true {
                    if (try? pushSubscriptionStore.removeSubscription(forDevice: deviceID)) == true {
                        await watchManager.pushEligibilityChanged(deviceID: deviceID)
                        auditLog.recordBestEffort(RemoteAuditRecord(
                            deviceID: deviceID,
                            requestID: nil,
                            op: "trust_sync",
                            sessionID: nil,
                            outcome: "push_subscription_removed",
                            code: "device_revoked"
                        ))
                    }
                }
            }
        }
    )
    await pairingRelay.setPostCompletePairingAction {
        do {
            try await trustRefreshCoordinator.refresh()
        } catch is CancellationError {
            // Gateway shutdown owns cancellation; pairing HTTP work will be
            // closed by server teardown.
        } catch {
            logger.warning("Post-pairing gateway trust refresh failed: \(String(describing: error))")
        }
    }
    try await httpServer.start()
    try RemoteGatewayProcessLeaseFile.write(
        RemoteGatewayProcessLease(
            pid: gatewayPID,
            parentPID: configuration.parentPID,
            executablePath: CommandLine.arguments.first,
            bindHost: configuration.bindHost,
            port: configuration.port,
            appSupportRoot: configuration.appSupportRootURL.path
        ),
        to: configuration.processLeaseFileURL
    )
    processLeaseWritten = true

    // Trust sync: the gateway holds only the host public key and paired-device
    // public keys/tickets; revocations tear down per-device app links.
    let trustSyncTask = Task {
        while !Task.isCancelled {
            do {
                try await trustRefreshCoordinator.refresh()
            } catch {
                if !Task.isCancelled {
                    logger.warning("Gateway trust sync failed: \(String(describing: error))")
                }
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    let terminationReason = await waitForTermination(parentPID: configuration.parentPID, appLink: appLink)
    logger.notice("Stopping RepoPrompt gateway (\(terminationReason.description))")
    trustSyncTask.cancel()
    await trustRefreshCoordinator.stop()
    await httpServer.shutdown()
    await watchManager.shutdown()
    await appLinkPool.shutdownAll()
    await appLink.shutdown()
} catch {
    logger.error("RepoPrompt gateway failed: \(String(describing: error))")
    fputs("repoprompt-gateway: \(String(describing: error))\n", stderr)
    exit(EXIT_FAILURE)
}
