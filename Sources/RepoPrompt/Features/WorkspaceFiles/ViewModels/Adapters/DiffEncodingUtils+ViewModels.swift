import Foundation
import RepoPromptWorkspace

extension DiffEncodingUtils {
    /// Returns: encoded original lines, detected indent type ("s"|"t"), and
    /// `usesSpaces` convenience flag.
    static func encodedOriginal(of fileVM: FileViewModel) async throws
        -> ([String], String, Bool)
    {
        let original = await fileVM.latestContent ?? ""
        let (lines, _) = String.splitContentPreservingLineEndings(original)
        let (indent, _) = String.detectIndentationTypeFromLines(lines) // defaults to ("s", 4)
        let usesSpaces = indent == "s"
        let encodedOriginal = lines.map {
            String.encodeIndentationWithConversion(
                $0,
                desiredIndentationType: indent
            )
        }
        return (encodedOriginal, indent, usesSpaces)
    }
}
