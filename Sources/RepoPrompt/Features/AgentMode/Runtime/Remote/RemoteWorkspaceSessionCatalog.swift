import Foundation
import RepoPromptRemoteWire

protocol RemoteWorkspaceSessionCatalogConnection: Sendable {
    func command(_ frame: RemoteClientFrame, timeout: TimeInterval) async throws -> JSONValue
}

extension RemoteHostConnection: RemoteWorkspaceSessionCatalogConnection {}

@MainActor
protocol RemoteWorkspaceSessionCatalogStoring: AnyObject {
    func cachedState(hostID: String, clientWorkspaceID: UUID) -> RemoteWorkspaceSessionCatalogStore.State?
    func fetch(
        hostID: String,
        clientWorkspaceID: UUID,
        workspaceName: String,
        forceRefresh: Bool
    ) async -> RemoteWorkspaceSessionCatalogStore.State
    func invalidate(hostID: String, clientWorkspaceID: UUID)
    func invalidate(hostID: String)
}

@MainActor
final class RemoteWorkspaceSessionCatalogStore: RemoteWorkspaceSessionCatalogStoring {
    static let shared = RemoteWorkspaceSessionCatalogStore()

    struct Catalog: Equatable {
        var hostWorkspaceID: String?
        var hostWorkspaceName: String?
        var sessions: [RemoteAgentSessionDescriptor]
        var fetchedAt: Date
    }

    enum State: Equatable {
        case loaded(Catalog)
        case workspaceNotOpen(message: String)
        case unsupported
        case error(String)
    }

    private struct CacheKey: Hashable {
        var hostID: String
        var clientWorkspaceID: UUID
    }

    private struct CacheEntry {
        var state: State
        var loadedAt: Date
    }

    private static let degradedEntryTTL: TimeInterval = 20
    private static let healthyEntryTTL: TimeInterval = 300

    private let connectionProvider: @MainActor (String) throws -> any RemoteWorkspaceSessionCatalogConnection
    private let now: () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]
    private var learnedHostWorkspaceIDByKey: [CacheKey: String] = [:]
    private var invalidationGenerationByHostID: [String: UInt64] = [:]

    init(
        connectionProvider: @escaping @MainActor (String) throws -> any RemoteWorkspaceSessionCatalogConnection = {
            try RemoteHostConnectionManager.shared.connection(for: $0)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.connectionProvider = connectionProvider
        self.now = now
    }

    func cachedState(hostID: String, clientWorkspaceID: UUID) -> State? {
        let key = CacheKey(hostID: hostID, clientWorkspaceID: clientWorkspaceID)
        return cachedEntry(for: key, at: now())?.state
    }

    func fetch(
        hostID: String,
        clientWorkspaceID: UUID,
        workspaceName: String,
        forceRefresh: Bool = false
    ) async -> State {
        let key = CacheKey(hostID: hostID, clientWorkspaceID: clientWorkspaceID)
        if !forceRefresh, let state = cachedEntry(for: key, at: now())?.state {
            return state
        }

        let normalizedWorkspaceName = Self.normalizedString(workspaceName) ?? workspaceName
        let generation = invalidationGenerationByHostID[hostID, default: 0]
        let state = await load(
            key: key,
            workspaceName: normalizedWorkspaceName,
            retryingWithoutLearnedID: false
        )
        if invalidationGenerationByHostID[hostID, default: 0] == generation {
            cache[key] = CacheEntry(state: state, loadedAt: now())
        }
        return state
    }

    func invalidate(hostID: String, clientWorkspaceID: UUID) {
        cache.removeValue(forKey: CacheKey(hostID: hostID, clientWorkspaceID: clientWorkspaceID))
    }

    func invalidate(hostID: String) {
        invalidationGenerationByHostID[hostID, default: 0] &+= 1
        cache = cache.filter { $0.key.hostID != hostID }
    }

    private func cachedEntry(for key: CacheKey, at date: Date) -> CacheEntry? {
        guard let entry = cache[key] else { return nil }
        let ttl = switch entry.state {
        case .loaded:
            Self.healthyEntryTTL
        case .workspaceNotOpen, .unsupported, .error:
            Self.degradedEntryTTL
        }
        guard date.timeIntervalSince(entry.loadedAt) <= ttl else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private func load(
        key: CacheKey,
        workspaceName: String,
        retryingWithoutLearnedID: Bool
    ) async -> State {
        let learnedHostWorkspaceID = retryingWithoutLearnedID ? nil : learnedHostWorkspaceIDByKey[key]
        var payload: [String: JSONValue] = [
            "workspace_name": .string(workspaceName),
            "limit": .int(500)
        ]
        if let learnedHostWorkspaceID {
            payload["workspace_id"] = .string(learnedHostWorkspaceID)
        }

        do {
            let connection = try connectionProvider(key.hostID)
            let response = try await connection.command(
                RemoteClientFrame(
                    type: "list_sessions",
                    requestID: Self.makeRequestID(),
                    payload: .object(payload)
                ),
                timeout: RemoteHostConnection.commandTimeout
            )
            let workspace = response.objectValue?["workspace"]?.objectValue
            let hostWorkspaceID = Self.normalizedString(workspace?["id"]?.stringValue)
            let hostWorkspaceName = Self.normalizedString(workspace?["name"]?.stringValue)
            if let hostWorkspaceID {
                learnedHostWorkspaceIDByKey[key] = hostWorkspaceID
            }
            return .loaded(Catalog(
                hostWorkspaceID: hostWorkspaceID,
                hostWorkspaceName: hostWorkspaceName,
                sessions: RemoteAgentSessionController.sessionDescriptors(from: response),
                fetchedAt: now()
            ))
        } catch {
            let commandError = (error as? RemoteClientError)?.commandError
            if commandError?.code == "workspace_mismatch",
               learnedHostWorkspaceID != nil,
               !retryingWithoutLearnedID
            {
                learnedHostWorkspaceIDByKey.removeValue(forKey: key)
                return await load(
                    key: key,
                    workspaceName: workspaceName,
                    retryingWithoutLearnedID: true
                )
            }
            switch commandError?.code {
            case "unsupported_payload_key":
                return .unsupported
            case "workspace_not_open":
                return .workspaceNotOpen(message: commandError?.message ?? "Workspace is not open on the host.")
            default:
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return .error(message)
            }
        }
    }

    private static func normalizedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeRequestID() -> String {
        "workspace-sessions-\(UUID().uuidString.lowercased())"
    }
}
