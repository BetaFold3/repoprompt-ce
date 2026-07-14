import Foundation
import MCP
import RepoPromptRemoteWire

extension JSONValue {
    init(mcpValue value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    var mcpValue: Value {
        switch self {
        case .null:
            .null
        case let .bool(value):
            .bool(value)
        case let .int(value):
            .int(value)
        case let .double(value):
            .double(value)
        case let .string(value):
            .string(value)
        case let .array(values):
            .array(values.map(\.mcpValue))
        case let .object(object):
            .object(object.mapValues(\.mcpValue))
        }
    }
}

enum RemoteMCPToolResultCodec {
    static func value(from result: MCPToolResult) throws -> Value {
        if let structured = result.structuredContent {
            return structured
        }
        if let text = firstTextContent(in: result) {
            let data = Data(text.utf8)
            if let value = try? JSONDecoder().decode(Value.self, from: data) {
                return value
            }
            return .object([
                "text": .string(text),
                "is_error": .bool(result.isError == true)
            ])
        }
        return try .object([
            "content": Value(result.content),
            "is_error": .bool(result.isError == true)
        ])
    }

    static func jsonValue(from result: MCPToolResult) throws -> JSONValue {
        try JSONValue(mcpValue: value(from: result))
    }

    private static func firstTextContent(in result: MCPToolResult) -> String? {
        for content in result.content {
            if case let .text(text, _, _) = content {
                return text
            }
        }
        return nil
    }
}
