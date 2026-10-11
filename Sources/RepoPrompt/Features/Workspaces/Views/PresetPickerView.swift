import RepoPromptUI
import SwiftUI

struct PresetPickerView: View {
    @StateObject var workspaceManager: WorkspaceManagerViewModel
    @Binding var isPresented: Bool
    @State private var newPresetName = ""
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        // Safely unwrap the currently-active workspace from the manager
        if let workspace = workspaceManager.activeWorkspace {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a Preset")
                    .font(fontPreset.headlineFont)

                // Show existing presets
                ForEach(workspace.presets) { preset in
                    Button(action: {
                        Task {
                            await workspaceManager.applyPreset(preset.id)
                            isPresented = false
                        }
                    }) {
                        Text(preset.name)
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.vertical, 8)

                Text("Create a New Preset")
                    .font(fontPreset.subheadlineFont)

                HStack {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Button(action: {
                        let finalName = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !finalName.isEmpty else { return }

                        Task {
                            await workspaceManager.createPreset(for: workspace, name: finalName)
                            newPresetName = ""
                            isPresented = false
                        }
                    }) {
                        Text("Create")
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: fontPreset.scaledMetric(220))
        } else {
            // If there's no active workspace, show a fallback
            VStack(spacing: 8) {
                Text("No active workspace found.")
                Button("Close") {
                    isPresented = false
                }
            }
            .padding()
            .frame(width: fontPreset.scaledMetric(220))
        }
    }
}
