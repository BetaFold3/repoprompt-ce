import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenAIPricingDocumentParserTests: XCTestCase {
    private static let flagshipHeader = """
    | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    """
    private static let categorizedHeader = """
    | Category | Model | Input | Cached input | Output |
    | --- | --- | --- | --- | --- |
    """
    private static let validFlagshipRow = "| gpt-5.2 | $1.75 | $0.175 | - | $14.00 | - | - | - | - |"
    private static let validCodexRow = "| Codex | gpt-5.3-codex | $1.75 | $0.175 | $14.00 |"

    /// Exact decimal from text; float literals such as `0.175` are not exactly representable.
    private func usd(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    // MARK: - Official capture and reviewed seed

    func testOfficialCaptureParsesToReviewedSeedAndIgnoresNonStandardTables() throws {
        let parsed = try OpenAIPricingDocumentParser.parse(OpenAIPricingDocumentFixture.officialCapture20260915)

        XCTAssertEqual(parsed, OpenAIPricingSeed.catalog)
        XCTAssertEqual(parsed.pricingVersion, OpenAIPricingSeed.catalog.pricingVersion)
        XCTAssertEqual(parsed.models.count, 38)
        XCTAssertEqual(parsed.aliases, OpenAIPricingSeed.reviewedAliases.sorted { $0.alias < $1.alias })
        XCTAssertEqual(parsed.basis, .standardGlobalListPriceUSDPerMillionTokens)

        // Codex row comes from the specialized Standard table, not its Fast-mode sibling.
        let codex = try XCTUnwrap(parsed.resolve(modelID: "gpt-5.3-codex"))
        XCTAssertEqual(codex.pricing.flatRates, OpenAIPricingRates(input: usd("1.75"), cachedInput: usd("0.175"), cacheWrite: nil, output: 14))
        // Batch/Flex/Fast/Cyber/multimodal/tool/fine-tuning tables are never read.
        XCTAssertNil(parsed.pricing(forExactModelID: "gpt-5.6-cyber"))
        XCTAssertNil(parsed.pricing(forExactModelID: "gpt-realtime"))
        XCTAssertNil(parsed.pricing(forExactModelID: "chat-latest"))
        XCTAssertNil(parsed.pricing(forExactModelID: "o4-mini-2025-04-16"))
        let astra = try XCTUnwrap(parsed.pricing(forExactModelID: "gpt-6-astra"))
        XCTAssertEqual(astra.bands.map(\.kind), [.shortContext, .longContext])
        XCTAssertEqual(astra.bands[0].rates.input, 10)
    }

    func testInstalledCodexBaseCoverageMatchesOfficialListing() throws {
        let catalog = OpenAIPricingSeed.catalog
        let priced = ["gpt-5.3-codex", "gpt-5.2", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        for modelID in priced {
            let resolution = try XCTUnwrap(catalog.resolve(modelID: modelID), modelID)
            XCTAssertFalse(resolution.matchedViaAlias, modelID)
            XCTAssertEqual(resolution.resolvedModelID, modelID)
        }
        // Not listed in any Standard table and no official alias: stays unpriced rather than family-inferred.
        for modelID in ["gpt-5.6", "gpt-5.1-codex-mini", "gpt-5.1-mini", "gpt-5.1-codex-max", "gpt-5.6-cyber"] {
            XCTAssertNil(catalog.resolve(modelID: modelID), modelID)
        }
    }

    // MARK: - Table selection

    func testSelectsTablesByTierLabelHeadingAndHeaderNotPosition() throws {
        let document = """
        Flagship models

        Batch

        ### Batch pricing data

        \(Self.flagshipHeader)
        | gpt-5.2 | $0.875 | $0.0875 | - | $7.00 | - | - | - | - |

        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)

        Fast mode

        ### Fast pricing data

        \(Self.flagshipHeader)
        | gpt-5.2 | $3.50 | $0.35 | - | $28.00 | - | - | - | - |

        Cyber models

        Prices per 1M tokens.

        ### Grouped Pricing Table data

        \(Self.flagshipHeader)
        | gpt-5.6-cyber | $12.50 | $1.25 | $15.625 | $75.00 | - | - | - | - |

        Specialized models

        Fast mode

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        | Codex | gpt-5.3-codex | $3.50 | $0.35 | $28.00 |

        Standard

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        \(Self.validCodexRow)
        """

        let catalog = try OpenAIPricingDocumentParser.parse(document, aliases: [])
        XCTAssertEqual(catalog.models.map(\.modelID), ["gpt-5.2", "gpt-5.3-codex"])
        XCTAssertEqual(catalog.pricing(forExactModelID: "gpt-5.2")?.flatRates?.input, 1.75)
        XCTAssertEqual(catalog.pricing(forExactModelID: "gpt-5.3-codex")?.flatRates?.output, 14)
        XCTAssertNil(catalog.pricing(forExactModelID: "gpt-5.6-cyber"))
    }

    func testMissingOrAmbiguousQualifiedTablesRejectWhileCodexTableIsOptional() throws {
        let standardBlock = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)
        """
        let codexBlock = """
        Standard

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        \(Self.validCodexRow)
        """
        let unlabeledStandard = """
        Prices per 1M tokens.

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)
        """

        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(codexBlock, aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .missingStandardTable)
        }
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(unlabeledStandard, aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .missingStandardTable)
        }
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(standardBlock + "\n\n" + standardBlock, aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .ambiguousStandardTable(count: 2))
        }
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse([standardBlock, codexBlock, codexBlock].joined(separator: "\n\n"), aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .ambiguousCodexTable(count: 2))
        }

        let withoutCodex = try OpenAIPricingDocumentParser.parse(standardBlock, aliases: [])
        XCTAssertEqual(withoutCodex.models.map(\.modelID), ["gpt-5.2"])
        XCTAssertNil(withoutCodex.resolve(modelID: "gpt-5.3-codex"))
    }

    func testCodexTableUsesOnlyCodexCategoryRows() throws {
        let document = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)

        Standard

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        | ChatGPT | chat-latest | $5.00 | $0.50 | $30.00 |
        | Codex | gpt-5.3-codex | $1.75 | $0.175 | $14.00 |
        | Embedding | text-embedding-3-small | $0.02 | - | - |
        | Moderation | omni-moderation-latest | Free | - | - |
        """

        let catalog = try OpenAIPricingDocumentParser.parse(document, aliases: [])
        XCTAssertEqual(catalog.models.map(\.modelID), ["gpt-5.2", "gpt-5.3-codex"])
        let codex = try XCTUnwrap(catalog.pricing(forExactModelID: "gpt-5.3-codex"))
        XCTAssertEqual(codex.bands.map(\.kind), [.all])
        XCTAssertNil(codex.bands[0].rates.cacheWrite, "the grouped table has no cache-write column")
        XCTAssertNil(codex.contextThresholdTokens)

        let qualifiedCodex = document.replacingOccurrences(
            of: "| Codex | gpt-5.3-codex |",
            with: "| Codex | gpt-5.3-codex (<272K context length) |"
        )
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(qualifiedCodex, aliases: [])) { error in
            guard case .malformedModelCell? = error as? OpenAIPricingDocumentParserError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    // MARK: - Bands, unknown versus zero

    func testContextBandAndThresholdSemanticsNeverSelectCheapestBandSilently() throws {
        let seed = OpenAIPricingSeed.catalog

        let gpt55 = try XCTUnwrap(seed.pricing(forExactModelID: "gpt-5.5"))
        XCTAssertEqual(gpt55.contextThresholdTokens, 272_000)
        XCTAssertNil(gpt55.flatRates)
        XCTAssertEqual(gpt55.band(forContextTokens: 271_999)?.kind, .shortContext)
        XCTAssertEqual(gpt55.band(forContextTokens: 271_999)?.rates.input, 5)
        XCTAssertEqual(gpt55.band(forContextTokens: 272_000)?.kind, .longContext)
        XCTAssertEqual(gpt55.band(forContextTokens: 272_000)?.rates.output, 45)
        XCTAssertEqual(gpt55.rateEnvelope.input, Decimal(5) ... Decimal(10))
        XCTAssertEqual(gpt55.rateEnvelope.cachedInput, usd("0.50") ... Decimal(1))
        XCTAssertNil(gpt55.rateEnvelope.cacheWrite, "unlisted write rate must not become a bound")
        XCTAssertEqual(gpt55.rateEnvelope.output, Decimal(30) ... Decimal(45))

        let sol = try XCTUnwrap(seed.pricing(forExactModelID: "gpt-5.6-sol"))
        XCTAssertNil(sol.contextThresholdTokens, "the document states no threshold for this row")
        XCTAssertNil(sol.flatRates)
        XCTAssertNil(sol.band(forContextTokens: 1))
        XCTAssertNil(sol.band(forContextTokens: 1_000_000))
        XCTAssertEqual(sol.rateEnvelope.input, Decimal(4) ... Decimal(8))
        XCTAssertEqual(sol.rateEnvelope.cacheWrite, Decimal(5) ... Decimal(10))

        let gpt52 = try XCTUnwrap(seed.pricing(forExactModelID: "gpt-5.2"))
        XCTAssertEqual(gpt52.flatRates?.input, 1.75)
        XCTAssertEqual(gpt52.band(forContextTokens: 10_000_000)?.kind, .all)
        XCTAssertEqual(gpt52.rateEnvelope.output, Decimal(14) ... Decimal(14))

        let shortOnly = try OpenAIPricingDocumentParser.parse("""
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        | gpt-short (<128K context length) | $1.00 | - | - | $2.00 | - | - | - | - |
        """, aliases: [])
        let short = try XCTUnwrap(shortOnly.pricing(forExactModelID: "gpt-short"))
        XCTAssertEqual(short.bands.map(\.kind), [.shortContext])
        XCTAssertEqual(short.contextThresholdTokens, 128_000)
        XCTAssertNil(short.flatRates)
        XCTAssertEqual(short.band(forContextTokens: 127_999)?.rates.input, 1)
        XCTAssertNil(short.band(forContextTokens: 128_000), "long band is not listed")
        XCTAssertEqual(short.rateEnvelope, .unavailable)
    }

    func testDashIsUnknownWhileZeroAndFreeAreKnownZero() throws {
        let catalog = try OpenAIPricingDocumentParser.parse("""
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        | gpt-zero | $0.00 | $0 | Free | $1.00 | - | - | - | - |
        \(Self.validFlagshipRow)
        """, aliases: [])

        let zero = try XCTUnwrap(catalog.pricing(forExactModelID: "gpt-zero")?.flatRates)
        XCTAssertEqual(zero.input, 0)
        XCTAssertEqual(zero.cachedInput, 0)
        XCTAssertEqual(zero.cacheWrite, 0)
        XCTAssertEqual(zero.output, 1)

        let listed = try XCTUnwrap(catalog.pricing(forExactModelID: "gpt-5.2")?.flatRates)
        XCTAssertNil(listed.cacheWrite)
        XCTAssertNotEqual(listed.cacheWrite, zero.cacheWrite)
    }

    // MARK: - Atomic rejection

    func testMalformedAmountsCellsRowsAndTablesRejectWholeDocument() {
        typealias Failure = OpenAIPricingDocumentParserError
        let isAmount: (Failure) -> Bool = { failure in
            if case .malformedAmount = failure { return true }
            return false
        }
        let isRow: (Failure) -> Bool = { failure in
            if case .malformedRow = failure { return true }
            return false
        }
        let isModelCell: (Failure) -> Bool = { failure in
            if case .malformedModelCell = failure { return true }
            return false
        }
        let cases: [(name: String, row: String, matches: (Failure) -> Bool)] = [
            ("per-hour amount", "| gpt-bad | $1.00 / hour | - | - | $2.00 | - | - | - | - |", isAmount),
            ("currency-less amount", "| gpt-bad | 1.00 | - | - | $2.00 | - | - | - | - |", isAmount),
            ("grouped amount", "| gpt-bad | $1,000.00 | - | - | $2.00 | - | - | - | - |", isAmount),
            ("signed amount", "| gpt-bad | $-1.00 | - | - | $2.00 | - | - | - | - |", isAmount),
            ("blank cell", "| gpt-bad |  | - | - | $2.00 | - | - | - | - |", isAmount),
            ("short row", "| gpt-bad | $1.00 | - | - | $2.00 | - | - | - |", isRow),
            ("long row", "| gpt-bad | $1.00 | - | - | $2.00 | - | - | - | - | - |", isRow),
            ("unknown qualifier", "| gpt-bad (legacy) | $1.00 | - | - | $2.00 | - | - | - | - |", isModelCell),
            ("prose model cell", "| see [pricing](x) | $1.00 | - | - | $2.00 | - | - | - | - |", isModelCell),
            ("no rates", "| gpt-bad | - | - | - | - | - | - | - | - |", isRow),
            ("long without short", "| gpt-bad | - | - | - | - | $1.00 | - | - | $2.00 |", isRow)
        ]

        for testCase in cases {
            let document = """
            Standard

            ### Standard pricing data

            \(Self.flagshipHeader)
            \(Self.validFlagshipRow)
            \(testCase.row)
            """
            XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(document, aliases: []), testCase.name) { error in
                guard let failure = error as? Failure, testCase.matches(failure) else {
                    return XCTFail("\(testCase.name): unexpected error \(error)")
                }
            }
        }

        let missingSeparator = """
        Standard

        ### Standard pricing data

        | Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
        \(Self.validFlagshipRow)
        """
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(missingSeparator, aliases: [])) { error in
            guard case .malformedTable? = error as? Failure else {
                return XCTFail("Unexpected error \(error)")
            }
        }

        let badCodexRow = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)

        Standard

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        | Codex | gpt-5.3-codex | $1.75 | $0.175 |
        """
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(badCodexRow, aliases: [])) { error in
            guard case .malformedRow? = error as? Failure else {
                return XCTFail("Unexpected error \(error)")
            }
        }

        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(data: Data([0xFF, 0xFE, 0x00]))) { error in
            XCTAssertEqual(error as? Failure, .invalidEncoding)
        }
    }

    func testConflictingDuplicateRowsRejectWhileIdenticalDuplicatesMerge() throws {
        let identical = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)
        \(Self.validFlagshipRow)
        """
        XCTAssertEqual(try OpenAIPricingDocumentParser.parse(identical, aliases: []).models.count, 1)

        let conflicting = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)
        | gpt-5.2 | $1.80 | $0.175 | - | $14.00 | - | - | - | - |
        """
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(conflicting, aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .conflictingModelRows(modelID: "gpt-5.2"))
        }

        let crossTableConflict = """
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        | gpt-5.3-codex | $1.75 | $0.175 | - | $14.00 | - | - | - | - |

        Standard

        ### Grouped Pricing Table data

        \(Self.categorizedHeader)
        | Codex | gpt-5.3-codex | $1.75 | $0.175 | $15.00 |
        """
        XCTAssertThrowsError(try OpenAIPricingDocumentParser.parse(crossTableConflict, aliases: [])) { error in
            XCTAssertEqual(error as? OpenAIPricingDocumentParserError, .conflictingModelRows(modelID: "gpt-5.3-codex"))
        }
    }

    // MARK: - Resolution and persistence format

    func testResolutionUsesExactIDThenReviewedAliasAndLeavesUnlistedUnpriced() throws {
        let seed = OpenAIPricingSeed.catalog

        let exact = try XCTUnwrap(seed.resolve(modelID: "  GPT-5.5 \n"))
        XCTAssertEqual(exact.requestedModelID, "gpt-5.5")
        XCTAssertEqual(exact.resolvedModelID, "gpt-5.5")
        XCTAssertFalse(exact.matchedViaAlias)

        let alias = try XCTUnwrap(seed.resolve(modelID: "gpt-daybreak-blue-latest"))
        XCTAssertEqual(alias.resolvedModelID, "gpt-5.6-sol")
        XCTAssertTrue(alias.matchedViaAlias)
        XCTAssertEqual(alias.pricing, seed.pricing(forExactModelID: "gpt-5.6-sol"))

        XCTAssertNil(seed.resolve(modelID: "gpt-daybreak-red-latest"), "alias target is not in a parsed Standard table")
        XCTAssertNil(seed.resolve(modelID: ""))
        XCTAssertNil(seed.resolve(modelID: "gpt-5.6"))

        // An alias that would shadow an exact listed ID is dropped; exact IDs always win.
        let shadowing = try OpenAIPricingDocumentParser.parse("""
        Standard

        ### Standard pricing data

        \(Self.flagshipHeader)
        \(Self.validFlagshipRow)
        | gpt-5 | $1.25 | $0.125 | - | $10.00 | - | - | - | - |
        """, aliases: [OpenAIPricingAlias(alias: "gpt-5.2", targetModelID: "gpt-5")])
        XCTAssertTrue(shadowing.aliases.isEmpty)
        XCTAssertEqual(shadowing.resolve(modelID: "gpt-5.2")?.pricing.flatRates?.input, 1.75)
    }

    func testCatalogCodableRoundTripPreservesExactDecimalsAndRejectsTamperedContent() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(OpenAIPricingSeed.catalog)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"cachedInput\":\"0.175\""), "rates persist as exact decimal strings")

        let decoded = try JSONDecoder().decode(OpenAIPricingCatalog.self, from: data)
        XCTAssertEqual(decoded, OpenAIPricingSeed.catalog)
        XCTAssertEqual(decoded.pricingVersion, OpenAIPricingSeed.catalog.pricingVersion)

        let tamperedVersion = json.replacingOccurrences(of: OpenAIPricingSeed.catalog.pricingVersion, with: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIPricingCatalog.self, from: Data(tamperedVersion.utf8)))

        let tamperedRate = json.replacingOccurrences(of: "\"cachedInput\":\"0.175\"", with: "\"cachedInput\":\"0.176\"")
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIPricingCatalog.self, from: Data(tamperedRate.utf8)))

        let futureSchema = json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIPricingCatalog.self, from: Data(futureSchema.utf8)))

        let negativeRate = json.replacingOccurrences(of: "\"cachedInput\":\"0.175\"", with: "\"cachedInput\":\"-0.175\"")
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIPricingCatalog.self, from: Data(negativeRate.utf8)))
    }
}
