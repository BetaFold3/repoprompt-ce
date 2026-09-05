import Foundation

enum OpenAIConfiguredModelProjection {
    static func models(
        rows: [OpenAIAPIModelMetadata],
        visibleModelIDs: [String],
        typedCustomModelID: String?,
        isOfficialOpenAIHost: Bool,
        staticWireModelNames: Set<String>
    ) -> Set<AIModel> {
        let typedModelID = normalizedModelID(typedCustomModelID)
        guard isOfficialOpenAIHost else {
            guard let typedModelID else { return [] }
            return [.openaiCustom(name: typedModelID)]
        }

        let visibleIDs = Set(visibleModelIDs.compactMap { normalizedModelID($0) })
        var projectedRowsByID: [String: OpenAIAPIModelMetadata] = [:]
        for row in rows
            where !staticWireModelNames.contains(row.id)
            && (visibleIDs.contains(row.id) || row.id == typedModelID)
        {
            projectedRowsByID[row.id] = row
        }

        var models = Set(projectedRowsByID.values.flatMap { projectedModels(for: $0) })
        let emittedTypedConfiguredChoice = typedModelID.map { typedModelID in
            models.contains { model in
                guard case let .openAIConfigured(selection) = model else { return false }
                return selection.modelID == typedModelID
            }
        } ?? false
        if let typedModelID, !emittedTypedConfiguredChoice {
            models.formUnion(AIModel.openAICustomResponsesVariants(for: typedModelID))
        }
        return models
    }

    static func projectedMetadataRowCount(
        rows: [OpenAIAPIModelMetadata],
        visibleModelIDs: [String],
        typedCustomModelID: String?,
        isOfficialOpenAIHost: Bool,
        staticWireModelNames: Set<String>
    ) -> Int {
        let projected = models(
            rows: rows,
            visibleModelIDs: visibleModelIDs,
            typedCustomModelID: typedCustomModelID,
            isOfficialOpenAIHost: isOfficialOpenAIHost,
            staticWireModelNames: staticWireModelNames
        )
        return Set(projected.compactMap { model -> String? in
            guard case let .openAIConfigured(selection) = model else { return nil }
            return selection.modelID
        }).count
    }

    static func serviceTierVariants(
        for baseModels: Set<AIModel>,
        rows: [OpenAIAPIModelMetadata],
        enabled: Bool
    ) -> Set<AIModel> {
        guard enabled else { return [] }
        let tiersByModelID = Dictionary(
            rows.map { ($0.id, $0.serviceTiers) },
            uniquingKeysWith: { _, latest in latest }
        )
        var variants = Set<AIModel>()

        for base in baseModels {
            guard case let .openAIConfigured(selection) = base else { continue }
            variants.insert(.openAIServiceTierVariant(base: base, tier: "default"))
            for tier in tiersByModelID[selection.modelID] ?? [] {
                variants.insert(.openAIServiceTierVariant(base: base, tier: tier.rawValue))
            }
        }
        return variants
    }

    static func legacyServiceTierVariants(
        for baseModels: Set<AIModel>,
        enabled: Bool
    ) -> Set<AIModel> {
        guard enabled else { return [] }
        let eligibleBases = baseModels.filter { model in
            guard model.providerType == .openAI,
                  model.usesResponsesAPI,
                  !model.isOpenAIServiceTierVariant
            else {
                return false
            }
            if case .openAIConfigured = model {
                return false
            }
            return true
        }

        return Set(eligibleBases.flatMap { base in
            [
                AIModel.openAIServiceTierVariant(base: base, tier: "default"),
                AIModel.openAIServiceTierVariant(base: base, tier: "flex"),
                AIModel.openAIServiceTierVariant(base: base, tier: "priority")
            ]
        })
    }

    static func staticModels(
        _ models: Set<AIModel>,
        visibleModelIDs: [String],
        isOfficialOpenAIHost: Bool,
        hasSuccessfulLiveRefresh: Bool
    ) -> Set<AIModel> {
        guard isOfficialOpenAIHost, hasSuccessfulLiveRefresh else {
            return models
        }
        let visibleIDs = Set(visibleModelIDs.compactMap { normalizedModelID($0) })
        return Set(models.filter {
            visibleIDs.contains(AIModel.staticOpenAIRequestWireModelID(for: $0))
        })
    }

    private static func projectedModels(
        for descriptor: OpenAIAPIModelMetadata
    ) -> [AIModel] {
        guard descriptor.protocols.contains(.responses),
              let reasoning = descriptor.reasoning
        else {
            return []
        }

        return reasoning.modes.flatMap { mode -> [AIModel] in
            guard let reasoningMode = OpenAIReasoningMode(rawValue: mode.rawValue) else {
                return []
            }
            return reasoning.efforts.compactMap { effort in
                guard let reasoningEffort = CodexReasoningEffort(rawValue: effort.rawValue),
                      let selection = OpenAIConfiguredModelSelection(
                          modelID: descriptor.id,
                          reasoningMode: reasoningMode,
                          reasoningEffort: reasoningEffort,
                          supportsStreaming: descriptor.supportsStreaming
                      )
                else {
                    return nil
                }
                return .openAIConfigured(selection: selection)
            }
        }
    }

    private static func normalizedModelID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
