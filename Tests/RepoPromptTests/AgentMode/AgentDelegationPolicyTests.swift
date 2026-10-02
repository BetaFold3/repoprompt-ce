import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Bounded RepoPrompt MCP delegation: main (depth 0) → worker (depth 1) → sub-worker (depth 2).
@MainActor
final class AgentDelegationPolicyTests: XCTestCase {
    private typealias Policy = AgentDelegationPolicy

    // MARK: - Pure lineage and decisions

    func testLineageCountsParentEdgesAcrossMainWorkerAndSubWorker() {
        let main = UUID()
        let worker = UUID()
        let subWorker = UUID()
        let parents: [UUID: Policy.ParentLookup] = [
            main: .root,
            worker: .parent(main),
            subWorker: .parent(worker)
        ]

        XCTAssertEqual(resolve(main, parents), .resolved(depth: 0))
        XCTAssertEqual(resolve(worker, parents), .resolved(depth: 1))
        XCTAssertEqual(resolve(subWorker, parents), .resolved(depth: 2))
        XCTAssertEqual(
            Policy.resolveLineage(sessionID: nil, startingParent: .root, parentOf: { _ in .unknown }),
            .resolved(depth: 0),
            "A live session without a durable identity or parent is a root"
        )
    }

    func testLineageFailsClosedOnMissingInconsistentAndCyclicAncestry() {
        let child = UUID()
        let missingParent = UUID()
        XCTAssertEqual(resolve(child, [child: .parent(missingParent)]), .unresolved)

        let conflictingParent = UUID()
        XCTAssertEqual(
            resolve(child, [child: .parent(conflictingParent), conflictingParent: .inconsistent]),
            .inconsistent
        )

        let selfParented = UUID()
        XCTAssertEqual(resolve(selfParented, [selfParented: .parent(selfParented)]), .cyclic)

        let first = UUID()
        let second = UUID()
        XCTAssertEqual(resolve(first, [first: .parent(second), second: .parent(first)]), .cyclic)
    }

    func testDecisionAndRunToolPolicyBoundDelegationByDepthAndRole() {
        let delegatingRoles: [AgentModelCatalog.TaskLabelKind?] = [nil, .engineer, .pair, .design]
        for role in delegatingRoles {
            let label = role?.rawValue ?? "nil-role"
            for depth in 0 ... 1 {
                let decision = Policy.decision(taskLabelKind: role, lineage: .resolved(depth: depth))
                XCTAssertEqual(decision, .eligible(depth: depth), label)
                XCTAssertNil(Policy.denialMessage(for: decision), label)
                let policy = Policy.runToolPolicy(decision: decision, taskLabelKind: role)
                XCTAssertTrue(policy.allowsAgentExternalControlTools, label)
                XCTAssertTrue(policy.additionalRestrictedTools.isEmpty, label)
                XCTAssertEqual(policy.promptAudience, role == nil ? .agentRunOnly : .both, label)
            }
            for depth in 2 ... 3 {
                let decision = Policy.decision(taskLabelKind: role, lineage: .resolved(depth: depth))
                XCTAssertEqual(decision, .depthLimit(depth: depth), "\(label) depth \(depth)")
                XCTAssertEqual(Policy.runToolPolicy(decision: decision, taskLabelKind: role), .leaf, label)
                XCTAssertTrue(
                    Policy.denialMessage(for: decision)?.contains("sub-workers cannot start or control other agents") == true,
                    label
                )
            }
        }

        for depth in 0 ... 2 {
            let decision = Policy.decision(taskLabelKind: .explore, lineage: .resolved(depth: depth))
            XCTAssertEqual(decision, .exploreLeaf, "explore depth \(depth)")
            XCTAssertEqual(Policy.runToolPolicy(decision: decision, taskLabelKind: .explore), .leaf)
        }

        for failure in [Policy.LineageResolution.unresolved, .cyclic, .inconsistent] {
            let decision = Policy.decision(taskLabelKind: nil, lineage: failure)
            XCTAssertEqual(decision, .lineageFailure(failure))
            XCTAssertEqual(Policy.runToolPolicy(decision: decision, taskLabelKind: nil), .leaf)
            XCTAssertNotNil(Policy.denialMessage(for: decision))
        }

        XCTAssertEqual(
            Policy.delegationToolNames,
            [MCPWindowToolName.agentRun, MCPWindowToolName.agentManage, MCPWindowToolName.agentExplore]
        )
        XCTAssertEqual(Policy.RunToolPolicy.leaf.additionalRestrictedTools, Policy.delegationToolNames)
        XCTAssertFalse(Policy.RunToolPolicy.leaf.allowsAgentExternalControlTools)
        XCTAssertEqual(Policy.RunToolPolicy.leaf.promptAudience, ExportDelegationAudience.none)
    }

