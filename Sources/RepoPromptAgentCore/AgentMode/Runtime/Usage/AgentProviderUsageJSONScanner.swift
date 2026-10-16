import Foundation

/// Feature-private JSON byte scanner for the session envelope's `providerUsage` member
/// (plan §3.3 preservation amendment).
///
/// The scanner walks the RFC 8259 grammar over raw bytes and only ever reports byte ranges: it
/// never converts a numeric token to any numeric type, so arbitrary lexemes (any significand
/// length, any exponent) are preserved byte-for-byte. Containers are tracked with an explicit
/// stack rather than recursion, so nesting depth is bounded by memory, not the call stack.
/// It is a boundary utility, not a general JSON object model.
///
/// Every entry point scans a pointer borrowed from the input `Data` inside `withCursor` (no copy
/// into an array); result bytes are copied out before that scope ends and no pointer escapes it.
/// Offsets are zero-based relative to the supplied bytes, including for `Data` slices.
enum AgentProviderUsageJSONScanner {
    struct ScanError: Error, Equatable, CustomStringConvertible {
        enum Kind: Equatable {
            case unexpectedEnd
            case unexpectedByte
            case invalidNumber
            case invalidString
            case invalidLiteral
            case trailingContent
            case notAnObject
            case duplicateTopLevelMember
        }

        let kind: Kind
        let offset: Int

        var description: String {
            "providerUsage JSON scan failed (\(kind)) at byte offset \(offset)"
        }
    }

    /// Result of splitting a top-level object at one member.
    struct TopLevelSplit: Equatable {
        /// The object bytes with the member (and its separating comma) removed; identical to the
        /// input when the member is absent.
        let envelope: Data
        /// Exact bytes of the member's value (no surrounding whitespace), or `nil` when absent.
        let memberValue: Data?
    }

    /// Validates that `data` holds exactly one JSON value (surrounding whitespace allowed) and
    /// returns the exact value bytes.
    static func validatedValue(in data: Data) throws -> Data {
        try withCursor(data) { cursor in
            cursor.skipWhitespace()
            let start = cursor.index
            try cursor.scanValue()
            let end = cursor.index
            cursor.skipWhitespace()
            guard cursor.isAtEnd else { throw cursor.error(.trailingContent) }
            return cursor.copyBytes(start ..< end)
        }
    }

    /// Splits `data`, which must be a single JSON object, at the top-level member `name`.
    /// Nested members with the same name are untouched. A duplicated top-level member is
    /// rejected as ambiguous rather than silently selecting one occurrence.
    static func splitTopLevelMember(named name: String, in data: Data) throws -> TopLevelSplit {
        let targetKey = [UInt8](name.utf8)
        return try withCursor(data) { cursor in
            cursor.skipByteOrderMark()
            cursor.skipWhitespace()
            guard !cursor.isAtEnd, cursor.currentByte == Byte.openBrace else {
                throw cursor.error(.notAnObject)
            }
            cursor.index += 1

            struct Match {
                let keyStart: Int
                let valueStart: Int
                let valueEnd: Int
                let precedingComma: Int?
                var followingComma: Int?
            }
            var match: Match?
            var memberCount = 0
            var previousComma: Int?

            while true {
                cursor.skipWhitespace()
                guard !cursor.isAtEnd else { throw cursor.error(.unexpectedEnd) }
                if memberCount == 0, cursor.currentByte == Byte.closeBrace {
                    cursor.index += 1
                    break
                }
                guard cursor.currentByte == Byte.quote else { throw cursor.error(.unexpectedByte) }
                let keyStart = cursor.index
                try cursor.scanString()
                let keyEnd = cursor.index
                let isTarget = try cursor.keyMatches(targetKey, quotedRange: keyStart ..< keyEnd)
                cursor.skipWhitespace()
                guard !cursor.isAtEnd else { throw cursor.error(.unexpectedEnd) }
                guard cursor.currentByte == Byte.colon else { throw cursor.error(.unexpectedByte) }
                cursor.index += 1
                cursor.skipWhitespace()
                let valueStart = cursor.index
                try cursor.scanValue()
                let valueEnd = cursor.index
                if isTarget {
                    guard match == nil else { throw ScanError(kind: .duplicateTopLevelMember, offset: keyStart) }
                    match = Match(keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd, precedingComma: previousComma, followingComma: nil)
                }
                memberCount += 1
                cursor.skipWhitespace()
                guard !cursor.isAtEnd else { throw cursor.error(.unexpectedEnd) }
                let separator = cursor.currentByte
                if separator == Byte.comma {
                    if isTarget { match?.followingComma = cursor.index }
                    previousComma = cursor.index
                    cursor.index += 1
                    continue
                }
                guard separator == Byte.closeBrace else { throw cursor.error(.unexpectedByte) }
                cursor.index += 1
                break
            }
            cursor.skipWhitespace()
            guard cursor.isAtEnd else { throw cursor.error(.trailingContent) }

            guard let found = match else {
                return TopLevelSplit(envelope: data, memberValue: nil)
            }
            let removal: Range<Int> = if let precedingComma = found.precedingComma {
                precedingComma ..< found.valueEnd
            } else if let followingComma = found.followingComma {
                found.keyStart ..< (followingComma + 1)
            } else {
                found.keyStart ..< found.valueEnd
            }
            var envelope = Data(capacity: cursor.count - removal.count)
            cursor.appendBytes(0 ..< removal.lowerBound, to: &envelope)
            cursor.appendBytes(removal.upperBound ..< cursor.count, to: &envelope)
            return TopLevelSplit(envelope: envelope, memberValue: cursor.copyBytes(found.valueStart ..< found.valueEnd))
        }
    }

