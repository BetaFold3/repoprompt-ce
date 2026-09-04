import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIAPIModelMetadataResolverTests: XCTestCase {
    func testOverrideReplacesWholeRowAndAddsRows() throws {
        let resolver = try makeResolver()
        let resolution = resolver.reload(overrideData: data(
            """
            {
              "schema_version":2,
              "models":[
                {"id":"baseline","display_name":"Replacement","protocols":["chat_completions"],"streaming":false},
                {"id":"added","protocols":["responses"],"streaming":true}
              ]
            }
            """
        ))

        XCTAssertEqual(resolution.rows.map(\.id), ["baseline", "added"])
        XCTAssertEqual(resolution.rows.first?.displayName, "Replacement")
        XCTAssertEqual(resolution.rows.first?.protocols, [.chatCompletions])
        XCTAssertFalse(resolution.rows.first?.supportsStreaming ?? true)
        XCTAssertNil(resolution.rows.first?.reasoning)
        XCTAssertEqual(resolution.status.overrideCount, 2)
        XCTAssertEqual(resolution.status.overriddenCount, 1)
    }

    func testDisabledIDsSuppressMergedRows() throws {
        let resolver = try makeResolver()
        let resolution = resolver.reload(overrideData: data(
            """
            {
              "schema_version":2,
              "models":[],
              "disabled_model_ids":["baseline"]
            }
            """
        ))

        XCTAssertEqual(resolution.rows, [])
        XCTAssertEqual(resolution.status.disabledCount, 1)
    }

    func testMalformedOverrideRetainsLastGoodLocalLayer() throws {
        let resolver = try makeResolver()
        let loaded = resolver.reload(overrideData: data(
            #"{"schema_version":2,"models":[{"id":"local","protocols":["responses"],"streaming":true}]}"#
        ))
        XCTAssertEqual(loaded.rows.map(\.id), ["baseline", "local"])

        let failed = resolver.reload(overrideData: Data("{".utf8))

        XCTAssertEqual(failed.rows.map(\.id), ["baseline", "local"])
        XCTAssertEqual(failed.status.overrideState, .failed(.malformedJSON))
        XCTAssertEqual(failed.status.overrideCount, 1)
    }

    func testMissingOverrideFileClearsLastGoodLocalLayer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("metadata.json")
        try data(
            #"{"schema_version":2,"models":[{"id":"local","protocols":["responses"],"streaming":true}]}"#
        ).write(to: fileURL)
        let resolver = try makeResolver(overrideFileURL: fileURL)

        XCTAssertEqual(resolver.reloadFromFile().rows.map(\.id), ["baseline", "local"])
        try FileManager.default.removeItem(at: fileURL)
        let cleared = resolver.reloadFromFile()

        XCTAssertEqual(cleared.rows.map(\.id), ["baseline"])
        XCTAssertEqual(cleared.status.overrideState, .absent)
        XCTAssertEqual(cleared.status.overrideCount, 0)
    }

    func testStaticWireIDOwnershipRemovesCollisionAndAccountsForIt() throws {
        let resolver = try makeResolver(staticModelIDs: ["baseline"])
        let resolution = resolver.currentResolution()

        XCTAssertEqual(resolution.rows, [])
        XCTAssertEqual(resolution.staticOwnedRows.map(\.id), ["baseline"])
        XCTAssertEqual(resolution.status.staticCollisionCount, 1)
        XCTAssertEqual(resolution.status.resolvedCount, 0)

        let registry = OpenAIAPIModelMetadataRegistry()
        registry.update(resolution: resolution)
        XCTAssertEqual(registry.rows.map(\.id), ["baseline"])
        XCTAssertEqual(registry.displayName(for: "baseline"), "Baseline")
    }

    func testInitialResolutionFallsBackToBaselineAndRegistrySnapshotsSynchronously() throws {
        let resolver = try makeResolver()
        let resolution = resolver.currentResolution()
        let registry = OpenAIAPIModelMetadataRegistry()
        registry.update(resolution: resolution)

        XCTAssertEqual(resolution.rows.map(\.id), ["baseline"])
        XCTAssertEqual(resolution.status.overrideState, .absent)
        XCTAssertEqual(registry.rows.map(\.id), ["baseline"])
        XCTAssertEqual(registry.displayName(for: "baseline"), "Baseline")

        let row = try XCTUnwrap(resolution.rows.first)
        registry.update(rows: [row, row])
        XCTAssertEqual(registry.rows.map(\.id), ["baseline", "baseline"])
        XCTAssertEqual(registry.displayName(for: "baseline"), "Baseline")
    }

    func testStatusIncludesRejectedAndDuplicateOverrideRows() throws {
        let resolver = try makeResolver()
        let resolution = resolver.reload(overrideData: data(
            """
            {
              "schema_version":2,
              "models":[
                {"id":"local","protocols":["responses"],"streaming":true},
                {"id":"bad id","protocols":["responses"],"streaming":true},
                {"id":"local","protocols":["responses"],"streaming":true}
              ]
            }
            """
        ))

        XCTAssertEqual(resolution.status.rejectedCount, 1)
        XCTAssertEqual(resolution.status.duplicateWarningCount, 1)
    }

    private func makeResolver(
        overrideFileURL: URL? = nil,
        staticModelIDs: Set<String> = []
    ) throws -> OpenAIAPIModelMetadataResolver {
        try OpenAIAPIModelMetadataResolver(
            baselineData: data(
                """
                {
                  "schema_version":2,
                  "models":[{
                    "id":"baseline",
                    "display_name":"Baseline",
                    "protocols":["responses"],
                    "reasoning":{"modes":["standard"],"efforts":["medium"]},
                    "streaming":true
                  }]
                }
                """
            ),
            overrideFileURL: overrideFileURL,
            staticModelIDs: staticModelIDs
        )
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
