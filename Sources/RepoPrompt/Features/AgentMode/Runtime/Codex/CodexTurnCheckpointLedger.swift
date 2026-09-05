import Foundation

// swiftformat:disable:next redundantSendable
struct CodexTurnCheckpointLedger: Codable, Equatable, Sendable {
    var threadID: String
    var entries: [CodexTurnCheckpoint]

    init(threadID: String, entries: [CodexTurnCheckpoint] = []) {
        self.threadID = threadID
        self.entries = entries
    }

    mutating func bind(to threadID: String) {
        guard self.threadID != threadID else { return }
        self = CodexTurnCheckpointLedger(threadID: threadID)
    }

    func matching(threadID: String?) -> CodexTurnCheckpointLedger? {
        guard let threadID, self.threadID == threadID else { return nil }
        return self
    }

    mutating func record(
        turnID: UUID,
        codexTurnID: String,
        recordedAt: Date = Date()
    ) {
        let checkpoint = CodexTurnCheckpoint(
            turnID: turnID,
            codexTurnID: codexTurnID,
            status: .inProgress,
            sideEffect: nil,
            recordedAt: recordedAt
        )
        if let index = entries.firstIndex(where: { $0.turnID == turnID }) {
            if entries[index].codexTurnID == codexTurnID,
               entries[index].status == .inProgress
            {
                return
            }
            entries[index] = checkpoint
        } else {
            entries.append(checkpoint)
        }
    }

    @discardableResult
    mutating func transition(
        turnID: UUID,
        codexTurnID: String,
        to status: CodexTurnCheckpoint.Status,
        sideEffect: CodexTurnCheckpoint.SideEffect
    ) -> Bool {
        guard status != .inProgress,
              let index = entries.firstIndex(where: {
                  $0.turnID == turnID
                      && $0.codexTurnID == codexTurnID
                      && $0.status == .inProgress
              })
        else {
            return false
        }
        entries[index].status = status
        entries[index].sideEffect = sideEffect
        return true
    }

    mutating func prune(retaining turnIDs: Set<UUID>) {
        entries.removeAll { !turnIDs.contains($0.turnID) }
    }

    mutating func pruneForPersistence(
        retainedTerminalTurnIDs: Set<UUID>,
        currentUserTurnIDs: Set<UUID>
    ) {
        entries.removeAll { checkpoint in
            if checkpoint.status == .inProgress {
                return !currentUserTurnIDs.contains(checkpoint.turnID)
            }
            return !retainedTerminalTurnIDs.contains(checkpoint.turnID)
        }
    }
}

// swiftformat:disable:next redundantSendable
struct CodexTurnCheckpoint: Codable, Equatable, Sendable {
    // swiftformat:disable:next redundantSendable
    enum Status: String, Codable, Equatable, Sendable {
        case inProgress
        case completed
        case failed
        case cancelled
    }

    // swiftformat:disable:next redundantSendable
    enum SideEffect: Codable, Equatable, Sendable {
        case readOnly
        case modified(paths: [String])
        case unknown
    }

    let turnID: UUID
    let codexTurnID: String
    var status: Status
    var sideEffect: SideEffect?
    let recordedAt: Date
}

enum CodexTurnSideEffectClassifier {
    private static let readOnlyTools: Set<String> = [
        "read_file",
        "file_search",
        "get_file_tree",
        "get_code_structure",
        "workspace_context"
    ]

    static func classify(turn: AgentTranscriptTurn) -> CodexTurnCheckpoint.SideEffect {
        guard turn.retentionTier == .full, !turn.isStructurallyCompacted else { return .unknown }
        let activities = turn.responseSpans.flatMap(\.activities)
        guard !activities.contains(where: { $0.role == .toolExecution && $0.toolExecution == nil }) else {
            return .unknown
        }
        return classify(executions: activities.compactMap(\.toolExecution))
    }

