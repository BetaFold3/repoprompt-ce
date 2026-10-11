import Foundation
import RepoPromptWorkspace

struct BenchmarkAuditIssue {
    enum Severity: String { case info, warning, error }
    let severity: Severity
    let code: String
    let message: String
    let path: String?
    let metrics: [String: BenchmarkJSONValue]
}

struct BenchmarkSearchHint {
    let path: String
    let search: [String]
    let replacement: [String]
    let reason: String
}

struct BenchmarkAuditResult {
    let spec: BenchmarkTaskSpec
    let issues: [BenchmarkAuditIssue]
    let hints: [BenchmarkSearchHint]
    let solvable: Bool
}

struct BenchmarkAuditor {
    func auditSeed(_ generated: BenchmarkGeneratedSeed) async -> [BenchmarkAuditResult] {
        await withTaskGroup(of: BenchmarkAuditResult.self) { group in
            let snapshot = generated.fileSystem.snapshot()
            for task in generated.tasks {
                group.addTask {
                    await auditTask(task, on: snapshot)
                }
            }
            var results: [BenchmarkAuditResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    func auditTask(_ spec: BenchmarkTaskSpec, on fs: BenchmarkMockFileSystemSnapshot) async -> BenchmarkAuditResult {
        var issues: [BenchmarkAuditIssue] = []
        var hints: [BenchmarkSearchHint] = []
        var simulatedPass = false
        let missing = spec.selectFiles.filter { fs.content(for: $0) == nil }
        if !missing.isEmpty {
            issues.append(.err(code: "missingFile", msg: "Selected file(s) not present in baseline: \(missing.joined(separator: ", "))", path: nil))
            return BenchmarkAuditResult(spec: spec, issues: issues, hints: [], solvable: false)
        }
        switch spec.type {
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            let outcome = await auditInsertGuard(spec, fs: fs)
            issues.append(contentsOf: outcome.issues)
            hints.append(contentsOf: outcome.hints)
            simulatedPass = outcome.simulatedPass
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            let outcome = await auditPatchBlock(spec, fs: fs)
            issues.append(contentsOf: outcome.issues)
            hints.append(contentsOf: outcome.hints)
            simulatedPass = outcome.simulatedPass
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            if spec.params["markerless"]?.boolValue == true {
                let outcome = await auditSwapArgsMarkerless(spec, fs: fs)
                issues.append(contentsOf: outcome.issues)
                hints.append(contentsOf: outcome.hints)
                simulatedPass = outcome.simulatedPass
            } else {
                let outcome = await auditGeneric(spec, fs: fs)
                issues.append(contentsOf: outcome.issues)
                hints.append(contentsOf: outcome.hints)
                simulatedPass = outcome.simulatedPass
            }
        case .removeXTs, .removeXGo, .removeXSwift,
             .curlyFixTs, .curlyFixGo, .curlyFixSwift,
             .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift,
             .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift,
             .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift,
             .insertFunctionBottomTs, .insertFunctionBottomGo, .insertFunctionBottomSwift,
             .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            let outcome = await auditGeneric(spec, fs: fs)
            issues.append(contentsOf: outcome.issues)
            hints.append(contentsOf: outcome.hints)
            simulatedPass = outcome.simulatedPass
        }
        if spec.type == .removeXTs,
           let path = spec.params["file"]?.stringValue,
           let text = fs.content(for: path),
           let target = spec.params["target"]?.stringValue
        {
            let count = max(0, text.components(separatedBy: target).count - 1)
            if count > spec.maxEdits {
                issues.append(.warn(
                    code: "maxEditsLikelyInsufficient",
                    msg: "Will likely need \(count) edits but maxEdits=\(spec.maxEdits).",
                    path: path,
                    metrics: ["needed": .integer(count)]
                ))
            }
        }
        return BenchmarkAuditResult(spec: spec, issues: issues, hints: hints, solvable: simulatedPass)
    }

    private func auditInsertGuardMarkerless(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        var issues: [BenchmarkAuditIssue] = []
        var hints: [BenchmarkSearchHint] = []

        guard
            let functionName = spec.params["functionName"]?.stringValue,
            let insertAfterPattern = spec.params["insertAfterPattern"]?.stringValue,
            let snippet = spec.params["snippet"]?.stringValue,
            let path = spec.selectFiles.first,
            let text = fs.content(for: path)
        else {
            return ([.err(code: "missingParams", msg: "functionName/insertAfterPattern/snippet/or file missing", path: nil)], [], false)
        }

        // Use DecoyPlanner's core location logic to find the insertion region
        guard let core = DecoyPlanner.locateCore(for: spec, in: text, path: path) else {
            issues.append(.err(
                code: "functionOrPatternNotFound",
                msg: "Could not locate function '\(functionName)' or pattern '\(insertAfterPattern)' in \(path)",
                path: path
            ))
            return (issues, hints, false)
        }

        // Build search block: should include function signature, pattern line, and at least one more line
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        // Find function signature line (should be before core)
        var sigLine: String?
        for i in stride(from: max(0, core.startLine - 1), through: 0, by: -1) {
            let line = lines[i]
            if line.contains("function \(functionName)(") || line.contains("func \(functionName)(") {
                sigLine = line
                break
            }
        }

        // Build recommended search block: sig + core lines (5-8 total recommended)
        var searchLines: [String] = []
        if let sig = sigLine {
            searchLines.append(sig)
        }
        searchLines.append(contentsOf: core.lines)

        // Count pattern occurrences to detect ambiguity
        let patternOccurrencesInFile = text.components(separatedBy: insertAfterPattern).count - 1

        // Count occurrences in the function body (approximate: core region +/- 10 lines)
        let funcStart = max(0, core.startLine - 10)
        let funcEnd = min(lines.count - 1, core.endLine + 10)
        let funcBody = lines[funcStart ... funcEnd].joined(separator: "\n")
        let patternOccurrencesInFunction = funcBody.components(separatedBy: insertAfterPattern).count - 1

        // Check if search is too short (< 5 lines = likely ambiguous with complex code)
        if searchLines.count < 5 {
            issues.append(.warn(
                code: "searchBlockTooShort",
                msg: "Recommended search block has only \(searchLines.count) lines; strong ambiguity risk. Include signature + multiple body lines (5-8 lines).",
                path: path,
                metrics: [
                    "searchLineCount": .integer(searchLines.count),
                    "patternOccurrencesInFile": .integer(patternOccurrencesInFile),
                    "patternOccurrencesInFunction": .integer(patternOccurrencesInFunction)
                ]
            ))
        }

        // Warn if pattern appears multiple times within the function
        if patternOccurrencesInFunction >= 2 {
            issues.append(.warn(
                code: "multiplePatternMatches",
                msg: "Pattern '\(insertAfterPattern)' appears \(patternOccurrencesInFunction) times within target function; short search blocks likely ambiguous.",
                path: path,
                metrics: [
                    "patternOccurrencesInFunction": .integer(patternOccurrencesInFunction),
                    "patternOccurrencesInFile": .integer(patternOccurrencesInFile)
                ]
            ))
        }

        // Check indentation
        let (_, lineEnding) = detectIndentInfo(in: text)
        let usesTabIndentation = spec.language.usesTabIndentation

        if usesTabIndentation, snippet.contains("    ") {
            issues.append(.warn(
                code: "indentationMismatch",
                msg: "Swift requires tabs, but snippet contains 4 spaces.",
                path: path
            ))
        } else if !usesTabIndentation, snippet.contains("\t") {
            issues.append(.err(
                code: "snippetHasTabs",
                msg: "TS/Go requires 4 spaces, but snippet contains tabs.",
                path: path
            ))
        }

        // Build replacement: insert snippet after pattern line
        let patternLineIdx = core.lines.firstIndex(where: { $0.contains(insertAfterPattern) }) ?? 0
        var replacementLines = core.lines
        replacementLines.insert(snippet, at: patternLineIdx + 1)

        // Create hint
        hints.append(BenchmarkSearchHint(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            reason: "Insert snippet after '\(insertAfterPattern)' line inside \(functionName)() function. Include signature and 5-8 body lines in search to avoid ambiguity."
        ))

        // Simulate
        let simulated = await simulateOneModify(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            fs: fs,
            lineEnding: lineEnding,
            caseType: spec.type
        )
        issues.append(contentsOf: simulated.issues)

        return (issues, hints, simulated.pass)
    }

    private func auditPatchBlockMarkerless(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        guard let path = spec.selectFiles.first,
              let text = fs.content(for: path),
              let functionName = spec.params["functionName"]?.stringValue,
              let snippet = spec.params["snippet"]?.stringValue
        else {
            return ([.err(code: "missingParams", msg: "Missing params", path: nil)], [], false)
        }

        // Use DecoyPlanner to locate the function
        let coreRegion = DecoyPlanner.locateCore(for: spec, in: text, path: path)
        guard let core = coreRegion else {
            return ([.err(code: "functionNotFound", msg: "Function '\(functionName)' not found", path: path)], [], false)
        }

        var issues: [BenchmarkAuditIssue] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Build recommended search block: signature + body line + closing brace
        let sigLine = core.startLine - 1
        let searchLines = Array(lines[max(0, sigLine) ... min(lines.count - 1, core.endLine + 1)])

        if searchLines.count < 3 {
            issues.append(.warn(code: "shortSearch", msg: "Search block < 3 lines may be ambiguous", path: path))
        }

        let (_, lineEnding) = detectIndentInfo(in: text)

        // Simulate the edit
        let hint = BenchmarkSearchHint(
            path: path,
            search: searchLines,
            replacement: [snippet],
            reason: "Replace function '\(functionName)' body with snippet"
        )

        let (simIssues, simPass) = await simulateOneModify(
            path: path,
            search: searchLines,
            replacement: [snippet],
            fs: fs,
            lineEnding: lineEnding,
            caseType: spec.type
        )
        issues.append(contentsOf: simIssues)

        return (issues, [hint], simPass)
    }

    private func auditSwapArgsMarkerless(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        guard let path = spec.selectFiles.first,
              let text = fs.content(for: path),
              let functionName = spec.params["functionName"]?.stringValue
        else {
            return ([.err(code: "missingParams", msg: "Missing params", path: nil)], [], false)
        }

        // Use DecoyPlanner to locate the core region containing use() calls
        let coreRegion = DecoyPlanner.locateCore(for: spec, in: text, path: path)
        guard let core = coreRegion else {
            return ([.err(code: "regionNotFound", msg: "Function '\(functionName)' or use() calls not found", path: path)], [], false)
        }

        var issues: [BenchmarkAuditIssue] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Build search: include line before first use() + all use() lines + line after
        let beforeLine = core.startLine - 1 >= 0 ? core.startLine - 1 : core.startLine
        let afterLine = core.endLine + 1 < lines.count ? core.endLine + 1 : core.endLine
        let searchLines = Array(lines[beforeLine ... afterLine])

        if searchLines.count < 3 {
            issues.append(.warn(code: "shortSearch", msg: "Search block < 3 lines may be ambiguous", path: path))
        }

        // Build replacement: swap use(a,b) to use(b,a)
        var replacementLines = searchLines
        for i in 0 ..< replacementLines.count {
            replacementLines[i] = swapUseCallsInLine(replacementLines[i])
        }

        let (_, lineEnding) = detectIndentInfo(in: text)

        let hint = BenchmarkSearchHint(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            reason: "Swap use(a,b) to use(b,a) in function '\(functionName)'"
        )

        let (simIssues, simPass) = await simulateOneModify(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            fs: fs,
            lineEnding: lineEnding,
            caseType: spec.type
        )
        issues.append(contentsOf: simIssues)

        return (issues, [hint], simPass)
    }

    private func swapUseCallsInLine(_ line: String) -> String {
        // Simple regex to swap use(a, b) -> use(b, a)
        var result = line
        let pattern = "use\\(([^,]+),\\s*([^)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if match.numberOfRanges == 3 {
                    let arg1 = nsString.substring(with: match.range(at: 1))
                    let arg2 = nsString.substring(with: match.range(at: 2))
                    let replacement = "use(\(arg2), \(arg1))"
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }
        return result
    }

    private func auditInsertGuard(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        // Check for markerless mode
        if spec.params["markerless"]?.boolValue == true {
            return await auditInsertGuardMarkerless(spec, fs: fs)
        }

        var issues: [BenchmarkAuditIssue] = []
        var hints: [BenchmarkSearchHint] = []
        guard
            let uid = spec.params["uid"]?.stringValue,
            let snippet = spec.params["snippet"]?.stringValue,
            let path = spec.selectFiles.first,
            let text = fs.content(for: path)
        else {
            return ([.err(code: "missingParams", msg: "uid/snippet/or file missing", path: nil)], [], false)
        }
        let startAnchor = "// ANCHOR:start:\(uid)"
        let endAnchor = "// ANCHOR:end:\(uid)"
        let startRanges = text.ranges(of: startAnchor)
        let endRanges = text.ranges(of: endAnchor)
        if startRanges.count != 1 || endRanges.count != 1 {
            issues.append(.err(
                code: "anchorMultiplicity",
                msg: "Expected exactly one start/end anchor for uid \(uid) but found start=\(startRanges.count) end=\(endRanges.count)",
                path: path
            ))
            return (issues, hints, false)
        }
        guard let start = startRanges.first,
              let end = text.range(of: endAnchor, range: start.upperBound ..< text.endIndex)
        else {
            issues.append(.err(code: "anchorOrder", msg: "End anchor not found after start anchor", path: path))
            return (issues, hints, false)
        }
        let interior = text[start.upperBound ..< end.lowerBound]
        if interior.contains("\t") {
            issues.append(.warn(
                code: "indentationRisk",
                msg: "Anchor region currently uses TAB indentation; verifier requires 4-space snippet equality.",
                path: path
            ))
        }
        if snippet.contains("\t") {
            issues.append(.err(code: "snippetHasTabs", msg: "Snippet contains tabs but spec requires 4 spaces only.", path: path))
        }
        let (usesSpaces, lineEnding) = detectIndentInfo(in: text)
        let searchLines = DiffParserUtils.splitContentToLines(String(interior), usesSpaces)
        let replacementLines = DiffParserUtils.splitContentToLines(snippet, usesSpaces)
        if let ambiguity = findAmbiguity(in: text, searchEncoded: searchLines, usesSpaces: usesSpaces) {
            issues.append(ambiguity)
        }
        hints.append(BenchmarkSearchHint(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            reason: "Exact match of inner anchor region (excluding anchor lines)."
        ))
        let simulated = await simulateOneModify(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            fs: fs,
            lineEnding: lineEnding,
            caseType: spec.type
        )
        issues.append(contentsOf: simulated.issues)
        return (issues, hints, simulated.pass)
    }

    private func auditPatchBlock(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        // Check for markerless mode
        if spec.params["markerless"]?.boolValue == true {
            return await auditPatchBlockMarkerless(spec, fs: fs)
        }

        var issues: [BenchmarkAuditIssue] = []
        var hints: [BenchmarkSearchHint] = []
        guard
            let uid = spec.params["uid"]?.stringValue,
            let snippet = spec.params["snippet"]?.stringValue,
            let path = spec.selectFiles.first,
            let text = fs.content(for: path)
        else {
            return ([.err(code: "missingParams", msg: "uid/snippet/or file missing", path: nil)], [], false)
        }
        let startToken = "/* BLOCK START:\(uid) */"
        let endToken = "/* BLOCK END:\(uid) */"
        let startRanges = text.ranges(of: startToken)
        let endRanges = text.ranges(of: endToken)
        if startRanges.count != 1 || endRanges.count != 1 {
            issues.append(.err(
                code: "blockMultiplicity",
                msg: "Expected exactly one block for uid \(uid) but found start=\(startRanges.count) end=\(endRanges.count)",
                path: path
            ))
            return (issues, hints, false)
        }
        guard let start = startRanges.first,
              let end = text.range(of: endToken, range: start.upperBound ..< text.endIndex)
        else {
            issues.append(.err(code: "blockOrder", msg: "END block not found after START", path: path))
            return (issues, hints, false)
        }
        let body = text[start.upperBound ..< end.lowerBound]
        let (usesSpaces, lineEnding) = detectIndentInfo(in: text)
        if body.contains("\t"), snippet.contains("    ") {
            issues.append(.warn(
                code: "indentationRisk",
                msg: "Block body uses tabs but snippet uses spaces; strict equality will fail.",
                path: path
            ))
        }
        let searchLines = DiffParserUtils.splitContentToLines(String(body), usesSpaces)
        let replacementLines = DiffParserUtils.splitContentToLines(snippet, usesSpaces)
        if let ambiguity = findAmbiguity(in: text, searchEncoded: searchLines, usesSpaces: usesSpaces) {
            issues.append(ambiguity)
        }
        hints.append(BenchmarkSearchHint(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            reason: "Exact match of existing block body; replacement is the provided snippet."
        ))
        let simulated = await simulateOneModify(
            path: path,
            search: searchLines,
            replacement: replacementLines,
            fs: fs,
            lineEnding: lineEnding,
            caseType: spec.type
        )
        issues.append(contentsOf: simulated.issues)
        return (issues, hints, simulated.pass)
    }

    private func auditGeneric(_ spec: BenchmarkTaskSpec, fs: BenchmarkMockFileSystemSnapshot) async -> (issues: [BenchmarkAuditIssue], hints: [BenchmarkSearchHint], simulatedPass: Bool) {
        var issues: [BenchmarkAuditIssue] = []
        for path in spec.selectFiles where fs.content(for: path) == nil {
            issues.append(.err(code: "missingFile", msg: "File not found", path: path))
        }
        return (issues, [], true)
    }

    private func detectIndentInfo(in text: String) -> (usesSpaces: Bool, lineEnding: String) {
        let (lines, lineEnding) = String.splitContentPreservingLineEndings(text)
        let (indentType, _) = String.detectIndentationTypeFromLines(lines)
        return (indentType == "s", lineEnding)
    }

    private func findAmbiguity(in fileText: String, searchEncoded: [String], usesSpaces: Bool) -> BenchmarkAuditIssue? {
        let encodedFile = fileText
            .components(separatedBy: .newlines)
            .map { usesSpaces ? String.encodeIndentationAsSpaces($0) : String.encodeIndentationAsTabs($0) }
            .map { DiffGenerationUtility.processLine($0, precision: .high) }
        let indexMap = DiffGenerationUtility.buildLineIndexMapHigh(content: encodedFile)
        do {
            _ = try DiffGenerationUtility.matchSelectorFastWithAmbiguityCheck(
                selector: searchEncoded.map { DiffGenerationUtility.processLine($0, precision: .high) },
                content: encodedFile,
                lineIndex: indexMap
            )
            return nil
        } catch let DiffGenerationError.ambiguousMatch(message) {
            return .warn(code: "ambiguousSearch", msg: message, path: nil)
        } catch {
            return .warn(code: "searchNoMatch", msg: "Search block not found in baseline: \(error.localizedDescription)", path: nil)
        }
    }

    private func languageFromCaseType(_ caseType: BenchmarkCaseType) -> BenchmarkLanguage {
        let rawValue = caseType.rawValue
        if rawValue.hasSuffix("_go") {
            return .go
        } else if rawValue.hasSuffix("_swift") {
            return .swift
        } else {
            return .ts
        }
    }

    private func simulateOneModify(
        path: String,
        search: [String],
        replacement: [String],
        fs: BenchmarkMockFileSystemSnapshot,
        lineEnding: String,
        caseType: BenchmarkCaseType
    ) async -> (issues: [BenchmarkAuditIssue], pass: Bool) {
        var issues: [BenchmarkAuditIssue] = []
        var workingFS = BenchmarkMockFileSystem(files: fs.dictionary())
        let change = Change(
            id: UUID(),
            type: .modify,
            summary: "preflight",
            isSelected: true,
            content: replacement,
            startSelector: nil,
            endSelector: nil,
            searchBlock: search
        )
        let parsed = ParsedFile(
            fileName: path,
            changes: [change],
            fileContent: "",
            canBeLoaded: true,
            action: .modify,
            lineEnding: lineEnding
        )
        let spec = BenchmarkTaskSpec(
            id: "preflight",
            type: caseType,
            language: languageFromCaseType(caseType),
            difficulty: .medium,
            selectFiles: [path],
            maxEdits: 10,
            instructions: [],
            task: "",
            acceptance: [],
            params: [:]
        )
        let (edited, errors) = await BenchmarkDiffApplier.apply(
            parsedFiles: [parsed],
            task: spec,
            fileSystem: &workingFS,
            baseline: fs
        )
        if !errors.isEmpty {
            let message = errors.map { error in
                if let detail = error.detail {
                    return "\(error.code): \(detail)"
                }
                return error.code
            }.joined(separator: ", ")
            issues.append(.err(code: "applyFailed", msg: message, path: path))
            return (issues, false)
        }
        if edited.isEmpty {
            issues.append(.warn(code: "noChangesGenerated", msg: "Diff applier produced no changes", path: path))
            return (issues, false)
        }
        return (issues, true)
    }
}

private extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = startIndex
        while let range = range(of: substring, range: searchStart ..< endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

private extension BenchmarkAuditIssue {
    static func info(code: String, msg: String, path: String?, metrics: [String: BenchmarkJSONValue] = [:]) -> Self {
        BenchmarkAuditIssue(severity: .info, code: code, message: msg, path: path, metrics: metrics)
    }

    static func warn(code: String, msg: String, path: String?, metrics: [String: BenchmarkJSONValue] = [:]) -> Self {
        BenchmarkAuditIssue(severity: .warning, code: code, message: msg, path: path, metrics: metrics)
    }

    static func err(code: String, msg: String, path: String?, metrics: [String: BenchmarkJSONValue] = [:]) -> Self {
        BenchmarkAuditIssue(severity: .error, code: code, message: msg, path: path, metrics: metrics)
    }
}
