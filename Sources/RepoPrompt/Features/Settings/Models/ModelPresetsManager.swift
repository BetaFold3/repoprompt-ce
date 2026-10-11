import Foundation
import RepoPromptAgentCore

// App-owned: persists model presets through `PresetFileStore`.

// MARK: - ModelPresetsManager

/// Manages storage and retrieval of model presets
@MainActor
class ModelPresetsManager: ObservableObject {
    static let shared = ModelPresetsManager()

    private let presetFileStore = PresetFileStore.shared

    @Published var presets: [ModelPreset] = []

    private init() {
        loadPresets()
    }

    /// Loads presets from Application Support JSON.
    private func loadPresets() {
        presets = presetFileStore.loadModelPresets().modelPresets
    }

    /// Saves presets to Application Support JSON.
    private func savePresets() {
        presetFileStore.saveModelPresets(
            PresetFileStore.ModelPresetDocument(modelPresets: presets)
        )
    }

    /// Adds a new preset
    func addPreset(_ preset: ModelPreset) {
        presets.append(preset)
        savePresets()
    }

    /// Updates an existing preset
    func updatePreset(_ preset: ModelPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            savePresets()
        }
    }

    /// Removes a preset
    func removePreset(_ preset: ModelPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    /// Removes presets at the specified offsets
    func removePresets(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        savePresets()
    }

    /// Moves presets for reordering
    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        savePresets()
    }

    /// Returns available presets for a specific mode
    func availablePresets(for mode: String) -> [ModelPreset] {
        presets.filteredForMode(mode)
    }

    /// Returns a preset by name (case-insensitive)
    func preset(named name: String) -> ModelPreset? {
        presets.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Returns a preset by ID
    func preset(withID id: UUID) -> ModelPreset? {
        presets.first { $0.id == id }
    }

    /// Returns a thread-safe copy of all presets
    /// Since ModelPreset is Sendable, this array can be safely passed across actor boundaries
    func allPresets() -> [ModelPreset] {
        // Returns a copy of the array, safe to use across actors
        presets
    }

    /// Returns a thread-safe copy of presets available for a specific mode
    func getAvailablePresets(for mode: String) -> [ModelPreset] {
        availablePresets(for: mode)
    }
}
