import Foundation
import RepoPromptWorkspace

class DiffParser {
    private let fileManager: WorkspaceFilesViewModel

    #if DEBUG
        /// Debug configuration for testing - only available in DEBUG builds
        struct DebugConfig {
            var treatNonExistentFilesAsExisting: Bool = false
            var alwaysPreserveRewriteAction: Bool = false
        }

        private let debugConfig: DebugConfig?
    #endif

    private func dbg(_ msg: @autoclosure () -> String) {
        dprint(msg())
    }

    #if DEBUG
        init(fileManager: WorkspaceFilesViewModel, debugConfig: DebugConfig? = nil) {
            self.fileManager = fileManager
            self.debugConfig = debugConfig
        }
    #else
        init(fileManager: WorkspaceFilesViewModel) {
            self.fileManager = fileManager
        }
    #endif

    /// Merges two actions for the same file into a single effective action
    /// following these rules:
    ///   delete + create  -> rewrite
    ///   create + delete  -> rewrite
    ///   any + rewrite    -> rewrite
    ///   create + modify  -> create (can't modify a file that doesn't exist yet)
    ///   otherwise        -> keeps the newestAction
    private func mergedAction(_ previous: FileAction, _ newest: FileAction) -> FileAction {
        if (previous == .delete && newest == .create) ||
            (previous == .create && newest == .delete) { return .rewrite }
        if previous == .rewrite || newest == .rewrite { return .rewrite }
        // Special case: create + modify should stay as create
        // (you can't modify a file that will be created)
        if previous == .create, newest == .modify { return .create }
        return newest // fallback: latest wins
    }

