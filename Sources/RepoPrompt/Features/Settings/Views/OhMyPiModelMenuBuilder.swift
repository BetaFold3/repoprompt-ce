import Foundation

/// AI-model adapter for the shared Oh My Pi presentation projector.
enum OhMyPiModelMenuBuilder {
    struct Leaf: Identifiable, Hashable {
        let model: AIModel
        let title: String
        let allowsThinkingAccessory: Bool

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
        let shape: OhMyPiModelMenuProjector.ModelGroup.Shape

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
            return Leaf(
                model: model,
                title: projectedLeaf.title,
                allowsThinkingAccessory: projectedLeaf.allowsThinkingAccessory
            )
        }

        func modelGroup(_ projectedGroup: OhMyPiModelMenuProjector.ModelGroup) -> ModelGroup {
            ModelGroup(
                id: projectedGroup.id,
                title: projectedGroup.title,
                normalLeaves: projectedGroup.normalLeaves.compactMap(leaf),
                fastLeaves: projectedGroup.fastLeaves.compactMap(leaf),
                isFamily: projectedGroup.isFamily,
                shape: projectedGroup.shape
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

    @MainActor
    static func stableMenuItems(
        for models: [AIModel],
        destination: ModelDestination,
        titleTransform: (String) -> String = { $0 },
        onModelCommit: @escaping (AIModel) -> Void
    ) -> [StableMenuItem] {
        func modelItem(_ leaf: Leaf, title titleOverride: String? = nil) -> StableMenuItem {
            let title = titleTransform(titleOverride ?? leaf.title)
            guard leaf.allowsThinkingAccessory,
                  destination.hasThinkingAccessory,
                  let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: leaf.model)
            else {
                return .action(
                    title,
                    isSelected: leaf.model.rawValue == destination.currentRawValue
                ) {
                    onModelCommit(leaf.model)
                }
            }

            return .submenu(
                title,
                isSelected: leaf.model.rawValue == destination.currentRawValue,
                items: OhMyPiThinkingMenuBuilder.stableMenuItems(
                    exactModelID: exactModelID,
                    destination: destination,
                    onBeforeApply: {
                        onModelCommit(leaf.model)
                        return true
                    }
                )
            )
        }

        func modelGroupItems(_ group: ModelGroup) -> [StableMenuItem] {
            guard group.isFamily else {
                return [group.normalLeaves.first.map { modelItem($0) } ?? .separator]
            }
            if group.shape.collapsesNormal, let normal = group.normalLeaves.first {
                var items = [modelItem(normal, title: group.title)]
                if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                    items.append(modelItem(fast, title: "\(group.title) Fast"))
                } else if !group.fastLeaves.isEmpty {
                    items.append(.submenu(
                        "\(group.title) Fast",
                        items: group.fastLeaves.map { modelItem($0) }
                    ))
                }
                return items
            }
            var items = group.normalLeaves.map { modelItem($0) }
            if group.shape.collapsesFast, let fast = group.fastLeaves.first {
                items.append(modelItem(fast, title: "Fast"))
            } else if !group.fastLeaves.isEmpty {
                items.append(.submenu(
                    "Fast",
                    items: group.fastLeaves.map { modelItem($0) }
                ))
            }
            return [.submenu(group.title, items: items)]
        }

        let projection = projection(for: models)
        var items = projection.rootLeaves.map { modelItem($0) }
        items.append(contentsOf: projection.namespaceGroups.map { namespaceGroup in
            .submenu(
                namespaceGroup.namespace,
                items: namespaceGroup.modelGroups.flatMap(modelGroupItems)
            )
        })
        if let header = OhMyPiThinkingSweepStatusPresentation.headerItem(
            OhMyPiThinkingCapabilityResolver.shared.sweepStatus
        ) {
            items.insert(header, at: 0)
        }
        return items
    }

    static func groups(for models: [AIModel]) -> [NamespaceGroup] {
        projection(for: models).namespaceGroups
    }

    static func collapsedLabel(for model: AIModel) -> String? {
        guard case let .ohMyPiCustom(rawValue) = model else { return nil }
        return "OMP/\(rawValue)"
    }
}
