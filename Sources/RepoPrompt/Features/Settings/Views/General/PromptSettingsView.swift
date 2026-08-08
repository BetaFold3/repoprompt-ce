//
//  PromptSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-16.
//

import SwiftUI

struct PromptSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Prompt Packaging
                SettingSection(
                    title: "Prompt Packaging",
                    description: "Configure prompt assembly behavior"
                ) {
                    SettingToggle(
                        title: "Include datetime in user instructions",
                        description: "Add a timestamp attribute to user instruction tags when packaging prompts",
                        isOn: $promptViewModel.includeDatetimeInUserInstructions
                    )
                }

                Divider()

                // Saved Prompts Section
                SettingSection(
                    title: "Saved Prompts",
                    description: "Manage your saved instruction prompts. Reset to defaults if you're experiencing issues."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            // Export Prompts
                            Button("Export Prompts") {
                                let savePanel = NSSavePanel()
                                savePanel.title = "Export Saved Prompts"
                                savePanel.prompt = "Export"
                                savePanel.nameFieldStringValue = "SavedPrompts.json"

                                if savePanel.runModal() == .OK, let url = savePanel.url {
                                    do {
                                        try promptViewModel.exportPrompts(to: url)
                                    } catch {
                                        let alert = NSAlert()
                                        alert.messageText = "Export Failed"
                                        alert.informativeText = error.localizedDescription
                                        alert.alertStyle = .warning
                                        alert.runModal()
                                    }
                                }
                            }
                            .buttonStyle(CustomButtonStyle())
                            .frame(minWidth: 120)

                            // Import Prompts
                            Button("Import Prompts") {
                                let openPanel = NSOpenPanel()
                                openPanel.title = "Import Saved Prompts"
                                openPanel.prompt = "Import"
                                openPanel.allowedFileTypes = ["json"]
                                openPanel.canChooseFiles = true
                                openPanel.canChooseDirectories = false

                                if openPanel.runModal() == .OK, let url = openPanel.url {
                                    do {
                                        let addedCount = try promptViewModel.importPrompts(from: url)
                                        let alert = NSAlert()
                                        alert.messageText = "Import Complete"
                                        alert.informativeText = "Successfully added \(addedCount) new prompt(s)."
                                        alert.runModal()
                                    } catch {
                                        let alert = NSAlert()
                                        alert.messageText = "Import Failed"
                                        alert.informativeText = error.localizedDescription
                                        alert.alertStyle = .warning
                                        alert.runModal()
                                    }
                                }
                            }
                            .buttonStyle(CustomButtonStyle())
                            .frame(minWidth: 120)

                            // Reset Button
                            Button("Reset Prompts") {
                                // Ask for confirmation first
                                let alert = NSAlert()
                                alert.messageText = "Reset Saved Prompts"
                                alert.informativeText = "This will remove all custom prompts and restore the default prompts. This action cannot be undone."
                                alert.alertStyle = .warning
                                alert.addButton(withTitle: "Reset")
                                alert.addButton(withTitle: "Cancel")

                                let response = alert.runModal()
                                if response == .alertFirstButtonReturn {
                                    do {
                                        try promptViewModel.resetUserPrompts()
                                    } catch {
                                        let failureAlert = NSAlert()
                                        failureAlert.messageText = "Reset Failed"
                                        failureAlert.informativeText = error.localizedDescription
                                        failureAlert.alertStyle = .warning
                                        failureAlert.runModal()
                                    }
                                }
                            }
                            .buttonStyle(CustomButtonStyle())
                            .hoverTooltip("Clears all user-defined prompts and restores the default built-in prompts.")
                            .frame(minWidth: 120)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
