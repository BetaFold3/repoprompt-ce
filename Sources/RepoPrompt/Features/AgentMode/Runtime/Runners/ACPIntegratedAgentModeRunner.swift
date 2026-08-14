import Foundation
import MCP

@MainActor
final class ACPIntegratedAgentModeRunner {
    #if DEBUG
        private static let ohMyPiAuthorizationFailureText =
            "Oh My Pi requires an active DEBUG qualification authorization bound to this fresh session."
    #else
        private static let ohMyPiAuthorizationFailureText = "Oh My Pi support is not enabled in this build."
    #endif

    private struct ConsumeEventsOutcome {
        let terminalState: AgentSessionRunState
        let errorText: String?
    }

    private enum MCPBootstrapLeaseDisposition {
        case none
        case clearPolicyAfterSuccessfulRouting
        case failAndRelease
        case failAndCleanup
        case cancelAndCleanup
        case cleanupDeferredRouting

        init(terminalState: AgentSessionRunState, agentKind: AgentProviderKind) {
            switch terminalState {
            case .failed:
                self = agentKind.requiresPrePromptAgentModeMCPRouting ? .failAndRelease : .failAndCleanup
            case .cancelled:
                self = .cancelAndCleanup
            case .completed:
                self = agentKind.requiresPrePromptAgentModeMCPRouting
                    ? .clearPolicyAfterSuccessfulRouting
                    : .cleanupDeferredRouting
            default:
                self = .none
            }
        }

        func apply(to lease: MCPBootstrapLease?) async {
            switch self {
            case .none:
                break
            case .clearPolicyAfterSuccessfulRouting:
                await lease?.clearPolicyAfterSuccessfulRouting()
            case .failAndRelease:
                await lease?.failAndRelease()
            case .failAndCleanup:
                await lease?.failAndCleanup()
            case .cancelAndCleanup:
                await lease?.cancelAndCleanup()
            case .cleanupDeferredRouting:
                await lease?.cleanupDeferredRouting()
            }
        }
    }

    private final class WeakTabSession {
        weak var value: AgentModeViewModel.TabSession?

        init(_ value: AgentModeViewModel.TabSession) {
            self.value = value
        }
    }

    private final class StartupTeardownClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var teardownTask: Task<Void, Never>?
        private var promptStarted = false

        func markPromptStartedIfUnclaimed() -> Bool {
            lock.withLock {
                guard teardownTask == nil else { return false }
                promptStarted = true
                return true
            }
        }

        @discardableResult
        func claim(
            onlyBeforePrompt: Bool = false,
            operation: @escaping @Sendable () async -> Void
        ) -> Task<Void, Never>? {
            lock.withLock {
                if let teardownTask { return teardownTask }
                if onlyBeforePrompt, promptStarted { return nil }
                let task = Task { await operation() }
                teardownTask = task
                return task
            }
        }

