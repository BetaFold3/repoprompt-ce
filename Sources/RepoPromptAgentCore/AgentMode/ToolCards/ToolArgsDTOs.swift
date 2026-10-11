import Foundation

package enum ToolArgsDTOs {
    package struct ReadFileArgs: Decodable {
        package let path: String?
        let startLine: Int?
        let limit: Int?
    }

    package struct NativeReadArgs: Decodable {
        package let path: String?
        package let filePath: String?
        let offset: Int?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case path
            case filePath = "file_path"
            case offset
            case limit
        }
    }

    package struct FileSearchArgs: Decodable {
        struct Filter: Decodable {
            let paths: [String]?
        }

        package let pattern: String?
        let mode: String?
        let maxResults: Int?
        let path: String?
        let filter: Filter?

        package var scopePaths: [String] {
            if let paths = filter?.paths, !paths.isEmpty { return paths }
            if let path, !path.isEmpty { return [path] }
            return []
        }
    }

    package struct ApplyEditsArgs: Decodable {
        package let path: String?
        let search: String?
        let replace: String?
        let rewrite: String?
    }

    package struct ApplyPatchArgs: Decodable {
        package let path: String?
        package let paths: [String]?
        package let changeCount: Int?

        enum CodingKeys: String, CodingKey {
            case path
            case paths
            case changeCount = "change_count"
        }
    }

    package struct FileTreeArgs: Decodable {
        package let path: String?
        package let type: String?
        package let mode: String?
        package let maxDepth: Int?
    }

    package struct FileActionsArgs: Decodable {
        package let action: String?
        package let path: String?
        package let newPath: String?

        enum CodingKeys: String, CodingKey {
            case action
            case path
            case newPath = "new_path"
        }
    }

    package struct CodeStructureArgs: Decodable {
        package let scope: String?
        package let paths: [String]?
        let maxResults: Int?

        enum CodingKeys: String, CodingKey {
            case scope
            case paths
            case maxResults = "max_results"
        }
    }

    package struct ManageSelectionArgs: Decodable {
        package let op: String?
        let view: String?
        let mode: String?
    }

    package struct WorkspaceContextArgs: Decodable {
        package let include: [String]?
    }

    package struct PromptArgs: Decodable {
        package let op: String?
        package let path: String?
        package let text: String?
        package let preset: String?
        package let copyPreset: String?

        enum CodingKeys: String, CodingKey {
            case op
            case path
            case text
            case preset
            case copyPreset = "copy_preset"
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            preset = Self.decodeSelector(from: container, key: .preset)
            copyPreset = Self.decodeSelector(from: container, key: .copyPreset)
        }

        private static func decodeSelector(
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> String? {
            if let value = try? container.decode(String.self, forKey: key),
               !value.isEmpty
            {
                return value
            }
            if let object = try? container.decode([String: String].self, forKey: key) {
                return object["name"] ?? object["kind"] ?? object["id"]
            }
            return nil
        }
    }

    struct AskOracleArgs: Decodable {
        let message: String?
        let mode: String?
        let chatID: String?
        let newChat: Bool?
        let model: String?
        let chatName: String?

        enum CodingKeys: String, CodingKey {
            case message
            case mode
            case chatID = "chat_id"
            case newChat = "new_chat"
            case model
            case chatName = "chat_name"
        }
    }

    package struct ChatsArgs: Decodable {
        package let action: String?
        package let chatID: String?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case action
            case chatID = "chat_id"
            case limit
        }
    }

    package struct BindContextArgs: Decodable {
        package let op: String?
        package let windowID: Int?
        package let contextID: String?

        enum CodingKeys: String, CodingKey {
            case op
            case windowID = "window_id"
            case contextID = "context_id"
        }
    }

    package struct ManageWorkspacesArgs: Decodable {
        package let action: String?
        package let workspace: String?
        let name: String?
        let tab: String?
        let windowID: Int?

        enum CodingKeys: String, CodingKey {
            case action
            case workspace
            case name
            case tab
            case windowID = "window_id"
        }
    }

    package struct GitArgs: Decodable {
        package let op: String?
        package let compare: String?
        package let detail: String?
        let repoRoot: String?

        enum CodingKeys: String, CodingKey {
            case op
            case compare
            case detail
            case repoRoot = "repo_root"
        }
    }

    // MARK: - Agent Control DTOs

    package struct AgentRunArgs: Decodable {
        package let op: String?
        let message: String?
        package let sessionID: String?
        package let sessionName: String?
        package let agent: String?
        package let model: String?
        package let workflowID: String?
        package let workflowName: String?
        package let reasoningEffort: String?
        let interactionID: String?
        let response: String?
        let decision: String?
        let reason: String?
        let amendment: String?
        package let detach: Bool?
        package let timeout: Double?
        package let wait: Bool?
        package let timeoutSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case op
            case message
            case sessionID = "session_id"
            case sessionName = "session_name"
            case agent
            case model
            case workflowID = "workflow_id"
            case workflowName = "workflow_name"
            case reasoningEffort = "reasoning_effort"
            case interactionID = "interaction_id"
            case response
            case decision
            case reason
            case amendment
            case detach
            case timeout
            case wait
            case timeoutSeconds = "timeout_seconds"
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
            workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
            reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            interactionID = try container.decodeIfPresent(String.self, forKey: .interactionID)
            response = try container.decodeIfPresent(String.self, forKey: .response)
            decision = try container.decodeIfPresent(String.self, forKey: .decision)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            amendment = try container.decodeIfPresent(String.self, forKey: .amendment)
            detach = try ToolArgsDTOs.decodeBool(from: container, forKey: .detach)
            timeout = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeout)
            wait = try ToolArgsDTOs.decodeBool(from: container, forKey: .wait)
            timeoutSeconds = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeoutSeconds)
        }
    }

    package struct AgentExploreArgs: Decodable {
        package let op: String?
        let message: String?
        package let messages: [String]?
        package let sessionID: String?
        package let sessionIDs: [String]?
        package let detach: Bool?
        package let timeout: Double?

        enum CodingKeys: String, CodingKey {
            case op
            case message
            case messages
            case sessionID = "sessionId"
            case sessionIDs = "sessionIds"
            case detach
            case timeout
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            messages = try container.decodeIfPresent([String].self, forKey: .messages)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionIDs = try container.decodeIfPresent([String].self, forKey: .sessionIDs)
            detach = try ToolArgsDTOs.decodeBool(from: container, forKey: .detach)
            timeout = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeout)
        }
    }

    package struct AgentManageArgs: Decodable {
        package let op: String?
        package let sessionID: String?
        package let sessionName: String?
        package let agent: String?
        let model: String?
        let limit: Int?
        package let name: String?
        package let state: String?
        package let offset: Int?
        let rolesOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case op
            case sessionID = "session_id"
            case sessionName = "session_name"
            case agent
            case model
            case limit
            case name
            case state
            case offset
            case rolesOnly = "roles_only"
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            limit = try container.decodeIfPresent(Int.self, forKey: .limit)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            offset = try container.decodeIfPresent(Int.self, forKey: .offset)
            rolesOnly = try ToolArgsDTOs.decodeBool(from: container, forKey: .rolesOnly)
        }
    }

    private static func decodeDouble<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Double? {
        if let value = try container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decodeBool<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Bool? {
        if let value = try container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
