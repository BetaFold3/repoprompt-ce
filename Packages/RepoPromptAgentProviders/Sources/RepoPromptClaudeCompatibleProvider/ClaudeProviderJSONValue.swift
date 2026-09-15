import Foundation

/// Sendable JSON value used by provider DTOs instead of exposing `[String: Any]`.
public enum ClaudeProviderJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([ClaudeProviderJSONValue])
    case object([String: ClaudeProviderJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClaudeProviderJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClaudeProviderJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public init(any value: Any) throws {
        switch value {
        case _ as NSNull:
            self = .null
        case let value as NSNumber:
            // `JSONSerialization` yields `NSNumber` for every JSON number and boolean. This case
            // must precede the `Bool` cast: on Darwin an `NSNumber` holding 0 or 1 bridges to
            // `Bool`, which turned wire integers such as `"cache_creation_input_tokens":0` and
            // `"output_tokens":1` into `.bool` and downstream into missing counts. Only the
            // CFBoolean singletons are booleans. Swift `Bool`/`Int`/`Double` inputs also arrive
            // here via bridging: integers are classified first by the exact decimal `stringValue`
            // (which keeps values above 2^53 exact), then by `Int(exactly:)` on the finite double
            // (so integral doubles in scientific notation such as `1e18` stay `.integer`, as the
            // `Double` case below always did); non-finite values still throw.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if let exactInteger = Int(value.stringValue) {
                self = .integer(exactInteger)
            } else {
                // `JSONSerialization` decodes long decimal literals (for example the wire cost
                // `0.007236599999999999`) as `NSDecimalNumber`, whose `doubleValue` is computed
                // from mantissa and exponent and is not the nearest double (it yields
                // `…996`). Parsing its exact decimal text gives the correctly rounded double,
                // whose shortest round-trip text equals the wire lexeme again.
                let double: Double = if value is NSDecimalNumber, let parsed = Double(value.stringValue) {
                    parsed
                } else {
                    value.doubleValue
                }
                guard double.isFinite else {
                    throw JSONValueError.unsupportedValue(value.stringValue)
                }
                if let exactInteger = Int(exactly: double) {
                    self = .integer(exactInteger)
                } else {
                    self = .double(double)
                }
            }
        // The three cases below are unreachable on Darwin (every `Bool`/`Int`/`Double` boxed in
        // `Any` matches `NSNumber` above) and are retained only as non-bridging fallbacks; their
        // classification intentionally mirrors the `NSNumber` branch.
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .integer(value)
        case let value as Double:
            guard value.isFinite else {
                throw JSONValueError.unsupportedValue(String(describing: value))
            }
            if let exactInteger = Int(exactly: value) {
                self = .integer(exactInteger)
            } else {
                self = .double(value)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = try .array(value.map { try ClaudeProviderJSONValue(any: $0) })
        case let value as [String: Any]:
            self = try .object(value.mapValues { try ClaudeProviderJSONValue(any: $0) })
        default:
            throw JSONValueError.unsupportedValue(String(describing: Swift.type(of: value)))
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var objectValue: [String: ClaudeProviderJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [ClaudeProviderJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public func foundationObject() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map { $0.foundationObject() }
        case let .object(value):
            value.mapValues { $0.foundationObject() }
        }
    }

    public enum JSONValueError: Error, Equatable {
        case unsupportedValue(String)
    }
}
