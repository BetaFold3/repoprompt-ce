import Foundation
import SwiftUI

/// Determines how CodeMap definitions are inserted.
enum CodeMapUsage: String, CaseIterable, Codable {
    case auto
    case complete
    /// Include code-map for selected files only (handled at injection sites;
    /// returning it here would duplicate).
    case selected
    case none
}

/// Standalone helper for file-tree generation and selection presentation.
enum CodeMapExtractor {
    struct RootInfo: Hashable {
        let standardizedRootFullPath: String
        let displayName: String
    }

    // New markers and legends
    static let selectedMark = " *"
    static let codeMapMark = " +"
    static let selectedLegend = "(* denotes selected files)"
    static let codeMapLegend = "(+ denotes code-map available)"

    /// Single-buffer string builder with incremental token estimate
    struct StringBuilder {
        private(set) var estimatedTokens: Int = 0
        private var s: String = ""
        init(reserve: Int = 0) {
            if reserve > 0 { s.reserveCapacity(reserve) }
        }

        @inline(__always) mutating func appendLine(_ line: String) {
            s.append(line)
            s.append("\n")
            // Same heuristic as estimateTokens(for:)
            estimatedTokens &+= Int((Double(line.count + 1) * 1.05) / 4.0)
        }

        var result: String {
            s
        }

        var isEmpty: Bool {
            s.isEmpty
        }
    }

    // MARK: - Subset tree helpers (NEW)

    private struct SubsetNode {
        var folders: [String: SubsetNode] = [:]
        var files: [String: String] = [:] // name -> standardized full path
    }

    /// Builds a file tree limited to a subset of files identified by absolute full paths,
    /// without traversing the FolderViewModel graph.
    static func generateFileTreeForSubsetPaths(
        roots: [RootInfo],
        subsetFullPaths: Set<String>,
        filePathDisplay: FilePathDisplay,
        selectedMarkAll: Bool = true,
        codeMapAvailableFullPaths: Set<String> = [],
        includeLegend: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard !subsetFullPaths.isEmpty, !roots.isEmpty else { return "" }
        if Task.isCancelled { return "" }

        let matchingRoots = roots.sorted { $0.standardizedRootFullPath.count > $1.standardizedRootFullPath.count }
        var rootNodes: [String: SubsetNode] = [:]
        rootNodes.reserveCapacity(roots.count)

        func insertPathComponents(_ comps: [String], fullPath: String, into node: inout SubsetNode) {
            guard let head = comps.first else { return }
            if comps.count == 1 {
                node.files[head] = fullPath
                return
            }
            var child = node.folders[head] ?? SubsetNode()
            insertPathComponents(Array(comps.dropFirst()), fullPath: fullPath, into: &child)
            node.folders[head] = child
        }

        for rawPath in subsetFullPaths {
            if Task.isCancelled { break }
            let stdPath = StandardizedPath.absolute(rawPath)
            guard let root = matchingRoots.first(where: {
                stdPath == $0.standardizedRootFullPath || stdPath.hasPrefix($0.standardizedRootFullPath + "/")
            }) else { continue }

            let rootFull = root.standardizedRootFullPath
            if stdPath == rootFull { continue }
            let needsSlash = stdPath.hasPrefix(rootFull + "/")
            let startIdx = stdPath.index(stdPath.startIndex, offsetBy: rootFull.count + (needsSlash ? 1 : 0))
            let rel = String(stdPath[startIdx...])
            let comps = rel.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }

            var node = rootNodes[rootFull] ?? SubsetNode()
            insertPathComponents(comps, fullPath: stdPath, into: &node)
            rootNodes[rootFull] = node
        }

        guard !rootNodes.isEmpty else { return "" }

        let standardizedCodeMapPaths = showCodeMapMarkers
            ? Set(codeMapAvailableFullPaths.map(StandardizedPath.absolute))
            : []
        var sb = StringBuilder(reserve: 8192)
        var usedSelected = false
        var usedCodeMap = false

        func emitNode(
            _ node: SubsetNode,
            basePrefix: String
        ) {
            if Task.isCancelled { return }
            let folderNames = node.folders.keys.sorted()
            let fileNames = node.files.keys.sorted()
            let totalCount = folderNames.count + fileNames.count
            var current = 0

            for name in folderNames {
                current += 1
                let isLast = current == totalCount
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(name)")
                let nextPrefix = basePrefix + (isLast ? "    " : "│   ")
                emitNode(node.folders[name] ?? SubsetNode(), basePrefix: nextPrefix)
            }

            for name in fileNames {
                current += 1
                let isLast = current == totalCount
                let fullPath = node.files[name] ?? ""
                let marked = selectedMarkAll
                let hasMap = showCodeMapMarkers && !fullPath.isEmpty && standardizedCodeMapPaths.contains(fullPath)
                if marked { usedSelected = true }
                if hasMap { usedCodeMap = true }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
            }
        }

        let rootsWithContent = roots.filter { rootNodes[$0.standardizedRootFullPath] != nil }
        for (idx, root) in rootsWithContent.enumerated() {
            if Task.isCancelled { break }
            let rootLabel: String = if filePathDisplay == .full {
                root.standardizedRootFullPath
            } else {
                if !root.displayName.isEmpty {
                    root.displayName
                } else {
                    (root.standardizedRootFullPath as NSString).lastPathComponent
                }
            }
            sb.appendLine(rootLabel)
            if let node = rootNodes[root.standardizedRootFullPath] {
                emitNode(node, basePrefix: "")
            }
            if idx < rootsWithContent.count - 1 {
                sb.appendLine("")
            }
        }

        var text = sb.result
        if includeLegend, usedSelected || usedCodeMap {
            var legends: [String] = []
            if usedSelected { legends.append(selectedLegend) }
            if usedCodeMap { legends.append(codeMapLegend) }
            text += "\n\n" + legends.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Token estimator

    static func estimateTokens(for text: String) -> Int {
        Int(Double(text.count) * 1.05 / 4.0)
    }
}
