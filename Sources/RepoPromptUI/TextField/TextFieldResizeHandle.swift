import SwiftUI

struct TextFieldResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())

            HStack(spacing: 2) {
                ForEach(0 ..< 3) { _ in
                    Capsule()
                        .fill(Color.secondary.opacity(isHovering || isDragging ? 0.5 : 0.3))
                        .frame(width: 20, height: 2)
                }
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture()
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    height = min(maxHeight, max(minHeight, height + value.translation.height))
                }
        )
    }
}
