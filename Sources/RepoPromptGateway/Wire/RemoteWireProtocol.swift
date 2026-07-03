import CryptoKit
import Foundation
import MCP

/// Gateway remote-control wire protocol v1.
enum RemoteWireProtocol {
    static let version = 1

    static let clientFrameTypes: Set<String> = [
        "hello",
        "start",
        "steer",
        "respond",
        "cancel",
        "poll",
        "subscribe",
        "unsubscribe",
        "list_sessions",
        "get_log",
        "ping",
        // M5: gateway-owned Web Push subscription registration for the connected
        // (authenticated) device; never translated to an app tool call.
        "push_subscribe",
        "push_unsubscribe"
    ]

    static let serverFrameTypes: Set<String> = [
        "hello_ack",
        "command_result",
        "command_error",
        "session_update",
        "session_terminal",
        "session_expired",
        // M6.2: emitted when a pending interaction is resolved (by this device,
        // another device, a CLI client, or the local user).
        "interaction_resolved",
        "channel_closing",
        "pong"
    ]

    static let mutatingClientFrameTypes: Set<String> = ["start", "steer", "respond", "cancel"]

    static func decodeClientFrame(from data: Data) throws -> RemoteClientFrame {
        let frame: RemoteClientFrame
        do {
            frame = try JSONDecoder().decode(RemoteClientFrame.self, from: data)
        } catch {
            throw RemoteWireProtocolError.invalidJSON
        }
        try validateClientFrame(frame)
        return frame
    }

    static func validateClientFrame(_ frame: RemoteClientFrame) throws {
        guard frame.v == version else {
            throw RemoteWireProtocolError.unsupportedVersion(frame.v)
        }
        guard clientFrameTypes.contains(frame.type) else {
            throw RemoteWireProtocolError.unsupportedFrameType(frame.type)
        }
        if mutatingClientFrameTypes.contains(frame.type), frame.requestID?.isEmptyOrWhitespace != false {
            throw RemoteWireProtocolError.missingRequestID(frame.type)
        }
    }

    /// Decode server frames with additive-evolution tolerance. Unknown server frame
    /// types are preserved as strings so clients can ignore them without a v1 bump.
    static func decodeServerFrame(from data: Data) throws -> RemoteServerFrame {
        let frame = try JSONDecoder().decode(RemoteServerFrame.self, from: data)
        guard frame.v == version else {
            throw RemoteWireProtocolError.unsupportedVersion(frame.v)
        }
        return frame
    }

    static func encodeServerFrame(_ frame: RemoteServerFrame) throws -> Data {
        try canonicalData(for: JSONValue(frame))
    }

    static func canonicalData(for value: JSONValue) throws -> Data {
        try value.canonicalString().data(using: .utf8).okOrThrow(RemoteWireProtocolError.canonicalEncodingFailed)
    }

    static func canonicalJSONString(for value: JSONValue) throws -> String {
        try value.canonicalString()
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func commandFingerprint(for frame: RemoteClientFrame) throws -> CommandLedger.CommandFingerprint {
        var object: [String: JSONValue] = [
            "type": .string(frame.type),
            "payload": frame.payload ?? .object([:])
        ]
        if let sessionID = frame.sessionID {
            object["session_id"] = .string(sessionID)
        }
        let data = try canonicalData(for: .object(object))
        return CommandLedger.CommandFingerprint(
            operation: frame.type,
            canonicalPayloadSHA256: sha256Hex(of: data)
        )
    }
}

/// Per-frame device signature fields required for ticket-authenticated remote frames (M4 DPoP-lite).
struct RemoteFrameSignature: Equatable {
    static let requiredAlgorithm = "P256-SHA256"

    let ticketID: UUID
    let deviceID: String
    let counter: UInt64
    let algorithm: String
    let signature: Data

    init(ticketID: UUID, deviceID: String, counter: UInt64, algorithm: String = Self.requiredAlgorithm, signature: Data) {
        self.ticketID = ticketID
        self.deviceID = deviceID
        self.counter = counter
        self.algorithm = algorithm
        self.signature = signature
    }

    init?(jsonValue: JSONValue?) {
        guard let object = jsonValue?.objectValue,
              let ticketIDRaw = object["ticket_id"]?.stringValue,
              let ticketID = UUID(uuidString: ticketIDRaw),
              let deviceID = object["device_id"]?.stringValue, !deviceID.isEmpty,
              let counterRaw = object["counter"]?.intValue, counterRaw >= 0,
              let algorithm = object["algorithm"]?.stringValue,
              let signatureRaw = object["signature"]?.stringValue,
              let signature = Data(base64Encoded: signatureRaw)
        else {
            return nil
        }
        self.ticketID = ticketID
        self.deviceID = deviceID
        counter = UInt64(counterRaw)
        self.algorithm = algorithm
        self.signature = signature
    }

    var jsonValue: JSONValue {
        .object([
            "ticket_id": .string(ticketID.uuidString.lowercased()),
            "device_id": .string(deviceID),
            "counter": .int(Int(counter)),
            "algorithm": .string(algorithm),
            "signature": .string(signature.base64EncodedString())
        ])
    }
}

extension RemoteWireProtocol {
    /// Context line for the canonical remote frame signing payload.
    static let frameSigningContext = "RemoteFrameV1"

