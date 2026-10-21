import AppKit
import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform

// Production environment of the two-stage quit / window-close coordinator (spec R4). The policy and
// its fences live in `AgentLifecycleShutdownCoordinator`; this file only binds it to windows, the
// recovery coordinator, the layout writer, the termination flags, and AppKit prompts.

@MainActor
extension WindowStatesManager {
    func makeLifecycleShutdownEnvironment() -> AgentLifecycleShutdownEnvironment {
        AgentLifecycleShutdownEnvironment(
            participants: { [weak self] scope in
                guard let self else { return [] }
                switch scope {
                case .application:
                    return allWindows.map(\.agentModeViewModel)
                case let .window(windowID):
                    return window(withID: windowID).map { [$0.agentModeViewModel] } ?? []
                }
            },
            beginApplicationRecoveryFreeze: {
                guard let coordinator = AgentRecoveryAppComposition.shared.coordinator else { return {} }
                let token = coordinator.beginShutdownFreeze(scope: .application)
                return { coordinator.endShutdownFreeze(token) }
            },
            preserveLayout: { [weak self] in
                guard let self else { return false }
                return await persistWindowSessionImmediately(reason: "appShouldTerminate").isPreserved
            },
            settleReleasedRecoveryInput: {
                guard let coordinator = AgentRecoveryAppComposition.shared.coordinator else { return [] }
                let unsaved = await coordinator.settleReleasedRetirements()
                guard !unsaved.isEmpty else { return [] }
                return [
                    "Input from \(unsaved.count == 1 ? "a closed session" : "\(unsaved.count) closed sessions") could not be saved. Restore or discard it from the recovery list first."
                ]
            },
            recordLaunchState: { state in
                guard let coordinator = AgentRecoveryAppComposition.shared.coordinator else {
                    return Task { true }
                }
                return coordinator.recordLaunchState(state)
            },
            authorizeCleanExit: {
                AgentRecoveryAppComposition.shared.coordinator?.authorizeCleanExit() ?? UUID()
            },
            recordCleanExit: { authorization in
                guard let coordinator = AgentRecoveryAppComposition.shared.coordinator else {
                    return Task { true }
                }
                return coordinator.recordCleanExit(authorization: authorization)
            },
            beginIrreversible: { [weak self] scope in
                guard let self else { return }
                switch scope {
                case .application:
                    signalTermination()
                    ProcessTermination.beginAppTerminationFastPath()
                    MCPBackgroundModeCoordinator.shared.resetForTermination()
                case let .window(windowID):
                    window(withID: windowID)?.beginClose()
                }
            },
            tearDownScope: { [weak self] scope in
                guard scope == .application else { return }
                await OhMyPiThinkingCapabilityResolver.shared.cancel(reason: .appTermination)
                // Stop dedicated CLI model polling so background refreshes cannot race shutdown.
                await CodexModelPollingService.shared.shutdown()
                await OpenCodeACPModelPollingService.shared.shutdown()
                await CursorACPModelPollingService.shared.shutdown()
                await self?.stopAllServers()
            },
            presentFailure: { [weak self] failure in
                guard let self else { return failure.stage == .preparation ? .cancel : .proceedAnyway }
                return await presentLifecycleShutdownFailure(failure)
            },
            dismissFailure: { [weak self] scope in
                guard let alert = self?.presentedLifecycleShutdownAlerts.removeValue(forKey: scope),
                      let parent = alert.window.sheetParent
                else { return }
                parent.endSheet(alert.window, returnCode: .cancel)
            },
            now: { ContinuousClock.now },
            sleepUntil: { expiry in try await Task.sleep(until: expiry, clock: .continuous) }
        )
    }

    /// Stage A: Retry / Cancel. Stage B: Retry / Quit (Close) Anyway; never Cancel.
    private func presentLifecycleShutdownFailure(
        _ failure: AgentLifecycleShutdownFailure
    ) async -> AgentLifecycleShutdownChoice {
        let isQuit = failure.scope == .application
        let alert = NSAlert()
        alert.alertStyle = .warning
        let details = failure.messages.joined(separator: "\n")
        switch failure.stage {
        case .preparation:
            alert.messageText = isQuit
                ? "RepoPrompt couldn't save everything before quitting"
                : "RepoPrompt couldn't save everything before closing this window"
            alert.informativeText = details + "\n\nNothing was stopped or closed. You can keep working, or try again."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Cancel")
        case .finalization where failure.awaitsCleanExitAcknowledgement:
            // Everything admitted was saved; only the clean-exit record is unconfirmed.
            alert.messageText = "RepoPrompt is still finishing its quit"
            alert.informativeText = details
                + "\n\nNothing is left to save. If the clean exit was not recorded, the next launch asks you to review the stopped sessions."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Quit Anyway")
        case .finalization:
            alert.messageText = "Some work could not be saved"
            // An app quit reaches Stage B only after its `shutdownInProgress` mark was confirmed,
            // and no clean write was started: the launch file still records this exit as unclean.
            let consequence = isQuit
                ? "\n\nSessions were already stopped. This exit stays recorded as interrupted, so the next launch asks you to review it."
                : "\n\nSessions in this window were already stopped."
            alert.informativeText = details + consequence
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: isQuit ? "Quit Anyway" : "Close Anyway")
        }
        let parent: NSWindow? = switch failure.scope {
        case .application:
            NSApp.keyWindow ?? NSApp.mainWindow
        case let .window(windowID):
            window(withID: windowID)?.nsWindow
        }
        presentedLifecycleShutdownAlerts[failure.scope] = alert
        let response: NSApplication.ModalResponse
        if let parent {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        if presentedLifecycleShutdownAlerts[failure.scope] === alert {
            presentedLifecycleShutdownAlerts[failure.scope] = nil
        }
        switch (failure.stage, response) {
        case (_, .alertFirstButtonReturn):
            return .retry
        case (.preparation, _):
            return .cancel
        case (.finalization, .alertSecondButtonReturn):
            return .proceedAnyway
        case (.finalization, _):
            // Dismissed without a choice (superseded): not a Cancel; the fenced caller ignores it.
            return .cancel
        }
    }

    // MARK: Window close entry

    /// Routes a window close through Stage A/B. Returns `true` when AppKit may close the window now
    /// (an app quit already passed its point of no return, or this close was finalized); `false`
    /// when the close continues asynchronously (or is refused while an app quit prepares).
    func handleLifecycleWindowCloseAttempt(
        _ windowState: WindowState,
        forwardedVeto: @escaping @MainActor () -> Bool
    ) -> Bool {
        if isTerminating {
            return true
        }
        let windowID = windowState.windowID
        lifecycleShutdown.requestWindowClose(
            windowID: windowID,
            forwardedVeto: forwardedVeto,
            finish: { [weak windowState] closed in
                guard closed, let windowState else { return }
                windowState.closeCoordinator.authorizeFinalizedClose()
                windowState.nsWindow?.performClose(nil)
            }
        )
        return false
    }
}
