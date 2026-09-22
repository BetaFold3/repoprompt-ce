import CryptoKit
import Foundation
import MCP

@MainActor
struct MCPOracleToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias ResolvedTabContextSnapshot = MCPServerViewModel.ResolvedTabContextSnapshot
    typealias TabScopedContext = MCPServerViewModel.TabScopedContext
    typealias ChatSendOperation = @Sendable () async throws -> [String: Value]
    typealias SendChat = @MainActor @Sendable (
        _ args: [String: Value],
        _ promptVM: PromptViewModel,
        _ tabContext: OracleViewModel.OracleSendTabContext?
    ) async throws -> [String: Value]
    typealias ExportOracleResponse = @MainActor @Sendable (OracleExportRequest) async throws -> OracleExportFile
    typealias StabilizedVirtualContext = @MainActor @Sendable (
        _ context: TabScopedContext
    ) async -> TabScopedContext
    typealias ResolveDelegatedReviewPackaging = @MainActor @Sendable (
        _ conversationTabID: UUID,
        _ conversationWorkspaceID: UUID?,
        _ conversationAgentSessionID: UUID?,
        _ conversationAgentRunID: UUID?
    ) async throws -> OracleViewModel.OracleSendPackagingContext?
    typealias ResolveExplicitSliceSelection = @MainActor @Sendable (
        _ slices: Value,
        _ lookupContext: WorkspaceLookupContext
    ) async throws -> StoredSelection

    let askOracleToolName: String
    let oracleSendToolName: String
    let oracleChatLogToolName: String
    let promptVM: PromptViewModel
    let oracleVM: OracleViewModel
    let captureRequestMetadata: () async -> RequestMetadata
    let resolveTabContextSnapshot: (RequestMetadata) throws -> ResolvedTabContextSnapshot
    let requireCurrentTabContext: (String) async throws -> TabScopedContext
    let stabilizedVirtualContext: StabilizedVirtualContext
    let resolveDelegatedReviewPackaging: ResolveDelegatedReviewPackaging
    let resolveExplicitSliceSelection: ResolveExplicitSliceSelection
    let rebindChatSessionIfNeeded: (_ metadata: RequestMetadata, _ chatIDString: String) throws -> Void
    let resolveTabIDForAgentMode: (_ args: [String: Value], _ connectionID: UUID?) async throws -> UUID
    let requireTargetWindow: () throws -> WindowState
    let rawExplicitTabID: (_ args: [String: Value]) -> String?
    let sendStageProgress: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String) async -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping ChatSendOperation) async throws -> [String: Value]
    let sendChat: SendChat
    let exportOracleResponse: ExportOracleResponse

    // MARK: Bounded ask_oracle seams (plan §3.4–§3.8)

    typealias StartOracleSend = @MainActor @Sendable (
        _ args: [String: Value],
        _ promptVM: PromptViewModel,
        _ tabContext: OracleViewModel.OracleSendTabContext?,
        _ operationID: UUID
    ) async throws -> OracleViewModel.OracleMCPSendTicket

    /// One frozen wait invocation: the parent-family policy context, the run whose
    /// `activeToolExecutionIDsByRunID` entry this call occupies, and the execution-scoped wake
    /// scope (nil when the run is unresolved — the 180 s bound still applies, no wake).
    struct OracleWaitInvocation {
        let context: AgentMCPWaitPolicy.RequestContext
        let callerRunID: UUID?
        let wakeScopeExecutionID: UUID?
    }

    /// MCP-owned `OracleMCPWaitScope` accessors keyed by execution ID. The scope owns how this
    /// call stops waiting; it never owns or cancels the query.
    struct OracleWaitScopeHooks {
        let isSteeringRequested: @MainActor (_ executionID: UUID) -> Bool
        let subscribe: @MainActor (_ executionID: UUID, _ onWake: @escaping @MainActor () -> Void) -> Void
        let unsubscribe: @MainActor (_ executionID: UUID) -> Void

        static let none = OracleWaitScopeHooks(
            isSteeringRequested: { _ in false },
            subscribe: { _, _ in },
            unsubscribe: { _ in }
        )
    }

    let startOracleSend: StartOracleSend
    let operationStore: OracleMCPOperationStore
    let resolveWaitInvocation: () async -> OracleWaitInvocation
    let waitScopeHooks: OracleWaitScopeHooks
    let cancelOracleQuery: @MainActor (_ chatID: UUID, _ queryID: UUID) async -> OracleViewModel.CancelAIResponseOutcome
    let noteOracleResultIdentity: @MainActor (_ result: [String: Value], _ tabID: UUID) -> Void
    /// Deterministic lifecycle seam; production supplies a no-op.
    let beforeAskOraclePreparation: @MainActor @Sendable () async -> Void

    @MainActor
    private final class HeartbeatCapture<T: Sendable> {
        private(set) var value: T?

        func store(_ value: T) {
            self.value = value
        }
    }

    func executeOracleUtils(args: [String: Value]) async throws -> Value {
        let op = (args["op"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !op.isEmpty else {
            throw MCPError.invalidParams("oracle_utils requires an 'op' parameter.")
        }
        var forwarded = args
        forwarded.removeValue(forKey: "op")

        switch op {
        case "models":
            return try await executeOracleModelsUtility()
        case "sessions":
            if let connectionID = ServerNetworkManager.currentConnectionID,
               await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun
            {
                throw MCPError.invalidParams(
                    "oracle_utils op=sessions is unavailable in Agent Mode because workspace-wide session metadata is not scoped to the current run. Use oracle_chat_log with an explicit chat_id returned by ask_oracle."
                )
            }
            return try await executeLiveOracleSessions(args: forwarded)
        default:
            throw MCPError.invalidParams("Unsupported oracle_utils op '\(op)'. Use models or sessions.")
        }
    }

    func executeOracleChatLog(args: [String: Value]) async throws -> Value {
        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("oracle_chat_log requires an active MCP connection")
        }

        let allowedArgs: Set = ["chat_id", "limit", "include_user", "max_chars", "part", "max_total_chars"]
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_chat_log only accepts: chat_id, limit, include_user, max_chars, part, max_total_chars. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        if let limitValue = args["limit"], limitValue.intValue == nil {
            throw MCPError.invalidParams("limit must be an integer")
        }
        if let includeUserValue = args["include_user"], includeUserValue.boolValue == nil {
            throw MCPError.invalidParams("include_user must be a boolean")
        }
        if let maxCharsValue = args["max_chars"] {
            guard let maxChars = maxCharsValue.intValue, maxChars > 0 else {
                throw MCPError.invalidParams("max_chars must be a positive integer")
            }
        }
        if let maxTotalCharsValue = args["max_total_chars"] {
            guard let maxTotalChars = maxTotalCharsValue.intValue, maxTotalChars > 0 else {
                throw MCPError.invalidParams("max_total_chars must be a positive integer")
            }
        }
        if let partValue = args["part"] {
            guard let partRaw = partValue.stringValue else {
                throw MCPError.invalidParams("part must be a string")
            }
            _ = try OracleChatLogPart.parse(partRaw)
        }
        if let chatIDValue = args["chat_id"] {
            guard let chatIDRaw = chatIDValue.stringValue else {
                throw MCPError.invalidParams("chat_id must be a string")
            }
            guard !chatIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("chat_id cannot be empty when provided")
            }
        }

        let hasExplicitTabID = rawExplicitTabID(args) != nil
        let tabID: UUID
        let tabContext: TabScopedContext?
        if hasExplicitTabID {
            tabID = try await resolveTabIDForAgentMode(args, connectionID)
            let requestContext = try? await requireCurrentTabContext(oracleChatLogToolName)
            tabContext = (requestContext?.tabID == tabID) ? requestContext : nil
        } else {
            let currentContext = try await requireCurrentTabContext(oracleChatLogToolName)
            tabID = currentContext.tabID
            tabContext = currentContext
        }
        let targetWindow = try requireTargetWindow()
        let owner = await resolveAgentOracleOwner(tabID: tabID, targetWindow: targetWindow, tabContext: tabContext)

        let result = try await oracleVM.tool_oracleChatLog(
            args: args,
            tabID: tabID,
            agentModeSessionID: owner.agentSessionID,
            agentModeRunID: owner.runID
        )
        return .object(result)
    }

    // MARK: - ask_oracle (agent-mode only)

    /// `op:"wait"` / `op:"cancel"` accept at most this many handles per call (plan §3.2).
    static let operationIDsPerCallLimit = 16
    /// Byte ceiling for a pending single-send result, asserted by `MCPAskOracleLifecycleTests`.
    static let pendingStubByteCeiling = 700

    static let pendingNote = "Oracle still running; nothing was resent. Use ask_oracle with resume args. Never resend."
    private static let cancelNote = "Cancel never delivers a result. Collect each lane's final state with ask_oracle op:\"wait\"."
    static let steeringWakeReason = "steering_requested"

    private static let singleAskOracleArgs: Set<String> = [
        "message", "mode", "chat_id", "new_chat", "model", "chat_name",
        "export_response", "selection_mode", "slices", "max_output_tokens", "response_mode",
        "op", "timeout_seconds", "request_id"
    ]

    private static let batchAskOracleArgs: Set<String> = [
        "consultations", "require_distinct", "op", "timeout_seconds", "request_id"
    ]

    private static let waitAskOracleArgs: Set<String> = [
        "op", "operation_ids", "timeout_seconds"
    ]

    private static let cancelAskOracleArgs: Set<String> = [
        "op", "operation_ids"
    ]

    enum AskOracleOp: String {
        case send
        case wait
        case cancel
    }

    /// `op` and timeouts are validated before any model selection, packaging, chat creation
    /// or send (plan §3.1).
    static func parseAskOracleOp(_ args: [String: Value]) throws -> AskOracleOp {
        guard let value = args["op"] else { return .send }
        guard let raw = value.stringValue else {
            throw MCPError.invalidParams("op must be a string: send, wait, or cancel")
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let op = AskOracleOp(rawValue: normalized) else {
            throw MCPError.invalidParams("Unsupported ask_oracle op '\(raw)'. Use send (default), wait, or cancel.")
        }
        return op
    }

    static func parseAskOracleTimeout(_ value: Value?) throws -> TimeInterval? {
        do {
            return try AgentMCPToolHelpers.parseTimeoutSeconds(value)
        } catch let error as MCPError {
            throw MCPError.invalidParams("timeout_seconds: \(error.localizedDescription)")
        }
    }

    static func parseRequestID(_ args: [String: Value]) throws -> UUID? {
        guard let value = args["request_id"] else { return nil }
        guard let raw = value.stringValue,
              let requestID = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MCPError.invalidParams("request_id must be a UUID string")
        }
        return requestID
    }

    static func parseOperationIDs(_ value: Value?, required: Bool) throws -> [UUID]? {
        guard let value else {
            if required {
                throw MCPError.invalidParams(
                    "operation_ids is required for this op (1…\(operationIDsPerCallLimit) distinct operation_id strings). Omission never means every operation."
                )
            }
            return nil
        }
        guard let array = value.arrayValue else {
            throw MCPError.invalidParams("operation_ids must be an array of operation_id strings")
        }
        guard !array.isEmpty, array.count <= operationIDsPerCallLimit else {
            throw MCPError.invalidParams(
                "operation_ids must contain between 1 and \(operationIDsPerCallLimit) entries"
            )
        }
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for (index, item) in array.enumerated() {
            guard let raw = item.stringValue,
                  let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw MCPError.invalidParams("operation_ids[\(index)] must be an operation_id UUID string")
            }
            guard seen.insert(id).inserted else {
                throw MCPError.invalidParams("operation_ids must be distinct (duplicate \(id.uuidString))")
            }
            ids.append(id)
        }
        return ids
    }

    func executeAskOracle(args: [String: Value]) async throws -> Value {
        switch try Self.parseAskOracleOp(args) {
        case .wait:
            return try await executeAskOracleWait(args: args)
        case .cancel:
            return try await executeAskOracleCancel(args: args)
        case .send:
            if args["consultations"] != nil {
                return try await executeAskOracleBatch(args: args)
            }
            return try await executeAskOracleSingle(args: args)
        }
    }

    // MARK: Single send (bounded, plan §3.1/§3.6)

    private func executeAskOracleSingle(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.singleAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle only accepts: message, mode, chat_id, new_chat, model, chat_name, export_response, selection_mode, slices, max_output_tokens, response_mode, op, timeout_seconds, request_id. Unsupported args: \(unsupported.joined(separator: ", ")). For multiple independent lanes use consultations; to resume use op:\"wait\"."
            )
        }

        // Timeout, request_id and presentation are validated before any model selection,
        // packaging, chat creation or send.
        let rawTimeout = args["timeout_seconds"]
        _ = try Self.parseAskOracleTimeout(rawTimeout)
        let requestID = try Self.parseRequestID(args)
        try validateCommonOracleArgs(args)
        if let responseModeValue = args["response_mode"], responseModeValue.stringValue == nil {
            throw MCPError.invalidParams("response_mode must be a string")
        }
        let responseMode = try OracleResponseMode.parse(args["response_mode"]?.stringValue)
        let exportResponse = try parseExportResponseFlag(args)

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        // One monotonic observation deadline per invocation. It starts before owner
        // resolution and covers mutable preparation, accepted-send binding, and streaming.
        let clock = ContinuousClock()
        let observationStart = clock.now
        let invocation = await resolveWaitInvocation()
        let selection = try AgentMCPWaitPolicy.selection(
            rawTimeout: rawTimeout,
            parentFamily: invocation.context.parentFamily
        )

        await sendStageProgress(connectionID, askOracleToolName, "starting", "Starting Oracle...")

        let observationCapture = HeartbeatCapture<SingleObservation>()
        _ = try await withHeartbeat(
            connectionID,
            askOracleToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            let started = try await startAskOracleOperation(
                args: args,
                connectionID: connectionID,
                requestID: requestID,
                responseMode: responseMode,
                exportResponse: exportResponse
            )
            let remaining = Self.remainingTimeout(
                selection: selection,
                elapsed: observationStart.duration(to: clock.now)
            )
            let outcome = await operationStore.awaitSettlement(
                of: [started.operationID],
                timeoutSeconds: remaining,
                externalWake: externalWake(for: invocation)
            )
            await observationCapture.store(SingleObservation(started: started, outcome: outcome))
            return [:]
        }
        guard let observation = observationCapture.value else {
            throw MCPError.internalError("ask_oracle lost its typed observation result")
        }
        let operationID = observation.started.operationID
        let outcome = observation.outcome
        if outcome == .cancelled {
            // Tool-task cancellation affects only this observer; the stream keeps running.
            throw CancellationError()
        }
        let parkedMS = Int(Self.seconds(observationStart.duration(to: clock.now)) * 1000)

        let result: [String: Value]
        let outcomeLabel: String
        var stubBytes = 0
        if operationStore.allSettled([operationID]) {
            if observation.started.startupTask != nil,
               let startupError = operationStore.startupRejection(for: operationID)
            {
                // Only the originating observer throws the recorded pre-send rejection.
                // Bound terminal delivery never joins independent post-bind startup work.
                throw startupError
            }
            do {
                result = try await deliverOperation(operationID)
            } catch {
                throw ChatToolError(
                    code: .internalError,
                    message: "ask_oracle could not deliver operation \(operationID.uuidString): \(error.localizedDescription). Retry with op:\"wait\" and this operation_id; the completed lane was not consumed.",
                    details: ["operation_id": operationID.uuidString]
                )
            }
            outcomeLabel = result["status"]?.stringValue ?? "completed"
        } else {
            let reason = Self.pendingReason(outcome: outcome, selection: selection)
            result = pendingStub(
                operationID,
                reason: reason,
                includeResume: true,
                steering: outcome == .steering
            )
            outcomeLabel = reason
        }
        let attached = AgentMCPWaitPolicy.attaching(selection, to: .object(result))
        if outcomeLabel != "completed", let object = attached.objectValue {
            stubBytes = Self.approximateByteCount(.object(object))
        }
        recordWaitDiagnostics(
            op: "send",
            selection: selection,
            outcome: outcomeLabel,
            parkedMS: parkedMS,
            operationCount: 1,
            stubBytes: stubBytes,
            progressPresent: result["pending"]?.objectValue?["progress"] != nil,
            wakeReason: outcome == .steering ? Self.steeringWakeReason : nil
        )

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle complete")
        return Self.agentFacingOracleResult(attached)
    }

    private struct StartedAskOracleOperation {
        let operationID: UUID
        let startupTask: Task<ChatToolError?, Never>?
    }

    private struct SingleObservation {
        let started: StartedAskOracleOperation
        let outcome: OracleMCPOperationStore.WaitOutcome
    }

    /// Resolves immutable owner/key identity and reserves before mutable packaging or model
    /// preparation. New work is launched as store-owned startup so the invocation can park,
    /// time out, or wake while preparation and post-bind activation are suspended.
    private func startAskOracleOperation(
        args: [String: Value],
        connectionID: UUID,
        requestID: UUID?,
        responseMode: OracleResponseMode,
        exportResponse: Bool
    ) async throws -> StartedAskOracleOperation {
        let owner = try await resolveCallerScope(args: args, connectionID: connectionID)
        let requestKey = requestID.map { OracleMCPOperationStore.RequestKey(owner: owner, requestID: $0) }
        let intentDigest = requestKey == nil ? nil : Self.intentDigest(
            args: args,
            responseMode: responseMode,
            exportResponse: exportResponse
        )
        let provisionalFinalization = OracleMCPOperationStore.FinalizationRequest(
            mode: args["mode"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "chat",
            message: (args["message"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            responseMode: responseMode,
            exportResponse: exportResponse,
            exportDestination: nil
        )

        let operationID: UUID
        switch try operationStore.reserve(
            owner: owner,
            finalization: provisionalFinalization,
            requestKey: requestKey,
            intentDigest: intentDigest
        ) {
        case let .existing(existingID):
            // Identical keyed intent observes the existing handle before mutable preparation.
            return StartedAskOracleOperation(operationID: existingID, startupTask: nil)
        case let .reserved(reservedID):
            operationID = reservedID
        }

        let task = Task<ChatToolError?, Never> { @MainActor in
            await beforeAskOraclePreparation()
            do {
                let prepared = try await prepareAskOracleSend(args: args, connectionID: connectionID)
                let preparedOwner = OracleMCPOperationStore.OwnerScope(
                    tabID: prepared.tabID,
                    agentSessionID: prepared.owner.agentSessionID,
                    runID: prepared.owner.runID
                )
                guard preparedOwner == owner else {
                    throw ChatToolError.internalError(
                        "ask_oracle owner changed during startup; no consultation was sent"
                    )
                }
                let finalization = try await makeFinalizationRequest(
                    args: args,
                    connectionID: connectionID,
                    responseMode: responseMode,
                    exportResponse: exportResponse,
                    lookupContext: prepared.tabContext.packaging.lookupContext,
                    tabID: prepared.tabID
                )
                operationStore.updateFinalization(operationID, finalization: finalization)
                let ticket = try await startOracleSend(
                    prepared.chatArgs,
                    promptVM,
                    prepared.tabContext,
                    operationID
                )
                operationStore.finishStartupTask(operationID)
                guard operationStore.snapshot(operationID)?.queryID == ticket.queryID else {
                    // The receipt did not take the accepted ticket's pin.
                    oracleVM.unpinSession(ticket.chatID)
                    operationStore.discardUnstarted(operationID)
                    return ChatToolError.internalError(
                        "ask_oracle could not bind operation \(operationID.uuidString)"
                    )
                }
                return nil
            } catch {
                // A post-bind suspension may be cancelled during teardown; a bound operation
                // remains authoritative and its completion observer owns terminal state.
                if operationStore.snapshot(operationID)?.queryID != nil {
                    operationStore.finishStartupTask(operationID)
                    return nil
                }
                let rejection = (error as? ChatToolError)
                    ?? ChatToolError.invalidParams(error.localizedDescription)
                operationStore.rejectStartup(operationID, error: rejection)
                return rejection
            }
        }
        operationStore.installStartupTask(operationID, task: task)
        // Give immediately runnable actor-local startup work a fair chance to reach its accepted-send
        // bind before poll mode constructs the pending DTO. This is scheduling-only (no sleeping or
        // wall-clock extension); genuinely suspended preparation remains bounded by the observer.
        for _ in 0 ..< 64 {
            guard operationStore.snapshot(operationID)?.phase == .starting else { break }
            await Task.yield()
        }
        return StartedAskOracleOperation(operationID: operationID, startupTask: task)
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private nonisolated static func remainingTimeout(
        selection: AgentMCPWaitPolicy.Selection,
        elapsed: Duration
    ) -> TimeInterval {
        guard selection.mode != .poll else { return 0 }
        return max(0, selection.timeoutSeconds - seconds(elapsed))
    }

    private static func pendingReason(
        outcome: OracleMCPOperationStore.WaitOutcome,
        selection: AgentMCPWaitPolicy.Selection
    ) -> String {
        switch outcome {
        case .steering:
            "interrupted_by_steering"
        case .polled, .deadline:
            selection.mode == .poll ? "polled" : "timed_out"
        case .settled:
            "completed"
        case .cancelled:
            "cancelled"
        }
    }

    private func externalWake(for invocation: OracleWaitInvocation) -> OracleMCPOperationStore.ExternalWake? {
        guard let executionID = invocation.wakeScopeExecutionID else { return nil }
        let hooks = waitScopeHooks
        return OracleMCPOperationStore.ExternalWake(
            isRequested: { hooks.isSteeringRequested(executionID) },
            subscribe: { onWake in hooks.subscribe(executionID, onWake) },
            unsubscribe: { hooks.unsubscribe(executionID) }
        )
    }

    /// Delivers a terminal operation exactly once (single-flight in the store) and records the
    /// UI identity sidecar for tool cards.
    private func deliverOperation(_ operationID: UUID) async throws -> [String: Value] {
        let tabID = operationStore.snapshot(operationID)?.owner.tabID
        let result = try await operationStore.deliver(operationID) { result, request in
            try await finalizeAskOracleResult(&result, request: request)
        }
        if let tabID {
            noteOracleResultIdentity(result, tabID)
        }
        recordDiagnosticsEvent("mcp.oracle.finalize", fields: [
            "status": result["status"]?.stringValue ?? "unknown",
            "exported": (result["oracle_export_path"] != nil) ? "1" : "0"
        ])
        return result
    }

    /// Pending stub (plan §3.2). Never carries `response`; model identity comes from the same
    /// helper as the final reply so the preset-redaction rule stays intact.
    private func pendingStub(
        _ operationID: UUID,
        reason: String,
        includeResume: Bool,
        steering: Bool
    ) -> [String: Value] {
        guard let snapshot = operationStore.snapshot(operationID) else {
            return ["status": .string("unknown"), "operation_id": .string(operationID.uuidString)]
        }
        var stub: [String: Value] = [
            "status": .string("pending"),
            "operation_id": .string(operationID.uuidString),
            "mode": .string(snapshot.finalization.mode)
        ]
        if let batchIndex = snapshot.batchIndex {
            stub["index"] = .int(batchIndex)
            stub["chat_id"] = snapshot.chatShortID.map(Value.string) ?? .null
            stub["query_id"] = snapshot.queryID.map { .string($0.uuidString) } ?? .null
        } else {
            if let chatShortID = snapshot.chatShortID {
                stub["chat_id"] = .string(chatShortID)
            }
            if let queryID = snapshot.queryID {
                stub["query_id"] = .string(queryID.uuidString)
            }
        }
        if let context = operationStore.replyContext(operationID) {
            let identity = oracleVM.modelIdentityFields(context)
            if let presetName = identity["model_preset_name"] {
                stub["model_preset_name"] = presetName
            } else if let modelName = identity["model_name"] {
                stub["model_name"] = modelName
            }
        }
        let streamState = switch snapshot.phase {
        case .queued: "queued"
        case .starting: "starting"
        case .running: "streaming"
        case .cancelling: "cancelling"
        case .ready, .failed, .cancelled: "terminal"
        }
        var pending: [String: Value] = [
            "reason": .string(reason),
            "stream_state": .string(streamState),
            "elapsed_seconds": .int(operationStore.elapsedSeconds(for: operationID) ?? 0)
        ]
        if let progress = operationStore.progress(for: operationID) {
            var progressFields: [String: Value] = [:]
            if let outputChars = progress.outputChars {
                progressFields["output_chars"] = .int(outputChars)
            }
            if let activityAge = progress.lastActivitySecondsAgo {
                progressFields["last_activity_seconds_ago"] = .int(activityAge)
            }
            if let queuePosition = progress.queuePosition {
                progressFields["queue_position"] = .int(queuePosition)
            }
            if !progressFields.isEmpty {
                pending["progress"] = .object(progressFields)
            }
        }
        stub["pending"] = .object(pending)
        if includeResume {
            stub["resume"] = Self.resumeValue([operationID])
            stub["note"] = .string(Self.pendingNote)
            if steering {
                stub["_meta"] = .object(["wake_reason": .string(Self.steeringWakeReason)])
            }
        }
        return stub
    }

    private static func resumeValue(_ operationIDs: [UUID]) -> Value {
        var resume: [String: Value] = ["op": .string("wait")]
        if operationIDs.count <= Self.operationIDsPerCallLimit {
            resume["operation_ids"] = .array(operationIDs.map { .string($0.uuidString) })
        }
        return .object(resume)
    }

    private static func unknownLane(_ operationID: UUID) -> Value {
        .object([
            "operation_id": .string(operationID.uuidString),
            "status": .string("unknown"),
            "ok": .bool(false),
            "error": .object([
                "code": .string(ChatToolErrorCode.oracleOperationNotFound.rawValue),
                "message": .string("operation_id \(operationID.uuidString) is unknown to this caller. If the Oracle answered before this app relaunched, read it with oracle_chat_log using the chat_id you already hold; never resend.")
            ])
        ])
    }

    private func deliveryFailureLane(_ operationID: UUID, error: Error) -> Value {
        var lane: [String: Value] = [
            "operation_id": .string(operationID.uuidString),
            "status": .string("delivery_failed"),
            "ok": .bool(false),
            "error": .object([
                "code": .string(ChatToolErrorCode.internalError.rawValue),
                "message": .string(
                    "Completed operation \(operationID.uuidString) could not be delivered: \(error.localizedDescription). Retry this operation_id with ask_oracle op:\"wait\"."
                )
            ])
        ]
        if let batchIndex = operationStore.snapshot(operationID)?.batchIndex {
            lane["index"] = .int(batchIndex)
        }
        return .object(lane)
    }

    private static func expiredLane(_ tombstone: OracleMCPOperationStore.Tombstone) -> Value {
        var lane: [String: Value] = [
            "operation_id": .string(tombstone.operationID.uuidString),
            "status": .string("unknown"),
            "ok": .bool(false),
            "error": .object([
                "code": .string(ChatToolErrorCode.oracleOperationExpired.rawValue),
                "message": .string("operation_id \(tombstone.operationID.uuidString) was evicted after delivery or retention expiry. Read the chat with oracle_chat_log; do not resend.")
            ])
        ]
        if let batchIndex = tombstone.batchIndex {
            lane["index"] = .int(batchIndex)
        }
        if let chatShortID = tombstone.chatShortID {
            lane["chat_id"] = .string(chatShortID)
        }
        return .object(lane)
    }

    /// Compact current-state lane for cancel results and terminal-but-undelivered rows.
    private func snapshotLane(_ operationID: UUID) -> [String: Value] {
        guard let snapshot = operationStore.snapshot(operationID) else {
            return unknownLaneObject(operationID)
        }
        if !snapshot.phase.isTerminal {
            return pendingStub(operationID, reason: "polled", includeResume: false, steering: false)
        }
        var lane: [String: Value] = [
            "operation_id": .string(operationID.uuidString),
            "status": .string(snapshot.phase == .ready ? "completed" : snapshot.phase.rawValue),
            "delivered": .bool(snapshot.delivery == .delivered),
            "mode": .string(snapshot.finalization.mode)
        ]
        if let batchIndex = snapshot.batchIndex {
            lane["index"] = .int(batchIndex)
        }
        if let chatShortID = snapshot.chatShortID {
            lane["chat_id"] = .string(chatShortID)
        }
        if let queryID = snapshot.queryID {
            lane["query_id"] = .string(queryID.uuidString)
        }
        return lane
    }

    private func unknownLaneObject(_ operationID: UUID) -> [String: Value] {
        Self.unknownLane(operationID).objectValue ?? [:]
    }

    private func resolveCallerScope(
        args: [String: Value],
        connectionID: UUID
    ) async throws -> OracleMCPOperationStore.OwnerScope {
        let targetWindow = try requireTargetWindow()
        let tabID = try await resolveTabIDForAgentMode(args, connectionID)
        let requestContext = try? await requireCurrentTabContext(askOracleToolName)
        let owner = await resolveAgentOracleOwner(
            tabID: tabID,
            targetWindow: targetWindow,
            tabContext: (requestContext?.tabID == tabID) ? requestContext : nil
        )
        return OracleMCPOperationStore.OwnerScope(
            tabID: tabID,
            agentSessionID: owner.agentSessionID,
            runID: owner.runID
        )
    }

    // MARK: op:"wait" (plan §3.2/§3.6)

    private func executeAskOracleWait(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.waitAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle op:\"wait\" only accepts operation_ids and timeout_seconds; presentation was frozen at send. Unsupported args: \(unsupported.joined(separator: ", "))."
            )
        }
        let rawTimeout = args["timeout_seconds"]
        _ = try Self.parseAskOracleTimeout(rawTimeout)
        let requestedIDs = try Self.parseOperationIDs(args["operation_ids"], required: false)

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }
        let caller = try await resolveCallerScope(args: args, connectionID: connectionID)
        let invocation = await resolveWaitInvocation()
        let selection = try AgentMCPWaitPolicy.selection(
            rawTimeout: rawTimeout,
            parentFamily: invocation.context.parentFamily
        )
        operationStore.purge()
        let targetIDs = requestedIDs ?? operationStore.undeliveredOperationIDs(owner: caller)
        return try await observeAskOracleOperations(
            targetIDs: targetIDs,
            caller: caller,
            selection: selection,
            timeoutSeconds: selection.mode == .poll ? 0 : selection.timeoutSeconds,
            connectionID: connectionID,
            invocation: invocation,
            op: "wait"
        )
    }

    private func observeAskOracleOperations(
        targetIDs: [UUID],
        caller: OracleMCPOperationStore.OwnerScope,
        selection: AgentMCPWaitPolicy.Selection,
        timeoutSeconds: TimeInterval,
        connectionID: UUID,
        invocation: OracleWaitInvocation,
        op: String
    ) async throws -> Value {
        var lanesByID: [UUID: Value] = [:]
        var observable: [UUID] = []
        var hasLaneErrors = false
        for id in targetIDs {
            switch operationStore.lookup(id, caller: caller) {
            case .found:
                observable.append(id)
            case let .expired(tombstone):
                lanesByID[id] = Self.expiredLane(tombstone)
                hasLaneErrors = true
            case .notFound:
                lanesByID[id] = Self.unknownLane(id)
                hasLaneErrors = true
            }
        }

        let clock = ContinuousClock()
        let observationStart = clock.now
        var outcome: OracleMCPOperationStore.WaitOutcome = .settled
        if !observable.isEmpty {
            let capturedObservable = observable
            let wake = externalWake(for: invocation)
            let outcomeCapture = HeartbeatCapture<OracleMCPOperationStore.WaitOutcome>()
            _ = try await withHeartbeat(
                connectionID,
                askOracleToolName,
                "waiting",
                "Waiting for Oracle response..."
            ) {
                let capturedOutcome = await operationStore.awaitSettlement(
                    of: capturedObservable,
                    timeoutSeconds: timeoutSeconds,
                    externalWake: wake
                )
                await outcomeCapture.store(capturedOutcome)
                return [:]
            }
            guard let capturedOutcome = outcomeCapture.value else {
                throw MCPError.internalError("ask_oracle wait lost its typed observation result")
            }
            outcome = capturedOutcome
        }
        if outcome == .cancelled {
            throw CancellationError()
        }
        let parkedMS = Int(Self.seconds(observationStart.duration(to: clock.now)) * 1000)

        // Re-authorize and re-resolve after every suspension. An evicted lane or a delivery
        // failure is lane-local; it never discards successful earlier lanes.
        var pendingIDs: [UUID] = []
        var retryableIDs: [UUID] = []
        var stubBytes = 0
        var progressPresent = false
        let laneReason = Self.pendingReason(outcome: outcome, selection: selection)
        for id in observable {
            switch operationStore.lookup(id, caller: caller) {
            case let .found(snapshot) where snapshot.phase.isTerminal:
                do {
                    let delivered = try await deliverOperation(id)
                    lanesByID[id] = .object(delivered)
                } catch {
                    retryableIDs.append(id)
                    hasLaneErrors = true
                    lanesByID[id] = deliveryFailureLane(id, error: error)
                }
            case .found:
                pendingIDs.append(id)
                let stub = pendingStub(id, reason: laneReason, includeResume: false, steering: false)
                stubBytes += Self.approximateByteCount(.object(stub))
                progressPresent = progressPresent || stub["pending"]?.objectValue?["progress"] != nil
                lanesByID[id] = .object(stub)
            case let .expired(tombstone):
                lanesByID[id] = Self.expiredLane(tombstone)
                hasLaneErrors = true
            case .notFound:
                lanesByID[id] = Self.unknownLane(id)
                hasLaneErrors = true
            }
        }

        // Precedence: all terminal → lane-local errors → steering → poll → deadline.
        let waitResult = if pendingIDs.isEmpty, retryableIDs.isEmpty, !hasLaneErrors {
            "completed"
        } else if pendingIDs.isEmpty {
            "completed_with_errors"
        } else if outcome == .steering {
            "interrupted_by_steering"
        } else if selection.mode == .poll {
            "polled"
        } else {
            "timed_out"
        }

        var wait: [String: Value] = [
            "result": .string(waitResult),
            "pending_operation_ids": .array(pendingIDs.map { .string($0.uuidString) })
        ]
        if !retryableIDs.isEmpty {
            wait["retryable_operation_ids"] = .array(retryableIDs.map { .string($0.uuidString) })
        }
        var envelope: [String: Value] = [
            "results": .array(targetIDs.compactMap { lanesByID[$0] }),
            "wait": .object(wait)
        ]
        let resumeIDs = pendingIDs + retryableIDs
        if !resumeIDs.isEmpty {
            envelope["resume"] = Self.resumeValue(resumeIDs)
            envelope["note"] = .string(Self.pendingNote)
        }
        if outcome == .steering, !pendingIDs.isEmpty {
            envelope["_meta"] = .object(["wake_reason": .string(Self.steeringWakeReason)])
        }
        recordWaitDiagnostics(
            op: op,
            selection: selection,
            outcome: waitResult,
            parkedMS: parkedMS,
            operationCount: targetIDs.count,
            stubBytes: stubBytes,
            progressPresent: progressPresent,
            wakeReason: outcome == .steering ? Self.steeringWakeReason : nil
        )
        return Self.agentFacingOracleResult(AgentMCPWaitPolicy.attaching(selection, to: .object(envelope)))
    }

    // MARK: op:"cancel" (plan §3.8)

    private func executeAskOracleCancel(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.cancelAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle op:\"cancel\" only accepts operation_ids. Unsupported args: \(unsupported.joined(separator: ", "))."
            )
        }
        guard let operationIDs = try Self.parseOperationIDs(args["operation_ids"], required: true) else {
            throw MCPError.invalidParams("operation_ids is required for op:\"cancel\"")
        }
        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }
        let caller = try await resolveCallerScope(args: args, connectionID: connectionID)
        operationStore.purge()

        // Resolve and authorize the whole list before any mutation.
        let lookups = operationIDs.map { ($0, operationStore.lookup($0, caller: caller)) }

        var lanes: [Value] = []
        var resumeIDs: [UUID] = []
        var cancelOutcomes: [String: Int] = [:]
        for (operationID, lookup) in lookups {
            switch lookup {
            case .notFound:
                lanes.append(Self.unknownLane(operationID))
            case let .expired(tombstone):
                lanes.append(Self.expiredLane(tombstone))
            case let .found(authorizedSnapshot):
                // A prior lane's transport stop may have suspended; re-read this authorized
                // lane before deciding whether or how to mutate it.
                let snapshot = operationStore.snapshot(operationID) ?? authorizedSnapshot
                let cancelValue: String
                switch snapshot.phase {
                case .queued:
                    cancelValue = operationStore.cancelUnboundBatch(operationID)
                        ? "requested"
                        : "already_terminal"
                case .starting:
                    if snapshot.batchIndex != nil {
                        cancelValue = operationStore.cancelUnboundBatch(operationID)
                            ? "requested"
                            : "already_terminal"
                    } else {
                        cancelValue = "not_cancellable_yet"
                    }
                case .running:
                    guard operationStore.beginCancelRequest(operationID) else {
                        cancelValue = operationStore.snapshot(operationID)?.phase.isTerminal == true
                            ? "already_terminal"
                            : "requested"
                        break
                    }
                    if let chatID = snapshot.chatID, let queryID = snapshot.queryID {
                        // The store gate is claimed synchronously before suspension, so
                        // concurrent cancel calls cannot both issue a transport stop.
                        switch await cancelOracleQuery(chatID, queryID) {
                        case .stopIssued:
                            cancelValue = "requested"
                        case .noActiveQuery, .queryNotActive:
                            operationStore.cancelRequestRejected(operationID)
                            cancelValue = "query_not_active"
                        }
                    } else {
                        operationStore.cancelRequestRejected(operationID)
                        cancelValue = "not_cancellable_yet"
                    }
                case .cancelling:
                    // No second stop; the completion observer still owns the terminal phase.
                    cancelValue = "requested"
                case .ready, .failed, .cancelled:
                    cancelValue = "already_terminal"
                }
                var lane = snapshotLane(operationID)
                lane["cancel"] = .string(cancelValue)
                lanes.append(.object(lane))
                cancelOutcomes[cancelValue, default: 0] += 1
                if operationStore.snapshot(operationID)?.delivery != .delivered {
                    resumeIDs.append(operationID)
                }
            }
        }

        var envelope: [String: Value] = [
            "results": .array(lanes),
            "note": .string(Self.cancelNote)
        ]
        if !resumeIDs.isEmpty {
            envelope["resume"] = Self.resumeValue(resumeIDs)
        }
        recordDiagnosticsEvent("mcp.oracle.cancel", fields: cancelOutcomes.reduce(into: ["operation_count": String(operationIDs.count)]) {
            $0["cancel.\($1.key)"] = String($1.value)
        })
        return Self.agentFacingOracleResult(.object(envelope))
    }

    // MARK: Diagnostics (plan §3.11)

    private func recordWaitDiagnostics(
        op: String,
        selection: AgentMCPWaitPolicy.Selection,
        outcome: String,
        parkedMS: Int,
        operationCount: Int,
        stubBytes: Int,
        progressPresent: Bool,
        wakeReason: String?
    ) {
        var fields: [String: String] = [
            "op": op,
            "mode": selection.mode.rawValue,
            "timeout_seconds": String(Int(selection.timeoutSeconds)),
            "parent_family": selection.parentFamily?.rawValue ?? "n/a",
            "outcome": outcome,
            "parked_ms": String(parkedMS),
            "operation_count": String(operationCount),
            "stub_bytes": String(stubBytes),
            "progress_present": progressPresent ? "1" : "0"
        ]
        if let wakeReason {
            fields["wake_reason"] = wakeReason
        }
        recordDiagnosticsEvent("mcp.oracle.wait", fields: fields)
    }

    private func recordDiagnosticsEvent(_ name: String, fields: [String: String]) {
        #if DEBUG
            AgentModePerfDiagnostics.event(name, fields: fields)
        #endif
    }

    private static func approximateByteCount(_ value: Value) -> Int {
        #if DEBUG
            guard let data = try? JSONEncoder().encode(value) else { return 0 }
            return data.count
        #else
            // Stub-size diagnostics are DEBUG-only; avoid release-path JSON re-encoding.
            return 0
        #endif
    }

    /// Normalized intent compared only under an explicit `request_id` (plan §3.9).
    /// Excludes `timeout_seconds` and never consults mutable preset state: a retry with the
    /// same selector remains identical even if its preset was edited or removed.
    static func intentDigest(
        args: [String: Value],
        responseMode: OracleResponseMode,
        exportResponse: Bool
    ) -> String {
        func trimmed(_ key: String) -> String {
            (args[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let modelSelector = trimmed("model").lowercased()
        let modelIdentity = modelSelector.isEmpty ? "auto" : "raw:\(modelSelector)"
        let slices = args["slices"].map { ToolOutputFormatter.rawJSONString($0) } ?? ""
        let parts = [
            "message=\(trimmed("message"))",
            "mode=\(trimmed("mode").isEmpty ? "chat" : trimmed("mode").lowercased())",
            "model=\(modelIdentity)",
            "chat_id=\(trimmed("chat_id"))",
            "new_chat=\(args["new_chat"]?.boolValue ?? false)",
            "selection_mode=\(trimmed("selection_mode").isEmpty ? "current" : trimmed("selection_mode").lowercased())",
            "slices=\(slices)",
            "max_output_tokens=\(args["max_output_tokens"]?.intValue.map(String.init) ?? "")",
            "response_mode=\(responseMode.rawValue)",
            "export_response=\(exportResponse)"
        ]
        let canonicalIntent = parts.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonicalIntent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Batch (bounded, resumable; Step C)

    private func executeAskOracleBatch(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.batchAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle consultations is mutually exclusive with the single-send parameter set and accepts only consultations, require_distinct, op, and timeout_seconds. Unsupported args: \(unsupported.joined(separator: ", ")). Batch request_id is unsupported."
            )
        }
        if args["request_id"] != nil {
            throw MCPError.invalidParams(
                "request_id is unsupported for consultations batches; recover accepted lanes with op:\"wait\" rather than resending."
            )
        }
        let rawTimeout = args["timeout_seconds"]
        _ = try Self.parseAskOracleTimeout(rawTimeout)

        guard let consultationsValue = args["consultations"],
              let consultationItems = consultationsValue.arrayValue,
              !consultationItems.isEmpty,
              consultationItems.count <= OracleMCPOperationStore.maxBatchLaneCount
        else {
            throw MCPError.invalidParams(
                "consultations must contain between 1 and \(OracleMCPOperationStore.maxBatchLaneCount) lanes"
            )
        }

        let requireDistinct: Bool
        if let requireDistinctValue = args["require_distinct"] {
            guard let boolValue = requireDistinctValue.boolValue else {
                throw MCPError.invalidParams("require_distinct must be a boolean")
            }
            requireDistinct = boolValue
        } else {
            requireDistinct = false
        }

        var parsedItems: [AskOracleConsultationItem] = []
        parsedItems.reserveCapacity(consultationItems.count)
        for (index, itemValue) in consultationItems.enumerated() {
            guard let object = itemValue.objectValue else {
                throw MCPError.invalidParams("consultations[\(index)] must be an object")
            }
            try parsedItems.append(parseConsultationItem(object, index: index))
        }
        if requireDistinct {
            try validateDistinctConsultationPresets(parsedItems)
        }

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        let clock = ContinuousClock()
        let observationStart = clock.now
        let invocation = await resolveWaitInvocation()
        let selection = try AgentMCPWaitPolicy.selection(
            rawTimeout: rawTimeout,
            parentFamily: invocation.context.parentFamily
        )
        let source = try await captureBatchSource(
            args: args,
            connectionID: connectionID,
            needsReview: parsedItems.contains { $0.mode == "review" }
        )
        let caller = OracleMCPOperationStore.OwnerScope(
            tabID: source.directTabContext.tabID,
            agentSessionID: source.owner.agentSessionID,
            runID: source.owner.runID
        )

        await sendStageProgress(
            connectionID,
            askOracleToolName,
            "starting",
            "Starting \(parsedItems.count) Oracle consultations..."
        )

        let starter = startOracleSend
        let preparationHook = beforeAskOraclePreparation
        let promptVM = promptVM
        let activeRunProvider = source.activeRunProvider
        let submissions = parsedItems.map { item in
            let itemArgs = consultationArgs(item)
            let laneSource = source.laneSource(for: item.mode)
            let tabContext = laneSource.context
            let finalization = makeBatchFinalizationRequest(
                item: item,
                tabContext: tabContext,
                source: source
            )
            return OracleMCPOperationStore.BatchSubmission(
                finalization: finalization,
                activeRunProvider: activeRunProvider,
                startup: { operationID in
                    if let startupError = laneSource.startupError {
                        return startupError
                    }
                    await preparationHook()
                    do {
                        _ = try await starter(itemArgs, promptVM, tabContext, operationID)
                        return nil
                    } catch {
                        return (error as? ChatToolError)
                            ?? ChatToolError.invalidParams(error.localizedDescription)
                    }
                }
            )
        }
        let operationIDs = try operationStore.admitBatch(owner: caller, submissions: submissions)
        let remaining = Self.remainingTimeout(
            selection: selection,
            elapsed: observationStart.duration(to: clock.now)
        )
        let result = try await observeAskOracleOperations(
            targetIDs: operationIDs,
            caller: caller,
            selection: selection,
            timeoutSeconds: remaining,
            connectionID: connectionID,
            invocation: invocation,
            op: "send"
        )

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle consultations complete")
        return result
    }

    private struct AskOracleConsultationItem {
        let message: String
        let model: String
        let mode: String
        let chatName: String?
        let responseMode: OracleResponseMode
    }

    private func parseConsultationItem(
        _ object: [String: Value],
        index: Int
    ) throws -> AskOracleConsultationItem {
        let allowed: Set = ["message", "model", "mode", "chat_name", "response_mode"]
        let unsupported = object.keys.filter { !allowed.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "consultations[\(index)] only accepts: message, model, mode, chat_name, response_mode. Unsupported: \(unsupported.joined(separator: ", "))"
            )
        }

        let message = (object["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw MCPError.invalidParams("consultations[\(index)].message cannot be empty")
        }

        guard let modelRaw = object["model"]?.stringValue else {
            throw MCPError.invalidParams(
                "consultations[\(index)].model is required (exact preset UUID or name)"
            )
        }
        let modelSelector = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelSelector.isEmpty else {
            throw MCPError.invalidParams("consultations[\(index)].model cannot be empty")
        }

        if let modeValue = object["mode"], modeValue.stringValue == nil {
            throw MCPError.invalidParams("consultations[\(index)].mode must be a string")
        }
        let modeRaw = object["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(modeRaw) else {
            throw MCPError.invalidParams(
                "consultations[\(index)].mode must be one of: chat, plan, review"
            )
        }

        let chatName: String?
        if let chatNameValue = object["chat_name"] {
            guard let raw = chatNameValue.stringValue else {
                throw MCPError.invalidParams("consultations[\(index)].chat_name must be a string")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPError.invalidParams(
                    "consultations[\(index)].chat_name cannot be empty when provided"
                )
            }
            chatName = trimmed
        } else {
            chatName = nil
        }

        if let responseModeValue = object["response_mode"],
           responseModeValue.stringValue == nil
        {
            throw MCPError.invalidParams(
                "consultations[\(index)].response_mode must be a string"
            )
        }
        let responseMode = try OracleResponseMode.parse(object["response_mode"]?.stringValue)
        let model = try resolveBatchModelSelector(
            modelSelector,
            mode: modeRaw,
            index: index
        )

        return AskOracleConsultationItem(
            message: message,
            model: model,
            mode: modeRaw,
            chatName: chatName,
            responseMode: responseMode
        )
    }

    private func validateDistinctConsultationPresets(
        _ items: [AskOracleConsultationItem]
    ) throws {
        let configuredPresets = ModelPresetsManager.shared.allPresets()
        var seen: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            let key = if let preset = Self.exactModelPresetMatch(item.model, in: configuredPresets) {
                "preset:\(preset.id.uuidString)"
            } else {
                "raw:\(item.model.lowercased())"
            }
            if let prior = seen[key] {
                throw MCPError.invalidParams(
                    "require_distinct:true rejected consultations[\(prior)] and consultations[\(index)] because they resolve to the same preset/model. No lanes were started."
                )
            }
            seen[key] = index
        }
    }

    private struct CapturedBatchSource {
        let owner: AgentOracleOwner
        let directTabContext: OracleViewModel.OracleSendTabContext
        let reviewTabContext: OracleViewModel.OracleSendTabContext?
        let reviewError: ChatToolError?
        let workspace: WorkspaceModel?
        let windowID: Int
        let activeRunProvider: @MainActor () -> UUID?

        func laneSource(for mode: String) -> (
            context: OracleViewModel.OracleSendTabContext,
            startupError: ChatToolError?
        ) {
            guard mode == "review" else { return (directTabContext, nil) }
            return (reviewTabContext ?? directTabContext, reviewError)
        }
    }

    private func captureBatchSource(
        args: [String: Value],
        connectionID: UUID,
        needsReview: Bool
    ) async throws -> CapturedBatchSource {
        let targetWindow = try requireTargetWindow()
        let tabID = try await resolveTabIDForAgentMode(args, connectionID)
        let requestContext = try? await requireCurrentTabContext(askOracleToolName)
        let virtualContext = (requestContext?.tabID == tabID) ? requestContext : nil
        let owner = await resolveAgentOracleOwner(
            tabID: tabID,
            targetWindow: targetWindow,
            tabContext: virtualContext
        )
        guard owner.agentSessionID != nil || owner.runID != nil else {
            throw MCPError.invalidParams(
                "consultations batches require an authenticated active Agent Mode session or run"
            )
        }

        let directTabContext: OracleViewModel.OracleSendTabContext
        if let virtualContext {
            directTabContext = try await oracleSendTabContext(
                from: virtualContext,
                owner: owner,
                origin: .askOracle,
                mode: "chat"
            )
        } else {
            guard let tabSnapshot = targetWindow.workspaceManager.composeTabSnapshot(for: tabID) else {
                throw MCPError.internalError("Unable to resolve compose tab context for ask_oracle")
            }
            let lookupContext = try await oraclePackagingLookupContext(owner: owner)
            let workspace = targetWindow.workspaceManager.activeWorkspace
            let workspaceID = workspace?.id
            let reviewGitContext = await promptVM.freezePromptGitReviewContext(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: owner.agentSessionID,
                bindings: owner.worktreeBindingState.bindings ?? [],
                base: "HEAD"
            )
            let packaging = OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: workspaceID.map {
                    targetWindow.workspaceManager.selectionRevisionForMCP(
                        workspaceID: $0,
                        tabID: tabID
                    )
                } ?? 0,
                sourceAgentSessionID: owner.agentSessionID,
                sourceAgentRunID: owner.runID,
                promptText: tabSnapshot.promptText,
                selection: tabSnapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext,
                provenance: .direct
            )
            directTabContext = OracleViewModel.OracleSendTabContext(
                tabID: tabID,
                workspaceID: workspaceID,
                origin: .askOracle,
                agentModeSessionID: owner.agentSessionID,
                agentModeRunID: owner.runID,
                packaging: packaging
            )
        }

        var reviewTabContext: OracleViewModel.OracleSendTabContext?
        var reviewError: ChatToolError?
        if needsReview {
            do {
                let packaging = try await reviewPackaging(
                    mode: "review",
                    conversationTabID: tabID,
                    conversationWorkspaceID: directTabContext.workspaceID,
                    owner: owner,
                    direct: directTabContext.packaging
                )
                reviewTabContext = OracleViewModel.OracleSendTabContext(
                    tabID: tabID,
                    workspaceID: directTabContext.workspaceID,
                    origin: .askOracle,
                    agentModeSessionID: owner.agentSessionID,
                    agentModeRunID: owner.runID,
                    packaging: packaging
                )
            } catch {
                reviewError = (error as? ChatToolError)
                    ?? ChatToolError.invalidParams(error.localizedDescription)
            }
        }

        let sourceWorkspace = directTabContext.workspaceID.flatMap {
            targetWindow.workspaceManager.workspace(withID: $0)
        }
        if directTabContext.workspaceID != nil, sourceWorkspace == nil {
            throw MCPError.internalError(
                "Unable to resolve the frozen source workspace for ask_oracle batch"
            )
        }

        let agentModeViewModel = targetWindow.agentModeViewModel
        let ownerSessionID = owner.agentSessionID
        let ownerRunID = owner.runID
        let activeRunProvider: @MainActor () -> UUID? = { [weak agentModeViewModel] in
            agentModeViewModel?.mcpOracleActiveRunID(
                tabID: tabID,
                ownerSessionID: ownerSessionID,
                ownerRunID: ownerRunID
            )
        }
        return CapturedBatchSource(
            owner: owner,
            directTabContext: directTabContext,
            reviewTabContext: reviewTabContext,
            reviewError: reviewError,
            workspace: sourceWorkspace,
            windowID: targetWindow.windowID,
            activeRunProvider: activeRunProvider
        )
    }

    private func consultationArgs(_ item: AskOracleConsultationItem) -> [String: Value] {
        var itemArgs: [String: Value] = [
            "message": .string(item.message),
            "mode": .string(item.mode),
            "new_chat": .bool(true),
            "model": .string(item.model),
            "response_mode": .string(item.responseMode.rawValue)
        ]
        if let chatName = item.chatName {
            itemArgs["chat_name"] = .string(chatName)
        }
        return itemArgs
    }

    private func makeBatchFinalizationRequest(
        item: AskOracleConsultationItem,
        tabContext: OracleViewModel.OracleSendTabContext,
        source: CapturedBatchSource
    ) -> OracleMCPOperationStore.FinalizationRequest {
        let exportDestination: OracleExportDestination? = if item.responseMode == .full {
            nil
        } else {
            try? MCPServerViewModel.makeOracleExportDestination(
                workspace: source.workspace,
                windowID: source.windowID,
                tabID: tabContext.tabID,
                lookupContext: tabContext.packaging.lookupContext ?? .visibleWorkspace
            )
        }
        return OracleMCPOperationStore.FinalizationRequest(
            mode: item.mode,
            message: item.message,
            responseMode: item.responseMode,
            exportResponse: false,
            exportDestination: exportDestination
        )
    }

    /// Freezes presentation at send (plan §3.5): mode, message, `response_mode`,
    /// `export_response`, and the export destination derived from the original packaging
    /// scope. A destination that cannot be resolved is frozen as `nil`; finalization then
    /// takes the inline `export_failed_warning` fallback so a response is never lost.
    private func makeFinalizationRequest(
        args: [String: Value],
        connectionID: UUID,
        responseMode: OracleResponseMode,
        exportResponse: Bool,
        lookupContext: WorkspaceLookupContext?,
        tabID: UUID? = nil
    ) async throws -> OracleMCPOperationStore.FinalizationRequest {
        let modeRaw = args["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        let message = (args["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsExport = exportResponse || responseMode != .full
        var exportDestination: OracleExportDestination?
        if needsExport, let targetWindow = try? requireTargetWindow() {
            let resolvedTabID: UUID? = if let tabID {
                tabID
            } else {
                try? await resolveTabIDForAgentMode(args, connectionID)
            }
            if let resolvedTabID {
                let resolvedLookupContext: WorkspaceLookupContext
                if let lookupContext {
                    resolvedLookupContext = lookupContext
                } else {
                    let requestContext = try? await requireCurrentTabContext(askOracleToolName)
                    let owner = await resolveAgentOracleOwner(
                        tabID: resolvedTabID,
                        targetWindow: targetWindow,
                        tabContext: (requestContext?.tabID == resolvedTabID) ? requestContext : nil
                    )
                    resolvedLookupContext = await (try? oraclePackagingLookupContext(owner: owner))
                        ?? .visibleWorkspace
                }
                exportDestination = try? MCPServerViewModel.makeOracleExportDestination(
                    workspace: targetWindow.workspaceManager.activeWorkspace,
                    windowID: targetWindow.windowID,
                    tabID: resolvedTabID,
                    lookupContext: resolvedLookupContext
                )
            }
        }
        return OracleMCPOperationStore.FinalizationRequest(
            mode: modeRaw,
            message: message,
            responseMode: responseMode,
            exportResponse: exportResponse,
            exportDestination: exportDestination
        )
    }

    /// Finalizes a completed reply exactly once per operation (the store's single-flight
    /// delivery guarantees this even under concurrent waits). Export happens at most once.
    private func finalizeAskOracleResult(
        _ result: inout [String: Value],
        request: OracleMCPOperationStore.FinalizationRequest
    ) async throws {
        let chatID = result["chat_id"]?.stringValue
        do {
            if request.requestsExport, request.exportDestination == nil {
                throw MCPError.internalError(
                    "the export destination could not be resolved for this tab at send time"
                )
            }
            try await OracleResponsePresentation.applyResponseMode(
                to: &result,
                mode: request.responseMode
            ) { response in
                try await exportOracleResponse(OracleExportRequest(
                    sourceTool: askOracleToolName,
                    mode: request.mode,
                    message: request.message,
                    chatID: chatID,
                    response: response,
                    destination: request.exportDestination
                ))
            }

            if request.exportResponse, request.responseMode == .full, let exportDestination = request.exportDestination {
                let export = try await exportOracleResponse(OracleExportRequest(
                    sourceTool: askOracleToolName,
                    mode: request.mode,
                    message: request.message,
                    chatID: chatID,
                    response: result["response"]?.stringValue,
                    destination: exportDestination
                ))
                result["oracle_export_path"] = .string(export.path)
                result["oracle_export_instruction"] = .string(export.instruction)
            }
        } catch {
            result["response_mode"] = .string(OracleResponseMode.full.rawValue)
            result["export_failed_warning"] = .string(
                "Oracle export failed after the response completed; returning the full response inline. \(error.localizedDescription)"
            )
        }
    }

    /// Everything `ask_oracle` needs before a send: the immutable send-local packaging context,
    /// the normalized chat args, and the resolved tab/owner used for receipts and admission.
    private struct PreparedAskOracleSend {
        let chatArgs: [String: Value]
        let tabContext: OracleViewModel.OracleSendTabContext
        let tabID: UUID
        let owner: AgentOracleOwner
    }

    private func prepareAskOracleSend(
        args: [String: Value],
        connectionID: UUID
    ) async throws -> PreparedAskOracleSend {
        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let newChat = args["new_chat"]?.boolValue ?? false
        let selectionMode = try parseSelectionMode(args, newChat: newChat)
        let maxOutputTokens = try parseMaxOutputTokens(args)
        let chatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChatID = (chatID?.isEmpty == false) ? chatID : nil
        let model = args["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatName = args["chat_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateNewChatModelSelection(
            newChat: newChat,
            model: model,
            mode: modeRaw
        )
        let targetWindow = try requireTargetWindow()

        let tabID = try await resolveTabIDForAgentMode(args, connectionID)
        let requestContext = try? await requireCurrentTabContext(askOracleToolName)
        let virtualContext = (requestContext?.tabID == tabID) ? requestContext : nil
        if let normalizedChatID {
            guard let session = oracleVM.resolveSession(id: normalizedChatID) else {
                throw MCPError.invalidParams("Chat with ID '\(normalizedChatID)' not found")
            }
            guard let sessionTabID = session.composeTabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' is not bound to a compose tab. Use a chat_id from the current tab."
                )
            }
            guard sessionTabID == tabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' belongs to a different tab. ask_oracle can only continue chats from the current tab."
                )
            }
        }

        let owner = await resolveAgentOracleOwner(tabID: tabID, targetWindow: targetWindow, tabContext: virtualContext)
        var tabContext: OracleViewModel.OracleSendTabContext
        if let virtualContext, virtualContext.tabID == tabID {
            tabContext = try await oracleSendTabContext(
                from: virtualContext,
                owner: owner,
                origin: .askOracle,
                mode: modeRaw
            )
        } else {
            guard let tabSnapshot = targetWindow.workspaceManager.composeTabSnapshot(for: tabID) else {
                throw MCPError.internalError("Unable to resolve compose tab context for ask_oracle")
            }
            let lookupContext = try await oraclePackagingLookupContext(owner: owner)
            let reviewGitContext = await promptVM.freezePromptGitReviewContext(
                workspaceID: targetWindow.workspaceManager.activeWorkspace?.id,
                tabID: tabID,
                sessionID: owner.agentSessionID,
                bindings: owner.worktreeBindingState.bindings ?? [],
                base: "HEAD"
            )
            let workspaceID = targetWindow.workspaceManager.activeWorkspace?.id
            let directPackaging = OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: workspaceID.map {
                    targetWindow.workspaceManager.selectionRevisionForMCP(
                        workspaceID: $0,
                        tabID: tabID
                    )
                } ?? 0,
                sourceAgentSessionID: owner.agentSessionID,
                sourceAgentRunID: owner.runID,
                promptText: tabSnapshot.promptText,
                selection: tabSnapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext,
                provenance: .direct
            )
            let packaging = try await reviewPackaging(
                mode: modeRaw,
                conversationTabID: tabID,
                conversationWorkspaceID: workspaceID,
                owner: owner,
                direct: directPackaging
            )
            tabContext = OracleViewModel.OracleSendTabContext(
                tabID: tabID,
                workspaceID: workspaceID,
                origin: .askOracle,
                agentModeSessionID: owner.agentSessionID,
                agentModeRunID: owner.runID,
                packaging: packaging
            )
        }

        let explicitSelection: StoredSelection?
        if selectionMode == .explicitSlices {
            guard let slices = args["slices"] else {
                throw MCPError.invalidParams(
                    "selection_mode:explicit_slices requires a non-empty slices array"
                )
            }
            guard let lookupContext = tabContext.packaging.lookupContext else {
                throw MCPError.invalidParams(
                    "selection_mode:explicit_slices requires an available workspace lookup context"
                )
            }
            explicitSelection = try await resolveExplicitSliceSelection(slices, lookupContext)
        } else {
            explicitSelection = nil
        }
        let sendPackaging = tabContext.packaging.applying(
            selectionMode: selectionMode,
            explicitSelection: explicitSelection
        )
        tabContext = OracleViewModel.OracleSendTabContext(
            tabID: tabContext.tabID,
            workspaceID: tabContext.workspaceID,
            origin: tabContext.origin,
            agentModeSessionID: tabContext.agentModeSessionID,
            agentModeRunID: tabContext.agentModeRunID,
            packaging: sendPackaging
        )

        var chatArgs: [String: Value] = [
            "message": .string(message),
            "mode": .string(modeRaw),
            "new_chat": .bool(newChat)
        ]
        if let normalizedChatID {
            chatArgs["chat_id"] = .string(normalizedChatID)
        }
        if let model {
            chatArgs["model"] = .string(model)
        }
        if let chatName {
            chatArgs["chat_name"] = .string(chatName)
        }
        chatArgs["selection_mode"] = .string(selectionMode.rawValue)
        if let maxOutputTokens {
            chatArgs["max_output_tokens"] = .int(maxOutputTokens)
        }

        return PreparedAskOracleSend(
            chatArgs: chatArgs,
            tabContext: tabContext,
            tabID: tabID,
            owner: owner
        )
    }

    // MARK: - oracle_send

    func executeOracleSend(args: [String: Value]) async throws -> Value {
        let allowedArgs: Set = ["message", "mode", "chat_id", "new_chat", "model", "export_response"]
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_send only accepts: message, mode, chat_id, new_chat, model, export_response. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        try validateCommonOracleArgs(args)
        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let exportResponse = try parseExportResponseFlag(args)

        let connectionID = ServerNetworkManager.currentConnectionID
        let runPurpose: MCPRunPurpose = if let connectionID {
            await ServerNetworkManager.shared.runPurpose(for: connectionID)
        } else {
            .unknown
        }
        let targetWindow: WindowState? = if exportResponse || runPurpose == .agentModeRun {
            try requireTargetWindow()
        } else {
            nil
        }
        let metadata = await captureRequestMetadata()
        let resolvedContext = try resolveTabContextSnapshot(metadata)
        var tabContext: OracleViewModel.OracleSendTabContext? = nil

        if !resolvedContext.usesActiveTabCompatibility {
            if runPurpose != .agentModeRun,
               let chatIDString = args["chat_id"]?.stringValue,
               !chatIDString.isEmpty
            {
                try rebindChatSessionIfNeeded(metadata, chatIDString)
            }

            let context = try await requireCurrentTabContext(oracleSendToolName)
            if runPurpose == .agentModeRun, let targetWindow {
                let owner = await resolveAgentOracleOwner(tabID: context.tabID, targetWindow: targetWindow, tabContext: context)
                tabContext = try await oracleSendTabContext(
                    from: context,
                    owner: owner,
                    origin: .oracleSend,
                    mode: modeRaw
                )
            } else {
                tabContext = try await oracleSendTabContext(
                    from: context,
                    origin: .oracleSend,
                    mode: modeRaw
                )
            }
        }

        let exportDestination: OracleExportDestination? = if exportResponse, let targetWindow {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: targetWindow.workspaceManager.activeWorkspace,
                windowID: targetWindow.windowID,
                tabID: tabContext?.tabID,
                lookupContext: tabContext?.packaging.lookupContext ?? .visibleWorkspace
            )
        } else {
            nil
        }

        await sendStageProgress(connectionID, oracleSendToolName, "starting", "Starting Oracle...")

        var chatArgs = args
        chatArgs.removeValue(forKey: "export_response")

        let capturedTabContext = tabContext
        let capturedChatArgs = chatArgs
        var result = try await withHeartbeat(
            connectionID,
            oracleSendToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            try await sendChat(capturedChatArgs, promptVM, capturedTabContext)
        }

        if exportResponse {
            let normalizedChatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let export = try await exportOracleResponse(OracleExportRequest(
                sourceTool: oracleSendToolName,
                mode: modeRaw,
                message: message,
                chatID: result["chat_id"]?.stringValue ?? ((normalizedChatID?.isEmpty == false) ? normalizedChatID : nil),
                response: result["response"]?.stringValue,
                destination: exportDestination
            ))
            result["oracle_export_path"] = .string(export.path)
            result["oracle_export_instruction"] = .string(export.instruction)
        }

        await sendStageProgress(connectionID, oracleSendToolName, "complete", "Oracle complete")
        return Self.agentFacingOracleResult(.object(result))
    }

    /// Removes app-only Oracle identity fields at the final MCP serialization boundary.
    /// Preset-backed results also hide legacy provider identity throughout their nested shape.
    /// Tool-card sidecars consume the internal result before this projection.
    private static func agentFacingOracleResult(
        _ value: Value,
        insidePresetResult: Bool = false
    ) -> Value {
        if var object = value.objectValue {
            let hidesProviderIdentity = insidePresetResult
                || object["model_source"]?.stringValue == "preset"
            object.removeValue(forKey: "ui_model_id")
            object.removeValue(forKey: "ui_model_name")
            if hidesProviderIdentity {
                object.removeValue(forKey: "model_id")
                object.removeValue(forKey: "model_name")
            }
            for (key, child) in object {
                object[key] = agentFacingOracleResult(
                    child,
                    insidePresetResult: hidesProviderIdentity
                )
            }
            return .object(object)
        }
        if let array = value.arrayValue {
            return .array(array.map {
                agentFacingOracleResult($0, insidePresetResult: insidePresetResult)
            })
        }
        return value
    }

    // MARK: - Shared helpers

    private func parseExportResponseFlag(_ args: [String: Value]) throws -> Bool {
        guard let value = args["export_response"] else { return false }
        guard let boolValue = value.boolValue else {
            throw MCPError.invalidParams("export_response must be a boolean")
        }
        return boolValue
    }

    private func parseSelectionMode(
        _ args: [String: Value],
        newChat: Bool
    ) throws -> OracleViewModel.OracleSelectionMode {
        if let value = args["selection_mode"], value.stringValue == nil {
            throw MCPError.invalidParams("selection_mode must be a string")
        }
        let raw = args["selection_mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? OracleViewModel.OracleSelectionMode.current.rawValue
        guard let mode = OracleViewModel.OracleSelectionMode(rawValue: raw) else {
            throw MCPError.invalidParams(
                "selection_mode must be one of: current, none, explicit_slices"
            )
        }
        let chatID = args["chat_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if newChat, mode != .current {
            throw MCPError.invalidParams(
                "selection_mode is only valid for continuation sends with an explicit chat_id"
            )
        }
        if mode != .current, chatID?.isEmpty != false {
            throw MCPError.invalidParams(
                "selection_mode:\(mode.rawValue) requires an explicit chat_id for a continuation send"
            )
        }
        if mode == .explicitSlices {
            guard let slices = args["slices"], let array = slices.arrayValue, !array.isEmpty else {
                throw MCPError.invalidParams(
                    "selection_mode:explicit_slices requires a non-empty slices array"
                )
            }
        } else if args["slices"] != nil {
            throw MCPError.invalidParams(
                "slices is only valid with selection_mode:explicit_slices"
            )
        }
        return mode
    }

    private func parseMaxOutputTokens(_ args: [String: Value]) throws -> Int? {
        guard let value = args["max_output_tokens"] else { return nil }
        guard let tokens = value.intValue, tokens > 0 else {
            throw MCPError.invalidParams("max_output_tokens must be a positive integer")
        }
        return tokens
    }

    private func validateCommonOracleArgs(_ args: [String: Value]) throws {
        let message = (args["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw MCPError.invalidParams("message cannot be empty")
        }

        if let modeValue = args["mode"], modeValue.stringValue == nil {
            throw MCPError.invalidParams("mode must be a string")
        }
        let modeRaw = args["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(modeRaw) else {
            throw MCPError.invalidParams("Invalid mode: \(modeRaw). Valid modes: chat, plan, review")
        }

        if let chatIDValue = args["chat_id"] {
            guard let chatIDRaw = chatIDValue.stringValue else {
                throw MCPError.invalidParams("chat_id must be a string")
            }
            guard !chatIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("chat_id cannot be empty when provided")
            }
        }
        if let newChatValue = args["new_chat"], newChatValue.boolValue == nil {
            throw MCPError.invalidParams("new_chat must be a boolean")
        }
        let newChat = args["new_chat"]?.boolValue ?? false
        if newChat, args["chat_id"] != nil {
            throw MCPError.invalidParams("chat_id and new_chat:true cannot be used together")
        }

        for key in ["model", "chat_name"] where args[key] != nil {
            guard let value = args[key]?.stringValue else {
                throw MCPError.invalidParams("\(key) must be a string")
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("\(key) cannot be empty when provided")
            }
        }
        if args["chat_name"] != nil, !newChat {
            throw MCPError.invalidParams("chat_name is only valid with new_chat:true")
        }
    }

    private func validateNewChatModelSelection(
        newChat: Bool,
        model: String?,
        mode: String
    ) throws {
        guard newChat else { return }

        let settings = GlobalSettingsStore.shared
        let configuredPresets = ModelPresetsManager.shared.allPresets()
        let usageState = MCPModelPresetUsageState(
            showModelPresets: settings.mcpShowModelPresets(),
            temporarilyDisabled: settings.mcpTemporarilyDisablePresets(),
            configuredPresetCount: configuredPresets.count
        )

        if let model,
           let preset = Self.exactModelPresetMatch(model, in: configuredPresets),
           let message = usageState.blockedPresetMessage(for: preset)
        {
            throw MCPError.invalidParams(message)
        }

        guard model == nil, usageState.allowsConfiguredPresets else { return }

        let compatiblePresets = configuredPresets
            .filteredForMode(mode)
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                if order == .orderedSame { return $0.id.uuidString < $1.id.uuidString }
                return order == .orderedAscending
            }
        guard compatiblePresets.count > 1 else { return }

        let choices = compatiblePresets
            .map { "'\($0.name)' (\($0.id.uuidString))" }
            .joined(separator: ", ")
        throw MCPError.invalidParams(
            "new_chat:true requires an explicit model when multiple model presets support '\(mode)' mode: \(choices). Retry with model set to one exact preset name or UUID from oracle_utils op=models. chat_name only labels the Oracle session and never selects a model."
        )
    }

    private func resolveBatchModelSelector(
        _ selector: String,
        mode: String,
        index: Int
    ) throws -> String {
        try validateNewChatModelSelection(newChat: true, model: selector, mode: mode)

        let configuredPresets = ModelPresetsManager.shared.allPresets()
        let settings = GlobalSettingsStore.shared
        let usageState = MCPModelPresetUsageState(
            showModelPresets: settings.mcpShowModelPresets(),
            temporarilyDisabled: settings.mcpTemporarilyDisablePresets(),
            configuredPresetCount: configuredPresets.count
        )
        if usageState.allowsConfiguredPresets, !configuredPresets.isEmpty {
            guard let preset = Self.exactModelPresetMatch(selector, in: configuredPresets) else {
                throw MCPError.invalidParams(
                    "consultations[\(index)].model must exactly match one configured preset UUID or unambiguous name from oracle_utils op=models"
                )
            }
            guard configuredPresets.filteredForMode(mode).contains(where: { $0.id == preset.id }) else {
                throw MCPError.invalidParams(
                    "consultations[\(index)].model preset '\(preset.name)' does not support '\(mode)' mode"
                )
            }
            return preset.id.uuidString
        }

        let planningResolution = promptVM.mcpOraclePlanningModelResolution()
        guard case let .configured(planningModel) = planningResolution else {
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: planningResolution,
                availabilityGuidance: { model in oracleModelAvailabilityGuidance(for: model) }
            ) ?? "MCP Oracle model is not configured."
            throw MCPError.invalidParams(message)
        }
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.caseInsensitiveCompare("current_chat_model") == .orderedSame
            || normalized.caseInsensitiveCompare(planningModel.displayName) == .orderedSame
        else {
            throw MCPError.invalidParams(
                "consultations[\(index)].model must be 'current_chat_model' or '\(planningModel.displayName)' while model presets are unavailable"
            )
        }
        return "current_chat_model"
    }

    private static func exactModelPresetMatch(
        _ selector: String,
        in presets: [ModelPreset]
    ) -> ModelPreset? {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: normalized) {
            return presets.first { $0.id == id }
        }
        let matches = presets.filter {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func oracleModelAvailabilityGuidance(for model: AIModel) -> String {
        switch model.providerType {
        case .claudeCode:
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
                return "Configure and enable \(descriptor.groupDisplayName) in Settings."
            }
            return "Connect Claude Code in Settings."
        default:
            return "Please check that the \(model.providerType.displayName) API key is configured in Settings."
        }
    }

    private func executeOracleModelsUtility() async throws -> Value {
        let (showModelPresets, temporarilyDisabled) = await MainActor.run {
            let store = GlobalSettingsStore.shared
            return (store.mcpShowModelPresets(), store.mcpTemporarilyDisablePresets())
        }
        let configuredPresets = ModelPresetsManager.shared.allPresets()
        let usageState = MCPModelPresetUsageState(
            showModelPresets: showModelPresets,
            temporarilyDisabled: temporarilyDisabled,
            configuredPresetCount: configuredPresets.count
        )

        var models: [ToolResultDTOs.ModelInfo] = []

        func supportedModes(for preset: ModelPreset) -> ToolResultDTOs.SupportedModesInfo {
            if let modes = preset.supportedModes {
                return ToolResultDTOs.SupportedModesInfo(
                    chat: modes.chat,
                    plan: modes.plan,
                    review: modes.review
                )
            }
            return ToolResultDTOs.SupportedModesInfo(chat: true, plan: true, review: true)
        }

        if usageState.allowsConfiguredPresets {
            for preset in configuredPresets {
                let capabilities = preset.optionalModel.map(AIModelCapabilityMetadata.resolve) ?? .empty
                models.append(ToolResultDTOs.ModelInfo(
                    id: preset.id.uuidString,
                    name: preset.name,
                    description: nil,
                    supportedModes: supportedModes(for: preset),
                    contextWindow: capabilities.contextWindowTokens,
                    maxOutputTokens: capabilities.maxOutputTokens
                ))
            }
        } else {
            try models.append(defaultCurrentChatModelInfo())
        }

        let notes = Self.modelPresetDiagnosticLines(
            usageState: usageState,
            configuredPresets: configuredPresets
        )
        return try Value(ToolResultDTOs.ListModelsReply(
            models: models,
            total: models.count,
            notes: notes.isEmpty ? nil : notes
        ))
    }

    static func modelPresetDiagnosticLines(
        usageState: MCPModelPresetUsageState,
        configuredPresets: [ModelPreset]
    ) -> [String] {
        guard usageState == .disabledByToggle || usageState == .temporarilyHidden else {
            return []
        }

        func modes(for preset: ModelPreset) -> String {
            let supported = preset.supportedModes ?? SupportedModes()
            var items: [String] = []
            if supported.chat { items.append("Chat") }
            if supported.plan { items.append("Plan") }
            if supported.review { items.append("Review") }
            return "[\(items.joined(separator: ", "))]"
        }

        var lines = [""]
        if usageState == .disabledByToggle {
            lines.append("Model preset state: disabled for MCP")
        } else {
            lines.append("Model preset state: temporarily hidden by Setup Wizard")
        }
        lines.append("Configured presets — NOT selectable in this state:")
        for preset in configuredPresets {
            lines.append("- \(preset.id.uuidString): \(preset.name) — modes: \(modes(for: preset))")
        }
        if usageState == .disabledByToggle {
            lines.append(
                "Enable \"Use Oracle Model Presets for MCP\" in Settings → MCP, then call oracle_utils op=models again. Do not pass these presets to ask_oracle until enabled."
            )
        } else {
            lines.append(
                "Choose \"Show presets\" in Settings → MCP, then call oracle_utils op=models again. Do not pass these presets to ask_oracle until they are shown."
            )
        }
        return lines
    }

    private func defaultCurrentChatModelInfo() throws -> ToolResultDTOs.ModelInfo {
        let resolution = promptVM.mcpOraclePlanningModelResolution()
        guard case let .configured(effectiveModel) = resolution else {
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: resolution,
                availabilityGuidance: { model in oracleModelAvailabilityGuidance(for: model) }
            ) ?? "MCP Oracle model is not configured."
            throw MCPError.invalidParams(message)
        }
        return ToolResultDTOs.ModelInfo(
            id: "current_chat_model",
            name: effectiveModel.displayName,
            description: "MCP Oracle Model",
            supportedModes: ToolResultDTOs.SupportedModesInfo(chat: true, plan: true, review: true),
            contextWindow: AIModelCapabilityMetadata.contextWindowTokens(for: effectiveModel),
            maxOutputTokens: effectiveModel.maxTokens
        )
    }

    private func executeLiveOracleSessions(args: [String: Value]) async throws -> Value {
        let allowedArgs: Set = ["limit", "scope", "context_id"]
        let unsupported = args.keys.filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_utils op='sessions' only accepts limit, scope, and context_id. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }
        if let limitValue = args["limit"], limitValue.intValue == nil {
            throw MCPError.invalidParams("limit must be an integer")
        }
        if let contextIDValue = args["context_id"]?.stringValue {
            let trimmed = contextIDValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw MCPError.invalidParams("context_id cannot be empty when provided")
            }
            if UUID(uuidString: trimmed) == nil {
                throw MCPError.invalidParams("context_id must be a valid UUID. Use bind_context op=list to discover context_id values.")
            }
        }
        var listArgs: [String: Value] = [:]
        if let limit = args["limit"] {
            listArgs["limit"] = limit
        }
        if let scope = args["scope"] {
            listArgs["scope"] = scope
        }
        if let contextID = args["context_id"] {
            listArgs["tab_id"] = contextID
        }
        var result = try await oracleVM.tool_chatList(args: listArgs)
        result["action"] = .string("list")
        return .object(result)
    }

    private struct AgentOracleOwner {
        let agentSessionID: UUID?
        let runID: UUID?
        let worktreeBindingState: AgentSessionWorktreeBindingState
    }

    private func resolveAgentOracleOwner(
        tabID: UUID,
        targetWindow: WindowState,
        tabContext: TabScopedContext?
    ) async -> AgentOracleOwner {
        let agentModeViewModel = targetWindow.agentModeViewModel
        let storedSessionID = tabContext?.activeAgentSessionID
            ?? targetWindow.workspaceManager.composeTab(with: tabID)?.activeAgentSessionID
            ?? agentModeViewModel.session(for: tabID, createIfNeeded: false)?.activeAgentSessionID
        guard let storedSessionID else {
            return AgentOracleOwner(
                agentSessionID: nil,
                runID: tabContext?.runID,
                worktreeBindingState: .notApplicable
            )
        }

        let hydratedSession = await agentModeViewModel.ensureSessionReady(tabID: tabID)
        guard hydratedSession.activeAgentSessionID == storedSessionID else {
            return AgentOracleOwner(
                agentSessionID: storedSessionID,
                runID: tabContext?.runID ?? hydratedSession.runID,
                worktreeBindingState: .unavailable
            )
        }
        return AgentOracleOwner(
            agentSessionID: storedSessionID,
            runID: tabContext?.runID ?? hydratedSession.runID,
            worktreeBindingState: agentModeViewModel.worktreeBindingState(
                forAgentSessionID: storedSessionID,
                tabID: tabID
            )
        )
    }

    private func oraclePackagingLookupContext(for context: TabScopedContext) async throws -> WorkspaceLookupContext {
        if let frozenLookupContext = context.frozenLookupContext {
            return frozenLookupContext
        }
        return try await requiredOracleLookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: context.activeAgentSessionID,
                worktreeBindingState: context.worktreeBindingState
            )
        )
    }

    private func oraclePackagingLookupContext(owner: AgentOracleOwner) async throws -> WorkspaceLookupContext {
        try await requiredOracleLookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: owner.agentSessionID,
                worktreeBindingState: owner.worktreeBindingState
            )
        )
    }

    private func requiredOracleLookupContext(
        source: AgentWorkspaceLookupContextSource
    ) async throws -> WorkspaceLookupContext {
        do {
            return try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: source,
                store: promptVM.workspaceFileContextStore
            )
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    private func oracleSendTabContext(
        from context: TabScopedContext,
        owner: AgentOracleOwner = AgentOracleOwner(
            agentSessionID: nil,
            runID: nil,
            worktreeBindingState: .notApplicable
        ),
        origin: OracleSendOrigin,
        mode: String
    ) async throws -> OracleViewModel.OracleSendTabContext {
        let stabilizedContext = await stabilizedVirtualContext(context)
        let lookupContext = try await oraclePackagingLookupContext(for: stabilizedContext)
        let reviewGitContext = await promptVM.freezePromptGitReviewContext(
            workspaceID: stabilizedContext.workspaceID,
            tabID: stabilizedContext.tabID,
            sessionID: owner.agentSessionID,
            bindings: owner.worktreeBindingState.bindings ?? stabilizedContext.worktreeBindings,
            base: "HEAD"
        )
        let directPackaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilizedContext.tabID,
            sourceWorkspaceID: stabilizedContext.workspaceID,
            sourceSelectionRevision: stabilizedContext.selectionRevision,
            sourceAgentSessionID: owner.agentSessionID,
            sourceAgentRunID: owner.runID,
            promptText: stabilizedContext.promptText,
            selection: stabilizedContext.selection,
            lookupContext: lookupContext,
            reviewGitContext: reviewGitContext,
            provenance: .direct
        )
        let packaging = try await reviewPackaging(
            mode: mode,
            conversationTabID: stabilizedContext.tabID,
            conversationWorkspaceID: stabilizedContext.workspaceID,
            owner: owner,
            direct: directPackaging
        )
        return OracleViewModel.OracleSendTabContext(
            tabID: stabilizedContext.tabID,
            workspaceID: stabilizedContext.workspaceID,
            origin: origin,
            agentModeSessionID: owner.agentSessionID,
            agentModeRunID: owner.runID,
            packaging: packaging
        )
    }

    private func reviewPackaging(
        mode: String,
        conversationTabID: UUID,
        conversationWorkspaceID: UUID?,
        owner: AgentOracleOwner,
        direct: OracleViewModel.OracleSendPackagingContext
    ) async throws -> OracleViewModel.OracleSendPackagingContext {
        guard mode == "review" else { return direct }
        guard let delegated = try await resolveDelegatedReviewPackaging(
            conversationTabID,
            conversationWorkspaceID,
            owner.agentSessionID,
            owner.runID
        ) else {
            return direct
        }
        guard owner.agentSessionID != nil, owner.runID != nil else {
            throw MCPError.invalidParams(
                "Delegated Oracle review packaging requires an exact Agent Mode session and run"
            )
        }
        guard delegated.sourceWorkspaceID == conversationWorkspaceID else {
            throw MCPError.invalidParams(
                "Delegated Oracle review packaging belongs to a different workspace"
            )
        }
        guard case .delegated = delegated.provenance else {
            throw MCPError.internalError(
                "Delegated Oracle review packaging is missing delegation provenance"
            )
        }
        return delegated
    }
}