    /// SHA-256 hex digest of the canonical JSON encoding of the raw frame object
    /// with the `sig` member removed. Computed from raw bytes so unknown fields the
    /// device signed over are preserved verbatim.
    static func canonicalFrameHashHex(fromRawFrameData data: Data) throws -> String {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RemoteWireProtocolError.invalidJSON
        }
        guard var object = value.objectValue else {
            throw RemoteWireProtocolError.invalidJSON
        }
        object.removeValue(forKey: "sig")
        return try sha256Hex(of: canonicalData(for: .object(object)))
    }

    /// Canonical signing payload:
    /// `RemoteFrameV1\n<ticket_id>\n<device_id>\n<counter>\n<sha256(canonical_json_without_sig)>\n`
    static func frameSigningPayload(
        ticketID: UUID,
        deviceID: String,
        counter: UInt64,
        frameHashHex: String
    ) -> Data {
        let lines = [
            frameSigningContext,
            ticketID.uuidString.lowercased(),
            deviceID,
            String(counter),
            frameHashHex
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

enum RemoteWireProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidJSON
    case unsupportedVersion(Int)
    case unsupportedFrameType(String)
    case missingRequestID(String)
    case canonicalEncodingFailed

    var code: String {
        switch self {
        case .invalidJSON: "invalid_json"
        case .unsupportedVersion: "unsupported_version"
        case .unsupportedFrameType: "unsupported_frame_type"
        case .missingRequestID: "missing_request_id"
        case .canonicalEncodingFailed: "canonical_encoding_failed"
        }
    }

    var description: String {
        switch self {
        case .invalidJSON:
            "Frame is not valid JSON."
        case let .unsupportedVersion(version):
            "Unsupported remote wire version \(version)."
        case let .unsupportedFrameType(type):
            "Unsupported remote frame type '\(type)'."
        case let .missingRequestID(type):
            "request_id is required for remote mutating operation '\(type)'."
        case .canonicalEncodingFailed:
            "Could not encode canonical JSON."
        }
    }
}

struct RemoteClientFrame: Codable, Equatable {
    let v: Int
    let type: String
    let requestID: String?
    let sessionID: String?
    let payload: JSONValue?
    let clientTime: String?
    let sig: JSONValue?

    init(
        v: Int = RemoteWireProtocol.version,
        type: String,
        requestID: String? = nil,
        sessionID: String? = nil,
        payload: JSONValue? = nil,
        clientTime: String? = nil,
        sig: JSONValue? = .null
    ) {
        self.v = v
        self.type = type
        self.requestID = requestID
        self.sessionID = sessionID
        self.payload = payload
        self.clientTime = clientTime
        self.sig = sig
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case type
        case requestID = "request_id"
        case sessionID = "session_id"
        case payload
        case clientTime = "client_time"
        case sig
    }
}

struct RemoteServerFrame: Codable, Equatable {
    let v: Int
    let type: String
    let requestID: String?
    let sessionID: String?
    let seq: UInt64?
    let payload: JSONValue?

    init(
        v: Int = RemoteWireProtocol.version,
        type: String,
        requestID: String? = nil,
        sessionID: String? = nil,
        seq: UInt64? = nil,
        payload: JSONValue? = nil
    ) {
        self.v = v
        self.type = type
        self.requestID = requestID
        self.sessionID = sessionID
        self.seq = seq
        self.payload = payload
    }

    static func helloAck(payload: JSONValue = .object(["server": .string("repoprompt-gateway")])) -> RemoteServerFrame {
        RemoteServerFrame(type: "hello_ack", payload: payload)
    }

    static func commandResult(
        requestID: String?,
        sessionID: String? = nil,
        payload: JSONValue
    ) -> RemoteServerFrame {
        RemoteServerFrame(type: "command_result", requestID: requestID, sessionID: sessionID, payload: payload)
    }

    static func commandError(
        requestID: String?,
        sessionID: String? = nil,
        code: String,
        message: String,
        details: JSONValue? = nil
    ) -> RemoteServerFrame {
        var payload: [String: JSONValue] = [
            "code": .string(code),
            "message": .string(message)
        ]
        if let details {
            payload["details"] = details
        }
        return RemoteServerFrame(
            type: "command_error",
            requestID: requestID,
            sessionID: sessionID,
            payload: .object(payload)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case type
        case requestID = "request_id"
        case sessionID = "session_id"
        case seq
        case payload
    }
}

enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
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

    init(_ frame: RemoteServerFrame) throws {
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

    init(mcpValue value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encode(to encoder: Encoder) throws {
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

    var objectValue: [String: JSONValue]? {
        guard case let .object(object) = self else { return nil }
        return object
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(array) = self else { return nil }
        return array
    }

    var stringValue: String? {
        guard case let .string(string) = self else { return nil }
        return string
    }

    var boolValue: Bool? {
        guard case let .bool(bool) = self else { return nil }
        return bool
    }

    var intValue: Int? {
        guard case let .int(int) = self else { return nil }
        return int
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

    func canonicalString() throws -> String {
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

private extension Optional {
    func okOrThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

private extension String {
    var isEmptyOrWhitespace: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
