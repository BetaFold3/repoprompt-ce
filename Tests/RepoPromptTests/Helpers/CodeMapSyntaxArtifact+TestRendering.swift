import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp

extension CodeMapSyntaxArtifact {
    func renderedCodeMap(displayPath: String) -> String {
        CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: imports
        ) + apiDescription
    }
}
