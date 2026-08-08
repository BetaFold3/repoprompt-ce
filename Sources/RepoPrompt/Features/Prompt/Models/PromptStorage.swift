//
//  PromptStorage.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-21.
//

import Combine
import Foundation

/// <summary>
/// Represents the external structure used for importing and exporting prompts,
/// without relying on our internal UUID.
/// </summary>
struct PromptExport: Codable, Equatable {
    let title: String
    let content: String
}

enum SavedPromptLibraryError: LocalizedError {
    case notLoaded
    case loadFailed(underlying: Error)
    case promptNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            "The saved prompt library is not loaded."
        case let .loadFailed(underlying):
            "The saved prompt library could not be loaded: \(underlying.localizedDescription)"
        case let .promptNotFound(id):
            "The saved prompt \(id.uuidString) no longer exists. It may have been deleted or reset in another window."
        }
    }

    var recoverySuggestion: String? {
        "Check SavedPrompts.json and restart RepoPrompt after resolving the file problem."
    }
}

/// App-wide authority for the saved-prompt library and its persistence.
///
/// The store loads `SavedPrompts.json` at most once, publishes mutations synchronously
/// on the main actor, and serializes atomic writes on its private queue.
@MainActor
final class PromptStorage: ObservableObject {
    typealias StoredPrompt = PromptViewModel.StoredPrompt
    typealias LoadedPromptsResolver = ([StoredPrompt]) -> (prompts: [StoredPrompt], needsSave: Bool)

    static let shared = PromptStorage()

    @Published private(set) var prompts: [StoredPrompt] = []

    private enum LoadState {
        case notLoaded
        case loaded
        case failed(Error)
    }

    private let fileURL: URL
    private let writeQueue: DispatchQueue
    private let persistenceObserver: (([StoredPrompt]) -> Void)?
    private var loadState: LoadState = .notLoaded

    init(
        fileURL: URL? = nil,
        persistenceObserver: (([StoredPrompt]) -> Void)? = nil
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.persistenceObserver = persistenceObserver
        writeQueue = DispatchQueue(label: "com.pvncher.repoprompt.PromptStorageQueue.\(UUID().uuidString)")
    }

    /// Loads and resolves the library once for this store instance.
    /// A failed load is retained and prevents later mutations from overwriting unreadable data.
    @discardableResult
    func loadIfNeeded(resolving resolver: LoadedPromptsResolver) -> Result<[StoredPrompt], Error> {
        switch loadState {
        case .loaded:
            return .success(prompts)
        case let .failed(error):
            return .failure(error)
        case .notLoaded:
            break
        }

        let loadResult = loadPromptsFromDisk()
        switch loadResult {
        case let .success(loadedPrompts):
            let resolved = resolver(loadedPrompts)
            loadState = .loaded
            prompts = resolved.prompts
            if resolved.needsSave {
                persist(resolved.prompts)
            }
            return .success(resolved.prompts)
        case let .failure(error):
            loadState = .failed(error)
            return .failure(error)
        }
    }

    /// Applies one mutation against the current app-wide library snapshot.
    /// The closure returns whether it changed the snapshot and should be published/persisted.
    @discardableResult
    func mutate(_ mutation: (inout [StoredPrompt]) -> Bool) throws -> Bool {
        try requireAvailable()

        var updatedPrompts = prompts
        guard mutation(&updatedPrompts) else { return false }

        prompts = updatedPrompts
        persist(updatedPrompts)
        return true
    }

    /// Replaces the library in one publication and one persistence operation.
    @discardableResult
    func replacePrompts(_ prompts: [StoredPrompt]) throws -> Bool {
        try mutate { current in
            current = prompts
            return true
        }
    }

    /// Waits until all previously requested writes have finished.
    /// Used by deterministic persistence tests.
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    func exportPrompts(to url: URL) throws {
        try requireAvailable()
        let exports = prompts.map { PromptExport(title: $0.title, content: $0.content) }
        let data = try JSONEncoder().encode(exports)
        try data.write(to: url, options: .atomicWrite)
    }

    func loadExternalPrompts(from url: URL) throws -> [PromptExport] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PromptExport].self, from: data)
    }

    /// Merges imported prompts into the supplied current library, preserving import behavior.
    func mergeExternalPrompts(
        current: [StoredPrompt],
        external: [PromptExport]
    ) -> (merged: [StoredPrompt], addedCount: Int) {
        var merged = current
        var addedCount = 0

        for item in external {
            let duplicateExists = merged.contains(where: {
                $0.title == item.title && $0.content == item.content
            })

            if !duplicateExists {
                merged.append(StoredPrompt(id: UUID(), title: item.title, content: item.content))
                addedCount += 1
            }
        }
        return (merged, addedCount)
    }

    func requireAvailable() throws {
        switch loadState {
        case .loaded:
            return
        case .notLoaded:
            throw SavedPromptLibraryError.notLoaded
        case let .failed(error):
            throw SavedPromptLibraryError.loadFailed(underlying: error)
        }
    }

    private static func defaultFileURL() -> URL {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return supportDir
            .appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
            .appendingPathComponent("SavedPrompts.json")
    }

    private func loadPromptsFromDisk() -> Result<[StoredPrompt], Error> {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return failedLoad(error)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try .success(JSONDecoder().decode([StoredPrompt].self, from: data))
        } catch {
            if Self.isNoSuchFileError(error) {
                return .success([])
            }
            return failedLoad(error)
        }
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileNoSuchFileError
            || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }

    private func failedLoad(_ error: Error) -> Result<[StoredPrompt], Error> {
        print("⚠️ ERROR: Failed to load prompts from \(fileURL.path): \(error)")
        print("⚠️ This could indicate file corruption or permissions issues.")
        print("⚠️ User prompts will NOT be overwritten to prevent data loss.")
        return .failure(error)
    }

    private func persist(_ prompts: [StoredPrompt]) {
        persistenceObserver?(prompts)

        let fileURL = fileURL
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(prompts)
                try data.write(to: fileURL, options: .atomicWrite)
            } catch {
                print("Failed to write prompts: \(error)")
            }
        }
    }
}
