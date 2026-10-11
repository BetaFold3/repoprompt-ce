import Foundation

package enum CLIOutputFormat: String {
    case text
    case json
    case streamJson = "stream-json"

    var tokens: [String] {
        ["--output-format", rawValue]
    }
}
