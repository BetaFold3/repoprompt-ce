import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunResponsePresentationTests: XCTestCase {
    func testFullModesAreValueEqualAndMalformedModeFailsBeforeMutation() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let exporter = immediateExporter()
        let canonical = snapshot(
            sessionID: UUID(),
            status: .completed,
            text: "complete response",
            extras: ["unknown_control": .string("preserve")]
        )
        var operationCount = 0
        var captureCount = 0

        let operation: AgentRunResponsePresentation.CanonicalOperation = { args in
            operationCount += 1
            XCTAssertNil(args["response_mode"])
            return canonical
        }
        let capture: AgentRunResponsePresentation.CaptureDestination = {
            captureCount += 1
            return destination
        }

        let implicit = try await AgentRunResponsePresentation.execute(
            args: ["op": .string("poll")],
            exporter: exporter,
            captureDestination: capture,
            canonicalOperation: operation
        )
        let explicit = try await AgentRunResponsePresentation.execute(
            args: ["op": .string("poll"), "response_mode": .string(" FULL ")],
            exporter: exporter,
            captureDestination: capture,
            canonicalOperation: operation
        )

        XCTAssertEqual(implicit, canonical)
        XCTAssertEqual(explicit, canonical)
        XCTAssertEqual(operationCount, 2)
        XCTAssertEqual(captureCount, 0)

        do {
            _ = try await AgentRunResponsePresentation.execute(
                args: ["op": .string("poll"), "response_mode": .int(7)],
                exporter: exporter,
                captureDestination: capture,
                canonicalOperation: operation
            )
            XCTFail("Malformed response_mode must fail before capture or canonical execution")
        } catch {
            XCTAssertTrue(String(describing: error).contains("response_mode must be a string"))
        }
        XCTAssertEqual(operationCount, 2)
        XCTAssertEqual(captureCount, 0)
    }

    /// Plan §6.3: presentation trims assistant text only; the canonical root `wait_policy`
    /// tuple survives full, tail and none unchanged.
    func testTrimmedModesPreserveRootWaitPolicyTuple() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let policy: Value = .object([
            "mode": .string("automatic"),
            "timeout_seconds": .int(600),
            "parent_family": .string("codex")
        ])
        let canonical = snapshot(
            sessionID: UUID(),
            status: .completed,
            text: "complete response",
            extras: ["wait_policy": policy]
        )

        for mode in ["full", "tail", "none"] {
            let presented = try await AgentRunResponsePresentation.execute(
                args: ["op": .string("wait"), "response_mode": .string(mode)],
                exporter: immediateExporter(),
                captureDestination: { destination },
                canonicalOperation: { _ in canonical }
            )
            XCTAssertEqual(presented.objectValue?["wait_policy"], policy, mode)
            if mode == "full" {
                XCTAssertEqual(presented, canonical)
            } else {
                XCTAssertNotEqual(presented, canonical, "\(mode) must trim the terminal assistant text")
                XCTAssertEqual(
                    presented.objectValue?[AgentRunResponsePresentation.presentationKey]?
                        .objectValue?["response_mode"]?.stringValue,
                    mode
                )
            }
        }
    }

    func testRequestBoundDestinationIsCapturedBeforeCanonicalAwait() async throws {
        let rootA = FileManager.default.temporaryDirectory.appendingPathComponent("captured-a")
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("ambient-b")
        let destinationA = makeDestination(root: rootA)
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 },
            write: { path, content, destination in
                await recorder.recordWrite(path: path, content: content, destination: destination)
                return path
            },
            remove: { path, _ in await recorder.recordRemoval(path: path) }
        )
        var captureCount = 0
        var ambientRoot = rootA

        let result = try await AgentRunResponsePresentation.execute(
            args: ["op": .string("wait"), "response_mode": .string("none")],
            exporter: exporter,
            captureDestination: {
                captureCount += 1
                return destinationA
            },
            canonicalOperation: { _ in
                XCTAssertEqual(captureCount, 1)
                await Task.yield()
                ambientRoot = rootB
                return self.snapshot(
                    sessionID: UUID(),
                    status: .completed,
                    text: "captured before wait"
                )
            }
        )

        XCTAssertEqual(ambientRoot, rootB)
        XCTAssertEqual(captureCount, 1)
        let capturedWrites = await recorder.writes()
        let write = try XCTUnwrap(capturedWrites.first)
        XCTAssertEqual(write.destination.primaryRootPath, rootA.path)
        XCTAssertTrue(write.path.hasPrefix(rootA.path + "/"))
        XCTAssertNil(result.objectValue?["assistant_text"])
    }

    func testRequestBoundDestinationCaptureInheritsCallerTaskLocalIdentity() async throws {
        let callerConnectionID = UUID()
        let callerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-local-caller")
        let ambientRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-local-ambient")
        let callerDestination = makeDestination(root: callerRoot)
        let ambientDestination = makeDestination(root: ambientRoot)
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)
        var observedConnectionID: UUID?

        let result = try await ServerNetworkManager.withConnectionID(callerConnectionID) {
            try await AgentRunResponsePresentation.execute(
                args: ["op": .string("wait"), "response_mode": .string("none")],
                exporter: exporter,
                captureDestination: {
                    observedConnectionID = ServerNetworkManager.currentConnectionID
                    return observedConnectionID == callerConnectionID
                        ? callerDestination
                        : ambientDestination
                },
                canonicalOperation: { _ in
                    self.snapshot(
                        sessionID: UUID(),
                        status: .completed,
                        text: "caller-owned destination"
                    )
                }
            )
        }

        XCTAssertEqual(observedConnectionID, callerConnectionID)
        let writes = await recorder.writes()
        let write = try XCTUnwrap(writes.first)
        XCTAssertEqual(write.destination.primaryRootPath, callerRoot.path)
        XCTAssertTrue(write.path.hasPrefix(callerRoot.path + "/"))
        XCTAssertFalse(write.path.hasPrefix(ambientRoot.path + "/"))
        XCTAssertNil(result.objectValue?["assistant_text"])
    }

    func testActionableContextOverridesTrimAndPreservesControlMetadata() async throws {
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)
        let interaction: Value = .object([
            "id": .string(UUID().uuidString),
            "kind": .string("question"),
            "content": .object(["question": .string("Continue?")])
        ])
        let canonical = snapshot(
            sessionID: UUID(),
            status: .waitingForInput,
            text: "Context required to answer",
            extras: [
                "interaction": interaction,
                "interaction_id": .string(UUID().uuidString),
                "_meta": .object(["wait_result": .string("snapshot_ready")]),
                "wait": .object(["pending_session_ids": .array([.string("child")])]),
                "unknown_control": .string("preserve")
            ]
        )

        let result = try await execute(
            canonical: canonical,
            mode: .none,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["assistant_text"]?.stringValue, "Context required to answer")
        XCTAssertEqual(
            presentation(in: object)?["response_mode"]?.stringValue,
            OracleResponseMode.full.rawValue
        )
        XCTAssertEqual(
            presentation(in: object)?["safety_override"]?.stringValue,
            "actionable_context_preserved"
        )
        XCTAssertEqual(object["interaction"], interaction)
        XCTAssertEqual(object["_meta"], canonical.objectValue?["_meta"])
        XCTAssertEqual(object["wait"], canonical.objectValue?["wait"])
        XCTAssertEqual(object["unknown_control"]?.stringValue, "preserve")
        let writes = await recorder.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testTailUsesTwoThousandSwiftCharactersOnlyForPrimaryAndReferencesNestedTerminals() async throws {
        let primaryID = UUID()
        let nestedID = UUID()
        let primaryText = String(repeating: "🙂", count: 2050) + "\nPRIMARY-END"
        let nestedText = String(repeating: "é", count: 2100) + "\nNESTED-END"
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)

        var root = try XCTUnwrap(snapshot(
            sessionID: primaryID,
            status: .completed,
            text: primaryText,
            extras: [
                "_meta": .object(["wait_result": .string("snapshot_ready")]),
                "wait": .object(["winner_session_id": .string(primaryID.uuidString)]),
                "unknown_control": .int(19)
            ]
        ).objectValue)
        root["snapshots"] = .array([
            snapshot(sessionID: primaryID, status: .completed, text: primaryText),
            snapshot(sessionID: nestedID, status: .failed, text: nestedText)
        ])

        let result = try await execute(
            canonical: .object(root),
            mode: .tail,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)
        let excerpt = try XCTUnwrap(object["assistant_text"]?.stringValue)
        XCTAssertEqual(excerpt.count, OracleResponseMode.tailExcerptCharacterBudget)
        XCTAssertTrue(excerpt.hasSuffix("PRIMARY-END"))
        XCTAssertEqual(
            presentation(in: object)?["character_count"]?.intValue,
            primaryText.count
        )
        XCTAssertEqual(
            presentation(in: object)?["response_mode"]?.stringValue,
            OracleResponseMode.tail.rawValue
        )

        let nested = try XCTUnwrap(object["snapshots"]?.arrayValue)
        XCTAssertEqual(nested.count, 2)
        let firstNestedObject = try XCTUnwrap(nested[0].objectValue)
        let secondNestedObject = try XCTUnwrap(nested[1].objectValue)
        XCTAssertNil(firstNestedObject["assistant_text"])
        XCTAssertNil(secondNestedObject["assistant_text"])
        let primaryPath = try XCTUnwrap(presentation(in: object)?["export_path"]?.stringValue)
        XCTAssertEqual(
            presentation(in: firstNestedObject)?["export_path"]?.stringValue,
            primaryPath,
            "The duplicate top-level snapshot must reuse the same verified export"
        )
        XCTAssertEqual(
            presentation(in: firstNestedObject)?["response_mode"]?.stringValue,
            OracleResponseMode.none.rawValue
        )
        XCTAssertEqual(
            presentation(in: secondNestedObject)?["response_mode"]?.stringValue,
            OracleResponseMode.none.rawValue
        )

        let writes = await recorder.writes()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(Set(writes.map(\.content)), Set([primaryText, nestedText]))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(result), encoding: .utf8))
        XCTAssertFalse(encoded.contains(primaryText))
        XCTAssertFalse(encoded.contains(nestedText))
        XCTAssertEqual(object["_meta"], root["_meta"])
        XCTAssertEqual(object["wait"], root["wait"])
        XCTAssertEqual(object["unknown_control"]?.intValue, 19)
    }

    func testCollectionOnlyMultiPollUsesReferenceOnlyPresentation() async throws {
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)
        let value: Value = .object([
            "poll": .object([
                "mode": .string("many"),
                "polled_count": .int(2)
            ]),
            "snapshots": .array([
                snapshot(sessionID: UUID(), status: .completed, text: "first"),
                snapshot(sessionID: UUID(), status: .cancelled, text: "second")
            ])
        ])

        let result = try await execute(
            canonical: value,
            mode: .tail,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["poll"], value.objectValue?["poll"])
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        XCTAssertEqual(snapshots.count, 2)
        for snapshot in snapshots {
            let snapshotObject = try XCTUnwrap(snapshot.objectValue)
            XCTAssertNil(snapshotObject["assistant_text"])
            XCTAssertEqual(
                presentation(in: snapshotObject)?["response_mode"]?.stringValue,
                OracleResponseMode.none.rawValue
            )
            XCTAssertNotNil(presentation(in: snapshotObject)?["export_path"]?.stringValue)
        }
        let writes = await recorder.writes()
        XCTAssertEqual(writes.count, 2)
    }

    func testCollectionExportFailureAndActionableOverrideReachTextWire() async throws {
        let terminalText = "TERMINAL EXPORT FAILURE BODY"
        let actionableText = "ACTIONABLE RESPONSE BODY"
        let sleeper = ManualSleep()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 },
            write: { _, _, _ in
                throw MCPError.internalError("forced export failure")
            },
            remove: { _, _ in }
        )
        let canonical: Value = .object([
            "poll": .object([
                "mode": .string("many"),
                "polled_count": .int(2)
            ]),
            "snapshots": .array([
                snapshot(sessionID: UUID(), status: .completed, text: terminalText),
                snapshot(sessionID: UUID(), status: .waitingForInput, text: actionableText)
            ])
        ])

        let result = try await execute(
            canonical: canonical,
            mode: .none,
            exporter: exporter
        )
        let wireText = try agentRunWireText(
            args: ["op": .string("poll")],
            value: result
        )

        XCTAssertTrue(wireText.contains(terminalText), wireText)
        XCTAssertTrue(wireText.contains(actionableText), wireText)
        XCTAssertTrue(wireText.contains("- Export warning:"), wireText)
        XCTAssertTrue(wireText.contains("forced export failure"), wireText)
    }

    func testWaitAnyNestedTerminalRetrievalReachesTextWire() async throws {
        let primaryID = UUID()
        let siblingID = UUID()
        let primaryText = "PRIMARY TERMINAL BODY"
        let siblingText = "SIBLING TERMINAL BODY"
        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)
        var root = try XCTUnwrap(snapshot(
            sessionID: primaryID,
            status: .completed,
            text: primaryText,
            extras: [
                "wait": .object([
                    "mode": .string("any"),
                    "result": .string("snapshot_ready"),
                    "waited_count": .int(2),
                    "winner_session_id": .string(primaryID.uuidString)
                ])
            ]
        ).objectValue)
        root["snapshots"] = .array([
            snapshot(sessionID: primaryID, status: .completed, text: primaryText),
            snapshot(sessionID: siblingID, status: .failed, text: siblingText)
        ])

        let result = try await execute(
            canonical: .object(root),
            mode: .none,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)
        let snapshots = try XCTUnwrap(object["snapshots"]?.arrayValue)
        let sibling = try XCTUnwrap(snapshots[1].objectValue)
        let siblingPath = try XCTUnwrap(
            presentation(in: sibling)?["export_path"]?.stringValue
        )
        let wireText = try agentRunWireText(
            args: ["op": .string("wait")],
            value: result
        )

        XCTAssertTrue(wireText.contains("- Additional result: `\(siblingID.uuidString)`"), wireText)
        XCTAssertTrue(wireText.contains(siblingPath), wireText)
        XCTAssertTrue(wireText.contains("- Retrieval:"), wireText)
        XCTAssertFalse(wireText.contains(siblingText), wireText)
    }

    func testResponseWideFallbackPreservesCollectionAndReachesTextWire() async throws {
        let preparationGate = ExportGate()
        let sleeper = ManualSleep()
        let clock = ManualClock()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { clock.now() },
            beforePrepare: { await preparationGate.enter() },
            write: { path, _, _ in path },
            remove: { _, _ in }
        )
        let snapshots = (0 ..< 64).map { index in
            snapshot(
                sessionID: UUID(),
                status: .completed,
                text: "FULL FALLBACK BODY \(index)"
            )
        }
        let canonical: Value = .object([
            "poll": .object([
                "mode": .string("many"),
                "polled_count": .int(snapshots.count)
            ]),
            "snapshots": .array(snapshots)
        ])

        let task = Task { @MainActor in
            try await self.execute(
                canonical: canonical,
                mode: .none,
                exporter: exporter
            )
        }
        await preparationGate.waitUntilEntered()
        clock.advance(to: 1)
        sleeper.fire()

        let result = try await task.value
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["snapshots"], canonical.objectValue?["snapshots"])
        XCTAssertEqual(
            presentation(in: object)?["response_mode"]?.stringValue,
            OracleResponseMode.full.rawValue
        )
        let wireText = try agentRunWireText(
            args: ["op": .string("poll")],
            value: result
        )
        XCTAssertTrue(wireText.contains("- Export warning:"), wireText)
        XCTAssertTrue(wireText.contains("FULL FALLBACK BODY 0"), wireText)
        XCTAssertTrue(wireText.contains("FULL FALLBACK BODY 63"), wireText)

        await preparationGate.release()
        await exporter.testWaitUntilIdle()
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testAuthorizedWriterProducesImmediatelyReadableExactResult() async throws {
        let root = try makeTemporaryRoot(name: "AgentResponseReadable")
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let destination = makeDestination(root: root)
        let sleeper = ManualSleep()
        let exporter = AgentRunResponseExportAdapter(
            store: store,
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 }
        )
        let text = "Exact assistant result\nwith a second line 🙂"

        let result = try await execute(
            canonical: snapshot(
                sessionID: UUID(),
                status: .completed,
                text: text
            ),
            mode: .none,
            destination: destination,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertNil(object["assistant_text"])
        let metadata = try XCTUnwrap(presentation(in: object))
        let path = try XCTUnwrap(metadata["export_path"]?.stringValue)
        XCTAssertTrue(
            metadata["retrieval_instruction"]?.stringValue?.contains(path) == true
        )
        XCTAssertEqual(metadata["character_count"]?.intValue, text.count)
        XCTAssertEqual(metadata["line_count"]?.intValue, 2)

        let readable = await WorkspaceReadableFileService(store: store).resolveReadableFile(
            path,
            profile: .mcpRead,
            rootScope: destination.lookupContext.rootScope
        )
        guard case let .workspace(file) = readable else {
            return XCTFail("Advertised result must be readable through read_file semantics")
        }
        let readback = try await store.readContent(
            rootID: rootRecord.id,
            relativePath: file.standardizedRelativePath
        )
        XCTAssertEqual(readback, text)
        await GeneratedOracleExportFileWriter(store: store).remove(
            path: path,
            destination: destination
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testWrongOwnerWriterFailureFallsBackToFull() async throws {
        let root = try makeTemporaryRoot(name: "AgentResponseWrongOwner")
        let store = WorkspaceFileContextStore()
        let destination = makeDestination(root: root)
        let sleeper = ManualSleep()
        let exporter = AgentRunResponseExportAdapter(
            store: store,
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 }
        )
        let text = "must remain inline"

        let result = try await execute(
            canonical: snapshot(
                sessionID: UUID(),
                status: .completed,
                text: text
            ),
            mode: .none,
            destination: destination,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["assistant_text"]?.stringValue, text)
        XCTAssertEqual(
            presentation(in: object)?["response_mode"]?.stringValue,
            OracleResponseMode.full.rawValue
        )
        XCTAssertTrue(
            presentation(in: object)?["export_warning"]?.stringValue?
                .contains("not loaded in the bound read_file workspace scope") == true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("prompt-exports").path
            )
        )
    }

    func testResponseWideDeadlineReturnsFullAndOwnsLateOffMainCleanup() async throws {
        let root = try makeTemporaryRoot(name: "AgentResponseDeadline")
        let store = WorkspaceFileContextStore()
        let rootRecord = try await store.loadRoot(path: root.path)
        let destination = makeDestination(root: root)
        let writeGate = ExportGate()
        let sleeper = ManualSleep()
        let clock = ManualClock()
        let recorder = ExportRecorder()
        let exporter = AgentRunResponseExportAdapter(
            store: store,
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { clock.now() },
            afterWrite: {
                await recorder.recordThreadWasMain(observedMainThread())
                await writeGate.enter()
            }
        )
        let text = "late but verified"

        let task = Task { @MainActor in
            try await self.execute(
                canonical: self.snapshot(
                    sessionID: UUID(),
                    status: .completed,
                    text: text
                ),
                mode: .tail,
                destination: destination,
                exporter: exporter
            )
        }
        await writeGate.waitUntilEntered()
        XCTAssertGreaterThanOrEqual(exporter.testActiveTaskCount(), 1)
        let exportPath = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("prompt-exports"),
                includingPropertiesForKeys: nil
            )?.allObjects.compactMap { ($0 as? URL)?.path }.first
        )
        clock.advance(to: 1)
        sleeper.fire()

        let result = try await task.value
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["assistant_text"]?.stringValue, text)
        XCTAssertEqual(
            presentation(in: object)?["response_mode"]?.stringValue,
            OracleResponseMode.full.rawValue
        )
        XCTAssertTrue(
            presentation(in: object)?["export_warning"]?.stringValue?
                .contains("one-second response presentation budget") == true
        )

        await store.unloadRoot(id: rootRecord.id)
        await writeGate.release()
        await exporter.testWaitUntilIdle()
        let threadWasMain = await recorder.threadWasMain()
        XCTAssertEqual(threadWasMain, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath))
        XCTAssertEqual(exporter.testCleanupFailureCount(), 0)
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testCallerCancellationOwnsLateArtifactCleanup() async throws {
        let root = try makeTemporaryRoot(name: "AgentResponseCancellation")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let destination = makeDestination(root: root)
        let writeGate = ExportGate()
        let sleeper = ManualSleep()
        let exporter = AgentRunResponseExportAdapter(
            store: store,
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 },
            afterWrite: { await writeGate.enter() }
        )

        let task = Task { @MainActor in
            try await self.execute(
                canonical: self.snapshot(
                    sessionID: UUID(),
                    status: .completed,
                    text: "cancelled caller"
                ),
                mode: .none,
                destination: destination,
                exporter: exporter
            )
        }
        await writeGate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled presentation must propagate cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertGreaterThanOrEqual(exporter.testActiveTaskCount(), 1)
        let exportPath = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("prompt-exports"),
                includingPropertiesForKeys: nil
            )?.allObjects.compactMap { ($0 as? URL)?.path }.first
        )
        await writeGate.release()
        await exporter.testWaitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath))
        XCTAssertEqual(exporter.testCleanupFailureCount(), 0)
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testCancellationCleansCollectedAndLateSuccessfulExports() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let secondWriteGate = ExportGate()
        let published = PublicationSignal()
        let sleeper = ManualSleep()
        let recorder = ExportRecorder()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 },
            didPublish: { published.record($0) },
            write: { path, content, destination in
                await recorder.recordWrite(
                    path: path,
                    content: content,
                    destination: destination
                )
                if content == "second" {
                    await secondWriteGate.enter()
                }
                return path
            },
            remove: { path, _ in
                await recorder.recordRemoval(path: path)
            }
        )
        let requests = [
            AgentRunResponseExportRequest(index: 0, sessionID: "first", content: "first"),
            AgentRunResponseExportRequest(index: 1, sessionID: "second", content: "second")
        ]

        let task = Task {
            try await exporter.export(requests, destination: destination)
        }
        await published.wait(for: 0)
        await secondWriteGate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop delivery of a partially collected batch")
        } catch is CancellationError {
            // Expected.
        }

        await secondWriteGate.release()
        let firstRemoval = await recorder.waitForRemoval()
        let secondRemoval = await recorder.waitForRemoval()
        await exporter.testWaitUntilIdle()
        let writtenPaths = await Set(recorder.writes().map(\.path))
        XCTAssertEqual(Set([firstRemoval, secondRemoval]), writtenPaths)
        XCTAssertEqual(exporter.testCleanupFailureCount(), 0)
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testLatePublishCannotBeatAbsoluteDeadlineWhenTimerDeliveryIsDelayed() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let writeGate = ExportGate()
        let sleeper = ManualSleep()
        let clock = ManualClock()
        let recorder = ExportRecorder()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { clock.now() },
            write: { path, content, destination in
                await recorder.recordWrite(
                    path: path,
                    content: content,
                    destination: destination
                )
                await writeGate.enter()
                return path
            },
            remove: { path, _ in
                await recorder.recordRemoval(path: path)
            }
        )

        let task = Task {
            try await exporter.export(
                [AgentRunResponseExportRequest(index: 0, sessionID: "late", content: "late")],
                destination: destination
            )
        }
        await writeGate.waitUntilEntered()
        clock.advance(to: 1)
        await writeGate.release()

        let outcomes = try await task.value
        XCTAssertTrue(outcomes.isEmpty)
        _ = await recorder.waitForRemoval()
        await exporter.testWaitUntilIdle()
        XCTAssertEqual(exporter.testCleanupFailureCount(), 0)
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testSlowCaptureConsumesBudgetWithoutDelayingCanonicalExecution() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let captureGate = ExportGate()
        let sleeper = ManualSleep()
        let clock = ManualClock()
        let recorder = ExportRecorder()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { clock.now() },
            write: { path, content, destination in
                await recorder.recordWrite(
                    path: path,
                    content: content,
                    destination: destination
                )
                return path
            },
            remove: { path, _ in await recorder.recordRemoval(path: path) }
        )
        var canonicalExecutions = 0

        let task = Task { @MainActor in
            try await AgentRunResponsePresentation.execute(
                args: [
                    "op": .string("poll"),
                    "response_mode": .string("none")
                ],
                exporter: exporter,
                captureDestination: {
                    await captureGate.enter()
                    return destination
                },
                canonicalOperation: { _ in
                    canonicalExecutions += 1
                    return self.snapshot(
                        sessionID: UUID(),
                        status: .completed,
                        text: "capture timed out"
                    )
                }
            )
        }
        await captureGate.waitUntilEntered()
        clock.advance(to: 1)
        sleeper.fire()

        let result = try await task.value
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(canonicalExecutions, 1)
        XCTAssertEqual(object["assistant_text"]?.stringValue, "capture timed out")
        XCTAssertTrue(
            presentation(in: object)?["export_warning"]?.stringValue?
                .contains("one-second response presentation budget") == true
        )
        let captureWrites = await recorder.writes()
        XCTAssertTrue(captureWrites.isEmpty)
        XCTAssertGreaterThanOrEqual(exporter.testActiveTaskCount(), 1)

        await captureGate.release()
        await exporter.testWaitUntilIdle()
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testPreparationSchedulingConsumesRemainingAbsoluteBudgetOffMainThread() async throws {
        let destination = makeDestination(root: FileManager.default.temporaryDirectory)
        let preparationGate = ExportGate()
        let sleeper = ManualSleep()
        let clock = ManualClock()
        let recorder = ExportRecorder()
        let exporter = AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { clock.now() },
            beforePrepare: {
                await recorder.recordThreadWasMain(observedMainThread())
                await preparationGate.enter()
            },
            write: { path, content, destination in
                await recorder.recordWrite(
                    path: path,
                    content: content,
                    destination: destination
                )
                return path
            },
            remove: { path, _ in await recorder.recordRemoval(path: path) }
        )

        let task = Task { @MainActor in
            try await self.execute(
                canonical: self.snapshot(
                    sessionID: UUID(),
                    status: .completed,
                    text: "preparation timed out"
                ),
                mode: .none,
                destination: destination,
                exporter: exporter
            )
        }
        await preparationGate.waitUntilEntered()
        clock.advance(to: 1)
        sleeper.fire()

        let result = try await task.value
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["assistant_text"]?.stringValue, "preparation timed out")
        let preparationThreadWasMain = await recorder.threadWasMain()
        XCTAssertEqual(preparationThreadWasMain, false)
        XCTAssertTrue(
            presentation(in: object)?["export_warning"]?.stringValue?
                .contains("one-second response presentation budget") == true
        )

        await preparationGate.release()
        await exporter.testWaitUntilIdle()
        let preparationWrites = await recorder.writes()
        XCTAssertTrue(preparationWrites.isEmpty)
        XCTAssertEqual(exporter.testActiveTaskCount(), 0)
    }

    func testCanonicalEquivalentUnicodeUsesByteExactExportIdentity() async throws {
        let sessionID = UUID()
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(precomposed, decomposed)

        let recorder = ExportRecorder()
        let sleeper = ManualSleep()
        let exporter = recordedExporter(recorder: recorder, sleeper: sleeper)
        var root = try XCTUnwrap(
            snapshot(
                sessionID: sessionID,
                status: .completed,
                text: precomposed
            ).objectValue
        )
        root["snapshots"] = .array([
            snapshot(
                sessionID: sessionID,
                status: .completed,
                text: decomposed
            )
        ])

        let result = try await execute(
            canonical: .object(root),
            mode: .none,
            exporter: exporter
        )
        let object = try XCTUnwrap(result.objectValue)
        let nested = try XCTUnwrap(object["snapshots"]?.arrayValue?.first?.objectValue)
        XCTAssertNotEqual(
            presentation(in: object)?["export_path"]?.stringValue,
            presentation(in: nested)?["export_path"]?.stringValue
        )
        let writes = await recorder.writes()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(Set(writes.map { Data($0.content.utf8) }).count, 2)
        XCTAssertEqual(
            Set(writes.map { Data($0.content.utf8) }),
            Set([Data(precomposed.utf8), Data(decomposed.utf8)])
        )
    }

    private func agentRunWireText(
        args: [String: Value],
        value: Value
    ) throws -> String {
        let content = try XCTUnwrap(
            ToolOutputFormatter.formatAgentRun(args: args, value: value).first
        )
        guard case let .text(text, _, _) = content else {
            XCTFail("Expected Agent Run text wire content")
            return ""
        }
        return text
    }

    private func execute(
        canonical: Value,
        mode: OracleResponseMode,
        destination: OracleExportDestination? = nil,
        exporter: AgentRunResponseExportAdapter
    ) async throws -> Value {
        let captured = destination ?? makeDestination(
            root: FileManager.default.temporaryDirectory
        )
        return try await AgentRunResponsePresentation.execute(
            args: [
                "op": .string("poll"),
                "response_mode": .string(mode.rawValue)
            ],
            exporter: exporter,
            captureDestination: { captured },
            canonicalOperation: { args in
                XCTAssertNil(args["response_mode"])
                return canonical
            }
        )
    }

    private func snapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status,
        text: String?,
        extras: [String: Value] = [:]
    ) -> Value {
        var object: [String: Value] = [
            "session_id": .string(sessionID.uuidString),
            "status": .string(status.rawValue),
            "transcript_item_count": .int(1),
            "session": .object([
                "id": .string(sessionID.uuidString),
                "name": .string("Worker")
            ])
        ]
        if let text {
            object["assistant_text"] = .string(text)
        }
        for (key, value) in extras {
            object[key] = value
        }
        return .object(object)
    }

    private func presentation(
        in object: [String: Value]
    ) -> [String: Value]? {
        object[AgentRunResponsePresentation.presentationKey]?.objectValue
    }

    private func makeDestination(root: URL) -> OracleExportDestination {
        OracleExportDestination(
            workspaceID: UUID(),
            windowID: 1,
            tabID: UUID(),
            primaryRootPath: root.path
        )
    }

    private func immediateExporter() -> AgentRunResponseExportAdapter {
        let sleeper = ManualSleep()
        return recordedExporter(recorder: ExportRecorder(), sleeper: sleeper)
    }

    private func recordedExporter(
        recorder: ExportRecorder,
        sleeper: ManualSleep
    ) -> AgentRunResponseExportAdapter {
        AgentRunResponseExportAdapter(
            budgetNanoseconds: 1,
            sleep: { _ in try await sleeper.sleep() },
            now: { 0 },
            write: { path, content, destination in
                await recorder.recordWrite(path: path, content: content, destination: destination)
                return path
            },
            remove: { path, _ in await recorder.recordRemoval(path: path) }
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCE-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private func observedMainThread() -> Bool {
    Thread.isMainThread
}

private final class PublicationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var published: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ index: Int) {
        lock.lock()
        published.insert(index)
        let continuations = waiters.removeValue(forKey: index) ?? []
        lock.unlock()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait(for index: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if published.contains(index) {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[index, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class ManualSleep: @unchecked Sendable {
    private enum Waiter {
        case registering
        case waiting(CheckedContinuation<Void, Error>)
        case wakePending
        case cancellationPending
    }

    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]

    func sleep() async throws {
        let id = UUID()
        lock.lock()
        waiters[id] = .registering
        lock.unlock()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                let waiter = waiters[id]
                switch waiter {
                case .registering:
                    if Task.isCancelled {
                        waiters.removeValue(forKey: id)
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = .waiting(continuation)
                        lock.unlock()
                    }
                case .wakePending:
                    waiters.removeValue(forKey: id)
                    lock.unlock()
                    continuation.resume()
                case .cancellationPending:
                    waiters.removeValue(forKey: id)
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                case .waiting, nil:
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func fire() {
        lock.lock()
        var pending: [CheckedContinuation<Void, Error>] = []
        for id in Array(waiters.keys) {
            guard let waiter = waiters[id] else { continue }
            switch waiter {
            case .registering:
                waiters[id] = .wakePending
            case let .waiting(continuation):
                waiters.removeValue(forKey: id)
                pending.append(continuation)
            case .wakePending, .cancellationPending:
                break
            }
        }
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        lock.lock()
        let continuation: CheckedContinuation<Void, Error>?
        switch waiters[id] {
        case .registering, .wakePending:
            waiters[id] = .cancellationPending
            continuation = nil
        case let .waiting(waiting):
            waiters.removeValue(forKey: id)
            continuation = waiting
        case .cancellationPending, nil:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor ExportGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ExportRecorder {
    struct WriteRecord {
        let path: String
        let content: String
        let destination: OracleExportDestination
    }

    private var writeRecords: [WriteRecord] = []
    private var removedPaths: [String] = []
    private var removalWaiters: [CheckedContinuation<String, Never>] = []
    private var observedThreadWasMain: Bool?

    func recordWrite(
        path: String,
        content: String,
        destination: OracleExportDestination
    ) {
        writeRecords.append(WriteRecord(
            path: path,
            content: content,
            destination: destination
        ))
    }

    func writes() -> [WriteRecord] {
        writeRecords
    }

    func recordRemoval(path: String) {
        if let waiter = removalWaiters.first {
            removalWaiters.removeFirst()
            waiter.resume(returning: path)
        } else {
            removedPaths.append(path)
        }
    }

    func waitForRemoval() async -> String {
        if !removedPaths.isEmpty {
            return removedPaths.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            removalWaiters.append(continuation)
        }
    }

    func recordThreadWasMain(_ value: Bool) {
        observedThreadWasMain = value
    }

    func threadWasMain() -> Bool? {
        observedThreadWasMain
    }
}
