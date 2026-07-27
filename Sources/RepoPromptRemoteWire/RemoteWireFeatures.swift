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

    /// Host accepts `include_host_row_ids: true` in the `get_log` payload and emits
    /// per-row host identifiers in the returned `transcript_xml`.
    public static let getLogHostRowIDs = "get_log_host_row_ids"

    /// Host accepts the mutating `fork_session` frame.
    public static let forkSession = "fork_session"

    /// Host accepts the read-only `extract_handoff` frame.
    public static let extractHandoff = "extract_handoff"

    /// Every feature the current host build supports, sorted for canonical output.
    public static let all: [String] = [
        extractHandoff,
        forkSession,
        getLogHostRowIDs,
        getLogRowTimestamps
    ].sorted()
}
