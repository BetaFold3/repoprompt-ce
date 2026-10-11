import Foundation

extension Notification.Name {
    static let codexReasoningSummariesDidChange = Notification.Name("RepoPrompt.codexReasoningSummariesDidChange")
}

package enum CodexReasoningSummaries {
    static let defaultsKey = "enableCodexReasoningSummaries"

    package static func isEnabled(defaults: UserDefaults) -> Bool {
        isEnabled(persistedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }

    package static func isEnabled(persistedValue: Bool) -> Bool {
        isEnabled(persistedValue: Optional(persistedValue))
    }

    package static func isEnabled(persistedValue: Bool?) -> Bool {
        persistedValue ?? false
    }

    package static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        let oldValue = isEnabled(defaults: defaults)
        defaults.set(value, forKey: defaultsKey)
        postDidChangeIfNeeded(previousValue: oldValue, currentValue: isEnabled(defaults: defaults))
    }

    package static func postDidChangeIfNeeded(previousValue: Bool, currentValue: Bool) {
        guard currentValue != previousValue else { return }
        NotificationCenter.default.post(name: .codexReasoningSummariesDidChange, object: nil)
    }
}
