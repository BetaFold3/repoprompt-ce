import CryptoKit
import Foundation

/// Gateway remote-control wire protocol v1.
public enum RemoteWireProtocol {
    public static let version = 1

    public static let clientFrameTypes: Set<String> = [
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

    public static let serverFrameTypes: Set<String> = [
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

    public static let mutatingClientFrameTypes: Set<String> = ["start", "steer", "respond", "cancel"]

    public static func decodeClientFrame(from data: Data) throws -> RemoteClientFrame {
        let frame: RemoteClientFrame
        do {
            frame = try JSONDecoder().decode(RemoteClientFrame.self, from: data)
        } catch {
            throw RemoteWireProtocolError.invalidJSON
        }
        try validateClientFrame(frame)
        return frame
    }

    public static func validateClientFrame(_ frame: RemoteClientFrame) throws {
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
    public static func decodeServerFrame(from data: Data) throws -> RemoteServerFrame {
        let frame = try JSONDecoder().decode(RemoteServerFrame.self, from: data)
        guard frame.v == version else {
            throw RemoteWireProtocolError.unsupportedVersion(frame.v)
        }
        return frame
    }

    public static func encodeServerFrame(_ frame: RemoteServerFrame) throws -> Data {
        try canonicalData(for: JSONValue(frame))
    }

    public static func canonicalData(for value: JSONValue) throws -> Data {
        try value.canonicalString().data(using: .utf8).okOrThrow(RemoteWireProtocolError.canonicalEncodingFailed)
    }

    public static func canonicalJSONString(for value: JSONValue) throws -> String {
        try value.canonicalString()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension RemoteWireProtocol {
    /// Context line for the canonical remote frame signing payload.
    public static let frameSigningContext = "RemoteFrameV1"

    /// SHA-256 hex digest of the canonical JSON encoding of the raw frame object
    /// with the `sig` member removed. Computed from raw bytes so unknown fields the
    /// device signed over are preserved verbatim.
    public static func canonicalFrameHashHex(fromRawFrameData data: Data) throws -> String {
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
    public static func frameSigningPayload(
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
