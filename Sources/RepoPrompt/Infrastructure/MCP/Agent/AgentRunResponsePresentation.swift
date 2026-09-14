import Foundation
import MCP
import OSLog

/// Applies opt-in inline-text presentation after Agent Run/Explore has produced
/// its canonical response. Canonical snapshots and stored terminal text remain untouched.
enum AgentRunResponsePresentation {
    static let additionalWaitBudgetNanoseconds: UInt64 = 1_000_000_000
    static let presentationKey = "assistant_text_presentation"

    typealias CaptureDestination = @MainActor @Sendable () async throws -> OracleExportDestination
    typealias CanonicalOperation = @MainActor @Sendable (_ args: [String: Value]) async throws -> Value

    private enum CapturedDestination: @unchecked Sendable {
        case available(OracleExportDestination)
        case unavailable(String)
    }

    private enum Location: Hashable {
        case primary
        case nested(Int)
    }

    private struct ExportIdentity: Hashable {
        let sessionID: String?
        let utf8Content: Data
        let fallbackOrdinal: Int?
    }

    private struct Candidate {
        enum Kind: Equatable {
            case running
            case actionable
            case terminal
        }

        let location: Location
        let kind: Kind
        let text: String
        let exportIndex: Int?
    }

    @MainActor
    static func execute(
        args: [String: Value],
        exporter: AgentRunResponseExportAdapter,
        captureDestination: @escaping CaptureDestination,
        canonicalOperation: CanonicalOperation
    ) async throws -> Value {
        let mode = try parseMode(args["response_mode"])
        var canonicalArgs = args
        canonicalArgs.removeValue(forKey: "response_mode")

        guard mode != .full else {
            return try await canonicalOperation(canonicalArgs)
        }

        let captureStartedAt = exporter.nowNanoseconds()
        let captureDeadline = exporter.deadline(
            after: exporter.budgetNanoseconds,
            from: captureStartedAt
        )
        let capturedDestination = try await exporter.performOwned(
            deadline: captureDeadline,
            discard: { (_: CapturedDestination) in },
            inheritTaskLocals: true
        ) {
            do {
                return try await .available(captureDestination())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .unavailable(String(describing: error))
            }
        } ?? .unavailable(
            "Capturing the request-bound export authorization exceeded the one-second response presentation budget."
        )
        let captureFinishedAt = exporter.nowNanoseconds()
        let captureElapsed = exporter.elapsed(
            from: captureStartedAt,
            to: captureFinishedAt
        )
        let remainingBudget = captureElapsed >= exporter.budgetNanoseconds
            ? 0
            : exporter.budgetNanoseconds - captureElapsed

        let canonicalValue = try await canonicalOperation(canonicalArgs)
        guard remainingBudget > 0 else {
            return responseWideFallback(
                canonicalValue,
                warning: "Agent result presentation did not finish within the one-second response presentation budget; returning the full assistant text inline."
            )
        }

        let presentationDeadline = exporter.deadline(
            after: remainingBudget,
            from: exporter.nowNanoseconds()
        )
        let presented = try await exporter.performOwned(
            deadline: presentationDeadline,
            discard: { output in
                exporter.scheduleCleanup(output.artifacts)
            }
        ) {
            try await exporter.beforePrepare()
            return try await present(
                canonicalValue,
                mode: mode,
                capturedDestination: capturedDestination,
                exporter: exporter,
                deadline: presentationDeadline
            )
        }
        guard let presented else {
            return responseWideFallback(
                canonicalValue,
                warning: "Agent result presentation did not finish within the one-second response presentation budget; returning the full assistant text inline."
            )
        }
        return presented.value
    }

    static func parseMode(_ value: Value?) throws -> OracleResponseMode {
        if let value, value.stringValue == nil {
            throw MCPError.invalidParams("response_mode must be a string")
        }
        return try OracleResponseMode.parse(value?.stringValue)
    }

