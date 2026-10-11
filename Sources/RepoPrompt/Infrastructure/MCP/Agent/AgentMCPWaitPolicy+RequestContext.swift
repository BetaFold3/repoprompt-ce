import Foundation
import RepoPromptAgentCore
import RepoPromptShared

// App-owned: carries `MCPServerViewModel.RequestMetadata`.
extension AgentMCPWaitPolicy {
    /// The already authenticated request metadata plus the frozen parent-family classification
    /// and prompt-cache retention visible at the matched parent process launch.
    struct RequestContext {
        let metadata: MCPServerViewModel.RequestMetadata
        let parentFamily: ParentFamily
        let parentPromptCacheRetention: ParentPromptCacheRetention

        init(
            metadata: MCPServerViewModel.RequestMetadata,
            parentFamily: ParentFamily,
            parentPromptCacheRetention: ParentPromptCacheRetention
        ) {
            self.metadata = metadata
            self.parentFamily = parentFamily
            self.parentPromptCacheRetention = parentPromptCacheRetention
        }

        static func unresolved(metadata: MCPServerViewModel.RequestMetadata) -> RequestContext {
            RequestContext(
                metadata: metadata,
                parentFamily: .unresolved,
                parentPromptCacheRetention: .standard
            )
        }
    }
}
