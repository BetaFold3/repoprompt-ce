import Foundation

enum CodexServiceTierVariantCatalog {
    static let fastServiceTier = "fast"
    static let fastCostWarningText = "Fast service tier uses your usage limits about 2× faster."

    static func isFastEligible(
        baseModelID: String,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> Bool {
        capabilities.capability(forBase: baseModelID)?.speedTiers.contains(fastServiceTier) == true
    }

    static func isFastVariant(
        rawModel: String?,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> Bool {
        let specifier = CodexModelSpecifier(raw: rawModel, capabilities: capabilities)
        guard let baseModel = specifier.baseModel else { return false }
        return supportedServiceTier(
            baseModelID: baseModel,
            serviceTier: specifier.serviceTier,
            capabilities: capabilities
        ) == fastServiceTier
    }

    static func serviceTierAwareBaseID(
        for rawModel: String,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let specifier = CodexModelSpecifier(raw: trimmed, capabilities: capabilities)
        var baseID = (specifier.baseModel ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tier = supportedServiceTier(
            baseModelID: baseID,
            serviceTier: specifier.serviceTier,
            capabilities: capabilities
        ) {
            baseID += "-\(tier)"
        }
        return baseID
    }

    static func supportedServiceTier(
        baseModelID: String,
        serviceTier: String?,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> String? {
        guard let serviceTier else { return nil }
        let normalizedTier = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedTier == fastServiceTier,
              isFastEligible(baseModelID: baseModelID, capabilities: capabilities)
        else { return nil }
        return normalizedTier
    }

    static func fastVariantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> String? {
        let baseModelID = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModelID.isEmpty,
              isFastEligible(baseModelID: baseModelID, capabilities: capabilities)
        else { return nil }
        if let reasoningEffort {
            return "\(baseModelID)-\(fastServiceTier)-\(reasoningEffort.rawValue)"
        }
        return "\(baseModelID)-\(fastServiceTier)"
    }
}
