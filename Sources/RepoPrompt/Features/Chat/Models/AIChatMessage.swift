//
//  AIChatMessage.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-14.
//

import Foundation

// MARK: - Supporting Models

struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    private(set) var content: String
    let isUser: Bool

    /// Event time shown in chat: user dispatch time or assistant terminal time.
    private(set) var timestamp: Date

    /// The sequence index determining message order.
    let sequenceIndex: Int
    private(set) var isFinalized: Bool = false
    private(set) var reasoningContent: String = ""

    /// The user's selected file paths at the time this message was created.
    private(set) var allowedFilePaths: [String] = []

    /// Quick access to how many files were selected when this message was created.
    var selectedFileCount: Int {
        allowedFilePaths.count
    }

    var revisionCount: Int = 0

    // Token counts for analytics
    private(set) var promptTokens: Int?
    private(set) var completionTokens: Int?
    private(set) var cost: Double?

    /// The AI model name (e.g. "gpt-4o", "Claude-Opus", etc.) associated with
    /// this assistant response.  `nil` for user messages or when unknown.
    private(set) var modelName: String?

    init(
        id: UUID = UUID(),
        content: String,
        isUser: Bool,
        timestamp: Date = Date(),
        isFinalized: Bool = false,
        sequenceIndex: Int = 0,
        allowedFilePaths: [String] = [],
        reasoningContent: String = "",
        modelName: String? = nil
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.sequenceIndex = sequenceIndex
        self.allowedFilePaths = allowedFilePaths
        self.isFinalized = isFinalized
        self.reasoningContent = reasoningContent
        self.modelName = modelName
    }

    static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.revisionCount == rhs.revisionCount
    }

    /// Updates the core `content` and increments revisionCount.
    mutating func updateContent(_ newContent: String) {
        content = newContent
        revisionCount += 1
    }

    /// Appends text to existing `content`, then increments revisionCount.
    mutating func appendContent(_ extra: String) {
        content += extra
        revisionCount += 1
    }

    mutating func updateReasoningContent(_ newReasoning: String) {
        reasoningContent = newReasoning
        revisionCount += 1
    }

    mutating func setIsFinalized(_ finalized: Bool) {
        isFinalized = finalized
        revisionCount += 1
    }

    /// Marks a live assistant response terminal and publishes its completion time atomically.
    /// Hydrated messages initialize or restore finalization without calling this method, so loading never rewrites persisted timestamps.
    @discardableResult
    mutating func markFinalized(at timestamp: Date) -> Bool {
        guard !isFinalized else { return false }
        self.timestamp = timestamp
        isFinalized = true
        revisionCount += 1
        return true
    }

    mutating func updateTokenInfo(_ info: ChatTokenInfo?) {
        promptTokens = info?.promptTokens
        completionTokens = info?.completionTokens
        cost = info?.cost
        revisionCount += 1
    }

    mutating func setAllowedPaths(_ filePaths: [String]) {
        allowedFilePaths = filePaths
        revisionCount += 1
    }

    /// Make this message lightweight before deallocation to reduce release overhead.
    mutating func makeLightweight() {
        updateContent("")
        updateReasoningContent("")
        setAllowedPaths([])
    }
}
