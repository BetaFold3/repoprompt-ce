@testable import RepoPromptAgentCore
import XCTest

/// Differential proof that the production `AgentProviderUsageJSONScanner` behaves exactly like the
/// frozen pre-D6 reference (`LegacyAgentProviderUsageJSONScannerReference`).
///
/// Every input is run through both implementations and the full outcome is compared: success bytes
/// and their `Data` start indices (split envelope, member value, validated value), or the error
/// (scan kind and offset; for escaped-key `JSONDecoder` failures the error case, coding path,
/// debug description and underlying error domain/code). Lossless-projection shapes are compared too.
final class AgentProviderUsageJSONScannerDifferentialTests: XCTestCase {
    private typealias Production = AgentProviderUsageJSONScanner
    private typealias Legacy = LegacyAgentProviderUsageJSONScannerReference

    private static let member = "providerUsage"
    private static let fuzzBaseSeed: UInt64 = 0xD6C0_1D5C_A11E_0001
    private static let mutationsPerBase = 10000

    // MARK: - Corpus

    func testEncodedSessionCorpusMatchesReference() throws {
        let variants = try Self.providerUsageVariants()
        var count = 0
        for (variantIndex, usage) in variants.enumerated() {
            for (encoderLabel, encoder) in Self.encoders {
                let data = try AgentSessionDataCodec.encodeSession(Self.makeSession(providerUsage: usage), using: encoder)
                let label = "corpus variant #\(variantIndex) encoder=\(encoderLabel)"
                assertSameOutcomes(data, label: label, includeDocumentShape: true)
                assertSameOutcomes(Self.offsetSlice(data), label: label + " [offset slice]", includeDocumentShape: false)
                count += 1
            }
        }
        XCTAssertEqual(count, variants.count * Self.encoders.count)
        // The lossless-projection comparison must have seen a real typed record on both sides.
        XCTAssertGreaterThan(nonNilLosslessRecordComparisons, 0)
    }

    func testV1RecordFixturesProjectAsExpectedThroughBothScanners() throws {
        let valid = try Self.validRecordMember()
        let validRecord = AgentProviderUsageRawValue(unchecked: valid).losslessRecord()
        XCTAssertNotNil(validRecord, "JSONEncoder output of a valid v1 record must project losslessly")
        XCTAssertEqual(validRecord, AgentProviderUsageRecord.legacyProjection(of: valid))

        let exotic = try Self.exoticRecordMember()
        XCTAssertNil(AgentProviderUsageRawValue(unchecked: exotic).losslessRecord(), "beyond-Decimal lexeme must stay opaque")
        XCTAssertNil(AgentProviderUsageRecord.legacyProjection(of: exotic))
    }

    // MARK: - Hand-written cases

    func testHandWrittenCasesMatchReference() {
        let cases = Self.handWrittenCases
        XCTAssertGreaterThan(cases.count, 100)
        var histogram: [String: Int] = [:]
        for (index, bytes) in cases.enumerated() {
            let data = Data(bytes)
            let label = "hand case #\(index) (\(bytes.count) bytes)"
            let outcome = assertSameOutcomes(data, label: label, includeDocumentShape: true, shapeDepths: [0, 1, 2, 64])
            histogram[Self.category(outcome), default: 0] += 1
            assertSameOutcomes(Self.offsetSlice(data), label: label + " [offset slice]", includeDocumentShape: true)
        }
        // Every outcome family is exercised, including the escaped-key `JSONDecoder` failure path.
        let expectedCategories = [
            "split",
            "split+member",
            "decodingError",
            "scanError.duplicateTopLevelMember",
            "scanError.notAnObject",
            "scanError.trailingContent",
            "scanError.invalidLiteral",
            "scanError.invalidNumber",
            "scanError.invalidString",
            "scanError.unexpectedByte",
            "scanError.unexpectedEnd"
        ]
        for category in expectedCategories {
            XCTAssertGreaterThan(histogram[category, default: 0], 0, category)
        }
    }

