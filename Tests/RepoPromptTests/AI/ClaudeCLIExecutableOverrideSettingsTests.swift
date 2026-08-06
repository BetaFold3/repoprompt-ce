import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ClaudeCLIExecutableOverrideSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "ClaudeCLIExecutableOverrideSettingsTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIExecutableOverrideSettingsTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        suiteName = nil
        root = nil
    }

    func testStaleInFlightProbeIsDiscardedAndMatchingFreshProbeIsDisplayed() async throws {
        let firstExecutable = try makeExecutable(named: "claude-a")
        let secondExecutable = try makeExecutable(named: "claude-b")
        defaults.set(
            firstExecutable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )

        let gate = ClaudeProbeGate(blockedCommand: firstExecutable.path)
        let viewModel = makeSettingsViewModel(
            probe: { config, _ in
                await gate.run(command: config.command)
            },
            invalidator: {}
        )

        let staleProbe = Task {
            await viewModel.refreshClaudeCodeBinaryStatus(timeout: 2, forceProbe: true)
        }
        await gate.waitUntilBlockedProbeStarted()

        viewModel.updateClaudeExecutableOverrideDraft(secondExecutable.path)
        let applySucceeded = await viewModel.applyClaudeExecutableOverride()
        XCTAssertTrue(applySucceeded)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(
                resolvedCommand: secondExecutable.path,
                version: "fresh version"
            )
        )

        await gate.finishBlockedProbe(
            with: .succeeded(
                resolvedCommand: firstExecutable.path,
                version: "stale version"
            )
        )
        let staleProbeSucceeded = await staleProbe.value
        XCTAssertTrue(staleProbeSucceeded)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(
                resolvedCommand: secondExecutable.path,
                version: "fresh version"
            )
        )
    }

    func testOlderForcedProbeForSameSelectionCannotOverwriteNewerResult() async throws {
        let executable = try makeExecutable(named: "configured-claude")
        defaults.set(
            executable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )
        let probeSequence = SameSelectionClaudeProbeSequence()
        let refreshGate = ClaudeFamilyModelAvailabilityRefreshGate()
        let viewModel = makeSettingsViewModel(
            probe: { config, _ in
                await probeSequence.run(command: config.command)
            },
            invalidator: {},
            modelAvailabilityRefreshBoundary: {
                await refreshGate.pauseFirstRefresh()
            }
        )

        let olderProbe = Task {
            await viewModel.refreshClaudeCodeBinaryStatus(timeout: 2, forceProbe: true)
        }
        await refreshGate.waitUntilFirstRefreshStarted()

        let newerProbeSucceeded = await viewModel.refreshClaudeCodeBinaryStatus(
            timeout: 2,
            forceProbe: true
        )
        XCTAssertFalse(newerProbeSucceeded)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .failed(message: "newer failure")
        )

        await refreshGate.finishFirstRefresh()
        let olderProbeSucceeded = await olderProbe.value
        XCTAssertFalse(olderProbeSucceeded)
        XCTAssertEqual(
            viewModel.claudeCodeCLIStatus,
            .binaryMissing(message: "newer failure")
        )
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .failed(message: "newer failure")
        )
    }

    func testLateOlderSameSelectionProbeOutcomeIsRejectedBeforePublication() async throws {
        let executable = try makeExecutable(named: "configured-claude")
        defaults.set(
            executable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )
        let probeGate = SameSelectionClaudeProbeOperationGate()
        let viewModel = makeSettingsViewModel(
            probe: { config, _ in
                await probeGate.run(command: config.command)
            },
            invalidator: {}
        )

        let olderProbe = Task {
            await viewModel.refreshClaudeCodeBinaryStatus(timeout: 2, forceProbe: true)
        }
        await probeGate.waitUntilFirstProbeStarted()

        let newerProbeSucceeded = await viewModel.refreshClaudeCodeBinaryStatus(
            timeout: 2,
            forceProbe: true
        )
        XCTAssertTrue(newerProbeSucceeded)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(resolvedCommand: executable.path, version: "newer success")
        )

        await probeGate.finishFirstProbe(with: .failed(message: "older failure"))
        let olderProbeSucceeded = await olderProbe.value
        XCTAssertTrue(olderProbeSucceeded)
        XCTAssertEqual(viewModel.claudeCodeCLIStatus, .binaryPresent)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(resolvedCommand: executable.path, version: "newer success")
        )
    }

    func testApplyAndResetPipelineOrderingIsObservable() async throws {
        let executable = try makeExecutable(named: "configured-claude")
        var stages: [ClaudeExecutableOverridePipelineStage] = []
        let viewModel = makeSettingsViewModel(
            probe: { config, _ in
                .succeeded(
                    resolvedCommand: config.command == "claude" ? "/automatic/claude" : config.command,
                    version: "fixture version"
                )
            },
            invalidator: {},
            pipelineObserver: { stages.append($0) }
        )

        viewModel.updateClaudeExecutableOverrideDraft(executable.path)
        let applySucceeded = await viewModel.applyClaudeExecutableOverride()
        XCTAssertTrue(applySucceeded)
        XCTAssertEqual(
            stages,
            [
                .validate,
                .persist,
                .invalidateResolvedCommandCache,
                .clearProbeFingerprint,
                .probe
            ]
        )
        XCTAssertEqual(
            defaults.object(forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)) as? String,
            executable.path
        )

        stages.removeAll()
        let resetSucceeded = await viewModel.resetClaudeExecutableOverrideToAutomatic()
        XCTAssertTrue(resetSucceeded)
        XCTAssertEqual(
            stages,
            [
                .validate,
                .persist,
                .invalidateResolvedCommandCache,
                .clearProbeFingerprint,
                .probe
            ]
        )
        XCTAssertNil(
            defaults.object(forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))
        )
        XCTAssertEqual(viewModel.claudeExecutableOverrideAppliedState, .automatic)
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(resolvedCommand: "/automatic/claude", version: "fixture version")
        )
    }

    func testInvalidSavePreservesAppliedValueAndRapidDraftEditsCannotPublishStaleValidation() async throws {
        let appliedExecutable = try makeExecutable(named: "applied-claude")
        let invalidExecutable = root.appendingPathComponent("not-executable")
        try "fixture".write(to: invalidExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: invalidExecutable.path
        )
        defaults.set(
            appliedExecutable.path,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )

        let slowDraft = root.appendingPathComponent("slow-draft").path
        let validationGate = DraftValidationGate()
        let viewModel = makeSettingsViewModel(
            draftValidator: { input in
                if input == slowDraft {
                    return await validationGate.validateSlowDraft()
                }
                let assessment = Self.assessDraft(input)
                await validationGate.markFreshDraftValidated(input)
                return assessment
            },
            probe: { config, _ in
                .succeeded(resolvedCommand: config.command, version: "fixture version")
            },
            invalidator: {}
        )

        viewModel.updateClaudeExecutableOverrideDraft(invalidExecutable.path)
        let invalidApplySucceeded = await viewModel.applyClaudeExecutableOverride()
        XCTAssertFalse(invalidApplySucceeded)
        XCTAssertEqual(
            defaults.object(forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)) as? String,
            appliedExecutable.path
        )
        XCTAssertEqual(
            viewModel.claudeExecutableOverrideAppliedState.appliedPath,
            appliedExecutable.path
        )
        guard case let .invalid(message) = viewModel.claudeExecutableOverrideDraftValidation else {
            return XCTFail("Expected loud invalid-draft state")
        }
        XCTAssertTrue(message.hasPrefix(CLIExecutableOverrideError.messagePrefix))

        viewModel.updateClaudeExecutableOverrideDraft(slowDraft)
        await validationGate.waitUntilSlowDraftStarted()
        viewModel.updateClaudeExecutableOverrideDraft(appliedExecutable.path)
        await validationGate.waitUntilFreshDraftValidated(appliedExecutable.path)
        XCTAssertEqual(viewModel.claudeExecutableOverrideDraftValidation, .valid)

        await validationGate.finishSlowDraft(
            with: ClaudeExecutableDraftAssessment(
                validation: .invalid(message: "stale validation"),
                normalizedPath: nil,
                isQuarantined: false
            )
        )
        await Task.yield()
        XCTAssertEqual(viewModel.claudeExecutableOverrideDraft, appliedExecutable.path)
        XCTAssertEqual(viewModel.claudeExecutableOverrideDraftValidation, .valid)
    }

    func testCorruptStoredValueIsVisibleAndResetRestoresAutomatic() async {
        defaults.set(
            true,
            forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode)
        )
        let viewModel = makeSettingsViewModel(
            probe: { config, _ in
                .succeeded(resolvedCommand: "/automatic/" + config.command, version: "automatic version")
            },
            invalidator: {}
        )

        guard case let .corrupt(message) = viewModel.claudeExecutableOverrideAppliedState else {
            return XCTFail("Expected visible corrupt stored-value state")
        }
        XCTAssertTrue(message.hasPrefix(CLIExecutableOverrideError.messagePrefix))

        let resetSucceeded = await viewModel.resetClaudeExecutableOverrideToAutomatic()
        XCTAssertTrue(resetSucceeded)
        XCTAssertEqual(viewModel.claudeExecutableOverrideAppliedState, .automatic)
        XCTAssertNil(
            defaults.object(forKey: CLIExecutableOverrideStore.key(for: CLILaunchProfiles.claudeCode))
        )
        XCTAssertEqual(
            viewModel.displayedClaudeExecutableProbeStatus,
            .succeeded(resolvedCommand: "/automatic/claude", version: "automatic version")
        )
    }

    private func makeSettingsViewModel(
        draftValidator: ((String) async -> ClaudeExecutableDraftAssessment)? = nil,
        probe: ((CLIProcessConfiguration, TimeInterval) async -> ClaudeExecutableProbeOutcome)? = nil,
        invalidator: (() async -> Void)? = nil,
        pipelineObserver: ((ClaudeExecutableOverridePipelineStage) -> Void)? = nil,
        modelAvailabilityRefreshBoundary: (@MainActor @Sendable () async -> Void)? = nil
    ) -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            cliExecutableOverrideDefaults: defaults,
            claudeExecutableDraftValidator: draftValidator,
            claudeExecutableProbeOperation: probe,
            cliResolvedCommandCacheInvalidator: invalidator,
            claudeExecutableOverridePipelineObserver: pipelineObserver,
            claudeFamilyModelAvailabilityRefreshBoundary: modelAvailabilityRefreshBoundary
        )
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\nprintf 'fixture version\\n'\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func assessDraft(_ input: String) -> ClaudeExecutableDraftAssessment {
        do {
            guard let normalized = try CLIExecutableOverrideStore.normalizeForApply(input) else {
                return ClaudeExecutableDraftAssessment(
                    validation: .valid,
                    normalizedPath: nil,
                    isQuarantined: false
                )
            }
            try CLIExecutableOverrideStore.validateForLaunch(
                normalized,
                commandName: CLILaunchProfiles.claudeCode.commandName
            )
            return ClaudeExecutableDraftAssessment(
                validation: .valid,
                normalizedPath: normalized,
                isQuarantined: false
            )
        } catch {
            return ClaudeExecutableDraftAssessment(
                validation: .invalid(message: error.localizedDescription),
                normalizedPath: nil,
                isQuarantined: false
            )
        }
    }
}

