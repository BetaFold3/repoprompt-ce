import AppKit
import Combine
import MarkdownUI
import SwiftUI

typealias AgentConversationBranchPickerTarget = AgentModeViewModel.ConversationBranchPickerTarget

struct AgentConversationTreePickerTurn: Equatable, Identifiable {
    struct ID: Hashable {
        let sessionID: UUID
        let turnID: UUID
    }

    let id: ID
    let ordinal: Int
    let prompt: String
    let conclusion: String?
    let availability: AgentSessionBranchAvailability
    let safetySummary: AgentBranchSafetySummary?
    let isCompleted: Bool

    var availabilityIndicator: String {
        if case .available = availability { return "●" }
        return "○"
    }

    var snippet: String {
        let normalized = prompt
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(160))
    }
}

struct AgentConversationTreePickerPath: Equatable, Identifiable {
    enum Evidence: Equatable {
        case available
        case deleted
        case sourceUnavailable
        case deletedSource
        case unreadable(String)

        var placeholderTitle: String? {
            switch self {
            case .sourceUnavailable: "Source path unavailable"
            case .deletedSource: "Deleted source path"
            case .available, .deleted, .unreadable: nil
            }
        }
    }

    let id: UUID
    let name: String
    let savedAt: Date
    let sourceSessionID: UUID?
    let sourceTurnID: UUID?
    let sourceTurnOrdinal: Int?
    let isActive: Bool
    let isOpenElsewhere: Bool
    let evidence: Evidence
    var turns: [AgentConversationTreePickerTurn]?
}

struct AgentConversationTreeNode: Equatable, Identifiable {
    enum ID: Hashable {
        case path(UUID)
        case turn(AgentConversationTreePickerTurn.ID)
        case missingTurn(sessionID: UUID, ordinal: Int)
        case sourcePlaceholder(sessionID: UUID)
    }

    enum Kind: Equatable {
        case path(AgentConversationTreePickerPath)
        case turn(AgentConversationTreePickerTurn, pathID: UUID)
        case missingTurn(pathID: UUID, ordinal: Int)
        case sourcePlaceholder(title: String)
    }

    let id: ID
    var kind: Kind
    var children: [AgentConversationTreeNode]
}

enum AgentConversationTreeTopology {
    static func makeNodes(paths: [AgentConversationTreePickerPath]) -> [AgentConversationTreeNode] {
        guard !paths.isEmpty else { return [] }
        let pathByID = Dictionary(uniqueKeysWithValues: paths.map { ($0.id, $0) })
        let childPaths = Dictionary(grouping: paths.filter { $0.sourceSessionID != nil }) {
            $0.sourceSessionID!
        }
        let roots = paths.filter {
            $0.sourceSessionID == nil || pathByID[$0.sourceSessionID!] == nil
        }.sorted(by: pathOrder)

        func makePath(_ path: AgentConversationTreePickerPath) -> AgentConversationTreeNode {
            let turns = path.turns ?? []
            var turnNodes = turns.map { turn in
                AgentConversationTreeNode(
                    id: .turn(turn.id),
                    kind: .turn(turn, pathID: path.id),
                    children: []
                )
            }
            for child in (childPaths[path.id] ?? []).sorted(by: pathOrder) {
                var pathNode = makePath(child)
                if child.evidence.placeholderTitle == nil {
                    coalesceInheritedPrefix(
                        in: &pathNode,
                        child: child,
                        parent: path,
                        parentTurnNodes: &turnNodes
                    )
                } else {
                    markPathActionable(&pathNode)
                }
                let childNode = if let title = child.evidence.placeholderTitle {
                    AgentConversationTreeNode(
                        id: .sourcePlaceholder(sessionID: child.id),
                        kind: .sourcePlaceholder(title: title),
                        children: [pathNode]
                    )
                } else {
                    pathNode
                }
                guard let ordinal = child.sourceTurnOrdinal else {
                    turnNodes.append(childNode)
                    continue
                }
                if let index = turnNodes.firstIndex(where: { node in
                    guard case let .turn(turn, _) = node.kind else { return false }
                    return turn.ordinal == ordinal
                }) {
                    turnNodes[index].children.append(childNode)
                } else {
                    turnNodes.append(AgentConversationTreeNode(
                        id: .missingTurn(sessionID: path.id, ordinal: ordinal),
                        kind: .missingTurn(pathID: path.id, ordinal: ordinal),
                        children: [childNode]
                    ))
                }
            }

            return AgentConversationTreeNode(
                id: .path(path.id),
                kind: .path(path),
                children: turnNodes
            )
        }

        return roots.map { path in
            var node = makePath(path)
            guard let title = path.evidence.placeholderTitle else { return node }
            markPathActionable(&node)
            let child: AgentConversationTreeNode
            if let ordinal = path.sourceTurnOrdinal {
                let sourceID = path.sourceSessionID ?? path.id
                child = AgentConversationTreeNode(
                    id: .missingTurn(sessionID: sourceID, ordinal: ordinal),
                    kind: .missingTurn(pathID: sourceID, ordinal: ordinal),
                    children: [node]
                )
            } else {
                child = node
            }
            return AgentConversationTreeNode(
                id: .sourcePlaceholder(sessionID: path.id),
                kind: .sourcePlaceholder(title: title),
                children: [child]
            )
        }
    }

