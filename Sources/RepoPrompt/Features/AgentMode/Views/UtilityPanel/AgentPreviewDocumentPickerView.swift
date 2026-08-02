import SwiftUI

// SEARCH-HELPER: AgentPreviewDocumentPickerView, preview document browser, previewable file list

/// The browser shown by the Preview segment when no document is selected.
///
/// A searchable flat list rather than a tree: the panel is 320–560pt wide, and a document the user
/// wants is found by name far more often than by walking folders. Documents this session's agent
/// wrote are grouped first, because "show me what it just wrote" is the reason the panel exists.
struct AgentPreviewDocumentPickerView: View {
    let entries: [AgentPreviewPickerEntry]
    let onSelect: (AgentPreviewPickerEntry) -> Void

    @State private var query = ""
    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let horizontalPadding: CGFloat = 10
        static let rowSpacing: CGFloat = 1
        static let sectionSpacing: CGFloat = 10
        static let searchBottomPadding: CGFloat = 8
        static let searchGlyphSizeAtNormal: CGFloat = 10
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var visibleEntries: [AgentPreviewPickerEntry] {
        AgentPreviewDocumentPicker.filter(entries, query: query)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if entries.isEmpty {
                emptyInventory
            } else if visibleEntries.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: preset.scaledMetric(Layout.searchGlyphSizeAtNormal)))
                .foregroundStyle(.tertiary)

            TextField("Find a document", text: $query)
                .textFieldStyle(.plain)
                .font(preset.swiftUIFont(sizeAtNormal: 11))
                .accessibilityLabel("Find a document to preview")

            if isSearching {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: preset.scaledMetric(Layout.searchGlyphSizeAtNormal)))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.bottom, Layout.searchBottomPadding)
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                if isSearching {
                    // Searching flattens the grouping: the ranking already put the best answer
                    // first, and a section header between ranked results would fight it.
                    rows(visibleEntries)
                } else {
                    let artifacts = visibleEntries.filter(\.isSessionArtifact)
                    let workspaceDocuments = visibleEntries.filter { !$0.isSessionArtifact }
                    if !artifacts.isEmpty {
                        sectionHeader("Written This Session")
                        rows(artifacts)
                    }
                    if !workspaceDocuments.isEmpty {
                        sectionHeader(artifacts.isEmpty ? "Documents" : "In This Workspace")
                            .padding(.top, artifacts.isEmpty ? 0 : Layout.sectionSpacing)
                        rows(workspaceDocuments)
                    }
                }
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.bottom, Layout.horizontalPadding)
        }
    }

    private func rows(_ entries: [AgentPreviewPickerEntry]) -> some View {
        ForEach(entries) { entry in
            AgentPreviewPickerRow(entry: entry) {
                onSelect(entry)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(preset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Empty states

    private var emptyInventory: some View {
        AgentPreviewPickerMessage(
            symbolName: "doc.text",
            title: "No Documents Yet",
            message: "Markdown and HTML files in this workspace show up here, along with anything the agent writes."
        )
    }

    private var noMatches: some View {
        AgentPreviewPickerMessage(
            symbolName: "magnifyingglass",
            title: "No Matches",
            message: "Nothing in this workspace matches “\(query)”."
        )
    }
}

// MARK: - Row

private struct AgentPreviewPickerRow: View {
    let entry: AgentPreviewPickerEntry
    let onSelect: () -> Void

    private enum Layout {
        static let glyphSizeAtNormal: CGFloat = 10
        static let glyphWidthAtNormal: CGFloat = 13
    }

    @State private var isHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Image(systemName: entry.kind.symbolName)
                    .font(.system(size: preset.scaledMetric(Layout.glyphSizeAtNormal)))
                    .foregroundStyle(.secondary)
                    .frame(width: preset.scaledMetric(Layout.glyphWidthAtNormal))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.fileName)
                        .font(preset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(entry.directoryPath)
                        .font(preset.swiftUIFont(sizeAtNormal: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .hoverTooltip(entry.relativePath)
        .accessibilityLabel("\(entry.fileName), \(entry.directoryPath)")
        .accessibilityHint("Opens this document in the preview")
    }
}

// MARK: - Message

private struct AgentPreviewPickerMessage: View {
    let symbolName: String
    let title: String
    let message: String

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: preset.scaledMetric(20), weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(preset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(preset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .agentSidebarCard()
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}