    private static func present(
        _ value: Value,
        mode: OracleResponseMode,
        capturedDestination: CapturedDestination?,
        exporter: AgentRunResponseExportAdapter,
        deadline: UInt64
    ) async throws -> AgentRunResponsePresentedValue {
        guard var root = value.objectValue else {
            return AgentRunResponsePresentedValue(value: value, artifacts: [])
        }

        var rawCandidates: [(location: Location, kind: Candidate.Kind, text: String)] = []
        if let candidate = candidate(in: root) {
            rawCandidates.append((.primary, candidate.kind, candidate.text))
        }
        if let snapshots = root["snapshots"]?.arrayValue {
            for (index, snapshot) in snapshots.enumerated() {
                guard let object = snapshot.objectValue,
                      let candidate = candidate(in: object)
                else { continue }
                rawCandidates.append((.nested(index), candidate.kind, candidate.text))
            }
        }
        guard !rawCandidates.isEmpty else {
            return AgentRunResponsePresentedValue(value: value, artifacts: [])
        }

        var exportRequests: [AgentRunResponseExportRequest] = []
        var exportIndexByIdentity: [ExportIdentity: Int] = [:]
        var candidates: [Candidate] = []
        candidates.reserveCapacity(rawCandidates.count)

        for (ordinal, raw) in rawCandidates.enumerated() {
            guard raw.kind == .terminal else {
                candidates.append(Candidate(
                    location: raw.location,
                    kind: raw.kind,
                    text: raw.text,
                    exportIndex: nil
                ))
                continue
            }

            let sessionID = object(at: raw.location, in: root)?["session_id"]?.stringValue
            let identity = ExportIdentity(
                sessionID: sessionID,
                utf8Content: Data(raw.text.utf8),
                fallbackOrdinal: sessionID == nil ? ordinal : nil
            )
            let exportIndex: Int
            if let existing = exportIndexByIdentity[identity] {
                exportIndex = existing
            } else {
                exportIndex = exportRequests.count
                exportIndexByIdentity[identity] = exportIndex
                exportRequests.append(AgentRunResponseExportRequest(
                    index: exportIndex,
                    sessionID: sessionID,
                    content: raw.text
                ))
            }
            candidates.append(Candidate(
                location: raw.location,
                kind: raw.kind,
                text: raw.text,
                exportIndex: exportIndex
            ))
        }

        let outcomes: [Int: AgentRunResponseExportOutcome]
        let unavailableReason: String?
        switch capturedDestination {
        case let .available(destination):
            outcomes = try await exporter.export(
                exportRequests,
                destination: destination,
                deadline: deadline
            )
            unavailableReason = nil
        case let .unavailable(reason):
            outcomes = [:]
            unavailableReason = reason
        case nil:
            outcomes = [:]
            unavailableReason = "No request-bound export authorization was captured."
        }

        for candidate in candidates {
            mutateObject(at: candidate.location, in: &root) { object in
                switch candidate.kind {
                case .running:
                    object.removeValue(forKey: "assistant_text")
                    mergePresentation(
                        into: &object,
                        values: [
                            "response_mode": .string(OracleResponseMode.none.rawValue),
                            "reason": .string("non_actionable_running")
                        ]
                    )
                case .actionable:
                    mergePresentation(
                        into: &object,
                        values: [
                            "response_mode": .string(OracleResponseMode.full.rawValue),
                            "safety_override": .string("actionable_context_preserved")
                        ]
                    )
                case .terminal:
                    guard let exportIndex = candidate.exportIndex else { return }
                    switch outcomes[exportIndex] {
                    case let .success(artifact):
                        let exportFile = artifact.file
                        let effectiveMode: OracleResponseMode =
                            mode == .tail && candidate.location == .primary ? .tail : .none
                        if effectiveMode == .tail {
                            let excerpt = OracleResponsePresentation.characterTail(
                                candidate.text,
                                budget: OracleResponseMode.tailExcerptCharacterBudget
                            )
                            object["assistant_text"] = .string(excerpt)
                            mergePresentation(
                                into: &object,
                                values: successfulPresentation(
                                    exportFile: exportFile,
                                    text: candidate.text,
                                    effectiveMode: effectiveMode,
                                    excerpt: excerpt
                                )
                            )
                        } else {
                            object.removeValue(forKey: "assistant_text")
                            mergePresentation(
                                into: &object,
                                values: successfulPresentation(
                                    exportFile: exportFile,
                                    text: candidate.text,
                                    effectiveMode: effectiveMode,
                                    excerpt: nil
                                )
                            )
                        }
                    case let .failure(message):
                        applyFullFallback(to: &object, warning: message)
                    case nil:
                        let warning = unavailableReason.map {
                            "Agent result export authorization was unavailable before execution; returning the full assistant text inline. \($0)"
                        } ?? "Agent result export did not finish within the one-second response presentation budget; returning the full assistant text inline."
                        applyFullFallback(to: &object, warning: warning)
                    }
                }
            }
        }

        let artifacts = outcomes.values.compactMap { outcome -> AgentRunResponseWrittenArtifact? in
            guard case let .success(artifact) = outcome else { return nil }
            return artifact
        }
        return AgentRunResponsePresentedValue(value: .object(root), artifacts: artifacts)
    }

