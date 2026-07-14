import Foundation
import Security

final class RemoteGatewayTokenStore {
    static let shared = RemoteGatewayTokenStore()

    private let secureStorage: SecurePlainStringStoring

    init(secureStorage: SecurePlainStringStoring = SecureKeysService()) {
        self.secureStorage = secureStorage
    }

    func token() throws -> String? {
        try secureStorage.getPlainValue(
            for: .remoteGatewayStaticToken,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )
    }

    @discardableResult
    func ensureToken() throws -> String {
        if let existing = try token(), !existing.isEmpty {
            return existing
        }
        let generated = try Self.generateToken()
        try secureStorage.savePlainValue(
            generated,
            for: .remoteGatewayStaticToken,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )
        return generated
    }

    @discardableResult
    func regenerateToken() throws -> String {
        let generated = try Self.generateToken()
        try secureStorage.savePlainValue(
            generated,
            for: .remoteGatewayStaticToken,
            accessMode: .interactive
        )
        return generated
    }

    static func generateToken(byteCount: Int = 32) throws -> String {
        precondition(byteCount > 0)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteGatewayTokenStoreError.randomGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RemoteGatewayTokenStoreError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
}
