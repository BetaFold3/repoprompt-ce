import Foundation
import RepoPromptRemoteWire

@MainActor
final class RemoteAgentModeCoordinator {
    private struct HostConnectionTasks {
        var inbound: Task<Void, Never>
        var state: Task<Void, Never>
    }

    private weak var viewModel: AgentModeViewModel?
    private let connectionManagerProvider: @MainActor () -> RemoteHostConnectionManager
    private var controllersByTabID: [UUID: RemoteAgentSessionController] = [:]
    private var eventTasksByTabID: [UUID: Task<Void, Never>] = [:]
    private var hostIDByTabID: [UUID: String] = [:]
    private var connectionTasksByHostID: [String: HostConnectionTasks] = [:]
    private var surfacedChannelReasonsByTabID: [UUID: Set<String>] = [:]

    init(
        connectionManagerProvider: @escaping @MainActor () -> RemoteHostConnectionManager = { RemoteHostConnectionManager.shared }
    ) {
        self.connectionManagerProvider = connectionManagerProvider
    }

    func attach(viewModel: AgentModeViewModel) {
        self.viewModel = viewModel
    }

    func attachPersistedSessionIfNeeded(_ session: AgentModeViewModel.TabSession) {
        guard session.remoteHost != nil else { return }
        do {
            let controller = try controller(for: session)
            Task { [weak self] in
                do {
                    try await controller.attachAndCatchUp()
                } catch {
                    self?.appendSystemMessage("Remote attach failed: \(Self.describe(error))", tabID: session.tabID)
                }
            }
        } catch {
            appendSystemMessage("Remote attach failed: \(Self.describe(error))", tabID: session.tabID)
        }
    }

    func startRemoteSession(
        session: AgentModeViewModel.TabSession,
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        windowID: Int?,
        workspaceID: String?
    ) async throws {
        let controller = try controller(for: session)
        session.runState = .running
        session.setRunningStatus("Starting on \(session.remoteHost?.hostDisplayName ?? "remote host")…", source: .transport)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        let remoteSessionID = try await controller.start(
            message: message,
            modelSelectionRaw: modelSelectionRaw,
            sessionName: sessionName,
            windowID: windowID,
            workspaceID: workspaceID
        )
        if var binding = session.remoteHost {
            binding.remoteSessionID = remoteSessionID
            session.remoteHost = binding
            updateSessionIndex(for: session)
        }
    }

    func steer(session: AgentModeViewModel.TabSession, text: String) async throws {
        let controller = try controller(for: session)
        try await controller.steer(text)
    }

    func cancel(session: AgentModeViewModel.TabSession) async throws {
        let controller = try controller(for: session)
        try await controller.cancel()
    }

    func submitApprovalDecision(
        session: AgentModeViewModel.TabSession,
        interactionID: String,
        decision: AgentApprovalDecision
    ) {
        optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        let payload = RemoteInteractionResponsePayload.approval(decision: decision)
        submitResponse(session: session, interactionID: interactionID, payload: payload)
    }

