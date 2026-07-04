import Foundation

@MainActor
protocol RemoteHostsConnectionTesting: AnyObject {
    func testConnection(hostID: String) async throws -> RemoteHostConnectionTestResult
}

@MainActor
final class RemoteHostConnectionManager: RemoteHostsConnectionTesting {
    static let shared = RemoteHostConnectionManager()

    private let registry: RemoteHostRegistry
    private let keyStore: RemoteClientKeyStore
    private let httpTransport: any RemoteHostConnectionHTTPTransport
    private let webSocketSession: URLSession
    private let now: @Sendable () -> Date
    private var connections: [String: RemoteHostConnection] = [:]

    init(
        registry: RemoteHostRegistry = .shared,
        keyStore: RemoteClientKeyStore = .shared,
        httpTransport: any RemoteHostConnectionHTTPTransport = URLSessionRemoteHostConnectionHTTPTransport(),
        webSocketSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.keyStore = keyStore
        self.httpTransport = httpTransport
        self.webSocketSession = webSocketSession
        self.now = now
    }

    func connection(for hostID: String) throws -> RemoteHostConnection {
        guard registry.hasHosts else {
            throw RemoteClientError.hostNotFound(hostID)
        }
        guard try registry.host(id: hostID) != nil else {
            throw RemoteClientError.hostNotFound(hostID)
        }
        if let connection = connections[hostID] {
            return connection
        }
        let connection = RemoteHostConnection(
            hostID: hostID,
            registry: registry,
            keyStore: keyStore,
            httpTransport: httpTransport,
            webSocketSession: webSocketSession,
            now: now
        )
        connections[hostID] = connection
        return connection
    }

    func testConnection(hostID: String) async throws -> RemoteHostConnectionTestResult {
        let connection = try connection(for: hostID)
        return try await connection.testConnection()
    }

    func disconnect(hostID: String) async {
        await connections[hostID]?.disconnect()
    }

    func teardown(hostID: String) async {
        let connection = connections.removeValue(forKey: hostID)
        await connection?.disconnect()
    }

    func disconnectAll() async {
        let existing = connections
        connections.removeAll()
        for connection in existing.values {
            await connection.disconnect()
        }
    }
}
