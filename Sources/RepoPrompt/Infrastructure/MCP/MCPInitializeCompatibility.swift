import Foundation

/// The pinned Swift MCP SDK models experimental client capabilities as strings,
/// although MCP defines object-valued extensions. Unsupported extensions must not
/// prevent standard capability negotiation. Remove this adapter when the SDK's
/// Client.Capabilities.experimental can decode arbitrary JSON.
enum MCPInitializeCompatibility {
    static func sdkCompatibleFrame(_ frame: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              request["method"] as? String == "initialize",
              request["id"] != nil,
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any]
        else {
            return frame
        }

        // CE implements no structured experimental client capability. Keep the
        // SDK-supported string entries; do not turn an unknown extension into a
        // claimed capability or alter standard capabilities or client identity.
        let supported = experimental.compactMapValues { $0 as? String }
        guard supported.count != experimental.count else { return frame }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? frame
    }
}
