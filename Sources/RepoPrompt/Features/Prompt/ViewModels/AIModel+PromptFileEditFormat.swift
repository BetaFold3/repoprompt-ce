import Foundation
import RepoPromptAgentCore

// App-owned: model choice depends on `PromptViewModel.FileEditFormat`.

extension AIModel {
    static func findBestAvailableModel(
        in availableModels: [AIModel],
        desiredFormat: PromptViewModel.FileEditFormat,
        priorities: [AIModel]
    ) -> AIModel? {
        // Filter out models that are not yet available
        let currentlyAvailableModels = availableModels.filter(\.isAvailable)

        // 1) Try the official priority list
        for candidate in priorities {
            guard let match = currentlyAvailableModels.first(where: { $0 == candidate }) else { continue }
            switch desiredFormat {
            case .diff:
                if match.isModelCapableOfDiff { return match }
            case .whole, .none:
                return match
            }
        }
        // 2) If none found in the list, fallback to ANY leftover model in user's environment
        //    e.g. custom provider or openrouterCustom not in the arrays
        //    Skip service tier variants to prevent accidental selection of explicit tiers
        for possible in currentlyAvailableModels {
            if possible.isOpenAIServiceTierVariant { continue }
            if !priorities.contains(possible) {
                // This means it's "unlisted."
                // Check if it meets the diff requirement if needed:
                switch desiredFormat {
                case .diff:
                    if possible.isModelCapableOfDiff { return possible }
                case .whole, .none:
                    return possible
                }
            }
        }
        // 3) Return nil if truly nothing is suitable
        return nil
    }
}
