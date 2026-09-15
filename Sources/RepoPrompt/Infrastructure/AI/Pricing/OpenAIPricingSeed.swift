import Foundation

/// Reviewed literal seed transcribed from the official OpenAI pricing document.
///
/// Source: `https://developers.openai.com/api/docs/pricing.md`, captured 2026-09-15 with
/// `Last-Modified: Tue, 15 Sep 2026 02:21:17 GMT` and `ETag: "9c9c657012f2a8a709e5333323e8e04f"`.
/// Only the flagship `Standard pricing data` table and the `Codex` row of the specialized
/// `Standard` grouped table are transcribed. `nil` cells were `-` in the document (not listed,
/// never zero). Aliases are limited to the ones the document states explicitly.
///
/// The seed must equal `OpenAIPricingDocumentParser.parse` of the captured document; the test
/// suite enforces that so a transcription error cannot ship silently.
enum OpenAIPricingSeed {
    static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    static let documentETag = "\"9c9c657012f2a8a709e5333323e8e04f\""
    static let documentLastModified = "Tue, 15 Sep 2026 02:21:17 GMT"
    /// Document `Last-Modified` of the reviewed capture (UTC).
    static let reviewedAt = Date(timeIntervalSince1970: 1_789_438_877)

    /// Explicit alias statements from the document. `gpt-daybreak-red-latest` targets
    /// `gpt-5.6-cyber`, which is not in a parsed Standard table, so it resolves to unpriced.
    static let reviewedAliases: [OpenAIPricingAlias] = [
        OpenAIPricingAlias(alias: "gpt-daybreak-blue-latest", targetModelID: "gpt-5.6-sol"),
        OpenAIPricingAlias(alias: "gpt-daybreak-red-latest", targetModelID: "gpt-5.6-cyber")
    ]

    static let catalog = OpenAIPricingCatalog(
        models: flagshipStandardModels + codexStandardModels,
        aliases: reviewedAliases
    )

    /// `### Standard pricing data` under the flagship `Standard` tier, in document order.
    private static let flagshipStandardModels: [OpenAIModelPricing] = [
        banded("gpt-6-astra", short: ["10.00", "1.00", "12.50", "50.00"], long: ["20.00", "2.00", "25.00", "75.00"]),
        banded("gpt-5.6-sol", short: ["4.00", "0.40", "5.00", "20.00"], long: ["8.00", "0.80", "10.00", "30.00"]),
        banded("gpt-5.6-terra", short: ["2.00", "0.20", "2.50", "12.00"], long: ["4.00", "0.40", "5.00", "18.00"]),
        banded("gpt-5.6-luna", short: ["0.20", "0.02", "0.25", "1.20"], long: ["0.40", "0.04", "0.50", "1.80"]),
        banded("gpt-5.5", short: ["5.00", "0.50", nil, "30.00"], long: ["10.00", "1.00", nil, "45.00"], threshold: 272_000),
        banded("gpt-5.5-pro", short: ["30.00", nil, nil, "180.00"], long: ["60.00", nil, nil, "270.00"], threshold: 272_000),
        banded("gpt-5.4", short: ["2.50", "0.25", nil, "15.00"], long: ["5.00", "0.50", nil, "22.50"], threshold: 272_000),
        flat("gpt-5.4-mini", ["0.75", "0.075", nil, "4.50"]),
        flat("gpt-5.4-nano", ["0.20", "0.02", nil, "1.25"]),
        banded("gpt-5.4-pro", short: ["30.00", nil, nil, "180.00"], long: ["60.00", nil, nil, "270.00"], threshold: 272_000),
        flat("gpt-5.2", ["1.75", "0.175", nil, "14.00"]),
        flat("gpt-5.2-pro", ["21.00", nil, nil, "168.00"]),
        flat("gpt-5.1", ["1.25", "0.125", nil, "10.00"]),
        flat("gpt-5", ["1.25", "0.125", nil, "10.00"]),
        flat("gpt-5-mini", ["0.25", "0.025", nil, "2.00"]),
        flat("gpt-5-nano", ["0.05", "0.005", nil, "0.40"]),
        flat("gpt-5-pro", ["15.00", nil, nil, "120.00"]),
        flat("gpt-4.1", ["2.00", "0.50", nil, "8.00"]),
        flat("gpt-4.1-mini", ["0.40", "0.10", nil, "1.60"]),
        flat("gpt-4.1-nano", ["0.10", "0.025", nil, "0.40"]),
        flat("gpt-4o", ["2.50", "1.25", nil, "10.00"]),
        flat("gpt-4o-2024-05-13", ["5.00", nil, nil, "15.00"]),
        flat("gpt-4o-mini", ["0.15", "0.075", nil, "0.60"]),
        flat("o1", ["15.00", "7.50", nil, "60.00"]),
        flat("o1-pro", ["150.00", nil, nil, "600.00"]),
        flat("o3-pro", ["20.00", nil, nil, "80.00"]),
        flat("o3", ["2.00", "0.50", nil, "8.00"]),
        flat("o4-mini", ["1.10", "0.275", nil, "4.40"]),
        flat("o3-mini", ["1.10", "0.55", nil, "4.40"]),
        flat("gpt-4-turbo-2024-04-09", ["10.00", nil, nil, "30.00"]),
        flat("gpt-4-0613", ["30.00", nil, nil, "60.00"]),
        flat("gpt-3.5-turbo", ["0.50", nil, nil, "1.50"]),
        flat("gpt-3.5-turbo-0125", ["0.50", nil, nil, "1.50"]),
        flat("gpt-3.5-turbo-1106", ["1.00", nil, nil, "2.00"]),
        flat("gpt-3.5-turbo-instruct", ["1.50", nil, nil, "2.00"]),
        flat("davinci-002", ["2.00", nil, nil, "2.00"]),
        flat("babbage-002", ["0.40", nil, nil, "0.40"])
    ]

    /// `Codex` rows of the specialized `Standard` → `### Grouped Pricing Table data` table.
    /// That table has no cache-write column, so `cacheWrite` is not listed.
    private static let codexStandardModels: [OpenAIModelPricing] = [
        flat("gpt-5.3-codex", ["1.75", "0.175", nil, "14.00"])
    ]

    // MARK: - Literal helpers

    private static func usd(_ text: String?) -> Decimal? {
        guard let text else { return nil }
        guard let value = OpenAIPricingDecimal.parse(text) else {
            preconditionFailure("Invalid reviewed seed amount '\(text)'")
        }
        return value
    }

    private static func rates(_ cells: [String?]) -> OpenAIPricingRates {
        precondition(cells.count == 4, "Seed rate rows carry input, cached input, cache write, output")
        return OpenAIPricingRates(
            input: usd(cells[0]),
            cachedInput: usd(cells[1]),
            cacheWrite: usd(cells[2]),
            output: usd(cells[3])
        )
    }

    private static func flat(_ modelID: String, _ cells: [String?]) -> OpenAIModelPricing {
        OpenAIModelPricing(
            modelID: modelID,
            bands: [OpenAIPricingContextBand(kind: .all, rates: rates(cells))]
        )
    }

    private static func banded(
        _ modelID: String,
        short: [String?],
        long: [String?],
        threshold: Int? = nil
    ) -> OpenAIModelPricing {
        OpenAIModelPricing(
            modelID: modelID,
            bands: [
                OpenAIPricingContextBand(kind: .shortContext, rates: rates(short)),
                OpenAIPricingContextBand(kind: .longContext, rates: rates(long))
            ],
            contextThresholdTokens: threshold
        )
    }
}