    // MARK: - Lossless-projection comparison shape

    /// Order-insensitive comparison shape used only to prove that a typed v1 projection reproduces
    /// a raw value. Numbers are canonical lexeme forms, never numeric types. `nil` means the value
    /// cannot be compared exactly (duplicate keys, unrepresentable exponent, undecodable string, or
    /// nesting beyond `maxDepth`), which callers must treat as "not lossless".
    indirect enum Shape: Equatable {
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case array([Shape])
        case object([String: Shape])
    }

    static func shape(of data: Data, maxDepth: Int = 64) -> Shape? {
        guard (try? validatedValue(in: data)) != nil else { return nil }
        return withCursor(data) { cursor in
            cursor.skipWhitespace()
            return ShapeBuilder(stringDecoder: JSONDecoder()).build(&cursor, depth: 0, maxDepth: maxDepth)
        }
    }

    /// Canonical form of a JSON number lexeme: `<sign><digits without leading/trailing zeros>e<exponent>`,
    /// or `0` / `-0`. `nil` when the exponent does not fit `Int` (treated as not comparable).
    static func canonicalNumber(_ lexeme: [UInt8]) -> String? {
        var index = 0
        var negative = false
        if index < lexeme.count, lexeme[index] == Byte.minus {
            negative = true
            index += 1
        }
        var digits: [UInt8] = []
        while index < lexeme.count, Byte.isDigit(lexeme[index]) {
            digits.append(lexeme[index])
            index += 1
        }
        var fractionCount = 0
        if index < lexeme.count, lexeme[index] == Byte.period {
            index += 1
            while index < lexeme.count, Byte.isDigit(lexeme[index]) {
                digits.append(lexeme[index])
                fractionCount += 1
                index += 1
            }
        }
        var exponent = 0
        if index < lexeme.count, lexeme[index] == Byte.lowerE || lexeme[index] == Byte.upperE {
            index += 1
            let exponentText = String(decoding: lexeme[index...], as: UTF8.self)
            guard let parsed = Int(exponentText.hasPrefix("+") ? String(exponentText.dropFirst()) : exponentText) else {
                return nil
            }
            exponent = parsed
        }
        let (adjusted, overflow) = exponent.subtractingReportingOverflow(fractionCount)
        guard !overflow else { return nil }
        exponent = adjusted
        while let first = digits.first, first == Byte.zero {
            digits.removeFirst()
        }
        while let last = digits.last, last == Byte.zero {
            digits.removeLast()
            let (bumped, bumpOverflow) = exponent.addingReportingOverflow(1)
            guard !bumpOverflow else { return nil }
            exponent = bumped
        }
        guard !digits.isEmpty else { return negative ? "-0" : "0" }
        return (negative ? "-" : "") + String(decoding: digits, as: UTF8.self) + "e" + String(exponent)
    }