    func testDeepNestingMatchesReference() {
        let depth = 100_000
        let open = [UInt8](repeating: 0x5B, count: depth)
        let close = [UInt8](repeating: 0x5D, count: depth)
        let prefix = Array(#"{"providerUsage":"#.utf8)
        let objectOpen = [UInt8](String(repeating: #"{"a":"#, count: depth).utf8)
        let objectClose = [UInt8](repeating: 0x7D, count: depth)
        let inputs: [(String, [UInt8])] = [
            ("balanced arrays", prefix + open + close + [0x7D]),
            ("arrays missing one close", prefix + open + close.dropLast() + [0x7D]),
            ("arrays with one extra close", prefix + open + close + [0x5D, 0x7D]),
            ("arrays mismatched innermost", prefix + open.dropLast() + [0x7B] + close + [0x7D]),
            ("balanced objects", prefix + objectOpen + [0x31] + objectClose + [0x7D]),
            ("objects truncated", prefix + objectOpen + [0x31] + objectClose.dropLast(2)),
            ("bare nested arrays", open + close),
            ("member after deep value", prefix + open + close + Array(#","x":1}"#.utf8))
        ]
        for (label, bytes) in inputs {
            assertSameOutcomes(Data(bytes), label: "deep: \(label)", includeDocumentShape: true, shapeDepths: [64, 200])
        }
    }

    func testNonZeroStartIndexSlicesMatchReference() throws {
        let document = try AgentSessionDataCodec.encodeSession(
            Self.makeSession(providerUsage: Data(#"{"schemaVersion":99,"n":[1,2.5e-3]}"#.utf8)),
            using: Self.sortedEncoder
        )
        let padded = Data([0x7B, 0x22, 0x5C, 0xEF, 0xBB, 0xBF] + [UInt8](document) + [0x20, 0x7D])
        for start in 0 ... 6 {
            for end in [padded.count - 2, padded.count - 1, padded.count] {
                let slice = padded[start ..< end]
                XCTAssertEqual(slice.startIndex, start)
                assertSameOutcomes(slice, label: "slice \(start)..<\(end)", includeDocumentShape: false)
            }
        }
        // A slice of a large backing store, with BOM inside the slice.
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"providerUsage":[1],"a":2}"#.utf8)
        let backing = Data(repeating: 0x20, count: 4096) + bom + Data(repeating: 0x20, count: 17)
        assertSameOutcomes(backing[4096...], label: "BOM slice at 4096", includeDocumentShape: true)
        assertSameOutcomes(backing[4096 ..< 4096], label: "empty slice at 4096", includeDocumentShape: true)
    }

    // MARK: - Truncations

    func testEveryTruncationOfAMidSizeDocumentMatchesReference() throws {
        let document = try Self.midSizeDocument()
        XCTAssertTrue((2048 ... 4096).contains(document.count), "truncation base is \(document.count) bytes")
        let padding = Data([0x5B, 0x22])
        let padded = padding + document
        for length in 0 ... document.count {
            assertSameOutcomes(Data(document.prefix(length)), label: "truncation \(length)", includeDocumentShape: false)
            let slice = padded[padding.count ..< (padding.count + length)]
            assertSameOutcomes(slice, label: "truncation \(length) [offset slice]", includeDocumentShape: false)
        }
    }

    // MARK: - Mutation fuzz

    func testSeededMutationFuzzMatchesReference() throws {
        let bases: [(String, Data)] = try [
            ("compact", AgentSessionDataCodec.encodeSession(Self.fuzzSession(), using: Self.sortedEncoder)),
            ("pretty", AgentSessionDataCodec.encodeSession(Self.fuzzSession(), using: Self.prettyEncoder))
        ]
        let alphabet: [UInt8] = Array(#""\{}[],:"#.utf8) + [0x00, 0x1F, 0x20, 0x09, 0x75, 0x30, 0x2D, 0x65, 0xEF]
        memberShapeCache = []
        defer { memberShapeCache = nil }
        var executed = 0
        var histogram: [String: Int] = [:]
        let failuresAtStart = testRun?.failureCount ?? 0
        for (baseIndex, (baseLabel, base)) in bases.enumerated() {
            let baseBytes = [UInt8](base)
            for iteration in 0 ..< Self.mutationsPerBase {
                let seed = Self.fuzzBaseSeed &+ UInt64(baseIndex) << 32 &+ UInt64(iteration)
                var random = SplitMix64(seed: seed)
                var bytes = baseBytes
                let editCount = 1 + Int(random.next() % 3)
                for _ in 0 ..< editCount {
                    let byte = alphabet[Int(random.next() % UInt64(alphabet.count))]
                    let position = Int(random.next() % UInt64(bytes.count + 1))
                    switch random.next() % 3 {
                    case 0 where position < bytes.count:
                        bytes[position] = byte
                    case 1, 0:
                        bytes.insert(byte, at: position)
                    default:
                        if position < bytes.count { bytes.remove(at: position) }
                    }
                }
                let data = Data(bytes)
                let label = "fuzz base=\(baseLabel) iteration=\(iteration) seed=0x\(String(seed, radix: 16))"
                let outcome = assertSameOutcomes(data, label: label, includeDocumentShape: false)
                histogram[Self.category(outcome), default: 0] += 1
                executed += 1
                if (testRun?.failureCount ?? 0) > failuresAtStart + 20 {
                    XCTFail("stopping fuzz after repeated failures; last \(label)")
                    return
                }
            }
        }
        XCTAssertEqual(executed, bases.count * Self.mutationsPerBase)
        let distribution = histogram.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("D6 fuzz split outcomes (\(executed) mutations, \(memberShapeCache?.count ?? 0) distinct member values): \(distribution)")
        // The fuzz must exercise both accepted documents and a spread of rejection paths.
        XCTAssertGreaterThan(histogram["split+member", default: 0], executed / 20)
        for kind in ["unexpectedByte", "invalidString", "invalidNumber", "unexpectedEnd"] {
            XCTAssertGreaterThan(histogram["scanError.\(kind)", default: 0], 0, kind)
        }
    }

    private static func category(_ outcome: Outcome) -> String {
        switch outcome {
        case let .split(_, _, member, _): member == nil ? "split" : "split+member"
        case .value: "value"
        case let .scanError(error): "scanError.\(error.kind)"
        case .decodingError: "decodingError"
        case .otherError: "otherError"
        }
    }

    // MARK: - Large document

    func testLargeSyntheticDocumentMatchesReference() throws {
        let document = try Self.largeDocument()
        XCTAssertGreaterThan(document.count, 1_400_000)
        assertSameOutcomes(document, label: "large (member last)", includeDocumentShape: false)

        // Member first: re-host the member at the head of the object.
        let split = try Production.splitTopLevelMember(named: Self.member, in: document)
        let memberValue = try XCTUnwrap(split.memberValue)
        var first = Data(#"{"providerUsage":"#.utf8)
        first.append(memberValue)
        first.append(0x2C)
        first.append(split.envelope.dropFirst())
        assertSameOutcomes(first, label: "large (member first)", includeDocumentShape: false)
        assertSameOutcomes(Self.offsetSlice(first), label: "large (member first) [offset slice]", includeDocumentShape: false)
    }

    // MARK: - Outcome comparison

    private enum Outcome: Equatable {
        case split(envelope: [UInt8], envelopeStart: Int, member: [UInt8]?, memberStart: Int?)
        case value([UInt8], start: Int)
        case scanError(AgentProviderUsageJSONScanner.ScanError)
        case decodingError(String)
        case otherError(String)
    }

    /// When non-nil, member values already compared are skipped (fuzz iterations share members).
    private var memberShapeCache: Set<Data>?
    /// Member comparisons where both scanners projected a non-nil typed record.
    private var nonNilLosslessRecordComparisons = 0

    @discardableResult
    private func assertSameOutcomes(
        _ data: Data,
        label: @autoclosure () -> String,
        includeDocumentShape: Bool,
        shapeDepths: [Int] = [64],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Outcome {
        let productionSplit = Self.outcome { try Self.splitOutcome(Production.splitTopLevelMember(named: Self.member, in: data)) }
        let legacySplit = Self.outcome { try Self.splitOutcome(Legacy.splitTopLevelMember(named: Self.member, in: data)) }
        guard productionSplit == legacySplit else {
            XCTFail("split differs for \(label()): production=\(Self.summary(productionSplit)) legacy=\(Self.summary(legacySplit))", file: file, line: line)
            return productionSplit
        }

        let productionValue = Self.outcome { try Self.valueOutcome(Production.validatedValue(in: data)) }
        let legacyValue = Self.outcome { try Self.valueOutcome(Legacy.validatedValue(in: data)) }
        guard productionValue == legacyValue else {
            XCTFail("validatedValue differs for \(label()): production=\(Self.summary(productionValue)) legacy=\(Self.summary(legacyValue))", file: file, line: line)
            return productionSplit
        }

        if includeDocumentShape {
            for depth in shapeDepths where Production.shape(of: data, maxDepth: depth) != Legacy.shape(of: data, maxDepth: depth) {
                XCTFail("document shape (maxDepth \(depth)) differs for \(label())", file: file, line: line)
                return productionSplit
            }
        }

        guard case let .split(_, _, memberBytes?, _) = productionSplit else { return productionSplit }
        let memberValue = Data(memberBytes)
        if memberShapeCache?.insert(memberValue).inserted == false { return productionSplit }
        let productionMember = Self.outcome { try Self.valueOutcome(Production.validatedValue(in: memberValue)) }
        let legacyMember = Self.outcome { try Self.valueOutcome(Legacy.validatedValue(in: memberValue)) }
        XCTAssertEqual(productionMember, legacyMember, "member validatedValue differs for \(label())", file: file, line: line)
        for depth in shapeDepths {
            let productionShape = Production.shape(of: memberValue, maxDepth: depth)
            let legacyShape = Legacy.shape(of: memberValue, maxDepth: depth)
            XCTAssertTrue(productionShape == legacyShape, "member shape (maxDepth \(depth)) differs for \(label())", file: file, line: line)
        }
        let productionRecord = AgentProviderUsageRawValue(unchecked: memberValue).losslessRecord()
        let legacyRecord = AgentProviderUsageRecord.legacyProjection(of: memberValue)
        XCTAssertEqual(productionRecord, legacyRecord, "losslessRecord differs for \(label())", file: file, line: line)
        if productionRecord != nil, legacyRecord != nil { nonNilLosslessRecordComparisons += 1 }
        return productionSplit
    }

    private static func outcome(_ body: () throws -> Outcome) -> Outcome {
        do {
            return try body()
        } catch let error as AgentProviderUsageJSONScanner.ScanError {
            return .scanError(error)
        } catch let error as DecodingError {
            return .decodingError(structuredDescription(of: error))
        } catch {
            let nsError = error as NSError
            return .otherError("\(type(of: error))|\(nsError.domain)|\(nsError.code)")
        }
    }

    private static func splitOutcome(_ split: AgentProviderUsageJSONScanner.TopLevelSplit) -> Outcome {
        .split(
            envelope: [UInt8](split.envelope),
            envelopeStart: split.envelope.startIndex,
            member: split.memberValue.map { [UInt8]($0) },
            memberStart: split.memberValue?.startIndex
        )
    }

    private static func valueOutcome(_ value: Data) -> Outcome {
        .value([UInt8](value), start: value.startIndex)
    }

    /// Error case, coding path, debug description and underlying error identity; never localized text.
    private static func structuredDescription(of error: DecodingError) -> String {
        func context(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            let underlying = (context.underlyingError as NSError?).map { "\($0.domain)#\($0.code)" } ?? "-"
            return "path=\(path)|debug=\(context.debugDescription)|underlying=\(underlying)"
        }
        switch error {
        case let .dataCorrupted(ctx):
            return "dataCorrupted|" + context(ctx)
        case let .keyNotFound(key, ctx):
            return "keyNotFound(\(key.stringValue))|" + context(ctx)
        case let .typeMismatch(type, ctx):
            return "typeMismatch(\(type))|" + context(ctx)
        case let .valueNotFound(type, ctx):
            return "valueNotFound(\(type))|" + context(ctx)
        @unknown default:
            return "unknown|\(error)"
        }
    }

    /// Length/offset summary only, so failures never echo document bytes.
    private static func summary(_ outcome: Outcome) -> String {
        switch outcome {
        case let .split(envelope, envelopeStart, member, memberStart):
            "split(envelope \(envelope.count)B @\(envelopeStart), member \(member.map { "\($0.count)B" } ?? "nil") @\(memberStart.map(String.init) ?? "-"))"
        case let .value(bytes, start):
            "value(\(bytes.count)B @\(start))"
        case let .scanError(error):
            "scanError(\(error.kind) @\(error.offset))"
        case let .decodingError(text):
            "decodingError(\(text))"
        case let .otherError(text):
            "otherError(\(text))"
        }
    }

    // MARK: - Fixtures

    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let encoders: [(String, JSONEncoder)] = [
        ("default", JSONEncoder()),
        ("sorted", sortedEncoder),
        ("pretty", prettyEncoder)
    ]

    private static func providerUsageVariants() throws -> [Data?] {
        try staticProviderUsageVariants + [validRecordMember(), exoticRecordMember()]
    }

    private static let staticProviderUsageVariants: [Data?] = [
        nil,
        Data("null".utf8),
        Data(#"{"schemaVersion":99,"turns":[],"nested":{"providerUsage":{"x":[1,{"y":null}]}}}"#.utf8),
        Data(#"[1,"two",null,true,false,{"k":0.10},[]]"#.utf8),
        Data(#"{"a":1e1000,"b":-0,"c":-0.0e-0,"d":123456789012345678901234567890.000000000000000000001E+99999999999999999999,"e":0.1E+5,"f":1E-7}"#.utf8),
        Data(#"-1.5e+308"#.utf8),
        Data(#""string \"with\" escapes \\ \/ \b\f\n\r\t \u00e9 \uD83D\uDE00""#.utf8),
        Data(#"{"dup":1,"dup":2,"\u0064up":3}"#.utf8),
        Data(#"{ "spaced" : [ 1 , 2 ] , "x" : { } }"#.utf8)
    ]

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// `JSONEncoder` output of a semantically valid v1 record: projects losslessly.
    private static func validRecordMember() throws -> Data {
        try JSONEncoder().encode(makeRecord())
    }

    /// The valid record with `latestCumulative` rewritten to a 41-significant-digit lexeme that
    /// `Decimal` cannot hold, so the re-encoded projection differs and the value must stay opaque.
    private static func exoticRecordMember() throws -> Data {
        let text = try String(decoding: validRecordMember(), as: UTF8.self)
        let key = #""latestCumulative":"#
        guard let keyRange = text.range(of: key),
              let valueEnd = text[keyRange.upperBound...].firstIndex(where: { $0 == "," || $0 == "}" })
        else {
            throw CocoaError(.coderInvalidValue)
        }
        let exotic = text.replacingCharacters(
            in: keyRange.upperBound ..< valueEnd,
            with: "2.1710000000000000000000000000000000000001"
        )
        return Data(exotic.utf8)
    }

    private static func makeRecord() -> AgentProviderUsageRecord {
        let execution = UUID(uuidString: "00000000-0000-0000-0000-00000000E0E0")!
        return AgentProviderUsageRecord(
            originSessionID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            hasUnmeasuredHistory: true,
            turns: [
                .init(
                    executionID: execution,
                    segmentIndex: 0,
                    turnID: UUID(uuidString: "00000000-0000-0000-0000-00000000A0A0")!,
                    acceptedResultID: "res-1",
                    inputTokens: 10,
                    outputTokens: 2,
                    cacheReadInputTokens: 90,
                    cacheCreationInputTokens: 0,
                    observedRequestCount: 1,
                    outcome: .completed,
                    coverage: .complete,
                    diagnostic: "escaped \"diagnostic\" \\ é"
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

    private static func makeSession(providerUsage: Data?, payloads: [String: String] = defaultPayloads) -> AgentSession {
        AgentSession(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D6"),
            name: "Scanner \"differential\" \\ session / é 😀",
            savedAt: fixedDate,
            uiToolResultPayloadsByItemID: payloads,
            agentKind: "claudeCode",
            agentModel: "opus",
            providerSessionID: "ps-1",
            providerUsage: providerUsage.map { .opaque(AgentProviderUsageRawValue(unchecked: $0)) },
            codexContextWindow: 200_000,
            pendingHandoffPayload: "line1\nline2\t\u{01}\u{1F}"
        )
    }

    private static let defaultPayloads: [String: String] = [
        "item-1": #"{"providerUsage":"decoy","quote":"\"","slash":"\\"}"#,
        "item-2": "control \u{00}\u{07}\u{1F} and unicode \u{2028}\u{FEFF}",
        "item-3": "plain"
    ]

    private static func fuzzSession() -> AgentSession {
        makeSession(
            providerUsage: Data(#"{"schemaVersion":99,"n":[1,-0,2.5e-3,"a\"b\\\u00e9"],"o":{"k":true,"z":null}}"#.utf8),
            payloads: ["a": #"x"y\z"#, "b": "tab\tnl\n"]
        )
    }

    private static func midSizeDocument() throws -> Data {
        var payloads = defaultPayloads
        var index = 0
        var document = Data()
        repeat {
            payloads["filler-\(index)"] = "payload \(index) \"q\" \\ / \u{01} é 😀 " + String(repeating: "x", count: index % 40)
            index += 1
            document = try AgentSessionDataCodec.encodeSession(
                makeSession(providerUsage: Data(#"{"schemaVersion":99,"turns":[{"n":1e5,"s":"\u0041"}],"x":[true,false,null]}"#.utf8), payloads: payloads),
                using: sortedEncoder
            )
        } while document.count < 3000
        return document
    }

    private static func largeDocument() throws -> Data {
        var payloads: [String: String] = [:]
        let chunk = String(repeating: "Lorem ipsum \"quoted\" \\ back / slash é 😀 \u{01} tab\t newline\n ", count: 18)
        for index in 0 ..< 1200 {
            payloads[String(format: "item-%05d", index)] = "\(index): " + chunk
        }
        return try AgentSessionDataCodec.encodeSession(
            makeSession(providerUsage: Data(#"{"schemaVersion":99,"big":[1e999,-0,"x"],"nested":{"providerUsage":null}}"#.utf8), payloads: payloads),
            using: sortedEncoder
        )
    }

    /// The same bytes as a `Data` slice whose `startIndex` is not zero.
    private static func offsetSlice(_ data: Data) -> Data {
        let padded = Data([0x7B, 0x22, 0xEF]) + data
        return padded[3...]
    }

    private static var handWrittenCases: [[UInt8]] {
        let texts: [String] = [
            // Target position.
            #"{"providerUsage":1}"#,
            #"{"providerUsage":{"a":[1,2]},"b":2,"c":3}"#,
            #"{"a":1,"providerUsage":[true],"c":3}"#,
            #"{"a":1,"b":2,"providerUsage":"last"}"#,
            #"{}"#,
            #"{ }"#,
            #"{"a":1}"#,
            // Whitespace around every token.
            " \t\r\n{ \t\r\n\"a\" \t\r\n: \t\r\n1 \t\r\n, \t\r\n\"providerUsage\" \t\r\n: \t\r\n[ \t\r\n1 \t\r\n, \t\r\n{ \t\r\n} \t\r\n] \t\r\n} \t\r\n",
            "{\n  \"providerUsage\" : null\n}\n",
            "{\"providerUsage\":null\n,\n\"x\":1}",
            "{\"x\":1\n,\n\"providerUsage\":null}",
            // Non-object top-level values.
            "[1]", "1", "-0", "\"providerUsage\"", "null", "true", "false", "[]", "   ", "",
            "\u{FEFF}{\"providerUsage\":1}",
            // Duplicate and alias keys.
            #"{"providerUsage":1,"providerUsage":2}"#,
            #"{"providerUsage":1,"a":2,"providerUsage":3}"#,
            #"{"\u0070roviderUsage":1,"x":2}"#,
            #"{"providerUsage":1,"\u0070roviderUsage":2}"#,
            #"{"provider\u0055sage":{"k":1}}"#,
            #"{"providerUsag\u0065":1}"#,
            #"{"providerUsage\u0000":1}"#,
            #"{"providerUsageX":1,"providerUsag":2}"#,
            #"{"x":{"providerUsage":1},"providerUsage":2}"#,
            #"{"x":{"providerUsage":1}}"#,
            #"{"a":1,"a":2,"b":[{"c":1,"c":2}]}"#,
            #"{"\uD800":1,"providerUsage":2}"#,
            #"{"\uDC00x":1}"#,
            #"{"\uD83D\uDE00":1,"providerUsage":2}"#,
            #"{"a\"b":1,"providerUsage":"c\\d"}"#,
            #"{"\\":1,"providerUsage":"\""}"#,
            #"{"\"providerUsage\"":1}"#,
            // Escapes.
            #"{"providerUsage":"\"\\\/\b\f\n\r\t\u0041\u00e9\uFFFF"}"#,
            #"{"providerUsage":"\x"}"#,
            #"{"providerUsage":"\u12"}"#,
            #"{"providerUsage":"\u12G4"}"#,
            #"{"providerUsage":"\u"}"#,
            #"{"providerUsage":"\uABC"#,
            #"{"providerUsage":"\"#,
            #"{"providerUsage":"\'"}"#,
            #"{"pro\viderUsage":1}"#,
            #"{"providerUsage":"\U0041"}"#,
            // Control bytes inside and outside strings.
            "{\"providerUsage\":\"a\u{01}b\"}",
            "{\"providerUsage\":\"a\u{1F}b\"}",
            "{\"providerUsage\":\"a\u{00}b\"}",
            "{\"providerUsage\":\"a\tb\"}",
            "{\"providerUsage\":\u{01}1}",
            "{\u{00}\"providerUsage\":1}",
            "{\"providerUsage\":1}\u{00}",
            "{\"providerUsage\"\u{0B}:1}",
            "{\"providerUsage\":1\u{0C}}",
            "{\"providerUsage\":\"\u{7F}\"}",
            // Numbers.
            #"{"providerUsage":-0}"#,
            #"{"providerUsage":-0.0}"#,
            #"{"providerUsage":0e0}"#,
            #"{"providerUsage":0E+0}"#,
            #"{"providerUsage":0e-0}"#,
            #"{"providerUsage":1e1000}"#,
            #"{"providerUsage":-12345678901234567890123456789012345678901234567890.12345678901234567890e-12345678901234567890}"#,
            #"{"providerUsage":01}"#,
            #"{"providerUsage":-}"#,
            #"{"providerUsage":-a}"#,
            #"{"providerUsage":1.}"#,
            #"{"providerUsage":.5}"#,
            #"{"providerUsage":1.e5}"#,
            #"{"providerUsage":1e}"#,
            #"{"providerUsage":1e+}"#,
            #"{"providerUsage":1E-}"#,
            #"{"providerUsage":+1}"#,
            #"{"providerUsage":1.5.5}"#,
            #"{"providerUsage":1e5e5}"#,
            #"{"providerUsage":--1}"#,
            #"{"providerUsage":0x10}"#,
            #"{"providerUsage":[1,-0,0.10,1E+5,-1e-5,100000]}"#,
            #"{"providerUsage":1"#,
            #"{"providerUsage":-"#,
            #"{"providerUsage":1e"#,
            #"{"providerUsage":1."#,
            // Literals.
            #"{"providerUsage":true}"#,
            #"{"providerUsage":false}"#,
            #"{"providerUsage":null}"#,
            #"{"providerUsage":tru}"#,
            #"{"providerUsage":fals}"#,
            #"{"providerUsage":nul}"#,
            #"{"providerUsage":nulll}"#,
            #"{"providerUsage":True}"#,
            #"{"providerUsage":nan}"#,
            #"{"providerUsage":t"#,
            #"{"providerUsage":nu"#,
            #"{"providerUsage":[truex]}"#,
            // Structure.
            #"{"providerUsage":1,}"#,
            #"{"providerUsage":[1,]}"#,
            #"{"providerUsage":{"a":1,}}"#,
            #"{,"providerUsage":1}"#,
            #"{"providerUsage":1,,"a":2}"#,
            #"{"providerUsage":[1}"#,
            #"{"providerUsage":{"a":1]}"#,
            #"{"providerUsage":[}"#,
            #"{"providerUsage":]}"#,
            #"{"providerUsage"1}"#,
            #"{"providerUsage"::1}"#,
            #"{"providerUsage":}"#,
            #"{"providerUsage"}"#,
            #"{providerUsage:1}"#,
            #"{"providerUsage":{"a"}}"#,
            #"{"providerUsage":{"a":}}"#,
            #"{"providerUsage":{1:2}}"#,
            #"{"providerUsage":{"a":1 "b":2}}"#,
            #"{"providerUsage":[1 2]}"#,
            #"{"providerUsage":1}}"#,
            #"{"providerUsage":1} {"#,
            #"{"providerUsage":1} x"#,
            #"{"providerUsage":1}   "#,
            #"{"providerUsage":1"#,
            #"{"providerUsage""#,
            #"{"providerUsage"#,
            #"{"#,
            #"}"#,
            #"{"a":1 "#,
            #"{"a":1,"#,
            #"{"a":1,}"#,
            #"{]"#
        ]
        var cases = texts.map { [UInt8]($0.utf8) }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        cases += [
            bom + Array(#"{"providerUsage":1,"a":2}"#.utf8),
            bom + Array(#"  {"a":2}"#.utf8),
            bom + Array("[1]".utf8),
            bom,
            [0xEF, 0xBB],
            [0xEF],
            [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("{}".utf8),
            [0x20] + bom + Array("{}".utf8),
            bom + Array(#""x""#.utf8),
            // Invalid UTF-8 inside strings, keys and outside.
            Array(#"{"providerUsage":""#.utf8) + [0xFF, 0xFE, 0xC0, 0x80] + Array(#""}"#.utf8),
            Array(#"{""#.utf8) + [0xFF] + Array(#"":1,"providerUsage":2}"#.utf8),
            Array(#"{"\n"#.utf8) + [0xFF] + Array(#"":1}"#.utf8),
            Array(#"{"providerUsage":"#.utf8) + [0xFF] + Array("}".utf8),
            Array(#"{"providerUsage":"\u00"#.utf8) + [0xE9] + Array(#"0"}"#.utf8),
            Array(#"{"providerUsage":"#.utf8) + [0xED, 0xA0, 0x80] + Array("}".utf8),
            Array(#"{"providerUsage":""#.utf8) + [0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80] + Array(#""}"#.utf8)
        ]
        // Long values and long whitespace runs.
        cases.append(Array(#"{"providerUsage":"#.utf8) + [UInt8](repeating: 0x39, count: 5000) + Array("}".utf8))
        cases.append(Array(#"{"providerUsage":"#.utf8) + [UInt8](repeating: 0x20, count: 5000) + Array("1}".utf8))
        cases.append(Array(#"{"providerUsage":""#.utf8) + [UInt8](repeating: 0x5C, count: 4000) + Array(#""}"#.utf8))
        cases.append(Array(#"{"providerUsage":""#.utf8) + [UInt8](repeating: 0x5C, count: 4001) + Array(#""}"#.utf8))
        cases.append(Array(#"{"providerUsage":0."#.utf8) + [UInt8](repeating: 0x30, count: 5000) + Array("e-1}".utf8))
        return cases
    }
}

private extension AgentProviderUsageRecord {
    /// Production `AgentProviderUsageRawValue.losslessRecord(of:shape:)` driven by the frozen
    /// reference scanner's shape instead of the production one.
    static func legacyProjection(of data: Data) -> AgentProviderUsageRecord? {
        AgentProviderUsageRawValue.losslessRecord(of: data) { LegacyAgentProviderUsageJSONScannerReference.shape(of: $0) }
    }
}

/// Deterministic SplitMix64 generator (seed printed with every fuzz failure).
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
