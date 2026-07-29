import SwiftUI

// MARK: - Oracle Pill

enum AgentOraclePillLogic {
    enum PresentationSource: Equatable {
        case latest
        case explicit
        case pinned
    }

    struct ExplicitOpenRequest: Equatable {
        let generation: UInt64
        let workspaceID: UUID
        let tabID: UUID
        let chatID: String
    }

    static func explicitOpenRequest(
        chatID rawChatID: String,
        workspaceID: UUID,
        tabID: UUID,
        generation: UInt64
    ) -> ExplicitOpenRequest? {
        let chatID = rawChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else { return nil }
        return ExplicitOpenRequest(
            generation: generation,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: chatID
        )
    }

    static func shouldPresent(
        session: ChatSession,
        for request: ExplicitOpenRequest,
        currentGeneration: UInt64,
        currentWorkspaceID: UUID?,
        currentTabID: UUID?
    ) -> Bool {
        guard request.generation == currentGeneration,
              request.workspaceID == currentWorkspaceID,
              request.tabID == currentTabID,
              session.workspaceID == request.workspaceID,
              session.composeTabID == request.tabID else { return false }
        return Self.session(matchingChatID: request.chatID, in: [session]) != nil
    }

    static func hasRenderableMessages(session: ChatSession, liveMessageCount: Int?) -> Bool {
        if let liveMessageCount {
            return liveMessageCount > 0
        }
        return session.hasMessages
    }

    static func eligibleSessions(
        sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        liveMessageCount: (UUID) -> Int?,
        activeAgentSessionID: UUID? = nil,
        activeRunID: UUID? = nil
    ) -> [ChatSession] {
        let renderable = sessions.filter { session in
            hasRenderableMessages(session: session, liveMessageCount: liveMessageCount(session.id))
                || streamingSessionIDs.contains(session.id)
        }
        let streaming = renderable.filter { streamingSessionIDs.contains($0.id) }
        let completed = renderable.filter { !streamingSessionIDs.contains($0.id) }
        guard activeAgentSessionID != nil || activeRunID != nil else { return renderable }

        func isUnownedLegacy(_ session: ChatSession) -> Bool {
            session.agentModeSessionID == nil && session.agentModeRunID == nil
        }
        func matchesAgent(_ session: ChatSession) -> Bool {
            guard let activeAgentSessionID else { return true }
            return session.agentModeSessionID == activeAgentSessionID
        }
        func includingEveryStream(_ completedSessions: [ChatSession]) -> [ChatSession] {
            streaming + completedSessions
        }

        // Cap accounting and user observability are tab-scoped, so every active
        // stream remains visible even when completed history is owner-filtered.
        if let activeRunID {
            let exactRunMatches = completed.filter { matchesAgent($0) && $0.agentModeRunID == activeRunID }
            if !exactRunMatches.isEmpty { return includingEveryStream(exactRunMatches) }

            let sameAgentLegacyRunMatches = completed.filter {
                matchesAgent($0) && $0.agentModeSessionID != nil && $0.agentModeRunID == nil
            }
            if !sameAgentLegacyRunMatches.isEmpty { return includingEveryStream(sameAgentLegacyRunMatches) }

            if let activeAgentSessionID,
               completed.contains(where: { $0.agentModeSessionID == activeAgentSessionID })
            {
                return streaming
            }
            return includingEveryStream(completed.filter(isUnownedLegacy))
        }

        if let activeAgentSessionID {
            let sameAgentMatches = completed.filter { $0.agentModeSessionID == activeAgentSessionID }
            if !sameAgentMatches.isEmpty { return includingEveryStream(sameAgentMatches) }
        }

        return includingEveryStream(completed.filter(isUnownedLegacy))
    }

