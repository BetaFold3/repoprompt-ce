import Foundation

/// Stable identity for one resolved checkout in the grouped Changes panel.
///
/// A checkout path alone is not sufficient: scope, worktree substitution, backend, and represented
/// logical roots all change what the panel may read or mutate. Wrapping the resolver's full
/// ``AgentPanelResolvedCheckout/targetKey`` keeps every group-qualified key on that same safety
/// boundary.
struct AgentChangesGroupID: Equatable, Hashable, Identifiable {
    let targetKey: String

    init(targetKey: String) {
        self.targetKey = targetKey
    }

    init(target: AgentPanelResolvedCheckout) {
        targetKey = target.targetKey
    }

    var id: String {
        targetKey
    }
}

/// One existing section-qualified row identity inside one resolved checkout.
///
/// The row ID already distinguishes staged and unstaged counterparts. Adding the group prevents
/// otherwise-identical rows in two repositories from sharing patch, pending, or search state.
struct AgentChangesRowKey: Equatable, Hashable {
    let groupID: AgentChangesGroupID
    let rowID: String
}

/// One repository-relative path inside one resolved checkout.
///
/// This key is for group-local operations whose identity is a path rather than a section-qualified
/// row, such as pending partial mutations. A path must never be interpreted without its checkout.
struct AgentChangesGroupPathKey: Equatable, Hashable {
    let groupID: AgentChangesGroupID
    let repositoryRelativePath: String
}

/// Expansion and context identity for one file in one resolved checkout.
///
/// Staged and unstaged rows deliberately share this key. They are two views of the same file, so
/// opening either row keeps the current single-checkout behavior of opening both counterparts while
/// the group ID prevents the same relative path in another repository from following along.
struct AgentChangesFileStateKey: Equatable, Hashable {
    let groupID: AgentChangesGroupID
    let repositoryRelativePath: String
}

/// The compare readiness of one Changes group.
///
/// Compare selection remains global to the tab, but base readiness is repository-local. This value
/// lets one group wait for an explicit base while other repositories continue rendering.
enum AgentChangesGroupCompareState: Equatable {
    case workingTree
    case awaitingBase
    case vsBase(base: String)

    init(resolvedCompareMode: AgentChangesCompareMode?) {
        switch resolvedCompareMode {
        case .workingTree:
            self = .workingTree
        case let .vsBase(base):
            self = .vsBase(base: base)
        case nil:
            self = .awaitingBase
        }
    }
}

/// Published state for one resolved checkout in the grouped Changes panel.
///
/// Each group retains its own snapshot, generation, fingerprint, freshness, and base candidates.
/// There is intentionally no aggregate `AgentChangesSnapshot`: a global generation or fingerprint
/// could not truthfully describe independently refreshing repositories.
struct AgentChangesGroupState: Equatable, Identifiable {
    let target: AgentPanelResolvedCheckout
    var resolvedCompareMode: AgentChangesCompareMode?
    var snapshot: AgentChangesSnapshot
    var baseCandidates: [String]
    var lastRefreshedAt: Date?

    var id: AgentChangesGroupID {
        AgentChangesGroupID(target: target)
    }

    var compareState: AgentChangesGroupCompareState {
        AgentChangesGroupCompareState(resolvedCompareMode: resolvedCompareMode)
    }
}
