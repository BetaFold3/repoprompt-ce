import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless restart Phase 4 reconciliation seams: Codex controller-owned observation, the Claude
/// dangling-resume disposition, and the DataService history-import commit and stale-snapshot fence.
/// Fixtures only: no provider process, home directory or live transport is touched.
@MainActor
final class AgentRecoveryReconciliationTests: XCTestCase {
    // MARK: Codex observation (pure parsing)

    func testCodexObservationReportsOnlyTheExpectedTurnsOwnTerminalStatus() {
        let turns: [[String: Any]] = [
            ["id": "turn-latest", "status": "completed"],
            [
                "id": "turn-expected",
                "status": "completed",
                "items": [
                    ["id": "u1", "type": "userMessage"],
                    ["id": "a1", "type": "agentMessage", "text": "Done."]
                ]
            ]
        ]
        let observation = CodexNativeSessionController.recoveryObservation(
            threadID: "thread-1",
            expectedTurnID: "turn-expected",
            turns: turns,
            source: .turnsList,
            transportGeneration: 3
        )
        XCTAssertEqual(observation.turnID, "turn-expected")
        XCTAssertEqual(observation.terminal, .completed)
        XCTAssertEqual(observation.items, [
            .init(nativeItemID: "u1", kind: .userMessage, text: nil),
            .init(nativeItemID: "a1", kind: .agentMessage, text: "Done.")
        ])
        XCTAssertEqual(observation.transportGeneration, 3)
    }

    func testCodexObservationNeverInfersCompletionFromLatestIdleOrAmbiguousTurns() {
        func observe(_ turns: [[String: Any]]) -> CodexRecoveryObservation {
            CodexNativeSessionController.recoveryObservation(
                threadID: "thread-1",
                expectedTurnID: "turn-expected",
                turns: turns,
                source: .threadRead,
                transportGeneration: 1
            )
        }
        let missing = observe([["id": "turn-latest", "status": "completed"]])
        XCTAssertEqual(missing.terminal, .unconfirmed, "the latest turn is never evidence")
        XCTAssertNil(missing.turnID)
        XCTAssertNil(missing.items)

        let running = observe([["id": "turn-expected", "status": "inProgress"]])
        XCTAssertEqual(running.terminal, .unconfirmed)

        let ambiguous = observe([["id": "turn-expected", "status": "completed"], ["id": "turn-expected", "status": "failed"]])
        XCTAssertEqual(ambiguous.terminal, .unconfirmed)

        let interrupted = observe([["id": "turn-expected", "status": "interrupted", "error": ["message": "Stopped by user"]]])
        XCTAssertEqual(interrupted.terminal, .interrupted)
        XCTAssertEqual(interrupted.abortDetail, "Stopped by user")

        let withTool = observe([[
            "id": "turn-expected",
            "status": "completed",
            "items": [["id": "a1", "type": "agentMessage", "text": "x"], ["id": "c1", "type": "commandExecution"]]
        ]])
        XCTAssertEqual(withTool.terminal, .completed)
        XCTAssertNil(withTool.items, "unsupported items make the list unavailable, never partial")

        let duplicateItem = observe([[
            "id": "turn-expected",
            "status": "completed",
            "items": [["id": "a1", "type": "agentMessage", "text": "x"], ["id": "a1", "type": "agentMessage", "text": "y"]]
        ]])
        XCTAssertNil(duplicateItem.items)
    }

    // MARK: Codex observation (controller gate)

    func testCodexObservationRequiresARegisteredTransportAndOnlyReads() async throws {
        let requests = ReconciliationRequestLog()
        let client = CodexAppServerClient(mcpHost: ServerNetworkManager.shared, livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            options: CodexNativeSessionController.Options(
                requestTimeout: 5,
                configOverridesProvider: { [:] },
                launchEnvironmentProvider: { [:] },
                approvalPolicyProvider: { .never },
                sandboxModeProvider: { .readOnly },
                approvalReviewerProvider: { .user },
                authTokensRefreshHandler: nil
            ),
            requestExecutor: { method, _, _ in
                requests.append(method)
                return ["data": [["id": "turn-expected", "status": "failed", "error": ["message": "boom"]]]]
            }
        )

        do {
            _ = try await controller.observeRecovery(threadID: "thread-1", expectedTurnID: "turn-expected", timeout: 5)
            XCTFail("an unregistered transport must fail closed")
        } catch {
            XCTAssertEqual(error as? CodexRecoveryObservationError, .registeredTransportRequired)
        }
        do {
            _ = try await controller.observeRecovery(threadID: " ", expectedTurnID: "turn-expected", timeout: 5)
            XCTFail("missing identity")
        } catch {
            XCTAssertEqual(error as? CodexRecoveryObservationError, .missingIdentity)
        }
        XCTAssertEqual(requests.methods, [], "nothing was requested before the gates passed")

        controller.recoveryObservationTreatsTransportAsRegisteredForTesting = true
        let observation = try await controller.observeRecovery(threadID: "thread-1", expectedTurnID: "turn-expected", timeout: 5)
        XCTAssertEqual(observation.terminal, .failed)
        XCTAssertEqual(observation.abortDetail, "boom")
        XCTAssertEqual(observation.source, .turnsList)
        XCTAssertEqual(requests.methods, ["thread/turns/list"], "observation never resumes, starts, steers or interrupts")
        await client.stop()
    }

    // MARK: Claude dangling --resume

