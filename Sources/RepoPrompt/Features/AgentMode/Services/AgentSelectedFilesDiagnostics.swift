import Foundation
import RepoPromptWorkspace

/// Agent-typed field helpers for `AgentSelectedFilesDiagnostics`. The dependency-free recording
/// helpers (`event`, `durationEvent`, `timestampMSIfEnabled`, `elapsedFields`, `shortID`) live in
/// `Infrastructure/WorkspaceContext/AgentSelectedFilesDiagnosticsCore.swift`.
extension AgentSelectedFilesDiagnostics {
    static func selectionFields(_ selection: StoredSelection) -> [String: String] {
        #if DEBUG
            let nonEmptySlices = selection.slices.filter { !$0.value.isEmpty }
            let sliceRanges = nonEmptySlices.values.reduce(0) { $0 + $1.count }
            return [
                "selectedPaths": String(selection.selectedPaths.count),
                "manualCodemapPaths": String(selection.manualCodemapPaths.count),
                "sliceFiles": String(nonEmptySlices.count),
                "sliceRanges": String(sliceRanges),
                "codemapAutoEnabled": String(selection.codemapAutoEnabled)
            ]
        #else
            [:]
        #endif
    }

    static func sourceFields(_ source: AgentContextExportSource) -> [String: String] {
        #if DEBUG
            var fields = selectionFields(source.selection)
            fields["tabID"] = shortID(source.tabID)
            fields["activeAgentSessionID"] = shortID(source.activeAgentSessionID)
            fields["bindingCount"] = String(source.worktreeBindings.count)
            fields["bindingFingerprint"] = String(source.exportContextIdentity.worktreeBindingFingerprint.prefix(16))
            fields["promptChars"] = String(source.promptText.count)
            return fields
        #else
            [:]
        #endif
    }

    static func requestFields(_ request: AgentSelectedFilesModelRequest) -> [String: String] {
        #if DEBUG
            var fields = sourceFields(request.source)
            fields["filePathDisplay"] = String(describing: request.filePathDisplay)
            fields["codeMapUsage"] = String(describing: request.codeMapUsage)
            return fields
        #else
            [:]
        #endif
    }
}
