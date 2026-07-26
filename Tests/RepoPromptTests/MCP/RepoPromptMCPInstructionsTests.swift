import Foundation
@testable import RepoPromptApp
import XCTest

final class RepoPromptMCPInstructionsTests: XCTestCase {
    func testRenderedInstructionVariantsStayWithinClientBudgetAndAvoidNativeComparisonFraming() throws {
        let comparisonMarkers = [
            "recommended over",
            "built-in equivalent",
            "instead of",
            "rather than",
            "compared with"
        ]
        let standaloneNativeToolPattern = #"(?<![A-Za-z0-9_])(Grep|Glob|Edit)(?![A-Za-z0-9_])"#

        for variant in Self.renderedVariants() {
            let label = Self.label(for: variant)
            XCTAssertLessThanOrEqual(
                variant.rendered.count,
                2048,
                "\(label) rendered \(variant.rendered.count) Swift String characters"
            )

            let lowercased = variant.rendered.lowercased()
            for marker in comparisonMarkers {
                XCTAssertFalse(lowercased.contains(marker), "\(label) contains comparison marker: \(marker)")
            }
            XCTAssertFalse(
                try Self.containsRegex(standaloneNativeToolPattern, in: variant.rendered),
                "\(label) contains a forbidden standalone native tool name"
            )
            try Self.assertNoContextualLowercaseNativeToolNames(in: variant.rendered, label: label)

            for identifier in Self.requiredCapabilityIdentifiers(for: variant.purpose) {
                let line = try XCTUnwrap(
                    variant.rendered.components(separatedBy: .newlines).first {
                        try Self.containsIdentifier(identifier, in: $0)
                    },
                    "\(label) is missing capability identifier \(identifier)"
                )
                let descriptiveRemainder = line
                    .replacingOccurrences(of: identifier, with: "")
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                            .union(.punctuationCharacters)
                            .union(CharacterSet(charactersIn: "`"))
                    )
                XCTAssertFalse(
                    descriptiveRemainder.isEmpty,
                    "\(label) must describe capability identifier \(identifier)"
                )
            }
        }
    }

    func testRenderedInstructionVariantsPreservePurposeSpecificToolAndCodeMapBoundaries() throws {
        for variant in Self.renderedVariants() {
            let label = Self.label(for: variant)

            switch variant.purpose {
            case .agentModeRun:
                try Self.assertIdentifiers(
                    [
                        "file_search", "get_file_tree", "read_file", "apply_edits",
                        "manage_selection", "workspace_context", "context_builder", "ask_oracle",
                        "export_response", "oracle_export_path", "oracle_export_instruction"
                    ],
                    arePresentIn: variant.rendered,
                    label: label
                )
                XCTAssertFalse(try Self.containsIdentifier("bind_context", in: variant.rendered), label)
                try Self.assertExportHandoff(in: variant.rendered, label: label)
            case .unknown:
                try Self.assertIdentifiers(
                    [
                        "file_search", "get_file_tree", "read_file", "apply_edits",
                        "manage_selection", "workspace_context", "context_builder", "oracle_send",
                        "agent_run", "export_response", "oracle_export_path", "oracle_export_instruction",
                        "bind_context"
                    ],
                    arePresentIn: variant.rendered,
                    label: label
                )
                try Self.assertExportHandoff(in: variant.rendered, label: label)
                XCTAssertTrue(try Self.containsIdentifier("context_id", in: variant.rendered), label)
                XCTAssertTrue(variant.rendered.localizedCaseInsensitiveContains("tab"), label)
                XCTAssertTrue(variant.rendered.localizedCaseInsensitiveContains("workspace"), label)
            case .discoverRun:
                var expectedIdentifiers: Set = [
                    "file_search", "get_file_tree", "read_file", "manage_selection", "workspace_context", "git"
                ]
                if !variant.codeMapsDisabled {
                    expectedIdentifiers.insert("get_code_structure")
                }
                XCTAssertEqual(
                    try Self.advertisedToolIdentifiers(in: variant.rendered),
                    expectedIdentifiers,
                    "\(label) must advertise exactly the reduced read-only surface"
                )
                try Self.assertIdentifiers(
                    [
                        "apply_edits", "file_actions", "ask_oracle", "oracle_send", "context_builder",
                        "agent_run", "agent_manage", "ask_user", "set_status", "bind_context"
                    ],
                    areAbsentFrom: variant.rendered,
                    label: label
                )
            }

            if variant.codeMapsDisabled {
                XCTAssertFalse(try Self.containsIdentifier("get_code_structure", in: variant.rendered), label)
                XCTAssertTrue(variant.rendered.contains("Code Maps are globally disabled"), label)
                XCTAssertTrue(try Self.containsIdentifier("file_search", in: variant.rendered), label)
                XCTAssertTrue(try Self.containsIdentifier("read_file", in: variant.rendered), label)
            } else {
                XCTAssertTrue(try Self.containsIdentifier("get_code_structure", in: variant.rendered), label)
                XCTAssertFalse(variant.rendered.contains("Code Maps are globally disabled"), label)
            }
        }
    }

    func testFullInstructionVariantsPlaceRoutingBeforeOptionalWorkflowDetails() throws {
        for purpose in [MCPRunPurpose.agentModeRun, .unknown] {
            for codeMapsDisabled in [false, true] {
                let rendered = RepoPromptMCPInstructions.text(
                    for: purpose,
                    codeMapsDisabled: codeMapsDisabled
                )
                let label = "purpose=\(purpose.rawValue), codeMapsDisabled=\(codeMapsDisabled)"
                let routingAnchors = ["file_search", "get_file_tree", "read_file", "apply_edits"]
                var lowerPriorityAnchors = ["manage_selection", "context_builder", "export_response", "delegat"]
                if purpose == .unknown {
                    lowerPriorityAnchors.append(contentsOf: ["agent_run", "bind_context"])
                }

                let routingIndices = try routingAnchors.map {
                    try Self.firstIndex(of: $0, in: rendered, label: label)
                }
                let lowerPriorityIndices = try lowerPriorityAnchors.map {
                    try Self.firstIndex(of: $0, in: rendered, label: label, caseInsensitive: $0 == "delegat")
                }
                let lastRouting = try XCTUnwrap(routingIndices.max(), label)
                let firstLowerPriority = try XCTUnwrap(lowerPriorityIndices.min(), label)

                XCTAssertLessThan(
                    lastRouting,
                    firstLowerPriority,
                    "\(label) routing indices \(routingIndices) must precede lower-priority indices \(lowerPriorityIndices)"
                )
            }
        }
    }

    private typealias RenderedVariant = (
        purpose: MCPRunPurpose,
        codeMapsDisabled: Bool,
        rendered: String
    )

    private static let knownToolIdentifiers: Set<String> = [
        "agent_manage", "agent_run", "apply_edits", "ask_oracle", "ask_user", "bind_context",
        "context_builder", "file_actions", "file_search", "get_code_structure", "get_file_tree",
        "git", "manage_selection", "oracle_send", "read_file", "set_status", "workspace_context"
    ]

    private static func renderedVariants() -> [RenderedVariant] {
        [MCPRunPurpose.agentModeRun, .unknown, .discoverRun].flatMap { purpose in
            [false, true].map { codeMapsDisabled in
                (
                    purpose,
                    codeMapsDisabled,
                    RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: codeMapsDisabled)
                )
            }
        }
    }

    private static func label(for variant: RenderedVariant) -> String {
        "purpose=\(variant.purpose.rawValue), codeMapsDisabled=\(variant.codeMapsDisabled)"
    }

    private static func requiredCapabilityIdentifiers(for purpose: MCPRunPurpose) -> [String] {
        switch purpose {
        case .agentModeRun:
            [
                "file_search", "get_file_tree", "read_file", "apply_edits", "manage_selection",
                "workspace_context", "context_builder", "ask_oracle", "export_response",
                "oracle_export_path", "oracle_export_instruction"
            ]
        case .unknown:
            [
                "file_search", "get_file_tree", "read_file", "apply_edits", "manage_selection",
                "workspace_context", "context_builder", "oracle_send", "agent_run", "export_response",
                "oracle_export_path", "oracle_export_instruction", "bind_context"
            ]
        case .discoverRun:
            ["file_search", "get_file_tree", "read_file", "manage_selection", "workspace_context", "git"]
        }
    }

    private static func assertNoContextualLowercaseNativeToolNames(
        in rendered: String,
        label: String
    ) throws {
        XCTAssertFalse(rendered.contains("cat/head"), label)
        XCTAssertFalse(rendered.contains("ls/find"), label)

        let contextualKeywords = ["command", "equivalent", "native", "unavailable"]
        for line in rendered.components(separatedBy: .newlines) {
            let lowercasedLine = line.lowercased()
            for token in ["cat", "head", "ls", "find"] {
                let tokenPattern = "(?<![A-Za-z0-9_])\(token)(?![A-Za-z0-9_])"
                let appearsAsCode = line.contains("`\(token)`")
                let hasToolContext = contextualKeywords.contains {
                    lowercasedLine.contains($0)
                }
                let appearsWithToolContext = try hasToolContext && containsRegex(tokenPattern, in: line)
                XCTAssertFalse(
                    appearsAsCode || appearsWithToolContext,
                    "\(label) contains contextual forbidden tool token \(token): \(line)"
                )
            }
        }
    }

    private static func assertExportHandoff(in rendered: String, label: String) throws {
        try assertIdentifiers(
            ["export_response", "oracle_export_path", "oracle_export_instruction"],
            arePresentIn: rendered,
            label: label
        )
        XCTAssertTrue(rendered.localizedCaseInsensitiveContains("delegated child"), label)
        XCTAssertTrue(try containsIdentifier("message", in: rendered), label)
    }

    private static func assertIdentifiers(
        _ identifiers: [String],
        arePresentIn rendered: String,
        label: String
    ) throws {
        for identifier in identifiers {
            XCTAssertTrue(
                try containsIdentifier(identifier, in: rendered),
                "\(label) is missing identifier \(identifier)"
            )
        }
    }

    private static func assertIdentifiers(
        _ identifiers: [String],
        areAbsentFrom rendered: String,
        label: String
    ) throws {
        for identifier in identifiers {
            XCTAssertFalse(
                try containsIdentifier(identifier, in: rendered),
                "\(label) leaked identifier \(identifier)"
            )
        }
    }

    private static func advertisedToolIdentifiers(in rendered: String) throws -> Set<String> {
        var advertised: Set<String> = []
        for identifier in knownToolIdentifiers where try containsIdentifier(identifier, in: rendered) {
            advertised.insert(identifier)
        }
        return advertised
    }

    private static func containsIdentifier(_ identifier: String, in rendered: String) throws -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        return try containsRegex("(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])", in: rendered)
    }

    private static func containsRegex(_ pattern: String, in rendered: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(rendered.startIndex..., in: rendered)
        return regex.firstMatch(in: rendered, range: range) != nil
    }

    private static func firstIndex(
        of anchor: String,
        in rendered: String,
        label: String,
        caseInsensitive: Bool = false
    ) throws -> Int {
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        let range = try XCTUnwrap(
            rendered.range(of: anchor, options: options),
            "\(label) is missing ordering anchor \(anchor)"
        )
        return rendered.distance(from: rendered.startIndex, to: range.lowerBound)
    }
}
