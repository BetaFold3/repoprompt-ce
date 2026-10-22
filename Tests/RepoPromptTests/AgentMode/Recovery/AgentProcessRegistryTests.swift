import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 runtime-ownership registry over a temporary recovery store and a scripted process
/// system: the coupled activation gate, reservation/commit/fence lifecycle, conservative family
/// discovery, exit watches, coalesced rediscovery, preserved records, Let finish, and the Stop
/// engine with injected actions. Nothing inspects, watches or signals a real process.
final class AgentProcessRegistryTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    private var root: URL!
    private var recoveryRoot: URL!
    private var failures: RecoveryStoreWriteFailureSwitch!
    private var processes: ScriptedProcessSystem!
    private var registries: [AgentProcessRegistry] = []

    override func setUpWithError() throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("AgentProcessRegistryTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        failures = RecoveryStoreWriteFailureSwitch()
        processes = ScriptedProcessSystem()
    }

    override func tearDown() async throws {
        for registry in registries {
            await registry.disposeWatches()
        }
        registries = []
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Fixtures

    private func makeStore() -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID(), fileOperations: failures.fileOperations())
    }

    private func makeRegistry(
        store: AgentRecoveryStore,
        qualification: AgentRuntimeQualification = AgentProcessRegistryFixtures.qualified(),
        stop: Bool = false
    ) -> AgentProcessRegistry {
        let registry = AgentProcessRegistry(
            store: store,
            qualification: qualification,
            system: processes.system,
            stopActions: stop ? processes.stopActions : nil
        )
        registries.append(registry)
        return registry
    }

    private func newLaunch(
        _ registry: AgentProcessRegistry,
        family: AgentRuntimeFamily = .claudeNative,
        provider: AgentRuntimeProvider? = nil,
        session: AgentRuntimeSessionScope = .sessionless,
        worktreePath: String? = "/tmp/rpce-wt",
        conversationID: String? = nil,
        permission: AgentRuntimePermissionSnapshot = .unavailable
    ) throws -> AgentRuntimeLaunch {
        try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(
            family,
            provider: provider,
            session: session,
            worktreePath: worktreePath,
            conversationID: conversationID,
            permission: permission
        )))
    }

    private func assertThrows(
        _ expected: AgentProcessRegistryError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, expected, file: file, line: line)
        }
    }

    private func signalNames() -> [String] {
        processes.sentSignals.map { sent in
            let name = sent.signal == SIGTERM ? "TERM" : sent.signal == SIGKILL ? "KILL" : "\(sent.signal)"
            return "\(sent.group):\(name)"
        }
    }

    // MARK: Activation gate

    func testProductionActivationStaysOffAndInactiveRegistryRefusesReservations() async {
        XCTAssertFalse(AgentRuntimeQualification.production.activatesRegistration)
        var partial = Fixtures.qualified(freshSessionID: true)
        partial.families[.acp] = nil
        XCTAssertFalse(partial.activatesRegistration, "one coupled activation: every managed family must qualify")
        XCTAssertFalse(partial.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)), "fresh --session-id is gated on activation")
        XCTAssertTrue(Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeCompatible, provider: .claude(.glm)))
        XCTAssertFalse(
            Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeNative, provider: .claude(.kimi)),
            "qualification is keyed to the actual provider, never the family alone"
        )
        XCTAssertFalse(Fixtures.qualified().allowsFreshSessionID(.claudeNative, provider: .claude(.standard)), "fresh --session-id is a separate gate")
        var emptyProviders = Fixtures.qualified()
        emptyProviders.families[.acp]?.providers = []
        XCTAssertFalse(emptyProviders.activatesRegistration, "a family qualified for no actual provider does not activate")

        XCTAssertNil(AgentProcessRegistry.production, "XCTest composes no production registry")
        guard case .activationOff = AgentRuntimeLaunchAuthority.production else {
            return XCTFail("Production launch authority must stay off")
        }
        XCTAssertNil(AgentRuntimeLaunchAuthority.activationOff.makeLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/x")))
        XCTAssertFalse(AgentRuntimeLaunchAuthority.activationOff.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))

        let registry = makeRegistry(store: makeStore(), qualification: .production)
        XCTAssertFalse(registry.isRegistrationActive)
        await registry.start()
        XCTAssertNil(
            AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/x")),
            "an inactive registry issues no launch owner (no shadow reservations)"
        )
        await assertThrows(.registrationInactive) {
            _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/x"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
        let stopEnabled = await registry.isStopEnabled
        XCTAssertFalse(stopEnabled, "production registries carry no Stop actions")
    }

    func testExistingRecordsAreEnforcedWhileRegistrationIsOff() async throws {
        processes.add(processes.observation(pid: 500, group: 500))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 500),
            rootGroup: 500,
            conversationIDs: ["conv-A"],
            worktreePaths: ["/tmp/wt-a"]
        )
        let registry = makeRegistry(store: makeStore(), qualification: .production)
        let snapshot = await registry.start()

        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID])
        let restriction = try XCTUnwrap(snapshot.restrictions.first)
        XCTAssertEqual(restriction.kind, .possibleWriter)
        XCTAssertEqual(restriction.state, .unknown, "an alive writer under unqualified discovery stays unresolved")
        XCTAssertTrue(restriction.isPreviousInstance)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: "/tmp/elsewhere")))
        XCTAssertFalse(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/wt-b")),
            "unrelated conversations continue"
        )
        XCTAssertFalse(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/wt-a")),
            "an associated writer blocks its own conversation, not other sends on the worktree"
        )
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-a/sub")))
        XCTAssertFalse(snapshot.hasGlobalUncertainty)
    }

    func testRootExitNeverProvesFamilyExitWithoutCompleteQualifiedDiscovery() async throws {
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 501),
            conversationIDs: ["conv-A"]
        )
        let unqualified = makeRegistry(store: makeStore(), qualification: .production)
        var snapshot = await unqualified.start()
        XCTAssertEqual(snapshot.restrictions.first?.state, .unknown, "root gone, family discovery unqualified")
        await unqualified.disposeWatches()

        processes.inventoryIsIncomplete = true
        let store = makeStore()
        let qualified = makeRegistry(store: store)
        snapshot = await qualified.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "root gone, inventory incomplete")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: nil)))

        processes.inventoryIsIncomplete = false
        await qualified.refresh()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .exited, "complete qualified discovery proves exit")
        snapshot = await qualified.restrictionSnapshot()
        XCTAssertTrue(snapshot.restrictions.isEmpty)
    }

    func testRootlessReservationStaysUnresolvedWithoutMarkerEvidence() async throws {
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, state: .reserved, root: nil, worktreePaths: ["/tmp/wt-r"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "an absent marker never proves exit")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-r")))
    }

    // MARK: Launch lifecycle

    func testFailedReservationWritesNothingAndTheLaunchCannotCommitOrRetry() async throws {
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        failures.shouldFailWrites = true
        let launch = try newLaunch(registry, conversationID: "conv-A")
        do {
            _ = try await launch.prepareSpawn()
            XCTFail("Expected the reservation write to fail")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
        let runtimeID = await launch.runtimeID
        XCTAssertNil(runtimeID)
        await assertThrows(.staleLaunch) { try await launch.commitSpawn(pid: 10, processGroupID: nil) }
        await assertThrows(.staleLaunch) { try await launch.authorizeWrite() }
        failures.shouldFailWrites = false
        await assertThrows(.staleLaunch) { _ = try await launch.prepareSpawn() }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
    }

    func testTwoWriterRuleRefusesConflictingReservationAndAssociationWithoutWriting() async throws {
        processes.add(processes.observation(pid: 600, group: 600))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 600),
            rootGroup: 600,
            conversationIDs: ["conv-A"],
            worktreePaths: ["/tmp/wt-a"]
        )
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .live)

        await assertThrows(.ownershipConflict(runtimeID: seeded.runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/elsewhere", conversationID: "conv-A"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 1, "a refused reservation writes nothing")

        let unrelated = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/wt-b", conversationID: "conv-B"))
        XCTAssertEqual(Fixtures.record(store, unrelated.runtimeID)?.state, .reserved, "unrelated work continues")
        await assertThrows(.ownershipConflict(runtimeID: seeded.runtimeID)) {
            try await registry.associate(
                runtimeID: unrelated.runtimeID,
                launchToken: unrelated.launchToken,
                association: AgentRuntimeAssociation(session: nil, conversationID: "conv-A", worktreePath: nil, permission: .unavailable)
            )
        }
        XCTAssertEqual(Fixtures.record(store, unrelated.runtimeID)?.conversationIDs, ["conv-B"])
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID], "an active launch restricts nothing")
    }

    func testCommitFailuresLeaveOwnershipUnresolvedAndFenceEveryWrite() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        // Birth identity unavailable.
        let denied = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-denied")
        let deniedID = try await denied.prepareSpawn()
        processes.deny(pid: 700)
        await assertThrows(.identityUnavailable) { try await denied.commitSpawn(pid: 700, processGroupID: 700) }
        XCTAssertEqual(Fixtures.record(store, deniedID)?.state, .unknown)
        await assertThrows(.staleLaunch) { try await denied.authorizeWrite() }
        await assertThrows(.staleLaunch) { try await denied.associate(conversationID: "thread-1") }

        // Commit write failure.
        let unwritten = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-unwritten")
        let unwrittenID = try await unwritten.prepareSpawn()
        processes.add(processes.observation(pid: 701, executable: "/opt/fixture/bin/codex", group: 701, marker: unwrittenID))
        failures.shouldFailWrites = true
        do {
            try await unwritten.commitSpawn(pid: 701, processGroupID: 701)
            XCTFail("Expected the commit write to fail")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
        failures.shouldFailWrites = false
        XCTAssertEqual(Fixtures.record(store, unwrittenID)?.state, .reserved, "the durable record keeps its reservation")
        await assertThrows(.staleLaunch) { try await unwritten.authorizeWrite() }

        let snapshot = await registry.restrictionSnapshot()
        let restricted = Dictionary(uniqueKeysWithValues: snapshot.restrictions.map { ($0.runtimeID, $0) })
        XCTAssertEqual(restricted[deniedID]?.kind, .possibleWriter)
        XCTAssertEqual(restricted[unwrittenID]?.state, .unknown, "an unpersisted classification is unresolved")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-denied")))
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "thread-9", worktreePath: "/tmp/wt-unwritten")))
    }

    /// Lossless restart Phase 4 §G Stage B proof and the Claude history home lookup.
    func testRestartStageBProofAndClaudeHistoryHomesFollowRegisteredRecords() async throws {
        let inactive = makeRegistry(store: makeStore(), qualification: .production)
        await inactive.start()
        let inactiveProof = await inactive.verifyAllFamiliesStopped()
        XCTAssertEqual(inactiveProof, .notProven("Runtime registration is not active."))

        let store = makeStore()
        let registry = makeRegistry(store: store)
        let unchecked = await registry.verifyAllFamiliesStopped()
        XCTAssertEqual(unchecked, .notProven("Runtime ownership has not been checked yet."))
        await registry.start()
        let empty = await registry.verifyAllFamiliesStopped()
        XCTAssertEqual(empty, .allStopped)
        // Review A P1-08: the proof seals launches for the rest of the process (Stage B has no Cancel),
        // sessionless probes included, so nothing can start between the proof, the arm and the exit.
        let sealed = await registry.isSealedForSafeRestart
        XCTAssertTrue(sealed)
        let sessionless = try newLaunch(registry, session: .sessionless)
        await assertThrows(.launchesSealed) { _ = try await sessionless.prepareSpawn() }
        let afterSealed = try newLaunch(registry, conversationID: "conv-A")
        await assertThrows(.launchesSealed) { _ = try await afterSealed.prepareSpawn() }
        XCTAssertEqual(processes.sentSignals.count, 0)

        let liveRegistry = makeRegistry(store: makeStore())
        await liveRegistry.start()
        let launch = try newLaunch(liveRegistry, conversationID: "conv-A")
        let runtimeID = try await launch.prepareSpawn()
        let reserved = await liveRegistry.verifyAllFamiliesStopped()
        XCTAssertEqual(reserved, .notProven("A provider launch is still in progress."), "a durable reservation is never proof")
        processes.add(processes.observation(pid: 800, group: 800, marker: runtimeID, home: "/Users/fixture/.claude-alt"))
        try await launch.commitSpawn(pid: 800, processGroupID: 800)

        let homes = await liveRegistry.claudeProviderHomes(conversationID: "conv-A")
        XCTAssertEqual(homes, ["/Users/fixture/.claude-alt"], "the observed CLAUDE_CONFIG_DIR of the exact conversation")
        let otherHomes = await liveRegistry.claudeProviderHomes(conversationID: "conv-other")
        XCTAssertEqual(otherHomes, [])
        let live = await liveRegistry.verifyAllFamiliesStopped()
        guard case .notProven = live else { return XCTFail("a live family is never proof that everything stopped") }
        XCTAssertEqual(processes.sentSignals.count, 0, "the proof never signals")
    }

    func testStaleLaunchGenerationsAreFencedAfterRootReap() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-A")
        let runtimeID = try await launch.prepareSpawn()
        processes.add(processes.observation(pid: 800, group: 800, marker: runtimeID, home: "/Users/fixture/.claude-alt"))
        processes.add(processes.observation(pid: 801, start: 200, parent: 800, executable: "/usr/bin/node", group: 800, marker: runtimeID))
        try await launch.commitSpawn(pid: 800, processGroupID: 800)

        var record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.state, .live)
        XCTAssertEqual(record.root, processes.identity(pid: 800))
        XCTAssertEqual(record.providerHome, "/Users/fixture/.claude-alt", "the home comes from the process's own environment")
        try await launch.authorizeWrite(conversationID: "conv-A")
        await assertThrows(.ownershipConflict(runtimeID: nil)) { try await launch.authorizeWrite(conversationID: "conv-other") }
        XCTAssertEqual(processes.liveWatchCount(pid: 800), 1)
        await assertThrows(.staleLaunch) { _ = try await launch.prepareSpawn() }

        // The root exits and is reaped by its launcher; its tool survives, reparented to launchd.
        processes.remove(pid: 800)
        processes.add(processes.observation(pid: 801, start: 200, parent: 1, executable: "/usr/bin/node", group: 800, marker: runtimeID))
        await launch.rootReaped(pid: 800, confirmed: true)
        record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertTrue(record.rootReaped)
        XCTAssertEqual(record.state, .toolsRemaining, "root exit is not family exit")
        XCTAssertEqual(record.members.map(\.role), [.tool])
        await assertThrows(.staleLaunch) { try await launch.authorizeWrite(conversationID: "conv-A") }
        await assertThrows(.staleLaunch) { try await launch.associate(conversationID: "conv-Z") }

        let snapshot = await registry.restrictionSnapshot()
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: "/tmp/rpce-wt")))
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/rpce-wt")))

        await launch.spawnFailed()
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .toolsRemaining, "a late callback of an ended launch is ignored")

        XCTAssertEqual(processes.processExited(pid: 801), 1, "every identified member is watched")
        let exited = await Fixtures.eventually { Fixtures.record(store, runtimeID)?.state == .exited }
        XCTAssertTrue(exited)
    }

    // MARK: Discovery

    func testPIDReuseAndDeniedInspection() async throws {
        // The recorded root PID now belongs to an unrelated later process.
        processes.add(processes.observation(pid: 900, start: 999, executable: "/bin/zsh", group: 900))
        let reused = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 900, start: 10), conversationIDs: ["conv-reused"])
        let denied = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 901), conversationIDs: ["conv-denied"])
        processes.deny(pid: 901)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        let reusedRecord = try XCTUnwrap(Fixtures.record(store, reused.runtimeID))
        XCTAssertEqual(reusedRecord.state, .exited, "a different birth identity proves only that the lifetime ended")
        XCTAssertTrue(reusedRecord.members.isEmpty, "the reused PID never joins the family")
        XCTAssertEqual(Fixtures.record(store, denied.runtimeID)?.state, .unknown, "denied inspection is never exit")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-denied", worktreePath: nil)))
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-reused", worktreePath: nil)))
    }

    func testMixedExecUpgradesToolsToWritersAndNeverDemotesWriters() async throws {
        processes.add(processes.observation(pid: 951, start: 200, parent: 1, executable: "/opt/fixture/bin/claude", group: 950))
        processes.add(processes.observation(pid: 952, start: 210, parent: 1, executable: "/usr/bin/node", group: 950))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 950),
            rootGroup: 950,
            members: [
                AgentRuntimeMember(identity: processes.identity(pid: 951, start: 200), processGroupID: 950, role: .tool),
                AgentRuntimeMember(identity: processes.identity(pid: 952, start: 210), processGroupID: 950, role: .writer)
            ],
            conversationIDs: ["conv-M"]
        )
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.state, .live)
        XCTAssertEqual(record.members.map(\.identity.pid), [951, 952])
        XCTAssertEqual(record.members.map(\.role), [.writer, .writer], "exec into a writer upgrades; writers are never demoted")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-M", worktreePath: nil)))
    }

    func testMarkersAndParentLinksFindDescendantsButNotEarlierBornOrAppProcesses() async throws {
        processes.add(processes.observation(pid: 960, executable: "/opt/fixture/bin/claude", group: 960))
        processes.add(processes.observation(pid: 961, start: 200, parent: 960, executable: "/usr/bin/node", group: 961))
        processes.add(processes.observation(pid: 963, start: 300, parent: 961, executable: nil, group: 961, environmentAvailable: false))
        // Born before the root: a parent-PID match through PID reuse, never a member.
        processes.add(processes.observation(pid: 964, start: 50, parent: 960, executable: "/usr/bin/node", group: 964))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 960), rootGroup: 960, conversationIDs: ["conv-F"])
        // A reparented tool found only by its marker, and the app itself carrying the same marker.
        processes.add(processes.observation(pid: 962, start: 250, parent: 1, executable: "/usr/bin/node", group: 962, marker: seeded.runtimeID))
        processes.add(processes.observation(pid: processes.appPID, start: 20, parent: 1, group: processes.appProcessGroupID, marker: seeded.runtimeID))

        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.members.map(\.identity.pid), [961, 962, 963])
        XCTAssertEqual(record.members.map(\.role), [.tool, .tool, .unknown], "unclassifiable members stay unknown")
        XCTAssertEqual(record.state, .live)
        for pid: pid_t in [960, 961, 962, 963] {
            XCTAssertEqual(processes.liveWatchCount(pid: pid), 1, "watch every member, pid \(pid)")
        }
        XCTAssertEqual(processes.liveWatchCount(pid: 964), 0)
    }

    func testStaleWatchEventsAreIgnoredAndExitEventsRediscover() async throws {
        processes.add(processes.observation(pid: 970, group: 970))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 970), rootGroup: 970, conversationIDs: ["conv-W"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 1)

        let stale = processes.capturedHandlers(pid: 970)
        await registry.disposeWatches()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 0, "disposal cancels every watch")
        let passesBefore = processes.inventoryCalls
        stale.forEach { $0() }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await registry.restrictionSnapshot()
        XCTAssertEqual(processes.inventoryCalls, passesBefore, "a disposed watch generation never triggers rediscovery")

        await registry.refresh()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 1, "refresh reinstalls the watch")
        processes.processExited(pid: 970)
        let exited = await Fixtures.eventually { Fixtures.record(store, seeded.runtimeID)?.state == .exited }
        XCTAssertTrue(exited)
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertTrue(snapshot.restrictions.isEmpty)
    }

    func testUnwatchableLifetimeStaysUnresolved() async throws {
        processes.add(processes.observation(pid: 980, group: 980))
        processes.makeUnwatchable(pid: 980)
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 980), rootGroup: 980, conversationIDs: ["conv-U"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "no polling fallback for a missed watch")
    }

    func testRediscoveryRequestsCoalesceIntoOneFollowUpPass() async throws {
        processes.add(processes.observation(pid: 990, group: 990))
        try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 990), rootGroup: 990, conversationIDs: ["conv-C"])
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let before = processes.inventoryCalls

        let gate = InventoryGate()
        processes.inventoryHook = { await gate.pass() }
        let first = Task { await registry.refresh() }
        await gate.waitForArrival()
        let followers = (0 ..< 3).map { _ in Task { await registry.refresh() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        await first.value
        for follower in followers {
            await follower.value
        }
        XCTAssertEqual(processes.inventoryCalls - before, 2, "requests during a pass coalesce into exactly one more pass")
    }

    // MARK: Preserved records and uncertainty

    func testUnidentifiableRecordIsGlobalUncertainty() async throws {
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("not-a-runtime.json")
        try Data("{}".utf8).write(to: file)
        let registry = makeRegistry(store: makeStore())
        let snapshot = await registry.start()

        XCTAssertTrue(snapshot.hasGlobalUncertainty)
        XCTAssertEqual(snapshot.unidentifiedRecordCount, 1)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "anything", worktreePath: "/tmp/any")))
        await assertThrows(.ownershipUnknown) {
            _ = try await registry.reserveLaunch(Fixtures.context(.acp, worktreePath: "/tmp/any"))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8), "preserved bytes are never rewritten")
    }

    func testUnreadableRecordWithBindingsIsScopedAndNonwritable() async throws {
        let runtimeID = UUID()
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(runtimeID.uuidString).json")
        let bytes = Data(#"{"schemaVersion":99,"conversationIDs":["conv-X"],"worktreePaths":["/tmp/wt-x"]}"#.utf8)
        try bytes.write(to: file)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        XCTAssertFalse(snapshot.hasGlobalUncertainty)
        let restriction = try XCTUnwrap(snapshot.restrictions.first { $0.runtimeID == runtimeID })
        XCTAssertTrue(restriction.isUnreadable)
        XCTAssertNil(restriction.family)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-X", worktreePath: nil)))
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-Y", worktreePath: "/tmp/wt-y")))
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-x")))
        await assertThrows(.ownershipConflict(runtimeID: runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/other", conversationID: "conv-X"))
        }
        await assertThrows(.staleLaunch) {
            try await registry.letFinish(runtimeID: runtimeID, expectedRevision: .make())
        }
        await registry.refresh()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        if case .preserved = store.readRuntime(runtimeID: runtimeID) {} else { XCTFail("Expected a preserved record") }
    }

    func testRecordCodecRoundTripsWithoutArgumentsOrEnvironment() throws {
        let timestamp = AgentRecoveryTimestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let record = AgentRuntimeRecord(
            runtimeID: UUID(),
            revision: .make(),
            appInstanceID: UUID(),
            family: .codexAppServer,
            provider: .codex,
            providerHome: nil,
            state: .toolsRemaining,
            root: processes.identity(pid: 42),
            rootProcessGroupID: 42,
            rootReaped: true,
            members: [AgentRuntimeMember(identity: processes.identity(pid: 43, start: 7), processGroupID: 42, role: .tool)],
            associations: [
                AgentRuntimeAssociation(
                    session: Fixtures.session(),
                    conversationID: "thread-1",
                    worktreePath: "/tmp/wt",
                    permission: .codex(approvalPolicy: "on-request", sandbox: "workspace-write")
                ),
                AgentRuntimeAssociation(session: nil, conversationID: nil, worktreePath: nil, permission: .unavailable)
            ],
            conversationIDs: ["thread-1"],
            worktreePaths: ["/tmp/wt"],
            letFinish: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let data = try AgentRuntimeRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRuntimeRecordCodec.decode(data, expectedRuntimeID: record.runtimeID) else {
            return XCTFail("Expected the record to round-trip")
        }
        XCTAssertEqual(decoded, record)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["argv", "arguments", "environment", "\"env\""] {
            XCTAssertFalse(text.contains(forbidden), "runtime records never persist \(forbidden)")
        }
        let unknownFamily = text.replacingOccurrences(of: "\"codexAppServer\"", with: "\"futureFamily\"")
        if case .success = AgentRuntimeRecordCodec.decode(Data(unknownFamily.utf8), expectedRuntimeID: record.runtimeID) {
            XCTFail("An unknown family variant must be preserved, not decoded")
        }
    }

    // MARK: Let finish

    func testLetFinishPersistsTheChoiceAndKeepsRestricting() async throws {
        processes.add(processes.observation(pid: 1100, group: 1100))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1100), rootGroup: 1100, conversationIDs: ["conv-L"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        let revision = try XCTUnwrap(snapshot.restrictions.first?.revision)

        try await registry.letFinish(runtimeID: seeded.runtimeID, expectedRevision: revision)
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.letFinish, true)
        let after = await registry.restrictionSnapshot()
        XCTAssertEqual(after.restrictions.first?.letFinish, true)
        XCTAssertTrue(
            after.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-L", worktreePath: nil)),
            "Let finish keeps watching and restricting"
        )
        XCTAssertEqual(processes.liveWatchCount(pid: 1100), 1)
        do {
            try await registry.letFinish(runtimeID: seeded.runtimeID, expectedRevision: revision)
            XCTFail("A stale revision must be refused")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Stop (injected actions only)

    private func seedStoppableFamily(group: pid_t = 1000) throws -> AgentRuntimeRecord {
        processes.add(processes.observation(pid: 1000, group: group))
        processes.add(processes.observation(pid: 1001, start: 200, parent: 1000, executable: "/usr/bin/node", group: group))
        return try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1000), rootGroup: group, conversationIDs: ["conv-S"])
    }

    private func stopPreview(_ registry: AgentProcessRegistry, _ runtimeID: UUID) async throws -> AgentRuntimeStopPreview {
        let preview = await registry.previewStop(runtimeID: runtimeID)
        return try XCTUnwrap(preview)
    }

    func testStopIsDisabledWithoutInjectedActions() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .disabled)
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopSignalsVerifiedGroupsThenVerifiesExit() async throws {
        let seeded = try seedStoppableFamily()
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let preview = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertTrue(preview.isComplete)
        XCTAssertEqual(preview.members.map(\.identity.pid), [1000, 1001])

        let result = await registry.stop(preview: preview)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM"], "no SIGKILL once the family is verified gone")
        XCTAssertEqual(processes.recordedSleeps, [3])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopEscalatesToKillAfterTheGracePeriod() async throws {
        let seeded = try seedStoppableFamily()
        processes.survivesTERM = true
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM", "1000:KILL"])
        XCTAssertEqual(processes.recordedSleeps, [3])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopRefusesChangedMembershipAndUnownedGroupMembers() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()

        var current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1002, start: 300, parent: 1, executable: "/usr/bin/node", group: 1000, marker: seeded.runtimeID))
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .changed)
        processes.remove(pid: 1002)

        current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1003, start: 300, parent: 1, executable: "/bin/zsh", group: 1000))
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "a group with an unowned process is never signalled")
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopRefusesTheAppProcessGroup() async throws {
        let seeded = try seedStoppableFamily(group: processes.appProcessGroupID)
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .refusedUnsafeGroup)
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopRefusesIncompleteFamiliesAndPermissionDenialStaysUnresolved() async throws {
        let seeded = try seedStoppableFamily()
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()

        processes.inventoryIsIncomplete = true
        var current = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertFalse(current.isComplete)
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "an incomplete family is never signalled")
        XCTAssertTrue(processes.sentSignals.isEmpty)

        processes.inventoryIsIncomplete = false
        processes.signalErrno = EPERM
        current = try await stopPreview(registry, seeded.runtimeID)
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .unresolved, "EPERM leaves the item unresolved")
        XCTAssertNotEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopRevalidatesEveryGroupMemberImmediatelyBeforeSignalling() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()

        // A process whose group cannot be read appears after the preview: membership is unverifiable.
        var current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1005, start: 300, parent: 1, executable: "/bin/zsh", group: nil))
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "unreadable group membership is never signalled")
        processes.remove(pid: 1005)

        // The root moved to another group after the preview: the observed group, not the persisted one.
        current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1000, group: 1010))
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .changed, "a member in another group than the reviewed one is a changed family")
        XCTAssertTrue(processes.sentSignals.isEmpty, "no signal from a stale membership view")
    }

    // MARK: Phase 3 remediation counterexamples

    func testUnreadableOwnershipEvidenceNeverProvesFamilyExit() async throws {
        // The root is gone; a reparented process born after it survives whose marker cannot be read.
        processes.add(processes.observation(pid: 1201, start: 200, parent: 1, executable: "/usr/bin/node", group: 1201, environmentAvailable: false))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1200), rootGroup: 1200, conversationIDs: ["conv-R1"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "unreadable ownership evidence is incomplete discovery")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-R1", worktreePath: nil)))

        processes.remove(pid: 1201)
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .exited, "complete readable discovery proves exit")
    }

    func testUnfamiliarDescendantsAreUnknownNotTools() async throws {
        processes.add(processes.observation(pid: 1300, group: 1300))
        processes.add(processes.observation(pid: 1301, start: 200, parent: 1300, executable: "/opt/fixture/bin/unfamiliar-shim", group: 1300))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1300), rootGroup: 1300, conversationIDs: ["conv-R2"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.unknown], "only explicit qualified tool evidence classifies a tool")

        // The root exits: an unknown member keeps the conversation restricted (never tool-only).
        processes.remove(pid: 1300)
        await registry.refresh()
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertNotEqual(Fixtures.record(store, seeded.runtimeID)?.state, .toolsRemaining)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-R2", worktreePath: nil)))
    }

    func testActiveSameSessionRuntimesExcludeEachOtherBeforeAnyConversationIsKnown() async throws {
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let session = AgentRuntimeSessionScope.session(Fixtures.session())
        let first = try await registry.reserveLaunch(Fixtures.context(.claudeNative, session: session, worktreePath: "/tmp/wt-s1"))
        await assertThrows(.ownershipConflict(runtimeID: first.runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, session: session, worktreePath: "/tmp/wt-s2"))
        }
        // A different session continues.
        _ = try await registry.reserveLaunch(Fixtures.context(
            .claudeNative,
            session: .session(Fixtures.session()),
            worktreePath: "/tmp/wt-s3"
        ))
    }

    func testNarrowedProviderQualificationDoesNotActivateRegistration() async {
        let narrowedACP = Fixtures.qualified(providers: [.acp: [.acp(.cursor)]])
        XCTAssertFalse(narrowedACP.activatesRegistration, "every supported provider of every family must be covered")
        let narrowedCompatible = Fixtures.qualified(providers: [.claudeCompatible: [.claude(.glm)]])
        XCTAssertFalse(narrowedCompatible.activatesRegistration)
        XCTAssertTrue(Fixtures.qualified().activatesRegistration)

        let registry = makeRegistry(store: makeStore(), qualification: narrowedACP)
        await registry.start()
        XCTAssertNil(
            AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(.acp, provider: .acp(.openCode), worktreePath: "/tmp/x")),
            "no legacy or partial registration for an uncovered provider"
        )
        await assertThrows(.registrationInactive) {
            _ = try await registry.reserveLaunch(Fixtures.context(.acp, provider: .acp(.cursor), worktreePath: "/tmp/x"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
    }

    func testRefreshRetriesAFailedRuntimeDirectoryRead() async throws {
        // The runtimes directory cannot be listed at startup (a file stands in its place).
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let runtimesPath = recoveryRoot.appendingPathComponent("runtimes")
        try Data("blocked".utf8).write(to: runtimesPath)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        var snapshot = await registry.start()
        XCTAssertNotNil(snapshot.storageFailure)
        await assertThrows(.ownershipUnknown) {
            _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/any"))
        }

        // Access is restored (and an earlier instance's runtime is now readable): Refresh recovers.
        try FileManager.default.removeItem(at: runtimesPath)
        processes.add(processes.observation(pid: 1500, group: 1500))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1500), rootGroup: 1500, conversationIDs: ["conv-R11"])
        snapshot = await registry.refreshRetryingStorage()
        XCTAssertNil(snapshot.storageFailure, "uncertainty clears only after a successful read")
        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID])
        _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/any"))
    }

    func testRootlessFailedCommitResolvesOnlyOnAConfirmedExactReapAndCompleteDiscovery() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        // An unconfirmed reap (no exit status observed) is not exit proof.
        let unconfirmed = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-unconfirmed")
        let unconfirmedID = try await unconfirmed.prepareSpawn()
        processes.deny(pid: 1400)
        await assertThrows(.identityUnavailable) { try await unconfirmed.commitSpawn(pid: 1400, processGroupID: 1400) }
        await unconfirmed.rootReaped(pid: 1400, confirmed: false)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.rootReaped, false)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.state, .unknown)

        // A confirmed reap of the exact spawned child, but discovery is incomplete: unresolved.
        let confirmed = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-confirmed")
        let confirmedID = try await confirmed.prepareSpawn()
        processes.deny(pid: 1401)
        await assertThrows(.identityUnavailable) { try await confirmed.commitSpawn(pid: 1401, processGroupID: 1401) }
        processes.inventoryIsIncomplete = true
        await confirmed.rootReaped(pid: 1401, confirmed: true)
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.rootReaped, true)
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.state, .unknown, "incomplete discovery never proves exit")

        // Complete qualified discovery resolves only the confirmed exact reap.
        processes.inventoryIsIncomplete = false
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.state, .exited)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.state, .unknown, "marker absence alone is not exit proof")
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-unconfirmed")))
        XCTAssertFalse(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-confirmed")))
    }

    // MARK: Phase 3 re-review counterexamples (R-1)

    func testUnrelatedZombieAndEarlierBornUnreadableProcessesDoNotKeepAnExitedFamilyUnresolved() async throws {
        // The root (born at 10 000 s) is gone. An unrelated same-UID zombie (no readable environment
        // or group) and a process born long before the root (unreadable environment) are present.
        let root = processes.identity(pid: 1500, start: 10000)
        processes.add(processes.observation(pid: 1501, start: 20000, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        processes.add(processes.observation(pid: 1502, start: 1000, parent: 1, executable: "/usr/bin/node", group: 1502, environmentAvailable: false))
        // Contrast: born before the root but within the wall-clock margin (could descend from it).
        let withinMargin = 10000 - AgentProcessRegistry.birthOrderingMarginSeconds + 1
        processes.add(processes.observation(pid: 1503, start: withinMargin, parent: 1, executable: "/usr/bin/node", group: 1503, environmentAvailable: false))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: root, rootGroup: 1500, conversationIDs: ["conv-Z"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "an unreadable process inside the margin keeps discovery incomplete")

        processes.remove(pid: 1503)
        await registry.refresh()
        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.state, .exited, "a zombie and an earlier-born process are never reparented members")
        XCTAssertTrue(record.members.isEmpty, "neither is adopted as a member")
    }

    func testRootlessReservationOfThisInstanceAnchorsBirthOrderingOnItsCreation() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        let nowSeconds = UInt64(Date().timeIntervalSince1970)
        // Long before this reservation existed: cannot descend from its child.
        processes.add(processes.observation(pid: 1602, start: 1000, parent: 1, executable: "/usr/bin/node", group: 1602, environmentAvailable: false))
        processes.add(processes.observation(pid: 1603, start: nowSeconds, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        // Within the margin of the reservation: could be its reparented child.
        processes.add(processes.observation(pid: 1604, start: nowSeconds - 60, parent: 1, executable: "/usr/bin/node", group: 1604, environmentAvailable: false))

        let launch = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-rootless-r1")
        let runtimeID = try await launch.prepareSpawn()
        processes.deny(pid: 1601)
        await assertThrows(.identityUnavailable) { try await launch.commitSpawn(pid: 1601, processGroupID: 1601) }
        await launch.rootReaped(pid: 1601, confirmed: true)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.rootReaped, true)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .unknown, "the within-margin unreadable process keeps it unresolved")

        processes.remove(pid: 1604)
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .exited)
    }

    func testStopIgnoresAnUnreadableGroupOnlyForAZombie() async throws {
        let seeded = try seedStoppableFamily()
        // An exited, uncollected process: its group cannot be read, and it can neither be harmed nor
        // survive a signal. (A live process with an unreadable group still refuses Stop: see
        // `testStopRevalidatesEveryGroupMemberImmediatelyBeforeSignalling`.)
        processes.add(processes.observation(pid: 1007, start: 300, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let preview = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertTrue(preview.isComplete)
        XCTAssertEqual(preview.members.map(\.identity.pid), [1000, 1001], "the zombie is not a member")

        let result = await registry.stop(preview: preview)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM"])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }
}