    // MARK: - Byte constants

    enum Byte {
        static let openBrace: UInt8 = 0x7B
        static let closeBrace: UInt8 = 0x7D
        static let openBracket: UInt8 = 0x5B
        static let closeBracket: UInt8 = 0x5D
        static let quote: UInt8 = 0x22
        static let backslash: UInt8 = 0x5C
        static let colon: UInt8 = 0x3A
        static let comma: UInt8 = 0x2C
        static let minus: UInt8 = 0x2D
        static let plus: UInt8 = 0x2B
        static let period: UInt8 = 0x2E
        static let zero: UInt8 = 0x30
        static let lowerE: UInt8 = 0x65
        static let upperE: UInt8 = 0x45
        static let lowerU: UInt8 = 0x75
        static let lowerT: UInt8 = 0x74
        static let lowerF: UInt8 = 0x66
        static let lowerN: UInt8 = 0x6E

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= 0x30 && byte <= 0x39
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    // MARK: - Cursor

    /// Runs `body` with a cursor over `data`'s bytes, borrowed for the duration of the call only.
    /// Neither the cursor nor its pointer may escape `body`; results are copied out as `Data`.
    private static func withCursor<Result>(_ data: Data, _ body: (inout Cursor) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buffer = raw.bindMemory(to: UInt8.self)
            if let base = buffer.baseAddress, buffer.count > 0 {
                var cursor = Cursor(base: base, count: buffer.count)
                return try body(&cursor)
            }
            // Empty input may have no base address. With `count == 0` every read is guarded by a
            // bounds check first, so the placeholder byte is never read.
            let placeholder: UInt8 = 0
            return try withUnsafePointer(to: placeholder) { pointer in
                var cursor = Cursor(base: pointer, count: 0)
                return try body(&cursor)
            }
        }
    }

    /// Scanner position over borrowed bytes. `skipWhitespace`, `scanString` and `scanNumber` copy
    /// `base`, `count` and `index` into locals and write `index` back before returning or throwing;
    /// `scanValue`, `scanLiteral` and the top-level split update `index` in place. Either way error
    /// offsets and the final position are identical to an array-backed scan.
    struct Cursor {
        private let base: UnsafePointer<UInt8>
        let count: Int
        var index = 0

        fileprivate init(base: UnsafePointer<UInt8>, count: Int) {
            self.base = base
            self.count = count
        }

        var isAtEnd: Bool {
            index >= count
        }

        /// Byte at `index`; callers check `isAtEnd` first.
        var currentByte: UInt8 {
            precondition(index >= 0 && index < count, "cursor read out of bounds")
            return base[index]
        }

        func byte(at position: Int) -> UInt8 {
            precondition(position >= 0 && position < count, "cursor read out of bounds")
            return base[position]
        }

        /// Copies `range` out of the borrowed bytes.
        func copyBytes(_ range: Range<Int>) -> Data {
            precondition(range.lowerBound >= 0 && range.upperBound <= count, "cursor copy out of bounds")
            return Data(bytes: base + range.lowerBound, count: range.count)
        }

        func byteArray(_ range: Range<Int>) -> [UInt8] {
            precondition(range.lowerBound >= 0 && range.upperBound <= count, "cursor copy out of bounds")
            return Array(UnsafeBufferPointer(start: base + range.lowerBound, count: range.count))
        }

        func appendBytes(_ range: Range<Int>, to data: inout Data) {
            precondition(range.lowerBound >= 0 && range.upperBound <= count, "cursor copy out of bounds")
            data.append(base + range.lowerBound, count: range.count)
        }

        func error(_ kind: ScanError.Kind) -> ScanError {
            ScanError(kind: kind, offset: index)
        }

