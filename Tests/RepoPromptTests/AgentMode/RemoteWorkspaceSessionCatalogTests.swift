@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

@MainActor
final class RemoteWorkspaceSessionCatalogTests: XCTestCase {
    func testFirstFetchUsesWorkspaceNameLearnsHostIDAndParsesPinnedDescriptorFields() async throws {
        let connection = CatalogRecordingConnection(steps: [
            .value(Self.catalogPayload(workspaceID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
            .value(Self.catalogPayload(workspaceID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        ])
        let store = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in connection })
        let clientWorkspaceID = UUID()

        let first = await store.fetch(
            hostID: "host-a",
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: "Project Alpha"
        )
        guard case let .loaded(catalog) = first else {
            return XCTFail("Expected loaded catalog, got \(first)")
        }
        XCTAssertEqual(catalog.hostWorkspaceID, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        XCTAssertEqual(catalog.hostWorkspaceName, "Project Alpha")
        let descriptor = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(descriptor.sessionID, "session-1")
        XCTAssertEqual(descriptor.itemCount, 7)
        XCTAssertEqual(descriptor.originSummary, "remote:device")
        XCTAssertEqual(descriptor.isLive, true)
        XCTAssertEqual(
            try XCTUnwrap(descriptor.lastModified).timeIntervalSince1970,
            1_783_386_000,
            accuracy: 0.001
        )

        _ = await store.fetch(
            hostID: "host-a",
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: "Project Alpha",
            forceRefresh: true
        )
        let frames = await connection.recordedFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload?.objectValue?["workspace_name"]?.stringValue, "Project Alpha")
        XCTAssertNil(frames[0].payload?.objectValue?["workspace_id"])
        XCTAssertEqual(
            frames[1].payload?.objectValue?["workspace_id"]?.stringValue,
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        )
        XCTAssertNotEqual(frames[1].payload?.objectValue?["workspace_id"]?.stringValue, clientWorkspaceID.uuidString)
    }

    func testLearnedIDMismatchDropsIDAndRetriesOnceByName() async {
        let connection = CatalogRecordingConnection(steps: [
            .value(Self.catalogPayload(workspaceID: "OLD-WORKSPACE-ID")),
            .error(.fromCommandError(code: "workspace_mismatch", message: "workspace_mismatch: recreated")),
            .value(Self.catalogPayload(workspaceID: "NEW-WORKSPACE-ID")),
            .value(Self.catalogPayload(workspaceID: "NEW-WORKSPACE-ID"))
        ])
        let store = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in connection })
        let clientWorkspaceID = UUID()

        _ = await store.fetch(
            hostID: "host-a",
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: "Project Alpha"
        )
        let retried = await store.fetch(
            hostID: "host-a",
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: "Project Alpha",
            forceRefresh: true
        )
        guard case let .loaded(catalog) = retried else {
            return XCTFail("Expected retry to load, got \(retried)")
        }
        XCTAssertEqual(catalog.hostWorkspaceID, "NEW-WORKSPACE-ID")

        _ = await store.fetch(
            hostID: "host-a",
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: "Project Alpha",
            forceRefresh: true
        )
        let frames = await connection.recordedFrames()
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[1].payload?.objectValue?["workspace_id"]?.stringValue, "OLD-WORKSPACE-ID")
        XCTAssertNil(frames[2].payload?.objectValue?["workspace_id"])
        XCTAssertEqual(frames[2].payload?.objectValue?["workspace_name"]?.stringValue, "Project Alpha")
        XCTAssertEqual(frames[3].payload?.objectValue?["workspace_id"]?.stringValue, "NEW-WORKSPACE-ID")
    }

    func testFetchMapsUnsupportedWorkspaceNotOpenAndTransportErrorStates() async {
        let unsupportedConnection = CatalogRecordingConnection(steps: [
            .error(.fromCommandError(code: "unsupported_payload_key", message: "unsupported"))
        ])
        let notOpenConnection = CatalogRecordingConnection(steps: [
            .error(.fromCommandError(code: "workspace_not_open", message: "Open Project Alpha on the host."))
        ])
        let transportConnection = CatalogRecordingConnection(steps: [
            .error(.transport("offline"))
        ])

        let unsupportedStore = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in unsupportedConnection })
        let notOpenStore = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in notOpenConnection })
        let transportStore = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in transportConnection })
        let workspaceID = UUID()

        let unsupportedState = await unsupportedStore.fetch(
            hostID: "host",
            clientWorkspaceID: workspaceID,
            workspaceName: "Project Alpha"
        )
        let notOpenState = await notOpenStore.fetch(
            hostID: "host",
            clientWorkspaceID: workspaceID,
            workspaceName: "Project Alpha"
        )
        XCTAssertEqual(unsupportedState, .unsupported)
        XCTAssertEqual(notOpenState, .workspaceNotOpen(message: "Open Project Alpha on the host."))
        guard case let .error(message) = await transportStore.fetch(
            hostID: "host",
            clientWorkspaceID: workspaceID,
            workspaceName: "Project Alpha"
        ) else {
            return XCTFail("Expected transport error state")
        }
        XCTAssertTrue(message.contains("offline"), message)
    }

    func testHealthyAndDegradedEntriesUseRemoteHostCatalogTTLs() async {
        var currentDate = Date(timeIntervalSinceReferenceDate: 100)
        let loadedConnection = CatalogRecordingConnection(steps: [
            .value(Self.catalogPayload(workspaceID: "WORKSPACE-ID")),
            .value(Self.catalogPayload(workspaceID: "WORKSPACE-ID"))
        ])
        let degradedConnection = CatalogRecordingConnection(steps: [
            .error(.fromCommandError(code: "unsupported_payload_key", message: "unsupported")),
            .error(.fromCommandError(code: "unsupported_payload_key", message: "unsupported"))
        ])
        let loadedStore = RemoteWorkspaceSessionCatalogStore(
            connectionProvider: { _ in loadedConnection },
            now: { currentDate }
        )
        let degradedStore = RemoteWorkspaceSessionCatalogStore(
            connectionProvider: { _ in degradedConnection },
            now: { currentDate }
        )
        let workspaceID = UUID()

        _ = await loadedStore.fetch(hostID: "loaded", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")
        _ = await degradedStore.fetch(hostID: "degraded", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")
        currentDate.addTimeInterval(21)
        XCTAssertNotNil(loadedStore.cachedState(hostID: "loaded", clientWorkspaceID: workspaceID))
        XCTAssertNil(degradedStore.cachedState(hostID: "degraded", clientWorkspaceID: workspaceID))
        _ = await degradedStore.fetch(hostID: "degraded", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")
        currentDate.addTimeInterval(280)
        XCTAssertNil(loadedStore.cachedState(hostID: "loaded", clientWorkspaceID: workspaceID))
        _ = await loadedStore.fetch(hostID: "loaded", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")

        let loadedCommandCount = await loadedConnection.commandCount()
        let degradedCommandCount = await degradedConnection.commandCount()
        XCTAssertEqual(loadedCommandCount, 2)
        XCTAssertEqual(degradedCommandCount, 2)
    }

    func testReconnectInvalidationDropsStateAndLearnedHostWorkspaceID() async {
        let connection = CatalogRecordingConnection(steps: [
            .value(Self.catalogPayload(workspaceID: "HOST-WORKSPACE-ID")),
            .value(Self.catalogPayload(workspaceID: "HOST-WORKSPACE-ID"))
        ])
        let store = RemoteWorkspaceSessionCatalogStore(connectionProvider: { _ in connection })
        let workspaceID = UUID()

        _ = await store.fetch(hostID: "host-a", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")
        XCTAssertEqual(
            store.learnedHostWorkspaceID(hostID: "host-a", clientWorkspaceID: workspaceID),
            "HOST-WORKSPACE-ID"
        )

        let coordinator = RemoteAgentModeCoordinator(workspaceSessionCatalogStore: store)
        await coordinator.test_deliverConnectionState(.connected(scopes: []), hostID: "host-a")
        XCTAssertNil(store.cachedState(hostID: "host-a", clientWorkspaceID: workspaceID))
        XCTAssertNil(store.learnedHostWorkspaceID(hostID: "host-a", clientWorkspaceID: workspaceID))
        _ = await store.fetch(hostID: "host-a", clientWorkspaceID: workspaceID, workspaceName: "Project Alpha")

        let frames = await connection.recordedFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertNil(frames[1].payload?.objectValue?["workspace_id"])
        XCTAssertEqual(frames[1].payload?.objectValue?["workspace_name"]?.stringValue, "Project Alpha")
    }

    private static func catalogPayload(workspaceID: String) -> JSONValue {
        .object([
            "sessions": .array([
                .object([
                    "session_id": .string("session-1"),
                    "name": .string("Remote Session"),
                    "state": .string("running"),
                    "last_modified": .string("2026-07-07T01:00:00.000Z"),
                    "item_count": .int(7),
                    "is_live": .bool(true),
                    "agent": .object([
                        "id": .string("codex"),
                        "model": .string("gpt-5.4")
                    ]),
                    "origin": .string("remote:device")
                ])
            ]),
            "workspace": .object([
                "id": .string(workspaceID),
                "name": .string("Project Alpha")
            ]),
            "window_count": .int(1)
        ])
    }
}

private actor CatalogRecordingConnection: RemoteWorkspaceSessionCatalogConnection {
    enum Step {
        case value(JSONValue)
        case error(RemoteClientError)
    }

    private var steps: [Step]
    private var frames: [RemoteClientFrame] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func command(_ frame: RemoteClientFrame, timeout _: TimeInterval) async throws -> JSONValue {
        frames.append(frame)
        guard !steps.isEmpty else {
            return .object([:])
        }
        switch steps.removeFirst() {
        case let .value(value):
            return value
        case let .error(error):
            throw error
        }
    }

    func recordedFrames() -> [RemoteClientFrame] {
        frames
    }

    func commandCount() -> Int {
        frames.count
    }
}
