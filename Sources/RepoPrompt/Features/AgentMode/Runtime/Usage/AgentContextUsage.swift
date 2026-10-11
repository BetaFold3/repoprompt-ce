import Foundation

struct AgentContextUsage: Codable, Equatable {
    var modelContextWindow: Int?
    var configuredContextWindow: Int? = nil
    var lastTotalTokens: Int?
    var totalTotalTokens: Int?
}
