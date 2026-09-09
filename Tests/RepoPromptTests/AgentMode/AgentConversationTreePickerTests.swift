import AppKit
@_spi(TestSupport) @testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentConversationTreePickerTests: XCTestCase {
    func testNestedTopologyAttachesBranchBelowOwningTurn() {
        let rootID = UUID()
        let rootTurns = [turn(sessionID: rootID, ordinal: 1), turn(sessionID: rootID, ordinal: 2)]
        let child = path(sourceID: rootID, sourceOrdinal: 2, turns: rootTurns)
        let root = path(id: rootID, turns: rootTurns)

        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, child])

        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].children.count, 2)
        XCTAssertEqual(nodes[0].children[1].children.first?.id, .path(child.id))
        XCTAssertTrue(nodes[0].children[1].children.first?.children.isEmpty == true)
    }

    func testCoalescingRequiresInheritedTurnIdentityNotMatchingSnippet() {
        let rootID = UUID()
        let shared = turn(sessionID: rootID, ordinal: 1, prompt: "same")
        let root = path(id: rootID, turns: [shared])
        let differentIdentity = turn(sessionID: UUID(), ordinal: 1, prompt: "same")
        let child = path(sourceID: rootID, sourceOrdinal: 1, turns: [differentIdentity])

        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, child])
        let childNode = nodes[0].children[0].children[0]
        XCTAssertEqual(childNode.children.count, 1, "Snippet equality must not coalesce distinct turns")
    }

    func testDeletedSourceProducesNotRetainedTurnPlaceholder() {
        let rootID = UUID()
        let root = path(id: rootID, turns: [])
        let child = path(sourceID: rootID, sourceOrdinal: 4, turns: [])

        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, child])

        XCTAssertEqual(nodes[0].children.first?.id, .missingTurn(sessionID: rootID, ordinal: 4))
        XCTAssertEqual(nodes[0].children.first?.children.first?.id, .path(child.id))
    }

    func testKeyboardReducerNavigatesExpandsSubmitsOnceAndEscapesOnlyWhenIdle() {
        let active = activePath()
        let model = makeModel(paths: [active], initial: .path(active.id))
        XCTAssertEqual(model.reduce(key: .right), .handled)
        XCTAssertEqual(model.reduce(key: .down), .handled)
        XCTAssertEqual(model.reduce(key: .enter), .submit)
        XCTAssertEqual(model.reduce(key: .enter, isRepeat: true), .ignored)
        XCTAssertEqual(model.reduce(key: .escape), .dismiss)
    }

    func testInactiveTurnResolvesToSwitchAndNeverBranch() throws {
        let inactive = path(turns: [turn(sessionID: UUID(), ordinal: 1)])
        let selected = try XCTUnwrap(inactive.turns?.first)
        let model = makeModel(paths: [inactive], initial: .turn(selected.id))
        XCTAssertEqual(model.primaryAction, .switchPath)
    }

    func testActiveHeaderIsCurrentPathAndIncompleteTurnIsDisabled() {
        let id = UUID()
        let incomplete = turn(sessionID: id, ordinal: 1, isCompleted: false)
        let active = path(id: id, isActive: true, turns: [incomplete])
        let headerModel = makeModel(paths: [active], initial: .path(id))
        XCTAssertEqual(headerModel.primaryAction, .currentPath)
        headerModel.select(.turn(incomplete.id))
        XCTAssertEqual(headerModel.primaryAction, .disabled("No completed turns yet."))
    }

    func testStaleSelectionRequiresExplicitNewActivation() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let model = makeModel(paths: [active], initial: .turn(selected.id))
        XCTAssertEqual(model.reduce(key: .enter), .submit)
        model.markSelectionStale()
        XCTAssertTrue(model.staleSelection)
        let staleSubmitResult = await model.submit()
        XCTAssertFalse(staleSubmitResult, "Idle submission must still reject stale selection")
        model.select(.turn(selected.id))
        XCTAssertFalse(model.staleSelection)
        XCTAssertEqual(model.reduce(key: .enter), .submit)
    }

    func testFailedTreeStillShowsCurrentPathAndAllowsBranching() throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let model = makeModel(paths: [active], initial: .turn(selected.id), phase: .failed("Index unavailable"))
        XCTAssertEqual(model.phase, .failed("Index unavailable"))
        XCTAssertEqual(model.primaryAction, .branch(title: "Branch"))
    }

    func testColdLoadCacheKeepsAtMostTwoInactiveSnapshots() async {
        let paths = (0 ..< 3).map { _ in path(turns: nil) }
        let byID = Dictionary(uniqueKeysWithValues: paths.map { ($0.id, $0) })
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: paths,
            initialSelection: nil,
            loadPath: { sessionID in
                guard var loaded = byID[sessionID] else { throw TestError.failed }
                loaded.turns = [self.turn(sessionID: sessionID, ordinal: 1)]
                return loaded
            },
            performBranch: { _ in },
            performSwitch: { _ in }
        )

        for path in paths {
            model.requestPathLoad(path.id)
            await waitUntil { model.pathLoadStates[path.id] == .loaded }
        }

        XCTAssertLessThanOrEqual(model.paths.compactMap(\.turns).count, 2)
        XCTAssertEqual(model.pathLoadStates[paths[0].id], .notLoaded)
    }

    func testStaleOrCancelledColdLoadCannotPublishIntoChangedPath() {
        let id = UUID()
        let savedAt = Date(timeIntervalSinceReferenceDate: 10)
        let current = path(id: id, turns: nil)
        XCTAssertFalse(AgentConversationTreePickerModel.shouldPublishPathLoad(
            sessionID: id,
            expectedSavedAt: savedAt,
            generation: 1,
            currentGeneration: 2,
            currentPath: current,
            isCancelled: false
        ))
        XCTAssertFalse(AgentConversationTreePickerModel.shouldPublishPathLoad(
            sessionID: id,
            expectedSavedAt: current.savedAt,
            generation: 1,
            currentGeneration: 1,
            currentPath: current,
            isCancelled: true
        ))
    }

    func testHostedOutlineCreatesNativeOutlineView() {
        let active = activePath()
        let model = makeModel(paths: [active], initial: .path(active.id))
        let host = NSHostingView(rootView: AgentConversationTreeOutlineView(model: model) { _ in })
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.subviews.isEmpty)
    }

    func testTurnAvailabilityIndicatorsAreExplicit() {
        let available = turn(sessionID: UUID(), ordinal: 1)
        let unavailable = AgentConversationTreePickerTurn(
            id: .init(sessionID: UUID(), turnID: UUID()),
            ordinal: 2,
            prompt: "Prompt",
            conclusion: nil,
            availability: .unavailable(.noCheckpoint),
            safetySummary: nil,
            isCompleted: true
        )
        XCTAssertEqual(available.availabilityIndicator, "●")
        XCTAssertEqual(unavailable.availabilityIndicator, "○")
    }

    func testDefaultSelectionUsesLatestCompletedTurnAndReplyUsesRequestedTurn() {
        let id = UUID()
        let first = turn(sessionID: id, ordinal: 1)
        let second = turn(sessionID: id, ordinal: 2)
        let active = path(id: id, isActive: true, turns: [first, second])

        XCTAssertEqual(makeModel(paths: [active], initial: nil).selectedID, .turn(second.id))
        XCTAssertEqual(makeModel(paths: [active], initial: .turn(first.id)).selectedID, .turn(first.id))
    }

    func testEmptyActivePathUsesExactCopy() {
        let active = path(id: UUID(), isActive: true, turns: [])
        XCTAssertEqual(
            makeModel(paths: [active], initial: nil).emptyStateText,
            "Complete a turn to create a branch."
        )
    }

    func testLoadingPublishesReadyTreeAndFailureRetainsActiveBranching() throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let model = makeModel(paths: [active], initial: .turn(selected.id), phase: .loading)
        let inactive = path(turns: nil)

        model.publishResolvedTree(phase: .ready, paths: [active, inactive])
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(Set(model.paths.map(\.id)), [active.id, inactive.id])

        model.publishResolvedTree(
            phase: .failed("Index unavailable"),
            paths: model.paths.filter(\.isActive)
        )
        XCTAssertEqual(model.phase, .failed("Index unavailable"))
        XCTAssertEqual(model.primaryAction, .branch(title: "Branch"))
    }

    func testInactiveTurnSubmitActuallySwitches() async {
        let inactive = path(turns: [])
        let selected = turn(sessionID: inactive.id, ordinal: 1)
        var loadedInactive = inactive
        loadedInactive.turns = [selected]
        var switchedID: UUID?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [loadedInactive],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in XCTFail("Inactive selection must not branch") },
            performSwitch: { switchedID = $0 }
        )

        let didSwitch = await model.submit()
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(switchedID, inactive.id)
        XCTAssertEqual(model.operation, .idle)
    }

    func testSharedPrefixTurnBranchesAgainstActiveDescendant() async {
        let turnID = UUID()
        let parentID = UUID()
        let activeID = UUID()
        let parentTurn = turn(sessionID: parentID, turnID: turnID, ordinal: 1)
        let activeTurn = turn(sessionID: activeID, turnID: turnID, ordinal: 1)
        let parent = path(id: parentID, turns: [parentTurn])
        let active = path(
            id: activeID,
            sourceID: parentID,
            sourceOrdinal: 1,
            isActive: true,
            turns: [activeTurn]
        )
        var branchedSessionID: UUID?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [parent, active],
            initialSelection: .turn(activeTurn.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { branchedSessionID = $0.id.sessionID },
            performSwitch: { _ in XCTFail("Retained active prefix must branch") }
        )

        XCTAssertEqual(model.primaryAction, .branch(title: "Branch"))
        let didBranch = await model.submit()
        XCTAssertTrue(didBranch)
        XCTAssertEqual(branchedSessionID, activeID)
        XCTAssertEqual(model.operation, .idle)
    }

    func testSourceEvidenceCreatesExactNonActionablePlaceholders() {
        let rootID = UUID()
        let root = path(id: rootID)
        let unavailable = path(
            sourceID: rootID,
            sourceOrdinal: 1,
            evidence: .sourceUnavailable
        )
        let deleted = path(
            sourceID: rootID,
            sourceOrdinal: 2,
            evidence: .deletedSource
        )
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, unavailable, deleted])
        let placeholders = nodes[0].children.compactMap { node -> String? in
            guard case let .sourcePlaceholder(title) = node.children.first?.kind ?? node.kind else {
                return nil
            }
            return title
        }
        XCTAssertTrue(placeholders.contains("Source path unavailable"))
        XCTAssertTrue(placeholders.contains("Deleted source path"))

        let model = makeModel(paths: [root, unavailable], initial: .path(unavailable.id))
        XCTAssertEqual(model.primaryAction, .switchPath)
    }

    func testLiveStaleColdLoadDoesNotPublishIntoReplacedPath() async {
        let id = UUID()
        let old = path(id: id, savedAt: Date(timeIntervalSinceReferenceDate: 1), turns: nil)
        let newer = path(id: id, savedAt: Date(timeIntervalSinceReferenceDate: 2), turns: nil)
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [old],
            initialSelection: .path(id),
            loadPath: { sessionID in
                try await Task.sleep(for: .milliseconds(30))
                var loaded = old
                loaded.turns = [self.turn(sessionID: sessionID, ordinal: 1)]
                return loaded
            },
            performBranch: { _ in },
            performSwitch: { _ in }
        )

        model.requestPathLoad(id)
        await waitUntil { model.pathLoadStates[id] == .loading }
        model.publishResolvedTree(phase: .ready, paths: [newer])
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.paths.first?.turns)
        XCTAssertEqual(model.paths.first?.savedAt, newer.savedAt)
    }

    func testRefreshOnlyRetriesFailedColdLoad() async {
        let inactive = path(turns: nil)
        var attempts = 0
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [inactive],
            initialSelection: .path(inactive.id),
            loadPath: { _ in
                attempts += 1
                throw TestError.failed
            },
            performBranch: { _ in },
            performSwitch: { _ in }
        )

        model.refreshFailedPath(inactive.id)
        XCTAssertEqual(attempts, 0)
        model.requestPathLoad(inactive.id)
        await waitUntil {
            if case .failed = model.pathLoadStates[inactive.id] { return true }
            return false
        }
        model.refreshFailedPath(inactive.id)
        await waitUntil { attempts == 2 }
        XCTAssertEqual(attempts, 2)
    }

    func testNavigationChangesSelectionAndBranchAnywayEnterSubmits() {
        let id = UUID()
        let changed = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 1,
            impact: .modified(paths: ["a.swift"])
        )
        let selected = turn(sessionID: id, ordinal: 1, safetySummary: changed)
        let active = path(id: id, isActive: true, turns: [selected])
        let model = makeModel(paths: [active], initial: .path(id))

        XCTAssertEqual(model.reduce(key: .right), .handled)
        XCTAssertEqual(model.reduce(key: .right), .handled)
        XCTAssertEqual(model.selectedID, .turn(selected.id))
        XCTAssertEqual(model.primaryAction, .branch(title: "Branch anyway"))
        XCTAssertEqual(model.reduce(key: .enter), .submit)
    }

    func testStaleSubmissionRefreshesDisplayedSafetySummary() async {
        let id = UUID()
        let original = turn(sessionID: id, ordinal: 1)
        let refreshedSummary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 2,
            impact: .modified(paths: ["changed.swift"])
        )
        let refreshed = turn(
            sessionID: id,
            turnID: original.id.turnID,
            ordinal: 1,
            safetySummary: refreshedSummary
        )
        let active = path(id: id, isActive: true, turns: [original])
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(original.id),
            refreshActiveTurn: { _ in refreshed },
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in XCTFail("Stale selection must not branch") },
            performSwitch: { _ in }
        )

        let didSubmit = await model.submit()
        XCTAssertFalse(didSubmit)
        XCTAssertTrue(model.staleSelection)
        XCTAssertEqual(model.selectedTurn?.safetySummary, refreshedSummary)
        XCTAssertEqual(model.primaryAction, .branch(title: "Branch anyway"))
        XCTAssertEqual(model.reduce(key: .enter), .handled)
        model.select(.turn(refreshed.id))
        XCTAssertFalse(model.staleSelection)
        XCTAssertEqual(model.reduce(key: .enter), .submit)
    }

    func testEscapeIgnoredDuringActualSubmission() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        var continuation: CheckedContinuation<Void, Error>?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            },
            performSwitch: { _ in }
        )

        let submission = Task { await model.submit() }
        await waitUntil { model.operation == .branching }
        XCTAssertEqual(model.reduce(key: .escape), .ignored)
        continuation?.resume()
        let didSubmit = await submission.value
        XCTAssertTrue(didSubmit)
    }

    func testChildSavedRecoveryUsesSwitchPathAndTerminalStateCanDismiss() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let childID = UUID()
        var switchedID: UUID?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                throw AgentBranchOperationError.childSavedButNotOpened(sessionID: childID)
            },
            performSwitch: { switchedID = $0 }
        )
        let didSubmit = await model.submit()
        XCTAssertFalse(didSubmit)
        XCTAssertEqual(model.operation, .childSavedNotOpened(sessionID: childID))
        XCTAssertEqual(model.reduce(key: .escape), .dismiss)
        let didOpen = await model.openCreatedBranch()
        XCTAssertTrue(didOpen)
        XCTAssertEqual(switchedID, childID)
        XCTAssertEqual(model.operation, .idle)
    }

    func testNativeIndeterminateIsTerminalAndDismissable() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                throw AgentBranchOperationError.nativeIndeterminate(
                    provider: .codexExec,
                    knownChildID: "child"
                )
            },
            performSwitch: { _ in }
        )
        let didSubmit = await model.submit()
        XCTAssertFalse(didSubmit)
        guard case let .nativeIndeterminate(message) = model.operation else {
            return XCTFail("Expected terminal indeterminate state")
        }
        XCTAssertTrue(message.contains("unverified"))
        XCTAssertEqual(model.reduce(key: .escape), .dismiss)

        let state = AgentConversationTreePickerState()
        state.present(AgentConversationTreePresentationRequest(
            id: UUID(),
            tabID: UUID(),
            initialSelection: .latestCompletedTurn,
            model: model
        ))
        state.dismiss()
        XCTAssertNil(state.request)
    }

    func testConcurrentSubmitClaimsOperationBeforeSuspension() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        var invocationCount = 0
        var continuation: CheckedContinuation<Void, Never>?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                invocationCount += 1
                await withCheckedContinuation { continuation = $0 }
            },
            performSwitch: { _ in }
        )

        let first = Task { await model.submit() }
        await waitUntil { model.operation == .branching }
        let second = await model.submit()
        XCTAssertFalse(second)
        XCTAssertEqual(invocationCount, 1)
        continuation?.resume()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(model.operation, .idle)
    }

    func testSuccessfulSubmissionExitsActiveOperationBeforeSheetDismissal() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        var continuation: CheckedContinuation<Void, Never>?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                await withCheckedContinuation { continuation = $0 }
            },
            performSwitch: { _ in }
        )
        let request = AgentConversationTreePresentationRequest(
            id: UUID(),
            tabID: UUID(),
            initialSelection: .turn(selected.id.turnID),
            model: model
        )
        let state = AgentConversationTreePickerState()
        state.present(request)

        let submission = Task { await model.submit() }
        await waitUntil { model.operation == .branching }
        XCTAssertNil(state.dismiss())
        XCTAssertNotNil(state.request)
        continuation?.resume()
        let succeeded = await submission.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.operation, .idle)
        XCTAssertEqual(state.dismiss(), request.id)
        XCTAssertNil(state.request)
    }

    func testPinnedSourceRejectsRefreshBranchAndSwitchAfterGenerationChanges() async throws {
        let active = activePath()
        let inactive = path(turns: nil)
        var valid = true
        var loadCount = 0
        var branchCount = 0
        var switchCount = 0
        let selected = try XCTUnwrap(active.turns?.first)
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active, inactive],
            initialSelection: .turn(selected.id),
            loadPath: { _ in
                loadCount += 1
                throw TestError.failed
            },
            performBranch: { _ in branchCount += 1 },
            performSwitch: { _ in switchCount += 1 },
            sourceIsValid: { valid }
        )
        valid = false

        model.requestPathLoad(inactive.id)
        let branchResult = await model.submit()
        XCTAssertFalse(branchResult)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(branchCount, 0)
        XCTAssertEqual(switchCount, 0)
        XCTAssertTrue(model.staleSelection)

        model.select(.path(inactive.id))
        let switchResult = await model.submit()
        XCTAssertFalse(switchResult)
        XCTAssertEqual(switchCount, 0)
    }

    func testActionableActiveTurnOwnsFooterButtonAndOperationSafety() async {
        let turnID = UUID()
        let parentID = UUID()
        let activeID = UUID()
        let parentSummary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 0,
            impact: .readOnly,
            sourceOwnedOracleChatCount: 1
        )
        let activeSummary = AgentBranchSafetySummary(
            retainedTurnCount: 1,
            omittedTurnCount: 2,
            impact: .modified(paths: ["active.swift"]),
            sourceOwnedOracleChatCount: 3
        )
        let parentTurn = turn(
            sessionID: parentID,
            turnID: turnID,
            ordinal: 1,
            safetySummary: parentSummary
        )
        let activeTurn = turn(
            sessionID: activeID,
            turnID: turnID,
            ordinal: 1,
            safetySummary: activeSummary
        )
        let parent = path(id: parentID, turns: [parentTurn])
        let active = path(
            id: activeID,
            sourceID: parentID,
            sourceTurnID: turnID,
            sourceOrdinal: 1,
            isActive: true,
            turns: [activeTurn]
        )
        var submittedSummary: AgentBranchSafetySummary?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [parent, active],
            initialSelection: .turn(activeTurn.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { submittedSummary = $0.safetySummary },
            performSwitch: { _ in }
        )

        XCTAssertEqual(model.displayedSafetySummary, activeSummary)
        XCTAssertEqual(model.primaryAction, .branch(title: "Branch anyway"))
        let submitted = await model.submit()
        XCTAssertTrue(submitted)
        XCTAssertEqual(submittedSummary, activeSummary)
    }

    func testInitialExpansionFollowsActualActiveAncestorChain() {
        let rootID = UUID()
        let childID = UUID()
        let activeID = UUID()
        let rootTurnID = UUID()
        let childTurnID = UUID()
        let root = path(
            id: rootID,
            turns: [turn(sessionID: rootID, turnID: rootTurnID, ordinal: 1)]
        )
        let child = path(
            id: childID,
            sourceID: rootID,
            sourceTurnID: rootTurnID,
            sourceOrdinal: 1,
            turns: [turn(sessionID: childID, turnID: childTurnID, ordinal: 2)]
        )
        let active = path(
            id: activeID,
            sourceID: childID,
            sourceTurnID: childTurnID,
            sourceOrdinal: 2,
            isActive: true,
            turns: []
        )

        let model = makeModel(paths: [root, child, active], initial: .path(activeID))
        XCTAssertTrue(model.expandedIDs.contains(.path(rootID)))
        XCTAssertTrue(model.expandedIDs.contains(.path(childID)))
        XCTAssertTrue(model.expandedIDs.contains(.path(activeID)))
        XCTAssertTrue(model.expandedIDs.contains(.turn(.init(
            sessionID: rootID,
            turnID: rootTurnID
        ))))
        XCTAssertTrue(model.expandedIDs.contains(.turn(.init(
            sessionID: childID,
            turnID: childTurnID
        ))))
    }

    func testThreeGenerationCoalescingRehomesGrandchildToCanonicalTurn() {
        let turnID = UUID()
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let rootTurn = turn(sessionID: rootID, turnID: turnID, ordinal: 1)
        let childTurn = turn(sessionID: childID, turnID: turnID, ordinal: 1)
        let grandchildTurn = turn(sessionID: grandchildID, turnID: turnID, ordinal: 1)
        let root = path(id: rootID, turns: [rootTurn])
        let child = path(
            id: childID,
            sourceID: rootID,
            sourceTurnID: turnID,
            sourceOrdinal: 1,
            turns: [childTurn]
        )
        let grandchild = path(
            id: grandchildID,
            sourceID: childID,
            sourceTurnID: turnID,
            sourceOrdinal: 1,
            turns: [grandchildTurn]
        )

        let rootNode = AgentConversationTreeTopology.makeNodes(paths: [root, child, grandchild])[0]
        let canonicalTurn = rootNode.children[0]
        XCTAssertTrue(canonicalTurn.children.contains { $0.id == .path(childID) })
        XCTAssertTrue(canonicalTurn.children.contains { $0.id == .path(grandchildID) })
        guard let childNode = canonicalTurn.children.first(where: { $0.id == .path(childID) }) else {
            return XCTFail("Expected coalesced child path")
        }
        XCTAssertTrue(childNode.children.isEmpty)
    }

    func testUnavailableSourcePlaceholderKeepsSurvivingChildSwitchableAtOrdinal() async {
        let rootID = UUID()
        let childID = UUID()
        let root = path(id: rootID, turns: [])
        let child = path(
            id: childID,
            sourceID: rootID,
            sourceOrdinal: 4,
            evidence: .deletedSource,
            turns: []
        )
        let nodes = AgentConversationTreeTopology.makeNodes(paths: [root, child])
        let missing = nodes[0].children[0]
        XCTAssertEqual(missing.id, .missingTurn(sessionID: rootID, ordinal: 4))
        XCTAssertEqual(missing.children[0].id, .sourcePlaceholder(sessionID: childID))
        XCTAssertEqual(missing.children[0].children[0].id, .path(childID))

        var switched: UUID?
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [root, child],
            initialSelection: .path(childID),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in },
            performSwitch: { switched = $0 }
        )
        XCTAssertEqual(model.primaryAction, .switchPath)
        let submitted = await model.submit()
        XCTAssertTrue(submitted)
        XCTAssertEqual(switched, childID)
    }

    func testDeletedMissingParentBecomesPlaceholderRootWithCorrectOrdinal() {
        let deletedParentID = UUID()
        let childID = UUID()
        let child = path(
            id: childID,
            sourceID: deletedParentID,
            sourceOrdinal: 3,
            evidence: .deletedSource,
            turns: []
        )

        let roots = AgentConversationTreeTopology.makeNodes(paths: [child])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].id, .sourcePlaceholder(sessionID: childID))
        XCTAssertEqual(roots[0].children[0].id, .missingTurn(
            sessionID: deletedParentID,
            ordinal: 3
        ))
        XCTAssertEqual(roots[0].children[0].children[0].id, .path(childID))
        let model = makeModel(paths: [child], initial: .path(childID))
        XCTAssertEqual(model.primaryAction, .switchPath)
    }

    func testLazyPublicationReconcilesReplySelectionToCanonicalAncestor() async {
        let turnID = UUID()
        let rootID = UUID()
        let activeID = UUID()
        let root = path(id: rootID, turns: nil)
        let activeTurn = turn(sessionID: activeID, turnID: turnID, ordinal: 1)
        let active = path(
            id: activeID,
            sourceID: rootID,
            sourceTurnID: turnID,
            sourceOrdinal: 1,
            isActive: true,
            turns: [activeTurn]
        )
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [root, active],
            initialSelection: .turn(activeTurn.id),
            loadPath: { sessionID in
                self.path(
                    id: sessionID,
                    turns: [self.turn(sessionID: sessionID, turnID: turnID, ordinal: 1)]
                )
            },
            performBranch: { _ in },
            performSwitch: { _ in }
        )

        model.requestPathLoad(rootID)
        await waitUntil { model.pathLoadStates[rootID] == .loaded }
        XCTAssertEqual(
            model.selectedID,
            .turn(.init(sessionID: rootID, turnID: turnID))
        )
        XCTAssertTrue(model.expandedIDs.contains(.path(rootID)))
    }

    func testOutlineProgrammaticRestoreDoesNotClearStaleOrStartLoad() async throws {
        let inactive = path(turns: nil)
        let loaded = path(
            id: inactive.id,
            savedAt: inactive.savedAt,
            turns: [turn(sessionID: inactive.id, ordinal: 1)]
        )
        var loadCount = 0
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [inactive],
            initialSelection: .path(inactive.id),
            loadPath: { _ in
                loadCount += 1
                return loaded
            },
            performBranch: { _ in },
            performSwitch: { _ in }
        )
        model.markSelectionStale()
        model.expandedIDs.insert(.path(inactive.id))
        let host = NSHostingView(
            rootView: AgentConversationTreeOutlineView(model: model) { _ in }
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(findOutline(in: host) as? AgentConversationTreeOutlineHost)
        let coordinator = try XCTUnwrap(outline.bridgeCoordinator)
        let appliedCount = coordinator.synchronizationApplyCount
        let reloadCount = coordinator.topologyReloadCount
        coordinator.synchronize(outline)
        coordinator.synchronize(outline)

        XCTAssertEqual(coordinator.synchronizationApplyCount, appliedCount)
        XCTAssertEqual(coordinator.topologyReloadCount, reloadCount)
        XCTAssertTrue(model.staleSelection)
        XCTAssertEqual(model.selectedID, .path(inactive.id))
        XCTAssertEqual(loadCount, 0)

        let topologyReloadsBeforeLoading = coordinator.topologyReloadCount
        let appliesBeforeLoading = coordinator.synchronizationApplyCount
        XCTAssertEqual(outline.keyHandler?(.right, false), true)
        XCTAssertEqual(coordinator.topologyReloadCount, topologyReloadsBeforeLoading)
        XCTAssertGreaterThan(coordinator.synchronizationApplyCount, appliesBeforeLoading)
        await waitUntil { model.pathLoadStates[inactive.id] == .loaded }
        coordinator.synchronize(outline)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(coordinator.topologyReloadCount, topologyReloadsBeforeLoading + 1)
        XCTAssertTrue(model.staleSelection, "Expansion/load is not a new selection activation")
        XCTAssertEqual(model.selectedID, .path(inactive.id))

        XCTAssertEqual(outline.keyHandler?(.right, false), true)
        XCTAssertFalse(model.staleSelection)
        let loadedTurnID = try XCTUnwrap(loaded.turns?.first?.id)
        XCTAssertEqual(model.selectedID, .turn(loadedTurnID))
        XCTAssertEqual(loadCount, 1, "Keyboard selection must not restart the path load")
    }

    func testOutlineKeyHandlerDoesNotRetainCoordinatorAndDismantleClearsHandler() {
        let active = activePath()
        let model = makeModel(paths: [active], initial: .path(active.id))
        var keyResults: [AgentConversationTreePickerModel.KeyResult] = []
        weak var weakCoordinator: AgentConversationTreeOutlineView.Coordinator?

        autoreleasepool {
            var host: NSHostingView<AgentConversationTreeOutlineView>? = NSHostingView(
                rootView: AgentConversationTreeOutlineView(model: model) {
                    keyResults.append($0)
                }
            )
            host?.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            host?.layoutSubtreeIfNeeded()

            guard let unwrappedHost = host,
                  let outline = findOutline(in: unwrappedHost) as? AgentConversationTreeOutlineHost,
                  let coordinator = outline.bridgeCoordinator,
                  let scroll = outline.enclosingScrollView
            else {
                return XCTFail("Expected production outline bridge")
            }
            weakCoordinator = coordinator
            XCTAssertTrue(outline.delegate === coordinator)
            XCTAssertTrue(outline.dataSource === coordinator)
            XCTAssertNotNil(outline.keyHandler)

            let handled = outline.keyHandler?(.right, false)
            XCTAssertEqual(handled, true)
            XCTAssertEqual(keyResults, [.handled])
            XCTAssertNotEqual(model.selectedID, .path(active.id))

            AgentConversationTreeOutlineView.dismantleNSView(
                scroll,
                coordinator: coordinator
            )
            XCTAssertNil(outline.keyHandler)
            XCTAssertNil(outline.bridgeCoordinator)
            XCTAssertNil(outline.delegate)
            XCTAssertNil(outline.dataSource)
            host = nil
        }
        XCTAssertNil(weakCoordinator)
    }

    func testOpenCreatedBranchFailurePreservesRecoveryIDWithoutBranchingAgain() async throws {
        let active = activePath()
        let selected = try XCTUnwrap(active.turns?.first)
        let childID = UUID()
        var branchCount = 0
        var switchedIDs: [UUID] = []
        let model = AgentConversationTreePickerModel(
            phase: .ready,
            paths: [active],
            initialSelection: .turn(selected.id),
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in
                branchCount += 1
                throw AgentBranchOperationError.childSavedButNotOpened(sessionID: childID)
            },
            performSwitch: { sessionID in
                switchedIDs.append(sessionID)
                throw TestError.failed
            }
        )
        let submitted = await model.submit()
        let firstOpen = await model.openCreatedBranch()
        let secondOpen = await model.openCreatedBranch()
        XCTAssertFalse(submitted)
        XCTAssertFalse(firstOpen)
        XCTAssertFalse(secondOpen)
        XCTAssertEqual(model.operation, .childSavedNotOpened(sessionID: childID))
        XCTAssertEqual(branchCount, 1, "Recovery must never invoke the branch callback again")
        XCTAssertEqual(switchedIDs, [childID, childID])
    }

    func testRepeatedPresentationIncrementsFocusGeneration() {
        let state = AgentConversationTreePickerState()
        let active = activePath()
        let first = AgentConversationTreePresentationRequest(
            id: UUID(),
            tabID: UUID(),
            initialSelection: .latestCompletedTurn,
            model: makeModel(paths: [active], initial: nil)
        )
        state.present(first)
        state.focusOrPresent(first)
        XCTAssertEqual(state.focusGeneration, 1)
    }

    func testHostedOutlineContainsNativeOutlineRowsAndRoutesSelection() throws {
        let active = activePath()
        let model = makeModel(paths: [active], initial: .path(active.id))
        let host = NSHostingView(
            rootView: AgentConversationTreeOutlineView(
                model: model,
                focusGeneration: 1
            ) { _ in }
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(findOutline(in: host))
        XCTAssertGreaterThanOrEqual(outline.numberOfRows, 2)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertNotEqual(model.selectedID, .path(active.id))
    }

    private func makeModel(
        paths: [AgentConversationTreePickerPath],
        initial: AgentConversationTreeNode.ID?,
        phase: AgentConversationTreePickerModel.Phase = .ready
    ) -> AgentConversationTreePickerModel {
        AgentConversationTreePickerModel(
            phase: phase,
            paths: paths,
            initialSelection: initial,
            loadPath: { _ in throw TestError.failed },
            performBranch: { _ in },
            performSwitch: { _ in }
        )
    }

    private func activePath() -> AgentConversationTreePickerPath {
        let id = UUID()
        return path(id: id, isActive: true, turns: [turn(sessionID: id, ordinal: 1)])
    }

    private func path(
        id: UUID = UUID(),
        sourceID: UUID? = nil,
        sourceTurnID: UUID? = nil,
        sourceOrdinal: Int? = nil,
        isActive: Bool = false,
        savedAt: Date = .distantPast,
        evidence: AgentConversationTreePickerPath.Evidence = .available,
        turns: [AgentConversationTreePickerTurn]? = []
    ) -> AgentConversationTreePickerPath {
        AgentConversationTreePickerPath(
            id: id,
            name: isActive ? "Current path" : "Branch",
            savedAt: savedAt,
            sourceSessionID: sourceID,
            sourceTurnID: sourceTurnID,
            sourceTurnOrdinal: sourceOrdinal,
            isActive: isActive,
            isOpenElsewhere: false,
            evidence: evidence,
            turns: turns
        )
    }

    private func turn(
        sessionID: UUID,
        turnID: UUID = UUID(),
        ordinal: Int,
        prompt: String = "Prompt",
        isCompleted: Bool = true,
        safetySummary: AgentBranchSafetySummary? = nil
    ) -> AgentConversationTreePickerTurn {
        let checkpoint = AgentBranchCheckpoint(
            turnID: turnID,
            status: .completed,
            sideEffect: .readOnly,
            nativeRef: .codexTurn(id: turnID.uuidString),
            recordedAt: .distantPast
        )
        return AgentConversationTreePickerTurn(
            id: .init(sessionID: sessionID, turnID: turnID),
            ordinal: ordinal,
            prompt: prompt,
            conclusion: "Conclusion",
            availability: .available(checkpoint),
            safetySummary: safetySummary ?? AgentBranchSafetySummary(
                retainedTurnCount: ordinal,
                omittedTurnCount: 0,
                impact: .readOnly
            ),
            isCompleted: isCompleted
        )
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let outline = findOutline(in: child) { return outline }
        }
        return nil
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for picker state")
    }

    private enum TestError: Error {
        case failed
    }
}
