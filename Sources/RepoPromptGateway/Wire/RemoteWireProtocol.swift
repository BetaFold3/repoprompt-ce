import Foundation
import RepoPromptRemoteWire

extension RemoteWireProtocol {
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
