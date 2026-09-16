import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Plan §6.1/§6.3/§8: provider-family automatic lifecycle waits share one numeric authority,
/// the parent family is frozen from the authenticated run binding only, and explicit values are
/// validated against the inclusive 0…14,400-second range without clamping.
@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    private typealias ParentFamily = AgentMCPWaitPolicy.ParentFamily
    private typealias ParentCandidate = AgentMCPWaitPolicy.ParentCandidate

    /// Start, wait, steer and Explore start share one selection authority.
    private var lifecycleSelectionResolvers: [(Value?, ParentFamily) throws -> AgentMCPWaitPolicy.Selection] {
        [
            AgentRunMCPToolService.resolvedStartWaitSelection,
            AgentRunMCPToolService.resolvedWaitSelection,
            AgentRunMCPToolService.resolvedSteerWaitSelection,
            AgentExploreMCPToolService.resolvedStartWaitSelection
        ]
    }

    func testSharedLifecycleTimeoutAuthorityMatchesProductContract() {
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleClaudeAutomaticWaitSeconds, 180)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleCodexAutomaticWaitSeconds, 600)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleOtherAutomaticWaitSeconds, 180)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleUnresolvedAutomaticWaitSeconds, 180)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleMaximumAutomaticWaitSeconds, 600)
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds, 630)
        XCTAssertEqual(
            MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds,
            MCPTimeoutPolicy.agentLifecycleMaximumAutomaticWaitSeconds
                + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
        )
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds, 14400)

        // The public symbol survives only as the unresolved-parent compatibility alias.
        XCTAssertEqual(
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds,
            MCPTimeoutPolicy.agentLifecycleUnresolvedAutomaticWaitSeconds
        )
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds)

        // Parser maximum aliases the shared explicit ceiling so schema text and transport cannot drift.
        XCTAssertEqual(
            AgentMCPToolHelpers.maximumTimeoutSeconds,
            MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds
        )

        let tableMaximum = ParentFamily.allCases
            .map { MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(for: $0) }
            .max()
        XCTAssertEqual(tableMaximum, MCPTimeoutPolicy.agentLifecycleMaximumAutomaticWaitSeconds)
    }

    func testProviderFamilyTableIsExhaustiveOverEveryProviderKind() {
        for provider in AgentProviderKind.allCases {
            let family = AgentMCPWaitPolicy.parentFamily(for: provider)
            let expectedFamily: ParentFamily = switch provider {
            case .claudeCode:
                .claude
            case .codexExec:
                .codex
            case .openCode, .cursor, .ohMyPi, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
                .other
            }
            XCTAssertEqual(family, expectedFamily, "\(provider)")
            let expectedSeconds: TimeInterval = provider == .codexExec ? 600 : 180
            XCTAssertEqual(
                MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(for: family),
                expectedSeconds,
                "\(provider)"
            )
        }
        XCTAssertEqual(MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(for: .unresolved), 180)
        XCTAssertNotEqual(
            AgentMCPWaitPolicy.parentFamily(for: .customClaudeCompatible),
            .claude,
            "Claude-compatible transport must not inherit the Claude row"
        )
    }

    func testOmittedLifecycleTimeoutSelectsAutomaticWaitForFrozenFamily() throws {
        for family in ParentFamily.allCases {
            let expected = MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(for: family)
            for resolver in lifecycleSelectionResolvers {
                let selection = try resolver(nil, family)
                XCTAssertEqual(selection.mode, .automatic, "\(family)")
                XCTAssertEqual(selection.timeoutSeconds, expected, "\(family)")
                XCTAssertEqual(selection.parentFamily, family, "\(family)")
                let canonical = try XCTUnwrap(selection.canonicalValue.objectValue)
                XCTAssertEqual(canonical["mode"], .string("automatic"))
                XCTAssertEqual(canonical["timeout_seconds"], .int(Int(expected)))
                XCTAssertEqual(canonical["parent_family"], .string(family.rawValue))
                XCTAssertEqual(canonical.count, 3, "no extra policy fields: \(canonical.keys.sorted())")
            }
        }
        // Omitted `.null` is omission too.
        let nullSelection = try AgentRunMCPToolService.resolvedWaitSelection(.null, parentFamily: .codex)
        XCTAssertEqual(nullSelection, .automatic(parentFamily: .codex))
        XCTAssertEqual(nullSelection.timeoutSeconds, 600)
    }

    func testExplicitLifecycleTimeoutBoundariesAcceptZeroAndMaximumAndRejectAboveWithoutClamp() throws {
        let maximum = MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds

        for resolver in lifecycleSelectionResolvers {
            // Explicit zero is a non-blocking poll and never carries a family.
            let poll = try resolver(.int(0), .codex)
            XCTAssertEqual(poll, .poll)
            XCTAssertEqual(poll.canonicalValue, .object(["mode": .string("poll"), "timeout_seconds": .int(0)]))

            // Explicit positive values are explicit for every family (no family override).
            let explicit = try resolver(.int(600), .claude)
            XCTAssertEqual(explicit, .explicit(timeoutSeconds: 600))
            XCTAssertNil(explicit.parentFamily)
            XCTAssertEqual(explicit.canonicalValue, .object(["mode": .string("explicit"), "timeout_seconds": .int(600)]))
            XCTAssertGreaterThan(explicit.timeoutSeconds, TimeInterval(MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds))

            // Inclusive maximum across every accepted representation.
            XCTAssertEqual(try resolver(.double(maximum), .other).timeoutSeconds, maximum)
            XCTAssertEqual(try resolver(.int(Int(maximum)), .other).timeoutSeconds, maximum)
            XCTAssertEqual(try resolver(.string(String(Int(maximum))), .other).timeoutSeconds, maximum)
            XCTAssertEqual(try resolver(.int(14400), .unresolved).mode, .explicit)

            // Fractional explicit values survive unchanged.
            let fractional = try resolver(.double(900.5), .codex)
            XCTAssertEqual(fractional, .explicit(timeoutSeconds: 900.5))
            XCTAssertEqual(fractional.canonicalValue.objectValue?["timeout_seconds"], .double(900.5))

            // 14,401 and larger are rejected — never silently clamped to the maximum.
            for value in [Value.int(14401), .double(maximum + 1), .string("14401"), .int(86400)] {
                XCTAssertThrowsError(try resolver(value, .codex), "\(value)") { error in
                    XCTAssertTrue(String(describing: error).contains("14400"), String(describing: error))
                }
            }
        }
    }

    func testParentResolutionRequiresExactlyOneActiveExactRunMatch() {
        let runID = UUID()
        let active = ParentCandidate(runID: runID, isActive: true, selectedAgent: .codexExec)
        let stale = ParentCandidate(runID: runID, isActive: false, selectedAgent: .claudeCode)
        let otherRun = ParentCandidate(runID: UUID(), isActive: true, selectedAgent: .claudeCode)
        let unbound = ParentCandidate(runID: nil, isActive: true, selectedAgent: .claudeCode)
        let duplicate = ParentCandidate(runID: runID, isActive: true, selectedAgent: .claudeCode)

        // Unique active exact match wins; inactive/other/unbound sessions do not disturb it.
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: runID, candidates: [stale, active, otherRun, unbound]), .codex)
        // Missing authenticated identity.
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: nil, candidates: [active]), .unresolved)
        // No session carries that run.
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: runID, candidates: [otherRun, unbound]), .unresolved)
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: runID, candidates: []), .unresolved)
        // Stale: the only exact match is no longer active.
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: runID, candidates: [stale]), .unresolved)
        // Ambiguous: two active sessions claim the same run.
        XCTAssertEqual(AgentMCPWaitPolicy.resolveParentFamily(runID: runID, candidates: [active, duplicate]), .unresolved)
    }

    func testServerFreezesParentFamilyFromAuthenticatedRunBindingOnly() async {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let connectionID = UUID()
        let runID = UUID()
        XCTAssertTrue(window.mcpServer.registerRunIDMapping(
            connectionID: connectionID,
            runID: runID,
            windowID: window.windowID
        ))

        let parent = await viewModel.ensureSessionReady(tabID: UUID())
        parent.runID = runID
        parent.selectedAgent = .codexExec
        parent.runState = .running
        defer { parent.runState = .idle }

        // A differently configured worker session bound to another run must not influence the parent family.
        let worker = await viewModel.ensureSessionReady(tabID: UUID())
        worker.runID = UUID()
        worker.selectedAgent = .claudeCode
        worker.runState = .running
        defer { worker.runState = .idle }

        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-lifecycle-contract-tests",
            windowID: window.windowID
        )
        let bound = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(bound.parentFamily, .codex)
        XCTAssertEqual(bound.metadata.connectionID, connectionID)
        XCTAssertEqual(bound.metadata.clientName, metadata.clientName)

        // Ambiguous: a second active session claiming the same run identity.
        let duplicate = await viewModel.ensureSessionReady(tabID: UUID())
        duplicate.runID = runID
        duplicate.selectedAgent = .claudeCode
        duplicate.runState = .running
        defer { duplicate.runState = .idle }
        let ambiguous = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(ambiguous.parentFamily, .unresolved)

        // Stale: the bound run is no longer active anywhere.
        duplicate.runState = .completed
        parent.runState = .completed
        let stale = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(stale.parentFamily, .unresolved)

        // Missing / external: no authenticated run binding for the connection.
        parent.runState = .running
        let unboundConnection = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "agent-lifecycle-contract-tests",
            windowID: window.windowID
        )
        let unbound = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: unboundConnection)
        XCTAssertEqual(unbound.parentFamily, .unresolved)
        let noConnection = MCPServerViewModel.RequestMetadata(
            connectionID: nil,
            clientName: "agent-lifecycle-contract-tests",
            windowID: window.windowID
        )
        let anonymous = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: noConnection)
        XCTAssertEqual(anonymous.parentFamily, .unresolved)
    }

    /// Plan §6.3 provenance: the manager's cross-window run recovery must never let a connection
    /// without a direct binding in this window inherit the matching session's family.
    func testServerManagerRunFallbackResolvesUnresolvedDespiteMatchingActiveCodexSession() async {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let otherWindow = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(otherWindow) }
        let connectionID = UUID()
        let runID = UUID()

        // Direct binding lives only in the other window; the manager can still recover the run
        // for this connection through its all-windows scan (no persisted window affinity so the
        // fallback is not rejected on window mismatch).
        let mapped = await ServerNetworkManager.shared.mapConnectionToRunID(
            connectionID,
            runID: runID,
            windowID: otherWindow.windowID,
            persistWindowBinding: false
        )
        XCTAssertTrue(mapped)
        XCTAssertNil(window.mcpServer.connectionIDToRunID[connectionID], "fixture: no direct binding in the target window")
        let managerRunID = await ServerNetworkManager.shared.runIDForConnection(connectionID)
        XCTAssertEqual(managerRunID, runID, "fixture: the manager fallback would name the run")

        let parent = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
        parent.runID = runID
        parent.selectedAgent = .codexExec
        parent.runState = .running
        defer { parent.runState = .idle }

        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-lifecycle-contract-tests",
            windowID: window.windowID
        )
        let context = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(context.parentFamily, .unresolved)

        // The same run bound directly in this window is authoritative again.
        XCTAssertTrue(window.mcpServer.registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: window.windowID))
        let direct = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(direct.parentFamily, .codex)
    }

    func testServerRemoteClientNeverInheritsParentFamilyEvenWithDirectBinding() async {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let connectionID = UUID()
        let runID = UUID()
        XCTAssertTrue(window.mcpServer.registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: window.windowID))
        let parent = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
        parent.runID = runID
        parent.selectedAgent = .codexExec
        parent.runState = .running
        defer { parent.runState = .idle }

        let remote = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "remote:abcd1234",
            windowID: window.windowID
        )
        let remoteContext = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: remote)
        XCTAssertEqual(remoteContext.parentFamily, .unresolved)
        XCTAssertEqual(remoteContext.metadata.clientName, "remote:abcd1234")

        let wildcard = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: MCPClientIdentity.remoteAllDevicesWildcard,
            windowID: window.windowID
        )
        let wildcardContext = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: wildcard)
        XCTAssertEqual(wildcardContext.parentFamily, .unresolved)

        // Only the client identity differs: the local Agent Mode caller resolves.
        let local = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-lifecycle-contract-tests",
            windowID: window.windowID
        )
        let localContext = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: local)
        XCTAssertEqual(localContext.parentFamily, .codex)
    }

    func testServerActiveTabCompatibilityRoutingResolvesUnresolvedAndRecordsNoDiagnostic() async {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.mcpServer.setActiveTabCompatibilityFallbackEnabled(true)
        let parent = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
        parent.runID = UUID()
        parent.selectedAgent = .codexExec
        parent.runState = .running
        defer { parent.runState = .idle }
        let diagnosticsBefore = window.mcpServer.activeTabCompatibilityFallbackDiagnostics.count

        // An unbound legacy caller that would otherwise route through active-tab compatibility.
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: UUID(),
            clientName: "legacy-compatibility-client",
            windowID: window.windowID
        )
        let context = await window.mcpServer.resolveAgentLifecycleWaitPolicyContext(metadata: metadata)
        XCTAssertEqual(context.parentFamily, .unresolved)
        XCTAssertEqual(
            window.mcpServer.activeTabCompatibilityFallbackDiagnostics.count,
            diagnosticsBefore,
            "A policy read must not record a compatibility-fallback diagnostic under a synthetic tool name"
        )
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
