import Foundation

/// AI-model adapter for the shared Oh My Pi presentation projector.
enum OhMyPiModelMenuBuilder {
    struct Leaf: Identifiable, Hashable {
        let model: AIModel
        let title: String

        var id: String {
            model.rawValue
        }
    }

    struct ModelGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let normalLeaves: [Leaf]
        let fastLeaves: [Leaf]
        let isFamily: Bool

        var allLeaves: [Leaf] {
            normalLeaves + fastLeaves
        }
    }

    struct NamespaceGroup: Identifiable, Hashable {
        let namespace: String
        let modelGroups: [ModelGroup]

        var id: String {
            namespace
        }

        var leaves: [Leaf] {
            modelGroups.flatMap(\.allLeaves)
        }
    }

    struct Projection: Hashable {
        let rootLeaves: [Leaf]
        let namespaceGroups: [NamespaceGroup]

        var allLeaves: [Leaf] {
            rootLeaves + namespaceGroups.flatMap(\.leaves)
        }
    }

    static func projection(for models: [AIModel]) -> Projection {
        let ohMyPiModels = models.filter {
            if case .ohMyPiCustom = $0 {
                return true
            }
            return false
        }
        let indexed = ohMyPiModels.enumerated().map {
            (sourceID: String($0.offset), model: $0.element)
        }
        let modelsBySourceID = Dictionary(uniqueKeysWithValues: indexed.map { ($0.sourceID, $0.model) })
        let projected = OhMyPiModelMenuProjector.project(indexed.map { entry in
            OhMyPiModelMenuProjector.Input(
                sourceID: entry.sourceID,
                wireID: entry.model.modelName,
                displayName: entry.model.displayName
            )
        })

        func leaf(_ projectedLeaf: OhMyPiModelMenuProjector.Leaf) -> Leaf? {
            guard let model = modelsBySourceID[projectedLeaf.sourceID] else { return nil }
            return Leaf(model: model, title: projectedLeaf.title)
        }

        func modelGroup(_ projectedGroup: OhMyPiModelMenuProjector.ModelGroup) -> ModelGroup {
            ModelGroup(
                id: projectedGroup.id,
                title: projectedGroup.title,
                normalLeaves: projectedGroup.normalLeaves.compactMap(leaf),
                fastLeaves: projectedGroup.fastLeaves.compactMap(leaf),
                isFamily: projectedGroup.isFamily
            )
        }

        return Projection(
            rootLeaves: projected.rootLeaves.compactMap(leaf),
            namespaceGroups: projected.namespaceGroups.map { namespaceGroup in
                NamespaceGroup(
                    namespace: namespaceGroup.namespace,
                    modelGroups: namespaceGroup.modelGroups.map(modelGroup)
                )
            }
        )
    }

    static func groups(for models: [AIModel]) -> [NamespaceGroup] {
        projection(for: models).namespaceGroups
    }

    static func collapsedLabel(for model: AIModel) -> String? {
        guard case let .ohMyPiCustom(rawValue) = model else { return nil }
        return "OMP/\(rawValue)"
    }
}
