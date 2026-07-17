import Foundation

/// Optional host feature strings advertised in the `hello_ack` payload's `features` array.
///
/// Clients must treat a missing or non-array `features` key as the empty set and ignore
/// unknown strings, so features remain strictly additive wire evolution. Hosts advertise
/// `all` on every hello_ack; per-feature negotiation happens by the client opting in on
/// the relevant command payloads.
public enum RemoteWireFeatures {
    /// Host accepts `include_row_timestamps: true` in the `get_log` payload and emits
    /// per-row `ts` attributes (Unix epoch seconds) in the returned `transcript_xml`.
    public static let getLogRowTimestamps = "get_log_row_timestamps"

    /// Every feature the current host build supports, sorted for canonical output.
    public static let all: [String] = [
        getLogRowTimestamps
    ].sorted()
}
