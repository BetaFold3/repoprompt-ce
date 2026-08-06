import Foundation

enum CursorBracketModelID {
    struct Parameter: Equatable {
        let key: String
        let value: String
    }

    struct Parsed: Equatable {
        let base: String
        let params: [Parameter]
        let hasBracket: Bool
    }

    static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let openingBracket = trimmed.firstIndex(of: "[") else {
            guard !trimmed.contains("]") else { return nil }
            return Parsed(base: trimmed, params: [], hasBracket: false)
        }

        let base = trimmed[..<openingBracket]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }

        let bracketAndSuffix = trimmed[openingBracket...]
        guard bracketAndSuffix.last == "]",
              bracketAndSuffix.dropFirst().dropLast().allSatisfy({ $0 != "[" && $0 != "]" })
        else {
            return nil
        }

        let body = bracketAndSuffix.dropFirst().dropLast()
        guard !body.isEmpty else {
            return Parsed(base: base, params: [], hasBracket: true)
        }

        var params: [Parameter] = []
        var normalizedKeys: Set<String> = []
        for assignment in body.split(separator: ",", omittingEmptySubsequences: false) {
            guard let equals = assignment.firstIndex(of: "=") else { return nil }

            let key = assignment[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = assignment[assignment.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRepresentableComponent(key),
                  isRepresentableComponent(value)
            else {
                return nil
            }

            let normalizedKey = key.lowercased()
            guard normalizedKeys.insert(normalizedKey).inserted else { return nil }
            params.append(Parameter(key: key, value: value))
        }

        return Parsed(base: base, params: params, hasBracket: true)
    }

    static func compose(base rawBase: String, params rawParams: [Parameter]) -> String? {
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              !base.contains("["),
              !base.contains("]")
        else {
            return nil
        }

        var params: [Parameter] = []
        var normalizedKeys: Set<String> = []
        for parameter in rawParams {
            let key = parameter.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRepresentableComponent(key),
                  isRepresentableComponent(value)
            else {
                return nil
            }

            let normalizedKey = key.lowercased()
            guard normalizedKeys.insert(normalizedKey).inserted else { return nil }
            params.append(Parameter(key: key, value: value))
        }

        let orderedParams = params.filter { $0.key.lowercased() != "fast" }
            + params.filter { $0.key.lowercased() == "fast" }
        let body = orderedParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "\(base)[\(body)]"
    }

    static func strippingCursorPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cursor:") else { return trimmed }
        return String(trimmed.dropFirst("cursor:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRepresentableComponent(_ component: String) -> Bool {
        !component.isEmpty
            && !component.contains(",")
            && !component.contains("=")
            && !component.contains("[")
            && !component.contains("]")
    }
}

enum CursorModelRegistryGate {
    static func allows(_ rawModel: String, in snapshot: ACPDiscoveredSessionModels?) -> Bool {
        let selection = normalizedAlias(rawModel)
        guard !selection.isEmpty else { return false }
        if selection == normalizedAlias(AgentModel.cursorAuto.rawValue) {
            return true
        }
        guard let snapshot else { return true }
        return snapshot.options.contains { option in
            normalizedAlias(option.rawValue) == selection
                || normalizedAlias(option.displayName) == selection
        }
    }

    static func normalizedAlias(_ raw: String) -> String {
        let withoutPrefix = CursorBracketModelID.strippingCursorPrefix(raw).lowercased()
        let base: String = if let parsed = CursorBracketModelID.parse(withoutPrefix) {
            parsed.base
        } else if let bracketIndex = withoutPrefix.firstIndex(of: "[") {
            String(withoutPrefix[..<bracketIndex])
        } else {
            withoutPrefix
        }
        return base
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
    }
}

enum CursorParameterizedModels {
    static let userDefaultsKey = "CursorParameterizedModelPickerEnabled"

    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: userDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: userDefaultsKey)
    }
}
