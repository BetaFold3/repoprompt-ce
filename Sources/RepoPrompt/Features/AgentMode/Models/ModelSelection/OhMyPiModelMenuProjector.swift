import Foundation

/// Presentation-only hierarchy for Oh My Pi model catalogs.
///
/// Grouping is derived exclusively from exact wire IDs and is presentational only. Display
/// names are retained only for standalone leaf labels and never participate in parsing or family
/// corroboration. Thinking-accessory eligibility is derived per leaf from its effort suffix.
enum OhMyPiModelMenuProjector {
    struct Input: Hashable {
        let sourceID: String
        let wireID: String
        let displayName: String
    }

    enum Effort: String, CaseIterable, Hashable {
        case none
        case minimal
        case low
        case medium
        case high
        case xhigh
        case max

        var displayName: String {
            switch self {
            case .none: "None"
            case .minimal: "Minimal"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .xhigh: "X-High"
            case .max: "Max"
            }
        }
    }

    struct Leaf: Identifiable, Hashable {
        let sourceID: String
        let wireID: String
        let displayName: String
        let title: String
        let effort: Effort?
        let isFast: Bool
        let allowsThinkingAccessory: Bool

        var id: String {
            sourceID
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

        var allLeaves: [Leaf] {
            modelGroups.flatMap(\.allLeaves)
        }
    }

    struct Projection: Hashable {
        let rootLeaves: [Leaf]
        let namespaceGroups: [NamespaceGroup]

        var allLeaves: [Leaf] {
            rootLeaves + namespaceGroups.flatMap(\.allLeaves)
        }
    }

    private struct ParsedEntry {
        let input: Input
        let namespace: String
        let modelSegment: String
        let base: String
        let effort: Effort?
        let isFast: Bool
        let strippedSuffix: Bool
    }

    private struct SemanticSlot: Hashable {
        let effort: Effort?
        let isFast: Bool
    }

    private final class ProjectionCache: @unchecked Sendable {
        private struct Entry {
            let inputs: [Input]
            let projection: Projection
        }

        private let lock = NSLock()
        private var entries: [Entry] = []
        private let capacity = 8

        func projection(
            for inputs: [Input],
            build: () -> Projection
        ) -> Projection {
            lock.lock()
            if let index = entries.firstIndex(where: { $0.inputs == inputs }) {
                let entry = entries.remove(at: index)
                entries.insert(entry, at: 0)
                lock.unlock()
                return entry.projection
            }
            lock.unlock()

            let projection = build()

            lock.lock()
            if let existing = entries.first(where: { $0.inputs == inputs }) {
                lock.unlock()
                return existing.projection
            }
            entries.insert(Entry(inputs: inputs, projection: projection), at: 0)
            if entries.count > capacity {
                entries.removeLast(entries.count - capacity)
            }
            lock.unlock()
            return projection
        }
    }

    private static let cache = ProjectionCache()

    static func project(_ inputs: [Input]) -> Projection {
        cache.projection(for: inputs) {
            buildProjection(inputs)
        }
    }

    private static func buildProjection(_ inputs: [Input]) -> Projection {
        var rootLeaves: [Leaf] = []
        var entriesByNamespace: [String: [ParsedEntry]] = [:]

        for input in inputs {
            guard let slash = input.wireID.firstIndex(of: "/") else {
                rootLeaves.append(standaloneLeaf(input: input, modelSegment: input.wireID))
                continue
            }

            let namespace = String(input.wireID[..<slash])
            let modelStart = input.wireID.index(after: slash)
            let modelSegment = String(input.wireID[modelStart...])
            let suffix = parseSuffix(in: modelSegment)
            entriesByNamespace[namespace, default: []].append(ParsedEntry(
                input: input,
                namespace: namespace,
                modelSegment: modelSegment,
                base: suffix.base,
                effort: suffix.effort,
                isFast: suffix.isFast,
                strippedSuffix: suffix.stripped
            ))
        }

        rootLeaves.sort(by: leafPrecedes)

        let namespaceGroups = entriesByNamespace.keys
            .sorted(by: stringPrecedes)
            .map { namespace in
                NamespaceGroup(
                    namespace: namespace,
                    modelGroups: modelGroups(for: entriesByNamespace[namespace] ?? [])
                )
            }

        return Projection(rootLeaves: rootLeaves, namespaceGroups: namespaceGroups)
    }

    private static func modelGroups(for entries: [ParsedEntry]) -> [ModelGroup] {
        var entriesByBase: [String: [ParsedEntry]] = [:]
        for entry in entries {
            entriesByBase[entry.base, default: []].append(entry)
        }

        var groups: [ModelGroup] = []
        for baseEntries in entriesByBase.values {
            guard let representative = baseEntries.first else { continue }
            if qualifiesAsFamily(baseEntries) {
                let normalLeaves = baseEntries
                    .filter { !$0.isFast }
                    .map(familyLeaf)
                    .sorted(by: familyLeafPrecedes)
                let fastLeaves = baseEntries
                    .filter(\.isFast)
                    .map(familyLeaf)
                    .sorted(by: familyLeafPrecedes)
                groups.append(ModelGroup(
                    id: "family:\(representative.base)",
                    title: representative.base,
                    normalLeaves: normalLeaves,
                    fastLeaves: fastLeaves,
                    isFamily: true
                ))
            } else {
                groups.append(contentsOf: baseEntries.map { entry in
                    let leaf = standaloneLeaf(input: entry.input, modelSegment: entry.modelSegment)
                    return ModelGroup(
                        id: "leaf:\(entry.input.sourceID):\(entry.input.wireID)",
                        title: leaf.title,
                        normalLeaves: [leaf],
                        fastLeaves: [],
                        isFamily: false
                    )
                })
            }
        }

        return groups.sorted { lhs, rhs in
            let titleOrder = ModelPickerStringOrdering.compare(
                lhs.title,
                rhs.title,
                caseInsensitiveASCII: true
            )
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            let lhsWire = lhs.allLeaves.first?.wireID ?? ""
            let rhsWire = rhs.allLeaves.first?.wireID ?? ""
            if lhsWire != rhsWire {
                return stringPrecedes(lhsWire, rhsWire)
            }
            return stringPrecedes(lhs.id, rhs.id)
        }
    }

