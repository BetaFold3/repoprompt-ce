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

    /// Matches `OracleViewModel.maxConcurrentMCPOracleStreamsPerTab`.
    private static let batchMaxConcurrentStreams = 2

    private static let singleAskOracleArgs: Set<String> = [
        "message", "mode", "chat_id", "new_chat", "model", "chat_name",
        "export_response", "selection_mode", "slices", "max_output_tokens", "response_mode"
    ]

    private static let batchAskOracleArgs: Set<String> = [
        "consultations", "require_distinct"
    ]

    func executeAskOracle(args: [String: Value]) async throws -> Value {
        let hasConsultations = args["consultations"] != nil
        if hasConsultations {
            return try await executeAskOracleBatch(args: args)
        }
        return try await executeAskOracleSingle(args: args)
    }

    private func executeAskOracleSingle(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.singleAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle only accepts: message, mode, chat_id, new_chat, model, chat_name, export_response, selection_mode, slices, max_output_tokens, response_mode. Unsupported args: \(unsupported.joined(separator: ", ")). For multiple independent lanes use consultations."
            )
        }

        try validateCommonOracleArgs(args)
        if let responseModeValue = args["response_mode"], responseModeValue.stringValue == nil {
            throw MCPError.invalidParams("response_mode must be a string")
        }
        let responseMode = try OracleResponseMode.parse(args["response_mode"]?.stringValue)

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        await sendStageProgress(connectionID, askOracleToolName, "starting", "Starting Oracle...")
        var result = try await withHeartbeat(
            connectionID,
            askOracleToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            try await performAskOracleSend(args: args, connectionID: connectionID)
        }

        try await finalizeAskOracleResult(
            &result,
            args: args,
            responseMode: responseMode,
            exportResponse: parseExportResponseFlag(args)
        )

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle complete")
        return Self.agentFacingOracleResult(.object(result))
    }

    private func executeAskOracleBatch(args: [String: Value]) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.batchAskOracleArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle consultations is mutually exclusive with single-send parameters. Unsupported args with consultations: \(unsupported.joined(separator: ", ")). Allowed batch args: consultations, require_distinct."
            )
        }

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        guard let consultationsValue = args["consultations"],
              let consultationItems = consultationsValue.arrayValue
        else {
            throw MCPError.invalidParams("consultations must be a non-empty array")
        }
        guard !consultationItems.isEmpty else {
            throw MCPError.invalidParams("consultations must be a non-empty array")
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

        // Fail closed before any lane spends money or creates chats.
        if requireDistinct {
            try validateDistinctConsultationPresets(parsedItems)
        }

        await sendStageProgress(
            connectionID,
            askOracleToolName,
            "starting",
            "Starting \(parsedItems.count) Oracle consultations..."
        )

        let capturedItems = parsedItems
        let maxConcurrent = Self.batchMaxConcurrentStreams
        let envelope = try await withHeartbeat(
            connectionID,
            askOracleToolName,
            "waiting",
            "Waiting for Oracle consultations..."
        ) {
            let collected = try await withThrowingTaskGroup(of: (Int, Value).self) { group in
                var nextIndex = 0
                var inFlight = 0
                var collected = Array(repeating: Value.null, count: capturedItems.count)

                func startNextIfPossible() {
                    while inFlight < maxConcurrent, nextIndex < capturedItems.count {
                        let index = nextIndex
                        let item = capturedItems[index]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask { @MainActor in
                            let value = await executeConsultationItem(
                                item,
                                index: index,
                                connectionID: connectionID
                            )
                            return (index, value)
                        }
                    }
                }

                startNextIfPossible()
                while inFlight > 0 {
                    let (index, value) = try await group.next()!
                    collected[index] = value
                    inFlight -= 1
                    startNextIfPossible()
                }
                return collected
            }
            return ["results": .array(collected)]
        }

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle consultations complete")
        return Self.agentFacingOracleResult(.object(envelope))
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
        let model = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
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
        try validateNewChatModelSelection(newChat: true, model: model, mode: modeRaw)

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

    private func executeConsultationItem(
        _ item: AskOracleConsultationItem,
        index: Int,
        connectionID: UUID
    ) async -> Value {
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

        do {
            var result = try await performAskOracleSend(args: itemArgs, connectionID: connectionID)
            try await finalizeAskOracleResult(
                &result,
                args: itemArgs,
                responseMode: item.responseMode,
                exportResponse: false
            )
            result["ok"] = .bool(true)
            result["index"] = .int(index)
            return .object(result)
        } catch let error as ChatToolError {
            var payload = error.toMCPValue().objectValue ?? [:]
            payload["ok"] = .bool(false)
            payload["index"] = .int(index)
            return .object(payload)
        } catch {
            return .object([
                "ok": .bool(false),
                "index": .int(index),
                "error": .object([
                    "code": .string(ChatToolErrorCode.invalidParams.rawValue),
                    "message": .string(error.localizedDescription)
                ])
            ])
        }
    }

    private func finalizeAskOracleResult(
        _ result: inout [String: Value],
        args: [String: Value],
        responseMode: OracleResponseMode,
        exportResponse: Bool
    ) async throws {
        let modeRaw = args["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        let message = (args["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chatID = result["chat_id"]?.stringValue
            ?? args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let needsExport = exportResponse || responseMode != .full
            let exportDestination: OracleExportDestination?
            if needsExport {
                let targetWindow = try requireTargetWindow()
                let tabID = try await resolveTabIDForAgentMode(
                    args,
                    ServerNetworkManager.currentConnectionID
                )
                let requestContext = try? await requireCurrentTabContext(askOracleToolName)
                let owner = await resolveAgentOracleOwner(
                    tabID: tabID,
                    targetWindow: targetWindow,
                    tabContext: (requestContext?.tabID == tabID) ? requestContext : nil
                )
                let lookupContext = await (try? oraclePackagingLookupContext(owner: owner))
                    ?? .visibleWorkspace
                exportDestination = try MCPServerViewModel.makeOracleExportDestination(
                    workspace: targetWindow.workspaceManager.activeWorkspace,
                    windowID: targetWindow.windowID,
                    tabID: tabID,
                    lookupContext: lookupContext
                )
            } else {
                exportDestination = nil
            }

            try await OracleResponsePresentation.applyResponseMode(
                to: &result,
                mode: responseMode
            ) { response in
                try await exportOracleResponse(OracleExportRequest(
                    sourceTool: askOracleToolName,
                    mode: modeRaw,
                    message: message,
                    chatID: chatID,
                    response: response,
                    destination: exportDestination
                ))
            }

            if exportResponse, responseMode == .full, let exportDestination {
                let export = try await exportOracleResponse(OracleExportRequest(
                    sourceTool: askOracleToolName,
                    mode: modeRaw,
                    message: message,
                    chatID: chatID,
                    response: result["response"]?.stringValue,
                    destination: exportDestination
                ))
                result["oracle_export_path"] = .string(export.path)
                result["oracle_export_instruction"] = .string(export.instruction)
            }
        } catch {
            guard responseMode != .full else { throw error }
            result["response_mode"] = .string(OracleResponseMode.full.rawValue)
            result["export_failed_warning"] = .string(
                "Oracle export failed after the response completed; returning the full response inline. \(error.localizedDescription)"
            )
        }
    }

    private func performAskOracleSend(
        args: [String: Value],
        connectionID: UUID
    ) async throws -> [String: Value] {
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

        return try await sendChat(chatArgs, promptVM, tabContext)
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
