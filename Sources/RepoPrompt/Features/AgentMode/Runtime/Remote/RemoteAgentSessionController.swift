import Foundation
import OSLog
import RepoPromptRemoteWire

protocol RemoteAgentSessionConnection: Sendable {
    func command(_ frame: RemoteClientFrame, timeout: TimeInterval) async throws -> JSONValue
    func ensureConnected() async throws
    func subscribe(sessionIDs: [String]) async throws
    func unsubscribe(sessionIDs: [String]) async throws
    /// Whether the connected host advertised an optional `hello_ack` feature
    /// (see `RemoteWireFeatures`). Defaults to false so legacy fakes and hosts
    /// degrade to legacy behavior.
    func supportsHostFeature(_ feature: String) async -> Bool
}

extension RemoteAgentSessionConnection {
    func command(_ frame: RemoteClientFrame) async throws -> JSONValue {
        try await command(frame, timeout: RemoteHostConnection.commandTimeout)
    }

    func supportsHostFeature(_: String) async -> Bool {
        false
    }
}

extension RemoteHostConnection: RemoteAgentSessionConnection {}

protocol RemoteAgentSessionRecoveryScheduling: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct RemoteAgentSessionTaskRecoveryScheduler: RemoteAgentSessionRecoveryScheduling {
    func sleep(seconds: TimeInterval) async throws {
        let milliseconds = Int64((max(0, seconds) * 1000).rounded(.up))
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

struct RemoteAgentSessionRecoveryPolicy {
    var staleIntervalSeconds: TimeInterval
    var retryDelaySeconds: [TimeInterval]

    static let `default` = RemoteAgentSessionRecoveryPolicy(
        staleIntervalSeconds: 30,
        retryDelaySeconds: [5, 10]
    )
}

struct RemoteChannelState: Equatable {
    enum Kind: Equatable {
        case connected
        case degraded(reason: String)
        case revoked
    }

    var kind: Kind
}

struct RemoteAgentSessionDescriptor: Equatable {
    var sessionID: String
    var name: String?
    var stateRaw: String?
    var agentKindRaw: String?
    var agentModelRaw: String?
    var parentSessionID: String?
    var lastModified: Date?
    var itemCount: Int?
    var originSummary: String?
    var isLive: Bool?
}

private enum RemoteLogPagingError: Error, CustomStringConvertible {
    case missingSession
    case missingProjector

    var description: String {
        switch self {
        case .missingSession:
            "Remote transcript catch-up has no active session."
        case .missingProjector:
            "Remote transcript catch-up has no transcript projector."
        }
    }
}

enum RemoteSessionEvent: Equatable {
    case transcriptRows(
        items: [AgentChatItem],
        removedIDs: [UUID],
        hostRowIDByClientItemID: [UUID: UUID]
    )
    case runState(AgentSessionRunState, pendingInteraction: RemotePendingInteraction?, statusText: String?)
    case interactionResolved(interactionID: String, resolvedBy: String?)
    case sessionExpired
    case terminal(status: String)
    case channel(RemoteChannelState)
    case systemMessage(String)
    case metadata(agentKindRaw: String?, modelRaw: String?, reasoningEffortRaw: String?, sessionName: String?)
    case binding(AgentSessionRemoteHostBinding)
}

actor RemoteAgentSessionController {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "RemoteControlClient")

    nonisolated let events: AsyncStream<RemoteSessionEvent>

    private let hostID: String
    private let hostDisplayName: String
    private let connection: any RemoteAgentSessionConnection
    private let recoveryScheduler: any RemoteAgentSessionRecoveryScheduling
    private let recoveryPolicy: RemoteAgentSessionRecoveryPolicy
    private let eventsContinuation: AsyncStream<RemoteSessionEvent>.Continuation
    private var remoteSessionID: String?
    private var lastAppliedSeq: UInt64
    private var seqEpoch: String?
    private var retiredSeqEpochs: Set<String> = []
    private var nextLogOffset: Int
    private var projector: RemoteTranscriptProjector?
    private var lastKnownRunState: AgentSessionRunState = .idle
    private var scheduledLogCatchUpTask: Task<Void, Never>?
    private var scheduledLogCatchUpDirty = false
    private var catchUpTask: Task<Void, Error>?
    private var catchUpTaskID: UUID?
    private var catchUpTaskSessionID: String?
    private var catchUpTaskLifecycleGeneration: UUID?
    private var catchUpTaskPollsHost: Bool?
    private var observationRecoveryTask: Task<Void, Never>?
    private var observationRecoveryGeneration: UUID?
    private var observationLifecycleGeneration = UUID()
    private var observationEnabled = true
    private var attachedObservationSessionID: String?
    private var staleRecoveryTask: Task<Void, Never>?
    private var staleRecoveryGeneration: UUID?
    private var staleProgressGeneration: UInt64 = 0
    private var observationPaused = false
    private var didReportObservationFailure = false
    private var didReportLogCatchUpFailure = false
    private var didYieldSessionExpired = false
    private var didTerminalSettleReRead = false
    /// One-shot version-skew latch: set when a host that advertised
    /// `get_log_row_timestamps` still rejected the payload key, so every later
    /// fetch degrades to the legacy timestampless request.
    private var hostRejectedGetLogRowTimestamps = false
    /// One-shot version-skew latch matching the timestamp fallback for hosts that
    /// advertise `get_log_host_row_ids` but reject `include_host_row_ids`.
    private var hostRejectedGetLogHostRowIDs = false
    private var hostRowIDByClientItemID: [UUID: UUID] = [:]
    private var projectedRowIDsByPageOffset: [Int: Set<UUID>] = [:]
    private var lastCompletePageOffset: Int?
    private var lastLegacyAdvanceOffset: Int?
    private var isShutdown = false

    init(
        binding: AgentSessionRemoteHostBinding,
        connection: any RemoteAgentSessionConnection,
        recoveryScheduler: any RemoteAgentSessionRecoveryScheduling = RemoteAgentSessionTaskRecoveryScheduler(),
        recoveryPolicy: RemoteAgentSessionRecoveryPolicy = .default
    ) {
        hostID = binding.hostID
        hostDisplayName = binding.hostDisplayName
        remoteSessionID = binding.remoteSessionID.isEmpty ? nil : binding.remoteSessionID
        lastKnownRunState = binding.remoteSessionID.isEmpty ? .idle : .completed
        lastAppliedSeq = binding.lastAppliedSeq
        seqEpoch = Self.normalizedSequenceEpoch(binding.seqEpoch)
        nextLogOffset = binding.nextLogOffset
        self.connection = connection
        self.recoveryScheduler = recoveryScheduler
        self.recoveryPolicy = recoveryPolicy
        if !binding.remoteSessionID.isEmpty {
            projector = RemoteTranscriptProjector(remoteSessionID: binding.remoteSessionID)
        }
        var continuation: AsyncStream<RemoteSessionEvent>.Continuation!
        events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        observationEnabled = false
        observationLifecycleGeneration = UUID()
        attachedObservationSessionID = nil
        scheduledLogCatchUpTask?.cancel()
        scheduledLogCatchUpTask = nil
        scheduledLogCatchUpDirty = false
        cancelCatchUpTask()
        observationRecoveryTask?.cancel()
        observationRecoveryTask = nil
        observationRecoveryGeneration = nil
        stopStaleRecovery(reason: "shutdown")
        eventsContinuation.finish()
    }

    func start(
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        windowID: Int?,
        workspaceID: String?,
        workspaceName: String?
    ) async throws -> String {
        try ensureNotShutdown()
        observationRecoveryTask?.cancel()
        observationRecoveryTask = nil
        observationRecoveryGeneration = nil
        attachedObservationSessionID = nil
        stopStaleRecovery(reason: "start")
        scheduledLogCatchUpTask?.cancel()
        scheduledLogCatchUpTask = nil
        scheduledLogCatchUpDirty = false
        cancelCatchUpTask()
        observationPaused = false
        observationEnabled = true
        observationLifecycleGeneration = UUID()
        let observationGeneration = observationLifecycleGeneration
        var payload: [String: JSONValue] = [
            "message": .string(message),
            "detach": .bool(true)
        ]
        if let modelSelectionRaw, !modelSelectionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["model_id"] = .string(modelSelectionRaw)
        }
        if let sessionName, !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["session_name"] = .string(sessionName)
        }
        if let windowID {
            payload["window_id"] = .int(windowID)
        }
        if let workspaceID, !workspaceID.isEmpty {
            payload["workspace_id"] = .string(workspaceID)
        }
        if let workspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceName.isEmpty {
            payload["workspace_name"] = .string(workspaceName)
        }
        let frame = RemoteClientFrame(
            type: "start",
            requestID: makeRequestID(prefix: "start"),
            payload: .object(payload)
        )
        Self.logger.log("remote start request sent request_id=\(frame.requestID ?? "", privacy: .public) has_window_id=\(windowID != nil) has_workspace_id=\(workspaceID?.isEmpty == false) has_workspace_name=\(payload["workspace_name"] != nil)")
        let response: JSONValue
        do {
            response = try await commandWithTransportRetry(frame, operation: "start", mayRetryTransportLoss: true)
        } catch {
            let commandError = (error as? RemoteClientError)?.commandError
            let code = commandError?.code ?? Self.errorLogMetadata(error).code
            let hasWindowsDetails = commandError?.details?.objectValue?["windows"]?.arrayValue != nil
            let windowsCount = RemoteStartWindowOption.options(from: commandError?.details).count
            Self.logger.notice("remote start request failed request_id=\(frame.requestID ?? "", privacy: .public) code=\(code, privacy: .public) has_windows_details=\(hasWindowsDetails) windows_count=\(windowsCount)")
            throw error
        }
        let sessionID = try Self.remoteSessionID(from: response)
        let didResetCursor = sessionID != remoteSessionID
        if didResetCursor {
            lastAppliedSeq = 0
            seqEpoch = nil
            retiredSeqEpochs.removeAll()
            nextLogOffset = 0
            scheduledLogCatchUpDirty = false
            didReportLogCatchUpFailure = false
            let hadHostRowIDMappings = !hostRowIDByClientItemID.isEmpty
            resetLogReconciliationState()
            if hadHostRowIDMappings {
                eventsContinuation.yield(.transcriptRows(
                    items: [],
                    removedIDs: [],
                    hostRowIDByClientItemID: [:]
                ))
            }
        }
        didYieldSessionExpired = false
        lastKnownRunState = .running
        didTerminalSettleReRead = false
        remoteSessionID = sessionID
        Self.logger.notice("remote start response adopted request_id=\(frame.requestID ?? "", privacy: .public) session_id=\(sessionID, privacy: .public) did_reset_cursor=\(didResetCursor)")
        projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        emitBinding()
        applySnapshot(response, frameType: "session_update")
        do {
            guard try await observeAndCatchUp(
                sessionID: sessionID,
                generation: observationGeneration
            ) else { return sessionID }
        } catch {
            guard isObservationCurrent(generation: observationGeneration, sessionID: sessionID) else {
                return sessionID
            }
            guard Self.isTransientObservationFailure(error) else { throw error }
            reportObservationDegraded(error, sessionID: sessionID)
            scheduleObservationRecovery(for: sessionID, lifecycleGeneration: observationGeneration)
        }
        return sessionID
    }

    func steer(_ text: String) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        // Register before sending so throw paths also re-arm; .inDoubt catch-up can adopt
        // a parked active run before rethrowing.
        defer { recordStaleObservationProgress(reason: "steer") }
        let frame = RemoteClientFrame(
            type: "steer",
            requestID: makeRequestID(prefix: "steer"),
            sessionID: sessionID,
            payload: .object(["message": .string(text)])
        )
        let response = try await commandWithTransportRetry(frame, operation: "steer", mayRetryTransportLoss: true)
        lastKnownRunState = .running
        didTerminalSettleReRead = false
        applySnapshot(response, frameType: "session_update")
        try await catchUpFromHost()
    }

    func fork(
        upToClientItemID clientItemID: UUID,
        destinationAgent: String,
        destinationModelID: String,
        destinationEffort: String?
    ) async throws -> RemoteAgentSessionDescriptor {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        try await requireHostFeature(
            RemoteWireFeatures.forkSession,
            operationDescription: "remote session forking"
        )
        try ensureCurrentSession(sessionID, operation: "fork_session")
        let hostRowID = try requireHostRowID(forClientItemID: clientItemID)
        var payload: [String: JSONValue] = [
            "up_to_item_id": .string(hostRowID.uuidString),
            "destination_agent": .string(destinationAgent),
            "destination_model_id": .string(destinationModelID)
        ]
        if let destinationEffort {
            payload["destination_effort"] = .string(destinationEffort)
        }
        let frame = RemoteClientFrame(
            type: "fork_session",
            requestID: makeRequestID(prefix: "fork"),
            sessionID: sessionID,
            payload: .object(payload)
        )
        let response = try await commandWithLedgerCompletionRetry(
            frame,
            operation: "fork_session"
        )
        guard let sessionValue = response.objectValue?["session"],
              let descriptor = Self.sessionDescriptor(from: sessionValue)
        else {
            throw RemoteClientError.protocolViolation(
                "fork_session response did not include a valid list_sessions session descriptor."
            )
        }
        return descriptor
    }

    func extractHandoff(
        upToClientItemID clientItemID: UUID,
        maxTranscriptItems: Int? = nil,
        maxToolArgsCharacters: Int? = nil
    ) async throws -> String {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        try await requireHostFeature(
            RemoteWireFeatures.extractHandoff,
            operationDescription: "remote handoff payload extraction"
        )
        try ensureCurrentSession(sessionID, operation: "extract_handoff")
        let hostRowID = try requireHostRowID(forClientItemID: clientItemID)
        var payload: [String: JSONValue] = [
            "up_to_item_id": .string(hostRowID.uuidString)
        ]
        if let maxTranscriptItems {
            payload["max_transcript_items"] = .int(maxTranscriptItems)
        }
        if let maxToolArgsCharacters {
            payload["max_tool_args_characters"] = .int(maxToolArgsCharacters)
        }
        let frame = RemoteClientFrame(
            type: "extract_handoff",
            requestID: makeRequestID(prefix: "extract"),
            sessionID: sessionID,
            payload: .object(payload)
        )
        let response = try await commandWithTransportRetry(
            frame,
            operation: "extract_handoff",
            mayRetryTransportLoss: true
        )
        guard let handoffXML = response.objectValue?["handoff_xml"]?.stringValue,
              !handoffXML.isEmpty
        else {
            throw RemoteClientError.protocolViolation(
                "extract_handoff response did not include the inline handoff XML payload."
            )
        }
        return handoffXML
    }

    func supportsForkSessionFeature() async -> Bool {
        guard !isShutdown else { return false }
        do {
            try await connection.ensureConnected()
        } catch {
            return false
        }
        return await connection.supportsHostFeature(RemoteWireFeatures.forkSession)
    }

    func respond(interactionID: String, payload: RemoteInteractionResponsePayload) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        defer { recordStaleObservationProgress(reason: "respond") }
        let frame = RemoteClientFrame(
            type: "respond",
            requestID: makeRequestID(prefix: "respond"),
            sessionID: sessionID,
            payload: payload.wirePayload(interactionID: interactionID)
        )
        do {
            let response = try await commandWithTransportRetry(frame, operation: "respond", mayRetryTransportLoss: true)
            applySnapshot(response, frameType: "session_update")
            try await catchUpFromHost()
        } catch RemoteClientError.interactionAlreadyResolved {
            eventsContinuation.yield(.interactionResolved(interactionID: interactionID, resolvedBy: nil))
            try await catchUpFromHost()
        }
    }

    func cancel() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        defer { recordStaleObservationProgress(reason: "cancel") }
        let frame = RemoteClientFrame(
            type: "cancel",
            requestID: makeRequestID(prefix: "cancel"),
            sessionID: sessionID,
            payload: .object([:])
        )
        let response = try await commandWithTransportRetry(frame, operation: "cancel", mayRetryTransportLoss: true)
        applySnapshot(response, frameType: "session_terminal")
        try await catchUpFromHost()
    }

    /// Whether observation (subscribe + initial catch-up) has completed for the
    /// current remote session. False for controllers created lazily on a send path
    /// (e.g. restored terminal child sessions skipped by attachPersistedSessionIfNeeded)
    /// where no attach ever ran, and after a failed attach.
    func hasAttachedObservation() -> Bool {
        guard let remoteSessionID else { return false }
        return attachedObservationSessionID == remoteSessionID
    }

    func attachAndCatchUp() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        if projector == nil {
            projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        }
        let observationGeneration = observationLifecycleGeneration
        guard observationEnabled else { return }
        do {
            guard try await observeAndCatchUp(
                sessionID: sessionID,
                generation: observationGeneration
            ) else { return }
        } catch {
            guard isObservationCurrent(generation: observationGeneration, sessionID: sessionID) else {
                return
            }
            guard Self.isTransientObservationFailure(error) else { throw error }
            reportObservationDegraded(error, sessionID: sessionID)
            scheduleObservationRecovery(for: sessionID, lifecycleGeneration: observationGeneration)
        }
    }

    func listSessions(parentSessionID: String) async throws -> [RemoteAgentSessionDescriptor] {
        try ensureNotShutdown()
        let trimmedParentID = parentSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParentID.isEmpty else { return [] }
        let frame = RemoteClientFrame(
            type: "list_sessions",
            requestID: makeRequestID(prefix: "sessions"),
            payload: .object([
                "parent_session_id": .string(trimmedParentID),
                "limit": .int(500)
            ])
        )
        let response = try await commandWithTransportRetry(
            frame,
            operation: "list_sessions",
            mayRetryTransportLoss: true
        )
        return Self.sessionDescriptors(from: response)
    }

    func currentBinding() -> AgentSessionRemoteHostBinding? {
        guard let remoteSessionID else { return nil }
        return AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: hostDisplayName,
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: lastAppliedSeq,
            seqEpoch: seqEpoch,
            nextLogOffset: nextLogOffset
        )
    }

    func hostRowID(forClientItemID clientItemID: UUID) -> UUID? {
        hostRowIDByClientItemID[clientItemID]
    }

    #if DEBUG
        func test_setHostRowID(_ hostRowID: UUID, forClientItemID clientItemID: UUID) {
            hostRowIDByClientItemID[clientItemID] = hostRowID
        }

        /// Marks observation as already attached so tests can model a session that
        /// completed subscribe + catch-up before the scenario under test begins.
        func test_markObservationAttached() {
            attachedObservationSessionID = remoteSessionID
        }
    #endif

    func unsubscribe() async {
        observationEnabled = false
        observationLifecycleGeneration = UUID()
        attachedObservationSessionID = nil
        observationRecoveryTask?.cancel()
        observationRecoveryTask = nil
        observationRecoveryGeneration = nil
        stopStaleRecovery(reason: "unsubscribe")
        scheduledLogCatchUpTask?.cancel()
        scheduledLogCatchUpTask = nil
        scheduledLogCatchUpDirty = false
        cancelCatchUpTask()
        guard let sessionID = remoteSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else {
            return
        }
        let remoteHostID = hostID
        do {
            try await connection.unsubscribe(sessionIDs: [sessionID])
        } catch {
            Self.logger.debug("remote unsubscribe failed host_id=\(remoteHostID, privacy: .public) session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func listChildSessions() async throws -> [RemoteAgentSessionDescriptor] {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        let normalizedParentSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await listSessions(parentSessionID: normalizedParentSessionID).filter { descriptor in
            descriptor.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedParentSessionID
        }
    }

    func handleInboundFrame(_ frame: RemoteServerFrame) async {
        if isShutdown {
            logInboundFrameDrop(frame, reason: "shutdown")
            return
        }
        if frame.sessionID != nil, frame.sessionID != remoteSessionID {
            logInboundFrameDrop(frame, reason: "session_mismatch")
            return
        }
        if let seq = frame.seq {
            let incomingEpoch = Self.normalizedSequenceEpoch(frame.seqEpoch)
            var shouldForceEpochCatchUp = false
            if let currentEpoch = seqEpoch {
                if let incomingEpoch {
                    if incomingEpoch != currentEpoch {
                        if retiredSeqEpochs.contains(incomingEpoch) {
                            logInboundFrameDrop(frame, reason: "retired_seq_epoch")
                            return
                        }
                        retiredSeqEpochs.insert(currentEpoch)
                        seqEpoch = incomingEpoch
                        lastAppliedSeq = 0
                        shouldForceEpochCatchUp = true
                        emitBinding()
                    }
                } else {
                    retiredSeqEpochs.insert(currentEpoch)
                    seqEpoch = nil
                    lastAppliedSeq = 0
                    shouldForceEpochCatchUp = true
                    emitBinding()
                }
            } else if let incomingEpoch {
                if retiredSeqEpochs.contains(incomingEpoch) {
                    logInboundFrameDrop(frame, reason: "retired_seq_epoch")
                    return
                }
                shouldForceEpochCatchUp = lastAppliedSeq > 0
                seqEpoch = incomingEpoch
                lastAppliedSeq = 0
                emitBinding()
            }
            if shouldForceEpochCatchUp {
                await catchUpFromHostReportingFailures()
            }
            if seq <= lastAppliedSeq {
                logInboundFrameDrop(frame, reason: "seq_gated")
                return
            }
            if seq > lastAppliedSeq + 1 {
                await catchUpFromHostReportingFailures()
            }
            lastAppliedSeq = max(lastAppliedSeq, seq)
            emitBinding()
        }
        logInboundFrameHandled(frame)
        recordStaleObservationProgress(reason: "push")
        switch frame.type {
        case "session_update":
            if let payload = frame.payload {
                applySnapshot(payload, frameType: frame.type)
                scheduleLogCatchUp()
            }
        case "session_terminal":
            if let payload = frame.payload {
                applySnapshot(payload, frameType: frame.type)
                scheduleLogCatchUp()
            }
        case "session_expired":
            yieldSessionExpiredOnce()
            let sessionID = remoteSessionID ?? ""
            Self.logger.notice("remote terminal status session_id=\(sessionID, privacy: .public) status=expired")
            eventsContinuation.yield(.terminal(status: "expired"))
        case "interaction_resolved":
            let object = frame.payload?.objectValue ?? [:]
            let interactionID = object["interaction_id"]?.stringValue ?? ""
            guard !interactionID.isEmpty else { return }
            eventsContinuation.yield(.interactionResolved(
                interactionID: interactionID,
                resolvedBy: object["resolved_by"]?.stringValue
            ))
        default:
            break
        }
    }

    private func logInboundFrameDrop(_ frame: RemoteServerFrame, reason: String) {
        Self.logger.log("remote inbound frame dropped type=\(frame.type, privacy: .public) session_id=\(frame.sessionID ?? "", privacy: .public) seq=\(frame.seq ?? 0) has_seq=\(frame.seq != nil) reason=\(reason, privacy: .public)")
    }

    private func logInboundFrameHandled(_ frame: RemoteServerFrame) {
        Self.logger.log("remote inbound frame handled type=\(frame.type, privacy: .public) session_id=\(frame.sessionID ?? "", privacy: .public) seq=\(frame.seq ?? 0) has_seq=\(frame.seq != nil)")
    }

    func handleConnectionState(_ state: RemoteHostConnection.State) {
        guard !isShutdown else { return }
        switch state {
        case .connected:
            observationPaused = false
            eventsContinuation.yield(.channel(.init(kind: .connected)))
            scheduleStaleRecoveryIfEligible(reason: "connected")
        case let .degraded(code, _):
            pauseStaleRecovery(reason: "degraded")
            eventsContinuation.yield(.channel(.init(kind: .degraded(reason: code))))
        case .revoked:
            pauseStaleRecovery(reason: "revoked")
            eventsContinuation.yield(.channel(.init(kind: .revoked)))
        case .idle, .mintingTicket, .connecting:
            pauseStaleRecovery(reason: "disconnected")
        }
    }

    private func observeAndCatchUp(sessionID: String, generation: UUID) async throws -> Bool {
        guard isObservationCurrent(generation: generation, sessionID: sessionID) else { return false }
        do {
            try await connection.subscribe(sessionIDs: [sessionID])
        } catch {
            guard isObservationCurrent(generation: generation, sessionID: sessionID) else {
                return false
            }
            throw error
        }
        guard isObservationCurrent(generation: generation, sessionID: sessionID) else {
            await compensateStaleObservationSubscription(sessionID: sessionID)
            return false
        }
        Self.logger.notice("remote subscribe succeeded session_id=\(sessionID, privacy: .public)")
        do {
            try await catchUpFromHost()
        } catch {
            guard isObservationCurrent(generation: generation, sessionID: sessionID) else {
                await compensateStaleObservationSubscription(sessionID: sessionID)
                return false
            }
            throw error
        }
        guard isObservationCurrent(generation: generation, sessionID: sessionID) else {
            await compensateStaleObservationSubscription(sessionID: sessionID)
            return false
        }
        if didReportObservationFailure {
            eventsContinuation.yield(.systemMessage("Remote observation restored."))
        }
        didReportObservationFailure = false
        attachedObservationSessionID = sessionID
        scheduleStaleRecoveryIfEligible(reason: "attached")
        return true
    }

    private func isObservationCurrent(generation: UUID, sessionID: String) -> Bool {
        observationEnabled
            && observationLifecycleGeneration == generation
            && remoteSessionID == sessionID
            && !isShutdown
    }

    private func compensateStaleObservationSubscription(sessionID: String) async {
        do {
            try await connection.unsubscribe(sessionIDs: [sessionID])
        } catch {
            Self.logger.debug("remote stale observation compensation failed session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleObservationRecovery(for sessionID: String, lifecycleGeneration: UUID) {
        guard isObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID),
              observationRecoveryTask == nil
        else { return }
        stopStaleRecovery(reason: "transient_recovery")
        let generation = UUID()
        observationRecoveryGeneration = generation
        observationRecoveryTask = Task { [weak self] in
            await self?.runObservationRecovery(
                for: sessionID,
                generation: generation,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    private func runObservationRecovery(
        for sessionID: String,
        generation: UUID,
        lifecycleGeneration: UUID
    ) async {
        defer {
            if observationRecoveryGeneration == generation {
                observationRecoveryTask = nil
                observationRecoveryGeneration = nil
                scheduleStaleRecoveryIfEligible(reason: "transient_recovery_released")
            }
        }
        for attempt in 1 ... 3 {
            guard !Task.isCancelled,
                  isObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            else { return }
            if attempt > 1 {
                let delayMilliseconds = 250 * (1 << (attempt - 2))
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return
                }
            }
            do {
                guard try await observeAndCatchUp(
                    sessionID: sessionID,
                    generation: lifecycleGeneration
                ) else { return }
                return
            } catch {
                guard isObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID) else {
                    return
                }
                guard Self.isTransientObservationFailure(error) else {
                    reportObservationRecoveryStopped(error, sessionID: sessionID)
                    return
                }
                if attempt == 3 {
                    reportObservationRecoveryStopped(error, sessionID: sessionID)
                }
            }
        }
    }

    private func reportObservationDegraded(_ error: Error, sessionID: String) {
        let errorLogMetadata = Self.errorLogMetadata(error)
        Self.logger.notice("remote observation degraded session_id=\(sessionID, privacy: .public) error_type=\(errorLogMetadata.type, privacy: .public) error_code=\(errorLogMetadata.code, privacy: .public) error_description=\(errorLogMetadata.description, privacy: .private)")
        guard !didReportObservationFailure else { return }
        didReportObservationFailure = true
        eventsContinuation.yield(.systemMessage(
            "Remote session was accepted, but observation is degraded. Retrying without resending your message."
        ))
    }

    private func reportObservationRecoveryStopped(_ error: Error, sessionID: String) {
        let errorLogMetadata = Self.errorLogMetadata(error)
        Self.logger.notice("remote observation recovery stopped session_id=\(sessionID, privacy: .public) error_type=\(errorLogMetadata.type, privacy: .public) error_code=\(errorLogMetadata.code, privacy: .public) error_description=\(errorLogMetadata.description, privacy: .private)")
        eventsContinuation.yield(.systemMessage("Remote observation recovery failed: \(error)"))
    }

    private static func isTransientObservationFailure(_ error: Error) -> Bool {
        guard let remoteError = error as? RemoteClientError else { return false }
        return switch remoteError {
        case .timeout, .transport, .connectionClosed, .rateLimited:
            true
        default:
            false
        }
    }

    private func commandWithLedgerCompletionRetry(
        _ frame: RemoteClientFrame,
        operation: String
    ) async throws -> JSONValue {
        let retryDelaySeconds: TimeInterval = 0.25
        let maximumWaitSeconds: TimeInterval = 30
        var waitedSeconds: TimeInterval = 0
        var response = try await commandWithTransportRetry(
            frame,
            operation: operation,
            mayRetryTransportLoss: true
        )
        while Self.isLedgerInFlightResponse(response) {
            guard waitedSeconds < maximumWaitSeconds else {
                throw RemoteClientError.timeout(
                    operation: "\(operation) ledger completion",
                    seconds: maximumWaitSeconds
                )
            }
            try await recoveryScheduler.sleep(seconds: retryDelaySeconds)
            waitedSeconds += retryDelaySeconds
            try ensureNotShutdown()
            if let sessionID = frame.sessionID {
                try ensureCurrentSession(sessionID, operation: operation)
            }
            response = try await commandWithTransportRetry(
                frame,
                operation: operation,
                mayRetryTransportLoss: true
            )
        }
        return response
    }

    private func commandWithTransportRetry(
        _ frame: RemoteClientFrame,
        operation _: String,
        mayRetryTransportLoss: Bool
    ) async throws -> JSONValue {
        do {
            return try await connection.command(frame)
        } catch let error as RemoteClientError {
            switch error {
            case .inDoubt:
                eventsContinuation.yield(.systemMessage("Command outcome uncertain — re-synced from host."))
                try? await catchUpFromHost()
                throw error
            case .connectionClosed, .transport, .timeout:
                guard mayRetryTransportLoss else { throw error }
                try await connection.ensureConnected()
                return try await connection.command(frame)
            default:
                throw error
            }
        }
    }

    private func catchUpFromHost(pollHost: Bool = true) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        let lifecycleGeneration = observationLifecycleGeneration
        if let existingTask = catchUpTask {
            let existingTaskID = catchUpTaskID
            let isCurrentTask = catchUpTaskSessionID == sessionID
                && catchUpTaskLifecycleGeneration == lifecycleGeneration
            let existingModeCoversRequest = catchUpTaskPollsHost == true || !pollHost
            if isCurrentTask, existingModeCoversRequest {
                try await existingTask.value
                return
            }
            if !isCurrentTask {
                existingTask.cancel()
                _ = try? await existingTask.value
            } else {
                try await existingTask.value
            }
            clearCatchUpTaskIfCurrent(id: existingTaskID)
            try await catchUpFromHost(pollHost: pollHost)
            return
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            if pollHost {
                try await performCatchUpFromHost(
                    sessionID: sessionID,
                    lifecycleGeneration: lifecycleGeneration
                )
            } else {
                try await performLogCatchUpFromHost(
                    sessionID: sessionID,
                    lifecycleGeneration: lifecycleGeneration
                )
            }
        }
        catchUpTask = task
        catchUpTaskID = taskID
        catchUpTaskSessionID = sessionID
        catchUpTaskLifecycleGeneration = lifecycleGeneration
        catchUpTaskPollsHost = pollHost
        do {
            try await task.value
            clearCatchUpTaskIfCurrent(id: taskID)
        } catch {
            clearCatchUpTaskIfCurrent(id: taskID)
            throw error
        }
    }

    private func clearCatchUpTaskIfCurrent(id: UUID?) {
        guard catchUpTaskID == id else { return }
        catchUpTask = nil
        catchUpTaskID = nil
        catchUpTaskSessionID = nil
        catchUpTaskLifecycleGeneration = nil
        catchUpTaskPollsHost = nil
    }

    private func cancelCatchUpTask() {
        let task = catchUpTask
        catchUpTask = nil
        catchUpTaskID = nil
        catchUpTaskSessionID = nil
        catchUpTaskLifecycleGeneration = nil
        catchUpTaskPollsHost = nil
        task?.cancel()
    }

    private func performCatchUpFromHost(
        sessionID: String,
        lifecycleGeneration: UUID
    ) async throws {
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        let poll = RemoteClientFrame(
            type: "poll",
            requestID: makeRequestID(prefix: "poll"),
            sessionID: sessionID,
            payload: .object(["timeout": .int(0)])
        )
        do {
            let snapshot = try await connection.command(poll)
            try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            applySnapshot(snapshot, frameType: "session_update")
        } catch RemoteClientError.sessionExpired {
            try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            yieldSessionExpiredOnce()
            return
        }

        try await performLogCatchUpFromHost(
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    private func performLogCatchUpFromHost(
        sessionID: String,
        lifecycleGeneration: UUID
    ) async throws {
        try await pageLogsFromHost(sessionID: sessionID, lifecycleGeneration: lifecycleGeneration)
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        try await performTerminalSettleReReadIfNeeded(
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration
        )
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
    }

    private func pageLogsFromHost(
        sessionID: String,
        lifecycleGeneration: UUID
    ) async throws {
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        var keepPaging = true
        while keepPaging {
            try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            let offset = nextLogOffset
            let page = try await fetchLogPage(
                offset: offset,
                limit: 20,
                sessionID: sessionID,
                lifecycleGeneration: lifecycleGeneration
            )
            try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            guard page.returnedTurnCount > 0 else {
                logLogPageResult(page, branch: "empty", emittedRowCount: 0)
                return
            }

            guard page.completedTurnCount != nil else {
                emitLogPage(page, reconciliation: .parked)
                let didAdvance = advanceLogOffset(to: page.consumableOffset, from: offset)
                if didAdvance {
                    lastLegacyAdvanceOffset = offset
                }
                logLogPageResult(page, branch: "legacy", emittedRowCount: page.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
                continue
            }

            let consumableOffset = effectiveConsumableOffset(for: page)
            if consumableOffset >= page.nextLogOffset {
                emitLogPage(page, reconciliation: .complete)
                let didAdvance = advanceLogOffset(to: consumableOffset, from: offset)
                logLogPageResult(page, branch: "complete", emittedRowCount: page.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
            } else if consumableOffset <= offset {
                emitLogPage(page, reconciliation: .parked)
                emitBinding()
                logLogPageResult(page, branch: "parked", emittedRowCount: page.items.count)
                keepPaging = false
            } else {
                let completedPage = try await fetchLogPage(
                    offset: offset,
                    limit: consumableOffset - offset,
                    sessionID: sessionID,
                    lifecycleGeneration: lifecycleGeneration
                )
                try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
                let completedPageConsumableOffset = effectiveConsumableOffset(for: completedPage)
                guard completedPageConsumableOffset >= completedPage.nextLogOffset else {
                    logLogPageResult(page, branch: "mixed-discarded", emittedRowCount: 0)
                    keepPaging = false
                    continue
                }
                emitLogPage(completedPage, reconciliation: .complete)
                let didAdvance = advanceLogOffset(to: min(consumableOffset, completedPageConsumableOffset), from: offset)
                logLogPageResult(completedPage, branch: "mixed", emittedRowCount: completedPage.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
            }
        }
    }

    private func performTerminalSettleReReadIfNeeded(
        sessionID: String,
        lifecycleGeneration: UUID
    ) async throws {
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        guard !lastKnownRunState.isActive, !didTerminalSettleReRead else { return }
        let settleOffset: Int
        let settleLimit: Int
        let reconciliation: LogPageReconciliation
        if let lastCompletePageOffset {
            settleOffset = lastCompletePageOffset
            settleLimit = max(1, nextLogOffset - lastCompletePageOffset)
            reconciliation = .complete
        } else if lastLegacyAdvanceOffset != nil, nextLogOffset > 0 {
            settleOffset = max(0, nextLogOffset - 1)
            settleLimit = 1
            reconciliation = .parked
        } else {
            return
        }
        let page = try await fetchLogPage(
            offset: settleOffset,
            limit: settleLimit,
            sessionID: sessionID,
            lifecycleGeneration: lifecycleGeneration
        )
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        didTerminalSettleReRead = true
        emitLogPage(page, reconciliation: reconciliation)
        logLogPageResult(page, branch: "terminal-settle", emittedRowCount: page.items.count)
    }

    private func fetchLogPage(
        offset: Int,
        limit: Int,
        sessionID: String,
        lifecycleGeneration: UUID
    ) async throws -> RemoteProjectedLogPage {
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        // Establish the connection (and therefore the hello_ack feature set) before the
        // feature read; command() auto-connects, so a cold-start fetch would otherwise
        // read a stale-false feature and permanently project this page without dates.
        try await connection.ensureConnected()
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        var includeRowTimestamps = if hostRejectedGetLogRowTimestamps {
            false
        } else {
            await connection.supportsHostFeature(RemoteWireFeatures.getLogRowTimestamps)
        }
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        var includeHostRowIDs = if hostRejectedGetLogHostRowIDs {
            false
        } else {
            await connection.supportsHostFeature(RemoteWireFeatures.getLogHostRowIDs)
        }
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        Self.logger.log("remote get_log fetch session_id=\(sessionID, privacy: .public) offset=\(offset) limit=\(limit) row_ts=\(includeRowTimestamps) host_row_ids=\(includeHostRowIDs)")
        var resolvedPagePayload: JSONValue?
        while resolvedPagePayload == nil {
            do {
                resolvedPagePayload = try await connection.command(makeGetLogFrame(
                    offset: offset,
                    limit: limit,
                    sessionID: sessionID,
                    includeRowTimestamps: includeRowTimestamps,
                    includeHostRowIDs: includeHostRowIDs
                ))
            } catch let error as RemoteClientError {
                guard error.commandError?.code == "unsupported_payload_key" else {
                    throw error
                }
                // Prefer dropping the newest additive key first. If an older skewed host
                // rejects timestamps instead, a second retry applies the existing latch.
                if includeHostRowIDs {
                    hostRejectedGetLogHostRowIDs = true
                    includeHostRowIDs = false
                    Self.logger.notice("remote get_log retrying without include_host_row_ids after unsupported_payload_key session_id=\(sessionID, privacy: .public)")
                } else if includeRowTimestamps {
                    hostRejectedGetLogRowTimestamps = true
                    includeRowTimestamps = false
                    Self.logger.notice("remote get_log retrying without include_row_timestamps after unsupported_payload_key session_id=\(sessionID, privacy: .public)")
                } else {
                    throw error
                }
                try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
            }
        }
        try ensureObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
        guard let pagePayload = resolvedPagePayload,
              let page = projector?.projectGetLogResponse(pagePayload)
        else {
            throw RemoteLogPagingError.missingProjector
        }
        return page
    }

    private func makeGetLogFrame(
        offset: Int,
        limit: Int,
        sessionID: String,
        includeRowTimestamps: Bool,
        includeHostRowIDs: Bool
    ) -> RemoteClientFrame {
        var payload: [String: JSONValue] = [
            "offset": .int(offset),
            "limit": .int(limit)
        ]
        if includeRowTimestamps {
            payload["include_row_timestamps"] = .bool(true)
        }
        if includeHostRowIDs {
            payload["include_host_row_ids"] = .bool(true)
        }
        return RemoteClientFrame(
            type: "get_log",
            requestID: makeRequestID(prefix: "log"),
            sessionID: sessionID,
            payload: .object(payload)
        )
    }

    private enum LogPageReconciliation {
        case parked
        case complete
    }

    private func emitLogPage(_ page: RemoteProjectedLogPage, reconciliation: LogPageReconciliation) {
        hostRowIDByClientItemID.merge(page.hostRowIDByClientItemID) { _, incoming in incoming }
        let removedIDs = reconcileProjectedRows(for: page, reconciliation: reconciliation)
        for removedID in removedIDs {
            hostRowIDByClientItemID.removeValue(forKey: removedID)
        }
        if !page.items.isEmpty || !removedIDs.isEmpty || !page.hostRowIDByClientItemID.isEmpty {
            eventsContinuation.yield(.transcriptRows(
                items: page.items,
                removedIDs: removedIDs,
                hostRowIDByClientItemID: hostRowIDByClientItemID
            ))
        }
    }

    private func reconcileProjectedRows(
        for page: RemoteProjectedLogPage,
        reconciliation: LogPageReconciliation
    ) -> [UUID] {
        let incomingIDs = Set(page.items.map(\.id))
        switch reconciliation {
        case .parked:
            projectedRowIDsByPageOffset[page.turnOffset, default: []].formUnion(incomingIDs)
            return []
        case .complete:
            let rememberedIDs = projectedRowIDsByPageOffset[page.turnOffset, default: []]
            // Complete pages mirror the host export exactly. Rows suppressed by the host export
            // (including maxTranscriptItems budget drops) are reconciled away once absent here.
            // This registry is in-memory per controller; parked rows persisted from a previous app
            // run cannot be diffed on the first complete page after restart without future persisted
            // row-origin tagging.
            let removedIDs = rememberedIDs.subtracting(incomingIDs)
            projectedRowIDsByPageOffset[page.turnOffset] = incomingIDs
            lastCompletePageOffset = page.turnOffset
            return removedIDs.sorted { $0.uuidString < $1.uuidString }
        }
    }

    private func resetLogReconciliationState() {
        hostRowIDByClientItemID.removeAll()
        projectedRowIDsByPageOffset.removeAll()
        lastCompletePageOffset = nil
        lastLegacyAdvanceOffset = nil
    }

    private func effectiveConsumableOffset(for page: RemoteProjectedLogPage) -> Int {
        let rawOffset = page.consumableOffset
        guard page.completedTurnCount != nil, lastKnownRunState.isActive else { return rawOffset }
        let cappedOffset = min(rawOffset, max(0, page.totalTurns - 1))
        if cappedOffset != rawOffset {
            let runStateRaw = lastKnownRunState.rawValue
            Self.logger.notice("remote active-run completed boundary capped session_id=\(page.sessionID, privacy: .public) raw_consumable_offset=\(rawOffset) capped_consumable_offset=\(cappedOffset) total_turns=\(page.totalTurns) run_state=\(runStateRaw, privacy: .public)")
        }
        return cappedOffset
    }

    private func logLogPageResult(_ page: RemoteProjectedLogPage, branch: String, emittedRowCount: Int) {
        let nextOffset = nextLogOffset
        Self.logger.log("remote get_log page session_id=\(page.sessionID, privacy: .public) offset=\(page.turnOffset) limit=\(page.turnLimit) returned_turn_count=\(page.returnedTurnCount) total_turns=\(page.totalTurns) completed_turn_count=\(page.completedTurnCount ?? -1) has_completed_turn_count=\(page.completedTurnCount != nil) emitted_row_count=\(emittedRowCount) next_log_offset=\(nextOffset) branch=\(branch, privacy: .public)")
    }

    private func advanceLogOffset(to offset: Int, from previousOffset: Int) -> Bool {
        nextLogOffset = max(nextLogOffset, offset)
        pruneProjectedRowRegistry()
        emitBinding()
        let didAdvance = nextLogOffset > previousOffset
        if didAdvance {
            recordStaleObservationProgress(reason: "log_offset_advanced")
        }
        return didAdvance
    }

    private func pruneProjectedRowRegistry() {
        let minimumRetainedOffset = nextLogOffset - 1
        guard minimumRetainedOffset > 0 else { return }
        projectedRowIDsByPageOffset = projectedRowIDsByPageOffset.filter { offset, _ in
            offset >= minimumRetainedOffset || offset == lastCompletePageOffset
        }
    }

    private func emitNonAdvancingLogPageWarning() {
        eventsContinuation.yield(.systemMessage("Remote log page did not advance; stopped catch-up paging."))
    }

    private func catchUpFromHostReportingFailures() async {
        do {
            try await catchUpFromHost()
            didReportLogCatchUpFailure = false
        } catch {
            reportLogCatchUpFailure(error)
        }
    }

    private func reportLogCatchUpFailure(_ error: Error) {
        if error is CancellationError {
            return
        }
        if let remoteError = error as? RemoteClientError,
           case .sessionExpired = remoteError
        {
            yieldSessionExpiredOnce()
            return
        }
        let sessionID = remoteSessionID ?? ""
        let errorLogMetadata = Self.errorLogMetadata(error)
        Self.logger.notice("remote transcript catch-up failed session_id=\(sessionID, privacy: .public) error_type=\(errorLogMetadata.type, privacy: .public) error_code=\(errorLogMetadata.code, privacy: .public) error_description=\(errorLogMetadata.description, privacy: .private)")
        if !didReportLogCatchUpFailure {
            eventsContinuation.yield(.systemMessage("Remote transcript catch-up failed: \(error)"))
        }
        didReportLogCatchUpFailure = true
    }

    private func yieldSessionExpiredOnce() {
        lastKnownRunState = .failed
        stopStaleRecovery(reason: "expired")
        guard !didYieldSessionExpired else { return }
        didYieldSessionExpired = true
        let sessionID = remoteSessionID ?? ""
        Self.logger.notice("remote session expired session_id=\(sessionID, privacy: .public)")
        eventsContinuation.yield(.sessionExpired)
    }

    private func scheduleStaleRecoveryIfEligible(reason: String) {
        guard !isShutdown,
              !observationPaused,
              observationEnabled,
              lastKnownRunState.isActive,
              let sessionID = remoteSessionID,
              attachedObservationSessionID == sessionID
        else { return }
        guard observationRecoveryTask == nil else {
            Self.logger.notice("remote stale recovery deferred session_id=\(sessionID, privacy: .public) reason=transient_recovery")
            return
        }
        guard staleRecoveryTask == nil else { return }

        let generation = UUID()
        let lifecycleGeneration = observationLifecycleGeneration
        staleRecoveryGeneration = generation
        let delay = recoveryPolicy.staleIntervalSeconds
        Self.logger.notice("remote stale recovery scheduled session_id=\(sessionID, privacy: .public) reason=\(reason, privacy: .public) delay_seconds=\(delay)")
        staleRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recoveryScheduler.sleep(seconds: delay)
            } catch {
                return
            }
            await runStaleRecovery(
                for: sessionID,
                generation: generation,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    private func runStaleRecovery(
        for sessionID: String,
        generation: UUID,
        lifecycleGeneration: UUID
    ) async {
        defer {
            if staleRecoveryGeneration == generation {
                staleRecoveryTask = nil
                staleRecoveryGeneration = nil
            }
        }
        let retryDelays = recoveryPolicy.retryDelaySeconds
        let attemptCount = retryDelays.count + 1
        for attempt in 1 ... attemptCount {
            guard isStaleRecoveryCurrent(
                generation: generation,
                lifecycleGeneration: lifecycleGeneration,
                sessionID: sessionID
            ) else { return }
            if observationRecoveryTask != nil {
                Self.logger.notice("remote stale recovery deferred session_id=\(sessionID, privacy: .public) reason=transient_recovery attempt=\(attempt)")
                return
            }
            if attempt > 1 {
                let delay = retryDelays[attempt - 2]
                do {
                    try await recoveryScheduler.sleep(seconds: delay)
                } catch {
                    return
                }
                guard isStaleRecoveryCurrent(
                    generation: generation,
                    lifecycleGeneration: lifecycleGeneration,
                    sessionID: sessionID
                ) else { return }
            }

            let progressBeforeAttempt = staleProgressGeneration
            Self.logger.notice("remote stale recovery attempted session_id=\(sessionID, privacy: .public) attempt=\(attempt) max_attempts=\(attemptCount)")
            do {
                try await catchUpFromHost()
            } catch {
                guard isStaleRecoveryCurrent(
                    generation: generation,
                    lifecycleGeneration: lifecycleGeneration,
                    sessionID: sessionID
                ) else { return }
            }
            guard isStaleRecoveryCurrent(
                generation: generation,
                lifecycleGeneration: lifecycleGeneration,
                sessionID: sessionID
            ) else { return }
            if staleProgressGeneration != progressBeforeAttempt {
                return
            }
            if attempt == attemptCount {
                Self.logger.notice("remote stale recovery stopped session_id=\(sessionID, privacy: .public) reason=attempts_exhausted attempts=\(attemptCount)")
            }
        }
    }

    private func isStaleRecoveryCurrent(
        generation: UUID,
        lifecycleGeneration: UUID,
        sessionID: String
    ) -> Bool {
        !Task.isCancelled
            && staleRecoveryGeneration == generation
            && !observationPaused
            && attachedObservationSessionID == sessionID
            && lastKnownRunState.isActive
            && isObservationCurrent(generation: lifecycleGeneration, sessionID: sessionID)
    }

    private func recordStaleObservationProgress(reason: String) {
        staleProgressGeneration &+= 1
        guard lastKnownRunState.isActive else {
            stopStaleRecovery(reason: "terminal")
            return
        }
        stopStaleRecovery(reason: reason)
        scheduleStaleRecoveryIfEligible(reason: reason)
    }

    private func pauseStaleRecovery(reason: String) {
        observationPaused = true
        let sessionID = remoteSessionID ?? ""
        Self.logger.notice("remote stale recovery paused session_id=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        stopStaleRecovery(reason: reason)
    }

    private func stopStaleRecovery(reason: String) {
        guard staleRecoveryTask != nil else { return }
        let sessionID = remoteSessionID ?? ""
        Self.logger.notice("remote stale recovery stopped session_id=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        staleRecoveryTask?.cancel()
        staleRecoveryTask = nil
        staleRecoveryGeneration = nil
    }

    private func scheduleLogCatchUp() {
        guard !isShutdown, remoteSessionID != nil else { return }
        scheduledLogCatchUpDirty = true
        guard scheduledLogCatchUpTask == nil else { return }
        scheduledLogCatchUpTask = Task {
            while self.scheduledLogCatchUpDirty, !self.isShutdown {
                self.scheduledLogCatchUpDirty = false
                do {
                    try await self.catchUpFromHost(pollHost: false)
                    self.didReportLogCatchUpFailure = false
                } catch {
                    self.reportLogCatchUpFailure(error)
                }
            }
            self.scheduledLogCatchUpTask = nil
        }
    }

    private func applySnapshot(_ payload: JSONValue, frameType: String?) {
        guard !isShutdown else { return }
        guard let projection = projector?.projectSnapshot(payload, frameType: frameType) else { return }
        if projection.agentKindRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || projection.agentModelRaw != nil
            || projection.sessionName != nil
        {
            eventsContinuation.yield(.metadata(
                agentKindRaw: projection.agentKindRaw,
                modelRaw: projection.agentModelRaw,
                reasoningEffortRaw: projection.agentReasoningEffortRaw,
                sessionName: projection.sessionName
            ))
        }
        let sessionID = remoteSessionID ?? ""
        let wasActive = lastKnownRunState.isActive
        lastKnownRunState = projection.runState
        if projection.runState.isActive {
            didTerminalSettleReRead = false
        } else if wasActive {
            staleProgressGeneration &+= 1
            stopStaleRecovery(reason: "terminal")
        }
        Self.logger.log("remote snapshot projected frame_type=\(frameType ?? "", privacy: .public) session_id=\(sessionID, privacy: .public) run_state=\(projection.runState.rawValue, privacy: .public) has_status_text=\(projection.statusText != nil)")
        eventsContinuation.yield(.runState(
            projection.runState,
            pendingInteraction: projection.pendingInteraction,
            statusText: projection.statusText
        ))
        if let resolved = Self.interactionResolution(from: payload) {
            eventsContinuation.yield(.interactionResolved(
                interactionID: resolved.interactionID,
                resolvedBy: resolved.resolvedBy
            ))
        }
        if projection.isExpired {
            yieldSessionExpiredOnce()
        }
        if let terminalStatus = projection.terminalStatus {
            Self.logger.notice("remote terminal status session_id=\(sessionID, privacy: .public) status=\(terminalStatus, privacy: .public)")
            eventsContinuation.yield(.terminal(status: terminalStatus))
        }
    }

    private func emitBinding() {
        guard !isShutdown, let binding = currentBinding() else { return }
        eventsContinuation.yield(.binding(binding))
    }

    private func makeRequestID(prefix: String) -> String {
        "rpce-n5-\(prefix)-\(UUID().uuidString)"
    }

    private func ensureNotShutdown() throws {
        if isShutdown {
            throw RemoteClientError.protocolViolation("Remote controller is shut down.")
        }
    }

    private func ensureObservationCurrent(generation: UUID, sessionID: String) throws {
        guard !Task.isCancelled,
              isObservationCurrent(generation: generation, sessionID: sessionID)
        else { throw CancellationError() }
    }

    private func ensureCurrentSession(_ expectedSessionID: String, operation: String) throws {
        try ensureNotShutdown()
        guard remoteSessionID == expectedSessionID else {
            throw RemoteClientError.protocolViolation(
                "Remote session changed while preparing \(operation); choose the cutoff again."
            )
        }
    }

    private func missingSessionError() -> RemoteClientError {
        .sessionExpired(.init(code: "missing_session", message: "Remote session is not attached."))
    }

    private func requireHostFeature(
        _ feature: String,
        operationDescription: String
    ) async throws {
        try await connection.ensureConnected()
        guard await connection.supportsHostFeature(feature) else {
            throw RemoteClientError.command(.init(
                code: "unsupported_host_feature",
                message: "\(hostDisplayName) does not support \(operationDescription). Update RepoPrompt CE on the host and try again."
            ))
        }
    }

    private func requireHostRowID(forClientItemID clientItemID: UUID) throws -> UUID {
        guard let hostRowID = hostRowIDByClientItemID[clientItemID] else {
            throw RemoteClientError.command(.init(
                code: "host_row_id_unavailable",
                message: "This transcript row is not yet mapped to its host cutoff ID. Wait for remote transcript sync and try again."
            ))
        }
        return hostRowID
    }

    private static func isLedgerInFlightResponse(_ response: JSONValue) -> Bool {
        response.objectValue?["status"]?.stringValue == "in_flight"
    }

    private static func errorLogMetadata(_ error: Error) -> (type: String, code: String, description: String) {
        let code: String = if let remoteError = error as? RemoteClientError {
            remoteError.commandError?.code ?? ""
        } else {
            ""
        }
        return (String(describing: Swift.type(of: error)), code, String(describing: error))
    }

    private static func normalizedSequenceEpoch(_ epoch: String?) -> String? {
        guard let epoch = epoch?.trimmingCharacters(in: .whitespacesAndNewlines), !epoch.isEmpty else {
            return nil
        }
        return epoch
    }

    private static func remoteSessionID(from payload: JSONValue) throws -> String {
        guard let object = payload.objectValue else {
            throw RemoteClientError.protocolViolation("agent_run start did not return an object payload.")
        }
        if let sessionID = object["session_id"]?.stringValue,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionID
        }
        if let sessionID = object["session"]?.objectValue?["id"]?.stringValue,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionID
        }
        throw RemoteClientError.protocolViolation("agent_run start response did not include session_id.")
    }

    static func sessionDescriptors(from payload: JSONValue) -> [RemoteAgentSessionDescriptor] {
        let sessions = payload.objectValue?["sessions"]?.arrayValue ?? []
        return sessions.compactMap(sessionDescriptor(from:))
    }

    static func sessionDescriptor(from value: JSONValue) -> RemoteAgentSessionDescriptor? {
        guard let object = value.objectValue,
              let sessionID = normalizedDescriptorString(object["session_id"]?.stringValue)
        else { return nil }
        let agentObject = object["agent"]?.objectValue
        return RemoteAgentSessionDescriptor(
            sessionID: sessionID,
            name: normalizedDescriptorString(object["name"]?.stringValue),
            stateRaw: object["raw_state"]?.stringValue ?? object["state"]?.stringValue,
            agentKindRaw: agentObject?["id"]?.stringValue ?? object["agent"]?.stringValue,
            agentModelRaw: agentObject?["model"]?.stringValue,
            parentSessionID: normalizedDescriptorString(object["parent_session_id"]?.stringValue),
            lastModified: descriptorDate(from: object["last_modified"]?.stringValue),
            itemCount: object["item_count"]?.intValue,
            originSummary: normalizedDescriptorString(object["origin"]?.stringValue),
            isLive: object["is_live"]?.boolValue
        )
    }

    private static func normalizedDescriptorString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func descriptorDate(from value: String?) -> Date? {
        guard let value = normalizedDescriptorString(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: value)
    }

    private static func interactionResolution(from payload: JSONValue) -> (interactionID: String, resolvedBy: String?)? {
        guard let meta = payload.objectValue?["_meta"]?.objectValue,
              let resolved = meta["interaction_resolved"]?.objectValue,
              let interactionID = resolved["interaction_id"]?.stringValue,
              !interactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (interactionID, resolved["resolved_by"]?.stringValue)
    }
}
