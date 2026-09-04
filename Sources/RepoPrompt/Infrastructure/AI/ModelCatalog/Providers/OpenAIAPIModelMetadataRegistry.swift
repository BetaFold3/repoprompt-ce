import Foundation

final class OpenAIAPIModelMetadataRegistry: @unchecked Sendable {
    static let shared = OpenAIAPIModelMetadataRegistry(
        rows: (try? OpenAIAPIModelMetadataBaseline.decode().document.models) ?? []
    )

    private let lock = NSLock()
    private var storedRows: [OpenAIAPIModelMetadata]
    private var displayNamesByID: [String: String]

    init(rows: [OpenAIAPIModelMetadata] = []) {
        storedRows = rows
        displayNamesByID = Dictionary(
            rows.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    var rows: [OpenAIAPIModelMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return storedRows
    }

    func displayName(for modelID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return displayNamesByID[modelID]
    }

    func update(rows: [OpenAIAPIModelMetadata]) {
        let displayNames = Dictionary(
            rows.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { _, latest in latest }
        )
        lock.lock()
        storedRows = rows
        displayNamesByID = displayNames
        lock.unlock()
    }

    func update(resolution: OpenAIAPIModelMetadataResolution) {
        update(rows: resolution.rows + resolution.staticOwnedRows)
    }

    #if DEBUG
        func resetForTesting(rows: [OpenAIAPIModelMetadata] = []) {
            update(rows: rows)
        }
    #endif
}
