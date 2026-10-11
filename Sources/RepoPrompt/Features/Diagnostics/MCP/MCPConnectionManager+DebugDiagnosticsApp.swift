// MARK: - DEBUG App Diagnostics

import Foundation
import MCP
import RepoPromptUI

#if DEBUG
    extension ServerNetworkManager {
        func debugFontScaleMetricsPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            #if DEBUG
                if let enable = debugBool(arguments, "enable") {
                    FontScalePerfDiagnostics.setDebugProcessOverrideEnabled(enable)
                }
                if debugBool(arguments, "clear") == true {
                    FontScalePerfDiagnostics.clearRecentMetrics()
                }
                if debugBool(arguments, "emit_probe") == true {
                    FontScalePerfDiagnostics.event("fontScale.metrics.probe", fields: ["source": "debugDiagnostics"])
                }
                let mark = debugString(arguments, "mark")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let mark, !mark.isEmpty {
                    FontScalePerfDiagnostics.event("fontScale.metrics.mark", fields: ["mark": mark])
                }

                let limit: Int
                switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1 ... 1000) {
                case let .value(parsed), let .defaulted(parsed):
                    limit = parsed
                case .invalid:
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
                }

                let fontState = await MainActor.run { () -> (current: FontScalePreset, manager: FontScalePreset, isFrozen: Bool) in
                    (FontScalePreset.current, FontScaleManager.shared.preset, FontScaleManager.shared.isFrozen)
                }
                var payload = FontScalePerfDiagnostics.debugStateSnapshot(
                    lineLimit: limit,
                    currentPreset: fontState.current,
                    managerPreset: fontState.manager,
                    managerIsFrozen: fontState.isFrozen
                )
                payload["ok"] = true
                payload["op"] = op
                if let mark, !mark.isEmpty {
                    payload["mark"] = mark
                }
                return debugDiagnosticsResult(payload)
            #else
                return debugDiagnosticsError(op: op, code: "unavailable", message: "`font_scale_metrics` is only available in DEBUG builds.")
            #endif
        }
    }
#endif
