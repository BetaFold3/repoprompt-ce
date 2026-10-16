import Foundation
import RepoPromptPlatform

// Secure storage for the Telegram attention-notification bot token
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 3).
//
// The token lives only in the app's secure-storage domain under a dedicated account, never in
// defaults or files. Every access is noninteractive, so no macOS approval prompt can appear; a
// store that needs approval reads as `unavailable`. Raw storage errors are not retained.

enum TelegramBotTokenRead: Equatable {
    case token(TelegramBotToken)
    /// No token saved.
    case missing
    /// A saved value exists but is not a valid bot token.
    case invalidStoredValue
    /// Secure storage could not be read without user interaction, or failed.
    case unavailable
}

enum TelegramBotTokenWrite: Equatable {
    case succeeded
    /// Secure storage could not be written without user interaction, or failed.
    case unavailable
}

final class TelegramBotTokenStore {
    static let account = SecureStorageAccount.telegramAttentionBotToken
    static let accessMode = KeychainAccessMode.nonInteractive(reason: .backgroundAvailabilityCheck)

    private let secureStorage: SecurePlainStringStoring

    init(secureStorage: SecurePlainStringStoring = SecureKeysService()) {
        self.secureStorage = secureStorage
    }

    /// False when secure storage is process-local (ephemeral): a saved token is lost at quit.
    var persistsAcrossLaunches: Bool {
        secureStorage.persistsValuesAcrossLaunches
    }

    func read() -> TelegramBotTokenRead {
        let value: String?
        do {
            value = try secureStorage.getPlainValue(for: Self.account, accessMode: Self.accessMode)
        } catch {
            return .unavailable
        }
        guard let value, !value.isEmpty else { return .missing }
        guard let token = TelegramBotToken(value) else { return .invalidStoredValue }
        return .token(token)
    }

    func save(_ token: TelegramBotToken) -> TelegramBotTokenWrite {
        do {
            try secureStorage.savePlainValue(token.secureStorageValue, for: Self.account, accessMode: Self.accessMode)
            return .succeeded
        } catch {
            return .unavailable
        }
    }

    func delete() -> TelegramBotTokenWrite {
        do {
            try secureStorage.deletePlainValue(for: Self.account, accessMode: Self.accessMode)
            return .succeeded
        } catch {
            return .unavailable
        }
    }
}
