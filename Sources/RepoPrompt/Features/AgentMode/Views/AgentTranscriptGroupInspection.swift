import SwiftUI

// Oracle failure inspection plan, Patch C: live group expansion and large-group rendering for
// dynamic tool-summary blocks (activity clusters and grouped history). Everything here is
// presentation-only and in-memory; a transcript reload returns every block to its default.

// MARK: - C1. Explicit-choice provenance

/// Effective expansion for dynamic tool-summary blocks. `transcriptBlockExpansion` is seeded for
/// every expandable block, so a stored value alone never means the user chose it; the manual set
/// records explicit choices.
enum AgentTranscriptGroupExpansionPolicy {
    struct BlockInput: Equatable {
        let id: String
        let supportsExpansion: Bool
        let defaultExpanded: Bool
    }

    struct State: Equatable {
        var expansion: [String: Bool] = [:]
        var defaults: [String: Bool] = [:]
        var manualIDs: Set<String> = []
    }

    /// - no expandable content → collapsed;
    /// - an explicit user choice → the stored value;
    /// - a default-collapse target (a dynamic group in the live run's latest turn) → collapsed;
    /// - otherwise → the stored value, else the block default.
    static func effectiveExpansion(
        supportsExpansion: Bool,
        isManualChoice: Bool,
        isDefaultCollapseTarget: Bool,
        storedExpansion: Bool?,
        defaultExpanded: Bool
    ) -> Bool {
        guard supportsExpansion else { return false }
        if isManualChoice {
            return storedExpansion ?? defaultExpanded
        }
        if isDefaultCollapseTarget {
            return false
        }
        return storedExpansion ?? defaultExpanded
    }

    static func effectiveExpansion(
        of block: BlockInput,
        in state: State,
        isDefaultCollapseTarget: Bool
    ) -> Bool {
        effectiveExpansion(
            supportsExpansion: block.supportsExpansion,
            isManualChoice: state.manualIDs.contains(block.id),
            isDefaultCollapseTarget: isDefaultCollapseTarget,
            storedExpansion: state.expansion[block.id],
            defaultExpanded: block.defaultExpanded
        )
    }

    /// A user click flips the *effective* state (so the first click on a default-expanded block
    /// that is showing collapsed expands it) and records the choice for both directions.
    static func toggled(
        _ state: State,
        block: BlockInput,
        isDefaultCollapseTarget: Bool
    ) -> State {
        guard block.supportsExpansion else { return state }
        var next = state
        next.expansion[block.id] = !effectiveExpansion(
            of: block,
            in: state,
            isDefaultCollapseTarget: isDefaultCollapseTarget
        )
        next.defaults[block.id] = block.defaultExpanded
        next.manualIDs.insert(block.id)
        return next
    }

    /// Seeds new blocks with their default, follows default flips only for blocks without an
    /// explicit choice whose stored value still equals the previous default, and prunes state
    /// (including explicit choices) for blocks that are gone or no longer expandable.
    static func synchronized(_ state: State, blocks: [BlockInput]) -> State {
        let validIDs = Set(blocks.map(\.id))
        var nextExpansion = state.expansion.filter { validIDs.contains($0.key) }
        var nextDefaults = state.defaults.filter { validIDs.contains($0.key) }
        var nextManualIDs = state.manualIDs.intersection(validIDs)
        for block in blocks {
            guard block.supportsExpansion else {
                nextExpansion.removeValue(forKey: block.id)
                nextDefaults.removeValue(forKey: block.id)
                nextManualIDs.remove(block.id)
                continue
            }
            let defaultExpanded = block.defaultExpanded
            if nextManualIDs.contains(block.id), nextExpansion[block.id] != nil {
                // An explicit choice is never default-following.
            } else if let existingExpansion = nextExpansion[block.id],
                      let previousDefault = nextDefaults[block.id]
            {
                if previousDefault != defaultExpanded,
                   existingExpansion == previousDefault
                {
                    nextExpansion[block.id] = defaultExpanded
                }
            } else {
                nextExpansion[block.id] = defaultExpanded
            }
            nextDefaults[block.id] = defaultExpanded
        }
        return State(expansion: nextExpansion, defaults: nextDefaults, manualIDs: nextManualIDs)
    }

    /// Dynamic blocks that collapse automatically when a run becomes active: expanded by their
    /// stored or default value and not explicitly chosen. Explicit choices never collapse, so they
    /// never trigger a compensating live-bottom re-pin.
    static func automaticallyCollapsingCount(_ state: State, blocks: [BlockInput]) -> Int {
        blocks.count(where: { block in
            block.supportsExpansion
                && !state.manualIDs.contains(block.id)
                && (state.expansion[block.id] ?? block.defaultExpanded)
        })
    }
}

// MARK: - C4. Flattened grouped-history entries