        var task: Task<Void, Never>? {
            lock.withLock { teardownTask }
        }
    }

    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    private let toolTrackingHooks: AgentToolTrackingHooks
    private let providerFactory: AgentModeViewModel.ACPProviderFactory
    private let controllerFactory: AgentModeViewModel.ACPControllerFactory
    private var toolTrackingByTabID: [UUID: AgentToolTrackingController] = [:]
    private var toolTrackingRunIDByTabID: [UUID: UUID] = [:]
    private var acpProviderInvocationByTrackerInvocationIDByTabID: [UUID: [UUID: UUID]] = [:]
    private var acpProviderPlaceholderInvocationIDsByTabID: [UUID: Set<UUID>] = [:]
    #if DEBUG
        struct OMPQualificationStartupProbes {
            var beforeAgentTaskEntry: () async -> Void = {}
            var duringExpectedMCPRunIDSet: (() async -> Void)?
            var beforeAuthorizationLivenessCheck: () async -> Void = {}
            var afterProviderBootstrap: () async -> Void = {}
            var afterProviderInitializationCompleted: () async -> Void = {}
            var beforePromptStartClaim: () async -> Void = {}
            var beforeGenericStartupFailureTeardown: () async -> Void = {}
            var toolTrackingStopped: (UUID) -> Void = { _ in }
        }

        private var ompQualificationStartupProbes = OMPQualificationStartupProbes()

        func installOMPQualificationStartupProbes(_ probes: OMPQualificationStartupProbes) {
            ompQualificationStartupProbes = probes
        }
    #endif

    private func log(_ message: String, runID: UUID) {
        guard AgentRuntimeProviderService.enableDebugLogging else { return }
        print("[ACP-Runner] run=\(runID) \(message)")
    }

    private func displayText(for error: Error) -> String {
        Self.displayText(for: error)
    }

    private static func displayText(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .missingOllamaURL:
                return "Missing Ollama URL."
            case .missingAzureConfiguration:
                return "Missing Azure OpenAI configuration."
            case .missingAPIKey:
                return "Missing API key."
            case .missingURL:
                return "Missing provider URL."
            case .providerNotConfigured:
                return "Provider is not configured."
            case .invalidModel:
                return "Invalid model."
            case .invalidSystemPrompt:
                return "Invalid system prompt."
            case .messageCreationFailed:
                return "Failed to create provider message."
            case let .invalidResponse(detail), let .invalidConfiguration(detail):
                return detail
            case let .apiError(source), let .unknown(source):
                return source.map(displayText) ?? String(describing: providerError)
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty, description != "The operation couldn’t be completed." {
                return description
            }
        }
        return String(describing: error)
    }

    init(
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier,
        toolTrackingHooks: AgentToolTrackingHooks,
        providerFactory: @escaping AgentModeViewModel.ACPProviderFactory,
        controllerFactory: @escaping AgentModeViewModel.ACPControllerFactory
    ) {
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        self.toolTrackingHooks = toolTrackingHooks
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func startRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease,
        providerStartAuthorizer: @escaping (_ runID: UUID) -> Bool,
        providerStartBoundaryReporter: @escaping (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool,
        providerStartBootstrapObserver: @escaping () -> Void
    ) async {
        #if DEBUG
            var providerBoundaryResponsibilityTransferred = false
            var providerBoundaryFailureReason: String? = "provider_start_abandoned_before_authorization"
            defer {
                if !providerBoundaryResponsibilityTransferred {
                    _ = providerStartBoundaryReporter(nil, nil, nil, false, providerBoundaryFailureReason)
                }
            }
        #endif
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let ownership = session.beginRunAttempt(source: "acp")
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        setRunningStatus(initialTransportStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

        let freshRunRequest = runRequest
        if let existingController = session.acpController {
            let isCompatible = await existingController.isCompatibleWith(request: runRequest)
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            let hasReusableSession = isCompatible ? await existingController.hasReusableSession : false
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            if isCompatible,
               hasReusableSession,
               let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
            {
                guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
                guard providerStartAuthorizer(runID) else {
                    #if DEBUG
                        _ = providerStartBoundaryReporter(runID, session.activeAgentSessionID, runAttemptID, false, nil)
                    #endif
                    await failBeforeProviderSend(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID,
                        errorText: Self.ohMyPiAuthorizationFailureText
                    )
                    return
                }
                #if DEBUG
                    guard providerStartBoundaryReporter(
                        runID,
                        session.activeAgentSessionID,
                        runAttemptID,
                        true,
                        nil
                    ) else {
                        await failBeforeProviderSend(
                            tabID: tabID,
                            session: session,
                            runID: runID,
                            runAttemptID: runAttemptID,
                            attachmentReservationID: attachmentReservationID,
                            errorText: Self.ohMyPiAuthorizationFailureText
                        )
                        return
                    }
                #endif
                let deferredLease = runRequest.agentKind.requiresPrePromptAgentModeMCPRouting
                    ? nil
                    : makeLease(runID)
                session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] terminalState in
                    let trackerTeardown = self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
                    return {
                        await trackerTeardown?()
                        await MCPBootstrapLeaseDisposition(
                            terminalState: terminalState,
                            agentKind: runRequest.agentKind
                        ).apply(to: deferredLease)
                    }
                }
                session.agentTask = Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                        await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
                    }
                    await withTaskCancellationHandler {
                        await self.continueRun(
                            tabID: tabID,
                            session: session,
                            runID: runID,
                            runAttemptID: runAttemptID,
                            initialMessageForRun: initialMessageForRun,
                            attachments: attachments,
                            controller: existingController,
                            runRequest: runRequest,
                            deferredLease: deferredLease,
                            attachmentReservationID: attachmentReservationID
                        )
                    } onCancel: {}
                }
                return
            }

            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await existingController.shutdown()
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
        }
        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
        let lease = makeLease(runID)

        guard let provider = providerFactory(runRequest.agentKind, runRequest.modelString) else {
            #if DEBUG
                providerBoundaryFailureReason = "acp_provider_unavailable"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "No ACP provider is registered for \(runRequest.agentKind.displayName)."
            )
            return
        }
        let support: ACPSupportResult
        do {
            support = try await provider.support(for: freshRunRequest)
        } catch is CancellationError {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_preflight_cancelled"
            #endif
            await cancelBeforeProviderSend(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID
            )
            return
        } catch {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_preflight_failed"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP support preflight failed: \(error.localizedDescription)"
            )
            return
        }
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
        guard support == .supported else {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_unsupported"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: support.reason ?? "\(runRequest.agentKind.displayName) ACP is not available."
            )
            return
        }
        let controller: ACPAgentSessionController
        do {
            controller = try controllerFactory(provider, freshRunRequest)
        } catch {
            let errorText = displayText(for: error)
            #if DEBUG
                providerBoundaryFailureReason = "acp_controller_initialization_failed"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP controller init failed: \(errorText)"
            )
            return
        }

        #if DEBUG
            await controller.setExpectedMCPRunID(
                runID,
                testDuringSet: runRequest.agentKind == .ohMyPi
                    ? ompQualificationStartupProbes.duringExpectedMCPRunIDSet
                    : nil
            )
        #else
            await controller.setExpectedMCPRunID(runID)
        #endif
        let ownsUnpublishedControllerSlot = session.acpController == nil || session.acpController === controller
        let ownsCurrentAttempt = isStartupStillCurrent(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        ) && ownsUnpublishedControllerSlot
        guard !Task.isCancelled, ownsCurrentAttempt else {
            await finalizeUnpublishedControllerStartup(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                ownsCurrentAttempt: ownsCurrentAttempt,
                providerStartBoundaryReporter: providerStartBoundaryReporter
            )
            return
        }
        session.acpController = controller
        #if DEBUG
            if runRequest.agentKind == .ohMyPi {
                session.ompQualificationStartupLease = lease
            }
        #endif
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak self, weak session] terminalState in
            let trackerTeardown = session.flatMap { self?.prepareToolTrackingTeardown(for: $0, matchingRunID: runID) }
            return {
                await trackerTeardown?()
                await MCPBootstrapLeaseDisposition(
                    terminalState: terminalState,
                    agentKind: runRequest.agentKind
                ).apply(to: lease)
                #if DEBUG
                    if session?.ompQualificationStartupLease === lease {
                        session?.ompQualificationStartupLease = nil
                    }
                #endif
            }
        }
        #if DEBUG
            providerBoundaryResponsibilityTransferred = true
        #endif
        let weakSession = WeakTabSession(session)
        #if DEBUG
            let beforeAgentTaskEntry = ompQualificationStartupProbes.beforeAgentTaskEntry
        #endif
        let terminalCommitBarrier = terminalCommitBarrier
        let hooks = hooks
        let startupTeardownClaim = StartupTeardownClaim()
        session.agentTask = Task { [weak self] in
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await beforeAgentTaskEntry()
                }
            #endif
            guard let self else {
                #if DEBUG
                    _ = providerStartBoundaryReporter(
                        runID,
                        nil,
                        runAttemptID,
                        false,
                        "runner_released_before_authorization"
                    )
                #endif
                if let session = weakSession.value,
                   let currentOwnership = session.activeRunOwnership,
                   currentOwnership.attemptID == runAttemptID,
                   session.runID == runID,
                   session.acpController == nil || session.acpController === controller
                {
                    hooks.recordPendingHandoffSendOutcome(session, false)
                    await terminalCommitBarrier.commit(.init(
                        session: session,
                        ownership: currentOwnership,
                        expectedRunID: runID,
                        terminalState: .failed,
                        source: "acp.runnerReleasedBeforeTaskEntry",
                        completion: .terminalTeardownCompleted,
                        errorText: Self.ohMyPiAuthorizationFailureText,
                        attachmentReservationID: attachmentReservationID,
                        attachmentDisposition: .deleteFiles,
                        finalizeNonCodexUsage: true,
                        supportsFollowUp: false,
                        notifyTurnComplete: false,
                        prepareProviderState: {
                            if session.acpController === controller {
                                session.acpController = nil
                            }
                            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                            return { await controller.shutdown() }
                        }
                    ))
                } else {
                    hooks.finalizeAbandonedAttachmentsForTurn(attachments)
                    await lease.failAndCleanup()
                    await controller.shutdown()
                }
                return
            }
            if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                if let session = weakSession.value {
                    await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
                }
            }
            await withTaskCancellationHandler {
                await self.startFreshRun(
                    tabID: tabID,
                    session: weakSession,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForRun,
                    attachments: attachments,
                    controller: controller,
                    runRequest: freshRunRequest,
                    lease: lease,
                    providerStartAuthorizer: providerStartAuthorizer,
                    providerStartBoundaryReporter: providerStartBoundaryReporter,
                    providerStartBootstrapObserver: providerStartBootstrapObserver,
                    attachmentReservationID: attachmentReservationID,
                    startupTeardownClaim: startupTeardownClaim
                )
            } onCancel: { [weak self] in
                guard freshRunRequest.agentKind == .ohMyPi else { return }
                // OMP bootstrap may not promptly cooperate with cancellation. The same
                // one-shot task is joined below and claimed by in-body cancellation paths.
                _ = startupTeardownClaim.claim(onlyBeforePrompt: true) { @MainActor [weak self] in
                    guard let self else { return }
                    await finalizeStartupDisposition(
                        tabID: tabID,
                        session: weakSession,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        lease: lease,
                        attachments: attachments,
                        attachmentReservationID: attachmentReservationID,
                        controller: controller,
                        runRequest: freshRunRequest,
                        terminalState: .cancelled,
                        errorText: nil
                    )
                }
            }
            await startupTeardownClaim.task?.value
        }
    }

    func submitActivePrompt(
        session: AgentModeViewModel.TabSession,
        messageForRun: String,
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController
    ) async -> Bool {
        guard runRequest.agentKind == session.selectedAgent,
              runRequest.agentKind.acpProviderID != nil,
              session.runState == .running,
              let controller = session.acpController,
              controller === targetController,
              let runID = session.runID,
              runID == targetRunID,
              let runAttemptID = session.activeRunAttemptID,
              runAttemptID == targetRunAttemptID
        else {
            let diagnosticRunID = session.runID ?? targetRunID ?? UUID()
            log("active prompt preflight rejected selected=\(session.selectedAgent.rawValue) request=\(runRequest.agentKind.rawValue) state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) targetRunID=\(String(describing: targetRunID)) attempt=\(String(describing: session.activeRunAttemptID)) targetAttempt=\(String(describing: targetRunAttemptID)) hasController=\(session.acpController != nil) controllerMatches=\(session.acpController === targetController)", runID: diagnosticRunID)
            return false
        }
        guard await controller.isCompatibleWith(request: runRequest) else {
            log("active prompt preflight rejected incompatible ACP request model=\(runRequest.modelString ?? "default") workspace=\(runRequest.workspacePath ?? "nil")", runID: runID)
            return false
        }
        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active prompt preflight became stale after compatibility check state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        // Active steering must not reconfigure ACP session mode/model. Agent-mode UI
        // locks provider selection while a run is active, and reapplying Cursor/OpenCode
        // dynamic model aliases (notably Cursor `auto`) can fail before session/cancel.

        setRunningStatus("Interrupting…", source: .transport, session: session, urgent: true)
        log("active steering interrupt begin attempt=\(runAttemptID)", runID: runID)
        do {
            try await controller.interruptActivePromptForSteering()
            log("active steering interrupt settled attempt=\(runAttemptID)", runID: runID)
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering interrupt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }

        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active steering became stale after interrupt state=\(session.runState.rawValue) currentRunID=\(String(describing: session.runID)) currentAttempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            messageForRun,
            runID,
            attachments
        )

        do {
            log("active steering session/prompt begin attempt=\(runAttemptID)", runID: runID)
            try await controller.prompt(agentMessage, request: runRequest)
            log("active steering session/prompt completed attempt=\(runAttemptID)", runID: runID)
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            // A successful prompt return means the steering prompt was delivered and
            // completed at the ACP layer. The event consumer may already have handled
            // the terminal and finalized the run, so do not require the original
            // activeRunAttemptID to still be present here.
            return true
        } catch {
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering session/prompt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }
    }

    private func isStartupStillCurrent(
        session: AgentModeViewModel.TabSession,
        runID: UUID? = nil,
        runAttemptID: UUID
    ) -> Bool {
        guard session.activeRunAttemptID == runAttemptID,
              session.runState.isActive
        else {
            return false
        }
        if let runID {
            return session.runID == runID
        }
        return true
    }

    private func finalizeUnpublishedControllerStartup(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        ownsCurrentAttempt: Bool,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool
    ) async {
        #if DEBUG
            _ = providerStartBoundaryReporter(
                runID,
                session.activeAgentSessionID,
                runAttemptID,
                false,
                "startup_invalid_before_authorization"
            )
        #endif
        if ownsCurrentAttempt {
            await cancelBeforeProviderSend(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID
            )
        } else {
            hooks.finalizeAttachmentsForTurn(
                session,
                attachmentReservationID,
                attachments,
                .deleteFiles
            )
        }
        await lease.cancelAndCleanup()
        await controller.shutdown()
    }

    private func failBeforeProviderSend(
        tabID _: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        errorText: String
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .failed,
            source: "acp.startupFailure",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    private func cancelBeforeProviderSend(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.startupCancelled",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    private struct StartupBoundarySnapshot {
        let activeAgentSessionID: UUID?
    }

    private enum StartupBoundaryStage: Equatable {
        case beforeAuthorization
        case beforeBootstrap
        case afterBootstrap
        case afterProviderInitializationCompleted

        var reportsProviderInitializationCancellation: Bool {
            self != .afterProviderInitializationCompleted
        }

        var reportsProviderBoundaryFailure: Bool {
            self == .beforeBootstrap
        }
    }

    private enum StartupBoundaryOutcome {
        case current(StartupBoundarySnapshot)
        case cancelled(StartupBoundaryStage)
    }

    private func revalidateStartupBoundary(
        _ stage: StartupBoundaryStage,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> StartupBoundaryOutcome {
        guard let snapshot = startupBoundarySnapshot(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller
        ) else {
            return .cancelled(stage)
        }
        return .current(snapshot)
    }

    private func reportInvalidStartupBoundaryIfNeeded(
        _ stage: StartupBoundaryStage,
        runID: UUID,
        runAttemptID: UUID,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool
    ) -> Bool {
        #if DEBUG
            guard stage.reportsProviderBoundaryFailure else { return false }
            _ = providerStartBoundaryReporter(
                runID,
                nil,
                runAttemptID,
                false,
                "startup_boundary_invalid_before_bootstrap"
            )
            return true
        #else
            return false
        #endif
    }

    private func finalizeInvalidStartupBoundary(
        _ stage: StartupBoundaryStage,
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        providerName: String,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        if stage.reportsProviderInitializationCancellation {
            await lease.providerInitializationCompleted(provider: providerName, outcome: "cancelled")
        }
        await finalizeStartupBoundaryCancellation(
            tabID: tabID,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            startupTeardownClaim: startupTeardownClaim
        )
    }

    private func startupBoundarySnapshot(
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> StartupBoundarySnapshot? {
        guard !Task.isCancelled,
              let session = session.value,
              isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              session.acpController === controller
        else {
            return nil
        }
        return StartupBoundarySnapshot(activeAgentSessionID: session.activeAgentSessionID)
    }

    private func finalizeAfterSessionLoss(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState
    ) async {
        await teardownToolTrackingAfterSessionLoss(tabID: tabID, runID: runID)
        if let liveSession = session.value {
            hooks.finalizeAttachmentsForTurn(
                liveSession,
                attachmentReservationID,
                attachments,
                .deleteFiles
            )
        } else {
            hooks.finalizeAbandonedAttachmentsForTurn(attachments)
        }
        await MCPBootstrapLeaseDisposition(
            terminalState: terminalState,
            agentKind: runRequest.agentKind
        ).apply(to: lease)
        await controller.shutdown()
    }

    private func finalizeClaimedStartupDisposition(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState,
        errorText: String?,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        let task = startupTeardownClaim.claim { @MainActor [weak self] in
            guard let self else { return }
            await finalizeStartupDisposition(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                controller: controller,
                runRequest: runRequest,
                terminalState: terminalState,
                errorText: errorText
            )
        }
        await task?.value
    }

    private func finalizeStartupBoundaryCancellation(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        await finalizeClaimedStartupDisposition(
            tabID: tabID,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            terminalState: .cancelled,
            errorText: nil,
            startupTeardownClaim: startupTeardownClaim
        )
    }

    private func finalizeStartupDisposition(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState,
        errorText: String?
    ) async {
        if let liveSession = session.value,
           isStartupStillCurrent(session: liveSession, runID: runID, runAttemptID: runAttemptID),
           liveSession.acpController == nil || liveSession.acpController === controller
        {
            await finalize(
                session: liveSession,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: terminalState,
                errorText: errorText,
                notifyTurnComplete: false,
                shouldShutdownController: true,
                completion: .terminalTeardownCompleted
            )
            return
        }
        await finalizeAfterSessionLoss(
            tabID: tabID,
            session: session,
            runID: runID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            terminalState: terminalState
        )
    }

    private func finalizeAcquireFailureAfterSessionLoss(
        tabID: UUID,
        runID: UUID,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController
    ) async {
        await teardownToolTrackingAfterSessionLoss(tabID: tabID, runID: runID)
        hooks.finalizeAbandonedAttachmentsForTurn(attachments)
        await controller.shutdown()
    }

    private func startFreshRun(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        lease: MCPBootstrapLease,
        providerStartAuthorizer: (_ runID: UUID) -> Bool,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool,
        providerStartBootstrapObserver: () -> Void,
        attachmentReservationID: UUID?,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        #if DEBUG
            var providerBoundaryReported = false
            var providerBoundaryFailureReason = "fresh_start_abandoned_before_authorization"
            defer {
                if !providerBoundaryReported {
                    _ = providerStartBoundaryReporter(
                        runID,
                        nil,
                        runAttemptID,
                        false,
                        providerBoundaryFailureReason
                    )
                }
            }
        #endif
        let modelDescription = runRequest.modelString ?? "default"
        let resumeDescription = runRequest.resumeSessionID ?? "nil"
        let workspaceDescription = runRequest.workspacePath ?? "nil"
        log("fresh start begin model=\(modelDescription) resume=\(resumeDescription) workspace=\(workspaceDescription)", runID: runID)
        let acquired = await lease.acquire()
        guard acquired else {
            #if DEBUG
                providerBoundaryFailureReason = "bootstrap_lease_acquisition_failed"
            #endif
            log("lease acquire failed", runID: runID)
            let teardown = startupTeardownClaim.claim { @MainActor [self] in
                if let liveSession = session.value {
                    await handleAcquireFailure(
                        tabID: tabID,
                        session: liveSession,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        lease: lease,
                        attachmentReservationID: attachmentReservationID
                    )
                } else {
                    // acquire() owns its failure cleanup. This branch must not apply a second
                    // generic lease disposition that could be mistaken for gate ownership.
                    await finalizeAcquireFailureAfterSessionLoss(
                        tabID: tabID,
                        runID: runID,
                        attachments: attachments,
                        controller: controller
                    )
                }
            }
            await teardown?.value
            return
        }

        var providerInitializationCompleted = false
        do {
            let providerName = runRequest.agentKind.rawValue
            await lease.providerInitializationStarted(provider: providerName)
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforeAuthorizationLivenessCheck()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .beforeAuthorization,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            guard providerStartAuthorizer(runID) else {
                #if DEBUG
                    providerBoundaryReported = true
                    _ = providerStartBoundaryReporter(runID, session.value?.activeAgentSessionID, runAttemptID, false, nil)
                #endif
                await lease.providerInitializationCompleted(provider: providerName, outcome: "failed")
                await finalizeClaimedStartupDisposition(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    terminalState: .failed,
                    errorText: Self.ohMyPiAuthorizationFailureText,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            let boundarySnapshot: StartupBoundarySnapshot
            switch revalidateStartupBoundary(
                .beforeBootstrap,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
            case let .current(snapshot):
                boundarySnapshot = snapshot
            case let .cancelled(stage):
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            log("bootstrap begin", runID: runID)
            #if DEBUG
                providerBoundaryReported = true
                guard providerStartBoundaryReporter(
                    runID,
                    boundarySnapshot.activeAgentSessionID,
                    runAttemptID,
                    true,
                    nil
                ) else {
                    await lease.providerInitializationCompleted(provider: providerName, outcome: "failed")
                    await finalizeClaimedStartupDisposition(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        lease: lease,
                        attachments: attachments,
                        attachmentReservationID: attachmentReservationID,
                        controller: controller,
                        runRequest: runRequest,
                        terminalState: .failed,
                        errorText: Self.ohMyPiAuthorizationFailureText,
                        startupTeardownClaim: startupTeardownClaim
                    )
                    return
                }
                providerStartBootstrapObserver()
            #endif
            let bootstrap = try await controller.bootstrap()
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.afterProviderBootstrap()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .afterBootstrap,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            providerInitializationCompleted = true
            await lease.providerInitializationCompleted(provider: providerName, outcome: "ready")
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.afterProviderInitializationCompleted()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .afterProviderInitializationCompleted,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            log("bootstrap completed sessionID=\(bootstrap.sessionID)", runID: runID)
            guard let session = session.value else {
                await finalizeStartupBoundaryCancellation(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            var initialMessageForPromptTurn = initialMessageForRun
            if bootstrap.didFallbackToNewSessionAfterLoadFailure {
                await hooks.stageResumeRecoveryHandoffIfNeeded(session)
                initialMessageForPromptTurn = hooks.prependPendingHandoffIfNeeded(initialMessageForRun, session)
            }
            applyProviderSessionIdentity(
                bootstrap.providerSessionIdentity,
                invalidatedResumeSessionID: bootstrap.invalidatedResumeSessionID,
                session: session
            )
            _ = syncACPSelectedModelFromRegistryIfNeeded(agentKind: runRequest.agentKind, session: session)
            session.isDirty = true
            hooks.scheduleSave(session.tabID)
            hooks.updateBindings(session)

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(runRequest.sessionModeID, controller: controller, runID: runID)
            setRunningStatus(waitingForConnectionStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

            if runRequest.agentKind.requiresPrePromptAgentModeMCPRouting {
                let routed = await lease.releaseWhenRouted()
                log("releaseWhenRouted routed=\(routed)", runID: runID)
                guard routed else {
                    await finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "RepoPrompt MCP routing did not complete before \(runRequest.agentKind.displayName) ACP prompt submission.",
                        notifyTurnComplete: false,
                        shouldShutdownController: true
                    )
                    return
                }
            } else {
                await lease.releaseGateForDeferredRouting()
                log("deferred MCP routing until ACP prompt", runID: runID)
            }

            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforePromptStartClaim()
                }
            #endif
            guard startupTeardownClaim.markPromptStartedIfUnclaimed() else {
                await startupTeardownClaim.task?.value
                return
            }
            await runPromptTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                initialMessageForRun: initialMessageForPromptTurn,
                attachments: attachments,
                controller: controller,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID
            )
        } catch is CancellationError {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: runRequest.agentKind.rawValue, outcome: "cancelled")
            }
            log("fresh start cancelled", runID: runID)
            await finalizeStartupBoundaryCancellation(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                controller: controller,
                runRequest: runRequest,
                startupTeardownClaim: startupTeardownClaim
            )
        } catch {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: runRequest.agentKind.rawValue, outcome: "failed")
            }
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("fresh start failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforeGenericStartupFailureTeardown()
                }
            #endif
            let teardown = startupTeardownClaim.claim { @MainActor [weak self] in
                guard let self else { return }
                await finalizeStartupDisposition(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    terminalState: .failed,
                    errorText: normalizedText
                )
            }
            await teardown?.value
        }
    }

    private func continueRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        deferredLease: MCPBootstrapLease?,
        attachmentReservationID: UUID?
    ) async {
        do {
            guard await controller.hasReusableSession else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            let prepared = await controller.prepareForNextTurn()
            guard prepared else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(runRequest.sessionModeID, controller: controller, runID: runID)

            if let deferredLease {
                let acquired = await deferredLease.acquire()
                guard acquired else {
                    await finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "RepoPrompt MCP routing policy could not be prepared before \(runRequest.agentKind.displayName) ACP prompt submission.",
                        notifyTurnComplete: false,
                        shouldShutdownController: true
                    )
                    return
                }
                await deferredLease.releaseGateForDeferredRouting()
                log("deferred MCP routing until ACP follow-up prompt", runID: runID)
            }

            await runPromptTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                controller: controller,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID
            )
        } catch is CancellationError {
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("continue failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: normalizedText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        }
    }

    private func runPromptTurn(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?
    ) async {
        log("prompt turn begin", runID: runID)
        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            initialMessageForRun,
            runID,
            attachments
        )
        hooks.recordPendingHandoffSendOutcome(session, true)
        hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
        hooks.markAttachmentsConsumed(session, attachmentReservationID)

        let events = await controller.events
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return ConsumeEventsOutcome(terminalState: .failed, errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(
                events,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
        }

        do {
            log("controller.prompt begin", runID: runID)
            try await controller.prompt(agentMessage, request: runRequest)
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            log("controller.prompt returned; awaiting event consumer", runID: runID)
        } catch {
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalizedError = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalizedError)
            log("controller.prompt failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            let outcome = await consumeTask.value
            let errorText = promptFailureErrorText(outcome: outcome, fallback: normalizedText)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: errorText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
            return
        }

        let outcome = await consumeTask.value
        let outcomeErrorDescription = outcome.errorText ?? "nil"
        log("event consumer completed state=\(outcome.terminalState.rawValue) error=\(outcomeErrorDescription)", runID: runID)
        await finalize(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID,
            terminalState: outcome.terminalState,
            errorText: outcome.errorText,
            notifyTurnComplete: outcome.terminalState == .completed,
            shouldShutdownController: outcome.terminalState != .completed
        )
    }

    private func applyProviderSessionIdentity(
        _ identity: ACPProviderSessionIdentity,
        invalidatedResumeSessionID: String? = nil,
        session: AgentModeViewModel.TabSession
    ) {
        let providerSessionID = identity.loadSessionID ?? identity.runtimeSessionID
        var changed = false
        let invalidated = invalidatedResumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalidated,
           !invalidated.isEmpty,
           session.providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == invalidated,
           providerSessionID != invalidated
        {
            session.providerSessionID = nil
            changed = true
        }
        if session.providerSessionID != providerSessionID {
            session.providerSessionID = providerSessionID
            changed = true
        }
        guard changed else { return }
        session.isDirty = true
        hooks.scheduleSave(session.tabID)
        hooks.updateBindings(session)
    }

    private func applyRequestedSessionModeIfNeeded(
        _ requestedMode: String?,
        controller: ACPAgentSessionController,
        runID: UUID
    ) async throws {
        if let requestedMode = requestedMode?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedMode.isEmpty {
            try await controller.setSessionMode(requestedMode)
        }
    }

    private func applyExplicitSelectedModelIfNeeded(
        _ runRequest: ACPRunRequest,
        controller: ACPAgentSessionController,
        runID: UUID
    ) async throws {
        guard runRequest.agentKind == .openCode || runRequest.agentKind == .cursor || runRequest.agentKind == .ohMyPi else { return }
        guard let model = runRequest.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return
        }
        if runRequest.agentKind == .ohMyPi {
            guard let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi),
                  snapshot.contains(rawModel: model)
            else {
                return
            }
        }
        if runRequest.agentKind == .cursor,
           let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor),
           !Self.cursorRegistryAllowsSelectedModel(model, snapshot: snapshot)
        {
            return
        }
        log("applying \(runRequest.agentKind.displayName) selected model=\(model)", runID: runID)
        try await controller.setSessionModel(model)
    }

    static func cursorRegistryAllowsSelectedModel(
        _ model: String,
        snapshot: ACPDiscoveredSessionModels?
    ) -> Bool {
        CursorModelRegistryGate.allows(model, in: snapshot)
    }

    private func promptFailureErrorText(
        outcome: ConsumeEventsOutcome,
        fallback: String
    ) -> String {
        let unexpectedStreamEnd = "ACP events stream ended unexpectedly."
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outcomeError = outcome.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outcomeError.isEmpty,
              outcomeError != unexpectedStreamEnd
        else {
            return trimmedFallback.isEmpty ? unexpectedStreamEnd : trimmedFallback
        }
        return outcomeError
    }

    private func consumeEvents(
        _ events: AsyncStream<NormalizedAgentRuntimeEvent>,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
        }
        for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil)
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            switch event {
            case let .stream(result):
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .approvalRequested(request):
                session.pendingApproval = request
                session.runState = .waitingForApproval
                setRunningStatus(nil, source: nil, session: session, urgent: true)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == requestID {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    } else {
                        hooks.updateBindings(session)
                    }
                }
            case let .terminal(state, errorText):
                if session.pendingSupersedingTurnCompletions > 0 {
                    session.pendingSupersedingTurnCompletions -= 1
                    if session.runState.isActive {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    }
                    continue
                }
                return ConsumeEventsOutcome(terminalState: state, errorText: errorText)
            }
        }

        return ConsumeEventsOutcome(
            terminalState: .failed,
            errorText: "ACP events stream ended unexpectedly."
        )
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease _: MCPBootstrapLease,
        attachmentReservationID: UUID?
    ) async {
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.acquireFailure",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                if session.acpController === controller {
                    session.acpController = nil
                }
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return { await controller.shutdown() }
            }
        ))
    }

    private func finalize(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController?,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownController: Bool,
        completion: AgentModeRunService.CancellationCompletion = .terminalPublished
    ) async {
        let finalizeErrorDescription = errorText ?? "nil"
        log("finalize requested state=\(terminalState.rawValue) error=\(finalizeErrorDescription)", runID: runID)
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else {
            log("finalize ignored; session no longer owns run", runID: runID)
            return
        }
        let supportsSessionResume = terminalState == .completed && controller != nil
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "acp.finalize",
            completion: completion,
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: supportsSessionResume,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: {
                session.pendingSupersedingTurnCompletions = 0
                if terminalState != .completed {
                    if let controller, session.acpController === controller {
                        session.acpController = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                } else if session.acpController == nil {
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                }
                return {
                    if shouldShutdownController, let controller {
                        await controller.shutdown()
                    }
                }
            }
        ))
    }

    // MARK: - Tool Tracking (per-tab, using shared AgentToolTrackingController)

    private func startToolTracking(
        for session: AgentModeViewModel.TabSession,
        runID: UUID,
        clientNameHint: String
    ) async {
        guard session.runID == runID, session.runState.isActive else { return }
        #if DEBUG
            print("[ACPAgentRunToolTracking] ACP startToolTracking session=\(session.activeAgentSessionID?.uuidString ?? "nil") tab=\(session.tabID.uuidString) agent=\(session.selectedAgent.rawValue) runID=\(runID.uuidString) clientHint=\(clientNameHint)")
        #endif
        resetACPToolCorrelation(for: session.tabID)
        toolTrackingRunIDByTabID[session.tabID] = runID
        let controller = toolTrackingByTabID[session.tabID] ?? {
            let c = AgentToolTrackingController()
            toolTrackingByTabID[session.tabID] = c
            return c
        }()
        await controller.startTracking(
            runID: runID,
            clientNameHint: clientNameHint,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleTrackerToolResult(invocationID: invocationID, toolName: toolName, args: args, resultJSON: resultJSON, isError: isError, session: session)
            }
        )
    }

    private func prepareToolTrackingTeardown(
        for session: AgentModeViewModel.TabSession,
        matchingRunID: UUID? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        prepareToolTrackingTeardown(tabID: session.tabID, matchingRunID: matchingRunID)
    }

    private func prepareToolTrackingTeardown(
        tabID: UUID,
        matchingRunID: UUID? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        if let matchingRunID, toolTrackingRunIDByTabID[tabID] != matchingRunID {
            return nil
        }
        let stoppedRunID = toolTrackingRunIDByTabID.removeValue(forKey: tabID)
        guard let controller = toolTrackingByTabID.removeValue(forKey: tabID) else { return nil }
        resetACPToolCorrelation(for: tabID)
        #if DEBUG
            let stoppedHook = ompQualificationStartupProbes.toolTrackingStopped
        #endif
        return {
            await controller.stopTracking()
            #if DEBUG
                if let stoppedRunID {
                    stoppedHook(stoppedRunID)
                }
            #endif
        }
    }

    private func teardownToolTrackingAfterSessionLoss(tabID: UUID, runID: UUID) async {
        let teardown = prepareToolTrackingTeardown(tabID: tabID, matchingRunID: runID)
        await teardown?()
    }

    private func setRunningStatus(
        _ text: String?,
        source: AgentModeViewModel.TabSession.RunningStatusSource?,
        session: AgentModeViewModel.TabSession,
        urgent: Bool = false
    ) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        let normalizedSource = value == nil ? nil : source
        guard session.runningStatusText != value || session.runningStatusSource != normalizedSource else {
            if urgent {
                hooks.updateBindings(session)
                hooks.requestUIRefresh(session.tabID, true)
            }
            return
        }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        hooks.updateBindings(session)
        hooks.requestUIRefresh(session.tabID, urgent)
    }

    private func initialTransportStatusText(for _: AgentProviderKind) -> String {
        "Preparing…"
    }

    private func waitingForConnectionStatusText(for _: AgentProviderKind) -> String {
        "Waiting for connection…"
    }

    // MARK: - Tracker Callbacks

    private func handleTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentModeViewModel.TabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        if let index = correlatedToolCallItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: false
        ) {
            var updated = session.items[index]
            let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != invocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
                removeProviderPlaceholderInvocation(existingInvocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = invocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if updated.kind == .toolCall {
                updated.text = argsJSON ?? ""
            }
            if !hadArgs, hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: false
        ) {
            var updated = session.items[index]
            let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != invocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
                removeProviderPlaceholderInvocation(existingInvocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = invocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if !hadArgs, hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else {
            if hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
        }
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
    }

    private func handleTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentModeViewModel.TabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) isError=\(isError) resultChars=\(resultJSON.count) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        let resolvedInvocationID = consumeProviderInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
        if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: resolvedInvocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: true
        ) {
            var updated = session.items[index]
            let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
            updated.kind = .toolResult
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != resolvedInvocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = resolvedInvocationID
            }
            updated.toolName = storedToolName
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
            if !hadResult, hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else {
            if hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            var toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: resolvedInvocationID,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            toolResultItem.toolArgsJSON = argsJSON
            session.appendItem(toolResultItem)
        }
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
    }

    private func indexedThenActiveTurnToolCandidates(
        indexedIndices: [Int],
        session: AgentModeViewModel.TabSession,
        where predicate: (AgentChatItem) -> Bool
    ) -> (indices: [Int], inspectedItemCount: Int, usedFallbackScan: Bool) {
        let indexedMatches = indexedIndices.filter { predicate(session.items[$0]) }
        if !indexedMatches.isEmpty || !indexedIndices.isEmpty {
            return (indexedMatches, indexedIndices.count, false)
        }
        let fallback = session.activeTurnToolItemIndices(where: predicate)
        return (
            fallback.indices,
            indexedIndices.count + fallback.scannedItemCount,
            !fallback.indices.isEmpty
        )
    }

    private func correlatedToolCallItemIndex(
        in session: AgentModeViewModel.TabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolCall(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "invocation_id_active_turn_scan" : "invocation_id",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON {
            let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(
                    signature: signature,
                    pendingCallsOnly: true
                ),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "signature_active_turn_scan" : "signature",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON,
           hasAccountableToolPayload(argsJSON)
        {
            let normalizedToolName = AgentModeViewModel.TabSession.normalizedToolCorrelationName(storedToolName)
            let placeholderCandidates = session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && self.isProviderPlaceholderInvocation(item.toolInvocationID, tabID: session.tabID)
                    && self.isPlaceholderToolArgs(item.toolArgsJSON)
                    && AgentModeViewModel.TabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
            })
            inspectedItemCount += placeholderCandidates.scannedItemCount
            if placeholderCandidates.indices.count == 1 {
                MCPToolObserverAttributionContext.record(
                    correlationPath: "placeholder_active_turn_scan",
                    scannedItemCount: inspectedItemCount
                )
                return placeholderCandidates.indices[0]
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentModeViewModel.TabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentModeViewModel.TabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func correlatedToolResultItemIndex(
        in session: AgentModeViewModel.TabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolCall(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "invocation_id_call_active_turn_scan"
                        : "invocation_id_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolResult
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolResult(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "invocation_id_result_active_turn_scan"
                        : "invocation_id_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
        if argsJSON != nil {
            let signatureIndices = session.indexedToolItemIndices(signature: signature)
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "signature_call_active_turn_scan"
                        : "signature_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolResult
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "signature_result_active_turn_scan"
                        : "signature_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentModeViewModel.TabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentModeViewModel.TabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func shouldUpdateExistingToolCall(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolCall else { return false }
        return hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON)
            || hasSameNormalizedToolName(item.toolName, storedToolName)
            || isKnownProviderPlaceholder(item, tabID: tabID)
    }

    private func shouldUpdateExistingToolResult(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolResult else { return false }
        if hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON) {
            return true
        }
        switch AgentTranscriptToolNormalizer.status(for: item) {
        case .pending, .running:
            return hasSameNormalizedToolName(item.toolName, storedToolName)
                || isKnownProviderPlaceholder(item, tabID: tabID)
        case .success, .warning, .failed, .cancelled, .unknown:
            return false
        }
    }

    private func hasExactToolInvocationSignature(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?
    ) -> Bool {
        toolInvocationSignature(toolName: item.toolName, argsJSON: item.toolArgsJSON)
            == toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
    }

    private func hasSameNormalizedToolName(_ existingToolName: String?, _ incomingToolName: String) -> Bool {
        let existing = MCPIntegrationHelper.normalizedRepoPromptToolName(existingToolName ?? "")
        let incoming = MCPIntegrationHelper.normalizedRepoPromptToolName(incomingToolName)
        return !existing.isEmpty && existing == incoming
    }

    private func isKnownProviderPlaceholder(_ item: AgentChatItem, tabID: UUID) -> Bool {
        isProviderPlaceholderInvocation(item.toolInvocationID, tabID: tabID)
            && isPlaceholderToolArgs(item.toolArgsJSON)
    }

    private func recordProviderInvocation(_ providerInvocationID: UUID, forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) {
        var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID, default: [:]]
        mappings[trackerInvocationID] = providerInvocationID
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings
    }

    private func recordProviderPlaceholderInvocationIfNeeded(_ invocationID: UUID?, argsJSON: String?, tabID: UUID) {
        guard let invocationID, isPlaceholderToolArgs(argsJSON) else { return }
        var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID, default: []]
        placeholders.insert(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders
    }

    private func removeProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) {
        guard let invocationID,
              var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID] else { return }
        placeholders.remove(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders.isEmpty ? nil : placeholders
    }

    private func isProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) -> Bool {
        guard let invocationID else { return false }
        return acpProviderPlaceholderInvocationIDsByTabID[tabID]?.contains(invocationID) == true
    }

    private func consumeProviderInvocation(forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) -> UUID? {
        guard var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID] else { return nil }
        let providerInvocationID = mappings.removeValue(forKey: trackerInvocationID)
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings.isEmpty ? nil : mappings
        return providerInvocationID
    }

    private func resetACPToolCorrelation(for tabID: UUID) {
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = nil
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = nil
    }

    private func toolInvocationSignature(toolName: String?, argsJSON: String?) -> String {
        AgentModeViewModel.TabSession.canonicalToolInvocationSignature(
            toolName: toolName,
            argsJSON: argsJSON
        )
    }

    private func hasNonEmptyPayload(_ payload: String?) -> Bool {
        payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasAccountableToolPayload(_ payload: String?) -> Bool {
        hasNonEmptyPayload(payload) && !isPlaceholderToolArgs(payload)
    }

    private func isPlaceholderToolArgs(_ payload: String?) -> Bool {
        guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return true
        }
        return canonicalizedJSON(payload) == "{}"
    }

    private func canonicalizedJSON(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8)
        else {
            return raw
        }
        return canonical
    }

    #if DEBUG
        func testHandleTrackerToolCall(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            session: AgentModeViewModel.TabSession
        ) {
            handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
        }

        func testHandleTrackerToolResult(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            resultJSON: String,
            isError: Bool,
            session: AgentModeViewModel.TabSession
        ) {
            handleTrackerToolResult(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
        }

        func testSyncACPSelectedModelFromRegistryIfNeeded(
            agentKind: AgentProviderKind,
            session: AgentModeViewModel.TabSession
        ) -> Bool {
            syncACPSelectedModelFromRegistryIfNeeded(agentKind: agentKind, session: session)
        }
    #endif

    // MARK: - Provider Stream Tool Event Handling

    private func syncACPSelectedModelFromRegistryIfNeeded(
        agentKind: AgentProviderKind,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard let providerID = agentKind.acpProviderID,
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID)
        else {
            return false
        }
        let selectedModelRaw = session.selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIsDefault = selectedModelRaw.isEmpty
            || selectedModelRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let selectedOption = snapshot.option(matching: selectedModelRaw)
        let selectedIsPlaceholder = selectedIsDefault || selectedOption?.isPlaceholderDefault == true
        guard selectedIsPlaceholder else { return false }
        if let preferredModelRaw = snapshot.preferredModelRaw,
           session.selectedModelRaw.caseInsensitiveCompare(preferredModelRaw) != .orderedSame
        {
            session.selectedModelRaw = preferredModelRaw
            return true
        }
        if !snapshot.contains(rawModel: session.selectedModelRaw) {
            session.selectedModelRaw = AgentModelCatalog.defaultModelRaw(for: agentKind)
            return true
        }
        return false
    }

    @discardableResult
    func handleToolStreamEvent(
        _ event: AgentToolStreamEvent,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        // ACP provider events carry the provider's tool invocation IDs, while the
        // MCP tracker sees RepoPrompt's internal invocation IDs. Render explicit
        // RepoPrompt tool cards here so AgentModeViewModel can remain provider-neutral.
        switch event {
        case let .toolCall(call):
            guard AgentToolTrackingSupport.isRepoPromptTool(call.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(call.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(call.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(call.invocationID?.uuidString ?? "nil") tool=\(call.toolName) argsChars=\(call.argsJSON?.count ?? 0) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(call.toolName) ?? call.toolName
            if let index = correlatedToolCallItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
                allowNameOnlyFallback: false
            ) {
                var updated = session.items[index]
                let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
                if let trackerInvocationID = updated.toolInvocationID,
                   let providerInvocationID = call.invocationID,
                   trackerInvocationID != providerInvocationID
                {
                    recordProviderInvocation(providerInvocationID, forTrackerInvocationID: trackerInvocationID, tabID: session.tabID)
                    updated.toolInvocationID = providerInvocationID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? call.invocationID
                }
                updated.toolName = storedToolName
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                if updated.kind == .toolCall {
                    updated.text = call.argsJSON ?? ""
                }
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
                allowNameOnlyFallback: false
            ) {
                var updated = session.items[index]
                let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
                if let trackerInvocationID = updated.toolInvocationID,
                   let providerInvocationID = call.invocationID,
                   trackerInvocationID != providerInvocationID
                {
                    recordProviderInvocation(providerInvocationID, forTrackerInvocationID: trackerInvocationID, tabID: session.tabID)
                    updated.toolInvocationID = providerInvocationID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? call.invocationID
                }
                updated.toolName = storedToolName
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                let toolItem = AgentChatItem.toolCall(
                    name: storedToolName,
                    invocationID: call.invocationID,
                    argsJSON: call.argsJSON,
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(toolItem)
                recordProviderPlaceholderInvocationIfNeeded(call.invocationID, argsJSON: call.argsJSON, tabID: session.tabID)
            }
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true

        case let .toolResult(result):
            guard AgentToolTrackingSupport.isRepoPromptTool(result.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(result.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(result.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(result.invocationID?.uuidString ?? "nil") tool=\(result.toolName) isError=\(result.isError) resultChars=\(result.resultJSON.count) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            removeProviderPlaceholderInvocation(result.invocationID, tabID: session.tabID)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(result.toolName) ?? result.toolName
            if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: result.invocationID,
                argsJSON: result.argsJSON,
                allowNameOnlyFallback: true
            ) {
                var updated = session.items[index]
                let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
                updated.kind = .toolResult
                updated.toolName = storedToolName
                updated.toolInvocationID = updated.toolInvocationID ?? result.invocationID
                updated.toolResultJSON = result.resultJSON
                updated.toolArgsJSON = result.argsJSON ?? updated.toolArgsJSON
                updated.toolIsError = result.isError
                updated.text = result.resultJSON
                if !hadResult, hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                var toolResultItem = AgentChatItem.toolResult(
                    name: storedToolName,
                    invocationID: result.invocationID,
                    resultJSON: result.resultJSON,
                    isError: result.isError,
                    sequenceIndex: session.nextSequenceIndex
                )
                toolResultItem.toolArgsJSON = result.argsJSON
                session.appendItem(toolResultItem)
            }
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true

        case let .legacyEvent(legacy):
            guard AgentToolTrackingSupport.isRepoPromptTool(legacy.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(legacy.toolName) else { return true }
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(legacy.toolName) ?? legacy.toolName
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                argsJSON: nil,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true
        }
    }
}
