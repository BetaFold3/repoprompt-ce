import Foundation
import SwiftUI

/// Decouples "what model was picked" from "where/how that choice is applied".
/// Each destination encapsulates:
/// - How to get the current model raw value
/// - How to apply a new model selection (including any side effects like notifications)
@MainActor
struct ModelDestination: Identifiable {
    let id: String
    private let getter: @MainActor () -> String
    private let applier: @MainActor (String) -> Void
    private let thinkingGetter: (@MainActor () -> OhMyPiThinkingSelections)?
    private let thinkingApplier: (@MainActor (OhMyPiThinkingSelections) -> Void)?

    init(
        id: String,
        getter: @escaping @MainActor () -> String,
        applier: @escaping @MainActor (String) -> Void,
        thinkingGetter: (@MainActor () -> OhMyPiThinkingSelections)? = nil,
        thinkingApplier: (@MainActor (OhMyPiThinkingSelections) -> Void)? = nil
    ) {
        self.id = id
        self.getter = getter
        self.applier = applier
        self.thinkingGetter = thinkingGetter
        self.thinkingApplier = thinkingApplier
    }

    /// The current model raw value for this destination
    var currentRawValue: String {
        getter()
    }

    /// Apply a new model selection to this destination
    func apply(_ rawValue: String) {
        applier(rawValue)
    }

    var hasThinkingAccessory: Bool {
        thinkingGetter != nil && thinkingApplier != nil
    }

    var currentThinkingSelections: OhMyPiThinkingSelections? {
        thinkingGetter?()
    }

    func applyThinkingSelections(_ selections: OhMyPiThinkingSelections) {
        thinkingApplier?(selections)
    }

    func thinkingChoice(for exactWireModelID: String) -> OhMyPiThinkingSelections.ThinkingChoice? {
        thinkingGetter?()[exactWireModelID]
    }

    func applyThinkingValue(
        _ value: String?,
        for exactWireModelID: String,
        updatedAt: Date = Date()
    ) {
        guard var selections = thinkingGetter?(), let thinkingApplier else { return }
        selections.setValue(value, for: exactWireModelID, updatedAt: updatedAt)
        thinkingApplier(selections)
    }
}

// MARK: - Binding-backed Destination

extension ModelDestination {
    /// Creates a destination backed by a simple binding (no side effects)
    static func binding(_ binding: Binding<String>, id: String) -> ModelDestination {
        ModelDestination(
            id: id,
            getter: { binding.wrappedValue },
            applier: { binding.wrappedValue = $0 }
        )
    }

    static func binding(
        _ binding: Binding<String>,
        thinkingSelections: Binding<OhMyPiThinkingSelections>,
        id: String
    ) -> ModelDestination {
        ModelDestination(
            id: id,
            getter: { binding.wrappedValue },
            applier: { binding.wrappedValue = $0 },
            thinkingGetter: { thinkingSelections.wrappedValue },
            thinkingApplier: { thinkingSelections.wrappedValue = $0 }
        )
    }
}

// MARK: - Agent Tab Destination

extension ModelDestination {
    static func agentTab(_ session: AgentModeViewModel.TabSession) -> ModelDestination {
        ModelDestination(
            id: "agentTab.\(session.tabID.uuidString)",
            getter: { session.selectedModelRaw },
            applier: { session.selectedModelRaw = $0 },
            thinkingGetter: { session.ohMyPiThinkingSelections },
            thinkingApplier: { session.ohMyPiThinkingSelections = $0 }
        )
    }
}

// MARK: - PromptViewModel-backed Destinations

extension ModelDestination {
    /// Destination for the main chat model (preferredModel).
    /// PromptViewModel enforces Oracle/Built-in Chat sync when the global toggle is enabled.
    static func chatModel(promptVM: PromptViewModel) -> ModelDestination {
        ModelDestination(
            id: "chatModel",
            getter: { promptVM.preferredModel },
            applier: { promptVM.preferredModel = $0 },
            thinkingGetter: { promptVM.preferredModelOhMyPiThinkingSelections },
            thinkingApplier: { promptVM.preferredModelOhMyPiThinkingSelections = $0 }
        )
    }

    /// Destination for the context builder model
    static func contextBuilderModel(promptVM: PromptViewModel) -> ModelDestination {
        ModelDestination(
            id: "contextBuilderModel",
            getter: { promptVM.contextBuilderModelName },
            applier: { promptVM.contextBuilderModelName = $0 },
            thinkingGetter: { promptVM.contextBuilderOhMyPiThinkingSelections },
            thinkingApplier: { promptVM.contextBuilderOhMyPiThinkingSelections = $0 }
        )
    }

    /// Destination for the MCP default model (planningModel).
    /// PromptViewModel enforces Oracle/Built-in Chat sync when the global toggle is enabled.
    /// This model is used for all MCP chat connections: ask_oracle/oracle_send and context_builder plan/review/question.
    /// - Parameter postNotification: Whether to post `.recommendationsShouldRefresh` after applying (default: true)
    ///   Note: We use `.recommendationsShouldRefresh` (not `.recommendationsDidApply`) because a user manually
    ///   picking a model is semantically different from the recommendation engine applying changes.
    ///   This triggers the wizard to recompute without side effects like discarding window overlays.
    static func planningModel(promptVM: PromptViewModel, postNotification: Bool = true) -> ModelDestination {
        ModelDestination(
            id: "planningModel",
            getter: { promptVM.planningModelName },
            applier: { rawValue in
                promptVM.planningModelName = rawValue

                if postNotification {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .recommendationsShouldRefresh,
                            object: nil
                        )
                    }
                }
            },
            thinkingGetter: { promptVM.planningModelOhMyPiThinkingSelections },
            thinkingApplier: { promptVM.planningModelOhMyPiThinkingSelections = $0 }
        )
    }
}