        mutating func skipWhitespace() {
            let base = base
            let count = count
            var position = index
            while position < count {
                let byte = base[position]
                // Inline `Byte.isWhitespace` (space, tab, LF, CR).
                guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { break }
                position &+= 1
            }
            index = position
        }

        mutating func skipByteOrderMark() {
            if index == 0, count >= 3, base[0] == 0xEF, base[1] == 0xBB, base[2] == 0xBF {
                index = 3
            }
        }

        /// Scans exactly one JSON value starting at `index` (whitespace already skipped) and leaves
        /// `index` immediately after its last byte. Iterative: containers use an explicit stack.
        mutating func scanValue() throws {
            enum Expectation { case value, valueOrClose, keyOrClose, key, colon, commaOrClose }
            let openBrace = Byte.openBrace
            let closeBrace = Byte.closeBrace
            let openBracket = Byte.openBracket
            let closeBracket = Byte.closeBracket
            let quote = Byte.quote
            let colon = Byte.colon
            let comma = Byte.comma
            let minus = Byte.minus
            // `byte &- zero < 10` below is inline `Byte.isDigit` (0x30...0x39).
            let zero = Byte.zero
            let lowerT = Byte.lowerT
            let lowerF = Byte.lowerF
            let lowerN = Byte.lowerN
            // Open containers: `top` is the innermost one (meaningful only while `depth > 0`) and
            // `outer` holds the enclosing ones, so per-token checks never call into `Array`.
            var outer: [UInt8] = []
            var top: UInt8 = 0
            var depth = 0
            var expectation = Expectation.value
            while true {
                skipWhitespace()
                guard index < count else { throw error(.unexpectedEnd) }
                let byte = base[index]
                switch expectation {
                case .value, .valueOrClose:
                    if case .valueOrClose = expectation, byte == closeBracket {
                        depth &-= 1
                        if depth > 0 { top = outer.removeLast() }
                        index &+= 1
                        expectation = .commaOrClose
                    } else if byte == openBrace {
                        if depth > 0 { outer.append(top) }
                        top = openBrace
                        depth &+= 1
                        index &+= 1
                        expectation = .keyOrClose
                    } else if byte == openBracket {
                        if depth > 0 { outer.append(top) }
                        top = openBracket
                        depth &+= 1
                        index &+= 1
                        expectation = .valueOrClose
                    } else if byte == quote {
                        try scanString()
                        expectation = .commaOrClose
                    } else if byte == minus || byte &- zero < 10 {
                        try scanNumber()
                        expectation = .commaOrClose
                    } else if byte == lowerT || byte == lowerF || byte == lowerN {
                        try scanLiteral()
                        expectation = .commaOrClose
                    } else {
                        throw error(.unexpectedByte)
                    }
                case .keyOrClose:
                    if byte == closeBrace {
                        depth &-= 1
                        if depth > 0 { top = outer.removeLast() }
                        index &+= 1
                        expectation = .commaOrClose
                    } else if byte == quote {
                        try scanString()
                        expectation = .colon
                    } else {
                        throw error(.unexpectedByte)
                    }
                case .key:
                    guard byte == quote else { throw error(.unexpectedByte) }
                    try scanString()
                    expectation = .colon
                case .colon:
                    guard byte == colon else { throw error(.unexpectedByte) }
                    index &+= 1
                    expectation = .value
                case .commaOrClose:
                    guard depth > 0 else { return }
                    if byte == comma {
                        index &+= 1
                        expectation = top == openBrace ? .key : .value
                    } else if byte == closeBrace, top == openBrace {
                        depth &-= 1
                        if depth > 0 { top = outer.removeLast() }
                        index &+= 1
                    } else if byte == closeBracket, top == openBracket {
                        depth &-= 1
                        if depth > 0 { top = outer.removeLast() }
                        index &+= 1
                    } else {
                        throw error(.unexpectedByte)
                    }
                }
                if case .commaOrClose = expectation, depth == 0 {
                    return
                }
            }
        }

