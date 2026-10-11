import Foundation

// MARK: - ModelPreset

/// Represents a user-defined model preset with optional mode restrictions.
/// Legacy mode override options preserved for decoding old preset files.
package enum ProEditingOverride: String, Codable {
    case useDefault = "default"
    case forceOn = "on"
    case forceOff = "off"
}

package struct ModelPreset: Codable, Identifiable, Equatable {
    package let id: UUID
    package let name: String
    let modelString: String // Store as string for Codable
    package let description: String?
    package let supportedModes: SupportedModes?
    let proEditingOverride: ProEditingOverride // Legacy decode-only field
    package let chatPresetMappings: ChatPresetMappings? // Maps modes to chat preset IDs
    package let ohMyPiThinkingSelections: OhMyPiThinkingSelections

    /// Returns the resolved AIModel, or `.claude4Sonnet` as a fallback if the stored rawValue can't be parsed.
    /// For cases where you need to handle missing models differently, use `optionalModel` instead.
    package var model: AIModel {
        AIModel.fromModelName(modelString) ?? .claude4Sonnet
    }

    /// Returns the resolved AIModel, or `nil` if the stored rawValue can't be parsed.
    /// Use this when you want to handle missing/renamed models explicitly rather than falling back silently.
    package var optionalModel: AIModel? {
        AIModel.fromModelName(modelString)
    }

    /// Returns `true` if the stored modelString can be resolved to a valid AIModel.
    /// Use this to check if the preset's model is still valid after model definitions may have changed.
    package var isModelResolvable: Bool {
        AIModel.fromModelName(modelString) != nil
    }

    package init(
        id: UUID = UUID(),
        name: String,
        model: AIModel,
        description: String? = nil,
        supportedModes: SupportedModes? = nil,
        proEditingOverride: ProEditingOverride = .useDefault,
        chatPresetMappings: ChatPresetMappings? = nil,
        ohMyPiThinkingSelections: OhMyPiThinkingSelections = .empty
    ) {
        self.id = id
        self.name = Self.sanitizeName(name)
        modelString = model.rawValue
        self.description = description
        self.supportedModes = supportedModes
        self.proEditingOverride = proEditingOverride
        self.chatPresetMappings = chatPresetMappings
        self.ohMyPiThinkingSelections = ohMyPiThinkingSelections
    }

    /// Custom decoding to handle missing fields in existing presets
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        modelString = try container.decode(String.self, forKey: .modelString)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        supportedModes = try container.decodeIfPresent(SupportedModes.self, forKey: .supportedModes)
        // Default to .useDefault if not present (for backward compatibility)
        proEditingOverride = try container.decodeIfPresent(ProEditingOverride.self, forKey: .proEditingOverride) ?? .useDefault
        // Default to nil if not present (for backward compatibility)
        chatPresetMappings = try container.decodeIfPresent(ChatPresetMappings.self, forKey: .chatPresetMappings)
        ohMyPiThinkingSelections = try .decodeIfPresent(from: container, forKey: .ohMyPiThinkingSelections)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(modelString, forKey: .modelString)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(supportedModes, forKey: .supportedModes)
        try container.encodeIfPresent(chatPresetMappings, forKey: .chatPresetMappings)
        try ohMyPiThinkingSelections.encodeIfNonEmpty(to: &container, forKey: .ohMyPiThinkingSelections)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelString, description, supportedModes, proEditingOverride, chatPresetMappings
        case ohMyPiThinkingSelections
    }

    /// Sanitizes a preset name to ensure it's valid for command-line use
    package static func sanitizeName(_ name: String) -> String {
        // Remove leading/trailing whitespace
        var sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace spaces and special characters with underscores
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        sanitized = sanitized.unicodeScalars
            .map { allowedCharacters.contains($0) ? String($0) : "_" }
            .joined()

        // Remove consecutive underscores
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        // Ensure it starts with alphanumeric
        if let first = sanitized.first, !first.isLetter, !first.isNumber {
            sanitized = "preset_" + sanitized
        }

        // Limit length
        let maxLength = 30
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength))
        }

        // Ensure non-empty
        if sanitized.isEmpty {
            sanitized = "preset_\(UUID().uuidString.prefix(8))"
        }

        return sanitized
    }

    /// Validates if a name is acceptable for a preset
    package static func validateName(_ name: String) -> (isValid: Bool, error: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return (false, "Name cannot be empty")
        }

        if trimmed.count > 30 {
            return (false, "Name must be 30 characters or less")
        }

        // Check for whitespace
        if trimmed.contains(" ") || trimmed.contains("\t") || trimmed.contains("\n") {
            return (false, "Name cannot contain spaces or tabs")
        }

        // Check for allowed characters
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let nameCharacters = CharacterSet(charactersIn: trimmed)
        if !allowedCharacters.isSuperset(of: nameCharacters) {
            return (false, "Name can only contain letters, numbers, underscores, and hyphens")
        }

        // Check first character
        if let first = trimmed.first, !first.isLetter, !first.isNumber {
            return (false, "Name must start with a letter or number")
        }

        return (true, nil)
    }

    /// Convenience initializer from current chat model
    package static func fromCurrentChatModel(modelRawString: String) -> ModelPreset {
        let model = AIModel.fromModelName(modelRawString) ?? .claude4Sonnet
        return ModelPreset(
            name: "Default",
            model: model,
            description: "Current chat model",
            supportedModes: nil, // No restrictions by default
            proEditingOverride: .useDefault,
            chatPresetMappings: nil
        )
    }

    /// Finds the best matching preset name from available options using fuzzy matching
    package static func findBestMatch(_ requested: String, among availableNames: [String]) -> String? {
        let trimmedReq = requested.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Exact match
        if availableNames.contains(trimmedReq) {
            return trimmedReq
        }

        // 2) Case-insensitive exact match
        let reqLower = trimmedReq.lowercased()
        if let match = availableNames.first(where: { $0.lowercased() == reqLower }) {
            return match
        }

        // 3) Prefix match (case-insensitive)
        if let match = availableNames.first(where: { $0.lowercased().hasPrefix(reqLower) }) {
            return match
        }

        // 4) Contains match (case-insensitive)
        if let match = availableNames.first(where: { $0.lowercased().contains(reqLower) }) {
            return match
        }

        // 5) Fuzzy similarity using Dice coefficient
        var bestCandidate: String?
        var bestScore = 0.0
        let threshold = 0.6 // Lower threshold for model names

        for candidate in availableNames {
            // Use dice coefficient for fuzzy matching
            let score = trimmedReq.lowercased().diceCoefficient(against: candidate.lowercased())
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        if let match = bestCandidate, bestScore >= threshold {
            return match
        }

        // 6) Levenshtein distance for very close matches
        if trimmedReq.count >= 3 { // Only for non-trivial strings
            for candidate in availableNames {
                let distance = trimmedReq.lowercased().levenshteinDistance(to: candidate.lowercased())
                let maxLen = max(trimmedReq.count, candidate.count)
                let similarity = 1.0 - Double(distance) / Double(maxLen)

                if similarity >= 0.8 { // 80% similarity threshold
                    return candidate
                }
            }
        }

        return nil
    }
}

