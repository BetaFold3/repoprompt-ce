import Foundation

enum AppQuitRequestPhase: Equatable {
    case idle
    case awaitingConfirmation
    case terminating
}

enum AppQuitRequestDecision: Equatable {
    case showConfirmation(AppQuitConfirmation)
    case beginTermination
    case awaitCurrentRequest
}

struct AppQuitConfirmation: Equatable {
    let title: String
    let message: String
    let cancelButtonTitle: String
    let confirmButtonTitle: String
}

enum AppQuitPolicy {
    static func decide(
        warningEnabled: Bool,
        suppressesConfirmation: Bool,
        phase: AppQuitRequestPhase,
        activeItems: [WindowCloseActivityItem]
    ) -> AppQuitRequestDecision {
        guard phase == .idle else {
            return .awaitCurrentRequest
        }
        guard warningEnabled, !suppressesConfirmation else {
            return .beginTermination
        }

        let items = consolidatedActiveItems(activeItems)
        var message = "Are you sure you want to quit RepoPrompt?"
        if !items.isEmpty {
            message += " Quitting will end \(summaryText(for: items))."
        }
        return .showConfirmation(
            AppQuitConfirmation(
                title: "Quit RepoPrompt?",
                message: message,
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Quit"
            )
        )
    }

    static func consolidatedActiveItems(
        _ items: [WindowCloseActivityItem]
    ) -> [WindowCloseActivityItem] {
        var itemsByID: [String: WindowCloseActivityItem] = [:]
        for item in items where item.count > 0 {
            if let existing = itemsByID[item.id] {
                itemsByID[item.id] = WindowCloseActivityItem(
                    id: item.id,
                    count: existing.count + item.count,
                    singularLabel: existing.singularLabel,
                    pluralLabel: existing.pluralLabel
                )
            } else {
                itemsByID[item.id] = item
            }
        }
        return itemsByID.values.sorted { $0.id < $1.id }
    }

    private static func summaryText(for items: [WindowCloseActivityItem]) -> String {
        items.map { $0.formattedCount() }.joined(separator: " and ")
    }
}
