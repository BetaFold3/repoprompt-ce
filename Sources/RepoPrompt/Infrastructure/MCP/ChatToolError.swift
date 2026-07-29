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