    private static func responseWideFallback(
        _ value: Value,
        warning: String
    ) -> Value {
        guard var root = value.objectValue else { return value }
        applyFullFallback(to: &root, warning: warning)
        return .object(root)
    }

    private static func candidate(
        in object: [String: Value]
    ) -> (kind: Candidate.Kind, text: String)? {
        guard let text = object["assistant_text"]?.stringValue, !text.isEmpty,
              let statusRaw = object["status"]?.stringValue,
              let status = AgentRunMCPSnapshot.Status(rawValue: statusRaw)
        else { return nil }

        if status == .waitingForInput || object["interaction"] != nil {
            return (.actionable, text)
        }
        if status.isTerminal {
            return (.terminal, text)
        }
        if status == .running {
            return (.running, text)
        }
        return nil
    }

    private static func object(
        at location: Location,
        in root: [String: Value]
    ) -> [String: Value]? {
        switch location {
        case .primary:
            return root
        case let .nested(index):
            guard let snapshots = root["snapshots"]?.arrayValue,
                  snapshots.indices.contains(index)
            else { return nil }
            return snapshots[index].objectValue
        }
    }

    private static func mutateObject(
        at location: Location,
        in root: inout [String: Value],
        mutation: (inout [String: Value]) -> Void
    ) {
        switch location {
        case .primary:
            mutation(&root)
        case let .nested(index):
            guard var snapshots = root["snapshots"]?.arrayValue,
                  snapshots.indices.contains(index),
                  var object = snapshots[index].objectValue
            else { return }
            mutation(&object)
            snapshots[index] = .object(object)
            root["snapshots"] = .array(snapshots)
        }
    }

    private static func successfulPresentation(
        exportFile: OracleExportFile,
        text: String,
        effectiveMode: OracleResponseMode,
        excerpt: String?
    ) -> [String: Value] {
        var values: [String: Value] = [
            "response_mode": .string(effectiveMode.rawValue),
            "export_path": .string(exportFile.path),
            "retrieval_instruction": .string(exportFile.instruction),
            "character_count": .int(text.count),
            "line_count": .int(OracleResponsePresentation.lineCount(of: text))
        ]
        if let excerpt {
            values["excerpt_character_count"] = .int(excerpt.count)
            values["excerpt_line_count"] = .int(
                OracleResponsePresentation.lineCount(of: excerpt)
            )
        }
        return values
    }

    private static func applyFullFallback(
        to object: inout [String: Value],
        warning: String
    ) {
        mergePresentation(
            into: &object,
            values: [
                "response_mode": .string(OracleResponseMode.full.rawValue),
                "export_warning": .string(warning)
            ]
        )
    }

    private static func mergePresentation(
        into object: inout [String: Value],
        values: [String: Value]
    ) {
        var presentation = object[presentationKey]?.objectValue ?? [:]
        for (key, value) in values {
            presentation[key] = value
        }
        object[presentationKey] = .object(presentation)
    }

    static func retrievalInstruction(path: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let literal = (try? encoder.encode(path))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\(path)\""
        return "Read the complete assistant result with `read_file` using {\"path\": \(literal)}. Use this exact absolute path value verbatim."
    }
}

struct AgentRunResponseExportRequest {
    let index: Int
    let sessionID: String?
    let content: String
}

struct AgentRunResponseWrittenArtifact: @unchecked Sendable {
    let file: OracleExportFile
    let cleanup: @Sendable () async -> Bool
}

struct AgentRunResponsePresentedValue: @unchecked Sendable {
    let value: Value
    let artifacts: [AgentRunResponseWrittenArtifact]
}