    private static func markPathActionable(_ node: inout AgentConversationTreeNode) {
        guard case let .path(path) = node.kind else { return }
        node.kind = .path(AgentConversationTreePickerPath(
            id: path.id,
            name: path.name,
            savedAt: path.savedAt,
            sourceSessionID: path.sourceSessionID,
            sourceTurnID: path.sourceTurnID,
            sourceTurnOrdinal: path.sourceTurnOrdinal,
            isActive: path.isActive,
            isOpenElsewhere: path.isOpenElsewhere,
            evidence: .available,
            turns: path.turns
        ))
    }

    private static func coalesceInheritedPrefix(
        in childNode: inout AgentConversationTreeNode,
        child: AgentConversationTreePickerPath,
        parent: AgentConversationTreePickerPath,
        parentTurnNodes: inout [AgentConversationTreeNode]
    ) {
        guard let sourceOrdinal = child.sourceTurnOrdinal,
              let childTurns = child.turns,
              let parentTurns = parent.turns
        else { return }
        let inherited = Array(childTurns.prefix(sourceOrdinal))
        let parentPrefix = Array(parentTurns.prefix(sourceOrdinal))
        guard inherited.map(\.id.turnID) == parentPrefix.map(\.id.turnID) else { return }

        let inheritedIDs = Set(inherited.map(\.id))
        var retainedChildren: [AgentConversationTreeNode] = []
        for node in childNode.children {
            guard case let .turn(turn, _) = node.kind, inheritedIDs.contains(turn.id) else {
                retainedChildren.append(node)
                continue
            }
            guard let parentIndex = parentTurnNodes.firstIndex(where: {
                guard case let .turn(parentTurn, _) = $0.kind else { return false }
                return parentTurn.id.turnID == turn.id.turnID
            }) else { continue }
            parentTurnNodes[parentIndex].children.append(contentsOf: node.children)
        }
        childNode.children = retainedChildren
    }

