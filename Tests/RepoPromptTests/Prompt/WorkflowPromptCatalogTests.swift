@testable import RepoPromptApp
import XCTest

final class WorkflowPromptCatalogTests: XCTestCase {
    func testWorkflowCommandOrdersAndNamesStayStable() {
        XCTAssertEqual(
            RepoPromptWorkflowID.mcpPromptOrder.map(\.commandName),
            [
                "rp-build",
                "rp-investigate",
                "rp-deep-plan",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize"
            ]
        )
        XCTAssertEqual(
            RepoPromptWorkflowID.installOrder.map(\.commandName),
            [
                "rp-investigate",
                "rp-build",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize",
                "rp-deep-plan"
            ]
        )
        XCTAssertEqual(RepoPromptWorkflowID.allCases.count, 9)
    }

    func testCatalogMetadataMatchesWorkflowIDs() {
        XCTAssertEqual(WorkflowPromptCatalog.descriptors.count, RepoPromptWorkflowID.allCases.count)
        XCTAssertEqual(WorkflowPromptCatalog.mcpPromptDescriptors.map(\.id), RepoPromptWorkflowID.mcpPromptOrder)
        XCTAssertEqual(WorkflowPromptCatalog.installDescriptors.map(\.id), RepoPromptWorkflowID.installOrder)

        for descriptor in WorkflowPromptCatalog.descriptors {
            XCTAssertEqual(descriptor.name, descriptor.id.commandName)
            XCTAssertFalse(descriptor.description.isEmpty, descriptor.name)
        }
    }

    func testRenderedManagedPromptFrontmatterCompatibility() {
        XCTAssertEqual(RepoPromptWorkflowPrompts.skillsVersion, 63)

        for descriptor in WorkflowPromptCatalog.installDescriptors {
            let rendered = RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
            XCTAssertTrue(rendered.hasPrefix("---\n"), descriptor.name)
            XCTAssertTrue(rendered.contains("name: \"\(descriptor.name)\""), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_managed: true"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_skills_version: 63"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_variant: mcp"), descriptor.name)
            XCTAssertFalse(RepoPromptWorkflowPrompts.stripYAMLFrontmatter(rendered).hasPrefix("---"), descriptor.name)
        }
    }

    func testNamedOracleGuidanceStaysFailClosedAcrossAgentAndReminderPrompts() {
        let reminder = RepoPromptWorkflowPrompts.render(id: .reminder, variant: .mcp)
        let standardAgent = SystemPromptService.agentModePrompt()
        let engineerAgent = SystemPromptService.agentModePrompt(taskLabelKind: .engineer)

        for (label, prompt) in [
            ("rp-reminder", reminder),
            ("standard agent", standardAgent),
            ("engineer agent", engineerAgent)
        ] {
            XCTAssertTrue(prompt.contains("model-preset selector"), label)
            XCTAssertTrue(prompt.contains("oracle_utils"), label)
            XCTAssertTrue(prompt.contains("exact preset UUID"), label)
            XCTAssertTrue(prompt.contains("same tool-call batch"), label)
            XCTAssertTrue(prompt.contains("`chat_name` is"), label)
            XCTAssertTrue(prompt.contains("never selects a model"), label)
            XCTAssertTrue(prompt.contains("`model_preset_id`"), label)
            XCTAssertTrue(prompt.contains("do not synthesize"), label)
        }
        XCTAssertTrue(reminder.contains("re-packages the current workspace selection"))
        XCTAssertTrue(reminder.contains("fresh chat with a concise summary"))
    }

    func testAgentWorkflowTemplatesRenderFromProviderNeutralCatalog() {
        for workflow in AgentWorkflow.allCases {
            let rendered = RepoPromptWorkflowPrompts.render(id: workflow.workflowPromptID, variant: .agent)
            XCTAssertFalse(rendered.isEmpty, workflow.rawValue)
            XCTAssertEqual(workflow.template, rendered, workflow.rawValue)
        }
    }
}
