import Foundation
import MCP
import RepoPromptAgentCore

enum ContextBuilderResponseType: String {
    case plan
    case question
    case review
    case clarify

    static func parse(from value: Value?) throws -> ContextBuilderResponseType? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let parsed = ContextBuilderResponseType(rawValue: raw.lowercased()) else {
            throw MCPError.invalidParams("Invalid response_type: \(raw)")
        }
        return parsed
    }

    var wantsResponse: Bool {
        switch self {
        case .plan, .question, .review:
            true
        case .clarify:
            false
        }
    }

    var generationLabel: String? {
        switch self {
        case .plan:
            "plan"
        case .question:
            "question"
        case .review:
            "review"
        case .clarify:
            nil
        }
    }

    func supportsPresetMode(_ preset: ModelPreset) -> Bool {
        switch self {
        case .plan:
            preset.supportedModes?.plan ?? true
        case .review:
            preset.supportedModes?.review ?? true
        case .question:
            preset.supportedModes?.chat ?? true
        case .clarify:
            false
        }
    }
}
