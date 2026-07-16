import Foundation
import RepoPromptRemoteWire

struct RemoteHostHTTPResponse: Equatable {
    let statusCode: Int
    let finalURL: URL
    let contentType: String?
    let body: Data
}

enum RemoteHostHTTPClientError: Error, Equatable {
    case invalidResponse
    case redirected
    case responseTooLarge(limit: Int)
    case finalURLMismatch
}

final class RemoteHostHTTPRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RemoteHostHTTPRedirectRejectingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor RemoteHostHTTPClient {
    static let shared = RemoteHostHTTPClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 16
            self.session = URLSession(
                configuration: configuration,
                delegate: RemoteHostHTTPRedirectRejectingDelegate.shared,
                delegateQueue: nil
            )
        }
    }

    func postJSON(
        to url: URL,
        body: Data,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> RemoteHostHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, maximumResponseBytes: maximumResponseBytes)
    }

    func get(
        _ url: URL,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> RemoteHostHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return try await send(request, maximumResponseBytes: maximumResponseBytes)
    }

    private func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> RemoteHostHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url
        else {
            throw RemoteHostHTTPClientError.invalidResponse
        }
        guard finalURL == request.url else {
            throw RemoteHostHTTPClientError.redirected
        }
        var body = Data()
        body.reserveCapacity(min(maximumResponseBytes, Int(http.expectedContentLength.clamped(to: 0 ... Int64(maximumResponseBytes)))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumResponseBytes else {
                throw RemoteHostHTTPClientError.responseTooLarge(limit: maximumResponseBytes)
            }
            body.append(byte)
        }
        return RemoteHostHTTPResponse(
            statusCode: http.statusCode,
            finalURL: finalURL,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            body: body
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
