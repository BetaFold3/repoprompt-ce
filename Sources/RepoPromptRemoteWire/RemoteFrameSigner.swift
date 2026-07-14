import CryptoKit
import Foundation

public struct RemoteSignedFrame: Equatable, Sendable {
    public let frame: RemoteClientFrame
    public let data: Data
    public let signature: RemoteFrameSignature

    public init(frame: RemoteClientFrame, data: Data, signature: RemoteFrameSignature) {
        self.frame = frame
        self.data = data
        self.signature = signature
    }
}

public enum RemoteFrameSignerError: Error, Equatable, CustomStringConvertible, Sendable {
    case counterOverflow

    public var description: String {
        switch self {
        case .counterOverflow:
            "Remote frame counter overflowed."
        }
    }
}

/// Stateful client-side signer for ticket-authenticated remote frames.
///
/// The signer hashes the canonical frame object without `sig`, signs the standard
/// `RemoteFrameV1` payload, inserts `sig`, and returns the final canonical bytes to
/// send on the wire. Counter selection follows the v1 client policy:
/// `max(lastCounter + 1, nowMs)`.
public struct RemoteFrameSigner {
    private let deviceSigner: P256.Signing.PrivateKey
    public let ticketID: UUID
    public let deviceID: String
    public private(set) var lastCounter: UInt64

    public init(
        deviceSigner: P256.Signing.PrivateKey,
        ticketID: UUID,
        deviceID: String,
        lastCounter: UInt64 = 0
    ) {
        self.deviceSigner = deviceSigner
        self.ticketID = ticketID
        self.deviceID = deviceID
        self.lastCounter = lastCounter
    }

    public mutating func sign(_ frame: RemoteClientFrame, nowMs: Int64 = currentEpochMilliseconds()) throws -> RemoteSignedFrame {
        let counter = try nextCounter(nowMs: nowMs)
        var object = Self.unsignedObject(from: frame)
        let frameHashHex = try RemoteWireProtocol.sha256Hex(
            of: RemoteWireProtocol.canonicalData(for: .object(object))
        )
        let signingPayload = RemoteWireProtocol.frameSigningPayload(
            ticketID: ticketID,
            deviceID: deviceID,
            counter: counter,
            frameHashHex: frameHashHex
        )
        let signatureBytes = try deviceSigner.signature(for: signingPayload).rawRepresentation
        let signature = RemoteFrameSignature(
            ticketID: ticketID,
            deviceID: deviceID,
            counter: counter,
            signature: signatureBytes
        )
        object["sig"] = signature.jsonValue
        let data = try RemoteWireProtocol.canonicalData(for: .object(object))
        let signedFrame = RemoteClientFrame(
            v: frame.v,
            type: frame.type,
            requestID: frame.requestID,
            sessionID: frame.sessionID,
            payload: frame.payload,
            clientTime: frame.clientTime,
            sig: signature.jsonValue
        )
        lastCounter = counter
        return RemoteSignedFrame(frame: signedFrame, data: data, signature: signature)
    }

    private mutating func nextCounter(nowMs: Int64) throws -> UInt64 {
        guard lastCounter < UInt64.max else {
            throw RemoteFrameSignerError.counterOverflow
        }
        let next = lastCounter + 1
        let nowCounter = nowMs > 0 ? UInt64(nowMs) : 0
        let counter = max(next, nowCounter)
        guard counter <= UInt64(Int.max) else {
            throw RemoteFrameSignerError.counterOverflow
        }
        return counter
    }

    private static func unsignedObject(from frame: RemoteClientFrame) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "v": .int(frame.v),
            "type": .string(frame.type)
        ]
        if let requestID = frame.requestID { object["request_id"] = .string(requestID) }
        if let sessionID = frame.sessionID { object["session_id"] = .string(sessionID) }
        if let payload = frame.payload { object["payload"] = payload }
        if let clientTime = frame.clientTime { object["client_time"] = .string(clientTime) }
        return object
    }
}

public func currentEpochMilliseconds(date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
}
