import Foundation

enum OpenAIPricingDocumentParserError: Error, Equatable {
    case invalidEncoding
    case missingStandardTable
    case ambiguousStandardTable(count: Int)
    case ambiguousCodexTable(count: Int)
    case malformedTable(line: Int)
    case malformedRow(line: Int)
    case malformedModelCell(line: Int, cell: String)
    case malformedAmount(line: Int, cell: String)
    case conflictingModelRows(modelID: String)
}

/// Pure parser for the official OpenAI pricing Markdown document
/// (`https://developers.openai.com/api/docs/pricing.md`).
///
/// Only two qualified tables are read, selected by their tier label, `###` heading, and exact
/// header names rather than position:
///
/// 1. The flagship `Standard` → `### Standard pricing data` table with short/long context columns.
/// 2. The specialized `Standard` → `### Grouped Pricing Table data` table whose header is
///    `Category | Model | Input | Cached input | Output`; only rows whose category is `Codex` are used.
///
/// Batch, Flex, Fast, Cyber, multimodal, tool, and fine-tuning tables are never read. Prose is
/// never interpreted; aliases come from the reviewed seed list. Any malformed amount, model
/// cell, row shape, conflicting duplicate, or ambiguous table selection rejects the whole
/// document so a caller keeps its prior valid catalog.
enum OpenAIPricingDocumentParser {
    static let standardTierLabel = "Standard"
    static let flagshipStandardHeading = "Standard pricing data"
    static let groupedHeading = "Grouped Pricing Table data"
    static let tierLabels: Set<String> = ["standard", "batch", "flex", "fast mode"]
    static let codexCategory = "Codex"

    static let flagshipHeader = [
        "Model",
        "Short context input",
        "Short context cached input",
        "Short context cache writes",
        "Short context output",
        "Long context input",
        "Long context cached input",
        "Long context cache writes",
        "Long context output"
    ]
    static let categorizedHeader = ["Category", "Model", "Input", "Cached input", "Output"]