/// One lazily rendered line of an expanded grouped-history block.
struct AgentTranscriptGroupInspectionEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case sectionHeader(AgentTranscriptGroupedSection)
        /// A transcript row and the child block that supplies its render context.
        case row(AgentChatItem, childBlock: AgentTranscriptRenderBlock)
    }

    let id: String
    let content: Content
    /// Space above this entry, reproducing the eager nested-stack layout.
    let topSpacing: CGFloat
}

/// Flattens grouped-history sections so a `LazyVStack` virtualizes rows; a lazy wrapper around
/// eager sections would still build every row. Grouped sections render a heading and their
/// child rows, so entries carry those two kinds with stable identity.
enum AgentTranscriptGroupInspection {
    static let sectionSpacing: CGFloat = 8
    static let sectionVerticalPadding: CGFloat = 2
    static let sectionContentSpacing: CGFloat = 6
    static let childRowSpacing: CGFloat = 4

    static func hasSectionHeader(_ section: AgentTranscriptGroupedSection) -> Bool {
        section.title != nil || section.clusterSummary != nil
    }

    static func entries(for sections: [AgentTranscriptGroupedSection]) -> [AgentTranscriptGroupInspectionEntry] {
        var entries: [AgentTranscriptGroupInspectionEntry] = []
        var emittedIDs = Set<String>()
        for (sectionIndex, section) in sections.enumerated() {
            var isFirstInSection = true
            func spacing(withinSection: CGFloat) -> CGFloat {
                guard isFirstInSection else { return withinSection }
                return sectionIndex == 0
                    ? sectionVerticalPadding
                    : sectionVerticalPadding * 2 + sectionSpacing
            }
            func append(id: String, content: AgentTranscriptGroupInspectionEntry.Content, withinSection: CGFloat) {
                guard emittedIDs.insert(id).inserted else { return }
                entries.append(.init(id: id, content: content, topSpacing: spacing(withinSection: withinSection)))
                isFirstInSection = false
            }
            if hasSectionHeader(section) {
                append(id: "section:\(section.id)", content: .sectionHeader(section), withinSection: 0)
            }
            for childBlock in section.childBlocks {
                for (rowIndex, item) in childBlock.rows.enumerated() {
                    append(
                        id: "row:\(item.id.uuidString.lowercased())",
                        content: .row(item, childBlock: childBlock),
                        withinSection: rowIndex == 0 ? sectionContentSpacing : childRowSpacing
                    )
                }
            }
        }
        return entries
    }
}

// MARK: - C3. Bottom-sticky inner follow

enum AgentTranscriptInnerFollowPolicy {
    static let bottomTolerance: CGFloat = 6

    struct Position: Equatable {
        var offsetY: CGFloat
        var distanceToBottom: CGFloat
    }

    /// Reaching the inner bottom pins; scrolling up unpins; content growth alone (a new row
    /// arriving below an unmoved offset) keeps the current state so following continues.
    static func isPinned(current: Bool, old: Position?, new: Position) -> Bool {
        if new.distanceToBottom <= bottomTolerance {
            return true
        }
        if let old, new.offsetY < old.offsetY - 0.5 {
            return false
        }
        return current
    }

    /// Follow the newest row only for a live group while the user is at its inner bottom.
    static func shouldFollow(isLive: Bool, isPinned: Bool) -> Bool {
        isLive && isPinned
    }

    /// macOS 15+ path: `ScrollGeometry` content offset, content height, and visible maximum.
    static func position(contentOffsetY: CGFloat, contentHeight: CGFloat, visibleMaxY: CGFloat) -> Position {
        Position(offsetY: contentOffsetY, distanceToBottom: max(0, contentHeight - visibleMaxY))
    }

    /// macOS 14 path: the scrolled content's frame in the scroll view's own coordinate space
    /// (its `minY` moves up as the user scrolls down) and the visible viewport height. Equal
    /// geometry yields the same position as the macOS 15+ path.
    static func position(contentFrame: CGRect, viewportHeight: CGFloat) -> Position {
        Position(offsetY: -contentFrame.minY, distanceToBottom: max(0, contentFrame.maxY - viewportHeight))
    }
}

/// Pin and live state for one inner follow scroll view, plus a generation token that makes
/// deferred follow scrolls cancellable. A follow is scheduled on a newest-row change only when
/// eligible, and the deferred scroll runs only if it is still the latest scheduled follow and
/// still eligible; unpinning or the run ending invalidates any scheduled follow.
struct AgentTranscriptInnerFollowState: Equatable {
    private(set) var isPinned = false
    private(set) var isLive: Bool
    private(set) var lastPosition: AgentTranscriptInnerFollowPolicy.Position?
    private(set) var generation = 0

    init(isLive: Bool) {
        self.isLive = isLive
    }

    mutating func record(_ position: AgentTranscriptInnerFollowPolicy.Position) {
        let pinned = AgentTranscriptInnerFollowPolicy.isPinned(current: isPinned, old: lastPosition, new: position)
        lastPosition = position
        if isPinned, !pinned {
            generation &+= 1
        }
        isPinned = pinned
    }