    static func latestSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        latestStreamingSession(in: sessions, streamingSessionIDs: streamingSessionIDs)
            ?? sessions.max(by: { $0.savedAt < $1.savedAt })
    }

    static func latestStreamingSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        sessions
            .filter { streamingSessionIDs.contains($0.id) }
            .max(by: { $0.savedAt < $1.savedAt })
    }

    static func orderedSessions(
        _ sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        completedLimit: Int? = nil
    ) -> [ChatSession] {
        let streaming = sessions
            .filter { streamingSessionIDs.contains($0.id) }
            .sorted { $0.savedAt > $1.savedAt }
        let completed = sessions
            .filter { !streamingSessionIDs.contains($0.id) }
            .sorted { $0.savedAt > $1.savedAt }
        if let completedLimit {
            return streaming + Array(completed.prefix(max(0, completedLimit)))
        }
        return streaming + completed
    }

    static func selectedSessionID(
        currentSelectionID: UUID?,
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        if let currentSelectionID,
           sessions.contains(where: { $0.id == currentSelectionID })
        {
            return currentSelectionID
        }
        return latestSession(in: sessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func reconciledPresentedSessionID(
        currentSessionID: UUID?,
        source: PresentationSource,
        currentWorkspaceID: UUID?,
        sameTabSessions: [ChatSession],
        eligibleSessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        let sameWorkspaceSessions = sameTabSessions.filter { $0.workspaceID == currentWorkspaceID }
        let sameWorkspaceEligibleSessions = eligibleSessions.filter { $0.workspaceID == currentWorkspaceID }
        if source == .explicit {
            guard let currentSessionID,
                  sameWorkspaceSessions.contains(where: { $0.id == currentSessionID })
            else {
                return nil
            }
            return currentSessionID
        }

        if let currentSessionID,
           sameWorkspaceEligibleSessions.contains(where: { $0.id == currentSessionID })
        {
            return currentSessionID
        }
        return latestSession(in: sameWorkspaceEligibleSessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func reconciledPresentedSessionID(
        currentSessionID: UUID?,
        isExplicit: Bool,
        currentWorkspaceID: UUID?,
        sameTabSessions: [ChatSession],
        eligibleSessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        reconciledPresentedSessionID(
            currentSessionID: currentSessionID,
            source: isExplicit ? .explicit : .latest,
            currentWorkspaceID: currentWorkspaceID,
            sameTabSessions: sameTabSessions,
            eligibleSessions: eligibleSessions,
            streamingSessionIDs: streamingSessionIDs
        )
    }

    static func modelDisplayName(
        for session: ChatSession,
        streamingSessionIDs: Set<UUID>
    ) -> String? {
        if streamingSessionIDs.contains(session.id) {
            return session.lastSendModelDisplayName ?? session.lastResponseModelDisplayName
        }
        return session.lastResponseModelDisplayName
    }

    static func displayTitle(
        for session: ChatSession,
        modelDisplayName: String? = nil
    ) -> String {
        let resolvedModelName = modelDisplayName ?? session.lastResponseModelDisplayName
        let genericNames: Set = ["new chat", "untitled", "untitled chat"]
        let trimmedName = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if genericNames.contains(trimmedName.lowercased()),
           let resolvedModelName,
           !resolvedModelName.isEmpty
        {
            return resolvedModelName
        }
        return trimmedName.isEmpty ? (resolvedModelName ?? session.shortID) : trimmedName
    }

    static func session(matchingChatID raw: String, in sessions: [ChatSession]) -> ChatSession? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targetUUID = UUID(uuidString: trimmed)
        let matches = sessions.filter { session in
            if let targetUUID {
                return session.id == targetUUID
            }
            return session.shortID == trimmed
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Pill that appears when there are oracle chat sessions for the current tab.
/// More prominent when streaming. Clicking opens a wide popover with chat transcript.
struct AgentOraclePill: View {
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?

    @State private var showPopover = false
    @State private var autoScrollEnabled = false
    @State private var presentedSessionID: UUID?
    @State private var presentedSessionSource: AgentOraclePillLogic.PresentationSource = .latest
    @State private var openRequestGeneration: UInt64 = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var eligibleTabSessions: [ChatSession] {
        guard let tabID = currentTabID else { return [] }
        return AgentOraclePillLogic.eligibleSessions(
            sessions: oracleViewModel.sessions(forTabID: tabID),
            streamingSessionIDs: oracleViewModel.streamingSessions,
            liveMessageCount: { oracleViewModel.liveMessageCount(for: $0) },
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    private var orderedEligibleTabSessions: [ChatSession] {
        var ordered = AgentOraclePillLogic.orderedSessions(
            eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions,
            completedLimit: 3
        )
        if let presentedSession,
           eligibleTabSessions.contains(where: { $0.id == presentedSession.id }),
           !ordered.contains(where: { $0.id == presentedSession.id })
        {
            ordered.append(presentedSession)
        }
        return ordered
    }

    private var latestTabSession: ChatSession? {
        AgentOraclePillLogic.latestSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
    }

    private var streamingSessionCount: Int {
        eligibleTabSessions.reduce(into: 0) { count, session in
            if oracleViewModel.streamingSessions.contains(session.id) {
                count += 1
            }
        }
    }

    private var isStreaming: Bool {
        streamingSessionCount > 0
    }

    private var presentedSession: ChatSession? {
        guard let presentedSessionID,
              let tabID = currentTabID else { return nil }
        return oracleViewModel.sessions(forTabID: tabID).first { $0.id == presentedSessionID }
    }

    private var isPresentedSessionStreaming: Bool {
        guard let presentedSessionID else { return isStreaming }
        return oracleViewModel.streamingSessions.contains(presentedSessionID)
    }

    private var popoverSubtitle: String {
        guard let presentedSession else { return "Latest tab chat" }
        let modelName = AgentOraclePillLogic.modelDisplayName(
            for: presentedSession,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        var parts = [AgentOraclePillLogic.displayTitle(
            for: presentedSession,
            modelDisplayName: modelName
        )]
        if let modelName, !parts.contains(modelName) {
            parts.append(modelName)
        }
        parts.append(presentedSession.shortID)
        return parts.joined(separator: " • ")
    }

    private var pillLabel: String {
        streamingSessionCount > 1 ? "Oracle · \(streamingSessionCount)" : "Oracle"
    }

    private var pillTooltip: String {
        if streamingSessionCount > 1 {
            return "\(streamingSessionCount) Oracle chats are running — click to view"
        }
        if isStreaming {
            return "Oracle is thinking — click to view the live chat"
        }
        return "Open the latest Oracle chat for this tab"
    }

    private var hasAnySessions: Bool {
        latestTabSession != nil
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.oracle")
        #endif
        Group {
            if hasAnySessions {
                let cornerRadius = AgentPillMetrics.cornerRadius()
                Button {
                    openPopover(chatID: nil)
                } label: {
                    HStack(spacing: 6) {
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "brain")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .foregroundStyle(.secondary)
                        }
                        Text(pillLabel)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: isStreaming ? .semibold : .medium))
                            .foregroundStyle(isStreaming ? .primary : .secondary)
                    }
                    .padding(.horizontal, AgentPillMetrics.horizontalPadding())
                    .frame(height: AgentPillMetrics.height())
                    .background(isStreaming ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(isStreaming ? Color.purple.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isStreaming ? 1 : 0.5)
                    )
                    .shadow(color: isStreaming ? Color.purple.opacity(0.15) : .clear, radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .hoverTooltip(pillTooltip, .top)
                .accessibilityLabel("Oracle")
                .accessibilityValue(isStreaming ? "\(streamingSessionCount) chat\(streamingSessionCount == 1 ? "" : "s") running" : "No chats running")
                .animation(.easeInOut(duration: 0.2), value: isStreaming)
                .animation(.easeInOut(duration: 0.2), value: streamingSessionCount)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentOraclePopover)) { note in
            if let route = AgentOraclePopoverRoute(notificationUserInfo: note.userInfo) {
                guard route.windowID == windowID,
                      route.tabID == currentTabID,
                      route.workspaceID == oracleViewModel.workspaceManager.activeWorkspaceID
                else { return }
                openPopover(chatID: route.chatID, workspaceID: route.workspaceID)
                return
            }
            guard let route = AgentOracleLatestPopoverRoute(notificationUserInfo: note.userInfo),
                  route.windowID == windowID,
                  route.tabID == currentTabID,
                  route.workspaceID == oracleViewModel.workspaceManager.activeWorkspaceID
            else { return }
            openLatestStreamingPopover()
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            oraclePopoverContent
        }
        .onChange(of: currentTabID) { _, _ in
            openRequestGeneration &+= 1
            reconcilePresentedSession()
        }
        .onReceive(oracleViewModel.workspaceManager.$activeWorkspaceID) { _ in
            openRequestGeneration &+= 1
            if presentedSessionSource == .explicit {
                presentedSessionID = nil
                showPopover = false
            } else {
                reconcilePresentedSession()
            }
        }
        .onChange(of: activeAgentSessionID) { _, _ in
            reconcilePresentedSession()
        }
        .onChange(of: activeRunID) { _, _ in
            reconcilePresentedSession()
        }
        .onChange(of: eligibleTabSessions.map(\.id)) { _, _ in
            reconcilePresentedSession()
        }
    }

    @ViewBuilder
    private var oraclePopoverContent: some View {
        // Popover dimensions scale so chat messages don't feel cramped at
        // Larger/Extra Large. Width gets a tighter cap than height because the
        // popover is anchored to the composer and we don't want it to spill
        // beyond the window edges; the chat transcript area takes the rest.
        let popoverWidth = fontPreset.scaledClamped(800, max: 1040)
        let transcriptMinHeight = fontPreset.scaledClamped(350, max: 460)
        let transcriptIdealHeight = fontPreset.scaledClamped(500, max: 660)
        let transcriptMaxHeight = fontPreset.scaledClamped(600, max: 780)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Oracle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                if isPresentedSessionStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
                Text(popoverSubtitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if orderedEligibleTabSessions.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(orderedEligibleTabSessions) { session in
                            oracleSessionChip(session)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

            ChatMessagesView(
                viewModel: oracleViewModel,
                autoScrollEnabled: $autoScrollEnabled,
                bottomOcclusion: 0,
                showsScrollControls: true,
                autoScrollOnAppear: true,
                sessionIDOverride: presentedSessionID
            )
            .frame(minHeight: transcriptMinHeight, idealHeight: transcriptIdealHeight, maxHeight: transcriptMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(width: popoverWidth)
    }

    private func reconcilePresentedSession() {
        guard showPopover else { return }
        let sameTabSessions = currentTabID.map { oracleViewModel.sessions(forTabID: $0) } ?? []
        let resolvedID = AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: presentedSessionID,
            source: presentedSessionSource,
            currentWorkspaceID: oracleViewModel.workspaceManager.activeWorkspaceID,
            sameTabSessions: sameTabSessions,
            eligibleSessions: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        guard let resolvedID else {
            presentedSessionID = nil
            showPopover = false
            return
        }
        presentedSessionID = resolvedID
    }

    private func oracleSessionChip(_ session: ChatSession) -> some View {
        let isSelected = session.id == presentedSessionID
        let isSessionStreaming = oracleViewModel.streamingSessions.contains(session.id)
        let modelName = AgentOraclePillLogic.modelDisplayName(
            for: session,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        let title = AgentOraclePillLogic.displayTitle(for: session, modelDisplayName: modelName)
        let detail = [modelName == title ? nil : modelName, session.shortID]
            .compactMap(\.self)
            .joined(separator: " • ")

        return Button {
            presentedSessionID = session.id
            presentedSessionSource = .pinned
        } label: {
            HStack(spacing: 7) {
                if isSessionStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSessionStreaming ? Color.purple.opacity(0.35) : Color.secondary.opacity(0.12),
                        lineWidth: 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityValue("\(isSessionStreaming ? "running" : "completed")\(isSelected ? ", selected" : "")")
    }

    private func openLatestStreamingPopover() {
        guard let target = AgentOraclePillLogic.latestStreamingSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        ) else { return }
        openRequestGeneration &+= 1
        presentedSessionID = target.id
        presentedSessionSource = .latest
        showPopover = true
    }

    private func openPopover(chatID: String?, workspaceID: UUID? = nil) {
        guard let tabID = currentTabID else { return }
        openRequestGeneration &+= 1
        let generation = openRequestGeneration

        guard let chatID else {
            guard let target = latestTabSession else { return }
            presentedSessionID = target.id
            presentedSessionSource = .latest
            showPopover = true
            return
        }

        presentedSessionID = nil
        presentedSessionSource = .explicit
        showPopover = false
        guard let workspaceID,
              let request = AgentOraclePillLogic.explicitOpenRequest(
                  chatID: chatID,
                  workspaceID: workspaceID,
                  tabID: tabID,
                  generation: generation
              ) else { return }

        Task { @MainActor in
            guard let target = await oracleViewModel.resolveExactSessionForPopover(
                chatID: request.chatID,
                workspaceID: request.workspaceID,
                tabID: request.tabID
            ),
                AgentOraclePillLogic.shouldPresent(
                    session: target,
                    for: request,
                    currentGeneration: openRequestGeneration,
                    currentWorkspaceID: oracleViewModel.workspaceManager.activeWorkspaceID,
                    currentTabID: currentTabID
                )
            else { return }

            presentedSessionID = target.id
            presentedSessionSource = .explicit
            showPopover = true
        }
    }
}
