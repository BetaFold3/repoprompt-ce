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

    fileprivate init(
        id: String,
        displayName: String,
        protocols: [OpenAIAPIModelProtocol],
        reasoning: OpenAIAPIReasoningMetadata?,
        supportsStreaming: Bool,
        tokens: OpenAIAPITokenMetadata?
    ) {
        self.id = id
        self.displayName = displayName
        self.protocols = protocols
        self.reasoning = reasoning
        self.supportsStreaming = supportsStreaming
        self.tokens = tokens
    }
}

struct OpenAIAPIModelMetadataDocument: Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let models: [OpenAIAPIModelMetadata]
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

    private static let rootKeys: Set<String> = ["schema_version", "models"]
    private static let modelKeys: Set<String> = [
        "id", "display_name", "protocols", "reasoning", "streaming", "tokens"
    ]
    private static let reasoningKeys: Set<String> = ["modes", "efforts"]
    private static let tokenKeys: Set<String> = [
        "context_window_tokens", "max_input_tokens", "max_output_tokens"
    ]

    static func decode(contentsOf fileURL: URL) throws -> OpenAIAPIModelMetadataDocument {
        guard fileURL.isFileURL else { throw OpenAIAPIModelMetadataError.unreadable }
        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maximumDocumentByteCount
        {
            throw OpenAIAPIModelMetadataError.documentTooLarge
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            throw OpenAIAPIModelMetadataError.unreadable
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> OpenAIAPIModelMetadataDocument {
        guard data.count <= maximumDocumentByteCount else {
            throw OpenAIAPIModelMetadataError.documentTooLarge
        }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw OpenAIAPIModelMetadataError.malformedJSON
        }
        guard let root = value as? [String: Any] else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }
        try rejectUnknownKeys(in: root, allowed: rootKeys, path: "$")

        guard let schemaVersion = exactPositiveInteger(root["schema_version"]) else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }
        guard schemaVersion == OpenAIAPIModelMetadataDocument.currentSchemaVersion else {
            throw OpenAIAPIModelMetadataError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let rawModels = root["models"] as? [Any], rawModels.count <= maximumModelCount else {
            throw OpenAIAPIModelMetadataError.invalidDocument
        }

        var seen = Set<String>()
        var models: [OpenAIAPIModelMetadata] = []
        for (index, rawModel) in rawModels.enumerated() {
            guard let dictionary = rawModel as? [String: Any] else { continue }
            try rejectUnknownKeys(
                in: dictionary,
                allowed: modelKeys,
                path: "models[\(index)]"
            )
            guard let model = try parseModel(dictionary, index: index),
                  seen.insert(model.id).inserted
            else {
                continue
            }
            models.append(model)
        }

        guard !models.isEmpty else {
            throw OpenAIAPIModelMetadataError.noValidModels
        }
        return OpenAIAPIModelMetadataDocument(schemaVersion: schemaVersion, models: models)
    }

    private static func parseModel(
        _ dictionary: [String: Any],
        index: Int
    ) throws -> OpenAIAPIModelMetadata? {
        guard let id = normalizedModelID(dictionary["id"]),
              let protocols = enumArray(dictionary["protocols"], as: OpenAIAPIModelProtocol.self),
              !protocols.isEmpty,
              let supportsStreaming = exactBool(dictionary["streaming"])
        else {
            return nil
        }

        let displayName: String
        if dictionary.keys.contains("display_name") {
            guard let normalizedDisplayName = normalizedDisplayName(dictionary["display_name"]) else {
                return nil
            }
            displayName = normalizedDisplayName
        } else {
            displayName = id
        }

        let reasoning: OpenAIAPIReasoningMetadata?
        if let rawReasoning = dictionary["reasoning"] {
            guard let reasoningDictionary = rawReasoning as? [String: Any] else { return nil }
            try rejectUnknownKeys(
                in: reasoningDictionary,
                allowed: reasoningKeys,
                path: "models[\(index)].reasoning"
            )
            guard let modes = enumArray(
                reasoningDictionary["modes"],
                as: OpenAIAPIReasoningMode.self
            ),
                !modes.isEmpty,
                let efforts = enumArray(
                    reasoningDictionary["efforts"],
                    as: OpenAIAPIReasoningEffort.self
                ),
                !efforts.isEmpty
            else {
                return nil
            }
            reasoning = OpenAIAPIReasoningMetadata(modes: modes, efforts: efforts)
        } else {
            reasoning = nil
        }

        let tokens: OpenAIAPITokenMetadata?
        if let rawTokens = dictionary["tokens"] {
            guard let tokenDictionary = rawTokens as? [String: Any] else { return nil }
            try rejectUnknownKeys(
                in: tokenDictionary,
                allowed: tokenKeys,
                path: "models[\(index)].tokens"
            )
            guard let contextWindow = exactPositiveInteger(tokenDictionary["context_window_tokens"])
            else {
                return nil
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
                return nil
            }
            tokens = OpenAIAPITokenMetadata(
                contextWindowTokens: contextWindow,
                maxInputTokens: maxInput.value,
                maxOutputTokens: maxOutput.value
            )
        } else {
            tokens = nil
        }

        return OpenAIAPIModelMetadata(
            id: id,
            displayName: displayName,
            protocols: protocols,
            reasoning: reasoning,
            supportsStreaming: supportsStreaming,
            tokens: tokens
        )
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
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-")
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
              // Double(Int.max) rounds up to an out-of-range boundary on 64-bit platforms.
              // Keep the comparison strict so the conversion below cannot trap.
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