enum AgentRunResponseExportOutcome {
    case success(AgentRunResponseWrittenArtifact)
    case failure(String)
}

/// Owns capture, response preparation, export, and cleanup tasks until every
/// scheduled operation either publishes before its absolute deadline or drains.
struct AgentRunResponseExportAdapter {
    typealias Sleep = @Sendable (_ nanoseconds: UInt64) async throws -> Void
    typealias Now = @Sendable () -> UInt64
    typealias Write = @Sendable (
        _ path: String,
        _ content: String,
        _ destination: OracleExportDestination
    ) async throws -> String
    typealias Remove = @Sendable (
        _ path: String,
        _ destination: OracleExportDestination
    ) async -> Void
    private typealias WriteArtifact = @Sendable (
        _ path: String,
        _ content: String,
        _ destination: OracleExportDestination
    ) async throws -> AgentRunResponseWrittenArtifact

    let budgetNanoseconds: UInt64
    private let sleep: Sleep
    private let now: Now
    private let preparationHook: @Sendable () async throws -> Void
    private let outcomePublished: @Sendable (Int) -> Void
    private let writeArtifact: WriteArtifact
    private let taskOwner = AgentRunResponseExportTaskOwner()

    init(
        store: WorkspaceFileContextStore,
        budgetNanoseconds: UInt64 = AgentRunResponsePresentation.additionalWaitBudgetNanoseconds,
        sleep: @escaping Sleep = { nanoseconds in
            try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping Now = { DispatchTime.now().uptimeNanoseconds },
        afterWrite: @escaping @Sendable () async -> Void = {}
    ) {
        let writer = GeneratedOracleExportFileWriter(store: store)
        self.init(
            budgetNanoseconds: budgetNanoseconds,
            sleep: sleep,
            now: now,
            preparationHook: {},
            outcomePublished: { _ in },
            writeArtifact: { path, content, destination in
                let receipt = try await writer.writeArtifact(
                    path: path,
                    content: content,
                    destination: destination
                )
                await afterWrite()
                let file = OracleExportFile(
                    path: receipt.logicalPath,
                    instruction: AgentRunResponsePresentation.retrievalInstruction(
                        path: receipt.logicalPath
                    )
                )
                return AgentRunResponseWrittenArtifact(
                    file: file,
                    cleanup: {
                        await writer.remove(receipt: receipt)
                    }
                )
            }
        )
    }

    init(
        budgetNanoseconds: UInt64,
        sleep: @escaping Sleep,
        now: @escaping Now = { DispatchTime.now().uptimeNanoseconds },
        beforePrepare: @escaping @Sendable () async throws -> Void = {},
        didPublish: @escaping @Sendable (Int) -> Void = { _ in },
        write: @escaping Write,
        remove: @escaping Remove
    ) {
        self.init(
            budgetNanoseconds: budgetNanoseconds,
            sleep: sleep,
            now: now,
            preparationHook: beforePrepare,
            outcomePublished: didPublish,
            writeArtifact: { path, content, destination in
                let resolvedPath = try await write(path, content, destination)
                let file = OracleExportFile(
                    path: resolvedPath,
                    instruction: AgentRunResponsePresentation.retrievalInstruction(
                        path: resolvedPath
                    )
                )
                return AgentRunResponseWrittenArtifact(
                    file: file,
                    cleanup: {
                        await remove(resolvedPath, destination)
                        return true
                    }
                )
            }
        )
    }

    private init(
        budgetNanoseconds: UInt64,
        sleep: @escaping Sleep,
        now: @escaping Now,
        preparationHook: @escaping @Sendable () async throws -> Void,
        outcomePublished: @escaping @Sendable (Int) -> Void,
        writeArtifact: @escaping WriteArtifact
    ) {
        self.budgetNanoseconds = budgetNanoseconds
        self.sleep = sleep
        self.now = now
        self.preparationHook = preparationHook
        self.outcomePublished = outcomePublished
        self.writeArtifact = writeArtifact
    }

    func nowNanoseconds() -> UInt64 {
        now()
    }

    func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    func deadline(after duration: UInt64, from start: UInt64) -> UInt64 {
        let (value, overflow) = start.addingReportingOverflow(duration)
        return overflow ? UInt64.max : value
    }

    func beforePrepare() async throws {
        try await preparationHook()
    }

    func performOwned<Output: Sendable>(
        deadline: UInt64,
        discard: @escaping @Sendable (Output) -> Void,
        inheritTaskLocals: Bool = false,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output? {
        let state = AgentRunResponseOwnedOperationState(
            deadline: deadline,
            now: now,
            sleep: sleep,
            discard: discard
        )
        state.armDeadline()
        let ownedOperation: @Sendable () async -> Void = {
            do {
                try await state.publish(.success(operation()))
            } catch {
                state.publish(.failure(error))
            }
        }
        if inheritTaskLocals {
            taskOwner.startInheritingTaskLocals(id: UUID(), operation: ownedOperation)
        } else {
            taskOwner.start(id: UUID(), operation: ownedOperation)
        }
        return try await state.wait()
    }

    func export(
        _ requests: [AgentRunResponseExportRequest],
        destination: OracleExportDestination
    ) async throws -> [Int: AgentRunResponseExportOutcome] {
        try await export(
            requests,
            destination: destination,
            deadline: deadline(after: budgetNanoseconds, from: now())
        )
    }

    func export(
        _ requests: [AgentRunResponseExportRequest],
        destination: OracleExportDestination,
        deadline: UInt64
    ) async throws -> [Int: AgentRunResponseExportOutcome] {
        guard !requests.isEmpty, now() < deadline else { return [:] }

        let batch = AgentRunResponseExportBatchState(
            expectedCount: requests.count,
            deadline: deadline,
            now: now,
            sleep: sleep,
            discard: { outcome in
                guard case let .success(artifact) = outcome else { return }
                taskOwner.scheduleCleanup([artifact])
            }
        )
        batch.armDeadline()

        for request in requests {
            taskOwner.start(id: UUID()) {
                let path = Self.exportPath(
                    sessionID: request.sessionID,
                    destination: destination
                )
                let outcome: AgentRunResponseExportOutcome
                do {
                    outcome = try await .success(writeArtifact(
                        path,
                        request.content,
                        destination
                    ))
                } catch {
                    outcome = .failure(
                        "Agent result export failed after the run completed; returning the full assistant text inline. \(String(describing: error))"
                    )
                }
                batch.publish(outcome, for: request.index)
                outcomePublished(request.index)
            }
        }

        return try await batch.wait()
    }

    func scheduleCleanup(_ artifacts: [AgentRunResponseWrittenArtifact]) {
        taskOwner.scheduleCleanup(artifacts)
    }

    #if DEBUG
        func testActiveTaskCount() -> Int {
            taskOwner.activeTaskCount
        }

        func testCleanupFailureCount() -> Int {
            taskOwner.cleanupFailureCount
        }

        func testWaitUntilIdle() async {
            await taskOwner.waitUntilIdle()
        }
    #endif

    private static func exportPath(
        sessionID: String?,
        destination: OracleExportDestination
    ) -> String {
        let rawSession = sessionID?.lowercased() ?? "session"
        let sessionSlug = rawSession.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let boundedSlug = String((sessionSlug.isEmpty ? "session" : sessionSlug).prefix(12))
        let nonce = UUID().uuidString.prefix(8).lowercased()
        return URL(fileURLWithPath: destination.primaryRootPath, isDirectory: true)
            .appendingPathComponent("prompt-exports", isDirectory: true)
            .appendingPathComponent("agent-run-\(boundedSlug)-\(nonce).md")
            .path
    }
}

private final class AgentRunResponseExportTaskOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(
        subsystem: "com.repoprompt.mcp",
        category: "AgentRunResponseExport"
    )
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCleanupFailureCount = 0

    var activeTaskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    var cleanupFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCleanupFailureCount
    }

