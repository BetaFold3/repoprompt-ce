import Foundation

/// Provider-reported request-size failures, without inferring a token budget.
struct AIProviderRequestSizeFailure: Equatable {
    enum Limit: Equatable {
        case characters(Int)
        case unreported
    }

    let limit: Limit
    let providerSentence: String
    let sourceDomain: String?

    private static let characterLimitPattern = try? NSRegularExpression(
        pattern: #"\bmaximum length of ([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+) characters\b"#,
        options: .caseInsensitive
    )

    static func detect(in error: Error) -> AIProviderRequestSizeFailure? {
        var source = error
        var wrappingDepth = 0
        while let providerError = source as? AIProviderError {
            switch providerError {
            case let .apiError(underlying?), let .unknown(underlying?):
                guard wrappingDepth < 16 else { return nil }
                wrappingDepth += 1
                source = underlying
            default:
                return detectDescription(in: source)
            }
        }
        return detectDescription(in: source)
    }

    private static func detectDescription(in error: Error) -> AIProviderRequestSizeFailure? {
        let nsError = error as NSError
        let localizedDescription = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitDescription = (nsError.userInfo[NSLocalizedDescriptionKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let description = [localizedDescription, explicitDescription]
            .compactMap(\.self).first(where: { !$0.isEmpty })
        else { return nil }

        let range = NSRange(description.startIndex..., in: description)
        if let match = characterLimitPattern?.firstMatch(in: description, range: range),
           let numberRange = Range(match.range(at: 1), in: description)
        {
            let digits = description[numberRange].replacingOccurrences(of: ",", with: "")
            guard let limit = Int(digits), limit > 0 else { return nil }
            return Self(
                limit: .characters(limit),
                providerSentence: description,
                sourceDomain: nsError.domain
            )
        }

        if description.range(
            of: #"\bprompt is too long\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return Self(
                limit: .unreported,
                providerSentence: description,
                sourceDomain: nsError.domain
            )
        }
        return nil
    }
}