    private static func pathOrder(
        _ lhs: AgentConversationTreePickerPath,
        _ rhs: AgentConversationTreePickerPath
    ) -> Bool {
        switch (lhs.sourceTurnOrdinal, rhs.sourceTurnOrdinal) {
        case let (l?, r?) where l != r: return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            if lhs.savedAt != rhs.savedAt { return lhs.savedAt < rhs.savedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

@MainActor
final class AgentConversationTreePickerModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum PathLoadState: Equatable {
        case notLoaded
        case loading
        case loaded
        case failed(String)
    }

    enum Operation: Equatable {
        case idle
        case branching
        case switching
        case preCommitFailed(String)
        case nativeIndeterminate(String)
        case childSavedNotOpened(sessionID: UUID)
    }

    enum Key {
        case up
        case down
        case right
        case left
        case enter
        case escape
        case tab
    }

    enum KeyResult: Equatable {
        case handled
        case submit
        case dismiss
        case focusTraversal
        case ignored
    }

    enum PrimaryAction: Equatable {
        case branch(title: String)
        case switchPath
        case currentPath
        case disabled(String)
    }

    typealias PathLoader = @MainActor (UUID) async throws -> AgentConversationTreePickerPath
    typealias ActiveTurnRefresher = @MainActor (UUID) -> AgentConversationTreePickerTurn?
    typealias BranchAction = @MainActor (AgentConversationTreePickerTurn) async throws -> Void
    typealias SwitchAction = @MainActor (UUID) async throws -> Void
    typealias SourceValidator = @MainActor () -> Bool

    @Published private(set) var phase: Phase
    @Published private(set) var paths: [AgentConversationTreePickerPath]
    @Published var selectedID: AgentConversationTreeNode.ID?
    @Published var expandedIDs: Set<AgentConversationTreeNode.ID>
    @Published private(set) var pathLoadStates: [UUID: PathLoadState]
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var staleSelection = false

    private let loadPath: PathLoader
    private let refreshActiveTurn: ActiveTurnRefresher?
    private let performBranch: BranchAction
    private let performSwitch: SwitchAction
    private let performRecoverySwitch: SwitchAction
    private let sourceIsValid: SourceValidator
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var loadGeneration: [UUID: UInt64] = [:]
    private var inactiveCacheOrder: [UUID] = []
    private var submissionLatched = false

    init(
        phase: Phase,
        paths: [AgentConversationTreePickerPath],
        initialSelection: AgentConversationTreeNode.ID?,
        refreshActiveTurn: ActiveTurnRefresher? = nil,
        loadPath: @escaping PathLoader,
        performBranch: @escaping BranchAction,
        performSwitch: @escaping SwitchAction,
        performRecoverySwitch: SwitchAction? = nil,
        sourceIsValid: @escaping SourceValidator = { true }
    ) {
        self.phase = phase
        self.paths = paths
        selectedID = initialSelection
        var initialExpandedIDs: Set<AgentConversationTreeNode.ID> = Set(
            paths.filter(\.isActive).map { .path($0.id) }
        )
        var descendant = paths.first(where: \.isActive)
        while let child = descendant,
              let parentID = child.sourceSessionID,
              let parent = paths.first(where: { $0.id == parentID })
        {
            initialExpandedIDs.insert(.path(parentID))
            if let sourceTurnID = child.sourceTurnID {
                initialExpandedIDs.insert(.turn(.init(
                    sessionID: parentID,
                    turnID: sourceTurnID
                )))
            }
            descendant = parent
        }
        expandedIDs = initialExpandedIDs
        pathLoadStates = Dictionary(uniqueKeysWithValues: paths.map {
            ($0.id, $0.turns == nil ? .notLoaded : .loaded)
        })
        self.loadPath = loadPath
        self.refreshActiveTurn = refreshActiveTurn
        self.performBranch = performBranch
        self.performSwitch = performSwitch
        self.performRecoverySwitch = performRecoverySwitch ?? { sessionID in
            guard sourceIsValid() else { throw AgentBranchOperationError.staleOperation }
            try await performSwitch(sessionID)
        }
        self.sourceIsValid = sourceIsValid
        if initialSelection == nil {
            selectedID = latestCompletedActiveTurnID
        }
        normalizeSelection()
    }

    deinit {
        for task in loadTasks.values {
            task.cancel()
        }
    }

    var nodes: [AgentConversationTreeNode] {
        AgentConversationTreeTopology.makeNodes(paths: paths)
    }

    var visibleNodes: [AgentConversationTreeNode] {
        func append(_ node: AgentConversationTreeNode, to result: inout [AgentConversationTreeNode]) {
            result.append(node)
            guard expandedIDs.contains(node.id) else { return }
            for child in node.children {
                append(child, to: &result)
            }
        }
        var result: [AgentConversationTreeNode] = []
        for node in nodes {
            append(node, to: &result)
        }
        return result
    }

    var selectedNode: AgentConversationTreeNode? {
        guard let selectedID else { return nil }
        return findNode(selectedID, in: nodes)
    }

    var selectedTurn: AgentConversationTreePickerTurn? {
        guard case let .turn(turn, _)? = selectedNode?.kind else { return nil }
        return turn
    }

    var emptyStateText: String? {
        guard paths.first(where: \.isActive)?.turns?.contains(where: \.isCompleted) != true else {
            return nil
        }
        return "Complete a turn to create a branch."
    }

    var resolvedActionableTurn: AgentConversationTreePickerTurn? {
        guard let selectedTurn else { return nil }
        if paths.first(where: { $0.id == selectedTurn.id.sessionID })?.isActive == true {
            return selectedTurn
        }
        return paths.first(where: \.isActive)?.turns?.first {
            $0.id.turnID == selectedTurn.id.turnID
        }
    }

    var primaryAction: PrimaryAction {
        guard let node = selectedNode else { return .disabled("Select a conversation turn.") }
        switch node.kind {
        case let .path(path):
            if path.isActive { return .currentPath }
            return switchAction(for: path)
        case let .turn(_, pathID):
            guard let path = paths.first(where: { $0.id == pathID }) else {
                return .disabled("The requested branch is no longer available.")
            }
            guard let resolvedActionableTurn else {
                return path.isActive ? .disabled("No completed turns yet.") : switchAction(for: path)
            }
            guard resolvedActionableTurn.isCompleted else { return .disabled("No completed turns yet.") }
            guard case .available = resolvedActionableTurn.availability else {
                if case let .unavailable(reason) = resolvedActionableTurn.availability {
                    return .disabled(AgentReplyBranchPresentation.helpText(for: reason))
                }
                return .disabled("This turn is not available for native branching.")
            }
            guard let summary = resolvedActionableTurn.safetySummary, summary.hasResolvedTurn else {
                return .disabled("The conversation changed. Review the updated branch details.")
            }
            return .branch(title: summary.branchButtonTitle)
        case .missingTurn:
            return .disabled("The source turn is no longer retained.")
        case let .sourcePlaceholder(title):
            return .disabled(title)
        }
    }

    var selectedPreview: (prompt: String, conclusion: String?)? {
        selectedTurn.map { ($0.prompt, $0.conclusion) }
    }

    var displayedSafetySummary: AgentBranchSafetySummary? {
        resolvedActionableTurn?.safetySummary
    }

    var actionDisabledReason: String? {
        guard case let .disabled(reason) = primaryAction else { return nil }
        return reason
    }

    var contextualHelpText: String? {
        guard let turn = selectedTurn,
              resolvedActionableTurn?.id.sessionID != paths.first(where: \.isActive)?.id,
              paths.first(where: { $0.id == turn.id.sessionID })?.isActive == false
        else { return nil }
        return "Open this path before creating a branch."
    }

    static func shouldPublishPathLoad(
        sessionID: UUID,
        expectedSavedAt: Date,
        generation: UInt64,
        currentGeneration: UInt64?,
        currentPath: AgentConversationTreePickerPath?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && generation == currentGeneration
            && currentPath?.id == sessionID
            && currentPath?.savedAt == expectedSavedAt
    }

    func publishResolvedTree(
        phase: Phase,
        paths: [AgentConversationTreePickerPath]
    ) {
        cancelLoads()
        self.phase = phase
        self.paths = paths
        pathLoadStates = Dictionary(uniqueKeysWithValues: paths.map {
            ($0.id, $0.turns == nil ? .notLoaded : .loaded)
        })
        inactiveCacheOrder = inactiveCacheOrder.filter { id in paths.contains { $0.id == id } }
        if selectedID == nil {
            selectedID = latestCompletedActiveTurnID
        }
        reconcileTopology()
    }

    func cancelLoads() {
        loadGeneration = loadGeneration.mapValues { $0 &+ 1 }
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll()
        for (id, state) in pathLoadStates where state == .loading {
            pathLoadStates[id] = .notLoaded
        }
    }

    func markSelectionStale() {
        staleSelection = true
        submissionLatched = false
    }

    func select(_ id: AgentConversationTreeNode.ID) {
        guard operation == .idle || isFailure(operation) else { return }
        selectedID = id
        normalizeSelection()
        staleSelection = false
        submissionLatched = false
        if case .preCommitFailed = operation {
            operation = .idle
        }
        if case let .path(pathID) = id {
            requestPathLoad(pathID)
        } else if case let .turn(turnID) = id {
            requestPathLoad(turnID.sessionID)
        }
    }

    func toggleExpanded(_ id: AgentConversationTreeNode.ID) {
        setExpanded(id, expanded: !expandedIDs.contains(id))
    }

    func setExpanded(_ id: AgentConversationTreeNode.ID, expanded: Bool) {
        if expanded {
            expandedIDs.insert(id)
            if case let .path(pathID) = id { requestPathLoad(pathID) }
        } else {
            expandedIDs.remove(id)
        }
    }

    func reduce(key: Key, isRepeat: Bool = false) -> KeyResult {
        if key == .tab { return .focusTraversal }
        if key == .escape {
            switch operation {
            case .idle, .preCommitFailed, .nativeIndeterminate, .childSavedNotOpened: return .dismiss
            case .branching, .switching: return .ignored
            }
        }
        guard operation == .idle || isFailure(operation) else { return .ignored }
        let rows = visibleNodes
        let selectedIndex = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        switch key {
        case .up:
            guard !rows.isEmpty else { return .handled }
            select(rows[max(0, (selectedIndex ?? 1) - 1)].id)
        case .down:
            guard !rows.isEmpty else { return .handled }
            select(rows[min(rows.count - 1, (selectedIndex ?? -1) + 1)].id)
        case .right:
            guard let selectedNode else { return .handled }
            if case let .path(path) = selectedNode.kind, path.turns == nil {
                setExpanded(selectedNode.id, expanded: true)
            } else if !selectedNode.children.isEmpty, !expandedIDs.contains(selectedNode.id) {
                setExpanded(selectedNode.id, expanded: true)
            } else if let first = selectedNode.children.first {
                select(first.id)
            }
        case .left:
            guard let selectedNode else { return .handled }
            if expandedIDs.contains(selectedNode.id) {
                setExpanded(selectedNode.id, expanded: false)
            } else if let parent = parentID(of: selectedNode.id, in: nodes) {
                select(parent)
            }
        case .enter:
            guard !isRepeat, !submissionLatched else { return .ignored }
            guard !staleSelection else { return .handled }
            switch primaryAction {
            case .branch, .switchPath:
                submissionLatched = true
                return .submit
            case .currentPath, .disabled:
                return .handled
            }
        case .escape, .tab:
            break
        }
        return .handled
    }

    func submit() async -> Bool {
        guard !staleSelection,
              operation == .idle || isFailure(operation),
              sourceIsValid()
        else {
            submissionLatched = false
            if operation == .idle {
                staleSelection = true
                operation = .preCommitFailed(AgentBranchOperationError.staleOperation.localizedDescription)
            }
            return false
        }

        let action = primaryAction
        switch action {
        case .branch:
            guard var turn = resolvedActionableTurn else {
                submissionLatched = false
                return false
            }
            operation = .branching
            if let refreshed = refreshActiveTurn?(turn.id.turnID) {
                if refreshed.safetySummary != turn.safetySummary {
                    replaceActiveTurn(refreshed)
                    staleSelection = true
                    submissionLatched = false
                    operation = .preCommitFailed(AgentBranchSafetySummary.staleText)
                    return false
                }
                turn = refreshed
            }
            guard sourceIsValid() else {
                staleSelection = true
                submissionLatched = false
                operation = .preCommitFailed(AgentBranchOperationError.staleOperation.localizedDescription)
                return false
            }
            do {
                try await performBranch(turn)
                operation = .idle
                submissionLatched = false
                return true
            } catch let error as AgentBranchOperationError {
                submissionLatched = false
                switch error {
                case .staleConfirmation, .staleOperation:
                    staleSelection = true
                    operation = .preCommitFailed(error.localizedDescription)
                case .nativeIndeterminate:
                    operation = .nativeIndeterminate(error.localizedDescription)
                case let .childSavedButNotOpened(sessionID):
                    operation = .childSavedNotOpened(sessionID: sessionID)
                default:
                    operation = .preCommitFailed(error.localizedDescription)
                }
                return false
            } catch {
                submissionLatched = false
                operation = .preCommitFailed(error.localizedDescription)
                return false
            }
        case .switchPath:
            let path: AgentConversationTreePickerPath? = switch selectedNode?.kind {
            case let .path(selectedPath):
                selectedPath
            case let .turn(_, pathID), let .missingTurn(pathID, _):
                paths.first(where: { $0.id == pathID })
            case .sourcePlaceholder, nil:
                nil
            }
            guard let path else {
                submissionLatched = false
                return false
            }
            operation = .switching
            do {
                try await performSwitch(path.id)
                operation = .idle
                submissionLatched = false
                return true
            } catch {
                submissionLatched = false
                operation = .preCommitFailed(error.localizedDescription)
                return false
            }
        case .currentPath, .disabled:
            submissionLatched = false
            return false
        }
    }

    func requestPathLoad(_ sessionID: UUID, force: Bool = false) {
        guard sourceIsValid(),
              let index = paths.firstIndex(where: { $0.id == sessionID }),
              !paths[index].isActive,
              force || paths[index].turns == nil,
              loadTasks[sessionID] == nil
        else { return }

        let generation = (loadGeneration[sessionID] ?? 0) &+ 1
        loadGeneration[sessionID] = generation
        pathLoadStates[sessionID] = .loading
        let expectedSavedAt = paths[index].savedAt
        loadTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadPath(sessionID)
                let currentIndex = paths.firstIndex(where: { $0.id == sessionID })
                let currentPath = currentIndex.map { self.paths[$0] }
                guard Self.shouldPublishPathLoad(
                    sessionID: sessionID,
                    expectedSavedAt: expectedSavedAt,
                    generation: generation,
                    currentGeneration: loadGeneration[sessionID],
                    currentPath: currentPath,
                    isCancelled: Task.isCancelled
                ), let currentIndex
                else {
                    clearLoadTaskIfOwned(sessionID, generation: generation)
                    return
                }
                paths[currentIndex] = loaded
                pathLoadStates[sessionID] = .loaded
                touchCache(sessionID)
                reconcileTopology()
            } catch {
                guard !Task.isCancelled, loadGeneration[sessionID] == generation else {
                    clearLoadTaskIfOwned(sessionID, generation: generation)
                    return
                }
                pathLoadStates[sessionID] = .failed(error.localizedDescription)
            }
            clearLoadTaskIfOwned(sessionID, generation: generation)
        }
    }

    var selectedPathID: UUID? {
        switch selectedNode?.kind {
        case let .path(path): path.id
        case let .turn(_, pathID), let .missingTurn(pathID, _): pathID
        case .sourcePlaceholder, nil: nil
        }
    }

    var selectedPathLoadState: PathLoadState? {
        selectedPathID.flatMap { pathLoadStates[$0] }
    }

    func refreshFailedPath(_ sessionID: UUID) {
        guard sourceIsValid(), case .failed = pathLoadStates[sessionID] else { return }
        requestPathLoad(sessionID, force: true)
    }

    func openCreatedBranch() async -> Bool {
        guard case let .childSavedNotOpened(sessionID) = operation else { return false }
        operation = .switching
        do {
            try await performRecoverySwitch(sessionID)
            operation = .idle
            return true
        } catch {
            operation = .childSavedNotOpened(sessionID: sessionID)
            return false
        }
    }

    private func clearLoadTaskIfOwned(_ sessionID: UUID, generation: UInt64) {
        guard loadGeneration[sessionID] == generation else { return }
        loadTasks[sessionID] = nil
    }

    private func replaceActiveTurn(_ replacement: AgentConversationTreePickerTurn) {
        guard let pathIndex = paths.firstIndex(where: \.isActive),
              let turnIndex = paths[pathIndex].turns?.firstIndex(where: {
                  $0.id.turnID == replacement.id.turnID
              })
        else { return }
        paths[pathIndex].turns?[turnIndex] = replacement
    }

    private var latestCompletedActiveTurnID: AgentConversationTreeNode.ID? {
        paths.first(where: \.isActive)?.turns?
            .last(where: \.isCompleted)
            .map { .turn($0.id) }
    }

    private func switchAction(for path: AgentConversationTreePickerPath) -> PrimaryAction {
        switch path.evidence {
        case .deleted:
            return .disabled("The original conversation was deleted.")
        case .sourceUnavailable, .deletedSource:
            if path.isOpenElsewhere {
                return .disabled("This branch is open in another tab.")
            }
            return .switchPath
        case let .unreadable(reason):
            return .disabled(reason)
        case .available:
            if path.isOpenElsewhere {
                return .disabled("This branch is open in another tab.")
            }
            return .switchPath
        }
    }

    private func touchCache(_ sessionID: UUID) {
        inactiveCacheOrder.removeAll { $0 == sessionID }
        inactiveCacheOrder.append(sessionID)
        while inactiveCacheOrder.count > 2 {
            let evicted = inactiveCacheOrder.removeFirst()
            guard let index = paths.firstIndex(where: { $0.id == evicted }) else { continue }
            paths[index].turns = nil
            pathLoadStates[evicted] = .notLoaded
            reconcileTopology()
        }
    }

    private func reconcileTopology() {
        normalizeSelection()
        let currentNodes = nodes
        let validIDs = allNodeIDs(in: currentNodes)
        expandedIDs = expandedIDs.intersection(validIDs)
        if let selectedID {
            var ancestor = parentID(of: selectedID, in: currentNodes)
            while let id = ancestor {
                expandedIDs.insert(id)
                ancestor = parentID(of: id, in: currentNodes)
            }
        }
        var descendant = paths.first(where: \.isActive)
        while let child = descendant,
              let parentID = child.sourceSessionID,
              let parent = paths.first(where: { $0.id == parentID })
        {
            expandedIDs.insert(.path(parentID))
            if let sourceTurnID = child.sourceTurnID {
                let requested = AgentConversationTreeNode.ID.turn(.init(
                    sessionID: parentID,
                    turnID: sourceTurnID
                ))
                if let resolved = findTurnNodeID(turnID: sourceTurnID, in: currentNodes) {
                    expandedIDs.insert(resolved)
                } else {
                    expandedIDs.insert(requested)
                }
            }
            descendant = parent
        }
    }

    private func allNodeIDs(in nodes: [AgentConversationTreeNode]) -> Set<AgentConversationTreeNode.ID> {
        var result: Set<AgentConversationTreeNode.ID> = []
        for node in nodes {
            result.insert(node.id)
            result.formUnion(allNodeIDs(in: node.children))
        }
        return result
    }

    private func normalizeSelection() {
        guard let selectedID, findNode(selectedID, in: nodes) == nil else { return }
        guard case let .turn(requestedTurnID) = selectedID,
              let matchingID = findTurnNodeID(
                  turnID: requestedTurnID.turnID,
                  in: nodes
              )
        else { return }
        self.selectedID = matchingID
    }

    private func findTurnNodeID(
        turnID: UUID,
        in nodes: [AgentConversationTreeNode]
    ) -> AgentConversationTreeNode.ID? {
        for node in nodes {
            if case let .turn(turn, _) = node.kind, turn.id.turnID == turnID {
                return node.id
            }
            if let child = findTurnNodeID(turnID: turnID, in: node.children) {
                return child
            }
        }
        return nil
    }

    private func findNode(
        _ id: AgentConversationTreeNode.ID,
        in nodes: [AgentConversationTreeNode]
    ) -> AgentConversationTreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if let child = findNode(id, in: node.children) { return child }
        }
        return nil
    }

    private func parentID(
        of id: AgentConversationTreeNode.ID,
        in nodes: [AgentConversationTreeNode]
    ) -> AgentConversationTreeNode.ID? {
        for node in nodes {
            if node.children.contains(where: { $0.id == id }) { return node.id }
            if let result = parentID(of: id, in: node.children) { return result }
        }
        return nil
    }

    private func isFailure(_ operation: Operation) -> Bool {
        switch operation {
        case .preCommitFailed: true
        default: false
        }
    }
}

