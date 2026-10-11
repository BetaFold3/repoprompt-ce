import Foundation
import OSLog

enum WorkspaceCodemapBindingEngineProviderError: Error, Equatable {
    case unconfigured
}

/// Lazily creates the single binding engine owned by one artifact runtime.
///
/// Successful construction is memoized. Environmental failures use bounded backoff,
/// while deterministic provider/storage invariants remain parked.
final class WorkspaceCodemapBindingEngineProvider: @unchecked Sendable {
    typealias Factory = @Sendable (CodeMapArtifactRuntime) throws -> WorkspaceCodemapBindingEngine

    private enum FailureClassification {
        case transient
        case freelyRetryable
        case parked(reason: String)
    }

    private enum State {
        case pending(Factory)
        case retrying(
            factory: Factory,
            error: Error,
            retryNotBefore: Date,
            attempt: Int
        )
        case resolved(WorkspaceCodemapBindingEngine)
        case parked(Error)
    }

    static let unconfiguredFactory: Factory = { _ in
        throw WorkspaceCodemapBindingEngineProviderError.unconfigured
    }

    private static let logger = Logger(
        subsystem: "com.repoprompt.codemap",
        category: "binding-engine"
    )
    private static let initialRetryDelay: TimeInterval = 30
    private static let maximumRetryDelay: TimeInterval = 5 * 60

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var state: State

    init(
        factory: @escaping Factory = unconfiguredFactory,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        state = .pending(factory)
        self.now = now
    }

    func engine(for runtime: CodeMapArtifactRuntime) throws -> WorkspaceCodemapBindingEngine {
        lock.lock()
        defer { lock.unlock() }

        let factory: Factory
        let previousAttempt: Int
        switch state {
        case let .resolved(engine):
            return engine
        case let .parked(error):
            throw error
        case let .pending(pendingFactory):
            factory = pendingFactory
            previousAttempt = 0
        case let .retrying(retryFactory, error, retryNotBefore, attempt):
            guard now() >= retryNotBefore else { throw error }
            factory = retryFactory
            previousAttempt = attempt
        }

        do {
            let engine = try factory(runtime)
            state = .resolved(engine)
            return engine
        } catch {
            switch Self.classify(error) {
            case .freelyRetryable:
                state = .pending(factory)
                Self.logger.error(
                    "Codemap binding engine construction failed classification=freely_retryable error=\(String(describing: error), privacy: .private)"
                )
            case .transient:
                let attempt = previousAttempt + 1
                let delay = Self.retryDelay(forAttempt: attempt)
                state = .retrying(
                    factory: factory,
                    error: error,
                    retryNotBefore: now().addingTimeInterval(delay),
                    attempt: attempt
                )
                Self.logger.error(
                    "Codemap binding engine construction failed classification=transient attempt=\(attempt, privacy: .public) retryAfterSeconds=\(Int(delay), privacy: .public) error=\(String(describing: error), privacy: .private)"
                )
            case let .parked(reason):
                state = .parked(error)
                Self.logger.fault(
                    "Codemap binding engine construction parked reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .private)"
                )
            }
            throw error
        }
    }

    static func isParkedFailure(_ error: Error) -> Bool {
        if case .parked = classify(error) {
            return true
        }
        return false
    }

    private static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 4)
        return min(initialRetryDelay * TimeInterval(1 << exponent), maximumRetryDelay)
    }

    private static func classify(_ error: Error) -> FailureClassification {
        if error is CancellationError {
            return .freelyRetryable
        }
        if let error = error as? CodeMapRepositoryNamespaceSaltStoreError {
            return switch error {
            case .ioFailure: .transient
            case .insecureStorage: .parked(reason: "insecure_namespace_salt_storage")
            }
        }
        if error is WorkspaceCodemapBindingEngineProviderError {
            return .parked(reason: "binding_engine_provider_invariant")
        }
        return .transient
    }
}