    /// Converts a raw diff-XML string into an array of `ParsedFile`.
    /// The heavy lifting is delegated to small helpers so the core loop
    /// is straightforward and easy to unit-test.
    func parse(_ rawInput: String) async throws -> [ParsedFile] {
        var parsedFileMap: [String: ParsedFile] = [:]
        var errors: [ParserError] = []

        // 1️⃣  Pre-processing that strips <think>, CDATA, smart quotes, etc.
        let thinkFree = DiffParserUtils.removeThinkTag(from: rawInput)
        let stripped = DiffParserUtils
            .stripCDATA(thinkFree)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        let input = stripped.decodingHTMLEntities()

        let fileEntries = DiffParserUtils.extractFileEntries(from: input)
        dbg("🔍  Found \(fileEntries.count) <file> entrie(s)")

        for (filePathRaw, actionRaw, fileBody) in fileEntries {
            dbg("🚩  Parsing <file> path='\(filePathRaw)' action='\(actionRaw)'")

            // ---- Normalise path / action --------------------------------------
            let filePath = DiffParserUtils.decodeAndEscapeString(filePathRaw)
            let actionString = DiffParserUtils.decodeAndEscapeString(actionRaw)

            // ---- Handle <file action="rename"> up front -----------------------
            if actionString.lowercased() == "rename" {
                await handleRename(
                    oldPath: filePath,
                    fileBody: fileBody,
                    parsedFileMap: &parsedFileMap,
                    errors: &errors
                )
                continue
            }

            // ---- Validate action string ---------------------------------------
            guard let originalAction = FileAction(rawValue: actionString) else {
                errors.append(.invalidFileAction(filePath: filePath, action: actionString))
                continue
            }

            // ---- Resolve via FileSystemService (if any) -----------------------
            var canonicalPath = filePath // default = as-is
            var canBeLoaded = false
            var loadedFile = fileBody // default = diff payload
            let isCreate = originalAction == .create
            let isDelete = originalAction == .delete

            // Extract file-level <content> lazily; only when needed (create/rewrite)
            // Extract file-level <content> lazily; only when needed (create/rewrite)
            let resolveMainContent: () -> String = {
                if let s = DiffParserUtils.extractContent(from: fileBody, tag: "content", flexible: false) {
                    // extractContent already post-processes
                    return s
                }
                if let s = DiffParserUtils.extractLenientContent(from: fileBody, tag: "content") {
                    // extractLenientContent already post-processes
                    return s
                }
                return ""
            }

            if let location = await fileManager.pathLocation(filePath, exactMatchOnly: isCreate || isDelete) {
                // Fetch the would-be *absolute* path for the service's correction
                let candidateCanonical = URL(fileURLWithPath: location.rootPath)
                    .appendingPathComponent(location.correctedPath)
                    .path

                // -----------------------------------------------------------------
                // SAME-COMPONENT test for CREATE actions
                // • If the user supplied a *relative* path, compare it with the
                //   service’s *relative* correction (`svc.correctedPath`).
                // • If the user supplied an *absolute* path, compare it with the
                //   *absolute* canonical path returned by the service.
                // -----------------------------------------------------------------
                var useCandidate = true
                if isCreate {
                    let origCount = filePath
                        .split(separator: "/")
                        .count(where: { !$0.isEmpty })

                    let candCount: Int = if filePath.hasPrefix("/") { // absolute input
                        candidateCanonical
                            .split(separator: "/")
                            .count(where: { !$0.isEmpty })

                    } else { // relative input
                        location.correctedPath
                            .split(separator: "/")
                            .count(where: { !$0.isEmpty })
                    }

                    useCandidate = (origCount == candCount)
                }

                if useCandidate {
                    canonicalPath = candidateCanonical

                    // Get latest content from FileViewModel
                    if let file = await fileManager.findFile(
                        atPath: location.correctedPath,
                        rootIdentifier: location.rootIdentifier
                    ) {
                        canBeLoaded = true
                        // latestContent is an async getter
                        loadedFile = await file.latestContent ?? ""
                    } else if let baselineContent = await fileManager.getBaselineContent(
                        forPath: location.correctedPath,
                        rootIdentifier: location.rootIdentifier
                    ) {
                        // Use baseline content if available (e.g., in benchmark mode)
                        canBeLoaded = true
                        loadedFile = baselineContent
                    } else {
                        // File doesn't exist in hierarchy yet
                        canBeLoaded = false
                    }
                }
            }

            // ---- Convert create → rewrite if we discover an existing file -----
            var effectiveAction = originalAction
            if isCreate, canBeLoaded {
                effectiveAction = .rewrite
            }
            if !canBeLoaded, effectiveAction == .create {
                // "create" file truly doesn't exist yet, treat diff body as new
                canBeLoaded = true
            }

            // ---- Handle modify on non-existent file (error but continue) -----
            if originalAction == .modify, !canBeLoaded {
                errors.append(.fileNotFoundForModify(filePath: canonicalPath))
                #if DEBUG
                    // In debug mode, we can treat non-existent files as existing for testing
                    if debugConfig?.treatNonExistentFilesAsExisting == true {
                        canBeLoaded = true
                    }
                #endif
            }

            // ---- Convert rewrite → add if file doesn't exist -----
            if originalAction == .rewrite, !canBeLoaded {
                #if DEBUG
                    // In debug mode with alwaysPreserveRewriteAction, keep it as rewrite
                    if debugConfig?.alwaysPreserveRewriteAction == true {
                        effectiveAction = .rewrite
                    } else {
                        effectiveAction = .create
                    }
                #else
                    effectiveAction = .create
                #endif
                canBeLoaded = true // Treat as new file
            }

            // ---- Guard against multiple rewrite actions for the same file ----
            if effectiveAction == .rewrite,
               let existingRewrite = parsedFileMap[canonicalPath],
               existingRewrite.action == .rewrite
            {
                dbg("⚠️  Skipping additional rewrite for '\(canonicalPath)' – only the first rewrite per file is processed")
                continue
            }

            // ---- Detect indentation style & line ending -----------------------
            let (lines, detectedLE) = String.splitContentPreservingLineEndings(loadedFile)
            let (indentType, _) = String.detectIndentationTypeFromLines(lines)
            let usesSpaces = indentType == "s"

            // ---- Parse <change> blocks (or fallback) --------------------------
            let changes = DiffParserUtils.parseChanges(
                fileBody,
                filePath: canonicalPath,
                fileAction: effectiveAction,
                lineEnding: detectedLE,
                fileExists: canBeLoaded,
                usesSpaces: usesSpaces,
                originalFileContent: loadedFile // ← NEW
            )

            /// Join content lines from parsed changes for non-create/rewrite files
            func contentFromChanges(_ ch: [Change]) -> String {
                ch.compactMap { $0.content?.joined(separator: "\n") }.joined(separator: "\n")
            }

            // ---- Aggregate results -------------------------------------------
            if let existing = parsedFileMap[canonicalPath] {
                // ❶ Combine change arrays
                var combinedChanges = existing.changes + changes

                // ❷ If we are about to turn this into a rewrite, strip any full-file
                //    "remove" change that originated from the preliminary *delete*.
                let combinedAction = mergedAction(existing.action, effectiveAction)
                if combinedAction == .rewrite {
                    combinedChanges.removeAll(where: { $0.type == .remove })
                    // Optionally: convert remaining `.add` changes to `.modify`
                    combinedChanges = combinedChanges.map { change in
                        guard change.type == .add else { return change }
                        var c = change
                        c.type = .modify
                        return c
                    }
                }

                // ❸ Re-build ParsedFile because `action` is a `let`
                // For create actions, always use the new content to ensure we have the latest content
                let updatedFileContent: String
                if combinedAction == .create || combinedAction == .rewrite {
                    updatedFileContent = resolveMainContent()
                } else {
                    // Keep existing content if present; otherwise derive from combined changes
                    let derived = contentFromChanges(combinedChanges)
                    updatedFileContent = existing.fileContent.isEmpty ? derived : existing.fileContent
                }

                let updated = ParsedFile(
                    fileName: existing.fileName,
                    changes: combinedChanges,
                    fileContent: updatedFileContent,
                    canBeLoaded: existing.canBeLoaded || canBeLoaded,
                    action: combinedAction,
                    lineEnding: existing.lineEnding.isEmpty ? detectedLE : existing.lineEnding
                )
                parsedFileMap[canonicalPath] = updated
            } else {
                let initialFileContent: String = if effectiveAction == .create || effectiveAction == .rewrite {
                    resolveMainContent()
                } else {
                    contentFromChanges(changes)
                }

                parsedFileMap[canonicalPath] = ParsedFile(
                    fileName: canonicalPath,
                    changes: changes,
                    fileContent: initialFileContent,
                    canBeLoaded: canBeLoaded,
                    action: effectiveAction,
                    lineEnding: detectedLE
                )
            }

            if changes.isEmpty, effectiveAction != .delete {
                errors.append(.noChangesInFile(filePath: canonicalPath))
            }
        }

        // Return even if `errors` not empty – caller can inspect them.
        return Array(parsedFileMap.values)
    }

