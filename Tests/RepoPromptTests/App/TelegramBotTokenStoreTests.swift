import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Token storage against injected test backends only; never the real Keychain.
final class TelegramBotTokenStoreTests: XCTestCase {
    /// Synthetic, test-only sentinel shaped like a bot token. Not a real credential.
    private static let syntheticToken = "424242:SYNTHETIC_TELEGRAM_STORE_SENTINEL-not-real"
    private static let syntheticSecret = "SYNTHETIC_TELEGRAM_STORE_SENTINEL"

    func testMissingTokenReadsMissing() {
        let backend = TestSecureStorageBackend()
        XCTAssertEqual(store(backend).read(), .missing)
        assertNonInteractiveOnly(backend, operations: [.get])
    }

    func testSaveReadDeleteRoundTripUsesDedicatedAccountNonInteractively() throws {
        let backend = TestSecureStorageBackend()
        let store = store(backend)
        let token = try XCTUnwrap(TelegramBotToken(Self.syntheticToken))

        XCTAssertEqual(store.save(token), .succeeded)
        XCTAssertEqual(backend.value(for: .telegramAttentionBotToken), Self.syntheticToken)
        XCTAssertEqual(store.read(), .token(token))
        XCTAssertEqual(store.delete(), .succeeded)
        XCTAssertEqual(store.read(), .missing)

        assertNonInteractiveOnly(backend, operations: [.save, .get, .delete, .get])
        XCTAssertTrue(backend.calls.allSatisfy { $0.account == .telegramAttentionBotToken })
    }

    func testStorageNeedingApprovalOrFailingReadsAndWritesUnavailable() throws {
        let backend = TestSecureStorageBackend(values: [.telegramAttentionBotToken: Self.syntheticToken])
        backend.getErrors[.telegramAttentionBotToken] = .interactionNotAllowed
        backend.saveErrors[.telegramAttentionBotToken] = .unexpectedStatus(-1)
        backend.deleteErrors[.telegramAttentionBotToken] = .authenticationFailed
        let store = store(backend)
        let token = try XCTUnwrap(TelegramBotToken(Self.syntheticToken))

        XCTAssertEqual(store.read(), .unavailable)
        XCTAssertEqual(store.save(token), .unavailable)
        XCTAssertEqual(store.delete(), .unavailable)
        assertNonInteractiveOnly(backend, operations: [.get, .save, .delete])
    }

    func testInvalidOrEmptyStoredValues() {
        XCTAssertEqual(
            store(TestSecureStorageBackend(values: [.telegramAttentionBotToken: "not a token"])).read(),
            .invalidStoredValue
        )
        XCTAssertEqual(store(TestSecureStorageBackend(values: [.telegramAttentionBotToken: ""])).read(), .missing)
    }

    func testEphemeralStorageIsReported() throws {
        let ephemeral = TelegramBotTokenStore(secureStorage: SecureKeysService(secureStorage: EphemeralSecureKeyValueStore()))
        XCTAssertFalse(ephemeral.persistsAcrossLaunches)
        let token = try XCTUnwrap(TelegramBotToken(Self.syntheticToken))
        XCTAssertEqual(ephemeral.save(token), .succeeded)
        XCTAssertEqual(ephemeral.read(), .token(token))

        XCTAssertTrue(store(TestSecureStorageBackend()).persistsAcrossLaunches)
    }

    func testSavedTokenNeverReachesDefaultsOrReadResultSurfaces() throws {
        let backend = TestSecureStorageBackend()
        let store = store(backend)
        let token = try XCTUnwrap(TelegramBotToken(Self.syntheticToken))
        XCTAssertEqual(store.save(token), .succeeded)
        let read = store.read()

        var dumped = ""
        dump(read, to: &dumped)
        for surface in [String(describing: read), String(reflecting: read), dumped] {
            XCTAssertFalse(surface.contains(Self.syntheticSecret), surface)
        }
        let defaults = String(describing: UserDefaults.standard.dictionaryRepresentation())
        XCTAssertFalse(defaults.contains(Self.syntheticSecret))
    }

    // MARK: - Helpers

    private func store(_ backend: TestSecureStorageBackend) -> TelegramBotTokenStore {
        TelegramBotTokenStore(secureStorage: SecureKeysService(secureStorage: backend))
    }

    private func assertNonInteractiveOnly(
        _ backend: TestSecureStorageBackend,
        operations: [TestSecureStorageBackend.Operation],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(backend.calls.map(\.operation), operations, file: file, line: line)
        for call in backend.calls {
            XCTAssertTrue(call.accessMode.isNonInteractive, file: file, line: line)
            XCTAssertEqual(call.accessMode, TelegramBotTokenStore.accessMode, file: file, line: line)
        }
    }
}
