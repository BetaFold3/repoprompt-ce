@testable import RepoPromptApp
import XCTest

/// Field-local `providerUsage` preservation and accounting hydration contracts (plan §3.3, §8).
///
/// Persisted data always flows through `AgentSessionDataCodec`; raw bytes are the authoritative
/// representation and a typed v1 view is only derived when it provably reproduces those bytes.
final class AgentUsagePersistenceTests: XCTestCase {
    private let sessionID = UUID()
    private let owner = UUID()
    private let execution = UUID()
    private let recordTurnID = UUID()
    private let precisionJSON = #"{"schemaVersion":99,"cost":2.1710000000000000000001,"big":123456789012345678901234567890,"tiny":-0.000000000000000000001,"nested":{"list":[1,"two",null,true,{"k":0.10}]}}"#

    func testProviderUsageDecodeStatesPreserveAbsentNullOpaqueAndLosslessRecord() throws {
        // Absent stays absent and is omitted on encode.
        let absent = try decodeSession(providerUsageJSON: nil)
        XCTAssertNil(absent.providerUsage)
        XCTAssertFalse(try encodedString(absent).contains("providerUsage"))

        // Explicit null is preserved as raw null, not dropped and not treated as absent.
        let explicitNull = try decodeSession(providerUsageJSON: "null")
        XCTAssertEqual(explicitNull.providerUsage, .opaque(.null))
        XCTAssertNil(explicitNull.providerUsage?.record)
        XCTAssertTrue(try encodedString(explicitNull).contains(#""providerUsage":null"#))

        // Unknown schema, malformed shape, unknown members, numeric precision, nested duplicate keys and
        // whitespace formatting stay opaque and are written back byte-for-byte.
        for opaqueJSON in [
            #"{"schemaVersion":2,"turns":"future"}"#,
            #""not an object""#,
            #"[1,2,3]"#,
            #"{"schemaVersion":1,"originSessionID":"garbage"}"#,
            #"{"schemaVersion":1,"dup":1,"dup":2}"#,
            #"{ "schemaVersion" : 3 , "list" : [ 1 , 2.50 , "xA\n" ] }"#,
            #"{"schemaVersion":99,"value":1e1000}"#,
            precisionJSON
        ] {
            let session = try decodeSession(providerUsageJSON: opaqueJSON)
            XCTAssertEqual(session.providerUsage, try .opaque(raw(opaqueJSON)), opaqueJSON)
            XCTAssertNil(session.providerUsage?.record, opaqueJSON)
            let encoded = try AgentSessionDataCodec.encodeSession(session)
            XCTAssertEqual(try providerUsageText(in: encoded), opaqueJSON)
            let reloaded = try AgentSessionDataCodec.decodeSession(from: encoded)
            XCTAssertEqual(reloaded.providerUsage, session.providerUsage, opaqueJSON)
            XCTAssertEqual(reloaded.name, "Usage Session")
        }

        // A valid v1 record keeps its raw bytes as the persisted representation and projects a typed view.
        let record = makeRecord()
        let recordJSON = try recordText(record)
        let typed = try decodeSession(providerUsageJSON: recordJSON)
        XCTAssertEqual(typed.providerUsage, try .opaque(raw(recordJSON)))
        XCTAssertEqual(typed.providerUsage?.record, record)
        XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(typed)), recordJSON)

        // Member order is not significant for the typed view; bytes are still preserved as written.
        let claudeSegmentsText = try memberText(recordJSON, "claudeSegments")
        let turnsText = try memberText(recordJSON, "turns")
        let reordered = #"{"claudeSegments":"# + claudeSegmentsText
            + #","turns":"# + turnsText
            + #","hasUnmeasuredHistory":true,"trackingStartedAtMilliseconds":1700000000500,"originSessionID":"\#(owner.uuidString)","schemaVersion":1}"#
        let reorderedSession = try decodeSession(providerUsageJSON: reordered)
        XCTAssertEqual(reorderedSession.providerUsage?.record, record)
        XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(reorderedSession)), reordered)

        // Unknown members at any level, or explicit null members, remove the typed view but never the bytes.
        let unknownMemberVariants: [String] = try [
            String(recordJSON.dropLast()) + #","futureMember":{"x":1}}"#,
            String(recordJSON.dropLast()) + #","extraNull":null}"#,
            replacing(recordJSON, #""segmentIndex":0"#, with: #""segmentIndex":0,"futureTurnField":true"#),
            replacing(recordJSON, #""provider":"claude""#, with: #""provider":"claude","futureSegmentField":null"#)
        ]
        for text in unknownMemberVariants {
            let session = try decodeSession(providerUsageJSON: text)
            XCTAssertNil(session.providerUsage?.record, text)
            XCTAssertEqual(session.providerUsage?.rawValue?.text, text)
            XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(session)), text)
        }

        // Ambiguous duplicate top-level members and syntactically invalid JSON are still load errors.
        XCTAssertThrowsError(try AgentSessionDataCodec.decodeSession(from: Data(envelope(members: [
            #""providerUsage": {"schemaVersion":1}"#,
            #""providerUsage": null"#
        ]).utf8)))
        XCTAssertThrowsError(try decodeSession(providerUsageJSON: "{unterminated"))
        XCTAssertThrowsError(try decodeSession(providerUsageJSON: "01"))
        XCTAssertThrowsError(try decodeSession(providerUsageJSON: "1."))
        XCTAssertThrowsError(try decodeSession(providerUsageJSON: #"{"a":1,}"#))
        XCTAssertThrowsError(try decodeSession(providerUsageJSON: "nul"))
    }

    func testProviderUsageArbitraryNumericLexemesSurviveAndOnlyExactValuesProject() throws {
        let record = makeRecord()
        let recordJSON = try recordText(record)
        let latest = #""latestCumulative":2.171"#
        let exactlyRepresentablePowerOfTen = "100000000000000000000000000000000000000000000000000"
        XCTAssertTrue(recordJSON.contains(latest))

        // Beyond Decimal precision or exponent range: transcript loads, bytes survive, no typed view
        // (never a rounded, clamped, or empty replacement).
        let opaqueLexemes = [
            "1234567890123456789012345678901234567890123.4567890123",
            "2.1710000000000000000000000000000000000000001",
            "1e200",
            "1e-200",
            "1e1000",
            "1E-1000",
            "9e99999999999999999999"
        ]
        for lexeme in opaqueLexemes {
            let json = try replacing(recordJSON, latest, with: #""latestCumulative":\#(lexeme)"#)
            let session = try decodeSession(providerUsageJSON: json)
            XCTAssertEqual(session.providerUsage?.rawValue?.text, json, lexeme)
            XCTAssertNil(session.providerUsage?.record, lexeme)
            let encoded = try AgentSessionDataCodec.encodeSession(session)
            XCTAssertEqual(try providerUsageText(in: encoded), json, lexeme)
            XCTAssertEqual(try AgentSessionDataCodec.decodeSession(from: encoded).providerUsage, session.providerUsage, lexeme)
            let stub = try AgentSessionDataCodec.decodeEnvelope(AgentSessionStubProbe.self, from: encoded)
            XCTAssertEqual(stub.value.name, "Usage Session", lexeme)
            XCTAssertEqual(stub.providerUsage, session.providerUsage, lexeme)
        }

        // Lexemes the typed record reproduces exactly (value-identical, formatting aside) keep the
        // typed view while the persisted representation remains the original bytes.
        for (lexeme, expected) in try [
            ("1E+5", Decimal(100_000)),
            ("0.10", XCTUnwrap(Decimal(string: "0.10"))),
            ("2.171000", XCTUnwrap(Decimal(string: "2.171"))),
            ("12345678901234567890123456789012345678", XCTUnwrap(Decimal(string: "12345678901234567890123456789012345678"))),
            (exactlyRepresentablePowerOfTen, XCTUnwrap(Decimal(string: exactlyRepresentablePowerOfTen)))
        ] {
            let json = try replacing(recordJSON, latest, with: #""latestCumulative":\#(lexeme)"#)
            let session = try decodeSession(providerUsageJSON: json)
            XCTAssertEqual(session.providerUsage?.record?.claudeSegments.first?.latestCumulative, expected, lexeme)
            XCTAssertEqual(session.providerUsage, try .opaque(raw(json)), lexeme)
            XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(session)), json, lexeme)
        }

        // Negative zero is preserved verbatim whatever Decimal does with it.
        let negativeZero = try replacing(recordJSON, latest, with: #""latestCumulative":-0"#)
        XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(decodeSession(providerUsageJSON: negativeZero))), negativeZero)

        // The precision fixture's numeric text survives an envelope round trip untouched.
        let precisionText = try encodedString(decodeSession(providerUsageJSON: precisionJSON))
        XCTAssertTrue(precisionText.contains("2.1710000000000000000001"), precisionText)
        XCTAssertTrue(precisionText.contains("123456789012345678901234567890"), precisionText)
        XCTAssertTrue(precisionText.contains("-0.000000000000000000001"), precisionText)

        // Canonical lexeme comparison is value-based and never numeric.
        XCTAssertEqual(AgentProviderUsageJSONScanner.canonicalNumber(Array("1E+5".utf8)), "1e5")
        XCTAssertEqual(AgentProviderUsageJSONScanner.canonicalNumber(Array("100000".utf8)), "1e5")
        XCTAssertEqual(
            AgentProviderUsageJSONScanner.canonicalNumber(Array(exactlyRepresentablePowerOfTen.utf8)),
            "1e50"
        )
        XCTAssertEqual(AgentProviderUsageJSONScanner.canonicalNumber(Array("0.10".utf8)), "1e-1")
        XCTAssertEqual(AgentProviderUsageJSONScanner.canonicalNumber(Array("-0".utf8)), "-0")
        XCTAssertEqual(AgentProviderUsageJSONScanner.canonicalNumber(Array("0.000".utf8)), "0")
        XCTAssertNil(AgentProviderUsageJSONScanner.canonicalNumber(Array("1e99999999999999999999".utf8)))
    }

    func testProviderUsageSemanticViolationsStayOpaqueAndArePreservedVerbatim() throws {
        let recordJSON = try recordText(makeRecord())
        let turnObject = try String(memberText(recordJSON, "turns").dropFirst().dropLast())
        let violations: [(search: String, replace: String)] = [
            (#""inputTokens":10"#, #""inputTokens":-10"#),
            (#""cacheReadInputTokens":90"#, #""cacheReadInputTokens":-1"#),
            (#""observedRequestCount":1"#, #""observedRequestCount":-1"#),
            (#""baseline":0"#, #""baseline":5"#), // above latestCumulative 2.171
            (#""baseline":0"#, #""baseline":-1"#),
            (#""provider":"claude""#, #""provider":"openai""#),
            (#""currency":"USD""#, #""currency":"EUR""#),
            (#""contractID":"test.claude.cumulative.v1""#, #""contractID":"""#),
            (#""segmentIndex":0"#, #""segmentIndex":1"#), // invalid segment reference
            (#""segmentIndex":0"#, #""segmentIndex":-1"#),
            (#""resetGeneration":0"#, #""resetGeneration":-1"#),
            (#""acceptedResultOrder":1"#, #""acceptedResultOrder":-1"#),
            (#""schemaVersion":1"#, #""schemaVersion":"1""#), // malformed known version
            (#""schemaVersion":1"#, #""schemaVersion":1.5"#),
            (#""schemaVersion":1"#, #""schemaVersion":2"#),
            (#""trackingStartedAtMilliseconds":1700000000500"#, #""trackingStartedAtMilliseconds":-1"#),
            (#""outcome":"completed""#, #""outcome":"finished""#),
            (#""turns":["#, #""turns":[\#(turnObject),"#) // duplicate turnID
        ]
        for violation in violations {
            let json = try replacing(recordJSON, violation.search, with: violation.replace)
            let session = try decodeSession(providerUsageJSON: json)
            XCTAssertNil(session.providerUsage?.record, violation.replace)
            XCTAssertEqual(session.providerUsage?.rawValue?.text, json, violation.replace)
            XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(session)), json, violation.replace)
        }

        // A turn whose executionID does not match its segment is an invalid reference.
        // Rewrite the isolated turn object because keyed JSON member order is not stable.
        let foreignExecution = UUID().uuidString
        let mismatchedTurn = try replacing(
            turnObject,
            #""executionID":"\#(execution.uuidString)""#,
            with: #""executionID":"\#(foreignExecution)""#
        )
        let mismatched = try replacing(recordJSON, turnObject, with: mismatchedTurn)
        XCTAssertNil(try decodeSession(providerUsageJSON: mismatched).providerUsage?.record)

        // Counterexamples come from the accumulator itself: semantic validation must continue to
        // admit every legitimate lifecycle shape, including incomplete monetary observations.
        var idle = makeQualifiedAccumulator(baseline: .verifiedZero)
        idle.endExecution(execution)
        let idleState = try XCTUnwrap(idle.persistedRepresentation?.record)
        XCTAssertTrue(idleState.turns.isEmpty)
        XCTAssertEqual(idleState.claudeSegments.first?.state, .closed)
        XCTAssertEqual(idleState.claudeSegments.first?.coverage, .complete)

        var unknownBaseline = makeQualifiedAccumulator(baseline: .unknown)
        let unknownTurnID = UUID()
        unknownBaseline.registerTurn(unknownTurnID, executionID: execution)
        XCTAssertEqual(unknownBaseline.observe(result(unknownTurnID, id: "res-unknown", cost: "3.00")), .accepted)
        unknownBaseline.endExecution(execution)
        let unknownState = try XCTUnwrap(unknownBaseline.persistedRepresentation?.record)
        XCTAssertEqual(unknownState.claudeSegments.first?.baseline, Decimal(string: "3.00"))
        XCTAssertEqual(unknownState.claudeSegments.first?.coverage, .partial)

        var verifiedReset = makeQualifiedAccumulator(baseline: .verifiedZero)
        let beforeResetTurnID = UUID()
        verifiedReset.registerTurn(beforeResetTurnID, executionID: execution)
        XCTAssertEqual(verifiedReset.observe(result(beforeResetTurnID, id: "res-reset-1", cost: "1.00")), .accepted)
        XCTAssertEqual(verifiedReset.noteVerifiedReset(executionID: execution), .accepted)
        let afterResetTurnID = UUID()
        verifiedReset.registerTurn(afterResetTurnID, executionID: execution)
        XCTAssertEqual(verifiedReset.observe(result(afterResetTurnID, id: "res-reset-2", cost: "0.20")), .accepted)
        verifiedReset.endExecution(execution, outcome: .completed)
        let resetState = try XCTUnwrap(verifiedReset.persistedRepresentation?.record)
        XCTAssertEqual(resetState.claudeSegments.map(\.coverage), [.complete, .complete])

        var suspended = makeQualifiedAccumulator(baseline: .verifiedZero)
        let acceptedCheckpointTurnID = UUID()
        suspended.registerTurn(acceptedCheckpointTurnID, executionID: execution)
        XCTAssertEqual(suspended.observe(result(acceptedCheckpointTurnID, id: "res-suspend-1", cost: "1.00")), .accepted)
        let decreasedTurnID = UUID()
        suspended.registerTurn(decreasedTurnID, executionID: execution)
        XCTAssertEqual(
            suspended.observe(result(decreasedTurnID, id: "res-suspend-2", cost: "0.50")),
            .acceptedWithMonetaryRejection(.unexplainedDecrease)
        )
        suspended.endExecution(execution)
        let suspendedState = try XCTUnwrap(suspended.persistedRepresentation?.record)
        XCTAssertEqual(suspendedState.claudeSegments.first?.state, .suspended)
        XCTAssertEqual(suspendedState.claudeSegments.first?.coverage, .partial)

        var tokenOnly = makeQualifiedAccumulator(baseline: .verifiedZero)
        let tokenOnlyTurnID = UUID()
        tokenOnly.registerTurn(tokenOnlyTurnID, executionID: execution)
        XCTAssertEqual(
            tokenOnly.observe(result(
                tokenOnlyTurnID,
                id: "res-token-only",
                input: 10,
                output: 2,
                read: 90,
                creation: 0
            )),
            .accepted
        )
        let openTokenOnlyState = try XCTUnwrap(tokenOnly.persistedRepresentation?.record)
        XCTAssertEqual(openTokenOnlyState.claudeSegments.first?.state, .open)
        XCTAssertEqual(openTokenOnlyState.claudeSegments.first?.coverage, .complete)
        XCTAssertNil(openTokenOnlyState.semanticViolation, "open mid-run state may not claim final coverage yet")
        tokenOnly.endExecution(execution, outcome: .completed)
        let closedTokenOnlyState = try XCTUnwrap(tokenOnly.persistedRepresentation?.record)
        XCTAssertEqual(closedTokenOnlyState.claudeSegments.first?.state, .closed)
        XCTAssertEqual(closedTokenOnlyState.claudeSegments.first?.coverage, .partial)

        for (label, state) in [
            ("verified-zero no-turn", idleState),
            ("unknown baseline", unknownState),
            ("verified reset", resetState),
            ("suspended decrease", suspendedState),
            ("closed token-only", closedTokenOnlyState)
        ] {
            XCTAssertNil(state.semanticViolation, label)
            let json = try recordText(state)
            XCTAssertEqual(try decodeSession(providerUsageJSON: json).providerUsage?.record, state, label)
        }

        // Raw identity/checkpoint/terminal-coverage violations stay opaque and survive verbatim.
        var duplicateAcceptedResult = makeRecord()
        var secondTurnWithDuplicateResult = duplicateAcceptedResult.turns[0]
        secondTurnWithDuplicateResult.turnID = UUID()
        duplicateAcceptedResult.turns.append(secondTurnWithDuplicateResult)

        var danglingCheckpoint = makeRecord()
        danglingCheckpoint.claudeSegments[0].acceptedResultID = "res-dangling"

        var missingTerminalIdentity = makeRecord()
        missingTerminalIdentity.claudeSegments[0].acceptedResultID = nil
        missingTerminalIdentity.claudeSegments[0].acceptedResultOrder = 0

        var missingBaseline = makeRecord()
        missingBaseline.claudeSegments[0].baseline = nil

        var missingLatestCumulative = makeRecord()
        missingLatestCumulative.claudeSegments[0].latestCumulative = nil

        var uncoveredTerminalTurn = makeRecord()
        var tokenOnlyTerminalTurn = uncoveredTerminalTurn.turns[0]
        tokenOnlyTerminalTurn.turnID = UUID()
        tokenOnlyTerminalTurn.acceptedResultID = "res-token-only"
        uncoveredTerminalTurn.turns.append(tokenOnlyTerminalTurn)

        var crossSegmentCheckpoint = resetState
        crossSegmentCheckpoint.claudeSegments[1].acceptedResultID = "res-reset-1"

        for (label, invalidRecord) in [
            ("duplicate accepted result identity", duplicateAcceptedResult),
            ("dangling monetary checkpoint", danglingCheckpoint),
            ("complete coverage with no terminal identity", missingTerminalIdentity),
            ("complete coverage with no baseline", missingBaseline),
            ("complete coverage with no latest cumulative amount", missingLatestCumulative),
            ("complete coverage before uncovered terminal turn", uncoveredTerminalTurn),
            ("checkpoint references another segment", crossSegmentCheckpoint)
        ] {
            XCTAssertNotNil(invalidRecord.semanticViolation, label)
            let json = try recordText(invalidRecord)
            let session = try decodeSession(providerUsageJSON: json)
            XCTAssertNil(session.providerUsage?.record, label)
            XCTAssertEqual(session.providerUsage?.rawValue?.text, json, label)
            XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(session)), json, label)
        }

        // The typed invariant surface agrees with the persisted classification.
        XCTAssertNil(makeRecord().semanticViolation)
        var invalid = makeRecord()
        invalid.claudeSegments[0].baseline = 5
        XCTAssertNotNil(invalid.semanticViolation)
        var duplicateSegment = makeRecord()
        duplicateSegment.claudeSegments.append(duplicateSegment.claudeSegments[0])
        XCTAssertNotNil(duplicateSegment.semanticViolation)
        var nan = makeRecord()
        nan.claudeSegments[0].latestCumulative = .nan
        XCTAssertNotNil(nan.semanticViolation)
    }

    func testProviderUsageScannerSplitsOnlyTheTopLevelMember() throws {
        let value = #"{"providerUsage":{"nested":1e999},"n":[1,{"providerUsage":null}]}"#
        let others = [#""id":"\#(sessionID.uuidString)""#, #""name":"Usage Session""#]
        for position in 0 ... others.count {
            var members = others
            members.insert(#""providerUsage":\#(value)"#, at: position)
            let data = Data(("{" + members.joined(separator: ",") + "}").utf8)
            let split = try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: data)
            XCTAssertEqual(split.memberValue.map { String(decoding: $0, as: UTF8.self) }, value, "position \(position)")
            XCTAssertEqual(String(decoding: split.envelope, as: UTF8.self), "{" + others.joined(separator: ",") + "}", "position \(position)")
        }

        // Only member, whitespace formatting, escaped key spelling, and absence.
        let only = try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"{ "providerUsage" : 1e1000 }"#.utf8))
        XCTAssertEqual(only.memberValue, Data("1e1000".utf8))
        XCTAssertEqual(String(decoding: only.envelope, as: UTF8.self), "{  }")
        let escaped = try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"{"providerUsage":[],"x":1}"#.utf8))
        XCTAssertEqual(escaped.memberValue, Data("[]".utf8))
        XCTAssertEqual(String(decoding: escaped.envelope, as: UTF8.self), #"{"x":1}"#)
        let absentSplit = try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"{"x":{"providerUsage":1}}"#.utf8))
        XCTAssertNil(absentSplit.memberValue)
        XCTAssertEqual(String(decoding: absentSplit.envelope, as: UTF8.self), #"{"x":{"providerUsage":1}}"#)

        // Duplicates are ambiguous; malformed envelopes and non-objects are reported, never guessed.
        XCTAssertThrowsError(try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"{"providerUsage":1,"providerUsage":2}"#.utf8)))
        XCTAssertThrowsError(try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"{"a":1}x"#.utf8)))
        XCTAssertThrowsError(try AgentProviderUsageJSONScanner.splitTopLevelMember(named: "providerUsage", in: Data(#"[1]"#.utf8)))
        XCTAssertThrowsError(try AgentProviderUsageRawValue(validating: "1 2"))
        XCTAssertEqual(try AgentProviderUsageRawValue(validating: " [ 1 ] \n").text, "[ 1 ]")

        // Deep nesting is handled iteratively during capture and stays opaque beyond the projection bound.
        let deep = String(repeating: "[", count: 20000) + String(repeating: "]", count: 20000)
        let deepSession = try decodeSession(providerUsageJSON: deep)
        XCTAssertEqual(deepSession.providerUsage?.rawValue?.text, deep)
        XCTAssertNil(deepSession.providerUsage?.record)
    }

    func testProviderUsageDirectCodableIsLimitedToTheLosslessSubset() throws {
        let record = makeRecord()

        // Owned typed records and explicit null round-trip through generic Codable.
        let typedSession = AgentSession(id: sessionID, name: "Typed", autoEditEnabled: true, providerUsage: .record(record))
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(typedSession)).providerUsage, .record(record))
        let nullSession = AgentSession(id: sessionID, name: "Null", autoEditEnabled: true, providerUsage: .opaque(.null))
        let nullEncoded = try JSONEncoder().encode(nullSession)
        XCTAssertTrue(String(decoding: nullEncoded, as: UTF8.self).contains(#""providerUsage":null"#))
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: nullEncoded).providerUsage, .opaque(.null))

        // Raw bytes can never be re-serialized, narrowed, nulled or omitted by a generic Encoder.
        let rawSession = try AgentSession(id: sessionID, name: "Raw", autoEditEnabled: true, providerUsage: .opaque(raw(precisionJSON)))
        XCTAssertThrowsError(try JSONEncoder().encode(rawSession))
        XCTAssertEqual(try providerUsageText(in: AgentSessionDataCodec.encodeSession(rawSession)), precisionJSON)

        // Generic decoding outside the lossless subset fails explicitly instead of claiming preservation;
        // the codec still loads the same payloads.
        let recordJSON = try recordText(record)
        for unsupported in try [
            #"{"schemaVersion":99,"value":1e1000}"#,
            String(recordJSON.dropLast() + #","futureMember":1}"#),
            replacing(recordJSON, #""baseline":0"#, with: #""baseline":5"#),
            #""string""#
        ] {
            let payload = Data(sessionPayload(providerUsageJSON: unsupported).utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self, from: payload), unsupported)
            XCTAssertEqual(try AgentSessionDataCodec.decodeSession(from: payload).providerUsage, try .opaque(raw(unsupported)), unsupported)
        }

        // An unrepresentable owned record fails before any bytes are produced.
        var nan = record
        nan.claudeSegments[0].latestCumulative = .nan
        let nanSession = AgentSession(id: sessionID, name: "NaN", autoEditEnabled: true, providerUsage: .record(nan))
        XCTAssertThrowsError(try AgentSessionDataCodec.encodeSession(nanSession))
        XCTAssertThrowsError(try JSONEncoder().encode(nanSession))
    }

    func testProviderUsageSurvivesLoadRewriteStubRenameAndSave() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let outOfDomain = #"{"schemaVersion":99,"cost":2.1710000000000000000001,"huge":1e1000,"tiny":1e-200,"big":123456789012345678901234567890123456789012345}"#
        let expected = try raw(outOfDomain)

        // Legacy-versioned file with a working item forces the load-time rewrite path.
        var legacy = AgentSession(
            id: sessionID,
            serializationVersion: 6,
            workspaceID: workspace.id,
            name: "Usage Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            items: [AgentChatItemPersist(from: .user("hello", sequenceIndex: 0))],
            autoEditEnabled: true,
            providerUsage: .opaque(expected)
        )
        legacy.lastRunState = AgentSessionRunState.idle.rawValue
        let folder = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        try AgentSessionDataCodec.encodeSession(legacy).write(to: fileURL)
        XCTAssertEqual(try providerUsageText(in: Data(contentsOf: fileURL)), outOfDomain)

        let rawLastRunState = try await service.rawLastRunStateForAgentSession(id: sessionID, for: workspace)
        XCTAssertEqual(rawLastRunState, AgentSessionRunState.idle.rawValue)

        let loaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(loaded.providerUsage, .opaque(expected))
        XCTAssertNil(loaded.providerUsage?.record)
        XCTAssertEqual(try topLevelMemberText("serializationVersion", in: Data(contentsOf: fileURL)), "\(AgentSession.currentSerializationVersion)", "rewrite path ran")
        XCTAssertEqual(try providerUsageText(in: Data(contentsOf: fileURL)), outOfDomain)

        let stub = try await service.loadAgentSessionStub(from: fileURL)
        XCTAssertTrue(stub.isListStub)
        XCTAssertEqual(stub.providerUsage, .opaque(expected))

        try await service.renameAgentSession(id: sessionID, to: "Renamed Usage Session", for: workspace)
        XCTAssertEqual(try topLevelMemberText("name", in: Data(contentsOf: fileURL)), #""Renamed Usage Session""#)
        XCTAssertEqual(try providerUsageText(in: Data(contentsOf: fileURL)), outOfDomain)

        // A supported record persists as its original bytes through the unqualified production path.
        let record = makeRecord()
        let recordJSON = try recordText(record)
        var withRecord = try await service.loadAgentSession(from: fileURL)
        withRecord.providerUsage = try .opaque(raw(recordJSON))
        _ = try await service.saveAgentSession(withRecord, for: workspace, preparation: .alreadyCanonicalTranscript)
        XCTAssertEqual(try providerUsageText(in: Data(contentsOf: fileURL)), recordJSON)
        let reloadedRecord = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(reloadedRecord.providerUsage?.record, record)
        let production = AgentUsageAccumulator(ownerSessionID: sessionID, persisted: reloadedRecord.providerUsage, hasPriorHistory: true, qualification: .productionClaude)
        XCTAssertEqual(production.persistedRepresentation, try .opaque(raw(recordJSON)))

        var resaved = try await service.loadAgentSession(from: fileURL)
        resaved.providerUsage = .opaque(.null)
        _ = try await service.saveAgentSession(resaved, for: workspace, preparation: .alreadyCanonicalTranscript)
        XCTAssertEqual(try providerUsageText(in: Data(contentsOf: fileURL)), "null")

        // Absent stays absent through the same writer.
        var absent = try await service.loadAgentSession(from: fileURL)
        absent.providerUsage = nil
        _ = try await service.saveAgentSession(absent, for: workspace, preparation: .alreadyCanonicalTranscript)
        XCTAssertNil(try providerUsageText(in: Data(contentsOf: fileURL)))
        let absentStub = try await service.loadAgentSessionStub(from: fileURL)
        XCTAssertNil(absentStub.providerUsage)
    }

    func testFailedAtomicWriteRetainsPreviouslyPersistedUsage() async throws {
        try XCTSkipIf(geteuid() == 0, "read-only folder permissions are not enforced for root")
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        let storage = try XCTUnwrap(workspace.customStoragePath)
        let record = makeRecord()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Original",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            autoEditEnabled: true,
            providerUsage: .record(record)
        )
        let fileURL = try await service.saveAgentSession(session, for: workspace, preparation: .alreadyCanonicalTranscript)
        let folder = fileURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: storage)
        }
        let originalBytes = try Data(contentsOf: fileURL)
        let originalProviderUsage = try XCTUnwrap(providerUsageText(in: originalBytes))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        var changed = session
        changed.name = "Changed"
        changed.providerUsage = .opaque(.null)
        do {
            _ = try await service.saveAgentSession(changed, for: workspace, preparation: .alreadyCanonicalTranscript)
            XCTFail("Expected the atomic write to fail in a read-only folder")
        } catch {
            // Expected: the writer surfaces the failure and performs no replacement write.
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        // A preservation failure (unrepresentable owned record) throws before the writer runs.
        var nan = record
        nan.claudeSegments[0].latestCumulative = .nan
        var unrepresentable = session
        unrepresentable.name = "Unrepresentable"
        unrepresentable.providerUsage = .record(nan)
        do {
            _ = try await service.saveAgentSession(unrepresentable, for: workspace, preparation: .alreadyCanonicalTranscript)
            XCTFail("Expected the codec to refuse an unrepresentable providerUsage record")
        } catch {
            // Expected: encode fails before replacement.
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let retained = try await service.loadAgentSession(from: fileURL)
        XCTAssertEqual(retained.name, "Original")
        XCTAssertEqual(retained.providerUsage?.record, record)
        XCTAssertEqual(retained.providerUsage, try .opaque(raw(originalProviderUsage)))
    }

    func testVerifiedResetWithOutstandingTurnPersistsAndReloadsTypedState() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }

        var live = makeQualifiedAccumulator(baseline: .verifiedZero)
        let outstandingTurnID = UUID()
        live.registerTurn(outstandingTurnID, executionID: execution)
        let paidTurnID = UUID()
        live.registerTurn(paidTurnID, executionID: execution)
        XCTAssertEqual(live.observe(result(paidTurnID, id: "res-paid", cost: "1.00")), .accepted)
        XCTAssertEqual(live.noteVerifiedReset(executionID: execution), .accepted)
        XCTAssertEqual(live.persistedRepresentation?.record?.claudeSegments[0].coverage, .partial)
        XCTAssertEqual(
            live.observe(result(
                outstandingTurnID,
                id: "res-crossed",
                input: 10,
                output: 2,
                read: 90,
                creation: 0,
                cost: "9.00"
            )),
            .acceptedWithMonetaryRejection(.crossedResetBoundary)
        )
        live.endExecution(execution, outcome: .completed)

        let persisted = try XCTUnwrap(live.persistedRepresentation)
        let record = try XCTUnwrap(persisted.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertEqual(record.claudeSegments[0].latestCumulative, Decimal(string: "1.00"))
        XCTAssertEqual(record.claudeSegments[0].acceptedResultID, "res-paid")
        XCTAssertEqual(record.claudeSegments[0].coverage, .partial)
        XCTAssertNil(record.claudeSegments[1].latestCumulative, "crossed money must not charge the reset segment")
        XCTAssertNil(record.claudeSegments[1].acceptedResultID)
        XCTAssertEqual(record.claudeSegments[1].state, .closed)
        XCTAssertEqual(record.claudeSegments[1].coverage, .complete, "the reset segment dispatched no work")
        let crossedTurn = try XCTUnwrap(record.turns.first(where: { $0.turnID == outstandingTurnID }))
        XCTAssertEqual(crossedTurn.segmentIndex, 0)
        XCTAssertEqual(crossedTurn.acceptedResultID, "res-crossed")
        XCTAssertEqual(crossedTurn.inputTokens, 10)
        XCTAssertEqual(crossedTurn.outputTokens, 2)
        XCTAssertEqual(crossedTurn.cacheReadInputTokens, 90)
        XCTAssertEqual(crossedTurn.cacheCreationInputTokens, 0)
        XCTAssertEqual(crossedTurn.diagnostic, "monetary checkpoint rejected: crossedResetBoundary")
        XCTAssertEqual(live.sessionCostEstimate, .init(amount: Decimal(string: "1.00") ?? .nan, currency: "USD", coverage: .partial))

        let session = AgentSession(
            id: owner,
            workspaceID: workspace.id,
            name: "Reset Boundary",
            autoEditEnabled: true,
            providerUsage: persisted
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript
        )
        XCTAssertNotNil(try providerUsageText(in: Data(contentsOf: fileURL)))

        let loaded = try await service.loadAgentSession(from: fileURL)
        XCTAssertNotNil(loaded.providerUsage?.rawValue, "reload keeps authoritative raw bytes")
        XCTAssertEqual(loaded.providerUsage?.record, record, "the producer state remains a valid typed projection")

        let restored = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: loaded.providerUsage,
            hasPriorHistory: false,
            qualification: .qualified(contractID: "test.claude.cumulative.v1")
        )
        XCTAssertEqual(restored.eligibility, .eligible)
        let restoredRecord = try XCTUnwrap(restored.persistedRepresentation?.record)
        XCTAssertEqual(restoredRecord, record)
        XCTAssertEqual(restoredRecord.claudeSegments[0].coverage, .partial)
        XCTAssertEqual(restored.sessionCostEstimate, .init(amount: Decimal(string: "1.00") ?? .nan, currency: "USD", coverage: .partial))
        XCTAssertNil(restoredRecord.claudeSegments[1].latestCumulative)
        XCTAssertNil(restoredRecord.claudeSegments[1].acceptedResultID)
        let restoredCrossedTurn = try XCTUnwrap(restoredRecord.turns.first(where: { $0.turnID == outstandingTurnID }))
        XCTAssertEqual(restoredCrossedTurn.segmentIndex, 0)
        XCTAssertEqual(restoredCrossedTurn.acceptedResultID, "res-crossed")
        XCTAssertEqual(restoredCrossedTurn.inputTokens, 10)
        XCTAssertEqual(restoredCrossedTurn.outputTokens, 2)
        XCTAssertEqual(restoredCrossedTurn.cacheReadInputTokens, 90)
        XCTAssertEqual(restoredCrossedTurn.cacheCreationInputTokens, 0)
    }

    func testAccumulatorHydrationKeepsIdentitiesRejectsForeignOriginAndRefusesLateOverwrite() throws {
        let qualification = AgentUsageQualification.qualified(contractID: "test.claude.cumulative.v1")
        var live = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: qualification)
        live.beginExecution(executionID: execution, providerSessionID: "ps-1", baseline: .verifiedZero, at: Date(timeIntervalSince1970: 1_700_000_000))
        let completed = UUID()
        let interrupted = UUID()
        live.registerTurn(completed, executionID: execution)
        XCTAssertEqual(live.observe(result(completed, id: "res-1", cost: "1.00")), .accepted)
        live.registerTurn(interrupted, executionID: execution)
        XCTAssertEqual(live.observe(request(interrupted, requestID: "r-open", input: 40, read: 60, creation: 0)), .accepted)
        live.endExecution(execution)

        // Persist through the session envelope and restore before any live ingestion.
        let persisted = try XCTUnwrap(live.persistedRepresentation)
        let session = AgentSession(id: owner, name: "Owner", autoEditEnabled: true, providerUsage: persisted)
        let reloaded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(reloaded.providerUsage, persisted)
        var restored = AgentUsageAccumulator(ownerSessionID: owner, persisted: reloaded.providerUsage, hasPriorHistory: true, qualification: qualification)
        XCTAssertEqual(restored.eligibility, .eligible)
        XCTAssertEqual(restored.persistedRepresentation, persisted)
        let turns = try XCTUnwrap(restored.persistedRepresentation?.record?.turns)
        XCTAssertEqual(turns.map(\.turnID), [completed, interrupted])
        XCTAssertEqual(turns.first?.acceptedResultID, "res-1")
        XCTAssertEqual(turns.last?.outcome, .interrupted)
        XCTAssertEqual(turns.last?.coverage, .partial)
        XCTAssertEqual(turns.last?.inputTokens, 40)
        XCTAssertEqual(restored.persistedRepresentation?.record?.claudeSegments.first?.state, .closed)
        XCTAssertEqual(restored.sessionCostEstimate?.amount, Decimal(string: "1.00"))

        // Same-session resume: a fresh execution keeps owned segments and the accepted result identities.
        let resumedExecution = UUID()
        restored.beginExecution(executionID: resumedExecution, providerSessionID: "ps-1", baseline: .unknown, at: Date(timeIntervalSince1970: 1_700_000_100))
        let resumedTurn = UUID()
        restored.registerTurn(resumedTurn, executionID: resumedExecution)
        var replayedResult = result(resumedTurn, id: "res-1", cost: "1.00")
        replayedResult.executionID = resumedExecution
        XCTAssertEqual(restored.observe(replayedResult), .rejected(.duplicateResult))
        XCTAssertEqual(restored.persistedRepresentation?.record?.claudeSegments.count, 2)
        XCTAssertEqual(restored.sessionCostEstimate, .init(amount: Decimal(string: "1.00") ?? .nan, currency: "USD", coverage: .partial))

        // Late hydration cannot overwrite newer owner state.
        XCTAssertFalse(restored.applyHydration(nil, hasPriorHistory: false))
        XCTAssertEqual(restored.persistedRepresentation?.record?.claudeSegments.count, 2)
        var untouched = AgentUsageAccumulator(ownerSessionID: owner, persisted: nil, hasPriorHistory: false, qualification: qualification)
        XCTAssertTrue(untouched.applyHydration(persisted, hasPriorHistory: true))
        XCTAssertEqual(untouched.persistedRepresentation, persisted)

        // Foreign origin (branch/copy) is preserved verbatim but never charged to the destination.
        var foreign = AgentUsageAccumulator(ownerSessionID: sessionID, persisted: persisted, hasPriorHistory: true, qualification: qualification)
        XCTAssertEqual(foreign.eligibility, .foreignOrigin(owner))
        foreign.beginExecution(executionID: execution, providerSessionID: nil, baseline: .verifiedZero, at: Date())
        let foreignTurn = UUID()
        XCTAssertEqual(foreign.registerTurn(foreignTurn, executionID: execution), .rejected(.ineligibleOwner))
        XCTAssertEqual(foreign.observe(result(foreignTurn, id: "res-9", cost: "9.00")), .rejected(.ineligibleOwner))
        XCTAssertEqual(foreign.persistedRepresentation, persisted)
        XCTAssertNil(foreign.sessionCostEstimate)

        // Opaque persisted values are equally ineligible and returned unchanged.
        let opaqueValue = try raw(#""v2""#)
        let opaque = AgentUsageAccumulator(ownerSessionID: owner, persisted: .opaque(opaqueValue), hasPriorHistory: true, qualification: qualification)
        XCTAssertEqual(opaque.eligibility, .opaquePersistedValue)
        XCTAssertEqual(opaque.persistedRepresentation, .opaque(opaqueValue))
    }

    // MARK: - Helpers

    /// Header-shaped probe standing in for the data service's private lightweight header.
    private struct AgentSessionStubProbe: Decodable {
        let id: UUID
        let name: String
    }

    private func makeRecord() -> AgentProviderUsageRecord {
        AgentProviderUsageRecord(
            originSessionID: owner,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            hasUnmeasuredHistory: true,
            turns: [
                .init(
                    executionID: execution,
                    segmentIndex: 0,
                    turnID: recordTurnID,
                    acceptedResultID: "res-1",
                    inputTokens: 10,
                    outputTokens: 2,
                    cacheReadInputTokens: 90,
                    cacheCreationInputTokens: 0,
                    observedRequestCount: 1,
                    outcome: .completed,
                    coverage: .complete,
                    diagnostic: nil
                )
            ],
            claudeSegments: [
                .init(
                    contractID: "test.claude.cumulative.v1",
                    provider: "claude",
                    providerSessionID: "ps-1",
                    executionID: execution,
                    resetGeneration: 0,
                    baseline: 0,
                    latestCumulative: Decimal(string: "2.171"),
                    currency: "USD",
                    acceptedResultID: "res-1",
                    acceptedResultOrder: 1,
                    state: .closed,
                    coverage: .complete
                )
            ]
        )
    }

    private func recordText(_ record: AgentProviderUsageRecord) throws -> String {
        try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
    }

    private func raw(_ text: String) throws -> AgentProviderUsageRawValue {
        try AgentProviderUsageRawValue(validating: text)
    }

    private func replacing(_ text: String, _ search: String, with replacement: String) throws -> String {
        let range = try XCTUnwrap(text.range(of: search), "fixture must contain \(search)")
        return text.replacingCharacters(in: range, with: replacement)
    }

    /// Exact bytes of a top-level member of a JSON object, as text; `nil` when absent.
    private func topLevelMemberText(_ name: String, in data: Data) throws -> String? {
        try AgentProviderUsageJSONScanner.splitTopLevelMember(named: name, in: data).memberValue
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func providerUsageText(in data: Data) throws -> String? {
        try topLevelMemberText(AgentSessionDataCodec.providerUsageMemberName, in: data)
    }

    private func memberText(_ objectJSON: String, _ name: String) throws -> String {
        try XCTUnwrap(topLevelMemberText(name, in: Data(objectJSON.utf8)))
    }

    private func envelope(members: [String]) -> String {
        let base = [
            #""id": "\#(sessionID.uuidString)""#,
            #""serializationVersion": 7"#,
            #""name": "Usage Session""#,
            #""savedAt": 0"#,
            #""items": []"#,
            #""autoEditEnabled": true"#
        ]
        return "{\n" + (base + members).joined(separator: ",\n") + "\n}"
    }

    private func sessionPayload(providerUsageJSON: String?) -> String {
        envelope(members: providerUsageJSON.map { [#""providerUsage": \#($0)"#] } ?? [])
    }

    private func decodeSession(providerUsageJSON: String?) throws -> AgentSession {
        try AgentSessionDataCodec.decodeSession(from: Data(sessionPayload(providerUsageJSON: providerUsageJSON).utf8))
    }

    private func encodedString(_ session: AgentSession) throws -> String {
        try String(decoding: AgentSessionDataCodec.encodeSession(session), as: UTF8.self)
    }

    private func request(
        _ turnID: UUID,
        requestID: String,
        input: Int,
        read: Int,
        creation: Int
    ) -> AgentUsageObservationInput {
        .init(
            observation: .init(
                source: .messageStart,
                inputTokens: input,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: creation,
                requestID: requestID
            ),
            executionID: execution,
            turnID: turnID,
            attribution: .live
        )
    }

    private func result(
        _ turnID: UUID,
        id: String,
        input: Int? = nil,
        output: Int? = nil,
        read: Int? = nil,
        creation: Int? = nil,
        cost: String? = nil
    ) -> AgentUsageObservationInput {
        .init(
            observation: .init(
                source: .result,
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: creation,
                envelopeID: id,
                resultSubtype: "success",
                resultIsError: false
            ),
            reportedCost: cost.flatMap { Decimal(string: $0) },
            executionID: execution,
            turnID: turnID,
            attribution: .live,
            hasOriginalResultAuthority: true
        )
    }

    private func makeQualifiedAccumulator(baseline: AgentUsageSegmentBaseline) -> AgentUsageAccumulator {
        var accumulator = AgentUsageAccumulator(
            ownerSessionID: owner,
            persisted: nil,
            hasPriorHistory: false,
            qualification: .qualified(contractID: "test.claude.cumulative.v1")
        )
        accumulator.beginExecution(
            executionID: execution,
            providerSessionID: "ps-1",
            baseline: baseline,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return accumulator
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentUsagePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Agent Usage Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
