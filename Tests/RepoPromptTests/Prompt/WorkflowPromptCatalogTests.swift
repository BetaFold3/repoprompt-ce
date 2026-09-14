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
        XCTAssertEqual(RepoPromptWorkflowPrompts.skillsVersion, 64)

        for descriptor in WorkflowPromptCatalog.installDescriptors {
            let rendered = RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
            XCTAssertTrue(rendered.hasPrefix("---\n"), descriptor.name)
            XCTAssertTrue(rendered.contains("name: \"\(descriptor.name)\""), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_managed: true"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_skills_version: 64"), descriptor.name)
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

        let waitFirstWorkflowIDs: [RepoPromptWorkflowID] = [
            .investigate,
            .deepPlan,
            .optimize,
            .orchestrate,
            .refactor
        ]
        let waitFirstVariants: [(name: String, variant: WorkflowPromptVariant)] = [
            ("mcp", .mcp),
            ("cli", .cli),
            ("agent", .agent)
        ]
        for workflowID in waitFirstWorkflowIDs {
            for renderedVariant in waitFirstVariants {
                let rendered = RepoPromptWorkflowPrompts.render(
                    id: workflowID,
                    variant: renderedVariant.variant
                )
                let label = "\(workflowID.commandName) [\(renderedVariant.name)]"

                XCTAssertTrue(rendered.contains("Detach independent parallel starts"), label)
                XCTAssertTrue(rendered.contains("pass every pending ID in `session_ids` to `agent_run op=wait`"), label)
                XCTAssertTrue(rendered.contains("Wait returns as soon as any watched session finishes or needs interaction"), label)
                XCTAssertTrue(rendered.contains("`timeout` is only an upper bound on how long that call may block"), label)
                XCTAssertTrue(rendered.contains("Maintain a caller-owned outstanding-ID set"), label)
                XCTAssertTrue(rendered.contains("do not rebuild it solely from response `pending_session_ids`"), label)
                XCTAssertTrue(rendered.contains("nonterminal interaction/status winner"), label)
                XCTAssertTrue(rendered.contains("Handle **every** returned interaction"), label)
                XCTAssertTrue(rendered.contains("Remove only terminal workers from the outstanding set"), label)
                XCTAssertTrue(rendered.contains("Retain or re-add nonterminal interaction/status winners after responding"), label)
                XCTAssertTrue(rendered.contains("wait again while any outstanding IDs remain"), label)
                XCTAssertTrue(rendered.contains("A timeout leaves workers active; do not abandon them—wait again"), label)
                XCTAssertTrue(rendered.contains("Use `op=poll` only for a deliberate instantaneous inspection"), label)
                XCTAssertTrue(rendered.contains("Do not set `include_status_updates` merely to show activity"), label)
                XCTAssertTrue(rendered.contains("Transport heartbeats keep the connection alive; they do not warm provider prompt caches"), label)
                XCTAssertFalse(rendered.lowercased().contains("poll periodically"), label)
                XCTAssertFalse(rendered.contains("Forgetting to poll"), label)
            }
        }
    }
}