    func testClaudeResumeFailureRequiresAnExplicitChoiceOnlyForTheSuppressedConversation() {
        let failure = NativeAgentRuntimeControllerError.processNotRunning
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: nil),
            .retryFresh
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: "conv-1"),
            .requireExplicitChoice(conversationID: "conv-1"),
            "a recovery dispatch never falls back to an implicit fresh conversation"
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: "conv-2"),
            .retryFresh
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(
                after: NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart,
                existingSessionID: "conv-1",
                suppressedConversationID: "conv-1"
            ),
            .rethrow
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: nil, suppressedConversationID: nil),
            .rethrow
        )
    }

    // MARK: History import commit and stale-snapshot fence

    func testHistoryImportCommitsLedgerAndReceiptInOneSaveAndFencesStaleSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRecoveryReconciliationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tombstones = root.appendingPathComponent("AgentRecovery/v1/tombstones", isDirectory: true)
        let workspace = WorkspaceModel(
            name: "History",
            repoPaths: ["/tmp/repo"],
            customStoragePath: root.appendingPathComponent("workspace", isDirectory: true)
        )
        let service = AgentSessionDataService(tombstoneRoot: tombstones)
        let sessionID = UUID()
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: AgentSession(id: sessionID, workspaceID: workspace.id, name: "History"),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let files = try await service.listAgentSessions(for: workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        let initialBytes = try Data(contentsOf: fileURL)

        let commit = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: UUID(),
            providerRaw: "claude",
            conversationID: "conv-1",
            committedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1
        )
        let ledger = AgentSessionProviderHistoryRecovery(
            nativeItems: [.init(
                providerRaw: "claude",
                nativeSessionID: "conv-1",
                nativeEntryID: "entry-1",
                rowKindRaw: "assistantText",
                ordinal: 0,
                localItemID: UUID()
            )],
            lastImportCommit: commit
        )

        // A payload that does not carry exactly its own receipt is refused before any write.
        var mismatched = load.session
        mismatched.providerHistoryRecovery = AgentSessionProviderHistoryRecovery(nativeItems: ledger.nativeItems)
        do {
            _ = try await service.commitProviderHistoryImport(mismatched, for: workspace, importCommit: commit, persistenceState: load.persistenceState)
            XCTFail("receipt mismatch must refuse")
        } catch {
            XCTAssertEqual(error as? AgentSessionHistoryImportError, .receiptMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), initialBytes)

        var imported = load.session
        imported.providerHistoryRecovery = ledger
        let saved = try await service.commitProviderHistoryImport(imported, for: workspace, importCommit: commit, persistenceState: load.persistenceState)
        XCTAssertEqual(saved.disposition, .written)
        let reloaded = try await AgentSessionDataService(tombstoneRoot: tombstones).loadAgentSession(id: sessionID, for: workspace)
        XCTAssertEqual(reloaded?.providerHistoryRecovery, ledger, "ledger and receipt committed together")
        let committedBytes = try Data(contentsOf: fileURL)

        // An older snapshot (without the committed receipt) can never clobber the import.
        do {
            _ = try await service.saveAgentSession(load.session, for: workspace, persistenceState: saved.persistenceState)
            XCTFail("a stale snapshot must be refused")
        } catch {
            XCTAssertEqual(error as? AgentSessionHistoryImportError, .staleHistorySnapshot)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), committedBytes)

        // A later ordinary save that carries the committed receipt proceeds.
        var later = imported
        later.name = "History renamed"
        let laterCommit = try await service.saveAgentSession(later, for: workspace, persistenceState: saved.persistenceState)
        XCTAssertEqual(laterCommit.disposition, .written)
        let afterLater = try await AgentSessionDataService(tombstoneRoot: tombstones).loadAgentSession(id: sessionID, for: workspace)
        XCTAssertEqual(afterLater?.providerHistoryRecovery, ledger)
    }

    func testHistoryLedgerMemberIsOptionalAndRoundTripsUnknownMembers() throws {
        var session = AgentSession(id: UUID(), name: "Envelope")
        let empty = try JSONSerialization.jsonObject(with: AgentSessionDataCodec.encodeSession(session)) as? [String: Any]
        XCTAssertNil(empty?["providerHistoryRecovery"], "absent when empty")

        let json = #"{"nativeItems":[{"provider":"claude","nativeSessionID":"s","nativeEntryID":"e","rowKind":"assistantText","ordinal":0,"future":1}],"lastImportCommit":{"importID":"\#(UUID().uuidString)","provider":"claude","conversationID":"s","committedAt":0,"rowCount":0},"futureTop":"x"}"#
        let decoded = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extras["futureTop"], .string("x"))
        XCTAssertEqual(decoded.nativeItems.first?.extras["future"], .number(1))
        session.providerHistoryRecovery = decoded
        let reencoded = try JSONDecoder().decode(
            AgentSessionProviderHistoryRecovery.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(reencoded, decoded)
        XCTAssertEqual(
            AgentSessionProviderHistoryRecovery.rowKey(providerRaw: "a|b", nativeSessionID: "", nativeEntryID: "c", rowKindRaw: "d", ordinal: 1),
            "3:a|b|0:|1:c|1:d|1:1"
        )
    }

    // MARK: Dispatch baselines (model)

    private func baseline(
        dispatchID: UUID = UUID(),
        runAttemptID: UUID? = UUID(),
        generation: UInt64 = 0,
        conversationID: String? = "conv-1",
        userItemIDs: [UUID] = [UUID()],
        status: AgentSessionProviderHistoryRecovery.DispatchBaseline.Status = .captured
    ) -> AgentSessionProviderHistoryRecovery.DispatchBaseline {
        AgentSessionProviderHistoryRecovery.DispatchBaseline(
            dispatchID: dispatchID,
            runAttemptID: runAttemptID,
            transcriptResetGeneration: generation,
            providerRaw: "claude",
            conversationID: conversationID,
            userItemIDs: userItemIDs,
            file: status == .captured ? AgentRecoveryHistoryFileIdentity(device: 7, inode: 1 << 60, birthSeconds: 5, birthNanoseconds: 6) : nil,
            completeLineOffset: status == .captured ? 42 : 0,
            baselineCommitID: status == .captured ? UUID() : nil,
            profileName: ClaudeSessionHistoryReader.profileName,
            status: status,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
    }

    func testDispatchBaselinesRoundTripAndKeepUnreadableEntriesVerbatim() throws {
        let captured = baseline()
        let unsupported = baseline(conversationID: nil, status: .unsupported("no identity"))
        let ledger = AgentSessionProviderHistoryRecovery(dispatchBaselines: [captured, unsupported])
        XCTAssertNotNil(ledger.nilIfEmpty, "a baseline alone is persisted")
        let decoded = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.dispatchBaselines.first?.file?.inode, 1 << 60, "file identity survives exactly")
        XCTAssertEqual(decoded.dispatchBaselines.first?.cursor?.importID, captured.baselineCommitID)
        XCTAssertNil(decoded.dispatchBaselines.last?.cursor, "an unsupported capture is never a boundary")

        // Unknown status and an incomplete capture stay verbatim, never usable, never failing the session.
        let json = #"{"dispatchBaselines":[{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","completeLineOffset":0,"profile":"p","status":"futureStatus","recordedAtMs":0,"future":true},{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","completeLineOffset":0,"profile":"p","status":"captured","recordedAtMs":0}]}"#
        let partial = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(json.utf8))
        XCTAssertTrue(partial.dispatchBaselines.isEmpty)
        XCTAssertEqual(partial.unreadableDispatchBaselines.count, 2)
        let roundTripped = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(roundTripped, partial)
        XCTAssertNotNil(partial.nilIfEmpty)
    }

    // MARK: Association preflight (pure)

    private func observation(_ rows: [AgentProviderHistoryRow], conversationID: String = "conv-1") -> AgentProviderHistoryObservation {
        AgentProviderHistoryObservation(
            provider: .claude,
            conversationID: conversationID,
            rows: rows,
            file: nil,
            completeLineOffset: 0,
            completionConfirmed: false
        )
    }

    private func assistantRow(_ entry: String, text: String = "Done.") -> AgentProviderHistoryRow {
        AgentProviderHistoryRow(
            nativeSessionID: "conv-1",
            nativeEntryID: entry,
            rowKindRaw: "assistantText",
            ordinal: 0,
            item: AgentChatItem.assistant(text).replacingID(ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "fixture",
                components: [entry]
            ))
        )
    }

    private func nativeUserRow(_ entry: String) -> AgentProviderHistoryRow {
        AgentProviderHistoryRow(nativeSessionID: "conv-1", nativeEntryID: entry, rowKindRaw: "userText", ordinal: 0, item: nil)
    }

    private func preflight(
        _ observation: AgentProviderHistoryObservation,
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        runAttemptID: UUID?,
        generation: UInt64 = 0,
        transcript: AgentTranscript = .empty,
        items: [AgentChatItem],
        ledger: AgentSessionProviderHistoryRecovery? = nil,
        hasUnreadable: Bool = false
    ) -> AgentProviderHistoryAssociationRefusal? {
        AgentProviderHistoryAssociationPreflight.check(
            observation: observation,
            baseline: baseline,
            hasUnreadableBaselines: hasUnreadable,
            expectedRunAttemptID: runAttemptID,
            transcriptResetGeneration: generation,
            canonical: AgentProviderHistoryCanonicalView(transcript: transcript, suffixItems: items),
            ledger: ledger
        )
    }

    /// An explicit ledger association of the dispatch's local user item to a native user row of
    /// `conversationID` (review A P1-05: every user constituent must be positively associated).
    private func userAssociation(
        _ userItem: AgentChatItem,
        conversationID: String = "conv-1",
        rowKindRaw: String = "userText",
        localItemID: UUID?? = .none
    ) -> AgentSessionProviderHistoryRecovery.NativeItem {
        .init(
            providerRaw: "claude",
            nativeSessionID: conversationID,
            nativeEntryID: "u-\(userItem.id.uuidString)",
            rowKindRaw: rowKindRaw,
            ordinal: 0,
            localItemID: localItemID ?? userItem.id
        )
    }

    private func userLedger(_ userItem: AgentChatItem) -> AgentSessionProviderHistoryRecovery {
        AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem)])
    }

    func testPreflightRequiresPositiveAssociationOfEveryUserConstituent() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let steer = AgentChatItem.user("Also this")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let empty = observation([])
        XCTAssertEqual(
            preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem]),
            .nativeUserAssociationUnavailable,
            "no empty-output shortcut: an unassociated user item refuses"
        )
        for unassociated in [
            userAssociation(userItem, localItemID: .some(nil)),
            userAssociation(userItem, conversationID: "conv-other"),
            userAssociation(userItem, rowKindRaw: "assistantText")
        ] {
            XCTAssertEqual(
                preflight(
                    empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem],
                    ledger: AgentSessionProviderHistoryRecovery(nativeItems: [unassociated])
                ),
                .nativeUserAssociationUnavailable
            )
        }
        XCTAssertNil(preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem], ledger: userLedger(userItem)))
        // Every constituent: a steered second user item without its own association refuses.
        let both = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id, steer.id])
        XCTAssertEqual(
            preflight(empty, baseline: both, runAttemptID: runAttemptID, items: [userItem, steer], ledger: userLedger(userItem)),
            .nativeUserAssociationUnavailable
        )
        XCTAssertNil(preflight(
            empty, baseline: both, runAttemptID: runAttemptID, items: [userItem, steer],
            ledger: AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem), userAssociation(steer)])
        ))
    }

    func testPreflightRequiresTheAttemptsOwnCapturedBaseline() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let empty = observation([])
        XCTAssertEqual(preflight(empty, baseline: nil, runAttemptID: runAttemptID, items: [userItem]), .baselineUnavailable)
        XCTAssertEqual(
            preflight(empty, baseline: baseline(runAttemptID: runAttemptID, status: .unsupported("x")), runAttemptID: runAttemptID, items: [userItem]),
            .baselineUnavailable,
            "an unsupported capture is never backfilled"
        )
        XCTAssertEqual(
            preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem], hasUnreadable: true),
            .baselineUnavailable
        )
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: UUID(), items: [userItem]), .baselineTargetMismatch)
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: runAttemptID, generation: 1, items: [userItem]), .baselineTargetMismatch)
        XCTAssertEqual(
            preflight(observation([], conversationID: "conv-other"), baseline: captured, runAttemptID: runAttemptID, items: [userItem]),
            .baselineTargetMismatch
        )
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: []), .baselineTargetMismatch)
        XCTAssertNil(preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem], ledger: userLedger(userItem)))
    }

    func testPreflightNeverAssumesNativeUserOrLiveOutputAssociations() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        // A native user entry is never mapped to the local user item, even with a ledger whose
        // `localItemID == nil` entries look like "known" user rows.
        let nilLedger = AgentSessionProviderHistoryRecovery(nativeItems: [.init(
            providerRaw: "claude",
            nativeSessionID: "conv-1",
            nativeEntryID: "u0",
            rowKindRaw: "userText",
            ordinal: 0,
            localItemID: nil
        )])
        XCTAssertEqual(
            preflight(observation([nativeUserRow("u1"), assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID, items: [userItem], ledger: nilLedger),
            .nativeUserAssociationUnavailable
        )
        // A persisted live assistant row with a different local ID blocks the import, even with
        // identical text.
        let live = AgentChatItem.assistant("Done.")
        XCTAssertEqual(
            preflight(
                observation([assistantRow("a1", text: "Done.")]), baseline: captured, runAttemptID: runAttemptID,
                items: [userItem, live], ledger: userLedger(userItem)
            ),
            .canonicalOutputAssociationUnavailable
        )
        // Output before the dispatch's user item is not this dispatch's output.
        XCTAssertNil(preflight(
            observation([assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID,
            items: [live, userItem], ledger: userLedger(userItem)
        ))
        // An explicit ledger association of the live row passes, and the planner deduplicates.
        let associated = AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem), .init(
            providerRaw: "claude",
            nativeSessionID: "conv-1",
            nativeEntryID: "a0",
            rowKindRaw: "assistantText",
            ordinal: 0,
            localItemID: live.id
        )])
        XCTAssertNil(preflight(observation([assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID, items: [userItem, live], ledger: associated))
    }

    func testPreflightCannotLoseCompactedCanonicalOutput() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let compacted = AgentTranscriptTurn(
            request: AgentTranscriptRequestAnchor(from: userItem),
            retentionTier: .summary,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        var transcript = AgentTranscript.empty
        transcript.turns = [compacted]
        XCTAssertEqual(
            preflight(
                observation([assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID,
                transcript: transcript, items: [], ledger: userLedger(userItem)
            ),
            .canonicalOutputAssociationUnavailable,
            "a dispatch inside a compacted turn has output that cannot be enumerated"
        )
    }

    // MARK: Baseline producer and reconcile refusal (view model, real persistence)

    private let conversationID = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let qualified = AgentRecoveryActionQualification(
        sameConversationResume: true,
        historyReconciliation: true,
        freshClaudeConversation: true,
        safeRestart: true
    )

    @MainActor
    private struct ProducerHarness {
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let lane: AgentRecoverySessionLane
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let home: URL

        var historyFile: URL {
            home.appendingPathComponent("projects/-fixture-project", isDirectory: true)
                .appendingPathComponent("0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f.jsonl")
        }

        func appendHistory(_ objects: [[String: Any]]) throws {
            try FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = (try? Data(contentsOf: historyFile)) ?? Data()
            for object in objects {
                try data.append(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: historyFile)
        }

        func cursor() async -> AgentRecoveryHistoryCursor? {
            guard case let .success(.supported(record)) = await lane.readRecord() else { return nil }
            return record.historyCursor(providerRaw: "claude", conversationID: "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f")
        }

        func persisted() async throws -> AgentSession? {
            let id = try XCTUnwrap(session.activeAgentSessionID)
            return try await service.loadAgentSession(id: id, for: workspace)
        }
    }

    private func makeProducerHarness(
        windowID: Int,
        qualified isQualified: Bool = true,
        codexFactory: CodexAgentModeCoordinator.CodexControllerFactory? = nil
    ) async throws -> ProducerHarness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineWorkspace")
        let home = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineHome")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = AgentRecoveryStore(rootURL: recoveryRoot)
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(store: store, gate: gate, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            }
        )
        coordinator.startIfNeeded()
        guard await coordinator.awaitStartup() == .ready else { throw RecoveryLaneFixtureError.startupNotReady }
        let workspace = WorkspaceModel(name: "Baseline", repoPaths: [storageURL.path], customStoragePath: storageURL)
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            codexControllerFactoryWithComputerUse: codexFactory
        )
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator)
        viewModel.test_establishPersistenceWorkspace(workspace)
        if isQualified {
            viewModel.recoveryActionRunner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        }
        let homePath = home.path
        viewModel.test_recoveryClaudeHistoryHomes = { _ in [homePath] }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .claudeCode
        session.providerSessionID = conversationID
        session.appendItem(.user("Earlier turn"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(session.recoveryLane)
        return ProducerHarness(viewModel: viewModel, session: session, lane: lane, service: service, workspace: workspace, home: home)
    }

    private func historyEntry(_ type: String, uuid: String, parent: String?, text: String) -> [String: Any] {
        [
            "type": type,
            "uuid": uuid,
            "parentUuid": parent ?? NSNull(),
            "sessionId": conversationID,
            "message": ["role": type, "content": type == "user" ? text as Any : [["type": "text", "text": text]] as Any],
            "isSidechain": false
        ]
    }

    func testBaselineProducerIsInertWhenHistoryReconciliationIsNotQualified() async throws {
        let harness = try await makeProducerHarness(windowID: 4970, qualified: false)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .notCaptured)
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertTrue(admitted, "production keeps the ordinary send")
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, 0, "zero history lookups or reads")
        XCTAssertNil(harness.session.providerHistoryRecovery, "zero extra writes")
        XCTAssertNil(harness.session.pendingHistoryImportCommit)
        let cursor = await harness.cursor()
        XCTAssertNil(cursor)
    }

    func testBaselineCommitsAZeroRowReceiptBeforeAdmittingAndKeepsEachDispatchsBoundary() async throws {
        let harness = try await makeProducerHarness(windowID: 4971)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let firstSize = try UInt64(Data(contentsOf: harness.historyFile).count)
        let first = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let firstAdmission = await harness.viewModel.captureClaudeDispatchBaseline(first, session: harness.session)
        XCTAssertEqual(firstAdmission, .committed)
        let firstBaseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: first.dispatchID))
        XCTAssertEqual(firstBaseline.status, .captured)
        XCTAssertEqual(firstBaseline.completeLineOffset, firstSize)
        XCTAssertNotNil(firstBaseline.file)
        XCTAssertEqual(harness.session.committedHistoryImportID, firstBaseline.baselineCommitID, "the exact receipt committed before admission")
        XCTAssertNil(harness.session.pendingHistoryImportCommit)
        let persisted = try await harness.persisted()
        XCTAssertEqual(persisted?.providerHistoryRecovery?.dispatchBaselines, [firstBaseline], "a zero-row baseline is a real session commit")
        XCTAssertEqual(persisted?.providerHistoryRecovery?.lastImportCommit?.rowCount, 0)
        let seeded = await harness.cursor()
        XCTAssertEqual(seeded, firstBaseline.cursor, "the cursor is seeded only after the session commit")

        // The same dispatch re-entering admission reuses its boundary without reading again.
        let accessCount = harness.viewModel.test_recoveryClaudeHistoryAccessCount
        let repeated = await harness.viewModel.captureClaudeDispatchBaseline(first, session: harness.session)
        XCTAssertEqual(repeated, .alreadyRecorded)
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, accessCount)

        // A later dispatch records its own boundary; the first one and the existing cursor stay.
        try harness.appendHistory([historyEntry("assistant", uuid: "a1", parent: "u1", text: "ok")])
        let second = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let secondAdmission = await harness.viewModel.captureClaudeDispatchBaseline(second, session: harness.session)
        XCTAssertEqual(secondAdmission, .committed)
        let baselines = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaselines)
        XCTAssertEqual(baselines.count, 2)
        XCTAssertEqual(baselines.first, firstBaseline, "an older attempt's boundary is never overwritten")
        XCTAssertGreaterThan(baselines[1].completeLineOffset, firstBaseline.completeLineOffset)
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, firstBaseline.cursor, "the cursor is not the attempt-boundary authority")
    }

    func testMissingIdentityOrLocationIsRecordedUnsupportedAndNeverBackfilled() async throws {
        let harness = try await makeProducerHarness(windowID: 4972)
        harness.session.providerSessionID = nil
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let missingID = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        guard case .unsupported = missingID else { return XCTFail("expected unsupported, got \(missingID)") }
        XCTAssertTrue(missingID.admitsWrite, "the ordinary send proceeds")
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, 0)

        // The identity appearing later does not backfill this dispatch's boundary.
        harness.session.providerSessionID = conversationID
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let later = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(later, .alreadyRecorded)
        guard case .unsupported = harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.status else {
            return XCTFail("still unsupported")
        }

        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in [] }
        let noHome = await harness.viewModel.captureClaudeDispatchBaseline(
            AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()]),
            session: harness.session
        )
        guard case .unsupported = noHome else { return XCTFail("an unknown home is unsupported, never a guessed default") }
        let cursor = await harness.cursor()
        XCTAssertNil(cursor)
    }

    func testFailedInspectionIsNotAnAbsentFileBaseline() async throws {
        let harness = try await makeProducerHarness(windowID: 4973)
        try Data("not a directory".utf8).write(to: harness.home.appendingPathComponent("projects"))
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        guard case .unsupported = admission else { return XCTFail("expected unsupported, got \(admission)") }
        XCTAssertNil(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.cursor)
    }

    func testBaselinePersistenceFailureRefusesTheWrite() async throws {
        let harness = try await makeProducerHarness(windowID: 4974)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let files = try await harness.service.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        try FileManager.default.removeItem(at: fileURL)
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertFalse(admitted, "an enabled baseline that cannot be persisted sends zero bytes")
        let cursor = await harness.cursor()
        XCTAssertNil(cursor, "the cursor never moves ahead of the session commit")
    }

    func testReconcileRefusesWithoutAssociationsAndChangesNothing() async throws {
        let harness = try await makeProducerHarness(windowID: 4975)
        try harness.appendHistory([historyEntry("user", uuid: "u0", parent: nil, text: "Earlier turn")])
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .committed)
        // The live run persisted its own user and assistant rows; Claude wrote its own entries.
        harness.session.appendItem(userItem)
        harness.session.appendItem(.assistant("Done."))
        _ = await harness.viewModel.flushSave(for: harness.session.tabID)
        try harness.appendHistory([
            historyEntry("user", uuid: "u1", parent: "u0", text: "Do it"),
            historyEntry("assistant", uuid: "a1", parent: "u1", text: "Done.")
        ])
        let itemsBefore = harness.session.items.map(\.id)
        let ledgerBefore = harness.session.providerHistoryRecovery
        let cursorBefore = await harness.cursor()

        func action(runAttemptID: UUID?) -> AgentRecoveryAction {
            AgentRecoveryAction(
                actionID: UUID(),
                itemKey: AgentRecoveryCardKey(kind: .run, incarnationID: harness.lane.binding.incarnationID, transcriptResetGeneration: 0, entityID: "run"),
                kindRaw: AgentRecoveryActionKind.reconcileOnly.rawValue,
                expectedRevision: nil,
                incarnationID: harness.lane.binding.incarnationID,
                transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
                sourceIntentIDs: [],
                sourceRunAttemptID: runAttemptID,
                sourceInteractionID: nil,
                target: harness.viewModel.recoveryActionTarget(for: harness.session),
                text: nil,
                plannedUserItemID: nil,
                appInstanceID: UUID(),
                reservedAt: AgentRecoveryTimestamp(Date())
            )
        }
        let refused = await harness.viewModel.reconcileRecoveryHistory(
            action(runAttemptID: runAttemptID),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(
            refused,
            .associationUnavailable(.nativeUserAssociationUnavailable, AgentModeViewModel.recoveryAssociationText(.nativeUserAssociationUnavailable))
        )
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "zero transcript changes")
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "zero ledger changes")
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, cursorBefore, "no cursor advance")

        // Another attempt has no baseline of its own: refused before any history read.
        let accessCount = harness.viewModel.test_recoveryClaudeHistoryAccessCount
        let unavailable = await harness.viewModel.reconcileRecoveryHistory(
            action(runAttemptID: UUID()),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(unavailable, .associationUnavailable(.baselineUnavailable, AgentModeViewModel.recoveryAssociationText(.baselineUnavailable)))
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, accessCount)
    }

    @MainActor
    private final class ReconcileGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Review A P1-01 / B F3a at the view model: while an explicit recovery action of the session is
    /// between its reservation and its recorded outcome (here, inside its reconciliation), the
    /// scheduler's busy state and the workspace's new-session gate (also consulted by
    /// `runAlongsideOtherSessions`) report it, and both clear with the recorded outcome.
    func testInFlightRecoveryActionHoldsAutomaticWorkUntilItsOutcome() async throws {
        let harness = try await makeProducerHarness(windowID: 5080)
        let session = harness.session
        let workspaceID = harness.workspace.id
        XCTAssertFalse(harness.viewModel.scheduledSendHasUnresolvedRecovery(session))
        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy)
        XCTAssertFalse(harness.viewModel.hasUnresolvedRecoverySession(inWorkspace: workspaceID, excluding: UUID()))

        var revision: AgentRecoveryRecordRevision?
        if case let .success(.supported(record)) = await harness.lane.readRecord() { revision = record.revision }
        let request = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: AgentRecoveryCardKey(
                kind: .run,
                incarnationID: harness.lane.binding.incarnationID,
                transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
                entityID: UUID().uuidString
            ),
            kind: .reconcileOnly,
            expectedRevision: revision,
            target: harness.viewModel.recoveryActionTarget(for: session)
        )
        let gate = ReconcileGate()
        let performers = AgentRecoveryActionPerformers(reconcile: { _ in
            await gate.wait()
            return .nothingImported("none")
        }) { _, _ in .notDispatched("Reconcile never dispatches.") }
        let runner = harness.viewModel.recoveryActionRunner
        let lane = harness.lane
        let running = Task { await runner.perform(request, lane: lane, performers: performers) }
        var polls = 0
        while !gate.isWaiting, polls < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertTrue(gate.isWaiting, "the reconciliation is in flight")
        XCTAssertTrue(harness.viewModel.scheduledSendHasUnresolvedRecovery(session))
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy, "a due schedule waits")
        XCTAssertTrue(
            harness.viewModel.hasUnresolvedRecoverySession(inWorkspace: workspaceID, excluding: UUID()),
            "new sessions in the workspace stay paused, runAlongside included"
        )

        gate.open()
        let result = await running.value
        XCTAssertEqual(result, .completed(.notDispatched, reason: "none"))
        XCTAssertFalse(harness.viewModel.scheduledSendHasUnresolvedRecovery(session), "the hold ends with the recorded outcome")
        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy)
    }

    /// Review B F3b/F4 and A P1-06 at the row seam: Continue is offered only for an unresolved
    /// interruption of the lane's own reset generation whose input was handed off; Reconcile stays.
    func testRunRowOffersContinueOnlyForAnUnresolvedHandedOffInterruption() async throws {
        let harness = try await makeProducerHarness(windowID: 5081)
        let session = harness.session
        let generation = harness.lane.binding.transcriptResetGeneration
        let vm = harness.viewModel
        XCTAssertEqual(
            vm.recoveryRunActions(session: session, status: .interrupted, facts: .init(runTranscriptResetGeneration: generation)),
            [.continueTurn, .reconcileHistory]
        )
        XCTAssertEqual(vm.recoveryRunActions(session: session, status: .interrupted, facts: .init()), [.continueTurn, .reconcileHistory])
        for status: AgentRecoveryInterruptedTurn.Status in [.completedTailMayBeMissing, .failed, .cancelledByUser, .stopped, .unknown] {
            XCTAssertEqual(vm.recoveryRunActions(session: session, status: status, facts: .init()), [.reconcileHistory], "\(status)")
        }
        for facts in [
            AgentRecoveryCatalogActionFacts(resolvedByAction: true),
            AgentRecoveryCatalogActionFacts(runNeverHandedOff: true),
            AgentRecoveryCatalogActionFacts(runTranscriptResetGeneration: generation + 1)
        ] {
            XCTAssertEqual(vm.recoveryRunActions(session: session, status: .interrupted, facts: facts), [.reconcileHistory], "\(facts)")
        }
    }

    // MARK: Cold Codex recovery observation (coordinator transaction)

    private func codexObservation(
        turnID: String?,
        terminal: CodexRecoveryObservation.Terminal,
        items: [CodexRecoveryObservation.Item]?
    ) -> CodexRecoveryObservation {
        CodexRecoveryObservation(
            threadID: "thread-c",
            turnID: turnID,
            terminal: terminal,
            abortDetail: nil,
            items: items,
            source: .turnsList,
            transportGeneration: 1
        )
    }

    /// The existing producer harness as an idle Codex session after a relaunch (no controller), its
    /// factory handing out `controllers` in order and recording every creation.
    private func makeColdCodexHarness(
        windowID: Int,
        controllers: [LifecycleNoopCodexController]
    ) async throws -> (ProducerHarness, CodexObservationFactoryLog) {
        let log = CodexObservationFactoryLog(controllers)
        let harness = try await makeProducerHarness(windowID: windowID, codexFactory: { runID, _, _, workspacePath, permissionProfile, sessionProfile, taskLabelKind, _ in
            log.make(runID: runID, workspacePath: workspacePath, permissionProfile: permissionProfile, sessionProfile: sessionProfile, taskLabelKind: taskLabelKind)
        })
        harness.session.selectedAgent = .codexExec
        harness.session.codexConversationID = "thread-c"
        XCTAssertNil(harness.session.codexController, "cold: no controller after a relaunch")
        return (harness, log)
    }

    private func reconcileAction(_ harness: ProducerHarness, runAttemptID: UUID?) -> AgentRecoveryAction {
        AgentRecoveryAction(
            actionID: UUID(),
            itemKey: AgentRecoveryCardKey(kind: .run, incarnationID: harness.lane.binding.incarnationID, transcriptResetGeneration: 0, entityID: "run"),
            kindRaw: AgentRecoveryActionKind.reconcileOnly.rawValue,
            expectedRevision: nil,
            incarnationID: harness.lane.binding.incarnationID,
            transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
            sourceIntentIDs: [],
            sourceRunAttemptID: runAttemptID,
            sourceInteractionID: nil,
            target: harness.viewModel.recoveryActionTarget(for: harness.session),
            text: nil,
            plannedUserItemID: nil,
            appInstanceID: UUID(),
            reservedAt: AgentRecoveryTimestamp(Date())
        )
    }

    /// Cold relaunch: reconcile creates exactly one temporary controller through the existing
    /// factory (correlated by the action ID only), observes under the explicit durable scope, joins
    /// its shutdown, and never installs it, sets a run, or starts/resumes a thread. A verified
    /// completion is kept even when its items cannot be projected; a missing turn is unconfirmed.
    func testColdCodexReconcileObservesThroughATemporaryControllerAndJoinsItsCleanup() async throws {
        struct Row {
            let name: String
            let observed: (String) -> CodexRecoveryObservation
            let expected: (UUID) -> AgentRecoveryReconcileResult
        }
        let rows: [Row] = [
            Row(
                name: "completed-unsupported-items",
                observed: { _ in self.codexObservation(turnID: "turn-c", terminal: .completed, items: nil) },
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: 0) }
            ),
            Row(
                name: "missing-turn",
                observed: { _ in self.codexObservation(turnID: nil, terminal: .unconfirmed, items: nil) },
                expected: { _ in .nothingImported("Codex has no matching record of the interrupted turn.") }
            ),
            Row(
                name: "interrupted-unsupported-items",
                observed: { _ in self.codexObservation(turnID: "turn-c", terminal: .interrupted, items: nil) },
                expected: { _ in .nothingImported("Codex has no matching record of the interrupted turn.") }
            )
        ]
        for (index, row) in rows.enumerated() {
            let recorder = LifecycleRecorder()
            let controller = LifecycleNoopCodexController(recorder: recorder)
            controller.lifecycleLabel = "obs"
            controller.joinsRetirementBeforeSuccessor = true
            controller.recoveryObservationOutcome = .success(row.observed(row.name))
            let (harness, log) = try await makeColdCodexHarness(windowID: 4980 + index, controllers: [controller])
            let runAttemptID = UUID()
            let action = reconcileAction(harness, runAttemptID: runAttemptID)
            let itemsBefore = harness.session.items.map(\.id)
            let runIDBefore = harness.session.runID

            let result = await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: "turn-c")

            XCTAssertEqual(result, row.expected(runAttemptID), row.name)
            XCTAssertEqual(log.runIDs, [action.actionID], "\(row.name): one creation, correlated by the action ID only")
            let scope = AgentRuntimeSessionScope.session(AgentRuntimeSessionAssociation(
                lifecycle: harness.lane.binding,
                runAttemptID: runAttemptID,
                processRunID: nil
            ))
            XCTAssertEqual(controller.observationOwners, [scope], "\(row.name): explicit durable scope, no process run")
            XCTAssertEqual(recorder.events, ["codex:observe:obs", "codex:shutdown", "codex:shutdown-complete:obs"], row.name)
            XCTAssertTrue(controller.startReferences.isEmpty, "\(row.name): no thread start or resume")
            XCTAssertTrue(controller.sentTexts.isEmpty, row.name)
            XCTAssertNil(harness.session.codexController, "\(row.name): never installed on the session")
            XCTAssertEqual(harness.session.runID, runIDBefore, row.name)
            XCTAssertNil(harness.session.codexEventTask, row.name)
            // The shutdown already completed before the result; the retained retirement only
            // drops its entry on a later hop, and joining it performs nothing further.
            await harness.session.joinRuntimeRetirements()
            XCTAssertEqual(recorder.events, ["codex:observe:obs", "codex:shutdown", "codex:shutdown-complete:obs"], "\(row.name): cleanup joined")
            XCTAssertFalse(harness.session.hasPendingRuntimeRetirements, row.name)
            XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "\(row.name): zero transcript rows")
        }
    }

    /// Review A P1-04 / B F1: live Codex output already in the conversation has no native mapping, so
    /// projected observation rows that could duplicate it are withheld entirely (zero rows, zero
    /// ledger writes), while a confirmed completion stays honest. Without canonical output after the
    /// turn's user item the same rows import.
    func testCodexOverlappingCanonicalOutputImportsZeroRowsAndKeepsCompletion() async throws {
        struct Row {
            let name: String
            let terminal: CodexRecoveryObservation.Terminal
            let liveOutput: Bool
            let expected: (UUID) -> AgentRecoveryReconcileResult
        }
        let rows: [Row] = [
            Row(
                name: "completed-overlap",
                terminal: .completed,
                liveOutput: true,
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: 0) }
            ),
            Row(
                name: "interrupted-overlap",
                terminal: .interrupted,
                liveOutput: true,
                expected: { _ in .nothingImported(AgentModeViewModel.recoveryCodexOverlapText) }
            ),
            Row(
                name: "completed-no-overlap",
                terminal: .completed,
                liveOutput: false,
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: -1) }
            )
        ]
        for (index, row) in rows.enumerated() {
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            controller.joinsRetirementBeforeSuccessor = true
            controller.recoveryObservationOutcome = .success(codexObservation(
                turnID: "turn-c",
                terminal: row.terminal,
                items: [.init(nativeItemID: "item-1", kind: .agentMessage, text: "Done.")]
            ))
            let (harness, _) = try await makeColdCodexHarness(windowID: 5060 + index, controllers: [controller])
            let userItem = AgentChatItem.user("Do it")
            let live = AgentChatItem.assistant("Done.")
            let turnID = UUID()
            harness.session.transcript = AgentTranscript(turns: [AgentTranscriptTurn(
                id: turnID,
                request: AgentTranscriptRequestAnchor(from: userItem),
                responseSpans: [AgentTranscriptProviderResponseSpan(
                    providerTurnID: "turn-c",
                    startedAt: Date(),
                    activities: row.liveOutput ? [AgentTranscriptActivity(from: live)] : []
                )],
                startedAt: Date()
            )])
            let itemsBefore = harness.session.items.map(\.id)
            let ledgerBefore = harness.session.providerHistoryRecovery
            let runAttemptID = UUID()

            let result = await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: runAttemptID),
                session: harness.session,
                lane: harness.lane,
                codexTurnID: "turn-c",
                runTurnID: turnID
            )

            if case let .imported(completion, rowCount) = row.expected(runAttemptID), rowCount < 0 {
                // Control: whatever the projection yields, it imports (and completion is kept).
                guard case let .imported(actualCompletion, actualRows) = result else {
                    XCTFail("\(row.name): expected an import, got \(result)")
                    continue
                }
                XCTAssertEqual(actualCompletion, completion, row.name)
                XCTAssertGreaterThan(actualRows, 0, row.name)
                XCTAssertEqual(harness.session.items.count, itemsBefore.count + actualRows, "\(row.name): the observed output imports")
                continue
            }
            XCTAssertEqual(result, row.expected(runAttemptID), row.name)
            if row.liveOutput {
                XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "\(row.name): zero rows appended")
                XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "\(row.name): zero ledger writes")
            }
        }
    }

    /// Ownership cuts of the coordinator transaction: pending retirement, cleanup before the result,
    /// warm borrow, incompatible warm controller, busy session, a policy change or cancellation
    /// while observing.
    func testCodexObservationTransactionOwnershipCuts() async throws {
        let completed = codexObservation(turnID: "turn-c", terminal: .completed, items: nil)
        func observe(_ harness: ProducerHarness, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> CodexRecoveryObservation {
            try await harness.viewModel.codexCoordinator.observeRecovery(
                session: harness.session,
                actionID: UUID(),
                threadID: "thread-c",
                expectedTurnID: "turn-c",
                sourceRunAttemptID: nil,
                timeout: nil,
                isCurrent: isCurrent
            )
        }

        // A prior retirement on the tab is joined before anything is created; the result is held
        // until the temporary controller's shutdown completed.
        do {
            let recorder = LifecycleRecorder()
            let cold = LifecycleNoopCodexController(recorder: recorder)
            cold.lifecycleLabel = "cold"
            cold.joinsRetirementBeforeSuccessor = true
            cold.recoveryObservationOutcome = .success(completed)
            let shutdownGate = LifecycleAsyncGate()
            cold.shutdownGate = shutdownGate
            let (harness, log) = try await makeColdCodexHarness(windowID: 4990, controllers: [cold])
            let retirementGate = LifecycleAsyncGate()
            harness.session.retainRuntimeRetirement { await retirementGate.arriveAndWait() }
            let finished = LifecycleCompletionFlag()
            let observing = Task { @MainActor in
                defer { Task { await finished.set() } }
                return try await observe(harness)
            }
            await retirementGate.waitUntilArrived()
            XCTAssertEqual(log.runIDs.count, 0, "zero creations while a retirement is pending")
            await retirementGate.release()
            await shutdownGate.waitUntilArrived()
            XCTAssertEqual(log.runIDs.count, 1)
            let finishedDuringCleanup = await finished.isSet
            XCTAssertFalse(finishedDuringCleanup, "no result while the cleanup is unresolved")
            await shutdownGate.release()
            let observation = try await observing.value
            XCTAssertEqual(observation, completed)
            XCTAssertEqual(recorder.events, ["codex:observe:cold", "codex:shutdown", "codex:shutdown-complete:cold"])
        }

        // Warm: a compatible live controller is borrowed unchanged (zero creations, zero shutdowns);
        // an incompatible one is refused as stale and left alone.
        do {
            let probeRecorder = LifecycleRecorder()
            let probe = LifecycleNoopCodexController(recorder: probeRecorder)
            probe.recoveryObservationOutcome = .success(completed)
            let warmRecorder = LifecycleRecorder()
            let warm = LifecycleNoopCodexController(recorder: warmRecorder)
            warm.lifecycleLabel = "warm"
            warm.recoveryObservationOutcome = .success(completed)
            let (harness, log) = try await makeColdCodexHarness(windowID: 4991, controllers: [probe])
            _ = try await observe(harness)
            let inputs = try XCTUnwrap(log.calls.first)
            let session = harness.session
            session.codexController = warm
            session.codexControllerWorkspacePath = inputs.workspacePath
            session.codexControllerPermissionProfile = inputs.permissionProfile
            session.codexControllerSessionProfile = inputs.sessionProfile
            session.codexControllerTaskLabelKind = inputs.taskLabelKind

            let borrowed = try await observe(harness)
            XCTAssertEqual(borrowed, completed)
            XCTAssertEqual(log.calls.count, 1, "warm: zero creations")
            XCTAssertEqual(warmRecorder.events, ["codex:observe:warm"], "warm: never shut down")
            XCTAssertTrue(session.codexController === warm, "warm: left in place")

            session.codexControllerWorkspacePath = "/elsewhere"
            do {
                _ = try await observe(harness)
                XCTFail("an incompatible controller is never borrowed")
            } catch {
                XCTAssertEqual(error as? CodexRecoveryObservationError, .staleContext)
            }
            XCTAssertEqual(log.calls.count, 1, "incompatible: never silently replaced")
            XCTAssertEqual(warmRecorder.events, ["codex:observe:warm"], "incompatible: never invalidated")
            XCTAssertTrue(session.codexController === warm)

            session.runState = .running
            do {
                _ = try await observe(harness)
                XCTFail("a busy session acquires nothing")
            } catch {
                XCTAssertEqual(error as? CodexRecoveryObservationError, .sessionBusy)
            }
            session.runState = .idle
        }

        // A policy change or a cancellation while the cold observation awaits: nothing usable is
        // returned, and the temporary controller's cleanup is still joined.
        enum Cut: CaseIterable { case policyChanged, targetReplaced, cancelled }
        for (index, cut) in Cut.allCases.enumerated() {
            let recorder = LifecycleRecorder()
            let cold = LifecycleNoopCodexController(recorder: recorder)
            cold.lifecycleLabel = "cut"
            cold.joinsRetirementBeforeSuccessor = true
            cold.recoveryObservationOutcome = .success(completed)
            let gate = LifecycleAsyncGate()
            cold.observationGate = gate
            let (harness, _) = try await makeColdCodexHarness(windowID: 4992 + index, controllers: [cold])
            let current = CodexObservationCurrentFlag()
            let observing = Task { @MainActor in try await observe(harness, isCurrent: { current.value }) }
            await gate.waitUntilArrived()
            switch cut {
            case .policyChanged:
                harness.session.permissionProfile = harness.session.permissionProfile == .mcpSafeDefaults ? .userConfigured : .mcpSafeDefaults
            case .targetReplaced:
                current.value = false
            case .cancelled:
                observing.cancel()
            }
            await gate.release()
            do {
                _ = try await observing.value
                XCTFail("\(cut): nothing usable")
            } catch {
                switch cut {
                case .policyChanged, .targetReplaced:
                    XCTAssertEqual(error as? CodexRecoveryObservationError, .staleContext, "\(cut)")
                case .cancelled:
                    XCTAssertTrue(error is CancellationError, "\(cut): \(error)")
                }
            }
            XCTAssertEqual(recorder.events, ["codex:observe:cut", "codex:shutdown", "codex:shutdown-complete:cut"], "\(cut): cleanup joined")
            XCTAssertNil(harness.session.codexController, "\(cut)")
            await harness.session.joinRuntimeRetirements()
            XCTAssertEqual(recorder.events.count, 3, "\(cut): nothing left to clean up")
            XCTAssertFalse(harness.session.hasPendingRuntimeRetirements, "\(cut)")
        }
    }
}

