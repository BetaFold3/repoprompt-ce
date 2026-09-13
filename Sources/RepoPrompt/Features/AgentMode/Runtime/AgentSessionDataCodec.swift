import Foundation

enum AgentSessionDataCodecError: Error, CustomStringConvertible {
    case malformedEnvelope(String)

    var description: String {
        switch self {
        case let .malformedEnvelope(reason):
            "agent session envelope is malformed: \(reason)"
        }
    }
}

/// Field-local codec for persisted Agent session envelopes (plan §3.3 preservation amendment).
///
/// Generic `Decoder`/`Encoder` cannot expose raw numeric lexemes, so this codec changes only the
/// `Data ↔ session/header` boundary: it captures the top-level `providerUsage` member as immutable
/// raw bytes, hands the remaining envelope to the normal `Codable` implementation, and on encode
/// re-inserts the authoritative bytes under that key. Every persisted session/header read and every
/// session write must go through it; the existing atomic writer receives only fully assembled data,
/// so a preservation failure throws before any replacement write.
enum AgentSessionDataCodec {
    static let providerUsageMemberName = "providerUsage"

    struct DecodedEnvelope<Value> {
        let value: Value
        /// Captured `providerUsage`: `nil` when the member is absent, otherwise raw bytes
        /// (explicit `null` included) regardless of whether a typed v1 view exists.
        let providerUsage: AgentProviderUsagePersist?
    }

    /// Decodes any envelope-shaped value (full session, header, run-state probe) with the
    /// `providerUsage` member captured separately instead of routed through `Codable`.
    static func decodeEnvelope<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> DecodedEnvelope<Value> {
        let split = try splitProviderUsage(from: data)
        let value = try decoder.decode(type, from: split.envelope)
        return DecodedEnvelope(
            value: value,
            providerUsage: split.memberValue.map { .opaque(AgentProviderUsageRawValue(unchecked: $0)) }
        )
    }

    static func decodeSession(from data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> AgentSession {
        let decoded = try decodeEnvelope(AgentSession.self, from: data, using: decoder)
        var session = decoded.value
        session.providerUsage = decoded.providerUsage
        return session
    }

    /// Encodes the session with `providerUsage` serialized outside `Codable`: raw bytes verbatim,
    /// owned records from the typed value. Absent stays absent.
    static func encodeSession(_ session: AgentSession, using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        guard let usage = session.providerUsage else {
            return try encoder.encode(session)
        }
        var stripped = session
        stripped.providerUsage = nil
        let envelope = try encoder.encode(stripped)
        let member = try usage.encodedJSONValue(using: encoder)
        return try insertTopLevelMember(named: providerUsageMemberName, value: member, into: envelope)
    }

    // MARK: - Internals

    private static func splitProviderUsage(from data: Data) throws -> AgentProviderUsageJSONScanner.TopLevelSplit {
        do {
            return try AgentProviderUsageJSONScanner.splitTopLevelMember(named: providerUsageMemberName, in: data)
        } catch let error as AgentProviderUsageJSONScanner.ScanError where error.kind == .notAnObject {
            // Not a JSON object at the top level: let the decoder report its own diagnostics.
            return .init(envelope: data, memberValue: nil)
        }
    }

    /// Appends `"name":value` to a non-whitespace-formatted top-level object produced by `encoder`.
    private static func insertTopLevelMember(named name: String, value: Data, into envelope: Data) throws -> Data {
        let bytes = [UInt8](envelope)
        var end = bytes.count
        while end > 0, AgentProviderUsageJSONScanner.Byte.isWhitespace(bytes[end - 1]) {
            end -= 1
        }
        guard end > 0, bytes[end - 1] == AgentProviderUsageJSONScanner.Byte.closeBrace else {
            throw AgentSessionDataCodecError.malformedEnvelope("encoded session is not a JSON object")
        }
        var start = 0
        while start < end, AgentProviderUsageJSONScanner.Byte.isWhitespace(bytes[start]) {
            start += 1
        }
        guard start < end, bytes[start] == AgentProviderUsageJSONScanner.Byte.openBrace else {
            throw AgentSessionDataCodecError.malformedEnvelope("encoded session is not a JSON object")
        }
        var firstMember = start + 1
        while firstMember < end, AgentProviderUsageJSONScanner.Byte.isWhitespace(bytes[firstMember]) {
            firstMember += 1
        }
        let isEmptyObject = firstMember == end - 1
        var assembled = Data(bytes[0 ..< (end - 1)])
        if !isEmptyObject {
            assembled.append(AgentProviderUsageJSONScanner.Byte.comma)
        }
        assembled.append(contentsOf: Data("\"\(name)\":".utf8))
        assembled.append(value)
        assembled.append(AgentProviderUsageJSONScanner.Byte.closeBrace)
        return assembled
    }
}
