import Foundation
import SwiftUI

/// Notice above a parent agent's composer listing child questions addressed to this agent
/// (delegated ask_user plan §6.5). It exists for legibility only: it never takes focus, never
/// answers, and is not a transcript item. **Open** selects the child tab after verifying the
/// question is still pending.
struct AgentDelegatedQuestionsBanner: View {
    static let maximumVisibleRows = 3
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 2
    static let verticalChrome: CGFloat = 12

    let rows: [AgentDelegatedQuestionBannerRow]
    let actions: AgentDelegatedQuestionBannerActions

    @State private var actionError: (rowID: AgentDelegatedQuestionNoticeKey, message: String)?
    @State private var inFlightRowID: AgentDelegatedQuestionNoticeKey?

    /// Height reserved by the composer so the banner never shifts the editor unexpectedly.
    static func reservedHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let visibleRows = min(rowCount, maximumVisibleRows) + (rowCount > maximumVisibleRows ? 1 : 0)
        return CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows - 1) * rowSpacing + verticalChrome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(rows.prefix(Self.maximumVisibleRows))) { row in
                let error = actionError?.rowID == row.id ? actionError?.message : nil
                HStack(spacing: 8) {
                    Image(systemName: row.status == .delivered ? "questionmark.bubble.fill" : "questionmark.bubble")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text(error ?? row.text)
                        .font(.system(size: 11, weight: error == nil ? .medium : .semibold))
                        .foregroundStyle(error == nil ? Color.primary : Color.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hoverTooltip(row.text)
                    Button("Open") {
                        open(row)
                    }
                    .controlSize(.small)
                    .disabled(inFlightRowID != nil)
                    .accessibilityIdentifier("agent.delegatedQuestions.open")
                }
                .frame(height: Self.rowHeight)
                .accessibilityElement(children: .combine)
            }
            if rows.count > Self.maximumVisibleRows {
                Text("+\(rows.count - Self.maximumVisibleRows) more child questions")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityIdentifier("agent.delegatedQuestions.banner")
        .onChange(of: rows) { _, _ in
            actionError = nil
        }
    }

    private func open(_ row: AgentDelegatedQuestionBannerRow) {
        guard inFlightRowID == nil else { return }
        inFlightRowID = row.id
        actionError = nil
        Task { @MainActor in
            if let message = await actions.openChild(row) {
                actionError = (row.id, message)
            }
            inFlightRowID = nil
        }
    }
}