    ///  MARK: ––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
    /// Special-case handler that converts a `<file action="rename">`
    /// block into a *delete* (old path) + *create* (new path) pair.
    private func handleRename(
        oldPath: String,
        fileBody: String,
        parsedFileMap: inout [String: ParsedFile],
        errors: inout [ParserError]
    ) async {
        dbg("🔀  RENAME detected  '\(oldPath)'  →  (new path parsed below)")

        // 1. Extract the `<new path="…">`
        let newRegex = try! NSRegularExpression(
            pattern: "<new\\s+path\\s*=\\s*[\"“”]([^\"“”]+)[\"“”]\\s*/?>",
            options: [.caseInsensitive]
        )

        guard
            let m = newRegex.firstMatch(
                in: fileBody,
                options: [],
                range: NSRange(location: 0, length: fileBody.utf16.count)
            ),
            let newRange = Range(m.range(at: 1), in: fileBody)
        else {
            errors.append(.missingTag(tag: "new"))
            return
        }

        let newPathRaw = DiffParserUtils.decodeAndEscapeString(String(fileBody[newRange]))
        let newPath = newPathRaw

        // -----------------------------------------------------------------
        // Load the old file's content (best-effort – not fatal if missing)
        var loadedOld = ""
        var canonicalOld = oldPath
        var lineEnding = "\n"
        var usesSpaces = true

        if let locationOld = await fileManager.pathLocation(oldPath, exactMatchOnly: true) {
            canonicalOld = URL(fileURLWithPath: locationOld.rootPath)
                .appendingPathComponent(locationOld.correctedPath)
                .path

            // Use FileViewModel to load old file content
            if let file = await fileManager.findFile(
                atPath: locationOld.correctedPath,
                rootIdentifier: locationOld.rootIdentifier
            ) {
                if let data = await file.latestContent {
                    loadedOld = data
                }
            } else if let baselineContent = await fileManager.getBaselineContent(
                forPath: locationOld.correctedPath,
                rootIdentifier: locationOld.rootIdentifier
            ) {
                // Use baseline content if available (e.g., in benchmark mode)
                loadedOld = baselineContent
            }
        }

        let (lns, le) = String.splitContentPreservingLineEndings(loadedOld)
        lineEnding = le
        let (indent, _) = String.detectIndentationTypeFromLines(lns)
        usesSpaces = indent == "s"
        let encodedLines = DiffParserUtils.splitContentToLines(loadedOld, usesSpaces)

        // -----------------------------------------------------------------
        // 2. Build the *delete* entry — now with an explicit Change block
        //    that flags every original line for removal.
        let deleteChange = Change(
            id: UUID(),
            type: .remove,
            summary: "Rename from \(oldPath) to \(newPath)",
            isSelected: true,
            content: encodedLines, // every old line becomes a “-” diff line
            startSelector: nil,
            endSelector: nil,
            searchBlock: nil
        )

        let deleteFile = ParsedFile(
            fileName: canonicalOld,
            changes: [deleteChange], // <-- previously “[]”
            fileContent: loadedOld,
            canBeLoaded: !loadedOld.isEmpty,
            action: .delete,
            lineEnding: lineEnding
        )
        parsedFileMap[canonicalOld] = deleteFile

        // -----------------------------------------------------------------
        // 3. Build the *create* entry  (single "add everything" change)
        let createChange = Change(
            id: UUID(),
            type: .add,
            summary: "Rename from \(oldPath) to \(newPath)",
            isSelected: true,
            content: encodedLines,
            startSelector: nil,
            endSelector: nil,
            searchBlock: nil
        )

        // Resolve a canonical path if the destination folder already exists
        let createFile = ParsedFile(
            fileName: newPath,
            changes: [createChange],
            fileContent: loadedOld,
            canBeLoaded: false, // new file does not exist yet
            action: .create,
            lineEnding: lineEnding
        )
        parsedFileMap[newPath] = createFile
    }
}
