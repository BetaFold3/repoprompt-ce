import Foundation
import RepoPromptRemoteWire

struct RemoteStartWindowOption: Identifiable, Equatable {
    let windowID: Int
    let title: String
    let workspaceID: String?
    let workspaceName: String?

    var id: Int {
        windowID
    }

    var subtitle: String? {
        workspaceName ?? workspaceID
    }

    static func options(from details: JSONValue?) -> [RemoteStartWindowOption] {
        guard let windows = details?.objectValue?["windows"]?.arrayValue else { return [] }
        return windows.compactMap { value in
            guard let object = value.objectValue else { return nil }
            let windowID = object["window_id"]?.intValue
                ?? object["id"]?.intValue
                ?? object["windowID"]?.intValue
            guard let windowID else { return nil }
            let title = object["title"]?.stringValue
                ?? object["name"]?.stringValue
                ?? "Window \(windowID)"
            let workspaceID = object["workspace_id"]?.stringValue
                ?? object["workspaceID"]?.stringValue
            let workspaceName = object["workspace_name"]?.stringValue
                ?? object["workspaceName"]?.stringValue
                ?? object["workspace"]?.stringValue
            return RemoteStartWindowOption(
                windowID: windowID,
                title: title,
                workspaceID: workspaceID,
                workspaceName: workspaceName
            )
        }
    }
}

struct RemoteStartWindowPickerState: Identifiable, Equatable {
    let id: UUID
    let tabID: UUID
    let hostName: String
    let message: String
    let modelSelectionRaw: String?
    let sessionName: String?
    let workspaceName: String?
    let optimisticUserItemID: UUID
    let windows: [RemoteStartWindowOption]

    var openableWorkspaceName: String? {
        guard let workspaceName else { return nil }
        let matchesExisting = windows.contains { option in
            option.workspaceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(workspaceName) == .orderedSame
        }
        return matchesExisting ? nil : workspaceName
    }

    init(
        id: UUID = UUID(),
        tabID: UUID,
        hostName: String,
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        workspaceName: String?,
        optimisticUserItemID: UUID,
        windows: [RemoteStartWindowOption]
    ) {
        self.id = id
        self.tabID = tabID
        self.hostName = hostName
        self.message = message
        self.modelSelectionRaw = modelSelectionRaw
        self.sessionName = sessionName
        let trimmedWorkspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceName = trimmedWorkspaceName?.isEmpty == false ? trimmedWorkspaceName : nil
        self.optimisticUserItemID = optimisticUserItemID
        self.windows = windows
    }

    init?(
        error: Error,
        tabID: UUID,
        hostName: String,
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        workspaceName: String?,
        optimisticUserItemID: UUID
    ) {
        guard let commandError = Self.targetCommandError(from: error) else { return nil }
        let windows = Self.deduped(RemoteStartWindowOption.options(from: commandError.details))
        guard !windows.isEmpty else { return nil }
        self.init(
            tabID: tabID,
            hostName: hostName,
            message: message,
            modelSelectionRaw: modelSelectionRaw,
            sessionName: sessionName,
            workspaceName: workspaceName,
            optimisticUserItemID: optimisticUserItemID,
            windows: windows
        )
    }

    static func isTargetError(_ error: Error) -> Bool {
        targetCommandError(from: error) != nil
    }

    private static func targetCommandError(from error: Error) -> RemoteCommandError? {
        guard let remoteError = error as? RemoteClientError,
              let commandError = remoteError.commandError
        else { return nil }
        switch remoteError {
        case .bindingRequired, .ambiguousStartTarget:
            return commandError
        default:
            return ["workspace_mismatch", "workspace_not_open"].contains(commandError.code)
                ? commandError
                : nil
        }
    }

    private static func deduped(_ options: [RemoteStartWindowOption]) -> [RemoteStartWindowOption] {
        var seen = Set<Int>()
        var result: [RemoteStartWindowOption] = []
        for option in options where seen.insert(option.windowID).inserted {
            result.append(option)
        }
        return result
    }
}
