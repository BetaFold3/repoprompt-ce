import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeApprovalAndResumeTests: XCTestCase {
    enum ResolverError: Error {
        case unsupportedModel
    }

    actor RecordingLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        private(set) var requestedModels: [String?] = []

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            requestedModels.append(requestedModel)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        }
    }

    func testNativeFlagResolutionPassesEncodedGLMModelToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.test_resolveApplyFlagSettingsRequest(model: "glm-5-turbo:xhigh")
            XCTFail("Expected encoded unsupported GLM XHigh model to be rejected by the resolver")
        } catch ResolverError.unsupportedModel {
            // Expected.
        }

        let requestedModels = await resolver.requestedModels
        XCTAssertEqual(requestedModels, ["glm-5-turbo:xhigh"])
    }

    func testNativeLiveModelSwitchRequiresRestartWhenLaunchEnvironmentChanges() async throws {
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
        let directGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5-turbo",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let slotGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-4.7",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let sameEnvironmentDifferentFlagModel = ClaudeCodeLaunchEnvironment(
            effectiveModel: "opus",
            environmentOverrides: directGLM.environmentOverrides,
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )

        let directToSlotRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: slotGLM
        )
        let sameEnvironmentRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: sameEnvironmentDifferentFlagModel
        )

        XCTAssertTrue(directToSlotRequiresRestart)
        XCTAssertFalse(sameEnvironmentRequiresRestart)
    }

    func testResolvedCompatibleBackendBlocksNativeAutoBeforeLaunch() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(
                commandName: "/usr/bin/false",
                modelString: "opus",
                runtimeVariant: .standard,
                permissionMode: "auto"
            ),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.test_resolveApplyFlagSettingsRequest(
                model: "opus",
                effortLevel: .high
            )
            XCTFail("Expected resolved compatible backend to block Auto")
        } catch let error as ClaudeAgentToolPreferences.AutoPermissionModeBlockedError {
            XCTAssertEqual(error.candidacy, .compatibleBackend(.claudeCodeGLM))
        }
    }

    func testSendBeforeInitializationWritesNothingAndTracksNoTurn() async throws {
        let child = try ProcessLauncher.spawn(
            command: "/bin/cat",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp"
        )
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .standard
            )
        )
        await controller.test_attachSpawnedProcess(child, initialized: false)

        do {
            _ = try await controller.sendUserMessage("must not be written")
            XCTFail("Expected send-before-initialization to fail")
        } catch let error as ClaudeNativeProcessSessionController.ControllerError {
            guard case .initializationFailed = error else {
                return XCTFail("Unexpected controller error: \(error)")
            }
        }

        let hasTurnInFlight = await controller.hasTurnInFlight
        XCTAssertFalse(hasTurnInFlight)
        await controller.shutdown()
    }

    func testNativeSessionRefReportsStableGenerationOnReuseAndZeroForUninitializedAttach() async throws {
        let uninitializedChild = try ProcessLauncher.spawn(
            command: "/bin/cat",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp"
        )
        let uninitializedController = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .standard
            )
        )
        await uninitializedController.test_attachSpawnedProcess(
            uninitializedChild,
            initialized: false
        )

        let uninitializedRef = await uninitializedController.currentSessionRef()
        XCTAssertEqual(uninitializedRef.initializationGeneration, 0)
        XCTAssertFalse(uninitializedRef.initializedDuringCall)
        await uninitializedController.shutdown()

        let initializedChild = try ProcessLauncher.spawn(
            command: "/bin/cat",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp"
        )
        let initializedController = try ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .standard
            )
        )
        await initializedController.test_attachSpawnedProcess(
            initializedChild,
            initialized: true
        )

        let attachedRef = await initializedController.currentSessionRef()
        let reusedRef = try await initializedController.startOrResume(
            existingSessionID: nil,
            model: nil
        )
        XCTAssertEqual(attachedRef.initializationGeneration, 1)
        XCTAssertFalse(attachedRef.initializedDuringCall)
        XCTAssertEqual(reusedRef.initializationGeneration, attachedRef.initializationGeneration)
        XCTAssertFalse(reusedRef.initializedDuringCall)
        await initializedController.shutdown()
    }

    @MainActor
    func testPermissionStageAndLocalAutoFailuresDoNotRetryFreshResume() {
        let underlying = ClaudeNativeProcessSessionController.ControllerError.invalidControlResponse(
            "Auto rejected"
        )
        let permissionFailure = ClaudeNativeProcessSessionController.PermissionStageError(
            requestedMode: "auto",
            underlyingError: underlying
        )
        XCTAssertFalse(
            ClaudeAgentModeCoordinator.test_shouldRetryFreshStartWithoutResume(
                after: permissionFailure,
                existingSessionID: "existing-session"
            )
        )
        XCTAssertFalse(
            ClaudeAgentModeCoordinator.test_shouldRetryFreshStartWithoutResume(
                after: ClaudeAgentToolPreferences.AutoPermissionModeBlockedError(
                    candidacy: .unsupportedModel("haiku")
                ),
                existingSessionID: "existing-session"
            )
        )
        XCTAssertTrue(
            ClaudeAgentModeCoordinator.test_shouldRetryFreshStartWithoutResume(
                after: underlying,
                existingSessionID: "existing-session"
            )
        )
    }

    func testRepoPromptPermissionAutoApprovalAndAllowPayloadPreserveToolUseID() throws {
        let repoPromptPayload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": ["path": "Sources/App.swift"],
            "permission_suggestions": [["type": "tool", "name": "mcp__RepoPromptCE__read_file"]]
        ]

        let match = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, .topLevelToolName)
        XCTAssertEqual(match.normalizedToolName, "read_file")

        let allowOnce = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: false
        )
        XCTAssertEqual(allowOnce["behavior"] as? String, "allow")
        XCTAssertEqual(allowOnce["toolUseID"] as? String, "toolu_read_1")
        XCTAssertNil(allowOnce["updatedPermissions"])
        XCTAssertEqual((allowOnce["updatedInput"] as? [String: Any])?["path"] as? String, "Sources/App.swift")

        let allowForSession = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: true
        )
        XCTAssertEqual((allowForSession["updatedPermissions"] as? [[String: Any]])?.first?["name"] as? String, "mcp__RepoPromptCE__read_file")

        let nestedMatch = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: [
                "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]
            ]
        ))
        XCTAssertEqual(nestedMatch.source, .nestedToolName)
        XCTAssertEqual(nestedMatch.normalizedToolName, "read_file")

        XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: ["input": ["command": "rm -rf /tmp/example"]]
        ))
    }
}
