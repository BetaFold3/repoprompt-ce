package enum GitDiffInclusionMode: String, CaseIterable, Codable {
    case none
    case selectedFiles
    case all

    var displayName: String {
        switch self {
        case .none: "None"
        case .selectedFiles: "Selected"
        case .all: "All"
        }
    }
}
