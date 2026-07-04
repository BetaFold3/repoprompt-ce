@testable import RepoPromptApp
import XCTest

final class RemoteAgentSessionTests: XCTestCase {
    func testLegacyAgentSessionJSONDecodesWithoutRemoteHostBinding() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000301",
          "serializationVersion": 6,
          "name": "Legacy Remote Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertNil(decoded.remoteHost)
        XCTAssertEqual(decoded.serializationVersion, 6)
    }

    func testAgentSessionRoundTripsRemoteHostBindingWithoutVersionBump() throws {
        let binding = makeBinding()
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000302")),
            name: "Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            remoteHost: binding,
            autoEditEnabled: false
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("remoteHost"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 6)
        XCTAssertEqual(decoded.remoteHost, binding)
    }

    func testDataServiceStubMetadataAndSidebarExposeRemoteHostBinding() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let binding = makeBinding()
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000303"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000304"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Remote Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 40),
            itemCount: 4,
            lastRunState: AgentSessionRunState.running.rawValue,
            remoteHost: binding,
            autoEditEnabled: true,
            origin: .remote(deviceID: "device-abc")
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 4
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Remote Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertNil(stub.transcript)
        XCTAssertTrue(stub.items.isEmpty)
        XCTAssertEqual(stub.remoteHost, binding)

        let meta = try XCTUnwrap(metadata.first)
        XCTAssertEqual(meta.remoteHostID, binding.hostID)
        XCTAssertEqual(meta.remoteHostName, binding.hostDisplayName)

        let sidebarEntry = try XCTUnwrap(sidebar.entriesBySessionID[sessionID])
        XCTAssertEqual(sidebarEntry.remoteHostID, binding.hostID)
        XCTAssertEqual(sidebarEntry.remoteHostName, binding.hostDisplayName)
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testMetadataIndexRemoteHostFieldsParticipateInStaleComparison() throws {
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000305")),
            name: "Indexed Remote Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 50),
            itemCount: 2,
            remoteHost: makeBinding(),
            autoEditEnabled: true
        )
        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-00000000-0000-0000-0000-000000000305.json")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 52)
        )
        let sameRecord = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 53)
        )
        XCTAssertTrue(record.matchesIndexedSessionMetadata(sameRecord))

        var changed = session
        changed.remoteHost?.hostDisplayName = "Renamed Host"
        let changedRecord = AgentSessionMetadataRecord.record(
            from: changed,
            fileURL: fileURL,
            observedFileSize: 123,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 51),
            lastIndexedAt: Date(timeIntervalSinceReferenceDate: 54)
        )
        XCTAssertFalse(record.matchesIndexedSessionMetadata(changedRecord))
    }

    func testLegacyMetadataIndexRecordsDecodeWithoutRemoteHostFields() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000306",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000306.json",
              "name": "Indexed Legacy Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(payload.utf8))
        let record = try XCTUnwrap(decoded.entries.first)

        XCTAssertNil(record.remoteHostID)
        XCTAssertNil(record.remoteHostName)
        XCTAssertNil(record.agentSessionMeta().remoteHostID)
        XCTAssertNil(record.agentSessionMeta().remoteHostName)
    }

    @MainActor
    func testChannelClosingReasonSurfacesAsBannerAndDedupedSystemRows() {
        let coordinator = RemoteAgentModeCoordinator()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.remoteHost = makeBinding()
        session.runState = .running

        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(session.runningStatusText, "Remote reconnecting (app_link_unavailable)…")
        XCTAssertEqual(
            systemMessages(in: session),
            ["Remote channel degraded: app_link_unavailable. Reconnecting…"]
        )

        coordinator.test_applyChannel(.init(kind: .connected), to: session)
        coordinator.test_applyChannel(.init(kind: .degraded(reason: "app_link_unavailable")), to: session)

        XCTAssertEqual(systemMessages(in: session).count(where: { $0.contains("app_link_unavailable") }), 2)
    }

    @MainActor
    func testStoppingLastRemoteTabsReleasesControllersAndFanoutTasks() async throws {
        let directory = try RemoteHostTestSupport.temporaryDirectory(testCase: self)
        let registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: directory))
        let keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
        let record = try RemoteHostTestSupport.hostRecord(displayName: "Studio Mac")
        try registry.upsertHost(record)
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let coordinator = RemoteAgentModeCoordinator()
        let firstTabID = UUID()
        let secondTabID = UUID()
        var firstController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-1"),
            connection: connection
        )
        var secondController: RemoteAgentSessionController? = RemoteAgentSessionController(
            binding: makeBinding(hostID: record.id, remoteSessionID: "remote-session-2"),
            connection: connection
        )
        let weakFirstController = RemoteAgentSessionWeakBox(firstController)
        let weakSecondController = RemoteAgentSessionWeakBox(secondController)

        try coordinator.test_attachController(
            tabID: firstTabID,
            hostID: record.id,
            controller: XCTUnwrap(firstController),
            connection: connection
        )
        try coordinator.test_attachController(
            tabID: secondTabID,
            hostID: record.id,
            controller: XCTUnwrap(secondController),
            connection: connection
        )

        var counts = coordinator.test_lifecycleCounts()
        XCTAssertEqual(counts.controllers, 2)
        XCTAssertEqual(counts.eventTasks, 2)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 2)

        coordinator.stop(tabID: firstTabID)
        firstController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakFirstController.value == nil && coordinator.test_lifecycleCounts().controllers == 1
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakFirstController.value)
        XCTAssertEqual(counts.controllers, 1)
        XCTAssertEqual(counts.eventTasks, 1)
        XCTAssertEqual(counts.hostFanoutTasks, 1)
        XCTAssertEqual(counts.tabHostBindings, 1)

        coordinator.stop(tabID: secondTabID)
        secondController = nil
        await waitForRemoteCoordinatorLifecycle {
            weakSecondController.value == nil && coordinator.test_lifecycleCounts().controllers == 0
        }
        counts = coordinator.test_lifecycleCounts()
        XCTAssertNil(weakSecondController.value)
        XCTAssertEqual(counts.controllers, 0)
        XCTAssertEqual(counts.eventTasks, 0)
        XCTAssertEqual(counts.hostFanoutTasks, 0)
        XCTAssertEqual(counts.tabHostBindings, 0)
    }

    @MainActor
    private func systemMessages(in session: AgentModeViewModel.TabSession) -> [String] {
        session.items.filter { $0.kind == .system }.map(\.text)
    }

    @MainActor
    private func waitForRemoteCoordinatorLifecycle(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate(), "Timed out waiting for remote coordinator lifecycle cleanup", file: file, line: line)
    }

    private func makeBinding(
        hostID: String = "host-abc",
        remoteSessionID: String = "remote-session-abc"
    ) -> AgentSessionRemoteHostBinding {
        AgentSessionRemoteHostBinding(
            hostID: hostID,
            hostDisplayName: "Studio Mac",
            remoteSessionID: remoteSessionID,
            lastAppliedSeq: 42,
            nextLogOffset: 7
        )
    }

    private final class RemoteAgentSessionWeakBox<Value: AnyObject> {
        weak var value: Value?

        init(_ value: Value?) {
            self.value = value
        }
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAgentSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Agent Session Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
