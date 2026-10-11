import RepoPromptUI
import SwiftUI

/// A simple sheet that asks the user for a preset name, then creates it via
/// `WorkspaceManagerViewModel`.  UI intentionally matches the rename-preset sheet.
struct PresetCreationSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
    /// Workspace in which the preset will be created
    let workspace: WorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Preset")
                .font(fontPreset.headlineFont)

            TextField("Preset name", text: $name)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(minWidth: fontPreset.scaledMetric(200))
                .onSubmit {
                    // Trigger save on Return/Enter, mimicking clicking the Save button
                    save()
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.return)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: fontPreset.scaledMetric(360))
        // Allow pressing Esc to close the sheet
        .onExitCommand {
            dismiss()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        Task {
            await workspaceManager.createPreset(for: workspace, name: trimmedName)
            dismiss()
        }
    }
}