    func submitAskUserResponse(
        session: AgentModeViewModel.TabSession,
        interactionID: String,
        response: AgentAskUserResponse
    ) {
        optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .askUser(response))
    }

    func submitUserInputResponse(
        session: AgentModeViewModel.TabSession,
        request: AgentRequestUserInputRequest,
        response: AgentRequestUserInputResponse
    ) {
        let interactionID = request.remoteInteractionID ?? request.id.uuidString
        optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .userInput(response))
    }

    func submitMCPElicitationResponse(
        session: AgentModeViewModel.TabSession,
        request: AgentMCPElicitationRequest,
        response: AgentMCPElicitationResponse
    ) {
        let interactionID = request.remoteInteractionID ?? request.id.uuidString
        optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .mcpElicitation(response))
    }

    func stop(tabID: UUID) {
        eventTasksByTabID.removeValue(forKey: tabID)?.cancel()
        surfacedChannelReasonsByTabID.removeValue(forKey: tabID)
        let controller = controllersByTabID.removeValue(forKey: tabID)
        if let hostID = hostIDByTabID.removeValue(forKey: tabID) {
            stopConnectionFanoutIfUnused(hostID: hostID)
        }
        if let controller {
            Task { await controller.shutdown() }
        }
    }

    private func submitResponse(
        session: AgentModeViewModel.TabSession,
        interactionID: String,
        payload: RemoteInteractionResponsePayload
    ) {
        do {
            let controller = try controller(for: session)
            Task { [weak self] in
                do {
                    try await controller.respond(interactionID: interactionID, payload: payload)
                } catch RemoteClientError.interactionAlreadyResolved {
                    self?.clearResolvedInteraction(tabID: session.tabID, interactionID: interactionID, resolvedBy: nil)
                } catch {
                    self?.appendSystemMessage("Remote response failed: \(Self.describe(error))", tabID: session.tabID)
                }
            }
        } catch {
            appendSystemMessage("Remote response failed: \(Self.describe(error))", tabID: session.tabID)
        }
    }

    private func controller(for session: AgentModeViewModel.TabSession) throws -> RemoteAgentSessionController {
        if let existing = controllersByTabID[session.tabID] {
            return existing
        }
        guard let binding = session.remoteHost else {
            throw RemoteClientError.protocolViolation("Session is not bound to a remote host.")
        }
        let connection = try connectionManagerProvider().connection(for: binding.hostID)
        let controller = RemoteAgentSessionController(binding: binding, connection: connection)
        controllersByTabID[session.tabID] = controller
        hostIDByTabID[session.tabID] = binding.hostID
        startEventTask(for: session.tabID, controller: controller)
        startConnectionFanoutIfNeeded(hostID: binding.hostID, connection: connection)
        return controller
    }

    private func startEventTask(for tabID: UUID, controller: RemoteAgentSessionController) {
        eventTasksByTabID[tabID]?.cancel()
        eventTasksByTabID[tabID] = Task { [weak self] in
            for await event in controller.events {
                await self?.handle(event, tabID: tabID)
            }
        }
    }

    private func startConnectionFanoutIfNeeded(hostID: String, connection: RemoteHostConnection) {
        guard connectionTasksByHostID[hostID] == nil else { return }
        let inbound = Task { [weak self] in
            for await frame in connection.inboundFrames {
                await self?.deliver(frame, hostID: hostID)
            }
        }
        let state = Task { [weak self] in
            for await state in connection.stateEvents {
                await self?.deliver(state, hostID: hostID)
            }
        }
        connectionTasksByHostID[hostID] = HostConnectionTasks(inbound: inbound, state: state)
    }

    private func stopConnectionFanoutIfUnused(hostID: String) {
        guard !hostIDByTabID.values.contains(hostID) else { return }
        let tasks = connectionTasksByHostID.removeValue(forKey: hostID)
        tasks?.inbound.cancel()
        tasks?.state.cancel()
    }

    private func deliver(_ frame: RemoteServerFrame, hostID: String) async {
        let controllers = controllersByTabID.compactMap { tabID, controller in
            hostIDByTabID[tabID] == hostID ? controller : nil
        }
        for controller in controllers {
            await controller.handleInboundFrame(frame)
        }
    }

    private func deliver(_ state: RemoteHostConnection.State, hostID: String) async {
        if case .connected = state {
            viewModel?.refreshRemoteHostCatalogAfterConnect(hostID: hostID)
        }
        let controllers = controllersByTabID.compactMap { tabID, controller in
            hostIDByTabID[tabID] == hostID ? controller : nil
        }
        for controller in controllers {
            await controller.handleConnectionState(state)
        }
    }

    private func handle(_ event: RemoteSessionEvent, tabID: UUID) {
        guard let session = viewModel?.sessions[tabID] else { return }
        switch event {
        case let .transcriptRows(rows):
            applyTranscriptRows(rows, to: session)
        case let .runState(runState, pendingInteraction):
            applyRunState(runState, pendingInteraction: pendingInteraction, to: session)
        case let .interactionResolved(interactionID, resolvedBy):
            clearResolvedInteraction(tabID: tabID, interactionID: interactionID, resolvedBy: resolvedBy)
        case .sessionExpired:
            session.runState = .failed
            clearPendingInteractions(session)
            appendSystemMessage("Remote session expired on host.", tabID: tabID)
        case let .terminal(status):
            applyTerminal(status: status, to: session)
        case let .channel(channelState):
            applyChannel(channelState, to: session)
        case let .systemMessage(message):
            appendSystemMessage(message, tabID: tabID)
        case let .metadata(agentKindRaw, modelRaw, sessionName):
            if let agentKindRaw,
               let kind = AgentProviderKind(rawValue: agentKindRaw)
            {
                session.selectedAgent = kind
            }
            if let modelRaw, !modelRaw.isEmpty {
                session.selectedModelRaw = modelRaw
            }
            _ = sessionName
        case let .binding(binding):
            session.remoteHost = binding
            updateSessionIndex(for: session)
        }
        session.isDirty = true
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.updateBindingsFromSession(session)
        viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
        viewModel?.scheduleSave(for: tabID)
    }

    private func applyTranscriptRows(_ rows: [AgentChatItem], to session: AgentModeViewModel.TabSession) {
        guard !rows.isEmpty else { return }
        let remoteSessionID = session.remoteHost?.remoteSessionID ?? "remote"
        let projector = RemoteTranscriptProjector(remoteSessionID: remoteSessionID)
        let projectedUserTextKeys = Set(rows.filter { $0.kind == .user }.map { Self.normalizedTextKey($0.text) })
        session.mutateItemsBatch { items in
            var merged = projector.upserting(rows, into: items)
            if !projectedUserTextKeys.isEmpty, !session.pendingRemoteOptimisticUserItemIDs.isEmpty {
                merged.removeAll { item in
                    item.kind == .user
                        && session.pendingRemoteOptimisticUserItemIDs.contains(item.id)
                        && projectedUserTextKeys.contains(Self.normalizedTextKey(item.text))
                }
                session.pendingRemoteOptimisticUserItemIDs = session.pendingRemoteOptimisticUserItemIDs.filter { id in
                    merged.contains { $0.id == id }
                }
            }
            items = merged
        }
        session.hasSentFirstMessage = session.items.contains { $0.kind == .user }
    }

    private func applyRunState(
        _ runState: AgentSessionRunState,
        pendingInteraction: RemotePendingInteraction?,
        to session: AgentModeViewModel.TabSession
    ) {
        if let pendingInteraction {
            clearPendingInteractions(session, preserving: pendingInteraction.interactionID)
            switch pendingInteraction {
            case let .approval(interactionID, request):
                if !Self.interactionMatches(
                    session.pendingApproval?.id,
                    remoteInteractionID: approvalRemoteInteractionID(session.pendingApproval),
                    interactionID: interactionID
                ) {
                    session.pendingApproval = request
                }
            case let .question(interactionID, pending):
                if !Self.interactionMatches(
                    session.pendingAskUser?.interaction.id,
                    remoteInteractionID: session.pendingAskUser?.interaction.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    session.pendingAskUser = pending
                }
            case let .userInput(interactionID, request):
                if !Self.interactionMatches(
                    session.pendingUserInputRequest?.id,
                    remoteInteractionID: session.pendingUserInputRequest?.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    session.pendingUserInputRequest = request
                }
            case let .mcpElicitation(interactionID, request):
                if !Self.interactionMatches(
                    session.pendingMCPElicitationRequest?.id,
                    remoteInteractionID: session.pendingMCPElicitationRequest?.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    session.pendingMCPElicitationRequest = request
                }
            }
        } else {
            clearPendingInteractions(session)
        }
        session.runState = runState
        if runState == .running {
            session.setRunningStatus("Running on \(session.remoteHost?.hostDisplayName ?? "remote host")…", source: .transport)
        }
    }

    private func applyTerminal(status: String, to session: AgentModeViewModel.TabSession) {
        clearPendingInteractions(session)
        switch status {
        case "completed":
            session.runState = .completed
        case "cancelled":
            session.runState = .cancelled
        case "expired", "failed":
            session.runState = .failed
        default:
            session.runState = .failed
        }
        session.setRunningStatus(nil, source: nil)
    }

    private func applyChannel(_ state: RemoteChannelState, to session: AgentModeViewModel.TabSession) {
        switch state.kind {
        case .connected:
            surfacedChannelReasonsByTabID[session.tabID] = []
            if session.runState.isActive {
                session.setRunningStatus("Connected to \(session.remoteHost?.hostDisplayName ?? "remote host")", source: .transport)
            }
        case let .degraded(reason):
            let displayReason = Self.displayChannelReason(reason)
            session.setRunningStatus("Remote reconnecting (\(displayReason))…", source: .reconnect)
            surfaceChannelReasonIfNeeded(displayReason, to: session)
        case .revoked:
            surfacedChannelReasonsByTabID.removeValue(forKey: session.tabID)
            session.runState = .failed
            clearPendingInteractions(session)
            appendSystemMessage("Remote host revoked this device. Forget and pair again to restore access.", to: session)
        }
    }

    private func optimisticallyClearPendingInteraction(
        _ session: AgentModeViewModel.TabSession,
        interactionID: String
    ) {
        clearPendingInteractions(session, matching: interactionID)
        session.runState = .running
        session.setRunningStatus("Sending response to \(session.remoteHost?.hostDisplayName ?? "remote host")…", source: .transport)
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func clearResolvedInteraction(tabID: UUID, interactionID: String, resolvedBy _: String?) {
        guard let session = viewModel?.sessions[tabID] else { return }
        clearPendingInteractions(session, matching: interactionID)
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
    }

    private func clearPendingInteractions(
        _ session: AgentModeViewModel.TabSession,
        matching interactionID: String? = nil,
        preserving preservedInteractionID: String? = nil
    ) {
        func shouldClear(_ id: UUID?, remoteInteractionID: String? = nil) -> Bool {
            if let preservedInteractionID,
               Self.interactionMatches(
                   id,
                   remoteInteractionID: remoteInteractionID,
                   interactionID: preservedInteractionID
               )
            {
                return false
            }
            guard let interactionID else { return true }
            return Self.interactionMatches(id, remoteInteractionID: remoteInteractionID, interactionID: interactionID)
        }
        let approvalRemoteID = approvalRemoteInteractionID(session.pendingApproval)
        if shouldClear(session.pendingApproval?.id, remoteInteractionID: approvalRemoteID) { session.pendingApproval = nil }
        if shouldClear(session.pendingAskUser?.interaction.id, remoteInteractionID: session.pendingAskUser?.interaction.remoteInteractionID) { session.pendingAskUser = nil }
        if shouldClear(session.pendingUserInputRequest?.id, remoteInteractionID: session.pendingUserInputRequest?.remoteInteractionID) { session.pendingUserInputRequest = nil }
        if shouldClear(session.pendingMCPElicitationRequest?.id, remoteInteractionID: session.pendingMCPElicitationRequest?.remoteInteractionID) { session.pendingMCPElicitationRequest = nil }
        if interactionID == nil {
            session.pendingPermissionsRequest = nil
            session.queuedUserInputRequests.removeAll()
            session.queuedMCPElicitationRequests.removeAll()
        }
    }

    private func surfaceChannelReasonIfNeeded(_ reason: String, to session: AgentModeViewModel.TabSession) {
        var reasons = surfacedChannelReasonsByTabID[session.tabID, default: []]
        guard reasons.insert(reason).inserted else { return }
        surfacedChannelReasonsByTabID[session.tabID] = reasons
        appendSystemMessage("Remote channel degraded: \(reason). Reconnecting…", to: session)
    }

    private func appendSystemMessage(_ message: String, tabID: UUID) {
        guard let session = viewModel?.sessions[tabID] else { return }
        appendSystemMessage(message, to: session)
    }

    private func appendSystemMessage(_ message: String, to session: AgentModeViewModel.TabSession) {
        session.appendItem(.system(message))
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private func updateSessionIndex(for session: AgentModeViewModel.TabSession) {
        guard let viewModel,
              let sessionID = session.activeAgentSessionID,
              let remoteHost = session.remoteHost
        else { return }
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: session.tabID,
            name: viewModel.resolvedSessionDisplayName(for: session.tabID),
            lastUserMessageAt: session.lastUserMessageAt,
            savedAt: session.lastActivityAt,
            lastRunStateRaw: session.runState.rawValue,
            itemCount: max(session.transcriptCanonicalVisibleRowCount, session.items.count),
            agentKindRaw: session.selectedAgent.rawValue,
            agentModelRaw: session.selectedModelRaw,
            agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            remoteHostID: remoteHost.hostID,
            remoteHostName: remoteHost.hostDisplayName,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    private static func normalizedTextKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayChannelReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "channel_closing" : trimmed
    }

    private static func interactionMatches(
        _ id: UUID?,
        remoteInteractionID: String?,
        interactionID: String
    ) -> Bool {
        if id?.uuidString.caseInsensitiveCompare(interactionID) == .orderedSame {
            return true
        }
        return remoteInteractionID?.caseInsensitiveCompare(interactionID) == .orderedSame
    }

    private func approvalRemoteInteractionID(_ request: AgentApprovalRequest?) -> String? {
        if case let .remoteGateway(interactionID)? = request?.requestID {
            return interactionID
        }
        return nil
    }

    #if DEBUG
        func test_applyChannel(_ state: RemoteChannelState, to session: AgentModeViewModel.TabSession) {
            applyChannel(state, to: session)
        }

        func test_attachController(
            tabID: UUID,
            hostID: String,
            controller: RemoteAgentSessionController,
            connection: RemoteHostConnection
        ) {
            controllersByTabID[tabID] = controller
            hostIDByTabID[tabID] = hostID
            startEventTask(for: tabID, controller: controller)
            startConnectionFanoutIfNeeded(hostID: hostID, connection: connection)
        }

        func test_lifecycleCounts() -> (controllers: Int, eventTasks: Int, hostFanoutTasks: Int, tabHostBindings: Int) {
            (
                controllers: controllersByTabID.count,
                eventTasks: eventTasksByTabID.count,
                hostFanoutTasks: connectionTasksByHostID.count,
                tabHostBindings: hostIDByTabID.count
            )
        }
    #endif

    static func describe(_ error: Error) -> String {
        if (error as? RemoteClientError)?.commandError?.code == "binding_required" {
            return "The host couldn't route this message to its window. Try again — if it keeps failing, the session's window may have been closed on the host."
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }
}