    static func parse(
        data: Data,
        aliases: [OpenAIPricingAlias] = OpenAIPricingSeed.reviewedAliases
    ) throws -> OpenAIPricingCatalog {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenAIPricingDocumentParserError.invalidEncoding
        }
        return try parse(text, aliases: aliases)
    }

    static func parse(
        _ text: String,
        aliases: [OpenAIPricingAlias] = OpenAIPricingSeed.reviewedAliases
    ) throws -> OpenAIPricingCatalog {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        let tables = locateTables(in: lines)

        var flagshipTables: [Table] = []
        var codexTables: [Table] = []
        for table in tables {
            guard equalsIgnoringCase(table.tierLabel, standardTierLabel) else { continue }
            if equalsIgnoringCase(table.heading, flagshipStandardHeading),
               headersMatch(table.header, flagshipHeader)
            {
                flagshipTables.append(table)
            } else if equalsIgnoringCase(table.heading, groupedHeading),
                      headersMatch(table.header, categorizedHeader)
            {
                codexTables.append(table)
            }
        }
        guard !flagshipTables.isEmpty else {
            throw OpenAIPricingDocumentParserError.missingStandardTable
        }
        guard flagshipTables.count == 1 else {
            throw OpenAIPricingDocumentParserError.ambiguousStandardTable(count: flagshipTables.count)
        }
        guard codexTables.count <= 1 else {
            throw OpenAIPricingDocumentParserError.ambiguousCodexTable(count: codexTables.count)
        }
        for table in flagshipTables + codexTables {
            guard table.hasSeparator, !table.rows.isEmpty else {
                throw OpenAIPricingDocumentParserError.malformedTable(line: table.headerLine)
            }
        }

        var modelsByID: [String: OpenAIModelPricing] = [:]
        func merge(_ model: OpenAIModelPricing) throws {
            if let existing = modelsByID[model.modelID] {
                guard existing == model else {
                    throw OpenAIPricingDocumentParserError.conflictingModelRows(modelID: model.modelID)
                }
                return
            }
            modelsByID[model.modelID] = model
        }

        for row in flagshipTables[0].rows {
            try merge(parseFlagshipRow(row))
        }
        if let codexTable = codexTables.first {
            for row in codexTable.rows {
                if let model = try parseCodexRow(row) {
                    try merge(model)
                }
            }
        }

        let modelIDs = Set(modelsByID.keys)
        var aliasesByName: [String: OpenAIPricingAlias] = [:]
        for alias in aliases where !modelIDs.contains(alias.alias) {
            aliasesByName[alias.alias] = alias
        }
        return OpenAIPricingCatalog(
            models: Array(modelsByID.values),
            aliases: Array(aliasesByName.values)
        )
    }

    // MARK: - Table location

    struct Row {
        let line: Int
        let cells: [String]
    }

    struct Table {
        let tierLabel: String?
        let heading: String?
        let header: [String]
        let headerLine: Int
        let hasSeparator: Bool
        let rows: [Row]
    }

    /// Finds every pipe table together with the nearest preceding `###` heading and the nearest
    /// non-blank line before that heading (the tier label, when it is one of the known tiers).
    private static func locateTables(in lines: [String]) -> [Table] {
        var tables: [Table] = []
        var index = 0
        while index < lines.count {
            guard isTableLine(lines[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < lines.count, isTableLine(lines[index]) {
                index += 1
            }
            let block = Array(lines[start ..< index])
            guard block.count >= 2 else { continue }

            var probe = start - 1
            while probe >= 0, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                probe -= 1
            }
            var heading: String?
            var tierLabel: String?
            if probe >= 0 {
                let candidate = lines[probe].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("### ") {
                    heading = String(candidate.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    probe -= 1
                    while probe >= 0, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                        probe -= 1
                    }
                    if probe >= 0 {
                        let label = lines[probe].trimmingCharacters(in: .whitespaces)
                        if tierLabels.contains(label.lowercased()) {
                            tierLabel = label
                        }
                    }
                }
            }

            let header = splitCells(block[0])
            let rows = block.dropFirst(2).enumerated().map { offset, line in
                Row(line: start + 2 + offset + 1, cells: splitCells(line))
            }
            tables.append(Table(
                tierLabel: tierLabel,
                heading: heading,
                header: header,
                headerLine: start + 1,
                hasSeparator: isSeparatorRow(block[1]),
                rows: Array(rows)
            ))
        }
        return tables
    }

    private static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func splitCells(_ line: String) -> [String] {
        var parts = line.trimmingCharacters(in: .whitespaces).split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func headersMatch(_ header: [String], _ expected: [String]) -> Bool {
        header.count == expected.count
            && zip(header, expected).allSatisfy { equalsIgnoringCase($0, $1) }
    }

    private static func equalsIgnoringCase(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs) == .orderedSame
    }

    // MARK: - Row parsing

    private static func parseFlagshipRow(_ row: Row) throws -> OpenAIModelPricing {
        guard row.cells.count == flagshipHeader.count else {
            throw OpenAIPricingDocumentParserError.malformedRow(line: row.line)
        }
        let model = try parseModelCell(row.cells[0], line: row.line)
        let short = try parseRates(Array(row.cells[1 ... 4]), line: row.line)
        let long = try parseRates(Array(row.cells[5 ... 8]), line: row.line)

        var bands: [OpenAIPricingContextBand] = []
        if long.isEmpty {
            guard !short.isEmpty else {
                throw OpenAIPricingDocumentParserError.malformedRow(line: row.line)
            }
            bands.append(OpenAIPricingContextBand(
                kind: model.thresholdTokens == nil ? .all : .shortContext,
                rates: short
            ))
        } else {
            guard !short.isEmpty else {
                throw OpenAIPricingDocumentParserError.malformedRow(line: row.line)
            }
            bands.append(OpenAIPricingContextBand(kind: .shortContext, rates: short))
            bands.append(OpenAIPricingContextBand(kind: .longContext, rates: long))
        }
        return OpenAIModelPricing(
            modelID: model.id,
            bands: bands,
            contextThresholdTokens: model.thresholdTokens
        )
    }

    private static func parseCodexRow(_ row: Row) throws -> OpenAIModelPricing? {
        guard row.cells.count == categorizedHeader.count else {
            throw OpenAIPricingDocumentParserError.malformedRow(line: row.line)
        }
        guard equalsIgnoringCase(row.cells[0], codexCategory) else {
            return nil
        }
        let model = try parseModelCell(row.cells[1], line: row.line)
        guard model.thresholdTokens == nil else {
            throw OpenAIPricingDocumentParserError.malformedModelCell(line: row.line, cell: row.cells[1])
        }
        let input = try parseAmount(row.cells[2], line: row.line)
        let cachedInput = try parseAmount(row.cells[3], line: row.line)
        let output = try parseAmount(row.cells[4], line: row.line)
        let rates = OpenAIPricingRates(input: input, cachedInput: cachedInput, cacheWrite: nil, output: output)
        guard !rates.isEmpty else {
            throw OpenAIPricingDocumentParserError.malformedRow(line: row.line)
        }
        return OpenAIModelPricing(modelID: model.id, bands: [OpenAIPricingContextBand(kind: .all, rates: rates)])
    }

    private static func parseRates(_ cells: [String], line: Int) throws -> OpenAIPricingRates {
        let input = try parseAmount(cells[0], line: line)
        let cachedInput = try parseAmount(cells[1], line: line)
        let cacheWrite = try parseAmount(cells[2], line: line)
        let output = try parseAmount(cells[3], line: line)
        return OpenAIPricingRates(input: input, cachedInput: cachedInput, cacheWrite: cacheWrite, output: output)
    }

    /// `-` → not listed (`nil`); `Free` → zero; `$<decimal>` → the amount. Anything else is malformed,
    /// including per-hour, per-character, per-minute, signed, grouped, or currency-less amounts.
    static func parseAmount(_ cell: String, line: Int) throws -> Decimal? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if trimmed == "-" || trimmed == "—" || trimmed == "–" {
            return nil
        }
        if trimmed.caseInsensitiveCompare("free") == .orderedSame {
            return 0
        }
        guard trimmed.hasPrefix("$"),
              let value = OpenAIPricingDecimal.parse(String(trimmed.dropFirst()))
        else {
            throw OpenAIPricingDocumentParserError.malformedAmount(line: line, cell: cell)
        }
        return value
    }

    struct ModelCell: Equatable {
        let id: String
        let thresholdTokens: Int?
    }

    /// Accepts `model-id` or `model-id (<NNNK context length)`; rejects every other qualifier.
    static func parseModelCell(_ cell: String, line: Int) throws -> ModelCell {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\s+\(<([0-9]{1,4})K context length\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: trimmed,
                  options: [],
                  range: NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
              ),
              let idRange = Range(match.range(at: 1), in: trimmed)
        else {
            throw OpenAIPricingDocumentParserError.malformedModelCell(line: line, cell: cell)
        }
        var threshold: Int?
        if let thresholdRange = Range(match.range(at: 2), in: trimmed) {
            guard let thousands = Int(trimmed[thresholdRange]), thousands > 0 else {
                throw OpenAIPricingDocumentParserError.malformedModelCell(line: line, cell: cell)
            }
            threshold = thousands * 1000
        }
        return ModelCell(
            id: OpenAIPricingCatalog.normalizedModelID(String(trimmed[idRange])),
            thresholdTokens: threshold
        )
    }
}
