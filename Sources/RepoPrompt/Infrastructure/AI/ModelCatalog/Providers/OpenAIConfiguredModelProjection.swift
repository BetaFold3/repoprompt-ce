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
