import Foundation

/// Oracle-specific advice. Shared error formatting stays provider-neutral.
enum OracleErrorPresenter {
    static func message(
        for error: Error,
        tokenCount: Int = 0,
        capturedModel: AIModel? = nil
    ) -> String {
        guard let err = error as NSError?, err.domain == NSURLErrorDomain else {
            // Check if this is an OpenAI request too large error
            if let openAIError = error as? CustomOpenAIProviderError {
                switch openAIError {
                case .requestTooLarge:
                    var message = "Request too large. The model has strict token limits and the provided request exceeds them."
                    if tokenCount > 0 {
                        message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
                        message += "\nTip: Try deselecting some files to reduce the context size."
                    }
                    return message
                default:
                    // Check if it's the vague "no additional details" error
                    let errorString = error.asFriendlyString()
                    if errorString.contains("no additional details") {
                        var message = "OpenAI error: Request failed. This often occurs when the request is too large or there are insufficient credits on your account."
                        if tokenCount > 0 {
                            message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
                            message += "\nTip: Try deselecting some files to reduce the context size."
                        }
                        return message
                    }
                    return errorString
                }
            }

            if let failure = AIProviderRequestSizeFailure.detect(in: error) {
                return requestSizeMessage(
                    for: failure,
                    tokenCount: tokenCount,
                    capturedModel: capturedModel
                )
            }

            // Also check for the generic error string case
            let errorString = error.asFriendlyString()
            if errorString.contains("no additional details") {
                var message = "Request failed. This often occurs when the request is too large or there are insufficient credits on your account."
                if tokenCount > 0 {
                    message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
                    message += "\nTip: Try deselecting some files to reduce the context size."
                }
                return message
            }

            return errorString
        }
        switch err.code {
        case NSURLErrorTimedOut:
            return "The request timed out. Please check your internet connection and try again."
        case NSURLErrorCannotConnectToHost:
            return "Unable to connect to the server. Please try again later."
        case NSURLErrorNetworkConnectionLost:
            return "The network connection was lost. Please check your internet connection and try again."
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection. Please check your network settings and try again."
        case NSURLErrorSecureConnectionFailed:
            return "Secure connection failed."
        default:
            return "\(error.asFriendlyString())"
        }
    }

    private static func requestSizeMessage(
        for failure: AIProviderRequestSizeFailure,
        tokenCount: Int,
        capturedModel: AIModel?
    ) -> String {
        let message: String
        let tip: String
        switch failure.limit {
        case let .characters(limit):
            let isCodex = failure.sourceDomain == "CodexAppServer"
            let provider = isCodex ? "The Codex app server" : "The provider"
            message = "Request too large. \(provider) rejected this request; its reported input limit is \(limit.formatted()) characters, which is separate from the model's token context window."
            tip = isCodex
                ? "Tip: Deselect some files or use slices, or start a new Oracle chat — this Oracle provider resends the full conversation history with every request."
                : "Tip: Deselect some files or use slices, or start a new Oracle chat."
        case .unreported:
            message = "Request too large. The provider rejected this request as too long and did not report a maximum size."
            tip = "Tip: Deselect some files or use slices, or start a new Oracle chat to drop earlier conversation history."
        }

        var result = message
        if let capturedModel {
            let metadata = AIModelCapabilityMetadata.resolve(for: capturedModel)
            if metadata.windowSource == .exact,
               let window = metadata.contextWindowTokens, window > 0
            {
                result += "\n\nModel context window: about \(window.formatted()) tokens. This is separate from the provider's input-size limit and is not the available input budget."
            }
        }
        if tokenCount > 0 {
            result += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens (current Prompt context estimate; not a character count and excludes Oracle conversation messages and provider-added text)."
        }
        result += "\n\n\(tip)"
        return result
    }
}
