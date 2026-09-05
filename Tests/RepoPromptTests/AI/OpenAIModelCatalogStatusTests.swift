import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIModelCatalogStatusTests: XCTestCase {
    func testNilRequestAndLiveScopesAreNotSuccessfulLiveRefresh() {
        XCTAssertFalse(OpenAIModelCatalogStatus.hasSuccessfulLiveRefresh(
            requestScope: nil,
            liveRefreshScope: nil
        ))
    }

    func testStatusProjectsSourcesCountsDiscoveryAndExactCustomVisibility() throws {
        let overrideURL = URL(fileURLWithPath: "/tmp/ModelCatalog/openai-model-metadata-v1.json")
        let resolver = try OpenAIAPIModelMetadataResolver(
            overrideFileURL: overrideURL,
            staticModelIDs: []
        )
        let resolution = resolver.reload(overrideData: Data(
            """
            {"schema_version":2,"models":[
              {"id":"gpt-6-astra","protocols":["responses"],"streaming":true},
              {"id":"override-only","protocols":["responses"],"streaming":true}
            ],"disabled_model_ids":["disabled"]}
            """.utf8
        ))
        let scope = try XCTUnwrap(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://api.openai.com/v1",
            apiKey: "super-secret"
        ))
        let shutdown = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: ["gpt-6-astra"],
            refreshedAt: Date(timeIntervalSince1970: 100),
            generation: 1,
            models: [.init(id: "gpt-6-astra", shutdownDate: shutdown)]
        )

        let status = OpenAIModelCatalogStatus.make(
            resolution: resolution,
            baselineVersion: OpenAIAPIModelMetadataBaseline.baselineVersion,
            overrideFileURL: overrideURL,
            snapshot: snapshot,
            hasSuccessfulLiveRefresh: true,
            refreshFailure: nil,
            normalizedEndpoint: scope.normalizedEndpoint,
            typedCustomModelID: "gpt-6-astra",
            projectedMetadataRowCount: 1
        )

        XCTAssertEqual(status.metadataSource, .baselineWithOverride(version: "2026-09-04"))
        XCTAssertEqual(status.overrideState, .loaded(path: overrideURL.path))
        XCTAssertEqual(status.resolverCounts.baseline, 1)
        XCTAssertEqual(status.resolverCounts.override, 2)
        XCTAssertEqual(status.resolverCounts.overridden, 1)
        XCTAssertEqual(status.resolverCounts.disabled, 1)
        XCTAssertEqual(status.resolverCounts.projected, 1)
        XCTAssertEqual(status.discoverySource, .live)
        XCTAssertEqual(status.visibleModelIDCount, 1)
        XCTAssertTrue(status.isTypedCustomModelIDVisible)
        XCTAssertEqual(status.shutdownDatesByModelID["gpt-6-astra"], shutdown)

        let displayable = String(describing: status)
        XCTAssertFalse(displayable.contains("super-secret"))
        XCTAssertFalse(displayable.contains(scope.keyFingerprint))
        XCTAssertEqual(status.normalizedEndpoint, "https://api.openai.com/v1")
    }

    func testCredentialBearingEndpointIsRejectedFromDisplayStatus() throws {
        let resolver = try OpenAIAPIModelMetadataResolver()
        let status = OpenAIModelCatalogStatus.make(
            resolution: resolver.currentResolution(),
            baselineVersion: "baseline",
            overrideFileURL: URL(fileURLWithPath: "/tmp/metadata.json"),
            snapshot: nil,
            hasSuccessfulLiveRefresh: false,
            refreshFailure: nil,
            normalizedEndpoint: "https://user:secret@proxy.example.com/v1?token=abc",
            typedCustomModelID: nil,
            projectedMetadataRowCount: 0
        )

        XCTAssertNil(status.normalizedEndpoint)
        let displayable = String(describing: status)
        for sentinel in ["user", "secret", "token"] {
            XCTAssertFalse(displayable.contains(sentinel))
        }
    }

    func testEmptyLastGoodOverrideAndPreservedRefreshFailureRemainVisibleAfterDecodeFailure() throws {
        let overrideURL = URL(fileURLWithPath: "/tmp/ModelCatalog/openai-model-metadata-v1.json")
        let resolver = try OpenAIAPIModelMetadataResolver(overrideFileURL: overrideURL)
        _ = resolver.reload(overrideData: Data(#"{"schema_version":2,"models":[]}"#.utf8))
        let failed = resolver.reload(overrideData: Data("{".utf8))

        let status = OpenAIModelCatalogStatus.make(
            resolution: failed,
            baselineVersion: "baseline",
            overrideFileURL: overrideURL,
            snapshot: nil,
            hasSuccessfulLiveRefresh: false,
            refreshFailure: nil,
            preservedLastError: "Model discovery failed. Try refreshing again.",
            normalizedEndpoint: nil,
            typedCustomModelID: nil,
            projectedMetadataRowCount: 0
        )

        XCTAssertEqual(status.metadataSource, .baselineWithOverride(version: "baseline"))
        XCTAssertEqual(status.lastError, "Model discovery failed. Try refreshing again.")
    }

    func testMalformedOverrideAndCachedFailureRemainDisplayableWithoutLeakingCredentials() throws {
        let overrideURL = URL(fileURLWithPath: "/tmp/ModelCatalog/openai-model-metadata-v1.json")
        let resolver = try OpenAIAPIModelMetadataResolver(overrideFileURL: overrideURL)
        _ = resolver.reload(overrideData: Data(
            #"{"schema_version":2,"models":[{"id":"kept","protocols":["responses"],"streaming":true},{"id":"bad id","protocols":["responses"],"streaming":true}]}"#.utf8
        ))
        let resolution = resolver.reload(overrideData: Data("{".utf8))
        let scope = try XCTUnwrap(APIModelCatalogScope(
            providerID: "openai",
            endpoint: "https://api.openai.com/v1",
            apiKey: "never-display"
        ))
        let snapshot = APIModelCatalogSnapshot(
            scope: scope,
            modelIDs: ["Case-Sensitive"],
            refreshedAt: Date(timeIntervalSince1970: 100),
            generation: 1
        )
        let status = OpenAIModelCatalogStatus.make(
            resolution: resolution,
            baselineVersion: "baseline",
            overrideFileURL: overrideURL,
            snapshot: snapshot,
            hasSuccessfulLiveRefresh: false,
            refreshFailure: .init(reason: .requestFailed, failedAt: Date()),
            normalizedEndpoint: scope.normalizedEndpoint,
            typedCustomModelID: "case-sensitive",
            projectedMetadataRowCount: 0
        )

        guard case let .failed(message, path) = status.overrideState else {
            return XCTFail("Expected failed override state")
        }
        XCTAssertTrue(message.contains("malformed JSON"))
        XCTAssertEqual(path, overrideURL.path)
        XCTAssertEqual(status.discoverySource, .cached)
        XCTAssertEqual(status.lastError, "Model discovery failed. Try refreshing again.")
        XCTAssertLessThanOrEqual(status.lastError?.count ?? .max, 80)
        XCTAssertFalse(status.isTypedCustomModelIDVisible)
        XCTAssertEqual(status.resolverCounts.override, 1, "last-good override remains active")
        XCTAssertEqual(status.resolverCounts.rejected, 1)
        XCTAssertEqual(status.resolverCounts.rejectedByReason, [.invalidModelID: 1])
        XCTAssertEqual(status.resolverCounts.projected, 0)
        XCTAssertFalse(String(describing: status).contains("never-display"))
        XCTAssertFalse(String(describing: status).contains(scope.keyFingerprint))

        let forbiddenSentinels = [
            "never-display",
            scope.keyFingerprint,
            "user:password",
            "query-token",
            "Authorization",
            "%2Fsecret",
            String(repeating: "x", count: 1000)
        ]
        for sentinel in forbiddenSentinels {
            XCTAssertFalse(status.lastError?.contains(sentinel) ?? false)
        }
    }
}
