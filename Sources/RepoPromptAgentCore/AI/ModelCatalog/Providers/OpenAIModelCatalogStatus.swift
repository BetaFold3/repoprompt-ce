import Foundation

package struct OpenAIModelCatalogStatus: Equatable {
    package enum MetadataSource: Equatable {
        case baselineOnly(version: String)
        case baselineWithOverride(version: String)
    }

    package enum OverrideState: Equatable {
        case absent(path: String)
        case loaded(path: String)
        case failed(message: String, path: String)
    }

    package struct ResolverCounts: Equatable {
        package let baseline: Int
        package let override: Int
        package let overridden: Int
        package let disabled: Int
        package let rejected: Int
        package let rejectedByReason: [OpenAIAPIModelMetadataRowRejectionReason: Int]
        let duplicateWarnings: Int
        let staticOwned: Int
        package let projected: Int
    }

    package enum DiscoverySource: Equatable {
        case live
        case cached
        case none
    }

    package let metadataSource: MetadataSource
    package let overrideState: OverrideState
    package let resolverCounts: ResolverCounts
    package let discoverySource: DiscoverySource
    package let lastRefreshAt: Date?
    package let visibleModelIDCount: Int
    package let lastError: String?
    package let normalizedEndpoint: String?
    package let typedCustomModelID: String?
    package let isTypedCustomModelIDVisible: Bool
    package let shutdownDatesByModelID: [String: Date]

    package static func hasSuccessfulLiveRefresh(
        requestScope: APIModelCatalogScope?,
        liveRefreshScope: APIModelCatalogScope?
    ) -> Bool {
        guard let requestScope else { return false }
        return requestScope == liveRefreshScope
    }

    package static func make(
        resolution: OpenAIAPIModelMetadataResolution,
        baselineVersion: String,
        overrideFileURL: URL,
        snapshot: APIModelCatalogSnapshot?,
        hasSuccessfulLiveRefresh: Bool,
        refreshFailure: APIModelCatalogRefreshFailure?,
        preservedLastError: String? = nil,
        normalizedEndpoint: String?,
        typedCustomModelID: String?,
        projectedMetadataRowCount: Int
    ) -> OpenAIModelCatalogStatus {
        let path = overrideFileURL.standardizedFileURL.path
        let overrideState: OverrideState = switch resolution.status.overrideState {
        case .absent:
            .absent(path: path)
        case .loaded:
            .loaded(path: path)
        case let .failed(error):
            .failed(message: metadataErrorMessage(error), path: path)
        }

        let usesOverride = resolution.status.hasLastGoodOverride
        let metadataSource: MetadataSource = usesOverride
            ? .baselineWithOverride(version: baselineVersion)
            : .baselineOnly(version: baselineVersion)
        let normalizedTypedID = typedCustomModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleIDs = Set(snapshot?.modelIDs ?? [])

        return OpenAIModelCatalogStatus(
            metadataSource: metadataSource,
            overrideState: overrideState,
            resolverCounts: ResolverCounts(
                baseline: resolution.status.baselineCount,
                override: resolution.status.overrideCount,
                overridden: resolution.status.overriddenCount,
                disabled: resolution.status.disabledCount,
                rejected: resolution.status.rejectedCount,
                rejectedByReason: resolution.status.rejectedByReason,
                duplicateWarnings: resolution.status.duplicateWarningCount,
                staticOwned: resolution.status.staticCollisionCount,
                projected: projectedMetadataRowCount
            ),
            discoverySource: snapshot == nil ? .none : (hasSuccessfulLiveRefresh ? .live : .cached),
            lastRefreshAt: snapshot?.refreshedAt,
            visibleModelIDCount: snapshot?.modelIDs.count ?? 0,
            lastError: refreshFailure?.message ?? preservedLastError,
            normalizedEndpoint: normalizedEndpoint.flatMap(APIModelCatalogScope.normalizeEndpoint),
            typedCustomModelID: normalizedTypedID.flatMap { $0.isEmpty ? nil : $0 },
            isTypedCustomModelIDVisible: normalizedTypedID.map(visibleIDs.contains) ?? false,
            shutdownDatesByModelID: Dictionary(
                (snapshot?.models ?? []).compactMap { descriptor in
                    descriptor.shutdownDate.map { (descriptor.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private static func metadataErrorMessage(_ error: OpenAIAPIModelMetadataError) -> String {
        switch error {
        case .unreadable:
            "The override file could not be read."
        case .documentTooLarge:
            "The override file is too large."
        case .malformedJSON:
            "The override file contains malformed JSON."
        case .invalidDocument:
            "The override document is invalid."
        case let .unsupportedSchemaVersion(version):
            "Unsupported override schema version \(version)."
        case let .forbiddenField(field):
            "The override contains forbidden field \(field)."
        case .noValidModels:
            "The override contains no valid model rows."
        }
    }
}