    func testLeafLeaseRestrictsEveryDelegationToolWhileEligibleLeaseKeepsBaseRestrictions() {
        let leaf = Policy.RunToolPolicy.leaf
        let leafSpec = MCPBootstrapLeaseSpec.agentMode(
            tabID: UUID(),
            runID: UUID(),
            gateID: UUID(),
            windowID: 1,
            agent: .claudeCode,
            taskLabelKind: .engineer,
            allowsAgentExternalControlTools: leaf.allowsAgentExternalControlTools,
            additionalRestrictedTools: leaf.additionalRestrictedTools
        )
        XCTAssertTrue(leafSpec.restrictedTools.isSuperset(of: AgentModeMCPToolPolicy.restrictedTools))
        XCTAssertTrue(leafSpec.restrictedTools.isSuperset(of: Policy.delegationToolNames))
        XCTAssertFalse(leafSpec.allowsAgentExternalControlTools)

        let eligible = Policy.runToolPolicy(decision: .eligible(depth: 1), taskLabelKind: .engineer)
        let eligibleSpec = MCPBootstrapLeaseSpec.agentMode(
            tabID: UUID(),
            runID: UUID(),
            gateID: UUID(),
            windowID: 1,
            agent: .claudeCode,
            taskLabelKind: .engineer,
            allowsAgentExternalControlTools: eligible.allowsAgentExternalControlTools,
            additionalRestrictedTools: eligible.additionalRestrictedTools
        )
        XCTAssertEqual(eligibleSpec.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
        XCTAssertTrue(eligibleSpec.allowsAgentExternalControlTools)
        XCTAssertTrue(eligibleSpec.restrictedTools.isDisjoint(with: Policy.delegationToolNames))
    }

    // MARK: - View-model admission over live lineage

    func testLiveLineageAdmitsMainAndWorkerButDeniesSubWorkerExploreAndExplicitModelNilRole() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let worker = makeSession(vm, parent: main.sessionID, role: .engineer)
        let nilRoleWorker = makeSession(vm, parent: main.sessionID, role: nil)
        // Explicit-model sub-worker: nil role and no MCP control context must not bypass the ceiling.
        let nilRoleSubWorker = makeSession(vm, parent: worker.sessionID, role: nil, controlled: false)
        let namedSubWorker = makeSession(vm, parent: nilRoleWorker.sessionID, role: .pair)
        let explore = makeSession(vm, parent: main.sessionID, role: .explore)

        XCTAssertEqual(vm.mcpDelegationLineage(for: main.session), .resolved(depth: 0))
        XCTAssertEqual(vm.mcpDelegationLineage(for: worker.session), .resolved(depth: 1))
        XCTAssertEqual(vm.mcpDelegationLineage(for: nilRoleSubWorker.session), .resolved(depth: 2))

        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: nil), "External clients keep their surface")
        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: main.tabID))
        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: worker.tabID))
        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: nilRoleWorker.tabID))
        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: worker.tabID, isExploreOnly: true))
        for subWorker in [nilRoleSubWorker, namedSubWorker] {
            XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: subWorker.tabID)) { error in
                XCTAssertTrue(String(describing: error).contains("delegation depth 2"), String(describing: error))
            }
            XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: subWorker.tabID, isExploreOnly: true))
        }
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: explore.tabID)) { error in
            XCTAssertTrue(String(describing: error).contains("Explore agents cannot start or control"), String(describing: error))
        }
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: explore.tabID, isExploreOnly: true)) { error in
            XCTAssertTrue(String(describing: error).contains("cannot start additional explore agents"), String(describing: error))
        }

        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: main.session).promptAudience, .agentRunOnly)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: worker.session).promptAudience, .both)
        XCTAssertTrue(vm.mcpDelegationRunToolPolicy(for: worker.session).allowsAgentExternalControlTools)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: nilRoleWorker.session).promptAudience, .agentRunOnly)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: nilRoleSubWorker.session), .leaf)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: namedSubWorker.session), .leaf)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: explore.session), .leaf)
    }

    func testLiveLineageFailsClosedForMissingCyclicOrUnresolvedSources() throws {
        let vm = makeViewModel()

        let orphan = makeSession(vm, parent: UUID(), role: .engineer)
        XCTAssertEqual(vm.mcpDelegationLineage(for: orphan.session), .unresolved)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: orphan.session), .leaf)
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: orphan.tabID)) { error in
            XCTAssertTrue(String(describing: error).contains("missing ancestor"), String(describing: error))
        }

        let cycleA = makeSession(vm, parent: nil, role: .engineer)
        let cycleB = makeSession(vm, parent: cycleA.sessionID, role: .engineer)
        cycleA.session.parentSessionID = cycleB.sessionID
        XCTAssertEqual(vm.mcpDelegationLineage(for: cycleA.session), .cyclic)
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: cycleA.tabID)) { error in
            XCTAssertTrue(String(describing: error).contains("cyclic ancestry"), String(describing: error))
        }

        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: UUID())) { error in
            XCTAssertTrue(
                String(describing: error).contains("could not resolve the calling Agent Mode session"),
                String(describing: error)
            )
        }
    }

    func testDuplicateIdentityClaimsReconcileCompatibleAndConflictingParents() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let otherMain = makeSession(vm, parent: nil, role: nil)

        // Compatible duplicates (both parentless) keep root semantics for callers and children.
        let compatibleID = UUID()
        let compatibleA = makeSession(vm, sessionID: compatibleID, parent: nil, role: nil)
        _ = makeSession(vm, sessionID: compatibleID, parent: nil, role: nil)
        let childOfCompatible = makeSession(vm, parent: compatibleID, role: .engineer)
        XCTAssertEqual(vm.mcpDelegationParentLookup(sessionID: compatibleID), .root)
        XCTAssertEqual(vm.mcpDelegationLineage(for: compatibleA.session), .resolved(depth: 0))
        XCTAssertEqual(vm.mcpDelegationLineage(for: childOfCompatible.session), .resolved(depth: 1))
        XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: childOfCompatible.tabID))

        // A parentless duplicate cannot shorten the lineage another record claims for the identity:
        // the parentless caller resolves at the claimed (deeper) position.
        let workerID = UUID()
        let parentlessWorkerClaim = makeSession(vm, sessionID: workerID, parent: nil, role: .engineer)
        _ = makeSession(vm, sessionID: workerID, parent: main.sessionID, role: .engineer)
        let subWorker = makeSession(vm, parent: workerID, role: .engineer)
        XCTAssertEqual(vm.mcpDelegationParentLookup(sessionID: workerID), .parent(main.sessionID))
        XCTAssertEqual(vm.mcpDelegationLineage(for: parentlessWorkerClaim.session), .resolved(depth: 1))
        XCTAssertEqual(vm.mcpDelegationLineage(for: subWorker.session), .resolved(depth: 2))
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: subWorker.tabID))

        // Different non-nil parent claims are inconsistent for every record and descendant.
        let conflictedID = UUID()
        let conflictedA = makeSession(vm, sessionID: conflictedID, parent: main.sessionID, role: .engineer)
        let conflictedB = makeSession(vm, sessionID: conflictedID, parent: otherMain.sessionID, role: .engineer)
        let childOfConflicted = makeSession(vm, parent: conflictedID, role: .engineer)
        XCTAssertEqual(vm.mcpDelegationParentLookup(sessionID: conflictedID), .inconsistent)
        for record in [conflictedA, conflictedB, childOfConflicted] {
            XCTAssertEqual(vm.mcpDelegationLineage(for: record.session), .inconsistent)
            XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: record.session), .leaf)
            XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: record.tabID)) { error in
                XCTAssertTrue(String(describing: error).contains("inconsistent ancestry"), String(describing: error))
            }
        }
    }

    func testUnhydratedPersistedIdentityIsUnknownUntilIndexedOrLoaded() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let worker = makeSession(vm, parent: main.sessionID, role: .engineer)
        let subWorker = makeSession(vm, parent: worker.sessionID, role: .engineer)

        // An unhydrated ancestor with no parent loaded and no index entry is not a root.
        worker.session.parentSessionID = nil
        worker.session.hasLoadedPersistedState = false
        XCTAssertEqual(vm.mcpDelegationParentLookup(sessionID: worker.sessionID), .unknown)
        XCTAssertEqual(vm.mcpDelegationLineage(for: subWorker.session), .unresolved)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: subWorker.session), .leaf)
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: subWorker.tabID)) { error in
            XCTAssertTrue(String(describing: error).contains("missing ancestor"), String(describing: error))
        }
        // The unhydrated caller itself is unverifiable rather than a fresh root.
        XCTAssertEqual(vm.mcpDelegationLineage(for: worker.session), .unresolved)
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: worker.tabID))

        // Once its persisted parent loads, the lineage resolves at its real depth.
        worker.session.parentSessionID = main.sessionID
        XCTAssertEqual(vm.mcpDelegationLineage(for: subWorker.session), .resolved(depth: 2))
        worker.session.hasLoadedPersistedState = true
        XCTAssertEqual(vm.mcpDelegationLineage(for: worker.session), .resolved(depth: 1))

        // A genuinely new root (hydrated, no durable identity yet) stays a root; admission binds
        // and returns its durable identity so later checks compare against the admitted session.
        let freshTabID = UUID()
        let fresh = try XCTUnwrap(vm.session(for: freshTabID, createIfNeeded: true))
        XCTAssertNil(fresh.activeAgentSessionID)
        XCTAssertTrue(fresh.hasLoadedPersistedState)
        XCTAssertEqual(vm.mcpDelegationLineage(for: fresh), .resolved(depth: 0))
        let admittedFreshID = try XCTUnwrap(vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: freshTabID))
        XCTAssertEqual(fresh.activeAgentSessionID, admittedFreshID)
        XCTAssertEqual(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: worker.tabID), worker.sessionID)
        XCTAssertNil(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: nil), "External callers stay unbound")

        XCTAssertNoThrow(try vm.mcpRequireAdmittedSpawnParent(
            sourceTabID: nil, admittedCallerSessionID: nil, resolvedParentSessionID: UUID(), operation: "agent_manage.create_session"
        ))
        XCTAssertNoThrow(try vm.mcpRequireAdmittedSpawnParent(
            sourceTabID: freshTabID, admittedCallerSessionID: admittedFreshID, resolvedParentSessionID: admittedFreshID, operation: "agent_manage.create_session"
        ))
        XCTAssertThrowsError(try vm.mcpRequireAdmittedSpawnParent(
            sourceTabID: freshTabID, admittedCallerSessionID: admittedFreshID, resolvedParentSessionID: UUID(), operation: "agent_manage.create_session"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("changed while its parent was being resolved"), String(describing: error))
        }
    }

    func testIndexedParentRestorationIsNotRejectedAsSubtreeAdoption() async throws {
        let vm = makeViewModel()
        let mainTabID = UUID()
        let mainSessionID = UUID()
        let workerTabID = UUID()
        let workerSessionID = UUID()
        let childTabID = UUID()
        let childSessionID = UUID()
        let otherTabID = UUID()
        let otherSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Delegation Restoration",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: mainTabID, name: "Main", activeAgentSessionID: mainSessionID),
                ComposeTabState(id: workerTabID, name: "Worker", activeAgentSessionID: workerSessionID),
                ComposeTabState(id: childTabID, name: "Child", activeAgentSessionID: childSessionID),
                ComposeTabState(id: otherTabID, name: "Other", activeAgentSessionID: otherSessionID)
            ],
            activeComposeTabID: nil
        )
        let owner = vm.test_receiveWorkspaceSwitchNotification(workspace)
        vm.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: [
                indexEntry(mainSessionID, tabID: mainTabID, parent: nil),
                indexEntry(workerSessionID, tabID: workerTabID, parent: mainSessionID),
                indexEntry(childSessionID, tabID: childTabID, parent: workerSessionID),
                indexEntry(otherSessionID, tabID: otherTabID, parent: nil)
            ].map { ($0.id, $0) }),
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        _ = makeSession(vm, tabID: mainTabID, sessionID: mainSessionID, parent: nil, role: nil)
        _ = makeSession(vm, tabID: otherTabID, sessionID: otherSessionID, parent: nil, role: nil)
        // Hydrated live record without its parent yet, whose index already records the parent and
        // which already has a delegated child.
        let worker = makeSession(vm, tabID: workerTabID, sessionID: workerSessionID, parent: nil, role: .engineer)
        let child = makeSession(vm, tabID: childTabID, sessionID: childSessionID, parent: workerSessionID, role: .engineer)
        XCTAssertTrue(vm.mcpDelegationHasChildSessions(workerSessionID))
        XCTAssertEqual(vm.mcpDelegationParentLookup(sessionID: workerSessionID), .parent(mainSessionID))
        XCTAssertEqual(vm.mcpDelegationLineage(for: child.session), .resolved(depth: 2))

        // Restoring the indexed parent through session resolution changes no depth and succeeds.
        let target = try await vm.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: workerSessionID,
            createIfNeeded: false,
            sessionName: nil,
            parentSessionID: otherSessionID
        )
        XCTAssertEqual(target.sessionID, workerSessionID)
        XCTAssertEqual(worker.session.parentSessionID, mainSessionID)
        XCTAssertEqual(vm.mcpDelegationLineage(for: worker.session), .resolved(depth: 1))
        XCTAssertEqual(vm.mcpDelegationLineage(for: child.session), .resolved(depth: 2))
    }

    func testCommitRevalidationRejectsChangedCallerIdentityOrLineage() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let worker = makeSession(vm, parent: main.sessionID, role: .engineer)
        let subWorker = makeSession(vm, parent: worker.sessionID, role: .engineer)
        let otherRoot = makeSession(vm, parent: nil, role: nil)
        let operation = "agent_run.start"

        XCTAssertNoThrow(try vm.mcpRevalidateDelegationCommit(
            sourceTabID: nil, expectedCallerSessionID: nil, operation: operation
        ))
        XCTAssertNoThrow(try vm.mcpRevalidateDelegationCommit(
            sourceTabID: worker.tabID,
            expectedCallerSessionID: worker.sessionID,
            targetSessionID: subWorker.sessionID,
            operation: operation
        ))
        XCTAssertThrowsError(try vm.mcpRevalidateDelegationCommit(
            sourceTabID: worker.tabID, expectedCallerSessionID: UUID(), operation: operation
        )) { error in
            XCTAssertTrue(String(describing: error).contains("changed while the request was in flight"), String(describing: error))
        }

        // The worker's root moved under another session after admission: the worker is now depth 2.
        main.session.parentSessionID = otherRoot.sessionID
        XCTAssertThrowsError(try vm.mcpRevalidateDelegationCommit(
            sourceTabID: worker.tabID, expectedCallerSessionID: worker.sessionID, operation: operation
        )) { error in
            XCTAssertTrue(String(describing: error).contains("delegation depth 2"), String(describing: error))
        }
        XCTAssertThrowsError(try vm.mcpRevalidateDelegationCommit(
            sourceTabID: worker.tabID,
            expectedCallerSessionID: worker.sessionID,
            isExploreOnly: true,
            operation: "agent_explore.start"
        ))
    }

    func testAdoptionOfParentlessSessionWithDelegatedChildrenIsRejected() async throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let rootWithChild = makeSession(vm, parent: nil, role: nil)
        let child = makeSession(vm, parent: rootWithChild.sessionID, role: .engineer)
        let childlessRoot = makeSession(vm, parent: nil, role: nil)

        XCTAssertTrue(vm.mcpDelegationHasChildSessions(rootWithChild.sessionID))
        XCTAssertFalse(vm.mcpDelegationHasChildSessions(childlessRoot.sessionID))

        do {
            _ = try await vm.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: rootWithChild.sessionID,
                createIfNeeded: false,
                sessionName: nil,
                parentSessionID: main.sessionID
            )
            XCTFail("Adopting a session with delegated children must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("already has delegated child sessions"), String(describing: error))
        }
        XCTAssertNil(rootWithChild.session.parentSessionID)
        XCTAssertEqual(vm.mcpDelegationLineage(for: child.session), .resolved(depth: 1))

        // A commit check that fails leaves a childless root unadopted too.
        struct StaleAdmission: Error {}
        do {
            _ = try await vm.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: childlessRoot.sessionID,
                createIfNeeded: false,
                sessionName: nil,
                parentSessionID: main.sessionID,
                delegationCommitCheck: { throw StaleAdmission() }
            )
            XCTFail("A failed commit check must abort adoption")
        } catch is StaleAdmission {}
        XCTAssertNil(childlessRoot.session.parentSessionID)

        let target = try await vm.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: childlessRoot.sessionID,
            createIfNeeded: false,
            sessionName: nil,
            parentSessionID: main.sessionID
        )
        XCTAssertEqual(target.sessionID, childlessRoot.sessionID)
        XCTAssertEqual(childlessRoot.session.parentSessionID, main.sessionID)
    }

    func testIndexedParentResolvesUnhydratedLiveSessionAndConflictingParentsAreInconsistent() {
        let vm = makeViewModel()
        let mainTabID = UUID()
        let mainSessionID = UUID()
        let otherTabID = UUID()
        let otherSessionID = UUID()
        let childTabID = UUID()
        let childSessionID = UUID()
        let conflictTabID = UUID()
        let conflictSessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Delegation Lineage",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: mainTabID, name: "Main", activeAgentSessionID: mainSessionID),
                ComposeTabState(id: otherTabID, name: "Other", activeAgentSessionID: otherSessionID),
                ComposeTabState(id: childTabID, name: "Child", activeAgentSessionID: childSessionID),
                ComposeTabState(id: conflictTabID, name: "Conflict", activeAgentSessionID: conflictSessionID)
            ],
            activeComposeTabID: nil
        )
        let owner = vm.test_receiveWorkspaceSwitchNotification(workspace)
        vm.test_installSessionIndexSnapshot(
            Dictionary(uniqueKeysWithValues: [
                indexEntry(mainSessionID, tabID: mainTabID, parent: nil),
                indexEntry(otherSessionID, tabID: otherTabID, parent: nil),
                indexEntry(childSessionID, tabID: childTabID, parent: mainSessionID),
                indexEntry(conflictSessionID, tabID: conflictTabID, parent: mainSessionID)
            ].map { ($0.id, $0) }),
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )

        // Unhydrated live child: its live parent is still nil, so the indexed parent wins.
        let child = makeSession(vm, tabID: childTabID, sessionID: childSessionID, parent: nil, role: nil)
        child.session.hasLoadedPersistedState = false
        XCTAssertEqual(vm.mcpDelegationLineage(for: child.session), .resolved(depth: 1))
        XCTAssertEqual(vm.mcpDelegationLineage(sessionID: mainSessionID), .resolved(depth: 0))

        // A compose tab bound to a persisted identity materializes unhydrated; with its index entry
        // it resolves from the index, without one it is unknown rather than a new root.
        let unindexedTabID = UUID()
        let unindexed = makeSession(vm, tabID: unindexedTabID, parent: nil, role: nil)
        unindexed.session.hasLoadedPersistedState = false
        XCTAssertEqual(vm.mcpDelegationLineage(for: unindexed.session), .unresolved)
        XCTAssertThrowsError(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: unindexedTabID))

        // Live and indexed parents disagree: neither reading is chosen.
        let conflict = makeSession(vm, tabID: conflictTabID, sessionID: conflictSessionID, parent: otherSessionID, role: nil)
        XCTAssertEqual(vm.mcpDelegationLineage(for: conflict.session), .inconsistent)
        XCTAssertEqual(vm.mcpDelegationRunToolPolicy(for: conflict.session), .leaf)
    }

    func testWorkerTargetsOnlyDeeperSessionsWhileMainKeepsExistingTargets() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let worker = makeSession(vm, parent: main.sessionID, role: .engineer)
        let sibling = makeSession(vm, parent: main.sessionID, role: .engineer)
        let subWorker = makeSession(vm, parent: worker.sessionID, role: .engineer)
        let otherRoot = makeSession(vm, parent: nil, role: nil)
        let operation = "agent_run.steer"

        for target in [worker, sibling, subWorker, otherRoot, main] {
            XCTAssertNoThrow(
                try vm.mcpValidateDelegationTarget(sourceTabID: main.tabID, targetSessionID: target.sessionID, operation: operation)
            )
            XCTAssertNoThrow(
                try vm.mcpValidateDelegationTarget(sourceTabID: nil, targetSessionID: target.sessionID, operation: operation)
            )
        }

        XCTAssertNoThrow(
            try vm.mcpValidateDelegationTarget(sourceTabID: worker.tabID, targetSessionID: subWorker.sessionID, operation: operation)
        )
        XCTAssertNoThrow(
            try vm.mcpValidateDelegationTarget(sourceTabID: worker.tabID, targetSessionID: nil, operation: operation)
        )
        XCTAssertThrowsError(
            try vm.mcpValidateDelegationTarget(sourceTabID: worker.tabID, targetSessionID: worker.sessionID, operation: operation)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("cannot target the calling agent session itself"), String(describing: error))
        }
        for shallower in [main, sibling, otherRoot] {
            XCTAssertThrowsError(
                try vm.mcpValidateDelegationTarget(sourceTabID: worker.tabID, targetSessionID: shallower.sessionID, operation: operation)
            ) { error in
                XCTAssertTrue(String(describing: error).contains("may only target sessions deeper"), String(describing: error))
            }
        }
        XCTAssertThrowsError(
            try vm.mcpValidateDelegationTarget(sourceTabID: worker.tabID, targetSessionID: UUID(), operation: operation)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("could not verify the target session"), String(describing: error))
        }
    }

    func testForkDestinationParentKeepsSourcePlacementAndNeverEscapesRequesterDepth() throws {
        let vm = makeViewModel()
        let main = makeSession(vm, parent: nil, role: nil)
        let worker = makeSession(vm, parent: main.sessionID, role: .engineer)
        let subWorker = makeSession(vm, parent: worker.sessionID, role: .engineer)
        let otherRoot = makeSession(vm, parent: nil, role: nil)

        // External requester: the destination takes the source's place in the tree.
        XCTAssertNil(try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: main.sessionID, requesterTabID: nil))
        XCTAssertEqual(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: subWorker.sessionID, requesterTabID: nil),
            worker.sessionID
        )
        // Main forking its child keeps the child's parent; forking an unrelated root adopts it under main.
        XCTAssertEqual(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: worker.sessionID, requesterTabID: main.tabID),
            main.sessionID
        )
        XCTAssertEqual(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: otherRoot.sessionID, requesterTabID: main.tabID),
            main.sessionID
        )
        // A worker cannot fork a root into a new root: the destination becomes its sub-worker.
        XCTAssertEqual(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: otherRoot.sessionID, requesterTabID: worker.tabID),
            worker.sessionID
        )
        XCTAssertEqual(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: worker.sessionID, requesterTabID: worker.tabID),
            worker.sessionID
        )
        XCTAssertThrowsError(
            try vm.mcpForkDestinationParentSessionID(forkSourceSessionID: UUID(), requesterTabID: nil)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("could not verify the source session"), String(describing: error))
        }
    }

    // MARK: - Prompt audience

    func testNilAudienceKeepsLegacyRolePromptsAcrossProviders() {
        for agentKind in [AgentProviderKind.claudeCode, .codexExec, .openCode, nil] {
            XCTAssertEqual(
                SystemPromptService.agentModePrompt(agentKind: agentKind),
                SystemPromptService.agentModePrompt(agentKind: agentKind, delegationAudience: .agentRunOnly)
            )
            for role in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
                XCTAssertEqual(
                    SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: role),
                    SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: role, delegationAudience: .agentExploreOnly),
                    role.rawValue
                )
            }
        }
    }

    func testEligibleNamedRolePromptsDescribeBothDelegationToolsAndDepthBound() {
        for agentKind in [AgentProviderKind.claudeCode, .codexExec, .openCode] {
            for role in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
                let label = "\(agentKind.rawValue)/\(role.rawValue)"
                let prompt = SystemPromptService.agentModePrompt(
                    agentKind: agentKind,
                    taskLabelKind: role,
                    delegationAudience: .both
                )
                XCTAssertTrue(prompt.contains(toolReference(MCPWindowToolName.agentRun, agentKind)), label)
                XCTAssertTrue(prompt.contains(toolReference(MCPWindowToolName.agentManage, agentKind)), label)
                XCTAssertTrue(prompt.contains(toolReference(MCPWindowToolName.agentExplore, agentKind)), label)
                XCTAssertTrue(prompt.contains("main → worker → sub-worker"), label)
                XCTAssertTrue(prompt.contains("prefer a Pair worker"), label)
                XCTAssertTrue(prompt.contains("oracle_export_path"), label)
            }
        }
    }

    func testPairReviewRemediationGuidanceMatchesDelegationAudienceAcrossProviders() {
        for agentKind in [AgentProviderKind.claudeCode, .codexExec, .openCode] {
            XCTAssertTrue(
                SystemPromptService.agentModePrompt(agentKind: agentKind).contains("prefer a Pair worker"),
                "\(agentKind.rawValue)/nil-role"
            )
            XCTAssertFalse(
                SystemPromptService.agentModePrompt(agentKind: agentKind, delegationAudience: .agentExploreOnly)
                    .contains("prefer a Pair worker"),
                "\(agentKind.rawValue)/nil-role/agentExploreOnly"
            )
            XCTAssertTrue(
                SystemPromptService.agentModePrompt(agentKind: agentKind, delegationAudience: .both)
                    .contains("prefer a Pair worker"),
                "\(agentKind.rawValue)/nil-role/both"
            )
            for role in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
                for audience in [ExportDelegationAudience.agentExploreOnly, nil] {
                    let prompt = SystemPromptService.agentModePrompt(
                        agentKind: agentKind,
                        taskLabelKind: role,
                        delegationAudience: audience
                    )
                    XCTAssertFalse(
                        prompt.contains("prefer a Pair worker"),
                        "\(agentKind.rawValue)/\(role.rawValue)/\(String(describing: audience))"
                    )
                }
            }
            for role in [AgentModelCatalog.TaskLabelKind.engineer, .pair, .design] {
                let prompt = SystemPromptService.agentModePrompt(
                    agentKind: agentKind,
                    taskLabelKind: role,
                    delegationAudience: .agentRunOnly
                )
                XCTAssertTrue(prompt.contains("prefer a Pair worker"), "\(agentKind.rawValue)/\(role.rawValue)/agentRunOnly")
            }

            let explorePrompt = SystemPromptService.agentModePrompt(agentKind: agentKind, taskLabelKind: .explore)
            XCTAssertFalse(explorePrompt.contains("prefer a Pair worker"), "\(agentKind.rawValue)/explore")
        }
    }

    func testLeafPromptsOmitEveryDelegationToolAndExportHandoff() {
        for agentKind in [AgentProviderKind.claudeCode, .codexExec, .openCode] {
            let roles: [AgentModelCatalog.TaskLabelKind?] = [nil, .engineer, .pair, .design]
            for role in roles {
                let label = "\(agentKind.rawValue)/\(role?.rawValue ?? "nil-role")"
                let prompt = SystemPromptService.agentModePrompt(
                    agentKind: agentKind,
                    taskLabelKind: role,
                    delegationAudience: ExportDelegationAudience.none
                )
                for tool in Policy.delegationToolNames.sorted() {
                    XCTAssertFalse(prompt.contains("`\(tool)`"), "\(label) \(tool)")
                    XCTAssertFalse(prompt.contains("__\(tool)`"), "\(label) \(tool)")
                }
                XCTAssertFalse(prompt.contains("prefer a Pair worker"), label)
                XCTAssertFalse(prompt.contains("oracle_export_instruction"), label)
                XCTAssertFalse(prompt.contains("When to dispatch"), label)
                XCTAssertFalse(prompt.contains("spawn_agent"), label)
            }
        }
        let nilRoleLeaf = SystemPromptService.agentModePrompt(agentKind: .claudeCode, delegationAudience: ExportDelegationAudience.none)
        XCTAssertTrue(nilRoleLeaf.contains("RepoPrompt agent delegation is not available in this session"))
    }

    // MARK: - Helpers

    private struct LiveSession {
        let tabID: UUID
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
    }

    private func resolve(_ sessionID: UUID, _ parents: [UUID: Policy.ParentLookup]) -> Policy.LineageResolution {
        Policy.resolveLineage(
            sessionID: sessionID,
            startingParent: parents[sessionID] ?? .unknown,
            parentOf: { parents[$0] ?? .unknown }
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
    }

    private func makeSession(
        _ vm: AgentModeViewModel,
        tabID: UUID = UUID(),
        sessionID: UUID = UUID(),
        parent: UUID?,
        role: AgentModelCatalog.TaskLabelKind?,
        controlled: Bool = true
    ) -> LiveSession {
        let session = vm.session(for: tabID, createIfNeeded: true)!
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parent
        session.hasLoadedPersistedState = true
        if controlled, parent != nil || role != nil {
            session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: nil,
                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
                suppressUserNotifications: true,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: false,
                taskLabelKind: role
            )
        }
        return LiveSession(tabID: tabID, sessionID: sessionID, session: session)
    }

    private func indexEntry(_ sessionID: UUID, tabID: UUID, parent: UUID?) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Session \(sessionID.uuidString.suffix(4))",
            lastUserMessageAt: Date(timeIntervalSince1970: 100),
            savedAt: Date(timeIntervalSince1970: 100),
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parent,
            hasUnknownConversationContent: false,
            remoteHostID: nil,
            remoteHostName: nil,
            isMCPOriginated: parent != nil,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func toolReference(_ tool: String, _ agentKind: AgentProviderKind) -> String {
        agentKind == .codexExec
            ? "`mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__\(tool)`"
            : "`\(tool)`"
    }
}
