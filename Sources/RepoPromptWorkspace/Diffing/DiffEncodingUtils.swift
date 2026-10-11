import Foundation

/// Pure helpers (no AppKit/SwiftUI) that were previously duplicated.
package enum DiffEncodingUtils {
    /// Helper to encode arbitrary raw text into `[String]` by splitting it into lines
    /// with `DiffParserUtils.splitContentToLines` (the App adapter `encodedOriginal(of:)`
    /// uses the same rules).
    package static func encode(_ raw: String, usesSpaces: Bool) -> [String] {
        DiffParserUtils.splitContentToLines(raw, usesSpaces)
    }
}
