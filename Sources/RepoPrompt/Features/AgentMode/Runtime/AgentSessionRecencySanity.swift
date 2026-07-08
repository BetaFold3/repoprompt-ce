import Foundation

/// Remote transcript projection historically synthesized epoch-era timestamps from sequence indexes
/// (`Date(timeIntervalSince1970: sequenceIndex)`). This floor lets consumers ignore those synthetic
/// values; the app didn't exist before 2020 so genuine session dates are never floored.
enum AgentSessionRecencySanity {
    static let syntheticTimestampFloor = Date(timeIntervalSince1970: 1_577_836_800)

    static func plausibleRecencyDate(_ date: Date?) -> Date? {
        guard let date, date >= syntheticTimestampFloor else { return nil }
        return date
    }
}
