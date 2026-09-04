import CoreFoundation
import Foundation

enum OpenAIAPIModelProtocol: String, CaseIterable {
    case responses
    case chatCompletions = "chat_completions"
}

enum OpenAIAPIReasoningMode: String, CaseIterable {
    case standard
    case pro
}

enum OpenAIAPIReasoningEffort: String, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

enum OpenAIAPIServiceTier: String, CaseIterable {
    case flex
    case priority
}

struct OpenAIAPIReasoningMetadata: Equatable {
    let modes: [OpenAIAPIReasoningMode]
    let efforts: [OpenAIAPIReasoningEffort]
}

struct OpenAIAPITokenMetadata: Equatable {
    let contextWindowTokens: Int
    let maxInputTokens: Int?
    let maxOutputTokens: Int?
}

struct OpenAIAPIModelMetadata: Equatable {
    let id: String
    let displayName: String
    let protocols: [OpenAIAPIModelProtocol]
    let reasoning: OpenAIAPIReasoningMetadata?
    let supportsStreaming: Bool
    let tokens: OpenAIAPITokenMetadata?
    let serviceTiers: [OpenAIAPIServiceTier]

    fileprivate init(
        id: String,
        displayName: String,
        protocols: [OpenAIAPIModelProtocol],
        reasoning: OpenAIAPIReasoningMetadata?,
        supportsStreaming: Bool,
        tokens: OpenAIAPITokenMetadata?,
        serviceTiers: [OpenAIAPIServiceTier]
    ) {
        self.id = id
        self.displayName = displayName
        self.protocols = protocols
        self.reasoning = reasoning
        self.supportsStreaming = supportsStreaming
        self.tokens = tokens
        self.serviceTiers = serviceTiers
    }
}

struct OpenAIAPIModelMetadataDocument: Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let models: [OpenAIAPIModelMetadata]
    let disabledModelIDs: [String]
}

enum OpenAIAPIModelMetadataRowRejectionReason: String, Error, Equatable {
    case notAnObject
    case invalidModelID
    case invalidProtocols
    case invalidDisplayName
    case invalidReasoning
    case invalidStreaming
    case invalidTokens
    case invalidServiceTiers
}

struct OpenAIAPIModelMetadataRejectedRow: Equatable {
    let index: Int
    let modelID: String?
    let reason: OpenAIAPIModelMetadataRowRejectionReason
}

struct OpenAIAPIModelMetadataDuplicateWarning: Equatable {
    let index: Int
    let modelID: String
}

struct OpenAIAPIModelMetadataDecodeReport: Equatable {
    let document: OpenAIAPIModelMetadataDocument
    let rejectedRows: [OpenAIAPIModelMetadataRejectedRow]
    let duplicateWarnings: [OpenAIAPIModelMetadataDuplicateWarning]
}

enum OpenAIAPIModelMetadataError: Error, Equatable {
    case unreadable
    case documentTooLarge
    case malformedJSON
    case invalidDocument
    case unsupportedSchemaVersion(Int)
    case forbiddenField(String)
    case noValidModels
}

enum OpenAIAPIModelMetadataDecoder {
    static let maximumDocumentByteCount = 1_048_576
    static let maximumModelCount = 2048

    private static let versionOneRootKeys: Set<String> = ["schema_version", "models"]
    private static let versionTwoRootKeys: Set<String> = [
        "schema_version", "models", "disabled_model_ids"
    ]
    private static let versionOneModelKeys: Set<String> = [
        "id", "display_name", "protocols", "reasoning", "streaming", "tokens"
    ]
    private static let versionTwoModelKeys = versionOneModelKeys.union(["service_tiers"])
    private static let reasoningKeys: Set<String> = ["modes", "efforts"]
    private static let tokenKeys: Set<String> = [
        "context_window_tokens", "max_input_tokens", "max_output_tokens"
    ]

    static func decode(contentsOf fileURL: URL) throws -> OpenAIAPIModelMetadataDocument {
        try decodeWithReport(contentsOf: fileURL).document
    }

    static func decode(_ data: Data) throws -> OpenAIAPIModelMetadataDocument {
        try decodeWithReport(data).document
    }

    static func decodeWithReport(
        contentsOf fileURL: URL
    ) throws -> OpenAIAPIModelMetadataDecodeReport {
        guard fileURL.isFileURL else { throw OpenAIAPIModelMetadataError.unreadable }
        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maximumDocumentByteCount
        {
            throw OpenAIAPIModelMetadataError.documentTooLarge
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            throw OpenAIAPIModelMetadataError.unreadable
        }
        return try decodeWithReport(data)
    }

