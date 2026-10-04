import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceCodemapStructureDiagnosticsTests: XCTestCase {
    private typealias Classifier = WorkspaceCodemapStructureDiagnosticClassifier
    private typealias Trace = WorkspaceCodemapStructureDiagnosticTrace

    // Identifying sentinels that must never reach a diagnostic record.
    private let sentinelRootID = UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000A001")!
    private let sentinelLifetimeID = UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000A002")!
    private let sentinelFileID = UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000A003")!
    private let sentinelPath = "/private/SentinelSecretRoot/ControlAuthorityAdded.swift"
    private let sentinelErrorMessage = "Sentinel secret failure description"

    private var epoch: WorkspaceCodemapRootEpoch {
        WorkspaceCodemapRootEpoch(rootID: sentinelRootID, rootLifetimeID: sentinelLifetimeID)
    }

    private var ticket: WorkspaceCodemapArtifactDemandTicket {
        WorkspaceCodemapArtifactDemandTicket(
            retainID: sentinelFileID,
            requestID: sentinelRootID,
            rootEpoch: epoch,
            fileID: sentinelFileID,
            requestGeneration: 7_777_001,
            catalogGeneration: 7_777_002,
            pathGeneration: 7_777_003,
            ingressGeneration: 7_777_004
        )
    }

    func testPublicationStaleAndRevalidationCodesKeepEachNestedLeaf() {
        let cases: [(WorkspaceCodemapStructurePublicationStaleReason, String)] = [
            (.presentation(.rootScope), "publication.presentation.root_scope"),
            (.presentation(.rootEpoch(epoch)), "publication.presentation.root_epoch"),
            (.presentation(.catalog(fileID: sentinelFileID)), "publication.presentation.catalog"),
            (.presentation(.demand(ticket)), "publication.presentation.demand"),
            (
                .presentation(.bundle(rootEpoch: epoch, bundleID: WorkspaceCodemapFrozenPresentationBundleID())),
                "publication.presentation.bundle"
            ),
            (.presentation(.automatic(.publicationReceipt)), "publication.presentation.automatic.publication_receipt"),
            (
                .presentation(.automatic(.graph(.runtime(rootEpoch: epoch, reason: .rebuilding)))),
                "publication.presentation.automatic.graph.runtime.rebuilding"
            ),
            (.traversal(.rootEpoch(epoch)), "publication.traversal.root_epoch"),
            (.traversal(.seed(ticket)), "publication.traversal.seed"),
            (.traversal(.graph(epoch)), "publication.traversal.graph"),
            (.output, "publication.output")
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(Classifier.code(for: reason).rawValue, expected)
            XCTAssertEqual(
                Classifier.code(for: WorkspaceCodemapStructureIssue.publicationStale(reason)).rawValue,
                expected,
                "The issue form must keep the same nested leaf."
            )
            XCTAssertEqual(
                Classifier.code(for: WorkspaceCodemapStructurePublicationDisposition.stale(reason)).rawValue,
                expected,
                "Revalidation must report the exact nested leaf, not a collapsed stale code."
            )
        }
        XCTAssertEqual(Classifier.code(for: WorkspaceCodemapStructurePublicationDisposition.current).rawValue, "current")
    }

    func testIssueTraversalProjectionAndRetryCodesKeepTypedLeavesAndBudgetDimensions() {
        let issueCases: [(WorkspaceCodemapStructureIssue, String)] = [
            (.candidate(.fileOutsideRootScope(sentinelFileID)), "candidate.file_outside_root_scope"),
            (.artifactPending(fileID: sentinelFileID, ticket: ticket), "artifact_pending"),
            (
                .artifactUnavailable(fileID: sentinelFileID, reason: .runtimeFailureParked),
                "artifact_unavailable.runtime_failure_parked"
            ),
            (.traversalPartial(.referenceFailuresPresent(epoch)), "traversal_partial.reference_failures_present"),
            (.traversalPending(.graphBusy(epoch)), "traversal_pending.graph_busy"),
            (.traversalPending(.graphRebuilding(epoch)), "traversal_pending.graph_rebuilding"),
            (.traversalUnavailable(.graphNotBuilt(epoch)), "traversal_unavailable.graph_not_built"),
            (.traversalUnavailable(.seedNotReady(sentinelFileID)), "traversal_unavailable.seed_not_ready"),
            (
                .traversalUnavailable(.runtime(rootEpoch: epoch, reason: .invalidQuery)),
                "traversal_unavailable.runtime.invalid_query"
            ),
            (
                .traversalUnavailable(.runtime(
                    rootEpoch: epoch,
                    reason: .processAdmissionRejected(.reservedBindingCountLimit)
                )),
                "traversal_unavailable.runtime.process_admission_rejected.reserved_binding_count_limit"
            ),
            (
                .traversalUnavailable(.runtime(
                    rootEpoch: epoch,
                    reason: .actorAdmissionRejected(.processAdmission(.activeReservationCountLimit))
                )),
                "traversal_unavailable.runtime.actor_admission_rejected.process_admission.active_reservation_count_limit"
            ),
            (
                .traversalUnavailable(.runtime(
                    rootEpoch: epoch,
                    reason: .actorAdmissionRejected(.actorReservedBindingLimit)
                )),
                "traversal_unavailable.runtime.actor_admission_rejected.actor_reserved_binding_limit"
            ),
            (
                .traversalUnavailable(.runtime(rootEpoch: epoch, reason: .outputBudgetExceeded(.referenceFailures))),
                "traversal_unavailable.runtime.output_budget_exceeded.reference_failures"
            ),
            (
                .traversalUnavailable(.runtime(rootEpoch: epoch, reason: .explicitRootUnavailable(.rootUnloaded))),
                "traversal_unavailable.runtime.explicit_root_unavailable.root_unloaded"
            ),
            (
                .traversalUnavailable(.definitionUniverse(
                    rootEpoch: epoch,
                    coverage: .budget(dimension: .residentGraph(.postings), attempted: 9, limit: 3)
                )),
                "traversal_unavailable.definition_universe.budget.resident_graph.postings"
            ),
            (.traversalStale(.graph(epoch)), "traversal_stale.graph"),
            (
                .traversalBudget(.runtime(rootEpoch: epoch, dimension: .edges)),
                "traversal_budget.runtime.edges"
            ),
            (.traversalBudget(.nodeLimit(attempted: 11, limit: 10)), "traversal_budget.node_limit"),
            (.busy(retryAfterMilliseconds: 100), "busy"),
            (
                .readinessTimeout(elapsedMilliseconds: 10000, limitMilliseconds: 10000, retryAfterMilliseconds: 100),
                "readiness_timeout"
            ),
            (
                .projectionUnavailable(reason: .repositoryAuthorityChanged, retryAfterMilliseconds: 100),
                "projection_unavailable.repository_authority_changed"
            ),
            (
                .projectionUnavailable(
                    reason: .projectionBudget(WorkspaceCodemapProjectionBudget(
                        dimension: .residentGraph(.edges),
                        attempted: 5,
                        limit: 4
                    )),
                    retryAfterMilliseconds: nil
                ),
                "projection_unavailable.projection_budget.resident_graph.edges"
            ),
            (
                .projectionBudget(WorkspaceCodemapProjectionBudget(dimension: .stagedGraphBytes, attempted: 2, limit: 1)),
                "projection_budget.staged_graph_bytes"
            ),
            (
                .freezeUnavailable(rootEpoch: epoch, reason: .demandUnavailable(ticket, .staleCurrentness)),
                "freeze_unavailable.demand_unavailable.stale_currentness"
            ),
            (
                .renderUnavailable(rootEpoch: epoch, reason: .noRenderableCodemap(sentinelFileID)),
                "render_unavailable.no_renderable_codemap"
            ),
            (.fileLimit(attempted: 11, limit: 10), "file_limit"),
            (.seedDemandLimit(attempted: 3, limit: 2), "seed_demand_limit"),
            (.tokenLimit(path: sentinelPath, attempted: 9, limit: 1), "token_limit")
        ]
        for (issue, expected) in issueCases {
            XCTAssertEqual(Classifier.code(for: issue).rawValue, expected)
        }

        let dispositionCases: [(WorkspaceCodemapStructureTraversalDisposition, String)] = [
            (.pending(.graphRebuilding(epoch)), "pending.graph_rebuilding"),
            (.unavailable(.definitionUniverse(
                rootEpoch: epoch,
                coverage: .budget(dimension: .catalogEntries, attempted: 1, limit: 0)
            )), "unavailable.definition_universe.budget.catalog_entries"),
            (.stale(.seed(ticket)), "stale.seed"),
            (.budget(nil, .accountingOverflow), "budget.accounting_overflow"),
            (.cancelled, "cancelled")
        ]
        for (disposition, expected) in dispositionCases {
            XCTAssertEqual(Classifier.code(for: disposition).rawValue, expected)
        }

        XCTAssertEqual(Classifier.code(for: Classifier.ProjectionWait.ready).rawValue, "ready")
        XCTAssertEqual(Classifier.code(for: Classifier.ProjectionWait.timeout).rawValue, "timeout")
        XCTAssertEqual(
            Classifier.code(for: Classifier.ProjectionWait.unavailable(.capabilityUnavailable)).rawValue,
            "unavailable.capability_unavailable"
        )
        XCTAssertEqual(
            Classifier.code(for: WorkspaceCodemapProjectionRootSessionRetryPreparation.deadlineReached).rawValue,
            "deadline_reached"
        )
        XCTAssertEqual(Classifier.code(for: WorkspaceCodemapStructureTraversalDirection?.none).rawValue, "none")
        XCTAssertEqual(
            Classifier.code(for: WorkspaceCodemapStructureTraversalDirection.referencedDefinitions).rawValue,
            "referenced_definitions"
        )
    }

    func testRecordLogLinesContainOnlyFixedCodesNumbersAndBooleans() throws {
        var trace = enabledTrace()
        trace.beginAttempt(0)
        trace.record(
            .initialTraversal,
            code: Classifier.code(
                for: WorkspaceCodemapStructureTraversalDisposition.unavailable(.foreignRootEpoch(sentinelRootID))
            ),
            details: [.count(.queries, 3)]
        )
        trace.record(
            .attemptResult,
            code: Classifier.code(for: WorkspaceCodemapStructurePublicationStaleReason.presentation(.demand(ticket)))
        )
        trace.decide(.staleAfterRevalidation)
        let presentation = WorkspaceCodemapStructurePresentation(
            outcome: .stale,
            entries: [],
            issues: [
                .publicationStale(.presentation(.demand(ticket))),
                .tokenLimit(path: sentinelPath, attempted: 9, limit: 1),
                .candidate(.incompleteRootSet(missingFileIDs: [sentinelFileID])),
                .freezeUnavailable(rootEpoch: epoch, reason: .duplicateFileID(sentinelFileID))
            ],
            requestedSeedCount: 1,
            resolvedSeedCount: 0,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )
        let returned = try XCTUnwrap(trace.finish(returning: presentation))
        XCTAssertEqual(returned.terminal.disposition, .staleAfterRevalidation)
        XCTAssertEqual(returned.terminal.outcome?.rawValue, "stale")
        XCTAssertEqual(returned.terminal.staleReason?.rawValue, "publication.presentation.demand")
        XCTAssertEqual(
            returned.terminal.issueCodes.map(\.rawValue),
            [
                "candidate.incomplete_root_set",
                "freeze_unavailable.duplicate_file_id",
                "publication.presentation.demand",
                "token_limit"
            ]
        )

        let thrownError = NSError(
            domain: "SentinelSecretDomain",
            code: 4242,
            userInfo: [NSLocalizedDescriptionKey: sentinelErrorMessage, NSFilePathErrorKey: sentinelPath]
        )
        let threw = try XCTUnwrap(trace.finish(throwing: thrownError))
        XCTAssertEqual(threw.terminal.disposition, .threw)
        XCTAssertNil(threw.terminal.outcome)
        let cancelled = try XCTUnwrap(trace.finish(throwing: CancellationError()))
        XCTAssertEqual(cancelled.terminal.disposition, .cancelled)

        for record in [returned, threw, cancelled] {
            let lines = record.logLines(emissionSequence: 3)
            XCTAssertFalse(lines.isEmpty)
            for line in lines {
                assertPrivacySafe(line)
            }
            XCTAssertEqual(reconstructedTokens(lines), [3: record.tokens])
        }
        let lines = returned.logLines(emissionSequence: 3)
        XCTAssertTrue(
            lines[0].hasPrefix("code_structure_diagnostics schema=1 rec=3 part=1 parts=\(lines.count) "),
            lines[0]
        )
        let tokens = returned.tokens
        XCTAssertEqual(
            Array(tokens.prefix(4)),
            [
                "elapsed_ms=\(returned.terminal.elapsedMilliseconds)",
                "terminal=stale_after_revalidation",
                "outcome=stale",
                "stale=publication.presentation.demand"
            ]
        )
        XCTAssertEqual(
            tokens.filter { $0.hasPrefix("issue=") },
            [
                "issue=candidate.incomplete_root_set",
                "issue=freeze_unavailable.duplicate_file_id",
                "issue=publication.presentation.demand",
                "issue=token_limit"
            ]
        )
        XCTAssertTrue(
            tokens.contains {
                $0.hasPrefix("cp=a0.initial_traversal@") && $0.hasSuffix(":unavailable.foreign_root_epoch{queries=3}")
            },
            "Checkpoint tokens carry the attempt, phase, elapsed time, code, and details: \(tokens)"
        )
    }

    func testTraceBoundsCheckpointsAndIssueCodesWhileKeepingOrderAndTerminal() throws {
        let phases: [WorkspaceCodemapStructureDiagnosticPhase] = [
            .seedAdmission, .seedCandidates, .seedDemand, .projection, .initialTraversal,
            .targetDemand, .targetTraversal, .presentationCandidates, .freezeRender, .attemptResult,
            .publicationHook, .revalidation, .cleanup
        ]
        var trace = enabledTrace()
        var expectedPhases: [WorkspaceCodemapStructureDiagnosticPhase] = []
        for attempt in 0 ..< 6 {
            trace.beginAttempt(attempt)
            expectedPhases.append(.attemptBegin)
            for phase in phases {
                trace.record(phase, details: [.count(.entries, attempt)])
                expectedPhases.append(phase)
            }
        }
        let releaseStarted = trace.mark()
        trace.recordDuration(.cleanup, since: releaseStarted)
        expectedPhases.append(.cleanup)
        trace.decide(.attemptsExhausted)
        XCTAssertEqual(expectedPhases.count, 6 * 14 + 1)

        let distinctIssues = (1 ... 11).map { WorkspaceCodemapStructureIssue.fileLimit(attempted: $0, limit: 0) } + [
            .busy(retryAfterMilliseconds: 1),
            .readinessTimeout(elapsedMilliseconds: 1, limitMilliseconds: 1, retryAfterMilliseconds: 1),
            .seedDemandLimit(attempted: 1, limit: 0),
            .traversalPending(.graphBusy(epoch)),
            .traversalPending(.graphRebuilding(epoch)),
            .traversalStale(.graph(epoch)),
            .traversalStale(.seed(ticket)),
            .traversalStale(.rootEpoch(epoch)),
            .artifactPending(fileID: sentinelFileID, ticket: ticket),
            .projectionUnavailable(reason: .generationMismatch, retryAfterMilliseconds: nil)
        ]
        let record = try XCTUnwrap(trace.finish(returning: WorkspaceCodemapStructurePresentation(
            outcome: .unavailable,
            entries: [],
            issues: distinctIssues,
            requestedSeedCount: 1,
            resolvedSeedCount: 1,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )))

        XCTAssertEqual(record.checkpoints.count, WorkspaceCodemapStructureDiagnosticRecord.maximumCheckpointCount)
        XCTAssertEqual(record.droppedCheckpointCount, expectedPhases.count - 64)
        XCTAssertEqual(record.checkpoints.map(\.phase), Array(expectedPhases.prefix(64)), "Kept checkpoints stay in order.")
        XCTAssertEqual(record.checkpoints.map(\.attempt), Array((0 ..< 6).flatMap { Array(repeating: $0, count: 14) }.prefix(64)))
        XCTAssertEqual(
            record.checkpoints.map(\.elapsedMilliseconds),
            record.checkpoints.map(\.elapsedMilliseconds).sorted(),
            "Checkpoint times are monotonic."
        )
        XCTAssertEqual(record.terminal.disposition, .attemptsExhausted)
        XCTAssertEqual(record.terminal.attemptsStarted, 6)
        XCTAssertEqual(record.terminal.finalAttempt, 5, "The terminal keeps the final attempt past the checkpoint cap.")
        XCTAssertEqual(record.terminal.finalPhase, .cleanup)
        XCTAssertEqual(record.terminal.issueCodes.count, WorkspaceCodemapStructureDiagnosticRecord.maximumIssueCodeCount)
        XCTAssertEqual(record.terminal.issueCodes, record.terminal.issueCodes.sorted())
        XCTAssertEqual(
            record.terminal.droppedIssueCodeCount,
            11 - WorkspaceCodemapStructureDiagnosticRecord.maximumIssueCodeCount,
            "Eleven distinct codes (all file_limit issues share one) keep eight and count three dropped."
        )

        let lines = record.logLines(emissionSequence: 7, maximumLineBytes: 400)
        XCTAssertGreaterThan(lines.count, 2)
        for (index, line) in lines.enumerated() {
            XCTAssertTrue(
                line.hasPrefix("code_structure_diagnostics schema=1 rec=7 part=\(index + 1) parts=\(lines.count) "),
                line
            )
            assertPrivacySafe(line)
            XCTAssertLessThanOrEqual(line.utf8.count, 400, "Every line, including the summary, is bounded: \(line)")
        }
        let tokens = try XCTUnwrap(reconstructedTokens(lines)[7])
        XCTAssertEqual(tokens, record.tokens, "Splitting must neither drop, reorder, nor alter tokens.")
        XCTAssertEqual(tokens.count { $0.hasPrefix("cp=") }, 64)
        XCTAssertTrue(tokens.contains("checkpoints=64"), "\(tokens)")
        XCTAssertTrue(tokens.contains("checkpoints_dropped=\(expectedPhases.count - 64)"), "\(tokens)")
        XCTAssertTrue(tokens.contains("issues_dropped=3"), "\(tokens)")
    }

    func testDisabledTraceDoesNoWorkAndActivationRequiresExactOptIn() {
        final class EvaluationCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = EvaluationCounter()
        func countedCode() -> WorkspaceCodemapStructureDiagnosticCode? {
            counter.count += 1
            return Classifier.code(for: WorkspaceCodemapStructurePublicationStaleReason.output)
        }
        var trace = Trace(
            isEnabled: false,
            direction: .referrers,
            requestedSeedCount: 1,
            maximumAttemptCount: 4,
            totalWait: .seconds(10)
        )
        trace.beginAttempt(0)
        trace.record(.seedDemand, code: countedCode(), details: [.count(.ready, 1)])
        XCTAssertNil(trace.mark())
        trace.recordDuration(.cleanup, since: ContinuousClock.now, code: countedCode())
        trace.decide(.revalidatedCurrent)
        XCTAssertEqual(counter.count, 0, "A disabled trace must not evaluate diagnostic arguments.")
        XCTAssertTrue(trace.checkpoints.isEmpty)
        XCTAssertNil(trace.finish(returning: .stale(.output, requestedSeedCount: 1)))
        XCTAssertNil(trace.finish(throwing: CancellationError()))

        let key = WorkspaceCodemapStructureDiagnostics.environmentKey
        let flag = WorkspaceCodemapStructureDiagnostics.launchArgument
        XCTAssertEqual(key, "REPOPROMPT_CODE_STRUCTURE_DIAGNOSTICS")
        XCTAssertEqual(flag, "--codemap-structure-diagnostics")
        let activationCases: [([String: String], [String], Bool)] = [
            ([key: "1"], [], true),
            ([:], ["/path/RepoPrompt", flag], true),
            ([:], [], false),
            ([key: "0"], [], false),
            ([key: "true"], [], false),
            ([key: ""], [], false),
            ([key: " 1"], [], false),
            ([:], ["--codemap-structure-diagnostics=1"], false),
            ([:], ["-codemap-structure-diagnostics"], false),
            ([:], ["--codemap-structure-diagnostics-extra"], false)
        ]
        for (environment, arguments, expected) in activationCases {
            XCTAssertEqual(
                WorkspaceCodemapStructureDiagnostics.isEnabled(environment: environment, arguments: arguments),
                expected,
                "environment=\(environment) arguments=\(arguments)"
            )
            XCTAssertEqual(
                WorkspaceCodemapStructureDiagnostics.sink(environment: environment, arguments: arguments) != nil,
                expected
            )
        }
    }

    func testArtifactUnavailableCodesKeepEveryNestedRejectionGitAndDemandLeaf() {
        let rejections: [(WorkspaceCodemapBindingDemandRejection, String)] = [
            (.rootNotRegistered, "root_not_registered"),
            (.capabilityUnavailable, "capability_unavailable"),
            (.rootEpochMismatch, "root_epoch_mismatch"),
            (.rootPathMismatch, "root_path_mismatch"),
            (.invalidIdentity, "invalid_identity"),
            (.catalogGenerationMismatch, "catalog_generation_mismatch"),
            (.requestGenerationInvalid, "request_generation_invalid"),
            (.stalePathGeneration, "stale_path_generation"),
            (.staleIngressGeneration, "stale_ingress_generation"),
            (.languageMismatch, "language_mismatch"),
            (.classificationMismatch, "classification_mismatch"),
            (.sourceAuthorityUnavailable, "source_authority_unavailable"),
            (.repositoryAuthorityChanged, "repository_authority_changed"),
            (.staleCompletion, "stale_completion"),
            (.overlayRejected(.rootNotRegistered), "overlay_rejected.root_not_registered"),
            (.overlayRejected(.rootAuthorityInvalid), "overlay_rejected.root_authority_invalid"),
            (.overlayRejected(.rootEpochMismatch), "overlay_rejected.root_epoch_mismatch"),
            (.overlayRejected(.catalogGenerationMismatch), "overlay_rejected.catalog_generation_mismatch"),
            (.overlayRejected(.repositoryAuthorityMismatch), "overlay_rejected.repository_authority_mismatch"),
            (.overlayRejected(.invalidToken), "overlay_rejected.invalid_token"),
            (.overlayRejected(.pathOutsideRoot), "overlay_rejected.path_outside_root"),
            (.overlayRejected(.staleRequestGeneration), "overlay_rejected.stale_request_generation"),
            (.overlayRejected(.requestGenerationConflict), "overlay_rejected.request_generation_conflict"),
            (.overlayRejected(.admissionReservationInvalid), "overlay_rejected.admission_reservation_invalid")
        ]
        let gitTerminal: [(WorkspaceCodemapGitTerminalUnavailableReason, String)] = [
            (.nonGit, "non_git"),
            (.bareRepository, "bare_repository"),
            (.unsupportedObjectFormat, "unsupported_object_format"),
            (.unsupportedGit, "unsupported_git"),
            (.invalidLayout, "invalid_layout"),
            (.invalidLoadedRootContainment, "invalid_loaded_root_containment"),
            (.namespaceUnavailable, "namespace_unavailable"),
            (.rootEpochBindingMismatch, "root_epoch_binding_mismatch"),
            (.releasedRootEpoch, "released_root_epoch")
        ]
        let gitTransient: [(WorkspaceCodemapGitTransientUnavailableReason, String)] = [
            (.gitProcessUnavailable, "git_process_unavailable"),
            (.repositoryChanging, "repository_changing"),
            (.permissionFailure, "permission_failure"),
            (.runtimeUnavailable, "runtime_unavailable")
        ]
        let demandUnavailable: [(WorkspaceCodemapBindingDemandUnavailableReason, String)] = [
            (.unsupportedFileType, "unsupported_file_type"),
            (.missing, "missing"),
            (.securityExcluded, "security_excluded"),
            (.nonRegular, "non_regular"),
            (.oversized, "oversized"),
            (.transient, "transient"),
            (.terminalArtifact(.ready), "terminal_artifact.ready"),
            (.terminalArtifact(.readyNoSymbols), "terminal_artifact.ready_no_symbols"),
            (.terminalArtifact(.oversize), "terminal_artifact.oversize"),
            (.terminalArtifact(.decodeFailed), "terminal_artifact.decode_failed"),
            (.terminalArtifact(.parseFailed), "terminal_artifact.parse_failed")
        ]
        let direct: [(WorkspaceCodemapArtifactDemandUnavailableReason, String)] = [
            (.rootNotLoaded, "root_not_loaded"),
            (.fileNotCataloged, "file_not_cataloged"),
            (.unsupportedFileType, "unsupported_file_type"),
            (.busy(retryAfterMilliseconds: 4242), "busy"),
            (.routeConflict, "route_conflict"),
            (.registrationFailed, "registration_failed"),
            (.runtimeFailure, "runtime_failure"),
            (.runtimeFailureParked, "runtime_failure_parked"),
            (.staleCurrentness, "stale_currentness"),
            (.cancelled, "cancelled")
        ]
        let cases: [(WorkspaceCodemapArtifactDemandUnavailableReason, String)] = direct
            + rejections.map { (.rejected($0.0), "rejected." + $0.1) }
            + gitTerminal.map { (.gitTerminal($0.0), "git_terminal." + $0.1) }
            + gitTransient.map { (.gitTransient($0.0), "git_transient." + $0.1) }
            + demandUnavailable.map { (.demandUnavailable($0.0), "demand_unavailable." + $0.1) }
        XCTAssertEqual(cases.count, 58)
        for (reason, expected) in cases {
            XCTAssertEqual(
                Classifier.code(
                    for: WorkspaceCodemapStructureIssue.artifactUnavailable(fileID: sentinelFileID, reason: reason)
                ).rawValue,
                "artifact_unavailable." + expected
            )
            XCTAssertEqual(
                Classifier.code(
                    for: WorkspaceCodemapStructureIssue.freezeUnavailable(
                        rootEpoch: epoch,
                        reason: .demandUnavailable(ticket, reason)
                    )
                ).rawValue,
                "freeze_unavailable.demand_unavailable." + expected,
                "Freeze demand failures keep the same nested artifact leaf."
            )
        }
        XCTAssertEqual(
            Set(cases.map(\.1)).count,
            cases.count,
            "Distinct nested reasons, including rejections recovered differently, never share a code."
        )
    }

    func testEveryLogLineIsBoundedForWorstCaseSummaryOversizedTokensAndUnsupportedLimits() throws {
        let longestStale = Classifier.code(for: WorkspaceCodemapStructurePublicationStaleReason.presentation(
            .automatic(.graph(.runtime(rootEpoch: epoch, reason: .explicitRootUnavailable(.authorityRevoked))))
        ))
        let longIssues: [WorkspaceCodemapStructureIssue] = [
            .freezeUnavailable(
                rootEpoch: epoch,
                reason: .demandUnavailable(ticket, .rejected(.overlayRejected(.admissionReservationInvalid)))
            ),
            .freezeUnavailable(
                rootEpoch: epoch,
                reason: .demandUnavailable(ticket, .rejected(.overlayRejected(.repositoryAuthorityMismatch)))
            ),
            .freezeUnavailable(
                rootEpoch: epoch,
                reason: .demandUnavailable(ticket, .demandUnavailable(.terminalArtifact(.readyNoSymbols)))
            ),
            .freezeUnavailable(
                rootEpoch: epoch,
                reason: .demandUnavailable(ticket, .gitTerminal(.invalidLoadedRootContainment))
            ),
            .artifactUnavailable(
                fileID: sentinelFileID,
                reason: .rejected(.overlayRejected(.requestGenerationConflict))
            ),
            .traversalUnavailable(.definitionUniverse(
                rootEpoch: epoch,
                coverage: .budget(dimension: .residentGraph(.postings), attempted: 1, limit: 0)
            )),
            .projectionUnavailable(
                reason: .projectionBudget(WorkspaceCodemapProjectionBudget(
                    dimension: .queuedManifestMutationBytes,
                    attempted: 1,
                    limit: 0
                )),
                retryAfterMilliseconds: nil
            ),
            .publicationStale(.presentation(.automatic(.graph(.runtime(
                rootEpoch: epoch,
                reason: .explicitRootUnavailable(.authorityRevoked)
            )))))
        ]
        let issueCodes = longIssues.map { Classifier.code(for: $0) }.sorted()
        XCTAssertEqual(Set(issueCodes).count, WorkspaceCodemapStructureDiagnosticRecord.maximumIssueCodeCount)
        let oversized = WorkspaceCodemapStructureDiagnosticCheckpoint(
            attempt: .max,
            phase: .projectionRootSessionRetry,
            elapsedMilliseconds: .max,
            code: issueCodes.last,
            details: Array(repeating: .count(.durationMilliseconds, .max), count: 12) + [.flag(.roundLimitReached, false)]
        )
        let ordinary = WorkspaceCodemapStructureDiagnosticCheckpoint(
            attempt: 3,
            phase: .presentationCandidates,
            elapsedMilliseconds: .max,
            code: longestStale,
            details: [.count(.candidates, .max), .count(.issues, .max), .count(.ordered, .max)]
        )
        let record = WorkspaceCodemapStructureDiagnosticRecord(
            direction: Classifier.code(for: WorkspaceCodemapStructureTraversalDirection.referencedDefinitions),
            requestedSeedCount: .max,
            maximumAttemptCount: .max,
            totalWaitLimitMilliseconds: .max,
            checkpoints: [oversized] + Array(repeating: ordinary, count: 62) + [oversized],
            droppedCheckpointCount: .max,
            terminal: WorkspaceCodemapStructureDiagnosticTerminal(
                disposition: .staleAfterReceiptlessRevocation,
                outcome: Classifier.code(for: WorkspaceCodemapStructureOutcome.unavailable),
                staleReason: longestStale,
                issueCodes: issueCodes,
                droppedIssueCodeCount: .max,
                elapsedMilliseconds: .max,
                attemptsStarted: .max,
                finalAttempt: .max,
                finalPhase: .projectionRootSessionRetry,
                deadlinePassed: true,
                cancelled: true
            )
        )
        let oversizedToken = try XCTUnwrap(record.tokens.first { $0.hasPrefix("cp=") })
        XCTAssertGreaterThan(oversizedToken.utf8.count, 400, "The fixture must exceed the 400-byte body.")
        XCTAssertLessThan(oversizedToken.utf8.count, 800, "The fixture fits one line at the default bound.")
        let summaryBytes = record.tokens.prefix { !$0.hasPrefix("issue=") }.map(\.utf8.count).reduce(0, +)
        XCTAssertGreaterThan(summaryBytes, WorkspaceCodemapStructureDiagnosticRecord.minimumLineBytes)

        for requested in [Int.min, -1, 0, 10, 191, 192, 193, 256, 400, 900, 4096] {
            let bound = max(requested, WorkspaceCodemapStructureDiagnosticRecord.minimumLineBytes)
            let lines = record.logLines(emissionSequence: .max, maximumLineBytes: requested)
            for (index, line) in lines.enumerated() {
                XCTAssertLessThanOrEqual(line.utf8.count, bound, "requested=\(requested) line=\(line)")
                XCTAssertTrue(
                    line.hasPrefix(
                        "code_structure_diagnostics schema=1 rec=\(UInt64.max) part=\(index + 1) parts=\(lines.count) "
                    ),
                    line
                )
                assertPrivacySafe(line)
            }
            XCTAssertEqual(
                reconstructedTokens(lines),
                [UInt64.max: record.tokens],
                "requested=\(requested): every token, including split ones, must survive in order."
            )
            XCTAssertEqual(
                lines.contains { $0.contains(" frag=1,") },
                bound <= 400,
                "Only bounds too small for the oversized checkpoint split it (requested=\(requested))."
            )
            let droppedCountersLine = try XCTUnwrap(lines.firstIndex { $0.contains(" checkpoints_dropped=") })
            let firstIssueLine = try XCTUnwrap(lines.firstIndex { $0.contains(" issue=") })
            XCTAssertLessThanOrEqual(
                droppedCountersLine,
                firstIssueLine,
                "Dropped counters are emitted before the issue list (requested=\(requested))."
            )
        }
    }

    func testInterleavedConcurrentEmissionsReconstructByEmissionSequence() async throws {
        var trace = enabledTrace()
        for attempt in 0 ..< 4 {
            trace.beginAttempt(attempt)
            trace.record(.seedDemand, details: [.count(.ready, 1), .count(.pending, 0)])
            trace.record(.attemptResult, code: Classifier.code(for: WorkspaceCodemapStructureOutcome.stale))
        }
        trace.decide(.attemptsExhausted)
        let record = try XCTUnwrap(trace.finish(returning: .stale(.output, requestedSeedCount: 1)))
        let first = record.logLines(emissionSequence: 1, maximumLineBytes: 256)
        let second = record.logLines(emissionSequence: 2, maximumLineBytes: 256)
        XCTAssertGreaterThan(first.count, 1)
        XCTAssertEqual(
            first.map { $0.replacingOccurrences(of: " rec=1 ", with: " ") },
            second.map { $0.replacingOccurrences(of: " rec=2 ", with: " ") },
            "Identical elapsed times and part counts: only the emission number tells the records apart."
        )
        var interleaved: [String] = []
        for (late, early) in zip(first.reversed(), second) {
            interleaved += [late, early]
        }
        XCTAssertEqual(reconstructedTokens(interleaved), [1: record.tokens, 2: record.tokens])

        let sequence = WorkspaceCodemapStructureDiagnosticEmissionSequence()
        let written = CodemapLockedValues<String>()
        let emit = WorkspaceCodemapStructureDiagnostics.emitter(sequence: sequence) { written.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask { emit(record) }
            }
        }
        let byEmission = reconstructedTokens(written.values)
        XCTAssertEqual(Set(byEmission.keys), Set(UInt64(1) ... 32), "Each emission gets one unique number.")
        for (emission, tokens) in byEmission {
            XCTAssertEqual(tokens, record.tokens, "rec=\(emission)")
        }
        XCTAssertEqual(sequence.next(), 33, "Emission numbers are monotonic and process-local to the sequence.")
    }

    // MARK: - Coordinator-emitted records

    func testCoordinatorRecordsTimeoutWhenSeedDemandStaysPendingPastDeadline() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let resolutionGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: resolutionGate)
        addTeardownBlock {
            resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let records = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .milliseconds(50)
            ),
            structureDiagnosticSink: { records.append($0) }
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: Self.seedOnlyTraversalLimits,
            outputLimits: Self.outputLimits,
            rootScope: .allLoaded
        )

        XCTAssertEqual(presentation.outcome, .timeout, "\(presentation.issues)")
        let pendingTicket = try XCTUnwrap(presentation.issues.compactMap {
            issue -> WorkspaceCodemapArtifactDemandTicket? in
            if case let .artifactPending(_, ticket) = issue { return ticket }
            return nil
        }.first)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(pendingTicket)
        XCTAssertEqual(retainCount, 0, "The timed-out attempt's owned demand is released.")

        let record = try singleRecord(records)
        let context = "\(record.logLines(emissionSequence: 1))"
        XCTAssertEqual(record.terminal.disposition, .attemptPresentationWithoutReceipt, context)
        XCTAssertEqual(record.terminal.outcome?.rawValue, "timeout", context)
        XCTAssertNil(record.terminal.staleReason, context)
        XCTAssertEqual(record.terminal.issueCodes.map(\.rawValue), ["artifact_pending", "readiness_timeout"], context)
        XCTAssertTrue(record.terminal.deadlinePassed, context)
        XCTAssertFalse(record.terminal.cancelled, context)
        XCTAssertEqual(record.terminal.attemptsStarted, 1, context)
        XCTAssertEqual(
            record.checkpoints.map(\.phase),
            [.attemptBegin, .seedAdmission, .seedCandidates, .seedDemand, .attemptResult, .cleanup],
            context
        )
        let seedDemand = record.checkpoints.first { $0.phase == .seedDemand }
        XCTAssertEqual(seedDemand?.details.contains(.count(.pending, 1)), true, context)
        XCTAssertEqual(seedDemand?.details.contains(.flag(.deadlineReached, true)), true, context)
        XCTAssertEqual(record.checkpoints.first { $0.phase == .attemptResult }?.code?.rawValue, "timeout", context)
        assertRecordLinesBoundedAndPrivate(record)
    }

    func testCoordinatorRecordsTypedStaleAfterPublicationRevocationRetry() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": "protocol FeatureProtocol { func feature() }\nstruct Feature: FeatureProtocol { func feature() {} }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let publicationCount = CodemapLockedCounter()
        let attempts = CodemapLockedValues<Int>()
        let records = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 20,
                maximumTotalWait: .seconds(10)
            ),
            beforePublicationRevalidation: { _ in
                // Existing deterministic mutation: unload the root once, after the first attempt
                // acquired its demand and bundle but before publication revalidation.
                if publicationCount.incrementAndGet() == 1 {
                    await store.unloadRoot(id: loaded.id)
                }
            },
            structureAttemptDidBegin: { attempts.append($0) },
            structureDiagnosticSink: { records.append($0) }
        )

        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: Self.seedOnlyTraversalLimits,
            outputLimits: Self.outputLimits,
            rootScope: .allLoaded
        )

        XCTAssertEqual(presentation.outcome, .stale, "\(presentation.issues)")
        XCTAssertEqual(attempts.values, [0, 1])
        XCTAssertEqual(publicationCount.value, 1)
        let staleReason = try XCTUnwrap(presentation.issues.compactMap {
            issue -> WorkspaceCodemapStructurePublicationStaleReason? in
            if case let .publicationStale(reason) = issue { return reason }
            return nil
        }.first)
        let expectedStale = Classifier.code(for: staleReason)

        let record = try singleRecord(records)
        let context = "\(record.logLines(emissionSequence: 1))"
        XCTAssertTrue(expectedStale.rawValue.hasPrefix("publication."), context)
        XCTAssertEqual(record.terminal.disposition, .staleAfterReceiptlessRevocation, context)
        XCTAssertEqual(record.terminal.outcome?.rawValue, "stale", context)
        XCTAssertEqual(record.terminal.staleReason, expectedStale, context)
        XCTAssertEqual(record.terminal.attemptsStarted, 2, context)
        XCTAssertEqual(record.terminal.finalAttempt, 1, context)
        XCTAssertFalse(record.terminal.deadlinePassed, context)
        XCTAssertFalse(record.terminal.cancelled, context)
        let firstAttempt = record.checkpoints.filter { $0.attempt == 0 }
        XCTAssertEqual(
            firstAttempt.map(\.phase),
            [
                .attemptBegin, .seedAdmission, .seedCandidates, .seedDemand, .presentationCandidates,
                .freezeRender, .attemptResult, .publicationHook, .revalidation, .cleanup
            ],
            context
        )
        XCTAssertEqual(firstAttempt.first { $0.phase == .attemptResult }?.code?.rawValue, "ready", context)
        XCTAssertEqual(
            firstAttempt.first { $0.phase == .revalidation }?.code,
            expectedStale,
            "The revalidation leaf is the stale reason the caller receives: \(context)"
        )
        let secondAttempt = record.checkpoints.filter { $0.attempt == 1 }
        XCTAssertEqual(secondAttempt.first?.phase, .attemptBegin, context)
        XCTAssertEqual(secondAttempt.last?.phase, .cleanup, context)
        XCTAssertFalse(secondAttempt.contains { $0.phase == .revalidation }, context)
        assertRecordLinesBoundedAndPrivate(record)
    }

    func testCoordinatorCancellationAfterSeedDemandAcquisitionReleasesOwnedDemandAndRecordsCleanup() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            // A renderable symbol so the follow-up publication can render the same seed.
            files: ["Sources/Cancellation.swift": "struct CancellationSeed { func renderable() {} }\n"]
        )
        let resolutionGate = CodemapResolutionGate()
        let waiterGate = CodemapSuspensionGate()
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            resolutionGate: resolutionGate
        )
        addTeardownBlock {
            waiterGate.release()
            resolutionGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(cancellationCleanupHook: { ticket in
            cancelledTickets.append(ticket)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)
        let records = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            waiter: WorkspaceCodemapPresentationWaiter { _ in
                await waiterGate.enterAndWait()
                try Task.checkCancellation()
            },
            structureDiagnosticSink: { records.append($0) }
        )
        let task = Task {
            try await coordinator.structurePresentation(
                seedFileIDs: [file.id],
                direction: nil,
                traversalLimits: Self.seedOnlyTraversalLimits,
                outputLimits: Self.outputLimits,
                rootScope: .allLoaded
            )
        }

        // Acquisition is confirmed before cancelling: the seed demand was issued and parked in
        // resolution, and the coordinator is waiting for readiness while owning that ticket.
        let resolutionEntered = await resolutionGate.waitUntilEntered()
        XCTAssertTrue(resolutionEntered)
        let waiterEntered = await waiterGate.waitUntilEntered()
        XCTAssertTrue(waiterEntered)
        task.cancel()
        waiterGate.release()
        resolutionGate.release()
        do {
            let presentation = try await task.value
            XCTFail("Expected cancellation, got \(presentation.outcome)")
        } catch is CancellationError {
            // Expected.
        }

        let clock = ContinuousClock()
        let cleanupDeadline = clock.now.advanced(by: .seconds(5))
        while cancelledTickets.values.isEmpty, clock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cancelledTickets.values.count, 1, "The owned pending seed demand is cancelled once.")
        let cancelledTicket = try XCTUnwrap(cancelledTickets.values.first)
        XCTAssertEqual(cancelledTicket.fileID, file.id)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(cancelledTicket)
        XCTAssertEqual(retainCount, 0)
        let presentationRetainCount = await store.codemapPresentationRetainCountForTesting(
            rootEpoch: cancelledTicket.rootEpoch
        )
        XCTAssertEqual(presentationRetainCount, 0)

        let record = try singleRecord(records)
        let context = "\(record.logLines(emissionSequence: 1))"
        XCTAssertEqual(record.terminal.disposition, .cancelled, context)
        XCTAssertTrue(record.terminal.cancelled, context)
        XCTAssertNil(record.terminal.outcome, context)
        XCTAssertNil(record.terminal.staleReason, context)
        XCTAssertEqual(record.terminal.attemptsStarted, 1, context)
        XCTAssertEqual(record.terminal.finalPhase, .cleanup, context)
        // Seed demand acquired its ticket and was waiting for readiness when cancelled, so its
        // checkpoint never completes; the attempt's ownership cleanup still runs and is timed.
        XCTAssertEqual(
            record.checkpoints.map(\.phase),
            [.attemptBegin, .seedAdmission, .seedCandidates, .cleanup],
            context
        )
        XCTAssertEqual(
            record.checkpoints.first { $0.phase == .seedCandidates }?.details.first,
            .count(.candidates, 1),
            context
        )
        XCTAssertTrue(
            record.checkpoints.last?.details.contains {
                if case .count(.durationMilliseconds, _) = $0 { return true }
                return false
            } == true,
            context
        )
        assertRecordLinesBoundedAndPrivate(record)

        let followUp = try await WorkspaceCodemapPresentationCoordinator(store: store).structurePresentation(
            seedFileIDs: [file.id],
            direction: nil,
            traversalLimits: Self.seedOnlyTraversalLimits,
            outputLimits: Self.outputLimits,
            rootScope: .allLoaded
        )
        XCTAssertEqual(followUp.outcome, .ready, "\(followUp.issues)")
        XCTAssertEqual(followUp.entries.map(\.entry.fileID), [file.id])
        XCTAssertEqual(records.values.count, 1, "The follow-up coordinator has no test sink.")
    }

    private static let seedOnlyTraversalLimits = WorkspaceCodemapStructureTraversalLimits(
        maximumDepth: 0,
        maximumNodeCount: 10,
        maximumEdgeCount: 10,
        maximumByteCount: 4096
    )

    private static let outputLimits = WorkspaceCodemapStructureOutputLimits(
        maximumFileCount: 10,
        maximumCodemapTokenCount: 6000
    )

    private func singleRecord(
        _ records: CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WorkspaceCodemapStructureDiagnosticRecord {
        let values = records.values
        XCTAssertEqual(values.count, 1, "One terminal record per invocation.", file: file, line: line)
        return try XCTUnwrap(values.first, file: file, line: line)
    }

    private func assertRecordLinesBoundedAndPrivate(
        _ record: WorkspaceCodemapStructureDiagnosticRecord,
        file: StaticString = #filePath,
        line lineNumber: UInt = #line
    ) {
        let lines = record.logLines(emissionSequence: 1)
        for line in lines {
            XCTAssertLessThanOrEqual(
                line.utf8.count,
                WorkspaceCodemapStructureDiagnosticRecord.defaultMaximumLineBytes,
                line,
                file: file,
                line: lineNumber
            )
            assertPrivacySafe(line, file: file, line: lineNumber)
            XCTAssertFalse(line.contains("feature"), "Fixture names must not be logged: \(line)", file: file, line: lineNumber)
        }
        XCTAssertEqual(reconstructedTokens(lines, file: file, line: lineNumber), [1: record.tokens], file: file, line: lineNumber)
    }

    private struct ParsedLine {
        let part: Int
        let parts: Int
        let body: [Substring]
    }

    /// Applies the documented join rule: group by `rec`, order by `part`, concatenate bodies, and
    /// rejoin consecutive `frag=<i>,<n>:` pieces. Fails on malformed lines, gaps, or open fragments.
    private func reconstructedTokens(
        _ lines: [String],
        file: StaticString = #filePath,
        line lineNumber: UInt = #line
    ) -> [UInt64: [String]] {
        var linesByEmission: [UInt64: [ParsedLine]] = [:]
        for line in lines {
            let fields = line.split(separator: " ")
            guard fields.count > 5,
                  fields[0] == "code_structure_diagnostics",
                  fields[1] == "schema=1",
                  fields[2].hasPrefix("rec="), let emission = UInt64(fields[2].dropFirst(4)),
                  fields[3].hasPrefix("part="), let part = Int(fields[3].dropFirst(5)),
                  fields[4].hasPrefix("parts="), let parts = Int(fields[4].dropFirst(6))
            else {
                XCTFail("Malformed diagnostic line: \(line)", file: file, line: lineNumber)
                continue
            }
            linesByEmission[emission, default: []].append(
                ParsedLine(part: part, parts: parts, body: Array(fields.dropFirst(5)))
            )
        }
        var tokensByEmission: [UInt64: [String]] = [:]
        for (emission, parsed) in linesByEmission {
            let ordered = parsed.sorted { $0.part < $1.part }
            XCTAssertEqual(ordered.map(\.part), Array(1 ... ordered.count), "rec=\(emission)", file: file, line: lineNumber)
            XCTAssertEqual(Set(ordered.map(\.parts)), [ordered.count], "rec=\(emission)", file: file, line: lineNumber)
            var tokens: [String] = []
            var fragment: (next: Int, count: Int, text: String)?
            for piece in ordered.flatMap(\.body) {
                guard piece.hasPrefix("frag=") else {
                    XCTAssertNil(fragment, "Unterminated fragment before \(piece)", file: file, line: lineNumber)
                    fragment = nil
                    tokens.append(String(piece))
                    continue
                }
                guard let colon = piece.firstIndex(of: ":") else {
                    XCTFail("Malformed fragment \(piece)", file: file, line: lineNumber)
                    continue
                }
                let numbers = piece[piece.index(piece.startIndex, offsetBy: 5) ..< colon]
                    .split(separator: ",")
                    .compactMap { Int($0) }
                guard numbers.count == 2 else {
                    XCTFail("Malformed fragment \(piece)", file: file, line: lineNumber)
                    continue
                }
                let chunk = String(piece[piece.index(after: colon)...])
                if numbers[0] == 1 {
                    XCTAssertNil(fragment, "Unterminated fragment before \(piece)", file: file, line: lineNumber)
                    fragment = (next: 2, count: numbers[1], text: chunk)
                } else if let current = fragment, current.next == numbers[0], current.count == numbers[1] {
                    fragment = (next: current.next + 1, count: current.count, text: current.text + chunk)
                } else {
                    XCTFail("Out-of-order fragment \(piece)", file: file, line: lineNumber)
                    continue
                }
                if let current = fragment, current.next > current.count {
                    tokens.append(current.text)
                    fragment = nil
                }
            }
            XCTAssertNil(fragment, "Unterminated trailing fragment rec=\(emission)", file: file, line: lineNumber)
            tokensByEmission[emission] = tokens
        }
        return tokensByEmission
    }

    private func enabledTrace() -> Trace {
        Trace(
            isEnabled: true,
            direction: .referrers,
            requestedSeedCount: 1,
            maximumAttemptCount: 4,
            totalWait: .seconds(10)
        )
    }

    private func assertPrivacySafe(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.=@;:,{} ")
        XCTAssertTrue(
            line.unicodeScalars.allSatisfy(allowed.contains),
            "Only fixed lowercase codes, digits, and separators may be logged: \(line)",
            file: file,
            line: lineNumber
        )
        let lowered = line.lowercased()
        for sentinel in [
            sentinelRootID.uuidString, sentinelLifetimeID.uuidString, sentinelFileID.uuidString,
            sentinelPath, sentinelErrorMessage, "sentinel", "7777", "4242", "controlauthorityadded"
        ] {
            XCTAssertFalse(lowered.contains(sentinel.lowercased()), "Leaked \(sentinel): \(line)", file: file, line: lineNumber)
        }
    }
}
