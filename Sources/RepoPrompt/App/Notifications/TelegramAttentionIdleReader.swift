import CoreGraphics
import Foundation

// Event-time Mac input idle sampling for attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 8).
//
// Read-only: one CoreGraphics query of the combined session state for any input event type. No
// event tap, focus check, or permission request. Called only when an automatic event is captured.

enum TelegramAttentionIdleReader {
    /// Seconds since the last keyboard, mouse, or other input event, or nil when unreadable.
    static func secondsSinceLastInput() -> TimeInterval? {
        // `kCGAnyInputEventType` (~0) is a sentinel, not a named `CGEventType` case.
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return sanitized(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
    }

    /// Only finite, nonnegative readings count; anything else means unreadable.
    static func sanitized(_ seconds: Double) -> TimeInterval? {
        seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
