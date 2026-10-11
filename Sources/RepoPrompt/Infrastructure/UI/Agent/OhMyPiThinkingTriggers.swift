import Foundation
import RepoPromptAgentCore

enum OhMyPiThinkingSelectionProbeTrigger {
    #if DEBUG
        private static let testingStateLock = NSLock()
        private static var disabledForTesting = false

        static var isDisabledForTesting: Bool {
            get { testingStateLock.withLock { disabledForTesting } }
            set { testingStateLock.withLock { disabledForTesting = newValue } }
        }
    #endif

    static func afterExplicitSelection(
        of model: AIModel,
        workspacePath: String? = nil,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        guard let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: model) else { return }
        resolver.requestAfterExplicitSelection(
            exactModelID: exactModelID,
            workspacePath: workspacePath
        )
    }

    static func afterExplicitSelection(
        agent: AgentProviderKind,
        rawModel: String,
        workspacePath: String? = nil,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        guard agent == .ohMyPi,
              let exactModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: rawModel)
        else { return }
        resolver.requestAfterExplicitSelection(
            exactModelID: exactModelID,
            workspacePath: workspacePath
        )
    }
}

enum OhMyPiThinkingSweepTrigger {
    #if DEBUG
        static var isDisabledForTesting: Bool {
            get { OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting }
            set { OhMyPiThinkingSelectionProbeTrigger.isDisabledForTesting = newValue }
        }
    #endif

    static func onProviderSubmenuOpen(
        wireIDs: [String],
        selectedRawModel: String?,
        workspacePath: String?,
        isLocal: Bool = true,
        resolver: OhMyPiThinkingCapabilityResolver = .shared
    ) {
        #if DEBUG
            guard !isDisabledForTesting else { return }
        #endif
        let targets = OhMyPiThinkingSweepTargets.compute(
            wireIDs: wireIDs,
            selectedRawModel: selectedRawModel,
            recentlyInvalidated: OhMyPiThinkingCapabilityRegistry.shared.recentlyInvalidatedIDs()
        )
        guard !targets.isEmpty else { return }
        Task {
            _ = await resolver.requestSweep(.init(
                wireIDs: targets,
                selectedRawModel: selectedRawModel,
                workspacePath: workspacePath,
                isLocal: isLocal
            ))
        }
    }
}
