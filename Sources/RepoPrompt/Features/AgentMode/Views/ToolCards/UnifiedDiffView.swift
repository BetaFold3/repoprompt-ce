import SwiftUI

// MARK: - Unified Diff View

/// Renders unified diffs with the AppKit-backed path.
struct UnifiedDiffView: View {
    let largeBodyMaxHeight: CGFloat
    private let document: UnifiedDiffDocument

    init(diff: String, largeBodyMaxHeight: CGFloat = 260) {
        self.largeBodyMaxHeight = largeBodyMaxHeight
        document = UnifiedDiffCardRendering.parse(diff)
    }

    var body: some View {
        LargeUnifiedDiffContainer(
            document: document,
            largeBodyMaxHeight: largeBodyMaxHeight
        )
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .cornerRadius(6)
    }
}

private struct UnifiedDiffContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next.isFinite, next > 1 else { return }
        value = next
    }
}

private struct LargeUnifiedDiffContainer: View {
    let document: UnifiedDiffDocument
    let largeBodyMaxHeight: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    @State private var measuredWidth: CGFloat = 0
    @State private var debouncedWidth: CGFloat = 0
    @State private var resizeDebounceTask: Task<Void, Never>?

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var fontSize: CGFloat {
        CGFloat(max(fontPreset.rawValue - 2, 9))
    }

    private var wrapLines: Bool {
        globalSettings.wrapTranscriptDiffLines()
    }

    private var preferredCodeFontPostScriptName: String? {
        globalSettings.transcriptCodeFontPostScriptName()
    }

    private var resolvedMaxHeight: CGFloat {
        fontPreset.scaledClamped(largeBodyMaxHeight, max: 420)
    }

    private var heightMeasurementWidth: CGFloat {
        let width = debouncedWidth > 1 ? debouncedWidth : measuredWidth
        if wrapLines {
            return width > 1 ? width : 480
        }
        return .greatestFiniteMagnitude
    }

    private var resolvedHeight: CGFloat {
        UnifiedDiffCardRendering.estimatedHeight(
            for: document,
            fontSize: fontSize,
            fontPreset: fontPreset,
            maxHeight: resolvedMaxHeight,
            availableWidth: heightMeasurementWidth,
            wrapLines: wrapLines,
            preferredPostScriptName: preferredCodeFontPostScriptName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Toggle(isOn: Binding(
                    get: { wrapLines },
                    set: { globalSettings.setWrapTranscriptDiffLines($0) }
                )) {
                    Text("Wrap")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.checkbox)
                .hoverTooltip("Wrap long diff lines instead of scrolling horizontally")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            UnifiedDiffTextView(
                document: document,
                fontSize: fontSize,
                fontPreset: fontPreset,
                colorScheme: colorScheme,
                wrapLines: wrapLines,
                preferredPostScriptName: preferredCodeFontPostScriptName
            )
            .frame(maxWidth: .infinity)
            .frame(height: resolvedHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: UnifiedDiffContentWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .onPreferenceChange(UnifiedDiffContentWidthPreferenceKey.self) { width in
                scheduleWidthUpdate(width)
            }
        }
        .onDisappear {
            resizeDebounceTask?.cancel()
            resizeDebounceTask = nil
        }
    }

    private func scheduleWidthUpdate(_ width: CGFloat) {
        guard width.isFinite, width > 1 else { return }
        if abs(measuredWidth - width) > 0.5 {
            measuredWidth = width
        }
        // Bucket-equality short-circuit: ignore sub-bucket jitter without resetting debounce.
        let newBucket = UnifiedDiffHeightMeasurement.CacheKey.widthBucket(for: width)
        let currentBucket = UnifiedDiffHeightMeasurement.CacheKey.widthBucket(for: debouncedWidth)
        if newBucket == currentBucket, debouncedWidth > 1 {
            return
        }

        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UnifiedDiffHeightMeasurement.resizeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let bucketed = UnifiedDiffHeightMeasurement.bucketedWidth(for: width)
            if abs(debouncedWidth - bucketed) > 0.5 {
                debouncedWidth = bucketed
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct UnifiedDiffView_Previews: PreviewProvider {
        static var previews: some View {
            UnifiedDiffView(diff: """
            diff --git a/file.swift b/file.swift
            index abc123..def456 100644
            --- a/file.swift
            +++ b/file.swift
            @@ -10,7 +10,8 @@ func example() {
                    let x = 1
            -    let y = 2
            +    let y = 3
            +    let z = 4
                    return x + y
                }
            """)
            .padding()
            .frame(width: 500)
        }
    }
#endif