// MARK: - MCP Model Preset Usage

/// Describes whether configured model presets are currently selectable by MCP
/// Oracle tools. Tool availability is a separate permission boundary.
package enum MCPModelPresetUsageState: Equatable {
    case enabled
    case noneDefined
    case disabledByToggle
    case temporarilyHidden

    package init(
        showModelPresets: Bool,
        temporarilyDisabled: Bool,
        configuredPresetCount: Int
    ) {
        if configuredPresetCount == 0 {
            self = .noneDefined
        } else if !showModelPresets {
            self = .disabledByToggle
        } else if temporarilyDisabled {
            self = .temporarilyHidden
        } else {
            self = .enabled
        }
    }

    package var allowsConfiguredPresets: Bool {
        self == .enabled
    }

    package func blockedPresetMessage(for preset: ModelPreset) -> String? {
        switch self {
        case .disabledByToggle:
            "Model preset '\(preset.name)' (\(preset.id.uuidString)) exists but is not selectable because \"Use Oracle Model Presets for MCP\" is disabled. It was not used. Enable that setting under Settings → MCP, call oracle_utils op=models again, then retry."
        case .temporarilyHidden:
            "Model preset '\(preset.name)' (\(preset.id.uuidString)) exists but is temporarily hidden by Setup Wizard. It was not used. Choose \"Show presets\" under Settings → MCP, call oracle_utils op=models again, then retry."
        case .enabled, .noneDefined:
            nil
        }
    }
}

