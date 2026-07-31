import Foundation
import SwiftOpenAI

public enum OpenAIReasoningMode: String, CaseIterable, Sendable {
    case standard
    case pro

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .pro: "Pro"
        }
    }
}

public struct OpenAIConfiguredModelSelection: Equatable, Hashable, Sendable {
    static let rawPrefix = "openai_api_selection_v1__"
    static let capabilityRawPrefix = "openai_api_selection_v2__"
    static let supportedEfforts: [CodexReasoningEffort] = [
        .none, .low, .medium, .high, .xhigh, .max
    ]
    static let persistableEfforts: [CodexReasoningEffort] = [
        .none, .minimal, .low, .medium, .high, .xhigh, .max
    ]

    public let modelID: String
    public let reasoningMode: OpenAIReasoningMode
    public let reasoningEffort: CodexReasoningEffort
    public let supportsStreaming: Bool?

    public init?(
        modelID: String,
        reasoningMode: OpenAIReasoningMode,
        reasoningEffort: CodexReasoningEffort,
        supportsStreaming: Bool? = nil
    ) {
        guard Self.isValidModelID(modelID), Self.persistableEfforts.contains(reasoningEffort) else {
            return nil
        }
        self.modelID = modelID
        self.reasoningMode = reasoningMode
        self.reasoningEffort = reasoningEffort
        self.supportsStreaming = supportsStreaming
    }

    public init?(rawValue: String) {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let prefix: String
        let expectsStreamingCapability: Bool
        if rawValue.hasPrefix(Self.capabilityRawPrefix) {
            prefix = Self.capabilityRawPrefix
            expectsStreamingCapability = true
        } else if rawValue.hasPrefix(Self.rawPrefix) {
            prefix = Self.rawPrefix
            expectsStreamingCapability = false
        } else {
            return nil
        }

        let payload = String(rawValue.dropFirst(prefix.count))
        let fields = payload.components(separatedBy: "__")
        guard fields.count == (expectsStreamingCapability ? 4 : 3),
              let mode = OpenAIReasoningMode(rawValue: fields[1]),
              let effort = CodexReasoningEffort(rawValue: fields[2]),
              let selection = Self(
                  modelID: fields[0],
                  reasoningMode: mode,
                  reasoningEffort: effort,
                  supportsStreaming: expectsStreamingCapability
                      ? Self.streamingCapability(rawValue: fields[3])
                      : nil
              ),
              !expectsStreamingCapability || selection.supportsStreaming != nil,
              selection.rawValue == rawValue
        else {
            return nil
        }
        self = selection
    }

    public var rawValue: String {
        let fields = "\(modelID)__\(reasoningMode.rawValue)__\(reasoningEffort.rawValue)"
        guard let supportsStreaming else {
            return "\(Self.rawPrefix)\(fields)"
        }
        let capability = supportsStreaming ? "streaming" : "completion"
        return "\(Self.capabilityRawPrefix)\(fields)__\(capability)"
    }

    static func pickerSelections(modelID: String) -> [OpenAIConfiguredModelSelection] {
        OpenAIReasoningMode.allCases.flatMap { mode in
            supportedEfforts.compactMap { effort in
                OpenAIConfiguredModelSelection(
                    modelID: modelID,
                    reasoningMode: mode,
                    reasoningEffort: effort
                )
            }
        }
    }

    private static func isValidModelID(_ modelID: String) -> Bool {
        guard !modelID.isEmpty,
              modelID == modelID.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.contains("__")
        else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/")
        return modelID.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func streamingCapability(rawValue: String) -> Bool? {
        switch rawValue {
        case "streaming": true
        case "completion": false
        default: nil
        }
    }
}

struct OpenAIResponseRequestPlan: Equatable {
    enum Delivery: Equatable {
        case foreground
        case stream
        case background
    }

    let baseModel: AIModel
    let modelID: String
    let reasoningEffort: String?
    let reasoningMode: OpenAIReasoningMode?
    let serviceTier: String?

