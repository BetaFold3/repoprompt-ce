import Foundation

package struct AgentContextUsage: Codable, Equatable {
    package var modelContextWindow: Int?
    package var configuredContextWindow: Int? = nil
    package var lastTotalTokens: Int?
    package var totalTotalTokens: Int?

    package init(
        modelContextWindow: Int? = nil,
        configuredContextWindow: Int? = nil,
        lastTotalTokens: Int? = nil,
        totalTotalTokens: Int? = nil
    ) {
        self.modelContextWindow = modelContextWindow
        self.configuredContextWindow = configuredContextWindow
        self.lastTotalTokens = lastTotalTokens
        self.totalTotalTokens = totalTotalTokens
    }
}
