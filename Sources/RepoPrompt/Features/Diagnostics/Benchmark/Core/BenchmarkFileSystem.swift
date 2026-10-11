import Foundation
import RepoPromptWorkspace

/// Lightweight, in-memory representation of benchmark files.
/// Paths are stored as normalized POSIX-relative strings (no leading slash).
struct BenchmarkMockFileSystem {
    private var files: [String: String]

    init(files: [String: String] = [:]) {
        self.files = files.reduce(into: [:]) { result, pair in
            let normalized = BenchmarkMockFileSystem.normalize(pair.key)
            guard !normalized.isEmpty else { return }
            result[normalized] = pair.value
        }
    }

    var count: Int {
        files.count
    }

    var allPaths: [String] {
        Array(files.keys).sorted()
    }

    func content(for path: String) -> String? {
        files[Self.normalize(path)]
    }

    mutating func setFile(_ path: String, content: String) {
        let normalized = Self.normalize(path)
        guard !normalized.isEmpty else { return }
        files[normalized] = content
    }

    mutating func setFiles(_ newFiles: [String: String]) {
        for (path, content) in newFiles {
            setFile(path, content: content)
        }
    }

    mutating func removeFile(_ path: String) {
        files.removeValue(forKey: Self.normalize(path))
    }

    func snapshot() -> BenchmarkMockFileSystemSnapshot {
        BenchmarkMockFileSystemSnapshot(files: files)
    }

    func clone() -> BenchmarkMockFileSystem {
        BenchmarkMockFileSystem(files: files)
    }

    func filterPaths(where predicate: (String) -> Bool) -> BenchmarkMockFileSystem {
        var filtered: [String: String] = [:]
        for (path, content) in files where predicate(path) {
            filtered[path] = content
        }
        return BenchmarkMockFileSystem(files: filtered)
    }

    func mapValues(_ transform: (String) -> String) -> BenchmarkMockFileSystem {
        var mapped: [String: String] = [:]
        for (path, content) in files {
            mapped[path] = transform(content)
        }
        return BenchmarkMockFileSystem(files: mapped)
    }

    static func normalize(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withoutLeading = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        let stripped = withoutLeading.hasPrefix("/") ? String(withoutLeading.dropFirst()) : withoutLeading
        let components = stripped.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [String] = []
        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                if !stack.isEmpty {
                    stack.removeLast()
                }
            default:
                stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }
}

struct BenchmarkMockFileSystemSnapshot {
    private let files: [String: String]

    init(files: [String: String]) {
        self.files = files
    }

    var count: Int {
        files.count
    }

    var allPaths: [String] {
        Array(files.keys).sorted()
    }

    func content(for path: String) -> String? {
        files[BenchmarkMockFileSystem.normalize(path)]
    }

    func contains(_ path: String) -> Bool {
        files.keys.contains(BenchmarkMockFileSystem.normalize(path))
    }

    func dictionary() -> [String: String] {
        files
    }
}
