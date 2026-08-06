import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorModelParameterCatalogTests: XCTestCase {
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

        let catalog = CursorModelParameterCatalog()
        XCTAssertTrue(catalog.apply(response: result))

        let specs = try XCTUnwrap(catalog.parameterSpecs(forModel: expected.0))
        let spec = try XCTUnwrap(specs.first(where: {
            $0.id == expected.1["id"] as? String
        }))
        XCTAssertEqual(spec.category, "thought_level")
        XCTAssertEqual(spec.defaultValue, expected.1["currentValue"] as? String)
        XCTAssertFalse(spec.defaultValue.isEmpty)
        XCTAssertFalse(spec.options.isEmpty)
    }

    func testMalformedEntriesAreSkippedWithoutThrowing() {
        let catalog = CursorModelParameterCatalog()
        let response: [String: Any] = [
            "models": [
                ["value": 42, "configOptions": []],
                [
                    "value": "valid-model",
                    "configOptions": [
                        ["id": "missing-fields"],
                        [
                            "id": "effort",
                            "category": "thought_level",
                            "type": "select",
                            "currentValue": "high",
                            "options": [
                                ["value": "low", "name": "Low"],
                                ["value": 7, "name": "Malformed"],
                                ["value": "high", "name": "High"]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        XCTAssertTrue(catalog.apply(response: response))
        let specs = catalog.parameterSpecs(forModel: "valid-model")
        XCTAssertEqual(specs?.map(\.id), ["effort"])
        XCTAssertEqual(specs?.first?.options.map(\.value), ["low", "high"])
    }

    func testMalformedSuccessfulResponseClearsButValidUnchangedRetainsCatalog() {
        let catalog = CursorModelParameterCatalog()
        XCTAssertTrue(catalog.apply(response: validResponse()))
        let retained = catalog.currentSnapshot()

        XCTAssertFalse(catalog.apply(response: validResponse()))
        XCTAssertEqual(catalog.currentSnapshot(), retained)

        XCTAssertTrue(catalog.apply(response: ["unexpected": true]))
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
    }

    func testMethodNotFoundClearsRetainedCatalog() {
        let catalog = CursorModelParameterCatalog()
        XCTAssertTrue(catalog.apply(response: validResponse()))
        XCTAssertFalse(catalog.currentSnapshot().isEmpty)

        XCTAssertTrue(catalog.clearForMethodNotFound())
        XCTAssertTrue(catalog.currentSnapshot().isEmpty)
    }

    func testChangeNotificationFires() {
        let notificationCenter = NotificationCenter()
        let catalog = CursorModelParameterCatalog(notificationCenter: notificationCenter)
        let changed = expectation(
            forNotification: .cursorModelParameterCatalogDidChange,
            object: catalog,
            notificationCenter: notificationCenter
        )

        XCTAssertTrue(catalog.apply(response: validResponse()))
        wait(for: [changed], timeout: 1)
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
                "configOptions": [[
                    "id": "effort",
                    "category": "thought_level",
                    "type": "select",
                    "currentValue": "medium",
                    "options": [
                        ["value": "medium", "name": "Medium"],
                        ["value": "high", "name": "High"]
                    ]
                ]]
            ]]
        ]
    }
}
