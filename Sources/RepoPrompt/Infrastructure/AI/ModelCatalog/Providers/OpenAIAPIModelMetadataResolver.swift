import Foundation

enum OpenAIAPIModelMetadataOverrideState: Equatable {
    case absent
    case loaded
    case failed(OpenAIAPIModelMetadataError)
}

struct OpenAIAPIModelMetadataResolutionStatus: Equatable {
    let overrideState: OpenAIAPIModelMetadataOverrideState
    let baselineCount: Int
    let overrideCount: Int
    let overriddenCount: Int
    let disabledCount: Int
    let rejectedCount: Int
    let duplicateWarningCount: Int
    let staticCollisionCount: Int
    let resolvedCount: Int
}

struct OpenAIAPIModelMetadataResolution: Equatable {
    let rows: [OpenAIAPIModelMetadata]
    let staticOwnedRows: [OpenAIAPIModelMetadata]
    let status: OpenAIAPIModelMetadataResolutionStatus
}

final class OpenAIAPIModelMetadataResolver: @unchecked Sendable {
    private let baselineReport: OpenAIAPIModelMetadataDecodeReport
    private let overrideFileURL: URL?
    private let staticModelIDs: Set<String>
    private let lock = NSLock()

    private var lastGoodOverrideReport: OpenAIAPIModelMetadataDecodeReport?
    private var overrideState: OpenAIAPIModelMetadataOverrideState = .absent

    init(
        baselineData: Data = OpenAIAPIModelMetadataBaseline.data,
        overrideFileURL: URL? = nil,
        staticModelIDs: Set<String> = []
    ) throws {
        baselineReport = try OpenAIAPIModelMetadataDecoder.decodeWithReport(baselineData)
        self.overrideFileURL = overrideFileURL
        self.staticModelIDs = staticModelIDs
    }

    func currentResolution() -> OpenAIAPIModelMetadataResolution {
        lock.lock()
        defer { lock.unlock() }
        return makeResolutionLocked()
    }

    @discardableResult
    func reload(overrideData: Data?) -> OpenAIAPIModelMetadataResolution {
        lock.lock()
        defer { lock.unlock() }

        guard let overrideData else {
            lastGoodOverrideReport = nil
            overrideState = .absent
            return makeResolutionLocked()
        }

        do {
            lastGoodOverrideReport = try OpenAIAPIModelMetadataDecoder.decodeWithReport(overrideData)
            overrideState = .loaded
        } catch let error as OpenAIAPIModelMetadataError {
            overrideState = .failed(error)
        } catch {
            overrideState = .failed(.invalidDocument)
        }
        return makeResolutionLocked()
    }

    @discardableResult
    func reloadFromFile(
        fileManager: FileManager = .default
    ) -> OpenAIAPIModelMetadataResolution {
        lock.lock()
        defer { lock.unlock() }

        guard let overrideFileURL else {
            lastGoodOverrideReport = nil
            overrideState = .absent
            return makeResolutionLocked()
        }
        guard fileManager.fileExists(atPath: overrideFileURL.path) else {
            lastGoodOverrideReport = nil
            overrideState = .absent
            return makeResolutionLocked()
        }

        do {
            lastGoodOverrideReport = try OpenAIAPIModelMetadataDecoder.decodeWithReport(
                contentsOf: overrideFileURL
            )
            overrideState = .loaded
        } catch let error as OpenAIAPIModelMetadataError {
            overrideState = .failed(error)
        } catch {
            overrideState = .failed(.invalidDocument)
        }
        return makeResolutionLocked()
    }

    private func makeResolutionLocked() -> OpenAIAPIModelMetadataResolution {
        let overrideReport = lastGoodOverrideReport
        var rowsByID = Dictionary(
            uniqueKeysWithValues: baselineReport.document.models.map { ($0.id, $0) }
        )
        var orderedIDs = baselineReport.document.models.map(\.id)
        var overriddenCount = 0

        if let overrideReport {
            for row in overrideReport.document.models {
                if rowsByID.updateValue(row, forKey: row.id) != nil {
                    overriddenCount += 1
                } else {
                    orderedIDs.append(row.id)
                }
            }
        }

        let disabledIDs = Set(baselineReport.document.disabledModelIDs)
            .union(overrideReport?.document.disabledModelIDs ?? [])
        let enabledRows = orderedIDs.compactMap { id -> OpenAIAPIModelMetadata? in
            guard !disabledIDs.contains(id) else { return nil }
            return rowsByID[id]
        }
        let staticOwnedRows = enabledRows.filter { staticModelIDs.contains($0.id) }
        let rows = enabledRows.filter { !staticModelIDs.contains($0.id) }

        let status = OpenAIAPIModelMetadataResolutionStatus(
            overrideState: overrideState,
            baselineCount: baselineReport.document.models.count,
            overrideCount: overrideReport?.document.models.count ?? 0,
            overriddenCount: overriddenCount,
            disabledCount: disabledIDs.count,
            rejectedCount: (overrideReport?.rejectedRows.count ?? 0)
                + baselineReport.rejectedRows.count,
            duplicateWarningCount: (overrideReport?.duplicateWarnings.count ?? 0)
                + baselineReport.duplicateWarnings.count,
            staticCollisionCount: staticOwnedRows.count,
            resolvedCount: rows.count
        )
        return OpenAIAPIModelMetadataResolution(
            rows: rows,
            staticOwnedRows: staticOwnedRows,
            status: status
        )
    }
}
