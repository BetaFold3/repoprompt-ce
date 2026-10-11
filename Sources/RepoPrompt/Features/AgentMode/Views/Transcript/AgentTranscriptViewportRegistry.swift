import RepoPromptAgentCore
import SwiftUI

@MainActor
final class AgentTranscriptViewportRegistry: ObservableObject {
    private var blockFramesByID: [String: AgentTranscriptBlockViewportFrame] = [:]
    private var viewportCandidatesByTargetID: [AgentTranscriptViewportTargetID: AgentTranscriptViewportCandidate] = [:]

    func replaceBlockFrames(_ frames: [AgentTranscriptBlockViewportFrame]) {
        blockFramesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.blockID, $0) })
    }

    func replaceViewportCandidates(_ candidates: [AgentTranscriptViewportCandidate]) {
        viewportCandidatesByTargetID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.targetID, $0) })
    }

    func blockFrame(for blockID: String) -> AgentTranscriptBlockViewportFrame? {
        blockFramesByID[blockID]
    }

    func viewportCandidate(for targetID: AgentTranscriptViewportTargetID) -> AgentTranscriptViewportCandidate? {
        viewportCandidatesByTargetID[targetID]
    }

    var viewportCandidates: [AgentTranscriptViewportCandidate] {
        Array(viewportCandidatesByTargetID.values)
    }

    func clearBlockFrames() {
        blockFramesByID.removeAll()
    }

    func clearViewportCandidates() {
        viewportCandidatesByTargetID.removeAll()
    }

    func clear() {
        clearBlockFrames()
        clearViewportCandidates()
    }
}

enum AgentDetachedViewportTrackingMode: Equatable {
    case off
    case blockOnly
    case targetedRows(Set<String>)

    var shouldTrackCandidates: Bool {
        switch self {
        case .off:
            false
        case .blockOnly, .targetedRows:
            true
        }
    }

    func containsRowTracking(for blockID: String) -> Bool {
        guard case let .targetedRows(blockIDs) = self else { return false }
        return blockIDs.contains(blockID)
    }
}
