import Foundation

struct CodexModelSpecifier: Equatable {
    typealias ReasoningEffort = CodexReasoningEffort

    let baseModel: String?
    let reasoningEffort: ReasoningEffort?
    let serviceTier: String?
    private let supportedServiceTier: String?

    init(
        baseModel: String?,
        reasoningEffort: ReasoningEffort?,
        serviceTier: String? = nil,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) {
        let normalizedBase = baseModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedBase, !normalizedBase.isEmpty, normalizedBase.lowercased() != "default" {
            self.baseModel = normalizedBase
        } else {
            self.baseModel = nil
        }
        self.reasoningEffort = self.baseModel == nil ? nil : reasoningEffort
        self.serviceTier = self.baseModel == nil ? nil : serviceTier
        if let baseModel = self.baseModel {
            supportedServiceTier = CodexServiceTierVariantCatalog.supportedServiceTier(
                baseModelID: baseModel,
                serviceTier: self.serviceTier,
                capabilities: capabilities
            )
        } else {
            supportedServiceTier = nil
        }
    }

    init(raw: String?, capabilities: CodexModelCapabilitySnapshot = .shared) {
        let parts = Self.splitLegacyModelID(raw, capabilities: capabilities)
        self.init(
            baseModel: parts.baseModel,
            reasoningEffort: parts.reasoningEffort,
            serviceTier: parts.serviceTier,
            capabilities: capabilities
        )
    }

    static func splitLegacyModelID(
        _ raw: String?,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> (baseModel: String?, reasoningEffort: ReasoningEffort?, serviceTier: String?) {
        guard
            let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            raw.lowercased() != "default"
        else {
            return (nil, nil, nil)
        }

        let lowered = raw.lowercased()
        if let exact = capabilities.capability(forBase: lowered) {
            return (exact.base, nil, nil)
        }

        for capability in capabilities.knownBasesLongestFirst {
            let base = capability.base
            let baseLowered = base.lowercased()
            for tier in [CodexServiceTierVariantCatalog.fastServiceTier] {
                let tierPrefix = "\(baseLowered)-\(tier)"
                if lowered == tierPrefix {
                    return (base, nil, tier)
                }
                if lowered.hasPrefix("\(tierPrefix)-"),
                   let effort = ReasoningEffort.parse(String(lowered.dropFirst(tierPrefix.count + 1))),
                   !effort.isExtended || capability.efforts.contains(effort)
                {
                    return (base, effort, tier)
                }
            }
            if lowered.hasPrefix("\(baseLowered)-"),
               let effort = ReasoningEffort.parse(String(lowered.dropFirst(baseLowered.count + 1))),
               !effort.isExtended || capability.efforts.contains(effort)
            {
                return (base, effort, nil)
            }
        }

        // Preserve legacy broad decoding for ordinary efforts. Extended efforts require
        // capability evidence so exact IDs such as gpt-5.1-codex-max remain intact.
        let ordinarySuffixes: [(String, ReasoningEffort)] = [
            ("-xhigh", .xhigh),
            ("-medium", .medium),
            ("-minimal", .minimal),
            ("-high", .high),
            ("-none", .none),
            ("-low", .low)
        ]
        var base = raw
        var effort: ReasoningEffort?
        for (suffix, candidateEffort) in ordinarySuffixes where lowered.hasSuffix(suffix) {
            let candidate = String(raw.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                base = candidate
                effort = candidateEffort
            }
            break
        }

        var tier: String?
        let baseLowered = base.lowercased()
        for knownTier in [CodexServiceTierVariantCatalog.fastServiceTier] {
            let tierSuffix = "-\(knownTier)"
            if baseLowered.hasSuffix(tierSuffix) {
                let strippedBase = String(base.dropLast(tierSuffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !strippedBase.isEmpty {
                    base = strippedBase
                    tier = knownTier
                    break
                }
            }
        }
        return (base, effort, tier)
    }

    var cliModelArgs: [String] {
        guard let baseModel else { return [] }
        return ["--model", baseModel]
    }

    var cliReasoningConfigArgs: [String] {
        guard let reasoningEffort else { return [] }
        return ["-c", "model_reasoning_effort=\(reasoningEffort.rawValue)"]
    }

    var cliServiceTierConfigArgs: [String] {
        guard let supportedServiceTier else { return [] }
        return ["-c", "service_tier=\(supportedServiceTier)"]
    }

    var appServerModelParam: String? {
        baseModel
    }

    var appServerEffortParam: String? {
        reasoningEffort?.rawValue
    }

    var appServerServiceTierParam: String? {
        supportedServiceTier
    }
}
