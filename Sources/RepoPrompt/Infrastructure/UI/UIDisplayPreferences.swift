import Combine
import Foundation

/// Live display preferences read by shared UI components (tooltips, markdown code
/// blocks). The App layer owns persistence and forwards current values here, so
/// these views do not depend on the settings store directly.
@MainActor
final class UIDisplayPreferences: ObservableObject {
    static let shared = UIDisplayPreferences()

    /// Whether hover tooltips are shown. Default matches the persisted-settings default.
    @Published private(set) var showTooltips: Bool = true

    /// Optional PostScript face for transcript code/diff rendering. `nil` = system monospaced.
    @Published private(set) var transcriptCodeFontPostScriptName: String?

    /// Applies values forwarded by the settings owner, publishing only fields that changed.
    func apply(showTooltips: Bool, transcriptCodeFontPostScriptName: String?) {
        if self.showTooltips != showTooltips {
            self.showTooltips = showTooltips
        }
        if self.transcriptCodeFontPostScriptName != transcriptCodeFontPostScriptName {
            self.transcriptCodeFontPostScriptName = transcriptCodeFontPostScriptName
        }
    }
}
