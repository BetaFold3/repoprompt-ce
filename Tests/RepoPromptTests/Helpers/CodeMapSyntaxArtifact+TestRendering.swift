import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI

extension CodeMapSyntaxArtifact {
    func renderedCodeMap(displayPath: String) -> String {
        CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: imports
        ) + apiDescription
    }
}
