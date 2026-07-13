import Foundation

/// Per-frame device signature fields required for ticket-authenticated remote frames (M4 DPoP-lite).
public struct RemoteFrameSignature: Equatable, Sendable {
    public static let requiredAlgorithm = "P256-SHA256"

    public let ticketID: UUID
    public let deviceID: String
    public let counter: UInt64
    public let algorithm: String
    public let signature: Data

    public init(ticketID: UUID, deviceID: String, counter: UInt64, algorithm: String = Self.requiredAlgorithm, signature: Data) {
        self.ticketID = ticketID
        self.deviceID = deviceID
        self.counter = counter
        self.algorithm = algorithm
        self.signature = signature
    }

    public init?(jsonValue: JSONValue?) {
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

    public var jsonValue: JSONValue {
        .object([
            "ticket_id": .string(ticketID.uuidString.lowercased()),
            "device_id": .string(deviceID),
            "counter": .int(Int(counter)),
            "algorithm": .string(algorithm),
            "signature": .string(signature.base64EncodedString())
        ])
    }
}

public struct RemoteClientFrame: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String
    public let requestID: String?
    public let sessionID: String?
    public let payload: JSONValue?
    public let clientTime: String?
    public let sig: JSONValue?

    public init(
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

public struct RemoteServerFrame: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String
    public let requestID: String?
    public let sessionID: String?
    public let seq: UInt64?
    public let seqEpoch: String?
    public let payload: JSONValue?

    public init(
        v: Int = RemoteWireProtocol.version,
        type: String,
        requestID: String? = nil,
        sessionID: String? = nil,
        seq: UInt64? = nil,
        seqEpoch: String? = nil,
        payload: JSONValue? = nil
    ) {
        self.v = v
        self.type = type
        self.requestID = requestID
        self.sessionID = sessionID
        self.seq = seq
        self.seqEpoch = seqEpoch
        self.payload = payload
    }

    public static func helloAck(payload: JSONValue = .object(["server": .string("repoprompt-gateway")])) -> RemoteServerFrame {
        RemoteServerFrame(type: "hello_ack", payload: payload)
    }

    public static func commandResult(
        requestID: String?,
        sessionID: String? = nil,
        payload: JSONValue
    ) -> RemoteServerFrame {
        RemoteServerFrame(type: "command_result", requestID: requestID, sessionID: sessionID, payload: payload)
    }

    public static func commandError(
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
        case seqEpoch = "seq_epoch"
        case payload
    }
}

public enum RemoteWireProtocolError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidJSON
    case unsupportedVersion(Int)
    case unsupportedFrameType(String)
    case missingRequestID(String)
    case canonicalEncodingFailed

    public var code: String {
        switch self {
        case .invalidJSON: "invalid_json"
        case .unsupportedVersion: "unsupported_version"
        case .unsupportedFrameType: "unsupported_frame_type"
        case .missingRequestID: "missing_request_id"
        case .canonicalEncodingFailed: "canonical_encoding_failed"
        }
    }

    public var description: String {
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
