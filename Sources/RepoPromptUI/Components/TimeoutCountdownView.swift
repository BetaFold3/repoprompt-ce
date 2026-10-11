import SwiftUI

/// A countdown timer view for question/instruction timeouts.
package struct TimeoutCountdownView: View {
    let startedAt: Date
    let timeoutSeconds: TimeInterval

    package init(startedAt: Date, timeoutSeconds: TimeInterval) {
        self.startedAt = startedAt
        self.timeoutSeconds = timeoutSeconds
    }

    @State private var remainingSeconds: Int = 0
    @State private var timer: Timer?

    package var body: some View {
        HStack(spacing: 4) {
            Image(systemName: remainingSeconds < 60 ? "clock.badge.exclamationmark" : "clock")
                .font(.caption)
                .foregroundColor(remainingSeconds < 60 ? .orange : .secondary)
            Text(timeString)
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(remainingSeconds < 60 ? .orange : .secondary)
        }
        .onAppear {
            updateRemaining()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                updateRemaining()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var timeString: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateRemaining() {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, Int(timeoutSeconds - elapsed))
        remainingSeconds = remaining
    }
}
