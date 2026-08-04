import Foundation

/// Decodes path tokens written in Git's C-quoted patch format.
///
/// Octal escapes encode UTF-8 bytes rather than Unicode scalars. Keeping the decoder in the Git
/// diff layer prevents rendering and mutation validation from disagreeing about a quoted path.
enum GitPatchPathCodec {
    /// Decodes one path token, preserving malformed input verbatim for display-only callers.
    static func decode(_ raw: String) -> String {
        decodeStrict(raw) ?? raw
    }

    /// Decodes one path token, rejecting malformed quoting or non-UTF-8 byte sequences.
    static func decodeStrict(_ raw: String) -> String? {
        guard raw.hasPrefix("\"") || raw.hasSuffix("\"") else { return raw }
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }

        let characters = Array(raw)
        var bytes: [UInt8] = []
        var index = 1
        let end = characters.count - 1

        while index < end {
            let character = characters[index]
            guard character == "\\" else {
                bytes.append(contentsOf: String(character).utf8)
                index += 1
                continue
            }

            index += 1
            guard index < end else { return nil }
            let escaped = characters[index]

            if let firstDigit = octalDigit(escaped) {
                var value = firstDigit
                var digitCount = 1
                index += 1
                while digitCount < 3, index < end, let digit = octalDigit(characters[index]) {
                    value = value * 8 + digit
                    digitCount += 1
                    index += 1
                }
                guard value <= 0xFF else { return nil }
                bytes.append(UInt8(value))
                continue
            }

            let byte: UInt8
            switch escaped {
            case "a": byte = 0x07
            case "b": byte = 0x08
            case "t": byte = 0x09
            case "n": byte = 0x0A
            case "v": byte = 0x0B
            case "f": byte = 0x0C
            case "r": byte = 0x0D
            case "\\": byte = 0x5C
            case "\"": byte = 0x22
            default: return nil
            }
            bytes.append(byte)
            index += 1
        }

        return String(data: Data(bytes), encoding: .utf8)
    }

    /// Tokenizes the whitespace-delimited path portion of a Git patch header.
    ///
    /// Quoted tokens retain their quotes until decoding so an embedded escaped space cannot split a
    /// filename. This parser is intentionally narrower than shell parsing: Git patch paths do not
    /// have interpolation, single quotes, or bare backslash escapes.
    static func tokens(in input: String) -> [String]? {
        let characters = Array(input)
        var result: [String] = []
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
            guard index < characters.count else { break }

            if characters[index] == "\"" {
                let start = index
                index += 1
                var escaped = false
                while index < characters.count {
                    let character = characters[index]
                    if escaped {
                        escaped = false
                        index += 1
                        continue
                    }
                    if character == "\\" {
                        escaped = true
                        index += 1
                        continue
                    }
                    if character == "\"" {
                        index += 1
                        break
                    }
                    index += 1
                }
                guard index <= characters.count,
                      index > start + 1,
                      characters[index - 1] == "\"",
                      index == characters.count || characters[index] == " " || characters[index] == "\t"
                else { return nil }
                let raw = String(characters[start ..< index])
                guard let decoded = decodeStrict(raw) else { return nil }
                result.append(decoded)
                continue
            }

            let start = index
            while index < characters.count, characters[index] != " ", characters[index] != "\t" {
                guard characters[index] != "\"", characters[index] != "\\" else { return nil }
                index += 1
            }
            guard start < index else { return nil }
            result.append(String(characters[start ..< index]))
        }

        return result
    }

    private static func octalDigit(_ character: Character) -> Int? {
        guard character.isASCII,
              let value = character.wholeNumberValue,
              (0 ... 7).contains(value)
        else { return nil }
        return value
    }
}