    var requiresProviderEncoding: Bool {
        reasoningMode == .pro
    }

    static func make(model: AIModel, defaultServiceTier: String?) -> OpenAIResponseRequestPlan {
        let tierOverride = model.openAIServiceTierOverride
        let base = model.openAIServiceTierBase

        if case let .openAIConfigured(selection) = base {
            return OpenAIResponseRequestPlan(
                baseModel: base,
                modelID: selection.modelID,
                reasoningEffort: selection.reasoningEffort.rawValue,
                reasoningMode: selection.reasoningMode,
                serviceTier: tierOverride ?? defaultServiceTier
            )
        }

        let resolved: (AIModel, String?) = switch base {
        case .gpt5Pro: (.gpt5Pro, "high")
        case .gpt5ProXHigh: (.gpt5Pro, "xhigh")
        case .gpt54Pro: (.gpt54Pro, "high")
        case .gpt54ProXHigh: (.gpt54Pro, "xhigh")
        case .o3High: (.o3, "high")
        case .o3Low: (.o3, "low")
        case .o3: (.o3, "medium")
        case .gpt5XHigh: (.gpt5, "xhigh")
        case .gpt5High: (.gpt5, "high")
        case .gpt5Low: (.gpt5, "low")
        case .gpt5: (.gpt5, "medium")
        case .gpt54XHigh: (.gpt54, "xhigh")
        case .gpt54High: (.gpt54, "high")
        case .gpt54Low: (.gpt54, "low")
        case .gpt54: (.gpt54, "medium")
        case .gpt5CodexXHigh: (.gpt5CodexMed, "xhigh")
        case .gpt5CodexHigh: (.gpt5CodexMed, "high")
        case .gpt5CodexMed: (.gpt5CodexMed, "medium")
        case .gpt5CodexLow: (.gpt5CodexMed, "low")
        case .gpt54MiniXHigh: (.gpt54Mini, "xhigh")
        case .gpt54MiniHigh: (.gpt54Mini, "high")
        case .gpt54MiniLow: (.gpt54Mini, "low")
        case .gpt54Mini: (.gpt54Mini, "medium")
        case .gpt56Sol: (.gpt56Sol, "medium")
        case .openaiCustomReasoning: (base, base.defaultReasoningEffort)
        default: (base, nil)
        }

        let resolvedTier: String? = switch resolved.0 {
        case .openaiCustomResponses, .openaiCustomReasoning: nil
        default: tierOverride ?? defaultServiceTier
        }
        return OpenAIResponseRequestPlan(
            baseModel: resolved.0,
            modelID: resolved.0.modelName,
            reasoningEffort: resolved.1,
            reasoningMode: nil,
            serviceTier: resolvedTier
        )
    }

    func parameters(
        input: SwiftOpenAI.InputType,
        instructions: String?,
        maxOutputTokens: Int?,
        delivery: Delivery
    ) -> ModelResponseParameter {
        var parameters = ModelResponseParameter(
            input: input,
            model: .custom(modelID),
            background: delivery == .background ? true : nil,
            instructions: instructions,
            maxOutputTokens: maxOutputTokens,
            reasoning: reasoningEffort.map {
                Reasoning(effort: $0, summary: delivery == .stream ? "auto" : nil)
            },
            serviceTier: serviceTier,
            stream: delivery == .stream
        )
        parameters.tools = nil
        parameters.toolChoice = nil
        return parameters
    }

    func encodedBody(for parameters: ModelResponseParameter) throws -> Data {
        let encoded = try JSONEncoder().encode(parameters)
        guard reasoningMode == .pro else { return encoded }

        guard var body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var reasoning = body["reasoning"] as? [String: Any]
        else {
            throw AIProviderError.invalidConfiguration(
                detail: "OpenAI Pro reasoning requires a reasoning request object."
            )
        }
        reasoning["mode"] = OpenAIReasoningMode.pro.rawValue
        body["reasoning"] = reasoning
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
