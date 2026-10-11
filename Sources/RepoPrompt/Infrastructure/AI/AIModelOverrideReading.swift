import Foundation

/// Read-only access to the user's per-model overrides consumed by agent/AI code.
///
/// Agent code receives a conforming value by injection; the App composition root
/// supplies the concrete settings-backed reader.
protocol AIModelOverrideReading: Sendable {
    func streamOverride(for modelRaw: String) -> Bool?
    func responsesOverride(for modelRaw: String) -> Bool?
    func temperatureOverride(for modelRaw: String) -> Double?
}
