import AppKit
import SwiftUI

/// Curated fixed-pitch font picker for transcript code/diff rendering.
/// Uses NSFontManager's fixed-pitch trait filter — never opens NSFontPanel.
struct TranscriptCodeFontPicker: View {
    @Binding var selection: String
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    private let faces: [TranscriptCodeFontResolver.FaceOption] = TranscriptCodeFontResolver.availableFixedPitchFaces()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $selection) {
                Text("System Monospaced")
                    .tag(TranscriptCodeFontResolver.systemMonospacedPreferenceValue)

                ForEach(faces) { face in
                    Text(face.displayName)
                        .font(facePreviewFont(for: face.postScriptName))
                        .tag(face.postScriptName)
                }
            }
            .labelsHidden()
            .frame(maxWidth: fontPreset.scaledClamped(360, max: 480), alignment: .leading)

            Text(helpText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.secondary)
        }
    }

    private var helpText: String {
        if selection.isEmpty {
            return "Uses the system monospaced face. Invalid or uninstalled faces fall back automatically."
        }
        return "PostScript name: \(selection). Invalid or uninstalled faces fall back automatically."
    }

    /// Show each option in its own face when AppKit can resolve it; otherwise keep the UI font.
    private func facePreviewFont(for postScriptName: String) -> Font {
        let size = fontPreset.scaledClamped(13, max: 16)
        if let nsFont = NSFont(name: postScriptName, size: size), nsFont.isFixedPitch {
            return Font(nsFont)
        }
        return fontPreset.swiftUIFont(sizeAtNormal: 13)
    }
}
