import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeAutoPermissionPolicyTests: XCTestCase {
    func testOfficialClaudeAutoCandidateMatrix() {
        let eligible = [
            "opus",
            "OPUS",
            "opus[1m]",
            "OPUS[1M]",
            "sonnet",
            "SONNET",
            "opus:low",
            "sonnet:xhigh",
            "claude-opus-4-6",
            "claude-opus-4-7:high",
            "claude-sonnet-4-6",
            "claude-fable-5",
            "claude-opus-5:max",
            "claude-sonnet-5",
            "claude-fable-5-1",
            "claude-opus-5-12-20260902:xhigh",
            "claude-sonnet-5-2-20261010:medium"
        ]

        for model in eligible {
            XCTAssertEqual(
                ClaudeAgentToolPreferences.autoPermissionCandidacy(
                    agentKind: .claudeCode,
                    selectedModelRaw: model
                ),
                .eligible,
                model
            )
        }
    }

    func testOfficialClaudeAutoRejectsUnknownUnsupportedFutureAndMalformedSelections() {
        let blocked: [String?] = [
            nil,
            "",
            "   ",
            AgentModel.defaultModel.rawValue,
            "haiku",
            "claude-haiku-4-5",
            "claude-opus-4-5",
            "claude-sonnet-4-5",
            "claude-opus-6",
            "claude-opus-5-preview",
            "claude-sonnet-5-",
            "claude-fable-5-1-2026090",
            "claude-opus-5:ultra",
            "Claude-opus-5",
            "some-future-alias"
        ]

        for model in blocked {
            XCTAssertNotEqual(
                ClaudeAgentToolPreferences.autoPermissionCandidacy(
                    agentKind: .claudeCode,
                    selectedModelRaw: model
                ),
                .eligible,
                model ?? "<nil>"
            )
        }
    }

    func testCompatibleProvidersNeverInheritOfficialAutoCandidacy() {
        for agentKind in [
            AgentProviderKind.claudeCodeGLM,
            .kimiCode,
            .customClaudeCompatible
        ] {
            XCTAssertEqual(
                ClaudeAgentToolPreferences.autoPermissionCandidacy(
                    agentKind: agentKind,
                    selectedModelRaw: "claude-opus-5-2:xhigh"
                ),
                .compatibleBackend(agentKind)
            )
        }
    }

    func testUnsupportedAutoBlocksWithoutParentOrChildWidening() {
        // Resolution deliberately has no parent/child fallback input. Both
        // conceptual call sites receive the same blocked result.
        let parentResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: "auto",
            agentKind: .claudeCode,
            selectedModelRaw: "haiku"
        )
        let childResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: "auto",
            agentKind: .claudeCode,
            selectedModelRaw: "haiku"
        )

        XCTAssertNil(parentResolution.launchMode)
        XCTAssertNil(childResolution.launchMode)
        XCTAssertEqual(parentResolution, childResolution)
        XCTAssertNotEqual(parentResolution.launchMode, "acceptEdits")
        XCTAssertNotEqual(parentResolution.launchMode, "bypassPermissions")
    }

    func testEligibleAutoAndExplicitNonAutoModesPassThroughExactly() {
        let autoResolution = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: "AuTo",
            agentKind: .claudeCode,
            selectedModelRaw: "claude-sonnet-5-2:high"
        )
        XCTAssertEqual(autoResolution.requestedMode, "AuTo")
        XCTAssertEqual(autoResolution.launchMode, "auto")
        XCTAssertEqual(autoResolution.reason, .eligibleAuto)

        let fullAccess = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: "bypassPermissions",
            agentKind: .claudeCode,
            selectedModelRaw: "haiku"
        )
        XCTAssertEqual(fullAccess.requestedMode, "bypassPermissions")
        XCTAssertEqual(fullAccess.launchMode, "bypassPermissions")
        XCTAssertEqual(fullAccess.reason, .nonAutoPassThrough)

        let unknown = ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: "futurePermissionMode",
            agentKind: .customClaudeCompatible,
            selectedModelRaw: nil
        )
        XCTAssertEqual(unknown.requestedMode, "futurePermissionMode")
        XCTAssertEqual(unknown.launchMode, "futurePermissionMode")
        XCTAssertEqual(unknown.reason, .nonAutoPassThrough)
    }
}