        /// Validates escapes and rejects raw control bytes; does not validate UTF-8.
        mutating func scanString() throws {
            let base = base
            let count = count
            let quote = Byte.quote
            let backslash = Byte.backslash
            let lowerU = Byte.lowerU
            var position = index
            guard position < count, base[position] == quote else { throw error(.invalidString) }
            position &+= 1
            while true {
                guard position < count else {
                    index = position
                    throw error(.unexpectedEnd)
                }
                let byte = base[position]
                if byte == quote {
                    index = position &+ 1
                    return
                }
                if byte == backslash {
                    position &+= 1
                    guard position < count else {
                        index = position
                        throw error(.unexpectedEnd)
                    }
                    let escaped = base[position]
                    if escaped == quote || escaped == backslash || escaped == 0x2F || escaped == 0x62
                        || escaped == 0x66 || escaped == 0x6E || escaped == 0x72 || escaped == 0x74
                    {
                        position &+= 1
                    } else if escaped == lowerU {
                        position &+= 1
                        guard position &+ 4 <= count else {
                            index = position
                            throw error(.unexpectedEnd)
                        }
                        var offset = 0
                        while offset < 4 {
                            let hex = base[position &+ offset]
                            // Inline hex-digit test (the former `Byte.isHex`: 0-9, A-F, a-f).
                            guard hex &- 0x30 < 10 || hex &- 0x41 < 6 || hex &- 0x61 < 6 else {
                                index = position
                                throw ScanError(kind: .invalidString, offset: position &+ offset)
                            }
                            offset &+= 1
                        }
                        position &+= 4
                    } else {
                        index = position
                        throw error(.invalidString)
                    }
                    continue
                }
                if byte < 0x20 {
                    index = position
                    throw error(.invalidString)
                }
                position &+= 1
            }
        }

        mutating func scanNumber() throws {
            let base = base
            let count = count
            let minus = Byte.minus
            let plus = Byte.plus
            let zero = Byte.zero
            let period = Byte.period
            let lowerE = Byte.lowerE
            let upperE = Byte.upperE
            var position = index
            defer { index = position }
            // `byte &- zero < 10` below is inline `Byte.isDigit` (0x30...0x39).
            if position < count, base[position] == minus {
                position &+= 1
            }
            guard position < count else { throw ScanError(kind: .unexpectedEnd, offset: position) }
            let first = base[position]
            if first == zero {
                position &+= 1
            } else if first &- zero < 10 {
                position &+= 1
                while position < count, base[position] &- zero < 10 {
                    position &+= 1
                }
            } else {
                throw ScanError(kind: .invalidNumber, offset: position)
            }
            if position < count, base[position] == period {
                position &+= 1
                guard position < count, base[position] &- zero < 10 else {
                    throw ScanError(kind: .invalidNumber, offset: position)
                }
                while position < count, base[position] &- zero < 10 {
                    position &+= 1
                }
            }
            if position < count, base[position] == lowerE || base[position] == upperE {
                position &+= 1
                if position < count, base[position] == plus || base[position] == minus {
                    position &+= 1
                }
                guard position < count, base[position] &- zero < 10 else {
                    throw ScanError(kind: .invalidNumber, offset: position)
                }
                while position < count, base[position] &- zero < 10 {
                    position &+= 1
                }
            }
        }

        /// Matches `true`, `false` or `null` at `index` (callers have checked `index < count`).
        mutating func scanLiteral() throws {
            let base = base
            let count = count
            let start = index
            let first = base[start]
            let length: Int
            let matches: Bool
            if first == Byte.lowerT {
                length = 4
                matches = start &+ length <= count && base[start] == 0x74 && base[start &+ 1] == 0x72
                    && base[start &+ 2] == 0x75 && base[start &+ 3] == 0x65
            } else if first == Byte.lowerF {
                length = 5
                matches = start &+ length <= count && base[start] == 0x66 && base[start &+ 1] == 0x61
                    && base[start &+ 2] == 0x6C && base[start &+ 3] == 0x73 && base[start &+ 4] == 0x65
            } else {
                length = 4
                matches = start &+ length <= count && base[start] == 0x6E && base[start &+ 1] == 0x75
                    && base[start &+ 2] == 0x6C && base[start &+ 3] == 0x6C
            }
            guard matches else { throw error(.invalidLiteral) }
            index = start &+ length
        }

