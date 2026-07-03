import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptShared
import XCTest

final class AppLinkSessionTests: XCTestCase {
    func testStubBootstrapAcceptEmitsConnected() async throws {
        let connector = StubAppLinkConnector(outcomes: [.success(StubAppLinkConnection())])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()

        XCTAssertEqual(first, .connected)
        await session.shutdown()
    }

    func testCallToolInjectsRawJSONFlagCentrallyAndAllowsOverride() async throws {
        let connection = RecordingAppLinkConnection()
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await session.connect()

        _ = try await session.callTool(name: "remote_pairing", arguments: ["op": .string("list_devices")])
        _ = try await session.callTool(name: "agent_run", arguments: ["_rawJSON": .bool(false)])

        let calls = await connection.calls
        XCTAssertEqual(calls.count, 2)
        // Regression: trust sync (and any other consumer) must receive raw JSON
        // tool output, not the app's ```json fenced markdown rendering; otherwise
        // trust never loads and remote connects fail with `trust_unavailable`.
        XCTAssertEqual(calls[0].arguments["_rawJSON"]?.boolValue, true)
        // Explicit caller overrides are preserved.
        XCTAssertEqual(calls[1].arguments["_rawJSON"]?.boolValue, false)
        await session.shutdown()
    }

    func testStubBootstrapRejectThrowsFromConnect() async throws {
        let connector = StubAppLinkConnector(outcomes: [.failure(StubAppLinkError.rejected)])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )

        do {
            try await session.connect()
            XCTFail("Expected connect to throw")
        } catch StubAppLinkError.rejected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReconnectEmitsReconnectingThenConnected() async throws {
        let connector = StubAppLinkConnector(outcomes: [
            .failure(StubAppLinkError.rejected),
            .success(StubAppLinkConnection())
        ])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in },
            initialReconnectBackoff: 0.001,
            maximumReconnectBackoff: 0.001
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        let second = await events.next()

        XCTAssertEqual(first, .reconnecting(attempt: 1, reason: "rejected"))
        XCTAssertEqual(second, .connected)
        await session.shutdown()
    }

    func testReconnectEmitsFailedAfterConfiguredAttemptBudget() async throws {
        let connector = StubAppLinkConnector(outcomes: [
            .failure(StubAppLinkError.rejected),
            .failure(StubAppLinkError.rejected)
        ])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in },
            initialReconnectBackoff: 0.001,
            maximumReconnectBackoff: 0.001,
            maximumReconnectAttempts: 2
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        let second = await events.next()

        XCTAssertEqual(first, .reconnecting(attempt: 1, reason: "rejected"))
        XCTAssertEqual(second, .failed(reason: "rejected"))
        await session.shutdown()
    }

    func testAppChannelClosingNotificationEmitsClosingState() async throws {
        let connector = ChannelClosingCapturingConnector()
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        let capturedHandler = await connector.capturedHandler
        let handler = try XCTUnwrap(capturedHandler, "connect must register the channel_closing handler")
        await handler(RepoPromptChannelClosingParams(
            reason: .serverShutdown,
            message: "restarting"
        ))

        let second = await events.next()
        XCTAssertEqual(second, .closing(reason: TerminationReason.serverShutdown.rawValue, message: "restarting"))
        await session.shutdown()
    }
}

private enum StubAppLinkError: Error, CustomStringConvertible {
    case rejected

    var description: String {
        switch self {
        case .rejected: "rejected"
        }
    }
}

private actor StubAppLinkConnector: AppLinkConnecting {
    private var outcomes: [Result<StubAppLinkConnection, Error>]

    init(outcomes: [Result<StubAppLinkConnection, Error>]) {
        self.outcomes = outcomes
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        guard !outcomes.isEmpty else { return StubAppLinkConnection() }
        return try outcomes.removeFirst().get()
    }
}

/// Plan §6.3: captures the `onChannelClosing` handler AppLinkSession registers so
/// tests can simulate the app's graceful channel-closing announcement.
private actor ChannelClosingCapturingConnector: AppLinkConnecting {
    private(set) var capturedHandler: (@Sendable (RepoPromptChannelClosingParams) async -> Void)?

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        StubAppLinkConnection()
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger,
        onChannelClosing: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection {
        capturedHandler = onChannelClosing
        return StubAppLinkConnection()
    }
}

private struct StubAppLinkConnection: AppLinkConnection {
    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
    }

    func disconnect() async {}
}