struct AgentBranchSelection: Equatable {
    let turnID: UUID
    let tabID: UUID
    let safetySummary: AgentBranchSafetySummary
    let pin: AgentModeViewModel.ReplyBranchConfirmationPin
}

enum AgentConversationTreeInitialSelection: Equatable {
    case latestCompletedTurn
    case turn(UUID)
}

struct AgentConversationTreePresentationRequest: Identifiable {
    let id: UUID
    let tabID: UUID
    let initialSelection: AgentConversationTreeInitialSelection
    let model: AgentConversationTreePickerModel
    let target: AgentConversationBranchPickerTarget?

    init(
        id: UUID,
        tabID: UUID,
        initialSelection: AgentConversationTreeInitialSelection,
        model: AgentConversationTreePickerModel,
        target: AgentConversationBranchPickerTarget? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.initialSelection = initialSelection
        self.model = model
        self.target = target
    }
}

@MainActor
final class AgentConversationTreePickerState: ObservableObject {
    @Published private(set) var request: AgentConversationTreePresentationRequest?
    @Published private(set) var focusGeneration: UInt64 = 0

    func present(_ request: AgentConversationTreePresentationRequest) {
        if self.request != nil { return }
        self.request = request
    }

    func focusOrPresent(_ request: AgentConversationTreePresentationRequest) {
        guard self.request == nil else {
            focusGeneration &+= 1
            return
        }
        self.request = request
    }

