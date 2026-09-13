import Foundation

/// Feature-private JSON byte scanner for the session envelope's `providerUsage` member
/// (plan §3.3 preservation amendment).
///
/// The scanner walks the RFC 8259 grammar over raw bytes and only ever reports byte ranges: it
/// never converts a numeric token to any numeric type, so arbitrary lexemes (any significand
/// length, any exponent) are preserved byte-for-byte. Containers are tracked with an explicit
/// stack rather than recursion, so nesting depth is bounded by memory, not the call stack.
/// It is a boundary utility, not a general JSON object model.
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
        var cursor = Cursor(bytes: [UInt8](data))
        cursor.skipWhitespace()
        let start = cursor.index
        try cursor.scanValue()
        let end = cursor.index
        cursor.skipWhitespace()
        guard cursor.isAtEnd else { throw cursor.error(.trailingContent) }
        return Data(cursor.bytes[start ..< end])
    }

    /// Splits `data`, which must be a single JSON object, at the top-level member `name`.
    /// Nested members with the same name are untouched. A duplicated top-level member is
    /// rejected as ambiguous rather than silently selecting one occurrence.
    static func splitTopLevelMember(named name: String, in data: Data) throws -> TopLevelSplit {
        var cursor = Cursor(bytes: [UInt8](data))
        cursor.skipByteOrderMark()
        cursor.skipWhitespace()
        guard !cursor.isAtEnd, cursor.bytes[cursor.index] == Byte.openBrace else {
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
        let targetKey = [UInt8](name.utf8)

        while true {
            cursor.skipWhitespace()
            guard !cursor.isAtEnd else { throw cursor.error(.unexpectedEnd) }
            if memberCount == 0, cursor.bytes[cursor.index] == Byte.closeBrace {
                cursor.index += 1
                break
            }
            guard cursor.bytes[cursor.index] == Byte.quote else { throw cursor.error(.unexpectedByte) }
            let keyStart = cursor.index
            try cursor.scanString()
            let keyEnd = cursor.index
            let isTarget = try cursor.keyMatches(targetKey, quotedRange: keyStart ..< keyEnd)
            cursor.skipWhitespace()
            guard !cursor.isAtEnd else { throw cursor.error(.unexpectedEnd) }
            guard cursor.bytes[cursor.index] == Byte.colon else { throw cursor.error(.unexpectedByte) }
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
            let separator = cursor.bytes[cursor.index]
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
        var envelope = Data(cursor.bytes[0 ..< removal.lowerBound])
        envelope.append(contentsOf: cursor.bytes[removal.upperBound...])
        return TopLevelSplit(envelope: envelope, memberValue: Data(cursor.bytes[found.valueStart ..< found.valueEnd]))
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
        var cursor = Cursor(bytes: [UInt8](data))
        cursor.skipWhitespace()
        return ShapeBuilder(stringDecoder: JSONDecoder()).build(&cursor, depth: 0, maxDepth: maxDepth)
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

        static func isHex(_ byte: UInt8) -> Bool {
            isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    // MARK: - Cursor

    struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool {
            index >= bytes.count
        }

        func error(_ kind: ScanError.Kind) -> ScanError {
            ScanError(kind: kind, offset: index)
        }

        mutating func skipWhitespace() {
            while index < bytes.count, Byte.isWhitespace(bytes[index]) {
                index += 1
            }
        }

        mutating func skipByteOrderMark() {
            if index == 0, bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                index = 3
            }
        }

        /// Scans exactly one JSON value starting at `index` (whitespace already skipped) and leaves
        /// `index` immediately after its last byte. Iterative: containers use an explicit stack.
        mutating func scanValue() throws {
            enum Expectation { case value, valueOrClose, keyOrClose, key, colon, commaOrClose }
            var stack: [UInt8] = []
            var expectation = Expectation.value
            while true {
                skipWhitespace()
                guard index < bytes.count else { throw error(.unexpectedEnd) }
                let byte = bytes[index]
                switch expectation {
                case .value, .valueOrClose:
                    if expectation == .valueOrClose, byte == Byte.closeBracket {
                        stack.removeLast()
                        index += 1
                        expectation = .commaOrClose
                    } else {
                        switch byte {
                        case Byte.openBrace:
                            stack.append(Byte.openBrace)
                            index += 1
                            expectation = .keyOrClose
                        case Byte.openBracket:
                            stack.append(Byte.openBracket)
                            index += 1
                            expectation = .valueOrClose
                        case Byte.quote:
                            try scanString()
                            expectation = .commaOrClose
                        case Byte.minus, 0x30 ... 0x39:
                            try scanNumber()
                            expectation = .commaOrClose
                        case Byte.lowerT, Byte.lowerF, Byte.lowerN:
                            try scanLiteral()
                            expectation = .commaOrClose
                        default:
                            throw error(.unexpectedByte)
                        }
                    }
                case .keyOrClose:
                    if byte == Byte.closeBrace {
                        stack.removeLast()
                        index += 1
                        expectation = .commaOrClose
                    } else if byte == Byte.quote {
                        try scanString()
                        expectation = .colon
                    } else {
                        throw error(.unexpectedByte)
                    }
                case .key:
                    guard byte == Byte.quote else { throw error(.unexpectedByte) }
                    try scanString()
                    expectation = .colon
                case .colon:
                    guard byte == Byte.colon else { throw error(.unexpectedByte) }
                    index += 1
                    expectation = .value
                case .commaOrClose:
                    guard let top = stack.last else { return }
                    if byte == Byte.comma {
                        index += 1
                        expectation = top == Byte.openBrace ? .key : .value
                    } else if byte == Byte.closeBrace, top == Byte.openBrace {
                        stack.removeLast()
                        index += 1
                    } else if byte == Byte.closeBracket, top == Byte.openBracket {
                        stack.removeLast()
                        index += 1
                    } else {
                        throw error(.unexpectedByte)
                    }
                }
                if expectation == .commaOrClose, stack.isEmpty {
                    return
                }
            }
        }

        mutating func scanString() throws {
            guard index < bytes.count, bytes[index] == Byte.quote else { throw error(.invalidString) }
            index += 1
            while true {
                guard index < bytes.count else { throw error(.unexpectedEnd) }
                let byte = bytes[index]
                if byte == Byte.quote {
                    index += 1
                    return
                }
                if byte == Byte.backslash {
                    index += 1
                    guard index < bytes.count else { throw error(.unexpectedEnd) }
                    switch bytes[index] {
                    case Byte.quote, Byte.backslash, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 1
                    case Byte.lowerU:
                        index += 1
                        guard index + 4 <= bytes.count else { throw error(.unexpectedEnd) }
                        for offset in 0 ..< 4 where !Byte.isHex(bytes[index + offset]) {
                            throw ScanError(kind: .invalidString, offset: index + offset)
                        }
                        index += 4
                    default:
                        throw error(.invalidString)
                    }
                    continue
                }
                if byte < 0x20 { throw error(.invalidString) }
                index += 1
            }
        }

        mutating func scanNumber() throws {
            if index < bytes.count, bytes[index] == Byte.minus {
                index += 1
            }
            guard index < bytes.count else { throw error(.unexpectedEnd) }
            if bytes[index] == Byte.zero {
                index += 1
            } else if Byte.isDigit(bytes[index]) {
                while index < bytes.count, Byte.isDigit(bytes[index]) {
                    index += 1
                }
            } else {
                throw error(.invalidNumber)
            }
            if index < bytes.count, bytes[index] == Byte.period {
                index += 1
                guard index < bytes.count, Byte.isDigit(bytes[index]) else { throw error(.invalidNumber) }
                while index < bytes.count, Byte.isDigit(bytes[index]) {
                    index += 1
                }
            }
            if index < bytes.count, bytes[index] == Byte.lowerE || bytes[index] == Byte.upperE {
                index += 1
                if index < bytes.count, bytes[index] == Byte.plus || bytes[index] == Byte.minus {
                    index += 1
                }
                guard index < bytes.count, Byte.isDigit(bytes[index]) else { throw error(.invalidNumber) }
                while index < bytes.count, Byte.isDigit(bytes[index]) {
                    index += 1
                }
            }
        }

        mutating func scanLiteral() throws {
            let literal: [UInt8] = switch bytes[index] {
            case Byte.lowerT: [0x74, 0x72, 0x75, 0x65]
            case Byte.lowerF: [0x66, 0x61, 0x6C, 0x73, 0x65]
            default: [0x6E, 0x75, 0x6C, 0x6C]
            }
            guard index + literal.count <= bytes.count,
                  Array(bytes[index ..< index + literal.count]) == literal
            else {
                throw error(.invalidLiteral)
            }
            index += literal.count
        }

        /// Compares a scanned quoted key with `target` bytes; escaped keys are decoded first.
        func keyMatches(_ target: [UInt8], quotedRange: Range<Int>) throws -> Bool {
            let inner = bytes[(quotedRange.lowerBound + 1) ..< (quotedRange.upperBound - 1)]
            if !inner.contains(Byte.backslash) {
                return Array(inner) == target
            }
            let decoded = try JSONDecoder().decode(String.self, from: Data(bytes[quotedRange]))
            return Array(decoded.utf8) == target
        }
    }

    // MARK: - Shape builder (depth-bounded)

    private struct ShapeBuilder {
        let stringDecoder: JSONDecoder

        /// Recursion is bounded by `maxDepth`; deeper values yield `nil` (not comparable).
        func build(_ cursor: inout Cursor, depth: Int, maxDepth: Int) -> Shape? {
            guard depth <= maxDepth, !cursor.isAtEnd else { return nil }
            switch cursor.bytes[cursor.index] {
            case Byte.openBrace:
                cursor.index += 1
                var members: [String: Shape] = [:]
                cursor.skipWhitespace()
                if !cursor.isAtEnd, cursor.bytes[cursor.index] == Byte.closeBrace {
                    cursor.index += 1
                    return .object(members)
                }
                while true {
                    cursor.skipWhitespace()
                    let keyStart = cursor.index
                    guard (try? cursor.scanString()) != nil,
                          let key = try? stringDecoder.decode(String.self, from: Data(cursor.bytes[keyStart ..< cursor.index]))
                    else { return nil }
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd, cursor.bytes[cursor.index] == Byte.colon else { return nil }
                    cursor.index += 1
                    cursor.skipWhitespace()
                    guard let value = build(&cursor, depth: depth + 1, maxDepth: maxDepth) else { return nil }
                    guard members.updateValue(value, forKey: key) == nil else { return nil }
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd else { return nil }
                    if cursor.bytes[cursor.index] == Byte.comma {
                        cursor.index += 1
                        continue
                    }
                    guard cursor.bytes[cursor.index] == Byte.closeBrace else { return nil }
                    cursor.index += 1
                    return .object(members)
                }
            case Byte.openBracket:
                cursor.index += 1
                var elements: [Shape] = []
                cursor.skipWhitespace()
                if !cursor.isAtEnd, cursor.bytes[cursor.index] == Byte.closeBracket {
                    cursor.index += 1
                    return .array(elements)
                }
                while true {
                    cursor.skipWhitespace()
                    guard let value = build(&cursor, depth: depth + 1, maxDepth: maxDepth) else { return nil }
                    elements.append(value)
                    cursor.skipWhitespace()
                    guard !cursor.isAtEnd else { return nil }
                    if cursor.bytes[cursor.index] == Byte.comma {
                        cursor.index += 1
                        continue
                    }
                    guard cursor.bytes[cursor.index] == Byte.closeBracket else { return nil }
                    cursor.index += 1
                    return .array(elements)
                }
            case Byte.quote:
                let start = cursor.index
                guard (try? cursor.scanString()) != nil,
                      let string = try? stringDecoder.decode(String.self, from: Data(cursor.bytes[start ..< cursor.index]))
                else { return nil }
                return .string(string)
            case Byte.minus, 0x30 ... 0x39:
                let start = cursor.index
                guard (try? cursor.scanNumber()) != nil,
                      let canonical = canonicalNumber(Array(cursor.bytes[start ..< cursor.index]))
                else { return nil }
                return .number(canonical)
            case Byte.lowerT, Byte.lowerF, Byte.lowerN:
                let start = cursor.index
                guard (try? cursor.scanLiteral()) != nil else { return nil }
                switch cursor.bytes[start] {
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
