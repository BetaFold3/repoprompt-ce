import Foundation
import SwiftUI

func oracleToolResultPopoverUserInfo(
    item: AgentChatItem,
    openContext: AgentOracleOpenContext?
) -> [AnyHashable: Any]? {
    let chatID = AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: item.toolResultJSON)
    return AgentOracleToolRouting.operationPopoverUserInfo(
        openContext: openContext,
        chatID: chatID
    )
}

func chatSendResultSummary(_ dto: ToolResultDTOs.ChatSendDTO) -> String {
    var parts: [String] = []
    if let mode = dto.mode { parts.append(mode) }
    if let modelName = dto.modelPresetName ?? dto.uiModelName ?? dto.modelName,
       !modelName.isEmpty
    {
        parts.append(modelName)
    }
    if let chatID = dto.chatID, !chatID.isEmpty, parts.isEmpty || dto.diffs?.isEmpty != false {
        parts.append(chatID)
    }
    if let diffs = dto.diffs, !diffs.isEmpty {
        parts.append("\(diffs.count) diffs")
    }
    return parts.joined(separator: " • ")
}

private func nonEmptyOracleToolCardText(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func oracleProgressSummary(
    outputChars: Int?,
    lastActivitySecondsAgo: Int?,
    queuePosition: Int?,
    activityAgeAtLastReport: Bool
) -> String? {
    var parts: [String] = []
    if let queuePosition {
        parts.append("queue position \(queuePosition)")
    }
    if let outputChars {
        parts.append("\(outputChars) chars")
    }
    if let lastActivitySecondsAgo {
        let age = max(0, lastActivitySecondsAgo)
        if activityAgeAtLastReport {
            parts.append("activity age at last report: \(age)s")
        } else {
            parts.append("activity observed \(age)s ago")
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

enum OracleToolCardState: String, Equatable, Hashable {
    case queued
    case preparing
    case pending
    case cancelling
    case completed
    case cancelled
    case failed

    var displayLabel: String {
        switch self {
        case .queued: "Last reported queued"
        case .preparing: "Last reported preparing"
        case .pending: "Last reported running"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    var visualStatus: ToolCardStatus {
        switch self {
        case .queued, .preparing, .pending, .cancelling, .cancelled: .warning
        case .completed: .success
        case .failed: .failure
        }
    }
}

struct OracleToolCardLanePresentation: Equatable {
    let operationID: String?
    let chatID: String?
    let state: OracleToolCardState
    let progressSummary: String?
    let contextSummary: String

    init(dto: ToolResultDTOs.ChatSendDTO) {
        operationID = nonEmptyOracleToolCardText(dto.operationID)
        chatID = nonEmptyOracleToolCardText(dto.chatID)
        state = Self.state(for: dto)
        progressSummary = oracleProgressSummary(
            outputChars: dto.pending?.progress?.outputChars,
            lastActivitySecondsAgo: dto.pending?.progress?.lastActivitySecondsAgo,
            queuePosition: dto.pending?.progress?.queuePosition,
            activityAgeAtLastReport: true
        )
        contextSummary = chatSendResultSummary(dto)
    }

    private static func state(for dto: ToolResultDTOs.ChatSendDTO) -> OracleToolCardState {
        // Terminal status is authoritative even when a cancel acknowledgement is echoed.
        switch dto.status?.lowercased() {
        case "completed", "ready":
            return .completed
        case "cancelled":
            return .cancelled
        case "failed", "unknown", "delivery_failed":
            return .failed
        default:
            break
        }
        if dto.ok == false || dto.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || dto.errors?.isEmpty == false
        {
            return .failed
        }
        if dto.cancel?.lowercased() == "requested"
            || dto.pending?.streamState?.lowercased() == "cancelling"
        {
            return .cancelling
        }
        switch dto.pending?.streamState?.lowercased() {
        case "queued":
            return .queued
        case "starting":
            return .preparing
        default:
            break
        }
        switch dto.status?.lowercased() {
        case "pending", "running", "starting":
            return .pending
        case "cancelling":
            return .cancelling
        default:
            return .completed
        }
    }

    var subtitle: String {
        [state.displayLabel, progressSummary, nonEmptyOracleToolCardText(contextSummary)]
            .compactMap(\.self)
            .joined(separator: " • ")
    }
}

struct OracleToolCardPresentation: Equatable {
    let lanes: [OracleToolCardLanePresentation]
    let waitLabel: String?

    init(dto: ToolResultDTOs.ChatSendDTO, resultObject: [String: Any]?) {
        let laneDTOs = dto.results?.isEmpty == false ? dto.results ?? [] : [dto]
        lanes = laneDTOs.map(OracleToolCardLanePresentation.init)
        waitLabel = resultObject.flatMap(AgentControlWaitLabelBuilder.resultLabel)
    }

    var state: OracleToolCardState {
        if lanes.contains(where: { $0.state == .failed }) { return .failed }
        if lanes.contains(where: { $0.state == .cancelling }) { return .cancelling }
        if lanes.contains(where: { $0.state == .pending }) { return .pending }
        if lanes.contains(where: { $0.state == .preparing }) { return .preparing }
        if lanes.contains(where: { $0.state == .queued }) { return .queued }
        if lanes.contains(where: { $0.state == .cancelled }) { return .cancelled }
        return .completed
    }

    var subtitle: String {
        let base: String
        if lanes.count == 1 {
            base = lanes[0].subtitle
        } else {
            let counts = Dictionary(grouping: lanes, by: \.state).mapValues(\.count)
            let order: [OracleToolCardState] = [
                .failed,
                .cancelling,
                .pending,
                .preparing,
                .queued,
                .cancelled,
                .completed
            ]
            base = order.compactMap { state in
                guard let count = counts[state] else { return nil }
                return "\(count) \(state.displayLabel.lowercased())"
            }.joined(separator: " • ")
        }
        return [nonEmptyOracleToolCardText(base), waitLabel].compactMap(\.self).joined(separator: " • ")
    }

    var uniqueChatIDs: [String] {
        var seen = Set<String>()
        return lanes.compactMap(\.chatID).filter { seen.insert($0).inserted }
    }

    var singleChatID: String? {
        uniqueChatIDs.count == 1 ? uniqueChatIDs[0] : nil
    }
}

struct OracleToolCardLivePresentation: Equatable, Identifiable {
    let operationID: UUID
    let text: String
    let chatID: String?

    var id: UUID {
        operationID
    }

    init(summary: OracleMCPOperationStore.Summary, now: Date = Date()) {
        operationID = summary.operationID
        chatID = nonEmptyOracleToolCardText(summary.chatShortID) ?? summary.chatID?.uuidString

        let statusText = if summary.isCollected {
            "Collected"
        } else {
            switch summary.phase {
            case .queued:
                "Oracle queued · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .starting:
                "Oracle preparing · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .running:
                "Oracle running · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .cancelling:
                "Oracle cancelling · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .ready, .failed, .cancelled:
                "Oracle finished — not yet collected"
            }
        }

        let progressText = summary.progress.flatMap {
            oracleProgressSummary(
                outputChars: $0.outputChars,
                lastActivitySecondsAgo: $0.lastActivitySecondsAgo,
                queuePosition: $0.queuePosition,
                activityAgeAtLastReport: false
            )
        }
        let detailedStatus = [statusText, progressText].compactMap(\.self).joined(separator: " · ")
        if let chatName = nonEmptyOracleToolCardText(summary.chatName) {
            text = "\(detailedStatus) • \(chatName)"
        } else {
            text = detailedStatus
        }
    }

    private static func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

private struct OracleToolCardLiveSidecar: View {
    @ObservedObject var operationStore: OracleMCPOperationStore
    let lanes: [OracleToolCardLanePresentation]
    let openContext: AgentOracleOpenContext?
    let showsOpenChatAction: Bool

    private func presentations(at now: Date) -> [OracleToolCardLivePresentation] {
        _ = operationStore.phaseRevision
        return lanes.compactMap { lane in
            guard lane.state == .queued
                || lane.state == .preparing
                || lane.state == .pending
                || lane.state == .cancelling,
                let operationID = lane.operationID.flatMap({ UUID(uuidString: $0) }),
                let summary = operationStore.summary(for: operationID)
            else {
                return nil
            }
            return OracleToolCardLivePresentation(summary: summary, now: now)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let livePresentations = presentations(at: context.date)
            if !livePresentations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(livePresentations) { presentation in
                        if showsOpenChatAction,
                           let userInfo = AgentOracleToolRouting.operationPopoverUserInfo(
                               openContext: openContext,
                               chatID: presentation.chatID
                           )
                        {
                            Button {
                                NotificationCenter.default.post(
                                    name: .showAgentOraclePopover,
                                    object: nil,
                                    userInfo: userInfo
                                )
                            } label: {
                                HStack(spacing: 4) {
                                    Text(presentation.text)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9))
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        } else {
                            Text(presentation.text)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct OracleToolCardChatLinks: View {
    let chatIDs: [String]
    let openContext: AgentOracleOpenContext?

    var body: some View {
        if chatIDs.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(chatIDs.enumerated()), id: \.element) { index, chatID in
                    if let userInfo = AgentOracleToolRouting.operationPopoverUserInfo(
                        openContext: openContext,
                        chatID: chatID
                    ) {
                        Button {
                            NotificationCenter.default.post(
                                name: .showAgentOraclePopover,
                                object: nil,
                                userInfo: userInfo
                            )
                        } label: {
                            Label("Open chat \(index + 1)", systemImage: "bubble.left.and.bubble.right")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Open Oracle chat \(chatID)")
                    }
                }
            }
        }
    }
}

/// Failed-Oracle card presentation (Oracle failure inspection plan, B4). Built only from the
/// shared `OracleToolResultInspection` projection, so a live failed card and the same card
/// after transcript reload show the same redacted diagnostics. Never establishes root routing
/// identity: the card's Open Oracle control uses the authoritative chat-ID policy instead, and a
/// diagnostic's structured `laneChatID` only opens that lane's chat.
struct OracleFailureCardPresentation: Equatable {
    static let unavailableHeadline = "Error details unavailable"

    let failure: OracleToolResultInspection.Failure

    init(failure: OracleToolResultInspection.Failure) {
        self.failure = failure
    }

    /// Non-nil only when the Oracle result failed, using the trusted resolution (provider error
    /// flag, normalized status, or any failed lane). Pending and cancelled results return nil.
    init?(item: AgentChatItem) {
        let status = AgentTranscriptToolNormalizer.status(for: item)
        guard let failure = OracleToolResultInspection.inspect(
            resultJSON: item.toolResultJSON,
            text: item.text,
            toolIsError: item.toolIsError,
            statusWord: AgentTranscriptToolStatusSemantics.persistedStatusWord(from: status)
        ) else {
            return nil
        }
        self.failure = failure
    }

    var detailsUnavailable: Bool {
        failure.diagnostics.isEmpty
    }

    /// Collapsed subtitle: the redacted headline, prefixed by lane counts for multi-lane results.
    var subtitle: String {
        let headline = failure.headline ?? Self.unavailableHeadline
        if let counts = failure.laneCounts, counts.laneCount > 1 {
            return "\(counts.failedCount) of \(counts.laneCount) failed • \(headline)"
        }
        return headline
    }

    var unavailableExplanation: String {
        failure.isSavedSummary
            ? "The saved transcript did not keep this Oracle call's error details."
            : "This Oracle result did not include error details."
    }

    var showsTruncationNote: Bool {
        failure.primaryMessageTruncated
    }

    /// Historical lane counts; nonterminal lanes are described as unfinished when recorded,
    /// never as still running.
    var laneSummary: String? {
        guard let counts = failure.laneCounts else { return nil }
        var text = "\(counts.failedCount) of \(counts.laneCount) \(counts.laneCount == 1 ? "lane" : "lanes") failed"
        if counts.nonterminalCount > 0 {
            text += "; \(counts.nonterminalCount) unfinished when recorded"
        }
        return text
    }

    var omittedSummary: String? {
        let omitted = failure.omittedDiagnosticCount
        guard omitted > 0 else { return nil }
        return "\(omitted) more \(omitted == 1 ? "error was" : "errors were") not retained"
    }

    static func diagnosticLabel(_ diagnostic: OracleToolResultInspection.Diagnostic) -> String? {
        let parts = [
            diagnostic.index.map { "Lane \($0)" },
            diagnostic.code
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

/// The failed card's Open Oracle control: its own hit target and accessibility action, so the
/// header tap only toggles disclosure.
private struct OracleFailureOpenControl: View {
    let timestamp: Date?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Label("Open Oracle", systemImage: "arrow.up.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .hoverTooltip("Open Oracle chat")
            .accessibilityLabel("Open Oracle chat")
            if let timestamp {
                MessageTimestampText(date: timestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }
}

private struct OracleFailureDetailsView: View {
    let presentation: OracleFailureCardPresentation
    let openContext: AgentOracleOpenContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presentation.detailsUnavailable {
                Text(OracleFailureCardPresentation.unavailableHeadline)
                    .font(.system(size: 11, weight: .semibold))
                Text(presentation.unavailableExplanation)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(presentation.failure.diagnostics.enumerated()), id: \.offset) { offset, diagnostic in
                    VStack(alignment: .leading, spacing: 2) {
                        if let label = OracleFailureCardPresentation.diagnosticLabel(diagnostic) {
                            Text(label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(diagnostic.message)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if offset == 0, presentation.showsTruncationNote {
                            Text("(message truncated when saved)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        if let chatID = diagnostic.laneChatID,
                           let userInfo = AgentOracleToolRouting.operationPopoverUserInfo(
                               openContext: openContext,
                               chatID: chatID
                           )
                        {
                            Button {
                                NotificationCenter.default.post(
                                    name: .showAgentOraclePopover,
                                    object: nil,
                                    userInfo: userInfo
                                )
                            } label: {
                                Label("Open lane chat", systemImage: "bubble.left.and.bubble.right")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Open Oracle chat \(chatID)")
                        }
                    }
                }
            }
            if let omittedSummary = presentation.omittedSummary {
                Text(omittedSummary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let laneSummary = presentation.laneSummary {
                Text(laneSummary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatSendResultCard: View {
    let item: AgentChatItem
    let oracleOpenContext: AgentOracleOpenContext?
    let oracleToolCardContext: AgentOracleToolCardContext?

    /// Card-local disclosure for the failed branch only; always starts collapsed regardless of
    /// `agentToolCardAutoExpandEnabled`.
    @State private var isFailureExpanded = false

    private var normalizedToolName: String {
        (normalizedToolCardName(item.toolName) ?? "").lowercased()
    }

    private var isOracleTool: Bool {
        normalizedToolName == "ask_oracle" || normalizedToolName == "oracle_send"
    }

    private var isResumableOracleTool: Bool {
        normalizedToolName == "ask_oracle"
    }

    private var dto: ToolResultDTOs.ChatSendDTO? {
        ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON)
    }

    private var oraclePresentation: OracleToolCardPresentation? {
        guard isResumableOracleTool, let dto else { return nil }
        return OracleToolCardPresentation(
            dto: dto,
            resultObject: ToolJSON.structuredResultObject(from: item.toolResultJSON)
        )
    }

    /// Compact summary showing mode and a small amount of result context
    private var summary: String {
        oraclePresentation?.subtitle ?? dto.map(chatSendResultSummary) ?? ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let oraclePresentation {
            return oraclePresentation.state.visualStatus
        }
        if let dto {
            if let errors = dto.errors, !errors.isEmpty { return .failure }
            if dto.response == nil || dto.response?.isEmpty == true,
               let diffs = dto.diffs,
               !diffs.isEmpty
            {
                return .warning
            }
            return .success
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var onTap: (() -> Void)? {
        let chatID = oraclePresentation?.singleChatID
            ?? AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: item.toolResultJSON)
        guard let userInfo = AgentOracleToolRouting.operationPopoverUserInfo(
            openContext: oracleOpenContext,
            chatID: chatID
        ) else { return nil }
        return {
            NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
        }
    }

    /// Only failed Oracle cards become expandable (user decision 4); `chat_send` is unchanged.
    private var failurePresentation: OracleFailureCardPresentation? {
        guard isOracleTool else { return nil }
        return OracleFailureCardPresentation(item: item)
    }

    var body: some View {
        if let failurePresentation {
            failedCard(failurePresentation)
        } else {
            staticCard
        }
    }

    /// Failed branch: header tap toggles disclosure only; Open Oracle is a separate trailing
    /// control with its own hit target, present only when authoritative routing yields a chat.
    /// The live sidecar stays mounted beside the container so an invocation failure (for
    /// example a failed wait call) never hides a still-running operation.
    private func failedCard(_ presentation: OracleFailureCardPresentation) -> some View {
        let openAction = onTap
        return VStack(alignment: .leading, spacing: 4) {
            ToolCardContainer(
                iconName: toolIcon(for: item.toolName),
                iconColor: ToolCardAccentResolver.color(for: item.toolName),
                title: "Oracle",
                headerStatusText: OracleToolCardState.failed.displayLabel,
                subtitle: presentation.subtitle,
                status: .failure,
                timestamp: item.timestamp,
                headerTrailingView: openAction.map { action in
                    AnyView(OracleFailureOpenControl(timestamp: item.timestamp, action: action))
                },
                isExpandable: true,
                isExpanded: $isFailureExpanded
            ) {
                OracleFailureDetailsView(presentation: presentation, openContext: oracleOpenContext)
                if let oraclePresentation {
                    OracleToolCardChatLinks(
                        chatIDs: oraclePresentation.uniqueChatIDs,
                        openContext: oracleOpenContext
                    )
                }
            }
            if let oraclePresentation, let oracleToolCardContext {
                OracleToolCardLiveSidecar(
                    operationStore: oracleToolCardContext.operationStore,
                    lanes: oraclePresentation.lanes,
                    openContext: oracleOpenContext,
                    showsOpenChatAction: openAction == nil
                )
                .padding(.leading, 10)
            }
        }
    }

    private var staticCard: some View {
        StaticToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: isOracleTool ? "Oracle" : "Chat",
            subtitle: summary,
            status: status,
            timestamp: item.timestamp,
            onTap: onTap
        ) {
            if let oraclePresentation {
                if let oracleToolCardContext {
                    OracleToolCardLiveSidecar(
                        operationStore: oracleToolCardContext.operationStore,
                        lanes: oraclePresentation.lanes,
                        openContext: oracleOpenContext,
                        showsOpenChatAction: onTap == nil
                    )
                }
                OracleToolCardChatLinks(
                    chatIDs: oraclePresentation.uniqueChatIDs,
                    openContext: oracleOpenContext
                )
            }
        }
    }
}

struct ChatsResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ChatsReplyDTO? {
        ToolJSON.decode(ChatsReplyDTO.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        if let chats = dto?.chats, !chats.isEmpty {
            let visible = chats.prefix(2).compactMap { chat -> String? in
                let trimmed = chat.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : chat.id
            }
            guard !visible.isEmpty else { return nil }
            var parts = visible
            if chats.count > visible.count {
                parts.append("(+\(chats.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        return nil
    }

    private var summary: String {
        if let dto {
            if dto.action?.lowercased() == "log" {
                let chatID = dto.chatID ?? "chat"
                let messageCount = dto.messages?.count ?? 0
                return "\(chatID) • \(messageCount) messages"
            }
            if let count = dto.chats?.count {
                return "\(count) chats"
            }
        }
        if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ChatsArgs.self, from: item.toolArgsJSON)?.action,
           !action.isEmpty
        {
            return action
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            if dto.action?.lowercased() == "log" {
                return .success
            }
            if dto.chats != nil {
                return .success
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        let normalizedName = normalizedToolCardName(item.toolName)?.lowercased()
        let title = (normalizedName == "oracle_chat_log") ? "Oracle Log" : "Chats"
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct ListModelsResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.ListModelsReply? {
        ToolJSON.decode(ToolResultDTOs.ListModelsReply.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        guard let models = dto?.models, !models.isEmpty else { return nil }
        let visible = models.prefix(2).map(\.name)
        var parts = visible
        if models.count > visible.count {
            parts.append("(+\(models.count - visible.count) more)")
        }
        return parts.joined(separator: " • ")
    }

    private var summary: String {
        guard let dto else { return "" }
        return "\(dto.total) models"
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            return dto.total > 0 ? .success : .neutral
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Models",
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct ManageWorkspacesResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ManageWorkspacesResponse? {
        ToolJSON.decode(ManageWorkspacesResponse.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        guard let dto else { return nil }
        if let workspaces = dto.workspaces, !workspaces.isEmpty {
            let visible = workspaces.prefix(2).map(\.name)
            var parts = visible
            if workspaces.count > visible.count {
                parts.append("(+\(workspaces.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        if let tabs = dto.tabs, !tabs.isEmpty {
            let visible = tabs.prefix(2).map(\.name)
            var parts = visible
            if tabs.count > visible.count {
                parts.append("(+\(tabs.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        return nil
    }

    private var headerStatusText: String? {
        nil
    }

    private var summary: String {
        if let dto {
            var parts: [String] = [dto.action]
            if let workspaces = dto.workspaces {
                parts.append("\(workspaces.count) workspaces")
            }
            if let tabs = dto.tabs {
                parts.append("\(tabs.count) tabs")
            }
            if let windowID = dto.windowID {
                parts.append("window \(windowID)")
            }
            if let closedWindowID = dto.closedWindowID {
                parts.append("closed \(closedWindowID)")
            }
            return parts.joined(separator: " • ")
        }
        if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ManageWorkspacesArgs.self, from: item.toolArgsJSON)?.action {
            return action
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto, let status = dto.status, let mapped = ToolResultStatusResolver.mapStatusWord(status) {
            return mapped
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Workspaces",
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

private struct ChatsReplyDTO: Decodable {
    let action: String?
    let chats: [ChatSummaryDTO]?
    let chatID: String?
    let messages: [ChatMessageDTO]?

    enum CodingKeys: String, CodingKey {
        case action
        case chats
        case chatID = "chat_id"
        case messages
    }
}

private struct ChatSummaryDTO: Decodable {
    let id: String?
    let name: String?
    let messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case messageCount = "message_count"
    }
}

private struct ChatMessageDTO: Decodable {}
