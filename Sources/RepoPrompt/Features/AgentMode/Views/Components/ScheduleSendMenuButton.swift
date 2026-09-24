import Foundation
import SwiftUI

enum AgentScheduledSendDateFormatting {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dateAndTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return time(date)
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "\(time(date)) tomorrow"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ScheduleSendMenuButton: View {
    private struct QuickPick: Identifiable {
        let title: String
        let delay: TimeInterval

        var id: TimeInterval {
            delay
        }
    }

    let isEnabled: Bool
    let isNewSessionStart: Bool
    let hasExistingScheduledSend: Bool
    let isDetached: Bool
    let onSchedule: (_ notBefore: Date, _ runAlongsideOtherSessions: Bool) -> Void

    @State private var runAlongsideOtherSessions = false
    @State private var isCustomPickerPresented = false
    @State private var customStepCount = AgentScheduledSendTiming.customStepCountRange.lowerBound

    private let quickPicks: [QuickPick] = [
        QuickPick(title: "15 minutes", delay: 15 * 60),
        QuickPick(title: "30 minutes", delay: 30 * 60),
        QuickPick(title: "1 hour", delay: 60 * 60),
        QuickPick(title: "2 hours", delay: 2 * 60 * 60),
        QuickPick(title: "4 hours", delay: 4 * 60 * 60)
    ]

    var body: some View {
        Menu {
            if isNewSessionStart {
                Toggle("Run alongside other sessions", isOn: $runAlongsideOtherSessions)
                Divider()
            }

            ForEach(quickPicks) { pick in
                Button {
                    onSchedule(
                        Date().addingTimeInterval(pick.delay),
                        isNewSessionStart && runAlongsideOtherSessions
                    )
                } label: {
                    Text("\(pick.title)  →  \(AgentScheduledSendDateFormatting.time(Date().addingTimeInterval(pick.delay)))")
                }
            }

            Divider()

            Button("Custom…") {
                customStepCount = AgentScheduledSendTiming.customStepCountRange.lowerBound
                isCustomPickerPresented = true
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .frame(width: isDetached ? 36 : 38, height: 40)
            .contentShape(Rectangle())
            .background(Color.secondary.opacity(isDetached ? 0.06 : 0.04))
            .cornerRadius(20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .hoverTooltip(tooltip)
        .accessibilityLabel("Schedule message")
        .popover(isPresented: $isCustomPickerPresented) {
            customPicker
        }
    }

    private var customPicker: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            customPickerContent(now: timeline.date)
        }
    }

    private func customPickerContent(now: Date) -> some View {
        let notBefore = AgentScheduledSendTiming.customNotBefore(
            stepCount: customStepCount,
            now: now
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("Schedule message")
                .font(.headline)

            Stepper(
                customDelayText,
                value: $customStepCount,
                in: AgentScheduledSendTiming.customStepCountRange
            )

            Text(AgentScheduledSendDateFormatting.dateAndTime(notBefore))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isNewSessionStart {
                Toggle("Run alongside other sessions", isOn: $runAlongsideOtherSessions)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isCustomPickerPresented = false
                }
                Button("Schedule") {
                    onSchedule(
                        notBefore,
                        isNewSessionStart && runAlongsideOtherSessions
                    )
                    isCustomPickerPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isEnabled)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var customDelayText: String {
        let minutes = AgentScheduledSendTiming.customDelayMinutes(stepCount: customStepCount)
        if minutes < 60 {
            return "Delay: \(minutes) minutes"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "Delay: \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "Delay: \(hours)h \(remainingMinutes)m"
    }

    private var tooltip: String {
        if hasExistingScheduledSend {
            return "Manage the scheduled message in the banner."
        }
        return isEnabled ? "Schedule message" : "Scheduling is unavailable for this message."
    }
}