    private static func qualifiesAsFamily(_ entries: [ParsedEntry]) -> Bool {
        var slots = Set<SemanticSlot>()
        for entry in entries {
            guard slots.insert(SemanticSlot(effort: entry.effort, isFast: entry.isFast)).inserted else {
                return false
            }
        }

        let normalSlots = Set(entries.filter { !$0.isFast }.map(\.effort))
        let fastSlots = Set(entries.filter(\.isFast).map(\.effort))
        if normalSlots.count >= 2 || fastSlots.count >= 2 {
            return true
        }

        let hasBareBase = entries.contains {
            !$0.strippedSuffix && !$0.isFast && $0.effort == nil
        }
        if hasBareBase, entries.contains(where: \.strippedSuffix) {
            return true
        }

        return !normalSlots.isDisjoint(with: fastSlots)
    }

    private static func parseSuffix(
        in modelSegment: String
    ) -> (base: String, effort: Effort?, isFast: Bool, stripped: Bool) {
        var base = modelSegment
        var effort: Effort?
        var isFast = false
        var stripped = false

        guard let first = trailingToken(in: base) else {
            return (base, nil, false, false)
        }

        if first.token.caseInsensitiveCompare("fast") == .orderedSame {
            base = first.base
            isFast = true
            stripped = true
            if let second = trailingToken(in: base),
               let parsedEffort = Effort(rawValue: second.token.lowercased())
            {
                base = second.base
                effort = parsedEffort
            }
        } else if let parsedEffort = Effort(rawValue: first.token.lowercased()) {
            base = first.base
            effort = parsedEffort
            stripped = true
            if let second = trailingToken(in: base),
               second.token.caseInsensitiveCompare("fast") == .orderedSame
            {
                base = second.base
                isFast = true
            }
        }

        return (base, effort, isFast, stripped)
    }

    private static func trailingToken(in value: String) -> (base: String, token: String)? {
        guard let hyphen = value.lastIndex(of: "-") else { return nil }
        let tokenStart = value.index(after: hyphen)
        let base = String(value[..<hyphen])
        let token = String(value[tokenStart...])
        guard !base.isEmpty, !token.isEmpty else { return nil }
        return (base, token)
    }

    private static func familyLeaf(_ entry: ParsedEntry) -> Leaf {
        Leaf(
            sourceID: entry.input.sourceID,
            wireID: entry.input.wireID,
            displayName: entry.input.displayName,
            title: entry.effort?.displayName ?? "Default",
            effort: entry.effort,
            isFast: entry.isFast,
            allowsThinkingAccessory: !wireIDEncodesExplicitEffort(entry)
        )
    }

    private static func wireIDEncodesExplicitEffort(_ entry: ParsedEntry) -> Bool {
        entry.effort != nil
    }

    private static func standaloneLeaf(input: Input, modelSegment: String) -> Leaf {
        let title: String
        if input.displayName.isEmpty {
            title = modelSegment
        } else if let slash = input.wireID.firstIndex(of: "/") {
            let prefix = String(input.wireID[...slash])
            if input.displayName.lowercased().hasPrefix(prefix.lowercased()) {
                let suffixStart = input.displayName.index(
                    input.displayName.startIndex,
                    offsetBy: prefix.count
                )
                let stripped = String(input.displayName[suffixStart...])
                title = stripped.isEmpty ? modelSegment : stripped
            } else {
                title = input.displayName
            }
        } else {
            title = input.displayName
        }

        return Leaf(
            sourceID: input.sourceID,
            wireID: input.wireID,
            displayName: input.displayName,
            title: title,
            effort: nil,
            isFast: false,
            allowsThinkingAccessory: true
        )
    }

    private static func familyLeafPrecedes(_ lhs: Leaf, _ rhs: Leaf) -> Bool {
        let lhsRank = lhs.effort.flatMap { Effort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rhsRank = rhs.effort.flatMap { Effort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.wireID != rhs.wireID {
            return stringPrecedes(lhs.wireID, rhs.wireID)
        }
        return stringPrecedes(lhs.sourceID, rhs.sourceID)
    }

    private static func leafPrecedes(_ lhs: Leaf, _ rhs: Leaf) -> Bool {
        let titleOrder = ModelPickerStringOrdering.compare(
            lhs.title,
            rhs.title,
            caseInsensitiveASCII: true
        )
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        if lhs.wireID != rhs.wireID {
            return stringPrecedes(lhs.wireID, rhs.wireID)
        }
        return stringPrecedes(lhs.sourceID, rhs.sourceID)
    }

    private static func stringPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        ModelPickerStringOrdering.precedes(lhs, rhs)
    }
}