// MARK: - SupportedModes

/// Defines which modes a model preset supports
package struct SupportedModes: Codable, Equatable {
    package let chat: Bool
    package let plan: Bool
    let edit: Bool
    package let review: Bool

    package init(chat: Bool = true, plan: Bool = true, edit: Bool = false, review: Bool = true) {
        self.chat = chat
        self.plan = plan
        self.edit = edit
        self.review = review
    }

    private enum CodingKeys: String, CodingKey {
        case chat, plan, edit, review
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chat, forKey: .chat)
        try container.encode(plan, forKey: .plan)
        try container.encode(review, forKey: .review)
    }

    /// Custom decoder for backward compatibility when new modes are added
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Default missing keys to true for backward compatibility
        chat = try container.decodeIfPresent(Bool.self, forKey: .chat) ?? true
        plan = try container.decodeIfPresent(Bool.self, forKey: .plan) ?? true
        // Legacy Oracle edit support is decode-only; old presets with edit=true load safely but are not surfaced as active modes.
        edit = try container.decodeIfPresent(Bool.self, forKey: .edit) ?? false
        review = try container.decodeIfPresent(Bool.self, forKey: .review) ?? true
    }

    /// Returns true if at least one mode is enabled
    var hasEnabledModes: Bool {
        chat || plan || review
    }

    /// Returns a user-friendly string describing the enabled modes
    package var displayString: String {
        var modes: [String] = []
        if chat { modes.append("Chat") }
        if plan { modes.append("Plan") }
        if review { modes.append("Review") }

        if modes.isEmpty {
            return "No modes enabled"
        } else if modes.count == 3 {
            return "All modes"
        } else {
            return modes.joined(separator: ", ")
        }
    }
}

// MARK: - ChatPresetMappings

/// Maps each mode to a specific chat preset ID
package struct ChatPresetMappings: Codable, Equatable {
    package var chatPresetID: UUID?
    package var planPresetID: UUID?
    var editPresetID: UUID?
    package var reviewPresetID: UUID?

    package init(chatPresetID: UUID? = nil, planPresetID: UUID? = nil, editPresetID: UUID? = nil, reviewPresetID: UUID? = nil) {
        self.chatPresetID = chatPresetID
        self.planPresetID = planPresetID
        self.editPresetID = editPresetID
        self.reviewPresetID = reviewPresetID
    }

    private enum CodingKeys: String, CodingKey {
        case chatPresetID, planPresetID, editPresetID, reviewPresetID
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(chatPresetID, forKey: .chatPresetID)
        try container.encodeIfPresent(planPresetID, forKey: .planPresetID)
        try container.encodeIfPresent(reviewPresetID, forKey: .reviewPresetID)
    }

    /// Custom decoder for backward compatibility when new mappings are added
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatPresetID = try container.decodeIfPresent(UUID.self, forKey: .chatPresetID)
        planPresetID = try container.decodeIfPresent(UUID.self, forKey: .planPresetID)
        editPresetID = try container.decodeIfPresent(UUID.self, forKey: .editPresetID)
        reviewPresetID = try container.decodeIfPresent(UUID.self, forKey: .reviewPresetID)
    }

    /// Get the chat preset ID for a specific mode
    package func presetID(for mode: String) -> UUID? {
        switch mode.lowercased() {
        case "chat": chatPresetID
        case "plan": planPresetID
        case "review": reviewPresetID
        default: nil
        }
    }

    /// Set the chat preset ID for a specific mode
    mutating func setPresetID(_ id: UUID?, for mode: String) {
        switch mode.lowercased() {
        case "chat": chatPresetID = id
        case "plan": planPresetID = id
        case "review": reviewPresetID = id
        default: break
        }
    }
}
