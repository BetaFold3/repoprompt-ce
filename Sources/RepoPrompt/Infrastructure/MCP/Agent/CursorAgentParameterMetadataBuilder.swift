import MCP

struct CursorAgentParameterMetadataBuilder {
    static let includeParametersFlag = "include_model_parameters"

    private let catalog: CursorModelParameterCatalog
    private let isEnabled: () -> Bool

    init(
        catalog: CursorModelParameterCatalog = .shared,
        isEnabled: @escaping () -> Bool = { CursorParameterizedModels.isEnabled }
    ) {
        self.catalog = catalog
        self.isEnabled = isEnabled
    }

    func metadata(
        agent: AgentProviderKind,
        targetID: String,
        includeParameters: Bool
    ) -> Value? {
        guard agent == .cursor, isEnabled() else {
            return nil
        }

        let strippedTargetID = CursorBracketModelID.strippingCursorPrefix(targetID)
        guard let parsedTargetID = CursorBracketModelID.parse(strippedTargetID),
              !parsedTargetID.hasBracket,
              let specs = catalog.parameterSpecs(forModel: parsedTargetID.base),
              !specs.isEmpty
        else {
            return nil
        }

        let assignments = specs
            .map { "\($0.id)=<value>" }
            .joined(separator: ",")
        let targetTemplate = "\(targetID)[\(assignments)]"
        guard let parsedTemplate = CursorBracketModelID.parse(
            CursorBracketModelID.strippingCursorPrefix(targetTemplate)
        ),
            parsedTemplate.hasBracket,
            parsedTemplate.base == parsedTargetID.base,
            parsedTemplate.params.count == specs.count
        else {
            return nil
        }

        var envelope: [String: Value] = [
            "syntax": .string("cursor-bracket-v1"),
            "target_template": .string(targetTemplate),
            "include_model_parameters_flag": .string(Self.includeParametersFlag)
        ]
        let thoughtLevelSpecs = specs.filter { $0.category == "thought_level" }
        if thoughtLevelSpecs.count == 1 {
            envelope["reasoning_effort_parameter_id"] = .string(thoughtLevelSpecs[0].id)
        }
        if includeParameters {
            envelope["parameters"] = .array(specs.map(parameterValue))
        }
        return .object(envelope)
    }

    private func parameterValue(_ spec: CursorModelParameterCatalog.ParameterSpec) -> Value {
        var object: [String: Value] = [
            "id": .string(spec.id),
            "category": .string(spec.category),
            "default_value": .string(spec.defaultValue),
            "options": .array(spec.options.map { option in
                .object([
                    "value": .string(option.value),
                    "name": .string(option.name)
                ])
            })
        ]
        if let description = spec.description {
            object["description"] = .string(description)
        }
        return .object(object)
    }
}