        /// Compares a scanned quoted key with `target` bytes; escaped keys are decoded first.
        func keyMatches(_ target: [UInt8], quotedRange: Range<Int>) throws -> Bool {
            let base = base
            let innerStart = quotedRange.lowerBound &+ 1
            let innerEnd = quotedRange.upperBound &- 1
            let backslash = Byte.backslash
            var position = innerStart
            while position < innerEnd {
                if base[position] == backslash {
                    let decoded = try JSONDecoder().decode(String.self, from: copyBytes(quotedRange))
                    return Array(decoded.utf8) == target
                }
                position &+= 1
            }
            guard innerEnd &- innerStart == target.count else { return false }
            return target.withUnsafeBufferPointer { targetBytes in
                var offset = 0
                while offset < targetBytes.count {
                    if base[innerStart &+ offset] != targetBytes[offset] { return false }
                    offset &+= 1
                }
                return true
            }
        }
    }

    // MARK: - Shape builder (depth-bounded)

    private struct ShapeBuilder {
        let stringDecoder: JSONDecoder

        /// Recursion is bounded by `maxDepth`; deeper values yield `nil` (not comparable).
        func build(_ cursor: inout Cursor, depth: Int, maxDepth: Int) -> Shape? {
            guard depth <= maxDepth, !cursor.isAtEnd else { return nil }
            switch cursor.currentByte {
            case Byte.openBrace:
                cursor.index += 1
                var members: [String: Shape] = [:]
                cursor.skipWhitespace()
                if !cursor.isAtEnd, cursor.currentByte == Byte.closeBrace {
                    cursor.index += 1
                    return .object(members)
                }
                while true {
                    cursor.skipWhitespace()
                    let keyStart = cursor.index
                    guard (try? cursor.scanString()) != nil,
                          let key = try? stringDecoder.decode(String.self, from: cursor.copyBytes(keyStart ..< cursor.index))
                    else { return nil }
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd, cursor.currentByte == Byte.colon else { return nil }
                    cursor.index += 1
                    cursor.skipWhitespace()
                    guard let value = build(&cursor, depth: depth + 1, maxDepth: maxDepth) else { return nil }
                    guard members.updateValue(value, forKey: key) == nil else { return nil }
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd else { return nil }
                    if cursor.currentByte == Byte.comma {
                        cursor.index += 1
                        continue
                    }
                    guard cursor.currentByte == Byte.closeBrace else { return nil }
                    cursor.index += 1
                    return .object(members)
                }
            case Byte.openBracket:
                cursor.index += 1
                var elements: [Shape] = []
                cursor.skipWhitespace()
                if !cursor.isAtEnd, cursor.currentByte == Byte.closeBracket {
                    cursor.index += 1
                    return .array(elements)
                }
                while true {
                    cursor.skipWhitespace()
                    guard let value = build(&cursor, depth: depth + 1, maxDepth: maxDepth) else { return nil }
                    elements.append(value)
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd else { return nil }
                    if cursor.currentByte == Byte.comma {
                        cursor.index += 1
                        continue
                    }
                    guard cursor.currentByte == Byte.closeBracket else { return nil }
                    cursor.index += 1
                    return .array(elements)
                }
            case Byte.quote:
                let start = cursor.index
                guard (try? cursor.scanString()) != nil,
                      let string = try? stringDecoder.decode(String.self, from: cursor.copyBytes(start ..< cursor.index))
                else { return nil }
                return .string(string)
            case Byte.minus, 0x30 ... 0x39:
                let start = cursor.index
                guard (try? cursor.scanNumber()) != nil,
                      let canonical = canonicalNumber(cursor.byteArray(start ..< cursor.index))
                else { return nil }
                return .number(canonical)
            case Byte.lowerT, Byte.lowerF, Byte.lowerN:
                let start = cursor.index
                guard (try? cursor.scanLiteral()) != nil else { return nil }
                switch cursor.byte(at: start) {
                case Byte.lowerT: return .bool(true)
                case Byte.lowerF: return .bool(false)
                default: return .null
                }
            default:
                return nil
            }
        }
    }
}
