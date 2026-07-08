import Foundation
import OSLog
import RepoPromptRemoteWire

protocol RemoteAgentSessionConnection: Sendable {
    func command(_ frame: RemoteClientFrame, timeout: TimeInterval) async throws -> JSONValue
    func ensureConnected() async throws
    func subscribe(sessionIDs: [String]) async throws
    func unsubscribe(sessionIDs: [String]) async throws
}

extension RemoteAgentSessionConnection {
    func command(_ frame: RemoteClientFrame) async throws -> JSONValue {
        try await command(frame, timeout: RemoteHostConnection.commandTimeout)
    }
}

extension RemoteHostConnection: RemoteAgentSessionConnection {}

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
    case transcriptRows([AgentChatItem])
    case runState(AgentSessionRunState, pendingInteraction: RemotePendingInteraction?)
    case interactionResolved(interactionID: String, resolvedBy: String?)
    case sessionExpired
    case terminal(status: String)
    case channel(RemoteChannelState)
    case systemMessage(String)
    case metadata(agentKindRaw: String?, modelRaw: String?, sessionName: String?)
    case binding(AgentSessionRemoteHostBinding)
}

actor RemoteAgentSessionController {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "RemoteControlClient")

    nonisolated let events: AsyncStream<RemoteSessionEvent>

    private let hostID: String
    private let hostDisplayName: String
    private let connection: any RemoteAgentSessionConnection
    private let eventsContinuation: AsyncStream<RemoteSessionEvent>.Continuation
    private var remoteSessionID: String?
    private var lastAppliedSeq: UInt64
    private var nextLogOffset: Int
    private var projector: RemoteTranscriptProjector?
    private var lastKnownRunState: AgentSessionRunState = .idle
    private var scheduledLogCatchUpTask: Task<Void, Never>?
    private var scheduledLogCatchUpDirty = false
    private var didReportLogCatchUpFailure = false
    private var didYieldSessionExpired = false
    private var isShutdown = false

    init(
        binding: AgentSessionRemoteHostBinding,
        connection: any RemoteAgentSessionConnection
    ) {
        hostID = binding.hostID
        hostDisplayName = binding.hostDisplayName
        remoteSessionID = binding.remoteSessionID.isEmpty ? nil : binding.remoteSessionID
        lastKnownRunState = binding.remoteSessionID.isEmpty ? .idle : .completed
        lastAppliedSeq = binding.lastAppliedSeq
        nextLogOffset = binding.nextLogOffset
        self.connection = connection
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
        scheduledLogCatchUpTask?.cancel()
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
        if let windowID { payload["window_id"] = .int(windowID) }
        if let workspaceID, !workspaceID.isEmpty { payload["workspace_id"] = .string(workspaceID) }
        if let workspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceName.isEmpty {
            payload["workspace_name"] = .string(workspaceName)
        }
        let frame = RemoteClientFrame(
            type: "start",
            requestID: makeRequestID(prefix: "start"),
            payload: .object(payload)
        )
        Self.logger.log("remote start request sent request_id=\(frame.requestID ?? "", privacy: .public) has_window_id=\(windowID != nil) has_workspace_id=\(workspaceID?.isEmpty == false) has_workspace_name=\(payload["workspace_name"] != nil)")
        let response = try await commandWithTransportRetry(frame, operation: "start", mayRetryTransportLoss: true)
        let sessionID = try Self.remoteSessionID(from: response)
        let didResetCursor = sessionID != remoteSessionID
        if didResetCursor {
            lastAppliedSeq = 0
            nextLogOffset = 0
            scheduledLogCatchUpDirty = false
            didReportLogCatchUpFailure = false
        }
        didYieldSessionExpired = false
        lastKnownRunState = .running
        remoteSessionID = sessionID
        Self.logger.notice("remote start response adopted request_id=\(frame.requestID ?? "", privacy: .public) session_id=\(sessionID, privacy: .public) did_reset_cursor=\(didResetCursor)")
        projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        emitBinding()
        do {
            try await connection.subscribe(sessionIDs: [sessionID])
            Self.logger.notice("remote subscribe succeeded session_id=\(sessionID, privacy: .public)")
        } catch {
            let errorLogMetadata = Self.errorLogMetadata(error)
            Self.logger.notice("remote subscribe failed session_id=\(sessionID, privacy: .public) error_type=\(errorLogMetadata.type, privacy: .public) error_code=\(errorLogMetadata.code, privacy: .public) error_description=\(errorLogMetadata.description, privacy: .private)")
            throw error
        }
        applySnapshot(response, frameType: "session_update")
        try await catchUpFromHost()
        return sessionID
    }

    func steer(_ text: String) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
        let frame = RemoteClientFrame(
            type: "steer",
            requestID: makeRequestID(prefix: "steer"),
            sessionID: sessionID,
            payload: .object(["message": .string(text)])
        )
        let response = try await commandWithTransportRetry(frame, operation: "steer", mayRetryTransportLoss: true)
        lastKnownRunState = .running
        applySnapshot(response, frameType: "session_update")
        try await catchUpFromHost()
    }

    func respond(interactionID: String, payload: RemoteInteractionResponsePayload) async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { throw missingSessionError() }
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

    func attachAndCatchUp() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        if projector == nil {
            projector = RemoteTranscriptProjector(remoteSessionID: sessionID)
        }
        do {
            try await connection.subscribe(sessionIDs: [sessionID])
            Self.logger.notice("remote subscribe succeeded session_id=\(sessionID, privacy: .public)")
        } catch {
            let errorLogMetadata = Self.errorLogMetadata(error)
            Self.logger.notice("remote subscribe failed session_id=\(sessionID, privacy: .public) error_type=\(errorLogMetadata.type, privacy: .public) error_code=\(errorLogMetadata.code, privacy: .public) error_description=\(errorLogMetadata.description, privacy: .private)")
            throw error
        }
        try await catchUpFromHost()
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
            nextLogOffset: nextLogOffset
        )
    }

    func unsubscribe() async {
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
            eventsContinuation.yield(.channel(.init(kind: .connected)))
        case let .degraded(code, _):
            eventsContinuation.yield(.channel(.init(kind: .degraded(reason: code))))
        case .revoked:
            eventsContinuation.yield(.channel(.init(kind: .revoked)))
        case .idle, .mintingTicket, .connecting:
            break
        }
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

    private func catchUpFromHost() async throws {
        try ensureNotShutdown()
        guard let sessionID = remoteSessionID else { return }
        let poll = RemoteClientFrame(
            type: "poll",
            requestID: makeRequestID(prefix: "poll"),
            sessionID: sessionID,
            payload: .object(["timeout": .int(0)])
        )
        do {
            let snapshot = try await connection.command(poll)
            applySnapshot(snapshot, frameType: "session_update")
        } catch RemoteClientError.sessionExpired {
            yieldSessionExpiredOnce()
            return
        }

        try await pageLogsFromHost()
    }

    private func pageLogsFromHost() async throws {
        try ensureNotShutdown()
        guard remoteSessionID != nil else { return }
        var keepPaging = true
        while keepPaging {
            try ensureNotShutdown()
            let offset = nextLogOffset
            let page = try await fetchLogPage(offset: offset, limit: 20)
            guard page.returnedTurnCount > 0 else {
                logLogPageResult(page, branch: "empty", emittedRowCount: 0)
                return
            }

            guard page.completedTurnCount != nil else {
                emitLogPage(page)
                let didAdvance = advanceLogOffset(to: page.consumableOffset, from: offset)
                logLogPageResult(page, branch: "legacy", emittedRowCount: page.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
                continue
            }

            let consumableOffset = effectiveConsumableOffset(for: page)
            if consumableOffset >= page.nextLogOffset {
                emitLogPage(page)
                let didAdvance = advanceLogOffset(to: consumableOffset, from: offset)
                logLogPageResult(page, branch: "complete", emittedRowCount: page.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
            } else if consumableOffset <= offset {
                emitLogPage(page)
                emitBinding()
                logLogPageResult(page, branch: "parked", emittedRowCount: page.items.count)
                keepPaging = false
            } else {
                let completedPage = try await fetchLogPage(offset: offset, limit: consumableOffset - offset)
                let completedPageConsumableOffset = effectiveConsumableOffset(for: completedPage)
                guard completedPageConsumableOffset >= completedPage.nextLogOffset else {
                    logLogPageResult(page, branch: "mixed-discarded", emittedRowCount: 0)
                    keepPaging = false
                    continue
                }
                emitLogPage(completedPage)
                let didAdvance = advanceLogOffset(to: min(consumableOffset, completedPageConsumableOffset), from: offset)
                logLogPageResult(completedPage, branch: "mixed", emittedRowCount: completedPage.items.count)
                keepPaging = nextLogOffset < page.totalTurns && didAdvance
                if !didAdvance {
                    emitNonAdvancingLogPageWarning()
                }
            }
        }
    }

    private func fetchLogPage(offset: Int, limit: Int) async throws -> RemoteProjectedLogPage {
        guard let sessionID = remoteSessionID else {
            throw RemoteLogPagingError.missingSession
        }
        Self.logger.log("remote get_log fetch session_id=\(sessionID, privacy: .public) offset=\(offset) limit=\(limit)")
        let logFrame = RemoteClientFrame(
            type: "get_log",
            requestID: makeRequestID(prefix: "log"),
            sessionID: sessionID,
            payload: .object([
                "offset": .int(offset),
                "limit": .int(limit)
            ])
        )
        let pagePayload = try await connection.command(logFrame)
        guard let page = projector?.projectGetLogResponse(pagePayload) else {
            throw RemoteLogPagingError.missingProjector
        }
        return page
    }

    private func emitLogPage(_ page: RemoteProjectedLogPage) {
        if !page.items.isEmpty {
            eventsContinuation.yield(.transcriptRows(page.items))
        }
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
        emitBinding()
        return nextLogOffset > previousOffset
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
        guard !didYieldSessionExpired else { return }
        didYieldSessionExpired = true
        let sessionID = remoteSessionID ?? ""
        Self.logger.notice("remote session expired session_id=\(sessionID, privacy: .public)")
        eventsContinuation.yield(.sessionExpired)
    }

    private func scheduleLogCatchUp() {
        guard !isShutdown, remoteSessionID != nil else { return }
        scheduledLogCatchUpDirty = true
        guard scheduledLogCatchUpTask == nil else { return }
        scheduledLogCatchUpTask = Task {
            while self.scheduledLogCatchUpDirty, !self.isShutdown {
                self.scheduledLogCatchUpDirty = false
                do {
                    try await self.pageLogsFromHost()
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
                sessionName: projection.sessionName
            ))
        }
        let sessionID = remoteSessionID ?? ""
        lastKnownRunState = projection.runState
        Self.logger.log("remote snapshot projected frame_type=\(frameType ?? "", privacy: .public) session_id=\(sessionID, privacy: .public) run_state=\(projection.runState.rawValue, privacy: .public)")
        eventsContinuation.yield(.runState(projection.runState, pendingInteraction: projection.pendingInteraction))
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

    private func missingSessionError() -> RemoteClientError {
        .sessionExpired(.init(code: "missing_session", message: "Remote session is not attached."))
    }

    private static func errorLogMetadata(_ error: Error) -> (type: String, code: String, description: String) {
        let code: String = if let remoteError = error as? RemoteClientError {
            remoteError.commandError?.code ?? ""
        } else {
            ""
        }
        return (String(describing: Swift.type(of: error)), code, String(describing: error))
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

    private static func sessionDescriptors(from payload: JSONValue) -> [RemoteAgentSessionDescriptor] {
        let sessions = payload.objectValue?["sessions"]?.arrayValue ?? []
        return sessions.compactMap { value in
            guard let object = value.objectValue,
                  let sessionID = object["session_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty
            else { return nil }
            let agentObject = object["agent"]?.objectValue
            let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteAgentSessionDescriptor(
                sessionID: sessionID,
                name: name?.isEmpty == false ? name : nil,
                stateRaw: object["raw_state"]?.stringValue ?? object["state"]?.stringValue,
                agentKindRaw: agentObject?["id"]?.stringValue ?? object["agent"]?.stringValue,
                agentModelRaw: agentObject?["model"]?.stringValue,
                parentSessionID: object["parent_session_id"]?.stringValue
            )
        }
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