    static func decodeWithReport(_ data: Data) throws -> OpenAIAPIModelMetadataDecodeReport {
        guard data.count <= maximumDocumentByteCount else {
            throw OpenAIAPIModelMetadataError.documentTooLarge
        }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw OpenAIAPIModelMetadataError.malformedJSON
        }
        guard let root = value as? [String: Any],
              let schemaVersion = exactPositiveInteger(root["schema_version"])
        else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }

        let rootKeys: Set<String>
        let modelKeys: Set<String>
        switch schemaVersion {
        case 1:
            rootKeys = versionOneRootKeys
            modelKeys = versionOneModelKeys
        case 2:
            rootKeys = versionTwoRootKeys
            modelKeys = versionTwoModelKeys
        default:
            throw OpenAIAPIModelMetadataError.unsupportedSchemaVersion(schemaVersion)
        }
        try rejectUnknownKeys(in: root, allowed: rootKeys, path: "$")

        guard let rawModels = root["models"] as? [Any],
              rawModels.count <= maximumModelCount
        else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }
        let disabledModelIDs = try parseDisabledModelIDs(root, schemaVersion: schemaVersion)

        var seen = Set<String>()
        var models: [OpenAIAPIModelMetadata] = []
        var rejectedRows: [OpenAIAPIModelMetadataRejectedRow] = []
        var duplicateWarnings: [OpenAIAPIModelMetadataDuplicateWarning] = []

        for (index, rawModel) in rawModels.enumerated() {
            guard let dictionary = rawModel as? [String: Any] else {
                rejectedRows.append(.init(index: index, modelID: nil, reason: .notAnObject))
                continue
            }
            try rejectUnknownKeys(in: dictionary, allowed: modelKeys, path: "models[\(index)]")
            try rejectUnknownNestedKeys(in: dictionary, index: index)

            switch parseModel(dictionary, schemaVersion: schemaVersion) {
            case let .success(model):
                guard seen.insert(model.id).inserted else {
                    duplicateWarnings.append(.init(index: index, modelID: model.id))
                    continue
                }
                models.append(model)
            case let .failure(reason):
                rejectedRows.append(.init(
                    index: index,
                    modelID: normalizedModelID(dictionary["id"]),
                    reason: reason
                ))
            }
        }

        if schemaVersion == 1, models.isEmpty {
            throw OpenAIAPIModelMetadataError.noValidModels
        }
        if schemaVersion == 2, models.isEmpty, !rawModels.isEmpty,
           rejectedRows.count == rawModels.count
        {
            throw OpenAIAPIModelMetadataError.noValidModels
        }

        return OpenAIAPIModelMetadataDecodeReport(
            document: OpenAIAPIModelMetadataDocument(
                schemaVersion: schemaVersion,
                models: models,
                disabledModelIDs: disabledModelIDs
            ),
            rejectedRows: rejectedRows,
            duplicateWarnings: duplicateWarnings
        )
    }

    private static func parseDisabledModelIDs(
        _ root: [String: Any],
        schemaVersion: Int
    ) throws -> [String] {
        guard schemaVersion == 2 else { return [] }
        guard root.keys.contains("disabled_model_ids") else { return [] }
        guard let values = root["disabled_model_ids"] as? [Any],
              values.count <= maximumModelCount
        else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }

        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let id = normalizedModelID(value) else {
                throw OpenAIAPIModelMetadataError.invalidDocument
            }
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    private static func rejectUnknownNestedKeys(
        in dictionary: [String: Any],
        index: Int
    ) throws {
        if let reasoning = dictionary["reasoning"] as? [String: Any] {
            try rejectUnknownKeys(
                in: reasoning,
                allowed: reasoningKeys,
                path: "models[\(index)].reasoning"
            )
        }
        if let tokens = dictionary["tokens"] as? [String: Any] {
            try rejectUnknownKeys(
                in: tokens,
                allowed: tokenKeys,
                path: "models[\(index)].tokens"
            )
        }
    }

    private static func parseModel(
        _ dictionary: [String: Any],
        schemaVersion: Int
    ) -> Result<OpenAIAPIModelMetadata, OpenAIAPIModelMetadataRowRejectionReason> {
        guard let id = normalizedModelID(dictionary["id"]) else {
            return .failure(.invalidModelID)
        }
        guard let protocols = enumArray(
            dictionary["protocols"],
            as: OpenAIAPIModelProtocol.self
        ), !protocols.isEmpty else {
            return .failure(.invalidProtocols)
        }
        guard let supportsStreaming = exactBool(dictionary["streaming"]) else {
            return .failure(.invalidStreaming)
        }

        let displayName: String
        if dictionary.keys.contains("display_name") {
            guard let normalized = normalizedDisplayName(dictionary["display_name"]) else {
                return .failure(.invalidDisplayName)
            }
            displayName = normalized
        } else {
            displayName = id
        }

        let reasoning: OpenAIAPIReasoningMetadata?
        if let rawReasoning = dictionary["reasoning"] {
            guard let reasoningDictionary = rawReasoning as? [String: Any],
                  let modes = enumArray(
                      reasoningDictionary["modes"],
                      as: OpenAIAPIReasoningMode.self
                  ), !modes.isEmpty,
                  let efforts = enumArray(
                      reasoningDictionary["efforts"],
                      as: OpenAIAPIReasoningEffort.self
                  ), !efforts.isEmpty
            else {
                return .failure(.invalidReasoning)
            }
            reasoning = OpenAIAPIReasoningMetadata(modes: modes, efforts: efforts)
        } else {
            reasoning = nil
        }

        let tokens: OpenAIAPITokenMetadata?
        if let rawTokens = dictionary["tokens"] {
            guard let tokenDictionary = rawTokens as? [String: Any],
                  let contextWindow = exactPositiveInteger(
                      tokenDictionary["context_window_tokens"]
                  )
            else {
                return .failure(.invalidTokens)
            }
            let maxInput = optionalPositiveInteger(tokenDictionary, key: "max_input_tokens")
            let maxOutput = optionalPositiveInteger(tokenDictionary, key: "max_output_tokens")
            guard maxInput.isValid,
                  maxOutput.isValid,
                  maxInput.value.map({ $0 <= contextWindow }) ?? true,
                  maxOutput.value.map({ $0 <= contextWindow }) ?? true,
                  combinedTokenLimitsFit(
                      maxInput: maxInput.value,
                      maxOutput: maxOutput.value,
                      contextWindow: contextWindow
                  )
            else {
                return .failure(.invalidTokens)
            }
            tokens = OpenAIAPITokenMetadata(
                contextWindowTokens: contextWindow,
                maxInputTokens: maxInput.value,
                maxOutputTokens: maxOutput.value
            )
        } else {
            tokens = nil
        }

        let serviceTiers: [OpenAIAPIServiceTier]
        if schemaVersion == 2, dictionary.keys.contains("service_tiers") {
            guard let parsed = enumArray(
                dictionary["service_tiers"],
                as: OpenAIAPIServiceTier.self
            ) else {
                return .failure(.invalidServiceTiers)
            }
            serviceTiers = parsed
        } else {
            serviceTiers = []
        }

        return .success(OpenAIAPIModelMetadata(
            id: id,
            displayName: displayName,
            protocols: protocols,
            reasoning: reasoning,
            supportsStreaming: supportsStreaming,
            tokens: tokens,
            serviceTiers: serviceTiers
        ))
    }

    private static func rejectUnknownKeys(
        in dictionary: [String: Any],
        allowed: Set<String>,
        path: String
    ) throws {
        if let forbidden = Set(dictionary.keys).subtracting(allowed).sorted().first {
            throw OpenAIAPIModelMetadataError.forbiddenField("\(path).\(forbidden)")
        }
    }

    private static func enumArray<Value: RawRepresentable & Hashable>(
        _ value: Any?,
        as type: Value.Type
    ) -> [Value]? where Value.RawValue == String {
        guard let rawValues = value as? [Any], rawValues.count <= 16 else { return nil }
        var seen = Set<Value>()
        var values: [Value] = []
        for rawValue in rawValues {
            guard let string = rawValue as? String,
                  let value = Value(rawValue: string),
                  seen.insert(value).inserted
            else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    private static func normalizedModelID(_ value: Any?) -> String? {
        guard let rawValue = value as? String else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 256 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
        )
        guard normalized.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return normalized
    }

    private static func normalizedDisplayName(_ value: Any?) -> String? {
        guard let rawValue = value as? String else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 256,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return normalized
    }

    private static func exactBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private static func exactPositiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue > 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              // Keep this strict: Double(Int.max) rounds to 2^63 and Int conversion would trap.
              doubleValue < Double(Int.max)
        else {
            return nil
        }
        return Int(doubleValue)
    }

    private static func optionalPositiveInteger(
        _ dictionary: [String: Any],
        key: String
    ) -> (isValid: Bool, value: Int?) {
        guard dictionary.keys.contains(key) else { return (true, nil) }
        guard let value = exactPositiveInteger(dictionary[key]) else { return (false, nil) }
        return (true, value)
    }

    private static func combinedTokenLimitsFit(
        maxInput: Int?,
        maxOutput: Int?,
        contextWindow: Int
    ) -> Bool {
        guard let maxInput, let maxOutput else { return true }
        return maxInput <= contextWindow - maxOutput
    }
}

enum OpenAIAPIModelCatalogMerge {
    static func merge(
        visibleModelIDs: [String],
        trustedMetadata: [OpenAIAPIModelMetadata]
    ) -> [OpenAIAPIModelMetadata] {
        let visible = Set(visibleModelIDs.compactMap { rawValue -> String? in
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        })
        var seen = Set<String>()
        return trustedMetadata
            .filter { visible.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let displayOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if displayOrder != .orderedSame {
                    return displayOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }
}
