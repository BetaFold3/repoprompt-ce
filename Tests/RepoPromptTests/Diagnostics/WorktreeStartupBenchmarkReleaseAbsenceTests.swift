import Foundation
import XCTest

final class WorktreeStartupBenchmarkReleaseAbsenceTests: XCTestCase {
    func testReleaseProjectionOmitsBenchmarkPhasesSchemaAndDiagnosticSurface() throws {
        let root = try RepoRoot.url()
        let files = [
            "Sources/RepoPrompt/Features/Diagnostics/App/WorktreeStartupInstrumentation.swift",
            "Sources/RepoPrompt/Features/Diagnostics/AgentMode/OhMyPiAgentModeSmokeGate.swift",
            "Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelCatalog.swift",
            "Sources/RepoPrompt/Features/Settings/ViewModels/APISettingsViewModel.swift",
            "Sources/RepoPrompt/Features/Diagnostics/App/WorktreeStartupBenchmarkDiagnostics.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspacePolicyCanonicalizationDiagnostics.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeInitializationModels.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsWorktreeStartup.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugTransportDiagnostics.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentExternalMCPRunStarter.swift",
            "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift",
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift",
            "Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift"
        ]
        let sources = try files.map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let unprojectedSource = sources.joined(separator: "\n")
        let projection = sources.map(releaseProjection).joined(separator: "\n")
        for sourceBackedIdentifier in [
            "helper_peer_start_seconds",
            "helper_peer_start_microseconds",
            "ompQualificationStartContext",
            "invocationStartContext",
            "ompQualificationInvocationContext",
            "mcpStartInvocationGenerationID",
            "mcpStartDiscardClaimGenerationID",
            "mcpInstallStartInvocationGeneration",
            "ompQualificationStartupLease",
            "testBeforeOMPQualificationTargetDiscardCAS",
            "testWorktreePreparationFailure",
            "testBeforeWorktreePreparationFailureCleanup",
            "test_attachmentFinalizationHook",
            "The OMP qualification transaction context was replaced before instruction dispatch.",
            "testOMPQualificationTerminalCategory",
            "testBeforeOMPQualificationContextIdentityCheck",
            "testAfterOMPQualificationPreDispatchIdentityCheck",
            "testBeforeOMPQualificationProviderAuthorization",
            "testOMPQualificationProviderBootstrapEntry",
            "OMPQualificationStartupProbes",
            "ompQualificationStartupProbes",
            "installOMPQualificationStartupProbes",
            "duringExpectedMCPRunIDSet",
            "testDuringSet",
            "testOMPQualificationLeaseCreated",
            "debugCleanupSnapshot",
            "terminalCleanupRequestCount",
            "terminalCleanupRawRequestCount",
            "terminalCleanupRequestEntries",
            "didRecordTerminalCleanupRequest",
            "recordTerminalCleanupRequest"
        ] {
            XCTAssertTrue(
                unprojectedSource.contains(sourceBackedIdentifier),
                "Release-absence assertion is vacuous for \(sourceBackedIdentifier)"
            )
        }
        XCTAssertTrue(
            projection.contains("selectedAgent != .ohMyPi"),
            "RELEASE must retain the provider-start fail-closed OMP barrier"
        )
        let runnerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift"
            ),
            encoding: .utf8
        )
        let releaseRunner = releaseProjection(runnerSource)
        XCTAssertEqual(
            releaseRunner.components(separatedBy: "guard providerStartAuthorizer(runID) else").count - 1,
            2,
            "RELEASE must invoke the provider authorizer on both reusable and fresh ACP start paths"
        )
        XCTAssertTrue(releaseRunner.contains("switch revalidateStartupBoundary("))
        XCTAssertTrue(releaseRunner.contains(".beforeBootstrap,"))
        XCTAssertTrue(releaseRunner.contains("case let .cancelled(stage):"))
        XCTAssertTrue(releaseRunner.contains("await finalizeInvalidStartupBoundary("))
        XCTAssertFalse(
            releaseRunner.contains("guard let boundarySnapshot"),
            "RELEASE must retain the typed fail-closed startup-boundary outcome"
        )
        let freshAuthorization = try XCTUnwrap(
            releaseRunner.range(of: "guard providerStartAuthorizer(runID) else", options: .backwards)
        )
        let bootstrap = try XCTUnwrap(releaseRunner.range(of: "let bootstrap = try await controller.bootstrap()"))
        XCTAssertLessThan(freshAuthorization.lowerBound, bootstrap.lowerBound)

        let serviceSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift"
            ),
            encoding: .utf8
        )
        let releaseService = releaseProjection(serviceSource)
        let darknessStart = try XCTUnwrap(releaseService.range(of: "if selectedAgent == .ohMyPi"))
        let darknessTail = releaseService[darknessStart.lowerBound...]
        let failure = try XCTUnwrap(darknessTail.range(of: "await failBeforeProviderStartup"))
        let terminalReturn = try XCTUnwrap(darknessTail.range(of: "return nil"))
        XCTAssertLessThan(failure.lowerBound, terminalReturn.lowerBound)
        XCTAssertTrue(
            releaseRunner[freshAuthorization.lowerBound ..< bootstrap.lowerBound]
                .contains("return"),
            "A denied RELEASE OMP authorizer must return before controller.bootstrap()"
        )
        for forbidden in [
            "firstBenchmarkSearchStarted",
            "firstBenchmarkReadCompleted",
            "firstBenchmarkCodemapStarted",
            "worktree_startup_benchmark",
            "_worktree_startup_benchmark_token",
            "BenchmarkMetricTag",
            "ReceiptDecision",
            "GitWorkspacePolicyCanonicalizationDiagnostics",
            "BenchmarkPlannerPhase",
            "marker_publications",
            "receipt_decisions",
            "receiptDecisionDigest",
            "worktree_startup_benchmark_diagnostics_enabled",
            "OhMyPiAgentModeSmokeGate",
            "agent_mode.omp_smoke_gate_enabled",
            "omp_qualification_lease",
            "routing_sequence_baseline",
            "ohMyPiQualificationLeaseDidChange",
            "agents.append(.ohMyPi)",
            "_omp_qualification_lease_id",
            "OMPQualificationRawIngressRecorder",
            "debugOMPProcessCorrelationFields",
            "debugProcessIdentityMatches",
            "omp_current_executable_identity_match",
            "helper_current_executable_identity_match",
            "ompQualificationAuthorizer",
            "ompQualificationStartContext",
            "invocationStartContext",
            "ompQualificationInvocationContext",
            "mcpStartInvocationGenerationID",
            "mcpStartDiscardClaimGenerationID",
            "mcpInstallStartInvocationGeneration",
            "ompQualificationStartupLease",
            "testBeforeOMPQualificationTargetDiscardCAS",
            "testWorktreePreparationFailure",
            "testBeforeWorktreePreparationFailureCleanup",
            "test_attachmentFinalizationHook",
            "The OMP qualification transaction context was replaced before instruction dispatch.",
            "testOMPQualificationTerminalCategory",
            "testBeforeOMPQualificationContextIdentityCheck",
            "testAfterOMPQualificationPreDispatchIdentityCheck",
            "testBeforeOMPQualificationProviderAuthorization",
            "testOMPQualificationProviderBootstrapEntry",
            "OMPQualificationStartupProbes",
            "ompQualificationStartupProbes",
            "installOMPQualificationStartupProbes",
            "duringExpectedMCPRunIDSet",
            "testDuringSet",
            "testOMPQualificationLeaseCreated",
            "debugCleanupSnapshot",
            "terminalCleanupRequestCount",
            "terminalCleanupRawRequestCount",
            "terminalCleanupRequestEntries",
            "didRecordTerminalCleanupRequest",
            "recordTerminalCleanupRequest",
            "helper_peer_start_seconds",
            "helper_peer_start_microseconds",
            "ownerProcessStartMicroseconds",
            "DEBUG qualification authorization"
        ] {
            XCTAssertFalse(projection.contains(forbidden), "Release source projection leaked \(forbidden)")
        }
    }

    private func releaseProjection(_ source: String) -> String {
        struct Frame { let parentIncluded: Bool
            let debugCondition: Bool
            var inElse: Bool
        }
        var frames: [Frame] = []
        var included = true
        var output: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                let isDebug = directive == "#if DEBUG"
                frames.append(Frame(parentIncluded: included, debugCondition: isDebug, inElse: false))
                included = included && !isDebug
            } else if directive == "#else", var frame = frames.popLast() {
                frame.inElse.toggle()
                frames.append(frame)
                included = frame.parentIncluded && (frame.debugCondition || !frame.debugCondition)
            } else if directive == "#endif", let frame = frames.popLast() {
                included = frame.parentIncluded
            } else if included {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
