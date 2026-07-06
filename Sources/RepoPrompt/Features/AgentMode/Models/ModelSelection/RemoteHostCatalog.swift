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

    /// True only when the host sent the structured per-model fields needed to
    /// mirror the local CLI → model → effort picker. Older hosts are decoded and
    /// rendered through the legacy flat per-agent submenu instead.
    var supportsStructuredModelGroups: Bool {
        let models = selectableAgents.flatMap(\.models)
        return !models.isEmpty && models.allSatisfy(\.hasStructuredModelMetadata)
    }

    var structuredAgentGroups: [RemoteHostAgentModelGroup] {
        guard supportsStructuredModelGroups else { return [] }
        return selectableAgents.compactMap { agent -> RemoteHostAgentModelGroup? in
            var orderedBaseKeys: [String] = []
            var groupedModels: [String: [RemoteHostModel]] = [:]

            for model in agent.models {
                guard let baseModelID = model.normalizedBaseModelID,
                      model.normalizedModelDisplayName != nil
                else {
                    continue
                }
                let key = Self.groupKey(agentID: model.normalizedAgentID, agentName: agent.name, baseModelID: baseModelID)
                if groupedModels[key] == nil {
                    orderedBaseKeys.append(key)
                }
                groupedModels[key, default: []].append(model)
            }

            let modelGroups = orderedBaseKeys.compactMap { key -> RemoteHostBaseModelGroup? in
                guard let models = groupedModels[key],
                      let first = models.first,
                      let baseModelID = first.normalizedBaseModelID,
                      let displayName = first.normalizedModelDisplayName
                else {
                    return nil
                }
                let options = models.map { model in
                    RemoteHostEffortOption(
                        modelID: model.modelID,
                        effort: model.normalizedEffort,
                        displayName: model.normalizedEffortDisplayName ?? Self.displayName(forEffort: model.normalizedEffort),
                        isDefault: model.isDefault
                    )
                }
                return RemoteHostBaseModelGroup(
                    agentID: first.normalizedAgentID,
                    agentName: agent.name,
                    baseModelID: baseModelID,
                    displayName: displayName,
                    options: options
                )
            }

            guard !modelGroups.isEmpty else { return nil }
            return RemoteHostAgentModelGroup(
                agentID: modelGroups.first?.agentID,
                name: agent.name,
                models: modelGroups
            )
        }
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
        // Role labels (explore/engineer/pair/design) are host-portable start
        // selectors resolved on the host at start time.
        if let taskLabel = taskLabels.first(where: { $0.label == rawModelID }) {
            return taskLabel.name
        }
        if let taskLabel = taskLabels.first(where: { $0.modelID == rawModelID }) {
            return taskLabel.name
        }
        return rawModelID
    }

    func chipTitle(forModelID rawModelID: String?) -> String {
        guard let rawModelID,
              !rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawModelID != Self.hostDefaultModelID
        else {
            return "Remote · \(Self.hostDefaultDisplayName)"
        }
        if let group = selectedBaseModelGroup(forModelID: rawModelID) {
            return "\(group.agentName) · \(group.displayName)"
        }
        return "Remote · \(displayName(forModelID: rawModelID))"
    }

    func selectedBaseModelGroup(forModelID rawModelID: String?) -> RemoteHostBaseModelGroup? {
        guard let rawModelID else { return nil }
        let trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return structuredAgentGroups.lazy.flatMap(\.models).first { $0.containsModelID(trimmed) }
    }

    func effortOptions(forModelID rawModelID: String?) -> [RemoteHostEffortOption] {
        guard let group = selectedBaseModelGroup(forModelID: rawModelID),
              group.hasEffortVariants
        else {
            return []
        }
        return group.effortOptions
    }

    func selectedEffortOption(forModelID rawModelID: String?) -> RemoteHostEffortOption? {
        guard let rawModelID,
              let group = selectedBaseModelGroup(forModelID: rawModelID)
        else {
            return nil
        }
        let trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.options.first { $0.modelID == trimmed }
    }

    func modelID(forEffort effortRaw: String, selectedModelID rawModelID: String?) -> String? {
        guard let group = selectedBaseModelGroup(forModelID: rawModelID) else { return nil }
        return group.modelID(forEffort: effortRaw)
    }

    func reasoningEffort(forModelID rawModelID: String?) -> String? {
        guard let rawModelID else { return nil }
        return agents.lazy.flatMap(\.models).first(where: { $0.modelID == rawModelID })?.normalizedEffort
    }

    func effortDisplayName(forModelID rawModelID: String?) -> String? {
        guard let effort = reasoningEffort(forModelID: rawModelID) else { return nil }
        return Self.displayName(forEffort: effort)
    }

    static func modelIDForStart(_ rawModelID: String?) -> String? {
        guard let rawModelID else { return nil }
        let trimmed = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != hostDefaultModelID else { return nil }
        if agentKind(forModelID: trimmed) != nil {
            return trimmed
        }
        if AgentModelCatalog.TaskLabelKind.allCases.contains(where: { $0.rawValue == trimmed }) {
            return trimmed
        }
        return nil
    }

    static func agentKind(forModelID rawModelID: String?) -> AgentProviderKind? {
        guard let rawModelID,
              let prefix = rawModelID.split(separator: ":", maxSplits: 1).first
        else { return nil }
        return AgentProviderKind(rawValue: String(prefix))
    }

    static func displayName(forEffort rawEffort: String?) -> String {
        guard let rawEffort = rawEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEffort.isEmpty
        else {
            return "Default"
        }
        if let effort = CodexReasoningEffort.parse(rawEffort) {
            return effort.displayName
        }
        if let effort = ClaudeCodeEffortLevel.parse(rawEffort) {
            return effort.displayName
        }
        return rawEffort
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(\.capitalized)
            .joined(separator: " ")
    }

    private static func groupKey(agentID: String?, agentName: String, baseModelID: String) -> String {
        let agentKey = agentID ?? agentName
        return "\(agentKey.lowercased())/\(baseModelID.lowercased())"
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
    var agentID: String?
    var baseModelID: String?
    var effort: String?
    var modelDisplayName: String?
    var effortDisplayName: String?
    var isDefault: Bool

    init(
        modelID: String,
        name: String,
        reasoningEffort: String? = nil,
        agentID: String? = nil,
        baseModelID: String? = nil,
        effort: String? = nil,
        modelDisplayName: String? = nil,
        effortDisplayName: String? = nil,
        isDefault: Bool = false
    ) {
        self.modelID = modelID
        self.name = name
        self.reasoningEffort = reasoningEffort
        self.agentID = agentID
        self.baseModelID = baseModelID
        self.effort = effort
        self.modelDisplayName = modelDisplayName
        self.effortDisplayName = effortDisplayName
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case name
        case reasoningEffort = "reasoning_effort"
        case agentID = "agent_id"
        case baseModelID = "base_model_id"
        case effort
        case modelDisplayName = "model_display_name"
        case effortDisplayName = "effort_display_name"
        case isDefault = "is_default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        name = try container.decode(String.self, forKey: .name)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        baseModelID = try container.decodeIfPresent(String.self, forKey: .baseModelID)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        modelDisplayName = try container.decodeIfPresent(String.self, forKey: .modelDisplayName)
        effortDisplayName = try container.decodeIfPresent(String.self, forKey: .effortDisplayName)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    var normalizedAgentID: String? {
        normalizedString(agentID)
    }

    var normalizedBaseModelID: String? {
        normalizedString(baseModelID)
    }

    var normalizedEffort: String? {
        normalizedString(effort) ?? normalizedString(reasoningEffort)
    }

    var normalizedModelDisplayName: String? {
        normalizedString(modelDisplayName)
    }

    var normalizedEffortDisplayName: String? {
        normalizedString(effortDisplayName)
    }

    var hasStructuredModelMetadata: Bool {
        normalizedAgentID != nil
            && normalizedBaseModelID != nil
            && normalizedModelDisplayName != nil
    }

    private func normalizedString(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RemoteHostAgentModelGroup: Equatable, Identifiable {
    var id: String {
        (agentID ?? name).lowercased()
    }

    var agentKind: AgentProviderKind? {
        agentID.flatMap(AgentProviderKind.init(rawValue:))
    }

    var agentID: String?
    var name: String
    var models: [RemoteHostBaseModelGroup]
}

struct RemoteHostBaseModelGroup: Equatable, Identifiable {
    var id: String {
        let agentKey = agentID ?? agentName
        return "\(agentKey.lowercased())/\(baseModelID.lowercased())"
    }

    var agentID: String?
    var agentName: String
    var baseModelID: String
    var displayName: String
    var options: [RemoteHostEffortOption]

    var preferredOption: RemoteHostEffortOption? {
        if let hostDefault = options.first(where: \.isDefault) {
            return hostDefault
        }
        for effort in Self.fallbackEffortPreferenceOrder {
            if let option = options.first(where: { $0.effort?.caseInsensitiveCompare(effort) == .orderedSame }) {
                return option
            }
        }
        return options.first
    }

    var preferredModelID: String? {
        preferredOption?.modelID
    }

    var effortOptions: [RemoteHostEffortOption] {
        options.filter { $0.effort != nil }
    }

    var hasEffortVariants: Bool {
        Set(effortOptions.compactMap { $0.effort?.lowercased() }).count > 1
    }

    func containsModelID(_ rawModelID: String) -> Bool {
        options.contains { $0.modelID == rawModelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func modelID(forEffort effortRaw: String) -> String? {
        let trimmed = effortRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return options.first { $0.effort?.caseInsensitiveCompare(trimmed) == .orderedSame }?.modelID
    }

    private static let fallbackEffortPreferenceOrder = [
        "medium",
        "high",
        "low",
        "xhigh",
        "max",
        "minimal",
        "none"
    ]
}

struct RemoteHostEffortOption: Equatable, Identifiable {
    var id: String {
        modelID
    }

    var modelID: String
    var effort: String?
    var displayName: String
    var isDefault: Bool
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

    private static let degradedEntryTTL: TimeInterval = 20
    private static let healthyEntryTTL: TimeInterval = 300

    private struct CacheEntry {
        var catalog: RemoteHostAgentCatalog
        var loadedAt: Date
    }

    private let connectionManagerProvider: @MainActor () -> RemoteHostConnectionManager
    private let now: () -> Date
    private let catalogLoader: (@MainActor (String) async -> RemoteHostAgentCatalog)?
    private var cache: [String: CacheEntry] = [:]

    init(
        connectionManagerProvider: @escaping @MainActor () -> RemoteHostConnectionManager = { RemoteHostConnectionManager.shared },
        now: @escaping () -> Date = { Date() },
        catalogLoader: (@MainActor (String) async -> RemoteHostAgentCatalog)? = nil
    ) {
        self.connectionManagerProvider = connectionManagerProvider
        self.now = now
        self.catalogLoader = catalogLoader
    }

    func cachedCatalog(for hostID: String) -> RemoteHostAgentCatalog? {
        cachedEntry(for: hostID, at: now())?.catalog
    }

    func invalidate(hostID: String) {
        cache.removeValue(forKey: hostID)
    }

    func catalog(for hostID: String) async -> RemoteHostAgentCatalog {
        if let cached = cachedEntry(for: hostID, at: now())?.catalog {
            return cached
        }
        let catalog = await loadCatalog(for: hostID)
        guard !Task.isCancelled else { return catalog }
        cache[hostID] = CacheEntry(catalog: catalog, loadedAt: now())
        return catalog
    }

    private func cachedEntry(for hostID: String, at date: Date) -> CacheEntry? {
        guard let entry = cache[hostID] else { return nil }
        if isExpired(entry, at: date) {
            cache.removeValue(forKey: hostID)
            return nil
        }
        return entry
    }

    private func isExpired(_ entry: CacheEntry, at date: Date) -> Bool {
        let ttl = entry.catalog.isDegraded ? Self.degradedEntryTTL : Self.healthyEntryTTL
        return date.timeIntervalSince(entry.loadedAt) > ttl
    }

    private func loadCatalog(for hostID: String) async -> RemoteHostAgentCatalog {
        if let catalogLoader {
            return await catalogLoader(hostID)
        }
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
