@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentHandoffUITests: XCTestCase {
    func testDestinationSourceRequiresMappedRemoteRowsAndKeepsLocalRowsEligible() {
        XCTAssertEqual(
            AgentHandoffConfig.destinationSource(remoteHostID: nil, resolvedHostRowID: nil),
            .localProviders
        )
        XCTAssertNil(
            AgentHandoffConfig.destinationSource(remoteHostID: "host-a", resolvedHostRowID: nil)
        )
        XCTAssertEqual(
            AgentHandoffConfig.destinationSource(remoteHostID: "host-a", resolvedHostRowID: UUID()),
            .remoteCatalog(hostID: "host-a")
        )
    }

    func testRemoteDestinationStateRendersStructuredCatalogEffortAndExactRawValues() throws {
        var state = AgentHandoffRemoteDestinationState(
            catalog: structuredCatalogFixture(),
            preferredModelID: "codexExec:gpt-5.4:low"
        )

        let agent = try XCTUnwrap(state.structuredAgentGroups.first)
        let model = try XCTUnwrap(agent.models.first)
        XCTAssertEqual(agent.name, "Codex CLI")
        XCTAssertEqual(model.displayName, "GPT-5.4")
        XCTAssertEqual(state.effortOptions.map(\.displayName), ["Low", "High"])
        XCTAssertEqual(state.selectedEffortOption?.displayName, "Low")
        XCTAssertEqual(
            state.destination,
            .remote(
                agentID: "codexExec",
                modelID: "codexExec:gpt-5.4:low",
                effort: "low"
            )
        )

        state.selectEffort(modelID: "codexExec:gpt-5.4:high")
        XCTAssertEqual(state.selectedEffortOption?.displayName, "High")
        XCTAssertEqual(
            state.destination,
            .remote(
                agentID: "codexExec",
                modelID: "codexExec:gpt-5.4:high",
                effort: "high"
            )
        )
    }

    func testDegradedRemoteCatalogDisablesHandoffButKeepsCopyPayloadAvailable() {
        let state = AgentHandoffRemoteDestinationState(
            catalog: .degraded,
            preferredModelID: nil
        )

        XCTAssertFalse(state.canPerformHandoff)
        XCTAssertTrue(state.canCopyPayload)
        XCTAssertNil(state.destination)
    }

    func testCopyFailureAndInDoubtHandoffRemainLegibleInPopoverErrors() async {
        let copyResult = await AgentHandoffPopover.clipboardPayloadResult(
            config: remoteConfig(catalog: .degraded) {
                throw HandoffUITestError.extractionFailed
            }
        )
        XCTAssertEqual(copyResult, .failure("Copy Payload failed: Host extraction failed."))

        let inDoubt = RemoteClientError.inDoubt(RemoteCommandError(
            code: "in_doubt",
            message: "The command outcome is unknown."
        ))
        let message = AgentHandoffPopover.errorMessage(for: .handoff, error: inDoubt)
        XCTAssertTrue(message.contains("uncertain (in doubt)"), message)
        XCTAssertTrue(message.contains("The command outcome is unknown."), message)
        XCTAssertTrue(message.contains("before retrying"), message)

        let copyMessage = AgentHandoffPopover.errorMessage(for: .copyPayload, error: inDoubt)
        XCTAssertTrue(copyMessage.contains("Copy Payload outcome is uncertain (in doubt)"), copyMessage)
        XCTAssertFalse(copyMessage.contains("created the fork"), copyMessage)
    }

    private func structuredCatalogFixture() -> RemoteHostAgentCatalog {
        RemoteHostAgentCatalog(agents: [
            RemoteHostAgent(
                name: "Codex CLI",
                defaultModelID: "codexExec:gpt-5.4:high",
                models: [
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4:low",
                        name: "Codex CLI GPT-5.4 Low",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4",
                        effort: "low",
                        modelDisplayName: "GPT-5.4",
                        effortDisplayName: "Low"
                    ),
                    RemoteHostModel(
                        modelID: "codexExec:gpt-5.4:high",
                        name: "Codex CLI GPT-5.4 High",
                        agentID: "codexExec",
                        baseModelID: "gpt-5.4",
                        effort: "high",
                        modelDisplayName: "GPT-5.4",
                        effortDisplayName: "High",
                        isDefault: true
                    )
                ]
            )
        ])
    }

    private func remoteConfig(
        catalog: RemoteHostAgentCatalog,
        buildPayload: @escaping @MainActor () async throws -> String
    ) -> AgentHandoffConfig {
        AgentHandoffConfig(
            itemID: UUID(),
            destinationSource: .remoteCatalog(hostID: "host-a"),
            defaultDestinationAgent: .codexExec,
            defaultModelRaw: "codexExec:gpt-5.4:high",
            defaultReasoningEffortRaw: "high",
            availableAgentsProvider: { [] },
            modelOptionsProvider: { _ in [] },
            remoteCatalogSnapshot: catalog,
            windowID: -1,
            buildPayloadForClipboard: buildPayload,
            performHandoff: { _ in }
        )
    }
}

private enum HandoffUITestError: LocalizedError {
    case extractionFailed

    var errorDescription: String? {
        "Host extraction failed."
    }
}
