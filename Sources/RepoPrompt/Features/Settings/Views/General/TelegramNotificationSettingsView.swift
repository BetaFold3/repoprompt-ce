import SwiftUI

/// Settings for Telegram attention notifications on this (executing) Mac. The bot token is
/// entered into a blank secure field, never shown or preloaded, and cleared after a successful
/// save and when the view disappears.
struct TelegramNotificationSettingsView: View {
    let service: TelegramAttentionNotificationService
    @State private var chatIDDraft = ""
    @State private var tokenDraft = ""
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    /// Shows the automatic-notification preference in effect for this launch, not delivery readiness; a fixed notice
    /// explains when it is on but nothing can be delivered.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { service.isEnabled },
            set: { _ = service.setEnabled($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(18, max: 26)) {
                SettingSection(
                    title: "Telegram",
                    description: "Message your phone when a root Agent Mode turn finishes or an ask_user question is waiting. Configure on the Mac executing the session."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 14)) {
                        if !service.isStarted {
                            note(TelegramAttentionNotificationService.TokenStatus.notLoaded.message)
                        }

                        SettingToggle(
                            title: "Send Telegram notifications",
                            description: "Off by default. When this Mac's idle time is readable, notifications are sent only after 5 minutes without input.",
                            isOn: enabledBinding
                        )
                        .disabled(!service.isStarted)

                        ForEach(service.notices, id: \.self) { notice in
                            note(notice.message)
                        }
                        if service.offIsUnsaved {
                            Button("Retry Saving Off") { _ = service.setEnabled(false) }
                        }

                        chatIDRow
                        tokenRow

                        HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                            Button("Send Test") { _ = service.sendTest() }
                                .disabled(!service.isStarted || !service.isDeliveryConfigured || service.isTestPending)
                            if let record = service.lastTestRecord {
                                label("Test: \(TelegramAttentionNotificationService.message(for: record))")
                            }
                        }

                        if let action = service.lastAction {
                            label(action.message)
                        }
                    }
                }

                SettingSection(
                    title: "Last Results",
                    description: "Automatic notifications in this launch only; Send test results appear above. No message content or credentials are shown."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(6, max: 9)) {
                        label("Last delivery: \(service.admission.lastDeliveryOutcome.map { TelegramAttentionNotificationService.message(for: $0) } ?? "None")")
                        label("Last skipped: \(service.admission.lastSuppression.map { TelegramAttentionNotificationService.message(for: $0) } ?? "None")")
                    }
                }
            }
            .padding(fontPreset.scaledClamped(20, max: 28))
        }
        .onAppear { chatIDDraft = service.chatID ?? "" }
        .onDisappear { tokenDraft = "" }
    }

    private var chatIDRow: some View {
        HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
            TextField("Chat ID", text: $chatIDDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Button("Save Chat ID") {
                if service.saveChatID(chatIDDraft) {
                    chatIDDraft = service.chatID ?? ""
                }
            }
            .disabled(!service.isStarted)
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(4, max: 6)) {
            HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                SecureField("Bot token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .frame(maxWidth: 260)
                Button("Save Token") {
                    if service.saveToken(tokenDraft) {
                        tokenDraft = ""
                    }
                }
                .disabled(!service.isStarted || tokenDraft.isEmpty)
                Button("Remove Token") { _ = service.removeToken() }
                    .disabled(!service.isStarted || service.tokenStatus == .missing)
            }
            if service.isStarted {
                label(service.tokenStatus.message)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary)
            .padding(fontPreset.scaledClamped(10, max: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
