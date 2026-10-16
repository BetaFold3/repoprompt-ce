import Foundation
import RepoPromptAgentCore

// Paced Telegram delivery for admitted attention events
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 4).
//
// One immutable credential/client snapshot per configuration; replacements share one pacer, so
// reconfiguring never resets the rate limit. The queue head waits for its first message before
// admission (`prepareForAdmission`); later parts wait before their POST. Parts are sent in order,
// one POST attempt each, never retried, and the attempt stops at the first unconfirmed part.
// Nothing here is wired to live events or reads secure storage.

/// Monotonic time source for pacing: elapsed time since an arbitrary origin, and a wait.
struct TelegramAttentionPacingClock {
    let now: @Sendable () -> Duration
    let wait: @Sendable (Duration) async -> Void

    static func continuous() -> TelegramAttentionPacingClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return TelegramAttentionPacingClock(
            now: { origin.duration(to: clock.now) },
            wait: { try? await clock.sleep(for: $0) }
        )
    }
}

/// Service-lifetime spacing between Telegram requests (about one per second per chat, three
/// seconds in groups). Time is marked when a request is initiated, not when it responds.
actor TelegramAttentionPacer {
    static let privateChatSpacing: Duration = .seconds(1)
    static let groupChatSpacing: Duration = .seconds(3)

    private let clock: TelegramAttentionPacingClock
    private var nextEligible: Duration?

    init(clock: TelegramAttentionPacingClock = .continuous()) {
        self.clock = clock
    }

    /// Positive numeric chat IDs are private chats; negative IDs and `@channel` names are groups
    /// or channels and get the slower group spacing.
    static func spacing(for chatID: TelegramChatID) -> Duration {
        if case let .numeric(value) = chatID, value > 0 {
            return privateChatSpacing
        }
        return groupChatSpacing
    }

    func waitUntilEligible() async {
        guard let nextEligible else { return }
        let remaining = nextEligible - clock.now()
        if remaining > .zero {
            await clock.wait(remaining)
        }
    }

    func markRequestInitiated(spacing: Duration) {
        nextEligible = clock.now() + spacing
    }
}

/// Telegram delivery for one immutable bot token and chat ID.
struct TelegramPacedAttentionDelivery: AttentionNotificationDelivering {
    private let token: TelegramBotToken
    private let chatID: TelegramChatID
    private let client: TelegramSendMessageClient
    private let pacer: TelegramAttentionPacer

    init(token: TelegramBotToken, chatID: TelegramChatID, client: TelegramSendMessageClient, pacer: TelegramAttentionPacer) {
        self.token = token
        self.chatID = chatID
        self.client = client
        self.pacer = pacer
    }

    func prepareForAdmission() async {
        await pacer.waitUntilEligible()
    }

    /// All parts confirmed: sent. The first part definitively rejected: failed. Any unconfirmed
    /// part, or a rejection after an earlier part was sent: unknown.
    func deliver(_ event: AttentionNotificationEvent) async -> AttentionNotificationDeliveryOutcome {
        let spacing = TelegramAttentionPacer.spacing(for: chatID)
        for (index, part) in TelegramAttentionMessageRenderer.render(event).enumerated() {
            if index > 0 {
                await pacer.waitUntilEligible()
            }
            await pacer.markRequestInitiated(spacing: spacing)
            switch await client.send(text: part.text, to: chatID, token: token) {
            case .sent:
                continue
            case .failed:
                return index == 0 ? .failed : .unknown
            case .unknown:
                return .unknown
            }
        }
        return .sent
    }
}
