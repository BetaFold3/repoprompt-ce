import Foundation

/// Named OMP normalization seam. Captured OMP protocol shapes currently conform to
/// standard ACP session/update payloads, so provider-specific rewriting is deliberately absent.
enum OhMyPiACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .ohMyPi)
    }
}
