import Foundation

/// Who a session's `ask_user` question is addressed to (delegated `ask_user` plan §6.1).
///
/// The parent relationship is the reconciled lookup `AgentModeViewModel` already supplies to
/// `AgentDelegationPolicy` (`mcpDelegationParentLookup` / `mcpDelegationLineage`); this policy
/// never reads lineage itself and never guesses a parent. `.externalController` requires an
/// explicit verification that the current controller is a live non-Agent-Mode MCP connection;
/// a root lookup alone is never treated as external.
///
/// Related:
/// - AgentDelegationPolicy.swift (lineage resolution)
/// - AgentDelegatedQuestionNotice.swift (notice wire contract)
/// - MCPAskUserToolProvider.swift (controller provenance verification; reveal guard unchanged)
enum AgentDelegatedQuestionAudience: Equatable {
    /// Top-level session: unchanged behavior (the existing reveal guard decides attention).
    case user
    /// In-app child with a reconciled, live immediate parent: no reveal, deliver to the parent,
    /// and pause the child's timeout.
    case parentAgent(parentSessionID: UUID)
    /// Session verifiably controlled by a non-Agent-Mode MCP client: unchanged behavior.
    case externalController
    /// Lineage missing/inconsistent, parent gone, or controller unverifiable: the user answers
    /// in the child tab; the normal timeout runs and the child row shows "Needs your answer".
    case userFallback

    /// Whether the child's `ask_user` timeout is paused for this audience (§6.4).
    var pausesTimeout: Bool {
        if case .parentAgent = self { return true }
        return false
    }

    var parentSessionID: UUID? {
        if case let .parentAgent(parentSessionID) = self { return parentSessionID }
        return nil
    }

    struct Inputs: Equatable {
        /// The asking session currently has an MCP control context.
        var isMCPControlled: Bool
        /// Reconciled parent lookup for the asking session's durable identity.
        var parentLookup: AgentDelegationPolicy.ParentLookup
        /// Full reconciled lineage for the asking session's durable identity.
        var lineage: AgentDelegationPolicy.LineageResolution
        /// The immediate parent (when `parentLookup` is `.parent`) has a live session record.
        var parentIsLive: Bool
        /// The current controller connection was verified as a live non-Agent-Mode MCP
        /// connection, and it is still the connection that owns the child's control context.
        var controllerVerifiedNonAgentMode: Bool
    }

    static func resolve(_ inputs: Inputs) -> AgentDelegatedQuestionAudience {
        // A session without an MCP control context is driven by the user in the app, whatever
        // its lineage: unchanged behavior.
        guard inputs.isMCPControlled else { return .user }
        switch inputs.parentLookup {
        case let .parent(parentSessionID):
            guard inputs.lineage.depth != nil, inputs.parentIsLive else { return .userFallback }
            return .parentAgent(parentSessionID: parentSessionID)
        case .root:
            return inputs.controllerVerifiedNonAgentMode ? .externalController : .userFallback
        case .unknown, .inconsistent:
            // A controlled session that cannot prove its controller never guesses a parent.
            return .userFallback
        }
    }
}

/// Controller provenance captured asynchronously when a child asks. Verification binds to the
/// exact controlling connection so a later change of controller invalidates it.
struct AgentDelegatedQuestionControllerProvenance: Equatable {
    /// Connection verified (live, run purpose `.unknown` after rehydration, and no Agent Mode
    /// run mapping) as a non-Agent-Mode MCP client controlling the child.
    let verifiedNonAgentModeConnectionID: UUID?

    static let unverified = AgentDelegatedQuestionControllerProvenance(verifiedNonAgentModeConnectionID: nil)

    func verifies(currentControllerConnectionID: UUID?) -> Bool {
        guard let verifiedNonAgentModeConnectionID, let currentControllerConnectionID else { return false }
        return verifiedNonAgentModeConnectionID == currentControllerConnectionID
    }
}
