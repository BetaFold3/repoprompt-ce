import Foundation
import RepoPromptRemoteWire

struct RemoteHostAgentCatalog: Codable, Equatable {
    static let hostDefaultModelID = "__remote_host_default__"
    static let hostDefaultDisplayName = "Host default"

    var agents: [RemoteHostAgent]
    var taskLabels: [RemoteHostTaskLabel]
    var isDegraded: Bool

    init(
        agents: [RemoteHostAgent],
        taskLabels: [RemoteHostTaskLabel] = [],
        isDegraded: Bool = false
    ) {
        self.agents = agents
        self.taskLabels = taskLabels
        self.isDegraded = isDegraded
    }

    enum CodingKeys: String, CodingKey {
        case agents
        case taskLabels = "task_labels"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decodeIfPresent([RemoteHostAgent].self, forKey: .agents) ?? []
        taskLabels = try container.decodeIfPresent([RemoteHostTaskLabel].self, forKey: .taskLabels) ?? []
        isDegraded = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agents, forKey: .agents)
        try container.encode(taskLabels, forKey: .taskLabels)
    }

    static let degraded = RemoteHostAgentCatalog(
        agents: [RemoteHostAgent.hostDefault],
        taskLabels: [],
        isDegraded: true
    )

    var selectableAgents: [RemoteHostAgent] {
        guard !isDegraded else { return [] }
        return agents.filter { $0.available && !$0.models.isEmpty }
    }

    func displayName(forModelID rawModelID: String?) -> String {
        guard let rawModelID,
              !rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawModelID != Self.hostDefaultModelID
        else {
            return Self.hostDefaultDisplayName
        }
        if let model = agents.lazy.flatMap(\.models).first(where: { $0.modelID == rawModelID }) {
            return model.name
        }
        if let taskLabel = taskLabels.first(where: { $0.modelID == rawModelID }) {
            return taskLabel.name
        }
        return rawModelID
    }

    func reasoningEffort(forModelID rawModelID: String?) -> String? {
        guard let rawModelID else { return nil }
        return agents.lazy.flatMap(\.models).first(where: { $0.modelID == rawModelID })?.reasoningEffort
    }

    static func modelIDForStart(_ rawModelID: String?) -> String? {
        guard let rawModelID else { return nil }
        let trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != hostDefaultModelID else { return nil }
        return trimmed
    }

    static func agentKind(forModelID rawModelID: String?) -> AgentProviderKind? {
        guard let rawModelID,
              let prefix = rawModelID.split(separator: ":", maxSplits: 1).first
        else { return nil }
        return AgentProviderKind(rawValue: String(prefix))
    }
}

struct RemoteHostAgent: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var available: Bool
    var defaultModelID: String?
    var models: [RemoteHostModel]
    var capabilities: [String]

    init(
        name: String,
        available: Bool = true,
        defaultModelID: String? = nil,
        models: [RemoteHostModel],
        capabilities: [String] = []
    ) {
        self.name = name
        self.available = available
        self.defaultModelID = defaultModelID
        self.models = models
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case name
        case available
        case defaultModelID = "default_model_id"
        case models
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
        models = try container.decodeIfPresent([RemoteHostModel].self, forKey: .models) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    static let hostDefault = RemoteHostAgent(
        name: RemoteHostAgentCatalog.hostDefaultDisplayName,
        available: true,
        defaultModelID: RemoteHostAgentCatalog.hostDefaultModelID,
        models: [
            RemoteHostModel(
                modelID: RemoteHostAgentCatalog.hostDefaultModelID,
                name: RemoteHostAgentCatalog.hostDefaultDisplayName,
                reasoningEffort: nil
            )
        ]
    )
}

struct RemoteHostModel: Codable, Equatable, Identifiable {
    var id: String {
        modelID
    }

    var modelID: String
    var name: String
    var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case name
        case reasoningEffort = "reasoning_effort"
    }
}

struct RemoteHostTaskLabel: Codable, Equatable, Identifiable {
    var id: String {
        label
    }

    var label: String
    var modelID: String
    var name: String
    var description: String?
    var recommendedModelID: String?
    var recommendedName: String?
    var hasCustomOverride: Bool?
    var overrideUnavailable: Bool?

    enum CodingKeys: String, CodingKey {
        case label
        case modelID = "model_id"
        case name
        case description
        case recommendedModelID = "recommended_model_id"
        case recommendedName = "recommended_name"
        case hasCustomOverride = "has_custom_override"
        case overrideUnavailable = "override_unavailable"
    }
}

@MainActor
final class RemoteHostCatalog {
    static let shared = RemoteHostCatalog()

    private struct CacheEntry {
        var catalog: RemoteHostAgentCatalog
        var loadedAt: Date
    }

    private let connectionManagerProvider: @MainActor () -> RemoteHostConnectionManager
    private let now: () -> Date
    private var cache: [String: CacheEntry] = [:]

    init(
        connectionManagerProvider: @escaping @MainActor () -> RemoteHostConnectionManager = { RemoteHostConnectionManager.shared },
        now: @escaping () -> Date = { Date() }
    ) {
        self.connectionManagerProvider = connectionManagerProvider
        self.now = now
    }

    func cachedCatalog(for hostID: String) -> RemoteHostAgentCatalog? {
        cache[hostID]?.catalog
    }

    func invalidate(hostID: String) {
        cache.removeValue(forKey: hostID)
    }

    func catalog(for hostID: String) async -> RemoteHostAgentCatalog {
        if let cached = cache[hostID]?.catalog {
            return cached
        }
        let catalog = await loadCatalog(for: hostID)
        cache[hostID] = CacheEntry(catalog: catalog, loadedAt: now())
        return catalog
    }

    private func loadCatalog(for hostID: String) async -> RemoteHostAgentCatalog {
        do {
            let connection = try connectionManagerProvider().connection(for: hostID)
            guard try await connection.supportsAgentCatalog() else {
                return .degraded
            }
            let response = try await connection.command(
                RemoteClientFrame(
                    type: "list_agents",
                    requestID: Self.makeRequestID(),
                    payload: .object([:])
                ),
                timeout: 10
            )
            let data = try JSONEncoder().encode(response)
            return try JSONDecoder().decode(RemoteHostAgentCatalog.self, from: data)
        } catch {
            return .degraded
        }
    }

    private static func makeRequestID() -> String {
        "list_agents-\(UUID().uuidString.lowercased())"
    }
}