    @discardableResult
    func dismiss() -> UUID? {
        guard let current = request else { return nil }
        switch current.model.operation {
        case .branching, .switching:
            return nil
        case .idle, .preCommitFailed, .nativeIndeterminate, .childSavedNotOpened:
            current.model.cancelLoads()
            request = nil
            return current.id
        }
    }
}

@MainActor
struct AgentConversationTreePicker: View {
    @ObservedObject var state: AgentConversationTreePickerState
    var didDismiss: (UUID) -> Void = { _ in }

    var body: some View {
        if let request = state.request {
            AgentConversationTreePickerContent(
                model: request.model,
                focusGeneration: state.focusGeneration
            ) {
                if let requestID = state.dismiss() {
                    didDismiss(requestID)
                }
            }
        }
    }
}

private struct AgentConversationTreePickerContent: View {
    @ObservedObject var model: AgentConversationTreePickerModel
    let focusGeneration: UInt64
    let dismiss: () -> Void
    @State private var showsAllChangedPaths = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation Branches").font(.headline)
                Spacer()
                Button("Done", action: dismiss)
                    .disabled(isSubmitting)
            }
            .padding(16)

            Divider()

            switch model.phase {
            case .loading:
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading conversation tree…").foregroundStyle(.secondary)
                    }
                    outlineAndPreview
                }
            case let .failed(message):
                VStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary)
                    outlineAndPreview
                }
            case .ready:
                outlineAndPreview
            }

            Divider()
            safetyFooter
        }
        .frame(idealWidth: 840, idealHeight: 560)
        .frame(minWidth: 720, minHeight: 480)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var outlineAndPreview: some View {
        HSplitView {
            AgentConversationTreeOutlineView(
                model: model,
                focusGeneration: focusGeneration
            ) { result in
                handleKeyResult(result)
            }
            .frame(minWidth: 280, idealWidth: 360)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let preview = model.selectedPreview {
                        Text("Prompt").font(.headline)
                        Markdown(preview.prompt)
                        if let conclusion = preview.conclusion, !conclusion.isEmpty {
                            Divider()
                            Text("Final reply").font(.headline)
                            Markdown(conclusion)
                        }
                    } else if let emptyStateText = model.emptyStateText {
                        Text(emptyStateText)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Select a turn to preview it.")
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var safetyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.staleSelection {
                Text(AgentBranchSafetySummary.staleText).foregroundStyle(.orange)
            }
            if let contextualHelpText = model.contextualHelpText {
                Text(contextualHelpText).foregroundStyle(.secondary)
            }
            if let summary = model.displayedSafetySummary {
                Text(summary.turnSummaryText).font(.subheadline.weight(.semibold))
                Text(summary.impactText(expanded: showsAllChangedPaths))
                if summary.hasCollapsedChangedPaths {
                    Button(showsAllChangedPaths ? "Show less" : "Show all") {
                        showsAllChangedPaths.toggle()
                    }
                    .buttonStyle(.link)
                }
                Text(AgentBranchSafetySummary.rollbackDisclosure).foregroundStyle(.secondary)
                if let oracle = summary.oracleDisclosureText {
                    Text(oracle).foregroundStyle(.secondary)
                }
            }
            if let reason = model.actionDisabledReason {
                Text(reason).foregroundStyle(.secondary)
            }
            switch model.operation {
            case let .preCommitFailed(message):
                Text(message).foregroundStyle(.red)
            case let .nativeIndeterminate(message):
                Text(message).foregroundStyle(.orange)
            case .childSavedNotOpened:
                Text("Branch created; could not open it.").foregroundStyle(.orange)
            case .idle, .branching, .switching:
                EmptyView()
            }

            HStack {
                if case .failed = model.selectedPathLoadState,
                   let selectedPathID = model.selectedPathID
                {
                    Button("Refresh") {
                        model.refreshFailedPath(selectedPathID)
                    }
                }
                Spacer()
                if case .childSavedNotOpened = model.operation {
                    Button("Open created branch") {
                        Task {
                            if await model.openCreatedBranch() { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(primaryActionTitle) {
                        Task {
                            if await model.submit() { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryActionEnabled || isSubmitting)
                }
            }
        }
        .padding(16)
        .onChange(of: model.selectedID) { _, _ in
            showsAllChangedPaths = false
        }
    }

    private var primaryActionTitle: String {
        switch model.operation {
        case .branching:
            "Branching…"
        case .switching:
            "Switching…"
        default:
            switch model.primaryAction {
            case let .branch(title):
                title
            case .switchPath:
                "Switch to this path"
            case .currentPath:
                "Current path"
            case .disabled:
                "Branch"
            }
        }
    }

    private var primaryActionEnabled: Bool {
        switch model.operation {
        case .idle:
            break
        case .preCommitFailed where !model.staleSelection:
            break
        case .branching, .switching, .preCommitFailed, .nativeIndeterminate, .childSavedNotOpened:
            return false
        }
        return switch model.primaryAction {
        case .branch, .switchPath:
            true
        case .currentPath, .disabled:
            false
        }
    }

    private var isSubmitting: Bool {
        switch model.operation {
        case .branching, .switching:
            true
        default:
            false
        }
    }

    private func handleKeyResult(_ result: AgentConversationTreePickerModel.KeyResult) {
        switch result {
        case .submit:
            Task {
                if await model.submit() { dismiss() }
            }
        case .dismiss:
            dismiss()
        case .handled, .focusTraversal, .ignored:
            break
        }
    }
}

final class AgentConversationTreeOutlineHost: NSOutlineView {
    var keyHandler: ((AgentConversationTreePickerModel.Key, Bool) -> Bool)?
    weak var bridgeCoordinator: AgentConversationTreeOutlineView.Coordinator?

    override func keyDown(with event: NSEvent) {
        let key: AgentConversationTreePickerModel.Key? = switch event.keyCode {
        case 126: .up
        case 125: .down
        case 124: .right
        case 123: .left
        case 36, 76: .enter
        case 53: .escape
        case 48: .tab
        default: nil
        }
        if let key, keyHandler?(key, event.isARepeat) == true {
            return
        }
        super.keyDown(with: event)
    }
}

struct AgentConversationTreeOutlineView: NSViewRepresentable {
    @ObservedObject var model: AgentConversationTreePickerModel
    var focusGeneration: UInt64 = 0
    let keyResult: (AgentConversationTreePickerModel.KeyResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, keyResult: keyResult)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = AgentConversationTreeOutlineHost()
        outline.headerView = nil
        outline.rowSizeStyle = .medium
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch")))
        outline.outlineTableColumn = outline.tableColumns[0]
        Self.installBridge(on: outline, coordinator: context.coordinator)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.lastFocusGeneration = focusGeneration
        context.coordinator.synchronize(outline)
        DispatchQueue.main.async { [weak outline] in
            guard let outline else { return }
            outline.window?.makeFirstResponder(outline)
        }
        return scroll
    }

    static func installBridge(
        on outline: AgentConversationTreeOutlineHost,
        coordinator: Coordinator
    ) {
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.bridgeCoordinator = coordinator
        outline.keyHandler = { [weak coordinator, weak outline] key, repeatFlag in
            guard let coordinator else { return false }
            let result = coordinator.model.reduce(key: key, isRepeat: repeatFlag)
            coordinator.keyResult(result)
            if let outline {
                coordinator.synchronize(outline)
            }
            return result != .focusTraversal
        }
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outline = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.model = model
        context.coordinator.keyResult = keyResult
        context.coordinator.synchronize(outline)
        if context.coordinator.lastFocusGeneration != focusGeneration {
            context.coordinator.lastFocusGeneration = focusGeneration
            DispatchQueue.main.async { [weak outline] in
                guard let outline else { return }
                outline.window?.makeFirstResponder(outline)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let outline = nsView.documentView as? AgentConversationTreeOutlineHost else { return }
        outline.keyHandler = nil
        outline.bridgeCoordinator = nil
        outline.delegate = nil
        outline.dataSource = nil
        coordinator.cleanup()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Box: NSObject {
            let node: AgentConversationTreeNode
            let children: [Box]
            init(_ node: AgentConversationTreeNode) {
                self.node = node
                children = node.children.map(Box.init)
            }
        }

        var model: AgentConversationTreePickerModel
        var keyResult: (AgentConversationTreePickerModel.KeyResult) -> Void
        private var roots: [Box] = []
        private var lastNodes: [AgentConversationTreeNode] = []
        private var lastExpandedIDs: Set<AgentConversationTreeNode.ID> = []
        private var lastSelectedID: AgentConversationTreeNode.ID?
        private var lastPathLoadStates: [UUID: AgentConversationTreePickerModel.PathLoadState] = [:]
        private var isApplyingProgrammaticState = false
        private(set) var synchronizationApplyCount = 0
        private(set) var topologyReloadCount = 0
        var lastFocusGeneration: UInt64 = 0

        init(
            model: AgentConversationTreePickerModel,
            keyResult: @escaping (AgentConversationTreePickerModel.KeyResult) -> Void
        ) {
            self.model = model
            self.keyResult = keyResult
        }

        func synchronize(_ outline: NSOutlineView) {
            let nextNodes = model.nodes
            let topologyChanged = nextNodes != lastNodes
            let expansionChanged = model.expandedIDs != lastExpandedIDs
            let selectionChanged = model.selectedID != lastSelectedID
            let rowStateChanged = model.pathLoadStates != lastPathLoadStates
            guard topologyChanged || expansionChanged || selectionChanged || rowStateChanged else { return }

            synchronizationApplyCount += 1
            isApplyingProgrammaticState = true
            defer {
                lastNodes = nextNodes
                lastExpandedIDs = model.expandedIDs
                lastSelectedID = model.selectedID
                lastPathLoadStates = model.pathLoadStates
                isApplyingProgrammaticState = false
            }
            if topologyChanged {
                topologyReloadCount += 1
                roots = nextNodes.map(Box.init)
            }
            if topologyChanged || rowStateChanged {
                outline.reloadData()
            }
            if topologyChanged || rowStateChanged || expansionChanged {
                applyExpansion(in: roots, outline: outline)
            }
            if topologyChanged || selectionChanged,
               let id = model.selectedID,
               let box = find(id, in: roots)
            {
                let row = outline.row(forItem: box)
                if row >= 0, outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
        }

        func cleanup() {
            roots.removeAll()
            keyResult = { _ in }
        }

        func outlineView(
            _: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            (item as? Box)?.children.count ?? roots.count
        }

        func outlineView(
            _: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            (item as? Box)?.children[index] ?? roots[index]
        }

        func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
            ((item as? Box)?.children.isEmpty == false)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor _: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let box = item as? Box else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("ConversationTreeCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = identifier
            let field = cell.textField ?? {
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return field
            }()
            field.stringValue = title(for: box.node)
            field.lineBreakMode = .byTruncatingTail
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticState,
                  let outline = notification.object as? NSOutlineView,
                  let box = outline.item(atRow: outline.selectedRow) as? Box,
                  model.selectedID != box.node.id
            else { return }
            model.select(box.node.id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isApplyingProgrammaticState,
                  let box = notification.userInfo?["NSObject"] as? Box,
                  !model.expandedIDs.contains(box.node.id)
            else { return }
            model.setExpanded(box.node.id, expanded: true)
            lastExpandedIDs = model.expandedIDs
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isApplyingProgrammaticState,
                  let box = notification.userInfo?["NSObject"] as? Box,
                  model.expandedIDs.contains(box.node.id)
            else { return }
            model.setExpanded(box.node.id, expanded: false)
            lastExpandedIDs = model.expandedIDs
        }

        private func title(for node: AgentConversationTreeNode) -> String {
            switch node.kind {
            case let .path(path):
                if let placeholder = path.evidence.placeholderTitle {
                    return placeholder
                }
                var title = path.name
                if path.isActive { title += "  • Current" }
                switch model.pathLoadStates[path.id] {
                case .loading: title += "  · Loading…"
                case let .failed(message): title += "  · \(message)"
                case .notLoaded, .loaded, nil: break
                }
                return title
            case let .turn(turn, _):
                let count = node.children.count
                let badge = count == 0 ? "" : "  · \(count) branch\(count == 1 ? "" : "es")"
                return "\(turn.availabilityIndicator)  Turn \(turn.ordinal)  \(turn.snippet)\(badge)"
            case let .missingTurn(_, ordinal):
                return "Turn \(ordinal) (not retained)"
            case let .sourcePlaceholder(title):
                return title
            }
        }

        private func applyExpansion(in boxes: [Box], outline: NSOutlineView) {
            for box in boxes {
                if model.expandedIDs.contains(box.node.id) {
                    if !outline.isItemExpanded(box) {
                        outline.expandItem(box)
                    }
                } else if outline.isItemExpanded(box) {
                    outline.collapseItem(box)
                }
                applyExpansion(in: box.children, outline: outline)
            }
        }

        private func find(_ id: AgentConversationTreeNode.ID, in boxes: [Box]) -> Box? {
            for box in boxes {
                if box.node.id == id { return box }
                if let result = find(id, in: box.children) { return result }
            }
            return nil
        }
    }
}
