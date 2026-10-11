import Foundation

enum SortMethod: String, CaseIterable {
    case nameAscending
    case nameDescending
    case extensionAscending
    case extensionDescending
    case dateNewest
    case dateOldest
    case tokenAscending
    case tokenDescending

    static var selectedFilesAllowed: [SortMethod] {
        [
            .nameAscending,
            .nameDescending,
            .tokenAscending,
            .tokenDescending
        ]
    }

    static var fileTreeAllowed: [SortMethod] {
        [
            .nameAscending,
            .nameDescending,
            .extensionAscending,
            .extensionDescending,
            .dateNewest,
            .dateOldest
        ]
    }

    var icon: String {
        switch self {
        case .nameAscending:
            "arrow.up"
        case .nameDescending:
            "arrow.down"
        case .extensionAscending:
            "arrow.up.doc"
        case .extensionDescending:
            "arrow.down.doc"
        case .dateNewest:
            "arrow.down.circle"
        case .dateOldest:
            "arrow.up.circle"
        case .tokenAscending:
            "chart.bar"
        case .tokenDescending:
            "chart.bar.fill"
        }
    }

    var displayName: String {
        switch self {
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .extensionAscending: "Extension (A–Z)"
        case .extensionDescending: "Extension (Z–A)"
        case .dateNewest: "Date (Newest)"
        case .dateOldest: "Date (Oldest)"
        case .tokenAscending: "Tokens (Low–High)"
        case .tokenDescending: "Tokens (High–Low)"
        }
    }
}

extension String {
    var fileExtension: String? {
        let components = components(separatedBy: ".")
        return components.count > 1 ? components.last : nil
    }
}
