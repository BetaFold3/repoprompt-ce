import RepoPromptUI
import SwiftUI

// MARK: - Workspace Switch Loading Overlay

struct WorkspaceSwitchLoadingOverlay: View {
    let onCancel: () async -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text("Switching workspace...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Button("Cancel") {
                    Task {
                        await onCancel()
                    }
                }
                .buttonStyle(CustomButtonStyle())
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