    func start(
        id: UUID,
        operation: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        let task = Task.detached { [self] in
            await operation()
            finish(id: id)
        }
        tasks[id] = task
        lock.unlock()
    }

    func startInheritingTaskLocals(
        id: UUID,
        operation: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        let task = Task { [self] in
            await operation()
            finish(id: id)
        }
        tasks[id] = task
        lock.unlock()
    }

    func scheduleCleanup(_ artifacts: [AgentRunResponseWrittenArtifact]) {
        for artifact in artifacts {
            start(id: UUID()) { [self] in
                guard await !artifact.cleanup() else { return }
                recordCleanupFailure(path: artifact.file.path)
            }
        }
    }

    private func recordCleanupFailure(path: String) {
        lock.lock()
        recordedCleanupFailureCount += 1
        lock.unlock()
        log.error(
            "Generated agent response export cleanup failed for \(path, privacy: .public)"
        )
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if tasks.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finish(id: UUID) {
        lock.lock()
        tasks.removeValue(forKey: id)
        let waiters = tasks.isEmpty ? idleWaiters : []
        if tasks.isEmpty {
            idleWaiters.removeAll()
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class AgentRunResponseExportBatchState: @unchecked Sendable {
    private enum State {
        case collecting
        case ready
        case timedOutReady
        case delivered
        case cancelled
    }

    private let lock = NSLock()
    private let expectedCount: Int
    private let deadline: UInt64
    private let now: AgentRunResponseExportAdapter.Now
    private let sleep: AgentRunResponseExportAdapter.Sleep
    private let discard: @Sendable (AgentRunResponseExportOutcome) -> Void
    private var state: State = .collecting
    private var outcomes: [Int: AgentRunResponseExportOutcome] = [:]
    private var waiter: CheckedContinuation<[Int: AgentRunResponseExportOutcome], Error>?
    private var deadlineTask: Task<Void, Never>?

    init(
        expectedCount: Int,
        deadline: UInt64,
        now: @escaping AgentRunResponseExportAdapter.Now,
        sleep: @escaping AgentRunResponseExportAdapter.Sleep,
        discard: @escaping @Sendable (AgentRunResponseExportOutcome) -> Void
    ) {
        self.expectedCount = expectedCount
        self.deadline = deadline
        self.now = now
        self.sleep = sleep
        self.discard = discard
    }

    func armDeadline() {
        lock.lock()
        guard state == .collecting, deadlineTask == nil else {
            lock.unlock()
            return
        }
        let task = Task.detached { [self] in
            while !Task.isCancelled {
                let currentTime = now()
                if currentTime >= deadline {
                    timeOut()
                    return
                }
                do {
                    try await sleep(deadline - currentTime)
                } catch {
                    return
                }
            }
        }
        deadlineTask = task
        lock.unlock()
    }

    func wait() async throws -> [Int: AgentRunResponseExportOutcome] {
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                switch state {
                case .collecting:
                    waiter = continuation
                    lock.unlock()
                case .ready, .timedOutReady:
                    let currentOutcomes = outcomes
                    lock.unlock()
                    continuation.resume(returning: currentOutcomes)
                case .cancelled:
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                case .delivered:
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }

        do {
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
        guard claimReadyResult() else {
            throw CancellationError()
        }
        return result
    }

    func publish(
        _ outcome: AgentRunResponseExportOutcome,
        for index: Int
    ) {
        lock.lock()
        guard state == .collecting else {
            lock.unlock()
            discard(outcome)
            return
        }

        guard now() < deadline else {
            state = .timedOutReady
            let currentOutcomes = outcomes
            let continuation = waiter
            waiter = nil
            let timer = deadlineTask
            deadlineTask = nil
            lock.unlock()

            timer?.cancel()
            continuation?.resume(returning: currentOutcomes)
            discard(outcome)
            return
        }

        outcomes[index] = outcome
        guard outcomes.count == expectedCount else {
            lock.unlock()
            return
        }

        state = .ready
        let currentOutcomes = outcomes
        let continuation = waiter
        waiter = nil
        let timer = deadlineTask
        deadlineTask = nil
        lock.unlock()

        timer?.cancel()
        continuation?.resume(returning: currentOutcomes)
    }

    private func timeOut() {
        lock.lock()
        guard state == .collecting else {
            lock.unlock()
            return
        }

        state = .timedOutReady
        let currentOutcomes = outcomes
        let continuation = waiter
        waiter = nil
        deadlineTask = nil
        lock.unlock()

        continuation?.resume(returning: currentOutcomes)
    }

    private func claimReadyResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready || state == .timedOutReady else { return false }
        state = .delivered
        return true
    }

    private func cancel() {
        lock.lock()
        guard state == .collecting || state == .ready || state == .timedOutReady else {
            lock.unlock()
            return
        }

        state = .cancelled
        let discardedOutcomes = Array(outcomes.values)
        outcomes.removeAll()
        let continuation = waiter
        waiter = nil
        let timer = deadlineTask
        deadlineTask = nil
        lock.unlock()

        timer?.cancel()
        for outcome in discardedOutcomes {
            discard(outcome)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class AgentRunResponseOwnedOperationState<Output: Sendable>: @unchecked Sendable {
    private enum State {
        case collecting
        case ready
        case delivered
        case timedOut
        case cancelled
        case failed
    }

    private let lock = NSLock()
    private let deadline: UInt64
    private let now: AgentRunResponseExportAdapter.Now
    private let sleep: AgentRunResponseExportAdapter.Sleep
    private let discard: @Sendable (Output) -> Void
    private var state: State = .collecting
    private var output: Output?
    private var failure: Error?
    private var waiter: CheckedContinuation<Output?, Error>?
    private var deadlineTask: Task<Void, Never>?

    init(
        deadline: UInt64,
        now: @escaping AgentRunResponseExportAdapter.Now,
        sleep: @escaping AgentRunResponseExportAdapter.Sleep,
        discard: @escaping @Sendable (Output) -> Void
    ) {
        self.deadline = deadline
        self.now = now
        self.sleep = sleep
        self.discard = discard
    }

    func armDeadline() {
        lock.lock()
        guard state == .collecting, deadlineTask == nil else {
            lock.unlock()
            return
        }
        let task = Task.detached { [self] in
            while !Task.isCancelled {
                let currentTime = now()
                if currentTime >= deadline {
                    timeOut()
                    return
                }
                do {
                    try await sleep(deadline - currentTime)
                } catch {
                    return
                }
            }
        }
        deadlineTask = task
        lock.unlock()
    }

    func publish(_ result: Result<Output, Error>) {
        lock.lock()
        guard state == .collecting else {
            lock.unlock()
            if case let .success(output) = result {
                discard(output)
            }
            return
        }

        guard now() < deadline else {
            state = .timedOut
            let continuation = waiter
            waiter = nil
            let timer = deadlineTask
            deadlineTask = nil
            lock.unlock()

            timer?.cancel()
            continuation?.resume(returning: nil)
            if case let .success(output) = result {
                discard(output)
            }
            return
        }

        let continuation = waiter
        waiter = nil
        let timer = deadlineTask
        deadlineTask = nil
        switch result {
        case let .success(output):
            state = .ready
            self.output = output
            lock.unlock()
            timer?.cancel()
            continuation?.resume(returning: output)
        case let .failure(error):
            state = .failed
            failure = error
            lock.unlock()
            timer?.cancel()
            continuation?.resume(throwing: error)
        }
    }

    func wait() async throws -> Output? {
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                switch state {
                case .collecting:
                    waiter = continuation
                    lock.unlock()
                case .ready:
                    let output = output
                    lock.unlock()
                    continuation.resume(returning: output)
                case .timedOut:
                    lock.unlock()
                    continuation.resume(returning: nil)
                case .cancelled, .delivered:
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    let failure = failure ?? CancellationError()
                    lock.unlock()
                    continuation.resume(throwing: failure)
                }
            }
        } onCancel: {
            cancel()
        }

        do {
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
        if result != nil, !claimReadyResult() {
            throw CancellationError()
        }
        return result
    }

    private func timeOut() {
        lock.lock()
        guard state == .collecting else {
            lock.unlock()
            return
        }
        state = .timedOut
        let continuation = waiter
        waiter = nil
        deadlineTask = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private func claimReadyResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready else { return false }
        state = .delivered
        output = nil
        return true
    }

    private func cancel() {
        lock.lock()
        guard state == .collecting || state == .ready else {
            lock.unlock()
            return
        }
        state = .cancelled
        let discardedOutput = output
        output = nil
        let continuation = waiter
        waiter = nil
        let timer = deadlineTask
        deadlineTask = nil
        lock.unlock()

        timer?.cancel()
        if let discardedOutput {
            discard(discardedOutput)
        }
        continuation?.resume(throwing: CancellationError())
    }
}
