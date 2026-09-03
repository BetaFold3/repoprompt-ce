import Foundation

enum ClaudeModelFamilyCatalog {
    enum APIRequestShape: Hashable {
        case adaptiveEffort
        case legacy
    }

    struct Family: Hashable {
        enum ID: String {
            case fable
            case opus
            case sonnet
        }

        /// Full family identity: one curated row per `(id, major)`.
        /// All family comparisons must use this key (or the equivalent
        /// `anchor` string), never `id` alone, so a future curated major-6
        /// row is a distinct family from the major-5 row of the same name.
        struct Identity: Hashable {
            let id: ID
            let major: Int
        }

        let id: ID
        let major: Int
        let supportedEfforts: [ClaudeCodeEffortLevel]
        let xhighEligible: Bool
        /// Known Claude Code CLI/sidebar/discovery context window.
        let contextWindowTokens: Int?
        /// API-known fallback metadata for the native Anthropic API path.
        /// Populated only for families whose direct-API contract has been
        /// live-verified (the plan's U3 gate): Fable today; Opus preserves its
        /// pre-Phase-3 nil API-known limits and Sonnet stays nil until probed.
        let apiKnownContextWindowTokens: Int?
        let apiKnownMaxOutputTokens: Int?
        let defaultMaxTokens: Int?
        let apiRequestShape: APIRequestShape

        var identity: Identity {
            Identity(id: id, major: major)
        }

        var anchor: String {
            "claude-\(id.rawValue)-\(major)"
        }

        fileprivate var familyDisplayName: String {
            switch id {
            case .fable: "Fable"
            case .opus: "Opus"
            case .sonnet: "Sonnet"
            }
        }
    }

    struct PointRelease: Hashable {
        let family: Family
        let minor: Int
        let dateSuffix: String?
        let rawModelID: String

        /// Dated releases are always visibly date-qualified so a dated twin
        /// (e.g. `claude-fable-5-1-20260315`) can never render an identical
        /// label to its undated static sibling.
        var generatedDisplayName: String {
            let base = "\(family.familyDisplayName) \(family.major).\(minor)"
            guard let dateSuffix else { return base }
            return "\(base) (\(dateSuffix))"
        }
    }

    static let families: [Family] = [
        Family(
            id: .fable,
            major: 5,
            supportedEfforts: [.low, .medium, .high, .max, .xhigh],
            xhighEligible: true,
            contextWindowTokens: 1_000_000,
            apiKnownContextWindowTokens: 1_000_000,
            apiKnownMaxOutputTokens: 128_000,
            defaultMaxTokens: 16000,
            apiRequestShape: .adaptiveEffort
        ),
        Family(
            id: .opus,
            major: 5,
            supportedEfforts: [.low, .medium, .high, .max, .xhigh],
            xhighEligible: true,
            contextWindowTokens: 1_000_000,
            apiKnownContextWindowTokens: nil,
            apiKnownMaxOutputTokens: nil,
            defaultMaxTokens: nil,
            apiRequestShape: .adaptiveEffort
        ),
        Family(
            id: .sonnet,
            major: 5,
            supportedEfforts: [.low, .medium, .high, .max, .xhigh],
            xhighEligible: true,
            contextWindowTokens: 1_000_000,
            apiKnownContextWindowTokens: nil,
            apiKnownMaxOutputTokens: nil,
            defaultMaxTokens: nil,
            apiRequestShape: .legacy
        )
    ]

    static func family(for modelID: String) -> Family? {
        if let exact = families.first(where: { $0.anchor == modelID }) {
            return exact
        }
        return pointRelease(modelID)?.family
    }

    static func pointRelease(_ modelID: String) -> PointRelease? {
        for family in families {
            let prefix = "\(family.anchor)-"
            guard modelID.hasPrefix(prefix) else { continue }

            let suffix = modelID.dropFirst(prefix.count)
            let components = suffix.split(separator: "-", omittingEmptySubsequences: false)
            guard components.count == 1 || components.count == 2,
                  let minorComponent = components.first,
                  isASCIIInteger(minorComponent),
                  let minor = Int(minorComponent)
            else {
                return nil
            }

            let dateSuffix: String?
            if components.count == 2 {
                let dateComponent = components[1]
                guard dateComponent.count == 8, isASCIIInteger(dateComponent) else {
                    return nil
                }
                dateSuffix = String(dateComponent)
            } else {
                dateSuffix = nil
            }

            return PointRelease(
                family: family,
                minor: minor,
                dateSuffix: dateSuffix,
                rawModelID: modelID
            )
        }
        return nil
    }

    static func pointReleasePrecedes(_ lhs: PointRelease, _ rhs: PointRelease) -> Bool {
        if lhs.family.identity != rhs.family.identity {
            return familyRank(lhs.family) < familyRank(rhs.family)
        }
        if lhs.minor != rhs.minor {
            return lhs.minor > rhs.minor
        }

        let leftDate = lhs.dateSuffix.flatMap(Int.init) ?? -1
        let rightDate = rhs.dateSuffix.flatMap(Int.init) ?? -1
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return ModelPickerStringOrdering.precedes(lhs.rawModelID, rhs.rawModelID)
    }

    private static func isASCIIInteger(_ component: Substring) -> Bool {
        !component.isEmpty && component.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func familyRank(_ family: Family) -> Int {
        families.firstIndex(where: { $0.identity == family.identity }) ?? Int.max
    }
}