private actor ClaudeProbeGate {
    private let blockedCommand: String
    private var blockedProbeContinuation: CheckedContinuation<ClaudeExecutableProbeOutcome, Never>?
    private var blockedProbeStarted = false
    private var blockedProbeStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedCommand: String) {
        self.blockedCommand = blockedCommand
    }

    func run(command: String) async -> ClaudeExecutableProbeOutcome {
        guard command == blockedCommand else {
            return .succeeded(resolvedCommand: command, version: "fresh version")
        }

        return await withCheckedContinuation { continuation in
            blockedProbeContinuation = continuation
            blockedProbeStarted = true
            let waiters = blockedProbeStartWaiters
            blockedProbeStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilBlockedProbeStarted() async {
        guard !blockedProbeStarted else { return }
        await withCheckedContinuation { continuation in
            blockedProbeStartWaiters.append(continuation)
        }
    }

    func finishBlockedProbe(with outcome: ClaudeExecutableProbeOutcome) {
        blockedProbeContinuation?.resume(returning: outcome)
        blockedProbeContinuation = nil
    }
}

private actor SameSelectionClaudeProbeSequence {
    private var invocationCount = 0

    func run(command: String) -> ClaudeExecutableProbeOutcome {
        invocationCount += 1
        if invocationCount == 1 {
            return .succeeded(resolvedCommand: command, version: "older success")
        }
        return .failed(message: "newer failure")
    }
}

private actor SameSelectionClaudeProbeOperationGate {
    private var invocationCount = 0
    private var firstProbeContinuation: CheckedContinuation<ClaudeExecutableProbeOutcome, Never>?
    private var firstProbeStarted = false
    private var firstProbeStartWaiters: [CheckedContinuation<Void, Never>] = []

    func run(command: String) async -> ClaudeExecutableProbeOutcome {
        invocationCount += 1
        guard invocationCount == 1 else {
            return .succeeded(resolvedCommand: command, version: "newer success")
        }

        return await withCheckedContinuation { continuation in
            firstProbeContinuation = continuation
            firstProbeStarted = true
            let waiters = firstProbeStartWaiters
            firstProbeStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilFirstProbeStarted() async {
        guard !firstProbeStarted else { return }
        await withCheckedContinuation { continuation in
            firstProbeStartWaiters.append(continuation)
        }
    }

    func finishFirstProbe(with outcome: ClaudeExecutableProbeOutcome) {
        firstProbeContinuation?.resume(returning: outcome)
        firstProbeContinuation = nil
    }
}

private actor ClaudeFamilyModelAvailabilityRefreshGate {
    private var invocationCount = 0
    private var firstRefreshContinuation: CheckedContinuation<Void, Never>?
    private var firstRefreshStarted = false
    private var firstRefreshStartWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstRefresh() async {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstRefreshContinuation = continuation
            firstRefreshStarted = true
            let waiters = firstRefreshStartWaiters
            firstRefreshStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilFirstRefreshStarted() async {
        guard !firstRefreshStarted else { return }
        await withCheckedContinuation { continuation in
            firstRefreshStartWaiters.append(continuation)
        }
    }

    func finishFirstRefresh() {
        firstRefreshContinuation?.resume()
        firstRefreshContinuation = nil
    }
}

private actor DraftValidationGate {
    private var slowDraftContinuation: CheckedContinuation<ClaudeExecutableDraftAssessment, Never>?
    private var slowDraftStarted = false
    private var slowDraftStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var freshDrafts: Set<String> = []
    private var freshDraftWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func validateSlowDraft() async -> ClaudeExecutableDraftAssessment {
        await withCheckedContinuation { continuation in
            slowDraftContinuation = continuation
            slowDraftStarted = true
            let waiters = slowDraftStartWaiters
            slowDraftStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilSlowDraftStarted() async {
        guard !slowDraftStarted else { return }
        await withCheckedContinuation { continuation in
            slowDraftStartWaiters.append(continuation)
        }
    }

    func finishSlowDraft(with assessment: ClaudeExecutableDraftAssessment) {
        slowDraftContinuation?.resume(returning: assessment)
        slowDraftContinuation = nil
    }

    func markFreshDraftValidated(_ draft: String) {
        freshDrafts.insert(draft)
        let waiters = freshDraftWaiters.removeValue(forKey: draft) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFreshDraftValidated(_ draft: String) async {
        guard !freshDrafts.contains(draft) else { return }
        await withCheckedContinuation { continuation in
            freshDraftWaiters[draft, default: []].append(continuation)
        }
    }
}
