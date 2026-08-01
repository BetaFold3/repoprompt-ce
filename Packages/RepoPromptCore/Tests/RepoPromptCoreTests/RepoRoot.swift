import Foundation

enum RepoRoot {
    static func url(
        filePath: StaticString = #filePath,
        fileManager: FileManager = .default
    ) throws -> URL {
        var current = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .standardizedFileURL

        while true {
            let packageManifest = current.appendingPathComponent("Package.swift")
            let sourcesRoot = current.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
            var packageIsDirectory: ObjCBool = false
            var sourcesIsDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: packageManifest.path, isDirectory: &packageIsDirectory),
               !packageIsDirectory.boolValue,
               fileManager.fileExists(atPath: sourcesRoot.path, isDirectory: &sourcesIsDirectory),
               sourcesIsDirectory.boolValue
            {
                return current
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                throw RepoRootError.notFound(startingAt: "\(filePath)")
            }
            current = parent
        }
    }
}

enum RepoRootError: Error, CustomStringConvertible {
    case notFound(startingAt: String)

    var description: String {
        switch self {
        case let .notFound(startingAt):
            "Could not find repository root containing Package.swift and Sources/RepoPrompt when walking upward from \(startingAt)"
        }
    }
}
