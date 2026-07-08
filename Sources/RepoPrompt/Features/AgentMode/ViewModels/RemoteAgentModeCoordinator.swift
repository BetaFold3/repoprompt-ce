import Foundation
import OSLog
import RepoPromptRemoteWire

@MainActor
final class RemoteAgentModeCoordinator {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "RemoteAgentModeCoordinator")

    private struct HostConnectionTasks {
        var inbound: Task<Void, Never>
        var state: Task<Void, Never>
    }

    private struct RemoteChildDiscoveryContext {
        var key: String
        var parentTabID: UUID
        var parentRemoteSessionID: String
        var hostBinding: AgentSessionRemoteHostBinding
    }

    private weak var viewModel: AgentModeViewModel?
    private let connectionManagerProvider: @MainActor () -> RemoteHostConnectionManager
    private var controllersByTabID: [UUID: RemoteAgentSessionController] = [:]
    private var eventTasksByTabID: [UUID: Task<Void, Never>] = [:]
    private var hostIDByTabID: [UUID: String] = [:]
    private var connectionTasksByHostID: [String: HostConnectionTasks] = [:]
    private var surfacedChannelReasonsByTabID: [UUID: Set<String>] = [:]
    private var lastAdoptedHostNameByTabID: [UUID: String] = [:]
    private var startSessionNameByTabID: [UUID: String] = [:]
    private var childDiscoveryInFlightKeys: Set<String> = []
    private var childDiscoveryImmediatePendingKeys: Set<String> = []
    private var activeRunStateChildDiscoveryKeys: Set<String> = []
    private var discoveryKeyByTabID: [UUID: String] = [:]
    private var reportedChildMaterializationFailuresByDiscoveryKey: [String: Set<String>] = [:]
    private var childDiscoveryPendingContextsByKey: [String: RemoteChildDiscoveryContext] = [:]
    private var childDiscoveryTasksByKey: [String: Task<Void, Never>] = [:]
    private var lastChildDiscoveryStartedAtByKey: [String: Date] = [:]
    private let childDiscoveryDebounceInterval: TimeInterval
    #if DEBUG
        private var materializedRemoteChildAttachHandler: (@MainActor (AgentModeViewModel.TabSession) async throws -> Void)?
    #endif

    init(
        connectionManagerProvider: @escaping @MainActor () -> RemoteHostConnectionManager = { RemoteHostConnectionManager.shared },
        childDiscoveryDebounceInterval: TimeInterval = 3
    ) {
        self.connectionManagerProvider = connectionManagerProvider
        self.childDiscoveryDebounceInterval = childDiscoveryDebounceInterval
    }

    func attach(viewModel: AgentModeViewModel) {
        self.viewModel = viewModel
    }

    func attachPersistedSessionIfNeeded(_ session: AgentModeViewModel.TabSession) {
        guard session.remoteHost != nil else { return }
        guard !(session.parentSessionID != nil && session.runState.isTerminalForCommit) else { return }
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
        workspaceID: String?,
        workspaceName: String?,
        allowHostSessionNameAdoptionFromStartName: Bool = false
    ) async throws {
        let controller = try controller(for: session)
        recordStartSessionName(
            sessionName,
            tabID: session.tabID,
            allowHostSessionNameAdoptionFromStartName: allowHostSessionNameAdoptionFromStartName
        )
        session.runState = .running
        session.setRunningStatus("Starting on \(session.remoteHost?.hostDisplayName ?? "remote host")…", source: .transport)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        let remoteSessionID = try await controller.start(
            message: message,
            modelSelectionRaw: modelSelectionRaw,
            sessionName: sessionName,
            windowID: windowID,
            workspaceID: workspaceID,
            workspaceName: workspaceName
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
        let remoteBinding = viewModel?.sessions[tabID]?.remoteHost
        let storedDiscoveryKey = discoveryKeyByTabID.removeValue(forKey: tabID)
        let currentDiscoveryKey = viewModel?.sessions[tabID].flatMap { childDiscoveryKey(for: $0) }
        for key in Set([storedDiscoveryKey, currentDiscoveryKey].compactMap(\.self)) {
            cancelChildDiscovery(key: key)
        }
        eventTasksByTabID.removeValue(forKey: tabID)?.cancel()
        surfacedChannelReasonsByTabID.removeValue(forKey: tabID)
        lastAdoptedHostNameByTabID.removeValue(forKey: tabID)
        startSessionNameByTabID.removeValue(forKey: tabID)
        let controller = controllersByTabID.removeValue(forKey: tabID)
        if let hostID = hostIDByTabID.removeValue(forKey: tabID) {
            stopConnectionFanoutIfUnused(hostID: hostID)
        }
        if let controller {
            Task {
                await controller.unsubscribe()
                await controller.shutdown()
            }
        } else if let remoteBinding {
            do {
                let connection = try connectionManagerProvider().connection(for: remoteBinding.hostID)
                Task {
                    do {
                        try await connection.unsubscribe(sessionIDs: [remoteBinding.remoteSessionID])
                    } catch {
                        Self.logger.debug("remote unsubscribe failed host_id=\(remoteBinding.hostID, privacy: .public) session_id=\(remoteBinding.remoteSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                Self.logger.debug("remote unsubscribe skipped host_id=\(remoteBinding.hostID, privacy: .public) session_id=\(remoteBinding.remoteSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
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
        let shouldRefreshActivity = Self.shouldRefreshActivity(for: event)
        if shouldRefreshActivity {
            session.lastActivityAt = Date()
        }
        switch event {
        case let .transcriptRows(rows):
            let containsSpawnTool = Self.containsSpawnToolCall(rows)
            applyTranscriptRows(rows, to: session)
            if containsSpawnTool {
                requestChildSessionDiscovery(for: session, reason: "transcript_spawn")
            }
        case let .runState(runState, pendingInteraction):
            applyRunState(runState, pendingInteraction: pendingInteraction, to: session)
            if runState.isActive {
                requestFirstActiveChildSessionDiscovery(for: session, reason: "session_update")
            }
        case let .interactionResolved(interactionID, resolvedBy):
            clearResolvedInteraction(tabID: tabID, interactionID: interactionID, resolvedBy: resolvedBy)
        case .sessionExpired:
            session.runState = .failed
            clearPendingInteractions(session)
            appendSystemMessage("Remote session expired on host.", tabID: tabID)
        case let .terminal(status):
            applyTerminal(status: status, to: session)
            requestChildSessionDiscovery(for: session, reason: "terminal", immediate: true)
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
            adoptHostSessionNameIfAllowed(sessionName, for: session, tabID: tabID)
        case let .binding(binding):
            session.remoteHost = binding
        }
        if shouldRefreshActivity {
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
        let wasTerminal = Self.isTerminalRunState(session.runState)
        session.mutateItemsBatch { items in
            let existingItemIDs = Set(items.map(\.id))
            let optimisticUserTimestampByText = Self.optimisticUserTimestampByText(
                in: items,
                pendingIDs: session.pendingRemoteOptimisticUserItemIDs,
                projectedUserTextKeys: projectedUserTextKeys
            )
            var merged = projector.upserting(rows, into: items)
            if !projectedUserTextKeys.isEmpty, !session.pendingRemoteOptimisticUserItemIDs.isEmpty {
                merged = merged.map { item in
                    guard item.kind == .user,
                          !existingItemIDs.contains(item.id),
                          let optimisticTimestamp = optimisticUserTimestampByText[Self.normalizedTextKey(item.text)],
                          optimisticTimestamp > item.timestamp
                    else { return item }
                    return item.replacingTimestamp(optimisticTimestamp)
                }
                merged.removeAll { item in
                    item.kind == .user
                        && session.pendingRemoteOptimisticUserItemIDs.contains(item.id)
                        && projectedUserTextKeys.contains(Self.normalizedTextKey(item.text))
                }
                session.pendingRemoteOptimisticUserItemIDs = session.pendingRemoteOptimisticUserItemIDs.filter { id in
                    merged.contains { $0.id == id }
                }
            }
            if wasTerminal {
                _ = Self.settleResultlessToolCalls(in: &merged, terminalRunState: session.runState)
            }
            items = merged
        }
        logTranscriptRowsApplied(rows, remoteSessionID: remoteSessionID, tabID: session.tabID)
        if wasTerminal {
            viewModel?.ensureDerivedTranscriptCurrentForExport(tabID: session.tabID)
        }
        session.hasSentFirstMessage = session.items.contains { $0.kind == .user }
        session.lastUserMessageAt = session.items
            .filter { $0.kind == .user }
            .map(\.timestamp)
            .filter { $0 >= AgentSessionRecencySanity.syntheticTimestampFloor }
            .max() ?? session.lastUserMessageAt
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
        session.mutateItemsBatch { items in
            _ = Self.settleResultlessToolCalls(in: &items, terminalStatus: status)
        }
    }

    private func requestFirstActiveChildSessionDiscovery(
        for session: AgentModeViewModel.TabSession,
        reason: String
    ) {
        guard let context = childDiscoveryContext(for: session),
              controllersByTabID[session.tabID] != nil,
              activeRunStateChildDiscoveryKeys.insert(context.key).inserted
        else { return }
        requestChildSessionDiscovery(for: session, reason: reason)
    }

    private func requestChildSessionDiscovery(
        for session: AgentModeViewModel.TabSession,
        reason _: String,
        immediate: Bool = false
    ) {
        guard let context = childDiscoveryContext(for: session) else { return }
        guard let controller = controllersByTabID[session.tabID] else { return }
        recordDiscoveryKey(context.key, tabID: context.parentTabID)
        if childDiscoveryInFlightKeys.contains(context.key) {
            childDiscoveryPendingContextsByKey[context.key] = context
            if immediate {
                childDiscoveryImmediatePendingKeys.insert(context.key)
            }
            return
        }
        if !immediate,
           let lastStartedAt = lastChildDiscoveryStartedAtByKey[context.key]
        {
            let delay = childDiscoveryDebounceInterval - Date().timeIntervalSince(lastStartedAt)
            if delay > 0 {
                childDiscoveryPendingContextsByKey[context.key] = context
                guard childDiscoveryTasksByKey[context.key] == nil else { return }
                childDiscoveryTasksByKey[context.key] = Task { [weak self, key = context.key] in
                    let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                    if nanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                    guard !Task.isCancelled else { return }
                    await self?.startPendingChildDiscovery(key: key)
                }
                return
            }
        }
        if immediate {
            childDiscoveryTasksByKey.removeValue(forKey: context.key)?.cancel()
            childDiscoveryPendingContextsByKey.removeValue(forKey: context.key)
            childDiscoveryImmediatePendingKeys.remove(context.key)
        }
        startChildDiscovery(context: context, controller: controller)
    }

    private func startPendingChildDiscovery(key: String) {
        childDiscoveryTasksByKey.removeValue(forKey: key)
        childDiscoveryImmediatePendingKeys.remove(key)
        guard let pending = childDiscoveryPendingContextsByKey.removeValue(forKey: key),
              let controller = controllersByTabID[pending.parentTabID]
        else { return }
        startChildDiscovery(context: pending, controller: controller)
    }

    private func startChildDiscovery(
        context: RemoteChildDiscoveryContext,
        controller: RemoteAgentSessionController
    ) {
        lastChildDiscoveryStartedAtByKey[context.key] = Date()
        childDiscoveryInFlightKeys.insert(context.key)
        childDiscoveryTasksByKey[context.key]?.cancel()
        childDiscoveryTasksByKey[context.key] = Task { [weak self, controller, context] in
            do {
                let descriptors = try await controller.listChildSessions()
                await self?.completeChildDiscovery(context: context, descriptors: descriptors)
            } catch is CancellationError {
                self?.finishChildDiscovery(context: context)
            } catch {
                self?.failChildDiscovery(context: context, error: error)
            }
        }
    }

    private func completeChildDiscovery(
        context: RemoteChildDiscoveryContext,
        descriptors: [RemoteAgentSessionDescriptor]
    ) async {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        // Discovery may resume after the parent tab was stopped (for example a run-location
        // switch): never materialize children or restart discovery for a torn-down parent.
        guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
            finishChildDiscovery(context: context)
            return
        }
        for descriptor in descriptors {
            guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
                finishChildDiscovery(context: context)
                return
            }
            await materializeRemoteChildSession(descriptor, context: context)
        }
        childDiscoveryInFlightKeys.remove(context.key)
        restartPendingChildDiscoveryIfNeeded(after: context)
    }

    private func failChildDiscovery(context: RemoteChildDiscoveryContext, error _: Error) {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        childDiscoveryInFlightKeys.remove(context.key)
        restartPendingChildDiscoveryIfNeeded(after: context)
    }

    private func finishChildDiscovery(context: RemoteChildDiscoveryContext) {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        childDiscoveryInFlightKeys.remove(context.key)
        childDiscoveryImmediatePendingKeys.remove(context.key)
        childDiscoveryPendingContextsByKey.removeValue(forKey: context.key)
    }

    private func restartPendingChildDiscoveryIfNeeded(after context: RemoteChildDiscoveryContext) {
        guard let pending = childDiscoveryPendingContextsByKey.removeValue(forKey: context.key),
              let controller = controllersByTabID[pending.parentTabID]
        else { return }
        if childDiscoveryImmediatePendingKeys.remove(context.key) != nil {
            startChildDiscovery(context: pending, controller: controller)
            return
        }
        let delay = childDiscoveryDebounceInterval - Date().timeIntervalSince(lastChildDiscoveryStartedAtByKey[context.key] ?? .distantPast)
        if delay > 0 {
            childDiscoveryPendingContextsByKey[context.key] = pending
            guard childDiscoveryTasksByKey[context.key] == nil else { return }
            childDiscoveryTasksByKey[context.key] = Task { [weak self, key = context.key] in
                let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
                guard !Task.isCancelled else { return }
                await self?.startPendingChildDiscovery(key: key)
            }
            return
        }
        startChildDiscovery(context: pending, controller: controller)
    }

    private func materializeRemoteChildSession(
        _ descriptor: RemoteAgentSessionDescriptor,
        context: RemoteChildDiscoveryContext
    ) async {
        let childRemoteSessionID = descriptor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !childRemoteSessionID.isEmpty,
              childRemoteSessionID != context.parentRemoteSessionID,
              descriptor.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == context.parentRemoteSessionID,
              !isRemoteSessionMaterialized(hostID: context.hostBinding.hostID, remoteSessionID: childRemoteSessionID)
        else { return }
        guard let viewModel,
              let parentSession = viewModel.sessions[context.parentTabID]
        else { return }
        guard let childSession = await viewModel.materializeRemoteChildSession(
            descriptor,
            parentSession: parentSession,
            parentRemoteHost: context.hostBinding
        ) else {
            reportChildMaterializationFailureIfNeeded(
                childRemoteSessionID: childRemoteSessionID,
                context: context
            )
            return
        }
        clearReportedChildMaterializationFailure(
            childRemoteSessionID: childRemoteSessionID,
            discoveryKey: context.key
        )
        if let adoptedName = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !adoptedName.isEmpty
        {
            lastAdoptedHostNameByTabID[childSession.tabID] = AgentSession.validatedName(adoptedName)
        }
        do {
            try await attachMaterializedRemoteChildSession(childSession)
        } catch {
            appendSystemMessage("Remote child session attach failed: \(Self.describe(error))", tabID: context.parentTabID)
        }
    }

    private func attachMaterializedRemoteChildSession(_ session: AgentModeViewModel.TabSession) async throws {
        #if DEBUG
            if let materializedRemoteChildAttachHandler {
                try await materializedRemoteChildAttachHandler(session)
                return
            }
        #endif
        let controller = try controller(for: session)
        try await controller.attachAndCatchUp()
    }

    private func childDiscoveryContext(for session: AgentModeViewModel.TabSession) -> RemoteChildDiscoveryContext? {
        guard let remoteHost = session.remoteHost,
              session.activeAgentSessionID != nil
        else { return nil }
        let parentRemoteSessionID = remoteHost.remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parentRemoteSessionID.isEmpty else { return nil }
        return RemoteChildDiscoveryContext(
            key: childDiscoveryKey(hostID: remoteHost.hostID, remoteSessionID: parentRemoteSessionID),
            parentTabID: session.tabID,
            parentRemoteSessionID: parentRemoteSessionID,
            hostBinding: remoteHost
        )
    }

    private func childDiscoveryKey(for session: AgentModeViewModel.TabSession) -> String? {
        guard let remoteHost = session.remoteHost else { return nil }
        let parentRemoteSessionID = remoteHost.remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parentRemoteSessionID.isEmpty else { return nil }
        return childDiscoveryKey(hostID: remoteHost.hostID, remoteSessionID: parentRemoteSessionID)
    }

    private func childDiscoveryKey(hostID: String, remoteSessionID: String) -> String {
        "\(hostID)|\(remoteSessionID)"
    }

    private func recordDiscoveryKey(_ key: String, tabID: UUID) {
        if let previousKey = discoveryKeyByTabID[tabID], previousKey != key {
            cancelChildDiscovery(key: previousKey)
        }
        discoveryKeyByTabID[tabID] = key
    }

    private func cancelChildDiscovery(key: String) {
        childDiscoveryTasksByKey.removeValue(forKey: key)?.cancel()
        childDiscoveryInFlightKeys.remove(key)
        activeRunStateChildDiscoveryKeys.remove(key)
        childDiscoveryImmediatePendingKeys.remove(key)
        childDiscoveryPendingContextsByKey.removeValue(forKey: key)
        lastChildDiscoveryStartedAtByKey.removeValue(forKey: key)
        reportedChildMaterializationFailuresByDiscoveryKey.removeValue(forKey: key)
        discoveryKeyByTabID = discoveryKeyByTabID.filter { $0.value != key }
    }

    private func reportChildMaterializationFailureIfNeeded(
        childRemoteSessionID: String,
        context: RemoteChildDiscoveryContext
    ) {
        var reported = reportedChildMaterializationFailuresByDiscoveryKey[context.key, default: []]
        if reported.insert(childRemoteSessionID).inserted {
            reportedChildMaterializationFailuresByDiscoveryKey[context.key] = reported
            appendSystemMessage(
                "Remote child session materialization failed for '\(childRemoteSessionID)'.",
                tabID: context.parentTabID
            )
        } else {
            Self.logger.debug("remote child materialization failure already reported discovery_key=\(context.key, privacy: .public) child_session_id=\(childRemoteSessionID, privacy: .public)")
        }
    }

    private func clearReportedChildMaterializationFailure(
        childRemoteSessionID: String,
        discoveryKey: String
    ) {
        guard var reported = reportedChildMaterializationFailuresByDiscoveryKey[discoveryKey] else { return }
        reported.remove(childRemoteSessionID)
        if reported.isEmpty {
            reportedChildMaterializationFailuresByDiscoveryKey.removeValue(forKey: discoveryKey)
        } else {
            reportedChildMaterializationFailuresByDiscoveryKey[discoveryKey] = reported
        }
    }

    private func isRemoteSessionMaterialized(hostID: String, remoteSessionID: String) -> Bool {
        viewModel?.sessions.values.contains { session in
            session.remoteHost?.hostID == hostID
                && session.remoteHost?.remoteSessionID == remoteSessionID
        } == true
    }

    private func logTranscriptRowsApplied(_ rows: [AgentChatItem], remoteSessionID: String, tabID: UUID) {
        let lastAssistant = rows.last { $0.kind == .assistant }
        let lastAssistantIDSuffix = lastAssistant.map { String($0.id.uuidString.suffix(12)) } ?? "none"
        let lastAssistantTextCount = lastAssistant?.text.count ?? -1
        Self.logger.log("remote transcript apply session_id=\(remoteSessionID, privacy: .public) tab_id=\(tabID.uuidString, privacy: .public) applied_row_count=\(rows.count) last_assistant_id_suffix=\(lastAssistantIDSuffix, privacy: .public) last_assistant_text_count=\(lastAssistantTextCount)")
    }

    private static func optimisticUserTimestampByText(
        in items: [AgentChatItem],
        pendingIDs: Set<UUID>,
        projectedUserTextKeys: Set<String>
    ) -> [String: Date] {
        guard !pendingIDs.isEmpty, !projectedUserTextKeys.isEmpty else { return [:] }
        var timestamps: [String: Date] = [:]
        for item in items where item.kind == .user && pendingIDs.contains(item.id) {
            let key = normalizedTextKey(item.text)
            guard projectedUserTextKeys.contains(key) else { continue }
            if let existing = timestamps[key] {
                timestamps[key] = max(existing, item.timestamp)
            } else {
                timestamps[key] = item.timestamp
            }
        }
        return timestamps
    }

    private static func containsSpawnToolCall(_ rows: [AgentChatItem]) -> Bool {
        rows.contains { row in
            guard row.kind == .toolCall,
                  let toolName = row.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { return false }
            return toolName == "agent_run" || toolName == "agent_manage"
        }
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalRunState: AgentSessionRunState
    ) -> Int {
        settleResultlessToolCalls(in: &items, terminalSettlement: terminalSettlement(for: terminalRunState))
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalStatus: String
    ) -> Int {
        settleResultlessToolCalls(in: &items, terminalSettlement: terminalSettlement(for: terminalStatus))
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalSettlement: (statusWord: String, isError: Bool)
    ) -> Int {
        var settledCount = 0
        for index in items.indices where items[index].kind == .toolCall
            && items[index].toolResultJSON == nil
            && items[index].toolIsError == nil
        {
            items[index].toolResultJSON = AgentToolResultPersistencePolicy.minimalResultJSON(
                statusWord: terminalSettlement.statusWord,
                normalizedToolName: items[index].toolName
            )
            items[index].toolIsError = terminalSettlement.isError
            settledCount += 1
        }
        return settledCount
    }

    private static func terminalSettlement(for runState: AgentSessionRunState) -> (statusWord: String, isError: Bool) {
        switch runState {
        case .completed:
            ("completed", false)
        case .cancelled:
            ("cancelled", true)
        case .failed:
            ("failed", true)
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            ("failed", true)
        }
    }

    private static func terminalSettlement(for status: String) -> (statusWord: String, isError: Bool) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed":
            ("completed", false)
        case "cancelled", "canceled":
            ("cancelled", true)
        case "expired", "failed":
            ("failed", true)
        default:
            ("failed", true)
        }
    }

    private static func isTerminalRunState(_ runState: AgentSessionRunState) -> Bool {
        runState == .completed || runState == .cancelled || runState == .failed
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

    private func recordStartSessionName(
        _ sessionName: String?,
        tabID: UUID,
        allowHostSessionNameAdoptionFromStartName: Bool
    ) {
        guard allowHostSessionNameAdoptionFromStartName,
              let sessionName
        else { return }
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSessionNameByTabID[tabID] = AgentSession.validatedName(trimmed)
    }

    private func adoptHostSessionNameIfAllowed(
        _ sessionName: String?,
        for session: AgentModeViewModel.TabSession,
        tabID: UUID
    ) {
        guard session.remoteHost != nil,
              let viewModel,
              let sessionName
        else { return }
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hostName = AgentSession.validatedName(trimmed)
        guard !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let currentName = viewModel.resolvedSessionDisplayName(for: tabID)
        guard hostName != currentName else { return }

        let shouldAdopt = AgentSessionTitleNaming.isDefaultSessionTitle(currentName)
            || lastAdoptedHostNameByTabID[tabID] == currentName
            || startSessionNameByTabID[tabID] == currentName
        guard shouldAdopt else { return }

        viewModel.renameSession(tabID: tabID, to: hostName)
        lastAdoptedHostNameByTabID[tabID] = hostName
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

    private static func shouldRefreshActivity(for event: RemoteSessionEvent) -> Bool {
        switch event {
        case .transcriptRows, .runState, .terminal, .metadata:
            true
        case .interactionResolved, .sessionExpired, .channel, .systemMessage, .binding:
            false
        }
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

        func test_applyMetadata(
            agentKindRaw: String? = nil,
            modelRaw: String? = nil,
            sessionName: String?,
            tabID: UUID
        ) {
            handle(.metadata(agentKindRaw: agentKindRaw, modelRaw: modelRaw, sessionName: sessionName), tabID: tabID)
        }

        func test_handleEvent(_ event: RemoteSessionEvent, tabID: UUID) {
            handle(event, tabID: tabID)
        }

        func test_applyTranscriptRows(_ rows: [AgentChatItem], to session: AgentModeViewModel.TabSession) {
            applyTranscriptRows(rows, to: session)
        }

        func test_recordStartSessionName(
            _ sessionName: String?,
            tabID: UUID,
            allowHostSessionNameAdoptionFromStartName: Bool = true
        ) {
            recordStartSessionName(
                sessionName,
                tabID: tabID,
                allowHostSessionNameAdoptionFromStartName: allowHostSessionNameAdoptionFromStartName
            )
        }

        func test_setMaterializedRemoteChildAttachHandler(
            _ handler: (@MainActor (AgentModeViewModel.TabSession) async throws -> Void)?
        ) {
            materializedRemoteChildAttachHandler = handler
        }

        func test_requestChildSessionDiscovery(tabID: UUID) {
            guard let session = viewModel?.sessions[tabID] else { return }
            requestChildSessionDiscovery(for: session, reason: "test")
        }

        func test_startSessionNameRecord(tabID: UUID) -> String? {
            startSessionNameByTabID[tabID]
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
