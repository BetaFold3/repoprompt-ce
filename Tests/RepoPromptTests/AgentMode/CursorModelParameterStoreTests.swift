import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorModelParameterStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: CursorModelParameterStore!

    override func setUp() {
        super.setUp()
        suiteName = "CursorModelParameterStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = CursorModelParameterStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testRoundTripPreservesSnapshotAndTimestamp() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let models = sampleModels()

        XCTAssertTrue(store.save(models, updatedAt: updatedAt))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.updatedAt, updatedAt)
        XCTAssertEqual(loaded.models, models)
    }

    func testSaveCanonicalizesBaseOrderingAndTrimmedFields() throws {
        let models: [String: [CursorModelParameterCatalog.ParameterSpec]] = [
            " ZETA ": [],
            "Cursor:Alpha": [.init(
                id: " effort ",
                category: " thought_level ",
                defaultValue: " high ",
                options: [
                    .init(value: " low ", name: " Low "),
                    .init(value: " high ", name: " High ")
                ],
                description: " Description "
            )]
        ]

        XCTAssertTrue(store.save(models, updatedAt: Date(timeIntervalSince1970: 10)))
        let data = try XCTUnwrap(defaults.data(forKey: CursorModelParameterStore.storageKey))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedModels = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(encodedModels.compactMap { $0["base"] as? String }, ["alpha", "zeta"])

        let loaded = try XCTUnwrap(store.load())
        let parameter = try XCTUnwrap(loaded.models["alpha"]?.first)
        XCTAssertEqual(parameter.id, "effort")
        XCTAssertEqual(parameter.category, "thought_level")
        XCTAssertEqual(parameter.defaultValue, "high")
        XCTAssertEqual(parameter.options.map(\.value), ["low", "high"])
        XCTAssertEqual(parameter.options.map(\.name), ["Low", "High"])
        XCTAssertEqual(parameter.description, "Description")
    }

    func testSaveNeverWritesEmptyCatalog() {
        let original = Data("existing".utf8)
        defaults.set(original, forKey: CursorModelParameterStore.storageKey)

        XCTAssertFalse(store.save([:]))
        XCTAssertEqual(defaults.data(forKey: CursorModelParameterStore.storageKey), original)
    }

    func testClearRemovesStorageKey() {
        XCTAssertTrue(store.save(sampleModels()))
        XCTAssertNotNil(defaults.object(forKey: CursorModelParameterStore.storageKey))

        store.clear()

        XCTAssertNil(defaults.object(forKey: CursorModelParameterStore.storageKey))
    }

    func testClearPreservesCorruptAndUnknownVersionBytes() throws {
        let unknownVersion = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "updatedAt": 0,
            "models": []
        ])
        for preserved in [Data("{not-json".utf8), unknownVersion] {
            defaults.set(preserved, forKey: CursorModelParameterStore.storageKey)

            store.clear()

            XCTAssertEqual(
                defaults.data(forKey: CursorModelParameterStore.storageKey),
                preserved
            )
        }
    }

    func testCorruptDataIsIgnoredAndPreserved() {
        let corrupt = Data("{not-json".utf8)
        defaults.set(corrupt, forKey: CursorModelParameterStore.storageKey)

        XCTAssertNil(store.load())
        XCTAssertEqual(defaults.data(forKey: CursorModelParameterStore.storageKey), corrupt)
    }

    func testUnknownVersionIsIgnoredAndPreserved() throws {
        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "updatedAt": 0,
            "models": []
        ])
        defaults.set(future, forKey: CursorModelParameterStore.storageKey)

        XCTAssertNil(store.load())
        XCTAssertEqual(defaults.data(forKey: CursorModelParameterStore.storageKey), future)
    }

    func testSuccessfulNonemptySaveOverwritesUnknownVersion() throws {
        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "opaque": "preserve-until-success"
        ])
        defaults.set(future, forKey: CursorModelParameterStore.storageKey)

        XCTAssertTrue(store.save(sampleModels()))
        XCTAssertNotEqual(defaults.data(forKey: CursorModelParameterStore.storageKey), future)
        XCTAssertNotNil(store.load())

        let data = try XCTUnwrap(defaults.data(forKey: CursorModelParameterStore.storageKey))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testDedicatedSuitesAreIsolated() throws {
        let otherSuiteName = "CursorModelParameterStoreTests.Other.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuiteName))
        defer { otherDefaults.removePersistentDomain(forName: otherSuiteName) }
        let otherStore = CursorModelParameterStore(defaults: otherDefaults)

        XCTAssertTrue(store.save(sampleModels()))
        XCTAssertNil(otherStore.load())
        XCTAssertNil(otherDefaults.object(forKey: CursorModelParameterStore.storageKey))
    }

    private func sampleModels() -> [String: [CursorModelParameterCatalog.ParameterSpec]] {
        [
            "model": [.init(
                id: "effort",
                category: "thought_level",
                defaultValue: "medium",
                options: [
                    .init(value: "medium", name: "Medium"),
                    .init(value: "high", name: "High")
                ],
                description: "Reasoning effort"
            )]
        ]
    }
}
