import Foundation

// MARK: - Mode-support helpers

// Centralised, zero-cost helpers to determine whether a model preset
// (or its SupportedModes wrapper) can be used for a given operation mode.
// Keeping this logic here eliminates switch-statement duplication.
//
// The helpers accept `String` to avoid leaking UI-level enums and to
// remain source-compatible with existing call-sites that already pass
// string literals like "chat", "plan", or "review".
//

extension SupportedModes {
    /// Returns `true` if this instance allows the requested mode.
    /// Unknown modes default to `true` (maintains existing behaviour).
    func supports(mode: String) -> Bool {
        switch mode.lowercased() {
        case "chat": chat
        case "plan": plan
        case "review": review
        default: true
        }
    }
}

package extension ModelPreset {
    /// Convenience wrapper for `SupportedModes.supports(mode:)`.
    /// If `supportedModes == nil` the preset is unrestricted.
    func supports(mode: String) -> Bool {
        guard let supportedModes else { return true }
        return supportedModes.supports(mode: mode)
    }
}

package extension [ModelPreset] {
    /// Filters the collection, returning only presets compatible with `mode`.
    func filteredForMode(_ mode: String) -> [ModelPreset] {
        filter { $0.supports(mode: mode) }
    }
}