    static func classify(executions: [AgentTranscriptToolExecution]) -> CodexTurnCheckpoint.SideEffect {
        var encounteredMutation = false
        var modifiedPaths: [String] = []
        for execution in executions {
            guard execution.status == .success,
                  !execution.summaryOnly,
                  execution.toolIsError != true,
                  resultEvidenceIsNonConflicting(execution.resultJSON),
                  let rawToolName = execution.toolName,
                  MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(rawToolName),
                  let toolName = MCPIntegrationHelper.canonicalRepoPromptToolName(rawToolName)
            else {
                return .unknown
            }

            if readOnlyTools.contains(toolName) {
                continue
            }
            encounteredMutation = true
            guard let paths = affirmativeModifiedPaths(for: execution, toolName: toolName),
                  !paths.isEmpty
            else {
                return .unknown
            }
            modifiedPaths.append(contentsOf: paths)
        }

        guard encounteredMutation else { return .readOnly }
        guard let normalized = normalizedUniquePaths(modifiedPaths), !normalized.isEmpty else {
            return .unknown
        }
        return .modified(paths: normalized)
    }

    private static func affirmativeModifiedPaths(
        for execution: AgentTranscriptToolExecution,
        toolName: String
    ) -> [String]? {
        guard let result = jsonObject(execution.resultJSON), resultAffirmsSuccess(result) else { return nil }
        switch toolName {
        case "apply_edits":
            guard let args = jsonObject(execution.argsJSON),
                  let path = args["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return [path]
        case "file_actions":
            guard let args = jsonObject(execution.argsJSON),
                  let action = (args["action"] as? String)?.lowercased(),
                  ["create", "delete", "move", "rename"].contains(action)
            else {
                return nil
            }
            return ["path", "new_path", "newPath", "destination", "destination_path"]
                .compactMap { args[$0] as? String }
        default:
            return nil
        }
    }

    private enum StructuredOutcome {
        case success
        case failure
    }

    private static func resultEvidenceIsNonConflicting(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let result = jsonObject(trimmed) else { return false }
        return structuredOutcomes(in: result) != nil
    }

    private static func resultAffirmsSuccess(_ result: [String: Any]) -> Bool {
        guard let outcomes = structuredOutcomes(in: result) else { return false }
        return outcomes.contains(.success)
    }

    private static func structuredOutcomes(in result: [String: Any]) -> Set<StructuredOutcome>? {
        var outcomes: Set<StructuredOutcome> = []
        for key in ["isError", "is_error"] {
            if let flag = result[key] as? Bool {
                outcomes.insert(flag ? .failure : .success)
            }
        }
        for key in ["success", "ok"] {
            if let flag = result[key] as? Bool {
                outcomes.insert(flag ? .success : .failure)
            }
        }
        for key in ["status", "outcome", "result", "state"] {
            guard let raw = result[key] as? String else { continue }
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "success", "succeeded", "completed", "complete", "ok":
                outcomes.insert(.success)
            case "error", "failed", "failure", "cancelled", "canceled", "interrupted", "incomplete":
                outcomes.insert(.failure)
            default:
                break
            }
        }
        if let exitCode = result["exitCode"] as? NSNumber
            ?? result["exit_code"] as? NSNumber
            ?? result["code"] as? NSNumber
        {
            outcomes.insert(exitCode.intValue == 0 ? .success : .failure)
        }
        if let error = result["error"], !(error is NSNull) {
            let isEmptyString = (error as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let isFalse = (error as? Bool) == false
            if !isEmptyString, !isFalse {
                outcomes.insert(.failure)
            }
        }
        guard !outcomes.contains(.failure) else { return nil }
        return outcomes
    }

    private static func jsonObject(_ raw: String?) -> [String: Any]? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func normalizedUniquePaths(_ paths: [String]) -> [String]? {
        var seen: Set<String> = []
        var normalizedPaths: [String] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let slashPath = trimmed.replacingOccurrences(of: "\\", with: "/")
            let isAbsolute = slashPath.hasPrefix("/")
            var components: [Substring] = []
            for component in slashPath.split(separator: "/") {
                if component == "." { continue }
                if component == "..", components.last != ".." {
                    if !components.isEmpty {
                        components.removeLast()
                    } else if !isAbsolute {
                        components.append(component)
                    }
                    continue
                }
                components.append(component)
            }
            let body = components.joined(separator: "/")
            let normalized = isAbsolute ? "/" + body : body
            guard !normalized.isEmpty else { return nil }
            if seen.insert(normalized).inserted {
                normalizedPaths.append(normalized)
            }
        }
        return normalizedPaths
    }
}
