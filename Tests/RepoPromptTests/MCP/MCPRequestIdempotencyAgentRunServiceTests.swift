import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Plan §6.1: `agent_run` service-level `request_id` idempotency. Duplicates are
/// absorbed by `MCPRequestIdempotencyRegistry` before re-executing the mutation,
/// while `mcpResolvePendingInteraction` fencing stays strict for first attempts.
@MainActor
final class MCPRequestIdempotencyAgentRunServiceTests: XCTestCase {
    private final class CallCounter: @unchecked Sendable {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    func testDuplicateStartExecutesMutationOnceAndReplaysRecordedFailure() async throws {
        let registry = MCPRequestIdempotencyRegistry()
        let counter = CallCounter()
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "idempotency-service-tests",
                    windowID: nil
                )
            },
            requireTargetWindow: {
                counter.increment()
                throw MCPError.invalidParams("start-sentinel-refusal")
            },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be reached")
            }
        )
        service.idempotencyRegistry = registry

        let args: [String: Value] = [
            "op": .string("start"),
            "message": .string("go"),
            "request_id": .string("req-start-1")
        ]

        do {
            _ = try await service.execute(args: args)
            XCTFail("First start must fail through the sentinel refusal")
        } catch {
            XCTAssertTrue(String(describing: error).contains("start-sentinel-refusal"))
        }
        XCTAssertEqual(counter.count, 1)

        do {
            _ = try await service.execute(args: args)
            XCTFail("Duplicate start must replay the recorded outcome")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("already failed"),
                "Duplicate must be answered from the registry: \(error)"
            )
        }
        XCTAssertEqual(counter.count, 1, "Duplicate start must not execute the mutation a second time")
    }

    func testDuplicateRespondReplaysRecordedResultWhileVMFencingStaysStrict() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        let args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes"),
            "request_id": .string("req-respond-1")
        ]

        do {
            _ = try await service.execute(args: args)
            XCTFail("First respond must throw through strict VM interaction fencing")
        } catch {
            let description = String(describing: error)
            XCTAssertTrue(
                description.localizedCaseInsensitiveContains("interaction"),
                "First respond must fail via VM fencing: \(description)"
            )
            XCTAssertFalse(description.contains("already failed"))
        }

        do {
            _ = try await service.execute(args: args)
            XCTFail("Duplicate respond must replay the recorded outcome")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("already failed"),
                "Duplicate respond must be answered from the registry: \(error)"
            )
        }
    }

    func testSameRequestIDWithDifferentPayloadReturnsConflict() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        var args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes"),
            "request_id": .string("req-conflict-1")
        ]
        _ = try? await service.execute(args: args)

        args["response"] = .string("no")
        do {
            _ = try await service.execute(args: args)
            XCTFail("Same request_id with a different payload must conflict")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("request_id_conflict"),
                "Expected request_id_conflict, got: \(error)"
            )
        }
    }

    func testMutationWithoutRequestIDBypassesRegistry() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        _ = try? await service.execute(args: [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes")
        ])

        let entryCount = await registry.test_entryCount()
        XCTAssertEqual(entryCount, 0, "request_id is opt-in; without it no idempotency entry is recorded")
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func makeService(window: WindowState) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "idempotency-service-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be reached")
            }
        )
    }
}
