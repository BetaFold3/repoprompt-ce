import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class InteractiveLifecycleExecutionContractTests: XCTestCase {
    func testAskUserPreservesWorkspaceDefaultAndLongerCallerTimeout() throws {
        XCTAssertEqual(
            try MCPAskUserToolProvider.resolvedInteractionTimeoutSeconds(
                nil,
                defaultTimeout: MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
            ),
            MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
        )
        XCTAssertEqual(
            try MCPAskUserToolProvider.resolvedInteractionTimeoutSeconds(
                .int(900),
                defaultTimeout: MCPTimeoutPolicy.askUserDefaultTimeoutSeconds
            ),
            900
        )
    }

    func testWaitForNextInstructionPreservesDefaultAndLongerCallerTimeout() throws {
        XCTAssertEqual(
            try MCPAgentSessionControlToolProvider.resolvedInstructionWaitTimeoutSeconds(nil),
            MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds
        )
        XCTAssertEqual(
            try MCPAgentSessionControlToolProvider.resolvedInstructionWaitTimeoutSeconds(.int(1200)),
            1200
        )
    }

    func testInteractiveLifecycleToolsHaveNoExecutionWatchdogDeadline() {
        for toolName in [
            MCPWindowToolName.askUser,
            MCPWindowToolName.waitForNextInstruction
        ] {
            let contract = MCPToolExecutionContractCatalog.contract(for: toolName)
            XCTAssertEqual(contract?.kind, .interactiveCancellable, toolName)
            XCTAssertNil(contract?.deadline, toolName)
            XCTAssertNil(contract?.cancellationGrace, toolName)
        }
    }
}
