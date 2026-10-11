import Foundation

struct StoredSelection: Codable, Equatable, Hashable {
    let selectedPaths: [String]
    let manualCodemapPaths: [String]
    let slices: [String: [LineRange]]
    let codemapAutoEnabled: Bool

    init(
        selectedPaths: [String] = [],
        manualCodemapPaths: [String] = [],
        slices: [String: [LineRange]] = [:],
        codemapAutoEnabled: Bool = true
    ) {
        self.selectedPaths = selectedPaths
        self.manualCodemapPaths = manualCodemapPaths
        self.slices = slices
        self.codemapAutoEnabled = codemapAutoEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selectedPaths: container.decodeIfPresent([String].self, forKey: .selectedPaths) ?? [],
            manualCodemapPaths: container.decodeIfPresent([String].self, forKey: .manualCodemapPaths) ?? [],
            slices: container.decodeIfPresent([String: [LineRange]].self, forKey: .slices) ?? [:],
            codemapAutoEnabled: container.decodeIfPresent(Bool.self, forKey: .codemapAutoEnabled) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedPaths, forKey: .selectedPaths)
        try container.encode(manualCodemapPaths, forKey: .manualCodemapPaths)
        try container.encode([String](), forKey: .autoCodemapPaths)
        try container.encode(slices, forKey: .slices)
        try container.encode(codemapAutoEnabled, forKey: .codemapAutoEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPaths
        case manualCodemapPaths
        case autoCodemapPaths
        case slices
        case codemapAutoEnabled
    }
}
