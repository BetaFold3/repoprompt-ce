import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorModelParameterCatalogTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: CursorModelParameterStore!
    private var notificationCenter: NotificationCenter!
    private var catalog: CursorModelParameterCatalog!

    override func setUp() {
        super.setUp()
        suiteName = "CursorModelParameterCatalogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = CursorModelParameterStore(defaults: defaults)
        notificationCenter = NotificationCenter()
        catalog = CursorModelParameterCatalog(
            store: store,
            notificationCenter: notificationCenter
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        catalog = nil
        notificationCenter = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testFixtureParsesThoughtLevelDefaultsAndOptions() throws {
        let result = try fixtureResult()
        let models = try XCTUnwrap(result["models"] as? [[String: Any]])
        let expected = try XCTUnwrap(models.lazy.compactMap { model -> (String, [String: Any])? in
            guard let base = model["value"] as? String,
                  let options = model["configOptions"] as? [[String: Any]],
                  let thought = options.first(where: { $0["category"] as? String == "thought_level" })
            else {
                return nil
            }
            return (base, thought)
        }.first)

        XCTAssertEqual(apply(result), .applied(didChange: true))

        let specs = try XCTUnwrap(catalog.parameterSpecs(forModel: expected.0))
        let spec = try XCTUnwrap(specs.first(where: {
            $0.id == expected.1["id"] as? String
        }))
        XCTAssertEqual(spec.category, "thought_level")
        XCTAssertEqual(spec.defaultValue, expected.1["currentValue"] as? String)
        XCTAssertFalse(spec.defaultValue.isEmpty)
        XCTAssertFalse(spec.options.isEmpty)
    }

    func testApplyMalformedResponseRetainsLastGoodCatalogAndStore() throws {
        XCTAssertEqual(apply(validResponse()), .applied(didChange: true))
        let retained = catalog.currentSnapshot()
        let retainedData = try XCTUnwrap(
            defaults.data(forKey: CursorModelParameterStore.storageKey)
        )

        let malformed: [String: Any] = [
            "models": [
                ["value": "valid-model", "configOptions": []],
                ["value": 42, "configOptions": []]
            ]
        ]
        XCTAssertEqual(apply(malformed), .rejectedMalformed)
        XCTAssertEqual(catalog.currentSnapshot(), retained)
        XCTAssertEqual(
            defaults.data(forKey: CursorModelParameterStore.storageKey),
            retainedData
        )
        XCTAssertEqual(catalog.status().state, .stale(.malformedResponse))
        XCTAssertTrue(catalog.status().hasUsableCatalog)
    }

    func testAbsentConfigOptionsIsValidZeroAxisModel() {
        XCTAssertEqual(
            apply(["models": [["value": " zero-axis "]]]),
            .applied(didChange: true)
        )
        XCTAssertEqual(catalog.parameterSpecs(forModel: "ZERO-AXIS"), [])
    }

    func testUnknownWellFormedNonSelectOptionIsSkipped() throws {
        let response: [String: Any] = [
            "models": [[
                "value": "model",
                "configOptions": [
                    ["type": "boolean", "id": "future-option"],
                    selectSpec()
                ]
            ]]
        ]

        XCTAssertEqual(apply(response), .applied(didChange: true))
        XCTAssertEqual(try XCTUnwrap(catalog.parameterSpecs(forModel: "model")).map(\.id), ["effort"])
    }

    func testDuplicateNormalizedBaseRejectsWholeResponse() {
        assertRejectedAndRetained([
            "models": [
                ["value": " Model ", "configOptions": []],
                ["value": "cursor:model", "configOptions": []]
            ]
        ])
    }

    func testDuplicateSelectIDAfterTrimmingCaseInsensitivelyRejectsWholeResponse() {
        var duplicate = selectSpec()
        duplicate["id"] = " EFFORT "
        assertRejectedAndRetained([
            "models": [[
                "value": "other",
                "configOptions": [selectSpec(), duplicate]
            ]]
        ])
    }

    func testDuplicateOptionValueAfterTrimmingRejectsWholeResponse() {
        var spec = selectSpec()
        spec["options"] = [
            ["value": "high", "name": "High"],
            ["value": " high ", "name": "Duplicate"]
        ]
        assertRejectedAndRetained([
            "models": [["value": "other", "configOptions": [spec]]]
        ])
    }

    func testMalformedSelectSpecRejectsWholeResponse() {
        var spec = selectSpec()
        spec["currentValue"] = "missing-from-options"
        assertRejectedAndRetained([
            "models": [["value": "other", "configOptions": [spec]]]
        ])
    }

    func testPresentNonArrayConfigOptionsRejectsWholeResponse() {
        assertRejectedAndRetained([
            "models": [["value": "other", "configOptions": "invalid"]]
        ])
    }

    func testValidEmptyResponseAuthoritativelyClearsMemoryAndStore() {
        XCTAssertEqual(apply(validResponse()), .applied(didChange: true))
        XCTAssertNotNil(defaults.object(forKey: CursorModelParameterStore.storageKey))

        XCTAssertEqual(apply(["models": []]), .applied(didChange: true))
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
        XCTAssertNil(defaults.object(forKey: CursorModelParameterStore.storageKey))
        XCTAssertEqual(catalog.status().state, .live)
        XCTAssertFalse(catalog.status().hasUsableCatalog)
    }

    func testMethodNotFoundAuthoritativelyClearsMemoryAndStore() {
        XCTAssertEqual(apply(validResponse()), .applied(didChange: true))

        XCTAssertTrue(catalog.clearForMethodNotFound(
            at: Date(timeIntervalSince1970: 50)
        ))
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
        XCTAssertNil(defaults.object(forKey: CursorModelParameterStore.storageKey))
        XCTAssertEqual(catalog.status().state, .unsupported)
        XCTAssertFalse(catalog.status().hasUsableCatalog)
        XCTAssertEqual(
            catalog.status().lastAttempt,
            Date(timeIntervalSince1970: 50)
        )
    }

    func testCorruptAndUnknownStoreBytesSurviveAuthoritativeEmptySignalsUntilNonemptyApply() throws {
        let unknownVersion = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "updatedAt": 0,
            "models": []
        ])
        for preserved in [Data("{not-json".utf8), unknownVersion] {
            defaults.set(preserved, forKey: CursorModelParameterStore.storageKey)
            catalog = CursorModelParameterCatalog(
                store: store,
                notificationCenter: notificationCenter
            )

            XCTAssertTrue(catalog.currentSnapshot().isEmpty)
            XCTAssertFalse(catalog.clearForMethodNotFound())
            XCTAssertEqual(
                defaults.data(forKey: CursorModelParameterStore.storageKey),
                preserved
            )

            XCTAssertEqual(
                apply(["models": []]),
                .applied(didChange: false)
            )
            XCTAssertEqual(
                defaults.data(forKey: CursorModelParameterStore.storageKey),
                preserved
            )

            XCTAssertEqual(apply(validResponse()), .applied(didChange: true))
            XCTAssertNotEqual(
                defaults.data(forKey: CursorModelParameterStore.storageKey),
                preserved
            )
            XCTAssertNotNil(store.load())
        }
    }

    func testHydrationProducesCachedUsableStatusWithoutRewritingStore() throws {
        let updatedAt = Date(timeIntervalSince1970: 123)
        XCTAssertTrue(store.save(snapshot(), updatedAt: updatedAt))
        let original = try XCTUnwrap(
            defaults.data(forKey: CursorModelParameterStore.storageKey)
        )
        let hydrated = CursorModelParameterCatalog(
            store: store,
            notificationCenter: notificationCenter
        )

        hydrated.hydrateSynchronously()

        XCTAssertEqual(hydrated.currentSnapshot(), snapshot())
        XCTAssertEqual(hydrated.status().state, .cached)
        XCTAssertTrue(hydrated.status().hasUsableCatalog)
        XCTAssertEqual(hydrated.status().lastSuccessfulRefresh, updatedAt)
        XCTAssertNil(hydrated.status().lastAttempt)
        XCTAssertEqual(
            defaults.data(forKey: CursorModelParameterStore.storageKey),
            original
        )
    }

    func testStatusChurnUsesOnlyStatusNotification() {
        var dataNotifications = 0
        var statusNotifications = 0
        let dataToken = notificationCenter.addObserver(
            forName: .cursorModelParameterCatalogDidChange,
            object: catalog,
            queue: nil
        ) { _ in
            dataNotifications += 1
        }
        let statusToken = notificationCenter.addObserver(
            forName: .cursorModelParameterCatalogStatusDidChange,
            object: catalog,
            queue: nil
        ) { _ in
            statusNotifications += 1
        }
        defer {
            notificationCenter.removeObserver(dataToken)
            notificationCenter.removeObserver(statusToken)
        }

        XCTAssertEqual(apply(validResponse()), .applied(didChange: true))
        catalog.markRefreshing(at: Date(timeIntervalSince1970: 10))
        catalog.markStale(.timeout, at: Date(timeIntervalSince1970: 11))
        XCTAssertEqual(apply(validResponse()), .applied(didChange: false))

        XCTAssertEqual(dataNotifications, 1)
        XCTAssertEqual(statusNotifications, 4)
    }

    func testRestoreSnapshotNeverMutatesInjectedStore() throws {
        XCTAssertTrue(store.save(snapshot(), updatedAt: Date(timeIntervalSince1970: 1)))
        let original = try XCTUnwrap(
            defaults.data(forKey: CursorModelParameterStore.storageKey)
        )
        let restored: [String: [CursorModelParameterCatalog.ParameterSpec]] = [
            "restored": []
        ]

        XCTAssertTrue(catalog.test_restoreSnapshot(restored))

        XCTAssertEqual(catalog.currentSnapshot(), restored)
        XCTAssertEqual(
            defaults.data(forKey: CursorModelParameterStore.storageKey),
            original
        )
    }

    func testDataNotificationAllowsReentrantAuthoritativeClear() {
        var didReenter = false
        let token = notificationCenter.addObserver(
            forName: .cursorModelParameterCatalogDidChange,
            object: catalog,
            queue: nil
        ) { _ in
            guard !didReenter else { return }
            didReenter = true
            _ = self.catalog.clearForMethodNotFound()
        }
        defer { notificationCenter.removeObserver(token) }

        XCTAssertEqual(apply(validResponse()), .applied(didChange: true))

        XCTAssertTrue(didReenter)
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
        XCTAssertEqual(catalog.status().state, .unsupported)
    }

    func testDefaultConstructedCatalogsUseIsolatedTransientStores() {
        let first = CursorModelParameterCatalog(notificationCenter: NotificationCenter())
        let second = CursorModelParameterCatalog(notificationCenter: NotificationCenter())
        let result: CursorModelParameterCatalog.ApplyResult = first.apply(
            response: validResponse()
        )

        XCTAssertEqual(result, .applied(didChange: true))
        XCTAssertNil(second.parameterSpecs(forModel: "model"))
    }

    private func assertRejectedAndRetained(
        _ response: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            apply(validResponse()),
            .applied(didChange: true),
            file: file,
            line: line
        )
        let retained = catalog.currentSnapshot()

        XCTAssertEqual(apply(response), .rejectedMalformed, file: file, line: line)
        XCTAssertEqual(catalog.currentSnapshot(), retained, file: file, line: line)
    }

    private func apply(_ response: Any) -> CursorModelParameterCatalog.ApplyResult {
        catalog.apply(response: response)
    }

    private func fixtureResult() throws -> [String: Any] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CursorACP/list_available_models.json")
        let data = try Data(contentsOf: fixtureURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(payload["result"] as? [String: Any])
    }

    private func validResponse() -> [String: Any] {
        [
            "models": [[
                "value": "model",
                "configOptions": [selectSpec()]
            ]]
        ]
    }

    private func selectSpec() -> [String: Any] {
        [
            "id": "effort",
            "category": "thought_level",
            "type": "select",
            "currentValue": "medium",
            "options": [
                ["value": "medium", "name": "Medium"],
                ["value": "high", "name": "High"]
            ]
        ]
    }

    private func snapshot() -> [String: [CursorModelParameterCatalog.ParameterSpec]] {
        [
            "model": [.init(
                id: "effort",
                category: "thought_level",
                defaultValue: "medium",
                options: [
                    .init(value: "medium", name: "Medium"),
                    .init(value: "high", name: "High")
                ],
                description: nil
            )]
        ]
    }
}
