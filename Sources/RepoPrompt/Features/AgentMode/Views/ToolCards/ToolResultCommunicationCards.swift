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

enum OracleToolCardState: String, Equatable, Hashable {
    case pending
    case cancelling
    case completed
    case cancelled
    case failed

    var displayLabel: String {
        switch self {
        case .pending: "Last reported pending"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    var visualStatus: ToolCardStatus {
        switch self {
        case .pending, .cancelling, .cancelled: .warning
        case .completed: .success
        case .failed: .failure
        }
    }
}

struct OracleToolCardLanePresentation: Equatable {
    let operationID: String?
    let chatID: String?
    let state: OracleToolCardState
    let contextSummary: String

    init(dto: ToolResultDTOs.ChatSendDTO) {
        operationID = nonEmptyOracleToolCardText(dto.operationID)
        chatID = nonEmptyOracleToolCardText(dto.chatID)
        state = Self.state(for: dto)
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
        [state.displayLabel, nonEmptyOracleToolCardText(contextSummary)]
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
        if lanes.contains(where: { $0.state == .cancelled }) { return .cancelled }
        return .completed
    }

    var subtitle: String {
        let base: String
        if lanes.count == 1 {
            base = lanes[0].subtitle
        } else {
            let counts = Dictionary(grouping: lanes, by: \.state).mapValues(\.count)
            let order: [OracleToolCardState] = [.failed, .cancelling, .pending, .cancelled, .completed]
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
            case .starting, .running:
                "Oracle running · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .cancelling:
                "Oracle cancelling · \(Self.elapsedLabel(summary.elapsed(at: now)))"
            case .ready, .failed, .cancelled:
                "Oracle finished — not yet collected"
            }
        }

        if let chatName = nonEmptyOracleToolCardText(summary.chatName) {
            text = "\(statusText) • \(chatName)"
        } else {
            text = statusText
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
            guard lane.state == .pending || lane.state == .cancelling,
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

struct ChatSendResultCard: View {
    let item: AgentChatItem
    let oracleOpenContext: AgentOracleOpenContext?
    let oracleToolCardContext: AgentOracleToolCardContext?

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

    var body: some View {
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
