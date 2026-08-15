import Foundation

/// Shared Oh My Pi picker projection.
///
/// OMP owns flattened wire IDs. RepoPrompt only groups them by the first path
/// segment and always keeps the complete canonical wire ID on the selected model.
enum OhMyPiModelMenuBuilder {
    struct Leaf: Identifiable, Hashable {
        let model: AIModel
        let title: String

        var id: String {
            model.rawValue
        }
    }

    struct NamespaceGroup: Identifiable, Hashable {
        let namespace: String
        let leaves: [Leaf]

        var id: String {
            namespace.lowercased()
        }
    }

    static func groups(for models: [AIModel]) -> [NamespaceGroup] {
        let entries = models.compactMap { model -> (namespace: String, leaf: Leaf)? in
            guard case let .ohMyPiCustom(rawValue) = model, !rawValue.isEmpty else {
                return nil
            }
            let namespace = String(rawValue.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let normalizedNamespace = namespace.isEmpty ? rawValue : namespace
            return (
                normalizedNamespace,
                Leaf(model: model, title: leafTitle(model: model, namespace: normalizedNamespace))
            )
        }

        let grouped = Dictionary(grouping: entries, by: \.namespace)
        return grouped.keys
            .sorted { ModelPickerStringOrdering.precedes($0, $1) }
            .map { namespace in
                let leaves = (grouped[namespace] ?? [])
                    .map(\.leaf)
                    .sorted {
                        let titleOrder = ModelPickerStringOrdering.compare(
                            $0.title,
                            $1.title,
                            caseInsensitiveASCII: true
                        )
                        if titleOrder != .orderedSame {
                            return titleOrder == .orderedAscending
                        }
                        return ModelPickerStringOrdering.precedes(
                            $0.model.modelName,
                            $1.model.modelName,
                            caseInsensitiveASCII: false
                        )
                    }
                return NamespaceGroup(namespace: namespace, leaves: leaves)
            }
    }

    static func collapsedLabel(for model: AIModel) -> String? {
        guard case let .ohMyPiCustom(rawValue) = model else { return nil }
        return "OMP/\(rawValue)"
    }

    private static func leafTitle(model: AIModel, namespace: String) -> String {
        let displayName = model.displayName
        let prefix = namespace + "/"
        if displayName.lowercased().hasPrefix(prefix.lowercased()) {
            let index = displayName.index(displayName.startIndex, offsetBy: prefix.count)
            let stripped = String(displayName[index...])
            if !stripped.isEmpty {
                return stripped
            }
        }

        guard case let .ohMyPiCustom(rawValue) = model else { return displayName }
        if rawValue.lowercased().hasPrefix(prefix.lowercased()) {
            let index = rawValue.index(rawValue.startIndex, offsetBy: prefix.count)
            let stripped = String(rawValue[index...])
            if !stripped.isEmpty {
                return stripped
            }
        }
        return displayName.isEmpty ? rawValue : displayName
    }
}