/// The `isCurrent` answer a cold Codex observation test flips mid-observation.
@MainActor
private final class CodexObservationCurrentFlag {
    var value = true
}

/// Records the coordinator factory's creations for the cold Codex observation tests.
private final class CodexObservationFactoryLog {
    struct Call {
        let runID: UUID
        let workspacePath: String?
        let permissionProfile: AgentProviderPermissionProfile
        let sessionProfile: AgentSessionProfile
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    }

    private let controllers: [LifecycleNoopCodexController]
    private(set) var calls: [Call] = []

    var runIDs: [UUID] {
        calls.map(\.runID)
    }

    init(_ controllers: [LifecycleNoopCodexController]) {
        self.controllers = controllers
    }

    func make(
        runID: UUID,
        workspacePath: String?,
        permissionProfile: AgentProviderPermissionProfile,
        sessionProfile: AgentSessionProfile,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> any CodexSessionControlling {
        calls.append(Call(runID: runID, workspacePath: workspacePath, permissionProfile: permissionProfile, sessionProfile: sessionProfile, taskLabelKind: taskLabelKind))
        return controllers[min(calls.count - 1, controllers.count - 1)]
    }
}

private final class ReconciliationRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ method: String) {
        lock.lock()
        recorded.append(method)
        lock.unlock()
    }
}
