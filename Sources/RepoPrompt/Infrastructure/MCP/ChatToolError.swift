import Foundation
import MCP // for `Value`

enum ChatToolErrorCode: String, Codable {
    case invalidParams = "invalid_params"
    case notFound = "not_found"
    case conflict
    case internalError = "internal_error"
    case fileNotFound = "file_not_found"
    case permissionDenied = "permission_denied"
    case oracleSessionBusy = "oracle_session_busy"
    case oracleConcurrencyLimit = "oracle_concurrency_limit"
    case oracleContextOverflow = "oracle_context_overflow"
}

struct ChatToolError: LocalizedError, Codable {
    let code: ChatToolErrorCode
    let message: String
    let details: [String: String]?

    var errorDescription: String? {
        message
    }

    /// Convenience builders
    static func invalidParams(
        _ msg: String,
        details: [String: String]? = nil
    ) -> Self {
        .init(code: .invalidParams, message: msg, details: details)
    }

    static func notFound(_ msg: String) -> Self {
        .init(code: .notFound, message: msg, details: nil)
    }

    static func internalError(_ msg: String) -> Self {
        .init(code: .internalError, message: msg, details: nil)
    }

    static func oracleSessionBusy(_ msg: String) -> Self {
        .init(code: .oracleSessionBusy, message: "oracle_session_busy: \(msg)", details: nil)
    }

    static func oracleConcurrencyLimit(_ msg: String) -> Self {
        .init(code: .oracleConcurrencyLimit, message: "oracle_concurrency_limit: \(msg)", details: nil)
    }

    static func oracleContextOverflow(_ estimate: OracleRequestBudgetEstimate) -> Self {
        let largest = estimate.contributors.prefix(4)
            .map { "\($0.name)=\($0.tokens)" }
            .joined(separator: ", ")
        let remedies = "Prune the workspace selection; retry the continuation with selection_mode:none; or start a fresh chat with a concise summary."
        let window = estimate.contextWindowTokens ?? 0
        return .init(
            code: .oracleContextOverflow,
            message: "oracle_context_overflow: packaged request requires \(estimate.requiredTokens) tokens but the context window is \(window). Largest contributors: \(largest). Remedies: \(remedies)",
            details: [
                "context_window_tokens": String(window),
                "required_tokens": String(estimate.requiredTokens),
                "input_tokens": String(estimate.inputTokens),
                "output_reserve_tokens": String(estimate.outputReserveTokens),
                "tokenizer_margin_tokens": String(estimate.tokenizerMarginTokens),
                "largest_contributors": largest,
                "remedies": remedies
            ]
        )
    }

    /// Serialise into the canonical MCP Value wrapper
    func toMCPValue() -> Value {
        var dict: [String: Value] = [
            "error": .object([
                "code": .string(code.rawValue),
                "message": .string(message)
            ])
        ]
        if let d = details {
            dict["error_details"] = .object(
                d.mapValues { .string($0) }
            )
        }
        return .object(dict)
    }
}