    mutating func setLive(_ live: Bool) {
        if isLive, !live {
            generation &+= 1
        }
        isLive = live
    }

    /// A newest-row change: returns a ticket for a deferred follow scroll, or `nil` when the
    /// group is not live or the user is not at its inner bottom.
    mutating func scheduleFollow() -> Int? {
        guard AgentTranscriptInnerFollowPolicy.shouldFollow(isLive: isLive, isPinned: isPinned) else { return nil }
        generation &+= 1
        return generation
    }

    /// Revalidated at execution: the ticket is still the latest and following still applies.
    func shouldExecuteFollow(_ ticket: Int) -> Bool {
        ticket == generation && AgentTranscriptInnerFollowPolicy.shouldFollow(isLive: isLive, isPinned: isPinned)
    }
}

/// Capped inner scroll view for an expanded group. While `followsNewest` (an expanded group in
/// the live run's latest turn) and the user is at the inner bottom, a newly arriving row scrolls
/// into view; scrolling up stops following until the user returns to the bottom. Bottom tracking
/// uses `onScrollGeometryChange` on macOS 15+ and a geometry-reader preference on macOS 14; both
/// feed the same `AgentTranscriptInnerFollowState`.
struct AgentTranscriptInnerFollowScrollView<Content: View>: View {
    let maxHeight: CGFloat
    let followsNewest: Bool
    let newestEntryID: String?
    let bottomAnchorID: String
    private let content: Content

    @State private var followState: AgentTranscriptInnerFollowState

    init(
        maxHeight: CGFloat,
        followsNewest: Bool,
        newestEntryID: String?,
        bottomAnchorID: String,
        @ViewBuilder content: () -> Content
    ) {
        self.maxHeight = maxHeight
        self.followsNewest = followsNewest
        self.newestEntryID = newestEntryID
        self.bottomAnchorID = bottomAnchorID
        self.content = content()
        _followState = State(initialValue: AgentTranscriptInnerFollowState(isLive: followsNewest))
    }

    private var coordinateSpaceName: String {
        "AgentTranscriptInnerFollowScroll:\(bottomAnchorID)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    Color.clear.frame(height: 1).id(bottomAnchorID)
                }
                .modifier(AgentTranscriptInnerLegacyContentFrameReporter(coordinateSpaceName: coordinateSpaceName))
            }
            .coordinateSpace(.named(coordinateSpaceName))
            .frame(maxHeight: maxHeight)
            .modifier(AgentTranscriptInnerBottomTracking { position in
                followState.record(position)
            })
            .onChange(of: followsNewest) { _, isLive in
                followState.setLive(isLive)
            }
            .onChange(of: newestEntryID) { _, _ in
                guard let ticket = followState.scheduleFollow() else { return }
                DispatchQueue.main.async {
                    guard followState.shouldExecuteFollow(ticket) else { return }
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }
}

private struct AgentTranscriptInnerContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct AgentTranscriptInnerViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// macOS 14 only: reports the scrolled content's frame in the inner scroll view's coordinate
/// space. macOS 15+ reads `ScrollGeometry` instead, so the two sources never interleave.
private struct AgentTranscriptInnerLegacyContentFrameReporter: ViewModifier {
    let coordinateSpaceName: String

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
        } else {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AgentTranscriptInnerContentFramePreferenceKey.self,
                        value: geometry.frame(in: .named(coordinateSpaceName))
                    )
                }
            }
        }
    }
}

private struct AgentTranscriptInnerBottomTracking: ViewModifier {
    let onPosition: (AgentTranscriptInnerFollowPolicy.Position) -> Void

    @State private var legacyContentFrame: CGRect?
    @State private var legacyViewportHeight: CGFloat?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(
                for: AgentTranscriptInnerFollowPolicy.Position.self,
                of: { geometry in
                    AgentTranscriptInnerFollowPolicy.position(
                        contentOffsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        visibleMaxY: geometry.visibleRect.maxY
                    )
                },
                action: { _, newPosition in
                    onPosition(newPosition)
                }
            )
        } else {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AgentTranscriptInnerViewportHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .onPreferenceChange(AgentTranscriptInnerContentFramePreferenceKey.self) { frame in
                    legacyContentFrame = frame
                    reportLegacyPosition()
                }
                .onPreferenceChange(AgentTranscriptInnerViewportHeightPreferenceKey.self) { height in
                    legacyViewportHeight = height
                    reportLegacyPosition()
                }
        }
    }

    private func reportLegacyPosition() {
        guard let legacyContentFrame, let legacyViewportHeight, legacyViewportHeight > 0 else { return }
        onPosition(AgentTranscriptInnerFollowPolicy.position(
            contentFrame: legacyContentFrame,
            viewportHeight: legacyViewportHeight
        ))
    }
}
