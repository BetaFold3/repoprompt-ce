import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public init(_ frame: RemoteServerFrame) throws {
        var object: [String: JSONValue] = [
            "v": .int(frame.v),
            "type": .string(frame.type)
        ]
        if let requestID = frame.requestID { object["request_id"] = .string(requestID) }
        if let sessionID = frame.sessionID { object["session_id"] = .string(sessionID) }
        if let seq = frame.seq { object["seq"] = .int(Int(seq)) }
        if let payload = frame.payload { object["payload"] = payload }
        self = .object(object)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(object):
            try container.encode(object)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(object) = self else { return nil }
        return object
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(array) = self else { return nil }
        return array
    }

    public var stringValue: String? {
        guard case let .string(string) = self else { return nil }
        return string
    }

    public var boolValue: Bool? {
        guard case let .bool(bool) = self else { return nil }
        return bool
    }

    public var intValue: Int? {
        guard case let .int(int) = self else { return nil }
        return int
    }

    public func canonicalString() throws -> String {
        switch self {
        case .null:
            "null"
        case let .bool(value):
            value ? "true" : "false"
        case let .int(value):
            String(value)
        case let .double(value):
            try Self.encodePrimitive(value)
        case let .string(value):
            try Self.encodePrimitive(value)
        case let .array(values):
            try "[" + values.map { try $0.canonicalString() }.joined(separator: ",") + "]"
        case let .object(object):
            try "{" + object.keys.sorted().map { key in
                try Self.encodePrimitive(key) + ":" + (object[key] ?? .null).canonicalString()
            }.joined(separator: ",") + "}"
        }
    }

    private static func encodePrimitive(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteWireProtocolError.canonicalEncodingFailed
        }
        return string
    }
}
